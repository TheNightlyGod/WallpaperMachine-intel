import SwiftUI

/// The whole panel: the page under the title bar's tabs, the Now Playing bar along the bottom, and
/// the guide and the dialogs over them.
///
/// It applies the panel's theme and language to everything below it and publishes whether the
/// window is on screen. It expects the `PanelController` in the environment, which
/// `ControlPanelView` puts there.
struct PanelRootView: View {
  @Environment(PanelController.self) private var controller

  var body: some View {
    PanelWindowContent()
      .panelTheme(theme: controller.theme, locale: PanelLocale.shared)
      .environment(\.panelIsVisible, controller.presentation.isVisible)
  }
}

/// The page with its inspector, the Now Playing bar, and what sits over them. There is no sidebar:
/// the pages are tabs in the title bar (`PanelTabs`), and Settings lists its sections in its own
/// page.
private struct PanelWindowContent: View {
  @Environment(PanelController.self) private var controller

  /// Counts the Settings reveals the app asked for (Check for Updates, the update notice), which
  /// arrive through the navigation model from outside the window.
  private var revealToken: UInt64 {
    let _ = controller.revisions.navigation
    return controller.navigation.settingsSectionToken
  }

  var body: some View {
    let shell = controller.shell
    VStack(spacing: 0) {
      PanelDetail()
      NowPlayingBar()
    }
    // Command-F belongs to the page, not to what has the keyboard, so it is bound out here.
    .background { FindShortcut() }
    // The guide covers everything; what is behind it can be neither used nor reached by VoiceOver.
    .disabled(shell.isWelcomeOpen)
    .accessibilityHidden(shell.isWelcomeOpen)
    // AppKit draws the toolbar above the guide's scrim, where its controls would look usable. It
    // is hidden, not emptied, so its items are never removed and inserted again, and the traffic
    // lights and the title bar's dragging stay. The bar is `.automatic`: the toolbar
    // a hosting controller bridges into its window ignores `.windowToolbar`.
    .toolbarVisibility(shell.isWelcomeOpen ? .hidden : .automatic, for: .automatic)
    .overlay { WelcomeOverlayHost() }
    .background { DownloadDialogHost() }
    // The width of the window decides whether the inspector starts open (`ShellLayout`). Reported
    // only when the window crosses a width; the model lets the resize settle first.
    .onGeometryChange(for: ShellLayout.Width.self) { ShellLayout.Width(width: $0.size.width) }
    action: { shell.windowWidthChanged($0) }
    // A popover belongs to the page it was opened on.
    .onChange(of: shell.selection, initial: true) { shell.closePopover() }
    .onChange(of: revealToken, initial: true) { controller.settings.adoptReveal() }
    // Escape, for what the shell owns; a name field and a popover handle their own first.
    .onExitCommand { shell.handleEscape() }
  }
}

/// A button nobody sees whose shortcut, Command-F, puts the keyboard in the page's search field.
private struct FindShortcut: View {
  @Environment(PanelController.self) private var controller

  var body: some View {
    Button {
      controller.shell.focusSearch()
    } label: {
      EmptyView()
    }
    .keyboardShortcut("f", modifiers: .command)
    .frame(width: 0, height: 0)
    .opacity(0)
    .accessibilityHidden(true)
  }
}
