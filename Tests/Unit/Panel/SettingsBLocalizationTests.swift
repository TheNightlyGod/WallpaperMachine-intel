import XCTest

@testable import WallpaperMachine

/// The words Displays builds from the model are not left in English in another language, such as
/// the held playlist's "Playlist paused" and its Resume playlist row. The phrases the rows declare
/// are checked with every other section's by `SettingsSectionsLocalizationTests`.
@MainActor
final class SettingsBLocalizationTests: XCTestCase {
  func testTheWordsThePagesBuildFromTheModelAreTranslated() throws {
    let defaults = try TemporaryDefaults.make(for: self).defaults
    addTeardownBlock { @MainActor in PanelLocale.shared.bind(to: .testHost) }
    func words() -> [String] {
      [
        L("Playlist paused"), L("Resume playlist"),
        L("This display’s wallpaper was removed, so its playlist waits until you choose a wallpaper or resume it."),
        DisplaysPlaylistDisclosure.modeTitle(.rotate), DisplaysPlaylistDisclosure.modeTitle(.dayNight),
        L("Playlist: \(DisplaysPlaylistDisclosure.modeTitle(.rotate))"),
        L("Limited to \(24) fps by Performance settings"),
        L("Any whole number of minutes, up to \(IntervalChoice.range.upperBound)."),
        DisplaysRuleSummary.shortName(of: 2), DisplaysRuleSummary.fullName(of: 7), L("min"),
      ]
    }
    PanelLocale.shared.bind(to: AppLanguageStore(defaults: defaults, systemLanguages: ["en"]))
    let english = words()
    for language in AppLanguage.supported where language != .english {
      PanelLocale.shared.bind(to: AppLanguageStore(defaults: defaults, systemLanguages: [language.tag]))
      // Portuguese abbreviates minutes as English does.
      let same: Set<String> = language.tag == "pt-BR" ? ["min"] : []
      for (translated, base) in zip(words(), english) where !same.contains(base) {
        XCTAssertNotEqual(translated, base, "\(language.tag): \(base)")
      }
    }
  }
}
