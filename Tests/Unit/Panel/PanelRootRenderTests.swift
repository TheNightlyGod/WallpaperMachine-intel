import AppKit
import SwiftUI
import XCTest

@testable import WallpaperMachine

/// The whole panel in a window that is never shown: it takes the size the window gives it, in every
/// language and with the guide open, and its toolbar and title follow the page.
@MainActor
final class PanelRootRenderTests: PanelTestCase {
  /// One panel hosted the way `AppDelegate` hosts it, in an unordered window.
  @MainActor
  private final class Harness {
    let window: NSWindow
    let hosting: NSHostingController<ControlPanelView>
    let workshop: WorkshopStore
    let navigation: ControlPanelNavigation
    let directory: URL

    init(
      test: XCTestCase, store: BridgeStore, language: String,
      selection: SidebarSelection = .wallpaper,
      welcomeSeen: Bool = true
    ) throws {
      directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "panel-render-\(UUID().uuidString)")
      let defaults = try TemporaryDefaults.make(for: test).defaults
      if welcomeSeen { PanelPreferences.markWelcomeSeen(in: defaults) }
      workshop = WorkshopStore(
        downloader: WorkshopDownloadManager(sessionDirectory: directory),
        supportDirectory: directory,
        defaults: defaults)
      navigation = ControlPanelNavigation(selection: selection)
      // The language comes from a store that follows a fixed "system" language, so nothing is
      // written to the user's preferences.
      let languages = AppLanguageStore(defaults: defaults, systemLanguages: [language])
      hosting = NSHostingController(
        rootView: ControlPanelView(
          store: store, navigation: navigation, workshop: workshop, pixiv: PixivStore(),
          updater: AppUpdateStore(currentVersion: "0.1.0", client: DisabledAppUpdateClient()),
          imports: LibraryImportStore(), defaults: defaults, appLanguage: languages))
      hosting.sizingOptions = []
      hosting.sceneBridgingOptions = [.toolbars, .title]
      window = ControlPanelWindow.make(contentViewController: hosting, delegate: nil)
    }

    func layout(at size: NSSize) {
      window.setContentSize(size)
      window.layoutIfNeeded()
      hosting.view.layoutSubtreeIfNeeded()
    }

    /// The widest split view inside the window's content: wider than the window means the panel is
    /// asking for more room than it was given, and its edges are clipped.
    var widestSplitView: CGFloat {
      func widest(_ view: NSView) -> CGFloat {
        let own = (view as? NSSplitView)?.frame.width ?? 0
        return view.subviews.map(widest).reduce(own, max)
      }
      return widest(window.contentView!)
    }

    /// The toolbar items the panel's own content adds, which are not the split view's.
    var contentToolbarItems: [NSToolbarItem] {
      (window.toolbar?.items ?? []).filter {
        !$0.itemIdentifier.rawValue.hasPrefix("com.apple.SwiftUI")
          && !$0.itemIdentifier.rawValue.hasPrefix("NSToolbar")
      }
    }

    func close() async {
      window.contentViewController = nil
      window.close()
      await workshop.steamCMDSetup.shutdown()
      try? FileManager.default.removeItem(at: directory)
    }
  }

  override func tearDown() async throws {
    // Each harness bound the shared panel language to its own store.
    PanelLocale.shared.bind(to: .testHost)
    try await super.tearDown()
  }

  private func settle() async throws { try await Task.sleep(for: .milliseconds(300)) }

  /// The window owns its bounds, so the root must take whatever it proposes, even with a very long
  /// display title, in every shipped language, and not lay out wider than that.
  func testTheRootAcceptsSmallWindowProposalsWithALongDisplayTitleInEveryLanguage() async throws {
    let store = makeStore().store
    for language in AppLanguage.supported.map(\.tag) {
      let harness = try Harness(test: self, store: store, language: language)
      for size in [
        NSSize(width: 760, height: 560), NSSize(width: 960, height: 640),
        NSSize(width: 1240, height: 800),
      ] {
        harness.layout(at: size)
        try await settle()
        harness.layout(at: size)
        let measured = harness.hosting.sizeThatFits(in: size)
        XCTAssertEqual(
          measured.width, size.width, accuracy: 1,
          "\(language): the root must accept the window width")
        XCTAssertLessThanOrEqual(
          measured.height, size.height + 1, "\(language): content must not force a taller window")
        XCTAssertLessThanOrEqual(
          harness.widestSplitView, size.width + 1,
          "\(language) at \(Int(size.width)): the panel must fit the window, not overflow it")
        XCTAssertFalse(harness.window.isVisible, "Layout measurement must stay offscreen")
      }
      await harness.close()
    }
  }

  func testTheFirstRunGuideOverTheSplitViewStillAcceptsTheSmallestWindow() async throws {
    let harness = try Harness(
      test: self, store: makeStore().store, language: "en", welcomeSeen: false)
    let size = NSSize(width: 760, height: 560)
    harness.layout(at: size)
    try await settle()
    harness.layout(at: size)
    XCTAssertEqual(harness.hosting.sizeThatFits(in: size).width, size.width, accuracy: 1)
    XCTAssertLessThanOrEqual(harness.widestSplitView, size.width + 1)
    await harness.close()
  }

  func testTheToolbarAndTitleFollowThePageOnShow() async throws {
    let harness = try Harness(test: self, store: makeStore().store, language: "en")
    harness.layout(at: NSSize(width: 1240, height: 800))
    try await settle()
    XCTAssertEqual(harness.window.title, "All wallpapers")
    XCTAssertEqual(
      harness.contentToolbarItems.count, 4,
      "A library page offers the app's name, the tabs, the target display menu and the inspector toggle")

    harness.navigation.selection = .settings
    try await settle()
    XCTAssertEqual(harness.window.title, "Quick Settings")
    XCTAssertEqual(
      harness.contentToolbarItems.count, 2,
      "Settings has the app's name and the tabs, but neither a target nor an inspector")

    harness.navigation.revealSettingsSection(.about)
    harness.navigation.selection = .pixiv
    try await settle()
    XCTAssertEqual(harness.window.title, "pixiv")
    XCTAssertEqual(harness.contentToolbarItems.count, 4)
    await harness.close()
  }

  func testAnAppRevealOfASettingsSectionIsShownOnceWhenSettingsOpens() async throws {
    let harness = try Harness(
      test: self, store: makeStore().store, language: "en", selection: .settings)
    harness.navigation.revealSettingsSection(.about)
    harness.layout(at: NSSize(width: 1240, height: 800))
    try await settle()
    XCTAssertEqual(
      harness.window.title, "About", "A reveal made before the window existed is shown")
    await harness.close()
  }

  // MARK: The language on show

  /// What a person reads first: the window's title and subtitle, the tabs, the library's views
  /// and Settings' section list, on a library page and in Settings.
  private struct DrawnWords: Equatable {
    var libraryTitle = ""
    var librarySubtitle = ""
    var workshopTab = ""
    var allWallpapersChip = ""
    var settingsTitle = ""
    var generalRow = ""

    var all: [(name: String, text: String)] {
      [
        ("library title", libraryTitle), ("library subtitle", librarySubtitle),
        ("Steam Workshop tab", workshopTab), ("All wallpapers chip", allWallpapersChip),
        ("Settings title", settingsTitle), ("General row", generalRow),
      ]
    }
  }

  /// The panel is drawn in the language its controller follows: in Japanese, Korean and both
  /// Chinese scripts these words differ from the English panel, use their script and keep no placeholder.
  func testThePanelIsDrawnInTheLanguageItsControllerFollows() async throws {
    let (store, bridge) = makeStore()
    try await ShellFixtures.seed(store, bridge: bridge)
    var english: DrawnWords?
    for language in AppLanguage.supported.map(\.tag) {
      let harness = try Harness(test: self, store: store, language: language)
      let words = try await drawnWords(harness)
      await harness.close()
      guard let english else {
        english = words
        continue
      }
      for ((name, text), (_, englishText)) in zip(words.all, english.all) {
        XCTAssertNotEqual(text, englishText, "\(language): the \(name) is not translated")
        XCTAssertTrue(Self.isCJK(text), "\(language): the \(name) “\(text)” is not in its script")
        XCTAssertFalse(text.contains("%"), "\(language): the \(name) “\(text)” keeps a placeholder")
      }
    }
  }

  /// Reads the words of `harness` on All wallpapers, then on Settings › General, waiting for each
  /// page to be drawn rather than for a time.
  private func drawnWords(_ harness: Harness) async throws -> DrawnWords {
    var words = DrawnWords()
    harness.layout(at: NSSize(width: 1240, height: 800))
    try await waitUntil {
      !harness.window.subtitle.isEmpty && Self.element("scope-all", in: harness.window) != nil
        && Self.tab(.workshop, in: harness.window) != nil
    }
    words.libraryTitle = harness.window.title
    words.librarySubtitle = harness.window.subtitle
    words.workshopTab = Self.tab(.workshop, in: harness.window) ?? ""
    words.allWallpapersChip = Self.element("scope-all", in: harness.window) ?? ""

    harness.navigation.revealSettingsSection(.general)
    harness.navigation.selection = .settings
    try await waitUntil {
      harness.window.title != words.libraryTitle
        && Self.listRow("settings-section-general", in: harness.window) != nil
    }
    words.settingsTitle = harness.window.title
    words.generalRow = Self.listRow("settings-section-general", in: harness.window) ?? ""
    return words
  }

  /// Polls `condition` until it holds, for up to five seconds.
  private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(5)
    while !condition() {
      guard Date() < deadline else { throw CancellationError() }
      try await Task.sleep(for: .milliseconds(20))
    }
  }

  /// What the element with `identifier` in the window's content says, as VoiceOver reads it; nil
  /// while none is drawn.
  private static func element(_ identifier: String, in window: NSWindow) -> String? {
    guard let content = window.contentView else { return nil }
    return AccessibilityElement(object: content).first(identifier: identifier)?.text
  }

  /// What the title bar's tab for `page` says, as VoiceOver reads it; nil while it is not drawn.
  private static func tab(_ page: SidebarSelection, in window: NSWindow) -> String? {
    let identifier = "tab-\(PanelTabs.identifier(of: page))"
    for view in window.toolbar?.items.compactMap(\.view) ?? [] {
      if let text = AccessibilityElement(object: view).first(identifier: identifier)?.text,
        !text.isEmpty
      {
        return text
      }
    }
    return nil
  }

  /// What the Settings section row with `identifier` says, read from the cells of the window's lists
  /// the way VoiceOver reads them; nil while no such row is drawn.
  private static func listRow(_ identifier: String, in window: NSWindow) -> String? {
    func tables(_ view: NSView) -> [NSTableView] {
      ((view as? NSTableView).map { [$0] } ?? []) + view.subviews.flatMap(tables)
    }
    for table in window.contentView.map(tables) ?? [] {
      for row in 0..<table.numberOfRows {
        guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) else { continue }
        if let element = AccessibilityElement(object: cell).all(limit: 50).first(where: {
          $0.identifier == identifier
        }) {
          return element.text
        }
      }
    }
    return nil
  }

  /// Whether the text holds kana, Hangul or Han ideographs.
  private static func isCJK(_ text: String) -> Bool {
    text.unicodeScalars.contains { scalar in
      [
        0x1100...0x11FF, 0x3040...0x30FF, 0x3130...0x318F, 0x3400...0x4DBF,
        0x4E00...0x9FFF, 0xAC00...0xD7A3, 0xF900...0xFAFF,
      ].contains {
        $0.contains(scalar.value)
      }
    }
  }
}
