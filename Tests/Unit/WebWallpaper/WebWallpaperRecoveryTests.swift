import WebKit
import XCTest

@testable import WallpaperMachine

/// Page identity, committed-state replay and the restart budget: the three ways
/// a web wallpaper used to rebuild or lose itself. Offscreen `WKWebView`s only;
/// no desktop window is created.
@MainActor
final class WebWallpaperRecoveryTests: XCTestCase {
  private var project: URL!
  private var madeSurfaces: [FakeSurface] = []

  private final class FakePointerMonitor: WebWallpaperPointerMonitoring {
    var isActive = false
    func setActive(_ active: Bool) { isActive = active }
  }

  private final class FakeSurface: WebWallpaperSurface {
    let page: WebWallpaperPage
    var frame: NSRect
    var posterLayer: CALayer? = CALayer()
    var windowNumber: Int { ObjectIdentifier(self).hashValue }
    init(frame: NSRect, page: WebWallpaperPage) {
      self.frame = frame
      self.page = page
      page.webView.setFrameSize(frame.size)
    }
    func setScreenFrame(_ frame: NSRect) { self.frame = frame; page.webView.setFrameSize(frame.size) }
    func present() {}
    func retire() {}
  }

  private func makeHost(
    fetch: @escaping @MainActor () async throws -> [BridgeWebWallpaper],
    screens: @escaping @MainActor () -> [(id: UInt32, frame: NSRect)], counters: RuntimeCounters? = nil
  ) -> WebWallpaperHost {
    WebWallpaperHost(fetch: fetch, screens: screens, counters: counters,
      pointerMonitor: FakePointerMonitor(), makeSurface: { [weak self] frame, page in
        let surface = FakeSurface(frame: frame, page: page)
        self?.madeSurfaces.append(surface)
        return surface
      })
  }

  override func setUpWithError() throws {
    madeSurfaces = []
    project = FileManager.default.temporaryDirectory.appendingPathComponent(
      "web-recovery-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: project.appendingPathComponent("sub"), withIntermediateDirectories: true)
    let page = """
      <!doctype html><html><head><script>
      window.__received = { user: [], general: [], paused: [] };
      window.wallpaperPropertyListener = {
        applyUserProperties(p) { window.__received.user.push(p); },
        applyGeneralProperties(p) { window.__received.general.push(p); },
        setPaused(v) { window.__received.paused.push(v); },
      };
      </script></head><body></body></html>
      """
    try page.write(
      to: project.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
    try page.write(
      to: project.appendingPathComponent("sub/index.html"), atomically: true, encoding: .utf8)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: project)
  }

  // MARK: - W01-a: entry identity

  func testANestedEntryIsIdentifiedByItsResolvedPathNotItsFileName() throws {
    let nested = try XCTUnwrap(
      WebWallpaperProtocol.canonicalEntryURL(projectURL: project, entryFile: "sub/index.html"))
    let top = try XCTUnwrap(
      WebWallpaperProtocol.canonicalEntryURL(projectURL: project, entryFile: "index.html"))
    XCTAssertNotEqual(nested, top, "two entries sharing a file name are different pages")
    XCTAssertEqual(
      nested,
      WebWallpaperProtocol.canonicalEntryURL(projectURL: project, entryFile: "./sub/index.html"),
      "a differently spelled path names the same page")
    XCTAssertEqual(
      top, WebWallpaperProtocol.canonicalEntryURL(projectURL: project, entryFile: "sub/../index.html"))
  }

  func testAnEntryOutsideTheProjectFolderIsRejected() async {
    for escape in ["../outside.html", "sub/../../outside.html", "/etc/hosts", ""] {
      XCTAssertNil(
        WebWallpaperProtocol.canonicalEntryURL(projectURL: project, entryFile: escape),
        "entry \(escape) is not a project-relative entry inside the folder")
    }
  }

  func testRepeatedIdenticalReconcilesDoNotRebuildANestedEntryPage() async throws {
    let counters = RuntimeCounters()
    counters.startSession(duration: .seconds(60))
    let wallpaper = descriptor(entryFile: "sub/index.html")
    let host = makeHost(
      fetch: { [wallpaper] }, screens: { [(id: UInt32(7), frame: NSRect(x: 0, y: 0, width: 320, height: 200))] },
      counters: counters)

    await host.apply([wallpaper])
    let surface = RuntimeSurfaceKey(kind: .desktopWeb, displayID: 7, generation: 1)
    XCTAssertEqual(counters.snapshot().value(.webPageCreated, for: surface), 1)

    for _ in 0..<3 { await host.apply([wallpaper]) }
    XCTAssertEqual(
      counters.snapshot().total(.webPageCreated), 1,
      "an unchanged descriptor must reuse the page it already built")
    XCTAssertEqual(host.activeDisplayIDs, [7])
    host.shutdown()
  }

  func testPointerMonitorFollowsALivePageNotMerelyAnOpenWindow() async throws {
    let wallpaper = descriptor(entryFile: "index.html")
    let host = makeHost(
      fetch: { [wallpaper] },
      screens: { [(id: UInt32(7), frame: NSRect(x: 0, y: 0, width: 320, height: 200))] })
    await host.apply([wallpaper])
    XCTAssertFalse(
      host.isPointerMonitorActive,
      "a window whose page has not loaded yet installs no pointer monitor")

    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline, !host.isPointerMonitorActive {
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertTrue(host.isPointerMonitorActive, "a loaded page installs the pointer monitor")

    host.setPresentationSuspended(true)
    XCTAssertFalse(
      host.isPointerMonitorActive,
      "a host-suspended page must not keep the global pointer monitor")
    host.setPresentationSuspended(false)
    XCTAssertTrue(
      host.isPointerMonitorActive, "the first resume reinstalls the pointer monitor")

    host.setPresentationSuspended(true, forDisplay: 7)
    XCTAssertFalse(host.isPointerMonitorActive)
    host.setPresentationSuspended(false, forDisplay: 7)
    XCTAssertTrue(host.isPointerMonitorActive)
    host.shutdown()
    XCTAssertFalse(host.isPointerMonitorActive)
  }

  /// A wallpaper set on a display that "Only play on the display I'm using" has
  /// already paused is still on screen. Its page must not be detached before it has
  /// loaded, which would leave the display black until the pointer comes back.
  func testAPageCreatedOnADisplayPausedInPlainSightIsNotDetachedUnloaded() async {
    let host = makeHost(
      fetch: { [] }, screens: { [(id: UInt32(7), frame: NSRect(x: 0, y: 0, width: 320, height: 200))] })
    host.setPresentationSuspended(true, forDisplay: 7, stillVisible: true)
    await host.apply([descriptor(entryFile: "index.html")])
    let page = madeSurfaces.last?.page
    XCTAssertEqual(page?.hostSuspended, false)

    host.setPresentationSuspended(true)
    XCTAssertEqual(page?.hostSuspended, true, "sleep, a lock or an app rule hides every display")
    host.setPresentationSuspended(false)
    XCTAssertEqual(page?.hostSuspended, false, "and the display is in sight again when they end")
    host.shutdown()
  }

  func testAPageCreatedOnAHiddenDisplayIsDetachedAtOnce() async {
    let host = makeHost(
      fetch: { [] }, screens: { [(id: UInt32(7), frame: NSRect(x: 0, y: 0, width: 320, height: 200))] })
    host.setPresentationSuspended(true, forDisplay: 7)
    await host.apply([descriptor(entryFile: "index.html")])
    XCTAssertEqual(madeSurfaces.last?.page.hostSuspended, true, "a covered display needs no frame")

    host.setPresentationSuspended(false, forDisplay: 7)
    XCTAssertEqual(madeSurfaces.last?.page.hostSuspended, false)
    host.shutdown()
  }

  func testTheInSightMarkEndsWithTheDisplaySuspension() async {
    let host = makeHost(
      fetch: { [] }, screens: { [(id: UInt32(7), frame: NSRect(x: 0, y: 0, width: 320, height: 200))] })
    host.setPresentationSuspended(true, forDisplay: 7, stillVisible: true)
    host.setPresentationSuspended(false, forDisplay: 7)
    // Covered later: the earlier mark must not outlive the suspension it described.
    host.setPresentationSuspended(true, forDisplay: 7)
    await host.apply([descriptor(entryFile: "index.html")])
    XCTAssertEqual(madeSurfaces.last?.page.hostSuspended, true)
    host.shutdown()
  }

  func testChangingTheEntryFileReplacesThePage() async {
    let counters = RuntimeCounters()
    counters.startSession(duration: .seconds(60))
    let host = makeHost(
      fetch: { [] }, screens: { [(id: UInt32(7), frame: NSRect(x: 0, y: 0, width: 320, height: 200))] },
      counters: counters)

    await host.apply([descriptor(entryFile: "sub/index.html")])
    await host.apply([descriptor(entryFile: "index.html")])
    XCTAssertEqual(counters.snapshot().total(.webPageCreated), 2)
    host.shutdown()
  }

  func testAnEscapingEntryIsReportedAndOpensNoPage() async {
    var errors: [String] = []
    let counters = RuntimeCounters()
    counters.startSession(duration: .seconds(60))
    let host = makeHost(
      fetch: { [] }, screens: { [(id: UInt32(7), frame: NSRect(x: 0, y: 0, width: 320, height: 200))] },
      counters: counters)
    host.onError = { errors.append($0) }

    await host.apply([descriptor(entryFile: "../outside.html")])
    XCTAssertTrue(host.isEmpty)
    XCTAssertEqual(counters.snapshot().total(.webPageCreated), 0)
    XCTAssertEqual(errors.count, 1, "\(errors)")
    host.shutdown()
  }

  // MARK: - W01-b: committed state replay

  func testAReloadedDocumentGetsTheWholeCommittedStateBack() async throws {
    let counters = RuntimeCounters()
    counters.startSession(duration: .seconds(60))
    let page = WebWallpaperPage(
      projectURL: project, entryFile: "index.html",
      surface: RuntimeSurfaceKey(kind: .desktopWeb, displayID: 3), counters: counters)
    page.applyUserProperties(json: #"{"theme":{"value":"dark"}}"#)
    page.applyGeneralProperties(fps: 24)
    page.setPaused(true)
    page.load()
    _ = try await waitForDelivery(page) { $0["paused"] as? [Bool] == [true] }

    // Reload with no descriptor change at all: a diff-driven host would send
    // nothing, and the page would come back without properties, fps or pause.
    page.load()
    let replayed = try await waitForDelivery(page) {
      ($0["user"] as? [[String: Any]])?.isEmpty == false && ($0["paused"] as? [Bool])?.isEmpty == false
    }
    let user = try XCTUnwrap((replayed["user"] as? [[String: Any]])?.last)
    XCTAssertEqual((user["theme"] as? [String: Any])?["value"] as? String, "dark")
    XCTAssertEqual((replayed["general"] as? [[String: Any]])?.last?["fps"] as? Int, 24)
    XCTAssertEqual((replayed["paused"] as? [Bool])?.last, true)
    XCTAssertEqual(counters.snapshot().total(.webStateReplayed), 2, "once per document generation")
  }

  func testUserPauseSurvivesAReloadAndPresentationResume() async throws {
    let page = WebWallpaperPage(
      projectURL: project, entryFile: "index.html", timing: .init(firstFrameGrace: .zero))
    page.setPaused(true)
    page.setPresentationSuspended(true)
    page.load()
    _ = try await waitForDelivery(page) { ($0["paused"] as? [Bool])?.last == true }

    page.load()
    _ = try await waitForDelivery(page) { ($0["paused"] as? [Bool])?.last == true }
    page.setPresentationSuspended(false)
    // Resuming presentation must not resume a wallpaper the user paused.
    try await Task.sleep(for: .milliseconds(300))
    let state = try await received(page)
    XCTAssertEqual(
      (state["paused"] as? [Bool])?.last, true,
      "clearing presentation suspension must not undo the user's pause")
    XCTAssertTrue(
      page.hostSuspended,
      "and the host keeps the paused page suspended once the presentation resumes")
  }

  func testLoadInvalidatesHostCallsIssuedForTheOldDocument() async throws {
    let page = WebWallpaperPage(projectURL: project, entryFile: "index.html")
    page.load()
    _ = try await waitForDelivery(page) { _ in true }
    let firstGeneration = page.documentGeneration

    // A property change issued and then immediately superseded by a reload must
    // not land on the new document carrying the old value.
    page.applyUserProperties(json: #"{"theme":{"value":"stale"}}"#)
    page.load()
    XCTAssertGreaterThan(page.documentGeneration, firstGeneration)
    page.applyUserProperties(json: #"{"theme":{"value":"fresh"}}"#)
    let state = try await waitForDelivery(page) {
      ($0["user"] as? [[String: Any]])?.isEmpty == false
    }
    let values = try XCTUnwrap(state["user"] as? [[String: Any]])
      .compactMap { ($0["theme"] as? [String: Any])?["value"] as? String }
    XCTAssertFalse(values.contains("stale"), "\(values)")
    XCTAssertEqual(values.last, "fresh")
  }

  // MARK: - W01-c: restart budget

  func testRepeatedCrashesAfterASuccessfulLoadExhaustTheBudget() async throws {
    let counters = RuntimeCounters()
    counters.startSession(duration: .seconds(60))
    let clock = TestInstant()
    var failures: [String] = []
    let page = WebWallpaperPage(
      projectURL: project, entryFile: "index.html",
      surface: RuntimeSurfaceKey(kind: .desktopWeb, displayID: 5), counters: counters,
      recovery: .init(maximumRestarts: 3, window: .seconds(120), stableRun: .seconds(60)),
      now: { clock.value }, wait: { _ in })
    page.onFailure = { failures.append($0) }
    page.load()
    _ = try await waitForDelivery(page) { _ in true }

    // Every crash arrives after a completed load, which is exactly the case the
    // old single-shot flag reset back to zero for ever.
    for attempt in 1...3 {
      page.webViewWebContentProcessDidTerminate(page.webView)
      _ = try await waitForDelivery(page) { _ in true }
      XCTAssertEqual(counters.snapshot().total(.webRecoveryStarted), UInt64(attempt))
      XCTAssertTrue(failures.isEmpty, "\(failures)")
    }

    let generationBeforeGivingUp = page.documentGeneration
    page.webViewWebContentProcessDidTerminate(page.webView)
    XCTAssertEqual(counters.snapshot().total(.webRecoveryBudgetExhausted), 1)
    XCTAssertEqual(failures.count, 1, "\(failures)")
    try await Task.sleep(for: .milliseconds(200))
    XCTAssertEqual(
      page.documentGeneration, generationBeforeGivingUp,
      "an exhausted budget must not keep restarting the content process")
  }

  func testAStableRunReturnsTheRestartBudget() async throws {
    let clock = TestInstant()
    var failures: [String] = []
    let page = WebWallpaperPage(
      projectURL: project, entryFile: "index.html",
      recovery: .init(maximumRestarts: 2, window: .seconds(600), stableRun: .seconds(60)),
      now: { clock.value }, wait: { _ in })
    page.onFailure = { failures.append($0) }
    page.load()
    _ = try await waitForDelivery(page) { _ in true }

    // Two crashes that follow their loads immediately spend the budget.
    for _ in 0..<2 {
      page.webViewWebContentProcessDidTerminate(page.webView)
      _ = try await waitForDelivery(page) { _ in true }
    }
    XCTAssertTrue(failures.isEmpty, "\(failures)")

    // This document runs past the stable-run threshold before it dies, so the
    // spent restarts come back instead of the budget being exhausted.
    clock.advance(by: .seconds(61))
    page.webViewWebContentProcessDidTerminate(page.webView)
    _ = try await waitForDelivery(page) { _ in true }
    XCTAssertTrue(
      failures.isEmpty,
      "a page that ran stably for the whole window earns its restarts back")

    // And a page that immediately starts dying again still runs out.
    page.webViewWebContentProcessDidTerminate(page.webView)
    _ = try await waitForDelivery(page) { _ in true }
    page.webViewWebContentProcessDidTerminate(page.webView)
    XCTAssertEqual(failures.count, 1, "\(failures)")
  }

  func testCrashesOutsideTheWindowDoNotCountAgainstTheBudget() async throws {
    let clock = TestInstant()
    var failures: [String] = []
    let page = WebWallpaperPage(
      projectURL: project, entryFile: "index.html",
      recovery: .init(maximumRestarts: 2, window: .seconds(60), stableRun: .seconds(600)),
      now: { clock.value }, wait: { _ in })
    page.onFailure = { failures.append($0) }
    page.load()
    _ = try await waitForDelivery(page) { _ in true }

    for _ in 0..<2 {
      page.webViewWebContentProcessDidTerminate(page.webView)
      _ = try await waitForDelivery(page) { _ in true }
    }
    clock.advance(by: .seconds(61))
    page.webViewWebContentProcessDidTerminate(page.webView)
    _ = try await waitForDelivery(page) { _ in true }
    XCTAssertTrue(failures.isEmpty, "\(failures)")

    // Two more inside the new window do reach the limit.
    page.webViewWebContentProcessDidTerminate(page.webView)
    _ = try await waitForDelivery(page) { _ in true }
    page.webViewWebContentProcessDidTerminate(page.webView)
    XCTAssertEqual(failures.count, 1, "\(failures)")
  }

  func testStoppingAPageCancelsAPendingRestart() async throws {
    let page = WebWallpaperPage(
      projectURL: project, entryFile: "index.html",
      recovery: .init(maximumRestarts: 3), wait: { _ in try await Task.sleep(for: .seconds(5)) })
    page.load()
    _ = try await waitForDelivery(page) { _ in true }

    page.webViewWebContentProcessDidTerminate(page.webView)
    page.stop()
    let generation = page.documentGeneration
    try await Task.sleep(for: .milliseconds(200))
    XCTAssertEqual(page.documentGeneration, generation, "a stopped page must not reload")
  }

  // MARK: - helpers

  private final class TestInstant {
    private(set) var value = ContinuousClock.now
    func advance(by duration: Duration) { value = value.advanced(by: duration) }
  }

  private func descriptor(entryFile: String) -> BridgeWebWallpaper {
    BridgeWebWallpaper(
      displayId: 7, startupRevision: 0, displayKey: "7", audioSourceDisplayId: 7,
      wallpaperId: "1", title: "Test", projectPath: project.path,
      entryFile: entryFile, fps: 30, renderScale: 1, paused: false, volume: 1, muted: false,
      audioResponseEnabled: false,
      mediaIntegrationEnabled: false, propertiesJson: "{}")
  }

  private func received(_ page: WebWallpaperPage) async throws -> [String: Any] {
    guard page.isLoaded,
      let state = try? await page.webView.callAsyncJavaScript(
        "return window.__received", arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
    else { return [:] }
    return state
  }

  private func waitForDelivery(
    _ page: WebWallpaperPage, timeout: TimeInterval = 10,
    until condition: ([String: Any]) -> Bool
  ) async throws -> [String: Any] {
    let deadline = Date().addingTimeInterval(timeout)
    var last: [String: Any] = [:]
    while Date() < deadline {
      last = try await received(page)
      if page.isLoaded, condition(last) { return last }
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTFail("condition not met before timeout; last state: \(last)")
    return last
  }
}
