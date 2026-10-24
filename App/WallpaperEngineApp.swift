import AppKit

@main
struct WallpaperEngineApp {
    @MainActor
    static func main() {
        // First, so the import picker's helper process is covered too.
        ProcessSignals.ignoreBrokenPipes()
        if WallpaperImportPickerHelper.runIfRequested() { return }
        if NSClassFromString("XCTestCase") == nil {
            // First, so a second copy never restores a backup over files the first one is using
            // and never overwrites the running copy's session record.
            SingleInstance.claim()
            recordSessionStart()
            // Before the backup restore, which writes into the library where it now is.
            StorageMoveService.applyPending()
            // A library on a drive that is not connected is not restored into: the restore waits.
            if case .unavailable = ClientPaths.storageResolution {
                AppLog.warn("startup: the wallpaper library is not available; a pending restore waits")
            } else {
                do {
                    if let report = try WallpaperBackupService.applyPendingRestore(storageRoot: ClientPaths.storageURL) {
                        AppLog.info("startup: restored \(report.restoredPaths.count) backup resources")
                        for warning in report.warnings { AppLog.warn("backup restore: \(warning)") }
                    }
                } catch {
                    AppLog.error("startup backup restore failed: \(error.localizedDescription)")
                }
            }
        }
        // AppKit owns the control panel and the menu-bar item, so a SwiftUI scene here would only
        // add an empty window; the app has none.
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) {
            application.run()
        }
    }

    /// Opens this run's record in the session ledger, which says how the run before it
    /// ended, and starts naming any exception that ends this one. Before anything that
    /// can fail at startup, so even a launch that dies early is on record.
    @MainActor
    private static func recordSessionStart() {
        let previous = SessionLedger.beginProcessSession()
        let line = "previous session: \(previous.summary)"
        if previous.outcome.isAbnormal { AppLog.warn(line) } else { AppLog.info(line) }
        TelemetryLaunchRecord.previousOutcome = previous.outcome
        UncaughtExceptionLog.install()
        guard previous.outcome.isUnexpectedEnd, let launch = previous.launch else { return }
        TelemetryLaunchRecord.crashReportFound = false
        // The crash report is written by ReportCrash after the process is gone and may
        // not exist when the next launch begins. Looking later keeps the lookup off startup.
        Task.detached(priority: .utility) {
            try? await Task.sleep(for: .seconds(20))
            guard let report = CrashReportIndex.report(
                forPid: launch.pid, bootSession: launch.bootSession, notBefore: launch.startedAt,
                in: CrashReportIndex.userReportsFolder()) else { return }
            AppLog.info("previous session crash report: \(report.summary)")
            await MainActor.run { TelemetryLaunchRecord.crashReportFound = true }
        }
    }
}
