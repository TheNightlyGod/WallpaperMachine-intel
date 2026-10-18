import AppKit
import Foundation
import Observation
import SwiftUI

/// The Installed page: what is searched, filtered and sorted, what is selected, and the rows the
/// grid shows.
///
/// The model reads and acts through `controller`, which owns every store. It is the state the page
/// keeps for itself: the search text, the tag filters and the sort, the multi-selection with its
/// press-and-sweep gesture, the one animated tile, the Import popover, and the import pill.
/// Filters and sort are reported to `controller.storeViewState(_:)` as they change
/// so a reopened window comes back to them, and restored once when the model is made.
///
/// The model lives as long as the window, not as long as the page: leaving for another page and
/// coming back finds the selection, the filters and the scroll position as they were.
@MainActor
@Observable
final class InstalledBrowserModel {
  unowned let controller: PanelController

  // MARK: Filter and sort

  /// The search text, tag filters and collection on show.
  private(set) var filter = LibraryFilter()
  private(set) var sort = LibrarySort.title
  /// Whether the sort runs against its natural direction.
  private(set) var descending = false
  /// How far the grid is scrolled, as last reported by the page. Not observed: it changes with
  /// every notch of the wheel, and the page only reads it when it appears.
  @ObservationIgnored private(set) var scrollOffset: CGFloat = 0
  /// Counts the times the grid must scroll to its top: a library view was chosen.
  private(set) var scrollToTopCount = 0
  /// Which Filters groups are open, by key. The person's choice, kept while the window lives.
  var openFilterGroups: Set<String> = ["collections", "show-only", "type", "rating", "genre"]

  // MARK: Selection
  //
  // The state of the selection, the sweep, the notice and the animated preview is changed only by
  // the methods of the extensions in this folder; the setters are open to them.

  /// What is ticked for a batch action. It outlives the view, search and filters (see
  /// `LibrarySelection`), and is dropped only for wallpapers that left the library.
  var selection = LibrarySelection()
  /// Selection mode: every tile shows its check, and a click ticks instead of choosing.
  var isSelecting = false
  /// The press-and-sweep gesture in progress, if any. Views never read it: it changes with every
  /// move of the pointer. They read `armingID`, which changes only when the hold does.
  var sweep: SweepSelection?
  /// The tile whose hold is in progress, which draws itself pressed in.
  var armingID: String?
  /// The name being typed for a new collection made from the selection; nil when not asked for.
  var newCollectionName: String?
  /// The last batch result, shown beside the selection's tools for five seconds.
  var notice: String?
  /// How a sentence reaches VoiceOver. A seam: tests record it.
  @ObservationIgnored var announce: @MainActor (String) -> Void = {
    AccessibilityNotification.Announcement($0).post()
  }
  @ObservationIgnored private var summaryTask: Task<Void, Never>?

  // MARK: Animated preview

  /// The one tile that is playing its animation, with the animation.
  struct LivePreview: Equatable {
    let id: String
    let data: Data
  }
  var livePreview: LivePreview?

  // MARK: Import

  /// The Import popover is open, and where it is hanging from.
  enum ImportAnchor: Equatable { case page, pill }
  private(set) var importAnchor: ImportAnchor?
  /// What the Import popover does with a wallpaper the library already holds. Page memory only: a
  /// new window starts at Skip, which keeps what the library has.
  var importDuplicates = WallpaperImportService.DuplicatePolicy.skip
  /// The toolbar pill's memory of a finished import, kept up to date by the model whether or not
  /// the page is on show.
  private(set) var importPill = ImportPill()

  // MARK: Plumbing the views and tests share

  /// Where each tile is, for the sweep. Only the gesture reads it.
  @ObservationIgnored var geometry = LibraryGridGeometry()
  /// The tile that holds keyboard focus, which Delete acts on when nothing is ticked.
  @ObservationIgnored var focusedID: String?
  /// How the page scrolls its grid, set while the page is on show. Offsets are in points from the
  /// top of the content.
  @ObservationIgnored var scrollGrid: (@MainActor (CGFloat) -> Void)?
  /// The last click on a tile, from which the next one knows whether it is the second of a double
  /// click.
  @ObservationIgnored var lastClick: (id: String, time: Date)?
  /// The time, and how long two clicks may be apart and still be a double click. Tests replace
  /// both.
  @ObservationIgnored var clock: () -> Date = { Date() }
  @ObservationIgnored var doubleClickInterval: () -> TimeInterval = { NSEvent.doubleClickInterval }
  /// Waits for a duration. Tests replace it with a clock that moves by hand.
  /// Whether a mouse button is held, which makes a pointer entering a tile part of a drag rather than
  /// a rest. A seam: tests answer it, so a button the developer holds cannot change their outcome.
  @ObservationIgnored var isMouseButtonDown: @MainActor () -> Bool = { NSEvent.pressedMouseButtons != 0 }
  @ObservationIgnored var sleep: @Sendable (Duration) async throws -> Void = {
    try await Task.sleep(for: $0)
  }

  @ObservationIgnored fileprivate var sortedCache: (key: SortedKey, rows: [LibraryRow])?
  @ObservationIgnored fileprivate var visibleCache: (key: VisibleKey, result: Visible)?
  @ObservationIgnored var liveTarget = LivePreviewTarget()
  @ObservationIgnored var liveCandidate: String?
  @ObservationIgnored var liveTask: Task<Void, Never>?
  @ObservationIgnored var holdTask: Task<Void, Never>?
  @ObservationIgnored var autoscrollTask: Task<Void, Never>?
  /// The primary button is down on the grid, from the first event of the drag gesture to its end.
  @ObservationIgnored var isPointerDown = false
  /// A press that did its work as a sweep: the click that ends it must change nothing.
  @ObservationIgnored var swallowsClick = false
  @ObservationIgnored var swallowReset: Task<Void, Never>?
  @ObservationIgnored var noticeTask: Task<Void, Never>?
  @ObservationIgnored private var reportTask: Task<Void, Never>?
  @ObservationIgnored private var hasUnreportedChange = false
  @ObservationIgnored private var importLoop: ObservationLoop?
  /// The required tags that came back from the last window and are checked against the library
  /// once it has loaded.
  @ObservationIgnored private var restoredTags: Set<String> = []

  init(controller: PanelController) {
    self.controller = controller
    restore(controller.restoredViewState)
    importPill.observe(controller.importState, popoverOpen: false)
    importLoop = ObservationLoop(
      track: { [weak self] in _ = self?.controller.importState },
      onChange: { [weak self] in self?.importStateChanged() })
    importLoop?.start()
  }

  // MARK: Cross-area contract (the view chips and the Collections group read and set the scope)

  /// The part of the library on show, which the view chips light: a collection, else Favorites
  /// (the Favorite filter), else everything.
  var scope: LibraryScope {
    if let collection = shownCollection { return .collection(collection.id) }
    return filter.requiredTags.contains(LibraryFilterCatalog.favoriteTag) ? .favorites : .all
  }

  /// Shows a part of the library, as the All wallpapers and Favorites chips and the filters
  /// panel's collection rows do. Favorites and a collection are filters of Installed, not pages of their own, so the
  /// search, sort and the other tags stay as they are, and the grid goes back to its top: a grid
  /// on screen scrolls there (`scrollToTopCount`), and one made afterwards (the view was chosen
  /// from another page, or from an empty state) starts there, since it restores `scrollOffset`.
  func show(_ scope: LibraryScope) {
    switch scope {
    case .collection(let id):
      guard controller.collectionRows.contains(where: { $0.id == id }) else { return }
      filter.collectionID = id
      filter.requiredTags.removeAll { $0 == LibraryFilterCatalog.favoriteTag }
    case .favorites:
      filter.collectionID = nil
      if !filter.requiredTags.contains(LibraryFilterCatalog.favoriteTag) {
        filter.requiredTags.append(LibraryFilterCatalog.favoriteTag)
      }
    case .all:
      filter.collectionID = nil
      filter.requiredTags.removeAll { $0 == LibraryFilterCatalog.favoriteTag }
    }
    scrollOffset = 0
    scrollToTopCount += 1
    filtersChanged(immediately: true)
  }

  /// The collection on show, nil when none is chosen or the chosen one was deleted: the grid goes
  /// back to every wallpaper by itself.
  var shownCollection: CollectionRow? {
    guard let id = filter.collectionID else { return nil }
    return controller.collectionRows.first { $0.id == id }
  }

  /// The name the window's title shows beside the Favorites view.
  var showsFavorites: Bool {
    shownCollection == nil && filter.requiredTags.contains(LibraryFilterCatalog.favoriteTag)
  }

  // MARK: Filter and sort changes

  /// The filter as it applies now: the collection counts only while it exists.
  var effectiveFilter: LibraryFilter {
    var effective = filter
    if filter.collectionID != nil, shownCollection == nil { effective.collectionID = nil }
    return effective
  }

  /// How many filters are in effect, for the Filter button's badge.
  var filterCount: Int { effectiveFilter.activeCount }

  /// Whether a search or a filter narrows the view the chips light, so the grid can show fewer
  /// wallpapers than the window's subtitle counts. Favorites and a collection are that view, not a
  /// narrowing of it.
  var narrowsView: Bool {
    var narrowing = effectiveFilter
    narrowing.collectionID = nil
    if scope == .favorites {
      narrowing.requiredTags.removeAll { $0 == LibraryFilterCatalog.favoriteTag }
    }
    return !narrowing.text.isEmpty || narrowing.hasFilters
  }

  /// What VoiceOver reads after the Filter button's name: how many filters apply, and whether the
  /// Filters sidebar is open, which the web panel's button said with `aria-expanded`. Two separate
  /// facts, so a list of them.
  var filterButtonValue: String {
    let count = filterCount
    var parts: [String] = []
    if count > 0 { parts.append(L("\(count) active")) }
    parts.append(controller.shell.areFiltersShown ? L("Expanded") : L("Collapsed"))
    return parts.joined(separator: ", ")
  }

  func setText(_ text: String) {
    guard text != filter.text else { return }
    filter.text = text
    filtersChanged(immediately: false)
  }

  /// Chooses a sort key, which also puts the list in that key's natural direction.
  func setSort(_ sort: LibrarySort) {
    self.sort = sort
    descending = sort.startsDescending
    filtersChanged(immediately: true)
  }

  func toggleSortDirection() { setDescending(!descending) }

  /// Puts the list against its sort's natural direction, or back with it.
  func setDescending(_ isDescending: Bool) {
    guard isDescending != descending else { return }
    descending = isDescending
    filtersChanged(immediately: true)
  }

  /// Ticks or unticks a "Show only" box.
  func setRequired(_ tag: String, _ isOn: Bool) {
    if isOn {
      if !filter.requiredTags.contains(tag) { filter.requiredTags.append(tag) }
    } else {
      filter.requiredTags.removeAll { $0 == tag }
    }
    filtersChanged(immediately: true)
  }

  /// How the chip of `tag` stands: selected (required), hidden (excluded) or neither.
  func chipSelection(_ tag: String) -> TagChip.Selection {
    if filter.requiredTags.contains(tag) { return .required }
    return filter.excludedTags.contains(tag) ? .excluded : .plain
  }

  /// Selects, hides or lets go of a chip; a tag is never both required and excluded.
  func setChip(_ tag: String, _ selection: TagChip.Selection) {
    filter.requiredTags.removeAll { $0 == tag }
    filter.excludedTags.removeAll { $0 == tag }
    switch selection {
    case .plain: break
    case .required: filter.requiredTags.append(tag)
    case .excluded: filter.excludedTags.append(tag)
    }
    filtersChanged(immediately: true)
  }

  /// Reset of a chip section: no chip of it selected or hidden.
  func resetChips(in section: LibraryFilterCatalog.Section) {
    let tags = Set(section.tags)
    filter.requiredTags.removeAll { tags.contains($0) }
    filter.excludedTags.removeAll { tags.contains($0) }
    filtersChanged(immediately: true)
  }

  func chipsAreAtDefaults(in section: LibraryFilterCatalog.Section) -> Bool {
    section.tags.allSatisfy { chipSelection($0) == .plain }
  }

  /// Ticks or unticks an exclusion box: unticked tags are the ones no shown wallpaper may carry.
  func setIncluded(_ tag: String, _ isIncluded: Bool) {
    if isIncluded {
      filter.excludedTags.removeAll { $0 == tag }
    } else if !filter.excludedTags.contains(tag) {
      filter.excludedTags.append(tag)
    }
    filtersChanged(immediately: true)
  }

  func isIncluded(_ tag: String) -> Bool { !filter.excludedTags.contains(tag) }

  /// All and None of a section: ticks every box of it, or unticks them all.
  func setSection(_ key: String, included: Bool) {
    guard let section = LibraryFilterCatalog.section(key: key) else { return }
    for tag in section.tags {
      if included {
        filter.excludedTags.removeAll { $0 == tag }
      } else if !filter.excludedTags.contains(tag) {
        filter.excludedTags.append(tag)
      }
    }
    filtersChanged(immediately: true)
  }

  /// How many boxes of `section` are ticked.
  func includedCount(in section: LibraryFilterCatalog.Section) -> Int {
    section.tags.filter { !filter.excludedTags.contains($0) }.count
  }

  /// Clear: every tag and the collection go, the search text stays.
  func clearFilters() {
    filter = filter.clearingFilters()
    filtersChanged(immediately: true)
  }

  func clearSearch() {
    guard !filter.text.isEmpty else { return }
    filter.text = ""
    filtersChanged(immediately: true)
  }

  /// Clear search and filters: the text goes first, then everything Clear takes away.
  func clearSearchAndFilters() {
    filter = LibraryFilter()
    filtersChanged(immediately: true)
  }

  /// Shows every wallpaper again, as an empty collection's Show all wallpapers does.
  func showAllWallpapers() {
    guard filter.collectionID != nil else { return }
    filter.collectionID = nil
    filtersChanged(immediately: true)
  }

  private func filtersChanged(immediately: Bool) {
    hasUnreportedChange = true
    if immediately {
      reportViewState()
    } else {
      scheduleReport(after: .milliseconds(400))
    }
  }

  // MARK: Rows

  fileprivate struct SortedKey: Equatable {
    var rows: Int
    var sort: LibrarySort
    var descending: Bool
    var favorites: Set<String>?
    var language: String
  }

  fileprivate struct VisibleKey: Equatable {
    var sorted: SortedKey
    var filter: LibraryFilter
    var favorites: Set<String>?
    var members: [String]?
  }

  fileprivate struct Visible {
    var rows: [LibraryRow]
    var ids: [String]
  }

  /// Every installed wallpaper the filters let through, in the chosen order. Kept until an input
  /// moves: a typed letter filters the sorted library again, and only a new library or sort
  /// sorts it, so a 10,000-wallpaper library is sorted once however long the user types.
  var visibleRows: [LibraryRow] { visible.rows }

  /// The ids of `visibleRows`, in order.
  var visibleIDs: [String] { visible.ids }

  private var visible: Visible {
    let rows = controller.libraryRows
    let favorites = controller.favoriteIDs
    let filter = effectiveFilter
    let usesFavorites =
      filter.requiredTags.contains { $0.lowercased() == "favorite" }
      || filter.excludedTags.contains { $0.lowercased() == "favorite" }
    let sortedKey = SortedKey(
      rows: controller.libraryRowsCache.rebuilds, sort: sort, descending: descending,
      favorites: sort == .favorites ? favorites : nil, language: PanelLocale.shared.tag)
    let members = shownCollection?.wallpaperIDs
    let key = VisibleKey(
      sorted: sortedKey, filter: filter, favorites: usesFavorites ? favorites : nil,
      members: members)
    if let visibleCache, visibleCache.key == key { return visibleCache.result }

    let sorted: [LibraryRow]
    if let sortedCache, sortedCache.key == sortedKey {
      sorted = sortedCache.rows
    } else {
      sorted = sort.sorted(
        rows, descending: descending, favorites: favorites, locale: PanelLocale.shared.locale)
      sortedCache = (sortedKey, sorted)
    }
    let narrowed = filter.apply(
      to: sorted, favorites: favorites, members: members.map(Set.init))
    let result = Visible(rows: narrowed, ids: narrowed.map(\.id))
    visibleCache = (key, result)
    return result
  }

  /// Why the grid is empty, or nil while it has tiles.
  var emptyState: LibraryEmptyState? {
    let rowCount = visibleRows.count
    guard rowCount == 0 else { return nil }
    let collection = shownCollection
    return LibraryEmptyState.make(
      rowCount: rowCount, isLoading: controller.isLibraryLoading,
      libraryIsEmpty: controller.libraryRows.isEmpty,
      collection: collection.map { ($0.name, $0.count) }, filter: effectiveFilter)
  }

  /// The wallpapers that enabled displays other than the target show, for the Other display pill.
  var otherDisplayWallpaperIDs: Set<String> {
    let target = controller.targetDisplayID
    let monitors = controller.store.monitorInformationSnapshot.rows
    var ids = Set<String>()
    for display in controller.store.settingsSnapshot.displays
    where display.displayId != target && display.enabled && display.mode != .mirror {
      if let id = monitors.first(where: { $0.displayId == display.displayId })?.wallpaperId,
        !id.isEmpty
      {
        ids.insert(id)
      }
    }
    return ids
  }

  /// A number that changes whenever the library's rows do, for a view that must react to that.
  var libraryRevision: Int {
    _ = controller.libraryRows
    return controller.libraryRowsCache.rebuilds
  }

  // MARK: Summary

  /// How long the summary must stay the same before VoiceOver hears it.
  static let summaryDelay = Duration.milliseconds(500)

  /// What the bar under the grid says first: that the library is loading, how many wallpapers are
  /// ticked, or how many the grid shows. Nil while the grid stands empty: its empty state says why.
  var summary: String? {
    if controller.isLibraryLoading { return L("Loading your library…") }
    let selected = selectedIDs.count
    if selected > 0 { return L("\(selected) selected") }
    guard emptyState == nil else { return nil }
    let count = visibleRows.count
    return count == 1 ? L("\(count) wallpaper") : L("\(count) wallpapers")
  }

  /// The summary changed, which the page reports. VoiceOver hears the new one once it has held
  /// still for `summaryDelay`, as the web panel's polite live region was read: a sweep across a
  /// row of tiles, or a search being typed, is one announcement rather than one per tile or letter.
  func summaryChanged() {
    summaryTask?.cancel()
    summaryTask = Task { [weak self] in
      guard let sleep = self?.sleep else { return }
      do { try await sleep(Self.summaryDelay) } catch { return }
      guard let self, self.controller.presentation.isVisible, let summary = self.summary else {
        return
      }
      self.announce(summary)
    }
  }

  /// Whether the sweep tip is on offer: until the user has swept across tiles once or said Got
  /// it, and while there is more than one tile to sweep across.
  var showsSweepTip: Bool { !controller.dragSelectLearned && visibleRows.count > 1 }

  // MARK: Restoring and reporting the view

  /// Comes back to what the last window left, once: the text, sort, direction and tags, and the
  /// scroll offset the grid restores itself to.
  private func restore(_ saved: PanelViewState?) {
    guard let saved else { return }
    filter.text = saved.installed.text
    if let sort = LibrarySort(rawValue: saved.installed.sort) { self.sort = sort }
    descending = saved.installed.descending
    filter.requiredTags = Self.unique(saved.installed.tags)
    filter.excludedTags = Self.unique(saved.installed.excludedTags)
    restoredTags = Set(filter.requiredTags)
    scrollOffset = CGFloat(saved.scroll["installed"] ?? 0)
  }

  private static func unique(_ tags: [String]) -> [String] {
    var seen = Set<String>()
    return tags.filter { seen.insert($0).inserted }
  }

  /// Drops the tags restored from the last window that no wallpaper carries any more, which would
  /// leave the grid empty. It waits for a library that has loaded and holds something, and runs
  /// once; excluded tags stay, since they only hide and a wallpaper imported later should stay
  /// hidden.
  func dropStaleRestoredTags() {
    guard !restoredTags.isEmpty, !controller.isLibraryLoading else { return }
    let rows = controller.libraryRows
    guard !rows.isEmpty else { return }
    let stale = Set(
      filter.staleRequiredTags(in: rows, favorites: controller.favoriteIDs)
        .filter { restoredTags.contains($0) })
    restoredTags = []
    guard !stale.isEmpty else { return }
    filter.requiredTags.removeAll { stale.contains($0) }
    filtersChanged(immediately: true)
  }

  /// The grid scrolled. Reported about every 400 ms while it keeps moving.
  func scrolled(to offset: CGFloat) {
    guard offset != scrollOffset else { return }
    scrollOffset = max(0, offset)
    hasUnreportedChange = true
    scheduleReport(after: .milliseconds(400))
  }

  /// Hands the filters and the scroll position to the controller, which keeps them for the next
  /// window. The text is reported empty when it is over the limit, which is more honest than a
  /// cut one.
  func reportViewState() {
    reportTask?.cancel()
    reportTask = nil
    hasUnreportedChange = false
    var state = controller.navigation.viewState ?? PanelViewState()
    state.installed = PanelViewState.Installed(
      text: filter.text.count <= PanelViewState.maxTextLength ? filter.text : "",
      sort: sort.rawValue, descending: descending, tags: filter.requiredTags,
      excludedTags: filter.excludedTags)
    state.scroll["installed"] = Double(max(0, scrollOffset.rounded()))
    controller.storeViewState(state)
  }

  /// Reports when the window hides or the page goes, so nothing waiting is lost.
  func flushViewState() {
    if hasUnreportedChange { reportViewState() }
  }

  /// The earliest deadline wins: a burst of typing or scrolling reports once per delay, with
  /// whatever is current when the delay is up.
  private func scheduleReport(after delay: Duration) {
    guard reportTask == nil else { return }
    reportTask = Task { [weak self] in
      // The model is not held while it waits: it goes when its window's controller does.
      guard let sleep = self?.sleep else { return }
      do { try await sleep(delay) } catch { return }
      guard let self else { return }
      self.reportTask = nil
      if self.hasUnreportedChange { self.reportViewState() }
    }
  }

  // MARK: Leaving

  /// The page goes: its popover closes, nothing plays or sweeps, and what waited to be reported is.
  func leavePage() {
    closeImport()
    windowWentAway()
  }

  /// The window was hidden or lost focus, or the page went: a hold or a sweep ends, the animation
  /// is released, and the filters and scroll position that waited to be reported are.
  func windowWentAway() {
    endSweep()
    releaseLivePreview()
    flushViewState()
    summaryTask?.cancel()
  }

  // MARK: Popover

  func popoversChanged() {
    controller.shell.isPopoverOpen = importAnchor != nil
  }

  // MARK: Import popover and pill

  func openImport(from anchor: ImportAnchor) {
    guard importAnchor != anchor else { return }
    importAnchor = anchor
    importPill.observe(controller.importState, popoverOpen: true)
    popoversChanged()
  }

  /// Closing the popover means whatever it showed has been seen.
  func closeImport() {
    guard importAnchor != nil else { return }
    importAnchor = nil
    importPill.popoverDidClose()
    popoversChanged()
  }

  func toggleImport(from anchor: ImportAnchor) {
    if importAnchor == anchor { closeImport() } else { openImport(from: anchor) }
  }

  private func importStateChanged() {
    importPill.observe(controller.importState, popoverOpen: importAnchor != nil)
  }

  /// The Choose wallpapers button: asks for files in a sheet and starts the import.
  @discardableResult
  func chooseImportFiles() -> Task<Void, Never> {
    let duplicates = importDuplicates
    return controller.launch(PanelActionCoordinator.key("import")) { [controller] in
      try await controller.beginImport(duplicates: duplicates)
    }
  }
}
