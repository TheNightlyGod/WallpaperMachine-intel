import AppKit
import SwiftUI

/// The tiles of the Installed page in a lazy grid, with the keyboard, the press-and-sweep gesture
/// and the scroll position the page owns.
///
/// The grid itself is `TileGrid`: columns, the arrow keys, Home and End, Return and Space, and
/// bringing a focused tile into view. This view adds Delete, Escape, scroll tracking and
/// restoring, and the sweep that ticks every tile the pointer crosses after a hold.
struct InstalledGrid: View {
  let rows: [LibraryRow]

  @Environment(PanelController.self) private var controller
  @State private var position: ScrollPosition
  /// The offset to scroll back to once the grid has content to scroll, from the last time the
  /// page was on show or the last window. Nothing is reported while it waits, so the grid's first
  /// look at the top does not overwrite it.
  @State private var pendingOffset: CGFloat?
  @State private var restoreAttempts = 0

  /// A scroll view reporting less than this is still being laid out.
  private static let settledViewport: CGFloat = 100
  private static let restoreAttempts = 8

  /// - Parameter restoring: Where the grid was left, in points from its top; 0 starts at the top.
  init(rows: [LibraryRow], restoring offset: CGFloat = 0) {
    self.rows = rows
    _position = State(initialValue: offset > 0 ? ScrollPosition(y: offset) : ScrollPosition())
    _pendingOffset = State(initialValue: offset > 0 ? offset : nil)
  }

  /// What the scroll view reports about itself, as far as a change of it is worth an action.
  ///
  /// Every change of this value makes SwiftUI ask the window for another layout pass, from inside
  /// the pass that changed it. The content's height changes with the grid's width, so it is left
  /// out: a scroller that comes and goes because the content is as tall as the viewport, or the
  /// inspector column animating open or shut, would otherwise flip it on every pass until AppKit
  /// gives up ("needing another Update Constraints in Window pass") and the app ends. It is
  /// carried only while an offset is restored into a settled viewport, which follows the lazy
  /// grid's estimate as it settles and ends after `restoreAttempts` reports. The sweep's bound
  /// reads the height that `keepContentHeight(of:model:)` keeps out of band.
  private struct ScrollMetrics: Equatable {
    var offset: CGFloat
    var viewportHeight: CGFloat
    var restoringContentHeight: CGFloat?
  }

  var body: some View {
    let model = controller.library
    let others = model.otherDisplayWallpaperIDs
    TileGrid(
      rows, spacing: LibraryGridGeometry.spacing, insets: LibraryGridGeometry.insets,
      onActivate: { model.tileActivated($0.id) }
    ) { row in
      InstalledTile(row: row, otherDisplayIDs: others)
    }
    .scrollPosition($position)
    .onScrollGeometryChange(for: ScrollMetrics.self) {
      [isRestoring = pendingOffset != nil] geometry in
      let viewport = geometry.containerSize.height
      let content = keepContentHeight(of: geometry, model: model)
      return ScrollMetrics(
        offset: geometry.contentOffset.y + geometry.contentInsets.top, viewportHeight: viewport,
        restoringContentHeight: isRestoring && viewport > Self.settledViewport ? content : nil)
    } action: { _, metrics in
      scrolled(metrics, model: model)
    }
    .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) {
      model.geometry.viewport.width = $0
    }
    .simultaneousGesture(sweepGesture(model))
    .onKeyPress(keys: [.delete, .deleteForward]) { _ in
      model.deleteSelectionOrFocused() ? .handled : .ignored
    }
    .onKeyPress(.escape) { model.escape() ? .handled : .ignored }
    .onChange(of: model.scrollToTopCount) {
      // A view chosen while an old offset is still being restored wins over it.
      pendingOffset = nil
      position.scrollTo(edge: .top)
    }
    .onAppear { model.scrollGrid = { offset in position.scrollTo(y: offset) } }
    .onDisappear { model.scrollGrid = nil }
    .accessibilityLabel(Text("Wallpapers"))
  }

  // MARK: Scrolling

  /// Keeps the content's height for the sweep's autoscroll bound, which is read only while the
  /// pointer is down. The model's geometry is not observed, so writing it while the scroll view
  /// reports draws nothing again; and it is written here, not in the action, because the height
  /// is not part of what dispatches one (`ScrollMetrics`).
  private func keepContentHeight(of geometry: ScrollGeometry, model: InstalledBrowserModel)
    -> CGFloat
  {
    model.geometry.contentHeight = geometry.contentSize.height
    return geometry.contentSize.height
  }

  private func scrolled(_ metrics: ScrollMetrics, model: InstalledBrowserModel) {
    model.geometry.offsetY = metrics.offset
    model.geometry.viewport.height = metrics.viewportHeight
    // Restoring waits for a settled grid. While a window lays out, the scroll view reports a
    // viewport of a few points and a content height that is only an estimate, and the offset
    // drifts with it; so the target is asserted again with each report until the grid is there,
    // and for a few reports at most.
    if let target = pendingOffset {
      guard metrics.viewportHeight > Self.settledViewport,
        let contentHeight = metrics.restoringContentHeight
      else { return }
      let clamped = min(target, max(0, contentHeight - metrics.viewportHeight))
      restoreAttempts += 1
      if abs(metrics.offset - clamped) <= 1 || restoreAttempts > Self.restoreAttempts {
        pendingOffset = nil
      } else {
        position.scrollTo(y: clamped)
        return
      }
    }
    model.scrolled(to: metrics.offset)
  }

  // MARK: Press and sweep

  /// The press, the movement and the release of the primary button on the grid. A press that is
  /// not the start of a sweep (a modifier, a heart, no tile) is still tracked, so its movement
  /// is not mistaken for a new press.
  private func sweepGesture(_ model: InstalledBrowserModel) -> some Gesture {
    DragGesture(minimumDistance: 0, coordinateSpace: .local)
      .onChanged { value in
        if !model.isPointerDown {
          model.isPointerDown = true
          model.sweepPressed(at: value.startLocation, modifiers: NSEvent.modifierFlags)
        } else {
          model.sweepMoved(to: value.location)
        }
      }
      .onEnded { _ in
        model.isPointerDown = false
        model.endSweep()
      }
  }
}
