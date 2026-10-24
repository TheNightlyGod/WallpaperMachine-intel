import AVFoundation
import CoreMedia
import XCTest

@testable import WallpaperMachine

/// Which stretch of a clip one pass of the loop plays.
///
/// The loop is bounded by the picture. An unbounded `AVPlayerLooper` ends each
/// pass where the item ends, which for a clip with sound is wherever its audio
/// stops: the last frame then holds until it does (issue 76, a quarter-second
/// freeze at every seam of a 4K clip whose two tracks were the same length).
///
/// No window, no player, no desktop: this is metadata. The player's use of the
/// range is checked against real playback in `NativeVideoPlayerMediaTests`.
final class NativeVideoLoopRangeTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("native-video-loop-range-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try super.tearDownWithError()
    }

    func testTheLoopEndsWithThePictureWhenTheAudioRunsLonger() async throws {
        var request = SyntheticVideoFixture.Request.constantRate(
            name: "audio-longer", numerator: 30, denominator: 1, frames: 30)
        request.withAudio = true
        request.audioSeconds = 1.5
        let asset = AVURLAsset(url: try await SyntheticVideoFixture.write(request, into: directory))
        let duration = try await asset.load(.duration)
        XCTAssertGreaterThan(duration.seconds, 1.4, "the fixture's audio must outlast its picture")

        let range = await NativeVideoPlayer.loopRange(of: asset)

        XCTAssertTrue(range.isValid)
        XCTAssertEqual(range.start, .zero)
        XCTAssertEqual(range.duration, CMTime(value: 1, timescale: 1))
    }

    func testAClipWithoutSoundLoopsItsWholePicture() async throws {
        let asset = AVURLAsset(url: try await SyntheticVideoFixture.write(
            .constantRate(name: "silent", numerator: 30, denominator: 1, frames: 45),
            into: directory))

        let range = await NativeVideoPlayer.loopRange(of: asset)

        XCTAssertEqual(range.duration, CMTime(value: 3, timescale: 2))
    }

    func testAClipWithNoReadablePictureLoopsTheWholeItem() async throws {
        // The looper treats an invalid range as the whole item, which is what
        // it did before the loop was bounded; such a clip is admission's to refuse.
        let audioOnly = AVURLAsset(url: try await SyntheticVideoFixture.writeAudioOnly(
            name: "audio-only", into: directory))
        let corrupt = AVURLAsset(url: try SyntheticVideoFixture.writeCorrupt(
            name: "corrupt", into: directory))

        let audioOnlyRange = await NativeVideoPlayer.loopRange(of: audioOnly)
        let corruptRange = await NativeVideoPlayer.loopRange(of: corrupt)

        XCTAssertFalse(audioOnlyRange.isValid)
        XCTAssertFalse(corruptRange.isValid)
    }
}
