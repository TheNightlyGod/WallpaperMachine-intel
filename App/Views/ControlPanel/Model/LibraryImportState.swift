import Foundation

/// What the import pill and its popover show about the app's import: running, its status line, and
/// the report of the one that just finished.
struct LibraryImportState: Equatable, Sendable {
  struct Report: Equatable, Sendable {
    var imported: Int
    var skipped: Int
    /// One reason for each source that could not be imported.
    var failures: [String]
    var cancelled: Bool

    /// A failure or a cancellation: the pill asks for a look.
    var needsAttention: Bool { !failures.isEmpty || cancelled }

    /// How many were imported and skipped, and that the import was cancelled when it was.
    @MainActor
    var summary: String {
      cancelled
        ? L("\(imported) imported · \(skipped) skipped · Cancelled")
        : L("\(imported) imported · \(skipped) skipped")
    }
  }

  var isBusy: Bool
  /// The store's progress line while it runs; it can outlive the run.
  var status: String
  /// The last finished import's outcome, until the next one starts.
  var report: Report?

  static let idle = LibraryImportState(isBusy: false, status: "", report: nil)
}
