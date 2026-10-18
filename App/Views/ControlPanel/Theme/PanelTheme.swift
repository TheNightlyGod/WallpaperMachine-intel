import SwiftUI

/// Whether the panel is drawn light or dark; the resolved appearance, never the stored mode.
enum PanelAppearance: Sendable {
  case light, dark

  init(_ scheme: ColorScheme) {
    self = scheme == .dark ? .dark : .light
  }
}

/// Everything the panel's look derives from the appearance preferences: the contrast-fitted
/// accent tokens and the tone's surface tokens for the resolved light or dark appearance.
struct PanelTheme: Equatable, Sendable {
  let tone: AppThemePreferences.Tone
  let appearance: PanelAppearance
  let accent: AccentPalette
  let surface: SurfacePalette

  init(preferences: AppThemePreferences = AppThemePreferences(), appearance: PanelAppearance) {
    tone = preferences.tone
    self.appearance = appearance
    accent = AccentPalette(accent: preferences.accent, appearance: appearance)
    surface = SurfacePalette(tone: preferences.tone, appearance: appearance)
  }
}

extension EnvironmentValues {
  /// The palettes of the panel the view is in; the defaults outside one (previews, tests).
  @Entry var panelTheme = PanelTheme(appearance: .light)
}

extension View {
  /// Applies the panel's look and language to every view below: the accent as the tint, the
  /// palettes in `\.panelTheme`, and the formatting locale for literals that localize themselves.
  ///
  /// The root view calls this once. It re-renders its content when the stored accent or tone
  /// changes, when the language does, and when the resolved appearance flips. It does not
  /// choose light or dark: `AppDelegate` applies the mode through `NSApp.appearance`, the
  /// single writer, and this reads the result from the environment.
  func panelTheme(theme: AppThemeStore, locale: PanelLocale) -> some View {
    modifier(PanelThemeModifier(theme: theme, locale: locale))
  }
}

private struct PanelThemeModifier: ViewModifier {
  @ObservedObject var theme: AppThemeStore
  let locale: PanelLocale
  @Environment(\.colorScheme) private var colorScheme

  func body(content: Content) -> some View {
    let resolved = PanelTheme(
      preferences: theme.preferences, appearance: PanelAppearance(colorScheme))
    content
      .environment(\.panelTheme, resolved)
      .environment(\.locale, locale.locale)
      .tint(resolved.accent.accent.color)
  }
}
