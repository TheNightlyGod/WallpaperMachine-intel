import XCTest

@testable import WallpaperMachine

/// Energy sampling reads every coalition on the Mac, so it must run only while its
/// readout can be seen: panel visible, Settings open.
@MainActor
final class WebPanelEnergyUsageTests: XCTestCase {
  func testSamplingRunsOnlyWhileSettingsIsVisible() async throws {
    let context = try Context()
    defer { context.tearDown() }
    let controller = context.controller
    let monitor = controller.energyUsage

    controller.scheduleUpdate()
    XCTAssertFalse(monitor.isActive, "Installed is on show, not Settings")

    try await controller.perform("navigate", body: ["page": "settings"])
    controller.scheduleUpdate()
    XCTAssertTrue(monitor.isActive)

    context.visible = false
    controller.scheduleUpdate()
    XCTAssertFalse(monitor.isActive, "a hidden, minimised or covered panel stops sampling")

    context.visible = true
    controller.scheduleUpdate()
    XCTAssertTrue(monitor.isActive)

    try await controller.perform("navigate", body: ["page": "installed"])
    controller.scheduleUpdate()
    XCTAssertFalse(monitor.isActive, "leaving Settings stops sampling")

    try await controller.perform("navigate", body: ["page": "settings"])
    controller.scheduleUpdate()
    controller.stop()
    XCTAssertFalse(monitor.isActive)
  }

  /// What to do in Low Power Mode, when the Mac is hot and when the battery is low can choose
  /// Reduced quality, which lowers the frame rate and render scale the moment its condition
  /// holds, so each is a Performance setting that changes how much work runs.
  func testChoosingWhatAConditionDoesRestartsTheEnergyComparisonLikeTheOtherQualitySettings()
    async throws
  {
    let context = try Context()
    defer { context.tearDown() }
    let controller = context.controller
    let monitor = controller.energyUsage
    try await controller.perform("navigate", body: ["page": "settings"])
    controller.scheduleUpdate()
    XCTAssertTrue(monitor.isActive)
    // Nothing else makes the monitor report a change within a test: its own samples come an
    // hour apart, and a restart is the one thing that reports at once.
    var restarts = 0
    monitor.onChange = { restarts += 1 }

    for key in ["lowPowerModeAction", "thermalAction", "lowBatteryAction"] {
      let before = restarts
      try await controller.perform("setting", body: ["key": key, "value": "reduceQuality"])
      XCTAssertEqual(restarts, before + 1, "\(key) restarts the window, as the battery mode does")
    }

    let before = restarts
    try await controller.perform("setting", body: ["key": "hideAfterActivating", "value": true])
    XCTAssertEqual(restarts, before, "a setting that changes no rendering work leaves the window alone")
  }

  @MainActor
  private final class Context {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "panel-energy-\(UUID().uuidString)")
    let navigation = ControlPanelNavigation()
    let defaults: UserDefaults
    let controller: WebPanelController
    var visible = true

    init() throws {
      defaults = TemporaryDefaults.makeForCurrentTest().defaults
      let workshop = WorkshopStore(
        downloader: WorkshopDownloadManager(sessionDirectory: root), supportDirectory: root,
        defaults: defaults)
      var isVisible: () -> Bool = { true }
      controller = WebPanelController(
        store: BridgeStore(bridge: LayoutSnapshotBridge(noPointer: .init())),
        navigation: navigation, workshop: workshop,
        isPresentationVisible: { isVisible() }, defaults: defaults,
        energyUsage: EnergyUsageMonitor(source: IdleSource(), interval: .seconds(3600)),
        appLanguage: .english())
      isVisible = { [unowned self] in self.visible }
      // A page that has loaded reports ready before anything else.
      controller.isReady = true
    }

    func tearDown() {
      controller.stop()
      try? FileManager.default.removeItem(at: root)
    }
  }
}

private struct IdleSource: EnergyUsageSource {
  func sample() -> EnergyUsageSample? {
    EnergyUsageSample(uptimeNanoseconds: 0, own: [:], otherGPUTime: [:])
  }
}
