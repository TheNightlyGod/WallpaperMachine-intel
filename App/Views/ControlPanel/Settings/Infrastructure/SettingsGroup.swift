import SwiftUI

/// A titled card of settings rows, or an untitled one. It is drawn while any of its items is, so a
/// search never leaves an empty card.
struct SettingsGroup<Content: View>: View {
  let group: SettingsItem.Group
  let section: SettingsSection
  @ViewBuilder var content: Content

  @Environment(PanelController.self) private var controller

  init(
    _ group: SettingsItem.Group, in section: SettingsSection, @ViewBuilder content: () -> Content
  ) {
    self.group = group
    self.section = section
    self.content = content()
  }

  var body: some View {
    let settings = controller.settings
    if settings.search.shows(group, in: section) {
      VStack(alignment: .leading, spacing: 6) {
        if let title = group.title {
          Text(verbatim: settings.text(title))
            .font(.system(size: 13, weight: .semibold))
            .padding(.leading, 12)
            .accessibilityAddTraits(.isHeader)
        }
        PanelCard { content }
      }
    }
  }
}
