import Foundation
@testable import WallpaperMachine

final class MemorySteamTokenStore: SteamClientTokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var saved: SteamRefreshToken?

    init(_ token: SteamRefreshToken? = nil) { saved = token }

    var token: SteamRefreshToken? { lock.withLock { saved } }

    func load() -> SteamRefreshToken? { lock.withLock { saved } }
    func save(_ token: SteamRefreshToken) throws { lock.withLock { saved = token } }
    func remove() { lock.withLock { saved = nil } }
}

/// A keychain that keeps the saved sign-in it is asked to delete.
final class KeptSteamTokenStore: SteamClientTokenStoring, @unchecked Sendable {
    private let token: SteamRefreshToken?
    init(_ token: SteamRefreshToken?) { self.token = token }
    func load() async -> SteamRefreshToken? { token }
    func save(_ token: SteamRefreshToken) throws {}
    func remove() throws { throw SteamClientTokenRemovalFailed(reason: "kept") }
}

/// A keychain whose read waits, suspended, until the test opens `gate`: it hands back what was
/// saved when the read began, as a read that raced a sign-out would.
final class GatedSteamTokenStore: SteamClientTokenStoring, @unchecked Sendable {
    let gate = PixivGate()
    private let lock = NSLock()
    private var saved: SteamRefreshToken?

    init(_ token: SteamRefreshToken?) { saved = token }

    var isReading: Bool { gate.waiting > 0 }

    func load() async -> SteamRefreshToken? {
        let snapshot = lock.withLock { saved }
        try? await gate.pass()
        return snapshot
    }

    func save(_ token: SteamRefreshToken) throws { lock.withLock { saved = token } }
    func remove() { lock.withLock { saved = nil } }
}

/// A whole Steam for one Workshop item: directory, logon, item details, depot key, manifest
/// and chunks. Files are served unencrypted-named, one chunk each.
final class FakeSteam: @unchecked Sendable {
    static let app: UInt32 = 431_960
    let key = Data((0..<32).map { UInt8($0) })
    let api = FakeSteamWebAPI()
    let fetcher = FakeSteamContentFetcher()
    /// Steam's answer to the logon; 5 refuses the token.
    var logOnResult: Int32 = 1
    /// False leaves every logon unanswered, as a Steam that went silent would.
    var answersLogOn = true
    /// Steam's answer to the depot key; 15 is what an account that does not own the app gets.
    var depotKeyResult: Int32 = 1
    private let lock = NSLock()
    private var opened = 0

    init(item: UInt64, manifestID: UInt64 = 77, files: [String: Data]) throws {
        api.serve("ISteamDirectory/GetCMListForConnect/v1/",
                  json: #"{"response":{"serverlist":[{"endpoint":"cm.test:443","type":"websockets"}]}}"#)
        api.serve("IContentServerDirectoryService/GetServersForSteamPipe/v1/",
                  json: #"{"response":{"servers":[{"type":"CDN","host":"cdn.test","https_support":"mandatory"}]}}"#)
        var payload = SteamProto.Writer()
        for (path, data) in files.sorted(by: { $0.key < $1.key }) {
            var mapping = SteamProto.Writer()
            mapping.string(1, path)
            mapping.varint(2, UInt64(data.count))
            var chunk = SteamProto.Writer()
            chunk.bytes(1, SteamDepotCrypto.sha1(data))
            chunk.varint(3, 0)
            chunk.varint(4, UInt64(data.count))
            mapping.message(6, chunk)
            payload.message(1, mapping)
            let id = SteamDepotCrypto.sha1(data).map { String(format: "%02x", $0) }.joined()
            fetcher.serve("depot/\(Self.app)/chunk/\(id)",
                          try SteamDepotCrypto.encrypt(PrefixDecompressor.pack(data), key: key, iv: Data(count: 16)))
        }
        var metadata = SteamProto.Writer()
        metadata.varint(1, UInt64(Self.app))
        metadata.varint(2, manifestID)
        var manifest = Data()
        for (magic, section) in [(SteamDepotManifest.payloadMagic, payload.data), (SteamDepotManifest.metadataMagic, metadata.data)] {
            withUnsafeBytes(of: magic.littleEndian) { manifest.append(contentsOf: $0) }
            withUnsafeBytes(of: UInt32(section.count).littleEndian) { manifest.append(contentsOf: $0) }
            manifest.append(section)
        }
        fetcher.serve("depot/\(Self.app)/manifest/\(manifestID)/5/999", PrefixDecompressor.pack(manifest))
        self.item = item
        self.manifestID = manifestID
    }

    private let item: UInt64
    private let manifestID: UInt64

    var connectionsOpened: Int { lock.withLock { opened } }

    /// `timeout` is how long the connection waits for each answer, the logon's included.
    @MainActor
    func session(store: any SteamClientTokenStoring, timeout: Duration = .seconds(5)) -> SteamNativeSession {
        SteamNativeSession(
            store: store, signIn: SteamQRSignIn(api: api), deviceName: "Test Mac",
            makeConnection: { [self] in SteamCMConnection(api: api, opener: socket(), timeout: timeout) },
            makeClient: { [self] in
                SteamContentClient(connection: $0, api: api, fetcher: fetcher, decompressor: PrefixDecompressor())
            })
    }

    private func socket() -> ScriptedCMSocket {
        lock.withLock { opened += 1 }
        return ScriptedCMSocket { [self] packet in
            let job = packet.header.fixed64(10) ?? SteamCMConnection.noJob
            var body = SteamProto.Writer()
            switch (packet.emsg, packet.header.string(12)) {
            case (SteamCMConnection.EMsg.clientLogon, _):
                let token = (try? SteamProto.Message(packet.body))?.string(108) ?? ""
                let steamID = (try? SteamRefreshToken(token, accountName: "")).map(\.steamID) ?? 0
                guard answersLogOn else { return [] }
                return [ScriptedCMSocket.logOnReply(eresult: logOnResult, steamID: steamID)]
            case (_, "PublishedFile.GetDetails#1"):
                var details = SteamProto.Writer()
                details.varint(1, 1)
                details.varint(2, item)
                details.varint(5, UInt64(Self.app))
                details.fixed64(14, manifestID)
                body.message(1, details)
            case (_, "ContentServerDirectory.GetManifestRequestCode#1"):
                body.varint(1, 999)
            case (SteamCMConnection.EMsg.clientGetDepotDecryptionKey, _):
                body.varint(1, UInt64(UInt32(bitPattern: depotKeyResult)))
                body.varint(2, UInt64(Self.app))
                if depotKeyResult == 1 { body.bytes(3, key) }
                return [ScriptedCMSocket.frame(5439, jobTarget: job, body: body)]
            default:
                return []
            }
            return [ScriptedCMSocket.frame(SteamCMConnection.EMsg.serviceMethodResponse, jobTarget: job, eresult: 1, body: body)]
        }
    }
}
