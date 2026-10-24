import Foundation

/// Small readings the Steam Workshop page and its inspector need over the typed model: the selected
/// item, the window's subtitle, the library's own cover for a copy that is installed, and the problem
/// report of an item that is not installed. The rules are the page's own; nothing here changes state.
extension PanelController {
  /// The item the inspector shows: the selected one, while it is on the page. Selecting something
  /// and then paging away leaves the inspector empty, as it always did.
  var workshopSelectedItem: WorkshopItem? {
    let browse = workshopBrowse
    guard let id = browse.selectedID else { return nil }
    return browse.items.first { $0.id == id }
  }

  /// The line under the window's title on the Steam Workshop page: what is on show and, once it has
  /// loaded, how many it holds ("Wallpapers · 18,420 results", "Wallpapers by Ana · 12 results").
  ///
  /// It reads only the store's list-level values, never the tiles or the selection, so the window's
  /// title is not redrawn when a tile is selected or a download moves. The source is named as
  /// `WorkshopBrowseState` names it.
  var workshopTitleSubtitle: String {
    let shown = workshop.source
    let named = workshop.committedQuery?.source == shown ? workshop.sourceTitle : nil
    let source = WorkshopSourceState(
      source: shown, name: named ?? shown.name, canGoBack: !workshop.sourceHistory.isEmpty)
    let summary = WorkshopSummary.make(
      source: shown, isLoading: workshop.isLoading, isSignedIn: workshop.steamWebSession != nil,
      hasLoaded: workshop.hasLoaded, totalCount: workshop.totalCount,
      isLookup: workshop.committedQuery?.itemID != nil, isDegraded: workshop.isDegraded)
    return source.titleSubtitle(summary: summary)
  }

  /// The still of a Workshop item that is in the library: the library's own cover, the same picture
  /// the Installed page shows, with nothing while its stamp is still being read. A tile shows this
  /// and not Steam's preview once the wallpaper is installed.
  func workshopInstalledStill(for id: String) -> PanelImageSource? {
    libraryRow(id: id)?.still
  }

  /// Whether **Reinstall from Workshop…** is offered for an installed item: a Workshop wallpaper
  /// (its id is the Workshop's number) that runs on macOS, with no download under way and no
  /// request waiting for a prerequisite.
  func canReinstallWorkshopItem(_ item: WorkshopItem) -> Bool {
    guard item.id.allSatisfy(\.isNumber), item.canRunOnMac, mediaLibraryContains(item.id) else {
      return false
    }
    return steamDownloadRow(for: item.id)?.isPending != true && downloadRequestRow(for: item.id) == nil
  }

  /// GitHub's bug report form for a Workshop item whose download failed, filled with the item, its
  /// type, the app version and the failure. Nothing is sent from here: the browser opens the draft
  /// and the person decides whether to submit it. (An installed wallpaper's report is
  /// `issueReportURL(for:failure:)`.)
  func workshopIssueReportURL(
    for item: WorkshopItem, failure: String,
    version: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
      as? String
  ) -> URL? {
    let page = ExternalLink.workshopItem(id: item.id)?.absoluteString ?? item.id
    let facts = ["**Wallpaper:** \(item.title)", "**Type:** \(item.kind.rawValue)", "**Error:** \(failure)"]
    return ExternalLink.newIssue(
      title: "[\(item.kind.rawValue)] \(item.title)", wallpaper: page, version: version ?? "unknown",
      details: facts.joined(separator: "\n"))
  }
}
