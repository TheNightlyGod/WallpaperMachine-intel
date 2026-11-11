import XCTest
@testable import WallpaperMachine

@MainActor
final class WorkshopUpdateStoreTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)
    private var asked: [[String]] = []
    private var answer: [WorkshopItem] = []

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("workshop-updates-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defaults = try TemporaryDefaults.make(for: self).defaults
        clock = Date(timeIntervalSince1970: 1_800_000_000)
        asked = []
        answer = []
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private func item(_ id: String, updated: Date?) -> WorkshopItem {
        WorkshopItem(
            id: id, title: "Item \(id)", creator: "Creator", summary: "", previewURL: nil, tags: ["Video"],
            size: 1, subscriptions: 0, timeUpdated: updated)
    }

    private func makeStore() -> WorkshopUpdateStore {
        let recorder = Recorder()
        recorder.answer = answer
        recorder.onAsk = { self.asked.append($0) }
        return WorkshopUpdateStore(
            defaults: defaults, fetch: { ids in await recorder.reply(ids) }, now: { self.clock })
    }

    /// A folder whose project.json was last written at `date`.
    private func installed(_ id: String, writtenAt date: Date) throws {
        let folder = root.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let manifest = folder.appendingPathComponent("project.json")
        try Data("{}".utf8).write(to: manifest)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: manifest.path)
    }

    private func settle(_ store: WorkshopUpdateStore) async throws {
        for _ in 0..<200 where store.isChecking { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(store.isChecking)
    }

    func testOnlyItemsChangedAfterTheirInstallAreOutdated() {
        let installed = clock
        let outdated = WorkshopUpdateStore.outdated(
            remote: [
                item("1", updated: installed.addingTimeInterval(3600)),
                item("2", updated: installed.addingTimeInterval(-3600)),
                item("3", updated: installed.addingTimeInterval(30)),
                item("4", updated: nil),
                item("5", updated: installed.addingTimeInterval(3600)),
            ],
            local: ["1": installed, "2": installed, "3": installed, "4": installed])
        XCTAssertEqual(Set(outdated.keys), ["1"], "within a minute is the same version, and an unknown install is never flagged")
    }

    func testACheckComparesDownloadsAndImportsAndSkipsWhatIsNotFromTheWorkshop() async throws {
        let store = makeStore()
        store.recordInstalled("100")
        try installed("200", writtenAt: clock.addingTimeInterval(-7200))
        answer = [item("100", updated: clock.addingTimeInterval(-60)), item("200", updated: clock.addingTimeInterval(-3600))]
        let checking = makeStore()
        checking.check(installed: ["100", "200", "image-photo.png", "local-movie.mp4"], library: root)
        try await settle(checking)
        XCTAssertEqual(asked, [["100", "200"]])
        XCTAssertEqual(Set(checking.available.keys), ["200"], "the import predates its item's last change")
        XCTAssertEqual(checking.lastChecked, clock)
        XCTAssertNil(checking.errorMessage)
    }

    /// An installed preset carries its base's content, so a change to the base is an update of
    /// the preset too: the check asks Steam about the base as well, and offers the preset.
    func testAChangedBaseIsAnUpdateOfThePresetBuiltOnIt() async throws {
        try installed("300", writtenAt: clock.addingTimeInterval(-7200))
        try Data(#"{"title":"Preset","dependency":"400"}"#.utf8)
            .write(to: root.appendingPathComponent("300/project.json"))
        try FileManager.default.setAttributes(
            [.modificationDate: clock.addingTimeInterval(-7200)],
            ofItemAtPath: root.appendingPathComponent("300/project.json").path)
        answer = [item("300", updated: clock.addingTimeInterval(-9000)), item("400", updated: clock.addingTimeInterval(-3600))]
        let store = makeStore()
        store.check(installed: ["300"], library: root)
        try await settle(store)
        XCTAssertEqual(asked, [["300", "400"]], "the base is asked about with the preset")
        XCTAssertEqual(Set(store.available.keys), ["300"], "the preset is offered; its base is not in the library")
        XCTAssertEqual(store.available["300"]?.title, "Item 300", "with the preset's own details")

        answer = [item("300", updated: clock.addingTimeInterval(-9000)), item("400", updated: clock.addingTimeInterval(-9000))]
        asked = []
        let unchanged = makeStore()
        unchanged.check(installed: ["300"], library: root)
        try await settle(unchanged)
        XCTAssertTrue(unchanged.available.isEmpty, "a base older than the preset's install is no update")
    }

    func testDownloadingAnUpdateMakesItCurrentAndResultsOutliveTheApp() async throws {
        try installed("300", writtenAt: clock.addingTimeInterval(-7200))
        answer = [item("300", updated: clock.addingTimeInterval(-3600))]
        let store = makeStore()
        store.check(installed: ["300"], library: root)
        try await settle(store)
        XCTAssertNotNil(makeStore().available["300"], "found updates survive a relaunch")

        store.recordInstalled("300")
        XCTAssertNil(store.available["300"])
        XCTAssertNil(makeStore().available["300"])
    }

    func testADownloadThatFinishesDuringACheckStaysCurrent() async throws {
        try installed("600", writtenAt: clock.addingTimeInterval(-7200))
        let changed = [item("600", updated: clock.addingTimeInterval(-3600))]
        let gate = Gate()
        let store = WorkshopUpdateStore(
            defaults: defaults, fetch: { _ in
                await gate.wait()
                return changed
            }, now: { self.clock })
        store.check(installed: ["600"], library: root)
        store.recordInstalled("600")
        await gate.open()
        try await settle(store)
        XCTAssertNil(store.available["600"], "the check compared the version the download replaced")
    }

    func testAnImportedItemForgottenDuringACheckDoesNotReappear() async throws {
        try installed("601", writtenAt: clock.addingTimeInterval(-7200))
        try installed("602", writtenAt: clock.addingTimeInterval(-7200))
        let changed = [item("601", updated: clock.addingTimeInterval(-3600)),
                       item("602", updated: clock.addingTimeInterval(-3600))]
        let gate = Gate()
        let store = WorkshopUpdateStore(defaults: defaults, fetch: { _ in
            await gate.wait()
            return changed
        }, now: { self.clock })
        store.check(installed: ["601", "602"], library: root)
        store.forget(["601"])
        await gate.open()
        try await settle(store)
        XCTAssertEqual(Set(store.available.keys), ["602"])
        XCTAssertNil(makeStore().available["601"], "the delayed result must not be persisted again")
    }

    func testAutomaticChecksWaitADayAndCanBeTurnedOff() async throws {
        let store = makeStore()
        store.checkIfDue(installed: ["1"], library: root)
        try await settle(store)
        XCTAssertEqual(asked.count, 1)

        clock.addTimeInterval(WorkshopUpdateStore.checkInterval - 60)
        store.checkIfDue(installed: ["1"], library: root)
        try await settle(store)
        XCTAssertEqual(asked.count, 1, "less than a day later nothing is asked")

        store.checksAutomatically = false
        clock.addTimeInterval(WorkshopUpdateStore.checkInterval)
        store.checkIfDue(installed: ["1"], library: root)
        try await settle(store)
        XCTAssertEqual(asked.count, 1)
        XCTAssertFalse(makeStore().checksAutomatically, "turning it off is remembered")
    }

    func testAFailedCheckSaysWhyAndKeepsWhatWasKnown() async throws {
        try installed("400", writtenAt: clock.addingTimeInterval(-7200))
        answer = [item("400", updated: clock.addingTimeInterval(-3600))]
        let store = makeStore()
        store.check(installed: ["400"], library: root)
        try await settle(store)
        let failing = WorkshopUpdateStore(
            defaults: defaults, fetch: { _ in throw WorkshopFailure(message: "offline") }, now: { self.clock })
        failing.check(installed: ["400"], library: root)
        try await settle(failing)
        XCTAssertNotNil(failing.errorMessage)
        XCTAssertNotNil(failing.available["400"])
    }

    func testWallpapersThatLeaveTheLibraryAreForgotten() async throws {
        try installed("500", writtenAt: clock.addingTimeInterval(-7200))
        answer = [item("500", updated: clock.addingTimeInterval(-3600))]
        let store = makeStore()
        store.check(installed: ["500"], library: root)
        try await settle(store)
        store.forget(["500"])
        XCTAssertNil(store.available["500"])
        XCTAssertNil(makeStore().available["500"])
    }
}

/// Answers the store's details requests in place of Steam.
private final class Recorder: @unchecked Sendable {
    var answer: [WorkshopItem] = []
    var onAsk: (@MainActor ([String]) -> Void)?

    func reply(_ ids: [String]) async -> [WorkshopItem] {
        let onAsk = onAsk
        await MainActor.run { onAsk?(ids) }
        return answer.filter { ids.contains($0.id) }
    }
}

/// Holds a details request until the test lets it answer.
private actor Gate {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func open() {
        isOpen = true
        for continuation in waiting { continuation.resume() }
        waiting = []
    }
}
