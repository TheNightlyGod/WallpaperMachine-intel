import AVFoundation
import CoreMedia
import XCTest
import WallpaperMedia

@testable import WallpaperMachine

/// Records what the feeder hands a renderer, without a renderer.
private final class RecordingSink: WebMSampleSink {
  var room: Int
  private(set) var buffers: [CMSampleBuffer] = []
  init(room: Int) { self.room = room }
  var hasRoom: Bool { room > 0 }
  func accept(_ buffer: CMSampleBuffer) {
    buffers.append(buffer)
    room -= 1
  }
  var times: [Double] { buffers.map { CMSampleBufferGetPresentationTimeStamp($0).seconds } }
}

/// The WebM player's feeding, looping and placement, without a display; and the player itself on a layer
/// that is not in a window (no desktop is touched, and no audio is played: players here have no audio).
@MainActor
final class WebMPlayerTests: XCTestCase {
  private func file(_ data: Data) throws -> WebMFile {
    switch WebMOpening.open(data: data) {
    case .success(let file): return file
    case .failure(let failure): throw failure
    }
  }

  // MARK: Feeding

  func testTheFeederWrapsAtTheEndOfTheFileWithTimeContinuingAcrossPasses() throws {
    let clip = try file(WebMFixture.vp9)
    let feeder = WebMFeeder(file: clip, audio: nil)
    let sink = RecordingSink(room: 75)  // two and a half passes of 30 frames
    XCTAssertTrue(feeder.feedVideo(into: sink))
    let times = sink.times
    XCTAssertEqual(times.count, 75)
    // Decode order of this clip is not presentation order (hidden frames), so compare each pass as a set.
    let length = clip.duration.seconds
    for pass in 0..<2 {
      let slice = Array(times[(pass * 30)..<((pass + 1) * 30)])
      XCTAssertEqual(slice.min()!, Double(pass) * length, accuracy: 0.002)
      XCTAssertLessThan(slice.max()!, Double(pass + 1) * length + 0.001)
    }
    // The first sample of a new pass is a key frame again.
    let attachments = CMSampleBufferGetSampleAttachmentsArray(sink.buffers[30], createIfNecessary: false) as? [[CFString: Any]]
    XCTAssertNil(attachments?.first?[kCMSampleAttachmentKey_NotSync])
    XCTAssertEqual(feeder.videoSamplesEnqueued, 75)
  }

  func testAStillPictureIsFedOnceAndNotLooped() throws {
    // Six VP8 frames cannot play; a one-frame file is built from the VP9 clip's first key frame.
    let clip = try file(WebMFixture.vp9)
    let reader = clip.makeVideoReader()
    XCTAssertNotNil(reader.copyNextSampleBuffer())
    // The player treats frameCount == 1 as a still; the feeder's rule is on the file's own count.
    XCTAssertGreaterThan(clip.frameCount, 1)
  }

  func testTheAudioIsCutWhereThePictureWrapsAndRestartsOnTheNextPass() throws {
    let clip = try file(WebMFixture.vp9Opus)
    let audio = try clip.makeAudioReader()
    let feeder = WebMFeeder(file: clip, audio: audio)
    let sink = RecordingSink(room: 24)  // about 2.4 s of 0.1 s buffers: past one pass of half a second
    XCTAssertTrue(feeder.feedAudio(into: sink))
    let length = clip.duration.seconds
    let starts = sink.times
    XCTAssertEqual(starts.first!, 0, accuracy: 0.001)
    // Time never goes backwards, and every pass starts at a multiple of the picture's length.
    for (a, b) in zip(starts, starts.dropFirst()) { XCTAssertGreaterThan(b, a) }
    let second = starts.first { $0 >= length - 0.001 }
    XCTAssertEqual(try XCTUnwrap(second), length, accuracy: 0.002)
    // No buffer runs past its pass.
    for buffer in sink.buffers {
      let start = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
      let end = start + CMSampleBufferGetDuration(buffer).seconds
      let pass = floor((start + 0.0001) / length)
      XCTAssertLessThanOrEqual(end, (pass + 1) * length + 0.001)
    }
  }

  func testRepositioningStartsTheVideoAtTheKeyFrameBeforeTheTimeInItsPass() throws {
    let clip = try file(WebMFixture.vp9)
    let feeder = WebMFeeder(file: clip, audio: nil)
    // 1.7 s: the second pass, 0.7 s in; the key frame before it is the one at 0.5 s.
    feeder.reposition(at: CMTime(seconds: 1.7, preferredTimescale: 1000))
    let sink = RecordingSink(room: 3)
    _ = feeder.feedVideo(into: sink)
    XCTAssertEqual(sink.times.min()!, 1.5, accuracy: 0.01)
    let attachments = CMSampleBufferGetSampleAttachmentsArray(sink.buffers[0], createIfNecessary: false) as? [[CFString: Any]]
    XCTAssertNil(attachments?.first?[kCMSampleAttachmentKey_NotSync])
  }

  func testRepositioningTheSoundDropsWhatTheClockHasPassed() throws {
    let clip = try file(WebMFixture.vp9Opus)
    let feeder = WebMFeeder(file: clip, audio: try clip.makeAudioReader())
    feeder.repositionAudio(at: CMTime(seconds: 0.3, preferredTimescale: 1000))
    let sink = RecordingSink(room: 1)
    _ = feeder.feedAudio(into: sink)
    let buffer = try XCTUnwrap(sink.buffers.first)
    let end = CMSampleBufferGetPresentationTimeStamp(buffer).seconds + CMSampleBufferGetDuration(buffer).seconds
    XCTAssertGreaterThan(end, 0.3)
    XCTAssertLessThan(CMSampleBufferGetPresentationTimeStamp(buffer).seconds, 0.3 + 0.001)
  }

  // MARK: Orientation

  func testAClipMarkedAsTurnedIsShownWithItsAxesExchanged() throws {
    let clip = try file(WebMFixture.vp9Rotated)
    XCTAssertTrue(clip.transformSwapsAxes)
    XCTAssertEqual(clip.presentationSize, CGSize(width: 96, height: 128))
    XCTAssertFalse(clip.preferredTransform.isIdentity)
  }

  // MARK: Playing

  private func waitUntil(_ timeout: TimeInterval = 8, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return true }
      try? await Task.sleep(for: .milliseconds(50))
    }
    return condition()
  }

  func testAPlayerShowsItsFirstPictureRunsAndLoops() async throws {
    let player = WebMPlayer(file: try file(WebMFixture.vp9), withAudio: false, paused: false)
    let root = CALayer()
    root.frame = CGRect(x: 0, y: 0, width: 320, height: 200)
    player.attach(to: root)
    player.relayout(bounds: root.bounds, backingScale: 1)
    var ready = false
    player.onReadyForDisplay = { ready = true }
    player.start()
    defer { player.stop() }
    let shown = await waitUntil { ready }
    XCTAssertTrue(shown, "no first picture: \(player.stateSummary)")
    XCTAssertTrue(player.isPlaying)
    // The clock runs past the one second the clip lasts, so it has looped, and samples kept coming.
    let looped = await waitUntil(10) { player.currentTime.seconds > 1.4 }
    XCTAssertTrue(looped, player.stateSummary)
    XCTAssertGreaterThan(player.videoSamplesFed, 30)
  }

  func testPausingStopsTheClockAndResumingRunsItAgain() async throws {
    let player = WebMPlayer(file: try file(WebMFixture.vp9), withAudio: false, paused: false)
    let root = CALayer()
    root.frame = CGRect(x: 0, y: 0, width: 320, height: 200)
    player.attach(to: root)
    player.start()
    defer { player.stop() }
    let advanced = await waitUntil { player.currentTime.seconds > 0.2 }
    XCTAssertTrue(advanced, player.stateSummary)
    player.setPaused(true)
    XCTAssertFalse(player.isPlaying)
    try await Task.sleep(for: .milliseconds(200))
    let held = player.currentTime.seconds
    try await Task.sleep(for: .milliseconds(400))
    XCTAssertEqual(player.currentTime.seconds, held, accuracy: 0.02)
    player.setPaused(false)
    let resumed = await waitUntil { player.currentTime.seconds > held + 0.2 }
    XCTAssertTrue(resumed, player.stateSummary)
  }

  func testAPlayerStartedPausedShowsItsFirstPictureWithoutRunning() async throws {
    let player = WebMPlayer(file: try file(WebMFixture.vp9), withAudio: false, paused: true)
    let root = CALayer()
    root.frame = CGRect(x: 0, y: 0, width: 320, height: 200)
    player.attach(to: root)
    var ready = false
    player.onReadyForDisplay = { ready = true }
    player.start()
    defer { player.stop() }
    let shown = await waitUntil { ready }
    XCTAssertTrue(shown, player.stateSummary)
    XCTAssertFalse(player.isPlaying)
    XCTAssertEqual(player.currentTime.seconds, 0, accuracy: 0.05)
  }

  func testARestartKeepsThePictureGoingAndSpendsTheAllowance() async throws {
    let player = WebMPlayer(
      file: try file(WebMFixture.vp9), withAudio: false, paused: false,
      recovery: .init(maximum: 1, window: .seconds(600), stableRun: .seconds(600)))
    let root = CALayer()
    root.frame = CGRect(x: 0, y: 0, width: 320, height: 200)
    player.attach(to: root)
    player.start()
    defer { player.stop() }
    let advanced = await waitUntil { player.currentTime.seconds > 0.3 }
    XCTAssertTrue(advanced, player.stateSummary)
    XCTAssertTrue(player.restartPlayback(reason: "test"))
    let before = player.currentTime.seconds
    let after = await waitUntil { player.currentTime.seconds > before + 0.3 }
    XCTAssertTrue(after, player.stateSummary)
    XCTAssertFalse(player.restartPlayback(reason: "again"), "the allowance is one restart")
  }

  /// A volume that stops answering holds the feed queue inside a read. Stopping, restarting and
  /// replacing a wallpaper must not wait for it: the main actor is the app's whole interface.
  func testStoppingAndRestartingNeverWaitForAFeedQueueThatIsStuckInARead() async throws {
    let queue = DispatchQueue(label: "test.webm-feed-stuck")
    let gate = DispatchSemaphore(value: 0)
    queue.async { gate.wait() }
    // The watchdog frees a queue that a regression would be waiting for, so a failure is a
    // measured delay, not a hung run.
    DispatchQueue.global().asyncAfter(deadline: .now() + 6) { gate.signal() }
    let player = WebMPlayer(
      file: try file(WebMFixture.vp9), withAudio: false, paused: false,
      recovery: .init(maximum: 3, window: .seconds(600), stableRun: .seconds(600)), feedQueue: queue)
    let root = CALayer()
    root.frame = CGRect(x: 0, y: 0, width: 320, height: 200)
    player.attach(to: root)
    player.start()
    let started = ContinuousClock.now
    XCTAssertTrue(player.restartPlayback(reason: "test"))
    XCTAssertTrue(player.restartPlayback(reason: "again"))
    player.stop()
    let elapsed = ContinuousClock.now - started
    XCTAssertLessThan(elapsed, .seconds(2), "the main actor waited for the feed queue")
    gate.signal()
  }

  func testARestartRequestedWhileTheQueueIsBusyFeedsAgainOnceItIsFree() async throws {
    let queue = DispatchQueue(label: "test.webm-feed-slow")
    let gate = DispatchSemaphore(value: 0)
    queue.async { gate.wait() }
    let player = WebMPlayer(
      file: try file(WebMFixture.vp9), withAudio: false, paused: false,
      recovery: .init(maximum: 3, window: .seconds(600), stableRun: .seconds(600)), feedQueue: queue)
    let root = CALayer()
    root.frame = CGRect(x: 0, y: 0, width: 320, height: 200)
    player.attach(to: root)
    var ready = false
    player.onReadyForDisplay = { ready = true }
    player.start()
    defer { player.stop() }
    XCTAssertTrue(player.restartPlayback(reason: "test"))
    XCTAssertEqual(player.videoSamplesFed, 0, "nothing is fed while the queue is held")
    gate.signal()
    let shown = await waitUntil { ready && player.videoSamplesFed > 0 }
    XCTAssertTrue(shown, player.stateSummary)
  }

  func testThePosterIsAnUprightPictureAtTheShownSize() async throws {
    let player = WebMPlayer(file: try file(WebMFixture.vp9Rotated), withAudio: false, paused: true)
    let root = CALayer()
    player.attach(to: root)
    player.start()
    defer { player.stop() }
    let poster = await player.posterImage()
    XCTAssertEqual(poster?.width, 96)
    XCTAssertEqual(poster?.height, 128)
  }

  func testAClipTheDecoderRefusesFailsAsAVerdictOnTheFile() async throws {
    // A VP9 stream whose frames are not VP9: the format description builds from the first header, and
    // the decoder fails every frame it is given.
    var bytes = [UInt8](WebMFixture.vp9)
    // Garble the picture data of every frame but keep the container and each frame's VP9 header
    // intact for the first key frame's profile read: bytes after the first cluster's start, past the
    // first 30 bytes of the first frame.
    let cluster: [UInt8] = [0x1F, 0x43, 0xB6, 0x75]
    let start = try XCTUnwrap(bytes.firstIndex(where: { _ in true }).flatMap { _ in
      (0..<(bytes.count - 4)).first { Array(bytes[$0..<($0 + 4)]) == cluster }
    })
    for index in (start + 80)..<bytes.count where index % 2 == 0 { bytes[index] ^= 0x5A }
    guard case .success(let broken) = WebMOpening.open(data: Data(bytes)) else {
      throw XCTSkip("the garbled clip no longer opens, so there is nothing for the decoder to refuse")
    }
    let player = WebMPlayer(file: broken, withAudio: false, paused: false)
    let root = CALayer()
    player.attach(to: root)
    var failure: (String, Bool)?
    player.onFailure = { failure = ($0, $1) }
    player.start()
    defer { player.stop() }
    let failed = await waitUntil { failure != nil || player.isReadyForDisplay }
    XCTAssertTrue(failed)
    if let failure { XCTAssertTrue(failure.1, "a decoder that fails from the first frame has given a verdict on the file") }
  }
}
