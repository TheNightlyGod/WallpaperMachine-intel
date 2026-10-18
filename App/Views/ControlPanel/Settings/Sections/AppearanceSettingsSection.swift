import SwiftUI

/// Settings › Appearance: how the window looks. Every choice applies at once and changes only this
/// app's window, never a wallpaper, and none of them waits for the renderer.
struct AppearanceSettingsSection: View {
  private static let look = SettingsItem.Group("look")
  private static let icon = SettingsItem.Group("icon")
  private static let reset = SettingsItem.Group("reset")

  static let mode = SettingsItem(
    id: "appearance.mode", section: .appearance, group: look, title: "Appearance",
    keywords: ["System (Auto)", "Light", "Dark"])
  static let tone = SettingsItem(
    id: "appearance.tone", section: .appearance, group: look, title: "Surface tone",
    keywords: ["Neutral", "Warm", "Cool"])
  static let accent = SettingsItem(
    id: "appearance.accent", section: .appearance, group: look, title: "Accent color",
    note: "Colors buttons, links and focus rings.", keywords: ["Custom color"])
  static let appIcon = SettingsItem(
    id: "appearance.icon", section: .appearance, group: icon, title: "App icon",
    note:
      "Changes the Dock icon while the app is running. Finder and the menu bar stay unchanged.",
    keywords: ["Minimal", "Day", "Night"])
  static let resetItem = SettingsItem(
    id: "appearance.reset", section: .appearance, group: reset, title: "Theme defaults",
    note: "Restores System, the default accent, Neutral tone and the Day icon.",
    keywords: ["Reset appearance"])

  static let items = [mode, tone, accent, appIcon, resetItem]

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme
  @FocusState private var focusedMode: AppThemePreferences.Mode?
  @FocusState private var focusedTone: AppThemePreferences.Tone?
  @FocusState private var focusedIcon: AppThemePreferences.Icon?

  var body: some View {
    let preferences = controller.themePreferences
    SettingsPage(.appearance) {
      SettingsGroup(Self.look, in: .appearance) {
        AppearanceChoiceRow(Self.mode) { modeCards(preferences.mode) }
        AppearanceChoiceRow(Self.tone) { toneCards(preferences.tone) }
        SettingsRow(Self.accent, stacked: true) { AppearanceAccentControl() }
      }
      SettingsGroup(Self.icon, in: .appearance) {
        SettingsRow(Self.appIcon, stacked: true) { iconOptions(preferences.icon) }
      }
      SettingsGroup(Self.reset, in: .appearance) {
        SettingsRow(Self.resetItem) {
          SettingsActionButton("Reset appearance") {
            controller.settings.applyTheme { controller.resetTheme() }
          }
        }
      }
      if controller.settings.search.isActive == false {
        Text("Appearance changes apply right away and only affect this app’s window, not your wallpapers.")
          .font(.system(size: 11.5))
          .foregroundStyle(theme.surface.muted.color)
          .padding(.horizontal, 12)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  /// System shows both looks on one diagonal; Light and Dark show their own.
  private func modeCards(_ current: AppThemePreferences.Mode) -> some View {
    HStack(spacing: 14) {
      ForEach(AppThemePreferences.Mode.allCases, id: \.self) { mode in
        AppearanceChoiceCard(
          title: mode.title,
          miniature: SurfacePalette.miniature(tone: .neutral, appearance: mode == .dark ? .dark : .light),
          split: mode == .system ? SurfacePalette.miniature(tone: .neutral, appearance: .dark) : nil,
          isSelected: mode == current
        ) {
          choose(mode)
        }
        .settingsRadioKeys(mode, in: AppThemePreferences.Mode.allCases, focus: $focusedMode) {
          choose($0)
        }
      }
    }
    .accessibilityElement(children: .contain)
  }

  /// The tones are drawn in the look the window has now, so a Warm card reads as warm in the dark.
  private func toneCards(_ current: AppThemePreferences.Tone) -> some View {
    HStack(spacing: 14) {
      ForEach(AppThemePreferences.Tone.allCases, id: \.self) { tone in
        AppearanceChoiceCard(
          title: tone.title,
          miniature: SurfacePalette.miniature(tone: tone, appearance: theme.appearance),
          isSelected: tone == current
        ) {
          choose(tone)
        }
        .settingsRadioKeys(tone, in: AppThemePreferences.Tone.allCases, focus: $focusedTone) {
          choose($0)
        }
      }
    }
    .accessibilityElement(children: .contain)
  }

  private func iconOptions(_ current: AppThemePreferences.Icon) -> some View {
    HStack(spacing: 18) {
      ForEach(AppThemePreferences.Icon.allCases, id: \.self) { icon in
        AppearanceIconOption(icon: icon, isSelected: icon == current) {
          choose(icon)
        }
        .settingsRadioKeys(icon, in: AppThemePreferences.Icon.allCases, focus: $focusedIcon) {
          choose($0)
        }
      }
    }
    .accessibilityElement(children: .contain)
  }

  private func choose(_ mode: AppThemePreferences.Mode) {
    controller.settings.applyTheme { try controller.setThemeMode(mode) }
  }

  private func choose(_ tone: AppThemePreferences.Tone) {
    controller.settings.applyTheme { try controller.setThemeTone(tone) }
  }

  private func choose(_ icon: AppThemePreferences.Icon) {
    controller.settings.applyTheme { try controller.setThemeIcon(icon) }
  }
}
