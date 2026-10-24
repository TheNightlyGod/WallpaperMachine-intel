import XCTest
@testable import WallpaperMachine

@MainActor
final class WallpaperAutomationSchedulerTests: XCTestCase {
    private var defaults: UserDefaults!
    private var rules: WallpaperAutomationStore!
    private var focus: FocusFilterState!
    private var states: [String: WallpaperAutomationDisplayState] = [:]
    private var changes: [(String, WallpaperAutomationTarget)] = []
    private var restores = 0
    private var running = true
    private var dark = false
    private var targetDisplay = "primary"
    private var clock = Date()
    private let queue = UserCommandQueue()
    private var failures = Set<String>()
    private var spaceVisits: [String: WallpaperSpaceVisit] = [:]
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!; return calendar
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        defaults = try TemporaryDefaults.make(for: self).defaults
        rules = WallpaperAutomationStore(defaults: defaults)
        focus = FocusFilterState(defaults: defaults)
        var playlist = DisplayPlaylist()
        playlist.mode = .rotate; playlist.source = .list; playlist.wallpaperIDs = ["original", "other"]
        states = ["primary": .init(playlist: playlist, wallpaperID: "original"), "secondary": .init(playlist: .init(), wallpaperID: "second")]
        changes = []; restores = 0; running = true; dark = false; failures = []; targetDisplay = "primary"
        spaceVisits = [:]
        clock = calendar.date(from: DateComponents(year: 2026, month: 10, day: 8, hour: 10))!
    }
    private func settle() async { for _ in 0..<70 { await Task.yield() } }
    private func target(_ id: String, _ kind: WallpaperAutomationTarget.Kind = .wallpaper) -> WallpaperAutomationTarget { .init(kind: kind, id: id) }
    private func scheduler() -> WallpaperAutomationScheduler {
        WallpaperAutomationScheduler(store: rules, focus: focus, displays: { Array(self.states.keys) }, targetDisplay: { self.targetDisplay },
            canRun: { _ in self.running }, capture: { self.states[$0]! }, queue: { display, action in
                try await self.queue.run(slot: BridgeStore.activationSlot(displayId: display), origin: .automation, action)
            }, apply: { target, display in
                self.changes.append((display, target))
                if self.failures.contains(target.id) { throw AutomationError(message: "Fixture unavailable") }
                if target.kind == .wallpaper {
                    self.states[display]?.wallpaperID = target.id
                    self.states[display]?.playlist.mode = .off
                    self.states[display]?.playlist.planID = nil
                } else {
                    self.states[display]?.playlist.mode = .rotate
                    self.states[display]?.playlist.planID = target.id
                }
            }, restore: { original, display, preserve in
                self.restores += 1
                self.states[display]?.playlist = original.playlist
                if !preserve { self.states[display]?.wallpaperID = original.wallpaperID }
            }, dark: { self.dark }, now: { self.clock }, calendar: calendar,
            appearanceCenter: NotificationCenter(), sleep: { _ in try await Task.sleep(for: .seconds(3600)) },
            spaceVisit: { self.spaceVisits[$0] })
    }

    func testTimeRulesCatchUpOnceWaitWhenPausedAndRespectManualChoice() async throws {
        try rules.update("primary") {
            $0.mode = .schedule
            $0.rules = [.init(minute: 8 * 60, target: target("morning")), .init(minute: 12 * 60, target: target("noon")), .init(minute: 14 * 60, target: target("afternoon"))]
        }
        let scheduler = scheduler(); scheduler.start(); defer { scheduler.stop() }
        await settle()
        XCTAssertEqual(states["primary"]?.wallpaperID, "morning")
        states["primary"]?.wallpaperID = "manual"
        scheduler.noteManualChoice("primary")
        scheduler.evaluate(); await settle()
        XCTAssertEqual(states["primary"]?.wallpaperID, "manual")
        running = false; clock.addTimeInterval(5 * 3600)
        scheduler.evaluate(); await settle()
        XCTAssertEqual(changes.map { $0.1.id }, ["morning"])
        running = true; scheduler.evaluate(); await settle()
        XCTAssertEqual(changes.map { $0.1.id }, ["morning", "afternoon"])
        scheduler.evaluate(); await settle()
        XCTAssertEqual(changes.count, 2)
    }

    func testSpaceChoicesRespectManualSelectionUntilAnotherDesktopVisit() async throws {
        try rules.update("primary") { $0.mode = .spaces; $0.spaces = ["a": target("ocean"), "b": target("forest")] }
        spaceVisits["primary"] = .init(spaceID: "a", token: "visit1")
        let scheduler = scheduler(); scheduler.start(); defer { scheduler.stop() }; await settle()
        XCTAssertEqual(states["primary"]?.wallpaperID, "ocean")
        states["primary"]?.wallpaperID = "manual"; scheduler.noteManualChoice("primary")
        scheduler.evaluate(); await settle(); XCTAssertEqual(states["primary"]?.wallpaperID, "manual")
        spaceVisits["primary"] = .init(spaceID: "unmapped", token: "visit2")
        scheduler.evaluate(); await settle(); XCTAssertEqual(states["primary"]?.wallpaperID, "manual")
        spaceVisits["primary"] = .init(spaceID: "a", token: "visit3")
        scheduler.evaluate(); await settle(); XCTAssertEqual(states["primary"]?.wallpaperID, "ocean")
        spaceVisits["primary"] = .init(spaceID: "b", token: "visit4")
        scheduler.evaluate(); await settle(); XCTAssertEqual(states["primary"]?.wallpaperID, "forest")
    }

    func testADesktopWithoutAChoiceShowsDesktop1sAsANewDesktopDoes() async throws {
        try rules.update("primary") { $0.mode = .spaces; $0.spaces = ["a": target("ocean"), "b": target("forest")] }
        spaceVisits["primary"] = .init(spaceID: "b", token: "visit1", firstSpaceID: "a")
        let scheduler = scheduler(); scheduler.start(); defer { scheduler.stop() }; await settle()
        XCTAssertEqual(states["primary"]?.wallpaperID, "forest")

        spaceVisits["primary"] = .init(spaceID: "new", token: "visit2", firstSpaceID: "a")
        XCTAssertEqual(scheduler.pendingTarget(on: "primary"), target("ocean"), "the new desktop waits for Desktop 1's")
        scheduler.evaluate(); await settle()
        XCTAssertEqual(states["primary"]?.wallpaperID, "ocean")
        XCTAssertNil(rules.configuration(for: "primary").spaces["new"], "following Desktop 1 saves nothing for the desktop")

        try rules.update("primary") { $0.spaces["a"] = nil }
        spaceVisits["primary"] = .init(spaceID: "b", token: "visit3", firstSpaceID: "a"); scheduler.evaluate(); await settle()
        spaceVisits["primary"] = .init(spaceID: "new", token: "visit4", firstSpaceID: "a"); scheduler.evaluate(); await settle()
        XCTAssertEqual(states["primary"]?.wallpaperID, "forest", "with no choice on Desktop 1 either, the display keeps what it shows")
    }

    func testADesktopFollowingDesktop1FollowsTheNewDesktop1WhenTheDesktopsAreReordered() async throws {
        try rules.update("primary") { $0.mode = .spaces; $0.spaces = ["a": target("ocean"), "b": target("forest")] }
        spaceVisits["primary"] = .init(spaceID: "new", token: "visit1", firstSpaceID: "a")
        let scheduler = scheduler(); scheduler.start(); defer { scheduler.stop() }; await settle()
        XCTAssertEqual(states["primary"]?.wallpaperID, "ocean")

        // Desktop b is moved to the front while the person stays on the same desktop.
        spaceVisits["primary"] = .init(spaceID: "new", token: "visit1", firstSpaceID: "b")
        scheduler.evaluate(); await settle()
        XCTAssertEqual(states["primary"]?.wallpaperID, "forest", "the desktop shows the new Desktop 1's wallpaper")
    }

    func testAWallpaperChosenByHandBecomesTheCurrentDesktopsOwn() async throws {
        try rules.update("primary") { $0.mode = .spaces; $0.spaces = ["a": target("ocean"), "b": target("forest")] }
        spaceVisits["primary"] = .init(spaceID: "a", token: "visit1")
        let scheduler = scheduler(); scheduler.start(); defer { scheduler.stop() }; await settle()
        XCTAssertEqual(states["primary"]?.wallpaperID, "ocean")

        states["primary"]?.wallpaperID = "manual"
        scheduler.noteManualChoice("primary", wallpaperID: "manual")
        await settle()
        XCTAssertEqual(rules.configuration(for: "primary").spaces["a"], target("manual"))
        XCTAssertEqual(changes.map { $0.1.id }, ["ocean"], "what was chosen is on screen already")

        spaceVisits["primary"] = .init(spaceID: "b", token: "visit2")
        scheduler.evaluate(); await settle()
        XCTAssertEqual(states["primary"]?.wallpaperID, "forest")
        spaceVisits["primary"] = .init(spaceID: "a", token: "visit3")
        scheduler.evaluate(); await settle()
        XCTAssertEqual(states["primary"]?.wallpaperID, "manual", "coming back keeps the desktop's own wallpaper")

        spaceVisits["primary"] = .init(spaceID: "new", token: "visit4")
        scheduler.evaluate(); await settle()
        states["primary"]?.wallpaperID = "picked"
        scheduler.noteManualChoice("primary", wallpaperID: "picked")
        XCTAssertEqual(rules.configuration(for: "primary").spaces["new"], target("picked"),
                       "a desktop without a choice gets one")
    }

    func testAManualChoiceOutsideTheSpaceModeChangesNoDesktop() async throws {
        try rules.update("primary") { $0.mode = .schedule; $0.spaces = [:] }
        spaceVisits["primary"] = .init(spaceID: "a", token: "visit1")
        let scheduler = scheduler(); scheduler.start(); defer { scheduler.stop() }; await settle()

        scheduler.noteManualChoice("primary", wallpaperID: "manual")

        XCTAssertTrue(rules.configuration(for: "primary").spaces.isEmpty)
    }

    func testSpaceChoiceWaitsWhilePausedAndBlocksPosterPublicationUntilSettled() async throws {
        try rules.update("primary") { $0.mode = .spaces; $0.spaces["a"] = target("ocean") }
        spaceVisits["primary"] = .init(spaceID: "a", token: "visit1"); running = false
        let scheduler = scheduler(); scheduler.start(); defer { scheduler.stop() }; await settle()
        XCTAssertTrue(changes.isEmpty)
        XCTAssertFalse(scheduler.selectionIsSettled(on: "primary"))
        XCTAssertEqual(scheduler.pendingTarget(on: "primary"), target("ocean"), "the desktop's choice waits")
        XCTAssertFalse(scheduler.isApplying(on: "primary"), "it is not running while paused")
        running = true; scheduler.evaluate(); await settle()
        XCTAssertEqual(states["primary"]?.wallpaperID, "ocean")
        XCTAssertTrue(scheduler.selectionIsSettled(on: "primary"))
        XCTAssertNil(scheduler.pendingTarget(on: "primary"))
    }

    func testFocusEndsOnlyAfterSpaceInformationRecoversAndUsesTheNewDesktopChoice() async throws {
        try rules.update("primary") { $0.mode = .spaces; $0.spaces = ["a": target("ocean"), "b": target("forest")] }
        spaceVisits["primary"] = .init(spaceID: "a", token: "visit1")
        let scheduler = scheduler(); scheduler.start(); defer { scheduler.stop() }; await settle()
        focus.set(nil, selection: .init(target: target("focus"), displayID: "primary")); await settle()
        spaceVisits["primary"] = nil; focus.set(nil); await settle()
        XCTAssertEqual(states["primary"]?.wallpaperID, "focus")
        XCTAssertNotNil(rules.focusRestore["primary"])
        spaceVisits["primary"] = .init(spaceID: "b", token: "visit2")
        scheduler.evaluate(); await settle()
        XCTAssertEqual(states["primary"]?.wallpaperID, "forest")
        XCTAssertNil(rules.focusRestore["primary"])
    }

    func testAppearanceChangesOnceAndAStoredHandledEventSurvivesRestart() async throws {
        try rules.update("primary") { $0.mode = .appearance; $0.light = target("light"); $0.dark = target("dark") }
        var scheduler = scheduler(); scheduler.start(); await settle(); scheduler.stop()
        states["primary"]?.wallpaperID = "manual"
        rules = WallpaperAutomationStore(defaults: defaults)
        scheduler = self.scheduler(); scheduler.start(); defer { scheduler.stop() }
        await settle()
        XCTAssertEqual(states["primary"]?.wallpaperID, "manual")
        dark = true; scheduler.evaluate(); await settle()
        XCTAssertEqual(states["primary"]?.wallpaperID, "dark")
        XCTAssertEqual(changes.map { $0.1.id }, ["light", "dark"])
    }

    func testFocusOverridesThenRestoresWallpaperAndPlaylist() async throws {
        let original = states["primary"]
        focus.set(nil, selection: .init(target: target("focus"), displayID: "primary"))
        let scheduler = scheduler(); scheduler.start(); defer { scheduler.stop() }
        await settle()
        XCTAssertEqual(states["primary"]?.wallpaperID, "focus")
        XCTAssertNotNil(WallpaperAutomationStore(defaults: defaults).focusRestore["primary"])
        focus.set(nil); await settle()
        XCTAssertEqual(states["primary"], original)
        XCTAssertTrue(rules.focusRestore.isEmpty)
        XCTAssertEqual(restores, 1)
    }

    func testManualWallpaperDuringFocusSurvivesExitButTheOldPlaylistReturns() async throws {
        let original = states["primary"]!.playlist
        focus.set(nil, selection: .init(target: target("focus"), displayID: "primary"))
        let scheduler = scheduler(); scheduler.start(); defer { scheduler.stop() }; await settle()
        states["primary"]?.wallpaperID = "manual"
        scheduler.noteManualChoice("primary")
        focus.set(nil); await settle()
        XCTAssertEqual(states["primary"]?.wallpaperID, "manual")
        XCTAssertEqual(states["primary"]?.playlist, original)
    }

    func testEditingThePlaylistDuringFocusWinsOverRestoration() async throws {
        focus.set(nil, selection: .init(target: target("focus-plan", .playlist), displayID: "primary"))
        let scheduler = scheduler(); scheduler.start(); defer { scheduler.stop() }; await settle()
        states["primary"]?.playlist.interval = 120
        let edited = states["primary"]
        focus.set(nil); await settle()
        XCTAssertEqual(states["primary"], edited)
        XCTAssertEqual(restores, 0)
        XCTAssertTrue(rules.focusRestore.isEmpty)
    }

    func testDeletingTheFocusSavedPlanKeepsItsCopiedPlaylistAndStillRestores() async throws {
        let original = states["primary"]
        focus.set(nil, selection: .init(target: target("temporary", .playlist), displayID: "primary"))
        let scheduler = scheduler(); scheduler.start(); defer { scheduler.stop() }; await settle()
        states["primary"]?.playlist.planID = nil
        try rules.forgetPlan("temporary")
        focus.set(nil); await settle()
        XCTAssertEqual(states["primary"], original)
        XCTAssertEqual(restores, 1)
    }

    func testChangingFocusKeepsTheOriginalBaselineAndPinsAnImplicitDisplay() async throws {
        let original = states["primary"]
        focus.set(nil, selection: .init(target: target("first"), displayID: nil))
        let scheduler = scheduler(); scheduler.start(); defer { scheduler.stop() }; await settle()
        targetDisplay = "secondary"
        scheduler.evaluate(); await settle()
        XCTAssertEqual(states["secondary"]?.wallpaperID, "second")
        focus.set(nil, selection: .init(target: target("next"), displayID: "primary")); await settle()
        XCTAssertEqual(states["primary"]?.wallpaperID, "next")
        focus.set(nil); await settle()
        XCTAssertEqual(states["primary"], original)
    }

    func testFocusExitUsesTheLatestScheduleInsteadOfReplayingMissedChanges() async throws {
        try rules.update("primary") { $0.mode = .schedule; $0.rules = [.init(minute: 480, target: target("morning")), .init(minute: 720, target: target("noon"))] }
        let scheduler = scheduler(); scheduler.start(); defer { scheduler.stop() }; await settle()
        focus.set(nil, selection: .init(target: target("focus"), displayID: "primary")); await settle()
        clock.addTimeInterval(3 * 3600); scheduler.evaluate(); await settle()
        XCTAssertEqual(states["primary"]?.wallpaperID, "focus")
        focus.set(nil); await settle()
        XCTAssertEqual(changes.map { $0.1.id }, ["morning", "focus", "noon"])
        XCTAssertEqual(restores, 0)
    }

    func testInterruptedFocusPublicationCanRestoreAfterRelaunch() async throws {
        let original = states["primary"]!
        try rules.rememberFocus(.init(key: "focus:interrupted", before: original, expectedPlaylist: original.playlist, pending: true), on: "primary")
        states["primary"]?.playlist.mode = .off
        states["primary"]?.wallpaperID = "partial"
        rules = WallpaperAutomationStore(defaults: defaults)
        let scheduler = scheduler(); scheduler.start(); defer { scheduler.stop() }; await settle()
        XCTAssertEqual(states["primary"], original)
        XCTAssertTrue(rules.focusRestore.isEmpty)
    }

    func testFailureIsReportedOnceAndExplicitRetryCanRecover() async throws {
        try rules.update("primary") { $0.mode = .appearance; $0.light = target("missing") }
        failures = ["missing"]
        let scheduler = scheduler(); scheduler.start(); defer { scheduler.stop() }; await settle()
        scheduler.evaluate(); await settle()
        XCTAssertEqual(changes.count, 1)
        XCTAssertNotNil(rules.errors["primary"])
        failures = []; rules.retry("primary"); await settle()
        XCTAssertEqual(states["primary"]?.wallpaperID, "missing")
        XCTAssertNil(rules.errors["primary"])
    }

    func testAQueuedRuleCannotReplaceANewerManualCommand() async throws {
        var release: CheckedContinuation<Void, Never>?
        let blocker = Task { await queue.run { await withCheckedContinuation { release = $0 } } }
        await settle()
        try rules.update("primary") { $0.mode = .appearance; $0.light = target("automatic") }
        let scheduler = scheduler(); scheduler.start(); defer { scheduler.stop() }; await settle()
        let manual = Task {
            await queue.run(slot: BridgeStore.activationSlot(displayId: "primary")) {
                states["primary"]?.wallpaperID = "manual"
                scheduler.noteManualChoice("primary")
            }
        }
        await settle()
        try XCTUnwrap(release).resume()
        await blocker.value; await manual.value; await settle()
        XCTAssertTrue(changes.isEmpty)
        XCTAssertEqual(states["primary"]?.wallpaperID, "manual")
    }

    func testARuleThatFindsAManualCommandWaitingGivesWayAndDoesNotRetry() async throws {
        var release: CheckedContinuation<Void, Never>?
        let blocker = Task { await queue.run { await withCheckedContinuation { release = $0 } } }
        await settle()
        let manual = Task {
            await queue.run(slot: BridgeStore.activationSlot(displayId: "primary")) { states["primary"]?.wallpaperID = "manual" }
        }
        await settle()
        try rules.update("primary") { $0.mode = .appearance; $0.light = target("automatic") }
        let scheduler = scheduler(); scheduler.start(); defer { scheduler.stop() }; await settle()
        try XCTUnwrap(release).resume()
        await blocker.value; await manual.value; await settle()

        scheduler.evaluate(); await settle()
        XCTAssertTrue(changes.isEmpty, "The rule's event is spent, not queued again behind the user's choice")
        XCTAssertEqual(states["primary"]?.wallpaperID, "manual")
        XCTAssertNil(rules.errors["primary"], "Giving way is not a failure to report")
    }

    func testARuleThatFindsAManualCommandRunningGivesWayAndDoesNotReplaceIt() async throws {
        var release: CheckedContinuation<Void, Never>?
        let manual = Task {
            await queue.run(slot: BridgeStore.activationSlot(displayId: "primary")) {
                await withCheckedContinuation { release = $0 }
                states["primary"]?.wallpaperID = "manual"
            }
        }
        await settle()
        XCTAssertTrue(queue.isBusy)
        try rules.update("primary") { $0.mode = .appearance; $0.light = target("automatic") }
        let scheduler = scheduler(); scheduler.start(); defer { scheduler.stop() }; await settle()
        XCTAssertTrue(queue.waiting.isEmpty, "The rule does not queue up behind the user's command")
        try XCTUnwrap(release).resume()
        await manual.value; await settle()

        scheduler.evaluate(); await settle()
        XCTAssertTrue(changes.isEmpty, "The rule's event is spent, not applied over the user's choice")
        XCTAssertEqual(states["primary"]?.wallpaperID, "manual")
        XCTAssertNil(rules.errors["primary"], "Giving way is not a failure to report")
    }

    func testRapidSpaceChangesDiscardQueuedChoicesForDesktopsAlreadyLeft() async throws {
        var release: CheckedContinuation<Void, Never>?
        let blocker = Task { await queue.run { await withCheckedContinuation { release = $0 } } }
        await settle()
        try rules.update("primary") { $0.mode = .spaces; $0.spaces = ["a": target("ocean"), "b": target("forest"), "c": target("mountain")] }
        spaceVisits["primary"] = .init(spaceID: "a", token: "visit1")
        let scheduler = scheduler(); scheduler.start(); defer { scheduler.stop() }; await settle()
        spaceVisits["primary"] = .init(spaceID: "b", token: "visit2"); scheduler.evaluate()
        spaceVisits["primary"] = .init(spaceID: "c", token: "visit3"); scheduler.evaluate()
        try XCTUnwrap(release).resume(); await blocker.value; await settle()
        XCTAssertEqual(changes.map { $0.1.id }, ["mountain"])
    }
}
