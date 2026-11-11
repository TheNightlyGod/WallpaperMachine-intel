import Foundation

/// The protobuf wire format as far as Steam's messages need it, written and read by field
/// number: the client sends a handful of messages and reads a few fields of each answer, so
/// a schema compiler and its runtime would cost more than they save.
enum SteamProto {
    /// A message under construction. Fields are appended in call order.
    struct Writer {
        private(set) var data = Data()

        init() {}

        mutating func varint(_ field: Int, _ value: UInt64) {
            key(field, wireType: 0)
            Self.append(varint: value, to: &data)
        }

        mutating func bool(_ field: Int, _ value: Bool) {
            varint(field, value ? 1 : 0)
        }

        mutating func fixed32(_ field: Int, _ value: UInt32) {
            key(field, wireType: 5)
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }

        mutating func fixed64(_ field: Int, _ value: UInt64) {
            key(field, wireType: 1)
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }

        mutating func bytes(_ field: Int, _ value: Data) {
            key(field, wireType: 2)
            Self.append(varint: UInt64(value.count), to: &data)
            data.append(value)
        }

        mutating func string(_ field: Int, _ value: String) {
            bytes(field, Data(value.utf8))
        }

        mutating func message(_ field: Int, _ value: Writer) {
            bytes(field, value.data)
        }

        private mutating func key(_ field: Int, wireType: UInt64) {
            Self.append(varint: UInt64(field) << 3 | wireType, to: &data)
        }

        static func append(varint value: UInt64, to data: inout Data) {
            var value = value
            while value >= 0x80 {
                data.append(UInt8(value & 0x7F) | 0x80)
                value >>= 7
            }
            data.append(UInt8(value))
        }
    }

    /// A decoded message: every field it carried, by number, in the order it arrived.
    struct Message: Sendable {
        enum Value: Sendable {
            case varint(UInt64)
            case fixed32(UInt32)
            case fixed64(UInt64)
            case bytes(Data)
        }

        private let fields: [Int: [Value]]

        init(_ data: Data) throws {
            var fields: [Int: [Value]] = [:]
            var reader = Reader(data: data)
            while !reader.isAtEnd {
                let key = try reader.varint()
                let field = Int(key >> 3)
                guard field > 0 else { throw DecodingError(reason: "field number 0") }
                let value: Value
                switch key & 7 {
                case 0: value = .varint(try reader.varint())
                case 1: value = .fixed64(try reader.littleEndian(UInt64.self))
                case 2: value = .bytes(try reader.bytes(count: try reader.length()))
                case 5: value = .fixed32(try reader.littleEndian(UInt32.self))
                default: throw DecodingError(reason: "wire type \(key & 7)")
                }
                fields[field, default: []].append(value)
            }
            self.fields = fields
        }

        func varint(_ field: Int) -> UInt64? { varints(field).last }

        func varints(_ field: Int) -> [UInt64] {
            (fields[field] ?? []).compactMap { if case .varint(let value) = $0 { value } else { nil } }
        }

        func int32(_ field: Int) -> Int32? { varint(field).map { Int32(truncatingIfNeeded: $0) } }

        func bool(_ field: Int) -> Bool? { varint(field).map { $0 != 0 } }

        func fixed32(_ field: Int) -> UInt32? {
            (fields[field] ?? []).compactMap { if case .fixed32(let value) = $0 { value } else { nil } }.last
        }

        func float(_ field: Int) -> Float? { fixed32(field).map { Float(bitPattern: $0) } }

        func fixed64(_ field: Int) -> UInt64? {
            (fields[field] ?? []).compactMap { if case .fixed64(let value) = $0 { value } else { nil } }.last
        }

        func bytes(_ field: Int) -> Data? { allBytes(field).last }

        func string(_ field: Int) -> String? { bytes(field).flatMap { String(data: $0, encoding: .utf8) } }

        func messages(_ field: Int) throws -> [Message] { try allBytes(field).map(Message.init) }

        func message(_ field: Int) throws -> Message? { try bytes(field).map(Message.init) }

        private func allBytes(_ field: Int) -> [Data] {
            (fields[field] ?? []).compactMap { if case .bytes(let value) = $0 { value } else { nil } }
        }
    }

    struct DecodingError: LocalizedError {
        let reason: String
        var errorDescription: String? { "Malformed Steam message (\(reason))" }
    }

    /// Reads little-endian values and varints from the front of a buffer.
    struct Reader {
        let data: Data
        private(set) var offset: Int

        init(data: Data) {
            self.data = data
            offset = data.startIndex
        }

        var isAtEnd: Bool { offset >= data.endIndex }

        mutating func varint() throws -> UInt64 {
            var result: UInt64 = 0
            for shift in stride(from: UInt64(0), to: 64, by: 7) {
                guard offset < data.endIndex else { throw DecodingError(reason: "truncated varint") }
                let byte = data[offset]
                offset += 1
                result |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return result }
            }
            throw DecodingError(reason: "varint longer than 64 bits")
        }

        mutating func length() throws -> Int {
            let value = try varint()
            guard value <= UInt64(data.endIndex - offset) else { throw DecodingError(reason: "length past the end") }
            return Int(value)
        }

        mutating func bytes(count: Int) throws -> Data {
            guard count >= 0, count <= data.endIndex - offset else { throw DecodingError(reason: "truncated bytes") }
            defer { offset += count }
            return Data(data[offset..<offset + count])
        }

        mutating func littleEndian<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
            let raw = try bytes(count: MemoryLayout<T>.size)
            return raw.withUnsafeBytes { T(littleEndian: $0.loadUnaligned(as: T.self)) }
        }
    }
}
