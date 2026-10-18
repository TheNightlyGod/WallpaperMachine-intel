import Foundation

/// Where a scene or video wallpaper sits on one display, from the inspector's Position sliders.
///
/// A position is two fractions from 0 (left, top) to 1 (right, bottom) of the room the display leaves
/// around the wallpaper. It is saved the moment it is sent and the running wallpaper follows, so it
/// is not a draft and neither Apply nor Revert has anything to do with it.
///
/// While a slider is dragged each step the pump shows is `previewDisplayPosition`: the wallpaper
/// follows, but nothing is saved and nothing else hears of it. The release saves the value it settled
/// on. A key press changes the position at once, without a step. The sliders and Center are never
/// disabled for a running command, because their changes queue.
extension PanelController {
  /// The axes of a position, for the drag pump of a slider.
  enum PositionAxis: Sendable { case horizontal, vertical }

  /// `displayPosition`: saves one or both axes. A slider sends only the axis it moved; the other
  /// keeps its saved value, and 0 and 1 are positions too. Start it under
  /// `InspectorAction.displayPosition` with `.latestWins`.
  ///
  /// It changes what a display draws, so it takes its turn behind the user's other commands (and
  /// leaves an older banner showing). The wallpaper must be a supported scene or video with a row
  /// for the display, read once the command's turn comes: an activation or Apply ahead of it may
  /// have changed what the display shows. Refused with no bridge call when no axis is given or a
  /// value is not a fraction.
  func setDisplayPosition(
    _ wallpaperID: String, display displayID: String, x: Double? = nil, y: Double? = nil
  ) async throws {
    let (panX, panY) = try Self.positionAxes(x: x, y: y)
    let id = try installedWallpaperID(wallpaperID)
    try await commitDisplayPosition(id, displayID, panX: panX, panY: panY)
  }

  /// `displayPositionReset`: Center, both axes at 0.5.
  func resetDisplayPosition(_ wallpaperID: String, display displayID: String) async throws {
    let id = try installedWallpaperID(wallpaperID)
    try await commitDisplayPosition(id, displayID, panX: 0.5, panY: 0.5)
  }

  private func commitDisplayPosition(
    _ id: String, _ displayID: String, panX: Double?, panY: Double?
  ) async throws {
    try await run(.immediateQueued) {
      let options = try await store.wallpaperOptionsSnapshotAsync(wallpaperId: id)
      guard options.supported, options.kind == .projectScene || options.kind == .video,
        options.displayConfigurations.contains(where: { $0.displayId == displayID })
      else { throw InvalidControlValue() }
      try await store.setDisplayPositionAsync(
        wallpaperId: id, displayId: displayID, panX: panX, panY: panY)
    }
  }

  /// `displayPositionPreview`: shows the position while a slider is being dragged, saving nothing.
  /// Not a command: it changes nothing a later command depends on, and queued behind a running
  /// activation it would reach the display long after the thumb had moved on. A refusal throws to
  /// the caller, which ignores it.
  ///
  /// A step is refused for what a move is refused for (`canPreviewPosition`), before the bridge
  /// hears of it.
  func previewDisplayPosition(
    _ wallpaperID: String, display displayID: String, x: Double? = nil, y: Double? = nil
  ) async throws {
    let (panX, panY) = try Self.positionAxes(x: x, y: y)
    let id = try installedWallpaperID(wallpaperID)
    guard canPreviewPosition(id, display: displayID) else { throw InvalidControlValue() }
    try await run(.immediate) {
      try await store.previewDisplayPositionAsync(
        wallpaperId: id, displayId: displayID, panX: panX, panY: panY)
    }
  }

  /// Whether a drag step may show `id` at a new position on `displayID`: a supported scene or
  /// video with a row for the display. A step comes up to ten times a second, so this reads what is
  /// at hand instead of asking the bridge for the options as a move does: the library's entry, and
  /// the wallpaper's options when they are known (the open inspector's, or the ones Settings read).
  /// Without them the kind decides, and the bridge shows nothing for a display no scene draws.
  private func canPreviewPosition(_ id: String, display displayID: String) -> Bool {
    guard let entry = store.librarySnapshot.wallpapers.first(where: { $0.id == id }),
      entry.supported, entry.kind == .projectScene || entry.kind == .video
    else { return false }
    let open = store.wallpaperOptionsSnapshot
    guard let options = open?.wallpaperId == id ? open : displayOptions.options(for: id) else {
      return true
    }
    return options.supported
      && options.displayConfigurations.contains { $0.displayId == displayID }
  }

  /// The pump for one axis of one display's position slider, whose value is the fraction. The
  /// control calls `release(_:commit:)` with `setDisplayPosition` inside `launch`.
  func displayPositionDragPump(
    _ wallpaperID: String, display displayID: String, axis: PositionAxis,
    interval: Duration = DragStepPump<Double>.defaultInterval,
    sleep: @escaping DragStepPump<Double>.Sleep = { try await Task.sleep(for: $0) }
  ) -> DragStepPump<Double> {
    DragStepPump(interval: interval, sleep: sleep) { [weak self] value in
      let x: Double? = axis == .horizontal ? value : nil
      let y: Double? = axis == .vertical ? value : nil
      try? await self?.previewDisplayPosition(wallpaperID, display: displayID, x: x, y: y)
    }
  }

  /// An axis the request may leave out; one that is present must be a fraction. At least one is
  /// needed. A value outside 0...1 is a stale or forged control, not something to nudge to an edge.
  private static func positionAxes(x: Double?, y: Double?) throws -> (Double?, Double?) {
    guard x != nil || y != nil else { throw InvalidControlValue() }
    return (try x.map(PanelValueRules.fraction), try y.map(PanelValueRules.fraction))
  }
}
