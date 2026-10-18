import Foundation

/// The colours an accent produces, contrast-checked so any `#rrggbb`, pure white or black
/// included, still gives a readable filled button, link and focus ring. A pure port of
/// `tokens()` in `WebUI/theme.js`; the golden tests hold it to that file's output.
///
/// Native `.borderedProminent` always draws a white label, which fails for yellow, white and
/// grey accents where this palette flips the label to ink. A filled button therefore paints
/// `primary` (`primaryHover`, `primaryActive`) under `onPrimary` itself.
struct AccentPalette: Equatable, Sendable {
  static let defaultAccent = "#80bbff"

  /// The accent as chosen; for swatches, never for text or fills.
  let base: PanelColor
  /// Text, links and selection on any surface of the appearance.
  let accent: PanelColor
  /// The fill of a prominent button.
  let primary: PanelColor
  let primaryHover: PanelColor
  let primaryActive: PanelColor
  /// `primary` as an outline or ring on a surface.
  let primaryLine: PanelColor
  /// The label on `primary`: white, or ink when the accent is light.
  let onPrimary: PanelColor
  /// Focus rings and other non-text graphics.
  let focus: PanelColor
  /// Glyphs drawn on white.
  let control: PanelColor

  private static let white: UInt32 = 0xffffff
  private static let ink: UInt32 = 0x14161a
  /// The lightest dark surface and the darkest light surface across every tone, as in
  /// `panel.css`, so text accents stay legible whichever tone is chosen.
  private static let darkSurface: UInt32 = 0x3b414b
  private static let lightSurface: UInt32 = 0xe3e8f0
  private static let textRatio = 4.5
  private static let fillRatio = 4.6
  private static let graphicRatio = 3.2
  private static let glyphRatio = 3.0
  /// Below this lightness a hue-preserving fill no longer reads as the chosen accent, so the
  /// label flips to ink instead.
  private static let fillFloor = 0.34
  private static let stateStep = 0.055

  /// - Parameter accent: `#rrggbb`; anything else, as in the stored preference, is the default.
  init(accent: String = Self.defaultAccent, appearance: PanelAppearance) {
    let base = Self.parse(accent)
    let ref = appearance == .dark ? Self.darkSurface : Self.lightSurface
    let primary: UInt32
    let onPrimary: UInt32
    if ContrastMath.contrast(Self.white, base) >= Self.fillRatio {
      primary = base
      onPrimary = Self.white
    } else if ContrastMath.hsl(base).saturation < 0.12 {
      onPrimary = Self.ink
      primary = ContrastMath.fit(base, against: Self.ink, ratio: Self.fillRatio)
    } else {
      let darkened = ContrastMath.fit(base, against: Self.white, ratio: Self.fillRatio)
      if ContrastMath.hsl(darkened).lightness >= Self.fillFloor {
        primary = darkened
        onPrimary = Self.white
      } else {
        onPrimary = Self.ink
        primary = ContrastMath.fit(base, against: Self.ink, ratio: Self.fillRatio)
      }
    }
    // The conventional direction is lighter under a white label and darker under an ink one;
    // the other is used when the preferred one would take the label below AA.
    let preferred = onPrimary == Self.white ? Self.stateStep : -Self.stateStep
    let probe = ContrastMath.shiftLightness(primary, by: preferred)
    let direction =
      probe != primary && ContrastMath.contrast(probe, onPrimary) >= Self.textRatio
      ? preferred : -preferred

    self.base = PanelColor(rgb: base)
    self.accent = PanelColor(
      rgb: ContrastMath.fit(base, against: ref, ratio: Self.textRatio))
    self.primary = PanelColor(rgb: primary)
    primaryHover = PanelColor(
      rgb: ContrastMath.fit(
        ContrastMath.shiftLightness(primary, by: direction), against: onPrimary,
        ratio: Self.textRatio))
    primaryActive = PanelColor(
      rgb: ContrastMath.fit(
        ContrastMath.shiftLightness(primary, by: direction * 2), against: onPrimary,
        ratio: Self.textRatio))
    primaryLine = PanelColor(
      rgb: ContrastMath.fit(primary, against: ref, ratio: Self.graphicRatio))
    self.onPrimary = PanelColor(rgb: onPrimary)
    focus = PanelColor(rgb: ContrastMath.fit(base, against: ref, ratio: Self.graphicRatio))
    control = PanelColor(rgb: ContrastMath.fit(base, against: Self.white, ratio: Self.glyphRatio))
  }

  /// The same six-digit contract as the stored preference and the colour picker.
  private static func parse(_ value: String) -> UInt32 {
    let raw = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return PanelColor(hex: raw)?.rgb ?? PanelColor(hex: defaultAccent)!.rgb
  }
}
