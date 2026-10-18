import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import XCTest

@testable import WallpaperMachine

/// Answers every Steam browse request with the page of items a test chose, so Discover shows real
/// tiles without reaching Steam. The page is the render context Steam's own markup carries.
final class WorkshopBrowseProtocol: URLProtocol, @unchecked Sendable {
  struct Row {
    var id: String
    var title: String
    var kind = "Scene"
    var creator = "76561198000000001"
    var summary = "A slow pan across a northern fjord under shifting aurora. Reacts to music."
    var tags: [String] = []
    var size: Int64 = 281_000_000
    var subscriptions = 48_200
    var preview: String?
    var collectionChildren: [String]?

    var json: [String: Any] {
      var row: [String: Any] = [
        "publishedfileid": id, "consumer_appid": 431960, "title": title, "creator": creator,
        "short_description": summary, "tags": ([kind] + tags).map { ["tag": $0] },
        "file_size": String(size), "subscriptions": subscriptions,
      ]
      if let preview { row["preview_url"] = preview }
      if let collectionChildren {
        row["file_type"] = 2
        row["children"] = collectionChildren.map { ["publishedfileid": $0] }
      }
      return row
    }
  }

  nonisolated(unsafe) private static var current = Page(rows: [], pages: 1, count: 0)
  nonisolated(unsafe) private static var served: [URL] = []
  private static let lock = NSLock()

  /// The browse requests answered since the last `serve`, oldest first.
  static var requests: [URL] { lock.withLock { served } }

  /// The `p` (page) of each request, and the `searchtext`.
  static func values(_ name: String, in url: URL) -> String? {
    URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
      .first { $0.name == name }?.value
  }

  struct Page {
    var rows: [Row]
    var pages: Int
    var count: Int
  }

  /// What the next browse request answers.
  static func serve(_ rows: [Row], pages: Int = 1, count: Int? = nil) {
    lock.withLock {
      current = Page(rows: rows, pages: pages, count: count ?? rows.count)
      served = []
    }
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let url = request.url else { return }
    guard url.host == "steamcommunity.com", url.path.contains("/workshop/browse") else {
      client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
      return
    }
    let page = Self.lock.withLock { () -> Page in
      Self.served.append(url)
      return Self.current
    }
    let requested = Int(
      URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
        .first { $0.name == "p" }?.value ?? "1") ?? 1
    let queries: [[String: Any]] = [
      [
        "queryKey": ["workshop_browse"],
        "state": [
          "data": [
            "eresult": 1, "current_page": requested, "total_pages": page.pages,
            "total_count": page.count, "results": page.rows.map(\.json),
          ]
        ],
      ]
    ]
    let body: Data
    do {
      let queryData = String(
        decoding: try JSONSerialization.data(withJSONObject: ["queries": queries]), as: UTF8.self)
      let ssr = String(
        decoding: try JSONSerialization.data(
          withJSONObject: ["renderContext": ["queryData": queryData]]), as: UTF8.self)
      body = Data(
        "<html><script type=\"application/json\" id=\"valve-ssr-data\">\(ssr)</script></html>".utf8)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
      return
    }
    client?.urlProtocol(
      self,
      didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!,
      cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: body)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

/// A Discover panel over its own temporary folder, stores and a Workshop store that reads
/// `WorkshopBrowseProtocol`, with a fetcher that answers every Steam picture from a closure.
struct DiscoverPanel {
  let controller: PanelController
  let workshop: WorkshopStore
  let store: BridgeStore
  let dialogs: RecordingDialogs
  let presentation: PanelPresentation
  let root: URL
  let defaults: UserDefaults
  let theme: AppThemeStore
}

extension MediaPanelTestCase {
  /// - Parameters:
  ///   - steamImage: The bytes of Steam's picture for a preview URL; an animation when it is a GIF
  ///     of several frames.
  func makeDiscoverPanel(
    steamImage: @escaping @Sendable (URL) throws -> Data = { _ in try DiscoverPictures.flat() },
    welcomeSeen: Bool = true, language: String = "en"
  ) throws -> DiscoverPanel {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "panel-discover-\(UUID().uuidString)")
    let defaults = try TemporaryDefaults.make(for: self).defaults
    if welcomeSeen { PanelPreferences.markWelcomeSeen(in: defaults) }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [WorkshopBrowseProtocol.self]
    let workshop = WorkshopStore(
      service: WorkshopService(session: URLSession(configuration: configuration)),
      downloader: WorkshopDownloadManager(sessionDirectory: root.appendingPathComponent("session")),
      supportDirectory: root, defaults: defaults)
    let pixiv = PixivStore(
      service: PixivService(
        transport: PixivFixtureTransport { _ in throw URLError(.notConnectedToInternet) },
        minimumInterval: .zero),
      packager: PixivWallpaperPackager(library: root.appendingPathComponent("Library")),
      sessions: PixivMemorySessionStore())
    let store = makeStore().store
    let dialogs = RecordingDialogs()
    let presentation = PanelPresentation()
    let theme = AppThemeStore(defaults: defaults)
    let previousHome = ProcessInfo.processInfo.environment["WALLPAPER_MACHINE_HOME"]
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    setenv("WALLPAPER_MACHINE_HOME", root.path, 1)
    let images = PanelImagePipeline(
      thumbnailCache: WorkshopThumbnailCache(
        directory: root.appendingPathComponent("thumbnails"),
        fetcher: PreviewFetcher(respond: steamImage)),
      pixivThumbnailCache: WorkshopThumbnailCache(
        directory: root.appendingPathComponent("pixiv-thumbnails"),
        fetcher: PreviewFetcher { _ in throw URLError(.notConnectedToInternet) }),
      libraryThumbnailCache: WorkshopThumbnailCache(
        directory: root.appendingPathComponent("library-thumbnails"),
        fetcher: LibraryPreviewFetcher(root: root.appendingPathComponent("Library")),
        keepsAnimation: false),
      libraryRoot: { root.appendingPathComponent("Library") })
    let controller = PanelController(
      store: store, navigation: ControlPanelNavigation(selection: .workshop), workshop: workshop,
      pixiv: pixiv, presentation: presentation, theme: theme, defaults: defaults, images: images,
      dialogs: dialogs,
      appLanguage: language == "en"
        ? .english() : AppLanguageStore(defaults: defaults, systemLanguages: [language]))
    addTeardownBlock { @MainActor in
      controller.stop()
      workshop.cancelSearch()
      await workshop.downloader.shutdown()
      await workshop.steamCMDSetup.shutdown()
      await pixiv.downloads.shutdown()
      if let previousHome { setenv("WALLPAPER_MACHINE_HOME", previousHome, 1) }
      else { unsetenv("WALLPAPER_MACHINE_HOME") }
      try? FileManager.default.removeItem(at: root)
    }
    return DiscoverPanel(
      controller: controller, workshop: workshop, store: store, dialogs: dialogs,
      presentation: presentation, root: root, defaults: defaults, theme: theme)
  }
}

// MARK: - Fixture pictures

enum DiscoverPictures {
  /// A one-frame GIF of one grey, which every picture answers unless a test says otherwise.
  static func flat(brightness: Double = 0.55) throws -> Data {
    try gif(frames: 1, brightness: brightness)
  }

  /// A GIF of `frames` greys that differ frame to frame, 0.1 s each.
  static func gif(frames: Int, brightness: Double) throws -> Data {
    let output = NSMutableData()
    let destination = try XCTUnwrap(
      CGImageDestinationCreateWithData(output, UTType.gif.identifier as CFString, frames, nil))
    for frame in 0..<frames {
      let context = try XCTUnwrap(
        CGContext(
          data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      context.setFillColor(gray: min(1, brightness + Double(frame) * 0.05), alpha: 1)
      context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
      let properties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]]
      CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), properties as CFDictionary)
    }
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return output as Data
  }

  /// A PNG of a two-band landscape: a sky over a ground, so a tile looks like a wallpaper.
  static func landscape(sky: (Double, Double, Double), ground: (Double, Double, Double)) throws -> Data {
    let width = 640
    let height = 640
    let context = try XCTUnwrap(
      CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let colors = [
      CGColor(red: sky.0, green: sky.1, blue: sky.2, alpha: 1),
      CGColor(red: sky.0 * 0.5 + 0.1, green: sky.1 * 0.5 + 0.1, blue: sky.2 * 0.5 + 0.2, alpha: 1),
    ]
    let gradient = try XCTUnwrap(CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1]))
    context.drawLinearGradient(
      gradient, start: CGPoint(x: 0, y: CGFloat(height)), end: CGPoint(x: 0, y: CGFloat(height) * 0.35), options: [])
    context.setFillColor(CGColor(red: ground.0, green: ground.1, blue: ground.2, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: Int(Double(height) * 0.35)))
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.18))
    context.fillEllipse(in: CGRect(x: CGFloat(width) * 0.62, y: CGFloat(height) * 0.55, width: 120, height: 120))
    let image = try XCTUnwrap(context.makeImage())
    let output = NSMutableData()
    let destination = try XCTUnwrap(
      CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return output as Data
  }
}

// MARK: - Hosting

/// The panel in a window that is never shown, built from a controller the test made: the same root
/// `ControlPanelView` builds, over the test's own stores and pictures.
@MainActor
final class PanelHost {
  let controller: PanelController
  let window: NSWindow
  let hosting: NSHostingController<AnyView>

  init(controller: PanelController, language: String = "en") {
    self.controller = controller
    PanelLocale.shared.bind(to: controller.appLanguage)
    hosting = NSHostingController(
      rootView: AnyView(
        PanelRootView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .environment(controller)
          .environment(\.panelImages, controller.images)))
    hosting.sizingOptions = []
    hosting.sceneBridgingOptions = [.toolbars, .title]
    window = ControlPanelWindow.make(contentViewController: hosting, delegate: nil)
  }

  func layout(at size: NSSize) {
    window.setContentSize(size)
    window.layoutIfNeeded()
    hosting.view.layoutSubtreeIfNeeded()
  }

  /// Lets the run loop turn so SwiftUI lays out and loads what it was asked to.
  func settle(_ seconds: Double = 0.4) async throws {
    try await Task.sleep(for: .seconds(seconds))
    hosting.view.layoutSubtreeIfNeeded()
  }

  func appearance(_ name: NSAppearance.Name?) {
    hosting.view.appearance = name.flatMap(NSAppearance.init(named:))
    window.appearance = name.flatMap(NSAppearance.init(named:))
  }

  /// The widest split view inside the window's content: wider than the window means the panel asks
  /// for more room than it was given.
  var widestSplitView: CGFloat {
    func widest(_ view: NSView) -> CGFloat {
      let own = (view as? NSSplitView)?.frame.width ?? 0
      return view.subviews.map(widest).reduce(own, max)
    }
    return widest(window.contentView!)
  }

  func close() {
    window.contentViewController = nil
    window.close()
  }

  /// A PNG of the hosting view as drawn now, for the visual review only. The window's own frame
  /// (title bar, toolbar, inspector) is captured beside it.
  func snapshot(to url: URL) throws {
    try capture(hosting.view, to: url)
    if let frame = window.contentView?.superview {
      try capture(
        frame, to: url.deletingPathExtension().appendingPathExtension("frame.png"))
    }
  }

  private func capture(_ view: NSView, to url: URL) throws {
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
    view.cacheDisplay(in: view.bounds, to: rep)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try rep.representation(using: .png, properties: [:])?.write(to: url)
  }
}
