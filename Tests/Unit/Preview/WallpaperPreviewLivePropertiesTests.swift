import AppKit
import XCTest
@testable import WallpaperMachine

@MainActor
final class WallpaperPreviewLivePropertiesTests: XCTestCase {
    private func settle() async { for _ in 0..<40 { await Task.yield() } }

    /// Lets the quiet period pass: ends the wait until the scheduler has none left, then lets the
    /// refresh it started finish.
    private func elapse(_ harness: Harness) async {
        for _ in 0..<8 {
            await settle()
            if harness.sleep.finishWaits() == 0 { break }
        }
        await settle()
    }

    private func make(kind: BridgeWallpaperKind = .projectScene, draft: String? = nil,
                      frozen: Set<String> = ["picture"]) -> Harness {
        let harness = Harness(kind: kind, draft: draft ?? Harness.scene(size: 10), frozen: frozen)
        addTeardownBlock { @MainActor in harness.session.close() }
        return harness
    }

    private func value(_ json: String, _ key: String) throws -> Any? {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])[key]
    }

    func testADraftChangeIsPushedOnceAfterTheDebounceAndBurstsCoalesceToTheLatest() async throws {
        let h = make()
        await h.show()
        let surface = try XCTUnwrap(h.surfaces.first)
        XCTAssertEqual(h.session.phase, .playing)
        for size in [20, 30, 40] {
            h.draft = Harness.scene(size: size)
            h.session.propertiesDidChange(wallpaperID: "a")
        }
        await settle()
        XCTAssertEqual(h.loads.count, 1, "nothing is read while the edits are still coming")
        XCTAssertTrue(surface.applied.isEmpty)
        h.draft = Harness.scene(size: 50)
        h.session.propertiesDidChange(wallpaperID: "a")
        await elapse(h)
        XCTAssertEqual(h.loads.count, 2, "the whole burst costs one read")
        XCTAssertEqual(surface.applied.count, 1)
        XCTAssertEqual(try value(try XCTUnwrap(surface.applied.first), "size") as? Int, 50)
        XCTAssertEqual(h.loads[1].textOverrides, [:])
    }

    func testADragIsFollowedWithoutTheQuietPeriodAndStepsDuringARefreshCostOneMore() async throws {
        let h = make()
        await h.show()
        let surface = try XCTUnwrap(h.surfaces.first)
        h.draft = Harness.scene(size: 20)
        h.session.propertiesDidChange(wallpaperID: "a", whileDragging: true)
        await settle()
        XCTAssertEqual(surface.applied.count, 1, "the step shows without waiting for the edits to pause")
        XCTAssertEqual(try value(try XCTUnwrap(surface.applied.last), "size") as? Int, 20)
        XCTAssertFalse(h.sleep.requested.contains(.milliseconds(150)), "a drag never stops, so there is no quiet to wait for")

        // Steps that arrive while the preview is still reading an earlier one.
        h.holdLoads = true
        h.draft = Harness.scene(size: 30)
        h.session.propertiesDidChange(wallpaperID: "a", whileDragging: true)
        await settle()
        let loading = h.loads.count
        for size in [40, 50, 60] {
            h.draft = Harness.scene(size: size)
            h.session.propertiesDidChange(wallpaperID: "a", whileDragging: true)
        }
        await settle()
        XCTAssertEqual(h.loads.count, loading, "one read at a time")
        h.holdLoads = false
        h.releaseLoads()
        await settle()
        XCTAssertEqual(h.loads.count, loading + 1, "the steps in between cost one more read")
        XCTAssertEqual(surface.applied.count, 2, "the read that was under way shows the newest, and the next finds nothing to add")
        XCTAssertEqual(try value(try XCTUnwrap(surface.applied.last), "size") as? Int, 60)
        XCTAssertFalse(h.sleep.requested.contains(.milliseconds(150)))
    }

    func testADragStepHiddenOrNotReadyWaitsForTheWindowLikeAnyEdit() async throws {
        let hidden = make()
        hidden.session.open(.init(wallpaperID: "a", displayID: "primary"))
        await settle()
        hidden.draft = Harness.scene(size: 20)
        hidden.session.propertiesDidChange(wallpaperID: "a", whileDragging: true)
        await settle()
        XCTAssertEqual(hidden.loads.count, 1, "a hidden preview does no work for a drag either")
        XCTAssertTrue(hidden.surfaces.isEmpty)
        hidden.session.setVisible(true)
        await elapse(hidden)
        XCTAssertEqual(try value(try XCTUnwrap(hidden.surfaces.first?.applied.last), "size") as? Int, 20)
    }

    func testAWallpaperEngineOptionChangeIsShownInPlaceOnceAndAnUnchangedOneIsNot() async throws {
        let h = make()
        await h.show()
        let surface = try XCTUnwrap(h.surfaces.first)
        h.session.propertiesDidChange(wallpaperID: "a")
        await elapse(h)
        XCTAssertTrue(surface.appliedEngineOptions.isEmpty, "the options equal what the preview started with")
        h.engineOptions = BridgeSnapshotFixtures.engineOptionValues(flipHorizontal: true, playbackRate: 150)
        h.session.propertiesDidChange(wallpaperID: "a")
        await elapse(h)
        XCTAssertEqual(surface.appliedEngineOptions.count, 1)
        XCTAssertEqual(surface.appliedEngineOptions.last?.flipHorizontal, true)
        XCTAssertEqual(surface.appliedEngineOptions.last?.playbackRate, 150)
        XCTAssertTrue(surface.applied.isEmpty, "the properties did not change")
        h.session.propertiesDidChange(wallpaperID: "a")
        await elapse(h)
        XCTAssertEqual(surface.appliedEngineOptions.count, 1, "options already shown are not sent again")
    }

    func testIdenticalOrFrozenOnlyChangesPushNothing() async throws {
        let h = make()
        await h.show()
        let surface = try XCTUnwrap(h.surfaces.first)
        h.session.propertiesDidChange(wallpaperID: "a")
        await elapse(h)
        XCTAssertEqual(h.loads.count, 2)
        XCTAssertTrue(surface.applied.isEmpty, "the draft equals what the preview started with")
        XCTAssertFalse(h.session.needsReload)
        h.draft = Harness.scene(size: 10, picture: "b.png")
        h.session.propertiesDidChange(wallpaperID: "a")
        await elapse(h)
        XCTAssertTrue(surface.applied.isEmpty, "a picture is not something the preview can take in place")
        XCTAssertTrue(h.session.needsReload)
    }

    func testAPictureOrFileChangeSetsNeedsReloadAndNeverReachesTheSurface() async throws {
        let h = make()
        var changes = 0
        h.session.onChange = { changes += 1 }
        await h.show()
        let surface = try XCTUnwrap(h.surfaces.first)
        h.draft = Harness.scene(size: 20, picture: "b.png")
        h.session.propertiesDidChange(wallpaperID: "a")
        let before = changes
        await elapse(h)
        XCTAssertGreaterThan(changes, before, "the window is told the note is due")
        XCTAssertTrue(h.session.needsReload)
        let pushed = try XCTUnwrap(surface.applied.first)
        XCTAssertEqual(try value(pushed, "size") as? Int, 20, "what can follow does")
        XCTAssertEqual(try value(pushed, "picture") as? String, "a.png", "the picture stays the one the preview loaded")

        // Changing it back clears the note, and the preview has nothing more to take in.
        h.draft = Harness.scene(size: 20, picture: "a.png")
        h.session.propertiesDidChange(wallpaperID: "a")
        await elapse(h)
        XCTAssertFalse(h.session.needsReload)
        XCTAssertEqual(surface.applied.count, 1)
    }

    func testAChangeWhileHiddenOrLoadingIsAppliedOnceWhenTheSurfaceIsVisibleAndReady() async throws {
        // Hidden: the request is read, but no surface exists and no work is done.
        let hidden = make()
        hidden.session.open(.init(wallpaperID: "a", displayID: "primary"))
        await settle()
        XCTAssertTrue(hidden.surfaces.isEmpty)
        hidden.draft = Harness.scene(size: 20)
        hidden.session.propertiesDidChange(wallpaperID: "a")
        hidden.draft = Harness.scene(size: 30)
        hidden.session.propertiesDidChange(wallpaperID: "a")
        await elapse(hidden)
        XCTAssertEqual(hidden.loads.count, 1, "a hidden preview does no work for the edits")
        hidden.session.setVisible(true)
        await elapse(hidden)
        XCTAssertEqual(hidden.loads.count, 2, "one read once it shows")
        let first = try XCTUnwrap(hidden.surfaces.first)
        XCTAssertEqual(first.applied.count, 1)
        XCTAssertEqual(try value(try XCTUnwrap(first.applied.first), "size") as? Int, 30)

        // Not ready: the surface exists but has not drawn its first frame.
        let loading = make()
        loading.readiness = false
        await loading.show()
        let surface = try XCTUnwrap(loading.surfaces.first)
        loading.draft = Harness.scene(size: 20)
        loading.session.propertiesDidChange(wallpaperID: "a")
        await elapse(loading)
        XCTAssertEqual(loading.loads.count, 1)
        surface.onReady?()
        await elapse(loading)
        XCTAssertEqual(loading.loads.count, 2)
        XCTAssertEqual(surface.applied.count, 1)

        // Hidden while the edits settle: the read waits for the window to show again.
        let shown = make()
        await shown.show()
        let live = try XCTUnwrap(shown.surfaces.first)
        shown.draft = Harness.scene(size: 20)
        shown.session.propertiesDidChange(wallpaperID: "a")
        shown.session.setVisible(false)
        await elapse(shown)
        XCTAssertEqual(shown.loads.count, 1)
        XCTAssertTrue(live.applied.isEmpty)
        shown.session.setVisible(true)
        await elapse(shown)
        XCTAssertEqual(shown.loads.count, 2)
        XCTAssertEqual(live.applied.count, 1)

        // Hidden after the read began: nothing is pushed to a hidden surface.
        shown.draft = Harness.scene(size: 30)
        shown.holdLoads = true
        shown.session.propertiesDidChange(wallpaperID: "a")
        await elapse(shown)
        shown.session.setVisible(false)
        shown.releaseLoads()
        await settle()
        XCTAssertEqual(live.applied.count, 1)
        shown.holdLoads = false
        shown.session.setVisible(true)
        await elapse(shown)
        XCTAssertEqual(live.applied.count, 2)
        XCTAssertEqual(try value(try XCTUnwrap(live.applied.last), "size") as? Int, 30)
    }

    func testAPausedPreviewStillTakesTheDraftSoItResumesCurrent() async throws {
        let h = make()
        await h.show()
        let surface = try XCTUnwrap(h.surfaces.first)
        h.session.togglePause()
        h.draft = Harness.scene(size: 20)
        h.session.propertiesDidChange(wallpaperID: "a")
        await elapse(h)
        XCTAssertEqual(surface.applied.count, 1)
        XCTAssertTrue(surface.paused)
    }

    func testOtherWallpapersAndAClosedOrReplacedSessionAreIgnoredAndLateRefreshesAreFenced() async throws {
        let h = make()
        await h.show()
        let old = try XCTUnwrap(h.surfaces.first)
        h.draft = Harness.scene(size: 20)
        h.session.propertiesDidChange(wallpaperID: "other")
        await elapse(h)
        XCTAssertEqual(h.loads.count, 1, "another wallpaper's edits are not this preview's")

        // A read still in flight when the preview is replaced must not reach the new one.
        h.holdLoads = true
        h.session.propertiesDidChange(wallpaperID: "a")
        await elapse(h)
        XCTAssertEqual(h.loads.count, 2)
        h.holdLoads = false
        h.session.open(.init(wallpaperID: "a", displayID: "primary"))
        h.releaseLoads()
        await settle()
        let replacement = try XCTUnwrap(h.surfaces.last)
        XCTAssertNotIdentical(old, replacement)
        XCTAssertTrue(old.applied.isEmpty)
        XCTAssertTrue(replacement.applied.isEmpty, "the replacement started from the draft that read already holds")

        // Closing drops what was waiting, and a closed preview ignores later edits.
        let loadsBeforeClose = h.loads.count
        h.session.propertiesDidChange(wallpaperID: "a")
        h.session.close()
        await elapse(h)
        h.session.propertiesDidChange(wallpaperID: "a")
        await elapse(h)
        XCTAssertEqual(h.loads.count, loadsBeforeClose)
    }

    func testAFailedPushIsLoggedAndTheSessionKeepsPlaying() async throws {
        let h = make()
        await h.show()
        let surface = try XCTUnwrap(h.surfaces.first)
        surface.failApply = true
        h.draft = Harness.scene(size: 20)
        h.session.propertiesDidChange(wallpaperID: "a")
        await elapse(h)
        XCTAssertEqual(h.warnings.count, 1)
        XCTAssertEqual(h.session.phase, .playing)
        XCTAssertEqual(surface.stops, 0)
        h.draft = Harness.scene(size: 30)
        h.session.propertiesDidChange(wallpaperID: "a")
        await elapse(h)
        XCTAssertEqual(h.warnings.count, 1, "the same problem is not logged for every edit")

        surface.failApply = false
        h.session.propertiesDidChange(wallpaperID: "a")
        await elapse(h)
        XCTAssertEqual(surface.applied.count, 1, "the next edit tries again and shows the newest draft")
        XCTAssertEqual(try value(try XCTUnwrap(surface.applied.first), "size") as? Int, 30)

        // A draft that cannot be read is logged too, and the preview plays on.
        h.loadFailure = WallpaperPreviewFailure(message: "no draft")
        h.session.propertiesDidChange(wallpaperID: "a")
        await elapse(h)
        XCTAssertEqual(h.warnings.count, 2)
        XCTAssertEqual(h.session.phase, .playing)
    }

    func testReloadStartsFromTheNewBaselineAndDropsOpenTimeTextOverrides() async throws {
        let h = make()
        h.session.open(.init(wallpaperID: "a", displayID: "primary", textOverrides: ["message": "Draft"]))
        h.session.setVisible(true)
        await settle()
        XCTAssertEqual(h.loads.map(\.textOverrides), [["message": "Draft"]])
        h.draft = Harness.scene(size: 10, picture: "b.png")
        h.session.propertiesDidChange(wallpaperID: "a")
        await elapse(h)
        XCTAssertEqual(h.loads.map(\.textOverrides), [["message": "Draft"], [:]], "a later edit must win over what was typed at open time")
        XCTAssertTrue(h.session.needsReload)

        h.session.reload()
        await settle()
        XCTAssertFalse(h.session.needsReload, "the new preview loaded the picture")
        XCTAssertEqual(h.surfaces.count, 2)
        let fresh = try XCTUnwrap(h.surfaces.last)
        h.draft = Harness.scene(size: 33, picture: "b.png")
        h.session.propertiesDidChange(wallpaperID: "a")
        await elapse(h)
        XCTAssertFalse(h.session.needsReload)
        let pushed = try XCTUnwrap(fresh.applied.first)
        XCTAssertEqual(try value(pushed, "size") as? Int, 33)
        XCTAssertEqual(try value(pushed, "picture") as? String, "b.png")
        XCTAssertEqual(h.surfaces[0].stops, 1, "the old preview was released by the reload")
        XCTAssertTrue(h.surfaces[0].applied.isEmpty)
    }

    func testAVideoPreviewHasNoPropertiesToFollow() async throws {
        let h = make(kind: .video, draft: "{}")
        await h.show()
        h.draft = Harness.scene(size: 20)
        h.session.propertiesDidChange(wallpaperID: "a")
        await elapse(h)
        XCTAssertEqual(h.loads.count, 1)
        XCTAssertTrue(try XCTUnwrap(h.surfaces.first).applied.isEmpty)
    }

    func testAWebPreviewKeepsItsFileEntriesAndFollowsTheRest() async throws {
        let started = #"{"choice":{"type":"combo","value":2},"pic":{"type":"file","value":"/old/a.png"}}"#
        let h = make(kind: .webpage, draft: started, frozen: ["pic"])
        await h.show()
        let surface = try XCTUnwrap(h.surfaces.first)
        h.draft = #"{"choice":{"type":"combo","value":3},"pic":{"type":"file","value":"/new/b.png"}}"#
        h.session.propertiesDidChange(wallpaperID: "a")
        await elapse(h)
        let pushed = try XCTUnwrap(surface.applied.first)
        XCTAssertEqual((try value(pushed, "choice") as? [String: Any])?["value"] as? Int, 3)
        XCTAssertEqual((try value(pushed, "pic") as? [String: Any])?["value"] as? String, "/old/a.png")
        XCTAssertTrue(h.session.needsReload)
    }

    func testASceneSurfaceWithoutARendererHasNothingToUpdateAndDoesNotFail() throws {
        let surface = SceneWallpaperPreviewSurface(request: try make().request())
        XCTAssertNoThrow(try surface.applyProperties(Harness.scene(size: 20)), "before the renderer starts")
        surface.stop()
        XCTAssertNoThrow(try surface.applyProperties(Harness.scene(size: 30)), "after the preview was released")
    }

    func testTheWindowShowsTheReloadNoteInPlaceOfTheStatusWhileAPictureIsPending() async throws {
        let h = make()
        let controller = WallpaperPreviewWindowController(session: h.session)
        let root = controller.makeContentView(size: CGSize(width: 480, height: 320))
        let status = try XCTUnwrap(root.subviews.compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "preview-status" })
        await h.show()
        XCTAssertEqual(status.stringValue, String(localized: "Playing preview"))
        h.draft = Harness.scene(size: 10, picture: "b.png")
        h.session.propertiesDidChange(wallpaperID: "a")
        await elapse(h)
        XCTAssertEqual(status.stringValue, String(localized: "Reload preview to show the picture or files you chose."))
        h.draft = Harness.scene(size: 10)
        h.session.propertiesDidChange(wallpaperID: "a")
        await elapse(h)
        XCTAssertEqual(status.stringValue, String(localized: "Playing preview"))
    }
}

@MainActor
private final class Harness {
    var draft: String
    /// The draft's Wallpaper Engine options, as the bridge exports them.
    var engineOptions: BridgeEngineOptionValues? = BridgeSnapshotFixtures.engineOptionValues()
    var frozen: Set<String>
    let kind: BridgeWallpaperKind
    var readiness = true
    var loads: [WallpaperPreviewSession.Selection] = []
    var surfaces: [RecordingSurface] = []
    var warnings: [String] = []
    var loadFailure: Error?
    var holdLoads = false
    let sleep = ManualSleeper()
    private var held: [CheckedContinuation<Void, Never>] = []
    private(set) var session: WallpaperPreviewSession!

    static func scene(size: Int, picture: String = "a.png") -> String {
        #"{"flag":true,"picture":"\#(picture)","size":\#(size)}"#
    }

    init(kind: BridgeWallpaperKind, draft: String, frozen: Set<String>) {
        self.kind = kind
        self.draft = draft
        self.frozen = frozen
        let sleep = self.sleep
        session = WallpaperPreviewSession(
            load: { [weak self] selection in
                guard let self else { throw CancellationError() }
                loads.append(selection)
                if holdLoads { await withCheckedContinuation { self.held.append($0) } }
                if let loadFailure { throw loadFailure }
                return try request()
            },
            makeSurface: { [weak self] _, _ in
                guard let self else { throw CancellationError() }
                let surface = RecordingSurface()
                surface.becomesReady = readiness
                surfaces.append(surface)
                return surface
            },
            refreshes: PropertyPreviewScheduler(delay: .milliseconds(150), sleep: { try await sleep.sleep($0) }),
            warn: { [weak self] in self?.warnings.append($0) })
    }

    func request() throws -> WallpaperPreviewRequest {
        var request = try WallpaperPreviewRequest(.init(wallpaperId: "a", title: "A", kind: kind,
            projectPath: "/fixture/a", entryFile: "scene.json", assetsPath: "/fixture/assets",
            propertiesJson: draft, fps: 30, scalingMode: .fill, scalingFactor: 1, volume: 0.5,
            engineOptions: engineOptions, lutPath: nil, sceneQuality: .wallpaperEngineDefault))
        request.frozenPropertyIDs = frozen
        return request
    }

    func show() async {
        session.open(.init(wallpaperID: "a", displayID: "primary"))
        session.setVisible(true)
        for _ in 0..<40 { await Task.yield() }
    }

    func releaseLoads() {
        let waiting = held
        held.removeAll()
        for continuation in waiting { continuation.resume() }
    }
}

@MainActor
private final class RecordingSurface: WallpaperPreviewSurface {
    let view = NSView()
    var onReady: (() -> Void)?
    var onFailure: ((String) -> Void)?
    var applied: [String] = []
    var failApply = false
    var becomesReady = true
    var paused = false
    var stops = 0
    func start() async throws { if becomesReady { onReady?() } }
    func setPaused(_ paused: Bool) throws { self.paused = paused }
    func setMuted(_ muted: Bool) throws {}
    func applyProperties(_ json: String) throws {
        if failApply { throw WallpaperPreviewFailure(message: "The renderer refused the properties") }
        applied.append(json)
    }
    var appliedEngineOptions: [WallpaperEngineOptions] = []
    func applyEngineOptions(_ options: WallpaperEngineOptions) throws { appliedEngineOptions.append(options) }
    func stop() { stops += 1 }
}
