import XCTest

@testable import WallpaperMachine

/// The supervisor's timers are scripted: a stage that must hang parks on a latch, and the
/// deadline passes when the test fires the sleep the supervisor asked for. Which sleep that
/// is names the time the stage was given, so a budget is checked by waiting for it. The
/// clock the supervisor reads is scripted too, so no test depends on how fast the machine is.
/// One test runs the real timer with tiny budgets to prove the default wiring.
@MainActor
final class QuitSupervisorTests: XCTestCase {
    private final class ScriptedClock {
        private let base = ContinuousClock.now
        private var elapsed = Duration.zero
        var instant: ContinuousClock.Instant { base.advanced(by: elapsed) }
        func pass(_ amount: Duration) { elapsed += amount }
    }

    /// Sleeps until the test fires the duration, or the sleeping task is cancelled.
    private final class ManualSleeper: @unchecked Sendable {
        private let lock = NSLock()
        private var pending: [Int: (duration: Duration, continuation: CheckedContinuation<Void, any Error>)] = [:]
        private var cancelledEarly: Set<Int> = []
        private var nextID = 0

        func sleep(_ duration: Duration) async throws {
            if Task.isCancelled { throw CancellationError() }
            let id = lock.withLock {
                nextID += 1
                return nextID
            }
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    lock.lock()
                    if cancelledEarly.remove(id) != nil {
                        lock.unlock()
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    pending[id] = (duration, continuation)
                    lock.unlock()
                }
            } onCancel: {
                lock.lock()
                let entry = pending.removeValue(forKey: id)
                if entry == nil { cancelledEarly.insert(id) }
                lock.unlock()
                entry?.continuation.resume(throwing: CancellationError())
            }
        }

        func isPending(_ duration: Duration) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return pending.values.contains { $0.duration == duration }
        }

        /// The deadline of every stage that is waiting for exactly `duration` passes.
        func fire(_ duration: Duration) {
            lock.lock()
            let due = pending.filter { $0.value.duration == duration }
            due.keys.forEach { pending.removeValue(forKey: $0) }
            lock.unlock()
            due.values.forEach { $0.continuation.resume() }
        }
    }

    /// Parks a stage until released. A cooperative stage also leaves when cancelled.
    private final class Latch: @unchecked Sendable {
        private let lock = NSLock()
        private var released = false
        private var cancelled = false
        private var waiters: [CheckedContinuation<Void, any Error>] = []

        var wasCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        func wait(cooperative: Bool) async throws {
            if cooperative {
                try await withTaskCancellationHandler { try await park(honoringCancellation: true) } onCancel: { cancel() }
            } else {
                try await park(honoringCancellation: false)
            }
        }

        func release() {
            lock.lock()
            released = true
            let parked = waiters
            waiters = []
            lock.unlock()
            parked.forEach { $0.resume() }
        }

        private func park(honoringCancellation: Bool) async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                lock.lock()
                if released {
                    lock.unlock()
                    continuation.resume()
                } else if honoringCancellation && cancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append(continuation)
                    lock.unlock()
                }
            }
        }

        private func cancel() {
            lock.lock()
            cancelled = true
            let parked = waiters
            waiters = []
            lock.unlock()
            parked.forEach { $0.resume(throwing: CancellationError()) }
        }
    }

    private struct StillRestoring: LocalizedError {
        var errorDescription: String? { "macOS is still restoring the desktop wallpaper." }
    }

    private let clock = ScriptedClock()
    private let sleeper = ManualSleeper()
    private var lines: [String] = []
    /// The stages that started, in order.
    private var events: [String] = []

    private func makeSupervisor(mode: QuitMode = .interactive) -> QuitSupervisor {
        QuitSupervisor(
            mode: mode,
            now: { [clock] in clock.instant },
            sleep: { [sleeper] in try await sleeper.sleep($0) },
            log: { [unowned self] in self.lines.append($0) })
    }

    private func stage(_ name: String, takes amount: Duration = .zero) -> QuitSupervisor.Stage {
        .init(name: name) { [self] in
            events.append(name)
            clock.pass(amount)
        }
    }

    private func hanging(_ name: String, on latch: Latch, cooperative: Bool = true) -> QuitSupervisor.Stage {
        .init(name: name) { [self] in
            events.append(name)
            try await latch.wait(cooperative: cooperative)
        }
    }

    private func throwing(_ name: String, _ error: any Error) -> QuitSupervisor.Stage {
        .init(name: name) { [self] in
            events.append(name)
            throw error
        }
    }

    /// Waits, bounded, for something another task is about to make true.
    private func waitUntil(_ what: String, _ condition: () -> Bool) async {
        let limit = ContinuousClock.now.advanced(by: .seconds(10))
        while !condition() {
            if ContinuousClock.now >= limit {
                XCTFail("timed out waiting for \(what)")
                return
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    // MARK: Order and logging

    func testStagesRunInOrderAndEveryDurationIsLoggedOnce() async {
        let supervisor = makeSupervisor()

        let outcome = await supervisor.run(
            restoration: stage("restore", takes: .milliseconds(840)),
            teardown: [stage("imports", takes: .milliseconds(2)), stage("bridge", takes: .milliseconds(455))])

        XCTAssertEqual(outcome, .proceed(stalled: []))
        XCTAssertEqual(events, ["restore", "imports", "bridge"])
        XCTAssertEqual(supervisor.timings.stages.map(\.name), ["restore", "imports", "bridge"])
        XCTAssertEqual(supervisor.timings.stages.map(\.duration),
                       [.milliseconds(840), .milliseconds(2), .milliseconds(455)])
        XCTAssertEqual(lines.count, 4, "one line per stage and one for the whole quit")
        XCTAssertTrue(lines.last?.hasPrefix("quit: finished after 1297 ms") == true, lines.last ?? "")
    }

    func testAQuitWithNoTeardownStagesStillFinishes() async {
        let outcome = await makeSupervisor().run(restoration: stage("restore"), teardown: [])

        XCTAssertEqual(outcome, .proceed(stalled: []))
    }

    // MARK: Restoration

    func testARestorationThatThrowsCancelsTheQuitAndNothingAfterItRuns() async {
        let supervisor = makeSupervisor()

        let outcome = await supervisor.run(
            restoration: throwing("restore", StillRestoring()),
            teardown: [stage("imports"), stage("bridge")])

        XCTAssertEqual(outcome, .cancel(.restorationFailed("macOS is still restoring the desktop wallpaper.")))
        XCTAssertEqual(events, ["restore"], "teardown is not started for a quit that was refused")
        XCTAssertEqual(supervisor.timings.stages, [.init(name: "restore", duration: .zero, failed: true)])
        XCTAssertTrue(lines.last?.hasPrefix("quit: cancelled") == true, lines.last ?? "")
    }

    func testARestorationThatNeverReturnsCancelsTheQuitOnceItsTimeIsUp() async {
        let supervisor = makeSupervisor()
        let latch = Latch()
        let run = Task {
            await supervisor.run(restoration: hanging("restore", on: latch), teardown: [stage("imports")])
        }

        await waitUntil("the restoration budget to start counting") { sleeper.isPending(.seconds(20)) }
        sleeper.fire(.seconds(20))
        let outcome = await run.value

        XCTAssertEqual(outcome, .cancel(.restorationTimedOut))
        XCTAssertEqual(events, ["restore"], "teardown is not started for a quit that was refused")
        XCTAssertEqual(supervisor.timings.stages.map(\.stalled), [true])
        await waitUntil("the stage to be told to stop") { latch.wasCancelled }
    }

    func testARestorationThatIgnoresCancellationCannotChangeTheOutcomeWhenItFinishesLate() async {
        let supervisor = makeSupervisor()
        let latch = Latch()
        let run = Task {
            await supervisor.run(restoration: hanging("restore", on: latch, cooperative: false), teardown: [])
        }
        await waitUntil("the restoration budget to start counting") { sleeper.isPending(.seconds(20)) }
        sleeper.fire(.seconds(20))
        let outcome = await run.value
        let linesAtTheDeadline = lines

        latch.release()
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(outcome, .cancel(.restorationTimedOut))
        XCTAssertEqual(lines, linesAtTheDeadline, "the late finish is not logged as a second result")
        XCTAssertEqual(supervisor.timings.stages.count, 1)
    }

    // MARK: Teardown

    func testAHangingTeardownStageIsNamedAndTheStagesAfterItStillRun() async {
        let supervisor = makeSupervisor()
        let latch = Latch()
        let run = Task {
            await supervisor.run(
                restoration: stage("restore"),
                teardown: [stage("imports", takes: .seconds(1)), hanging("steamcmd", on: latch),
                           stage("workshop"), stage("bridge")])
        }

        await waitUntil("steamcmd to be waited for") { sleeper.isPending(.seconds(9)) }
        sleeper.fire(.seconds(9))
        let outcome = await run.value

        XCTAssertEqual(outcome, .proceed(stalled: ["steamcmd"]))
        XCTAssertEqual(events, ["restore", "imports", "steamcmd", "workshop", "bridge"])
        XCTAssertEqual(supervisor.timings.stages.map(\.stalled), [false, false, true, false, false])
        XCTAssertTrue(lines.last?.hasPrefix("quit: finished without steamcmd") == true, lines.last ?? "")
        await waitUntil("the stage to be told to stop") { latch.wasCancelled }
    }

    func testTeardownStagesShareOneBudgetAndTheLastKeepsItsFloor() async {
        let supervisor = makeSupervisor()
        let steamcmd = Latch(), bridge = Latch()
        let run = Task {
            await supervisor.run(
                restoration: stage("restore"),
                teardown: [stage("imports", takes: .seconds(4)), hanging("steamcmd", on: steamcmd),
                           stage("workshop"), hanging("bridge", on: bridge)])
        }

        // 10 s for all, 4 s used by the first stage.
        await waitUntil("steamcmd to be given what is left of the budget") { sleeper.isPending(.seconds(6)) }
        clock.pass(.seconds(6))
        sleeper.fire(.seconds(6))
        // The budget is spent. The renderer's shutdown still gets its floor.
        await waitUntil("the last stage to be given its floor") { sleeper.isPending(.seconds(2)) }
        sleeper.fire(.seconds(2))
        let outcome = await run.value

        XCTAssertEqual(outcome, .proceed(stalled: ["steamcmd", "workshop", "bridge"]))
        XCTAssertTrue(events.contains("workshop"), "a stage with no time left is still started, so it can stop its children")
    }

    func testATeardownStageThatThrowsIsLoggedAndTheQuitGoesOn() async {
        let supervisor = makeSupervisor()

        let outcome = await supervisor.run(
            restoration: stage("restore"),
            teardown: [throwing("bridge", StillRestoring()), stage("last")])

        XCTAssertEqual(outcome, .proceed(stalled: []), "a failed stage is not a stalled one")
        XCTAssertEqual(events, ["restore", "bridge", "last"])
        XCTAssertEqual(supervisor.timings.stages.map(\.failed), [false, true, false])
        XCTAssertTrue(lines.contains { $0.contains("bridge") && $0.contains("macOS is still restoring") },
                      "the log says why: \(lines)")
    }

    // MARK: Power off

    func testAPowerOffQuitGoesOnWhenRestorationFailsInsteadOfRefusingTheLogout() async {
        let supervisor = makeSupervisor(mode: .powerOff)

        let outcome = await supervisor.run(
            restoration: throwing("restore", StillRestoring()),
            teardown: [stage("imports"), stage("bridge")])

        XCTAssertEqual(outcome, .proceedUnrestored(
            .restorationFailed("macOS is still restoring the desktop wallpaper."), stalled: []))
        XCTAssertEqual(events, ["restore", "imports", "bridge"], "the teardown still runs, so the renderer closes its journal")
        XCTAssertTrue(lines.contains { $0.hasPrefix("quit: power off; desktop restoration unfinished") && $0.contains("still restoring") },
                      "the log says what was left to the journal: \(lines)")
        XCTAssertTrue(lines.last?.hasPrefix("quit: finished without restore") == true, lines.last ?? "")
    }

    func testAPowerOffQuitGoesOnWhenRestorationNeverReturnsAfterItsShortBudget() async {
        let supervisor = makeSupervisor(mode: .powerOff)
        let latch = Latch()
        let run = Task {
            await supervisor.run(restoration: hanging("restore", on: latch), teardown: [stage("imports")])
        }

        // The interactive budget is 20 s; a logout is not given that.
        await waitUntil("the restoration budget to start counting") { sleeper.isPending(.seconds(3)) }
        XCTAssertFalse(sleeper.isPending(.seconds(20)))
        sleeper.fire(.seconds(3))
        let outcome = await run.value

        XCTAssertEqual(outcome, .proceedUnrestored(.restorationTimedOut, stalled: []))
        XCTAssertEqual(events, ["restore", "imports"])
        XCTAssertEqual(supervisor.timings.stages.map(\.stalled), [true, false])
        XCTAssertTrue(lines.contains { $0.hasPrefix("quit: power off; desktop restoration unfinished") && $0.contains("3000 ms") },
                      "\(lines)")
        await waitUntil("the restoration to be told to stop, so the journal keeps what it did not finish") { latch.wasCancelled }
    }

    func testAPowerOffQuitThatRestoredTheDesktopIsAnOrdinaryProceed() async {
        let outcome = await makeSupervisor(mode: .powerOff).run(
            restoration: stage("restore"), teardown: [stage("bridge")])

        XCTAssertEqual(outcome, .proceed(stalled: []))
        XCTAssertFalse(lines.contains { $0.contains("power off") })
    }

    func testAPowerOffQuitHasLessTeardownTimeAndTheRendererKeepsItsFloor() async {
        let supervisor = makeSupervisor(mode: .powerOff)
        let steamcmd = Latch(), bridge = Latch()
        let run = Task {
            await supervisor.run(
                restoration: stage("restore"),
                teardown: [stage("imports", takes: .seconds(1)), hanging("steamcmd", on: steamcmd), hanging("bridge", on: bridge)])
        }

        // 1.5 s for all, 1 s used by the first stage.
        await waitUntil("steamcmd to be given what is left of the budget") { sleeper.isPending(.milliseconds(500)) }
        clock.pass(.milliseconds(500))
        sleeper.fire(.milliseconds(500))
        // The budget is spent. The renderer's shutdown still gets a second, not the two
        // an interactive quit would give it.
        await waitUntil("the last stage to be given its floor") { sleeper.isPending(.seconds(1)) }
        XCTAssertFalse(sleeper.isPending(.seconds(2)))
        sleeper.fire(.seconds(1))
        let outcome = await run.value

        XCTAssertEqual(outcome, .proceed(stalled: ["steamcmd", "bridge"]))
    }

    func testTheSameRestorationFailureStillRefusesAnInteractiveQuit() async {
        let outcome = await makeSupervisor(mode: .interactive).run(
            restoration: throwing("restore", StillRestoring()), teardown: [stage("bridge")])

        XCTAssertEqual(outcome, .cancel(.restorationFailed("macOS is still restoring the desktop wallpaper.")))
        XCTAssertEqual(events, ["restore"])
    }

    func testAPowerOffQuitIsGivenLessTimeInEveryPart() {
        let interactive = QuitMode.interactive.budgets, powerOff = QuitMode.powerOff.budgets

        XCTAssertLessThan(powerOff.restoration, interactive.restoration)
        XCTAssertLessThan(powerOff.teardown, interactive.teardown)
        XCTAssertLessThan(powerOff.exitFuse, interactive.exitFuse)
        XCTAssertLessThanOrEqual(powerOff.lastStageFloor, interactive.lastStageFloor)
        for budgets in [interactive, powerOff] {
            XCTAssertLessThanOrEqual(budgets.stalledExitFuse, budgets.exitFuse,
                                     "a stage left running must not make the exit slower")
        }
    }

    func testTheLongestQuitIsEveryPartAtItsLimit() {
        let budgets = QuitSupervisor.Budgets(
            restoration: .seconds(20), teardown: .seconds(10), exitFuse: .seconds(5),
            stalledExitFuse: .seconds(1), lastStageFloor: .seconds(2))

        XCTAssertEqual(budgets.longestQuit, .seconds(37),
                       "restoration, the teardown, the last stage's floor and the exit fuse")
        XCTAssertGreaterThan(QuitMode.interactive.budgets.longestQuit, QuitMode.powerOff.budgets.longestQuit)
    }

    // MARK: Exit fuse

    func testAStageLeftRunningSelectsTheShorterExitFuse() {
        let budgets = QuitSupervisor.Budgets(
            restoration: .seconds(1), teardown: .seconds(1), exitFuse: .seconds(7),
            stalledExitFuse: .seconds(3), lastStageFloor: .seconds(1))

        XCTAssertEqual(budgets.exitFuse(stalled: []), .seconds(7))
        XCTAssertEqual(budgets.exitFuse(stalled: ["bridge"]), .seconds(3))
        XCTAssertEqual(budgets.exitFuse(stalled: ["steamcmd", "bridge"]), .seconds(3))
    }

    func testTheExitFuseFiresOffTheMainThread() async {
        let fired = expectation(description: "the fuse fired")
        let onMainThread = FuseThreadFlag()
        ExitFuse.arm(after: .milliseconds(20)) {
            if Thread.isMainThread { onMainThread.set() }
            fired.fulfill()
        }

        await fulfillment(of: [fired], timeout: 10)

        XCTAssertFalse(onMainThread.isSet, "a hung main thread must not be able to stop it")
    }

    // MARK: The real timer

    func testTheDefaultTimerEndsAStageThatNeverReturns() async {
        let budgets = QuitSupervisor.Budgets(
            restoration: .milliseconds(30), teardown: .milliseconds(30), exitFuse: .seconds(5),
            stalledExitFuse: .seconds(1), lastStageFloor: .milliseconds(30))
        let supervisor = QuitSupervisor(budgets: budgets, log: { [unowned self] in self.lines.append($0) })
        let restoration = Latch(), teardown = Latch()
        let done = expectation(description: "both quits returned")
        let outcomes = Collected()
        Task {
            outcomes.items.append(await supervisor.run(
                restoration: hanging("restore", on: restoration, cooperative: false), teardown: []))
            outcomes.items.append(await supervisor.run(
                restoration: stage("restore"), teardown: [hanging("bridge", on: teardown, cooperative: false)]))
            done.fulfill()
        }

        // Only a hang detector: the outcomes do not depend on how long this takes.
        await fulfillment(of: [done], timeout: 30)

        XCTAssertEqual(outcomes.items, [.cancel(.restorationTimedOut), .proceed(stalled: ["bridge"])])
        restoration.release()
        teardown.release()
    }
}

/// The answer to a request to quit is a pure function of the quit that is running, so a
/// logout arriving mid-quit is exercised without one.
final class QuitRequestAnswerTests: XCTestCase {
    private func answer(finished: Bool = false, running: QuitMode?, request: QuitMode) -> QuitRequestAnswer {
        QuitRequestAnswer.answer(finished: finished, running: running, request: request)
    }

    func testAnIdleAppStartsAQuitWhoeverAsks() {
        XCTAssertEqual(answer(running: nil, request: .interactive), .start)
        XCTAssertEqual(answer(running: nil, request: .powerOff), .start)
    }

    func testAFinishedQuitLetsTheProcessGo() {
        for running in [nil, QuitMode.interactive, .powerOff] {
            for request in [QuitMode.interactive, .powerOff] {
                XCTAssertEqual(answer(finished: true, running: running, request: request), .terminateNow)
            }
        }
    }

    func testASecondUserQuitIsRefusedWhileOneRuns() {
        XCTAssertEqual(answer(running: .interactive, request: .interactive), .refuse)
    }

    func testALogoutDuringAUsersQuitWaitsInsteadOfBeingRefused() {
        XCTAssertEqual(answer(running: .interactive, request: .powerOff), .wait,
                       "refusing it would cancel the logout")
    }

    func testAnyRequestDuringAPowerOffQuitWaitsForIt() {
        XCTAssertEqual(answer(running: .powerOff, request: .powerOff), .wait)
        XCTAssertEqual(answer(running: .powerOff, request: .interactive), .wait,
                       "the process is leaving either way, and refusing would cancel the system's request")
    }
}

final class FirstResultTests: XCTestCase {
    func testOnlyTheFirstOfferIsKeptAndTheWaiterIsResumedOnce() async {
        let gate = FirstResult<String>()
        let waiting = Task { await gate.wait() }

        XCTAssertTrue(gate.offer("deadline"))
        XCTAssertFalse(gate.offer("finished"), "a stage that finishes after its deadline is turned away")
        let value = await waiting.value

        XCTAssertEqual(value, "deadline")
        XCTAssertEqual(gate.resumeCount, 1)
    }

    func testAnOfferThatComesBeforeAnyoneWaitsIsStillDelivered() async {
        let gate = FirstResult<Int>()
        gate.offer(1)
        gate.offer(2)

        let value = await gate.wait()

        XCTAssertEqual(value, 1)
        XCTAssertEqual(gate.resumeCount, 1)
    }
}

@MainActor
private final class Collected {
    var items: [QuitSupervisor.Outcome] = []
}

private final class FuseThreadFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}
