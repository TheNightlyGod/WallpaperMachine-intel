import XCTest
@testable import WallpaperMachine

/// Batch deletion must trash every valid wallpaper even when one entry fails,
/// report the failure per id, and refresh the library exactly once.
@MainActor
final class BatchDeletionTests: XCTestCase {
    private var home: URL!
    private var library: URL { home.appendingPathComponent("Library") }

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        for id in ["a", "b", "c"] {
            try FileManager.default.createDirectory(
                at: library.appendingPathComponent(id), withIntermediateDirectories: true)
        }
        setenv("WALLPAPER_MACHINE_HOME", home.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("WALLPAPER_MACHINE_HOME")
        try FileManager.default.removeItem(at: home)
    }

    func testContinuesPastFailuresAndRefreshesOnce() async throws {
        let bridge = CountingBridge(noPointer: .init())
        let store = BridgeStore(bridge: bridge)
        var recycled: [String] = []
        let report = try await store.deleteWallpapersAsync(ids: ["a", "missing", "b", "c"]) { url in
            if url.lastPathComponent == "b" { throw CocoaError(.fileWriteNoPermission) }
            recycled.append(url.lastPathComponent)
            try FileManager.default.removeItem(at: url)
        }

        XCTAssertEqual(report.deleted, ["a", "c"])
        XCTAssertEqual(report.failures.map(\.id), ["missing", "b"])
        XCTAssertEqual(recycled, ["a", "c"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.appendingPathComponent("b").path))
        XCTAssertEqual(bridge.refreshes, 1)
    }

    func testNothingDeletedSkipsRefresh() async throws {
        let bridge = CountingBridge(noPointer: .init())
        let store = BridgeStore(bridge: bridge)
        let report = try await store.deleteWallpapersAsync(ids: ["missing", "../outside"]) { _ in
            XCTFail("Must not recycle an invalid id")
        }
        XCTAssertTrue(report.deleted.isEmpty)
        XCTAssertEqual(report.failures.count, 2)
        XCTAssertEqual(bridge.refreshes, 0)
    }
}

private final class CountingBridge: WallpaperBridge {
    var refreshes = 0

    override func refreshLibrary() async throws -> BridgeSnapshotBundle {
        refreshes += 1
        return BridgeSnapshotBundle(
            app: BridgeAppSnapshot(playbackState: .paused, selectedWallpaperId: nil, activeWallpaperIds: [], errors: [], heldWallpaperIds: []),
            library: BridgeLibrarySnapshot(
                wallpapers: [], scanStatus: BridgeLibraryScanStatus(scanning: false, done: 0, total: 0),
                sceneCount: 0, videoCount: 0, webpageCount: 0, unknownCount: 0),
            wallpaperOptions: nil,
            monitorInformation: BridgeMonitorInformationSnapshot(rows: []),
            settings: BridgeSnapshotFixtures.settings())
    }
}
