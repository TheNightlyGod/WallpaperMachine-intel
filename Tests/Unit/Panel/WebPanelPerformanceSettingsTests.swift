import XCTest

@testable import WallpaperMachine

/// Covers the validation the panel performs on quality settings before they reach
/// the engine, and the snapshot keys the settings page reads back.
@MainActor
final class WebPanelPerformanceSettingsTests: XCTestCase {
  func testRenderScaleFromAStalePageIsClampedToTheSupportedRange() async throws {
    let context = try Context()
    defer { context.tearDown() }

    try await context.controller.perform("setting", body: ["key": "renderScale", "value": 5.0])
    try await context.controller.perform("setting", body: ["key": "renderScale", "value": 0.01])

    XCTAssertEqual(
      context.bridge.renderScales, [1, 0.25],
      "A scale outside 0.25...1 must reach the engine clamped, not refused or passed through")
  }

  func testNonNumericRenderScaleIsRefused() async {
    guard let context = try? Context() else { return XCTFail("fixture") }
    defer { context.tearDown() }

    do {
      try await context.controller.perform("setting", body: ["key": "renderScale", "value": "0.5"])
      XCTFail("A string render scale must not be accepted")
    } catch {}
    XCTAssertTrue(context.bridge.renderScales.isEmpty)
  }

  func testDesktopCoveredActionIsSavedAndAnUnknownValueRefused() async throws {
    let context = try Context()
    defer { context.tearDown() }

    try await context.controller.perform(
      "setting", body: ["key": "desktopCoveredAction", "value": "keepRunning"])
    XCTAssertEqual(context.playback.desktopCoveredAction, .keepRunning)

    do {
      try await context.controller.perform(
        "setting", body: ["key": "desktopCoveredAction", "value": "sometimes"])
      XCTFail("An unrecognised choice must not be applied")
    } catch {}
    XCTAssertEqual(context.playback.desktopCoveredAction, .keepRunning)
  }

  func testLowBatteryActionIsSavedAndAnUnknownValueRefused() async throws {
    let context = try Context()
    defer { context.tearDown() }

    try await context.controller.perform(
      "setting", body: ["key": "lowBatteryAction", "value": "stop"])
    XCTAssertEqual(context.playback.lowBatteryAction, .stop)

    for bad: Any in ["sometimes", "mute", 1, true] {
      do {
        try await context.controller.perform(
          "setting", body: ["key": "lowBatteryAction", "value": bad])
        XCTFail("\(bad) is not a low-battery action")
      } catch {}
    }
    XCTAssertEqual(context.playback.lowBatteryAction, .stop, "A refused value leaves the saved one alone")
  }

  func testLowBatteryLevelAcceptsOnlyTheOfferedLevels() async throws {
    let context = try Context()
    defer { context.tearDown() }

    for level in [10, 30, 20] {
      try await context.controller.perform(
        "setting", body: ["key": "lowBatteryThreshold", "value": level])
      XCTAssertEqual(context.playback.lowBatteryThreshold, level)
    }
    context.playback.lowBatteryThreshold = 10
    for bad: Any in [15, 9, 31, 20.5, "20", true, NSNull()] {
      do {
        try await context.controller.perform(
          "setting", body: ["key": "lowBatteryThreshold", "value": bad])
        XCTFail("\(bad) is not an offered low-battery level")
      } catch {}
    }
    XCTAssertEqual(context.playback.lowBatteryThreshold, 10, "Refused levels leave the saved one alone")
  }

  func testPlayOnlyOnTheActiveDisplayAcceptsABooleanAndRefusesAnythingElse() async throws {
    let context = try Context()
    defer { context.tearDown() }

    try await context.controller.perform(
      "setting", body: ["key": "playOnlyOnActiveDisplay", "value": true])
    XCTAssertTrue(context.playback.playsOnlyOnActiveDisplay)

    for bad: Any in ["true", "on", 1, NSNull()] {
      do {
        try await context.controller.perform(
          "setting", body: ["key": "playOnlyOnActiveDisplay", "value": bad])
        XCTFail("\(bad) is not a boolean")
      } catch {}
    }
    XCTAssertTrue(context.playback.playsOnlyOnActiveDisplay, "A refused value leaves the saved one alone")

    let settings = try XCTUnwrap(context.controller.snapshot()["settings"] as? [String: Any])
    XCTAssertEqual(settings["playOnlyOnActiveDisplay"] as? Bool, true)

    try await context.controller.perform(
      "setting", body: ["key": "playOnlyOnActiveDisplay", "value": false])
    XCTAssertFalse(context.playback.playsOnlyOnActiveDisplay)
    let after = try XCTUnwrap(context.controller.snapshot()["settings"] as? [String: Any])
    XCTAssertEqual(after["playOnlyOnActiveDisplay"] as? Bool, false)
  }

  /// The stored name of the new choice is one letter away from the battery mode's, so a swap of
  /// the two must fail here and not in someone's saved settings.
  func testReducedQualityIsAcceptedForTheThreeConditionsAndRefusedElsewhere() async throws {
    let context = try Context()
    defer { context.tearDown() }

    for key in ["lowPowerModeAction", "thermalAction", "lowBatteryAction"] {
      try await context.controller.perform("setting", body: ["key": key, "value": "reduceQuality"])
    }
    XCTAssertEqual(context.playback.lowPowerModeAction, .reduceQuality)
    XCTAssertEqual(context.playback.thermalAction, .reduceQuality)
    XCTAssertEqual(context.playback.lowBatteryAction, .reduceQuality)

    // The battery mode's own name is not a condition choice.
    for key in ["lowPowerModeAction", "thermalAction", "lowBatteryAction"] {
      do {
        try await context.controller.perform("setting", body: ["key": key, "value": "reducedQuality"])
        XCTFail("\(key) must not accept the battery mode's name")
      } catch {}
    }
    // The condition choice is not a battery mode or a choice for any other rule.
    for key in ["batteryMode", "displaySleepAction", "otherAudioAction", "desktopCoveredAction"] {
      do {
        try await context.controller.perform("setting", body: ["key": key, "value": "reduceQuality"])
        XCTFail("\(key) has no reduced-quality choice")
      } catch {}
    }
    XCTAssertEqual(context.playback.lowPowerModeAction, .reduceQuality)
    XCTAssertEqual(context.playback.thermalAction, .reduceQuality)
    XCTAssertEqual(context.playback.lowBatteryAction, .reduceQuality)
    XCTAssertEqual(context.playback.displaySleepAction, .pause, "A refused value leaves the saved one alone")
    XCTAssertTrue(context.bridge.batteryModes.isEmpty)
  }

  func testSnapshotPublishesTheEffectiveCeilingAndTheThrottleCauses() throws {
    let context = try Context()
    defer { context.tearDown() }
    context.store.settingsSnapshot.frameRateCap = 45
    context.store.settingsSnapshot.effectiveFrameRateCap = 24
    context.store.settingsSnapshot.qualityThrottle = [.heat, .lowPowerMode]

    let throttled = try XCTUnwrap(context.controller.snapshot()["settings"] as? [String: Any])

    XCTAssertEqual(throttled["effectiveFrameRateCap"] as? Int, 24)
    XCTAssertEqual(throttled["qualityThrottle"] as? [String], ["heat", "lowPowerMode"])
    XCTAssertEqual(throttled["frameRateCap"] as? Int, 45, "The saved cap stays the saved cap")

    context.store.settingsSnapshot.effectiveFrameRateCap = nil
    context.store.settingsSnapshot.qualityThrottle = [.lowBattery]
    let lowBattery = try XCTUnwrap(context.controller.snapshot()["settings"] as? [String: Any])
    XCTAssertEqual(lowBattery["qualityThrottle"] as? [String], ["lowBattery"])

    context.store.settingsSnapshot.frameRateCap = nil
    context.store.settingsSnapshot.qualityThrottle = []
    let free = try XCTUnwrap(context.controller.snapshot()["settings"] as? [String: Any])
    XCTAssertTrue(free["effectiveFrameRateCap"] is NSNull, "No ceiling is null, not zero")
    XCTAssertEqual((free["qualityThrottle"] as? [String])?.isEmpty, true)
  }

  func testSnapshotPublishesTheLowBatteryChoicesAndAChargeOnlyWhenThereIsABattery() throws {
    let context = try Context()
    defer { context.tearDown() }
    context.playback.lowBatteryAction = .pause
    context.playback.lowBatteryThreshold = 30

    let settings = try XCTUnwrap(context.controller.snapshot()["settings"] as? [String: Any])

    XCTAssertEqual(settings["lowBatteryAction"] as? String, "pause")
    XCTAssertEqual(settings["lowBatteryThreshold"] as? Int, 30)
    // Whether this Mac has a battery is the Mac's business; the page needs the key either way,
    // and a charge it can show or null that hides the rows.
    let charge = try XCTUnwrap(settings["batteryPercent"], "The key must always be present")
    if !(charge is NSNull) {
      XCTAssertTrue((0...100).contains(try XCTUnwrap(charge as? Int)))
    }
  }

  func testUnknownVideoBackendIsRefusedInsteadOfSilentlyDefaulting() async throws {
    let context = try Context()
    defer { context.tearDown() }

    do {
      try await context.controller.perform("setting", body: ["key": "videoBackend", "value": "native"])
      XCTFail("An unrecognised backend name must not be applied")
    } catch {}
    XCTAssertTrue(
      context.bridge.videoBackends.isEmpty,
      "A rejected backend must not fall back to Compatibility behind the user's back")

    try await context.controller.perform(
      "setting", body: ["key": "videoBackend", "value": "native_preferred"])
    XCTAssertEqual(context.bridge.videoBackends, ["native_preferred"])
  }

  func testBatteryFrameRateIsClampedAndTheUnchangedScaleIsKept() async throws {
    let context = try Context()
    defer { context.tearDown() }
    context.store.settingsSnapshot.batteryRenderScale = 0.5
    context.store.settingsSnapshot.batteryTargetFps = 30

    try await context.controller.perform("setting", body: ["key": "batteryTargetFps", "value": 1000])

    let profile = try XCTUnwrap(context.bridge.batteryProfiles.first)
    XCTAssertEqual(profile.targetFps, 240, "Frame rate must be clamped to 1...240")
    XCTAssertEqual(profile.renderScale, 0.5, "Changing one field must not reset the other")
  }

  func testBatteryModeRoundTripsAndAnUnknownValueIsRefused() async throws {
    let context = try Context()
    defer { context.tearDown() }

    do {
      try await context.controller.perform("setting", body: ["key": "batteryMode", "value": "sometimes"])
      XCTFail("An unknown battery mode must be refused")
    } catch {}
    XCTAssertTrue(context.bridge.batteryModes.isEmpty)

    try await context.controller.perform("setting", body: ["key": "batteryMode", "value": "pause"])
    XCTAssertEqual(context.bridge.batteryModes, [.pause])
  }

  func testFrameRateCapClampsANumberAndTreatsNullAsNoLimit() async throws {
    let context = try Context()
    defer { context.tearDown() }

    try await context.controller.perform("setting", body: ["key": "frameRateCap", "value": 0])
    try await context.controller.perform("setting", body: ["key": "frameRateCap", "value": 300])
    try await context.controller.perform("setting", body: ["key": "frameRateCap", "value": NSNull()])

    XCTAssertEqual(context.bridge.frameRateCaps.count, 3)
    XCTAssertEqual(context.bridge.frameRateCaps[0], 1)
    XCTAssertEqual(context.bridge.frameRateCaps[1], 240)
    XCTAssertNil(context.bridge.frameRateCaps[2])
  }

  func testQualityPresetAppliesRenderScaleAndFrameRateCapTogether() async throws {
    let context = try Context()
    defer { context.tearDown() }

    try await context.controller.perform("setting", body: ["key": "qualityPreset", "value": "low"])
    XCTAssertEqual(context.bridge.renderScales, [0.5])
    XCTAssertEqual(context.bridge.frameRateCaps, [30])

    try await context.controller.perform("setting", body: ["key": "qualityPreset", "value": "high"])
    XCTAssertEqual(context.bridge.renderScales, [0.5, 1])
    XCTAssertEqual(context.bridge.frameRateCaps.count, 2)
    XCTAssertNil(context.bridge.frameRateCaps[1], "High is the default: no frame-rate limit")

    do {
      try await context.controller.perform("setting", body: ["key": "qualityPreset", "value": "ultra"])
      XCTFail("An unknown preset must be refused")
    } catch {}
    XCTAssertEqual(context.bridge.renderScales.count, 2, "A refused preset must not apply a scale")
  }

  func testAppRuleAddUpdateAndRemoveRoundTripAndAnUnknownIdIsRefused() async throws {
    let context = try Context()
    defer { context.tearDown() }
    let app = context.root.appendingPathComponent("Sample.app")
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    try """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
    <key>CFBundleIdentifier</key><string>com.example.sample</string>
    <key>CFBundleName</key><string>Sample</string>
    </dict></plist>
    """.write(to: app.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
    context.controller.chooseApplication = { app }

    try await context.controller.perform("appRuleAdd", body: [:])
    let added = try XCTUnwrap(context.playback.appRules.first)
    XCTAssertEqual(added.bundleIdentifier, "com.example.sample")
    XCTAssertFalse(added.name.isEmpty)
    XCTAssertEqual(added.condition, .running)
    XCTAssertEqual(added.action, .pause)

    try await context.controller.perform(
      "appRuleUpdate", body: ["id": added.id.uuidString, "key": "condition", "value": "frontmost"])
    try await context.controller.perform(
      "appRuleUpdate", body: ["id": added.id.uuidString, "key": "action", "value": "mute"])
    XCTAssertEqual(context.playback.appRules.first?.condition, .frontmost)
    XCTAssertEqual(context.playback.appRules.first?.action, .mute)

    do {
      try await context.controller.perform(
        "appRuleUpdate", body: ["id": UUID().uuidString, "key": "action", "value": "stop"])
      XCTFail("An unknown rule id must be refused")
    } catch {}
    XCTAssertEqual(context.playback.appRules.count, 1)

    try await context.controller.perform("appRuleRemove", body: ["id": added.id.uuidString])
    XCTAssertTrue(context.playback.appRules.isEmpty)
  }

  func testSceneOptimizationDefaultsOnAndRoundTripsThroughTheEngine() async throws {
    let context = try Context()
    defer { context.tearDown() }
    context.store.settingsSnapshot = BridgeSnapshotFixtures.settings()

    let shipped = try XCTUnwrap(context.controller.snapshot()["settings"] as? [String: Any])
    XCTAssertEqual(
      shipped["sceneOptimization"] as? Bool, true,
      "Scene optimisation ships on; a page that renders it off would invert the default")

    try await context.controller.perform(
      "setting", body: ["key": "sceneOptimization", "value": false])

    XCTAssertEqual(context.bridge.sceneOptimization, [false])
    let off = try XCTUnwrap(context.controller.snapshot()["settings"] as? [String: Any])
    XCTAssertEqual(
      off["sceneOptimization"] as? Bool, false,
      "The page must re-render from the snapshot the engine returned, not from the click")

    try await context.controller.perform(
      "setting", body: ["key": "sceneOptimization", "value": true])

    XCTAssertEqual(context.bridge.sceneOptimization, [false, true])
    let on = try XCTUnwrap(context.controller.snapshot()["settings"] as? [String: Any])
    XCTAssertEqual(on["sceneOptimization"] as? Bool, true)
  }

  func testNonBooleanSceneOptimizationValueIsRefused() async throws {
    let context = try Context()
    defer { context.tearDown() }

    do {
      try await context.controller.perform(
        "setting", body: ["key": "sceneOptimization", "value": 1])
      XCTFail("A numeric value must not be accepted for a switch")
    } catch {}
    XCTAssertTrue(context.bridge.sceneOptimization.isEmpty)
  }

  func testDirectVideoPlaneSamplingDefaultsOffAndRoundTripsThroughTheEngine() async throws {
    let context = try Context()
    defer { context.tearDown() }
    context.store.settingsSnapshot = BridgeSnapshotFixtures.settings()

    let shipped = try XCTUnwrap(context.controller.snapshot()["settings"] as? [String: Any])
    XCTAssertEqual(
      shipped["sceneVideoPlaneSampling"] as? Bool, false,
      "A sampling path whose equivalence is bounded rather than total ships off")

    try await context.controller.perform(
      "setting", body: ["key": "sceneVideoPlaneSampling", "value": true])

    XCTAssertEqual(context.bridge.sceneVideoPlaneSampling, [true])
    let on = try XCTUnwrap(context.controller.snapshot()["settings"] as? [String: Any])
    XCTAssertEqual(
      on["sceneVideoPlaneSampling"] as? Bool, true,
      "The page must re-render from the snapshot the engine returned, not from the click")
  }

  func testNonBooleanVideoPlaneSamplingValueIsRefused() async throws {
    let context = try Context()
    defer { context.tearDown() }

    do {
      try await context.controller.perform(
        "setting", body: ["key": "sceneVideoPlaneSampling", "value": "on"])
      XCTFail("A string value must not be accepted for a switch")
    } catch {}
    XCTAssertTrue(context.bridge.sceneVideoPlaneSampling.isEmpty)
  }

  func testSnapshotPublishesPerformanceSettingsUnderTheDocumentedKeys() throws {
    let context = try Context()
    defer { context.tearDown() }
    context.store.settingsSnapshot.videoBackend = "native_preferred"
    context.store.settingsSnapshot.videoBackends = [
      BridgeVideoBackendReport(
        displayId: 2, displayName: "Display 2", wallpaperId: "beach", wallpaperTitle: "Beach",
        backend: "legacy", fallbackReason: "29.97 fps is below the 30 fps target")
    ]
    context.store.settingsSnapshot.contentPacingEnabled = true
    context.store.settingsSnapshot.sharedVideoDecodeEnabled = true
    context.store.settingsSnapshot.sharedVideoDecodeSessions = 1
    context.store.settingsSnapshot.sharedVideoDecodeConsumers = 3
    context.store.settingsSnapshot.renderScale = 0.75
    context.store.settingsSnapshot.preferredRenderScale = 1
    context.store.settingsSnapshot.renderScaleSupported = true
    context.store.settingsSnapshot.batteryMode = .reducedQuality
    context.store.settingsSnapshot.batteryRenderScale = 0.75
    context.store.settingsSnapshot.batteryTargetFps = 30
    context.store.settingsSnapshot.onBatteryPower = true
    context.store.settingsSnapshot.frameRateCap = 45
    context.playback.displaySleepAction = .stop
    context.playback.otherAudioAction = .mute
    context.playback.desktopCoveredAction = .keepRunning
    _ = context.playback.addRule(bundleIdentifier: "com.example.sample", name: "Sample")

    let settings = try XCTUnwrap(context.controller.snapshot()["settings"] as? [String: Any])

    XCTAssertEqual(settings["videoBackend"] as? String, "native_preferred")
    XCTAssertEqual(settings["contentPacing"] as? Bool, true)
    XCTAssertEqual(settings["sharedVideoDecode"] as? Bool, true)
    XCTAssertEqual(settings["sharedVideoDecodeSessions"] as? Int, 1)
    XCTAssertEqual(settings["sharedVideoDecodeConsumers"] as? Int, 3)
    XCTAssertEqual(settings["renderScale"] as? Double, 0.75)
    XCTAssertEqual(settings["preferredRenderScale"] as? Double, 1)
    XCTAssertEqual(settings["renderScaleSupported"] as? Bool, true)
    XCTAssertEqual(settings["batteryMode"] as? String, "reducedQuality")
    XCTAssertEqual(settings["batteryRenderScale"] as? Double, 0.75)
    XCTAssertEqual(settings["batteryTargetFps"] as? Int, 30)
    XCTAssertEqual(settings["onBatteryPower"] as? Bool, true)
    XCTAssertEqual(settings["frameRateCap"] as? Int, 45)
    XCTAssertEqual(settings["frameRateCapMax"] as? Int, 60)
    XCTAssertEqual(settings["displaySleepAction"] as? String, "stop")
    XCTAssertEqual(settings["otherAudioAction"] as? String, "mute")
    XCTAssertEqual(settings["desktopCoveredAction"] as? String, "keepRunning")
    let rules = try XCTUnwrap(settings["appRules"] as? [[String: Any]])
    XCTAssertEqual(rules.count, 1)
    XCTAssertEqual(rules[0]["name"] as? String, "Sample")
    XCTAssertEqual(rules[0]["bundleID"] as? String, "com.example.sample")
    XCTAssertEqual(rules[0]["condition"] as? String, "running")
    XCTAssertEqual(rules[0]["action"] as? String, "pause")

    let reports = try XCTUnwrap(settings["videoBackends"] as? [[String: Any]])
    XCTAssertEqual(reports.count, 1)
    XCTAssertEqual(reports[0]["displayId"] as? Int, 2)
    XCTAssertEqual(reports[0]["displayName"] as? String, "Display 2")
    XCTAssertEqual(reports[0]["wallpaperId"] as? String, "beach")
    XCTAssertEqual(reports[0]["wallpaperTitle"] as? String, "Beach")
    XCTAssertEqual(reports[0]["backend"] as? String, "legacy")
    XCTAssertEqual(
      reports[0]["fallbackReason"] as? String, "29.97 fps is below the 30 fps target")

    context.store.settingsSnapshot.videoBackends = []
    let empty = try XCTUnwrap(context.controller.snapshot()["settings"] as? [String: Any])
    XCTAssertEqual((empty["videoBackends"] as? [[String: Any]])?.isEmpty, true)
  }

  @MainActor
  private final class Context {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "panel-performance-\(UUID().uuidString)")
    let bridge = RecordingBridge(noPointer: .init())
    let store: BridgeStore
    let defaults: UserDefaults
    let workshop: WorkshopStore
    let controller: WebPanelController
    let playback: PlaybackPreferences

    init() throws {
      store = BridgeStore(bridge: bridge)
      defaults = TemporaryDefaults.makeForCurrentTest().defaults
      workshop = WorkshopStore(
        downloader: WorkshopDownloadManager(sessionDirectory: root), supportDirectory: root,
        defaults: defaults)
      playback = PlaybackPreferences(defaults: defaults)
      controller = WebPanelController(
        store: store, navigation: ControlPanelNavigation(), workshop: workshop, defaults: defaults,
        appLanguage: .english(), playback: playback)
      bridge.snapshots = { [store] in
        BridgeSnapshotBundle(
          app: store.appSnapshot, library: store.librarySnapshot, wallpaperOptions: nil,
          monitorInformation: store.monitorInformationSnapshot, settings: store.settingsSnapshot)
      }
    }

    func tearDown() {
      controller.stop()
      try? FileManager.default.removeItem(at: root)
    }
  }
}

private final class RecordingBridge: WallpaperBridge {
  struct Profile {
    let renderScale: Float
    let targetFps: UInt32
  }

  @MainActor var snapshots: (() -> BridgeSnapshotBundle)?
  @MainActor var renderScales: [Float] = []
  @MainActor var videoBackends: [String] = []
  @MainActor var batteryProfiles: [Profile] = []
  @MainActor var batteryModes: [BridgeBatteryMode] = []
  @MainActor var frameRateCaps: [UInt32?] = []
  @MainActor var sceneOptimization: [Bool] = []
  @MainActor var sceneVideoPlaneSampling: [Bool] = []

  override func setRenderScale(scale: Float) async throws -> BridgeSnapshotBundle {
    await record { $0.renderScales.append(scale) }
  }

  override func setVideoBackend(mode: String) async throws -> BridgeSnapshotBundle {
    await record { $0.videoBackends.append(mode) }
  }

  /// Returns the setting applied, the way the engine does: the page re-renders from
  /// this, so a test that returned the old value could not tell acceptance from a
  /// silently dropped click.
  override func setSceneOptimizationEnabled(enabled: Bool) async throws -> BridgeSnapshotBundle {
    var bundle = await record { $0.sceneOptimization.append(enabled) }
    bundle.settings.sceneOptimizationEnabled = enabled
    return bundle
  }

  override func setSceneVideoPlaneSamplingEnabled(enabled: Bool) async throws
    -> BridgeSnapshotBundle
  {
    var bundle = await record { $0.sceneVideoPlaneSampling.append(enabled) }
    bundle.settings.sceneVideoPlaneSamplingEnabled = enabled
    return bundle
  }

  override func setBatteryQualityProfile(renderScale: Float, targetFps: UInt32) async throws
    -> BridgeSnapshotBundle
  {
    await record {
      $0.batteryProfiles.append(Profile(renderScale: renderScale, targetFps: targetFps))
    }
  }

  override func setBatteryMode(mode: BridgeBatteryMode) async throws -> BridgeSnapshotBundle {
    await record { $0.batteryModes.append(mode) }
  }

  override func setFrameRateCap(cap: UInt32?) async throws -> BridgeSnapshotBundle {
    await record { $0.frameRateCaps.append(cap) }
  }

  @MainActor private func record(_ note: @MainActor (RecordingBridge) -> Void)
    -> BridgeSnapshotBundle
  {
    note(self)
    guard let snapshots else { fatalError("The fixture must publish a snapshot") }
    return snapshots()
  }
}
