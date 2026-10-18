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
  @Environment(\.panelTheme) private var theme
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
          Button {
            settings.setOpen(!isOpen, for: item)
          } label: {
            HStack(spacing: 8) {
              VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: settings.text(item.title)).font(.system(size: 13))
                if let note = item.note {
                  Text(verbatim: settings.text(note))
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.surface.muted.color)
                }
              }
              .frame(maxWidth: .infinity, alignment: .leading)
              Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.surface.faint.color)
                .rotationEffect(.degrees(isOpen ? 90 : 0))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier(item.id)
          .accessibilityAddTraits(isOpen ? .isSelected : [])
        }
        if isOpen { content }
      }
      .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isOpen)
    }
  }
}
