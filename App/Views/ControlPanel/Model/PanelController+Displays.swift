import Foundation

/// A display in the target picker: every display is listed, and only an enabled independent one can
/// be chosen.
struct TargetDisplayChoice: Identifiable, Equatable, Sendable {
  let id: String
  /// The display's title, for the toolbar.
  let title: String
  /// The title as the picker lists it: a mirror or a disabled display says so.
  let label: String
  let isSelectable: Bool
}

/// One change to a display, as its controls make it: the typed form of the page's `displaySetting`
/// keys. A value no control offers is refused by `PanelController.setDisplay`.
enum DisplaySetting: Equatable {
  case enabled(Bool)
  case mode(BridgeDisplayMode)
  /// The display to mirror. Never empty: the "Choose display" row sends nothing.
  case mirrorTarget(String)
  case scalingMode(BridgeScalingMode)
  /// Greater than zero.
  case scalingFactor(Double)
  /// From 1 to the highest rate of the display's wallpaper (of the mirror, for a mirror).
  case fps(Int)
  /// From 0 to 1.
  case volume(Float)
  case muted(Bool)
}

extension PanelController {
  // MARK: Derived state

  /// Every display the renderer reports, in its order, with the values Settings › Displays shows.
  /// An independent display's scaling, frame rate, volume and mute are those of its own wallpaper's
  /// configuration, read from the options the inspector has open or, for another display's
  /// wallpaper, from `displayOptions` (which Settings fetches while it is on screen); the display's
  /// saved values stand in until then, and for a mirror.
  var displayRows: [DisplayRow] {
    let displays = store.settingsSnapshot.displays
    let titles = displayTitles.resolved()
    let monitors = store.monitorInformationSnapshot.rows
    let open = store.wallpaperOptionsSnapshot
    return displays.map { display in
      let shown = monitors.first { $0.displayId == display.displayId }?.wallpaperId
      let options = shown.flatMap { id -> BridgeWallpaperOptionsSnapshot? in
        guard !id.isEmpty else { return nil }
        return open?.wallpaperId == id ? open : displayOptions.options(for: id)
      }
      return DisplayRow.make(
        display, among: displays, titles: titles, shown: shown, options: options,
        libraryTitle: { id in store.librarySnapshot.wallpapers.first { $0.id == id }?.title })
    }
  }

  /// The enabled independent displays: the ones an apply, a playlist, automatic rules and a
  /// position can reach. **Apply to all displays** counts them (`InspectorPolicy.offersApplyToAll`).
  var standaloneDisplayRows: [DisplayRow] { displayRows.filter(\.isStandalone) }

  /// The displays the target picker lists. A mirror and a disabled display are listed, marked, and
  /// cannot be chosen; the whole picker is disabled while `isStoreBusy`.
  var targetDisplayChoices: [TargetDisplayChoice] {
    displayRows.map { row in
      TargetDisplayChoice(
        id: row.id, title: row.title,
        label: row.isMirror
          ? L("\(row.title) (mirrored)") : row.enabled ? row.title : L("\(row.title) (disabled)"),
        isSelectable: row.isStandalone)
    }
  }

  /// The displays `display`'s wallpaper can be copied to or swapped with: the other enabled
  /// independent displays. Empty when `display` shows no wallpaper of its own, which is when Copy or
  /// swap is not offered at all.
  func transferPeers(of display: String) -> [DisplayRow] {
    let rows = displayRows
    guard let source = rows.first(where: { $0.id == display }), source.wallpaperID != nil,
      source.mode == .standalone
    else { return [] }
    return rows.filter { $0.isStandalone && $0.id != display }
  }

  // MARK: Actions

  /// `displaySetting`: one change to a display.
  ///
  /// A mirror's scaling, frame rate, volume and mute go to the mirror itself. An independent
  /// display's go to its wallpaper's own configuration and are then applied, which also commits any
  /// other pending edit of that wallpaper; the display must show a wallpaper first. Queued behind
  /// whatever command is running.
  func setDisplay(_ id: String, _ setting: DisplaySetting) async throws {
    try validate(setting)
    try await run(.queued) {
      guard let display = store.settingsSnapshot.displays.first(where: { $0.displayId == id }) else {
        throw InvalidControlValue()
      }
      switch setting {
      case .enabled(let enabled):
        try await store.setDisplayEnabledAsync(displayId: id, enabled: enabled)
      case .mode(let mode):
        try await store.setDisplayModeAsync(displayId: id, mode: mode)
      case .mirrorTarget(let target):
        try await store.setMirrorTargetAsync(displayId: id, targetDisplayId: target)
      case .scalingMode, .scalingFactor, .fps, .volume, .muted:
        if display.mode == .mirror {
          try await setMirror(display, setting)
        } else {
          try await setStandalone(display, setting)
        }
      }
    }
  }

  /// `refreshDisplays`: reads the displays again, once the running activation is idle.
  func refreshDisplays() async throws {
    try await run(.queued) { try await store.refreshDisplaysAsync() }
  }

  /// `eject`: the user takes `wallpaperID` off `display`, which also tells the playlist so it does not
  /// fill the display again. Nothing is reported when the display shows another wallpaper by then.
  func eject(_ wallpaperID: String, from display: String) async throws {
    try await run(.queued) {
      try await store.removeWallpaperFromDisplayAsync(
        displayId: display, wallpaperId: try installedWallpaperID(wallpaperID))
    }
  }

  /// `sceneRetry`: reloads the wallpaper of a scene that stopped, on the enabled display whose live
  /// CoreGraphics id is `physicalDisplayID` (the id a scene report carries). A mirror's scene reloads
  /// on the display it mirrors. Not queued: the store takes the display's activation turn itself,
  /// and a command that waited for the queue it held would never return.
  func retryScene(onPhysicalDisplay physicalDisplayID: UInt32) async throws {
    try await run(.direct) {
      guard
        let display = store.settingsSnapshot.displays.first(where: {
          $0.enabled && ResolvedDisplayTitles.liveDisplayID($0.displayId, title: $0.title) == physicalDisplayID
        })
      else { throw InvalidControlValue() }
      try await store.retryStoppedSceneAsync(displayId: display.displayId)
    }
  }

  // MARK: Helpers

  /// The refusals that depend on the value alone, before the change waits for the queue.
  private func validate(_ setting: DisplaySetting) throws {
    switch setting {
    case .mirrorTarget(let target) where target.isEmpty: throw InvalidControlValue()
    case .scalingFactor(let factor)
    where !(Double.leastNonzeroMagnitude...Double.greatestFiniteMagnitude).contains(factor):
      throw InvalidControlValue()
    case .volume(let volume) where !(0...1).contains(volume): throw InvalidControlValue()
    case .fps(let fps) where fps < 1: throw InvalidControlValue()
    default: return
    }
  }

  /// A mirror display has no wallpaper of its own, so its playback settings are its own.
  private func setMirror(_ display: BridgeDisplaySettingsRow, _ setting: DisplaySetting) async throws {
    let id = display.displayId
    switch setting {
    case .scalingMode(let mode):
      try await store.setMirrorScalingModeAsync(displayId: id, mode: mode)
    case .scalingFactor(let factor):
      try await store.setMirrorScalingFactorAsync(displayId: id, factor: factor)
    case .fps(let fps):
      guard fps <= Int(max(1, display.maxFps)) else { throw InvalidControlValue() }
      try await store.setMirrorTargetFpsAsync(displayId: id, fps: UInt32(fps))
    case .volume(let volume):
      try await store.setMirrorVolumeAsync(displayId: id, volume: volume)
    case .muted(let muted):
      try await store.setMirrorMutedAsync(displayId: id, muted: muted)
    case .enabled, .mode, .mirrorTarget:
      throw InvalidControlValue()
    }
  }

  /// An independent display's playback settings belong to the wallpaper it shows. The edit goes to
  /// that wallpaper's options and is applied at once, which also commits the wallpaper's other
  /// pending edits (a scale factor or text the inspector has not sent yet).
  private func setStandalone(_ display: BridgeDisplaySettingsRow, _ setting: DisplaySetting) async throws {
    let id = display.displayId
    guard
      let shown = store.monitorInformationSnapshot.rows.first(where: { $0.displayId == id })?.wallpaperId
    else { throw WallpaperActionError(message: L("Choose a wallpaper for this display first.")) }
    let wallpaper = try installedWallpaperID(shown)
    switch setting {
    case .scalingMode(let mode):
      try await store.setScalingModeAsync(wallpaperId: wallpaper, displayId: id, mode: mode)
    case .scalingFactor(let factor):
      try await store.editScalingFactorAsync(wallpaperId: wallpaper, displayId: id, factor: factor)
    case .fps(let fps):
      let options = try await store.wallpaperOptionsSnapshotAsync(wallpaperId: wallpaper)
      guard let row = options.displayConfigurations.first(where: { $0.displayId == id }),
        fps <= Int(max(1, row.maxFps))
      else { throw InvalidControlValue() }
      try await store.setTargetFpsAsync(wallpaperId: wallpaper, displayId: id, fps: UInt32(fps))
    case .volume(let volume):
      try await store.setVolumeAsync(wallpaperId: wallpaper, volume: volume)
    case .muted(let muted):
      try await store.setMutedAsync(wallpaperId: wallpaper, muted: muted)
    case .enabled, .mode, .mirrorTarget:
      throw InvalidControlValue()
    }
    try await store.applyWallpaperOptionsAsync(wallpaperId: wallpaper)
  }
}
