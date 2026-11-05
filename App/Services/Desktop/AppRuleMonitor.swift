import AppKit

/// Reports the app-rule actions currently in force: the per-app rules' and that of
/// "When another app is in front". Workspace notifications are observed only while at least one
/// of them can do something.
///
/// "Pause on battery" also depends on the power source, which the monitor reads only when that
/// choice is made and another app is in front. Nothing here observes the power source: the app
/// calls `refresh()` when it changes (`PowerSourceMonitor`, which also reads it again after a wake).
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
    private let desktopBundleIDs: Set<String>

    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var started = false

    /// `onBattery` says whether the Mac runs on battery now; an unknown source is not battery.
    /// Without one, the system's providing power source is read.
    init(
        preferences: PlaybackPreferences,
        workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        preferencesCenter: NotificationCenter = .default,
        runningBundleIDs: (@MainActor () -> Set<String>)? = nil,
        frontmostBundleID: (@MainActor () -> String?)? = nil,
        onBattery: (@MainActor () -> Bool)? = nil,
        desktopBundleIDs: Set<String> = AppRuleMonitor.defaultDesktopBundleIDs
    ) {
        self.desktopBundleIDs = desktopBundleIDs
        self.preferences = preferences
        self.workspaceCenter = workspaceCenter
        self.preferencesCenter = preferencesCenter
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
                MainActor.assumeIsolated { self?.recompute() }
            }))
        }
    }

    private func removeWorkspaceObservers() {
        observers.removeAll { center, token in
            guard center === workspaceCenter else { return false }
            center.removeObserver(token)
            return true
        }
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
        // No app in front (a moment between activations) is not another app.
        if let frontmost, !desktopBundleIDs.contains(frontmost),
           let action = preferences.otherAppInFrontAction.ruleAction(onBattery: onBattery()) {
            next.insert(action)
        }
        publish(next)
    }

    private func publish(_ next: Set<AppRuleAction>) {
        guard next != actions else { return }
        actions = next
        onChange?()
    }
}
