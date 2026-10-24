import Foundation

/// The current settings values, merged from the bridge's snapshot, the playback preferences and the
/// Mac's own facts. Each getter reads the counters of the stores SwiftUI cannot observe first
/// (`revisions.playback`, `.power`, `.focus`, `.conditions`, `.energy`, `systemReadingsRevision`), so a view that
/// calls it is asked again when they change.
extension PanelController {
  var generalSettings: GeneralSettings {
    _ = systemReadingsRevision
    let settings = store.settingsSnapshot
    return GeneralSettings(
      launchAtLogin: LaunchAtLoginState(
        isOn: settings.launchAtLoginEnabled, isAvailable: settings.launchAtLoginAvailable,
        needsApproval: settings.launchAtLoginNeedsApproval),
      hidesAfterActivating: hidesAfterActivating)
  }

  var desktopSettings: DesktopSettings {
    _ = revisions.playback
    _ = systemReadingsRevision
    return DesktopSettings(
      writesDesktopPicture: playback.writesDesktopPicture,
      desktopPictureLocked: store.lockScreenWallpaper?.locksDesktopPictureChoice ?? false,
      refreshesDesktopPicture: playback.refreshesDesktopPicturePeriodically,
      keepsWindowsOnWallpaperClick: !DesktopClickRevealPreference.isEnabled,
      livePropertyEdits: LivePropertyEditing.isEnabled(defaults: defaults))
  }

  /// The Animate lock screen row and its quick tile.
  var lockScreenState: LockScreenState {
    LockScreenState.make(.lockScreen, service: store.lockScreenWallpaper)
  }

  /// The Use wallpaper as screen saver row and its quick tile. Shares its busy flag with the lock screen.
  var screenSaverState: LockScreenState {
    LockScreenState.make(.screenSaver, service: store.lockScreenWallpaper)
  }

  var playbackSettings: PlaybackSettings {
    _ = revisions.playback
    _ = revisions.power
    _ = revisions.focus
    _ = revisions.conditions
    let settings = store.settingsSnapshot
    let focus = FocusFilterState.shared
    return PlaybackSettings(
      wallpapersMuted: playback.wallpapersMuted,
      desktopCoveredAction: playback.desktopCoveredAction,
      playsOnlyOnActiveDisplay: playback.playsOnlyOnActiveDisplay,
      otherAudioAction: playback.otherAudioAction, displaySleepAction: playback.displaySleepAction,
      batteryMode: settings.batteryMode, onBatteryPower: settings.onBatteryPower,
      batteryRenderScale: settings.batteryRenderScale,
      batteryTargetFps: Int(settings.batteryTargetFps),
      lowBatteryAction: playback.lowBatteryAction,
      lowBatteryThreshold: playback.lowBatteryThreshold,
      lowPowerModeAction: playback.lowPowerModeAction, thermalAction: playback.thermalAction,
      batteryPercent: batteryPercent,
      lowPowerModeIsOn: ProcessInfo.processInfo.isLowPowerModeEnabled,
      thermalLevel: ThermalLevel(ProcessInfo.processInfo.thermalState),
      conditions: systemConditions.engaged,
      focusAction: focus.selection?.target.kind.rawValue ?? focus.action?.rawValue
        ?? FocusFilterEffect.keepRunning.rawValue,
      appRules: playback.appRules,
      enabledDisplayCount: settings.displays.filter(\.enabled).count)
  }

  /// Why quality is lower than the user's settings, and the render scale in force.
  var qualityReport: QualityReport {
    _ = revisions.playback
    return QualityReport.make(
      settings: store.settingsSnapshot, lowPowerModeAction: playback.lowPowerModeAction,
      thermalAction: playback.thermalAction, lowBatteryAction: playback.lowBatteryAction,
      batteryPercent: batteryPercent)
  }

  var performanceSettings: PerformanceSettings {
    let settings = store.settingsSnapshot
    return PerformanceSettings(
      quality: qualityReport, frameRateCap: settings.frameRateCap,
      effectiveFrameRateCap: settings.effectiveFrameRateCap,
      slider: FrameRateCapSlider(displays: settings.displays),
      activePreset: QualityPreset.active(
        frameRateCap: settings.frameRateCap, preferredRenderScale: settings.preferredRenderScale),
      videoBackends: settings.videoBackends.map(VideoBackendReport.init),
      sceneResolution: SceneResolutionMode(rawValue: settings.sceneResolution) ?? .display,
      sceneOptimization: settings.sceneOptimizationEnabled,
      sceneOnDemand: settings.sceneOnDemandEnabled,
      sceneVideoPlaneSampling: settings.sceneVideoPlaneSamplingEnabled,
      sceneUpdates: settings.sceneUpdateModes.map(SceneUpdateReport.init),
      sceneRenderers: settings.sceneRenderers.map(SceneRendererReport.init))
  }

  /// The frame-rate ceiling in force and the setting that sets it, nil while there is none.
  var frameRateCeiling: FrameRateCeiling? { FrameRateCeiling(store.settingsSnapshot) }

  /// The ceiling where it holds a display below `saved`, the display's own frame rate; nil when
  /// nothing does. Settings › Displays notes it and opens the page of the setting that sets it.
  func frameRateLimit(saved: Int) -> FrameRateCeiling? {
    frameRateCeiling?.limiting(saved: saved)
  }

  var librarySteamSettings: LibrarySteamSettings {
    LibrarySteamSettings(
      workshopUpdateChecks: workshop.updates.checksAutomatically,
      concurrentDownloads: workshop.downloader.maximumConcurrentDownloads,
      concurrentDownloadsRange: WorkshopDownloadManager.concurrentDownloadRange,
      libraryPath: ClientPaths.libraryURL.path)
  }

  var storageState: StorageState {
    _ = systemReadingsRevision
    let settings = store.settingsSnapshot
    return StorageState(
      shaderCacheBytes: settings.storage.shaderCacheSizeBytes,
      logBytes: settings.storage.logs.activeFileSizeBytes, userAssetsPath: settings.userAssetsPath,
      userAssetsReleasedBytes: userAssetsReleasedBytes, verboseLogging: settings.verboseLogging,
      inspectsWebWallpapers: WebWallpaperInspection.isEnabled(defaults: defaults))
  }

  var aboutInfo: AboutInfo {
    let settings = store.settingsSnapshot
    return AboutInfo(
      version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
      gitRevision: settings.gitSha, bridgeVersion: settings.bridgeVersion,
      coreVersion: settings.coreVersion, shaderVersion: settings.shaderPipelineVersion)
  }

  /// The Energy use readout. The monitor measures only while the panel is visible on Settings.
  var energyReadout: EnergyReadout {
    _ = revisions.energy
    return energyUsage.readout
  }

  /// The Backup group's state.
  var backupPresentation: BackupPresentation {
    BackupPresentation(
      isBusy: backup.busy, hasPendingRestore: backup.pendingRestore,
      preview: backup.preview.map(BackupPresentation.Preview.init), status: backup.status,
      error: backup.error)
  }

  /// The About › Updates card for the updater's state. `locale` words the time a rate limit ends.
  func updatePresentation(locale: Locale = .current) -> UpdatePresentation {
    UpdatePresentation(
      state: updater.state, notes: updater.releaseNotes, rateLimitedUntil: updater.rateLimitedUntil,
      locale: locale)
  }
}
