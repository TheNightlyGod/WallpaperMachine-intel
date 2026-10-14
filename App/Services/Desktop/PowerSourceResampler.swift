import AppKit

/// Has the power source read again when the Mac wakes. A plug or unplug during sleep may not be
/// reported, or its report may race the wake, and the battery rule would keep acting on the old
/// source until the next change. Each wake reads at once and once more after `followUp`, for a
/// system that is still settling its power state. A burst of wakes keeps only the newest
/// follow-up, so it is never more than two reads per wake and nothing is polled.
@MainActor
final class PowerSourceResampler {
    typealias Sleep = @Sendable (Duration) async throws -> Void

    private let workspaceCenter: NotificationCenter
    private let followUp: Duration
    private let resample: @MainActor () -> Void
    private let sleep: Sleep
    private var observers: [NSObjectProtocol] = []
    private var pendingFollowUp: Task<Void, Never>?

    init(
        workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        followUp: Duration = .seconds(2),
        resample: @escaping @MainActor () -> Void,
        sleep: @escaping Sleep = { try await Task.sleep(for: $0, tolerance: .milliseconds(500)) }
    ) {
        self.workspaceCenter = workspaceCenter
        self.followUp = followUp
        self.resample = resample
        self.sleep = sleep
    }

    func start() {
        guard observers.isEmpty else { return }
        // The display coming back and the Mac coming back are separate notifications, and a
        // dark wake posts only the first. Either one is reason enough to read again.
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            observers.append(workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.woke() }
            })
        }
    }

    func stop() {
        for observer in observers { workspaceCenter.removeObserver(observer) }
        observers.removeAll()
        pendingFollowUp?.cancel()
        pendingFollowUp = nil
    }

    private func woke() {
        AppLog.debug("power source resample after wake")
        resample()
        pendingFollowUp?.cancel()
        let sleep = sleep, followUp = followUp
        pendingFollowUp = Task { [weak self] in
            do { try await sleep(followUp) } catch { return }
            // A sleep that ignores cancellation still returns, and must not read for a wake
            // that a newer one or `stop()` has replaced.
            guard !Task.isCancelled, let self else { return }
            pendingFollowUp = nil
            resample()
        }
    }
}
