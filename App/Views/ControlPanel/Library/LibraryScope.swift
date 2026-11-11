/// Which part of the library the Installed page shows: everything, the favorites, or one local
/// collection. Favorites and a collection are filters of Installed, not pages of their own, so
/// changing the scope keeps the search, sort, tags and exclusions as they are.
enum LibraryScope: Hashable {
  case all
  case favorites
  case collection(String)
}

extension LibraryScope {
  /// The playlist source that rotates through the same wallpapers: what Play hands the display.
  var playlistSource: PlaylistSourceChoice {
    switch self {
    case .all: .all
    case .favorites: .favorites
    case .collection(let id): .collection(id: id)
    }
  }
}
