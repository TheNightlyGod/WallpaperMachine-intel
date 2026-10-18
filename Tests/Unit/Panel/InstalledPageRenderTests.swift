import AppKit
import SwiftUI
import XCTest

@testable import WallpaperMachine

/// The Installed page drawn in a window that is never shown: it takes the size the window gives
/// it, in both appearances and every shipped language, with the states that have the most to say.
@MainActor
final class InstalledPageRenderTests: PanelTestCase {
  private static let sizes = [NSSize(width: 760, height: 560), NSSize(width: 1240, height: 800)]

  override func tearDown() async throws {
    // Each test bound the shared panel language to its fixture's own store.
    PanelLocale.shared.bind(to: .testHost)
    try await super.tearDown()
  }

  private func specs(count: Int = 14) -> [LibrarySpec] {
    (0..<count).map {
      LibrarySpec(
        "item\($0)", "A wallpaper with a rather long title number \($0)",
        kind: [.projectScene, .video, .webpage][$0 % 3], tags: ["Nature"], approved: $0 % 4 == 0,
        preview: .picture(Double($0) / Double(count)))
    }
  }

  private func prepare(_ panel: PanelFixture, count: Int = 14) async throws {
    panel.show()
    try panel.installLibrary(specs(count: count))
    panel.configureDisplays()
    panel.showOnPrimary("item1")
    try await panel.loadLibrary()
    try await panel.settleLibrary()
    panel.controller.favoriteIDs = ["item2"]
  }

  /// Asserts `hosted` takes the window's size and is not wider than it.
  private func assertFits(
    _ hosted: HostedPanel, _ size: NSSize, _ context: String, file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let measured = hosted.hosting.sizeThatFits(in: size)
    XCTAssertEqual(measured.width, size.width, accuracy: 1, "\(context): width", file: file, line: line)
    XCTAssertLessThanOrEqual(
      measured.height, size.height + 1, "\(context): must not force a taller window", file: file,
      line: line)
    XCTAssertLessThanOrEqual(
      hosted.widestSplitView, size.width + 1, "\(context): the panel must fit the window",
      file: file, line: line)
    XCTAssertFalse(hosted.window.isVisible, "layout stays offscreen", file: file, line: line)
  }

  func testThePageTakesTheWindowsSizeInBothAppearancesAndEveryLanguageWithoutAnAppKitException() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    try await prepare(panel)
    let model = panel.controller.library
    PanelLocale.shared.bind(to: panel.controller.appLanguage)
    for language in AppLanguage.supported.map(\.tag) {
      try panel.controller.appLanguage.set(language)
      for dark in [false, true] {
        let hosted = HostedPanel(panel, size: Self.sizes[1], dark: dark)
        for size in Self.sizes {
          hosted.layout(at: size)
          try await hosted.settle(0.3)
          hosted.layout(at: size)
          assertFits(hosted, size, "\(language), \(dark ? "dark" : "light"), \(Int(size.width))")
        }
        hosted.close()
      }
    }
    XCTAssertGreaterThanOrEqual(model.geometry.columns, 3)
  }

  func testTheGridMeasuresItselfSoThePressCanFindATileAndNeverUsesFewerThanThreeColumns() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    try await prepare(panel)
    let model = panel.controller.library
    let hosted = HostedPanel(panel, size: Self.sizes[1])
    try await hosted.settle(1.2)
    let geometry = model.geometry
    XCTAssertTrue(geometry.isMeasured, "a drawn tile reported its size, and the scroll view its own")
    XCTAssertGreaterThanOrEqual(geometry.columns, 3)
    XCTAssertGreaterThan(geometry.cellSize.width, 90)
    XCTAssertGreaterThan(geometry.cellSize.height, geometry.cellSize.width, "the caption is under the square")
    XCTAssertGreaterThan(geometry.viewport.height, 300)
    XCTAssertGreaterThan(geometry.contentHeight, 0)
    XCTAssertEqual(
      model.geometry.index(at: CGPoint(x: geometry.frame(ofIndex: 3).midX, y: geometry.frame(ofIndex: 3).midY), count: 14),
      3)

    hosted.layout(at: Self.sizes[0])
    try await hosted.settle(0.8)
    XCTAssertGreaterThanOrEqual(model.geometry.columns, 3, "never fewer than three")
    XCTAssertLessThan(model.geometry.viewport.width, geometry.viewport.width, "the page column is narrower")
    hosted.close()
  }

  /// Lays the hosted panel out until `condition` holds, or fails after a few seconds.
  private func waitFor(_ hosted: HostedPanel, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(6)
    while !condition() {
      guard Date() < deadline else { return }
      try await hosted.settle(0.1)
    }
  }

  func testAGridThatScrollsReportsItsOffsetAndComesBackToWhereItWas() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    try await prepare(panel, count: 60)
    let model = panel.controller.library
    var hosted = HostedPanel(panel, size: Self.sizes[1])
    try await hosted.settle(1.0)
    XCTAssertGreaterThan(model.geometry.maxOffset, 200, "sixty wallpapers do not fit")
    var scrolls: [CGFloat] = []
    let original = model.scrollGrid
    XCTAssertNotNil(original, "the page hands the model a way to scroll its grid")
    model.scrollGrid = { offset in
      scrolls.append(offset)
      original?(offset)
    }
    // Well inside the content (more than 200 points scroll, asserted above), so a lazy grid whose
    // estimated height is still settling cannot clamp it; waited for, not timed, under load.
    model.scrollGrid?(150)
    try await waitFor(hosted) { abs(model.scrollOffset - 150) <= 1 }
    XCTAssertEqual(model.scrollOffset, 150, accuracy: 1, "the scroll view's own report reaches the model")
    hosted.close()

    // Leaving and coming back: the page reads the offset from the model.
    // macOS 26 lands a restored lazy grid a few points short while its estimated height settles.
    hosted = HostedPanel(panel, size: Self.sizes[1])
    try await waitFor(hosted) { abs(model.geometry.offsetY - 150) <= 4 }
    XCTAssertEqual(model.geometry.offsetY, 150, accuracy: 4, "the grid scrolled back to where it was")
    hosted.close()

    // A restored offset past the end of the content comes back clamped to what the grid holds.
    model.scrolled(to: 1_000_000)
    hosted = HostedPanel(panel, size: Self.sizes[1])
    try await hosted.settle(1.5)
    XCTAssertEqual(
      model.geometry.offsetY, model.geometry.maxOffset, accuracy: 2, "clamped to the content")
    hosted.close()
  }

  func testTheFooterAndTheSelectionToolsFitTheNarrowestColumnInEveryLanguage() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    try await prepare(panel)
    let model = panel.controller.library
    _ = try panel.collections.create(name: "Night", wallpaperIDs: ["item3"])
    model.toggleSelecting()
    for id in ["item0", "item1", "item2"] { model.toggleChecked(id) }
    PanelLocale.shared.bind(to: panel.controller.appLanguage)
    for language in AppLanguage.supported.map(\.tag) {
      try panel.controller.appLanguage.set(language)
      for size in Self.sizes {
        let hosted = HostedPanel(panel, size: size)
        try await hosted.settle(0.5)
        hosted.layout(at: size)
        assertFits(hosted, size, "selection, \(language), \(Int(size.width))")
        hosted.close()
      }
    }
    model.beginNewCollection()
    let named = HostedPanel(panel, size: Self.sizes[0])
    try await named.settle(0.4)
    assertFits(named, Self.sizes[0], "naming a collection")
    named.close()
  }

  func testEveryEmptyStateFitsTheNarrowestWindowInEveryLanguage() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    try await prepare(panel)
    let model = panel.controller.library
    PanelLocale.shared.bind(to: panel.controller.appLanguage)
    let states: [() -> Void] = [
      { model.setText("zzz") }, { model.setRequired("Customizable", true) },
      { model.setRequired("Customizable", false); model.setText("") },
    ]
    for language in AppLanguage.supported.map(\.tag) {
      try panel.controller.appLanguage.set(language)
      for apply in states {
        apply()
        let hosted = HostedPanel(panel, size: Self.sizes[0])
        try await hosted.settle(0.3)
        assertFits(hosted, Self.sizes[0], "empty, \(language)")
        hosted.close()
      }
      model.clearSearchAndFilters()
    }
    let empty = try makeController()
    defer { Task { await empty.shutdown() } }
    empty.show()
    try await empty.loadLibrary()
    PanelLocale.shared.bind(to: empty.controller.appLanguage)
    XCTAssertEqual(empty.controller.library.emptyState, .emptyLibrary)
    for language in AppLanguage.supported.map(\.tag) {
      try empty.controller.appLanguage.set(language)
      let hosted = HostedPanel(empty, size: Self.sizes[0])
      try await hosted.settle(0.3)
      assertFits(hosted, Self.sizes[0], "empty library, \(language)")
      hosted.close()
    }
  }

  // MARK: What VoiceOver and the layout see

  /// One element of the accessibility tree, read the way an assistive app reads it. SwiftUI's
  /// elements answer the informal accessibility methods, so they are read by key.
  private struct Element {
    let object: NSObject

    private func string(_ key: String) -> String? {
      guard object.responds(to: NSSelectorFromString(key)) else { return nil }
      return object.value(forKey: key) as? String
    }

    var identifier: String? { string("accessibilityIdentifier") }
    var role: String? { string("accessibilityRole") }
    var label: String? { string("accessibilityLabel") }
    var value: Any? {
      object.responds(to: NSSelectorFromString("accessibilityValue"))
        ? object.value(forKey: "accessibilityValue") : nil
    }
    var frame: NSRect {
      guard object.responds(to: NSSelectorFromString("accessibilityFrame")) else { return .zero }
      return (object.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue ?? .zero
    }
  }

  /// Every element of the accessibility tree under `view`.
  private func accessibilityElements(in view: NSView) -> [Element] {
    var found: [Element] = []
    func visit(_ element: Any?, depth: Int) {
      guard depth < 60, let object = element as? NSObject else { return }
      found.append(Element(object: object))
      if object.responds(to: NSSelectorFromString("accessibilityChildren")),
        let children = object.value(forKey: "accessibilityChildren") as? [Any]
      {
        for child in children { visit(child, depth: depth + 1) }
      }
    }
    visit(view, depth: 0)
    return found
  }

  private func element(_ identifier: String, in view: NSView) -> Element? {
    accessibilityElements(in: view).first { $0.identifier == identifier }
  }

  func testTheActivePillSaysActiveInTheCornerAndMovesPastTheCheckOnlyWhileItShows() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    try await prepare(panel)
    let model = panel.controller.library
    let hosted = HostedPanel(panel, size: Self.sizes[1])
    try await hosted.settle(1.0)
    func frames() throws -> (tile: NSRect, pill: NSRect) {
      let tile = try XCTUnwrap(element("installed-tile-item1", in: hosted.hosting.view))
      let pill = try XCTUnwrap(element("installed-tile-active", in: hosted.hosting.view))
      return (tile.frame, pill.frame)
    }

    var (tile, pill) = try frames()
    XCTAssertEqual(pill.minX - tile.minX, 6, accuracy: 1, "at rest the pill sits in the corner")
    XCTAssertGreaterThan(pill.width, 40, "a tile of this size has room for the word")
    XCTAssertLessThanOrEqual(
      pill.maxX, tile.maxX - 6 - LibraryTileChrome.controlRoom + 1, "the heart's corner stays clear")

    model.toggleSelecting()
    try await hosted.settle(0.6)
    (tile, pill) = try frames()
    XCTAssertEqual(
      pill.minX - tile.minX, 6 + LibraryTileChrome.controlRoom, accuracy: 1,
      "every check shows in selection mode, and the pill moves past it")
    XCTAssertGreaterThan(pill.width, 40)

    // The narrowest window beside the inspector: the word goes before the heart's corner does.
    hosted.layout(at: Self.sizes[0])
    try await hosted.settle(0.8)
    (tile, pill) = try frames()
    XCTAssertLessThanOrEqual(pill.maxX, tile.maxX - 6 - LibraryTileChrome.controlRoom + 1)
    hosted.close()
  }

  func testFilterBoxesReachVoiceOverAsCheckboxesAndTagChipsAsButtons() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    try await prepare(panel)
    let model = panel.controller.library
    model.setIncluded("Web", false)
    model.setChip("Anime", .required)
    model.setChip("Nature", .excluded)
    let controller = panel.controller
    let hosting = NSHostingView(
      rootView: InstalledFilters()
        .environment(controller)
        .environment(\.panelImages, controller.images)
        .panelTheme(theme: controller.theme, locale: PanelLocale.shared))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 900), styleMask: [.borderless],
      backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    window.contentView = hosting
    defer {
      window.contentView = nil
      window.close()
    }
    hosting.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(300))
    hosting.layoutSubtreeIfNeeded()

    let checkboxes = accessibilityElements(in: hosting).filter {
      $0.role == NSAccessibility.Role.checkBox.rawValue
    }
    let sections = LibraryFilterCatalog.installedGroups.flatMap(\.sections)
    let boxes = sections.filter { !$0.isChips }.flatMap(\.entries).count
    let showOnly = LibraryFilterCatalog.showOnly.count
    XCTAssertEqual(
      checkboxes.count, showOnly + boxes, "every box is a checkbox; the Tags chips are not")
    let values = checkboxes.compactMap { ($0.value as? NSNumber)?.intValue }
    XCTAssertTrue(values.contains(0), "an unticked box reads as unchecked, not as a digit in a label")
    XCTAssertTrue(values.contains(1))

    let buttons = accessibilityElements(in: hosting).filter {
      $0.role == NSAccessibility.Role.button.rawValue
    }
    XCTAssertTrue(buttons.contains { $0.label == "Anime" }, "a chip is a button a click selects")
    let hidden = try XCTUnwrap(buttons.first { $0.label == "Nature" })
    XCTAssertEqual(hidden.value as? String, "Hidden", "a hidden chip says so")
  }

  func testTheImportPopoverKeepsTheImportsStatusAboveItsReport() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    let controller = panel.controller
    let model = controller.library
    panel.dialogs.presentingWindow = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled],
      backing: .buffered, defer: true)
    panel.dialogs.presentingWindow?.isReleasedWhenClosed = false
    controller.chooseImportFiles = { _, _ in [panel.root.appendingPathComponent("not-there")] }
    await model.chooseImportFiles().value
    try await panel.waitUntil(timeout: 10) {
      controller.importState.report != nil && !controller.imports.isBusy
    }
    try await panel.waitUntil { model.importPill.state.report != nil }
    let status = model.importPill.state.status
    XCTAssertFalse(status.isEmpty, "the store says how the import ended")

    let hosting = NSHostingView(
      rootView: ImportPopover()
        .environment(controller)
        .environment(\.panelImages, controller.images)
        .panelTheme(theme: controller.theme, locale: PanelLocale.shared))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 700), styleMask: [.borderless],
      backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    window.contentView = hosting
    defer {
      window.contentView = nil
      window.close()
    }
    hosting.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(300))
    hosting.layoutSubtreeIfNeeded()
    let texts = accessibilityElements(in: hosting).compactMap { ($0.value as? String) ?? $0.label }
    XCTAssertTrue(texts.contains(status), "the status line is shown with a report: \(texts)")
    let summary = try XCTUnwrap(model.importPill.state.report).summary
    XCTAssertTrue(
      texts.contains { $0.contains(summary) }, "and the report's counts after it: \(texts)")
  }

  /// A popover or the Filters sidebar hosted on its own: its width is its own, whatever the
  /// window.
  private func popoverSize<V: View>(_ view: V, _ panel: PanelFixture, dark: Bool) async throws -> CGSize {
    let controller = panel.controller
    let hosting = NSHostingView(
      rootView:
        view
        .environment(controller)
        .environment(\.panelImages, controller.images)
        .panelTheme(theme: controller.theme, locale: PanelLocale.shared))
    hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 900), styleMask: [.borderless],
      backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    window.contentView = hosting
    hosting.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(250))
    hosting.layoutSubtreeIfNeeded()
    let size = hosting.fittingSize
    window.contentView = nil
    window.close()
    return size
  }

  func testTheFiltersSidebarAndImportPopoverKeepTheirWidthInEveryLanguageAndAppearance() async throws {
    let panel = try makeController()
    defer { Task { await panel.shutdown() } }
    try await prepare(panel)
    let model = panel.controller.library
    model.setRequired("Approved", true)
    model.setIncluded("Anime", false)
    model.setIncluded("Web", false)
    model.setRequired("Some tag not in the list", true)
    PanelLocale.shared.bind(to: panel.controller.appLanguage)
    for language in AppLanguage.supported.map(\.tag) {
      try panel.controller.appLanguage.set(language)
      for dark in [false, true] {
        let filters = try await popoverSize(FilterSidebar(selection: .wallpaper), panel, dark: dark)
        XCTAssertEqual(
          filters.width, FilterSidebar.width + FilterSidebar.inset, accuracy: 1,
          "filters, \(language)")
        let importing = try await popoverSize(ImportPopover(), panel, dark: dark)
        XCTAssertEqual(importing.width, 320, accuracy: 1, "import, \(language)")
        XCTAssertLessThanOrEqual(importing.height, 520)
      }
    }
  }
}
