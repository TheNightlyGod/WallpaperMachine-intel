import Foundation

/// How often one native video surface may rebuild its playback pipeline before
/// the wallpaper is handed to the scene engine instead.
///
/// A rebuild is the strongest repair the player has, and a pipeline that stalls
/// again right after it will go on doing so: without a bound the player would
/// rebuild forever, decoding the clip again each time, and a display would never
/// reach the fallback that can actually show it. The budget is a sliding window
/// with an escape for a pipeline that has proved itself since: a clip that has
/// delivered frames for a whole `stableRun` without a rebuild starts again with
/// the full allowance, so a fault every few hours is repaired every time while a
/// fault every few seconds is not.
///
/// Pure, with the clock passed in, so the rule is exercised without waiting. It
/// is a value the player owns, one per surface, which is why it survives the
/// player replacing its item.
struct NativeVideoRecoveryBudget: Equatable {
    struct Policy: Equatable {
        /// Rebuilds allowed inside `window`.
        var maximum = 2
        /// How long a rebuild counts against the allowance.
        var window: Duration = .seconds(600)
        /// How long the pipeline has to keep delivering, with no rebuild in
        /// between, for the history to be forgiven.
        var stableRun: Duration = .seconds(60)
    }

    let policy: Policy
    private var history: [ContinuousClock.Instant] = []
    /// When the current uninterrupted run of delivered frames began. Cleared by
    /// every rebuild that is permitted, so only a run that no repair
    /// interrupted can earn the allowance back.
    private var healthySince: ContinuousClock.Instant?

    init(policy: Policy = Policy()) {
        self.policy = policy
    }

    /// Rebuilds spent inside the window as of the last call, for a log line.
    var spent: Int { history.count }

    /// Asks to spend one rebuild at `moment`. True means the caller may rebuild
    /// now and the allowance is charged; false means the allowance is used up
    /// and the caller has to give the wallpaper up instead.
    mutating func permit(at moment: ContinuousClock.Instant) -> Bool {
        // A run that lasted long enough proves the last repair held, whatever
        // it took; it is judged before this request interrupts it.
        if let since = healthySince, moment - since >= policy.stableRun {
            history.removeAll()
        }
        let window = policy.window
        history.removeAll { moment - $0 >= window }
        // A refusal rebuilds nothing, so it leaves a run in progress alone.
        guard history.count < policy.maximum else { return false }
        history.append(moment)
        healthySince = nil
        return true
    }

    /// Whether `permit(at:)` would say yes at `moment`, without charging
    /// anything. For a caller that has a cheaper repair to try first and wants
    /// to know whether the expensive one is still open to it.
    func wouldPermit(at moment: ContinuousClock.Instant) -> Bool {
        var trial = self
        return trial.permit(at: moment)
    }

    /// Records that the pipeline delivered a frame at `moment`. The first call
    /// after a rebuild starts the stable run; later ones leave its start alone,
    /// so a long healthy stretch is measured from when it began.
    mutating func healthy(at moment: ContinuousClock.Instant) {
        if healthySince == nil { healthySince = moment }
    }

    /// Forgets everything: the allowance is full and no run is in progress.
    mutating func reset() {
        history.removeAll()
        healthySince = nil
    }
}
