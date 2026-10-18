import AppKit
import Observation

/// The groups of the Filters sidebar, which can each be folded.
enum PixivFilterGroup: CaseIterable, Hashable {
  case account, orientation, minimumSize, ageRating, ai
}

/// The pixiv page: the query being edited, the rules that turn edits into searches, the paging bar
/// and the popover's state.
///
/// The page edits a **draft** query that starts as the store's and is committed whole with every
/// change, so ticking a filter right after typing commits the typed text too. Typing waits 450 ms
/// for a pause; Return and Refresh ask for the first page afresh; a filter, the menu and Clear
/// commit at once. What the account does not allow is dropped from what is shown and committed
/// (signed out, nothing R-18), and from the draft itself when the sign-in changes, so signing in
/// again does not bring a ticked Mature box back on its own.
///
/// The grid's scroll offset is kept for the next window (`PanelViewState.scroll["pixiv"]`): stored
/// at most every 400 ms while it moves and once more when the page goes, and handed back once.
///
/// The model reads and acts through `controller`, which owns every store.
@MainActor
@Observable
final class PixivBrowserModel {
  unowned let controller: PanelController

  /// How long typing waits before the search is sent.
  nonisolated static let searchDelay: Duration = .milliseconds(450)
  /// The longest search text the store accepts.
  nonisolated static let textLimit = 256

  /// What the page edits. Read `query` for what is shown and sent.
  private(set) var draft: PixivQuery
  /// The folded groups of the Filters sidebar: kept while the page lives, all open at first.
  var collapsedGroups: Set<PixivFilterGroup> = []

  /// Test seam: the clock of the search debounce and of the scroll report.
  @ObservationIgnored var sleep: @Sendable (Duration) async throws -> Void = {
    try await Task.sleep(for: $0)
  }
  @ObservationIgnored private var debounce: Task<Void, Never>?
  /// Where the grid was last seen, in points from its top.
  @ObservationIgnored private(set) var scrollOffset: Double = 0
  @ObservationIgnored private var scrollReport: Task<Void, Never>?
  @ObservationIgnored private var hasUnreportedScroll = false
  /// The grid's offset was handed back from the last window, once.
  @ObservationIgnored private var restoredScroll = false
  /// The ring that last acted, and when: what tells the second click of a double-click on a ring
  /// from a press of its own.
  @ObservationIgnored private var lastRingPress: (jobID: String, at: ContinuousClock.Instant)?
  /// Test seam: the clock that times presses of a ring.
  @ObservationIgnored var now: () -> ContinuousClock.Instant = { .now }
  /// Two presses of one ring closer than this are a double-click: the system's interval.
  @ObservationIgnored var doubleClickInterval: Duration = .seconds(NSEvent.doubleClickInterval)

  init(controller: PanelController) {
    self.controller = controller
    draft = controller.pixiv.query
  }

  // MARK: Reading

  /// Whether a pixiv session is held, which unlocks the Mature box and the R-18 rankings.
  var isSignedIn: Bool { controller.pixiv.isSignedIn }

  /// The draft as the account allows it: what the controls show and what is sent.
  var query: PixivQuery { draft.sanitized(signedIn: isSignedIn) }

  /// The draft counts as a search once its text has a visible character, which is when the menu
  /// swaps rankings for search orders.
  var isSearching: Bool { query.isSearchDraft }

  /// The rankings the menu offers while the box is empty.
  var rankingChoices: [PixivRanking] {
    let query = query
    return PixivRanking.offered(signedIn: isSignedIn, ratings: query.ratings)
  }

  /// How many filters differ from a fresh page: the badge of the Filter button.
  var filterCount: Int { query.activeFilterCount }

  func count(in group: PixivFilterGroup) -> Int {
    let query = query
    switch group {
    case .account: return 0
    case .orientation: return query.orientationFilterCount
    case .minimumSize: return query.minimumSizeFilterCount
    case .ageRating: return query.ratingFilterCount
    case .ai: return query.aiFilterCount
    }
  }

  func isExpanded(_ group: PixivFilterGroup) -> Bool { !collapsedGroups.contains(group) }

  func setExpanded(_ group: PixivFilterGroup, _ expanded: Bool) {
    if expanded { collapsedGroups.remove(group) } else { collapsedGroups.insert(group) }
  }

  // MARK: Editing

  /// The search field's text, cut to the length pixiv takes. The search follows after a pause.
  func setText(_ text: String) {
    draft.text = String(text.prefix(Self.textLimit))
    debounce?.cancel()
    let sleep = self.sleep
    debounce = Task { [weak self] in
      do { try await sleep(Self.searchDelay) } catch { return }
      guard !Task.isCancelled, let self else { return }
      self.debounce = nil
      self.commit()
    }
  }

  /// Return or the Search button: the first page of the listing, asked for afresh.
  @discardableResult
  func submit() -> Task<Void, Never> { commit(refresh: true) }

  /// The Refresh button.
  @discardableResult
  func refresh() -> Task<Void, Never> { commit(refresh: true) }

  /// The menu's choice while the box is empty.
  @discardableResult
  func choose(ranking: PixivRanking) -> Task<Void, Never> {
    draft.ranking = ranking
    return commit()
  }

  /// The menu's choice while the box has text.
  @discardableResult
  func choose(order: PixivSearchOrder) -> Task<Void, Never> {
    draft.order = order
    return commit()
  }

  @discardableResult
  func choose(orientation: PixivOrientation) -> Task<Void, Never> {
    draft.orientation = orientation
    return commit()
  }

  @discardableResult
  func choose(minimumSize: PixivMinimumSize) -> Task<Void, Never> {
    draft.minimumSize = minimumSize
    return commit()
  }

  /// Ticks or unticks an age rating. Every box can be unticked; Mature needs a sign-in.
  @discardableResult
  func set(_ rating: PixivRating, isOn: Bool) -> Task<Void, Never> {
    var ratings = query.ratings
    if isOn { ratings.insert(rating) } else { ratings.remove(rating) }
    draft.ratings = ratings
    return commit()
  }

  @discardableResult
  func set(hidesAIGenerated: Bool) -> Task<Void, Never> {
    draft.hidesAIGenerated = hidesAIGenerated
    return commit()
  }

  /// Clear: orientation, size, AI and the ratings go back to their defaults; the text, the ranking
  /// and the search order stay.
  @discardableResult
  func clearFilters() -> Task<Void, Never> {
    draft = query.clearingFilters()
    return commit()
  }

  /// Clear search: back to the ranking.
  @discardableResult
  func clearSearch() -> Task<Void, Never> {
    draft.text = ""
    return commit()
  }

  /// Takes what the account no longer allows out of the draft itself. The page calls it whenever
  /// the sign-in changes, and when it appears.
  func reconcileAccount() {
    let allowed = query
    if draft != allowed { draft = allowed }
  }

  /// Commits the draft, whole, and drops a pause that was waiting to. The newest query lands last.
  @discardableResult
  func commit(refresh: Bool = false) -> Task<Void, Never> {
    debounce?.cancel()
    debounce = nil
    draft = query
    let query = draft
    let controller = controller
    return controller.launch("pixivSearch", policy: .latestWins) {
      try await controller.pixivSearch(query, refresh: refresh)
    }
  }

  /// The first visit's load, for a page that appears before anything asked for its list. The
  /// shell's navigation does the same; this one never repeats a load that is under way or failed.
  @discardableResult
  func loadIfNeeded() -> Task<Void, Never>? {
    let pixiv = controller.pixiv
    guard !pixiv.hasLoaded, !pixiv.isLoading, pixiv.errorMessage == nil,
      !controller.isBusy("pixivSearch")
    else { return nil }
    return commit()
  }

  // MARK: Paging

  /// Shows a page of the listing; the grid starts at its top.
  @discardableResult
  func showPage(_ page: Int) -> Task<Void, Never> {
    let controller = controller
    let page = controller.pixivBrowse.pager.clamped(page)
    return controller.launch("pixivPage", policy: .dropDuplicates) {
      try await controller.pixivLoadPage(page)
    }
  }

  /// The number typed in the page field: rounded and held to the pages there are, the first page
  /// for anything that is not a number. Asks for the page unless it is the one on show or a page
  /// is loading. Returns the number the field should say.
  @discardableResult
  func jump(typed text: String) -> Int {
    let pager = controller.pixivBrowse.pager
    if let target = pager.jumpTarget(typed: text) { showPage(target) }
    return Self.shownNumber(typed: text, in: pager)
  }

  /// What a typed page number comes to once rounded and held to the pager's pages.
  static func shownNumber(typed text: String, in pager: ResultPager) -> Int {
    let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines))
    let rounded = (value ?? 0).rounded(.toNearestOrAwayFromZero)
    let number = rounded.isNaN || rounded == 0 ? 1 : rounded
    return Int(min(Double(pager.pages), max(1, number)))
  }

  // MARK: Remembering where the grid was

  /// The offset the last window left, taken once by the first grid this window shows.
  func takeRestoredScroll() -> Double? {
    guard !restoredScroll else { return nil }
    restoredScroll = true
    return controller.restoredViewState?.scroll["pixiv"]
  }

  /// The grid scrolled. The place is stored at most every 400 ms, so a flick is one write, not
  /// one for each frame; an offset that is not a place is ignored.
  func scrolled(to offset: Double) {
    guard offset.isFinite, offset >= 0, offset != scrollOffset else { return }
    scrollOffset = offset
    hasUnreportedScroll = true
    guard scrollReport == nil else { return }
    scrollReport = Task { @MainActor [weak self, sleep] in
      do { try await sleep(.milliseconds(400)) } catch { return }
      guard let self else { return }
      self.scrollReport = nil
      self.flushScrollReport()
    }
  }

  /// Stores the grid's place now, if it moved since it was last stored. Installed's filters and
  /// the other pages' offsets are kept: only this page's offset changes.
  func flushScrollReport() {
    scrollReport?.cancel()
    scrollReport = nil
    guard hasUnreportedScroll else { return }
    hasUnreportedScroll = false
    var state = controller.navigation.viewState ?? PanelViewState()
    state.scroll["pixiv"] = scrollOffset.rounded()
    controller.storeViewState(state)
  }

  // MARK: Works

  /// A click on a tile's ring: cancel, resume or retry the save it names, unless it is the second
  /// click of a double-click on the same ring. The first click already acted, and the ring it left
  /// may offer the opposite (a cancelled save offers to try again), so a second press would undo
  /// it. A key press or VoiceOver press comes one at a time and is never that close.
  @discardableResult
  func pressRing(_ ring: PixivTile.Ring) -> Task<Void, Never>? {
    let instant = now()
    if let last = lastRingPress, last.jobID == ring.jobID, instant - last.at < doubleClickInterval {
      return nil
    }
    lastRingPress = (ring.jobID, instant)
    let controller = controller
    return controller.launch(PanelActionCoordinator.key("pixivRing", id: ring.jobID)) {
      try await PixivTileCell.perform(ring, in: controller)
    }
  }

  func select(_ work: PixivWork) {
    let controller = controller
    controller.launch(PanelActionCoordinator.key("pixivSelect", id: work.id)) {
      try await controller.pixivSelect(workID: work.id)
    }
  }

  /// A double-click: saves the page the inspector shows, applies a saved one, waits while it
  /// downloads, and does nothing when no display could show the wallpaper.
  @discardableResult
  func doubleClick(_ work: PixivWork) -> Task<Void, Never>? {
    let controller = controller
    switch controller.pixivDoubleClick(for: work) {
    case .nothing:
      return nil
    case .apply(let libraryID):
      return controller.launch(PanelActionCoordinator.key("activate", id: libraryID)) {
        try await controller.activate(libraryID)
      }
    case .download(let workID, let page):
      return controller.launch(PanelActionCoordinator.key("pixivDownload", id: workID)) {
        try await controller.pixivDownload(workID: workID, page: page)
      }
    }
  }
}
