import Foundation

/// One display as Settings › Displays and the target picker show it.
struct DisplayRow: Identifiable, Equatable {
  let id: String
  /// The name macOS gives the screen, with the renderer's `(id - Role)` suffix; the renderer's own
  /// label when macOS names no such screen.
  let title: String
  let enabled: Bool
  let mode: BridgeDisplayMode
  /// The display this one mirrors, and the displays it can mirror.
  let mirrorTarget: String?
  let mirrorTargets: [MirrorTarget]
  let scalingMode: BridgeScalingMode
  let scalingFactor: Double
  let fps: UInt32
  /// The highest frame rate the display can run.
  let maxFps: UInt32
  let volume: Float
  let muted: Bool
  /// What the display shows, which for a mirror is what its source shows; nil when it is empty.
  let wallpaperID: String?
  /// The title of `wallpaperID` in the library, or the id itself when the library no longer has it.
  let wallpaperTitle: String?

  struct MirrorTarget: Identifiable, Equatable {
    let id: String
    let title: String
  }

  var isPrimary: Bool { id == "primary" }
  var isMirror: Bool { mode == .mirror }

  /// Whether its scaling, frame rate and sound can be adjusted: a mirror, when enabled, has its own; an
  /// independent display needs a wallpaper to adjust them on.
  var canAdjustPlayback: Bool { enabled && (isMirror || wallpaperID != nil) }

  /// Whether the display can be the target of an apply and have a playlist, automatic rules and a
  /// position of its own: enabled, and showing a wallpaper of its own rather than a source's.
  var isStandalone: Bool { enabled && mode == .standalone }

  /// Builds the row of `display`.
  ///
  /// The scaling, frame rate, volume and mute of an independent display come from its wallpaper's own
  /// per-display configuration when `options` (that wallpaper's saved options) holds one for this
  /// display, and from the display's saved values otherwise; a mirror always uses its own. The
  /// wallpaper's volume and mute stand in for the display's only when such a configuration exists.
  ///
  /// - Parameters:
  ///   - displays: every display, to name the mirror sources.
  ///   - shown: the wallpaper the display shows, or nil/empty when it shows none.
  ///   - libraryTitle: the library's title of a wallpaper id, nil for one it does not hold.
  static func make(
    _ display: BridgeDisplaySettingsRow, among displays: [BridgeDisplaySettingsRow],
    titles: ResolvedDisplayTitles, shown: String?, options: BridgeWallpaperOptionsSnapshot?,
    libraryTitle: (String) -> String?
  ) -> DisplayRow {
    let config =
      display.mode == .standalone
      ? options?.displayConfigurations.first { $0.displayId == display.displayId } : nil
    let wallpaperID = shown.flatMap { $0.isEmpty ? nil : $0 }
    return DisplayRow(
      id: display.displayId, title: titles.title(display.title, displayId: display.displayId),
      enabled: display.enabled, mode: display.mode, mirrorTarget: display.selectedMirrorTarget,
      mirrorTargets: display.mirrorTargets.map { id in
        let title = displays.first { $0.displayId == id }?.title ?? id
        return MirrorTarget(id: id, title: titles.title(title, displayId: id))
      },
      scalingMode: config?.scalingMode ?? display.scalingMode,
      scalingFactor: config?.scalingFactor ?? display.scalingFactor,
      fps: config?.targetFps ?? display.targetFps, maxFps: display.maxFps,
      volume: config == nil ? display.volume : options?.volume ?? display.volume,
      muted: config == nil ? display.muted : options?.muted ?? display.muted,
      wallpaperID: wallpaperID,
      wallpaperTitle: wallpaperID.map { libraryTitle($0) ?? $0 })
  }
}
