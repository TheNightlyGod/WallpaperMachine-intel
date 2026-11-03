import XCTest
@testable import WallpaperMachine

/// The settled posters kept for wallpapers that come back, and the look that decides whether one
/// may be given back. Only a temporary folder is touched.
@MainActor
final class DesktopSettledPosterStoreTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("settled-posters-" + UUID().uuidString)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    private func look(_ wallpaper: String, display: String = "1", revision: String = "0") -> DesktopPosterLook {
        DesktopPosterLook(display: display, wallpaperID: wallpaper, inputs: ["revision": revision])
    }

    private var files: [URL] {
        (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
    }

    func testOnlyTheSameLookGetsThePosterBackAndEachPairKeepsOneFile() {
        let store = DesktopSettledPosterStore(folder: folder)
        store.store(Data([1]), for: look("ocean"))
        store.store(Data([2]), for: look("ocean", display: "2"))
        store.store(Data([3]), for: look("../forest"))
        XCTAssertEqual(store.poster(for: look("ocean")), Data([1]))
        XCTAssertEqual(store.poster(for: look("ocean", display: "2")), Data([2]), "each display keeps its own")
        XCTAssertEqual(store.poster(for: look("../forest")), Data([3]), "any wallpaper id is a safe name on disk")
        XCTAssertNil(store.poster(for: look("ocean", revision: "1")), "a changed look is another picture")
        XCTAssertNil(store.poster(for: look("desert")))

        store.store(Data([4]), for: look("ocean", revision: "1"))
        XCTAssertEqual(store.poster(for: look("ocean", revision: "1")), Data([4]))
        XCTAssertNil(store.poster(for: look("ocean")), "the pair's newer settled poster replaced the older one")
        XCTAssertEqual(files.count, 3, "one file per display and wallpaper")
        XCTAssertEqual(store.reuses, 4)
    }

    func testTheLeastRecentlyUsedPosterGoesPastTheCapacity() {
        let store = DesktopSettledPosterStore(folder: folder, capacity: 2)
        store.store(Data([1]), for: look("a"))
        store.store(Data([2]), for: look("b"))
        XCTAssertNotNil(store.poster(for: look("a")))
        store.store(Data([3]), for: look("c"))
        XCTAssertNil(store.poster(for: look("b")), "b was used least recently")
        XCTAssertEqual(store.poster(for: look("a")), Data([1]))
        XCTAssertEqual(store.poster(for: look("c")), Data([3]))
        XCTAssertEqual(store.count, 2)
        XCTAssertEqual(files.count, 2, "its file is gone too")
    }

    func testAWallpaperThatLeftTheLibraryIsForgottenOnDisk() {
        let store = DesktopSettledPosterStore(folder: folder)
        store.store(Data([1]), for: look("a"))
        store.store(Data([2]), for: look("b", display: "2"))
        store.retain(wallpaperIDs: ["b"])
        XCTAssertNil(store.poster(for: look("a")))
        XCTAssertEqual(store.poster(for: look("b", display: "2")), Data([2]))
        XCTAssertEqual(files.count, 1)
    }

    /// A wallpaper's files or settings may have changed while the app was not running to notice,
    /// so nothing an earlier run kept is given back or left on disk.
    func testWhatAnEarlierRunKeptIsEmptied() {
        let earlier = DesktopSettledPosterStore(folder: folder)
        earlier.store(Data([1]), for: look("a"))
        XCTAssertEqual(files.count, 1)
        let store = DesktopSettledPosterStore(folder: folder)
        XCTAssertTrue(files.isEmpty)
        XCTAssertNil(store.poster(for: look("a")))
    }

    func testAPosterChangedOnDiskIsNotGivenBack() throws {
        let store = DesktopSettledPosterStore(folder: folder)
        store.store(Data([1, 2, 3]), for: look("a"))
        let file = try XCTUnwrap(files.first)
        try Data([9]).write(to: file)
        XCTAssertNil(store.poster(for: look("a")))
        XCTAssertEqual(store.count, 0)
    }

    // MARK: - The look

    private func settings(
        scaling: BridgeScalingMode = .fill, enabled: Bool = true, mode: BridgeDisplayMode = .standalone,
        fps: UInt32 = 30, renderScale: Float = 0.75, sceneResolution: String = "display",
        postProcessing: BridgePostProcessing = .enabled, metalFX: Bool = false,
        displayFraming: Bool = false,
        scene: (backend: String, failure: String?, wallpaper: String)? = ("native_metal", nil, "a")
    ) -> BridgeSettingsSnapshot {
        var quality = BridgeSceneQuality.wallpaperEngineDefault
        quality.postProcessing = postProcessing
        return BridgeSnapshotFixtures.settings(
            displays: [BridgeDisplaySettingsRow(
                displayId: "primary", title: "Built-in (1 - Primary)", enabled: enabled, mode: mode,
                mirrorTargets: [], selectedMirrorTarget: nil, scalingMode: scaling, scalingFactor: 1,
                targetFps: fps, maxFps: 120, muted: false, volume: 1)],
            metalfxUpscalingEnabled: metalFX, sceneDisplayFramingEnabled: displayFraming,
            sceneResolution: sceneResolution, sceneQuality: quality,
            sceneRenderers: scene.map {
                [BridgeSceneBackendReport(
                    displayId: 1, displayName: "Built-in", wallpaperId: $0.wallpaper, wallpaperTitle: "",
                    backend: $0.backend, failureStage: $0.failure, failureReason: $0.failure,
                    videoPath: "none", optimizationApplied: true, qualityInForce: nil)]
            } ?? [],
            renderScale: renderScale)
    }

    private func monitors(_ wallpaper: String = "a", mirror: String? = nil) -> [BridgeMonitorInfoRow] {
        [BridgeMonitorInfoRow(
            displayId: "primary", title: "Built-in (1 - Primary)", wallpaperId: wallpaper, wallpaperTitle: "",
            mirrorTargetDisplayId: mirror, mirrorTargetTitle: nil, scalingMode: "fill", targetFps: "30",
            audioResponse: false)]
    }

    private func resolve(
        wallpaper: String = "a", kind: BridgeWallpaperKind? = .projectScene,
        settings: BridgeSettingsSnapshot? = nil, monitors: [BridgeMonitorInfoRow]? = nil,
        hostPhase: HostWallpaperState.Phase? = nil,
        screen: DesktopPosterLayout.Screen? = .init(frame: CGRect(x: 0, y: 0, width: 1512, height: 982), scale: 2),
        contentRevision: UInt64 = 0, wallpaperSettings: Data? = Data("{}".utf8), extras: [String: String] = [:]
    ) -> DesktopPosterLook? {
        DesktopPosterLook.resolve(
            display: "1", wallpaperID: wallpaper, kind: kind, settings: settings ?? self.settings(),
            monitors: monitors ?? self.monitors(), hostPhase: hostPhase, screen: screen,
            contentRevision: contentRevision, wallpaperSettings: wallpaperSettings, extras: extras,
            physicalDisplay: { ResolvedDisplayTitles.liveDisplayID($0.displayId, title: $0.title).map(String.init) })
    }

    func testTheLookChangesWithEverythingThatChangesThePicture() throws {
        let base = try XCTUnwrap(resolve())
        XCTAssertEqual(resolve(settings: settings(fps: 60)), base, "a frame rate changes no picture")
        let changed: [(String, DesktopPosterLook?)] = [
            ("saved properties or framing", resolve(wallpaperSettings: Data(#"{"property_overrides":{"x":1}}"#.utf8))),
            ("no saved settings", resolve(wallpaperSettings: nil)),
            ("files", resolve(contentRevision: 1)),
            ("scaling", resolve(settings: settings(scaling: .match))),
            ("screen size", resolve(screen: .init(frame: CGRect(x: 0, y: 0, width: 2560, height: 1440), scale: 2))),
            ("screen scale", resolve(screen: .init(frame: CGRect(x: 0, y: 0, width: 1512, height: 982), scale: 1))),
            ("render scale", resolve(settings: settings(renderScale: 1))),
            ("2D scene resolution", resolve(settings: settings(sceneResolution: "canvas"))),
            ("post-processing", resolve(settings: settings(postProcessing: .ultra))),
            ("MetalFX", resolve(settings: settings(metalFX: true))),
            ("display framing", resolve(settings: settings(displayFraming: true))),
            ("appearance", resolve(extras: ["appearance": "dark"])),
        ]
        for (name, look) in changed {
            XCTAssertNotNil(look, name)
            XCTAssertNotEqual(look, base, name)
        }
    }

    /// Only a wallpaper the display shows on its own, and that is drawing, has a look: a scene
    /// still loading or held in a failure shows another picture.
    func testOnlyAWallpaperThatIsDrawingOnItsOwnDisplayHasALook() {
        XCTAssertNil(resolve(wallpaper: "b"), "the display shows another wallpaper")
        XCTAssertNil(resolve(monitors: monitors(mirror: "2")), "a mirror shows another display's picture")
        XCTAssertNil(resolve(settings: settings(enabled: false)))
        XCTAssertNil(resolve(settings: settings(mode: .mirror)))
        XCTAssertNil(resolve(screen: nil))
        XCTAssertNil(resolve(settings: settings(scene: ("unknown", nil, "a"))), "a scene still being read")
        XCTAssertNil(resolve(settings: settings(scene: ("unknown", "compile", "a"))), "a scene held in a failure")
        XCTAssertNil(resolve(settings: settings(scene: nil)))
        XCTAssertNil(resolve(settings: settings(scene: ("native_metal", nil, "b"))), "another scene draws")
        XCTAssertNil(resolve(kind: .webpage, hostPhase: .loading))
        XCTAssertNil(resolve(kind: .video, hostPhase: .failed))
        XCTAssertNil(resolve(kind: .video, hostPhase: nil))
        XCTAssertNil(resolve(kind: .unknown))
        XCTAssertNil(resolve(kind: nil))
        XCTAssertNotNil(resolve(kind: .webpage, hostPhase: .ready))
        XCTAssertNotNil(resolve(kind: .video, hostPhase: .ready))
    }
}
