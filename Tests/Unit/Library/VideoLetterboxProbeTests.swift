import XCTest

@testable import WallpaperMachine

/// The black-bar probe's logic and failure handling: injected frames, files that cannot be read,
/// time, cancellation and replacement. Nothing here decodes video; the cases that decode real clips
/// are in `VideoLetterboxProbeMediaTests`, which is opt-in.
final class VideoLetterboxProbeTests: XCTestCase {
  private var directory: URL!

  override func setUpWithError() throws {
    try super.setUpWithError()
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("video-letterbox-probe-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let directory { try? FileManager.default.removeItem(at: directory) }
    try super.tearDownWithError()
  }

  private func expectFailure(_ expected: VideoLetterboxProbe.Failure, probe: VideoLetterboxProbe = VideoLetterboxProbe(),
                             url: URL, file: StaticString = #filePath, line: UInt = #line) async {
    do {
      _ = try await probe.check(url)
      XCTFail("Expected \(expected)", file: file, line: line)
    } catch let failure as VideoLetterboxProbe.Failure {
      XCTAssertEqual(failure, expected, file: file, line: line)
    } catch {
      XCTFail("Expected \(expected), got \(error)", file: file, line: line)
    }
  }

  // MARK: - Files that cannot be checked

  func testTextFileNamedAsAMovieIsUnreadable() async throws {
    let url = directory.appendingPathComponent("not-a-movie.mp4")
    try Data("this is text, not a movie".utf8).write(to: url)
    do {
      _ = try await VideoLetterboxProbe().check(url)
      XCTFail("A text file has no frames")
    } catch VideoLetterboxProbe.Failure.unreadable {
    } catch {
      XCTFail("Expected unreadable, got \(error)")
    }
  }

  func testMissingFileIsUnreadable() async {
    do {
      _ = try await VideoLetterboxProbe().check(directory.appendingPathComponent("missing.mp4"))
      XCTFail("A missing file has no frames")
    } catch VideoLetterboxProbe.Failure.unreadable {
    } catch {
      XCTFail("Expected unreadable, got \(error)")
    }
  }

  func testAudioOnlyClipHasNoVideoTrack() async throws {
    let url = try await SyntheticVideoFixture.writeAudioOnly(name: "audio-only", into: directory)
    await expectFailure(.noVideoTrack, url: url)
  }

  // MARK: - Time, cancellation and replacement

  func testFrameSourceThatNeverReturnsTimesOut() async throws {
    let url = directory.appendingPathComponent("slow.mp4")
    try Data("x".utf8).write(to: url)
    let probe = VideoLetterboxProbe(frames: { _ in
      try await Task.sleep(for: .seconds(3600))
      return []
    }, timeout: .milliseconds(100))
    await expectFailure(.timedOut, probe: probe, url: url)
  }

  func testCancellingTheCheckCancelsTheFrameSource() async throws {
    let url = directory.appendingPathComponent("cancelled.mp4")
    try Data("x".utf8).write(to: url)
    let started = expectation(description: "frame source started")
    let observed = expectation(description: "frame source saw the cancellation")
    let probe = VideoLetterboxProbe(frames: { _ in
      started.fulfill()
      do { try await Task.sleep(for: .seconds(3600)) } catch {
        observed.fulfill()
        throw error
      }
      return []
    }, timeout: .seconds(600))
    let task = Task { try await probe.check(url) }
    await fulfillment(of: [started], timeout: 10)
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("A cancelled check has no result")
    } catch is CancellationError {
    } catch {
      XCTFail("Expected CancellationError, got \(error)")
    }
    await fulfillment(of: [observed], timeout: 10)
  }

  func testFileReplacedWhileSamplingIsReportedAsChanged() async throws {
    let url = directory.appendingPathComponent("replaced.mp4")
    try Data("first".utf8).write(to: url)
    let probe = VideoLetterboxProbe(frames: { url in
      try Data(repeating: 7, count: 4096).write(to: url)
      return LetterboxFixtures.frames(top: 23, bottom: 23)
    })
    await expectFailure(.fileChanged, probe: probe, url: url)
  }

  // MARK: - Injected frames

  func testRepeatedFramesCountOnce() async throws {
    let url = directory.appendingPathComponent("repeats.mp4")
    try Data("x".utf8).write(to: url)
    // Five decodes that all landed on the same frame are one picture, not five agreeing ones.
    let single = LetterboxFixtures.frames(top: 23, bottom: 23, count: 1)
    let probe = VideoLetterboxProbe(frames: { _ in Array(repeating: single[0], count: 5) })
    let report = try await probe.check(url)
    XCTAssertEqual(report.sampled, 1)
    XCTAssertEqual(report.verdict, .indeterminate(.tooFewFrames))
  }

  func testOrientationOfADecodedImageIsKept() async throws {
    let url = directory.appendingPathComponent("oriented.mp4")
    try Data("x".utf8).write(to: url)
    let probe = VideoLetterboxProbe(frames: { _ in LetterboxFixtures.frames(top: 40) })
    let report = try await probe.check(url)
    guard case .uneven(let bars) = report.verdict else { return XCTFail("Expected uneven, got \(report.verdict)") }
    XCTAssertEqual(bars.top, 40.0 / 180, accuracy: 1.0 / 180)
    XCTAssertEqual(bars.bottom, 0)
  }

  func testLargeFramesAreMeasuredAtTheSameFractions() async throws {
    let url = directory.appendingPathComponent("large.mp4")
    try Data("x".utf8).write(to: url)
    let probe = VideoLetterboxProbe(frames: { _ in LetterboxFixtures.frames(top: 120, bottom: 120, width: 1280, height: 720) })
    let report = try await probe.check(url)
    XCTAssertEqual(report.aspect, 1280.0 / 720, accuracy: 0.001)
    guard case .bars(let bars) = report.verdict else { return XCTFail("Expected bars, got \(report.verdict)") }
    XCTAssertEqual(bars.top, 120.0 / 720, accuracy: 0.01)
  }
}
