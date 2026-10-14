import WebKit
import XCTest

@testable import WallpaperMachine

/// Exercises the shared compositor without ordering any window or changing wallpaper selections.
@MainActor
final class ScreenSaverWebSurfaceTests: XCTestCase {
  private var rootURL: URL!
  private var project: URL!
  private var surfaces: [ScreenSaverWebSurface] = []
  private var roots: [CALayer] = []

  override func setUpWithError() throws {
    rootURL = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("saver-web-\(UUID().uuidString)")
    project = rootURL.appendingPathComponent("project")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    try """
      <!doctype html><html><head><style>
      html,body { margin:0; width:100%; height:100%; background:rgb(0,255,0); }
      </style></head><body><canvas width="32" height="32"></canvas><script>
      window.state = {ticks:0, frames:0, gap:0, general:null, user:null, userKeys:[], directories:{}, capture:[]};
      let previous = performance.now();
      setInterval(() => {
        const now = performance.now(); state.gap = Math.max(state.gap, now-previous);
        previous = now; state.ticks++;
      }, 10);
      const context = document.querySelector('canvas').getContext('2d');
      const animate = () => {
        state.frames++;
        context.fillStyle = state.frames % 2 ? 'red' : 'blue'; context.fillRect(0,0,32,32);
        requestAnimationFrame(animate);
      };
      requestAnimationFrame(animate);
      window.wallpaperPropertyListener = {
        applyGeneralProperties(value) { state.general = value; },
        applyUserProperties(value) {
          state.user = value;
          state.userKeys.push(Object.keys(value).sort());
          if (value.cover) fetch('file:///' + value.cover.value).then(r => r.text()).then(t => state.file = t);
        },
        setPaused(value) { state.paused = value; },
        userDirectoryFilesAddedOrChanged(property, files) { state.directories[property] = files; },
        userDirectoryFilesRemoved(property, files) {
          state.directories[property] = (state.directories[property] || []).filter(file => !files.includes(file));
        }
      };
      window.wallpaperRegisterAudioListener(() => state.capture.push('audio-delivered'));
      window.wallpaperRegisterMediaStatusListener(value => state.media = value);
      </script></body></html>
      """.write(to: project.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
  }

  override func tearDownWithError() throws {
    surfaces.forEach { $0.stop() }
    surfaces.removeAll()
    roots.removeAll()
    try? FileManager.default.removeItem(at: rootURL)
  }

  private func make(entry: String = "index.html", properties: String = "{}", paused: Bool = false) throws -> ScreenSaverWebSurface {
    let surface = try ScreenSaverWebSurface(projectURL: project, entryFile: entry,
      readAccessURL: rootURL, size: CGSize(width: 128, height: 96), scale: 1,
      propertiesJSON: properties, fps: 30, paused: paused)
    surfaces.append(surface)
    let layer = CALayer()
    layer.frame = CGRect(x: 0, y: 0, width: 128, height: 96)
    try surface.attach(to: layer)
    roots.append(layer)
    return surface
  }

  private func start(_ surface: ScreenSaverWebSurface) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      surface.start { error in
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
      }
    }
  }

  private func state(_ surface: ScreenSaverWebSurface) async throws -> [String: Any] {
    let result = try await surface.webView.callAsyncJavaScript("return window.state", arguments: [:], in: nil, contentWorld: .page)
    return try XCTUnwrap(result as? [String: Any])
  }

  private func poll(timeout: Duration = .seconds(5), _ condition: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
      if try await condition() { return }
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTFail("Web content did not reach the requested state")
    throw ScreenSaverWebSurface.Failure.timedOut
  }

  func testReadinessIncludesActualContentAndLiveCanvasKeepsAnimating() async throws {
    let surface = try make()
    var firstFrame: NSImage?
    surface.onFrame = { firstFrame = $0 }
    try await start(surface)
    let image = try XCTUnwrap(firstFrame)
    let pixels = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
    XCTAssertEqual(pixels.width, 128)
    XCTAssertEqual(pixels.height, 96)
    let bitmap = NSBitmapImageRep(cgImage: pixels)
    let color = try XCTUnwrap(bitmap.colorAt(x: 80, y: 64)?.usingColorSpace(.sRGB))
    XCTAssertLessThan(color.redComponent, 0.1)
    XCTAssertGreaterThan(color.greenComponent, 0.9)
    XCTAssertLessThan(color.blueComponent, 0.1)
    let before = try await state(surface)
    try await Task.sleep(for: .milliseconds(150))
    let after = try await state(surface)
    XCTAssertGreaterThan(try XCTUnwrap(after["frames"] as? Int), try XCTUnwrap(before["frames"] as? Int))
    XCTAssertEqual((after["general"] as? [String: Any])?["fps"] as? Int, 30)
  }

  func testCommittedPropertiesAndOwnedSiblingFilesLoadWithAuthorPathConvention() async throws {
    let assets = rootURL.appendingPathComponent("user-assets")
    try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
    let file = assets.appendingPathComponent("chosen file.txt")
    try "published asset".write(to: file, atomically: true, encoding: .utf8)
    let json = try JSONSerialization.data(withJSONObject: [
      "cover": ["type": "file", "value": file.absoluteString],
      "gallery": ["type": "directory", "mode": "fetchall", "value": assets.absoluteString],
      "pick": ["type": "directory", "mode": "ondemand", "value": assets.absoluteString],
      "color": ["type": "color", "value": "1 0 0"],
    ])
    let surface = try make(properties: String(decoding: json, as: UTF8.self))
    try await start(surface)
    try await poll { try await self.state(surface)["file"] as? String == "published asset" }
    var received = try await state(surface)
    XCTAssertEqual(((received["user"] as? [String: Any])?["color"] as? [String: Any])?["value"] as? String, "1 0 0")
    let directories = try XCTUnwrap(received["directories"] as? [String: Any])
    let listedPath = try XCTUnwrap((directories["gallery"] as? [String])?.first)
    XCTAssertEqual(try String(contentsOf: XCTUnwrap(URL(string: "file:///" + listedPath)), encoding: .utf8),
      "published asset")
    XCTAssertNil(directories["pick"])
    _ = try await surface.webView.callAsyncJavaScript(
      "window.wallpaperRequestRandomFileForProperty('pick', (_id, file) => state.random = file)",
      arguments: [:], in: nil, contentWorld: .page)
    try await poll { try await self.state(surface)["random"] as? String != nil }
    let randomState = try await state(surface)
    let randomPath = try XCTUnwrap(randomState["random"] as? String)
    XCTAssertEqual(try String(contentsOf: XCTUnwrap(URL(string: "file:///" + randomPath)), encoding: .utf8),
      "published asset")
    try surface.update(propertiesJSON: "{\"color\":{\"type\":\"color\",\"value\":\"0 1 0\"}}", fps: 12, paused: false)
    try await poll { (try await self.state(surface)["general"] as? [String: Any])?["fps"] as? Int == 12 }
    received = try await state(surface)
    XCTAssertEqual(((received["user"] as? [String: Any])?["color"] as? [String: Any])?["value"] as? String, "0 1 0")
    XCTAssertEqual((received["directories"] as? [String: Any])?["gallery"] as? [String], [])
  }

  /// Every reconcile (a pause toggle, an FPS change) resends the whole committed set to the page;
  /// the host script hands the listener only what it has not already taken in.
  func testOnlyChangedPropertiesReachThePageAfterTheFirstDelivery() async throws {
    let both = #"{"color":{"type":"color","value":"1 0 0"},"size":{"type":"slider","value":3}}"#
    let surface = try make(properties: both)
    try await start(surface)
    var received = try await state(surface)
    XCTAssertEqual(received["userKeys"] as? [[String]], [["color", "size"]])

    try surface.update(propertiesJSON: both, fps: 12, paused: false)
    try await poll { (try await self.state(surface)["general"] as? [String: Any])?["fps"] as? Int == 12 }
    surface.setPaused(true)
    try await poll { surface.isPaused }
    surface.setPaused(false)
    try await poll { !surface.isPaused }
    try await poll { try await self.state(surface)["paused"] as? Bool == false }
    received = try await state(surface)
    XCTAssertEqual(
      received["userKeys"] as? [[String]], [["color", "size"]],
      "an FPS change and a pause toggle resend the same properties, which the page already has")

    try surface.update(
      propertiesJSON: #"{"color":{"type":"color","value":"0 1 0"},"size":{"type":"slider","value":3}}"#,
      fps: 12, paused: false)
    try await poll { (try await self.state(surface)["userKeys"] as? [[String]])?.count == 2 }
    received = try await state(surface)
    XCTAssertEqual(received["userKeys"] as? [[String]], [["color", "size"], ["color"]])
  }

  func testPauseSuspendsUncooperativeTimersAndResumeRestoresAnimation() async throws {
    let surface = try make()
    try await start(surface)
    surface.setPaused(true)
    try await poll { surface.isPaused }
    try await Task.sleep(for: .milliseconds(450))
    surface.setPaused(false)
    try await poll { !surface.isPaused }
    try await poll { (try await self.state(surface)["gap"] as? Double ?? 0) >= 400 }
    try await poll { try await self.state(surface)["paused"] as? Bool == false }
    let before = try await state(surface)
    try await Task.sleep(for: .milliseconds(100))
    let after = try await state(surface)
    XCTAssertGreaterThan(try XCTUnwrap(after["ticks"] as? Int), try XCTUnwrap(before["ticks"] as? Int))
    XCTAssertGreaterThan(try XCTUnwrap(after["frames"] as? Int), try XCTUnwrap(before["frames"] as? Int))
    XCTAssertEqual(after["paused"] as? Bool, false)
  }

  func testMalformedAndEscapingEntriesAndAssetsAreDenied() throws {
    for entry in ["", "../outside.html", "/etc/hosts", "missing.html"] {
      XCTAssertThrowsError(try make(entry: entry))
    }
    let outside = FileManager.default.temporaryDirectory.appendingPathComponent("outside-\(UUID().uuidString).html")
    try "outside".write(to: outside, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: outside) }
    try FileManager.default.createSymbolicLink(at: project.appendingPathComponent("escape.html"), withDestinationURL: outside)
    XCTAssertThrowsError(try make(entry: "escape.html"))
    XCTAssertThrowsError(try make(properties: "[]"))
    let data = try JSONSerialization.data(withJSONObject: ["cover": ["type": "file", "value": outside.absoluteString]])
    XCTAssertThrowsError(try make(properties: String(decoding: data, as: UTF8.self)))
  }

  func testStopCancelsReadinessAndSnapshotsAndAllowsReplacementSurface() async throws {
    let surface = try make()
    let ready = expectation(description: "Cancelled readiness")
    surface.start { error in XCTAssertTrue(error is CancellationError); ready.fulfill() }
    surface.stop()
    await fulfillment(of: [ready], timeout: 2)
    let snapshot = expectation(description: "Stopped snapshot")
    surface.snapshot { result in
      if case .success = result { XCTFail("Stopped page returned content") }
      snapshot.fulfill()
    }
    await fulfillment(of: [snapshot], timeout: 2)
    let replacement = try make()
    try await start(replacement)
    let replacementState = try await state(replacement)
    XCTAssertEqual(replacementState["paused"] as? Bool, false)
    replacement.setPaused(true)
    try await poll { replacement.isPaused }
    replacement.stop()
    XCTAssertTrue(replacement.isStopped)
    let next = try make()
    try await start(next)
    let nextState = try await state(next)
    XCTAssertEqual(nextState["paused"] as? Bool, false)
  }

  func testRelativeFileAndBrokenOptionalImageStillProduceContent() async throws {
    try "local property".write(to: project.appendingPathComponent("cover.txt"),
      atomically: true, encoding: .utf8)
    let entry = project.appendingPathComponent("index.html")
    let html = try String(contentsOf: entry, encoding: .utf8)
    try ("<img src='missing-optional.png'>" + html).write(to: entry, atomically: true, encoding: .utf8)
    let surface = try make(properties: #"{"cover":{"type":"file","value":"cover.txt"}}"#)
    try await start(surface)
    try await poll { try await self.state(surface)["file"] as? String == "local property" }
    let received = try await state(surface)
    XCTAssertEqual(received["paused"] as? Bool, false)
  }

  func testContentProcessFailureIsReportedAndStopsWithoutRestartLoop() async throws {
    let surface = try make()
    try await start(surface)
    var failure: Error?
    surface.onFailure = { failure = $0 }
    surface.webViewWebContentProcessDidTerminate(surface.webView)
    XCTAssertTrue(surface.isStopped)
    XCTAssertNotNil(failure)
    let failed = expectation(description: "Failed snapshot completes")
    surface.snapshot { result in
      if case .success = result { XCTFail("Failed page returned a new frame") }
      failed.fulfill()
    }
    await fulfillment(of: [failed], timeout: 2)
  }

  func testLoadFailureAfterPublicationIsBoundedAndStopsTheSurface() async throws {
    let surface = try make()
    try FileManager.default.removeItem(at: project.appendingPathComponent("index.html"))
    let failed = expectation(description: "Missing published entry fails")
    surface.start { error in
      XCTAssertNotNil(error)
      failed.fulfill()
    }
    await fulfillment(of: [failed], timeout: 5)
    XCTAssertTrue(surface.isStopped)
  }

  /// A project file fetched from a frame the page embeds is served like one fetched from the
  /// page itself, and the frame gets none of the host API.
  func testSubframesGetTheFileRequestFixesButNotTheHostApi() async throws {
    try #"{"answer":42}"#.write(to: project.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
    try """
      <!doctype html><html><body style="background:rgb(0,255,0)"><iframe src="frame.html"></iframe><script>
      window.reports = [];
      window.addEventListener("message", event => window.reports.push(event.data));
      </script></body></html>
      """.write(to: project.appendingPathComponent("framed.html"), atomically: true, encoding: .utf8)
    try """
      <!doctype html><html><body><script>
      (async () => {
        const response = await fetch("settings.json");
        const request = new XMLHttpRequest();
        request.open("GET", "settings.json", false);
        request.send();
        parent.postMessage({
          ok: response.ok, status: response.status, type: response.headers.get("Content-Type"),
          xhr: request.status, host: typeof window.__mweWallpaperHost,
          audio: typeof window.wallpaperRegisterAudioListener, listener: "wallpaperPropertyListener" in window,
        }, "*");
      })();
      </script></body></html>
      """.write(to: project.appendingPathComponent("frame.html"), atomically: true, encoding: .utf8)
    let surface = try make(entry: "framed.html")
    try await start(surface)
    var reports: [[String: Any]] = []
    try await poll {
      let value = try await surface.webView.callAsyncJavaScript(
        "return window.reports", arguments: [:], in: nil, contentWorld: .page)
      reports = (value as? [[String: Any]]) ?? []
      return !reports.isEmpty
    }
    let report = try XCTUnwrap(reports.first)
    XCTAssertEqual(report["ok"] as? Bool, true, "\(report)")
    XCTAssertEqual(report["status"] as? Int, 200)
    XCTAssertEqual(report["type"] as? String, "application/json")
    XCTAssertEqual(report["xhr"] as? Int, 200)
    XCTAssertEqual(report["host"] as? String, "undefined")
    XCTAssertEqual(report["audio"] as? String, "undefined")
    XCTAssertEqual(report["listener"] as? Bool, false)
    let main = try await surface.webView.callAsyncJavaScript(
      "return typeof window.__mweWallpaperHost", arguments: [:], in: nil, contentWorld: .page)
    XCTAssertEqual(main as? String, "object")
  }

  func testAudioAndDisplayCaptureAreDeniedWithoutHostSubscription() async throws {
    let surface = try make()
    try await start(surface)
    let result = try await surface.webView.callAsyncJavaScript("""
      const denied = [];
      for (const name of ['getUserMedia', 'getDisplayMedia']) {
        if (typeof navigator.mediaDevices?.[name] !== 'function') { denied.push(true); continue; }
        try { await navigator.mediaDevices[name]({audio:true, video:true}); denied.push(false); }
        catch (error) { denied.push(error.name === 'NotAllowedError'); }
      }
      return {denied, audio:state.capture, media:state.media};
      """, arguments: [:], in: nil, contentWorld: .page)
    let reply = try XCTUnwrap(result as? [String: Any])
    XCTAssertEqual(reply["denied"] as? [Bool], [true, true])
    XCTAssertEqual(reply["audio"] as? [String], [])
    XCTAssertEqual((reply["media"] as? [String: Any])?["enabled"] as? Bool, false)
    XCTAssertEqual(surface.webView.value(forKey: "_mediaMutedState") as? UInt, 7)
  }
}
