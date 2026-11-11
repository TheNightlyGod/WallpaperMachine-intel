import AppKit

/// Reports the app-rule actions currently in force: the per-app rules' and that of
/// "When another app is in front". Workspace notifications are observed only while at least one
/// of them can do something.
///
/// "Pause on battery" also depends on the power source, which the monitor reads only when that
/// choice is made and another app is in front. Nothing here observes the power source: the app
/// calls `refresh()` when it changes (`PowerSourceMonitor`, which also reads it again after a wake).
///
/// An app stays in front when its last window is minimized or closed, and macOS posts no
/// activation for that. So the app's own windows changing occlusion (the coverage probes over the
/// working area, the wallpaper windows) is taken as a sign that windows left or came back: the
/// monitor then asks whether the app in front still shows a window, and an app that shows none
/// stops counting as another app in front until it is activated again or shows one.
@MainActor
final class AppRuleMonitor {
    /// The apps that count as the desktop for "When another app is in front": Finder, which
    /// clicking the desktop brings forward, and this app, whose panel and menus are about the
    /// wallpapers themselves.
    nonisolated static let defaultDesktopBundleIDs: Set<String> = Set(
        ["com.apple.finder", Bundle.main.bundleIdentifier].compactMap { $0 })

    /// Whether the monitor has anything to watch for these preferences. Pause on battery is
    /// watched on mains power too, so unplugging finds the app in front already known.
    static func isNeeded(for preferences: PlaybackPreferences) -> Bool {
        !preferences.appRules.isEmpty || preferences.otherAppInFrontAction.watchesFrontmostApp
    }

    var onChange: (@MainActor () -> Void)?
    private(set) var actions: Set<AppRuleAction> = []

    private let preferences: PlaybackPreferences
    private let workspaceCenter: NotificationCenter
    private let preferencesCenter: NotificationCenter
    private let runningBundleIDs: @MainActor () -> Set<String>
    private let frontmostBundleID: @MainActor () -> String?
    private let onBattery: @MainActor () -> Bool
    private let windowCenter: NotificationCenter
    private let frontmostShowsWindow: @MainActor () -> Bool
    private let desktopBundleIDs: Set<String>

    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    /// Kept apart from `observers`: the window center is usually the preferences center too.
    private var windowObserver: NSObjectProtocol?
    private var started = false
    /// A window change found the app in front without a window on screen: its windows were
    /// minimized or closed while it stayed active. Cleared by the next activation, launch or quit,
    /// and by a window change that finds a window again. An activation alone never sets it, so an
    /// app whose first window is still opening counts as in front.
    private var frontmostIsWindowless = false

    /// `onBattery` says whether the Mac runs on battery now; an unknown source is not battery.
    /// Without one, the system's providing power source is read. `frontmostShowsWindow` says
    /// whether the app in front has a window on screen; without one, the window server is asked.
    init(
        preferences: PlaybackPreferences,
        workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        preferencesCenter: NotificationCenter = .default,
        windowCenter: NotificationCenter = .default,
        runningBundleIDs: (@MainActor () -> Set<String>)? = nil,
        frontmostBundleID: (@MainActor () -> String?)? = nil,
        onBattery: (@MainActor () -> Bool)? = nil,
        frontmostShowsWindow: (@MainActor () -> Bool)? = nil,
        desktopBundleIDs: Set<String> = AppRuleMonitor.defaultDesktopBundleIDs
    ) {
        self.desktopBundleIDs = desktopBundleIDs
        self.preferences = preferences
        self.workspaceCenter = workspaceCenter
        self.preferencesCenter = preferencesCenter
        self.windowCenter = windowCenter
        self.frontmostShowsWindow = frontmostShowsWindow ?? {
            NSWorkspace.shared.frontmostApplication.map { Self.showsWindow(processID: $0.processIdentifier) } ?? true
        }
        self.runningBundleIDs = runningBundleIDs ?? {
            Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        }
        self.frontmostBundleID = frontmostBundleID ?? {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        }
        self.onBattery = onBattery ?? { PowerSourceMonitor.systemSource() == .battery }
    }

    /// The power source changed: Pause on battery may start or end. Does nothing while stopped.
    func refresh() {
        recompute()
    }

    func start() {
        guard !started else {
            refreshWorkspaceObservation()
            recompute()
            return
        }
        started = true
        observers.append((preferencesCenter, preferencesCenter.addObserver(
            forName: PlaybackPreferences.didChangeNotification, object: preferences, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshWorkspaceObservation()
                self?.recompute()
            }
        }))
        refreshWorkspaceObservation()
        recompute()
    }

    func stop() {
        started = false
        frontmostIsWindowless = false
        removeWorkspaceObservers()
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        publish([])
    }

    private func refreshWorkspaceObservation() {
        let watching = observers.contains { $0.0 === workspaceCenter }
        guard started, Self.isNeeded(for: preferences) else {
            removeWorkspaceObservers()
            return
        }
        guard !watching else { return }
        for name in [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
        ] {
            observers.append((workspaceCenter, workspaceCenter.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.frontmostChanged() }
            }))
        }
        windowObserver = windowCenter.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.windowsChanged() }
        }
    }

    private func removeWorkspaceObservers() {
        observers.removeAll { center, token in
            guard center === workspaceCenter else { return false }
            center.removeObserver(token)
            return true
        }
        if let windowObserver { windowCenter.removeObserver(windowObserver) }
        windowObserver = nil
        frontmostIsWindowless = false
    }

    /// An activation, launch or quit: whatever app is in front now counts again, windows or not.
    private func frontmostChanged() {
        frontmostIsWindowless = false
        recompute()
    }

    /// Windows covering this app's windows changed. Asks whether the app in front still shows a
    /// window while another app is in front and the choice watches it: on mains power too for
    /// Pause on battery, so an unplug finds the answer current.
    private func windowsChanged() {
        guard started, preferences.otherAppInFrontAction.watchesFrontmostApp,
              let frontmost = frontmostBundleID(), !desktopBundleIDs.contains(frontmost) else { return }
        frontmostIsWindowless = !frontmostShowsWindow()
        recompute()
    }

    private func recompute() {
        guard started, Self.isNeeded(for: preferences) else {
            publish([])
            return
        }
        let running = runningBundleIDs()
        let frontmost = frontmostBundleID()
        var next = Set<AppRuleAction>()
        for rule in preferences.appRules {
            let matches = switch rule.condition {
            case .running: running.contains(rule.bundleIdentifier)
            case .frontmost: frontmost == rule.bundleIdentifier
            }
            if matches { next.insert(rule.action) }
        }
        // No app in front (a moment between activations) is not another app, nor is one
        // left in front with every window minimized or closed.
        if let frontmost, !desktopBundleIDs.contains(frontmost), !frontmostIsWindowless,
           let action = preferences.otherAppInFrontAction.ruleAction(onBattery: onBattery()) {
            next.insert(action)
        }
        publish(next)
    }

    /// Whether the process has a window on screen in the current Space at a level where people
    /// work in it: from normal windows to floating panels, below the menu bar, visible and larger
    /// than the 1-point helper windows some apps keep. Without the window server's answer, it does.
    nonisolated static func showsWindow(processID: pid_t) -> Bool {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return true }
        let menuBarLevel = Int(CGWindowLevelForKey(.mainMenuWindow))
        return windows.contains { window in
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == processID,
                  let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  (0..<menuBarLevel).contains(layer),
                  ((window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0,
                  let bounds = (window[kCGWindowBounds as String] as? NSDictionary)
                      .flatMap({ CGRect(dictionaryRepresentation: $0 as CFDictionary) })
            else { return false }
            return bounds.width > 1 && bounds.height > 1
        }
    }

    private func publish(_ next: Set<AppRuleAction>) {
        guard next != actions else { return }
        actions = next
        onChange?()
    }
}
