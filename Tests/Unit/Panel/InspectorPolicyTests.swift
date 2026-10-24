import XCTest

@testable import WallpaperMachine

/// The base of the inspector's suites: the panel's language is pinned to English, so the sentences
/// the inspector words with `L()` can be asserted whatever language the Mac running the tests uses.
@MainActor
class InspectorTestCase: PanelTestCase {
  override func setUp() async throws {
    try await super.setUp()
    PanelLocale.shared.bind(to: .english())
  }

  override func tearDown() async throws {
    PanelLocale.shared.bind(to: .testHost)
    try await super.tearDown()
  }

  /// An installed row, with only what the case at hand cares about.
  func row(
    _ id: String = "wp", title: String = "Aurora", kind: LibraryRow.Kind = .scene,
    supported: Bool = true, size: Int64? = nil, energy: LibraryEnergyRating? = nil
  ) -> LibraryRow {
    LibraryRow(
      id: id, title: title, kind: kind, previewFile: nil, cover: .none, canAnimate: false,
      isActive: false, isSupported: supported, tags: [], isApproved: false, size: size,
      addedAt: nil, energy: energy, isUpdateAvailable: false, updatedAt: nil)
  }

  func target(
    enabled: Bool = true, mirror: Bool = false, showing wallpaper: String? = nil
  ) -> TargetDisplayOption {
    TargetDisplayOption(
      id: "primary", title: "Studio", isEnabled: enabled, isMirror: mirror, wallpaperID: wallpaper)
  }
}

/// Which controls the Installed inspector offers and when they are enabled: the rules of the page's
/// `renderInspector`, as functions of the wallpaper, the target display and the downloads.
@MainActor
final class InspectorPolicyTests: InspectorTestCase {
  func testApplyNeedsAKnownTypeAndATargetThatIsEnabledAndNotAMirror() {
    XCTAssertTrue(InspectorPolicy.canActivate(kind: .scene, target: target()))
    XCTAssertTrue(InspectorPolicy.canActivate(kind: .video, target: target()))
    XCTAssertTrue(InspectorPolicy.canActivate(kind: .web, target: target()))
    XCTAssertFalse(InspectorPolicy.canActivate(kind: .unknown, target: target()))
    XCTAssertFalse(InspectorPolicy.canActivate(kind: .scene, target: target(enabled: false)))
    XCTAssertFalse(InspectorPolicy.canActivate(kind: .scene, target: target(mirror: true)))
    XCTAssertFalse(InspectorPolicy.canActivate(kind: .scene, target: nil), "no display to apply to")
    XCTAssertTrue(
      InspectorPolicy.canActivate(kind: .scene, target: target()),
      "whether the Mac can render it is the wallpaper's own notice, not part of the rule")
  }

  func testTheButtonRestartsWhatTheTargetShowsAndOtherwiseApplies() {
    XCTAssertTrue(InspectorPolicy.reapplies("a", target: target(showing: "a")))
    XCTAssertFalse(InspectorPolicy.reapplies("a", target: target(showing: "b")))
    XCTAssertFalse(InspectorPolicy.reapplies("a", target: target()))
    XCTAssertFalse(InspectorPolicy.reapplies("a", target: nil))
  }

  /// Port of `ControlPanelDisplayLayoutTests.testInspectorAppliesToEveryDisplay...` (offered with two
  /// displays that can take a wallpaper, not with one; nothing to do once all show it).
  func testApplyToAllDisplaysNeedsTwoSharedDisplaysAndAWallpaperThatCanRun() {
    XCTAssertTrue(InspectorPolicy.offersApplyToAll(row(), sharedDisplayCount: 2))
    XCTAssertTrue(InspectorPolicy.offersApplyToAll(row(), sharedDisplayCount: 3))
    XCTAssertFalse(InspectorPolicy.offersApplyToAll(row(), sharedDisplayCount: 1))
    XCTAssertFalse(InspectorPolicy.offersApplyToAll(row(), sharedDisplayCount: 0))
    XCTAssertFalse(InspectorPolicy.offersApplyToAll(row(supported: false), sharedDisplayCount: 2))
    XCTAssertFalse(InspectorPolicy.offersApplyToAll(row(kind: .unknown), sharedDisplayCount: 2))

    XCTAssertFalse(
      InspectorPolicy.appliesEverywhereAlready("a", sharedDisplayWallpapers: ["a", "b"]))
    XCTAssertFalse(InspectorPolicy.appliesEverywhereAlready("a", sharedDisplayWallpapers: ["a", nil]))
    XCTAssertTrue(
      InspectorPolicy.appliesEverywhereAlready("a", sharedDisplayWallpapers: ["a", "a"]),
      "even for the wallpaper one display shows, the button is offered until every display does")
    XCTAssertFalse(InspectorPolicy.appliesEverywhereAlready("a", sharedDisplayWallpapers: []))
  }

  func testTheLivePreviewNeedsTheWindowAndAKnownType() {
    XCTAssertTrue(InspectorPolicy.offersPreview(kind: .video, previewAvailable: true))
    XCTAssertFalse(InspectorPolicy.offersPreview(kind: .video, previewAvailable: false))
    XCTAssertFalse(InspectorPolicy.offersPreview(kind: .unknown, previewAvailable: true))
  }

  func testThePlaylistButtonEditsTheTargetsOwnListOfAWallpaperThatCanRender() {
    let wallpaper = row("a")
    XCTAssertEqual(
      InspectorPolicy.playlistToggle(wallpaper, target: target(), listedIDs: ["b"]),
      .enabled(isListed: false))
    XCTAssertEqual(
      InspectorPolicy.playlistToggle(wallpaper, target: target(), listedIDs: ["a", "b"]),
      .enabled(isListed: true))
    XCTAssertEqual(
      InspectorPolicy.playlistToggle(wallpaper, target: target(mirror: true), listedIDs: ["a"]),
      .disabled(isListed: true), "a mirror has no list of its own to change")
    XCTAssertEqual(
      InspectorPolicy.playlistToggle(wallpaper, target: target(enabled: false), listedIDs: []),
      .disabled(isListed: false))
    XCTAssertEqual(
      InspectorPolicy.playlistToggle(wallpaper, target: nil, listedIDs: []), .disabled(isListed: false))
    XCTAssertEqual(
      InspectorPolicy.playlistToggle(row("a", supported: false), target: target(), listedIDs: []),
      .hidden)
  }

  /// Port of `ControlPanelLibraryTests.testReinstallIsOfferedOnlyForAnInstalledWorkshopWallpaper...`
  /// (the page's `canReinstall`): a Workshop id of a wallpaper that can run on macOS, nothing
  /// downloading and nothing waiting for setup.
  func testReinstallIsOfferedOnlyForAWorkshopWallpaperThatCanRunWithNoDownloadUnderWay() {
    func offered(
      _ id: String, kind: LibraryRow.Kind = .video, downloading: Bool = false, waiting: Bool = false
    ) -> Bool {
      InspectorPolicy.canReinstall(
        row(id, kind: kind), hasPendingDownload: downloading, hasRequest: waiting)
    }
    XCTAssertTrue(offered("2819450811"))
    XCTAssertTrue(offered("2819450811", kind: .scene))
    XCTAssertFalse(offered("2819450811", downloading: true), "a download is under way or waiting its turn")
    XCTAssertFalse(offered("2819450811", waiting: true), "a request waits for setup")
    XCTAssertFalse(
      offered("2819450811", kind: .unknown),
      "an Application wallpaper (a type the renderer cannot name) cannot run on macOS")
    XCTAssertFalse(offered("image-a.png"))
    XCTAssertFalse(offered("pixiv-1-p0"))
    XCTAssertFalse(offered("12a"))
    XCTAssertFalse(offered(""))
    XCTAssertFalse(offered("٣٤٥"), "only ASCII digits are a Workshop number")
  }

  func testTheControllerOffersReinstallOnlyForAnInstalledWallpaperThatCanRun() async throws {
    try await withPanel { panel in
      let controller = panel.controller
      panel.store.librarySnapshot.wallpapers = [
        ("2819450811", BridgeWallpaperKind.video, true), ("local-folder", .projectScene, true),
        ("3000000001", .unknown, false),
      ].map {
        BridgeWallpaperEntry(
          id: $0.0, title: $0.0, kind: $0.1, supported: $0.2, active: false, selected: false,
          previewPath: nil)
      }
      XCTAssertTrue(controller.canReinstall("2819450811"))
      XCTAssertFalse(controller.canReinstall("local-folder"), "only the Workshop has a copy")
      XCTAssertFalse(
        controller.canReinstall("3000000001"), "an installed Workshop Application cannot run on macOS")
      XCTAssertFalse(controller.canReinstall("2819450812"), "a wallpaper that is not installed")
    }
  }

  // MARK: Problem report

  /// Port of `ControlPanelLibraryTests.testInspectorReportLinkCarriesRendererAndApplyFailure...` (the
  /// offer): a wallpaper that can run gets the plain report, one that cannot gets none, and a
  /// failure takes the plain link's place with a report of its own.
  func testOnlyAWallpaperThatCanRunGetsThePlainReportAndAFailureCarriesItsOwn() {
    for kind in [LibraryRow.Kind.scene, .video, .web] {
      XCTAssertEqual(
        InspectorPolicy.issueReport(for: row(kind: kind), failure: nil, sceneResourcesMissing: false),
        .plain, "\(kind)")
    }
    XCTAssertEqual(
      InspectorPolicy.issueReport(
        for: row(kind: .unknown, supported: false), failure: nil, sceneResourcesMissing: false),
      .none, "an Application wallpaper cannot run, so there is nothing to report but its type")
    XCTAssertEqual(
      InspectorPolicy.issueReport(
        for: row(kind: .scene), failure: "The scene file is damaged.", sceneResourcesMissing: false),
      .failure("The scene file is damaged."))
  }

  /// A scene waiting for the shared resources is setup to finish, not a problem to
  /// report, so no report sits beside the notice that offers them, failure or not.
  func testASceneWaitingForTheSharedResourcesOffersNoReport() {
    for failure in [nil, "Shared resources are not installed."] {
      XCTAssertEqual(
        InspectorPolicy.issueReport(for: row(kind: .scene), failure: failure, sceneResourcesMissing: true),
        .none)
    }
    XCTAssertEqual(
      InspectorPolicy.issueReport(for: row(kind: .video), failure: nil, sceneResourcesMissing: true),
      .plain, "other types do not need them")
  }

  func testTheMenusReportCarriesTheFailureAndNoneIsOfferedForAWallpaperThatCannotRun() async throws {
    try await withPanel { panel in
      let controller = panel.controller
      panel.store.librarySnapshot.wallpapers = [
        BridgeWallpaperEntry(
          id: "ghost", title: "Ghost", kind: .projectScene, supported: true, active: false,
          selected: false, previewPath: nil),
        BridgeWallpaperEntry(
          id: "tool", title: "Tool", kind: .unknown, supported: false, active: false,
          selected: false, previewPath: nil),
      ]
      func details(_ url: URL?) throws -> String {
        let components = try XCTUnwrap(
          URLComponents(url: XCTUnwrap(url), resolvingAgainstBaseURL: false))
        return try XCTUnwrap(components.queryItems?.first { $0.name == "app-details" }?.value)
      }
      panel.sceneAssets.available = true
      panel.workshop.refreshSceneAssetsReadiness()
      let ghost = try XCTUnwrap(controller.libraryRow(id: "ghost"))
      let tool = try XCTUnwrap(controller.libraryRow(id: "tool"))

      XCTAssertNil(controller.inspectorIssueReportURL(for: tool))
      XCTAssertFalse(try details(controller.inspectorIssueReportURL(for: ghost)).contains("**Error:**"))

      controller.activationFailures["ghost"] = "The scene file is damaged."
      XCTAssertTrue(
        try details(controller.inspectorIssueReportURL(for: ghost))
          .contains("**Error:** The scene file is damaged."), "the menu's report carries the failure")
      XCTAssertEqual(
        controller.inspectorIssueReport(for: ghost),
        .failure("The scene file is damaged."), "so the plain link under the type sentence steps aside")

      panel.sceneAssets.available = false
      panel.workshop.refreshSceneAssetsReadiness()
      XCTAssertNil(
        controller.inspectorIssueReportURL(for: ghost),
        "a scene waiting for the shared resources gets their notice instead")
    }
  }

  // MARK: Trash

  func testTheTrashWaitsOnlyForItsOwnDeleteAndNotForAnotherCommand() async throws {
    try await withPanel { panel in
      let controller = panel.controller
      var release: CheckedContinuation<Void, Never>?
      let other = controller.launch("activate:other") {
        try await controller.run(.queued) {
          await withCheckedContinuation { release = $0 }
        }
      }
      try await panel.waitUntil(timeout: 5) { release != nil }
      XCTAssertTrue(controller.isStoreBusy, "a command is running")
      XCTAssertTrue(controller.canMoveToTrash("wp"), "and the Trash does not wait for it")
      release?.resume()
      await other.value

      release = nil
      let deleting = controller.launch(PanelActionCoordinator.key("delete", id: "wp")) {
        await withCheckedContinuation { release = $0 }
      }
      try await panel.waitUntil(timeout: 5) { release != nil }
      XCTAssertFalse(controller.canMoveToTrash("wp"), "its own delete under way")
      XCTAssertTrue(controller.canMoveToTrash("another"))
      release?.resume()
      await deleting.value
      XCTAssertTrue(controller.canMoveToTrash("wp"))
    }
  }

  // MARK: Frame rate

  func testADisplayTheNativePlayerDrawsOnHasNoFrameRateToSet() {
    let snapshot = BridgeSnapshotFixtures.options(
      wallpaperId: "clip", kind: .video,
      displayConfigurations: [
        InspectorRenderFixture.config("primary", "Studio Display (1 - Primary)", mode: .fill, factor: 1, pan: (0.5, 0.5)),
        InspectorRenderFixture.config("second", "LG UltraFine (2 - Secondary)", mode: .fill, factor: 1, pan: (0.5, 0.5)),
      ])
    var inputs = InspectorOptions.Inputs()
    inputs.nativePlayerDisplays = [1]
    let displays = InspectorOptions.make(snapshot, inputs: inputs).displays
    XCTAssertEqual(
      displays.map(InspectorPolicy.offersFrameRate(for:)), [false, true],
      "a clip plays at its own rate on the native player; another display of it keeps the row")
  }

  func testFitWithBlurredBackdropIsOfferedWhereAScalingModeMovesThePicture() {
    let configurations = [
      InspectorRenderFixture.config("primary", "Studio Display (1 - Primary)", mode: .fill, factor: 1, pan: (0.5, 0.5)),
      InspectorRenderFixture.config("second", "LG UltraFine (2 - Secondary)", mode: .matchBlurred, factor: 1, pan: (0.5, 0.5)),
    ]
    for kind in [BridgeWallpaperKind.projectScene, .video] {
      let options = InspectorOptions.make(
        BridgeSnapshotFixtures.options(wallpaperId: "w", kind: kind, displayConfigurations: configurations))
      XCTAssertEqual(
        options.displays.map { InspectorPolicy.offersBlurredFit(options, display: $0) }, [true, true], "\(kind)")
    }
    // A web page fills its window whatever the mode; a display already set to it keeps it shown.
    let web = InspectorOptions.make(
      BridgeSnapshotFixtures.options(wallpaperId: "w", kind: .webpage, displayConfigurations: configurations))
    XCTAssertEqual(web.displays.map { InspectorPolicy.offersBlurredFit(web, display: $0) }, [false, true])
  }

  func testOnlyANativelyPlayedVideoWithABlurredBackdropIsToldItsBarsStayBlack() {
    let snapshot = BridgeSnapshotFixtures.options(
      wallpaperId: "clip", kind: .video,
      displayConfigurations: [
        InspectorRenderFixture.config("primary", "Studio Display (1 - Primary)", mode: .matchBlurred, factor: 1, pan: (0.5, 0.5)),
        InspectorRenderFixture.config("second", "LG UltraFine (2 - Secondary)", mode: .matchBlurred, factor: 1, pan: (0.5, 0.5)),
        InspectorRenderFixture.config("third", "Built-in (3 - Secondary)", mode: .match, factor: 1, pan: (0.5, 0.5)),
      ])
    var inputs = InspectorOptions.Inputs()
    inputs.nativePlayerDisplays = [1, 3]
    let displays = InspectorOptions.make(snapshot, inputs: inputs).displays
    XCTAssertEqual(displays.map(InspectorPolicy.blurredFitNote(for:)), [.nativePlayer, .none, .none])
  }

  func testAStillTheAppPackagedIsToldByItsIdAndTheArtworkIdIsRead() {
    XCTAssertTrue(InspectorPolicy.isPackagedStill("pixiv-12345-p0"))
    XCTAssertTrue(InspectorPolicy.isPackagedStill("image-3F.png"))
    XCTAssertFalse(InspectorPolicy.isPackagedStill("2819450811"))
    XCTAssertEqual(InspectorPolicy.pixivArtworkID(of: "pixiv-12345-p0"), "12345")
    XCTAssertEqual(InspectorPolicy.pixivArtworkID(of: "pixiv-987-p12"), "987")
    XCTAssertNil(InspectorPolicy.pixivArtworkID(of: "pixiv-12345"))
    XCTAssertNil(InspectorPolicy.pixivArtworkID(of: "pixiv-x-p1"))
    XCTAssertNil(InspectorPolicy.pixivArtworkID(of: "pixiv-1-p"))
    XCTAssertNil(InspectorPolicy.pixivArtworkID(of: "image-a.png"))
  }

  func testTheSentenceUnderTheHeaderFollowsTheIdThenTheType() {
    XCTAssertEqual(InspectorPolicy.kindNote(for: row("pixiv-1-p0", kind: .web)), .pixivStill)
    XCTAssertEqual(InspectorPolicy.kindNote(for: row("image-a.png", kind: .web)), .importedStill)
    XCTAssertEqual(InspectorPolicy.kindNote(for: row("1", kind: .scene)), .scene)
    XCTAssertEqual(InspectorPolicy.kindNote(for: row("1", kind: .video)), .video)
    XCTAssertEqual(InspectorPolicy.kindNote(for: row("1", kind: .web)), .web)
    XCTAssertEqual(InspectorPolicy.kindNote(for: row("1", kind: .unknown)), .unsupported)
  }

  // MARK: Properties

  private func options(_ properties: [BridgePropertyDescriptor]) -> InspectorOptions {
    var inputs = InspectorOptions.Inputs()
    inputs.locale = PanelLocale(language: .english, region: nil)
    return InspectorOptions.make(
      BridgeSnapshotFixtures.options(kind: .projectScene, properties: properties), inputs: inputs)
  }

  private func property(
    _ id: String, _ kind: BridgePropertyKind, label: String, value: BridgePropertyValue = .empty
  ) -> BridgePropertyDescriptor {
    BridgePropertyDescriptor(
      id: id, kind: kind, labelHtml: label, value: value, defaultValue: .empty, slider: nil,
      comboOptions: [], fileFilter: nil, directoryMode: nil, dirty: false, canRestoreDefaults: false,
      enabled: true, assetManaged: false, assetMissing: false, assetSourcePath: nil)
  }

  /// Port of `WebPanelPropertyLabelTests.testGroupsAreHeadingsAndEmptyOnesAreDropped`.
  func testAGroupWithNoWordsIsLeftOutAndEveryControlStaysInTheAuthorsOrder() {
    let rows = InspectorPolicy.visibleProperties(
      options([
        property("chars", .group, label: "Characters"),
        property("hair", .bool, label: "Show hair"),
        property("blank", .group, label: ""),
        property("light", .group, label: "<font color=red>Lighting</font><script>window.injected = true</script>"),
        property("glow", .bool, label: "Glow"),
      ]))
    XCTAssertEqual(rows.map(\.id), ["chars", "hair", "light", "glow"])
    XCTAssertEqual(rows[0].control, .heading)
    XCTAssertEqual(
      InspectorPolicy.labelDocument(for: rows[2]).plainText, "Lighting",
      "a script in a label is not text")
  }

  /// Port of `testPagePreservesPresentationAndRejectsAuthorControls` (the section and row parts): a
  /// control whose label is decoration is still drawn and named; a description that is only
  /// decoration is not; with every row left out, the section goes too.
  func testDecorationOnlyRowsLeaveNoSectionButAControlWithNoWordsIsStillDrawn() {
    let slug = "imgsrchttpphotogzphotostoreqqcompscv12uhwit3z28ypviewer_4width2000height51"
    let mixed = options([
      property(slug, .bool, label: "<img src=\"http://photogz.photo.store.qq.com/x\">"),
      property("deco", .text, label: ""), property("real", .slider, label: "Character size"),
    ])
    XCTAssertEqual(
      InspectorPolicy.visibleProperties(mixed).map(\.id), [slug, "real"],
      "a control is never anonymous, and a text record is only its label")
    XCTAssertEqual(InspectorPolicy.visibleProperties(mixed).first?.name, "Unnamed option")

    let decorationOnly = options([property("deco", .text, label: "")])
    XCTAssertTrue(InspectorPolicy.visibleProperties(decorationOnly).isEmpty)
  }

  func testADescriptionDrawsWhenItsValueAddsWordsAndARuleAloneIsSomethingToDraw() {
    let rows = InspectorPolicy.visibleProperties(
      options([
        property("a", .text, label: "Hello", value: .string(value: "A longer note")),
        property("b", .text, label: "", value: .string(value: "Only the value")),
        property("c", .text, label: "<hr>"),
        property("d", .text, label: "<img src=\"https://evil.test/x\" onerror=\"alert(1)\">"),
      ]))
    XCTAssertEqual(rows.map(\.id), ["a", "b", "c"])
  }
}
