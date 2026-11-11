import SwiftUI

/// Wallpaper Engine's per-wallpaper options of a scene or video: colour adjustments, an image
/// filter, flip, mouse parallax and playback rate, saved per wallpaper and staged like the authored
/// properties (Apply changes keeps them, Revert undoes them). The card has its own Restore all
/// defaults, which touches nothing outside it. Absent for a web page.
struct EngineOptionsCard: View {
  let options: InspectorOptions

  @Environment(PanelController.self) private var controller

  var body: some View {
    if let rows = options.engineOptions {
      InspectorSection(
        "Wallpaper Engine options", isOpen: InspectorPolicy.engineOptionsOpenByDefault(options)
      ) {
        InspectorCardRow {
          HStack {
            Spacer(minLength: 0)
            Button {
              controller.launch(InspectorAction.restoreAllEngineOptions(options.wallpaperID)) {
                try await controller.restoreAllEngineOptions(options.wallpaperID)
              }
            } label: {
              Label("Restore all defaults", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.inspectorLink)
            .disabled(!options.canRestoreAllEngineOptions)
            .help(L("Stages the default for every Wallpaper Engine option. Revert undoes it."))
          }
        }
        ForEach(rows) { entry in
          PropertyRowView(options: options, row: entry.row, scope: .engineOption(entry.option))
        }
      }
    }
  }
}
