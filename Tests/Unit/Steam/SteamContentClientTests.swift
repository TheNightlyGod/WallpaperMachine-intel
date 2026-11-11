import XCTest
@testable import WallpaperMachine

/// Depot manifests, chunk handling and a whole Workshop download against a scripted Steam.
final class SteamContentClientTests: XCTestCase {
    private let key = Data((0..<32).map { UInt8($0) })
    private let iv = Data((100..<116).map { UInt8($0) })
    private let appID: UInt32 = 431_960
    private let itemID: UInt64 = 3_521_337_568
    private let manifestID: UInt64 = 6_161_419_052_622_875_408

    func testSteamEncryptionRoundTripsAndRejectsTheWrongKey() throws {
        let plain = Data("scene.pkg".utf8)
        let encrypted = try SteamDepotCrypto.encrypt(plain, key: key, iv: iv)
        XCTAssertEqual(try SteamDepotCrypto.decrypt(encrypted, key: key), plain)
        // A wrong key fails the padding or yields other bytes; chunks are caught by their SHA-1.
        XCTAssertNotEqual(try? SteamDepotCrypto.decrypt(encrypted, key: Data(repeating: 9, count: 32)), plain)
        XCTAssertThrowsError(try SteamDepotCrypto.decrypt(Data(count: 5), key: key))
    }

    func testManifestReadsFilesAndDecryptsTheirNames() throws {
        let names = [#"materials\sky.png"#, "project.json"]
        var manifest = try SteamDepotManifest(try manifestData(names: names, encrypted: true, chunks: [[], []]))
        XCTAssertTrue(manifest.filenamesEncrypted)
        try manifest.decryptFilenames(key: key)
        XCTAssertEqual(manifest.files.map(\.path), ["materials/sky.png", "project.json"])
        XCTAssertEqual(manifest.depotID, appID)
        XCTAssertEqual(manifest.manifestID, manifestID)
        XCTAssertThrowsError(try SteamDepotManifest(Data([1, 2, 3, 4, 5, 6, 7, 8])))
    }

    func testDestinationsStayInsideTheDownloadFolder() throws {
        let root = URL(fileURLWithPath: "/tmp/item")
        XCTAssertEqual(try SteamContentClient.destination(of: "materials/sky.png", in: root).path,
                       "/tmp/item/materials/sky.png")
        for path in ["../escape", "/etc/hosts", "a/../../b", "", "./x"] {
            XCTAssertThrowsError(try SteamContentClient.destination(of: path, in: root), path)
        }
    }

    func testAChunkThatDoesNotMatchItsChecksumIsRejected() throws {
        let data = Data("real content".utf8)
        let chunk = SteamDepotManifest.Chunk(id: SteamDepotCrypto.sha1(Data("other".utf8)), offset: 0,
                                             originalSize: UInt32(data.count), compressedSize: 0)
        let packed = try SteamDepotCrypto.encrypt(PrefixDecompressor.pack(data), key: key, iv: iv)
        XCTAssertThrowsError(try SteamContentClient.unpack(packed, chunk: chunk, key: key, decompressor: PrefixDecompressor()))
    }

    func testDownloadingAWorkshopItemWritesEveryFileFromItsChunks() async throws {
        let steam = try await scriptedDownload()
        defer { steam.cleanUp() }
        let reports = ProgressLog()

        let item = try await steam.client.downloadWorkshopItem(itemID, of: appID, into: steam.folder) { done, total in
            reports.add(done, total)
        }

        XCTAssertEqual(item.title, "Lucy")
        XCTAssertEqual(try Data(contentsOf: steam.folder.appending(path: "scene.pkg")), steam.big)
        XCTAssertEqual(try Data(contentsOf: steam.folder.appending(path: "materials/project.json")), steam.small)
        XCTAssertEqual(reports.last?.done, 3000 + UInt64(steam.small.count))
        XCTAssertEqual(reports.last?.total, 3000 + UInt64(steam.small.count))
        XCTAssertTrue(steam.fetcher.requests.allSatisfy { $0.hasPrefix("depot/") })
        await steam.connection.disconnect()
    }

    func testAnItemOfAnotherAppIsRefusedBeforeAnythingIsFetched() async throws {
        let steam = try await scriptedDownload(itemApp: 480)
        defer { steam.cleanUp() }
        do {
            _ = try await steam.client.downloadWorkshopItem(itemID, of: appID, into: steam.folder) { _, _ in }
            XCTFail("expected the refusal")
        } catch {
            XCTAssertEqual(error as? SteamContentClient.Failure, .wrongApp(itemID, app: 480))
        }
        XCTAssertEqual(steam.fetcher.requests, [])
        await steam.connection.disconnect()
    }

    func testADownloadThatDoesNotFitFailsBeforeAnyChunkIsFetched() async throws {
        let steam = try await scriptedDownload(freeSpace: 1024)
        defer { steam.cleanUp() }
        do {
            _ = try await steam.client.downloadWorkshopItem(itemID, of: appID, into: steam.folder) { _, _ in }
            XCTFail("expected the refusal")
        } catch {
            guard case .insufficientSpace(let needed, let available)? = error as? SteamContentClient.Failure else {
                return XCTFail("got \(error)")
            }
            XCTAssertEqual(available, 1024)
            XCTAssertGreaterThan(needed, available)
        }
        XCTAssertFalse(steam.fetcher.requests.contains { $0.contains("/chunk/") })
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: steam.folder.path), [])
        await steam.connection.disconnect()
    }

    func testAServerThatAnswersAfterAnotherFailedIsTriedFirstFromThenOn() async throws {
        let steam = try await scriptedDownload(servers: [
            #"{"type":"CDN","host":"down.test","https_support":"mandatory"}"#,
            #"{"type":"CDN","host":"cdn.test","https_support":"optional"}"#,
        ], failingHost: "down.test")
        defer { steam.cleanUp() }

        _ = try await steam.client.downloadWorkshopItem(itemID, of: appID, into: steam.folder) { _, _ in }

        XCTAssertEqual(steam.fetcher.hosts.filter { $0 == "down.test" }.count, 1, "only the manifest tried the failing server")
        XCTAssertEqual(try Data(contentsOf: steam.folder.appending(path: "scene.pkg")), steam.big)
        await steam.connection.disconnect()
    }

    func testContentServersAreReachedOverHTTPSOnly() throws {
        let json = #"""
            {"response":{"servers":[
            {"type":"CDN","host":"a.test","https_support":"mandatory"},
            {"type":"SteamCache","host":"b.test","https_support":"optional"},
            {"type":"CDN","host":"plain.test","https_support":"unavailable"},
            {"type":"CS","host":"cs.test","https_support":"mandatory"},
            {"type":"CDN","host":"c.test"}]}}
            """#
        let servers = try SteamContentClient.contentServers(fromJSON: Data(json.utf8))
        XCTAssertEqual(servers.map(\.base.absoluteString), ["https://a.test/", "https://b.test/", "https://c.test/"])
    }

    func testTheCurrentDepotManifestComesFromTheAppsProductInfo() async throws {
        let api = FakeSteamWebAPI()
        api.serve("ISteamDirectory/GetCMListForConnect/v1/",
                  json: #"{"response":{"serverlist":[{"endpoint":"cm.test:443","type":"websockets"}]}}"#)
        let token = SteamTestToken.token()
        let appInfo = #""appinfo" { "depots" { "431961" { "manifests" { "public" { "gid" "5060075082323178717" } } } } }"#
        let steam = ScriptedCMSocket { [appID] packet in
            switch packet.emsg {
            case SteamCMConnection.EMsg.clientLogon:
                return [ScriptedCMSocket.logOnReply(steamID: token.steamID)]
            case SteamCMConnection.EMsg.clientPICSProductInfoRequest:
                let asked = try? SteamProto.Message(packet.body).messages(2).first?.varint(1)
                var app = SteamProto.Writer()
                app.varint(1, asked ?? 0)
                app.bytes(5, Data(appInfo.utf8) + Data([0]))
                var body = SteamProto.Writer()
                body.message(1, app)
                return asked == UInt64(appID)
                    ? [ScriptedCMSocket.frame(8904, jobTarget: packet.header.fixed64(10), body: body)] : []
            default:
                return []
            }
        }
        let connection = SteamCMConnection(api: api, opener: steam, timeout: .seconds(5))
        try await connection.logOn(with: token, machineName: "Test Mac")
        let client = SteamContentClient(connection: connection, api: api, fetcher: FakeSteamContentFetcher(),
                                        decompressor: PrefixDecompressor())
        let manifest = try await client.currentManifestID(app: appID, depot: 431_961)
        XCTAssertEqual(manifest, 5_060_075_082_323_178_717)
        do {
            _ = try await client.currentManifestID(app: appID, depot: 431_962)
            XCTFail("a depot the product info does not list has no manifest")
        } catch is SteamCMConnection.Failure {}
        await connection.disconnect()
    }

    // MARK: - Fixtures

    private struct ScriptedDownload {
        let client: SteamContentClient
        let connection: SteamCMConnection
        let fetcher: FakeSteamContentFetcher
        let folder: URL
        let big: Data
        let small: Data

        func cleanUp() { try? FileManager.default.removeItem(at: folder) }
    }

    /// A logged-on client for a scripted Steam that offers one Workshop item (of `itemApp`)
    /// with a three-chunk file and a small one, served by `servers`.
    private func scriptedDownload(
        itemApp: UInt32? = nil, freeSpace: Int64? = nil,
        servers: [String] = [#"{"type":"CDN","host":"cdn.test","https_support":"mandatory"}"#, #"{"type":"CS","host":"skip.test"}"#],
        failingHost: String? = nil
    ) async throws -> ScriptedDownload {
        let big = Data((0..<3000).map { UInt8($0 % 251) })
        let small = Data("{\"title\":\"Lucy\"}".utf8)
        let bigChunks = [big.prefix(1000), big.dropFirst(1000).prefix(1000), big.dropFirst(2000)].map(Data.init)
        let fetcher = FakeSteamContentFetcher(failingHost: failingHost)
        let manifest = try manifestData(names: ["scene.pkg", "materials", #"materials\project.json"#], encrypted: true,
                                        chunks: [bigChunks.enumerated().map { ($0.element, UInt64($0.offset * 1000)) },
                                                 [], [(small, 0)]],
                                        sizes: [3000, 0, UInt64(small.count)], flags: [0, 64, 0])
        fetcher.serve("depot/\(appID)/manifest/\(manifestID)/5/777", PrefixDecompressor.pack(manifest))
        for piece in bigChunks + [small] {
            let id = SteamDepotCrypto.sha1(piece).map { String(format: "%02x", $0) }.joined()
            fetcher.serve("depot/\(appID)/chunk/\(id)", try SteamDepotCrypto.encrypt(PrefixDecompressor.pack(piece), key: key, iv: iv))
        }
        let api = FakeSteamWebAPI()
        api.serve("ISteamDirectory/GetCMListForConnect/v1/",
                  json: #"{"response":{"serverlist":[{"endpoint":"cm.test:443","type":"websockets"}]}}"#)
        api.serve("IContentServerDirectoryService/GetServersForSteamPipe/v1/",
                  json: #"{"response":{"servers":["# + servers.joined(separator: ",") + "]}}")
        let token = SteamTestToken.token()
        let detailsApp = itemApp ?? appID
        let steam = ScriptedCMSocket { [key, appID, itemID, manifestID] packet in
            let job = packet.header.fixed64(10) ?? SteamCMConnection.noJob
            var body = SteamProto.Writer()
            switch (packet.emsg, packet.header.string(12)) {
            case (SteamCMConnection.EMsg.clientLogon, _):
                return [ScriptedCMSocket.logOnReply(steamID: token.steamID)]
            case (_, "PublishedFile.GetDetails#1"):
                var details = SteamProto.Writer()
                details.varint(1, 1)
                details.varint(2, itemID)
                details.varint(5, UInt64(detailsApp))
                details.varint(8, 3000)
                details.fixed64(14, manifestID)
                details.string(16, "Lucy")
                body.message(1, details)
            case (_, "ContentServerDirectory.GetManifestRequestCode#1"):
                body.varint(1, 777)
            case (SteamCMConnection.EMsg.clientGetDepotDecryptionKey, _):
                body.varint(1, 1)
                body.varint(2, UInt64(appID))
                body.bytes(3, key)
                return [ScriptedCMSocket.frame(5439, jobTarget: job, body: body)]
            default:
                return []
            }
            return [ScriptedCMSocket.frame(SteamCMConnection.EMsg.serviceMethodResponse, jobTarget: job, eresult: 1, body: body)]
        }
        let connection = SteamCMConnection(api: api, opener: steam, timeout: .seconds(5))
        try await connection.logOn(with: token, machineName: "Test Mac")
        let client = SteamContentClient(connection: connection, api: api, fetcher: fetcher,
                                        decompressor: PrefixDecompressor(), parallelChunks: 2,
                                        freeSpace: { _ in freeSpace ?? .max })
        let folder = FileManager.default.temporaryDirectory.appending(path: "SteamContent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return ScriptedDownload(client: client, connection: connection, fetcher: fetcher, folder: folder, big: big, small: small)
    }

    /// A depot manifest in Steam's sectioned format. `chunks[i]` lists each chunk of file `i`
    /// with its offset.
    private func manifestData(names: [String], encrypted: Bool, chunks: [[(Data, UInt64)]],
                              sizes: [UInt64]? = nil, flags: [UInt32]? = nil) throws -> Data {
        var payload = SteamProto.Writer()
        for (index, name) in names.enumerated() {
            var mapping = SteamProto.Writer()
            let stored = encrypted
                ? try SteamDepotCrypto.encrypt(Data(name.utf8) + Data([0]), key: key, iv: iv).base64EncodedString()
                : name
            mapping.string(1, stored)
            mapping.varint(2, sizes?[index] ?? 0)
            mapping.varint(3, UInt64(flags?[index] ?? 0))
            for (data, offset) in chunks[index] {
                var chunk = SteamProto.Writer()
                chunk.bytes(1, SteamDepotCrypto.sha1(data))
                chunk.varint(3, offset)
                chunk.varint(4, UInt64(data.count))
                chunk.varint(5, UInt64(data.count))
                mapping.message(6, chunk)
            }
            payload.message(1, mapping)
        }
        var metadata = SteamProto.Writer()
        metadata.varint(1, UInt64(appID))
        metadata.varint(2, manifestID)
        metadata.bool(4, encrypted)
        var data = Data()
        for (magic, section) in [(SteamDepotManifest.payloadMagic, payload.data), (SteamDepotManifest.metadataMagic, metadata.data)] {
            withUnsafeBytes(of: magic.littleEndian) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: UInt32(section.count).littleEndian) { data.append(contentsOf: $0) }
            data.append(section)
        }
        withUnsafeBytes(of: SteamDepotManifest.endMagic.littleEndian) { data.append(contentsOf: $0) }
        return data
    }
}

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(done: UInt64, total: UInt64)] = []

    func add(_ done: UInt64, _ total: UInt64) { lock.withLock { entries.append((done, total)) } }

    var last: (done: UInt64, total: UInt64)? { lock.withLock { entries.last } }
}
