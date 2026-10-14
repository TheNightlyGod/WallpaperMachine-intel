import Darwin
import XCTest

@testable import WallpaperMachine

/// Real signals, but SIGUSR1 and SIGUSR2 instead of SIGTERM and SIGHUP, so a relay that
/// failed to install would cost one test and not the test host. `forceDefault` is always
/// injected: nothing here ends the process.
final class TerminationSignalRelayTests: XCTestCase {
    /// What the relay called, in order, and a way to wait for a call to arrive. The timeout
    /// of a wait only detects a call that never comes.
    private final class Calls: @unchecked Sendable {
        private let condition = NSCondition()
        private var terminated: [Int32] = []
        private var forced: [Int32] = []

        var terminates: [Int32] { read { terminated } }
        var forces: [Int32] { read { forced } }

        private func read<T>(_ value: () -> T) -> T {
            condition.lock()
            defer { condition.unlock() }
            return value()
        }

        func terminate(_ signal: Int32) {
            condition.lock()
            terminated.append(signal)
            condition.broadcast()
            condition.unlock()
        }

        func force(_ signal: Int32) {
            condition.lock()
            forced.append(signal)
            condition.broadcast()
            condition.unlock()
        }

        func waitForTerminates(_ count: Int, timeout: TimeInterval = 10) -> Bool {
            wait(timeout) { terminated.count >= count }
        }

        func waitForForces(_ count: Int, timeout: TimeInterval = 10) -> Bool {
            wait(timeout) { forced.count >= count }
        }

        private func wait(_ timeout: TimeInterval, until reached: () -> Bool) -> Bool {
            let limit = Date(timeIntervalSinceNow: timeout)
            condition.lock()
            defer { condition.unlock() }
            while !reached() {
                if !condition.wait(until: limit) { return reached() }
            }
            return true
        }
    }

    private let defaultAction = 0
    private let ignored = 1
    private var restoreAtTearDown: [(Int32, sigaction)] = []

    override func tearDown() {
        // Newest first, so a signal preserved twice ends up as it was before the test.
        for (number, var action) in restoreAtTearDown.reversed() { sigaction(number, &action, nil) }
        restoreAtTearDown = []
        super.tearDown()
    }

    /// Remembers a signal's disposition and puts it back after the test, whatever happens.
    private func preserveDisposition(of number: Int32) {
        var current = sigaction()
        sigaction(number, nil, &current)
        restoreAtTearDown.append((number, current))
    }

    private func disposition(of number: Int32) -> Int {
        var current = sigaction()
        sigaction(number, nil, &current)
        return unsafeBitCast(current.__sigaction_u.__sa_handler, to: Int.self)
    }

    /// Starts a relay for `signals` that is stopped when the test ends. Fails the test, and
    /// returns `nil`, if a handler is not in place, so the caller never raises into the host.
    private func startedRelay(
        signals: [Int32] = [SIGUSR1], calls: Calls, forceAfter: Duration = .seconds(3600)
    ) throws -> TerminationSignalRelay? {
        for number in signals { preserveDisposition(of: number) }
        let relay = TerminationSignalRelay(
            signals: signals, terminate: { calls.terminate($0) }, forceDefault: { calls.force($0) },
            forceAfter: forceAfter,
            // At the test thread's own priority, which waits for the calls: no priority inversion.
            queue: DispatchQueue(label: "relay-test", qos: .userInteractive))
        try relay.start()
        addTeardownBlock { relay.stop() }
        for number in signals where disposition(of: number) == defaultAction || disposition(of: number) == ignored {
            XCTFail("no handler was installed for signal \(number)")
            return nil
        }
        return relay
    }

    // MARK: A signal becomes a quit

    func testASignalAsksForOneQuitAndTheProcessSurvives() throws {
        let calls = Calls()
        guard try startedRelay(calls: calls) != nil else { return }

        raise(SIGUSR1)

        XCTAssertTrue(calls.waitForTerminates(1))
        XCTAssertEqual(calls.terminates, [SIGUSR1])
        XCTAssertEqual(calls.forces, [], "one signal is a request, not an order to end at once")
    }

    func testASecondSignalForcesTheDefaultActionAndDoesNotAskAgain() throws {
        let calls = Calls()
        guard try startedRelay(calls: calls) != nil else { return }

        raise(SIGUSR1)
        XCTAssertTrue(calls.waitForTerminates(1))
        raise(SIGUSR1)

        XCTAssertTrue(calls.waitForForces(1))
        XCTAssertEqual(calls.terminates, [SIGUSR1])
        XCTAssertEqual(calls.forces, [SIGUSR1])
    }

    func testSignalsThatArriveBackToBackAreOneRequestAndOneForce() throws {
        let calls = Calls()
        guard try startedRelay(calls: calls) != nil else { return }

        raise(SIGUSR1)
        raise(SIGUSR1)

        XCTAssertTrue(calls.waitForTerminates(1))
        XCTAssertTrue(calls.waitForForces(1))
        XCTAssertEqual(calls.terminates, [SIGUSR1])
        XCTAssertEqual(calls.forces, [SIGUSR1])
    }

    func testEachRelayedSignalIsDeliveredWithItsOwnNumber() throws {
        let calls = Calls()
        guard try startedRelay(signals: [SIGUSR1, SIGUSR2], calls: calls) != nil else { return }

        raise(SIGUSR2)

        XCTAssertTrue(calls.waitForTerminates(1))
        XCTAssertEqual(calls.terminates, [SIGUSR2])
    }

    func testTheDeadlineForcesTheDefaultActionWhenNothingEndsTheApp() throws {
        let calls = Calls()
        guard try startedRelay(calls: calls, forceAfter: .milliseconds(50)) != nil else { return }

        raise(SIGUSR1)

        XCTAssertTrue(calls.waitForForces(1))
        XCTAssertEqual(calls.terminates, [SIGUSR1])
        XCTAssertEqual(calls.forces, [SIGUSR1], "the first signal's number is the one forced")
    }

    func testAfterAResetTheNextSignalAsksForAQuitAgain() throws {
        let calls = Calls()
        guard let relay = try startedRelay(calls: calls) else { return }

        raise(SIGUSR1)
        XCTAssertTrue(calls.waitForTerminates(1))
        relay.reset()
        raise(SIGUSR1)

        XCTAssertTrue(calls.waitForTerminates(2))
        XCTAssertEqual(calls.terminates, [SIGUSR1, SIGUSR1], "a refused quit is not a first signal that stands")
        XCTAssertEqual(calls.forces, [])
    }

    // MARK: Dispositions

    func testStopPutsBackTheDispositionTheSignalHad() throws {
        let calls = Calls()
        preserveDisposition(of: SIGUSR2)
        // Something else's handler: it must come back exactly, not become the default.
        let theirs: @convention(c) (Int32) -> Void = { _ in }
        var action = sigaction()
        action.__sigaction_u.__sa_handler = theirs
        sigemptyset(&action.sa_mask)
        sigaction(SIGUSR2, &action, nil)
        let before = disposition(of: SIGUSR2)

        guard let relay = try startedRelay(signals: [SIGUSR2], calls: calls) else { return }
        XCTAssertNotEqual(disposition(of: SIGUSR2), before, "the relay's own handler is in place")
        relay.stop()

        XCTAssertEqual(disposition(of: SIGUSR2), before)
        XCTAssertNil(relay.descriptors)
    }

    func testASignalThatWasIgnoredStaysIgnored() throws {
        preserveDisposition(of: SIGUSR2)
        signal(SIGUSR2, SIG_IGN)
        let relay = TerminationSignalRelay(signals: [SIGUSR2], terminate: { _ in }, forceDefault: { _ in })

        try relay.start()
        defer { relay.stop() }

        XCTAssertEqual(disposition(of: SIGUSR2), ignored,
                       "nohup ignores SIGHUP on purpose; a relay must not undo it")
    }

    func testAChildStartedWhileTheRelayRunsGetsTheDefaultDisposition() throws {
        let calls = Calls()
        // The probe first: perl does report an ignore it inherited.
        preserveDisposition(of: SIGUSR2)
        signal(SIGUSR2, SIG_IGN)
        XCTAssertEqual(try ChildSignalProbe.perlDispositions(of: ["USR2"]), "IGNORE", "the probe can tell an ignore from a default")
        signal(SIGUSR2, SIG_DFL)

        guard try startedRelay(signals: [SIGUSR1, SIGUSR2], calls: calls) != nil else { return }

        XCTAssertEqual(try ChildSignalProbe.perlDispositions(of: ["USR1", "USR2"]), "DEFAULT,DEFAULT",
                       "a caught handler resets across exec; an ignored signal would be inherited")
    }

    func testBothPipeEndsCloseOnExecAndNeverBlock() throws {
        let calls = Calls()
        guard let relay = try startedRelay(calls: calls) else { return }
        let ends = try XCTUnwrap(relay.descriptors)

        for end in [ends.read, ends.write] {
            XCTAssertNotEqual(fcntl(end, F_GETFD) & FD_CLOEXEC, 0, "descriptor \(end) must not reach a child")
            XCTAssertNotEqual(fcntl(end, F_GETFL) & O_NONBLOCK, 0, "descriptor \(end) must not block a handler")
        }
    }

    // MARK: Delivery to the main run loop

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var raised: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func raise() { lock.lock(); value = true; lock.unlock() }
    }

    /// The quit a signal asks for must start while an alert is up or a menu is open, and those run
    /// the main loop in a mode of their own. Spun here in the event-tracking mode (an open menu's)
    /// and the modal-panel mode (an alert's), which are common modes like the default one.
    /// `RunLoop.perform` leaves the block waiting in the event-tracking mode, which is the bug this
    /// pins. The deadline only ends a wait that nothing will answer.
    func testAQuitRequestedByASignalRunsInTheDefaultModeAndInEveryOtherCommonMode() {
        XCTAssertTrue(Thread.isMainThread, "the test spins the main run loop, so it has to run on it")
        let modes = [RunLoop.Mode.default, .eventTracking, RunLoop.Mode(rawValue: "NSModalPanelRunLoopMode")]
        for mode in modes {
            let ran = Flag()
            // The relay's queue is not the main thread, so deliver from another one.
            DispatchQueue.global().async {
                TerminationSignalRelay.performOnMainRunLoopInAnyMode { ran.raise() }
            }
            let deadline = Date().addingTimeInterval(10)
            while !ran.raised, Date() < deadline {
                _ = RunLoop.main.run(mode: mode, before: deadline)
            }
            XCTAssertTrue(ran.raised, "the request was not delivered in \(mode.rawValue)")
        }
    }

    // MARK: Names

    func testTheTerminationSignalsAreNamedForTheLog() {
        XCTAssertEqual(TerminationSignalRelay.name(of: SIGTERM), "SIGTERM")
        XCTAssertEqual(TerminationSignalRelay.name(of: SIGHUP), "SIGHUP")
        XCTAssertEqual(TerminationSignalRelay.name(of: 99), "signal 99")
    }
}
