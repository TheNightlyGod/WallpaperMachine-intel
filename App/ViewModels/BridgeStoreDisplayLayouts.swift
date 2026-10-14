import Foundation

@MainActor
extension BridgeStore {
    func displayTransferSnapshot() -> WallpaperDisplayTransfer.Snapshot {
        .init(displays: settingsSnapshot.displays.map { display in
            let assignment = monitorInformationSnapshot.rows.first { $0.displayId == display.displayId && $0.mirrorTargetDisplayId == nil }
            return .init(id: display.displayId, title: display.title.isEmpty ? display.displayId : display.title,
                         eligible: display.enabled && display.mode == .standalone,
                         wallpaperID: assignment.flatMap { $0.wallpaperId.isEmpty ? nil : $0.wallpaperId })
        }, wallpapers: Set(librarySnapshot.wallpapers.filter(\.supported).map(\.id)), reliable: !activationNeedsRefresh,
           held: Set(heldWallpaperIDs))
    }

    /// One wallpaper on every enabled independent display, or on none of them: a failure puts
    /// each display back as it was, and says so when one cannot be put back. A mirror follows
    /// its source, so it is left out.
    func activateWallpaperEverywhereAsync(id: String) async throws {
        try await applyDisplayTransferAsync(.everywhere(wallpaperID: id))
    }

    func applyDisplayTransferAsync(_ request: WallpaperDisplayTransfer.Request) async throws {
        // A layout is one user command. Later individual choices wait behind the whole
        // operation, including rollback; no screen receives half of a coalesced swap.
        // It has no slot of its own, so it counts as the user's choice for each display it
        // names as it is asked for, and work waiting on one of them (a Download and apply)
        // stands down.
        commands.noteUserChoice(in: request.displayIDs(in: displayTransferSnapshot()).map { Self.activationSlot(displayId: $0) })
        try await commands.run {
            let before = displayTransferSnapshot()
            var successful: [WallpaperDisplayAssignment] = []
            var touched = Set<String>()
            defer {
                let after = displayTransferSnapshot()
                if after.reliable {
                    for screen in after.displays where screen.eligible && (touched.contains(screen.id) || successful.contains { $0.displayID == screen.id }) {
                        let previous = before.displays.first { $0.id == screen.id }?.wallpaperID
                        if let current = screen.wallpaperID, current != previous {
                            history.recordSwitch(from: previous, to: current, on: screen.id)
                            onUserWallpaperChoice?(current, screen.id)
                            if !successful.isEmpty { supportPrompt?.recordSuccessfulActivation(wallpaperID: current) }
                        } else if successful.contains(where: { $0.displayID == screen.id }), let current = screen.wallpaperID {
                            onUserWallpaperChoice?(current, screen.id)
                        }
                    }
                }
            }
            successful = try await WallpaperDisplayTransfer.execute(request, snapshot: { self.displayTransferSnapshot() },
                prepare: { ids in
                    for id in ids.sorted() {
                        let options = try await self.wallpaperOptionsSnapshotAsync(wallpaperId: id)
                        guard !options.dirty, !self.editorState.hasPendingEdits(wallpaperID: id) else {
                            throw WallpaperDisplayLayoutError.pendingEdits
                        }
                    }
                }, apply: { id, display in
                    touched.insert(display)
                    try await self.activateWallpaperAsync(id: id, displayId: display, origin: .layout, recordsHistory: false,
                                                          releasesHold: request.releasesHold)
                }, clear: { id, display in
                    try await self.ejectWallpaperFromDisplayAsync(displayId: display, wallpaperId: id)
                })
        }
    }
}
