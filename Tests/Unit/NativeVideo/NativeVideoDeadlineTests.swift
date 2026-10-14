import XCTest

@testable import WallpaperMachine

/// The race that lets the host stop waiting for a metadata read that never
/// returns. What matters is who wins and that the caller is always released:
/// the operation may be blocked where nothing can cancel it.
@MainActor
final class NativeVideoDeadlineTests: XCTestCase {
    private let sleeper = ManualSleeper()
    private let gate = AsyncGate()

    override func tearDown() async throws {
        // A test that left the operation suspended must not leave its task
        // behind.
        gate.open()
        sleeper.fireAll()
        try await super.tearDown()
    }

    func testAnOperationThatFinishesFirstYieldsItsValueAndCancelsTheTimer() async {
        let gate = self.gate
        let task = Task {
            await NativeVideoDeadline.race(.seconds(5), sleep: self.sleeper.closure) {
                await gate.wait()
                return 42
            }
        }
        await sleeper.waitUntilPending()
        XCTAssertEqual(sleeper.requested, [.seconds(5)], "the timer is armed with the limit asked for")

        gate.open()
        let outcome = await task.value

        XCTAssertEqual(outcome, .value(42))
        XCTAssertEqual(sleeper.cancelledCount, 1, "the timer must not outlive the race")
        XCTAssertEqual(sleeper.pendingCount, 0)
    }

    func testATimerThatFiresFirstReleasesTheCallerWhileTheOperationStaysSuspended() async {
        let gate = self.gate
        let returned = AsyncGate()
        var cancelledWhenItReturned: Bool?
        let task = Task {
            await NativeVideoDeadline.race(.seconds(5), sleep: self.sleeper.closure) {
                await gate.wait()
                cancelledWhenItReturned = Task.isCancelled
                returned.open()
                return 1
            }
        }
        await sleeper.waitUntilPending()
        await gate.waitUntilWaiting()

        sleeper.fireNext()
        let outcome = await task.value

        XCTAssertEqual(outcome, .timedOut)
        XCTAssertNil(
            cancelledWhenItReturned, "the caller was released without the operation returning")
        XCTAssertEqual(gate.waitingCount, 1, "and it is still suspended, not torn down")

        // Released late, the operation returns a value nobody is waiting for.
        // That must not crash, and it must have been told to stop.
        gate.open()
        await returned.wait()
        XCTAssertEqual(
            cancelledWhenItReturned, true,
            "a cooperative operation is cancelled when its caller gives up on it")
    }

    func testCancellingTheCallerReleasesItAndStopsTheTimer() async {
        let gate = self.gate
        let task = Task {
            await NativeVideoDeadline.race(.seconds(5), sleep: self.sleeper.closure) {
                await gate.wait()
                return 1
            }
        }
        await sleeper.waitUntilPending()

        task.cancel()
        let outcome = await task.value

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(sleeper.cancelledCount, 1)
        XCTAssertEqual(sleeper.pendingCount, 0)
    }

    func testACallerCancelledBeforeItStartsNeverRunsTheOperation() async {
        var started = false
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return await NativeVideoDeadline.race(.seconds(5), sleep: self.sleeper.closure) {
                started = true
                return 1
            }
        }

        task.cancel()
        let outcome = await task.value

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertFalse(started)
        XCTAssertTrue(sleeper.requested.isEmpty, "and arms no timer")
    }
}
