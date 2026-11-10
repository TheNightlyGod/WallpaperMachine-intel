import Foundation

/// Why the Installed grid has nothing to show, and so what to offer. Only meaningful when no row
/// passes; a grid with rows has no empty state.
enum LibraryEmptyState: Equatable {
  /// The first read of the library, or a rescan that left nothing to show yet.
  case loading
  /// The library could not be read, so nothing is known to be installed: say why and offer to
  /// read it again. Not `emptyLibrary`, which would invite someone to import what they already have.
  case failed(message: String)
  /// Nothing is installed: import something or find it on the Workshop.
  case emptyLibrary
  /// A collection that holds nothing. It is empty, not filtered away.
  case emptyCollection(name: String)
  /// The search is a Workshop link or id, and no installed wallpaper is that item: Discover can
  /// show it. Neither the filters nor a collection are why it is missing. Only for an id that
  /// names its item alone (`WorkshopLink.isBareItemID(_:)`), which is what Discover is given; a
  /// link to a shorter id is an ordinary search.
  ///
  /// A bare number is only this once it has arrived whole and while no filter applies. Typed,
  /// each prefix of an id from six digits on would claim to be an item until the last digit. It
  /// is searched as words too (`LibraryFilter`), and the filters may be hiding a wallpaper whose
  /// words hold it.
  case notInstalled(itemID: String)
  /// Search text and filters together hide everything.
  case searchAndFilters
  /// The search text alone hides everything.
  case search(text: String)
  /// `count` filters hide everything, the collection among them.
  case filters(count: Int)

  /// The state for a grid with no rows, or nil when something is shown.
  ///
  /// - Parameters:
  ///   - rowCount: How many rows pass the filter.
  ///   - isLoading: The library is being read.
  ///   - loadFailure: Why the last read of the library failed, when it did.
  ///   - libraryIsEmpty: Nothing is installed at all.
  ///   - collection: The collection on show and how many ids it holds, stale ones included.
  ///   - isInstalled: Whether the library holds the wallpaper of this id.
  ///   - textIsWhole: The search text was pasted, dropped, confirmed with Return or restored,
  ///     rather than being typed (`InstalledBrowserModel.isTextWhole`).
  static func make(
    rowCount: Int, isLoading: Bool, loadFailure: String? = nil, libraryIsEmpty: Bool,
    collection: (name: String, memberCount: Int)?, filter: LibraryFilter,
    isInstalled: (String) -> Bool, textIsWhole: Bool
  ) -> LibraryEmptyState? {
    guard rowCount == 0 else { return nil }
    if isLoading { return .loading }
    // A read that failed leaves the wallpapers it had before on show; with none, the grid is
    // empty because of the failure, whatever the search and filters say.
    if libraryIsEmpty, let loadFailure { return .failed(message: loadFailure) }
    if libraryIsEmpty { return .emptyLibrary }
    if let collection, collection.memberCount == 0 {
      return .emptyCollection(name: collection.name)
    }
    if let id = WorkshopLink.itemID(in: filter.text), WorkshopLink.isBareItemID(id),
      !isInstalled(id),
      WorkshopLink.itemID(inLink: filter.text) != nil || (textIsWhole && !filter.hasFilters)
    {
      return .notInstalled(itemID: id)
    }
    if !filter.text.isEmpty && filter.hasFilters { return .searchAndFilters }
    if !filter.text.isEmpty { return .search(text: filter.text) }
    return .filters(count: max(1, filter.activeCount))
  }
}
