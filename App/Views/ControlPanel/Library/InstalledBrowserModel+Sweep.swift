import AppKit
import Foundation

/// The press-and-sweep selection: the gesture's events arrive here, the logic is `SweepSelection`.
extension InstalledBrowserModel {
  /// How often the grid scrolls while the pointer rests in its edge band.
  fileprivate static let autoscrollInterval = Duration.milliseconds(16)

  /// The primary button went down on the grid at `point` (the scroll view's own coordinates).
  /// A press with a modifier, off any tile or on a tile's heart is not the start of a sweep.
  func sweepPressed(at point: CGPoint, modifiers: NSEvent.ModifierFlags) {
    endSweep()
    guard modifiers.intersection([.command, .control, .shift, .option]).isEmpty else { return }
    let ids = visibleIDs
    guard let index = geometry.index(at: point, count: ids.count),
      !geometry.isOnHeart(point, tileIndex: index)
    else { return }
    // Once a selection is under way, or from a tile's check, moving onto another tile sweeps
    // at once.
    let eager = isSelecting || !selection.isEmpty || geometry.isOnCheck(point, tileIndex: index)
    sweep = SweepSelection(startID: ids[index], at: point, isEager: eager)
    refreshArming()
    retargetLivePreview()
    holdTask = Task { [weak self] in
      guard let sleep = self?.sleep else { return }
      do { try await sleep(SweepSelection.holdDuration) } catch { return }
      self?.holdElapsed()
    }
  }

  private func holdElapsed() {
    holdTask = nil
    sweep?.holdElapsed(selection: &selection, visible: visibleIDs)
    refreshArming()
    updateAutoscroll()
  }

  /// The pointer moved with the button still down.
  func sweepMoved(to point: CGPoint) {
    guard sweep != nil else { return }
    let ids = visibleIDs
    let tile = geometry.index(at: point, count: ids.count).map { ids[$0] }
    let outcome =
      sweep?.move(to: point, over: tile, selection: &selection, visible: ids) ?? .cancelled
    if outcome == .cancelled {
      endSweep()
    } else {
      refreshArming()
      updateAutoscroll()
    }
  }

  /// The button came up, the window lost focus, or Escape was pressed. A sweep that painted keeps
  /// its selection, swallows the click that ends the press, and, having covered two tiles or more,
  /// retires the tip that teaches it.
  func endSweep() {
    holdTask?.cancel()
    holdTask = nil
    autoscrollTask?.cancel()
    autoscrollTask = nil
    guard let ended = sweep else { return }
    sweep = nil
    refreshArming()
    if ended.isPainting {
      swallowsClick = true
      swallowReset?.cancel()
      // One turn of the run loop: as long as the click that ends the press takes to arrive.
      swallowReset = Task { [weak self] in self?.swallowsClick = false }
      if ended.hasLearned, !controller.dragSelectLearned { controller.markDragSelectLearned() }
    }
    retargetLivePreview()
  }

  /// Sets `armingID` from the sweep, writing only when it changed so no tile redraws for nothing.
  private func refreshArming() {
    let arming = sweep?.isArming == true ? sweep?.startID : nil
    if armingID != arming { armingID = arming }
  }

  /// Scrolls the grid while the pointer rests in the band at its top or bottom, faster the deeper
  /// it is. Runs only while a sweep is painting and the pointer is in a band.
  private func updateAutoscroll() {
    guard autoscrollTask == nil, let sweep, sweep.isPainting,
      SweepSelection.scrollStep(pointerY: sweep.point.y, viewportHeight: geometry.viewport.height)
        != 0
    else { return }
    autoscrollTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let sleep = self?.sleep, self?.autoscrollStep() == true else { break }
        do { try await sleep(Self.autoscrollInterval) } catch { break }
      }
      self?.autoscrollTask = nil
    }
  }

  /// One frame of the autoscroll: false once there is nothing left to scroll for.
  private func autoscrollStep() -> Bool {
    guard let sweep, sweep.isPainting else { return false }
    let step = SweepSelection.scrollStep(
      pointerY: sweep.point.y, viewportHeight: geometry.viewport.height)
    guard step != 0 else { return false }
    scroll(by: step)
    return true
  }

  /// Scrolls the grid by `step` points and lets the tile that arrives under the pointer join.
  private func scroll(by step: CGFloat) {
    let target = min(max(0, geometry.offsetY + step), geometry.maxOffset)
    guard target != geometry.offsetY else { return }
    geometry.offsetY = target
    scrollGrid?(target)
    guard let sweep else { return }
    let ids = visibleIDs
    let point = SweepSelection.clamped(sweep.point, in: geometry.viewport)
    if let index = geometry.index(at: point, count: ids.count) {
      self.sweep?.paint(ids[index], selection: &selection)
    }
  }
}
