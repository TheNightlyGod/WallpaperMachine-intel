import Observation
import XCTest

@testable import WallpaperMachine

/// The merged settings values the pages read: the bridge's snapshot, the playback preferences and the
/// Mac's own facts as typed state. Replaces the settings half of the old snapshot assertions
/// (`testSnapshotPublishes…` in `WebPanelPerformanceSettingsTests` and `WebPanelSceneSettingsTests`).
@MainActor
final class PanelSettingsValuesTests: PanelTestCase {
  func testPerformanceAndPlaybackSettingsCarryEveryValueTheirRowsRead() async throws {
    try await withRecordingPanel { panel, _ in
      let settings = BridgeSnapshotFixtures.settings(
        displays: panel.store.settingsSnapshot.displays, batteryMode: .reducedQuality,
        videoBackends: [
          BridgeVideoBackendReport(
            displayId: 2, displayName: "Display 2", wallpaperId: "beach", wallpaperTitle: "Beach",
            backend: "legacy", fallbackReason: "29.97 fps is below the 30 fps target")
        ],
        renderScale: 0.75, preferredRenderScale: 1, frameRateCap: 45,
        batteryRenderScale: 0.75, batteryTargetFps: 30, onBatteryPower: true)
      panel.store.settingsSnapshot = settings
      let playback = panel.controller.playback
      playback.displaySleepAction = .stop
      playback.otherAudioAction = .mute
      playback.desktopCoveredAction = .keepRunning
      playback.addRule(bundleIdentifier: "com.example.sample", name: "Sample")

      let performance = panel.controller.performanceSettings
      XCTAssertEqual(performance.quality.renderScale, 0.75)
      XCTAssertEqual(performance.quality.preferredRenderScale, 1)
      XCTAssertTrue(performance.quality.renderScaleSupported)
      XCTAssertEqual(performance.frameRateCap, 45, "The saved cap stays the saved cap")
      XCTAssertEqual(performance.slider.refreshRate, 60)
      XCTAssertNil(performance.activePreset, "45 fps at full scale is none of the presets")
      XCTAssertEqual(performance.videoBackends.count, 1)
      XCTAssertEqual(performance.videoBackends[0].displayID, 2)
      XCTAssertEqual(performance.videoBackends[0].backend, "legacy")
      XCTAssertEqual(performance.videoBackends[0].fallbackReason, "29.97 fps is below the 30 fps target")

      let playbackSettings = panel.controller.playbackSettings
      XCTAssertEqual(playbackSettings.batteryMode, .reducedQuality)
      XCTAssertEqual(playbackSettings.batteryRenderScale, 0.75)
      XCTAssertEqual(playbackSettings.batteryTargetFps, 30)
      XCTAssertTrue(playbackSettings.onBatteryPower)
      XCTAssertEqual(playbackSettings.displaySleepAction, .stop)
      XCTAssertEqual(playbackSettings.otherAudioAction, .mute)
      XCTAssertEqual(playbackSettings.desktopCoveredAction, .keepRunning)
      XCTAssertEqual(playbackSettings.appRules.count, 1)
      XCTAssertEqual(playbackSettings.appRules[0].name, "Sample")
      XCTAssertEqual(playbackSettings.appRules[0].bundleIdentifier, "com.example.sample")
      XCTAssertEqual(playbackSettings.appRules[0].condition, .running)
      XCTAssertEqual(playbackSettings.appRules[0].action, .pause)

      panel.store.settingsSnapshot.videoBackends = []
      XCTAssertTrue(panel.controller.performanceSettings.videoBackends.isEmpty)
    }
  }

  func testTheEffectiveCeilingAndTheThrottleCausesAreCarriedBesideTheSavedCap() async throws {
    try await withRecordingPanel { panel, _ in
      panel.store.settingsSnapshot.frameRateCap = 45
      panel.store.settingsSnapshot.effectiveFrameRateCap = 24
      panel.store.settingsSnapshot.qualityThrottle = [.heat, .lowPowerMode]

      let throttled = panel.controller.performanceSettings
      XCTAssertEqual(throttled.effectiveFrameRateCap, 24)
      XCTAssertEqual(throttled.quality.causes, [.heat, .lowPowerMode])
      XCTAssertEqual(throttled.frameRateCap, 45)

      panel.store.settingsSnapshot.effectiveFrameRateCap = nil
      panel.store.settingsSnapshot.qualityThrottle = [.lowBattery]
      XCTAssertEqual(panel.controller.performanceSettings.quality.causes, [.lowBattery])

      panel.store.settingsSnapshot.frameRateCap = nil
      panel.store.settingsSnapshot.qualityThrottle = []
      let free = panel.controller.performanceSettings
      XCTAssertNil(free.effectiveFrameRateCap, "No ceiling is nil, not zero")
      XCTAssertTrue(free.quality.causes.isEmpty)
      XCTAssertNil(free.frameRateCap)
      XCTAssertEqual(free.sliderPosition, free.slider.maximum, "No limit is the top of the slider")
    }
  }

  func testTheFrameRateSliderFollowsTheHighestDisplayRefresh() async throws {
    try await withRecordingPanel { panel, _ in
      XCTAssertEqual(panel.controller.performanceSettings.slider.refreshRate, 60)
      panel.store.settingsSnapshot.displays[0].maxFps = 120
      XCTAssertEqual(panel.controller.performanceSettings.slider.maximum, 121)
      panel.store.settingsSnapshot.frameRateCap = 30
      XCTAssertEqual(panel.controller.performanceSettings.activePreset, nil)
      panel.store.settingsSnapshot.preferredRenderScale = 0.5
      XCTAssertEqual(panel.controller.performanceSettings.activePreset, .low)
    }
  }

  func testTheRenderScaleMenuFollowsTheSavedScaleAndIsDisabledWhereNoneCanHonourIt() async throws {
    try await withRecordingPanel { panel, _ in
      panel.store.settingsSnapshot.preferredRenderScale = 0.6
      XCTAssertEqual(panel.controller.performanceSettings.renderScaleChoices.first?.scale, 0.6)
      panel.store.settingsSnapshot.renderScaleSupported = false
      XCTAssertFalse(panel.controller.performanceSettings.canChangeRenderScale)
      panel.store.settingsSnapshot.renderScaleSupported = true
      XCTAssertTrue(panel.controller.performanceSettings.canChangeRenderScale)
    }
  }

  /// Whether this Mac has a battery is the Mac's business; the rows need a charge they can show, or
  /// nil that hides them.
  func testTheLowBatteryRowsExistOnlyWhereThereIsABattery() async throws {
    try pinPanelLanguageToEnglish()
    try await withRecordingPanel { panel, _ in
      let controller = panel.controller
      let reading = controller.playbackSettings.batteryPercent
      if let reading { XCTAssertTrue((0...100).contains(reading)) }

      controller.batteryPercent = nil
      var settings = controller.playbackSettings
      XCTAssertFalse(settings.hasBattery)
      XCTAssertFalse(settings.showsLowBatteryRows)
      XCTAssertNil(settings.lowBatteryNote)
      XCTAssertFalse(settings.showsLowBatteryLevel)

      controller.batteryPercent = 54
      controller.playback.lowBatteryAction = .pause
      controller.playback.lowBatteryThreshold = 30
      settings = controller.playbackSettings
      XCTAssertTrue(settings.showsLowBatteryRows)
      XCTAssertEqual(settings.lowBatteryAction, .pause)
      XCTAssertEqual(settings.lowBatteryThreshold, 30)
      XCTAssertTrue(settings.showsLowBatteryLevel, "The level is asked once the rule does something")
      XCTAssertTrue(settings.lowBatteryNote?.hasSuffix("The battery is at 54% now.") == true)

      controller.playback.lowBatteryAction = .keepRunning
      XCTAssertFalse(controller.playbackSettings.showsLowBatteryLevel)

      // The reduced-quality choice of a Mac without a battery does not ask for the profile.
      controller.playback.lowBatteryAction = .reduceQuality
      XCTAssertTrue(controller.qualityReport.reducedQualityChosen)
      controller.batteryPercent = nil
      XCTAssertFalse(controller.qualityReport.reducedQualityChosen)
    }
  }

  func testTheOtherPlaybackRowsAppearByTheRulesThePageHad() async throws {
    try await withRecordingPanel { panel, _ in
      let controller = panel.controller
      XCTAssertEqual(controller.playbackSettings.enabledDisplayCount, 1)
      XCTAssertFalse(controller.playbackSettings.showsActiveDisplayOnly, "One display has no other to pause")
      controller.playback.playsOnlyOnActiveDisplay = true
      XCTAssertTrue(controller.playbackSettings.showsActiveDisplayOnly, "Shown while on, so it can be turned off")
      controller.playback.playsOnlyOnActiveDisplay = false
      panel.configureDisplays()
      XCTAssertEqual(controller.playbackSettings.enabledDisplayCount, 2)
      XCTAssertTrue(controller.playbackSettings.showsActiveDisplayOnly)

      controller.batteryPercent = nil
      panel.store.settingsSnapshot.batteryMode = .keepRunning
      XCTAssertFalse(controller.playbackSettings.offersBatteryMode)
      panel.store.settingsSnapshot.batteryMode = .pause
      XCTAssertTrue(controller.playbackSettings.offersBatteryMode, "A choice that is not the default stays editable")
      controller.batteryPercent = 80
      panel.store.settingsSnapshot.batteryMode = .keepRunning
      XCTAssertTrue(controller.playbackSettings.offersBatteryMode)
    }
  }

  func testLowPowerModeAndHeatNotesFollowTheChoiceAndTheMac() async throws {
    try pinPanelLanguageToEnglish()
    try await withRecordingPanel { panel, _ in
      let settings = panel.controller.playbackSettings
      XCTAssertEqual(
        settings.lowPowerModeNote,
        ProcessInfo.processInfo.isLowPowerModeEnabled ? "Low Power Mode is on now." : "Low Power Mode is off now.")
      XCTAssertEqual(settings.thermalLevel, ThermalLevel(ProcessInfo.processInfo.thermalState))
      XCTAssertEqual(settings.thermalNote, settings.thermalLevel.note(for: settings.thermalAction))
      XCTAssertEqual(settings.focusNote == nil, settings.focusAction == "keepRunning")
    }
  }

  // MARK: Observation

  /// Facts nothing notifies the app about are read again on request, and a getter that read them
  /// asks its view to draw again.
  func testRefreshingTheSystemReadingsTakesTheBatteryAgainAndWakesTheReaders() async throws {
    try await withRecordingPanel { panel, _ in
      let controller = panel.controller
      let before = controller.systemReadingsRevision
      let seen = SettingsObservedFlag()
      withObservationTracking {
        _ = controller.desktopSettings
        _ = controller.storageState
      } onChange: {
        seen.set()
      }
      controller.batteryPercent = -1
      controller.refreshSystemReadings()
      XCTAssertEqual(controller.systemReadingsRevision, before &+ 1)
      XCTAssertNotEqual(controller.batteryPercent, -1, "The charge is read again")
      try await panel.waitUntil { seen.value }
    }
  }

  func testAPlaybackChangeFromElsewhereWakesTheGetterThatReadItsRevision() async throws {
    try await withRecordingPanel { panel, _ in
      let controller = panel.controller
      let seen = SettingsObservedFlag()
      withObservationTracking {
        _ = controller.desktopSettings
      } onChange: {
        seen.set()
      }
      controller.playback.refreshesDesktopPicturePeriodically = true
      try await panel.waitUntil { seen.value }
      XCTAssertTrue(controller.desktopSettings.refreshesDesktopPicture)
    }
  }

  // MARK: Library and Steam

  /// The Downloads-at-once menu changes how many Steam downloads run at once, and the choice is read
  /// back; only a count the menu offers is accepted.
  func testDownloadsAtOnceReachesTheQueueAndOnlyOfferedCountsAreAccepted() async throws {
    try await withRecordingPanel { panel, _ in
      let controller = panel.controller
      XCTAssertEqual(controller.librarySteamSettings.concurrentDownloadsRange, 1...6)

      try await controller.setConcurrentDownloads(5)
      XCTAssertEqual(panel.workshop.downloader.maximumConcurrentDownloads, 5)
      XCTAssertEqual(panel.workshop.downloader.slotLimit, 5)
      XCTAssertEqual(controller.librarySteamSettings.concurrentDownloads, 5)

      for bad in [0, 7, -1, 100] {
        do {
          try await controller.setConcurrentDownloads(bad)
          XCTFail("\(bad) is not a count the menu offers")
        } catch is InvalidControlValue {}
      }
      XCTAssertEqual(panel.workshop.downloader.maximumConcurrentDownloads, 5)
    }
  }

  func testTheDailyWorkshopCheckIsStoredAndReported() async throws {
    try await withRecordingPanel { panel, _ in
      XCTAssertTrue(panel.controller.librarySteamSettings.workshopUpdateChecks, "On until turned off")
      try await panel.controller.setWorkshopUpdateChecks(false)
      XCTAssertFalse(panel.workshop.updates.checksAutomatically)
      XCTAssertFalse(panel.controller.librarySteamSettings.workshopUpdateChecks)
      try await panel.controller.setWorkshopUpdateChecks(true)
      XCTAssertTrue(panel.controller.librarySteamSettings.workshopUpdateChecks)
    }
  }
}
