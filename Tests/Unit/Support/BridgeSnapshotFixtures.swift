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
    volume: Float = 1,
    engineOptions: BridgeEngineOptions? = nil
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
      volume: volume,
      engineOptions: engineOptions)
  }

  /// Wallpaper Engine's per-wallpaper option values, at their defaults unless named.
  static func engineOptionValues(
    colorEnabled: Bool = false, brightness: Double = 50, imageFilter: String = "",
    flipHorizontal: Bool = false, mouseParallax: Bool = true, playbackRate: Double = 100
  ) -> BridgeEngineOptionValues {
    BridgeEngineOptionValues(
      colorEnabled: colorEnabled, brightness: brightness, contrast: 50, saturation: 50,
      hueShift: 50, imageFilter: imageFilter, filterStrength: 100,
      flipHorizontal: flipHorizontal, mouseParallax: mouseParallax, playbackRate: playbackRate)
  }

  /// The rows the bridge reports for a scene with every option at its default, the
  /// mouse-parallax switch included when `parallax` is set.
  static func engineOptions(
    parallax: Bool = false, imageFilters: [String] = ["lutx32_amber", "k23_b"],
    values: [BridgeEngineOptionId: BridgePropertyValue] = [:]
  ) -> BridgeEngineOptions {
    let slider = BridgeSliderMetadata(min: 0, max: 100, step: 1, precision: 0)
    var rows: [(BridgeEngineOptionId, BridgePropertyValue, BridgeSliderMetadata?)] = [
      (.colorEnabled, .bool(value: false), nil),
      (.brightness, .number(value: 50), slider),
      (.contrast, .number(value: 50), slider),
      (.saturation, .number(value: 50), slider),
      (.hueShift, .number(value: 50), slider),
      (.imageFilter, .string(value: ""), nil),
      (.filterStrength, .number(value: 100), slider),
      (.flipHorizontal, .bool(value: false), nil),
    ]
    if parallax { rows.append((.mouseParallax, .bool(value: true), nil)) }
    rows.append((.playbackRate, .number(value: 100), BridgeSliderMetadata(min: 10, max: 200, step: 1, precision: 0)))
    func current(_ id: BridgeEngineOptionId, _ fallback: BridgePropertyValue) -> BridgePropertyValue {
      values[id] ?? fallback
    }
    let colorOn = current(.colorEnabled, .bool(value: false)) == .bool(value: true)
    let filterChosen = current(.imageFilter, .string(value: "")) != .string(value: "")
    return BridgeEngineOptions(
      rows: rows.map { id, defaultValue, slider in
        let value = current(id, defaultValue)
        let enabled: Bool =
          switch id {
          case .brightness, .contrast, .saturation, .hueShift: colorOn
          case .filterStrength: filterChosen
          default: true
          }
        return BridgeEngineOptionRow(
          id: id, value: value, defaultValue: defaultValue, slider: slider,
          modified: value != defaultValue, enabled: enabled)
      },
      imageFilters: imageFilters)
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
  /// off, MetalFX upscaling off, scene optimisation on and 2D scenes drawn at the display's resolution. Tests that care about one of those pass it
  /// explicitly.
  static func settings(
    displays: [BridgeDisplaySettingsRow] = [],
    batteryMode: BridgeBatteryMode = .keepRunning,
    videoBackends: [BridgeVideoBackendReport] = [],
    sceneOptimizationEnabled: Bool = true,
    sceneOnDemandEnabled: Bool = false,
    metalfxUpscalingEnabled: Bool = false,
    sceneVideoPlaneSamplingEnabled: Bool = false,
    sceneDisplayFramingEnabled: Bool = false,
    sceneResolution: String = "display",
    sceneQuality: BridgeSceneQuality = .wallpaperEngineDefault,
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
    renderScaleSupported: Bool = true,
    mutedWallpaperCount: UInt32 = 0
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
      metalfxUpscalingEnabled: metalfxUpscalingEnabled,
      sceneVideoPlaneSamplingEnabled: sceneVideoPlaneSamplingEnabled,
      sceneDisplayFramingEnabled: sceneDisplayFramingEnabled,
      sceneResolution: sceneResolution,
      sceneQuality: sceneQuality,
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
      renderScaleSupported: renderScaleSupported,
      mutedWallpaperCount: mutedWallpaperCount)
  }
}
