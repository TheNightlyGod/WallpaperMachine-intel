import Foundation

/// What Settings can be searched by, in one language: each item's phrases joined, and each group's
/// title. Built once per language, because resolving every phrase of every row is the costly part
/// of a search and typing should not repeat it.
struct SettingsIndex {
  fileprivate struct Entry {
    let item: SettingsItem
    let text: String
  }

  fileprivate let entries: [Entry]
  fileprivate let groupTitles: [String: String]

  /// - Parameter resolve: Turns a phrase into the panel's language.
  init(items: [SettingsItem] = SettingsRegistry.items, resolve: (LocalizedStringResource) -> String)
  {
    var titles: [String: String] = [:]
    entries = items.map { item in
      if let group = item.group, let title = group.title {
        titles[SettingsSearch.groupKey(item.section, group)] = resolve(title)
      }
      return Entry(item: item, text: item.phrases(resolve).joined(separator: "\n"))
    }
    groupTitles = titles
  }

  private init(entries: [Entry], groupTitles: [String: String]) {
    self.entries = entries
    self.groupTitles = groupTitles
  }

  /// The index of what the pages draw now: without the items `isOffered` turns down, nor anything
  /// inside a disclosure it turns down. A row a page leaves out on this Mac (the low-battery
  /// choices without a battery, Effective now while nothing lowers the scale) was not in the web
  /// page's DOM, so it was never a result; searching this index, such a row neither counts toward
  /// its section, nor opens a disclosure, nor keeps a group's title on show, and a query only it
  /// would match has no result.
  func offering(_ isOffered: (SettingsItem) -> Bool) -> SettingsIndex {
    let byID = Dictionary(
      entries.map { ($0.item.id, $0.item) }, uniquingKeysWith: { first, _ in first })
    func offered(_ item: SettingsItem) -> Bool {
      var current: SettingsItem? = item
      var hops = 0
      while let checked = current, hops < 8 {
        guard isOffered(checked) else { return false }
        current = checked.disclosure.flatMap { byID[$0] }
        hops += 1
      }
      return true
    }
    return SettingsIndex(entries: entries.filter { offered($0.item) }, groupTitles: groupTitles)
  }

  @MainActor
  init(items: [SettingsItem] = SettingsRegistry.items, locale: PanelLocale) {
    self.init(items: items) { locale.string(resolving: $0) }
  }
}

/// A row a section builds from live data instead of declaring it as an item: a display's card, a
/// saved display layout, a wallpaper in a display's own list. The web page searched whatever a row
/// said, so a display's name, a layout's name or a listed wallpaper's title found it; a search counts
/// each live row that matches toward its section, so the section keeps its page and its list
/// count for it. The section's view decides which of its live rows to draw with `matches(_:)`.
struct SettingsLiveUnit: Equatable, Sendable {
  let section: SettingsSection
  /// The group the row is drawn in, which a match keeps on show; nil for a row that is not inside a
  /// registered group's card, or whose view decides on its own whether its card shows.
  let groupID: String?
  /// Everything the row says, one phrase per line.
  let text: String

  init(section: SettingsSection, group: SettingsItem.Group? = nil, text: String) {
    self.section = section
    groupID = group?.id
    self.text = text
  }
}

/// The result of typing in the Settings search field: which rows stay, how many each section
/// keeps, and which disclosures open.
///
/// The rules are the web panel's, including the fix of `50129725`:
/// - A query is one contiguous piece of text, matched ignoring case, accents and character width
///   against everything a row says: its title, note, details and keywords. Section names are not
///   searched; group titles are.
/// - A group whose title matches keeps all of its items.
/// - A disclosure shows when its own words match or something inside it does, and opens when
///   something inside it does. Without a match in or on it, an open one folds away with its title
///   instead of leaving its contents on show without it; it comes back, still open, when the
///   search clears.
/// - A section's count is the number of items and live rows (`SettingsLiveUnit`) that match, and a
///   section with none drops out.
struct SettingsSearch {
  /// The query without the spaces around it. Empty means no search.
  let query: String
  private let matched: Set<String>
  private let visible: Set<String>
  private let visibleGroups: Set<String>
  private let opening: Set<String>
  private let counts: [SettingsSection: Int]

  var isActive: Bool { !query.isEmpty }

  /// - Parameter live: The rows the sections build from live data, counted as items are.
  init(query: String, index: SettingsIndex, live: [SettingsLiveUnit] = []) {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    self.query = query
    guard !query.isEmpty else {
      matched = []
      visible = []
      visibleGroups = []
      opening = []
      counts = [:]
      return
    }
    let entries = index.entries
    let byID = Dictionary(
      entries.map { ($0.item.id, $0.item) }, uniquingKeysWith: { first, _ in first })
    /// The group an item belongs to, which an item inside a disclosure takes from the disclosure.
    func group(of item: SettingsItem) -> String? {
      var current = item
      var hops = 0
      while current.group == nil, let parent = current.disclosure.flatMap({ byID[$0] }), hops < 8 {
        current = parent
        hops += 1
      }
      return current.group.map { Self.groupKey(current.section, $0) }
    }
    func contains(_ text: String) -> Bool { Self.contains(text, query) }

    let textMatches = Set(entries.filter { contains($0.text) }.map(\.item.id))
    let matchingGroups = Set(index.groupTitles.filter { contains($0.value) }.keys)
    var matched = Set<String>()
    for entry in entries {
      let item = entry.item
      if textMatches.contains(item.id) || group(of: item).map(matchingGroups.contains) == true {
        matched.insert(item.id)
      }
    }
    // A match opens every disclosure around it and keeps each of them on show.
    var visible = matched
    var opening = Set<String>()
    for entry in entries where textMatches.contains(entry.item.id) {
      var parent = entry.item.disclosure
      var hops = 0
      while let id = parent, hops < 8 {
        visible.insert(id)
        opening.insert(id)
        parent = byID[id]?.disclosure
        hops += 1
      }
    }
    var visibleGroups = Set<String>()
    var counts: [SettingsSection: Int] = [:]
    for entry in entries {
      let item = entry.item
      guard visible.contains(item.id) else { continue }
      if let key = group(of: item) { visibleGroups.insert(key) }
      if matched.contains(item.id) { counts[item.section, default: 0] += 1 }
    }
    for unit in live where contains(unit.text) {
      counts[unit.section, default: 0] += 1
      if let group = unit.groupID { visibleGroups.insert(Self.groupKey(unit.section, id: group)) }
    }
    self.matched = matched
    self.visible = visible
    self.visibleGroups = visibleGroups
    self.opening = opening
    self.counts = counts
  }

  /// Whether the item is drawn: always without a search, otherwise when it matches or holds a
  /// match.
  func shows(_ item: SettingsItem) -> Bool { !isActive || visible.contains(item.id) }

  /// Whether the item itself matched, by its own words or its group's title, rather than only
  /// holding a match: a disclosure that is drawn once per display shows on a display whose rows do
  /// not hold the match only when this is true.
  func matchesItself(_ item: SettingsItem) -> Bool { !isActive || matched.contains(item.id) }

  /// Whether the group's card is drawn: while any of its items or live rows is.
  func shows(_ group: SettingsItem.Group, in section: SettingsSection) -> Bool {
    !isActive || visibleGroups.contains(Self.groupKey(section, group))
  }

  /// Whether the section has anything to draw, and so a page in the results.
  func shows(_ section: SettingsSection) -> Bool { !isActive || counts[section] != nil }

  /// The disclosure opens by itself because something inside it matched.
  func opens(_ disclosure: SettingsItem) -> Bool { isActive && opening.contains(disclosure.id) }

  /// How many items and live rows of the section match; zero without a search.
  func count(in section: SettingsSection) -> Int { counts[section] ?? 0 }

  /// The sections that keep a page, in the order of the section list.
  var sections: [SettingsSection] { SettingsSection.allCases.filter(shows) }

  /// Whether a search has no result at all, so the page says so.
  var hasNoResults: Bool { isActive && counts.isEmpty }

  /// Whether text that is not an item matches the query, for a row built from live data (a
  /// playlist, a display layout) that hides itself without being registered. It counts toward the
  /// section list only when the section also hands the row in as a `SettingsLiveUnit`.
  func matches(_ text: String) -> Bool { !isActive || Self.contains(text, query) }

  fileprivate static func groupKey(_ section: SettingsSection, _ group: SettingsItem.Group)
    -> String
  {
    groupKey(section, id: group.id)
  }

  private static func groupKey(_ section: SettingsSection, id: String) -> String {
    "\(section.rawValue)/\(id)"
  }

  /// A piece of text anywhere in another, ignoring case, accents and character width.
  static func contains(_ text: String, _ query: String) -> Bool {
    text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive])
      != nil
  }
}
