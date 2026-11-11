import AVFoundation
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
        volume: 0.5, engineOptions: BridgeSnapshotFixtures.engineOptionValues(), lutPath: nil,
        sceneQuality: .wallpaperEngineDefault))
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

  private func videoLayer(of surface: VideoWallpaperPreviewSurface) throws -> AVPlayerLayer {
    try XCTUnwrap(surface.view.layer?.sublayers?.compactMap { $0 as? AVPlayerLayer }.first)
  }

  func testIdentityOptionsDoNotAddAVideoCompositionToThePreview() async throws {
    let url = try await SyntheticVideoFixture.write(
      .constantRate(name: "identity", numerator: 30, denominator: 1, frames: 4), into: root)
    let surface = try surface(entry: url.lastPathComponent)
    defer { surface.stop() }
    try await surface.start()
    let player = try XCTUnwrap(try videoLayer(of: surface).player)
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while player.currentItem == nil && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    let item = try XCTUnwrap(player.currentItem)
    XCTAssertNil(item.videoComposition, "default options keep AVFoundation's unfiltered path")
  }

  func testOptionsEditedWhileThePreviewPreparesAreTheOptionsItStartsWith() async throws {
    let url = try await SyntheticVideoFixture.write(
      .constantRate(name: "edited", numerator: 30, denominator: 1, frames: 4), into: root)
    let surface = try surface(entry: url.lastPathComponent)
    defer { surface.stop() }
    var edited = WallpaperEngineOptions.identity
    edited.playbackRate = 150
    edited.flipHorizontal = true
    try surface.applyEngineOptions(edited)
    try await surface.start()
    let layer = try videoLayer(of: surface)
    XCTAssertEqual(layer.player?.defaultRate, 1.5)
    XCTAssertEqual(layer.affineTransform(), CGAffineTransform(scaleX: -1, y: 1))
  }

  func testSwitchingThePreviewFilterOnAndOffRestoresDirectPlayback() async throws {
    let url = try await SyntheticVideoFixture.write(
      .constantRate(name: "switch", numerator: 30, denominator: 1, frames: 30), into: root)
    let surface = try surface(entry: url.lastPathComponent)
    defer { surface.stop() }
    try surface.setPaused(true)
    try await surface.start()
    let player = try XCTUnwrap(try videoLayer(of: surface).player)
    var options = WallpaperEngineOptions.identity
    options.colorEnabled = true
    options.brightness = 75
    try surface.applyEngineOptions(options)
    let filteredDeadline = ContinuousClock.now.advanced(by: .seconds(5))
    while player.currentItem?.videoComposition == nil && ContinuousClock.now < filteredDeadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertNotNil(player.currentItem?.videoComposition)
    try surface.applyEngineOptions(.identity)
    let directDeadline = ContinuousClock.now.advanced(by: .seconds(5))
    while (player.currentItem == nil || player.currentItem?.videoComposition != nil) && ContinuousClock.now < directDeadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertNotNil(player.currentItem)
    XCTAssertNil(player.currentItem?.videoComposition)
    XCTAssertEqual(player.rate, 0, "changing colour options keeps the user's paused state")
  }
}
