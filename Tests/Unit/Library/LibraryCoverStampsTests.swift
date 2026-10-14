import XCTest

@testable import WallpaperMachine

/// The Installed tiles' cover addresses carry a stamp of the preview file. It is read off the main
/// thread, answered from a cache on the snapshot path, and announced only when a preview is new or
/// changed, so a rescan that replaced nothing leaves every tile's image alone.
@MainActor
final class LibraryCoverStampsTests: XCTestCase {
    private var root: URL!
    private var changes = 0
    private let moment = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("library-cover-stamps-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    @discardableResult
    private func preview(_ id: String, bytes: Int = 16, at date: Date? = nil) throws -> URL {
        let file = root.appendingPathComponent("\(id)/preview.png")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: date ?? moment], ofItemAtPath: file.path)
        return file
    }

    private func makeService() -> LibraryCoverStamps {
        let service = LibraryCoverStamps()
        service.onChange = { [weak self] in self?.changes += 1 }
        return service
    }

    func testStampsAreReadAfterTheSnapshotAnsweredAndAnnouncedOnce() async throws {
        let files = ["a": try preview("a"), "b": try preview("b", bytes: 32)]
        let service = makeService()

        XCTAssertEqual(service.stamps(for: files, revision: 0), [:], "The snapshot path answers at once with nothing read")
        XCTAssertEqual(changes, 0)
        await service.settled()

        XCTAssertEqual(changes, 1, "One announcement for the pass, not one per file")
        let stamps = service.stamps(for: files, revision: 0)
        XCTAssertEqual(stamps["a"], LibraryPreviewFetcher.coverStamp(of: files["a"]!))
        XCTAssertEqual(stamps["b"], LibraryPreviewFetcher.coverStamp(of: files["b"]!))
        XCTAssertNotEqual(stamps["a"], stamps["b"])
        await service.settled()
        XCTAssertEqual(changes, 1, "Asking again for what is known reads nothing and announces nothing")
    }

    func testARescanThatReplacedNothingReadsAgainAndAnnouncesNothing() async throws {
        let files = ["a": try preview("a"), "b": try preview("b")]
        let service = makeService()
        _ = service.stamps(for: files, revision: 0)
        await service.settled()
        let stamps = service.stamps(for: files, revision: 0)
        let revision = service.contentRevision

        for rescan: UInt64 in 1...3 {
            XCTAssertEqual(service.stamps(for: files, revision: rescan), stamps, "The known stamps stand while it reads")
            await service.settled()
        }

        XCTAssertEqual(service.stamps, stamps)
        XCTAssertEqual(service.contentRevision, revision)
        XCTAssertEqual(changes, 1)
    }

    func testAReplacedPreviewKeepsItsOldStampUntilTheNewOneIsReadThenIsAnnounced() async throws {
        let files = ["a": try preview("a"), "b": try preview("b")]
        let service = makeService()
        _ = service.stamps(for: files, revision: 0)
        await service.settled()
        let before = service.stamps(for: files, revision: 0)

        // A different size, then the same size at a later time: each is a different preview.
        var rescan: UInt64 = 0
        for (bytes, date) in [(99, moment), (99, moment.addingTimeInterval(60))] {
            let previous = service.stamps["a"]
            let announced = service.contentRevision
            try preview("a", bytes: bytes, at: date)
            rescan += 1
            XCTAssertEqual(service.stamps(for: files, revision: rescan)["a"], previous, "The old stamp stands until the new one is read")
            await service.settled()
            XCTAssertNotEqual(service.stamps["a"], previous)
            XCTAssertEqual(service.contentRevision, announced + 1)
        }
        XCTAssertEqual(service.stamps["b"], before["b"], "A preview nobody touched keeps its stamp")
        XCTAssertEqual(changes, 3)
    }

    func testAWallpaperThatLeftOrWhosePreviewMovedHasNothingKnownUntilItIsRead() async throws {
        let files = ["a": try preview("a"), "b": try preview("b")]
        let service = makeService()
        _ = service.stamps(for: files, revision: 0)
        await service.settled()

        let moved = try preview("moved", bytes: 40)
        XCTAssertEqual(service.stamps(for: ["a": moved], revision: 0), [:], "b left, and a's preview is another file now")
        await service.settled()
        XCTAssertEqual(service.stamps(for: ["a": moved], revision: 0), ["a": LibraryPreviewFetcher.coverStamp(of: moved)!])
    }

    func testAPreviewThatCannotBeReadIsStampedZeroSoItsTileIsNotLeftWaiting() async throws {
        let service = makeService()
        let gone = root.appendingPathComponent("gone/preview.png")
        _ = service.stamps(for: ["gone": gone], revision: 0)
        await service.settled()
        XCTAssertEqual(service.stamps(for: ["gone": gone], revision: 0), ["gone": 0])
    }

    func testAnAskMadeWhileAPassIsReadingIsNotLost() async throws {
        let first = try preview("a")
        let second = try preview("b")
        let service = makeService()
        _ = service.stamps(for: ["a": first], revision: 0)
        _ = service.stamps(for: ["a": first, "b": second], revision: 0)
        await service.settled()
        XCTAssertEqual(Set(service.stamps.keys), ["a", "b"])
        XCTAssertEqual(service.stamps(for: ["a": first, "b": second], revision: 0).count, 2)
    }
}
