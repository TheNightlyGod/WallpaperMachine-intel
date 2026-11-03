import AVFoundation
import XCTest

@testable import WallpaperMachine

/// What the native player does with a playback failure, short of playing
/// anything: the detail the host is told, the video-only item the player
/// falls back to when the clip failed with its audio, and the audio track it
/// switches off while the clip cannot be heard.
///
/// No player, no window, no audio device: this is error values, track
/// metadata and a composition. The fallback and the switched-off track, played
/// against an audio output that cannot start, are in `NativeVideoPlayerMediaTests`.
@MainActor
final class NativeVideoPlaybackFailureTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("native-video-failure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try super.tearDownWithError()
    }

    func testTheReportedFailureCarriesTheCodesBeneathTheLocalizedMessage() {
        // Issue 31's whole report was "这项操作无法完成": AVFoundation's
        // localized AVErrorUnknown, which says nothing. The underlying status
        // is what told an audio queue that would not start apart from a
        // decoder fault.
        let error = NSError(
            domain: AVFoundationErrorDomain, code: AVError.unknown.rawValue,
            userInfo: [
                NSLocalizedDescriptionKey: "这项操作无法完成",
                NSUnderlyingErrorKey: NSError(domain: NSOSStatusErrorDomain, code: -66681),
            ])

        let detail = NativeVideoPlayer.describe(error)

        XCTAssertTrue(detail.contains("这项操作无法完成"), detail)
        XCTAssertTrue(detail.contains("\(AVFoundationErrorDomain) -11800"), detail)
        XCTAssertTrue(detail.contains("\(NSOSStatusErrorDomain) -66681"), detail)
    }

    func testAClipWithSoundCanBeRebuiltWithItsPictureAlone() async throws {
        var request = SyntheticVideoFixture.Request.constantRate(
            name: "with-audio", numerator: 30, denominator: 1, frames: 30)
        request.withAudio = true
        let url = try await SyntheticVideoFixture.write(request, into: directory)
        let source = AVURLAsset(url: url)
        let sourceAudio = try await source.loadTracks(withMediaType: .audio)
        XCTAssertEqual(sourceAudio.count, 1, "the fixture must carry the audio being left out")
        let sourceVideoTracks = try await source.loadTracks(withMediaType: .video)
        let sourceVideo = try XCTUnwrap(sourceVideoTracks.first)
        let sourceRange = try await sourceVideo.load(.timeRange)

        let rebuilt = await NativeVideoPlayer.videoOnlyItem(url: url)
        let item = try XCTUnwrap(rebuilt, "a clip with an audio track has something to leave out")

        let audio = try await item.asset.loadTracks(withMediaType: .audio)
        let video = try await item.asset.loadTracks(withMediaType: .video)
        XCTAssertTrue(audio.isEmpty, "the rebuilt item must not start an audio output")
        XCTAssertEqual(video.count, 1)
        let duration = try await item.asset.load(.duration)
        XCTAssertEqual(
            CMTimeCompare(duration, sourceRange.duration), 0,
            "the picture keeps its full length, so the loop seam does not move")
    }

    /// The audio track switched off while a clip cannot be heard is the one
    /// the platform would play, and switching it back on restores that only
    /// when there is exactly one: with several, the platform's choice between
    /// them is not known, and the clip keeps its sound running muted.
    func testOnlyAClipWithOneEnabledAudioTrackHasItsSoundSwitchedOff() async throws {
        func silenceable(_ name: String, audio: [Bool]?) async throws -> (CMPersistentTrackID?, [CMPersistentTrackID]) {
            var request = SyntheticVideoFixture.Request.constantRate(
                name: name, numerator: 30, denominator: 1, frames: 10)
            if let audio {
                request.withAudio = true
                request.audioTracksEnabled = audio
            }
            let asset = AVURLAsset(url: try await SyntheticVideoFixture.write(request, into: directory))
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            XCTAssertEqual(tracks.count, audio?.count ?? 0, "\(name): the fixture's audio tracks")
            return (await NativeVideoPlayer.silenceableAudioTrack(of: asset), tracks.map(\.trackID))
        }

        let (one, oneIDs) = try await silenceable("one-audio", audio: [true])
        XCTAssertEqual(one, oneIDs.first)
        let (beside, besideIDs) = try await silenceable("one-enabled-one-not", audio: [false, true])
        XCTAssertEqual(beside, besideIDs.last, "a track the file leaves off is never played, so it does not count")
        let (two, _) = try await silenceable("two-enabled", audio: [true, true])
        XCTAssertNil(two)
        let (none, _) = try await silenceable("no-audio", audio: nil)
        XCTAssertNil(none)
        let (off, _) = try await silenceable("only-disabled", audio: [false])
        XCTAssertNil(off)
    }

    func testASilentClipHasNoAudioToLeaveOut() async throws {
        // Its failure is about the picture, so a second attempt would fail the
        // same way; the host is told at once.
        let url = try await SyntheticVideoFixture.write(
            .constantRate(name: "silent", numerator: 30, denominator: 1, frames: 30),
            into: directory)

        let item = await NativeVideoPlayer.videoOnlyItem(url: url)

        XCTAssertNil(item)
    }
}
