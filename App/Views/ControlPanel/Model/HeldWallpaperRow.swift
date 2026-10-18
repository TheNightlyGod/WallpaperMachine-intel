import Foundation

/// A wallpaper the load journal held back after the app quit unexpectedly twice while loading it,
/// with the sentence the banner shows beside its Try again button. A warning, not an error: it has
/// no Dismiss, and the row stays until the hold is released.
struct HeldWallpaperRow: Identifiable, Equatable, Sendable {
  var id: String
  /// The wallpaper's title, or its id when it is gone from the library, so that a display left
  /// blank is still explained.
  var title: String
  var message: String

  /// The sentence, worded here so that no view assembles a localized one.
  @MainActor
  static func message(title: String) -> String {
    L(
      "“\(title)” was not restored: WallpaperMachine quit unexpectedly twice in a row while loading it. Nothing was deleted."
    )
  }
}
