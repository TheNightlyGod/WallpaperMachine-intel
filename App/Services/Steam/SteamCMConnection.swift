import Foundation

/// One frame-oriented socket to a Steam connection manager. Injected so tests can stand in
/// for Steam.
protocol SteamCMSocket: Sendable {
    func send(_ data: Data) async throws
    func receive() async throws -> Data
    func close()
}

protocol SteamCMSocketOpening: Sendable {
    /// Opens `wss://<endpoint>/cmsocket/`, `endpoint` being `host:port` from Steam's CM directory.
    func open(endpoint: String) async throws -> any SteamCMSocket
}

/// A logged-on session with a Steam connection manager (CM), the server the Steam client
/// itself talks to: the app logs on with a refresh token, asks for what a download needs
/// (Workshop details, depot keys, manifest request codes) and then fetches content from the
/// CDN over plain HTTPS.
actor SteamCMConnection {
    enum EMsg {
        static let multi: UInt32 = 1
        static let serviceMethodResponse: UInt32 = 147
        static let serviceMethodCallFromClient: UInt32 = 151
        static let clientHeartBeat: UInt32 = 703
        static let clientLogOff: UInt32 = 706
        static let clientLogOnResponse: UInt32 = 751
        static let clientLoggedOff: UInt32 = 757
        static let clientGetDepotDecryptionKey: UInt32 = 5438
        static let clientLogon: UInt32 = 5514
        static let clientPICSProductInfoRequest: UInt32 = 8903
    }

    struct Packet: Sendable {
        let emsg: UInt32
        let header: SteamProto.Message
        let body: Data
    }

    enum Failure: LocalizedError, Equatable {
        case noServers
        case notLoggedOn
        case disconnected
        case timedOut(String)
        /// Steam refused the logon; 5 means the token is no longer valid, 84 rate limiting.
        case logOnRefused(eresult: Int32)
        case loggedOff(eresult: Int32)
        case requestFailed(String, eresult: Int32)

        var errorDescription: String? {
            switch self {
            case .noServers: "Steam listed no connection server"
            case .notLoggedOn: "Not logged on to Steam"
            case .disconnected: "The connection to Steam closed"
            case .timedOut(let what): "Steam did not answer \(what) in time"
            case .logOnRefused(let eresult): "Steam refused the sign-in (EResult \(eresult))"
            case .loggedOff(let eresult): "Steam ended the session (EResult \(eresult))"
            case .requestFailed(let what, let eresult): "Steam refused \(what) (EResult \(eresult))"
            }
        }
    }

    /// The protocol version the current Steam client sends in its logon.
    static let protocolVersion: UInt64 = 65580
    static let protobufFlag: UInt32 = 0x8000_0000
    static let noJob = UInt64.max
    /// `k_EOSTypeMacOS15`, as a uint32.
    static let osType = UInt64(UInt32(bitPattern: -71))

    private let api: any SteamWebAPI
    private let opener: any SteamCMSocketOpening
    private let timeout: Duration
    /// The region hint SteamCMD's runs get (`SteamCMDDownloadRegion`): a mainland cell on a Mac
    /// in mainland China, which Steam narrows to its nearest mainland cell or, from an address
    /// abroad, replaces with its own choice.
    private let downloadRegion: @Sendable () -> SteamCMDDownloadRegion
    private var socket: (any SteamCMSocket)?
    private var steamID: UInt64 = 0
    private var sessionID: Int32 = 0
    private var nextJobID: UInt64 = 1
    private var jobs: [UInt64: CheckedContinuation<Packet, any Error>] = [:]
    /// Each pending job's send-then-time-out task, cancelled as soon as the job ends.
    private var timers: [UInt64: Task<Void, Never>] = [:]
    private var receiveTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private(set) var isLoggedOn = false
    /// Steam's guess at this Mac's region, used to pick nearby content servers.
    private(set) var cellID: UInt32 = 0

    init(api: any SteamWebAPI = URLSessionSteamWebAPI(),
         opener: any SteamCMSocketOpening = URLSessionCMSocketOpener(),
         timeout: Duration = .seconds(30),
         downloadRegion: @escaping @Sendable () -> SteamCMDDownloadRegion = { .steamsChoice }) {
        self.api = api
        self.opener = opener
        self.timeout = timeout
        self.downloadRegion = downloadRegion
    }

    /// Connects to the first reachable connection manager and logs on with the token.
    func logOn(with token: SteamRefreshToken, machineName: String) async throws {
        disconnect()
        // Given as SteamCMD gives it: the cell the connection servers are listed for and the one
        // the logon starts from. Content servers then come from the cell Steam answers with.
        let hint = downloadRegion().cell.flatMap { UInt32(exactly: $0) }
        let endpoints = try await connectionManagers(cell: hint ?? cellID)
        var lastError: any Error = Failure.noServers
        for endpoint in endpoints.prefix(3) {
            do {
                socket = try await opener.open(endpoint: endpoint)
                break
            } catch {
                lastError = error
                AppLog.warn("Steam connection server \(endpoint) could not be reached (\(error.localizedDescription))")
            }
        }
        guard let socket else { throw lastError }
        steamID = token.steamID
        sessionID = 0
        startReceiving(from: socket)
        do {
            try await completeLogOn(with: token, machineName: machineName, cellHint: hint)
        } catch {
            // Whatever went wrong, the socket and its receive loop go with the attempt.
            disconnect()
            throw error
        }
    }

    private func completeLogOn(with token: SteamRefreshToken, machineName: String, cellHint: UInt32?) async throws {
        var body = SteamProto.Writer()
        body.varint(1, Self.protocolVersion)
        if let cellHint { body.varint(3, UInt64(cellHint)) }
        body.string(6, "english")
        body.varint(7, Self.osType)
        body.bool(8, true)
        var privateIP = SteamProto.Writer()
        privateIP.varint(1, 0)
        body.message(11, privateIP)
        body.bytes(30, Self.machineID(for: token.accountName))
        body.varint(33, 2)
        body.string(96, machineName)
        body.bool(102, true)
        body.string(108, token.value)
        let response = try await exchange(EMsg.clientLogon, body.data, awaiting: .logOn, what: "the sign-in")
        let result = try SteamProto.Message(response.body)
        let eresult = result.int32(1) ?? 2
        guard eresult == 1 else { throw Failure.logOnRefused(eresult: eresult) }
        steamID = response.header.fixed64(1) ?? steamID
        sessionID = response.header.int32(2) ?? 0
        cellID = UInt32(truncatingIfNeeded: result.varint(7) ?? 0)
        isLoggedOn = true
        let heartbeat = max(Int(result.int32(3) ?? 9), 5)
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(heartbeat))
                await self?.sendHeartbeat()
            }
        }
    }

    /// Calls a unified service method such as `PublishedFile.GetDetails#1`.
    func serviceMethod(_ name: String, _ request: Data) async throws -> SteamProto.Message {
        guard isLoggedOn else { throw Failure.notLoggedOn }
        let response = try await exchange(EMsg.serviceMethodCallFromClient, request, awaiting: .job,
                                          jobName: name, what: name)
        if let eresult = response.header.int32(13), eresult != 1 {
            throw Failure.requestFailed(name, eresult: eresult)
        }
        return try SteamProto.Message(response.body)
    }

    /// A classic request answered by a reply that names its job.
    func request(_ emsg: UInt32, _ body: Data, what: String) async throws -> SteamProto.Message {
        guard isLoggedOn else { throw Failure.notLoggedOn }
        return try SteamProto.Message(try await exchange(emsg, body, awaiting: .job, what: what).body)
    }

    func logOff() async {
        if isLoggedOn, let socket {
            try? await socket.send(frame(EMsg.clientLogOff, body: Data(), jobID: Self.noJob, jobName: nil))
        }
        disconnect()
    }

    func disconnect() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        socket?.close()
        socket = nil
        isLoggedOn = false
        failAll(Failure.disconnected)
    }

    // MARK: - Messages

    private enum Awaiting { case logOn, job }

    /// The job id 0 stands for the logon reply, which Steam sends without one.
    private static let logOnJob: UInt64 = 0

    private func exchange(_ emsg: UInt32, _ body: Data, awaiting: Awaiting, jobName: String? = nil,
                          what: String) async throws -> Packet {
        guard let socket else { throw Failure.disconnected }
        let jobID: UInt64
        switch awaiting {
        case .logOn: jobID = Self.logOnJob
        case .job:
            jobID = nextJobID
            nextJobID += 1
        }
        let data = frame(emsg, body: body, jobID: awaiting == .job ? jobID : Self.noJob, jobName: jobName)
        let timeout = timeout
        // A paused or cancelled download must not wait for Steam to answer or for the timeout.
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { return continuation.resume(throwing: CancellationError()) }
                jobs[jobID] = continuation
                timers[jobID] = Task { [weak self] in
                    do {
                        try await socket.send(data)
                    } catch {
                        await self?.finish(jobID, with: .failure(error))
                        return
                    }
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled else { return }
                    await self?.finish(jobID, with: .failure(Failure.timedOut(what)))
                }
            }
        } onCancel: {
            Task { await self.finish(jobID, with: .failure(CancellationError())) }
        }
    }

    private func finish(_ jobID: UInt64, with result: Result<Packet, any Error>) {
        timers.removeValue(forKey: jobID)?.cancel()
        jobs.removeValue(forKey: jobID)?.resume(with: result)
    }

    private func failAll(_ error: any Error) {
        for timer in timers.values { timer.cancel() }
        timers = [:]
        let pending = jobs
        jobs = [:]
        for continuation in pending.values { continuation.resume(throwing: error) }
    }

    private func sendHeartbeat() async {
        guard isLoggedOn, let socket else { return }
        try? await socket.send(frame(EMsg.clientHeartBeat, body: Data(), jobID: Self.noJob, jobName: nil))
    }

    func frame(_ emsg: UInt32, body: Data, jobID: UInt64, jobName: String?) -> Data {
        var header = SteamProto.Writer()
        header.fixed64(1, steamID)
        header.varint(2, UInt64(UInt32(bitPattern: sessionID)))
        header.fixed64(10, jobID)
        if let jobName { header.string(12, jobName) }
        var data = Data()
        withUnsafeBytes(of: (emsg | Self.protobufFlag).littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(header.data.count).littleEndian) { data.append(contentsOf: $0) }
        data.append(header.data)
        data.append(body)
        return data
    }

    private func startReceiving(from socket: any SteamCMSocket) {
        receiveTask = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let data = try await socket.receive()
                    await self?.handle(data)
                }
            } catch {
                await self?.connectionEnded(error)
            }
        }
    }

    private func connectionEnded(_ error: any Error) {
        guard socket != nil else { return }
        AppLog.info("Steam connection closed (\(error.localizedDescription))")
        isLoggedOn = false
        socket = nil
        heartbeatTask?.cancel()
        failAll(Failure.disconnected)
    }

    func handle(_ data: Data) {
        let packets: [Packet]
        do {
            packets = try Self.packets(in: data)
        } catch {
            AppLog.warn("Steam sent a message the app could not read (\(error.localizedDescription))")
            return
        }
        for packet in packets { route(packet) }
    }

    private func route(_ packet: Packet) {
        switch packet.emsg {
        case EMsg.clientLogOnResponse:
            finish(Self.logOnJob, with: .success(packet))
        case EMsg.clientLoggedOff:
            let eresult = (try? SteamProto.Message(packet.body))?.int32(1) ?? 0
            AppLog.info("Steam ended the session (EResult \(eresult))")
            isLoggedOn = false
            failAll(Failure.loggedOff(eresult: eresult))
        default:
            if let target = packet.header.fixed64(11), target != Self.noJob, target != Self.logOnJob {
                finish(target, with: .success(packet))
            }
        }
    }

    /// Splits one frame into its messages, unpacking `Multi` bundles (gzip-compressed or not).
    static func packets(in data: Data) throws -> [Packet] {
        var reader = SteamProto.Reader(data: data)
        let raw = try reader.littleEndian(UInt32.self)
        // Only protobuf-headed messages matter here; the legacy binary header is not used
        // for anything this client asks for.
        guard raw & protobufFlag != 0 else { return [] }
        let headerLength = Int(try reader.littleEndian(UInt32.self))
        let header = try SteamProto.Message(try reader.bytes(count: headerLength))
        let body = try reader.bytes(count: data.endIndex - reader.offset)
        let emsg = raw & ~protobufFlag
        guard emsg == EMsg.multi else { return [Packet(emsg: emsg, header: header, body: body)] }

        let multi = try SteamProto.Message(body)
        var payload = multi.bytes(2) ?? Data()
        if let size = multi.varint(1), size > 0 {
            guard let expected = Int(exactly: size) else { throw SteamProto.DecodingError(reason: "Multi size \(size)") }
            payload = try gunzip(payload, expectedSize: expected)
        }
        var inner = SteamProto.Reader(data: payload)
        var packets: [Packet] = []
        while !inner.isAtEnd {
            let length = Int(try inner.littleEndian(UInt32.self))
            packets += try Self.packets(in: try inner.bytes(count: length))
        }
        return packets
    }

    static func gunzip(_ data: Data, expectedSize: Int) throws -> Data {
        // RFC 1952: a 10-byte header, optional fields, the raw deflate stream, an 8-byte trailer.
        guard data.count > 18, data[data.startIndex] == 0x1F, data[data.startIndex + 1] == 0x8B else {
            throw SteamProto.DecodingError(reason: "Multi body is not gzip")
        }
        let flags = data[data.startIndex + 3]
        var offset = data.startIndex + 10
        if flags & 0x04 != 0, offset + 2 <= data.endIndex {
            offset += 2 + Int(data[offset]) + Int(data[offset + 1]) << 8
        }
        for flag: UInt8 in [0x08, 0x10] where flags & flag != 0 {
            while offset < data.endIndex, data[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x02 != 0 { offset += 2 }
        guard offset < data.endIndex - 8 else { throw SteamProto.DecodingError(reason: "truncated gzip") }
        let inflated = try (data[offset..<data.endIndex - 8] as NSData).decompressed(using: .zlib) as Data
        guard inflated.count == expectedSize else {
            throw SteamProto.DecodingError(reason: "Multi unpacked to \(inflated.count) bytes, expected \(expectedSize)")
        }
        return inflated
    }

    /// The binary KeyValues object Steam expects as `machine_id`: three SHA-1 hex strings.
    /// Derived from the account alone, so every sign-in of an account reads as one machine,
    /// on this Mac and on any other; the device name tells them apart in Steam's list.
    static func machineID(for accountName: String) -> Data {
        var data = Data([0])
        data.append(contentsOf: Array("MessageObject".utf8) + [0])
        for key in ["BB3", "FF2", "3B3"] {
            data.append(1)
            data.append(contentsOf: Array(key.utf8) + [0])
            data.append(contentsOf: Array(SteamDepotCrypto.sha1Hex("WallpaperMachine \(key) \(accountName)").utf8) + [0])
        }
        data.append(contentsOf: [8, 8])
        return data
    }

    // MARK: - Directory

    private func connectionManagers(cell: UInt32) async throws -> [String] {
        let data = try await api.json("ISteamDirectory/GetCMListForConnect/v1/",
                                      query: [URLQueryItem(name: "cellid", value: String(cell))])
        struct Directory: Decodable {
            struct Response: Decodable { let serverlist: [Server] }
            struct Server: Decodable { let endpoint: String; let type: String }
            let response: Response
        }
        let servers = try JSONDecoder().decode(Directory.self, from: data).response.serverlist
        let endpoints = servers.filter { $0.type == "websockets" }.map(\.endpoint)
        guard !endpoints.isEmpty else { throw Failure.noServers }
        return endpoints
    }
}

struct URLSessionCMSocketOpener: SteamCMSocketOpening {
    func open(endpoint: String) async throws -> any SteamCMSocket {
        guard let url = URL(string: "wss://\(endpoint)/cmsocket/") else { throw SteamCMConnection.Failure.noServers }
        let task = URLSession.shared.webSocketTask(with: url)
        // A Multi bundle can carry several large replies at once.
        task.maximumMessageSize = 32 * 1024 * 1024
        task.resume()
        // Resuming connects in the background; a ping answered proves the server is there, so
        // `logOn` can move on to the next listed server when it is not.
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    task.sendPing { error in
                        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                    }
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                // Cancelling the task answers the ping with an error, so the group can finish.
                task.cancel(with: .goingAway, reason: nil)
                throw SteamCMConnection.Failure.timedOut("the connection server")
            }
            do {
                try await group.next()
                group.cancelAll()
            } catch {
                task.cancel(with: .goingAway, reason: nil)
                throw error
            }
        }
        return URLSessionCMSocket(task: task)
    }
}

struct URLSessionCMSocket: SteamCMSocket {
    let task: URLSessionWebSocketTask

    func send(_ data: Data) async throws {
        try await task.send(.data(data))
    }

    func receive() async throws -> Data {
        switch try await task.receive() {
        case .data(let data): return data
        case .string(let text): return Data(text.utf8)
        @unknown default: return Data()
        }
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
    }
}
