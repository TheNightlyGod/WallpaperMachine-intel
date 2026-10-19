import XCTest

@testable import WallpaperMachine

/// The inspector's General configuration and Displays cards: each setting is its own typed call that
/// reaches the bridge as it was asked, a value a control never offers is refused without a bridge
/// call, and the card's rows follow what the bridge answered.
@MainActor
final class PanelWallpaperSettingsTests: PanelTestCase {
  private func withSettings(_ body: (PanelFixture, SettingsBridge) async throws -> Void) async throws {
    let bridge = SettingsBridge(noPointer: .init())
    let store = BridgeStore(bridge: bridge)
    store.librarySnapshot.wallpapers = [
      BridgeWallpaperEntry(
        id: "wp", title: "wp", kind: .projectScene, supported: true, active: false, selected: true,
        previewPath: nil)
    ]
    store.appSnapshot.selectedWallpaperId = "wp"
    let options = BridgeSnapshotFixtures.options(
      wallpaperId: "wp", kind: .projectScene,
      displayConfigurations: [
        BridgeDisplayConfigRow(
          displayId: "primary", title: "Display (1 - Primary)", enabled: true, scalingMode: .fill,
          scalingFactor: 1, framing: .centered, targetFps: 30, maxFps: 60, muted: false, volume: 1,
          dirty: false, canRestoreDefaults: false),
        BridgeDisplayConfigRow(
          displayId: "slow", title: "Slow (2 - Secondary)", enabled: true, scalingMode: .fill,
          scalingFactor: 1, framing: .centered, targetFps: 30, maxFps: 0, muted: false, volume: 1,
          dirty: false, canRestoreDefaults: false),
      ])
    bridge.options["wp"] = options
    bridge.current = options
    store.wallpaperOptionsSnapshot = options
    bridge.store = store
    let panel = try PanelFixture(store: store, bridge: bridge, displayTitles: .renderer)
    do { try await body(panel, bridge) } catch {
      await panel.shutdown()
      throw error
    }
    await panel.shutdown()
  }

  func testEachSettingReachesTheBridgeAsItsOwnTypedCallAndTheCardFollowsTheAnswer() async throws {
    try await withSettings { panel, bridge in
      let controller = panel.controller
      try await controller.setVolume(0.4, for: "wp")
      try await controller.setMuted(true, for: "wp")
      try await controller.setAudioResponseEnabled(false, for: "wp")
      try await controller.setMediaIntegrationEnabled(false, for: "wp")
      try await controller.setDisplayEnabled(false, on: "primary", for: "wp")
      try await controller.setScalingMode(.match, on: "primary", for: "wp")
      try await controller.setScalingFactor(1.5, on: "primary", for: "wp")
      try await controller.setFrameRate(24, on: "primary", for: "wp")

      XCTAssertEqual(
        bridge.calls,
        [
          "volume wp 0.4", "muted wp true", "audioResponse wp false", "mediaIntegration wp false",
          "enabled wp primary false", "scalingMode wp primary match", "scalingFactor wp primary 1.5",
          "fps wp primary 24",
        ])
      let options = try XCTUnwrap(controller.inspectorOptions(for: "wp"))
      XCTAssertEqual(options.volume, Double(Float(0.4)))
      XCTAssertTrue(options.isMuted)
      XCTAssertFalse(options.audioResponseEnabled)
      XCTAssertFalse(options.mediaIntegrationEnabled)
      let display = try XCTUnwrap(options.displays.first)
      XCTAssertFalse(display.isEnabled)
      XCTAssertEqual(display.scalingMode, .match)
      XCTAssertEqual(display.scalingFactor, 1.5)
      XCTAssertEqual(display.frameRate, 24)
      XCTAssertTrue(options.isDirty, "the scale factor is a draft that waits for Apply changes")
      XCTAssertTrue(options.canApply)
    }
  }

  func testAValueNoControlOffersIsRefusedWithoutABridgeCall() async throws {
    try await withSettings { panel, bridge in
      let controller = panel.controller
      for volume in [-0.1, 1.1, Double.nan, Double.infinity] {
        await assertInspectorInvalidValue("a volume of \(volume)") {
          try await controller.setVolume(volume, for: "wp")
        }
      }
      for factor in [0, -1, Double.nan, Double.infinity, -Double.infinity] {
        await assertInspectorInvalidValue("a scale factor of \(factor)") {
          try await controller.setScalingFactor(factor, on: "primary", for: "wp")
        }
      }
      for fps in [0, -5, 61, 1000] {
        await assertInspectorInvalidValue("a frame rate of \(fps)") {
          try await controller.setFrameRate(fps, on: "primary", for: "wp")
        }
      }
      await assertInspectorInvalidValue("a frame rate above a display that reports no maximum") {
        try await controller.setFrameRate(2, on: "slow", for: "wp")
      }
      await assertInspectorInvalidValue("a frame rate for a display the wallpaper has no row for") {
        try await controller.setFrameRate(30, on: "gone", for: "wp")
      }
      XCTAssertTrue(bridge.calls.isEmpty, "a refusal reaches no bridge call")
      XCTAssertEqual(controller.errors.actionError, nil)

      // The edges are values like any other.
      try await controller.setVolume(0, for: "wp")
      try await controller.setVolume(1, for: "wp")
      try await controller.setFrameRate(60, on: "primary", for: "wp")
      try await controller.setFrameRate(1, on: "slow", for: "wp")
      try await controller.setScalingFactor(.leastNonzeroMagnitude, on: "primary", for: "wp")
      XCTAssertEqual(bridge.calls.count, 5)
    }
  }

  func testAnUnknownWallpaperIsRefusedByEverySetting() async throws {
    try await withSettings { panel, bridge in
      let controller = panel.controller
      let expected = "This wallpaper is no longer installed. Refresh your library."
      let attempts: [(String, () async throws -> Void)] = [
        ("volume", { try await controller.setVolume(0.5, for: "nope") }),
        ("muted", { try await controller.setMuted(true, for: "nope") }),
        ("audio", { try await controller.setAudioResponseEnabled(true, for: "nope") }),
        ("media", { try await controller.setMediaIntegrationEnabled(true, for: "nope") }),
        ("enabled", { try await controller.setDisplayEnabled(true, on: "primary", for: "nope") }),
        ("mode", { try await controller.setScalingMode(.fill, on: "primary", for: "nope") }),
        ("factor", { try await controller.setScalingFactor(1, on: "primary", for: "nope") }),
        ("fps", { try await controller.setFrameRate(30, on: "primary", for: "nope") }),
      ]
      for (name, attempt) in attempts {
        do {
          try await attempt()
          XCTFail("\(name) must be refused")
        } catch {
          XCTAssertEqual(error.localizedDescription, expected, name)
        }
      }
      XCTAssertTrue(bridge.calls.isEmpty)
    }
  }

  func testACaptureThatFailsRollsTheSavedAudioResponseBackByReadingEverythingAgain() async throws {
    try await withSettings { panel, bridge in
      bridge.audioResponseFailure = InspectorTestRefusal()
      let reads = bridge.snapshotReads
      do {
        try await panel.controller.setAudioResponseEnabled(true, for: "wp")
        XCTFail("the capture failure must reach the caller")
      } catch is InspectorTestRefusal {}
      XCTAssertGreaterThan(bridge.snapshotReads, reads, "the store re-reads every snapshot so the switch follows the engine")
    }
  }

  func testTheNewestValueOfASliderLandsLastWhenTheSendsAreChained() async throws {
    try await withSettings { panel, bridge in
      let controller = panel.controller
      let store = panel.store
      var release: CheckedContinuation<Void, Never>?
      let running = Task { @MainActor in
        await store.commands.run { await withCheckedContinuation { release = $0 } }
      }
      for _ in 0..<200 where release == nil { await Task.yield() }
      let key = InspectorAction.wallpaperSetting("wp", "volume")
      let tasks = [0.2, 0.5, 0.9].map { volume in
        controller.launch(key, policy: .latestWins) { try await controller.setVolume(volume, for: "wp") }
      }
      XCTAssertTrue(controller.isBusy(key))
      release?.resume()
      _ = await running.value
      for task in tasks { await task.value }
      XCTAssertEqual(bridge.calls, ["volume wp 0.2", "volume wp 0.5", "volume wp 0.9"])
      XCTAssertFalse(controller.isBusy(key))
    }
  }
}

/// A bridge that takes each setting the way the engine does and answers with the wallpaper's
/// options afterwards, and records what it was asked as a line of words.
private final class SettingsBridge: LayoutSnapshotBridge {
  @MainActor weak var store: BridgeStore?
  @MainActor var current: BridgeWallpaperOptionsSnapshot?
  @MainActor var calls: [String] = []
  @MainActor var audioResponseFailure: Error?

  override func wallpaperOptionsSnapshot(wallpaperId: String) async throws -> BridgeWallpaperOptionsSnapshot {
    try await read()
  }

  @MainActor private func read() throws -> BridgeWallpaperOptionsSnapshot {
    guard let current else { throw CancellationError() }
    return current
  }

  override func setVolume(wallpaperId: String, volume: Float) async throws -> BridgeWallpaperMutationBundle {
    try await change("volume \(wallpaperId) \(volume)") { $0.volume = volume }
  }
  override func setMuted(wallpaperId: String, muted: Bool) async throws -> BridgeWallpaperMutationBundle {
    try await change("muted \(wallpaperId) \(muted)") { $0.muted = muted }
  }
  override func setAudioResponseEnabled(wallpaperId: String, enabled: Bool) async throws
    -> BridgeWallpaperMutationBundle
  {
    try await change("audioResponse \(wallpaperId) \(enabled)", failure: audioResponseFailureNow) {
      $0.audioResponseEnabled = enabled
    }
  }
  override func setMediaIntegrationEnabled(wallpaperId: String, enabled: Bool) async throws
    -> BridgeWallpaperMutationBundle
  {
    try await change("mediaIntegration \(wallpaperId) \(enabled)") { $0.mediaIntegrationEnabled = enabled }
  }
  override func setDisplayConfigEnabled(wallpaperId: String, displayId: String, enabled: Bool) async throws
    -> BridgeWallpaperMutationBundle
  {
    try await change("enabled \(wallpaperId) \(displayId) \(enabled)") { options in
      Self.update(&options, displayId) { $0.enabled = enabled }
    }
  }
  override func setScalingMode(wallpaperId: String, displayId: String, mode: BridgeScalingMode) async throws
    -> BridgeWallpaperMutationBundle
  {
    try await change("scalingMode \(wallpaperId) \(displayId) \(mode.word)") { options in
      Self.update(&options, displayId) { $0.scalingMode = mode }
    }
  }
  override func editScalingFactor(wallpaperId: String, displayId: String, factor: Double) async throws
    -> BridgeWallpaperMutationBundle
  {
    try await change("scalingFactor \(wallpaperId) \(displayId) \(factor)", dirty: true) { options in
      Self.update(&options, displayId) { $0.scalingFactor = factor }
    }
  }
  override func setTargetFps(wallpaperId: String, displayId: String, fps: UInt32) async throws
    -> BridgeWallpaperMutationBundle
  {
    try await change("fps \(wallpaperId) \(displayId) \(fps)") { options in
      Self.update(&options, displayId) { $0.targetFps = fps }
    }
  }

  @MainActor private var audioResponseFailureNow: Error? { audioResponseFailure }

  @MainActor private func change(
    _ call: String, failure: Error? = nil, dirty: Bool = false,
    _ edit: (inout BridgeWallpaperOptionsSnapshot) -> Void
  ) throws -> BridgeWallpaperMutationBundle {
    calls.append(call)
    if let failure { throw failure }
    guard var options = current, let store else { throw CancellationError() }
    edit(&options)
    if dirty { options.dirty = true }
    current = options
    return BridgeWallpaperMutationBundle(
      app: store.appSnapshot, library: store.librarySnapshot, wallpaperOptions: options,
      monitorInformation: store.monitorInformationSnapshot, settings: store.settingsSnapshot)
  }

  private static func update(
    _ options: inout BridgeWallpaperOptionsSnapshot, _ display: String,
    _ edit: (inout BridgeDisplayConfigRow) -> Void
  ) {
    options.displayConfigurations = options.displayConfigurations.map { row in
      guard row.displayId == display else { return row }
      var row = row
      edit(&row)
      return row
    }
  }
}

extension BridgeScalingMode {
  fileprivate var word: String {
    switch self {
    case .none: "none"
    case .stretch: "stretch"
    case .match: "match"
    case .fill: "fill"
    }
  }
}
