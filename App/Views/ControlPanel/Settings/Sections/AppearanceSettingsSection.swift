import SwiftUI

/// Settings › Appearance: how the window looks. Every choice applies at once and changes only this
/// app's window, never a wallpaper, and none of them waits for the renderer.
///
/// While the Halloween look is on, its group comes first under the season's picture, and the tone,
/// accent and icon rows it stands in for are dimmed: their choices are kept for when it ends.
struct AppearanceSettingsSection: View {
  private static let look = SettingsItem.Group("look")
  private static let icon = SettingsItem.Group("icon")
  private static let season = SettingsItem.Group("season")
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
  static let halloween = SettingsItem(
    id: "appearance.halloween", section: .appearance, group: season, title: "Halloween look",
    note:
      "Dresses the window, its accent and the Dock icon for Halloween. Halloween week runs from October 24 to November 1.",
    keywords: ["Halloween week", "Always", "Off"])
  static let resetItem = SettingsItem(
    id: "appearance.reset", section: .appearance, group: reset, title: "Theme defaults",
    note: "Restores System, the default accent, Neutral tone, the Day icon and Halloween week.",
    keywords: ["Reset appearance"])

  static let items = [mode, tone, accent, appIcon, halloween, resetItem]

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme
  @FocusState private var focusedMode: AppThemePreferences.Mode?
  @FocusState private var focusedTone: AppThemePreferences.Tone?
  @FocusState private var focusedIcon: AppThemePreferences.Icon?
  @FocusState private var focusedHalloween: AppThemePreferences.Halloween?

  var body: some View {
    let preferences = controller.themePreferences
    let season = controller.season
    SettingsPage(.appearance) {
      if season != nil {
        if let season, controller.settings.search.isActive == false { SeasonBanner(season: season) }
        halloweenGroup(preferences.halloween, season: season)
      }
      SettingsGroup(Self.look, in: .appearance) {
        AppearanceChoiceRow(Self.mode) { modeCards(preferences.mode) }
        AppearanceChoiceRow(Self.tone) { toneCards(preferences.tone) }
          .heldBySeason(season)
        SettingsRow(Self.accent, stacked: true) { AppearanceAccentControl() }
          .heldBySeason(season)
      }
      SettingsGroup(Self.icon, in: .appearance) {
        SettingsRow(Self.appIcon, stacked: true) { iconOptions(preferences.icon) }
          .heldBySeason(season)
      }
      if season == nil {
        halloweenGroup(preferences.halloween, season: season)
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

  private func halloweenGroup(
    _ current: AppThemePreferences.Halloween, season: Season?
  ) -> some View {
    SettingsGroup(Self.season, in: .appearance) {
      AppearanceChoiceRow(Self.halloween, note: halloweenNote(current, season: season)) {
        halloweenCards(current)
      }
    }
  }

  /// While the look is on, the note says until when and that the person's own choices come back.
  private func halloweenNote(_ current: AppThemePreferences.Halloween, season: Season?) -> String? {
    guard season == .halloween else { return nil }
    return switch current {
    case .always:
      L("On all year. Your own accent, tone and Dock icon come back when you choose Halloween week or Off.")
    case .automatic, .off:
      L("On until November 1. Your own accent, tone and Dock icon come back after.")
    }
  }

  /// Halloween week shows the everyday look and the Halloween one on one diagonal, as System
  /// shows light and dark; Always shows the Halloween look and Off the everyday one.
  private func halloweenCards(_ current: AppThemePreferences.Halloween) -> some View {
    let everyday = SurfacePalette.miniature(
      tone: controller.themePreferences.tone, appearance: theme.appearance)
    let spooky = SurfacePalette.miniature(season: .halloween, appearance: theme.appearance)
    let ownAccent = AccentPalette(
      accent: controller.themePreferences.accent, appearance: theme.appearance
    ).accent.color
    let pumpkin = AccentPalette(accent: Season.halloween.accent, appearance: theme.appearance)
      .accent.color
    return HStack(spacing: 14) {
      ForEach(AppThemePreferences.Halloween.allCases, id: \.self) { choice in
        AppearanceChoiceCard(
          title: choice.title,
          miniature: choice == .always ? spooky : everyday,
          split: choice == .automatic ? spooky : nil,
          accent: choice == .always ? pumpkin : ownAccent,
          splitAccent: pumpkin,
          isSelected: choice == current
        ) {
          choose(choice)
        }
        .settingsRadioKeys(
          choice, in: AppThemePreferences.Halloween.allCases, focus: $focusedHalloween
        ) {
          choose($0)
        }
      }
    }
    .accessibilityElement(children: .contain)
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

  private func choose(_ halloween: AppThemePreferences.Halloween) {
    controller.settings.applyTheme { try controller.setThemeHalloween(halloween) }
  }
}

/// The season's horizon above its group while it is on, under a night sky: the band over the Now
/// Playing bar, at the size of a picture, with nothing to read in it.
private struct SeasonBanner: View {
  let season: Season

  @Environment(\.panelTheme) private var theme

  var body: some View {
    SeasonHorizon(season: season, style: .night)
      .frame(maxWidth: .infinity)
      .frame(height: 120)
      .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .strokeBorder(theme.surface.divider.color, lineWidth: 0.5)
      }
      .accessibilityHidden(true)
  }
}

extension View {
  /// Locks a row whose choice a season stands in for while it is on; the choice is kept. Its
  /// controls dim themselves, as every disabled control in Settings does.
  fileprivate func heldBySeason(_ season: Season?) -> some View {
    disabled(season != nil)
  }
}
