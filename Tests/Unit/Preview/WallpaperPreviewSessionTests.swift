import AppKit
import XCTest
@testable import WallpaperMachine

@MainActor
final class WallpaperPreviewSessionTests: XCTestCase {
    private func request(_ id: String) throws -> WallpaperPreviewRequest {
        try WallpaperPreviewRequest(.init(wallpaperId: id, title: id, kind: .webpage,
            projectPath: "/fixture/\(id)", entryFile: "index.html", assetsPath: "/fixture/assets",
            propertiesJson: "{}", fps: 30, scalingMode: .fill, scalingFactor: 1, volume: 0.5,
            engineOptions: BridgeSnapshotFixtures.engineOptionValues(), lutPath: nil,
            sceneQuality: .wallpaperEngineDefault))
    }

    private func settle() async { for _ in 0..<40 { await Task.yield() } }

    func testHiddenPreviewDefersRenderingAndUserPauseSurvivesVisibilityChanges() async throws {
        let request = try request("a")
        var surfaces: [PreviewFixtureSurface] = []
        let session = WallpaperPreviewSession(load: { _ in request }, makeSurface: { _, _ in
            let surface = PreviewFixtureSurface()
            surfaces.append(surface)
            return surface
        })
        session.open(.init(wallpaperID: "a", displayID: "primary"))
        await settle()
        XCTAssertTrue(surfaces.isEmpty)
        session.setVisible(true)
        await settle()
        let surface = try XCTUnwrap(surfaces.first)
        XCTAssertEqual(session.phase, .playing)
        XCTAssertTrue(surface.muted)
        session.togglePause()
        session.setVisible(false)
        session.setVisible(true)
        XCTAssertTrue(surface.paused)
        XCTAssertEqual(session.phase, .paused)
        session.togglePause()
        session.toggleMute()
        XCTAssertFalse(surface.paused)
        XCTAssertFalse(surface.muted)
        session.close()
        XCTAssertEqual(surface.stops, 1)
        XCTAssertNil(session.surface)
        XCTAssertEqual(session.phase, .closed)
    }

    func testSupersededLoadCannotCreateASurfaceOrReplaceTheLatestPreview() async throws {
        var pending: [String: CheckedContinuation<WallpaperPreviewRequest, Error>] = [:]
        var created: [String] = []
        let session = WallpaperPreviewSession(load: { selection in
            try await withCheckedThrowingContinuation { pending[selection.wallpaperID] = $0 }
        }, makeSurface: { request, _ in created.append(request.wallpaperID); return PreviewFixtureSurface() })
        session.setVisible(true)
        session.open(.init(wallpaperID: "old", displayID: "primary"))
        await settle()
        session.open(.init(wallpaperID: "new", displayID: "primary"))
        await settle()
        try XCTUnwrap(pending["new"]).resume(returning: request("new"))
        await settle()
        try XCTUnwrap(pending["old"]).resume(returning: request("old"))
        await settle()
        XCTAssertEqual(created, ["new"])
        XCTAssertEqual(session.title, "new")
        XCTAssertEqual(session.phase, .playing)
        session.close()
    }

    func testCloseDiscardsPendingPreparationAndLateSurfaceCallbacks() async throws {
        var pending: CheckedContinuation<WallpaperPreviewRequest, Error>?
        var made = 0
        let session = WallpaperPreviewSession(load: { _ in
            try await withCheckedThrowingContinuation { pending = $0 }
        }, makeSurface: { _, _ in made += 1; return PreviewFixtureSurface() })
        session.setVisible(true)
        session.open(.init(wallpaperID: "a", displayID: "primary"))
        await settle()
        session.close()
        try XCTUnwrap(pending).resume(returning: request("a"))
        await settle()
        XCTAssertEqual(made, 0)
        XCTAssertEqual(session.phase, .closed)

        let input = try request("b")
        let surface = PreviewFixtureSurface()
        let active = WallpaperPreviewSession(load: { _ in input }, makeSurface: { _, _ in surface })
        active.setVisible(true)
        active.open(.init(wallpaperID: "b", displayID: "primary"))
        await settle()
        let failure = surface.onFailure, ready = surface.onReady
        active.close()
        failure?("Late error")
        ready?()
        XCTAssertEqual(active.phase, .closed)
        XCTAssertEqual(surface.stops, 1)
    }

    func testFailureReleasesTheSurfaceAndReloadReadsFreshValuesMuted() async throws {
        let input = try request("a")
        var selections: [WallpaperPreviewSession.Selection] = []
        var surfaces: [PreviewFixtureSurface] = []
        let session = WallpaperPreviewSession(load: { selection in selections.append(selection); return input }, makeSurface: { _, _ in
            let surface = PreviewFixtureSurface(); surfaces.append(surface); return surface
        })
        session.setVisible(true)
        session.open(.init(wallpaperID: "a", displayID: "primary", textOverrides: ["message": "Draft"]))
        await settle()
        let first = try XCTUnwrap(surfaces.first)
        session.toggleMute()
        first.onFailure?("Fixture failed")
        XCTAssertEqual(session.phase, .failed("Fixture failed"))
        XCTAssertEqual(first.stops, 1)
        session.reload()
        await settle()
        XCTAssertEqual(selections.map(\.textOverrides), [["message": "Draft"], [:]])
        XCTAssertEqual(session.phase, .playing)
        XCTAssertTrue(try XCTUnwrap(surfaces.last).muted)
        session.close()
    }

    func testPreviewSizeFitsSmallAndPortraitDisplays() {
        for visible in [CGSize(width: 640, height: 480), CGSize(width: 800, height: 1280), CGSize(width: 3440, height: 1440)] {
            let size = WallpaperPreviewWindowController.contentSize(visibleSize: visible)
            XCTAssertLessThan(size.width, visible.width)
            XCTAssertLessThan(size.height, visible.height)
            XCTAssertGreaterThan(size.width, 0)
            XCTAssertGreaterThan(size.height, 0)
        }
    }

    func testScenePointerCoordinatesMatchTheRendererAndRejectEmptyViews() {
        let size = CGSize(width: 800, height: 400)
        XCTAssertEqual(SceneWallpaperPreviewSurface.RenderView.normalized(CGPoint(x: 200, y: 100), size: size), CGPoint(x: 0.25, y: 0.75))
        XCTAssertEqual(SceneWallpaperPreviewSurface.RenderView.normalized(CGPoint(x: -10, y: 900), size: size), CGPoint(x: 0, y: 0))
        XCTAssertNil(SceneWallpaperPreviewSurface.RenderView.normalized(.zero, size: .zero))
    }

    func testReadinessTimeoutStopsTheRenderer() async throws {
        let input = try request("a")
        var pending: CheckedContinuation<Void, Error>?
        let surface = PreviewFixtureSurface()
        surface.becomesReady = false
        let session = WallpaperPreviewSession(load: { _ in input }, makeSurface: { _, _ in surface }, sleep: { _ in
            try await withCheckedThrowingContinuation { continuation in
                Task { @MainActor in pending = continuation }
            }
        })
        session.setVisible(true)
        session.open(.init(wallpaperID: "a", displayID: "primary"))
        await settle()
        let deadline = try XCTUnwrap(pending)
        deadline.resume()
        await settle()
        guard case .failed = session.phase else { return XCTFail("an unready preview must time out") }
        XCTAssertEqual(surface.stops, 1)
        XCTAssertNil(session.surface)
        session.close()
    }
}

@MainActor
private final class PreviewFixtureSurface: WallpaperPreviewSurface {
    let view = NSView()
    var onReady: (() -> Void)?
    var onFailure: ((String) -> Void)?
    var paused = false
    var muted = false
    var stops = 0
    var becomesReady = true
    func start() async throws { if becomesReady { onReady?() } }
    func setPaused(_ paused: Bool) throws { self.paused = paused }
    func setMuted(_ muted: Bool) throws { self.muted = muted }
    func applyProperties(_ json: String) throws {}
    func applyEngineOptions(_ options: WallpaperEngineOptions) throws {}
    func stop() { stops += 1 }
}
