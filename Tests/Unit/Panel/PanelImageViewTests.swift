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
}
