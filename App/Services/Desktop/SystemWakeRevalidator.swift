import AppKit

/// Asks the renderer to confirm, after the Mac wakes, that every scene which
/// should be drawing still is.
///
/// The check itself lives in the bridge (`revalidateScenePresentation`): it
/// reads each scene's frame counter twice, a few seconds apart, and has the
/// engine rebuild the surface of only the scene whose counter did not move.
/// A healthy Mac pays two counter reads and the wait; nothing is rebuilt, and
/// paused, suspended and event-driven scenes are never touched. This class only
/// decides *when* to ask, and never polls:
///
/// - A wake (`didWake` from the system, `screensDidWake` from the displays)
///   starts one pass after a short debounce. The two notifications for one
///   wake, and a burst of either, are one pass.
/// - A wake is checked only while the wallpaper is presenting. A wake usually
///   lands on a locked session, where the presentation policy has the scenes
///   suspended and a frame counter standing still means nothing; the wake then
///   stays pending, and `presentationResumed()` runs the pass once the unlock
///   lets the scenes draw again.
/// - A pass waits for the user's command queue to be idle, so it never runs in
///   the middle of an Apply that is replacing the scenes it would read.
///
/// A failing check is logged and dropped: the check is a courtesy, and the
/// scene it could not read stays exactly as it was.
@MainActor
final class SystemWakeRevalidator {
    typealias Sleep = @MainActor (Duration) async throws -> Void

    /// What one pass found, counted the way the log reports it.
    struct Summary: Equatable {
        /// Displays whose scene was looked at (skipped ones are not).
        var checked: Int
        var repaired: Int
        /// Asked to repair and not repaired: a scene the user will find frozen.
        var unrepaired: Int
        var skipped: Int

        /// A repair, or a scene still not drawing, is worth a warning; a Mac that woke well is not.
        var isWarning: Bool { repaired + unrepaired > 0 }
    }

    /// What a pass tells the log, kept as facts until it is worded (`message`).
    enum Report: Equatable {
        case checked(reason: String, Summary)
        case failed(reason: String, error: String)

        var isWarning: Bool {
            switch self {
            case let .checked(_, summary): summary.isWarning
            case .failed: true
            }
        }

        /// The line the log gets, in the shape `docs/features/diagnostics.md#wake-check` shows.
        var message: String {
            switch self {
            case let .checked(reason, summary):
                var line = "wake check (\(reason)): \(SystemWakeRevalidator.count(summary.checked, "display")) checked, "
                    + "\(summary.repaired) repaired"
                if summary.unrepaired > 0 { line += ", \(summary.unrepaired) still not drawing" }
                if summary.skipped > 0 { line += ", \(summary.skipped) skipped" }
                return line
            case let .failed(reason, error):
                return "wake check (\(reason)) failed: \(error)"
            }
        }
    }

    private let center: NotificationCenter
    private let isPresenting: @MainActor () -> Bool
    private let waitForIdle: @MainActor () async -> Void
    private let perform: @MainActor (String) async throws -> [BridgeSurfaceCheck]
    private let debounce: Duration
    private let sleep: Sleep
    private let report: @MainActor (Report) -> Void

    private var observers: [NSObjectProtocol] = []
    private var started = false
    /// Bumped by every wake, every resume and `stop()`. A run whose number is no
    /// longer current has been superseded and does nothing more.
    private var generation = 0
    private var latest: Task<Void, Never>?
    /// What woke the Mac, until a pass has taken it. Set means a check is owed.
    private var pendingReason: String?
    /// Whether the wallpaper presented again after the wake that is pending: the
    /// check then runs because of the resume, and the log says so.
    private var resumedSinceWake = false

    /// Closures are optional so their `@MainActor` defaults are built inside
    /// this (already `@MainActor`) initializer rather than in a default-argument
    /// expression evaluated in the caller's isolation.
    init(
        center: NotificationCenter = NSWorkspace.shared.notificationCenter,
        isPresenting: @escaping @MainActor () -> Bool,
        waitForIdle: @escaping @MainActor () async -> Void,
        perform: @escaping @MainActor (String) async throws -> [BridgeSurfaceCheck],
        debounce: Duration = .milliseconds(650),
        sleep: Sleep? = nil,
        report: (@MainActor (Report) -> Void)? = nil
    ) {
        self.center = center
        self.isPresenting = isPresenting
        self.waitForIdle = waitForIdle
        self.perform = perform
        self.debounce = debounce
        self.sleep = sleep ?? { try await Task.sleep(for: $0) }
        self.report = report ?? { report in
            if report.isWarning { AppLog.warn(report.message) } else { AppLog.info(report.message) }
        }
    }

    func start() {
        guard !started else { return }
        started = true
        for (name, reason) in [
            (NSWorkspace.didWakeNotification, "didWake"),
            (NSWorkspace.screensDidWakeNotification, "screensDidWake"),
        ] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.wakeObserved(reason) }
            })
        }
    }

    func stop() {
        started = false
        generation += 1
        latest?.cancel()
        latest = nil
        for observer in observers { center.removeObserver(observer) }
        observers.removeAll()
        pendingReason = nil
        resumedSinceWake = false
    }

    /// Call when presentation runs again after the policy paused or unloaded
    /// it, for the whole desktop or for one display. Runs the pass a wake left
    /// owed because the session was locked; does nothing otherwise.
    func presentationResumed() {
        guard started, pendingReason != nil else { return }
        resumedSinceWake = true
        schedule()
    }

    /// Resolves when the pass the latest trigger scheduled has finished. For
    /// tests, which drive the pass with an injected sleep.
    func waitForSchedule() async {
        await latest?.value
    }

    private func wakeObserved(_ reason: String) {
        guard started else { return }
        // The first notification names the wake; the second one for it does not
        // rename it.
        if pendingReason == nil { pendingReason = reason }
        schedule()
    }

    private func schedule() {
        generation += 1
        let generation = generation
        latest?.cancel()
        latest = Task { [weak self] in
            await self?.run(generation: generation)
        }
    }

    private func run(generation: Int) async {
        // Superseded before it began: it does not even start the debounce.
        guard !Task.isCancelled else { return }
        do { try await sleep(debounce) } catch { return }
        guard started, generation == self.generation else { return }
        // Locked, asleep or deliberately paused: the pass stays owed and runs when
        // presentation resumes.
        guard isPresenting() else { return }
        // An Apply in progress is replacing the scenes this would read.
        await waitForIdle()
        guard started, generation == self.generation, isPresenting(), let woke = pendingReason else { return }
        let reason = resumedSinceWake ? "\(woke), once presentation resumed" : woke
        pendingReason = nil
        resumedSinceWake = false
        let checks: [BridgeSurfaceCheck]
        do {
            checks = try await perform(reason)
        } catch {
            report(.failed(reason: reason, error: error.localizedDescription))
            return
        }
        report(.checked(reason: reason, Summary(checks)))
    }

    nonisolated fileprivate static func count(_ number: Int, _ noun: String) -> String {
        "\(number) \(noun)\(number == 1 ? "" : "s")"
    }
}

extension SystemWakeRevalidator.Summary {
    /// Counts the per-display outcomes the bridge reported.
    init(_ checks: [BridgeSurfaceCheck]) {
        let skipped = checks.filter { $0.outcome.hasPrefix("skipped") }.count
        self.init(
            checked: checks.count - skipped,
            repaired: checks.filter { $0.outcome == "repaired" }.count,
            unrepaired: checks.filter {
                ["gave_up", "recovery_pending", "recovery_failed"].contains($0.outcome)
            }.count,
            skipped: skipped)
    }
}
