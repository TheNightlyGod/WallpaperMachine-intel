import SwiftUI

/// A disclosure row whose contents are whole groups, laid out below the row as ordinary cards when
/// it opens rather than inside it: Performance's Advanced.
///
/// What is open is kept by the settings model like every disclosure, and a search opens it when
/// something inside matches and folds it away, title and all, when nothing does
/// (`SettingsSearch`).
struct SettingsGroupDisclosure<Content: View>: View {
  let item: SettingsItem
  let content: Content

  @Environment(PanelController.self) private var controller
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  init(_ item: SettingsItem, @ViewBuilder content: () -> Content) {
    self.item = item
    self.content = content()
  }

  var body: some View {
    let settings = controller.settings
    if settings.search.shows(item) {
      let isOpen = settings.isOpen(item)
      VStack(alignment: .leading, spacing: 22) {
        PanelCard {
          SettingsDisclosureHeader(
            title: settings.text(item.title), note: item.note.map(settings.text), isOpen: isOpen,
            minHeight: 44, identifier: item.id
          ) {
            settings.setOpen(!isOpen, for: item)
          }
          .accessibilityAddTraits(isOpen ? .isSelected : [])
        }
        if isOpen { content }
      }
      .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isOpen)
    }
  }
}
