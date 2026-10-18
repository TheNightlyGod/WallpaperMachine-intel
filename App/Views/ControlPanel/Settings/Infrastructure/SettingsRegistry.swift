import Foundation

/// Every section's items in one place. A section lists its own in `static let items`; adding a
/// section's list here is what makes its rows searchable.
enum SettingsRegistry {
  static let items: [SettingsItem] =
    QuickSettingsSection.items + GeneralSettingsSection.items + AppearanceSettingsSection.items
    + DesktopSettingsSection.items + PlaybackSettingsSection.items
    + PerformanceSettingsSection.items + DisplaysSettingsSection.items
    + ShortcutsSettingsSection.items + LibrarySettingsSection.items + StorageSettingsSection.items
    + AboutSettingsSection.items

  static func items(in section: SettingsSection) -> [SettingsItem] {
    items.filter { $0.section == section }
  }

  /// The ids of the items no page draws now: rows that depend on this Mac (a battery, two
  /// displays) or on another choice (Reduced quality chosen somewhere), and live reports with
  /// nothing to say. A search leaves them out, so it never finds a row it cannot show. A section
  /// whose rows come and go adds its own rule here; its view draws a row by the same facts.
  @MainActor
  static func unofferedItems(_ controller: PanelController) -> Set<String> {
    QuickSettingsSection.unofferedItems(controller)
      .union(PlaybackSettingsSection.unofferedItems(controller))
      .union(PerformanceSettingsSection.unofferedItems(controller))
  }

  /// What is wrong with a list of items, one line per problem; empty when it is sound. Ids are
  /// unique, a group's id means one title, and a disclosure an item names is an item of its own
  /// section. The registry's own list is checked by a test, so a section cannot ship a mistake the
  /// search would silently turn into a hidden row.
  static func problems(in items: [SettingsItem]) -> [String] {
    var problems: [String] = []
    var seen = Set<String>()
    for item in items where !seen.insert(item.id).inserted {
      problems.append("duplicate id \(item.id)")
    }
    let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var groupTitles: [String: LocalizedStringResource?] = [:]
    for item in items {
      if let parentID = item.disclosure {
        if let parent = byID[parentID] {
          if parent.section != item.section {
            problems.append("\(item.id) is inside \(parentID) of another section")
          }
        } else {
          problems.append("\(item.id) is inside \(parentID), which is not an item")
        }
      }
      if let group = item.group {
        let key = "\(item.section.rawValue)/\(group.id)"
        if let known = groupTitles[key], known != group.title {
          problems.append("group \(key) has two titles")
        }
        groupTitles[key] = group.title
      }
    }
    return problems
  }
}
