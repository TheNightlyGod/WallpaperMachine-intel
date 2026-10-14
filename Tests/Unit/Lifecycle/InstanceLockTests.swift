import Darwin
import XCTest

@testable import WallpaperMachine

/// One copy per library: the claim, who holds it, how long a second launch waits and when it
/// gives up. Every lock lives in a temporary folder, so the installed app's library is never
/// involved and nothing here depends on the clock.
final class InstanceLockTests: XCTestCase {
    private var root: URL!
    private var file: URL { root.appendingPathComponent(InstanceLock.fileName) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mwe-instance-lock-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func acquire(
        _ patience: InstanceLock.Patience = .init(running: 0, quitting: 0, poll: 0.125),
        isAlive: @escaping (pid_t) -> Bool = InstanceLock.processExists,
        sleep: @escaping (TimeInterval) -> Void = { _ in }
    ) -> InstanceLock.Outcome {
        InstanceLock.acquire(at: file, patience: patience, isAlive: isAlive, sleep: sleep)
    }

    private func expectAcquired(_ outcome: InstanceLock.Outcome, file: StaticString = #filePath, line: UInt = #line) -> InstanceLock? {
        guard case let .acquired(lock) = outcome else {
            XCTFail("expected to acquire the lock, got \(outcome)", file: file, line: line)
            return nil
        }
        return lock
    }

    private func spawnSleeper() throws -> pid_t {
        var pid: pid_t = 0
        var arguments: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sleep"), strdup("30"), nil]
        defer { arguments.forEach { free($0) } }
        var environment: [UnsafeMutablePointer<CChar>?] = [nil]
        // Plain posix_spawn keeps every descriptor that is not close-on-exec, which is what a
        // careless child would inherit.
        XCTAssertEqual(posix_spawn(&pid, "/bin/sleep", nil, nil, &arguments, &environment), 0)
        return pid
    }

    private func reap(_ pid: pid_t) {
        kill(pid, SIGKILL)
        var status: Int32 = 0
        waitpid(pid, &status, 0)
    }

    func testFirstCopyTakesTheLibraryAndRecordsItself() throws {
        let lock = try XCTUnwrap(expectAcquired(acquire()))
        XCTAssertEqual(InstanceLock.readHolder(at: file), .init(pid: getpid(), phase: .running))
        lock.release()
    }

    func testSecondCopyIsTurnedAwayAfterTheGrace() throws {
        let first = try XCTUnwrap(expectAcquired(acquire()))
        defer { first.release() }
        var slept: TimeInterval = 0
        let outcome = acquire(.init(running: 0.375, quitting: 5, poll: 0.125), sleep: { slept += $0 })
        guard case let .heldBy(holder) = outcome else { return XCTFail("a running holder must keep the library: \(outcome)") }
        XCTAssertEqual(holder, .init(pid: getpid(), phase: .running))
        XCTAssertEqual(slept, 0.375, "A running holder is given only the short grace")
    }

    func testLibraryIsFreeAgainOnceTheHolderReleasesOrIsGone() throws {
        let first = try XCTUnwrap(expectAcquired(acquire()))
        first.release()
        let second = try XCTUnwrap(expectAcquired(acquire()))
        second.release()

        var abandoned: InstanceLock? = try XCTUnwrap(expectAcquired(acquire()))
        XCTAssertNotNil(abandoned)
        abandoned = nil
        let third = try XCTUnwrap(expectAcquired(acquire()), "Dropping the holder gives the library up")
        third.release()
    }

    func testRunningHolderThatLetsGoDuringTheGraceHandsTheLibraryOver() throws {
        // A quit-and-reopen, or an updater relaunch whose old process is still tearing down.
        let first = try XCTUnwrap(expectAcquired(acquire()))
        var sleeps = 0
        let outcome = acquire(.init(running: 2, quitting: 25, poll: 0.125), sleep: { _ in
            sleeps += 1
            if sleeps == 5 { first.release() }
        })
        let second = try XCTUnwrap(expectAcquired(outcome))
        XCTAssertEqual(sleeps, 5)
        second.release()
    }

    func testQuittingHolderIsWaitedForBeyondTheGrace() throws {
        let first = try XCTUnwrap(expectAcquired(acquire()))
        first.setPhase(.quitting)
        var sleeps = 0
        let outcome = acquire(.init(running: 0.25, quitting: 25, poll: 0.125), sleep: { _ in
            sleeps += 1
            if sleeps == 100 { first.release() }
        })
        let second = try XCTUnwrap(expectAcquired(outcome))
        XCTAssertEqual(sleeps, 100, "Twelve virtual seconds is far past the grace of a running holder")
        second.release()
    }

    func testASecondLaunchOutwaitsTheLongestQuitItsHolderMayTake() throws {
        // A slow but successful quit that keeps to its budgets releases the library at the very
        // end of them, and the relaunch the user made right after choosing Quit must still win it.
        let longest = QuitMode.interactive.budgets.longestQuit.timeInterval
        let first = try XCTUnwrap(expectAcquired(acquire()))
        first.setPhase(.quitting)
        var slept: TimeInterval = 0
        let outcome = acquire(.standard, sleep: {
            slept += $0
            if slept >= longest { first.release() }
        })
        let second = try XCTUnwrap(expectAcquired(outcome), "gave up on a holder still within its quit budgets")
        XCTAssertGreaterThanOrEqual(slept, longest)
        second.release()
    }

    func testTheStandardPatienceForAQuittingHolderCoversTheLongestQuitWithAMargin() {
        let longest = QuitMode.interactive.budgets.longestQuit.timeInterval
        XCTAssertGreaterThan(InstanceLock.Patience.standard.quitting, longest)
        XCTAssertEqual(InstanceLock.Patience.standard.quitting, longest + InstanceLock.Patience.quitMargin)
        XCTAssertGreaterThan(InstanceLock.Patience.standard.quitting, InstanceLock.Patience.standard.running)
    }

    func testQuittingHolderThatNeverFinishesIsEventuallyHandedOverTo() throws {
        let first = try XCTUnwrap(expectAcquired(acquire()))
        defer { first.release() }
        first.setPhase(.quitting)
        var slept: TimeInterval = 0
        let outcome = acquire(.init(running: 0.25, quitting: 3, poll: 0.125), sleep: { slept += $0 })
        guard case let .heldBy(holder) = outcome else { return XCTFail("expected a hand-over: \(outcome)") }
        XCTAssertEqual(holder.phase, .quitting)
        XCTAssertEqual(slept, 3)
    }

    func testClaimIsNeverLeftBehindForAnOrphanedChild() throws {
        // The app spawns SteamCMD and helpers. If one outlives the app, a launch that finds the
        // library locked would be refused for as long as that child lives.
        let first = try XCTUnwrap(expectAcquired(acquire()))
        let child = try spawnSleeper()
        defer { reap(child) }
        first.release()
        let second = try XCTUnwrap(expectAcquired(acquire()), "The surviving child must not keep the library locked")
        second.release()
    }

    func testRecordTracksTheHolderThroughQuittingAndACancelledQuit() throws {
        let lock = try XCTUnwrap(expectAcquired(acquire()))
        defer { lock.release() }
        lock.setPhase(.quitting)
        XCTAssertEqual(InstanceLock.readHolder(at: file), .init(pid: getpid(), phase: .quitting))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "\(getpid()) quitting\n")
        lock.setPhase(.running)
        XCTAssertEqual(InstanceLock.readHolder(at: file), .init(pid: getpid(), phase: .running))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "\(getpid()) running\n",
                       "A shorter record must not leave the tail of the longer one behind")
    }

    func testLockHeldByAProcessThatIsGoneDoesNotBlockLaunch() throws {
        let first = try XCTUnwrap(expectAcquired(acquire()))
        defer { first.release() }
        // What a descriptor leaked into some other process looks like: the lock is held, but the
        // pid it names has exited.
        let gone = Process()
        gone.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try gone.run()
        gone.waitUntilExit()
        try "\(gone.processIdentifier) running\n".write(to: file, atomically: false, encoding: .utf8)

        var slept: TimeInterval = 0
        let outcome = acquire(.init(running: 2, quitting: 25, poll: 0.125), sleep: { slept += $0 })
        guard case let .proceedUnlocked(reason) = outcome else { return XCTFail("a stale lock must not refuse the launch: \(outcome)") }
        XCTAssertEqual(reason, .deadHolder(pid: gone.processIdentifier))
        XCTAssertEqual(slept, 0.125, "The dead holder is confirmed once, not waited out")
    }

    func testLockWithNoReadableRecordIsGivenTheGraceThenIgnored() throws {
        let first = try XCTUnwrap(expectAcquired(acquire()))
        defer { first.release() }
        try "not a record".write(to: file, atomically: false, encoding: .utf8)
        var slept: TimeInterval = 0
        let outcome = acquire(.init(running: 0.375, quitting: 25, poll: 0.125), sleep: { slept += $0 })
        guard case let .proceedUnlocked(reason) = outcome else { return XCTFail("expected to continue unlocked: \(outcome)") }
        XCTAssertEqual(reason, .unreadableHolder)
        XCTAssertEqual(slept, 0.375)
    }

    func testLockThatCannotBeCreatedDoesNotBlockLaunch() throws {
        // A directory where the lock file should be: nothing can be opened for writing there.
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        guard case let .proceedUnlocked(reason) = acquire() else { return XCTFail("an unusable lock must never block launch") }
        guard case .unusable = reason else { return XCTFail("unexpected reason \(reason)") }
    }

    func testDecisionTable() {
        let patience = InstanceLock.Patience(running: 2, quitting: 25, poll: 0.125)
        let running = InstanceLock.Holder(pid: 10, phase: .running)
        let quitting = InstanceLock.Holder(pid: 10, phase: .quitting)
        func decide(_ holder: InstanceLock.Holder?, alive: Bool = true, waited: TimeInterval = 0, acquired: Bool = false) -> InstanceDecision {
            InstanceDecision.decide(acquired: acquired, holder: holder, holderAlive: alive, waited: waited, patience: patience)
        }
        XCTAssertEqual(decide(nil, acquired: true), .proceed)
        XCTAssertEqual(decide(running, waited: 1.9), .wait)
        XCTAssertEqual(decide(running, waited: 2), .handOff)
        XCTAssertEqual(decide(quitting, waited: 10), .wait)
        XCTAssertEqual(decide(quitting, waited: 24.9), .wait)
        XCTAssertEqual(decide(quitting, waited: 25), .handOff)
        XCTAssertEqual(decide(running, alive: false, waited: 0), .wait, "A dead holder is confirmed on a second look")
        XCTAssertEqual(decide(running, alive: false, waited: 0.125), .proceedUnlocked)
        XCTAssertEqual(decide(quitting, alive: false, waited: 0.125), .proceedUnlocked)
        XCTAssertEqual(decide(nil, waited: 1.9), .wait)
        XCTAssertEqual(decide(nil, waited: 2), .proceedUnlocked)
    }

    func testHandOffRecognisesTheSameBundleAnotherCopyAndStrangers() throws {
        let fileManager = FileManager.default
        let real = root.appendingPathComponent("real/WallpaperMachine.app/Contents/MacOS", isDirectory: true)
        try fileManager.createDirectory(at: real, withIntermediateDirectories: true)
        let executable = real.appendingPathComponent("WallpaperMachine")
        try Data().write(to: executable)
        let alias = root.appendingPathComponent("alias")
        try fileManager.createSymbolicLink(at: alias, withDestinationURL: root.appendingPathComponent("real"))
        let viaAlias = alias.appendingPathComponent("WallpaperMachine.app/Contents/MacOS/WallpaperMachine")

        XCTAssertEqual(InstanceHandOff.action(holderExecutable: executable.path, ownExecutable: viaAlias.path), .reopenRunningCopy)
        XCTAssertEqual(
            InstanceHandOff.action(
                holderExecutable: "/Applications/WallpaperMachine.app/Contents/MacOS/WallpaperMachine",
                ownExecutable: executable.path),
            .warnAboutOtherCopy)
        XCTAssertEqual(
            InstanceHandOff.action(holderExecutable: "/usr/bin/perl", ownExecutable: executable.path),
            .proceedUnlocked, "A reused pid names some other program")
        XCTAssertEqual(
            InstanceHandOff.action(holderExecutable: "/tmp/WallpaperMachine", ownExecutable: executable.path),
            .proceedUnlocked, "A bare binary of the same name is not an app copy")
        XCTAssertEqual(InstanceHandOff.action(holderExecutable: nil, ownExecutable: executable.path), .proceedUnlocked)
        XCTAssertEqual(InstanceHandOff.action(holderExecutable: executable.path, ownExecutable: nil), .proceedUnlocked)
    }

    func testExecutablePathIsReadableForARunningProcessAndNotForAGoneOne() throws {
        let own = try XCTUnwrap(InstanceHandOff.executablePath(ofProcess: getpid()))
        XCTAssertEqual(URL(fileURLWithPath: own).resolvingSymlinksInPath().path,
                       try XCTUnwrap(Bundle.main.executableURL).resolvingSymlinksInPath().path)

        let gone = Process()
        gone.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try gone.run()
        gone.waitUntilExit()
        XCTAssertNil(InstanceHandOff.executablePath(ofProcess: gone.processIdentifier))
    }
}
