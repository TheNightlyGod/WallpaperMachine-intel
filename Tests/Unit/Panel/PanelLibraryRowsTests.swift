import ImageIO
import Observation
import UniformTypeIdentifiers
import XCTest

@testable import WallpaperMachine

/// The Installed rows: what a row says, and that a library of any size is built once and kept
/// until one of the rows' inputs moves.
@MainActor
final class PanelLibraryRowsTests: PanelTestCase {
  private final class Flag: @unchecked Sendable {
    private(set) var raised = false
    func raise() { raised = true }
  }

  private func entry(
    _ id: String, title: String? = nil, kind: BridgeWallpaperKind = .video, supported: Bool = true,
    preview: URL? = nil
  ) -> BridgeWallpaperEntry {
    BridgeWallpaperEntry(
      id: id, title: title ?? id.uppercased(), kind: kind, supported: supported, active: false,
      selected: false, previewPath: preview?.path)
  }

  private func energySnapshot(battery: Double? = nil) -> [String: Any] {
    var snapshot: [String: Any] = [
      "level": "medium", "milliwatts": 800.0, "displays": 2, "frameRateCap": 30, "renderScale": 0.75,
    ]
    if let battery { snapshot["batteryPercentPerHour"] = battery }
    return snapshot
  }

  /// Library folders `a` and `b` with an animated preview, `c` with a picture, and `d` with none.
  private func installPreviews(_ panel: PanelFixture) throws {
    let gif = try Self.gif(frames: 3, brightness: 0.6)
    var entries: [BridgeWallpaperEntry] = []
    for (id, file, bytes) in [("a", "preview.gif", gif), ("b", "preview.gif", gif), ("c", "preview.png", try png())] {
      let path = panel.library.appendingPathComponent("\(id)/\(file)")
      try FileManager.default.createDirectory(
        at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
      try bytes.write(to: path)
      entries.append(entry(id, preview: path))
    }
    entries.append(entry("d"))
    panel.store.librarySnapshot.wallpapers = entries
  }

  private func png() throws -> Data {
    let output = NSMutableData()
    let destination = try XCTUnwrap(
      CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil))
    let context = try XCTUnwrap(
      CGContext(
        data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
    CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return output as Data
  }

  /// The renderer rescanning the library: the same wallpapers come back with a new refresh revision.
  private func rescan(_ panel: PanelFixture) async throws {
    let store = panel.store
    panel.bridge.bundleProvider = {
      BridgeSnapshotBundle(
        app: store.appSnapshot, library: store.librarySnapshot,
        wallpaperOptions: store.wallpaperOptionsSnapshot,
        monitorInformation: store.monitorInformationSnapshot, settings: store.settingsSnapshot)
    }
    try await store.refreshLibraryAsync()
  }

  /// The sizes and tags of the three library folders `installPreviews` makes are measured in the
  /// background; their arrival rebuilds the rows, so tests that compare rows wait for it first.
  private func settleMetrics(_ panel: PanelFixture) async throws {
    _ = panel.controller.libraryRows
    try await panel.waitUntil(timeout: 10) { panel.controller.libraryMetrics.measured.count == 3 }
    _ = panel.controller.libraryRows
  }

  // MARK: What a row says

  func testARowJoinsTheEntryWithItsMeasuredFactsItsUpdateAndItsRating() throws {
    let file = URL(fileURLWithPath: "/library/a/preview.GIF")
    let added = Date(timeIntervalSince1970: 1_700_000_000)
    let changed = Date(timeIntervalSince1970: 1_800_000_000)
    let row = LibraryRow.make(
      entry("a", title: "Aurora", kind: .projectScene, preview: file), isActive: true,
      covers: ["a": 7],
      metrics: LibraryMetricsService.Metrics(
        size: 4_096, addedAt: added, approved: true, tags: ["Anime", "Audio responsive"]),
      update: WorkshopItem(
        id: "a", title: "Aurora", creator: "Author", summary: "", previewURL: nil, tags: [], size: 0,
        subscriptions: 0, timeUpdated: changed),
      energy: energySnapshot(battery: 3.5))

    XCTAssertEqual(row.id, "a")
    XCTAssertEqual(row.title, "Aurora")
    XCTAssertEqual(row.kind, .scene)
    XCTAssertEqual(row.cover, .stamped(7))
    XCTAssertEqual(row.coverSource, .libraryCover(file: file, stamp: 7))
    XCTAssertEqual(row.previewSource, .libraryPreview(file: file))
    XCTAssertEqual(row.animationSource, .libraryPreview(file: file), "the extension decides, in any case")
    XCTAssertTrue(row.isActive && row.isSupported && row.isApproved)
    XCTAssertEqual(row.tags, ["Anime", "Audio responsive"])
    XCTAssertEqual(row.size, 4_096)
    XCTAssertEqual(row.addedAt, added)
    XCTAssertTrue(row.isUpdateAvailable)
    XCTAssertEqual(row.updatedAt, changed)
    XCTAssertEqual(
      row.energy,
      LibraryEnergyRating(snapshot: energySnapshot(battery: 3.5)),
      "the rating keeps the conditions it was measured under")
    XCTAssertEqual(row.energy?.level, .medium)
    XCTAssertEqual(row.energy?.frameRateCap, 30)
    XCTAssertEqual(row.energy?.batteryPercentPerHour, 3.5)
  }

  func testAnUnmeasuredRowHasNoSizeDateTagsOrRatingAndNoPreviewMeansNoCover() {
    let row = LibraryRow.make(
      entry("a", kind: .unknown, supported: false), isActive: false, covers: [:], metrics: nil,
      update: nil, energy: nil)
    XCTAssertEqual(row.kind, .unknown)
    XCTAssertFalse(row.isSupported)
    XCTAssertNil(row.size, "nil sorts last in both directions, which 0 would not")
    XCTAssertNil(row.addedAt)
    XCTAssertEqual(row.tags, [])
    XCTAssertFalse(row.isApproved)
    XCTAssertNil(row.energy)
    XCTAssertFalse(row.isUpdateAvailable)
    XCTAssertNil(row.updatedAt)
    XCTAssertEqual(row.cover, .none, "a wallpaper without a preview waits for no cover")
    XCTAssertNil(row.coverSource)
    XCTAssertNil(row.previewSource)
    XCTAssertNil(row.animationSource)
    XCTAssertNil(LibraryEnergyRating(snapshot: ["level": "nonsense"]))
  }

  func testTypesSortByTheirEnglishNameAndPreviewsAnimateOnlyByExtension() {
    XCTAssertEqual(
      [LibraryRow.Kind.web, .video, .unknown, .scene].sorted(), [.scene, .unknown, .video, .web])
    for (name, animates) in [
      ("preview.gif", true), ("preview.WEBP", true), ("preview.apng", true), ("preview.png", false),
      ("preview.jpg", false),
    ] {
      let row = LibraryRow.make(
        entry("a", preview: URL(fileURLWithPath: "/library/a/\(name)")), isActive: false,
        covers: [:], metrics: nil, update: nil, energy: nil)
      XCTAssertEqual(row.canAnimate, animates, name)
      XCTAssertEqual(row.animationSource != nil, animates, name)
    }
  }

  // MARK: Covers

  func testACoverIsOfferedOnceItsStampIsReadAndNoRowEverFallsBackToTheFullPreview() async throws {
    try await withPanel { panel in
      try installPreviews(panel)
      let controller = panel.controller
      // The stamps are read in the background: until they are, a row has no cover to show.
      let pending = controller.libraryRows
      XCTAssertEqual(pending.map(\.cover), [.pending, .pending, .pending, .none])
      XCTAssertEqual(pending.compactMap(\.coverSource), [], "never the full-size preview meanwhile")
      XCTAssertEqual(pending.compactMap(\.previewSource).count, 3, "the preview itself is still there for the inspector")

      await controller.libraryCovers.settled()
      let rows = controller.libraryRows
      for (index, file) in ["a/preview.gif", "b/preview.gif", "c/preview.png"].enumerated() {
        let source = panel.library.appendingPathComponent(file)
        let stamp = try XCTUnwrap(LibraryPreviewFetcher.coverStamp(of: source), file)
        XCTAssertEqual(rows[index].cover, .stamped(stamp), file)
        XCTAssertEqual(rows[index].coverSource, .libraryCover(file: source, stamp: stamp), file)
      }
      XCTAssertEqual(rows.map(\.canAnimate), [true, true, false, false])
      XCTAssertEqual(rows[3].cover, .none)
    }
  }

  func testAPreviewThatCannotBeReadIsStillOfferedItsCoverUnderStampZero() async throws {
    try await withPanel { panel in
      let missing = panel.library.appendingPathComponent("gone/preview.gif")
      panel.store.librarySnapshot.wallpapers = [entry("gone", preview: missing)]
      _ = panel.controller.libraryRows
      await panel.controller.libraryCovers.settled()
      let row = try XCTUnwrap(panel.controller.libraryRow(id: "gone"))
      XCTAssertEqual(row.cover, .stamped(0), "the loader falls back to the preview, so the tile still draws")
    }
  }

  func testARescanThatReplacedNoPreviewLeavesEveryRowAlone() async throws {
    try await withPanel { panel in
      try installPreviews(panel)
      let controller = panel.controller
      try await settleMetrics(panel)
      await controller.libraryCovers.settled()
      let before = controller.libraryRows
      let announced = controller.libraryCovers.contentRevision

      try await rescan(panel)
      _ = controller.libraryRows
      await controller.libraryCovers.settled()

      XCTAssertEqual(controller.libraryCovers.contentRevision, announced, "nothing changed, so nothing was announced")
      XCTAssertEqual(controller.libraryRows, before, "no row, and so no tile's image, was redone")
    }
  }

  func testAPreviewThatWasReplacedGetsANewCoverAndTheOthersKeepTheirs() async throws {
    try await withPanel { panel in
      try installPreviews(panel)
      let controller = panel.controller
      try await settleMetrics(panel)
      await controller.libraryCovers.settled()
      let before = controller.libraryRows

      // An update replaced a's preview with a different picture.
      try Self.gif(frames: 5, brightness: 0.3).write(to: panel.library.appendingPathComponent("a/preview.gif"))
      try await rescan(panel)
      _ = controller.libraryRows
      await controller.libraryCovers.settled()
      let after = controller.libraryRows

      XCTAssertNotEqual(after[0].cover, before[0].cover, "a's cover is another image now")
      XCTAssertNotEqual(after[0].coverSource, before[0].coverSource)
      XCTAssertEqual(Array(after.dropFirst()), Array(before.dropFirst()), "only a's tile is redone")
    }
  }

  // MARK: The active mark

  func testOnlyTheTargetDisplaysOwnWallpaperIsActive() async throws {
    try await withPanel { panel in
      panel.configureDisplays()
      panel.store.librarySnapshot.wallpapers = ["first", "second", "third"].map { entry($0) }
      panel.navigation.targetDisplayID = "primary"
      XCTAssertEqual(panel.controller.libraryRows.map(\.isActive), [true, false, false])
      panel.navigation.targetDisplayID = "secondary"
      XCTAssertEqual(
        panel.controller.libraryRows.map(\.isActive), [false, true, false],
        "another target display is another Active tile")

      // A mirror shows the wallpaper of what it mirrors but holds no wallpaper of its own.
      panel.store.monitorInformationSnapshot.rows[1].mirrorTargetDisplayId = "primary"
      XCTAssertEqual(panel.controller.libraryRows.map(\.isActive), [false, false, false])
    }
  }

  // MARK: Reuse

  func testTenThousandWallpapersAreBuiltOnceWhateverElseChanges() async throws {
    try await withPanel { panel in
      let controller = panel.controller
      let cache = controller.libraryRowsCache
      panel.store.librarySnapshot.wallpapers = (0..<10_000).map {
        entry("synthetic-\($0)", title: "Synthetic wallpaper \($0)")
      }
      let first = controller.libraryRows
      XCTAssertEqual(first.count, 10_000)
      XCTAssertEqual(cache.rebuilds, 1)

      // Everything that moves while the user works leaves the rows as they are: a download's
      // progress, a selection, playback, favorites, the same library handed over again.
      for step in 0..<5 {
        panel.store.appSnapshot.selectedWallpaperId = "synthetic-\(step)"
        panel.store.appSnapshot.playbackState = step.isMultiple(of: 2) ? .paused : .playing
        panel.store.librarySnapshot = panel.store.librarySnapshot
        panel.store.monitorInformationSnapshot = panel.store.monitorInformationSnapshot
        controller.favoriteIDs.insert("synthetic-\(step)")
        panel.workshop.searchText = "progress \(step)"
        XCTAssertEqual(controller.libraryRows, first)
        XCTAssertEqual(controller.libraryRow(id: "synthetic-9999")?.title, "Synthetic wallpaper 9999")
      }
      XCTAssertEqual(cache.rebuilds, 1, "the 10,000 rows were not rebuilt for any of it")
    }
  }

  func testTheRowsAreRebuiltWhenOneOfTheirInputsMoves() async throws {
    try await withPanel { panel in
      panel.configureDisplays()
      panel.store.librarySnapshot.wallpapers = [entry("first"), entry("second")]
      let controller = panel.controller
      let cache = controller.libraryRowsCache
      _ = controller.libraryRows
      XCTAssertEqual(cache.rebuilds, 1)

      panel.store.librarySnapshot.wallpapers[1].title = "Renamed"
      XCTAssertEqual(controller.libraryRow(id: "second")?.title, "Renamed")
      XCTAssertEqual(cache.rebuilds, 2, "a renamed wallpaper")

      panel.navigation.targetDisplayID = "secondary"
      XCTAssertEqual(controller.libraryRows.map(\.isActive), [false, true])
      XCTAssertEqual(cache.rebuilds, 3, "the target display decides which tile is Active")

      try controller.appLanguage.set("ja")
      _ = controller.libraryRows
      XCTAssertEqual(cache.rebuilds, 4, "a language switch redelivers the rows")

      try await rescan(panel)
      _ = controller.libraryRows
      XCTAssertEqual(cache.rebuilds, 5, "a rescan asks the measuring services again")

      controller.revisions.bump(.libraryMetrics)
      _ = controller.libraryRows
      XCTAssertEqual(cache.rebuilds, 5, "a bump that did not change the service's content changes no row")
    }
  }

  func testReadingTheRowsTellsSwiftUIWhenTheirInputsMoveAndNotWhenSomethingElseDoes() async throws {
    try await withPanel { panel in
      panel.configureDisplays()
      panel.store.librarySnapshot.wallpapers = [entry("first"), entry("second")]
      let controller = panel.controller
      _ = controller.libraryRows

      func fires(_ change: () throws -> Void) throws -> Bool {
        let fired = Flag()
        withObservationTracking({ MainActor.assumeIsolated { _ = controller.libraryRows } }, onChange: { fired.raise() })
        try change()
        return fired.raised
      }
      XCTAssertFalse(try fires { panel.store.appSnapshot.selectedWallpaperId = "second" }, "selection")
      XCTAssertFalse(try fires { panel.store.appSnapshot.playbackState = .paused }, "playback")
      XCTAssertFalse(try fires { controller.favoriteIDs.insert("first") }, "favorites")
      XCTAssertTrue(try fires { panel.store.librarySnapshot.wallpapers[0].title = "Other" }, "the library")
      XCTAssertTrue(try fires { panel.navigation.targetDisplayID = "secondary" }, "the target display")
      XCTAssertTrue(try fires { try controller.appLanguage.set("zh-Hans") }, "the language")
      XCTAssertTrue(try fires { controller.revisions.bump(.libraryMetrics) }, "measured sizes and tags")
      XCTAssertTrue(try fires { controller.revisions.bump(.libraryCovers) }, "cover stamps")
    }
  }
}
