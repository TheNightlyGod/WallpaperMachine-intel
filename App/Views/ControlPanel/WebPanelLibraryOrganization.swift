import Foundation

@MainActor
extension WebPanelController {
    func libraryOrganizationSnapshot() -> [String: Any] {
        [
            "collections": collections.collections.map {
                ["id": $0.id, "name": $0.name, "wallpaperIDs": $0.wallpaperIDs] as [String: Any]
            },
            "plans": playlists.plans.map {
                ["id": $0.id, "name": $0.name, "playlist": Self.organizationPlaylistSnapshot($0.playlist)] as [String: Any]
            },
        ]
    }

    static func organizationPlaylistSnapshot(_ playlist: DisplayPlaylist) -> [String: Any] {
        let null = NSNull()
        return [
            "mode": playlist.mode.rawValue, "source": playlist.source.rawValue,
            "order": playlist.order.rawValue, "trigger": playlist.trigger.rawValue, "interval": playlist.interval,
            "wallpaperIDs": playlist.wallpaperIDs,
            "collectionID": playlist.collectionID as Any? ?? null,
            "planID": playlist.planID as Any? ?? null,
            "dayWallpaperID": playlist.dayWallpaperID as Any? ?? null,
            "nightWallpaperID": playlist.nightWallpaperID as Any? ?? null,
            "dayStart": playlist.dayStart, "nightStart": playlist.nightStart,
        ]
    }

    /// Collection edits are local metadata. Plan application reaches only the scheduler,
    /// which retains pause state and waits for the display to present again.
    func performLibraryOrganization(_ action: String, request: WebPanelRequest) async throws -> Bool {
        switch action {
        case "collectionCreate":
            let ids = request.body["ids"] == nil ? [] : try organizationIDs(request, requireInstalled: true)
            try collections.create(name: request.string("name"), wallpaperIDs: ids)
        case "collectionRename":
            try collections.rename(request.string("collectionID"), name: request.string("name"))
        case "collectionDelete":
            let id = try request.string("collectionID")
            try collections.delete(id)
            playlists.forgetCollection(id)
        case "collectionAdd":
            try collections.add(organizationIDs(request, requireInstalled: true), to: request.string("collectionID"))
        case "collectionRemove":
            // Membership can be removed even when a wallpaper has already disappeared.
            try collections.remove(organizationIDs(request, requireInstalled: false), from: request.string("collectionID"))
        case "playlistPlanSave":
            try playlists.savePlan(from: playlistDisplay(request), name: request.string("name"))
        case "playlistPlanRename":
            try playlists.renamePlan(request.string("planID"), name: request.string("name"))
        case "playlistPlanDelete":
            let id = try request.string("planID")
            try playlists.deletePlan(id)
            try automations.forgetPlan(id)
        case "playlistPlanApply":
            let display = try playlistDisplay(request)
            let id = try request.string("planID")
            try await store.commands.run(slot: BridgeStore.activationSlot(displayId: display)) {
                _ = try playlistDisplay(request)
                try WallpaperAutomationController.applyPlaylist(id, to: display, playlists: playlists, collections: collections)
                automations.manualChoice?(display)
            }
        default:
            return false
        }
        return true
    }

    private func organizationIDs(_ request: WebPanelRequest, requireInstalled: Bool) throws -> [String] {
        guard let raw = request.body["ids"] as? [String], raw.count <= 4096,
            raw.allSatisfy({ !$0.isEmpty && $0.count <= 65_536 })
        else { throw WebPanelRequest.invalid }
        let installed = Set(store.librarySnapshot.wallpapers.map(\.id))
        if requireInstalled, !raw.allSatisfy(installed.contains) {
            throw WallpaperActionError(
                message: String(localized: "Some selected wallpapers are no longer installed. Refresh your library."))
        }
        var seen = Set<String>()
        return raw.filter { seen.insert($0).inserted }
    }
}
