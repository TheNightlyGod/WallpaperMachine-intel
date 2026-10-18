import SwiftUI

/// The switch of a Settings row, bound to one `SettingsSwitchKey`.
///
/// It shows the value it just sent until the change has run (the settings model's draft), so a
/// press is seen at once and a refused one snaps back. It waits while the Mac is busy and while the
/// setting itself cannot be changed (`SettingsModel.isDisabled`). Its hidden label is the title of
/// the row it sits in, so VoiceOver names the switch even inside a group of controls.
struct SettingsSwitchControl: View {
  let key: SettingsSwitchKey

  @Environment(PanelController.self) private var controller
  @Environment(\.settingsRow) private var row

  var body: some View {
    let settings = controller.settings
    Toggle(
      isOn: Binding(get: { settings.isOn(key) }, set: { settings.set(key, to: $0) })
    ) {
      Text(verbatim: row?.title ?? "")
    }
    .toggleStyle(.switch)
    .labelsHidden()
    .settingsAccessibilityHint(row?.hint)
    .controlSize(.small)
    .disabled(settings.isDisabled(key))
  }
}
