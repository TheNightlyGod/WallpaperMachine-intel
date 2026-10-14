import Foundation

/// Runs the stages of a quit, each against a deadline.
///
/// Before this, a stage that never returned left the app half quit: the control panel
/// was already hidden and the activation policy already `.accessory`, so the app was
/// invisible, a second Exit was refused without a word, and nothing in the log said
/// which stage was stuck. Now restoration of the desktop gets one budget and the rest
/// of the teardown shares another; a stage that outlives its time is named, logged and
/// left behind.
///
/// Stages are raced rather than run under a task group, because a group waits for its
/// slowest child and a stage that is stuck never returns. Each stage runs in a task of
/// its own and a timer runs beside it; whichever settles first decides, and the other
/// is cancelled but never awaited. A stage that finishes after its deadline finds the
/// race already decided and changes nothing.
///
/// What a refused or cut-short quit does to the rest of the app (the alert, the panel,
/// the menu, the exit fuse) belongs to `AppDelegate`; this type only decides and logs.
///
/// How strict it is depends on who asked (`QuitMode`). A user's quit can be refused when
/// the desktop cannot be restored; the system's logout, restart or shutdown never is.
@MainActor
final class QuitSupervisor {
    /// How long each part of a quit may take.
    struct Budgets: Equatable, Sendable {
        /// Putting the user's own desktop picture back. Its own retries take about five
        /// seconds; the rest is for the lock-screen service that restores first.
        var restoration: Duration
        /// All the stages after restoration together.
        var teardown: Duration
        /// How long the process may take to exit once the quit has finished.
        var exitFuse: Duration
        /// The same, when a stage was left running: the renderer's threads are still alive
        /// and a slow exit would run C++ static destructors under them.
        var stalledExitFuse: Duration
        /// The least the last stage is given, even when earlier ones used the budget up:
        /// it is the renderer's shutdown, which closes the scenes and the log. It closes the
        /// load journal the moment it starts, so that does not depend on this time.
        var lastStageFloor: Duration

        /// Chosen generously. The stage durations every quit logs are what to tune them from.
        static let interactive = Budgets(
            restoration: .seconds(20), teardown: .seconds(10), exitFuse: .seconds(5),
            stalledExitFuse: .seconds(1), lastStageFloor: .seconds(2))

        /// The system is waiting for the app and its patience is limited, so every part is
        /// short. Judgments, not measurements: restoration is given a little over half the
        /// time its own retries use (they go on for about five seconds), because what it
        /// does not finish stays in the originals journal. The last stage keeps a second
        /// even so, because it closes the renderer's scenes and log. It closes the load
        /// journal as it starts, so a logout during a load is not counted as a crash
        /// whatever is left of that second.
        static let powerOff = Budgets(
            restoration: .seconds(3), teardown: .milliseconds(1500), exitFuse: .seconds(2),
            stalledExitFuse: .seconds(1), lastStageFloor: .seconds(1))

        func exitFuse(stalled: [String]) -> Duration {
            stalled.isEmpty ? exitFuse : stalledExitFuse
        }

        /// The longest a quit that keeps to these limits takes from the request to the
        /// process exiting: restoration, the teardown (the last stage keeps its floor even
        /// when the others used the budget up) and the exit fuse. A termination signal's
        /// deadline is not shorter, or it would cut off a quit that is still within its limits.
        var longestQuit: Duration { restoration + teardown + lastStageFloor + exitFuse }
    }

    struct Stage {
        let name: String
        let run: @MainActor () async throws -> Void
    }

    /// Why the quit was called off.
    enum Cancellation: Equatable, Sendable {
        /// Restoration threw; the text is the error's own.
        case restorationFailed(String)
        case restorationTimedOut
    }

    enum Outcome: Equatable {
        /// Restoration is done and the app may exit. `stalled` names the stages that were
        /// left behind, in order.
        case proceed(stalled: [String])
        /// The system is logging out, restarting or shutting down and the desktop was not
        /// restored in time (or at all). The app may exit anyway: whatever is unrestored
        /// stays in the originals journal. Only a `QuitMode.powerOff` quit ends this way.
        case proceedUnrestored(Cancellation, stalled: [String])
        /// The desktop could not be restored in time, so the app keeps running.
        case cancel(Cancellation)
    }

    /// Every stage and the whole quit are logged through this.
    let timings: QuitTimings
    let mode: QuitMode
    let budgets: Budgets
    private let now: () -> ContinuousClock.Instant
    private let sleep: @Sendable (Duration) async throws -> Void
    private let log: (String) -> Void

    /// `budgets` stands in for the mode's own, which tests use to make them small.
    init(
        mode: QuitMode = .interactive,
        budgets: Budgets? = nil,
        now: @escaping () -> ContinuousClock.Instant = { .now },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        log: @escaping (String) -> Void = { AppLog.info($0) }
    ) {
        self.mode = mode
        self.budgets = budgets ?? mode.budgets
        self.now = now
        self.sleep = sleep
        self.log = log
        timings = QuitTimings(now: now, log: log)
    }

    /// Runs `restoration`, then the `teardown` stages in order.
    ///
    /// An interactive quit goes on only if restoration succeeds in time; otherwise it is
    /// refused and nothing after it runs. A power-off quit goes on whatever happens to
    /// restoration (see `Outcome.proceedUnrestored`), because refusing would cancel the
    /// logout, restart or shutdown for everyone.
    ///
    /// A teardown stage that throws is logged and the quit goes on without it: nothing
    /// after restoration is worth keeping the app alive for. A stage that outlives the
    /// time it has left is named in `stalled` and the stages after it still run.
    func run(restoration: Stage, teardown: [Stage]) async -> Outcome {
        let restoreStart = now()
        let shortfall: Cancellation?
        switch await race(restoration, allowance: budgets.restoration) {
        case .finished:
            timings.record(restoration.name, since: restoreStart)
            shortfall = nil
        case .threw(let error):
            timings.record(restoration.name, since: restoreStart, failed: true, detail: error.localizedDescription)
            shortfall = .restorationFailed(error.localizedDescription)
        case .deadline:
            timings.recordStalled(restoration.name, since: restoreStart)
            shortfall = .restorationTimedOut
        }
        if let shortfall {
            guard mode == .powerOff else {
                timings.finish("cancelled")
                return .cancel(shortfall)
            }
            let why = switch shortfall {
            case .restorationFailed(let text): text
            case .restorationTimedOut: "not finished after \(budgets.restoration.wholeMilliseconds) ms"
            }
            log("quit: power off; desktop restoration unfinished (\(why)), the poster journal will finish it at the next launch")
        }

        let deadline = now().advanced(by: budgets.teardown)
        var stalled: [String] = []
        for (index, stage) in teardown.enumerated() {
            var allowance = max(.zero, now().duration(to: deadline))
            if index == teardown.count - 1 { allowance = max(allowance, budgets.lastStageFloor) }
            let start = now()
            guard allowance > .zero else {
                // No time is left, but the stage still has to start: it may be what
                // stops a child process. It simply is not waited for.
                _ = Task { @MainActor in try? await stage.run() }
                timings.recordStalled(stage.name, since: start)
                stalled.append(stage.name)
                continue
            }
            switch await race(stage, allowance: allowance) {
            case .finished:
                timings.record(stage.name, since: start)
            case .threw(let error):
                timings.record(stage.name, since: start, failed: true, detail: error.localizedDescription)
            case .deadline:
                timings.recordStalled(stage.name, since: start)
                stalled.append(stage.name)
            }
        }
        let skipped = (shortfall == nil ? [] : [restoration.name]) + stalled
        timings.finish(skipped.isEmpty ? "finished" : "finished without " + skipped.joined(separator: ", "))
        if let shortfall { return .proceedUnrestored(shortfall, stalled: stalled) }
        return .proceed(stalled: stalled)
    }

    private enum Result: Sendable {
        case finished
        case threw(any Error)
        case deadline
    }

    private func race(_ stage: Stage, allowance: Duration) async -> Result {
        let gate = FirstResult<Result>()
        let sleep = sleep
        let work = Task { @MainActor in
            do {
                try await stage.run()
                gate.offer(.finished)
            } catch {
                gate.offer(.threw(error))
            }
        }
        // Detached, so the timer does not wait for the main actor the stage may be holding.
        let timer = Task.detached {
            do { try await sleep(allowance) } catch { return }
            gate.offer(.deadline)
        }
        let result = await gate.wait()
        if case .deadline = result { work.cancel() } else { timer.cancel() }
        return result
    }
}

/// How a quit behaves, which depends on who asked for it.
enum QuitMode: String, Equatable, Sendable {
    /// The user, an update or an app: restoring the desktop may take its time, and when it
    /// fails the quit is refused so the user can see why and try again.
    case interactive
    /// macOS is logging out, restarting or shutting down. The system is waiting for this
    /// app, and a refusal cancels the logout for every app and shows the user a dialog, so
    /// the quit never refuses: it restores what it can in a short time and goes.
    case powerOff

    /// Pure, so every combination is exercised without a logout. The announcement counts
    /// as well as the reason because a signal that arrives during a shutdown has the
    /// reason `signal`, and it is still the shutdown that is waiting.
    static func resolve(reason: QuitReason, powerOffNotified: Bool) -> QuitMode {
        powerOffNotified || reason.isPowerOff ? .powerOff : .interactive
    }

    var budgets: QuitSupervisor.Budgets {
        switch self {
        case .interactive: .interactive
        case .powerOff: .powerOff
        }
    }
}

/// What `applicationShouldTerminate` answers a request to quit.
enum QuitRequestAnswer: Equatable {
    /// A quit already finished; the process is about to exit.
    case terminateNow
    /// Nothing is running, so begin a quit.
    case start
    /// A quit is running and this request must not stop it: reply later, and the running
    /// quit answers for both. Refusing a logout would cancel it.
    case wait
    /// A user's quit is running and another one adds nothing.
    case refuse

    /// `running` is the mode of the quit in progress, `nil` when none is.
    ///
    /// A request from the system always waits for the quit in progress, and anything waits
    /// for a power-off quit, which ends the process either way.
    static func answer(finished: Bool, running: QuitMode?, request: QuitMode) -> QuitRequestAnswer {
        if finished { return .terminateNow }
        guard let running else { return .start }
        return request == .powerOff || running == .powerOff ? .wait : .refuse
    }
}

/// Keeps the first value offered and hands it to whoever waits, once.
///
/// A second offer is refused, which is what stops a stage that finishes after its
/// deadline from resuming the quit a second time.
final class FirstResult<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?
    private var waiter: CheckedContinuation<Value, Never>?
    private var resumed = 0

    /// How many times the waiter was resumed: one, however many offers came.
    var resumeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return resumed
    }

    /// Returns whether this offer was the one kept.
    @discardableResult
    func offer(_ candidate: Value) -> Bool {
        lock.lock()
        guard value == nil else {
            lock.unlock()
            return false
        }
        value = candidate
        let pending = waiter
        waiter = nil
        if pending != nil { resumed += 1 }
        lock.unlock()
        pending?.resume(returning: candidate)
        return true
    }

    func wait() async -> Value {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let value {
                resumed += 1
                lock.unlock()
                continuation.resume(returning: value)
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }
}

/// Ends the process if it is still there a while after the quit finished.
///
/// A normal exit runs the C++ static destructors of the renderer and waits for the
/// threads it left, and either can hang with the app invisible and logout waiting for it.
/// The fuse runs on a thread of its own, so a blocked main thread does not stop it.
enum ExitFuse {
    /// Calls `fire` on a new thread after `delay`. Nothing disarms it: a process that
    /// exits in time simply takes the thread with it.
    static func arm(after delay: Duration, fire: @escaping @Sendable () -> Void) {
        let thread = Thread {
            Thread.sleep(forTimeInterval: delay.timeInterval)
            fire()
        }
        thread.name = "app.wallpapermachine.exit-fuse"
        thread.qualityOfService = .userInitiated
        thread.start()
    }
}

/// Why a quit was refused, worded for the alert and the menu line.
struct QuitFailure: LocalizedError {
    let cancellation: QuitSupervisor.Cancellation

    init(_ cancellation: QuitSupervisor.Cancellation) {
        self.cancellation = cancellation
    }

    var errorDescription: String? {
        switch cancellation {
        case .restorationFailed(let text):
            text
        case .restorationTimedOut:
            String(localized: "WallpaperMachine did not quit because restoring the desktop picture took too long. The app is still running; quit again to retry.")
        }
    }
}
