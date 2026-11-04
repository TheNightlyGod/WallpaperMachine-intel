import AppKit

/// The app's update flow around `AppUpdateStore`: the launch and six-hourly checks, the update
/// window and when it may open (`UpdatePromptGate`), the status menu's update line and the
/// unattended install. `AppDelegate` owns one and supplies what it knows about the app.
@MainActor
final class AppUpdateCoordinator: NSObject, NSWindowDelegate {
    let updater: AppUpdateStore
    /// The update window while it is open.
    private(set) var window: NSWindow?
    private var automaticChecks: Task<Void, Never>?
    /// The version the unattended check last offered (Remind Me Later holds until the next launch)
    /// and whether a prompt is waiting for wallpapers to present again.
    private var prompts = UpdatePromptLedger()
    private let promptInput: () -> UpdatePromptGate.Input
    private let isShuttingDown: () -> Bool
    /// Nobody is at the Mac: the displays sleep or the session is locked.
    private let isUnattended: () -> Bool
    private let menuChanged: () -> Void
    /// Settings › About, which explains a failed update and offers a retry.
    private let showAbout: () -> Void
    private let beforeAutomaticCheck: () -> Void
    private let windowClosed: () -> Void

    init(
        updater: AppUpdateStore,
        promptInput: @escaping () -> UpdatePromptGate.Input,
        isShuttingDown: @escaping () -> Bool,
        isUnattended: @escaping () -> Bool,
        menuChanged: @escaping () -> Void,
        showAbout: @escaping () -> Void,
        beforeAutomaticCheck: @escaping () -> Void,
        windowClosed: @escaping () -> Void
    ) {
        self.updater = updater
        self.promptInput = promptInput
        self.isShuttingDown = isShuttingDown
        self.isUnattended = isUnattended
        self.menuChanged = menuChanged
        self.showAbout = showAbout
        self.beforeAutomaticCheck = beforeAutomaticCheck
        self.windowClosed = windowClosed
    }

    /// The check **Check for Updates…** asks for; its answer shows in About.
    func checkNow() {
        Task { _ = await updater.checkForUpdates() }
    }

    /// Clears the update images earlier launches left, then checks at launch and every six
    /// hours after, because a menu-bar app can run for weeks without relaunching.
    /// `Task.sleep` follows the continuous clock, so a Mac that slept through the interval
    /// checks as soon as it wakes.
    func startAutomaticChecks() {
        guard automaticChecks == nil else { return }
        automaticChecks = Task { [weak self] in
            await self?.updater.discardStaleDownloads()
            while !Task.isCancelled {
                await self?.runAutomaticCheck()
                try? await Task.sleep(for: .seconds(6 * 60 * 60))
            }
        }
    }

    /// Ends the automatic checks and the work in flight; a scheduled install survives it.
    func cancel() {
        automaticChecks?.cancel()
        updater.cancel()
    }

    private func runAutomaticCheck() async {
        beforeAutomaticCheck()
        // A check clears the release the open update window shows; it waits until it closes.
        guard window == nil else { return }
        var state = await updater.checkInBackground()
        if installsAutomatically, case .available(_, let version) = state,
           version != updater.skippedVersion {
            menuChanged()
            state = await updater.downloadUpdate()
        }
        menuChanged()
        offerIfNeeded(state)
        installIfUnattended()
    }

    /// Automatic updates are on and this copy can be replaced where it is. One that cannot is
    /// offered the window as usual, so a download never opens in Finder unasked.
    private var installsAutomatically: Bool {
        updater.automaticallyInstallsUpdates && updater.canInstallInPlace
    }

    /// With automatic updates on, a downloaded update installs (WallpaperMachine quits and
    /// reopens) while nobody is at the Mac: the displays sleep or the session is locked.
    func installIfUnattended() {
        guard installsAutomatically, case .ready(_, let version) = updater.state,
              version != updater.skippedVersion, !updater.isInstallPending,
              !isShuttingDown(), isUnattended() else { return }
        AppLog.info("update: installing \(version) automatically while the Mac is unattended")
        installDownloadedUpdate()
    }

    /// Opens the update window for `state` once per version, but only when `UpdatePromptGate`
    /// says it would not interrupt (not over a full-screen app, a locked screen or a sleeping
    /// display). A held prompt is not marked offered; `retryHeldPrompt` asks again
    /// without a network check when one of the gate's inputs changes.
    private func offerIfNeeded(_ state: AppUpdateState) {
        var version: String?
        switch state {
        case .ready(_, let ready): version = ready
        case .available(_, let available), .manual(_, let available): version = available
        default: version = nil
        }
        // A skipped version stays quiet, and so does one that installs by itself; a release
        // without a disk image cannot, so it is still offered.
        let installsItself: Bool
        switch state {
        case .available, .ready: installsItself = installsAutomatically
        default: installsItself = false
        }
        if version == updater.skippedVersion || installsItself { version = nil }
        switch prompts.offer(version: version, input: promptInput()) {
        case .none:
            return
        case .held(let reason, let isNew):
            if isNew { AppLog.info("update prompt deferred: \(reason.rawValue)") }
        case .present:
            showWindow()
        }
    }

    /// Asks again for a prompt the gate held, with the update state the app already has.
    func retryHeldPrompt() {
        guard prompts.holdReason != nil else { return }
        offerIfNeeded(updater.state)
    }

    /// The update window, brought forward: nonmodal, so it never stalls the main actor.
    @objc func showWindow() {
        guard !isShuttingDown(), let version = updater.state.availableVersion else { return }
        // Opened from the status menu too: a prompt held for this version is answered by it.
        prompts.markOffered(version)
        if let window {
            NSApp.setActivationPolicy(.regular)
            ControlPanelWindow.bringForward(window)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = UpdateWindow.make(store: updater, actions: UpdateWindow.Actions(
            skip: { [weak self] in
                guard let self else { return }
                self.updater.skippedVersion = self.updater.state.availableVersion
                self.window?.performClose(nil)
                self.menuChanged()
            },
            later: { [weak self] in self?.window?.performClose(nil) },
            install: { [weak self] in self?.installFromWindow() },
            setAutomatic: { [weak self] on in self?.updater.automaticallyInstallsUpdates = on }))
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

    /// **Install Update** is consent to both steps: the window shows the download, then the app
    /// quits and reopens on the new version. Closing the window meanwhile does not call it off.
    /// A failure closes the window and opens About, which explains it and offers a retry.
    private func installFromWindow() {
        switch updater.state {
        case .manual:
            updater.openReleases()
            window?.performClose(nil)
        case .ready:
            installDownloadedUpdate()
        case .available:
            Task {
                let state = await updater.downloadUpdate()
                menuChanged()
                switch state {
                case .ready where updater.canInstallInPlace:
                    installDownloadedUpdate()
                case .ready:
                    // The copy cannot be replaced in place; Finder shows the disk image instead.
                    window?.performClose(nil)
                case .error:
                    window?.performClose(nil)
                    showAbout()
                default:
                    break
                }
            }
        default:
            break
        }
    }

    /// The status menu's update line; "Later" leaves the update one click away there.
    func menuItem() -> NSMenuItem? {
        switch updater.state {
        case .ready(_, let version):
            return menuItem("Restart to Update to \(version)", action: #selector(installDownloadedUpdate))
        case .available(_, let version), .manual(_, let version):
            return menuItem("WallpaperMachine \(version) Available…", action: #selector(showWindow))
        default:
            return nil
        }
    }

    private func menuItem(_ title: String.LocalizationValue, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: String(localized: title), action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func installDownloadedUpdate() {
        Task {
            await updater.installUpdate()
            // A failed install explains itself, and offers GitHub Releases, in About.
            if case .error = updater.state {
                window?.performClose(nil)
                showAbout()
            }
        }
    }
}
