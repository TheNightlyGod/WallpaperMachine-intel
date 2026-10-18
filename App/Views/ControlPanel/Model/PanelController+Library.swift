import Foundation

/// The library's actions: choosing and applying wallpapers, favorites, refreshing, playback, the
/// target display, the preview window and the crash-loop holds.
extension PanelController {
  // MARK: Choosing and applying

  /// `select`: queued in the selection slot, which is what loads the inspector's options. Only the
  /// newest waiting selection runs: a newer click replaces one still waiting, and nothing the user
  /// asked for fails for being early.
  func select(_ id: String) async throws {
    let id = try installedWallpaperID(id)
    try await run(.queued, slot: BridgeStore.selectionSlot, subject: id) {
      try await store.selectWallpaperAsync(id: id)
    }
  }

  /// `activate`: applies a wallpaper to the target display. Applying what a display already shows
  /// does nothing; only `reapply` restarts it, so a double-click, Recently used and Previous keep
  /// leaving a running wallpaper alone. A scene while the shared resources are missing opens their
  /// setup instead (`getsSceneResourcesInstead(of:)`), as `reapply` and `activateAll` do.
  func activate(_ id: String) async throws { try await applyToTarget(id, restarts: false) }

  /// `reapplyWallpaper`: the inspector's Reapply wallpaper, which takes the wallpaper off the
  /// display and loads it afresh (or applies it plainly when the display does not show it).
  func reapply(_ id: String) async throws { try await applyToTarget(id, restarts: true) }

  /// `activateAll`: one wallpaper on every enabled independent display. The transfer takes its
  /// own turn in the queue, so it must not run inside `run(.queued)`; it rolls every display back
  /// when one fails, and says so. A failure leaves the wallpaper selected, where its note is.
  func activateAll(_ id: String) async throws {
    if try await getsSceneResourcesInstead(of: id) { return }
    do {
      try await run(.direct) {
        let id = try installedWallpaperID(id)
        try await store.activateWallpaperEverywhereAsync(id: id)
        if hidesAfterActivating, duePrompt == nil, !store.commands.isBusy {
          hideApplication()
        }
      }
      activationFailures[id] = nil
    } catch {
      recordActivationFailure(error, for: id)
      // Putting the displays back selects the wallpapers they showed; stay on the one that failed.
      if !(error is CancellationError) { try? await select(id) }
      throw error
    }
  }

  /// `previousWallpaper`: the wallpaper the display showed before, in the display's switch slot.
  /// Repeated presses continue backward. `displayID` is the target display when it names none.
  func previousWallpaper(displayID: String? = nil) async throws {
    let displayID = try standaloneDisplayID(displayID)
    try await run(.queued, slot: BridgeStore.activationSlot(displayId: displayID)) {
      try await store.activatePreviousWallpaperAsync(displayId: displayID)
    }
  }

  /// `nextWallpaper`, the Next wallpaper shortcut's rule: a rotating playlist moves along with a
  /// fresh interval, anything else takes the library's next supported wallpaper, measured from
  /// what the display shows when the switch gets its turn.
  func nextWallpaper(displayID: String? = nil) async throws {
    let displayID = try standaloneDisplayID(displayID)
    guard playlists.playlist(for: displayID).mode == .rotate else {
      try await run(.queued, slot: BridgeStore.activationSlot(displayId: displayID)) {
        guard let id = store.nextWallpaperID(displayId: displayID) else { return }
        try await store.activateWallpaperAsync(id: id, displayId: displayID, origin: .user)
      }
      return
    }
    try await run(.direct) {
      guard playlists.skipHandler?(displayID) == true else {
        throw WallpaperActionError(
          message: L("This display’s playlist has no other wallpaper to change to."))
      }
    }
  }

  /// Applies or restarts `id` on the display targeted *now*, which is the one the user means:
  /// the command may wait behind others, and the target can change in the meantime.
  private func applyToTarget(_ id: String, restarts: Bool) async throws {
    if try await getsSceneResourcesInstead(of: id) { return }
    do {
      let id = try installedWallpaperID(id)
      let displayID = navigation.targetDisplayID
      let slot = BridgeStore.activationSlot(displayId: displayID)
      let ran = try await run(.queued, slot: slot, subject: id) {
        if restarts {
          try await store.reapplyWallpaperAsync(id: id, displayId: displayID)
        } else {
          try await store.activateWallpaperAsync(id: id, displayId: displayID, origin: .user)
        }
        // Get out of the way so the freshly applied wallpaper is visible, unless another switch
        // is already waiting to replace it.
        if hidesAfterActivating, duePrompt == nil,
          !store.commands.hasWaiting(slot: slot)
        {
          hideApplication()
        }
      }
      // A command replaced while it waited applied nothing, so it clears no failure either.
      if ran { activationFailures[id] = nil }
    } catch {
      recordActivationFailure(error, for: id)
      throw error
    }
  }

  /// A scene cannot play without Wallpaper Engine's shared resources, and while they are missing
  /// applying one is the way into their one-time setup: the request for them is made (the download
  /// dialog opens on what it needs, or their running download is shown) and the renderer is not
  /// asked for a failure the user could only report. They are looked for again first, in case
  /// they were installed meanwhile. Returns whether it did so; anything but an installed scene
  /// that macOS can play is left to the apply.
  private func getsSceneResourcesInstead(of id: String) async throws -> Bool {
    guard let row = libraryRow(id: id), row.kind == .scene, row.isSupported else { return false }
    workshop.refreshSceneAssetsReadiness()
    guard workshopSceneAssetsAreMissing(for: row) else { return false }
    // The notice that offers the resources says why it cannot play now.
    activationFailures[id] = nil
    try await getSceneResources()
    return true
  }

  /// Keeps why Apply last failed for `id`, which the inspector and the tile show with a report
  /// link until an apply of that wallpaper succeeds. A cancellation is the window going away.
  private func recordActivationFailure(_ error: Error, for id: String) {
    guard !(error is CancellationError) else { return }
    activationFailures[id] = error.localizedDescription
  }

  // MARK: Favorites and Finder

  /// `favorite`: a direct action. Neither favoriting nor revealing touches the renderer, so
  /// neither waits behind a command that does. The key is shared with the Random Wallpaper pool
  /// and the playlists' favorites source, and is written at once.
  func toggleFavorite(_ id: String) async throws {
    try await run(.direct) {
      let id = try installedWallpaperID(id)
      if !favoriteIDs.insert(id).inserted { favoriteIDs.remove(id) }
      try PanelPreferences.saveFavorites(favoriteIDs, in: defaults)
    }
  }

  /// Drops deleted wallpapers from the favorites.
  func forgetFavorites(_ ids: [String]) throws {
    guard ids.contains(where: favoriteIDs.contains) else { return }
    favoriteIDs.subtract(ids)
    try PanelPreferences.saveFavorites(favoriteIDs, in: defaults)
  }

  /// `reveal`: selects the wallpaper's folder in Finder.
  func reveal(_ id: String) async throws {
    try await run(.direct) {
      revealInFinder([ClientPaths.libraryURL.appendingPathComponent(try installedWallpaperID(id))])
    }
  }

  // MARK: Refresh, playback and target

  /// `refresh`: reads every snapshot again, then rescans the library. A failed rescan shows in the
  /// banner until it is dismissed or happens again.
  func refresh() async throws {
    try await run(.queued) {
      try await store.refreshAllAsync()
      try await store.refreshLibraryAsync()
    }
  }

  /// `playback`: pauses every display, or resumes them all when playback is paused.
  func togglePlayback() async throws {
    try await run(.queued) {
      if store.appSnapshot.playbackState == .paused {
        try await store.playAllAsync()
      } else {
        try await store.pauseAllAsync()
      }
    }
  }

  /// `target`: sets the display that Apply, Now Playing, the history and the cards of the
  /// inspector act on. Only an enabled display that shows its own wallpaper is accepted, checked
  /// when the command's turn comes. A view sends it with `.latestWins` under the key "target".
  func setTargetDisplay(_ displayID: String) async throws {
    try await run(.queued) {
      navigation.targetDisplayID = try standaloneDisplayID(displayID)
    }
  }

  // MARK: Preview window

  /// `previewWallpaper`: opens a preview of the wallpaper on the target display with the text the
  /// user typed and did not send yet, changing nothing on the desktop. Browsing, so it leaves an
  /// older banner showing; it waits in the "preview" slot, where a newer request replaces one still
  /// waiting. `textOverrides` is limited to 1,000 entries and 1 MiB of text.
  func previewWallpaper(_ id: String, textOverrides: [String: String] = [:]) async throws {
    let id = try installedWallpaperID(id)
    guard let preview = store.openPreview, isSupportedWallpaper(id),
      textOverrides.count <= 1_000,
      textOverrides.values.reduce(0, { $0 + $1.utf8.count }) <= 1024 * 1024
    else { throw InvalidControlValue() }
    let selection = WallpaperPreviewSession.Selection(
      wallpaperID: id, displayID: navigation.targetDisplayID, textOverrides: textOverrides)
    try await run(.immediateQueued, slot: "preview", subject: id) {
      guard isSupportedWallpaper(id) else { throw InvalidControlValue() }
      preview(selection)
    }
  }

  private func isSupportedWallpaper(_ id: String) -> Bool {
    store.librarySnapshot.wallpapers.contains { $0.id == id && $0.supported }
  }

  // MARK: Held wallpapers and the web host

  /// `releaseHeld`: Try again on a wallpaper the load journal held back after the app died twice
  /// while loading it. Only a held wallpaper can be released; anything else is a stale row. A
  /// refusal reaches the banner and the held row stays.
  func releaseHeld(_ id: String) async throws {
    let id = try installedWallpaperID(id)
    guard store.heldWallpaperIDs.contains(id) else { throw InvalidControlValue() }
    try await run(.immediateQueued, subject: id) {
      try await store.releaseHeldWallpaperAsync(id: id)
    }
  }

  /// `retryHostWallpaper`: reloads a web wallpaper whose page failed on one display. Only a failed,
  /// retryable web surface is accepted, so a row from before the host changed is refused.
  func retryHostWallpaper(_ id: String, on displayID: UInt32) async throws {
    try await run(.immediate) {
      let id = try installedWallpaperID(id)
      guard
        store.hostWallpaperStates.values.contains(where: {
          $0.kind == .web && $0.wallpaperID == id && $0.displayID == displayID
            && $0.phase == .failed && $0.canRetry
        })
      else { throw InvalidControlValue() }
      store.retryHostWallpaper?(id, displayID)
    }
  }
}
