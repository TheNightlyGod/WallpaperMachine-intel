import SwiftUI

/// The accent-filled button: Apply, Download, Choose wallpapers.
///
/// `.borderedProminent` always draws a white label, which cannot be read on a yellow, white or
/// grey accent. This style paints `AccentPalette.primary` and the label colour that was fitted to
/// it, and uses the palette's hover and pressed fills.
struct PrimaryButtonStyle: ButtonStyle {
  enum Size {
    case regular
    case compact
    /// As tall and in the same type as a small bordered button (`.controlSize(.small)`), for the
    /// main action of a row of small buttons, as on the Settings pages.
    case small

    var height: CGFloat {
      switch self {
      case .regular: 28
      case .compact: 24
      case .small: 20
      }
    }

    var fontSize: CGFloat { self == .small ? 11 : 13 }
    var horizontalPadding: CGFloat { self == .small ? 9 : 14 }
    var cornerRadius: CGFloat { self == .small ? 5 : 7 }
  }

  var size: Size = .regular
  /// Whether the button takes the width it is offered, as the inspector's main action does.
  var expands = false

  func makeBody(configuration: Configuration) -> some View {
    PrimaryButtonBody(configuration: configuration, size: size, expands: expands)
  }
}

private struct PrimaryButtonBody: View {
  let configuration: ButtonStyleConfiguration
  let size: PrimaryButtonStyle.Size
  let expands: Bool

  @Environment(\.panelTheme) private var theme
  @Environment(\.isEnabled) private var isEnabled
  @State private var isHovering = false

  var body: some View {
    let accent = theme.accent
    configuration.label
      .font(.system(size: size.fontSize, weight: .medium))
      .foregroundStyle(accent.onPrimary.color)
      .lineLimit(1)
      .padding(.horizontal, size.horizontalPadding)
      .frame(maxWidth: expands ? .infinity : nil, minHeight: size.height)
      .background(fill.color, in: RoundedRectangle(cornerRadius: size.cornerRadius, style: .continuous))
      .opacity(isEnabled ? 1 : 0.4)
      .contentShape(RoundedRectangle(cornerRadius: size.cornerRadius, style: .continuous))
      .onHover { isHovering = $0 }
  }

  private var fill: PanelColor {
    let accent = theme.accent
    if configuration.isPressed { return accent.primaryActive }
    return isHovering && isEnabled ? accent.primaryHover : accent.primary
  }
}

/// A quiet capsule button for the bars above a page: Filter, Sort, Select, and the pills that
/// report activity. `isActive` tints it with the accent, as a Filter that has filters set.
struct ToolbarCapsuleButtonStyle: ButtonStyle {
  var isActive = false

  func makeBody(configuration: Configuration) -> some View {
    ToolbarCapsuleBody(configuration: configuration, isActive: isActive)
  }
}

private struct ToolbarCapsuleBody: View {
  let configuration: ButtonStyleConfiguration
  let isActive: Bool

  @Environment(\.panelTheme) private var theme
  @Environment(\.isEnabled) private var isEnabled
  @State private var isHovering = false

  var body: some View {
    configuration.label
      .font(.system(size: 12.5, weight: .medium))
      .foregroundStyle(isActive ? theme.accent.accent.color : theme.surface.text.color)
      .lineLimit(1)
      .padding(.horizontal, 10)
      .frame(minHeight: 26)
      .background(background, in: Capsule())
      .opacity(isEnabled ? 1 : 0.4)
      .contentShape(Capsule())
      .onHover { isHovering = $0 }
  }

  private var background: Color {
    if isActive { return theme.accent.accent.color.opacity(configuration.isPressed ? 0.24 : 0.16) }
    if configuration.isPressed { return theme.surface.pressed.color }
    return isHovering ? theme.surface.selected.color : theme.surface.hover.color
  }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
  /// `PrimaryButtonStyle` at its regular size.
  static var panelPrimary: PrimaryButtonStyle { PrimaryButtonStyle() }
  static func panelPrimary(size: PrimaryButtonStyle.Size, expands: Bool = false)
    -> PrimaryButtonStyle
  {
    PrimaryButtonStyle(size: size, expands: expands)
  }
}

extension ButtonStyle where Self == ToolbarCapsuleButtonStyle {
  /// `ToolbarCapsuleButtonStyle` in its resting state.
  static var panelCapsule: ToolbarCapsuleButtonStyle { ToolbarCapsuleButtonStyle() }
  static func panelCapsule(isActive: Bool) -> ToolbarCapsuleButtonStyle {
    ToolbarCapsuleButtonStyle(isActive: isActive)
  }
}
