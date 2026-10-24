import SwiftUI

/// Settings › Quick Settings: the switches people change most as tiles, and the three choices they
/// reach for most as segments, each leading to its full section. Every tile and segment is the
/// same setting as its full row, so the two stay in step. A choice another setting overrides right
/// now says so under its segments: Quality and On battery name the condition holding quality down,
/// and On battery also names a low-battery, Low Power Mode or heat rule that pauses or stops
/// wallpapers on battery.
struct QuickSettingsSection: View {
  // Tiles
  static let openAtLogin = SettingsItem(
    id: "quick.tile-open-at-login", section: .quick, title: "Open at Login")
  static let muteAll = SettingsItem(
    id: "quick.tile-mute-all", section: .quick, title: "Mute All")
  // The feature's noun, not the status menu's “Lock Screen” command.
  static let lockScreen = SettingsItem(
    id: "quick.tile-lock-screen", section: .quick, title: "Lock screen",
    keywords: ["Experimental"])
  static let screenSaver = SettingsItem(
    id: "quick.tile-screen-saver", section: .quick, title: "Screen Saver",
    keywords: ["Experimental"])
  static let desktopPicture = SettingsItem(
    id: "quick.tile-desktop-picture", section: .quick, title: "Desktop Picture")
  static let desktopWallpapers = SettingsItem(
    id: "quick.tile-desktop-wallpapers", section: .quick, title: "Wallpaper per Desktop",
    keywords: ["Different wallpaper for each desktop", "Spaces"])
  static let activeDisplayOnly = SettingsItem(
    id: "quick.tile-active-display-only", section: .quick, title: "Active Display Only")
  static let hideAfterApplying = SettingsItem(
    id: "quick.tile-hide-after-applying", section: .quick, title: "Hide After Applying")
  static let liveEdits = SettingsItem(
    id: "quick.tile-live-edits", section: .quick, title: "Live Edits")

  // Modules
  static let quality = SettingsItem(
    id: "quick.module-quality", section: .quick, title: "Quality",
    note: "Lower quality saves energy on every display.",
    keywords: ["Low", "Medium", "High", "Custom"])
  static let onBattery = SettingsItem(
    id: "quick.module-on-battery", section: .quick, title: "On battery",
    keywords: ["Keep running", "Reduced quality", "Pause"])
  static let covered = SettingsItem(
    id: "quick.module-covered", section: .quick, title: "When windows cover the desktop",
    keywords: ["Pause", "Keep running"])
  static let appearance = SettingsItem(
    id: "quick.module-appearance", section: .quick, title: "Appearance",
    keywords: ["System (Auto)", "Light", "Dark"])

  static let items = [
    openAtLogin, muteAll, lockScreen, screenSaver, desktopPicture, desktopWallpapers, activeDisplayOnly,
    hideAfterApplying, liveEdits, quality, onBattery, covered, appearance,
  ]

  private static let tileItems: [SettingsSwitchKey: SettingsItem] = [
    .launchAtLogin: openAtLogin, .wallpapersMuted: muteAll, .lockScreenEnabled: lockScreen,
    .screenSaverEnabled: screenSaver, .writeDesktopPicture: desktopPicture,
    .desktopWallpapers: desktopWallpapers,
    .playOnlyOnActiveDisplay: activeDisplayOnly, .hideAfterActivating: hideAfterApplying,
    .livePropertyEdits: liveEdits,
  ]

  /// What this page leaves out now, by the rules it draws them with: the Active Display Only tile
  /// (`QuickTile.tiles`) and the On battery module, which a Mac without a battery is offered only
  /// while its choice is not the default.
  @MainActor
  static func unofferedItems(_ controller: PanelController) -> Set<String> {
    let playback = controller.playbackSettings
    var hidden: [SettingsItem] = []
    if !playback.showsActiveDisplayOnly { hidden.append(activeDisplayOnly) }
    if !playback.offersBatteryMode { hidden.append(onBattery) }
    return Set(hidden.map(\.id))
  }

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  var body: some View {
    let settings = controller.settings
    let search = settings.search
    let tiles = QuickTile.tiles(for: controller) { settings.isOn($0) }.filter { tile in
      Self.tileItems[tile.key].map(search.shows) ?? false
    }
    SettingsPage(.quick) {
      SettingsUnavailableNotice()
      if !tiles.isEmpty {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 10)], spacing: 10) {
          ForEach(tiles) { tile in
            if let item = Self.tileItems[tile.key] {
              QuickTileView(
                tile: tile, title: settings.text(item.title), isLocked: settings.isLocked(tile.key.rawValue)
              ) {
                settings.set(tile.key, to: !tile.isOn)
              }
            }
          }
        }
      }
      modules
    }
    .onAppear { controller.refreshSystemReadings() }
  }

  // MARK: Modules

  @ViewBuilder
  private var modules: some View {
    let settings = controller.settings
    let search = settings.search
    let showsAny = [Self.quality, Self.onBattery, Self.covered, Self.appearance].contains(where: search.shows)
    if showsAny {
      VStack(spacing: 10) {
        if search.shows(Self.quality) {
          QuickModule(
            item: Self.quality, section: .performance, status: controller.qualityReport.inForceText
          ) {
            PerformanceQualityPresetControl()
          }
        }
        if search.shows(Self.onBattery), controller.playbackSettings.offersBatteryMode {
          QuickModule(
            item: Self.onBattery, section: .playback,
            status: controller.playbackSettings.onBatteryText(quality: controller.qualityReport)
          ) {
            SettingsSegmentsControl(
              key: "batteryMode", saved: controller.playbackSettings.batteryMode,
              options: [BridgeBatteryMode.keepRunning, .reducedQuality, .pause].map {
                SettingsMenuOption(value: $0, title: $0.title)
              }
            ) { try await controller.setBatteryMode($0) }
          }
        }
        if search.shows(Self.covered) {
          QuickModule(item: Self.covered, section: .playback) {
            SettingsSegmentsControl(
              key: "desktopCoveredAction", saved: controller.playbackSettings.desktopCoveredAction,
              options: DesktopCoveredAction.allCases.map {
                SettingsMenuOption(value: $0, title: $0.title)
              }
            ) { try await controller.setDesktopCoveredAction($0) }
          }
        }
        if search.shows(Self.appearance) {
          QuickModule(item: Self.appearance, section: .appearance) {
            SettingsSegmentedControl(
              segments: AppThemePreferences.Mode.allCases.map { .init(value: $0, title: $0.title) },
              selection: controller.themePreferences.mode
            ) { mode in
              settings.applyTheme { try controller.setThemeMode(mode) }
            }
          }
        }
      }
    }
  }
}

/// A Quick Settings module: a card with the section's tile, the name, a way into the section, the
/// short choice and an optional line under it: `status` while another setting overrides the choice,
/// which takes the place of the item's note, or the note.
private struct QuickModule<Control: View>: View {
  let item: SettingsItem
  let section: SettingsSection
  var status: String? = nil
  @ViewBuilder var control: Control

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  var body: some View {
    let settings = controller.settings
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        SymbolTile(systemImage: section.systemImage, color: section.tileColor, size: .small)
        Text(verbatim: settings.text(item.title))
          .font(.system(size: 13, weight: .semibold))
          .lineLimit(1)
        Spacer(minLength: 4)
        Button {
          settings.select(section)
        } label: {
          Image(systemName: "chevron.right")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(theme.surface.faint.color)
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("Open \(settings.text(section.title))"))
        .accessibilityLabel(Text(verbatim: L("Open \(settings.text(section.title))")))
      }
      control
        .accessibilityLabel(Text(verbatim: settings.text(item.title)))
      if let line = status ?? item.note.map(settings.text) {
        Text(verbatim: line)
          .font(.system(size: 11.5))
          .foregroundStyle(theme.surface.muted.color)
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(theme.surface.card.color, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .strokeBorder(theme.surface.divider.color, lineWidth: 0.5)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(item.id)
  }
}
