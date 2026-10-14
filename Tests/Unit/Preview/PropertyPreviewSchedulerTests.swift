import Foundation
import XCTest
@testable import WallpaperMachine

extension ManualSleeper {
    /// Ends every wait that is pending now, as if the quiet period had passed. Returns how many
    /// there were.
    @discardableResult
    func finishWaits() -> Int {
        let waiting = pendingCount
        fireAll()
        return waiting
    }
}

/// Makes a wait fail on demand, as an injected sleep that throws would.
final class FailingSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var on = false
    var isOn: Bool {
        get { lock.withLock { on } }
        set { lock.withLock { on = newValue } }
    }
}

@MainActor
final class PropertyPreviewSchedulerTests: XCTestCase {
    private func settle() async { for _ in 0..<40 { await Task.yield() } }

    private func make(_ sleep: ManualSleeper, failing: FailingSwitch = FailingSwitch()) -> PropertyPreviewScheduler {
        PropertyPreviewScheduler(delay: .milliseconds(150), sleep: {
            if failing.isOn { throw URLError(.cancelled) }
            try await sleep.sleep($0)
        })
    }

    func testABurstRunsOnlyTheNewestWorkAfterTheQuietPeriod() async {
        let sleep = ManualSleeper()
        let scheduler = make(sleep)
        var ran: [Int] = []
        for value in 1...3 { scheduler.schedule(key: "k") { ran.append(value) } }
        await settle()
        XCTAssertTrue(ran.isEmpty, "nothing runs before the quiet period ends")
        XCTAssertEqual(sleep.pendingCount, 1, "one wait serves the whole burst")
        sleep.finishWaits()
        await settle()
        XCTAssertEqual(ran, [3])
        XCTAssertFalse(scheduler.isPending("k"))
    }

    func testAnEditDuringTheWaitStartsTheWaitOver() async {
        let sleep = ManualSleeper()
        let scheduler = make(sleep)
        var ran: [String] = []
        scheduler.schedule(key: "k") { ran.append("first") }
        await settle()
        scheduler.schedule(key: "k") { ran.append("second") }
        await settle()
        sleep.finishWaits()
        await settle()
        XCTAssertTrue(ran.isEmpty, "the first wait ended, but a newer edit arrived during it")
        XCTAssertEqual(sleep.pendingCount, 1)
        sleep.finishWaits()
        await settle()
        XCTAssertEqual(ran, ["second"])
    }

    func testEditsWhileARunIsInFlightQueueBehindItAsOneRun() async {
        let sleep = ManualSleeper()
        let scheduler = make(sleep)
        var gate: CheckedContinuation<Void, Never>?
        var running = 0, highest = 0
        var ran: [String] = []
        scheduler.schedule(key: "k") {
            running += 1; highest = max(highest, running)
            await withCheckedContinuation { gate = $0 }
            ran.append("first")
            running -= 1
        }
        await settle()
        sleep.finishWaits()
        await settle()
        XCTAssertNotNil(gate, "the first run is in flight")
        for name in ["second", "third"] {
            scheduler.schedule(key: "k") {
                running += 1; highest = max(highest, running)
                ran.append(name)
                running -= 1
            }
        }
        await settle()
        sleep.finishWaits()
        await settle()
        XCTAssertTrue(ran.isEmpty, "a second run does not start while the first is in flight")
        gate?.resume()
        await settle()
        XCTAssertEqual(ran, ["first"])
        sleep.finishWaits()
        await settle()
        XCTAssertEqual(ran, ["first", "third"], "the edits made meanwhile cost one more run, the newest")
        XCTAssertEqual(highest, 1)
        XCTAssertFalse(scheduler.isPending("k"))
    }

    func testCancelDropsWaitingWorkAndTheKeyCanBeUsedAgain() async {
        let sleep = ManualSleeper()
        let scheduler = make(sleep)
        var ran: [String] = []
        scheduler.schedule(key: "k") { ran.append("dropped") }
        await settle()
        scheduler.cancel("k")
        sleep.finishWaits()
        await settle()
        XCTAssertTrue(ran.isEmpty)
        XCTAssertFalse(scheduler.isPending("k"))
        scheduler.schedule(key: "k") { ran.append("later") }
        await settle()
        sleep.finishWaits()
        await settle()
        XCTAssertEqual(ran, ["later"])
        scheduler.schedule(key: "k") { ran.append("all") }
        scheduler.cancelAll()
        await settle()
        sleep.finishWaits()
        await settle()
        XCTAssertEqual(ran, ["later"])
    }

    func testKeysWaitAndRunIndependently() async {
        let sleep = ManualSleeper()
        let scheduler = make(sleep)
        var ran: [String] = []
        scheduler.schedule(key: "a") { ran.append("a") }
        scheduler.schedule(key: "b") { ran.append("b") }
        await settle()
        XCTAssertEqual(sleep.pendingCount, 2)
        scheduler.cancel("a")
        sleep.finishWaits()
        await settle()
        XCTAssertEqual(ran, ["b"])
    }

    func testAZeroDelayRunsAtOnceWithoutAnyWaitAndStepsInFlightCostOneMoreRun() async {
        let sleep = ManualSleeper()
        let scheduler = make(sleep)
        var gate: CheckedContinuation<Void, Never>?
        var ran: [String] = []
        scheduler.schedule(key: "k", delay: .zero) {
            await withCheckedContinuation { gate = $0 }
            ran.append("first")
        }
        await settle()
        XCTAssertNotNil(gate, "the work started without the quiet period")
        XCTAssertTrue(sleep.requested.isEmpty, "a source that spaces its own edits is not made to wait")
        for name in ["second", "third", "fourth"] { scheduler.schedule(key: "k", delay: .zero) { ran.append(name) } }
        await settle()
        XCTAssertTrue(ran.isEmpty, "nothing overlaps a run in flight")
        gate?.resume()
        await settle()
        XCTAssertEqual(ran, ["first", "fourth"], "the steps that came meanwhile cost one more run, the newest")
        XCTAssertTrue(sleep.requested.isEmpty)
        XCTAssertFalse(scheduler.isPending("k"))
    }

    func testAZeroDelayEditOvertakesTheQuietPeriodAnEarlierEditStartedAndAnotherEditRestoresIt() async {
        let sleep = ManualSleeper()
        let scheduler = make(sleep)
        var ran: [String] = []
        scheduler.schedule(key: "k") { ran.append("edit") }
        await settle()
        XCTAssertEqual(sleep.pendingCount, 1)
        scheduler.schedule(key: "k", delay: .zero) { ran.append("step") }
        await settle()
        sleep.finishWaits()
        await settle()
        XCTAssertEqual(ran, ["step"], "the wait that was running ends, and the newest work follows without another")
        XCTAssertEqual(sleep.requested, [.milliseconds(150)])

        scheduler.schedule(key: "k", delay: .zero) { ran.append("step again") }
        await settle()
        scheduler.schedule(key: "k") { ran.append("release") }
        await settle()
        sleep.finishWaits()
        await settle()
        XCTAssertEqual(ran.last, "release", "an edit after a drag waits out its quiet period again")
    }

    func testAWaitThatFailsDoesNotBlockTheKeyForever() async {
        let sleep = ManualSleeper()
        let failing = FailingSwitch()
        failing.isOn = true
        let scheduler = make(sleep, failing: failing)
        var ran: [String] = []
        scheduler.schedule(key: "k") { ran.append("lost") }
        await settle()
        XCTAssertFalse(scheduler.isPending("k"))
        failing.isOn = false
        scheduler.schedule(key: "k") { ran.append("kept") }
        await settle()
        sleep.finishWaits()
        await settle()
        XCTAssertEqual(ran, ["kept"])
    }
}
