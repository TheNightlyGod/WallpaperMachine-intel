import WebKit
import XCTest

@testable import WallpaperMachine

/// Exercises the Wallpaper Engine host protocol against a real offscreen
/// `WKWebView`: module scripts from the project folder, property and pause
/// delivery, and replay to a listener that registers after the host's first
/// push. No desktop window is ever created.
@MainActor
final class WebWallpaperPageTests: XCTestCase {
  private var project: URL!

  override func setUpWithError() throws {
    project = FileManager.default.temporaryDirectory.appendingPathComponent(
      "web-wallpaper-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: project.appendingPathComponent("assets"), withIntermediateDirectories: true)
    try """
      export const loaded = true;
      window.__moduleLoaded = true;
      """.write(
        to: project.appendingPathComponent("assets/main.js"), atomically: true, encoding: .utf8)
    try """
      <!doctype html><html><head>
      <script type="module" crossorigin src="./assets/main.js"></script>
      <script>
      window.__received = { user: [], general: [], paused: [] };
      // Register late, after the host has already pushed its initial values.
      setTimeout(() => {
        window.wallpaperPropertyListener = {
          applyUserProperties(p) { window.__received.user.push(p); },
          applyGeneralProperties(p) { window.__received.general.push(p); },
          setPaused(v) { window.__received.paused.push(v); },
        };
      }, 50);
      </script></head><body><div id="stage"></div></body></html>
      """.write(to: project.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: project)
  }

  func testPageDeliversHostPropertiesAndPauseToLateListener() async throws {
    let page = WebWallpaperPage(projectURL: project, entryFile: "index.html")
    page.webView.setFrameSize(NSSize(width: 640, height: 400))
    var failures: [String] = []
    page.onFailure = { failures.append($0) }
    page.applyUserProperties(json: #"{"theme":{"value":"dark"},"tint":{"value":"1 0.5 0"}}"#)
    page.applyGeneralProperties(fps: 30)
    page.setPaused(false)
    page.load()

    let received = try await poll(page) { received in
      (received["user"] as? [[String: Any]])?.isEmpty == false
        && (received["paused"] as? [Bool])?.isEmpty == false
    }
    XCTAssertTrue(failures.isEmpty, "\(failures)")
    let moduleLoaded =
      try await page.webView.callAsyncJavaScript(
        "return window.__moduleLoaded === true", arguments: [:], in: nil, contentWorld: .page)
      as? Bool
    XCTAssertEqual(
      moduleLoaded, true,
      "ES modules must load from the project folder like they do under Wallpaper Engine")
    let user = try XCTUnwrap((received["user"] as? [[String: Any]])?.last)
    XCTAssertEqual((user["theme"] as? [String: Any])?["value"] as? String, "dark")
    XCTAssertEqual((user["tint"] as? [String: Any])?["value"] as? String, "1 0.5 0")
    XCTAssertEqual((received["general"] as? [[String: Any]])?.last?["fps"] as? Int, 30)
    XCTAssertEqual((received["paused"] as? [Bool])?.last, false)

    // Presentation suspension pauses the page without changing the user's
    // playback choice; clearing it resumes only if the user is not paused.
    page.setPresentationSuspended(true)
    _ = try await poll(page) { ($0["paused"] as? [Bool])?.last == true }
    page.setPaused(true)
    page.setPresentationSuspended(false)
    let stillPaused = try await poll(page) { ($0["paused"] as? [Bool])?.count ?? 0 >= 4 }
    XCTAssertEqual((stillPaused["paused"] as? [Bool])?.last, true)
    page.setPaused(false)
    let resumed = try await poll(page) { ($0["paused"] as? [Bool])?.last == false }
    XCTAssertEqual((resumed["paused"] as? [Bool])?.last, false)
    XCTAssertNil(page.webView.window, "This regression must not open a desktop window")
  }

  /// An offscreen view never draws, so the cadence itself cannot be observed
  /// here; WebKit's own record of the preference the page was created with is
  /// what decides it. The rate was measured on a 120 Hz display instead.
  func testOnlyAFullRefreshPageLeavesWebKitsNear60FPSCadence() throws {
    let features = (WKPreferences.self as NSObject.Type)
      .perform(NSSelectorFromString("_features"))?.takeUnretainedValue() as? [NSObject]
    let isEnabled = NSSelectorFromString("_isEnabledForFeature:")
    guard let feature = features?.first(where: {
      $0.value(forKey: "key") as? String == "PreferPageRenderingUpdatesNear60FPSEnabled"
    }), WKPreferences.instancesRespond(to: isEnabled) else {
      throw XCTSkip("This WebKit has no near-60 fps rendering preference")
    }
    typealias IsEnabled = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
    func prefersNear60FPS(_ page: WebWallpaperPage) -> Bool {
      let preferences = page.webView.configuration.preferences
      return unsafeBitCast(preferences.method(for: isEnabled), to: IsEnabled.self)(
        preferences, isEnabled, feature)
    }
    XCTAssertTrue(prefersNear60FPS(WebWallpaperPage(projectURL: project, entryFile: "index.html")))
    XCTAssertFalse(prefersNear60FPS(WebWallpaperPage(
      projectURL: project, entryFile: "index.html", rendersAtDisplayRefresh: true)))
  }

  func testTopFrameCannotNavigateAwayFromTheEntryPage() async throws {
    try """
      <!doctype html><html><body><script>location.href = "https://example.invalid/";</script></body></html>
      """.write(to: project.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
    let page = WebWallpaperPage(projectURL: project, entryFile: "index.html")
    page.load()
    let deadline = Date().addingTimeInterval(10)
    while !page.isLoaded && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
    XCTAssertTrue(page.isLoaded)
    try await Task.sleep(for: .milliseconds(300))
    XCTAssertEqual(page.webView.url?.standardizedFileURL, page.entryURL.standardizedFileURL)
  }

  /// A navigation the policy refuses, or a load another load replaces, leaves the page on show:
  /// the wallpaper is neither reported failed nor forgotten as unloaded.
  func testRefusedOrReplacedNavigationDoesNotFailTheWallpaper() async throws {
    try """
      <!doctype html><html><body><a id="away" href="other.html">away</a><script>
      setTimeout(() => { location.href = "https://example.invalid/"; }, 150);
      setTimeout(() => { document.getElementById("away").click(); }, 250);
      </script></body></html>
      """.write(to: project.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
    try "<!doctype html><p>other</p>".write(
      to: project.appendingPathComponent("other.html"), atomically: true, encoding: .utf8)
    let page = WebWallpaperPage(projectURL: project, entryFile: "index.html")
    var failures: [String] = []
    page.onFailure = { failures.append($0) }
    // The second load replaces the first while it is still provisional.
    page.load()
    try await Task.sleep(for: .milliseconds(3))
    page.load()
    let deadline = Date().addingTimeInterval(10)
    while !page.isLoaded && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
    XCTAssertTrue(page.isLoaded)
    try await Task.sleep(for: .milliseconds(600))
    XCTAssertEqual(failures, [])
    XCTAssertTrue(page.isLoaded)
    XCTAssertEqual(page.webView.url?.standardizedFileURL, page.entryURL.standardizedFileURL)
  }

  /// Hash routing changes only the fragment, which keeps the page on its entry file.
  func testHashRoutingStaysOnTheEntryPage() async throws {
    try """
      <!doctype html><html><body><script>
      setTimeout(() => { location.hash = "#route"; }, 100);
      </script></body></html>
      """.write(to: project.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
    let page = WebWallpaperPage(projectURL: project, entryFile: "index.html")
    var failures: [String] = []
    page.onFailure = { failures.append($0) }
    page.load()
    let deadline = Date().addingTimeInterval(10)
    while !page.isLoaded && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
    try await Task.sleep(for: .milliseconds(400))
    let hash = try await page.webView.callAsyncJavaScript(
      "return location.hash", arguments: [:], in: nil, contentWorld: .page) as? String
    XCTAssertEqual(hash, "#route")
    XCTAssertEqual(failures, [])
    XCTAssertTrue(page.isLoaded)
  }

  /// WebKit answers a `file://` fetch with status 0 and no headers; Wallpaper
  /// Engine's Chromium host answers 200 with a type from the extension. WebGL
  /// exports (Unity, Emscripten) check `ok` and stream `.wasm` files, so without
  /// parity they never start.
  func testProjectFileFetchesLookServedSoWasmLoadersStart() async throws {
    // (module (func (export "f") (result i32) i32.const 42))
    let wasm: [UInt8] = [
      0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00, 0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7F,
      0x03, 0x02, 0x01, 0x00, 0x07, 0x05, 0x01, 0x01, 0x66, 0x00, 0x00, 0x0A, 0x06, 0x01, 0x04,
      0x00, 0x41, 0x2A, 0x0B,
    ]
    try Data(wasm).write(to: project.appendingPathComponent("assets/answer.wasm"))
    let page = WebWallpaperPage(projectURL: project, entryFile: "index.html")
    page.load()
    let deadline = Date().addingTimeInterval(10)
    while !page.isLoaded && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
    XCTAssertTrue(page.isLoaded)

    let value = try await page.webView.callAsyncJavaScript(
        """
        const script = await fetch("assets/main.js");
        const text = await script.clone().text();
        const missing = await fetch("assets/missing.wasm").then(() => "resolved", () => "rejected");
        const streamed = await WebAssembly.instantiateStreaming(fetch("assets/answer.wasm"), {});
        const compiled = await WebAssembly.compileStreaming(fetch("./assets/answer.wasm"));
        let wrongType = "resolved";
        try {
          await WebAssembly.compileStreaming(new Response(new Uint8Array([0, 97, 115, 109, 1, 0, 0, 0])));
        } catch (error) { wrongType = error.name; }
        return {
          ok: script.ok, status: script.status, type: script.headers.get("Content-Type"),
          url: script.url.endsWith("/assets/main.js"), text: text.includes("loaded = true"),
          missing, answer: streamed.instance.exports.f(),
          compiledExports: WebAssembly.Module.exports(compiled).map(e => e.name).join(),
          wrongType,
        };
        """, arguments: [:], in: nil, contentWorld: .page)
    let result = try XCTUnwrap(value as? [String: Any])
    XCTAssertEqual(result["ok"] as? Bool, true, "\(result)")
    XCTAssertEqual(result["status"] as? Int, 200)
    XCTAssertEqual(result["type"] as? String, "text/javascript")
    XCTAssertEqual(result["url"] as? Bool, true, "A served response must keep its file URL")
    XCTAssertEqual(result["text"] as? Bool, true, "The body must reach the page unchanged")
    XCTAssertEqual(result["missing"] as? String, "rejected", "A missing file must still fail")
    XCTAssertEqual(result["answer"] as? Int, 42)
    XCTAssertEqual(result["compiledExports"] as? String, "f")
    XCTAssertEqual(
      result["wrongType"] as? String, "TypeError",
      "A response that is not a served project file keeps WebKit's own MIME check")
  }

  func testForwardedPointerEventsReachThePageWithoutANativeContextMenu() async throws {
    try """
      <!doctype html><html><body style="margin:0"><div id="stage" style="position:absolute;left:0;top:0;width:640px;height:400px"></div>
      <script>
      window.__received = { pointer: [] };
      for (const name of ["mousedown", "mouseup", "click", "contextmenu"]) {
        window.addEventListener(name, event => window.__received.pointer.push(
          [name, event.clientX, event.clientY, event.button, event.defaultPrevented]), false);
      }
      </script></body></html>
      """.write(to: project.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
    let page = WebWallpaperPage(projectURL: project, entryFile: "index.html")
    page.webView.setFrameSize(NSSize(width: 640, height: 400))
    page.load()
    let deadline = Date().addingTimeInterval(10)
    while !page.isLoaded && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
    XCTAssertTrue(page.isLoaded)

    // AppKit points, origin bottom-left: (100, 300) is CSS (100, 100).
    let point = NSPoint(x: 100, y: 300)
    let event = { (type: NSEvent.EventType) in
      NSEvent.mouseEvent(
        with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 0)!
    }
    page.deliverMouse(event(.leftMouseDown))
    page.deliverMouse(event(.leftMouseUp))
    page.deliverMouse(event(.rightMouseDown))
    page.deliverMouse(event(.rightMouseUp))
    // Wheel events ride WebKit's scrolling thread, which only exists for a page
    // in a window; they are covered by the desktop probe, not here.

    let received = try await poll(page) { ($0["pointer"] as? [[Any]])?.count ?? 0 >= 6 }
    let pointer = try XCTUnwrap(received["pointer"] as? [[Any]])
    XCTAssertEqual(
      pointer.map { $0[0] as? String },
      ["mousedown", "mouseup", "click", "mousedown", "contextmenu", "mouseup"], "\(pointer)")
    let click = try XCTUnwrap(pointer.first { $0[0] as? String == "click" })
    XCTAssertEqual(click[1] as? Int, 100)
    XCTAssertEqual(click[2] as? Int, 100)
    XCTAssertEqual(click[3] as? Int, 0)
    let contextMenu = try XCTUnwrap(pointer.first { $0[0] as? String == "contextmenu" })
    XCTAssertEqual(contextMenu[3] as? Int, 2)
    XCTAssertEqual(contextMenu[4] as? Bool, true, "WebKit's context menu must never open over the desktop")
    XCTAssertNil(page.webView.window, "This regression must not open a desktop window")
  }

  func testPointerMoveIntervalFollowsTheFrameLimit() {
    let page = WebWallpaperPage(projectURL: project, entryFile: "index.html")
    XCTAssertEqual(page.pointerMoveInterval, 1.0 / 60, accuracy: 1e-12, "no rate committed yet")
    // (descriptor fps, forwarded moves per second)
    let cases: [(UInt32, Double)] = [
      (0, 60), (120, 60), (60, 60), (59, 59), (30, 30), (12, 12), (9, 10), (1, 10),
    ]
    for (fps, rate) in cases {
      page.applyGeneralProperties(fps: fps)
      XCTAssertEqual(page.pointerMoveInterval, 1 / rate, accuracy: 1e-12, "fps \(fps)")
    }
  }

  /// WebKit hands a page one pointer move per frame it draws, so the interval
  /// follows the rate the page draws at: 60 near its default cadence even on a
  /// fast display, the display's refresh for a page created to draw at it, and
  /// the refresh of a slow display.
  func testPointerMoveIntervalFollowsTheRateThePageDrawsAt() {
    // (display refresh, page created for the full refresh, fps, forwarded moves per second)
    let cases: [(Int, Bool, UInt32, Double)] = [
      (120, false, 120, 60), (120, false, 90, 60), (120, false, 30, 30),
      (120, true, 120, 120), (144, true, 144, 144), (120, true, 240, 120), (120, true, 30, 30),
      (48, false, 48, 48), (48, false, 30, 30), (30, false, 60, 30),
    ]
    for (refresh, full, fps, rate) in cases {
      let page = WebWallpaperPage(projectURL: project, entryFile: "index.html", rendersAtDisplayRefresh: full)
      page.applyDisplayRefreshRate(refresh)
      page.applyGeneralProperties(fps: fps)
      XCTAssertEqual(
        page.pointerMoveInterval, 1 / rate, accuracy: 1e-12,
        "\(fps) fps on a \(refresh) Hz display\(full ? " drawn at its refresh" : "")")
    }
  }

  private func poll(
    _ page: WebWallpaperPage, timeout: TimeInterval = 10,
    until condition: ([String: Any]) -> Bool
  ) async throws -> [String: Any] {
    let deadline = Date().addingTimeInterval(timeout)
    var last: [String: Any] = [:]
    while Date() < deadline {
      if page.isLoaded,
        let received = try? await page.webView.callAsyncJavaScript(
          "return window.__received", arguments: [:], in: nil, contentWorld: .page)
          as? [String: Any]
      {
        last = received
        if condition(received) { return received }
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    XCTFail("condition not met before timeout; last state: \(last)")
    return last
  }
}
