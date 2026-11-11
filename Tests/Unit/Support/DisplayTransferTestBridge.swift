import Foundation
@testable import WallpaperMachine

/// A two-display bridge that really updates assignment snapshots without any desktop windows.
@MainActor
final class DisplayTransferTestBridge: LayoutSnapshotBridge {
    var assignments = ["primary": "a", "secondary": "b"]
    var eligible = Set(["primary", "secondary"])
    var dirtyWallpapers = Set<String>()
    /// Wallpapers the app reports it is holding back after a crash.
    var held: [String] = []
    var failOnce: String?
    var failAfterMutation = false
    var beforeApply: (@MainActor () async -> Void)?
    /// The id CoreGraphics gives a display, worded into its title the way the renderer does
    /// (`primary (7 - Primary)`), for tests that reach a display by that id. Empty by default,
    /// which leaves the bare ids as titles.
    var physicalIDs: [String: UInt32] = [:]
    /// What the settings snapshot reports about each running scene.
    var sceneUpdateModes: [BridgeSceneUpdateModeReport] = []
    /// Displays that mirror another (`["secondary": "primary"]`). A mirror holds no assignment
    /// of its own: it shows the wallpaper of the display it mirrors, as the real bridge reports.
    var mirrors: [String: String] = [:]
    /// Every eject and apply that reached the bridge, in order (`eject primary a`, `apply primary a`).
    private(set) var events: [String] = []
    private var selected = "a"
    private var edits: [String: [String: Bool]] = [:]
    private(set) var applications: [(String, String)] = []
    /// Whether each apply that reached the bridge came from the user, in order.
    private(set) var applyRequests: [Bool] = []
    /// Every `(display, wallpaper)` the store asked to take off a display, in order.
    private(set) var ejections: [(String, String)] = []
    /// What an eject throws instead of taking the wallpaper off the display.
    var ejectFailure: Error?
    /// What reading a scene answers, and the scenes read, in order. Nil answers throw.
    var sceneCapabilityAnswer: BridgeSceneCapability?
    private(set) var sceneCapabilityReads: [String] = []
    /// Runs while a scene is being read, as the user may act during that wait.
    var whileReadingScene: (@MainActor () -> Void)?

    func installProjects(in library: URL) throws {
        for id in ["a", "b", "c"] {
            let folder = library.appendingPathComponent(id)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(#"{"type":"web","title":"Fixture","file":"index.html"}"#.utf8).write(to: folder.appendingPathComponent("project.json"))
            try Data("<!doctype html><title>Fixture</title>".utf8).write(to: folder.appendingPathComponent("index.html"))
        }
    }

    private func title(_ display: String) -> String {
        physicalIDs[display].map { "\(display) (\($0) - \(display == "primary" ? "Primary" : "Secondary"))" } ?? display
    }

    private func currentOptions(_ id: String) -> BridgeWallpaperOptionsSnapshot {
        BridgeSnapshotFixtures.options(wallpaperId: id, title: id, kind: .webpage,
            dirty: dirtyWallpapers.contains(id), displayConfigurations: ["primary", "secondary"].map { display in
                .init(displayId: display, title: title(display), enabled: edits[id]?[display] ?? (assignments[display] == id),
                      scalingMode: .fill, scalingFactor: 1, framing: .centered, targetFps: 30,
                      maxFps: 60, muted: true, volume: 0, dirty: false, canRestoreDefaults: false)
            })
    }
    var currentBundle: BridgeSnapshotBundle {
        .init(app: .init(playbackState: .paused, selectedWallpaperId: selected, activeWallpaperIds: Array(Set(assignments.values)), errors: [], heldWallpaperIds: held),
            library: .init(wallpapers: ["a", "b", "c"].map { id in
                .init(id: id, title: id == "a" ? "Ocean <img src=x>" : id, kind: .webpage, supported: true,
                      active: assignments.values.contains(id), selected: selected == id, previewPath: nil)
            }, scanStatus: .init(scanning: false, done: 3, total: 3), sceneCount: 0, videoCount: 0, webpageCount: 3, unknownCount: 0),
            wallpaperOptions: currentOptions(selected), monitorInformation: .init(rows: ["primary", "secondary"].map { display in
                let shown = mirrors[display].flatMap { assignments[$0] } ?? assignments[display] ?? ""
                return .init(displayId: display, title: title(display), wallpaperId: shown, wallpaperTitle: shown,
                      mirrorTargetDisplayId: mirrors[display], mirrorTargetTitle: mirrors[display].map(title),
                      scalingMode: "fill", targetFps: "30", audioResponse: false)
            }), settings: BridgeSnapshotFixtures.settings(displays: ["primary", "secondary"].map { display in
                .init(displayId: display, title: title(display), enabled: eligible.contains(display),
                      mode: mirrors[display] == nil ? .standalone : .mirror,
                      mirrorTargets: mirrors[display].map { [$0] } ?? [], selectedMirrorTarget: mirrors[display],
                      scalingMode: .fill, scalingFactor: 1, targetFps: 30, maxFps: 60, muted: true, volume: 0)
            }, sceneUpdateModes: sceneUpdateModes))
    }
    private var mutation: BridgeWallpaperMutationBundle {
        let bundle = currentBundle
        return .init(app: bundle.app, library: bundle.library, wallpaperOptions: bundle.wallpaperOptions!,
                     monitorInformation: bundle.monitorInformation, settings: bundle.settings)
    }
    override func selectWallpaper(id: String) async throws -> BridgeSnapshotBundle { selected = id; return currentBundle }
    override func allSnapshots() async throws -> BridgeSnapshotBundle { currentBundle }
    override func sceneCapability(wallpaperId: String) async throws -> BridgeSceneCapability {
        sceneCapabilityReads.append(wallpaperId)
        whileReadingScene?()
        guard let sceneCapabilityAnswer else { throw WallpaperActionError(message: "no scene probe in this test") }
        return sceneCapabilityAnswer
    }
    /// Set to make the next rescans of the library fail, as a folder that cannot be read does.
    var libraryRefreshFailure: Error?
    override func refreshLibrary() async throws -> BridgeSnapshotBundle {
        if let libraryRefreshFailure { throw libraryRefreshFailure }
        return currentBundle
    }
    override func wallpaperOptionsSnapshot(wallpaperId: String) async throws -> BridgeWallpaperOptionsSnapshot { currentOptions(wallpaperId) }
    override func setDisplayConfigEnabled(wallpaperId: String, displayId: String, enabled: Bool) async throws -> BridgeWallpaperMutationBundle {
        selected = wallpaperId
        edits[wallpaperId, default: [:]][displayId] = enabled
        return mutation
    }
    override func applyWallpaperOptions(wallpaperId: String, userInitiated: Bool) async throws -> BridgeWallpaperMutationBundle {
        if let beforeApply { await beforeApply() }
        applyRequests.append(userInitiated)
        // Like the engine: only the user applying a held wallpaper lifts its hold.
        if userInitiated { held.removeAll { $0 == wallpaperId } }
        let changes = edits[wallpaperId] ?? [:]
        let fail = changes.keys.contains { "\($0)=\(wallpaperId)" == failOnce }
        if fail { failOnce = nil }
        if fail && !failAfterMutation { throw CocoaError(.fileWriteUnknown) }
        for (display, enabled) in changes {
            if enabled { assignments[display] = wallpaperId }
            else if assignments[display] == wallpaperId { assignments[display] = nil }
            applications.append((display, wallpaperId))
            events.append("apply \(display) \(wallpaperId)")
        }
        edits[wallpaperId] = nil
        if fail { throw CocoaError(.fileWriteUnknown) }
        return mutation
    }
    override func ejectWallpaperFromDisplay(displayId: String, wallpaperId: String) async throws -> BridgeDisplayMutationBundle {
        if let ejectFailure { throw ejectFailure }
        events.append("eject \(displayId) \(wallpaperId)")
        ejections.append((displayId, wallpaperId))
        if assignments[displayId] == wallpaperId { assignments[displayId] = nil }
        let value = currentBundle
        return .init(app: value.app, library: value.library, monitorInformation: value.monitorInformation, settings: value.settings)
    }
}
