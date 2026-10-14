import Darwin
import XCTest

@testable import WallpaperMachine

extension URL {
    /// Whether Time Machine skips this item, read through a fresh value so no cached answer is returned.
    var isKeptOutOfBackups: Bool {
        (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isExcludedFromBackupKey]))?.isExcludedFromBackup == true
    }
}

/// The Steam sign-in, partial downloads and caches stay out of Time Machine; the library does not.
final class ClientPathsBackupTests: XCTestCase {
    private var home: URL!
    private var savedEnvironment: [String: String?] = [:]
    private let exportedRoots = [
        "WALLPAPER_MACHINE_HOME", "WALLPAPER_MACHINE_SUPPORT_ROOT", "WALLPAPER_MACHINE_LIBRARY_ROOT",
        "WALLPAPER_MACHINE_ASSETS_ROOT", "WALLPAPER_MACHINE_USER_ASSETS_ROOT",
    ]

    override func setUpWithError() throws {
        // Unit tests run inside the real app: `prepare()` exports roots the renderer reads, so put
        // every one of them back exactly as found.
        savedEnvironment = Dictionary(uniqueKeysWithValues: exportedRoots.map { name in
            (name, getenv(name).map { String(cString: $0) })
        })
        home = FileManager.default.temporaryDirectory.appendingPathComponent("client-paths-backup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        setenv("WALLPAPER_MACHINE_HOME", home.path, 1)
    }

    override func tearDownWithError() throws {
        for (name, value) in savedEnvironment {
            if let value { setenv(name, value, 1) } else { unsetenv(name) }
        }
        try FileManager.default.removeItem(at: home)
    }

    func testExcludingAFolderFlagsItAndRepeatingIsHarmless() throws {
        let folder = home.appendingPathComponent("SteamSession", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertFalse(folder.isKeptOutOfBackups, "a new folder is backed up until it is flagged")
        XCTAssertTrue(ClientPaths.excludeFromBackup(folder))
        XCTAssertTrue(folder.isKeptOutOfBackups)
        XCTAssertTrue(ClientPaths.excludeFromBackup(folder))
        XCTAssertTrue(folder.isKeptOutOfBackups)
    }

    func testAFolderThatIsNotThereReportsFailureInsteadOfThrowing() {
        let missing = home.appendingPathComponent("nothing-here", isDirectory: true)
        XCTAssertFalse(ClientPaths.excludeFromBackup(missing))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path), "flagging never creates the folder")
    }

    func testLaunchFlagsTheCacheAndLeavesTheLibraryBackedUp() throws {
        try ClientPaths.prepare()
        XCTAssertTrue(ClientPaths.cacheURL.isKeptOutOfBackups)
        XCTAssertTrue(FileManager.default.fileExists(atPath: ClientPaths.libraryURL.path))
        XCTAssertFalse(ClientPaths.libraryURL.isKeptOutOfBackups)
        XCTAssertFalse(ClientPaths.supportURL.isKeptOutOfBackups, "only the disposable folders are excluded, never the whole support folder")
        XCTAssertFalse(ClientPaths.userAssetsURL.isKeptOutOfBackups)
        XCTAssertFalse(ClientPaths.managedAssetsURL.isKeptOutOfBackups)
    }

    /// An update must not wait for the next download or sign-in before the folders an earlier
    /// version left behind stop being backed up.
    func testLaunchFlagsTheSignInAndPartialDownloadsAnEarlierVersionLeftUnflagged() throws {
        let session = ClientPaths.steamSessionURL()
        let downloads = ClientPaths.workshopDownloadsURL()
        let requests = ClientPaths.supportURL.appendingPathComponent("Downloads/workshop-requests.json")
        try FileManager.default.createDirectory(
            at: downloads.appendingPathComponent("3632513108", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        try Data("token".utf8).write(to: session.appendingPathComponent("account"))
        try Data("[]".utf8).write(to: downloads.appendingPathComponent("queue.json"))
        try Data("[]".utf8).write(to: requests)
        XCTAssertFalse(session.isKeptOutOfBackups)
        XCTAssertFalse(downloads.isKeptOutOfBackups)

        try ClientPaths.prepare()

        XCTAssertTrue(session.isKeptOutOfBackups)
        XCTAssertTrue(downloads.isKeptOutOfBackups)
        XCTAssertFalse(downloads.deletingLastPathComponent().isKeptOutOfBackups, "the request list beside the downloads stays backed up")
        XCTAssertEqual(try Data(contentsOf: session.appendingPathComponent("account")), Data("token".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: downloads.appendingPathComponent("queue.json").path))
    }

    func testLaunchDoesNotCreateTheSignInOrDownloadFoldersOnlyToFlagThem() throws {
        try ClientPaths.prepare()
        XCTAssertFalse(FileManager.default.fileExists(atPath: ClientPaths.steamSessionURL().path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ClientPaths.workshopDownloadsURL().path))
    }

    func testAFlaggedCacheStaysFlaggedAfterTheNextLaunch() throws {
        try ClientPaths.prepare()
        let thumbnails = ClientPaths.thumbnailCacheURL
        try FileManager.default.createDirectory(at: thumbnails, withIntermediateDirectories: true)
        try Data("cached".utf8).write(to: thumbnails.appendingPathComponent("a.jpg"))
        try ClientPaths.prepare()
        XCTAssertTrue(ClientPaths.cacheURL.isKeptOutOfBackups)
        XCTAssertEqual(try Data(contentsOf: thumbnails.appendingPathComponent("a.jpg")), Data("cached".utf8))
    }
}
