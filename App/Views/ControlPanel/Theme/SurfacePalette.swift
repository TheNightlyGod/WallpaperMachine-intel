import Foundation

/// The surface, text and divider colours of one surface tone in one appearance: the tone ×
/// appearance table of `WebUI/panel.css`. Neutral is the untinted look; Warm and Cool shift
/// every surface and text colour a little toward amber or blue. A season has a column of its own
/// beside the tones (Halloween: moonlit ink in the dark, candlelit parchment in the light).
/// Contrast-fitted accent colours live in `AccentPalette`; media overlays are always dark and
/// never toned, so they are not here.
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
  /// A mark over a preview picture (a Library or Workshop tile's chips): a dark disc and a
  /// white glyph in both appearances, since the picture under it is either.
  let markFill: PanelColor
  let markGlyph: PanelColor
  /// The approved trophy on that dark disc: a bright green in both appearances, since the
  /// light-appearance `approved` green is too dark to read on it.
  let markApproved: PanelColor

  init(tone: AppThemePreferences.Tone, appearance: PanelAppearance) {
    self.init(look: .tone(tone), appearance: appearance)
  }

  /// The season's own surfaces, which stand in for the tone's while the season is on.
  init(season: Season, appearance: PanelAppearance) {
    self.init(look: .season(season), appearance: appearance)
  }

  /// A column of the table: one of the tones or a season's.
  private enum Look {
    case tone(AppThemePreferences.Tone)
    case season(Season)
  }

  private init(look: Look, appearance: PanelAppearance) {
    let dark = appearance == .dark
    let lookColumn =
      switch look {
      case .tone(.neutral): 0
      case .tone(.warm): 1
      case .tone(.cool): 2
      case .season(.halloween): 3
      }
    let column = (dark ? 0 : 4) + lookColumn
    /// One row of the table: dark neutral, warm, cool, Halloween, then light neutral, warm, cool,
    /// Halloween.
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

    background = toned("#1d1d1f #1f1d1b #1b1d22 #17121f #ffffff #fffdf9 #fbfcfe #fbf7ef")
    surface = toned("#222224 #252220 #20232a #1c1626 #f7f7f8 #f8f5ef #f3f5f9 #f5efe3")
    card = toned("#2a2a2c #2d2a27 #282c34 #231c2e #ffffff #fffdf9 #ffffff #fffcf6")
    raised = toned("#3a3a3c #3d3935 #383c46 #322940 #ffffff #fffdf9 #ffffff #fffcf6")
    raisedHover = toned("#464648 #4a4540 #444955 #3d324d #f4f4f6 #f4efe6 #eef1f6 #f1e9da")
    sunken = toned("#19191b #1b1917 #171920 #120e19 #ffffff #ffffff #ffffff #ffffff")
    well = toned("#2a2a2c #2d2a27 #282c34 #231c2e #f2f2f4 #f3eee5 #eef1f6 #f1eadc")
    mediaWell = toned("#151517 #171513 #13151a #0f0b15 #e9e9ed #ebe5da #e4e8ef #e8dfcd")
    text = toned("#f2f2f4 #f5f1ea #eff2f7 #f3ecdf #1d1d1f #221e18 #171b23 #1c1526")
    muted = toned("#a1a1a7 #b0a89c #a2a9b8 #b0a3bf #6e6e73 #6d665a #626a79 #6a5f73")
    faint = toned("#6c6c72 #786f64 #6a7180 #786b88 #a1a1a6 #a69e90 #9aa2b0 #a497a8")
    tagInk = toned("#d1d1d6 #d8d0c4 #ccd3de #d6cce0 #4a4a4f #4f483f #454d5c #4a3f55")
    badge = toned("#48484c #4f4840 #454c5a #4a3d5c #e3e3e8 #e8e1d5 #dfe4ec #e9dfcf")
    sidebarFallback = toned("#2b2b2e #2f2b27 #282c34 #2a2236 #ebebee #eee9df #e9edf3 #eee6d6")
    segmentSelected = byAppearance(dark: "#636366", light: "#ffffff")
    // The light tints are the neutral one for every tone and season.
    sidebarTint =
      switch (dark, look) {
      case (true, .tone(.neutral)): PanelColor(rgb: 0x1e1e21, alpha: 0.18)
      case (true, .tone(.warm)): PanelColor(rgb: 0x281e12, alpha: 0.16)
      case (true, .tone(.cool)): PanelColor(rgb: 0x121c2e, alpha: 0.16)
      case (true, .season(.halloween)): PanelColor(rgb: 0x1e1230, alpha: 0.18)
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
    markFill = PanelColor(rgb: 0, alpha: 0.58)
    markGlyph = PanelColor(rgb: 0xffffff)
    markApproved = PanelColor(rgb: 0x5cf27c)
  }

  /// The three colours of a miniature window, as the Settings appearance cards and the welcome
  /// guide draw one: its background, the sidebar bar and a line of text. A season's also has a
  /// moon in its corner.
  struct Miniature: Equatable, Sendable {
    let background: PanelColor
    let bar: PanelColor
    let line: PanelColor
    var moon: PanelColor?
  }

  /// A miniature of the panel in a season's look and an appearance.
  static func miniature(season: Season, appearance: PanelAppearance) -> Miniature {
    switch (season, appearance) {
    case (.halloween, .dark):
      Miniature(
        background: PanelColor(rgb: 0x241b31), bar: PanelColor(rgb: 0x120d19),
        line: PanelColor(rgb: 0x4a3d5c), moon: PanelColor(rgb: 0xf2e8cc))
    case (.halloween, .light):
      Miniature(
        background: PanelColor(rgb: 0xf3ead9), bar: PanelColor(rgb: 0xe2d6c0),
        line: PanelColor(rgb: 0xcdbfa6), moon: PanelColor(rgb: 0xe0b25c))
    }
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
