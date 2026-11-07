import SwiftUI

struct ReleaseHistoryView: View {
  let releases: [AppReleaseHistory.Entry]
  @State private var language = AppReleaseHistory.Language(appLanguage: AppLanguageStore.shared.effective)

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("Release notes").font(.headline)
        Spacer(minLength: 0)
        Picker("Release notes language", selection: $language) {
          ForEach(AppReleaseHistory.Language.allCases, id: \.self) { language in
            Text(verbatim: language.name).tag(language)
          }
        }
        .labelsHidden()
        .pickerStyle(.menu)
      }
      UpdateNotesBox(releases: releases, language: language)
      Text("Release notes include up to 20 recent versions. Older changes are available on GitHub.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .onChange(of: AppLanguageStore.shared.effective) { _, value in
      language = AppReleaseHistory.Language(appLanguage: value)
    }
    .environment(\.openURL, OpenURLAction { url in ExternalLink.open(url) ? .handled : .discarded })
  }
}
