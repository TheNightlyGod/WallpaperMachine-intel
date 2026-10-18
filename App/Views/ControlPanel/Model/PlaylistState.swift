import Foundation

/// What Settings › Displays shows of one display's playlist: the saved settings and the run state
/// the scheduler keeps beside them.
struct PlaylistState: Equatable, Sendable {
  let display: String
  let playlist: DisplayPlaylist
  /// When the display changes on its own next; nil until the scheduler dates it.
  let nextChange: Date?
  /// The playlist waits because the user removed this display's wallpaper, until a wallpaper is put
  /// on it or the playlist is resumed.
  let isHeld: Bool
  /// Wallpapers a rotation skips for a while because they failed to load, by id.
  let skipped: [SkippedWallpaper]
  /// How many wallpapers of the display's own list are still in the library, the count the
  /// Wallpapers menu shows. The stored list also keeps ids that left it.
  let listedCount: Int
  /// The Wallpapers menu's selection.
  let source: PlaylistSourceChoice

  struct SkippedWallpaper: Identifiable, Equatable, Sendable {
    let id: String
    let message: String
    let retryAfter: Date
  }

  /// The How often menu's selection.
  var interval: IntervalChoice { .current(for: playlist) }

  /// A held playlist is shown as paused only while it has something to resume; a playlist that is
  /// off waits for nothing.
  var showsResume: Bool { isHeld && playlist.mode != .off }

  /// `nextChange` as the page worded it: the time alone when it falls today, with the short weekday
  /// otherwise, in `locale`'s language and conventions. Nil when the change is not dated.
  func nextChangeText(now: Date = Date(), locale: Locale, calendar: Calendar = .current) -> String? {
    nextChange.map { Self.changeTime($0, now: now, locale: locale, calendar: calendar) }
  }

  static func changeTime(_ date: Date, now: Date = Date(), locale: Locale, calendar: Calendar = .current) -> String {
    var calendar = calendar
    calendar.locale = locale
    let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
    return calendar.isDate(date, inSameDayAs: now)
      ? date.formatted(style.hour().minute())
      : date.formatted(style.weekday(.abbreviated).hour().minute())
  }
}
