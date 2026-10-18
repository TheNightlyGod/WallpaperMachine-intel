import Foundation

/// What the Installed inspector's views ask of the controller that no other group serves.
extension PanelController {
  /// Whether **Reinstall from Workshop…** is offered for an installed wallpaper: it is a Workshop
  /// item (its id is the Workshop's number) that can run on macOS, with no download under way and
  /// no request waiting for setup. The Compatibility check offers it too, for what a fresh copy
  /// repairs. A wallpaper that is not installed has nothing to reinstall.
  func canReinstall(_ id: String) -> Bool {
    guard let row = libraryRow(id: id) else { return false }
    return InspectorPolicy.canReinstall(
      row, hasPendingDownload: steamDownloadRow(for: id)?.isPending == true,
      hasRequest: downloadRequestRow(for: id) != nil)
  }

  /// The problem report the inspector's menu offers for `row` (`InspectorPolicy.issueReport`):
  /// GitHub's form with the failure applying it just met, a plain one for a wallpaper that can run,
  /// and nil for one that cannot or for a scene waiting for the shared resources.
  func inspectorIssueReportURL(for row: LibraryRow) -> URL? {
    switch inspectorIssueReport(for: row) {
    case .none: nil
    case .plain: issueReportURL(for: row.id)
    case .failure(let failure): issueReportURL(for: row.id, failure: failure)
    }
  }

  /// What `inspectorIssueReportURL(for:)` offers, which the failure notice and the plain link
  /// under the type sentence follow too.
  func inspectorIssueReport(for row: LibraryRow) -> InspectorPolicy.IssueReport {
    InspectorPolicy.issueReport(
      for: row, failure: activationFailures[row.id],
      sceneResourcesMissing: workshopSceneAssetsAreMissing(for: row))
  }

  /// Whether the inspector offers **Show in downloads** under the wallpaper: a download of it is in
  /// the list, under way, waiting or finished, or a request for one waits for a prerequisite.
  func offersShowInDownloads(for id: String) -> Bool {
    steamDownloadRow(for: id) != nil || downloadRequestRow(for: id) != nil
  }

  /// Whether **Move wallpaper to Trash** can be chosen. Only its own delete under way holds it:
  /// the confirmation is asked outside the command queue and the move then waits its turn, so
  /// another command running (an edit, an apply) is no reason to refuse.
  func canMoveToTrash(_ id: String) -> Bool {
    !isBusy(PanelActionCoordinator.key("delete", id: id))
  }

  /// A scene needs Wallpaper Engine's shared resources before it can play.
  func workshopSceneAssetsAreMissing(for row: LibraryRow) -> Bool {
    row.kind == .scene && !workshop.sceneAssetsReady
  }

  /// Whether the shared scene resources are on their way: their download is waiting or running,
  /// so the scene notice shows that download instead of asking for it again.
  var sceneResourcesArePending: Bool {
    steamDownloadRow(for: WorkshopStore.sceneAssetsRequestID)?.isPending == true
  }

  /// **Preview wallpaper**: opens the live preview of an installed wallpaper on the target display
  /// with the text typed into its properties and not yet committed, so the preview shows what the
  /// person is writing. Changes nothing on the desktop.
  func previewWithTypedText(_ id: String) async throws {
    let texts = Dictionary(
      uniqueKeysWithValues: store.editorState.propertyTextDrafts
        .filter { $0.key.wallpaperID == id }.map { ($0.key.fieldID, $0.value) })
    try await previewWallpaper(id, textOverrides: texts)
  }
}
