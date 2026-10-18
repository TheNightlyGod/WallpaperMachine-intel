import SwiftUI

/// A small capsule of text, optionally with a glyph or an `Equalizer` beside it: "Active", "Other
/// display", a state on a tile or a row.
struct CapsuleBadge<Content: View>: View {
  enum Style {
    /// Filled with the accent: the wallpaper that is playing.
    case accent
    /// Dark whatever the appearance, for use over artwork.
    case overlay
    /// A quiet chip on a surface.
    case neutral
  }

  var style: Style = .neutral
  @ViewBuilder var content: Content

  @Environment(\.panelTheme) private var theme

  var body: some View {
    HStack(spacing: 4) { content }
      .font(.system(size: 11, weight: .semibold))
      .foregroundStyle(foreground)
      .lineLimit(1)
      .padding(.horizontal, 7)
      .frame(minHeight: 18)
      .background(background, in: Capsule())
  }

  private var foreground: Color {
    switch style {
    case .accent: theme.accent.onPrimary.color
    case .overlay: .white
    case .neutral: theme.surface.tagInk.color
    }
  }

  private var background: Color {
    switch style {
    case .accent: theme.accent.primary.color
    case .overlay: .black.opacity(0.6)
    case .neutral: theme.surface.badge.color
    }
  }
}

/// A number in a capsule: a count beside a Settings section, a filter, the downloads button.
struct CountBadge: View {
  enum Style {
    case neutral
    /// Filled with the accent: something here needs the user.
    case attention
  }

  let count: Int
  var style: Style = .neutral

  @Environment(\.panelTheme) private var theme

  var body: some View {
    Text(count, format: .number)
      .font(.system(size: 11, weight: .semibold).monospacedDigit())
      .foregroundStyle(
        style == .attention ? theme.accent.onPrimary.color : theme.surface.muted.color
      )
      .padding(.horizontal, 6)
      .frame(minWidth: 18, minHeight: 18)
      .background(
        style == .attention ? theme.accent.primary.color : theme.surface.badge.color, in: Capsule())
  }
}
