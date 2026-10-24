import XCTest

@testable import WallpaperMachine

/// The preview of a plain video plays with the app's own players, never the scene engine. No window and
/// no decoding of a real picture here: what is checked is what the surface does with a file neither
/// player takes, how it is released, and that it has no properties to follow.
@MainActor
final class VideoWallpaperPreviewSurfaceTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "video-preview-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

  private func surface(entry: String) throws -> VideoWallpaperPreviewSurface {
    let request = try WallpaperPreviewRequest(
      .init(
        wallpaperId: "clip", title: "Clip", kind: .video, projectPath: root.path, entryFile: entry,
        assetsPath: root.path, propertiesJson: "{}", fps: 30, scalingMode: .fill, scalingFactor: 1,
        volume: 0.5))
    return VideoWallpaperPreviewSurface(request: request)
  }

  func testAFileNeitherPlayerTakesIsAFailedPreviewWithTheReasonAndNothingElseDrawsIt() async throws {
    try Data("not a movie".utf8).write(to: root.appendingPathComponent("clip.mp4"))
    let surface = try surface(entry: "clip.mp4")
    defer { surface.stop() }
    do {
      try await surface.start()
      XCTFail("a file that is not a video must not play")
    } catch let failure as WallpaperPreviewFailure {
      XCTAssertFalse(failure.message.isEmpty, "the reason is the player's own, never blank")
    }
  }

  func testAMissingFileIsAFailedPreviewToo() async throws {
    let surface = try surface(entry: "missing.mp4")
    defer { surface.stop() }
    do {
      try await surface.start()
      XCTFail("a file that is not there must not play")
    } catch is WallpaperPreviewFailure {
    }
  }

  func testAVideoHasNoPropertiesToFollowAndStopIsIdempotent() throws {
    let surface = try surface(entry: "clip.mp4")
    XCTAssertNoThrow(try surface.applyProperties(#"{"size":{"type":"slider","value":3}}"#))
    XCTAssertNoThrow(try surface.setPaused(true))
    XCTAssertNoThrow(try surface.setMuted(false))
    surface.stop()
    surface.stop()
    XCTAssertNoThrow(try surface.setPaused(false), "after release there is nothing left to pause")
  }

  func testAStoppedPreviewDoesNotStart() async throws {
    let surface = try surface(entry: "clip.mp4")
    surface.stop()
    do {
      try await surface.start()
      XCTFail("a released preview cannot start")
    } catch is CancellationError {
    }
  }
}
