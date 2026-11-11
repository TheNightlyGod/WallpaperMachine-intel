import Foundation

/// A depot manifest as Steam's CDN serves it, once unpacked: the files of one depot
/// version, each cut into chunks that are fetched, decrypted and unpacked separately.
struct SteamDepotManifest: Sendable, Equatable {
    struct Chunk: Sendable, Equatable {
        /// SHA-1 of the unpacked chunk, which is also its name on the CDN.
        let id: Data
        let offset: UInt64
        let originalSize: UInt32
        let compressedSize: UInt32

        var hexID: String { id.map { String(format: "%02x", $0) }.joined() }
    }

    struct File: Sendable, Equatable {
        /// Path inside the depot with `/` separators (Steam stores Windows separators).
        var path: String
        let size: UInt64
        let flags: UInt32
        let chunks: [Chunk]
        let linkTarget: String?

        var isDirectory: Bool { flags & SteamDepotManifest.directoryFlag != 0 }
    }

    static let payloadMagic: UInt32 = 0x71F6_17D0
    static let metadataMagic: UInt32 = 0x1F48_12BE
    static let signatureMagic: UInt32 = 0x1B81_B817
    static let endMagic: UInt32 = 0x32C4_15AB
    /// `EDepotFileFlag.Directory`.
    static let directoryFlag: UInt32 = 64

    private(set) var files: [File]
    let depotID: UInt32
    let manifestID: UInt64
    private(set) var filenamesEncrypted: Bool

    init(_ data: Data) throws {
        var reader = SteamProto.Reader(data: data)
        var payload: SteamProto.Message?
        var metadata: SteamProto.Message?
        sections: while !reader.isAtEnd {
            let magic = try reader.littleEndian(UInt32.self)
            switch magic {
            case Self.endMagic:
                break sections
            case Self.payloadMagic, Self.metadataMagic, Self.signatureMagic:
                let length = Int(try reader.littleEndian(UInt32.self))
                let section = try reader.bytes(count: length)
                if magic == Self.payloadMagic { payload = try SteamProto.Message(section) }
                if magic == Self.metadataMagic { metadata = try SteamProto.Message(section) }
            default:
                throw SteamProto.DecodingError(reason: String(format: "manifest section %08x", magic))
            }
        }
        guard let payload, let metadata else { throw SteamProto.DecodingError(reason: "manifest without payload") }
        depotID = UInt32(truncatingIfNeeded: metadata.varint(1) ?? 0)
        manifestID = metadata.varint(2) ?? 0
        filenamesEncrypted = metadata.bool(4) ?? false
        files = try payload.messages(1).map { mapping in
            let chunks = try mapping.messages(6).map { chunk in
                Chunk(id: chunk.bytes(1) ?? Data(), offset: chunk.varint(3) ?? 0,
                      originalSize: UInt32(truncatingIfNeeded: chunk.varint(4) ?? 0),
                      compressedSize: UInt32(truncatingIfNeeded: chunk.varint(5) ?? 0))
            }
            return File(path: mapping.string(1) ?? "", size: mapping.varint(2) ?? 0,
                        flags: UInt32(truncatingIfNeeded: mapping.varint(3) ?? 0),
                        chunks: chunks.sorted { $0.offset < $1.offset },
                        linkTarget: mapping.string(7).flatMap { $0.isEmpty ? nil : $0 })
        }
        if !filenamesEncrypted { files = files.map(Self.normalized) }
    }

    /// Decrypts the file names with the depot key, when the manifest has them encrypted.
    mutating func decryptFilenames(key: Data) throws {
        guard filenamesEncrypted else { return }
        files = try files.map { file in
            guard let encrypted = Data(base64Encoded: file.path, options: .ignoreUnknownCharacters) else {
                throw SteamDepotCrypto.Failure(reason: "file name is not base64")
            }
            var plain = try SteamDepotCrypto.decrypt(encrypted, key: key)
            if let end = plain.firstIndex(of: 0) { plain = plain[..<end] }
            guard let name = String(data: plain, encoding: .utf8) else {
                throw SteamDepotCrypto.Failure(reason: "file name is not UTF-8")
            }
            var decrypted = file
            decrypted.path = name
            return Self.normalized(decrypted)
        }
        filenamesEncrypted = false
    }

    var totalSize: UInt64 { files.reduce(0) { $0 + $1.size } }

    private static func normalized(_ file: File) -> File {
        var file = file
        file.path = file.path.replacingOccurrences(of: "\\", with: "/")
        return file
    }
}
