import Foundation

// The settings the Settings pages read, merged from the bridge's settings snapshot, the playback
// preferences and the Mac's own facts, as typed values per page. Each is built by a pure
// factory from plain inputs so its rules are tested without a window; `PanelController` hands out
// the current ones (`PanelController+SettingsValues.swift`).

// MARK: - General

struct GeneralSettings: Equatable, Sendable {
  var launchAtLogin: LaunchAtLoginState
  /// Whether applying a wallpaper hides the app so the result is visible. Off until turned on.
  var hidesAfterActivating: Bool
}

/// Launch at login as the Startup row shows it. The facts are the bridge's: whether the login item
/// can be registered, and whether the user switched it off in System Settings where only they can
/// allow it again.
struct LaunchAtLoginState: Equatable, Sendable {
  /// Whether the login item is on. A request waiting for approval is not on.
  var isOn: Bool
  /// False outside Applications, where the app cannot register itself; the switch is disabled with a reason.
  var isAvailable: Bool
  /// The item is registered but switched off in System Settings › Login Items.
  var needsApproval: Bool

  /// "Open Login Items…" sits beside the switch while the user has something to allow there.
  var showsLoginItemsButton: Bool { isAvailable && needsApproval }

  /// The state line of the quick Open at Login tile instead of On or Off: nil while nothing needs saying.
  @MainActor var tileNote: String? {
    if !isAvailable { return L("Unavailable") }
    return needsApproval ? L("Needs approval") : nil
  }

  /// What the row tells the user to do, nil when nothing is left to explain.
  @MainActor var note: String? {
    if !isAvailable { return L("Move the app to Applications to enable.") }
    if needsApproval {
      return L(
        "Allow WallpaperMachine in System Settings → General → Login Items to launch it at login.")
    }
    return nil
  }
}

// MARK: - Desktop and lock screen

struct DesktopSettings: Equatable, Sendable {
  /// Whether the app installs a still of the wallpaper as macOS's own desktop picture. On until turned off.
  var writesDesktopPicture: Bool
  /// The animated lock screen sets the picture itself, so the choice waits for it.
  var desktopPictureLocked: Bool
  /// Retake the Mission Control picture every five minutes.
  var refreshesDesktopPicture: Bool
  /// The inverse of macOS's "Click wallpaper to reveal desktop".
  var keepsWindowsOnWallpaperClick: Bool
  /// The displays follow property edits before Apply.
  var livePropertyEdits: Bool

  /// A timed retake of a picture that is not written does nothing, so the switch waits for the one it depends on.
  var canChangeRefresh: Bool { writesDesktopPicture }
  /// Locked by the animated lock screen, in either direction.
  var canChangeWritesDesktopPicture: Bool { !desktopPictureLocked }

  /// What the row says beneath it while the lock screen holds the choice; nil otherwise, when the
  /// row's ordinary explanation applies.
  @MainActor var lockedNote: String? {
    desktopPictureLocked
      ? L("Animate lock screen sets the desktop picture itself, so this cannot be changed while it is on.")
      : nil
  }
}

/// One of the two animated-system features, as its row and quick tile show it: Animate lock screen
/// and Use wallpaper as screen saver. Both are served by `LockScreenWallpaperService`, and both
/// share its busy flag.
struct LockScreenState: Equatable, Sendable {
  enum Kind: Sendable { case lockScreen, screenSaver }

  var kind: Kind
  /// Whether the user asked for it.
  var isRequested: Bool
  /// False without the service (before macOS 26, or when it could not start); the switch is disabled.
  var isAvailable: Bool
  /// The service is working on a change, and so both switches wait.
  var isBusy: Bool
  /// What the service reports, or why there is none ("Requires macOS 26 or later" / "Unavailable").
  var status: String
  var error: String?

  /// The switch cannot be changed while unavailable or while the service is changing something.
  var isSwitchEnabled: Bool { isAvailable && !isBusy }
  /// Retry appears with the error and waits for the service to finish.
  var canRetry: Bool { isAvailable && error != nil && !isBusy }

  /// The readout beside the switch. Unavailable names why. While busy the lock screen's reading
  /// ends in an ellipsis, added unless the service's own wording already ends in one; the screen
  /// saver's reads plain. An empty status reads "Updating".
  @MainActor var statusText: String {
    guard isAvailable else { return status.isEmpty ? L("Unavailable") : status }
    return kind == .lockScreen && isBusy ? busyReading : (status.isEmpty ? L("Updating") : status)
  }

  /// The status as a working service words it: "Preparing…". An ellipsis is added unless the service's
  /// own wording already ends in one, so it never doubles.
  @MainActor private var busyReading: String {
    let text = status.isEmpty ? L("Updating") : status
    return text.hasSuffix("…") || text.hasSuffix("...") ? text : text + "…"
  }

  /// The state line of the quick tile instead of On or Off: the status with an ellipsis while the
  /// service works (for either feature, unlike the screen saver's row), "Unavailable" without a
  /// service, nil otherwise.
  @MainActor var tileNote: String? {
    if isBusy { return busyReading }
    return isAvailable ? nil : L("Unavailable")
  }

  /// What the service says with no service at all.
  @MainActor static func unavailableStatus() -> String {
    LockScreenConfiguration.isSupportedBySystem
      ? L("Unavailable") : L("Requires macOS 26 or later")
  }

  @MainActor
  static func make(_ kind: Kind, service: LockScreenWallpaperService?) -> LockScreenState {
    guard let service else {
      return LockScreenState(
        kind: kind, isRequested: false, isAvailable: false, isBusy: false,
        status: unavailableStatus(), error: nil)
    }
    switch kind {
    case .lockScreen:
      return LockScreenState(
        kind: kind, isRequested: service.isRequested, isAvailable: true, isBusy: service.isBusy,
        status: service.status, error: service.errorMessage)
    case .screenSaver:
      return LockScreenState(
        kind: kind, isRequested: service.screenSaverRequested, isAvailable: true,
        isBusy: service.isBusy, status: service.screenSaverStatus, error: service.screenSaverError)
    }
  }
}

// MARK: - Playback and power

/// Playback & Power: what wallpapers do when something else wants the Mac, and the facts the page
/// reports "in effect now" beside the choices.
struct PlaybackSettings: Equatable {
  var wallpapersMuted: Bool
  var desktopCoveredAction: DesktopCoveredAction
  var playsOnlyOnActiveDisplay: Bool
  var otherAudioAction: OtherAudioAction
  var displaySleepAction: DisplaySleepAction
  var batteryMode: BridgeBatteryMode
  var onBatteryPower: Bool
  /// The reduced-quality profile every Reduced quality choice shares.
  var batteryRenderScale: Float
  var batteryTargetFps: Int
  var lowBatteryAction: SystemConditionAction
  var lowBatteryThreshold: Int
  var lowPowerModeAction: SystemConditionAction
  var thermalAction: SystemConditionAction
  /// Nil on a Mac without an internal battery, which is how the low-battery rows are left out.
  var batteryPercent: Int?
  var lowPowerModeIsOn: Bool
  var thermalLevel: ThermalLevel
  /// The low-battery, Low Power Mode and heat rules engaged now, as the app's condition monitor
  /// evaluated them (the low-battery rule's hysteresis included), so a row never guesses.
  var conditions: EngagedSystemConditions
  /// The Focus filter in effect, by name: `keepRunning` while none is (`FocusFilterEffect` knows the rest).
  var focusAction: String
  var appRules: [AppRule]
  /// Enabled displays, which decide whether "Only play on the display I'm using" is worth offering.
  var enabledDisplayCount: Int

  var hasBattery: Bool { batteryPercent != nil }

  /// The low-battery rows exist only where there is a battery.
  var showsLowBatteryRows: Bool { hasBattery }
  /// The low battery level is asked only once the rule does something.
  var showsLowBatteryLevel: Bool { hasBattery && lowBatteryAction != .keepRunning }
  /// "Only play on the display I'm using" needs two displays, or is shown while on so it can be turned off.
  var showsActiveDisplayOnly: Bool { enabledDisplayCount >= 2 || playsOnlyOnActiveDisplay }
  /// The quick On battery module is worth showing on a Mac with a battery, or while its choice is not the default.
  var offersBatteryMode: Bool { hasBattery || batteryMode != .keepRunning }

  /// The condition rule that overrides the On battery choice now: one that pauses or stops
  /// wallpapers while the Mac runs on battery, beyond what the choice does itself (Pause already
  /// pauses, so only a stop overrides it). Nil plugged in, where the choice does nothing.
  var conditionOverridingBatteryMode: EngagedSystemCondition? {
    guard onBatteryPower, let rule = conditions.strongestRuleAction else { return nil }
    if batteryMode == .pause, rule.effect == .pause { return nil }
    return rule
  }

  /// What Quick Settings' On battery module says while another rule overrides the choice: the rule
  /// that pauses or stops wallpapers, which outweighs any quality, or else the cause holding
  /// quality down (`QualityReport.onBatteryText`). Nil while the choice is what is in force.
  @MainActor func onBatteryText(quality: QualityReport) -> String? {
    conditionOverridingBatteryMode?.statusText ?? quality.onBatteryText
  }

  /// "Low Power Mode is on now.", and what its rule does while engaged.
  @MainActor var lowPowerModeNote: String {
    Self.note(
      lowPowerModeIsOn ? L("Low Power Mode is on now.") : L("Low Power Mode is off now."),
      engaged: conditions.effect(of: .lowPowerMode))
  }

  @MainActor var thermalNote: String {
    Self.note(thermalLevel.note(for: thermalAction), engaged: conditions.effect(of: .heat))
  }

  /// "The battery is at 54% now." beside the low-battery choice, and what the rule does while
  /// engaged, which the charge alone cannot tell: the rule ends only 5 points above its level.
  /// Nil without a battery.
  @MainActor var lowBatteryNote: String? {
    guard let percent = batteryPercent else { return nil }
    return Self.note(
      L(
        "Applies only while the Mac runs on battery. It ends 5 points above the level you choose, or when you plug in. The battery is at \(percent)% now."
      ), engaged: conditions.effect(of: .lowBattery))
  }

  /// A condition row's note, with "In effect now. Wallpapers are paused." on its own line while
  /// the rule is engaged.
  @MainActor private static func note(_ note: String, engaged: EngagedSystemCondition.Effect?) -> String {
    guard let engaged else { return note }
    return note + "\n" + engaged.inEffectText
  }

  /// "A Focus filter is in effect now: Mute.", nil while none is.
  @MainActor var focusNote: String? { FocusFilterEffect.note(forRawValue: focusAction) }
}

// MARK: - Performance

/// Performance: quality, the renderers and the live reports about them.
struct PerformanceSettings: Equatable {
  var quality: QualityReport
  /// The saved frame-rate limit; nil is no limit.
  var frameRateCap: UInt32?
  /// What the engine holds frames to now, whatever lowered it.
  var effectiveFrameRateCap: UInt32?
  var slider: FrameRateCapSlider
  /// The preset the saved values match, nil for Custom.
  var activePreset: QualityPreset?
  var videoBackends: [VideoBackendReport]
  var sceneResolution: SceneResolutionMode
  var sceneOptimization: Bool
  var sceneOnDemand: Bool
  var sceneVideoPlaneSampling: Bool
  var sceneUpdates: [SceneUpdateReport]
  var sceneRenderers: [SceneRendererReport]

  /// The slider's position for the saved cap.
  var sliderPosition: Int { slider.position(forCap: frameRateCap) }

  /// The Internal render scale menu for the saved scale, which includes a hand-edited value.
  @MainActor var renderScaleChoices: [RenderScaleChoice] {
    RenderScaleChoices.options(saved: quality.preferredRenderScale)
  }

  /// The menu is disabled when no running wallpaper can honour a scale; the note says so.
  var canChangeRenderScale: Bool { quality.renderScaleSupported }

  /// The sentence under Scene render optimisation: shown "How much can be skipped…" only while a
  /// running scene is drawn by Native Metal, since the note is only true of a surface that is.
  var nativeSceneRunning: Bool { sceneRenderers.contains { $0.backend == .nativeMetal } }

  var optimization: SceneOptimizationStatus {
    SceneOptimizationStatus(reports: sceneRenderers, saved: sceneOptimization)
  }
}

// MARK: - Library and Steam

/// The Library & Steam settings this layer owns: the daily check, the downloads ceiling and the folder.
struct LibrarySteamSettings: Equatable, Sendable {
  var workshopUpdateChecks: Bool
  var concurrentDownloads: Int
  /// The values the menu offers.
  var concurrentDownloadsRange: ClosedRange<Int>
  var libraryPath: String
}

// MARK: - Storage and About

/// Settings › Storage: sizes, the managed-files folder and the troubleshooting switches.
struct StorageState: Equatable, Sendable {
  var shaderCacheBytes: UInt64
  /// The size of the active log file.
  var logBytes: UInt64
  var userAssetsPath: String
  /// Bytes the last cache purge released: nil when none has run this session, which is a different
  /// answer from zero, "nothing to release".
  var userAssetsReleasedBytes: UInt64?
  var verboseLogging: Bool
  var inspectsWebWallpapers: Bool

  /// A zero or missing size has nothing to clear.
  var canClearShaderCache: Bool { shaderCacheBytes > 0 }
  var canClearLogs: Bool { logBytes > 0 }

  /// "Last clear released 1.2 MB.", nil until a purge has run (and "0 B" after one that found nothing).
  @MainActor func lastClearNote(locale: Locale = .current) -> String? {
    guard let released = userAssetsReleasedBytes else { return nil }
    return L("Last clear released \(ByteSize.format(Double(released), locale: locale)).")
  }
}

struct AboutInfo: Equatable, Sendable {
  /// `CFBundleShortVersionString`.
  var version: String
  var gitRevision: String
  var bridgeVersion: String
  var coreVersion: String
  var shaderVersion: String
}

/// A size as Storage and Backup print it: bytes under 1,024, then base 1024 in KB, MB, GB and TB with
/// at most one fraction digit, in `locale`. `ByteCountFormatter` cannot stand in: it prints "bytes"
/// and "Zero KB".
enum ByteSize {
  /// Zero is "0 B". A figure that is not a number is "Unavailable".
  @MainActor static func format(_ value: Double, locale: Locale = .current) -> String {
    guard value.isFinite else { return L("Unavailable") }
    return text(value, locale: locale)
  }

  /// The same, but empty for a figure that is not a size (negative or not a number).
  static func text(_ value: Double, locale: Locale = .current) -> String {
    guard value.isFinite, value >= 0 else { return "" }
    if value < 1024 { return "\(Int(value)) B" }
    let units = ["KB", "MB", "GB", "TB"]
    var size = value / 1024
    var unit = 0
    while size >= 1024, unit < units.count - 1 {
      size /= 1024
      unit += 1
    }
    let number = size.formatted(
      .number.rounded(rule: .toNearestOrAwayFromZero).precision(.fractionLength(0...1)).locale(locale))
    return "\(number) \(units[unit])"
  }
}

// MARK: - Backup

/// The Backup group: which of its four states the restore row is in, and the words of a previewed package.
struct BackupPresentation: Equatable {
  /// A package the user previewed and has not confirmed.
  struct Preview: Equatable, Sendable {
    var name: String
    var createdAt: Date
    var wallpaperCount: Int
    var presetCount: Int
    var collectionCount: Int
    var includesLibrary: Bool
    var byteCount: Int64
    /// Items that exist here and in the package.
    var conflicts: [String]
    var warnings: [String]

    init(_ preview: WallpaperBackupPreview) {
      name = preview.name
      createdAt = preview.createdAt
      wallpaperCount = preview.wallpaperCount
      presetCount = preview.presetCount
      collectionCount = preview.collectionCount
      includesLibrary = preview.includesLibrary
      byteCount = preview.byteCount
      conflicts = preview.conflicts.filter { !$0.isEmpty }
      warnings = preview.warnings.filter { !$0.isEmpty }
    }

    /// "Name · Made Oct 14, 2026 at 4:03 PM · 12.4 MB", leaving out what is missing.
    @MainActor func factsLine(locale: Locale = .current) -> String {
      var facts = [String]()
      if !name.isEmpty { facts.append(name) }
      let made = createdAt.formatted(
        Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale))
      facts.append(L("Made \(made)"))
      let size = ByteSize.text(Double(byteCount), locale: locale)
      if !size.isEmpty { facts.append(size) }
      return facts.joined(separator: " · ")
    }

    /// "3 wallpapers · 1 preset · 2 collections · no wallpaper files".
    @MainActor var countsLine: String {
      [
        wallpaperCount == 1 ? L("\(wallpaperCount) wallpaper") : L("\(wallpaperCount) wallpapers"),
        presetCount == 1 ? L("\(presetCount) preset") : L("\(presetCount) presets"),
        collectionCount == 1
          ? L("\(collectionCount) collection") : L("\(collectionCount) collections"),
        includesLibrary ? L("wallpaper library included") : L("no wallpaper files"),
      ].joined(separator: " · ")
    }
  }

  /// What the Restore row offers: a restore waiting for the next launch, a package to confirm, or the
  /// way to choose one, in that order of precedence. The progress row is separate (`isBusy`) and
  /// shows above the Restore row while an operation runs.
  enum RestoreStage: Equatable {
    case pendingRestore
    case preview(Preview)
    case idle
  }

  /// An operation is running, including while one of its file panels is open, so Cancel shows then.
  var isBusy: Bool
  /// A confirmed restore is staged and applies at the next launch.
  var hasPendingRestore: Bool
  var preview: Preview?
  /// The result of the last operation; shown as a notice once it is not working any more.
  var status: String?
  var error: String?

  var restoreStage: RestoreStage {
    if hasPendingRestore { return .pendingRestore }
    if let preview { return .preview(preview) }
    return .idle
  }

  /// Export, Choose backup and Restore wait for the operation and for a pending restore.
  var canStartOperation: Bool { !isBusy && !hasPendingRestore }

  /// What the progress row says while working.
  @MainActor var workingText: String { status ?? L("Working…") }
}
