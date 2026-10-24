import XCTest

@testable import WallpaperMachine

/// Nothing a page of this area says is left in English in another language: every title, note,
/// keyword and choice resolves to a translation, and a placeholder never shows. The same check as
/// the web panel's "no English leaking on its main surfaces", on the declared rows and the words the
/// model hands the views.
@MainActor
final class SettingsSectionsLocalizationTests: XCTestCase {
  private static let sections: [SettingsSection] = [
    .quick, .general, .appearance, .desktop, .playback, .performance,
    .displays, .shortcuts, .library, .storage, .about,
  ]
  /// Words that are the same in every language on purpose: figures, units and file names.
  private static let sameEverywhere: Set<String> = []

  private var items: [SettingsItem] {
    SettingsRegistry.items.filter { Self.sections.contains($0.section) }
  }

  func testEveryPhraseOfEveryRowIsTranslatedInEveryOtherLanguage() {
    let english = PanelLocale(language: .english, region: nil)
    for language in AppLanguage.supported where language != .english {
      let locale = PanelLocale(language: language, region: nil)
      for item in items {
        let resources = [item.title] + [item.note].compactMap { $0 } + item.info + item.keywords
        for resource in resources {
          let base = english.string(resolving: resource)
          let translated = locale.string(resolving: resource)
          guard !Self.sameEverywhere.contains(base) else { continue }
          XCTAssertNotEqual(
            translated, base, "\(item.id) in \(language.tag) is still English: \(base.prefix(60))")
          XCTAssertFalse(
            translated.contains("%@") || translated.contains("%lld") || translated.contains("{"),
            "\(item.id) in \(language.tag) shows a placeholder: \(translated.prefix(60))")
        }
      }
    }
  }

  func testTheWordsTheModelHandsTheViewsAreTranslated() throws {
    let defaults = try TemporaryDefaults.make(for: self).defaults
    addTeardownBlock { @MainActor in PanelLocale.shared.bind(to: .testHost) }
    for language in AppLanguage.supported where language != .english {
      PanelLocale.shared.bind(
        to: AppLanguageStore(defaults: defaults, systemLanguages: [language.tag]))
      let words: [(String, String)] = [
        (QualityPreset.low.title, "Low"), (QualityPreset.medium.title, "Medium"), (QualityPreset.high.title, "High"),
        (QualityPreset.customTitle, "Custom"),
        (DesktopCoveredAction.keepRunning.title, "Keep running"), (OtherAudioAction.mute.title, "Mute"),
        (DisplaySleepAction.stop.title, "Stop (free memory)"),
        (SystemConditionAction.reduceQuality.title, "Reduced quality"),
        (BridgeBatteryMode.pause.title, "Pause"), (AppRuleCondition.frontmost.title, "In front"),
        (AppRuleAction.stop.title, "Stop"), (AppThemePreferences.Mode.system.title, "System (Auto)"),
        (AppThemePreferences.Tone.warm.title, "Warm"), (AppThemePreferences.Icon.night.title, "Night"),
        (SceneResolutionMode.display.title, "Display resolution"),
        (SceneResolutionMode.canvas.title, "Canvas size"),
        (QualityCause.heat.statusText, "The Mac is hot. Reduced quality is in use."),
        (EnergyReadout.Caveat.nativeVideo.title, "Video not counted"),
        (EnergyReadout.title(for: .high), "High energy use"),
        (FrameRateCapSlider(refreshRate: 60).readout(atPosition: 61), "No limit"),
        (GeneralSettingsSection.languageOptions()[0].title, "System (Auto)"),
      ]
      for (translated, base) in words {
        XCTAssertNotEqual(translated, base, "\(language.tag): \(base)")
      }
    }
  }
}
