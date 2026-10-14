import AppKit

/// AppKit owns the control panel and menu-bar lifecycle. A placeholder SwiftUI
/// Settings scene can create an empty window independently of that control panel.
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
            do {
                if let report = try WallpaperBackupService.applyPendingRestore() {
                    AppLog.info("startup: restored \(report.restoredPaths.count) backup resources")
                    for warning in report.warnings { AppLog.warn("backup restore: \(warning)") }
                }
            } catch {
                AppLog.error("startup backup restore failed: \(error.localizedDescription)")
            }
        }
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
