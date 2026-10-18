import SwiftUI

/// A choice that is a whole row: a coloured glyph, a name and a line about it, and a mark at the
/// trailing edge saying where it leads. The suggested one wears the accent. The Start page's ways to
/// begin and the support prompt's two links are made of it.
struct WelcomeActionRow: View {
  let symbol: String
  let color: Color
  let title: Text
  let note: Text
  /// `chevron.right` for what stays in the app, `arrow.up.right` for what opens a link.
  let trailingSymbol: String
  var isSuggested = false
  var action: () -> Void

  @Environment(\.panelTheme) private var theme

  var body: some View {
    Button(action: action) {
      HStack(spacing: 12) {
        SymbolTile(systemImage: symbol, color: color)
        WelcomeColumn(spacing: 2) {
          title.font(.system(size: 13, weight: .semibold))
          note
            .font(.system(size: 12))
            .foregroundStyle(theme.surface.muted.color)
            .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        Image(systemName: trailingSymbol)
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(theme.surface.faint.color)
          .accessibilityHidden(true)
      }
    }
    .buttonStyle(WelcomeActionRowStyle(isSuggested: isSuggested))
  }
}

private struct WelcomeActionRowStyle: ButtonStyle {
  let isSuggested: Bool

  func makeBody(configuration: Configuration) -> some View {
    RowBody(configuration: configuration, isSuggested: isSuggested)
  }

  private struct RowBody: View {
    let configuration: ButtonStyleConfiguration
    let isSuggested: Bool
    @Environment(\.panelTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
      configuration.label
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity)
        .background(fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(
              isSuggested ? theme.accent.primaryLine.color : theme.surface.divider.color,
              lineWidth: isSuggested ? 1.5 : 0.5)
        }
        .opacity(isEnabled ? 1 : 0.55)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { isHovering = $0 }
    }

    private var fill: Color {
      if configuration.isPressed { return theme.surface.pressed.color }
      return isHovering && isEnabled ? theme.surface.raisedHover.color : theme.surface.well.color
    }
  }
}
