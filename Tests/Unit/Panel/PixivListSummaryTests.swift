import XCTest

@testable import WallpaperMachine

/// What the pixiv page says about its listing and its works: the summary line, what replaces the
/// grid while it is empty, the facts on a tile, the inspector's meta line and apply button, and
/// what a click on a tile's ring does.
@MainActor
final class PixivListSummaryTests: MediaPanelTestCase {
  private func ranking(
    entries: @escaping @Sendable () -> [[String: Any]], search: [[String: Any]] = []
  ) throws -> PixivFixtureTransport {
    let image = try PanelTestCase.gif(frames: 1, brightness: 0.6)
    return PixivFixtureTransport(respondingToSession: { url, _ in
      if url.host == "i.pximg.net" { return image }
      if url.path.hasSuffix("/pages") {
        return PixivFixtures.pages(
          workID: Int(url.pathComponents.dropLast().last ?? "") ?? 0, count: 2)
      }
      if url.path.hasPrefix("/ajax/search/") {
        return PixivFixtures.search(search, total: search.count, lastPage: 1)
      }
      return PixivFixtures.ranking(entries(), total: 500)
    })
  }

  private func entries(sexual: Int = 0) -> @Sendable () -> [[String: Any]] {
    {
      [
        PixivFixtures.rankingEntry(.init(id: 301, pages: 2), rank: 1),
        PixivFixtures.rankingEntry(.init(id: 302, sexual: 1), rank: 2),
        PixivFixtures.rankingEntry(.init(id: 303, sexual: sexual), rank: 3),
      ]
    }
  }

  private func loaded(_ panel: PanelFixture) async throws {
    await panel.controller.pixivBrowser.commit().value
    try await waitFor { panel.pixiv.hasLoaded && !panel.pixiv.isLoading }
  }

  // MARK: Summary

  func testTheSummaryNamesTheRankingAndHowManyWorksTheFiltersHide() async throws {
    try await withPanel(pixivTransport: try ranking(entries: entries())) { panel in
      let fresh = PixivListSummary.make(panel.controller.pixivBrowse)
      XCTAssertEqual(fresh.text, "pixiv", "before the first page the line is just the name")

      try await loaded(panel)
      XCTAssertEqual(
        PixivListSummary.make(panel.controller.pixivBrowse).text,
        "Daily ranking · top 500 · 1 hidden by your filters on this page")

      await panel.controller.pixivBrowser.set(.questionable, isOn: true).value
      try await waitFor { panel.pixiv.hiddenCount == 0 }
      XCTAssertEqual(
        PixivListSummary.make(panel.controller.pixivBrowse).text, "Daily ranking · top 500",
        "nothing hidden adds nothing")

      await panel.controller.pixivBrowser.choose(ranking: .monthly).value
      try await waitFor {
        panel.pixiv.committedQuery?.ranking == .monthly && !panel.pixiv.isLoading
      }
      XCTAssertEqual(
        PixivListSummary.make(panel.controller.pixivBrowse).text, "Monthly ranking · top 500")
    }
  }

  func testTheSummaryCountsSearchResultsAndSaysLoadingWhilePagesLoad() async throws {
    let transport = try ranking(
      entries: entries(),
      search: [
        PixivFixtures.searchEntry(.init(id: 701)), PixivFixtures.searchEntry(.init(id: 702)),
      ])
    try await withPanel(pixivTransport: transport) { panel in
      let model = panel.controller.pixivBrowser
      model.sleep = ManualSleeper().closure
      try await loaded(panel)
      model.setText("sky")
      let search = model.commit()
      XCTAssertTrue(panel.pixiv.isLoading || panel.controller.isBusy("pixivSearch"))
      await search.value
      try await waitFor { panel.pixiv.committedQuery?.text == "sky" && !panel.pixiv.isLoading }
      XCTAssertEqual(PixivListSummary.make(panel.controller.pixivBrowse).text, "2 results")
    }
    // pixiv answers only once the test lets it, so the page is loading for as long as it looks.
    let gate = DispatchSemaphore(value: 0)
    let held = PixivFixtureTransport { _ in
      _ = gate.wait(timeout: .now() + 10)
      return PixivFixtures.ranking([PixivFixtures.rankingEntry(.init(id: 301), rank: 1)])
    }
    try await withPanel(pixivTransport: held) { panel in
      await panel.controller.pixivBrowser.commit().value
      try await waitFor { panel.pixiv.isLoading }
      XCTAssertEqual(PixivListSummary.make(panel.controller.pixivBrowse).text, "Loading pixiv…")
      XCTAssertEqual(PixivEmptyState.make(panel.controller.pixivBrowse), .loading)
      gate.signal()
      try await waitFor { panel.pixiv.hasLoaded && !panel.pixiv.isLoading }
    }
  }

  // MARK: What replaces the grid

  func testTheGridIsReplacedByTheFirstReasonThatAppliesLoadingErrorHiddenOrNothing() async throws {
    // Nothing asked for yet: not an empty ranking but a page about to load.
    try await withPanel(pixivTransport: try ranking(entries: entries())) { panel in
      XCTAssertEqual(PixivEmptyState.make(panel.controller.pixivBrowse), .loading)
      try await loaded(panel)
      XCTAssertNil(PixivEmptyState.make(panel.controller.pixivBrowse), "works are on show")
    }
    // Every work hidden by the age rating: Clear filters, and Next while there is one.
    try await withPanel(
      pixivTransport: try ranking(entries: {
        (0..<3).map { PixivFixtures.rankingEntry(.init(id: 400 + $0, sexual: 1), rank: $0 + 1) }
      })
    ) { panel in
      try await loaded(panel)
      XCTAssertEqual(
        PixivEmptyState.make(panel.controller.pixivBrowse),
        .filtersHideAll(hidden: 3, canGoNext: true))
      await panel.controller.pixivBrowser.set(.everyone, isOn: false).value
      try await settle(panel)
      XCTAssertEqual(
        PixivEmptyState.make(panel.controller.pixivBrowse),
        .filtersHideAll(hidden: 3, canGoNext: true))
    }
    // An empty ranking, and an empty search.
    try await withPanel(pixivTransport: try ranking(entries: { [] })) { panel in
      try await loaded(panel)
      XCTAssertEqual(PixivEmptyState.make(panel.controller.pixivBrowse), .nothing(searching: false))
      let model = panel.controller.pixivBrowser
      model.sleep = ManualSleeper().closure
      model.setText("nothing")
      await model.commit().value
      try await waitFor { panel.pixiv.committedQuery?.text == "nothing" && !panel.pixiv.isLoading }
      XCTAssertEqual(PixivEmptyState.make(panel.controller.pixivBrowse), .nothing(searching: true))
    }
    // pixiv refused: the error leads, and Retry asks again.
    let failing = PixivFixtureTransport { _ in throw PixivFailure(code: .status(429)) }
    try await withPanel(pixivTransport: failing) { panel in
      await panel.controller.pixivBrowser.commit().value
      try await waitFor { panel.pixiv.errorMessage != nil && !panel.pixiv.isLoading }
      guard case .error(let message) = PixivEmptyState.make(panel.controller.pixivBrowse) else {
        return XCTFail("a failed first page is an error, not an empty ranking")
      }
      XCTAssertEqual(message, panel.pixiv.errorMessage)
      XCTAssertFalse(message.isEmpty)
    }
  }

  private func settle(_ panel: PanelFixture) async throws {
    try await waitFor { !panel.pixiv.isLoading }
  }

  func testThePagingBarStaysOnlyWithWorksOrPagesToGoToAndRefreshNeverSpinsBesideTheCentre()
    async throws
  {
    // Loading the first page: the centre says so, once; no bar, and Refresh only waits.
    let gate = DispatchSemaphore(value: 0)
    // One page in all, so no later page is read ahead and every answer the gate lets through is
    // the one the test waits for.
    let image = try PanelTestCase.gif(frames: 1, brightness: 0.6)
    let held = PixivFixtureTransport { url in
      if url.host == "i.pximg.net" { return image }
      _ = gate.wait(timeout: .now() + 10)
      return PixivFixtures.ranking([PixivFixtures.rankingEntry(.init(id: 301), rank: 1)], total: 1)
    }
    try await withPanel(pixivTransport: held) { panel in
      defer { gate.signal() }
      await panel.controller.pixivBrowser.commit().value
      try await waitFor { panel.pixiv.isLoading }
      let loading = panel.controller.pixivBrowse
      XCTAssertFalse(PixivPagerBar.isShown(for: loading))
      XCTAssertFalse(PixivHeaderRow.refreshSpins(loading), "one loading indicator, in the centre")
      gate.signal()
      try await waitFor { panel.pixiv.hasLoaded && !panel.pixiv.isLoading }
      XCTAssertTrue(PixivPagerBar.isShown(for: panel.controller.pixivBrowse), "works on show")

      // A refresh that replaces works on show: the grid stays, so Refresh says it is busy.
      let refresh = panel.controller.pixivBrowser.refresh()
      try await waitFor { panel.pixiv.isLoading }
      XCTAssertTrue(PixivHeaderRow.refreshSpins(panel.controller.pixivBrowse))
      XCTAssertTrue(PixivPagerBar.isShown(for: panel.controller.pixivBrowse))
      gate.signal()
      await refresh.value
      try await settle(panel)
    }
    // Every work of a page hidden: the bar stays while there are other pages to go to.
    for (total, shown) in [(500, true), (3, false)] {
      try await withPanel(
        pixivTransport: PixivFixtureTransport { _ in
          PixivFixtures.ranking(
            (0..<3).map { PixivFixtures.rankingEntry(.init(id: 400 + $0, sexual: 1), rank: $0 + 1) },
            total: total)
        }
      ) { panel in
        try await loaded(panel)
        XCTAssertEqual(
          PixivPagerBar.isShown(for: panel.controller.pixivBrowse), shown,
          "\(total) works: the bar is there only with another page to go to")
      }
    }
    // Nothing found, and an error: the centre says it all.
    try await withPanel(pixivTransport: try ranking(entries: { [] })) { panel in
      try await loaded(panel)
      XCTAssertFalse(PixivPagerBar.isShown(for: panel.controller.pixivBrowse))
    }
    let failing = PixivFixtureTransport { _ in throw PixivFailure(code: .status(429)) }
    try await withPanel(pixivTransport: failing) { panel in
      await panel.controller.pixivBrowser.commit().value
      try await waitFor { panel.pixiv.errorMessage != nil && !panel.pixiv.isLoading }
      XCTAssertFalse(PixivPagerBar.isShown(for: panel.controller.pixivBrowse))
    }
  }

  // MARK: Tiles and the inspector

  private func work(
    rank: Int? = nil, rating: PixivRating = .everyone, pages: Int = 1, author: String = "Artist",
    ai: Bool? = nil
  ) -> PixivWork {
    PixivWork(
      id: "301", title: "Sky", authorID: "31415", authorName: author, thumbnailURL: nil,
      width: 1920,
      height: 1080, pageCount: pages, rating: rating, aiGenerated: ai, tags: ["a"], rank: rank)
  }

  func testATileWearsTheRankR18AndThePageCountAndSpeaksTheSameFactsInOrder() {
    let busy = PixivTile(
      work: work(rank: 3, rating: .mature, pages: 2), savedPages: [0, 1], image: nil, ring: nil)
    let facts = PixivTileFacts(busy)
    XCTAssertEqual(facts.rank, 3)
    XCTAssertTrue(facts.isMature)
    XCTAssertEqual(facts.pageCount, 2)
    XCTAssertTrue(facts.isSaved)
    XCTAssertEqual(
      facts.spoken, "by Artist, Ranked #3, Mature (R-18), 2 pages, In your library")

    let plain = PixivFacts(work(), saved: [])
    XCTAssertNil(plain.rank)
    XCTAssertFalse(plain.isMature)
    XCTAssertNil(plain.pageCount, "a single page carries no badge")
    XCTAssertEqual(plain.spoken, "by Artist")
    XCTAssertEqual(PixivFacts(work(author: ""), saved: []).spoken, "", "no author, nothing to say")

    XCTAssertFalse(
      PixivFacts(work(rating: .questionable), saved: []).isMature,
      "Questionable gets no badge; the inspector says so")
  }

  func testASmallTileKeepsOnlyTheSavedCheckAndR18WhileVoiceOverStillHearsEveryFact() {
    let facts = PixivFacts(work(rank: 3, rating: .mature, pages: 2), saved: [0])
    let roomy = PixivTileCorners(facts, isCompact: false)
    XCTAssertEqual(roomy.rank, 3)
    XCTAssertEqual(roomy.pageCount, 2)
    XCTAssertTrue(roomy.showsSaved)
    XCTAssertTrue(roomy.showsMature)

    let small = PixivTileCorners(facts, isCompact: true)
    XCTAssertNil(small.rank, "the rank would meet the saved check on a small tile")
    XCTAssertNil(small.pageCount, "and the page count would cover the picture")
    XCTAssertTrue(small.showsSaved)
    XCTAssertTrue(small.showsMature, "R-18 stays: it changes what the person does")
    XCTAssertEqual(
      facts.spoken, "by Artist, Ranked #3, Mature (R-18), 2 pages, In your library",
      "the label keeps what the corners leave out")

    XCTAssertTrue(PixivTileCorners.isCompact(side: 48), "beside the inspector of the smallest window")
    XCTAssertFalse(PixivTileCorners.isCompact(side: TileGridLayout.preferredTileWidth))
  }

  func testTheCompactPillSaysOnlyTheShareOfOneSaveOrHowManySavesThereAre() {
    let work = work()
    func row(_ page: Int, _ status: PixivDownload.Status, received: Int64 = 0, expected: Int64? = nil)
      -> PixivDownloadRow
    {
      PixivDownloadRow(
        work: work, pageIndex: page, status: status, bytesReceived: received,
        bytesExpected: expected)
    }
    let one = try? XCTUnwrap(PixivActivity([row(0, .downloading, received: 42, expected: 100)]))
    XCTAssertEqual(one?.figure, "42%")
    XCTAssertEqual(one?.label, "pixiv: Sky · 42%", "the tooltip and VoiceOver keep the whole label")
    XCTAssertNil(PixivActivity([row(0, .waiting)])?.figure, "an unknown share leaves the ring alone")
    let several = PixivActivity([row(0, .downloading), row(1, .waiting), row(2, .paused)])
    XCTAssertEqual(several?.figure, "2", "paused saves are not under way")
    XCTAssertEqual(several?.label, "2 pixiv downloads")
  }

  func testTheInspectorsMetaLineGivesTheSizePagesRatingAndTheAIFlagOnlyWhenTheyApply() {
    func selection(
      work: PixivWork, width: Int = 1360, height: Int = 1920, count: Int = 1
    ) -> PixivSelection {
      PixivSelection(
        work: work, pageIndex: 0, pageCount: count, pages: .loaded, preview: nil, thumbnail: nil,
        pageWidth: width, pageHeight: height, libraryID: "pixiv-301-p0", savedPages: [], job: nil)
    }
    XCTAssertEqual(PixivMeta.parts(selection(work: work()), locale: english), ["1,360 × 1,920"])
    XCTAssertEqual(
      PixivMeta.parts(
        selection(work: work(rating: .questionable, ai: true), count: 3), locale: english),
      ["1,360 × 1,920", "3 pages", "Questionable (PG-13)", "AI-generated"])
    XCTAssertEqual(
      PixivMeta.parts(selection(work: work(rating: .mature)), locale: english),
      ["1,360 × 1,920", "Mature (R-18)"])
    XCTAssertEqual(
      PixivMeta.parts(selection(work: work(ai: false), width: 0, height: 0), locale: english), [],
      "a page whose size is not known yet shows no size")
    XCTAssertEqual(
      PixivMeta.parts(selection(work: work()), locale: Locale(identifier: "de_DE")),
      ["1.360 × 1.920"],
      "the size follows the panel's number formatting")
  }

  func testTheArtistLinkIsOnlyBuiltForAnIdThePixivAllowlistOpens() {
    XCTAssertEqual(work().authorProfileURL?.absoluteString, "https://www.pixiv.net/users/31415")
    for id in ["", "31415/../x", "abc", "１２３", "1?x=y"] {
      let odd = PixivWork(
        id: "301", title: "", authorID: id, authorName: "A", thumbnailURL: nil, width: 1, height: 1,
        pageCount: 1, rating: .everyone, aiGenerated: nil, tags: [], rank: nil)
      XCTAssertNil(odd.authorProfileURL, "\(id) names no artist")
    }
  }

  func testApplyReappliesWhatTheTargetShowsAndNeedsADisplayThatCanShowIt() {
    XCTAssertEqual(
      PixivApplyOffer(
        libraryID: "pixiv-301-p0",
        target: MediaApplyTarget(canShowWallpaper: true, wallpaperID: nil)),
      PixivApplyOffer(
        libraryID: "pixiv-301-p0",
        target: MediaApplyTarget(canShowWallpaper: true, wallpaperID: "other")))
    let showing = PixivApplyOffer(
      libraryID: "pixiv-301-p0",
      target: MediaApplyTarget(canShowWallpaper: true, wallpaperID: "pixiv-301-p0"))
    XCTAssertTrue(showing.reapplies)
    XCTAssertTrue(showing.isEnabled)
    let mirror = PixivApplyOffer(
      libraryID: "pixiv-301-p0", target: MediaApplyTarget(canShowWallpaper: false, wallpaperID: nil)
    )
    XCTAssertFalse(mirror.reapplies)
    XCTAssertFalse(mirror.isEnabled, "a mirror or a disabled display cannot take it")
  }

  // MARK: The ring

  func testAClickOnATilesRingResumesAPausedSaveCancelsOneUnderWayAndRetriesAFailedOne() async throws
  {
    let image = try PanelTestCase.gif(frames: 1, brightness: 0.6)
    let transport = PixivFixtureTransport(respondingToSession: { url, _ in
      if url.host == "i.pximg.net" {
        if url.lastPathComponent.hasPrefix("303_") { throw PixivFailure(code: .status(404)) }
        return image
      }
      if url.path.hasSuffix("/pages") {
        return PixivFixtures.pages(
          workID: Int(url.pathComponents.dropLast().last ?? "") ?? 0, count: 2)
      }
      return PixivFixtures.ranking([
        PixivFixtures.rankingEntry(.init(id: 301, pages: 2), rank: 1),
        PixivFixtures.rankingEntry(.init(id: 303, pages: 2), rank: 3),
      ])
    })
    try await withPanel(pixivTransport: transport) { panel in
      let controller = panel.controller
      try await loaded(panel)
      let first = try XCTUnwrap(panel.pixiv.works.first { $0.id == "301" })
      let failing = try XCTUnwrap(panel.pixiv.works.first { $0.id == "303" })

      try await controller.pixivDownload(workID: "301", page: 1)
      try await controller.pixivPause(id: "pixiv-301-p1")
      try await panel.waitUntil {
        panel.pixiv.downloads.download(for: "pixiv-301-p1")?.status == .paused
      }
      let paused = try XCTUnwrap(controller.pixivTile(for: first).ring)
      XCTAssertEqual(paused.state.action, .resume)
      try await PixivTileCell.perform(paused, in: controller)
      try await panel.waitUntil(timeout: 10) {
        panel.pixiv.downloads.download(for: "pixiv-301-p1")?.status == .finished
      }
      XCTAssertNil(controller.pixivTile(for: first).ring, "a finished save wears no ring")

      try await controller.pixivDownload(workID: "303", page: 0)
      try await panel.waitUntil {
        if case .failed = panel.pixiv.downloads.download(for: "pixiv-303-p0")?.status {
          return true
        }
        return false
      }
      let failed = try XCTUnwrap(controller.pixivTile(for: failing).ring)
      XCTAssertEqual(failed.state.kind, .failed)
      XCTAssertEqual(failed.state.action, .retry)
      XCTAssertEqual(failed.jobID, "pixiv-303-p0")
      try await PixivTileCell.perform(failed, in: controller)
      XCTAssertNil(controller.errors.message)
    }
  }
}

/// A tile's facts for a work and the pages of it that are saved.
@MainActor
private func PixivFacts(_ work: PixivWork, saved: [Int]) -> PixivTileFacts {
  PixivTileFacts(PixivTile(work: work, savedPages: saved, image: nil, ring: nil))
}
