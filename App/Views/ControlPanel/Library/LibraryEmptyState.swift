import Foundation

/// Why the Installed grid has nothing to show, and so what to offer. Only meaningful when no row
/// passes; a grid with rows has no empty state.
enum LibraryEmptyState: Equatable {
  /// The first read of the library, or a rescan that left nothing to show yet.
  case loading
  /// Nothing is installed: import something or find it on the Workshop.
  case emptyLibrary
  /// A collection that holds nothing. It is empty, not filtered away.
  case emptyCollection(name: String)
  /// Search text and filters together hide everything.
  case searchAndFilters
  case search(text: String)
  /// `count` filters hide everything, the collection among them.
  case filters(count: Int)

  /// The state for a grid with no rows, or nil when something is shown.
  ///
  /// - Parameters:
  ///   - rowCount: How many rows pass the filter.
  ///   - isLoading: The library is being read.
  ///   - libraryIsEmpty: Nothing is installed at all.
  ///   - collection: The collection on show and how many ids it holds, stale ones included.
  static func make(
    rowCount: Int, isLoading: Bool, libraryIsEmpty: Bool,
    collection: (name: String, memberCount: Int)?, filter: LibraryFilter
  ) -> LibraryEmptyState? {
    guard rowCount == 0 else { return nil }
    if isLoading { return .loading }
    if libraryIsEmpty { return .emptyLibrary }
    if let collection, collection.memberCount == 0 {
      return .emptyCollection(name: collection.name)
    }
    if !filter.text.isEmpty && filter.hasFilters { return .searchAndFilters }
    if !filter.text.isEmpty { return .search(text: filter.text) }
    return .filters(count: max(1, filter.activeCount))
  }
}
