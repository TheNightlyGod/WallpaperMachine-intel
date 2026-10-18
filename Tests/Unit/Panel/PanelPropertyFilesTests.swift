import XCTest

@testable import WallpaperMachine

/// The `file`, `directory` and `texture` property editors: what the panel sends to the engine, what
/// the pickers are configured with, and where a failure is shown. A texture moved out of the old
/// directory bucket, so it is held to the control it has always had: the image picker, a pending
/// edit, no user-asset path.
@MainActor
final class PanelPropertyFilesTests: XCTestCase {
  private func install(_ context: PanelPropertyContext) {
    var cover = PanelPropertyContext.property("cover", .file, .empty)
    cover.fileFilter = .image
    var album = PanelPropertyContext.property("album", .directory, .empty)
    album.fileFilter = .image
    let options = BridgeSnapshotFixtures.options(
      wallpaperId: "wp", kind: .webpage,
      properties: [cover, album, PanelPropertyContext.property("backdrop", .texture, .string(value: ""))])
    context.bridge.options["wp"] = options
    context.store.wallpaperOptionsSnapshot = options
  }

  private func chosenFile(_ context: PanelPropertyContext, named name: String = "picked.png") throws -> URL {
    let url = context.panel.root.appendingPathComponent(name)
    try Data([0x89]).write(to: url)
    return url
  }

  func testClearingAPathSendsNilNotAnEmptyString() async throws {
    try await PanelPropertyContext.with { context in
      install(context)
      try await context.controller.clearAssetPath("wp", property: "cover")

      XCTAssertEqual(context.bridge.paths.count, 1)
      let call = try XCTUnwrap(context.bridge.paths.first)
      XCTAssertEqual(call.wallpaperId, "wp")
      XCTAssertEqual(call.propertyId, "cover")
      XCTAssertNil(call.path, "an empty string would be stored by the engine as a path")
    }
  }

  func testChoosingWithoutAWindowSendsNoPathAndTheFilePickerIsConfiguredForTheProperty() async throws {
    try await PanelPropertyContext.with { context in
      install(context)
      try await context.controller.chooseAssetPath("wp", property: "cover")
      try await context.controller.chooseAssetPath("wp", property: "album")

      XCTAssertTrue(context.bridge.paths.isEmpty, "a picker that was never presented must not commit a path")
      let panels = context.panel.dialogs.panels.compactMap { $0 as? NSOpenPanel }
      XCTAssertEqual(panels.count, 2)
      let file = panels[0]
      XCTAssertTrue(file.canChooseFiles)
      XCTAssertFalse(file.canChooseDirectories)
      XCTAssertFalse(file.canCreateDirectories)
      XCTAssertFalse(file.allowedContentTypes.isEmpty, "a file is offered only in the types the property accepts")
      XCTAssertEqual(file.message, String(localized: "Choose a file for cover."))
      let folder = panels[1]
      XCTAssertTrue(folder.canChooseDirectories)
      XCTAssertFalse(folder.canChooseFiles)
      XCTAssertEqual(folder.message, String(localized: "Choose a folder for album."))
    }
  }

  func testATexturePropertyIsRefusedByThePathEditorAndAFileByTheImagePicker() async throws {
    try await PanelPropertyContext.with { context in
      install(context)
      let controller = context.controller
      await assertInspectorInvalidValue("a path for a scene texture") {
        try await controller.chooseAssetPath("wp", property: "backdrop")
      }
      await assertInspectorInvalidValue("clearing a scene texture as a path") {
        try await controller.clearAssetPath("wp", property: "backdrop")
      }
      await assertInspectorInvalidValue("the image picker for a file property") {
        try await controller.chooseTextureImage("wp", property: "cover")
      }
      XCTAssertTrue(context.bridge.paths.isEmpty)
      XCTAssertTrue(context.panel.dialogs.panels.isEmpty, "nothing was presented")
    }
  }

  func testAChosenFileIsSavedAtOnceAndClearsWhatWasKnownAboutTheProperty() async throws {
    try await PanelPropertyContext.with { context in
      install(context)
      let controller = context.controller
      let url = try chosenFile(context)
      context.panel.dialogs.chosenURL = url
      controller.propertyPathErrors["wp"] = ["cover": "An old failure"]
      controller.propertyAssets["wp"] = ["cover": PanelPropertyAsset(path: "/old", name: "old")]

      try await controller.chooseAssetPath("wp", property: "cover")

      XCTAssertEqual(context.bridge.paths.map(\.path), [url.path], "saved as it is picked, not a draft")
      XCTAssertNil(controller.propertyPathErrors["wp"]?["cover"], "the earlier failure is cleared first")
      XCTAssertNil(controller.propertyAssets["wp"]?["cover"], "and so is the measurement of the old path")
      XCTAssertNil(controller.errors.message)
    }
  }

  func testAWallpaperFolderThatCannotHoldTheFileRecordsWhyBesideTheControlAndNotInTheBanner() async throws {
    try await PanelPropertyContext.with { context in
      install(context)
      let controller = context.controller
      context.panel.dialogs.chosenURL = try chosenFile(context)

      let project = context.panel.library.appendingPathComponent("wp")
      try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: project.path)
      defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: project.path) }
      try await controller.chooseAssetPath("wp", property: "cover")
      XCTAssertEqual(
        controller.propertyPathErrors["wp"]?["cover"],
        "This wallpaper’s folder is read-only, so the file cannot be prepared for it.")

      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: project.path)
      try FileManager.default.removeItem(at: project)
      try await controller.chooseAssetPath("wp", property: "cover")
      XCTAssertEqual(
        controller.propertyPathErrors["wp"]?["cover"],
        "This wallpaper’s folder is missing, so the file cannot be prepared for it.")

      XCTAssertTrue(context.bridge.paths.isEmpty, "the choice never reached the engine")
      XCTAssertNil(controller.errors.message, "a failure belongs beside the control the user just used")
      XCTAssertEqual(
        context.controller.inspectorOptions(for: "wp").flatMap { options in
          guard case .file(let state) = options.properties.first?.control else { return nil }
          return state.error
        }, "This wallpaper’s folder is missing, so the file cannot be prepared for it.",
        "and the row carries it")
    }
  }

  func testTheTexturePickerStoresThePathAsAPendingEditAndCancelChangesNothing() async throws {
    try await PanelPropertyContext.with { context in
      install(context)
      let controller = context.controller
      try await controller.chooseTextureImage("wp", property: "backdrop")
      XCTAssertTrue(context.bridge.edits.isEmpty, "cancel changes nothing")
      let picker = try XCTUnwrap(context.panel.dialogs.panels.first as? NSOpenPanel)
      XCTAssertEqual(picker.title, String(localized: "Choose Image"))
      XCTAssertFalse(picker.allowedContentTypes.isEmpty)

      let url = try chosenFile(context, named: "sky.png")
      context.panel.dialogs.chosenURL = url
      try await controller.chooseTextureImage("wp", property: "backdrop")
      XCTAssertEqual(
        context.bridge.edits, [.init(propertyId: "backdrop", value: .string(value: url.path))],
        "the path of the image, not a copy, as a pending edit")
      XCTAssertEqual(context.bridge.options["wp"]?.dirty, true)

      // Clearing the image is an edit with an empty string.
      try await controller.commitProperty("wp", property: "backdrop", value: .string(value: ""))
      XCTAssertEqual(context.bridge.edits.last, .init(propertyId: "backdrop", value: .string(value: "")))
    }
  }

  func testAPropertyThatTheBridgeNoLongerOffersIsRefusedBeforeAnyPickerOpens() async throws {
    try await PanelPropertyContext.with { context in
      install(context)
      let controller = context.controller
      await assertInspectorInvalidValue("a property the wallpaper does not have") {
        try await controller.chooseAssetPath("wp", property: "nope")
      }
      do {
        try await controller.chooseAssetPath("gone", property: "cover")
        XCTFail("a wallpaper the library no longer has must be refused")
      } catch {
        XCTAssertEqual(error.localizedDescription, "This wallpaper is no longer installed. Refresh your library.")
      }
      XCTAssertTrue(context.panel.dialogs.panels.isEmpty)
    }
  }
}
