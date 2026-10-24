import AppKit
import Darwin

/// What the pinning needs to know about one display that follows desktop Spaces.
struct WallpaperSpacePin: Equatable {
    enum Content: Equatable {
        /// The current desktop's own wallpaper is on screen, or nothing is to change.
        case ready
        /// The current desktop's wallpaper is being applied.
        case loading
        /// The current desktop's wallpaper waits until playback can run it.
        case waiting
    }

    /// The window server's number for the display's current desktop; nil on a full-screen app's
    /// Space, where the windows stay on the desktop they were on.
    var space: UInt64?
    var content: Content
    /// The desktops each wallpaper is chosen for, by wallpaper id, as the window server's numbers:
    /// a window showing that wallpaper belongs on exactly those, also while the person is on
    /// another desktop, where it waits paused.
    var desktops: [String: Set<UInt64>] = [:]
    /// The wallpaper the current desktop is about to show while it is not on screen yet. A window
    /// of another wallpaper that no desktop is chosen for stays where it is meanwhile, instead of
    /// following the person onto the desktop it is leaving.
    var incoming: String? = nil
}

/// One wallpaper window, as the pinning sees it.
@MainActor
protocol WallpaperPinnableWindow {
    var number: Int { get }
    var displayID: UInt32? { get }
    /// The wallpaper the window shows; nil while that is not known yet, as for a window that has
    /// just opened.
    var wallpaperID: String? { get }
    /// Whether the window is ordered in: a host's new window is listed, with its wallpaper, before
    /// its page or clip is ready and the window is presented.
    var isOrderedIn: Bool { get }
    var joinsAllSpaces: Bool { get nonmutating set }
    /// Hides the window at once, on screen before it returns, or shows it again over `fade`
    /// seconds.
    func setConcealed(_ concealed: Bool, fade: TimeInterval)
}

/// The window server's Space calls for this app's own windows.
@MainActor
protocol WallpaperSpaceWindowMoving {
    func spaces(ofWindow number: Int) -> [UInt64]?
    func move(windows: [Int], toSpace space: UInt64)
    /// Puts the window on exactly `spaces`; false when the calls that add a window to a Space and
    /// take it off one are missing.
    func place(window number: Int, onSpaces spaces: [UInt64]) -> Bool
}

/// Keeps each wallpaper window of a display that follows desktop Spaces on the desktops that show
/// its wallpaper.
///
/// Wallpaper windows normally join every Space, so the live wallpaper is the picture of every
/// desktop: Mission Control and the Spaces bar show it on each one, and a swipe carries the old
/// wallpaper onto the next desktop until its own has loaded. A pinned window stays on the desktops
/// chosen for its wallpaper instead (`WallpaperSpacePin.desktops`). A display keeps the wallpaper of
/// a desktop the person left loaded and paused in its own window there (`WallpaperSpaceParking`),
/// so a swipe slides in that desktop's paused wallpaper and arriving runs it on. A window whose
/// wallpaper no desktop is chosen for follows the person to the current desktop, as does one that
/// just opened.
///
/// A desktop whose wallpaper is not loaded yet shows its macOS picture, the poster of its own
/// wallpaper: the windows that belong on it are hidden while it loads and fade in once it is
/// ready, and a window that opens meanwhile is hidden before it is first ordered in.
///
/// A hidden window is still on screen to the window server and AppKit (fully transparent), so
/// occlusion does not suspend the display and the renderer keeps presenting its first frame.
/// Displays that do not follow Spaces keep windows on every Space, as does every display when the
/// window server's calls are not available.
@MainActor
final class WallpaperSpacePinning {
    struct Configuration {
        /// The longest a window stays hidden for a wallpaper that is being applied.
        var loadingCeiling: Duration = .seconds(30)
        /// The fade-in, in seconds; none under Reduce Motion.
        var fade: TimeInterval = 0.2
    }

    private let windows: @MainActor () -> [any WallpaperPinnableWindow]
    private let pins: @MainActor () -> [UInt32: WallpaperSpacePin]
    private let holding: @MainActor (UInt32) -> Bool
    private let mover: (any WallpaperSpaceWindowMoving)?
    private let reduceMotion: @MainActor () -> Bool
    private let now: @MainActor () -> ContinuousClock.Instant
    private let sleep: @Sendable (Duration) async throws -> Void
    private let center: NotificationCenter
    private let windowCenter: NotificationCenter
    private let openedWindow: @MainActor (Notification) -> (any WallpaperPinnableWindow)?
    private let configuration: Configuration
    private var observer: NSObjectProtocol?
    private var openObserver: NSObjectProtocol?
    /// The pins of the last update, for a window that opens between updates.
    private var lastPins: [UInt32: WallpaperSpacePin] = [:]
    /// Windows the last update put on desktops other than the one the person is on.
    private var awayWindows = Set<Int>()
    /// Windows taken off every Space by this pinning.
    private var pinnedWindows = Set<Int>()
    private var concealedWindows = Set<Int>()
    private var concealedSince: [UInt32: ContinuousClock.Instant] = [:]
    /// Displays that reached the ceiling, shown until their wallpaper is ready.
    private var gaveUp = Set<UInt32>()
    private var ceiling: Task<Void, Never>?

    /// `pins` lists the displays that follow Spaces now; `holding` says whether the switch hold
    /// still covers a display, which for a web page or a clip is how its readiness shows.
    /// `openedWindow` finds the window a `wallpaperLayerInstalled` notification posted on
    /// `windowCenter` announces, before it is ordered in.
    init(windows: @escaping @MainActor () -> [any WallpaperPinnableWindow] = { SystemPinnableWindow.all() },
         pins: @escaping @MainActor () -> [UInt32: WallpaperSpacePin],
         holding: @escaping @MainActor (UInt32) -> Bool,
         mover: (any WallpaperSpaceWindowMoving)?,
         reduceMotion: @escaping @MainActor () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion },
         now: @escaping @MainActor () -> ContinuousClock.Instant = { ContinuousClock.now },
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         center: NotificationCenter = .default,
         windowCenter: NotificationCenter = .default,
         openedWindow: @escaping @MainActor (Notification) -> (any WallpaperPinnableWindow)? = SystemPinnableWindow.opened,
         configuration: Configuration = Configuration()) {
        self.windows = windows
        self.pins = pins
        self.holding = holding
        self.mover = mover
        self.reduceMotion = reduceMotion
        self.now = now
        self.sleep = sleep
        self.center = center
        self.windowCenter = windowCenter
        self.openedWindow = openedWindow
        self.configuration = configuration
    }

    func start() {
        guard observer == nil else { return }
        if mover == nil {
            AppLog.warn("space pinning: the window server's Space calls are unavailable; "
                + "wallpaper windows stay on every desktop")
        }
        observer = center.addObserver(forName: WallpaperSpaceMonitor.didChangeNotification, object: nil,
                                      queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        // Posted synchronously on the main thread by the window that is about to be ordered in.
        openObserver = windowCenter.addObserver(forName: WallpaperSwitchHoldNotification.layerInstalled,
                                                object: nil, queue: nil) { [weak self] note in
            MainActor.assumeIsolated { self?.windowWillOpen(note) }
        }
        update()
    }

    /// Puts every window back on every Space, shown.
    func stop() {
        if let observer { center.removeObserver(observer) }
        observer = nil
        if let openObserver { windowCenter.removeObserver(openObserver) }
        openObserver = nil
        lastPins = [:]
        awayWindows.removeAll()
        ceiling?.cancel()
        ceiling = nil
        for window in windows() {
            if pinnedWindows.contains(window.number) { window.joinsAllSpaces = true }
            if concealedWindows.contains(window.number) { window.setConcealed(false, fade: 0) }
        }
        pinnedWindows.removeAll()
        concealedWindows.removeAll()
        concealedSince.removeAll()
        gaveUp.removeAll()
    }

    /// Whether the display's wallpaper windows are hidden while its desktop's wallpaper loads.
    func isConcealed(_ display: UInt32) -> Bool { concealedSince[display] != nil }

    /// Whether windows can be kept on desktops of their own: the window server's calls are there
    /// and the pinning runs.
    var isActive: Bool { mover != nil && observer != nil }

    /// Whether the window belongs only on desktops other than the one the person is on, such as
    /// the paused wallpaper of a desktop they left.
    func isAwayFromCurrentDesktop(_ windowNumber: Int) -> Bool { awayWindows.contains(windowNumber) }

    /// Brings every wallpaper window in line with the displays that follow Spaces. Cheap and
    /// idempotent: call it whenever the desktop, the choices, a switch or the windows changed.
    func update() {
        let pins = mover == nil || observer == nil ? [:] : self.pins()
        lastPins = pins
        let windows = windows()
        let concealed = displaysToConceal(pins, windows: windows)
        awayWindows.removeAll()
        for window in windows {
            let number = window.number
            guard let display = window.displayID, let pin = pins[display], let mover else {
                if pinnedWindows.remove(number) != nil { window.joinsAllSpaces = true }
                if concealedWindows.remove(number) != nil { window.setConcealed(false, fade: 0) }
                continue
            }
            let placement = Self.placement(of: window.wallpaperID, in: pin)
            if !placement.onCurrentDesktop, pin.space != nil { awayWindows.insert(number) }
            // Only a window that belongs on the desktop being loaded is hidden; one kept for
            // another desktop is not on screen.
            let hide = concealed.contains(display) && placement.onCurrentDesktop
            // Hidden before it moves, so the old picture never reaches the new desktop.
            if hide, concealedWindows.insert(number).inserted { window.setConcealed(true, fade: 0) }
            if window.joinsAllSpaces { window.joinsAllSpaces = false }
            pinnedWindows.insert(number)
            if let spaces = placement.spaces, mover.spaces(ofWindow: number) != spaces {
                Self.put(number, on: spaces, current: pin.space, mover: mover)
            }
            if !hide, concealedWindows.remove(number) != nil {
                window.setConcealed(false, fade: reduceMotion() ? 0 : configuration.fade)
            }
        }
        let live = Set(windows.map(\.number))
        pinnedWindows.formIntersection(live)
        concealedWindows.formIntersection(live)
    }

    /// Where a window showing `wallpaper` belongs: the desktops chosen for it, else the current
    /// desktop, unless another wallpaper is on its way there.
    struct Placement: Equatable {
        /// Sorted; nil to leave the window where it is.
        var spaces: [UInt64]?
        /// Whether the window belongs on the desktop the person is on.
        var onCurrentDesktop: Bool
    }

    static func placement(of wallpaper: String?, in pin: WallpaperSpacePin) -> Placement {
        if let wallpaper, let own = pin.desktops[wallpaper], !own.isEmpty {
            return Placement(spaces: own.sorted(), onCurrentDesktop: pin.space.map(own.contains) ?? false)
        }
        if let wallpaper, let incoming = pin.incoming, wallpaper != incoming {
            return Placement(spaces: nil, onCurrentDesktop: false)
        }
        return Placement(spaces: pin.space.map { [$0] }, onCurrentDesktop: true)
    }

    /// Puts a window on `spaces`. Without the calls for more than one Space it goes to the one
    /// the person is on if that is among them, else to the first.
    private static func put(_ number: Int, on spaces: [UInt64], current: UInt64?,
                            mover: any WallpaperSpaceWindowMoving) {
        if spaces.count > 1, mover.place(window: number, onSpaces: spaces) { return }
        let space = current.flatMap { spaces.contains($0) ? $0 : nil } ?? spaces[0]
        if mover.spaces(ofWindow: number) != [space] { mover.move(windows: [number], toSpace: space) }
    }

    /// A window about to be ordered in for the first time on a display that follows Spaces: it is
    /// kept off the other desktops, and hidden when the display's desktop is loading, so its first
    /// picture never reaches the screen before its wallpaper has drawn. The next update puts it
    /// where it belongs.
    private func windowWillOpen(_ note: Notification) {
        guard mover != nil,
              note.userInfo?[WallpaperSwitchHoldNotification.reasonKey] as? String
                == WallpaperSwitchHoldNotification.Reason.open.rawValue,
              let display = (note.userInfo?[WallpaperSwitchHoldNotification.displayIDKey] as? NSNumber)?.uint32Value,
              lastPins[display] != nil, let window = openedWindow(note) else { return }
        window.joinsAllSpaces = false
        pinnedWindows.insert(window.number)
        if concealedSince[display] != nil, concealedWindows.insert(window.number).inserted {
            window.setConcealed(true, fade: 0)
        }
    }

    private func displaysToConceal(_ pins: [UInt32: WallpaperSpacePin],
                                   windows: [any WallpaperPinnableWindow]) -> Set<UInt32> {
        let instant = now()
        var result = Set<UInt32>()
        for (display, pin) in pins {
            let wasConcealed = concealedSince[display] != nil
            let held = wasConcealed && holding(display)
            // The incoming wallpaper may already be on screen there, shown: the one the display
            // kept paused for this desktop, which the renderer runs on before the app hears
            // that the switch is done. Hiding it would flash the desktop picture. A window that
            // is not ordered in yet, or not on this desktop as the window server says, is not.
            let alreadyShowing = !wasConcealed && pin.incoming.map { incoming in
                windows.contains { window in
                    window.displayID == display && window.wallpaperID == incoming && window.isOrderedIn
                        && !concealedWindows.contains(window.number)
                        && pin.space.map { mover?.spaces(ofWindow: window.number)?.contains($0) == true } == true
                }
            } == true
            guard pin.content != .ready || held, !alreadyShowing else {
                gaveUp.remove(display)
                continue
            }
            guard !gaveUp.contains(display) else { continue }
            let since = concealedSince[display] ?? instant
            if pin.content != .waiting, since.duration(to: instant) >= configuration.loadingCeiling {
                AppLog.warn("space pinning: display \(display) wallpaper not ready after "
                    + "\(configuration.loadingCeiling.wholeMilliseconds / 1_000) s; showing it")
                gaveUp.insert(display)
                continue
            }
            if !wasConcealed { AppLog.info("space pinning: display \(display) hidden while its desktop's wallpaper loads") }
            concealedSince[display] = since
            result.insert(display)
        }
        for (display, since) in concealedSince where !result.contains(display) {
            concealedSince[display] = nil
            let seconds = Double(since.duration(to: instant).wholeMilliseconds) / 1_000
            AppLog.info("space pinning: display \(display) shown after \(String(format: "%.1f", seconds)) s")
        }
        armCeiling(pins)
        return result
    }

    /// Wakes the pinning when the oldest hidden display that can reach the ceiling does. A display
    /// waiting for playback stays hidden however long it waits, so it never arms it: counting it
    /// would re-arm a ceiling already passed with no wait, over and over.
    private func armCeiling(_ pins: [UInt32: WallpaperSpacePin]) {
        ceiling?.cancel()
        ceiling = nil
        let loading = concealedSince.filter { display, _ in pins[display].map { $0.content != .waiting } ?? false }
        guard let oldest = loading.values.min() else { return }
        let wait = max(.zero, now().duration(to: oldest + configuration.loadingCeiling))
        let sleep = self.sleep
        ceiling = Task { [weak self] in
            do { try await sleep(wait) } catch { return }
            self?.update()
        }
    }
}

/// A wallpaper window of any of the four kinds.
struct SystemPinnableWindow: WallpaperPinnableWindow {
    let window: NSWindow
    var wallpaperID: String? = nil

    /// Every wallpaper window, each with its wallpaper from `wallpaperIDs`, by window number.
    static func all(wallpaperIDs: [Int: String] = [:]) -> [any WallpaperPinnableWindow] {
        WallpaperPresentationPolicy.wallpaperWindows().map {
            SystemPinnableWindow(window: $0, wallpaperID: wallpaperIDs[$0.windowNumber])
        }
    }

    /// The window a `wallpaperLayerInstalled` notification announces: its layer is hosted by the
    /// window's content view. A window that is not ordered in yet is already among the app's.
    static func opened(_ note: Notification) -> (any WallpaperPinnableWindow)? {
        guard let layer = note.object as? CALayer,
              let window = (layer.delegate as? NSView)?.window
                ?? NSApp.windows.first(where: { $0.contentView?.layer === layer }) else { return nil }
        return SystemPinnableWindow(window: window)
    }

    var number: Int { window.windowNumber }

    var isOrderedIn: Bool { window.isVisible }

    var displayID: UInt32? {
        let screen = window.screen ?? NSScreen.screens.first { $0.frame.intersects(window.frame) }
        return (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    var joinsAllSpaces: Bool {
        get { window.collectionBehavior.contains(.canJoinAllSpaces) }
        nonmutating set {
            if newValue { window.collectionBehavior.insert(.canJoinAllSpaces) }
            else { window.collectionBehavior.remove(.canJoinAllSpaces) }
        }
    }

    func setConcealed(_ concealed: Bool, fade: TimeInterval) {
        guard !concealed, fade > 0 else {
            window.alphaValue = concealed ? 0 : 1
            // A window's alpha reaches the screen with the next Core Animation commit, at the end
            // of this run loop turn, while a Space move takes effect at once: without the flush
            // the window would arrive on the new desktop opaque and show the old wallpaper.
            if concealed { CATransaction.flush() }
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = fade
            window.animator().alphaValue = 1
        }
    }
}

/// Optional private CoreGraphics entry points that place this app's own windows on a Space.
/// Public AppKit has no call that moves a window to the current Space: a window ordered in again,
/// or one that joins every Space and leaves again, returns to the Space it came from.
@MainActor
final class SystemSpaceWindowMover: WallpaperSpaceWindowMoving {
    private typealias Connection = @convention(c) () -> Int32
    private typealias CopySpaces = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias Move = @convention(c) (Int32, CFArray, UInt64) -> Void
    private typealias Change = @convention(c) (Int32, CFArray, CFArray) -> Void
    /// Current, other and user Spaces: every Space the window is on.
    private static let allSpacesMask: Int32 = 0x7
    private let connection: Connection
    private let copySpaces: CopySpaces
    private let moveWindows: Move
    /// Optional on their own: without them a window is on one Space at a time.
    private let addWindows: Change?
    private let removeWindows: Change?

    init?() {
        guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY),
              let connection = dlsym(handle, "_CGSDefaultConnection"),
              let copySpaces = dlsym(handle, "CGSCopySpacesForWindows"),
              let moveWindows = dlsym(handle, "CGSMoveWindowsToManagedSpace") else { return nil }
        self.connection = unsafeBitCast(connection, to: Connection.self)
        self.copySpaces = unsafeBitCast(copySpaces, to: CopySpaces.self)
        self.moveWindows = unsafeBitCast(moveWindows, to: Move.self)
        if let add = dlsym(handle, "CGSAddWindowsToSpaces"), let remove = dlsym(handle, "CGSRemoveWindowsFromSpaces") {
            addWindows = unsafeBitCast(add, to: Change.self)
            removeWindows = unsafeBitCast(remove, to: Change.self)
        } else {
            addWindows = nil
            removeWindows = nil
        }
    }

    func place(window number: Int, onSpaces spaces: [UInt64]) -> Bool {
        guard let addWindows, let removeWindows, let current = self.spaces(ofWindow: number) else { return false }
        let wanted = Set(spaces), now = Set(current)
        let windows = [number] as CFArray
        let missing = wanted.subtracting(now).sorted(), extra = now.subtracting(wanted).sorted()
        if !missing.isEmpty { addWindows(connection(), windows, missing as CFArray) }
        if !extra.isEmpty { removeWindows(connection(), windows, extra as CFArray) }
        return true
    }

    func spaces(ofWindow number: Int) -> [UInt64]? {
        guard let spaces = copySpaces(connection(), Self.allSpacesMask, [number] as CFArray)?
            .takeRetainedValue() as? [NSNumber] else { return nil }
        return spaces.map(\.uint64Value).sorted()
    }

    func move(windows: [Int], toSpace space: UInt64) {
        moveWindows(connection(), windows as CFArray, space)
    }
}
