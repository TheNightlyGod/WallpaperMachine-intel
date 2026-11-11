import Foundation

/// What narrows the Installed grid: the search text, the tags a wallpaper must and must not
/// carry, and the collection on show. Sorting is not part of it (see `LibrarySort`), and neither
/// is the selection.
///
/// Installed keeps Discover's filter model, applied in the app to each wallpaper's own tags. The
/// library is the user's own, so nothing is excluded by default.
struct LibraryFilter: Equatable, Sendable {
  var text = ""
  /// Tags every shown wallpaper must carry, in the order they were ticked. "Favorite" is the
  /// sidebar's Favorites view.
  var requiredTags: [String] = []
  /// Tags no shown wallpaper may carry.
  var excludedTags: [String] = []
  /// The collection the grid is narrowed to, if any.
  var collectionID: String?

  /// How many filters are in effect: every required tag, every box unticked, and the collection.
  /// It reads zero right after Clear, and the Filter button's badge shows it.
  var activeCount: Int {
    requiredTags.count + excludedTags.count + (collectionID == nil ? 0 : 1)
  }

  /// Tags and collection only; the search text is the search field's.
  var hasFilters: Bool { activeCount > 0 }

  /// The same filter with every tag and the collection cleared, keeping the text.
  func clearingFilters() -> LibraryFilter {
    var copy = self
    copy.requiredTags = []
    copy.excludedTags = []
    copy.collectionID = nil
    return copy
  }

  /// The facts a wallpaper can be filtered on, lower-cased: its type as Steam's type tag, the tags
  /// of its manifest, and the library's own: Approved, Favorite, Active (it is the target
  /// display's wallpaper), Update, and Unspecified when it names no genre, as Steam would list it.
  static func tags(of row: LibraryRow, isFavorite: Bool) -> Set<String> {
    var tags = Set([row.kind.rawValue.lowercased()])
    for tag in row.tags { tags.insert(tag.lowercased()) }
    if row.isApproved { tags.insert("approved") }
    if isFavorite { tags.insert("favorite") }
    if row.isActive { tags.insert("active") }
    if row.isUpdateAvailable { tags.insert("update") }
    if tags.isDisjoint(with: LibraryFilterCatalog.genreTags) { tags.insert("unspecified") }
    return tags
  }

  /// Whether a wallpaper with these `tags` passes: every required tag is among them and none of
  /// the excluded ones is, whatever the case.
  func accepts(tags: Set<String>) -> Bool {
    requiredTags.allSatisfy { tags.contains($0.lowercased()) }
      && !excludedTags.contains { tags.contains($0.lowercased()) }
  }

  /// The search text as one pass over the library asks it.
  private enum Query {
    /// A Workshop link, or a bare item id that is installed (`WorkshopLink.itemID(in:)`): only
    /// that wallpaper.
    case item(String)
    /// Words, folded (`LibrarySearchText`), and the wallpapers of the collections the text names.
    case words(String, collections: Set<String>)
  }

  /// A link names a Workshop item whether or not `rows` hold it. A bare number of six digits or
  /// more names one only when a wallpaper of `rows` has it for its id; otherwise it is searched
  /// as words, without the spaces around it, as the artwork id in the description of a work
  /// saved from pixiv is.
  private func textQuery(in rows: [LibraryRow], named: Set<String>) -> Query? {
    guard !text.isEmpty else { return nil }
    if let id = WorkshopLink.itemID(in: text) {
      if WorkshopLink.itemID(inLink: text) != nil || rows.contains(where: { $0.id == id }) {
        return .item(id)
      }
      let number = text.trimmingCharacters(in: .whitespacesAndNewlines)
      return .words(LibrarySearchText.fold(number), collections: named)
    }
    return .words(LibrarySearchText.fold(text), collections: named)
  }

  /// The wallpapers of the collections whose name the search text is, whatever its case,
  /// accents and the spaces around it, which a search shows beside the wallpapers whose own
  /// words hold the text. Empty when the text names none, or is a Workshop link.
  func membersOfCollectionsNamed(in collections: [CollectionRow]) -> Set<String> {
    let name = LibrarySearchText.fold(text.trimmingCharacters(in: .whitespacesAndNewlines))
    guard !name.isEmpty, WorkshopLink.itemID(inLink: text) == nil else { return [] }
    var members = Set<String>()
    for collection in collections where LibrarySearchText.fold(collection.name) == name {
      members.formUnion(collection.wallpaperIDs)
    }
    return members
  }

  /// Whether `row` passes `query`. Words are looked for in the title and tags, joined by a space,
  /// and in the author and description the manifest names; they are not trimmed, so a lone space
  /// narrows to the wallpapers with a space in them. A link or an installed id is the wallpaper's
  /// own id, never words, so a description that links another item does not count.
  private func matches(_ row: LibraryRow, _ query: Query) -> Bool {
    switch query {
    case .item(let id): row.id == id
    case .words(let words, let collections):
      collections.contains(row.id) || LibrarySearchText.contains(row.searchText, words)
    }
  }

  /// The rows that pass, in the order they came in. The collection comes first, then the text,
  /// then the tags. `rows` are the whole library, which a bare id is looked for in.
  ///
  /// - Parameters:
  ///   - favorites: The favorite ids.
  ///   - members: The shown collection's wallpaper ids. Nil shows every wallpaper; a collection
  ///     that no longer exists is the caller's to drop before asking.
  ///   - named: `membersOfCollectionsNamed(in:)`'s answer, which the text matches too.
  func apply(
    to rows: [LibraryRow], favorites: Set<String>, members: Set<String>?, named: Set<String> = []
  ) -> [LibraryRow] {
    let needsTags = !requiredTags.isEmpty || !excludedTags.isEmpty
    let query = textQuery(in: rows, named: named)
    guard needsTags || query != nil || members != nil else { return rows }
    return rows.filter { row in
      if let members, !members.contains(row.id) { return false }
      if let query, !matches(row, query) { return false }
      guard needsTags else { return true }
      return accepts(tags: Self.tags(of: row, isFavorite: favorites.contains(row.id)))
    }
  }

  /// The required tags that no wallpaper of `rows` carries any more, which would leave the grid
  /// empty after a restore. Excluded tags are not asked about: they only hide.
  func staleRequiredTags(in rows: [LibraryRow], favorites: Set<String>) -> [String] {
    guard !requiredTags.isEmpty else { return [] }
    var carried = Set<String>()
    for row in rows {
      carried.formUnion(Self.tags(of: row, isFavorite: favorites.contains(row.id)))
    }
    return requiredTags.filter { !carried.contains($0.lowercased()) }
  }

  /// How many boxes of `tags` are unticked or chips selected or hidden, for a group's count.
  func count(among tags: [String]) -> Int {
    tags.filter { tag in excludedTags.contains(tag) || requiredTags.contains(tag) }.count
  }
}
