import AppKit
import SwiftUI
import XCTest

@testable import WallpaperMachine

@MainActor
final class PanelThemeTests: XCTestCase {
  /// What a view below the root modifier saw the last time it was drawn.
  private final class Seen {
    var theme: PanelTheme?
    var locale: Locale?
    var draws = 0
  }

  private struct Probe: View {
    let seen: Seen
    @Environment(\.panelTheme) private var theme
    @Environment(\.locale) private var locale

    var body: some View {
      seen.theme = theme
      seen.locale = locale
      seen.draws += 1
      return Color.clear.frame(width: 20, height: 20)
    }
  }

  private func preferences(
    accent: String = "#80bbff", tone: AppThemePreferences.Tone = .neutral
  ) -> AppThemePreferences {
    var preferences = AppThemePreferences()
    preferences.accent = accent
    preferences.tone = tone
    return preferences
  }

  /// Draws the probe without showing a window: the hosting view sits in a window that is never ordered.
  private func host(
    _ seen: Seen, theme: AppThemeStore, locale: PanelLocale, dark: Bool = false
  ) -> (NSHostingView<some View>, NSWindow) {
    let view = NSHostingView(rootView: Probe(seen: seen).panelTheme(theme: theme, locale: locale))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 80, height: 80), styleMask: [.titled],
      backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    window.contentView = view
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    view.layoutSubtreeIfNeeded()
    return (view, window)
  }

  private func settle(_ view: NSView) {
    for _ in 0..<4 {
      RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
      view.layoutSubtreeIfNeeded()
    }
  }

  func testThemeDerivesFromThePreferencesAndTheResolvedAppearance() {
    let warm = PanelTheme(preferences: preferences(accent: "#ffd60a", tone: .warm), appearance: .dark)
    XCTAssertEqual(warm.accent, AccentPalette(accent: "#ffd60a", appearance: .dark))
    XCTAssertEqual(warm.surface, SurfacePalette(tone: .warm, appearance: .dark))
    XCTAssertEqual(warm.accent.onPrimary.hex, "#14161a")
    XCTAssertEqual(warm.tone, .warm)
    let light = PanelTheme(appearance: .light)
    XCTAssertEqual(light.accent.base.hex, AccentPalette.defaultAccent)
    XCTAssertNotEqual(light.accent.accent, PanelTheme(appearance: .dark).accent.accent)
  }

  func testRootModifierPublishesThePalettesAndFollowsPreferenceChanges() throws {
    let store = AppThemeStore(defaults: try TemporaryDefaults.make(for: self).defaults)
    let seen = Seen()
    let (view, window) = host(seen, theme: store, locale: PanelLocale(region: nil))
    defer { window.close() }
    XCTAssertEqual(seen.theme?.accent.base.hex, AccentPalette.defaultAccent)
    XCTAssertEqual(seen.theme?.surface, SurfacePalette(tone: .neutral, appearance: .light))

    try store.set("accent", value: "#FFD60A")
    try store.set("tone", value: "cool")
    settle(view)
    XCTAssertEqual(seen.theme?.accent.base.hex, "#ffd60a")
    XCTAssertEqual(seen.theme?.surface, SurfacePalette(tone: .cool, appearance: .light))

    store.reset()
    settle(view)
    XCTAssertEqual(seen.theme?.accent.base.hex, AccentPalette.defaultAccent)
    XCTAssertEqual(seen.theme?.tone, .neutral)
  }

  func testRootModifierReadsTheResolvedAppearanceFromTheEnvironment() throws {
    let store = AppThemeStore(defaults: try TemporaryDefaults.make(for: self).defaults)
    let seen = Seen()
    let (view, window) = host(seen, theme: store, locale: PanelLocale(region: nil), dark: true)
    defer { window.close() }
    XCTAssertEqual(seen.theme?.appearance, .dark)
    XCTAssertEqual(seen.theme?.surface.background.hex, "#1d1d1f")

    window.appearance = NSAppearance(named: .aqua)
    settle(view)
    XCTAssertEqual(seen.theme?.appearance, .light)
    XCTAssertEqual(seen.theme?.surface.background.hex, "#ffffff")
  }

  func testRootModifierPublishesTheLanguageLocaleAndFollowsTheLanguage() throws {
    let store = AppThemeStore(defaults: try TemporaryDefaults.make(for: self).defaults)
    let language = AppLanguageStore(
      defaults: try TemporaryDefaults.make(for: self).defaults, systemLanguages: ["en"])
    let locale = PanelLocale(region: "US")
    locale.bind(to: language)
    let seen = Seen()
    let (view, window) = host(seen, theme: store, locale: locale)
    defer { window.close() }
    XCTAssertEqual(seen.locale?.identifier, "en_US")

    try language.set("ja")
    settle(view)
    XCTAssertEqual(seen.locale?.language.languageCode?.identifier, "ja")
    XCTAssertEqual(seen.locale?.region?.identifier, "US")

    try language.set("zh-Hant")
    settle(view)
    XCTAssertEqual(seen.locale?.language.script?.identifier, "Hant")
  }
}
