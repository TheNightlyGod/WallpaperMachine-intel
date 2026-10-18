import AppKit
import SwiftUI
import XCTest

@testable import WallpaperMachine

/// The inspector drawn offscreen in windows that are never shown: it takes the size it is given in
/// every shipped language and both appearances, never makes the panel's split view wider than its
/// window, and the controls it draws reach the controller (sliders by key, VoiceOver and pointer).
@MainActor
final class InspectorRenderTests: InspectorTestCase {
  override func tearDown() async throws {
    PanelLocale.shared.bind(to: .testHost)
    try await super.tearDown()
  }

  private func settle(_ milliseconds: Int = 300) async throws {
    try await Task.sleep(for: .milliseconds(milliseconds))
  }

  private func prepare(_ fixture: InspectorRenderFixture) async throws {
    try await fixture.panel.start()
    fixture.panel.show()
    _ = fixture.controller.libraryRows
    try await fixture.panel.waitUntil(timeout: 10) { fixture.controller.libraryMetrics.measured.count == 4 }
    _ = fixture.controller.libraryRows
  }

  /// Every view of a type below `root`.
  private func views<T: NSView>(_ type: T.Type, in root: NSView) -> [T] {
    var found: [T] = []
    func walk(_ view: NSView) {
      if let match = view as? T { found.append(match) }
      view.subviews.forEach(walk)
    }
    walk(root)
    return found
  }

  /// The inspector as the panel's window content, in a window made the way the app makes it.
  private func windowHosting(
    _ fixture: InspectorRenderFixture, size: NSSize, dark: Bool
  ) -> (window: NSWindow, hosting: NSHostingController<AnyView>) {
    let controller = fixture.controller
    let hosting = NSHostingController(
      rootView: AnyView(
        InstalledInspector()
          .environment(controller)
          .environment(\.panelImages, controller.images)
          .environment(\.panelIsVisible, true)
          .panelTheme(theme: controller.theme, locale: PanelLocale.shared)))
    hosting.sizingOptions = []
    let window = ControlPanelWindow.make(contentViewController: hosting, delegate: nil)
    window.setContentSize(size)
    hosting.view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    window.layoutIfNeeded()
    hosting.view.layoutSubtreeIfNeeded()
    return (window, hosting)
  }

  // MARK: Layout

  func testTheInspectorAcceptsTheWindowItIsGivenInEveryLanguageAndAppearance() async throws {
    let fixture = try InspectorRenderFixture()
    try await prepare(fixture)
    for language in AppLanguage.supported.map(\.tag) {
      let languages = AppLanguageStore(
        defaults: TemporaryDefaults.makeForCurrentTest().defaults, systemLanguages: [language])
      PanelLocale.shared.bind(to: languages)
      for dark in [false, true] {
        for size in [NSSize(width: 760, height: 560), NSSize(width: 1240, height: 800)] {
          let (window, hosting) = windowHosting(fixture, size: size, dark: dark)
          try await settle()
          hosting.view.layoutSubtreeIfNeeded()
          let measured = hosting.sizeThatFits(in: size)
          XCTAssertLessThanOrEqual(
            measured.width, size.width + 1,
            "\(language) \(dark ? "dark" : "light"): the inspector must not ask for more width")
          XCTAssertLessThanOrEqual(
            measured.height, size.height + 1, "\(language): and it scrolls, so no more height")
          XCTAssertFalse(window.isVisible, "layout stays offscreen")
          XCTAssertFalse(
            views(PanelNSSlider.self, in: hosting.view).isEmpty,
            "\(language): the options were drawn, not just the loading line")
          window.contentViewController = nil
          window.close()
        }
      }
    }
    await fixture.shutdown()
  }

  func testTheEmptyInspectorAsksForASelectionInTheWindowToo() async throws {
    let fixture = try InspectorRenderFixture()
    fixture.store.appSnapshot.selectedWallpaperId = nil
    try await fixture.panel.start()
    let (window, hosting) = windowHosting(
      fixture, size: ControlPanelWindow.minimumContentSize, dark: false)
    try await settle()
    hosting.view.layoutSubtreeIfNeeded()
    XCTAssertLessThanOrEqual(hosting.sizeThatFits(in: ControlPanelWindow.minimumContentSize).width, 761)
    XCTAssertTrue(views(PanelNSSlider.self, in: hosting.view).isEmpty, "nothing selected, nothing to adjust")
    window.contentViewController = nil
    window.close()
    await fixture.shutdown()
  }

  /// The whole panel with the inspector open beside the Installed page: the 260-point column and the
  /// content inside it must not push the split view past the window (the trap F-C found).
  func testThePanelWithTheInspectorOpenFitsItsWindowAtTheSmallestSizeInEveryLanguage() async throws {
    let fixture = try InspectorRenderFixture()
    for language in AppLanguage.supported.map(\.tag) {
      let languages = AppLanguageStore(
        defaults: fixture.panel.defaults, systemLanguages: [language])
      let navigation = ControlPanelNavigation(selection: .wallpaper)
      let hosting = NSHostingController(
        rootView: ControlPanelView(
          store: fixture.store, navigation: navigation, workshop: fixture.panel.workshop,
          pixiv: PixivStore(),
          updater: AppUpdateStore(currentVersion: "0.1.0", client: DisabledAppUpdateClient()),
          imports: LibraryImportStore(), defaults: fixture.panel.defaults, appLanguage: languages))
      hosting.sizingOptions = []
      hosting.sceneBridgingOptions = [.toolbars, .title]
      let window = ControlPanelWindow.make(contentViewController: hosting, delegate: nil)
      for size in [ControlPanelWindow.minimumContentSize, ControlPanelWindow.initialContentSize] {
        window.setContentSize(size)
        window.layoutIfNeeded()
        hosting.view.layoutSubtreeIfNeeded()
        try await settle(500)
        hosting.view.layoutSubtreeIfNeeded()
        var widest: CGFloat = 0
        func walk(_ view: NSView) {
          if let split = view as? NSSplitView { widest = max(widest, split.frame.width) }
          view.subviews.forEach(walk)
        }
        walk(window.contentView!)
        XCTAssertLessThanOrEqual(
          widest, size.width + 1,
          "\(language) at \(Int(size.width)): the inspector's content must not widen the panel")
        XCTAssertLessThanOrEqual(hosting.sizeThatFits(in: size).width, size.width + 1)
      }
      window.contentViewController = nil
      window.close()
    }
    await fixture.shutdown()
  }

  // MARK: The narrowest window

  /// A library too short to fill the Installed page: four wallpapers, whose grid is about as tall
  /// as its scroll view at some window widths.
  private func makeShortLibraryPanel() async throws -> PanelFixture {
    let panel = try makeController()
    panel.show()
    try panel.installLibrary(
      (0..<4).map {
        LibrarySpec("item\($0)", "Wallpaper \($0)", kind: .projectScene, preview: .picture(Double($0) / 4))
      })
    panel.configureDisplays()
    panel.showOnPrimary("item1")
    try await panel.loadLibrary()
    try await panel.settleLibrary()
    panel.store.appSnapshot.selectedWallpaperId = "item1"
    return panel
  }

  /// The whole panel in a window made the way the app makes it, never ordered front. The window's
  /// toolbar is left out: its title view logs AppKit constraint conflicts while any panel window is
  /// first laid out, which XCTest records, and nothing here is about the toolbar.
  private func panelWindow(_ panel: PanelFixture, size: NSSize, dark: Bool = false) -> (
    window: NSWindow, hosting: NSHostingController<AnyView>
  ) {
    let controller = panel.controller
    let hosting = NSHostingController(
      rootView: AnyView(
        PanelRootView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .environment(controller)
          .environment(\.panelImages, controller.images)))
    hosting.sizingOptions = []
    hosting.sceneBridgingOptions = []
    let window = ControlPanelWindow.make(contentViewController: hosting, delegate: nil)
    hosting.view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    lay(window, hosting, at: size)
    return (window, hosting)
  }

  private func lay(_ window: NSWindow, _ hosting: NSHostingController<AnyView>, at size: NSSize) {
    window.setContentSize(size)
    window.layoutIfNeeded()
    hosting.view.layoutSubtreeIfNeeded()
  }

  /// Gives every scroll view below `root` the scroll bars of a Mac set to always show them (or with
  /// a mouse), which take room from the content: a grid as tall as its scroll view then gains a
  /// scroll bar, narrows, gets shorter than the scroll view and loses it again.
  private func showScrollBarsAlways(in root: NSView) {
    for scrollView in views(NSScrollView.self, in: root) {
      scrollView.scrollerStyle = .legacy
      scrollView.autohidesScrollers = true
    }
  }

  private func widestSplitView(in window: NSWindow) -> CGFloat {
    views(NSSplitView.self, in: window.contentView!).map(\.frame.width).max() ?? 0
  }

  /// Lays the window out until `condition` has held for a few passes in a row, for at most a few
  /// seconds. A window just made, resized or toggled settles over several passes, and the split
  /// view reports the inspector it shows back to the shell along the way.
  private func layOut(
    _ window: NSWindow, _ hosting: NSHostingController<AnyView>, until condition: () -> Bool
  ) async throws {
    let deadline = Date().addingTimeInterval(8)
    var held = 0
    while held < 3, Date() < deadline {
      try await settle(100)
      window.layoutIfNeeded()
      hosting.view.layoutSubtreeIfNeeded()
      held = condition() ? held + 1 : 0
    }
  }

  /// At the smallest window the inspector column beside the Installed page leaves the page about
  /// 250 points. A new window made at that size, and one shrunk to it from the first size, start
  /// with the inspector closed (the person has not chosen yet); the toolbar's button then shows it
  /// beside the page and hides it again, in both appearances, and the panel stays inside its window.
  func testThePanelAtItsSmallestWindowShowsTheInspectorBesideANarrowPage() async throws {
    let smallest = ControlPanelWindow.minimumContentSize
    for dark in [false, true] {
      for madeSmall in [true, false] {
        let context = "\(dark ? "dark" : "light"), \(madeSmall ? "made small" : "shrunk")"
        // A new window is a new controller, with no choice of the person's about the inspector.
        let panel = try await makeShortLibraryPanel()
        let shell = panel.controller.shell
        let library = panel.controller.library
        let pageWidth = { library.geometry.viewport.width }
        // The page beside the inspector: the window less the column.
        let isBeside = { (380...520).contains(pageWidth()) }
        let isAlone = { pageWidth() > 600 }
        let (window, hosting) = panelWindow(
          panel, size: madeSmall ? smallest : ControlPanelWindow.initialContentSize, dark: dark)
        if !madeSmall {
          try await layOut(window, hosting) { shell.isInspectorShown && pageWidth() > 600 }
          lay(window, hosting, at: smallest)
        }
        try await layOut(window, hosting) { shell.isCompact && !shell.isInspectorShown && isAlone() }
        XCTAssertFalse(shell.isInspectorShown, "\(context): a narrow window starts without it")
        XCTAssertTrue(isAlone(), "\(context): the page takes the room")

        // What the toolbar's button does.
        shell.isInspectorShown.toggle()
        try await layOut(window, hosting, until: isBeside)
        XCTAssertTrue(isBeside(), "\(context): the inspector opens beside the page, not \(pageWidth())")
        XCTAssertLessThanOrEqual(widestSplitView(in: window), smallest.width + 1, context)
        shell.isInspectorShown.toggle()
        try await layOut(window, hosting, until: isAlone)
        XCTAssertTrue(isAlone(), "\(context): and closes again, not \(pageWidth())")
        shell.isInspectorShown.toggle()
        try await layOut(window, hosting, until: isBeside)
        XCTAssertTrue(isBeside(), "\(context): and opens again, not \(pageWidth())")
        XCTAssertLessThanOrEqual(widestSplitView(in: window), smallest.width + 1, context)
        XCTAssertFalse(window.isVisible, "layout stays offscreen")
        window.contentViewController = nil
        window.close()
        await panel.shutdown()
      }
    }
  }

  /// Every width from the first size down to the smallest and back, with the inspector closed and
  /// open, over a grid about as tall as its scroll view at some of them, with scroll bars that take
  /// room. A scroll bar coming and going used to change what the Installed grid reported about its
  /// scrolling on every layout pass, and each report asked the window for another pass from inside
  /// the pass, until AppKit gave up with "needing another Update Constraints in Window pass" and the
  /// app ended. A crash here fails the run.
  func testResizingThePanelOverAShortLibraryWithScrollBarsThatTakeRoomNeverLoopsItsLayout() async throws {
    let panel = try await makeShortLibraryPanel()
    defer { Task { await panel.shutdown() } }
    let shell = panel.controller.shell
    let first = ControlPanelWindow.initialContentSize
    let smallest = ControlPanelWindow.minimumContentSize
    let (window, hosting) = panelWindow(panel, size: first)
    try await settle(500)
    for open in [false, true] {
      shell.isInspectorShown = open
      try await settle(300)
      let down = stride(from: first.width, through: smallest.width, by: -4)
      let up = stride(from: smallest.width, through: first.width, by: 4)
      for width in Array(down) + Array(up) {
        lay(window, hosting, at: NSSize(width: width, height: smallest.height))
        showScrollBarsAlways(in: hosting.view)
        hosting.view.layoutSubtreeIfNeeded()
        // The window's display cycle, where the passes run.
        try await settle(15)
      }
      XCTAssertEqual(shell.isInspectorShown, open)
      XCTAssertLessThanOrEqual(widestSplitView(in: window), first.width + 1)
    }
    XCTAssertFalse(window.isVisible, "layout stays offscreen")
    window.contentViewController = nil
    window.close()
  }

  // MARK: VoiceOver

  /// What a test hears in place of VoiceOver.
  private final class Heard {
    var lines: [String] = []
  }

  /// Every element of the accessibility tree below `root`, as assistive apps walk it.
  private func accessibilityElements(in root: NSView) -> [NSAccessibilityProtocol] {
    var found: [NSAccessibilityProtocol] = []
    func walk(_ element: NSAccessibilityProtocol, depth: Int) {
      found.append(element)
      guard depth < 60 else { return }
      for case let child as NSAccessibilityProtocol in element.accessibilityChildren() ?? [] {
        walk(child, depth: depth + 1)
      }
    }
    walk(root, depth: 0)
    return found
  }

  /// The footer's sentence is a status line, as the page's was: the edit that leaves something to
  /// apply is said aloud, not only drawn.
  func testTheFooterSaysAloudThatAnEditLeftSomethingToApply() async throws {
    let fixture = try InspectorRenderFixture()
    try await prepare(fixture)
    let sentence = "You have unapplied changes."
    let heard = Heard()
    let (window, view) = fixture.host(size: NSSize(width: 360, height: 1400)) {
      InstalledInspector().environment(\.panelAnnouncer, PanelAnnouncer { heard.lines.append($0) })
    }
    try await settle(600)
    view.layoutSubtreeIfNeeded()
    XCTAssertEqual(fixture.controller.inspectorOptions(for: InspectorRenderFixture.selected)?.hasChanges, false)
    XCTAssertFalse(heard.lines.contains(sentence), "nothing to apply yet")

    fixture.store.wallpaperOptionsSnapshot?.dirty = true
    try await fixture.panel.waitUntil(timeout: 5) {
      view.layoutSubtreeIfNeeded()
      return heard.lines.contains(sentence)
    }
    XCTAssertEqual(heard.lines.filter { $0 == sentence }.count, 1, "said once")
    window.contentView = nil
    await fixture.shutdown()
  }

  /// VoiceOver meets the Position on screen frame as a draggable picture that says where the picture
  /// sits on which display, and its increment moves the picture a step, as an arrow key does.
  func testThePositionFrameIsADraggablePictureToVoiceOver() async throws {
    let fixture = try InspectorRenderFixture()
    try await prepare(fixture)
    let state = ImagePlacementState(
      wallpaperID: "image-a.png", displayID: "primary", displayTitle: "Studio Display",
      isSupported: true, reason: nil, x: 0.5, y: 0.5, zoom: 1, isCustomized: false, fit: .fill,
      imagePixelSize: CGSize(width: 1600, height: 900), imageAspectRatio: 16.0 / 9,
      displayAspectRatio: 16.0 / 10, displayViewportSize: CGSize(width: 1440, height: 900),
      displayPixelSize: CGSize(width: 2880, height: 1800))
    let (window, view) = fixture.host(size: NSSize(width: 320, height: 900)) {
      PlacementCard(state: state, row: LibraryRows.row("image-a.png", kind: .web))
    }
    try await settle(300)
    view.layoutSubtreeIfNeeded()
    let picture = try XCTUnwrap(
      accessibilityElements(in: view).first { $0.accessibilityRoleDescription() == "draggable picture" },
      "the frame calls itself a draggable picture")
    XCTAssertEqual(picture.accessibilityRole(), .image)
    let label = picture.accessibilityLabel() ?? ""
    XCTAssertTrue(label.hasPrefix("Picture position on Studio Display: 50% across, 50% down"), label)

    XCTAssertTrue(picture.accessibilityPerformIncrement())
    XCTAssertEqual(
      fixture.controller.inspector.placement.values(for: state).x, 0.51, accuracy: 0.0001,
      "a step to the right, as the right arrow key moves it")
    window.contentView = nil
    await fixture.shutdown()
  }

  // MARK: The controls reach the controller

  private func slider(
    _ label: String, in view: NSView
  ) throws -> PanelNSSlider {
    try XCTUnwrap(
      views(PanelNSSlider.self, in: view).first { $0.accessibilityLabel() == label },
      "the \(label) slider")
  }

  func testAPropertySliderTheInspectorDrawsSavesVoiceOverKeyAndPointerChanges() async throws {
    let fixture = try InspectorRenderFixture()
    try await prepare(fixture)
    let (window, view) = fixture.host(size: NSSize(width: 360, height: 1400))
    try await settle(600)
    view.layoutSubtreeIfNeeded()
    let count = try slider("Particle count", in: view)
    XCTAssertEqual(count.doubleValue, 120)
    XCTAssertEqual(count.step, 10)

    // VoiceOver: one step saves one edit, with no preview.
    XCTAssertTrue(count.accessibilityPerformIncrement())
    try await fixture.panel.waitUntil(timeout: 5) { fixture.bridge.edits.count == 1 }
    XCTAssertEqual(fixture.bridge.edits.last, .init(propertyId: "count", value: .number(value: 130)))
    XCTAssertTrue(fixture.store.editorState.propertyPreviewValues.isEmpty)
    XCTAssertNil(fixture.controller.errors.message)

    // A key press the same.
    count.keyDown(
      with: NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
        context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 123)!)
    try await fixture.panel.waitUntil(timeout: 5) { fixture.bridge.edits.count == 2 }
    XCTAssertEqual(fixture.bridge.edits.last, .init(propertyId: "count", value: .number(value: 120)))

    // The pointer drag shows steps, saves nothing until it is released, and then saves the value it
    // settled on and drops the step.
    let key = WallpaperEditorState.FieldKey(wallpaperID: "wp", fieldID: "count")
    count.beginPointer()
    count.doubleValue = 300
    count.valueDidChange(nil)
    try await fixture.panel.waitUntil(timeout: 5) {
      fixture.store.editorState.propertyPreviewValues[key] == .number(value: 300)
    }
    XCTAssertEqual(fixture.bridge.edits.count, 2, "dragging saves nothing")
    count.endPointer()
    try await fixture.panel.waitUntil(timeout: 5) { fixture.bridge.edits.count == 3 }
    XCTAssertEqual(fixture.bridge.edits.last, .init(propertyId: "count", value: .number(value: 300)))
    try await fixture.panel.waitUntil(timeout: 5) {
      fixture.store.editorState.propertyPreviewValues[key] == nil
    }
    XCTAssertNil(fixture.controller.errors.message)
    window.contentView = nil
    await fixture.shutdown()
  }
}
