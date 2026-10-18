import XCTest

@testable import WallpaperMachine

/// The pixiv page's draft query and the rules that turn edits into searches: the 450 ms pause,
/// Return and Refresh, what the account allows, Clear, the page field and the first visit.
/// pixiv is a fixture that records its requests, so nothing leaves the machine.
@MainActor
final class PixivBrowserModelTests: MediaPanelTestCase {
  /// pixiv with a daily ranking of three works over ten pages (301 and 303 admitted by the default
  /// rating, 302 not), a tag search of two, and the pages and images the page asks for.
  private func fixture() throws -> PixivFixtureTransport {
    let image = try PanelTestCase.gif(frames: 1, brightness: 0.6)
    return PixivFixtureTransport(respondingToSession: { url, session in
      if url.host == "i.pximg.net" { return image }
      if url.path == "/touch/ajax/user/self/status" {
        return PixivFixtures.status(signedIn: session == PixivFixtures.session)
      }
      if url.path.hasSuffix("/pages") {
        return PixivFixtures.pages(
          workID: Int(url.pathComponents.dropLast().last ?? "") ?? 0, count: 2)
      }
      if url.path.hasPrefix("/ajax/search/") {
        return PixivFixtures.search(
          [PixivFixtures.searchEntry(.init(id: 701)), PixivFixtures.searchEntry(.init(id: 702))],
          total: 120, lastPage: 2)
      }
      let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
      if items.first(where: { $0.name == "mode" })?.value?.hasSuffix("_r18") == true,
        session != PixivFixtures.session
      {
        throw PixivFixtures.forbidden
      }
      let page = items.first { $0.name == "p" }?.value.flatMap(Int.init) ?? 1
      return PixivFixtures.ranking(
        [
          PixivFixtures.rankingEntry(.init(id: 301, pages: 2), rank: 1),
          PixivFixtures.rankingEntry(.init(id: 302, sexual: 1), rank: 2),
          PixivFixtures.rankingEntry(.init(id: 303, pages: 2), rank: 3),
        ], page: page, total: 500)
    })
  }

  private func openRanking(_ panel: PanelFixture) async throws {
    await panel.controller.pixivBrowser.commit().value
    try await waitFor { panel.pixiv.hasLoaded && !panel.pixiv.isLoading }
  }

  private func settle(_ panel: PanelFixture) async throws {
    try await waitFor { !panel.pixiv.isLoading }
  }

  /// The pages of a ranking asked for, in order. The store also reads the page after the one on
  /// show in the background, so a test counts the page it cares about, not every request.
  private func rankingPages(_ transport: PixivFixtureTransport) -> [Int] {
    transport.requests.filter { $0.path == "/ranking.php" }.map(page(of:))
  }

  private func searchPages(_ transport: PixivFixtureTransport) -> [Int] {
    transport.requests.filter { $0.path.hasPrefix("/ajax/search/") }.map(page(of:))
  }

  private func page(of url: URL) -> Int {
    URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
      .first { $0.name == "p" }?.value.flatMap(Int.init) ?? 1
  }

  // MARK: Typing

  func testTypingWaitsForAPauseAndThenSendsTheWholeDraft() async throws {
    let transport = try fixture()
    try await withPanel(pixivTransport: transport) { panel in
      let model = panel.controller.pixivBrowser
      let sleeper = ManualSleeper()
      model.sleep = sleeper.closure
      try await openRanking(panel)

      model.setText("s")
      model.setText("sk")
      model.setText("sky")
      await sleeper.waitUntilPending(1)
      try await waitFor { sleeper.requested.count == 3 }
      XCTAssertEqual(sleeper.requested, Array(repeating: .milliseconds(450), count: 3))
      XCTAssertEqual(sleeper.cancelledCount, 2, "each key press restarts the pause")
      XCTAssertEqual(sleeper.pendingCount, 1)
      XCTAssertTrue(searchPages(transport).isEmpty, "nothing is sent while the person is typing")
      XCTAssertEqual(panel.pixiv.query.text, "")
      XCTAssertTrue(model.isSearching, "the menu already offers search orders")

      sleeper.fireNext()
      try await waitFor { panel.pixiv.query.text == "sky" }
      try await settle(panel)
      XCTAssertEqual(searchPages(transport).first, 1)
      XCTAssertTrue(transport.requests.contains { $0.path == "/ajax/search/illustrations/sky" })
      XCTAssertEqual(panel.pixiv.works.map(\.id), ["701", "702"])
    }
  }

  func testAFilterRightAfterTypingCommitsTheTypedTextToo() async throws {
    let transport = try fixture()
    try await withPanel(pixivTransport: transport) { panel in
      let model = panel.controller.pixivBrowser
      let sleeper = ManualSleeper()
      model.sleep = sleeper.closure
      try await openRanking(panel)

      model.setText("sky")
      await sleeper.waitUntilPending(1)
      await model.set(hidesAIGenerated: true).value
      try await settle(panel)
      XCTAssertEqual(panel.pixiv.query.text, "sky")
      XCTAssertTrue(panel.pixiv.query.hidesAIGenerated)
      XCTAssertEqual(
        sleeper.cancelledCount, 1, "the committed draft makes the waiting pause pointless")
      sleeper.fireAll()
      try await Task.sleep(for: .milliseconds(50))
      XCTAssertEqual(searchPages(transport).filter { $0 == 1 }.count, 1)
    }
  }

  func testReturnAndRefreshAskForTheFirstPageAfreshButAFilterTheListingNeverSeesDoesNot()
    async throws
  {
    let transport = try fixture()
    try await withPanel(pixivTransport: transport) { panel in
      let model = panel.controller.pixivBrowser
      try await openRanking(panel)
      XCTAssertEqual(rankingPages(transport).filter { $0 == 1 }.count, 1)

      await model.set(.questionable, isOn: true).value
      try await settle(panel)
      XCTAssertEqual(
        rankingPages(transport).filter { $0 == 1 }.count, 1,
        "the age rating is applied to the page on show, with no request")
      XCTAssertEqual(panel.pixiv.query.ratings, [.everyone, .questionable])
      XCTAssertEqual(panel.pixiv.works.map(\.id), ["301", "302", "303"])

      await model.submit().value
      try await waitFor { self.rankingPages(transport).filter { $0 == 1 }.count == 2 }
      await model.refresh().value
      try await waitFor { self.rankingPages(transport).filter { $0 == 1 }.count == 3 }
      try await settle(panel)
    }
  }

  func testTheTextIsCutAtTwoHundredFiftySixCharactersAndThePageIsNotBlamed() async throws {
    try await withPanel(pixivTransport: try fixture()) { panel in
      let model = panel.controller.pixivBrowser
      model.sleep = ManualSleeper().closure
      model.setText(String(repeating: "a", count: 300))
      XCTAssertEqual(model.draft.text.count, 256)
      await model.commit().value
      try await settle(panel)
      XCTAssertNil(
        panel.controller.errors.message, "a paste the store would refuse never reaches it")
      XCTAssertEqual(panel.pixiv.query.text.count, 256)
    }
  }

  // MARK: The menu and the filters

  func testTheMenuFollowsTheTextAndEachChoiceIsCommittedAtOnce() async throws {
    let transport = try fixture()
    try await withPanel(pixivTransport: transport) { panel in
      let model = panel.controller.pixivBrowser
      model.sleep = ManualSleeper().closure
      try await openRanking(panel)
      XCTAssertFalse(model.isSearching)
      XCTAssertEqual(model.rankingChoices, [.daily, .weekly, .monthly, .rookie])

      await model.choose(ranking: .weekly).value
      try await waitFor { panel.pixiv.committedQuery?.ranking == .weekly && !panel.pixiv.isLoading }

      model.setText("sky")
      XCTAssertTrue(model.isSearching)
      await model.choose(order: .oldest).value
      try await waitFor { panel.pixiv.committedQuery?.order == .oldest && !panel.pixiv.isLoading }
      XCTAssertEqual(model.query.ranking, .weekly, "the ranking is kept while searching")

      await model.clearSearch().value
      try await waitFor { panel.pixiv.committedQuery?.text == "" && !panel.pixiv.isLoading }
      XCTAssertFalse(model.isSearching)
      XCTAssertEqual(panel.pixiv.query.ranking, .weekly, "and comes back when the text is cleared")
    }
  }

  func testClearResetsTheFiltersAndKeepsTheTextTheRankingAndTheOrder() async throws {
    try await withPanel(pixivTransport: try fixture()) { panel in
      let model = panel.controller.pixivBrowser
      model.sleep = ManualSleeper().closure
      try await openRanking(panel)
      model.setText("sky")
      model.choose(order: .oldest)
      model.choose(orientation: .portrait)
      model.choose(minimumSize: .quadHD)
      model.set(hidesAIGenerated: true)
      await model.set(.questionable, isOn: true).value
      XCTAssertEqual(model.filterCount, 4)
      XCTAssertEqual(model.count(in: .orientation), 1)
      XCTAssertEqual(model.count(in: .minimumSize), 1)
      XCTAssertEqual(model.count(in: .ageRating), 1)
      XCTAssertEqual(model.count(in: .ai), 1)
      XCTAssertEqual(model.count(in: .account), 0, "the account has no count")

      await model.clearFilters().value
      try await settle(panel)
      XCTAssertEqual(model.filterCount, 0)
      XCTAssertEqual(model.draft.text, "sky")
      XCTAssertEqual(model.draft.order, .oldest)
      XCTAssertEqual(panel.pixiv.query.text, "sky", "Clear commits at once")
      XCTAssertEqual(panel.pixiv.query.orientation, .any)
    }
  }

  func testEveryRatingCanBeUntickedAndTheMatureBoxNeedsASignIn() async throws {
    try await withPanel(pixivTransport: try fixture()) { panel in
      let model = panel.controller.pixivBrowser
      try await openRanking(panel)
      await model.set(.everyone, isOn: false).value
      try await settle(panel)
      XCTAssertEqual(model.query.ratings, [])
      XCTAssertEqual(model.filterCount, 1, "unticking Everyone counts one")
      XCTAssertTrue(panel.pixiv.works.isEmpty, "every work is hidden")
      XCTAssertEqual(panel.pixiv.hiddenCount, 3)

      await model.set(.mature, isOn: true).value
      XCTAssertFalse(model.query.ratings.contains(.mature), "signed out, Mature is never asked for")
      XCTAssertFalse(panel.controller.pixivAccount.allowsMature)
    }
  }

  // MARK: The account

  func testSigningOutTakesMatureAndAnR18RankingOutOfTheDraftAndSigningInAgainDoesNotBringThemBack()
    async throws
  {
    try await withPanel(pixivTransport: try fixture()) { panel in
      let controller = panel.controller
      let model = controller.pixivBrowser
      controller.signInToPixiv = { PixivFixtures.session }
      try await openRanking(panel)

      try await controller.pixivSignIn()
      try await waitFor {
        panel.pixiv.account != nil && !panel.pixiv.isSigningIn && !panel.pixiv.isLoading
      }
      XCTAssertTrue(model.isSignedIn)
      await model.set(.mature, isOn: true).value
      XCTAssertTrue(
        model.rankingChoices.contains(.dailyR18), "R-18 rankings appear for a signed-in Mature box")
      XCTAssertEqual(model.rankingChoices.count, 6)
      await model.choose(ranking: .dailyR18).value
      try await waitFor {
        panel.pixiv.committedQuery?.ranking == .dailyR18 && !panel.pixiv.isLoading
      }
      XCTAssertEqual(model.filterCount, 1)

      try await controller.pixivSignOut()
      try await waitFor { !panel.pixiv.isSignedIn && !panel.pixiv.isLoading }
      XCTAssertEqual(
        model.query.ranking, .daily, "what is shown never offers what the account lost")
      XCTAssertEqual(model.query.ratings, [.everyone])
      XCTAssertEqual(model.rankingChoices, [.daily, .weekly, .monthly, .rookie])
      model.reconcileAccount()
      XCTAssertEqual(model.draft.ratings, [.everyone], "the draft itself lets go")
      XCTAssertEqual(model.draft.ranking, .daily)

      try await controller.pixivSignIn()
      try await waitFor { panel.pixiv.account != nil && !panel.pixiv.isLoading }
      XCTAssertEqual(
        model.query.ratings, [.everyone], "a new sign-in does not tick the box on its own")
      XCTAssertEqual(model.query.ranking, .daily)
    }
  }

  // MARK: Paging

  func testATypedPageNumberIsRoundedHeldToThePagesAndOnlyAnotherPageLoads() async throws {
    let transport = try fixture()
    try await withPanel(pixivTransport: transport) { panel in
      let model = panel.controller.pixivBrowser
      try await openRanking(panel)
      XCTAssertEqual(panel.controller.pixivBrowse.pager.pages, 10)
      let first = rankingPages(transport).filter { $0 == 1 }.count

      XCTAssertEqual(model.jump(typed: ""), 1, "an empty field asks for the first page")
      XCTAssertEqual(model.jump(typed: "1"), 1)
      XCTAssertEqual(model.jump(typed: "abc"), 1)
      XCTAssertEqual(model.jump(typed: "-4"), 1)
      XCTAssertEqual(model.jump(typed: "0"), 1)
      try await Task.sleep(for: .milliseconds(50))
      XCTAssertEqual(
        rankingPages(transport).filter { $0 == 1 }.count, first,
        "the page on show is never asked for again")

      XCTAssertEqual(model.jump(typed: "3"), 3)
      try await waitFor { panel.pixiv.page == 3 && !panel.pixiv.isLoading }
      XCTAssertEqual(model.jump(typed: " 3 "), 3)
      XCTAssertEqual(model.jump(typed: "2.6"), 3, "rounded: 2.6 is page 3, the page on show")
      XCTAssertEqual(model.jump(typed: "99999"), 10, "held to the last page")
      try await waitFor { panel.pixiv.page == 10 && !panel.pixiv.isLoading }
      XCTAssertTrue(rankingPages(transport).contains(3))
      XCTAssertTrue(rankingPages(transport).contains(10))
      XCTAssertEqual(
        rankingPages(transport).filter { $0 == 3 }.count, 1, "page 3 was asked for once")

      await model.showPage(0).value
      try await waitFor { panel.pixiv.page == 1 && !panel.pixiv.isLoading }
    }
  }

  func testTheFirstVisitLoadsOnceAndNeverRepeatsALoadThatIsUnderWayOrFailed() async throws {
    try await withPanel(pixivTransport: try fixture()) { panel in
      let model = panel.controller.pixivBrowser
      let first = try XCTUnwrap(model.loadIfNeeded(), "nothing was loaded: the page asks")
      XCTAssertNil(model.loadIfNeeded(), "one is under way")
      await first.value
      try await waitFor { panel.pixiv.hasLoaded }
      XCTAssertNil(model.loadIfNeeded(), "a loaded page is never asked for again")
    }
    let failing = PixivFixtureTransport { _ in throw PixivFailure(code: .status(429)) }
    try await withPanel(pixivTransport: failing) { panel in
      let model = panel.controller.pixivBrowser
      await model.loadIfNeeded()?.value
      try await waitFor { panel.pixiv.errorMessage != nil && !panel.pixiv.isLoading }
      XCTAssertNil(model.loadIfNeeded(), "a failure waits for Try again; it does not loop")
    }
  }

  // MARK: Works

  func testDoubleClickingAWorkSavesItsFirstPageAndASecondOneWaitsForIt() async throws {
    try await withPanel(pixivTransport: try fixture()) { panel in
      let controller = panel.controller
      let model = controller.pixivBrowser
      try await openRanking(panel)
      let work = try XCTUnwrap(panel.pixiv.works.first { $0.id == "301" })

      await model.doubleClick(work)?.value
      XCTAssertNotNil(panel.pixiv.downloads.download(for: "pixiv-301-p0"))
      try await panel.waitUntil(timeout: 10) {
        panel.pixiv.downloads.download(for: "pixiv-301-p0")?.status == .finished
      }
      panel.store.librarySnapshot.wallpapers = [
        BridgeWallpaperEntry(
          id: "pixiv-301-p0", title: "Saved", kind: .webpage, supported: true, active: false,
          selected: false, previewPath: nil)
      ]
      XCTAssertEqual(controller.pixivDoubleClick(for: work), .apply(libraryID: "pixiv-301-p0"))
      panel.store.settingsSnapshot.displays[0].mode = .mirror
      XCTAssertNil(
        model.doubleClick(work), "a mirror shows no wallpaper of its own: nothing happens")
    }
  }

  func testSelectingAWorkSelectsItAndTheGridStartsAtTheTopOnlyForAnotherListingOrPage() async throws
  {
    try await withPanel(pixivTransport: try fixture()) { panel in
      let model = panel.controller.pixivBrowser
      try await openRanking(panel)
      let work = try XCTUnwrap(panel.pixiv.works.first)
      model.select(work)
      try await waitFor { panel.pixiv.selectedWork?.id == work.id }
      XCTAssertEqual(panel.controller.pixivBrowse.selectedID, work.id)

      let ranking = PixivScrollKey(listing: PixivQuery().listing, page: 1)
      XCTAssertEqual(ranking, PixivScrollKey(listing: PixivQuery().listing, page: 1))
      XCTAssertNotEqual(ranking, PixivScrollKey(listing: PixivQuery().listing, page: 2))
      XCTAssertNotEqual(
        ranking, PixivScrollKey(listing: PixivQuery(ranking: .weekly).listing, page: 1))
    }
  }

  func testASecondPressOfARingWithinADoubleClickUndoesNothingAndALaterPressActs() async throws {
    // Saves stay under way until cancelled, as a transfer on a slow network would; the panel's
    // shutdown cancels the one still held at the end.
    let gate = PixivGate()
    let image = try PanelTestCase.gif(frames: 1, brightness: 0.6)
    let fixture = PixivFixtureTransport { url in
      if url.host == "i.pximg.net" { return image }
      if url.path.hasSuffix("/pages") {
        return PixivFixtures.pages(
          workID: Int(url.pathComponents.dropLast().last ?? "") ?? 0, count: 1)
      }
      return PixivFixtures.ranking([PixivFixtures.rankingEntry(.init(id: 301), rank: 1)])
    }
    let transport = PixivHeldTransport(fixture: fixture, originals: gate)
    try await withPanel(pixivTransport: transport) { panel in
      let controller = panel.controller
      let model = controller.pixivBrowser
      try await openRanking(panel)
      let work = try XCTUnwrap(panel.pixiv.works.first { $0.id == "301" })
      var clock = ContinuousClock.now
      model.now = { clock }
      model.doubleClickInterval = .milliseconds(500)
      @MainActor func status() -> PixivDownload.Status? {
        panel.pixiv.downloads.download(for: "pixiv-301-p0")?.status
      }

      try await controller.pixivDownload(workID: "301", page: 0)
      try await panel.waitUntil { gate.waiting == 1 }
      XCTAssertEqual(status(), .downloading)
      let cancel = try XCTUnwrap(controller.pixivTile(for: work).ring)
      XCTAssertEqual(cancel.state.action, .cancel)
      await model.pressRing(cancel)?.value
      try await panel.waitUntil { status() == .cancelled }

      // The second click of the double-click lands on the ring the first one left, which now
      // offers to try again: it must not start the save that was just cancelled.
      let retry = try XCTUnwrap(controller.pixivTile(for: work).ring)
      XCTAssertEqual(retry.state.action, .retry)
      clock += .milliseconds(200)
      XCTAssertNil(model.pressRing(retry), "the second click of a double-click is not a press")
      try await Task.sleep(for: .milliseconds(100))
      XCTAssertEqual(status(), .cancelled)

      clock += .seconds(1)
      await model.pressRing(retry)?.value
      XCTAssertTrue(status().map { $0 == .waiting || $0 == .downloading } ?? false, "a later press acts")
    }
  }

  func testTheGridsPlaceIsStoredAtMostEvery400msBesideTheOtherPagesAndHandedBackOnce() async throws {
    try await withPanel(pixivTransport: try fixture()) { panel in
      let controller = panel.controller
      controller.navigation.viewState = PanelViewState(
        installed: .init(text: "sky", sort: "size", descending: true, tags: ["Anime"], excludedTags: []),
        scroll: ["installed": 80, "pixiv": 250])
      let model = controller.pixivBrowser
      XCTAssertEqual(model.takeRestoredScroll(), 250, "the last window left this place")
      XCTAssertNil(model.takeRestoredScroll(), "and it is handed back once")

      let sleeper = ManualSleeper()
      model.sleep = sleeper.closure
      model.scrolled(to: 100)
      model.scrolled(to: 300)
      await sleeper.waitUntilPending(1)
      XCTAssertEqual(sleeper.requested, [.milliseconds(400)], "a flick is one write, not one a frame")
      XCTAssertEqual(controller.navigation.viewState?.scroll["pixiv"], 250, "nothing stored yet")
      sleeper.fireNext()
      try await waitFor { controller.navigation.viewState?.scroll["pixiv"] == 300 }
      let state = try XCTUnwrap(controller.navigation.viewState)
      XCTAssertEqual(state.scroll["installed"], 80, "Installed's place is kept")
      XCTAssertEqual(state.installed.text, "sky", "and so are its filters")
      XCTAssertEqual(state.installed.tags, ["Anime"])

      model.scrolled(to: 410.4)
      model.flushScrollReport()
      XCTAssertEqual(
        controller.navigation.viewState?.scroll["pixiv"], 410, "leaving the page stores it at once")
      model.scrolled(to: -5)
      model.scrolled(to: .nan)
      model.scrolled(to: .infinity)
      model.flushScrollReport()
      XCTAssertEqual(
        controller.navigation.viewState?.scroll["pixiv"], 410, "an offset that is not a place is ignored")
    }
  }

  // MARK: The first pages of text

  func testHowAPageNumberIsShownAndThePageBarSizesItself() {
    let pager = ResultPager(page: 4, totalPages: 12, isLoading: false, maxPages: 1000)
    XCTAssertEqual(PixivBrowserModel.shownNumber(typed: "99", in: pager), 12)
    XCTAssertEqual(PixivBrowserModel.shownNumber(typed: "inf", in: pager), 12)
    XCTAssertEqual(PixivBrowserModel.shownNumber(typed: "nan", in: pager), 1)
    XCTAssertEqual(PixivBrowserModel.shownNumber(typed: "", in: pager), 1)
    XCTAssertEqual(PixivBrowserModel.shownNumber(typed: "7.4", in: pager), 7)
    XCTAssertGreaterThan(
      PixivPagerBar.height(isCompact: true, showsError: false),
      PixivPagerBar.height(isCompact: false, showsError: false))
    XCTAssertGreaterThan(
      PixivPagerBar.height(isCompact: false, showsError: true),
      PixivPagerBar.height(isCompact: false, showsError: false))
  }

  func testThePagerGivesTheSummaryRoomBeforeItStacksIt() {
    XCTAssertEqual(PixivPagerBar.layout(forWidth: 1000), .full)
    XCTAssertEqual(PixivPagerBar.layout(forWidth: PixivPagerBar.shortControlsWidth), .full)
    // The page beside the sidebar of the smallest window: "Page" and Go leave first, so the
    // summary keeps how many works the filters hide.
    XCTAssertEqual(PixivPagerBar.layout(forWidth: 540), .short)
    XCTAssertEqual(PixivPagerBar.layout(forWidth: PixivPagerBar.compactWidth), .short)
    XCTAssertEqual(PixivPagerBar.layout(forWidth: 300), .stacked)
    XCTAssertEqual(PixivPagerBar.layout(forWidth: 0), .stacked)
  }

  func testTheSignInLinkTakesItsShortWordsAndLeavesBeforeTheMenuLosesItsRoom() {
    XCTAssertEqual(PixivHeaderRow.signInStyle(forWidth: 900), .text)
    XCTAssertEqual(
      PixivHeaderRow.signInStyle(forWidth: 450), .short, "a label stays where there is room")
    XCTAssertEqual(PixivHeaderRow.signInStyle(forWidth: 280), .hidden)
    XCTAssertEqual(PixivHeaderRow.signInStyle(forWidth: 0), .hidden)
  }
}
