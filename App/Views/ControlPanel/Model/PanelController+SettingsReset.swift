import Foundation

/// Settings › General › Reset All Settings: every choice the Settings pages offer goes back to what
/// a fresh install starts with, after the user confirms.
///
/// What is the user's content rather than a setting stays: the library, favorites, playlists,
/// collections, presets, the display arrangement and per-display wallpapers, the storage location
/// and the Steam and pixiv sign-ins. macOS's own "Click wallpaper to reveal desktop", which a
/// Desktop switch only mirrors, is the system's and stays too.
extension PanelController {
  /// The engine's defaults for the settings it owns, as `AppConfig::default()` in
  /// `Renderer/Bridge/src/config/app.rs` writes them.
  enum EngineSettingDefaults {
    static let batteryMode = BridgeBatteryMode.keepRunning
    static let renderScale: Float = 1
    static let frameRateCap: UInt32? = nil
    static let batteryRenderScale: Float = 0.75
    static let batteryTargetFps: UInt32 = 30
    static let sceneResolution = SceneResolutionMode.display
    static let sceneOptimization = true
    static let sceneOnDemand = false
    static let sceneVideoPlaneSampling = false
    static let verboseLogging = false
  }

  /// Asks first; Cancel, or no window to ask in, changes nothing. Then every setting is reset in
  /// one queued change. One that fails does not stop the others: the first failure is reported
  /// once all have been tried.
  func resetAllSettings() async throws {
    errors.clearAction()
    guard
      await dialogs.confirm(
        L("Reset all settings?"),
        detail: L(
          "Every setting returns to its default, including appearance, language, shortcuts, playback, performance and app rules. Your library, playlists, collections, displays and sign-ins are kept."
        ),
        button: L("Reset"))
    else { return }
    try await run(.queued) { try await resetSettingsToDefaults() }
  }

  private func resetSettingsToDefaults() async throws {
    var failure: Error?
    func attempt(_ step: () async throws -> Void) async {
      do { try await step() } catch {
        AppLog.warn("Reset all settings: \(error.localizedDescription)")
        if failure == nil { failure = error }
      }
    }
    defer {
      refreshSystemReadings()
      energyUsage.settingChanged()
    }

    // General
    if store.settingsSnapshot.launchAtLoginEnabled {
      await attempt { try await store.setLaunchAtLoginAsync(enabled: false) }
    }
    defaults.removeObject(forKey: PanelPreferences.hideAfterActivatingKey)
    if appLanguage.preference != AppLanguageStore.systemChoice {
      await attempt { try await setLanguage(nil) }
    }
    theme.reset()
    for action in HotKeyAction.allCases where hotKeys.bindings[action] != nil {
      await attempt { try hotKeys.set(nil, for: action) }
    }

    // Desktop and lock screen. The lock screen goes first: while on, it holds the desktop
    // picture choice that the playback reset returns to its default.
    if let lock = store.lockScreenWallpaper {
      if lock.isRequested { lock.setEnabled(false) }
      if lock.screenSaverRequested { lock.setScreenSaverEnabled(false) }
    }
    let wasShowingLiveEdits = LivePropertyEditing.isEnabled(defaults: defaults)
    LivePropertyEditing.setEnabled(LivePropertyEditing.buildDefault, defaults: defaults)
    if wasShowingLiveEdits && !LivePropertyEditing.buildDefault {
      await store.stopShowingPropertyEditsOnDesktopAsync()
    }

    // Playback, power and app rules.
    playback.resetToDefaults()

    // What the engine keeps. Only a value that differs is sent, so a reset of settings already
    // at their defaults restarts nothing.
    await resetEngineSettings(attempt)

    // Troubleshooting, Steam and privacy.
    WebWallpaperInspection.setEnabled(WebWallpaperInspection.buildDefault, defaults: defaults)
    workshop.updates.checksAutomatically = true
    workshop.setConcurrentDownloads(WorkshopDownloadManager.defaultConcurrentDownloads)
    if let telemetry = store.telemetry, telemetry.isEnabled { telemetry.setEnabled(false) }

    if let failure { throw failure }
  }

  private func resetEngineSettings(_ attempt: (() async throws -> Void) async -> Void) async {
    typealias D = EngineSettingDefaults
    let current = { self.store.settingsSnapshot }
    if current().batteryMode != D.batteryMode {
      await attempt { try await store.setBatteryModeAsync(D.batteryMode) }
    }
    if current().batteryRenderScale != D.batteryRenderScale
      || current().batteryTargetFps != D.batteryTargetFps
    {
      await attempt {
        try await store.setBatteryQualityProfileAsync(
          renderScale: D.batteryRenderScale, targetFps: D.batteryTargetFps)
      }
    }
    if current().preferredRenderScale != D.renderScale {
      await attempt { try await store.setRenderScaleAsync(D.renderScale) }
    }
    if current().frameRateCap != D.frameRateCap {
      await attempt { try await store.setFrameRateCapAsync(D.frameRateCap) }
    }
    if current().sceneResolution != D.sceneResolution.rawValue {
      await attempt { try await store.setSceneResolutionAsync(D.sceneResolution.rawValue) }
    }
    if current().sceneOptimizationEnabled != D.sceneOptimization {
      await attempt { try await store.setSceneOptimizationEnabledAsync(D.sceneOptimization) }
    }
    if current().sceneOnDemandEnabled != D.sceneOnDemand {
      await attempt { try await store.setSceneOnDemandEnabledAsync(D.sceneOnDemand) }
    }
    if current().sceneVideoPlaneSamplingEnabled != D.sceneVideoPlaneSampling {
      await attempt {
        try await store.setSceneVideoPlaneSamplingEnabledAsync(D.sceneVideoPlaneSampling)
      }
    }
    if current().verboseLogging != D.verboseLogging {
      await attempt { try await store.setVerboseLoggingAsync(enabled: D.verboseLogging) }
    }
  }
}
