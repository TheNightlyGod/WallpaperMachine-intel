import XCTest

@testable import WallpaperMachine

/// Showing a wallpaper's pending property edits on the desktop: which panel edits reach the bridge's
/// property preview and when, what a slider or colour step does while it is dragged, and what Revert,
/// Apply, deleting a wallpaper and turning the choice off do about edits already shown. The bridge is
/// a double that records what the displays were asked to show; whether a display really follows is a
/// desktop check, not one made here, and so is the bridge's own bookkeeping, which its Rust tests
/// cover.
@MainActor
final class PanelPropertyPreviewTests: XCTestCase {
  func testAnEditWithTheSwitchOnReachesTheBridgeOnceAfterTheDebounceAndNeverWithItOff() async throws {
    try await PanelPropertyContext.with { context in
      for value in [true, false, true] { try await context.edit(value) }
      await context.settle()
      XCTAssertTrue(
        context.sleeper.requested.isEmpty, "with the choice off an edit does not even start to wait")
      XCTAssertTrue(context.bridge.previews.isEmpty)

      context.switchOn()
      for value in [false, true, false] { try await context.edit(value) }
      await context.settle()
      XCTAssertTrue(context.bridge.previews.isEmpty, "nothing is shown until the edits pause")
      await context.letTheEditsPause()
      XCTAssertEqual(
        context.bridge.previews, [.init(wallpaperID: "wp", show: true)],
        "a burst of edits costs the displays one update, and it asks for the pending edits, not a value"
      )
      XCTAssertEqual(context.bridge.options["wp"]?.dirty, true, "showing an edit does not apply it")
      XCTAssertFalse(context.bridge.events.contains("apply wp"))
    }
  }

  func testEveryWayToEditThePendingPropertiesIsFollowed() async throws {
    try await PanelPropertyContext.with { context in
      context.switchOn()
      try await context.edit(true)
      await context.letTheEditsPause()
      try await context.controller.restoreProperty("wp", property: "mode")
      await context.letTheEditsPause()
      try await context.controller.restoreAllProperties("wp")
      await context.letTheEditsPause()
      try await context.store.setPropertyPathAsync(
        wallpaperId: "wp", propertyId: "mode", path: "/tmp/picture.png")
      await context.letTheEditsPause()

      XCTAssertEqual(
        context.bridge.previews.count, 4,
        "an edit, a restored default, every default restored and a chosen file each show the draft again"
      )
    }
  }

  func testApplyCancelsAPendingPushAndRevertLeavesRestoringToTheBridge() async throws {
    try await PanelPropertyContext.with { context in
      context.switchOn()

      try await context.edit(true)
      await context.settle()
      XCTAssertEqual(context.sleeper.pendingCount, 1, "the edit is waiting to be shown")
      try await context.controller.apply("wp")
      await context.letTheEditsPause()
      XCTAssertTrue(
        context.bridge.previews.isEmpty,
        "the wallpaper loads from what is saved; showing the edit first is moot")
      XCTAssertEqual(context.bridge.events, ["edit wp", "apply wp"])

      try await context.edit(false)
      await context.letTheEditsPause()
      XCTAssertEqual(context.bridge.previews, [.init(wallpaperID: "wp", show: true)])
      try await context.edit(true)
      await context.settle()
      XCTAssertEqual(context.sleeper.pendingCount, 1)
      try await context.controller.revert("wp")
      await context.letTheEditsPause()
      XCTAssertEqual(
        context.bridge.previews, [.init(wallpaperID: "wp", show: true)],
        "the bridge puts the saved look back when it cancels the edit, so the app asks for nothing more"
      )
      XCTAssertEqual(Array(context.bridge.events.suffix(2)), ["edit wp", "cancel wp"])

      await context.switchOff()
      XCTAssertEqual(context.bridge.previews.count, 1, "after a Revert there is nothing left to take back")
    }
  }

  func testTheTextApplyCommitsStartsNoUpdateOfItsOwn() async throws {
    try await PanelPropertyContext.with { context in
      context.switchOn()
      context.controller.setPropertyText("hello", property: "note", in: "wp")

      try await context.controller.apply("wp")
      await context.letTheEditsPause()

      XCTAssertEqual(context.bridge.events, ["edit wp", "apply wp"], "Apply sent the text it held")
      XCTAssertTrue(
        context.sleeper.requested.isEmpty,
        "an edit made by Apply itself shows nothing before it loads the result")
      XCTAssertTrue(context.bridge.previews.isEmpty)
    }
  }

  func testTurningTheSwitchOffRestoresEveryWallpaperItPreviewed() async throws {
    try await PanelPropertyContext.with { context in
      context.switchOn()
      try await context.edit(true, id: "wp2")
      try await context.edit(true, id: "wp")
      await context.letTheEditsPause()
      XCTAssertEqual(
        Set(context.bridge.previews),
        [.init(wallpaperID: "wp", show: true), .init(wallpaperID: "wp2", show: true)])
      context.bridge.previews = []

      try await context.edit(false, id: "wp")
      await context.settle()
      XCTAssertEqual(context.sleeper.pendingCount, 1, "an update is waiting when the switch goes off")
      await context.switchOff()
      await context.letTheEditsPause()

      XCTAssertEqual(
        context.bridge.previews,
        [.init(wallpaperID: "wp", show: false), .init(wallpaperID: "wp2", show: false)],
        "each wallpaper that was shown an edit gets the saved look back, and the waiting update is dropped"
      )
      XCTAssertEqual(
        context.bridge.options["wp"]?.dirty, true, "the edits stay pending in the inspector")

      await context.switchOff()
      XCTAssertEqual(context.bridge.previews.count, 2, "what was put back is not asked for again")
      try await context.edit(true)
      await context.letTheEditsPause()
      XCTAssertEqual(
        context.bridge.previews.count, 2, "and with the switch off an edit stays off the desktop")
    }
  }

  func testAWallpaperThatWasAppliedOrDeletedIsNotAskedToGoBack() async throws {
    try await PanelPropertyContext.with { context in
      context.switchOn()
      for id in ["wp", "wp2", "wp3"] { try await context.edit(true, id: id) }
      await context.letTheEditsPause()
      XCTAssertEqual(context.bridge.previews.count, 3)
      context.bridge.previews = []

      try await context.controller.apply("wp")
      let report = try await context.store.deleteWallpapersAsync(ids: ["wp2"], recycle: { _ in })
      XCTAssertEqual(report.deleted, ["wp2"])
      await context.switchOff()

      XCTAssertEqual(
        context.bridge.previews, [.init(wallpaperID: "wp3", show: false)],
        "an applied wallpaper loaded its edits from what is saved and a deleted one is gone; only the pending one is put back"
      )
    }
  }

  func testTheDisplaysDrawingAnEditAreKnownUntilTheEditEnds() async throws {
    try await PanelPropertyContext.with { context in
      context.showWallpapersOnDisplays()
      var ended = 0
      context.store.onPropertyEditsOnDesktopEnded = { ended += 1 }

      try await context.edit(true)
      await context.letTheEditsPause()
      XCTAssertEqual(context.displaysShowingEdits(), [], "with the choice off no display draws an edit")

      context.switchOn()
      try await context.edit(false)
      await context.settle()
      XCTAssertEqual(
        context.displaysShowingEdits(), [], "an edit waiting for its quiet period is not on a display yet")
      await context.letTheEditsPause()
      XCTAssertEqual(
        context.displaysShowingEdits(), ["1", "2"],
        "the display showing the wallpaper and the one mirroring it, not the one showing another wallpaper"
      )
      XCTAssertEqual(ended, 0)

      try await context.controller.revert("wp")
      XCTAssertEqual(context.displaysShowingEdits(), [], "Revert put the saved look back")
      XCTAssertEqual(ended, 1, "and whatever withheld the desktop's picture is told to take it")

      try await context.controller.revert("wp")
      XCTAssertEqual(ended, 1, "a wallpaper nothing was shown of has nothing to take again")

      try await context.edit(true)
      await context.letTheEditsPause()
      XCTAssertEqual(context.displaysShowingEdits(), ["1", "2"])
      try await context.controller.apply("wp")
      XCTAssertEqual(context.displaysShowingEdits(), [], "Apply loads the saved look")
      XCTAssertEqual(ended, 2)
    }
  }

  func testTurningTheSwitchOffOrDeletingAWallpaperLetsItsDisplaysGo() async throws {
    try await PanelPropertyContext.with { context in
      context.showWallpapersOnDisplays()
      var ended = 0
      context.store.onPropertyEditsOnDesktopEnded = { ended += 1 }
      context.switchOn()
      for id in ["wp", "wp2", "wp3"] { try await context.edit(true, id: id) }
      await context.letTheEditsPause()
      XCTAssertEqual(context.displaysShowingEdits(), ["1", "2", "3"])

      // wp3 is on no display, so deleting it needs no eject.
      let report = try await context.store.deleteWallpapersAsync(ids: ["wp3"], recycle: { _ in })
      XCTAssertEqual(report.deleted, ["wp3"])
      XCTAssertEqual(ended, 1)

      context.bridge.previewFailure = InspectorTestRefusal()
      await context.switchOff()
      XCTAssertEqual(
        context.displaysShowingEdits(), ["1", "2", "3"],
        "a wallpaper the bridge could not put back may still be drawing its edit")
      XCTAssertEqual(ended, 1)

      context.bridge.previewFailure = nil
      await context.switchOff()
      XCTAssertEqual(context.displaysShowingEdits(), [])
      XCTAssertGreaterThan(ended, 1)
    }
  }

  func testAnUpdateThatOutlivesTheSwitchIsDropped() async throws {
    try await PanelPropertyContext.with { context in
      context.switchOn()
      try await context.edit(true)
      await context.settle()
      XCTAssertEqual(context.sleeper.pendingCount, 1)

      // Turned off from somewhere that does not go through the panel's action.
      LivePropertyEditing.setEnabled(false, defaults: context.defaults, center: NotificationCenter())
      await context.letTheEditsPause()

      XCTAssertTrue(
        context.bridge.previews.isEmpty,
        "the choice is read when the update is due, not only when the edit was made")
    }
  }

  func testOnlyScenesAreShownOnTheDesktop() async throws {
    try await PanelPropertyContext.with { context in
      context.switchOn()

      for id in ["web", "clip"] { try await context.edit(true, id: id) }
      await context.letTheEditsPause()

      XCTAssertTrue(
        context.sleeper.requested.isEmpty,
        "a web page and a video have nothing for the desktop to follow")
      XCTAssertTrue(context.bridge.previews.isEmpty)
      XCTAssertEqual(context.bridge.events, ["edit web", "edit clip"])
    }
  }

  func testAPreviewFailureIsLoggedNotShown() async throws {
    try await PanelPropertyContext.with { context in
      context.switchOn()
      context.bridge.previewFailure = InspectorTestRefusal()

      try await context.edit(true)
      await context.letTheEditsPause()

      XCTAssertEqual(context.bridge.previews.count, 1, "the bridge was asked")
      XCTAssertEqual(context.log.count, 1, "and its refusal went to the log")
      XCTAssertTrue(context.log.first?.contains("wp") == true, "naming the wallpaper")
      XCTAssertNil(
        context.store.latestBridgeErrorMessage, "an edit in progress is not interrupted by an alert")
      XCTAssertEqual(context.bridge.options["wp"]?.dirty, true, "the edit itself is untouched")

      context.bridge.previewFailure = nil
      try await context.edit(false)
      await context.letTheEditsPause()
      XCTAssertEqual(context.bridge.previews.count, 2, "the next edit tries again")
      XCTAssertEqual(context.log.count, 1)
    }
  }

  func testASwitchOffTheBridgeRefusesIsAskedAgainTheNextTime() async throws {
    try await PanelPropertyContext.with { context in
      context.switchOn()
      try await context.edit(true)
      await context.letTheEditsPause()
      context.bridge.previews = []

      context.bridge.previewFailure = InspectorTestRefusal()
      await context.switchOff()
      XCTAssertEqual(context.bridge.previews, [.init(wallpaperID: "wp", show: false)])
      XCTAssertEqual(context.log.count, 1, "the refusal is logged and the switch still goes off")
      XCTAssertFalse(LivePropertyEditing.isEnabled(defaults: context.defaults))

      context.bridge.previewFailure = nil
      await context.switchOff()
      XCTAssertEqual(
        context.bridge.previews,
        [.init(wallpaperID: "wp", show: false), .init(wallpaperID: "wp", show: false)],
        "a wallpaper that could not be put back stays marked until it can")
      await context.switchOff()
      XCTAssertEqual(context.bridge.previews.count, 2)
    }
  }

  // MARK: Drags

  func testAStepReachesTheDisplaysAtOnceWithItsValueAndSavesNothing() async throws {
    try await PanelPropertyContext.with { context in
      context.switchOn()
      var dragged: [String] = []
      var edited: [String] = []
      context.store.onPropertyDragged = { dragged.append($0) }
      context.store.onPropertyDraftChanged = { edited.append($0) }

      try await context.drag("alpha", .number(0.4))
      XCTAssertEqual(
        context.bridge.previews,
        [
          .init(
            wallpaperID: "wp", show: true,
            pending: [.init(propertyId: "alpha", value: .number(value: 0.4))])
        ],
        "a drag has no quiet period to wait for, so the step reaches the displays as it arrives")
      XCTAssertTrue(context.sleeper.requested.isEmpty)

      try await context.drag("tint", .color(red: 1, green: 128.0 / 255, blue: 0))
      XCTAssertEqual(
        context.bridge.previews.last?.pending,
        [
          .init(propertyId: "alpha", value: .number(value: 0.4)),
          .init(propertyId: "tint", value: .colorRgb(red: 1, green: 128.0 / 255, blue: 0)),
        ],
        "every step carries the others still being dragged, in a fixed order")

      XCTAssertEqual(dragged, ["wp", "wp"], "whatever shows the draft is told of each step")
      XCTAssertTrue(edited.isEmpty, "a step is not an edit")
      XCTAssertTrue(context.bridge.events.isEmpty, "nothing reached the draft")
      XCTAssertEqual(context.bridge.options["wp"]?.dirty, false)
      XCTAssertFalse(
        context.store.editorState.hasPendingEdits(wallpaperID: "wp"),
        "and it blocks nothing that waits for a clean draft")
    }
  }

  func testAStepWithTheSwitchOffReachesOnlyWhatFollowsTheDraft() async throws {
    try await PanelPropertyContext.with { context in
      var dragged: [String] = []
      context.store.onPropertyDragged = { dragged.append($0) }

      try await context.drag("alpha", .number(0.4))

      XCTAssertEqual(dragged, ["wp"])
      XCTAssertTrue(context.bridge.previews.isEmpty, "the displays keep to the saved look")
      XCTAssertEqual(
        context.store.editorState.propertyPreviews(wallpaperID: "wp"),
        [.init(propertyId: "alpha", value: .number(value: 0.4))], "the preview window asks for it")
    }
  }

  func testAStepIsHeldToTheRulesOfAnEditAndOnlySlidersAndColoursTakePart() async throws {
    try await PanelPropertyContext.with { context in
      context.switchOn()
      var dragged: [String] = []
      context.store.onPropertyDragged = { dragged.append($0) }
      let controller = context.controller
      let cases: [(String, BridgePropertyValue)] = [
        ("alpha", .number(value: 1.5)), ("alpha", .number(value: -0.1)),
        ("alpha", .number(value: .nan)), ("alpha", .number(value: .infinity)),
        ("alpha", .string(value: "0.5")), ("alpha", .bool(value: true)), ("alpha", .empty),
        ("tint", .string(value: "red")), ("tint", .number(value: 5)), ("tint", .bool(value: true)),
        ("tint", .colorRgb(red: 1.1, green: 0, blue: 0)),
        ("tint", .colorRgb(red: 0, green: -0.1, blue: 0)),
        ("tint", .colorRgb(red: 0, green: 0, blue: .nan)),
      ]

      for (property, value) in cases {
        await assertInspectorInvalidValue("a \(property) step of \(value)") {
          try await controller.previewProperty("wp", property: property, value: value)
        }
        await assertInspectorInvalidValue("an edit of \(property) to \(value)") {
          try await controller.commitProperty("wp", property: property, value: value)
        }
      }
      // Kinds the drag does not carry, a property that cannot be edited, and one that does not exist.
      let others: [(String, BridgePropertyValue)] = [
        ("mode", .bool(value: true)), ("note", .string(value: "hello")),
        ("picture", .string(value: "a.png")), ("locked", .number(value: 0.5)),
        ("missing", .number(value: 0.5)),
      ]
      for (property, value) in others {
        await assertInspectorInvalidValue("a step of \(property)") {
          try await controller.previewProperty("wp", property: property, value: value)
        }
      }
      do {
        try await controller.previewProperty("nope", property: "alpha", value: .number(value: 0.5))
        XCTFail("a wallpaper the library no longer has must be refused")
      } catch {
        XCTAssertEqual(
          error.localizedDescription,
          "This wallpaper is no longer installed. Refresh your library.")
      }

      XCTAssertTrue(context.bridge.previews.isEmpty, "a refused step shows nothing")
      XCTAssertTrue(dragged.isEmpty)
      XCTAssertTrue(
        context.store.editorState.propertyPreviewValues.isEmpty, "and is not held for the next update either")
      XCTAssertTrue(context.bridge.events.isEmpty)

      // The edge of the range is a value like any other.
      try await context.drag("alpha", .number(0))
      try await context.drag("alpha", .number(1))
      XCTAssertEqual(context.bridge.previews.count, 2)
    }
  }

  func testAStepDoesNotWaitBehindTheCommandThatIsRunning() async throws {
    try await PanelPropertyContext.with { context in
      context.switchOn()
      var release: CheckedContinuation<Void, Never>?
      let store = context.store
      let running = Task { @MainActor in
        await store.commands.run { await withCheckedContinuation { release = $0 } }
      }
      for _ in 0..<200 where release == nil { await Task.yield() }
      XCTAssertNotNil(release, "the first command must be running before the step is sent")

      try await context.drag("alpha", .number(0.4))

      XCTAssertEqual(
        context.bridge.previews.map(\.pending.count), [1],
        "a step that waited for a wallpaper switch would reach the displays long after the thumb moved on"
      )
      XCTAssertTrue(context.store.commands.waiting.isEmpty)
      release?.resume()
      _ = await running.value
    }
  }

  func testTheEditThatEndsADragKeepsItsValueAndTheStepIsNotShownAgain() async throws {
    try await PanelPropertyContext.with { context in
      context.switchOn()

      try await context.drag("alpha", .number(0.4))
      try await context.drag("alpha", .number(0.42))
      try await context.controller.commitProperty("wp", property: "alpha", value: .number(value: 0.45))

      XCTAssertTrue(
        context.store.editorState.propertyPreviewValues.isEmpty, "the release replaces the step")
      XCTAssertEqual(context.bridge.events, ["edit wp"])
      await context.letTheEditsPause()
      XCTAssertEqual(
        context.bridge.previews.last, .init(wallpaperID: "wp", show: true),
        "the update the edit starts asks for the draft alone: a step left in it would hide the value that was saved"
      )
    }
  }

  func testARefusedEditTakesTheStepBackToo() async throws {
    try await PanelPropertyContext.with { context in
      context.switchOn()
      context.bridge.editFailure = InspectorTestRefusal()

      try await context.drag("alpha", .number(0.4))
      do {
        try await context.controller.commitProperty("wp", property: "alpha", value: .number(value: 0.4))
        XCTFail("the bridge refused the edit")
      } catch is InspectorTestRefusal {}

      XCTAssertTrue(
        context.store.editorState.propertyPreviewValues.isEmpty,
        "a value nobody kept is not left on show")
      await context.letTheEditsPause()
      XCTAssertEqual(
        context.bridge.previews.last, .init(wallpaperID: "wp", show: true),
        "the displays are asked to follow the draft, which never took the value")
    }
  }

  func testAnEditOfAnotherPropertyLeavesTheStepAlone() async throws {
    try await PanelPropertyContext.with { context in
      context.switchOn()

      try await context.drag("tint", .color(red: 1, green: 128.0 / 255, blue: 0))
      try await context.edit(true)
      await context.letTheEditsPause()
      XCTAssertEqual(context.bridge.previews.last?.pending.map(\.propertyId), ["tint"])

      try await context.controller.restoreProperty("wp", property: "tint")
      XCTAssertTrue(
        context.store.editorState.propertyPreviewValues.isEmpty,
        "restoring the property it is for ends it")

      try await context.drag("alpha", .number(0.4))
      try await context.drag("tint", .color(red: 1, green: 128.0 / 255, blue: 0))
      try await context.controller.restoreAllProperties("wp")
      XCTAssertTrue(
        context.store.editorState.propertyPreviewValues.isEmpty, "so does restoring every default")
    }
  }

  func testRevertAndApplyEndTheStep() async throws {
    try await PanelPropertyContext.with { context in
      context.switchOn()

      try await context.drag("alpha", .number(0.4))
      try await context.controller.revert("wp")
      XCTAssertTrue(context.store.editorState.propertyPreviewValues.isEmpty)
      await context.letTheEditsPause()
      XCTAssertEqual(
        context.bridge.previews.count, 1,
        "the bridge puts the saved look back when it cancels the edit, so the app asks for nothing more"
      )

      try await context.drag("alpha", .number(0.4))
      try await context.edit(true)
      try await context.controller.apply("wp")
      XCTAssertTrue(context.store.editorState.propertyPreviewValues.isEmpty)
      XCTAssertEqual(Array(context.bridge.events.suffix(2)), ["edit wp", "apply wp"])
    }
  }

  func testAnotherWallpapersInspectorEndsTheStepAndTheDisplaysGoBackToTheDraft() async throws {
    try await PanelPropertyContext.with { context in
      context.switchOn()
      var named: [String] = []
      context.store.onPropertyDraftChanged = { named.append($0) }

      try await context.drag("alpha", .number(0.4))
      context.bridge.previews = []
      // The inspector shows wp2 from now on.
      try await context.controller.commitProperty("wp2", property: "mode", value: .bool(value: true))

      XCTAssertTrue(context.store.editorState.propertyPreviewValues.isEmpty)
      XCTAssertEqual(Set(named), ["wp", "wp2"], "the wallpaper it left follows its draft again")
      await context.letTheEditsPause()
      XCTAssertTrue(context.bridge.previews.contains(.init(wallpaperID: "wp", show: true)))
    }
  }

  func testAStepWhileTheWallpaperIsBeingAppliedIsDropped() async throws {
    try await PanelPropertyContext.with { context in
      context.switchOn()
      var dragged: [String] = []
      context.store.onPropertyDragged = { dragged.append($0) }
      context.bridge.holdApply = true
      let controller = context.controller
      let applying = Task { @MainActor in try await controller.apply("wp") }
      for _ in 0..<400 where context.store.applyingWallpaperID == nil { await Task.yield() }
      XCTAssertEqual(context.store.applyingWallpaperID, "wp", "the apply is under way")

      try await context.drag("alpha", .number(0.4))

      XCTAssertTrue(dragged.isEmpty)
      XCTAssertTrue(context.bridge.previews.isEmpty)
      XCTAssertTrue(
        context.store.editorState.propertyPreviewValues.isEmpty,
        "a step that outlived the apply would be left behind with nothing to end it")
      context.bridge.releaseApply()
      try await applying.value
    }
  }

  func testARefusalIsLoggedOncePerRunNotForEveryStep() async throws {
    try await PanelPropertyContext.with { context in
      context.switchOn()
      context.bridge.previewFailure = InspectorTestRefusal()

      for value in [0.1, 0.2, 0.3] { try await context.drag("alpha", .number(value)) }
      XCTAssertEqual(context.bridge.previews.count, 3, "every step still tries")
      XCTAssertEqual(context.log.count, 1, "the same refusal is logged once")
      XCTAssertTrue(context.log.first?.contains("wp") == true)
      XCTAssertNil(context.store.latestBridgeErrorMessage)

      context.bridge.previewFailure = nil
      try await context.drag("alpha", .number(0.4))
      context.bridge.previewFailure = InspectorTestRefusal()
      try await context.drag("alpha", .number(0.5))
      XCTAssertEqual(context.log.count, 2, "a refusal after the displays took a step is news again")
    }
  }

  // MARK: The drag pump

  /// What a slider does with the pump the controller hands it: the first value is shown at once,
  /// later ones wait for the interval and carry the newest, and the release drops a waiting step and
  /// saves the final value, once. (The pump's own timing rules are `DragStepPumpTests`'.)
  func testASliderDragShowsTheNewestStepAndTheReleaseSavesTheFinalValueOnce() async throws {
    try await PanelPropertyContext.with { context in
      context.switchOn()
      let pump = context.controller.propertyDragPump(
        "wp", property: "alpha", sleep: context.sleeper.closure)

      for value in [0.31, 0.32, 0.33, 0.34, 0.35] { pump.update(.number(value)) }
      await context.settle()
      XCTAssertEqual(
        context.bridge.previews.map(\.pending),
        [[.init(propertyId: "alpha", value: .number(value: 0.31))]],
        "the first step is shown at once; the others wait for the interval")
      XCTAssertTrue(context.bridge.edits.isEmpty, "dragging saves nothing")

      context.sleeper.fireNext()
      await context.settle()
      XCTAssertEqual(
        context.bridge.previews.last?.pending, [.init(propertyId: "alpha", value: .number(value: 0.35))],
        "the newest value follows when the interval is up")

      let controller = context.controller
      try await pump.release(.number(0.35)) { value in
        try await controller.commitProperty("wp", property: "alpha", value: value.bridgeValue)
      }
      XCTAssertEqual(context.bridge.edits, [.init(propertyId: "alpha", value: .number(value: 0.35))])
      XCTAssertEqual(context.bridge.previews.count, 2, "and no step follows it")
    }
  }

  func testAColourPumpWhoseSinglePickIsSavedAtOnceShowsNoStep() async throws {
    try await PanelPropertyContext.with { context in
      context.switchOn()
      let pump = context.controller.propertyDragPump(
        "wp", property: "tint", sleep: context.sleeper.closure)
      let color = PropertyDragValue.color(red: 0x11 / 255, green: 0x22 / 255, blue: 0x33 / 255)

      pump.update(color, deferFirstStep: true)
      let controller = context.controller
      try await pump.release(color) { value in
        try await controller.commitProperty("wp", property: "tint", value: value.bridgeValue)
      }
      await context.settle()

      XCTAssertTrue(
        context.bridge.previews.allSatisfy { $0.pending.isEmpty },
        "a single pick whose save follows at once shows nothing before it is saved")
      XCTAssertEqual(
        context.bridge.edits,
        [.init(propertyId: "tint", value: .colorRgb(red: 0x11 / 255, green: 0x22 / 255, blue: 0x33 / 255))])
    }
  }
}
