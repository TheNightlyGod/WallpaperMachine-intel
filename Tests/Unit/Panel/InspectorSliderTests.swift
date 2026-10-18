import AppKit
import XCTest

@testable import WallpaperMachine

/// How a slider's pointer, keyboard and VoiceOver paths reach the controller. The inspector previews
/// a pointer drag and saves a key press or a VoiceOver change at once; these tests hold the AppKit
/// slider to that split, and the drivers that connect it to the controller's drag pumps to the rest:
/// the first step at once, the newest value after the interval, a release that waits for the step in
/// flight and always saves, and a key press that never previews.
@MainActor
final class InspectorSliderTests: XCTestCase {
  // MARK: The slider itself

  private func slider(
    value: Double = 120, range: ClosedRange<Double> = 0...500, step: Double? = 10
  ) -> (slider: PanelNSSlider, log: EventLog) {
    let slider = PanelNSSlider(frame: NSRect(x: 0, y: 0, width: 200, height: 20))
    slider.minValue = range.lowerBound
    slider.maxValue = range.upperBound
    slider.step = step
    slider.doubleValue = value
    let log = EventLog()
    slider.events = PanelSliderEvents(
      onDrag: { log.events.append("drag \($0)") },
      onRelease: { log.events.append("release \($0)") },
      onStep: { log.events.append("step \($0)") })
    return (slider, log)
  }

  @MainActor
  private final class EventLog {
    var events: [String] = []
  }

  private func key(_ code: UInt16) -> NSEvent {
    NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
      context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
  }

  func testAVoiceOverIncrementAndDecrementMoveByTheStepAndAreSavedAtOnce() {
    let (slider, log) = slider()
    XCTAssertTrue(slider.accessibilityPerformIncrement())
    XCTAssertTrue(slider.accessibilityPerformDecrement())
    XCTAssertTrue(slider.accessibilityPerformDecrement())
    XCTAssertEqual(log.events, ["step 130.0", "step 120.0", "step 110.0"])
    XCTAssertEqual(slider.doubleValue, 110)
  }

  func testArrowKeysPageKeysHomeAndEndAreSavedAtOnceWithoutAnyDrag() {
    let (slider, log) = slider(value: 100)
    slider.keyDown(with: key(124))  // right
    slider.keyDown(with: key(126))  // up
    slider.keyDown(with: key(123))  // left
    slider.keyDown(with: key(125))  // down
    slider.keyDown(with: key(116))  // page up: ten steps
    slider.keyDown(with: key(119))  // end
    slider.keyDown(with: key(115))  // home
    XCTAssertEqual(
      log.events, ["step 110.0", "step 120.0", "step 110.0", "step 100.0", "step 200.0", "step 500.0", "step 0.0"])
    XCTAssertFalse(log.events.contains { $0.hasPrefix("drag") || $0.hasPrefix("release") })
  }

  func testTheEndsOfTheRangeAreNotPassedAndMoveNothingToReport() {
    let (slider, log) = slider(value: 500)
    XCTAssertFalse(slider.nudge(by: 1), "already at the top")
    slider.keyDown(with: key(124))
    slider.doubleValue = 0
    XCTAssertFalse(slider.nudge(by: -1))
    XCTAssertTrue(log.events.isEmpty)
  }

  func testASliderWithNoStepMovesByAHundredthOfItsRange() {
    let (slider, log) = slider(value: 0.5, range: 0...1, step: nil)
    slider.keyDown(with: key(124))
    XCTAssertEqual(slider.doubleValue, 0.51, accuracy: 1e-9)
    XCTAssertEqual(log.events.count, 1)
  }

  func testADisabledSliderIgnoresKeysAndVoiceOver() {
    let (slider, log) = slider()
    slider.isEnabled = false
    slider.keyDown(with: key(124))
    XCTAssertFalse(slider.accessibilityPerformIncrement())
    XCTAssertTrue(log.events.isEmpty)
  }

  func testThePointerDragsAndTheReleaseSettlesWithTheLastValue() {
    let (slider, log) = slider()
    slider.beginPointer()
    for value in [125.0, 130.0, 187.0] {
      slider.doubleValue = value
      slider.valueDidChange(nil)
    }
    XCTAssertTrue(slider.isTrackingPointer)
    slider.endPointer()
    XCTAssertFalse(slider.isTrackingPointer)
    XCTAssertEqual(
      log.events, ["drag 130.0", "drag 190.0", "release 190.0"],
      "values are held to the step, the first move that does not change the value is not a drag, and the release carries the last")
  }

  func testAClickOnTheThumbThatDoesNotMoveItIsNotADrag() {
    let (slider, log) = slider()
    slider.beginPointer()
    slider.valueDidChange(nil)
    slider.endPointer()
    XCTAssertTrue(log.events.isEmpty, "nothing changed, so nothing is saved")
  }

  func testADragThatReturnsToWhereItBeganStillReleasesThatValue() {
    let (slider, log) = slider()
    slider.beginPointer()
    slider.doubleValue = 200
    slider.valueDidChange(nil)
    slider.doubleValue = 120
    slider.valueDidChange(nil)
    slider.endPointer()
    XCTAssertEqual(
      log.events, ["drag 200.0", "drag 120.0", "release 120.0"],
      "the wallpaper was shown at 200 and must be put back at a saved value")
  }

  func testValuesAreSnappedToTheStepWithoutFloatingPointDust() {
    let (slider, _) = slider(value: 0.3, range: 0...1, step: 0.05)
    XCTAssertEqual(slider.snapped(0.3000000004), 0.3)
    XCTAssertEqual(slider.snapped(0.32), 0.3)
    XCTAssertEqual(slider.snapped(0.33), 0.35)
    XCTAssertEqual(slider.snapped(-4), 0)
    XCTAssertEqual(slider.snapped(7), 1)
  }

  // MARK: Wired to the controller (properties)

  func testADragPreviewsTheNewestValueAndTheReleaseSavesTheFinalOne() async throws {
    try await PanelPropertyContext.with { context in
      context.switchOn()
      let drag = PumpedDrag<PropertyDragValue>.property(
        controller: context.controller, wallpaperID: "wp", property: "alpha",
        sleep: context.sleeper.closure)

      for value in [0.31, 0.32, 0.33, 0.34, 0.35] { drag.update(.number(value)) }
      await context.settle()
      XCTAssertEqual(
        context.bridge.previews.map(\.pending),
        [[.init(propertyId: "alpha", value: .number(value: 0.31))]],
        "the first step is shown at once")
      XCTAssertTrue(context.bridge.edits.isEmpty, "dragging saves nothing")
      XCTAssertTrue(drag.isDragging)

      context.sleeper.fireNext()
      await context.settle()
      XCTAssertEqual(
        context.bridge.previews.last?.pending, [.init(propertyId: "alpha", value: .number(value: 0.35))])

      await drag.release(.number(0.35)).value
      XCTAssertEqual(context.bridge.edits, [.init(propertyId: "alpha", value: .number(value: 0.35))])
      XCTAssertEqual(context.bridge.previews.count, 2, "no step follows the release")
      XCTAssertFalse(drag.isDragging)
      XCTAssertNil(context.controller.errors.message)
    }
  }

  func testAKeyPressOrVoiceOverStepSavesAtOnceAndNeverPreviews() async throws {
    try await PanelPropertyContext.with { context in
      context.switchOn()
      let drag = PumpedDrag<PropertyDragValue>.property(
        controller: context.controller, wallpaperID: "wp", property: "alpha",
        sleep: context.sleeper.closure)

      await drag.step(.number(0.21)).value
      XCTAssertEqual(context.bridge.edits, [.init(propertyId: "alpha", value: .number(value: 0.21))])
      XCTAssertTrue(context.bridge.previews.isEmpty, "a key press shows no step first")
      XCTAssertFalse(drag.isDragging)
      XCTAssertTrue(
        context.sleeper.requested.filter { $0 == .milliseconds(100) }.isEmpty, "and starts no pump")
    }
  }

  func testTheSlidersOwnKeyAndVoiceOverEventsReachTheSavedEdit() async throws {
    try await PanelPropertyContext.with { context in
      let drag = PumpedDrag<PropertyDragValue>.property(
        controller: context.controller, wallpaperID: "wp", property: "alpha",
        sleep: context.sleeper.closure)
      let slider = PanelNSSlider(frame: NSRect(x: 0, y: 0, width: 200, height: 20))
      slider.minValue = 0
      slider.maxValue = 1
      slider.step = 0.05
      slider.doubleValue = 0.5
      var tasks: [Task<Void, Never>] = []
      slider.events = PanelSliderEvents(
        onDrag: { drag.update(.number($0)) },
        onRelease: { tasks.append(drag.release(.number($0))) },
        onStep: { tasks.append(drag.step(.number($0))) })

      XCTAssertTrue(slider.accessibilityPerformIncrement())
      slider.keyDown(
        with: NSEvent.keyEvent(
          with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
          context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false,
          keyCode: 124)!)
      for task in tasks { await task.value }

      XCTAssertEqual(
        context.bridge.edits,
        [
          .init(propertyId: "alpha", value: .number(value: 0.55)),
          .init(propertyId: "alpha", value: .number(value: 0.6)),
        ], "each step is its own saved edit, in order")
      XCTAssertTrue(context.bridge.previews.isEmpty)
    }
  }

  func testThePointersEventsPreviewAndThenSaveTheValueTheDragSettledOn() async throws {
    try await PanelPropertyContext.with { context in
      context.switchOn()
      let drag = PumpedDrag<PropertyDragValue>.property(
        controller: context.controller, wallpaperID: "wp", property: "alpha",
        sleep: context.sleeper.closure)
      let slider = PanelNSSlider(frame: NSRect(x: 0, y: 0, width: 200, height: 20))
      slider.minValue = 0
      slider.maxValue = 1
      slider.step = 0.05
      slider.doubleValue = 0.5
      var released: Task<Void, Never>?
      slider.events = PanelSliderEvents(
        onDrag: { drag.update(.number($0)) },
        onRelease: { released = drag.release(.number($0)) })

      slider.beginPointer()
      for value in [0.6, 0.7, 0.8] {
        slider.doubleValue = value
        slider.valueDidChange(nil)
      }
      await context.settle()
      XCTAssertEqual(
        try XCTUnwrap(context.bridge.previews.first?.pending.first?.propertyId), "alpha", "the drag is previewed")
      XCTAssertTrue(context.bridge.edits.isEmpty)
      slider.endPointer()
      await released?.value
      XCTAssertEqual(
        context.bridge.edits, [.init(propertyId: "alpha", value: .number(value: 0.8))],
        "and the release saves what the drag settled on")
    }
  }

  func testTwoStepsInARowLandInOrderSoTheNewestIsLast() async throws {
    try await PanelPropertyContext.with { context in
      let drag = PumpedDrag<PropertyDragValue>.property(
        controller: context.controller, wallpaperID: "wp", property: "alpha",
        sleep: context.sleeper.closure)
      let first = drag.step(.number(0.1))
      let second = drag.step(.number(0.2))
      await first.value
      await second.value
      XCTAssertEqual(
        context.bridge.edits.map(\.value),
        [.number(value: 0.1), .number(value: 0.2)], "latest wins: the newest value is sent last")
    }
  }

  func testACutOffDragSettlesWithTheNewestValueSoTheWallpaperIsPutBack() async throws {
    try await PanelPropertyContext.with { context in
      context.switchOn()
      let drag = PumpedDrag<PropertyDragValue>.property(
        controller: context.controller, wallpaperID: "wp", property: "alpha",
        sleep: context.sleeper.closure)
      XCTAssertNil(drag.settle(), "nothing to settle before a drag")
      drag.update(.number(0.4))
      drag.update(.number(0.45))
      await drag.settle()?.value
      XCTAssertEqual(context.bridge.edits, [.init(propertyId: "alpha", value: .number(value: 0.45))])
      XCTAssertFalse(drag.isDragging)
    }
  }

  func testARefusedSaveReachesTheBannerAndNotTheSlider() async throws {
    try await PanelPropertyContext.with { context in
      let drag = PumpedDrag<PropertyDragValue>.property(
        controller: context.controller, wallpaperID: "wp", property: "alpha",
        sleep: context.sleeper.closure)
      await drag.step(.number(7)).value  // outside the slider's 0...1
      XCTAssertTrue(context.bridge.edits.isEmpty)
      XCTAssertEqual(
        context.controller.errors.message,
        "This control sent an invalid value. Refresh the interface and retry.")
    }
  }

  // MARK: Colour

  func testASingleColourPickIsSavedOnceTheQuietPeriodPassesWithoutAnyPreviewBeforeIt() async throws {
    try await PanelPropertyContext.with { context in
      context.switchOn()
      let quiet = ManualSleeper()
      let drag = PumpedDrag<PropertyDragValue>.property(
        controller: context.controller, wallpaperID: "wp", property: "tint",
        sleep: context.sleeper.closure)
      let picker = ColorPickDriver(drag: drag, sleep: quiet.closure)

      picker.pick(red: 0x11 / 255, green: 0x22 / 255, blue: 0x33 / 255)
      await quiet.waitUntilPending()
      XCTAssertTrue(context.bridge.edits.isEmpty, "the colour is not chosen until it has paused")
      XCTAssertTrue(picker.isPicking)

      quiet.fireNext()
      for _ in 0..<40 { await Task.yield() }
      await context.settle()
      XCTAssertEqual(
        context.bridge.edits,
        [.init(propertyId: "tint", value: .colorRgb(red: 0x11 / 255, green: 0x22 / 255, blue: 0x33 / 255))],
        "exact components, not a rounded hex")
      XCTAssertFalse(picker.isPicking)
    }
  }

  func testABurstOfColoursIsOneDragThatSavesOnlyTheLastAndAClosedPanelSavesAtOnce() async throws {
    try await PanelPropertyContext.with { context in
      let quiet = ManualSleeper()
      let drag = PumpedDrag<PropertyDragValue>.property(
        controller: context.controller, wallpaperID: "wp", property: "tint",
        sleep: context.sleeper.closure)
      let picker = ColorPickDriver(drag: drag, sleep: quiet.closure)

      for level in [0.1, 0.2, 0.3] {
        picker.pick(red: level, green: level, blue: level)
        for _ in 0..<20 { await Task.yield() }
      }
      XCTAssertEqual(quiet.cancelledCount, 2, "each change starts the quiet period over")
      XCTAssertTrue(context.bridge.edits.isEmpty)

      picker.finish()  // the colour panel closed
      for _ in 0..<40 { await Task.yield() }
      await context.settle()
      XCTAssertEqual(
        context.bridge.edits, [.init(propertyId: "tint", value: .colorRgb(red: 0.3, green: 0.3, blue: 0.3))])
      XCTAssertFalse(picker.isPicking)

      picker.finish()
      await context.settle()
      XCTAssertEqual(context.bridge.edits.count, 1, "closing with nothing picked saves nothing")
    }
  }

  // MARK: Position

  func testAPositionDragPreviewsItsAxisAndTheKeyAndReleaseSaveOnlyThatAxis() async throws {
    let bridge = PositionRecordingBridge(noPointer: .init())
    let store = BridgeStore(bridge: bridge)
    bridge.options["scene"] = BridgeSnapshotFixtures.options(
      wallpaperId: "scene", kind: .projectScene,
      displayConfigurations: [
        InspectorRenderFixture.config("primary", "Studio", mode: .fill, factor: 1, pan: (0.2, 0.8))
      ])
    store.librarySnapshot.wallpapers = [
      BridgeWallpaperEntry(
        id: "scene", title: "Scene", kind: .projectScene, supported: true, active: false,
        selected: false, previewPath: nil)
    ]
    store.appSnapshot.selectedWallpaperId = "scene"
    store.wallpaperOptionsSnapshot = bridge.options["scene"]
    bridge.bundleProvider = { [store] in
      BridgeSnapshotBundle(
        app: store.appSnapshot, library: store.librarySnapshot, wallpaperOptions: nil,
        monitorInformation: store.monitorInformationSnapshot, settings: store.settingsSnapshot)
    }
    let panel = try PanelFixture(store: store, bridge: bridge, displayTitles: .renderer)
    defer { Task { await panel.shutdown() } }
    let sleeper = ManualSleeper()
    let vertical = PumpedDrag<Double>.position(
      controller: panel.controller, wallpaperID: "scene", display: "primary", axis: .vertical,
      sleep: sleeper.closure)

    vertical.update(0.31)
    for _ in 0..<60 { await Task.yield() }
    XCTAssertEqual(bridge.previews, [.init(panX: nil, panY: 0.31)], "only the dragged axis is shown")
    XCTAssertTrue(bridge.saves.isEmpty)

    await vertical.release(0.3).value
    XCTAssertEqual(bridge.saves, [.init(panX: nil, panY: 0.3)], "and only that axis is saved")

    let horizontal = PumpedDrag<Double>.position(
      controller: panel.controller, wallpaperID: "scene", display: "primary", axis: .horizontal,
      sleep: sleeper.closure)
    await horizontal.step(0.45).value
    XCTAssertEqual(bridge.saves.last, .init(panX: 0.45, panY: nil))
    XCTAssertEqual(bridge.previews.count, 1, "a key press previews nothing")
    XCTAssertNil(panel.controller.errors.message)
  }
}

/// A bridge that records the position previews and saves the way the engine would take them.
private final class PositionRecordingBridge: LayoutSnapshotBridge {
  struct Axes: Equatable {
    var panX: Double?
    var panY: Double?
  }
  @MainActor var previews: [Axes] = []
  @MainActor var saves: [Axes] = []

  override func previewDisplayPosition(
    wallpaperId: String, displayId: String, panX: Double?, panY: Double?
  ) async throws {
    await record(preview: Axes(panX: panX, panY: panY))
  }

  @MainActor private func record(preview: Axes) { previews.append(preview) }

  override func setDisplayPosition(
    wallpaperId: String, displayId: String, panX: Double?, panY: Double?
  ) async throws -> BridgeWallpaperMutationBundle {
    try await save(wallpaperId, Axes(panX: panX, panY: panY))
  }

  @MainActor private func save(_ id: String, _ axes: Axes) throws -> BridgeWallpaperMutationBundle {
    saves.append(axes)
    guard let bundle = bundleProvider?(), var options = options[id] else { throw CancellationError() }
    options.displayConfigurations = options.displayConfigurations.map { row in
      var row = row
      row.framing = BridgeFraming(
        panX: axes.panX ?? row.framing.panX, panY: axes.panY ?? row.framing.panY)
      return row
    }
    self.options[id] = options
    return BridgeWallpaperMutationBundle(
      app: bundle.app, library: bundle.library, wallpaperOptions: options,
      monitorInformation: bundle.monitorInformation, settings: bundle.settings)
  }
}
