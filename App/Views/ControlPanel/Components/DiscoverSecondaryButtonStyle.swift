import SwiftUI

/// The quiet counterpart of `PrimaryButtonStyle`: a neutral fill with a hairline, for the button
/// beside the main one (Cancel, Not now, Download and apply, View on Steam Workshop).
///
/// `.bordered` draws a near-white button that disappears on a white surface; this one takes the
/// panel's own well colour, so it reads in every tone and appearance, and has hover and pressed
/// states. It takes its size from `PrimaryButtonStyle.Size`, and may expand to the width it is
/// offered, as the inspector's buttons do.
struct DiscoverSecondaryButtonStyle: ButtonStyle {
  var size: PrimaryButtonStyle.Size = .regular
  var expands = false

  func makeBody(configuration: Configuration) -> some View {
    DiscoverSecondaryButtonBody(configuration: configuration, size: size, expands: expands)
  }
}

private struct DiscoverSecondaryButtonBody: View {
  let configuration: ButtonStyleConfiguration
  let size: PrimaryButtonStyle.Size
  let expands: Bool

  @Environment(\.panelTheme) private var theme
  @Environment(\.isEnabled) private var isEnabled
  @State private var isHovering = false

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
    configuration.label
      .font(.system(size: size == .regular ? 13 : 12, weight: .medium))
      .foregroundStyle(theme.surface.text.color)
      .lineLimit(1)
      .padding(.horizontal, size == .regular ? 14 : 10)
      .frame(maxWidth: expands ? .infinity : nil, minHeight: size.height)
      .background(theme.surface.well.color, in: shape)
      .overlay {
        shape.fill(
          configuration.isPressed
            ? theme.surface.pressed.color
            : isHovering && isEnabled ? theme.surface.hover.color : Color.clear)
      }
      .overlay { shape.strokeBorder(theme.surface.divider.color, lineWidth: 0.5) }
      .opacity(isEnabled ? 1 : 0.4)
      .contentShape(shape)
      .onHover { isHovering = $0 }
  }
}

extension ButtonStyle where Self == DiscoverSecondaryButtonStyle {
  /// `DiscoverSecondaryButtonStyle` at its regular size.
  static var panelSecondary: DiscoverSecondaryButtonStyle { DiscoverSecondaryButtonStyle() }
  static func panelSecondary(size: PrimaryButtonStyle.Size, expands: Bool = false)
    -> DiscoverSecondaryButtonStyle
  {
    DiscoverSecondaryButtonStyle(size: size, expands: expands)
  }
}
