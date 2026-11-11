import SwiftUI

extension GeneralSettingsSection {
  static let translation = SettingsItem.Group("translation", title: "Translation")

  static let translateSearches = SettingsItem(
    id: "general.translate-workshop-searches", section: .general, group: translation,
    title: "Translate Workshop searches into English",
    note:
      "Steam Workshop titles and tags are mostly in English, so a search typed in Chinese, Japanese or Korean is translated on this Mac and sent in English. The Steam Workshop page shows the English words, with a way to search what you typed instead.",
    info: [
      "Portuguese searches are translated while the app is in Portuguese. Links and item ids are never translated.",
      "A language is used only once it is downloaded for translation, and nothing is downloaded until you choose one from the Download… menu. A downloaded language serves every app on this Mac.",
    ],
    keywords: ["Download…", "Translation"])
}

/// **Translate Workshop searches into English**: the switch, which languages are ready, and the
/// menu that downloads another. The languages are read when the row appears and again when the
/// app's language changes which ones it lists (the Language menu above it), and only while the
/// switch is on; turning it on, or Reset all settings, reads them too. A download starts only from
/// the menu, and the system asks first.
struct SearchTranslationSettingsRow: View {
  @Environment(PanelController.self) private var controller

  private static let downloadKey = "downloadSearchTranslationLanguage"

  var body: some View {
    let state = controller.searchTranslationSettings
    let settings = controller.settings
    let item = GeneralSettingsSection.translateSearches
    let explanation = item.note.map(settings.text) ?? ""
    SettingsRow(item, note: state.note(explanation: explanation, locale: settings.locale.locale)) {
      HStack(spacing: 10) {
        if !state.downloadable.isEmpty { downloadMenu(state.downloadable) }
        SettingsSwitchControl(key: .translateWorkshopSearches)
      }
      .accessibilityElement(children: .contain)
    }
    .task(id: controller.effectiveLanguage.tag) { controller.searchTranslation.refreshLanguages() }
  }

  /// The languages not downloaded yet, each by its own name, as the Language menu names them.
  private func downloadMenu(_ languages: [AppLanguage]) -> some View {
    Menu {
      ForEach(languages, id: \.tag) { language in
        Button {
          controller.settings.perform(Self.downloadKey) {
            try await controller.downloadSearchTranslationLanguage(language.tag)
          }
        } label: {
          Text(verbatim: language.name)
        }
      }
    } label: {
      Text("Download…")
    }
    .menuStyle(.button)
    .buttonStyle(.bordered)
    .controlSize(.small)
    .fixedSize()
    .disabled(controller.isBusy(SettingsModel.actionKey(Self.downloadKey)))
    .help(L("Download a language for translating searches"))
    .accessibilityLabel(Text("Download a language for translating searches"))
  }
}
