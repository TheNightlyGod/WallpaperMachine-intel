import Foundation

/// The toolbar's import activity pill: when it shows and what it says, with the memory the page
/// kept so that a finished import is announced once.
///
/// The pill shows while an import runs, and after one that finished while the Import popover was
/// closed, until the user has looked: opening the popover and closing it again clears it. A report
/// that arrives while the popover is open is already being read, so it needs no pill. The popover
/// keeps showing the report it had when the store forgets it (a new import starts), so it never
/// goes blank under the reader.
///
/// A value type that its owner feeds from `PanelController.importState`: call `observe(_:popoverOpen:)`
/// whenever that changes (`onChange(of:)`) and `popoverDidClose()` when the popover closes.
struct ImportPill: Equatable {
  /// What the pill and the popover show: the store's state, with the previous report kept while the
  /// popover is open and the store has none.
  private(set) var state = LibraryImportState.idle
  /// A finished import's report that nobody has looked at.
  private(set) var isReportUnseen = false
  private var wasBusy = false

  mutating func observe(_ imports: LibraryImportState, popoverOpen: Bool) {
    if imports.isBusy {
      isReportUnseen = false
    } else if wasBusy, imports.report != nil {
      isReportUnseen = !popoverOpen
    }
    wasBusy = imports.isBusy
    var shown = imports
    if popoverOpen, !imports.isBusy, imports.report == nil, let kept = state.report {
      shown.report = kept
    }
    state = shown
  }

  /// The Import popover closed: whatever it showed has been seen.
  mutating func popoverDidClose() { isReportUnseen = false }

  /// Whether the pill is in the toolbar. `popoverOpenedFromPill` keeps it there while the popover
  /// it opened is open, so the popover's anchor does not vanish when the import ends.
  func isShown(popoverOpenedFromPill: Bool) -> Bool {
    state.isBusy || (state.report != nil && isReportUnseen) || popoverOpenedFromPill
  }

  /// The pill's text, also its help and its accessibility label.
  @MainActor
  var label: String {
    if state.isBusy { return state.status.isEmpty ? L("Importing…") : state.status }
    guard let report = state.report else { return L("Import wallpapers") }
    return report.needsAttention
      ? L("\(report.summary) · needs attention") : report.summary
  }

  /// A finished import with failures or a cancellation draws the pill in the attention colour.
  var needsAttention: Bool { !state.isBusy && state.report?.needsAttention == true }
}
