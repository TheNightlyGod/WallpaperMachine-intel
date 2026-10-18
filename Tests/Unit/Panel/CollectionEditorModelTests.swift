import XCTest

@testable import WallpaperMachine

/// The Collections section of the sidebar: the name field's states, what a refusal does, the delete
/// confirmation and its notice.
@MainActor
final class CollectionEditorModelTests: PanelTestCase {
  @MainActor
  private final class Spoken {
    private(set) var lines: [String] = []
    func say(_ line: String) { lines.append(line) }
  }

  private func names(_ panel: PanelFixture) -> [String] { panel.collections.collections.map(\.name) }

  // MARK: Create

  func testCreatingTrimsTheNameClosesTheFieldAndOpensInstalledOnTheNewCollection() async throws {
    try await withPanel { panel in
      let controller = panel.controller
      let editor = controller.shell.collectionEditor
      await controller.shell.open(.settings).value
      editor.beginCreate()
      XCTAssertEqual(editor.mode, .create)
      editor.name = "  Chill evenings  "
      await editor.submit().value

      XCTAssertEqual(names(panel), ["Chill evenings"])
      XCTAssertFalse(editor.isOpen, "the field closes")
      XCTAssertEqual(editor.name, "")
      XCTAssertNil(editor.failure)
      XCTAssertEqual(panel.navigation.selection, .wallpaper, "the new collection is shown on Installed")
      XCTAssertNil(controller.errors.message)
    }
  }

  func testAnEmptyNameDoesNothingAndLeavesTheFieldOpenWithoutAnError() async throws {
    try await withPanel { panel in
      let editor = panel.controller.shell.collectionEditor
      editor.beginCreate()
      editor.name = "   "
      await editor.submit().value
      XCTAssertTrue(editor.isOpen)
      XCTAssertNil(editor.failure, "nothing was refused: nothing was sent")
      XCTAssertTrue(names(panel).isEmpty)
    }
  }

  func testARefusedNameStaysInTheFieldWithItsReasonAndNeverReachesTheBanner() async throws {
    try await withPanel { panel in
      let controller = panel.controller
      let editor = controller.shell.collectionEditor
      editor.beginCreate()
      editor.name = String(repeating: "x", count: 129)
      await editor.submit().value

      XCTAssertEqual(editor.mode, .create, "the field stays open for another try")
      XCTAssertEqual(editor.failure, LibraryOrganizationError.invalidName.errorDescription)
      XCTAssertNil(controller.errors.message, "the reason is under the field, not in the banner")
      XCTAssertTrue(names(panel).isEmpty)

      editor.name = String(repeating: "x", count: 128)
      editor.clearFailure()
      XCTAssertNil(editor.failure, "typing again withdraws the reason")
      await editor.submit().value
      XCTAssertEqual(names(panel), [String(repeating: "x", count: 128)])
      XCTAssertFalse(editor.isOpen)
    }
  }

  func testTheNameFieldKeepsDuplicateNamesBecauseTheyAreLabelsNotIdentity() async throws {
    try await withPanel { panel in
      let editor = panel.controller.shell.collectionEditor
      for _ in 0..<2 {
        editor.beginCreate()
        editor.name = "Night"
        await editor.submit().value
      }
      XCTAssertEqual(names(panel), ["Night", "Night"])
      XCTAssertEqual(Set(panel.collections.collections.map(\.id)).count, 2)
    }
  }

  func testCancellingClosesTheFieldAndForgetsWhatWasTyped() async throws {
    try await withPanel { panel in
      let editor = panel.controller.shell.collectionEditor
      editor.beginCreate()
      editor.name = "Half a nam"
      editor.cancel()
      XCTAssertFalse(editor.isOpen)
      XCTAssertEqual(editor.name, "")
      editor.beginCreate()
      XCTAssertEqual(editor.name, "", "a new field starts empty")
    }
  }

  // MARK: Rename

  func testRenamingStartsFromTheCurrentNameAndSavesUnderTheSameCollection() async throws {
    try await withPanel { panel in
      let created = try panel.collections.create(name: "Neon", wallpaperIDs: [])
      let editor = panel.controller.shell.collectionEditor
      editor.beginRename(created.id)
      XCTAssertEqual(editor.mode, .rename(created.id))
      XCTAssertEqual(editor.name, "Neon")
      editor.name = "Neon nights"
      await editor.submit().value
      XCTAssertEqual(names(panel), ["Neon nights"])
      XCTAssertEqual(panel.collections.collections.first?.id, created.id)
      XCTAssertFalse(editor.isOpen)
    }
  }

  func testARefusedRenameStaysOpenWithItsReason() async throws {
    try await withPanel { panel in
      let created = try panel.collections.create(name: "Neon", wallpaperIDs: [])
      let editor = panel.controller.shell.collectionEditor
      editor.beginRename(created.id)
      editor.name = "two\nlines"
      await editor.submit().value
      XCTAssertEqual(editor.mode, .rename(created.id))
      XCTAssertEqual(editor.failure, LibraryOrganizationError.invalidName.errorDescription)
      XCTAssertEqual(names(panel), ["Neon"])
    }
  }

  func testRenamingACollectionThatIsGoneOpensNothingAndOneDeletedElsewhereClosesTheField() async throws {
    try await withPanel { panel in
      let editor = panel.controller.shell.collectionEditor
      editor.beginRename("gone")
      XCTAssertFalse(editor.isOpen)

      let created = try panel.collections.create(name: "Neon", wallpaperIDs: [])
      editor.beginRename(created.id)
      try panel.collections.delete(created.id)
      editor.reconcile()
      XCTAssertFalse(editor.isOpen, "its collection left the library")

      editor.beginCreate()
      editor.reconcile()
      XCTAssertTrue(editor.isOpen, "a field for a new collection has nothing to lose")
    }
  }

  // MARK: Delete

  func testDeletingAsksFirstAndWithoutAYesDeletesNothing() async throws {
    try await withPanel { panel in
      let created = try panel.collections.create(name: "Neon", wallpaperIDs: [])
      let controller = panel.controller
      await controller.shell.collectionEditor.requestDelete(created.id).value
      XCTAssertEqual(names(panel), ["Neon"], "a window-less panel answers no")
      XCTAssertEqual(panel.dialogs.confirmations.count, 1)
      XCTAssertEqual(
        panel.dialogs.confirmations.first?.title, L("Delete “Neon”? Its wallpapers stay in your library."))
      XCTAssertEqual(panel.dialogs.confirmations.first?.button, L("Delete"))
      XCTAssertNil(controller.shell.notice)
    }
  }

  func testAConfirmedDeleteRemovesTheCollectionKeepsItsWallpapersAndSaysSo() async throws {
    try await withPanel { panel in
      panel.store.librarySnapshot.wallpapers = ["a", "b"].map {
        BridgeWallpaperEntry(
          id: $0, title: $0, kind: .video, supported: true, active: false, selected: false,
          previewPath: nil)
      }
      let created = try panel.collections.create(name: "Neon", wallpaperIDs: ["a", "b"])
      let controller = panel.controller
      let shell = controller.shell
      let spoken = Spoken()
      shell.announce = { spoken.say($0) }
      panel.dialogs.confirmAnswer = true

      shell.collectionEditor.beginRename(created.id)
      await shell.collectionEditor.requestDelete(created.id).value
      XCTAssertTrue(names(panel).isEmpty)
      XCTAssertEqual(controller.store.librarySnapshot.wallpapers.count, 2, "the wallpapers stay in the library")
      XCTAssertEqual(shell.notice, L("Deleted “Neon”."))
      XCTAssertEqual(spoken.lines, [L("Deleted “Neon”.")], "VoiceOver says it too")
      XCTAssertFalse(shell.collectionEditor.isOpen, "the rename of a deleted collection closes")
      XCTAssertNil(controller.errors.message)
    }
  }

  func testDeletingAnUnknownCollectionDoesNotAsk() async throws {
    try await withPanel { panel in
      panel.dialogs.confirmAnswer = true
      await panel.controller.shell.collectionEditor.requestDelete("gone").value
      XCTAssertTrue(panel.dialogs.confirmations.isEmpty)
    }
  }
}
