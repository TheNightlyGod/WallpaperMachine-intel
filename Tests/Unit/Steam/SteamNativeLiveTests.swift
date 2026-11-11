import XCTest
@testable import WallpaperMachine

/// Opt-in checks of the native Steam client against live Steam. Starting a QR session needs
/// no account; the download needs a refresh token from a QR sign-in someone approved:
///
/// ```
/// WALLPAPER_MACHINE_NETWORK_TESTS=1 WALLPAPER_MACHINE_STEAM_TOKEN_FILE=<file> \
///   python3 scripts/test.py --only SteamNativeLiveTests
/// ```
///
/// The token file holds only the token; nothing here prints or keeps it.
final class SteamNativeLiveTests: XCTestCase {
    private func skipUnlessNetworkTestsEnabled() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["WALLPAPER_MACHINE_NETWORK_TESTS"] == "1",
                          "live Steam tests are opt-in; set WALLPAPER_MACHINE_NETWORK_TESTS=1")
    }

    func testLiveQRSessionStartsWithoutAnAccount() async throws {
        try skipUnlessNetworkTestsEnabled()
        let challenge = try await SteamQRSignIn().begin(deviceName: "WallpaperMachine tests")
        XCTAssertTrue(challenge.url.hasPrefix("https://s.team/q/"), challenge.url)
        let progress = try await SteamQRSignIn().poll(challenge)
        XCTAssertEqual(progress, .waiting(scanned: false))
    }

    func testLiveWorkshopDownloadWithARefreshToken() async throws {
        try skipUnlessNetworkTestsEnabled()
        // The token file is a separate opt-in: without it the account-free live checks still pass.
        guard let path = ProcessInfo.processInfo.environment["WALLPAPER_MACHINE_STEAM_TOKEN_FILE"] else {
            throw XCTSkip("set WALLPAPER_MACHINE_STEAM_TOKEN_FILE to a file holding a refresh token")
        }
        executionTimeAllowance = 300
        let raw = try String(contentsOfFile: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let token = try SteamRefreshToken(raw, accountName: "live-test")
        let connection = SteamCMConnection()
        try await connection.logOn(with: token, machineName: "WallpaperMachine tests")
        let client = SteamContentClient(connection: connection)
        let folder = FileManager.default.temporaryDirectory.appending(path: "SteamLive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let started = ContinuousClock.now
        // "Cyberpunk: Edgerunner-Lucy[4K]": a public 32 MB scene served only as depot content.
        let item = try await client.downloadWorkshopItem(3_521_337_568, of: 431_960, into: folder) { _, _ in }
        let elapsed = ContinuousClock.now - started

        // The shared scene resources: the current manifest and one real chunk, not all ~800 MB.
        let resources = try await client.currentManifestID(app: 431_960, depot: 431_961)
        let manifest = try await client.manifest(app: 431_960, depot: 431_961, manifestID: resources)
        XCTAssertGreaterThan(manifest.files.count, 1000)
        XCTAssertFalse(manifest.filenamesEncrypted)
        let piece = try XCTUnwrap(manifest.files.lazy.flatMap(\.chunks).first)
        let key = try await client.depotKey(app: 431_960, depot: 431_961)
        let chunk = try await client.chunk(piece, depot: 431_961, key: key)
        XCTAssertEqual(chunk.count, Int(piece.originalSize))
        await connection.logOff()

        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        let bytes = try files.reduce(UInt64(0)) {
            $0 + ((try FileManager.default.attributesOfItem(atPath: folder.appending(path: $1).path)[.size] as? UInt64) ?? 0)
        }
        print("Live Steam download: \(item.title), \(files), \(bytes) bytes in \(elapsed)")
        XCTAssertEqual(files, ["preview.gif", "project.json", "scene.pkg"])
        XCTAssertEqual(bytes, item.size)
        let project = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appending(path: "project.json")))
        XCTAssertNotNil(project as? [String: Any])
    }
}
