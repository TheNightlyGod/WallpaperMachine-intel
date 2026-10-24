import Dispatch
import Foundation

/// Writes the Mac's memory-pressure events to the log, each with how much memory
/// the app itself was using and how many scenes it was presenting, and says when
/// a stretch of pressure begins and ends (`onPressureChanged`).
///
/// Nothing here unloads, pauses or stops a wallpaper that is on screen: the
/// footprint is for the whole process, so it cannot say which scene to blame,
/// and no threshold for acting on it has been measured. The one listener is
/// `WallpaperSpaceParking`, which lets go of the wallpapers it keeps paused for
/// other desktops while the pressure lasts. The lines tell a bug report whether
/// memory was short when something went wrong.
///
/// Event-driven: the system tells the source when the pressure level changes,
/// so there is no timer and no sampling. The lock-screen extension is another
/// process and is not observed.
@MainActor
final class MemoryPressureMonitor {
    enum Level: String {
        case normal, warning, critical

        /// The most severe level an event carries, or nil for an empty one.
        init?(_ event: DispatchSource.MemoryPressureEvent) {
            if event.contains(.critical) {
                self = .critical
            } else if event.contains(.warning) {
                self = .warning
            } else if event.contains(.normal) {
                self = .normal
            } else {
                return nil
            }
        }
    }

    /// One line the monitor writes, kept as facts until it is worded (`message`).
    enum Report: Equatable {
        /// Pressure at `level` began or changed, with the process footprint (nil when macOS did
        /// not answer) and the scenes being presented at that moment.
        case pressure(Level, footprint: UInt64?, scenes: Int)
        /// Pressure ended after `afterSeconds` whole seconds, with the footprint then.
        case recovered(afterSeconds: Int, footprint: UInt64?)

        /// Pressure is a warning; the return to normal is information.
        var isWarning: Bool {
            if case .pressure = self { true } else { false }
        }

        /// The line the log gets, in the shape `docs/features/diagnostics.md#memory-pressure`
        /// shows.
        var message: String {
            switch self {
            case let .pressure(level, footprint, scenes):
                "memory pressure \(level.rawValue): process footprint \(ProcessFootprint.describe(footprint)), "
                    + "\(scenes) scene\(scenes == 1 ? "" : "s") presenting"
            case let .recovered(seconds, footprint):
                "memory pressure normal after \(seconds) s: process footprint \(ProcessFootprint.describe(footprint))"
            }
        }
    }

    /// Repeats of the same level closer together than this are one line.
    static let collapseWindow: Duration = .seconds(5)

    private let footprint: () -> UInt64?
    private let presentingScenes: @MainActor () -> Int
    private let report: @MainActor (Report) -> Void
    private let now: @MainActor () -> ContinuousClock.Instant

    private var source: DispatchSourceMemoryPressure?
    /// When the stretch of pressure in progress began; nil while there is none.
    private var pressureBegan: ContinuousClock.Instant?
    /// Told `true` when the Mac reports pressure after none, and `false` when it reports normal
    /// again; repeats in between are not passed on.
    var onPressureChanged: (@MainActor (Bool) -> Void)?
    /// Whether a stretch of warning or critical pressure is in progress.
    var underPressure: Bool { pressureBegan != nil }
    private var lastLogged: (level: Level, at: ContinuousClock.Instant)?

    /// The closures are optional so their `@MainActor` defaults are built inside
    /// this initializer, in the actor's isolation.
    init(
        footprint: (() -> UInt64?)? = nil,
        presentingScenes: @escaping @MainActor () -> Int,
        report: (@MainActor (Report) -> Void)? = nil,
        now: (@MainActor () -> ContinuousClock.Instant)? = nil
    ) {
        self.footprint = footprint ?? { ProcessFootprint.current() }
        self.presentingScenes = presentingScenes
        self.report = report ?? { report in
            if report.isWarning { AppLog.warn(report.message) } else { AppLog.info(report.message) }
        }
        self.now = now ?? { ContinuousClock.now }
    }

    func start() {
        guard source == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical, .normal], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            guard let source else { return }
            // The source runs on the main queue.
            MainActor.assumeIsolated { self?.handle(source.data) }
        }
        self.source = source
        source.activate()
    }

    /// Cancels the source before anything else, so no event arrives for an app
    /// that is shutting down. A later `start()` begins with no pressure in progress.
    func stop() {
        source?.cancel()
        source = nil
        pressureBegan = nil
        lastLogged = nil
    }

    /// Scenes the renderer is drawing or waiting to draw, from the live per-scene
    /// read-back. A scene the user paused, the system suspended, that stopped after
    /// a failure or that could not be read is not presenting.
    static func presentingSceneCount(_ modes: [BridgeSceneUpdateModeReport]) -> Int {
        modes.filter { ["continuous", "waiting_for_event", "waiting_for_deadline"].contains($0.mode) }.count
    }

    /// Handles one event from the system. Called by the source's handler, and
    /// directly by tests.
    func handle(_ event: DispatchSource.MemoryPressureEvent) {
        guard let level = Level(event) else { return }
        let at = now()
        switch level {
        case .normal:
            // The Mac settling after pressure this never reported is not news. This
            // also means a second `normal` in a row is silent.
            guard let began = pressureBegan else { return }
            pressureBegan = nil
            lastLogged = (level, at)
            let seconds = Int(((at - began) / .seconds(1)).rounded())
            report(.recovered(afterSeconds: seconds, footprint: footprint()))
            onPressureChanged?(false)
        case .warning, .critical:
            if pressureBegan == nil {
                pressureBegan = at
                onPressureChanged?(true)
            }
            // A burst of the same level is one line; a change of level is always one.
            if let last = lastLogged, last.level == level, at - last.at < Self.collapseWindow { return }
            lastLogged = (level, at)
            report(.pressure(level, footprint: footprint(), scenes: presentingScenes()))
        }
    }
}
