import AppKit
import WebKit
import XCTest

@testable import WallpaperMachine

/// Wallpaper Engine runs its Chromium with `force-device-scale-factor=1`, so a web wallpaper is
/// laid out in its display's device pixels. The page here is zoomed out by its window's backing
/// scale to get the same layout: `devicePixelRatio` 1, a viewport and a `screen` as wide as the
/// display in pixels. Everything runs in a real `WKWebView`; the window that supplies a backing
/// scale is never ordered in. How a real page looks at that layout is compared with Wallpaper
/// Engine's own frames by `scripts/we_reference.py`, not here.
@MainActor
final class WebWallpaperDeviceLayoutTests: XCTestCase {
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
      "web-device-layout-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    try """
      <!doctype html><html><body style="margin:0"><script>
      window.__start = { width: innerWidth, ratio: devicePixelRatio, screen: screen.width };
      window.__resizes = 0;
      addEventListener("resize", () => window.__resizes++);
      </script></body></html>
      """.write(to: project.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: project)
  }

  func testAPageInAWindowIsLaidOutInItsDisplaysDevicePixels() async throws {
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
    container.wantsLayer = true
    let page = WebWallpaperPage(projectURL: project, entryFile: "index.html", persistentData: false)
    page.attach(to: container)
    // Not deferred, so it has a display's backing scale, as a desktop window has.
    let window = VisibilityWindow(contentRect: container.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = container
    defer {
      page.stop()
      window.contentView = nil
      window.close()
    }
    let backing = window.backingScaleFactor
    page.load()
    try await waitUntilLoaded(page)
    let start = try await object(page, "window.__start")
    XCTAssertEqual(start["width"] as? Double, 320 * backing, "the first read already sees device pixels")
    XCTAssertEqual(start["ratio"] as? Double, 1, "one CSS pixel per device pixel, as under Wallpaper Engine")
    let native = try await number(page, "Object.getOwnPropertyDescriptor(Screen.prototype, 'width').get.call(screen)")
    XCTAssertEqual(start["screen"] as? Double, (native * backing).rounded(), "screen is in device pixels too")
  }

  func testAScaleChangeRelaysOutTheRunningDocumentAndOneRestoresWebKitsOwnScreen() async throws {
    let page = WebWallpaperPage(projectURL: project, entryFile: "index.html", persistentData: false)
    page.webView.setFrameSize(NSSize(width: 320, height: 200))
    defer { page.stop() }
    page.load()
    try await waitUntilLoaded(page)
    let generation = page.documentGeneration
    let nativeRatio = try await number(page, "devicePixelRatio")
    let width = try await number(page, "innerWidth")
    XCTAssertEqual(width, 320)
    let ownScreen = try await bool(page, "Object.getOwnPropertyDescriptor(screen, 'width') === undefined")
    XCTAssertTrue(ownScreen)

    page.applyBackingScale(2)
    try await waitUntil(page, "innerWidth === 640 && window.__resizes > 0")
    let height = try await number(page, "innerHeight")
    XCTAssertEqual(height, 400)
    let ratio = try await number(page, "devicePixelRatio")
    XCTAssertEqual(ratio, nativeRatio / 2, accuracy: 1e-9)
    let screens = try await object(
      page,
      """
      (() => {
        const native = name => Object.getOwnPropertyDescriptor(Screen.prototype, name).get.call(screen);
        return { width: screen.width, height: screen.height, availWidth: screen.availWidth,
                 nativeWidth: native("width"), nativeHeight: native("height"), nativeAvail: native("availWidth") };
      })()
      """)
    XCTAssertEqual(screens["width"] as? Double, (screens["nativeWidth"] as? Double).map { $0 * 2 })
    XCTAssertEqual(screens["height"] as? Double, (screens["nativeHeight"] as? Double).map { $0 * 2 })
    XCTAssertEqual(screens["availWidth"] as? Double, (screens["nativeAvail"] as? Double).map { $0 * 2 })
    XCTAssertEqual(page.documentGeneration, generation, "a scale change does not reload the page")

    page.applyBackingScale(1)
    try await waitUntil(page, "innerWidth === 320 && Object.getOwnPropertyDescriptor(screen, 'width') === undefined")
  }

  func testAReloadedDocumentStartsAtTheCommittedScale() async throws {
    let page = WebWallpaperPage(projectURL: project, entryFile: "index.html", persistentData: false)
    page.webView.setFrameSize(NSSize(width: 320, height: 200))
    defer { page.stop() }
    page.applyBackingScale(2)
    page.load()
    try await waitUntilLoaded(page)
    page.load()
    try await waitUntilLoaded(page)
    let start = try await object(page, "window.__start")
    XCTAssertEqual(start["width"] as? Double, 640)
    let native = try await number(page, "Object.getOwnPropertyDescriptor(Screen.prototype, 'width').get.call(screen)")
    XCTAssertEqual(start["screen"] as? Double, native * 2, "the seed reports screen in device pixels from the first line")
    let resizes = try await number(page, "window.__resizes")
    XCTAssertEqual(resizes, 0, "a document that starts at the scale is not resized")
  }

  /// Forwarded pointer events arrive in the window's points; the page reads them in its own
  /// device-pixel coordinates.
  func testAForwardedClickLandsWhereThePointerIsInTheZoomedPage() async throws {
    try """
      <!doctype html><html><body style="margin:0"><script>
      window.__clicks = [];
      addEventListener("click", event => window.__clicks.push([event.clientX, event.clientY]));
      </script></body></html>
      """.write(to: project.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
    let page = WebWallpaperPage(projectURL: project, entryFile: "index.html", persistentData: false)
    page.webView.setFrameSize(NSSize(width: 320, height: 200))
    defer { page.stop() }
    page.applyBackingScale(2)
    page.load()
    try await waitUntilLoaded(page)
    // AppKit points, origin bottom-left: (100, 150) is 50 points from the top.
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
      page.deliverMouse(
        NSEvent.mouseEvent(
          with: type, location: NSPoint(x: 100, y: 150), modifierFlags: [],
          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil, eventNumber: 1,
          clickCount: 1, pressure: 0)!)
    }
    try await waitUntil(page, "window.__clicks.length === 1")
    let click = try await page.webView.evaluateJavaScript("window.__clicks[0]") as? [Double]
    XCTAssertEqual(click, [200, 100], "one point is two CSS pixels at a backing scale of 2")
  }

  func testTheProtocolZoomsOutByTheBackingScaleAndIgnoresNonsense() {
    XCTAssertEqual(WebWallpaperProtocol.pageZoom(forBackingScale: 2), 0.5)
    XCTAssertEqual(WebWallpaperProtocol.pageZoom(forBackingScale: 3), 1.0 / 3)
    XCTAssertEqual(WebWallpaperProtocol.pageZoom(forBackingScale: 1), 1)
    XCTAssertEqual(WebWallpaperProtocol.pageZoom(forBackingScale: 0.5), 1, "a page is never zoomed in")
    XCTAssertEqual(WebWallpaperProtocol.pageZoom(forBackingScale: .nan), 1)
    XCTAssertEqual(WebWallpaperProtocol.pageZoom(forBackingScale: .infinity), 1)
  }

  // MARK: - helpers

  private func waitUntilLoaded(_ page: WebWallpaperPage, timeout: TimeInterval = 10) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !page.isLoaded && Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
    XCTAssertTrue(page.isLoaded, "the page did not finish loading")
  }

  private func waitUntil(_ page: WebWallpaperPage, _ condition: String, timeout: TimeInterval = 5) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if (try? await bool(page, condition)) == true { return }
      try await Task.sleep(for: .milliseconds(25))
    }
    XCTFail("timed out waiting for \(condition)")
  }

  private func number(_ page: WebWallpaperPage, _ expression: String) async throws -> Double {
    let value = try await page.webView.evaluateJavaScript(expression)
    return try XCTUnwrap(value as? Double)
  }

  private func bool(_ page: WebWallpaperPage, _ expression: String) async throws -> Bool {
    let value = try await page.webView.evaluateJavaScript(expression)
    return try XCTUnwrap(value as? Bool)
  }

  private func object(_ page: WebWallpaperPage, _ expression: String) async throws -> [String: Any] {
    let value = try await page.webView.evaluateJavaScript(expression)
    return try XCTUnwrap(value as? [String: Any])
  }
}
