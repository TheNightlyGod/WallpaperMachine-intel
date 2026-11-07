import AppKit

/// Background checks and unattended installs never activate the app. The update window is
/// opened only by a user action; the stores supply the passive menu and panel notices.
@MainActor
final class AppUpdateCoordinator: NSObject, NSWindowDelegate {
    let updater: AppUpdateStore
    /// The update window while it is open.
    private(set) var window: NSWindow?
    private var automaticChecks: Task<Void, Never>?
    private let isShuttingDown: () -> Bool
    /// Nobody is at the Mac: the displays sleep or the session is locked.
    private let isUnattended: () -> Bool
    private let onboardingComplete: () -> Bool
    private let menuChanged: () -> Void
    /// Settings › About, which explains a failed update and offers a retry.
    private let showAbout: () -> Void
    private let beforeAutomaticCheck: () -> Void
    private let windowClosed: () -> Void

    init(
        updater: AppUpdateStore,
        isShuttingDown: @escaping () -> Bool,
        isUnattended: @escaping () -> Bool,
        menuChanged: @escaping () -> Void,
        showAbout: @escaping () -> Void,
        beforeAutomaticCheck: @escaping () -> Void,
        windowClosed: @escaping () -> Void,
        onboardingComplete: @escaping () -> Bool = { PanelPreferences.welcomeSeen() }
    ) {
        self.updater = updater
        self.isShuttingDown = isShuttingDown
        self.isUnattended = isUnattended
        self.onboardingComplete = onboardingComplete
        self.menuChanged = menuChanged
        self.showAbout = showAbout
        self.beforeAutomaticCheck = beforeAutomaticCheck
        self.windowClosed = windowClosed
    }

    /// The check **Check for Updates…** asks for; its answer shows in About.
    func checkNow() {
        Task { _ = await updater.checkForUpdates(); menuChanged() }
    }

    /// Restores a complete verified download, then checks when the persisted six-hour deadline
    /// is due, because a menu-bar app can run for weeks without relaunching.
    /// `Task.sleep` follows the continuous clock, so a Mac that slept through the interval
    /// checks as soon as it wakes.
    func startAutomaticChecks() {
        guard automaticChecks == nil else { return }
        automaticChecks = Task { [weak self] in
            await self?.updater.discardStaleDownloads()
            while !Task.isCancelled {
                if self?.updater.automaticCheckIsDue == true { await self?.runAutomaticCheck() }
                self?.installIfUnattended()
                let delay = self?.updater.nextAutomaticCheckDelay ?? AppUpdatePolicy.checkInterval
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    /// Ends the automatic checks and the work in flight; a scheduled install survives it.
    func cancel() {
        automaticChecks?.cancel()
        updater.cancel()
    }

    func resumeAfterCancelledQuit() async {
        if let automaticChecks {
            automaticChecks.cancel()
            await automaticChecks.value
        }
        automaticChecks = nil
        startAutomaticChecks()
    }

    func runAutomaticCheck() async {
        guard !isShuttingDown(), !Task.isCancelled else { return }
        beforeAutomaticCheck()
        let state = await updater.checkInBackground()
        guard !isShuttingDown(), !Task.isCancelled else { return }
        if updater.mayDownloadAutomatically, case .available = state {
            menuChanged()
            _ = await updater.downloadUpdate(automatically: true)
        }
        menuChanged()
        installIfUnattended()
    }

    private var mayInstallAutomatically: Bool {
        AppUpdatePolicy.mayInstall(.init(
            mode: updater.mode, unattended: isUnattended(), shuttingDown: isShuttingDown(),
            onboardingComplete: onboardingComplete(), canInstallInPlace: updater.canInstallInPlace,
            skipped: updater.state.availableVersion == updater.skippedVersion, deferred: updater.isDeferred,
            blocked: updater.state.availableVersion == updater.blockedAutomaticVersion))
    }

    /// With automatic updates on, a downloaded update installs (WallpaperMachine quits and
    /// reopens) while nobody is at the Mac: the displays sleep or the session is locked.
    func installIfUnattended() {
        guard case .ready = updater.state, !updater.isInstallPending, mayInstallAutomatically else { return }
        Task {
            await updater.installUpdate(automatically: true, allowed: { [weak self] in
                self?.mayInstallAutomatically == true
            })
            menuChanged()
        }
    }

    /// The update window, brought forward: nonmodal, so it never stalls the main actor.
    @objc func showWindow() {
        guard !isShuttingDown(), updater.state.availableVersion != nil else { return }
        if let window {
            NSApp.setActivationPolicy(.regular)
            ControlPanelWindow.bringForward(window)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = UpdateWindow.make(store: updater, actions: UpdateWindow.Actions(
            skip: { [weak self] in
                guard let self else { return }
                Task {
                    await self.updater.skipCurrentVersion()
                    self.window?.performClose(nil)
                    self.menuChanged()
                }
            },
            later: { [weak self] in
                self?.updater.postponeUpdate()
                self?.window?.performClose(nil)
            },
            install: { [weak self] in self?.installFromWindow() },
            setMode: { [weak self] mode in self?.updater.mode = mode },
            cancel: { [weak self] in self?.updater.cancel() }))
        window.delegate = self
        window.center()
        ControlPanelWindow.moveToActiveSpace(window)
        self.window = window
        NSApp.setActivationPolicy(.regular)
        ControlPanelWindow.bringForward(window)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window else { return }
        window = nil
        closing.contentViewController = nil
        windowClosed()
    }

    /// Download and restart are separate explicit actions. Errors stay in the current window.
    private func installFromWindow() {
        switch updater.state {
        case .manual:
            updater.openReleases()
            window?.performClose(nil)
        case .ready:
            if updater.canInstallInPlace { installDownloadedUpdate() }
            else { updater.revealDownloadedUpdate() }
        case .error:
            Task { _ = await updater.retryUpdate(); menuChanged() }
        case .available:
            Task {
                let state = await updater.downloadUpdate()
                menuChanged()
                if case .ready = state, !updater.canInstallInPlace { window?.performClose(nil) }
            }
        default:
            break
        }
    }

    /// The status menu's update line; "Later" leaves the update one click away there.
    func menuItem() -> NSMenuItem? {
        switch updater.state {
        case .ready(_, let version):
            guard updater.canInstallInPlace else { return menuItem("View update", action: #selector(showUpdateStatus)) }
            return menuItem("Restart to Update to \(version)", action: #selector(installDownloadedUpdate))
        case .available(_, let version), .manual(_, let version):
            return menuItem("WallpaperMachine \(version) Available…", action: #selector(showWindow))
        case .downloading, .preparing, .error:
            return menuItem("View update", action: #selector(showUpdateStatus))
        default:
            return updater.recentlyInstalledVersion == nil ? nil : menuItem("View update", action: #selector(showUpdateStatus))
        }
    }

    @objc private func showUpdateStatus() { showAbout() }

    private func menuItem(_ title: String.LocalizationValue, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: String(localized: title), action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func installDownloadedUpdate() {
        Task {
            await updater.installUpdate()
            // A failed install explains itself, and offers GitHub Releases, in About.
            menuChanged()
        }
    }
}
