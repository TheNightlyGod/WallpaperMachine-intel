import Foundation

/// A collection in the filters panel, with the size it shows.
struct CollectionRow: Identifiable, Equatable, Sendable {
  let id: String
  let name: String
  let wallpaperIDs: [String]

  /// The members, stale ids included: a wallpaper that left the library leaves its collections
  /// when it is deleted through the panel, not when a scan stops finding it.
  var count: Int { wallpaperIDs.count }
}

extension PanelController {
  // MARK: Derived state

  /// Every collection in the order it was made, for the filters panel, the selection bar's picker, the
  /// inspector's membership card and a playlist's Wallpapers menu.
  var collectionRows: [CollectionRow] {
    _ = revisions.collections
    return collections.collections.map { CollectionRow(id: $0.id, name: $0.name, wallpaperIDs: $0.wallpaperIDs) }
  }

  // MARK: Actions

  /// `collectionCreate`: a collection of `wallpaperIDs` (installed ones only, each once, in the
  /// order given; none makes an empty collection). A name that is blank, over 128 characters or on
  /// more than one line is refused by the store. Metadata only, so the banner stays as it is and
  /// nothing waits for the renderer.
  @discardableResult
  func createCollection(name: String, wallpaperIDs: [String] = []) async throws -> WallpaperCollection {
    var created: WallpaperCollection?
    try await run(.immediate) {
      let ids = try organizationIDs(wallpaperIDs, requireInstalled: true)
      created = try collections.create(name: name, wallpaperIDs: ids)
    }
    guard let created else { throw CancellationError() }
    return created
  }

  /// `collectionRename`.
  func renameCollection(_ id: String, to name: String) async throws {
    try await run(.immediate) { try collections.rename(id, name: name) }
  }

  /// `collectionDelete`. A playlist that drew from the collection keeps an empty list of its own and
  /// never turns into a rotation over the whole library.
  func deleteCollection(_ id: String) async throws {
    try await run(.immediate) {
      try collections.delete(id)
      playlists.forgetCollection(id)
    }
  }

  /// `collectionAdd`: every id must be installed, or none is added. Ids already in the collection
  /// keep their place.
  func addToCollection(_ id: String, wallpaperIDs: [String]) async throws {
    try await run(.immediate) {
      try collections.add(try organizationIDs(wallpaperIDs, requireInstalled: true), to: id)
    }
  }

  /// `collectionRemove`. Membership can be removed even for a wallpaper that has already left the
  /// library.
  func removeFromCollection(_ id: String, wallpaperIDs: [String]) async throws {
    try await run(.immediate) {
      try collections.remove(try organizationIDs(wallpaperIDs, requireInstalled: false), from: id)
    }
  }

  /// A batch of wallpaper ids for a collection, each once, in request order. At most 4,096 of them,
  /// none empty (an empty batch is fine); with `requireInstalled`, one id that left the library
  /// refuses the whole batch.
  private func organizationIDs(_ ids: [String], requireInstalled: Bool) throws -> [String] {
    guard ids.count <= 4096, ids.allSatisfy({ !$0.isEmpty && $0.count <= 65_536 }) else {
      throw InvalidControlValue()
    }
    if requireInstalled {
      let installed = Set(store.librarySnapshot.wallpapers.map(\.id))
      guard ids.allSatisfy(installed.contains) else {
        throw WallpaperActionError(
          message: L("Some selected wallpapers are no longer installed. Refresh your library."))
      }
    }
    var seen = Set<String>()
    return ids.filter { seen.insert($0).inserted }
  }
}
