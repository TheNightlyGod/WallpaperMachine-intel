import Foundation

/// What the library, the tabs and the banners read: the Installed rows, selection and apply
/// state, history, host states, held wallpapers and the import. Each getter reads the counter of
/// every store SwiftUI cannot observe before the store itself (`PanelStoreRevisions`), so a view
/// that calls it is told when the answer changes.
extension PanelController {
  // MARK: Installed rows

  /// Every installed wallpaper, in the renderer's library order. Rebuilt only when an input of the
  /// rows moved (see `LibraryRowsCache`), so a selection, a playback change or a download tick
  /// costs nothing, whatever the library's size. Sorting, filtering and searching are the library
  /// browser's, over this array.
  ///
  /// The first read after the library changed also asks the background services for the sizes,
  /// tags and cover stamps of wallpapers they have not measured: the rows are rebuilt once those
  /// land.
  var libraryRows: [LibraryRow] {
    libraryRowsCache.rows(for: libraryRowsKey) { buildLibraryRows() }
  }

  /// The row of one installed wallpaper, nil when it is not in the library.
  func libraryRow(id: String) -> LibraryRow? {
    _ = libraryRows
    return libraryRowsCache.row(id: id)
  }

  private var libraryRowsKey: LibraryRowsCache.Key {
    // The services report through closures, so their counters are read first for observation.
    _ = revisions.libraryMetrics
    _ = revisions.libraryCovers
    _ = revisions.navigation
    _ = revisions.language
    return LibraryRowsCache.Key(
      content: store.libraryPresentationRevision, refresh: store.libraryRefreshRevision,
      metrics: libraryMetrics.contentRevision, covers: libraryCovers.contentRevision,
      updates: workshop.updates.availableRevision,
      // Nothing announces a new rating: one earned in the background shows with the next change
      // of anything above, as it did before.
      energy: store.wallpaperEnergyRatings?.revision ?? 0,
      target: navigation.targetDisplayID, language: appLanguage.effective.tag)
  }

  private func buildLibraryRows() -> [LibraryRow] {
    let entries = store.librarySnapshot.wallpapers
    let refresh = store.libraryRefreshRevision
    let previews = Dictionary(
      entries.compactMap { entry in entry.previewPath.map { (entry.id, URL(fileURLWithPath: $0)) } },
      uniquingKeysWith: { first, _ in first })
    // Both are read in the background and only asked here: this call is what queues a new or
    // changed wallpaper for measurement.
    let covers = libraryCovers.stamps(for: previews, revision: refresh)
    let metrics = libraryMetrics.metrics(for: entries.map(\.id), revision: refresh)
    let updates = workshop.updates.available
    let target = navigation.targetDisplayID
    let ratings = store.wallpaperEnergyRatings
    return entries.map { entry in
      LibraryRow.make(
        entry, isActive: store.isWallpaperActive(id: entry.id, displayId: target), covers: covers,
        metrics: metrics[entry.id], update: updates[entry.id],
        energy: ratings?.snapshot(for: entry.id, kind: entry.kind))
    }
  }

  // MARK: Selection and apply state

  /// The wallpaper the inspector shows.
  var selectedWallpaperID: String? { store.appSnapshot.selectedWallpaperId }

  var isPlaybackPaused: Bool { store.appSnapshot.playbackState == .paused }

  /// The wallpaper being switched to, which its tile marks with the Applying ring.
  var applyingWallpaperID: String? { store.activatingWallpaperID ?? store.applyingWallpaperID }

  /// The wallpapers whose switch waits behind the running command, oldest first. Waiting is shown
  /// as progress, never as an error.
  var queuedApplyIDs: [String] { store.waitingActivationIDs }

  /// The library is being read for the first time or rescanned.
  var isLibraryLoading: Bool { store.libraryLoadState == .loading }

  /// Whether the preview window exists to open (it does not in a headless run).
  var previewAvailable: Bool { store.openPreview != nil }

  /// What the target display showed before.
  var libraryHistory: LibraryHistory {
    let target = targetDisplayID
    return LibraryHistory(
      recentIDs: store.history.recent(on: target, available: supportedWallpaperIDs),
      previousID: store.previousWallpaperID(displayId: target))
  }

  private var supportedWallpaperIDs: Set<String> {
    Set(store.librarySnapshot.wallpapers.lazy.filter(\.supported).map(\.id))
  }

  /// The problem report of an installed wallpaper: GitHub's bug report form with the app version and
  /// the backend drawing it, and `failure` when applying it just failed. Nil for a wallpaper that
  /// is not installed or when the repository address cannot carry the draft.
  func issueReportURL(for id: String, failure: String? = nil) -> URL? {
    guard let row = libraryRow(id: id) else { return nil }
    return LibraryIssueReport.url(
      for: row, failure: failure,
      renderers: LibraryIssueReport.renderers(for: id, in: store.settingsSnapshot))
  }

  // MARK: Host states and held wallpapers

  /// Every web page and native video the host reports on, ordered by their key.
  var hostStates: [HostStateRow] {
    let titles = displayTitles.resolved()
    let monitors = store.monitorInformationSnapshot.rows
    let canRetry = store.retryHostWallpaper != nil
    return store.hostWallpaperStates.values.sorted { $0.key < $1.key }.map { state in
      let monitor = monitors.first {
        ResolvedDisplayTitles.liveDisplayID($0.displayId, title: $0.title) == state.displayID
      }
      return HostStateRow(
        id: state.key, wallpaperID: state.wallpaperID, displayID: state.displayID,
        displayTitle: monitor.map { titles.title($0.title, displayId: $0.displayId) }
          ?? String(state.displayID),
        kind: state.kind, phase: state.phase, message: state.message,
        canRetry: state.kind == .web && state.phase == .failed && state.canRetry && canRetry)
    }
  }

  /// The inspector lists the states of the wallpaper it shows only.
  func hostStates(for wallpaperID: String) -> [HostStateRow] {
    hostStates.filter { $0.wallpaperID == wallpaperID }
  }

  /// The wallpapers the load journal held back, each with the sentence its banner row shows.
  var heldWallpapers: [HeldWallpaperRow] {
    store.heldWallpaperIDs.map { id in
      let title = store.librarySnapshot.wallpapers.first { $0.id == id }?.title ?? id
      return HeldWallpaperRow(id: id, title: title, message: HeldWallpaperRow.message(title: title))
    }
  }

  // MARK: Import

  /// The app's import, as the pill and the popover show it.
  var importState: LibraryImportState {
    LibraryImportState(
      isBusy: imports.isBusy, status: imports.status,
      report: imports.report.map {
        LibraryImportState.Report(
          imported: $0.importedIDs.count, skipped: $0.skipped.count, failures: $0.failures,
          cancelled: $0.cancelled)
      })
  }

  // MARK: Target display and Now Playing

  /// Every display, for the target picker: all are listed, only an enabled one that shows its own
  /// wallpaper can be chosen.
  var targetDisplays: [TargetDisplayOption] {
    let titles = displayTitles.resolved()
    let monitors = store.monitorInformationSnapshot.rows
    return store.settingsSnapshot.displays.map { display in
      let wallpaperID = monitors.first { $0.displayId == display.displayId }?.wallpaperId
      return TargetDisplayOption(
        id: display.displayId, title: titles.title(display.title, displayId: display.displayId),
        isEnabled: display.enabled, isMirror: display.mode == .mirror,
        wallpaperID: wallpaperID.flatMap { $0.isEmpty ? nil : $0 })
    }
  }

  /// The target display; nil if it disappeared from the list.
  var targetDisplay: TargetDisplayOption? {
    let id = targetDisplayID
    return targetDisplays.first { $0.id == id }
  }

  /// The Now Playing card.
  var nowPlaying: NowPlayingState {
    let displays = targetDisplays
    let id = targetDisplayID
    let target = displays.first { $0.id == id }
    return NowPlayingState.make(
      target: target, item: target?.wallpaperID.flatMap(libraryRow(id:)),
      hasWallpaper: displays.contains { $0.wallpaperID != nil },
      hasOtherWallpaper: store.librarySnapshot.wallpapers.contains {
        $0.supported && $0.id != target?.wallpaperID
      },
      previousID: store.previousWallpaperID(displayId: id), isPaused: isPlaybackPaused,
      isBusy: isStoreBusy)
  }

  // MARK: Sidebar

  /// The counts of the Library and Collections items.
  var sidebarCounts: SidebarCounts {
    _ = revisions.collections
    let wallpapers = store.librarySnapshot.wallpapers
    let installed = favoriteIDs.isEmpty ? [] : Set(wallpapers.lazy.map(\.id))
    return SidebarCounts(
      all: wallpapers.count, favorites: favoriteIDs.intersection(installed).count,
      updates: workshop.updates.available.count,
      collections: collections.collections.map {
        .init(id: $0.id, name: $0.name, count: $0.wallpaperIDs.count)
      })
  }
}
