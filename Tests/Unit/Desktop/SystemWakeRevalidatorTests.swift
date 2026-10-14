import AppKit
import XCTest

@testable import WallpaperMachine

/// When the check after a wake is asked for, and what is done with its answer.
/// The wake notifications come from a private center and the delays, the idle
/// wait and the bridge call are injected closures: nothing sleeps, no window
/// exists and no renderer is asked. The answer is checked as the counts and
/// reasons the revalidator reports; one test pins the wording of the log lines,
/// because those are the lines `docs/features/diagnostics.md` shows.
@MainActor
final class SystemWakeRevalidatorTests: XCTestCase {
    private func check(_ display: UInt32 = 1, _ outcome: String = "ok") -> BridgeSurfaceCheck {
        BridgeSurfaceCheck(displayId: display, outcome: outcome, framesBefore: 10, framesAfter: 20)
    }

    private struct Failure: Error, LocalizedError {
        var errorDescription: String? { "the bridge is gone" }
    }

    @MainActor
    private final class Harness {
        let center = NotificationCenter()
        var presenting = true
        var result: Result<[BridgeSurfaceCheck], Error> = .success([])
        /// While true, the idle wait and the debounce sleep park until released.
        var holdIdle = false
        var holdSleep = false
        var parkedIdle: [CheckedContinuation<Void, Never>] = []
        var parkedSleep: [CheckedContinuation<Void, Never>] = []
        var idleWaits = 0
        var sleeps: [Duration] = []
        var performed: [String] = []
        var reports: [SystemWakeRevalidator.Report] = []
        var revalidator: SystemWakeRevalidator!

        init() {
            revalidator = SystemWakeRevalidator(
                center: center,
                isPresenting: { [unowned self] in self.presenting },
                waitForIdle: { [unowned self] in
                    self.idleWaits += 1
                    if self.holdIdle { await withCheckedContinuation { self.parkedIdle.append($0) } }
                },
                perform: { [unowned self] reason in
                    self.performed.append(reason)
                    return try self.result.get()
                },
                sleep: { [unowned self] duration in
                    self.sleeps.append(duration)
                    if self.holdSleep { await withCheckedContinuation { self.parkedSleep.append($0) } }
                },
                report: { [unowned self] in self.reports.append($0) })
            revalidator.start()
        }

        func wake() { center.post(name: NSWorkspace.didWakeNotification, object: nil) }
        func screensWake() { center.post(name: NSWorkspace.screensDidWakeNotification, object: nil) }
        func settle() async { await revalidator.waitForSchedule() }

        func releaseIdle() {
            holdIdle = false
            let parked = parkedIdle
            parkedIdle.removeAll()
            parked.forEach { $0.resume() }
        }

        func releaseSleep() {
            holdSleep = false
            let parked = parkedSleep
            parkedSleep.removeAll()
            parked.forEach { $0.resume() }
        }
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

    func testDidWakeAndScreensDidWakeProduceOnePass() async {
        let h = Harness()

        h.wake()
        h.screensWake()
        await h.settle()

        XCTAssertEqual(h.performed, ["didWake"], "one wake is one check, named by the first notification")
        XCTAssertEqual(h.sleeps, [.milliseconds(650)], "the burst is debounced, not slept through twice")
    }

    func testPassWaitsForTheCommandQueueToBeIdle() async {
        let h = Harness()
        h.holdIdle = true

        h.wake()
        await turns(until: !h.parkedIdle.isEmpty)
        await drain()
        XCTAssertEqual(h.performed, [], "a check must not run in the middle of an Apply that is replacing the scenes")

        h.releaseIdle()
        await h.settle()
        XCTAssertEqual(h.performed, ["didWake"])
    }

    func testPassIsDeferredUntilPresentationResumesAfterAWakeAtTheLockScreen() async {
        let h = Harness()
        h.presenting = false

        h.wake()
        h.screensWake()
        await h.settle()
        XCTAssertEqual(h.performed, [], "scenes suspended behind the lock screen have counters that mean nothing")
        XCTAssertEqual(h.idleWaits, 0, "a pass that cannot run does not queue behind the user's commands")

        h.presenting = true
        h.revalidator.presentationResumed()
        await h.settle()
        XCTAssertEqual(h.performed, ["didWake, once presentation resumed"])

        // The wake has been checked; later resumes owe nothing.
        h.revalidator.presentationResumed()
        await h.settle()
        XCTAssertEqual(h.performed.count, 1)
    }

    func testPresentationResumingWithoutAWakeChecksNothing() async {
        let h = Harness()

        h.revalidator.presentationResumed()
        await h.settle()

        XCTAssertEqual(h.performed, [])
        XCTAssertEqual(h.sleeps, [], "an unlock that follows no wake is not a reason to read the scenes")
    }

    func testAPassStaysOwedWhenPresentationStopsDuringTheIdleWait() async {
        let h = Harness()
        h.holdIdle = true

        h.wake()
        await turns(until: !h.parkedIdle.isEmpty)
        h.presenting = false
        h.releaseIdle()
        await h.settle()
        XCTAssertEqual(h.performed, [], "the Mac locked again while the Apply finished")

        h.presenting = true
        h.revalidator.presentationResumed()
        await h.settle()
        XCTAssertEqual(h.performed, ["didWake, once presentation resumed"])
    }

    func testANewWakeSupersedesAPendingPass() async {
        let h = Harness()
        h.holdSleep = true

        h.wake()
        await turns(until: h.parkedSleep.count == 1)
        h.screensWake()
        await turns(until: h.parkedSleep.count == 2)
        h.releaseSleep()
        await h.settle()

        XCTAssertEqual(h.performed, ["didWake"], "the first debounce ended after a newer wake: only the newer one runs")
    }

    func testStoppingCancelsAPendingPassAndIgnoresLaterWakes() async {
        let h = Harness()
        h.holdSleep = true

        h.wake()
        await turns(until: h.parkedSleep.count == 1)
        h.revalidator.stop()
        h.releaseSleep()
        await h.settle()
        h.wake()
        await h.settle()

        XCTAssertEqual(h.performed, [], "a stopped revalidator asks the bridge for nothing")
        XCTAssertEqual(h.sleeps.count, 1)
    }

    func testABridgeFailureIsReportedNotThrown() async {
        let h = Harness()
        h.result = .failure(Failure())

        h.wake()
        await h.settle()

        XCTAssertEqual(h.performed, ["didWake"])
        XCTAssertEqual(
            h.reports, [.failed(reason: "didWake", error: "the bridge is gone")],
            "the report must say what failed")
        XCTAssertTrue(h.reports[0].isWarning)

        // A failed pass leaves nothing stuck: the next wake is checked.
        h.result = .success([check()])
        h.wake()
        await h.settle()
        XCTAssertEqual(h.performed, ["didWake", "didWake"])
    }

    func testAHealthyPassIsInformationAndARepairOrAStuckSceneIsAWarning() async {
        let h = Harness()

        h.result = .success([check(1), check(2)])
        h.wake()
        await h.settle()
        XCTAssertEqual(
            h.reports.last, .checked(reason: "didWake", .init(checked: 2, repaired: 0, unrepaired: 0, skipped: 0)))
        XCTAssertEqual(h.reports.map(\.isWarning), [false], "a Mac that woke well leaves no warning")

        h.result = .success([check(1), check(2, "repaired"), check(3, "skipped_paused")])
        h.wake()
        await h.settle()
        XCTAssertEqual(
            h.reports.last,
            .checked(reason: "didWake", .init(checked: 2, repaired: 1, unrepaired: 0, skipped: 1)),
            "a display left alone is counted apart from the checked ones")
        XCTAssertEqual(h.reports.map(\.isWarning), [false, true], "a rebuilt surface is worth a warning")

        h.result = .success([check(1, "gave_up")])
        h.wake()
        await h.settle()
        XCTAssertEqual(
            h.reports.last, .checked(reason: "didWake", .init(checked: 1, repaired: 0, unrepaired: 1, skipped: 0)))
        XCTAssertEqual(
            h.reports.map(\.isWarning), [false, true, true], "a scene the engine would not rebuild is a warning")
    }

    func testEveryOutcomeIsCountedWhereTheBridgeMeansIt() {
        let summary = SystemWakeRevalidator.Summary([
            check(1, "ok"),
            check(2, "repaired"),
            check(3, "gave_up"),
            check(4, "recovery_pending"),
            check(5, "recovery_failed"),
            check(6, "skipped_paused"),
            check(7, "skipped_not_continuous"),
            check(8, "skipped_unreadable"),
            check(9, "skipped_changed"),
        ])

        XCTAssertEqual(summary, .init(checked: 5, repaired: 1, unrepaired: 3, skipped: 4))
        XCTAssertEqual(SystemWakeRevalidator.Summary([]), .init(checked: 0, repaired: 0, unrepaired: 0, skipped: 0))
    }

    func testPausedDisplaysAreSkippedNotCounted() async {
        let h = Harness()
        h.result = .success([check(1, "skipped_paused"), check(2, "skipped_not_continuous")])

        h.wake()
        await h.settle()

        XCTAssertEqual(
            h.reports, [.checked(reason: "didWake", .init(checked: 0, repaired: 0, unrepaired: 0, skipped: 2))])
        XCTAssertFalse(h.reports[0].isWarning)
    }

    /// The shape of the lines in `docs/features/diagnostics.md#wake-check`, which a bug report is
    /// read by. The one place the wording is pinned; the tests above assert the counts.
    func testTheLogLinesAreWordedAsTheDocsShowThem() {
        typealias Report = SystemWakeRevalidator.Report
        XCTAssertEqual(
            Report.checked(reason: "didWake", .init(checked: 1, repaired: 0, unrepaired: 0, skipped: 1)).message,
            "wake check (didWake): 1 display checked, 0 repaired, 1 skipped")
        XCTAssertEqual(
            Report.checked(
                reason: "didWake, once presentation resumed",
                .init(checked: 1, repaired: 1, unrepaired: 0, skipped: 0)
            ).message,
            "wake check (didWake, once presentation resumed): 1 display checked, 1 repaired")
        XCTAssertEqual(
            Report.checked(reason: "screensDidWake", .init(checked: 2, repaired: 0, unrepaired: 1, skipped: 0)).message,
            "wake check (screensDidWake): 2 displays checked, 0 repaired, 1 still not drawing")
        XCTAssertEqual(
            Report.failed(reason: "didWake", error: "the bridge is gone").message,
            "wake check (didWake) failed: the bridge is gone")
    }
}
