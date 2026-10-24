import Foundation

@testable import WallpaperMachine

extension BridgeFraming {
  /// The layout every wallpaper has until it is moved.
  static let centered = BridgeFraming(panX: 0.5, panY: 0.5)
}

/// Snapshot values for tests that need a settings snapshot but do not care what
/// is in it.
///
/// The bridge snapshot is a flat record with no defaults, so every test that
/// builds one has to name every field. Centralising that here means adding a
/// setting touches this file instead of every unrelated test, and it keeps those
/// tests describing what they actually assert rather than restating the whole
/// record.
enum BridgeSnapshotFixtures {
  static func storage() -> BridgeStorageStatus {
    BridgeStorageStatus(
      shaderCacheSizeBytes: 0,
      logs: BridgeLogStatus(
        logsRoot: "", activeSession: "", activeFile: "", activeFileSizeBytes: 0))
  }

  /// A wallpaper options snapshot carrying shipped defaults: audio response and
  /// media integration on, unmuted at full volume. Tests that care about one of
  /// those pass it explicitly.
  static func options(
    wallpaperId: String = "wallpaper",
    title: String = "Wallpaper",
    kind: BridgeWallpaperKind = .projectScene,
    supported: Bool = true,
    dirty: Bool = false,
    properties: [BridgePropertyDescriptor] = [],
    displayConfigurations: [BridgeDisplayConfigRow] = [],
    audioResponseEnabled: Bool = true,
    mediaIntegrationEnabled: Bool = true,
    muted: Bool = false,
    volume: Float = 1
  ) -> BridgeWallpaperOptionsSnapshot {
    BridgeWallpaperOptionsSnapshot(
      wallpaperId: wallpaperId,
      title: title,
      kind: kind,
      supported: supported,
      dirty: dirty,
      properties: properties,
      displayConfigurations: displayConfigurations,
      audioResponseEnabled: audioResponseEnabled,
      mediaIntegrationEnabled: mediaIntegrationEnabled,
      muted: muted,
      volume: volume)
  }

  /// A bare text property whose label is `labelHtml`, for tests about what the label says.
  static func textProperty(id: String, labelHtml: String) -> BridgePropertyDescriptor {
    BridgePropertyDescriptor(
      id: id, kind: .text, labelHtml: labelHtml, value: .empty, defaultValue: .empty, slider: nil,
      comboOptions: [], fileFilter: nil, directoryMode: nil, dirty: false,
      canRestoreDefaults: false, enabled: true, assetManaged: false, assetMissing: false,
      assetSourcePath: nil)
  }

  /// A settings snapshot carrying shipped defaults: full
  /// render scale, keep-running on battery, no frame-rate cap, both experiments
  /// off, scene optimisation on and 2D scenes drawn at the display's resolution. Tests that care about one of those pass it
  /// explicitly.
  static func settings(
    displays: [BridgeDisplaySettingsRow] = [],
    batteryMode: BridgeBatteryMode = .keepRunning,
    videoBackends: [BridgeVideoBackendReport] = [],
    sceneOptimizationEnabled: Bool = true,
    sceneOnDemandEnabled: Bool = false,
    sceneVideoPlaneSamplingEnabled: Bool = false,
    sceneResolution: String = "display",
    sceneUpdateModes: [BridgeSceneUpdateModeReport] = [],
    sceneRenderers: [BridgeSceneBackendReport] = [],
    userAssetsPath: String = "/tmp/UserAssets",
    renderScale: Float = 1,
    preferredRenderScale: Float = 1,
    frameRateCap: UInt32? = nil,
    batteryRenderScale: Float = 0.75,
    batteryTargetFps: UInt32 = 30,
    onBatteryPower: Bool = false,
    qualityThrottle: [BridgeQualityThrottleCause] = [],
    effectiveFrameRateCap: UInt32? = nil,
    renderScaleSupported: Bool = true
  ) -> BridgeSettingsSnapshot {
    BridgeSettingsSnapshot(
      displays: displays,
      launchAtLoginAvailable: false,
      launchAtLoginEnabled: false,
      launchAtLoginNeedsApproval: false,
      batteryMode: batteryMode,
      verboseLogging: false,
      gitSha: "",
      bridgeVersion: "",
      coreVersion: "",
      shaderPipelineVersion: "",
      storage: storage(),
      videoBackends: videoBackends,
      sceneOptimizationEnabled: sceneOptimizationEnabled,
      sceneOnDemandEnabled: sceneOnDemandEnabled,
      sceneVideoPlaneSamplingEnabled: sceneVideoPlaneSamplingEnabled,
      sceneResolution: sceneResolution,
      sceneUpdateModes: sceneUpdateModes,
      sceneRenderers: sceneRenderers,
      userAssetsPath: userAssetsPath,
      renderScale: renderScale,
      preferredRenderScale: preferredRenderScale,
      frameRateCap: frameRateCap,
      batteryRenderScale: batteryRenderScale,
      batteryTargetFps: batteryTargetFps,
      onBatteryPower: onBatteryPower,
      qualityThrottle: qualityThrottle,
      effectiveFrameRateCap: effectiveFrameRateCap,
      renderScaleSupported: renderScaleSupported)
  }
}
