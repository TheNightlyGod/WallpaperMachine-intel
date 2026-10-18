import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import XCTest

@testable import WallpaperMachine

/// A wallpaper of a test library: what the renderer lists and what its folder holds.
struct LibrarySpec {
  enum Preview {
    case none
    /// A still picture in this hue (0 to 1).
    case picture(Double)
    /// An animated GIF.
    case animation
  }

  var id: String
  var title: String
  var kind: BridgeWallpaperKind = .video
  var tags: [String] = []
  var approved = false
  var preview = Preview.picture(0.6)
  var supported = true

  init(
    _ id: String, _ title: String? = nil, kind: BridgeWallpaperKind = .video,
    tags: [String] = [], approved: Bool = false, preview: Preview = .picture(0.6),
    supported: Bool = true
  ) {
    self.id = id
    self.title = title ?? id
    self.kind = kind
    self.tags = tags
    self.approved = approved
    self.preview = preview
    self.supported = supported
  }
}

extension PanelFixture {
  /// Writes a folder for each spec under this fixture's library (a preview picture, and a
  /// manifest when it has tags or approval) and hands the renderer's listing of them to the
  /// store. Nothing is measured yet: `settleLibrary` waits for the background services.
  @discardableResult
  func installLibrary(_ specs: [LibrarySpec]) throws -> [BridgeWallpaperEntry] {
    var entries: [BridgeWallpaperEntry] = []
    for spec in specs {
      let folder = library.appendingPathComponent(spec.id, isDirectory: true)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      var previewPath: String?
      switch spec.preview {
      case .none: break
      case .picture(let hue):
        let file = folder.appendingPathComponent("preview.png")
        try Self.picture(hue: hue).write(to: file)
        previewPath = file.path
      case .animation:
        let file = folder.appendingPathComponent("preview.gif")
        try PanelTestCase.gif(frames: 3, brightness: 0.55).write(to: file)
        previewPath = file.path
      }
      if !spec.tags.isEmpty || spec.approved {
        var manifest: [String: Any] = ["tags": spec.tags, "title": spec.title]
        if spec.approved { manifest["approved"] = true }
        try JSONSerialization.data(withJSONObject: manifest)
          .write(to: folder.appendingPathComponent("project.json"))
      }
      entries.append(
        BridgeWallpaperEntry(
          id: spec.id, title: spec.title, kind: spec.kind, supported: spec.supported,
          active: false, selected: false, previewPath: previewPath))
    }
    store.librarySnapshot.wallpapers = entries
    return entries
  }

  /// Waits for the background services to have read every folder: sizes and tags, and the stamps
  /// of the previews. Rows read before this show covers as pending.
  func settleLibrary(timeout: TimeInterval = 10) async throws {
    _ = controller.libraryRows
    let count = store.librarySnapshot.wallpapers.count
    let previews = store.librarySnapshot.wallpapers.filter { $0.previewPath != nil }.count
    try await waitUntil(timeout: timeout) {
      controller.libraryMetrics.measured.count >= count
        && controller.libraryCovers.stamps.count >= previews
    }
    _ = controller.libraryRows
  }

  /// The renderer's first reading of the library, which ends the loading state.
  func loadLibrary() async throws {
    let store = store
    bridge.bundleProvider = {
      BridgeSnapshotBundle(
        app: store.appSnapshot, library: store.librarySnapshot,
        wallpaperOptions: store.wallpaperOptionsSnapshot,
        monitorInformation: store.monitorInformationSnapshot, settings: store.settingsSnapshot)
    }
    try await store.refreshLibraryAsync()
  }

  /// Makes `id` the wallpaper the primary display shows.
  func showOnPrimary(_ id: String) {
    store.monitorInformationSnapshot.rows = [
      BridgeMonitorInfoRow(
        displayId: "primary", title: "primary", wallpaperId: id, wallpaperTitle: id,
        mirrorTargetDisplayId: nil, mirrorTargetTitle: nil, scalingMode: "fill",
        targetFps: "30", audioResponse: false)
    ]
  }

  /// A picture of two bands, a sky and a ground, as the wallpapers of the design mockup have.
  static func picture(hue: Double, size: Int = 360) -> Data {
    let output = NSMutableData()
    let destination = CGImageDestinationCreateWithData(
      output, UTType.png.identifier as CFString, 1, nil)!
    let context = CGContext(
      data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    func colour(_ h: Double, _ s: Double, _ b: Double) -> CGColor {
      let color = NSColor(hue: h.truncatingRemainder(dividingBy: 1), saturation: s, brightness: b, alpha: 1)
      return color.usingColorSpace(.deviceRGB)!.cgColor
    }
    let sky = [colour(hue, 0.55, 0.35), colour(hue + 0.08, 0.5, 0.85)] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: sky, locations: [0, 1])!
    context.drawLinearGradient(
      gradient, start: CGPoint(x: 0, y: CGFloat(size)), end: CGPoint(x: 0, y: CGFloat(size) * 0.38),
      options: [])
    context.setFillColor(colour(hue + 0.55, 0.45, 0.42))
    context.fill(CGRect(x: 0, y: 0, width: size, height: Int(Double(size) * 0.38)))
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return output as Data
  }
}

/// The whole panel in a window that is never ordered front, over a fixture's controller, so a test
/// can both drive the controller's models and look at what is drawn.
@MainActor
final class HostedPanel {
  let window: NSWindow
  let hosting: NSHostingController<AnyView>

  init(_ fixture: PanelFixture, size: NSSize, dark: Bool = false) {
    let controller = fixture.controller
    hosting = NSHostingController(
      rootView: AnyView(
        PanelRootView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .environment(controller)
          .environment(\.panelImages, controller.images)))
    hosting.sizingOptions = []
    hosting.sceneBridgingOptions = [.toolbars, .title]
    window = ControlPanelWindow.make(contentViewController: hosting, delegate: nil)
    hosting.view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    layout(at: size)
  }

  func layout(at size: NSSize) {
    window.setContentSize(size)
    window.layoutIfNeeded()
    hosting.view.layoutSubtreeIfNeeded()
  }

  /// Lets the run loop turn so what was asked for is drawn.
  func settle(_ seconds: Double = 0.4) async throws {
    try await Task.sleep(for: .seconds(seconds))
    hosting.view.layoutSubtreeIfNeeded()
  }

  /// A PNG of what the hosted content draws.
  func png() -> Data? {
    let view = hosting.view
    view.layoutSubtreeIfNeeded()
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
    view.cacheDisplay(in: view.bounds, to: rep)
    return rep.representation(using: .png, properties: [:])
  }

  /// The widest split view inside the window's content; wider than the window means the panel asks
  /// for more room than it was given.
  var widestSplitView: CGFloat {
    func widest(_ view: NSView) -> CGFloat {
      let own = (view as? NSSplitView)?.frame.width ?? 0
      return view.subviews.map(widest).reduce(own, max)
    }
    return widest(window.contentView!)
  }

  func close() {
    window.contentViewController = nil
    window.close()
  }
}

/// Rows for the tests of the pure rules, which need no library on disk.
enum LibraryRows {
  static func row(
    _ id: String, _ title: String? = nil, kind: LibraryRow.Kind = .video, size: Int64? = nil,
    added: TimeInterval? = nil, tags: [String] = [], approved: Bool = false, active: Bool = false,
    update: Bool = false, supported: Bool = true, preview: URL? = nil,
    cover: LibraryRow.Cover = .none
  ) -> LibraryRow {
    LibraryRow(
      id: id, title: title ?? id, kind: kind, previewFile: preview, cover: cover,
      canAnimate: preview.map { LibraryRow.animatedPreviewExtensions.contains($0.pathExtension) }
        ?? false,
      isActive: active, isSupported: supported, tags: tags, isApproved: approved, size: size,
      addedAt: added.map { Date(timeIntervalSince1970: $0) }, energy: nil,
      isUpdateAvailable: update, updatedAt: nil)
  }

  static func titles(_ rows: [LibraryRow]) -> [String] { rows.map(\.title) }
}
