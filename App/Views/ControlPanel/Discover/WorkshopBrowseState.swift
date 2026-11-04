import Foundation

/// The four lists Discover's tabs open. An author or a collection is opened from a tile, so the
/// type that says which list to open cannot name one.
enum WorkshopList: CaseIterable, Equatable {
  case browse, collections, subscriptions, favorites

  var source: WorkshopSource {
    switch self {
    case .browse: .browse
    case .collections: .collections
    case .subscriptions: .subscriptions
    case .favorites: .favorites
    }
  }
}

/// Where Discover's tiles come from, as the page shows it.
struct WorkshopSourceState: Equatable {
  let source: WorkshopSource
  /// Steam's own name for the source once its first page arrived, else the name it was opened with.
  let name: String?
  /// An author or a collection was opened from a tile, so Back returns to the list before it.
  let canGoBack: Bool

  /// The tab that is current; nil while an author or a collection is open and no tab is.
  var list: WorkshopList? {
    switch source {
    case .browse: .browse
    case .collections: .collections
    case .subscriptions: .subscriptions
    case .favorites: .favorites
    case .collection, .creator: nil
    }
  }

  /// Steam searches and sorts only the wallpapers and collections lists; the others show their
  /// own order, so the search field and the sort menu are hidden.
  var isSearchable: Bool { source.isSearchable }
}

/// The Steam Workshop page's list-level state: the tiles, where they come from, how far paging has
/// gone and what the last load said.
///
/// Per-tile state (the download ring, the installed check) and per-item download state are asked
/// for one tile at a time, so a progress tick does not re-render the grid.
struct WorkshopBrowseState: Equatable {
  /// A page is one Steam page: 30 tiles, whatever the window's width, and never more than 1,000
  /// pages. The grid lays them out in as many columns as fit and scrolls the rest.
  static let pageSize = WorkshopStore.pageSize
  static let maxPages = WorkshopStore.maxPages

  let items: [WorkshopItem]
  let selectedID: String?
  let source: WorkshopSourceState
  let pager: ResultPager
  /// What Steam counted for the query, and how much of it its 1,000 pages can serve.
  let totalCount: Int
  let reachableCount: Int
  let isLoading: Bool
  /// A page has arrived for the query on show; before that the page is not empty, it is loading.
  let hasLoaded: Bool
  /// Why the last load failed. It shows in the empty state or the pager, not in the error banner.
  let errorMessage: String?
  /// The grid shows the one item a pasted link or id named, to which no filter applies.
  let isLookup: Bool
  /// The list was found from the links of a Steam page whose markup changed: it may be incomplete
  /// and its page count is an estimate.
  let isDegraded: Bool
  /// The Steam page that lists what is on show, for **Open on Steam**.
  let steamURL: URL
  /// A Steam Community session is held, which Your subscriptions needs.
  let isSignedInToSteam: Bool
  let isSigningInToSteam: Bool
  /// What the last search was sent with, which the page's draft is seeded from and which a reopened
  /// panel shows again.
  let lastSearch: Search

  struct Search: Equatable {
    let text: String
    let sort: WorkshopSort
    let tags: [String]
    let excludedTags: [String]
  }

  @MainActor
  init(_ workshop: WorkshopStore) {
    items = workshop.items
    selectedID = workshop.selectedItem?.id
    let shown = workshop.source
    let named = workshop.committedQuery?.source == shown ? workshop.sourceTitle : nil
    source = WorkshopSourceState(
      source: shown, name: named ?? shown.name, canGoBack: !workshop.sourceHistory.isEmpty)
    pager = ResultPager(
      page: workshop.page, totalPages: workshop.totalPages, isLoading: workshop.isLoading,
      maxPages: WorkshopStore.maxPages)
    totalCount = workshop.totalCount
    reachableCount = workshop.reachableCount
    isLoading = workshop.isLoading
    hasLoaded = workshop.hasLoaded
    errorMessage = workshop.errorMessage
    isLookup = workshop.committedQuery?.itemID != nil
    isDegraded = workshop.isDegraded
    steamURL = workshop.browseURL
    isSignedInToSteam = workshop.steamWebSession != nil
    isSigningInToSteam = workshop.isSigningInToSteamWeb
    lastSearch = Search(
      text: workshop.searchText, sort: workshop.sort, tags: workshop.tags,
      excludedTags: workshop.excludedTags)
  }
}
