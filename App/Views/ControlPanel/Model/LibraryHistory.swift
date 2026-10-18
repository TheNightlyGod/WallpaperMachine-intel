import Foundation

/// What the target display showed before, for Recently used and the Previous button.
struct LibraryHistory: Equatable, Sendable {
  /// The wallpapers used on the display, newest first, without repeats, limited to the ones still
  /// installed and able to run. The store keeps the last 50.
  var recentIDs: [String]
  /// The wallpaper Previous would apply: the last one before the current that is still installed
  /// and supported. Nil leaves Previous disabled.
  var previousID: String?
}
