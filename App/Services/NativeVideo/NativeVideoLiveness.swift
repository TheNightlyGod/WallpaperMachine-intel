import CoreMedia
import Foundation

/// What a short look at a playing pipeline concluded.
enum NativeVideoLiveness: Equatable {
    /// Frames are produced and the clock moves.
    case advancing
    /// Something that should be moving is not. The text says what was seen.
    case stalled(String)
    /// The player itself said it was waiting for data the whole time, which is
    /// a source that is slow to deliver rather than a pipeline that died. Not
    /// judged.
    case waiting(String)
}

/// Decides, from a handful of samples of a playing clip, whether its pipeline
/// is delivering pictures.
///
/// **The clock is not evidence.** A pipeline whose decoder never produces a
/// picture (an `hev1` clip on macOS 27, measured) still reports
/// `timeControlStatus == .playing` with a `currentTime` that advances, because
/// the clock belongs to the player and not to the decoder. Judging by time
/// alone would call that pipeline healthy. A verdict of `.advancing` therefore
/// needs both: a frame handed over by a video output, and a clock that moved.
///
/// Pure: samples go in, a verdict comes out. Taking the samples, and
/// deciding when to stop taking them, belongs to the caller.
struct NativeVideoLivenessEvaluator {
    /// One look at the pipeline.
    struct Sample {
        /// The playing item's position.
        var time: CMTime
        /// Which item that is. The loop replaces it at every boundary.
        var item: ObjectIdentifier
        /// A frame that nobody had read before was available at `time`.
        var producedFrame: Bool
        /// The player reports it is waiting for data to play.
        var waiting: Bool
    }

    /// How far the clock has to move to count. A little under one frame of a
    /// 30 fps clip: enough to tell a running clock from jitter, small enough
    /// that any clip passes it within a few samples.
    static let minimumAdvance = 1.0 / 30.0

    private(set) var sampleCount = 0
    private var waitingCount = 0
    private var frameSeen = false
    private var clockMoved = false
    /// Where the clock was when it was first seen with a usable value. A
    /// sample with no finite time (an item that has not loaded, a loop copy
    /// between items) anchors nothing and cannot show movement.
    private var anchor: (seconds: Double, item: ObjectIdentifier)?

    mutating func record(_ sample: Sample) {
        sampleCount += 1
        if sample.waiting { waitingCount += 1 }
        if sample.producedFrame { frameSeen = true }
        let seconds = sample.time.seconds
        guard seconds.isFinite else { return }
        guard let anchor else {
            anchor = (seconds, sample.item)
            return
        }
        // A new item means the loop moved on to its next copy, which only
        // happens when the previous one played to its end. Time going back is
        // the same wrap seen inside one item.
        if sample.item != anchor.item || seconds < anchor.seconds
            || seconds - anchor.seconds >= Self.minimumAdvance
        {
            clockMoved = true
        }
    }

    /// The verdict, once the samples so far already prove the pipeline works.
    /// Nothing short of proof settles early; a stall can only be concluded when
    /// the window ends.
    var verdict: NativeVideoLiveness? {
        frameSeen && clockMoved ? .advancing : nil
    }

    /// The verdict when the window ended without proof.
    func timedOut() -> NativeVideoLiveness {
        if let verdict { return verdict }
        guard sampleCount > 0 else {
            return .waiting("the player had no item to sample")
        }
        // A player that says it is waiting for data the whole time is not a
        // dead pipeline, and nudging it would only interrupt the load.
        if waitingCount == sampleCount {
            return .waiting("the player was waiting for data throughout")
        }
        switch (clockMoved, frameSeen) {
        case (true, false): return .stalled("the clock advances but no frame is produced")
        case (false, true): return .stalled("frames arrive but the clock does not advance")
        default: return .stalled("neither the clock nor the frames advance")
        }
    }
}
