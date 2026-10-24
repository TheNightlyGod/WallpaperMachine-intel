import AppKit
import Foundation
import UniformTypeIdentifiers

/// Settings › Storage and Library: opening the folders, clearing what can be rebuilt, exporting the
/// diagnostics report and the local backup.
///
/// The confirmations and the file picker are asked before the work is queued, so an open sheet holds
/// up no wallpaper switch; the banner is still cleared first, as it is for any queued action. Without
/// a window every confirmation and picker answers no, and the action does nothing.
extension PanelController {
  // MARK: Folders

  /// `showLibrary`: the wallpaper library in Finder.
  func showLibrary() async throws {
    try await run(.queued) { _ = openSystemURL(ClientPaths.libraryURL) }
  }

  /// `showLogs`: the folder the diagnostic logs are written to.
  func showLogs() async throws {
    try await run(.queued) { _ = openSystemURL(try store.logFolderURL()) }
  }

  /// `revealUserAssets`: the folder the files chosen in wallpaper settings are copied to, created first
  /// so the user is never shown an error for a folder they have simply not filled yet.
  func revealUserAssets() async throws {
    try await run(.queued) { UserAssetStorage.revealManagedDirectory() }
  }

  // MARK: Library location

  // A move is not queued: the copy can take minutes, and wallpapers keep switching meanwhile. The
  // store refuses a second one while one copies. The folder picker and the confirmation come first.

  /// `moveLibrary`: asks for a folder, checks it, says what the move copies and where, and prepares
  /// the move for the next launch.
  func moveLibrary() async throws {
    errors.clearAction()
    let panel = NSOpenPanel()
    panel.title = L("Move Wallpaper Library")
    panel.message = L(
      "Choose where to keep the wallpaper library and downloads, such as an external drive. WallpaperMachine creates a folder named WallpaperMachine there.")
    panel.prompt = L("Choose")
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.directoryURL = URL(fileURLWithPath: "/Volumes", isDirectory: true)
    guard let folder = await dialogs.choose(panel) else { return }
    try await prepareLibraryMove(to: folder)
  }

  /// `moveLibraryToThisMac`: brings the library and the downloads back into WallpaperMachine's own
  /// folder on this Mac, after a confirmation.
  func moveLibraryToThisMac() async throws {
    errors.clearAction()
    try await prepareLibraryMove(to: nil)
  }

  private func prepareLibraryMove(to folder: URL?) async throws {
    let plan = try await libraryLocation.plan(moveTo: folder)
    let size = ByteSize.text(Double(plan.bytes), locale: PanelLocale.shared.locale)
    let destination = plan.targetRoot.path
    let detail =
      plan.copies
      ? L(
        "WallpaperMachine copies \(size) to “\(destination)” now, and you can keep using it meanwhile. The move finishes the next time you open WallpaperMachine, which then deletes the old copy.")
      : L("The library and downloads move to “\(destination)” the next time you open WallpaperMachine.")
    let title = folder == nil ? L("Move the wallpaper library back to this Mac?") : L("Move the wallpaper library?")
    guard await dialogs.confirm(title, detail: detail, button: L("Move")) else { return }
    try await run(.immediate) { try await libraryLocation.move(plan) }
  }

  /// `cancelLibraryCopy`: stops the copy being prepared and removes what it copied.
  func cancelLibraryCopy() async throws {
    try await run(.immediate) { libraryLocation.cancel() }
  }

  /// `cancelLibraryMove`: forgets the move waiting for the next launch and removes its copy.
  func cancelLibraryMove() async throws {
    try await run(.immediate) { try libraryLocation.cancelPending() }
  }

  // MARK: Clearing

  /// Asks, then queues `operation`. Returns whether the user agreed.
  @discardableResult
  private func confirmedChange(
    _ title: String, detail: String, button: String, _ operation: @MainActor () async throws -> Void
  ) async throws -> Bool {
    errors.clearAction()
    guard await dialogs.confirm(title, detail: detail, button: button) else { return false }
    return try await run(.queued, operation)
  }

  /// `clearCache`: removes compiled shaders after a confirmation. They are rebuilt when wallpapers need them.
  func clearShaderCache() async throws {
    try await confirmedChange(
      L("Clear shader cache?"), detail: L("Shaders are rebuilt the next time wallpapers need them."),
      button: L("Clear Cache")
    ) { try await store.clearShaderCacheAsync() }
  }

  /// `clearLogs`: removes the diagnostic logs after a confirmation. Wallpapers and settings are not affected.
  func clearLogs() async throws {
    try await confirmedChange(
      L("Clear logs?"),
      detail: L("Only diagnostic logs are removed. Wallpapers and settings are not affected."),
      button: L("Clear Logs")
    ) { try store.clearLogsAsync() }
  }

  /// `purgeUnreferencedUserAssets`: removes the caches no manifest lists, after a confirmation, and
  /// remembers how much that released.
  ///
  /// Named for what it does: the manifest's files are user-imported originals that nothing can
  /// regenerate, so the confirmation says what is kept, not only what goes.
  func purgeUnreferencedUserAssets() async throws {
    try await confirmedChange(
      L("Clear unused caches?"),
      detail: L(
        "Only caches that can be rebuilt are removed. Files you chose in wallpaper settings are kept."),
      button: L("Clear Caches")
    ) {
      let released = try await UserAssetStorage.purgeUnreferencedDerivedCaches()
      // A negative figure would be a bug in the accounting, not a real amount, so it is reported as
      // nothing released rather than wrapped.
      userAssetsReleasedBytes = UInt64(max(0, released))
    }
  }

  // MARK: Diagnostics

  /// `exportDiagnostics`: asks where to save the report, writes it, and shows it in Finder. Nothing
  /// is written until a destination is chosen.
  func exportDiagnostics() async throws {
    errors.clearAction()
    let panel = NSSavePanel()
    panel.title = L("Export Diagnostics")
    panel.message = L("Attach this file to your bug report.")
    panel.nameFieldStringValue = DiagnosticsBundle.suggestedFileName(at: Date())
    panel.allowedContentTypes = [.zip]
    panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
    guard let destination = await dialogs.choose(panel) else { return }
    try await run(.queued) {
      try await exportDiagnostics(to: destination)
      revealDiagnosticsReport(destination)
    }
  }

  /// Writes the diagnostics bundle off the main actor: reading and redacting up to 64 MB of logs
  /// must not stall the panel.
  func exportDiagnostics(to destination: URL) async throws {
    let settings = store.settingsSnapshot
    let throttle = settings.qualityThrottle.map { QualityCause($0).rawValue }.joined(separator: ", ")
    var environment = DiagnosticEnvironment.current()
    environment.append(
      """
      settings: scene resolution \(settings.sceneResolution), \
      render scale \(settings.renderScale) (preferred \(settings.preferredRenderScale)), battery mode \
      \(settings.batteryMode), frame-rate cap \(settings.frameRateCap.map(String.init) ?? "none"), on battery \
      \(settings.onBatteryPower), reduced quality for \(throttle.isEmpty ? "nothing" : throttle), effective \
      frame-rate cap \(settings.effectiveFrameRateCap.map(String.init) ?? "none"), verbose logging \
      \(settings.verboseLogging)
      """)
    for scene in settings.sceneRenderers {
      let mode = settings.sceneUpdateModes.first { $0.displayId == scene.displayId }?.mode
      environment.append(DiagnosticEnvironment.runningSceneLine(scene, mode: mode))
    }
    // Read once, here: the report is the only consumer, so nothing polls the window server.
    environment.append(contentsOf: DesktopWindowDiagnostics.current())
    environment.append(
      ProcessFootprint.reportLine(
        bytes: ProcessFootprint.current(),
        wallpaperWindows: WallpaperPresentationPolicy.wallpaperWindows().count))
    let bundle = DiagnosticsBundle(
      sources: DiagnosticsBundle.sources(logsRoot: try store.logFolderURL()),
      redactor: DiagnosticsRedactor(
        homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path,
        userNames: [NSUserName(), NSFullUserName()],
        secrets: [workshop.downloader.savedAccount].compactMap { $0 }))
    let date = Date()
    let report = try await Task.detached(priority: .userInitiated) {
      try bundle.export(to: destination, environment: environment, at: date)
    }.value
    AppLog.info(
      """
      diagnostics exported: \(report.included.count) files\
      \(report.missing.isEmpty ? "" : "; not included: \(report.missing.joined(separator: "; "))")
      """)
  }

  // MARK: Backup

  // The backup actions are not queued and leave an older banner alone: the store has its own
  // busy flag, status and error, and refuses a second operation while one runs ("Another backup
  // operation is already running."). A failure sets the store's error and throws, so the banner
  // shows it too.

  /// `backupExport`: copies the settings and the files chosen for wallpapers, and the library when
  /// `includeLibrary`, to a package the user names.
  func exportBackup(includeLibrary: Bool) async throws {
    try await run(.immediate) { try await backup.export(includeLibrary: includeLibrary) }
  }

  /// `backupPreview`: asks for a package and reads what it holds and where it disagrees with this Mac.
  func previewBackup() async throws {
    try await run(.immediate) { try await backup.choosePreview() }
  }

  /// `backupRestore`: stages the previewed package to be restored at the next launch. Nothing changes
  /// now, and the app neither quits nor restarts.
  func restoreBackup(policy: WallpaperBackupConflictPolicy) async throws {
    try await run(.immediate) { try await backup.stageRestore(policy: policy) }
  }

  /// `backupCancel`: stops the operation that is running.
  func cancelBackup() async throws {
    try await run(.immediate) { backup.cancel() }
  }

  /// `backupCancelRestore`: removes a staged restore.
  func cancelPendingRestore() async throws {
    try await run(.immediate) { try backup.cancelRestore() }
  }
}
