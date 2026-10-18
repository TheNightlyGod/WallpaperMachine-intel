import Observation
import XCTest

@testable import WallpaperMachine

/// A low-battery, Low Power Mode or heat rule that pauses or stops wallpapers says so wherever the
/// choice it overrides is shown: under Quick Settings' On battery module while the Mac runs on
/// battery, and on the rule's own Playback & Power row. The engaged rules are what the app's
/// condition monitor published, never worked out again here.
@MainActor
final class ConditionOverrideTests: PanelTestCase {
  private struct Case {
    var batteryMode: BridgeBatteryMode = .keepRunning
    var onBattery = true
    var engaged: [(SystemCondition, EngagedSystemCondition.Effect)] = []
    var throttle: [BridgeQualityThrottleCause] = []
    var batteryPercent: Int? = 18
  }

  private func playback(_ value: Case) -> PlaybackSettings {
    PlaybackSettings(
      wallpapersMuted: false, desktopCoveredAction: .pause, playsOnlyOnActiveDisplay: false,
      otherAudioAction: .keepRunning, displaySleepAction: .pause, batteryMode: value.batteryMode,
      onBatteryPower: value.onBattery, batteryRenderScale: 0.75, batteryTargetFps: 30,
      lowBatteryAction: .pause, lowBatteryThreshold: 20, lowPowerModeAction: .pause,
      thermalAction: .pause, batteryPercent: value.batteryPercent, lowPowerModeIsOn: true,
      thermalLevel: .serious,
      conditions: EngagedSystemConditions(
        value.engaged.map { EngagedSystemCondition(condition: $0.0, effect: $0.1) }),
      focusAction: FocusFilterEffect.keepRunning.rawValue, appRules: [], enabledDisplayCount: 1)
  }

  private func onBatteryText(_ value: Case) -> String? {
    let settings = BridgeSnapshotFixtures.settings(
      batteryMode: value.batteryMode, onBatteryPower: value.onBattery, qualityThrottle: value.throttle)
    let quality = QualityReport.make(
      settings: settings, lowPowerModeAction: .keepRunning, thermalAction: .keepRunning,
      lowBatteryAction: .reduceQuality, batteryPercent: value.batteryPercent)
    return playback(value).onBatteryText(quality: quality)
  }

  /// Keep running on battery with a rule that pauses or stops reads as that rule, the very case the
  /// module used to leave unexplained; plugged in, the choice does nothing, so nothing is said.
  func testOnBatteryNamesTheRuleThatPausesOrStopsWallpapers() throws {
    try pinPanelLanguageToEnglish()
    let cases: [(String, Case, String?)] = [
      ("nothing", Case(), nil),
      ("lowBattery", Case(engaged: [(.lowBattery, .pause)]), "The battery is low. Wallpapers are paused."),
      ("lowBatteryStop", Case(engaged: [(.lowBattery, .stop)]), "The battery is low. Wallpapers are stopped."),
      ("lowPower", Case(engaged: [(.lowPowerMode, .pause)]), "Low Power Mode is on. Wallpapers are paused."),
      ("lowPowerStop", Case(engaged: [(.lowPowerMode, .stop)]), "Low Power Mode is on. Wallpapers are stopped."),
      ("heat", Case(engaged: [(.heat, .pause)]), "The Mac is hot. Wallpapers are paused."),
      ("heatStop", Case(engaged: [(.heat, .stop)]), "The Mac is hot. Wallpapers are stopped."),
      ("pluggedIn", Case(onBattery: false, engaged: [(.lowPowerMode, .stop)]), nil),
    ]
    for (name, value, expected) in cases {
      XCTAssertEqual(onBatteryText(value), expected, name)
    }
  }

  /// A stop outweighs a pause and a pause outweighs reduced quality, whichever rule asks; among
  /// equals the one named first wins.
  func testTheStrongestRuleIsNamed() throws {
    try pinPanelLanguageToEnglish()
    XCTAssertEqual(
      onBatteryText(Case(engaged: [(.heat, .pause), (.lowBattery, .stop)])),
      "The battery is low. Wallpapers are stopped.")
    XCTAssertEqual(
      onBatteryText(Case(engaged: [(.lowBattery, .pause), (.lowPowerMode, .pause)])),
      "Low Power Mode is on. Wallpapers are paused.")
    XCTAssertEqual(
      onBatteryText(
        Case(engaged: [(.lowBattery, .reducedQuality), (.heat, .pause)], throttle: [.lowBattery])),
      "The Mac is hot. Wallpapers are paused.",
      "A pause outweighs the reduced quality the low battery holds")
  }

  /// What the On battery choice already does is no override: Pause beside a rule that pauses says
  /// nothing, a rule that stops does. Reduced quality alone still reads as the quality cause.
  func testOnlyWhatGoesBeyondTheChoiceIsAnOverride() throws {
    try pinPanelLanguageToEnglish()
    XCTAssertNil(onBatteryText(Case(batteryMode: .pause, engaged: [(.lowBattery, .pause)])))
    XCTAssertEqual(
      onBatteryText(Case(batteryMode: .pause, engaged: [(.lowBattery, .stop)])),
      "The battery is low. Wallpapers are stopped.")
    XCTAssertEqual(
      onBatteryText(Case(batteryMode: .reducedQuality, engaged: [(.lowPowerMode, .pause)])),
      "Low Power Mode is on. Wallpapers are paused.")
    XCTAssertEqual(
      onBatteryText(Case(engaged: [(.lowBattery, .reducedQuality)], throttle: [.lowBattery])),
      "The battery is low. Reduced quality is in use.",
      "Reduced quality is still named from what the engine reports")
  }

  /// Each rule's own row says it is in effect while it is engaged, which the charge alone cannot
  /// tell for the low battery (the rule ends only 5 points above its level).
  func testEachRuleRowSaysWhenItIsInEffect() throws {
    try pinPanelLanguageToEnglish()
    let idle = playback(Case())
    XCTAssertEqual(idle.lowPowerModeNote, "Low Power Mode is on now.")
    XCTAssertFalse(try XCTUnwrap(idle.lowBatteryNote).contains("In effect now"))
    XCTAssertFalse(idle.thermalNote.contains("In effect now"))

    let engaged = playback(
      Case(engaged: [(.lowBattery, .stop), (.lowPowerMode, .reducedQuality), (.heat, .pause)]))
    XCTAssertEqual(
      engaged.lowPowerModeNote, "Low Power Mode is on now.\nIn effect now. Reduced quality is in use.")
    XCTAssertEqual(
      try XCTUnwrap(engaged.lowBatteryNote).components(separatedBy: "\n").last,
      "In effect now. Wallpapers are stopped.")
    XCTAssertEqual(
      engaged.thermalNote.components(separatedBy: "\n").last, "In effect now. Wallpapers are paused.")
    XCTAssertNil(
      playback(Case(engaged: [(.lowBattery, .pause)], batteryPercent: nil)).lowBatteryNote,
      "A Mac without a battery has no low-battery row")
  }

  /// The controller reads the store the app's monitor publishes to, and a change there asks the
  /// Playback & Power and Quick Settings readers again.
  func testThePublishedConditionsReachThePanelAndWakeItsReaders() async throws {
    try await withRecordingPanel { panel, _ in
      let controller = panel.controller
      XCTAssertTrue(controller.playbackSettings.conditions.isEmpty)
      let seen = SettingsObservedFlag()
      withObservationTracking {
        _ = controller.playbackSettings
      } onChange: {
        seen.set()
      }
      let engaged = EngagedSystemConditions([EngagedSystemCondition(condition: .lowBattery, effect: .pause)])
      panel.systemConditions.set(engaged)
      try await panel.waitUntil { seen.value }
      XCTAssertEqual(controller.playbackSettings.conditions, engaged)
    }
  }
}
