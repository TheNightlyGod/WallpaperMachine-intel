import XCTest

@testable import WallpaperMachine

/// The performance data switch round-trips through the page like any other setting, and
/// the one-time question is answered by choosing, here or in the guide.
@MainActor
final class WebPanelTelemetryTests: ControlPanelTestCase {
  private func post(_ panel: PanelFixture, _ message: String) async throws -> Any? {
    try await panel.js("return await window.webkit.messageHandlers.native.postMessage(\(message))")
  }

  func testPerformanceDataSwitchRoundTripsAndAnswersThePrompt() async throws {
    let defaults = try TemporaryDefaults.make(for: self).defaults
    let prompt = SupportPromptStore(defaults: defaults)
    try await withPanel(supportPrompt: prompt) { panel in
      let folder = FileManager.default.temporaryDirectory.appendingPathComponent("telemetry-\(UUID().uuidString)")
      defer { try? FileManager.default.removeItem(at: folder) }
      let telemetry = TelemetryService(
        preferences: TelemetryPreferences(defaults: defaults), spool: TelemetrySpool(folder: folder),
        uploader: NoUploads(), sampler: nil, sleep: { _ in throw CancellationError() })
      panel.store.telemetry = telemetry
      try await panel.finishWelcome()

      _ = try await post(panel, "{action:'setting', key:'telemetry', value:true}")
      XCTAssertTrue(telemetry.isEnabled)
      let snapshot = try await post(panel, "{action:'ready'}") as? [String: Any]
      let settings = try XCTUnwrap(snapshot?["settings"] as? [String: Any])
      XCTAssertEqual(settings["telemetry"] as? Bool, true)

      var revealed: [URL] = []
      panel.controller.revealFile = { revealed.append($0) }
      _ = try await post(panel, "{action:'telemetryShowData'}")
      let preview = try XCTUnwrap(revealed.first)
      let report = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: preview)) as? [String: Any])
      XCTAssertEqual(report["install"] as? String, telemetry.preferences.installID)

      _ = try await post(panel, "{action:'setting', key:'telemetry', value:false}")
      XCTAssertFalse(telemetry.isEnabled)
      XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
      XCTAssertNil(prompt.pendingPrompt(welcomeSeen: true, telemetryOn: false, now: Date() + 2 * 86_400),
                   "choosing in Settings answers the one-time question")
    }
  }

  /// Leaving the guide before its Preferences page leaves the question open; reaching it closes it.
  func testGuideAnswersTheQuestionOnlyIfItsSwitchWasShown() async throws {
    for shown in [false, true] {
      let prompt = SupportPromptStore(defaults: try TemporaryDefaults.make(for: self).defaults)
      try await withPanel(supportPrompt: prompt) { panel in
        _ = try await post(panel, "{action:'welcomeSeen', preferencesShown:\(shown)}")
        let pending = prompt.pendingPrompt(welcomeSeen: true, telemetryOn: false, now: Date() + 2 * 86_400)
        XCTAssertEqual(pending, shown ? nil : .telemetry)
      }
    }
  }

  private struct NoUploads: TelemetryUploading {
    func send(_ report: Data) async throws {}
    func delete(install: String) async throws {}
  }
}
