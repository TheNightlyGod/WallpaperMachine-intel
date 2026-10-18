import SwiftUI

/// A button that reads as a link: the panel's accent colour, underlined while the pointer is over
/// it, dimmed while pressed.
///
/// The system `.link` style takes the foreground colour of the view it is in, so it goes dark
/// wherever a container sets the panel's text colour. This one draws the contrast-fitted accent
/// itself (`AccentPalette.accent`), which reads on every surface.
struct DiscoverLinkButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    DiscoverLinkButtonBody(configuration: configuration)
  }
}

private struct DiscoverLinkButtonBody: View {
  let configuration: ButtonStyleConfiguration

  @Environment(\.panelTheme) private var theme
  @Environment(\.isEnabled) private var isEnabled
  @State private var isHovering = false

  var body: some View {
    configuration.label
      .foregroundStyle(theme.accent.accent.color)
      .underline(isHovering && isEnabled)
      .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.4)
      .contentShape(Rectangle())
      .onHover { isHovering = $0 }
  }
}

extension ButtonStyle where Self == DiscoverLinkButtonStyle {
  /// `DiscoverLinkButtonStyle`.
  static var panelLink: DiscoverLinkButtonStyle { DiscoverLinkButtonStyle() }
}

/// A link's symbol in a column of fixed width before its words, so links stacked one under another
/// start their words at the same place however wide their symbols are.
struct PanelLinkRowLabelStyle: LabelStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 6) {
      configuration.icon
        .frame(width: 18)
      configuration.title
    }
  }
}

extension LabelStyle where Self == PanelLinkRowLabelStyle {
  /// `PanelLinkRowLabelStyle`, for the label of a `.panelLink` button in a stack of links.
  static var panelLinkRow: PanelLinkRowLabelStyle { PanelLinkRowLabelStyle() }
}
