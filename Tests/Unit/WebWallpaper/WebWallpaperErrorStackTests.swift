import WebKit
import XCTest

@testable import WallpaperMachine

/// A web wallpaper written for Wallpaper Engine's Chromium reads `Error().stack` in V8's
/// format: a `Name: message` line, then one `    at function (location)` line per frame.
/// WebKit writes `function@location` lines with no header, so a logger that took its caller
/// from a fixed line of the stack threw while the page started, and the page drew nothing.
/// Every page here is synthetic, loaded offscreen with no window.
@MainActor
final class WebWallpaperErrorStackTests: XCTestCase {
  private var views: [WKWebView] = []

  override func tearDown() async throws {
    views.removeAll()
  }

  /// A local page with the error-stack script and `body` as its inline script.
  private func load(script body: String = "") async throws -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.userContentController.addUserScript(
      WKUserScript(
        source: WebWallpaperErrorStacks.script, injectionTime: .atDocumentStart,
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

  /// The shape of the logger in the report: built while its script loads, it logs once from
  /// its constructor and finds the caller as the fifth line of a stack it throws, cut after
  /// `at `. The page's start-up only got past it with V8's lines.
  func testALoggerThatReadsItsCallerFromAFixedStackLineStarts() async throws {
    let view = try await load(
      script: """
        function _getErrorObject() { try { throw Error(''); } catch (err) { return err; } }
        function Log() { this.append('log started'); }
        Log.prototype.append = function (text) {
          var callerLine = _getErrorObject().stack.split("\\n")[4];
          this.caller = callerLine.slice(callerLine.indexOf("at ") + 2).replace(/^\\s+/, '');
        };
        try { window.log = new Log(); } catch (error) { window.failure = String(error); }
        """)
    let result = try await evaluate(
      view, "return { failure: window.failure ?? null, caller: window.log?.caller ?? null };")
    XCTAssertTrue(result["failure"] is NSNull, "\(result)")
    let caller = try XCTUnwrap(result["caller"] as? String, "\(result)")
    XCTAssertNotNil(
      caller.range(of: #"^file:.*:7:\d+$"#, options: .regularExpression),
      "the caller is the page line that built the logger: \(caller)")
  }

  /// A header with the error's name and message, then each frame as V8 writes it: named
  /// functions with their location in parentheses, top-level code and anonymous functions
  /// as the bare location, built-ins as `<anonymous>`. No frame comes from the script itself.
  func testStacksReadAsV8WritesThem() async throws {
    let view = try await load()
    let result = try await evaluate(
      view,
      """
      function outer() { return inner(); }
      function inner() { return new Error("boom"); }
      class Custom extends Error { constructor(message) { super(message); this.name = "Custom"; } }
      function makeCustom() { return new Custom("bad"); }
      let fromCallback = null;
      [1].forEach(() => { fromCallback = new TypeError("typed").stack.split("\\n"); });
      return {
        named: outer().stack.split("\\n"),
        bare: Error().stack.split("\\n")[0],
        custom: makeCustom().stack.split("\\n").slice(0, 3),
        fromCallback,
      };
      """)
    let named = try XCTUnwrap(result["named"] as? [String])
    XCTAssertEqual(named.first, "Error: boom")
    XCTAssertGreaterThanOrEqual(named.count, 3, "\(named)")
    XCTAssertTrue(named[1].hasPrefix("    at inner ("), "\(named)")
    XCTAssertTrue(named[2].hasPrefix("    at outer ("), "\(named)")
    XCTAssertTrue(named.dropFirst().allSatisfy { $0.hasPrefix("    at ") }, "\(named)")
    XCTAssertEqual(result["bare"] as? String, "Error")
    let custom = try XCTUnwrap(result["custom"] as? [String])
    XCTAssertEqual(custom.first, "Custom: bad")
    XCTAssertTrue(custom[1].hasPrefix("    at Custom ("), "\(custom)")
    XCTAssertTrue(custom[2].hasPrefix("    at makeCustom ("), "\(custom)")
    let fromCallback = try XCTUnwrap(result["fromCallback"] as? [String])
    XCTAssertEqual(fromCallback.first, "TypeError: typed")
    XCTAssertFalse(fromCallback[1].contains("("), "an arrow function is a bare location: \(fromCallback)")
    XCTAssertEqual(fromCallback[2], "    at forEach (<anonymous>)")
  }

  /// Errors are still the browser's own: type checks, constructors, the frame limit,
  /// `captureStackTrace`, `cause`, assigning `stack`, and errors the engine throws.
  func testErrorsKeepTheirTypesAndTheBrowsersOwnBehavior() async throws {
    let view = try await load()
    let result = try await evaluate(
      view,
      """
      const error = new Error("m", { cause: 3 });
      const typed = new RangeError("r");
      let thrown = null;
      try { null.property; } catch (caught) { thrown = caught; }
      function deep() { return deeper(); }
      function deeper() { return new Error("limited").stack.split("\\n").length; }
      const limit = Error.stackTraceLimit;
      Error.stackTraceLimit = 1;
      const limited = deep();
      Error.stackTraceLimit = limit;
      const target = {};
      function capturing() { Error.captureStackTrace(target); }
      capturing();
      const assigned = new Error("a");
      assigned.stack = "replaced";
      return {
        isError: error instanceof Error && typed instanceof RangeError && typed instanceof Error,
        constructors: error.constructor === Error && typed.constructor === RangeError
          && Object.getPrototypeOf(RangeError) === Error,
        tag: Object.prototype.toString.call(error),
        cause: error.cause,
        enumerable: Object.keys(error),
        engineThrown: thrown instanceof TypeError && thrown.constructor === TypeError,
        limited,
        captured: String(target.stack).split("\\n").slice(0, 2),
        assigned: assigned.stack,
        lengths: [Error.length, AggregateError.length, Error.name],
      };
      """)
    XCTAssertEqual(result["isError"] as? Bool, true)
    XCTAssertEqual(result["constructors"] as? Bool, true)
    XCTAssertEqual(result["tag"] as? String, "[object Error]")
    XCTAssertEqual(result["cause"] as? Int, 3)
    XCTAssertEqual(result["enumerable"] as? [String], [])
    XCTAssertEqual(result["engineThrown"] as? Bool, true)
    XCTAssertEqual(result["limited"] as? Int, 2, "the header and one frame")
    let captured = try XCTUnwrap(result["captured"] as? [String])
    XCTAssertEqual(captured.first, "Error")
    XCTAssertTrue(captured.last?.hasPrefix("    at capturing (") == true, "\(captured)")
    XCTAssertEqual(result["assigned"] as? String, "replaced")
    XCTAssertEqual(result["lengths"] as? [AnyHashable], [1, 2, "Error"])
  }

  /// The script installs once per document: running it again adds no second layer.
  func testRunningTheScriptAgainChangesNothing() async throws {
    let view = try await load()
    let result = try await view.callAsyncJavaScript(
      """
      const before = Error;
      (0, eval)(source);
      function named() { return new Error("x").stack.split("\\n")[1]; }
      return { same: Error === before, frame: named() };
      """, arguments: ["source": WebWallpaperErrorStacks.script], in: nil, contentWorld: .page)
    let values = try XCTUnwrap(result as? [String: Any])
    XCTAssertEqual(values["same"] as? Bool, true)
    XCTAssertTrue((values["frame"] as? String)?.hasPrefix("    at named (") == true, "\(values)")
  }

  /// Every web wallpaper document gets the script, in every frame, before its own scripts.
  func testEveryWebWallpaperDocumentGetsTheScript() throws {
    let script = try XCTUnwrap(
      WebWallpaperProtocol.userScripts().first { $0.source == WebWallpaperErrorStacks.script })
    XCTAssertEqual(script.injectionTime, .atDocumentStart)
    XCTAssertFalse(script.isForMainFrameOnly)
  }
}
