import XCTest

@testable import WallpaperMachine

/// The presets bar's own state, ported from `presets.js`: the picked preset, the name being typed
/// and the Delete that waits for its second click, and what each allows. The bar had no test of
/// its own on the web; the controller's actions are in `PanelPresetsTests`.
final class PresetsBarStateTests: XCTestCase {
  private let night = PresetsState.Item(id: "p1", name: "Night")
  private let day = PresetsState.Item(id: "p2", name: "Day")

  private func state(
    items: [PresetsState.Item], dirty: Bool = false, canSave: Bool = true, status: String? = nil
  ) -> PresetsState {
    PresetsState(
      wallpaperID: "a", items: items, isDirty: dirty, canSave: canSave, status: status, error: nil)
  }

  func testAPickedPresetIsDroppedWhenItLeavesTheListAndDeleteDisarms() {
    var bar = PresetsBarState()
    bar.pick("p1")
    bar.beginDelete(of: night)
    XCTAssertEqual(bar.chosen(in: [night, day])?.id, "p1")
    XCTAssertTrue(bar.isConfirmingDelete(in: [night, day]))

    bar.pick("p2")
    XCTAssertEqual(bar.armed, "", "picking another disarms Delete")
    XCTAssertFalse(bar.isConfirmingDelete(in: [night, day]))

    bar.pick("p1")
    bar.beginDelete(of: night)
    bar.sync(items: [day])
    XCTAssertEqual(bar.picked, "")
    XCTAssertEqual(bar.armed, "")
    XCTAssertNil(bar.chosen(in: [day]))
  }

  func testTheNameEditorKnowsItsModeTrimsTheNameAndClosesWithEscape() {
    var bar = PresetsBarState()
    bar.beginSave()
    XCTAssertEqual(bar.editor?.mode, .save)
    XCTAssertNil(bar.editor?.trimmedName, "an empty name is ignored")
    bar.setName("  Calm night  ")
    XCTAssertEqual(bar.editor?.trimmedName, "Calm night")
    bar.setName("   ")
    XCTAssertNil(bar.editor?.trimmedName)
    bar.closeEditor()  // Escape or Cancel
    XCTAssertNil(bar.editor)

    bar.beginRename(of: night)
    XCTAssertEqual(bar.editor?.mode, .rename(presetID: "p1"))
    XCTAssertEqual(bar.editor?.name, "Night", "the current name is the starting point")
    bar.sync(items: [day])
    XCTAssertNil(bar.editor, "the preset being renamed is gone")
  }

  func testTheNameFieldTakesAtMostOneHundredAndTwentyCharacters() {
    var bar = PresetsBarState()
    bar.beginSave()
    bar.setName(String(repeating: "n", count: 400))
    XCTAssertEqual(bar.editor?.name.count, 120)
  }

  func testAFreshSavePicksThePresetItMadeAndClosesTheEditor() {
    var bar = PresetsBarState()
    bar.beginSave()
    bar.setName("Calm")
    bar.didSave(created: "p9")
    XCTAssertNil(bar.editor)
    XCTAssertEqual(bar.picked, "p9", "the new preset is picked automatically")

    bar.beginSave()
    bar.didSave(created: nil)
    XCTAssertEqual(bar.picked, "p9", "no new preset reported: the pick stays")
  }

  func testBeginningAnEditOrADeleteDisarmsTheOther() {
    var bar = PresetsBarState()
    bar.pick("p1")
    bar.beginDelete(of: night)
    bar.beginSave()
    XCTAssertEqual(bar.armed, "")
    XCTAssertFalse(bar.showsTools(in: [night]), "the links are hidden while the name form shows")
    bar.closeEditor()
    bar.beginDelete(of: night)
    XCTAssertFalse(bar.showsTools(in: [night]), "and while the delete confirmation shows")
    bar.disarm()
    XCTAssertTrue(bar.showsTools(in: [night]))
  }

  /// `presets.js`: arming Delete moves focus to the confirming Delete, Cancel takes it back to the
  /// Delete… link, and picking another preset disarms without moving it.
  func testArmingDeleteMovesFocusToTheConfirmationAndCancelBringsItBack() {
    var bar = PresetsBarState()
    bar.pick("p1")
    XCTAssertNil(bar.focusRequest)
    bar.beginDelete(of: night)
    XCTAssertEqual(bar.focusRequest, .confirmDelete, "the link that had focus went away")
    bar.focusTaken(.deleteLink)
    XCTAssertEqual(bar.focusRequest, .confirmDelete, "only the control asked for ends the request")
    bar.focusTaken(.confirmDelete)
    XCTAssertNil(bar.focusRequest)

    bar.cancelDelete()
    XCTAssertEqual(bar.armed, "")
    XCTAssertTrue(bar.showsTools(in: [night]))
    XCTAssertEqual(bar.focusRequest, .deleteLink, "Cancel goes back to where Delete… was pressed")
    bar.focusTaken(.deleteLink)

    bar.beginDelete(of: night)
    bar.pick("p2")
    XCTAssertNil(bar.focusRequest, "another pick disarms, and the confirmation it asked for is gone")
    bar.pick("p1")
    bar.beginDelete(of: night)
    bar.sync(items: [day])
    XCTAssertNil(bar.focusRequest, "nor does a preset that left the list keep it")
  }

  func testDeletingTheOnePickedForgetsThePick() {
    var bar = PresetsBarState()
    bar.pick("p1")
    bar.didDelete("p2")
    XCTAssertEqual(bar.picked, "p1")
    bar.didDelete("p1")
    XCTAssertEqual(bar.picked, "")
  }

  func testPendingEditsBlockSavingAndApplyingAndAnActionUnderWayBlocksTheWholeBar() {
    var bar = PresetsBarState()
    bar.pick("p1")
    let clean = state(items: [night, day])
    XCTAssertTrue(bar.canApply(clean, isPending: false))
    XCTAssertTrue(bar.canSave(clean, isPending: false))
    XCTAssertTrue(bar.canPick(clean, isPending: false))
    XCTAssertFalse(bar.showsDirtyNote(clean))

    let dirty = state(items: [night, day], dirty: true)
    XCTAssertFalse(bar.canApply(dirty, isPending: false), "applying over pending edits would throw them away")
    XCTAssertFalse(bar.canSave(dirty, isPending: false), "pending edits are not worth saving")
    XCTAssertTrue(bar.showsDirtyNote(dirty))
    bar.beginSave()
    XCTAssertFalse(bar.showsDirtyNote(dirty), "the note gives way to the name form")

    XCTAssertFalse(bar.canApply(clean, isPending: true))
    XCTAssertFalse(bar.canSave(clean, isPending: true))
    XCTAssertFalse(bar.canPick(clean, isPending: true))

    XCTAssertFalse(bar.canSave(state(items: [night], canSave: false), isPending: false), "the controller's own rule")
    XCTAssertFalse(bar.canPick(state(items: []), isPending: false), "nothing to pick")
    var none = PresetsBarState()
    XCTAssertFalse(none.canApply(clean, isPending: false), "nothing chosen")
    none.pick("gone")
    XCTAssertFalse(none.canApply(clean, isPending: false), "a pick that is not in the list")
  }
}
