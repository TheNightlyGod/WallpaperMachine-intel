import SwiftUI

/// The pages of the window, as tabs in the middle of the title bar: Library (Installed), Steam
/// Workshop, pixiv and Settings. Choosing one opens its page; the library's view (All wallpapers,
/// Favorites, a collection) is chosen on the Library page itself and survives a visit to the
/// others.
///
/// Each tab is as wide as its name. In a narrow window (`ShellModel.isCompact`) the tabs show their
/// symbols alone, with the names as tooltips, so the toolbar's tools keep their places beside them
/// instead of falling into its overflow menu. VoiceOver reads them as buttons named for their
/// pages, the page on show as selected.
struct PanelTabs: View {
  @Environment(PanelController.self) private var controller

  /// The tabs in order.
  static let pages: [SidebarSelection] = [.wallpaper, .workshop, .pixiv, .settings]

  var body: some View {
    let shell = controller.shell
    let selection = shell.selection
    let isCompact = shell.isCompact
    HStack(spacing: 2) {
      ForEach(Self.pages, id: \.self) { page in
        Button {
          if page != shell.selection { shell.open(page) }
        } label: {
          if isCompact {
            Image(systemName: Self.symbol(of: page))
              .font(.system(size: 13, weight: .medium))
              .frame(width: 18)
          } else {
            Text(verbatim: Self.name(of: page))
          }
        }
        .buttonStyle(PanelTabStyle(isSelected: page == selection))
        .help(isCompact ? Self.name(of: page) : "")
        .accessibilityLabel(Text(verbatim: Self.name(of: page)))
        .accessibilityAddTraits(page == selection ? .isSelected : [])
        .accessibilityIdentifier("tab-\(Self.identifier(of: page))")
      }
    }
    // The toolbar's glass capsule reaches about 4 pt past a tab above and below; the same inset at
    // the ends keeps the first and last tab's capsule concentric with it.
    .padding(.horizontal, 4)
    .fixedSize()
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text(verbatim: L("Main navigation")))
    .accessibilityIdentifier("panel-tabs")
  }

  static func name(of page: SidebarSelection) -> String {
    switch page {
    case .wallpaper: L("Library")
    case .workshop: L("Steam Workshop")
    // A proper noun: never translated.
    case .pixiv: "pixiv"
    case .settings: L("Settings")
    }
  }

  static func symbol(of page: SidebarSelection) -> String {
    switch page {
    case .wallpaper: "square.grid.2x2"
    case .workshop: "storefront"
    case .pixiv: "paintpalette"
    case .settings: "gearshape"
    }
  }

  static func identifier(of page: SidebarSelection) -> String {
    switch page {
    case .wallpaper: "library"
    case .workshop: "workshop"
    case .pixiv: "pixiv"
    case .settings: "settings"
    }
  }
}

/// A tab: its name in a capsule, tinted with the accent while its page is on show, and lit on hover
/// otherwise.
private struct PanelTabStyle: ButtonStyle {
  let isSelected: Bool

  func makeBody(configuration: Configuration) -> some View {
    PanelTabBody(configuration: configuration, isSelected: isSelected)
  }
}

private struct PanelTabBody: View {
  let configuration: ButtonStyleConfiguration
  let isSelected: Bool

  @Environment(\.panelTheme) private var theme
  @State private var isHovering = false

  var body: some View {
    configuration.label
      .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
      .foregroundStyle(isSelected ? theme.accent.accent.color : theme.surface.text.color)
      .lineLimit(1)
      .padding(.horizontal, 10)
      .frame(minHeight: 28)
      .background(background, in: Capsule())
      .contentShape(Capsule())
      .onHover { isHovering = $0 }
  }

  private var background: Color {
    if isSelected { return theme.accent.accent.color.opacity(configuration.isPressed ? 0.24 : 0.16) }
    if configuration.isPressed { return theme.surface.pressed.color }
    return isHovering ? theme.surface.hover.color : .clear
  }
}
