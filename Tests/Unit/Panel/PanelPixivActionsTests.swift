import XCTest

@testable import WallpaperMachine

/// The pixiv page through the typed actions: browsing a ranking, stepping through a work's pages,
/// saving one to the library, and signing in for R-18 works. pixiv is a fixture and the sign-in
/// window a closure, so nothing leaves the machine and no window opens.
@MainActor
final class PanelPixivActionsTests: MediaPanelTestCase {
  private func loadRanking(_ panel: PanelFixture, _ query: PixivQuery = PixivQuery()) async throws {
    try await panel.controller.pixivSearch(query)
    try await waitFor { panel.pixiv.hasLoaded && !panel.pixiv.isLoading }
  }

  private func savedPage(_ index: Int, of work: String = "301") -> BridgeWallpaperEntry {
    BridgeWallpaperEntry(
      id: "pixiv-\(work)-p\(index)", title: "Saved page \(index)", kind: .webpage, supported: true,
      active: false, selected: false, previewPath: nil)
  }

  func testBrowsingARankingStepsThroughAWorksPagesAndSavesTheChosenOne() async throws {
    try await withPanel { panel in
      let controller = panel.controller
      try await loadRanking(panel)
      let browse = controller.pixivBrowse
      XCTAssertEqual(browse.works.map(\.id), ["301", "303"], "the default Everyone rating hides 302")
      XCTAssertEqual(browse.hiddenCount, 1)
      XCTAssertFalse(browse.isSearching)
      XCTAssertEqual(browse.query.ranking, .daily)
      XCTAssertEqual(browse.pager.maxPages, 1000)
      XCTAssertNil(controller.pixivSelection)

      try await controller.pixivSelect(workID: "301")
      try await panel.waitUntil { panel.pixiv.selectedPageList?.count == 2 }
      var selection = try XCTUnwrap(controller.pixivSelection)
      XCTAssertEqual(selection.pageCount, 2)
      XCTAssertEqual(selection.pageIndex, 0)
      XCTAssertEqual(selection.pages, .loaded)
      XCTAssertEqual(selection.download, .available(.page(1)))
      XCTAssertEqual(selection.libraryID, "pixiv-301-p0")

      try await controller.pixivSelectPage(workID: "301", page: 1)
      selection = try XCTUnwrap(controller.pixivSelection)
      XCTAssertEqual(selection.pageIndex, 1)
      XCTAssertEqual(selection.download, .available(.page(2)), "the button reads Download page 2")
      XCTAssertEqual(selection.libraryID, "pixiv-301-p1")

      try await controller.pixivDownload(workID: "301", page: 1)
      XCTAssertEqual(controller.pixivActivity?.jobCount, 1, "the title bar says a save is under way")
      try await panel.waitUntil(timeout: 10) {
        panel.pixiv.downloads.download(for: "pixiv-301-p1")?.status == .finished
      }
      XCTAssertNil(controller.pixivActivity)
      let project = panel.root.appendingPathComponent("Library/pixiv-301-p1/project.json")
      let manifest = try XCTUnwrap(
        JSONSerialization.jsonObject(with: Data(contentsOf: project)) as? [String: Any])
      XCTAssertEqual(manifest["type"] as? String, "web")
      XCTAssertEqual((manifest["pixiv"] as? [String: Any])?["page"] as? Int, 1)
      XCTAssertNil(controller.errors.message)
    }
  }

  func testAPausedSaveResumesFromItsTileAndFromTheSharedQueue() async throws {
    try await withPanel { panel in
      let controller = panel.controller
      try await loadRanking(panel)
      let work = try XCTUnwrap(controller.pixivBrowse.works.first { $0.id == "301" })
      try await controller.pixivDownload(workID: "301", page: 1)
      try await controller.pixivPause(id: "pixiv-301-p1")
      try await panel.waitUntil { panel.pixiv.downloads.download(for: "pixiv-301-p1")?.status == .paused }

      let tile = controller.pixivTile(for: work)
      XCTAssertEqual(tile.ring?.state.action, .resume, "the tile's ring offers Resume")
      XCTAssertEqual(tile.ring?.jobID, "pixiv-301-p1")
      let queue = controller.downloadQueue
      XCTAssertEqual(queue.unresolved.map(\.id), ["pixiv-301-p1"], "so does a row of the shared queue")
      XCTAssertEqual(queue.unresolved.first?.source, .pixiv)
      XCTAssertEqual(queue.unresolved.first?.status, "Download paused")
      XCTAssertNil(controller.pixivActivity, "a paused save is not under way")

      try await controller.pixivResume(id: "pixiv-301-p1")
      try await panel.waitUntil(timeout: 10) {
        panel.pixiv.downloads.download(for: "pixiv-301-p1")?.status == .finished
      }
      XCTAssertNil(controller.errors.message)
      XCTAssertNil(controller.pixivTile(for: work).ring, "a finished save wears no ring")
    }
  }

  func testSigningInUnlocksMatureWorksAndLoggingOutLocksThemAgain() async throws {
    try await withPanel { panel in
      let controller = panel.controller
      var windows = 0
      controller.signInToPixiv = {
        windows += 1
        return PixivFixtures.session
      }
      try await loadRanking(panel)
      XCTAssertFalse(controller.pixivAccount.allowsMature, "the Mature box is disabled until a sign-in")
      XCTAssertEqual(controller.pixivAccount.r18Note, .signInToShow)

      try await controller.pixivSignIn()
      XCTAssertTrue(controller.pixivAccount.isSigningIn, "the window is open until the session is checked")
      try await panel.waitUntil(timeout: 5) { panel.pixiv.account != nil && !panel.pixiv.isSigningIn }
      XCTAssertEqual(windows, 1)
      XCTAssertEqual(panel.pixivSessions.session, PixivFixtures.session)
      let account = controller.pixivAccount
      XCTAssertTrue(account.isSignedIn)
      XCTAssertEqual(account.name, "Tester")
      XCTAssertEqual(account.id, "31415926")
      XCTAssertEqual(account.showsR18, true)
      XCTAssertTrue(account.allowsMature)
      XCTAssertEqual(account.r18Note, .neverShowsR18G)
      for state in [String(describing: account), String(describing: controller.pixivBrowse)] {
        XCTAssertFalse(state.contains(PixivFixtures.session), "the session is never part of the panel's state")
      }

      try await controller.pixivSignIn()
      XCTAssertEqual(windows, 1, "signed in, the action opens nothing")

      try await loadRanking(
        panel, PixivQuery(ranking: .dailyR18, ratings: [.everyone, .mature]))
      try await panel.waitUntil(timeout: 5) {
        panel.pixiv.committedQuery?.ranking == .dailyR18 && !panel.pixiv.isLoading
      }
      XCTAssertEqual(controller.pixivBrowse.query.ranking, .dailyR18)
      XCTAssertEqual(controller.pixivBrowse.works.count, 3)
      XCTAssertTrue(controller.pixivBrowse.works.allSatisfy { $0.rating == .mature })

      try await controller.pixivSignOut()
      try await panel.waitUntil(timeout: 5) {
        !panel.pixiv.isSignedIn && panel.pixiv.committedQuery?.ranking == .daily && !panel.pixiv.isLoading
      }
      XCTAssertNil(panel.pixivSessions.session)
      XCTAssertEqual(controller.pixivBrowse.query.ranking, .daily, "an R-18 ranking falls back to its all-ages one")
      XCTAssertEqual(controller.pixivBrowse.query.ratings, [.everyone], "the Mature box unticks")
      XCTAssertFalse(controller.pixivBrowse.works.contains { $0.rating == .mature })
      XCTAssertFalse(controller.pixivAccount.allowsMature)
      XCTAssertNil(controller.pixivAccount.name)
      XCTAssertEqual(windows, 1)
      XCTAssertNil(controller.errors.message)
    }
  }

  func testASearchAsksForNothingR18UntilSignedInAndRefusesWhatNoControlOffers() async throws {
    try await withPanel { panel in
      let controller = panel.controller
      try await controller.pixivSearch(PixivQuery(ranking: .dailyR18, ratings: [.everyone, .mature]))
      XCTAssertEqual(panel.pixiv.query.ranking, .daily, "signed out, nothing R-18 is asked for")
      XCTAssertEqual(panel.pixiv.query.ratings, [.everyone])

      for invalid in [
        PixivQuery(ratings: [.grotesque]), PixivQuery(ratings: [.everyone, .grotesque]),
        PixivQuery(text: String(repeating: "a", count: 257)),
      ] {
        do {
          try await controller.pixivSearch(invalid)
          XCTFail("\(invalid) is not a query the page sends")
        } catch is InvalidControlValue {}
      }
      for page in [0, -1, 1_001] {
        do {
          try await controller.pixivLoadPage(page)
          XCTFail("page \(page) is outside pixiv's pages")
        } catch is InvalidControlValue {}
      }
      do {
        try await controller.pixivSelectPage(workID: "11", page: 0)
        XCTFail("nothing is selected, so there are no pages to step through")
      } catch is InvalidControlValue {}
      do {
        try await controller.pixivSelect(workID: "999")
        XCTFail("a work the page has never listed is a stale control")
      } catch is InvalidControlValue {}
      do {
        try await controller.pixivDownload(workID: "999", page: 0)
        XCTFail("a work the page has never listed cannot be saved")
      } catch is InvalidControlValue {}

      controller.signInToPixiv = { PixivFixtures.session }
      try await controller.pixivSignIn()
      try await panel.waitUntil { panel.pixiv.account != nil }
      try await controller.pixivSearch(PixivQuery(ranking: .dailyR18, ratings: [.everyone, .mature]))
      XCTAssertEqual(panel.pixiv.query.ranking, .dailyR18)
      XCTAssertEqual(panel.pixiv.query.ratings, [.everyone, .mature])
    }
  }

  func testPagingAcceptsOnlyPagesPixivServesAndAStepOnlyReachesThePagesOfTheSelectedWork() async throws {
    // Each ranking page lists one work of its own, so a page change is visible in the works.
    let image = try PanelTestCase.gif(frames: 1, brightness: 0.6)
    let transport = PixivFixtureTransport(respondingToSession: { url, _ in
      if url.host == "i.pximg.net" { return image }
      if url.path.hasSuffix("/pages") {
        return PixivFixtures.pages(workID: Int(url.pathComponents.dropLast().last ?? "") ?? 0, count: 2)
      }
      let page = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
        .first { $0.name == "p" }?.value.flatMap(Int.init) ?? 1
      return PixivFixtures.ranking(
        [PixivFixtures.rankingEntry(.init(id: 300 + page, pages: 2), rank: 1)], page: page)
    })
    try await withPanel(pixivTransport: transport) { panel in
      let controller = panel.controller
      try await loadRanking(panel)
      XCTAssertEqual(controller.pixivBrowse.works.map(\.id), ["301"])
      XCTAssertTrue(controller.pixivBrowse.pager.canGoForward)
      XCTAssertFalse(controller.pixivBrowse.pager.canGoBack)

      try await controller.pixivSelect(workID: "301")
      try await waitFor { panel.pixiv.selectedPageList?.count == 2 }
      try await controller.pixivLoadPage(2)
      try await waitFor { panel.pixiv.page == 2 && !panel.pixiv.isLoading }
      XCTAssertEqual(controller.pixivBrowse.works.map(\.id), ["302"])
      XCTAssertEqual(controller.pixivBrowse.pager.page, 2)
      XCTAssertTrue(controller.pixivBrowse.pager.canGoBack)
      XCTAssertEqual(controller.pixivBrowse.selectedID, "301", "the selection survives paging away from it")
      XCTAssertEqual(controller.pixivSelection?.work.id, "301")

      for page in [-1, 2] {
        do {
          try await controller.pixivSelectPage(workID: "301", page: page)
          XCTFail("301 has pages 0 and 1")
        } catch is InvalidControlValue {}
      }
      do {
        try await controller.pixivSelectPage(workID: "302", page: 0)
        XCTFail("302 is not the selected work")
      } catch is InvalidControlValue {}
      do {
        try await controller.pixivDownload(workID: "301", page: 2)
        XCTFail("301 has no third page")
      } catch is InvalidControlValue {}
      try await controller.pixivDownload(workID: "301", page: 1)
      try await waitFor(timeout: 10) {
        panel.pixiv.downloads.download(for: "pixiv-301-p1")?.status == .finished
      }
    }
  }

  func testOnlyAPausedSaveResumesAndOnlyAFailedOrCancelledOneRetries() async throws {
    try await withPanel { panel in
      let controller = panel.controller
      try await loadRanking(panel)
      for id in ["pixiv-301-p0", "no-such-save"] {
        do {
          try await controller.pixivResume(id: id)
          XCTFail("\(id) is not a paused save")
        } catch is InvalidControlValue {}
        do {
          try await controller.pixivRetryDownload(id: id)
          XCTFail("\(id) is not a save that failed")
        } catch is InvalidControlValue {}
      }
      try await controller.pixivDownload(workID: "301", page: 0)
      try await panel.waitUntil(timeout: 10) {
        panel.pixiv.downloads.download(for: "pixiv-301-p0")?.status == .finished
      }
      do {
        try await controller.pixivRetryDownload(id: "pixiv-301-p0")
        XCTFail("a save that finished has nothing to retry")
      } catch is InvalidControlValue {}
      try await controller.pixivCancel(id: "nothing")
      try await controller.pixivPause(id: "nothing")
      XCTAssertEqual(controller.pixivDownloadRows.map(\.id), ["pixiv-301-p0"])
      try await controller.pixivClearDownloads()
      XCTAssertTrue(controller.pixivDownloadRows.isEmpty)
    }
  }

  /// A view that reads the queue, the title bar's note or the inspector hears about every step a
  /// save takes, though the save is an object of its own.
  func testASavesStepsReachEveryStateAViewReads() async throws {
    try await withPanel { panel in
      let controller = panel.controller
      try await loadRanking(panel)
      try await controller.pixivSelect(workID: "301")
      try await waitFor { panel.pixiv.selectedPageList?.count == 2 }
      let queueChanges = Counter()
      let activityChanges = Counter()
      let selectionChanges = Counter()
      let loops = [
        ObservationLoop(track: { _ = controller.downloadQueue }, onChange: { queueChanges.value += 1 }),
        ObservationLoop(track: { _ = controller.pixivActivity }, onChange: { activityChanges.value += 1 }),
        ObservationLoop(track: { _ = controller.pixivSelection }, onChange: { selectionChanges.value += 1 }),
      ]
      loops.forEach { $0.start() }
      defer { loops.forEach { $0.stop() } }

      try await controller.pixivDownload(workID: "301", page: 0)
      try await waitFor(timeout: 10) {
        panel.pixiv.downloads.download(for: "pixiv-301-p0")?.status == .finished
      }
      // Each observation reports on the turn after a change, so give it that turn.
      try await waitFor { queueChanges.value > 0 }
      try await waitFor { activityChanges.value > 0 }
      try await waitFor { selectionChanges.value > 0 }
    }
  }

  /// The shared Downloads list sends a row's action to the queue the row belongs to.
  func testARowOfTheSharedListActsOnItsOwnQueue() async throws {
    try await withPanel { panel in
      let controller = panel.controller
      try await loadRanking(panel)
      try await controller.pixivDownload(workID: "301", page: 1)
      var row = try XCTUnwrap(controller.downloadQueue.downloads.first)
      XCTAssertEqual(row.source, .pixiv)
      XCTAssertTrue(row.canPause)
      XCTAssertTrue(row.canCancel)
      XCTAssertFalse(row.canResume)

      try await controller.pauseDownload(row)
      try await waitFor { panel.pixiv.downloads.download(for: "pixiv-301-p1")?.status == .paused }
      row = try XCTUnwrap(controller.downloadQueue.downloads.first)
      XCTAssertTrue(row.canResume)
      XCTAssertFalse(row.canPause)
      XCTAssertFalse(row.canRetry, "a paused save resumes, it is not retried")

      try await controller.resumeDownload(row)
      try await waitFor(timeout: 10) {
        panel.pixiv.downloads.download(for: "pixiv-301-p1")?.status == .finished
      }
      XCTAssertNil(controller.errors.message)
    }
  }

  func testTheRowButtonsFollowTheJobsState() {
    let waiting = DownloadRow(id: "w", title: "W", isPending: true, isQueued: true)
    XCTAssertTrue(waiting.canPause)
    XCTAssertTrue(waiting.canCancel, "a waiting job is removed from the queue")
    let signIn = DownloadRow(id: "s", title: "S", isPending: true, isSignInOnly: true)
    XCTAssertFalse(signIn.canPause, "a sign-in downloads nothing, so there is nothing to pause")
    XCTAssertTrue(signIn.canCancel)
    let failed = DownloadRow(id: "f", title: "F", errorMessage: "no")
    XCTAssertTrue(failed.canRetry)
    XCTAssertFalse(failed.canCancel)
    XCTAssertTrue(failed.isUnresolved)
    let cancelled = DownloadRow(id: "c", title: "C", isCancelled: true)
    XCTAssertTrue(cancelled.canRetry)
    let finished = DownloadRow(id: "d", title: "D")
    XCTAssertFalse(finished.canRetry)
    XCTAssertFalse(finished.isUnresolved)
  }

  // MARK: Saved pages

  func testTheSavedPagesFollowTheLibraryAndNotUnrelatedChanges() async throws {
    try await withPanel { panel in
      let controller = panel.controller
      try await loadRanking(panel)
      let work = try XCTUnwrap(controller.pixivBrowse.works.first { $0.id == "301" })
      XCTAssertEqual(controller.pixivTile(for: work).savedPages, [])
      XCTAssertFalse(controller.pixivTile(for: work).isSaved)

      panel.store.librarySnapshot.wallpapers = [savedPage(0)]
      XCTAssertEqual(controller.pixivInstalledPages["301"], [0])
      XCTAssertTrue(controller.pixivTile(for: work).isSaved)

      // Playback state is not the library: the index it keeps is the one it reads from.
      controller.pixivInstalledIndex = (panel.store.libraryPresentationRevision, ["301": [7]])
      panel.store.appSnapshot.playbackState = .paused
      XCTAssertEqual(controller.pixivInstalledPages["301"], [7], "an unrelated change reuses the index")

      panel.store.librarySnapshot.wallpapers.append(savedPage(1))
      XCTAssertEqual(controller.pixivInstalledPages["301"], [0, 1])
      panel.store.librarySnapshot.wallpapers.removeFirst()
      XCTAssertEqual(controller.pixivInstalledPages["301"], [1])
    }
  }

  func testASavedPageOffersApplyAndItsDoubleClickAppliesOnlyWhereADisplayCanShowIt() async throws {
    try await withPanel { panel in
      let controller = panel.controller
      try await loadRanking(panel)
      let work = try XCTUnwrap(controller.pixivBrowse.works.first { $0.id == "301" })
      XCTAssertEqual(controller.pixivDoubleClick(for: work), .download(workID: "301", page: 0))

      panel.store.librarySnapshot.wallpapers = [savedPage(0)]
      try await controller.pixivSelect(workID: "301")
      XCTAssertEqual(try XCTUnwrap(controller.pixivSelection).download, .saved)
      XCTAssertEqual(controller.pixivDoubleClick(for: work), .apply(libraryID: "pixiv-301-p0"))

      panel.store.settingsSnapshot.displays[0].mode = .mirror
      XCTAssertEqual(controller.pixivDoubleClick(for: work), .nothing, "a mirror shows no wallpaper of its own")
    }
  }

  func testAPixivSaveInTheQueueAppearsWithItsWorksThumbnailAndLibraryID() async throws {
    try await withPanel { panel in
      let controller = panel.controller
      try await loadRanking(panel)
      try await controller.pixivDownload(workID: "303", page: 0)
      let row = try XCTUnwrap(controller.downloadQueue.downloads.first)
      XCTAssertEqual(row.id, "pixiv-303-p0")
      XCTAssertEqual(row.title, "Work 303")
      XCTAssertNotNil(row.image, "the work's own thumbnail, fetched with pixiv's referrer")
      try await panel.waitUntil(timeout: 10) {
        panel.pixiv.downloads.download(for: "pixiv-303-p0")?.status == .finished
      }
    }
  }
}

/// Counts the changes an observation reports.
@MainActor
private final class Counter {
  var value = 0
}
