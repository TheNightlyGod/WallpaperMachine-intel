import AppKit
import XCTest

@testable import WallpaperMachine

/// What the inspector's buttons and fields do through the controller, the way the views call it: the
/// preview with typed text, Restore all, a switch that saves without a step, and the small rules the
/// views draw from (sections that open by themselves, the words under a file or folder, the glyphs).
@MainActor
final class InspectorFlowTests: InspectorTestCase {
  // MARK: Preview

  /// Port of `ControlPanelPreviewTests.testPreviewUsesSelectedWallpaperAndUnappliedText...`: the
  /// preview opens the selected wallpaper on the target display with the text typed into a property
  /// and not committed, and changes nothing on the desktop.
  func testPreviewOpensTheWallpaperWithTheTextTypedAndNotYetCommittedAndTouchesNothing() async throws {
    try await PanelPropertyContext.with { context in
      let store = context.store
      var previews: [WallpaperPreviewSession.Selection] = []
      store.openPreview = { previews.append($0) }
      let before = store.appSnapshot
      let controller = context.controller
      XCTAssertTrue(controller.previewAvailable)

      controller.setPropertyText("Draft <b>text</b>", property: "note", in: "wp")
      await controller.launch(PanelActionCoordinator.key("previewWallpaper", id: "wp")) {
        try await controller.previewWithTypedText("wp")
      }.value

      XCTAssertEqual(
        previews,
        [.init(wallpaperID: "wp", displayID: "primary", textOverrides: ["note": "Draft <b>text</b>"])])
      XCTAssertEqual(store.appSnapshot, before, "a preview changes no selection")
      XCTAssertTrue(store.history.entries.isEmpty, "and records no history")
      XCTAssertEqual(
        controller.propertyTextDraft("note", in: "wp"), "Draft <b>text</b>",
        "the text stays in its field")
      XCTAssertNil(controller.errors.message)
    }
  }

  func testPreviewWithNothingTypedSendsNoTextAndOtherWallpapersTextIsNotCarried() async throws {
    try await PanelPropertyContext.with { context in
      var previews: [WallpaperPreviewSession.Selection] = []
      context.store.openPreview = { previews.append($0) }
      let controller = context.controller
      controller.setPropertyText("for wp2", property: "note", in: "wp2")
      try await controller.previewWithTypedText("wp")
      XCTAssertEqual(previews.first?.textOverrides, [:])
    }
  }

  // MARK: Restore all and switches

  /// Port of `ControlPanelRestoreAllTests.testRestoreAllDropsUnsentText...`, the button's path:
  /// unsent text makes Restore all available and Apply changes possible, and the button throws it away.
  func testRestoreAllIsAvailableForUnsentTextAndDropsIt() async throws {
    try await PanelPropertyContext.with { context in
      let controller = context.controller
      XCTAssertEqual(controller.inspectorOptions(for: "wp")?.canRestoreAll, false, "nothing differs")
      controller.setPropertyText("typed", property: "note", in: "wp")
      let typed = try XCTUnwrap(controller.inspectorOptions(for: "wp"))
      XCTAssertTrue(typed.canRestoreAll)
      XCTAssertTrue(typed.canApply && typed.canRevert, "typed text is an unapplied change")

      await controller.launch(InspectorAction.restoreAll("wp")) {
        try await controller.restoreAllProperties("wp")
      }.value
      XCTAssertNil(controller.propertyTextDraft("note", in: "wp"), "the draft is dropped first")
    }
  }

  /// Port of `testOtherControlsOfAPropertySaveWithoutShowingAStep`: a switch is saved by its value,
  /// with no drag pump and no step on the previews.
  func testASwitchSavesItsValueWithoutAStep() async throws {
    try await PanelPropertyContext.with { context in
      context.switchOn()
      let controller = context.controller
      await controller.launch(InspectorAction.property("wp", "mode"), policy: .latestWins) {
        try await controller.commitProperty("wp", property: "mode", value: .bool(value: true))
      }.value
      XCTAssertEqual(context.bridge.edits, [.init(propertyId: "mode", value: .bool(value: true))])
      XCTAssertTrue(context.bridge.previews.allSatisfy { $0.pending.isEmpty }, "no step is shown")
    }
  }

  func testTheRowShowsWhatWasJustChosenWhileItsEditWaitsAndTheBridgesValueAfterARefusal() async throws {
    try await PanelPropertyContext.with { context in
      let controller = context.controller
      context.bridge.editFailure = InspectorTestRefusal()
      await controller.launch(InspectorAction.property("wp", "mode")) {
        try await controller.commitProperty("wp", property: "mode", value: .bool(value: true))
      }.value
      let row = try XCTUnwrap(
        controller.inspectorOptions(for: "wp")?.properties.first { $0.id == "mode" })
      XCTAssertEqual(row.control, .toggle(isOn: false), "a refused edit leaves no stale value on show")
      XCTAssertFalse(row.isModified)
      XCTAssertNotNil(controller.errors.message, "and the refusal reaches the banner")
    }
  }

  // MARK: Words and rules the views draw from

  func testOnlyASupportedSceneOrVideoOffersAPositionAndOnlySceneAndWebOfferMedia() {
    func options(_ kind: BridgeWallpaperKind, supported: Bool = true) -> InspectorOptions {
      var inputs = InspectorOptions.Inputs()
      inputs.locale = PanelLocale(language: .english, region: nil)
      return InspectorOptions.make(
        BridgeSnapshotFixtures.options(kind: kind, supported: supported), inputs: inputs)
    }
    XCTAssertTrue(options(.projectScene).offersPosition)
    XCTAssertTrue(options(.video).offersPosition)
    XCTAssertFalse(options(.webpage).offersPosition, "a web page always fills its window")
    XCTAssertFalse(options(.unknown).offersPosition)
    XCTAssertFalse(options(.projectScene, supported: false).offersPosition)
    XCTAssertTrue(options(.projectScene).offersMediaIntegration)
    XCTAssertTrue(options(.webpage).offersMediaIntegration)
    XCTAssertFalse(options(.video).offersMediaIntegration)
  }

  func testSectionsOpenByThemselvesOnlyWhenThereIsSomethingInThem() throws {
    var inputs = InspectorOptions.Inputs()
    inputs.locale = PanelLocale(language: .english, region: nil)
    let withDisplays = InspectorOptions.make(
      BridgeSnapshotFixtures.options(
        displayConfigurations: [
          InspectorRenderFixture.config("primary", "Studio", mode: .fill, factor: 1, pan: (0.5, 0.5))
        ]), inputs: inputs)
    let without = InspectorOptions.make(BridgeSnapshotFixtures.options(), inputs: inputs)
    XCTAssertTrue(InspectorPolicy.displaysOpenByDefault(withDisplays))
    XCTAssertFalse(InspectorPolicy.displaysOpenByDefault(without))

    let rows = [
      CollectionRow(id: "c1", name: "Calm", wallpaperIDs: ["a"]),
      CollectionRow(id: "c2", name: "Loud", wallpaperIDs: []),
    ]
    XCTAssertTrue(InspectorPolicy.collectionsOpenByDefault(rows, wallpaperID: "a"))
    XCTAssertFalse(InspectorPolicy.collectionsOpenByDefault(rows, wallpaperID: "b"))
    XCTAssertFalse(InspectorPolicy.collectionsOpenByDefault([], wallpaperID: "a"))
  }

  func testTheAppsOwnWordsAreAPlainParagraphAndAnAuthorsMarkupIsADocument() throws {
    let options = InspectorOptions.make(
      BridgeSnapshotFixtures.options(properties: [
        BridgeSnapshotFixtures.textProperty(id: "token", labelHtml: "ui_editor_properties_size"),
        BridgeSnapshotFixtures.textProperty(id: "rich", labelHtml: "<b>Hello</b> <i>there</i>"),
      ]),
      inputs: {
        var inputs = InspectorOptions.Inputs()
        inputs.locale = PanelLocale(language: .english, region: nil)
        return inputs
      }())
    let token = try XCTUnwrap(options.properties.first { $0.id == "token" })
    XCTAssertNil(token.label.markup, "words from the app have no markup to draw")
    XCTAssertEqual(InspectorPolicy.labelDocument(for: token).plainText, "Size")
    let rich = try XCTUnwrap(options.properties.first { $0.id == "rich" })
    guard case .paragraph(let paragraph)? = InspectorPolicy.labelDocument(for: rich).blocks.first else {
      return XCTFail("the author's label is a document")
    }
    XCTAssertEqual(paragraph.runs.first?.isBold, true)
    XCTAssertEqual(paragraph.plainText, "Hello there")
  }

  func testWhatTheHostReportsIsNamedForTheDisplayAndEscapedReasonsStayText() {
    func row(_ phase: HostWallpaperState.Phase) -> HostStateRow {
      HostStateRow(
        id: "web:1", wallpaperID: "a", displayID: 1, displayTitle: "Studio <b>Display</b>", kind: .web,
        phase: phase, message: nil, canRetry: false)
    }
    XCTAssertEqual(
      InspectorWording.hostStatus(row(.failed)), "Studio <b>Display</b> · Wallpaper could not load")
    XCTAssertEqual(
      InspectorWording.hostStatus(row(.ready)), "Studio <b>Display</b> · Wallpaper content is ready")
    XCTAssertEqual(
      InspectorWording.hostStatus(row(.loading)), "Studio <b>Display</b> · Loading wallpaper content…")
  }

  // MARK: Under a file or folder

  private func path(
    name: String? = "loop.mp4", types: [String] = ["mp4", "webm"], managed: Bool = true,
    missing: Bool = false, source: String? = nil, error: String? = nil
  ) -> InspectorOptions.PropertyRow.PathState {
    .init(
      name: name, acceptedTypes: types, error: error, isManaged: managed, isMissing: missing,
      sourcePath: source)
  }

  func testAFileSaysWhatItAcceptsAndWhereItLives() {
    XCTAssertEqual(
      AssetNotes.lines(state: path(), folder: nil),
      [
        "Accepts mp4, webm.",
        "Copied into this app’s managed folder, so it survives cache cleans and wallpaper updates.",
      ])
    XCTAssertEqual(
      AssetNotes.lines(state: path(managed: false, source: "/Users/me/Movies/loop.mp4"), folder: nil).last,
      "Used in place from /Users/me/Movies/loop.mp4. Moving or deleting it there breaks the wallpaper.")
    XCTAssertEqual(
      AssetNotes.lines(state: path(managed: false), folder: nil).last,
      "Used in place from where you chose it. Moving or deleting it there breaks the wallpaper.")
    XCTAssertEqual(
      AssetNotes.lines(state: path(name: nil), folder: nil), ["Accepts mp4, webm."],
      "nothing chosen: no location")
  }

  func testAMissingFileDropsTheLocationLineSoItDoesNotContradictTheAlert() {
    XCTAssertEqual(
      AssetNotes.lines(state: path(managed: false, missing: true, source: "/x/y.mp4"), folder: nil),
      ["Accepts mp4, webm."])
  }

  func testAFolderSaysHowManyFilesItHoldsAndHowTheWallpaperGetsThem() {
    func folder(
      count: Int?, limit: Int = 1_000, truncated: Bool = false,
      delivery: InspectorOptions.PropertyRow.Folder.Delivery = .wholeList
    ) -> InspectorOptions.PropertyRow.Folder {
      .init(delivery: delivery, fileCount: count, fileLimit: limit, isTruncated: truncated)
    }
    let state = path(name: "photos", types: ["jpg", "png"])
    XCTAssertEqual(
      AssetNotes.lines(state: state, folder: folder(count: 2)),
      [
        "Uses jpg, png files from the chosen folder.", "2 matching files in this folder.",
        "The wallpaper receives the whole list of files.",
        "Copied into this app’s managed folder, so it survives cache cleans and wallpaper updates.",
      ])
    XCTAssertTrue(
      AssetNotes.lines(state: state, folder: folder(count: 1)).contains("1 matching file in this folder."))
    XCTAssertTrue(
      AssetNotes.lines(state: state, folder: folder(count: 0)).contains("0 matching files in this folder."))
    let limit = 1_000.formatted(.number.locale(PanelLocale.shared.locale))
    XCTAssertTrue(
      AssetNotes.lines(state: state, folder: folder(count: 1_000, limit: 1_000, truncated: true))
        .contains("More than \(limit) files match; only the first \(limit) are used."),
      "numbers follow the panel's locale")
    XCTAssertTrue(
      AssetNotes.lines(state: state, folder: folder(count: nil))
        .contains("This folder could not be read. Choose it again, or pick another."),
      "an unreadable folder is not an empty one")
    XCTAssertTrue(
      AssetNotes.lines(state: state, folder: folder(count: 3, delivery: .onDemand))
        .contains("The wallpaper picks files from the folder itself."))
    XCTAssertEqual(
      AssetNotes.lines(state: path(name: nil, types: ["png"]), folder: folder(count: nil)),
      ["Uses png files from the chosen folder."], "nothing chosen: no counts")
  }

  func testAPathCarryingMarkupIsKeptAsTheTextItIs() {
    let hostile = "/tmp/<img src=x onerror=alert(1)>.mp4"
    let lines = AssetNotes.lines(state: path(managed: false, source: hostile), folder: nil)
    XCTAssertTrue(lines.last?.contains(hostile) == true, "the note carries the path verbatim; the view draws text")
  }

  // MARK: Symbols

  func testEverySymbolTheInspectorDrawsIsInTheSymbolSet() {
    let dynamic =
      [WallpaperCompatibilityCheck.Status.ok, .warning, .unavailable, .unknown].map(InspectorGlyphs.compatibility)
      + [InspectorWording.LetterboxGlyph.ok, .info, .unclear, .failed].map(InspectorGlyphs.letterbox)
    let fixed = [
      "photo", "heart", "heart.fill", "ellipsis", "play.fill", "arrow.clockwise", "eye", "folder",
      "display.2", "text.badge.plus", "text.badge.minus", "arrow.triangle.2.circlepath",
      "exclamationmark.bubble", "trash", "arrow.down.circle", "arrow.down.circle.fill",
      "checkmark.shield", "hourglass", "arrow.up.right.square", "minus.circle", "plus",
      "arrow.counterclockwise", "slider.horizontal.3", "chevron.right", "info.circle.fill",
      "exclamationmark.triangle.fill", "exclamationmark.octagon.fill", "checkmark.circle.fill",
    ]
    for name in dynamic + fixed {
      XCTAssertNotNil(NSImage(systemSymbolName: name, accessibilityDescription: nil), "\(name) is not an SF Symbol")
    }
  }
}
