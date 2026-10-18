import AppKit
import SwiftUI
import XCTest

@testable import WallpaperMachine

/// The whole panel hosted the way `AppDelegate` hosts it, in a window that is never shown: the
/// root view in a hosting controller of an unordered `ControlPanelWindow`, over a store and a
/// defaults suite the test prepared. Nothing here orders a window front or touches `NSApp`.
@MainActor
final class ShellHost {
  let window: NSWindow
  let hosting: NSHostingController<ControlPanelView>
  let workshop: WorkshopStore
  let navigation: ControlPanelNavigation
  let defaults: UserDefaults
  let directory: URL

  /// - Parameters:
  ///   - prepare: Seeds the defaults the panel's stores are built over (favorites, collections)
  ///     before the controller exists.
  init(
    test: XCTestCase, store: BridgeStore, language: String = "en",
    selection: SidebarSelection = .wallpaper, welcomeSeen: Bool = true,
    prepare: (UserDefaults) throws -> Void = { _ in }
  ) throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "shell-host-\(UUID().uuidString)")
    defaults = try TemporaryDefaults.make(for: test).defaults
    if welcomeSeen { PanelPreferences.markWelcomeSeen(in: defaults) }
    try prepare(defaults)
    // Offline, as the panel fixture's: opening Steam Workshop must not search the real Steam.
    workshop = WorkshopStore(
      service: WorkshopService(session: OfflineSteamProtocol.session()),
      downloader: WorkshopDownloadManager(sessionDirectory: directory),
      supportDirectory: directory, defaults: defaults,
      updates: OfflineSteamProtocol.updates(defaults: defaults))
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

  /// Whether the window's scroll views take room for their scroll bars, as they do on a Mac with a
  /// mouse attached or set to "Show scroll bars: Always". A scroll view takes its style from the
  /// Mac it runs on when it is made, and this Mac may use overlay scrollers, so a host that sets this
  /// makes the scroll views of each layout legacy ones: their bar appears and goes, and the content
  /// beside it narrows and widens. Nothing is written to any preferences.
  var scrollBarsTakeRoom = false

  /// Gives the window `size` (a content size) and lays the hosted tree out.
  func layout(at size: NSSize) {
    window.setContentSize(size)
    layoutWindow()
  }

  /// Lays the hosted tree out where the window stands (a test that places the window itself calls
  /// this, as `setFrameUsingName` is followed by one).
  func layoutWindow() {
    if scrollBarsTakeRoom { makeScrollersTakeRoom() }
    window.layoutIfNeeded()
    hosting.view.layoutSubtreeIfNeeded()
    // Scroll views that this pass made are overlay ones; lay out again as it would have been had
    // they been legacy ones from the start.
    if scrollBarsTakeRoom, makeScrollersTakeRoom() {
      window.layoutIfNeeded()
      hosting.view.layoutSubtreeIfNeeded()
    }
  }

  /// Returns whether it changed a scroll view.
  @discardableResult
  private func makeScrollersTakeRoom() -> Bool {
    var changed = false
    func walk(_ view: NSView) {
      if let scrollView = view as? NSScrollView, scrollView.scrollerStyle != .legacy {
        scrollView.scrollerStyle = .legacy
        changed = true
      }
      view.subviews.forEach(walk)
    }
    walk(window.contentView!)
    return changed
  }

  /// The scroll view of the page's grid: the widest in the window that holds no other scroll view,
  /// which leaves out the full-width host the page and the inspector sit in (`PageScrollHost`).
  var pageScrollView: NSScrollView? {
    var widest: NSScrollView?
    func holdsScrollView(_ view: NSView) -> Bool {
      view.subviews.contains { $0 is NSScrollView || holdsScrollView($0) }
    }
    func walk(_ view: NSView) {
      if let scrollView = view as? NSScrollView,
        scrollView.frame.width > (widest?.frame.width ?? 0), !holdsScrollView(scrollView)
      {
        widest = scrollView
      }
      view.subviews.forEach(walk)
    }
    walk(window.contentView!)
    return widest
  }

  /// Lets SwiftUI and the asynchronous loads (covers, the first Settings pass) land.
  func settle(_ milliseconds: Int = 300) async throws {
    try await Task.sleep(for: .milliseconds(milliseconds))
  }

  /// Lets the run loop turn, laying the window out, until `condition` holds: a wait for state
  /// rather than for time, which a loaded machine stretches.
  func settle(
    timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line,
    until condition: () -> Bool
  ) async throws {
    try await ShellSettle.wait(window: window, timeout: timeout, file: file, line: line, condition)
  }

  /// Draws the panel in the light or dark appearance by the hosting view's own appearance.
  func setDark(_ dark: Bool) {
    hosting.view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    window.appearance = hosting.view.appearance
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

  /// The window's split views, outermost first.
  var splitViews: [NSSplitView] {
    var found: [NSSplitView] = []
    func walk(_ view: NSView) {
      if let split = view as? NSSplitView { found.append(split) }
      view.subviews.forEach(walk)
    }
    walk(window.contentView!)
    return found
  }

  /// The toolbar items the panel's own content adds, which are not the split view's.
  var contentToolbarItems: [NSToolbarItem] {
    (window.toolbar?.items ?? []).filter {
      !$0.itemIdentifier.rawValue.hasPrefix("com.apple.SwiftUI")
        && !$0.itemIdentifier.rawValue.hasPrefix("NSToolbar")
    }
  }

  /// Whether the page shows the search bar that the pages with one share (`PageSearchBar`).
  var hasPageSearchField: Bool {
    PanelSearchFocus.field(in: window)?.accessibilityIdentifier() == "page-search-field"
  }

  /// A PNG of the hosted content as drawn now.
  func png() throws -> Data {
    let view = hosting.view
    let bounds = view.bounds
    let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: bounds))
    view.cacheDisplay(in: bounds, to: rep)
    return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
  }

  func close() async {
    window.contentViewController = nil
    window.close()
    await workshop.steamCMDSetup.shutdown()
    try? FileManager.default.removeItem(at: directory)
  }
}

extension XCTestCase {
  /// Each `ShellHost` bound the shared panel language to its own store.
  @MainActor
  func restoreSharedPanelLanguage() { PanelLocale.shared.bind(to: .testHost) }

  /// A `ShellHost` for `body`, always closed afterwards.
  @MainActor
  func withShellHost(
    store: BridgeStore, language: String = "en", selection: SidebarSelection = .wallpaper,
    welcomeSeen: Bool = true, _ body: (ShellHost) async throws -> Void
  ) async throws {
    let host = try ShellHost(
      test: self, store: store, language: language, selection: selection, welcomeSeen: welcomeSeen)
    do {
      try await body(host)
    } catch {
      await host.close()
      throw error
    }
    await host.close()
  }
}

/// A library and displays to host the panel over: wallpapers with titles, optional generated
/// previews, two displays and what they show.
@MainActor
enum ShellFixtures {
  static let titles = [
    "Neon Rain Alley", "Aurora Drift", "Quiet Harbor", "Paper Lanterns", "Deep Forest",
    "Solar Flare", "Midnight Metro", "Cherry Blossom Hill",
  ]

  /// Fills the store's library with `count` wallpapers (`w0`, `w1`, ...), two displays and what they
  /// show. With `previews`, writes an image for each under `library`, which the covers read.
  static func seed(
    _ store: BridgeStore, bridge: LayoutSnapshotBridge, library: URL? = nil, count: Int = 8,
    primary: String? = "w0", secondary: String? = "w1", paused: Bool = false
  ) async throws {
    var entries: [BridgeWallpaperEntry] = []
    for index in 0..<count {
      var preview: String?
      if let library {
        let url = library.appendingPathComponent("w\(index)/preview.png")
        try FileManager.default.createDirectory(
          at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try image(index: index).write(to: url)
        preview = url.path
      }
      entries.append(
        BridgeWallpaperEntry(
          id: "w\(index)", title: titles[index % titles.count], kind: .video, supported: true,
          active: false, selected: false, previewPath: preview))
    }
    store.librarySnapshot.wallpapers = entries
    store.settingsSnapshot.displays = [
      display("primary", "Studio Display (primary - Primary)"),
      display("secondary", "Built-in Retina Display (secondary - Secondary)"),
    ]
    store.monitorInformationSnapshot.rows = [("primary", primary), ("secondary", secondary)].map {
      BridgeMonitorInfoRow(
        displayId: $0, title: $0, wallpaperId: $1 ?? "", wallpaperTitle: $1 ?? "",
        mirrorTargetDisplayId: nil, mirrorTargetTitle: nil, scalingMode: "fill", targetFps: "30",
        audioResponse: false)
    }
    store.appSnapshot = BridgeAppSnapshot(
      playbackState: paused ? .paused : .playing, selectedWallpaperId: nil,
      activeWallpaperIds: [primary, secondary].compactMap { $0 }, errors: [], heldWallpaperIds: [])
    store.snapshotRevision &+= 1
    // The library has been read: the panel counts it instead of waiting for it.
    bridge.snapshot = BridgeSnapshotBundle(
      app: store.appSnapshot, library: store.librarySnapshot, wallpaperOptions: nil,
      monitorInformation: store.monitorInformationSnapshot, settings: store.settingsSnapshot)
    try await store.refreshAllAsync()
  }

  static func display(_ id: String, _ title: String, enabled: Bool = true) -> BridgeDisplaySettingsRow
  {
    BridgeDisplaySettingsRow(
      displayId: id, title: title, enabled: enabled, mode: .standalone, mirrorTargets: [],
      selectedMirrorTarget: nil, scalingMode: .fill, scalingFactor: 1, targetFps: 30, maxFps: 60,
      muted: false, volume: 1)
  }

  /// A 256-point gradient with a sun, in a hue of its own, as PNG data.
  static func image(index: Int) throws -> Data {
    let size = 256
    let context = try XCTUnwrap(
      CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let hue = (Double(index) * 0.13 + 0.55).truncatingRemainder(dividingBy: 1)
    let top = NSColor(hue: hue, saturation: 0.55, brightness: 0.35, alpha: 1)
    let bottom = NSColor(hue: (hue + 0.12).truncatingRemainder(dividingBy: 1), saturation: 0.7, brightness: 0.95, alpha: 1)
    let gradient = try XCTUnwrap(
      CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [top.cgColor, bottom.cgColor] as CFArray,
        locations: [0, 1]))
    context.drawLinearGradient(
      gradient, start: CGPoint(x: 0, y: CGFloat(size)), end: .zero, options: [])
    context.setFillColor(NSColor.white.withAlphaComponent(0.85).cgColor)
    context.fillEllipse(in: CGRect(x: 150 - index * 6, y: 120 + index * 4, width: 64, height: 64))
    let rep = NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
    return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
  }
}

/// `PanelRootView` over a fixture's controller, hosted in an unordered `ControlPanelWindow`, for the
/// tests that need to read and drive the shell while it is drawn. English only: the fixture's
/// controller follows an English language store.
@MainActor
final class ShellFixtureHost {
  let window: NSWindow
  let hosting: NSHostingController<AnyView>
  let controller: PanelController

  init(panel: PanelFixture) {
    controller = panel.controller
    PanelLocale.shared.bind(to: controller.appLanguage)
    let controller = controller
    hosting = NSHostingController(
      rootView: AnyView(
        PanelRootView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .environment(controller)
          .environment(\.panelImages, controller.images)))
    hosting.sizingOptions = []
    hosting.sceneBridgingOptions = [.toolbars, .title]
    window = ControlPanelWindow.make(contentViewController: hosting, delegate: nil)
  }

  func layout(at size: NSSize) {
    window.setContentSize(size)
    window.layoutIfNeeded()
    hosting.view.layoutSubtreeIfNeeded()
  }

  /// Lets the run loop turn for `milliseconds`, laying the window out as it goes.
  func settle(_ milliseconds: Int = 300) async throws {
    var waited = 0
    while waited < milliseconds {
      try await Task.sleep(for: .milliseconds(50))
      window.layoutIfNeeded()
      waited += 50
    }
  }

  /// Lets the run loop turn, laying the window out, until `condition` holds.
  func settle(
    timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line,
    until condition: () -> Bool
  ) async throws {
    try await ShellSettle.wait(window: window, timeout: timeout, file: file, line: line, condition)
  }

  func setDark(_ dark: Bool) {
    hosting.view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    window.appearance = hosting.view.appearance
  }

  var widestSplitView: CGFloat {
    func widest(_ view: NSView) -> CGFloat {
      let own = (view as? NSSplitView)?.frame.width ?? 0
      return view.subviews.map(widest).reduce(own, max)
    }
    return widest(window.contentView!)
  }

  func png() throws -> Data {
    let view = hosting.view
    let bounds = view.bounds
    let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: bounds))
    view.cacheDisplay(in: bounds, to: rep)
    return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
  }

  /// The toolbar items the panel's own content adds, which are not the split view's.
  var contentToolbarItems: [NSToolbarItem] {
    (window.toolbar?.items ?? []).filter {
      !$0.itemIdentifier.rawValue.hasPrefix("com.apple.SwiftUI")
        && !$0.itemIdentifier.rawValue.hasPrefix("NSToolbar")
    }
  }

  func close() {
    window.contentViewController = nil
    window.close()
  }
}

/// The wait both hosts share.
@MainActor
enum ShellSettle {
  struct Timeout: Error, CustomStringConvertible {
    let file: StaticString
    let line: UInt
    var description: String { "\(file):\(line): the panel did not get there in time" }
  }

  static func wait(
    window: NSWindow, timeout: TimeInterval, file: StaticString, line: UInt,
    _ condition: () -> Bool
  ) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    window.layoutIfNeeded()
    while !condition() {
      guard Date() < deadline else { throw Timeout(file: file, line: line) }
      try await Task.sleep(for: .milliseconds(25))
      window.layoutIfNeeded()
    }
  }
}

extension PanelFixture {
  /// Imports one video wallpaper through the library's Import, as Choose wallpapers does, and waits
  /// until the import has finished and the pill holds its report.
  func importOneWallpaper() async throws {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled],
      backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    dialogs.presentingWindow = window
    let source = root.appendingPathComponent("sources/123456")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try Data("movie".utf8).write(to: source.appendingPathComponent("movie.mp4"))
    try JSONSerialization.data(withJSONObject: ["title": "T", "type": "video", "file": "movie.mp4"])
      .write(to: source.appendingPathComponent("project.json"))
    controller.chooseImportFiles = { _, _ in [source] }
    let library = controller.library
    await library.chooseImportFiles().value
    try await waitUntil(timeout: 10) {
      library.importPill.state.report != nil && !library.importPill.state.isBusy
    }
  }
}
