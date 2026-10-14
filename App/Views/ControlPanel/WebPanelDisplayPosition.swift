import Foundation

/// Where a scene or video wallpaper sits on one display, from the inspector's Position sliders.
///
/// A position is two fractions from 0 (left, top) to 1 (right, bottom) of the room the display
/// leaves around the wallpaper. It is saved the moment it is sent and the running wallpaper
/// follows, so it is not a draft and Apply has nothing to do with it.
///
/// While a slider is being dragged the page also sends `displayPositionPreview` for each step it
/// shows: the wallpaper follows, but nothing is saved and nothing else hears of it. The release
/// sends `displayPosition` for the value it settled on.
@MainActor
extension WebPanelController {
  func performDisplayPosition(_ action: String, request: WebPanelRequest) async throws -> Bool {
    let panX: Double?
    let panY: Double?
    switch action {
    case "displayPosition", "displayPositionPreview":
      // A slider sends only the axis it moved; the other keeps its saved value.
      panX = try request.optionalFraction("x")
      panY = try request.optionalFraction("y")
      guard panX != nil || panY != nil else { throw WebPanelRequest.invalid }
    case "displayPositionReset":
      (panX, panY) = (0.5, 0.5)
    default:
      return false
    }
    let id = try wallpaperID(request)
    let displayID = try request.string("displayID")
    if action == "displayPositionPreview" {
      // Not a command: it changes nothing a later command depends on, and queued behind a
      // running activation it would reach the display long after the thumb had moved on. The
      // page sends one at a time, and the bridge shows nothing for a display no scene draws.
      try await store.previewDisplayPositionAsync(
        wallpaperId: id, displayId: displayID, panX: panX, panY: panY)
      return true
    }
    // It changes what a display draws, so it takes its turn behind the user's other commands.
    try await store.commands.run {
      // Read once the command's turn comes, not when the slider was released: an activation
      // or Apply ahead of it may have changed what the display shows.
      let options = try await store.wallpaperOptionsSnapshotAsync(wallpaperId: id)
      guard options.supported, options.kind == .projectScene || options.kind == .video,
        options.displayConfigurations.contains(where: { $0.displayId == displayID })
      else { throw WebPanelRequest.invalid }
      try await store.setDisplayPositionAsync(
        wallpaperId: id, displayId: displayID, panX: panX, panY: panY)
    }
    return true
  }
}

extension WebPanelRequest {
  /// An axis the request may leave out. One that is present must be a number from 0 to 1:
  /// a value outside it is a stale or forged page, not something to nudge to an edge.
  fileprivate func optionalFraction(_ key: String) throws -> Double? {
    guard body[key] != nil else { return nil }
    return try number(key, range: 0...1)
  }
}
