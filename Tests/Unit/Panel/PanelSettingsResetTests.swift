import XCTest

@testable import WallpaperMachine

/// Settings › General › Reset all settings: asked first, then every setting back to its default,
/// while the user's content stays.
@MainActor
final class PanelSettingsResetTests: PanelTestCase {
  func testResetAsksFirstAndCancelChangesNothing() async throws {
    try await withRecordingPanel { panel, _ in
      let controller = panel.controller
      try await controller.setHidesAfterActivating(true)
      try controller.setThemeAccent("#ff0000")

      try await controller.resetAllSettings()

      XCTAssertEqual(panel.dialogs.confirmations.count, 1, "Resetting everything must be confirmed")
      XCTAssertTrue(controller.generalSettings.hidesAfterActivating, "Cancel keeps every setting")
      XCTAssertEqual(controller.themePreferences.accent, "#ff0000")
    }
  }

  func testConfirmedResetReturnsEverySettingToItsDefaultAndKeepsContent() async throws {
    try await withRecordingPanel { panel, bridge in
      let controller = panel.controller
      try await controller.setHidesAfterActivating(true)
      try await controller.setLibraryPreviewsOnHover(true)
      try controller.setThemeAccent("#ff0000")
      try await controller.setHotKey(.togglePlayback, keyCode: 35, modifierFlags: [.command, .option])
      try await controller.setDesktopCoveredAction(.keepRunning)
      try await controller.setPlaysOnlyOnActiveDisplay(true)
      try await controller.setOtherAppInFrontAction(.pauseOnBattery)
      controller.playback.addRule(bundleIdentifier: "com.example.game", name: "Game")
      try await controller.setLivePropertyEdits(true)
      try await controller.setConcurrentDownloads(6)
      try await controller.setWorkshopUpdateChecks(false)
      try await controller.setSceneOptimization(false)
      try await controller.setMetalFXUpscaling(true)
      try await controller.setSceneDisplayFraming(true)
      try await controller.setVerboseLogging(true)
      try await controller.setBatteryTargetFps(15)
      try PanelPreferences.saveFavorites(["kept"], in: panel.defaults)
      bridge.sceneOptimizationCalls = []
      bridge.metalFXUpscalingCalls = []
      bridge.sceneDisplayFramingCalls = []
      bridge.verboseLoggingCalls = []
      bridge.batteryProfileCalls = []

      panel.dialogs.confirmAnswer = true
      try await controller.resetAllSettings()

      XCTAssertFalse(controller.generalSettings.hidesAfterActivating)
      XCTAssertFalse(controller.generalSettings.playsLibraryPreviewsOnHover)
      XCTAssertFalse(controller.library.playsPreviewsOnHover, "the grid plays every tile again at once")
      XCTAssertEqual(controller.themePreferences, AppThemePreferences())
      XCTAssertNil(controller.hotKeys.bindings[.togglePlayback])
      XCTAssertEqual(controller.playback.desktopCoveredAction, .pause)
      XCTAssertFalse(controller.playback.playsOnlyOnActiveDisplay)
      XCTAssertEqual(controller.playback.otherAppInFrontAction, .keepRunning)
      XCTAssertTrue(controller.playback.appRules.isEmpty)
      XCTAssertFalse(controller.desktopSettings.livePropertyEdits)
      XCTAssertEqual(
        controller.workshop.downloader.maximumConcurrentDownloads,
        WorkshopDownloadManager.defaultConcurrentDownloads)
      XCTAssertTrue(controller.workshop.updates.checksAutomatically)

      XCTAssertEqual(bridge.sceneOptimizationCalls, [true])
      XCTAssertEqual(bridge.metalFXUpscalingCalls, [false])
      XCTAssertEqual(bridge.sceneDisplayFramingCalls, [false])
      XCTAssertEqual(bridge.verboseLoggingCalls, [false])
      XCTAssertEqual(bridge.batteryProfileCalls, [.init(renderScale: 0.75, targetFps: 30)])

      XCTAssertEqual(PanelPreferences.favorites(in: panel.defaults), ["kept"], "Content is not a setting")
    }
  }
}
