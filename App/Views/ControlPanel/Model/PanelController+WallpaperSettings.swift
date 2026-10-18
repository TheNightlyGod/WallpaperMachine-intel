import Foundation

/// The inspector's General configuration and Displays cards: the wallpaper's own audio and media
/// settings, and what each display does with it.
///
/// Every setting here takes effect at once and is saved, except the scale factor, which is a draft
/// that shows on the display and waits for Apply changes. Each is queued behind the user's other
/// commands and wrapped by the store in an edit, so an Apply or an activation waits for it. Start
/// them under the `InspectorAction.wallpaperSetting` / `displayConfig` keys with `.latestWins`.
extension PanelController {
  // MARK: The wallpaper's own settings

  /// `wallpaperSetting` `volume`: from 0 to 1; a value outside it is refused, not moved to the edge.
  func setVolume(_ volume: Double, for wallpaperID: String) async throws {
    try await run(.queued) {
      let id = try installedWallpaperID(wallpaperID)
      try await store.setVolumeAsync(wallpaperId: id, volume: try PanelValueRules.volume(volume))
    }
  }

  /// `wallpaperSetting` `muted`.
  func setMuted(_ muted: Bool, for wallpaperID: String) async throws {
    try await run(.queued) {
      try await store.setMutedAsync(wallpaperId: installedWallpaperID(wallpaperID), muted: muted)
    }
  }

  /// `wallpaperSetting` `audioResponseEnabled`. When the capture fails the store re-reads every
  /// snapshot, so the saved option rolls back and the switch follows.
  func setAudioResponseEnabled(_ enabled: Bool, for wallpaperID: String) async throws {
    try await run(.queued) {
      try await store.setAudioResponseEnabledAsync(
        wallpaperId: installedWallpaperID(wallpaperID), enabled: enabled)
    }
  }

  /// `wallpaperSetting` `mediaIntegrationEnabled`.
  func setMediaIntegrationEnabled(_ enabled: Bool, for wallpaperID: String) async throws {
    try await run(.queued) {
      try await store.setMediaIntegrationEnabledAsync(
        wallpaperId: installedWallpaperID(wallpaperID), enabled: enabled)
    }
  }

  // MARK: One display's setting

  /// `displayConfig` `enabled`: whether the display plays this wallpaper.
  func setDisplayEnabled(_ enabled: Bool, on displayID: String, for wallpaperID: String)
    async throws
  {
    try await run(.queued) {
      try await store.setDisplayConfigEnabledAsync(
        wallpaperId: installedWallpaperID(wallpaperID), displayId: displayID, enabled: enabled)
    }
  }

  /// `displayConfig` `scalingMode`.
  func setScalingMode(_ mode: BridgeScalingMode, on displayID: String, for wallpaperID: String)
    async throws
  {
    try await run(.queued) {
      try await store.setScalingModeAsync(
        wallpaperId: installedWallpaperID(wallpaperID), displayId: displayID, mode: mode)
    }
  }

  /// `displayConfig` `scalingFactor`: a finite factor greater than zero, held as a draft (it shows on
  /// the playing display, Apply changes keeps it and Revert restores the saved one). An empty or
  /// zero field is the control's to catch: it must never reach here as 0.
  func setScalingFactor(_ factor: Double, on displayID: String, for wallpaperID: String)
    async throws
  {
    try await run(.queued) {
      let id = try installedWallpaperID(wallpaperID)
      try await store.editScalingFactorAsync(
        wallpaperId: id, displayId: displayID, factor: try PanelValueRules.scalingFactor(factor))
    }
  }

  /// `displayConfig` `fps`: a whole number from 1 to the display's own maximum, read from a fresh
  /// options snapshot of the wallpaper (a display it has no row for is refused).
  func setFrameRate(_ fps: Int, on displayID: String, for wallpaperID: String) async throws {
    try await run(.queued) {
      let id = try installedWallpaperID(wallpaperID)
      let options = try await store.wallpaperOptionsSnapshotAsync(wallpaperId: id)
      guard let row = options.displayConfigurations.first(where: { $0.displayId == displayID })
      else { throw InvalidControlValue() }
      try await store.setTargetFpsAsync(
        wallpaperId: id, displayId: displayID,
        fps: try PanelValueRules.frameRate(fps, maximum: row.maxFps))
    }
  }
}
