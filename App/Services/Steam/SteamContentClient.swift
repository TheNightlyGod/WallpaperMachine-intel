import Foundation

/// Unpacks a decrypted chunk or manifest. The app uses the Rust bridge, which has the zstd
/// and LZMA decoders macOS lacks; tests substitute their own.
protocol SteamContentDecompressing: Sendable {
    func decompress(_ data: Data) throws -> Data
}

struct BridgeSteamContentDecompressor: SteamContentDecompressing {
    func decompress(_ data: Data) throws -> Data {
        try decompressSteamContent(data: data)
    }
}

/// Plain HTTP GETs against Steam's CDN. Injected so tests never reach the network.
protocol SteamContentFetching: Sendable {
    func fetch(_ url: URL) async throws -> Data
}

struct URLSessionSteamContentFetcher: SteamContentFetching {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetch(_ url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw SteamContentClient.Failure.http(status: status, url: url) }
        return data
    }
}

/// A Workshop item as the download needs it.
struct SteamPublishedFile: Sendable, Equatable {
    let id: UInt64
    /// Steam's EResult for this item: 1 when it is available.
    let result: Int32
    let title: String
    let appID: UInt32
    /// The depot manifest that holds the item's files; 0 for items served as one plain file.
    let manifestID: UInt64
    let fileURL: String?
    let size: UInt64
    let timeUpdated: Date?
}

/// Downloads depot content (Workshop items, the scene-resources depot) for a session that is
/// logged on to Steam: details and keys come from the connection manager, bytes from the CDN.
actor SteamContentClient {
    enum Failure: LocalizedError, Equatable {
        case itemUnavailable(UInt64, eresult: Int32)
        case notDepotContent(UInt64)
        case noContentServers
        case http(status: Int, url: URL)
        case unsafePath(String)
        case chunkMismatch(String)
        case wrongApp(UInt64, app: UInt32)
        case insufficientSpace(needed: Int64, available: Int64)

        var errorDescription: String? {
            switch self {
            case .wrongApp(let id, let app): "Workshop item \(id) belongs to app \(app), not the one asked for"
            case .insufficientSpace(let needed, let available): "Not enough free space (\(needed) bytes needed, \(available) available)"
            case .itemUnavailable(let id, let eresult): "Workshop item \(id) is not available (EResult \(eresult))"
            case .notDepotContent(let id): "Workshop item \(id) has no Steam depot content"
            case .noContentServers: "Steam listed no content server"
            case .http(let status, let url): "Steam's content server answered HTTP \(status) for \(url.path)"
            case .unsafePath(let path): "Steam listed a file outside the download folder: \(path)"
            case .chunkMismatch(let id): "A downloaded piece did not match Steam's checksum (\(id))"
            }
        }
    }

    /// What a refused request names in `SteamCMConnection.Failure.requestFailed`.
    static let itemDetailsMethod = "PublishedFile.GetDetails#1"
    static let depotKeyRequest = "the depot key"

    struct ContentServer: Sendable, Equatable {
        let base: URL
    }

    private let connection: SteamCMConnection
    private let api: any SteamWebAPI
    private let fetcher: any SteamContentFetching
    private let decompressor: any SteamContentDecompressing
    private let parallelChunks: Int
    private let freeSpace: @Sendable (URL) -> Int64?
    private var depotKeys: [UInt32: Data] = [:]
    private var servers: [ContentServer] = []

    init(connection: SteamCMConnection,
         api: any SteamWebAPI = URLSessionSteamWebAPI(),
         fetcher: any SteamContentFetching = URLSessionSteamContentFetcher(),
         decompressor: any SteamContentDecompressing = BridgeSteamContentDecompressor(),
         parallelChunks: Int = 6,
         freeSpace: @escaping @Sendable (URL) -> Int64? = WorkshopDownloader.systemFreeSpace) {
        self.connection = connection
        self.freeSpace = freeSpace
        self.api = api
        self.fetcher = fetcher
        self.decompressor = decompressor
        self.parallelChunks = max(parallelChunks, 1)
    }

    func publishedFile(_ id: UInt64) async throws -> SteamPublishedFile {
        var request = SteamProto.Writer()
        request.fixed64(1, id)
        let response = try await connection.serviceMethod(Self.itemDetailsMethod, request.data)
        guard let details = try response.messages(1).first(where: { $0.varint(2) == id }) else {
            throw Failure.itemUnavailable(id, eresult: 9)
        }
        let updated = details.varint(20).flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil }
        return SteamPublishedFile(
            id: id, result: details.int32(1) ?? 2, title: details.string(16) ?? "",
            appID: UInt32(truncatingIfNeeded: details.varint(5) ?? 0), manifestID: details.fixed64(14) ?? 0,
            fileURL: details.string(10).flatMap { $0.isEmpty ? nil : $0 }, size: details.varint(8) ?? 0,
            timeUpdated: updated)
    }

    /// Downloads a Workshop item of `app` into `directory`, which must exist and be empty. An
    /// item of any other app is refused: ids can come from author-written files (a preset's base).
    func downloadWorkshopItem(_ id: UInt64, of app: UInt32, into directory: URL,
                              progress: @escaping @Sendable (_ done: UInt64, _ total: UInt64) -> Void) async throws -> SteamPublishedFile {
        let item = try await publishedFile(id)
        guard item.result == 1 else { throw Failure.itemUnavailable(id, eresult: item.result) }
        guard item.appID == app else { throw Failure.wrongApp(id, app: item.appID) }
        guard item.manifestID != 0 else { throw Failure.notDepotContent(id) }
        // Workshop content lives in a depot named after the app that consumes it.
        let manifest = try await manifest(app: item.appID, depot: item.appID, manifestID: item.manifestID)
        try await download(manifest, app: item.appID, depot: item.appID, into: directory, progress: progress)
        return item
    }

    /// Downloads the current public version of a depot (such as Wallpaper Engine's shared
    /// scene resources) into `directory`.
    func downloadDepot(app: UInt32, depot: UInt32, branch: String = "public", into directory: URL,
                       progress: @escaping @Sendable (_ done: UInt64, _ total: UInt64) -> Void) async throws -> UInt64 {
        let manifestID = try await currentManifestID(app: app, depot: depot, branch: branch)
        let manifest = try await manifest(app: app, depot: depot, manifestID: manifestID, branch: branch)
        try await download(manifest, app: app, depot: depot, into: directory, progress: progress)
        return manifestID
    }

    /// The manifest a branch of a depot currently points at, from the app's product info (PICS).
    func currentManifestID(app: UInt32, depot: UInt32, branch: String = "public") async throws -> UInt64 {
        var appRequest = SteamProto.Writer()
        appRequest.varint(1, UInt64(app))
        var request = SteamProto.Writer()
        request.message(2, appRequest)
        request.bool(3, false)
        let response = try await connection.request(SteamCMConnection.EMsg.clientPICSProductInfoRequest, request.data,
                                                    what: "the app's product info")
        guard let info = try response.messages(1).first(where: { $0.varint(1) == UInt64(app) }),
              let buffer = info.bytes(5), let text = String(data: buffer, encoding: .utf8) else {
            throw SteamCMConnection.Failure.requestFailed("the app's product info", eresult: 9)
        }
        let gid = try SteamKeyValues.parse(text)["appinfo"]?["depots"]?[String(depot)]?["manifests"]?[branch]
        // Older product info lists the id directly; newer wraps it as { "gid" … }.
        guard let id = (gid?["gid"]?.string ?? gid?.string).flatMap(UInt64.init) else {
            throw SteamCMConnection.Failure.requestFailed("depot \(depot)'s \(branch) manifest", eresult: 9)
        }
        return id
    }

    func depotKey(app: UInt32, depot: UInt32) async throws -> Data {
        if let key = depotKeys[depot] { return key }
        var request = SteamProto.Writer()
        request.varint(1, UInt64(depot))
        request.varint(2, UInt64(app))
        let response = try await connection.request(SteamCMConnection.EMsg.clientGetDepotDecryptionKey, request.data,
                                                    what: Self.depotKeyRequest)
        let eresult = response.int32(1) ?? 2
        guard eresult == 1, let key = response.bytes(3) else {
            throw SteamCMConnection.Failure.requestFailed(Self.depotKeyRequest, eresult: eresult)
        }
        depotKeys[depot] = key
        return key
    }

    func manifest(app: UInt32, depot: UInt32, manifestID: UInt64, branch: String = "public") async throws -> SteamDepotManifest {
        // The key comes first although only encrypted names and the chunks need it: Steam gives
        // it only to an account that owns the app, so a refusal says so before anything else.
        let key = try await depotKey(app: app, depot: depot)
        var request = SteamProto.Writer()
        request.varint(1, UInt64(app))
        request.varint(2, UInt64(depot))
        request.varint(3, manifestID)
        request.string(4, branch)
        let code = try await connection.serviceMethod("ContentServerDirectory.GetManifestRequestCode#1", request.data)
        guard let requestCode = code.varint(1) else {
            throw SteamCMConnection.Failure.requestFailed("the manifest request code", eresult: 2)
        }
        let packed = try await fetchFromAnyServer("depot/\(depot)/manifest/\(manifestID)/5/\(requestCode)")
        var manifest = try SteamDepotManifest(try decompressor.decompress(packed))
        if manifest.filenamesEncrypted {
            try manifest.decryptFilenames(key: key)
        }
        return manifest
    }

    /// Writes every file of `manifest` under `directory`, fetching up to `parallelChunks`
    /// chunks at a time. Nothing is written outside `directory`.
    func download(_ manifest: SteamDepotManifest, app: UInt32, depot: UInt32, into directory: URL,
                  progress: @escaping @Sendable (_ done: UInt64, _ total: UInt64) -> Void) async throws {
        let key = try await depotKey(app: app, depot: depot)
        let root = directory.standardizedFileURL
        // The same allowance a SteamCMD download gets, from the manifest's exact size.
        let measure = freeSpace
        if let needed = WorkshopDownloader.requiredFreeBytes(
               expected: Int64(clamping: manifest.totalSize), alreadyStaged: 0, installingAssets: false),
           let available = await Task.detached(priority: .utility, operation: { measure(root) }).value,
           available < needed {
            throw Failure.insufficientSpace(needed: needed, available: available)
        }
        let fileManager = FileManager.default
        var pieces: [(file: URL, chunk: SteamDepotManifest.Chunk)] = []
        for file in manifest.files {
            let destination = try Self.destination(of: file.path, in: root)
            if file.isDirectory {
                try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
                continue
            }
            if file.linkTarget != nil {
                AppLog.info("Steam depot \(depot): skipped link \(file.path)")
                continue
            }
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard fileManager.createFile(atPath: destination.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: destination.path])
            }
            let handle = try FileHandle(forWritingTo: destination)
            try handle.truncate(atOffset: file.size)
            try handle.close()
            pieces += file.chunks.map { (destination, $0) }
        }

        let total = manifest.totalSize
        var done: UInt64 = 0
        progress(0, total)
        try await withThrowingTaskGroup(of: (URL, SteamDepotManifest.Chunk, Data).self) { group in
            var next = pieces.makeIterator()
            func addNext() async {
                guard let piece = next.next() else { return }
                group.addTask { [self] in
                    (piece.file, piece.chunk, try await chunk(piece.chunk, depot: depot, key: key))
                }
            }
            for _ in 0..<parallelChunks { await addNext() }
            while let (file, chunk, data) = try await group.next() {
                let handle = try FileHandle(forWritingTo: file)
                try handle.seek(toOffset: chunk.offset)
                try handle.write(contentsOf: data)
                try handle.close()
                done += UInt64(data.count)
                progress(done, total)
                await addNext()
            }
        }
    }

    /// Fetches one chunk and returns its verified, unpacked bytes. Nonisolated, so chunks are
    /// decrypted and unpacked in parallel rather than one at a time on the actor.
    nonisolated func chunk(_ chunk: SteamDepotManifest.Chunk, depot: UInt32, key: Data) async throws -> Data {
        let packed = try await fetchFromAnyServer("depot/\(depot)/chunk/\(chunk.hexID)")
        return try Self.unpack(packed, chunk: chunk, key: key, decompressor: decompressor)
    }

    /// Decrypts, unpacks and verifies one chunk.
    static func unpack(_ packed: Data, chunk: SteamDepotManifest.Chunk, key: Data,
                       decompressor: any SteamContentDecompressing) throws -> Data {
        let data = try decompressor.decompress(try SteamDepotCrypto.decrypt(packed, key: key))
        guard data.count == Int(chunk.originalSize), SteamDepotCrypto.sha1(data) == chunk.id else {
            throw Failure.chunkMismatch(chunk.hexID)
        }
        return data
    }

    /// Resolves a depot path under `root`, refusing anything that would land outside it.
    static func destination(of path: String, in root: URL) throws -> URL {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !path.hasPrefix("/"), !components.isEmpty,
              components.allSatisfy({ $0 != ".." && $0 != "." }) else { throw Failure.unsafePath(path) }
        let destination = components.reduce(root) { $0.appending(path: String($1)) }.standardizedFileURL
        guard destination.path.hasPrefix(root.path + "/") else { throw Failure.unsafePath(path) }
        return destination
    }

    // MARK: - Content servers

    /// Tries each content server in turn (up to three), so one bad server does not fail the download.
    private func fetchFromAnyServer(_ path: String) async throws -> Data {
        let servers = try await contentServers()
        var lastError: any Error = Failure.noContentServers
        for (index, server) in servers.prefix(3).enumerated() {
            do {
                let data = try await fetcher.fetch(server.base.appending(path: path))
                // A server that answered after others failed goes first for the requests that follow.
                if index > 0, let current = self.servers.firstIndex(of: server), current > 0 {
                    self.servers.insert(self.servers.remove(at: current), at: 0)
                }
                return data
            } catch {
                lastError = error
                if error is CancellationError { throw error }
                AppLog.debug("Steam content server \(server.base.host() ?? "?") failed for \(path) (\(error.localizedDescription))")
            }
        }
        // Rotate so the next request starts with a different server.
        if self.servers.count > 1 { self.servers.append(self.servers.removeFirst()) }
        throw lastError
    }

    private func contentServers() async throws -> [ContentServer] {
        if !servers.isEmpty { return servers }
        let cell = await connection.cellID
        let data = try await api.json("IContentServerDirectoryService/GetServersForSteamPipe/v1/",
                                      query: [URLQueryItem(name: "cell_id", value: String(cell))])
        servers = try Self.contentServers(fromJSON: data)
        guard !servers.isEmpty else { throw Failure.noContentServers }
        return servers
    }

    static func contentServers(fromJSON data: Data) throws -> [ContentServer] {
        struct Directory: Decodable {
            struct Response: Decodable { let servers: [Server] }
            struct Server: Decodable {
                let type: String
                let host: String
                let https_support: String?
            }
            let response: Response
        }
        return try JSONDecoder().decode(Directory.self, from: data).response.servers.compactMap { server in
            // Content travels over HTTPS only; a server that cannot serve it is skipped.
            guard server.type == "CDN" || server.type == "SteamCache", server.https_support != "unavailable" else { return nil }
            return URL(string: "https://\(server.host)/").map(ContentServer.init)
        }
    }
}
