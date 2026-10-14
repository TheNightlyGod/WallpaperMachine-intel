import Foundation

/// Runs the newest piece of work for a key once the edits for it have stopped for a moment.
///
/// A drag or a preset applies many edits in quick succession; each `schedule` only replaces
/// what the key will run and restarts the wait, so a burst costs one run. At most one run per
/// key is in flight: edits that arrive while it works queue behind it as one more run, again
/// with only the newest work. Keys are independent of each other.
///
/// A source that already spaces its edits, a drag the page sends a step of every 100 ms, passes
/// `delay: .zero` and is served as soon as nothing of the key is running: waiting out a quiet
/// period would never end while the drag goes on.
@MainActor
final class PropertyPreviewScheduler {
    typealias Work = @MainActor () async -> Void
    typealias Sleep = @Sendable (Duration) async throws -> Void

    private final class Slot {
        var work: Work?
        /// Counts `schedule` calls, so a wait that was overtaken by a newer edit starts over.
        var revision: UInt64 = 0
        /// The wait the newest `schedule` asked for, or the scheduler's own.
        var delay: Duration?
        var task: Task<Void, Never>?
    }

    nonisolated static let defaultDelay = Duration.milliseconds(150)

    private let delay: Duration
    private let sleep: Sleep
    private var slots: [String: Slot] = [:]

    init(delay: Duration = PropertyPreviewScheduler.defaultDelay,
         sleep: @escaping Sleep = { try await Task.sleep(for: $0) }) {
        self.delay = delay
        self.sleep = sleep
    }

    /// Whether the key has work waiting or running.
    func isPending(_ key: String) -> Bool { slots[key]?.task != nil }

    func schedule(key: String, delay: Duration? = nil, _ work: @escaping Work) {
        let slot = slots[key] ?? Slot()
        slots[key] = slot
        slot.work = work
        slot.delay = delay
        slot.revision &+= 1
        if slot.task == nil { slot.task = Task { [weak self, weak slot] in await self?.drain(key: key, slot: slot) } }
    }

    /// Drops the work waiting for the key. A run already in flight is told to stop and
    /// finishes on its own; the work checks for that itself.
    func cancel(_ key: String) {
        guard let slot = slots.removeValue(forKey: key) else { return }
        slot.work = nil
        slot.task?.cancel()
        slot.task = nil
    }

    func cancelAll() {
        for key in Array(slots.keys) { cancel(key) }
    }

    private func drain(key: String, slot: Slot?) async {
        guard let slot else { return }
        // A cancelled key was removed (and possibly scheduled again) already, so only a slot
        // that is still the key's own is released. Nothing suspends between the last check of
        // the loop and this, so work scheduled meanwhile is never left without a task.
        defer { if slots[key] === slot { slot.task = nil } }
        while true {
            let seen = slot.revision
            let wait = slot.delay ?? delay
            if wait > .zero { do { try await sleep(wait) } catch { return } }
            if Task.isCancelled { return }
            // Overtaken while waiting: the trailing edge is the newest edit's.
            if slot.revision != seen { continue }
            guard let work = slot.work else { return }
            slot.work = nil
            await work()
            if Task.isCancelled { return }
            if slot.work == nil { return }
        }
    }
}
