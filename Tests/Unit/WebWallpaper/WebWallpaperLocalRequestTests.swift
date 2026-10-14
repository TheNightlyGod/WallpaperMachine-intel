import WebKit
import XCTest

@testable import WallpaperMachine

/// Local loaders must see server-like success without turning missing files or
/// cancelled requests into successes. All fixtures are synthetic and offscreen.
@MainActor
final class WebWallpaperLocalRequestTests: XCTestCase {
  private var project: URL!

  override func setUpWithError() throws {
    project = FileManager.default.temporaryDirectory.appendingPathComponent(
      "web-local-request-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    try #"{"answer":42}"#.write(
      to: project.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
    try "".write(to: project.appendingPathComponent("empty.txt"), atomically: true, encoding: .utf8)
    try """
      <!doctype html><html><body><div id="stage">loading</div><script>
      const request = new XMLHttpRequest();
      request.open("GET", "settings.json", false);
      request.overrideMimeType("text/plain;charset=utf-8");
      request.send();
      if (request.status === 200) {
        document.getElementById("stage").textContent = JSON.parse(request.responseText).answer;
      }
      </script></body></html>
      """.write(to: project.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: project)
  }

  func testSynchronousStartupLoaderAdvancesPastLoading() async throws {
    let page = try await loadedPage()
    defer { page.stop() }
    let result = try await evaluate(page, """
      const empty = new XMLHttpRequest();
      empty.open('GET', 'empty.txt', false);
      empty.send();
      return {
        stage: document.getElementById('stage').textContent,
        status: empty.status, statusText: empty.statusText, body: empty.responseText,
        url: empty.responseURL.endsWith('/empty.txt')
      };
      """)
    XCTAssertEqual(result["stage"] as? String, "42")
    XCTAssertEqual(result["status"] as? Int, 200, "An empty successful response still succeeds")
    XCTAssertEqual(result["statusText"] as? String, "OK")
    XCTAssertEqual(result["body"] as? String, "")
    XCTAssertEqual(result["url"] as? Bool, true)
  }

  func testAsynchronousResponseMetadataIsAvailableInsideCallbacks() async throws {
    let page = try await loadedPage()
    defer { page.stop() }
    let result = try await evaluate(page, """
      return await new Promise(resolve => {
        const xhr = new XMLHttpRequest(), states = [], events = [];
        xhr.onreadystatechange = () => states.push([xhr.readyState, xhr.status, xhr.statusText]);
        xhr.onload = () => events.push('load');
        xhr.onerror = () => events.push('error');
        xhr.onloadend = () => resolve({states, events, answer: xhr.response?.answer,
          url: xhr.responseURL.endsWith('/settings.json')});
        xhr.open('GET', 'settings.json', true);
        xhr.responseType = 'json';
        xhr.send();
      });
      """)
    let states = try XCTUnwrap(result["states"] as? [[Any]])
    XCTAssertEqual(states.first?[0] as? Int, 1)
    XCTAssertEqual(states.first?[1] as? Int, 0, "Opening a request is not a successful response")
    XCTAssertEqual(states.last?[0] as? Int, 4)
    for state in states.dropFirst() {
      XCTAssertEqual(state[1] as? Int, 200, "Metadata must be visible before load: \(states)")
      XCTAssertEqual(state[2] as? String, "OK")
    }
    XCTAssertEqual(result["answer"] as? Int, 42, "Native JSON decoding must remain intact")
    XCTAssertEqual(result["url"] as? Bool, true)
    XCTAssertEqual(result["events"] as? [String], ["load"])
  }

  func testFailuresAbortAndReuseNeverInheritSuccessfulStatus() async throws {
    let page = try await loadedPage()
    defer { page.stop() }
    let result = try await evaluate(page, """
      const xhr = new XMLHttpRequest();
      const state = () => [xhr.status, xhr.statusText, xhr.responseURL];
      const unopened = state();
      xhr.open('GET', 'settings.json', false); xhr.send();
      const success = xhr.status;
      xhr.open('GET', 'missing.json', false);
      const reopened = state();
      try { xhr.send(); } catch (_) {}
      const missing = state();
      xhr.open('GET', 'settings.json', true); xhr.send(); xhr.abort();
      const aborted = state();
      const asyncMissing = await new Promise(resolve => {
        const failed = new XMLHttpRequest();
        failed.onloadend = () => resolve([failed.status, failed.statusText, failed.responseURL]);
        failed.open('GET', 'missing.json'); failed.send();
      });
      xhr.open('GET', 'settings.json', false); xhr.send();
      return {unopened, success, reopened, missing, aborted, asyncMissing, recovered: xhr.status};
      """)
    XCTAssertEqual(result["success"] as? Int, 200)
    XCTAssertEqual(result["recovered"] as? Int, 200)
    for key in ["unopened", "reopened", "missing", "aborted", "asyncMissing"] {
      let state = try XCTUnwrap(result[key] as? [Any])
      XCTAssertEqual(state[0] as? Int, 0, "\(key): \(state)")
      XCTAssertEqual(state[1] as? String, "", key)
      XCTAssertEqual(state[2] as? String, "", key)
    }
  }

  func testNonFileRequestsKeepNativeMetadataAndBinaryBodies() async throws {
    let page = try await loadedPage()
    defer { page.stop() }
    let result = try await evaluate(page, """
      const data = new XMLHttpRequest();
      data.open('GET', 'data:text/plain,hello', false); data.send();
      const bytes = await new Promise(resolve => {
        const file = new XMLHttpRequest();
        file.open('GET', 'settings.json'); file.responseType = 'arraybuffer';
        file.onloadend = () => resolve({status: file.status,
          text: new TextDecoder().decode(file.response)});
        file.send();
      });
      return {status: data.status, statusText: data.statusText, body: data.responseText,
        url: data.responseURL, bytes};
      """)
    XCTAssertEqual(result["status"] as? Int, 200)
    XCTAssertEqual(result["statusText"] as? String, "OK")
    XCTAssertEqual(result["body"] as? String, "hello")
    XCTAssertEqual(result["url"] as? String, "data:text/plain,hello")
    let bytes = try XCTUnwrap(result["bytes"] as? [String: Any])
    XCTAssertEqual(bytes["status"] as? Int, 200)
    XCTAssertEqual(bytes["text"] as? String, #"{"answer":42}"#)
  }

  // MARK: - subframes

  /// A frame the page embeds is a separate global with its own `fetch`, so the
  /// fixes have to be in it too; the host API must not be.
  func testAFileFetchInsideAnIframeIsReportedAsServed() async throws {
    try writeFramedPage(frameBody: """
      const response = await fetch("settings.json");
      report({ ok: response.ok, status: response.status,
        type: response.headers.get("Content-Type"), body: await response.text(),
        missing: await fetch("missing.json").then(() => "resolved", () => "rejected") });
      """)
    let page = try await loadedPage(entry: "framed.html")
    defer { page.stop() }
    let reports = try await receivedReports(page, count: 1)
    XCTAssertEqual(reports[0]["ok"] as? Bool, true, "\(reports[0])")
    XCTAssertEqual(reports[0]["status"] as? Int, 200)
    XCTAssertEqual(reports[0]["type"] as? String, "application/json")
    XCTAssertEqual(reports[0]["body"] as? String, #"{"answer":42}"#, "the body must reach the frame unchanged")
    XCTAssertEqual(reports[0]["missing"] as? String, "rejected", "a missing file must still fail in a frame")
  }

  func testStreamingWasmInsideAnIframeStarts() async throws {
    // (module (func (export "f") (result i32) i32.const 42))
    try Data([
      0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00, 0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7F,
      0x03, 0x02, 0x01, 0x00, 0x07, 0x05, 0x01, 0x01, 0x66, 0x00, 0x00, 0x0A, 0x06, 0x01, 0x04,
      0x00, 0x41, 0x2A, 0x0B,
    ]).write(to: project.appendingPathComponent("answer.wasm"))
    try writeFramedPage(frameBody: """
      const streamed = await WebAssembly.instantiateStreaming(fetch("answer.wasm"), {});
      report({ answer: streamed.instance.exports.f() });
      """)
    let page = try await loadedPage(entry: "framed.html")
    defer { page.stop() }
    let reports = try await receivedReports(page, count: 1)
    XCTAssertEqual(reports[0]["answer"] as? Int, 42, "\(reports[0])")
  }

  func testXhrInsideASrcdocFrameSeesStatus200() async throws {
    try #"""
      <!doctype html><html><body><script>
      window.__reports = [];
      window.addEventListener("message", event => window.__reports.push(event.data));
      const frame = document.createElement("iframe");
      frame.srcdoc = `<!doctype html><script>
        const request = new XMLHttpRequest();
        request.open("GET", "settings.json", false);
        request.send();
        const missing = new XMLHttpRequest();
        missing.open("GET", "missing.json", false);
        try { missing.send(); } catch (_) {}
        parent.postMessage({ status: request.status, statusText: request.statusText,
          text: request.responseText, missing: missing.status }, "*");
      <\/script>`;
      document.body.appendChild(frame);
      </script></body></html>
      """#.write(to: project.appendingPathComponent("framed.html"), atomically: true, encoding: .utf8)
    let page = try await loadedPage(entry: "framed.html")
    defer { page.stop() }
    let reports = try await receivedReports(page, count: 1)
    XCTAssertEqual(reports[0]["status"] as? Int, 200, "\(reports[0])")
    XCTAssertEqual(reports[0]["statusText"] as? String, "OK")
    XCTAssertEqual(reports[0]["text"] as? String, #"{"answer":42}"#)
    XCTAssertEqual(reports[0]["missing"] as? Int, 0, "a missing file keeps WebKit's status in a frame")
  }

  func testSubframesDoNotReceiveTheAuthorApi() async throws {
    try writeFramedPage(frameBody: """
      report({
        host: typeof window.__mweWallpaperHost,
        audio: typeof window.wallpaperRegisterAudioListener,
        media: typeof window.wallpaperRegisterMediaStatusListener,
        random: typeof window.wallpaperRequestRandomFileForProperty,
        listener: "wallpaperPropertyListener" in window,
        compat: window.__mweFileCompat === true,
      });
      """)
    let page = try await loadedPage(entry: "framed.html")
    defer { page.stop() }
    let reports = try await receivedReports(page, count: 1)
    XCTAssertEqual(reports[0]["compat"] as? Bool, true, "the file fixes are in the frame: \(reports[0])")
    for key in ["host", "audio", "media", "random"] {
      XCTAssertEqual(reports[0][key] as? String, "undefined", "\(key) must stay in the main frame")
    }
    XCTAssertEqual(reports[0]["listener"] as? Bool, false)
    let main = try await evaluate(page, """
      return {
        host: typeof window.__mweWallpaperHost,
        audio: typeof window.wallpaperRegisterAudioListener,
        listener: "wallpaperPropertyListener" in window,
      };
      """)
    XCTAssertEqual(main["host"] as? String, "object")
    XCTAssertEqual(main["audio"] as? String, "function")
    XCTAssertEqual(main["listener"] as? Bool, true)
  }

  /// WebKit registers a message handler with every frame, so a frame can reach
  /// the channel without any help from the host script. The host must still
  /// treat only the wallpaper's own document as the one asking.
  func testAFrameCannotSubscribeToAudioThroughTheHostChannel() async throws {
    try writeFramedPage(frameBody: """
      let reachable = true;
      try {
        window.webkit.messageHandlers.\(WebWallpaperProtocol.messageHandlerName).postMessage({ type: "audioSubscribed" });
      } catch (error) { reachable = false; }
      report({ reachable });
      """)
    let page = WebWallpaperPage(projectURL: project, entryFile: "framed.html")
    var audio: [Bool] = []
    var media: [WebWallpaperPage.MediaDemand] = []
    page.onAudioDemandChanged = { audio.append($0) }
    page.onMediaDemandChanged = { media.append($0) }
    page.setAudioResponseEnabled(true)
    page.load()
    defer { page.stop() }
    try await waitUntilLoaded(page)
    let reports = try await receivedReports(page, count: 1)
    XCTAssertEqual(reports[0]["reachable"] as? Bool, true, "the channel is there for the frame to misuse")
    // Messages from one web process arrive in order: once the main frame's own
    // subscription has been seen, the frame's earlier one has been dealt with.
    _ = try await evaluate(page, "window.wallpaperRegisterMediaStatusListener(() => {}); return {};")
    try await poll { media.last?.listening == true }
    XCTAssertEqual(audio, [], "a frame must not open the audio capture for the wallpaper")
  }

  func testAFrameWithoutASourceSeesTheFixesToo() async throws {
    try """
      <!doctype html><html><body><script>
      window.__reports = [];
      const frame = document.createElement("iframe");
      document.body.appendChild(frame);
      const request = new frame.contentWindow.XMLHttpRequest();
      request.open("GET", "settings.json", false);
      request.send();
      window.__reports.push({ status: request.status, compat: frame.contentWindow.__mweFileCompat === true });
      </script></body></html>
      """.write(to: project.appendingPathComponent("framed.html"), atomically: true, encoding: .utf8)
    let page = try await loadedPage(entry: "framed.html")
    defer { page.stop() }
    let reports = try await receivedReports(page, count: 1)
    XCTAssertEqual(reports[0]["compat"] as? Bool, true, "\(reports[0])")
    XCTAssertEqual(reports[0]["status"] as? Int, 200)
  }

  // MARK: - the compat script on its own

  /// The same document can be handed the script twice (a frame that is
  /// re-created, a navigation that keeps the global); wrapping twice would stack
  /// a second layer on every request.
  func testInjectingTheFixesTwiceWrapsOnlyOnce() async throws {
    let page = try await loadedPage()
    defer { page.stop() }
    let result = try await page.webView.callAsyncJavaScript(
      """
      const fetchBefore = window.fetch;
      const statusBefore = Object.getOwnPropertyDescriptor(XMLHttpRequest.prototype, "status").get;
      (0, eval)(source);
      return {
        fetch: window.fetch === fetchBefore,
        status: Object.getOwnPropertyDescriptor(XMLHttpRequest.prototype, "status").get === statusBefore,
        hidden: !Object.keys(window).includes("__mweFileCompat"),
      };
      """, arguments: ["source": WebWallpaperProtocol.compatScript], in: nil, contentWorld: .page)
    let state = try XCTUnwrap(result as? [String: Any])
    XCTAssertEqual(state["fetch"] as? Bool, true)
    XCTAssertEqual(state["status"] as? Bool, true)
    XCTAssertEqual(state["hidden"] as? Bool, true, "the guard must not show up when a page lists its globals")
  }

  /// A page served over http(s) cannot read a project file, so a remote page a
  /// wallpaper embeds keeps the browser's own request functions.
  func testRemoteDocumentsKeepTheirOwnRequestFunctions() async throws {
    let configuration = WKWebViewConfiguration()
    configuration.userContentController.addUserScript(
      WKUserScript(source: WebWallpaperProtocol.compatScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.loadHTMLString("<!doctype html><html><body></body></html>", baseURL: URL(string: "https://example.invalid/")!)
    let deadline = Date().addingTimeInterval(10)
    while webView.isLoading && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    let value = try await webView.callAsyncJavaScript(
      """
      const native = f => Function.prototype.toString.call(f).includes("[native code]");
      return {
        protocol: location.protocol,
        fetch: native(window.fetch),
        status: native(Object.getOwnPropertyDescriptor(XMLHttpRequest.prototype, "status").get),
      };
      """, arguments: [:], in: nil, contentWorld: .page)
    let state = try XCTUnwrap(value as? [String: Any])
    XCTAssertEqual(state["protocol"] as? String, "https:")
    XCTAssertEqual(state["fetch"] as? Bool, true)
    XCTAssertEqual(state["status"] as? Bool, true)
  }

  private func writeFramedPage(frameBody: String) throws {
    try """
      <!doctype html><html><body><iframe src="frame.html"></iframe><script>
      window.__reports = [];
      window.addEventListener("message", event => window.__reports.push(event.data));
      </script></body></html>
      """.write(to: project.appendingPathComponent("framed.html"), atomically: true, encoding: .utf8)
    try """
      <!doctype html><html><body><script>
      const report = data => parent.postMessage(data, "*");
      (async () => {
      \(frameBody)
      })().catch(error => report({ error: String(error) }));
      </script></body></html>
      """.write(to: project.appendingPathComponent("frame.html"), atomically: true, encoding: .utf8)
  }

  private func receivedReports(_ page: WebWallpaperPage, count: Int) async throws -> [[String: Any]] {
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
      let value = try await page.webView.callAsyncJavaScript(
        "return window.__reports", arguments: [:], in: nil, contentWorld: .page)
      if let reports = value as? [[String: Any]], reports.count >= count { return reports }
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTFail("The page did not report \(count) result(s)")
    throw CancellationError()
  }

  private func poll(timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertTrue(condition(), "The page did not reach the requested state")
  }

  private func loadedPage(entry: String = "index.html") async throws -> WebWallpaperPage {
    let page = WebWallpaperPage(projectURL: project, entryFile: entry)
    page.load()
    try await waitUntilLoaded(page)
    XCTAssertNil(page.webView.window, "No desktop window is needed")
    return page
  }

  private func waitUntilLoaded(_ page: WebWallpaperPage) async throws {
    let deadline = Date().addingTimeInterval(10)
    while !page.isLoaded && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
    XCTAssertTrue(page.isLoaded)
  }

  private func evaluate(_ page: WebWallpaperPage, _ script: String) async throws -> [String: Any] {
    let value = try await page.webView.callAsyncJavaScript(
      script, arguments: [:], in: nil, contentWorld: .page)
    return try XCTUnwrap(value as? [String: Any])
  }
}
