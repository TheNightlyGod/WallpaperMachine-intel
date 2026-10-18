import Foundation

/// The numbers the Library page's view chips and the Collections group carry.
struct SidebarCounts: Equatable {
  struct Collection: Identifiable, Equatable {
    var id: String
    var name: String
    /// Every wallpaper id the collection holds, not only the ones still installed: a stale id
    /// still counts, as it always did, until a rescan or a delete prunes it.
    var count: Int
  }

  /// All wallpapers: the whole library, not what a search or a filter leaves.
  var all: Int
  /// The favorites that still exist in the library.
  var favorites: Int
  /// Installed Workshop wallpapers with a newer version; zero hides the update dot.
  var updates: Int
  var collections: [Collection]

  /// The All wallpapers chip's tooltip while an update is waiting.
  @MainActor
  var updateTooltip: String? {
    guard updates > 0 else { return nil }
    return updates == 1 ? L("1 wallpaper has an update") : L("\(updates) wallpapers have updates")
  }
}
