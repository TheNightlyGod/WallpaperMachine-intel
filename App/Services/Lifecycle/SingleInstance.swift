import AppKit

/// Applies the one-copy-per-library rule when the process starts.
///
/// This runs before anything touches the library, so a second copy never restores a backup over,
/// or starts a renderer against, files the first one is using.
enum SingleInstance {
    /// Claims the library for this process, or hands over to the copy that owns it and exits.
    @MainActor
    static func claim(supportURL: URL = ClientPaths.supportURL) {
        let file = supportURL.appendingPathComponent(InstanceLock.fileName)
        switch InstanceLock.acquire(at: file) {
        case let .acquired(lock):
            InstanceLock.current = lock
        case let .proceedUnlocked(reason):
            AppLog.warn("startup: single-instance lock unavailable (\(reason)); continuing without it")
        case let .heldBy(holder):
            handOff(to: holder)
        }
    }

    @MainActor
    private static func handOff(to holder: InstanceLock.Holder) {
        let action = InstanceHandOff.action(
            holderExecutable: InstanceHandOff.executablePath(ofProcess: holder.pid),
            ownExecutable: InstanceHandOff.executablePath(ofProcess: getpid()))
        switch action {
        case .proceedUnlocked:
            AppLog.warn("startup: the library lock is held by pid \(holder.pid), which is not a copy of this app; continuing without it")
        case .reopenRunningCopy:
            AppLog.detachToStandardError()
            AppLog.info("startup: another copy of this app (pid \(holder.pid)) is running; handing over to it")
            reopenRunningCopy()
            exit(0)
        case .warnAboutOtherCopy:
            AppLog.detachToStandardError()
            AppLog.warn("startup: a copy of this app from another location (pid \(holder.pid)) is using this library")
            warnAboutOtherCopy()
            exit(0)
        }
    }

    /// Opening the bundle that is already running brings it forward and sends it the reopen event
    /// that shows its panel, the same as a Dock click would.
    @MainActor
    private static func reopenRunningCopy() {
        let finished = DispatchSemaphore(value: 0)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            if let error { AppLog.warn("startup: could not reopen the running copy: \(error.localizedDescription)") }
            finished.signal()
        }
        // The request only reaches LaunchServices while this process is alive, so wait for the
        // answer, pumping the run loop in case the system wants it, and give up after a few seconds.
        let deadline = Date().addingTimeInterval(3)
        while finished.wait(timeout: .now() + 0.02) == .timedOut, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    @MainActor
    private static func warnAboutOtherCopy() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(localized: "WallpaperMachine is already running")
        alert.informativeText = String(localized:
            "Another copy of WallpaperMachine is using this library. Quit it before opening this one.")
        application.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
