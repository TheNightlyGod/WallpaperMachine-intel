import Foundation

/// A tiny HEVC clip whose sample entry is tagged `hev1`, which macOS cannot
/// decode.
///
/// `hev1` is HEVC with its parameter sets in the stream instead of the sample
/// description. AVFoundation reports such a track as not playable, but a player
/// handed the file anyway gets as far as `readyToPlay` with its clock running
/// and then never produces a picture: the item reports a presentation size of
/// zero by zero, the layer is never ready for display, and no failure is
/// delivered. That is exactly the stall the first-frame watchdog exists for,
/// reproduced without a stuck volume.
///
/// Whether a future macOS decodes `hev1` is not this repository's to promise, so
/// the test that uses it skips itself when the layer does become ready.
///
/// Embedded rather than generated so the tests do not depend on an FFmpeg CLI.
/// Generated with: ffmpeg -f lavfi -i testsrc=size=64x64:rate=30 -t 0.4
/// -c:v libx265 -preset ultrafast
/// -x265-params log-level=none:keyint=12:bframes=0:info=0 -pix_fmt yuv420p
/// -tag:v hev1 -movflags +faststart -fflags +bitexact -flags:v +bitexact hev1.mp4
enum Hev1Fixture {
    static func write(name: String, into directory: URL) throws -> URL {
        let encoded = """
            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
            """
        guard let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters) else {
            throw SyntheticVideoFixture.FixtureError.writerFailed("invalid embedded hev1 fixture")
        }
        let url = directory.appendingPathComponent("\(name).mp4")
        try data.write(to: url)
        return url
    }
}
