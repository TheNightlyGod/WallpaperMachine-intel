import Foundation

/// Which wallpaper surface a counter belongs to. Display identity is the stable
/// `CGDirectDisplayID`; `generation` separates two surfaces that reused one
/// display id across a hot-plug or a wallpaper switch.
struct RuntimeSurfaceKey: Hashable, Sendable {
    enum Kind: String, Sendable {
        case desktopScene
        case desktopWeb
        case desktopNativeVideo
        case lockScreen
        case preview
    }

    let kind: Kind
    let displayID: UInt32
    let generation: UInt64

    init(kind: Kind, displayID: UInt32, generation: UInt64 = 0) {
        self.kind = kind
        self.displayID = displayID
        self.generation = generation
    }
}

/// The events this project counts to decide whether invisible work actually
/// stopped. Every case is incremented by production code; there are no
/// placeholders for metrics nothing reports yet.
enum RuntimeCounter: String, CaseIterable, Sendable {
    /// An effective-suspend decision was delivered to the renderer or page.
    case presentationSuspended
    /// An effective-resume decision was delivered.
    case presentationResumed
    /// A page was asked to suspend media playback through the host API.
    case webMediaSuspended
    case webMediaResumed
    /// A web view left the window tree so WebKit can apply its inactive policy.
    case webDetached
    case webAttached
    /// A `WKWebView` was constructed for a display.
    case webPageCreated
    /// Committed host state was replayed into a new document generation.
    case webStateReplayed
    /// A content-process termination started a restart.
    case webRecoveryStarted
    /// The restart budget rejected a further restart within its window.
    case webRecoveryBudgetExhausted
    /// A pointer sample reached a surface.
    case pointerDelivered
    /// A lock-screen or preview surface was allowed to keep presenting.
    case presentationAuthorized
    /// A surface produced the one frame a readiness or snapshot request needs,
    /// which is deliberately not the same as being allowed to keep presenting.
    case readinessFrameRendered
    /// A native player item was created for a surface, and released again.
    /// Creation and release are counted separately so a leaked player is
    /// visible as a difference rather than inferred.
    case nativeVideoItemCreated
    case nativeVideoItemReleased
    /// The native video host could not play a wallpaper and reported the display as
    /// failed, with the reason; the display keeps the picture it had.
    case nativeVideoRefused
    /// Reading a clip's metadata did not finish within the limit for its
    /// storage, so the host stopped waiting and handed the wallpaper over. A
    /// count on an internal drive means the read is genuinely stuck; on a
    /// network share or an evicted cloud file it may only be slow.
    case nativeVideoProbeTimeout
    /// A clip's first-frame deadline passed with nothing on the layer. The first
    /// miss restarts the player; a second, or a restart the recovery budget
    /// refused, hands the wallpaper to the scene engine. A count of one with no
    /// refusal means a restart brought the picture; on an internal drive any
    /// count means the pipeline stalled, while on a share or a cloud file the
    /// file may only have been slow to arrive.
    case nativeVideoFirstFrameTimeout
    /// A poster request was answered by a one-shot image generator instead of
    /// the item that is playing, which is a second decode of a few frames.
    /// Either the playing item produced no frame in time, or the clip is
    /// rotated or mirrored and the generator is the only path that returns it
    /// upright: for such a clip every poster counts here by design, so a
    /// steady count on one is not a fault. Counted so a fallback that became
    /// the normal path for an upright clip is visible instead of being
    /// inferred from CPU use.
    case nativeVideoPosterFallback
    /// A clip that had shown a picture was checked after a long pause or a
    /// wake and its pipeline delivered none, although the player reported it
    /// was playing. Counted once per check, at the first look, before anything
    /// is repaired. A steady zero over many long suspensions means the decoder
    /// survives them; a count says it does not, and how often.
    case nativeVideoPlaybackStalled
    /// The first repair of a stalled pipeline: a zero-tolerance seek to where
    /// it is, then play. Compare with `nativeVideoPlaybackStalled`: a kick for
    /// every stall means the cheap repair is enough.
    case nativeVideoPlaybackKick
    /// The second repair, after the kick did not bring pictures: the player's
    /// item and looper were rebuilt from the file. Spends the surface's
    /// recovery allowance, like a first-frame restart does, but is counted
    /// apart from it.
    case nativeVideoPlaybackRebuild
}

/// Time-limited, aggregated runtime counters. Off by default: recording happens
/// only inside an explicitly opened diagnostic session, so release builds carry
/// no per-frame bookkeeping. Counts are per surface and the surface table is
/// bounded; overflow is reported rather than silently growing.
///
/// This is the observability half of the power work: a claim that hidden
/// surfaces stopped working has to be readable from `snapshot()` rather than
/// inferred from CPU graphs. It is compiled into both the application and the
/// lock-screen extension, so the two processes count the same events the same
/// way instead of growing separate vocabularies.
@MainActor
final class RuntimeCounters {
    static let shared = RuntimeCounters()

    static let maximumTrackedSurfaces = 16

    struct Snapshot: Equatable, Sendable {
        var isRecording = false
        var sessionElapsed: Duration = .zero
        var surfaces: [RuntimeSurfaceKey: [RuntimeCounter: UInt64]] = [:]
        /// Increments recorded for surfaces evicted by the table bound.
        var droppedSurfaceEvents: UInt64 = 0

        func value(_ counter: RuntimeCounter, for surface: RuntimeSurfaceKey) -> UInt64 {
            surfaces[surface]?[counter] ?? 0
        }

        func total(_ counter: RuntimeCounter) -> UInt64 {
            surfaces.values.reduce(0) { $0 + ($1[counter] ?? 0) }
        }
    }

    private let now: @MainActor () -> ContinuousClock.Instant
    private var sessionStart: ContinuousClock.Instant?
    private var sessionDuration: Duration = .zero
    private var counts: [RuntimeSurfaceKey: [RuntimeCounter: UInt64]] = [:]
    /// Insertion order, so the bound evicts the least recently seen surface.
    private var order: [RuntimeSurfaceKey] = []
    private var droppedSurfaceEvents: UInt64 = 0

    init(now: (@MainActor () -> ContinuousClock.Instant)? = nil) {
        self.now = now ?? { ContinuousClock.now }
    }

    /// Opens a recording session that expires on its own. A session is bounded
    /// so a forgotten diagnostic switch cannot keep counting forever.
    func startSession(duration: Duration) {
        guard duration > .zero else { return }
        counts.removeAll()
        order.removeAll()
        droppedSurfaceEvents = 0
        sessionStart = now()
        sessionDuration = duration
    }

    func endSession() {
        sessionStart = nil
        sessionDuration = .zero
    }

    var isRecording: Bool {
        guard let sessionStart else { return false }
        return now() - sessionStart < sessionDuration
    }

    func record(_ counter: RuntimeCounter, for surface: RuntimeSurfaceKey, by amount: UInt64 = 1) {
        guard amount > 0, isRecording else { return }
        if counts[surface] == nil {
            if order.count >= Self.maximumTrackedSurfaces {
                let evicted = order.removeFirst()
                droppedSurfaceEvents += counts.removeValue(forKey: evicted)?.values.reduce(0, +) ?? 0
            }
            order.append(surface)
            counts[surface] = [:]
        }
        counts[surface, default: [:]][counter, default: 0] += amount
    }

    func snapshot() -> Snapshot {
        var snapshot = Snapshot()
        snapshot.isRecording = isRecording
        if let sessionStart { snapshot.sessionElapsed = now() - sessionStart }
        snapshot.surfaces = counts
        snapshot.droppedSurfaceEvents = droppedSurfaceEvents
        return snapshot
    }

    /// One aggregated line per surface, in the field order
    /// [docs/testing/power-benchmark.md](../../../docs/testing/power-benchmark.md)
    /// documents. Never emitted per frame.
    func aggregatedReport() -> [String] {
        order.compactMap { surface in
            guard let values = counts[surface], !values.isEmpty else { return nil }
            let fields = RuntimeCounter.allCases
                .compactMap { counter -> String? in
                    guard let value = values[counter], value > 0 else { return nil }
                    return "\(counter.rawValue)=\(value)"
                }
            return "surface=\(surface.kind.rawValue)/\(surface.displayID)"
                + "/gen\(surface.generation) " + fields.joined(separator: " ")
        }
    }
}
