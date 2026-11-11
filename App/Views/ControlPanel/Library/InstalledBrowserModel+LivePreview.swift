import AppKit
import Foundation

/// The Installed grid's animated previews, played one of two ways.
///
/// By default every tile on screen plays its animation, as the Workshop's grid does:
/// `LivePreviewScheduler` keeps the books, at most six animations load at once and in grid order, and
/// a tile that scrolls away, a hidden window and leaving the page release their animation. A
/// preview that is a single picture, or over the animation budget, keeps its cover and is not asked
/// again by scrolling. Only the tiles on screen and those still holding an animation are looked at,
/// so a scroll through a large library never walks all of it.
///
/// With Settings › General › Play Library previews only on hover on, one tile plays: the one under
/// the pointer once it has rested there, or the one holding keyboard focus.
extension InstalledBrowserModel {
  // MARK: What the tiles read

  /// The animation the tile draws over its cover, nil while it shows the cover alone.
  func playingAnimation(for id: String) -> Data? {
    if playsPreviewsOnHover {
      guard let livePreview, livePreview.id == id else { return nil }
      return livePreview.data
    }
    return gridAnimations[id]
  }

  // MARK: The setting

  /// The setting changed (or was reset): what the old way played is released and the new way
  /// starts from what the grid shows now.
  func previewModeChanged() {
    let onHover = PanelPreferences.playsLibraryPreviewsOnHover(in: controller.defaults)
    guard onHover != playsPreviewsOnHover else { return }
    playsPreviewsOnHover = onHover
    if onHover {
      releaseGridPreviews(keepingTilesOnScreen: true)
    } else {
      liveTarget.reset()
    }
    retargetLivePreview()
    refreshGridPreviews()
  }

  // MARK: Every tile on screen

  /// A tile came into or left the grid's visible part.
  func tileVisibilityChanged(_ id: String, isOnScreen: Bool) {
    guard isOnScreen != tilesOnScreen.contains(id) else { return }
    if isOnScreen { tilesOnScreen.insert(id) } else { tilesOnScreen.remove(id) }
    refreshGridPreviews()
  }

  /// A native collection reports the visible set together, so a row crossing the viewport
  /// schedules previews once, rather than restarting the scheduler for every cell in the row.
  func tilesVisibilityChanged(_ ids: Set<String>) {
    guard ids != tilesOnScreen else { return }
    tilesOnScreen = ids
    refreshGridPreviews()
  }

  /// The window hid or showed. A hidden window releases every animation and keeps the books, so
  /// showing it again plays the same tiles.
  func setGridHidden(_ hidden: Bool) {
    guard hidden != isGridHidden else { return }
    isGridHidden = hidden
    refreshGridPreviews()
  }

  /// Leaving the page or switching to hover: every animation goes and the failed ones are
  /// forgotten. The tiles on screen are kept only when the grid stays (a switch of the setting).
  func releaseGridPreviews(keepingTilesOnScreen: Bool = false) {
    for task in gridPreviewTasks.values { task.cancel() }
    gridPreviewTasks = [:]
    gridAnimations.removeAll()
    gridPreviews.releaseAll()
    if !keepingTilesOnScreen { tilesOnScreen = [] }
  }

  /// Re-evaluates after the grid scrolled, the window hid or showed, or the list changed, then
  /// starts and stops the loads the scheduler decided.
  func refreshGridPreviews() {
    guard !playsPreviewsOnHover else { return }
    let index = gridIndex()
    // The books hold only the tiles on screen, those still holding an animation and those that
    // failed. A row that left the list or no longer has an animation is forgotten, and so is a
    // tile waiting off screen: it is asked afresh when it comes back.
    let states = gridPreviews.states
    let kept = Set(
      states.keys.filter { id in
        index[id] != nil && (states[id] != .queued || tilesOnScreen.contains(id))
          && controller.libraryRow(id: id)?.animationSource != nil
      })
    if kept.count != states.count { gridPreviews.retire(keeping: kept) }
    let ids = tilesOnScreen.union(kept.filter { gridPreviews.isAttached($0) })
      .compactMap { id in index[id].map { (id, $0) } }
      .sorted { $0.1 < $1.1 }
      .map(\.0)
    let tiles = ids.map { id in
      LivePreviewScheduler.Tile(
        id: id, isOnScreen: tilesOnScreen.contains(id),
        hasAnimation: controller.libraryRow(id: id)?.animationSource != nil,
        // The cover is local and drawn at once; there is no still to wait for.
        hasStill: true)
    }
    gridPreviews.update(tiles: tiles, stillsSettled: true, isHidden: isGridHidden)
    // Released by key, not by the current tiles: a tile that left the list is detached too, and
    // its bytes must not outlive it.
    for id in Array(gridPreviewTasks.keys) where !gridPreviews.isAttached(id) {
      gridPreviewTasks.removeValue(forKey: id)?.cancel()
    }
    let released = gridAnimations.keys.filter { !gridPreviews.isAttached($0) }
    for id in released { gridAnimations[id] = nil }
    for id in ids where gridPreviews.isAttached(id) {
      guard gridPreviewTasks[id] == nil, gridAnimations[id] == nil,
        let source = controller.libraryRow(id: id)?.animationSource
      else { continue }
      startGridPreview(id, source)
    }
  }

  /// Each visible id's place, made again only when the list changed. Comparing the cached array
  /// with itself is immediate, so an unchanged list costs nothing.
  private func gridIndex() -> [String: Int] {
    let ids = visibleIDs
    if let gridOrder, gridOrder.ids == ids { return gridOrder.index }
    let index = Dictionary(
      ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
    gridOrder = (ids, index)
    return index
  }

  private func startGridPreview(_ id: String, _ source: PanelImageSource) {
    gridPreviewTasks[id] = Task { [weak self] in
      guard let images = self?.controller.images else { return }
      let data = try? await images.animation(for: source)
      guard !Task.isCancelled, let self else { return }
      self.gridPreviewArrived(id, data: data)
    }
  }

  private func gridPreviewArrived(_ id: String, data: Data?) {
    gridPreviewTasks[id] = nil
    // A tile released while its animation was on the way takes nothing.
    guard gridPreviews.isAttached(id) else { return }
    if let data { gridAnimations[id] = data }
    gridPreviews.finish(id, loaded: data != nil)
    refreshGridPreviews()
  }

  // MARK: The hovered or focused tile

  /// The pointer came onto a tile. A held button (a selection drag) starts nothing.
  func pointerEntered(_ id: String) {
    liveTarget.pointerEntered(id, isButtonDown: isMouseButtonDown())
    retargetLivePreview()
  }

  func pointerLeft(_ id: String) {
    liveTarget.pointerLeft(id)
    retargetLivePreview()
  }

  /// A tile gained or lost focus. Only focus that came from a key plays; a click's does not.
  /// `byKeyboard` is nil to find out from the event being handled, which is what a view does.
  func focusChanged(_ id: String, isFocused: Bool, byKeyboard: Bool? = nil) {
    if isFocused {
      focusedID = id
    } else if focusedID == id {
      focusedID = nil
    }
    liveTarget.focusChanged(
      id, isFocused: isFocused, byKeyboard: byKeyboard ?? (NSApp.currentEvent?.type == .keyDown))
    retargetLivePreview()
  }

  /// Releases the hover animation and forgets the pointer and focus: the window lost focus or was
  /// hidden, the page changed, or the tile left the list.
  func releaseLivePreview() {
    liveTarget.reset()
    retargetLivePreview()
  }

  /// The list changed: a tile no longer shown stops playing, whichever way the previews play.
  func releaseLivePreviewIfHidden() {
    refreshGridPreviews()
    guard let id = livePreview?.id ?? liveCandidate, !visibleIDs.contains(id) else { return }
    releaseLivePreview()
  }

  /// Makes the wanted tile the one that plays on hover: the old animation goes at once, and the
  /// new one loads only after the pointer or focus has rested for `LivePreviewTarget.dwell`.
  /// Nothing plays this way while a sweep is under way or while every tile on screen plays.
  func retargetLivePreview() {
    let wanted = sweep == nil && playsPreviewsOnHover ? liveTarget.id : nil
    guard wanted != liveCandidate else { return }
    liveTask?.cancel()
    liveTask = nil
    liveCandidate = wanted
    if livePreview?.id != wanted { livePreview = nil }
    guard let wanted, let source = controller.libraryRow(id: wanted)?.animationSource else {
      return
    }
    liveTask = Task { [weak self] in
      guard let sleep = self?.sleep else { return }
      do { try await sleep(LivePreviewTarget.dwell) } catch { return }
      guard let images = self?.controller.images, self?.liveCandidate == wanted else { return }
      // A single picture, or one over the animation budget, keeps its still and is not retried.
      guard let data = try? await images.animation(for: source) else { return }
      guard !Task.isCancelled, let self, self.liveCandidate == wanted else { return }
      self.livePreview = LivePreview(id: wanted, data: data)
    }
  }
}
