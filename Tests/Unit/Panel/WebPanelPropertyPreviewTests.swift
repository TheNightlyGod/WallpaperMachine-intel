import XCTest

@testable import WallpaperMachine

/// Showing a wallpaper's pending property edits on the desktop: which panel edits reach the
/// bridge's property preview and when, and what Revert, Apply, deleting a wallpaper and turning
/// the choice off do about edits already shown. The bridge is a double that records what the
/// displays were asked to show; whether a display really follows is a desktop check, not one made
/// here, and so is the bridge's own bookkeeping, which its Rust tests cover.
@MainActor
final class WebPanelPropertyPreviewTests: XCTestCase {
  func testAnEditWithTheSwitchOnReachesTheBridgeOnceAfterTheDebounceAndNeverWithItOff() async throws {
    let context = try Context()
    defer { context.tearDown() }

    for value in [true, false, true] { try await context.edit(value) }
    await context.settle()
    XCTAssertTrue(context.sleeper.requested.isEmpty, "with the choice off an edit does not even start to wait")
    XCTAssertTrue(context.bridge.previews.isEmpty)

    try await context.switchOn()
    for value in [false, true, false] { try await context.edit(value) }
    await context.settle()
    XCTAssertTrue(context.bridge.previews.isEmpty, "nothing is shown until the edits pause")
    await context.letTheEditsPause()
    XCTAssertEqual(
      context.bridge.previews, [.init(wallpaperID: "wp", show: true)],
      "a burst of edits costs the displays one update, and it asks for the pending edits, not a value")
    XCTAssertEqual(context.bridge.options["wp"]?.dirty, true, "showing an edit does not apply it")
    XCTAssertFalse(context.bridge.events.contains("apply wp"))
  }

  func testEveryWayToEditThePendingPropertiesIsFollowed() async throws {
    let context = try Context()
    defer { context.tearDown() }
    try await context.switchOn()

    try await context.edit(true)
    await context.letTheEditsPause()
    try await context.controller.perform("restoreProperty", body: ["id": "wp", "propertyID": "mode"])
    await context.letTheEditsPause()
    try await context.controller.perform("restoreAllProperties", body: ["id": "wp"])
    await context.letTheEditsPause()
    try await context.store.setPropertyPathAsync(wallpaperId: "wp", propertyId: "mode", path: "/tmp/picture.png")
    await context.letTheEditsPause()

    XCTAssertEqual(
      context.bridge.previews.count, 4,
      "an edit, a restored default, every default restored and a chosen file each show the draft again")
  }

  func testApplyCancelsAPendingPushAndRevertLeavesRestoringToTheBridge() async throws {
    let context = try Context()
    defer { context.tearDown() }
    try await context.switchOn()

    try await context.edit(true)
    await context.settle()
    XCTAssertEqual(context.sleeper.pendingCount, 1, "the edit is waiting to be shown")
    try await context.controller.perform("apply", body: ["id": "wp"])
    await context.letTheEditsPause()
    XCTAssertTrue(context.bridge.previews.isEmpty, "the wallpaper loads from what is saved; showing the edit first is moot")
    XCTAssertEqual(context.bridge.events, ["edit wp", "apply wp"])

    try await context.edit(false)
    await context.letTheEditsPause()
    XCTAssertEqual(context.bridge.previews, [.init(wallpaperID: "wp", show: true)])
    try await context.edit(true)
    await context.settle()
    XCTAssertEqual(context.sleeper.pendingCount, 1)
    try await context.controller.perform("revert", body: ["id": "wp"])
    await context.letTheEditsPause()
    XCTAssertEqual(
      context.bridge.previews, [.init(wallpaperID: "wp", show: true)],
      "the bridge puts the saved look back when it cancels the edit, so the app asks for nothing more")
    XCTAssertEqual(Array(context.bridge.events.suffix(2)), ["edit wp", "cancel wp"])

    try await context.switchOff()
    XCTAssertEqual(context.bridge.previews.count, 1, "after a Revert there is nothing left to take back")
  }

  func testTheTextApplyCommitsStartsNoUpdateOfItsOwn() async throws {
    let context = try Context()
    defer { context.tearDown() }
    try await context.switchOn()
    context.store.editorState.setPropertyText("hello", key: .init(wallpaperID: "wp", fieldID: "note"))

    try await context.controller.perform("apply", body: ["id": "wp"])
    await context.letTheEditsPause()

    XCTAssertEqual(context.bridge.events, ["edit wp", "apply wp"], "Apply sent the text it held")
    XCTAssertTrue(context.sleeper.requested.isEmpty, "an edit made by Apply itself shows nothing before it loads the result")
    XCTAssertTrue(context.bridge.previews.isEmpty)
  }

  func testTurningTheSwitchOffRestoresEveryWallpaperItPreviewed() async throws {
    let context = try Context()
    defer { context.tearDown() }
    try await context.switchOn()
    try await context.edit(true, id: "wp2")
    try await context.edit(true, id: "wp")
    await context.letTheEditsPause()
    XCTAssertEqual(Set(context.bridge.previews), [.init(wallpaperID: "wp", show: true), .init(wallpaperID: "wp2", show: true)])
    context.bridge.previews = []

    try await context.edit(false, id: "wp")
    await context.settle()
    XCTAssertEqual(context.sleeper.pendingCount, 1, "an update is waiting when the switch goes off")
    try await context.switchOff()
    await context.letTheEditsPause()

    XCTAssertEqual(
      context.bridge.previews, [.init(wallpaperID: "wp", show: false), .init(wallpaperID: "wp2", show: false)],
      "each wallpaper that was shown an edit gets the saved look back, and the waiting update is dropped")
    XCTAssertEqual(context.bridge.options["wp"]?.dirty, true, "the edits stay pending in the inspector")

    try await context.switchOff()
    XCTAssertEqual(context.bridge.previews.count, 2, "what was put back is not asked for again")
    try await context.edit(true)
    await context.letTheEditsPause()
    XCTAssertEqual(context.bridge.previews.count, 2, "and with the switch off an edit stays off the desktop")
  }

  func testAWallpaperThatWasAppliedOrDeletedIsNotAskedToGoBack() async throws {
    let context = try Context()
    defer { context.tearDown() }
    try await context.switchOn()
    for id in ["wp", "wp2", "wp3"] { try await context.edit(true, id: id) }
    await context.letTheEditsPause()
    XCTAssertEqual(context.bridge.previews.count, 3)
    context.bridge.previews = []

    try await context.controller.perform("apply", body: ["id": "wp"])
    let report = try await context.store.deleteWallpapersAsync(ids: ["wp2"], recycle: { _ in })
    XCTAssertEqual(report.deleted, ["wp2"])
    try await context.switchOff()

    XCTAssertEqual(
      context.bridge.previews, [.init(wallpaperID: "wp3", show: false)],
      "an applied wallpaper loaded its edits from what is saved and a deleted one is gone; only the pending one is put back")
  }

  func testTheDisplaysDrawingAnEditAreKnownUntilTheEditEnds() async throws {
    let context = try Context()
    defer { context.tearDown() }
    context.showWallpapersOnDisplays()
    var ended = 0
    context.store.onPropertyEditsOnDesktopEnded = { ended += 1 }

    try await context.edit(true)
    await context.letTheEditsPause()
    XCTAssertEqual(context.displaysShowingEdits(), [], "with the choice off no display draws an edit")

    try await context.switchOn()
    try await context.edit(false)
    await context.settle()
    XCTAssertEqual(context.displaysShowingEdits(), [], "an edit waiting for its quiet period is not on a display yet")
    await context.letTheEditsPause()
    XCTAssertEqual(
      context.displaysShowingEdits(), ["1", "2"],
      "the display showing the wallpaper and the one mirroring it, not the one showing another wallpaper")
    XCTAssertEqual(ended, 0)

    try await context.controller.perform("revert", body: ["id": "wp"])
    XCTAssertEqual(context.displaysShowingEdits(), [], "Revert put the saved look back")
    XCTAssertEqual(ended, 1, "and whatever withheld the desktop's picture is told to take it")

    try await context.controller.perform("revert", body: ["id": "wp"])
    XCTAssertEqual(ended, 1, "a wallpaper nothing was shown of has nothing to take again")

    try await context.edit(true)
    await context.letTheEditsPause()
    XCTAssertEqual(context.displaysShowingEdits(), ["1", "2"])
    try await context.controller.perform("apply", body: ["id": "wp"])
    XCTAssertEqual(context.displaysShowingEdits(), [], "Apply loads the saved look")
    XCTAssertEqual(ended, 2)
  }

  func testTurningTheSwitchOffOrDeletingAWallpaperLetsItsDisplaysGo() async throws {
    let context = try Context()
    defer { context.tearDown() }
    context.showWallpapersOnDisplays()
    var ended = 0
    context.store.onPropertyEditsOnDesktopEnded = { ended += 1 }
    try await context.switchOn()
    for id in ["wp", "wp2", "wp3"] { try await context.edit(true, id: id) }
    await context.letTheEditsPause()
    XCTAssertEqual(context.displaysShowingEdits(), ["1", "2", "3"])

    // wp3 is on no display, so deleting it needs no eject.
    let report = try await context.store.deleteWallpapersAsync(ids: ["wp3"], recycle: { _ in })
    XCTAssertEqual(report.deleted, ["wp3"])
    XCTAssertEqual(ended, 1)

    context.bridge.previewFailure = Refused()
    try await context.switchOff()
    XCTAssertEqual(context.displaysShowingEdits(), ["1", "2", "3"], "a wallpaper the bridge could not put back may still be drawing its edit")
    XCTAssertEqual(ended, 1)

    context.bridge.previewFailure = nil
    try await context.switchOff()
    XCTAssertEqual(context.displaysShowingEdits(), [])
    XCTAssertGreaterThan(ended, 1)
  }

  func testAnUpdateThatOutlivesTheSwitchIsDropped() async throws {
    let context = try Context()
    defer { context.tearDown() }
    try await context.switchOn()
    try await context.edit(true)
    await context.settle()
    XCTAssertEqual(context.sleeper.pendingCount, 1)

    // Turned off from somewhere that does not go through the panel's action.
    LivePropertyEditing.setEnabled(false, defaults: context.defaults, center: NotificationCenter())
    await context.letTheEditsPause()

    XCTAssertTrue(context.bridge.previews.isEmpty, "the choice is read when the update is due, not only when the edit was made")
  }

  func testOnlyScenesAreShownOnTheDesktop() async throws {
    let context = try Context()
    defer { context.tearDown() }
    try await context.switchOn()

    for id in ["web", "clip"] { try await context.edit(true, id: id) }
    await context.letTheEditsPause()

    XCTAssertTrue(context.sleeper.requested.isEmpty, "a web page and a video have nothing for the desktop to follow")
    XCTAssertTrue(context.bridge.previews.isEmpty)
    XCTAssertEqual(context.bridge.events, ["edit web", "edit clip"])
  }

  func testAPreviewFailureIsLoggedNotShown() async throws {
    let context = try Context()
    defer { context.tearDown() }
    try await context.switchOn()
    context.bridge.previewFailure = Refused()

    try await context.edit(true)
    await context.letTheEditsPause()

    XCTAssertEqual(context.bridge.previews.count, 1, "the bridge was asked")
    XCTAssertEqual(context.log.count, 1, "and its refusal went to the log")
    XCTAssertTrue(context.log.first?.contains("wp") == true, "naming the wallpaper")
    XCTAssertNil(context.store.latestBridgeErrorMessage, "an edit in progress is not interrupted by an alert")
    XCTAssertEqual(context.bridge.options["wp"]?.dirty, true, "the edit itself is untouched")

    context.bridge.previewFailure = nil
    try await context.edit(false)
    await context.letTheEditsPause()
    XCTAssertEqual(context.bridge.previews.count, 2, "the next edit tries again")
    XCTAssertEqual(context.log.count, 1)
  }

  func testASwitchOffTheBridgeRefusesIsAskedAgainTheNextTime() async throws {
    let context = try Context()
    defer { context.tearDown() }
    try await context.switchOn()
    try await context.edit(true)
    await context.letTheEditsPause()
    context.bridge.previews = []

    context.bridge.previewFailure = Refused()
    try await context.switchOff()
    XCTAssertEqual(context.bridge.previews, [.init(wallpaperID: "wp", show: false)])
    XCTAssertEqual(context.log.count, 1, "the refusal is logged and the switch still goes off")
    XCTAssertFalse(LivePropertyEditing.isEnabled(defaults: context.defaults))

    context.bridge.previewFailure = nil
    try await context.switchOff()
    XCTAssertEqual(
      context.bridge.previews, [.init(wallpaperID: "wp", show: false), .init(wallpaperID: "wp", show: false)],
      "a wallpaper that could not be put back stays marked until it can")
    try await context.switchOff()
    XCTAssertEqual(context.bridge.previews.count, 2)
  }

  // MARK: Drags

  func testAStepReachesTheDisplaysAtOnceWithItsValueAndSavesNothing() async throws {
    let context = try Context()
    defer { context.tearDown() }
    try await context.switchOn()
    var dragged: [String] = []
    var edited: [String] = []
    context.store.onPropertyDragged = { dragged.append($0) }
    context.store.onPropertyDraftChanged = { edited.append($0) }

    try await context.drag("alpha", 0.4)
    XCTAssertEqual(
      context.bridge.previews,
      [.init(wallpaperID: "wp", show: true, pending: [.init(propertyId: "alpha", value: .number(value: 0.4))])],
      "a drag has no quiet period to wait for, so the step reaches the displays as it arrives")
    XCTAssertTrue(context.sleeper.requested.isEmpty)

    try await context.drag("tint", "#ff8000")
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
    XCTAssertFalse(context.store.editorState.hasPendingEdits(wallpaperID: "wp"), "and it blocks nothing that waits for a clean draft")
  }

  func testAStepWithTheSwitchOffReachesOnlyWhatFollowsTheDraft() async throws {
    let context = try Context()
    defer { context.tearDown() }
    var dragged: [String] = []
    context.store.onPropertyDragged = { dragged.append($0) }

    try await context.drag("alpha", 0.4)

    XCTAssertEqual(dragged, ["wp"])
    XCTAssertTrue(context.bridge.previews.isEmpty, "the displays keep to the saved look")
    XCTAssertEqual(
      context.store.editorState.propertyPreviews(wallpaperID: "wp"),
      [.init(propertyId: "alpha", value: .number(value: 0.4))], "the preview window asks for it")
  }

  func testAStepIsHeldToTheRulesOfAnEditAndOnlySlidersAndColoursTakePart() async throws {
    let context = try Context()
    defer { context.tearDown() }
    try await context.switchOn()
    var dragged: [String] = []
    context.store.onPropertyDragged = { dragged.append($0) }
    let values: [(String, Any)] = [
      ("alpha", 1.5), ("alpha", -0.1), ("alpha", Double.nan), ("alpha", Double.infinity), ("alpha", "0.5"),
      ("alpha", true), ("alpha", NSNull()), ("alpha", [0.5]),
      ("tint", "red"), ("tint", "#12345"), ("tint", "#gggggg"), ("tint", "ff8000"), ("tint", 5), ("tint", true),
    ]

    for (property, value) in values {
      let body: [String: Any] = ["id": "wp", "propertyID": property, "value": value]
      await assertInvalid("a \(property) step of \(value)") { try await context.controller.perform("propertyPreview", body: body) }
      await assertInvalid("an edit of \(property) to \(value)") { try await context.controller.perform("property", body: body) }
    }
    // Kinds the drag does not carry, a property that cannot be edited, and one that does not exist.
    for (property, value) in [("mode", true as Any), ("note", "hello"), ("picture", "a.png"), ("locked", 0.5), ("missing", 0.5)] {
      await assertInvalid("a step of \(property)") {
        try await context.controller.perform("propertyPreview", body: ["id": "wp", "propertyID": property, "value": value])
      }
    }
    for body: [String: Any] in [
      ["id": "wp", "value": 0.5], ["id": "wp", "propertyID": "alpha"], ["propertyID": "alpha", "value": 0.5],
      ["id": "wp", "propertyID": 3, "value": 0.5],
    ] {
      await assertInvalid("\(body)") { try await context.controller.perform("propertyPreview", body: body) }
    }
    do {
      try await context.controller.perform("propertyPreview", body: ["id": "nope", "propertyID": "alpha", "value": 0.5])
      XCTFail("a wallpaper the library no longer has must be refused")
    } catch {}

    XCTAssertTrue(context.bridge.previews.isEmpty, "a refused step shows nothing")
    XCTAssertTrue(dragged.isEmpty)
    XCTAssertTrue(context.store.editorState.propertyPreviewValues.isEmpty, "and is not held for the next update either")
    XCTAssertTrue(context.bridge.events.isEmpty)

    // The edge of the range is a value like any other.
    try await context.drag("alpha", 0)
    try await context.drag("alpha", 1)
    XCTAssertEqual(context.bridge.previews.count, 2)
  }

  func testAStepDoesNotWaitBehindTheCommandThatIsRunning() async throws {
    let context = try Context()
    defer { context.tearDown() }
    try await context.switchOn()
    var release: CheckedContinuation<Void, Never>?
    let running = Task { @MainActor in
      await context.store.commands.run { await withCheckedContinuation { release = $0 } }
    }
    for _ in 0..<200 where release == nil { await Task.yield() }
    XCTAssertNotNil(release, "the first command must be running before the step is sent")

    try await context.drag("alpha", 0.4)

    XCTAssertEqual(
      context.bridge.previews.map(\.pending.count), [1],
      "a step that waited for a wallpaper switch would reach the displays long after the thumb moved on")
    XCTAssertTrue(context.store.commands.waiting.isEmpty)
    release?.resume()
    _ = await running.value
  }

  func testTheEditThatEndsADragKeepsItsValueAndTheStepIsNotShownAgain() async throws {
    let context = try Context()
    defer { context.tearDown() }
    try await context.switchOn()

    try await context.drag("alpha", 0.4)
    try await context.drag("alpha", 0.42)
    try await context.controller.perform("property", body: ["id": "wp", "propertyID": "alpha", "value": 0.45])

    XCTAssertTrue(context.store.editorState.propertyPreviewValues.isEmpty, "the release replaces the step")
    XCTAssertEqual(context.bridge.events, ["edit wp"])
    await context.letTheEditsPause()
    XCTAssertEqual(
      context.bridge.previews.last, .init(wallpaperID: "wp", show: true),
      "the update the edit starts asks for the draft alone: a step left in it would hide the value that was saved")
  }

  func testARefusedEditTakesTheStepBackToo() async throws {
    let context = try Context()
    defer { context.tearDown() }
    try await context.switchOn()
    context.bridge.editFailure = Refused()

    try await context.drag("alpha", 0.4)
    do {
      try await context.controller.perform("property", body: ["id": "wp", "propertyID": "alpha", "value": 0.4])
      XCTFail("the bridge refused the edit")
    } catch is Refused {}

    XCTAssertTrue(context.store.editorState.propertyPreviewValues.isEmpty, "a value nobody kept is not left on show")
    await context.letTheEditsPause()
    XCTAssertEqual(
      context.bridge.previews.last, .init(wallpaperID: "wp", show: true),
      "the displays are asked to follow the draft, which never took the value")
  }

  func testAnEditOfAnotherPropertyLeavesTheStepAlone() async throws {
    let context = try Context()
    defer { context.tearDown() }
    try await context.switchOn()

    try await context.drag("tint", "#ff8000")
    try await context.edit(true)
    await context.letTheEditsPause()
    XCTAssertEqual(context.bridge.previews.last?.pending.map(\.propertyId), ["tint"])

    try await context.controller.perform("restoreProperty", body: ["id": "wp", "propertyID": "tint"])
    XCTAssertTrue(context.store.editorState.propertyPreviewValues.isEmpty, "restoring the property it is for ends it")

    try await context.drag("alpha", 0.4)
    try await context.drag("tint", "#ff8000")
    try await context.controller.perform("restoreAllProperties", body: ["id": "wp"])
    XCTAssertTrue(context.store.editorState.propertyPreviewValues.isEmpty, "so does restoring every default")
  }

  func testRevertAndApplyEndTheStep() async throws {
    let context = try Context()
    defer { context.tearDown() }
    try await context.switchOn()

    try await context.drag("alpha", 0.4)
    try await context.controller.perform("revert", body: ["id": "wp"])
    XCTAssertTrue(context.store.editorState.propertyPreviewValues.isEmpty)
    await context.letTheEditsPause()
    XCTAssertEqual(
      context.bridge.previews.count, 1,
      "the bridge puts the saved look back when it cancels the edit, so the app asks for nothing more")

    try await context.drag("alpha", 0.4)
    try await context.edit(true)
    try await context.controller.perform("apply", body: ["id": "wp"])
    XCTAssertTrue(context.store.editorState.propertyPreviewValues.isEmpty)
    XCTAssertEqual(Array(context.bridge.events.suffix(2)), ["edit wp", "apply wp"])
  }

  func testAnotherWallpapersInspectorEndsTheStepAndTheDisplaysGoBackToTheDraft() async throws {
    let context = try Context()
    defer { context.tearDown() }
    try await context.switchOn()
    var named: [String] = []
    context.store.onPropertyDraftChanged = { named.append($0) }

    try await context.drag("alpha", 0.4)
    context.bridge.previews = []
    // The inspector shows wp2 from now on.
    try await context.controller.perform("property", body: ["id": "wp2", "propertyID": "mode", "value": true])

    XCTAssertTrue(context.store.editorState.propertyPreviewValues.isEmpty)
    XCTAssertEqual(Set(named), ["wp", "wp2"], "the wallpaper it left follows its draft again")
    await context.letTheEditsPause()
    XCTAssertTrue(context.bridge.previews.contains(.init(wallpaperID: "wp", show: true)))
  }

  func testAStepWhileTheWallpaperIsBeingAppliedIsDropped() async throws {
    let context = try Context()
    defer { context.tearDown() }
    try await context.switchOn()
    var dragged: [String] = []
    context.store.onPropertyDragged = { dragged.append($0) }
    context.bridge.holdApply = true
    let applying = Task { @MainActor in try await context.controller.perform("apply", body: ["id": "wp"]) }
    for _ in 0..<400 where context.store.applyingWallpaperID == nil { await Task.yield() }
    XCTAssertEqual(context.store.applyingWallpaperID, "wp", "the apply is under way")

    try await context.drag("alpha", 0.4)

    XCTAssertTrue(dragged.isEmpty)
    XCTAssertTrue(context.bridge.previews.isEmpty)
    XCTAssertTrue(
      context.store.editorState.propertyPreviewValues.isEmpty,
      "a step that outlived the apply would be left behind with nothing to end it")
    context.bridge.releaseApply()
    try await applying.value
  }

  func testARefusalIsLoggedOncePerRunNotForEveryStep() async throws {
    let context = try Context()
    defer { context.tearDown() }
    try await context.switchOn()
    context.bridge.previewFailure = Refused()

    for value in [0.1, 0.2, 0.3] { try await context.drag("alpha", value) }
    XCTAssertEqual(context.bridge.previews.count, 3, "every step still tries")
    XCTAssertEqual(context.log.count, 1, "the same refusal is logged once")
    XCTAssertTrue(context.log.first?.contains("wp") == true)
    XCTAssertNil(context.store.latestBridgeErrorMessage)

    context.bridge.previewFailure = nil
    try await context.drag("alpha", 0.4)
    context.bridge.previewFailure = Refused()
    try await context.drag("alpha", 0.5)
    XCTAssertEqual(context.log.count, 2, "a refusal after the displays took a step is news again")
  }

  // MARK: Doubles

  private struct Refused: Error {}

  private func assertInvalid(
    _ what: String, _ work: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line
  ) async {
    do {
      try await work()
      XCTFail("Accepted \(what)", file: file, line: line)
    } catch let error as WallpaperActionError {
      XCTAssertEqual(error.message, WebPanelRequest.invalid.message, what, file: file, line: line)
    } catch {
      XCTFail("Refused \(what) with \(error)", file: file, line: line)
    }
  }

  /// The panel's controller over a store whose bridge keeps each wallpaper's pending state the way
  /// the engine does and records the order of what it was asked.
  @MainActor
  private final class Context {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "panel-property-preview-\(UUID().uuidString)")
    let previousHome = ProcessInfo.processInfo.environment["WALLPAPER_MACHINE_HOME"]
    let defaults: UserDefaults
    let bridge = PreviewBridge(noPointer: .init())
    let sleeper = ManualSleeper()
    let store: BridgeStore
    let controller: WebPanelController
    /// What the store sent to its log.
    var log: [String] = []

    init() throws {
      setenv("WALLPAPER_MACHINE_HOME", root.path, 1)
      defaults = TemporaryDefaults.makeForCurrentTest().defaults
      store = BridgeStore(bridge: bridge)
      bridge.store = store
      // Applying validates the wallpaper's files; a web page is the cheapest project that passes.
      // The kind the options report is what decides whether the desktop can show an edit.
      let kinds: [(String, BridgeWallpaperKind)] = [
        ("wp", .projectScene), ("wp2", .projectScene), ("wp3", .projectScene), ("web", .webpage), ("clip", .video),
      ]
      for (id, kind) in kinds {
        let project = ClientPaths.libraryURL.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data(#"{"type":"web","file":"index.html"}"#.utf8).write(to: project.appendingPathComponent("project.json"))
        try Data("<!doctype html>".utf8).write(to: project.appendingPathComponent("index.html"))
        bridge.options[id] = BridgeSnapshotFixtures.options(
          wallpaperId: id, title: id, kind: kind, properties: [
            Self.property("mode", .bool, .bool(value: false)),
            Self.property("note", .textInput, .string(value: "")),
            Self.property("alpha", .slider, .number(value: 1), slider: .init(min: 0, max: 1, step: 0.01, precision: 2)),
            Self.property("tint", .color, .colorRgb(red: 1, green: 1, blue: 1)),
            Self.property("picture", .texture, .string(value: "")),
            Self.property("locked", .slider, .number(value: 0), slider: .init(min: 0, max: 1, step: 0.01, precision: 2), enabled: false),
          ])
      }
      store.librarySnapshot.wallpapers = kinds.map {
        BridgeWallpaperEntry(
          id: $0.0, title: $0.0, kind: $0.1, supported: true, active: false, selected: false, previewPath: nil)
      }
      store.wallpaperOptionsSnapshot = bridge.options["wp"]
      let defaults = defaults
      store.showsPropertyEditsOnDesktop = { LivePropertyEditing.isEnabled(defaults: defaults) }
      store.desktopPropertyPreviews = PropertyPreviewScheduler(delay: .milliseconds(150), sleep: sleeper.closure)
      let workshop = WorkshopStore(
        downloader: WorkshopDownloadManager(sessionDirectory: root), supportDirectory: root, defaults: defaults)
      controller = WebPanelController(
        store: store, navigation: ControlPanelNavigation(), workshop: workshop, defaults: defaults,
        appLanguage: .english())
      store.desktopPropertyPreviewLog = { [unowned self] in log.append($0) }
    }

    func tearDown() {
      controller.stop()
      store.desktopPropertyPreviews.cancelAll()
      if let previousHome { setenv("WALLPAPER_MACHINE_HOME", previousHome, 1) } else { unsetenv("WALLPAPER_MACHINE_HOME") }
      try? FileManager.default.removeItem(at: root)
    }

    /// The page sends a step of a slider or colour being dragged.
    func drag(_ property: String, _ value: Any, id: String = "wp") async throws {
      try await controller.perform("propertyPreview", body: ["id": id, "propertyID": property, "value": value])
    }

    /// The inspector flips a switch property.
    func edit(_ value: Bool, id: String = "wp") async throws {
      try await controller.perform("property", body: ["id": id, "propertyID": "mode", "value": value])
    }

    func switchOn() async throws {
      try await controller.perform("setting", body: ["key": "livePropertyEdits", "value": true])
    }

    func switchOff() async throws {
      try await controller.perform("setting", body: ["key": "livePropertyEdits", "value": false])
    }

    /// Displays 1 and 2 show "wp" (2 mirrors 1), display 3 shows "wp2" and display 4 shows nothing.
    func showWallpapersOnDisplays() {
      func row(_ id: String, _ title: String, _ wallpaper: String, mirroring target: String? = nil) -> BridgeMonitorInfoRow {
        BridgeMonitorInfoRow(
          displayId: id, title: title, wallpaperId: wallpaper, wallpaperTitle: wallpaper, mirrorTargetDisplayId: target,
          mirrorTargetTitle: nil, scalingMode: "fill", targetFps: "30", audioResponse: false)
      }
      store.monitorInformationSnapshot = BridgeMonitorInformationSnapshot(rows: [
        row("1", "Left (1 - Primary)", "wp"),
        row("2", "Right (2 - Mirror)", "wp", mirroring: "1"),
        row("3", "Other (3 - Secondary)", "wp2"),
        row("4", "Empty (4 - Secondary)", ""),
      ])
    }

    /// The displays of `showWallpapersOnDisplays` that the Mission Control picture is not taken from.
    func displaysShowingEdits() -> [String] {
      ["1", "2", "3", "4"].filter { store.isShowingPropertyEdits(onDisplay: $0) }
    }

    func settle() async { for _ in 0..<60 { await Task.yield() } }

    /// Lets the quiet period pass, once for every time an edit started it over.
    func letTheEditsPause() async {
      for _ in 0..<8 {
        await settle()
        if sleeper.finishWaits() == 0 { break }
      }
      await settle()
    }

    private static func property(
      _ id: String, _ kind: BridgePropertyKind, _ value: BridgePropertyValue, slider: BridgeSliderMetadata? = nil,
      enabled: Bool = true
    ) -> BridgePropertyDescriptor {
      BridgePropertyDescriptor(
        id: id, kind: kind, labelHtml: id, value: value, defaultValue: value, slider: slider, comboOptions: [],
        fileFilter: nil, directoryMode: nil, dirty: false, canRestoreDefaults: true, enabled: enabled,
        assetManaged: false, assetMissing: false, assetSourcePath: nil)
    }
  }
}

/// Answers a wallpaper's options as the engine would after each call and records, in order, what the
/// panel and the store asked of the displays and of the draft.
private final class PreviewBridge: WallpaperBridge {
  struct Preview: Hashable {
    var wallpaperID: String
    var show: Bool
    /// The values being dragged that the displays were told to show on top of the draft.
    var pending: [BridgePropertyEdit] = []
  }

  @MainActor weak var store: BridgeStore?
  @MainActor var options: [String: BridgeWallpaperOptionsSnapshot] = [:]
  /// What the displays were asked to show, in order.
  @MainActor var previews: [Preview] = []
  /// Edits, reverts and applies the bridge received, in order, as "edit wp".
  @MainActor var events: [String] = []
  @MainActor var previewFailure: Error?
  /// What the next edit fails with, when a test needs the bridge to refuse it.
  @MainActor var editFailure: Error?
  /// While set, an apply is received but not answered until `releaseApply()`, which is how a test
  /// holds a wallpaper in the middle of being applied.
  @MainActor var holdApply = false
  @MainActor private var heldApplies: [CheckedContinuation<Void, Never>] = []

  @MainActor func releaseApply() {
    holdApply = false
    let held = heldApplies
    heldApplies = []
    for continuation in held { continuation.resume() }
  }

  override func wallpaperOptionsSnapshot(wallpaperId: String) async throws -> BridgeWallpaperOptionsSnapshot {
    try await current(wallpaperId)
  }

  override func editProperty(wallpaperId: String, propertyId: String, value: BridgePropertyValue) async throws
    -> BridgeWallpaperMutationBundle
  {
    try await refuseEditOnRequest()
    return try await reply("edit", wallpaperId, dirty: true)
  }

  @MainActor private func refuseEditOnRequest() throws {
    if let editFailure { throw editFailure }
  }

  override func setPropertyPath(wallpaperId: String, propertyId: String, path: String?) async throws
    -> BridgeWallpaperMutationBundle
  {
    try await reply("path", wallpaperId, dirty: true)
  }

  override func restorePropertyDefault(wallpaperId: String, propertyId: String) async throws
    -> BridgeWallpaperMutationBundle
  {
    try await reply("restore", wallpaperId, dirty: true)
  }

  override func restoreAllPropertyDefaults(wallpaperId: String) async throws -> BridgeWallpaperMutationBundle {
    try await reply("restoreAll", wallpaperId, dirty: true)
  }

  override func cancelWallpaperOptions(wallpaperId: String) async throws -> BridgeWallpaperMutationBundle {
    try await reply("cancel", wallpaperId, dirty: false)
  }

  override func applyWallpaperOptions(wallpaperId: String, userInitiated: Bool) async throws
    -> BridgeWallpaperMutationBundle
  {
    await holdIfAsked()
    return try await reply("apply", wallpaperId, dirty: false)
  }

  @MainActor private func holdIfAsked() async {
    if holdApply { await withCheckedContinuation { heldApplies.append($0) } }
  }

  override func previewWallpaperProperties(wallpaperId: String, show: Bool, pending: [BridgePropertyEdit]) async throws {
    try await receivePreview(Preview(wallpaperID: wallpaperId, show: show, pending: pending))
  }

  override func refreshLibrary() async throws -> BridgeSnapshotBundle {
    try await library()
  }

  @MainActor private func current(_ id: String) throws -> BridgeWallpaperOptionsSnapshot {
    guard let options = options[id] else { throw CancellationError() }
    return options
  }

  @MainActor private func receivePreview(_ preview: Preview) throws {
    previews.append(preview)
    if let previewFailure { throw previewFailure }
  }

  /// The engine's reply to a call that changes the draft: the wallpaper's options afterwards.
  /// Only a call that edits is recorded under its name; the others do not matter to a test.
  @MainActor private func reply(_ event: String, _ id: String, dirty: Bool) throws -> BridgeWallpaperMutationBundle {
    if ["edit", "cancel", "apply"].contains(event) { events.append("\(event) \(id)") }
    var changed = try current(id)
    changed.dirty = dirty
    options[id] = changed
    let store = try XCTUnwrap(store)
    return BridgeWallpaperMutationBundle(
      app: store.appSnapshot, library: store.librarySnapshot, wallpaperOptions: changed,
      monitorInformation: store.monitorInformationSnapshot, settings: store.settingsSnapshot)
  }

  @MainActor private func library() throws -> BridgeSnapshotBundle {
    let store = try XCTUnwrap(store)
    return BridgeSnapshotBundle(
      app: store.appSnapshot, library: store.librarySnapshot, wallpaperOptions: nil,
      monitorInformation: store.monitorInformationSnapshot, settings: store.settingsSnapshot)
  }
}

/// The inspector's sliders and colour pickers as the page drives them: what a drag sends while it
/// goes on and what the release saves. The displays are asked through the bridge double, which is
/// how a step is seen here; whether a display visibly follows is a desktop check.
@MainActor
final class WebPanelPropertyDragPageTests: XCTestCase {
  func testADragShowsTheNewestStepAtMostOnceAHundredMillisecondsThenSavesOnRelease() async throws {
    try await withPanel { panel, bridge in
      let slider = Self.control("alpha")
      try await panel.waitJS("document.querySelector('\(slider)')")
      // The delays the page asks its timers for while the drag is going on.
      _ = try await panel.js("""
        window.timerDelays = [];
        const setTimer = window.setTimeout.bind(window);
        window.setTimeout = (callback, delay, ...rest) => {
          window.timerDelays.push(delay);
          return setTimer(callback, delay, ...rest);
        };
        """)

      // Five steps inside one animation frame: the first is shown at once, the rest are
      // collapsed into the newest, which follows when the interval is up.
      _ = try await panel.js(Self.drag(slider, ["0.31", "0.32", "0.33", "0.34", "0.35"]))

      try await panel.waitUntil { bridge.steps.count == 2 }
      XCTAssertEqual(bridge.steps, [[Self.alpha(0.31)], [Self.alpha(0.35)]])
      let delayed = try await panel.js("return window.timerDelays.filter(delay => delay > 0 && delay <= 100).length") as? Int
      XCTAssertGreaterThanOrEqual(
        delayed ?? 0, 1, "The newest step waits out the interval since the last one instead of following the reply at once")
      try await Task.sleep(for: .milliseconds(300))
      XCTAssertEqual(bridge.steps.count, 2, "Nothing is sent while the thumb is still")
      XCTAssertTrue(bridge.edits.isEmpty, "Dragging saves nothing")

      _ = try await panel.js(Self.release(slider))
      try await panel.waitUntil { bridge.edits.count == 1 }
      try await Task.sleep(for: .milliseconds(250))
      XCTAssertEqual(bridge.edits, [Self.alpha(0.35)], "The release saves the value it settled on, once")
      XCTAssertEqual(bridge.steps.count, 2, "and no step follows it")
      try await panel.waitJS("document.querySelector('\(slider)').value === '0.35'")
      XCTAssertTrue(panel.store.editorState.propertyPreviewValues.isEmpty, "the saved value replaced the step")
    }
  }

  func testReleasingBeforeTheFollowingStepCancelsItAndSavesTheNewestValue() async throws {
    try await withPanel { panel, bridge in
      let slider = Self.control("alpha")
      try await panel.waitJS("document.querySelector('\(slider)')")

      _ = try await panel.js(Self.drag(slider, ["0.31", "0.35"]) + Self.release(slider))

      try await panel.waitUntil { bridge.edits.count == 1 }
      try await Task.sleep(for: .milliseconds(300))
      XCTAssertEqual(bridge.edits, [Self.alpha(0.35)])
      XCTAssertEqual(bridge.steps, [[Self.alpha(0.31)]], "The step that was waiting for its turn is dropped: the release carries its value")
    }
  }

  func testTheReleaseWaitsForTheStepStillOnItsWay() async throws {
    try await withPanel { panel, bridge in
      let slider = Self.control("alpha")
      try await panel.waitJS("document.querySelector('\(slider)')")
      bridge.holdSteps = true

      _ = try await panel.js(Self.drag(slider, ["0.31", "0.35"]) + Self.release(slider))
      try await panel.waitUntil { bridge.steps.count == 1 }
      try await Task.sleep(for: .milliseconds(300))

      XCTAssertTrue(
        bridge.edits.isEmpty,
        "A step the displays have not answered could still land after the release if the release did not wait for it")
      bridge.releaseSteps()
      try await panel.waitUntil { bridge.edits.count == 1 }
      XCTAssertEqual(bridge.edits, [Self.alpha(0.35)])
      XCTAssertEqual(bridge.steps.count, 1)
    }
  }

  func testADragThatEndsWhereItBeganSavesThatValueEvenThoughNoChangeFires() async throws {
    try await withPanel { panel, bridge in
      let slider = Self.control("alpha")
      try await panel.waitJS("document.querySelector('\(slider)')")

      // Out to 0.7 and back to the 1 it started at: the browser fires no change event for
      // that, so the displays would stay at the last step shown unless the release settles it.
      _ = try await panel.js(Self.drag(slider, ["0.7"]))
      try await panel.waitUntil { bridge.steps.count == 1 }
      _ = try await panel.js(Self.drag(slider, ["1"], press: false))
      try await panel.waitUntil { bridge.steps.count == 2 }
      XCTAssertTrue(bridge.edits.isEmpty)
      _ = try await panel.js("document.dispatchEvent(new PointerEvent('pointerup', { bubbles: true }))")

      try await panel.waitUntil { bridge.edits.count == 1 }
      XCTAssertEqual(bridge.edits, [Self.alpha(1)], "The value the slider shows is sent, so the bridge can put the scene back")
      XCTAssertEqual(bridge.steps, [[Self.alpha(0.7)], [Self.alpha(1)]])
    }
  }

  func testAPointerThatIsCancelledSavesTheLastStepShownAndNothingMoreAfterIt() async throws {
    try await withPanel { panel, bridge in
      let slider = Self.control("alpha")
      try await panel.waitJS("document.querySelector('\(slider)')")

      _ = try await panel.js(Self.drag(slider, ["0.6"]))
      try await panel.waitUntil { bridge.steps.count == 1 }
      _ = try await panel.js("document.dispatchEvent(new PointerEvent('pointercancel', { bubbles: true }))")

      try await panel.waitUntil { bridge.edits.count == 1 }
      try await Task.sleep(for: .milliseconds(250))
      XCTAssertEqual(bridge.edits, [Self.alpha(0.6)])
      XCTAssertEqual(bridge.steps.count, 1)
      // The drag is over: another step on the slider without a press is a key press.
      _ = try await panel.js(Self.drag(slider, ["0.61"], press: false))
      try await Task.sleep(for: .milliseconds(250))
      XCTAssertEqual(bridge.steps.count, 1)
    }
  }

  func testAKeyPressSavesAtOnceWithoutShowingAStepFirst() async throws {
    try await withPanel { panel, bridge in
      let slider = Self.control("alpha")
      try await panel.waitJS("document.querySelector('\(slider)')")

      // An arrow key fires input and change together, with no pointer down.
      _ = try await panel.js("""
        const input = document.querySelector('\(slider)');
        input.value = '0.21';
        input.dispatchEvent(new Event('input', { bubbles: true }));
        input.dispatchEvent(new Event('change', { bubbles: true }));
        """)

      try await panel.waitUntil { bridge.edits.count == 1 }
      try await Task.sleep(for: .milliseconds(250))
      XCTAssertEqual(bridge.edits, [Self.alpha(0.21)])
      XCTAssertTrue(bridge.steps.isEmpty, "A single step has nothing to follow")
    }
  }

  func testAColourPickerShowsItsStepsAndASinglePickShowsNoneBeforeItIsSaved() async throws {
    try await withPanel { panel, bridge in
      let picker = Self.control("tint")
      try await panel.waitJS("document.querySelector('\(picker)')")

      // One pick: input and change arrive together, so there is nothing to follow.
      _ = try await panel.js("""
        const input = document.querySelector('\(picker)');
        input.value = '#112233';
        input.dispatchEvent(new Event('input', { bubbles: true }));
        input.dispatchEvent(new Event('change', { bubbles: true }));
        """)
      try await panel.waitUntil { bridge.edits.count == 1 }
      try await Task.sleep(for: .milliseconds(250))
      XCTAssertEqual(bridge.edits, [Self.tint(0x11, 0x22, 0x33)])
      XCTAssertTrue(bridge.steps.isEmpty)

      // A drag in the colour panel: input events with no change and no pointer on the page.
      _ = try await panel.js("""
        const input = document.querySelector('\(picker)');
        input.value = '#445566';
        input.dispatchEvent(new Event('input', { bubbles: true }));
        """)
      try await panel.waitUntil { bridge.steps.count == 1 }
      _ = try await panel.js("""
        const input = document.querySelector('\(picker)');
        input.value = '#778899';
        input.dispatchEvent(new Event('input', { bubbles: true }));
        """)
      try await panel.waitUntil { bridge.steps.count == 2 }
      XCTAssertEqual(bridge.steps, [[Self.tint(0x44, 0x55, 0x66)], [Self.tint(0x77, 0x88, 0x99)]])
      XCTAssertEqual(bridge.edits.count, 1, "nothing is saved while the picker is open")

      _ = try await panel.js("document.querySelector('\(picker)').dispatchEvent(new Event('change', { bubbles: true }))")
      try await panel.waitUntil { bridge.edits.count == 2 }
      XCTAssertEqual(bridge.edits.last, Self.tint(0x77, 0x88, 0x99))
      XCTAssertEqual(bridge.steps.count, 2)
    }
  }

  func testOtherControlsOfAPropertySaveWithoutShowingAStep() async throws {
    try await withPanel { panel, bridge in
      let toggle = Self.control("mode")
      try await panel.waitJS("document.querySelector('\(toggle)')")

      _ = try await panel.js("""
        const input = document.querySelector('\(toggle)');
        input.dispatchEvent(new PointerEvent('pointerdown', { bubbles: true, buttons: 1 }));
        input.checked = true;
        input.dispatchEvent(new Event('input', { bubbles: true }));
        input.dispatchEvent(new Event('change', { bubbles: true }));
        """)

      try await panel.waitUntil { bridge.edits.count == 1 }
      try await Task.sleep(for: .milliseconds(250))
      XCTAssertEqual(bridge.edits, [.init(propertyId: "mode", value: .bool(value: true))])
      XCTAssertTrue(bridge.steps.isEmpty)
    }
  }

  // MARK: Fixtures

  private static func control(_ property: String) -> String {
    "#inspector [data-change=\"property\"][data-property-id=\"\(property)\"]"
  }

  private static func alpha(_ value: Double) -> BridgePropertyEdit {
    .init(propertyId: "alpha", value: .number(value: value))
  }

  private static func tint(_ red: Int, _ green: Int, _ blue: Int) -> BridgePropertyEdit {
    .init(propertyId: "tint", value: .colorRgb(red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255))
  }

  /// Presses the slider (unless `press` is false) and steps it through `values` as consecutive
  /// input events, the way a pointer drag does.
  private static func drag(_ slider: String, _ values: [String], press: Bool = true) -> String {
    """
    const slider = document.querySelector('\(slider)');
    \(press ? "slider.dispatchEvent(new PointerEvent('pointerdown', { bubbles: true, buttons: 1 }));" : "")
    for (const value of \(values)) {
      slider.value = value;
      slider.dispatchEvent(new Event('input', { bubbles: true }));
    }
    """
  }

  /// The pointer comes up, and the browser then fires the slider's change event.
  private static func release(_ slider: String) -> String {
    """
    document.dispatchEvent(new PointerEvent('pointerup', { bubbles: true }));
    document.querySelector('\(slider)').dispatchEvent(new Event('change', { bubbles: true }));
    """
  }

  private static func property(
    _ id: String, _ kind: BridgePropertyKind, _ value: BridgePropertyValue, slider: BridgeSliderMetadata? = nil
  ) -> BridgePropertyDescriptor {
    BridgePropertyDescriptor(
      id: id, kind: kind, labelHtml: id, value: value, defaultValue: value, slider: slider, comboOptions: [],
      fileFilter: nil, directoryMode: nil, dirty: false, canRestoreDefaults: true, enabled: true,
      assetManaged: false, assetMissing: false, assetSourcePath: nil)
  }

  private func withPanel(_ body: (PanelFixture, DragBridge) async throws -> Void) async throws {
    let bridge = DragBridge(noPointer: .init())
    let store = BridgeStore(bridge: bridge)
    bridge.bundleProvider = { [store] in
      BridgeSnapshotBundle(
        app: store.appSnapshot, library: store.librarySnapshot, wallpaperOptions: nil,
        monitorInformation: store.monitorInformationSnapshot, settings: store.settingsSnapshot)
    }
    // The displays follow, and the quiet period an edit waits out never ends in a test.
    store.showsPropertyEditsOnDesktop = { true }
    store.desktopPropertyPreviews = PropertyPreviewScheduler(delay: .seconds(3600))
    let panel = try PanelFixture(store: store, bridge: bridge, displayTitles: .renderer)
    do {
      try await panel.start()
      let options = BridgeSnapshotFixtures.options(
        wallpaperId: "scene-1", title: "scene-1", kind: .projectScene,
        properties: [
          Self.property("alpha", .slider, .number(value: 1), slider: .init(min: 0, max: 1, step: 0.01, precision: 2)),
          Self.property("tint", .color, .colorRgb(red: 1, green: 1, blue: 1)),
          Self.property("mode", .bool, .bool(value: false)),
        ])
      store.librarySnapshot.wallpapers = [
        BridgeWallpaperEntry(
          id: "scene-1", title: "scene-1", kind: .projectScene, supported: true, active: false, selected: false,
          previewPath: nil)
      ]
      store.appSnapshot = .init(
        playbackState: .playing, selectedWallpaperId: "scene-1", activeWallpaperIds: [], errors: [], heldWallpaperIds: [])
      bridge.options["scene-1"] = options
      store.wallpaperOptionsSnapshot = options
      try await panel.finishWelcome()
      panel.show()
      try await body(panel, bridge)
    } catch {
      store.desktopPropertyPreviews.cancelAll()
      await panel.shutdown()
      throw error
    }
    store.desktopPropertyPreviews.cancelAll()
    await panel.shutdown()
  }
}

/// A bridge that answers an edit with the wallpaper's options as the engine would report them, and
/// records what the displays were asked to show and what was saved.
private final class DragBridge: LayoutSnapshotBridge {
  /// The values being dragged that each update of the displays carried; an update of the saved
  /// draft alone carries none and is left out.
  @MainActor var steps: [[BridgePropertyEdit]] = []
  /// The edits the draft took, in order.
  @MainActor var edits: [BridgePropertyEdit] = []
  /// While set, a step is received but not answered until `releaseSteps()`, which is how a test
  /// holds a step on its way.
  @MainActor var holdSteps = false
  @MainActor private var heldSteps: [CheckedContinuation<Void, Never>] = []

  @MainActor func releaseSteps() {
    holdSteps = false
    let held = heldSteps
    heldSteps = []
    for continuation in held { continuation.resume() }
  }

  override func previewWallpaperProperties(wallpaperId: String, show: Bool, pending: [BridgePropertyEdit]) async throws {
    try await receive(pending)
  }

  @MainActor private func receive(_ pending: [BridgePropertyEdit]) async throws {
    if !pending.isEmpty { steps.append(pending) }
    if holdSteps { await withCheckedContinuation { heldSteps.append($0) } }
  }

  override func editProperty(wallpaperId: String, propertyId: String, value: BridgePropertyValue) async throws
    -> BridgeWallpaperMutationBundle
  {
    try await edit(wallpaperId, BridgePropertyEdit(propertyId: propertyId, value: value))
  }

  @MainActor private func edit(_ wallpaperId: String, _ edit: BridgePropertyEdit) throws -> BridgeWallpaperMutationBundle {
    edits.append(edit)
    guard var changed = options[wallpaperId], let base = bundleProvider?() else { throw CancellationError() }
    changed.dirty = true
    changed.properties = changed.properties.map { property in
      var property = property
      if property.id == edit.propertyId { property.value = edit.value; property.dirty = true }
      return property
    }
    options[wallpaperId] = changed
    return BridgeWallpaperMutationBundle(
      app: base.app, library: base.library, wallpaperOptions: changed,
      monitorInformation: base.monitorInformation, settings: base.settings)
  }
}
