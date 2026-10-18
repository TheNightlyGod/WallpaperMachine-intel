import AppKit
import SwiftUI

/// What the App rules disclosure holds: a line when there are no rules, one row for each rule and a
/// row to add an app. They are rows of the disclosure itself, one after another, so each gets its
/// hairline.
///
/// A rule pauses, mutes or stops wallpapers while its app is running or in front. Its two menus
/// follow the settings model's editing rules like every other control (a draft until the change
/// has run, waiting while the Mac is busy), each under its own key.
struct PlaybackAppRulesEmptyRow: View {
  @Environment(\.panelTheme) private var theme

  var body: some View {
    Text(
      "No app rules yet. Add an app to pause, mute or stop wallpapers while it is running or in front."
    )
    .font(.system(size: 12))
    .foregroundStyle(theme.surface.muted.color)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
  }
}

/// The last row of the disclosure: choose an app to add a rule for.
struct PlaybackAddAppRuleRow: View {
  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  var body: some View {
    let settings = controller.settings
    if settings.search.shows(PlaybackSettingsSection.addAppRule) {
      HStack {
        Button {
          settings.perform("appRuleAdd") { try await controller.addAppRule() }
        } label: {
          Label("Add app…", systemImage: "plus")
            .font(.system(size: 13))
        }
        .buttonStyle(.borderless)
        .foregroundStyle(theme.accent.accent.color)
        .disabled(settings.isLocked("appRuleAdd", whileRunning: true))
        .accessibilityIdentifier(PlaybackSettingsSection.addAppRule.id)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .frame(minHeight: 36)
    }
  }
}

/// One app rule: the app, when it counts, what it does, and a way to remove it.
struct PlaybackAppRuleRow: View {
  let rule: AppRule

  @Environment(PanelController.self) private var controller

  var body: some View {
    let settings = controller.settings
    let name = rule.name.isEmpty ? rule.bundleIdentifier : rule.name
    HStack(spacing: 8) {
      PlaybackAppIcon(bundleIdentifier: rule.bundleIdentifier)
      Text(verbatim: name.isEmpty ? L("App") : name)
        .font(.system(size: 13))
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: .infinity, alignment: .leading)
      SettingsMenuControl(
        key: "rule-\(rule.id)-condition", saved: rule.condition,
        options: AppRuleCondition.allCases.map { SettingsMenuOption(value: $0, title: $0.title) }
      ) { try await controller.updateAppRule(rule.id, condition: $0) }
      .accessibilityLabel(Text(verbatim: L("Condition for \(name)")))
      SettingsMenuControl(
        key: "rule-\(rule.id)-action", saved: rule.action,
        options: AppRuleAction.allCases.map { SettingsMenuOption(value: $0, title: $0.title) }
      ) { try await controller.updateAppRule(rule.id, action: $0) }
      .accessibilityLabel(Text(verbatim: L("Action for \(name)")))
      Button {
        settings.perform("rule-\(rule.id)-remove") { try await controller.removeAppRule(rule.id) }
      } label: {
        Image(systemName: "minus.circle")
          .font(.system(size: 14))
      }
      .buttonStyle(.borderless)
      .foregroundStyle(.secondary)
      .disabled(settings.isLocked("rule-\(rule.id)-remove", whileRunning: true))
      .help(L("Remove"))
      .accessibilityLabel(Text("Remove"))
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .frame(minHeight: 40)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("playback.app-rule.\(rule.id.uuidString)")
  }
}

/// The icon of an app by its bundle identifier, found when the row appears, or a plain stand-in for
/// an app that is not installed any more.
private struct PlaybackAppIcon: View {
  let bundleIdentifier: String
  @State private var icon: NSImage?

  var body: some View {
    Group {
      if let icon {
        Image(nsImage: icon).resizable().interpolation(.high)
      } else {
        Image(systemName: "app.dashed").resizable().scaledToFit().foregroundStyle(.tertiary)
          .padding(2)
      }
    }
    .frame(width: 22, height: 22)
    .accessibilityHidden(true)
    .task(id: bundleIdentifier) {
      icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier).map {
        NSWorkspace.shared.icon(forFile: $0.path)
      }
    }
  }
}
