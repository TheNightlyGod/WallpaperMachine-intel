import Observation
import XCTest

@testable import WallpaperMachine

/// The typed Performance and Playback setters: what they clamp, what they refuse and what reaches
/// the engine. Replaces the old `setting` action tests (`WebPanelPerformanceSettingsTests`,
/// `WebPanelSceneSettingsTests`); a typed parameter cannot be the wrong kind, so those cases are
/// the compile-time guarantee and what remains here is the behavior.
@MainActor
final class PanelPerformanceSettingsTests: PanelTestCase {
  /// A control only offers values inside 0.25...1, so an outlier means a stale control: clamped, not
  /// refused or passed through. A scale that is not a number is refused.
  func testRenderScaleFromAStaleControlIsClampedToTheSupportedRange() async throws {
    try await withRecordingPanel { panel, bridge in
      let controller = panel.controller
      try await controller.setRenderScale(5)
      try await controller.setRenderScale(0.01)
      XCTAssertEqual(bridge.renderScaleCalls, [1, 0.25])

      do {
        try await controller.setRenderScale(.nan)
        XCTFail("A render scale that is not a number must not reach the engine")
      } catch is InvalidControlValue {}
      XCTAssertEqual(bridge.renderScaleCalls, [1, 0.25])
    }
  }

  func testFrameRateCapClampsANumberAndNilIsNoLimit() async throws {
    try await withRecordingPanel { panel, bridge in
      try await panel.controller.setFrameRateCap(0)
      try await panel.controller.setFrameRateCap(300)
      try await panel.controller.setFrameRateCap(45)
      try await panel.controller.setFrameRateCap(nil)
      XCTAssertEqual(bridge.frameRateCapCalls, [1, 240, 45, nil])
    }
  }

  func testQualityPresetAppliesRenderScaleAndFrameRateCapTogether() async throws {
    try await withRecordingPanel { panel, bridge in
      try await panel.controller.applyQualityPreset(.low)
      XCTAssertEqual(bridge.renderScaleCalls, [0.5])
      XCTAssertEqual(bridge.frameRateCapCalls, [30])

      try await panel.controller.applyQualityPreset(.medium)
      XCTAssertEqual(bridge.renderScaleCalls, [0.5, 0.75])
      XCTAssertEqual(bridge.frameRateCapCalls, [30, 60])

      try await panel.controller.applyQualityPreset(.high)
      XCTAssertEqual(bridge.renderScaleCalls, [0.5, 0.75, 1])
      XCTAssertEqual(bridge.frameRateCapCalls.count, 3)
      XCTAssertNil(bridge.frameRateCapCalls[2], "High is the default: no frame-rate limit")
    }
  }

  /// Changing one field of the battery profile must not reset the other: the engine owns the pair as
  /// one value, so the change is merged with what it reports when the change runs.
  func testBatteryProfileChangesOneFieldAndKeepsTheOther() async throws {
    try await withRecordingPanel { panel, bridge in
      panel.store.settingsSnapshot.batteryRenderScale = 0.5
      panel.store.settingsSnapshot.batteryTargetFps = 30

      try await panel.controller.setBatteryTargetFps(1000)
      XCTAssertEqual(
        bridge.batteryProfileCalls.last, .init(renderScale: 0.5, targetFps: 240),
        "The frame rate is clamped to 1...240 and the unchanged scale is passed through")

      try await panel.controller.setBatteryTargetFps(-3)
      XCTAssertEqual(bridge.batteryProfileCalls.last?.targetFps, 1)

      try await panel.controller.setBatteryRenderScale(2)
      XCTAssertEqual(
        bridge.batteryProfileCalls.last, .init(renderScale: 1, targetFps: 1),
        "The scale is clamped to 0.25...1 and the frame rate the engine now reports is kept")

      do {
        try await panel.controller.setBatteryRenderScale(.infinity)
        XCTFail("A scale that is not a number must not reach the engine")
      } catch is InvalidControlValue {}
      XCTAssertEqual(bridge.batteryProfileCalls.count, 3)
    }
  }

  func testBatteryModeReachesTheEngineUnderItsOwnName() async throws {
    try await withRecordingPanel { panel, bridge in
      try await panel.controller.setBatteryMode(.pause)
      try await panel.controller.setBatteryMode(.reducedQuality)
      XCTAssertEqual(bridge.batteryModeCalls, [.pause, .reducedQuality])
    }
    // The battery mode's Reduced quality is not the conditions' one: the stored names differ by a letter
    // on purpose, and the conditions (not the sleep choice) offer theirs.
    XCTAssertEqual(
      SystemConditionAction.allCases.map(\.rawValue), ["keepRunning", "reduceQuality", "pause", "stop"])
    XCTAssertEqual(DisplaySleepAction.allCases.map(\.rawValue), ["pause", "stop"])
  }

  /// The choice is by the names the engine accepts, ships on the display and comes back as the engine
  /// answered it. A name the typed choice cannot make is not offered, so the engine never has to refuse
  /// one the panel sent.
  func testSceneResolutionShipsOnTheDisplayAndRoundTripsThroughTheEngine() async throws {
    for rejected in ["native", "Display", "canvas size", ""] {
      XCTAssertNil(SceneResolutionMode(rawValue: rejected), rejected)
    }
    XCTAssertEqual(SceneResolutionMode.allCases.map(\.rawValue), ["display", "canvas"])

    try await withRecordingPanel { panel, bridge in
      panel.store.settingsSnapshot = BridgeSnapshotFixtures.settings()
      XCTAssertEqual(
        panel.controller.performanceSettings.sceneResolution, .display,
        "It ships on the display; a view that rendered the canvas would invert the default")

      try await panel.controller.setSceneResolution(.canvas)
      XCTAssertEqual(bridge.sceneResolutionCalls, ["canvas"])
      XCTAssertEqual(
        panel.controller.performanceSettings.sceneResolution, .canvas,
        "The state is the one the engine returned, not the click")

      try await panel.controller.setSceneResolution(.display)
      XCTAssertEqual(bridge.sceneResolutionCalls, ["canvas", "display"])
      XCTAssertEqual(panel.controller.performanceSettings.sceneResolution, .display)
    }
  }

  /// A name this build does not know, from a newer or hand-edited config, reads as the shipped default
  /// rather than as a choice the user never made.
  func testAnUnknownSceneResolutionNameReadsAsTheDisplay() async throws {
    try await withRecordingPanel { panel, _ in
      panel.store.settingsSnapshot = BridgeSnapshotFixtures.settings(sceneResolution: "supersampled")
      XCTAssertEqual(panel.controller.performanceSettings.sceneResolution, .display)
    }
  }

  func testSceneOptimizationShipsOnAndRoundTripsThroughTheEngine() async throws {
    try await withRecordingPanel { panel, bridge in
      panel.store.settingsSnapshot = BridgeSnapshotFixtures.settings()
      XCTAssertTrue(
        panel.controller.performanceSettings.sceneOptimization,
        "It ships on; a view that rendered it off would invert the default")

      try await panel.controller.setSceneOptimization(false)
      XCTAssertEqual(bridge.sceneOptimizationCalls, [false])
      XCTAssertFalse(
        panel.controller.performanceSettings.sceneOptimization,
        "The state is the one the engine returned, not the click")

      try await panel.controller.setSceneOptimization(true)
      XCTAssertEqual(bridge.sceneOptimizationCalls, [false, true])
      XCTAssertTrue(panel.controller.performanceSettings.sceneOptimization)
    }
  }

  func testSceneOnDemandAndDirectVideoPlaneSamplingShipOffAndRoundTrip() async throws {
    try await withRecordingPanel { panel, bridge in
      panel.store.settingsSnapshot = BridgeSnapshotFixtures.settings()
      let shipped = panel.controller.performanceSettings
      XCTAssertFalse(shipped.sceneOnDemand, "Stopping a scene's tick ships off")
      XCTAssertFalse(
        shipped.sceneVideoPlaneSampling,
        "A sampling path whose equivalence is bounded rather than total ships off")

      try await panel.controller.setSceneOnDemand(true)
      try await panel.controller.setSceneVideoPlaneSampling(true)
      XCTAssertEqual(bridge.sceneOnDemandCalls, [true])
      XCTAssertEqual(bridge.sceneVideoPlaneSamplingCalls, [true])
      let on = panel.controller.performanceSettings
      XCTAssertTrue(on.sceneOnDemand && on.sceneVideoPlaneSampling)
    }
  }

  // MARK: Playback choices

  func testConditionChoicesAreSavedAndSurviveARelaunch() async throws {
    try await withRecordingPanel { panel, _ in
      let controller = panel.controller
      try await controller.setDesktopCoveredAction(.keepRunning)
      try await controller.setLowBatteryAction(.stop)
      try await controller.setLowPowerModeAction(.reduceQuality)
      try await controller.setThermalAction(.reduceQuality)
      try await controller.setOtherAudioAction(.mute)
      try await controller.setDisplaySleepAction(.stop)

      let reopened = PlaybackPreferences(defaults: panel.defaults)
      XCTAssertEqual(reopened.desktopCoveredAction, .keepRunning)
      XCTAssertEqual(reopened.lowBatteryAction, .stop)
      XCTAssertEqual(reopened.lowPowerModeAction, .reduceQuality)
      XCTAssertEqual(reopened.thermalAction, .reduceQuality)
      XCTAssertEqual(reopened.otherAudioAction, .mute)
      XCTAssertEqual(reopened.displaySleepAction, .stop)

      let settings = controller.playbackSettings
      XCTAssertEqual(settings.desktopCoveredAction, .keepRunning)
      XCTAssertEqual(settings.lowBatteryAction, .stop)
      XCTAssertEqual(settings.otherAudioAction, .mute)
      XCTAssertEqual(settings.displaySleepAction, .stop)
    }
  }

  func testLowBatteryLevelAcceptsOnlyTheOfferedLevels() async throws {
    try await withRecordingPanel { panel, _ in
      let playback = panel.controller.playback
      for level in [10, 30, 20] {
        try await panel.controller.setLowBatteryThreshold(level)
        XCTAssertEqual(playback.lowBatteryThreshold, level)
      }
      try await panel.controller.setLowBatteryThreshold(10)
      for bad in [15, 9, 31, 0, -20, 200] {
        do {
          try await panel.controller.setLowBatteryThreshold(bad)
          XCTFail("\(bad) is not an offered low-battery level (15 is in range yet not offered)")
        } catch is InvalidControlValue {}
      }
      XCTAssertEqual(playback.lowBatteryThreshold, 10, "Refused levels leave the saved one alone")
      XCTAssertEqual(PlaybackPreferences.lowBatteryThresholds, [10, 20, 30])
    }
  }

  func testPlayOnlyOnTheActiveDisplayIsStoredAndReported() async throws {
    try await withRecordingPanel { panel, _ in
      XCTAssertFalse(panel.controller.playbackSettings.playsOnlyOnActiveDisplay)
      try await panel.controller.setPlaysOnlyOnActiveDisplay(true)
      XCTAssertTrue(panel.controller.playback.playsOnlyOnActiveDisplay)
      XCTAssertTrue(panel.controller.playbackSettings.playsOnlyOnActiveDisplay)
      try await panel.controller.setPlaysOnlyOnActiveDisplay(false)
      XCTAssertFalse(panel.controller.playbackSettings.playsOnlyOnActiveDisplay)
    }
  }

  /// The muting of every wallpaper is the app's own preference: stored, reported and kept across a
  /// relaunch; wallpapers keep their own sound until the user mutes them all.
  func testMutingEveryWallpaperIsStoredReportedAndSurvivesARelaunch() async throws {
    try await withRecordingPanel { panel, _ in
      XCTAssertFalse(panel.controller.playbackSettings.wallpapersMuted)
      try await panel.controller.setWallpapersMuted(true)
      XCTAssertTrue(panel.controller.playback.wallpapersMuted)
      XCTAssertTrue(panel.controller.playbackSettings.wallpapersMuted)
      XCTAssertTrue(
        PlaybackPreferences(defaults: panel.defaults).wallpapersMuted,
        "The choice must survive a relaunch")

      try await panel.controller.setWallpapersMuted(false)
      XCTAssertFalse(panel.controller.playbackSettings.wallpapersMuted)
    }
  }

  /// The panel follows a change made elsewhere (the menu bar, a link) because the getter reads the
  /// playback revision before the store.
  func testAMuteFromTheMenuBarReachesTheOpenPanel() async throws {
    try await withRecordingPanel { panel, _ in
      let controller = panel.controller
      let seen = SettingsObservedFlag()
      withObservationTracking {
        _ = controller.playbackSettings.wallpapersMuted
      } onChange: {
        seen.set()
      }
      controller.playback.wallpapersMuted = true
      try await panel.waitUntil { seen.value }
      XCTAssertTrue(controller.playbackSettings.wallpapersMuted)
    }
  }

  func testAppRuleAddUpdateAndRemoveRoundTripAndAnUnknownIdIsRefused() async throws {
    try await withRecordingPanel { panel, _ in
      let app = panel.root.appendingPathComponent("Sample.app")
      try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
      try """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>CFBundleIdentifier</key><string>com.example.sample</string>
        <key>CFBundleName</key><string>Sample</string>
        </dict></plist>
        """.write(to: app.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
      let controller = panel.controller
      controller.chooseApplication = { app }

      try await controller.addAppRule()
      let added = try XCTUnwrap(controller.playback.appRules.first)
      XCTAssertEqual(added.bundleIdentifier, "com.example.sample")
      XCTAssertFalse(added.name.isEmpty)
      XCTAssertFalse(added.name.lowercased().hasSuffix(".app"))
      XCTAssertEqual(added.condition, .running)
      XCTAssertEqual(added.action, .pause)

      try await controller.addAppRule()
      XCTAssertEqual(controller.playback.appRules.count, 1, "The same app is never added twice")

      try await controller.updateAppRule(added.id, condition: .frontmost)
      try await controller.updateAppRule(added.id, action: .mute)
      XCTAssertEqual(controller.playbackSettings.appRules.first?.condition, .frontmost)
      XCTAssertEqual(controller.playbackSettings.appRules.first?.action, .mute)

      do {
        try await controller.updateAppRule(UUID(), action: .stop)
        XCTFail("An unknown rule id must be refused")
      } catch is PlaybackPreferences.UnknownRule {}
      XCTAssertEqual(controller.playback.appRules.count, 1)

      try await controller.removeAppRule(added.id)
      XCTAssertTrue(controller.playback.appRules.isEmpty)
    }
  }

  func testAnAppWithoutABundleIdentifierCannotBeARuleAndACancelledPickerAddsNothing() async throws {
    try await withRecordingPanel { panel, _ in
      let controller = panel.controller
      let bare = panel.root.appendingPathComponent("Bare.app")
      try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)
      controller.chooseApplication = { bare }
      do {
        try await controller.addAppRule()
        XCTFail("An app with no bundle identifier cannot be used in a rule")
      } catch let error as WallpaperActionError {
        XCTAssertFalse(error.localizedDescription.isEmpty)
      }
      controller.chooseApplication = { nil }
      try await controller.addAppRule()
      XCTAssertTrue(controller.playback.appRules.isEmpty)
    }
  }

  /// A setting is queued: it clears an older banner at once and lands after the command that was
  /// running, the way a switch pressed during a wallpaper change always did.
  func testASettingClearsTheBannerAndWaitsItsTurnBehindARunningCommand() async throws {
    try await withRecordingPanel { panel, _ in
      let controller = panel.controller
      controller.errors.actionError = "An older failure"
      var release: CheckedContinuation<Void, Never>?
      let held = Task {
        try await panel.store.commands.run { await withCheckedContinuation { release = $0 } }
      }
      try await panel.waitUntil { release != nil }

      let change = Task { try await controller.setWallpapersMuted(true) }
      try await panel.quiet()
      XCTAssertNil(controller.errors.actionError, "A queued action clears the banner before it waits")
      XCTAssertFalse(controller.playback.wallpapersMuted, "It waits behind the running command")

      release?.resume()
      _ = try await held.value
      try await change.value
      XCTAssertTrue(controller.playback.wallpapersMuted)
    }
  }
}

/// A flag a `@Sendable` observation callback can set.
final class SettingsObservedFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var flag = false
  var value: Bool { lock.withLock { flag } }
  func set() { lock.withLock { flag = true } }
}
