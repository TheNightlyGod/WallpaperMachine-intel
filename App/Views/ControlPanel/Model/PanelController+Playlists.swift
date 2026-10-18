import Foundation

/// A saved playlist in the list of them, with how many displays currently run a copy of it.
struct PlaylistPlanRow: Identifiable, Equatable, Sendable {
  let id: String
  let name: String
  let playlist: DisplayPlaylist
  /// The displays whose playlist is a copy of this plan that has not been edited since.
  let displayCount: Int
}

extension PanelController {
  // MARK: Derived state

  /// `display`'s playlist and the scheduler's state beside it. A display nobody configured reads as
  /// the playlist every display starts with, which is off.
  func playlistState(for display: String) -> PlaylistState {
    _ = revisions.playlists
    _ = revisions.collections
    let playlist = playlists.playlist(for: display)
    // The list's own ids are few; the library's are not, so the library is walked once and only
    // when there is a list to count.
    let listed = Set(playlist.wallpaperIDs)
    let listedCount =
      listed.isEmpty
      ? 0 : store.librarySnapshot.wallpapers.reduce(0) { listed.contains($1.id) ? $0 + 1 : $0 }
    return PlaylistState(
      display: display, playlist: playlist, nextChange: playlists.nextChange[display],
      isHeld: playlists.holds[display] != nil,
      skipped: (playlists.skipped[display] ?? [:]).sorted { $0.key < $1.key }.map {
        PlaylistState.SkippedWallpaper(id: $0.key, message: $0.value.message, retryAfter: $0.value.retryAfter)
      },
      listedCount: listedCount,
      source: .current(for: playlist) { collections.collection(id: $0) != nil })
  }

  /// The saved playlists, in the order they were saved.
  var playlistPlanRows: [PlaylistPlanRow] {
    _ = revisions.playlists
    let inUse = Dictionary(grouping: playlists.playlists.values.compactMap(\.planID), by: { $0 })
    return playlists.plans.map {
      PlaylistPlanRow(id: $0.id, name: $0.name, playlist: $0.playlist, displayCount: inUse[$0.id]?.count ?? 0)
    }
  }

  // MARK: Editing a playlist

  /// `playlistSetting`: one change to `display`'s playlist (the target display when none is named).
  ///
  /// Waits its turn in the command queue, with no slot: automatic wallpaper choices can change
  /// playlists too, and an edit made while one is in flight must not be overwritten by it, nor may
  /// two edits made in a row coalesce. Counts as a manual choice for the automatic selection.
  func editPlaylist(_ edit: PlaylistEdit, display: String? = nil) async throws {
    try validate(edit)
    try await changePlaylist(display) { display in try apply(edit, to: display) }
  }

  /// `playlistAdd`: the installed wallpapers of `ids`, each once, appended to the display's list.
  func addToPlaylist(_ ids: [String], display: String? = nil) async throws {
    try await changePlaylist(display) { display in
      playlists.add(try installedWallpaperIDs(ids), to: display)
    }
  }

  /// `playlistRemove`: the wallpaper leaves the display's list. It need not be installed.
  func removeFromPlaylist(_ id: String, display: String? = nil) async throws {
    try await changePlaylist(display) { display in playlists.remove(id, from: display) }
  }

  /// `playlistReorder`: puts the display's list in the order of `ids`. `expected` is the order the
  /// view started from, and the store refuses the change unless that is still the stored order and
  /// `ids` holds exactly the same wallpapers, so a list that changed while the user dragged is never
  /// overwritten. Wallpapers that left the library stay in both arrays.
  func reorderPlaylist(_ ids: [String], expected: [String], display: String? = nil) async throws {
    guard ids.count <= 10_000, expected.count <= 10_000 else { throw InvalidControlValue() }
    try await changePlaylist(display) { display in
      try playlists.reorder(ids, on: display, expected: expected)
    }
  }

  /// `playlistClearFailures`: wallpapers a rotation skipped for failing are tried again.
  func clearPlaylistFailures(display: String? = nil) async throws {
    try await run(.immediate) { playlists.clearFailures(on: try standaloneDisplayID(display)) }
  }

  /// `playlistSkip` (Change now): the display's rotation moves on to its next wallpaper with a fresh
  /// interval. Refused, with the reason, when the scheduler has nothing to move.
  func skipPlaylist(display: String? = nil) async throws {
    try await run(.immediate) {
      let display = try standaloneDisplayID(display)
      guard playlists.skipHandler?(display) == true else {
        throw WallpaperActionError(
          message: playlists.playlist(for: display).mode == .rotate
            ? L("This display’s playlist has no other wallpaper to change to.")
            : L("This display has no rotating playlist to move along."))
      }
    }
  }

  /// `playlistResume`: a playlist that waits because its display was emptied fills the display.
  func resumePlaylist(display: String? = nil) async throws {
    try await run(.immediate) { playlists.resumeHandler?(try standaloneDisplayID(display)) }
  }

  /// `historyClear`: forgets what the display showed recently, so Previous has nothing to go back to.
  /// Other displays and the wallpaper files are not touched.
  func clearHistory(display: String? = nil) async throws {
    try await run(.immediate) { store.history.clear(on: try standaloneDisplayID(display)) }
  }

  // MARK: Saved playlists

  /// `playlistPlanSave`: a named copy of `display`'s playlist. Names follow the collections' rule.
  @discardableResult
  func savePlaylistPlan(name: String, display: String? = nil) async throws -> PlaylistPlan {
    var saved: PlaylistPlan?
    try await run(.immediate) {
      saved = try playlists.savePlan(from: try standaloneDisplayID(display), name: name)
    }
    guard let saved else { throw CancellationError() }
    return saved
  }

  /// `playlistPlanRename`.
  func renamePlaylistPlan(_ id: String, to name: String) async throws {
    try await run(.immediate) { try playlists.renamePlan(id, name: name) }
  }

  /// `playlistPlanDelete`. Displays that run a copy keep their playlist; only the link is gone. An
  /// automatic rule that targeted the plan stays and reads as unavailable.
  func deletePlaylistPlan(_ id: String) async throws {
    try await run(.immediate) {
      try playlists.deletePlan(id)
      try automations.forgetPlan(id)
    }
  }

  /// `playlistPlanApply`: the display takes a copy of the plan and the scheduler runs it, waiting
  /// for the display to present again. Takes the display's turn in the activation queue, like a
  /// wallpaper switch, and counts as a manual choice for the automatic selection.
  func applyPlaylistPlan(_ id: String, display: String? = nil) async throws {
    let display = try standaloneDisplayID(display)
    try await run(.immediateQueued, slot: BridgeStore.activationSlot(displayId: display)) {
      _ = try standaloneDisplayID(display)
      try WallpaperAutomationController.applyPlaylist(
        id, to: display, playlists: playlists, collections: collections)
      automations.manualChoice?(display)
    }
  }

  // MARK: Helpers

  /// Resolves the display once, then edits its playlist in a queue turn of its own. The display is
  /// checked again when the turn comes: an edit queued behind a switch must not reach a display that
  /// has stopped being independent meanwhile.
  private func changePlaylist(
    _ display: String?, _ change: @MainActor (String) throws -> Void
  ) async throws {
    let display = try standaloneDisplayID(display)
    try await run(.immediateQueued) {
      _ = try standaloneDisplayID(display)
      try change(display)
      automations.manualChoice?(display)
    }
  }

  /// The refusals that depend on the edit alone: a value no control offers, before it waits for the
  /// queue.
  private func validate(_ edit: PlaylistEdit) throws {
    if case .interval(let choice) = edit, !choice.isOffered { throw InvalidControlValue() }
  }

  /// The edit itself, inside the queue turn: the refusals that depend on the library and on the
  /// collections as they are when the turn comes.
  private func apply(_ edit: PlaylistEdit, to display: String) throws {
    switch edit {
    case .mode(let mode):
      playlists.update(display) { $0.mode = mode }
    case .source(let source):
      if source == .collection {
        guard let id = playlists.playlist(for: display).collectionID, collections.collection(id: id) != nil else {
          throw LibraryOrganizationError.missingCollection
        }
      }
      playlists.update(display) { $0.source = source }
    case .collection(let id):
      guard collections.collection(id: id) != nil else { throw LibraryOrganizationError.missingCollection }
      playlists.update(display) {
        $0.collectionID = id
        $0.source = .collection
      }
    case .order(let order):
      playlists.update(display) { $0.order = order }
    case .interval(.unlock):
      playlists.update(display) { $0.trigger = .unlock }
    case .interval(.preset(let minutes)), .interval(.custom(let minutes)):
      // Choosing a time is choosing to change on a timer again.
      playlists.update(display) {
        $0.interval = minutes
        $0.trigger = .interval
      }
    case .dayWallpaper(let id):
      let id = try playableWallpaperID(id)
      playlists.update(display) { $0.dayWallpaperID = id }
    case .nightWallpaper(let id):
      let id = try playableWallpaperID(id)
      playlists.update(display) { $0.nightWallpaperID = id }
    case .dayStart(let start):
      playlists.update(display) { $0.dayStart = start.minutes }
    case .nightStart(let start):
      playlists.update(display) { $0.nightStart = start.minutes }
    }
  }

  /// nil, which clears the choice, or an installed wallpaper that can play.
  private func playableWallpaperID(_ id: String?) throws -> String? {
    guard let id else { return nil }
    guard store.librarySnapshot.wallpapers.contains(where: { $0.id == id && $0.supported }) else {
      throw InvalidControlValue()
    }
    return id
  }
}
