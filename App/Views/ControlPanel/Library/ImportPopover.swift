import SwiftUI

/// The Import popover: what can be imported, what to do with a wallpaper the library already
/// holds, the button that asks for the files, and, while it runs or once it has finished, how it
/// went. Two quiet notes at the foot say that the originals stay untouched and that the Dock takes
/// drops too.
///
/// Closing it never cancels anything: the import belongs to the app, and the toolbar pill carries
/// on telling how it goes.
struct ImportPopover: View {
  /// The popover's width, in every language.
  static let width: CGFloat = 320

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme

  var body: some View {
    let model = controller.library
    let state = model.importPill.state
    VStack(alignment: .leading, spacing: 14) {
      header(model)
      duplicates(model, isBusy: state.isBusy)
      actions(model, isBusy: state.isBusy)
      activity(state)
      notes
    }
    .padding(16)
    .frame(width: Self.width, alignment: .leading)
    .foregroundStyle(theme.surface.text.color)
    .accessibilityIdentifier("import-popover")
  }

  // MARK: Header

  /// The close button sits over the corner, so only the title leaves room for it and the line
  /// under it can take the whole width.
  private func header(_ model: InstalledBrowserModel) -> some View {
    HStack(alignment: .top, spacing: 10) {
      SymbolTile(systemImage: "square.and.arrow.down", color: .indigo)
      VStack(alignment: .leading, spacing: 2) {
        Text("Import wallpapers")
          .font(.system(size: 13, weight: .semibold))
          .padding(.trailing, 24)
          .accessibilityAddTraits(.isHeader)
        Text("Folders, videos, images or web pages")
          .font(.system(size: 11.5))
          .foregroundStyle(theme.surface.muted.color)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .overlay(alignment: .topTrailing) {
      Button {
        model.closeImport()
      } label: {
        Image(systemName: "xmark")
          .font(.system(size: 9, weight: .bold))
          .foregroundStyle(theme.surface.muted.color)
          .frame(width: 20, height: 20)
          .background(theme.surface.hover.color, in: Circle())
          .contentShape(Circle())
      }
      .buttonStyle(.plain)
      .help(L("Close import"))
      .accessibilityLabel(Text("Close import"))
    }
  }

  // MARK: Duplicates

  /// One grouped row: the choice's name on the left, the menu on the right. The menu's own items
  /// ("Skip duplicates", "Keep both copies", "Replace if changed") say what each one does.
  private func duplicates(_ model: InstalledBrowserModel, isBusy: Bool) -> some View {
    PanelCard {
      HStack(spacing: 8) {
        Image(systemName: "square.on.square")
          .font(.system(size: 12))
          .foregroundStyle(theme.surface.muted.color)
          .frame(width: 16)
          .accessibilityHidden(true)
        Text("Duplicates")
          .font(.system(size: 12.5))
          .fixedSize()
          .accessibilityHidden(true)
        Spacer(minLength: 8)
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
        .controlSize(.small)
        .fixedSize()
        .disabled(isBusy)
      }
      .padding(.leading, 12)
      .padding(.trailing, 8)
      .padding(.vertical, 8)
    }
  }

  // MARK: Actions

  private func actions(_ model: InstalledBrowserModel, isBusy: Bool) -> some View {
    HStack(spacing: 8) {
      Button {
        model.chooseImportFiles()
      } label: {
        Label("Choose wallpapers", systemImage: "folder")
      }
      .buttonStyle(.panelPrimary(size: .regular, expands: true))
      .disabled(isBusy || controller.isBusy(PanelActionCoordinator.key("import")))
      if isBusy {
        Button("Cancel import") { controller.cancelImport() }
          .buttonStyle(.panelCapsule)
      }
    }
  }

  // MARK: Activity

  /// The store's line is shown whenever it says something: how far the import has got while it
  /// runs, and afterwards how it ended ("Import cancelled", "Import could not finish"), above the
  /// counts and the reasons of the report.
  @ViewBuilder private func activity(_ state: LibraryImportState) -> some View {
    let report = state.isBusy ? nil : state.report
    if state.isBusy || !state.status.isEmpty || report != nil {
      VStack(alignment: .leading, spacing: 8) {
        if state.isBusy || !state.status.isEmpty {
          VStack(alignment: .leading, spacing: 6) {
            if state.isBusy {
              ProgressView().progressViewStyle(.linear)
                .accessibilityLabel(Text("Importing…"))
            }
            if !state.status.isEmpty {
              Text(verbatim: state.status)
                .font(.system(size: 11.5))
                .foregroundStyle(theme.surface.muted.color)
                .lineLimit(2)
                .textSelection(.enabled)
                .accessibilityAddTraits(.updatesFrequently)
            }
          }
        }
        if let report {
          VStack(alignment: .leading, spacing: 6) {
            Label {
              Text(verbatim: report.summary).font(.system(size: 12, weight: .semibold))
            } icon: {
              Image(
                systemName: report.needsAttention
                  ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
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
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        theme.surface.sunken.color, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
  }

  // MARK: Notes

  private var notes: some View {
    VStack(alignment: .leading, spacing: 6) {
      note("doc.on.doc", Text("The library gets its own copy; your originals stay untouched."))
      note(
        "dock.rectangle",
        Text("You can also drop them on the library, or on WallpaperMachine in the Dock."))
    }
    .padding(.top, 2)
  }

  private func note(_ symbol: String, _ text: Text) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: symbol)
        .font(.system(size: 11))
        .frame(width: 16)
        .accessibilityHidden(true)
      text
        .font(.system(size: 11))
        .textSelection(.enabled)
    }
    .foregroundStyle(theme.surface.muted.color)
  }
}
