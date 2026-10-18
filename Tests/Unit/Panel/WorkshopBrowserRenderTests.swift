import AppKit
import SwiftUI
import XCTest

@testable import WallpaperMachine

/// The Workshop page, its inspector and the download surfaces in windows that are never shown: they
/// lay out in the smallest window and after a shrink, in every shipped language and both
/// appearances, without asking for more room than the window gives and without AppKit throwing.
@MainActor
final class WorkshopBrowserRenderTests: MediaPanelTestCase {
  private func rows(_ count: Int = 30) -> [WorkshopBrowseProtocol.Row] {
    (0..<count).map { index in
      var row = WorkshopBrowseProtocol.Row(
        id: String(1_000 + index),
        title: index == 3
          ? "A wallpaper whose title is much too long to fit a tile in the narrowest column"
          : "Wallpaper \(index)",
        kind: ["Scene", "Video", "Web"][index % 3],
        preview: "https://images.steamusercontent.com/ugc/\(1_000 + index)/preview/")
      row.tags = ["Landscape", "Nature", "Approved"]
      if index == 5 { row.collectionChildren = ["1", "2"] }
      return row
    }
  }

  private func makePanel(language: String = "en") async throws -> DiscoverPanel {
    let panel = try makeDiscoverPanel(
      steamImage: { _ in try DiscoverPictures.landscape(sky: (0.1, 0.2, 0.4), ground: (0.3, 0.7, 0.5)) },
      language: language)
    WorkshopBrowseProtocol.serve(rows(), pages: 614, count: 18_420)
    panel.controller.start()
    panel.presentation.show()
    try await panel.controller.searchWorkshop(
      text: "", sort: .trendingYear, tags: [], excludedTags: WorkshopStore.defaultExcludedTags)
    try await waitFor(timeout: 10) { panel.workshop.hasLoaded && !panel.workshop.isLoading }
    return panel
  }

  private func settle(_ host: PanelHost, size: NSSize) async throws {
    host.layout(at: size)
    try await host.settle(0.35)
    host.layout(at: size)
  }

  private func assertFits(
    _ host: PanelHost, _ size: NSSize, _ message: String,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    let measured = host.hosting.sizeThatFits(in: size)
    XCTAssertEqual(measured.width, size.width, accuracy: 1, "\(message): the root takes the window's width", file: file, line: line)
    XCTAssertLessThanOrEqual(measured.height, size.height + 1, "\(message): content must not force a taller window", file: file, line: line)
    XCTAssertLessThanOrEqual(host.widestSplitView, size.width + 1, "\(message): the panel must fit the window, not overflow it", file: file, line: line)
    XCTAssertFalse(host.window.isVisible, "Layout measurement must stay offscreen", file: file, line: line)
  }

  /// Every accessibility identifier under `view`, which says which controls the page really drew.
  private func identifiers(in view: NSView) -> Set<String> { accessibility(in: view, key: "accessibilityIdentifier") }

  /// Every accessibility label under `view`: what VoiceOver would read.
  private func labels(in view: NSView) -> Set<String> { accessibility(in: view, key: "accessibilityLabel") }

  /// Every element under `view` with an identifier or a label, and where it is on the screen
  /// (AppKit's coordinates: y grows upwards, so a row's top edge is its `maxY`).
  private func elements(in view: NSView) -> [(identifier: String, label: String, frame: CGRect)] {
    var found: [(String, String, CGRect)] = []
    func walk(_ element: Any?, depth: Int) {
      guard depth < 40, let object = element as? NSObject else { return }
      let identifier = object.responds(to: NSSelectorFromString("accessibilityIdentifier"))
        ? object.value(forKey: "accessibilityIdentifier") as? String ?? "" : ""
      let label = object.responds(to: NSSelectorFromString("accessibilityLabel"))
        ? object.value(forKey: "accessibilityLabel") as? String ?? "" : ""
      if !(identifier.isEmpty && label.isEmpty),
        object.responds(to: NSSelectorFromString("accessibilityFrame")),
        let frame = (object.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue
      {
        found.append((identifier, label, frame))
      }
      if object.responds(to: NSSelectorFromString("accessibilityChildren")),
        let children = object.value(forKey: "accessibilityChildren") as? [Any]
      {
        for child in children { walk(child, depth: depth + 1) }
      }
    }
    walk(view, depth: 0)
    return found
  }

  /// Lays the window out again until `condition` holds, for at most ten seconds, so a test reads
  /// what was drawn and not a frame still on its way under load.
  private func settle(_ host: PanelHost, until condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(10)
    while !condition(), Date() < deadline { try await host.settle(0.1) }
  }

  private func frame(_ identifier: String, in view: NSView) -> CGRect? {
    elements(in: view).first { $0.identifier == identifier }?.frame
  }

  private func accessibility(in view: NSView, key: String) -> Set<String> {
    var found = Set<String>()
    func walk(_ element: Any?, depth: Int) {
      guard depth < 40, let object = element as? NSObject else { return }
      if object.responds(to: NSSelectorFromString(key)),
        let identifier = object.value(forKey: key) as? String, !identifier.isEmpty
      {
        found.insert(identifier)
      }
      if object.responds(to: NSSelectorFromString("accessibilityChildren")),
        let children = object.value(forKey: "accessibilityChildren") as? [Any]
      {
        for child in children { walk(child, depth: depth + 1) }
      }
    }
    walk(view, depth: 0)
    return found
  }

  func testThePageAndItsInspectorFitTheWindowInEveryLanguageAndAppearanceAtBothSizes() async throws {
    for language in AppLanguage.supported.map(\.tag) {
      let panel = try await makePanel(language: language)
      let controller = panel.controller
      let items = controller.workshopBrowse.items
      panel.workshop.selectedItem = items[0]
      // A tile of each kind of mark and ring: installed, favorite and waiting for setup.
      panel.store.librarySnapshot.wallpapers = [
        BridgeWallpaperEntry(
          id: items[1].id, title: "x", kind: .video, supported: true, active: false, selected: false,
          previewPath: nil)
      ]
      controller.favoriteIDs = [items[1].id]
      try await controller.requestDownload(item: items[2])
      for appearance in [NSAppearance.Name.aqua, .darkAqua] {
        for size in [NSSize(width: 760, height: 560), NSSize(width: 1240, height: 800)] {
          let host = PanelHost(controller: controller)
          host.appearance(appearance)
          try await settle(host, size: size)
          assertFits(host, size, "\(language) \(appearance.rawValue) \(Int(size.width))")
          host.close()
        }
      }
    }
  }

  func testShrinkingTheWindowWithTheInspectorOpenNeverLoopsTheConstraints() async throws {
    let panel = try await makePanel()
    panel.workshop.selectedItem = panel.controller.workshopBrowse.items[0]
    let host = PanelHost(controller: panel.controller)
    for size in [
      NSSize(width: 1240, height: 800), NSSize(width: 900, height: 640), NSSize(width: 760, height: 560),
      NSSize(width: 1100, height: 700), NSSize(width: 760, height: 560),
    ] {
      try await settle(host, size: size)
      assertFits(host, size, "after resizing to \(Int(size.width))")
    }
    host.close()
  }

  func testEveryStateOfAnEmptyGridFitsTheSmallestWindow() async throws {
    let panel = try await makePanel()
    let controller = panel.controller
    let model = controller.workshopBrowser
    let host = PanelHost(controller: controller)
    let size = NSSize(width: 760, height: 560)
    try await settle(host, size: size)

    // Signed-out subscriptions, an empty search with a filter set, and an empty collections page.
    WorkshopBrowseProtocol.serve([], pages: 1, count: 0)
    model.open(.subscriptions)
    try await waitFor { controller.workshopBrowse.source.list == .subscriptions && !controller.workshopBrowse.isLoading }
    try await settle(host, size: size)
    assertFits(host, size, "signed-out subscriptions")

    model.open(.browse)
    model.setIncluded("Anime", false)
    try await waitFor { controller.workshopBrowse.items.isEmpty && controller.workshopBrowse.hasLoaded && !controller.workshopBrowse.isLoading }
    try await settle(host, size: size)
    assertFits(host, size, "a filter hides everything")

    model.edit(text: "3632513108")
    model.search()
    try await settle(host, size: size)
    assertFits(host, size, "a search with filters set")
    let found = identifiers(in: host.hosting.view)
    XCTAssertFalse(found.contains("workshop-page-field"), "an empty state stands alone, without a pager")
    XCTAssertFalse(found.contains("workshop-next-page"))
    host.close()
  }

  func testTheToolbarGainsTheDownloadsButtonOnceARequestIsWaiting() async throws {
    let panel = try await makePanel()
    let controller = panel.controller
    let host = PanelHost(controller: controller)
    let size = NSSize(width: 1240, height: 800)
    func contentItems() -> [NSToolbarItem] {
      (host.window.toolbar?.items ?? []).filter {
        !$0.itemIdentifier.rawValue.hasPrefix("com.apple.SwiftUI")
          && !$0.itemIdentifier.rawValue.hasPrefix("NSToolbar")
      }
    }
    try await settle(host, size: size)
    // Setting up SteamCMD (which `start()` kicked off) may show its pill for a moment.
    try await waitFor { !SetupActivityPill.isActive(in: controller) }
    try await settle(host, size: size)
    let before = contentItems().count
    XCTAssertEqual(host.window.title, "Steam Workshop")

    try await controller.requestDownload(item: controller.workshopBrowse.items[0])
    try await settle(host, size: size)
    XCTAssertEqual(contentItems().count, before + 1, "the Downloads button joined the toolbar")

    try await controller.removeDownloadRequest(id: controller.workshopBrowse.items[0].id)
    try await settle(host, size: size)
    XCTAssertEqual(contentItems().count, before, "and left it when there was nothing to list")
    host.close()
  }

  /// The page's search bar field, while the page has one.
  private func searchField(in window: NSWindow) -> NSSearchField? {
    PanelSearchFocus.field(in: window).flatMap {
      $0.accessibilityIdentifier() == "page-search-field" ? $0 : nil
    }
  }

  func testThePageDrawsItsControlsInOneRowAboveTheGridInTheSmallestWindow() async throws {
    let panel = try await makePanel()
    let size = NSSize(width: 760, height: 560)
    for inspector in [false, true] {
      panel.controller.shell.isInspectorShown = inspector
      let host = PanelHost(controller: panel.controller)
      try await settle(host, size: size)
      try await settle(host) { identifiers(in: host.hosting.view).contains("workshop-page-field") }
      let found = identifiers(in: host.hosting.view)
      for expected in ["workshop-lists", "workshop-filter", "workshop-refresh", "workshop-page-field"] {
        XCTAssertTrue(found.contains(expected), "\(expected) is missing from \(found.sorted())")
      }
      // The lists and the tools share one row, whatever form the lists take in the room left.
      let lists = try XCTUnwrap(frame("workshop-lists", in: host.hosting.view))
      for tool in ["workshop-filter", "workshop-sort", "workshop-refresh"] {
        let tool = try XCTUnwrap(frame(tool, in: host.hosting.view))
        XCTAssertEqual(tool.midY, lists.midY, accuracy: 2, "inspector \(inspector): one header row")
      }
      let field = try XCTUnwrap(searchField(in: host.window), "the page has its search bar")
      XCTAssertGreaterThan(field.frame.width, lists.width, "inspector \(inspector): a wide bar")
      host.close()
    }
  }

  func testCommandFSearchesFromThePageAndAnAuthorsListHasNoField() async throws {
    let panel = try await makePanel()
    let controller = panel.controller
    let model = controller.workshopBrowser
    let host = PanelHost(controller: controller)
    controller.presentation.attach(to: host.window)
    let size = NSSize(width: 1240, height: 800)
    try await settle(host, size: size)
    try await settle(host) { searchField(in: host.window) != nil }
    XCTAssertTrue(
      PanelSearchFocus.field(in: host.window) === searchField(in: host.window),
      "Command-F finds the Workshop's field")
    XCTAssertTrue(controller.shell.focusSearch())

    // An author's wallpapers are in their own order: the field goes, and comes back with the list,
    // and the page takes both changes.
    model.openAuthor(of: controller.workshopBrowse.items[0])
    try await waitFor { !controller.workshopBrowse.source.isSearchable }
    try await settle(host, size: size)
    try await settle(host) { searchField(in: host.window) == nil }
    XCTAssertNil(searchField(in: host.window))
    XCTAssertFalse(controller.shell.focusSearch(), "nothing to search")
    model.goBack()
    try await waitFor { controller.workshopBrowse.source.list == .browse }
    try await settle(host, size: size)
    try await settle(host) { searchField(in: host.window) != nil }
    XCTAssertNotNil(searchField(in: host.window))
    controller.presentation.attach(to: nil)
    host.close()
  }

  func testTheGridKeepsSquareTilesOfOneWidthInAtLeastThreeColumnsThatNeverDropAsItWidens() async throws {
    let panel = try await makePanel()
    let controller = panel.controller
    XCTAssertEqual(controller.workshopBrowse.items.count, WorkshopBrowseState.pageSize, "a page of 30")
    // A ring sits at the centre of its artwork, which places the artwork's middle.
    try await controller.requestDownload(item: controller.workshopBrowse.items[1])
    controller.shell.isInspectorShown = true
    var columns: [Int] = []
    for size in [NSSize(width: 760, height: 560), NSSize(width: 1240, height: 800), NSSize(width: 1900, height: 1000)] {
      let host = PanelHost(controller: controller)
      try await settle(host, size: size)
      try await settle(host) {
        elements(in: host.hosting.view).contains { $0.identifier == "workshop-tile-ring" }
      }
      let found = elements(in: host.hosting.view)
      let tiles = found.filter { $0.label.hasPrefix("Wallpaper ") && $0.label.contains(", ") }
        .map(\.frame)
      let top = try XCTUnwrap(tiles.map(\.maxY).max(), "\(Int(size.width)): tiles were drawn")
      let firstRow = tiles.filter { abs($0.maxY - top) < 1 }
      columns.append(Set(firstRow.map { Int($0.minX.rounded()) }).count)
      let width = try XCTUnwrap(tiles.first?.width)
      for tile in tiles {
        // macOS 26 rounds each column to whole points, so widths differ by up to one.
        XCTAssertEqual(tile.width, width, accuracy: 1, "\(Int(size.width)): every tile is as wide")
      }
      let ring = try XCTUnwrap(found.first { $0.identifier == "workshop-tile-ring" }?.frame)
      let owner = try XCTUnwrap(tiles.first { $0.contains(CGPoint(x: ring.midX, y: ring.midY)) })
      XCTAssertEqual(
        // macOS 26 rounds the ring's centre to a whole point, one point off at some widths.
        2 * (owner.maxY - ring.midY), owner.width, accuracy: 1,
        "\(Int(size.width)): the artwork is as tall as it is wide")
      host.close()
    }
    XCTAssertGreaterThanOrEqual(columns[0], 3, "never fewer than three, beside the inspector at 760")
    XCTAssertEqual(columns, columns.sorted(), "a wider window never has fewer columns: \(columns)")
    XCTAssertGreaterThan(columns[2], columns[0])
  }

  func testATileTellsVoiceOverWhatItIsAndWhatItWears() async throws {
    let panel = try await makePanel()
    let controller = panel.controller
    let items = controller.workshopBrowse.items
    panel.store.librarySnapshot.wallpapers = [
      BridgeWallpaperEntry(
        id: items[1].id, title: "x", kind: .video, supported: true, active: false, selected: false,
        previewPath: nil)
    ]
    controller.favoriteIDs = [items[1].id]
    panel.workshop.selectedItem = items[0]
    let host = PanelHost(controller: controller)
    try await settle(host, size: NSSize(width: 1240, height: 800))
    let found = labels(in: host.hosting.view)
    XCTAssertTrue(
      found.contains("Wallpaper 0, Scene, Approved by Wallpaper Engine"),
      "a tile reads its title and kind, then what it wears: \(found.sorted().prefix(12))")
    XCTAssertTrue(
      found.contains("Wallpaper 1, Video, In your library, Approved by Wallpaper Engine, Favorite"),
      "the marks follow in the order they stack")
    XCTAssertTrue(found.contains("Wallpapers"), "the grid is a group VoiceOver names")
    host.close()
  }

  func testOnlyTheTilesOnScreenLoadTheirAnimationsAndTheRestWait() async throws {
    let panel = try makeDiscoverPanel(steamImage: { _ in try DiscoverPictures.gif(frames: 3, brightness: 0.3) })
    WorkshopBrowseProtocol.serve(rows(), pages: 1, count: 30)
    panel.controller.start()
    panel.presentation.show()
    try await panel.controller.searchWorkshop(
      text: "", sort: .trendingYear, tags: [], excludedTags: WorkshopStore.defaultExcludedTags)
    try await waitFor(timeout: 10) { panel.workshop.hasLoaded && !panel.workshop.isLoading }
    let host = PanelHost(controller: panel.controller)
    try await settle(host, size: NSSize(width: 1240, height: 800))
    let previews = panel.controller.workshopBrowser.previews
    try await waitFor(timeout: 10) { !previews.animations.isEmpty }
    XCTAssertLessThan(previews.animations.count, 30, "the tiles below the fold load nothing")
    XCTAssertLessThanOrEqual(
      previews.scheduler.states.values.filter { $0 == .loading }.count, LivePreviewScheduler.concurrency)
    // Hiding the window releases them all.
    panel.presentation.hide()
    try await host.settle(0.3)
    XCTAssertTrue(previews.animations.isEmpty, "nothing plays where nobody can see it")
    host.close()
  }

  // MARK: The download surfaces

  private func fittingSize<V: View>(_ view: V, controller: PanelController, width: CGFloat) -> CGSize {
    let hosting = NSHostingView(
      rootView: AnyView(
        view.environment(controller).environment(\.panelImages, controller.images)
          .panelTheme(theme: controller.theme, locale: PanelLocale.shared)
          .frame(width: width)))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: width, height: 800), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = hosting
    hosting.layoutSubtreeIfNeeded()
    let size = hosting.fittingSize
    window.contentView = nil
    window.close()
    return size
  }

  func testEveryStageOfTheDialogFitsItsWidthInEveryLanguage() async throws {
    func resolution(
      request: DownloadRequestRow? = nil, own: DownloadRow? = nil,
      current: DownloadDialogResolution.Stage? = nil
    ) -> DownloadDialogResolution {
      DownloadDialogResolution.resolve(
        target: "222", request: request, own: own, sceneAssets: nil, currentStage: current,
        handoffTarget: nil)!
    }
    let long = "Rainy Tokyo Window with a very long Workshop title that has to wrap inside the dialog"
    let stages: [DownloadDialogResolution] = [
      resolution(request: DownloadRequestRow(id: "222", title: long, stage: .setup)),
      resolution(request: DownloadRequestRow(id: "222", title: long, stage: .account)),
      resolution(request: DownloadRequestRow(id: "222", title: long, stage: .resources)),
      resolution(own: DownloadRow(id: "222", title: long, account: "bobby", isPending: true, prompt: .password)),
      resolution(own: DownloadRow(id: "222", title: long, account: "bobby", isPending: true, challenge: .mobileApproval)),
      resolution(own: DownloadRow(id: "222", title: long, account: "bobby", isPending: true, prompt: .guardCode, challenge: .emailCode)),
      resolution(own: DownloadRow(id: "222", title: long, status: "Connecting…", account: "bobby", isPending: true, isAuthenticating: true)),
      resolution(own: DownloadRow(id: "222", title: long, status: "Downloading", progress: 0.2, isPending: true), current: .auth),
    ]
    for language in AppLanguage.supported.map(\.tag) {
      let panel = try makeDiscoverPanel(language: language)
      PanelLocale.shared.bind(to: panel.controller.appLanguage)
      for resolved in stages {
        let session = DownloadsModel.Session(target: "222", account: "bobby", remembersSession: true)
        session.account = "a-very-long-steam-account-name-indeed"
        let size = fittingSize(
          DownloadDialogView(session: session, resolution: resolved), controller: panel.controller,
          width: 460)
        XCTAssertLessThanOrEqual(size.width, 461, "\(language) \(resolved.stage): the dialog must not ask for more width")
        XCTAssertLessThanOrEqual(size.height, 640, "\(language) \(resolved.stage): the body scrolls before the dialog outgrows the window")
        XCTAssertGreaterThan(size.height, 120)
      }
    }
  }

  func testTheDownloadsListFitsItsWidthWithEveryKindOfRowInEveryLanguage() async throws {
    let requests = [
      DownloadRequestRow(id: "10", title: "Rainy Tokyo Window with a very long title", stage: .account),
      DownloadRequestRow(id: "11", title: "Cozy Cabin", stage: .setup, isPaused: true),
    ]
    let steam = [
      DownloadRow(id: "1", title: "Aurora Fjord", status: "Downloading", phase: .transferring, progress: 0.42, isPending: true, bytesReceived: 880_000_000, bytesExpected: 2_100_000_000, bytesPerSecond: 4_100_000, secondsRemaining: 300),
      DownloadRow(id: "2", title: "Orbital", status: "Waiting for a free download slot", isPending: true, isQueued: true),
      DownloadRow(id: "3", title: "Sakura Path", status: "Downloading", isPending: true, prompt: .password),
      DownloadRow(id: "4", title: "Retro Arcade", status: "Download failed", errorMessage: "Steam could not find this item. It may have been removed."),
      DownloadRow(id: "5", title: "Glacier Lake", status: "Download paused", isPaused: true),
    ]
    let queue = DownloadQueue.make(requests: requests, steam: steam, pixiv: [], slotLimit: 3)
    for language in AppLanguage.supported.map(\.tag) {
      let panel = try makeDiscoverPanel(language: language)
      PanelLocale.shared.bind(to: panel.controller.appLanguage)
      let size = fittingSize(DownloadsPopover(queue: queue), controller: panel.controller, width: 360)
      XCTAssertLessThanOrEqual(size.width, 361, "\(language)")
      XCTAssertLessThanOrEqual(size.height, 600, "\(language): the list scrolls past 360 points")
    }
  }

  func testAResumedDownloadRedrawsAsRunningWhileTheListIsOpen() async throws {
    let panel = try makeDiscoverPanel()
    let paused = DownloadRow(id: "1", title: "Aurora Fjord", status: "Download paused", isPaused: true)
    let running = DownloadRow(
      id: "1", title: "Aurora Fjord", status: "Starting SteamCMD and contacting Steam…",
      isPending: true)
    let other = DownloadRow(id: "2", title: "Glacier Lake", status: "Download paused", isPaused: true)
    let source = DownloadQueueSource(
      DownloadQueue.make(requests: [], steam: [paused, other], pixiv: [], slotLimit: 3))
    let hosting = NSHostingView(
      rootView: AnyView(
        DownloadQueueSourceView(source: source).environment(panel.controller)
          .environment(\.panelImages, panel.controller.images)
          .panelTheme(theme: panel.controller.theme, locale: PanelLocale.shared)))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 360, height: 600), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = hosting
    defer {
      window.contentView = nil
      window.close()
    }
    func drawn() async throws -> Set<String> {
      for _ in 0..<5 {
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(60))
      }
      return Set(elements(in: hosting).map(\.label))
        .union(accessibility(in: hosting, key: "accessibilityTitle"))
        .union(accessibility(in: hosting, key: "accessibilityValue"))
    }
    var shown = try await drawn()
    XCTAssertTrue(shown.contains { $0.contains("Download paused") }, "precondition: \(shown)")

    // Resuming moves the row from the paused section to the running one under the same id.
    source.queue = DownloadQueue.make(requests: [], steam: [running, other], pixiv: [], slotLimit: 3)
    shown = try await drawn()
    XCTAssertTrue(
      shown.contains { $0.contains("Starting SteamCMD and contacting Steam") },
      "the resumed row says what it does now: \(shown)")
    XCTAssertTrue(shown.contains { $0.contains("Pause download") }, "and offers a pause: \(shown)")

    // Pausing it moves it back.
    source.queue = DownloadQueue.make(requests: [], steam: [paused, other], pixiv: [], slotLimit: 3)
    shown = try await drawn()
    XCTAssertFalse(shown.contains { $0.contains("Pause download") }, "a paused row offers no pause: \(shown)")
  }

  func testTheDownloadsListsControlsNeverWrapOrTruncateInAnyLanguage() async throws {
    for language in AppLanguage.supported.map(\.tag) {
      let panel = try makeDiscoverPanel(language: language)
      PanelLocale.shared.bind(to: panel.controller.appLanguage)
      // Labels that never wrap and arrangements that never squeeze them: the narrowest one must fit
      // the popover's width inside its padding, and the first that fits is the one drawn.
      let inner: CGFloat = 360 - 2 * 12
      for showsCompleted in [false, true] {
        panel.controller.downloads.showsCompleted = showsCompleted
        let stacked = idealSize(
          DownloadsPopoverActions(completedCount: 12, canClearFinished: true, arrangement: .stacked),
          controller: panel.controller)
        XCTAssertLessThanOrEqual(stacked.width, inner, "\(language): even the narrowest arrangement overflows")
      }
    }
  }

  /// The size `view` takes when nothing constrains it: its labels' full width.
  private func idealSize<V: View>(_ view: V, controller: PanelController) -> CGSize {
    let hosting = NSHostingView(
      rootView: AnyView(
        view.fixedSize().environment(controller).environment(\.panelImages, controller.images)
          .panelTheme(theme: controller.theme, locale: PanelLocale.shared)))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 800, height: 400), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = hosting
    hosting.layoutSubtreeIfNeeded()
    let size = hosting.fittingSize
    window.contentView = nil
    window.close()
    return size
  }

  func testTheInspectorFitsItsNarrowestColumnInEveryLanguage() async throws {
    for language in AppLanguage.supported.map(\.tag) {
      let panel = try await makePanel(language: language)
      panel.workshop.selectedItem = panel.controller.workshopBrowse.items[3]
      let size = fittingSize(WorkshopInspector(), controller: panel.controller, width: 260)
      XCTAssertLessThanOrEqual(size.width, 261, "\(language): the inspector never asks for more than its column")
    }
  }
}

/// A Downloads list whose queue a test replaces while it is drawn, as the stores do while it is open.
@MainActor
@Observable
private final class DownloadQueueSource {
  var queue: DownloadQueue
  init(_ queue: DownloadQueue) { self.queue = queue }
}

private struct DownloadQueueSourceView: View {
  let source: DownloadQueueSource
  var body: some View { DownloadsPopover(queue: source.queue) }
}
