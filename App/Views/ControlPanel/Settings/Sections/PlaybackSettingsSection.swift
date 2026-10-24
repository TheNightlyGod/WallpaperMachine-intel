import SwiftUI

/// Settings › Playback & Power: when wallpapers pause, mute or stop on their own, and how they
/// behave on battery, in Low Power Mode, when the Mac is hot, under a Focus and beside other apps.
struct PlaybackSettingsSection: View {
  private static let playback = SettingsItem.Group("playback", title: "Playback")
  private static let context = SettingsItem.Group("context")
  /// The state a search reads in the notes that name how hot the Mac is; the page shows the real one.
  private static let sampleState = "normal"

  static let muteAll = SettingsItem(
    id: "playback.mute-all", section: .playback, group: playback, title: "Mute all wallpapers",
    note:
      "Silences every wallpaper without changing their saved sound or volume. It works together with the rules below."
  )
  static let desktopCovered = SettingsItem(
    id: "playback.desktop-covered", section: .playback, group: playback,
    title: "When windows cover the desktop",
    note:
      "Covered means windows hide everything but the menu bar and the screen edges. Pause keeps the last frame there. Wallpapers you can’t see at all always pause."
  )
  static let activeDisplayOnly = SettingsItem(
    id: "playback.active-display-only", section: .playback, group: playback,
    title: "Only play on the display I’m using",
    note:
      "The display your pointer is on keeps playing. The others pause a few seconds after you leave them and resume the moment you return. Your own Play and Pause are not changed."
  )
  static let otherAudio = SettingsItem(
    id: "playback.other-audio", section: .playback, group: playback,
    title: "When another app plays sound",
    note:
      "Mute silences scene and video wallpapers, and Web wallpapers when page-output mute is available. Pause applies to every wallpaper."
  )
  static let displaySleep = SettingsItem(
    id: "playback.display-sleep", section: .playback, group: playback,
    title: "When displays sleep",
    note:
      "Stop frees renderer memory and reloads the wallpaper when the display wakes. Pause keeps it loaded."
  )
  static let batteryMode = SettingsItem(
    id: "playback.battery-mode", section: .playback, group: playback, title: "On battery",
    note:
      "Reduced quality uses the scale and frame rate below instead of your usual quality settings. Pause stops wallpapers until you plug in."
  )
  static let batteryScale = SettingsItem(
    id: "playback.battery-scale", section: .playback, group: playback,
    title: "Render scale when reduced",
    note: "Every Reduced quality choice on this page uses this render scale and frame rate.")
  static let batteryFps = SettingsItem(
    id: "playback.battery-fps", section: .playback, group: playback,
    title: "Frame rate when reduced")
  static let reducedQuality = SettingsItem(
    id: "playback.reduced-quality", section: .playback, group: playback, title: "Reduced quality",
    keywords: [
      "Your usual quality settings are in use.",
      "The Mac is hot. Reduced quality is in use.",
      "Low Power Mode is on. Reduced quality is in use.",
      "The battery is low. Reduced quality is in use.",
      "On battery. Reduced quality is in use.",
    ])
  static let lowBattery = SettingsItem(
    id: "playback.low-battery", section: .playback, group: playback,
    title: "When the battery is low",
    note:
      "Applies only while the Mac runs on battery. It ends 5 points above the level you choose, or when you plug in. The battery is at \(100)% now."
  )
  static let lowBatteryLevel = SettingsItem(
    id: "playback.low-battery-level", section: .playback, group: playback,
    title: "Low battery level")
  static let lowPowerMode = SettingsItem(
    id: "playback.low-power-mode", section: .playback, group: playback,
    title: "In Low Power Mode", note: "Low Power Mode is on now.",
    keywords: ["Low Power Mode is off now."])
  static let thermal = SettingsItem(
    id: "playback.thermal", section: .playback, group: playback, title: "When the Mac is hot",
    note:
      "Applies while macOS reports the Mac as hot or very hot, which is when it starts slowing itself down. Right now it is \(sampleState).",
    keywords: [
      "Reduced quality applies while the Mac is hot, and wallpapers pause if it becomes very hot. Right now it is \(sampleState)."
    ])
  static let focus = SettingsItem(
    id: "playback.focus", section: .playback, group: playback, title: "Focus",
    note:
      "In System Settings → Focus, add the WallpaperMachine filter to pause, mute, stop or temporarily switch wallpapers. No Focus filter is in effect now.",
    keywords: ["Open Focus Settings…"])
  static let appRules = SettingsItem(
    id: "playback.app-rules", section: .playback, group: playback, title: "App rules",
    note: "Pause, mute or stop wallpapers while a chosen app is running or in front.")
  static let addAppRule = SettingsItem(
    id: "playback.app-rules-add", section: .playback, inside: appRules, title: "Add app…",
    keywords: [
      "No app rules yet. Add an app to pause, mute or stop wallpapers while it is running or in front."
    ])
  static let whatChanges = SettingsItem(
    id: "playback.context", section: .playback, group: context,
    title: "What these settings change")

  static let items = [
    muteAll, desktopCovered, activeDisplayOnly, otherAudio, displaySleep, batteryMode, batteryScale,
    batteryFps, reducedQuality, lowBattery, lowBatteryLevel, lowPowerMode, thermal, focus, appRules,
    addAppRule, whatChanges,
  ]

  /// The rows this page leaves out now, by the rules its body draws them with: "Only play on the
  /// display I'm using" needs two displays (or is on), the reduced profile needs a Reduced quality
  /// choice, and the low-battery rows need a battery (the level also a rule that does something).
  @MainActor
  static func unofferedItems(_ controller: PanelController) -> Set<String> {
    let playback = controller.playbackSettings
    var hidden: [SettingsItem] = []
    if !playback.showsActiveDisplayOnly { hidden.append(activeDisplayOnly) }
    if !controller.qualityReport.reducedQualityChosen {
      hidden += [batteryScale, batteryFps, reducedQuality]
    }
    if !playback.showsLowBatteryRows { hidden.append(lowBattery) }
    if !playback.showsLowBatteryLevel { hidden.append(lowBatteryLevel) }
    return Set(hidden.map(\.id))
  }

  @Environment(PanelController.self) private var controller

  var body: some View {
    let playback = controller.playbackSettings
    let quality = controller.qualityReport
    SettingsPage(.playback) {
      SettingsUnavailableNotice()
      SettingsGroup(Self.playback, in: .playback) {
        SettingsRow(Self.muteAll) { SettingsSwitchControl(key: .wallpapersMuted) }
        SettingsRow(Self.desktopCovered) {
          menu(
            "desktopCoveredAction", saved: playback.desktopCoveredAction,
            options: DesktopCoveredAction.allCases.map { ($0, $0.title) }
          ) { try await controller.setDesktopCoveredAction($0) }
        }
        if playback.showsActiveDisplayOnly {
          SettingsRow(Self.activeDisplayOnly) {
            SettingsSwitchControl(key: .playOnlyOnActiveDisplay)
          }
        }
        SettingsRow(Self.otherAudio) {
          menu(
            "otherAudioAction", saved: playback.otherAudioAction,
            options: OtherAudioAction.allCases.map { ($0, $0.title) }
          ) { try await controller.setOtherAudioAction($0) }
        }
        SettingsRow(Self.displaySleep) {
          menu(
            "displaySleepAction", saved: playback.displaySleepAction,
            options: DisplaySleepAction.allCases.map { ($0, $0.title) }
          ) { try await controller.setDisplaySleepAction($0) }
        }
        SettingsRow(Self.batteryMode) {
          menu(
            "batteryMode", saved: playback.batteryMode,
            options: [BridgeBatteryMode.keepRunning, .reducedQuality, .pause].map { ($0, $0.title) }
          ) { try await controller.setBatteryMode($0) }
        }
        if quality.reducedQualityChosen {
          reducedProfileRows(playback, quality)
        }
        if playback.showsLowBatteryRows {
          SettingsRow(Self.lowBattery, note: playback.lowBatteryNote) {
            conditionMenu("lowBatteryAction", saved: playback.lowBatteryAction) {
              try await controller.setLowBatteryAction($0)
            }
          }
          if playback.showsLowBatteryLevel {
            SettingsRow(Self.lowBatteryLevel) {
              menu(
                "lowBatteryThreshold", saved: playback.lowBatteryThreshold,
                options: PlaybackPreferences.lowBatteryThresholds.map { ($0, "\($0)%") }
              ) { try await controller.setLowBatteryThreshold($0) }
            }
          }
        }
        SettingsRow(Self.lowPowerMode, note: playback.lowPowerModeNote) {
          conditionMenu("lowPowerModeAction", saved: playback.lowPowerModeAction) {
            try await controller.setLowPowerModeAction($0)
          }
        }
        SettingsRow(Self.thermal, note: playback.thermalNote) {
          conditionMenu("thermalAction", saved: playback.thermalAction) {
            try await controller.setThermalAction($0)
          }
        }
        SettingsRow(Self.focus, note: playback.focusNote) {
          SettingsActionButton(
            "Open Focus Settings…", isDisabled: controller.settings.isLocked("openFocusSettings")
          ) {
            controller.settings.perform("openFocusSettings") {
              try await controller.openFocusSettings()
            }
          }
        }
        SettingsDisclosure(Self.appRules) {
          if playback.appRules.isEmpty { PlaybackAppRulesEmptyRow() }
          ForEach(playback.appRules) { PlaybackAppRuleRow(rule: $0) }
          PlaybackAddAppRuleRow()
        }
      }
      SettingsGroup(Self.context, in: .playback) {
        SettingsDisclosure(Self.whatChanges) { context }
      }
    }
    .onAppear { controller.refreshSystemReadings() }
  }

  /// The render scale and frame rate every Reduced quality choice shares, and which reason is
  /// holding quality down now.
  @ViewBuilder
  private func reducedProfileRows(_ playback: PlaybackSettings, _ quality: QualityReport)
    -> some View
  {
    SettingsRow(Self.batteryScale) {
      menu(
        "batteryRenderScale", saved: playback.batteryRenderScale,
        options: RenderScaleChoices.options(saved: playback.batteryRenderScale).map {
          ($0.scale, $0.title)
        }
      ) { try await controller.setBatteryRenderScale(Double($0)) }
    }
    SettingsRow(Self.batteryFps) {
      HStack(spacing: 6) {
        SettingsNumberField(
          key: "batteryTargetFps", saved: playback.batteryTargetFps, range: 1...240
        ) { try await controller.setBatteryTargetFps($0) }
        // The unit is a symbol, not a word: it reads the same in every language.
        Text(verbatim: "fps").font(.system(size: 12.5)).foregroundStyle(.secondary)
          .accessibilityHidden(true)
      }
      .accessibilityElement(children: .contain)
    }
    SettingsRow(Self.reducedQuality) { SettingsStatusText(quality.statusText) }
  }

  private func menu<Value: Hashable>(
    _ key: String, saved: Value, options: [(Value, String)],
    perform: @escaping @MainActor (Value) async throws -> Void
  ) -> some View {
    SettingsMenuControl(
      key: key, saved: saved, options: options.map { SettingsMenuOption(value: $0.0, title: $0.1) },
      perform: perform)
  }

  /// Keep running, Reduced quality, Pause, Stop: what a Mac condition can ask of wallpapers.
  private func conditionMenu(
    _ key: String, saved: SystemConditionAction,
    perform: @escaping @MainActor (SystemConditionAction) async throws -> Void
  ) -> some View {
    menu(key, saved: saved, options: SystemConditionAction.allCases.map { ($0, $0.title) }, perform: perform)
  }

  /// What the settings above do, in thirteen short paragraphs.
  private var context: some View {
    SettingsProse {
      Text(
        "Wallpapers you can’t see, such as behind a full-screen app, pause on their own. When windows cover the desktop, Pause keeps the last frame and Keep running keeps it moving in the gaps."
      )
      Text(
        "With two or more displays, Only play on the display I’m using pauses the others a few seconds after your pointer leaves them."
      )
      Text(
        "When another app plays sound, Mute uses each wallpaper’s output mute channel. Web mute availability is shown in its details. Pause stops every wallpaper until that sound ends."
      )
      Text(
        "When displays sleep, Pause keeps wallpapers loaded. Stop frees renderer memory and reloads them when the display wakes."
      )
      Text(
        "On battery, Keep running leaves quality alone, Reduced quality uses the battery scale and frame rate, and Pause stops wallpapers until you plug in. None of these promises a measured power saving."
      )
      Text(
        "When the battery is low, wallpapers pause or stop once the charge falls to the level you chose, and resume when you plug in or the charge recovers."
      )
      Text(
        "App rules pause, mute or stop wallpapers while a chosen app is running or in front. Your own Play and Pause are not changed."
      )
      Text(
        "Low Power Mode, a hot Mac and a Focus filter work the same way: while they hold, wallpapers pause, mute or stop as you chose, and resume when they end. Stop frees renderer memory and reloads wallpapers afterwards."
      )
      Text(
        "In Low Power Mode, when the Mac is hot or when the battery is low, Reduced quality keeps wallpapers running at the lower render scale and frame rate instead of pausing them, and never goes above your own quality settings. If the Mac gets very hot, wallpapers pause instead. It promises no measured power saving."
      )
      Text(
        "A quality preset sets the frame-rate limit and render scale together. The frame-rate limit caps scenes and web wallpapers on every display without rewriting the frame rate saved for each wallpaper; a video plays at its own frame rate. Internal render scale sets how many pixels are rendered before the image is scaled to fit."
      )
      Text(
        "Scene render optimisation reuses work inside a scene and produces the same picture. It only affects scene wallpapers."
      )
      Text(
        "Direct video plane sampling is experimental. It skips a color conversion when a layer’s shader can handle it; otherwise the picture is produced as before."
      )
    }
  }
}
