import Foundation

/// Times the stages of a quit and logs each one, then one line for the whole quit.
///
/// A quit that is slow, or that is cut short by the system, cannot be diagnosed from
/// the line that says it started. The durations here are also what a time budget for
/// a stage has to be read from, so they are logged for every quit, not only slow ones.
/// `QuitSupervisor` decides how long each stage may take and reports what happened here.
@MainActor
final class QuitTimings {
    struct Stage: Equatable {
        let name: String
        let duration: Duration
        /// The stage threw, so the quit was refused or went on without it.
        let failed: Bool
        /// The stage had not finished when its time ran out. `duration` is how long it
        /// was waited for; it may still be running.
        var stalled = false
    }

    /// Stages in the order they were settled.
    private(set) var stages: [Stage] = []
    private let now: () -> ContinuousClock.Instant
    private let log: (String) -> Void
    private let began: ContinuousClock.Instant

    init(
        now: @escaping () -> ContinuousClock.Instant = { .now },
        log: @escaping (String) -> Void = { AppLog.info($0) }
    ) {
        self.now = now
        self.log = log
        began = now()
    }

    /// Logs a stage that finished, or that threw (`detail` then says what it threw).
    func record(_ name: String, since start: ContinuousClock.Instant, failed: Bool = false, detail: String? = nil) {
        let stage = Stage(name: name, duration: start.duration(to: now()), failed: failed)
        stages.append(stage)
        let suffix = failed ? " and failed" + (detail.map { ": \($0)" } ?? "") : ""
        log("quit: stage \(name) took \(stage.duration.wholeMilliseconds) ms\(suffix)")
    }

    /// Logs a stage that was given up on because it had not finished in time.
    func recordStalled(_ name: String, since start: ContinuousClock.Instant) {
        let stage = Stage(name: name, duration: start.duration(to: now()), failed: false, stalled: true)
        stages.append(stage)
        log("quit: stage \(name) had not finished after \(stage.duration.wholeMilliseconds) ms and was left behind")
    }

    /// Logs the line for the whole quit: how it ended, how long it took since this
    /// object was made, and every stage that ran.
    func finish(_ outcome: String) {
        let stageText = stages.map { stage in
            var text = "\(stage.name) \(stage.duration.wholeMilliseconds) ms"
            if stage.failed { text += " (failed)" }
            if stage.stalled { text += " (stalled)" }
            return text
        }
        let detail = stageText.isEmpty ? "" : ": " + stageText.joined(separator: ", ")
        log("quit: \(outcome) after \(began.duration(to: now()).wholeMilliseconds) ms\(detail)")
    }
}

extension Duration {
    var wholeMilliseconds: Int64 {
        let parts = components
        return parts.seconds * 1_000 + parts.attoseconds / 1_000_000_000_000_000
    }

    /// For the APIs that still count in seconds (`Thread.sleep`).
    var timeInterval: TimeInterval {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1_000_000_000_000_000_000
    }
}
