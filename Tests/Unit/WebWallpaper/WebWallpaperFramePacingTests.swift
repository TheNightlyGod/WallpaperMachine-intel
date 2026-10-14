import WebKit
import XCTest

@testable import WallpaperMachine

/// The frame-rate limit of a web page, which WebKit gives no control over: the
/// host holds the page's own `requestAnimationFrame` callbacks to the limit.
///
/// The pacer is evaluated against a fake native frame source that the test
/// ticks by hand, so cadence, timestamps and ordering are exact. The page tests
/// then run the same code in a real offscreen `WKWebView`. No desktop window is
/// created; the one test that needs WebKit to run frames puts its view in a
/// window subclass that only reports visibility.
@MainActor
final class WebWallpaperFramePacingTests: XCTestCase {
  private var project: URL!

  /// Supplies WebKit's visibility input without ordering a desktop window.
  private final class VisibilityWindow: NSWindow {
    override var isVisible: Bool { true }
    override var occlusionState: NSWindow.OcclusionState { .visible }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
  }

  override func setUpWithError() throws {
    project = FileManager.default.temporaryDirectory.appendingPathComponent(
      "web-frame-pacing-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    try writePage(
      """
      window.__loop = { count: 0 };
      const step = () => { window.__loop.count++; requestAnimationFrame(step); };
      requestAnimationFrame(step);
      """)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: project)
  }

  private func writePage(_ script: String) throws {
    try """
      <!doctype html><html><body style="margin:0;background:#123456"><script>
      \(script)
      </script></body></html>
      """.write(to: project.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
  }

  // MARK: - the pacer against a fake native frame source

  /// A native source that fires every pending request on each tick, as one
  /// display frame does, and records whether the pacer ever held more than one.
  private static let fakeNative = """
    const errors = [];
    const native = { time: 0, handle: 0, pending: new Map(), maxOutstanding: 0, cancelled: 0 };
    native.request = callback => {
      const handle = ++native.handle;
      native.pending.set(handle, callback);
      native.maxOutstanding = Math.max(native.maxOutstanding, native.pending.size);
      return handle;
    };
    native.cancel = handle => { if (native.pending.delete(handle)) native.cancelled++; };
    native.tick = (elapsed = 1000 / 60) => {
      native.time += elapsed;
      const due = [...native.pending.values()];
      native.pending.clear();
      for (const callback of due) callback(native.time);
      return native.time;
    };
    const create = new Function("return " + source)();
    const pacer = create(native.request, native.cancel, error => errors.push(String(error)));
    """

  private func scenario(_ body: String) async throws -> [String: Any] {
    let webView = WKWebView(frame: .zero)
    webView.loadHTMLString("<!doctype html><html><body></body></html>", baseURL: nil)
    let deadline = Date().addingTimeInterval(10)
    while webView.isLoading && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    let value = try await webView.callAsyncJavaScript(
      Self.fakeNative + body, arguments: ["source": WebWallpaperProtocol.framePacerSource],
      in: nil, contentWorld: .page)
    return try XCTUnwrap(value as? [String: Any])
  }

  func testALimitOfHalfTheNativeCadenceFiresEverySecondFrame() async throws {
    let result = try await scenario("""
      pacer.setLimit(30);
      const stamps = [];
      const loop = timestamp => { stamps.push(timestamp); pacer.request(loop); };
      pacer.request(loop);
      const ticks = [];
      for (let i = 0; i < 60; i++) ticks.push(native.tick());
      return { stamps, ticks, maxOutstanding: native.maxOutstanding, errors };
      """)
    let stamps = try XCTUnwrap(result["stamps"] as? [Double])
    let ticks = try XCTUnwrap(result["ticks"] as? [Double])
    XCTAssertEqual(stamps.count, 30, "30 callbacks in 60 native frames")
    XCTAssertEqual(
      stamps.compactMap { ticks.firstIndex(of: $0) }, Array(stride(from: 0, to: 60, by: 2)),
      "every callback gets its native frame's own timestamp, on every second frame")
    XCTAssertEqual(result["maxOutstanding"] as? Int, 1, "one native request at a time, however many callbacks wait")
    XCTAssertEqual(result["errors"] as? [String], [])
  }

  func testANonDivisorLimitKeepsItsAverageRate() async throws {
    let result = try await scenario("""
      pacer.setLimit(40);
      let count = 0;
      const loop = () => { count++; pacer.request(loop); };
      pacer.request(loop);
      for (let i = 0; i < 120; i++) native.tick();
      return { count };
      """)
    let count = try XCTUnwrap(result["count"] as? Int)
    XCTAssertTrue((79...81).contains(count), "40 per second over 2 s of 60 Hz frames is 80 callbacks, got \(count)")
  }

  func testACallbackCancelledBeforeItsFrameNeverRuns() async throws {
    let result = try await scenario("""
      pacer.setLimit(30);
      const ran = [];
      pacer.request(() => ran.push("a"));
      const b = pacer.request(() => ran.push("b"));
      pacer.request(() => ran.push("c"));
      pacer.cancel(b);
      pacer.cancel(b);
      pacer.cancel(123);
      native.tick();
      return { ran };
      """)
    XCTAssertEqual(result["ran"] as? [String], ["a", "c"])
  }

  func testACallbackCancelledByAnEarlierOneInTheSameFrameIsSkipped() async throws {
    let result = try await scenario("""
      const ran = [];
      let victim;
      pacer.request(() => { ran.push("first"); pacer.cancel(victim); });
      victim = pacer.request(() => ran.push("victim"));
      pacer.request(() => ran.push("last"));
      native.tick();
      native.tick();
      return { ran };
      """)
    XCTAssertEqual(result["ran"] as? [String], ["first", "last"])
  }

  func testACallbackThatRequestsAgainRunsOnALaterFrame() async throws {
    for limit in [0, 30] {
      let result = try await scenario("""
        pacer.setLimit(\(limit));
        let count = 0;
        const loop = () => { count++; if (count < 3) pacer.request(loop); };
        pacer.request(loop);
        const afterEachTick = [];
        for (let i = 0; i < 6; i++) { native.tick(); afterEachTick.push(count); }
        return { afterEachTick };
        """)
      let counts = try XCTUnwrap(result["afterEachTick"] as? [Int])
      XCTAssertEqual(counts.first, 1, "limit \(limit): the new request must wait for the next frame")
      XCTAssertEqual(counts.last, 3)
      XCTAssertTrue(
        zip(counts, counts.dropFirst()).allSatisfy { $1 - $0 <= 1 },
        "limit \(limit): a loop runs at most once per frame, got \(counts)")
    }
  }

  func testCancellingEveryCallbackCancelsTheNativeRequest() async throws {
    let result = try await scenario("""
      pacer.setLimit(30);
      const a = pacer.request(() => {});
      const b = pacer.request(() => {});
      const outstandingWithTwoWaiting = native.pending.size;
      pacer.cancel(a);
      const afterFirst = native.pending.size;
      pacer.cancel(b);
      return { outstandingWithTwoWaiting, afterFirst, after: native.pending.size,
               cancelled: native.cancelled, ids: [a, b], owned: [pacer.owns(a), pacer.owns(b), pacer.owns(7)] };
      """)
    XCTAssertEqual(result["outstandingWithTwoWaiting"] as? Int, 1)
    XCTAssertEqual(result["afterFirst"] as? Int, 1, "another callback still waits for the frame")
    XCTAssertEqual(result["after"] as? Int, 0, "nothing is left waiting, so no frame is requested")
    XCTAssertEqual(result["cancelled"] as? Int, 1)
    let ids = try XCTUnwrap(result["ids"] as? [Double])
    XCTAssertTrue(ids.allSatisfy { $0 >= 1_073_741_824 }, "paced ids stay above every native id")
    XCTAssertEqual(Set(ids).count, 2)
    XCTAssertEqual(result["owned"] as? [Bool], [true, true, false])
  }

  func testAStallDoesNotBurst() async throws {
    let result = try await scenario("""
      pacer.setLimit(30);
      let count = 0;
      const loop = () => { count++; pacer.request(loop); };
      pacer.request(loop);
      const counts = [];
      native.tick(); counts.push(count);
      native.tick(); native.tick(); counts.push(count);
      native.tick(2000); counts.push(count);
      for (let i = 0; i < 4; i++) { native.tick(); counts.push(count); }
      return { counts };
      """)
    XCTAssertEqual(
      result["counts"] as? [Int], [1, 2, 3, 3, 4, 4, 5],
      "after a 2 s stall one callback runs, then the limit resumes at its own pace rather than catching up")
  }

  func testRaisingTheLimitToZeroDrainsPendingCallbacksEveryFrame() async throws {
    let result = try await scenario("""
      pacer.setLimit(10);
      let count = 0;
      const loop = () => { count++; pacer.request(loop); };
      pacer.request(loop);
      for (let i = 0; i < 12; i++) native.tick();
      const paced = count;
      pacer.setLimit(0);
      const stillPacing = pacer.isPacing();
      for (let i = 0; i < 5; i++) native.tick();
      const drained = count - paced;
      pacer.setLimit(30);
      const before = count;
      for (let i = 0; i < 6; i++) native.tick();
      return { paced, stillPacing, drained, resumed: count - before, maxOutstanding: native.maxOutstanding };
      """)
    XCTAssertEqual(result["paced"] as? Int, 2, "10 per second is one callback per 6 frames of 60 Hz")
    XCTAssertEqual(result["stillPacing"] as? Bool, false)
    XCTAssertEqual(result["drained"] as? Int, 5, "the loop the limit held back runs at every frame once it is off")
    XCTAssertEqual(result["resumed"] as? Int, 3, "and a new limit starts at once and then halves the rate")
    XCTAssertEqual(result["maxOutstanding"] as? Int, 1)
  }

  func testLimitsOutsideTheSupportedRangeLeaveTheNativeFramesAlone() async throws {
    let result = try await scenario("""
      const verdicts = {};
      for (const value of [1, 10, 30, 59, 60, 61, 120, 0, -5, NaN, Infinity, "abc", null, undefined]) {
        pacer.setLimit(value);
        verdicts[String(value)] = pacer.isPacing();
      }
      return verdicts;
      """)
    let pacing = Set(result.filter { $0.value as? Bool == true }.keys)
    XCTAssertEqual(pacing, ["1", "10", "30", "59"], "only a rate below the ceiling is enforced")
  }

  func testAThrowingCallbackDoesNotStarveTheOthers() async throws {
    let result = try await scenario("""
      pacer.setLimit(30);
      const ran = [];
      pacer.request(() => { throw new Error("boom"); });
      pacer.request(() => ran.push("after"));
      native.tick();
      return { ran, errors };
      """)
    XCTAssertEqual(result["ran"] as? [String], ["after"])
    XCTAssertEqual(result["errors"] as? [String], ["Error: boom"], "the failure is reported, not swallowed")
  }

  func testTheCeilingIsWhereTheLimitStops() {
    XCTAssertEqual(WebWallpaperProtocol.frameLimit(forFPS: 1), 1)
    XCTAssertEqual(WebWallpaperProtocol.frameLimit(forFPS: 30), 30)
    XCTAssertEqual(WebWallpaperProtocol.frameLimit(forFPS: 59), 59)
    XCTAssertEqual(WebWallpaperProtocol.frameLimit(forFPS: 60), 0)
    XCTAssertEqual(WebWallpaperProtocol.frameLimit(forFPS: 240), 0)
    XCTAssertEqual(WebWallpaperProtocol.frameLimit(forFPS: 0), 0, "zero means no limit, never a stopped page")
  }

  /// A frame rate limits a page only below the rate WebKit draws it at, which a
  /// slow display or a page created to follow a fast one moves away from 60.
  func testTheLimitStopsAtTheRateThePageDrawsAt() {
    let draws = WebWallpaperProtocol.renderRate
    XCTAssertEqual(draws(0, false), 60, "an unknown display counts as the 60 WebKit prefers")
    XCTAssertEqual(draws(60, false), 60)
    XCTAssertEqual(draws(120, false), 60, "a fast display is still drawn near 60 by default")
    XCTAssertEqual(draws(48, false), 48, "a slow display lowers it")
    XCTAssertEqual(draws(120, true), 120, "a page created for the full refresh draws at it")
    XCTAssertEqual(draws(144, true), 144)

    let limit = WebWallpaperProtocol.frameLimit
    XCTAssertEqual(limit(48, 48), 0, "the display's own rate limits nothing")
    XCTAssertEqual(limit(47, 48), 47)
    XCTAssertEqual(limit(30, 30), 0)
    XCTAssertEqual(limit(59, 120), 59)
    XCTAssertEqual(limit(90, 120), 0, "above 60 the pacer has nothing to hold the page to")
    XCTAssertEqual(limit(30, 120), 30, "a page drawing at the full refresh still honors a low limit")
    XCTAssertEqual(limit(120, 120), 0)
  }

  // MARK: - the pacer inside a real page

  func testPageAtOrAboveTheCeilingIsAPureNativePassThrough() async throws {
    for fps in [UInt32(60), 120] {
      let page = WebWallpaperPage(projectURL: project, entryFile: "index.html")
      page.applyGeneralProperties(fps: fps)
      page.load()
      try await waitUntilLoaded(page)
      let result = try await evaluate(
        page,
        """
        const id = requestAnimationFrame(() => {});
        cancelAnimationFrame(id);
        let error = null;
        try { requestAnimationFrame(1); } catch (thrown) { error = thrown.constructor.name; }
        return { id, error };
        """)
      let id = try XCTUnwrap(result["id"] as? Double)
      XCTAssertLessThan(id, 1_073_741_824, "\(fps) fps: the page holds a native handle")
      XCTAssertEqual(result["error"] as? String, "TypeError", "\(fps) fps: WebKit's own argument check answers")
      page.stop()
    }
  }

  func testAFrameRateThatReachesTheRateThePageDrawsAtLeavesItsFramesNative() async throws {
    // (display refresh, page created for the full refresh, frame rate, paced)
    let cases: [(Int, Bool, UInt32, Bool)] = [
      (48, false, 48, false), (48, false, 30, true), (120, true, 120, false), (120, true, 30, true),
    ]
    for (refresh, full, fps, paced) in cases {
      let page = WebWallpaperPage(projectURL: project, entryFile: "index.html", rendersAtDisplayRefresh: full)
      page.applyDisplayRefreshRate(refresh)
      page.applyGeneralProperties(fps: fps)
      page.load()
      try await waitUntilLoaded(page)
      let result = try await evaluate(
        page, "const id = requestAnimationFrame(() => {}); cancelAnimationFrame(id); return { id };")
      let id = try XCTUnwrap(result["id"] as? Double)
      XCTAssertEqual(
        id >= 1_073_741_824, paced, "\(fps) fps on a \(refresh) Hz display\(full ? " drawn at its refresh" : "")")
      page.stop()
    }
  }

  func testADisplayThatChangesRefreshRetunesTheLimitOfARunningPage() async throws {
    let page = WebWallpaperPage(projectURL: project, entryFile: "index.html")
    page.applyDisplayRefreshRate(48)
    page.applyGeneralProperties(fps: 50)
    page.load()
    try await waitUntilLoaded(page)
    try await pollPacing(page, expected: false)
    let generation = page.documentGeneration

    page.applyDisplayRefreshRate(120)
    try await pollPacing(page, expected: true)
    page.applyDisplayRefreshRate(48)
    try await pollPacing(page, expected: false)
    XCTAssertEqual(page.documentGeneration, generation, "a refresh change must not reload the page")
    page.stop()
  }

  func testAPageThatSetsAnFpsBeforeLoadIsPacedFromItsFirstCall() async throws {
    try writePage(
      """
      window.__first = requestAnimationFrame(() => {});
      """)
    let paced = WebWallpaperPage(projectURL: project, entryFile: "index.html")
    paced.applyGeneralProperties(fps: 30)
    paced.load()
    try await waitUntilLoaded(paced)
    let pacedResult = try await evaluate(paced, "return { id: window.__first }")
    let pacedFirst = try XCTUnwrap(pacedResult["id"] as? Double)
    XCTAssertGreaterThanOrEqual(
      pacedFirst, 1_073_741_824, "the limit is part of the document's start, so no call escapes it")
    paced.stop()

    let free = WebWallpaperPage(projectURL: project, entryFile: "index.html")
    free.load()
    try await waitUntilLoaded(free)
    let freeResult = try await evaluate(free, "return { id: window.__first }")
    let freeFirst = try XCTUnwrap(freeResult["id"] as? Double)
    XCTAssertLessThan(freeFirst, 1_073_741_824, "a page with no limit keeps WebKit's own handles")
    free.stop()
  }

  func testTheLimitSurvivesAReloadOfTheDocument() async throws {
    try writePage("window.__first = requestAnimationFrame(() => {});")
    let page = WebWallpaperPage(projectURL: project, entryFile: "index.html")
    page.load()
    try await waitUntilLoaded(page)
    page.applyGeneralProperties(fps: 20)
    try await pollPacing(page, expected: true)

    page.load()
    try await waitUntilLoaded(page)
    let result = try await evaluate(page, "return { id: window.__first }")
    let first = try XCTUnwrap(result["id"] as? Double)
    XCTAssertGreaterThanOrEqual(first, 1_073_741_824, "a reloaded document starts with the committed limit")
    page.stop()
  }

  func testALiveLimitChangeSlowsARealRenderLoopAndLiftingItRestoresTheRate() async throws {
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
    container.wantsLayer = true
    let page = WebWallpaperPage(projectURL: project, entryFile: "index.html")
    page.attach(to: container)
    let window = VisibilityWindow(
      contentRect: container.frame, styleMask: .borderless, backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    window.contentView = container
    defer {
      page.stop()
      window.contentView = nil
      window.close()
    }
    page.load()
    try await waitUntilLoaded(page)
    try await poll { ((try? await self.loopCount(page)) ?? 0) > 5 }
    let generation = page.documentGeneration

    let free = try await loopRate(page)
    page.applyGeneralProperties(fps: 30)
    try await pollPacing(page, expected: true)
    let limited = try await loopRate(page)
    XCTAssertGreaterThan(free, 20, "the fixture must be animating freely before it is limited")
    XCTAssertLessThan(limited, free * 0.7, "30 fps must visibly cut the callback rate (\(limited) vs \(free) per second)")
    XCTAssertGreaterThanOrEqual(limited, 12, "a limited loop still runs (\(limited) per second)")

    page.applyGeneralProperties(fps: 120)
    try await pollPacing(page, expected: false)
    let lifted = try await loopRate(page)
    XCTAssertGreaterThan(lifted, limited * 1.4, "lifting the limit frees the loop that was held (\(lifted) vs \(limited))")
    XCTAssertEqual(page.documentGeneration, generation, "a limit change must not reload the page")
  }

  func testAPacedHandleAndANativeHandleAreEachCancelledWhereTheyWereIssued() async throws {
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
    container.wantsLayer = true
    try writePage("window.__ran = [];")
    let page = WebWallpaperPage(projectURL: project, entryFile: "index.html")
    page.attach(to: container)
    let window = VisibilityWindow(
      contentRect: container.frame, styleMask: .borderless, backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    window.contentView = container
    defer {
      page.stop()
      window.contentView = nil
      window.close()
    }
    page.load()
    try await waitUntilLoaded(page)
    // One synchronous script, so no frame runs between the calls: the first
    // handle is issued before any limit and is cancelled after pacing starts.
    let result = try await evaluate(
      page,
      """
      const nativeId = requestAnimationFrame(() => window.__ran.push('native'));
      window.__mweWallpaperHost.setFrameLimit(30);
      const pacedId = requestAnimationFrame(() => window.__ran.push('paced'));
      cancelAnimationFrame(nativeId);
      cancelAnimationFrame(pacedId);
      requestAnimationFrame(() => window.__ran.push('kept'));
      return { nativeId, pacedId };
      """)
    XCTAssertLessThan(try XCTUnwrap(result["nativeId"] as? Double), 1_073_741_824)
    XCTAssertGreaterThanOrEqual(try XCTUnwrap(result["pacedId"] as? Double), 1_073_741_824)
    var ran: [String] = []
    try await poll {
      let state = try? await self.evaluate(page, "return { ran: window.__ran }")
      ran = (state?["ran"] as? [String]) ?? []
      return ran.contains("kept")
    }
    try await Task.sleep(for: .milliseconds(150))
    let settled = try await evaluate(page, "return { ran: window.__ran }")
    XCTAssertEqual(
      settled["ran"] as? [String], ["kept"],
      "neither cancelled callback may run, and the one left alone does")
  }

  /// The screen saver's readiness check waits on `requestAnimationFrame` in the
  /// page world and nothing there can be verified on a desktop, so its script
  /// must never carry the wrappers, whatever it is told.
  func testTheScreenSaverScriptNeverPacesFrames() async throws {
    let configuration = WKWebViewConfiguration()
    for script in WebWallpaperProtocol.userScripts() { configuration.userContentController.addUserScript(script) }
    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.loadHTMLString("<!doctype html><html><body></body></html>", baseURL: nil)
    let deadline = Date().addingTimeInterval(10)
    while webView.isLoading && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    let value = try await webView.callAsyncJavaScript(
      """
      window.__mweWallpaperHost.setFrameLimit(10);
      const id = requestAnimationFrame(() => {});
      cancelAnimationFrame(id);
      return { id };
      """, arguments: [:], in: nil, contentWorld: .page)
    let id = try XCTUnwrap((value as? [String: Any])?["id"] as? Double)
    XCTAssertLessThan(id, 1_073_741_824)
  }

  // MARK: - helpers

  @discardableResult
  private func evaluate(_ page: WebWallpaperPage, _ body: String) async throws -> [String: Any] {
    let value = try await page.webView.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: .page)
    return try XCTUnwrap(value as? [String: Any])
  }

  private func loopCount(_ page: WebWallpaperPage) async throws -> Int {
    let value = try await page.webView.callAsyncJavaScript(
      "return window.__loop.count", arguments: [:], in: nil, contentWorld: .page)
    return try XCTUnwrap(value as? Int)
  }

  /// Callbacks per second over one second of the page's own clock.
  private func loopRate(_ page: WebWallpaperPage) async throws -> Double {
    func sample() async throws -> (count: Double, time: Double) {
      let value = try await page.webView.callAsyncJavaScript(
        "return { count: window.__loop.count, time: performance.now() }",
        arguments: [:], in: nil, contentWorld: .page)
      let sample = try XCTUnwrap(value as? [String: Any])
      return (try XCTUnwrap(sample["count"] as? Double), try XCTUnwrap(sample["time"] as? Double))
    }
    let start = try await sample()
    try await Task.sleep(for: .seconds(1))
    let end = try await sample()
    return (end.count - start.count) / ((end.time - start.time) / 1000)
  }

  /// Whether the running document is being paced is read from the handle a
  /// request gets: paced handles sit above every native one.
  private func pollPacing(_ page: WebWallpaperPage, expected: Bool) async throws {
    var observed: Bool?
    try await poll {
      let value = try? await page.webView.callAsyncJavaScript(
        "const id = requestAnimationFrame(() => {}); cancelAnimationFrame(id); return id >= 2 ** 30",
        arguments: [:], in: nil, contentWorld: .page)
      observed = value as? Bool
      return observed == expected
    }
    XCTAssertEqual(observed, expected)
  }

  private func waitUntilLoaded(_ page: WebWallpaperPage, timeout: TimeInterval = 10) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !page.isLoaded && Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
    XCTAssertTrue(page.isLoaded, "the page did not load")
  }

  private func poll(timeout: TimeInterval = 5, until condition: () async -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if await condition() { return }
      try await Task.sleep(for: .milliseconds(25))
    }
  }
}
