import Foundation
import Observation

/// The Steam Workshop page's own state and what its controls do: the search draft, the filters, the
/// paging field, the popover, and the debounce that decides when typing becomes a search.
///
/// Steam does the searching, sorting and filtering, and `WorkshopStore` keeps what was last asked
/// for, so a reopened panel shows it again. What lives here is the *draft*: what the controls hold
/// before a search commits it. It is seeded from the store once, when the model is made, and never
/// reseeded, so a result arriving cannot overwrite what the person is typing. Only a search commits
/// it; typing alone does not search except by the rules of `WorkshopSearchTrigger`.
///
/// Every control starts its action through `controller.launch` under a key, so it can disable itself
/// while the action is pending. A search, a page and a list use `.latestWins`: the newest value is the
/// one that lands.
@MainActor
@Observable
final class WorkshopBrowserModel {
  unowned let controller: PanelController

  // MARK: The draft

  /// The search field's text. Edit it through `edit(text:)`.
  private(set) var text: String
  private(set) var sort: WorkshopSort
  private(set) var filters: WorkshopFilterDraft

  // MARK: Page state

  /// Filter groups the person folded. Every group starts open.
  var foldedFilterGroups: Set<String> = []
  /// What the jump field holds: the page on show until the person types another.
  var pageText = "1"
  /// Bumped whenever the grid should go back to the top: another list, an author, a collection,
  /// Back, another page.
  private(set) var scrollEpoch = 0
  /// Loads the stills and the animations of the tiles.
  let previews: WorkshopPreviewCoordinator

  /// How the timers wait; tests give them a clock they fire by hand.
  @ObservationIgnored var sleep: @Sendable (Duration) async throws -> Void = {
    try await Task.sleep(for: $0)
  }
  /// Opens an address outside the app instead of `DesktopActions.current`, which `ExternalLink`
  /// uses while this is nil; a test that checks the address sets it.
  @ObservationIgnored var openURL: (@MainActor (URL) -> Bool)?
  @ObservationIgnored private var pendingSearch: Task<Void, Never>?
  @ObservationIgnored private var scrollReport: Task<Void, Never>?
  @ObservationIgnored private var lastScrollOffset: Double?
  /// The grid's offset was restored from the last window, once.
  @ObservationIgnored private(set) var restoredScroll = false

  init(controller: PanelController) {
    self.controller = controller
    let workshop = controller.workshop
    text = workshop.searchText
    sort = workshop.sort
    filters = WorkshopFilterDraft(tags: workshop.tags, excludedTags: workshop.excludedTags)
    previews = WorkshopPreviewCoordinator(images: controller.images)
  }

  // MARK: Search

  /// An edit of the search field. Typing searches after a pause; a link pasted or dropped whole,
  /// at once; a bare item id waits for Return (see `WorkshopSearchTrigger`).
  func edit(text new: String) {
    let old = text
    guard new != old else { return }
    text = new
    pendingSearch?.cancel()
    pendingSearch = nil
    let pasted = WorkshopSearchTrigger.isPasteOrDrop(from: old, to: new)
    switch WorkshopSearchTrigger.classify(new, isPasteOrDrop: pasted) {
    case .now: search()
    case .afterPause: searchAfterPause()
    case .onReturn: break
    }
  }

  private func searchAfterPause() {
    pendingSearch = Task { @MainActor [weak self, sleep] in
      do { try await sleep(WorkshopSearchTrigger.pause) } catch { return }
      guard let self, !Task.isCancelled else { return }
      self.search()
    }
  }

  /// Return, the Refresh button, a sort or a filter: searches with the draft now, from the first page
  /// and with a fresh cache. Any typing still waiting for its pause is superseded.
  @discardableResult
  func search() -> Task<Void, Never> {
    pendingSearch?.cancel()
    pendingSearch = nil
    let text = text
    let sort = sort
    let tags = filters.tags
    let excluded = filters.excludedTags
    return controller.launch(
      PanelActionCoordinator.key("workshopSearch"), policy: .latestWins
    ) { [controller] in
      try await controller.searchWorkshop(
        text: text, sort: sort, tags: tags, excludedTags: excluded)
    }
  }

  /// Whether a pause is running before the typed text searches.
  var hasPendingSearch: Bool { pendingSearch != nil }

  func choose(sort new: WorkshopSort) {
    sort = new
    search()
  }

  func refresh() { search() }

  // MARK: Filters

  /// How many filters the Filter button counts.
  var filterCount: Int { filters.count }

  func setRequired(_ tag: String, _ required: Bool) {
    filters.setRequired(tag, required)
    search()
  }

  func setIncluded(_ tag: String, _ included: Bool) {
    filters.setIncluded(tag, included)
    search()
  }

  func setChip(_ tag: String, _ selection: TagChip.Selection) {
    filters.setChip(tag, selection)
    search()
  }

  func resetChips(in section: WorkshopFilterCatalog.Section) {
    filters.resetChips(in: section)
    search()
  }

  func includeAll(in section: WorkshopFilterCatalog.Section) {
    filters.includeAll(in: section)
    search()
  }

  func excludeAll(in section: WorkshopFilterCatalog.Section) {
    filters.excludeAll(in: section)
    search()
  }

  /// **Clear**: no required tag, the defaults excluded, and a search.
  func clearFilters() {
    filters.clear()
    search()
  }

  /// **Clear search and filters** and **Clear search**: the text goes too, and the filters return to
  /// their defaults, as the page always did.
  func clearSearchAndFilters() {
    pendingSearch?.cancel()
    pendingSearch = nil
    text = ""
    filters.clear()
    search()
  }

  func isFolded(_ group: String) -> Bool { foldedFilterGroups.contains(group) }

  func setFolded(_ group: String, _ folded: Bool) {
    if folded { foldedFilterGroups.insert(group) } else { foldedFilterGroups.remove(group) }
  }

  // MARK: Lists, sources and pages

  /// A tab. Choosing the list already on show searches it again from the first page.
  func open(_ list: WorkshopList) {
    scrollToTop()
    controller.launch(PanelActionCoordinator.key("workshopSource")) { [controller] in
      try await controller.openWorkshop(list)
    }
  }

  /// **More by this author**: the author's wallpapers, with Back returning here. Needs an author
  /// whose SteamID is known.
  func openAuthor(of item: WorkshopItem) {
    guard let id = item.authorProfileID else { return }
    scrollToTop()
    controller.launch(PanelActionCoordinator.key("workshopCreator", id: id)) { [controller] in
      try await controller.openWorkshopAuthor(id: id, name: item.creator)
    }
  }

  /// Opens a collection's wallpapers. A collection is a list, never a download.
  func openCollection(_ item: WorkshopItem) {
    scrollToTop()
    controller.launch(PanelActionCoordinator.key("workshopCollection", id: item.id)) {
      [controller] in
      try await controller.openWorkshopCollection(id: item.id, title: item.title)
    }
  }

  func goBack() {
    scrollToTop()
    controller.launch(PanelActionCoordinator.key("workshopBack")) { [controller] in
      try await controller.workshopGoBack()
    }
  }

  /// Previous, Next and the jump field. A newer page replaces one still loading.
  func showPage(_ page: Int) {
    scrollToTop()
    controller.launch(PanelActionCoordinator.key("workshopPage"), policy: .latestWins) {
      [controller] in
      try await controller.showWorkshopPage(page)
    }
  }

  /// The jump field's Return or **Go**: the field is rewritten with the page its number names, which
  /// is rounded and kept within Steam's 1,000 pages, and that page is asked for unless it is the
  /// one on show or a page is loading.
  func jump() {
    let pager = controller.workshopBrowse.pager
    let target = pager.clampedPage(typed: pageText)
    pageText = String(target)
    if target != pager.page, !pager.isLoading { showPage(target) }
  }

  /// Puts the page on show into the jump field, after a page arrived or the list changed.
  func syncPageText() {
    pageText = String(controller.workshopBrowse.pager.page)
  }

  /// **Try again** and **Retry**.
  func retry() {
    controller.launch(PanelActionCoordinator.key("workshopRetry")) { [controller] in
      try await controller.retryWorkshopSearch()
    }
  }

  func scrollToTop() { scrollEpoch &+= 1 }

  // MARK: Tiles

  func select(_ item: WorkshopItem) {
    controller.launch(PanelActionCoordinator.key("workshopSelect", id: item.id)) { [controller] in
      try await controller.selectWorkshopItem(id: item.id)
    }
  }

  /// What a double-click on a tile does, by the rule of `PanelController.workshopDoubleClick`: open
  /// a collection; apply a wallpaper that is in the library and that the target display can show
  /// (else select it); select one that is downloading; reopen the dialog of one waiting for a
  /// prerequisite; otherwise download it.
  func doubleClick(_ item: WorkshopItem) {
    switch controller.workshopDoubleClick(for: item) {
    case .openCollection:
      openCollection(item)
    case .apply:
      controller.launch(PanelActionCoordinator.key("activate", id: item.id)) { [controller] in
        try await controller.activate(item.id)
      }
    case .select:
      select(item)
    case .continueSetup:
      controller.downloads.openDialog(for: item.id)
    case .requestDownload:
      controller.downloads.requestDownload(item)
    }
  }

  // MARK: Steam Community

  func signInToSteam() {
    controller.launch(PanelActionCoordinator.key("steamWebSignIn")) { [controller] in
      try await controller.steamWebSignIn()
    }
  }

  func signOutOfSteam() {
    controller.launch(PanelActionCoordinator.key("steamWebSignOut")) { [controller] in
      try await controller.steamWebSignOut()
    }
  }

  /// **Download the ones not in your library**.
  func downloadSubscribed() {
    controller.launch(PanelActionCoordinator.key("workshopDownloadSubscribed")) { [controller] in
      try await controller.downloadSubscribedWorkshopItems()
    }
  }

  // MARK: Links

  /// **Open on Steam**: the Steam page that lists what is on show.
  func openOnSteam() {
    ExternalLink.open(controller.workshopBrowse.steamURL, using: openURL)
  }

  /// **View on Steam Workshop**: the item's own page.
  func viewOnSteam(_ item: WorkshopItem) {
    if let url = ExternalLink.workshopItem(id: item.id) { ExternalLink.open(url, using: openURL) }
  }

  // MARK: Leaving and coming back

  /// The page appeared: a Workshop that was never loaded starts its first search, whichever way the
  /// page was reached, and the jump field shows the page on show.
  func pageAppeared() {
    syncPageText()
    let workshop = controller.workshop
    if !workshop.hasLoaded && !workshop.isLoading {
      controller.launch(PanelActionCoordinator.key("navigate"), policy: .latestWins) {
        [controller] in
        try await controller.navigate(.workshop)
      }
    }
  }

  /// The page went away: every animation is released and the grid's place is stored.
  func pageDisappeared() {
    previews.releaseAll()
    flushScrollReport()
  }

  // MARK: Remembering where the grid was

  /// The offset the last window left, taken once when the first page of tiles has arrived.
  func takeRestoredScroll() -> Double? {
    guard !restoredScroll else { return nil }
    restoredScroll = true
    return controller.restoredViewState?.scroll["discover"]
  }

  /// The grid scrolled. The place is stored at most every 400 ms, so a flick is not written a
  /// hundred times, and once more when the page goes away.
  func scrolled(to offset: Double) {
    guard offset.isFinite, offset >= 0 else { return }
    lastScrollOffset = offset
    guard scrollReport == nil else { return }
    scrollReport = Task { @MainActor [weak self, sleep] in
      do { try await sleep(.milliseconds(400)) } catch { return }
      guard let self else { return }
      self.scrollReport = nil
      self.flushScrollReport()
    }
  }

  func flushScrollReport() {
    scrollReport?.cancel()
    scrollReport = nil
    guard let offset = lastScrollOffset else { return }
    lastScrollOffset = nil
    // Installed's filters and the other pages' offsets are kept: only this page's offset changes.
    var state = controller.navigation.viewState ?? PanelViewState()
    state.scroll["discover"] = offset
    controller.storeViewState(state)
  }
}
