import SwiftUI

/// One icon button of the Now Playing bar: previous, play or pause, next, the playlist, Recently
/// used.
///
/// Its label is both the tooltip and what VoiceOver reads, so a button never says one thing and does
/// another; the play button's label changes with what pressing it does.
struct NowPlayingControl: View {
  let systemImage: String
  let label: String
  var isEnabled = true
  /// The play or pause button is the bar's main action and draws a little larger.
  var isProminent = false
  /// The symbol's colour while the button stands for something switched on; the text colour
  /// otherwise.
  var tint: Color?
  let identifier: String
  let action: () -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.panelTheme) private var theme

  var body: some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .font(.system(size: isProminent ? 15 : 12.5, weight: .semibold))
        .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
        .foregroundStyle(tint ?? theme.surface.text.color)
    }
    .buttonStyle(NowPlayingControlStyle())
    .disabled(!isEnabled)
    .help(label)
    .accessibilityLabel(Text(verbatim: label))
    .accessibilityIdentifier(identifier)
  }
}

/// The look of a Now Playing button: a quiet rounded hit area that fills on hover and press, and
/// fades while the button is unavailable.
struct NowPlayingControlStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    NowPlayingControlBody(configuration: configuration)
  }
}

private struct NowPlayingControlBody: View {
  let configuration: ButtonStyleConfiguration

  @Environment(\.panelTheme) private var theme
  @Environment(\.isEnabled) private var isEnabled
  @State private var isHovering = false

  var body: some View {
    configuration.label
      .foregroundStyle(theme.surface.text.color)
      .frame(maxWidth: .infinity, minHeight: 28)
      .background(fill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
      .opacity(isEnabled ? 1 : 0.32)
      .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
      .onHover { isHovering = $0 }
  }

  private var fill: Color {
    guard isEnabled else { return .clear }
    if configuration.isPressed { return theme.surface.pressed.color }
    return isHovering ? theme.surface.selected.color : .clear
  }
}

/// The wallpaper's still over a quiet well with a picture glyph, which shows until the still has
/// loaded or when it cannot be: small in the Now Playing bar, wide in its details.
struct NowPlayingCover: View {
  let source: PanelImageSource?
  let width: CGFloat
  let height: CGFloat
  var cornerRadius: CGFloat = 8

  @Environment(\.panelTheme) private var theme

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    ZStack {
      theme.surface.mediaWell.color
      Image(systemName: "photo")
        .font(.system(size: min(width, height) * 0.34))
        .foregroundStyle(theme.surface.faint.color)
      PanelImage(source: source, pointSize: max(width, height), contentMode: .fill)
    }
    .frame(width: width, height: height)
    .clipShape(shape)
    .overlay { shape.strokeBorder(theme.surface.divider.color, lineWidth: 0.5) }
    .accessibilityHidden(true)
  }
}
