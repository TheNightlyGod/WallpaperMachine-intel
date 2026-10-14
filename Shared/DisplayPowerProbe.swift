import CoreGraphics

/// Whether a display is asleep, asked of the system each time it matters.
///
/// A surface used to remember "the displays are asleep" from the last sleep or
/// wake notification. A wake notice that never arrived then left it paused, and a
/// surface acquired while the displays slept started out rendering. Reading the
/// power state when a surface decides makes the notifications only a reason to
/// ask again.
///
/// Closures rather than direct calls so a test can describe displays that sleep
/// and wake without touching real ones.
struct DisplayPowerProbe: Sendable {
  /// Whether the display with this identifier is asleep.
  var isAsleep: @Sendable (UInt32) -> Bool
  /// Every display the system knows about, asleep ones included.
  var onlineDisplays: @Sendable () -> [UInt32]

  static let system = DisplayPowerProbe(
    isAsleep: { CGDisplayIsAsleep($0) != 0 },
    onlineDisplays: {
      var count: UInt32 = 0
      guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
      var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
      guard CGGetOnlineDisplayList(count, &displays, &count) == .success else { return [] }
      return Array(displays.prefix(Int(count)))
    })

  /// Whether a surface for this display should treat its display as asleep.
  ///
  /// A known display answers for itself, so one monitor sleeping does not pause
  /// the surface on another. A surface that is not tied to a display (a preview)
  /// counts as asleep only when there is at least one display and every one of
  /// them is: it is shown wherever the user happens to be looking.
  func displaysAsleep(for displayID: UInt32?) -> Bool {
    if let displayID { return isAsleep(displayID) }
    let displays = onlineDisplays()
    return !displays.isEmpty && displays.allSatisfy(isAsleep)
  }
}
