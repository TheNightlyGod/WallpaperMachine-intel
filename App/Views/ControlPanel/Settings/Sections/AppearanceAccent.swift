import AppKit
import SwiftUI

/// The accent's value and the nine preset swatches next to it, as plain rules.
enum AppearanceAccent {
  /// After the macOS accent colours; the colour well beside them takes any other.
  static let presets = [
    "#80bbff", "#0a84ff", "#5e5ce6", "#bf5af2", "#ff375f", "#ff9f0a", "#ffd60a", "#30d158",
    "#8e8e93",
  ]

  /// How long a colour has to stay put in the colour well before it is saved. The well reports
  /// every colour the pointer passes over, and each save rewrites the preference and tints the
  /// whole window again.
  static let settleDelay: Duration = .milliseconds(350)

  /// The preset the accent is, ignoring case; nil for a colour of the person's own.
  static func preset(for hex: String) -> String? {
    presets.first { $0 == hex.lowercased() }
  }

  /// `#rrggbb`, lower case, from components in 0...1. Each channel is rounded, not cut, so a colour
  /// that went through the colour well comes back as the colour it was.
  static func hex(red: Double, green: Double, blue: Double) -> String {
    func channel(_ value: Double) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
    return String(format: "#%02x%02x%02x", channel(red), channel(green), channel(blue))
  }

  /// The colour as sRGB `#rrggbb`; nil for one that has no sRGB form.
  static func hex(of color: Color) -> String? {
    guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
    return hex(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent)
  }

  static func color(hex: String) -> Color {
    PanelColor(hex: hex)?.color ?? PanelColor(hex: AccentPalette.defaultAccent)!.color
  }
}

/// The Accent color row's control: nine swatches, a colour well for any other colour and the
/// colour's hex, which follows the well as it moves.
///
/// A swatch saves at once. The well saves once the colour has stopped changing
/// (`AppearanceAccent.settleDelay`) and when the page goes away, never on every colour it passes
/// over.
struct AppearanceAccentControl: View {
  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme
  @State private var picked = Color.clear
  /// The colour the well holds that is not saved yet.
  @State private var pending: String?
  @State private var settle: Task<Void, Never>?
  @FocusState private var focusedSwatch: String?

  var body: some View {
    let saved = controller.themePreferences.accent
    // The swatches, the well and the hex wrap onto a second line in a narrow window, and share a
    // centre line within each.
    TagFlow(spacing: 4, centersRows: true) {
      ForEach(AppearanceAccent.presets, id: \.self) { hex in
        AccentSwatch(hex: hex, isSelected: pending == nil && AppearanceAccent.preset(for: saved) == hex) {
          choose(hex)
        }
        .settingsRadioKeys(hex, in: AppearanceAccent.presets, focus: $focusedSwatch) { choose($0) }
      }
      ColorPicker(
        selection: $picked, supportsOpacity: false,
        label: { Text("Custom color") }
      )
      .labelsHidden()
      .frame(width: 38)
      .padding(.leading, 8)
      .help(L("Custom color"))
      Text(verbatim: (pending ?? saved).uppercased())
        .font(.system(size: 12, design: .monospaced))
        .foregroundStyle(theme.surface.muted.color)
        .frame(minWidth: 62, alignment: .leading)
        .padding(.leading, 4)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .contain)
    .onAppear { picked = AppearanceAccent.color(hex: saved) }
    .onChange(of: saved) { _, hex in
      // The accent changed from elsewhere (a swatch, Reset appearance): the well follows it,
      // unless the person is still choosing a colour in it.
      if pending == nil || pending == hex {
        pending = nil
        picked = AppearanceAccent.color(hex: hex)
      }
    }
    .onChange(of: picked) { _, color in
      guard let hex = AppearanceAccent.hex(of: color), hex != saved else { return }
      pending = hex
      settle?.cancel()
      settle = Task { @MainActor in
        try? await Task.sleep(for: AppearanceAccent.settleDelay)
        guard !Task.isCancelled else { return }
        save(hex)
      }
    }
    .onDisappear {
      settle?.cancel()
      if let pending { save(pending) }
    }
  }

  private func choose(_ hex: String) {
    settle?.cancel()
    pending = nil
    save(hex)
  }

  private func save(_ hex: String) {
    controller.settings.applyTheme { try controller.setThemeAccent(hex) }
    pending = nil
  }
}

/// One accent preset: a disc of the colour, ringed and ticked while it is the accent.
private struct AccentSwatch: View {
  let hex: String
  let isSelected: Bool
  let action: () -> Void

  @Environment(\.panelTheme) private var theme
  @State private var isHovering = false

  var body: some View {
    let color = PanelColor(hex: hex) ?? PanelColor(rgb: 0x80bbff)
    Button(action: action) {
      Circle()
        .fill(color.color)
        .overlay { Circle().strokeBorder(Color.black.opacity(0.14), lineWidth: 0.5) }
        .overlay {
          if isSelected {
            Image(systemName: "checkmark")
              .font(.system(size: 9, weight: .bold))
              .foregroundStyle(tick(on: color))
          }
        }
        .frame(width: 20, height: 20)
        .padding(3)
        .overlay {
          Circle()
            .strokeBorder(theme.surface.text.color.opacity(0.5), lineWidth: 1.5)
            .opacity(isSelected ? 1 : 0)
        }
        .scaleEffect(isHovering && !isSelected ? 1.08 : 1)
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
    .accessibilityLabel(Text(verbatim: hex.uppercased()))
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .help(hex.uppercased())
  }

  /// White on a colour that holds it, ink on a light one such as yellow.
  private func tick(on color: PanelColor) -> Color {
    color.contrast(with: PanelColor(rgb: 0xffffff)) >= 3 ? .white : Color.black.opacity(0.75)
  }
}
