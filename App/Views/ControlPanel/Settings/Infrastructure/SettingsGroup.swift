import SwiftUI

/// A titled card of settings rows, or an untitled one. It is drawn while any of its items is, so a
/// search never leaves an empty card.
///
/// A group with a control of its own (the release notes' language) puts it at the trailing edge of
/// its title line, as `accessory`.
struct SettingsGroup<Content: View, Accessory: View>: View {
  let group: SettingsItem.Group
  let section: SettingsSection
  @ViewBuilder var content: Content
  @ViewBuilder var accessory: Accessory

  @Environment(PanelController.self) private var controller

  init(
    _ group: SettingsItem.Group, in section: SettingsSection, @ViewBuilder content: () -> Content,
    @ViewBuilder accessory: () -> Accessory
  ) {
    self.group = group
    self.section = section
    self.content = content()
    self.accessory = accessory()
  }

  var body: some View {
    let settings = controller.settings
    if settings.search.shows(group, in: section) {
      VStack(alignment: .leading, spacing: 6) {
        if let title = group.title {
          HStack(spacing: 8) {
            Text(verbatim: settings.text(title))
              .font(.system(size: 13, weight: .semibold))
              .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            accessory
          }
          .padding(.leading, 12)
        }
        PanelCard { content }
      }
    }
  }
}

extension SettingsGroup where Accessory == EmptyView {
  init(_ group: SettingsItem.Group, in section: SettingsSection, @ViewBuilder content: () -> Content) {
    self.init(group, in: section, content: content) { EmptyView() }
  }
}
