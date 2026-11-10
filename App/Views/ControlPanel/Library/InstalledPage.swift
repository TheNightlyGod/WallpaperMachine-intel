import SwiftUI

/// The Installed page (the Library tab): the views of the library and the bar of controls above
/// the wallpaper grid, the summary and the selection tools beneath it, and the search bar at the
/// top. The Filters sidebar beside it is the window's (`FilterSidebar`).
///
/// The page keeps no state of its own that must outlive it: the filters, the selection and the
/// scroll position are the model's, so leaving for another page and coming back finds them as
/// they were, and a reopened window restores them.
struct InstalledPage: View {
  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme
  /// Files are being dragged over the page.
  @State private var isDropTargeted = false

  var body: some View {
    let model = controller.library
    // The page reads the width it is offered and gives it back as its own. Without that, the
    // controls' minimum widths make the detail column ask the split view for more than the window
    // has beside an open inspector, and AppKit throws "needing another Update Constraints pass".
    GeometryReader { proxy in
      InstalledColumn().frame(width: proxy.size.width, height: proxy.size.height)
    }
    // Wallpaper files and folders dragged from the Finder import as the picker's would. The page
    // only hands the URLs on: the import service reads them, off the main actor.
    .dropDestination(for: URL.self) { urls, _ in
      model.importDropped(urls) != nil
    } isTargeted: { isDropTargeted = $0 }
    .overlay {
      if isDropTargeted {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .strokeBorder(theme.accent.accent.color, lineWidth: 2)
          .background(
            theme.accent.accent.color.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
          )
          .padding(6)
          .allowsHitTesting(false)
          .accessibilityHidden(true)
      }
    }
    .onAppear {
      model.pruneSelection()
      model.dropStaleRestoredTags()
    }
    .onDisappear { model.leavePage() }
    // The library changed: members that left it go, and a tile no longer shown stops playing.
    .onChange(of: model.libraryRevision, initial: false) {
      model.pruneSelection()
      model.dropStaleRestoredTags()
      model.releaseLivePreviewIfHidden()
    }
    .onChange(of: controller.isLibraryLoading) { model.dropStaleRestoredTags() }
    // The bar under the grid was a polite live region: VoiceOver hears what it says once it
    // settles.
    .onChange(of: model.summary) { model.summaryChanged() }
    .onChange(of: model.visibleIDs.count) { model.releaseLivePreviewIfHidden() }
    // Nothing plays in a hidden window; nothing plays on hover or sweeps in one that is not the
    // one being used.
    .onChange(of: controller.presentation.isVisible, initial: true) {
      model.setGridHidden(!controller.presentation.isVisible)
      if !controller.presentation.isVisible { model.windowWentAway() }
    }
    .onChange(of: controller.presentation.isKey) {
      if !controller.presentation.isKey { model.windowWentAway() }
    }
    // Escape, from wherever focus is on the page, leaves selection mode.
    .onExitCommand { model.escape() }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text("Wallpaper browser"))
  }
}

/// The views of the library and the bar of controls, the grid or what stands in for it, and the
/// footer.
private struct InstalledColumn: View {
  @Environment(PanelController.self) private var controller

  var body: some View {
    let model = controller.library
    VStack(spacing: 0) {
      InstalledScopeBar()
      InstalledHeaderRow()
      Group {
        if let empty = model.emptyState {
          InstalledEmptyState(state: empty)
        } else {
          InstalledGrid(rows: model.visibleRows, restoring: model.scrollOffset)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      InstalledFooter()
    }
  }
}
