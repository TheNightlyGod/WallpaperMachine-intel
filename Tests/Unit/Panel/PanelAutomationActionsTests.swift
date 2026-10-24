import os
import XCTest

@testable import WallpaperMachine

/// Automatic wallpaper selection: the actions of the page and the state its rows read.
@MainActor
final class PanelAutomationActionsTests: PanelTestCase {
  private func makePanel(spaces: WallpaperSpaceMonitor? = nil) throws -> PanelFixture {
    let panel = try makeController(spaces: spaces)
    panel.store.settingsSnapshot.displays = [
      OrganizationFixtures.display("primary", title: "Main (1 - Primary)"),
      OrganizationFixtures.display("mirrored", mode: .mirror),
    ]
    panel.store.librarySnapshot.wallpapers = [
      OrganizationFixtures.wallpaper("a", title: "Ocean <img src=x>"), OrganizationFixtures.wallpaper("b", title: "Evening"),
      OrganizationFixtures.wallpaper("app", supported: false),
    ]
    return panel
  }

  private func wallpaper(_ id: String) -> WallpaperAutomationTarget { .init(kind: .wallpaper, id: id) }

  private func time(_ minutes: Int) throws -> ClockMinute { try XCTUnwrap(ClockMinute(minutes: minutes)) }

  // MARK: Rules

  func testAWeekdayRuleCanBeSavedEditedIntoASunsetRuleAndRemoved() async throws {
    let panel = try makePanel()
    defer { Task { await panel.shutdown() } }
    let controller = panel.controller
    try await controller.setAutomationMode(.schedule, display: "primary")
    XCTAssertEqual(controller.automationState(for: "primary").mode, .schedule)

    try await controller.saveAutomationRule(
      AutomationRuleEdit(weekdays: AutomationRuleEdit.weekdaysOnly, time: try time(555), target: wallpaper("a")))
    let saved = try XCTUnwrap(controller.automationState(for: "primary").rules.first)
    XCTAssertEqual(saved.weekdays, [2, 3, 4, 5, 6])
    XCTAssertEqual(saved.minute, 555)
    XCTAssertEqual(saved.offset, 0)
    XCTAssertEqual(saved.event, .time)

    // The editor changes the same rule into a sunset rule: the time is ignored, the offset counts.
    try await controller.saveAutomationRule(
      AutomationRuleEdit(
        id: saved.id, weekdays: saved.weekdays, event: .sunset, time: try time(555), offset: -25,
        target: wallpaper("a")))
    var rules = controller.automationState(for: "primary").rules
    XCTAssertEqual(rules.map(\.id), [saved.id], "the same rule, not a second one")
    XCTAssertEqual(rules[0].event, .sunset)
    XCTAssertEqual(rules[0].offset, -25)
    XCTAssertEqual(rules[0].minute, 480)

    // And into a time rule again: a stray offset is dropped.
    try await controller.saveAutomationRule(
      AutomationRuleEdit(
        id: saved.id, weekdays: saved.weekdays, event: .time, time: try time(630), offset: 181, target: wallpaper("a")))
    rules = controller.automationState(for: "primary").rules
    XCTAssertEqual(rules[0].minute, 630)
    XCTAssertEqual(rules[0].offset, 0)
    XCTAssertEqual(WallpaperAutomationStore(defaults: panel.defaults).configuration(for: "primary").rules, rules)

    try await controller.removeAutomationRule(saved.id)
    XCTAssertTrue(controller.automationState(for: "primary").rules.isEmpty)
  }

  func testARuleWithNoWeekdayIsRefusedByTheStoreAndSavesNothing() async throws {
    let panel = try makePanel()
    defer { Task { await panel.shutdown() } }
    let controller = panel.controller
    try await controller.setAutomationMode(.schedule)
    do {
      try await controller.saveAutomationRule(AutomationRuleEdit(weekdays: [], target: wallpaper("a")))
      XCTFail("a rule that never runs")
    } catch {
      XCTAssertEqual(
        error.localizedDescription,
        String(localized: "Choose a valid display, time, weekday and wallpaper or saved playlist."))
    }
    XCTAssertTrue(controller.automationState(for: "primary").rules.isEmpty)
  }

  func testARuleIsRefusedForWhatNoEditorOffersAndNothingChanges() async throws {
    let panel = try makePanel()
    defer { Task { await panel.shutdown() } }
    let controller = panel.controller
    try await controller.saveAutomationRule(AutomationRuleEdit(weekdays: [2], target: wallpaper("a")), display: "primary")
    let before = controller.automationState(for: "primary")
    let refused: [(AutomationRuleEdit, String?)] = [
      (AutomationRuleEdit(weekdays: [0], target: wallpaper("a")), nil),
      (AutomationRuleEdit(weekdays: [8], target: wallpaper("a")), nil),
      (AutomationRuleEdit(weekdays: [1, 9], target: wallpaper("a")), nil),
      (AutomationRuleEdit(event: .sunrise, offset: 181, target: wallpaper("a")), nil),
      (AutomationRuleEdit(event: .sunset, offset: -181, target: wallpaper("a")), nil),
      (AutomationRuleEdit(target: wallpaper("app")), nil),
      (AutomationRuleEdit(target: wallpaper("missing")), nil),
      (AutomationRuleEdit(id: "stale", target: wallpaper("a")), nil),
      (AutomationRuleEdit(target: wallpaper("a")), "mirrored"),
      (AutomationRuleEdit(target: wallpaper("a")), "gone"),
    ]
    for (edit, display) in refused {
      do {
        try await controller.saveAutomationRule(edit, display: display)
        XCTFail("accepted \(edit) on \(display ?? "the target display")")
      } catch { XCTAssertTrue(error is InvalidControlValue, "\(edit): \(error)") }
    }
    do {
      try await controller.saveAutomationRule(
        AutomationRuleEdit(target: .init(kind: .playlist, id: "gone-plan")))
      XCTFail("a playlist that was never saved")
    } catch {
      XCTAssertEqual(error.localizedDescription, String(localized: "This playlist plan no longer exists. Refresh the library and retry."))
    }
    XCTAssertEqual(controller.automationState(for: "primary"), before)
    XCTAssertTrue(panel.automations.configurations["mirrored"] == nil && panel.automations.configurations["gone"] == nil)
  }

  func testDisplaysThatCannotHaveAutomaticRulesRefuseEveryAction() async throws {
    let panel = try makePanel()
    defer { Task { await panel.shutdown() } }
    let controller = panel.controller
    for display in ["mirrored", "gone"] {
      let attempts: [() async throws -> Void] = [
        { try await controller.setAutomationMode(.schedule, display: display) },
        { try await controller.setAutomationAppearance(.dark, to: self.wallpaper("a"), display: display) },
        { try await controller.removeAutomationRule("x", display: display) },
        { try await controller.retryAutomation(display: display) },
        { try await controller.setAutomationDesktop("space", to: nil, display: display) },
      ]
      for attempt in attempts {
        do {
          try await attempt()
          XCTFail("\(display) accepted an automatic-selection action")
        } catch { XCTAssertTrue(error is InvalidControlValue) }
      }
    }
    XCTAssertTrue(panel.automations.configurations.isEmpty)
  }

  func testRemovingARuleThatIsNotThereChangesNothing() async throws {
    let panel = try makePanel()
    defer { Task { await panel.shutdown() } }
    let controller = panel.controller
    try await controller.saveAutomationRule(AutomationRuleEdit(target: wallpaper("a")))
    try await controller.removeAutomationRule("never-there")
    XCTAssertEqual(controller.automationState(for: "primary").rules.count, 1)
  }

  // MARK: Appearance

  func testFollowSystemAppearanceChoosesAWallpaperPerLookAndCanLeaveItAsItIs() async throws {
    let panel = try makePanel()
    defer { Task { await panel.shutdown() } }
    let controller = panel.controller
    try await controller.setAutomationMode(.appearance)
    try await controller.setAutomationAppearance(.dark, to: wallpaper("b"))
    try await controller.setAutomationAppearance(.light, to: wallpaper("a"))
    var state = controller.automationState(for: "primary")
    XCTAssertEqual(state.dark, wallpaper("b"))
    XCTAssertEqual(state.light, wallpaper("a"), "each look has its own choice")
    try await controller.setAutomationAppearance(.dark, to: nil)
    state = controller.automationState(for: "primary")
    XCTAssertNil(state.dark, "Leave as it is")
    XCTAssertEqual(state.light, wallpaper("a"))
    do {
      try await controller.setAutomationAppearance(.light, to: wallpaper("app"))
      XCTFail("a wallpaper that cannot play")
    } catch { XCTAssertTrue(error is InvalidControlValue) }
    XCTAssertEqual(controller.automationState(for: "primary").light, wallpaper("a"))
  }

  // MARK: Location

  func testTheSolarLocationIsSavedClearedAndKeptWithinTheGlobe() async throws {
    let panel = try makePanel()
    defer { Task { await panel.shutdown() } }
    let controller = panel.controller
    XCTAssertNil(controller.solarLocation)
    try await controller.setSolarLocation(latitude: -33.87, longitude: 151.21)
    XCTAssertEqual(controller.solarLocation, WallpaperSolarLocation(latitude: -33.87, longitude: 151.21))
    XCTAssertEqual(WallpaperAutomationStore(defaults: panel.defaults).location?.longitude, 151.21)

    for (latitude, longitude) in [(91.0, 0.0), (-90.1, 0), (0, 180.1), (0, -181), (.nan, 0), (0, .infinity)] {
      do {
        try await controller.setSolarLocation(latitude: latitude, longitude: longitude)
        XCTFail("accepted \(latitude), \(longitude)")
      } catch { XCTAssertTrue(error is InvalidControlValue) }
    }
    try await controller.setSolarLocation(latitude: 90, longitude: -180)
    XCTAssertEqual(controller.solarLocation, WallpaperSolarLocation(latitude: 90, longitude: -180), "the edges are valid")

    try await controller.clearSolarLocation()
    XCTAssertNil(controller.solarLocation)
    XCTAssertNil(WallpaperAutomationStore(defaults: panel.defaults).location)
  }

  // MARK: Spaces

  func testADesktopChoicePersistsByUUIDAfterReorderingAndAMissingDesktopCanBeForgotten() async throws {
    var topology: [String: WallpaperDisplaySpaces]? = [
      "1": .init(
        displayUUID: "screen", spaces: [.init(id: "space-a", number: 1), .init(id: "space-b", number: 2)],
        current: "space-a")
    ]
    let spaces = WallpaperSpaceMonitor(provider: { topology })
    spaces.refresh()
    defer { spaces.stop() }
    let panel = try makePanel(spaces: spaces)
    defer { Task { await panel.shutdown() } }
    let controller = panel.controller

    try await controller.setAutomationMode(.spaces)
    var state = controller.automationState(for: "primary")
    XCTAssertTrue(state.spacesAvailable)
    XCTAssertEqual(state.desktops.map(\.id), ["space-a", "space-b"])
    XCTAssertEqual(state.desktops.map(\.number), [1, 2])
    XCTAssertEqual(state.currentDesktop, "space-a")

    try await controller.setAutomationDesktop("space-a", to: wallpaper("b"))
    XCTAssertEqual(WallpaperAutomationStore(defaults: panel.defaults).configuration(for: "primary").spaces["space-a"], wallpaper("b"))

    // The desktops are reordered: the label moves, the choice follows the desktop.
    topology?["1"]?.spaces = [.init(id: "space-b", number: 1), .init(id: "space-a", number: 2)]
    spaces.refresh()
    state = controller.automationState(for: "primary")
    XCTAssertEqual(state.desktops.map(\.id), ["space-b", "space-a"])
    let moved = try XCTUnwrap(state.desktops.first { $0.id == "space-a" })
    XCTAssertEqual(moved.number, 2)
    XCTAssertEqual(moved.target, wallpaper("b"), "stored by the Space's UUID, never its number")

    // The desktop is closed: its choice is listed as missing until it is forgotten.
    topology?["1"]?.current = "space-b"
    topology?["1"]?.spaces = [.init(id: "space-b", number: 1)]
    spaces.refresh()
    state = controller.automationState(for: "primary")
    XCTAssertEqual(state.desktops.map(\.id), ["space-b"])
    XCTAssertEqual(state.missingDesktops, [.init(id: "space-a", target: wallpaper("b"))])
    XCTAssertEqual(panel.automations.configuration(for: "primary").spaces["space-a"], wallpaper("b"), "kept, not dropped")

    try await controller.setAutomationDesktop("space-a", to: nil)
    XCTAssertNil(panel.automations.configuration(for: "primary").spaces["space-a"])
    XCTAssertTrue(controller.automationState(for: "primary").missingDesktops.isEmpty)
    do {
      try await controller.setAutomationDesktop("space-a", to: nil)
      XCTFail("there is nothing left to forget")
    } catch { XCTAssertTrue(error is InvalidControlValue) }
  }

  func testTurningOnAWallpaperForEachDesktopKeepsTheCurrentOneAndDesktop1sAndReplacesASchedule() async throws {
    let topology: [String: WallpaperDisplaySpaces]? = [
      "1": .init(
        displayUUID: "screen", spaces: [.init(id: "space-a", number: 1), .init(id: "space-b", number: 2)],
        current: "space-b")
    ]
    let spaces = WallpaperSpaceMonitor(provider: { topology })
    spaces.refresh()
    defer { spaces.stop() }
    let panel = try makePanel(spaces: spaces)
    defer { Task { await panel.shutdown() } }
    panel.store.monitorInformationSnapshot.rows = [OrganizationFixtures.monitor("primary", wallpaper: "a")]
    let controller = panel.controller
    try await controller.setAutomationMode(.schedule)

    try await controller.setDesktopWallpapers(true)

    var configuration = panel.automations.configuration(for: "primary")
    XCTAssertEqual(configuration.mode, .spaces, "it takes the place of the schedule")
    XCTAssertEqual(
      configuration.spaces, ["space-a": wallpaper("a"), "space-b": wallpaper("a")],
      "the desktop the person is on keeps its wallpaper, and so does Desktop 1, which new desktops follow")

    try await controller.setAutomationDesktop("space-a", to: wallpaper("b"))
    try await controller.setAutomationDesktop("space-b", to: nil)
    let desktops = controller.automationState(for: "primary").desktops
    XCTAssertEqual(desktops.map(\.target), [wallpaper("b"), nil])
    XCTAssertEqual(desktops.map(\.firstDesktopTarget), [nil, wallpaper("b")],
                   "a desktop without a choice shows Desktop 1's")

    try await controller.setAutomationDesktop("space-b", to: wallpaper("b"))
    try await controller.setDesktopWallpapers(false)
    try await controller.setDesktopWallpapers(true)
    configuration = panel.automations.configuration(for: "primary")
    XCTAssertEqual(configuration.spaces["space-b"], wallpaper("b"), "a choice already made is kept")

    try await controller.setDesktopWallpapers(false)
    XCTAssertEqual(panel.automations.configuration(for: "primary").mode, .off)
    try await controller.setAutomationMode(.appearance)
    try await controller.setDesktopWallpapers(false)
    XCTAssertEqual(panel.automations.configuration(for: "primary").mode, .appearance,
                   "turning it off leaves another automatic selection alone")
  }

  func testChoosingAWallpaperForEachDesktopFromTheModeMenuStartsLikeTheSwitch() async throws {
    let topology: [String: WallpaperDisplaySpaces]? = [
      "1": .init(
        displayUUID: "screen", spaces: [.init(id: "space-a", number: 1), .init(id: "space-b", number: 2)],
        current: "space-b")
    ]
    let spaces = WallpaperSpaceMonitor(provider: { topology })
    spaces.refresh()
    defer { spaces.stop() }
    let panel = try makePanel(spaces: spaces)
    defer { Task { await panel.shutdown() } }
    panel.store.monitorInformationSnapshot.rows = [OrganizationFixtures.monitor("primary", wallpaper: "a")]

    try await panel.controller.setAutomationMode(.spaces)

    let configuration = panel.automations.configuration(for: "primary")
    XCTAssertEqual(configuration.mode, .spaces)
    XCTAssertEqual(configuration.spaces, ["space-a": wallpaper("a"), "space-b": wallpaper("a")],
                   "the desktop the person is on and Desktop 1 keep the wallpaper shown")
  }

  func testWithoutSpaceInformationSpaceModeCannotBeChosenAndNoDesktopCanBeInvented() async throws {
    let panel = try makePanel()
    defer { Task { await panel.shutdown() } }
    let controller = panel.controller
    let state = controller.automationState(for: "primary")
    XCTAssertFalse(state.spacesAvailable)
    XCTAssertEqual(state.spacesUnavailableReason, .noInformation)
    XCTAssertTrue(state.desktops.isEmpty)
    do {
      try await controller.setAutomationMode(.spaces)
      XCTFail("enabled unavailable Space mode")
    } catch {
      XCTAssertEqual(
        error.localizedDescription,
        L("Desktop Space information is unavailable. Refresh Spaces or choose another automatic mode."))
    }
    XCTAssertEqual(controller.automationState(for: "primary").mode, .off)
    do {
      try await controller.setAutomationDesktop("made-up", to: wallpaper("a"))
      XCTFail("stored a choice with no Space information")
    } catch {}
    XCTAssertTrue(panel.automations.configuration(for: "primary").spaces.isEmpty)
  }

  func testADesktopTheDisplayDoesNotHaveCannotBeGivenAChoice() async throws {
    let spaces = WallpaperSpaceMonitor(provider: {
      ["1": .init(displayUUID: "screen", spaces: [.init(id: "space-a", number: 1)], current: "space-a")]
    })
    spaces.refresh()
    defer { spaces.stop() }
    let panel = try makePanel(spaces: spaces)
    defer { Task { await panel.shutdown() } }
    let controller = panel.controller
    do {
      try await controller.setAutomationDesktop("made-up", to: wallpaper("a"))
      XCTFail("stored a choice for a desktop that does not exist")
    } catch { XCTAssertTrue(error is InvalidControlValue) }
    let state = controller.automationState(for: "primary")
    XCTAssertTrue(state.spacesAvailable)
    XCTAssertNil(state.spacesUnavailableReason)
    XCTAssertTrue(panel.automations.configuration(for: "primary").spaces.isEmpty)
    try await controller.setAutomationDesktop("space-a", to: wallpaper("a"))
    XCTAssertEqual(panel.automations.configuration(for: "primary").spaces["space-a"], wallpaper("a"))
  }

  func testRefreshingSpacesReadsTheDesktopsAgain() async throws {
    var topology: [String: WallpaperDisplaySpaces]? = nil
    let spaces = WallpaperSpaceMonitor(provider: { topology })
    defer { spaces.stop() }
    let panel = try makePanel(spaces: spaces)
    defer { Task { await panel.shutdown() } }
    let controller = panel.controller
    try await panel.start()
    XCTAssertFalse(controller.automationState(for: "primary").spacesAvailable)
    topology = ["1": .init(displayUUID: "screen", spaces: [.init(id: "space-a", number: 1)], current: "space-a")]
    let changes = OSAllocatedUnfairLock(initialState: false)
    withObservationTracking {
      _ = controller.automationState(for: "primary")
    } onChange: {
      changes.withLock { $0 = true }
    }
    try await controller.refreshSpaces()
    try await panel.waitUntil { changes.withLock { $0 } }
    XCTAssertTrue(controller.automationState(for: "primary").spacesAvailable)
  }

  // MARK: State

  func testTheStateCarriesTheSchedulersNextChangeFocusAndFailure() async throws {
    let panel = try makePanel()
    defer { Task { await panel.shutdown() } }
    let controller = panel.controller
    let due = Date(timeIntervalSince1970: 2_000_000_000)
    panel.automations.setStatus(
      on: "primary", next: WallpaperAutomationOccurrence(key: "k", date: due, target: wallpaper("b")), focused: true)
    panel.automations.markHandled("k", on: "primary", error: "Could not apply")
    var state = controller.automationState(for: "primary")
    XCTAssertEqual(state.next, due)
    XCTAssertEqual(state.nextTarget, wallpaper("b"))
    XCTAssertTrue(state.isFocused)
    XCTAssertEqual(state.error, "Could not apply")

    try await controller.retryAutomation()
    state = controller.automationState(for: "primary")
    XCTAssertNil(state.error, "Retry clears the failure so the change is tried again")
    let quiet = controller.automationState(for: "mirrored")
    XCTAssertNil(quiet.next)
    XCTAssertFalse(quiet.isFocused)
  }

  func testTheTargetsAreTheWallpapersThatCanPlayAndTheSavedPlaylistsAndUnresolvedOnesReadAsUnavailable() async throws {
    let panel = try makePanel()
    defer { Task { await panel.shutdown() } }
    let controller = panel.controller
    let plan = try await controller.savePlaylistPlan(name: "Evening mix")
    let targets = controller.automationTargets
    XCTAssertEqual(targets.wallpapers.map(\.target.id), ["a", "b"], "the unsupported wallpaper is not offered")
    XCTAssertEqual(targets.wallpapers.map(\.title), ["Ocean <img src=x>", "Evening"])
    XCTAssertEqual(targets.playlists.map(\.title), ["Evening mix"])
    XCTAssertEqual(targets.title(of: wallpaper("b")), "Evening")
    XCTAssertEqual(targets.title(of: .init(kind: .playlist, id: plan.id)), "Evening mix")
    XCTAssertNil(targets.title(of: wallpaper("deleted")))
    XCTAssertNil(targets.title(of: wallpaper("app")), "a wallpaper that cannot play no longer resolves")
    XCTAssertNil(targets.title(of: .init(kind: .playlist, id: "a")), "a plan and a wallpaper with the same id are not the same")
    XCTAssertEqual(Set(targets.wallpapers.map(\.id) + targets.playlists.map(\.id)).count, 3)
  }

  func testAutomaticSelectionActionsLeaveTheBannerAndNeverWaitForTheQueue() async throws {
    let panel = try makePanel()
    defer { Task { await panel.shutdown() } }
    let controller = panel.controller
    struct Refused: LocalizedError { var errorDescription: String? { "Refused" } }
    controller.errors.report(Refused())
    let gate = QueueGate()
    let running = Task { @MainActor in await panel.store.commands.run { await gate.wait() } }
    try await panel.waitUntil { panel.store.commands.isBusy }
    try await controller.setAutomationMode(.schedule)
    XCTAssertEqual(controller.automationState(for: "primary").mode, .schedule, "settings do not wait for the renderer")
    XCTAssertEqual(controller.errors.message, "Refused")
    gate.open()
    _ = await running.value
  }

  func testTheStateFollowsTheStoreWithoutAnyOtherChange() async throws {
    let panel = try makePanel()
    defer { Task { await panel.shutdown() } }
    let controller = panel.controller
    try await panel.start()
    let changes = OSAllocatedUnfairLock(initialState: false)
    withObservationTracking {
      _ = controller.automationState(for: "primary")
      _ = controller.solarLocation
    } onChange: {
      changes.withLock { $0 = true }
    }
    try panel.automations.setLocation(WallpaperSolarLocation(latitude: 1, longitude: 2))
    try await panel.waitUntil { changes.withLock { $0 } }
    XCTAssertEqual(controller.solarLocation?.latitude, 1)
  }
}
