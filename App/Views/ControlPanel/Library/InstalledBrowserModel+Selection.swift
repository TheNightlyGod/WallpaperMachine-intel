import AppKit
import Foundation
import SwiftUI

/// Clicks, ticks and the batch actions on the ticked wallpapers.
extension InstalledBrowserModel {
  // MARK: What is selected

  /// The ticked wallpapers that are still installed, in the order they were ticked. A wallpaper
  /// that left the library is not counted or sent, whether or not `pruneSelection()` has run.
  var selectedIDs: [String] {
    _ = controller.libraryRows
    return selection.ids.filter { controller.libraryRowsCache.row(id: $0) != nil }
  }

  func isChecked(_ id: String) -> Bool { selection.contains(id) }

  /// Drops members that left the library, and the anchor with them. The page runs it whenever the
  /// library changes, and as it appears.
  func pruneSelection() {
    _ = controller.libraryRows
    selection.prune { controller.libraryRowsCache.row(id: $0) != nil }
  }

  // MARK: Clicks

  /// A click on a tile, as the tile's gesture reports it: how many clicks it is is worked out here
  /// from the clicks before it, since no SwiftUI gesture says it. `modifiers` are the keys held.
  func tileClicked(_ id: String, modifiers: NSEvent.ModifierFlags) {
    tileClicked(id, clickCount: clickCount(for: id), modifiers: modifiers)
  }

  /// The count of the click on `id` just made: 2 for a click that follows another on the same tile
  /// within the system's double-click time, else 1. A third click starts over, as a single one.
  func clickCount(for id: String) -> Int {
    let now = clock()
    if let last = lastClick, last.id == id,
      now.timeIntervalSince(last.time) <= doubleClickInterval()
    {
      lastClick = nil
      return 2
    }
    lastClick = (id, now)
    return 1
  }

  /// A click on a tile. A plain click chooses the wallpaper for the inspector and applies
  /// nothing; the second click of a double click applies it; a modifier or selection mode ticks
  /// it. The click that ends a sweep is swallowed: the press already did its work.
  func tileClicked(_ id: String, clickCount: Int, modifiers: NSEvent.ModifierFlags) {
    if swallowsClick || sweep?.isPainting == true {
      swallowsClick = false
      return
    }
    switch LibraryTileClick.resolve(
      clickCount: clickCount, modifiers: modifiers, isSelecting: isSelecting)
    {
    case .select: select(id)
    case .activate: activate(id)
    case .toggle: selection.toggle(id)
    case .extendRange: selection.toggle(id, range: true, visible: visibleIDs)
    }
  }

  /// Return or Space on the focused tile: a click with no modifiers.
  func tileActivated(_ id: String) { tileClicked(id, clickCount: 0, modifiers: []) }

  /// The check on a tile: ticks or unticks it, never extends a range. A check held long enough to
  /// start a sweep has already ticked its tile, and the click that ends the press is swallowed.
  func toggleChecked(_ id: String) {
    if swallowsClick || sweep?.isPainting == true {
      swallowsClick = false
      return
    }
    selection.toggle(id)
  }

  @discardableResult
  func select(_ id: String) -> Task<Void, Never> {
    controller.launch(PanelActionCoordinator.key("select", id: id)) { [controller] in
      try await controller.select(id)
    }
  }

  @discardableResult
  func activate(_ id: String) -> Task<Void, Never> {
    controller.launch(PanelActionCoordinator.key("activate", id: id)) { [controller] in
      try await controller.activate(id)
    }
  }

  @discardableResult
  func toggleFavorite(_ id: String) -> Task<Void, Never> {
    controller.launch(PanelActionCoordinator.key("favorite", id: id)) { [controller] in
      try await controller.toggleFavorite(id)
    }
  }

  // MARK: Selection mode

  /// The Select button. Leaving selection mode puts the selection away.
  func toggleSelecting() {
    isSelecting.toggle()
    if !isSelecting {
      selection.clear()
      newCollectionName = nil
    }
  }

  /// Select all ticks every tile on screen, not the ones a filter hides.
  func selectAllVisible() { selection.selectAll(visible: visibleIDs) }

  /// Clear: unticks everything and stays in selection mode.
  func clearSelection() {
    selection.clear()
    newCollectionName = nil
  }

  /// Escape on the grid: ends a sweep, else cancels a collection name being typed, else leaves
  /// selection mode with the selection. Returns whether it did anything, so a press with nothing
  /// to do goes on to whatever else wants it.
  @discardableResult
  func escape() -> Bool {
    if sweep != nil {
      endSweep()
      return true
    }
    if newCollectionName != nil {
      newCollectionName = nil
      return true
    }
    guard isSelecting || !selection.isEmpty else { return false }
    selection.clear()
    isSelecting = false
    return true
  }

  // MARK: Batch actions

  /// Add to playlist needs a target display that has a playlist of its own: enabled, and not a
  /// mirror.
  var canAddSelectionToPlaylist: Bool {
    controller.targetDisplay?.isSelectable == true
      && !controller.isBusy(PanelActionCoordinator.key("playlistAdd"))
  }

  /// Appends the ticked wallpapers to the target display's playlist. The selection stays.
  @discardableResult
  func addSelectionToPlaylist() -> Task<Void, Never>? {
    let ids = selectedIDs
    guard !ids.isEmpty, canAddSelectionToPlaylist else { return nil }
    return controller.launch(PanelActionCoordinator.key("playlistAdd")) { [controller] in
      try await controller.addToPlaylist(ids)
    }
  }

  /// Whether Move to Trash can run now: not while the renderer is busy applying something, and not
  /// twice at once.
  var canTrash: Bool {
    !controller.isStoreBusy && !controller.isBusy(PanelActionCoordinator.key("deleteMany"))
  }

  /// Moves the ticked wallpapers to the Trash, after the confirmation sheet names how many.
  @discardableResult
  func trashSelection() -> Task<Void, Never>? { trash(selectedIDs) }

  /// Delete or Backspace on the grid: the ticked wallpapers if any are ticked (whether or not the
  /// focused tile is one of them), else the focused tile. Returns whether the key was taken.
  func deleteSelectionOrFocused() -> Bool {
    let ids = selectedIDs
    let target = ids.isEmpty ? focusedID.map { [$0] } ?? [] : ids
    return trash(target) != nil
  }

  private func trash(_ ids: [String]) -> Task<Void, Never>? {
    guard !ids.isEmpty, canTrash else { return nil }
    return controller.launch(PanelActionCoordinator.key("deleteMany")) { [controller] in
      try await controller.deleteMany(ids)
    }
  }

  /// Update N wallpapers: downloads the new versions the Workshop has.
  @discardableResult
  func updateAll() -> Task<Void, Never> {
    controller.launch(PanelActionCoordinator.key("workshopUpdateAll")) { [controller] in
      try await controller.updateAllWorkshopItems()
    }
  }

  /// Refresh library: reads everything again and rescans.
  @discardableResult
  func refreshLibrary() -> Task<Void, Never> {
    controller.launch(PanelActionCoordinator.key("refresh")) { [controller] in
      try await controller.refresh()
    }
  }

  // MARK: Collections

  /// Whether a collection change is under way, which holds the collection controls: one of the
  /// bar's own, or a rename or delete from the filters panel, which the bar's tools wait for as well.
  var isChangingCollection: Bool {
    let keys = [
      PanelActionCoordinator.key("collectionAdd"), PanelActionCoordinator.key("collectionRemove"),
      CollectionEditorModel.createKey, CollectionEditorModel.renameKey,
      CollectionEditorModel.deleteKey,
    ]
    return keys.contains { controller.isBusy($0) }
  }

  /// The longest collection name the store takes; the field stops there, as the web panel's did.
  static let collectionNameLimit = 128

  /// Adds the ticked wallpapers to `collection` and says how many. The selection stays.
  @discardableResult
  func addSelection(to collection: CollectionRow) -> Task<Void, Never>? {
    let ids = selectedIDs
    guard !ids.isEmpty else { return nil }
    return controller.launch(PanelActionCoordinator.key("collectionAdd")) { [controller] in
      try await controller.addToCollection(collection.id, wallpaperIDs: ids)
      self.say(Self.addedNotice(count: ids.count, name: collection.name))
    }
  }

  /// Begins typing the name of a new collection made from the ticked wallpapers. The window has one
  /// collection name field at a time, so the filters panel's closes (and the panel's, opening, closes
  /// this one: `CollectionEditorModel`).
  func beginNewCollection() {
    guard !selection.isEmpty else { return }
    controller.shell.collectionEditor.cancel()
    newCollectionName = ""
  }

  func setNewCollectionName(_ name: String) {
    guard newCollectionName != nil else { return }
    newCollectionName = String(name.prefix(Self.collectionNameLimit))
  }

  func cancelNewCollection() { newCollectionName = nil }

  /// Makes the collection from the ticked wallpapers. A blank name does nothing, and the field
  /// stays for another try; a name the store refuses reaches the banner and leaves the field too.
  @discardableResult
  func createCollectionFromSelection() -> Task<Void, Never>? {
    guard let name = newCollectionName?.trimmingCharacters(in: .whitespacesAndNewlines),
      !name.isEmpty
    else { return nil }
    let ids = selectedIDs
    guard !ids.isEmpty else { return nil }
    let typed = newCollectionName
    return controller.launch(PanelActionCoordinator.key("collectionCreate")) { [controller] in
      let created = try await controller.createCollection(name: name, wallpaperIDs: ids)
      // The field closes only if it is still the one that was submitted.
      if self.newCollectionName == typed { self.newCollectionName = nil }
      self.say(Self.addedNotice(count: ids.count, name: created.name))
    }
  }

  /// Whether Remove from the shown collection has anyone to remove: some ticked wallpaper is in it.
  var canRemoveSelectionFromCollection: Bool {
    guard let collection = shownCollection else { return false }
    let members = Set(collection.wallpaperIDs)
    return selection.ids.contains(where: members.contains) && !isChangingCollection
  }

  /// Takes the ticked wallpapers out of the collection on show.
  @discardableResult
  func removeSelectionFromShownCollection() -> Task<Void, Never>? {
    guard let collection = shownCollection else { return nil }
    let ids = selection.ids
    guard !ids.isEmpty else { return nil }
    return controller.launch(PanelActionCoordinator.key("collectionRemove")) { [controller] in
      try await controller.removeFromCollection(collection.id, wallpaperIDs: ids)
      self.say(Self.removedNotice(count: ids.count, name: collection.name))
    }
  }

  private static func addedNotice(count: Int, name: String) -> String {
    count == 1
      ? L("Added 1 wallpaper to “\(name)”.") : L("Added \(count) wallpapers to “\(name)”.")
  }

  private static func removedNotice(count: Int, name: String) -> String {
    count == 1
      ? L("Removed 1 wallpaper from “\(name)”.")
      : L("Removed \(count) wallpapers from “\(name)”.")
  }

  /// Shows `text` beside the selection's tools for five seconds, and has VoiceOver read it.
  func say(_ text: String) {
    notice = text
    announce(text)
    noticeTask?.cancel()
    noticeTask = Task { [weak self] in
      guard let sleep = self?.sleep else { return }
      do { try await sleep(.seconds(5)) } catch { return }
      self?.notice = nil
    }
  }
}
