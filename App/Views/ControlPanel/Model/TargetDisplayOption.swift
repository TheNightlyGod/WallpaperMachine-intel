import Foundation

/// One display as the target picker and Now Playing see it.
struct TargetDisplayOption: Identifiable, Equatable, Sendable {
  var id: String
  /// The system's name for the display with the renderer's `(id - Role)` suffix; a display that
  /// cannot be named keeps the renderer's label.
  var title: String
  var isEnabled: Bool
  var isMirror: Bool
  /// The wallpaper the display shows now; nil for a display that shows none. A mirror reports the
  /// wallpaper of the display it mirrors.
  var wallpaperID: String?

  /// Only an enabled display that shows a wallpaper of its own can be the target. A disabled or a
  /// mirrored one stays in the list, and cannot be chosen.
  var isSelectable: Bool { isEnabled && !isMirror }
}
