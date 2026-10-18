import SwiftUI

/// What a Settings row says in place of a control: a status the Mac reports, with an optional button
/// beside it ("Retry"). The text is the service's own wording, so it is never looked up.
struct SettingsStatusText<Accessory: View>: View {
  let text: String
  /// The tone of the words: the service's report is quiet, a failure is red.
  var isError = false
  @ViewBuilder var accessory: Accessory

  @Environment(\.panelTheme) private var theme

  var body: some View {
    HStack(spacing: 8) {
      Text(verbatim: text)
        .font(.system(size: 12.5))
        .foregroundStyle(isError ? theme.surface.danger.color : theme.surface.muted.color)
        .multilineTextAlignment(.trailing)
        .frame(maxWidth: 340, alignment: .trailing)
      accessory
    }
    // A row names its control for VoiceOver; the group takes that name and the status and the
    // button inside it keep their own.
    .accessibilityElement(children: .contain)
  }
}

extension SettingsStatusText where Accessory == EmptyView {
  init(_ text: String, isError: Bool = false) {
    self.init(text: text, isError: isError) { EmptyView() }
  }
}

/// A Settings button: small, quiet, one action ("Show again", "Open Login Items…", "Retry").
struct SettingsActionButton: View {
  let title: LocalizedStringKey
  var isDisabled = false
  let action: () -> Void

  init(_ title: LocalizedStringKey, isDisabled: Bool = false, action: @escaping () -> Void) {
    self.title = title
    self.isDisabled = isDisabled
    self.action = action
  }

  var body: some View {
    Button(title, action: action)
      .buttonStyle(.bordered)
      .controlSize(.small)
      .disabled(isDisabled)
  }
}

/// A failure a service reports under a row, in red, such as the lock screen's last error. It stays
/// until the service stops reporting it.
struct SettingsErrorLine: View {
  let message: String

  @Environment(\.panelTheme) private var theme

  var body: some View {
    Text(verbatim: message)
      .font(.system(size: 12))
      .foregroundStyle(theme.surface.danger.color)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .accessibilityLabel(Text(verbatim: message))
      .accessibilityAddTraits(.isStaticText)
  }
}

/// The notice at the top of a page whose controls need the renderer's settings, which have not
/// arrived: they are disabled until they do. Appearance and language never show it.
struct SettingsUnavailableNotice: View {
  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  var body: some View {
    if controller.settings.isUnavailable {
      Label {
        Text("Settings are unavailable. Try refreshing the library.")
      } icon: {
        Image(systemName: "exclamationmark.triangle")
      }
      .font(.system(size: 12.5))
      .foregroundStyle(theme.surface.warning.color)
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        theme.surface.warning.color.opacity(0.12),
        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
      )
      .accessibilityElement(children: .combine)
    }
  }
}

/// Explanatory paragraphs inside a disclosure, as one row: a few sentences in a quieter voice.
struct SettingsProse<Content: View>: View {
  @ViewBuilder var content: Content

  @Environment(\.panelTheme) private var theme

  var body: some View {
    VStack(alignment: .leading, spacing: 8) { content }
      .font(.system(size: 12))
      .foregroundStyle(theme.surface.muted.color)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
  }
}
