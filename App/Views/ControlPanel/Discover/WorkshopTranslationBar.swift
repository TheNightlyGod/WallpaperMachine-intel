import SwiftUI

/// A search typed in another language went to Steam in English: the English words it was sent as,
/// and the way to search what was typed instead. Both are the person's own words or the
/// translator's, so they are shown verbatim and never read as markup.
struct WorkshopTranslationBar: View {
  let translation: WorkshopSearchTranslation

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  var body: some View {
    let model = controller.workshopBrowser
    let searched = L("Searched in English for “\(translation.english)”")
    let asTyped = L("Search “\(translation.original)” instead")
    HStack(spacing: 8) {
      Image(systemName: "translate")
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(theme.surface.muted.color)
        .accessibilityHidden(true)
      Text(verbatim: searched)
        .foregroundStyle(theme.surface.muted.color)
        .lineLimit(1)
        .truncationMode(.tail)
        .help(searched)
      Button {
        model.searchAsTyped(translation)
      } label: {
        Text(verbatim: asTyped).lineLimit(1).truncationMode(.middle)
      }
      .buttonStyle(.panelLink)
      .help(asTyped)
      .accessibilityIdentifier("workshop-search-as-typed")
      Spacer(minLength: 0)
    }
    .font(.system(size: 12))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("workshop-search-translation")
  }
}
