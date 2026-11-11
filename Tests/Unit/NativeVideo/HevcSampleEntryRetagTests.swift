import XCTest

@testable import WallpaperMachine

/// Finding the `hev1` sample entries a retag to `hvc1` can make playable, over box trees built
/// here, and writing the retag on a copy.
final class HevcSampleEntryRetagTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hevc-retag-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try super.tearDownWithError()
    }

    // MARK: - Building files

    private func be32(_ value: Int) -> [UInt8] { (0..<4).map { UInt8((value >> (24 - 8 * $0)) & 0xFF) } }
    private func be64(_ value: Int) -> [UInt8] { (0..<8).map { UInt8((value >> (56 - 8 * $0)) & 0xFF) } }
    private func ascii(_ text: String) -> [UInt8] { Array(text.utf8) }
    private func zeros(_ count: Int) -> [UInt8] { [UInt8](repeating: 0, count: count) }

    private func box(_ type: String, _ payload: [UInt8]) -> [UInt8] { be32(8 + payload.count) + ascii(type) + payload }
    private func largeBox(_ type: String, _ payload: [UInt8]) -> [UInt8] {
        be32(1) + ascii(type) + be64(16 + payload.count) + payload
    }
    private func fullBox(_ type: String, _ payload: [UInt8]) -> [UInt8] { box(type, zeros(4) + payload) }

    /// An `hvcC` record with `units[type]` NAL units of `length` bytes for each listed type.
    private func hvcC(_ units: [UInt8: Int], length: Int = 4) -> [UInt8] {
        var record = [UInt8(1)] + zeros(21) + [UInt8(units.count)]
        for (type, count) in units.sorted(by: { $0.key < $1.key }) {
            record += [0x80 | type] + [UInt8(count >> 8), UInt8(count & 0xFF)]
            for _ in 0..<count { record += [UInt8(length >> 8), UInt8(length & 0xFF)] + zeros(length) }
        }
        return box("hvcC", record)
    }

    private let complete: [UInt8: Int] = [32: 1, 33: 1, 34: 1]

    private func entry(_ type: String, _ children: [UInt8]) -> [UInt8] {
        box(type, zeros(78) + children)
    }

    private func track(_ entries: [[UInt8]]) -> [UInt8] {
        let descriptions = fullBox("stsd", be32(entries.count) + entries.flatMap { $0 })
        let table = box("stbl", descriptions + fullBox("stts", be32(0)))
        let information = box("minf", fullBox("vmhd", zeros(8)) + table)
        let media = box("mdia", fullBox("mdhd", zeros(20)) + fullBox("hdlr", zeros(4) + ascii("vide") + zeros(13)) + information)
        return box("trak", fullBox("tkhd", zeros(80)) + media)
    }

    /// `udta/meta` as QuickTime and FFmpeg write it: a full box whose children follow its flags.
    private var metadata: [UInt8] {
        box("udta", fullBox("meta", fullBox("hdlr", zeros(4) + ascii("mdir") + zeros(13)) + box("ilst", [])))
    }

    private func movie(_ tracks: [[UInt8]]) -> [UInt8] {
        box("moov", fullBox("mvhd", zeros(96)) + metadata + tracks.flatMap { $0 })
    }

    private let fileType: [UInt8] = [0, 0, 0, 0x14] + Array("ftypisom".utf8) + [0, 0, 2, 0] + Array("isom".utf8)

    private func find(_ bytes: [UInt8]) throws -> HevcSampleEntryRetag.Finding {
        try HevcSampleEntryRetag.inspect(size: UInt64(bytes.count)) { offset, count in
            let start = Int(min(offset, UInt64(bytes.count)))
            return Array(bytes[start..<min(bytes.count, start + count)])
        }
    }

    /// The four bytes at each planned offset.
    private func types(at finding: HevcSampleEntryRetag.Finding, in bytes: [UInt8]) -> [String] {
        guard case let .retag(plan) = finding else { return [] }
        return plan.offsets.map { String(decoding: bytes[Int($0)..<Int($0) + 4], as: UTF8.self) }
    }

    // MARK: - Finding

    func testAnHev1EntryThatCarriesItsParameterSetsIsPlannedWhereverTheMovieBoxIs() throws {
        let hev1 = track([entry("hev1", hvcC(complete) + box("pasp", zeros(8)))])
        let first = fileType + movie([hev1]) + box("mdat", zeros(64))
        // FFmpeg's default layout: the media first, with a 64-bit size, and the movie box after it.
        let last = fileType + box("free", []) + largeBox("mdat", zeros(4096)) + movie([hev1])
        for bytes in [first, last] {
            let finding = try find(bytes)
            XCTAssertEqual(types(at: finding, in: bytes), ["hev1"], "\(finding)")
        }
    }

    func testEveryHev1EntryOfEveryTrackIsPlannedAndOtherEntriesAreLeftAlone() throws {
        let bytes = fileType + movie([
            track([entry("avc1", box("avcC", zeros(8)))]),
            track([entry("hev1", hvcC(complete)), entry("hev1", hvcC(complete, length: 9))]),
            track([entry("hvc1", hvcC(complete))]),
        ]) + box("mdat", zeros(16))
        XCTAssertEqual(types(at: try find(bytes), in: bytes), ["hev1", "hev1"])
    }

    func testAnHev1EntryWithoutAVPSSPSOrPPSIsNotRetaggedAndNeitherIsAnyOtherInTheFile() throws {
        for missing: UInt8 in [32, 33, 34] {
            var units = complete
            units[missing] = nil
            let bytes = fileType + movie([track([entry("hev1", hvcC(complete))]), track([entry("hev1", hvcC(units))])])
            XCTAssertEqual(try find(bytes), .parameterSetsInBand, "NAL type \(missing) missing")
        }
        let empty = fileType + movie([track([entry("hev1", hvcC([32: 1, 33: 1, 34: 1], length: 0))])])
        XCTAssertEqual(try find(empty), .parameterSetsInBand, "parameter sets of no length are none")
        let none = fileType + movie([track([entry("hev1", hvcC([32: 0, 33: 0, 34: 0]))])])
        XCTAssertEqual(try find(none), .parameterSetsInBand)
        let noRecord = fileType + movie([track([entry("hev1", box("pasp", zeros(8)))])])
        XCTAssertEqual(try find(noRecord), .parameterSetsInBand)
    }

    func testAFileWithoutHev1OrWithoutAMovieHasNothingToRetag() throws {
        XCTAssertEqual(try find(fileType + movie([track([entry("hvc1", hvcC(complete))])])), .none)
        XCTAssertEqual(try find(fileType + box("mdat", zeros(32))), .none)
        XCTAssertEqual(try find([]), .none)
    }

    func testADamagedTreeEndsTheWalkInsteadOfReadingPastIt() throws {
        let hev1 = track([entry("hev1", hvcC(complete))])
        // A media box that claims more than the file holds hides the movie after it.
        let truncated = fileType + be32(1 << 20) + ascii("mdat") + zeros(16) + movie([hev1])
        XCTAssertEqual(try find(truncated), .none)
        // A sample entry that claims more than its description holds.
        var descriptions = fullBox("stsd", be32(1) + entry("hev1", hvcC(complete)))
        descriptions.replaceSubrange(16..<20, with: be32(10_000))
        let table = box("stbl", descriptions)
        let broken = fileType + box("moov", box("trak", box("mdia", box("minf", table))))
        XCTAssertEqual(try find(broken), .none)
        // A record whose NAL unit runs past its end does not count as carrying it.
        var record = hvcC(complete)
        record.removeLast(2)
        record.replaceSubrange(0..<4, with: be32(record.count))
        XCTAssertEqual(try find(fileType + movie([track([entry("hev1", record)])])), .parameterSetsInBand)
    }

    func testTheEmbeddedHev1ClipIsPlannedFromTheFile() throws {
        let url = try Hev1Fixture.write(name: "fixture", into: directory)
        let finding = try HevcSampleEntryRetag.inspect(url: url)
        XCTAssertEqual(types(at: finding, in: [UInt8](try Data(contentsOf: url))), ["hev1"])
    }

    func testAFileThatCannotBeOpenedThrows() {
        XCTAssertThrowsError(try HevcSampleEntryRetag.inspect(url: directory.appendingPathComponent("gone.mp4")))
    }

    // MARK: - Writing

    func testApplyingThePlanChangesOnlyTheTypesAndCanBeRepeated() throws {
        let bytes = fileType + movie([track([entry("hev1", hvcC(complete))]), track([entry("hev1", hvcC(complete))])])
        let url = directory.appendingPathComponent("copy.mp4")
        try Data(bytes).write(to: url)
        guard case let .retag(plan) = try HevcSampleEntryRetag.inspect(url: url) else { return XCTFail("planned") }
        try HevcSampleEntryRetag.apply(plan, to: url)
        try HevcSampleEntryRetag.apply(plan, to: url)
        let written = [UInt8](try Data(contentsOf: url))
        XCTAssertEqual(written.count, bytes.count)
        let changed = (0..<bytes.count).filter { bytes[$0] != written[$0] }
        XCTAssertFalse(changed.isEmpty)
        XCTAssertTrue(
            changed.allSatisfy { byte in plan.offsets.contains { Int($0) <= byte && byte < Int($0) + 4 } },
            "only the planned types changed: \(changed)")
        for offset in plan.offsets {
            XCTAssertEqual(String(decoding: written[Int(offset)..<Int(offset) + 4], as: UTF8.self), "hvc1")
        }
        XCTAssertEqual(try HevcSampleEntryRetag.inspect(url: url), .none, "nothing is left to retag")
    }

    func testAPlanIsNotWrittenOverAFileItWasNotMadeFor() throws {
        let url = directory.appendingPathComponent("other.mp4")
        let bytes = fileType + box("mdat", zeros(64))
        try Data(bytes).write(to: url)
        XCTAssertThrowsError(try HevcSampleEntryRetag.apply(.init(offsets: [24]), to: url))
        XCTAssertThrowsError(try HevcSampleEntryRetag.apply(.init(offsets: [UInt64(bytes.count)]), to: url))
        XCTAssertEqual([UInt8](try Data(contentsOf: url)), bytes, "nothing was written")
    }
}
