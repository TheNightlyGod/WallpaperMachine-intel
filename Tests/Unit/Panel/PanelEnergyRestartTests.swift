import XCTest

@testable import WallpaperMachine

/// The energy readout compares the figure before a quality change with the one after it, so each of
/// the sixteen settings that change how much rendering work runs restarts the monitor's window once
/// the engine accepted it, and nothing else does. Replaces `WebPanelEnergyUsageTests` (the
/// visibility half of it is `PanelControllerTests.testEnergySamplingRunsOnlyWhileSettingsIsVisible`).
@MainActor
final class PanelEnergyRestartTests: PanelTestCase {
  private struct IdleSource: EnergyUsageSource {
    func sample() -> EnergyUsageSample? {
      EnergyUsageSample(uptimeNanoseconds: 0, own: [:], otherGPUTime: [:])
    }
  }

  /// A controller over the fixture's stores whose monitor is active and counts the windows it
  /// restarts. Nothing else makes this monitor report a change within a test: its own samples come
  /// an hour apart, and a restart is the one thing that reports at once.
  private func makeCounting(_ panel: PanelFixture) -> (controller: PanelController, restarts: () -> Int) {
    let monitor = EnergyUsageMonitor(source: IdleSource(), interval: .seconds(3600))
    let controller = panel.buildSettingsController(energyUsage: monitor)
    monitor.setActive(true)
    XCTAssertTrue(monitor.isActive)
    let counter = RestartCounter()
    monitor.onChange = { counter.count += 1 }
    return (controller, { counter.count })
  }

  private final class RestartCounter { var count = 0 }

  /// Each case of `RenderingSetting` names a typed setter; the switch is exhaustive, so a setting
  /// added to the list cannot go untested.
  private func change(_ setting: RenderingSetting, on controller: PanelController) async throws {
    switch setting {
    case .batteryMode: try await controller.setBatteryMode(.pause)
    case .batteryRenderScale: try await controller.setBatteryRenderScale(0.5)
    case .batteryTargetFps: try await controller.setBatteryTargetFps(20)
    case .frameRateCap: try await controller.setFrameRateCap(30)
    case .qualityPreset: try await controller.applyQualityPreset(.low)
    case .renderScale: try await controller.setRenderScale(0.75)
    case .sceneOptimization: try await controller.setSceneOptimization(false)
    case .sceneOnDemand: try await controller.setSceneOnDemand(true)
    case .sceneVideoPlaneSampling: try await controller.setSceneVideoPlaneSampling(true)
    case .sceneResolution: try await controller.setSceneResolution(.canvas)
    case .lowPowerModeAction: try await controller.setLowPowerModeAction(.reduceQuality)
    case .thermalAction: try await controller.setThermalAction(.reduceQuality)
    case .lowBatteryAction: try await controller.setLowBatteryAction(.reduceQuality)
    }
  }

  func testEveryRenderingSettingRestartsTheComparisonExactlyOnce() async throws {
    XCTAssertEqual(RenderingSetting.allCases.count, 13)
    try await withRecordingPanel { panel, _ in
      let (controller, restarts) = makeCounting(panel)
      defer { controller.energyUsage.setActive(false) }
      for setting in RenderingSetting.allCases {
        let before = restarts()
        try await change(setting, on: controller)
        XCTAssertEqual(restarts(), before + 1, "\(setting) restarts the window once, as the battery mode does")
      }
    }
  }

  func testSettingsThatChangeNoRenderingWorkLeaveTheWindowAlone() async throws {
    try await withRecordingPanel { panel, _ in
      let (controller, restarts) = makeCounting(panel)
      defer { controller.energyUsage.setActive(false) }
      try await controller.setHidesAfterActivating(true)
      try await controller.setWallpapersMuted(true)
      try await controller.setPlaysOnlyOnActiveDisplay(true)
      try await controller.setDisplaySleepAction(.stop)
      try await controller.setOtherAudioAction(.pause)
      try await controller.setDesktopCoveredAction(.keepRunning)
      try await controller.setLowBatteryThreshold(30)
      try await controller.setRefreshesDesktopPicture(true)
      try await controller.setVerboseLogging(true)
      try await controller.setWorkshopUpdateChecks(false)
      try await controller.setConcurrentDownloads(2)
      XCTAssertEqual(restarts(), 0)
    }
  }

  func testARefusedOrFailedChangeDoesNotRestartTheComparison() async throws {
    try await withRecordingPanel { panel, bridge in
      let (controller, restarts) = makeCounting(panel)
      defer { controller.energyUsage.setActive(false) }
      do {
        try await controller.setRenderScale(.nan)
        XCTFail("A render scale that is not a number is refused")
      } catch is InvalidControlValue {}

      // The engine answers nothing, as when it is gone: the change throws and no window restarts.
      bridge.bundleProvider = nil
      do {
        try await controller.setSceneOnDemand(true)
        XCTFail("The engine could not answer")
      } catch {}
      XCTAssertEqual(restarts(), 0)
    }
  }
}
