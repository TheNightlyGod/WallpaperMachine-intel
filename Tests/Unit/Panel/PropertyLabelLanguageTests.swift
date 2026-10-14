import XCTest

@testable import WallpaperMachine

/// A wallpaper's own label tables are resolved by the bridge (the bridge crate's tests cover
/// that). These cover what the app does around it: name the language, and show the
/// relabelled inspector at once, without losing or mixing up what is open.
@MainActor
final class PropertyLabelLanguageTests: ControlPanelTestCase {
  private static let japanese = AppLanguage.named("ja")!
  private static let chinese = AppLanguage.named("zh-Hans")!

  private func options(_ id: String, label: String) -> BridgeWallpaperOptionsSnapshot {
    BridgeSnapshotFixtures.options(
      wallpaperId: id,
      properties: [BridgeSnapshotFixtures.textProperty(id: "size", labelHtml: label)])
  }

  private func label(of snapshot: BridgeWallpaperOptionsSnapshot?) -> String? {
    snapshot?.properties.first?.labelHtml
  }

  func testTheOpenInspectorIsReadAgainInTheNewLanguage() async throws {
    let (store, bridge) = makeStore()
    store.wallpaperOptionsSnapshot = options("scene-1", label: "Size")
    bridge.options["scene-1"] = options("scene-1", label: "Size")
    // The bridge relabels from its tables once it knows the language.
    bridge.onLabelLanguages = { locales in
      bridge.options["scene-1"] = self.options(
        "scene-1", label: locales.first == "zh-chs" ? "大小" : "Size")
    }
    let revision = store.snapshotRevision

    try await store.setLabelLanguageAsync(Self.chinese)

    XCTAssertEqual(bridge.labelLanguageCalls, [["zh-chs", "en-us"]])
    XCTAssertEqual(label(of: store.wallpaperOptionsSnapshot), "大小")
    XCTAssertNotEqual(
      store.snapshotRevision, revision, "The panel redraws on a new revision, not on new text")

    try await store.setLabelLanguageAsync(.english)
    XCTAssertEqual(bridge.labelLanguageCalls.last, ["en-us"])
    XCTAssertEqual(label(of: store.wallpaperOptionsSnapshot), "Size")
  }

  func testNothingIsReadWhenNoInspectorIsOpen() async throws {
    let (store, bridge) = makeStore()
    store.wallpaperOptionsSnapshot = nil
    let revision = store.snapshotRevision

    try await store.setLabelLanguageAsync(Self.japanese)

    XCTAssertEqual(bridge.labelLanguageCalls, [["ja-jp", "en-us"]], "The next wallpaper still needs it")
    XCTAssertEqual(bridge.optionRequests, [])
    XCTAssertEqual(store.snapshotRevision, revision)
  }

  func testAFailedRequestLeavesTheInspectorAsItWas() async throws {
    let (store, bridge) = makeStore()
    store.wallpaperOptionsSnapshot = options("scene-1", label: "Size")
    bridge.failLabelLanguages = true
    let revision = store.snapshotRevision

    do {
      try await store.setLabelLanguageAsync(Self.chinese)
      XCTFail("The failure must reach the caller, which decides it is not worth failing over")
    } catch {}

    XCTAssertEqual(bridge.optionRequests, [])
    XCTAssertEqual(label(of: store.wallpaperOptionsSnapshot), "Size")
    XCTAssertEqual(store.snapshotRevision, revision)
  }

  func testAReadThatFinishesAfterAnotherWallpaperOpenedIsDropped() async throws {
    let (store, bridge) = makeStore()
    store.wallpaperOptionsSnapshot = options("scene-1", label: "Size")
    bridge.holdOptions = true
    let revision = store.snapshotRevision

    let change = Task { try await store.setLabelLanguageAsync(Self.chinese) }
    var polls = 0
    while bridge.pendingOptions.isEmpty {
      polls += 1
      guard polls < 2_000 else { return XCTFail("The inspector was never read again") }
      await Task.yield()
    }
    // The user opens another wallpaper while the first one's labels are still on their way.
    store.wallpaperOptionsSnapshot = options("scene-2", label: "Speed")
    bridge.finishOption(options("scene-1", label: "大小"))
    try await change.value

    XCTAssertEqual(store.wallpaperOptionsSnapshot?.wallpaperId, "scene-2")
    XCTAssertEqual(label(of: store.wallpaperOptionsSnapshot), "Speed")
    XCTAssertEqual(store.snapshotRevision, revision)
  }

  func testChoosingALanguageInThePanelRelabelsTheOpenInspector() async throws {
    try await withPanel { panel in
      panel.store.wallpaperOptionsSnapshot = self.options("scene-1", label: "Size")
      panel.bridge.options["scene-1"] = self.options("scene-1", label: "Size")
      panel.bridge.onLabelLanguages = { locales in
        panel.bridge.options["scene-1"] = self.options(
          "scene-1", label: locales.first == "ja-jp" ? "サイズ" : "Size")
      }
      let rows = {
        ((panel.controller.snapshot()["options"] as? [String: Any])?["properties"]
          as? [[String: Any]])?.compactMap { $0["label"] as? String }
      }
      XCTAssertEqual(rows(), ["Size"])

      try await panel.controller.perform("languageSetting", body: ["value": "ja"])

      XCTAssertEqual(panel.bridge.labelLanguageCalls, [["ja-jp", "en-us"]])
      XCTAssertEqual(rows(), ["サイズ"])

      // A bridge that cannot take the language must not undo the choice the user made.
      panel.bridge.failLabelLanguages = true
      try await panel.controller.perform("languageSetting", body: ["value": "zh-Hans"])
      XCTAssertNil(panel.controller.actionError)
      XCTAssertEqual(
        (panel.controller.snapshot()["language"] as? [String: Any])?["effective"] as? String,
        "zh-Hans")
    }
  }
}
