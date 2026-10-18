import XCTest

@testable import WallpaperMachine

/// What the Workshop grid says when it has no tiles, the summary beside the pager, the header's
/// shapes, and the pager's field: the page's own rules, apart from the views.
@MainActor
final class WorkshopListStateTests: MediaPanelTestCase {
  private func source(
    _ source: WorkshopSource = .browse, canGoBack: Bool = false
  ) -> WorkshopSourceState {
    WorkshopSourceState(source: source, name: source.name, canGoBack: canGoBack)
  }

  private func empty(
    _ shown: WorkshopSource = .browse, signedIn: Bool = false, signingIn: Bool = false,
    loading: Bool = false, error: String? = nil, total: Int = 0, page: Int = 1, pages: Int = 1,
    text: String = "", filters: Int = 0
  ) -> WorkshopEmptyState {
    WorkshopEmptyState.make(
      source: source(shown), isSignedIn: signedIn, isSigningIn: signingIn, isLoading: loading,
      errorMessage: error, totalCount: total, page: page, totalPages: pages, draftText: text,
      filterCount: filters)
  }

  // MARK: Empty states

  func testASignedOutSubscriptionsListAsksForTheSignInBeforeAnythingElse() {
    XCTAssertEqual(empty(.subscriptions), .signInToSeeSubscriptions(isSigningIn: false))
    XCTAssertEqual(
      empty(.subscriptions, signingIn: true), .signInToSeeSubscriptions(isSigningIn: true),
      "while the sign-in window is open the button brings it forward")
    XCTAssertEqual(
      empty(.subscriptions, error: "Steam asked you to sign in again."),
      .signInToSeeSubscriptions(isSigningIn: false), "the sign-in prompt wins over an error")
    XCTAssertEqual(empty(.subscriptions, loading: true), .loading, "a list that loads is loading")
    XCTAssertEqual(empty(.subscriptions, signedIn: true), .noResults(.browseWorkshop))
  }

  func testLoadingComesBeforeAFailureAndAFailureBeforeAReasonForNothing() {
    XCTAssertEqual(empty(loading: true, error: "x", text: "a"), .loading)
    XCTAssertEqual(empty(error: "Steam is down.", text: "a", filters: 1), .unavailable("Steam is down."))
  }

  func testWordsFiltersAndBothEachHaveTheirOwnWayOut() {
    XCTAssertEqual(empty(text: "aurora", filters: 2), .noResults(.clearSearchAndFilters))
    XCTAssertEqual(empty(text: "aurora"), .noResults(.clearSearch))
    XCTAssertEqual(empty(filters: 3), .noResults(.clearFilters(count: 3)))
    XCTAssertEqual(empty(filters: 1), .noResults(.clearFilters(count: 1)))
    XCTAssertEqual(empty(text: "   "), .noResults(.refresh), "blank text is no search")
    XCTAssertEqual(empty(), .noResults(.refresh))
  }

  func testAListSteamDoesNotSearchIgnoresTheSearchText() {
    XCTAssertEqual(
      empty(.creator(id: "76561198000000001", name: "A"), text: "aurora"), .noResults(.refresh),
      "the field is hidden for an author, so its text cannot explain an empty page")
    XCTAssertEqual(
      empty(.creator(id: "76561198000000001", name: "A"), text: "aurora", filters: 2),
      .noResults(.clearFilters(count: 2)))
  }

  func testAPageScreenedAwayOffersTheNextPageAndTheFilters() {
    XCTAssertEqual(
      empty(.collection(id: "9", title: "T"), total: 40, page: 1, pages: 2),
      .noResults(.screened(isCollections: false, nextPage: 2)))
    XCTAssertEqual(
      empty(.collection(id: "9", title: "T"), total: 40, page: 2, pages: 2),
      .noResults(.screened(isCollections: false, nextPage: nil)), "no page after the last")
    XCTAssertEqual(
      empty(.collections, total: 12, page: 1, pages: 1),
      .noResults(.screened(isCollections: true, nextPage: nil)),
      "collections are screened for their age rating here, so they can hide a whole page")
    XCTAssertEqual(empty(.collections, total: 0), .noResults(.refresh))
    XCTAssertEqual(empty(.browse, total: 40), .noResults(.refresh), "Steam filters the browse list itself")
  }

  // MARK: Summary

  func testTheSummaryNamesWhatIsHappeningOrWhatIsOnShow() {
    func summary(
      _ shown: WorkshopSource = .browse, loading: Bool = false, signedIn: Bool = false,
      loaded: Bool = true, total: Int = 18_420, lookup: Bool = false, degraded: Bool = false
    ) -> WorkshopSummary {
      WorkshopSummary.make(
        source: shown, isLoading: loading, isSignedIn: signedIn, hasLoaded: loaded,
        totalCount: total, isLookup: lookup, isDegraded: degraded)
    }
    XCTAssertEqual(summary(loading: true), .searching)
    XCTAssertEqual(summary(loaded: false), .idle)
    XCTAssertEqual(summary(), .results(18_420))
    XCTAssertEqual(summary(lookup: true), .lookup, "a pasted link says filters do not apply to it")
    XCTAssertEqual(summary(degraded: true), .degraded)
    XCTAssertEqual(summary(lookup: true, degraded: true), .lookup)
    XCTAssertEqual(summary(.subscriptions, signedIn: true, total: 31), .subscriptions(count: 31))
    XCTAssertEqual(summary(.subscriptions, signedIn: true, loaded: false), .subscriptions(count: nil))
    XCTAssertEqual(summary(.subscriptions, signedIn: false), .results(18_420), "no bar without a session")
  }

  // MARK: Header

  func testTheHeaderTakesOneOfThreeShapesByTheWidthItHas() {
    XCTAssertEqual(WorkshopHeaderDensity.make(width: 900), .wide)
    XCTAssertEqual(WorkshopHeaderDensity.make(width: 680), .wide)
    XCTAssertEqual(WorkshopHeaderDensity.make(width: 520), .regular)
    XCTAssertEqual(WorkshopHeaderDensity.make(width: 400), .regular)
    XCTAssertEqual(
      WorkshopHeaderDensity.make(width: 220), .compact,
      "beside an open inspector in the smallest window the page column is about this wide")
    XCTAssertEqual(WorkshopHeaderDensity.make(width: 0), .compact)
  }

  func testEveryTabAndEverySortHasItsOwnNameInThePanelsLanguage() {
    let tabs = WorkshopList.allCases.map(\.panelTitle)
    XCTAssertEqual(tabs, ["Wallpapers", "Collections", "Your subscriptions"])
    let sorts = WorkshopSort.allCases.map(\.panelTitle)
    XCTAssertEqual(sorts.count, 9)
    XCTAssertEqual(Set(sorts).count, sorts.count, "no two sorts share a label")
    XCTAssertTrue(sorts.allSatisfy { !$0.isEmpty })
    XCTAssertEqual(WorkshopSort.trendingYear.panelTitle, "Most popular this year")
  }

  // MARK: The window's title

  func testTheSubtitleNamesWhatIsOnShowAndCountsItOnceKnown() {
    XCTAssertEqual(
      source().titleSubtitle(summary: .results(18_420)), "Wallpapers · \(L("\(18_420) results"))")
    XCTAssertEqual(
      source().titleSubtitle(summary: .searching), "Wallpapers",
      "a search on its way keeps the line, without a count")
    XCTAssertEqual(source(.collections).titleSubtitle(summary: .idle), "Collections")
    XCTAssertEqual(
      source(.subscriptions).titleSubtitle(summary: .subscriptions(count: 31)),
      "Your subscriptions · 31 subscribed")
    XCTAssertEqual(
      source(.subscriptions).titleSubtitle(summary: .subscriptions(count: nil)), "Your subscriptions")
    let author = WorkshopSourceState(
      source: .creator(id: "76561198000000001", name: "Ana"), name: "Ana", canGoBack: true)
    XCTAssertEqual(author.titleSubtitle(summary: .results(12)), "Wallpapers by Ana · \(L("\(12) results"))")
    let collection = WorkshopSourceState(
      source: .collection(id: "9", title: ""), name: nil, canGoBack: true)
    XCTAssertEqual(collection.titleSubtitle(summary: .lookup), "Collection", "a link's one item has no count")
    XCTAssertEqual(
      PanelTitle.make(selection: .workshop, workshopSubtitle: "Wallpapers").subtitle, "Wallpapers",
      "the window shows it under Steam Workshop")
  }

  func testTheSubtitleFollowsTheStoreAsTheListLoads() async throws {
    let panel = try makeDiscoverPanel()
    WorkshopBrowseProtocol.serve(
      [WorkshopBrowseProtocol.Row(id: "1000", title: "A")], pages: 1, count: 18_420)
    try await panel.controller.navigate(.workshop)
    try await waitFor { panel.workshop.hasLoaded && !panel.workshop.isLoading }
    XCTAssertEqual(panel.controller.workshopTitleSubtitle, "Wallpapers · \(L("\(18_420) results"))")
  }

  // MARK: The strip under the grid

  func testAnEmptyGridStandsAloneAndKeepsThePagerOnlyWhileOtherPagesRemain() {
    let loaded = WorkshopFooterContent.make(hasItems: true, pages: 1)
    XCTAssertTrue(loaded.showsSummary && loaded.showsPager, "tiles: what is on show, and the pager")
    let empty = WorkshopFooterContent.make(hasItems: false, pages: 1)
    XCTAssertTrue(empty.isEmpty, "no bare summary and no pager with nowhere to go")
    let screened = WorkshopFooterContent.make(hasItems: false, pages: 4)
    XCTAssertFalse(screened.showsSummary)
    XCTAssertTrue(screened.showsPager, "the filters screened this page; the next ones may hold some")
  }

  // MARK: Kinds

  func testEveryKindOfItemReadsInThePanelsLanguage() throws {
    let panel = try makeDiscoverPanel(language: "ja")
    PanelLocale.shared.bind(to: panel.controller.appLanguage)
    defer { PanelLocale.shared.bind(to: AppLanguageStore.english()) }
    func label(_ tag: String?) -> String {
      WorkshopItem(
        id: "1", title: "T", creator: "", summary: "", previewURL: nil, tags: tag.map { [$0] } ?? [],
        size: 0, subscriptions: 0
      ).kindLabel
    }
    let labels = ["Scene", "Video", "Web", "Application", nil].map(label)
    XCTAssertEqual(Set(labels).count, labels.count, "\(labels)")
    XCTAssertNotEqual(label("Application"), "Application", "an Application's kind is translated too")
    XCTAssertEqual(label("Application"), PanelLocale.shared.string("Application"))
  }

  // MARK: Pager

  func testAJumpFieldRoundsAndClampsToThePagesThereAre() {
    let pager = ResultPager(page: 3, totalPages: 614, isLoading: false, maxPages: 1000)
    XCTAssertEqual(pager.clampedPage(typed: "5000"), 614)
    XCTAssertEqual(pager.clampedPage(typed: "0"), 1)
    XCTAssertEqual(pager.clampedPage(typed: "-7"), 1)
    XCTAssertEqual(pager.clampedPage(typed: ""), 1, "an empty field asks for the first page")
    XCTAssertEqual(pager.clampedPage(typed: "abc"), 1)
    XCTAssertEqual(pager.clampedPage(typed: " 42 "), 42)
    XCTAssertEqual(pager.clampedPage(typed: "41.6"), 42, "rounded, as the field always was")
    XCTAssertEqual(pager.clampedPage(typed: "99999999999999999999999"), 614, "never traps")
    let steam = ResultPager(page: 1, totalPages: 5000, isLoading: false, maxPages: 1000)
    XCTAssertEqual(steam.clampedPage(typed: "5000"), 1000, "Steam's own limit")
    XCTAssertEqual(steam.pages, 1000)
  }
}
