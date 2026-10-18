import Foundation

/// The one line above the pixiv grid: what the listing is and how many works the filters hide.
struct PixivListSummary: Equatable {
  let text: String

  /// "Loading pixiv…" while a page loads, the bare name before the first one has arrived, then
  /// "42 results" for a tag search or "Daily ranking · top 500" for a ranking, with how many works
  /// of the page the filters hide.
  @MainActor
  static func make(_ browse: PixivBrowseState) -> PixivListSummary {
    if browse.isLoading { return PixivListSummary(text: L("Loading pixiv…")) }
    guard browse.hasLoaded else { return PixivListSummary(text: "pixiv") }
    let listing =
      browse.isSearching
      ? L("\(browse.totalCount) results")
      : L("\(browse.query.ranking.title) · top \(browse.totalCount)")
    let hidden = browse.hiddenCount
    guard hidden > 0 else { return PixivListSummary(text: listing) }
    let note =
      hidden == 1
      ? L("1 hidden by your filters on this page")
      : L("\(hidden) hidden by your filters on this page")
    return PixivListSummary(text: "\(listing) · \(note)")
  }
}

/// What the page shows in place of the grid while there are no works to show. The first rule that
/// applies wins: loading, then an error, then filters that hide the whole page, then nothing found.
enum PixivEmptyState: Equatable {
  case loading
  case error(String)
  /// pixiv returned works, and the age rating, orientation or size filters hide every one.
  /// `canGoNext` is whether a later page could still show some.
  case filtersHideAll(hidden: Int, canGoNext: Bool)
  case nothing(searching: Bool)

  /// Nil while there are works on show. A page that has not loaded, is not loading and has no
  /// error is loading: the first visit asks for its list a moment after the page appears.
  static func make(_ browse: PixivBrowseState) -> PixivEmptyState? {
    guard browse.works.isEmpty else { return nil }
    if browse.isLoading || (!browse.hasLoaded && browse.errorMessage == nil) { return .loading }
    if let message = browse.errorMessage { return .error(message) }
    if browse.hiddenCount > 0 {
      return .filtersHideAll(
        hidden: browse.hiddenCount, canGoNext: browse.pager.page < browse.pager.totalPages)
    }
    return .nothing(searching: browse.isSearching)
  }
}
