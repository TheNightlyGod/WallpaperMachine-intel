import AppKit

extension LibraryCollectionCoordinator {
  /// Observes the pointer before child buttons handle it; it does not consume or delay events.
  /// A sweep starting over a check must still allow an ordinary check click to reach SwiftUI.
  func windowChanged() {
    if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
    eventMonitor = nil
    guard scrollView.window != nil else {
      clearHover()
      hasPointerDown = false
      model.isPointerDown = false
      model.endSweep()
      return
    }
    eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
      MainActor.assumeIsolated { self?.pointerEvent(event) }
      return event
    }
  }

  func viewportPoint(_ location: CGPoint) -> CGPoint {
    let point = collection.convert(location, from: nil)
    return CGPoint(x: point.x, y: point.y - scrollView.contentView.bounds.minY)
  }

  func pointerEvent(_ event: NSEvent) {
    guard event.window === scrollView.window else { return }
    let point = viewportPoint(event.locationInWindow)
    switch event.type {
    case .leftMouseDown:
      guard !isUserScrolling else { return }
      guard CGRect(origin: .zero, size: model.geometry.viewport).contains(point) else { return }
      hasPointerDown = true
      model.isPointerDown = true
      if let index = model.geometry.index(at: point, count: rows.count) {
        focus(rows[index].id, byKeyboard: false)
        scrollView.window?.makeFirstResponder(collection)
      }
      model.sweepPressed(at: point, modifiers: event.modifierFlags)
    case .leftMouseDragged:
      if hasPointerDown { model.sweepMoved(to: point) }
    case .leftMouseUp:
      if hasPointerDown {
        hasPointerDown = false
        model.isPointerDown = false
        model.endSweep()
      }
    default: break
    }
  }

  func pointerMoved(_ location: CGPoint) {
    guard !isUserScrolling else { return }
    let point = viewportPoint(location)
    let id = model.geometry.index(at: point, count: rows.count).map { rows[$0].id }
    guard id != hoveredID else { return }
    clearHover()
    hoveredID = id
    if let id {
      item(for: id)?.tile.isHovering = true
      model.pointerEntered(id)
    }
  }

  func clearHover() {
    guard let id = hoveredID else { return }
    hoveredID = nil
    item(for: id)?.tile.isHovering = false
    model.pointerLeft(id)
  }

  func setUserScrolling(_ scrolling: Bool) {
    guard scrolling != isUserScrolling else { return }
    isUserScrolling = scrolling
    if scrolling {
      clearHover()
    } else if let window = scrollView.window, window.isKeyWindow {
      pointerMoved(window.mouseLocationOutsideOfEventStream)
    }
  }

  func scrollWheel(_ event: NSEvent) {
    if event.phase == .began || event.phase == .changed || event.momentumPhase == .began
      || event.momentumPhase == .changed {
      setUserScrolling(true)
    }
    if event.momentumPhase == .ended || event.phase == .cancelled {
      setUserScrolling(false)
    }
  }

  func item(for id: String) -> LibraryCollectionItem? {
    guard let index = rows.firstIndex(where: { $0.id == id }) else { return nil }
    return collection.item(at: IndexPath(item: index, section: 0)) as? LibraryCollectionItem
  }

  func focus(_ id: String, byKeyboard: Bool) {
    lastFocusedID = id
    if let previous = model.focusedID, previous != id {
      item(for: previous)?.tile.isFocused = false
      model.focusChanged(previous, isFocused: false, byKeyboard: byKeyboard)
    }
    model.focusChanged(id, isFocused: true, byKeyboard: byKeyboard)
    item(for: id)?.tile.isFocused = true
  }

  func focusEntered() {
    guard let id = model.focusedID ?? lastFocusedID ?? rows.first?.id else { return }
    focus(id, byKeyboard: NSApp.currentEvent?.type == .keyDown)
  }

  func focusLeft() {
    guard let id = model.focusedID else { return }
    item(for: id)?.tile.isFocused = false
    model.focusChanged(id, isFocused: false, byKeyboard: false)
  }

  @discardableResult
  func keyDown(_ event: NSEvent) -> Bool {
    if event.modifierFlags.contains(.command) {
      if event.charactersIgnoringModifiers?.lowercased() == "a" {
        model.selectAllVisible()
        return true
      }
      switch event.keyCode {
      // Command-Delete, the Finder's Move to Trash: the same confirmed delete as the plain key.
      case 51, 117: return model.deleteSelectionOrFocused()
      // Command-Return applies the focused wallpaper, which a double click does with the pointer.
      // Return alone still chooses it for the inspector.
      case 36, 76:
        guard let id = model.focusedID ?? lastFocusedID else { return false }
        model.activate(id)
        return true
      default: return false
      }
    }
    switch event.keyCode {
    case 51, 117: return model.deleteSelectionOrFocused()
    case 53: return model.escape()
    case 36, 49, 76:
      guard let id = model.focusedID ?? lastFocusedID else { return false }
      model.tileActivated(id)
      return true
    default: break
    }
    let move: TileGridLayout.Move
    switch event.keyCode {
    case 123: move = .left
    case 124: move = .right
    case 125: move = .down
    case 126: move = .up
    case 115: move = .first
    case 119: move = .last
    default: return false
    }
    let current = (model.focusedID ?? lastFocusedID).flatMap { id in rows.firstIndex { $0.id == id } } ?? 0
    guard let target = TileGridLayout.destination(
      from: current, move, columns: gridLayout.geometry.columns, count: rows.count)
    else { return true }
    focus(rows[target].id, byKeyboard: true)
    let frame = gridLayout.geometry.frame(ofIndex: target)
    let viewport = scrollView.contentView.bounds
    if frame.minY < viewport.minY { scroll(to: frame.minY) }
    else if frame.maxY > viewport.maxY { scroll(to: frame.maxY - viewport.height) }
    collection.layoutSubtreeIfNeeded()
    if let item = item(for: rows[target].id) {
      item.tile.isFocused = true
      NSAccessibility.post(element: item.view, notification: .focusedUIElementChanged)
    }
    return true
  }
}
