import Foundation

/// A clock that only moves when the test says so.
///
/// Code that waits for a limit takes its sleep as a closure; handing it
/// `sleeper.closure` lets a test fire the limit by hand (`fireNext()`), see
/// which limit was asked for (`requested`), and see that a timer which is no
/// longer needed was cancelled (`cancelledCount`). Nothing here waits in real
/// time, so a test that uses it cannot be made flaky by a loaded machine.
///
/// Cancellation resumes the waiter synchronously, on the cancelling thread, so
/// `cancelledCount` is already updated when `Task.cancel()` returns.
final class ManualSleeper: @unchecked Sendable {
    private let lock = NSLock()
    private var nextID = 0
    private var waiters: [(id: Int, continuation: CheckedContinuation<Void, Error>)] = []
    private var cancelledBeforeRegistering: Set<Int> = []
    private var watchers: [(pending: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var requestedDurations: [Duration] = []
    private var cancelled = 0

    /// Every duration asked for, in order, including sleeps already cancelled.
    var requested: [Duration] { lock.withLock { requestedDurations } }
    /// Sleeps currently waiting to be fired.
    var pendingCount: Int { lock.withLock { waiters.count } }
    /// Sleeps that ended because their task was cancelled.
    var cancelledCount: Int { lock.withLock { cancelled } }

    /// The closure to pass wherever code expects `Task.sleep`.
    var closure: @Sendable (Duration) async throws -> Void {
        { [self] duration in try await self.sleep(duration) }
    }

    func sleep(_ duration: Duration) async throws {
        let id = lock.withLock { () -> Int in
            nextID += 1
            requestedDurations.append(duration)
            return nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let result = lock.withLock { () -> (cancelled: Bool, ready: [CheckedContinuation<Void, Never>]) in
                    if cancelledBeforeRegistering.remove(id) != nil { return (true, []) }
                    waiters.append((id, continuation))
                    return (false, releaseSatisfiedWatchers())
                }
                if result.cancelled { continuation.resume(throwing: CancellationError()) }
                result.ready.forEach { $0.resume() }
            }
        } onCancel: {
            let waiter = lock.withLock { () -> CheckedContinuation<Void, Error>? in
                cancelled += 1
                guard let index = waiters.firstIndex(where: { $0.id == id }) else {
                    cancelledBeforeRegistering.insert(id)
                    return nil
                }
                return waiters.remove(at: index).continuation
            }
            waiter?.resume(throwing: CancellationError())
        }
    }

    /// Ends the oldest waiting sleep normally, as if its time had passed.
    /// Returns false when nothing is waiting.
    @discardableResult
    func fireNext() -> Bool {
        let waiter = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            waiters.isEmpty ? nil : waiters.removeFirst().continuation
        }
        waiter?.resume()
        return waiter != nil
    }

    func fireAll() {
        while fireNext() {}
    }

    /// Suspends until at least `count` sleeps are waiting, so a test can act
    /// on a timer that code under test has not started yet without guessing at
    /// scheduling.
    func waitUntilPending(_ count: Int = 1) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let ready = lock.withLock { () -> Bool in
                if waiters.count >= count { return true }
                watchers.append((count, continuation))
                return false
            }
            if ready { continuation.resume() }
        }
    }

    /// Called with the lock held.
    private func releaseSatisfiedWatchers() -> [CheckedContinuation<Void, Never>] {
        let satisfied = watchers.filter { $0.pending <= waiters.count }
        watchers.removeAll { $0.pending <= waiters.count }
        return satisfied.map(\.continuation)
    }
}

/// A one-shot gate: `wait()` suspends until `open()`, and stays open after.
///
/// Stands in for an operation that has to stay in flight for the length of a
/// test (a metadata read that never returns) and then be released, so no task
/// is left suspended when the test ends.
final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var watchers: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    /// How many callers are suspended in `wait()` right now.
    var waitingCount: Int { lock.withLock { waiters.count } }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let (proceed, ready) = lock.withLock {
                () -> (Bool, [CheckedContinuation<Void, Never>]) in
                if isOpen { return (true, []) }
                waiters.append(continuation)
                let satisfied = watchers.filter { $0.count <= waiters.count }
                watchers.removeAll { $0.count <= waiters.count }
                return (false, satisfied.map(\.continuation))
            }
            if proceed { continuation.resume() }
            ready.forEach { $0.resume() }
        }
    }

    func open() {
        let released = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            isOpen = true
            defer { waiters.removeAll() }
            return waiters
        }
        released.forEach { $0.resume() }
    }

    /// Suspends until `count` callers are waiting at the gate.
    func waitUntilWaiting(_ count: Int = 1) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let ready = lock.withLock { () -> Bool in
                if waiters.count >= count { return true }
                watchers.append((count, continuation))
                return false
            }
            if ready { continuation.resume() }
        }
    }
}
