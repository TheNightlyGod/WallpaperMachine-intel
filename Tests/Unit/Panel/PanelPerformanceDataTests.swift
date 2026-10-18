import XCTest

@testable import WallpaperMachine

/// **Send performance data** in the native panel: the Settings switch and the report it would send,
/// the one-time question for someone who finished the guide before it had the switch, and the guide
/// answering that question. Replaces `WebPanelTelemetryTests` and the performance data half of
/// `WebPanelSupportPromptTests`.
@MainActor
final class PanelPerformanceDataTests: PanelTestCase {
  private struct NoUploads: TelemetryUploading {
    func send(_ report: Data) async throws {}
    func delete(install: String) async throws {}
  }

  /// A service that never uploads or sleeps, spooling into a folder of its own.
  private func makeTelemetry(defaults: UserDefaults) -> (TelemetryService, URL) {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("telemetry-\(UUID().uuidString)", isDirectory: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
    let telemetry = TelemetryService(
      preferences: TelemetryPreferences(defaults: defaults), spool: TelemetrySpool(folder: folder),
      uploader: NoUploads(), sampler: nil, sleep: { _ in throw CancellationError() })
    return (telemetry, folder)
  }

  private func withTelemetryPanel(
    welcomeSeen: Bool = true,
    _ body: (PanelFixture, SupportPromptStore, TelemetryService, URL) async throws -> Void
  ) async throws {
    let defaults = try TemporaryDefaults.make(for: self).defaults
    let prompt = SupportPromptStore(defaults: defaults)
    try await withPanel(supportPrompt: prompt, welcomeSeen: welcomeSeen) { panel in
      let (telemetry, folder) = makeTelemetry(defaults: defaults)
      panel.store.telemetry = telemetry
      panel.controller.openSupportURL = { _ in
        XCTFail("Unexpected external link")
        return false
      }
      try await body(panel, prompt, telemetry, folder)
    }
  }

  private func later(_ days: Double = 2) -> Date { Date() + days * 86_400 }

  // MARK: Settings

  /// The switch turns sending on and off, **Show in Finder** shows the report the next upload would
  /// send, and turning it off deletes what was collected. Choosing here answers the question.
  func testTheSwitchRoundTripsShowsTheReportAndAnswersTheQuestion() async throws {
    try await withTelemetryPanel { panel, prompt, telemetry, folder in
      let controller = panel.controller
      XCTAssertEqual(controller.performanceData, PerformanceDataState(isEnabled: false, lastSentAt: nil))

      try await controller.setSendsPerformanceData(true)
      XCTAssertTrue(telemetry.isEnabled)
      XCTAssertEqual(controller.performanceData?.isEnabled, true)

      var revealed: [URL] = []
      controller.revealPerformanceData = { revealed.append($0) }
      try await controller.showPerformanceData()
      let preview = try XCTUnwrap(revealed.first)
      let report = try XCTUnwrap(
        try JSONSerialization.jsonObject(with: Data(contentsOf: preview)) as? [String: Any])
      XCTAssertEqual(report["install"] as? String, telemetry.preferences.installID)

      try await controller.setSendsPerformanceData(false)
      XCTAssertFalse(telemetry.isEnabled)
      XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "What was collected is gone")
      XCTAssertNil(
        prompt.pendingPrompt(welcomeSeen: true, telemetryOn: false, now: later()),
        "Choosing in Settings answers the one-time question")
    }
  }

  /// With sending off there is no report to show, and without a service there is no switch.
  func testShowInFinderNeedsSendingOnAndTheSwitchNeedsAService() async throws {
    try await withTelemetryPanel { panel, _, _, _ in
      var revealed = 0
      panel.controller.revealPerformanceData = { _ in revealed += 1 }
      do {
        try await panel.controller.showPerformanceData()
        XCTFail("Nothing to show while sending is off")
      } catch is InvalidControlValue {}
      XCTAssertEqual(revealed, 0)

      panel.store.telemetry = nil
      XCTAssertNil(panel.controller.performanceData, "The switch is disabled")
      try await panel.controller.setSendsPerformanceData(true)
    }
  }

  /// **What is sent** opens the document on GitHub through the injected opener.
  func testWhatIsSentOpensTheDocument() async throws {
    try await withTelemetryPanel { panel, _, _, _ in
      var opened: [URL] = []
      panel.controller.openSupportURL = { opened.append($0); return true }
      try panel.controller.openPerformanceDataDetails()
      XCTAssertEqual(
        opened.map(\.absoluteString),
        ["https://github.com/WallpaperMachine/WallpaperMachine/blob/main/docs/features/telemetry.md"])
    }
  }

  // MARK: The one-time question

  /// Someone who finished the guide before it had the switch is asked once, ahead of the support
  /// offer, and the answer turns sending on without opening any link.
  func testAnExistingUserIsAskedOnceAndTheAnswerTurnsSendingOn() async throws {
    try await withTelemetryPanel { panel, prompt, telemetry, _ in
      prompt.recordDownload(wallpaperID: "downloaded")
      prompt.recordSuccessfulActivation(wallpaperID: "downloaded")
      let presenter = panel.controller.supportPrompt
      panel.show()
      XCTAssertEqual(panel.controller.pendingPrompt, .telemetry, "The question comes first")
      XCTAssertTrue(presenter.wantsPresentation)

      presenter.sheetDidAppear()
      XCTAssertEqual(presenter.prompt, .telemetry)
      await presenter.choose(.enableTelemetry)
      XCTAssertTrue(telemetry.isEnabled)
      XCTAssertTrue(presenter.isDismissed)
      XCTAssertFalse(presenter.wantsPresentation)
      XCTAssertNil(panel.controller.pendingPrompt, "No second prompt on the same day")
      XCTAssertEqual(
        prompt.pendingPrompt(welcomeSeen: true, telemetryOn: false, now: later()), .support,
        "The question is answered for good; the support offer waits for another day")
    }
  }

  /// The guide asks new users itself, and a run without the service has nothing to ask.
  func testTheQuestionIsNotAskedBeforeTheGuideOrWithoutAService() async throws {
    try await withTelemetryPanel(welcomeSeen: false) { panel, _, _, _ in
      panel.show()
      XCTAssertNil(panel.controller.pendingPrompt, "The guide has not been finished")
      panel.controller.markWelcomeSeen()
      XCTAssertEqual(panel.controller.pendingPrompt, .telemetry)
      panel.store.telemetry = nil
      XCTAssertNil(panel.controller.pendingPrompt)
    }
  }

  /// Not now spends the question and opens nothing.
  func testNotNowSpendsTheQuestion() async throws {
    try await withTelemetryPanel { panel, prompt, telemetry, _ in
      panel.show()
      let presenter = panel.controller.supportPrompt
      presenter.sheetDidAppear()
      await presenter.dismiss().value
      XCTAssertFalse(telemetry.isEnabled)
      XCTAssertNil(prompt.pendingPrompt(welcomeSeen: true, telemetryOn: false, now: later()))
    }
  }

  // MARK: The guide

  /// Leaving the guide before its Preferences page leaves the question open; reaching it answers
  /// it, and the page's switch is a draft that **Continue** commits.
  func testTheGuideAnswersTheQuestionOnlyOnceItsSwitchWasShownAndCommitsTheDraft() async throws {
    try await withTelemetryPanel(welcomeSeen: false) { panel, prompt, telemetry, _ in
      let model = panel.controller.welcome
      model.open()
      defer { model.close() }
      model.go(to: .performance)
      XCTAssertEqual(
        prompt.pendingPrompt(welcomeSeen: true, telemetryOn: false, now: later()), .telemetry,
        "Not yet on the page with the switch")

      model.go(to: .preferences)
      XCTAssertNil(prompt.pendingPrompt(welcomeSeen: true, telemetryOn: false, now: later()))
      XCTAssertTrue(model.canChangePerformanceData)
      model.preferences.set(.performanceData(true))
      XCTAssertFalse(telemetry.isEnabled, "A draft is not sent")
      await model.continuePreferences()
      XCTAssertNil(model.error)
      XCTAssertTrue(telemetry.isEnabled)
      XCTAssertEqual(model.step, .tips)
    }
  }
}

/// Sharing a wallpaper or the app, and the star links. Every link is built in Swift from fixed parts
/// and a Workshop id. Replaces `WebPanelSharingTests`.
@MainActor
final class PanelSharingTests: PanelTestCase {
  func testAWorkshopWallpaperIsSharedAsItsWorkshopPageWithTheAppLink() async throws {
    try await withPanel { panel in
      let share = try XCTUnwrap(panel.controller.wallpaperShare("2873461829"))
      XCTAssertEqual(
        share.url.absoluteString, "https://steamcommunity.com/sharedfiles/filedetails/?id=2873461829")
      XCTAssertTrue(share.message.contains(panel.controller.websiteURL.absoluteString))
    }
  }

  func testOnlyAWorkshopIdCanBeShared() async throws {
    try await withPanel { panel in
      for id in ["pixiv-123-p0", "image-cat", "../../etc", "https://evil.example/", ""] {
        XCTAssertNil(panel.controller.wallpaperShare(id), id)
      }
    }
  }

  func testTheAppIsSharedWithTheWebsiteInThePanelsLanguage() async throws {
    for (language, website) in [
      ("en", "https://www.wallpapermachine.app/"), ("ja", "https://www.wallpapermachine.app/"),
      ("zh-Hans", "https://www.wallpapermachine.app/zh/"),
      ("zh-Hant", "https://www.wallpapermachine.app/zh/"),
    ] {
      try await withPanel { panel in
        try panel.controller.appLanguage.set(language)
        XCTAssertEqual(panel.controller.appShare.url.absoluteString, website, language)
      }
    }
  }

  /// **Star on GitHub** in About opens the repository and means the star prompt never asks.
  func testStarringFromAboutAnswersTheStarPrompt() async throws {
    let defaults = try TemporaryDefaults.make(for: self).defaults
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let prompt = SupportPromptStore(defaults: defaults, calendar: calendar)
    prompt.recordTelemetryAsked()
    let start = Date()
    for day in 0..<6 { prompt.recordPanelUse(now: start + Double(day) * 86_400) }
    XCTAssertEqual(prompt.pendingPrompt(welcomeSeen: true, telemetryOn: true, now: start + 30 * 86_400), .star)
    try await withPanel(supportPrompt: prompt) { panel in
      var opened: [URL] = []
      panel.controller.openSupportURL = { opened.append($0); return true }
      try await panel.controller.starRepository()
      XCTAssertEqual(opened, [AppUpdateConfiguration.repositoryURL])
      XCTAssertNil(prompt.pendingPrompt(welcomeSeen: true, telemetryOn: true, now: start + 30 * 86_400))
    }
  }

  /// The star prompt's one choice opens the repository; the support offer's star also counts.
  func testTheStarPromptOpensTheRepositoryAndARefusedChoiceThrows() async throws {
    try await withPanel { panel in
      var opened: [URL] = []
      panel.controller.openSupportURL = { opened.append($0); return true }
      panel.show()
      try await panel.controller.supportPromptChoice(.star, for: .star)
      XCTAssertEqual(opened, [AppUpdateConfiguration.repositoryURL])
      do {
        try await panel.controller.supportPromptChoice(.supporter, for: .star)
        XCTFail("The star prompt offers no supporter page")
      } catch is InvalidControlValue {}
      XCTAssertEqual(opened.count, 1)
    }
  }
}
