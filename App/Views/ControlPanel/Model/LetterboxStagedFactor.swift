import Foundation

/// What the Black bars card set, so it can tell its own unsaved factor from any other. The
/// wallpaper's `dirty` flag covers every unsaved edit and says nothing about which one it is.
struct LetterboxStagedFactor: Equatable {
  let wallpaperID: String
  let displayID: String
  let factor: Double
}
