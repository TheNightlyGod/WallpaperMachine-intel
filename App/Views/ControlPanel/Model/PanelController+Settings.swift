import AppKit
import Foundation
import UniformTypeIdentifiers

/// The settings that change how much rendering work runs now. After the engine accepts one, the
/// energy readout restarts its window and compares the figure before with the one after.
///
/// Battery quality counts only while it is in force, and so does what a Low Power Mode, a hot Mac or
/// a low battery asks for, but restarting on them anyway costs a few seconds of readout. A condition
/// choice reaches the renderer a moment after it is made, through the presentation policy; the restart
/// only takes a baseline sample, and the figure compared is the window that follows, so that moment is
/// a small part of it. Settings that change no rendering work (the sleep, audio and covered-desktop
/// choices, muting, the low-battery level, app rules, hiding after applying) are not here.
enum RenderingSetting: String, CaseIterable, Sendable {
  case batteryMode, batteryRenderScale, batteryTargetFps, frameRateCap, qualityPreset, renderScale
  case metalFXUpscaling
  case sceneOptimization, sceneOnDemand
  case sceneVideoPlaneSampling, sceneDisplayFraming, sceneResolution
  case sceneMSAA, sceneShadows, sceneVolumetrics, sceneReflections, scenePostProcessing
  case lowPowerModeAction, thermalAction, lowBatteryAction
}

/// Every key of the old `setting` action as its own typed setter, plus the app rules and the small
/// "open something" actions of Settings.
///
/// Each runs the way the page's did: queued (the banner is cleared first and the change waits its
/// turn behind a running command), so a switch pressed during a wallpaper change lands after it.
/// A value a control never offers is refused with `InvalidControlValue`; a value outside a range it
/// does offer is clamped where the page clamped it.
extension PanelController {
  static let focusSettingsURL = URL(
    string: "x-apple.systempreferences:com.apple.Focus-Settings.extension")!

  /// The render scale range: every control offers values inside it, so an outlier is a stale control.
  private static let renderScaleRange: ClosedRange<Double> = 0.25...1
  /// The frame rates the engine accepts for the cap and for the reduced-quality profile.
  private static let frameRateRange: ClosedRange<Int> = 1...240

  /// The shared shape of a `setting`: queued, and for a rendering setting the energy comparison restarts once
  /// the engine accepted it (never on a failure).
  private func change(
    _ rendering: RenderingSetting? = nil, _ operation: @MainActor () async throws -> Void
  ) async throws {
    try await run(.queued) {
      try await operation()
      if rendering != nil { energyUsage.settingChanged() }
    }
  }

  // MARK: General

  /// `launchAtLogin`. A login item the user switched off in System Settings stays off however often it is
  /// registered; the bridge answers "needs approval" and the row says so.
  func setLaunchAtLogin(_ enabled: Bool) async throws {
    try await change { try await store.setLaunchAtLoginAsync(enabled: enabled) }
  }

  /// `hideAfterActivating`: whether applying a wallpaper hides the app so the result shows.
  func setHidesAfterActivating(_ hides: Bool) async throws {
    try await change {
      defaults.set(hides, forKey: PanelPreferences.hideAfterActivatingKey)
      refreshSystemReadings()
    }
  }

  /// `libraryPreviewsOnHover`: whether Library tiles play their animated preview only while the
  /// pointer rests on one, instead of every tile on screen playing. Applies to the grid at once.
  func setLibraryPreviewsOnHover(_ onHover: Bool) async throws {
    try await change {
      defaults.set(onHover, forKey: PanelPreferences.libraryPreviewsOnHoverKey)
      refreshSystemReadings()
      library.previewModeChanged()
    }
  }

  /// Takes the readings nothing notifies the app about again: the battery charge and the preferences
  /// that live outside the stores. Views call it when the panel appears and when the window becomes key,
  /// and the setters that write those preferences call it themselves.
  func refreshSystemReadings() {
    batteryPercent = BatteryReading.read()?.percent
    systemReadingsRevision &+= 1
  }

  /// Shows System Settings › Login Items (`openLoginItemsSettings`), where the user allows a launch at
  /// login they switched off there. Named apart from the `openLoginItemsSettings` test seam it calls.
  func showLoginItemsSettings() async throws {
    try await run(.queued) { openLoginItemsSettings() }
  }

  // MARK: Desktop and lock screen

  /// `writeDesktopPicture`. Refused in both directions while the animated lock screen owns the picture.
  func setWritesDesktopPicture(_ writes: Bool) async throws {
    try await change {
      if store.lockScreenWallpaper?.locksDesktopPictureChoice == true {
        throw WallpaperActionError(
          message: L(
            "Turn off Animate lock screen before changing this: it sets the desktop picture itself."))
      }
      playback.writesDesktopPicture = writes
    }
  }

  /// `refreshDesktopPicture`: retake the Mission Control picture every five minutes.
  func setRefreshesDesktopPicture(_ refreshes: Bool) async throws {
    try await change { playback.refreshesDesktopPicturePeriodically = refreshes }
  }

  /// `keepWindowsOnWallpaperClick`. Writes macOS's own "Click wallpaper to reveal desktop" the other
  /// way round (keeping windows is "Only in Stage Manager"), so the switch round-trips with System
  /// Settings; macOS tells nobody when it changes there, so the value is read again after the write.
  func setKeepsWindowsOnWallpaperClick(_ keeps: Bool) async throws {
    try await change {
      defer { refreshSystemReadings() }
      try DesktopClickRevealPreference.setEnabled(!keeps)
    }
  }

  /// `hideDesktopIcons`. Writes Finder's own "show icons on the desktop" the other way round and
  /// restarts Finder so the desktop follows, after asking, since a restart interrupts whatever
  /// Finder is doing: Cancel, or no window to ask in, changes nothing, and so does a choice Finder
  /// already has. Finder tells nobody when the choice changes elsewhere, so the switch reads it
  /// again afterwards.
  func setHidesDesktopIcons(_ hides: Bool) async throws {
    defer { refreshSystemReadings() }
    let icons = FinderDesktopIcons()
    guard icons.areShown == hides else { return }
    guard
      await dialogs.confirm(
        hides ? L("Hide desktop icons?") : L("Show desktop icons?"),
        detail: L("Finder restarts to apply this. Let any copy or move in Finder finish first."),
        button: L("Restart Finder"))
    else { return }
    try await change { try icons.setShown(!hides) }
  }

  /// `hideNotch`: the black strip behind the menu bar of displays with a camera notch, which the
  /// app delegate's `NotchMaskController` puts up or takes down as soon as the choice is written.
  func setHidesNotch(_ hides: Bool) async throws {
    try await change {
      NotchMaskController.setEnabled(hides, defaults: defaults)
      refreshSystemReadings()
    }
  }

  /// `livePropertyEdits`. Turning it off also puts the saved look back on what the displays were
  /// shown; the edits stay pending in the inspector.
  func setLivePropertyEdits(_ enabled: Bool) async throws {
    try await change {
      LivePropertyEditing.setEnabled(enabled, defaults: defaults)
      refreshSystemReadings()
      if !enabled { await store.stopShowingPropertyEditsOnDesktopAsync() }
    }
  }

  /// `lockScreenEnabled` (experimental). Enabling it is refused while a display follows desktop Spaces,
  /// because the lock screen cannot show a different wallpaper per Space.
  func setLockScreenEnabled(_ enabled: Bool) async throws {
    try await change {
      guard let lock = store.lockScreenWallpaper else {
        throw WallpaperActionError(message: L("Lock Screen integration is unavailable."))
      }
      if enabled,
        store.settingsSnapshot.displays.contains(where: {
          $0.isIndependent
            && automations.configuration(for: $0.displayId).mode == .spaces
        })
      {
        throw WallpaperActionError(
          message: L(
            "Choose another automatic wallpaper mode for your displays before enabling animated lock-screen wallpaper."
          ))
      }
      lock.setEnabled(enabled)
    }
  }

  /// `screenSaverEnabled` (experimental).
  func setScreenSaverEnabled(_ enabled: Bool) async throws {
    try await change {
      guard let lock = store.lockScreenWallpaper else {
        throw WallpaperActionError(message: L("Screen saver integration is unavailable."))
      }
      lock.setScreenSaverEnabled(enabled)
    }
  }

  /// `lockScreenRetry`: activation again. Does nothing without the service.
  func retryLockScreen() async throws {
    try await run(.queued) { store.lockScreenWallpaper?.retry(lockScreen: true) }
  }

  /// `screenSaverRetry`.
  func retryScreenSaver() async throws {
    try await run(.queued) { store.lockScreenWallpaper?.retry(lockScreen: false) }
  }

  // MARK: Playback and power

  /// `wallpapersMuted`: silences every wallpaper without touching their saved sound.
  func setWallpapersMuted(_ muted: Bool) async throws {
    try await change { playback.wallpapersMuted = muted }
  }

  /// `desktopCoveredAction`.
  func setDesktopCoveredAction(_ action: DesktopCoveredAction) async throws {
    try await change { playback.desktopCoveredAction = action }
  }

  /// `playOnlyOnActiveDisplay`.
  func setPlaysOnlyOnActiveDisplay(_ only: Bool) async throws {
    try await change { playback.playsOnlyOnActiveDisplay = only }
  }

  /// `otherAudioAction`.
  func setOtherAudioAction(_ action: OtherAudioAction) async throws {
    try await change { playback.otherAudioAction = action }
  }

  /// `otherAudioVolume`: the share of its own volume, in whole percent from 0 to 100
  /// (`PlaybackPreferences.otherAudioVolumeRange`), each wallpaper keeps under Reduce volume.
  func setOtherAudioVolume(_ percent: Int) async throws {
    guard PlaybackPreferences.otherAudioVolumeRange.contains(percent) else {
      throw InvalidControlValue()
    }
    try await change { playback.otherAudioVolume = percent }
  }

  /// `otherAppInFrontAction`. Choosing here answers the one-time battery question, since the row
  /// offers Pause on battery.
  func setOtherAppInFrontAction(_ action: OtherAppInFrontAction) async throws {
    try await change {
      playback.otherAppInFrontAction = action
      store.supportPrompt?.recordBatteryAsked()
    }
  }

  /// `displaySleepAction`.
  func setDisplaySleepAction(_ action: DisplaySleepAction) async throws {
    try await change { playback.displaySleepAction = action }
  }

  /// `batteryMode`: the engine's own choice of what to do on battery. Its Reduced quality is named
  /// `reducedQuality`, one letter from the condition choices' `reduceQuality`, on purpose. Choosing
  /// here answers the one-time battery question.
  func setBatteryMode(_ mode: BridgeBatteryMode) async throws {
    try await change(.batteryMode) {
      try await store.setBatteryModeAsync(mode)
      store.supportPrompt?.recordBatteryAsked()
    }
  }

  /// `lowPowerModeAction`.
  func setLowPowerModeAction(_ action: SystemConditionAction) async throws {
    try await change(.lowPowerModeAction) { playback.lowPowerModeAction = action }
  }

  /// `thermalAction`.
  func setThermalAction(_ action: SystemConditionAction) async throws {
    try await change(.thermalAction) { playback.thermalAction = action }
  }

  /// `lowBatteryAction`.
  func setLowBatteryAction(_ action: SystemConditionAction) async throws {
    try await change(.lowBatteryAction) { playback.lowBatteryAction = action }
  }

  /// `lowBatteryThreshold`: only a level the menu offers (`PlaybackPreferences.lowBatteryThresholds`).
  /// A level inside the range but not offered, such as 15, is refused too.
  func setLowBatteryThreshold(_ percent: Int) async throws {
    guard PlaybackPreferences.lowBatteryThresholds.contains(percent) else {
      throw InvalidControlValue()
    }
    try await change { playback.lowBatteryThreshold = percent }
  }

  /// `inactivityAction`.
  func setInactivityAction(_ action: InactivityAction) async throws {
    try await change { playback.inactivityAction = action }
  }

  /// `inactivityMinutes`: only a time the menu offers (`PlaybackPreferences.inactivityMinuteChoices`).
  func setInactivityMinutes(_ minutes: Int) async throws {
    guard PlaybackPreferences.inactivityMinuteChoices.contains(minutes) else {
      throw InvalidControlValue()
    }
    try await change { playback.inactivityMinutes = minutes }
  }

  /// `batteryRenderScale`. The engine owns the battery scale and frame rate as one value, so this
  /// is merged with the frame rate as the engine currently reports it, read when the change runs.
  func setBatteryRenderScale(_ scale: Double) async throws {
    let scale = try clampedScale(scale)
    try await change(.batteryRenderScale) {
      try await store.setBatteryQualityProfileAsync(
        renderScale: scale, targetFps: store.settingsSnapshot.batteryTargetFps)
    }
  }

  /// `batteryTargetFps`, clamped to 1...240 and merged with the scale the engine reports.
  func setBatteryTargetFps(_ fps: Int) async throws {
    let fps = UInt32(min(max(fps, Self.frameRateRange.lowerBound), Self.frameRateRange.upperBound))
    try await change(.batteryTargetFps) {
      try await store.setBatteryQualityProfileAsync(
        renderScale: store.settingsSnapshot.batteryRenderScale, targetFps: fps)
    }
  }

  // MARK: Performance

  /// `qualityPreset`: the render scale, then the frame-rate limit, as one queued change. There is no
  /// rollback when the second fails, so a failure can leave the scale of the preset with the old limit.
  func applyQualityPreset(_ preset: QualityPreset) async throws {
    try await change(.qualityPreset) {
      try await store.setRenderScaleAsync(preset.renderScale)
      try await store.setFrameRateCapAsync(preset.frameRateCap)
    }
  }

  /// `frameRateCap`: nil is no limit; a number is clamped to 1...240.
  func setFrameRateCap(_ cap: Int?) async throws {
    let value = cap.map { UInt32(min(max($0, Self.frameRateRange.lowerBound), Self.frameRateRange.upperBound)) }
    try await change(.frameRateCap) { try await store.setFrameRateCapAsync(value) }
  }

  /// `renderScale`, clamped to 0.25...1: a control only offers values inside it, so an outlier means a
  /// stale control, which is clamped rather than refused or passed on. A scale that is not a number is refused.
  func setRenderScale(_ scale: Double) async throws {
    let scale = try clampedScale(scale)
    try await change(.renderScale) { try await store.setRenderScaleAsync(scale) }
  }

  private func clampedScale(_ scale: Double) throws -> Float {
    guard scale.isFinite else { throw InvalidControlValue() }
    return Float(min(max(scale, Self.renderScaleRange.lowerBound), Self.renderScaleRange.upperBound))
  }

  /// `metalFXUpscaling`: a scene drawn below full resolution is brought back to full size by
  /// MetalFX instead of being stretched. Running scenes pick it up at their next frame.
  func setMetalFXUpscaling(_ enabled: Bool) async throws {
    try await change(.metalFXUpscaling) { try await store.setMetalFXUpscalingEnabledAsync(enabled) }
  }

  /// `sceneOptimization`.
  func setSceneOptimization(_ enabled: Bool) async throws {
    try await change(.sceneOptimization) { try await store.setSceneOptimizationEnabledAsync(enabled) }
  }

  /// `sceneOnDemand`.
  func setSceneOnDemand(_ enabled: Bool) async throws {
    try await change(.sceneOnDemand) { try await store.setSceneOnDemandEnabledAsync(enabled) }
  }

  /// `sceneVideoPlaneSampling` (experimental).
  func setSceneVideoPlaneSampling(_ enabled: Bool) async throws {
    try await change(.sceneVideoPlaneSampling) {
      try await store.setSceneVideoPlaneSamplingEnabledAsync(enabled)
    }
  }

  /// `sceneDisplayFraming` (experimental): running 2D scenes take it at their next frame.
  func setSceneDisplayFraming(_ enabled: Bool) async throws {
    try await change(.sceneDisplayFraming) {
      try await store.setSceneDisplayFramingEnabledAsync(enabled)
    }
  }

  /// `sceneResolution`: running 2D scenes resize their render targets in place.
  func setSceneResolution(_ mode: SceneResolutionMode) async throws {
    try await change(.sceneResolution) { try await store.setSceneResolutionAsync(mode.rawValue) }
  }

  /// The scene quality rows. Each sends the saved quality with one field replaced; running scenes
  /// load once more with it.
  func setSceneMSAA(_ msaa: BridgeMsaa) async throws {
    try await changeSceneQuality(.sceneMSAA) { $0.msaa = msaa }
  }

  func setSceneShadows(_ level: BridgeQualityLevel) async throws {
    try await changeSceneQuality(.sceneShadows) { $0.shadows = level }
  }

  func setSceneVolumetrics(_ level: BridgeQualityLevel) async throws {
    try await changeSceneQuality(.sceneVolumetrics) { $0.volumetrics = level }
  }

  func setSceneReflections(_ enabled: Bool) async throws {
    try await changeSceneQuality(.sceneReflections) { $0.reflections = enabled }
  }

  func setScenePostProcessing(_ level: BridgePostProcessing) async throws {
    try await changeSceneQuality(.scenePostProcessing) { $0.postProcessing = level }
  }

  private func changeSceneQuality(
    _ setting: RenderingSetting, _ edit: @escaping (inout BridgeSceneQuality) -> Void
  ) async throws {
    try await change(setting) {
      var updated = store.settingsSnapshot.sceneQuality
      edit(&updated)
      try await store.setSceneQualityAsync(updated)
    }
  }

  // MARK: Troubleshooting and Steam

  /// `verboseLogging`: extra detail from now on, kept across restarts.
  func setVerboseLogging(_ enabled: Bool) async throws {
    try await change { try await store.setVerboseLoggingAsync(enabled: enabled) }
  }

  /// `telemetry`: **Send performance data** (docs/features/telemetry.md). Choosing here, or in the
  /// guide, answers the one-time question. The switch is disabled without a service; a stale control
  /// must not stall the guide's Continue, which stops at the first refusal, so it is only logged.
  func setSendsPerformanceData(_ enabled: Bool) async throws {
    try await change {
      guard let telemetry = store.telemetry else {
        AppLog.warn("telemetry: the switch was changed but sending is unavailable in this run")
        return
      }
      telemetry.setEnabled(enabled)
      store.supportPrompt?.recordTelemetryAsked()
    }
  }

  /// `inspectWebWallpapers`: lets Safari's Develop menu attach to running web wallpapers.
  func setInspectsWebWallpapers(_ enabled: Bool) async throws {
    try await change {
      WebWallpaperInspection.setEnabled(enabled, defaults: defaults)
      refreshSystemReadings()
    }
  }

  /// `workshopUpdateChecks`: whether Steam is asked once a day which installed wallpapers changed.
  func setWorkshopUpdateChecks(_ enabled: Bool) async throws {
    try await change { workshop.updates.checksAutomatically = enabled }
  }

  /// `concurrentDownloads`: how many Steam downloads run at once. Only a count the menu offers
  /// (`WorkshopDownloadManager.concurrentDownloadRange`) is accepted.
  func setConcurrentDownloads(_ count: Int) async throws {
    guard WorkshopDownloadManager.concurrentDownloadRange.contains(count) else {
      throw InvalidControlValue()
    }
    try await change { workshop.setConcurrentDownloads(count) }
  }

  /// `openFocusSettings`: Focus filters are added to a Focus there; the app cannot add its own.
  func openFocusSettings() async throws {
    try await run(.queued) { _ = openSystemURL(Self.focusSettingsURL) }
  }

  // MARK: App rules

  /// `appRuleAdd`: chooses an app and adds a rule that pauses wallpapers while it runs. The same app is
  /// never added twice (the existing rule stays), and one with no bundle identifier is refused.
  ///
  /// The picker is asked before queueing, so an open sheet holds up nothing else; the banner is still
  /// cleared first, as for any queued action.
  func addAppRule() async throws {
    errors.clearAction()
    guard let url = await chooseApplicationURL() else { return }
    try await run(.queued) {
      guard let bundleID = Bundle(url: url)?.bundleIdentifier else {
        throw WallpaperActionError(
          message: L("This app has no bundle identifier, so it can’t be used in an app rule."))
      }
      var name = FileManager.default.displayName(atPath: url.path)
      if name.lowercased().hasSuffix(".app") { name = String(name.dropLast(4)) }
      playback.addRule(bundleIdentifier: bundleID, name: name)
    }
  }

  /// `appRuleUpdate` (condition). An unknown rule says "That app rule no longer exists."
  func updateAppRule(_ id: UUID, condition: AppRuleCondition) async throws {
    try await change { try playback.updateRule(id: id, condition: condition) }
  }

  /// `appRuleUpdate` (action).
  func updateAppRule(_ id: UUID, action: AppRuleAction) async throws {
    try await change { try playback.updateRule(id: id, action: action) }
  }

  /// `appRuleRemove`.
  func removeAppRule(_ id: UUID) async throws {
    try await change { playback.removeRule(id: id) }
  }

  /// The application to add a rule for: what the `chooseApplication` seam answers, else the panel's sheet
  /// (applications only, starting in /Applications, packages not opened).
  private func chooseApplicationURL() async -> URL? {
    if let chooseApplication { return await chooseApplication() }
    let panel = NSOpenPanel()
    panel.title = L("Choose App")
    panel.allowedContentTypes = [.application]
    panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.treatsFilePackagesAsDirectories = false
    return await dialogs.choose(panel)
  }
}
