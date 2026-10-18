import AppKit
import SwiftUI
import XCTest

@testable import WallpaperMachine

/// The shell drawn in a window that is never shown: sidebar, banners, Now Playing and the toolbar in
/// every language and both appearances at the smallest and the default window, the layout at the
/// sizes of full screen and Split View, and the narrow-window behaviour.
@MainActor
final class ShellRenderTests: PanelTestCase {
  override func tearDown() async throws {
    // Each host bound the shared panel language to its own store.
    restoreSharedPanelLanguage()
    try await super.tearDown()
  }

  private let longError =
    "The wallpaper could not be started: its video track is damaged and cannot be decoded by the system."

  /// A store with a library, two displays, an error and a held wallpaper: everything the shell draws.
  private func busyStore() async throws -> BridgeStore {
    let (store, bridge) = makeStore()
    try await ShellFixtures.seed(store, bridge: bridge)
    store.latestBridgeErrorMessage = longError
    store.latestBridgeErrorRevision &+= 1
    store.appSnapshot.heldWallpaperIds = ["w6"]
    return store
  }

  func testTheShellTakesWhateverSizeTheWindowGivesItInEveryLanguageAndAppearance() async throws {
    let store = try await busyStore()
    for language in AppLanguage.supported.map(\.tag) {
      try await withShellHost(store: store, language: language) { host in
        for size in [NSSize(width: 760, height: 560), NSSize(width: 1240, height: 800)] {
          for dark in [false, true] {
            host.setDark(dark)
            host.layout(at: size)
            try await host.settle(250)
            host.layout(at: size)
            let measured = host.hosting.sizeThatFits(in: size)
            let note = "\(language) \(Int(size.width)) \(dark ? "dark" : "light")"
            XCTAssertEqual(measured.width, size.width, accuracy: 1, "\(note): accept the window width")
            XCTAssertLessThanOrEqual(
              measured.height, size.height + 1, "\(note): never force a taller window")
            XCTAssertLessThanOrEqual(
              host.widestSplitView, size.width + 1, "\(note): fit the window, not overflow it")
            XCTAssertFalse(host.window.isVisible, "layout stays offscreen")
          }
        }
      }
    }
  }

  func testThePageAndInspectorStayInsideTheWindowAtFullScreenSplitViewAndMinimumSizes() async throws {
    try await withShellHost(store: try await busyStore()) { host in
      for size in [
        NSSize(width: 1920, height: 1080), NSSize(width: 960, height: 1080),
        NSSize(width: 760, height: 560),
      ] {
        host.layout(at: size)
        try await host.settle(300)
        host.layout(at: size)
        let content = host.window.contentView!.bounds
        for split in host.splitViews {
          let frame = split.convert(split.bounds, to: host.window.contentView)
          XCTAssertGreaterThanOrEqual(frame.minX, -1, "\(Int(size.width)): the split view starts inside")
          XCTAssertLessThanOrEqual(frame.maxX, content.maxX + 1, "\(Int(size.width)): and ends inside")
        }
        // No sidebar: the page starts at the window's leading edge.
        let page = try XCTUnwrap(host.pageScrollView)
        XCTAssertLessThan(
          page.convert(page.bounds, to: host.window.contentView).minX, 40, "\(Int(size.width))")
      }
    }
  }

  func testTheWindowTitleAndSubtitleNameThePlaceAndFollowIt() async throws {
    try await withShellHost(store: try await busyStore()) { host in
      host.layout(at: NSSize(width: 1240, height: 800))
      try await host.settle { host.window.title == "All wallpapers" }
      XCTAssertEqual(host.window.subtitle, "8 wallpapers", "the title bar says how many are shown")

      // Settings searches in the same search bar as the other pages.
      XCTAssertTrue(host.hasPageSearchField)
      host.navigation.selection = .settings
      try await host.settle { host.window.title == "Quick Settings" && host.hasPageSearchField }
      XCTAssertEqual(host.window.subtitle, "", "Settings has no count")

      host.navigation.selection = .workshop
      try await host.settle { host.window.title == "Steam Workshop" }
      host.navigation.selection = .pixiv
      try await host.settle { host.window.title == "pixiv" }
    }
  }

  func testEveryLibraryPageOffersTheTargetMenuAndTheInspectorToggleAndSettingsOffersNeither()
    async throws
  {
    try await withShellHost(store: try await busyStore()) { host in
      host.layout(at: NSSize(width: 1240, height: 800))
      try await host.settle(400)
      XCTAssertEqual(
        host.contentToolbarItems.count, 4,
        "the app's name, the tabs, the target display menu and the toggle")
      host.navigation.selection = .settings
      try await host.settle(400)
      XCTAssertEqual(host.contentToolbarItems.count, 2, "the app's name and the tabs")
    }
  }

  // MARK: Narrow windows

  /// A store with eight wallpapers and nothing to report: no banner takes room above the grid.
  private func quietStore() async throws -> BridgeStore {
    let (store, bridge) = makeStore()
    try await ShellFixtures.seed(store, bridge: bridge)
    return store
  }

  /// Where scroll bars take room (a mouse attached, or "Show scroll bars: Always"), eight tiles come
  /// within a scroll bar's width of fitting the grid at some height of every narrow window: with the
  /// bar they are narrower and fit, without it they are wider and do not. The grid flipped between
  /// the two on every layout pass and reported each flip, which asked for another pass, until AppKit
  /// ended the app. A crash here ends the test run, so it is the failure.
  ///
  /// The window opens at a saved narrow frame, as `setFrameUsingName` restores one, and is then
  /// resized across every height in the band.
  func testInstalledLaysOutInANarrowWindowOpenedWhereScrollBarsTakeRoom() async throws {
    for width in [760.0, 860.0] {
      try await withShellHost(store: try await quietStore()) { host in
        host.scrollBarsTakeRoom = true
        let frame = host.window.frameRect(
          forContentRect: NSRect(origin: .zero, size: NSSize(width: width, height: 560)))
        host.window.setFrame(frame, display: false)
        host.layoutWindow()
        try await host.settle(100)
        XCTAssertLessThanOrEqual(host.widestSplitView, width + 1, "opened at \(Int(width))")
        try await sweepHeights(of: host, width: width)
      }
    }
  }

  /// The same from a wide window with the inspector open, which a zoom or a tiling jump takes to
  /// the narrow width at once.
  func testInstalledLaysOutWhenTheWindowJumpsToANarrowWidthWhereScrollBarsTakeRoom() async throws {
    try await withShellHost(store: try await quietStore()) { host in
      host.scrollBarsTakeRoom = true
      host.layout(at: NSSize(width: 1240, height: 800))
      try await host.settle(300)
      for width in [760.0, 860.0] {
        host.layout(at: NSSize(width: width, height: 560))
        try await sweepHeights(of: host, width: width)
        host.layout(at: NSSize(width: 1240, height: 800))
        try await host.settle(300)
      }
    }
  }

  /// Resizes the window through the heights at which the grid goes from needing a scroll bar to
  /// fitting: the band, below the height that holds all of its content, that the bar's width opens
  /// in the content's height. The band is found by laying out a window tall enough for everything,
  /// since where it falls depends on what else the page draws, and walked in steps smaller than it.
  private func sweepHeights(of host: ShellHost, width: CGFloat) async throws {
    let tall = 1000.0
    host.layout(at: NSSize(width: width, height: tall))
    // The page has the window's whole width once the inspector has closed, and the grid all of the
    // page's once nothing needs a scroll bar.
    try await host.settle {
      host.pageScrollView?.documentView.map { $0.frame.width > width - 1 } ?? false
    }
    let scrollView = try XCTUnwrap(host.pageScrollView)
    let fits = try XCTUnwrap(scrollView.documentView).frame.height + (tall - scrollView.frame.height)
    var barShown: Set<Bool> = []
    for height in stride(from: max(560.0, fits - 40), through: fits + 10, by: 2) {
      host.layout(at: NSSize(width: width, height: height))
      try await host.settle(10)
      barShown.insert(host.pageScrollView?.verticalScroller?.isHidden == false)
      XCTAssertLessThanOrEqual(
        host.widestSplitView, width + 1, "\(Int(width)) x \(Int(height))")
    }
    XCTAssertEqual(
      barShown, [false, true], "\(Int(width)): the sweep crosses where the grid starts to need a bar")
  }

  func testTheDownloadsButtonKeepsItsPlaceInTheToolbarOfTheSmallestWindowWhileAJobRuns()
    async throws
  {
    try await withPanel { panel in
      let controller = panel.controller
      // A download that has started and waits for its password: the job stays in flight. SteamCMD
      // is chosen before the library is read, which keeps SteamCMD's setup busy for a moment.
      panel.workshop.steamCMDSetup.selectExisting(at: panel.executable)
      try await panel.waitUntil(timeout: 15) { panel.workshop.steamCMDSetup.selectedRuntime != nil }
      let wanted = WorkshopItem(
        id: "222", title: "Local video", creator: "Fixture", summary: "", previewURL: nil,
        tags: ["Video"], size: 0, subscriptions: 0)
      panel.workshop.selectedItem = wanted
      panel.workshop.username = "localtest"
      controller.remembersSession = false
      try await controller.requestDownload(item: wanted)
      try await panel.waitUntil(timeout: 15) {
        panel.workshop.downloader.download(for: "222")?.worker.prompt == .password
      }
      controller.downloads.closeDialog()
      XCTAssertTrue(DownloadsToolbarButton.isActive(in: controller))
      try await ShellFixtures.seed(panel.store, bridge: panel.bridge)

      let host = ShellFixtureHost(panel: panel)
      defer { host.close() }
      for size in [NSSize(width: 760, height: 560), NSSize(width: 960, height: 640)] {
        host.layout(at: size)
        try await host.settle(600)
        let note = "\(Int(size.width))"
        let items = host.contentToolbarItems
        XCTAssertEqual(
          items.count, 5,
          "\(note): the app's name, the tabs, the target display menu, Downloads and the toggle")
        let visible = Set((host.window.toolbar?.visibleItems ?? []).map(ObjectIdentifier.init))
        for item in items {
          XCTAssertTrue(
            visible.contains(ObjectIdentifier(item)),
            "\(note): \(item.itemIdentifier.rawValue) is in the toolbar, not in its overflow menu")
        }
        XCTAssertFalse(host.window.title.isEmpty, note)
      }
    }
  }

  func testTheInspectorClosesInANarrowWindowOpensWhenItGrowsAndABannerNeverWidensTheLayout()
    async throws
  {
    try await withPanel { panel in
      try await ShellFixtures.seed(panel.store, bridge: panel.bridge)
      panel.store.latestBridgeErrorMessage = longError
      panel.store.latestBridgeErrorRevision &+= 1
      panel.store.appSnapshot.heldWallpaperIds = ["w6"]
      let host = ShellFixtureHost(panel: panel)
      let shell = panel.controller.shell
      defer { host.close() }

      host.layout(at: NSSize(width: 1240, height: 800))
      try await host.settle(400)
      XCTAssertFalse(shell.isCompact)
      XCTAssertTrue(shell.isInspectorShown)

      host.layout(at: NSSize(width: 760, height: 560))
      try await host.settle(900)
      XCTAssertTrue(shell.isCompact)
      XCTAssertFalse(shell.isInspectorShown, "there is no room for it beside a readable grid")
      XCTAssertLessThanOrEqual(host.widestSplitView, 761)

      // The person opens it anyway: the long banners wrap instead of widening the page.
      shell.isInspectorShown = true
      try await host.settle(600)
      XCTAssertTrue(shell.isInspectorShown)
      XCTAssertLessThanOrEqual(host.widestSplitView, 761, "an open inspector and banners still fit")

      host.layout(at: NSSize(width: 1240, height: 800))
      try await host.settle(900)
      XCTAssertFalse(shell.isCompact)
      XCTAssertTrue(shell.isInspectorShown, "the person's choice holds")
    }
  }

  func testShrinkingTheWindowStepByStepWithBannersAndTheInspectorOpenNeverBreaksTheLayout()
    async throws
  {
    try await withPanel { panel in
      try await ShellFixtures.seed(panel.store, bridge: panel.bridge)
      panel.store.latestBridgeErrorMessage = longError
      panel.store.latestBridgeErrorRevision &+= 1
      panel.store.appSnapshot.heldWallpaperIds = ["w6"]
      let host = ShellFixtureHost(panel: panel)
      let shell = panel.controller.shell
      defer { host.close() }
      host.layout(at: NSSize(width: 1240, height: 800))
      try await host.settle(300)
      shell.isInspectorShown = true

      var width = 1240.0
      while width > 760 {
        host.layout(at: NSSize(width: width, height: 640))
        try await host.settle(50)
        XCTAssertLessThanOrEqual(host.widestSplitView, width + 1, "\(Int(width))")
        width -= 23
      }
      host.layout(at: NSSize(width: 760, height: 640))
      try await host.settle(300)
      XCTAssertLessThanOrEqual(host.widestSplitView, 761)
    }
  }

  func testTheFiltersSidebarAndTheInspectorFitTheWindowAtEveryWidth() async throws {
    try await withPanel { panel in
      try await ShellFixtures.seed(panel.store, bridge: panel.bridge)
      let host = ShellFixtureHost(panel: panel)
      let shell = panel.controller.shell
      defer { host.close() }
      host.layout(at: NSSize(width: 1240, height: 800))
      try await host.settle(300)
      shell.setFiltersShown(true)
      try await host.settle(600)
      XCTAssertTrue(shell.areFiltersShown)
      XCTAssertTrue(shell.isInspectorShown, "a wide window has room for both")
      XCTAssertLessThanOrEqual(host.widestSplitView, 1241)

      var width = 1240.0
      while width > 760 {
        host.layout(at: NSSize(width: width, height: 640))
        try await host.settle(50)
        XCTAssertLessThanOrEqual(host.widestSplitView, width + 1, "\(Int(width))")
        width -= 37
      }
      host.layout(at: NSSize(width: 760, height: 640))
      try await host.settle(900)
      XCTAssertLessThanOrEqual(host.widestSplitView, 761, "both open in the narrowest window")
    }
  }

  // MARK: Popovers and keyboard

  func testChangingThePageClosesAnOpenPopover() async throws {
    try await withPanel { panel in
      try await ShellFixtures.seed(panel.store, bridge: panel.bridge)
      let host = ShellFixtureHost(panel: panel)
      let shell = panel.controller.shell
      defer { host.close() }
      host.layout(at: NSSize(width: 1240, height: 800))
      try await host.settle(300)
      shell.popover(.history).wrappedValue = true
      XCTAssertTrue(shell.isPopoverOpen)
      panel.navigation.selection = .settings
      try await host.settle(300)
      XCTAssertFalse(shell.isPopoverOpen, "a popover belongs to the page it was opened on")
    }
  }

  func testCommandFPutsTheKeyboardInTheSearchFieldOfEveryPage() async throws {
    try await withPanel { panel in
      let host = ShellFixtureHost(panel: panel)
      defer { host.close() }
      let controller = panel.controller
      controller.presentation.attach(to: host.window)
      defer { controller.presentation.attach(to: nil) }
      host.layout(at: NSSize(width: 1240, height: 800))
      try await host.settle(300)
      for selection in [SidebarSelection.wallpaper, .workshop, .pixiv, .settings] {
        await controller.shell.open(selection).value
        try await host.settle { PanelSearchFocus.field(in: host.window) != nil }
        host.window.makeFirstResponder(nil)
        XCTAssertTrue(controller.shell.focusSearch(), "\(selection)")
        let field = try XCTUnwrap(PanelSearchFocus.field(in: host.window))
        let editor = host.window.firstResponder as? NSTextView
        XCTAssertTrue(
          editor?.isFieldEditor == true && editor?.delegate === field,
          "\(selection): the page's field is being edited")
      }
    }
  }

  func testThePageSearchFieldIsNamedForWhatItSearches() async throws {
    try await withPanel { panel in
      let host = ShellFixtureHost(panel: panel)
      defer { host.close() }
      host.layout(at: NSSize(width: 1240, height: 800))
      let names: [(SidebarSelection, String)] = [
        (.wallpaper, L("Search installed wallpapers")), (.workshop, L("Search Steam Workshop")),
        (.pixiv, L("Search pixiv by tag")), (.wallpaper, L("Search installed wallpapers")),
      ]
      for (selection, name) in names {
        await panel.controller.shell.open(selection).value
        try await host.settle {
          PanelSearchFocus.field(in: host.window)?.accessibilityLabel() == name
        }
      }
    }
  }

  func testTheImportPillLeavesTheToolbarOnceItsReportHasBeenSeen() async throws {
    try await withPanel { panel in
      try await ShellFixtures.seed(panel.store, bridge: panel.bridge)
      let host = ShellFixtureHost(panel: panel)
      defer { host.close() }
      host.layout(at: NSSize(width: 1240, height: 800))
      try await host.settle(400)
      let idle = host.contentToolbarItems.count

      try await panel.importOneWallpaper()
      try await host.settle(400)
      XCTAssertEqual(host.contentToolbarItems.count, idle + 1, "the pill reports the finished import")

      // Opened from the pill and closed in the same turn, so no popover is drawn offscreen.
      let library = panel.controller.library
      library.openImport(from: .pill)
      library.closeImport()
      try await host.settle(400)
      XCTAssertEqual(host.contentToolbarItems.count, idle, "seen: the pill has gone")
    }
  }

  // MARK: The Now Playing card and the sidebar

  func testTheSidebarShowsTheCardOfTheTargetDisplayWithItsArtwork() async throws {
    try await withPanel { panel in
      try await ShellFixtures.seed(panel.store, bridge: panel.bridge, library: panel.library, count: 3)
      let host = ShellFixtureHost(panel: panel)
      defer { host.close() }
      host.layout(at: NSSize(width: 1240, height: 800))
      try await host.settle(timeout: 10) { panel.controller.nowPlaying.item?.still != nil }
      let card = panel.controller.nowPlaying
      XCTAssertEqual(card.item?.title, ShellFixtures.titles[0])
      let image = try host.png()
      XCTAssertGreaterThan(image.count, 2_000, "something was drawn")
    }
  }

  func testTheNowPlayingBarKeepsItsHeightWhateverTheTargetDisplayShows() async throws {
    try await withPanel { panel in
      @MainActor func height(width: CGFloat) -> CGFloat {
        let hosting = NSHostingView(
          rootView: NowPlayingBar()
            .environment(panel.controller)
            .panelTheme(theme: panel.controller.theme, locale: PanelLocale.shared)
            .frame(width: width))
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: 10)
        hosting.layoutSubtreeIfNeeded()
        return hosting.fittingSize.height
      }
      try await ShellFixtures.seed(panel.store, bridge: panel.bridge)
      XCTAssertNotNil(panel.controller.nowPlaying.item)
      for width: CGFloat in [760, 1240] {
        XCTAssertEqual(height(width: width), NowPlayingBar.height, accuracy: 0.5)
      }
      try await ShellFixtures.seed(panel.store, bridge: panel.bridge, primary: nil, secondary: nil)
      XCTAssertNil(panel.controller.nowPlaying.item)
      XCTAssertEqual(
        height(width: 760), NowPlayingBar.height, accuracy: 0.5,
        "the hint keeps to one line instead of growing the bar")
    }
  }

  func testTheNowPlayingDetailsOpenAboveTheBarAndOnePopoverIsOpenAtATime() async throws {
    try await withPanel { panel in
      let shell = panel.controller.shell
      try await ShellFixtures.seed(panel.store, bridge: panel.bridge)
      shell.popover(.nowPlaying).wrappedValue = true
      XCTAssertTrue(shell.isPopoverOpen, "the support prompt waits behind the details")
      shell.popover(.history).wrappedValue = true
      XCTAssertFalse(shell.popover(.nowPlaying).wrappedValue, "Recently used replaces them")
      let hosting = NSHostingView(
        rootView: NowPlayingDetails()
          .environment(panel.controller)
          .environment(\.panelImages, panel.controller.images)
          .panelTheme(theme: panel.controller.theme, locale: PanelLocale.shared))
      hosting.layoutSubtreeIfNeeded()
      XCTAssertEqual(hosting.fittingSize.width, NowPlayingDetails.width, accuracy: 1)
    }
  }

  func testTheCollectionsNoticeWrapsALongSentence() {
    func height(_ text: String) -> CGFloat {
      let hosting = NSHostingView(rootView: CollectionsNote(Text(verbatim: text)).frame(width: 160))
      hosting.frame = NSRect(x: 0, y: 0, width: 160, height: 10)
      hosting.layoutSubtreeIfNeeded()
      return hosting.fittingSize.height
    }
    let line = height("Deleted “Night”.")
    let long = height("Deleted “A very long collection name that does not fit one line”.")
    XCTAssertGreaterThan(long, line * 1.8, "the whole sentence is shown")
  }
}
