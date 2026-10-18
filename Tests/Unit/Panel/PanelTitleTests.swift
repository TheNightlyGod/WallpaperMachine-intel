import XCTest

@testable import WallpaperMachine

/// What the window's title and its subtitle say for every page, the way the sidebar names it.
@MainActor
final class PanelTitleTests: XCTestCase {
  private let japanese = PanelLocale(language: AppLanguage.named("ja") ?? .english, region: nil)
  private let english = PanelLocale(language: .english, region: nil)

  private func counts(
    all: Int = 248, favorites: Int = 31, updates: Int = 0,
    collections: [SidebarCounts.Collection] = [.init(id: "night", name: "Night", count: 1)]
  ) -> SidebarCounts {
    SidebarCounts(all: all, favorites: favorites, updates: updates, collections: collections)
  }

  private func make(
    _ selection: SidebarSelection, scope: LibraryScope = .all, counts: SidebarCounts? = nil,
    section: SettingsSection = .quick, query: String = "", in locale: PanelLocale? = nil
  ) -> PanelTitle {
    PanelTitle.make(
      selection: selection, scope: scope, counts: counts, settingsSection: section,
      searchQuery: query, locale: locale ?? english)
  }

  func testPagesAreNamedAndPixivIsNeverTranslated() {
    XCTAssertEqual(make(.pixiv, in: japanese).title, "pixiv", "a proper noun")
    XCTAssertNotEqual(make(.workshop, in: japanese).title, make(.workshop).title)
    XCTAssertNotEqual(make(.wallpaper, in: japanese).title, make(.wallpaper).title)
    XCTAssertEqual(make(.workshop).title, english.string("Steam Workshop"))
    XCTAssertNil(make(.workshop).subtitle, "the other pages have nothing to count here")
    XCTAssertNil(make(.pixiv).subtitle)
  }

  func testInstalledFollowsTheLibraryViewTheSidebarLights() {
    let counts = counts()
    XCTAssertEqual(make(.wallpaper, counts: counts).title, english.string("All wallpapers"))
    XCTAssertEqual(
      make(.wallpaper, scope: .favorites, counts: counts).title, english.string("Favorites"))
    XCTAssertEqual(make(.wallpaper, scope: .collection("night"), counts: counts).title, "Night")
    XCTAssertEqual(
      make(.wallpaper, scope: .collection("gone"), counts: counts).title,
      english.string("All wallpapers"), "a deleted collection is not named")
    XCTAssertEqual(
      make(.workshop, scope: .collection("night"), counts: counts).title,
      english.string("Steam Workshop"), "the other pages ignore the library view")
  }

  private func wallpapers(_ count: Int, in locale: PanelLocale? = nil) -> String {
    let locale = locale ?? english
    return count == 1 ? locale.string("\(count) wallpaper") : locale.string("\(count) wallpapers")
  }

  private func updates(_ count: Int) -> String {
    count == 1 ? english.string("\(count) update") : english.string("\(count) updates")
  }

  func testTheSubtitleCountsTheViewAndAllWallpapersAddsTheUpdates() {
    XCTAssertEqual(make(.wallpaper, counts: counts()).subtitle, wallpapers(248))
    XCTAssertEqual(
      make(.wallpaper, counts: counts(updates: 3)).subtitle, "\(wallpapers(248)) · \(updates(3))")
    XCTAssertEqual(
      make(.wallpaper, counts: counts(updates: 1)).subtitle, "\(wallpapers(248)) · \(updates(1))")
    XCTAssertNotEqual(updates(1), updates(3), "one is not 'updates'")
    XCTAssertEqual(
      make(.wallpaper, scope: .favorites, counts: counts(updates: 3)).subtitle, wallpapers(31),
      "only the whole library reports updates")
    XCTAssertEqual(
      make(.wallpaper, scope: .collection("night"), counts: counts()).subtitle, wallpapers(1))
    XCTAssertNotEqual(wallpapers(1), wallpapers(2), "one is not 'wallpapers'")
    XCTAssertEqual(
      make(.wallpaper, counts: counts(), in: japanese).subtitle, wallpapers(248, in: japanese))
    XCTAssertNotEqual(wallpapers(248, in: japanese), wallpapers(248))
  }

  func testNothingIsCountedWhileTheLibraryLoadsInsteadOfSayingNoneWereFound() {
    XCTAssertNil(make(.wallpaper, counts: nil).subtitle)
    XCTAssertNil(make(.wallpaper, scope: .favorites, counts: nil).subtitle)
    XCTAssertEqual(
      make(.wallpaper, counts: counts(all: 0)).subtitle, wallpapers(0), "an empty library is a fact")
  }

  func testSettingsNamesItsSectionAndASearchNamesItself() {
    XCTAssertEqual(
      make(.settings, section: .appearance).title,
      english.string(resolving: SettingsSection.appearance.title))
    XCTAssertEqual(
      make(.settings, section: .appearance, in: japanese).title,
      japanese.string(resolving: SettingsSection.appearance.title))
    XCTAssertEqual(
      make(.settings, section: .appearance, query: "  mute ").title,
      english.string("Search results"))
    XCTAssertEqual(
      make(.settings, section: .appearance, query: "   ").title,
      english.string(resolving: SettingsSection.appearance.title), "spaces are not a search")
    XCTAssertNil(make(.settings).subtitle)
  }
}
