import Foundation

/// What a health check concluded, and what it was run for.
struct NativeVideoHealthEvent: Equatable {
    /// Which look of a check this is. A check that finds a stall looks again
    /// after each repair it tries.
    enum Stage: Equatable {
        /// The first look, taken because of the trigger.
        case initial
        /// The look after the seek and play.
        case afterKick
        /// The look after the item was rebuilt.
        case afterRebuild
    }

    /// Why the check ran, for the log: "resumed after 2 h".
    let trigger: String
    let verdict: NativeVideoLiveness
    var stage: Stage = .initial
    /// What the check does about this verdict, decided before it is reported:
    /// a log line can say "kicking it" rather than leave the reader to infer
    /// it from the line that follows.
    var next: NativeVideoHealthLadder.Action = .done
}

/// The playing surface a supervisor looks at, and repairs.
@MainActor
protocol NativeVideoHealthTarget: AnyObject {
    /// Whether looking at the pipeline now would tell anything: it is playing,
    /// and it has shown a picture before. A surface that has never shown one is
    /// the first-frame watch's business, and a paused or hidden one is not
    /// supposed to be producing anything.
    var isEligibleForCheck: Bool { get }
    /// One look at the pipeline, or `nil` when there is nothing to look at right
    /// now (no item between two loop copies, or while the item is rebuilt).
    func liveSample() -> NativeVideoLivenessEvaluator.Sample?
    /// The check is over, whether it concluded or was abandoned. Whatever
    /// `liveSample` attached to the pipeline goes away here, so a surface that
    /// is not being checked is not paying for it.
    func finishSampling()
    func reportHealth(_ event: NativeVideoHealthEvent)

    /// Whether the surface could still afford to rebuild its pipeline. Asking
    /// charges nothing.
    func canRebuildPlayback() -> Bool
    /// Seek to where the clip is and play, which restarts an output that is
    /// stuck without disturbing a healthy one.
    func kickPlayback()
    /// Rebuilds the pipeline from the file and charges the recovery allowance.
    /// False means nothing was started.
    func rebuildPlayback(reason: String) -> Bool
    /// The pictures are back. A stretch of them with no rebuild in between is
    /// what earns the recovery allowance back.
    func playbackProvedHealthy()
    /// Nothing left to try. The surface reports the wallpaper as unplayable,
    /// which the host reports as a failed display.
    func giveUpOnPlayback(trigger: String, detail: String)
}

/// Looks at a surface's pipeline after something that could have cost it its
/// decoder, reports whether pictures still come out, and repairs it when they
/// do not.
///
/// A check settles first, because the system needs a moment to hand the
/// decoder back after a wake, and then samples at a fixed step until the
/// samples prove the pipeline works or the window ends. Healthy pipelines are
/// usually proven within a couple of samples, so the common cost of a check is
/// one short-lived video output and no visible change. A pipeline that is found
/// stalled climbs the `NativeVideoHealthLadder`: a kick, one rebuild, then giving
/// up (a failed display), with a fresh look after each.
///
/// At most one check runs at a time. A trigger that arrives while the check is
/// still only looking replaces it, since what the trigger describes is the
/// state the older check was about to judge. A trigger that arrives once the
/// check has begun repairing is absorbed instead: starting over would kick a
/// pipeline that is already being kicked, and the look that follows the repair
/// answers the same question.
@MainActor
final class NativeVideoHealthSupervisor {
    struct Policy: Equatable {
        /// How long a surface has to have been paused before resuming it is
        /// worth a check. A flick of the occlusion state is not.
        var minimumPause: Duration = .seconds(5)
        /// Wait between a trigger, or a repair, and the next look.
        var settle: Duration = .milliseconds(500)
        /// How long the samples may go on without proving anything.
        var window: Duration = .seconds(2)
        /// Time between samples.
        var step: Duration = .milliseconds(100)
        /// The window after a rebuild, which is longer because the new item has
        /// to load and show a first picture before anything can be proven.
        var rebuildWindow: Duration = .seconds(5)

        /// How many samples fit a window: the bound on one look's work.
        func samples(in window: Duration) -> Int {
            guard step > .zero else { return 1 }
            return max(1, Int(window / step))
        }

        var sampleLimit: Int { samples(in: window) }
    }

    weak var target: (any NativeVideoHealthTarget)?
    private let policy: Policy
    private let sleep: @Sendable (Duration) async throws -> Void
    private var run: Task<Void, Never>?
    /// Whether the run in flight has issued a repair.
    private var repairing = false
    /// Moves whenever a run starts or is abandoned, so a run that was replaced
    /// can tell, whatever it was doing when it was.
    private var generation: UInt64 = 0

    init(
        policy: Policy = Policy(),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.policy = policy
        self.sleep = sleep
    }

    /// Starts a check for `trigger`. A check that is still only looking is
    /// replaced; one that is repairing absorbs the trigger. A surface that
    /// cannot be judged right now is left alone.
    func schedule(trigger: String) {
        guard target?.isEligibleForCheck == true else { return }
        if run != nil, repairing { return }
        abandonRun()
        let mine = generation
        run = Task { @MainActor [weak self] in
            await self?.perform(trigger: trigger, generation: mine)
        }
    }

    /// Abandons the check in flight and reports nothing more for it.
    func cancel() {
        abandonRun()
    }

    /// Waits for the check in flight to finish.
    func waitUntilIdleForTest() async {
        await run?.value
    }

    private func abandonRun() {
        generation &+= 1
        repairing = false
        guard let run else { return }
        run.cancel()
        self.run = nil
        target?.finishSampling()
    }

    private func finishRun() {
        run = nil
        repairing = false
        target?.finishSampling()
    }

    private func perform(trigger: String, generation mine: UInt64) async {
        var ladder = NativeVideoHealthLadder()
        var stage = NativeVideoHealthEvent.Stage.initial
        var settle = policy.settle
        var window = policy.window
        while true {
            guard let verdict = await observe(generation: mine, settle: settle, window: window)
            else {
                // Replaced or cancelled: whoever did that has already
                // released what sampling attached. Stopping being meaningful
                // (the user paused) leaves it to be released here.
                if mine == generation { finishRun() }
                return
            }
            guard mine == generation, let target else { return }
            let action = ladder.next(verdict, canRebuild: target.canRebuildPlayback())
            target.reportHealth(NativeVideoHealthEvent(
                trigger: trigger, verdict: verdict, stage: stage, next: action))
            switch action {
            case .done:
                finishRun()
                target.playbackProvedHealthy()
                return
            case .recheck:
                // The previous window just ended; nothing to settle.
                settle = .zero
                window = policy.window
            case .kick:
                repairing = true
                target.kickPlayback()
                stage = .afterKick
                settle = policy.settle
                window = policy.window
            case .rebuild:
                repairing = true
                guard target.rebuildPlayback(reason: "playback stalled after \(trigger)") else {
                    finishRun()
                    target.giveUpOnPlayback(
                        trigger: trigger, detail: "the pipeline could not be rebuilt")
                    return
                }
                stage = .afterRebuild
                settle = policy.settle
                window = policy.rebuildWindow
            case let .giveUp(detail):
                finishRun()
                target.giveUpOnPlayback(trigger: trigger, detail: detail)
                return
            }
        }
    }

    /// The verdict, or `nil` when the check stopped being meaningful: it was
    /// replaced, the surface paused or went away, or it was cancelled.
    private func observe(
        generation mine: UInt64, settle: Duration, window: Duration
    ) async -> NativeVideoLiveness? {
        if settle > .zero {
            do { try await sleep(settle) } catch { return nil }
        }
        var evaluator = NativeVideoLivenessEvaluator()
        let samples = policy.samples(in: window)
        for index in 0..<samples {
            guard mine == generation, let target, target.isEligibleForCheck else { return nil }
            if let sample = target.liveSample() { evaluator.record(sample) }
            if let proven = evaluator.verdict { return proven }
            if index + 1 < samples {
                do { try await sleep(policy.step) } catch { return nil }
            }
        }
        guard mine == generation, target?.isEligibleForCheck == true else { return nil }
        return evaluator.timedOut()
    }
}
