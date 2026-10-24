import Darwin
import XCTest

@testable import WallpaperMachine

/// Where the library is: the app-support folder, a chosen folder with its marker, and a chosen
/// folder that is not there, which must never turn into a new library on this Mac.
final class StorageLocationTests: XCTestCase {
    private var home: URL!
    private var savedEnvironment: [String: String?] = [:]
    private let exportedRoots = [
        "WALLPAPER_MACHINE_HOME", "WALLPAPER_MACHINE_SUPPORT_ROOT", "WALLPAPER_MACHINE_LIBRARY_ROOT",
        "WALLPAPER_MACHINE_ASSETS_ROOT", "WALLPAPER_MACHINE_USER_ASSETS_ROOT",
    ]

    override func setUpWithError() throws {
        savedEnvironment = Dictionary(uniqueKeysWithValues: exportedRoots.map { name in
            (name, getenv(name).map { String(cString: $0) })
        })
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("storage-location-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        setenv("WALLPAPER_MACHINE_HOME", home.path, 1)
        ClientPaths.reloadStorageLocation()
    }

    override func tearDownWithError() throws {
        for (name, value) in savedEnvironment {
            if let value { setenv(name, value, 1) } else { unsetenv(name) }
        }
        ClientPaths.reloadStorageLocation()
        try FileManager.default.removeItem(at: home)
    }

    func testWithoutAChoiceTheLibraryIsInTheAppSupportFolder() {
        XCTAssertEqual(StorageLocation.resolve(support: home), .support)
        XCTAssertEqual(ClientPaths.libraryURL.path, home.appendingPathComponent("Library").path)
        XCTAssertEqual(ClientPaths.workshopDownloadsURL().path, home.appendingPathComponent("Downloads/Workshop").path)
    }

    func testAChosenFolderWithItsMarkerHoldsTheLibraryAndTheDownloads() throws {
        let chosen = try makeChosenFolder()
        let location = StorageLocation(path: chosen.path, id: "drive-id")
        try StorageLocation.writeMarker(location.id, at: chosen)
        try StorageLocation.write(location, support: home)
        ClientPaths.reloadStorageLocation()

        XCTAssertEqual(ClientPaths.storageResolution, .chosen(location.url))
        XCTAssertEqual(ClientPaths.libraryURL.path, chosen.appendingPathComponent("Library").path)
        XCTAssertEqual(ClientPaths.workshopDownloadsURL().path, chosen.appendingPathComponent("Downloads/Workshop").path)
        // What never moves stays in app support.
        XCTAssertEqual(ClientPaths.steamSessionURL().path, home.appendingPathComponent("SteamSession").path)
        XCTAssertEqual(ClientPaths.userAssetsURL.path, home.appendingPathComponent("UserAssets").path)
        try ClientPaths.prepare()
        XCTAssertTrue(FileManager.default.fileExists(atPath: chosen.appendingPathComponent("Library").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("Library").path))
    }

    func testAMissingDriveStopsTheLaunchAndCreatesNothing() throws {
        let missing = home.appendingPathComponent("Unplugged/WallpaperMachine", isDirectory: true)
        let location = StorageLocation(path: missing.path, id: "drive-id")
        try StorageLocation.write(location, support: home)
        ClientPaths.reloadStorageLocation()

        XCTAssertEqual(ClientPaths.storageResolution, .unavailable(location))
        XCTAssertEqual(ClientPaths.libraryURL.path, missing.appendingPathComponent("Library").path,
                       "the library is never quietly the app-support folder instead")
        XCTAssertThrowsError(try ClientPaths.prepare()) { XCTAssertTrue($0 is StorageUnavailableError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("Library").path))
    }

    func testAFolderWithoutThisLibrarysMarkerIsNotTheLibrary() throws {
        let chosen = try makeChosenFolder()
        try StorageLocation.writeMarker("another-library", at: chosen)
        let location = StorageLocation(path: chosen.path, id: "drive-id")
        try StorageLocation.write(location, support: home)
        XCTAssertEqual(StorageLocation.resolve(support: home), .unavailable(location))

        try Data("not json".utf8).write(to: StorageLocation.recordURL(support: home))
        XCTAssertEqual(StorageLocation.resolve(support: home), .unavailable(nil))
        ClientPaths.reloadStorageLocation()
        XCTAssertThrowsError(try ClientPaths.prepare())

        try StorageLocation.write(nil, support: home)
        XCTAssertEqual(StorageLocation.resolve(support: home), .support)
    }

    private func makeChosenFolder() throws -> URL {
        let chosen = home.appendingPathComponent("Drive/WallpaperMachine", isDirectory: true)
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
        return chosen
    }
}
