import WebKit
import XCTest

@testable import WallpaperMachine

/// The internal render scale of a web page. WebKit has no render target the host
/// can shrink, so the scale reaches a page as a multiplier of
/// `window.devicePixelRatio`: a page that sizes its canvas or WebGL buffer from
/// the ratio, and rebuilds it on `resize`, draws fewer pixels.
///
/// Everything runs in a real offscreen `WKWebView` with no desktop window. What
/// a page that reads the ratio looks like on screen, and what the scale saves in
/// energy, only a desktop run can show.
@MainActor
final class WebWallpaperRenderScaleTests: XCTestCase {
  private var project: URL!

  override func setUpWithError() throws {
    project = FileManager.default.temporaryDirectory.appendingPathComponent(
      "web-render-scale-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    try writePage("")
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: project)
  }

  private func writePage(_ script: String, body: String = "") throws {
    try """
      <!doctype html><html><body style="margin:0">\(body)<script>
      \(script)
      </script></body></html>
      """.write(to: project.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
  }

  func testTheScaleMultipliesDevicePixelRatioAndRestoresItExactly() async throws {
    let page = try await loadedPage()
    defer { page.stop() }
    let native = try await number(page, "window.devicePixelRatio")
    try await run(page, "window.__native = Object.getOwnPropertyDescriptor(window, 'devicePixelRatio')")

    page.applyRenderScale(0.5)
    try await waitUntil(page, "window.devicePixelRatio === \(native) * 0.5")
    let scaled = try await bool(
      page, "Object.getOwnPropertyDescriptor(window, 'devicePixelRatio').get !== window.__native.get")
    XCTAssertTrue(scaled, "the scaled ratio is a getter of the host's own")

    page.applyRenderScale(0.75)
    try await waitUntil(page, "window.devicePixelRatio === \(native) * 0.75")

    page.applyRenderScale(1)
    try await waitUntil(page, "window.devicePixelRatio === \(native)")
    let restored = try await bool(
      page,
      """
      (() => {
        const now = Object.getOwnPropertyDescriptor(window, 'devicePixelRatio');
        const saved = window.__native;
        return now.get === saved.get && now.set === saved.set
          && now.enumerable === saved.enumerable && now.configurable === saved.configurable;
      })()
      """)
    XCTAssertTrue(restored, "at full scale WebKit's own property is back, not an imitation of it")
  }

  func testALiveChangeRaisesOneResizeEventButTheSeededValueRaisesNone() async throws {
    try writePage("window.__resizes = 0; addEventListener('resize', () => window.__resizes++);")
    let native = try await nativeRatio()
    let page = WebWallpaperPage(projectURL: project, entryFile: "index.html")
    defer { page.stop() }
    page.applyRenderScale(0.5)
    page.load()
    try await waitUntilLoaded(page)
    let seeded = try await number(page, "window.devicePixelRatio")
    XCTAssertEqual(seeded, native * 0.5, accuracy: 1e-9)

    // Deliveries are ordered, so a stray event for the seeded value or for the
    // load-time replay would already be counted when this change lands.
    page.applyRenderScale(0.75)
    try await waitUntil(page, "window.devicePixelRatio === \(native) * 0.75")
    let afterChange = try await number(page, "window.__resizes")
    XCTAssertEqual(afterChange, 1)

    page.applyRenderScale(0.75)
    let afterRepeat = try await number(page, "window.__resizes")
    XCTAssertEqual(afterRepeat, 1, "the same scale again is not a change")

    // Two changes in one turn of the page share one event.
    try await run(
      page,
      """
      window.__resizes = 0;
      window.__mweWallpaperHost.setRenderScale(0.6);
      window.__mweWallpaperHost.setRenderScale(0.7);
      """)
    try await waitUntil(page, "window.__resizes > 0")
    let coalesced = try await number(page, "window.__resizes")
    XCTAssertEqual(coalesced, 1)
    let latest = try await number(page, "window.devicePixelRatio")
    XCTAssertEqual(latest, native * 0.7, accuracy: 1e-9)
  }

  func testTheScaleAppliedBeforeLoadIsVisibleToThePageAtStart() async throws {
    try writePage("window.__start = window.devicePixelRatio;")
    let native = try await nativeRatio()

    let page = WebWallpaperPage(projectURL: project, entryFile: "index.html")
    defer { page.stop() }
    page.applyRenderScale(0.5)
    page.load()
    try await waitUntilLoaded(page)
    let first = try await number(page, "window.__start")
    XCTAssertEqual(first, native * 0.5, accuracy: 1e-9, "the first read in the document already sees the scale")

    // A reload starts from the committed scale, with nothing delivered yet.
    page.load()
    try await waitUntilLoaded(page)
    let reloaded = try await number(page, "window.__start")
    XCTAssertEqual(reloaded, native * 0.5, accuracy: 1e-9)

    page.applyRenderScale(1)
    page.load()
    try await waitUntilLoaded(page)
    let restored = try await number(page, "window.__start")
    XCTAssertEqual(restored, native, accuracy: 1e-9)
  }

  func testACanvasPageThatSizesItsBufferFromTheRatioRebuildsAfterTheChange() async throws {
    try writePage(
      """
      const canvas = document.createElement('canvas');
      window.__widths = [];
      const fit = () => {
        canvas.width = Math.round(200 * window.devicePixelRatio);
        canvas.height = Math.round(100 * window.devicePixelRatio);
        window.__widths.push(canvas.width);
      };
      fit();
      addEventListener('resize', fit);
      """)
    let page = try await loadedPage()
    defer { page.stop() }
    let native = try await number(page, "window.devicePixelRatio")
    let initial = try await widths(page)
    XCTAssertEqual(initial, [Int((200 * native).rounded())])

    page.applyRenderScale(0.5)
    try await waitUntil(page, "window.__widths.length === 2")
    let halved = try await widths(page)
    XCTAssertEqual(halved.last, Int((200 * native * 0.5).rounded()), "the buffer is rebuilt at half the pixel density")

    page.applyRenderScale(1)
    try await waitUntil(page, "window.__widths.length === 3")
    let restored = try await widths(page)
    XCTAssertEqual(restored.last, Int((200 * native).rounded()))
  }

  func testScalesOutsideTheSupportedRangeAreHeldToIt() async throws {
    XCTAssertEqual(WebWallpaperProtocol.clampedRenderScale(0.25), 0.5, "scenes may go to a quarter, pages stop at half")
    XCTAssertEqual(WebWallpaperProtocol.clampedRenderScale(0.6), 0.6)
    XCTAssertEqual(WebWallpaperProtocol.clampedRenderScale(2), 1)
    XCTAssertEqual(WebWallpaperProtocol.clampedRenderScale(.nan), 1, "a value that is not a scale means full resolution")
    XCTAssertEqual(WebWallpaperProtocol.clampedRenderScale(.infinity), 1)
    let script = WebWallpaperProtocol.makeHostScript(seed: .init(renderScale: .nan))
    XCTAssertTrue(script.hasSuffix("renderScale: 1.0 })"), "only a number the script can read is interpolated")

    let page = try await loadedPage()
    defer { page.stop() }
    let native = try await number(page, "window.devicePixelRatio")
    page.applyRenderScale(0.25)
    try await waitUntil(page, "window.devicePixelRatio === \(native) * 0.5")
    page.applyRenderScale(.nan)
    try await waitUntil(page, "window.devicePixelRatio === \(native)")
  }

  func testAPageThatAssignedTheRatioItselfKeepsItsOwnValue() async throws {
    try writePage("window.__resizes = 0; addEventListener('resize', () => window.__resizes++);")
    let page = try await loadedPage()
    defer { page.stop() }
    let native = try await number(page, "window.devicePixelRatio")
    page.applyRenderScale(0.5)
    try await waitUntil(page, "window.devicePixelRatio === \(native) * 0.5")
    try await waitUntil(page, "window.__resizes === 1")

    // The property is replaceable: an assignment turns it into a plain value.
    try await run(page, "window.devicePixelRatio = 3")
    let assigned = try await number(page, "window.devicePixelRatio")
    XCTAssertEqual(assigned, 3)

    page.applyRenderScale(1)
    try await waitUntil(page, "window.__resizes === 2")
    let kept = try await number(page, "window.devicePixelRatio")
    XCTAssertEqual(kept, 3, "returning to full scale does not undo the page's own value")
  }

  /// Documented limit: only the main frame's script is seeded and driven, so a
  /// frame the page embeds keeps the display's own ratio.
  func testSubframesKeepTheDisplaysOwnRatio() async throws {
    try writePage("", body: "<iframe id='frame' srcdoc='<p>frame</p>'></iframe>")
    let page = try await loadedPage()
    defer { page.stop() }
    let native = try await number(page, "window.devicePixelRatio")
    page.applyRenderScale(0.5)
    try await waitUntil(page, "window.devicePixelRatio === \(native) * 0.5")
    try await waitUntil(page, "document.getElementById('frame').contentWindow !== null")
    let inFrame = try await number(page, "document.getElementById('frame').contentWindow.devicePixelRatio")
    XCTAssertEqual(inFrame, native)
  }

  // MARK: - helpers

  private func loadedPage() async throws -> WebWallpaperPage {
    let page = WebWallpaperPage(projectURL: project, entryFile: "index.html")
    page.load()
    try await waitUntilLoaded(page)
    return page
  }

  /// The ratio an unscaled page of this process reads.
  private func nativeRatio() async throws -> Double {
    let page = try await loadedPage()
    defer { page.stop() }
    return try await number(page, "window.devicePixelRatio")
  }

  private func number(_ page: WebWallpaperPage, _ expression: String) async throws -> Double {
    let value = try await page.webView.callAsyncJavaScript(
      "return \(expression)", arguments: [:], in: nil, contentWorld: .page)
    return try XCTUnwrap(value as? Double, "\(expression) is not a number")
  }

  private func bool(_ page: WebWallpaperPage, _ expression: String) async throws -> Bool {
    let value = try await page.webView.callAsyncJavaScript(
      "return \(expression)", arguments: [:], in: nil, contentWorld: .page)
    return try XCTUnwrap(value as? Bool, "\(expression) is not a boolean")
  }

  private func widths(_ page: WebWallpaperPage) async throws -> [Int] {
    let value = try await page.webView.callAsyncJavaScript(
      "return window.__widths", arguments: [:], in: nil, contentWorld: .page)
    return try XCTUnwrap(value as? [Int])
  }

  /// A round trip through the page: everything sent to it before is done.
  private func run(_ page: WebWallpaperPage, _ body: String) async throws {
    _ = try await page.webView.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: .page)
  }

  private func waitUntil(_ page: WebWallpaperPage, _ expression: String, timeout: TimeInterval = 10) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      let value = try? await page.webView.callAsyncJavaScript(
        "return !!(\(expression))", arguments: [:], in: nil, contentWorld: .page)
      if value as? Bool == true { return }
      try await Task.sleep(for: .milliseconds(25))
    }
    XCTFail("the page never reached: \(expression)")
  }

  private func waitUntilLoaded(_ page: WebWallpaperPage, timeout: TimeInterval = 10) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !page.isLoaded && Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
    XCTAssertTrue(page.isLoaded, "the page did not load")
  }
}
