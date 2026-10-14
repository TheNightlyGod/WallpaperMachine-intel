import AVFoundation
import XCTest

@testable import WallpaperMachine

/// Which clips the native player cannot read a poster from the playing item
/// for: those whose display matrix turns or mirrors the picture.
///
/// Metadata only. No player, no layer, no decode: the matrix is read from real
/// generated files, so the decision is exercised against what AVFoundation
/// actually reports for a rotated track rather than against a hand-made
/// value. Whether the resulting poster is upright is in
/// `NativeVideoPlayerMediaTests`, which is opt-in.
@MainActor
final class NativeVideoPosterOrientationTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("native-video-orientation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try super.tearDownWithError()
    }

    /// Real files, so the decision is checked against what AVFoundation reports for the matrix
    /// a clip actually carries, not against a matrix typed in by hand.
    func testTheMatrixOfARealClipIsReadBackAndOnlyAnUprightOneSkipsTheGenerator() async throws {
        let clips: [(name: String, degrees: Int, mirrored: Bool, upright: Bool)] = [
            ("upright", 0, false, true),
            ("turned-90", 90, false, false),
            ("turned-180", 180, false, false),
            ("turned-270", 270, false, false),
            ("mirrored", 0, true, false),
        ]
        for clip in clips {
            var request = SyntheticVideoFixture.Request.constantRate(
                name: "orientation-\(clip.name)", numerator: 30, denominator: 1, frames: 4)
            request.rotationDegrees = clip.degrees
            request.mirrored = clip.mirrored
            let url = try await SyntheticVideoFixture.write(request, into: directory)

            let transform = try await NativeVideoPlayer.loadDisplayTransform(
                of: AVURLAsset(url: url))

            XCTAssertEqual(
                NativeVideoPlayer.needsUprightGenerator(transform), !clip.upright,
                "\(clip.name) read back as \(transform)")
        }
    }

    func testAMovieWithNoPictureHasNoMatrixToHonour() async throws {
        let url = try await SyntheticVideoFixture.writeAudioOnly(name: "no-picture", into: directory)

        let transform = try await NativeVideoPlayer.loadDisplayTransform(of: AVURLAsset(url: url))

        XCTAssertTrue(transform.isIdentity)
        XCTAssertFalse(NativeVideoPlayer.needsUprightGenerator(transform))
    }
}
