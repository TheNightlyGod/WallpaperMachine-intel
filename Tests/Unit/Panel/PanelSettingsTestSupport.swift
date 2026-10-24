import XCTest

@testable import WallpaperMachine

/// Fixtures of the settings suites: a bridge that records every engine setting the panel changes and
/// answers with the setting applied, and the panel's language pinned to English for the tests that
/// read wording.
@MainActor
final class SettingsRecordingBridge: LayoutSnapshotBridge {
  struct Profile: Equatable {
    var renderScale: Float
    var targetFps: UInt32
  }

  var batteryProfileCalls: [Profile] = []
  var sceneOptimizationCalls: [Bool] = []
  var sceneOnDemandCalls: [Bool] = []
  var sceneVideoPlaneSamplingCalls: [Bool] = []
  var sceneResolutionCalls: [String] = []
  var verboseLoggingCalls: [Bool] = []
  /// Counted off the main actor: the store reads these synchronously.
  let clearShaderCacheCalls = SettingsCallCounter()
  let clearLogsCalls = SettingsCallCounter()
  /// The folder the diagnostic logs are said to live in.
  var logFolder = ""

  /// Answers with the setting applied, the way the engine does: a double that returned the old value
  /// could not tell acceptance from a silently dropped change.
  private func answer(_ change: (inout BridgeSettingsSnapshot) -> Void) throws -> BridgeSnapshotBundle {
    guard var bundle = bundleProvider?() else { throw CancellationError() }
    change(&bundle.settings)
    return bundle
  }

  override func setBatteryQualityProfile(renderScale: Float, targetFps: UInt32) async throws
    -> BridgeSnapshotBundle
  {
    try await record({ $0.batteryProfileCalls.append(Profile(renderScale: renderScale, targetFps: targetFps)) }) {
      $0.batteryRenderScale = renderScale
      $0.batteryTargetFps = targetFps
    }
  }

  override func setSceneOptimizationEnabled(enabled: Bool) async throws -> BridgeSnapshotBundle {
    try await record({ $0.sceneOptimizationCalls.append(enabled) }) {
      $0.sceneOptimizationEnabled = enabled
    }
  }

  override func setSceneOnDemandEnabled(enabled: Bool) async throws -> BridgeSnapshotBundle {
    try await record({ $0.sceneOnDemandCalls.append(enabled) }) { $0.sceneOnDemandEnabled = enabled }
  }

  override func setSceneVideoPlaneSamplingEnabled(enabled: Bool) async throws
    -> BridgeSnapshotBundle
  {
    try await record({ $0.sceneVideoPlaneSamplingCalls.append(enabled) }) {
      $0.sceneVideoPlaneSamplingEnabled = enabled
    }
  }

  override func setSceneResolution(mode: String) async throws -> BridgeSnapshotBundle {
    try await record({ $0.sceneResolutionCalls.append(mode) }) { $0.sceneResolution = mode }
  }

  override func setVerboseLogging(enabled: Bool) async throws -> BridgeSnapshotBundle {
    try await record({ $0.verboseLoggingCalls.append(enabled) }) { $0.verboseLogging = enabled }
  }

  override func clearShaderCache() async throws -> BridgeSettingsSnapshot {
    clearShaderCacheCalls.bump()
    return try await MainActor.run {
      guard var bundle = bundleProvider?() else { throw CancellationError() }
      bundle.settings.storage.shaderCacheSizeBytes = 0
      return bundle.settings
    }
  }

  override func clearLogs() throws -> BridgeLogStatus {
    clearLogsCalls.bump()
    return BridgeLogStatus(logsRoot: "", activeSession: "", activeFile: "", activeFileSizeBytes: 0)
  }

  override func logFolderPath() throws -> String {
    MainActor.assumeIsolated { logFolder }
  }

  @MainActor private func record(
    _ note: (SettingsRecordingBridge) -> Void, _ change: (inout BridgeSettingsSnapshot) -> Void
  ) throws -> BridgeSnapshotBundle {
    note(self)
    return try answer(change)
  }
}

extension PanelTestCase {
  /// A panel whose engine is a `SettingsRecordingBridge` that answers with the store's own snapshots
  /// and whatever setting was just changed.
  func makeRecordingPanel(
    welcomeSeen: Bool = true, supportPrompt: SupportPromptStore? = nil
  ) throws -> (panel: PanelFixture, bridge: SettingsRecordingBridge) {
    let bridge = SettingsRecordingBridge(noPointer: .init())
    let store = BridgeStore(bridge: bridge, supportPrompt: supportPrompt)
    store.settingsSnapshot.displays = [
      BridgeDisplaySettingsRow(
        displayId: "primary", title: "Studio Display", enabled: true, mode: .standalone,
        mirrorTargets: [], selectedMirrorTarget: nil, scalingMode: .fill, scalingFactor: 1,
        targetFps: 30, maxFps: 60, muted: false, volume: 1)
    ]
    bridge.bundleProvider = { [store] in
      BridgeSnapshotBundle(
        app: store.appSnapshot, library: store.librarySnapshot, wallpaperOptions: nil,
        monitorInformation: store.monitorInformationSnapshot, settings: store.settingsSnapshot)
    }
    let panel = try PanelFixture(
      store: store, bridge: bridge, displayTitles: .renderer, welcomeSeen: welcomeSeen)
    return (panel, bridge)
  }

  /// `makeRecordingPanel`, started, handed to `body` and always shut down afterwards.
  func withRecordingPanel(
    welcomeSeen: Bool = true, supportPrompt: SupportPromptStore? = nil,
    _ body: (PanelFixture, SettingsRecordingBridge) async throws -> Void
  ) async throws {
    let (panel, bridge) = try makeRecordingPanel(welcomeSeen: welcomeSeen, supportPrompt: supportPrompt)
    do {
      try await panel.start()
      try await body(panel, bridge)
    } catch {
      await panel.shutdown()
      throw error
    }
    await panel.shutdown()
  }

  /// Pins the panel's language to English for the rest of this test, so wording assertions do not
  /// depend on the language the developer's Mac or the installed app uses.
  func pinPanelLanguageToEnglish() throws {
    let store = AppLanguageStore(
      defaults: try TemporaryDefaults.make(for: self).defaults, systemLanguages: ["en"])
    PanelLocale.shared.bind(to: store)
    addTeardownBlock { @MainActor in PanelLocale.shared.bind(to: .testHost) }
  }
}

/// A count a `@Sendable` closure can bump.
final class SettingsCallCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var calls = 0
  var count: Int { lock.withLock { calls } }
  func bump() { lock.withLock { calls += 1 } }
}

extension PanelFixture {
  /// A controller over this fixture's stores with a stand-in updater and/or energy monitor, which
  /// the fixture's own `buildController()` has no seam for. Not started.
  func buildSettingsController(
    updater: AppUpdateStore? = nil, energyUsage: EnergyUsageMonitor? = nil
  ) -> PanelController {
    PanelController(
      store: store, navigation: navigation, workshop: workshop, pixiv: pixiv, updater: updater,
      presentation: presentation, theme: theme, defaults: defaults, dialogs: dialogs,
      energyUsage: energyUsage, appLanguage: .english(),
      playback: PlaybackPreferences(defaults: defaults), playlists: playlists,
      hotKeys: HotKeyPreferences(defaults: defaults), collections: collections, presets: presets,
      backup: backup, imagePlacement: imagePlacement, compatibility: compatibility,
      automations: automations, spaces: spaces, systemConditions: systemConditions)
  }
}
