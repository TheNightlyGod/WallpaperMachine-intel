import SwiftUI

/// The row a Settings disclosure opens and closes with: its title, an optional muted line under
/// it and the chevron that turns as it opens. `SettingsDisclosure`, `SettingsGroupDisclosure` and
/// the Displays page's `DisplaysDisclosure` draw it; each keeps its own open state and identifier.
/// VoiceOver hears whether it is open as its value.
struct SettingsDisclosureHeader: View {
  /// Untrusted or already localized text, shown verbatim.
  let title: String
  /// A short muted line under the title: the item's note or a live summary.
  var note: String?
  let isOpen: Bool
  var minHeight: CGFloat = 36
  let identifier: String
  let toggle: () -> Void

  @Environment(\.panelTheme) private var theme

  var body: some View {
    Button(action: toggle) {
      HStack(spacing: 8) {
        VStack(alignment: .leading, spacing: 2) {
          Text(verbatim: title).font(.system(size: 13))
          if let note {
            Text(verbatim: note)
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
      .frame(minHeight: minHeight)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityValue(Text(isOpen ? "Expanded" : "Collapsed"))
    .accessibilityIdentifier(identifier)
  }
}
