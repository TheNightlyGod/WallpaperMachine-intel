import AppKit

/// Visibility of the wallpaper surface on one display.
struct WallpaperSurfaceVisibility: Equatable, Sendable {
    let displayID: UInt32
    let isVisible: Bool
}

/// Strongest global presentation wins: `.unloaded` > `.suspended` > `.running`.
enum GlobalPresentation: Comparable, Sendable {
    case running
    case suspended
    case unloaded

    private var rank: Int {
        switch self {
        case .running: 0
        case .suspended: 1
        case .unloaded: 2
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rank < rhs.rank
    }

    var logLabel: String {
        switch self {
        case .running: "resumed"
        case .suspended: "suspended"
        case .unloaded: "unloaded"
        }
    }
}

/// Suspends wallpaper presentation per display while no pixel from that display
/// can reach the user, or, unless the user chose to keep it running, while
/// other windows cover that display's working area, or, if the user chose to
/// play only where they are working, while the pointer is on another display
/// that still shows its wallpaper; and globally only for conditions that really
/// do cover every screen.
/// Suspension never changes the user's Play/Pause choice: the bridge composes
/// this signal with the playback state and restores playback when it clears.
///
/// The split matters for power: a window covering the wallpaper on one display
/// must stop that display's decoding and rendering, and must not stop a display
/// the user is still looking at. Display sleep, session lock, app rules and
/// other-app audio can also suspend or unload every display, and mute wallpaper
/// audio, without touching that choice. The user's own mute of every wallpaper silences them
/// as well, whatever the rules say, and leaves each wallpaper's saved sound alone.
///
/// A third channel, beside presentation and audio, carries the conditions that chose Reduced
/// quality (`QualityReduction`): wallpapers keep presenting, only at a lower frame-rate ceiling
/// and render scale. It is decided and acknowledged on its own, never changes
/// `globalPresentation` or `suspendedDisplayIDs`, and is released on `stop()`.
@MainActor
final class WallpaperPresentationPolicy {
    typealias ApplyCompletion = @MainActor (Result<Void, Error>) -> Void

    private let workspaceCenter: NotificationCenter
    private let lockCenter: NotificationCenter
    private let windowCenter: NotificationCenter
    private let surfaces: @MainActor () -> [WallpaperSurfaceVisibility]
    private let isSessionLocked: @MainActor () -> Bool
    private let displaySleepAction: @MainActor () -> DisplaySleepAction
    private let appRuleActions: @MainActor () -> Set<AppRuleAction>
    private let otherAudioActive: @MainActor () -> Bool
    private let otherAudioAction: @MainActor () -> OtherAudioAction
    private let userMuted: @MainActor () -> Bool
    private let desktopCoveredAction: @MainActor () -> DesktopCoveredAction
    private let coveredDisplays: @MainActor () -> Set<UInt32>
    private let inactiveDisplays: @MainActor (Set<UInt32>) -> Set<UInt32>
    private let screenLayout: @MainActor () -> [NSRect]
    private let requestedQualityReductions: @MainActor () -> Set<QualityReduction>
    /// Owned only when neither surfaces nor coverage were injected.
    private let probes: WallpaperCoverageProbes?
    private let occlusionSettleDelay: Duration
    private let counters: RuntimeCounters
    private let applyGlobal: @MainActor (GlobalPresentation, @escaping ApplyCompletion) -> Void
    private let applyAudio: @MainActor (Bool, @escaping ApplyCompletion) -> Void
    private let applyQuality: @MainActor (Set<QualityReduction>, @escaping ApplyCompletion) -> Void
    private let applyDisplay: @MainActor (UInt32, Bool, @escaping ApplyCompletion) -> Void

    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var displaysAsleep = false
    /// The session's lock state as the window server last reported it. Asking is a
    /// synchronous round trip, and evaluate() runs after every snapshot the engine
    /// applies, so it is asked again only where the answer can have changed: a lock
    /// or unlock, waking displays, a user switch, and every evaluation while the
    /// session counts as locked, so a stale lock can never hold the wallpaper.
    private var sessionLocked = false
    /// Set until the first evaluation, which covers a session locked before start().
    private var sessionLockStale = true
    /// The screens and working areas the last screen change found.
    private var evaluatedScreenLayout: [NSRect]?
    private var settle: Task<Void, Never>?
    private var appliedGlobal: GlobalPresentation? = .running
    private var appliedAudio: Bool? = false
    /// What the bridge was last told to reduce for; it starts unthrottled. Nil after a failed delivery.
    private var appliedQuality: Set<QualityReduction>? = []
    /// Acknowledged state per display. A display with no entry has never been
    /// told anything, so it is presenting.
    private var appliedDisplays: [UInt32: Bool] = [:]
    /// Displays whose decision still has to reach the renderer, including one
    /// whose delivery failed; a later evaluation retries it.
    private var pendingDisplays: Set<UInt32> = []
    /// Displays whose last delivery failed, so the renderer's state for them is unknown. Kept
    /// across a disconnect, as an acknowledged suspension is.
    private var failedDisplays: Set<UInt32> = []
    private var deliveryInFlight = false
    /// Conditions under which no display at all can present, and how hard.
    private(set) var globalPresentation: GlobalPresentation = .running
    /// Wallpaper audio held down by the user's mute of every wallpaper, a mute rule or other-app audio.
    private(set) var isAudioSuppressed = false
    /// The conditions asking for the reduced-quality profile, whatever presentation does.
    private(set) var qualityReductions: Set<QualityReduction> = []
    /// Displays suspended on their own, by occlusion or a covered working area.
    private(set) var suspendedDisplayIDs: Set<UInt32> = []

    /// True when presentation is suspended or unloaded. Occlusion of one display
    /// does not set this.
    var isSuspended: Bool { globalPresentation != .running }

    /// The suspended displays that something hides from the user (a full-screen app, a covered
    /// working area), leaving out the ones paused only because they chose to play where they work
    /// and are elsewhere. The unattended update alert waits for the first and not for the second.
    /// A display the user is not using that a full-screen app also fills is hidden: being idle
    /// by choice does not make that app's window any less in the way of a modal alert.
    var hiddenDisplayIDs: Set<UInt32> {
        suspendedDisplayIDs.subtracting(idleInPlainSight(surfaces()))
    }

    /// Whether the display is suspended only because the user is working on another one: its
    /// wallpaper is on screen, nothing covers it and no full-screen app is on it. A web page on
    /// such a display still owes it a first frame before it stops; on a hidden display it owes none.
    func isSuspendedInPlainSight(displayID: UInt32) -> Bool {
        idleInPlainSight(surfaces()).contains(displayID)
    }

    /// Called once the bridge has accepted a resume: the whole desktop running
    /// again after a suspend or unload, or one display running again after its
    /// own suspension. Not called for a suspension, for a first delivery to a
    /// display that was never told anything, for a resume the bridge refused
    /// (a refused one is delivered again and is announced when it lands), or for
    /// the resume `stop()` delivers on teardown.
    var onResumed: (@MainActor () -> Void)?

    /// Called once each time the session goes from locked to unlocked, after the decision that
    /// follows from it (`globalPresentation`) has been made. It comes from the corrected lock
    /// state and not from the unlock notification, so an unlock whose notification was lost is
    /// still reported by the next evaluation. Not called for a session that was already locked
    /// when `start()` ran (nothing was seen to unlock), nor for `stop()`. Callers must only read
    /// the policy from it: it runs inside `evaluate()`.
    var onSessionUnlocked: (@MainActor () -> Void)?

    /// Between `start()` and `stop()`.
    private var isRunning: Bool { !observers.isEmpty }

    /// Closures are optional so their `@MainActor` defaults are built inside
    /// this (already `@MainActor`) initializer rather than in a default-argument
    /// expression evaluated in the caller's isolation.
    init(
        workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        lockCenter: NotificationCenter = DistributedNotificationCenter.default(),
        windowCenter: NotificationCenter = .default,
        surfaces: (@MainActor () -> [WallpaperSurfaceVisibility])? = nil,
        isSessionLocked: (@MainActor () -> Bool)? = nil,
        displaySleepAction: (@MainActor () -> DisplaySleepAction)? = nil,
        appRuleActions: (@MainActor () -> Set<AppRuleAction>)? = nil,
        otherAudioActive: (@MainActor () -> Bool)? = nil,
        otherAudioAction: (@MainActor () -> OtherAudioAction)? = nil,
        userMuted: (@MainActor () -> Bool)? = nil,
        desktopCoveredAction: (@MainActor () -> DesktopCoveredAction)? = nil,
        coveredDisplays: (@MainActor () -> Set<UInt32>)? = nil,
        inactiveDisplays: (@MainActor (Set<UInt32>) -> Set<UInt32>)? = nil,
        screenLayout: (@MainActor () -> [NSRect])? = nil,
        qualityReductions: (@MainActor () -> Set<QualityReduction>)? = nil,
        occlusionSettleDelay: Duration = .seconds(1),
        counters: RuntimeCounters? = nil,
        applyGlobal: @escaping @MainActor (GlobalPresentation, @escaping ApplyCompletion) -> Void,
        applyAudio: (@MainActor (Bool, @escaping ApplyCompletion) -> Void)? = nil,
        applyQuality: (@MainActor (Set<QualityReduction>, @escaping ApplyCompletion) -> Void)? = nil,
        applyDisplay: @escaping @MainActor (UInt32, Bool, @escaping ApplyCompletion) -> Void
    ) {
        self.workspaceCenter = workspaceCenter
        self.lockCenter = lockCenter
        self.windowCenter = windowCenter
        self.surfaces = surfaces ?? { Self.systemSurfaces() }
        self.isSessionLocked = isSessionLocked ?? { Self.sessionIsLocked() }
        self.displaySleepAction = displaySleepAction ?? { .pause }
        self.appRuleActions = appRuleActions ?? { [] }
        self.otherAudioActive = otherAudioActive ?? { false }
        self.otherAudioAction = otherAudioAction ?? { .keepRunning }
        self.userMuted = userMuted ?? { false }
        self.desktopCoveredAction = desktopCoveredAction ?? { .keepRunning }
        if let coveredDisplays {
            self.coveredDisplays = coveredDisplays
            probes = nil
        } else if surfaces == nil {
            let probes = WallpaperCoverageProbes()
            self.coveredDisplays = { probes.coveredDisplayIDs() }
            self.probes = probes
        } else {
            self.coveredDisplays = { [] }
            probes = nil
        }
        self.inactiveDisplays = inactiveDisplays ?? { _ in [] }
        self.screenLayout = screenLayout ?? { Self.systemScreenLayout() }
        requestedQualityReductions = qualityReductions ?? { [] }
        self.occlusionSettleDelay = occlusionSettleDelay
        self.counters = counters ?? .shared
        self.applyGlobal = applyGlobal
        self.applyAudio = applyAudio ?? { _, completion in completion(.success(())) }
        self.applyQuality = applyQuality ?? { _, completion in completion(.success(())) }
        self.applyDisplay = applyDisplay
    }

    func start() {
        guard observers.isEmpty else { return }
        for (name, asleep) in [
            (NSWorkspace.screensDidSleepNotification, true),
            (NSWorkspace.screensDidWakeNotification, false),
        ] {
            observers.append((workspaceCenter, workspaceCenter.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.displaysAsleep = asleep
                    // A lock taken while the displays slept may have posted nothing.
                    if !asleep { self.sessionLockStale = true }
                    self.evaluate()
                }
            }))
        }
        // Switching users away and back changes the session without a lock notification.
        for name in [
            NSWorkspace.sessionDidResignActiveNotification,
            NSWorkspace.sessionDidBecomeActiveNotification,
        ] {
            observers.append((workspaceCenter, workspaceCenter.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.sessionLockChanged() }
            }))
        }
        for name in ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked"] {
            observers.append((lockCenter, lockCenter.addObserver(
                forName: .init(name), object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.sessionLockChanged() }
            }))
        }
        // object: nil — the control panel appearing over the desktop is exactly
        // what changes a wallpaper window's occlusion, and evaluate() recomputes
        // from every wallpaper window anyway.
        observers.append((windowCenter, windowCenter.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate() }
        }))
        // A resolution change or the Dock appearing moves the working area the
        // coverage probes measure.
        observers.append((windowCenter, windowCenter.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenParametersChanged() }
        }))
        evaluatedScreenLayout = screenLayout()
        evaluate()
    }

    /// An XDR display posts a screen change for every frame of an EDR headroom ramp.
    /// Only a screen or working area that moved changes what the policy decides from here.
    private func screenParametersChanged() {
        let layout = screenLayout()
        guard layout != evaluatedScreenLayout else { return }
        evaluatedScreenLayout = layout
        evaluate()
    }

    private func sessionLockChanged() {
        sessionLockStale = true
        evaluate()
    }

    func stop() {
        settle?.cancel()
        settle = nil
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        probes?.removeAll()
        displaysAsleep = false
        sessionLocked = false
        sessionLockStale = true
        evaluatedScreenLayout = nil
        // Teardown must never leave a surface suspended or muted.
        pendingDisplays.formUnion(suspendedDisplayIDs)
        suspendedDisplayIDs.removeAll()
        globalPresentation = .running
        isAudioSuppressed = false
        qualityReductions = []
        deliverPending()
    }

    /// Every window kind that hosts wallpaper pixels: the renderer's Metal
    /// window, the web wallpaper window, and the two native video windows (AVFoundation's and the
    /// WebM player's). A backend
    /// missing from this list is invisible to occlusion tracking, so its
    /// display would never be suspended or resumed.
    static let wallpaperWindowClassNames = [
        "MWEWallpaperDesktopWindow",
        "MWEWebWallpaperDesktopWindow",
        "MWENativeVideoDesktopWindow",
        "MWEWebMVideoDesktopWindow",
    ]

    static func isWallpaperWindow(_ window: NSWindow) -> Bool {
        wallpaperWindowClassNames.contains { name in
            NSClassFromString(name).map { window.isKind(of: $0) } ?? false
        }
    }

    static func wallpaperWindows() -> [NSWindow] {
        NSApp.windows.filter(isWallpaperWindow)
    }

    /// The wallpaper windows from the front one back, so a display that briefly has two (one
    /// replacing the other) lists the one on top first.
    static func orderedWallpaperWindows() -> [NSWindow] {
        NSApp.orderedWindows.filter(isWallpaperWindow)
    }

    /// Wallpaper visibility grouped by display. A display counts as visible
    /// when any of its wallpaper windows is visible, so a second window that
    /// AppKit reports as occluded cannot hide a live one.
    static func systemSurfaces() -> [WallpaperSurfaceVisibility] {
        var visibility: [UInt32: Bool] = [:]
        for window in wallpaperWindows() {
            guard let screen = window.screen,
                  let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else { continue }
            let displayID = number.uint32Value
            let visible = window.occlusionState.contains(.visible)
            visibility[displayID] = (visibility[displayID] ?? false) || visible
        }
        return visibility
            .map { WallpaperSurfaceVisibility(displayID: $0.key, isVisible: $0.value) }
            .sorted { $0.displayID < $1.displayID }
    }

    /// Each screen's frame and working area: what the coverage probes cover.
    static func systemScreenLayout() -> [NSRect] {
        NSScreen.screens.flatMap { [$0.frame, $0.visibleFrame] }
    }

    static func sessionIsLocked() -> Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool
            ?? false
    }

    /// Wallpaper visibility with a covered working area counted as hidden when
    /// the user chose to pause for it, and the displays the user is not using
    /// when they chose to play only on the one they are.
    private func currentSurfaces() -> [WallpaperSurfaceVisibility] {
        let current = surfaces()
        let hidden = hiddenFromView(current)
        let hiddenByPolicy = hidden.union(unusedDisplays(in: current, hidden: hidden))
        guard !hiddenByPolicy.isEmpty else { return current }
        return current.map { surface in
            hiddenByPolicy.contains(surface.displayID)
                ? WallpaperSurfaceVisibility(displayID: surface.displayID, isVisible: false)
                : surface
        }
    }

    /// The displays whose wallpaper the user cannot see, whichever display they are using: no
    /// pixel of it on screen (a full-screen app, another Space) or, when a covered working area
    /// pauses, other windows over that area.
    private func hiddenFromView(_ current: [WallpaperSurfaceVisibility]) -> Set<UInt32> {
        var hidden = Set(current.filter { !$0.isVisible }.map(\.displayID))
        if desktopCoveredAction() == .pause { hidden.formUnion(coveredDisplays()) }
        return hidden
    }

    /// The displays in `current` the user is not using, when they chose to play only where they
    /// are. Only while a display in use shows its wallpaper: hiding that display pauses it alone
    /// and leaves the others playing, and an answer that names every display, a mistake, cannot
    /// freeze the desktop.
    private func unusedDisplays(in current: [WallpaperSurfaceVisibility], hidden: Set<UInt32>) -> Set<UInt32> {
        let known = Set(current.map(\.displayID))
        let inactive = inactiveDisplays(known).intersection(known)
        return known.subtracting(inactive).isSubset(of: hidden) ? [] : inactive
    }

    /// The displays the user is not using whose wallpaper nothing else hides: on screen, not
    /// under a full-screen app and, when a covered working area pauses, not under other windows.
    /// Only for these is not being used the one reason to stop. A display that is idle and also
    /// hidden is not here, because its wallpaper would be stopped for the hiding alone.
    private func idleInPlainSight(_ current: [WallpaperSurfaceVisibility]) -> Set<UInt32> {
        let hidden = hiddenFromView(current)
        return unusedDisplays(in: current, hidden: hidden).subtracting(hidden)
    }

    /// Probes exist only while a covered desktop pauses, so keeping the
    /// wallpaper running costs no extra windows.
    private func syncProbes() {
        guard let probes, !observers.isEmpty else { return }
        if desktopCoveredAction() == .pause {
            probes.sync()
        } else {
            probes.removeAll()
        }
    }

    /// Retry unacknowledged delivery even when visibility is unchanged.
    func evaluate() {
        // Reported when evaluate() returns, whichever path it takes, so `globalPresentation` is
        // already settled for the callback.
        var unlocked = false
        defer { if unlocked { onSessionUnlocked?() } }
        syncProbes()
        if sessionLockStale || sessionLocked {
            let wasLocked = sessionLocked
            sessionLocked = isSessionLocked()
            sessionLockStale = false
            unlocked = wasLocked && !sessionLocked
            if unlocked { AppLog.info("session unlocked") }
        }
        let presentation = resolvedPresentation()
        let audio = resolvedAudioSuppressed()
        let quality = requestedQualityReductions()
        let current = currentSurfaces()
        let hidden = Set(current.filter { !$0.isVisible }.map(\.displayID))
        let known = Set(current.map(\.displayID))
        settle?.cancel()
        settle = nil

        // A display that is gone gets no decisions, but what was acknowledged
        // for it stays: the bridge and the web and video hosts keep a suspended
        // display suspended across a disconnect. When it returns visible it is
        // resumed; when it returns hidden it is still suspended and stays so.
        pendingDisplays.formIntersection(known)
        suspendedDisplayIDs.formIntersection(known)
        for displayID in known where (appliedDisplays[displayID] == true || failedDisplays.contains(displayID))
            && !suspendedDisplayIDs.contains(displayID)
        {
            if hidden.contains(displayID) {
                suspendedDisplayIDs.insert(displayID)
                // A suspension that never landed is sent again; an acknowledged one stands.
                if failedDisplays.contains(displayID) { pendingDisplays.insert(displayID) }
            } else {
                pendingDisplays.insert(displayID)
            }
        }

        // A wake or unlock may also reveal a display that was suspended on its own.
        // Adopt both decisions in this evaluation: no later window event is guaranteed.
        if presentation != globalPresentation {
            globalPresentation = presentation
            AppLog.info("presentation \(presentation.logLabel)")
        }
        if audio != isAudioSuppressed {
            isAudioSuppressed = audio
            AppLog.info("wallpaper audio \(audio ? "suppressed" : "restored")")
        }
        adopt(quality: quality)
        // Resume instantly; delay only occlusion-driven suspension so a Space
        // switch or a Mission Control pass does not freeze a visible wallpaper.
        let revealed = suspendedDisplayIDs.subtracting(hidden)
        let newlyHidden = hidden.subtracting(suspendedDisplayIDs)
        if !revealed.isEmpty {
            suspendedDisplayIDs.subtract(revealed)
            pendingDisplays.formUnion(revealed)
            AppLog.info("presentation resumed for displays \(revealed.sorted())")
        }
        guard !newlyHidden.isEmpty else {
            deliverPending()
            return
        }
        guard occlusionSettleDelay > .zero else {
            commitHidden(newlyHidden)
            return
        }
        settle = Task { [weak self] in
            guard let self else { return }
            do { try await Task.sleep(for: self.occlusionSettleDelay) } catch { return }
            guard !Task.isCancelled else { return }
            let stillHidden = Set(self.currentSurfaces().filter { !$0.isVisible }.map(\.displayID))
            self.commitHidden(newlyHidden.intersection(stillHidden))
        }
        deliverPending()
    }

    private func resolvedPresentation() -> GlobalPresentation {
        var strongest = GlobalPresentation.running
        if displaysAsleep {
            strongest = max(strongest, displaySleepAction() == .stop ? .unloaded : .suspended)
        }
        if sessionLocked {
            strongest = max(strongest, .suspended)
        }
        let rules = appRuleActions()
        if rules.contains(.stop) {
            strongest = max(strongest, .unloaded)
        } else if rules.contains(.pause) {
            strongest = max(strongest, .suspended)
        }
        if otherAudioActive(), otherAudioAction() == .pause {
            strongest = max(strongest, .suspended)
        }
        return strongest
    }

    /// The user's mute holds on its own; the rules and other-app audio each hold too, so turning
    /// the user's mute off while one of them still applies keeps the wallpapers silent.
    private func resolvedAudioSuppressed() -> Bool {
        if userMuted() { return true }
        if appRuleActions().contains(.mute) { return true }
        return otherAudioActive() && otherAudioAction() == .mute
    }

    /// Takes the conditions' current request as the decision, and says whether it changed.
    @discardableResult
    private func adopt(quality: Set<QualityReduction>) -> Bool {
        guard quality != qualityReductions else { return false }
        qualityReductions = quality
        AppLog.info(quality.isEmpty
            ? "wallpaper quality restored"
            : "wallpaper quality reduced for \(quality.sorted().map(\.logLabel).joined(separator: ", "))")
        return true
    }

    private func commitHidden(_ hidden: Set<UInt32>) {
        guard !hidden.isEmpty else {
            deliverPending()
            return
        }
        suspendedDisplayIDs.formUnion(hidden)
        pendingDisplays.formUnion(hidden)
        AppLog.info("presentation suspended for displays \(hidden.sorted())")
        deliverPending()
    }

    private func deliverPending() {
        guard !deliveryInFlight else { return }
        // The global condition is the coarser one, so it goes first. Audio
        // and quality follow, then per-display occlusion, one acknowledgement at a time.
        if appliedGlobal != globalPresentation {
            let presentation = globalPresentation
            let resumes = isRunning && presentation == .running && appliedGlobal != .running
            deliveryInFlight = true
            applyGlobal(presentation) { [self] result in
                deliveryInFlight = false
                guard case .success = result else {
                    // A failed bridge transaction may have rolled rendering
                    // back. Keep it pending for a later evaluation, and stop
                    // here: retrying now would spin on a rejecting renderer.
                    appliedGlobal = nil
                    return
                }
                appliedGlobal = presentation
                record(presentation != .running, for: RuntimeSurfaceKey(kind: .desktopScene, displayID: 0))
                if resumes { onResumed?() }
                // Deliveries are serialized, so the rest of the queue — and any
                // decision that changed while this one was in flight — follows
                // the acknowledgement.
                deliverPending()
            }
            return
        }
        if appliedAudio != isAudioSuppressed {
            let suppressed = isAudioSuppressed
            deliveryInFlight = true
            applyAudio(suppressed) { [self] result in
                deliveryInFlight = false
                guard case .success = result else {
                    appliedAudio = nil
                    return
                }
                appliedAudio = suppressed
                deliverPending()
            }
            return
        }
        if appliedQuality != qualityReductions {
            let reductions = qualityReductions
            deliveryInFlight = true
            applyQuality(reductions) { [self] result in
                deliveryInFlight = false
                guard case .success = result else {
                    // Kept pending like the others: a later evaluation sends it again.
                    appliedQuality = nil
                    return
                }
                appliedQuality = reductions
                deliverPending()
            }
            return
        }
        for displayID in pendingDisplays.sorted() {
            let target = suspendedDisplayIDs.contains(displayID)
            guard appliedDisplays[displayID] != target else {
                pendingDisplays.remove(displayID)
                continue
            }
            // A display never told anything was presenting; one whose last delivery
            // failed may have been suspended, so its resume counts.
            let resumes = isRunning && !target
                && (appliedDisplays[displayID] == true || failedDisplays.contains(displayID))
            deliveryInFlight = true
            applyDisplay(displayID, target) { [self] result in
                deliveryInFlight = false
                guard case .success = result else {
                    // Leave it pending. Retrying here would spin on a renderer
                    // that keeps rejecting the transition.
                    appliedDisplays[displayID] = nil
                    failedDisplays.insert(displayID)
                    return
                }
                appliedDisplays[displayID] = target
                failedDisplays.remove(displayID)
                record(target, for: RuntimeSurfaceKey(kind: .desktopScene, displayID: displayID))
                if resumes { onResumed?() }
                // The decision may have changed while this one was in flight,
                // in which case the display stays pending and is sent again.
                if appliedDisplays[displayID] == suspendedDisplayIDs.contains(displayID) {
                    pendingDisplays.remove(displayID)
                }
                deliverPending()
            }
            return
        }
    }

    private func record(_ suspended: Bool, for surface: RuntimeSurfaceKey) {
        counters.record(suspended ? .presentationSuspended : .presentationResumed, for: surface)
    }
}

/// The hosts that draw the bridge's committed wallpapers in windows of their own.
///
/// Presentation, global and per display, is folded into the `paused` of every
/// descriptor these hosts are given, but committing it returns no snapshot. A
/// host that read its descriptors while a change held (a snapshot applied under
/// a covered desktop, the status menu opening, the charger being plugged in)
/// keeps that paused reading after the change ends, and nothing else tells it.
/// Whoever delivers a presentation change to the bridge calls `reconcile()`
/// afterwards, once the bridge has committed it or failed to, so every host
/// reads again.
@MainActor
struct WallpaperHosts {
    var web: WebWallpaperHost?
    var native: NativeVideoWallpaperHost?

    func reconcile() {
        web?.reconcile()
        native?.reconcile()
    }
}
