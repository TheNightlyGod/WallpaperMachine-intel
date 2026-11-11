import SwiftUI

struct UpdateModePicker: View {
  @Environment(PanelController.self) private var controller

  var body: some View {
    Picker("Update mode", selection: Binding(
      get: { controller.updater.mode },
      set: { mode in
        controller.launch(PanelActionCoordinator.key("updateMode")) {
          try await controller.setUpdateMode(mode)
        }
      }
    )) {
      ForEach(AppUpdateMode.allCases, id: \.self) { mode in
        Text(verbatim: mode.title).tag(mode)
      }
    }
    .pickerStyle(.menu)
    .labelsHidden()
    .disabled(controller.updater.isInstallPending)
    .accessibilityIdentifier("update-mode")
  }
}
