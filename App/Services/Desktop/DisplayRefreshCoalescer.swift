import Foundation

/// Runs one display refresh at a time, and none while the displays are as the
/// last successful refresh read them. macOS posts screen-parameter changes in
/// bursts: an XDR display posts one per frame while its EDR headroom ramps, as
/// a menu-bar banner, HDR content or a brightness change moves it, and none of
/// those change anything the renderer reads. Each refresh is a full round trip
/// through the bridge that republishes every snapshot and re-renders the
/// control panel, so a change that leaves the configuration as it was is
/// dropped, and the changes that arrive while one runs are answered by a
/// single refresh after it.
///
/// A display that disappears from the screen list gets one short wait first.
/// The bridge closes the wallpaper of a display that is not in the list and
/// opens it again when the display is back, which for a scene or a video is a
/// full load, so a display that is gone for a moment (a link renegotiating, a
/// monitor waking) must not cost one. Only a reading that is the last refresh
/// with displays taken out, and nothing else moved, waits. Anything else that
/// differs, a display added, moved, rescaled or promoted to main, refreshes
/// at once, because the renderer's picture of the displays that remain is
/// stale until it does. The wait is one fixed delay from the first reading
/// that lacks a display and is never extended, so a display that keeps
/// posting changes cannot hold the refresh off; a reading equal to the last
/// refresh ends it with no bridge work at all.
///
/// Skipping that refresh leaves one thing undone. The hosts draw on the screens
/// AppKit lists, so a snapshot applied while the display was missing closed its
/// window, and the refresh that used to follow the display's return is what
/// opened it again. `displayReturned` runs in its place, once, when a display
/// that went missing is back and no refresh is going to run for it.
@MainActor
final class DisplayRefreshCoalescer {
    private enum Reading {
        /// The same displays the last successful refresh read.
        case unchanged
        /// Those displays with some taken out, nothing else different.
        case departure
        /// Anything else, including every reading before a refresh has succeeded.
        case change
    }

    private let configuration: @MainActor () -> DisplayConfiguration
    private let refresh: @MainActor () async -> Bool
    private let displayReturned: @MainActor () -> Void
    private let settleDelay: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private var running = false
    private var pending = false
    private var coalesced = 0
    private var drainTask: Task<Void, Never>?
    /// The last wait that ended, by being answered or by being cancelled, so a test can wait
    /// for it to finish.
    private var endedWait: Task<Void, Never>?
    /// The wait before refreshing for a vanished display; at most one at a time.
    private var waiting: Task<Void, Never>?
    /// When the first reading that lacked a display was seen, kept until a refresh or the
    /// display's return answers it. Outlives the wait itself: a display can be back by the
    /// time the wait's own refresh reads the screens.
    private var missingSince: ContinuousClock.Instant?
    /// What the last refresh read, kept only when it succeeded; a failed one is retried
    /// on the next change even if the displays look the same.
    private var refreshed: DisplayConfiguration?

    /// `refresh` reports whether it succeeded. `settle` is how long a display may be missing
    /// before the refresh runs for it; `sleep` is what waits. `displayReturned` is told when a
    /// display that went missing is listed again with nothing refreshed for it.
    init(configuration: @escaping @MainActor () -> DisplayConfiguration = DisplayConfiguration.current,
         settle: Duration = .milliseconds(800),
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         displayReturned: @escaping @MainActor () -> Void = {},
         refresh: @escaping @MainActor () async -> Bool) {
        self.configuration = configuration
        self.settleDelay = settle
        self.sleep = sleep
        self.displayReturned = displayReturned
        self.refresh = refresh
    }

    func request() {
        guard !running else {
            pending = true
            coalesced += 1
            return
        }
        guard due() != nil else { return }
        startDrain(afterSettling: false)
    }

    /// Ends a wait for a vanished display without refreshing. A later request starts over.
    func cancel() {
        endWait()
        missingSince = nil
    }

    /// Resolves once nothing is refreshing and the last wait that ended has finished. A wait
    /// that is still pending does not count.
    func waitUntilIdleForTest() async {
        await endedWait?.value
        await drainTask?.value
    }

    private func startDrain(afterSettling: Bool) {
        running = true
        drainTask = Task { await drain(afterSettling: afterSettling) }
    }

    private func drain(afterSettling: Bool) async {
        var afterSettling = afterSettling
        repeat {
            pending = false
            if let current = due(afterSettling: afterSettling) {
                if afterSettling {
                    AppLog.info("display refresh: refreshing after \(Self.milliseconds(settleDelay)) ms of a display being missing")
                }
                refreshed = await refresh() ? current : nil
            }
            afterSettling = false
        } while pending
        running = false
        if coalesced > 0 {
            AppLog.info("display refresh: \(coalesced) screen changes arrived during a refresh and were merged")
            coalesced = 0
        }
    }

    /// The reading to refresh for, or nil when none is due now, and keeps the wait for a
    /// vanished display in step with what it saw. A reading that equals the last refresh
    /// ends the wait and, if a display had been missing, tells `displayReturned`; a departure
    /// starts a wait unless one is already running, and any other change ends it and is due
    /// at once. After the wait every difference is due.
    private func due(afterSettling: Bool = false) -> DisplayConfiguration? {
        let current = configuration()
        switch classify(current) {
        case .unchanged:
            endWait()
            if let since = missingSince {
                missingSince = nil
                let elapsed = Self.milliseconds(since.duration(to: .now))
                AppLog.info("display refresh: a display missing for \(elapsed) ms came back; no refresh")
                displayReturned()
            }
            return nil
        case .departure where !afterSettling:
            if missingSince == nil { missingSince = .now }
            beginWait()
            return nil
        case .departure, .change:
            missingSince = nil
            endWait()
            return current
        }
    }

    private func beginWait() {
        guard waiting == nil else { return }
        AppLog.debug("display refresh: a display is missing; waiting \(Self.milliseconds(settleDelay)) ms before refreshing")
        let delay = settleDelay
        let sleep = self.sleep
        waiting = Task { [weak self] in
            try? await sleep(delay)
            // A wait that was ended while it slept must not refresh.
            guard !Task.isCancelled else { return }
            self?.waitElapsed()
        }
    }

    private func endWait() {
        guard let waiting else { return }
        waiting.cancel()
        endedWait = waiting
        self.waiting = nil
    }

    private func waitElapsed() {
        endedWait = waiting
        waiting = nil
        guard !running else {
            // Starting a refresh ends the wait, so this cannot be reached; if it ever is,
            // the running refresh's loop reads the displays again.
            pending = true
            return
        }
        startDrain(afterSettling: true)
    }

    private func classify(_ current: DisplayConfiguration) -> Reading {
        guard let refreshed else { return .change }
        if current == refreshed { return .unchanged }
        return Self.isDeparture(from: refreshed, to: current) ? .departure : .change
    }

    /// Whether `current` is `refreshed` with displays taken out and every display that is
    /// left exactly as it was, in the same order, so the renderer's picture of them is still
    /// right. A screen without a display ID (0) leaving does not count: it cannot be matched
    /// to anything the bridge holds.
    private static func isDeparture(from refreshed: DisplayConfiguration, to current: DisplayConfiguration) -> Bool {
        var remaining = current.displays[...]
        var removedKnownDisplay = false
        for display in refreshed.displays {
            if remaining.first == display {
                remaining.removeFirst()
            } else if display.id != 0 {
                removedKnownDisplay = true
            }
        }
        return remaining.isEmpty && removedKnownDisplay
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        let (seconds, attoseconds) = duration.components
        return Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000)
    }
}
