import Foundation

/// How long the wallpaper on each display has played where it can be seen since it started: what
/// tells a frame of it that is past an intro or a fade-in from one that may not be. Time counts
/// only while the display presents (not paused, covered, asleep or suspended by a rule), since a
/// wallpaper that does not present does not move on. A new wallpaper, a new window (a reload, a
/// display that came back) or new files start the count again.
///
/// The owner reports what each display shows whenever that can change (`observe`). Nothing here
/// runs on its own, except for someone waiting (`nextChange`): then one sleep until the soonest
/// display that plays reaches the window. The window is the desktop picture's settle window, after which its posters
/// count as settled too (`DesktopWallpaperSync.settleCaptureDelays`).
@MainActor
final class WallpaperSettleClock {
    /// What a display shows: a change of any of it is a wallpaper that starts again.
    struct Identity: Equatable {
        var wallpaperID: String
        var window: Int
        var contentRevision: UInt64
    }

    struct Observation: Equatable {
        var identity: Identity
        var presenting: Bool
    }

    private struct Entry {
        var identity: Identity
        /// Time played before the current stretch of presenting.
        var played: Duration
        /// When the current stretch of presenting began; nil while the display does not present.
        var since: ContinuousClock.Instant?
    }

    static let window: Duration = DesktopWallpaperSync.settleCaptureDelays.last ?? .seconds(15)

    private let now: @MainActor () -> ContinuousClock.Instant
    private let sleep: @Sendable (Duration) async throws -> Void
    private var entries: [UInt32: Entry] = [:]
    /// Who waits for a display's next change, by display and ticket.
    private var waiters: [UInt32: [UUID: CheckedContinuation<Void, Never>]] = [:]
    /// The sleep until a display someone waits for settles.
    private var alarm: Task<Void, Never>?

    init(now: @escaping @MainActor () -> ContinuousClock.Instant = { .now },
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.now = now
        self.sleep = sleep
    }

    /// What every display shows now. A display left out has no wallpaper window and is forgotten.
    func observe(_ displays: [UInt32: Observation]) {
        let time = now()
        var changed = Set(entries.keys.filter { displays[$0] == nil })
        entries = entries.filter { displays[$0.key] != nil }
        for (display, observation) in displays {
            guard var entry = entries[display], entry.identity == observation.identity else {
                if entries[display] != nil { changed.insert(display) }
                entries[display] = Entry(
                    identity: observation.identity, played: .zero, since: observation.presenting ? time : nil)
                continue
            }
            if observation.presenting, entry.since == nil {
                entry.since = time
                changed.insert(display)
            } else if !observation.presenting, let since = entry.since {
                entry.played += time - since
                entry.since = nil
                changed.insert(display)
            }
            entries[display] = entry
        }
        for display in changed { wake(display) }
        scheduleAlarm()
    }

    /// Returns at the display's next change: its wallpaper settles, starts or stops playing where
    /// it can be seen, or is replaced or gone. Returns at once when the task is cancelled.
    func nextChange(of display: UInt32) async {
        let ticket = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                guard !Task.isCancelled else { return continuation.resume() }
                waiters[display, default: [:]][ticket] = continuation
                scheduleAlarm()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.wake(display, ticket: ticket) }
        }
    }

    /// How many waits are under way.
    var waiting: Int { waiters.values.reduce(0) { $0 + $1.count } }

    /// Lets go of whoever waits for `display`, or only the one holding `ticket`.
    private func wake(_ display: UInt32, ticket: UUID? = nil) {
        guard var waiting = waiters[display] else { return }
        let woken = ticket.map { ticket in waiting.removeValue(forKey: ticket).map { [$0] } ?? [] }
            ?? Array(waiting.values)
        if ticket == nil { waiting.removeAll() }
        waiters[display] = waiting.isEmpty ? nil : waiting
        for continuation in woken { continuation.resume() }
        scheduleAlarm()
    }

    /// One sleep until the soonest display someone waits for settles, while it plays.
    private func scheduleAlarm() {
        alarm?.cancel()
        alarm = nil
        guard let soonest = waiters.keys.compactMap({ display in remaining(display).map { (display, $0) } })
            .min(by: { $0.1 < $1.1 }) else { return }
        let sleep = self.sleep
        alarm = Task { [weak self] in
            do { try await sleep(soonest.1) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.alarm = nil
            self.wake(soonest.0)
        }
    }

    /// How long the wallpaper on `display` has played where it can be seen; nil for a display
    /// without one.
    func played(_ display: UInt32) -> Duration? {
        guard let entry = entries[display] else { return nil }
        return entry.played + (entry.since.map { now() - $0 } ?? .zero)
    }

    /// Whether the wallpaper on `display` has played a whole settle window.
    func isSettled(_ display: UInt32) -> Bool {
        (played(display) ?? .zero) >= Self.window
    }

    /// How long until the wallpaper on `display` has settled, while it presents; nil when it has
    /// settled, does not present, or there is none, as nothing would change by waiting.
    func remaining(_ display: UInt32) -> Duration? {
        guard let entry = entries[display], entry.since != nil, let played = played(display),
              played < Self.window else { return nil }
        return Self.window - played
    }
}
