import ImageIO
import UniformTypeIdentifiers
import WebKit
import XCTest

@testable import WallpaperMachine

/// Stands in for WebKit's scheme task so a load can be started, stopped and restarted on
/// the same object identity, which is what a freed-and-reallocated task looks like.
private final class FakeSchemeTask: NSObject, WKURLSchemeTask {
  var request: URLRequest
  var responses: [URLResponse] = []
  var body = Data()
  var finished = 0
  var failures: [Error] = []
  var onSettle: (() -> Void)?

  init(_ url: URL) { request = URLRequest(url: url) }

  func didReceive(_ response: URLResponse) { responses.append(response) }
  func didReceive(_ data: Data) { body.append(data) }
  func didFinish() {
    finished += 1
    onSettle?()
  }
  func didFailWithError(_ error: Error) {
    failures.append(error)
    onSettle?()
  }
}

/// Answers Steam preview requests only once the test releases it.
private final class GatedFetcher: WorkshopThumbnailFetching, @unchecked Sendable {
  private let lock = NSLock()
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private var released = false
  private let payload: Data

  init(payload: Data) { self.payload = payload }

  func release() {
    lock.lock()
    released = true
    let waiters = self.waiters
    self.waiters = []
    lock.unlock()
    waiters.forEach { $0.resume() }
  }

  func fetch(_ url: URL) async throws -> Data {
    await withCheckedContinuation { continuation in
      lock.lock()
      if released {
        lock.unlock()
        continuation.resume()
      } else {
        waiters.append(continuation)
        lock.unlock()
      }
    }
    return payload
  }
}

@MainActor
final class WebPanelAssetsTests: XCTestCase {
  func testThumbnailRouteServesOnlyAnnouncedSecurePreviews() throws {
    let assets = WebPanelAssets()
    let steam = try XCTUnwrap(URL(string: "https://images.steamusercontent.com/ugc/1/A/"))
    let insecure = try XCTUnwrap(URL(string: "http://images.steamusercontent.com/ugc/2/B/"))
    assets.thumbnails = ["100": steam, "200": insecure]

    XCTAssertEqual(assets.route(try XCTUnwrap(URL(string: "mwe-ui://thumbnail/100"))), .thumbnail(steam))
    XCTAssertNil(assets.route(try XCTUnwrap(URL(string: "mwe-ui://thumbnail/200"))))
    XCTAssertNil(assets.route(try XCTUnwrap(URL(string: "mwe-ui://thumbnail/300"))))
    XCTAssertNil(assets.route(try XCTUnwrap(URL(string: "mwe-ui://thumbnail:8080/100"))))
    XCTAssertNil(assets.route(try XCTUnwrap(URL(string: "https://thumbnail/100"))))
    XCTAssertEqual(assets.route(try XCTUnwrap(URL(string: "mwe-ui://animated/100"))), .animated(steam))
    XCTAssertNil(assets.route(try XCTUnwrap(URL(string: "mwe-ui://animated/200"))))
    XCTAssertNil(assets.route(try XCTUnwrap(URL(string: "mwe-ui://preview-cdn/100"))))

    assets.thumbnails = [:]
    XCTAssertNil(assets.route(try XCTUnwrap(URL(string: "mwe-ui://thumbnail/100"))))
    XCTAssertNil(assets.route(try XCTUnwrap(URL(string: "mwe-ui://animated/100"))))
  }

  func testLibraryThumbnailRouteServesOnlyAnnouncedIdsAndAcceptsOnlyTheRevisionQuery() throws {
    let assets = WebPanelAssets()
    let file = URL(fileURLWithPath: "/library/42/preview.gif")
    assets.libraryThumbnails = ["42": file]
    func route(_ address: String) throws -> WebPanelAssets.Route? {
      assets.route(try XCTUnwrap(URL(string: address)))
    }

    XCTAssertEqual(try route("mwe-ui://library-thumbnail/42"), .libraryThumbnail(file))
    XCTAssertEqual(try route("mwe-ui://library-thumbnail/42?v=0"), .libraryThumbnail(file))
    XCTAssertEqual(try route("mwe-ui://library-thumbnail/42?v=18446744073709551615"), .libraryThumbnail(file))
    XCTAssertNil(try route("mwe-ui://library-thumbnail/43"), "an id the snapshot did not announce")
    for refused in [
      "mwe-ui://library-thumbnail/42?v=", "mwe-ui://library-thumbnail/42?v=1a", "mwe-ui://library-thumbnail/42?v=-1",
      "mwe-ui://library-thumbnail/42?v=1&w=2", "mwe-ui://library-thumbnail/42?w=1", "mwe-ui://library-thumbnail/42?",
      "mwe-ui://library-thumbnail/42?v=1#fragment", "mwe-ui://library-thumbnail:8080/42",
      "mwe-ui://someone@library-thumbnail/42", "mwe-ui://library-thumbnails/42", "mwe-ui://library-thumbnail.example/42",
      "https://library-thumbnail/42",
    ] {
      XCTAssertNil(try route(refused), refused)
    }
    XCTAssertNil(try route("mwe-ui://thumbnail/42"), "Workshop thumbnails come from their own map")
    assets.libraryThumbnails = [:]
    XCTAssertNil(try route("mwe-ui://library-thumbnail/42"))
  }

  func testLibraryThumbnailAnswersASmallJpegAndNeverReadsOutsideTheLibrary() async throws {
    let home = FileManager.default.temporaryDirectory
      .appendingPathComponent("mwe-assets-\(UUID().uuidString)", isDirectory: true)
    let previous = ProcessInfo.processInfo.environment["WALLPAPER_MACHINE_HOME"]
    setenv("WALLPAPER_MACHINE_HOME", home.path, 1)
    defer {
      if let previous { setenv("WALLPAPER_MACHINE_HOME", previous, 1) } else { unsetenv("WALLPAPER_MACHINE_HOME") }
      try? FileManager.default.removeItem(at: home)
    }
    let inside = ClientPaths.libraryURL.appendingPathComponent("42/preview.png")
    let outside = home.appendingPathComponent("Elsewhere/preview.png")
    for file in [inside, outside] {
      try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Self.png(width: 1600, height: 900).write(to: file)
    }
    let covers = home.appendingPathComponent("covers", isDirectory: true)
    let assets = WebPanelAssets(
      libraryThumbnailCache: WorkshopThumbnailCache(
        directory: covers, fetcher: LibraryPreviewFetcher(), keepsAnimation: false))
    assets.libraryThumbnails = ["42": inside, "99": outside]
    let webView = WKWebView()

    func load(_ address: String) async throws -> FakeSchemeTask {
      let task = FakeSchemeTask(try XCTUnwrap(URL(string: address)))
      let settled = expectation(description: "\(address) settles")
      task.onSettle = { settled.fulfill() }
      assets.webView(webView, start: task)
      await fulfillment(of: [settled], timeout: 10)
      return task
    }

    let served = try await load("mwe-ui://library-thumbnail/42?v=3")
    XCTAssertTrue(served.failures.isEmpty, "\(served.failures)")
    XCTAssertEqual((served.responses.first as? HTTPURLResponse)?.statusCode, 200)
    XCTAssertEqual(served.responses.first?.mimeType, "image/jpeg")
    let source = try XCTUnwrap(CGImageSourceCreateWithData(served.body as CFData, nil))
    let cover = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    XCTAssertEqual(cover.width, 512, "The tile gets a downscaled cover, not the preview file")
    XCTAssertEqual(cover.height, 288)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: covers.path).filter { !$0.hasSuffix(".jpg") }, [])

    let refused = try await load("mwe-ui://library-thumbnail/99")
    XCTAssertTrue(refused.responses.isEmpty, "A preview outside the library is never read")
    XCTAssertEqual(refused.failures.count, 1)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: covers.path).filter { $0.hasSuffix(".jpg") }.count, 1)
  }

  func testRestartedTaskStillReceivesItsResponse() async throws {
    let home = FileManager.default.temporaryDirectory
      .appendingPathComponent("mwe-assets-\(UUID().uuidString)", isDirectory: true)
    let previous = ProcessInfo.processInfo.environment["WALLPAPER_MACHINE_HOME"]
    setenv("WALLPAPER_MACHINE_HOME", home.path, 1)
    defer {
      if let previous { setenv("WALLPAPER_MACHINE_HOME", previous, 1) } else { unsetenv("WALLPAPER_MACHINE_HOME") }
      try? FileManager.default.removeItem(at: home)
    }
    let folder = ClientPaths.libraryURL.appendingPathComponent("42", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let preview = folder.appendingPathComponent("preview.png")
    let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])
    try bytes.write(to: preview)

    let fetcher = GatedFetcher(payload: try Self.png(width: 32, height: 32))
    let cache = WorkshopThumbnailCache(
      directory: home.appendingPathComponent("thumbs", isDirectory: true), fetcher: fetcher)
    let assets = WebPanelAssets(thumbnailCache: cache)
    let steam = try XCTUnwrap(URL(string: "https://images.steamusercontent.com/ugc/1/A/"))
    assets.previews = ["42": preview]
    assets.thumbnails = ["100": steam]
    let webView = WKWebView()
    let task = FakeSchemeTask(try XCTUnwrap(URL(string: "mwe-ui://preview/42")))

    // WebKit stops the first load, frees the task, and the next load lands on the same
    // identity. The stale job finishes first and must neither answer nor evict the fresh one.
    assets.webView(webView, start: task)
    assets.webView(webView, stop: task)
    task.request = URLRequest(url: try XCTUnwrap(URL(string: "mwe-ui://thumbnail/100")))
    let settled = expectation(description: "restarted load settles")
    task.onSettle = { settled.fulfill() }
    assets.webView(webView, start: task)
    try await Task.sleep(for: .milliseconds(300))
    XCTAssertTrue(task.responses.isEmpty, "the stopped load must stay silent")
    fetcher.release()
    await fulfillment(of: [settled], timeout: 5)

    XCTAssertEqual(task.finished, 1)
    XCTAssertTrue(task.failures.isEmpty, "\(task.failures)")
    XCTAssertEqual((task.responses.first as? HTTPURLResponse)?.statusCode, 200)
    XCTAssertEqual(task.responses.first?.mimeType, "image/jpeg")
    XCTAssertFalse(task.body.isEmpty)
    XCTAssertNotEqual(task.body, bytes, "the stopped file load must not leak into the restarted one")
  }

  private static func png(width: Int, height: Int) throws -> Data {
    let output = NSMutableData()
    let destination = try XCTUnwrap(
      CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil))
    let context = try XCTUnwrap(
      CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return output as Data
  }

  func testServesEveryBundledPanelFile() throws {
    let assets = WebPanelAssets()
    // Every file the bundle ships under WebUI/, so a new module that was not allowlisted
    // fails here rather than as a blank panel.
    let root = try XCTUnwrap(Bundle.main.resourceURL).appendingPathComponent("WebUI", isDirectory: true)
    let enumerator = try XCTUnwrap(
      FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]))
    let names = try enumerator.compactMap { $0 as? URL }
      .filter { try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true }
      .map { String($0.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1)) }
    XCTAssertTrue(names.contains("index.html"), "\(names)")
    let locales = AppLanguage.supported.map(\.tag).filter { $0 != "en" }.map { "locales/\($0).js" }
    XCTAssertFalse(locales.isEmpty)
    for name in Set(names + locales) {
      let route = assets.route(try XCTUnwrap(URL(string: "mwe-ui://app/\(name)")))
      guard case .file(let file)? = route else {
        XCTFail("\(name) is bundled but not served; allowlist it in WebPanelAssets")
        continue
      }
      XCTAssertTrue(file.path.hasSuffix("/WebUI/\(name)"), file.path)
      XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "\(name) is not bundled")
    }
    XCTAssertNil(assets.route(try XCTUnwrap(URL(string: "mwe-ui://app/missing.js"))))
    XCTAssertNil(assets.route(try XCTUnwrap(URL(string: "mwe-ui://app/locales/en.js"))))
    XCTAssertNil(assets.route(try XCTUnwrap(URL(string: "mwe-ui://app/locales/../panel.js"))))
  }
}
