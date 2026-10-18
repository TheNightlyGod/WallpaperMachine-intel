import XCTest

@testable import WallpaperMachine

/// The shell's own state and rules: navigation through the typed actions, the target display, the
/// popovers, Escape, the inspector's width rule, notices and what the support prompt waits for.
@MainActor
final class ShellModelTests: PanelTestCase {
  @MainActor
  private final class Spoken {
    private(set) var lines: [String] = []
    func say(_ line: String) { lines.append(line) }
  }

  // MARK: Navigation

  func testSeveralQuickClicksEndOnTheLastPage() async throws {
    try await withPanel { panel in
      let shell = panel.controller.shell
      shell.open(.settings)
      shell.open(.wallpaper)
      let last = shell.open(.settings)
      await last.value
      XCTAssertEqual(shell.selection, .settings, "the newest choice lands last")
      XCTAssertNil(panel.controller.errors.message)
    }
  }

  func testOpeningSteamWorkshopInATestSearchesTheFixtureAndNeverSteam() async throws {
    try await withPanel { panel in
      let before = OfflineSteamProtocol.requests
      await panel.controller.shell.open(.workshop).value
      try await panel.waitUntil(timeout: 10) { panel.workshop.errorMessage != nil }
      XCTAssertGreaterThan(OfflineSteamProtocol.requests, before, "the first visit's search went out")
      XCTAssertTrue(panel.workshop.items.isEmpty, "and the offline fixture failed it")
    }
  }

  func testATabOpensItsPageAndTheLibrarysViewSurvivesAVisitToSettings() async throws {
    try await withPanel { panel in
      let shell = panel.controller.shell
      XCTAssertEqual(PanelTabs.pages, [.wallpaper, .workshop, .pixiv, .settings])
      panel.controller.library.show(.favorites)
      await shell.open(.settings).value
      XCTAssertEqual(shell.selection, .settings)
      await shell.open(.wallpaper).value
      XCTAssertEqual(shell.selection, .wallpaper)
      XCTAssertEqual(panel.controller.library.scope, .favorites, "Library comes back to its view")
    }
  }

  func testTheTargetDisplayChangesThroughTheTypedActionAndTheLastChoiceWins() async throws {
    try await withPanel { panel in
      panel.configureDisplays()
      let shell = panel.controller.shell
      shell.setTarget("secondary")
      await shell.setTarget("primary").value
      XCTAssertEqual(panel.controller.targetDisplayID, "primary")
      await shell.setTarget("secondary").value
      XCTAssertEqual(panel.navigation.targetDisplayID, "secondary", "AppDelegate reads the same model")
      XCTAssertNil(panel.controller.errors.message)

      await shell.setTarget("unplugged").value
      XCTAssertEqual(panel.navigation.targetDisplayID, "secondary", "an unknown display is refused")
      XCTAssertNotNil(panel.controller.errors.message, "and the refusal is reported")
    }
  }

  func testAMirroredOrDisabledDisplayIsListedAndRefusedAsATarget() async throws {
    try await withPanel { panel in
      panel.configureDisplays()
      panel.store.settingsSnapshot.displays[1].mode = .mirror
      let shell = panel.controller.shell
      XCTAssertFalse(panel.controller.targetDisplays[1].isSelectable)
      await shell.setTarget("secondary").value
      XCTAssertEqual(panel.navigation.targetDisplayID, "primary")
      XCTAssertNotNil(panel.controller.errors.message)
      XCTAssertEqual(
        panel.controller.targetDisplays[1].menuLabel, L("\(panel.controller.targetDisplays[1].title) (mirrored)"))
      panel.store.settingsSnapshot.displays[1].mode = .standalone
      panel.store.settingsSnapshot.displays[1].enabled = false
      XCTAssertEqual(
        panel.controller.targetDisplays[1].menuLabel, L("\(panel.controller.targetDisplays[1].title) (disabled)"))
      XCTAssertEqual(panel.controller.targetDisplays[0].menuLabel, panel.controller.targetDisplays[0].title)
    }
  }

  func testTheToolbarNamesTheTargetByItsScreenNameUnlessAnotherDisplaySharesIt() async throws {
    try await withPanel { panel in
      panel.store.settingsSnapshot.displays = [
        ShellFixtures.display("primary", "Studio Display (primary - Primary)"),
        ShellFixtures.display("secondary", "Built-in Retina Display (secondary - Secondary)"),
      ]
      let displays = panel.controller.targetDisplays
      XCTAssertEqual(displays[0].shortLabel(among: displays), "Studio Display")
      XCTAssertEqual(displays[1].shortLabel(among: displays), "Built-in Retina Display")
      XCTAssertEqual(
        displays[0].menuLabel, "Studio Display (primary - Primary)", "the menu keeps the full title")

      // Two monitors of one model: only the renderer's group tells them apart.
      panel.store.settingsSnapshot.displays = [
        ShellFixtures.display("1", "DELL U2720Q (1 - Primary)"),
        ShellFixtures.display("2", "DELL U2720Q (2 - Secondary)", enabled: false),
      ]
      let twins = panel.controller.targetDisplays
      XCTAssertEqual(twins[0].shortLabel(among: twins), "DELL U2720Q (1 - Primary)")
      XCTAssertEqual(
        twins[1].shortLabel(among: twins), L("\("DELL U2720Q (2 - Secondary)") (disabled)"),
        "a disabled display still says so")
    }
  }

  func testOnlyTheRenderersTrailingGroupIsDroppedFromADisplayTitle() {
    XCTAssertEqual(TargetDisplayOption.name(of: "Studio Display (2 - Primary)"), "Studio Display")
    XCTAssertEqual(
      TargetDisplayOption.name(of: "LG HDR 4K (DisplayPort) (3 - Secondary)"), "LG HDR 4K (DisplayPort)")
    XCTAssertEqual(TargetDisplayOption.name(of: "Projector (2)"), "Projector (2)", "not a renderer group")
    XCTAssertEqual(TargetDisplayOption.name(of: "(1 - Primary)"), "(1 - Primary)", "nothing in front of it")
    XCTAssertEqual(TargetDisplayOption.name(of: "primary"), "primary")
  }

  func testTheArtworkOpensInstalledWithTheWallpaperSelected() async throws {
    try await withApplyingPanel { panel, _, _ in
      let shell = panel.controller.shell
      await shell.open(.settings).value
      await shell.showInstalled("c").value
      XCTAssertEqual(shell.selection, .wallpaper)
      XCTAssertEqual(panel.controller.selectedWallpaperID, "c", "selected, not applied")
      XCTAssertNil(panel.controller.errors.message)
    }
  }

  // MARK: Recently used

  func testRecentlyUsedListsTheTargetsHistoryNewestFirstMarksTheCurrentOneAndClearsOnlyThatDisplay()
    async throws
  {
    try await withApplyingPanel { panel, _, _ in
      let controller = panel.controller
      let shell = controller.shell
      try await controller.activate("c")
      try await controller.activate("b")
      panel.store.history.recordSwitch(from: nil, to: "a", on: "secondary")
      XCTAssertEqual(shell.recentlyUsed.map(\.id), ["b", "c", "a"])
      XCTAssertEqual(shell.recentlyUsed.map(\.isCurrent), [true, false, false], "the one on show is marked")
      XCTAssertEqual(
        shell.recentlyUsed.last?.row.title, "Ocean <img src=x>", "a title reaches the view as it is written")
      XCTAssertTrue(controller.nowPlaying.canGoPrevious)

      panel.store.librarySnapshot.wallpapers.removeAll { $0.id == "c" }
      XCTAssertEqual(shell.recentlyUsed.map(\.id), ["b", "a"], "a wallpaper that left the library is dropped")

      await shell.clearHistory().value
      XCTAssertTrue(shell.recentlyUsed.isEmpty)
      XCTAssertFalse(controller.nowPlaying.canGoPrevious, "Previous has nothing to go back to")
      XCTAssertEqual(
        panel.store.history.recent(on: "secondary", available: ["a"]), ["a"],
        "another display keeps its own")
    }
  }

  func testApplyingFromRecentlyUsedSwitchesTheTargetDisplayAndTheListFollows() async throws {
    try await withApplyingPanel { panel, bridge, _ in
      let controller = panel.controller
      try await controller.activate("c")
      try await controller.activate("b")
      await controller.shell.apply("c").value
      XCTAssertEqual(bridge.assignments["primary"], "c")
      XCTAssertEqual(controller.shell.recentlyUsed.first?.id, "c")
      XCTAssertTrue(controller.shell.recentlyUsed.first?.isCurrent == true)
    }
  }

  // MARK: Popovers

  func testOnlyOnePopoverIsOpenAtATimeAndClosingOneLeavesTheNewOneAlone() async throws {
    try await withPanel { panel in
      let shell = panel.controller.shell
      XCTAssertFalse(shell.isPopoverOpen)
      let history = shell.popover(.history)
      let downloads = shell.popover(.downloads)
      history.wrappedValue = true
      XCTAssertTrue(shell.isPopoverOpen)
      XCTAssertTrue(history.wrappedValue)
      downloads.wrappedValue = true
      XCTAssertFalse(history.wrappedValue, "opening one closes the other")
      XCTAssertTrue(downloads.wrappedValue)

      history.wrappedValue = false
      XCTAssertTrue(downloads.wrappedValue, "the close of a popover that had already been replaced changes nothing")
      shell.closePopover()
      XCTAssertFalse(shell.isPopoverOpen)
    }
  }

  func testAViewThatCannotUseABindingStillCountsAndNeverClosesAnotherPopover() async throws {
    try await withPanel { panel in
      let shell = panel.controller.shell
      shell.isPopoverOpen = true
      XCTAssertTrue(shell.isPopoverOpen)
      shell.isPopoverOpen = false
      XCTAssertFalse(shell.isPopoverOpen)

      shell.popover(.downloads).wrappedValue = true
      shell.isPopoverOpen = false
      XCTAssertTrue(shell.popover(.downloads).wrappedValue, "it only closes what it opened")
      shell.isPopoverOpen = true
      XCTAssertTrue(shell.popover(.downloads).wrappedValue, "and opens nothing over an open one")
    }
  }

  func testAPopoverOfAnAreaIsCountedWhateverTheShellsOwnPopoverDoes() async throws {
    try await withPanel { panel in
      let controller = panel.controller
      let shell = controller.shell
      // Recently used is open when the library's Import opens over it, and closes after.
      shell.popover(.history).wrappedValue = true
      controller.library.openImport(from: .page)
      shell.popover(.history).wrappedValue = false
      XCTAssertTrue(shell.isPopoverOpen, "the Import popover is still open")
      XCTAssertTrue(shell.blocksSupportPrompt)
      controller.library.closeImport()
      XCTAssertFalse(shell.isPopoverOpen)

      // A popover a view reported belongs to the page it was opened on.
      shell.isPopoverOpen = true
      shell.closePopover()
      XCTAssertFalse(shell.isPopoverOpen, "a change of page forgets it")

      for open in [
        { controller.library.openImport(from: .page) },
        { controller.library.openImport(from: .pill) },
        { controller.downloads.isQueuePopoverOpen = true },
      ] {
        open()
        XCTAssertTrue(shell.isPopoverOpen)
        XCTAssertTrue(controller.supportPrompt.gate.popoverIsOpen, "the support prompt waits behind it")
        controller.library.closeImport()
        controller.downloads.isQueuePopoverOpen = false
        XCTAssertFalse(shell.isPopoverOpen)
        XCTAssertFalse(controller.supportPrompt.gate.popoverIsOpen)
      }
    }
  }

  func testTheImportPillLeavesTheToolbarOnceThePopoverHasShownTheReport() async throws {
    try await withPanel { panel in
      let controller = panel.controller
      let library = controller.library
      XCTAssertFalse(ImportActivityPill.isActive(in: controller))
      try await panel.importOneWallpaper()
      XCTAssertTrue(ImportActivityPill.isActive(in: controller), "a finished import nobody has seen")

      // Opened from the pill and closed again: seen, and nothing else keeps the pill.
      library.toggleImport(from: .pill)
      XCTAssertTrue(ImportActivityPill.isActive(in: controller), "the open popover keeps its anchor")
      library.closeImport()
      XCTAssertFalse(ImportActivityPill.isActive(in: controller))
      XCTAssertFalse(controller.shell.isPopoverOpen)
    }
  }

  // MARK: Escape

  func testEscapeCancelsANameFieldThenClosesAPopoverThenLeavesTheRestToThePage() async throws {
    try await withPanel { panel in
      let shell = panel.controller.shell
      XCTAssertFalse(shell.handleEscape(), "nothing of the shell's is open")
      shell.collectionEditor.beginCreate()
      shell.popover(.history).wrappedValue = true
      XCTAssertTrue(shell.handleEscape())
      XCTAssertFalse(shell.collectionEditor.isOpen, "the field first")
      XCTAssertTrue(shell.isPopoverOpen)
      XCTAssertTrue(shell.handleEscape())
      XCTAssertFalse(shell.isPopoverOpen, "then the popover")
      XCTAssertFalse(shell.handleEscape(), "a selection is the library page's to clear")
    }
  }

  // MARK: Filters sidebar

  func testTheFiltersSidebarIsOneForTheLibraryPagesAndWaitsOutSettings() async throws {
    try await withPanel { panel in
      let controller = panel.controller
      let shell = controller.shell
      XCTAssertFalse(shell.areFiltersShown, "it starts closed")
      shell.toggleFilters()
      XCTAssertTrue(shell.areFiltersShown)
      XCTAssertEqual(controller.library.filterButtonValue, L("Expanded"))
      XCTAssertFalse(shell.isPopoverOpen, "a sidebar is not a popover")
      XCTAssertFalse(shell.blocksSupportPrompt, "and the support prompt does not wait behind it")

      await shell.open(.workshop).value
      XCTAssertTrue(shell.areFiltersShown, "it stays open on the next library page")
      await shell.open(.settings).value
      XCTAssertFalse(shell.areFiltersShown, "Settings has no filters")
      shell.toggleFilters()
      XCTAssertFalse(shell.areFiltersShown, "nor a sidebar to open")
      await shell.open(.pixiv).value
      XCTAssertTrue(shell.areFiltersShown, "and the choice waits for the next page that has them")

      shell.toggleFilters()
      XCTAssertFalse(shell.areFiltersShown)
      XCTAssertEqual(controller.library.filterButtonValue, L("Collapsed"))
    }
  }

  func testInANarrowWindowTheFiltersSidebarAndTheInspectorTakeTurns() async throws {
    try await withPanel { panel in
      let shell = panel.controller.shell
      shell.windowWidthChanged(.regular)
      XCTAssertTrue(shell.isInspectorShown)
      shell.setFiltersShown(true)
      XCTAssertTrue(shell.isInspectorShown, "a wide window has room for both")
      shell.setFiltersShown(false)

      let narrow = try await makeCompact(shell)
      XCTAssertTrue(narrow)
      shell.toggleInspector()
      XCTAssertTrue(shell.isInspectorShown)
      shell.setFiltersShown(true)
      XCTAssertTrue(shell.areFiltersShown)
      XCTAssertFalse(shell.isInspectorShown, "opening the filters closes the inspector")
      shell.toggleInspector()
      XCTAssertTrue(shell.isInspectorShown)
      XCTAssertFalse(shell.areFiltersShown, "and opening the inspector closes the filters")
    }
  }

  /// Takes the shell to a narrow window at once.
  private func makeCompact(_ shell: ShellModel) async throws -> Bool {
    let sleeper = ManualSleeper()
    shell.sleep = sleeper.closure
    shell.windowWidthChanged(.compact)
    let shrinking = shell.pendingCompactChange
    await sleeper.waitUntilPending()
    sleeper.fireNext()
    await shrinking?.value
    return shell.isCompact
  }

  // MARK: Inspector and window width

  func testTheInspectorStartsOpenWhenThereIsRoomAndClosedInANarrowWindowAndAChoiceHolds() async throws {
    try await withPanel { panel in
      let shell = panel.controller.shell
      let sleeper = ManualSleeper()
      shell.sleep = sleeper.closure
      XCTAssertTrue(shell.isInspectorShown, "open until the window says otherwise")

      shell.windowWidthChanged(.unplaced)
      XCTAssertTrue(shell.isInspectorShown, "a view that has not been laid out says nothing")
      shell.windowWidthChanged(.compact)
      XCTAssertFalse(shell.isInspectorShown, "the first measurement is applied at once")
      XCTAssertTrue(shell.isCompact)

      // The toolbar button opens it in the narrow window, and growing the window keeps it open.
      shell.isInspectorShown.toggle()
      XCTAssertTrue(shell.isInspectorShown)
      shell.windowWidthChanged(.regular)
      let growing = shell.pendingCompactChange
      await sleeper.waitUntilPending()
      sleeper.fireNext()
      await growing?.value
      XCTAssertFalse(shell.isCompact)
      XCTAssertTrue(shell.isInspectorShown)

      // Closing it in a wide window holds when the window shrinks.
      shell.isInspectorShown = false
      XCTAssertFalse(shell.isInspectorShown)
      XCTAssertEqual(shell.inspectorChoice, false)
    }
  }

  func testWithoutAChoiceTheInspectorFollowsTheWidthAfterTheResizeSettles() async throws {
    try await withPanel { panel in
      let shell = panel.controller.shell
      let sleeper = ManualSleeper()
      shell.sleep = sleeper.closure
      shell.windowWidthChanged(.regular)
      XCTAssertTrue(shell.isInspectorShown)

      shell.windowWidthChanged(.compact)
      XCTAssertTrue(shell.isInspectorShown, "not while the window is still moving")
      let pending = shell.pendingCompactChange
      await sleeper.waitUntilPending()
      XCTAssertEqual(sleeper.requested, [shell.compactDelay])
      sleeper.fireNext()
      await pending?.value
      XCTAssertFalse(shell.isInspectorShown)

      shell.windowWidthChanged(.regular)
      await sleeper.waitUntilPending()
      shell.windowWidthChanged(.compact)
      XCTAssertEqual(sleeper.cancelledCount, 1, "crossing back before it settled cancels the change")
      XCTAssertEqual(sleeper.pendingCount, 0)
      XCTAssertFalse(shell.isInspectorShown)
      XCTAssertNil(shell.inspectorChoice, "following the width is not a choice")
    }
  }

  func testWhatTheSplitViewWritesBackIsNotAChoice() async throws {
    try await withPanel { panel in
      let shell = panel.controller.shell
      shell.isInspectorShown = shell.isInspectorShown
      XCTAssertNil(shell.inspectorChoice, "presenting the column writes the value on show")
      shell.windowWidthChanged(.compact)
      shell.isInspectorShown = false
      XCTAssertNil(shell.inspectorChoice, "so does collapsing it in a narrow window")
    }
  }

  func testTheInspectorExistsOnLibraryPagesAndNotOnSettings() async throws {
    try await withPanel { panel in
      let shell = panel.controller.shell
      XCTAssertTrue(shell.hasInspector)
      await shell.open(.settings).value
      XCTAssertFalse(shell.hasInspector)
      shell.isInspectorShown = false
      await shell.open(.wallpaper).value
      XCTAssertFalse(shell.isInspectorShown, "the choice waited for a page that has one")
    }
  }

  // MARK: Notices

  func testANoticeIsShownAnnouncedAndExpiresAfterItsLifetime() async throws {
    try await withPanel { panel in
      let shell = panel.controller.shell
      let sleeper = ManualSleeper()
      let spoken = Spoken()
      shell.sleep = sleeper.closure
      shell.announce = { spoken.say($0) }
      XCTAssertEqual(shell.noticeLifetime, .seconds(5))

      shell.say("Deleted “Night”.")
      XCTAssertEqual(shell.notice, "Deleted “Night”.")
      XCTAssertEqual(spoken.lines, ["Deleted “Night”."])
      let first = shell.pendingNotice
      await sleeper.waitUntilPending()
      XCTAssertEqual(sleeper.requested, [.seconds(5)])
      sleeper.fireNext()
      await first?.value
      XCTAssertNil(shell.notice)
    }
  }

  func testANewerNoticeReplacesTheOlderAndTheOlderTimerNeverClearsIt() async throws {
    try await withPanel { panel in
      let shell = panel.controller.shell
      let sleeper = ManualSleeper()
      let spoken = Spoken()
      shell.sleep = sleeper.closure
      shell.announce = { spoken.say($0) }
      shell.say("Deleted “One”.")
      shell.say("Deleted “Two”.")
      XCTAssertEqual(shell.notice, "Deleted “Two”.")
      await sleeper.waitUntilPending()
      XCTAssertEqual(sleeper.cancelledCount, 1, "the older timer was cancelled")
      shell.say("Deleted “Two”.")
      XCTAssertEqual(
        spoken.lines, ["Deleted “One”.", "Deleted “Two”.", "Deleted “Two”."],
        "the same sentence said again is announced again")
      let last = shell.pendingNotice
      await sleeper.waitUntilPending()
      sleeper.fireNext()
      await last?.value
      XCTAssertNil(shell.notice)
    }
  }

  // MARK: Support prompt

  func testTheSupportPromptWaitsForTheGuideAPopoverAndAnApplyThatIsRunning() async throws {
    try await withPanel(welcomeSeen: false) { panel in
      let shell = panel.controller.shell
      XCTAssertTrue(shell.blocksSupportPrompt, "the guide is open")
      panel.controller.markWelcomeSeen()
      XCTAssertFalse(shell.blocksSupportPrompt)
      shell.popover(.history).wrappedValue = true
      XCTAssertTrue(shell.blocksSupportPrompt)
      shell.closePopover()
      XCTAssertFalse(shell.blocksSupportPrompt)
      shell.isWelcomeRequested = true
      XCTAssertTrue(shell.blocksSupportPrompt, "asked for again from Settings")
    }
  }

  func testTheSupportPromptWaitsWhileACommandRuns() async throws {
    try await withPanel { panel in
      let shell = panel.controller.shell
      let gate = AsyncGate()
      XCTAssertFalse(shell.blocksSupportPrompt)
      let running = Task { @MainActor in
        try await panel.store.commands.run { await gate.wait() }
      }
      try await panel.waitUntil { panel.controller.isStoreBusy }
      XCTAssertTrue(shell.blocksSupportPrompt)
      gate.open()
      _ = try await running.value
      XCTAssertFalse(shell.blocksSupportPrompt)
    }
  }
}
