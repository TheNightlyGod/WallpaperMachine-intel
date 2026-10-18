import Foundation

/// The controls beside **Send performance data** in Settings › Storage › Troubleshooting
/// (docs/features/telemetry.md). The switch itself is `setSendsPerformanceData(_:)`.
extension PanelController {
  static let performanceDataDocumentPath = "blob/main/docs/features/telemetry.md"

  /// What is sent, on GitHub.
  static var performanceDataDocumentURL: URL {
    AppUpdateConfiguration.repositoryURL.appendingPathComponent(performanceDataDocumentPath)
  }

  /// The switch and its last upload; nil while this run has no telemetry service.
  var performanceData: PerformanceDataState? {
    guard let telemetry = store.telemetry else { return nil }
    return PerformanceDataState(isEnabled: telemetry.isEnabled, lastSentAt: telemetry.lastSentAt)
  }

  /// `telemetryShowData`: writes the report the next upload would send and shows it in Finder.
  func showPerformanceData() async throws {
    guard let telemetry = store.telemetry, telemetry.isEnabled else { throw InvalidControlValue() }
    try await run(.immediate) {
      let preview: URL
      do {
        preview = try telemetry.writePreview()
      } catch {
        throw WallpaperActionError(
          message: L("The data to be sent could not be written: \(error.localizedDescription)"))
      }
      revealPerformanceData(preview)
    }
  }

  /// `telemetryDetails`: the document that says what a report holds. Throws when the link cannot be
  /// opened, so the performance data question keeps the reason in its sheet.
  func openPerformanceDataDetails() throws {
    guard openSupportURL(Self.performanceDataDocumentURL) else {
      throw WallpaperActionError(message: L("The link could not be opened. Please try again."))
    }
  }
}

/// **Send performance data** as Settings shows it.
struct PerformanceDataState: Equatable, Sendable {
  var isEnabled: Bool
  var lastSentAt: Date?
}
