import AppKit
import SwiftUI
import XCTest

@testable import WallpaperMachine

/// `PanelImage` in an offscreen window: it asks the pipeline for exactly what it shows, at the
/// size it is drawn, and fills the space it is given before and after the image arrives.
@MainActor
final class PanelImageViewTests: XCTestCase {
  func testItLoadsItsSourceAtTheDrawnSizeAndKeepsItsFrameWhileLoading() async throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(
      "panel-image-view-\(UUID().uuidString)", isDirectory: true)
    let library = home.appendingPathComponent("Library", isDirectory: true)
    try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let file = library.appendingPathComponent("1/preview.png")
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try PanelImagePipelineTests.png(width: 1600, height: 900).write(to: file)
    let pipeline = PanelImagePipeline(
      thumbnailCache: WorkshopThumbnailCache(directory: home.appendingPathComponent("steam"), fetcher: PreviewFetcher { _ in Data() }),
      pixivThumbnailCache: WorkshopThumbnailCache(directory: home.appendingPathComponent("pixiv"), fetcher: PreviewFetcher { _ in Data() }),
      libraryThumbnailCache: WorkshopThumbnailCache(
        directory: home.appendingPathComponent("covers"), fetcher: LibraryPreviewFetcher(root: library),
        keepsAnimation: false),
      libraryRoot: { library })
    let source = PanelImageSource.libraryPreview(file: file)
    let host = NSHostingView(
      rootView: PanelImage(source: source, pointSize: 100)
        .environment(\.panelImages, pipeline)
        .environment(\.displayScale, 2)
        .frame(width: 140, height: 140))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled], backing: .buffered,
      defer: true)
    window.isReleasedWhenClosed = false
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    XCTAssertFalse(window.isVisible, "the window stays offscreen")
    let before = host.fittingSize

    // 100 points at a display scale of 2 is a 200 px decode, never the 1600 px file.
    let deadline = Date().addingTimeInterval(5)
    while pipeline.cachedImage(for: source, maxPixelSize: 200) == nil, Date() < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    let loaded = try XCTUnwrap(
      pipeline.cachedImage(for: source, maxPixelSize: 200), "the view loaded its source when it appeared")
    XCTAssertEqual(loaded.pixelSize.width, 200)
    XCTAssertEqual(loaded.pixelSize.height, 112.5, accuracy: 1)
    host.layoutSubtreeIfNeeded()
    XCTAssertEqual(host.fittingSize, before, "an image arriving moves nothing")
    window.close()
  }

  func testScrollingReleasesEvictedImagesAndReloadsThemOnReturn() async throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("panel-image-scroll-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: home) }
    let data = try PanelImagePipelineTests.png(width: 256, height: 256)
    let cache = NSCache<NSString, DecodedPanelImage>()
    let pipeline = PanelImagePipeline(
      thumbnailCache: WorkshopThumbnailCache(
        directory: home.appendingPathComponent("steam"), fetcher: PreviewFetcher { _ in data }),
      pixivThumbnailCache: WorkshopThumbnailCache(directory: home.appendingPathComponent("pixiv")),
      libraryThumbnailCache: WorkshopThumbnailCache(directory: home.appendingPathComponent("covers")),
      libraryRoot: { home }, memory: cache)
    let state = ImageScrollState()
    let host = NSHostingView(rootView: ImageScrollProbe(state: state).environment(\.panelImages, pipeline))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 240, height: 240), styleMask: [.titled], backing: .buffered,
      defer: true)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer {
      window.contentView = nil
      window.close()
    }
    host.layoutSubtreeIfNeeded()
    let first = ImageScrollProbe.source(0)
    try await waitUntil(host) { pipeline.cachedImage(for: first, maxPixelSize: 128) != nil }
    weak let original = pipeline.cachedImage(for: first, maxPixelSize: 128)
    weak let pixels = original?.cgImage
    XCTAssertNotNil(original)

    state.target = 99
    try await waitUntil(host) { state.appeared.contains(99) && !state.appeared.contains(0) }
    cache.removeAllObjects()
    try await waitUntil(host) { original == nil }
    XCTAssertNil(original, "lazy rows must not retain decoded pixels after scrolling away and cache eviction")
    try await waitUntil(host) { pixels == nil }
    XCTAssertNil(pixels, "the rendered image must release its pixels too, not just the pipeline wrapper")

    state.target = 0
    try await waitUntil(host) { state.appeared.contains(0) && pipeline.cachedImage(for: first, maxPixelSize: 128) != nil }
    XCTAssertEqual(pipeline.cachedImage(for: first, maxPixelSize: 128)?.pixelSize, CGSize(width: 128, height: 128))

    // Returning to an image still in cache must own it while visible, then release it again.
    weak let cached = pipeline.cachedImage(for: first, maxPixelSize: 128)
    weak let cachedPixels = cached?.cgImage
    state.target = 99
    try await waitUntil(host) { state.appeared.contains(99) && !state.appeared.contains(0) }
    state.target = 0
    try await waitUntil(host) { state.appeared.contains(0) && !state.appeared.contains(99) }
    cache.removeAllObjects()
    XCTAssertNotNil(cached, "cache eviction must not discard the visible row's image")
    state.target = 99
    try await waitUntil(host) { state.appeared.contains(99) && !state.appeared.contains(0) }
    try await waitUntil(host) { cached == nil && cachedPixels == nil }
    XCTAssertFalse(window.isVisible)
  }

  private func waitUntil(
    _ host: NSView, file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool
  ) async throws {
    let deadline = Date().addingTimeInterval(10)
    while !condition(), Date() < deadline {
      host.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertTrue(condition(), file: file, line: line)
  }
}

@MainActor @Observable
private final class ImageScrollState {
  var target = 0
  var appeared = Set<Int>()
}

private struct ImageScrollProbe: View {
  let state: ImageScrollState

  static func source(_ id: Int) -> PanelImageSource {
    .steamThumbnail(URL(string: "https://images.steamusercontent.com/ugc/\(id)/preview.png")!)
  }

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack {
          ForEach(0..<100) { id in
            PanelImage(source: Self.source(id), pointSize: 128)
              .frame(width: 200, height: 200)
              .id(id)
              .onAppear { state.appeared.insert(id) }
              .onDisappear { state.appeared.remove(id) }
          }
        }
      }
      .onChange(of: state.target) { _, target in proxy.scrollTo(target, anchor: .top) }
    }
    .environment(\.displayScale, 1)
  }
}
