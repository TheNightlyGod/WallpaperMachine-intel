import AppKit
import SwiftUI
import XCTest

@testable import WallpaperMachine

/// Settings › Appearance and General › Language as the page drives them: what a choice sends, what the
/// accent control writes and when, and what the language menu offers. The stores themselves are
/// `AppThemeTests` and `AppLanguageTests`.
@MainActor
final class AppearanceSettingsTests: PanelTestCase {
  // MARK: Accent

  func testHexIsRoundedLowerCasedAndClampedNotCut() {
    XCTAssertEqual(AppearanceAccent.hex(red: 0, green: 0, blue: 0), "#000000")
    XCTAssertEqual(AppearanceAccent.hex(red: 1, green: 1, blue: 1), "#ffffff")
    XCTAssertEqual(AppearanceAccent.hex(red: 0xb4 / 255, green: 0x32 / 255, blue: 0x71 / 255), "#b43271")
    XCTAssertEqual(AppearanceAccent.hex(red: 0.5, green: 0.5, blue: 0.5), "#808080", "127.5 rounds up, not down")
    XCTAssertEqual(AppearanceAccent.hex(red: 0.999, green: 0.001, blue: 0.4999), "#ff007f")
    XCTAssertEqual(AppearanceAccent.hex(red: -3, green: 7, blue: 0), "#00ff00", "Out of range is clamped")
  }

  func testEverySavedAccentComesBackFromTheColourWellAsItself() throws {
    for hex in AppearanceAccent.presets + ["#000000", "#ffffff", "#b43271", "#123456", "#fedcba"] {
      let color = AppearanceAccent.color(hex: hex)
      XCTAssertEqual(AppearanceAccent.hex(of: color), hex, "\(hex) must survive the round trip through a Color")
    }
  }

  func testThePresetsAreTheNineAccentsAndTheDefaultComesFirst() {
    XCTAssertEqual(AppearanceAccent.presets.count, 9)
    XCTAssertEqual(AppearanceAccent.presets.first, AccentPalette.defaultAccent)
    XCTAssertEqual(Set(AppearanceAccent.presets).count, 9)
    for hex in AppearanceAccent.presets { XCTAssertTrue(AppThemePreferences.validAccent(hex)) }
    XCTAssertEqual(AppearanceAccent.preset(for: "#0A84FF"), "#0a84ff", "Case does not matter")
    XCTAssertNil(AppearanceAccent.preset(for: "#b43271"), "A colour of the person's own matches no swatch")
  }

  func testTheColourWellWaitsForTheColourToSettleBeforeItSaves() {
    XCTAssertGreaterThanOrEqual(AppearanceAccent.settleDelay, .milliseconds(250))
    XCTAssertLessThanOrEqual(AppearanceAccent.settleDelay, .milliseconds(500))
  }

  // MARK: What a choice sends

  func testEveryChoiceIsSavedWithTheFormatTheStoreHadAndResetKeepsUnrelatedPreferences() async throws {
    try await withRecordingPanel { panel, _ in
      let controller = panel.controller
      let settings = controller.settings
      panel.defaults.set("kept", forKey: "unrelatedPreference")

      settings.applyTheme { try controller.setThemeMode(.dark) }
      settings.applyTheme { try controller.setThemeAccent("#B43271") }
      settings.applyTheme { try controller.setThemeTone(.warm) }
      settings.applyTheme { try controller.setThemeIcon(.night) }
      XCTAssertEqual(controller.themePreferences.mode, .dark)
      XCTAssertEqual(controller.themePreferences.accent, "#b43271", "The accent is kept in lower case")
      XCTAssertEqual(controller.themePreferences.tone, .warm)
      XCTAssertEqual(controller.themePreferences.icon, .night)
      let saved = try XCTUnwrap(panel.defaults.dictionary(forKey: AppThemeStore.defaultsKey) as? [String: String])
      XCTAssertEqual(saved, ["mode": "dark", "accent": "#b43271", "tone": "warm", "icon": "night"])

      settings.applyTheme { controller.resetTheme() }
      XCTAssertEqual(controller.themePreferences, AppThemePreferences())
      XCTAssertEqual(controller.themePreferences.icon, .day)
      XCTAssertEqual(panel.defaults.string(forKey: "unrelatedPreference"), "kept")
      XCTAssertNil(panel.defaults.object(forKey: AppThemeStore.defaultsKey))
    }
  }

  func testEveryChoiceOfTheThreeCardRowsHasAMiniatureAndAName() throws {
    try pinPanelLanguageToEnglish()
    XCTAssertEqual(AppThemePreferences.Mode.allCases.map(\.title), ["System (Auto)", "Light", "Dark"])
    XCTAssertEqual(AppThemePreferences.Tone.allCases.map(\.title), ["Neutral", "Warm", "Cool"])
    XCTAssertEqual(AppThemePreferences.Icon.allCases.map(\.title), ["Minimal", "Day", "Night"])
    for appearance in [PanelAppearance.light, .dark] {
      let tones = AppThemePreferences.Tone.allCases.map {
        SurfacePalette.miniature(tone: $0, appearance: appearance).background
      }
      XCTAssertEqual(Set(tones).count, 3, "The tone cards are told apart by their colour")
    }
    XCTAssertNotEqual(
      SurfacePalette.miniature(tone: .neutral, appearance: .light).background,
      SurfacePalette.miniature(tone: .neutral, appearance: .dark).background)
  }

  func testEveryAppIconTheCardsShowIsInTheAssetCatalogAndLoadsForTheDock() throws {
    for icon in AppThemePreferences.Icon.allCases {
      XCTAssertNotNil(NSImage(named: NSImage.Name(icon.imageName)), "\(icon.imageName) is not in the asset catalog")
      XCTAssertNoThrow(try icon.image(), "\(icon) must load as the Dock icon")
    }
  }

  // MARK: Language

  func testTheLanguageMenuOffersSystemFirstAndEveryShippedLanguageUnderItsOwnName() throws {
    try pinPanelLanguageToEnglish()
    let options = GeneralSettingsSection.languageOptions()
    XCTAssertEqual(options.map(\.value), [AppLanguageStore.systemChoice] + AppLanguage.supported.map(\.tag))
    XCTAssertEqual(options.map(\.title), ["System (Auto)"] + AppLanguage.supported.map(\.name))

    // Their own names are never translated, whatever the panel shows.
    let japanese = AppLanguageStore(
      defaults: try TemporaryDefaults.make(for: self).defaults, systemLanguages: ["ja"])
    PanelLocale.shared.bind(to: japanese)
    addTeardownBlock { @MainActor in PanelLocale.shared.bind(to: .testHost) }
    let inJapanese = GeneralSettingsSection.languageOptions()
    XCTAssertEqual(Array(inJapanese.map(\.title).dropFirst()), AppLanguage.supported.map(\.name))
    XCTAssertNotEqual(inJapanese.first?.title, "System (Auto)", "Only the system entry follows the language")
  }

  func testChoosingALanguageSwitchesThePanelAtOnceAndSystemGoesBack() async throws {
    try await withRecordingPanel { panel, _ in
      let controller = panel.controller
      let settings = controller.settings
      PanelLocale.shared.bind(to: controller.appLanguage)
      addTeardownBlock { @MainActor in PanelLocale.shared.bind(to: .testHost) }
      XCTAssertEqual(PanelLocale.shared.tag, "en")

      let choices = AppLanguage.supported.map { ($0.tag, $0.tag) } + [(AppLanguageStore.systemChoice, "en")]
      for (tag, expected) in choices {
        let task = try XCTUnwrap(
          settings.commit("language", to: tag) { try await controller.setLanguage(AppLanguage.named($0)) })
        await task.value
        XCTAssertEqual(PanelLocale.shared.tag, expected)
        XCTAssertEqual(controller.languagePreference?.tag ?? AppLanguageStore.systemChoice, tag)
      }
      XCTAssertNil(controller.errors.message)
    }
  }
}
