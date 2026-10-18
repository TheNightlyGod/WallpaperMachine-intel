import Foundation

/// The pixiv page: browsing illustration rankings and tag searches, selecting a work and its pages,
/// saving a page to the library as a still wallpaper, and signing in for members-only and R-18 works.
///
/// pixiv browsing and downloads never touch the renderer, so every action is the catalog's `E`:
/// always available, never queued, and it leaves an older banner showing. A failed load or a failed
/// save shows on the page and in the queue, not in the banner.
extension PanelController {
  // MARK: State

  /// The page's list-level state: query, works, paging and the last load's outcome.
  var pixivBrowse: PixivBrowseState { PixivBrowseState(pixiv) }

  /// Who is signed in, and what that unlocks.
  var pixivAccount: PixivAccountState { PixivAccountState(pixiv) }

  /// Every pixiv save, in queue order.
  var pixivDownloadRows: [PixivDownloadRow] { pixiv.downloads.downloads.map(PixivDownloadRow.init) }

  /// The pages of each pixiv work that are in the library, read off the wallpaper ids. The index is
  /// rebuilt only when the library changes, so a download progress tick never walks a library of
  /// 10,000 wallpapers.
  var pixivInstalledPages: [String: [Int]] {
    let revision = store.libraryPresentationRevision
    if let cached = pixivInstalledIndex, cached.revision == revision { return cached.pages }
    let pages = PixivInstalledPages.index(in: store.librarySnapshot.wallpapers.map(\.id))
    pixivInstalledIndex = (revision, pages)
    return pages
  }

  /// Everything one pixiv tile wears. A tile calls this itself, so a progress tick re-renders only
  /// the tile whose save moved.
  func pixivTile(for work: PixivWork) -> PixivTile {
    let saved = pixivInstalledPages[work.id] ?? []
    let jobs = pixiv.downloads.downloads.filter { $0.work.id == work.id }.map(PixivDownloadRow.init)
    let ring = TileDownloadState.pixiv(title: work.displayTitle, jobs: jobs, savedPages: saved)
    return PixivTile(
      work: work, savedPages: saved, image: work.thumbnail,
      ring: ring.map { PixivTile.Ring(state: $0.state, jobID: $0.jobID) })
  }

  /// The selected work as the inspector shows it, or nil when nothing is selected.
  var pixivSelection: PixivSelection? {
    guard let work = pixiv.selectedWork else { return nil }
    let index = pixiv.selectedPage
    let page = pixiv.selectedPageList?.first { $0.index == index }
    let pages: PixivSelection.Pages
    switch pixiv.selectedPages {
    case nil: pages = .loading
    case .success: pages = .loaded
    case .failure(let failure): pages = .failed(failure.localizedDescription)
    }
    let libraryID = work.libraryID(page: index)
    let job = pixiv.downloads.download(for: libraryID).map(PixivDownloadRow.init)
    return PixivSelection(
      work: work, pageIndex: index, pageCount: pixiv.pageCount(of: work), pages: pages,
      preview: page?.previewURL.map { .pixivThumbnail($0) }, thumbnail: work.thumbnail,
      pageWidth: page?.width ?? (index == 0 ? work.width : 0),
      pageHeight: page?.height ?? (index == 0 ? work.height : 0), libraryID: libraryID,
      savedPages: pixivInstalledPages[work.id] ?? [], job: job)
  }

  /// What double-clicking a pixiv tile does.
  func pixivDoubleClick(for work: PixivWork) -> PixivDoubleClick {
    PixivDoubleClick.decide(
      workID: work.id, selection: pixivSelection, savedPages: pixivInstalledPages[work.id] ?? [],
      pendingJobIDs: Set(pixiv.downloads.downloads.filter(\.isPending).map(\.id)),
      targetCanShowWallpaper: mediaApplyTarget.canShowWallpaper)
  }

  /// The note in the title bar that pixiv saves are under way, on every page; nil when none are.
  var pixivActivity: PixivActivity? { PixivActivity(pixivDownloadRows) }

  // MARK: Browsing

  /// Commits the page's query. A different listing, or `refresh`, fetches its first page afresh;
  /// otherwise only the app-side filters changed and the page on show is filtered again. The store
  /// sanitizes it for the account: signed out, nothing R-18 is asked for. A repeat while one is
  /// pending should use `.latestWins`, so the newest query is the one on show.
  ///
  /// Refused: a text of more than 256 characters, and a rating no box offers (R-18G).
  func pixivSearch(_ query: PixivQuery, refresh: Bool = false) async throws {
    guard query.text.count <= 256, query.ratings.isSubset(of: PixivQuery.offeredRatings) else {
      throw InvalidControlValue()
    }
    try await run(.immediate) { pixiv.apply(query, refresh: refresh) }
  }

  /// Loads a page of the listing on show. pixiv serves at most 1,000; a number outside them is
  /// refused, and one past the last page of this listing is ignored.
  func pixivLoadPage(_ page: Int) async throws {
    guard (1...PixivService.maxPages).contains(page) else { throw InvalidControlValue() }
    try await run(.immediate) { pixiv.loadPage(page) }
  }

  /// Asks again for the page that failed.
  func pixivRetry() async throws {
    try await run(.immediate) { pixiv.retry() }
  }

  /// Selects a work, which loads its page list. The id must be one on the page, the selection or a
  /// download, so a work stays reachable after paging away from it.
  func pixivSelect(workID: String) async throws {
    try await run(.immediate) {
      guard let work = pixiv.work(id: workID) else { throw InvalidControlValue() }
      pixiv.select(work)
    }
  }

  /// Steps the selected work to another of its pages. Only the selected work has pages to step
  /// through, and `page` must be one of them.
  func pixivSelectPage(workID: String, page: Int) async throws {
    try await run(.immediate) {
      guard let work = pixiv.selectedWork, work.id == workID,
        (0...max(0, pixiv.pageCount(of: work) - 1)).contains(page)
      else { throw InvalidControlValue() }
      pixiv.selectPage(page)
    }
  }

  /// Asks again for the selected work's page list.
  func pixivRetryPages() async throws {
    try await run(.immediate) { pixiv.retrySelectedPages() }
  }

  // MARK: Saving

  /// Saves one page of a work to the library as a still wallpaper (`pixiv-<work>-p<page>`), two
  /// saves at a time in the order asked. The page must be one of the work's.
  func pixivDownload(workID: String, page: Int) async throws {
    try await run(.immediate) {
      guard let work = pixiv.work(id: workID),
        (0...max(0, pixiv.pageCount(of: work) - 1)).contains(page)
      else { throw InvalidControlValue() }
      pixiv.requestDownload(work, page: page)
    }
  }

  /// Cancels a save (or removes it from the queue). `id` is the library id; it is not checked.
  func pixivCancel(id: String) async throws {
    try await run(.immediate) { pixiv.downloads.cancel(id) }
  }

  /// Pauses a save, keeping the bytes already received where the server allows resuming.
  func pixivPause(id: String) async throws {
    try await run(.immediate) { pixiv.downloads.pause(id) }
  }

  /// Resumes a paused save. A save that is not paused is refused.
  func pixivResume(id: String) async throws {
    try await run(.immediate) {
      guard pixiv.downloads.resume(id) else { throw InvalidControlValue() }
    }
  }

  /// Tries a failed or cancelled save again. One that is not failed or cancelled is refused.
  func pixivRetryDownload(id: String) async throws {
    try await run(.immediate) {
      guard pixiv.downloads.retry(id) else { throw InvalidControlValue() }
    }
  }

  /// Clears the finished, failed and cancelled saves; paused ones stay. The shared Downloads
  /// list's Clear finished clears both queues through `clearDownloads()`.
  func pixivClearDownloads() async throws {
    try await run(.immediate) { pixiv.downloads.clearFinished() }
  }

  // MARK: Account

  /// Signs in to pixiv on its own page, in a window of its own. The app never sees the password:
  /// it takes the one session cookie pixiv sets, checks it with pixiv and keeps it in the keychain.
  /// While the window is open this brings it forward, and signed in it does nothing. `signInToPixiv`
  /// is the seam tests answer instead of the window.
  func pixivSignIn() async throws {
    try await run(.immediate) {
      if pixiv.isSigningIn {
        WebSignInWindowController.bringToFront(.pixiv)
      } else if !pixiv.isSignedIn {
        let obtain = signInToPixiv ?? { await WebSignInWindowController.obtainCookie(for: .pixiv) }
        pixiv.signIn(obtainingSessionWith: obtain)
      }
    }
  }

  /// Forgets the session, here and in the keychain, and locks R-18 works again: an R-18 work that
  /// was selected is deselected, and the listing reloads as an anonymous visitor sees it.
  func pixivSignOut() async throws {
    try await run(.immediate) { pixiv.signOut() }
  }
}
