import Foundation

/// Settings › General › Clicking the menu bar icon: whether a click opens the menu bar panel or the
/// menu. The status item follows the saved choice at once (`StatusItemClick.didChangeNotification`).
extension PanelController {
  /// What a click on the menu bar icon opens, as saved.
  var statusItemClick: StatusItemClick {
    _ = systemReadingsRevision
    return StatusItemClick.current(in: defaults)
  }

  /// `statusItemClick`. A preference of the app's own, so it never waits behind a renderer command.
  func setStatusItemClick(_ click: StatusItemClick) async throws {
    try await run(.immediate) {
      StatusItemClick.save(click, in: defaults)
      refreshSystemReadings()
    }
  }
}
