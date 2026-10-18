import SwiftUI

/// One section's page: a header with the section's tile, name and one-line description, and the
/// groups below it.
///
/// While a search is on, the header shrinks to a small tile and the name, as the results stack the
/// matching sections one under another, and a page with nothing to show leaves the results.
///
/// A page with an action of its own (Displays' Refresh) puts it at the header's trailing edge, as
/// `accessory`; the accessory decides itself whether it shows during a search.
struct SettingsPage<Content: View, Accessory: View>: View {
  let section: SettingsSection
  @ViewBuilder var content: Content
  @ViewBuilder var accessory: Accessory

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  init(
    _ section: SettingsSection, @ViewBuilder content: () -> Content,
    @ViewBuilder accessory: () -> Accessory
  ) {
    self.section = section
    self.content = content()
    self.accessory = accessory()
  }

  var body: some View {
    let settings = controller.settings
    let searching = settings.search.isActive
    if settings.search.shows(section) {
      VStack(alignment: .leading, spacing: 22) {
        if searching {
          HStack(spacing: 8) {
            SymbolTile(systemImage: section.systemImage, color: section.tileColor, size: .small)
            Text(verbatim: settings.text(section.title))
              .font(.system(size: 15, weight: .semibold))
              .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            accessory
          }
        } else {
          HStack(spacing: 14) {
            SymbolTile(systemImage: section.systemImage, color: section.tileColor, size: .large)
            VStack(alignment: .leading, spacing: 2) {
              Text(verbatim: settings.text(section.title))
                .font(.system(size: 22, weight: .bold))
                .accessibilityAddTraits(.isHeader)
              Text(verbatim: settings.text(section.summary))
                .font(.system(size: 13))
                .foregroundStyle(theme.surface.muted.color)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            accessory
          }
          .padding(.bottom, 4)
        }
        content
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

extension SettingsPage where Accessory == EmptyView {
  init(_ section: SettingsSection, @ViewBuilder content: () -> Content) {
    self.init(section, content: content) { EmptyView() }
  }
}
