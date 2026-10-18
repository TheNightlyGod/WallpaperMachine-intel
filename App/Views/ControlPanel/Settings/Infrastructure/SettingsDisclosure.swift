import SwiftUI

/// A row of a Settings card that opens to more rows beneath it, such as App rules or Advanced.
///
/// What is open is remembered by the settings model, so it survives the page being rebuilt. A
/// search opens a disclosure that holds a match and folds an unmatched one away, with its title
/// (`SettingsSearch`).
struct SettingsDisclosure<Content: View>: View {
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
      VStack(spacing: 0) {
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
          .frame(minHeight: 36)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(item.id)
        if isOpen {
          Rectangle().fill(theme.surface.divider.color).frame(height: 0.5)
          DividedRows { content }
        }
      }
      .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isOpen)
    }
  }
}
