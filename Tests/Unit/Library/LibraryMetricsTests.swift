import XCTest
@testable import WallpaperMachine

/// Installed sorts by folder size and date added, which the renderer's library snapshot
/// does not carry. The service reads them from the library folders off the main thread,
/// answers snapshots from a cache, and re-measures only when the library was reloaded
/// and a folder actually changed.
@MainActor
final class LibraryMetricsTests: XCTestCase {
    private var root: URL!
    private var changes = 0

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("library-metrics-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    @discardableResult
    private func wallpaper(_ id: String, bytes: [Int]) throws -> URL {
        let folder = root.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("nested"), withIntermediateDirectories: true)
        for (index, count) in bytes.enumerated() {
            let file = folder.appendingPathComponent(index.isMultiple(of: 2) ? "file\(index)" : "nested/file\(index)")
            try Data(repeating: 0, count: count).write(to: file)
        }
        // Hidden entries are not part of what the wallpaper weighs.
        try Data(repeating: 0, count: 4096).write(to: folder.appendingPathComponent(".DS_Store"))
        return folder
    }

    private func makeService() -> LibraryMetricsService {
        let service = LibraryMetricsService(libraryURL: root)
        service.onChange = { [weak self] in self?.changes += 1 }
        return service
    }

    /// Waits for the background walk to report, then returns what the next snapshot sees.
    private func reported(_ service: LibraryMetricsService, ids: [String], revision: UInt64 = 0, count: Int)
        async throws -> [String: LibraryMetricsService.Metrics]
    {
        let deadline = Date().addingTimeInterval(5)
        while changes < count && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(changes, count, "The walk reports exactly once per batch that changed something")
        return service.metrics(for: ids, revision: revision)
    }

    func testMeasuresFolderSizeAndDateOffTheSnapshotPathThenReportsOnce() async throws {
        try wallpaper("one", bytes: [10, 20, 30])
        try wallpaper("two", bytes: [5])
        let service = makeService()
        XCTAssertEqual(
            service.metrics(for: ["one", "two", "ghost"], revision: 0), [:],
            "The first snapshot answers immediately with nothing measured")
        let metrics = try await reported(service, ids: ["one", "two", "ghost"], count: 1)
        XCTAssertEqual(metrics["one"]?.size, 60, "Every regular file, at any depth, hidden ones excluded")
        XCTAssertEqual(metrics["two"]?.size, 5)
        XCTAssertNotNil(metrics["one"]?.addedAt)
        XCTAssertNil(metrics["ghost"], "A wallpaper without a folder stays unknown and sorts last")
        try await Task.sleep(for: .milliseconds(150))
        _ = service.metrics(for: ["one", "two", "ghost"], revision: 0)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(changes, 1, "Nothing is re-measured while the library is unchanged")
        let dropped = service.metrics(for: ["two"], revision: 0)
        XCTAssertNil(dropped["one"], "Ids that left the library are forgotten")
        XCTAssertEqual(dropped["two"]?.size, 5)
    }

    /// Wallpaper Engine's staff approval lives in the manifest: `approved: true`, or the
    /// `Approved` tag Steam lists the same wallpapers under. Anything else is not approved.
    func testReadsStaffApprovalFromTheManifest() async throws {
        let flagged = try wallpaper("flagged", bytes: [1])
        let tagged = try wallpaper("tagged", bytes: [1])
        let plain = try wallpaper("plain", bytes: [1])
        try wallpaper("broken", bytes: [1])
        try Data(#"{"title":"A","approved":true,"tags":["Abstract"]}"#.utf8).write(to: flagged.appendingPathComponent("project.json"))
        try Data(#"{"title":"B","tags":["Nature","approved"]}"#.utf8).write(to: tagged.appendingPathComponent("project.json"))
        try Data(#"{"title":"C","approved":false,"tags":["Nature"]}"#.utf8).write(to: plain.appendingPathComponent("project.json"))
        try Data("not json".utf8).write(to: root.appendingPathComponent("broken/project.json"))
        let service = makeService()
        let ids = ["flagged", "tagged", "plain", "broken"]
        _ = service.metrics(for: ids, revision: 0)
        let metrics = try await reported(service, ids: ids, count: 1)
        XCTAssertEqual(metrics["flagged"]?.approved, true, "`approved: true` marks the wallpaper")
        XCTAssertEqual(metrics["tagged"]?.approved, true, "So does Steam's Approved tag, whatever its case")
        XCTAssertEqual(metrics["plain"]?.approved, false)
        XCTAssertEqual(metrics["broken"]?.approved, false, "An unreadable manifest is not approved, and still measures")
        XCTAssertEqual(metrics["broken"]?.size, 9, "…the folder's other files still count")
    }

    /// Installed filters with Discover's boxes, so the manifest is read as Steam's tags:
    /// genre tags, the content rating, approval, audio processing and user properties.
    func testReadsWorkshopStyleTagsFromTheManifest() async throws {
        let full = try wallpaper("full", bytes: [1])
        let plain = try wallpaper("plain", bytes: [1])
        let scheme = try wallpaper("scheme", bytes: [1])
        try wallpaper("none", bytes: [1])
        try Data(#"{"title":"A","approved":true,"contentrating":"Mature","tags":["Anime","approved"," Anime ","Girls",""],"general":{"supportsaudioprocessing":true,"properties":{"schemecolor":{},"speed":{}}}}"#.utf8)
            .write(to: full.appendingPathComponent("project.json"))
        try Data(#"{"title":"B","contentrating":"Everyone","tags":["Nature"],"general":{"supportsaudioprocessing":false}}"#.utf8)
            .write(to: plain.appendingPathComponent("project.json"))
        try Data(#"{"title":"C","general":{"properties":{"schemecolor":{}}}}"#.utf8)
            .write(to: scheme.appendingPathComponent("project.json"))
        let service = makeService()
        let ids = ["full", "plain", "scheme", "none"]
        _ = service.metrics(for: ids, revision: 0)
        let metrics = try await reported(service, ids: ids, count: 1)
        XCTAssertEqual(
            metrics["full"]?.tags, ["Anime", "Girls", "Mature", "Approved", "Audio responsive", "Customizable"],
            "Genre tags once each and trimmed, then rating, approval, audio processing and user properties")
        XCTAssertEqual(metrics["plain"]?.tags, ["Nature", "Everyone"], "Nothing is implied that the manifest does not say")
        XCTAssertEqual(metrics["scheme"]?.tags, [], "The stock scheme colour alone is not a customizable wallpaper")
        XCTAssertEqual(metrics["none"]?.tags, [], "No manifest, no tags; the folder still measures")
        XCTAssertEqual(metrics["none"]?.size, 1)
    }

    /// Installed's search reads the manifest's author and description beside the title and tags,
    /// folded once in the background so typing never folds a description.
    func testReadsTheWordsTheSearchFindsFromTheManifest() async throws {
        let saved = try wallpaper("saved", bytes: [1])
        let workshop = try wallpaper("workshop", bytes: [1])
        try wallpaper("none", bytes: [1])
        let pixiv: [String: Any] = [
            "title": "Dusk", "tags": ["Anime"], "description": "Dusk by Élodie on pixiv",
            "pixiv": ["author": "Élodie", "id": "1"],
        ]
        try JSONSerialization.data(withJSONObject: pixiv).write(to: saved.appendingPathComponent("project.json"))
        let long = String(repeating: "a", count: LibraryMetricsService.searchedDescriptionLength) + " hidden"
        try JSONSerialization.data(withJSONObject: ["title": "Rain", "author": "ＫＹŌＫＯ", "description": long])
            .write(to: workshop.appendingPathComponent("project.json"))
        let service = makeService()
        let ids = ["saved", "workshop", "none"]
        _ = service.metrics(for: ids, revision: 0)
        let metrics = try await reported(service, ids: ids, count: 1)
        func finds(_ id: String, _ query: String) -> Bool {
            LibrarySearchText.contains(metrics[id]?.searchText ?? "", LibrarySearchText.fold(query))
        }
        XCTAssertTrue(finds("saved", "anime"), "the tags come first")
        XCTAssertTrue(finds("saved", "elodie on pixiv"), "the description, its accents folded")
        XCTAssertTrue(finds("workshop", "kyoko"), "an author the manifest names, at any width")
        XCTAssertTrue(finds("workshop", "aaaa"))
        XCTAssertFalse(finds("workshop", "hidden"), "only the start of a very long description is read")
        XCTAssertFalse(finds("workshop", "rain"), "the title is the renderer's, not the manifest's")
        XCTAssertFalse(finds("none", "a"), "no manifest, no words")
        XCTAssertEqual(metrics["none"]?.size, 1, "…and the folder still measures")
    }

    func testReloadRemeasuresOnlyFoldersWhoseContentsMoved() async throws {
        let one = try wallpaper("one", bytes: [10])
        try wallpaper("two", bytes: [20])
        let service = makeService()
        _ = service.metrics(for: ["one", "two"], revision: 0)
        let first = try await reported(service, ids: ["one", "two"], count: 1)
        XCTAssertEqual(first["one"]?.size, 10)
        // A re-download replaces the folder's files; a bare reload leaves the other untouched.
        try await Task.sleep(for: .seconds(1.1))  // Directory modification dates can be whole seconds.
        try Data(repeating: 0, count: 90).write(to: one.appendingPathComponent("extra"))
        _ = service.metrics(for: ["one", "two"], revision: 1)
        let second = try await reported(service, ids: ["one", "two"], revision: 1, count: 2)
        XCTAssertEqual(second["one"]?.size, 100, "The reload picked up the new file")
        XCTAssertEqual(second["two"], first["two"], "An unchanged folder keeps its measurement")
        try await Task.sleep(for: .milliseconds(150))
        _ = service.metrics(for: ["one", "two"], revision: 1)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(changes, 2, "The same revision never re-checks")
    }
}
