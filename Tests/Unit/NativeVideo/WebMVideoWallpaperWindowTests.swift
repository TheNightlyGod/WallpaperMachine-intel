import AVFoundation
import AppKit
import XCTest
import WallpaperMedia

@testable import WallpaperMachine

/// The desktop surface for WebM: what the host asks of any surface, answered by a window that is never
/// put on screen (it is not ordered in), playing a small VP9 clip with no sound.
@MainActor
final class WebMVideoWallpaperWindowTests: XCTestCase {
  private var windows: [WebMVideoWallpaperWindow] = []
  private let frame = NSRect(x: 0, y: 0, width: 320, height: 200)

  override func tearDown() async throws {
    for window in windows { window.stop() }
    windows.removeAll()
    try await super.tearDown()
  }

  private func openClip(_ data: Data = WebMFixture.vp9) throws -> WebMFile {
    switch WebMOpening.open(data: data) {
    case .success(let file): return file
    case .failure(let failure): throw failure
    }
  }

  private func makeWindow(file: WebMFile?, url: URL = URL(fileURLWithPath: "/nonexistent.webm"), paused: Bool = false)
    -> WebMVideoWallpaperWindow
  {
    let window = WebMVideoWallpaperWindow(
      frame: frame, url: url, file: file, surface: RuntimeSurfaceKey(kind: .desktopNativeVideo, displayID: 7, generation: 3),
      counters: RuntimeCounters(), paused: paused)
    windows.append(window)
    return window
  }

  private func waitUntil(_ timeout: TimeInterval = 8, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return true }
      try? await Task.sleep(for: .milliseconds(50))
    }
    return condition()
  }

  func testAWindowWithItsFileBecomesReadyAndPlays() async throws {
    let window = makeWindow(file: try openClip())
    var ready = false
    window.onReadyForDisplay = { ready = true }
    let shown = await waitUntil { ready }
    XCTAssertTrue(shown, window.stateSummary)
    XCTAssertTrue(window.isReadyForDisplay)
    XCTAssertTrue(window.isPlaying)
    XCTAssertNotNil(window.posterLayer)
  }

  func testUserPauseAndPresentationSuspensionAreSeparateReasons() async throws {
    let window = makeWindow(file: try openClip())
    var ready = false
    window.onReadyForDisplay = { ready = true }
    _ = await waitUntil { ready }
    window.setUserPaused(true)
    XCTAssertFalse(window.isPlaying)
    window.setPresentationSuspended(true)
    window.setUserPaused(false)
    XCTAssertFalse(window.isPlaying, "the display is still hidden")
    window.setPresentationSuspended(false)
    XCTAssertTrue(window.isPlaying)
  }

  func testAWindowStartedPausedHoldsItsFirstPicture() async throws {
    let window = makeWindow(file: try openClip(), paused: true)
    var ready = false
    window.onReadyForDisplay = { ready = true }
    let shown = await waitUntil { ready }
    XCTAssertTrue(shown, window.stateSummary)
    XCTAssertFalse(window.isPlaying)
  }

  func testTheScalingChoiceMovesThePicture() async throws {
    let window = makeWindow(file: try openClip())
    let layer = try XCTUnwrap(window.playerForTest).layer
    window.setScaling(.match, factor: 1, pan: .centered)
    XCTAssertEqual(layer.videoGravity, .resizeAspect)
    window.setScaling(.fill, factor: 1, pan: .centered)
    XCTAssertEqual(layer.videoGravity, .resizeAspectFill)
    // Twice Fit, 128x96 into 320x200: 2.0833 x 2 = 4.1667 per pixel is not the arithmetic;
    // the layout rule gives the size, and a frame placement stretches to it.
    window.setScaling(.match, factor: 2, pan: .centered)
    let expected = NativeVideoLayout.pictureRect(
      mode: .match, factor: 2, videoSize: CGSize(width: 128, height: 96), viewport: frame.size, backingScale: window.backingScaleFactor)
    XCTAssertEqual(layer.videoGravity, .resize)
    XCTAssertEqual(layer.bounds.width * window.backingScaleFactor, CGFloat(expected.width), accuracy: 1)
    XCTAssertEqual(layer.bounds.height * window.backingScaleFactor, CGFloat(expected.height), accuracy: 1)
    // A position moves it: the top-left corner pins the picture's corner to the display's.
    window.setScaling(.match, factor: 0.5, pan: .init(x: 0, y: 0))
    XCTAssertEqual(layer.frame.minX, 0, accuracy: 1)
    XCTAssertEqual(layer.frame.maxY, frame.height, accuracy: 1)
  }

  func testAFileThatCannotBeOpenedFailsAsAVerdictAndAHeldFailureReachesALateHandler() async throws {
    let junk = FileManager.default.temporaryDirectory.appendingPathComponent("junk-\(UUID().uuidString).webm")
    try Data(repeating: 0x41, count: 64).write(to: junk)
    defer { try? FileManager.default.removeItem(at: junk) }
    let window = makeWindow(file: nil, url: junk)
    // Nothing listens yet while the file is opened in the background; the failure is held.
    try await Task.sleep(for: .milliseconds(500))
    var failure: (UInt64, String, Bool)?
    window.onPreparationFailure = { failure = ($0, $1, $2) }
    let delivered = await waitUntil { failure != nil }
    XCTAssertTrue(delivered)
    XCTAssertEqual(failure?.0, 3, "the failure carries the surface's own generation")
    XCTAssertEqual(failure?.2, true, "the file is not a WebM, which is a verdict on it")
    XCTAssertFalse(window.restartPlayback(reason: "nothing to restart"))
    XCTAssertFalse(window.isPlaying)
  }

  func testAWindowOpensItsFileItselfWhenNoneIsGiven() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("clip-\(UUID().uuidString).webm")
    try WebMFixture.vp9.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let window = makeWindow(file: nil, url: url)
    var ready = false
    window.onReadyForDisplay = { ready = true }
    let shown = await waitUntil { ready }
    XCTAssertTrue(shown, window.stateSummary)
  }

  func testThePosterIsComposedAtTheDisplaysSize() async throws {
    let window = makeWindow(file: try openClip())
    let poster = await window.posterImage()
    let image = try XCTUnwrap(poster)
    XCTAssertEqual(CGFloat(image.width), frame.width * window.backingScaleFactor, accuracy: 1)
    XCTAssertEqual(CGFloat(image.height), frame.height * window.backingScaleFactor, accuracy: 1)
  }

  func testStoppingTheWindowStopsThePlayer() async throws {
    let window = makeWindow(file: try openClip())
    var ready = false
    window.onReadyForDisplay = { ready = true }
    _ = await waitUntil { ready }
    window.stop()
    XCTAssertFalse(window.isPlaying)
    XCTAssertFalse(window.isReadyForDisplay)
  }
}
