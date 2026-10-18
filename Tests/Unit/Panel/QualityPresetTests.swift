import XCTest

@testable import WallpaperMachine

/// The Quality row's rules: the presets, the frame-rate slider and the render scale menu.
@MainActor
final class QualityPresetTests: PanelTestCase {
  func testThePresetsSetTheFrameRateLimitAndRenderScaleTogether() {
    XCTAssertEqual(QualityPreset.allCases, [.low, .medium, .high])
    XCTAssertEqual(QualityPreset.low.frameRateCap, 30)
    XCTAssertEqual(QualityPreset.low.renderScale, 0.5)
    XCTAssertEqual(QualityPreset.medium.frameRateCap, 60)
    XCTAssertEqual(QualityPreset.medium.renderScale, 0.75)
    XCTAssertNil(QualityPreset.high.frameRateCap, "High is the default: no frame-rate limit")
    XCTAssertEqual(QualityPreset.high.renderScale, 1)
  }

  /// The preset shown is the one whose cap and scale the saved values match; none matches, Custom.
  func testTheActivePresetIsTheOneTheSavedValuesMatchAndOtherwiseCustom() {
    for preset in QualityPreset.allCases {
      XCTAssertEqual(
        QualityPreset.active(frameRateCap: preset.frameRateCap, preferredRenderScale: preset.renderScale),
        preset)
    }
    XCTAssertEqual(
      QualityPreset.active(frameRateCap: 30, preferredRenderScale: 0.5004), .low,
      "A scale within a thousandth is the preset's")
    XCTAssertNil(QualityPreset.active(frameRateCap: 30, preferredRenderScale: 0.502))
    XCTAssertNil(QualityPreset.active(frameRateCap: 45, preferredRenderScale: 0.75), "Only the saved cap counts")
    XCTAssertNil(QualityPreset.active(frameRateCap: nil, preferredRenderScale: 0.75), "No limit with a lower scale is none of the three")
    XCTAssertNil(QualityPreset.active(frameRateCap: 60, preferredRenderScale: 1))
  }

  func testTheSliderEndsInNoLimitOneStepPastTheHighestRefreshRate() throws {
    try pinPanelLanguageToEnglish()
    let slider = FrameRateCapSlider(refreshRate: 60)
    XCTAssertEqual(slider.maximum, 61)
    XCTAssertEqual(slider.range, 10...61)

    // High reads No limit, 60 is a cap of its own below it, Low is 30 and 24 is 24.
    XCTAssertEqual(slider.readout(atPosition: slider.position(forCap: nil)), "No limit")
    XCTAssertEqual(slider.readout(atPosition: slider.position(forCap: 60)), "60 fps")
    XCTAssertEqual(slider.readout(atPosition: slider.position(forCap: 30)), "30 fps")
    XCTAssertEqual(slider.readout(atPosition: slider.position(forCap: 24)), "24 fps")

    XCTAssertNil(slider.cap(atPosition: 61), "The top position is sent as no limit")
    XCTAssertNil(slider.cap(atPosition: 70))
    XCTAssertEqual(slider.cap(atPosition: 60), 60)
    XCTAssertEqual(slider.cap(atPosition: 10), 10)
  }

  func testTheSliderNeverReadsAValueItCannotOffer() {
    let slider = FrameRateCapSlider(refreshRate: 120)
    XCTAssertEqual(slider.maximum, 121)
    XCTAssertEqual(slider.position(forCap: 240), 120, "A cap above the refresh shows as the refresh")
    XCTAssertEqual(slider.position(forCap: 3), 10, "A cap under 10 shows as 10")
    XCTAssertEqual(slider.position(forCap: nil), 121)
  }

  func testTheRefreshRateIsTheHighestDisplayAndFallsBackTo60() {
    func row(_ maxFps: UInt32) -> BridgeDisplaySettingsRow {
      BridgeDisplaySettingsRow(
        displayId: "d\(maxFps)", title: "", enabled: true, mode: .standalone, mirrorTargets: [],
        selectedMirrorTarget: nil, scalingMode: .fill, scalingFactor: 1, targetFps: 30,
        maxFps: maxFps, muted: false, volume: 1)
    }
    XCTAssertEqual(FrameRateCapSlider(displays: [row(60), row(120)]).refreshRate, 120)
    XCTAssertEqual(FrameRateCapSlider(displays: []).refreshRate, 60)
    XCTAssertEqual(FrameRateCapSlider(displays: [row(0)]).refreshRate, 60, "An implausible figure reads as 60")
    XCTAssertEqual(FrameRateCapSlider(displays: [row(9)]).refreshRate, 60)
    XCTAssertEqual(FrameRateCapSlider(displays: [row(10)]).refreshRate, 10)
    XCTAssertEqual(FrameRateCapSlider(refreshRate: nil).refreshRate, 60)
  }

  func testTheRenderScaleMenuKeepsAHandEditedValueInsteadOfSnappingToAStep() throws {
    try pinPanelLanguageToEnglish()
    let standard = RenderScaleChoices.options(saved: 0.75)
    XCTAssertEqual(standard.map(\.scale), [1, 0.75, 0.5])
    XCTAssertEqual(standard.map(\.title), ["100% (native)", "75%", "50%"])

    let edited = RenderScaleChoices.options(saved: 0.6)
    XCTAssertEqual(edited.map(\.scale), [0.6, 1, 0.75, 0.5])
    XCTAssertEqual(edited.first?.title, "60% (from configuration)")
    XCTAssertEqual(RenderScaleChoices.options(saved: .nan).count, 3, "Nothing to carry for a figure that is not a number")
    XCTAssertEqual(RenderScaleChoices.percent(0.76), "76%")
    XCTAssertEqual(RenderScaleChoices.percent(.infinity), "Unavailable")
  }

  /// A display's frame rate is held to the ceiling the engine reports, whatever lowered it, and the
  /// limit is put down to the setting that set it (the rule itself is `FrameRateCeiling`'s).
  func testTheControllerReportsTheLimitFromTheEnginesCeilingAndItsSource() async throws {
    try await withPanel { panel in
      panel.store.settingsSnapshot.frameRateCap = 24
      panel.store.settingsSnapshot.effectiveFrameRateCap = 24
      XCTAssertEqual(panel.controller.frameRateLimit(saved: 30)?.fps, 24)
      XCTAssertEqual(panel.controller.frameRateLimit(saved: 30)?.source, .frameRateLimit)
      XCTAssertNil(panel.controller.frameRateLimit(saved: 20))

      // On battery reads Keep running, no limit is saved, and the low-battery rule reduces quality.
      panel.store.settingsSnapshot.batteryMode = .keepRunning
      panel.store.settingsSnapshot.onBatteryPower = true
      panel.store.settingsSnapshot.frameRateCap = nil
      panel.store.settingsSnapshot.qualityThrottle = [.lowBattery]
      panel.store.settingsSnapshot.effectiveFrameRateCap = 30
      XCTAssertEqual(panel.controller.frameRateLimit(saved: 60)?.source, .reducedQuality(.lowBattery))
      XCTAssertEqual(panel.controller.frameRateLimit(saved: 60)?.section, .playback)

      panel.store.settingsSnapshot.qualityThrottle = []
      panel.store.settingsSnapshot.effectiveFrameRateCap = nil
      XCTAssertNil(panel.controller.frameRateLimit(saved: 30))
    }
  }
}
