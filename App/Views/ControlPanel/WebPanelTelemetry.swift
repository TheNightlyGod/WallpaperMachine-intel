import AppKit
import Foundation

/// The controls of **Send performance data** beside its switch (docs/features/telemetry.md).
@MainActor
extension WebPanelController {
  static let telemetryDocumentPath = "blob/main/docs/features/telemetry.md"

  func performTelemetry(_ action: String, request: WebPanelRequest) async throws -> Bool {
    switch action {
    case "telemetryDetails":
      guard openSupportURL(Self.telemetryDocumentURL) else {
        throw WallpaperActionError(message: String(localized: "The link could not be opened. Please try again."))
      }
    case "telemetryShowData":
      guard let telemetry = store.telemetry, telemetry.isEnabled else { throw WebPanelRequest.invalid }
      do {
        revealFile(try telemetry.writePreview())
      } catch {
        throw WallpaperActionError(
          message: String(localized: "The data to be sent could not be written: \(error.localizedDescription)"))
      }
    default:
      return false
    }
    return true
  }

  static var telemetryDocumentURL: URL {
    AppUpdateConfiguration.repositoryURL.appendingPathComponent(telemetryDocumentPath)
  }
}
