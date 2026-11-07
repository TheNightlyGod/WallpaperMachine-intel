import AppKit

/// AppKit owns the scroll offset and moves the cached tile layers without laying out SwiftUI.
@MainActor
final class LibraryCollectionScrollView: NSScrollView {
  weak var owner: LibraryCollectionCoordinator?

  override var intrinsicContentSize: NSSize {
    NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
  }

  override func layout() {
    super.layout()
    owner?.layoutViewport()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    owner?.windowChanged()
  }
}

@MainActor
final class LibraryCollectionView: NSCollectionView {
  weak var owner: LibraryCollectionCoordinator?
  private var pointerTracking: NSTrackingArea?

  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { true }

  override func updateTrackingAreas() {
    if let pointerTracking { removeTrackingArea(pointerTracking) }
    let tracking = NSTrackingArea(
      rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
      owner: self, userInfo: nil)
    addTrackingArea(tracking)
    pointerTracking = tracking
    super.updateTrackingAreas()
  }

  override func mouseMoved(with event: NSEvent) { owner?.pointerMoved(event.locationInWindow) }
  override func mouseEntered(with event: NSEvent) { owner?.pointerMoved(event.locationInWindow) }
  override func mouseExited(with event: NSEvent) { owner?.clearHover() }

  override func hitTest(_ point: NSPoint) -> NSView? {
    if owner?.isUserScrolling == true { return bounds.contains(convert(point, from: superview)) ? self : nil }
    return super.hitTest(point)
  }

  override func scrollWheel(with event: NSEvent) {
    owner?.scrollWheel(event)
    super.scrollWheel(with: event)
  }

  override func keyDown(with event: NSEvent) {
    if owner?.keyDown(event) != true { super.keyDown(with: event) }
  }

  override func becomeFirstResponder() -> Bool {
    let accepted = super.becomeFirstResponder()
    if accepted { owner?.focusEntered() }
    return accepted
  }

  override func resignFirstResponder() -> Bool {
    let accepted = super.resignFirstResponder()
    if accepted { owner?.focusLeft() }
    return accepted
  }
}
