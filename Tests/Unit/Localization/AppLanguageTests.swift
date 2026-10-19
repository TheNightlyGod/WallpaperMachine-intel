import XCTest

@testable import WallpaperMachine

@MainActor
final class AppLanguageTests: XCTestCase {
  /// A fresh suite. The app-domain `AppleLanguages` override is read back through the
  /// persistent domain because a suite's search list falls through to the global one.
  @MainActor private struct Suite {
    let defaults: UserDefaults
    let name: String
    init(_ test: XCTestCase) throws { (defaults, name) = try TemporaryDefaults.make(for: test) }
    var appleLanguages: [String]? {
      defaults.persistentDomain(forName: name)?[AppLanguageStore.appleLanguagesKey] as? [String]
    }
  }

  func testFollowsTheSystemLanguageUntilTheUserChooses() throws {
    let suite = try Suite(self)
    let cases: [([String], String)] = [
      (["zh-CN"], "zh-Hans"), (["zh"], "zh-Hans"), (["zh-Hans-TW"], "zh-Hans"),
      (["fr", "zh-CN", "en"], "zh-Hans"), (["zh-TW"], "zh-Hant"), (["zh-Hant-HK"], "zh-Hant"),
      (["ja-JP"], "ja"), (["fr", "ja", "zh-CN"], "ja"),
      (["ko"], "ko"), (["ko-KR"], "ko"), (["fr", "ko-KR", "en"], "ko"),
      (["ko-KR", "ja-JP"], "ko"), (["ja-JP", "ko-KR"], "ja"),
      (["en-GB"], "en"), (["fr"], "en"), ([], "en"), (["zhgarbage"], "en"),
    ]
    for (system, expected) in cases {
      let store = AppLanguageStore(defaults: suite.defaults, systemLanguages: system)
      XCTAssertEqual(store.preference, AppLanguageStore.systemChoice, "\(system)")
      XCTAssertEqual(store.effective.tag, expected, "\(system)")
    }
  }

  func testChoiceSurvivesRecreationAndReachesAppleLanguages() throws {
    let suite = try Suite(self)
    suite.defaults.set(true, forKey: "unrelatedPreference")
    for language in AppLanguage.supported {
      let store = AppLanguageStore(defaults: suite.defaults, systemLanguages: ["en-US", "fr"])
      try store.set(language.tag)
      XCTAssertEqual(store.effective.tag, language.tag)

      let restored = AppLanguageStore(defaults: suite.defaults, systemLanguages: ["en-US", "fr"])
      XCTAssertEqual(restored.preference, language.tag)
      XCTAssertEqual(restored.effective.tag, language.tag)
      // Foundation reads this list at launch; the choice must lead and the user's order follow.
      XCTAssertEqual(suite.appleLanguages, [language.tag, "en-US", "fr"])

      try restored.set(AppLanguageStore.systemChoice)
      XCTAssertEqual(restored.effective.tag, "en")
      let system = AppLanguageStore(defaults: suite.defaults, systemLanguages: ["zh-CN"])
      XCTAssertEqual(system.preference, AppLanguageStore.systemChoice)
      XCTAssertEqual(system.effective.tag, "zh-Hans")
      XCTAssertNil(suite.appleLanguages, "Returning to System must hand the language back to macOS")
      XCTAssertTrue(suite.defaults.bool(forKey: "unrelatedPreference"))
    }
  }

  func testUnknownOrUnsafeTagsAreRefusedAndKeepTheSavedChoice() throws {
    let suite = try Suite(self)
    let store = AppLanguageStore(defaults: suite.defaults, systemLanguages: ["en"])
    try store.set("zh-Hans")
    for value in ["zh-TW", "zh-CN", "fr", "", "en';alert(1);//", "SYSTEM"] {
      XCTAssertThrowsError(try store.set(value), value)
    }
    XCTAssertEqual(store.preference, "zh-Hans")
    XCTAssertEqual(
      AppLanguageStore(defaults: suite.defaults, systemLanguages: ["en"]).preference, "zh-Hans")
    XCTAssertEqual(suite.appleLanguages?.first, "zh-Hans")
  }

  func testDamagedSavedChoiceFallsBackToSystem() throws {
    let suite = try Suite(self)
    suite.defaults.set("tlh", forKey: AppLanguageStore.defaultsKey)
    let store = AppLanguageStore(defaults: suite.defaults, systemLanguages: ["zh-CN"])
    XCTAssertEqual(store.preference, AppLanguageStore.systemChoice)
    XCTAssertEqual(store.effective.tag, "zh-Hans")
  }

  func testEveryShippedLanguageNamesItsWallpaperEngineLocale() throws {
    let codes = AppLanguage.supported.map(\.wallpaperEngineLocale)
    XCTAssertEqual(Set(codes).count, codes.count, "Two languages cannot read the same label table first")
    for code in codes {
      XCTAssertNotNil(
        code.range(of: "^[a-z]{2}-[a-z]{2,3}$", options: .regularExpression),
        "\(code) is not a Wallpaper Engine locale code")
    }
    let expected = [
      "en": "en-us", "zh-Hans": "zh-chs", "zh-Hant": "zh-cht", "ja": "ja-jp", "ko": "ko-kr",
    ]
    XCTAssertEqual(
      Dictionary(uniqueKeysWithValues: AppLanguage.supported.map { ($0.tag, $0.wallpaperEngineLocale) }),
      expected)

    // Whatever the language, a wallpaper that only ships English still gets read.
    for language in AppLanguage.supported {
      let locales = language.labelLocales
      XCTAssertEqual(locales.first, language.wallpaperEngineLocale, language.tag)
      XCTAssertEqual(locales.last, "en-us", language.tag)
      XCTAssertEqual(Set(locales).count, locales.count, "\(language.tag): repeated locale")
    }
    XCTAssertEqual(AppLanguage.english.labelLocales, ["en-us"])
    XCTAssertEqual(AppLanguage.named("ja")?.labelLocales, ["ja-jp", "en-us"])
  }

  func testSnapshotOffersEveryShippedLanguageByItsOwnName() throws {
    let suite = try Suite(self)
    let store = AppLanguageStore(defaults: suite.defaults, systemLanguages: ["en"])
    let options = try XCTUnwrap(store.snapshot["options"] as? [[String: String]])
    XCTAssertEqual(options.map { $0["id"] }, AppLanguage.supported.map(\.tag))
    XCTAssertTrue(options.contains { $0["id"] == "zh-Hans" && $0["name"] == "简体中文" })
    XCTAssertTrue(options.contains { $0["id"] == "en" && $0["name"] == "English" })
    XCTAssertEqual(store.snapshot["preference"] as? String, AppLanguageStore.systemChoice)
    XCTAssertEqual(store.snapshot["effective"] as? String, "en")
    // The tests are hosted in the app, so its bundle is the one the picker describes.
    for option in options {
      let tag = try XCTUnwrap(option["id"])
      XCTAssertTrue(
        Bundle.main.localizations.contains(tag),
        "\(tag): the picker offers a language the app does not ship")
    }
  }
}
