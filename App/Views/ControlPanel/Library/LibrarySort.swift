import Foundation

/// Installed's five sort keys, each with the direction it starts in: names read A to Z, while
/// favorites, size and date are asked for to see the starred, biggest or newest first.
///
/// The raw value is the key `PanelViewState` stores, so a reopened window restores it.
enum LibrarySort: String, CaseIterable, Identifiable, Sendable {
  case title
  case type
  case favorites
  case size
  case added

  var id: String { rawValue }

  /// The direction choosing this key puts the list in.
  var startsDescending: Bool {
    switch self {
    case .title, .type: false
    case .favorites, .size, .added: true
    }
  }

  /// The key's name in the panel's language, for the Sort menu and the direction button's help.
  @MainActor
  var name: String {
    switch self {
    case .title: L("Name")
    case .type: L("Type")
    case .favorites: L("Favorites")
    case .size: L("File size")
    case .added: L("Date added")
    }
  }
}

extension LibrarySort {
  /// Natural order of titles as a person reads them: digits count as numbers, and case and
  /// accents do not matter. (Plain `localizedStandardCompare` also skips punctuation, which a
  /// library of Workshop titles must not.)
  static func compareTitles(_ lhs: String, _ rhs: String, locale: Locale) -> ComparisonResult {
    lhs.compare(
      rhs, options: [.numeric, .caseInsensitive, .diacriticInsensitive], range: nil, locale: locale)
  }

  /// `rows` in this key's order.
  ///
  /// The key decides first and the title breaks ties. A row whose size or date has not been
  /// measured yet sorts last in both directions, and the type sort breaks its ties by title in
  /// the natural direction whichever way the list runs. Rows equal in everything keep the order
  /// they came in, so the same library always lists the same way.
  ///
  /// - Parameters:
  ///   - favorites: The favorite ids, which the `favorites` key reads.
  ///   - locale: How titles are compared.
  func sorted(
    _ rows: [LibraryRow], descending: Bool, favorites: Set<String>, locale: Locale
  ) -> [LibraryRow] {
    let direction: Int = descending ? -1 : 1
    func order(_ result: ComparisonResult) -> Int {
      switch result {
      case .orderedAscending: -1
      case .orderedSame: 0
      case .orderedDescending: 1
      }
    }
    func byTitle(_ lhs: LibraryRow, _ rhs: LibraryRow) -> Int {
      order(Self.compareTitles(lhs.title, rhs.title, locale: locale))
    }
    /// The primary key of a numeric sort: nil when the row has no value yet.
    func value(_ row: LibraryRow) -> Double? {
      switch self {
      case .favorites: favorites.contains(row.id) ? 1 : 0
      case .size: row.size.map(Double.init)
      case .added: row.addedAt?.timeIntervalSince1970
      case .title, .type: nil
      }
    }
    func comparison(_ lhs: LibraryRow, _ rhs: LibraryRow) -> Int {
      switch self {
      case .title:
        return byTitle(lhs, rhs) * direction
      case .type:
        let kinds = lhs.kind.rawValue.compare(rhs.kind.rawValue)
        return order(kinds) * direction != 0 ? order(kinds) * direction : byTitle(lhs, rhs)
      case .favorites, .size, .added:
        let (left, right) = (value(lhs), value(rhs))
        guard let left, let right else {
          if (left == nil) != (right == nil) { return left == nil ? 1 : -1 }
          return byTitle(lhs, rhs)
        }
        if left != right { return (left < right ? -1 : 1) * direction }
        return byTitle(lhs, rhs)
      }
    }
    return rows.enumerated().sorted { lhs, rhs in
      let result = comparison(lhs.element, rhs.element)
      return result != 0 ? result < 0 : lhs.offset < rhs.offset
    }.map(\.element)
  }
}
