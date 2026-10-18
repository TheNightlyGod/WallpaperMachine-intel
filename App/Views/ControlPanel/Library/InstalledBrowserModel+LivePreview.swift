import AppKit
import Foundation

/// The one tile that plays its animation: the one under the pointer once it has rested there, or
/// the one holding keyboard focus.
extension InstalledBrowserModel {
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

  /// Releases the animation and forgets the pointer and focus: the window lost focus or was
  /// hidden, the page changed, or the tile left the list.
  func releaseLivePreview() {
    liveTarget.reset()
    retargetLivePreview()
  }

  /// Drops the animation if its tile is no longer shown.
  func releaseLivePreviewIfHidden() {
    guard let id = livePreview?.id ?? liveCandidate, !visibleIDs.contains(id) else { return }
    releaseLivePreview()
  }

  /// Makes the wanted tile the one that plays: the old animation goes at once, and the new one
  /// loads only after the pointer or focus has rested for `LivePreviewTarget.dwell`. Nothing plays
  /// while a sweep is under way.
  func retargetLivePreview() {
    let wanted = sweep == nil ? liveTarget.id : nil
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
