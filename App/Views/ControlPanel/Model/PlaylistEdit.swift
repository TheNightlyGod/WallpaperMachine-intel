import Foundation

/// One change to a display's playlist, as its controls make it: the typed form of the page's
/// `playlistSetting` keys. A value no control offers is refused by `PanelController.editPlaylist`.
enum PlaylistEdit: Equatable, Sendable {
  case mode(PlaylistMode)
  /// `.collection` needs the playlist's saved collection to still exist.
  case source(PlaylistSource)
  /// Picks a collection: sets the collection and the source together. It must exist.
  case collection(id: String)
  case order(PlaylistOrder)
  case interval(IntervalChoice)
  /// An installed wallpaper that can play, or nil to leave the day as it is.
  case dayWallpaper(String?)
  case nightWallpaper(String?)
  case dayStart(ClockMinute)
  case nightStart(ClockMinute)
}

/// What the How often menu can choose: a time, a number of minutes, or the unlock.
enum IntervalChoice: Hashable, Sendable {
  /// One of `presets`, the times the menu lists.
  case preset(Int)
  /// Any whole number of minutes in `range`, typed into the Custom field.
  case custom(Int)
  /// Change each time the Mac is unlocked, not on a timer.
  case unlock

  /// The times the menu offers, in minutes: 5 minutes to a day.
  static let presets = DisplayPlaylist.intervals
  /// The minutes a custom interval can take: a minute to a week.
  static let range = DisplayPlaylist.intervalRange

  /// What the menu shows for `playlist`: the unlock, else the stored time when it is a preset, else
  /// Custom with the stored minutes.
  static func current(for playlist: DisplayPlaylist) -> IntervalChoice {
    if playlist.trigger == .unlock { return .unlock }
    return presets.contains(playlist.interval) ? .preset(playlist.interval) : .custom(playlist.interval)
  }

  /// Whether the choice is one a control can make: a listed time, a custom number in `range`.
  var isOffered: Bool {
    switch self {
    case .preset(let minutes): Self.presets.contains(minutes)
    case .custom(let minutes): Self.range.contains(minutes)
    case .unlock: true
    }
  }

  /// "Every hour", "Every 3 days", or "Each time the Mac is unlocked", in the panel's language.
  @MainActor var title: String {
    switch self {
    case .preset(let minutes), .custom(let minutes): Self.title(minutes: minutes)
    case .unlock: L("Each time the Mac is unlocked")
    }
  }

  /// A time in minutes as the menu names it: a minute, an hour, a day, or a whole count of them.
  @MainActor static func title(minutes: Int) -> String {
    switch minutes {
    case 1: L("Every minute")
    case 60: L("Every hour")
    case 1440: L("Every day")
    case _ where minutes % 1440 == 0: L("Every \(minutes / 1440) days")
    case _ where minutes % 60 == 0: L("Every \(minutes / 60) hours")
    default: L("Every \(minutes) minutes")
    }
  }
}

/// A time of day as a minute after local midnight, from 0 (00:00) to 1,439 (23:59).
struct ClockMinute: Hashable, Comparable, Sendable {
  let minutes: Int

  /// 08:00, where a new automatic rule starts.
  static let eightAM = ClockMinute(unchecked: 8 * 60)

  private init(unchecked minutes: Int) { self.minutes = minutes }

  init?(minutes: Int) {
    guard (0..<DisplayPlaylist.minutesPerDay).contains(minutes) else { return nil }
    self.minutes = minutes
  }

  /// `HH:MM` with two digits each, the form a time field holds. Anything else, and a time that
  /// does not exist, is nil.
  init?(_ text: String) {
    let parts = text.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 2, parts.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isASCII) }),
      let hour = Int(parts[0]), let minute = Int(parts[1]), (0..<24).contains(hour), (0..<60).contains(minute)
    else { return nil }
    self.init(minutes: hour * 60 + minute)
  }

  /// The hour and minute to show in a time control.
  var hour: Int { minutes / 60 }
  var minute: Int { minutes % 60 }

  /// `HH:MM`, the inverse of `init(_:)`.
  var text: String { String(format: "%02d:%02d", hour, minute) }

  static func < (lhs: ClockMinute, rhs: ClockMinute) -> Bool { lhs.minutes < rhs.minutes }
}

/// What a display's Wallpapers menu holds, and the edit choosing it makes.
enum PlaylistSourceChoice: Hashable, Sendable {
  case all, favorites
  /// This display's own list.
  case list
  case collection(id: String)
  /// The playlist's source is a collection that is gone. Listed so the menu has a row to show,
  /// but choosing it changes nothing.
  case missingCollection

  /// The row `playlist` selects. `collectionExists` answers whether a collection id is in the store.
  static func current(for playlist: DisplayPlaylist, collectionExists: (String) -> Bool) -> PlaylistSourceChoice {
    switch playlist.source {
    case .all: .all
    case .favorites: .favorites
    case .list: .list
    case .collection:
      if let id = playlist.collectionID, collectionExists(id) { .collection(id: id) } else { .missingCollection }
    }
  }

  /// The change choosing the row makes; nil for `.missingCollection`, which the page ignored.
  var edit: PlaylistEdit? {
    switch self {
    case .all: .source(.all)
    case .favorites: .source(.favorites)
    case .list: .source(.list)
    case .collection(let id): .collection(id: id)
    case .missingCollection: nil
    }
  }
}

/// How the order of a display's own list changes, with the membership the change started from.
///
/// A list keeps ids that left the library, so a move works on the whole stored list and counts only
/// installed wallpapers as neighbours. Both input methods send the order they started from, and the
/// store refuses a stale one: a wallpaper added meanwhile is never dropped by an old drag.
enum PlaylistOrdering {
  /// `ids` with `id` taken out and put back before (or, with `after`, behind) `target`. The list is
  /// returned as it was when `target` is not in it.
  static func reordered(_ ids: [String], moving id: String, relativeTo target: String, after: Bool) -> [String] {
    var moved = ids.filter { $0 != id }
    guard let index = moved.firstIndex(of: target) else { return ids }
    moved.insert(id, at: index + (after ? 1 : 0))
    return moved
  }

  /// The order after `id` moves one place up (`direction` -1) or down (+1) among the installed
  /// wallpapers of `ids`; nil when it is not installed, is already at that end or `direction` is
  /// neither.
  static func moved(_ id: String, by direction: Int, in ids: [String], installed: Set<String>) -> [String]? {
    guard direction == -1 || direction == 1 else { return nil }
    let visible = ids.filter(installed.contains)
    guard let index = visible.firstIndex(of: id), visible.indices.contains(index + direction) else { return nil }
    return reordered(ids, moving: id, relativeTo: visible[index + direction], after: direction == 1)
  }
}
