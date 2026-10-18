import WebKit
import XCTest

@testable import WallpaperMachine

/// A web wallpaper written for Wallpaper Engine's Chromium calls `requestIdleCallback` without
/// checking for it; WebKit lacks it, and the call threw before a visualizer requested its first
/// frame. Every page here is synthetic, loaded offscreen with no window.
@MainActor
final class WebWallpaperIdleCallbackTests: XCTestCase {
  private var views: [WKWebView] = []

  override func tearDown() async throws {
    views.removeAll()
  }

  /// A local page with the idle-callback script and `body` as its inline script.
  private func load(script body: String = "") async throws -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.userContentController.addUserScript(
      WKUserScript(
        source: WebWallpaperIdleCallbacks.script, injectionTime: .atDocumentStart,
        forMainFrameOnly: false))
    let webView = WKWebView(frame: .zero, configuration: configuration)
    views.append(webView)
    webView.loadHTMLString(
      "<!doctype html><html><body><script>\(body)</script></body></html>",
      baseURL: URL(fileURLWithPath: NSTemporaryDirectory()))
    let deadline = Date().addingTimeInterval(10)
    while webView.isLoading && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertFalse(webView.isLoading, "the page did not finish loading")
    return webView
  }

  private func evaluate(_ webView: WKWebView, _ body: String) async throws -> [String: Any] {
    let value = try await webView.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: .page)
    return try XCTUnwrap(value as? [String: Any])
  }

  /// The shape of the visualizer in the report: its start-up asks for an idle callback and only
  /// then for its first animation frame, with nothing checking that the function exists.
  func testAPageThatAsksForAnIdleCallbackBeforeItsFirstFrameGetsToItsFrame() async throws {
    let view = try await load(
      script: """
        window.__state = { idle: null, frameRequested: false };
        try {
          window.requestIdleCallback(deadline => {
            window.__state.idle = { didTimeout: deadline.didTimeout, remaining: deadline.timeRemaining() };
          });
          window.__state.frameRequested = true;
        } catch (error) { window.__state.error = String(error); }
        """)
    let result = try await evaluate(
      view,
      """
      for (let i = 0; i < 100 && !window.__state.idle; i++) await new Promise(r => setTimeout(r, 10));
      return window.__state;
      """)
    XCTAssertNil(result["error"], "\(result)")
    XCTAssertEqual(result["frameRequested"] as? Bool, true)
    let idle = try XCTUnwrap(result["idle"] as? [String: Any], "the idle callback never ran")
    XCTAssertEqual(idle["didTimeout"] as? Bool, false)
    let remaining = try XCTUnwrap(idle["remaining"] as? Double)
    XCTAssertGreaterThan(remaining, 0)
    XCTAssertLessThanOrEqual(remaining, 50)
  }

  /// A prerender loop that asks again from inside its callback runs once per idle period, not
  /// at the rate of a zero-delay timer.
  func testACallbackThatAsksAgainRunsOncePerIdlePeriod() async throws {
    let view = try await load()
    let result = try await evaluate(
      view,
      """
      const runs = [];
      const step = () => { runs.push(performance.now()); requestIdleCallback(step); };
      requestIdleCallback(step);
      await new Promise(r => setTimeout(r, 600));
      const gaps = runs.slice(1).map((t, i) => t - runs[i]);
      return { count: runs.length, shortest: Math.min(...gaps) };
      """)
    let count = try XCTUnwrap(result["count"] as? Int)
    XCTAssertGreaterThanOrEqual(count, 2, "\(result)")
    XCTAssertLessThanOrEqual(count, 14, "\(result)")
    XCTAssertGreaterThanOrEqual(try XCTUnwrap(result["shortest"] as? Double), 45, "\(result)")
  }

  /// Callbacks queued together run in the order they were requested, a cancelled one never
  /// runs, and one that throws does not keep the rest from running.
  func testCallbacksRunInOrderWithoutTheCancelledOrThrowingOnesStoppingThem() async throws {
    let view = try await load()
    let result = try await evaluate(
      view,
      """
      const ran = [];
      window.addEventListener("error", event => event.preventDefault());
      requestIdleCallback(() => ran.push("first"));
      const cancelled = requestIdleCallback(() => ran.push("cancelled"));
      requestIdleCallback(() => { ran.push("throws"); throw new Error("expected"); });
      const last = requestIdleCallback(() => ran.push("last"));
      cancelIdleCallback(cancelled);
      cancelIdleCallback(12345);
      await new Promise(r => setTimeout(r, 200));
      return { ran, distinct: cancelled !== last };
      """)
    XCTAssertEqual(result["ran"] as? [String], ["first", "throws", "last"])
    XCTAssertEqual(result["distinct"] as? Bool, true)
  }

  /// A callback still waiting when its timeout passes runs then, with `didTimeout` set and no
  /// time remaining. Here the first callback uses up the idle period they were queued for.
  func testATimeoutRunsACallbackThatIsStillWaiting() async throws {
    let view = try await load()
    let result = try await evaluate(
      view,
      """
      let seen = null;
      requestIdleCallback(() => { const end = performance.now() + 60; while (performance.now() < end) {} });
      requestIdleCallback(deadline => {
        seen = { didTimeout: deadline.didTimeout, remaining: deadline.timeRemaining() };
      }, { timeout: 1 });
      for (let i = 0; i < 100 && !seen; i++) await new Promise(r => setTimeout(r, 10));
      return { seen };
      """)
    let seen = try XCTUnwrap(result["seen"] as? [String: Any], "the waiting callback never ran")
    XCTAssertEqual(seen["didTimeout"] as? Bool, true)
    XCTAssertEqual(seen["remaining"] as? Double, 0)
  }

  /// A WebKit that ships its own `requestIdleCallback` keeps it.
  func testABrowserWithItsOwnIdleCallbacksKeepsThem() async throws {
    let view = try await load()
    let kept = try await view.callAsyncJavaScript(
      """
      const own = () => 7;
      window.requestIdleCallback = own;
      (0, eval)(source);
      return window.requestIdleCallback === own;
      """, arguments: ["source": WebWallpaperIdleCallbacks.script], in: nil, contentWorld: .page)
    XCTAssertEqual(kept as? Bool, true)
  }

  /// Every web surface gets the script in every frame through the one list of user scripts.
  func testEverySurfaceGetsTheScriptInEveryFrame() throws {
    let script = try XCTUnwrap(
      WebWallpaperProtocol.userScripts().first { $0.source == WebWallpaperIdleCallbacks.script })
    XCTAssertFalse(script.isForMainFrameOnly)
    XCTAssertEqual(script.injectionTime, .atDocumentStart)
  }
}
