import AppKit
import SwiftUI

/// A recycled native collection keeps scrolling independent of the SwiftUI tile view graphs.
/// The Library model still owns selection, previews, keyboard focus and the saved offset.
struct InstalledGrid: NSViewRepresentable {
  let rows: [LibraryRow]
  private let restoring: CGFloat

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTileWidth) private var preferredTileWidth

  init(rows: [LibraryRow], restoring offset: CGFloat = 0) {
    self.rows = rows
    restoring = offset
  }

  func makeCoordinator() -> LibraryCollectionCoordinator {
    LibraryCollectionCoordinator(model: controller.library, restoring: restoring)
  }

  func makeNSView(context: Context) -> LibraryCollectionScrollView {
    context.coordinator.scrollView
  }

  func updateNSView(_ view: LibraryCollectionScrollView, context: Context) {
    context.coordinator.update(
      rows: rows, otherDisplays: controller.library.otherDisplayWallpaperIDs,
      environment: context.environment, preferredWidth: preferredTileWidth,
      scrollToTopCount: controller.library.scrollToTopCount)
  }

  static func dismantleNSView(_ view: LibraryCollectionScrollView, coordinator: LibraryCollectionCoordinator) {
    coordinator.stop()
  }
}
