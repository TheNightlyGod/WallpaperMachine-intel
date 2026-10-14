import XCTest
@testable import WallpaperMachine

/// Applying the wallpaper a display already shows does nothing. **Reapply wallpaper** is the one
/// way to restart it, for a wallpaper that froze, went blank or shows stale content.
@MainActor
final class WallpaperReapplyTests: XCTestCase {
    private var bridge: DisplayTransferTestBridge!
    private var store: BridgeStore!
    private var prompt: SupportPromptStore!
    private var history: WallpaperHistoryStore!
    private var root: URL!
    private var previousHome: String?
    private var log = ReapplyLog()

    override func setUp() async throws {
        previousHome = ProcessInfo.processInfo.environment["WALLPAPER_MACHINE_HOME"]
        root = FileManager.default.temporaryDirectory.appendingPathComponent("reapply-\(UUID().uuidString)")
        setenv("WALLPAPER_MACHINE_HOME", root.path, 1)
        bridge = DisplayTransferTestBridge(noPointer: .init())
        try bridge.installProjects(in: root.appendingPathComponent("Library"))
        prompt = SupportPromptStore(defaults: try TemporaryDefaults.make(for: self).defaults)
        history = WallpaperHistoryStore()
        store = BridgeStore(bridge: bridge, supportPrompt: prompt, history: history)
        let collected = log
        store.activationLogWriter = { line, isFailure in collected.add(line, isFailure: isFailure) }
        try await store.refreshAllAsync()
    }

    override func tearDown() async throws {
        if let previousHome { setenv("WALLPAPER_MACHINE_HOME", previousHome, 1) } else { unsetenv("WALLPAPER_MACHINE_HOME") }
        try FileManager.default.removeItem(at: root)
    }

    /// The panel runs every apply inside the display's command slot.
    private func reapply(_ id: String, on display: String = "primary") async throws {
        try await store.commands.run(slot: BridgeStore.activationSlot(displayId: display), subject: id) {
            try await self.store.reapplyWallpaperAsync(id: id, displayId: display)
        }
    }

    private var ejected: [String] { bridge.ejections.map { "\($0.0)/\($0.1)" } }

    // MARK: Restarting

    func testReapplyingTheShownWallpaperTakesItOffTheDisplayAndAppliesItAgain() async throws {
        let shownWhileApplying = ReapplyLog()
        bridge.beforeApply = { [bridge] in shownWhileApplying.add(bridge?.assignments["primary"] ?? "nothing", isFailure: false) }

        try await reapply("a")

        XCTAssertEqual(ejected, ["primary/a"], "The display lets go of the wallpaper exactly once")
        XCTAssertEqual(bridge.applications.filter { $0 == ("primary", "a") }.count, 1, "and the wallpaper is applied once")
        XCTAssertEqual(shownWhileApplying.entries.map(\.text), ["nothing"], "The apply starts from an empty display, so the renderer loads it afresh")
        XCTAssertEqual(bridge.assignments["primary"], "a")
        XCTAssertEqual(bridge.assignments["secondary"], "b", "Other displays are left alone")
        XCTAssertFalse(store.commands.isBusy)
    }

    func testARestartIsTheUsersChoiceButNotANewApply() async throws {
        let choices = ReapplyLog()
        store.onUserWallpaperChoice = { id, display in choices.add("\(display)/\(id)", isFailure: false) }
        prompt.recordDownload(wallpaperID: "a")

        try await reapply("a")

        XCTAssertEqual(choices.entries.map(\.text), ["primary/a"], "Restarting is a manual choice, so an automatic rule leaves the display alone")
        XCTAssertTrue(history.entries.isEmpty, "The display shows what it showed, so nothing is added to its history")
        XCTAssertFalse(prompt.isPending, "A wallpaper the display already showed is not applied for the first time")

        // Applying a downloaded wallpaper the display did not show is what the prompt waits for.
        prompt.recordDownload(wallpaperID: "c")
        try await reapply("c")
        XCTAssertTrue(prompt.isPending)
    }

    func testApplyingTheShownWallpaperStillLeavesItRunning() async throws {
        try await store.activateWallpaperAsync(id: "a", displayId: "primary", origin: .user)

        XCTAssertTrue(bridge.ejections.isEmpty)
        XCTAssertTrue(bridge.applications.isEmpty, "Choosing what the display shows touches nothing")
        XCTAssertEqual(bridge.assignments["primary"], "a")
    }

    func testReapplyingAWallpaperTheDisplayDoesNotShowJustAppliesIt() async throws {
        try await reapply("c")

        XCTAssertTrue(bridge.ejections.isEmpty, "Nothing is shown to restart, so nothing is taken off the display")
        XCTAssertEqual(bridge.applications.filter { $0 == ("primary", "c") }.count, 1)
        XCTAssertEqual(bridge.assignments["primary"], "c")
    }

    func testReapplyingOnAnotherDisplayRestartsThatDisplayOnly() async throws {
        try await reapply("b", on: "secondary")

        XCTAssertEqual(ejected, ["secondary/b"])
        XCTAssertEqual(bridge.assignments, ["primary": "a", "secondary": "b"])
    }

    // MARK: Refusals leave the display as it was

    func testAWallpaperThatCanNoLongerLoadKeepsItsDisplay() async throws {
        try FileManager.default.removeItem(at: root.appendingPathComponent("Library/a/index.html"))

        do {
            try await reapply("a")
            XCTFail("a web wallpaper without its page was restarted")
        } catch {}

        XCTAssertTrue(bridge.ejections.isEmpty, "The display must not be emptied for a wallpaper that cannot come back")
        XCTAssertEqual(bridge.assignments["primary"], "a")
        XCTAssertTrue(bridge.applications.isEmpty)
    }

    func testADisabledDisplayIsRefusedBeforeAnythingLeavesIt() async throws {
        bridge.eligible.remove("primary")
        try await store.refreshAllAsync()

        do {
            try await reapply("a")
            XCTFail("a disabled display was restarted")
        } catch {}

        XCTAssertTrue(bridge.ejections.isEmpty)
        XCTAssertEqual(bridge.assignments["primary"], "a")
    }

    func testAnUnfinishedSettingEditIsRefusedBeforeAnythingLeavesTheDisplay() async throws {
        store.editorState.setPropertyText("typed", key: .init(wallpaperID: "a", fieldID: "gone"))

        do {
            try await reapply("a")
            XCTFail("a pending edit that can no longer be applied was ignored")
        } catch {}

        XCTAssertTrue(bridge.ejections.isEmpty, "Applying would fail after the display was emptied")
        XCTAssertEqual(bridge.assignments["primary"], "a")
    }

    // MARK: Log

    func testARestartLeavesAReapplyLineAfterTheActivationItPerformed() async throws {
        try await reapply("a")

        XCTAssertEqual(log.entries.count, 2)
        XCTAssertTrue(log.entries[0].text.hasPrefix("activation: wallpaper a display primary origin user applied in "), log.entries[0].text)
        XCTAssertTrue(log.entries[1].text.hasPrefix("reapply: wallpaper a display primary origin user applied in "), log.entries[1].text)
        XCTAssertTrue(log.entries.allSatisfy { !$0.isFailure })
    }

    func testAnOrdinaryApplyThroughReapplyIsNotLoggedAsARestart() async throws {
        try await reapply("c")

        XCTAssertEqual(log.entries.map { $0.text.prefix(while: { $0 != ":" }) }, ["activation"])
    }

    func testARefusedRestartIsLoggedAsAFailure() async throws {
        try FileManager.default.removeItem(at: root.appendingPathComponent("Library/a/index.html"))

        do { try await reapply("a") } catch {}

        let entry = try XCTUnwrap(log.entries.last)
        XCTAssertTrue(entry.isFailure)
        XCTAssertTrue(entry.text.hasPrefix("reapply: wallpaper a display primary origin user failed (error) in "), entry.text)
    }
}

/// The inspector's play button, driven through the real panel: its Reapply restarts the
/// wallpaper, and everything else that chooses the shown wallpaper again leaves it running.
@MainActor
final class WallpaperReapplyPanelTests: ControlPanelTestCase {
    private func withTransferPanel(
        _ body: (PanelFixture, DisplayTransferTestBridge, ReapplyLog) async throws -> Void
    ) async throws {
        let bridge = DisplayTransferTestBridge(noPointer: .init())
        let store = BridgeStore(bridge: bridge)
        let log = ReapplyLog()
        store.activationLogWriter = { line, isFailure in log.add(line, isFailure: isFailure) }
        let panel = try PanelFixture(store: store, bridge: bridge, displayTitles: .renderer)
        do {
            try bridge.installProjects(in: panel.library)
            try await store.refreshAllAsync()
            try await panel.start()
            try await panel.finishWelcome()
            panel.navigation.selection = .wallpaper
            panel.show()
            try await body(panel, bridge, log)
        } catch { await panel.shutdown(); throw error }
        await panel.shutdown()
    }

    func testOnlyTheInspectorsReapplyRestartsTheShownWallpaper() async throws {
        try await withTransferPanel { panel, bridge, log in
            try await panel.waitJS("document.querySelector('#inspector [data-action=\"reapplyWallpaper\"][data-id=\"a\"]')")
            // Wallpaper "a" is shown on the target display, so the button restarts it.
            try await panel.expectJS("return document.querySelector('#inspector [data-action=\"activate\"]') === null", equals: true)

            _ = try await panel.js("document.querySelector('#inspector [data-action=\"reapplyWallpaper\"]').click()")
            try await panel.waitUntil(timeout: 5) { bridge.applications.contains { $0 == ("primary", "a") } }
            XCTAssertEqual(bridge.ejections.map { "\($0.0)/\($0.1)" }, ["primary/a"])
            XCTAssertEqual(bridge.assignments["primary"], "a")

            // A wallpaper the display does not show is applied, not restarted.
            _ = try await panel.js("document.querySelector('#wallpaper-grid [data-action=\"select\"][data-id=\"c\"]').click()")
            try await panel.waitJS("document.querySelector('#inspector [data-action=\"activate\"][data-id=\"c\"]')")
            _ = try await panel.js("document.querySelector('#inspector [data-action=\"activate\"]').click()")
            try await panel.waitUntil(timeout: 5) { bridge.assignments["primary"] == "c" }
            XCTAssertEqual(bridge.ejections.count, 1)

            // A double-click on the tile of the shown wallpaper keeps it running.
            log.entries.removeAll()
            _ = try await panel.js("""
              document.querySelector('#wallpaper-grid [data-action="select"][data-id="c"]')
                .dispatchEvent(new MouseEvent('click', { bubbles: true, detail: 2 }));
              """)
            try await panel.waitUntil(timeout: 5) { log.entries.contains { $0.text.contains("wallpaper c display primary origin user noOp") } }
            XCTAssertEqual(bridge.ejections.count, 1, "Only Reapply restarts a wallpaper")
            XCTAssertEqual(bridge.applications.filter { $0 == ("primary", "c") }.count, 1)
        }
    }
}

final class ReapplyLog {
    struct Entry {
        let text: String
        let isFailure: Bool
    }

    var entries: [Entry] = []

    func add(_ text: String, isFailure: Bool) { entries.append(Entry(text: text, isFailure: isFailure)) }
}
