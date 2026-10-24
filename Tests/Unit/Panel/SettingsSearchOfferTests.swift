import XCTest

@testable import WallpaperMachine

/// A Settings search finds only what the pages draw on this Mac now. A row a page leaves out (the
/// low-battery choices without a battery, Active Display Only with one display, a live report with
/// nothing to say) was not in the web page's DOM, so it was never a result: it neither counts in the
/// sidebar, nor opens a disclosure, nor leaves its group's title on show, and a query only it would
/// match says that nothing matches.
@MainActor
final class SettingsSearchOfferTests: PanelTestCase {
  private static let playback = SettingsItem.Group("playback", title: "Playback")

  private static let battery = SettingsItem(
    id: "playback.battery", section: .playback, group: playback, title: "On battery")
  private static let level = SettingsItem(
    id: "playback.level", section: .playback, group: playback, title: "Low battery level")
  private static let advanced = SettingsItem(
    id: "playback.advanced", section: .playback, group: playback, title: "Advanced")
  private static let inside = SettingsItem(
    id: "playback.inside", section: .playback, inside: advanced, title: "Shared decode in use")
  private static let items = [battery, level, advanced, inside]

  private func index() -> SettingsIndex {
    let locale = PanelLocale(language: .english, region: nil)
    return SettingsIndex(items: Self.items) { locale.string(resolving: $0) }
  }

  // MARK: The rule

  func testARowThePageLeavesOutIsNoResultAndLeavesNoBareGroupTitle() {
    XCTAssertTrue(
      SettingsSearch(query: "Low battery level", index: index()).shows(Self.level),
      "Drawn, the row is found")

    let search = SettingsSearch(
      query: "Low battery level", index: index().offering { $0.id != Self.level.id })
    XCTAssertTrue(search.hasNoResults, "The page says that nothing matches")
    XCTAssertEqual(search.count(in: .playback), 0, "The sidebar counts nothing")
    XCTAssertFalse(search.shows(Self.playback, in: .playback), "No group title is left without rows")
    XCTAssertEqual(search.sections, [])
  }

  func testAMatchingGroupTitleKeepsOnlyTheRowsThePageDraws() {
    let search = SettingsSearch(
      query: "Playback", index: index().offering { $0.id != Self.level.id })
    XCTAssertTrue(search.shows(Self.battery))
    XCTAssertFalse(search.shows(Self.level))
    XCTAssertEqual(search.count(in: .playback), 3, "On battery, Advanced and what is inside it")
  }

  func testNothingInsideADisclosureThePageLeavesOutIsFoundOrOpensIt() {
    let search = SettingsSearch(
      query: "decode in use", index: index().offering { $0.id != Self.advanced.id })
    XCTAssertTrue(search.hasNoResults)
    XCTAssertFalse(search.opens(Self.advanced))

    let drawn = SettingsSearch(
      query: "decode in use", index: index().offering { $0.id != Self.level.id })
    XCTAssertTrue(drawn.opens(Self.advanced), "A row that is drawn still opens its disclosure")
    XCTAssertEqual(drawn.count(in: .playback), 1)
  }

  // MARK: The pages' own rows

  /// The low-battery rows exist only on a Mac with a battery, and the level only while a low battery
  /// does something.
  func testTheLowBatteryRowsAreFoundOnlyWhereThePlaybackPageDrawsThem() async throws {
    try pinPanelLanguageToEnglish()
    try await withRecordingPanel { panel, _ in
      panel.store.snapshotRevision = 1
      let controller = panel.controller
      let settings = controller.settings
      controller.batteryPercent = nil
      settings.query = "Low battery level"
      XCTAssertTrue(settings.search.hasNoResults, "A Mac without a battery draws no low-battery row")
      settings.query = "When the battery is low"
      XCTAssertTrue(settings.search.hasNoResults)

      controller.batteryPercent = 54
      XCTAssertEqual(settings.search.count(in: .playback), 1, "With a battery the row is drawn and found")
      settings.query = "Low battery level"
      XCTAssertTrue(settings.search.hasNoResults, "The level waits for a low battery to do something")
      controller.playback.lowBatteryAction = .pause
      XCTAssertTrue(settings.search.shows(PlaybackSettingsSection.lowBatteryLevel))
      XCTAssertEqual(settings.search.count(in: .playback), 1)
    }
  }

  /// Active Display Only needs a second display, and the live reports need something to report:
  /// a scale in force that differs from the saved one.
  func testOneDisplayAndQuietReportsLeaveTheirRowsOutOfTheResults() async throws {
    try pinPanelLanguageToEnglish()
    try await withRecordingPanel { panel, _ in
      panel.store.snapshotRevision = 1
      let controller = panel.controller
      let settings = controller.settings
      let quiet = BridgeSnapshotFixtures.settings(displays: panel.store.settingsSnapshot.displays)
      panel.store.settingsSnapshot = quiet
      for query in ["Active Display", "Effective now"] {
        settings.query = query
        XCTAssertTrue(settings.search.hasNoResults, "\(query) is not drawn on this Mac now")
      }

      panel.store.settingsSnapshot = BridgeSnapshotFixtures.settings(
        displays: quiet.displays + [ShellFixtures.display("secondary", "Built-in Retina Display")],
        renderScale: 0.75, preferredRenderScale: 1)
      settings.query = "Active Display"
      XCTAssertEqual(settings.search.count(in: .quick), 1, "The tile of a Mac with two displays")
      settings.query = "Effective now"
      XCTAssertEqual(settings.search.count(in: .performance), 1)
      settings.query = "Direct video plane sampling"
      XCTAssertEqual(settings.search.count(in: .performance), 1)
      XCTAssertTrue(settings.search.opens(PerformanceSettingsSection.advanced))
    }
  }
}
