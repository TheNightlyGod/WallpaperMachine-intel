import Foundation

/// The surface, text and divider colours of one surface tone in one appearance: the tone ×
/// appearance table of `WebUI/panel.css`. Neutral is the untinted look; Warm and Cool shift
/// every surface and text colour a little toward amber or blue. Contrast-fitted accent colours
/// live in `AccentPalette`; media overlays are always dark and never toned, so they are not here.
struct SurfacePalette: Equatable, Sendable {
  /// The window and content background.
  let background: PanelColor
  /// Footers, bars and grouped sections over `background`.
  let surface: PanelColor
  let card: PanelColor
  let raised: PanelColor
  let raisedHover: PanelColor
  /// Wells that sit lower than their surroundings, such as text fields.
  let sunken: PanelColor
  let well: PanelColor
  /// Behind artwork while it loads.
  let mediaWell: PanelColor
  let text: PanelColor
  let muted: PanelColor
  let faint: PanelColor
  let tagInk: PanelColor
  let badge: PanelColor
  /// The selected segment of a segmented control.
  let segmentSelected: PanelColor
  /// What the window shows behind a sidebar that cannot draw the system material.
  let sidebarFallback: PanelColor
  /// A tint laid over the sidebar material.
  let sidebarTint: PanelColor
  /// Hairlines: the stronger `line` and the quieter `divider`, as translucent black or white.
  let line: PanelColor
  let divider: PanelColor
  /// Translucent states for rows and buttons.
  let hover: PanelColor
  let pressed: PanelColor
  let selected: PanelColor
  let danger: PanelColor
  let warning: PanelColor
  let approved: PanelColor
  let heart: PanelColor

  init(tone: AppThemePreferences.Tone, appearance: PanelAppearance) {
    let dark = appearance == .dark
    let toneColumn =
      switch tone {
      case .neutral: 0
      case .warm: 1
      case .cool: 2
      }
    let column = (dark ? 0 : 3) + toneColumn
    /// One row of the table: dark neutral, warm, cool, then light neutral, warm, cool.
    func toned(_ row: String) -> PanelColor {
      PanelColor(hex: row.split(separator: " ").map(String.init)[column])!
    }
    func byAppearance(dark darkHex: String, light lightHex: String) -> PanelColor {
      PanelColor(hex: dark ? darkHex : lightHex)!
    }
    func overlay(_ darkAlpha: Double, _ lightAlpha: Double) -> PanelColor {
      dark
        ? PanelColor(rgb: 0xffffff, alpha: darkAlpha) : PanelColor(rgb: 0, alpha: lightAlpha)
    }

    background = toned("#1d1d1f #1f1d1b #1b1d22 #ffffff #fffdf9 #fbfcfe")
    surface = toned("#222224 #252220 #20232a #f7f7f8 #f8f5ef #f3f5f9")
    card = toned("#2a2a2c #2d2a27 #282c34 #ffffff #fffdf9 #ffffff")
    raised = toned("#3a3a3c #3d3935 #383c46 #ffffff #fffdf9 #ffffff")
    raisedHover = toned("#464648 #4a4540 #444955 #f4f4f6 #f4efe6 #eef1f6")
    sunken = toned("#19191b #1b1917 #171920 #ffffff #ffffff #ffffff")
    well = toned("#2a2a2c #2d2a27 #282c34 #f2f2f4 #f3eee5 #eef1f6")
    mediaWell = toned("#151517 #171513 #13151a #e9e9ed #ebe5da #e4e8ef")
    text = toned("#f2f2f4 #f5f1ea #eff2f7 #1d1d1f #221e18 #171b23")
    muted = toned("#a1a1a7 #b0a89c #a2a9b8 #6e6e73 #6d665a #626a79")
    faint = toned("#6c6c72 #786f64 #6a7180 #a1a1a6 #a69e90 #9aa2b0")
    tagInk = toned("#d1d1d6 #d8d0c4 #ccd3de #4a4a4f #4f483f #454d5c")
    badge = toned("#48484c #4f4840 #454c5a #e3e3e8 #e8e1d5 #dfe4ec")
    sidebarFallback = toned("#2b2b2e #2f2b27 #282c34 #ebebee #eee9df #e9edf3")
    segmentSelected = byAppearance(dark: "#636366", light: "#ffffff")
    // The light tints are the neutral one for every tone.
    sidebarTint =
      switch (dark, tone) {
      case (true, .neutral): PanelColor(rgb: 0x1e1e21, alpha: 0.18)
      case (true, .warm): PanelColor(rgb: 0x281e12, alpha: 0.16)
      case (true, .cool): PanelColor(rgb: 0x121c2e, alpha: 0.16)
      case (false, _): PanelColor(rgb: 0xffffff, alpha: 0.22)
      }
    line = overlay(0.12, 0.13)
    divider = overlay(0.08, 0.08)
    hover = overlay(0.07, 0.05)
    pressed = overlay(0.12, 0.09)
    selected = overlay(0.11, 0.08)
    danger = byAppearance(dark: "#ff7b72", light: "#c4161c")
    warning = byAppearance(dark: "#ffcf66", light: "#915200")
    approved = byAppearance(dark: "#4cd964", light: "#248a3d")
    heart = byAppearance(dark: "#ff5c86", light: "#e0245e")
  }

  /// The three colours of a miniature window, as the Settings appearance cards and the welcome
  /// guide draw one: its background, the sidebar bar and a line of text.
  struct Miniature: Equatable, Sendable {
    let background: PanelColor
    let bar: PanelColor
    let line: PanelColor
  }

  /// A miniature of the panel in a tone and appearance. Warm and Cool tint only the background.
  static func miniature(tone: AppThemePreferences.Tone, appearance: PanelAppearance) -> Miniature {
    let dark = appearance == .dark
    let base = dark ? PanelColor(rgb: 0x2c2c2e) : PanelColor(rgb: 0xf5f5f7)
    let background: PanelColor
    switch tone {
    case .neutral:
      background = base
    case .warm:
      background = dark ? mix(base, 0.78, 0x6b4a26) : mix(base, 0.55, 0xf4e7d3)
    case .cool:
      background = dark ? mix(base, 0.78, 0x26446b) : mix(base, 0.55, 0xdbe5f3)
    }
    return Miniature(
      background: background, bar: PanelColor(rgb: dark ? 0x1c1c1e : 0xe2e2e7),
      line: PanelColor(rgb: dark ? 0x48484c : 0xc9c9d0))
  }

  /// `share` of `color` and the rest of `other`, channel by channel in sRGB, as CSS `color-mix`.
  private static func mix(_ color: PanelColor, _ share: Double, _ other: UInt32) -> PanelColor {
    func channel(_ shift: UInt32) -> UInt32 {
      let a = Double((color.rgb >> shift) & 255)
      let b = Double((other >> shift) & 255)
      return UInt32((a * share + b * (1 - share)).rounded())
    }
    return PanelColor(rgb: (channel(16) << 16) | (channel(8) << 8) | channel(0))
  }
}
