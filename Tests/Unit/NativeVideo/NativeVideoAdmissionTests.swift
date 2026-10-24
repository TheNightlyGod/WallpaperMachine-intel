import AVFoundation
import CoreMedia
import XCTest

@testable import WallpaperMachine

/// The native backend's admission rule, exercised against real files.
///
/// Every clip here is written by `SyntheticVideoFixture` and then read back
/// through `NativeVideoAdmission`, so what is asserted is what AVFoundation
/// reports about a finished file. The rule is about the file alone: a clip
/// plays at its own frame rate, so no clip is refused for being faster than a
/// target, and no test here passes a target at all.
///
/// No window, no player, no desktop: this is metadata.
final class NativeVideoAdmissionTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("native-video-admission-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try super.tearDownWithError()
    }

    // MARK: - Clips at their own rate

    func testAClipIsAdmittedAtEveryRateItWasWrittenAt() async throws {
        // Including rates far above any frame-rate cap a user can set: the cap
        // belongs to scenes and web wallpapers, and the clip is not slowed or
        // refused for it.
        for rate in [24, 30, 60, 120] as [CMTimeValue] {
            let url = try await SyntheticVideoFixture.write(
                .constantRate(name: "cfr-\(rate)", numerator: rate, denominator: 1, frames: 8),
                into: directory)
            let decision = await NativeVideoAdmission.evaluate(url: url)
            print("[admission] cfr-\(rate) -> \(decision?.reason ?? "ACCEPTED")")
            XCTAssertNil(decision, "a \(rate) fps clip plays at \(rate) fps")
        }
    }

    func testAVariableRateClipIsAdmitted() async throws {
        // A clip that sits at 12 fps and bursts to 60 used to be judged by its
        // fastest interval against the target. Nothing about its pace matters now.
        let url = try await SyntheticVideoFixture.write(
            .variableRate(
                name: "vfr-15-60", slowRate: 15, fastRate: 60, slowFrames: 6, fastFrames: 6),
            into: directory)
        let decision = await NativeVideoAdmission.evaluate(url: url)
        XCTAssertNil(decision)
    }

    // MARK: - Assets that cannot be played

    func testACorruptFileIsRefusedAsUnplayable() async throws {
        let url = try SyntheticVideoFixture.writeCorrupt(name: "corrupt", into: directory)
        let outcome = await NativeVideoAdmission.probe(url: url)
        guard case let .refused(refusal) = outcome else {
            return XCTFail("a file that is not a movie must not be probed as one")
        }
        print("[admission] corrupt -> REFUSED: \(refusal.reason)")
        guard case .notPlayable = refusal else {
            return XCTFail("expected notPlayable, got \(refusal)")
        }
    }

    func testAMissingFileIsRefusedRatherThanCrashing() async {
        let url = directory.appendingPathComponent("absent.mov")
        let decision = await NativeVideoAdmission.evaluate(url: url)
        print("[admission] absent -> \(decision?.reason ?? "ACCEPTED")")
        XCTAssertNotNil(decision)
    }

    func testARealAudioOnlyFileIsRefusedForHavingNoVideoTrack() async throws {
        // Exercised against AVFoundation actually returning an empty video
        // track list, not against a probe asserting itself. Writing an LPCM
        // track is file I/O: it opens no audio device and plays nothing.
        let url = try await SyntheticVideoFixture.writeAudioOnly(
            name: "audio-only", into: directory)
        let outcome = await NativeVideoAdmission.probe(url: url)
        guard case let .refused(refusal) = outcome else {
            return XCTFail("a file with no video track must not be probed as one")
        }
        print("[admission] audio-only -> REFUSED: \(refusal.reason)")
        guard case let .notPlayable(detail) = refusal else {
            return XCTFail("expected notPlayable, got \(refusal)")
        }
        XCTAssertTrue(
            detail.contains("no video track"),
            "the reason must name the missing video track, got: \(detail)")
    }

    // MARK: - The pure rule

    func testAPlayableTrackIsAdmittedWhateverItsRateMetadata() {
        let probe = NativeVideoTrackProbe(isPlayable: true, hasVideoTrack: true)
        XCTAssertNil(NativeVideoAdmission.decide(probe: probe))
    }

    func testATrackWithoutVideoIsRefused() {
        let audioOnly = NativeVideoTrackProbe(isPlayable: true, hasVideoTrack: false)
        guard case .notPlayable = NativeVideoAdmission.decide(probe: audioOnly) else {
            return XCTFail("a clip with no video track cannot be a wallpaper")
        }
    }

    func testAnUnplayableAssetIsRefused() {
        let unplayable = NativeVideoTrackProbe(isPlayable: false, hasVideoTrack: true)
        guard case .notPlayable = NativeVideoAdmission.decide(probe: unplayable) else {
            return XCTFail("an asset AVFoundation reports unplayable cannot be a wallpaper")
        }
    }
}
