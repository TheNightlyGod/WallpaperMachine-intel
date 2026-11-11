import Foundation

/// What an inspector's apply button does for a wallpaper that is in the library, decided the same
/// way in the Installed, Workshop and pixiv inspectors; each draws its own label, symbol and style.
///
/// Applying what the target display already shows does nothing, so there the button reapplies,
/// which restarts it. Either way it runs under its own key (`reapplyWallpaper` or `activate`) and
/// is disabled while that action is pending, or when the wallpaper or the target cannot take it.
/// `PanelController.apply(_:)` carries it out.
struct ApplyOffer: Equatable {
  let wallpaperID: String
  /// The target display shows this wallpaper now: the button restarts it instead of applying it.
  let reapplies: Bool
  /// The wallpaper and the target display can take it and its action is not already pending.
  let isEnabled: Bool

  /// - Parameters:
  ///   - shownID: what the target display shows now.
  ///   - canApply: the wallpaper can run and the target display can take it.
  ///   - isBusy: whether an action key is pending (`PanelController.isBusy`).
  init(
    wallpaperID: String, shownID: String?, canApply: Bool, isBusy: (String) -> Bool
  ) {
    self.wallpaperID = wallpaperID
    reapplies = shownID == wallpaperID
    isEnabled = canApply && !isBusy(Self.key(wallpaperID, reapplies: reapplies))
  }

  /// For the Workshop and pixiv inspectors: the target must be enabled and show a wallpaper of its
  /// own (not a mirror, not disabled); `canRun` is whether the wallpaper's type can play here.
  init(
    wallpaperID: String, target: MediaApplyTarget, canRun: Bool = true, isBusy: (String) -> Bool
  ) {
    self.init(
      wallpaperID: wallpaperID, shownID: target.wallpaperID,
      canApply: canRun && target.canShowWallpaper, isBusy: isBusy)
  }

  /// The key the button's action runs under.
  var key: String { Self.key(wallpaperID, reapplies: reapplies) }

  private static func key(_ wallpaperID: String, reapplies: Bool) -> String {
    PanelActionCoordinator.key(reapplies ? "reapplyWallpaper" : "activate", id: wallpaperID)
  }
}
