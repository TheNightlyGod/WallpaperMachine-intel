import CoreGraphics
import Foundation

/// What the Workshop grid says when it has no tiles to show, and what it offers to do about it.
///
/// The branches are checked in this order, as the page always did: a signed-out subscriptions list
/// asks for the sign-in before anything else (it wins over an error), then a page that is loading,
/// then a failed load, and only then the reasons a search can come back empty.
enum WorkshopEmptyState: Equatable {
  /// Your subscriptions, with no Steam session: Steam shows them only to their owner.
  case signInToSeeSubscriptions(isSigningIn: Bool)
  case loading
  /// The load failed; the message is Steam's or the network's own and is never a catalog key.
  case unavailable(String)
  case noResults(Recovery)

  /// Why nothing matched, and the one thing most likely to fix it.
  enum Recovery: Equatable {
    /// Words and filters together can hide everything.
    case clearSearchAndFilters
    case clearSearch
    case clearFilters(count: Int)
    /// A list Steam does not filter itself (subscriptions, an author's or a collection's items,
    /// collections while a rating is hidden) can have its whole page screened away while later
    /// pages hold some. `nextPage` is the page to try, if there is one.
    case screened(isCollections: Bool, nextPage: Int?)
    /// Your subscriptions, signed in, with none.
    case browseWorkshop
    case refresh
  }

  /// - Parameters:
  ///   - browse: The page's list state.
  ///   - draftText: The search field's text, which a list Steam does not search ignores.
  ///   - filterCount: How many filters the Filter button counts.
  static func make(browse: WorkshopBrowseState, draftText: String, filterCount: Int)
    -> WorkshopEmptyState
  {
    make(
      source: browse.source, isSignedIn: browse.isSignedInToSteam,
      isSigningIn: browse.isSigningInToSteam, isLoading: browse.isLoading,
      errorMessage: browse.errorMessage, totalCount: browse.totalCount, page: browse.pager.page,
      totalPages: browse.pager.totalPages, draftText: draftText, filterCount: filterCount)
  }

  static func make(
    source: WorkshopSourceState, isSignedIn: Bool, isSigningIn: Bool, isLoading: Bool,
    errorMessage: String?, totalCount: Int, page: Int, totalPages: Int, draftText: String,
    filterCount: Int
  ) -> WorkshopEmptyState {
    if source.source == .subscriptions, !isSignedIn, !isLoading {
      return .signInToSeeSubscriptions(isSigningIn: isSigningIn)
    }
    if isLoading { return .loading }
    if let errorMessage { return .unavailable(errorMessage) }

    let hasText =
      source.isSearchable && !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    if hasText && filterCount > 0 { return .noResults(.clearSearchAndFilters) }
    if hasText { return .noResults(.clearSearch) }
    if filterCount > 0 { return .noResults(.clearFilters(count: filterCount)) }
    let screened = !source.isSearchable || source.source == .collections
    if screened && totalCount > 0 {
      return .noResults(
        .screened(
          isCollections: source.source == .collections, nextPage: page < totalPages ? page + 1 : nil
        ))
    }
    if source.source == .subscriptions { return .noResults(.browseWorkshop) }
    return .noResults(.refresh)
  }
}

/// The line the Workshop page keeps beside its pager: what is on show, or what is happening.
enum WorkshopSummary: Equatable {
  case searching
  /// Your subscriptions, signed in. `count` is nil until the list has loaded.
  case subscriptions(count: Int?)
  /// A pasted link or id named one item, to which no filter applies.
  case lookup
  /// The list came from the links of a Steam page whose markup changed.
  case degraded
  case results(Int)
  /// Nothing has loaded yet.
  case idle

  static func make(browse: WorkshopBrowseState) -> WorkshopSummary {
    make(
      source: browse.source.source, isLoading: browse.isLoading,
      isSignedIn: browse.isSignedInToSteam, hasLoaded: browse.hasLoaded,
      totalCount: browse.totalCount, isLookup: browse.isLookup, isDegraded: browse.isDegraded)
  }

  static func make(
    source: WorkshopSource, isLoading: Bool, isSignedIn: Bool, hasLoaded: Bool, totalCount: Int,
    isLookup: Bool, isDegraded: Bool
  ) -> WorkshopSummary {
    if isLoading { return .searching }
    if source == .subscriptions, isSignedIn {
      return .subscriptions(count: hasLoaded ? totalCount : nil)
    }
    guard hasLoaded else { return .idle }
    if isLookup { return .lookup }
    if isDegraded { return .degraded }
    return .results(totalCount)
  }
}

/// How the page's header and footer use the width the page column has. The inspector takes 260
/// points or more from a 760-point window, so neither ever asks for more room than it is given. The
/// header is one row in every shape; its tabs become a menu by themselves where they do not fit.
enum WorkshopHeaderDensity: Equatable {
  /// Filter and the sort menu say what they are in words.
  case wide
  /// They are icons, which leaves the tabs room beside them.
  case regular
  /// Icons too, and the footer stacks its summary over the pager.
  case compact

  static func make(width: CGFloat) -> WorkshopHeaderDensity {
    guard width.isFinite else { return .wide }
    if width >= 680 { return .wide }
    return width >= 400 ? .regular : .compact
  }
}

extension WorkshopSourceState {
  /// What is on show, by name: the list, or the author's or the collection's wallpapers that were
  /// opened from a tile (Steam's own name for them once their first page arrived).
  @MainActor
  var heading: String {
    if let list { return list.panelTitle }
    switch source {
    case .creator:
      return name.map { L("Wallpapers by \($0)") } ?? L("This author’s wallpapers")
    default:
      return name.map { L("Collection: \($0)") } ?? L("Collection")
    }
  }

  /// The window's subtitle on the Workshop page: what is on show, then how many it holds once that
  /// is known. A search on its way, a link's one item and a list read off a changed Steam page add
  /// no count, so the line keeps its place and does not flicker between searches.
  @MainActor
  func titleSubtitle(summary: WorkshopSummary) -> String {
    let count: String? =
      switch summary {
      case .results(let total): L("\(total) results")
      case .subscriptions(let total): total.map { L("\($0) subscribed") }
      case .searching, .lookup, .degraded, .idle: nil
      }
    return ([heading] + (count.map { [$0] } ?? [])).joined(separator: " · ")
  }
}

/// What the strip under the grid holds. An empty grid's state stands alone: it says what happened
/// and offers the way on, so the strip neither repeats it ("0 results", a bare "Steam Workshop") nor
/// keeps a pager with nowhere to go. It keeps the pager only while there are other pages to try, as
/// after a page whose every wallpaper the filters screened away.
struct WorkshopFooterContent: Equatable {
  /// The summary line (or a failed page's message with Retry) and Open on Steam.
  let showsSummary: Bool
  let showsPager: Bool

  /// Nothing to show: the page draws no strip, and no divider above it.
  var isEmpty: Bool { !showsSummary && !showsPager }

  static func make(browse: WorkshopBrowseState) -> WorkshopFooterContent {
    make(hasItems: !browse.items.isEmpty, pages: browse.pager.pages)
  }

  static func make(hasItems: Bool, pages: Int) -> WorkshopFooterContent {
    WorkshopFooterContent(showsSummary: hasItems, showsPager: hasItems || pages > 1)
  }
}

extension WorkshopSort {
  /// The sort's name in the panel's language. `title` follows the launch language; this follows
  /// the live one.
  @MainActor
  var panelTitle: String {
    switch self {
    case .topRated: L("Highest rated")
    case .trendingToday: L("Most popular today")
    case .trending: L("Trending this week")
    case .trendingMonth: L("Most popular this month")
    case .trendingYear: L("Most popular this year")
    case .popular: L("Most subscribed")
    case .newest: L("Newest")
    case .updated: L("Recently updated")
    case .relevance: L("Relevance")
    }
  }
}

extension WorkshopList {
  /// The tab's name in the panel's language.
  @MainActor
  var panelTitle: String {
    switch self {
    case .browse: L("Wallpapers")
    case .collections: L("Collections")
    case .subscriptions: L("Your subscriptions")
    }
  }

  var systemImage: String {
    switch self {
    case .browse: "photo.on.rectangle"
    case .collections: "square.stack"
    case .subscriptions: "bookmark"
    }
  }
}

extension ResultPager {
  /// The page a number typed into the jump field names: rounded, brought into the pages the bar
  /// offers, and the first page for text that is not a number. The field is rewritten with it
  /// whether or not a request follows.
  func clampedPage(typed text: String) -> Int {
    let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines))
    let rounded = (value ?? 0).rounded(.toNearestOrAwayFromZero)
    // Clamp as a Double: an absurdly large number must not trap in the conversion.
    let number = rounded.isNaN || rounded == 0 ? 1 : rounded
    return Int(min(Double(pages), max(1, number)))
  }
}
