import Foundation

/// What the window's title says (the Window menu, Mission Control; the tabs stand for it in the
/// title bar): the place on show, and a line of detail under it.
///
/// Installed follows the library view the chips light, as a Finder window names its folder: a
/// shown collection by its name, else Favorites, else All wallpapers, with how many wallpapers it
/// holds (and, for All wallpapers, how many have an update). Settings is named by its section, or by
/// "Search results" while a search is typed. Steam Workshop says under its name what is on show and
/// how many it holds (`workshopSubtitle`). The pixiv name is a proper noun and is never translated.
/// It is text, never a control.
struct PanelTitle: Equatable {
  let title: String
  let subtitle: String?

  /// - Parameters:
  ///   - scope: The part of the library Installed shows.
  ///   - counts: The library's counts, nil while the library is still loading, which leaves the
  ///     subtitle out rather than say "0 wallpapers".
  ///   - workshopSubtitle: The Workshop page's line (`PanelController.workshopTitleSubtitle`).
  @MainActor
  static func make(
    selection: SidebarSelection, scope: LibraryScope = .all, counts: SidebarCounts? = nil,
    settingsSection: SettingsSection = .quick, searchQuery: String = "",
    workshopSubtitle: String? = nil, locale: PanelLocale? = nil
  ) -> PanelTitle {
    let locale = locale ?? .shared
    switch selection {
    case .wallpaper:
      return library(scope: scope, counts: counts, locale: locale)
    case .workshop:
      return PanelTitle(title: locale.string("Steam Workshop"), subtitle: workshopSubtitle)
    case .pixiv:
      return PanelTitle(title: "pixiv", subtitle: nil)
    case .settings:
      let searching = !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      let title =
        searching
        ? locale.string("Search results") : locale.string(resolving: settingsSection.title)
      return PanelTitle(title: title, subtitle: nil)
    }
  }

  @MainActor
  private static func library(scope: LibraryScope, counts: SidebarCounts?, locale: PanelLocale)
    -> PanelTitle
  {
    // A collection that is gone shows what the grid falls back to: every wallpaper.
    var scope = scope
    if case .collection(let id) = scope, counts?.collections.contains(where: { $0.id == id }) == false {
      scope = .all
    }
    let title: String
    let count: Int?
    switch scope {
    case .all:
      title = locale.string("All wallpapers")
      count = counts?.all
    case .favorites:
      title = locale.string("Favorites")
      count = counts?.favorites
    case .collection(let id):
      let collection = counts?.collections.first { $0.id == id }
      title = collection?.name ?? locale.string("All wallpapers")
      count = collection?.count
    }
    guard let count, let counts else { return PanelTitle(title: title, subtitle: nil) }
    var parts = [count == 1 ? locale.string("\(count) wallpaper") : locale.string("\(count) wallpapers")]
    if scope == .all, counts.updates > 0 {
      parts.append(
        counts.updates == 1
          ? locale.string("\(counts.updates) update") : locale.string("\(counts.updates) updates"))
    }
    return PanelTitle(title: title, subtitle: parts.joined(separator: " · "))
  }
}
