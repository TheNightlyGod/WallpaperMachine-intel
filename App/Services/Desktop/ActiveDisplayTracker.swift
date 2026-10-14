import AppKit

/// Tells which display the user is using, for the option that plays a wallpaper only there.
/// The display under the pointer is the active one. Moving onto a display makes it active at
/// once; the display the pointer left stays active for `dwell` more, so skimming across a
/// display, or going back to it, never pauses it. Every other display is inactive.
///
/// Nothing runs until `setEnabled(true)` and two displays are connected: the pointer monitors, the
/// activation observers and the screen observer exist only then, and a pointer event that stays on
/// the same display costs one rectangle test. Pointer events carry no permission: the global monitor
/// sees mouse events without Accessibility or Input Monitoring.
///
/// Event monitors have a gap while this app is the active one: AppKit hands pointer events to the
/// app, so a global monitor sees none of them, and a local monitor sees only the motion a window of
/// the app asked for. Motion over a display's desktop is not that, so while the app is active the
/// tracker also reads the pointer on a tolerant timer, and it reads it once when the app becomes or
/// stops being active. The renderer's pointer sampler closes the same gap the same way.
///
/// The tracker only reports; `WallpaperPresentationPolicy` turns the inactive displays into one more
/// reason a display is hidden, so Play and Pause are never involved and nothing needs restoring.
@MainActor
final class ActiveDisplayTracker {
    struct Screen: Equatable, Sendable {
        var id: UInt32
        var frame: CGRect
    }

    /// Calls the handler for every pointer event that can have moved the pointer, and returns the
    /// function that stops that.
    typealias InstallMonitor = @MainActor (@escaping @MainActor () -> Void) -> @MainActor () -> Void
    typealias Sleep = @Sendable (Duration) async throws -> Void

    /// Called when the set of displays that count as active changed.
    var onChange: (@MainActor () -> Void)?

    private let screens: @MainActor () -> [Screen]
    private let pointer: @MainActor () -> CGPoint
    private let installMonitor: InstallMonitor
    private let notificationCenter: NotificationCenter
    private let isAppActive: @MainActor () -> Bool
    private let dwell: Duration
    private let sleep: Sleep
    private let pollInterval: Duration
    private let pollSleep: Sleep

    private var enabled = false
    private var removeMonitor: (@MainActor () -> Void)?
    private var screenObserver: NSObjectProtocol?
    private var activationObservers: [NSObjectProtocol] = []
    /// Reads the pointer on a timer; exists only while tracking and this app is active.
    private var polling: Task<Void, Never>?
    private var knownScreens: [Screen] = []
    /// The display the pointer is on. Nil while nothing is tracked, and while the pointer is
    /// outside every screen at the moment tracking starts.
    private(set) var pointerDisplay: UInt32?
    private var pointerFrame: CGRect?
    /// Displays the pointer left less than `dwell` ago, each with the task that ends its wait.
    private var lingering: [UInt32: Task<Void, Never>] = [:]

    /// Closures are optional so their `@MainActor` defaults are built inside this initializer.
    init(
        screens: (@MainActor () -> [Screen])? = nil,
        pointer: (@MainActor () -> CGPoint)? = nil,
        installMonitor: InstallMonitor? = nil,
        notificationCenter: NotificationCenter = .default,
        isAppActive: (@MainActor () -> Bool)? = nil,
        dwell: Duration = .seconds(3),
        sleep: @escaping Sleep = { try await Task.sleep(for: $0, tolerance: .milliseconds(500)) },
        pollInterval: Duration = .milliseconds(250),
        pollSleep: @escaping Sleep = { try await Task.sleep(for: $0, tolerance: .milliseconds(100)) }
    ) {
        self.screens = screens ?? { Self.systemScreens() }
        self.pointer = pointer ?? { NSEvent.mouseLocation }
        self.installMonitor = installMonitor ?? { Self.systemMonitor($0) }
        self.notificationCenter = notificationCenter
        self.isAppActive = isAppActive ?? { NSApplication.shared.isActive }
        self.dwell = dwell
        self.sleep = sleep
        self.pollInterval = pollInterval
        self.pollSleep = pollSleep
    }

    /// True while a pointer monitor is installed.
    var isTracking: Bool { removeMonitor != nil }

    /// Starts or ends tracking. Ending it makes every display active again, and says so.
    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        let before = activeDisplays
        enabled = on
        if on {
            screenObserver = notificationCenter.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.reconcile() }
            }
            reconcile()
        } else {
            if let screenObserver { notificationCenter.removeObserver(screenObserver) }
            screenObserver = nil
            stopTracking()
            notify(from: before)
        }
    }

    /// Ends tracking for good, without telling anyone: whoever is shutting down resumes the displays.
    func stop() {
        onChange = nil
        setEnabled(false)
    }

    /// The displays among `known` that are not being used: none while nothing is tracked, and none
    /// while the pointer is on a screen that is not among `known`, so a display the app does not
    /// manage under the pointer pauses nothing.
    func inactive(among known: Set<UInt32>) -> Set<UInt32> {
        guard let pointerDisplay, known.contains(pointerDisplay) else { return [] }
        return known.subtracting(lingering.keys).subtracting([pointerDisplay])
    }

    // MARK: - Screens

    /// Reads the screens again: tracks only while two or more are connected, forgets displays that
    /// are gone, and finds the display under the pointer.
    private func reconcile() {
        guard enabled else { return }
        let before = activeDisplays
        let current = screens()
        guard current.count >= 2 else {
            stopTracking()
            notify(from: before)
            return
        }
        // An XDR display posts a screen change for every frame of an EDR headroom ramp.
        guard current != knownScreens || removeMonitor == nil else { return }
        knownScreens = current
        if removeMonitor == nil {
            removeMonitor = installMonitor { [weak self] in self?.pointerMoved() }
            observeActivation()
        }
        let present = Set(current.map(\.id))
        for display in lingering.keys where !present.contains(display) {
            lingering.removeValue(forKey: display)?.cancel()
        }
        if let pointerDisplay, !present.contains(pointerDisplay) { self.pointerDisplay = nil }
        pointerFrame = current.first { $0.id == pointerDisplay }?.frame
        if let screen = current.first(where: { $0.frame.contains(pointer()) }) { enter(screen) }
        notify(from: before)
    }

    private func stopTracking() {
        removeMonitor?()
        removeMonitor = nil
        for observer in activationObservers { notificationCenter.removeObserver(observer) }
        activationObservers = []
        setPolling(false)
        for task in lingering.values { task.cancel() }
        lingering.removeAll()
        pointerDisplay = nil
        pointerFrame = nil
        knownScreens = []
    }

    // MARK: - Pointer

    /// Watches this app become and stop being the active one, the times the event monitors can miss
    /// the pointer, and starts the timer when the app is active already.
    private func observeActivation() {
        activationObservers = [(NSApplication.didBecomeActiveNotification, true), (NSApplication.didResignActiveNotification, false)]
            .map { name, active in
                notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.appActivityChanged(active) }
                }
            }
        setPolling(isAppActive())
    }

    /// Events sent while the app was in front, or on its way there, may have been missed: read the
    /// pointer now rather than waiting for the next event or timer tick.
    private func appActivityChanged(_ active: Bool) {
        guard removeMonitor != nil else { return }
        setPolling(active)
        pointerMoved()
    }

    private func setPolling(_ on: Bool) {
        guard on != (polling != nil) else { return }
        guard on else {
            polling?.cancel()
            polling = nil
            return
        }
        let sleep = pollSleep, interval = pollInterval
        polling = Task { [weak self] in
            while !Task.isCancelled {
                do { try await sleep(interval) } catch { return }
                // A sleep that ignores cancellation still returns, and must not read the pointer
                // for an app that is no longer in front.
                guard !Task.isCancelled, let self else { return }
                pointerMoved()
            }
        }
    }

    private func pointerMoved() {
        let point = pointer()
        if let pointerFrame, pointerFrame.contains(point) { return }
        // Between screens the pointer belongs to no display, and the last one stays active.
        guard let screen = knownScreens.first(where: { $0.frame.contains(point) }) else { return }
        let before = activeDisplays
        enter(screen)
        notify(from: before)
    }

    /// The pointer is on `screen`: it is active at once, and the display it came from lingers.
    private func enter(_ screen: Screen) {
        pointerFrame = screen.frame
        guard screen.id != pointerDisplay else { return }
        if let previous = pointerDisplay { linger(previous) }
        lingering.removeValue(forKey: screen.id)?.cancel()
        pointerDisplay = screen.id
    }

    private func linger(_ display: UInt32) {
        lingering[display]?.cancel()
        let sleep = sleep, dwell = dwell
        lingering[display] = Task { [weak self] in
            do { try await sleep(dwell) } catch { return }
            // A sleep that ignores cancellation still returns, and must not end the wait of a
            // display the pointer came back to, or one that left a second time.
            guard !Task.isCancelled, let self else { return }
            let before = activeDisplays
            lingering[display] = nil
            notify(from: before)
        }
    }

    // MARK: - Change reporting

    /// The displays that count as active; nil while nothing is tracked.
    private var activeDisplays: Set<UInt32>? {
        guard let pointerDisplay else { return nil }
        return Set(lingering.keys).union([pointerDisplay])
    }

    private func notify(from before: Set<UInt32>?) {
        let after = activeDisplays
        guard after != before else { return }
        if let after {
            let paused = Set(knownScreens.map(\.id)).subtracting(after).sorted()
            AppLog.info("active display \(pointerDisplay.map { "\($0)" } ?? "none"); pausing \(paused)")
        } else {
            AppLog.info("active display tracking ended; every display plays")
        }
        onChange?()
    }

    // MARK: - The system

    static func systemScreens() -> [Screen] {
        NSScreen.screens.compactMap { screen in
            WallpaperCoverageProbes.displayID(of: screen).map { Screen(id: $0, frame: screen.frame) }
        }
    }

    /// One global monitor and one local one. A global monitor sees nothing while this app is in
    /// front, and a local one sees only what is sent to this app's windows, so the tracker reads the
    /// pointer itself in that time (see the class documentation). Neither consumes an event.
    static func systemMonitor(_ handler: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseDown, .rightMouseDown, .scrollWheel]
        let global = NSEvent.addGlobalMonitorForEvents(matching: mask) { _ in
            MainActor.assumeIsolated { handler() }
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: mask) { event in
            MainActor.assumeIsolated { handler() }
            return event
        }
        return {
            if let global { NSEvent.removeMonitor(global) }
            if let local { NSEvent.removeMonitor(local) }
        }
    }
}
