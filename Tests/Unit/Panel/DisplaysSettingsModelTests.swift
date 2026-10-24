import XCTest

@testable import WallpaperMachine

/// What Settings › Displays keeps between a person's actions and the controller's: the layouts
/// group's status, error and focus, the copy-or-swap choice, the Custom interval, the display's own
/// list, the time rule editor, the sunrise and sunset fields and the values a control shows while
/// its change is on the way.
@MainActor
final class DisplaysSettingsModelTests: SettingsBTestCase {
  private func wallpaper(_ id: String) -> WallpaperAutomationTarget { .init(kind: .wallpaper, id: id) }

  // MARK: Display layouts

  func testSavingRenamingApplyingAndDeletingALayoutReportAndMoveFocusLikeTheOldPage() async throws {
    try await withTwoDisplayPanel { panel, bridge in
      let controller = panel.controller
      let model = controller.displaysSettings

      model.beginNewLayout()
      XCTAssertEqual(model.layoutEditor, .new)
      model.layoutName = DisplaysNameForm("Work <img src=x>")
      await model.submitLayoutEditor()
      XCTAssertNil(model.layoutEditor, "the form closes once the layout is saved")
      XCTAssertEqual(model.layoutStatus, "Display layout saved.")
      XCTAssertNil(model.layoutError)
      XCTAssertNil(model.transferSource, "a layout's result is not repeated in any Copy or swap disclosure")
      XCTAssertEqual(model.layoutFocus, .new, "focus goes back to Save current layout…")
      let layout = try XCTUnwrap(controller.displayLayoutsState.layouts.first)
      XCTAssertEqual(layout.name, "Work <img src=x>", "a name is text")

      model.consumeLayoutFocus()
      model.beginRenaming(layout)
      XCTAssertEqual(model.layoutName.text, "Work <img src=x>", "the form starts with the current name")
      model.layoutName = DisplaysNameForm("Evening")
      await model.submitLayoutEditor()
      XCTAssertEqual(controller.displayLayoutsState.layouts.first?.name, "Evening")
      XCTAssertEqual(model.layoutStatus, "Layout renamed.")
      XCTAssertEqual(model.layoutFocus, .rename(layout.id), "focus goes back to the layout's own button")

      bridge.assignments = ["primary": "c", "secondary": "a"]
      try await panel.store.refreshAllAsync()
      await model.applyLayout(layout.id)
      XCTAssertEqual(bridge.assignments, ["primary": "a", "secondary": "b"])
      XCTAssertEqual(model.layoutStatus, "Wallpaper arrangement applied.")

      model.askToDelete(layout.id)
      XCTAssertEqual(model.layoutDeleteArmed, layout.id)
      XCTAssertEqual(model.layoutFocus, .confirmDelete(layout.id), "focus moves to the confirming button")
      model.cancelDelete()
      XCTAssertNil(model.layoutDeleteArmed)
      XCTAssertEqual(model.layoutFocus, .delete(layout.id), "cancelling returns to the opener")
      model.askToDelete(layout.id)
      await model.deleteLayout(layout.id)
      XCTAssertTrue(controller.displayLayoutsState.layouts.isEmpty)
      XCTAssertEqual(model.layoutStatus, "Layout deleted. Current wallpapers are unchanged.")
      XCTAssertEqual(model.layoutFocus, .new)
      XCTAssertNil(model.layoutDeleteArmed)
      XCTAssertEqual(bridge.assignments, ["primary": "a", "secondary": "b"])
    }
  }

  func testCancellingTheNameFormReturnsFocusToTheButtonThatOpenedIt() async throws {
    try await withTwoDisplayPanel { panel, _ in
      let controller = panel.controller
      let model = controller.displaysSettings
      let layout = try await controller.saveDisplayLayout(name: "Work")
      model.beginNewLayout()
      model.cancelLayoutEditor()
      XCTAssertNil(model.layoutEditor)
      XCTAssertEqual(model.layoutFocus, .new)
      model.consumeLayoutFocus()
      XCTAssertNil(model.layoutFocus)
      model.beginRenaming(try XCTUnwrap(controller.displayLayoutsState.layouts.first))
      model.cancelLayoutEditor()
      XCTAssertEqual(model.layoutFocus, .rename(layout.id))
      XCTAssertEqual(controller.displayLayoutsState.layouts.map(\.name), ["Work"], "nothing was renamed")
    }
  }

  func testOneNameFormIsOpenAtATimeSoTwoNeverTakeTheKeyboardFromEachOther() async throws {
    try await withTwoDisplayPanel { panel, _ in
      let controller = panel.controller
      let model = controller.displaysSettings
      let plan = try panel.playlists.savePlan(from: "primary", name: "Weekday")
      model.beginNewLayout()
      model.beginSavingPlan(of: "primary")
      XCTAssertNil(model.layoutEditor, "opening the plan form closes the layout form")
      XCTAssertEqual(model.planEditor, .save(display: "primary"))
      model.beginNewLayout()
      XCTAssertNil(model.planEditor, "and the other way round")
      XCTAssertEqual(model.layoutEditor, .new)
      model.beginRenaming(try XCTUnwrap(controller.playlistPlanRows.first { $0.id == plan.id }))
      XCTAssertNil(model.layoutEditor)
      XCTAssertEqual(model.planEditor, .rename(plan.id))
    }
  }

  func testAFormWithOnlySpacesSendsNothingAndARefusedNameStaysInTheForm() async throws {
    try await withTwoDisplayPanel { panel, _ in
      let model = panel.controller.displaysSettings
      model.beginNewLayout()
      model.layoutName = DisplaysNameForm("   ")
      await model.submitLayoutEditor()
      XCTAssertEqual(model.layoutEditor, .new, "nothing to save yet")
      XCTAssertTrue(panel.controller.displayLayoutsState.layouts.isEmpty)
      XCTAssertNil(model.layoutStatus)
    }
  }

  func testAFailedSwapSaysSoInTheLayoutsErrorBoxAndTakesFocus() async throws {
    try await withTwoDisplayPanel { panel, bridge in
      let model = panel.controller.displaysSettings
      bridge.failOnce = "primary=b"
      bridge.failAfterMutation = true
      await model.swapWallpapers("primary", "secondary")
      XCTAssertEqual(bridge.assignments, ["primary": "a", "secondary": "b"], "the displays were put back")
      let error = try XCTUnwrap(model.layoutError)
      XCTAssertTrue(error.hasPrefix(WallpaperDisplayLayoutError.restored("").errorDescription ?? "?"), error)
      XCTAssertNil(model.layoutStatus)
      XCTAssertEqual(model.layoutFocus, .error)
      XCTAssertEqual(model.transferSource, "primary", "only the display it was started from repeats it")
      XCTAssertNil(panel.controller.errors.actionError, "the box reports it, not the window's banner")

      bridge.failAfterMutation = false
      await model.swapWallpapers("secondary", "primary")
      XCTAssertNil(model.layoutError, "the next action clears the last one's error")
      XCTAssertEqual(model.layoutStatus, "Wallpaper arrangement applied.")
      XCTAssertEqual(model.transferSource, "secondary")
      XCTAssertEqual(bridge.assignments, ["primary": "b", "secondary": "a"])
    }
  }

  func testCopyingNeedsAChosenPeerThatIsStillEligible() async throws {
    try await withTwoDisplayPanel { panel, bridge in
      let controller = panel.controller
      let model = controller.displaysSettings
      XCTAssertNil(model.peer(of: "primary"), "nothing chosen yet")
      model.peers["primary"] = "secondary"
      XCTAssertEqual(model.peer(of: "primary")?.id, "secondary")
      await model.copyWallpaper(from: "primary", to: "secondary")
      XCTAssertEqual(bridge.assignments, ["primary": "a", "secondary": "a"])
      XCTAssertEqual(model.layoutStatus, "Wallpaper arrangement applied.")

      bridge.eligible.remove("secondary")
      try await panel.store.refreshAllAsync()
      XCTAssertNil(model.peer(of: "primary"), "a peer that is no longer independent is not offered")
      XCTAssertTrue(controller.transferPeers(of: "primary").isEmpty)
    }
  }

  func testALayoutWhoseDisplayIsGoneStaysListedWithItsReasonAndFailsToApply() async throws {
    try await withTwoDisplayPanel { panel, bridge in
      let controller = panel.controller
      let model = controller.displaysSettings
      let layout = try controller.displayLayouts.save(
        name: String(repeating: "长い名称", count: 25),
        assignments: WallpaperDisplayTransfer.capture(panel.store.displayTransferSnapshot()))
      bridge.eligible.remove("secondary")
      try await panel.store.refreshAllAsync()
      let listed = try XCTUnwrap(controller.displayLayoutsState.layouts.first)
      XCTAssertNotNil(listed.unavailableReason, "which disables Apply and is shown under the layout")
      await model.applyLayout(layout.id)
      XCTAssertNotNil(model.layoutError)
      XCTAssertEqual(bridge.assignments, ["primary": "a", "secondary": "b"])
      // Cancelling a rename keeps focus on the layout's button even in a compact language.
      model.beginRenaming(listed)
      model.cancelLayoutEditor()
      XCTAssertEqual(model.layoutFocus, .rename(layout.id))
    }
  }

  func testSavingTheLastAllowedLayoutSendsFocusToAnActionThatStillWorks() async throws {
    try await withTwoDisplayPanel { panel, _ in
      let controller = panel.controller
      let model = controller.displaysSettings
      let assignments = try WallpaperDisplayTransfer.capture(panel.store.displayTransferSnapshot())
      for index in 1..<WallpaperDisplayLayoutStore.limit {
        try controller.displayLayouts.save(name: "Layout \(index)", assignments: assignments)
      }
      model.beginNewLayout()
      model.layoutName = DisplaysNameForm("Last layout")
      await model.submitLayoutEditor()
      let state = controller.displayLayoutsState
      XCTAssertTrue(state.isFull, "Save current layout… is now disabled")
      guard case .apply(let id) = model.layoutFocus else {
        return XCTFail("focus must not stay on the disabled button: \(String(describing: model.layoutFocus))")
      }
      let target = try XCTUnwrap(state.layouts.first { $0.id == id })
      XCTAssertNil(target.unavailableReason, "an Apply button that is enabled")
    }
  }

  // MARK: Saved playlists

  func testASavedPlaylistIsNamedRenamedAndDeletedThroughTheInlineForms() async throws {
    try await withPanel { panel in
      let controller = panel.controller
      let model = controller.displaysSettings
      panel.playlists.update("primary") { $0.mode = .rotate }
      model.beginSavingPlan(of: "primary")
      XCTAssertEqual(model.planEditor, .save(display: "primary"))
      model.planName = DisplaysNameForm("  Weekday  ")
      try await model.submitPlanEditor()
      XCTAssertNil(model.planEditor)
      let plan = try XCTUnwrap(controller.playlistPlanRows.first)
      XCTAssertEqual(plan.name, "Weekday")

      model.beginRenaming(plan)
      XCTAssertEqual(model.planName.text, "Weekday")
      model.planName = DisplaysNameForm("Weekday")
      try await model.submitPlanEditor()
      XCTAssertNil(model.planEditor, "renaming to the name it has changes nothing and closes the form")
      model.beginRenaming(plan)
      model.planName = DisplaysNameForm("Evening")
      try await model.submitPlanEditor()
      XCTAssertEqual(controller.playlistPlanRows.map(\.name), ["Evening"])
      XCTAssertEqual(model.planFocus, .rename(plan.id), "focus goes back to the row's Rename…")
      model.consumePlanFocus()
      model.beginRenaming(plan)
      model.cancelPlanEditor()
      XCTAssertEqual(model.planFocus, .rename(plan.id), "and so does Cancel")

      model.askToDeletePlan(plan.id)
      XCTAssertEqual(model.planDeleteArmed, plan.id)
      XCTAssertEqual(model.planFocus, .confirmDelete(plan.id), "focus moves to the confirming Delete")
      model.cancelPlanDelete()
      XCTAssertNil(model.planDeleteArmed)
      XCTAssertEqual(model.planFocus, .delete(plan.id), "cancelling returns to Delete…")
      model.askToDeletePlan(plan.id)
      try await model.deletePlan(plan.id)
      XCTAssertTrue(controller.playlistPlanRows.isEmpty)
      XCTAssertNil(model.planDeleteArmed)
    }
  }

  func testAPlanFormThatTheStoreRefusesStaysOpen() async throws {
    try await withPanel { panel in
      let model = panel.controller.displaysSettings
      model.beginSavingPlan(of: "primary")
      model.planName = DisplaysNameForm("Name")
      // The primary display has no playlist to save only when it is not independent; make it a mirror.
      panel.store.settingsSnapshot.displays[0].mode = .mirror
      do {
        try await model.submitPlanEditor()
        XCTFail("a mirror has no playlist to save")
      } catch {}
      XCTAssertEqual(model.planEditor, .save(display: "primary"), "the form stays so the name is not lost")
      XCTAssertTrue(panel.controller.playlistPlanRows.isEmpty)
    }
  }

  // MARK: How often

  func testChoosingCustomSendsNothingAndAsksForTheMinutesField() async throws {
    try await withPanel { panel in
      let controller = panel.controller
      let model = controller.displaysSettings
      panel.playlists.update("primary") { $0.mode = .rotate }
      let before = panel.playlists.playlist(for: "primary")
      try await model.chooseInterval(.custom, display: "primary")
      XCTAssertEqual(panel.playlists.playlist(for: "primary"), before, "Custom changes nothing by itself")
      XCTAssertEqual(model.intervalDraft(of: "primary").selection(for: before), .custom)
      XCTAssertEqual(model.intervalFocus, "primary")
      model.consumeIntervalFocus()
      XCTAssertNil(model.intervalFocus)
      XCTAssertNil(model.intervalDraft(of: "primary").text, "the field shows the saved minutes until typing")
    }
  }

  func testATypedNumberOfMinutesIsSavedOnCommitAndTheDraftEnds() async throws {
    try await withPanel { panel in
      let model = panel.controller.displaysSettings
      panel.playlists.update("primary") { $0.mode = .rotate }
      try await model.chooseInterval(.custom, display: "primary")
      model.setIntervalText("45", display: "primary")
      let saved = try await model.commitCustomInterval(display: "primary")
      XCTAssertTrue(saved)
      XCTAssertEqual(panel.playlists.playlist(for: "primary").interval, 45)
      XCTAssertEqual(panel.playlists.playlist(for: "primary").trigger, .interval)
      XCTAssertEqual(model.intervalDraft(of: "primary"), DisplaysIntervalDraft(), "the draft is gone")
      XCTAssertEqual(
        model.intervalDraft(of: "primary").selection(for: panel.playlists.playlist(for: "primary")), .custom,
        "45 is not a menu time, so the menu keeps saying Custom")

      // A number that equals a menu time collapses back to that menu entry.
      try await model.chooseInterval(.custom, display: "primary")
      model.setIntervalText("60", display: "primary")
      try await model.commitCustomInterval(display: "primary")
      XCTAssertEqual(
        model.intervalDraft(of: "primary").selection(for: panel.playlists.playlist(for: "primary")), .preset(60))
    }
  }

  func testLeavingTheFieldWithoutAWholeNumberDiscardsBothDraftsAndSendsNothing() async throws {
    try await withPanel { panel in
      let model = panel.controller.displaysSettings
      panel.playlists.update("primary") { $0.mode = .rotate; $0.interval = 30 }
      for typed in ["", "abc", "7.5", "0", "10081"] {
        try await model.chooseInterval(.custom, display: "primary")
        model.setIntervalText(typed, display: "primary")
        try await model.leaveCustomInterval(display: "primary")
        XCTAssertEqual(panel.playlists.playlist(for: "primary").interval, 30, typed.debugDescription)
        XCTAssertEqual(model.intervalDraft(of: "primary"), DisplaysIntervalDraft(), "\(typed.debugDescription): the menu shows the saved interval again")
      }
      // Leaving a field that was never touched is not an action at all.
      try await model.leaveCustomInterval(display: "primary")
      XCTAssertEqual(panel.playlists.playlist(for: "primary").interval, 30)
    }
  }

  /// Return on a text that is not a whole number of minutes in range sends nothing and keeps the
  /// text, the Custom choice and the keyboard, with the note turned into what the field accepts;
  /// only leaving the field discards them.
  func testReturnOnARefusedTextKeepsItInTheFieldUntilTheFieldIsLeft() async throws {
    try await withPanel { panel in
      let model = panel.controller.displaysSettings
      panel.playlists.update("primary") { $0.mode = .rotate; $0.interval = 30 }
      try await model.chooseInterval(.custom, display: "primary")
      model.consumeIntervalFocus()
      let untouched = try await model.commitCustomInterval(display: "primary")
      XCTAssertFalse(untouched, "Return on the saved minutes, untouched, is not a change")
      XCTAssertTrue(model.intervalDraft(of: "primary").customChosen, "the field stays open")

      for typed in ["0", "abc", "10081", "7.5", ""] {
        model.setIntervalText(typed, display: "primary")
        let saved = try await model.commitCustomInterval(display: "primary")
        XCTAssertFalse(saved, typed.debugDescription)
        let draft = model.intervalDraft(of: "primary")
        XCTAssertEqual(draft.text, typed, "\(typed.debugDescription) stays to be corrected")
        XCTAssertTrue(draft.customChosen, "the menu keeps saying Custom")
        XCTAssertTrue(draft.isInvalid, "the field says what it accepts")
        XCTAssertEqual(model.intervalFocus, "primary", "the keyboard stays in the field")
        model.consumeIntervalFocus()
        XCTAssertEqual(panel.playlists.playlist(for: "primary").interval, 30)
      }
      model.setIntervalText("4", display: "primary")
      XCTAssertFalse(model.intervalDraft(of: "primary").isInvalid, "typing again ends the alert")
      model.setIntervalText("x", display: "primary")
      try await model.leaveCustomInterval(display: "primary")
      XCTAssertEqual(model.intervalDraft(of: "primary"), DisplaysIntervalDraft(), "leaving discards it")
    }
  }

  func testLeavingTheFieldWithANumberSavesIt() async throws {
    try await withPanel { panel in
      let model = panel.controller.displaysSettings
      panel.playlists.update("primary") { $0.mode = .rotate }
      try await model.chooseInterval(.custom, display: "primary")
      model.setIntervalText("90", display: "primary")
      try await model.leaveCustomInterval(display: "primary")
      XCTAssertEqual(panel.playlists.playlist(for: "primary").interval, 90)
    }
  }

  func testUnlockStoresTheTriggerWithoutRewritingTheMinutesAndATimeBringsTheTimerBack() async throws {
    try await withPanel { panel in
      let model = panel.controller.displaysSettings
      panel.playlists.update("primary") { $0.mode = .rotate; $0.interval = 30 }
      try await model.chooseInterval(.unlock, display: "primary")
      XCTAssertEqual(panel.playlists.playlist(for: "primary").trigger, .unlock)
      XCTAssertEqual(panel.playlists.playlist(for: "primary").interval, 30, "not rewritten")
      XCTAssertEqual(
        model.intervalDraft(of: "primary").selection(for: panel.playlists.playlist(for: "primary")), .unlock)
      try await model.chooseInterval(.preset(60), display: "primary")
      XCTAssertEqual(panel.playlists.playlist(for: "primary").trigger, .interval)
      XCTAssertEqual(panel.playlists.playlist(for: "primary").interval, 60)
      do {
        try await model.chooseInterval(.preset(7), display: "primary")
        XCTFail("7 minutes is not a time the menu offers")
      } catch { XCTAssertTrue(error is InvalidControlValue) }
      XCTAssertEqual(panel.playlists.playlist(for: "primary").interval, 60)
    }
  }

  func testARefusedTypedValueStaysInTheField() async throws {
    try await withPanel { panel in
      let model = panel.controller.displaysSettings
      panel.playlists.update("primary") { $0.mode = .rotate; $0.interval = 30 }
      try await model.chooseInterval(.custom, display: "primary")
      model.setIntervalText("45", display: "primary")
      // The display stops being independent between typing and committing.
      panel.store.settingsSnapshot.displays[0].mode = .mirror
      do {
        try await model.commitCustomInterval(display: "primary")
        XCTFail("a mirror has no playlist")
      } catch {}
      XCTAssertEqual(model.intervalDraft(of: "primary").text, "45", "the number stays next to the error")
      XCTAssertTrue(model.intervalDraft(of: "primary").customChosen)
      XCTAssertEqual(panel.playlists.playlist(for: "primary").interval, 30)
    }
  }

  // MARK: The display's own list

  private func installLibrary(_ panel: PanelFixture) {
    panel.store.librarySnapshot.wallpapers = ["a", "b", "c", "d"].map {
      OrganizationFixtures.wallpaper($0, title: $0 == "b" ? "B <img src=x onerror=alert(1)>" : $0)
    }
  }

  func testTheMoveButtonsReorderTheListAndAnnounceTheNewPlace() async throws {
    try await withPanel { panel in
      installLibrary(panel)
      let model = panel.controller.displaysSettings
      panel.playlists.update("primary") { $0.mode = .rotate; $0.source = .list; $0.wallpaperIDs = ["a", "b", "c"] }
      try await model.moveListWallpaper("a", by: 1, display: "primary")
      XCTAssertEqual(panel.playlists.playlist(for: "primary").wallpaperIDs, ["b", "a", "c"])
      XCTAssertEqual(model.listAnnouncement, "a moved to position 2 of 3.")
      XCTAssertEqual(model.listFocus, .init(display: "primary", id: "a", button: .down), "Move down still works")
      try await model.moveListWallpaper("a", by: 1, display: "primary")
      XCTAssertEqual(panel.playlists.playlist(for: "primary").wallpaperIDs, ["b", "c", "a"])
      XCTAssertEqual(model.listAnnouncement, "a moved to position 3 of 3.")
      XCTAssertEqual(
        model.listFocus, .init(display: "primary", id: "a", button: .up),
        "Move down is disabled on the last row, so focus goes to Move up")
      model.consumeListFocus()
      XCTAssertNil(model.listFocus)
      try await model.moveListWallpaper("a", by: 1, display: "primary")
      XCTAssertEqual(panel.playlists.playlist(for: "primary").wallpaperIDs, ["b", "c", "a"], "already last")
      try await model.moveListWallpaper("a", by: -1, display: "primary")
      XCTAssertEqual(panel.playlists.playlist(for: "primary").wallpaperIDs, ["b", "a", "c"])
      XCTAssertEqual(PlaylistStore(defaults: panel.defaults).playlist(for: "primary").wallpaperIDs, ["b", "a", "c"])
    }
  }

  func testAMoveCountsOnlyWallpapersTheLibraryStillHasAndKeepsTheOthersInTheList() async throws {
    try await withPanel { panel in
      installLibrary(panel)
      let model = panel.controller.displaysSettings
      panel.playlists.update("primary") { $0.mode = .rotate; $0.source = .list; $0.wallpaperIDs = ["a", "gone", "b"] }
      try await model.moveListWallpaper("a", by: 1, display: "primary")
      XCTAssertEqual(panel.playlists.playlist(for: "primary").wallpaperIDs, ["gone", "b", "a"])
      XCTAssertEqual(model.listAnnouncement, "a moved to position 2 of 2.", "counted among the visible ones")
    }
  }

  func testADragMovesTheRowAndAStaleDragIsRefusedWithoutOverwritingTheNewList() async throws {
    try await withPanel { panel in
      installLibrary(panel)
      let model = panel.controller.displaysSettings
      panel.playlists.update("primary") { $0.mode = .rotate; $0.source = .list; $0.wallpaperIDs = ["a", "b", "c"] }
      try await model.dropListWallpaper("b", onto: "c", expected: ["a", "b", "c"], display: "primary")
      XCTAssertEqual(panel.playlists.playlist(for: "primary").wallpaperIDs, ["a", "c", "b"])
      XCTAssertEqual(PlaylistStore(defaults: panel.defaults).playlist(for: "primary").wallpaperIDs, ["a", "c", "b"])

      // A drag that started from this order is dropped after a wallpaper was added meanwhile.
      let started = panel.playlists.playlist(for: "primary").wallpaperIDs
      panel.playlists.add(["d"], to: "primary")
      do {
        try await model.dropListWallpaper("a", onto: "b", expected: started, display: "primary")
        XCTFail("the list changed while the row was dragged")
      } catch {}
      XCTAssertEqual(panel.playlists.playlist(for: "primary").wallpaperIDs, ["a", "c", "b", "d"], "d was not dropped")

      // Dropping a row on itself, or on nothing, is not a change.
      try await model.dropListWallpaper("a", onto: "a", expected: ["a", "c", "b", "d"], display: "primary")
      XCTAssertEqual(panel.playlists.playlist(for: "primary").wallpaperIDs, ["a", "c", "b", "d"])
    }
  }

  // MARK: The time rule editor

  private func makeRulePanel() throws -> PanelFixture {
    let panel = try makeController()
    panel.store.settingsSnapshot.displays = [
      OrganizationFixtures.display("primary", title: "Main (1 - Primary)")
    ]
    panel.store.librarySnapshot.wallpapers = [
      OrganizationFixtures.wallpaper("a", title: "Ocean <img src=x>"), OrganizationFixtures.wallpaper("b", title: "Evening"),
    ]
    return panel
  }

  func testAWeekdayRuleIsSavedEditedIntoASunsetRuleAndRemovedWithFocusWhereItBelongs() async throws {
    let panel = try makeRulePanel()
    defer { Task { await panel.shutdown() } }
    let controller = panel.controller
    let model = controller.displaysSettings
    try await controller.setAutomationMode(.schedule)

    model.beginRule(display: "primary")
    XCTAssertNotNil(model.ruleEditor)
    XCTAssertEqual(model.automationFocus, .ruleEvent(display: "primary"), "the editor opens on When")
    model.consumeAutomationFocus()
    model.ruleEditor?.choose(AutomationRuleEdit.weekdaysOnly)
    model.ruleEditor?.time = try XCTUnwrap(ClockMinute(minutes: 9 * 60 + 15))
    model.ruleEditor?.target = wallpaper("a")
    try await model.saveRule()
    let saved = try XCTUnwrap(panel.automations.configuration(for: "primary").rules.first)
    XCTAssertEqual(saved.weekdays, [2, 3, 4, 5, 6])
    XCTAssertEqual(saved.minute, 555)
    XCTAssertNil(model.ruleEditor, "the form closes")
    XCTAssertEqual(model.automationFocus, .addRule(display: "primary"), "a new rule returns to Add time rule")

    model.consumeAutomationFocus()
    model.beginRule(display: "primary", editing: saved)
    model.ruleEditor?.time = try XCTUnwrap(ClockMinute(minutes: 0))
    model.ruleEditor?.event = .sunset
    model.ruleEditor?.offsetText = "-25"
    try await model.saveRule()
    let edited = try XCTUnwrap(panel.automations.configuration(for: "primary").rules.first)
    XCTAssertEqual(edited.id, saved.id, "the same rule")
    XCTAssertEqual(edited.event, .sunset)
    XCTAssertEqual(edited.offset, -25)
    XCTAssertEqual(model.automationFocus, .editRule(display: "primary", id: saved.id))

    // Back to a time rule: the stray offset is dropped; cancelling returns to the rule's Edit button.
    model.beginRule(display: "primary", editing: edited)
    model.ruleEditor?.event = .time
    model.ruleEditor?.time = try XCTUnwrap(ClockMinute(minutes: 630))
    model.ruleEditor?.offsetText = "181"
    try await model.saveRule()
    XCTAssertEqual(panel.automations.configuration(for: "primary").rules.first?.offset, 0)
    XCTAssertEqual(panel.automations.configuration(for: "primary").rules.first?.minute, 630)
    model.consumeAutomationFocus()
    model.beginRule(display: "primary", editing: edited)
    model.cancelRule()
    XCTAssertNil(model.ruleEditor)
    XCTAssertEqual(model.automationFocus, .editRule(display: "primary", id: saved.id))

    // Removing a rule closes its open editor and returns to Add time rule.
    model.beginRule(display: "primary", editing: edited)
    try await model.removeRule(saved.id, display: "primary")
    XCTAssertTrue(panel.automations.configuration(for: "primary").rules.isEmpty)
    XCTAssertNil(model.ruleEditor)
    XCTAssertEqual(model.automationFocus, .addRule(display: "primary"))
  }

  func testARuleWithNoWeekdayIsNotSavedAndTheEditorSaysSoAndFocusesTheFirstDay() async throws {
    let panel = try makeRulePanel()
    defer { Task { await panel.shutdown() } }
    let model = panel.controller.displaysSettings
    try await panel.controller.setAutomationMode(.schedule)
    model.beginRule(display: "primary")
    model.ruleEditor?.weekdays = []
    model.ruleEditor?.target = wallpaper("a")
    try await model.saveRule()
    XCTAssertTrue(panel.automations.configuration(for: "primary").rules.isEmpty)
    XCTAssertEqual(model.ruleEditor?.showsDaysError, true, "the inline alert shows")
    XCTAssertEqual(model.automationFocus, .firstDay)
    XCTAssertNotNil(model.ruleEditor, "the form stays open")
    model.ruleEditor?.toggle(2)
    XCTAssertEqual(model.ruleEditor?.showsDaysError, false, "a day ends the alert")
    try await model.saveRule()
    XCTAssertEqual(panel.automations.configuration(for: "primary").rules.count, 1)
  }

  func testAFormThatIsNotCompleteSendsNothing() async throws {
    let panel = try makeRulePanel()
    defer { Task { await panel.shutdown() } }
    let model = panel.controller.displaysSettings
    try await panel.controller.setAutomationMode(.schedule)
    model.beginRule(display: "primary")
    try await model.saveRule()
    XCTAssertTrue(panel.automations.configuration(for: "primary").rules.isEmpty, "no target chosen")
    XCTAssertNotNil(model.ruleEditor)
    model.ruleEditor?.target = wallpaper("a")
    model.ruleEditor?.event = .sunrise
    model.ruleEditor?.offsetText = "500"
    try await model.saveRule()
    XCTAssertTrue(panel.automations.configuration(for: "primary").rules.isEmpty, "an offset outside three hours")
  }

  // MARK: Spaces

  func testForgettingAMissingDesktopMovesFocusToTheNextForgetButtonElseTheModeMenu() async throws {
    var topology: [String: WallpaperDisplaySpaces]? = [
      "1": .init(
        displayUUID: "screen",
        spaces: [.init(id: "space-a", number: 1), .init(id: "space-b", number: 2), .init(id: "space-c", number: 3)],
        current: "space-a")
    ]
    let spaces = WallpaperSpaceMonitor(provider: { topology })
    spaces.refresh()
    defer { spaces.stop() }
    let panel = try makeController(spaces: spaces)
    defer { Task { await panel.shutdown() } }
    panel.store.settingsSnapshot.displays = [OrganizationFixtures.display("primary", title: "Main (1 - Primary)")]
    panel.store.librarySnapshot.wallpapers = [OrganizationFixtures.wallpaper("a")]
    let controller = panel.controller
    let model = controller.displaysSettings
    try await controller.setAutomationMode(.spaces)
    for id in ["space-b", "space-c"] { try await controller.setAutomationDesktop(id, to: wallpaper("a")) }
    topology?["1"]?.spaces = [.init(id: "space-a", number: 1)]
    spaces.refresh()
    XCTAssertEqual(controller.automationState(for: "primary").missingDesktops.map(\.id), ["space-b", "space-c"])

    try await model.forgetDesktop("space-b", display: "primary")
    XCTAssertEqual(model.automationFocus, .forget(display: "primary", desktop: "space-c"))
    try await model.forgetDesktop("space-c", display: "primary")
    XCTAssertEqual(model.automationFocus, .desktopsToggle(display: "primary"))
    XCTAssertTrue(controller.automationState(for: "primary").missingDesktops.isEmpty)
  }

  // MARK: Sunrise and sunset

  func testChoosingAutomaticRequestsLocationAndChangingSourceStopsIt() async throws {
    let panel = try makeRulePanel()
    defer { Task { await panel.shutdown() } }
    let model = panel.controller.displaysSettings
    XCTAssertEqual(panel.solarLocationManager.authorizationReads, 0)
    try await model.setSolarSource(.automatic)
    XCTAssertEqual(model.solarSource, .automatic)
    XCTAssertEqual(panel.solarLocationManager.requests, 1)
    panel.solarLocationManager.changeAuthorization(to: .authorizedAlways)
    XCTAssertEqual(panel.solarLocationManager.starts, 1)
    panel.solarLocationManager.send(.init(latitude: 30.08, longitude: 103.87))
    XCTAssertEqual(panel.controller.solarLocation?.latitude, 30.08)

    try await model.setSolarSource(.coordinates)
    XCTAssertEqual(panel.solarLocationManager.stops, 1)
    model.latitudeText = "51.5"
    model.longitudeText = "-0.1"
    let saved = try await model.saveLocation()
    XCTAssertTrue(saved)
    panel.solarLocationManager.send(.init(latitude: 40.7, longitude: -74.0))
    XCTAssertEqual(panel.controller.solarLocation?.latitude, 51.5)
  }

  func testLocationPermissionChangesReachThePanelWithoutALocationFix() async throws {
    let panel = try makeRulePanel()
    defer { Task { await panel.shutdown() } }
    let model = panel.controller.displaysSettings
    try await model.setSolarSource(.automatic)
    XCTAssertFalse(model.solarLocationDenied)
    panel.solarLocationManager.changeAuthorization(to: .denied)
    XCTAssertTrue(model.solarLocationDenied)
    panel.solarLocationManager.changeAuthorization(to: .authorizedAlways)
    XCTAssertFalse(model.solarLocationDenied)
    XCTAssertEqual(panel.solarLocationManager.starts, 1)
    XCTAssertNil(panel.controller.solarLocation)
  }

  func testTheLocationIsSavedFromTheTypedFieldsAndClearedAndInvalidTextChangesNothing() async throws {
    let panel = try makeRulePanel()
    defer { Task { await panel.shutdown() } }
    let controller = panel.controller
    let model = controller.displaysSettings
    model.latitudeText = "-33.87"
    model.longitudeText = "151.21"
    let saved = try await model.saveLocation()
    XCTAssertTrue(saved)
    XCTAssertEqual(controller.solarLocation, WallpaperSolarLocation(latitude: -33.87, longitude: 151.21))
    XCTAssertEqual(WallpaperAutomationStore(defaults: panel.defaults).location?.longitude, 151.21)
    XCTAssertNil(model.latitudeText, "the fields follow the saved location again")

    // One field edited: the other keeps the saved value.
    model.latitudeText = "10"
    try await model.saveLocation()
    XCTAssertEqual(controller.solarLocation, WallpaperSolarLocation(latitude: 10, longitude: 151.21))

    for (latitude, longitude) in [("95", "10"), ("10", "181"), ("abc", "10"), ("", "10")] {
      model.latitudeText = latitude
      model.longitudeText = longitude
      let accepted = try await model.saveLocation()
      XCTAssertFalse(accepted, "\(latitude), \(longitude)")
      XCTAssertEqual(controller.solarLocation, WallpaperSolarLocation(latitude: 10, longitude: 151.21))
      XCTAssertNil(model.latitudeText, "the saved location is put back in the fields")
    }

    try await model.clearLocation()
    XCTAssertNil(controller.solarLocation)
    XCTAssertNil(model.latitudeText)
    XCTAssertNil(model.longitudeText)
  }

  func testTheLatitudeAndLongitudeFieldsCheckTheirRangesBeforeTheSaveButtonIsOffered() {
    XCTAssertTrue(DisplaysSolarGroup.isValid("-90", within: -90...90, locale: english))
    XCTAssertTrue(DisplaysSolarGroup.isValid("35.68", within: -90...90, locale: english))
    XCTAssertFalse(DisplaysSolarGroup.isValid("90.1", within: -90...90, locale: english))
    XCTAssertFalse(DisplaysSolarGroup.isValid("", within: -180...180, locale: english))
    XCTAssertTrue(DisplaysSolarGroup.isValid("180", within: -180...180, locale: english))
  }

  // MARK: Values on the way

  func testAControlShowsItsNewValueAtOnceAndTheStoredOneOnceTheChangeRan() async throws {
    try await withPanel { panel in
      let controller = panel.controller
      let model = controller.displaysSettings
      let gate = QueueGate()
      let ran = expectation(description: "the change ran")
      let binding = model.binding("test", current: false) { value in
        await gate.wait()
        XCTAssertTrue(value)
        ran.fulfill()
      }
      XCTAssertFalse(binding.wrappedValue)
      binding.wrappedValue = true
      XCTAssertTrue(binding.wrappedValue, "the control shows what was chosen while the change is on the way")
      XCTAssertTrue(controller.isBusy("test"))
      gate.open()
      await fulfillment(of: [ran], timeout: 2)
      try await panel.waitUntil { model.drafts["test"] == nil }
      XCTAssertFalse(binding.wrappedValue, "back to the stored value, which a real change would have updated")
    }
  }

  func testARefusedChangeTakesTheOldValueBackAndReachesTheBanner() async throws {
    try await withPanel { panel in
      let controller = panel.controller
      let model = controller.displaysSettings
      let binding = model.binding("refused", current: 30) { _ in throw InvalidControlValue() }
      binding.wrappedValue = 45
      XCTAssertEqual(binding.wrappedValue, 45)
      try await panel.waitUntil { model.drafts["refused"] == nil }
      XCTAssertEqual(binding.wrappedValue, 30)
      XCTAssertEqual(controller.errors.actionError, InvalidControlValue().localizedDescription)
    }
  }

  // MARK: Disclosures

  func testEachDisplaysDisclosureOpensOnItsOwn() async throws {
    try await withPanel { panel in
      let model = panel.controller.displaysSettings
      let item = DisplaysSettingsSection.playlist
      XCTAssertFalse(model.isOpen(item, display: "primary"), "closed until opened")
      model.setOpen(true, item, display: "primary")
      XCTAssertTrue(model.isOpen(item, display: "primary"))
      XCTAssertFalse(model.isOpen(item, display: "secondary"), "another display's Playlist stays shut")
      XCTAssertFalse(model.isOpen(DisplaysSettingsSection.automation, display: "primary"))
      model.setOpen(false, item, display: "primary")
      XCTAssertFalse(model.isOpen(item, display: "primary"))
    }
  }

  /// A disclosure is open while the person opened it or the search opens it on that display; the
  /// person's choice outlives the search.
  func testADisclosureIsOpenByThePersonOrByTheSearchOnThatDisplay() async throws {
    try await withPanel { panel in
      let model = panel.controller.displaysSettings
      let item = DisplaysSettingsSection.playlist
      XCTAssertTrue(model.isOpen(item, display: "primary", searchOpens: true))
      XCTAssertFalse(model.isOpen(item, display: "primary", searchOpens: false))
      model.setOpen(true, item, display: "primary")
      XCTAssertTrue(model.isOpen(item, display: "primary", searchOpens: false), "opened by hand stays open")
      panel.controller.settings.query = "Shuffle"
      XCTAssertTrue(model.isOpen(item, display: "secondary"), "without a card's answer, a match inside opens it")
      panel.controller.settings.query = ""
      XCTAssertFalse(model.isOpen(item, display: "secondary"), "closed again")
    }
  }

  // MARK: The rows' own rules

  func testAHeldPlaylistOffersResumeOnlyWhileItIsNotOff() async throws {
    try await withPanel { panel in
      let controller = panel.controller
      panel.playlists.update("primary") { $0.mode = .rotate }
      XCTAssertFalse(controller.playlistState(for: "primary").showsResume)
      panel.playlists.setHold(.removedWallpaper, on: "primary")
      XCTAssertTrue(controller.playlistState(for: "primary").showsResume)
      panel.playlists.update("primary") { $0.mode = .off }
      XCTAssertFalse(controller.playlistState(for: "primary").showsResume, "nothing to resume when it is off")
      panel.playlists.setHold(nil, on: "primary")
    }
  }

  /// The note under a display's Frame rate reads the display's own saved rate against the ceiling in
  /// force, and names the setting that set it (the rule itself is `FrameRateCeiling`'s, tested on
  /// its own).
  func testTheFrameRateNoteOfADisplayComparesItsOwnRateWithTheCeilingInForce() async throws {
    try await withPanel { panel in
      try SettingsBFixtures.populate(panel)
      let controller = panel.controller
      let model = controller.displaysSettings
      let rows = Dictionary(uniqueKeysWithValues: controller.displayRows.map { ($0.id, $0) })
      let primary = try XCTUnwrap(rows["primary"])
      let second = try XCTUnwrap(rows["2"])
      XCTAssertEqual(primary.fps, 30)
      XCTAssertEqual(second.fps, 24)
      XCTAssertNil(model.frameRateLimit(of: primary), "nothing limits it below its own rate")

      panel.store.settingsSnapshot.frameRateCap = 24
      panel.store.settingsSnapshot.effectiveFrameRateCap = 24
      let limit = try XCTUnwrap(model.frameRateLimit(of: primary), "30 fps is held to 24")
      XCTAssertEqual(limit.fps, 24)
      XCTAssertEqual(limit.section, .performance, "the saved Frame rate limit holds it")
      XCTAssertNil(model.frameRateLimit(of: second), "a display set to the ceiling is not limited")

      // No limit saved, On battery on Keep running, the low-battery rule reducing quality: the note
      // must not send the user to a Frame rate limit that reads No limit.
      panel.store.settingsSnapshot.frameRateCap = nil
      panel.store.settingsSnapshot.onBatteryPower = true
      panel.store.settingsSnapshot.qualityThrottle = [.lowBattery]
      let lowBattery = try XCTUnwrap(model.frameRateLimit(of: primary))
      XCTAssertEqual(lowBattery.source, .reducedQuality(.lowBattery))
      XCTAssertEqual(lowBattery.section, .playback)
    }
  }
}
