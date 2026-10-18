import Foundation

/// One searchable thing on a Settings page: a row, a Quick Settings tile, a disclosure's summary.
///
/// A section declares its items once, as a `static let items` list the registry gathers, and its
/// view looks the items up to draw them. Everything the search and the page need to know without
/// drawing is here: where the item lives, and every phrase a person could look it up by. The
/// phrases are `LocalizedStringResource`s, read in the panel's own language when a search runs, so
/// a search finds a setting in whatever language the panel is in.
struct SettingsItem: Identifiable, Sendable {
  /// A titled card of rows, or an untitled one. It is part of the item because a search that
  /// matches a group's title shows every item in it.
  struct Group: Sendable {
    /// Unique within its section.
    let id: String
    let title: LocalizedStringResource?

    init(_ id: String, title: LocalizedStringResource? = nil) {
      self.id = id
      self.title = title
    }
  }

  /// Unique across Settings, by convention `<section>.<name>`: `desktop.write-picture`.
  let id: String
  let section: SettingsSection
  let group: Group?
  /// The id of the disclosure item this one sits inside, if any. A disclosure is itself an item:
  /// its title and note are what its summary line says, and a search folds it away unless it or
  /// something inside it matches.
  let disclosure: String?
  let title: LocalizedStringResource
  /// The explanation under the title. A long one shows its first sentence there and the rest
  /// behind the ⓘ button (`SettingsNote.parts(_:)`).
  let note: LocalizedStringResource?
  /// Further paragraphs behind the ⓘ button, for a row that states its details separately.
  let info: [LocalizedStringResource]
  /// Words a person might search with that appear nowhere else on the item: the other variants of
  /// its note, the titles of its choices, the labels of its buttons.
  let keywords: [LocalizedStringResource]

  init(
    id: String, section: SettingsSection, group: Group? = nil,
    inside disclosure: SettingsItem? = nil,
    title: LocalizedStringResource, note: LocalizedStringResource? = nil,
    info: [LocalizedStringResource] = [], keywords: [LocalizedStringResource] = []
  ) {
    self.id = id
    self.section = section
    self.group = group
    self.disclosure = disclosure?.id
    self.title = title
    self.note = note
    self.info = info
    self.keywords = keywords
  }

  /// Every phrase of the item, as the panel language says them.
  func phrases(_ resolve: (LocalizedStringResource) -> String) -> [String] {
    [resolve(title)] + [note].compactMap { $0 }.map(resolve) + info.map(resolve)
      + keywords.map(resolve)
  }
}
