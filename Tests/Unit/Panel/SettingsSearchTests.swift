import AppKit
import XCTest

@testable import WallpaperMachine

/// What typing in the Settings search field keeps: the rules of the web panel's search, including
/// the fold of an open disclosure that nothing matches.
@MainActor
final class SettingsSearchTests: XCTestCase {
  private static let playback = SettingsItem.Group("playback", title: "Playback")
  private static let startup = SettingsItem.Group("startup", title: "Startup")

  private static let battery = SettingsItem(
    id: "playback.battery", section: .playback, group: playback, title: "On battery",
    note: "Reduced quality uses the scale and frame rate below.")
  private static let mute = SettingsItem(
    id: "playback.mute", section: .playback, group: playback, title: "Mute all wallpapers")
  private static let help = SettingsItem(
    id: "playback.help", section: .playback, group: playback, title: "Help",
    note: "Renderers and experimental options")
  private static let guide = SettingsItem(
    id: "playback.guide", section: .playback, inside: help, title: "Welcome guide")
  private static let screenSaver = SettingsItem(
    id: "general.saver", section: .general, group: startup, title: "Screen saver",
    keywords: ["Lock screen"])
  private static let appearance = SettingsItem(
    id: "appearance.mode", section: .appearance, title: "Appearance")
  private static let items = [battery, mute, help, guide, screenSaver, appearance]

  private func index(_ language: String) -> SettingsIndex {
    let locale = PanelLocale(language: AppLanguage.named(language) ?? .english, region: nil)
    return SettingsIndex(items: Self.items) { locale.string(resolving: $0) }
  }

  private func search(_ query: String, language: String = "en") -> SettingsSearch {
    SettingsSearch(query: query, index: index(language))
  }

  func testWithoutAQueryEverythingShowsAndNothingOpensOrCounts() {
    for query in ["", "   \n"] {
      let search = search(query)
      XCTAssertFalse(search.isActive)
      for item in Self.items { XCTAssertTrue(search.shows(item)) }
      XCTAssertTrue(search.shows(Self.playback, in: .playback))
      XCTAssertFalse(search.opens(Self.help))
      XCTAssertEqual(search.count(in: .playback), 0)
      XCTAssertFalse(search.hasNoResults)
    }
  }

  func testAMatchKeepsOnlyItsRowAndItsGroupAndCountsPerSection() {
    let search = search("  battery ")
    XCTAssertEqual(search.query, "battery")
    XCTAssertTrue(search.shows(Self.battery))
    XCTAssertFalse(search.shows(Self.mute))
    XCTAssertTrue(search.shows(Self.playback, in: .playback), "The group holding a match stays")
    XCTAssertFalse(search.shows(Self.startup, in: .general), "A group without a match leaves")
    XCTAssertEqual(search.count(in: .playback), 1)
    XCTAssertEqual(
      search.sections, [.playback], "Sections without a match leave the results, in order")
  }

  func testTheQueryReadsTheNoteAndTheKeywordsAndIgnoresCaseAccentsAndWidth() {
    XCTAssertTrue(search("FRAME RATE").shows(Self.battery), "A note is searched, in any case")
    XCTAssertTrue(search("lock SCREEN").shows(Self.screenSaver), "A keyword is searched")
    XCTAssertTrue(search("ＡＰＰＥＡＲＡＮＣＥ").shows(Self.appearance), "Full-width letters match")
    XCTAssertTrue(search("on bat").shows(Self.battery))
    XCTAssertFalse(
      search("battery frame").shows(Self.battery), "The query is one piece of text, not words")
    XCTAssertFalse(search("Quick Settings").shows(Self.mute), "Section names are not searched")
  }

  func testAMatchingGroupTitleKeepsEveryItemInTheGroup() {
    let search = search("playback")
    for item in [Self.battery, Self.mute, Self.help, Self.guide] {
      XCTAssertTrue(search.shows(item), "\(item.id) is in the group that matched")
    }
    XCTAssertEqual(search.count(in: .playback), 4)
    XCTAssertFalse(search.shows(Self.appearance))
  }

  func testAnOpenDisclosureNothingMatchesFoldsAwayWithItsTitle() {
    // The fix of 50129725: with the group around it matching, a disclosure the person opened used
    // to stay on show without its title.
    let search = search("On battery")
    XCTAssertTrue(search.shows(Self.playback, in: .playback))
    XCTAssertFalse(search.shows(Self.help), "The disclosure folds away")
    XCTAssertFalse(search.shows(Self.guide), "and so does what is inside it")
    XCTAssertFalse(search.opens(Self.help))
  }

  func testAMatchInsideADisclosureShowsAndOpensItAndTheDisclosureIsNotACountedMatch() {
    let search = search("welcome")
    XCTAssertTrue(search.shows(Self.guide))
    XCTAssertTrue(search.shows(Self.help), "The disclosure holding the match shows, with its title")
    XCTAssertTrue(search.opens(Self.help), "and opens by itself for as long as the search lasts")
    XCTAssertEqual(search.count(in: .playback), 1, "Only the matching setting counts")
    XCTAssertFalse(self.search("").opens(Self.help), "It closes again when the search clears")
  }

  func testAQueryWithNoMatchHasNoResultsAndALiveRowCanAskTheSameQuestion() {
    let search = search("zzz")
    XCTAssertTrue(search.hasNoResults)
    XCTAssertTrue(search.sections.isEmpty)
    let battery = self.search("battery")
    XCTAssertTrue(
      battery.matches("Battery saver playlist"), "A row built from live data asks the query")
    XCTAssertFalse(battery.matches("Weekend playlist"))
    XCTAssertTrue(self.search("").matches("anything"))
  }

  func testTheQueryMatchesWhatTheRowsSayInThePanelLanguage() {
    XCTAssertTrue(search("外観", language: "ja").shows(Self.appearance))
    XCTAssertFalse(search("外観", language: "en").shows(Self.appearance))
    XCTAssertFalse(search("appearance", language: "ja").shows(Self.appearance))
    XCTAssertTrue(search("外观", language: "zh-Hans").shows(Self.appearance))
    XCTAssertTrue(search("배터리", language: "ko").shows(Self.battery))
    XCTAssertFalse(search("배터리", language: "en").shows(Self.battery))
    XCTAssertTrue(
      search("バッテリー", language: "ja").shows(Self.battery), "A title is read in the panel language")
    // A group's title is read in the language too: 再生 is Playback.
    XCTAssertTrue(search("再生", language: "ja").shows(Self.mute))
  }

  func testEverySectionHasANameAndADescriptionInEveryShippedLanguageAndARealSymbol() {
    let english = PanelLocale(language: .english, region: nil)
    for language in AppLanguage.supported where language.tag != "en" {
      let locale = PanelLocale(language: language, region: nil)
      for section in SettingsSection.allCases {
        XCTAssertNotEqual(
          locale.string(resolving: section.title), english.string(resolving: section.title),
          "\(language.tag) has no name for \(section)")
        XCTAssertNotEqual(
          locale.string(resolving: section.summary), english.string(resolving: section.summary),
          "\(language.tag) has no description for \(section)")
      }
    }
    for section in SettingsSection.allCases {
      XCTAssertNotNil(
        NSImage(systemSymbolName: section.systemImage, accessibilityDescription: nil),
        "\(section) names a symbol this macOS does not have")
    }
  }

  func testTheRegistryOfEverySectionIsSoundAndTheCheckCatchesTheMistakesItIsFor() {
    XCTAssertEqual(SettingsRegistry.problems(in: SettingsRegistry.items), [])
    let duplicate = SettingsItem(id: Self.mute.id, section: .general, title: "Language")
    let orphan = SettingsItem(
      id: "x.orphan", section: .playback,
      inside: SettingsItem(id: "x.ghost", section: .playback, title: "Help"), title: "Language")
    let crossed = SettingsItem(
      id: "x.crossed", section: .general, inside: Self.help, title: "Language")
    let retitled = SettingsItem(
      id: "x.retitled", section: .playback, group: SettingsItem.Group("playback", title: "Startup"),
      title: "Language")
    let problems = SettingsRegistry.problems(
      in: Self.items + [duplicate, orphan, crossed, retitled])
    XCTAssertEqual(problems.count, 4, "\(problems)")
  }
}

/// Where a long explanation is cut: the lead stays under the row's title, the rest waits behind ⓘ.
final class SettingsNoteTests: XCTestCase {
  func testAShortNoteStaysWhole() {
    let parts = SettingsNote.parts("  Mute silences scene and video wallpapers.  ")
    XCTAssertEqual(parts.lead, "Mute silences scene and video wallpapers.")
    XCTAssertNil(parts.more)
  }

  func testALongNoteIsCutAfterItsFirstSentence() {
    let first =
      "Mission Control and the moment before a wallpaper loads show a still frame of the wallpaper."
    let rest =
      "Turn this off to leave macOS's own wallpaper settings alone; your own picture comes back at once."
    let parts = SettingsNote.parts("\(first) \(rest)")
    XCTAssertEqual(parts.lead, first)
    XCTAssertEqual(parts.more, rest)
  }

  func testASentenceTooShortToStandAloneTakesTheNextOne() {
    let second =
      "In scenes drawn by Native Metal, a layer's shader can read video frames directly instead of converting them."
    let rest =
      "Only works with 8-bit NV12 video and shaders that support it; everything else converts as before, and the diagnostics show which path each scene uses."
    let parts = SettingsNote.parts("Experimental. \(second) \(rest)")
    XCTAssertEqual(parts.lead, "Experimental. \(second)")
    XCTAssertEqual(parts.more, rest)
  }

  func testACjkNoteWeighsDoubleAndIsCutAtAFullWidthStop() {
    XCTAssertEqual(SettingsNote.weight("abc"), 3)
    XCTAssertEqual(SettingsNote.weight("壁纸a"), 5)
    let first = String(repeating: "壁", count: 30) + "。"
    let second = String(repeating: "纸", count: 40) + "。"
    let parts = SettingsNote.parts(first + second)
    XCTAssertEqual(parts.lead, first)
    XCTAssertEqual(parts.more, second)
    // Fifty-nine such characters weigh 118 with the stop: still whole.
    XCTAssertNil(SettingsNote.parts(String(repeating: "壁", count: 59) + "。").more)
  }

  func testANoteWithNoSentenceEndOrNothingAfterItStaysWhole() {
    let run = String(repeating: "word ", count: 40)
    XCTAssertNil(SettingsNote.parts(run).more)
    let single = String(repeating: "word ", count: 40) + "end."
    XCTAssertNil(SettingsNote.parts(single).more)
  }
}
