import Foundation
import XCTest

@testable import WallpaperMachine

/// A visibility rule hides a property from the panel, but the bridge still reports it
/// (not enabled), so everything the panel builds from the options has to leave it out
/// on its own: the rows the page is given, the folders it measures and the text it waits for.
@MainActor
final class WebPanelHiddenPropertyTests: XCTestCase {
  func testAPropertyAHiddenRuleHidesIsNotListedOrMeasuredForThePage() throws {
    let context = try Context()
    defer { context.tearDown() }
    let shown = context.root.appendingPathComponent("shown")
    let tucked = context.root.appendingPathComponent("tucked")
    for folder in [shown, tucked] {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try Data().write(to: folder.appendingPathComponent("a.png"))
    }
    let options = BridgeSnapshotFixtures.options(
      wallpaperId: "scene-1", kind: .projectScene,
      properties: [
        Self.property(id: "gate", kind: .bool, value: .bool(value: false)),
        Self.property(id: "detail", kind: .textInput, value: .string(value: "x"), enabled: false),
        Self.property(id: "shown", kind: .directory, value: .string(value: shown.path)),
        Self.property(
          id: "tucked", kind: .directory, value: .string(value: tucked.path), enabled: false),
        Self.property(id: "note", kind: .text, value: .empty),
      ])
    context.store.wallpaperOptionsSnapshot = options

    let rows = try XCTUnwrap(
      (context.controller.snapshot()["options"] as? [String: Any])?["properties"]
        as? [[String: Any]])
    XCTAssertEqual(
      rows.compactMap { $0["id"] as? String }, ["gate", "shown", "note"],
      "Rows keep their authored order and a hidden one is not offered to the page")
    XCTAssertEqual(
      Set(context.controller.measuredAssets(for: options).keys), ["shown"],
      "A folder nobody can see is not read")
  }

  func testPendingTextGoesWithThePropertyARuleHides() async throws {
    let context = try Context()
    defer { context.tearDown() }
    func options(detailEnabled: Bool) -> BridgeWallpaperOptionsSnapshot {
      BridgeSnapshotFixtures.options(
        wallpaperId: "scene-1", kind: .projectScene,
        properties: [
          Self.property(id: "gate", kind: .bool, value: .bool(value: detailEnabled)),
          Self.property(
            id: "detail", kind: .textInput, value: .string(value: "x"), enabled: detailEnabled),
          Self.property(id: "title", kind: .textInput, value: .string(value: "y")),
        ])
    }
    context.store.wallpaperOptionsSnapshot = options(detailEnabled: true)
    let detail = WallpaperEditorState.FieldKey(wallpaperID: "scene-1", fieldID: "detail")
    let title = WallpaperEditorState.FieldKey(wallpaperID: "scene-1", fieldID: "title")
    context.store.editorState.setPropertyText("typed, not sent", key: detail)
    context.store.editorState.setPropertyText("also unsent", key: title)
    let closed = options(detailEnabled: false)
    context.bridge.answer = { [store = context.store] in
      BridgeWallpaperMutationBundle(
        app: store.appSnapshot, library: store.librarySnapshot, wallpaperOptions: closed,
        monitorInformation: store.monitorInformationSnapshot, settings: store.settingsSnapshot)
    }

    try await context.store.editPropertyAsync(
      wallpaperId: "scene-1", propertyId: "gate", value: .bool(value: false))

    XCTAssertNil(
      context.store.editorState.propertyTextDrafts[detail],
      "Text for a field that is gone cannot be applied, so it is not kept as a pending edit")
    XCTAssertEqual(context.store.editorState.propertyTextDrafts[title], "also unsent")
  }

  private static func property(
    id: String, kind: BridgePropertyKind, value: BridgePropertyValue, enabled: Bool = true
  ) -> BridgePropertyDescriptor {
    BridgePropertyDescriptor(
      id: id, kind: kind, labelHtml: id, value: value, defaultValue: value, slider: nil,
      comboOptions: [], fileFilter: nil, directoryMode: nil, dirty: false,
      canRestoreDefaults: false, enabled: enabled, assetManaged: false, assetMissing: false,
      assetSourcePath: nil)
  }

  @MainActor
  private final class Context {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "panel-hidden-\(UUID().uuidString)")
    let bridge = RuleBridge(noPointer: .init())
    let store: BridgeStore
    let controller: WebPanelController

    init() throws {
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      store = BridgeStore(bridge: bridge)
      let defaults = TemporaryDefaults.makeForCurrentTest().defaults
      controller = WebPanelController(
        store: store, navigation: ControlPanelNavigation(),
        workshop: WorkshopStore(
          downloader: WorkshopDownloadManager(sessionDirectory: root), supportDirectory: root,
          defaults: defaults),
        defaults: defaults, appLanguage: .english())
      store.settingsSnapshot = BridgeSnapshotFixtures.settings()
      store.librarySnapshot = BridgeLibrarySnapshot(
        wallpapers: [
          BridgeWallpaperEntry(
            id: "scene-1", title: "Scene one", kind: .projectScene, supported: true, active: false,
            selected: true, previewPath: nil)
        ],
        scanStatus: BridgeLibraryScanStatus(scanning: false, done: 0, total: 0), sceneCount: 1,
        videoCount: 0, webpageCount: 0, unknownCount: 0)
    }

    func tearDown() {
      controller.stop()
      try? FileManager.default.removeItem(at: root)
    }
  }
}

/// Answers a property edit with the state the engine would report afterwards.
private final class RuleBridge: WallpaperBridge {
  @MainActor var answer: (@MainActor () -> BridgeWallpaperMutationBundle)?

  override func editProperty(wallpaperId: String, propertyId: String, value: BridgePropertyValue)
    async throws -> BridgeWallpaperMutationBundle
  {
    try await reply()
  }

  @MainActor private func reply() throws -> BridgeWallpaperMutationBundle {
    guard let answer else { throw CancellationError() }
    return answer()
  }
}
