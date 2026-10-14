import Foundation

/// Turns the byte totals of a running transfer into a "time left" estimate. It has no clock of
/// its own: every sample carries the time it was taken, so the downloader's injectable clock
/// decides what a second is.
///
/// The speed is the bytes gained across the last `window` seconds of samples, smoothed with an
/// exponentially weighted average across calls so one burst or one quiet moment does not swing the
/// estimate. Nothing is estimated until the window spans `minimumSpan` seconds, while the
/// transfer crawls below `minimumSpeed`, or when nothing is left to fetch: a figure built on a
/// guess reads worse than none.
struct TransferEstimator {
    /// How much history the speed is measured over, in seconds.
    static let window: TimeInterval = 20
    /// The history a first estimate needs, in seconds.
    static let minimumSpan: TimeInterval = 4
    /// Below this the transfer is treated as stalled, in bytes per second.
    static let minimumSpeed = 1_000.0
    /// How much of each new reading the smoothed speed takes on.
    static let smoothing = 0.3
    /// The longest estimate worth showing, in seconds (99 hours).
    static let ceiling = 99 * 3_600

    private struct Sample {
        let time: TimeInterval
        let bytes: Int64
    }

    private var samples: [Sample] = []
    private var smoothedSpeed: Double?

    /// Records the bytes received so far at `time`. A total that drops means the counter started
    /// over (a new process, a new phase), so the history it was built on no longer applies.
    mutating func add(bytes: Int64, at time: TimeInterval) {
        if let last = samples.last {
            if bytes < last.bytes { reset() }
            else if time <= last.time { return }
        }
        samples.append(Sample(time: time, bytes: bytes))
        samples.removeAll { time - $0.time > Self.window }
        guard let first = samples.first, let last = samples.last, last.time - first.time >= 1 else { return }
        let measured = Double(last.bytes - first.bytes) / (last.time - first.time)
        smoothedSpeed = smoothedSpeed.map { $0 + Self.smoothing * (measured - $0) } ?? measured
    }

    mutating func reset() {
        samples.removeAll()
        smoothedSpeed = nil
    }

    /// Whole seconds until `remaining` more bytes have arrived at the current pace, or nil while
    /// there is no trustworthy pace.
    func secondsRemaining(remaining: Int64) -> Int? {
        guard remaining > 0, let first = samples.first, let last = samples.last,
              last.time - first.time >= Self.minimumSpan,
              let speed = smoothedSpeed, speed >= Self.minimumSpeed else { return nil }
        let seconds = (Double(remaining) / speed).rounded(.up)
        return seconds >= Double(Self.ceiling) ? Self.ceiling : Int(seconds)
    }
}
