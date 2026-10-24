import AVFoundation
import CoreMedia
import Foundation

/// Why the native player cannot take a wallpaper.
///
/// On the desktop a refusal is a failure of that display, reported with its reason: no other player
/// takes the clip, and the display keeps the picture it had. (The lock-screen extension still draws
/// a refused clip with the scene engine.) No refusal is about frame rate: the player plays a clip
/// at the clip's own rate, and the frame-rate cap applies to scenes and web wallpapers, so how fast
/// a clip is never decides whether it plays.
enum NativeVideoRefusal: Equatable {
    /// The asset is not playable, or carries no video track. A settled answer
    /// about this file: retrying it would read the same bytes again.
    case notPlayable(String)
    /// Loading the asset's metadata failed. This is *not* a statement about
    /// the content — an I/O error, a file still being written, a busy
    /// device — so it is retried a bounded number of times before it is
    /// reported. Kept apart from `notPlayable` precisely so a transient
    /// failure cannot fail a wallpaper for the rest of the session.
    case preparationFailed(String)
    /// Metadata loaded and admission accepted, but the platform player then
    /// failed to prepare or play the asset. A settled answer for this file and
    /// configuration: the decoder read the same bytes and could not play them.
    /// Distinct from `preparationFailed`, which is a metadata read that did
    /// not complete and says nothing about the content.
    case playbackFailed(String)
    /// The file is in a format nothing in this app can play. The string is the message a person
    /// reads, naming the format. A settled answer: the display keeps the picture it had.
    case unsupportedFormat(String)

    /// Whether this answer is settled for the inputs it was decided on. A
    /// settled refusal may be recorded and reported once; an unsettled one
    /// must be retried instead, within a bound.
    var isSettled: Bool {
        if case .preparationFailed = self { return false }
        return true
    }

    var reason: String {
        switch self {
        case let .notPlayable(detail):
            return "asset is not playable: \(detail)"
        case let .preparationFailed(detail):
            return "asset metadata could not be read: \(detail)"
        case let .playbackFailed(detail):
            return "the platform player could not play the asset: \(detail)"
        case let .unsupportedFormat(message):
            return message
        }
    }
}

/// What the asset actually reported.
///
/// Recorded verbatim so a test can report the API's own answer instead of the
/// answer its fixture generator was asked for.
struct NativeVideoTrackProbe: Equatable, Sendable {
    var isPlayable: Bool
    var hasVideoTrack: Bool

    init(isPlayable: Bool, hasVideoTrack: Bool) {
        self.isPlayable = isPlayable
        self.hasVideoTrack = hasVideoTrack
    }

    /// Human-readable dump of exactly what the API returned, for test records
    /// and log lines.
    var apiDescription: String {
        "isPlayable=\(isPlayable) hasVideoTrack=\(hasVideoTrack)"
    }
}

/// Result of reading a candidate's metadata. A refusal here is a routing
/// decision like any other, so it is not modelled as a thrown error.
enum NativeVideoProbeOutcome: Equatable {
    case probed(NativeVideoTrackProbe)
    case refused(NativeVideoRefusal)
}

/// Decides whether the native backend may take a wallpaper.
///
/// The decision is split in two on purpose: `probe` is the only part that
/// touches AVFoundation, and `decide` is a pure function of what the probe
/// returned. That is what lets the rule be exercised over both real media and
/// metadata shapes no encoder here can produce.
///
/// The rule is about the file alone. The clip plays at its own frame rate, so
/// no target rate takes part: an `AVPlayerLayer` cannot be capped, and the cap
/// is a setting for scenes and web wallpapers.
enum NativeVideoAdmission {
    static func evaluate(url: URL) async -> NativeVideoRefusal? {
        switch await probe(url: url) {
        case let .refused(refusal): return refusal
        case let .probed(probe): return decide(probe: probe)
        }
    }

    /// Reads the metadata the decision needs, asynchronously. Nothing here
    /// decodes the media or walks the file: these are the asynchronous
    /// property loads AVFoundation offers for exactly this purpose.
    static func probe(url: URL) async -> NativeVideoProbeOutcome {
        let asset = AVURLAsset(url: url)
        do {
            guard try await asset.load(.isPlayable) else {
                return .refused(.notPlayable("asset reports itself unplayable"))
            }
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard !tracks.isEmpty else {
                return .refused(.notPlayable("no video track"))
            }
            return .probed(NativeVideoTrackProbe(isPlayable: true, hasVideoTrack: true))
        } catch {
            // A thrown load says nothing about the content: the file may be
            // half-written, the volume may be busy, the decoder may be
            // contended. `AVError.fileFormatNotRecognized` and friends are the
            // settled cases and AVFoundation reports them through
            // `isPlayable` above, which is why this arm is the unsettled one.
            return .refused(.preparationFailed(error.localizedDescription))
        }
    }

    /// The whole rule, as a pure function: playable, with a video track.
    static func decide(probe: NativeVideoTrackProbe) -> NativeVideoRefusal? {
        guard probe.isPlayable else {
            return .notPlayable("asset reports itself unplayable")
        }
        guard probe.hasVideoTrack else {
            return .notPlayable("no video track")
        }
        return nil
    }
}
