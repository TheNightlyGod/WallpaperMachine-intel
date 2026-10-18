import SwiftUI

/// A short choice of a Settings page shown as segments, for one setting: Quick Settings' Quality,
/// On battery and Covered. It follows the same editing rules as the menu of the same setting, and
/// shares its key, so the segments and the row's menu always agree.
struct SettingsSegmentsControl<Value: Hashable>: View {
  let key: String
  let saved: Value
  let options: [SettingsMenuOption<Value>]
  var waitsForMac = true
  let perform: @MainActor (Value) async throws -> Void

  @Environment(PanelController.self) private var controller

  var body: some View {
    let settings = controller.settings
    SettingsSegmentedControl(
      segments: options.map { .init(value: $0.value, title: $0.title) },
      selection: settings.value(key, saved: saved),
      isEnabled: !(waitsForMac && settings.isLocked(key))
    ) { value in
      settings.commit(key, to: value, perform: perform)
    }
  }
}
