import AppKit
import SwiftUI
import XCTest

@testable import WallpaperMachine

/// The pixiv page and its inspector, drawn by the real root in a window that is never shown: they
/// take the size the window gives them, in every shipped language, light and dark, in each state
/// the page can be in, and the toolbar pill appears while a save is under way and gives way to the
/// controls that act. What VoiceOver reaches (a tile, the inspector's Try again) is read off the
/// accessibility tree of the view drawn on its own, since the split view's columns do not expose
/// theirs offscreen.
@MainActor
final class PixivBrowserRenderTests: MediaPanelTestCase {
  private enum Listing {
    case works, hidden, nothing, failing
    /// pixiv answers only when the gate opens, so the page is loading until then.
    case held(PixivGate)
  }

  @MainActor
  private final class Hosted {
    let fixture: PanelFixture
    let controller: PanelController
    let window: NSWindow
    let hosting: NSHostingController<AnyView>
    let transport: PixivFixtureTransport

    /// - Parameters:
    ///   - count: how many works the ranking has (on every page).
    ///   - membersOnly: works whose page list pixiv answers as it does for members only.
    ///   - viewState: what the last window left, which this one restores.
    init(
      test: MediaPanelTestCase, language: String = "en", dark: Bool = false,
      listing: Listing = .works, count: Int = 6, membersOnly: Set<Int> = [],
      originals: PixivGate? = nil, viewState: PanelViewState? = nil
    ) throws {
      let image = try PanelTestCase.gif(frames: 1, brightness: 0.6)
      let transport = PixivFixtureTransport(respondingToSession: { url, _ in
        if url.host == "i.pximg.net" { return image }
        if url.path.hasSuffix("/pages") {
          let id = Int(url.pathComponents.dropLast().last ?? "") ?? 0
          if membersOnly.contains(id) { return PixivFixtures.membersOnlyPages() }
          return PixivFixtures.pages(workID: id, count: 3)
        }
        switch listing {
        case .failing: throw PixivFailure(code: .status(429))
        case .nothing: return PixivFixtures.ranking([], total: 0)
        case .hidden:
          return PixivFixtures.ranking(
            (0..<3).map { PixivFixtures.rankingEntry(.init(id: 400 + $0, sexual: 1), rank: $0 + 1) }
          )
        case .held, .works: break
        }
        return PixivFixtures.ranking(
          (0..<count).map {
            PixivFixtures.rankingEntry(
              .init(
                id: 301 + $0, width: $0 % 2 == 0 ? 1920 : 1080, height: $0 % 2 == 0 ? 1080 : 1920,
                pages: $0 % 3 == 0 ? 1 : 3,
                title: $0 == 2
                  ? "A very long title that has to be cut short somewhere sensible" : nil),
              rank: $0 + 1)
          })
      })
      self.transport = transport
      var listings: PixivGate?
      if case .held(let gate) = listing { listings = gate }
      let made = test.makeStore()
      fixture = try PanelFixture(
        store: made.store, bridge: made.bridge, displayTitles: .renderer,
        pixivTransport: PixivHeldTransport(
          fixture: transport, originals: originals, listings: listings))
      if let viewState { fixture.navigation.viewState = viewState }
      let root = fixture.root
      let library = fixture.library
      let languages = AppLanguageStore(defaults: fixture.defaults, systemLanguages: [language])
      let images = PanelImagePipeline(
        thumbnailCache: WorkshopThumbnailCache(
          directory: root.appendingPathComponent("t1"), fetcher: PreviewFetcher { _ in image }),
        pixivThumbnailCache: WorkshopThumbnailCache(
          directory: root.appendingPathComponent("t2"), fetcher: PreviewFetcher { _ in image }),
        libraryThumbnailCache: WorkshopThumbnailCache(
          directory: root.appendingPathComponent("t3"),
          fetcher: LibraryPreviewFetcher(root: library),
          keepsAnimation: false),
        libraryRoot: { library })
      controller = PanelController(
        store: fixture.store, navigation: fixture.navigation, workshop: fixture.workshop,
        pixiv: fixture.pixiv, presentation: fixture.presentation, theme: fixture.theme,
        displayTitles: .renderer, defaults: fixture.defaults, images: images,
        dialogs: fixture.dialogs,
        appLanguage: languages, playback: PlaybackPreferences(defaults: fixture.defaults),
        playlists: fixture.playlists, hotKeys: HotKeyPreferences(defaults: fixture.defaults),
        collections: fixture.collections, presets: fixture.presets, backup: fixture.backup,
        imagePlacement: fixture.imagePlacement, compatibility: fixture.compatibility,
        automations: fixture.automations, spaces: fixture.spaces)
      PanelLocale.shared.bind(to: languages)
      let controller = controller
      hosting = NSHostingController(
        rootView: AnyView(
          PanelRootView().frame(maxWidth: .infinity, maxHeight: .infinity).environment(controller)
            .environment(\.panelImages, controller.images)))
      hosting.sizingOptions = []
      hosting.sceneBridgingOptions = [.toolbars, .title]
      window = ControlPanelWindow.make(contentViewController: hosting, delegate: nil)
      window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
      hosting.view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
      fixture.navigation.selection = .pixiv
      fixture.presentation.show()
      controller.start()
    }

    func layout(at size: NSSize, for seconds: Double = 0.45) async throws {
      window.setContentSize(size)
      window.layoutIfNeeded()
      hosting.view.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .seconds(seconds))
      window.layoutIfNeeded()
      hosting.view.layoutSubtreeIfNeeded()
    }

    /// The widest split view inside the window's content: wider than the window means the panel
    /// asks for more room than it was given.
    var widestSplitView: CGFloat {
      func widest(_ view: NSView) -> CGFloat {
        let own = (view as? NSSplitView)?.frame.width ?? 0
        return view.subviews.map(widest).reduce(own, max)
      }
      return widest(window.contentView!)
    }

    var contentToolbarItems: [NSToolbarItem] {
      (window.toolbar?.items ?? []).filter {
        !$0.itemIdentifier.rawValue.hasPrefix("com.apple.SwiftUI")
          && !$0.itemIdentifier.rawValue.hasPrefix("NSToolbar")
      }
    }

    /// A view of the page drawn on its own, over this panel's controller, in a window that is
    /// never shown.
    func standalone(_ content: some View, size: NSSize) -> NSHostingView<AnyView> {
      let view = NSHostingView(
        rootView: AnyView(
          content.frame(width: size.width, height: size.height)
            .environment(controller).environment(\.panelImages, controller.images)))
      view.frame = NSRect(origin: .zero, size: size)
      let window = NSWindow(
        contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentView = view
      standaloneWindows.append(window)
      view.layoutSubtreeIfNeeded()
      return view
    }

    private var standaloneWindows: [NSWindow] = []
    private var isClosed = false

    /// Closes the window and shuts the fixture down, once: a test that registered it as a
    /// teardown may also close it itself.
    func close() async {
      guard !isClosed else { return }
      isClosed = true
      for window in standaloneWindows { window.close() }
      window.contentViewController = nil
      window.close()
      controller.stop()
      await fixture.shutdown()
    }
  }

  // MARK: The accessibility tree

  /// Every accessibility element under `root`.
  private func elements(in root: Any) -> [NSObject] {
    var found: [NSObject] = []
    func walk(_ element: Any?, depth: Int) {
      guard depth < 50, let object = element as? NSObject else { return }
      found.append(object)
      if let children = value(object, "accessibilityChildren") as? [Any] {
        for child in children { walk(child, depth: depth + 1) }
      }
    }
    walk(root, depth: 0)
    return found
  }

  /// An accessibility attribute, read the way an assistive app does: SwiftUI's elements answer
  /// these messages without declaring `NSAccessibilityProtocol`.
  private func value(_ element: NSObject, _ key: String) -> Any? {
    element.responds(to: NSSelectorFromString(key)) ? element.value(forKey: key) : nil
  }

  private func element(_ identifier: String, in root: Any) -> NSObject? {
    elements(in: root).first { value($0, "accessibilityIdentifier") as? String == identifier }
  }

  private func identifiers(in root: Any) -> Set<String> {
    Set(elements(in: root).compactMap { value($0, "accessibilityIdentifier") as? String })
  }

  private func actionNames(_ element: NSObject?) -> [String] {
    guard let element else { return [] }
    return ((value(element, "accessibilityCustomActions") as? [NSAccessibilityCustomAction]) ?? [])
      .map(\.name)
  }

  /// What VoiceOver's VO-Space does.
  private func press(_ element: NSObject) {
    _ = element.perform(NSSelectorFromString("accessibilityPerformPress"))
  }

  /// A hosted panel that is closed when the test ends, even when it fails early: an open fixture
  /// would leave its `WALLPAPER_MACHINE_HOME` to the next test of the process.
  private func host(
    listing: Listing = .works, count: Int = 6, membersOnly: Set<Int> = [],
    originals: PixivGate? = nil, viewState: PanelViewState? = nil
  ) throws -> Hosted {
    let hosted = try Hosted(
      test: self, listing: listing, count: count, membersOnly: membersOnly, originals: originals,
      viewState: viewState)
    addTeardownBlock { @MainActor in await hosted.close() }
    return hosted
  }

  private func loadAndSelect(_ hosted: Hosted) async throws {
    try await hosted.controller.navigate(.pixiv)
    try await hosted.fixture.waitUntil(timeout: 5) { hosted.fixture.pixiv.hasLoaded }
    try await hosted.controller.pixivSelect(workID: "302")
    try await hosted.fixture.waitUntil(timeout: 5) { hosted.fixture.pixiv.selectedPageList != nil }
  }

  private func assertFits(
    _ hosted: Hosted, _ size: NSSize, _ context: String, file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let measured = hosted.hosting.sizeThatFits(in: size)
    XCTAssertEqual(
      measured.width, size.width, accuracy: 1, "\(context): the window decides the width",
      file: file,
      line: line)
    XCTAssertLessThanOrEqual(
      measured.height, size.height + 1, "\(context): no taller than the window", file: file,
      line: line)
    XCTAssertLessThanOrEqual(
      hosted.widestSplitView, size.width + 1, "\(context): the panel fits the window", file: file,
      line: line)
    XCTAssertFalse(hosted.window.isVisible, "layout stays offscreen", file: file, line: line)
  }

  private let sizes = [NSSize(width: 760, height: 560), NSSize(width: 1240, height: 800)]

  func testTheLoadedPageAndItsInspectorFitTheSmallestAndALargeWindowInEveryLanguage() async throws {
    for language in AppLanguage.supported.map(\.tag) {
      let hosted = try Hosted(test: self, language: language)
      try await loadAndSelect(hosted)
      for size in sizes {
        try await hosted.layout(at: size)
        assertFits(hosted, size, "\(language) \(Int(size.width))")
      }
      XCTAssertEqual(hosted.controller.pixivBrowse.works.count, 6)
      XCTAssertEqual(hosted.controller.pixivBrowse.selectedID, "302")
      XCTAssertEqual(hosted.window.title, "pixiv", "the name is never translated")
      await hosted.close()
    }
  }

  func testTheDarkPageAndEveryEmptyStateFitTheSmallestWindow() async throws {
    let dark = try Hosted(test: self, dark: true)
    try await loadAndSelect(dark)
    for size in sizes {
      try await dark.layout(at: size)
      assertFits(dark, size, "dark \(Int(size.width))")
    }
    await dark.close()

    let gate = PixivGate()
    for (listing, name) in [
      (Listing.hidden, "every work hidden"), (.nothing, "nothing found"), (.failing, "an error"),
      (.held(gate), "loading"),
    ] {
      let hosted = try Hosted(test: self, listing: listing)
      hosted.controller.launch { try await hosted.controller.navigate(.pixiv) }
      for size in sizes {
        try await hosted.layout(at: size)
        assertFits(hosted, size, "\(name) \(Int(size.width))")
      }
      if case .held = listing { gate.open() }
      await hosted.close()
    }
  }

  func testAPageListThatCannotBeReadIsSaidWithTryAgainForAWorkOfOnePageToo() async throws {
    // 301 has one page, and pixiv shows its page list to members only.
    let hosted = try host(membersOnly: [301])
    let controller = hosted.controller
    try await controller.navigate(.pixiv)
    try await hosted.fixture.waitUntil(timeout: 10) { hosted.fixture.pixiv.hasLoaded }
    try await controller.pixivSelect(workID: "301")
    try await hosted.fixture.waitUntil(timeout: 10) { controller.pixivSelection?.pages != .loading }
    let selection = try XCTUnwrap(controller.pixivSelection)
    XCTAssertEqual(selection.pageCount, 1)
    guard case .failed(let message) = selection.pages else {
      return XCTFail("the members-only answer is a failure")
    }

    let inspector = hosted.standalone(PixivInspector(), size: NSSize(width: 300, height: 760))
    try await Task.sleep(for: .milliseconds(300))
    let shown = identifiers(in: inspector)
    XCTAssertTrue(shown.contains("pixiv-retry-pages"), "Try again, beside why: \(shown.sorted())")
    XCTAssertFalse(shown.contains("pixiv-next-work-page"), "one page has no stepper")
    // A line of text is read as its value, a control by its label.
    let read = elements(in: inspector).flatMap { element in
      ["accessibilityLabel", "accessibilityValue"].compactMap { value(element, $0) as? String }
    }
    XCTAssertTrue(read.contains(message), "the notice says why the page list failed")

    let asked = { hosted.transport.requests.filter { $0.path.hasSuffix("/301/pages") }.count }
    let before = asked()
    press(try XCTUnwrap(element("pixiv-retry-pages", in: inspector)))
    try await hosted.fixture.waitUntil(timeout: 10) { asked() > before }

    // A work of several pages whose list loads has the stepper and no notice.
    try await controller.pixivSelect(workID: "302")
    try await hosted.fixture.waitUntil(timeout: 10) { controller.pixivSelection?.pages == .loaded }
    inspector.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(300))
    let stepped = identifiers(in: inspector)
    XCTAssertTrue(stepped.contains("pixiv-next-work-page"))
    XCTAssertFalse(stepped.contains("pixiv-retry-pages"))
    await hosted.close()
  }

  func testATileIsAButtonThatSelectsAndOffersWhatItsDoubleClickDoes() async throws {
    let gate = PixivGate()
    let hosted = try host(originals: gate)
    let controller = hosted.controller
    try await controller.navigate(.pixiv)
    try await hosted.fixture.waitUntil(timeout: 5) { hosted.fixture.pixiv.hasLoaded }
    let works = Array(hosted.fixture.pixiv.works.prefix(3))
    let tiles = hosted.standalone(
      HStack(alignment: .top, spacing: 14) {
        ForEach(works) { work in PixivTileCell(work: work, isSelected: false).frame(width: 140) }
      },
      size: NSSize(width: 480, height: 220))
    try await Task.sleep(for: .milliseconds(300))
    func tile() -> NSObject? {
      tiles.layoutSubtreeIfNeeded()
      return element("pixiv-tile-303", in: tiles)
    }
    let first = try XCTUnwrap(tile(), "the tile is in the accessibility tree")
    XCTAssertEqual(value(first, "accessibilityRole") as? String, NSAccessibility.Role.button.rawValue)
    XCTAssertEqual(actionNames(first), ["Download"], "the double-click, by name")

    press(first)
    try await hosted.fixture.waitUntil(timeout: 5) { hosted.fixture.pixiv.selectedWork?.id == "303" }

    let download = try XCTUnwrap(
      (value(first, "accessibilityCustomActions") as? [NSAccessibilityCustomAction])?.first)
    XCTAssertTrue(download.handler?() ?? false)
    try await hosted.fixture.waitUntil(timeout: 5) {
      hosted.fixture.pixiv.downloads.download(for: "pixiv-303-p0")?.isPending == true
    }
    try await Task.sleep(for: .milliseconds(200))
    XCTAssertEqual(actionNames(tile()), [], "nothing to offer while the page downloads")

    gate.open()
    try await hosted.fixture.waitUntil(timeout: 10) {
      hosted.fixture.pixiv.downloads.download(for: "pixiv-303-p0")?.status == .finished
    }
    hosted.fixture.store.librarySnapshot.wallpapers = [
      BridgeWallpaperEntry(
        id: "pixiv-303-p0", title: "Saved", kind: .webpage, supported: true, active: false,
        selected: false, previewPath: nil)
    ]
    try await Task.sleep(for: .milliseconds(200))
    XCTAssertEqual(actionNames(tile()), ["Apply wallpaper"], "a saved page applies")
    hosted.fixture.store.settingsSnapshot.displays[0].mode = .mirror
    try await Task.sleep(for: .milliseconds(200))
    XCTAssertEqual(actionNames(tile()), [], "a mirror shows no wallpaper of its own")
    await hosted.close()
  }

  func testTheGridGoesBackToWhereTheLastWindowLeftItEvenBesideTheInspectorOfTheSmallestWindow()
    async throws
  {
    let left = PanelViewState(scroll: ["pixiv": 400, "installed": 12])
    let wide = try host(count: 48, viewState: left)
    try await wide.controller.navigate(.pixiv)
    try await wide.fixture.waitUntil(timeout: 5) { wide.fixture.pixiv.hasLoaded }
    try await waitForOffset(wide, near: 400, at: sizes[1])
    await wide.close()

    // Beside an open inspector the page is about 280 points wide. The grid's scroll tracking must
    // not keep the split view's layout pass going (AppKit throws "needing another Update
    // Constraints in Window pass", a crash outside a test). Its tiles are small, so the place is
    // one well inside the shorter grid, where a lazy grid still estimating its height under load
    // cannot clamp it. pixiv answers only once the window is that small with its inspector open,
    // so the grid is restored where it is first laid out: one restored in a wider window is
    // re-anchored frame by frame as its columns change, and lands a point or two off.
    let ranking = PixivGate()
    let narrow = try host(
      listing: .held(ranking), count: 48, viewState: PanelViewState(scroll: ["pixiv": 160]))
    narrow.controller.launch { try await narrow.controller.navigate(.pixiv) }
    try await narrow.layout(at: sizes[0], for: 1.0)
    narrow.controller.shell.isInspectorShown = true
    try await narrow.layout(at: sizes[0], for: 0.5)
    ranking.open()
    try await narrow.fixture.waitUntil(timeout: 5) { narrow.fixture.pixiv.hasLoaded }
    try await narrow.controller.pixivSelect(workID: "302")
    try await waitForOffset(narrow, near: 160, at: sizes[0])
    XCTAssertTrue(narrow.controller.shell.isInspectorShown)
    assertFits(narrow, sizes[0], "restored beside the inspector")
    await narrow.close()

    // A grid shorter than the page, with nothing to restore: the lazy grid's estimated height
    // moves as its rows are built, and watching it looped that pass.
    let short = try host()
    try await short.controller.navigate(.pixiv)
    try await short.fixture.waitUntil(timeout: 5) { short.fixture.pixiv.hasLoaded }
    try await short.layout(at: sizes[0], for: 1.0)
    short.controller.shell.isInspectorShown = true
    try await short.controller.pixivSelect(workID: "302")
    try await short.layout(at: sizes[0], for: 1.0)
    assertFits(short, sizes[0], "a short grid beside the inspector")
    XCTAssertEqual(short.controller.pixivBrowser.scrollOffset, 0, "a grid with no place to go back to starts at its top")
    await short.close()
  }

  /// Lays the window out until the grid reports an offset near `target`, or fails after a few
  /// seconds.
  private func waitForOffset(
    _ hosted: Hosted, near target: Double, at size: NSSize, file: StaticString = #filePath,
    line: UInt = #line
  ) async throws {
    let deadline = Date().addingTimeInterval(8)
    let model = hosted.controller.pixivBrowser
    while abs(model.scrollOffset - target) > 1 {
      guard Date() < deadline else {
        return XCTFail(
          "the grid came back to \(model.scrollOffset), not \(target)", file: file, line: line)
      }
      try await hosted.layout(at: size, for: 0.2)
    }
  }

  func testAtTheSmallestWindowThePillGivesWayToTheDownloadsButtonAndTheInspectorToggle()
    async throws
  {
    try PanelTestSupport.skipBeforeMacOS27(
      "macOS 26 sends the Downloads button to the overflow menu of an unshown window's toolbar")
    // The saves stay under way until the panel closes, which cancels them.
    let hosted = try host(originals: PixivGate())
    try await loadAndSelect(hosted)
    let controller = hosted.controller
    for work in ["302", "304", "306"] { try await controller.pixivDownload(workID: work, page: 0) }
    try await hosted.fixture.waitUntil(timeout: 5) {
      hosted.fixture.pixiv.downloads.download(for: "pixiv-302-p0")?.status == .downloading
    }
    try await hosted.layout(at: sizes[0], for: 1.0)
    XCTAssertTrue(controller.shell.isCompact)

    let toolbar = try XCTUnwrap(hosted.window.toolbar)
    func item(holding identifier: String) -> NSToolbarItem? {
      toolbar.items.first { item in item.view.map { element(identifier, in: $0) != nil } ?? false }
    }
    let pill = try XCTUnwrap(item(holding: "pixiv-activity-pill"))
    let downloads = try XCTUnwrap(item(holding: "downloads-button"))
    let details = try XCTUnwrap(toolbar.items.first { $0.label == "Wallpaper details" })
    let visible = toolbar.visibleItems ?? []
    XCTAssertTrue(visible.contains(downloads), "the Downloads button stays out of the overflow menu")
    XCTAssertTrue(visible.contains(details), "and so does the inspector toggle")
    let compactWidth = try XCTUnwrap(pill.view).frame.width
    XCTAssertLessThanOrEqual(compactWidth, 64, "a ring and a figure")
    let label = try XCTUnwrap(element("pixiv-activity-pill", in: try XCTUnwrap(pill.view)))
    XCTAssertEqual(
      value(label, "accessibilityLabel") as? String, "3 pixiv downloads",
      "VoiceOver still hears the whole label")

    try await hosted.layout(at: sizes[1], for: 1.0)
    let regular = try XCTUnwrap(item(holding: "pixiv-activity-pill")?.view).frame.width
    XCTAssertGreaterThan(regular, compactWidth, "a wide window has room for the words")
    await hosted.close()
  }

  func testWhileASaveIsUnderWayTheRingAndThePillAreThereAndStillFit() async throws {
    let gate = PixivGate()
    let hosted = try host(originals: gate)
    try await loadAndSelect(hosted)
    let controller = hosted.controller
    XCTAssertFalse(PixivActivityPill.isActive(in: controller))
    try await hosted.layout(at: sizes[1])
    let idle = hosted.contentToolbarItems.count

    try await controller.pixivDownload(workID: "302", page: 0)
    try await hosted.fixture.waitUntil(timeout: 5) {
      hosted.fixture.pixiv.downloads.download(for: "pixiv-302-p0")?.status == .downloading
    }
    XCTAssertTrue(PixivActivityPill.isActive(in: controller))
    XCTAssertEqual(controller.pixivActivity?.jobCount, 1)
    let work = try XCTUnwrap(hosted.fixture.pixiv.works.first { $0.id == "302" })
    XCTAssertNotNil(controller.pixivTile(for: work).ring, "the tile wears a ring")
    for size in sizes {
      try await hosted.layout(at: size)
      assertFits(hosted, size, "saving \(Int(size.width))")
    }
    XCTAssertTrue(DownloadsToolbarButton.isActive(in: controller), "a pixiv save is download activity too")
    XCTAssertEqual(
      hosted.contentToolbarItems.count, idle + 2, "the pill and the downloads button join the toolbar")

    gate.open()
    try await hosted.fixture.waitUntil(timeout: 10) {
      hosted.fixture.pixiv.downloads.download(for: "pixiv-302-p0")?.status == .finished
    }
    try await hosted.layout(at: sizes[0])
    XCTAssertFalse(PixivActivityPill.isActive(in: controller))
    // The finished row stays in the downloads list until it is cleared, and so does the button.
    XCTAssertTrue(DownloadsToolbarButton.isActive(in: controller))
    XCTAssertEqual(hosted.contentToolbarItems.count, idle + 1, "the pill leaves when the save is done")
    await hosted.close()
  }
}
