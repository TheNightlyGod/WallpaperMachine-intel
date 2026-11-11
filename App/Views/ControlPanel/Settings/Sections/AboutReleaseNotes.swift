import SwiftUI

/// Settings › About › Release notes: its own card under Updates. The newest version's notes are
/// open; the versions before it (those between this build and an available update, or the
/// manifest's history) wait behind **Earlier versions**. The menu at the title picks the notes'
/// translation for this page only, never the app's language.
struct AboutReleaseNotesGroup: View {
  @Environment(PanelController.self) private var controller
  /// The translation picked here; nil follows the app's language.
  @State private var chosen: AppReleaseHistory.Language?

  var body: some View {
    let releases = controller.updater.notesReleases
    let settings = controller.settings
    let language = chosen ?? AppReleaseHistory.Language(appLanguage: controller.effectiveLanguage)
    if let latest = releases.first {
      SettingsGroup(AboutSettingsSection.releaseNotes, in: .about) {
        if settings.search.shows(AboutSettingsSection.updateNotes) {
          ReleaseNotesEntryView(release: latest, language: language)
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .accessibilityIdentifier(AboutSettingsSection.updateNotes.id)
        }
        let earlier = Array(releases.dropFirst())
        if !earlier.isEmpty, settings.search.shows(AboutSettingsSection.earlierReleases) {
          AboutEarlierReleases(releases: earlier, language: language)
        }
      } accessory: {
        Picker("Release notes language", selection: Binding(get: { language }, set: { chosen = $0 })) {
          ForEach(AppReleaseHistory.Language.allCases, id: \.self) { language in
            Text(verbatim: language.name).tag(language)
          }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
      }
      // A new app language brings its own translation again.
      .onChange(of: controller.effectiveLanguage) { chosen = nil }
      // Notes link the versions' comparisons on GitHub; nothing else opens from here.
      .environment(\.openURL, OpenURLAction { url in ExternalLink.open(url) ? .handled : .discarded })
    }
  }
}

/// **Earlier versions**, folded by default, with the range it holds beside it.
private struct AboutEarlierReleases: View {
  let releases: [AppReleaseHistory.Entry]
  let language: AppReleaseHistory.Language

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let settings = controller.settings
    let item = AboutSettingsSection.earlierReleases
    let isOpen = settings.isOpen(item)
    VStack(spacing: 0) {
      SettingsDisclosureHeader(
        title: settings.text(item.title), note: Self.range(releases), isOpen: isOpen,
        identifier: item.id
      ) {
        settings.setOpen(!isOpen, for: item)
      }
      if isOpen {
        Rectangle().fill(theme.surface.divider.color).frame(height: 0.5)
        DividedRows {
          ForEach(releases, id: \.version.display) { release in
            ReleaseNotesEntryView(release: release, language: language)
              .padding(.horizontal, 12)
              .padding(.vertical, 12)
          }
          if let note = item.note {
            DisplaysNote(text: settings.text(note))
          }
        }
      }
    }
    .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isOpen)
  }

  /// "1.9.3", or "1.8.0 – 1.9.3" for several, oldest first.
  static func range(_ releases: [AppReleaseHistory.Entry]) -> String? {
    guard let newest = releases.first?.version.display, let oldest = releases.last?.version.display
    else { return nil }
    return newest == oldest ? newest : "\(oldest) – \(newest)"
  }
}
