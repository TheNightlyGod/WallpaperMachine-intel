import XCTest
@testable import WallpaperMachine

/// The preview window follows a wallpaper's property draft, so every call that changes the draft
/// has to say which wallpaper it changed, and a call that fails changes nothing to follow.
@MainActor
final class PropertyDraftHookTests: XCTestCase {
    private var home: URL!
    private var previousHome: String?

    override func setUpWithError() throws {
        previousHome = ProcessInfo.processInfo.environment["WALLPAPER_MACHINE_HOME"]
        home = FileManager.default.temporaryDirectory.appendingPathComponent("draft-hook-\(UUID().uuidString)")
        setenv("WALLPAPER_MACHINE_HOME", home.path, 1)
        let project = ClientPaths.libraryURL.appendingPathComponent("wp")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data(#"{"type":"web","file":"index.html"}"#.utf8).write(to: project.appendingPathComponent("project.json"))
        try Data("<!doctype html>".utf8).write(to: project.appendingPathComponent("index.html"))
    }

    override func tearDownWithError() throws {
        if let previousHome { setenv("WALLPAPER_MACHINE_HOME", previousHome, 1) } else { unsetenv("WALLPAPER_MACHINE_HOME") }
        try FileManager.default.removeItem(at: home)
    }

    private func makeStore(failing: Bool = false) -> (BridgeStore, DraftBridge) {
        let bridge = DraftBridge(noPointer: .init())
        let store = BridgeStore(bridge: bridge)
        bridge.store = store
        bridge.failing = failing
        return (store, bridge)
    }

    func testEveryCallThatChangesTheDraftNamesItsWallpaper() async throws {
        let (store, _) = makeStore()
        var named: [String] = []
        store.onPropertyDraftChanged = { named.append($0) }
        try await store.editPropertyAsync(wallpaperId: "wp", propertyId: "size", value: .number(value: 3))
        XCTAssertEqual(named, ["wp"], "an edit")
        try await store.setPropertyPathAsync(wallpaperId: "wp", propertyId: "pic", path: "/tmp/a.png")
        XCTAssertEqual(named.count, 2, "a chosen file")
        try await store.restorePropertyDefaultAsync(wallpaperId: "wp", propertyId: "size")
        XCTAssertEqual(named.count, 3, "a restored default")
        try await store.restoreAllPropertyDefaultsAsync(wallpaperId: "wp")
        XCTAssertEqual(named.count, 4, "every default restored")
        try await store.cancelWallpaperOptionsAsync(wallpaperId: "wp")
        XCTAssertEqual(named.count, 5, "a revert")
        try await store.applyWallpaperOptionsAsync(wallpaperId: "wp")
        XCTAssertEqual(named.count, 6, "an apply")
        XCTAssertEqual(Set(named), ["wp"])
    }

    func testTheHookRunsOnceTheChangeIsStored() async throws {
        let (store, _) = makeStore()
        var seen: [Bool] = []
        store.onPropertyDraftChanged = { id in seen.append(store.wallpaperOptionsSnapshot?.wallpaperId == id) }
        try await store.editPropertyAsync(wallpaperId: "wp", propertyId: "size", value: .number(value: 3))
        XCTAssertEqual(seen, [true], "whoever follows the draft reads the stored state")
    }

    func testACallThatFailsAnnouncesNothing() async throws {
        let (store, _) = makeStore(failing: true)
        var named: [String] = []
        store.onPropertyDraftChanged = { named.append($0) }
        do { try await store.editPropertyAsync(wallpaperId: "wp", propertyId: "size", value: .number(value: 3)); XCTFail("expected a failure") } catch {}
        do { try await store.restorePropertyDefaultAsync(wallpaperId: "wp", propertyId: "size"); XCTFail("expected a failure") } catch {}
        do { try await store.cancelWallpaperOptionsAsync(wallpaperId: "wp"); XCTFail("expected a failure") } catch {}
        XCTAssertTrue(named.isEmpty)
    }
}

private final class DraftBridge: WallpaperBridge {
    @MainActor weak var store: BridgeStore?
    @MainActor var failing = false

    override func wallpaperOptionsSnapshot(wallpaperId: String) async throws -> BridgeWallpaperOptionsSnapshot {
        BridgeSnapshotFixtures.options(wallpaperId: wallpaperId, kind: .webpage)
    }
    override func editProperty(wallpaperId: String, propertyId: String, value: BridgePropertyValue) async throws -> BridgeWallpaperMutationBundle {
        try await reply(wallpaperId)
    }
    override func setPropertyPath(wallpaperId: String, propertyId: String, path: String?) async throws -> BridgeWallpaperMutationBundle {
        try await reply(wallpaperId)
    }
    override func restorePropertyDefault(wallpaperId: String, propertyId: String) async throws -> BridgeWallpaperMutationBundle {
        try await reply(wallpaperId)
    }
    override func restoreAllPropertyDefaults(wallpaperId: String) async throws -> BridgeWallpaperMutationBundle {
        try await reply(wallpaperId)
    }
    override func cancelWallpaperOptions(wallpaperId: String) async throws -> BridgeWallpaperMutationBundle {
        try await reply(wallpaperId)
    }
    override func applyWallpaperOptions(wallpaperId: String, userInitiated: Bool) async throws -> BridgeWallpaperMutationBundle {
        try await reply(wallpaperId)
    }

    @MainActor private func reply(_ wallpaperId: String) throws -> BridgeWallpaperMutationBundle {
        if failing { throw NSError(domain: "PropertyDraftHookTests", code: 1) }
        let store = try XCTUnwrap(store)
        return BridgeWallpaperMutationBundle(app: store.appSnapshot, library: store.librarySnapshot,
            wallpaperOptions: BridgeSnapshotFixtures.options(wallpaperId: wallpaperId, kind: .webpage),
            monitorInformation: store.monitorInformationSnapshot, settings: store.settingsSnapshot)
    }
}
