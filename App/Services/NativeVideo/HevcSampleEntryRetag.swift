import Darwin
import Foundation

/// Finds the HEVC sample entries of an MP4 or MOV file that are tagged `hev1` although their
/// configuration record carries the stream's parameter sets, so that a copy retagged `hvc1` plays.
///
/// macOS decodes HEVC in an ISO base media file only under the `hvc1` tag. `hev1` says the
/// parameter sets (VPS, SPS, PPS) may also arrive inside the stream, and AVFoundation refuses such
/// a track as not playable, but an encoder such as FFmpeg writes all three into the `hvcC` record
/// anyway. When it did, the four characters of the sample entry's type are all that stand between
/// the file and the decoder: writing `hvc1` over them on a copy (`DerivedVideoCache`) is the whole
/// repair, and nothing is decoded or re-encoded. When any `hev1` entry's record lacks one of the
/// three, the tag is honest, a retag would hand the decoder a stream it cannot start, and nothing
/// is planned.
///
/// The walk reads box headers and the sample descriptions only (`moov/trak/mdia/minf/stbl/stsd`),
/// wherever `moov` sits in the file, and steps over `mdat` by its size.
enum HevcSampleEntryRetag {
    /// What a file's sample descriptions say.
    enum Finding: Equatable, Sendable {
        /// No `hev1` sample entry, or no movie box to find one in: nothing to retag.
        case none
        /// Every `hev1` entry carries its parameter sets.
        case retag(Plan)
        /// An `hev1` entry whose record lacks a VPS, SPS or PPS: only the stream has them.
        case parameterSetsInBand
    }

    /// Where the `hev1` types are.
    struct Plan: Equatable, Sendable {
        /// The offset of each `hev1` entry's four-character type from the start of the file.
        var offsets: [UInt64]
    }

    struct IOFailure: Error, LocalizedError, Equatable {
        var detail: String
        var errorDescription: String? { detail }
    }

    static let hev1 = Array("hev1".utf8)
    static let hvc1 = Array("hvc1".utf8)

    /// NAL unit types of the three parameter sets an `hvcC` record must carry.
    private static let requiredParameterSets: Set<UInt8> = [32, 33, 34]  // VPS, SPS, PPS
    /// A sample description is a few hundred bytes; anything far larger is not one to trust.
    private static let sampleDescriptionLimit: UInt64 = 1 << 20
    /// Bounds the walk of one level, so a damaged file cannot keep it going for ever.
    private static let boxesPerLevelLimit = 10_000
    /// The fields of a visual sample entry before its child boxes (ISO/IEC 14496-12 12.1.3).
    private static let visualSampleEntryFields: UInt64 = 78

    // MARK: - Reading

    /// Reads the file's sample descriptions. Throws only when the file cannot be read; a damaged or
    /// unfamiliar structure is `.none`.
    static func inspect(url: URL) throws -> Finding {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw IOFailure(detail: String(cString: strerror(errno))) }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw IOFailure(detail: String(cString: strerror(errno))) }
        return try inspect(size: UInt64(max(0, status.st_size))) { offset, count in
            var buffer = [UInt8](repeating: 0, count: count)
            let read = pread(descriptor, &buffer, count, off_t(offset))
            guard read >= 0 else { throw IOFailure(detail: String(cString: strerror(errno))) }
            return Array(buffer.prefix(read))
        }
    }

    /// The same, over `read(offset, count)`, which returns at most `count` bytes (fewer at the end).
    static func inspect(size: UInt64, read: (UInt64, Int) throws -> [UInt8]) throws -> Finding {
        try withoutActuallyEscaping(read) { read in try inspect(Walker(size: size, read: read)) }
    }

    private static func inspect(_ walker: Walker) throws -> Finding {
        // The walk stops at the movie box, so the fragments of a fragmented file are not read.
        guard let movie = try walker.first("moov", in: 0..<walker.size) else { return .none }
        var offsets: [UInt64] = []
        for track in try walker.children(of: movie.payload) where track.type == "trak" {
            guard let media = try walker.child("mdia", of: track),
                let information = try walker.child("minf", of: media),
                let table = try walker.child("stbl", of: information),
                let descriptions = try walker.child("stsd", of: table)
            else { continue }
            switch try walker.hev1Entries(in: descriptions) {
            case nil: return .parameterSetsInBand
            case let found?: offsets += found
            }
        }
        return offsets.isEmpty ? .none : .retag(Plan(offsets: offsets))
    }

    // MARK: - Writing

    /// Writes `hvc1` over each planned `hev1` type of the file at `url`, which must be a copy: the
    /// file in the library is never written. A type already `hvc1` is left alone; one that is
    /// neither means the copy is not the file that was planned, and nothing more is written.
    static func apply(_ plan: Plan, to url: URL) throws {
        let descriptor = open(url.path, O_RDWR)
        guard descriptor >= 0 else { throw IOFailure(detail: String(cString: strerror(errno))) }
        defer { close(descriptor) }
        for offset in plan.offsets {
            var current = [UInt8](repeating: 0, count: 4)
            guard pread(descriptor, &current, 4, off_t(offset)) == 4 else {
                throw IOFailure(detail: "the copy is shorter than the file it was planned on")
            }
            if current == hvc1 { continue }
            guard current == hev1 else {
                throw IOFailure(detail: "the copy does not hold an hev1 sample entry where it was planned")
            }
            guard pwrite(descriptor, hvc1, 4, off_t(offset)) == 4 else {
                throw IOFailure(detail: String(cString: strerror(errno)))
            }
        }
    }

    // MARK: - The walk

    private struct Box {
        var type: String
        /// The whole box, header included.
        var range: Range<UInt64>
        var payload: Range<UInt64>
    }

    private struct Walker {
        let size: UInt64
        let read: (UInt64, Int) throws -> [UInt8]

        /// The boxes laid end to end in `range`, up to the first of `type` when one is given. A
        /// header that does not fit ends the list there.
        func children(of range: Range<UInt64>, until type: String? = nil) throws -> [Box] {
            var boxes: [Box] = []
            var offset = range.lowerBound
            while offset + 8 <= range.upperBound, boxes.count < HevcSampleEntryRetag.boxesPerLevelLimit {
                let header = try read(offset, 16)
                guard let box = HevcSampleEntryRetag.box(header: header, at: offset, within: range) else { break }
                boxes.append(box)
                if box.type == type { break }
                offset = box.range.upperBound
            }
            return boxes
        }

        func first(_ type: String, in range: Range<UInt64>) throws -> Box? {
            try children(of: range, until: type).last.flatMap { $0.type == type ? $0 : nil }
        }

        func child(_ type: String, of box: Box) throws -> Box? {
            try first(type, in: box.payload)
        }

        /// The offsets of the `hev1` entries of a sample description box, or `nil` when one of
        /// them lacks its parameter sets.
        func hev1Entries(in descriptions: Box) throws -> [UInt64]? {
            let length = descriptions.payload.count
            guard length >= 8, UInt64(length) <= HevcSampleEntryRetag.sampleDescriptionLimit else { return [] }
            let bytes = try read(descriptions.payload.lowerBound, length)
            guard bytes.count == length else { return [] }
            // A full box: version and flags, then the number of entries.
            let count = HevcSampleEntryRetag.uint32(bytes, at: 4)
            let base = descriptions.payload.lowerBound
            var offsets: [UInt64] = []
            var cursor = 8
            for _ in 0..<min(Int(count), HevcSampleEntryRetag.boxesPerLevelLimit) {
                let within = UInt64(cursor)..<UInt64(bytes.count)
                guard let entry = HevcSampleEntryRetag.box(
                    header: Array(bytes[cursor..<min(bytes.count, cursor + 16)]), at: UInt64(cursor), within: within)
                else { break }
                if entry.type == "hev1" {
                    let fields = entry.payload.lowerBound + HevcSampleEntryRetag.visualSampleEntryFields
                    guard fields <= entry.payload.upperBound,
                        HevcSampleEntryRetag.carriesParameterSets(
                            entry: Array(bytes[Int(fields)..<Int(entry.payload.upperBound)]))
                    else { return nil }
                    // The type follows the 32-bit size, and a 64-bit size comes after the type.
                    offsets.append(base + entry.range.lowerBound + 4)
                }
                cursor = Int(entry.range.upperBound)
            }
            return offsets
        }
    }

    /// The box whose header starts `header`, read at `offset`, if it fits inside `range`.
    private static func box(header: [UInt8], at offset: UInt64, within range: Range<UInt64>) -> Box? {
        guard header.count >= 8 else { return nil }
        let declared = UInt64(uint32(header, at: 0))
        let type = String(decoding: header[4..<8], as: UTF8.self)
        var length: UInt64 = 8
        let size: UInt64
        switch declared {
        case 0:
            // To the end of the enclosing box (the file, for a top-level box).
            size = range.upperBound - offset
        case 1:
            guard header.count >= 16 else { return nil }
            size = header[8..<16].reduce(0) { $0 << 8 | UInt64($1) }
            length = 16
        default:
            size = declared
        }
        guard size >= length, size <= range.upperBound - offset else { return nil }
        return Box(type: type, range: offset..<(offset + size), payload: (offset + length)..<(offset + size))
    }

    /// Whether the child boxes of an `hev1` entry hold an `hvcC` record with at least one VPS, SPS
    /// and PPS of nonzero length (ISO/IEC 14496-15 8.3.3.1).
    static func carriesParameterSets(entry children: [UInt8]) -> Bool {
        var cursor = 0
        while cursor + 8 <= children.count {
            let size = Int(uint32(children, at: cursor))
            guard size >= 8, cursor + size <= children.count else { return false }
            if String(decoding: children[(cursor + 4)..<(cursor + 8)], as: UTF8.self) == "hvcC" {
                return carriesParameterSets(record: Array(children[(cursor + 8)..<(cursor + size)]))
            }
            cursor += size
        }
        return false
    }

    /// Whether an `HEVCDecoderConfigurationRecord` lists a VPS, SPS and PPS of nonzero length.
    static func carriesParameterSets(record: [UInt8]) -> Bool {
        // 22 bytes of profile, level and stream fields, then the number of NAL unit arrays.
        guard record.count >= 23 else { return false }
        var found: Set<UInt8> = []
        var cursor = 23
        for _ in 0..<record[22] {
            guard cursor + 3 <= record.count else { return false }
            let type = record[cursor] & 0x3F
            let units = Int(record[cursor + 1]) << 8 | Int(record[cursor + 2])
            cursor += 3
            for _ in 0..<units {
                guard cursor + 2 <= record.count else { return false }
                let length = Int(record[cursor]) << 8 | Int(record[cursor + 1])
                cursor += 2
                guard cursor + length <= record.count else { return false }
                if length > 0 { found.insert(type) }
                cursor += length
            }
        }
        return found.isSuperset(of: requiredParameterSets)
    }

    private static func uint32(_ bytes: [UInt8], at index: Int) -> UInt32 {
        guard index + 4 <= bytes.count else { return 0 }
        return bytes[index..<(index + 4)].reduce(0) { $0 << 8 | UInt32($1) }
    }
}
