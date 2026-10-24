import CoreMedia
import XCTest
import WallpaperMedia

@testable import WallpaperMachine

/// The Swift face of the WebM reader: what a WebM file opens as, the samples it gives a player and
/// the failures, with the app's and the extension's shared `WebMOpening` on top. The reader's own
/// behaviour is covered by `webm_reader_test`; this proves the module is reachable from Swift and
/// that Swift gets the values the player depends on.
final class WebMOpeningTests: XCTestCase {
  private func open(_ data: Data) throws -> WebMFile {
    switch WebMOpening.open(data: data) {
    case .success(let file): return file
    case .failure(let failure):
      XCTFail("expected the file to open: \(failure)")
      throw failure
    }
  }

  func testAVp9FileOpensWithItsFormatSizeAndLength() throws {
    let file = try open(WebMFixture.vp9)
    XCTAssertEqual(file.containerName, "WebM")
    XCTAssertEqual(file.videoCodecName, "VP9")
    XCTAssertEqual(file.codedSize, CGSize(width: 128, height: 96))
    XCTAssertEqual(file.presentationSize, CGSize(width: 128, height: 96))
    XCTAssertEqual(file.frameCount, 30)
    XCTAssertEqual(file.duration.seconds, 1.0, accuracy: 0.05)
    XCTAssertEqual(file.nominalFrameRate, 30, accuracy: 0.5)
    XCTAssertTrue(file.preferredTransform.isIdentity)
    XCTAssertFalse(file.hasPlayableAudio)
    XCTAssertEqual(CMFormatDescriptionGetMediaSubType(file.videoFormatDescription), kCMVideoCodecType_VP9)
  }

  func testTheReaderGivesSampleBuffersInDecodeOrderAndSeeksToKeyFrames() throws {
    let file = try open(WebMFixture.vp9)
    let reader = file.makeVideoReader()
    var count = 0
    var syncCount = 0
    var lastDecode = CMTime.negativeInfinity
    while let sample = reader.copyNextSampleBuffer() {
      count += 1
      let attachments =
        CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
      if attachments?.first?[kCMSampleAttachmentKey_NotSync] == nil { syncCount += 1 }
      XCTAssertGreaterThanOrEqual(sample.decodeTimeStamp, lastDecode)
      lastDecode = sample.decodeTimeStamp
    }
    XCTAssertEqual(count, 30)
    XCTAssertEqual(syncCount, 2)
    XCTAssertTrue(reader.atEnd)
    XCTAssertEqual(reader.seek(to: CMTime(seconds: 0.7, preferredTimescale: 1000)).seconds, 0.5, accuracy: 0.01)
    XCTAssertFalse(reader.atEnd)
  }

  func testTheAudioOfAnOpusFileDecodesToFloatBuffers() throws {
    let file = try open(WebMFixture.vp9Opus)
    XCTAssertTrue(file.hasPlayableAudio)
    XCTAssertEqual(file.audioCodecName, "Opus")
    let audio = try XCTUnwrap(try? file.makeAudioReader())
    XCTAssertEqual(audio.sampleRate, 48000)
    XCTAssertEqual(audio.channelCount, 2)
    var frames = 0
    while let buffer = audio.copyNextSampleBuffer() { frames += CMSampleBufferGetNumSamples(buffer) }
    XCTAssertEqual(Double(frames), 24000, accuracy: 1000)
    XCTAssertTrue(audio.atEnd)
  }

  func testVp8IsRefusedWithItsNameAndJunkIsNotMatroska() {
    guard case .failure(let vp8) = WebMOpening.open(data: WebMFixture.vp8) else {
      return XCTFail("a VP8 file must not open")
    }
    XCTAssertEqual(vp8.kind, .unsupported(format: "VP8"))
    guard case .failure(let junk) = WebMOpening.open(data: Data(repeating: 0x41, count: 64)) else {
      return XCTFail("junk must not open")
    }
    XCTAssertEqual(junk.kind, .notMatroska)
  }

  func testAFileCutOffInsideItsHeadersIsDamagedAndAMissingFileIsUnreadable() {
    guard case .failure(let cut) = WebMOpening.open(data: WebMFixture.vp9.prefix(120)) else {
      return XCTFail("a cut file must not open")
    }
    XCTAssertEqual(cut.kind, .damaged)
    let missing = FileManager.default.temporaryDirectory.appendingPathComponent("no-such-\(UUID().uuidString).webm")
    guard case .failure(let gone) = WebMOpening.open(url: missing) else {
      return XCTFail("a missing file must not open")
    }
    XCTAssertEqual(gone.kind, .unreadable)
  }

  func testThePosterIsADecodedPictureOfTheClipsSize() throws {
    let file = try open(WebMFixture.vp9)
    let poster = try XCTUnwrap(file.copyPosterImage(at: .zero))
    XCTAssertEqual(poster.width, 128)
    XCTAssertEqual(poster.height, 96)
  }
}
