import Foundation

/// Wallpaper Engine's per-wallpaper options (colour adjustments, image filter, flip, mouse
/// parallax, playback rate): committing a value, showing a slider while it is dragged, and
/// restoring defaults. Like the authored properties they are drafts held by the bridge until Apply
/// changes, and Revert undoes them.
extension PanelController {
  /// `engineOption`: the value of one option, committed as a pending edit. Queued; start it with
  /// `.latestWins` under `InspectorAction.engineOption`. Only a listed (enabled) option takes an
  /// edit, and the value is held to its control: a switch takes a boolean, a slider a number inside
  /// its range, the image filter none or one of the filters the bridge listed. The row shows `value`
  /// until the edit ends, taken or refused.
  func commitEngineOption(
    _ wallpaperID: String, option: BridgeEngineOptionId, value: BridgePropertyValue
  ) async throws {
    pendingEngineOptionValues[wallpaperID, default: [:]][option] = value
    defer {
      if pendingEngineOptionValues[wallpaperID]?[option] == value {
        pendingEngineOptionValues[wallpaperID]?[option] = nil
        if pendingEngineOptionValues[wallpaperID]?.isEmpty == true {
          pendingEngineOptionValues[wallpaperID] = nil
        }
      }
    }
    try await run(.queued) {
      let id = try installedWallpaperID(wallpaperID)
      let options = try await store.wallpaperOptionsSnapshotAsync(wallpaperId: id)
      let value = try Self.editableEngineValue(value, for: option, in: options)
      try await store.editEngineOptionAsync(wallpaperId: id, option: option, value: value)
    }
    reconcileInspectorContext()
  }

  /// `engineOptionPreview`: the value an option's slider is being dragged to, shown without being
  /// an edit. Not a command, like `previewProperty`: a refusal throws to the caller (the drag pump
  /// ignores it). Only a listed slider takes part.
  func previewEngineOption(
    _ wallpaperID: String, option: BridgeEngineOptionId, value: BridgePropertyValue
  ) async throws {
    try await run(.immediate) {
      let id = try installedWallpaperID(wallpaperID)
      let options = try await store.wallpaperOptionsSnapshotAsync(wallpaperId: id)
      guard options.engineOptions?.rows.first(where: { $0.id == option })?.slider != nil else {
        throw InvalidControlValue()
      }
      let value = try Self.editableEngineValue(value, for: option, in: options)
      await store.previewEngineOptionAsync(wallpaperId: id, option: option, value: value)
    }
  }

  /// The pump for one option's slider; see `propertyDragPump`.
  func engineOptionDragPump(
    _ wallpaperID: String, option: BridgeEngineOptionId,
    interval: Duration = DragStepPump<PropertyDragValue>.defaultInterval,
    sleep: @escaping DragStepPump<PropertyDragValue>.Sleep = { try await Task.sleep(for: $0) }
  ) -> DragStepPump<PropertyDragValue> {
    DragStepPump(interval: interval, sleep: sleep) { [weak self] value in
      try? await self?.previewEngineOption(wallpaperID, option: option, value: value.bridgeValue)
    }
  }

  /// `restoreEngineOption`: stages the default of one option (pending: Apply keeps it, Revert
  /// undoes it).
  func restoreEngineOption(_ wallpaperID: String, option: BridgeEngineOptionId) async throws {
    try await run(.queued) {
      try await store.restoreEngineOptionDefaultAsync(
        wallpaperId: installedWallpaperID(wallpaperID), option: option)
    }
  }

  /// `restoreAllEngineOptions`: stages the default of every option, the ones a switch hides
  /// included. The authored properties, display settings, audio and presets are not touched.
  func restoreAllEngineOptions(_ wallpaperID: String) async throws {
    try await run(.queued) {
      try await store.restoreAllEngineOptionDefaultsAsync(
        wallpaperId: installedWallpaperID(wallpaperID))
    }
  }

  /// The value an option's control may send, or the refusal for one it never offers: the option
  /// must be listed and enabled.
  static func editableEngineValue(
    _ value: BridgePropertyValue, for option: BridgeEngineOptionId,
    in options: BridgeWallpaperOptionsSnapshot
  ) throws -> BridgePropertyValue {
    guard let engine = options.engineOptions,
      let row = engine.rows.first(where: { $0.id == option && $0.enabled })
    else { throw InvalidControlValue() }
    switch (option, value) {
    case (.colorEnabled, .bool), (.flipHorizontal, .bool), (.mouseParallax, .bool):
      return value
    case (.imageFilter, .string(let name)):
      guard name.isEmpty || engine.imageFilters.contains(name) else { throw InvalidControlValue() }
      return value
    case (_, .number(let number)):
      guard let slider = row.slider, number.isFinite, slider.min <= slider.max,
        (slider.min...slider.max).contains(number)
      else { throw InvalidControlValue() }
      return value
    default:
      throw InvalidControlValue()
    }
  }
}
