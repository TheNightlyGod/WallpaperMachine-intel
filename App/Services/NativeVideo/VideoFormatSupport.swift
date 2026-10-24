import AVFoundation
import CoreMedia
import Foundation
import VideoToolbox

/// What the app can tell about a video file's format before anything is asked to play it, and
/// the words it says it in.
///
/// A video file is imported whatever it holds, and only Apply (or a wallpaper that was assigned
/// earlier) finds out whether macOS can play it. Applying refuses a file nothing here can play
/// with a message that names the format; a file already assigned keeps the picture the display
/// had and the panel shows the same message.
///
/// The rule is AVFoundation's own answer (`isPlayable` and the first video track), plus two facts
/// it cannot give: the container, read from the file's first bytes so a message can say "AVI"
/// instead of a file extension that may lie, and whether the Mac can decode AV1 in hardware,
/// because software AV1 decoding of a wallpaper that runs all day is a cost this app does not
/// take on. Matroska and WebM files, which AVFoundation never opens, are opened with the app's own
/// reader (`WebMOpening`): H.264, HEVC and VP9 in them (and AV1 with hardware decoding) play through
/// `WebMPlayer`, and every other codec, VP8 for one, is refused with its format named. There is no
/// other player to hand a refused file to.
enum VideoFormatSupport {
    /// A container and the video codec in it, as a person would name them.
    struct Format: Equatable, Sendable {
        var container: String
        var codec: String?

        /// "MP4 (AV1)", or just "AVI" when the codec cannot be read.
        var name: String { codec.map { "\(container) (\($0))" } ?? container }
    }

    enum Reason: Equatable, Sendable {
        /// AVFoundation cannot play the file, or it has no video track.
        case notPlayable
        /// An AV1 clip on a Mac with no hardware AV1 decoder.
        case needsHardwareAV1Decode
    }

    enum Verdict: Equatable, Sendable {
        case supported
        /// Matroska or WebM that AVFoundation cannot open and the app's own player plays. The file
        /// the check opened is kept for the surface (`WebMOpenedFiles`).
        case supportedWebM
        case unsupported(Format, Reason)
        /// The file could not be read (a busy volume, a file still being written). Says nothing
        /// about the format, so nothing is refused for it.
        case unreadable(String)
    }

    /// What the first bytes of a file say it is.
    struct Container: Equatable, Sendable {
        enum Family: Equatable, Sendable { case isoBaseMedia, matroska, other }
        var name: String
        var family: Family
    }

    /// What AVFoundation reported about the file.
    struct TrackReport: Equatable, Sendable {
        var isPlayable: Bool
        var hasVideoTrack: Bool
        /// The first video track's codec, when it could be read.
        var videoCodec: FourCharCode?
    }

    static let av1: FourCharCode = 0x6176_3031  // 'av01'

    // MARK: - The decision

    /// The whole rule, as a pure function of what was read.
    static func decide(container: Container, report: TrackReport, hardwareAV1: Bool) -> Verdict {
        let codec = report.videoCodec.map(codecName)
        if report.isPlayable, report.hasVideoTrack {
            if report.videoCodec == av1, !hardwareAV1 {
                return .unsupported(
                    Format(container: container.name, codec: "AV1"), .needsHardwareAV1Decode)
            }
            return .supported
        }
        return .unsupported(Format(container: container.name, codec: codec), .notPlayable)
    }

    /// Reads the file and decides. Nothing is decoded: this is the metadata AVFoundation loads
    /// asynchronously, and the first bytes of the file.
    static func inspect(
        url: URL, hardwareAV1: Bool = hasHardwareAV1Decode,
        read: (@Sendable (URL) async -> Result<TrackReport, ReadFailure>)? = nil
    ) async -> Verdict {
        let container = sniff(head: readHead(of: url), fileExtension: url.pathExtension)
        let outcome = await (read ?? readTracks)(url)
        switch outcome {
        case let .success(report):
            let verdict = decide(container: container, report: report, hardwareAV1: hardwareAV1)
            // AVFoundation does not open Matroska at all; the app's own reader decides.
            if case .unsupported(_, .notPlayable) = verdict, container.family == .matroska {
                return judgeWebM(url, container: container)
            }
            return verdict
        case let .failure(failure):
            return .unreadable(failure.detail)
        }
    }

    /// What the app's own reader says about a Matroska or WebM file, which it opens to find out:
    /// the opened file is kept for the surface. Reads the file's headers and block headers, so it
    /// takes as long as the volume does.
    private static func judgeWebM(_ url: URL, container: Container) -> Verdict {
        switch WebMOpening.open(url: url) {
        case .success(let file):
            WebMOpenedFiles.shared.store(file, for: url)
            return .supportedWebM
        case .failure(let failure):
            switch failure.kind {
            case .unsupported(let name):
                if name == "AV1" {
                    return .unsupported(
                        Format(container: container.name, codec: "AV1"), .needsHardwareAV1Decode)
                }
                return .unsupported(Format(container: container.name, codec: name), .notPlayable)
            case .notMatroska, .damaged:
                return .unsupported(Format(container: container.name, codec: nil), .notPlayable)
            case .unreadable:
                return .unreadable(failure.detail)
            }
        }
    }

    struct ReadFailure: Error, Equatable, Sendable {
        var detail: String
    }

    /// The same verdict as an answer for the native host: `nil` to play it, a refusal that is final
    /// for a format nothing can play, and an unsettled one for a file that could not be read.
    static func refusal(url: URL) async -> NativeVideoRefusal? {
        switch await inspect(url: url) {
        case .supported, .supportedWebM:
            return nil
        case let .unsupported(format, reason):
            return .unsupportedFormat(message(for: format, reason: reason))
        case let .unreadable(detail):
            return .preparationFailed(detail)
        }
    }

    /// The message for a format that cannot be played, in the language the app launched in.
    static func message(for format: Format, reason: Reason) -> String {
        switch reason {
        case .needsHardwareAV1Decode:
            return String(localized: "AV1 video needs hardware decoding, which this Mac doesn’t have. Convert it to MP4 or MOV with H.264 or HEVC, then import it again.")
        case .notPlayable:
            let name = format.name
            return String(localized: "This video’s format isn’t supported (\(name)), or the file is damaged. Convert it to MP4 or MOV with H.264 or HEVC, or import a complete copy, then apply it again.")
        }
    }

    /// The message when the verdict refuses the file, and `nil` when it does not.
    static func message(for verdict: Verdict) -> String? {
        guard case let .unsupported(format, reason) = verdict else { return nil }
        return message(for: format, reason: reason)
    }

    // MARK: - The container

    /// The container the first bytes show. A file whose bytes show none is named by its
    /// extension, in capitals, since that is all that is left to call it.
    static func sniff(head: Data, fileExtension: String) -> Container {
        let bytes = [UInt8](head.prefix(512))
        func ascii(_ range: Range<Int>) -> String? {
            guard range.upperBound <= bytes.count else { return nil }
            return String(bytes: bytes[range], encoding: .isoLatin1)
        }
        if let kind = ascii(4..<8) {
            if kind == "ftyp" {
                let brand = ascii(8..<12) ?? ""
                return brand == "qt  "
                    ? Container(name: "MOV", family: .isoBaseMedia)
                    : Container(name: "MP4", family: .isoBaseMedia)
            }
            if ["moov", "mdat", "wide", "free", "skip", "pnot"].contains(kind) {
                return Container(name: "MOV", family: .isoBaseMedia)
            }
        }
        if bytes.starts(with: [0x1A, 0x45, 0xDF, 0xA3]) {
            let early = String(bytes: bytes.prefix(64), encoding: .isoLatin1) ?? ""
            return early.contains("webm")
                ? Container(name: "WebM", family: .matroska)
                : Container(name: "Matroska", family: .matroska)
        }
        if ascii(0..<4) == "RIFF", ascii(8..<12) == "AVI " {
            return Container(name: "AVI", family: .other)
        }
        if ascii(0..<4) == "OggS" { return Container(name: "Ogg", family: .other) }
        if bytes.starts(with: [0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11]) {
            return Container(name: "WMV", family: .other)
        }
        if ascii(0..<3) == "FLV" { return Container(name: "FLV", family: .other) }
        if bytes.count > 188, bytes[0] == 0x47, bytes[188] == 0x47 {
            return Container(name: "MPEG-TS", family: .other)
        }
        if bytes.starts(with: [0x00, 0x00, 0x01, 0xBA]) {
            return Container(name: "MPEG", family: .other)
        }
        let named = fileExtension.uppercased()
        return Container(name: named.isEmpty ? "unknown" : named, family: .other)
    }

    /// Whether the file's first bytes are Matroska or WebM, which AVFoundation never opens.
    static func isMatroska(_ url: URL) -> Bool {
        sniff(head: readHead(of: url), fileExtension: url.pathExtension).family == .matroska
    }

    /// The first bytes of the file, enough to tell the containers apart. Empty when it cannot be read.
    private static func readHead(of url: URL) -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 512)) ?? Data()
    }

    // MARK: - The codec

    /// A codec as a person names it; the four characters when there is no better name.
    static func codecName(_ subtype: FourCharCode) -> String {
        switch subtype {
        case 0x6176_6331, 0x6176_6333: return "H.264"  // avc1, avc3
        case 0x6876_6331, 0x6865_7631: return "HEVC"  // hvc1, hev1
        case 0x7670_3039: return "VP9"  // vp09
        case 0x7670_3038: return "VP8"  // vp08
        case av1: return "AV1"
        case 0x6170_6368, 0x6170_636E, 0x6170_6373, 0x6170_636F, 0x6170_3468, 0x6170_3478:
            return "ProRes"  // apch apcn apcs apco ap4h ap4x
        case 0x6D70_3476: return "MPEG-4"  // mp4v
        case 0x6D6A_7061, 0x6D6A_7062, 0x6A70_6567: return "Motion JPEG"  // mjpa mjpb jpeg
        default:
            let characters = (0..<4).map { shift -> Character in
                let byte = UInt8((subtype >> UInt32(24 - 8 * shift)) & 0xFF)
                return (0x20..<0x7F).contains(byte) ? Character(UnicodeScalar(byte)) : "?"
            }
            return String(characters).trimmingCharacters(in: .whitespaces)
        }
    }

    // MARK: - AVFoundation

    /// Whether this Mac decodes AV1 in hardware. Cheap and answered by VideoToolbox; read once a call.
    static var hasHardwareAV1Decode: Bool { VTIsHardwareDecodeSupported(av1) }

    /// What the video tracks of a file came to: how many, and the first one's codec.
    struct TrackLoad: Equatable, Sendable {
        var count: Int
        var codec: FourCharCode?
    }

    /// The report for what AVFoundation said, where a failed track load means two things.
    ///
    /// For a file it already called unplayable it is expected, and only leaves the codec out of
    /// the message. For one it called playable it is an I/O blip (a busy or network volume, a
    /// file still being written), which says nothing about the format: that is unreadable, so
    /// it is retried and never recorded as a refusal.
    static func report(
        isPlayable: Bool, tracks: Result<TrackLoad, ReadFailure>
    ) -> Result<TrackReport, ReadFailure> {
        switch tracks {
        case let .success(load):
            return .success(
                TrackReport(isPlayable: isPlayable, hasVideoTrack: load.count > 0, videoCodec: load.codec))
        case let .failure(failure):
            return isPlayable
                ? .failure(failure)
                : .success(TrackReport(isPlayable: false, hasVideoTrack: false, videoCodec: nil))
        }
    }

    @Sendable
    private static func readTracks(_ url: URL) async -> Result<TrackReport, ReadFailure> {
        let asset = AVURLAsset(url: url)
        do {
            let playable = try await asset.load(.isPlayable)
            let tracks: Result<TrackLoad, ReadFailure>
            do {
                let video = try await asset.loadTracks(withMediaType: .video)
                var codec: FourCharCode?
                // A file AVFoundation cannot open may still name its codec.
                if let track = video.first, let formats = try? await track.load(.formatDescriptions),
                    let first = formats.first
                {
                    codec = CMFormatDescriptionGetMediaSubType(first)
                }
                tracks = .success(TrackLoad(count: video.count, codec: codec))
            } catch {
                tracks = .failure(ReadFailure(detail: error.localizedDescription))
            }
            return report(isPlayable: playable, tracks: tracks)
        } catch {
            return .failure(ReadFailure(detail: error.localizedDescription))
        }
    }
}
