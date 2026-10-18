import Foundation

/// Settings › About › Updates: the buttons of the card `UpdatePresentation` describes.
///
/// None is queued and none clears the banner except installing: checking, downloading, cancelling and
/// opening the releases page never touch the renderer, so they never wait behind a wallpaper switch.
extension PanelController {
  /// `checkForUpdates`.
  func checkForUpdates() async throws {
    try await run(.immediate) { _ = await updater.checkForUpdates() }
  }

  /// `downloadUpdate`.
  func downloadUpdate() async throws {
    try await run(.immediate) { _ = await updater.downloadUpdate() }
  }

  /// `cancelUpdate`: stops preparing a downloaded update.
  func cancelUpdate() async throws {
    try await run(.immediate) { updater.cancel() }
  }

  /// `openReleases`: the GitHub releases page, for an update that has no download to install.
  func openReleases() async throws {
    try await run(.immediate) { updater.openReleases() }
  }

  /// `revealDownloadedUpdate`: the downloaded disk image in Finder.
  func revealDownloadedUpdate() async throws {
    try await run(.immediate) { updater.revealDownloadedUpdate() }
  }

  /// `installUpdate`: asks first, then quits the app and replaces it with the downloaded update.
  /// Without a window nobody can answer, so an offscreen panel never replaces the app.
  ///
  /// The question is asked before queueing, so an open sheet holds up nothing else; the banner is
  /// cleared first, as for any queued action. Returns whether the user agreed.
  @discardableResult
  func installUpdate() async throws -> Bool {
    errors.clearAction()
    guard
      await dialogs.confirm(
        L("Restart and install this update?"),
        detail: L("The current app will quit and be replaced. Wallpapers and settings are kept."),
        button: L("Restart and Install"))
    else { return false }
    return try await run(.queued) { await updater.installUpdate() }
  }
}
