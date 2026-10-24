import Foundation

/// The switches of Settings, by name. A Quick Settings tile and the full row of the same setting
/// name the same key, so both read one saved value, both show one draft and both send through one
/// typed setter: pressing either moves the other.
enum SettingsSwitchKey: String, CaseIterable, Sendable {
  case launchAtLogin, hideAfterActivating
  case writeDesktopPicture, refreshDesktopPicture, keepWindowsOnWallpaperClick, livePropertyEdits
  case lockScreenEnabled, screenSaverEnabled
  case wallpapersMuted, playOnlyOnActiveDisplay
  case sceneOptimization, sceneOnDemand, sceneVideoPlaneSampling
  /// Different wallpaper for each desktop, on the display the Library applies wallpapers to: the
  /// same switch as that display's card in Settings › Displays and the toolbar's display menu.
  case desktopWallpapers
}

/// What the Settings views read and send beyond the typed values: the saved state of a switch, the
/// rule that decides whether it can be pressed at all, and the setter it calls. Computed or
/// delegating only; the setters and the values are `PanelController+Settings`.
extension PanelController {
  /// The value the stores report for `key` right now, without any draft.
  func isSwitchOn(_ key: SettingsSwitchKey) -> Bool {
    switch key {
    case .launchAtLogin: generalSettings.launchAtLogin.isOn
    case .hideAfterActivating: generalSettings.hidesAfterActivating
    case .writeDesktopPicture: desktopSettings.writesDesktopPicture
    case .refreshDesktopPicture: desktopSettings.refreshesDesktopPicture
    case .keepWindowsOnWallpaperClick: desktopSettings.keepsWindowsOnWallpaperClick
    case .livePropertyEdits: desktopSettings.livePropertyEdits
    case .lockScreenEnabled: lockScreenState.isRequested
    case .screenSaverEnabled: screenSaverState.isRequested
    case .wallpapersMuted:
      { _ = revisions.playback; return playback.wallpapersMuted }()
    case .playOnlyOnActiveDisplay:
      { _ = revisions.playback; return playback.playsOnlyOnActiveDisplay }()
    case .sceneOptimization: store.settingsSnapshot.sceneOptimizationEnabled
    case .sceneOnDemand: store.settingsSnapshot.sceneOnDemandEnabled
    case .sceneVideoPlaneSampling: store.settingsSnapshot.sceneVideoPlaneSamplingEnabled
    case .desktopWallpapers: automationState(for: targetDisplayID).mode == .spaces
    }
  }

  /// Whether the setting can be changed at all, apart from the Mac being busy: a login item outside
  /// Applications, a desktop picture the animated lock screen owns, a refresh that depends on the
  /// picture being written, a lock screen or screen saver the Mac cannot offer or is changing.
  func isSwitchEnabled(_ key: SettingsSwitchKey) -> Bool {
    switch key {
    case .launchAtLogin: generalSettings.launchAtLogin.isAvailable
    case .writeDesktopPicture: desktopSettings.canChangeWritesDesktopPicture
    case .refreshDesktopPicture: desktopSettings.canChangeRefresh
    case .lockScreenEnabled: lockScreenState.isSwitchEnabled
    case .screenSaverEnabled: screenSaverState.isSwitchEnabled
    case .desktopWallpapers: canSwitchDesktopWallpapers
    default: true
    }
  }

  /// Whether the target display can have a different wallpaper for each desktop switched now: an
  /// enabled display of its own, and, to turn it on, desktop information to go by. The rows of its
  /// card in Settings › Displays follow the same rule.
  var canSwitchDesktopWallpapers: Bool {
    guard let target = targetDisplay, target.isEnabled, !target.isMirror else { return false }
    let state = automationState(for: target.id)
    return state.mode == .spaces || state.spacesAvailable
  }

  /// Sends the value to the typed setter of `key`. Queued like every setting.
  func setSwitch(_ key: SettingsSwitchKey, to on: Bool) async throws {
    switch key {
    case .launchAtLogin: try await setLaunchAtLogin(on)
    case .hideAfterActivating: try await setHidesAfterActivating(on)
    case .writeDesktopPicture: try await setWritesDesktopPicture(on)
    case .refreshDesktopPicture: try await setRefreshesDesktopPicture(on)
    case .keepWindowsOnWallpaperClick: try await setKeepsWindowsOnWallpaperClick(on)
    case .livePropertyEdits: try await setLivePropertyEdits(on)
    case .lockScreenEnabled: try await setLockScreenEnabled(on)
    case .screenSaverEnabled: try await setScreenSaverEnabled(on)
    case .wallpapersMuted: try await setWallpapersMuted(on)
    case .playOnlyOnActiveDisplay: try await setPlaysOnlyOnActiveDisplay(on)
    case .sceneOptimization: try await setSceneOptimization(on)
    case .sceneOnDemand: try await setSceneOnDemand(on)
    case .desktopWallpapers: try await setDesktopWallpapers(on, display: targetDisplayID)
    case .sceneVideoPlaneSampling: try await setSceneVideoPlaneSampling(on)
    }
  }
}

extension SettingsModel {
  /// What a switch shows: the value it just sent while that change is on its way, else the stores'.
  func isOn(_ key: SettingsSwitchKey) -> Bool { value(key.rawValue, saved: controller.isSwitchOn(key)) }

  /// Presses a switch: it shows the new value at once and the change runs queued. A press while the
  /// switch's own change is still running is ignored.
  @discardableResult
  func set(_ key: SettingsSwitchKey, to on: Bool) -> Task<Void, Never>? {
    commit(key.rawValue, to: on) { [controller] on in try await controller.setSwitch(key, to: on) }
  }

  /// Whether a switch cannot be pressed now: it is unavailable by its own rule, or the Mac is busy.
  func isDisabled(_ key: SettingsSwitchKey) -> Bool {
    !controller.isSwitchEnabled(key) || isLocked(key.rawValue)
  }
}

// MARK: - Words for the choices

/// The menu entries of the playback and power choices. The words are the web panel's; each reads the
/// panel language, so a menu that calls them changes with it.
extension DesktopCoveredAction {
  @MainActor var title: String {
    switch self {
    case .pause: L("Pause")
    case .keepRunning: L("Keep running")
    }
  }
}

extension OtherAudioAction {
  @MainActor var title: String {
    switch self {
    case .keepRunning: L("Keep running")
    case .mute: L("Mute")
    case .pause: L("Pause")
    }
  }
}

extension DisplaySleepAction {
  @MainActor var title: String {
    switch self {
    case .pause: L("Pause")
    case .stop: L("Stop (free memory)")
    }
  }
}

extension SystemConditionAction {
  @MainActor var title: String {
    switch self {
    case .keepRunning: L("Keep running")
    case .reduceQuality: L("Reduced quality")
    case .pause: L("Pause")
    case .stop: L("Stop (free memory)")
    }
  }
}

extension BridgeBatteryMode {
  @MainActor var title: String {
    switch self {
    case .keepRunning: L("Keep running")
    case .reducedQuality: L("Reduced quality")
    case .pause: L("Pause")
    }
  }
}

extension AppRuleCondition {
  @MainActor var title: String {
    switch self {
    case .running: L("Running")
    case .frontmost: L("In front")
    }
  }
}

extension AppRuleAction {
  @MainActor var title: String {
    switch self {
    case .pause: L("Pause")
    case .mute: L("Mute")
    case .stop: L("Stop")
    }
  }
}

extension AppThemePreferences.Mode: CaseIterable {
  static let allCases: [AppThemePreferences.Mode] = [.system, .light, .dark]

  @MainActor var title: String {
    switch self {
    case .system: L("System (Auto)")
    case .light: L("Light")
    case .dark: L("Dark")
    }
  }
}

extension AppThemePreferences.Tone: CaseIterable {
  static let allCases: [AppThemePreferences.Tone] = [.neutral, .warm, .cool]

  @MainActor var title: String {
    switch self {
    case .neutral: L("Neutral")
    case .warm: L("Warm")
    case .cool: L("Cool")
    }
  }
}

extension AppThemePreferences.Icon {
  @MainActor var title: String {
    switch self {
    case .minimal: L("Minimal")
    case .day: L("Day")
    case .night: L("Night")
    }
  }
}
