import XCTest

@testable import WallpaperMachine

/// The inspector's Wallpaper Engine options section: which rows it lists and how, what its own
/// Restore all defaults offers, how an image filter's file name reads, and that the controller's
/// actions reach the bridge with typed option ids, are refused for a value no control offers, and
/// show a dragged slider without making it an edit. Whether a scene really draws the options is the
/// renderer's to test.
@MainActor
final class InspectorEngineOptionsTests: XCTestCase {
  private let english = PanelLocale(language: .english, region: nil)

  private func make(
    kind: BridgeWallpaperKind = .projectScene, engineOptions: BridgeEngineOptions?,
    supported: Bool = true, configure: (inout InspectorOptions.Inputs) -> Void = { _ in }
  ) -> InspectorOptions {
    var inputs = InspectorOptions.Inputs()
    inputs.locale = english
    configure(&inputs)
    return InspectorOptions.make(
      BridgeSnapshotFixtures.options(
        wallpaperId: "wp", kind: kind, supported: supported, engineOptions: engineOptions),
      inputs: inputs)
  }

  // MARK: Rows

  func testTheListedRowsAreTheEnabledOnesInWallpaperEnginesOrderWithTheAppsOwnNames() throws {
    let options = make(engineOptions: BridgeSnapshotFixtures.engineOptions(parallax: true))
    let rows = try XCTUnwrap(options.engineOptions)
    XCTAssertEqual(
      rows.map(\.option), [.colorEnabled, .imageFilter, .flipHorizontal, .mouseParallax, .playbackRate],
      "the colour sliders wait for their switch and the strength for a filter")
    XCTAssertEqual(
      rows.map(\.row.name),
      ["Color adjustments", "Image filter", "Flip horizontally", "Mouse parallax", "Playback rate"])
    XCTAssertEqual(rows.first?.row.id, "engine.colorEnabled")
    XCTAssertTrue(rows.allSatisfy { $0.row.label.markup == nil && $0.row.canRestoreDefault })
    XCTAssertEqual(rows.first?.row.control, .toggle(isOn: false))
    guard case .slider(let rate) = rows.last?.row.control else { return XCTFail("the rate is a slider") }
    XCTAssertEqual([rate.value, rate.minimum, rate.maximum, rate.step], [100, 10, 200, 1])
    guard case .choice(let selection, let choices) = rows[1].row.control else {
      return XCTFail("the image filter is a choice")
    }
    XCTAssertEqual(selection, .string(value: ""))
    XCTAssertEqual(choices.map(\.label), ["No filter", "Amber", "K23 b"])
    XCTAssertEqual(choices.map(\.value), [.string(value: ""), .string(value: "lutx32_amber"), .string(value: "k23_b")])
  }

  func testTurningTheColourSwitchOnAndChoosingAFilterListsTheirSliders() throws {
    let options = make(
      engineOptions: BridgeSnapshotFixtures.engineOptions(values: [
        .colorEnabled: .bool(value: true), .imageFilter: .string(value: "k23_b"),
        .brightness: .number(value: 70),
      ]))
    let rows = try XCTUnwrap(options.engineOptions)
    XCTAssertTrue(rows.map(\.option).contains(.brightness))
    XCTAssertTrue(rows.map(\.option).contains(.filterStrength))
    XCTAssertEqual(rows.count, 9)
    let brightness = try XCTUnwrap(rows.first { $0.option == .brightness })
    XCTAssertTrue(brightness.row.isModified)
    XCTAssertTrue(InspectorPolicy.engineOptionsOpenByDefault(options))
  }

  func testAWebPageHasNoSectionAndAFilterNoLongerInstalledShowsNoSelection() throws {
    XCTAssertNil(make(kind: .webpage, engineOptions: nil).engineOptions)
    let options = make(
      engineOptions: BridgeSnapshotFixtures.engineOptions(values: [.imageFilter: .string(value: "gone")]))
    let filter = try XCTUnwrap(options.engineOptions?.first { $0.option == .imageFilter })
    guard case .choice(let selection, _) = filter.row.control else { return XCTFail() }
    XCTAssertNil(selection, "a saved filter the assets no longer hold is shown as no selection")
    XCTAssertFalse(InspectorPolicy.engineOptionsOpenByDefault(make(engineOptions: BridgeSnapshotFixtures.engineOptions())))
  }

  func testAValueOnItsWayIsShownAndCountsAsUnsent() throws {
    let options = make(engineOptions: BridgeSnapshotFixtures.engineOptions()) {
      $0.pendingEngineValues = [.flipHorizontal: .bool(value: true)]
    }
    let flip = try XCTUnwrap(options.engineOptions?.first { $0.option == .flipHorizontal })
    XCTAssertEqual(flip.row.control, .toggle(isOn: true))
    XCTAssertTrue(flip.row.isModified)
    XCTAssertFalse(flip.row.isDirty)
    XCTAssertTrue(options.hasUnsentChanges)
  }

  // MARK: Restore all defaults

  func testTheSectionsRestoreAllCountsListedHiddenAndPendingValuesAndNothingElse() {
    XCTAssertFalse(make(engineOptions: BridgeSnapshotFixtures.engineOptions()).canRestoreAllEngineOptions)
    XCTAssertTrue(
      make(engineOptions: BridgeSnapshotFixtures.engineOptions(values: [.playbackRate: .number(value: 50)]))
        .canRestoreAllEngineOptions)
    // A colour slider moved, then the colour switch turned off: the value is hidden but saved.
    let hidden = make(
      engineOptions: BridgeSnapshotFixtures.engineOptions(values: [.contrast: .number(value: 20)]))
    XCTAssertTrue(hidden.engineHiddenModified)
    XCTAssertTrue(hidden.canRestoreAllEngineOptions)
    XCTAssertTrue(
      make(engineOptions: BridgeSnapshotFixtures.engineOptions()) {
        $0.pendingEngineValues = [.colorEnabled: .bool(value: true)]
      }.canRestoreAllEngineOptions)
    let modified = BridgeSnapshotFixtures.engineOptions(values: [.flipHorizontal: .bool(value: true)])
    XCTAssertFalse(make(engineOptions: modified) { $0.isLocked = true }.canRestoreAllEngineOptions)
    XCTAssertFalse(make(engineOptions: modified, supported: false).canRestoreAllEngineOptions)
    XCTAssertFalse(make(kind: .webpage, engineOptions: nil).canRestoreAllEngineOptions)
  }

  // MARK: Image filter names

  func testAnImageFiltersNameIsItsFileNameInWords() {
    XCTAssertEqual(InspectorOptions.imageFilterLabel("lutx32_daisy"), "Daisy")
    XCTAssertEqual(
      InspectorOptions.imageFilterLabel("80s_post-apocalyptic_action"), "80s post-apocalyptic action")
    XCTAssertEqual(InspectorOptions.imageFilterLabel("k23_b"), "K23 b")
    XCTAssertEqual(InspectorOptions.imageFilterLabel("LUTX16_Teal_Orange"), "Teal Orange")
    XCTAssertEqual(InspectorOptions.imageFilterLabel("lutxa_b"), "Lutxa b", "a prefix without digits stays")
  }

  // MARK: Controller actions

  private func withEngineOptions(
    _ engineOptions: BridgeEngineOptions = BridgeSnapshotFixtures.engineOptions(),
    _ body: (PanelPropertyContext) async throws -> Void
  ) async throws {
    try await PanelPropertyContext.with { context in
      context.bridge.options["wp"]?.engineOptions = engineOptions
      context.store.wallpaperOptionsSnapshot = context.bridge.options["wp"]
      try await body(context)
    }
  }

  func testCommittingAnOptionStagesItWithItsTypedIdAndRestoresFollow() async throws {
    try await withEngineOptions { context in
      try await context.controller.commitEngineOption("wp", option: .flipHorizontal, value: .bool(value: true))
      try await context.controller.commitEngineOption("wp", option: .playbackRate, value: .number(value: 150))
      try await context.controller.commitEngineOption(
        "wp", option: .imageFilter, value: .string(value: "lutx32_amber"))
      try await context.controller.restoreEngineOption("wp", option: .playbackRate)
      try await context.controller.restoreAllEngineOptions("wp")
      XCTAssertEqual(
        context.bridge.engineEdits,
        [
          "flipHorizontal bool(value: true)", "playbackRate number(value: 150.0)",
          "imageFilter string(value: \"lutx32_amber\")", "restore playbackRate", "restoreAll",
        ])
      XCTAssertNil(context.controller.pendingEngineOptionValues["wp"], "nothing is left on its way")
      XCTAssertEqual(context.bridge.options["wp"]?.dirty, true, "an edit waits for Apply")
    }
  }

  func testAValueNoControlOffersIsRefusedBeforeTheBridgeHearsOfIt() async throws {
    try await withEngineOptions { context in
      let refused: [(BridgeEngineOptionId, BridgePropertyValue)] = [
        (.brightness, .number(value: 60)),  // not listed while the colour switch is off
        (.playbackRate, .number(value: 500)),
        (.playbackRate, .number(value: .nan)),
        (.flipHorizontal, .number(value: 1)),
        (.imageFilter, .string(value: "teal")),
        (.mouseParallax, .bool(value: false)),  // this scene does not offer it
      ]
      for (option, value) in refused {
        await self.assertInspectorInvalidValue("\(option) \(value)") {
          try await context.controller.commitEngineOption("wp", option: option, value: value)
        }
      }
      XCTAssertTrue(context.bridge.engineEdits.isEmpty)
    }
  }

  func testADraggedSliderIsShownOnTheDesktopWithoutBecomingAnEdit() async throws {
    try await withEngineOptions { context in
      context.switchOn()
      try await context.controller.previewEngineOption("wp", option: .playbackRate, value: .number(value: 40))
      await context.settle()
      XCTAssertEqual(
        context.bridge.previews.last,
        .init(
          wallpaperID: "wp", show: true,
          pendingEngineOptions: [.init(option: .playbackRate, value: .number(value: 40))]))
      XCTAssertTrue(context.bridge.engineEdits.isEmpty, "a step is not an edit")
      XCTAssertEqual(
        context.store.editorState.engineOptionPreviews(wallpaperID: "wp"),
        [.init(option: .playbackRate, value: .number(value: 40))])

      await self.assertInspectorInvalidValue("a switch step") {
        try await context.controller.previewEngineOption("wp", option: .flipHorizontal, value: .bool(value: true))
      }

      // The release commits through the drag driver, and the step it ends is no longer shown.
      try await context.controller.commitEngineOption("wp", option: .playbackRate, value: .number(value: 45))
      XCTAssertTrue(context.store.editorState.engineOptionPreviews(wallpaperID: "wp").isEmpty)
      XCTAssertEqual(context.bridge.engineEdits, ["playbackRate number(value: 45.0)"])
    }
  }

  func testAPumpedDragOfAnOptionPreviewsEachStepAndCommitsOnRelease() async throws {
    try await withEngineOptions { context in
      let sleeper = ManualSleeper()
      let drag = PumpedDrag<PropertyDragValue>.engineOption(
        controller: context.controller, wallpaperID: "wp", option: .playbackRate, sleep: sleeper.closure)
      drag.update(.number(120))
      await context.settle()
      XCTAssertEqual(
        context.store.editorState.engineOptionPreviews(wallpaperID: "wp"),
        [.init(option: .playbackRate, value: .number(value: 120))])
      await drag.release(.number(130)).value
      for _ in 0..<4 {
        await context.settle()
        if sleeper.finishWaits() == 0 { break }
      }
      await context.settle()
      XCTAssertEqual(context.bridge.engineEdits.last, "playbackRate number(value: 130.0)")
    }
  }
}
