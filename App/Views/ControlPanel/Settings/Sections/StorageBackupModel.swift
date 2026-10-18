import Observation

/// The choices of Settings › Storage › Backup that live between choosing a package and restoring it.
///
/// They belong to the page, not to the stores: whether Export also copies the wallpaper library,
/// and which side wins where the package and this Mac disagree. They start as the safe answers (no
/// library copy, keep what is on this Mac), outlive the page being rebuilt, and are read when the
/// button is pressed. The controller's backup actions do the work.
@MainActor
@Observable
final class StorageBackupModel {
  unowned let controller: PanelController

  /// Export copies every installed wallpaper as well, which can take a lot of space.
  var includeLibrary = false
  /// What a restore does with an item that exists in the package and on this Mac.
  var policy = WallpaperBackupConflictPolicy.keepExisting

  init(controller: PanelController) { self.controller = controller }

  /// Whether Export, Choose backup…, the library switch and Restore can be used: no wallpaper
  /// command or backup operation runs, and no restore waits for the next launch (it waits for that
  /// launch or for its own Cancel restore).
  var canStart: Bool { !controller.isStoreBusy && controller.backupPresentation.canStartOperation }

  func export() async throws {
    try await controller.exportBackup(includeLibrary: includeLibrary)
  }

  /// Asks for a package to read. A package that is read starts from the safe answer again, so a
  /// Replace chosen for one package is never carried to another.
  func choose() async throws {
    policy = .keepExisting
    try await controller.previewBackup()
  }

  /// Stages the previewed package with the policy chosen, to apply at the next launch.
  func restore() async throws {
    try await controller.restoreBackup(policy: policy)
  }
}
