import AVFoundation
import CoreMedia
import XCTest

@testable import WallpaperMachine

/// What the app can tell about a video's format before playing it: the container from the first
/// bytes, the codec from AVFoundation, and which files are refused with their format named.
final class VideoFormatSupportTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("video-format-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try super.tearDownWithError()
    }

    private func bytes(_ parts: [UInt8]...) -> Data { Data(parts.flatMap { $0 }) }
    private func text(_ value: String) -> [UInt8] { Array(value.utf8) }
    private func sniff(_ data: Data, ext: String = "bin") -> VideoFormatSupport.Container {
        VideoFormatSupport.sniff(head: data, fileExtension: ext)
    }

    // MARK: - The container comes from the bytes, not the extension

    func testContainersAreToldByTheirFirstBytes() {
        XCTAssertEqual(
            sniff(bytes([0, 0, 0, 0x20], text("ftyp"), text("isom")), ext: "avi").name, "MP4",
            "the extension is not trusted when the bytes say otherwise")
        XCTAssertEqual(sniff(bytes([0, 0, 0, 0x14], text("ftyp"), text("qt  "))).name, "MOV")
        XCTAssertEqual(sniff(bytes([0, 0, 0, 8], text("moov"))).name, "MOV", "QuickTime without ftyp")
        XCTAssertEqual(
            sniff(bytes([0x1A, 0x45, 0xDF, 0xA3, 0x9F, 0x42, 0x82, 0x84], text("webm"))).name, "WebM")
        XCTAssertEqual(
            sniff(bytes([0x1A, 0x45, 0xDF, 0xA3, 0x9F, 0x42, 0x82, 0x88], text("matroska"))).name,
            "Matroska")
        XCTAssertEqual(sniff(bytes(text("RIFF"), [0x24, 0, 0, 0], text("AVI LIST"))).name, "AVI")
        XCTAssertEqual(sniff(bytes(text("OggS"), [0, 2, 0, 0])).name, "Ogg")
        XCTAssertEqual(
            sniff(bytes([0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11, 0xA6, 0xD9])).name, "WMV")
        XCTAssertEqual(sniff(bytes(text("FLV"), [1, 5, 0, 0, 0, 9])).name, "FLV")
    }

    func testTheContainerFamilyIsWhatDecidesWhoMayStillPlayIt() {
        XCTAssertEqual(sniff(bytes([0x1A, 0x45, 0xDF, 0xA3], text("webm"))).family, .matroska)
        XCTAssertEqual(sniff(bytes([0, 0, 0, 0x20], text("ftyp"), text("isom"))).family, .isoBaseMedia)
        XCTAssertEqual(sniff(bytes(text("RIFF"), [0, 0, 0, 0], text("AVI "))).family, .other)
    }

    func testAFileWhoseBytesShowNoContainerIsNamedByItsExtension() {
        XCTAssertEqual(sniff(Data(repeating: 0x5A, count: 64), ext: "mov").name, "MOV")
        XCTAssertEqual(sniff(Data(), ext: "").name, "unknown")
        // A head too short for any signature neither crashes nor matches one.
        XCTAssertEqual(sniff(bytes([0x1A]), ext: "mkv").name, "MKV")
    }

    // MARK: - Codec names

    func testCodecsAreNamedTheWayPeopleNameThem() {
        let name = VideoFormatSupport.codecName
        XCTAssertEqual(name(0x6176_6331), "H.264")
        XCTAssertEqual(name(0x6876_6331), "HEVC")
        XCTAssertEqual(name(0x6865_7631), "HEVC")
        XCTAssertEqual(name(0x7670_3039), "VP9")
        XCTAssertEqual(name(0x7670_3038), "VP8")
        XCTAssertEqual(name(0x6176_3031), "AV1")
        XCTAssertEqual(name(0x6170_6368), "ProRes")
        XCTAssertEqual(name(0x7878_7878), "xxxx", "an unknown codec is shown as its four characters")
    }

    // MARK: - The rule

    private typealias Format = VideoFormatSupport.Format
    private let mp4 = VideoFormatSupport.Container(name: "MP4", family: .isoBaseMedia)
    private let webm = VideoFormatSupport.Container(name: "WebM", family: .matroska)
    private let avi = VideoFormatSupport.Container(name: "AVI", family: .other)

    private func report(
        playable: Bool = true, video: Bool = true, codec: FourCharCode? = 0x6176_6331
    ) -> VideoFormatSupport.TrackReport {
        .init(isPlayable: playable, hasVideoTrack: video, videoCodec: codec)
    }

    func testAPlayableClipIsSupported() {
        XCTAssertEqual(
            VideoFormatSupport.decide(container: mp4, report: report(), hardwareAV1: false), .supported)
        XCTAssertEqual(
            VideoFormatSupport.decide(container: mp4, report: report(codec: 0x6876_6331), hardwareAV1: false),
            .supported)
    }

    func testAnAV1ClipNeedsHardwareDecodeAndIsNamedAsAV1() {
        let av1 = report(codec: VideoFormatSupport.av1)
        XCTAssertEqual(
            VideoFormatSupport.decide(container: mp4, report: av1, hardwareAV1: false),
            .unsupported(Format(container: "MP4", codec: "AV1"), .needsHardwareAV1Decode))
        XCTAssertEqual(
            VideoFormatSupport.decide(container: mp4, report: av1, hardwareAV1: true), .supported,
            "a Mac with the hardware plays it")
    }

    func testAFileNothingCanOpenIsRefusedWithItsContainerAndCodecNamed() {
        XCTAssertEqual(
            VideoFormatSupport.decide(
                container: avi, report: report(playable: false, video: false, codec: nil),
                hardwareAV1: true),
            .unsupported(Format(container: "AVI", codec: nil), .notPlayable))
        XCTAssertEqual(
            VideoFormatSupport.decide(
                container: mp4, report: report(playable: false, codec: 0x7670_3038), hardwareAV1: true),
            .unsupported(Format(container: "MP4", codec: "VP8"), .notPlayable),
            "a codec AVFoundation names but cannot decode is named in the message")
    }

    func testAFileWithNoVideoTrackIsRefusedEvenWhenItPlays() {
        XCTAssertEqual(
            VideoFormatSupport.decide(
                container: mp4, report: report(video: false, codec: nil), hardwareAV1: true),
            .unsupported(Format(container: "MP4", codec: nil), .notPlayable))
    }

    func testMatroskaAndWebMAreNotAVFoundationsToPlayAndTheOwnReaderDecidesTheRest() {
        // AVFoundation never opens them, so the pure rule only says "not playable here"; inspecting
        // a file then asks the app's own reader, which can still accept it.
        XCTAssertEqual(
            VideoFormatSupport.decide(
                container: webm, report: report(playable: false, video: false, codec: nil),
                hardwareAV1: false),
            .unsupported(Format(container: "WebM", codec: nil), .notPlayable))
    }

    func testTheNameCarriesTheCodecWhenItIsKnown() {
        XCTAssertEqual(Format(container: "AVI", codec: nil).name, "AVI")
        XCTAssertEqual(Format(container: "MP4", codec: "AV1").name, "MP4 (AV1)")
    }

    // MARK: - The messages

    func testTheMessageNamesTheFormat() throws {
        let verdict = VideoFormatSupport.Verdict.unsupported(
            Format(container: "AVI", codec: nil), .notPlayable)
        let message = try XCTUnwrap(VideoFormatSupport.message(for: verdict))
        XCTAssertTrue(message.contains("AVI"), message)
        XCTAssertTrue(message.contains("isn’t supported"), message)

        let av1 = try XCTUnwrap(VideoFormatSupport.message(for: .unsupported(
            Format(container: "MP4", codec: "AV1"), .needsHardwareAV1Decode)))
        XCTAssertTrue(av1.contains("AV1"), av1)
        XCTAssertTrue(av1.contains("hardware"), av1)
    }

    func testNothingIsSaidAboutAFileThatIsNotRefused() {
        XCTAssertNil(VideoFormatSupport.message(for: .supported))
        XCTAssertNil(VideoFormatSupport.message(for: .supportedWebM))
        XCTAssertNil(VideoFormatSupport.message(for: .unreadable("the volume is busy")))
    }

    func testTheHostIsToldFinalForAFormatAndRetriesAnUnreadableFile() {
        // The refusal the native host acts on: final for a format, retried for a read problem.
        let refusal = NativeVideoRefusal.unsupportedFormat("message")
        XCTAssertTrue(refusal.isSettled)
        XCTAssertEqual(refusal.reason, "message")
        XCTAssertFalse(NativeVideoRefusal.preparationFailed("busy").isSettled)
    }

    func testATrackLoadThatFailsOnAPlayableFileIsUnreadableNotRefused() async {
        // A blip on a busy volume after AVFoundation said the file plays says nothing about the
        // format: it must come back unreadable (retried, handed on), never as "no video track".
        let blip = VideoFormatSupport.ReadFailure(detail: "the volume is busy")
        let report = VideoFormatSupport.report(isPlayable: true, tracks: .failure(blip))
        XCTAssertEqual(report, .failure(blip))
        let verdict = await VideoFormatSupport.inspect(
            url: directory.appendingPathComponent("x.mp4"), hardwareAV1: true,
            read: { _ in report })
        XCTAssertEqual(verdict, .unreadable("the volume is busy"))
        XCTAssertNil(VideoFormatSupport.message(for: verdict))
    }

    func testATrackLoadThatFailsOnAnUnplayableFileLeavesOnlyTheCodecOut() {
        let blip = VideoFormatSupport.ReadFailure(detail: "cannot open")
        XCTAssertEqual(
            VideoFormatSupport.report(isPlayable: false, tracks: .failure(blip)),
            .success(.init(isPlayable: false, hasVideoTrack: false, videoCodec: nil)))
        XCTAssertEqual(
            VideoFormatSupport.report(
                isPlayable: true, tracks: .success(.init(count: 1, codec: VideoFormatSupport.av1))),
            .success(.init(isPlayable: true, hasVideoTrack: true, videoCodec: VideoFormatSupport.av1)))
        XCTAssertEqual(
            VideoFormatSupport.report(isPlayable: true, tracks: .success(.init(count: 0, codec: nil))),
            .success(.init(isPlayable: true, hasVideoTrack: false, videoCodec: nil)))
    }

    // MARK: - Real files

    func testAClipAVFoundationPlaysIsSupported() async throws {
        let url = try await SyntheticVideoFixture.write(
            .constantRate(name: "h264", numerator: 30, denominator: 1, frames: 6), into: directory)
        let verdict = await VideoFormatSupport.inspect(url: url)
        XCTAssertEqual(verdict, .supported)
        let refusal = await VideoFormatSupport.refusal(url: url)
        XCTAssertNil(refusal)
    }

    func testAFileThatIsNotAMovieIsRefusedAndNamedByItsExtension() async throws {
        let url = try SyntheticVideoFixture.writeCorrupt(name: "broken", into: directory)
        let verdict = await VideoFormatSupport.inspect(url: url)
        XCTAssertEqual(verdict, .unsupported(Format(container: "MOV", codec: nil), .notPlayable))
        let refusal = await VideoFormatSupport.refusal(url: url)
        guard case let .unsupportedFormat(message)? = refusal else {
            return XCTFail("expected a final refusal, got \(String(describing: refusal))")
        }
        XCTAssertTrue(message.contains("MOV"), message)
    }

    func testAnAudioOnlyFileIsRefused() async throws {
        let url = try await SyntheticVideoFixture.writeAudioOnly(name: "sound", into: directory)
        let verdict = await VideoFormatSupport.inspect(url: url)
        guard case .unsupported(_, .notPlayable) = verdict else {
            return XCTFail("an audio-only file cannot be a video wallpaper, got \(verdict)")
        }
    }

    func testMatroskaTheOwnPlayerPlaysIsSupportedAndItsFileIsKeptForTheSurface() async throws {
        let url = try SyntheticVideoFixture.writeMatroska(name: "clip", into: directory)
        WebMOpenedFiles.shared.removeAll()
        let verdict = await VideoFormatSupport.inspect(url: url)
        XCTAssertEqual(verdict, .supportedWebM, "AVFoundation does not open Matroska; the app's own player does")
        XCTAssertNotNil(WebMOpenedFiles.shared.file(for: url), "the surface takes the file the check opened")
        let refusal = await VideoFormatSupport.refusal(url: url)
        XCTAssertNil(refusal, "nothing is refused or handed to the scene engine")
        XCTAssertTrue(VideoFormatSupport.isMatroska(url))
    }

    func testAWebMFileWithACodecNobodyPlaysIsRefusedWithItsFormatNamed() async throws {
        let url = directory.appendingPathComponent("vp8.webm")
        try WebMFixture.vp8.write(to: url)
        let verdict = await VideoFormatSupport.inspect(url: url)
        XCTAssertEqual(verdict, .unsupported(Format(container: "WebM", codec: "VP8"), .notPlayable))
        let refusal = await VideoFormatSupport.refusal(url: url)
        guard case let .unsupportedFormat(message)? = refusal else {
            return XCTFail("the host reports the display as failed, got \(String(describing: refusal))")
        }
        XCTAssertTrue(message.contains("WebM (VP8)"), message)
    }

    func testAMatroskaFileThatIsDamagedIsRefusedWithoutACodec() async throws {
        let url = directory.appendingPathComponent("cut.webm")
        try WebMFixture.vp9.prefix(120).write(to: url)
        let verdict = await VideoFormatSupport.inspect(url: url)
        XCTAssertEqual(verdict, .unsupported(Format(container: "WebM", codec: nil), .notPlayable))
    }

    func testTheOpenedFilesAreKeyedByTheFileAndForgetAChangedOne() throws {
        let url = directory.appendingPathComponent("a.webm")
        try WebMFixture.vp9.write(to: url)
        guard case .success(let file) = WebMOpening.open(url: url) else { return XCTFail("must open") }
        let cache = WebMOpenedFiles()
        cache.store(file, for: url)
        XCTAssertTrue(cache.file(for: url) === file)
        try WebMFixture.vp9Opus.write(to: url)
        XCTAssertNil(cache.file(for: url), "a file that changed on disk is another entry")
        for index in 0..<(WebMOpenedFiles.capacity + 2) {
            let other = directory.appendingPathComponent("o\(index).webm")
            try WebMFixture.vp9.write(to: other)
            cache.store(file, for: other)
        }
        XCTAssertNil(cache.file(for: directory.appendingPathComponent("o0.webm")), "the oldest entries go")
        XCTAssertNotNil(cache.file(for: directory.appendingPathComponent("o\(WebMOpenedFiles.capacity + 1).webm")))
    }

    func testAMissingFileIsNotReportedAsAFormat() async {
        let verdict = await VideoFormatSupport.inspect(url: directory.appendingPathComponent("gone.avi"))
        if case .supported = verdict { XCTFail("a missing file is not supported") }
        // Whatever it is called, a file that is not there is not blamed on its format as AV1.
        if case let .unsupported(_, reason) = verdict { XCTAssertEqual(reason, .notPlayable) }
    }
}
