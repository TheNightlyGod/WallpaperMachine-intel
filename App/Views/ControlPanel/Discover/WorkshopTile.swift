import Foundation

/// A Discover tile: the Workshop item with what the panel adds to it, whether the wallpaper is in
/// the library already, whether it is a favorite there, and the download ring it wears.
///
/// A tile asks `PanelController.workshopTile(for:)` itself, so a progress tick re-renders only the
/// tile whose job moved and not the grid.
struct WorkshopTile: Identifiable, Equatable {
  let item: WorkshopItem
  /// A copy of the wallpaper is in the library: the tile wears a check and no ring.
  let isInstalled: Bool
  /// The installed copy is a favorite, which the tile's heart mark shows.
  let isFavorite: Bool
  /// The signed-in Steam account subscribes to it.
  var isSubscribed = false
  let download: TileDownloadState?

  var id: String { item.id }
}

/// What double-clicking a Discover tile does.
enum WorkshopTileDoubleClick: Equatable {
  case openCollection, apply, select, continueSetup, requestDownload
}

extension WorkshopItem {
  /// A collection: a list of Workshop items put together by its author, opened and never downloaded.
  var isCollection: Bool { collectionSize != nil }

  /// Staff-approved wallpapers carry the `Approved` tag, which the tile marks with a trophy.
  var isApproved: Bool { tags.contains { $0.caseInsensitiveCompare("Approved") == .orderedSame } }

  /// Workshop presets carry the `Preset` category tag, which the tile marks.
  var isPreset: Bool { tags.contains { $0.caseInsensitiveCompare("Preset") == .orderedSame } }

  /// The cached still for the tile, nil when Steam gave no preview or one that is not https.
  var thumbnail: PanelImageSource? {
    guard let url = previewURL, url.scheme == "https" else { return nil }
    return .steamThumbnail(url)
  }

  /// The author's SteamID64 when the source said and it has the form of one, which is what opens
  /// the author's other items.
  var authorProfileID: String? {
    guard let creatorID, SteamWebSession.isSteamID(creatorID) else { return nil }
    return creatorID
  }

  /// "Collection" for a collection, else the wallpaper type in Steam's own words, translated (an
  /// item with no type tag reads "All types"). Each word is a literal key, so the catalog's
  /// extraction sees every one, Application included, and never drops one as unused.
  @MainActor
  var kindLabel: String {
    if isCollection { return L("Collection") }
    switch kind {
    case .scene: return L("Scene")
    case .video: return L("Video")
    case .web: return L("Web")
    case .application: return L("Application")
    case .all: return L("All types")
    }
  }

  /// Whether the wallpaper type runs on macOS at all: an Application is a Windows program.
  var canRunOnMac: Bool { kind != .application }
}
