import Foundation

/// Moving wallpapers to the Trash and forgetting everything the app kept about them.
extension PanelController {
  /// `delete`: asks first, then ejects the wallpaper from every display showing it, moves its
  /// library copy to the Trash (the files the user imported are not touched) and forgets what the
  /// app kept about it. A panel with no window cannot ask, so it deletes nothing.
  ///
  /// The confirmation is asked before queueing, so an open sheet holds up nothing else.
  func delete(_ id: String) async throws {
    try await run(.direct) {
      let id = try installedWallpaperID(id)
      let title = store.librarySnapshot.wallpapers.first { $0.id == id }?.title ?? id
      guard
        await dialogs.confirm(
          L("Move \(title) to Trash?"),
          detail: L(
            "It is removed from your library and stops playing. The original files you imported are not affected."
          ),
          button: L("Move to Trash"))
      else { return }
      try await store.commands.run {
        let report = try await store.deleteWallpapersAsync(ids: [id], recycle: recycleWallpaperFolder)
        if let failure = report.failures.first { throw failure.error }
        try await forgetLibraryMetadata([id])
      }
    }
  }

  /// `deleteMany`: the same for a selection. Wallpapers that could not be moved are reported after
  /// the ones that could have been cleaned up.
  func deleteMany(_ ids: [String]) async throws {
    try await run(.direct) {
      let ids = try installedWallpaperIDs(ids)
      let name = store.librarySnapshot.wallpapers.first { $0.id == ids[0] }?.title ?? ids[0]
      let title = ids.count == 1 ? L("Move \(name) to Trash?") : L("Move \(ids.count) wallpapers to Trash?")
      guard
        await dialogs.confirm(
          title,
          detail: L(
            "They are removed from your library and stop playing. The original files you imported are not affected."
          ),
          button: L("Move to Trash"))
      else { return }
      try await store.commands.run {
        let report = try await store.deleteWallpapersAsync(ids: ids, recycle: recycleWallpaperFolder)
        try await forgetLibraryMetadata(report.deleted)
        if !report.failures.isEmpty {
          let titles = Dictionary(
            store.librarySnapshot.wallpapers.map { ($0.id, $0.title) },
            uniquingKeysWith: { first, _ in first })
          let details = report.failures.map {
            "\(titles[$0.id] ?? $0.id): \($0.error.localizedDescription)"
          }
          throw WallpaperActionError(
            message: L(
              "Moved \(report.deleted.count) of \(ids.count) wallpapers to Trash. Couldn’t move \(details.joined(separator: "; "))"
            ))
        }
      }
    }
  }

  /// Everything the app kept about wallpapers that are gone: favorites, playlist entries,
  /// automation rules, history, update marks, collection membership, saved presets and image
  /// placements. Every cleanup runs even when one throws, and the first error is the one raised.
  func forgetLibraryMetadata(_ ids: [String]) async throws {
    var firstError: Error?
    do { try forgetFavorites(ids) } catch { firstError = error }
    playlists.forget(ids)
    do { try automations.forgetWallpapers(Set(ids)) } catch { firstError = firstError ?? error }
    store.history.forget(Set(ids))
    workshop.updates.forget(ids)
    do { try collections.forget(ids) } catch { firstError = firstError ?? error }
    do { try await presets.forget(wallpaperIDs: ids) } catch { firstError = firstError ?? error }
    do { try imagePlacement.forget(Set(ids)) } catch { firstError = firstError ?? error }
    if let firstError { throw firstError }
  }
}
