import XCTest

@testable import WallpaperMachine

/// Settings › Storage and Library: the folders, the confirmed clears, the diagnostics export and the
/// derived storage state. Without a window every confirmation and picker answers no, so nothing is
/// ever removed or written by an offscreen panel.
@MainActor
final class PanelStorageActionsTests: PanelTestCase {
  func testFoldersAndSettingsPanesOpenThroughTheSeamAndNothingElse() async throws {
    try await withRecordingPanel { panel, bridge in
      let controller = panel.controller
      var opened = [URL]()
      controller.openSystemURL = { opened.append($0); return true }
      let logs = panel.root.appendingPathComponent("logs", isDirectory: true)
      bridge.logFolder = logs.path

      try await controller.showLibrary()
      try await controller.showLogs()
      try await controller.openFocusSettings()
      XCTAssertEqual(opened.map(\.path), [ClientPaths.libraryURL.path, logs.path, PanelController.focusSettingsURL.path])
      XCTAssertEqual(opened.last, PanelController.focusSettingsURL)
      XCTAssertEqual(controller.librarySteamSettings.libraryPath, ClientPaths.libraryURL.path)
    }
  }

  func testMovingTheLibraryNeedsAFolderAndAYesAndWaitsForTheNextLaunch() async throws {
    try await withRecordingPanel { panel, _ in
      let controller = panel.controller
      let location = controller.libraryLocation
      // Outside the fixture's home, which is the app-support folder.
      let drive = FileManager.default.temporaryDirectory.appendingPathComponent("drive-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: drive) }
      XCTAssertTrue(location.isOnThisMac)

      // Cancel in the folder picker, then No in the confirmation: nothing is prepared.
      try await controller.moveLibrary()
      XCTAssertTrue(panel.dialogs.confirmations.isEmpty)
      panel.dialogs.chosenURL = drive
      try await controller.moveLibrary()
      XCTAssertEqual(panel.dialogs.confirmations.count, 1)
      XCTAssertNil(location.pending)
      XCTAssertFalse(FileManager.default.fileExists(atPath: drive.appendingPathComponent(StorageLocation.folderName).path))

      panel.dialogs.confirmAnswer = true
      try await controller.moveLibrary()
      let pending = try XCTUnwrap(location.pending)
      XCTAssertEqual(pending.target?.path, drive.appendingPathComponent(StorageLocation.folderName).resolvingSymlinksInPath().path)
      XCTAssertFalse(location.isCopying)
      XCTAssertEqual(location.current.path, ClientPaths.storageURL.path, "this run keeps using the library where it is")

      try await controller.cancelLibraryMove()
      XCTAssertNil(location.pending)
      XCTAssertFalse(FileManager.default.fileExists(atPath: drive.appendingPathComponent(StorageLocation.folderName).path))
    }
  }

  func testAFolderThatCannotHoldTheLibraryIsRefusedBeforeAnythingIsAsked() async throws {
    try await withRecordingPanel { panel, _ in
      panel.dialogs.chosenURL = panel.root.appendingPathComponent("Library", isDirectory: true)
      panel.dialogs.confirmAnswer = true
      try FileManager.default.createDirectory(at: panel.dialogs.chosenURL!, withIntermediateDirectories: true)
      do {
        try await panel.controller.moveLibrary()
        XCTFail("a folder inside WallpaperMachine's own is refused")
      } catch is StorageMoveError {}
      XCTAssertTrue(panel.dialogs.confirmations.isEmpty)
      XCTAssertNil(panel.controller.libraryLocation.pending)
      do {
        try await panel.controller.moveLibraryToThisMac()
        XCTFail("the library is already on this Mac")
      } catch is StorageMoveError {}
    }
  }

  func testClearingTheShaderCacheAndLogsNeedsAYesAndOnlyThenReachesTheEngine() async throws {
    try pinPanelLanguageToEnglish()
    try await withRecordingPanel { panel, bridge in
      let controller = panel.controller
      panel.store.settingsSnapshot.storage = BridgeStorageStatus(
        shaderCacheSizeBytes: 4096,
        logs: BridgeLogStatus(logsRoot: "", activeSession: "", activeFile: "", activeFileSizeBytes: 512))
      XCTAssertTrue(controller.storageState.canClearShaderCache)
      XCTAssertTrue(controller.storageState.canClearLogs)

      // Without an answer nothing is cleared.
      try await controller.clearShaderCache()
      try await controller.clearLogs()
      XCTAssertEqual(bridge.clearShaderCacheCalls.count, 0)
      XCTAssertEqual(bridge.clearLogsCalls.count, 0)
      XCTAssertEqual(panel.dialogs.confirmations.count, 2)
      XCTAssertEqual(panel.dialogs.confirmations[0].title, "Clear shader cache?")
      XCTAssertEqual(panel.dialogs.confirmations[0].button, "Clear Cache")
      XCTAssertEqual(panel.dialogs.confirmations[1].title, "Clear logs?")
      XCTAssertEqual(panel.dialogs.confirmations[1].button, "Clear Logs")

      panel.dialogs.confirmAnswer = true
      try await controller.clearShaderCache()
      try await controller.clearLogs()
      XCTAssertEqual(bridge.clearShaderCacheCalls.count, 1)
      XCTAssertEqual(bridge.clearLogsCalls.count, 1)
      XCTAssertFalse(controller.storageState.canClearShaderCache, "A cleared cache has nothing left to clear")
      XCTAssertFalse(controller.storageState.canClearLogs)
    }
  }

  func testAClearClearsTheBannerEvenWhenTheUserSaysNo() async throws {
    try await withRecordingPanel { panel, _ in
      panel.controller.errors.actionError = "An older failure"
      try await panel.controller.clearLogs()
      XCTAssertNil(panel.controller.errors.actionError, "A queued action clears the banner before it asks")
    }
  }

  /// "Last clear released" tells "not run" (nil) from "nothing to release" (0).
  func testPurgingUnusedCachesIsConfirmedAndRemembersWhatItReleased() async throws {
    try pinPanelLanguageToEnglish()
    try await withRecordingPanel { panel, _ in
      let controller = panel.controller
      XCTAssertNil(controller.userAssetsReleasedBytes)
      XCTAssertNil(controller.storageState.lastClearNote(locale: Locale(identifier: "en_US")))

      try await controller.purgeUnreferencedUserAssets()
      XCTAssertNil(controller.userAssetsReleasedBytes, "Nothing was confirmed, so nothing ran")
      let asked = try XCTUnwrap(panel.dialogs.confirmations.last)
      XCTAssertEqual(asked.title, "Clear unused caches?")
      XCTAssertEqual(asked.button, "Clear Caches")

      panel.dialogs.confirmAnswer = true
      try await controller.purgeUnreferencedUserAssets()
      XCTAssertEqual(controller.userAssetsReleasedBytes, 0, "A purge that found nothing is zero, never 'not run'")
      XCTAssertEqual(
        controller.storageState.lastClearNote(locale: Locale(identifier: "en_US")),
        "Last clear released 0 B.")

      // A wallpaper folder with no manifest holds nothing the user chose, so it is released.
      let orphan = ClientPaths.userAssetsURL.appendingPathComponent("orphan", isDirectory: true)
      try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
      try Data(count: 8192).write(to: orphan.appendingPathComponent("leftover.bin"))
      try await controller.purgeUnreferencedUserAssets()
      XCTAssertGreaterThan(try XCTUnwrap(controller.userAssetsReleasedBytes), 0)
      XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
    }
  }

  func testTheDiagnosticsReportIsWrittenOnlyToAChosenDestinationAndThenShownInFinder() async throws {
    try await withRecordingPanel { panel, bridge in
      let controller = panel.controller
      let logs = panel.root.appendingPathComponent("logs", isDirectory: true)
      try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
      bridge.logFolder = logs.path
      var revealed = [URL]()
      controller.revealDiagnosticsReport = { revealed.append($0) }

      try await controller.exportDiagnostics()
      XCTAssertTrue(revealed.isEmpty, "A cancelled save panel writes and shows nothing")
      let panelUsed = try XCTUnwrap(panel.dialogs.panels.last)
      XCTAssertEqual(panelUsed.allowedContentTypes.map(\.identifier), ["public.zip-archive"])
      XCTAssertFalse(panelUsed.nameFieldStringValue.isEmpty)

      let destination = panel.root.appendingPathComponent("report.zip")
      panel.dialogs.chosenURL = destination
      try await controller.exportDiagnostics()
      XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
      XCTAssertEqual(revealed, [destination])
    }
  }

  // MARK: Storage state

  func testTheStorageStateReadsSizesAndPathsFromTheSettings() async throws {
    try await withRecordingPanel { panel, _ in
      panel.store.settingsSnapshot = BridgeSnapshotFixtures.settings(userAssetsPath: "/Users/someone/UserAssets")
      let empty = panel.controller.storageState
      XCTAssertEqual(empty.userAssetsPath, "/Users/someone/UserAssets")
      XCTAssertFalse(empty.canClearShaderCache, "A zero size has nothing to clear")
      XCTAssertFalse(empty.canClearLogs)
      XCTAssertNil(empty.userAssetsReleasedBytes, "No purge has run; that is not the answer of a purge that released nothing")
      XCTAssertFalse(empty.verboseLogging)

      panel.store.settingsSnapshot.verboseLogging = true
      XCTAssertTrue(panel.controller.storageState.verboseLogging)
      panel.controller.userAssetsReleasedBytes = 0
      XCTAssertEqual(panel.controller.storageState.userAssetsReleasedBytes, 0)
    }
  }

  func testDetailedLoggingReachesTheEngine() async throws {
    try await withRecordingPanel { panel, bridge in
      try await panel.controller.setVerboseLogging(true)
      XCTAssertEqual(bridge.verboseLoggingCalls, [true])
      XCTAssertTrue(panel.controller.storageState.verboseLogging)
    }
  }

  func testTheAboutInfoCarriesTheBuildFacts() async throws {
    try await withRecordingPanel { panel, _ in
      panel.store.settingsSnapshot.gitSha = "abc1234"
      panel.store.settingsSnapshot.bridgeVersion = "b1"
      panel.store.settingsSnapshot.coreVersion = "c2"
      panel.store.settingsSnapshot.shaderPipelineVersion = "s3"
      let about = panel.controller.aboutInfo
      XCTAssertEqual(about.gitRevision, "abc1234")
      XCTAssertEqual([about.bridgeVersion, about.coreVersion, about.shaderVersion], ["b1", "c2", "s3"])
      XCTAssertEqual(
        about.version, Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
    }
  }

  func testSizesPrintTheWayStorageAlwaysDid() throws {
    try pinPanelLanguageToEnglish()
    let en = Locale(identifier: "en_US")
    XCTAssertEqual(ByteSize.format(0, locale: en), "0 B", "Zero is shown, it does not read 'Zero KB'")
    XCTAssertEqual(ByteSize.format(1023, locale: en), "1023 B")
    XCTAssertEqual(ByteSize.format(1024, locale: en), "1 KB")
    XCTAssertEqual(ByteSize.format(1536, locale: en), "1.5 KB")
    XCTAssertEqual(ByteSize.format(5 * 1024 * 1024, locale: en), "5 MB")
    XCTAssertEqual(ByteSize.format(1_288_490_189, locale: en), "1.2 GB")
    XCTAssertEqual(ByteSize.format(3 * pow(1024, 4), locale: en), "3 TB")
    XCTAssertEqual(ByteSize.format(5000 * pow(1024, 4), locale: en), "5,000 TB", "TB is the largest unit")
    XCTAssertEqual(ByteSize.format(.nan, locale: en), "Unavailable")
    XCTAssertEqual(ByteSize.text(-1, locale: en), "", "The backup's size is empty for a size that is not one")
    XCTAssertEqual(ByteSize.text(.nan, locale: en), "")
  }

  // MARK: Backup

  /// The controller's side of a restore: idle, then the previewed package, then a restore waiting
  /// for the next launch that keeps every other backup operation off until it is cancelled. What the
  /// package holds and what the page sends are `StorageSettingsModelTests`'.
  func testTheRestoreStagesFollowPreviewRestoreAndCancel() async throws {
    try await withPanel { panel in
      let controller = panel.controller
      try "schema_version = 1\n".write(
        to: panel.root.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
      let exports = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString, isDirectory: true)
      try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: exports) }
      let package = exports.appendingPathComponent("Plain.wmbackup")
      panel.pickers.exportBackup = { package }
      panel.pickers.restoreBackup = { package }

      XCTAssertEqual(controller.backupPresentation.restoreStage, .idle)
      XCTAssertTrue(controller.backupPresentation.canStartOperation)
      try await controller.exportBackup(includeLibrary: false)
      XCTAssertNotNil(panel.backup.status)
      XCTAssertFalse(controller.backupPresentation.isBusy)

      try await controller.previewBackup()
      let preview = try XCTUnwrap(controller.backupPresentation.preview)
      XCTAssertEqual(controller.backupPresentation.restoreStage, .preview(preview))
      XCTAssertTrue(controller.backupPresentation.canStartOperation)

      try await controller.restoreBackup(policy: .keepExisting)
      XCTAssertTrue(controller.backupPresentation.hasPendingRestore)
      XCTAssertEqual(controller.backupPresentation.restoreStage, .pendingRestore)
      XCTAssertFalse(controller.backupPresentation.canStartOperation, "A pending restore waits for its launch or its cancel")

      try await controller.cancelPendingRestore()
      XCTAssertFalse(controller.backupPresentation.hasPendingRestore)
      XCTAssertTrue(controller.backupPresentation.canStartOperation)
    }
  }

  func testRestoringWithoutAPreviewIsRefusedAndACancelledPickerLeavesTheStateAlone() async throws {
    try await withPanel { panel in
      let controller = panel.controller
      do {
        try await controller.restoreBackup(policy: .keepExisting)
        XCTFail("A restore needs a previewed package")
      } catch {}
      try await controller.previewBackup()
      XCTAssertNil(controller.backupPresentation.preview, "Cancel in the picker previews nothing")
      XCTAssertEqual(controller.backupPresentation.restoreStage, .idle)
    }
  }

  func testBackupActionsLeaveAnOlderBannerAloneAndAFailureStillReachesIt() async throws {
    try await withPanel { panel in
      let controller = panel.controller
      controller.errors.actionError = "An older failure"
      try await controller.previewBackup()
      XCTAssertEqual(controller.errors.actionError, "An older failure", "Backup actions are not queued and never clear the banner")
    }
  }

  func testAPreviewedPackageIsWordedWithItsFactsAndCounts() throws {
    try pinPanelLanguageToEnglish()
    let en = Locale(identifier: "en_US")
    let created = Date(timeIntervalSince1970: 1_800_000_000)
    let preview = BackupPresentation.Preview(
      WallpaperBackupPreview(
        name: "Mac mini", createdAt: created, wallpaperCount: 3, presetCount: 1, collectionCount: 2,
        includesLibrary: false, byteCount: 5 * 1024 * 1024, conflicts: ["Library/101", ""], warnings: [],
        manifestDigest: "digest"))
    let made = created.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(en))
    XCTAssertEqual(preview.factsLine(locale: en), "Mac mini · Made \(made) · 5 MB")
    XCTAssertEqual(preview.countsLine, "3 wallpapers · 1 preset · 2 collections · no wallpaper files")
    XCTAssertEqual(preview.conflicts, ["Library/101"], "Empty entries are dropped")

    var single = preview
    single.wallpaperCount = 1
    single.collectionCount = 1
    single.includesLibrary = true
    single.name = ""
    XCTAssertEqual(single.countsLine, "1 wallpaper · 1 preset · 1 collection · wallpaper library included")
    XCTAssertTrue(single.factsLine(locale: en).hasPrefix("Made "), "A missing name is left out")
    XCTAssertEqual(BackupPresentation(isBusy: true, hasPendingRestore: false, preview: nil, status: nil, error: nil).workingText, "Working…")
    XCTAssertEqual(
      BackupPresentation(isBusy: true, hasPendingRestore: false, preview: nil, status: "Copying the local backup…", error: nil).workingText,
      "Copying the local backup…")
  }
}
