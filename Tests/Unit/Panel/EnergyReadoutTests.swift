import Observation
import XCTest

@testable import WallpaperMachine

/// The energy readout's words: the grade, the battery share, the comparison with the figure before
/// the last change, and the formatting of watts. The sampling rules are `EnergyUsageMonitorTests`.
@MainActor
final class EnergyReadoutTests: PanelTestCase {
  private let en = Locale(identifier: "en_US")

  private func ready(cpu: Double, gpu: Double, contended: Bool = false, nativeVideo: Bool = false)
    -> EnergyUsageReading
  {
    EnergyUsageReading(
      status: .ready, cpuMilliwatts: cpu, gpuMilliwatts: gpu, gpuContended: contended,
      nativeVideo: nativeVideo, seconds: 6)
  }

  private func readout(
    _ reading: EnergyUsageReading, comparison: EnergyUsageComparison? = nil, battery: Double? = nil
  ) -> EnergyReadout {
    EnergyReadout(reading: reading, comparison: comparison, batteryCapacityWattHours: battery)
  }

  func testAComparableFigureIsGradedAndGivenABatteryShare() throws {
    try pinPanelLanguageToEnglish()
    let low = readout(ready(cpu: 100, gpu: 100), battery: 50)
    XCTAssertEqual(low.status, .ready)
    XCTAssertEqual(low.totalMilliwatts, 200)
    XCTAssertEqual(low.level, .low)
    XCTAssertEqual(low.levelTitle, "Low energy use")
    XCTAssertEqual(low.batteryShareNote, "Less than 1% of a full battery charge per hour.")

    let medium = readout(ready(cpu: 800, gpu: 200), battery: 50)
    XCTAssertEqual(medium.level, .medium)
    XCTAssertEqual(medium.levelTitle, "Medium energy use")
    XCTAssertEqual(
      medium.batteryPercentPerHour ?? 0, 2, accuracy: 0.001,
      "1 W of a 50 Wh battery is 2% an hour")
    XCTAssertEqual(medium.batteryShareNote, "About 2% of a full battery charge per hour.")

    let high = readout(ready(cpu: 1500, gpu: 1500))
    XCTAssertEqual(high.level, .high)
    XCTAssertEqual(high.levelTitle, "High energy use")
    XCTAssertNil(high.batteryShareNote, "A Mac without a battery has no share")
  }

  /// A figure that something qualifies is shown, with what qualifies it, but never graded or compared.
  func testAFigureThatNativeVideoOrGPUContentionQualifiesHasNoGrade() throws {
    try pinPanelLanguageToEnglish()
    let video = readout(ready(cpu: 800, gpu: 200, nativeVideo: true), battery: 50)
    XCTAssertNil(video.level)
    XCTAssertNil(video.levelTitle)
    XCTAssertNil(video.batteryPercentPerHour)
    XCTAssertEqual(video.caveats, [.nativeVideo])
    XCTAssertEqual(EnergyReadout.Caveat.nativeVideo.title, "Video not counted")

    let shared = readout(ready(cpu: 800, gpu: 200, contended: true))
    XCTAssertNil(shared.level)
    XCTAssertEqual(shared.caveats, [.gpuContended])
    XCTAssertEqual(EnergyReadout.Caveat.gpuContended.title, "GPU shared with other apps")

    let both = readout(ready(cpu: 800, gpu: 200, contended: true, nativeVideo: true))
    XCTAssertEqual(both.caveats, [.nativeVideo, .gpuContended], "Native video is named first")
    for caveat in both.caveats { XCTAssertFalse(caveat.note.isEmpty) }
  }

  func testMeasuringAndUnavailableCarryNoFigures() {
    XCTAssertEqual(readout(.measuring).status, .measuring)
    XCTAssertEqual(readout(.unavailable).status, .unavailable)
    XCTAssertNil(readout(.measuring).level)
    XCTAssertEqual(EnergyReadout.measuring.status, .measuring)
  }

  func testMilliwattsReadInMilliwattsBelowAWattAndWattsWithOneDecimalFromIt() throws {
    try pinPanelLanguageToEnglish()
    XCTAssertEqual(EnergyReadout.milliwatts(840, locale: en), "840 mW")
    XCTAssertEqual(EnergyReadout.milliwatts(839.6, locale: en), "840 mW")
    XCTAssertEqual(EnergyReadout.milliwatts(999.4, locale: en), "999 mW")
    XCTAssertEqual(EnergyReadout.milliwatts(1000, locale: en), "1.0 W")
    XCTAssertEqual(EnergyReadout.milliwatts(1250, locale: en), "1.3 W", "Half rounds away from zero")
    XCTAssertEqual(EnergyReadout.milliwatts(12_340, locale: en), "12.3 W")
    XCTAssertEqual(EnergyReadout.milliwatts(.nan, locale: en), "Unavailable")
    XCTAssertEqual(EnergyReadout.milliwatts(.infinity, locale: en), "Unavailable")
    XCTAssertEqual(
      EnergyReadout.milliwatts(1250, locale: Locale(identifier: "de_DE")), "1,3 W",
      "The Mac's region decides the decimal mark")
  }

  func testTheComparisonSaysWhatTheChangeDid() throws {
    try pinPanelLanguageToEnglish()
    func note(before: Double, after: Double?) -> String? {
      readout(
        ready(cpu: 100, gpu: 0),
        comparison: EnergyUsageComparison(
          before: ready(cpu: before, gpu: 0),
          after: after.map { ready(cpu: $0, gpu: 0) })
      ).comparisonNote(locale: en)
    }
    XCTAssertNil(readout(ready(cpu: 100, gpu: 0)).comparisonNote(locale: en), "Nothing to compare")
    XCTAssertEqual(
      note(before: 2000, after: nil), "Measuring the effect of your change. Before it: 2.0 W.")
    XCTAssertEqual(
      note(before: 2000, after: 1000), "Before your change: 2.0 W. Now: 1.0 W (\u{2212}50%).",
      "The minus sign is U+2212")
    XCTAssertEqual(
      note(before: 1000, after: 1500), "Before your change: 1.0 W. Now: 1.5 W (+50%).")
    XCTAssertEqual(
      note(before: 1000, after: 1001), "Before your change: 1.0 W. Now: 1.0 W, about the same.",
      "A change that rounds to nothing is about the same")
    XCTAssertEqual(
      note(before: 0, after: 400), "Before your change: 0 mW. Now: 400 mW, about the same.",
      "No percentage can be worked out from nothing")
  }

  func testTheMonitorHandsTheReadoutItsGradeAndComparison() {
    let monitor = EnergyUsageMonitor(source: nil, interval: .seconds(3600))
    monitor.setActive(true)
    let unavailable = monitor.readout
    XCTAssertEqual(unavailable.status, .unavailable, "Without a source there is nothing to measure")
    monitor.setActive(false)
  }

  func testTheControllerReadoutFollowsTheMonitorsChanges() async throws {
    try await withPanel { panel in
      let controller = panel.controller
      XCTAssertEqual(controller.energyReadout.status, .measuring)
      let seen = SettingsObservedFlag()
      withObservationTracking {
        _ = controller.energyReadout
      } onChange: {
        seen.set()
      }
      controller.energyUsage.onChange?()
      try await panel.waitUntil { seen.value }
    }
  }
}
