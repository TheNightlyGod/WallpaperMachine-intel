import SwiftUI

/// Settings › General: the interface language, how the Library plays its previews, what a click on the menu bar icon opens,
/// what happens at login and after applying a wallpaper, the way back to the welcome guide, resetting every setting, and
/// translating Workshop searches into English.
struct GeneralSettingsSection: View {
  private static let interface = SettingsItem.Group("interface", title: "Interface")
  private static let startup = SettingsItem.Group("startup", title: "Startup")
  private static let help = SettingsItem.Group("help", title: "Help")
  private static let reset = SettingsItem.Group("reset", title: "Reset")

  static let language = SettingsItem(
    id: "general.language", section: .general, group: interface, title: "Language",
    note:
      "The interface and import picker switch at once. Quit and reopen the app to switch menus and other dialogs.",
    keywords: ["System (Auto)"])
  static let libraryPreviewsOnHover = SettingsItem(
    id: "general.library-previews-on-hover", section: .general, group: interface,
    title: "Play Library previews only on hover",
    note:
      "When this is off, every Library tile on screen plays its animated preview, as in the Steam Workshop. When it is on, a tile plays only while the pointer rests on it.")
  static let statusItemClick = SettingsItem(
    id: "general.status-item-click", section: .general, group: interface,
    title: "Clicking the menu bar icon",
    note:
      "The panel shows what is playing on each display, its controls and a quick switcher. Right-click or Control-click the icon for the menu either way.",
    keywords: ["Shows the panel", "Shows the menu"])
  static let launchAtLogin = SettingsItem(
    id: "general.launch-at-login", section: .general, group: startup, title: "Launch at login",
    keywords: [
      "Move the app to Applications to enable.",
      "Allow WallpaperMachine in System Settings → General → Login Items to launch it at login.",
      "Open Login Items…",
    ])
  static let hideAfterApplying = SettingsItem(
    id: "general.hide-after-applying", section: .general, group: startup,
    title: "Hide window after applying a wallpaper")
  static let welcomeGuide = SettingsItem(
    id: "general.welcome-guide", section: .general, group: help, title: "Welcome guide",
    note: "Shown on first launch: language and appearance, Steam sign-in, preferences and tips.",
    keywords: ["Show again"])

  static let resetAll = SettingsItem(
    id: "general.reset-all", section: .general, group: reset, title: "Reset all settings",
    note:
      "Returns every setting to its default. Your library, playlists, collections, displays and sign-ins are kept.",
    keywords: ["Reset…", "Restore defaults"])

  static let items = [
    language, libraryPreviewsOnHover, statusItemClick, translateSearches, launchAtLogin, hideAfterApplying, welcomeGuide,
    resetAll,
  ]

  @Environment(PanelController.self) private var controller

  var body: some View {
    let login = controller.generalSettings.launchAtLogin
    SettingsPage(.general) {
      SettingsGroup(Self.interface, in: .general) {
        SettingsRow(Self.language) { languageMenu }
        SettingsRow(Self.libraryPreviewsOnHover) {
          SettingsSwitchControl(key: .libraryPreviewsOnHover)
        }
        SettingsRow(Self.statusItemClick) { statusItemClickMenu }
      }
      SettingsGroup(Self.translation, in: .general) { SearchTranslationSettingsRow() }
      SettingsGroup(Self.startup, in: .general) {
        SettingsRow(Self.launchAtLogin, note: login.note) {
          HStack(spacing: 10) {
            if login.showsLoginItemsButton {
              SettingsActionButton(
                "Open Login Items…",
                isDisabled: controller.settings.isLocked("openLoginItemsSettings")
              ) {
                controller.settings.perform("openLoginItemsSettings") {
                  try await controller.showLoginItemsSettings()
                }
              }
            }
            SettingsSwitchControl(key: .launchAtLogin)
          }
          .accessibilityElement(children: .contain)
        }
        SettingsRow(Self.hideAfterApplying) { SettingsSwitchControl(key: .hideAfterActivating) }
      }
      SettingsGroup(Self.help, in: .general) {
        SettingsRow(Self.welcomeGuide) {
          SettingsActionButton("Show again") { controller.shell.isWelcomeRequested = true }
        }
      }
      SettingsGroup(Self.reset, in: .general) {
        SettingsRow(Self.resetAll) {
          SettingsActionButton(
            "Reset…",
            isDisabled: controller.settings.isLocked("resetAllSettings", whileRunning: true)
          ) {
            controller.settings.perform("resetAllSettings") {
              try await controller.resetAllSettings()
            }
          }
        }
      }
    }
    .onAppear { controller.refreshSystemReadings() }
  }

  /// System (Auto), then every shipped language by its own name, which is never translated so a
  /// person can find theirs whatever the interface shows. Language belongs to the app and not the
  /// renderer, so the menu works while the Mac is busy.
  private var languageMenu: some View {
    SettingsMenuControl(
      key: "language",
      saved: controller.languagePreference?.tag ?? AppLanguageStore.systemChoice,
      options: Self.languageOptions(), waitsForMac: false
    ) { tag in
      try await controller.setLanguage(AppLanguage.named(tag))
    }
  }

  /// The menu bar panel, or the menu. It belongs to the app, not the renderer, so it works while the
  /// Mac is busy.
  private var statusItemClickMenu: some View {
    SettingsMenuControl(
      key: "statusItemClick", saved: controller.statusItemClick,
      options: Self.statusItemClickOptions(), waitsForMac: false
    ) { click in
      try await controller.setStatusItemClick(click)
    }
  }

  @MainActor
  static func statusItemClickOptions() -> [SettingsMenuOption<StatusItemClick>] {
    [
      SettingsMenuOption(value: .panel, title: L("Shows the panel")),
      SettingsMenuOption(value: .menu, title: L("Shows the menu")),
    ]
  }

  /// The menu's entries: System (Auto) first, then each shipped language under its own name.
  @MainActor
  static func languageOptions() -> [SettingsMenuOption<String>] {
    [SettingsMenuOption(value: AppLanguageStore.systemChoice, title: L("System (Auto)"))]
      + AppLanguage.supported.map { SettingsMenuOption(value: $0.tag, title: $0.name) }
  }
}
