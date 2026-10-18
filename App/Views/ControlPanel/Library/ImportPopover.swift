import SwiftUI

/// The Import popover: what an import is, what to do with a wallpaper the library already holds,
/// the button that asks for the files, and, while it runs or once it has finished, how it went.
///
/// Closing it never cancels anything: the import belongs to the app, and the toolbar pill carries
/// on telling how it goes.
struct ImportPopover: View {
  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  var body: some View {
    let model = controller.library
    let state = model.importPill.state
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Import wallpapers").font(.headline)
        Spacer(minLength: 8)
        Button {
          model.closeImport()
        } label: {
          Image(systemName: "xmark")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.secondary)
            .frame(width: 20, height: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("Close import"))
        .accessibilityLabel(Text("Close import"))
      }

      VStack(alignment: .leading, spacing: 4) {
        Text(
          "Choose wallpaper folders, videos, images or web pages. Imports copy the source files into your library and leave the originals untouched."
        )
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        Text("You can also drop them on WallpaperMachine in the Dock.")
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
      }
      .textSelection(.enabled)

      VStack(alignment: .leading, spacing: 4) {
        Text("If a wallpaper already exists")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(.secondary)
        Picker(
          selection: Binding(get: { model.importDuplicates }, set: { model.importDuplicates = $0 })
        ) {
          Text("Skip duplicates").tag(WallpaperImportService.DuplicatePolicy.skip)
          Text("Keep both copies").tag(WallpaperImportService.DuplicatePolicy.keepBoth)
          Text("Replace if changed").tag(WallpaperImportService.DuplicatePolicy.replaceChanged)
        } label: {
          Text("If a wallpaper already exists")
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .disabled(state.isBusy)
      }

      HStack(spacing: 8) {
        Button {
          model.chooseImportFiles()
        } label: {
          Label("Choose wallpapers", systemImage: "folder")
        }
        .buttonStyle(.panelPrimary)
        .disabled(state.isBusy || controller.isBusy(PanelActionCoordinator.key("import")))
        if state.isBusy {
          Button("Cancel import") { controller.cancelImport() }
            .buttonStyle(.panelCapsule)
        }
      }

      // The store's line is shown whenever it says something: how far the import has got while it
      // runs, and afterwards how it ended ("Import cancelled", "Import could not finish"), above
      // the counts and the reasons of the report.
      if state.isBusy || !state.status.isEmpty {
        VStack(alignment: .leading, spacing: 6) {
          if state.isBusy {
            ProgressView().progressViewStyle(.linear)
              .accessibilityLabel(Text("Importing…"))
          }
          if !state.status.isEmpty {
            Text(verbatim: state.status)
              .font(.system(size: 11.5))
              .foregroundStyle(.secondary)
              .lineLimit(2)
              .textSelection(.enabled)
              .accessibilityAddTraits(.updatesFrequently)
          }
        }
      }

      if let report = state.report, !state.isBusy {
        VStack(alignment: .leading, spacing: 6) {
          Label {
            Text(verbatim: report.summary).font(.system(size: 12, weight: .semibold))
          } icon: {
            Image(
              systemName: report.needsAttention ? "exclamationmark.triangle" : "checkmark.circle"
            )
            .foregroundStyle(
              report.needsAttention ? theme.surface.warning.color : theme.surface.approved.color)
          }
          ForEach(Array(report.failures.enumerated()), id: \.offset) { _, failure in
            Text(verbatim: failure)
              .font(.system(size: 11.5))
              .foregroundStyle(theme.surface.danger.color)
              .textSelection(.enabled)
          }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
      }
    }
    .padding(16)
    .frame(width: 320, alignment: .leading)
    .accessibilityIdentifier("import-popover")
  }
}
