import Foundation
@testable import WallpaperMachine

/// Stands in for api.steampowered.com: answers protobuf calls by method name, in order,
/// and JSON GETs by path.
final class FakeSteamWebAPI: SteamWebAPI, @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [String: [Result<Data, any Error>]] = [:]
    private var json: [String: Data] = [:]
    private var recorded: [(method: String, request: Data)] = []
    private var held: Set<String> = []
    private var jsonRequests: [(path: String, query: [URLQueryItem])] = []

    /// The JSON GETs made, with their queries, in order.
    var jsonCalls: [(path: String, query: [URLQueryItem])] { lock.withLock { jsonRequests } }
    private var parked: [String: CheckedContinuation<Void, Never>] = [:]

    /// Calls of `method` wait, once they arrive, until `release(_:)`.
    func hold(_ method: String) { lock.withLock { _ = held.insert(method) } }

    /// Whether a call of `method` arrived and is waiting.
    func isWaiting(_ method: String) -> Bool { lock.withLock { parked[method] != nil } }

    func release(_ method: String) {
        let waiting = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            held.remove(method)
            return parked.removeValue(forKey: method)
        }
        waiting?.resume()
    }

    func reply(_ method: String, _ message: SteamProto.Writer) {
        lock.withLock { replies[method, default: []].append(.success(message.data)) }
    }

    func fail(_ method: String, eresult: Int32) {
        lock.withLock {
            replies[method, default: []].append(.failure(SteamWebAPIError(method: method, status: 200, eresult: eresult)))
        }
    }

    func serve(_ path: String, json text: String) {
        lock.withLock { json[path] = Data(text.utf8) }
    }

    var calls: [(method: String, request: SteamProto.Message)] {
        lock.withLock { recorded.map { ($0.method, try! SteamProto.Message($0.request)) } }
    }

    func call(_ service: String, _ method: String, request: Data) async throws -> SteamProto.Message {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let waits = lock.withLock { () -> Bool in
                guard held.contains(method) else { return false }
                parked[method] = continuation
                return true
            }
            if !waits { continuation.resume() }
        }
        let next: Result<Data, any Error>? = lock.withLock {
            recorded.append((method, request))
            return replies[method]?.isEmpty == false ? replies[method]!.removeFirst() : nil
        }
        guard let next else { throw SteamWebAPIError(method: method, status: 404, eresult: nil) }
        return try SteamProto.Message(try next.get())
    }

    func json(_ path: String, query: [URLQueryItem]) async throws -> Data {
        guard let data = lock.withLock({ () -> Data? in
            jsonRequests.append((path, query))
            return json[path]
        }) else {
            throw SteamWebAPIError(method: path, status: 404, eresult: nil)
        }
        return data
    }
}

/// A connection manager in a box: every frame the client sends is decoded and handed to
/// `respond`, whose replies are delivered back as frames.
final class ScriptedCMSocket: SteamCMSocket, SteamCMSocketOpening, @unchecked Sendable {
    typealias Responder = @Sendable (SteamCMConnection.Packet) -> [Data]

    private let lock = NSLock()
    private let respond: Responder
    private let stream: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private var sentPackets: [SteamCMConnection.Packet] = []
    private var iterator: AsyncStream<Data>.Iterator
    private var closed = false

    init(respond: @escaping Responder) {
        self.respond = respond
        (stream, continuation) = AsyncStream.makeStream(of: Data.self)
        iterator = stream.makeAsyncIterator()
    }

    var sent: [SteamCMConnection.Packet] { lock.withLock { sentPackets } }

    var isClosed: Bool { lock.withLock { closed } }

    func open(endpoint: String) async throws -> any SteamCMSocket { self }

    func send(_ data: Data) async throws {
        for packet in try SteamCMConnection.packets(in: data) {
            lock.withLock { sentPackets.append(packet) }
            for reply in respond(packet) { continuation.yield(reply) }
        }
    }

    func receive() async throws -> Data {
        var iterator = lock.withLock { self.iterator }
        guard let data = await iterator.next() else { throw CancellationError() }
        lock.withLock { self.iterator = iterator }
        return data
    }

    func close() {
        lock.withLock { closed = true }
        continuation.finish()
    }

    /// A reply frame as Steam would send it.
    static func frame(_ emsg: UInt32, steamID: UInt64 = 0, sessionID: Int32 = 0, jobTarget: UInt64? = nil,
                      eresult: Int32? = nil, body: SteamProto.Writer) -> Data {
        var header = SteamProto.Writer()
        header.fixed64(1, steamID)
        header.varint(2, UInt64(UInt32(bitPattern: sessionID)))
        if let jobTarget { header.fixed64(11, jobTarget) }
        if let eresult { header.varint(13, UInt64(UInt32(bitPattern: eresult))) }
        var data = Data()
        withUnsafeBytes(of: (emsg | SteamCMConnection.protobufFlag).littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(header.data.count).littleEndian) { data.append(contentsOf: $0) }
        return data + header.data + body.data
    }

    /// A logon reply accepting the session, or refusing it with `eresult`.
    static func logOnReply(eresult: Int32 = 1, steamID: UInt64, cellID: UInt64 = 0) -> Data {
        var body = SteamProto.Writer()
        body.varint(1, UInt64(UInt32(bitPattern: eresult)))
        body.varint(3, 9)
        body.varint(7, cellID)
        return frame(SteamCMConnection.EMsg.clientLogOnResponse, steamID: steamID, sessionID: 42, body: body)
    }
}

final class FakeSteamContentFetcher: SteamContentFetching, @unchecked Sendable {
    private let lock = NSLock()
    private let failingHost: String?
    private var files: [String: Data] = [:]
    private var requested: [(host: String, path: String)] = []

    /// Every request to `failingHost` fails the way an unhealthy content server would.
    init(failingHost: String? = nil) {
        self.failingHost = failingHost
    }

    func serve(_ path: String, _ data: Data) { lock.withLock { files[path] = data } }

    var requests: [String] { lock.withLock { requested.map(\.path) } }

    var hosts: [String] { lock.withLock { requested.map(\.host) } }

    func fetch(_ url: URL) async throws -> Data {
        let path = String(url.path.dropFirst())
        let host = url.host() ?? ""
        let data = lock.withLock { () -> Data? in
            requested.append((host, path))
            return host == failingHost ? nil : files[path]
        }
        guard let data else { throw SteamContentClient.Failure.http(status: host == failingHost ? 503 : 404, url: url) }
        return data
    }
}

/// Stands in for the Rust decoder: test content is "packed" by prefixing `PACK`.
struct PrefixDecompressor: SteamContentDecompressing {
    static func pack(_ data: Data) -> Data { Data("PACK".utf8) + data }

    func decompress(_ data: Data) throws -> Data {
        guard data.starts(with: Data("PACK".utf8)) else { throw SteamProto.DecodingError(reason: "not packed") }
        return data.dropFirst(4)
    }
}

enum SteamTestToken {
    /// An unsigned JWT with the claims Steam puts in a refresh token.
    static func jwt(steamID: UInt64 = 76_561_198_000_000_001, audiences: [String] = ["client", "web", "renew", "derive"],
                    expires: Date = Date(timeIntervalSinceNow: 3600)) -> String {
        func base64URL(_ object: Any) -> String {
            try! JSONSerialization.data(withJSONObject: object).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let claims: [String: Any] = ["sub": String(steamID), "aud": audiences, "exp": expires.timeIntervalSince1970]
        return "\(base64URL(["alg": "EdDSA", "typ": "JWT"])).\(base64URL(claims)).c2ln"
    }

    static func token(steamID: UInt64 = 76_561_198_000_000_001) -> SteamRefreshToken {
        try! SteamRefreshToken(jwt(steamID: steamID), accountName: "tester")
    }
}
