import XCTest

@testable import WallpaperMachine

/// Settings › Playback & Power › When the Mac is inactive: off until chosen, its time asked for only
/// once the rule does something, only an offered time accepted, its row saying while the rule is
/// in effect, and Quick Settings' On battery module naming it when it pauses or stops wallpapers
/// on battery, as it names the other conditions of the Mac.
@MainActor
final class InactivitySettingsTests: PanelTestCase {
  private func playback(
    _ engaged: [(SystemCondition, EngagedSystemCondition.Effect)], onBattery: Bool = true
  ) -> PlaybackSettings {
    PlaybackSettings(
      wallpapersMuted: false, desktopCoveredAction: .pause, playsOnlyOnActiveDisplay: false,
      otherAudioAction: .keepRunning, otherAppInFrontAction: .keepRunning, displaySleepAction: .pause,
      batteryMode: .keepRunning, onBatteryPower: onBattery, batteryRenderScale: 0.75,
      batteryTargetFps: 30, lowBatteryAction: .keepRunning, lowBatteryThreshold: 20,
      lowPowerModeAction: .keepRunning, thermalAction: .pause, inactivityAction: .pause,
      inactivityMinutes: 10, batteryPercent: 54, lowPowerModeIsOn: false, thermalLevel: .serious,
      conditions: EngagedSystemConditions(
        engaged.map { EngagedSystemCondition(condition: $0.0, effect: $0.1) }),
      focusAction: FocusFilterEffect.keepRunning.rawValue, appRules: [], enabledDisplayCount: 1)
  }

  private func onBatteryText(
    _ engaged: [(SystemCondition, EngagedSystemCondition.Effect)], onBattery: Bool = true
  ) -> String? {
    let settings = BridgeSnapshotFixtures.settings(batteryMode: .keepRunning, onBatteryPower: onBattery)
    let quality = QualityReport.make(
      settings: settings, lowPowerModeAction: .keepRunning, thermalAction: .pause,
      lowBatteryAction: .keepRunning, batteryPercent: 54)
    return playback(engaged, onBattery: onBattery).onBatteryText(quality: quality)
  }

  func testTheRowSaysWhileTheRuleIsInEffect() throws {
    try pinPanelLanguageToEnglish()
    XCTAssertFalse(playback([]).inactivityNote.contains("In effect now"))
    XCTAssertFalse(
      playback([(.heat, .pause)]).inactivityNote.contains("In effect now"),
      "Another condition's pause is not this rule's")
    XCTAssertEqual(
      playback([(.inactivity, .pause)]).inactivityNote.components(separatedBy: "\n").last,
      "In effect now. Wallpapers are paused.")
    XCTAssertEqual(
      playback([(.inactivity, .stop)]).inactivityNote.components(separatedBy: "\n").last,
      "In effect now. Wallpapers are stopped.")
  }

  /// Keep running on battery while an inactive Mac pauses or stops wallpapers reads as that rule,
  /// the strongest effect first and, among equals, after the Mac's power conditions.
  func testOnBatteryNamesAnInactiveMac() throws {
    try pinPanelLanguageToEnglish()
    XCTAssertEqual(
      onBatteryText([(.inactivity, .pause)]), "The Mac is inactive. Wallpapers are paused.")
    XCTAssertEqual(
      onBatteryText([(.inactivity, .stop)]), "The Mac is inactive. Wallpapers are stopped.")
    XCTAssertNil(onBatteryText([(.inactivity, .stop)], onBattery: false), "Plugged in nothing is overridden")
    XCTAssertEqual(
      onBatteryText([(.heat, .pause), (.inactivity, .pause)]), "The Mac is hot. Wallpapers are paused.")
    XCTAssertEqual(
      onBatteryText([(.heat, .pause), (.inactivity, .stop)]),
      "The Mac is inactive. Wallpapers are stopped.", "A stop outweighs a pause")
  }

  func testTheTimeIsAskedForOnlyOnceTheRuleDoesSomething() async throws {
    try pinPanelLanguageToEnglish()
    try await withRecordingPanel { panel, _ in
      panel.store.snapshotRevision = 1
      let controller = panel.controller
      let settings = controller.settings
      settings.query = "When the Mac is inactive"
      XCTAssertTrue(settings.search.shows(PlaybackSettingsSection.inactivity))
      settings.query = "Inactive after"
      XCTAssertTrue(settings.search.hasNoResults, "Keep running is the default and needs no time")
      XCTAssertFalse(controller.playbackSettings.showsInactivityTime)

      try await controller.setInactivityAction(.pause)
      XCTAssertTrue(settings.search.shows(PlaybackSettingsSection.inactivityTime))
      XCTAssertTrue(controller.playbackSettings.showsInactivityTime)
    }
  }

  func testTheChoicesReachThePreferencesAndATimeTheMenuDoesNotOfferIsRefused() async throws {
    try await withRecordingPanel { panel, _ in
      let controller = panel.controller
      XCTAssertEqual(controller.playbackSettings.inactivityAction, .keepRunning)
      XCTAssertEqual(controller.playbackSettings.inactivityMinutes, 10)

      try await controller.setInactivityAction(.stop)
      try await controller.setInactivityMinutes(30)
      XCTAssertEqual(controller.playback.inactivityAction, .stop)
      XCTAssertEqual(controller.playbackSettings.inactivityMinutes, 30)

      do {
        try await controller.setInactivityMinutes(7)
        XCTFail("7 minutes is not offered")
      } catch is InvalidControlValue {}
      XCTAssertEqual(controller.playback.inactivityMinutes, 30)
    }
  }
}
