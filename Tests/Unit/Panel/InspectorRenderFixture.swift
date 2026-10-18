import AppKit
import CoreGraphics
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import XCTest

@testable import WallpaperMachine

/// A panel with a small library whose first wallpaper is open in the inspector, for tests that draw
/// the inspector. It has previews on disk, two displays, options with every kind of property and the
/// stores the cards read, over the same bridge double the property tests use.
@MainActor
final class InspectorRenderFixture {
  let panel: PanelFixture
  let bridge: InspectorPreviewBridge
  var store: BridgeStore { panel.store }
  var controller: PanelController { panel.controller }
  let assets: URL

  /// The wallpaper that is selected.
  static let selected = "wp"
  static let displays = ["primary", "second"]

  init(selecting kind: BridgeWallpaperKind = .projectScene, properties: [BridgePropertyDescriptor]? = nil) throws {
    let bridge = InspectorPreviewBridge(noPointer: .init())
    let store = BridgeStore(bridge: bridge)
    bridge.store = store
    self.bridge = bridge
    panel = try PanelFixture(store: store, bridge: bridge, displayTitles: .renderer)
    assets = panel.root.appendingPathComponent("picked", isDirectory: true)
    try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
    try Data("a".utf8).write(to: assets.appendingPathComponent("rain.png"))
    try Data("b".utf8).write(to: assets.appendingPathComponent("snow.png"))
    try Data("c".utf8).write(to: assets.appendingPathComponent("notes.txt"))

    store.settingsSnapshot.displays = [
      Self.display("primary", "Studio Display (1 - Primary)"),
      Self.display("second", "LG UltraFine (2 - Secondary)"),
    ]
    store.monitorInformationSnapshot = BridgeMonitorInformationSnapshot(rows: [
      BridgeMonitorInfoRow(
        displayId: "primary", title: "Studio Display (1 - Primary)", wallpaperId: Self.selected,
        wallpaperTitle: "Aurora", mirrorTargetDisplayId: nil, mirrorTargetTitle: nil,
        scalingMode: "fill", targetFps: "30", audioResponse: true),
      BridgeMonitorInfoRow(
        displayId: "second", title: "LG UltraFine (2 - Secondary)", wallpaperId: "clip",
        wallpaperTitle: "Clip", mirrorTargetDisplayId: nil, mirrorTargetTitle: nil,
        scalingMode: "fill", targetFps: "30", audioResponse: true),
    ])
    let entries: [(String, String, BridgeWallpaperKind)] = [
      (Self.selected, "Aurora Borealis over a Frozen Lake", kind),
      ("clip", "Slow Waves", .video), ("12345", "Workshop Night City", .projectScene),
      ("web", "Clock", .webpage),
    ]
    var library: [BridgeWallpaperEntry] = []
    for (index, entry) in entries.enumerated() {
      let project = panel.library.appendingPathComponent(entry.0)
      try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
      try Data(#"{"type":"web","file":"index.html","tags":["Anime","Nature","Audio responsive"]}"#.utf8)
        .write(to: project.appendingPathComponent("project.json"))
      try Data("<!doctype html>".utf8).write(to: project.appendingPathComponent("index.html"))
      try Data(count: 3_400_000 + index * 1000).write(to: project.appendingPathComponent("blob.bin"))
      let preview = project.appendingPathComponent("preview.png")
      try Self.picture(hue: Double(index) * 0.23 + 0.55).write(to: preview)
      library.append(
        BridgeWallpaperEntry(
          id: entry.0, title: entry.1, kind: entry.2, supported: true, active: false,
          selected: false, previewPath: preview.path))
      bridge.options[entry.0] = BridgeSnapshotFixtures.options(
        wallpaperId: entry.0, title: entry.1, kind: entry.2,
        properties: properties ?? self.properties(),
        displayConfigurations: [
          Self.config("primary", "Studio Display (1 - Primary)", mode: .fill, factor: 1, pan: (0.5, 0.5)),
          Self.config("second", "LG UltraFine (2 - Secondary)", mode: .match, factor: 1.2, pan: (0.3, 0.5)),
        ])
    }
    store.librarySnapshot.wallpapers = library
    store.appSnapshot.selectedWallpaperId = Self.selected
    store.wallpaperOptionsSnapshot = bridge.options[Self.selected]
  }

  // MARK: Fixtures

  static func display(_ id: String, _ title: String) -> BridgeDisplaySettingsRow {
    BridgeDisplaySettingsRow(
      displayId: id, title: title, enabled: true, mode: .standalone, mirrorTargets: [],
      selectedMirrorTarget: nil, scalingMode: .fill, scalingFactor: 1, targetFps: 30, maxFps: 60,
      muted: false, volume: 1)
  }

  static func config(
    _ id: String, _ title: String, mode: BridgeScalingMode, factor: Double, pan: (Double, Double)
  ) -> BridgeDisplayConfigRow {
    BridgeDisplayConfigRow(
      displayId: id, title: title, enabled: true, scalingMode: mode, scalingFactor: factor,
      framing: BridgeFraming(panX: pan.0, panY: pan.1), targetFps: 30, maxFps: 60, muted: false,
      volume: 1, dirty: false, canRestoreDefaults: false)
  }

  /// Every kind of authored row: a group with a rich label, a switch, two sliders, a choice, a
  /// colour, text, a picture, a file, a folder, and a description that links out.
  func properties() -> [BridgePropertyDescriptor] {
    func property(
      _ id: String, _ kind: BridgePropertyKind, _ label: String, _ value: BridgePropertyValue,
      defaultValue: BridgePropertyValue? = .empty, slider: BridgeSliderMetadata? = nil,
      options: [BridgeComboOption] = [], filter: BridgeFileFilter? = nil,
      mode: BridgeDirectoryMode? = nil, dirty: Bool = false, enabled: Bool = true
    ) -> BridgePropertyDescriptor {
      BridgePropertyDescriptor(
        id: id, kind: kind, labelHtml: label, value: value, defaultValue: defaultValue ?? value,
        slider: slider, comboOptions: options, fileFilter: filter, directoryMode: mode,
        dirty: dirty, canRestoreDefaults: true, enabled: enabled, assetManaged: false,
        assetMissing: false, assetSourcePath: nil)
    }
    return [
      property("g1", .group, "<b>Appearance</b>", .empty),
      property("clock", .bool, "Show the clock", .bool(value: true), defaultValue: .bool(value: false), dirty: true),
      property(
        "count", .slider, "Particle count", .number(value: 120), defaultValue: .number(value: 100),
        slider: BridgeSliderMetadata(min: 0, max: 500, step: 10, precision: 0)),
      property(
        "opacity", .slider, "<font color=\"#d2691e\">Glow</font> opacity", .number(value: 0.65),
        defaultValue: .number(value: 0.5),
        slider: BridgeSliderMetadata(min: 0, max: 1, step: 0.05, precision: 2)),
      property(
        "weather", .combo, "Weather", .string(value: "rain"), defaultValue: .string(value: "sun"),
        options: [
          BridgeComboOption(label: "Sunny", value: .string(value: "sun")),
          BridgeComboOption(label: "Light rain", value: .string(value: "rain")),
          BridgeComboOption(label: "Snow", value: .string(value: "snow")),
        ]),
      property("tint", .color, "Tint", .colorRgb(red: 0.35, green: 0.62, blue: 0.95)),
      property("g2", .group, "<font size=\"4\">Content</font>", .empty),
      property("caption", .textInput, "Caption", .string(value: "Good evening")),
      property("overlay", .texture, "Overlay picture", .string(value: "/Users/me/Pictures/clouds.png")),
      property("pictures", .directory, "Photos folder", .string(value: assets.path), filter: .image, mode: .fetchAll),
      property("note", .text, "Made by <a href=\"https://space.bilibili.com/1\">Someone</a> — thank you for the support!", .empty),
    ]
  }

  /// A PNG of a smooth two-colour picture, 16:10.
  static func picture(hue: Double) -> Data {
    let width = 800
    let height = 500
    let context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let first = NSColor(hue: hue.truncatingRemainder(dividingBy: 1), saturation: 0.65, brightness: 0.95, alpha: 1).cgColor
    let second = NSColor(hue: (hue + 0.18).truncatingRemainder(dividingBy: 1), saturation: 0.8, brightness: 0.45, alpha: 1).cgColor
    let gradient = CGGradient(
      colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [first, second] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(
      gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
    context.setFillColor(CGColor(gray: 1, alpha: 0.25))
    context.fillEllipse(in: CGRect(x: 520, y: 250, width: 190, height: 190))
    let output = NSMutableData()
    let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return output as Data
  }

  func shutdown() async {
    await panel.shutdown()
  }

  // MARK: Hosting

  /// The inspector alone in a window that is never shown, at `size`, in `appearance`.
  func host(size: NSSize, dark: Bool = false) -> (window: NSWindow, view: NSHostingView<AnyView>) {
    host(size: size, dark: dark) { InstalledInspector() }
  }

  /// Any view, hosted the way the panel hosts the inspector: with the controller, the images, the
  /// panel's visibility, its theme and language.
  func host<Content: View>(
    size: NSSize, dark: Bool = false, @ViewBuilder _ content: () -> Content
  ) -> (window: NSWindow, view: NSHostingView<AnyView>) {
    let controller = controller
    let root = content()
      .environment(controller)
      .environment(\.panelImages, controller.images)
      .environment(\.panelIsVisible, true)
      .panelTheme(theme: controller.theme, locale: PanelLocale.shared)
    let view = NSHostingView(rootView: AnyView(root))
    view.sceneBridgingOptions = []
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .resizable],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = view
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    view.frame = NSRect(origin: .zero, size: size)
    view.layoutSubtreeIfNeeded()
    return (window, view)
  }
}
