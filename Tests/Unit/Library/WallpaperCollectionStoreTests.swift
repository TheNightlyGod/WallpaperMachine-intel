import XCTest
@testable import WallpaperMachine

@MainActor
final class WallpaperCollectionStoreTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        defaults = try TemporaryDefaults.make(for: self).defaults
    }

    override func tearDown() {
        defaults = nil
        super.tearDown()
    }

    /// One saved collection is not in a shape this build reads. The other still loads, and
    /// changing it leaves the unreadable one in the saved list.
    func testAnUnreadableCollectionSurvivesAnEditOfAnother() throws {
        defaults.set(
            Data(#"[{"id":"a","name":"Nature","wallpaperIDs":["x"]},{"id":"b","name":"Later","members":{"y":1}}]"#.utf8),
            forKey: WallpaperCollectionStore.storageKey)

        let store = WallpaperCollectionStore(defaults: defaults)
        XCTAssertEqual(store.collections.map(\.id), ["a"])
        try store.rename("a", name: "Forests")

        let saved = try XCTUnwrap(defaults.data(forKey: WallpaperCollectionStore.storageKey))
        let collections = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [[String: Any]])
        XCTAssertEqual(collections.map { $0["name"] as? String }, ["Forests", "Later"])
        XCTAssertEqual((collections.last?["members"] as? [String: Int])?["y"], 1)
    }

    func testBatchMembershipAndStableIdentitySurviveReloadRenameAndDeletion() throws {
        let store = WallpaperCollectionStore(defaults: defaults)
        let first = try store.create(name: " Nature ", wallpaperIDs: ["a", "b", "a"])
        let second = try store.create(name: "Nature", wallpaperIDs: ["b", "d"])
        XCTAssertNotEqual(first.id, second.id, "names are labels, not identity")
        try store.add(["b", "c", "a", "c"], to: first.id)
        try store.remove(["b", "missing"], from: first.id)
        try store.rename(first.id, name: " Landscapes ")
        let reloaded = WallpaperCollectionStore(defaults: defaults)
        XCTAssertEqual(reloaded.collection(id: first.id)?.name, "Landscapes")
        XCTAssertEqual(reloaded.collection(id: first.id)?.wallpaperIDs, ["a", "c"])
        XCTAssertEqual(reloaded.collection(id: second.id)?.wallpaperIDs, ["b", "d"])
        try reloaded.delete(first.id)
        XCTAssertNil(WallpaperCollectionStore(defaults: defaults).collection(id: first.id))
        XCTAssertEqual(WallpaperCollectionStore(defaults: defaults).collections, [second])
        XCTAssertThrowsError(try reloaded.add(["x"], to: first.id))
    }

    func testDeletedWallpapersLeaveEveryCollectionWithoutDeletingCollectionIdentity() throws {
        let store = WallpaperCollectionStore(defaults: defaults)
        let first = try store.create(name: "One", wallpaperIDs: ["a", "b"])
        let second = try store.create(name: "Two", wallpaperIDs: ["b"])
        try store.forget(["b", "unknown"])
        let reloaded = WallpaperCollectionStore(defaults: defaults)
        XCTAssertEqual(reloaded.collection(id: first.id)?.wallpaperIDs, ["a"])
        XCTAssertEqual(reloaded.collection(id: second.id)?.wallpaperIDs, [])
    }

    func testInvalidNamesDoNotPartiallyApplyAndBoundaryNameIsAccepted() throws {
        let store = WallpaperCollectionStore(defaults: defaults)
        let accepted = String(repeating: "界", count: 128)
        let collection = try store.create(name: accepted, wallpaperIDs: ["a"])
        for invalid in [" \n ", String(repeating: "x", count: 129), "a\nb", "a\0b"] {
            XCTAssertThrowsError(try store.rename(collection.id, name: invalid))
            XCTAssertThrowsError(try store.create(name: invalid, wallpaperIDs: ["b"]))
        }
        XCTAssertEqual(WallpaperCollectionStore(defaults: defaults).collections, [collection])
    }
}
