import XCTest

@testable import WallpaperMachine

/// What the About › Updates card shows and offers for each state of the updater, and the controller's
/// buttons behind it. Replaces `WebPanelController.update`'s tests
/// (`ControlPanelShellTests.testUpdateSnapshotExposesCheckDownloadAndReadyActions` and the
/// assertions `AppUpdateTests` kept).
@MainActor
final class UpdatePresentationTests: PanelTestCase {
  private func presentation(_ state: AppUpdateState) -> UpdatePresentation {
    UpdatePresentation(state: state)
  }

  private struct Row {
    var state: AppUpdateState
    var status: UpdatePresentation.Status
    var action: UpdatePresentation.Action?
    var releases: Bool
    var reveal: Bool
  }

  /// The matrix of the card: one status, at most one primary action, and which of the two secondary
  /// buttons the state shows.
  func testEachStateOffersTheRightSingleActionAndSecondaryButtons() throws {
    try pinPanelLanguageToEnglish()
    let v = "1.0.0"
    let rows: [Row] = [
      Row(state: .unsupported(currentVersion: v), status: .unsupported, action: nil, releases: true, reveal: false),
      Row(state: .idle(currentVersion: v), status: .idle, action: .checkForUpdates, releases: false, reveal: false),
      Row(state: .checking(currentVersion: v), status: .checking, action: .checkForUpdates, releases: false, reveal: false),
      Row(state: .noRelease(currentVersion: v), status: .noRelease, action: .checkForUpdates, releases: false, reveal: false),
      Row(state: .upToDate(currentVersion: v), status: .upToDate, action: .checkForUpdates, releases: false, reveal: false),
      Row(state: .available(currentVersion: v, availableVersion: "1.1.0"), status: .available, action: .downloadUpdate, releases: false, reveal: false),
      Row(state: .manual(currentVersion: v, availableVersion: "1.1.0"), status: .manual, action: nil, releases: true, reveal: false),
      Row(
        state: .downloading(currentVersion: v, availableVersion: "1.1.0", percent: 42.4, transferred: 424, total: 1000, bytesPerSecond: 10),
        status: .downloading, action: .downloadUpdate, releases: false, reveal: false),
      Row(state: .ready(currentVersion: v, availableVersion: "1.1.0"), status: .ready, action: .installUpdate, releases: false, reveal: true),
      Row(state: .preparing(currentVersion: v, availableVersion: "1.1.0"), status: .preparing, action: .cancelUpdate, releases: false, reveal: false),
      Row(
        state: .error(currentVersion: v, operation: .install, code: .permission, availableVersion: "1.1.0"),
        status: .error, action: .installUpdate, releases: true, reveal: false),
      Row(
        state: .error(currentVersion: v, operation: .install, code: .permission, availableVersion: nil),
        status: .error, action: .checkForUpdates, releases: true, reveal: false),
      Row(
        state: .error(currentVersion: v, operation: .check, code: .network, availableVersion: nil),
        status: .error, action: .checkForUpdates, releases: true, reveal: false),
      Row(
        state: .error(currentVersion: v, operation: .download, code: .verification, availableVersion: "1.1.0"),
        status: .error, action: .checkForUpdates, releases: true, reveal: false),
    ]
    for row in rows {
      let card = presentation(row.state)
      XCTAssertEqual(card.status, row.status, "\(row.state)")
      XCTAssertEqual(card.action, row.action, "\(row.state)")
      XCTAssertEqual(card.showsAction, row.action != nil, "\(row.state)")
      XCTAssertEqual(card.actionLabel.isEmpty, row.action == nil, "\(row.state)")
      XCTAssertEqual(card.showsReleases, row.releases, "\(row.state)")
      XCTAssertEqual(card.showsReveal, row.reveal, "\(row.state)")
      XCTAssertEqual(card.isBusy, row.state.isBusy, "\(row.state)")
      XCTAssertFalse(card.statusText.isEmpty, "\(row.state)")
      XCTAssertEqual(card.isActionProminent, row.status == .available || row.status == .ready, "\(row.state)")
    }
  }

  func testTheStatusAndLabelWordsOfEachState() throws {
    try pinPanelLanguageToEnglish()
    let v = "1.0.0"
    XCTAssertEqual(presentation(.idle(currentVersion: v)).statusText, "Updates not yet checked")
    XCTAssertEqual(presentation(.idle(currentVersion: v)).actionLabel, "Check for Updates")
    XCTAssertEqual(presentation(.checking(currentVersion: v)).statusText, "Checking for updates...")
    XCTAssertEqual(presentation(.upToDate(currentVersion: v)).statusText, "Up to date")
    XCTAssertEqual(presentation(.upToDate(currentVersion: v)).actionLabel, "Check Again")
    XCTAssertEqual(
      presentation(.noRelease(currentVersion: v)).statusText,
      "No published update is available yet. You can keep using this version.")
    let available = presentation(.available(currentVersion: v, availableVersion: "1.1.0"))
    XCTAssertEqual(available.statusText, "Version 1.1.0 is available from GitHub Releases.")
    XCTAssertEqual(available.actionLabel, "Download Update")
    XCTAssertEqual(
      presentation(.manual(currentVersion: v, availableVersion: "1.1.0")).statusText, available.statusText)
    let ready = presentation(.ready(currentVersion: v, availableVersion: "1.1.0"))
    XCTAssertEqual(ready.statusText, "Version 1.1.0 is ready. Restart the app to install it.")
    XCTAssertEqual(ready.actionLabel, "Restart and Install")
    XCTAssertEqual(presentation(.preparing(currentVersion: v, availableVersion: "1.1.0")).statusText, "Preparing update…")
    XCTAssertEqual(presentation(.preparing(currentVersion: v, availableVersion: "1.1.0")).actionLabel, "Cancel")
    let retryInstall = presentation(
      .error(currentVersion: v, operation: .install, code: .permission, availableVersion: "1.1.0"))
    XCTAssertEqual(retryInstall.actionLabel, "Retry installation")
    XCTAssertEqual(retryInstall.statusText, UpdatePresentation.errorText(.permission))
    let retry = presentation(.error(currentVersion: v, operation: .check, code: .network, availableVersion: nil))
    XCTAssertEqual(retry.actionLabel, "Retry")
  }

  func testDownloadingCarriesTheProgressAndRoundsThePercent() throws {
    try pinPanelLanguageToEnglish()
    let card = presentation(
      .downloading(currentVersion: "1.0.0", availableVersion: "1.1.0", percent: 42.5, transferred: 425, total: 1000, bytesPerSecond: 0))
    XCTAssertEqual(card.statusText, "Downloading version 1.1.0 — 43 percent")
    XCTAssertEqual(card.actionLabel, "Downloading 43 percent")
    XCTAssertEqual(card.download, UpdatePresentation.Download(percent: 42.5, transferred: 425, total: 1000))
    XCTAssertTrue(card.isBusy)
    XCTAssertNil(presentation(.checking(currentVersion: "1.0.0")).download, "Only a download has progress")
    XCTAssertEqual(UpdatePresentation.progressLabel, "Update download progress")
  }

  func testTheNotesAreCarriedWhetherOrNotTheReleaseIsNewer() throws {
    let notes = try XCTUnwrap(ReleaseNotes(version: "1.1.0", body: PanelUpdateClient.notesBody))
    let card = UpdatePresentation(state: .upToDate(currentVersion: "1.2.0"), notes: notes)
    XCTAssertEqual(card.notesVersion, "1.1.0")
    XCTAssertTrue(card.hasNotes)
    XCTAssertEqual(card.notes.first?.title, "Fixed")
    XCTAssertEqual(card.notes.first?.items.count, 1)

    let none = presentation(.idle(currentVersion: "1.0.0"))
    XCTAssertNil(none.notesVersion)
    XCTAssertTrue(none.notes.isEmpty)
    XCTAssertFalse(none.hasNotes)
  }

  /// A missing latest release is normal: Check Again and nothing to open or install.
  func testNoPublishedReleaseOffersOnlyCheckAgain() {
    let card = presentation(.noRelease(currentVersion: "1.0.0"))
    XCTAssertEqual(card.status, .noRelease)
    XCTAssertEqual(card.action, .checkForUpdates)
    XCTAssertFalse(card.showsReleases)
    XCTAssertFalse(card.isBusy)
  }

  /// The rate limit names the time it ends, differs from a plain network failure, and says "later"
  /// when no time is known.
  func testTheRateLimitNamesItsResetTime() throws {
    try pinPanelLanguageToEnglish()
    let reset = Date(timeIntervalSince1970: 1_900_000_000)
    let en = Locale(identifier: "en_US")
    let withTime = UpdatePresentation.errorText(.rateLimited, rateLimitedUntil: reset, locale: en)
    let time = reset.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(en))
    XCTAssertTrue(withTime.hasSuffix("Try again after \(time)."), withTime)
    XCTAssertTrue(withTime.contains("60 requests an hour"))
    XCTAssertNotEqual(withTime, UpdatePresentation.errorText(.network))
    XCTAssertTrue(UpdatePresentation.errorText(.rateLimited).hasSuffix("Try again later."))

    let card = UpdatePresentation(
      state: .error(currentVersion: "1.0.0", operation: .check, code: .rateLimited, availableVersion: nil),
      rateLimitedUntil: reset, locale: en)
    XCTAssertEqual(card.statusText, withTime)
    for code in [AppUpdateErrorCode.network, .rateLimited, .configuration, .verification, .permission, .unknown] {
      XCTAssertFalse(UpdatePresentation.errorText(code).isEmpty, "\(code)")
    }
    XCTAssertEqual(
      Set([.network, .configuration, .verification, .permission, .unknown].map { UpdatePresentation.errorText($0) }).count, 5,
      "Each failure has its own words")
  }

  // MARK: The buttons

  private func makeUpdater(
    client: PanelUpdateClient, installer: PanelUpdateInstaller, root: URL,
    scheduled: SettingsCallCounter
  ) -> AppUpdateStore {
    AppUpdateStore(
      currentVersion: "1.0.0", client: client, installer: installer,
      workspace: AppUpdateWorkspace(
        archiveURL: { _, _ in root.appendingPathComponent("update.dmg") },
        reveal: { _ in }, open: { _ in }),
      scheduleInstall: { _ in scheduled.bump() }, terminate: {})
  }

  /// check, download, then install, with Show in Finder once it is ready; the install asks first,
  /// and a panel nobody can answer never replaces the app.
  func testTheCardWalksFromCheckToDownloadToInstallAndInstallNeedsAYes() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("update-card-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let client = PanelUpdateClient()
    client.release = PanelUpdateClient.release(version: "1.1.0")
    let installer = PanelUpdateInstaller()
    let scheduled = SettingsCallCounter()
    let updater = makeUpdater(client: client, installer: installer, root: root, scheduled: scheduled)
    let panel = try makeController()
    do {
      let controller = panel.buildSettingsController(updater: updater)
      let idle = controller.updatePresentation()
      XCTAssertEqual(idle.status, .idle)
      XCTAssertEqual(idle.action, .checkForUpdates)

      try await controller.checkForUpdates()
      XCTAssertEqual(controller.updatePresentation().status, .available)
      XCTAssertEqual(controller.updatePresentation().action, .downloadUpdate)
      XCTAssertEqual(client.fetchCalls, 1)

      try await controller.downloadUpdate()
      let ready = controller.updatePresentation()
      XCTAssertEqual(ready.status, .ready)
      XCTAssertEqual(ready.action, .installUpdate)
      XCTAssertTrue(ready.showsReveal)

      // Nobody to answer (no window): the update is not installed.
      XCTAssertFalse(panel.dialogs.confirmAnswer)
      let declined = try await controller.installUpdate()
      XCTAssertFalse(declined)
      XCTAssertEqual(
        updater.state, .ready(currentVersion: "1.0.0", availableVersion: "1.1.0"),
        "Install confirmation requires an answer, so an offscreen panel must not replace the app")
      XCTAssertEqual(scheduled.count, 0, "Nothing was prepared or scheduled")
      XCTAssertEqual(installer.installCalls, 0)
      let asked = try XCTUnwrap(panel.dialogs.confirmations.last)
      XCTAssertEqual(asked.button, L("Restart and Install"))

      // The user says yes.
      panel.dialogs.confirmAnswer = true
      let accepted = try await controller.installUpdate()
      XCTAssertTrue(accepted)
      XCTAssertEqual(scheduled.count, 1, "The replacement is scheduled once the user agreed")
    } catch {
      await panel.shutdown()
      throw error
    }
    await panel.shutdown()
  }

  func testAnInstallClearsTheBannerEvenWhenTheUserSaysNo() async throws {
    try await withPanel { panel in
      panel.controller.errors.actionError = "An older failure"
      let installed = try await panel.controller.installUpdate()
      XCTAssertFalse(installed)
      XCTAssertNil(panel.controller.errors.actionError)
    }
  }

  func testAboutRevealsTheDeepLinkedSectionAndTheOtherButtonsNeverClearTheBanner() async throws {
    try await withPanel { panel in
      panel.navigation.revealSettingsSection(.about)
      XCTAssertEqual(panel.navigation.settingsSection, .about)
      XCTAssertEqual(panel.navigation.settingsSectionToken, 1)

      // A stand-in workspace: the real one would open the releases page in the person's browser.
      let opened = OpenedURLs()
      let updater = AppUpdateStore(
        currentVersion: "1.0.0", client: DisabledAppUpdateClient(),
        workspace: AppUpdateWorkspace(
          archiveURL: { _, _ in FileManager.default.temporaryDirectory.appendingPathComponent("update.dmg") },
          reveal: { _ in }, open: { opened.append($0) }))
      let controller = panel.buildSettingsController(updater: updater)
      controller.errors.actionError = "An older failure"
      try await controller.cancelUpdate()
      try await controller.openReleases()
      try await controller.revealDownloadedUpdate()
      XCTAssertEqual(opened.urls, [AppUpdateConfiguration.releasesURL])
      XCTAssertEqual(
        controller.errors.actionError, "An older failure",
        "Checking, downloading, cancelling and opening links never touch the renderer, so they leave the banner alone")
    }
  }
}

/// The addresses a stand-in workspace was asked to open.
private final class OpenedURLs: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [URL] = []
  var urls: [URL] { lock.withLock { values } }
  func append(_ url: URL) { lock.withLock { values.append(url) } }
}
