import Foundation

/// What the inspector's apply button says and whether it can act, for a page that is in the
/// library: it reapplies when the target display already shows the page, and it needs a target
/// that is enabled and shows a wallpaper of its own (not a mirror, not disabled).
struct PixivApplyOffer: Equatable {
  let libraryID: String
  /// The target display shows this page now: the button restarts it instead of applying it.
  let reapplies: Bool
  let isEnabled: Bool

  init(libraryID: String, target: MediaApplyTarget) {
    self.libraryID = libraryID
    reapplies = target.wallpaperID == libraryID
    isEnabled = target.canShowWallpaper
  }
}
