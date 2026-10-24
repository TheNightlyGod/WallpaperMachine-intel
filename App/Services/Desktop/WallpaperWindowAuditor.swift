import AppKit

/// Notices, and records, a wallpaper window that macOS left on another Space,
/// off its display or out of the window server's composition after a Space
/// change, a wake or a display change.
///
/// Such a window does not announce itself. `WallpaperPresentationPolicy`
/// suspends a display whose window is not visible, so the symptom is a frozen
/// or missing wallpaper with a healthy renderer. Nothing here polls: a check
/// runs only after an event that can move windows, at a few fixed delays that
/// give the system time to settle, and stops at the first look where every
/// window is fine.
///
/// Detection and logging are always on. Repairing a window is off unless the
/// hidden preference `WallpaperMachine.reassertDesktopWindows` is set, because
/// moving windows can make the window server recompose and the failure has not
/// been reproduced on the macOS releases the app is tested on. The auditor
/// never acts where a window is legitimately not showing: while the
/// presentation policy has paused or unloaded the wallpaper, and on a display
/// whose current Space is a full-screen app's Space.
///
/// The wallpaper windows are this process's own `NSWindow`s, so reading them
/// needs no Accessibility permission.
@MainActor
final class WallpaperWindowAuditor {
    /// Set to true to let the auditor try to bring a faulty window back.
    static let repairKey = "WallpaperMachine.reassertDesktopWindows"

    /// What made the auditor look, named in the log.
    enum Trigger: String, Sendable {
        case activeSpaceDidChange
        case didWake
        case screensDidWake
        case screenParametersChanged
        /// The presentation policy let the wallpaper run again after pausing it.
        case presentationResumed
        /// A wallpaper window with a number the auditor had not seen.
        case windowOpened
    }

    /// The repair ladder. Each rung is tried only if the previous one did not
    /// bring the window back.
    enum RepairStep: Int, Sendable {
        case orderFront = 1
        case reassertLevelAndBehavior = 2

        var label: String {
            switch self {
            case .orderFront: "order front"
            case .reassertLevelAndBehavior: "reassert level and collection behavior, then order front"
            }
        }
    }

    /// One thing the auditor says, kept as facts until it is worded. The log line is made from
    /// these (`line`), so what the auditor concluded can be checked without parsing prose.
    struct Report: Equatable {
        enum Kind: Equatable {
            /// A window that is not showing, the first time this run sees it.
            case fault
            /// The last look still finds the same fault.
            case persisting
            /// A repair rung was applied to the window.
            case repaired(RepairStep)
            /// Every window shows, after at least one repair.
            case recovered
        }

        var kind: Kind
        var trigger: Trigger
        /// How long after the trigger the look that produced this was due.
        var offset: Duration
        /// The window the report is about; nil only for `recovered`, which is about all of them.
        var window: DesktopWindowObservation?
        /// Repairs this run had applied when the report was made.
        var repairsDone: Int

        /// The log line. Its shape is the one `docs/features/diagnostics.md` shows.
        var line: String {
            let label = "\(WallpaperWindowAuditor.offsetLabel(offset)) after \(trigger.rawValue)"
            let after = "after \(WallpaperWindowAuditor.count(repairsDone, "repair"))"
            let body: String
            switch (kind, window) {
            case let (.fault, window?):
                body = "\(Self.subject(window)) is \(window.state.rawValue) at \(label); "
                    + DesktopWindowDiagnostics.line(window)
            case let (.persisting, window?):
                body = "\(Self.subject(window)) is still \(window.state.rawValue) at \(label), \(after)"
            case let (.repaired(step), window?):
                body = "repair \(step.rawValue) (\(step.label)) applied to \(window.className) #\(window.windowNumber)"
            case (.recovered, _):
                body = "every wallpaper window is showing again at \(label), \(after)"
            default:
                body = "\(kind) at \(label)"
            }
            return "desktop window audit: " + body
        }

        private static func subject(_ window: DesktopWindowObservation) -> String {
            "display \(window.displayID.map(String.init) ?? "?") \(window.className) #\(window.windowNumber)"
        }
    }

    struct Policy: Sendable {
        /// Delays after a Space, wake or screen event at which windows are looked at.
        var checkOffsets: [Duration] = [.seconds(1), .seconds(3)]
        /// Delays after a new wallpaper window appears.
        var openOffsets: [Duration] = [.seconds(1), .seconds(2), .seconds(5)]
        /// Repairs one trigger may apply. The ladder has two rungs.
        var maximumRepairsPerTrigger = 2
        /// How long a report of the same fault on the same window is not repeated.
        var logInterval: Duration = .seconds(60)
    }

    typealias Sleep = @MainActor (Duration) async throws -> Void

    private let workspaceCenter: NotificationCenter
    private let displayCenter: NotificationCenter
    private let displayConfiguration: @MainActor () -> DisplayConfiguration
    private let windowNumbers: @MainActor () -> [Int]
    private let observe: @MainActor () -> [DesktopWindowObservation]
    private let canExpectVisible: @MainActor () -> Bool
    private let isDesktopSpace: @MainActor (UInt32?) -> Bool
    private let isConcealed: @MainActor (UInt32?) -> Bool
    private let isAwayFromCurrentDesktop: @MainActor (Int) -> Bool
    private let repairsEnabled: @MainActor () -> Bool
    private let repair: @MainActor (Int, RepairStep) -> Void
    private let sleep: Sleep
    private let now: @MainActor () -> ContinuousClock.Instant
    private let record: @MainActor (Report) -> Void
    private let policy: Policy

    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var started = false
    /// Bumped by every trigger and by `stop()`. A run whose number is no longer
    /// current has been superseded and does nothing more.
    private var generation = 0
    private var latest: Task<Void, Never>?
    private var knownWindowNumbers: Set<Int> = []
    private var lastDisplays: DisplayConfiguration?
    private var lastLogged: [LogKey: ContinuousClock.Instant] = [:]

    private struct Fault: Hashable {
        var windowNumber: Int
        var state: DesktopWindowState
    }

    private struct LogKey: Hashable {
        var displayID: UInt32?
        var windowNumber: Int
        var state: DesktopWindowState
        /// True for the line written when the last look still finds the fault.
        var persisting: Bool
    }

    /// Closures are optional so their `@MainActor` defaults are built inside
    /// this (already `@MainActor`) initializer rather than in a default-argument
    /// expression evaluated in the caller's isolation.
    init(
        workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        displayCenter: NotificationCenter = .default,
        defaults: UserDefaults? = nil,
        displayConfiguration: (@MainActor () -> DisplayConfiguration)? = nil,
        windowNumbers: (@MainActor () -> [Int])? = nil,
        observe: (@MainActor () -> [DesktopWindowObservation])? = nil,
        canExpectVisible: @escaping @MainActor () -> Bool,
        isDesktopSpace: @escaping @MainActor (UInt32?) -> Bool,
        isConcealed: (@MainActor (UInt32?) -> Bool)? = nil,
        isAwayFromCurrentDesktop: (@MainActor (Int) -> Bool)? = nil,
        repairsEnabled: (@MainActor () -> Bool)? = nil,
        repair: (@MainActor (Int, RepairStep) -> Void)? = nil,
        sleep: Sleep? = nil,
        now: (@MainActor () -> ContinuousClock.Instant)? = nil,
        record: (@MainActor (Report) -> Void)? = nil,
        policy: Policy = Policy()
    ) {
        self.workspaceCenter = workspaceCenter
        self.displayCenter = displayCenter
        self.displayConfiguration = displayConfiguration ?? { DisplayConfiguration.current() }
        self.windowNumbers = windowNumbers ?? {
            WallpaperPresentationPolicy.wallpaperWindows().map(\.windowNumber).filter { $0 > 0 }
        }
        self.observe = observe ?? { DesktopWindowReader.current() }
        self.canExpectVisible = canExpectVisible
        self.isDesktopSpace = isDesktopSpace
        self.isConcealed = isConcealed ?? { _ in false }
        self.isAwayFromCurrentDesktop = isAwayFromCurrentDesktop ?? { _ in false }
        let preferences = defaults ?? ClientPreferences.defaults
        self.repairsEnabled = repairsEnabled ?? { preferences.bool(forKey: Self.repairKey) }
        self.repair = repair ?? { Self.apply($1, toWindowNumbered: $0) }
        self.sleep = sleep ?? { try await Task.sleep(for: $0) }
        self.now = now ?? { ContinuousClock.now }
        self.record = record ?? { AppLog.warn($0.line) }
        self.policy = policy
    }

    func start() {
        guard !started else { return }
        started = true
        let names: [(NotificationCenter, Notification.Name, Trigger)] = [
            (workspaceCenter, NSWorkspace.activeSpaceDidChangeNotification, .activeSpaceDidChange),
            (workspaceCenter, NSWorkspace.didWakeNotification, .didWake),
            (workspaceCenter, NSWorkspace.screensDidWakeNotification, .screensDidWake),
        ]
        for (center, name, trigger) in names {
            observers.append((center, center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.begin(trigger, offsets: self?.policy.checkOffsets ?? []) }
            }))
        }
        observers.append((displayCenter, displayCenter.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenParametersChanged() }
        }))
        lastDisplays = displayConfiguration()
        // Windows that opened before the auditor started count as new.
        windowsMayHaveChanged()
    }

    func stop() {
        started = false
        generation += 1
        latest?.cancel()
        latest = nil
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        knownWindowNumbers.removeAll()
        lastDisplays = nil
        lastLogged.removeAll()
    }

    /// Call when a wallpaper window may have opened. A window number the
    /// auditor has not seen starts a check; the same windows, or fewer, do not.
    func windowsMayHaveChanged() {
        guard started else { return }
        let current = Set(windowNumbers())
        let opened = current.subtracting(knownWindowNumbers)
        knownWindowNumbers = current
        guard !opened.isEmpty else { return }
        begin(.windowOpened, offsets: policy.openOffsets)
    }

    /// Call when presentation runs again after the policy paused or unloaded
    /// it. A wake usually lands on a locked session, where a look at the
    /// wake itself finds nothing expected on screen and ends; the unlock is
    /// when the windows are expected to show.
    func presentationResumed() {
        begin(.presentationResumed, offsets: policy.checkOffsets)
    }

    /// Resolves when the check the latest trigger scheduled has finished. For
    /// tests, which drive the checks with an injected sleep.
    func waitForSchedule() async {
        await latest?.value
    }

    /// An XDR display posts a screen change for every frame of an EDR headroom
    /// ramp. Only a display that came, went or moved can move a window.
    private func screenParametersChanged() {
        let current = displayConfiguration()
        guard current != lastDisplays else { return }
        lastDisplays = current
        begin(.screenParametersChanged, offsets: policy.checkOffsets)
    }

    private func begin(_ trigger: Trigger, offsets: [Duration]) {
        guard started else { return }
        generation += 1
        let generation = generation
        latest?.cancel()
        latest = Task { [weak self] in
            await self?.run(trigger, offsets: offsets, generation: generation)
        }
    }

    private func run(_ trigger: Trigger, offsets: [Duration], generation: Int) async {
        var elapsed = Duration.zero
        var repairsDone = 0
        /// Faults this run has already reported, so a later look at the same
        /// fault is the persistence line rather than a second first report.
        var reported: Set<Fault> = []
        for (index, offset) in offsets.enumerated() {
            guard started, generation == self.generation else { return }
            do { try await sleep(max(offset - elapsed, .zero)) } catch { return }
            elapsed = max(elapsed, offset)
            guard started, generation == self.generation else { return }
            // Deliberately paused, unloaded or asleep: nothing is expected on screen.
            guard canExpectVisible() else { return }
            func made(_ kind: Report.Kind, _ window: DesktopWindowObservation?) -> Report {
                Report(kind: kind, trigger: trigger, offset: offset, window: window, repairsDone: repairsDone)
            }
            let notShowing = observe().filter { $0.state != .ok }
            let faulty = notShowing.filter { !isExcused($0) }
            guard !faulty.isEmpty else {
                if notShowing.isEmpty, repairsDone > 0 { record(made(.recovered, nil)) }
                return
            }
            let isLast = index == offsets.count - 1
            for window in faulty {
                let fault = Fault(windowNumber: window.windowNumber, state: window.state)
                if reported.insert(fault).inserted {
                    report(made(.fault, window))
                } else if isLast {
                    report(made(.persisting, window))
                }
            }
            guard repairsEnabled(), repairsDone < policy.maximumRepairsPerTrigger,
                  let step = RepairStep(rawValue: repairsDone + 1) else { continue }
            repairsDone += 1
            for window in faulty {
                repair(window.windowNumber, step)
                record(made(.repaired(step), window))
            }
        }
    }

    /// A window the system legitimately does not show. In a full-screen app's
    /// Space the desktop windows are on another Space and not composited, so
    /// neither fault means anything there. A display that follows desktop Spaces
    /// hides its windows while the desktop's own wallpaper loads, and keeps the
    /// wallpaper of a desktop the person left paused on that desktop.
    private func isExcused(_ window: DesktopWindowObservation) -> Bool {
        switch window.state {
        case .notOnActiveSpace, .offScreenInWindowServer:
            !isDesktopSpace(window.displayID) || isAwayFromCurrentDesktop(window.windowNumber)
        case .transparent: isConcealed(window.displayID)
        default: false
        }
    }

    /// Records a fault report unless the same fault on the same window was
    /// recorded within the log interval.
    private func report(_ report: Report) {
        guard let window = report.window else { return }
        let key = LogKey(displayID: window.displayID, windowNumber: window.windowNumber,
                         state: window.state, persisting: report.kind == .persisting)
        let instant = now()
        if let last = lastLogged[key], instant - last < policy.logInterval { return }
        lastLogged = lastLogged.filter { instant - $0.value < policy.logInterval }
        lastLogged[key] = instant
        record(report)
    }

    nonisolated fileprivate static func count(_ number: Int, _ noun: String) -> String {
        "\(number) \(noun)\(number == 1 ? "" : "s")"
    }

    /// `+3s`, `+0.5s`.
    nonisolated fileprivate static func offsetLabel(_ offset: Duration) -> String {
        let parts = offset.components
        let seconds = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
        let text = String(format: "%.1f", seconds)
        return "+" + (text.hasSuffix(".0") ? String(text.dropLast(2)) : text) + "s"
    }

    /// Whether the display's current Space is an ordinary desktop, where the
    /// wallpaper windows are expected on screen. False only when the Space
    /// topology says the Space is a full-screen app's. Unknown reads as a
    /// desktop, so a fault is still recorded when the topology is unavailable.
    ///
    /// A window on no display has no Space of its own to read; it counts as a
    /// desktop only if no display is in a full-screen Space.
    nonisolated static func spaceIsDesktop(
        displayID: UInt32?, available: Bool, displays: [String: WallpaperDisplaySpaces]
    ) -> Bool {
        guard available else { return true }
        guard let displayID else { return !displays.values.contains { $0.current == nil } }
        guard let spaces = displays[String(displayID)] else { return true }
        return spaces.current != nil
    }

    static func spaceIsDesktop(displayID: UInt32?, in monitor: WallpaperSpaceMonitor) -> Bool {
        spaceIsDesktop(displayID: displayID, available: monitor.available, displays: monitor.displays)
    }

    /// Applies one rung of the repair ladder to the live window.
    private static func apply(_ step: RepairStep, toWindowNumbered number: Int) {
        guard let window = WallpaperPresentationPolicy.wallpaperWindows().first(where: { $0.windowNumber == number })
        else { return }
        if step == .reassertLevelAndBehavior {
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
            // A window pinned to its desktop for Space selection stays pinned.
            let joinsAllSpaces = window.collectionBehavior.contains(.canJoinAllSpaces)
            var behavior: NSWindow.CollectionBehavior = [.stationary, .fullScreenAuxiliary, .ignoresCycle]
            if joinsAllSpaces { behavior.insert(.canJoinAllSpaces) }
            window.collectionBehavior = behavior
        }
        window.orderFrontRegardless()
    }
}
