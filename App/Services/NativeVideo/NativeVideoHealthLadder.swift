import Foundation

/// What to do next about a pipeline that a health check found wanting.
///
/// The repairs are ordered by what they cost the picture. A check that finds
/// pictures flowing needs none. A seek and a `play()` are invisible when they
/// work. Rebuilding the player's item blanks the layer until the new item shows
/// its first frame, and spends the surface's recovery allowance, so it is only
/// tried when the kick did not help. When both are spent, the display is
/// reported as failed.
///
/// Pure: each verdict goes in, the next step comes out. Looking at the pipeline
/// again, waiting between looks and carrying the step out belong to the caller.
struct NativeVideoHealthLadder: Equatable {
    enum Action: Equatable {
        /// Pictures flow; nothing more to do.
        case done
        /// The player said it was waiting for data. Look again before judging.
        case recheck
        /// Seek to where the clip is and play, which restarts a stuck output.
        case kick
        /// Rebuild the item and looper from the file.
        case rebuild
        /// Nothing left to try. The text says what was seen and what was tried.
        case giveUp(String)
    }

    /// How many more looks a pipeline gets while it only says it is waiting. A
    /// disk that is spinning up or a share that is answering slowly looks like
    /// this, and nudging it would only interrupt the load; but a player that
    /// waits for data from a local file for this long after a resume is stuck
    /// rather than slow.
    static let waitingRechecks = 2

    private(set) var rechecks = 0
    private(set) var kicked = false
    private(set) var rebuilt = false

    /// Whether a repair has been issued. A ladder that has acted is not
    /// started over by a newer trigger: the look that follows the repair
    /// already answers what the trigger would ask.
    var hasRepaired: Bool { kicked || rebuilt }

    /// The next step for `liveness`, the result of the latest look.
    /// `canRebuild` is whether the surface can still afford a rebuild.
    mutating func next(_ liveness: NativeVideoLiveness, canRebuild: Bool) -> Action {
        let detail: String
        switch liveness {
        case .advancing:
            return .done
        case let .waiting(waiting):
            if rechecks < Self.waitingRechecks {
                rechecks += 1
                return .recheck
            }
            detail = "\(waiting), in each of \(Self.waitingRechecks + 1) looks"
        case let .stalled(stalled):
            detail = stalled
        }
        if !kicked {
            kicked = true
            return .kick
        }
        if !rebuilt {
            guard canRebuild else {
                return .giveUp("\(detail); a kick did not help and no rebuild is left")
            }
            rebuilt = true
            return .rebuild
        }
        return .giveUp("\(detail); a kick and a rebuild did not help")
    }
}
