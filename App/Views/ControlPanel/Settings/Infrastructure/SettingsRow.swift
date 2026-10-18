import SwiftUI

/// One row of a Settings card: the title, a short note beneath it, the control at the trailing
/// edge, and an ⓘ button for the rest of a long explanation. The row is not drawn while a search
/// leaves it out.
///
/// A long note keeps its first sentence under the title and moves the rest behind the ⓘ button
/// (`SettingsNote.parts(_:)`). A note that depends on live values, such as the battery level, is
/// passed as `note` and replaces the declared one; the declared one is still what the search reads.
/// The row labels its control with the item's title for VoiceOver, gives it the lead of the note as
/// its hint, and gives itself the item's id as its accessibility identifier. The row also hands both
/// to the controls inside it (`SettingsRowContext`), so a switch or a field that sits in a group of
/// several, where the row's label names the group, still carries the row's name and hint itself.
struct SettingsRow<Control: View>: View {
  let item: SettingsItem
  let note: String?
  let stacked: Bool
  let control: Control

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme
  @State private var showsMore = false

  /// - Parameters:
  ///   - note: Replaces the item's note, for one built from live values.
  ///   - stacked: Puts the control under the text instead of beside it, for a control too wide for
  ///     the row.
  init(
    _ item: SettingsItem, note: String? = nil, stacked: Bool = false,
    @ViewBuilder control: () -> Control
  ) {
    self.item = item
    self.note = note
    self.stacked = stacked
    self.control = control()
  }

  var body: some View {
    let settings = controller.settings
    if settings.search.shows(item) {
      let title = settings.text(item.title)
      let parts = noteParts(settings)
      let details = parts.more.map { [$0] + extraInfo(settings) } ?? extraInfo(settings)
      let layout =
        stacked
        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
        : AnyLayout(HStackLayout(spacing: 12))
      layout {
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 4) {
            Text(verbatim: title).font(.system(size: 13))
            if !details.isEmpty { moreButton(title: title, details: details) }
          }
          if let lead = parts.lead {
            Text(verbatim: lead)
              .font(.system(size: 11.5))
              .foregroundStyle(theme.surface.muted.color)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        control
          .accessibilityLabel(Text(verbatim: title))
          .settingsAccessibilityHint(parts.lead)
          .environment(\.settingsRow, SettingsRowContext(title: title, hint: parts.lead))
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .frame(minHeight: 36)
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier(item.id)
    }
  }

  private func noteParts(_ settings: SettingsModel) -> (lead: String?, more: String?) {
    guard let text = note ?? item.note.map(settings.text) else { return (nil, nil) }
    let parts = SettingsNote.parts(text)
    return (parts.lead.isEmpty ? nil : parts.lead, parts.more)
  }

  private func extraInfo(_ settings: SettingsModel) -> [String] { item.info.map(settings.text) }

  private func moreButton(title: String, details: [String]) -> some View {
    Button {
      showsMore.toggle()
    } label: {
      Image(systemName: "info.circle").font(.system(size: 12))
    }
    .buttonStyle(.plain)
    .foregroundStyle(theme.surface.muted.color)
    .help(L("More about \(title)"))
    .accessibilityLabel(Text(verbatim: L("More about \(title)")))
    .popover(isPresented: $showsMore, arrowEdge: .bottom) {
      VStack(alignment: .leading, spacing: 8) {
        ForEach(details.indices, id: \.self) { index in
          Text(verbatim: details[index])
        }
      }
      .font(.system(size: 12))
      .fixedSize(horizontal: false, vertical: true)
      .frame(width: 300, alignment: .leading)
      .padding(14)
    }
  }
}

/// What a Settings row tells the controls inside it: its title, which names a control for VoiceOver,
/// and the lead of its note, which VoiceOver reads as the control's hint (the web panel's
/// `aria-label` and `aria-describedby`). Nil outside a row.
struct SettingsRowContext: Equatable {
  let title: String
  let hint: String?
}

extension EnvironmentValues {
  @Entry var settingsRow: SettingsRowContext?
}

extension View {
  /// The row's note as the control's VoiceOver hint; nothing when the row has no note.
  @ViewBuilder
  func settingsAccessibilityHint(_ hint: String?) -> some View {
    if let hint {
      accessibilityHint(Text(verbatim: hint))
    } else {
      self
    }
  }

  /// Names a control after the row it sits in and hints it with the row's note, for a control that
  /// can sit beside others in its row. Outside a row (an app rule's menus) it changes nothing, so
  /// the name the control's owner gives it stands.
  @ViewBuilder
  func settingsRowAccessibility(_ row: SettingsRowContext?) -> some View {
    if let row {
      accessibilityLabel(Text(verbatim: row.title)).settingsAccessibilityHint(row.hint)
    } else {
      self
    }
  }
}
