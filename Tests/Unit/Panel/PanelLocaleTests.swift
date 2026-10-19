import Observation
import XCTest

@testable import WallpaperMachine

@MainActor
final class PanelLocaleTests: XCTestCase {
  /// `onChange` is `@Sendable`; the change itself arrives synchronously on the main actor.
  private final class Counter: @unchecked Sendable {
    private(set) var value = 0
    func increment() { value += 1 }
  }

  private func store(_ choice: String? = nil, system: [String] = ["en"]) throws -> AppLanguageStore {
    let store = AppLanguageStore(
      defaults: try TemporaryDefaults.make(for: self).defaults, systemLanguages: system)
    if let choice { try store.set(choice) }
    return store
  }

  private func panel(_ tag: String) -> PanelLocale {
    PanelLocale(language: AppLanguage.named(tag) ?? .english, region: nil)
  }

  private func order(_ text: String, _ first: String, _ second: String) throws -> Bool {
    let a = try XCTUnwrap(text.range(of: first), "\(first) missing from \(text)")
    let b = try XCTUnwrap(text.range(of: second), "\(second) missing from \(text)")
    return a.lowerBound < b.lowerBound
  }

  func testEveryShippedLanguageResolvesMigratedPhrasesFromItsOwnBundle() {
    for language in AppLanguage.supported {
      let locale = panel(language.tag)
      let phrase = locale.string("Follow desktop Space")
      let runtime = locale.catalogString("Steam password")
      if language.tag == "en" {
        XCTAssertEqual(phrase, "Follow desktop Space")
        XCTAssertEqual(runtime, "Steam password")
      } else {
        XCTAssertNotEqual(phrase, "Follow desktop Space", language.tag)
        XCTAssertNotEqual(runtime, "Steam password", language.tag)
        XCTAssertFalse(phrase.isEmpty, language.tag)
      }
      XCTAssertEqual(locale.tag, language.tag)
      XCTAssertEqual(locale.bundle.bundleURL.lastPathComponent, "\(language.tag).lproj")
    }
  }

  func testIntegerAndStringArgumentsAreInterpolatedInEveryLanguage() {
    let name = "Library ⟦A⟧"
    for language in AppLanguage.supported {
      let locale = panel(language.tag)
      let count = locale.string("\(17) wallpapers")
      XCTAssertTrue(count.contains("17"), "\(language.tag): \(count)")
      XCTAssertFalse(count.contains("%"), "\(language.tag): \(count)")
      let forget = locale.string("Forget choice for \(name)")
      XCTAssertTrue(forget.contains(name), "\(language.tag): \(forget)")
      XCTAssertFalse(forget.contains("%"), "\(language.tag): \(forget)")
    }
    XCTAssertEqual(panel("en").string("\(17) wallpapers"), "17 wallpapers")
  }

  func testReorderedPlaceholdersLandInTheirOwnPositions() throws {
    let name = "NAMEVALUE"
    let time = "TIMEVALUE"
    XCTAssertTrue(
      try order(panel("en").string("Next: \(name) at \(time)"), name, time), "English keeps the order")
    for tag in ["ja", "zh-Hans", "zh-Hant"] {
      let text = panel(tag).string("Next: \(name) at \(time)")
      XCTAssertFalse(try order(text, name, time), "\(tag) puts the time first: \(text)")
      XCTAssertEqual(text.components(separatedBy: name).count, 2, text)
      XCTAssertEqual(text.components(separatedBy: time).count, 2, text)
    }
    // Two integers: Japanese says "page N of M" with the total first.
    let japanese = panel("ja").string("Page \(3) of \(17)")
    XCTAssertFalse(try order(japanese, "3", "17"), japanese)
    XCTAssertTrue(try order(panel("en").string("Page \(3) of \(17)"), "3", "17"))
  }

  func testRepeatedArgumentFillsEveryPlaceInItsPhrase() {
    let limit = 250
    for language in AppLanguage.supported {
      let text = panel(language.tag).string(
        "More than \(limit) files match; only the first \(limit) are used.")
      XCTAssertEqual(text.components(separatedBy: "250").count, 3, "\(language.tag): \(text)")
      XCTAssertFalse(text.contains("%"), "\(language.tag): \(text)")
    }
  }

  func testLiteralPercentSignShowsExactlyOnce() {
    for language in AppLanguage.supported {
      let locale = panel(language.tag)
      let withArgument = locale.string("Downloading \(42)%")
      XCTAssertTrue(withArgument.contains("42%"), "\(language.tag): \(withArgument)")
      XCTAssertFalse(withArgument.contains("%%"), "\(language.tag): \(withArgument)")
      XCTAssertFalse(withArgument.contains("%lld"), "\(language.tag): \(withArgument)")
      for phrase in [
        locale.string("100% (native)"), locale.string("Up to 60 fps at 75% resolution."),
      ] {
        XCTAssertFalse(phrase.contains("%%"), "\(language.tag): \(phrase)")
        XCTAssertTrue(phrase.contains("%"), "\(language.tag): \(phrase)")
      }
    }
    XCTAssertEqual(panel("en").string("Downloading \(42)%"), "Downloading 42%")
    XCTAssertEqual(panel("en").string("100% (native)"), "100% (native)")
  }

  func testMissingPhraseFallsBackToEnglishWithItsArguments() {
    for language in AppLanguage.supported {
      XCTAssertEqual(
        panel(language.tag).string("A sentence no catalog has \(5) times for \("each of us")"),
        "A sentence no catalog has 5 times for each of us", language.tag)
    }
  }

  func testRuntimeCatalogLookupIsNeverFormatted() {
    let japanese = panel("ja")
    XCTAssertNotEqual(japanese.catalogString("Play / Pause"), "Play / Pause")
    XCTAssertEqual(
      japanese.catalogString("Author text 100% %@ %lld"), "Author text 100% %@ %lld",
      "An unknown phrase comes back as it was, format characters included")
    XCTAssertEqual(panel("en").catalogString("No action"), "No action")
  }

  func testLocaleKeepsTheLanguageAndTheSystemRegion() {
    let japanese = PanelLocale(language: AppLanguage.named("ja")!, region: "CN").locale
    XCTAssertEqual(japanese.language.languageCode?.identifier, "ja")
    XCTAssertEqual(japanese.region?.identifier, "CN")
    let korean = PanelLocale(language: AppLanguage.named("ko")!, region: "US").locale
    XCTAssertEqual(korean.language.languageCode?.identifier, "ko")
    XCTAssertEqual(korean.region?.identifier, "US")
    let traditional = PanelLocale(language: AppLanguage.named("zh-Hant")!, region: "US").locale
    XCTAssertEqual(traditional.language.script?.identifier, "Hant")
    XCTAssertEqual(traditional.region?.identifier, "US")
    let bare = PanelLocale(language: AppLanguage.named("zh-Hans")!, region: nil).locale
    XCTAssertEqual(bare.language.script?.identifier, "Hans")
    XCTAssertNil(bare.region)
  }

  func testBoundStoreDrivesTheLanguageIncludingTheSystemChoice() throws {
    let source = try store(system: ["ko-KR"])
    let locale = PanelLocale(region: nil)
    locale.bind(to: source)
    XCTAssertEqual(locale.tag, "ko", "System follows the macOS language list")

    try source.set("zh-Hant")
    XCTAssertEqual(locale.tag, "zh-Hant")
    XCTAssertEqual(locale.bundle.bundleURL.lastPathComponent, "zh-Hant.lproj")
    XCTAssertEqual(locale.locale.language.script?.identifier, "Hant")

    try source.set("en")
    XCTAssertEqual(locale.string("Follow desktop Space"), "Follow desktop Space")
    try source.set(AppLanguageStore.systemChoice)
    XCTAssertEqual(locale.tag, "ko")

    let other = try store("zh-Hans")
    locale.bind(to: other)
    XCTAssertEqual(locale.tag, "zh-Hans", "Binding again replaces the earlier store")
    try source.set("en")
    XCTAssertEqual(locale.tag, "zh-Hans", "The earlier store no longer drives the panel")
  }

  func testGlobalHelperFollowsTheLanguageAndReadersAreToldWhenItChanges() throws {
    addTeardownBlock { @MainActor in PanelLocale.shared.bind(to: .testHost) }
    let source = try store("en")
    PanelLocale.shared.bind(to: source)
    XCTAssertEqual(L("Follow desktop Space"), "Follow desktop Space")
    let english = L("\(5) wallpapers")

    let fired = Counter()
    withObservationTracking {
      _ = L("Follow desktop Space")
    } onChange: {
      fired.increment()
    }
    XCTAssertEqual(fired.value, 0)
    try source.set("ja")
    XCTAssertEqual(fired.value, 1, "A body that called L() must be invalidated by a language change")
    XCTAssertNotEqual(L("Follow desktop Space"), "Follow desktop Space")
    XCTAssertNotEqual(L("\(5) wallpapers"), english)

    try source.set("en")
    XCTAssertEqual(L("\(5) wallpapers"), english)
  }
}
