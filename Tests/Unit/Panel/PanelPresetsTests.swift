import XCTest

@testable import WallpaperMachine

/// The presets bar of the selected wallpaper at the panel level: the state it is drawn from, the six
/// actions and the sentence each leaves behind. What a preset holds, how it is validated and applied
/// and how its files travel is `WallpaperPresetStoreTests`'.
@MainActor
final class PanelPresetsTests: XCTestCase {
  private func options(mode: Bool, dirty: Bool = false, supported: Bool = true)
    -> BridgeWallpaperOptionsSnapshot
  {
    BridgeSnapshotFixtures.options(
      wallpaperId: "wp", kind: .projectScene, supported: supported, dirty: dirty,
      properties: [PanelPropertyContext.property("mode", .bool, .bool(value: mode))])
  }

  private func show(_ context: PanelPropertyContext, _ options: BridgeWallpaperOptionsSnapshot) {
    context.bridge.options["wp"] = options
    context.store.wallpaperOptionsSnapshot = options
  }

  func testTheBarKnowsTheSavedPresetsAndWhatBlocksSavingOne() async throws {
    try await PanelPropertyContext.with { context in
      let controller = context.controller
      show(context, options(mode: false))

      var state = try XCTUnwrap(controller.presetsState)
      XCTAssertEqual(state.wallpaperID, "wp")
      XCTAssertTrue(state.items.isEmpty)
      XCTAssertTrue(state.canSave)
      XCTAssertFalse(state.isDirty)
      XCTAssertNil(state.status)
      XCTAssertNil(state.error)

      controller.setPropertyText("typed", property: "note", in: "wp")
      state = try XCTUnwrap(controller.presetsState)
      XCTAssertTrue(state.isDirty, "typed text is a change the bar counts, as the footer does")
      XCTAssertFalse(state.canSave)
      controller.discardPropertyTextDrafts(of: "wp")

      show(context, options(mode: false, dirty: true))
      XCTAssertEqual(controller.presetsState?.isDirty, true)
      XCTAssertEqual(controller.presetsState?.canSave, false, "a draft in the bridge blocks saving")

      show(context, options(mode: false, supported: false))
      XCTAssertEqual(controller.presetsState?.canSave, false, "a wallpaper that cannot be rendered cannot be saved")

      show(context, options(mode: false))
      var release: CheckedContinuation<Void, Never>?
      let store = context.store
      let running = Task { @MainActor in
        await store.commands.run { await withCheckedContinuation { release = $0 } }
      }
      for _ in 0..<200 where release == nil { await Task.yield() }
      XCTAssertEqual(controller.presetsState?.canSave, false, "nothing is saved while a command runs")
      release?.resume()
      _ = await running.value
      XCTAssertEqual(controller.presetsState?.canSave, true)

      context.store.appSnapshot.selectedWallpaperId = "gone"
      XCTAssertNil(controller.presetsState, "with no installed wallpaper selected there is no bar")
    }
  }

  func testSavingNeedsACleanAppliedStateAndHandsBackThePresetToPick() async throws {
    try await PanelPropertyContext.with { context in
      let controller = context.controller
      show(context, options(mode: true, dirty: true))
      do {
        try await controller.savePreset("wp", name: "Evening")
        XCTFail("a draft cannot become the saved applied state")
      } catch {}
      XCTAssertTrue(controller.presetsState?.items.isEmpty == true)

      show(context, options(mode: true))
      let id = try await controller.savePreset("wp", name: "Evening")

      let state = try XCTUnwrap(controller.presetsState)
      XCTAssertEqual(state.items.map(\.name), ["Evening"])
      XCTAssertEqual(id, state.items.first?.id, "the bar picks the preset that was just saved")
      XCTAssertEqual(state.status, L("Saved the applied wallpaper properties."))

      await assertThrows("an empty name") { try await controller.savePreset("wp", name: "  ") }
      await assertThrows("a name over 120 characters") {
        try await controller.savePreset("wp", name: String(repeating: "x", count: 121))
      }
      XCTAssertEqual(controller.presetsState?.items.count, 1)
    }
  }

  func testRenamingChangesTheListSoTheStatusGoesAndDeletingNeedsACleanWallpaper() async throws {
    try await PanelPropertyContext.with { context in
      let controller = context.controller
      show(context, options(mode: true))
      let id = try await save(controller, "Evening")
      XCTAssertNotNil(controller.presetsState?.status)

      try await controller.renamePreset(id, to: "Night")
      XCTAssertEqual(controller.presetsState?.items.map(\.name), ["Night"])
      XCTAssertNil(controller.presetsState?.status, "the status clears whenever the list changes")

      show(context, options(mode: true, dirty: true))
      await assertThrows("deleting while the wallpaper has pending edits") { try await controller.deletePreset(id) }
      XCTAssertEqual(controller.presetsState?.items.count, 1)

      show(context, options(mode: true))
      try await controller.deletePreset(id)
      XCTAssertTrue(controller.presetsState?.items.isEmpty == true)
      await assertThrows("an unknown preset") { try await controller.deletePreset(id) }
    }
  }

  func testApplyingAPresetStagesItsValuesAppliesThemAndNeverNeedsTheUserToWait() async throws {
    try await PanelPropertyContext.with { context in
      let controller = context.controller
      show(context, options(mode: true))
      let id = try await save(controller, "On")
      show(context, options(mode: false))

      try await controller.applyPreset("wp", preset: id)

      XCTAssertEqual(context.bridge.edits, [.init(propertyId: "mode", value: .bool(value: true))])
      XCTAssertEqual(context.bridge.events, ["edit wp", "apply wp"])
      XCTAssertEqual(controller.presetsState?.status, L("Property preset applied."))

      show(context, options(mode: false, dirty: true))
      await assertThrows("applying over pending edits") { try await controller.applyPreset("wp", preset: id) }
      await assertThrows("an unknown preset") { try await controller.applyPreset("wp", preset: "nope") }
    }
  }

  func testExportWritesTheFileTheSavePanelChoosesAndCancelLeavesNothing() async throws {
    try await PanelPropertyContext.with { context in
      let controller = context.controller
      show(context, options(mode: true))
      let id = try await save(controller, "On")
      let target = context.panel.root.appendingPathComponent("exported.json")

      // Cancel: no file, and no sentence about one.
      try await controller.exportPreset("wp", preset: id)
      let panel = try XCTUnwrap(context.panel.dialogs.panels.first)
      XCTAssertEqual(panel.title, String(localized: "Export Property Preset"))
      XCTAssertEqual(panel.nameFieldStringValue, "wallpaper-properties.json")
      XCTAssertEqual(panel.allowedContentTypes.map(\.identifier), ["public.json"])
      XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
      XCTAssertNotEqual(
        controller.presetsState?.status,
        L("Property preset exported. External file references require choosing the files again after import."))

      context.panel.dialogs.chosenURL = target
      try await controller.exportPreset("wp", preset: id)
      XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
      XCTAssertEqual(
        controller.presetsState?.status,
        L("Property preset exported. External file references require choosing the files again after import."))

      await assertInspectorInvalidValue("a preset of another wallpaper") {
        try await controller.exportPreset("wp2", preset: id)
      }
    }
  }

  func testImportAddsAPresetFromAFileAndNeverAppliesIt() async throws {
    try await PanelPropertyContext.with { context in
      let controller = context.controller
      show(context, options(mode: true))
      let id = try await save(controller, "On")
      let file = context.panel.root.appendingPathComponent("shared.json")
      context.panel.presets.chooseExportFile = { _ in file }
      try await controller.exportPreset("wp", preset: id)
      context.panel.presets.chooseExportFile = nil

      // Cancel adds nothing.
      try await controller.importPreset(into: "wp")
      XCTAssertEqual(controller.presetsState?.items.count, 1)
      let picker = try XCTUnwrap(context.panel.dialogs.panels.last as? NSOpenPanel)
      XCTAssertEqual(picker.title, String(localized: "Import Property Preset"))
      XCTAssertFalse(picker.allowsMultipleSelection)
      XCTAssertFalse(picker.canChooseDirectories)

      context.panel.dialogs.chosenURL = file
      let before = context.bridge.events
      try await controller.importPreset(into: "wp")
      XCTAssertEqual(controller.presetsState?.items.count, 2, "a new preset, never a replacement")
      XCTAssertEqual(
        controller.presetsState?.status, L("Property preset imported. Apply it to change this wallpaper."))
      XCTAssertEqual(context.bridge.events, before, "importing never applies it")

      // Only a regular file is read: a link or a folder is refused.
      let link = context.panel.root.appendingPathComponent("link.json")
      try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
      context.panel.dialogs.chosenURL = link
      await assertInspectorInvalidValue("a symbolic link") { try await controller.importPreset(into: "wp") }
      context.panel.dialogs.chosenURL = context.panel.root
      await assertInspectorInvalidValue("a folder") { try await controller.importPreset(into: "wp") }
      XCTAssertEqual(controller.presetsState?.items.count, 2)
    }
  }

  func testEveryPresetActionClearsTheBannerFirstAndWaitsItsTurnInTheQueue() async throws {
    try await PanelPropertyContext.with { context in
      let controller = context.controller
      show(context, options(mode: true))
      controller.errors.actionError = "An earlier failure"
      var release: CheckedContinuation<Void, Never>?
      let store = context.store
      let running = Task { @MainActor in
        await store.commands.run { await withCheckedContinuation { release = $0 } }
      }
      for _ in 0..<200 where release == nil { await Task.yield() }

      let saving = Task { try await controller.savePreset("wp", name: "Queued") }
      for _ in 0..<200 where store.commands.waiting.isEmpty { await Task.yield() }
      XCTAssertEqual(store.commands.waiting.count, 1, "the save waits behind the running command")
      XCTAssertNil(controller.errors.actionError, "the banner is cleared before the work starts")
      XCTAssertTrue(controller.presetsState?.items.isEmpty == true)

      release?.resume()
      _ = await running.value
      _ = try await saving.value
      XCTAssertEqual(controller.presetsState?.items.map(\.name), ["Queued"])
    }
  }

  private func save(_ controller: PanelController, _ name: String) async throws -> String {
    let id = try await controller.savePreset("wp", name: name)
    return try XCTUnwrap(id)
  }

  private func assertThrows(
    _ what: String, file: StaticString = #filePath, line: UInt = #line, _ work: () async throws -> Void
  ) async {
    do {
      try await work()
      XCTFail("Accepted \(what)", file: file, line: line)
    } catch {}
  }
}
