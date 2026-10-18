import AppKit
import UniformTypeIdentifiers
import XCTest

@testable import WallpaperMachine

/// Choosing files to import, the policy the import starts with, and the toolbar pill that reports it.
@MainActor
final class PanelLibraryImportTests: PanelTestCase {
  private func makeProject(in root: URL, id: String) throws -> URL {
    let folder = root.appendingPathComponent("sources/\(id)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("video-content".utf8).write(to: folder.appendingPathComponent("movie.mp4"))
    try JSONSerialization.data(withJSONObject: ["title": "Test \(id)", "type": "video", "file": "movie.mp4"])
      .write(to: folder.appendingPathComponent("project.json"))
    return folder
  }

  private func offscreenWindow() -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered,
      defer: true)
    window.isReleasedWhenClosed = false
    return window
  }

  func testImportStartsWithTheFilesTheSheetChoseAndThePolicyAndOffersFoldersAndMedia() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    let controller = panel.controller
    let window = offscreenWindow()
    panel.dialogs.presentingWindow = window
    let project = try makeProject(in: panel.root, id: "123456")
    var offered: [[UTType]] = []
    var presented: [NSWindow] = []
    controller.chooseImportFiles = { window, types in
      presented.append(window)
      offered.append(types)
      return [project]
    }

    try await controller.beginImport()
    try await panel.waitUntil(timeout: 10) { !controller.imports.isBusy && controller.importState.report != nil }
    XCTAssertTrue(presented.first === window, "the sheet belongs to the panel's window")
    XCTAssertTrue(offered[0].contains(.folder) && offered[0].contains(.json) && offered[0].contains(.mpeg4Movie))
    XCTAssertEqual(controller.importState.report?.imported, 1)
    XCTAssertEqual(controller.importState.report?.skipped, 0)
    XCTAssertTrue(FileManager.default.fileExists(atPath: panel.library.appendingPathComponent("123456/movie.mp4").path))

    // The default keeps what the library holds; Keep both copies is what a person asks for.
    try await controller.beginImport()
    try await panel.waitUntil(timeout: 10) { !controller.imports.isBusy && controller.importState.report?.skipped == 1 }
    XCTAssertEqual(controller.importState.report?.imported, 0)
    try Data("different-content".utf8).write(to: project.appendingPathComponent("movie.mp4"))
    try await controller.beginImport(duplicates: .keepBoth)
    try await panel.waitUntil(timeout: 10) { !controller.imports.isBusy && controller.importState.report?.imported == 1 }
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: panel.library.path).filter { $0 != ".DS_Store" }.count, 2)
  }

  func testNothingStartsWithoutAWindowAfterCancelOrOnceThePanelIsGone() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    let controller = panel.controller
    let project = try makeProject(in: panel.root, id: "123456")
    var asked = 0
    var answer: [URL]? = [project]
    controller.chooseImportFiles = { _, _ in
      asked += 1
      return answer
    }

    try await controller.beginImport()
    XCTAssertEqual(asked, 0, "a panel with no window cannot show the sheet, and does nothing")

    panel.dialogs.presentingWindow = offscreenWindow()
    answer = nil
    try await controller.beginImport()
    XCTAssertEqual(asked, 1)
    XCTAssertFalse(controller.imports.isBusy, "Cancel starts nothing")
    XCTAssertNil(controller.importState.report)

    answer = []
    try await controller.beginImport()
    XCTAssertFalse(controller.imports.isBusy, "an empty choice starts nothing")

    // The panel closed while the sheet was open: the files are not imported behind its back.
    controller.start()
    controller.stop()
    answer = [project]
    try await controller.beginImport()
    XCTAssertFalse(controller.imports.isBusy)
    XCTAssertNil(controller.importState.report)
  }

  func testAnImportThatIsAlreadyRunningRefusesAnotherInTheBanner() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    let controller = panel.controller
    panel.dialogs.presentingWindow = offscreenWindow()
    let project = try makeProject(in: panel.root, id: "123456")
    var asked = 0
    controller.chooseImportFiles = { _, _ in
      asked += 1
      return nil
    }
    try controller.imports.start([project], duplicates: .skip)
    XCTAssertTrue(controller.importState.isBusy)
    let task = controller.launch("import") { try await controller.beginImport() }
    await task.value
    XCTAssertEqual(controller.errors.message, L("An import is already running."))
    XCTAssertEqual(asked, 0)
    controller.cancelImport()
    try await panel.waitUntil(timeout: 10) { !controller.imports.isBusy }
  }

  // MARK: The pill

  private func report(imported: Int = 0, skipped: Int = 0, failures: [String] = [], cancelled: Bool = false)
    -> LibraryImportState.Report
  {
    .init(imported: imported, skipped: skipped, failures: failures, cancelled: cancelled)
  }

  private func busy(_ status: String = "Importing 1 of 2") -> LibraryImportState {
    .init(isBusy: true, status: status, report: nil)
  }

  private func finished(_ report: LibraryImportState.Report) -> LibraryImportState {
    .init(isBusy: false, status: "Import complete", report: report)
  }

  func testThePillShowsWhileTheImportRunsAndAfterItUntilTheReportHasBeenLookedAt() {
    var pill = ImportPill()
    XCTAssertFalse(pill.isShown(popoverOpenedFromPill: false))
    XCTAssertEqual(pill.label, L("Import wallpapers"))

    pill.observe(busy(), popoverOpen: false)
    XCTAssertTrue(pill.isShown(popoverOpenedFromPill: false))
    XCTAssertEqual(pill.label, "Importing 1 of 2", "the store's own status line")
    pill.observe(busy(""), popoverOpen: false)
    XCTAssertEqual(pill.label, L("Importing…"))

    pill.observe(finished(report(imported: 2, skipped: 1)), popoverOpen: false)
    XCTAssertTrue(pill.isShown(popoverOpenedFromPill: false), "the result waits to be seen")
    XCTAssertEqual(pill.label, L("\(2) imported · \(1) skipped"))
    XCTAssertFalse(pill.needsAttention)

    pill.popoverDidClose()
    XCTAssertFalse(pill.isShown(popoverOpenedFromPill: false), "looked at, so it goes")
    pill.observe(finished(report(imported: 2, skipped: 1)), popoverOpen: false)
    XCTAssertFalse(pill.isShown(popoverOpenedFromPill: false), "the same report is not announced twice")
  }

  func testAFailureOrACancellationAsksForAttentionInTheLabel() {
    var pill = ImportPill()
    pill.observe(busy(), popoverOpen: false)
    pill.observe(finished(report(imported: 1, failures: ["Not a wallpaper"])), popoverOpen: false)
    XCTAssertTrue(pill.needsAttention)
    XCTAssertEqual(pill.label, L("\(L("\(1) imported · \(0) skipped")) · needs attention"))

    pill.observe(busy(), popoverOpen: false)
    XCTAssertFalse(pill.needsAttention, "while it runs the pill has nothing to ask")
    pill.observe(finished(report(imported: 1, cancelled: true)), popoverOpen: false)
    XCTAssertTrue(pill.needsAttention)
    XCTAssertEqual(
      pill.state.report?.summary, L("\(1) imported · \(0) skipped · Cancelled"),
      "the cancellation is part of the phrase, not a fragment added to it")
  }

  func testAReportThatArrivesWhileThePopoverIsOpenNeedsNoPillAndTheOpenPopoverKeepsItsReport() {
    var pill = ImportPill()
    pill.observe(busy(), popoverOpen: true)
    pill.observe(finished(report(imported: 3)), popoverOpen: true)
    XCTAssertFalse(pill.isReportUnseen, "it is being read already")
    XCTAssertTrue(pill.isShown(popoverOpenedFromPill: true), "the popover's anchor stays while it is open")
    XCTAssertFalse(pill.isShown(popoverOpenedFromPill: false))

    // The store forgets the report when the next import starts; the popover still shows it.
    pill.observe(.init(isBusy: false, status: "", report: nil), popoverOpen: true)
    XCTAssertEqual(pill.state.report?.imported, 3)
    pill.observe(.init(isBusy: false, status: "", report: nil), popoverOpen: false)
    XCTAssertNil(pill.state.report, "a closed popover keeps nothing")
  }
}
