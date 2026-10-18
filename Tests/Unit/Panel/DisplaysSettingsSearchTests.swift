import XCTest

@testable import WallpaperMachine

/// What a Settings search finds on Settings › Displays: the rows built from live data (a display's
/// name, a saved layout, a wallpaper of a display's list) count as items do, and each display's card
/// keeps only what that display draws.
@MainActor
final class DisplaysSettingsSearchTests: SettingsBTestCase {
  private typealias S = DisplaysSettingsSection

  private func search(_ query: String, live: [SettingsLiveUnit] = []) -> SettingsSearch {
    let english = PanelLocale(language: .english, region: nil)
    return SettingsSearch(query: query, index: SettingsIndex(locale: english), live: live)
  }

  // MARK: Live rows in the search

  func testALiveRowThatMatchesKeepsItsSectionAndGroupAndCounts() {
    let live = [
      SettingsLiveUnit(section: .displays, text: "Studio Display (1 - Primary)"),
      SettingsLiveUnit(section: .displays, group: S.layouts, text: "Work\nStudio Display (1 - Primary): Aurora Bay"),
    ]
    let studio = search("studio", live: live)
    XCTAssertTrue(studio.shows(.displays), "a display's name finds the Displays page")
    XCTAssertFalse(studio.hasNoResults)
    XCTAssertEqual(studio.count(in: .displays), 2, "the card and the layout that names it")
    XCTAssertTrue(studio.shows(S.layouts, in: .displays), "a matching layout keeps its group")
    XCTAssertFalse(studio.shows(S.plans, in: .displays))

    let aurora = search("Aurora", live: live)
    XCTAssertEqual(aurora.count(in: .displays), 1)
    XCTAssertTrue(search("zzz-nothing", live: live).hasNoResults)
    XCTAssertFalse(search("", live: live).isActive, "without a query nothing is counted")
  }

  func testAnItemMatchesItselfOnlyByItsOwnWordsNotByWhatItHolds() {
    let shuffle = search("Shuffle")
    XCTAssertTrue(shuffle.shows(S.playlist), "the disclosure holding Order shows")
    XCTAssertFalse(shuffle.matchesItself(S.playlist), "but its own words do not say Shuffle")
    XCTAssertTrue(shuffle.matchesItself(S.playlistOrder))
    XCTAssertTrue(search("Day and night").matchesItself(S.playlist))
  }

  // MARK: One display's card

  private func card(_ query: String, title: String = "Display", rows: DisplaysCardSearch.Rows,
                    list: [(id: String, title: String)] = []) -> DisplaysCardSearch {
    DisplaysCardSearch(search: search(query), title: title, rows: rows, listTitles: list)
  }

  private let rotateList = DisplaysCardSearch.Rows(playlistMode: .rotate, listsOwnWallpapers: true, hasPeers: true)
  private let dayNight = DisplaysCardSearch.Rows(playlistMode: .dayNight)
  private let mirror = DisplaysCardSearch.Rows(isMirror: true)

  func testWithoutAQueryEveryCardAndDisclosureShows() {
    let card = card("", rows: mirror)
    XCTAssertTrue(card.showsCard)
    XCTAssertFalse(card.forced)
    XCTAssertTrue(card.showsDisclosure(S.automation))
    XCTAssertFalse(card.opens(S.automation))
  }

  /// A match on a row that only some displays draw keeps only their cards, and opens the disclosure
  /// on them; the others draw no empty card or disclosure.
  func testARowMatchKeepsOnlyTheCardsThatDrawThatRow() {
    let rotating = card("Shuffle", rows: rotateList)
    XCTAssertTrue(rotating.showsCard)
    XCTAssertTrue(rotating.showsDisclosure(S.playlist))
    XCTAssertTrue(rotating.opens(S.playlist))
    XCTAssertFalse(rotating.showsDisclosure(S.automation))

    let dayAndNight = card("Shuffle", rows: dayNight)
    XCTAssertFalse(dayAndNight.showsDisclosure(S.playlist), "a day-and-night playlist has no Order")
    XCTAssertFalse(dayAndNight.showsCard)
    XCTAssertFalse(card("Shuffle", rows: mirror).showsCard, "a mirror has no playlist")

    let copy = card("Copy wallpaper", rows: rotateList)
    XCTAssertTrue(copy.showsDisclosure(S.transfer))
    XCTAssertFalse(card("Copy wallpaper", rows: dayNight).showsCard, "no other display to copy to")
    XCTAssertTrue(card("Mirror source", rows: mirror).showsCard)
    XCTAssertFalse(card("Mirror source", rows: dayNight).showsCard)
  }

  /// A disclosure whose own words match stays, folded, on a display where nothing inside matches.
  func testADisclosureFoundByItsOwnWordsStaysFoldedWhereNothingInsideMatches() {
    let paused = card("Playlist paused", rows: dayNight)
    XCTAssertTrue(paused.showsDisclosure(S.playlist), "Playlist paused is what its summary can say")
    XCTAssertFalse(paused.opens(S.playlist), "but the display draws no Playlist paused row to open to")
    var held = dayNight
    held.showsResume = true
    XCTAssertTrue(card("Playlist paused", rows: held).opens(S.playlist))
  }

  func testTheDisplaysNameKeepsTheWholeCardFoldedAndOtherCardsLeave() {
    let named = card("UltraFine", title: "LG UltraFine 5K (2)", rows: dayNight)
    XCTAssertTrue(named.forced)
    XCTAssertTrue(named.showsCard)
    XCTAssertTrue(named.shows(S.enable))
    XCTAssertTrue(named.showsDisclosure(S.playback))
    XCTAssertFalse(named.opens(S.playback), "a card found by its name keeps its disclosures shut")
    XCTAssertFalse(card("UltraFine", title: "Studio Display", rows: dayNight).showsCard)
  }

  func testAWallpaperOfTheDisplaysListIsFoundByItsTitle() {
    let list = [(id: "w1", title: "Aurora Bay"), (id: "w3", title: "Sunrise over the Ridge")]
    let found = card("aurora", rows: rotateList, list: list)
    XCTAssertEqual(found.listMatches, ["w1"])
    XCTAssertFalse(found.showsWholeList, "only the wallpaper that matched")
    XCTAssertTrue(found.showsCard)
    XCTAssertTrue(found.opens(S.playlist))
    var noList = rotateList
    noList.listsOwnWallpapers = false
    XCTAssertTrue(card("aurora", rows: noList, list: list).listMatches.isEmpty, "a list that is not drawn")
    XCTAssertTrue(card("Move up", rows: rotateList, list: list).showsWholeList, "the row's own words")
  }

  // MARK: The page, through the controller

  func testADisplayNameALayoutAndAListedWallpaperEachFindTheDisplaysPage() async throws {
    try await withPanel { panel in
      try SettingsBFixtures.populate(panel)
      let controller = panel.controller
      let rows = Dictionary(uniqueKeysWithValues: controller.displayRows.map { ($0.id, $0) })
      let settings = controller.settings

      settings.query = "Studio"
      XCTAssertTrue(settings.search.shows(.displays), "Studio Display (1 - Primary)")
      XCTAssertFalse(settings.search.hasNoResults)
      XCTAssertGreaterThan(settings.search.count(in: .displays), 0, "the sidebar counts it")
      XCTAssertTrue(DisplaysCardSearch.make(try XCTUnwrap(rows["primary"]), controller: controller).forced)
      XCTAssertFalse(DisplaysCardSearch.make(try XCTUnwrap(rows["2"]), controller: controller).showsCard)

      settings.query = "Work"
      XCTAssertTrue(settings.search.shows(.displays), "the saved layout named Work")
      XCTAssertTrue(settings.search.shows(S.layouts, in: .displays))

      settings.query = "Aurora"
      XCTAssertTrue(settings.search.shows(.displays))
      let primary = DisplaysCardSearch.make(try XCTUnwrap(rows["primary"]), controller: controller)
      XCTAssertEqual(primary.listMatches, ["w1"], "Aurora Bay is in the primary display's list")
      XCTAssertTrue(primary.opens(S.playlist))

      settings.query = "Shuffle"
      XCTAssertTrue(DisplaysCardSearch.make(try XCTUnwrap(rows["primary"]), controller: controller).showsCard)
      XCTAssertFalse(
        DisplaysCardSearch.make(try XCTUnwrap(rows["2"]), controller: controller).showsCard,
        "LG UltraFine 5K (2) plays day and night")
      XCTAssertFalse(
        DisplaysCardSearch.make(try XCTUnwrap(rows["3"]), controller: controller).showsCard,
        "Sidecar iPad (3) mirrors")

      // A renamed layout is found by its new name, so the live rows follow the stores.
      let layout = try XCTUnwrap(controller.displayLayoutsState.layouts.first)
      settings.query = "Evening"
      XCTAssertFalse(settings.search.shows(.displays))
      try await controller.renameDisplayLayout(layout.id, to: "Evening")
      XCTAssertTrue(settings.search.shows(.displays))
      settings.query = ""
    }
  }
}
