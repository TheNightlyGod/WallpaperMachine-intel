import SwiftUI

/// The toolbar pill that reports an import in progress or the outcome of the last one: while it
/// runs, its status; afterwards, how many were imported and skipped, asking for a look when
/// anything failed or it was cancelled. Pressing it opens the Import popover.
///
/// It shows on every page, and goes once the popover has been opened and closed again: the
/// outcome has been seen.
struct ImportActivityPill: View {
  /// Whether the toolbar shows the pill. The toolbar asks before it adds the item, so an idle pill
  /// leaves no gap. It stays while the popover it opened is open, so the popover keeps its anchor
  /// when the import ends.
  static func isActive(in controller: PanelController) -> Bool {
    let model = controller.library
    return model.importPill.isShown(popoverOpenedFromPill: model.importAnchor == .pill)
  }

  @Environment(PanelController.self) private var controller

  var body: some View {
    let model = controller.library
    let pill = model.importPill
    let label = pill.label
    Button {
      model.toggleImport(from: .pill)
    } label: {
      HStack(spacing: 6) {
        if pill.state.isBusy {
          ProgressRing(value: nil, lineWidth: 1.75).frame(width: 13, height: 13)
        } else {
          Image(
            systemName: pill.needsAttention ? "exclamationmark.triangle" : "checkmark.circle"
          )
          .font(.system(size: 11.5, weight: .semibold))
        }
        Text(verbatim: label).lineLimit(1)
      }
      .frame(maxWidth: 240)
    }
    .buttonStyle(.panelCapsule(isActive: pill.needsAttention || model.importAnchor == .pill))
    .popover(
      isPresented: Binding(
        get: { model.importAnchor == .pill }, set: { if !$0 { model.closeImport() } }),
      arrowEdge: .bottom
    ) {
      ImportPopover().panelPresentationLocale()
    }
    .help(label)
    .accessibilityLabel(Text(verbatim: label))
    .accessibilityIdentifier("import-pill")
  }
}
