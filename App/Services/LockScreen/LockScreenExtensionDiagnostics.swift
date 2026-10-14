import Foundation

enum LockScreenExtensionDiagnostics {
  static let differentCopyMessage = String(localized: "macOS is still loading the wallpaper renderer from another copy of WallpaperMachine. Close other running copies, then retry in this app.")

  static func failure(
    status: LockScreenExtensionStatus, revision: String, expectedBundle: URL
  ) -> LockScreenWallpaperFailure? {
    guard status.revision == revision else { return nil }
    if !isSameBundle(URL(fileURLWithPath: status.bundlePath), expectedBundle) {
      return LockScreenWallpaperFailure(message: differentCopyMessage, reason: .differentExtensionCopy)
    }
    if status.supportedVersion != LockScreenConfiguration.supportedVersion {
      return LockScreenWallpaperFailure(message: String(localized: "The app and the lock-screen renderer use incompatible configuration versions. Quit other copies of WallpaperMachine and reopen the intended app, then retry."))
    }
    if let error = status.error {
      return LockScreenWallpaperFailure(message: String(localized: "The lock-screen renderer could not load its configuration: \(error)"))
    }
    return nil
  }

  static func isSameBundle(_ first: URL, _ second: URL) -> Bool {
    // URL equality also compares directory hints/trailing slashes.
    first.resolvingSymlinksInPath().standardizedFileURL.path
      == second.resolvingSymlinksInPath().standardizedFileURL.path
  }

  /// Legacy extensions cannot send diagnostics. Inspect only this user's extension processes
  /// after a timeout; an old process still exiting during activation is not itself a failure.
  static func runningExtensionBundles() -> [URL] {
    LockScreenExtensionProcesses.live.list().compactMap(\.bundle)
  }
}
