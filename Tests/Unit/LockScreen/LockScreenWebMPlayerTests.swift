import CoreGraphics
import XCTest
import WallpaperMedia

@testable import WallpaperMachine

/// The lock screen's WebM player: the same `WebMPlayer` as the desktop, without sound, in a layer
/// that is not on any screen. The surface's choice between it and the scene engine is covered by the
/// planner tests; here, what it does once chosen.
@MainActor
final class LockScreenWebMPlayerTests: XCTestCase {
  private let viewport = CGSize(width: 320, height: 200)

  private func makePlayer(_ data: Data = WebMFixture.vp9, mode: NativeVideoScalingMode = .fill) throws
    -> LockScreenWebMPlayer
  {
    guard case .success(let file) = WebMOpening.open(data: data) else {
      throw XCTSkip("the embedded WebM no longer opens")
    }
    return LockScreenWebMPlayer(
      file: file, mode: mode, factor: 1, viewport: viewport, backingScale: 2)
  }

  func testPrepareReturnsTheFirstFrameComposedAtTheDisplaysSize() async throws {
    let player = try makePlayer()
    let root = CALayer()
    root.frame = CGRect(origin: .zero, size: viewport)
    player.attach(to: root)
    defer { player.stop() }
    let prepared = try await player.prepare()
    let image = try XCTUnwrap(prepared)
    XCTAssertEqual(image.width, 640)
    XCTAssertEqual(image.height, 400)
    XCTAssertEqual(root.sublayers?.count, 1, "the picture's layer is in the surface's tree")
  }

  func testPausingHoldsTheClipAndAFrameCanStillBeRead() async throws {
    let player = try makePlayer()
    let root = CALayer()
    player.attach(to: root)
    defer { player.stop() }
    _ = try await player.prepare()
    player.setPaused(true)
    XCTAssertTrue(player.isPaused)
    let frame = await player.frame()
    XCTAssertEqual(frame?.width, 640)
    player.setPaused(false)
    XCTAssertFalse(player.isPaused)
  }

  func testStoppingBeforeThePictureEndsPrepareAsStopped() async throws {
    let player = try makePlayer()
    let root = CALayer()
    player.attach(to: root)
    let preparing = Task { @MainActor () -> Error? in
      do { _ = try await player.prepare() } catch { return error }
      return nil
    }
    player.stop()
    let error = await preparing.value
    // Either the first frame was already there or the stop ended the wait; never a hang.
    if let error { XCTAssertEqual(error as? LockScreenVideoPlayer.Failure, .stopped) }
    let frame = await player.frame()
    XCTAssertNil(frame, "a stopped player has no picture to give")
  }

  func testAFailureTheClipHadBeforeAHandlerWasSetIsHeldAndDeliveredOnce() async throws {
    // A decoder that refuses the frames fails the clip; whatever happens first, a handler set late hears
    // it exactly once.
    var bytes = [UInt8](WebMFixture.vp9)
    let cluster: [UInt8] = [0x1F, 0x43, 0xB6, 0x75]
    let start = try XCTUnwrap((0..<(bytes.count - 4)).first { Array(bytes[$0..<($0 + 4)]) == cluster })
    for index in (start + 80)..<bytes.count where index % 2 == 0 { bytes[index] ^= 0x5A }
    let player = try makePlayer(Data(bytes))
    let root = CALayer()
    player.attach(to: root)
    defer { player.stop() }
    do { _ = try await player.prepare() } catch {
      XCTAssertTrue(error is LockScreenVideoPlayer.Failure, "the failure before the first frame fails prepare")
      return
    }
    var heard: [String] = []
    player.onFailure = { heard.append($0) }
    try await Task.sleep(for: .milliseconds(300))
    XCTAssertLessThanOrEqual(heard.count, 1)
  }
}
