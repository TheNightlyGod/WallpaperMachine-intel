import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// The still a video imported from disk shows in the library, which a bare clip does not ship:
/// one frame from early in the clip, past a fade-in from black, as a JPEG.
enum VideoPoster {
    struct Failure: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    /// The frame is taken this far into the clip, as a share of its length…
    static let position = 0.1
    /// …but never later than this many seconds.
    static let latestSeconds = 3.0

    /// When the frame is taken in a clip of `duration`; the start when the length is unknown.
    static func time(duration: CMTime) -> CMTime {
        guard duration.isNumeric, duration.seconds > 0 else { return .zero }
        return CMTime(seconds: min(duration.seconds * position, latestSeconds), preferredTimescale: 600)
    }

    /// The poster of `video`, no larger than `maxPixelSize` on either side. Throws when the
    /// system cannot decode a frame of it. An HEVC clip tagged `hev1` is read from its corrected
    /// copy (`DerivedVideoCache`), as it plays; a copy made only for the poster goes after it.
    static func jpeg(
        of video: URL, maxPixelSize: Int, derived: DerivedVideoCache = .shared
    ) async throws -> Data {
        try await derived.reading(video, keepingCopy: false) { try await frame(of: $0, maxPixelSize: maxPixelSize) }
    }

    private static func frame(of video: URL, maxPixelSize: Int) async throws -> Data {
        let asset = AVURLAsset(url: video)
        let duration = (try? await asset.load(.duration)) ?? .invalid
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
        // At the time asked for, not the nearest key frame, which can be the black first frame.
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: time(duration: duration)).image
        return try encode(image)
    }

    static func encode(_ image: CGImage) throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw Failure(reason: "no JPEG encoder") }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(destination), output.length > 0 else {
            throw Failure(reason: "the frame could not be encoded")
        }
        return output as Data
    }
}
