import Foundation

/// What the host reports about one wallpaper's web page or native video on one display: still
/// loading, ready, or failed with a reason and maybe a Retry. A closed surface has no row.
struct HostStateRow: Identifiable, Equatable, Sendable {
  /// `HostWallpaperState.key`: the kind and the display (`web:1`).
  var id: String
  var wallpaperID: String
  var displayID: UInt32
  /// The display's name as macOS gives it, or the bare id when no monitor row matches.
  var displayTitle: String
  var kind: HostWallpaperState.Kind
  var phase: HostWallpaperState.Phase
  /// Why it failed, in the host's words. It is text, never markup: show it with `Text(verbatim:)`.
  var message: String?
  /// A failed web page the host can reload. A native video cannot be retried from here.
  var canRetry: Bool
}
