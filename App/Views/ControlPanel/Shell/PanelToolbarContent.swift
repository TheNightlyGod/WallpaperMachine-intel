import SwiftUI

/// The window toolbar: the app's name leading, the page tabs in the middle, and trailing the
/// activity pills, the target display menu, the downloads button and the inspector toggle, in that
/// order. A pill, the downloads button and the inspector toggle are in the toolbar only while they
/// have something to show; the target display menu is hidden on
/// Settings. The pages' search field is in the page, not here (`PageSearchBar`).
struct PanelToolbarContent: ToolbarContent {
  let controller: PanelController

  var body: some ToolbarContent {
    // The name is text, not a control: no glass behind it.
    ToolbarItem(placement: .navigation) { PanelIdentity() }
      .withoutSharedBackground()
    ToolbarItem(placement: .principal) { PanelTabs() }
    // The pill is in the toolbar while an import runs and until its report has been looked at.
    // The library keeps that memory with the popover that clears it (`ImportPill`).
    if ImportActivityPill.isActive(in: controller) {
      ToolbarItem(placement: .primaryAction) { ImportActivityPill() }
    }
    if SetupActivityPill.isActive(in: controller) {
      ToolbarItem(placement: .primaryAction) { SetupActivityPill() }
    }
    if PixivActivityPill.isActive(in: controller) {
      ToolbarItem(placement: .primaryAction) { PixivActivityPill() }
    }
    if controller.shell.selection != .settings {
      ToolbarItem(placement: .primaryAction) { TargetDisplayPicker() }
    }
    if DownloadsToolbarButton.isActive(in: controller) {
      ToolbarItem(placement: .primaryAction) { DownloadsToolbarButton() }
    }
    if controller.shell.hasInspector {
      ToolbarItem(placement: .primaryAction) { InspectorToggle() }
    }
  }
}

/// The toolbar button that shows and hides the inspector column.
private struct InspectorToggle: View {
  @Environment(PanelController.self) private var controller

  var body: some View {
    let shell = controller.shell
    Button {
      shell.toggleInspector()
    } label: {
      Label(L("Wallpaper details"), systemImage: "sidebar.trailing")
    }
    .help(L("Wallpaper details"))
    .accessibilityAddTraits(shell.isInspectorShown ? .isSelected : [])
    .accessibilityIdentifier("inspector-toggle")
  }
}

extension ToolbarContent {
  /// Leaves the item without the glass the toolbar puts behind its items (macOS 26 and later).
  @ToolbarContentBuilder
  fileprivate func withoutSharedBackground() -> some ToolbarContent {
    if #available(macOS 26.0, *) {
      sharedBackgroundVisibility(.hidden)
    } else {
      self
    }
  }
}
