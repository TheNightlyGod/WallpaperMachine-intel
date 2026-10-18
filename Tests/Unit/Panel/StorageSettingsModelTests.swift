import Foundation
import XCTest

@testable import WallpaperMachine

/// The choices of Settings › Storage › Backup that the page keeps between choosing a package and
/// restoring it, and what Export, Choose backup… and Restore do with them.
@MainActor
final class StorageSettingsModelTests: SettingsBTestCase {
  func testTheChoicesStartSafeAndLiveOnTheControllerNotInThePage() async throws {
    try await withPanel { panel in
      let model = panel.controller.displaysSettings.backup
      XCTAssertFalse(model.includeLibrary, "the library is not copied unless asked for")
      XCTAssertEqual(model.policy, .keepExisting)
      model.includeLibrary = true
      model.policy = .replace
      XCTAssertTrue(panel.controller.displaysSettings.backup.includeLibrary, "the same choices when the page is rebuilt")
      XCTAssertEqual(panel.controller.displaysSettings.backup.policy, .replace)
    }
  }

  /// Include the wallpaper library is honoured by Export; the previewed package shows its conflicts;
  /// Replace, chosen on the page, stages the restore for the next launch without touching the
  /// current files; and cancelling the restore removes the staging.
  func testIncludingTheLibraryAndChoosingReplaceProduceTheRequestedPendingRestore() async throws {
    try await withPanel { panel in
      let controller = panel.controller
      let model = controller.displaysSettings.backup
      let project = panel.library.appendingPathComponent("101", isDirectory: true)
      try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
      let original = Data("<!doctype html><html><body>Original</body></html>".utf8)
      try original.write(to: project.appendingPathComponent("index.html"))
      try Data(#"{"type":"web","title":"Original","file":"index.html"}"#.utf8)
        .write(to: project.appendingPathComponent("project.json"))
      try "schema_version = 1\n".write(
        to: panel.root.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
      let exports = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
      try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: exports) }
      let without = exports.appendingPathComponent("Without.wmbackup")
      let package = exports.appendingPathComponent("Library.wmbackup")

      // Left off, Export copies the settings and no wallpapers.
      panel.pickers.exportBackup = { without }
      try await model.export()
      XCTAssertNil(panel.backup.error)
      XCTAssertFalse(
        FileManager.default.fileExists(atPath: without.appendingPathComponent("data/Library/101/index.html").path),
        "the library switch is off by default")

      // Switched on, Export copies every installed wallpaper as well.
      model.includeLibrary = true
      panel.pickers.exportBackup = { package }
      panel.pickers.restoreBackup = { package }
      try await model.export()
      XCTAssertNil(panel.backup.error)
      XCTAssertEqual(
        try Data(contentsOf: package.appendingPathComponent("data/Library/101/index.html")), original)

      let current = Data("<!doctype html><html><body>Changed locally</body></html>".utf8)
      try current.write(to: project.appendingPathComponent("index.html"))
      model.policy = .replace
      try await model.choose()
      XCTAssertEqual(model.policy, .keepExisting, "a package that is read starts from the safe answer again")
      let preview = try XCTUnwrap(controller.backupPresentation.preview)
      XCTAssertTrue(preview.conflicts.contains("Library/101"))

      model.policy = .replace
      try await model.restore()
      XCTAssertNil(panel.backup.error)
      let pending = panel.root.appendingPathComponent(WallpaperBackupService.pendingDirectoryName)
      let state = try JSONDecoder().decode(
        WallpaperBackupPending.self, from: Data(contentsOf: pending.appendingPathComponent("pending.json")))
      XCTAssertEqual(state.policy, .replace)
      XCTAssertEqual(try Data(contentsOf: project.appendingPathComponent("index.html")), current)
      XCTAssertEqual(controller.backupPresentation.restoreStage, .pendingRestore)

      try await controller.cancelPendingRestore()
      XCTAssertFalse(FileManager.default.fileExists(atPath: pending.path))
      XCTAssertFalse(controller.backupPresentation.hasPendingRestore)
      XCTAssertEqual(
        controller.backupPresentation.restoreStage, .preview(preview),
        "the previewed package is on show again, ready to be restored or replaced")
    }
  }

  /// Exports a package of the settings alone, reads it and stages it as the page does untouched.
  private func stagePlainRestore(_ panel: PanelFixture, in exports: URL) async throws {
    let model = panel.controller.displaysSettings.backup
    try "schema_version = 1\n".write(
      to: panel.root.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
    let package = exports.appendingPathComponent("Plain.wmbackup")
    panel.pickers.exportBackup = { package }
    panel.pickers.restoreBackup = { package }
    try await model.export()
    try await model.choose()
    try await model.restore()
  }

  private func makeExports() throws -> URL {
    let exports = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
    return exports
  }

  func testRestoringKeepExistingIsWhatAnUntouchedPageSends() async throws {
    try await withPanel { panel in
      let exports = try makeExports()
      defer { try? FileManager.default.removeItem(at: exports) }
      try await stagePlainRestore(panel, in: exports)
      let pending = panel.root.appendingPathComponent(WallpaperBackupService.pendingDirectoryName)
      let state = try JSONDecoder().decode(
        WallpaperBackupPending.self, from: Data(contentsOf: pending.appendingPathComponent("pending.json")))
      XCTAssertEqual(state.policy, .keepExisting, "sent even when the conflict choice is not on show")
    }
  }

  /// While a restore waits for the next launch, the page offers only Cancel restore: Export, the
  /// library switch, Choose backup… and Restore are off, and come back once it is cancelled.
  func testWhileARestoreWaitsThePageCanStartNothingElseUntilItIsCancelled() async throws {
    try await withPanel { panel in
      let controller = panel.controller
      let model = controller.displaysSettings.backup
      XCTAssertTrue(model.canStart)
      XCTAssertEqual(controller.backupPresentation.workingText, "Working…", "the progress row's words before any status")
      let exports = try makeExports()
      defer { try? FileManager.default.removeItem(at: exports) }
      try await stagePlainRestore(panel, in: exports)
      XCTAssertEqual(controller.backupPresentation.restoreStage, .pendingRestore, "the restore row says it waits")
      XCTAssertFalse(model.canStart, "nothing else starts while it waits")
      try await controller.cancelPendingRestore()
      XCTAssertTrue(model.canStart)
    }
  }
}
