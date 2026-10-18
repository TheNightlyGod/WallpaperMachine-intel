import SwiftUI

/// One entry of a Settings menu: the value it stands for and the words it shows.
struct SettingsMenuOption<Value: Hashable>: Identifiable {
  let value: Value
  let title: String
  var id: Value { value }
}

/// The pop-up menu of a Settings row, for one setting.
///
/// Like every Settings control it shows what it just sent until the change has run, then what the
/// stores report. It waits while the Mac is busy unless `waitsForMac` is off, which the language
/// menu uses: it changes the app, not the renderer.
struct SettingsMenuControl<Value: Hashable>: View {
  let key: String
  let saved: Value
  let options: [SettingsMenuOption<Value>]
  var isEnabled = true
  var waitsForMac = true
  var policy: PanelActionCoordinator.Policy = .dropDuplicates
  let perform: @MainActor (Value) async throws -> Void

  @Environment(PanelController.self) private var controller
  @Environment(\.settingsRow) private var row

  var body: some View {
    let settings = controller.settings
    Picker(
      selection: Binding(
        get: { settings.value(key, saved: saved) },
        set: { settings.commit(key, to: $0, policy: policy, perform: perform) })
    ) {
      ForEach(options) { option in
        Text(verbatim: option.title).tag(option.value)
      }
    } label: {
      // No label view: VoiceOver reads a pop-up's label view and its accessibility label one
      // after the other ("Language, Language"), so the menu is named by the label alone.
      EmptyView()
    }
    .pickerStyle(.menu)
    .labelsHidden()
    // Named after its row wherever it sits in the row, even inside a group of controls.
    .settingsRowAccessibility(row)
    .controlSize(.small)
    // As wide as its longest choice: a pop-up stretched across the row reads as a text field, and
    // one squeezed cuts its own value short. The row's text wraps beside it instead, and the page
    // column asks the split view for no width (`SettingsDetail`), so this never widens the window.
    .fixedSize()
    .disabled(!isEnabled || (waitsForMac && settings.isLocked(key)))
  }
}
