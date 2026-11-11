import AppKit
import SwiftUI
import XCTest

@testable import WallpaperMachine

/// The six Settings pages of this area drawn in a window that is never shown: each takes the narrowest
/// column it can be given and the widest, in light and dark and in every shipped language, with
/// everything open and the longest wording the fixtures can make.
@MainActor
final class SettingsSectionsRenderTests: PanelTestCase {
  private static let sections: [SettingsSection] = [
    .quick, .general, .appearance, .desktop, .playback, .performance,
  ]
  /// The detail column of the smallest window with the sidebar dragged to its widest: 760 points
  /// minus 300.
  private static let narrow = NSSize(width: 460, height: 560)
  private static let wide = NSSize(width: 980, height: 800)

  private var longName: String {
    String(repeating: "Studio Display — 外接显示器 with a very long display name · ", count: 3)
  }

  /// A Mac with a battery, two displays, running scenes and a stopped one, app rules and an energy
  /// reading, every disclosure open.
  private func richController(_ panel: PanelFixture, long: Bool) -> PanelController {
    panel.store.snapshotRevision = 1
    let name = long ? longName : "Studio Display"
    var settings = BridgeSnapshotFixtures.settings(
      displays: panel.store.settingsSnapshot.displays, batteryMode: .reducedQuality,
      videoBackends: [
        BridgeVideoBackendReport(
          displayId: 1, displayName: name, wallpaperId: "beach", wallpaperTitle: name,
          backend: "native", fallbackReason: long ? longName : nil)
      ],
      sceneUpdateModes: [
        BridgeSceneUpdateModeReport(
          displayId: 1, displayName: name, wallpaperId: "a", wallpaperTitle: name,
          mode: "waiting_for_event", reasons: ["animation", "particles", "an unlisted reason"]),
        BridgeSceneUpdateModeReport(
          displayId: 2, displayName: name, wallpaperId: "b", wallpaperTitle: name,
          mode: "stopped_after_failure", reasons: []),
      ],
      sceneRenderers: [
        BridgeSceneBackendReport(
          displayId: 1, displayName: name, wallpaperId: "a", wallpaperTitle: name,
          backend: "native_metal", failureStage: nil, failureReason: nil, videoPath: "nv12_converted_preparing",
          optimizationApplied: true, qualityInForce: nil),
        BridgeSceneBackendReport(
          displayId: 2, displayName: name, wallpaperId: "b", wallpaperTitle: name,
          backend: "unknown", failureStage: "unsupported",
          failureReason: long ? longName : "Uses lit particles", videoPath: "none",
          optimizationApplied: false, qualityInForce: nil),
      ],
      renderScale: 0.75, preferredRenderScale: 1, frameRateCap: 45, onBatteryPower: true,
      qualityThrottle: [.lowPowerMode])
    settings.launchAtLoginAvailable = true
    settings.launchAtLoginNeedsApproval = true
    panel.store.settingsSnapshot = settings
    let monitor = EnergyUsageMonitor(source: nil)
    for step in 0..<4 {
      monitor.record(
        EnergyUsageSample(
          uptimeNanoseconds: UInt64(step) * 2_000_000_000,
          own: [
            1: CoalitionEnergyCounters(
              cpuEnergyNanojoules: UInt64(step) * 840_000_000,
              gpuEnergyNanojoules: UInt64(step) * 1_220_000_000, gpuTimeNanoseconds: 0)
          ], otherGPUTime: [:]))
    }
    let controller = panel.buildSettingsController(energyUsage: monitor)
    controller.batteryPercent = 54
    controller.playback.lowBatteryAction = .reduceQuality
    controller.playback.playsOnlyOnActiveDisplay = true
    controller.playback.addRule(bundleIdentifier: "com.apple.dt.Xcode", name: long ? longName : "Xcode")
    controller.playback.addRule(bundleIdentifier: "com.example.missing", name: "")
    for item in [
      PerformanceSettingsSection.advanced, PerformanceSettingsSection.videoDiagnostics,
      PerformanceSettingsSection.sceneDiagnostics, PerformanceSettingsSection.sceneCompatibility,
      PerformanceSettingsSection.energyMethod, PlaybackSettingsSection.appRules,
      PlaybackSettingsSection.whatChanges, DesktopSettingsSection.lockScreenContext,
      DesktopSettingsSection.screenSaverContext,
    ] {
      controller.settings.setOpen(true, for: item)
    }
    return controller
  }

  /// The pages without the column around them: `SettingsDetail` asks the split view for no width,
  /// so only the pages themselves can say how narrow they can go.
  private func host(_ controller: PanelController) -> (NSWindow, NSHostingController<AnyView>) {
    let hosting = NSHostingController(
      rootView: AnyView(
        SettingsPages().environment(controller)
          .panelTheme(theme: controller.theme, locale: PanelLocale.shared)))
    hosting.sizingOptions = []
    let window = ControlPanelWindow.make(contentViewController: hosting, delegate: nil)
    return (window, hosting)
  }

  private func settle(_ hosting: NSHostingController<AnyView>, _ window: NSWindow, at size: NSSize) {
    window.setContentSize(size)
    window.layoutIfNeeded()
    hosting.view.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.06))
    hosting.view.layoutSubtreeIfNeeded()
  }

  /// The least width the page can be laid out in, and the size it takes of the window it is given.
  private func assertLaysOut(
    _ hosting: NSHostingController<AnyView>, in size: NSSize, _ context: String,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    let least = hosting.sizeThatFits(in: NSSize(width: 0, height: size.height))
    XCTAssertLessThanOrEqual(
      least.width, size.width, "\(context): the page cannot be narrower than \(least.width) points",
      file: file, line: line)
    let taken = hosting.sizeThatFits(in: size)
    XCTAssertEqual(taken.width, size.width, accuracy: 1, "\(context): takes the width it is given", file: file, line: line)
    XCTAssertLessThanOrEqual(taken.height, size.height + 1, "\(context): scrolls instead of growing the window", file: file, line: line)
  }

  private func bind(language tag: String) throws {
    let store = AppLanguageStore(
      defaults: try TemporaryDefaults.make(for: self).defaults, systemLanguages: [tag])
    PanelLocale.shared.bind(to: store)
  }

  override func tearDown() async throws {
    PanelLocale.shared.bind(to: .testHost)
    try await super.tearDown()
  }

  // MARK: The pages

  func testEverySectionLaysOutInTheNarrowestAndTheWidestColumnInEveryLanguageAndAppearance() async throws {
    try await withRecordingPanel { panel, _ in
      let controller = richController(panel, long: true)
      let (window, hosting) = host(controller)
      for language in AppLanguage.supported.map(\.tag) {
        try bind(language: language)
        for section in Self.sections {
          controller.settings.select(section)
          for dark in [false, true] {
            hosting.view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            for size in [Self.narrow, Self.wide] {
              settle(hosting, window, at: size)
              assertLaysOut(hosting, in: size, "\(section) \(language) \(dark ? "dark" : "light") \(Int(size.width))")
            }
          }
        }
      }
      XCTAssertFalse(window.isVisible, "Layout stays offscreen")
      window.contentViewController = nil
      window.close()
    }
  }

  /// A page that has nothing to show (no snapshot yet) still lays out, with its notice.
  func testEverySectionLaysOutBeforeTheFirstSnapshotWithTheUnavailableNotice() async throws {
    try await withRecordingPanel { panel, _ in
      let controller = panel.controller
      XCTAssertTrue(controller.settings.isUnavailable)
      let (window, hosting) = host(controller)
      for section in Self.sections {
        controller.settings.select(section)
        settle(hosting, window, at: Self.narrow)
        assertLaysOut(hosting, in: Self.narrow, "\(section) unavailable")
      }
      window.contentViewController = nil
      window.close()
    }
  }

  /// With a search on, the pages stack and show only the rows that match, in the same column.
  func testSearchResultsOfTheSixPagesLayOutInTheNarrowColumn() async throws {
    try await withRecordingPanel { panel, _ in
      let controller = richController(panel, long: false)
      let (window, hosting) = host(controller)
      for query in ["a", "Mission Control", "battery", "scene", "zzz-nothing"] {
        controller.settings.query = query
        settle(hosting, window, at: Self.narrow)
        assertLaysOut(hosting, in: Self.narrow, "search \(query)")
      }
      controller.settings.query = ""
      window.contentViewController = nil
      window.close()
    }
  }

  // MARK: The energy readout

  func testEveryStateOfTheEnergyReadoutLaysOutInTheNarrowColumnInEveryLanguage() throws {
    let ready = EnergyUsageReading(
      status: .ready, cpuMilliwatts: 840, gpuMilliwatts: 1_220, gpuContended: false,
      nativeVideo: false, seconds: 6)
    let states: [EnergyReadout] = [
      .measuring, EnergyReadout(status: .unavailable),
      EnergyReadout(reading: ready, comparison: nil, batteryCapacityWattHours: 50),
      EnergyReadout(
        reading: ready,
        comparison: EnergyUsageComparison(before: ready, after: nil), batteryCapacityWattHours: nil),
      EnergyReadout(
        reading: {
          var native = ready
          native.nativeVideo = true
          native.gpuContended = true
          return native
        }(), comparison: nil, batteryCapacityWattHours: 50),
    ]
    let theme = PanelTheme(appearance: .light)
    for language in AppLanguage.supported {
      try bind(language: language.tag)
      for reading in states {
        let hosting = NSHostingController(
          rootView: PerformanceEnergyReading(reading: reading).environment(\.panelTheme, theme)
            .environment(\.locale, PanelLocale.shared.locale))
        let width: CGFloat = 440
        let size = hosting.sizeThatFits(in: NSSize(width: width, height: 10_000))
        XCTAssertLessThanOrEqual(size.width, width, "\(language.tag) \(reading.status)")
        XCTAssertGreaterThan(size.height, 10, "The state draws something")
        let least = hosting.sizeThatFits(in: NSSize(width: 0, height: 10_000))
        XCTAssertLessThanOrEqual(least.width, width, "\(language.tag) \(reading.status) wraps into the column")
      }
    }
  }

  /// The row names the readout and the readout is its value: VoiceOver reaches it once and reads the
  /// grade and the figures in one line, and it is never announced while the figures change.
  func testTheEnergyReadoutIsOneSpokenLineWithItsFigures() throws {
    try pinPanelLanguageToEnglish()
    let ready = EnergyUsageReading(
      status: .ready, cpuMilliwatts: 840, gpuMilliwatts: 1_220, gpuContended: false, nativeVideo: false,
      seconds: 6)
    let graded = PerformanceEnergyReading(
      reading: EnergyReadout(reading: ready, comparison: nil, batteryCapacityWattHours: 50)).summary
    for word in ["High energy use", "CPU", "GPU", "840 mW", "of a full battery charge per hour"] {
      XCTAssertTrue(graded.contains(word), "\(word) is missing from: \(graded)")
    }
    var native = ready
    native.nativeVideo = true
    let qualified = PerformanceEnergyReading(
      reading: EnergyReadout(reading: native, comparison: nil, batteryCapacityWattHours: 50)).summary
    XCTAssertTrue(qualified.hasPrefix("Video not counted"), "A qualified figure has no grade")
    XCTAssertFalse(qualified.contains("High energy use"))
    XCTAssertEqual(PerformanceEnergyReading(reading: EnergyReadout(status: .unavailable)).summary, "Unavailable on this Mac")
    XCTAssertEqual(PerformanceEnergyReading(reading: .measuring).summary, "Measuring…")
  }
}
