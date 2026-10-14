import Foundation

/// A sleep the test releases by hand, for code that takes its sleep as a closure. It ignores
/// cancellation, as the worst real sleep could, so a guard against acting on a cancelled wait
/// is exercised by releasing the sleep after the cancel.
final class ManualSleep: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var count = 0

    /// Sleeps begun and not yet released.
    var waiting: Int { lock.withLock { continuations.count } }
    /// Sleeps begun in all.
    var started: Int { lock.withLock { count } }

    func sleep(for duration: Duration) async {
        await withCheckedContinuation { continuation in
            lock.withLock {
                count += 1
                continuations.append(continuation)
            }
        }
    }

    /// Ends the sleep that began first.
    func releaseOldest() {
        let released: CheckedContinuation<Void, Never>? = lock.withLock {
            continuations.isEmpty ? nil : continuations.removeFirst()
        }
        released?.resume()
    }

    func releaseAll() {
        let released: [CheckedContinuation<Void, Never>] = lock.withLock {
            let all = continuations
            continuations.removeAll()
            return all
        }
        for continuation in released { continuation.resume() }
    }
}
