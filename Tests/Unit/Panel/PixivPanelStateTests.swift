import XCTest

@testable import WallpaperMachine

/// The pixiv page's pure rules: which pages of a work the library holds, what the inspector offers
/// for the page on show, what a double-click does, what the title bar says while pages save, and
/// what the account allows.
@MainActor
final class PixivPanelStateTests: MediaPanelTestCase {
  private func work(_ id: String = "301", pages: Int = 2, title: String = "Sky") -> PixivWork {
    PixivWork(
      id: id, title: title, authorID: "1", authorName: "Artist", thumbnailURL: nil, width: 1920,
      height: 1080, pageCount: pages, rating: .everyone, aiGenerated: nil, tags: [], rank: nil)
  }

  private func selection(
    page: Int = 0, count: Int = 2, saved: [Int] = [], job: PixivDownloadRow? = nil
  ) -> PixivSelection {
    PixivSelection(
      work: work(pages: count), pageIndex: page, pageCount: count, pages: .loaded, preview: nil,
      thumbnail: nil, pageWidth: 1920, pageHeight: 1080,
      libraryID: PixivWork.libraryID(workID: "301", page: page), savedPages: saved, job: job)
  }

  private func row(_ status: PixivDownload.Status, page: Int = 0) -> PixivDownloadRow {
    PixivDownloadRow(work: work(), pageIndex: page, status: status)
  }

  func testInstalledPagesAreReadOffTheIDsThePackagerGives() {
    let pages = PixivInstalledPages.index(in: [
      "pixiv-42-p3", "pixiv-42-p0", "pixiv-7-p0", "pixiv-42-p01", "pixiv-0-p0", "pixiv-42-p-1", "pixiv-42",
      "pixiv-x-p0", "other-42-p0", "pixiv-42-p2-extra", "pixiv-42-q1",
    ])
    XCTAssertEqual(pages, ["42": [0, 3], "7": [0]])
  }

  func testTheInspectorOffersWhatThePageOnShowNeedsInThatOrder() {
    XCTAssertEqual(selection(saved: [0]).download, .saved)
    XCTAssertEqual(
      selection(saved: [0], job: row(.waiting)).download, .saved,
      "a saved page has no download controls, whatever its job says")

    let pending = row(.downloading)
    XCTAssertEqual(selection(job: pending).download, .pending(pending))
    XCTAssertEqual(selection(job: row(.waiting)).download, .pending(row(.waiting)), "even while waiting")
    XCTAssertEqual(selection(job: row(.installing)).download, .pending(row(.installing)))
    let paused = row(.paused)
    XCTAssertEqual(selection(job: paused).download, .paused(paused))

    XCTAssertEqual(selection().download, .available(.page(1)), "a work with several pages says which")
    XCTAssertEqual(selection(page: 1).download, .available(.page(2)))
    XCTAssertEqual(selection(count: 1).download, .available(.plain))
    XCTAssertEqual(selection(job: row(.failed("no"))).download, .available(.again))
    XCTAssertEqual(selection(job: row(.cancelled)).download, .available(.page(1)), "a cancelled save has no failure to name")
  }

  func testAFailureShowsOnlyForAPageThatIsNotSavedAndNotUnderWay() {
    XCTAssertEqual(selection(job: row(.failed("pixiv is limiting requests."))).failure, "pixiv is limiting requests.")
    XCTAssertNil(selection(saved: [0], job: row(.failed("no"))).failure)
    XCTAssertNil(selection(job: row(.cancelled)).failure)
    XCTAssertNil(selection(job: row(.downloading)).failure)
  }

  func testDoubleClickingSavesTheShownPageAppliesASavedOneAndWaitsWhileItDownloads() {
    func decide(
      _ id: String = "301", selection shown: PixivSelection? = nil, saved: [Int] = [],
      pending: Set<String> = [], canShow: Bool = true
    ) -> PixivDoubleClick {
      PixivDoubleClick.decide(
        workID: id, selection: shown, savedPages: saved, pendingJobIDs: pending,
        targetCanShowWallpaper: canShow)
    }
    XCTAssertEqual(decide(), .download(workID: "301", page: 0), "the first page, until the inspector shows another")
    XCTAssertEqual(
      decide(selection: selection(page: 1)), .download(workID: "301", page: 1),
      "the page the inspector shows")
    XCTAssertEqual(
      decide("999", selection: selection(page: 1)), .download(workID: "999", page: 0),
      "another work's tile starts at its first page")
    XCTAssertEqual(decide(saved: [0]), .apply(libraryID: "pixiv-301-p0"))
    XCTAssertEqual(decide(saved: [0], canShow: false), .nothing, "a mirror or a disabled display cannot show it")
    XCTAssertEqual(decide(pending: ["pixiv-301-p0"]), .nothing)
    XCTAssertEqual(decide(selection: selection(page: 1), saved: [0], pending: ["pixiv-301-p0"]), .download(workID: "301", page: 1))
  }

  func testTheTitleBarNamesOneSaveWithItsProgressAndCountsSeveral() throws {
    XCTAssertNil(PixivActivity([]))
    XCTAssertNil(PixivActivity([row(.finished), row(.paused), row(.failed("no"))]), "only pending saves count")
    let one = try XCTUnwrap(
      PixivActivity([
        PixivDownloadRow(work: work(), pageIndex: 0, status: .downloading, bytesReceived: 42, bytesExpected: 100)
      ]))
    XCTAssertEqual(one.label, "pixiv: Sky · 42%")
    let unknownSize = try XCTUnwrap(PixivActivity([row(.waiting)]))
    XCTAssertEqual(unknownSize.label, "pixiv: Sky")
    let untitled = try XCTUnwrap(
      PixivActivity([PixivDownloadRow(work: work(title: ""), pageIndex: 0, status: .waiting)]))
    XCTAssertEqual(untitled.label, "pixiv: Untitled")
    let several = try XCTUnwrap(PixivActivity([row(.waiting, page: 0), row(.downloading, page: 1)]))
    XCTAssertEqual(several.label, "2 pixiv downloads")
  }

  func testSigningInUnlocksTheMatureBoxAndTheNoteFollowsWhatThePixivAccountAllows() {
    func account(signedIn: Bool, showsR18: Bool? = nil) -> PixivAccountState {
      PixivAccountState(
        isSignedIn: signedIn, isSigningIn: false, name: signedIn ? "Tester" : nil,
        id: signedIn ? "1" : nil, showsR18: showsR18, message: nil)
    }
    XCTAssertFalse(account(signedIn: false).allowsMature)
    XCTAssertEqual(account(signedIn: false).r18Note, .signInToShow)
    XCTAssertTrue(account(signedIn: true).allowsMature)
    XCTAssertEqual(account(signedIn: true, showsR18: true).r18Note, .neverShowsR18G)
    XCTAssertEqual(account(signedIn: true, showsR18: nil).r18Note, .neverShowsR18G)
    XCTAssertEqual(
      account(signedIn: true, showsR18: false).r18Note, .accountHidesThem,
      "the box stays tickable; only the note changes")
  }

  func testAPixivSaveReportsItsProgressAndWordsItsStateForTheInspector() {
    let downloading = PixivDownloadRow(
      work: work(), pageIndex: 1, status: .downloading, bytesReceived: 1_536, bytesExpected: 3_072)
    XCTAssertEqual(downloading.progress, 0.5)
    XCTAssertEqual(downloading.percent, 50)
    XCTAssertEqual(downloading.inspectorStatus(locale: english), "Downloading 50% · 1.5 KB of 3 KB")
    let unknown = PixivDownloadRow(work: work(), pageIndex: 0, status: .downloading)
    XCTAssertNil(unknown.progress)
    XCTAssertEqual(unknown.inspectorStatus(locale: english), "Downloading")
    XCTAssertEqual(row(.paused).inspectorStatus(locale: english), "Download paused")
    XCTAssertEqual(row(.waiting).inspectorStatus(locale: english), "Waiting to download")
    XCTAssertEqual(row(.installing).inspectorStatus(locale: english), "Saving to your library…")
    XCTAssertTrue(downloading.isPending)
    XCTAssertFalse(row(.paused).isPending)
  }

  // MARK: The query

  func testTheFilterCountCountsEachFilterThatDiffersFromItsDefault() {
    XCTAssertEqual(PixivQuery().activeFilterCount, 0)
    var query = PixivQuery()
    query.orientation = .landscape
    XCTAssertEqual(query.activeFilterCount, 1)
    query.minimumSize = .quadHD
    query.hidesAIGenerated = true
    XCTAssertEqual(query.activeFilterCount, 3)
    query.ratings = [.everyone, .questionable]
    XCTAssertEqual(query.ratingFilterCount, 1, "ticking Questionable counts one")
    query.ratings = [.questionable]
    XCTAssertEqual(query.ratingFilterCount, 2, "unticking Everyone is another")
    query.ratings = []
    XCTAssertEqual(query.ratingFilterCount, 1, "every box can be unticked")
    XCTAssertEqual(query.orientationFilterCount, 1)
    XCTAssertEqual(query.minimumSizeFilterCount, 1)
    XCTAssertEqual(query.aiFilterCount, 1)
  }

  func testClearResetsTheFiltersAndKeepsWhatWasSearchedFor() {
    let query = PixivQuery(
      text: "sky", ranking: .weekly, order: .oldest, orientation: .portrait, minimumSize: .fullHD,
      hidesAIGenerated: true, ratings: [.everyone, .mature])
    let cleared = query.clearingFilters()
    XCTAssertEqual(cleared.activeFilterCount, 0)
    XCTAssertEqual(cleared.text, "sky")
    XCTAssertEqual(cleared.ranking, .weekly)
    XCTAssertEqual(cleared.order, .oldest)
    XCTAssertEqual(cleared.ratings, [.everyone])
  }

  func testTheDraftIsASearchOnceItsTextHasAVisibleCharacter() {
    XCTAssertFalse(PixivQuery().isSearchDraft)
    XCTAssertFalse(PixivQuery(text: "  \n ").isSearchDraft)
    XCTAssertTrue(PixivQuery(text: " sky ").isSearchDraft)
  }

  func testTheRankingMenuOffersR18RankingsOnlyToASignedInAccountWithMatureTicked() {
    let allAges: [PixivRanking] = [.daily, .weekly, .monthly, .rookie]
    XCTAssertEqual(PixivRanking.offered(signedIn: false, ratings: [.everyone, .mature]), allAges)
    XCTAssertEqual(PixivRanking.offered(signedIn: true, ratings: [.everyone]), allAges)
    XCTAssertEqual(
      PixivRanking.offered(signedIn: true, ratings: [.everyone, .mature]),
      allAges + [.dailyR18, .weeklyR18])
  }

  func testEveryChoiceTheControlsOfferHasItsOwnNonEmptyTitle() {
    func distinct(_ titles: [String], _ what: String) {
      XCTAssertEqual(Set(titles).count, titles.count, what)
      XCTAssertFalse(titles.contains(where: \.isEmpty), what)
    }
    distinct(PixivRanking.allCases.map(\.title), "rankings")
    distinct(PixivSearchOrder.allCases.map(\.title), "search orders")
    distinct(PixivOrientation.allCases.map(\.title), "orientations")
    distinct(PixivMinimumSize.allCases.map(\.title), "sizes")
    distinct(PixivQuery.offeredRatings.map(\.title), "ratings")
    XCTAssertEqual(PixivRating.mature.title, "Mature (R-18)")
    XCTAssertEqual(PixivRanking.dailyR18.title, "Daily R-18 ranking")
  }
}
