import Foundation

/// A pixiv tile: the work with the pages of it already saved and the download ring it wears. A tile
/// asks `PanelController.pixivTile(for:)` itself, so a progress tick re-renders only its own tile.
struct PixivTile: Identifiable, Equatable {
  /// The ring of the work's page that is under way or needs attention.
  struct Ring: Equatable {
    let state: TileDownloadState
    /// The job the ring's action names: its library id.
    let jobID: String
  }

  let work: PixivWork
  /// Page indexes of this work that are in the library, sorted.
  let savedPages: [Int]
  /// The listing's own thumbnail.
  let image: PanelImageSource?
  let ring: Ring?

  var id: String { work.id }
  /// Any page of the work is saved: the tile wears a check.
  var isSaved: Bool { !savedPages.isEmpty }
}

extension PixivWork {
  /// The title, or "Untitled" for a work that has none.
  @MainActor
  var displayTitle: String { title.isEmpty ? L("Untitled") : title }

  /// The thumbnail the listing carries, for the cache that fetches it with pixiv's referrer.
  var thumbnail: PanelImageSource? { thumbnailURL.map { .pixivThumbnail($0) } }
}
