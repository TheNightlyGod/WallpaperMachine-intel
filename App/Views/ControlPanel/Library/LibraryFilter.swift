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

  /// Whether the search text appears in the title or a tag. The text is not trimmed: a lone space
  /// narrows to the titles and tags that contain a space.
  func matchesText(_ row: LibraryRow) -> Bool {
    guard !text.isEmpty else { return true }
    let searched = "\(row.title) \(row.tags.joined(separator: " "))"
    return searched.lowercased().contains(text.lowercased())
  }

  /// The rows that pass, in the order they came in. The collection comes first, then the text,
  /// then the tags.
  ///
  /// - Parameters:
  ///   - favorites: The favorite ids.
  ///   - members: The shown collection's wallpaper ids. Nil shows every wallpaper; a collection
  ///     that no longer exists is the caller's to drop before asking.
  func apply(to rows: [LibraryRow], favorites: Set<String>, members: Set<String>?)
    -> [LibraryRow]
  {
    let needsTags = !requiredTags.isEmpty || !excludedTags.isEmpty
    guard needsTags || !text.isEmpty || members != nil else { return rows }
    return rows.filter { row in
      if let members, !members.contains(row.id) { return false }
      guard matchesText(row) else { return false }
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
