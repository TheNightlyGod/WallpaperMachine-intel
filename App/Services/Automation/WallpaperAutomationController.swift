import Foundation

/// Connects automatic selection to existing transactional wallpaper and playlist commands.
@MainActor
final class WallpaperAutomationController {
    let scheduler: WallpaperAutomationScheduler

    init(bridge: BridgeStore, rules: WallpaperAutomationStore, playlists: PlaylistStore, collections: WallpaperCollectionStore,
         focus: FocusFilterState, displays: @escaping @MainActor () -> [String],
         targetDisplay: @escaping @MainActor () -> String, canRun: @escaping @MainActor (String) -> Bool,
         playlistScheduler: PlaylistScheduler, spaceMonitor: WallpaperSpaceMonitor? = nil,
         onSettled: @escaping @MainActor () -> Void = {}) {
        scheduler = WallpaperAutomationScheduler(store: rules, focus: focus,
            displays: displays, targetDisplay: targetDisplay, canRun: canRun,
            capture: { display in
                .init(playlist: playlists.playlist(for: display), wallpaperID: bridge.shownWallpaperID(on: display))
            }, queue: { display, operation in
                try await bridge.commands.run(slot: BridgeStore.activationSlot(displayId: display), origin: .automation, operation)
            }, apply: { target, display in
                try await Self.apply(target, to: display, bridge: bridge, playlists: playlists, collections: collections)
            }, restore: { state, display, preserveWallpaper in
                if !preserveWallpaper {
                    if let id = state.wallpaperID, bridge.librarySnapshot.wallpapers.contains(where: { $0.id == id && $0.supported }) {
                        try await bridge.activateWallpaperAsync(id: id, displayId: display, origin: .automation)
                    } else if state.wallpaperID == nil,
                              let current = bridge.monitorInformationSnapshot.rows.first(where: { $0.displayId == display })?.wallpaperId,
                              !current.isEmpty {
                        try await bridge.ejectWallpaperFromDisplayAsync(displayId: display, wallpaperId: current)
                    }
                }
                var restored = state.playlist
                let installed = Set(bridge.librarySnapshot.wallpapers.filter(\.supported).map(\.id))
                restored.wallpaperIDs.removeAll { !installed.contains($0) }
                if let id = restored.dayWallpaperID, !installed.contains(id) { restored.dayWallpaperID = nil }
                if let id = restored.nightWallpaperID, !installed.contains(id) { restored.nightWallpaperID = nil }
                if let id = restored.planID, playlists.plan(id: id) == nil { restored.planID = nil }
                if restored.source == .collection, restored.collectionID.flatMap({ collections.collection(id: $0) }) == nil {
                    restored.source = .list
                    restored.collectionID = nil
                    restored.wallpaperIDs = []
                }
                playlists.restore(restored, on: display)
                playlistScheduler.holdCurrentPeriod(display)
            }, spaceMonitor: spaceMonitor, spaceVisit: { display in
                guard bridge.lockScreenWallpaper?.isRequested != true, bridge.lockScreenWallpaper?.ownsDesktopProvider != true,
                      let row = bridge.settingsSnapshot.displays.first(where: { $0.displayId == display }),
                      let physical = spaceMonitor?.physicalDisplay(display, title: row.title) else { return nil }
                return spaceMonitor?.visit(for: physical)
            })
        scheduler.onSettled = { [weak playlistScheduler] in playlistScheduler?.evaluate(); onSettled() }
        scheduler.onInputsChanged = onSettled
        rules.manualChoice = { [weak scheduler = self.scheduler] display in scheduler?.noteManualChoice(display) }
    }

    private static func apply(_ target: WallpaperAutomationTarget, to display: String,
                              bridge: BridgeStore, playlists: PlaylistStore, collections: WallpaperCollectionStore) async throws {
        try Task.checkCancellation()
        guard bridge.settingsSnapshot.displays.contains(where: { $0.displayId == display && $0.enabled && $0.mode == .standalone }) else {
            throw AutomationError(message: String(localized: "The automatic wallpaper target display is unavailable."))
        }
        switch target.kind {
        case .wallpaper:
            guard bridge.librarySnapshot.wallpapers.contains(where: { $0.id == target.id && $0.supported }) else {
                throw AutomationError(message: String(localized: "The wallpaper chosen by this rule is no longer available."))
            }
            try await bridge.activateWallpaperAsync(id: target.id, displayId: display, origin: .automation)
            playlists.update(display) { $0.mode = .off }
        case .playlist:
            try applyPlaylist(target.id, to: display, playlists: playlists, collections: collections)
        }
    }

    static func applyPlaylist(_ id: String, to display: String, playlists: PlaylistStore,
                              collections: WallpaperCollectionStore) throws {
        guard let plan = playlists.plan(id: id) else { throw LibraryOrganizationError.missingPlan }
        if plan.playlist.source == .collection,
           plan.playlist.collectionID.flatMap({ collections.collection(id: $0) }) == nil {
            throw LibraryOrganizationError.missingCollection
        }
        try playlists.applyPlan(id, to: display)
    }
}
