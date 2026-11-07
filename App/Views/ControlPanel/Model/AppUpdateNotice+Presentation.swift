import Foundation

extension AppUpdateNotice {
  @MainActor var title: String {
    switch kind {
    case .available: L("Version \(version) is available")
    case .downloading: L("Downloading version \(version) — \(percent) percent")
    case .verifying: L("Verifying update…")
    case .ready:
      automatic ? L("Version \(version) will install when your Mac is locked or its display sleeps.")
        : L("Version \(version) is ready. Restart the app to install it.")
    case .deferred: L("Version \(version) is postponed for 24 hours.")
    case .failed: L("Version \(version) needs attention. Open Updates to retry.")
    case .installed: L("Updated to version \(version)")
    }
  }
}

extension AppUpdateMode {
  @MainActor var title: String {
    switch self {
    case .notify: L("Check and notify")
    case .download: L("Download automatically")
    case .automatic: L("Download and install automatically")
    }
  }

  @MainActor var explanation: String {
    switch self {
    case .notify: L("Updates are checked in the background. You choose when to download and restart.")
    case .download: L("Updates download in the background. You choose when to restart and install.")
    case .automatic: L("Updates download in the background and install while the display sleeps or the Mac is locked; WallpaperMachine quits and reopens to finish.")
    }
  }
}
