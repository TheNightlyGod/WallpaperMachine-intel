import AppKit
import XCTest

@testable import WallpaperMachine

/// When the auditor looks at the wallpaper windows, what it concludes and what
/// it does about it. The windows are injected observations and the delays are
/// recorded rather than slept: no window is created and nothing waits. What it
/// concludes is checked as the structured reports it makes (which fault, which
/// window, which look, how many repairs); only one test pins the wording of the
/// log lines, because those are the lines `docs/features/diagnostics.md` shows.
@MainActor
final class WallpaperWindowAuditorTests: XCTestCase {
    private typealias Step = WallpaperWindowAuditor.RepairStep

    private let displayFrame = CGRect(x: 0, y: 0, width: 3456, height: 2234)

    private func entry(isOnScreen: Bool = true) -> DesktopWindowObservation.WindowServerEntry {
        .init(layer: -2_147_483_623, alpha: 1, isOnScreen: isOnScreen, bounds: displayFrame)
    }

    private func healthy(number: Int = 1234, display: UInt32 = 1) -> DesktopWindowObservation {
        DesktopWindowObservation(
            windowNumber: number, className: "MWEWallpaperDesktopWindow", displayID: display,
            frame: displayFrame, displayFrame: displayFrame, level: -2_147_483_623, alpha: 1,
            isOrderedIn: true, isOnActiveSpace: true, occlusionVisible: true,
            collectionBehaviorRaw: 0x51, server: entry())
    }

    /// Ordered in, but on a Space that is not showing.
    private func offSpace(number: Int = 1234, display: UInt32 = 1) -> DesktopWindowObservation {
        var window = healthy(number: number, display: display)
        window.isOnActiveSpace = false
        window.occlusionVisible = false
        window.server = entry(isOnScreen: false)
        return window
    }

    /// The window server composites nothing for it although AppKit says it is on the active Space.
    private func offScreen(number: Int = 1234) -> DesktopWindowObservation {
        var window = healthy(number: number)
        window.server = entry(isOnScreen: false)
        return window
    }

    private func outside(number: Int = 1234) -> DesktopWindowObservation {
        var window = healthy(number: number)
        window.frame = CGRect(x: 9000, y: 0, width: 3456, height: 2234)
        return window
    }

    @MainActor
    private final class Harness {
        let workspace = NotificationCenter()
        let screens = NotificationCenter()
        var windows: [DesktopWindowObservation]
        var canExpectVisible = true
        var desktopSpace = true
        var concealed = Set<UInt32>()
        var away = Set<Int>()
        var displays = DisplayConfiguration(displays: [])
        var clock = ContinuousClock.now
        var holdSleeps = false
        var held: [CheckedContinuation<Void, Never>] = []
        var observations = 0
        var sleeps: [Duration] = []
        var repairs: [(window: Int, step: Step)] = []
        var reports: [WallpaperWindowAuditor.Report] = []
        var onRepair: (() -> Void)?
        var auditor: WallpaperWindowAuditor!

        init(
            windows: [DesktopWindowObservation], defaults: UserDefaults,
            policy: WallpaperWindowAuditor.Policy = .init()
        ) {
            self.windows = windows
            auditor = WallpaperWindowAuditor(
                workspaceCenter: workspace, displayCenter: screens, defaults: defaults,
                displayConfiguration: { [unowned self] in self.displays },
                windowNumbers: { [unowned self] in self.windows.map(\.windowNumber) },
                observe: { [unowned self] in
                    self.observations += 1
                    return self.windows
                },
                canExpectVisible: { [unowned self] in self.canExpectVisible },
                isDesktopSpace: { [unowned self] _ in self.desktopSpace },
                isConcealed: { [unowned self] in $0.map(self.concealed.contains) ?? false },
                isAwayFromCurrentDesktop: { [unowned self] in self.away.contains($0) },
                repair: { [unowned self] window, step in
                    self.repairs.append((window, step))
                    self.onRepair?()
                },
                sleep: { [unowned self] duration in
                    self.sleeps.append(duration)
                    if self.holdSleeps { await withCheckedContinuation { self.held.append($0) } }
                },
                now: { [unowned self] in self.clock },
                record: { [unowned self] in self.reports.append($0) },
                policy: policy)
        }

        func spaceChanged() {
            workspace.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        }

        func screensChanged() {
            screens.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        }

        func settle() async { await auditor.waitForSchedule() }
    }

    private func repairsApplied(_ reports: [WallpaperWindowAuditor.Report]) -> [Step] {
        reports.compactMap { report in
            if case let .repaired(step) = report.kind { step } else { nil }
        }
    }

    private func harness(
        _ windows: [DesktopWindowObservation], repairs: Bool = false,
        policy: WallpaperWindowAuditor.Policy = .init()
    ) throws -> Harness {
        let defaults = try TemporaryDefaults.make(for: self).defaults
        if repairs { defaults.set(true, forKey: WallpaperWindowAuditor.repairKey) }
        let harness = Harness(windows: windows, defaults: defaults, policy: policy)
        harness.auditor.start()
        return harness
    }

    /// Lets the main actor run until `condition` holds; a bounded number of
    /// turns, never a clock.
    private func turns(until condition: @autoclosure () -> Bool, line: UInt = #line) async {
        var remaining = 2000
        while !condition(), remaining > 0 {
            remaining -= 1
            await Task.yield()
        }
        XCTAssertTrue(condition(), "the awaited state never arrived", line: line)
    }

    /// Gives work that is already runnable on the main actor time to run, for
    /// asserting that something did not happen.
    private func drain() async {
        for _ in 0..<200 { await Task.yield() }
    }

    // MARK: Healthy windows

    func testHealthyWindowsProduceNoLogAndNoRepairEvenWhenRepairIsEnabled() async throws {
        let h = try harness([healthy()], repairs: true)

        h.spaceChanged()
        await h.settle()

        XCTAssertEqual(h.observations, 1, "the first look found everything fine, so there is no second one")
        XCTAssertEqual(h.sleeps, [.seconds(1)])
        XCTAssertTrue(h.reports.isEmpty)
        XCTAssertTrue(h.repairs.isEmpty)
    }

    // MARK: A window that is not showing

    func testWindowOffTheActiveSpaceIsLoggedOnceButNotRepairedWhileRepairIsDisabled() async throws {
        let h = try harness([offSpace()])

        h.spaceChanged()
        await h.settle()

        XCTAssertEqual(h.sleeps, [.seconds(1), .seconds(2)], "looks at +1 s and +3 s")
        XCTAssertEqual(h.observations, 2)
        XCTAssertTrue(h.repairs.isEmpty, "repair is off unless the hidden preference is set")
        XCTAssertEqual(
            h.reports.map(\.kind), [.fault, .persisting],
            "the first sighting and, at the last look, that it persists")
        let first = try XCTUnwrap(h.reports.first)
        XCTAssertEqual(first.trigger, .activeSpaceDidChange)
        XCTAssertEqual(first.offset, .seconds(1))
        XCTAssertEqual(first.window, offSpace(), "the report carries the window's whole observation")
        XCTAssertEqual(first.window?.state, .notOnActiveSpace)
        XCTAssertEqual(first.window?.displayID, 1)
        let last = try XCTUnwrap(h.reports.last)
        XCTAssertEqual(last.offset, .seconds(3))
        XCTAssertEqual(last.repairsDone, 0)
        XCTAssertEqual(last.window?.windowNumber, 1234)
    }

    func testEnabledRepairRunsTheLadderInOrderAndNeverMoreThanTwice() async throws {
        var policy = WallpaperWindowAuditor.Policy()
        policy.checkOffsets = [.seconds(1), .seconds(2), .seconds(3), .seconds(4)]
        let h = try harness([offSpace()], repairs: true, policy: policy)

        h.spaceChanged()
        await h.settle()

        XCTAssertEqual(h.observations, 4)
        XCTAssertEqual(h.repairs.map(\.step), [.orderFront, .reassertLevelAndBehavior])
        XCTAssertEqual(h.repairs.map(\.window), [1234, 1234])
        XCTAssertEqual(repairsApplied(h.reports), [.orderFront, .reassertLevelAndBehavior], "each repair is reported")
        let last = try XCTUnwrap(h.reports.last)
        XCTAssertEqual(last.kind, .persisting, "the window never came back")
        XCTAssertEqual(last.repairsDone, 2)
    }

    func testATriggerNeverSpendsMoreRepairsThanItsBudget() async throws {
        var policy = WallpaperWindowAuditor.Policy()
        policy.maximumRepairsPerTrigger = 1
        let h = try harness([offSpace()], repairs: true, policy: policy)

        h.spaceChanged()
        await h.settle()

        XCTAssertEqual(h.repairs.map(\.step), [.orderFront])
        XCTAssertEqual(h.observations, 2, "the looks go on after the budget is spent")
    }

    func testTheLadderStopsAsSoonAsTheWindowRecovers() async throws {
        let h = try harness([offSpace()], repairs: true)
        h.onRepair = { [unowned h] in h.windows = [self.healthy()] }

        h.spaceChanged()
        await h.settle()

        XCTAssertEqual(h.repairs.map(\.step), [.orderFront], "step 2 is for a window step 1 did not bring back")
        XCTAssertEqual(h.observations, 2, "one look to find it, one to see it recovered")
        let recovered = try XCTUnwrap(h.reports.last)
        XCTAssertEqual(recovered.kind, .recovered)
        XCTAssertEqual(recovered.repairsDone, 1)
        XCTAssertNil(recovered.window, "a recovery is about every window, not one")
    }

    func testOnlyTheFaultyWindowIsRepaired() async throws {
        let h = try harness([healthy(number: 11, display: 1), offSpace(number: 22, display: 2)], repairs: true)

        h.spaceChanged()
        await h.settle()

        XCTAssertEqual(h.repairs.map(\.window), [22, 22])
        XCTAssertEqual(
            Set(h.reports.compactMap { $0.window?.windowNumber }), [22],
            "nothing is said about the window that is showing")
    }

    // MARK: Nothing to see

    func testNothingHappensWhilePresentationIsDeliberatelySuspended() async throws {
        let h = try harness([offSpace()], repairs: true)
        h.canExpectVisible = false

        h.spaceChanged()
        await h.settle()

        XCTAssertTrue(h.reports.isEmpty)
        XCTAssertTrue(h.repairs.isEmpty)
    }

    func testNothingHappensInAFullscreenSpaceForAFaultThatSpaceExplains() async throws {
        let h = try harness([offSpace(), offScreen(number: 5678)], repairs: true)
        h.desktopSpace = false

        h.spaceChanged()
        await h.settle()

        XCTAssertTrue(h.reports.isEmpty, "desktop windows are legitimately off screen above a full-screen app")
        XCTAssertTrue(h.repairs.isEmpty)
    }

    func testAWindowHiddenWhileItsDesktopsWallpaperLoadsIsNotAFault() async throws {
        var hidden = healthy()
        hidden.alpha = 0
        var other = healthy(number: 5678, display: 2)
        other.alpha = 0
        let h = try harness([hidden, other])
        h.concealed = [1]

        h.spaceChanged()
        await h.settle()

        XCTAssertEqual(Set(h.reports.compactMap(\.window?.windowNumber)), [5678],
                       "only the display that follows Spaces hides its window on purpose")
    }

    func testAWallpaperKeptPausedForAnotherDesktopIsNotAFault() async throws {
        let h = try harness([offSpace(), offSpace(number: 5678)])
        h.away = [1234]

        h.spaceChanged()
        await h.settle()

        XCTAssertEqual(Set(h.reports.compactMap(\.window?.windowNumber)), [5678],
                       "only a window the pinning put on another desktop is off the active Space on purpose")
    }

    func testAFaultTheSpaceDoesNotExplainIsStillRecordedInAFullscreenSpace() async throws {
        let h = try harness([outside()])
        h.desktopSpace = false

        h.spaceChanged()
        await h.settle()

        XCTAssertEqual(h.reports.first?.window?.state, .outsideItsDisplay)
    }

    // MARK: Triggers

    func testAWakeIntoALockedSessionIsAuditedOnceThePresentationResumes() async throws {
        let h = try harness([offSpace()])
        await h.settle()
        h.sleeps.removeAll()
        h.reports.removeAll()
        h.canExpectVisible = false

        h.workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        await h.settle()
        XCTAssertTrue(h.reports.isEmpty, "the locked session is not expected to show the wallpaper")
        h.sleeps.removeAll()

        h.canExpectVisible = true
        h.clock = h.clock.advanced(by: .seconds(120))
        h.auditor.presentationResumed()
        await h.settle()
        XCTAssertEqual(h.sleeps, [.seconds(1), .seconds(2)])
        XCTAssertEqual(h.reports.first?.trigger, .presentationResumed)
    }

    func testABurstOfTriggersCoalescesToTheLatestGeneration() async throws {
        let h = try harness([offSpace()])

        h.spaceChanged()
        h.workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        h.workspace.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        await h.settle()

        XCTAssertEqual(h.observations, 2, "one schedule of looks, not three")
        XCTAssertEqual(h.sleeps, [.seconds(1), .seconds(2)])
        XCTAssertEqual(h.reports.first?.trigger, .screensDidWake, "the latest trigger owns the schedule")
    }

    func testASupersededScheduleNeverLooks() async throws {
        let h = try harness([offSpace()])
        h.holdSleeps = true

        h.spaceChanged()
        await turns(until: h.held.count == 1)
        h.workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        await turns(until: h.held.count == 2)

        h.held.removeFirst().resume()
        await drain()
        XCTAssertEqual(h.observations, 0, "the first schedule was replaced before its delay ended")

        h.holdSleeps = false
        h.held.removeFirst().resume()
        await h.settle()
        XCTAssertEqual(h.observations, 2)
        XCTAssertEqual(h.reports.first?.trigger, .didWake)
    }

    func testStoppingCancelsAPendingCheck() async throws {
        let h = try harness([offSpace()])
        h.holdSleeps = true

        h.spaceChanged()
        await turns(until: h.held.count == 1)
        h.auditor.stop()
        h.held.removeFirst().resume()
        await drain()

        XCTAssertEqual(h.observations, 0)
        h.spaceChanged()
        await h.settle()
        XCTAssertEqual(h.observations, 0, "a stopped auditor ignores notifications")
    }

    func testScreenChangesThatLeaveTheDisplaysAsTheyWereDoNotCheck() async throws {
        let h = try harness([healthy()])
        await h.settle()
        h.sleeps.removeAll()

        for _ in 0..<240 { h.screensChanged() }
        await h.settle()
        XCTAssertTrue(h.sleeps.isEmpty)

        h.displays.displays.append(
            .init(id: 2, frame: CGRect(x: 3456, y: 0, width: 1920, height: 1080), scale: 1, refreshRate: 60))
        h.screensChanged()
        await h.settle()
        XCTAssertEqual(h.sleeps, [.seconds(1)], "a display that came or went starts a check")
    }

    func testANewWindowNumberSchedulesTheOpenOffsets() async throws {
        let h = try harness([offSpace(number: 1)])
        await h.settle()
        XCTAssertEqual(h.sleeps, [.seconds(1), .seconds(1), .seconds(3)], "windows open before start count as new: +1 s, +2 s, +5 s")
        XCTAssertEqual(h.reports.first?.trigger, .windowOpened)

        h.windows.append(offSpace(number: 2))
        h.auditor.windowsMayHaveChanged()
        await h.settle()
        XCTAssertEqual(h.sleeps.count, 6)
        XCTAssertTrue(h.reports.contains { $0.window?.windowNumber == 2 })
    }

    func testAnUnchangedWindowSetDoesNothing() async throws {
        let h = try harness([healthy(number: 1), healthy(number: 2)])
        await h.settle()
        XCTAssertEqual(h.sleeps, [.seconds(1)])

        for _ in 0..<50 { h.auditor.windowsMayHaveChanged() }
        h.windows.removeLast()
        h.auditor.windowsMayHaveChanged()
        await h.settle()

        XCTAssertEqual(h.sleeps, [.seconds(1)], "the same windows, or fewer, are not a reason to look")
        XCTAssertEqual(h.observations, 1)
    }

    // MARK: Log throttle

    func testLogsAreThrottledPerWindowAndState() async throws {
        let h = try harness([offSpace()])
        h.spaceChanged()
        await h.settle()
        let written = h.reports.count
        XCTAssertEqual(written, 2)

        h.clock = h.clock.advanced(by: .seconds(59))
        h.spaceChanged()
        await h.settle()
        XCTAssertEqual(h.reports.count, written, "the same fault inside the interval is not written again")

        h.windows = [outside()]
        h.spaceChanged()
        await h.settle()
        XCTAssertGreaterThan(h.reports.count, written, "a different state is a new report")
        let afterOther = h.reports.count

        h.windows = [offSpace()]
        h.clock = h.clock.advanced(by: .seconds(2))
        h.spaceChanged()
        await h.settle()
        XCTAssertGreaterThan(h.reports.count, afterOther, "the first report has aged out of the interval")
    }

    // MARK: Log wording

    /// The shape of the lines in `docs/features/diagnostics.md#desktop-window-audit`, which a
    /// bug report is read by. This is the one place the wording is pinned; every test above
    /// asserts the facts in the reports instead.
    func testTheLogLinesAreWordedAsTheDocsShowThem() {
        let window = offSpace()
        func line(
            _ kind: WallpaperWindowAuditor.Report.Kind, offset: Duration, repairs: Int,
            window: DesktopWindowObservation? = nil
        ) -> String {
            WallpaperWindowAuditor.Report(
                kind: kind, trigger: .activeSpaceDidChange, offset: offset, window: window, repairsDone: repairs
            ).line
        }

        XCTAssertEqual(
            line(.fault, offset: .seconds(1), repairs: 0, window: window),
            "desktop window audit: display 1 MWEWallpaperDesktopWindow #1234 is notOnActiveSpace at "
                + "+1s after activeSpaceDidChange; " + DesktopWindowDiagnostics.line(window))
        XCTAssertEqual(
            line(.persisting, offset: .seconds(3), repairs: 0, window: window),
            "desktop window audit: display 1 MWEWallpaperDesktopWindow #1234 is still notOnActiveSpace at "
                + "+3s after activeSpaceDidChange, after 0 repairs")
        XCTAssertEqual(
            line(.repaired(.orderFront), offset: .seconds(1), repairs: 1, window: window),
            "desktop window audit: repair 1 (order front) applied to MWEWallpaperDesktopWindow #1234")
        XCTAssertEqual(
            line(.recovered, offset: .seconds(3), repairs: 1),
            "desktop window audit: every wallpaper window is showing again at +3s after "
                + "activeSpaceDidChange, after 1 repair")
    }

    // MARK: Which Spaces count as a desktop

    func testASpaceIsADesktopUnlessTheTopologySaysItIsFullscreen() {
        let desktop = WallpaperDisplaySpaces(displayUUID: "a", spaces: [.init(id: "s1", number: 1)], current: "s1")
        let fullscreen = WallpaperDisplaySpaces(displayUUID: "b", spaces: [.init(id: "s1", number: 1)], current: nil)
        let cases: [(String, UInt32?, Bool, [String: WallpaperDisplaySpaces], Bool)] = [
            ("topology unavailable", 1, false, [:], true),
            ("display not in the topology", 3, true, ["1": desktop], true),
            ("display on a desktop", 1, true, ["1": desktop, "2": fullscreen], true),
            ("display in a full-screen Space", 2, true, ["1": desktop, "2": fullscreen], false),
            ("window on no display, none full screen", nil, true, ["1": desktop], true),
            ("window on no display, one full screen", nil, true, ["1": desktop, "2": fullscreen], false),
        ]
        for (name, display, available, displays, expected) in cases {
            XCTAssertEqual(
                WallpaperWindowAuditor.spaceIsDesktop(displayID: display, available: available, displays: displays),
                expected, name)
        }
    }
}
