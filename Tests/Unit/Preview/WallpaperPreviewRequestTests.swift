import Foundation
import XCTest
@testable import WallpaperMachine

@MainActor
final class WallpaperPreviewRequestTests: XCTestCase {
    private var root: URL!
    private var library: URL!
    private var project: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("preview-inputs-\(UUID().uuidString)")
        library = root.appendingPathComponent("Library")
        project = library.appendingPathComponent("preview")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try writeProject(type: "web", entry: "index.html")
        try Data("<!doctype html><title>Preview</title>".utf8).write(to: project.appendingPathComponent("index.html"))
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func writeProject(type: String, entry: String) throws {
        try JSONSerialization.data(withJSONObject: ["type": type, "file": entry])
            .write(to: project.appendingPathComponent("project.json"))
    }

    private func descriptor(
        kind: BridgeWallpaperKind = .webpage, entry: String = "index.html",
        scalingMode: BridgeScalingMode = .fill
    ) -> BridgeWallpaperPreview {
        .init(wallpaperId: "preview", title: "Preview", kind: kind, projectPath: project.path,
              entryFile: entry, assetsPath: root.appendingPathComponent("Assets").path,
              propertiesJson: "{}", fps: 30, scalingMode: scalingMode, scalingFactor: 1, volume: 0.5,
              engineOptions: kind == .webpage ? nil : BridgeSnapshotFixtures.engineOptionValues(),
              lutPath: nil, sceneQuality: .wallpaperEngineDefault)
    }

    /// A scene preview starts with the draft's Wallpaper Engine options and the saved quality.
    func testASceneRequestCarriesTheEngineOptionsAndTheSceneQuality() throws {
        var input = descriptor(kind: .projectScene, entry: "scene.json")
        input.engineOptions = BridgeSnapshotFixtures.engineOptionValues(
            colorEnabled: true, brightness: 60, imageFilter: "lutx32_amber", playbackRate: 150)
        input.sceneQuality = BridgeSceneQuality(
            msaa: .x4, shadows: .high, volumetrics: .off, reflections: false, postProcessing: .ultra)
        let request = try WallpaperPreviewRequest(input)
        XCTAssertEqual(request.engineOptions?.brightness, 60)
        XCTAssertEqual(request.engineOptions?.imageFilter, "lutx32_amber")
        XCTAssertEqual(request.engineOptions?.playbackRate, 150)
        XCTAssertEqual(request.sceneQuality,
                       SceneQualitySettings(msaa: 4, shadows: 3, volumetrics: 0, reflection: false, postProcessing: 4))
        XCTAssertNil(try WallpaperPreviewRequest(descriptor()).engineOptions, "a web page has none")
    }

    /// The preview and the lock screen hand the renderer its own number for every mode, Fit with
    /// blurred backdrop included.
    func testEveryScalingModeReachesTheRendererAsItsOwnNumber() throws {
        let expected: [(BridgeScalingMode, Int32)] = [
            (.none, 0), (.stretch, 1), (.match, 2), (.fill, 3), (.matchBlurred, 4),
        ]
        for (mode, number) in expected {
            XCTAssertEqual(mode.rendererValue, number, "\(mode)")
            XCTAssertEqual(try WallpaperPreviewRequest(descriptor(scalingMode: mode)).scalingMode, number)
        }
    }

    func testValidInstalledWebProjectPassesWithoutChangingItsFiles() async throws {
        let before = try Data(contentsOf: project.appendingPathComponent("project.json"))
        let request = try WallpaperPreviewRequest(descriptor())
        let validated = try await WallpaperPreviewLoader(libraryURL: library).validate(request)
        XCTAssertEqual(validated, request)
        XCTAssertEqual(try Data(contentsOf: project.appendingPathComponent("project.json")), before)
    }

    func testEntryTraversalAndSymlinkEscapeAreRejected() async throws {
        let outside = root.appendingPathComponent("outside.html")
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: project.appendingPathComponent("link.html"), withDestinationURL: outside)
        for entry in ["../../outside.html", "link.html", outside.path] {
            try writeProject(type: "web", entry: entry)
            let request = try WallpaperPreviewRequest(descriptor(entry: entry))
            do { _ = try await WallpaperPreviewLoader(libraryURL: library).validate(request); XCTFail("escaped the installed project") }
            catch {}
        }
    }

    func testChangedKindMissingEntryAndInvalidPropertiesDoNotLoad() async throws {
        let loader = WallpaperPreviewLoader(libraryURL: library)
        let request = try WallpaperPreviewRequest(descriptor())
        try writeProject(type: "video", entry: "index.html")
        do { _ = try await loader.validate(request); XCTFail("a stale manifest was accepted") } catch {}
        try writeProject(type: "web", entry: "missing.html")
        do { _ = try await loader.validate(WallpaperPreviewRequest(descriptor(entry: "missing.html"))); XCTFail("missing entry accepted") } catch {}
        try writeProject(type: "web", entry: "index.html")
        var invalid = request
        invalid.propertiesJSON = "not JSON"
        do { _ = try await loader.validate(invalid); XCTFail("invalid properties accepted") } catch {}
    }

    func testSceneNeedsSharedResourcesButVideoDoesNot() async throws {
        let loader = WallpaperPreviewLoader(libraryURL: library)
        try writeProject(type: "scene", entry: "scene.json")
        try Data("fixture package".utf8).write(to: project.appendingPathComponent("scene.pkg"))
        do { _ = try await loader.validate(WallpaperPreviewRequest(descriptor(kind: .projectScene, entry: "scene.json"))); XCTFail("missing shared resources accepted") } catch {}
        try writeProject(type: "video", entry: "clip.webm")
        try Data("fixture metadata only".utf8).write(to: project.appendingPathComponent("clip.webm"))
        _ = try await loader.validate(WallpaperPreviewRequest(descriptor(kind: .video, entry: "clip.webm")))
    }

    func testPreviewCopiesUnappliedTextAndScaleWithoutMutatingDesktopOrDrafts() async throws {
        let bridge = PreviewInputsBridge(noPointer: .init())
        var input = descriptor()
        input.propertiesJson = #"{"message":{"type":"textinput","value":"saved"}}"#
        bridge.preview = input
        bridge.options = BridgeSnapshotFixtures.options(wallpaperId: "preview", kind: .webpage, properties: [
            BridgePropertyDescriptor(id: "message", kind: .textInput, labelHtml: "Message",
                value: .string(value: "saved"), defaultValue: .string(value: "saved"), slider: nil,
                comboOptions: [], fileFilter: nil, directoryMode: nil, dirty: false,
                canRestoreDefaults: false, enabled: true, assetManaged: false, assetMissing: false, assetSourcePath: nil),
        ])
        let store = BridgeStore(bridge: bridge)
        store.appSnapshot = .init(playbackState: .playing, selectedWallpaperId: "other", activeWallpaperIds: ["other"], errors: [], heldWallpaperIds: [])
        let before = store.appSnapshot
        let field = WallpaperEditorState.FieldKey(wallpaperID: "preview", fieldID: "message")
        store.editorState.setPropertyText("local draft", key: field)
        store.editorState.setScalingText("1.75", key: .init(wallpaperID: "preview", fieldID: "primary"), locale: Locale(identifier: "en_US_POSIX"))
        let result = try await store.wallpaperPreviewRequestAsync(id: "preview", displayID: "primary", textOverrides: ["message": "current text"])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.propertiesJSON.utf8)) as? [String: [String: Any]])
        XCTAssertEqual(json["message"]?["value"] as? String, "current text")
        XCTAssertEqual(result.scalingFactor, 1.75)
        XCTAssertEqual(store.appSnapshot, before)
        XCTAssertTrue(store.history.entries.isEmpty)
        XCTAssertEqual(store.editorState.propertyTextDrafts[field], "local draft")
        XCTAssertTrue(store.editorState.hasPendingEdits(wallpaperID: "preview"))
        do { _ = try await store.wallpaperPreviewRequestAsync(id: "preview", displayID: "primary", textOverrides: ["unknown": "x"]); XCTFail("undeclared preview property accepted") } catch {}
    }

    func testPreviewAsksForTheValuesBeingDraggedUntilTheDragEnds() async throws {
        let bridge = PreviewInputsBridge(noPointer: .init())
        bridge.preview = descriptor()
        bridge.options = BridgeSnapshotFixtures.options(wallpaperId: "preview", kind: .webpage)
        let store = BridgeStore(bridge: bridge)
        let draft = WallpaperEditorState.FieldKey(wallpaperID: "preview", fieldID: "message")
        store.editorState.setPropertyText("local draft", key: draft)

        _ = try await store.wallpaperPreviewRequestAsync(id: "preview", displayID: "primary")
        await store.previewPropertyAsync(wallpaperId: "preview", propertyId: "size", value: .number(value: 3))
        await store.previewPropertyAsync(wallpaperId: "other", propertyId: "size", value: .number(value: 9))
        await store.previewPropertyAsync(wallpaperId: "preview", propertyId: "size", value: .number(value: 4))
        _ = try await store.wallpaperPreviewRequestAsync(id: "preview", displayID: "primary")
        store.editorState.discard(wallpaperID: "preview")
        _ = try await store.wallpaperPreviewRequestAsync(id: "preview", displayID: "primary")

        XCTAssertEqual(
            bridge.requested,
            [[], [.init(propertyId: "size", value: .number(value: 4))], []],
            "the newest step of this wallpaper alone, and none once a revert or an apply ended it")
        XCTAssertTrue(store.history.entries.isEmpty)
        XCTAssertEqual(store.editorState.propertyPreviews(wallpaperID: "other").count, 1, "another wallpaper's drag is its own")
    }

    func testPreviewAsksForTheWallpaperEngineOptionValuesBeingDraggedUntilTheEditEndsThem() async throws {
        let bridge = PreviewInputsBridge(noPointer: .init())
        bridge.preview = descriptor(kind: .projectScene, entry: "scene.json")
        bridge.options = BridgeSnapshotFixtures.options(wallpaperId: "preview", kind: .projectScene)
        let store = BridgeStore(bridge: bridge)

        await store.previewEngineOptionAsync(wallpaperId: "preview", option: .playbackRate, value: .number(value: 40))
        await store.previewEngineOptionAsync(wallpaperId: "other", option: .brightness, value: .number(value: 9))
        _ = try await store.wallpaperPreviewRequestAsync(id: "preview", displayID: "primary")
        store.editorState.discard(wallpaperID: "preview")
        _ = try await store.wallpaperPreviewRequestAsync(id: "preview", displayID: "primary")

        XCTAssertEqual(
            bridge.requestedEngineOptions,
            [[.init(option: .playbackRate, value: .number(value: 40))], []],
            "this wallpaper's step alone, and none once a revert or an apply ended it")
        XCTAssertEqual(store.editorState.engineOptionPreviews(wallpaperID: "other").count, 1)
    }

    func testPreviewNamesThePicturesAndFilesItCannotChangeInPlace() async throws {
        func property(_ id: String, _ kind: BridgePropertyKind) -> BridgePropertyDescriptor {
            BridgePropertyDescriptor(id: id, kind: kind, labelHtml: id, value: .string(value: ""), defaultValue: .string(value: ""),
                slider: nil, comboOptions: [], fileFilter: nil, directoryMode: nil, dirty: false,
                canRestoreDefaults: false, enabled: true, assetManaged: false, assetMissing: false, assetSourcePath: nil)
        }
        let bridge = PreviewInputsBridge(noPointer: .init())
        bridge.preview = descriptor()
        bridge.options = BridgeSnapshotFixtures.options(wallpaperId: "preview", kind: .webpage, properties: [
            property("picture", .texture), property("file", .file), property("folder", .directory),
            property("size", .slider), property("tint", .color), property("flag", .bool), property("mode", .combo),
            property("message", .textInput), property("heading", .group), property("label", .text),
        ])
        let store = BridgeStore(bridge: bridge)
        let request = try await store.wallpaperPreviewRequestAsync(id: "preview", displayID: "primary")
        XCTAssertEqual(request.frozenPropertyIDs, ["picture", "file", "folder"])
    }
}

private final class PreviewInputsBridge: WallpaperBridge {
    var preview: BridgeWallpaperPreview!
    var options: BridgeWallpaperOptionsSnapshot!
    /// The values being dragged that each request asked the bridge to show on top of the draft.
    var requested: [[BridgePropertyEdit]] = []
    /// The option values being dragged that each request asked the bridge to show.
    var requestedEngineOptions: [[BridgeEngineOptionEdit]] = []
    override func wallpaperPreview(wallpaperId: String, displayId: String, pending: [BridgePropertyEdit],
                                   pendingEngineOptions: [BridgeEngineOptionEdit]) async throws -> BridgeWallpaperPreview {
        requested.append(pending)
        requestedEngineOptions.append(pendingEngineOptions)
        return preview
    }
    override func wallpaperOptionsSnapshot(wallpaperId: String) async throws -> BridgeWallpaperOptionsSnapshot { options }
}
