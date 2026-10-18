import AppKit
import Carbon
import SwiftUI
import XCTest

@testable import WallpaperMachine

/// The base of the settings-b suites: the panel speaks English, whatever the developer's Mac does.
@MainActor
class SettingsBTestCase: PanelTestCase {
  /// For the number formatting a model type takes as an argument.
  let english = Locale(identifier: "en_US")

  override func setUp() async throws {
    try await super.setUp()
    PanelLocale.shared.bind(to: .english())
  }

  override func tearDown() async throws {
    PanelLocale.shared.bind(to: .testHost)
    try await super.tearDown()
  }
}

/// A panel with something on every Settings page of settings-b: three displays (one mirror), a
/// library, playlists of each mode, saved playlists and layouts, rules of the time schedule, a solar
/// location and recorded shortcuts, all over the fixture's own stores.
@MainActor
enum SettingsBFixtures {
  static let wallpapers = [
    ("w1", "Aurora Bay"), ("w2", "Kyoto Rain Loop"), ("w3", "Sunrise over the Ridge"),
    ("w4", "Night Market 夜市"), ("w5", "Deep Field"), ("w6", "Paper Boats"),
    ("w7", "Moss & Stone"), ("w8", "A very long wallpaper title that keeps going and going"),
  ]

  /// Fills the panel's stores. The primary display shows `w1` and rotates through its own list;
  /// "2" shows `w2` on a day and night schedule; "3" mirrors the primary display.
  static func populate(_ panel: PanelFixture) throws {
    let store = panel.store
    store.librarySnapshot.wallpapers = wallpapers.map { OrganizationFixtures.wallpaper($0.0, title: $0.1) }
    store.settingsSnapshot.displays = [
      OrganizationFixtures.display(
        "primary", title: "Studio Display (1 - Primary)", mirrorTargets: [], targetFps: 30,
        maxFps: 60, volume: 0.6),
      OrganizationFixtures.display(
        "2", title: "LG UltraFine 5K (2)", scalingMode: .match, scalingFactor: 1.25,
        targetFps: 24, maxFps: 60),
      OrganizationFixtures.display(
        "3", title: "Sidecar iPad (3)", mode: .mirror, mirrorTargets: ["primary", "2"],
        selectedMirrorTarget: nil),
    ]
    store.monitorInformationSnapshot.rows = [
      OrganizationFixtures.monitor("primary", wallpaper: "w1"),
      OrganizationFixtures.monitor("2", wallpaper: "w2"),
    ]
    panel.playlists.update("primary") {
      $0.mode = .rotate
      $0.source = .list
      $0.wallpaperIDs = ["w1", "w3", "w5", "w6", "gone"]
      $0.interval = 30
    }
    panel.playlists.update("2") {
      $0.mode = .dayNight
      $0.dayWallpaperID = "w3"
      $0.nightWallpaperID = "w4"
    }
    _ = try panel.playlists.savePlan(from: "primary", name: "Weekday rotation")
    _ = try panel.playlists.savePlan(from: "2", name: "Day and night")
    let assignments = [
      WallpaperDisplayAssignment(displayID: "primary", displayTitle: "Studio Display (1 - Primary)", wallpaperID: "w1"),
      WallpaperDisplayAssignment(displayID: "2", displayTitle: "LG UltraFine 5K (2)", wallpaperID: "w2"),
    ]
    _ = try panel.controller.displayLayouts.save(name: "Work", assignments: assignments)
    try panel.automations.update("primary") {
      $0.mode = .schedule
      $0.rules = [
        WallpaperAutomationRule(
          weekdays: AutomationRuleEdit.weekdaysOnly, event: .time, minute: 9 * 60 + 15,
          target: .init(kind: .wallpaper, id: "w3")),
        WallpaperAutomationRule(
          weekdays: AutomationRuleEdit.everyDay, event: .sunset, offset: -25,
          target: .init(kind: .wallpaper, id: "w4")),
      ]
    }
    try panel.automations.setLocation(WallpaperSolarLocation(latitude: 35.6812, longitude: 139.7671))
    try panel.controller.hotKeys.set(
      HotKey(keyCode: 35, modifiers: UInt32(controlKey | optionKey | cmdKey), label: "⌃⌥⌘P"), for: .togglePlayback)
    try panel.controller.hotKeys.set(
      HotKey(keyCode: 124, modifiers: UInt32(optionKey | cmdKey), label: "⌥⌘→"), for: .nextWallpaper)
  }
}

/// The panel hosted in a window that is never shown, at a size, in a language and an appearance.
@MainActor
final class SettingsBHost {
  let window: NSWindow
  let hosting: NSHostingController<SettingsBRoot>
  let controller: PanelController

  init(panel: PanelFixture, language: String = "en", dark: Bool = false) {
    controller = panel.controller
    // Settings is the page from the first pass: the shell's toolbar changes between pages, and a
    // window that has to change it at the narrowest width is not what these tests are about.
    panel.navigation.selection = .settings
    // The panel's strings follow this store, which fixes the language without touching preferences.
    PanelLocale.shared.bind(to: AppLanguageStore(defaults: panel.defaults, systemLanguages: [language]))
    hosting = NSHostingController(rootView: SettingsBRoot(controller: panel.controller))
    hosting.sizingOptions = []
    hosting.sceneBridgingOptions = [.toolbars, .title]
    window = ControlPanelWindow.make(contentViewController: hosting, delegate: nil)
    if dark { hosting.view.appearance = NSAppearance(named: .darkAqua) }
  }

  /// The panel's language and the look of the hosted view, switched in place.
  func use(language: String, dark: Bool, panel: PanelFixture) {
    PanelLocale.shared.bind(to: AppLanguageStore(defaults: panel.defaults, systemLanguages: [language]))
    hosting.view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
  }

  /// Opens `section` of Settings and lays the window out at `size`.
  func show(_ section: SettingsSection, size: NSSize) async throws {
    controller.navigation.selection = .settings
    controller.settings.select(section)
    // As the shell's own render tests do: lay out, let the first pass settle, lay out again. The
    // first measurement of a new window is wider than the window while the split view finds its columns.
    window.setContentSize(size)
    window.layoutIfNeeded()
    hosting.view.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(300))
    window.layoutIfNeeded()
    hosting.view.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(100))
    window.layoutIfNeeded()
    hosting.view.layoutSubtreeIfNeeded()
  }

  /// Whether the root accepts `size`: it measures the window's width and no more than its height,
  /// and the split view is no wider than the window.
  func fits(_ size: NSSize) -> Bool {
    let measured = hosting.sizeThatFits(in: size)
    return abs(measured.width - size.width) <= 1 && measured.height <= size.height + 1
      && widestSplitView <= size.width + 1
  }

  /// Lays out again until the root accepts `size`, for up to `seconds`: a new window's first passes
  /// are wider than the window while the split view finds its columns, and only a page that still
  /// asks for more once they are done is too wide.
  func settle(_ size: NSSize, seconds: Double = 3) async throws {
    let deadline = Date().addingTimeInterval(seconds)
    while !fits(size), Date() < deadline {
      window.layoutIfNeeded()
      hosting.view.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(100))
    }
  }

  func layout(at size: NSSize) async throws {
    window.setContentSize(size)
    window.layoutIfNeeded()
    hosting.view.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(150))
    hosting.view.layoutSubtreeIfNeeded()
  }

  /// The widest split view inside the window: wider than the window means the panel asks for more
  /// room than it was given.
  var widestSplitView: CGFloat {
    func widest(_ view: NSView) -> CGFloat {
      let own = (view as? NSSplitView)?.frame.width ?? 0
      return view.subviews.map(widest).reduce(own, max)
    }
    return widest(window.contentView!)
  }

  /// Scrolls the page to `offset` points from its top, for a look at a page taller than the window.
  func scroll(to offset: CGFloat) async throws {
    func largest(_ view: NSView) -> NSScrollView? {
      let found = view.subviews.compactMap(largest)
      let own = (view as? NSScrollView).map { [$0] } ?? []
      return (own + found).max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }
    }
    guard let scrollView = largest(hosting.view) else { return }
    scrollView.contentView.scroll(to: NSPoint(x: 0, y: offset))
    scrollView.reflectScrolledClipView(scrollView.contentView)
    try await Task.sleep(for: .milliseconds(150))
    hosting.view.layoutSubtreeIfNeeded()
  }

  func close() {
    window.contentViewController = nil
    window.close()
    PanelLocale.shared.bind(to: .testHost)
  }

  /// Draws the hosted view to a PNG, for a look at it; a review only, never an assertion.
  func snapshot(to url: URL) throws {
    let view = hosting.view
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
    view.cacheDisplay(in: view.bounds, to: rep)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try rep.representation(using: .png, properties: [:])?.write(to: url)
  }
}

/// What `ControlPanelView` hosts, over a controller the test owns.
struct SettingsBRoot: View {
  let controller: PanelController

  var body: some View {
    PanelRootView()
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .environment(controller)
      .environment(\.panelImages, controller.images)
  }
}
