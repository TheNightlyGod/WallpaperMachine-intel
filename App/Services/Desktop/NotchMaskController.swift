import AppKit

/// The black strip behind the menu bar of one display. Its Objective-C name is not one of
/// `WallpaperPresentationPolicy.wallpaperWindowClassNames`, so occlusion tracking, the window
/// audit and the desktop-picture posters never take it for a wallpaper.
@objc(MWENotchMaskWindow)
final class NotchMaskWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// The strip lies under the menu bar, out of which AppKit would otherwise move a window.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// Settings › Desktop & Lock Screen › Hide the notch: an opaque black strip behind the menu bar of
/// every display with a camera notch, so the menu bar, which shows what lies beneath it, turns
/// black and the notch disappears into it. The rest of the display still shows the wallpaper.
///
/// One strip per notched display, just above the wallpaper windows and below Finder's desktop
/// icons, on every Space, ignoring the mouse, so a click there still reaches the menu bar. It
/// covers the display's whole width from the top edge down to where the working area
/// (`visibleFrame`) starts, which keeps it clear of the coverage probes over that working area.
/// A menu bar that hides itself leaves no strip, since nothing then separates the working area
/// from the top edge. Off by default. While off the controller keeps no window and watches only
/// its own preference; while on it moves the strips when a screen change moves a display or its
/// working area, and does nothing for a change that moves neither.
@MainActor
final class NotchMaskController {
    static let defaultsKey = "WallpaperMachine.hideNotch"
    /// Posted after the preference is written.
    static let didChange = Notification.Name("WallpaperMachine.NotchMask.didChange")

    /// A display as the strip sees it.
    struct Screen: Equatable {
        var displayID: UInt32
        var frame: NSRect
        /// The screen without the menu bar and a shown Dock.
        var visibleFrame: NSRect
        /// Whether the camera housing cuts into the top of the display.
        var hasNotch: Bool
    }

    private let defaults: UserDefaults
    private let center: NotificationCenter
    private let screens: @MainActor () -> [Screen]
    private let makeMask: @MainActor (NSRect) -> NSWindow
    private var masks: [UInt32: NSWindow] = [:]
    private var preferenceObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?

    /// `makeMask` makes and shows the window for a strip; tests pass one that keeps it off screen.
    init(
        defaults: UserDefaults = ClientPreferences.defaults, center: NotificationCenter = .default,
        screens: @escaping @MainActor () -> [Screen] = NotchMaskController.systemScreens,
        makeMask: @escaping @MainActor (NSRect) -> NSWindow = NotchMaskController.presentMask
    ) {
        self.defaults = defaults
        self.center = center
        self.screens = screens
        self.makeMask = makeMask
    }

    // MARK: The preference

    static func isEnabled(defaults: UserDefaults = ClientPreferences.defaults) -> Bool {
        defaults.bool(forKey: defaultsKey)
    }

    static func setEnabled(
        _ enabled: Bool, defaults: UserDefaults = ClientPreferences.defaults, center: NotificationCenter = .default
    ) {
        if isEnabled(defaults: defaults) != enabled {
            AppLog.info("notch mask \(enabled ? "enabled" : "disabled")")
        }
        defaults.set(enabled, forKey: defaultsKey)
        center.post(name: didChange, object: nil)
    }

    // MARK: Running

    /// The frames of the strips the controller keeps, by display.
    var placedFrames: [UInt32: NSRect] { masks.mapValues(\.frame) }

    func start() {
        guard preferenceObserver == nil else { return }
        preferenceObserver = center.addObserver(forName: Self.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync() }
        }
        sync()
    }

    func stop() {
        if let preferenceObserver { center.removeObserver(preferenceObserver) }
        preferenceObserver = nil
        stopWatchingScreens()
        removeAll()
    }

    private func sync() {
        guard Self.isEnabled(defaults: defaults) else {
            stopWatchingScreens()
            removeAll()
            return
        }
        if screenObserver == nil {
            // An XDR display posts a screen change for every frame of an EDR headroom ramp; a
            // change that moves no strip touches no window.
            screenObserver = center.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.place() }
            }
        }
        place()
    }

    private func place() {
        let frames = Self.maskFrames(for: screens())
        for (displayID, frame) in frames {
            if let mask = masks[displayID] {
                if mask.frame != frame { mask.setFrame(frame, display: true) }
            } else {
                masks[displayID] = makeMask(frame)
            }
        }
        for (displayID, mask) in masks where frames[displayID] == nil {
            mask.orderOut(nil)
            mask.close()
            masks[displayID] = nil
        }
    }

    private func stopWatchingScreens() {
        if let screenObserver { center.removeObserver(screenObserver) }
        screenObserver = nil
    }

    private func removeAll() {
        for mask in masks.values {
            mask.orderOut(nil)
            mask.close()
        }
        masks.removeAll()
    }

    // MARK: Geometry

    /// The strip behind the menu bar of `screen`, in global screen coordinates: the display's whole
    /// width, from its top edge down to the top of its working area. Nil for a display without a
    /// notch, and for one whose menu bar hides itself, where the working area reaches the top edge.
    nonisolated static func maskFrame(for screen: Screen) -> NSRect? {
        guard screen.hasNotch else { return nil }
        let height = screen.frame.maxY - screen.visibleFrame.maxY
        guard height > 0, screen.frame.width > 0 else { return nil }
        return NSRect(x: screen.frame.minX, y: screen.frame.maxY - height, width: screen.frame.width, height: height)
    }

    /// The strip each display should have, by display.
    nonisolated static func maskFrames(for screens: [Screen]) -> [UInt32: NSRect] {
        var frames: [UInt32: NSRect] = [:]
        for screen in screens {
            if let frame = maskFrame(for: screen) { frames[screen.displayID] = frame }
        }
        return frames
    }

    /// The connected displays as AppKit reports them now. A display with a notch has a top safe
    /// area, or an auxiliary area to the left of the camera housing.
    static func systemScreens() -> [Screen] {
        NSScreen.screens.compactMap { screen in
            guard let displayID = SystemDisplays.id(of: screen) else { return nil }
            return Screen(
                displayID: displayID, frame: screen.frame, visibleFrame: screen.visibleFrame,
                hasNotch: screen.safeAreaInsets.top > 0 || screen.auxiliaryTopLeftArea != nil)
        }
    }

    /// A strip that is not yet on screen.
    static func makeMaskWindow(frame: NSRect) -> NotchMaskWindow {
        let mask = NotchMaskWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        // Just above the wallpaper windows, as the coverage probes are, and below Finder's icons.
        mask.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        mask.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        mask.isOpaque = true
        mask.backgroundColor = .black
        mask.hasShadow = false
        mask.ignoresMouseEvents = true
        mask.isMovable = false
        mask.isReleasedWhenClosed = false
        mask.isRestorable = false
        // Hiding the app hides the panel, never the desktop.
        mask.canHide = false
        mask.hidesOnDeactivate = false
        mask.isExcludedFromWindowsMenu = true
        mask.animationBehavior = .none
        return mask
    }

    static func presentMask(frame: NSRect) -> NSWindow {
        let mask = makeMaskWindow(frame: frame)
        mask.orderFrontRegardless()
        return mask
    }
}
