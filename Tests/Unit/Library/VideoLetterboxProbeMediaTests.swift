import AVFoundation
import CoreVideo
import XCTest

@testable import WallpaperMachine

/// The black-bar probe against real files: clips written by `SyntheticVideoFixture` with bars
/// painted at known rows, decoded back through `AVAssetImageGenerator`. A few small frames are
/// decoded; there is no player, no window and no audio.
///
/// **Opt-in.** Decoding runs on this machine's media hardware and the bar edges are measured on
/// lossy H.264 output, so a different codec or decoder path can move them by a few rows. The cases
/// are skipped unless `WALLPAPER_MACHINE_MEDIA_TESTS=1` is set, like `NativeVideoPlayerMediaTests`,
/// and the routine gate stays a metadata-and-logic suite:
///
/// ```
/// WALLPAPER_MACHINE_MEDIA_TESTS=1 python3 scripts/test.py --only VideoLetterboxProbeMediaTests
/// ```
///
/// The probe's logic is covered without decoding in `VideoLetterboxProbeTests`.
final class VideoLetterboxProbeMediaTests: XCTestCase {
  private var directory: URL!

  override func setUpWithError() throws {
    try super.setUpWithError()
    try XCTSkipUnless(
      ProcessInfo.processInfo.environment["WALLPAPER_MACHINE_MEDIA_TESTS"] == "1",
      "media/device integration tests are opt-in; set WALLPAPER_MACHINE_MEDIA_TESTS=1")
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("video-letterbox-probe-media-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let directory { try? FileManager.default.removeItem(at: directory) }
    try super.tearDownWithError()
  }

  /// A 320x180 clip of 60 frames at 30 fps whose picture is a bright ramp with black bars of
  /// the given pixel counts.
  private func clip(_ name: String, top: Int = 0, bottom: Int = 0, left: Int = 0, right: Int = 0,
                    black: Bool = false) async throws -> URL {
    var request = SyntheticVideoFixture.Request.constantRate(name: name, numerator: 30, denominator: 1, frames: 60)
    request.width = 320
    request.height = 180
    request.painter = { buffer, step in
      CVPixelBufferLockBaseAddress(buffer, [])
      defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
      guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
      let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
      let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
      for row in 0..<height {
        let line = base.advanced(by: row * rowBytes).assumingMemoryBound(to: UInt8.self)
        for column in 0..<width {
          let isBar = black || row < top || row >= height - bottom || column < left || column >= width - right
          let value = isBar ? 0 : LetterboxFixtures.picture(x: column, y: row, width: width, height: height, seed: step)
          let pixel = line.advanced(by: column * 4)
          pixel[0] = value
          pixel[1] = value
          pixel[2] = value
          pixel[3] = 255
        }
      }
    }
    return try await SyntheticVideoFixture.write(request, into: directory)
  }

  // MARK: - Real clips

  func testLetterboxedClipReportsTheBarsNearThePaintedFraction() async throws {
    let url = try await clip("letterboxed", top: 24, bottom: 24)
    let report = try await VideoLetterboxProbe().check(url)
    XCTAssertEqual(report.stamp, try VideoFileStamp(url: url))
    XCTAssertEqual(report.aspect, 320.0 / 180, accuracy: 0.01)
    XCTAssertGreaterThanOrEqual(report.sampled, 3)
    guard case .bars(let bars) = report.verdict else { return XCTFail("Expected bars, got \(report.verdict)") }
    XCTAssertEqual(bars.top, 24.0 / 180, accuracy: 0.02)
    XCTAssertEqual(bars.bottom, 24.0 / 180, accuracy: 0.02)
    XCTAssertEqual(bars.left, 0)
    XCTAssertEqual(bars.right, 0)
  }

  func testPillarboxedClipReportsLeftAndRight() async throws {
    let report = try await VideoLetterboxProbe().check(try await clip("pillarboxed", left: 40, right: 40))
    guard case .bars(let bars) = report.verdict else { return XCTFail("Expected bars, got \(report.verdict)") }
    XCTAssertEqual(bars.left, 0.125, accuracy: 0.02)
    XCTAssertEqual(bars.right, 0.125, accuracy: 0.02)
    XCTAssertEqual(bars.top, 0)
  }

  func testBarOnTheTopOnlyKeepsItsSide() async throws {
    // Guards the decoded frame's orientation: a bar at the top of the picture is the top bar.
    let report = try await VideoLetterboxProbe().check(try await clip("top-only", top: 30))
    guard case .uneven(let bars) = report.verdict else { return XCTFail("Expected uneven, got \(report.verdict)") }
    XCTAssertEqual(bars.top, 30.0 / 180, accuracy: 0.02)
    XCTAssertEqual(bars.bottom, 0)
  }

  func testFullBleedClipHasNoBars() async throws {
    let report = try await VideoLetterboxProbe().check(try await clip("full-bleed"))
    XCTAssertEqual(report.verdict, .none)
  }

  func testAllBlackClipIsIndeterminate() async throws {
    let report = try await VideoLetterboxProbe().check(try await clip("black", black: true))
    XCTAssertEqual(report.verdict, .indeterminate(.tooDark))
  }
}
