import Foundation

/// The saved display layouts as Settings › Displays lists them.
struct DisplayLayoutsState: Equatable, Sendable {
  /// Why the saved layouts could not be read, when they could not.
  let loadError: String?
  /// How many layouts the store keeps.
  let limit: Int
  /// Whether the displays as they are now hold something a layout can save: an enabled independent
  /// display with a wallpaper, and an arrangement that is not in flux.
  let canSave: Bool
  let layouts: [Layout]

  /// The limit is reached: Save is disabled and a note says so.
  var isFull: Bool { layouts.count >= limit }

  struct Layout: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    /// Why the layout cannot be applied now (a display or a wallpaper is gone), or nil. An
    /// unavailable layout stays listed, with this reason and no Apply.
    let unavailableReason: String?
    let assignments: [Assignment]
  }

  struct Assignment: Equatable, Sendable {
    let displayID: String
    /// The display's title now, resolved the way the displays list is.
    let displayTitle: String
    let wallpaperID: String
    /// The wallpaper's title in the library, or its id when the library no longer has it.
    let wallpaperTitle: String
  }
}

extension PanelController {
  // MARK: Derived state

  /// The saved layouts, each checked against the displays and the library as they are now.
  var displayLayoutsState: DisplayLayoutsState {
    _ = revisions.displayLayouts
    let current = store.displayTransferSnapshot()
    let titles = displayTitles.resolved()
    // One pass over the library for the titles the layouts name, not one search per assignment.
    let named = Set(displayLayouts.layouts.flatMap { $0.assignments.map(\.wallpaperID) })
    var libraryTitles: [String: String] = [:]
    if !named.isEmpty {
      for wallpaper in store.librarySnapshot.wallpapers where named.contains(wallpaper.id) {
        libraryTitles[wallpaper.id] = wallpaper.title
      }
    }
    return DisplayLayoutsState(
      loadError: displayLayouts.loadError, limit: WallpaperDisplayLayoutStore.limit,
      canSave: (try? WallpaperDisplayTransfer.capture(current)) != nil,
      layouts: displayLayouts.layouts.map { layout in
        let unavailable: String?
        do {
          try WallpaperDisplayTransfer.validate(layout.assignments, in: current)
          unavailable = nil
        } catch {
          unavailable = error.localizedDescription
        }
        return DisplayLayoutsState.Layout(
          id: layout.id, name: layout.name, unavailableReason: unavailable,
          assignments: layout.assignments.map { value in
            DisplayLayoutsState.Assignment(
              displayID: value.displayID,
              displayTitle: titles.title(value.displayTitle, displayId: value.displayID),
              wallpaperID: value.wallpaperID,
              wallpaperTitle: libraryTitles[value.wallpaperID] ?? value.wallpaperID)
          })
      })
  }

  // MARK: Actions

  /// `displayLayoutSave`: the wallpapers the enabled independent displays show now, under `name`.
  /// The arrangement is captured when the command's turn comes, so it is what the displays show then,
  /// with each title resolved as the list shows it. Refused at the store's limit of layouts.
  @discardableResult
  func saveDisplayLayout(name: String) async throws -> WallpaperDisplayLayout {
    var saved: WallpaperDisplayLayout?
    try await run(.immediateQueued) {
      let titles = displayTitles.resolved()
      let assignments = try WallpaperDisplayTransfer.capture(store.displayTransferSnapshot()).map { value in
        var value = value
        value.displayTitle = titles.title(value.displayTitle, displayId: value.displayID)
        return value
      }
      saved = try displayLayouts.save(name: name, assignments: assignments)
    }
    guard let saved else { throw CancellationError() }
    return saved
  }

  /// `displayLayoutRename`.
  func renameDisplayLayout(_ id: String, to name: String) async throws {
    try await run(.immediate) { try displayLayouts.rename(id, name: name) }
  }

  /// `displayLayoutDelete`. The wallpapers on the displays stay as they are.
  func deleteDisplayLayout(_ id: String) async throws {
    try await run(.immediate) { try displayLayouts.delete(id) }
  }

  /// `displayLayoutApply`: gives every display of the layout its wallpaper, or none of them. All the
  /// targets are checked first, and a failure puts the displays back. The transfer takes its own
  /// turn in the command queue, so it is not queued here.
  func applyDisplayLayout(_ id: String) async throws {
    try await run(.immediate) {
      let layout = try displayLayouts.layout(id)
      try await store.applyDisplayTransferAsync(.layout(layout.assignments))
    }
  }

  /// `displayCopyWallpaper`: `target` shows what `source` shows; `source` is unchanged and `target`
  /// may be empty.
  func copyWallpaper(from source: String, to target: String) async throws {
    try await run(.immediate) {
      try await store.applyDisplayTransferAsync(.copy(from: source, to: target))
    }
  }

  /// `displaySwapWallpapers`: the two displays exchange wallpapers. Both must show one. No display
  /// receives half of the swap.
  func swapWallpapers(_ first: String, _ second: String) async throws {
    try await run(.immediate) {
      try await store.applyDisplayTransferAsync(.swap(first, second))
    }
  }
}
