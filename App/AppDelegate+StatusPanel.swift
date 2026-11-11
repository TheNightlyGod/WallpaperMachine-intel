import AppKit

/// What a click on the status item opens: the menu bar panel (`StatusPanelPopover`) or the menu,
/// as Settings › General says. A right click or a Control-click opens the menu either way, and so
/// does VoiceOver's Show Menu action, so every menu command stays reachable. The panel reads the
/// same input as the menu and runs its commands down the same paths (`StatusPanelSource`).
extension AppDelegate: StatusPanelSource {
    /// With the menu chosen, the item carries the menu itself, so it opens on the press as it always
    /// has. With the panel, the release of either button comes to `statusItemClicked`.
    func configureStatusItemClick() {
        guard let item = statusItem, let button = item.button else { return }
        switch StatusItemClick.current() {
        case .menu:
            statusPanel.close()
            item.menu = statusMenu
            button.setAccessibilityCustomActions(nil)
        case .panel:
            item.menu = nil
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            _ = button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityCustomActions([
                NSAccessibilityCustomAction(
                    name: String(localized: "Show Menu"), target: self,
                    selector: #selector(showStatusMenuForAccessibility)),
            ])
        }
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showStatusMenu()
        } else if statusPanel.toggle(from: sender) {
            // As opening the menu does: the panel then shows what the renderer reports now.
            refreshStoreSnapshot()
        }
    }

    /// Opens the menu under the icon, as a click on an item that carries it does, then gives the
    /// left click back to the panel. Tracking the menu has ended when `performClick` returns.
    func showStatusMenu() {
        guard let item = statusItem, let menu = statusMenu, let button = item.button else { return }
        statusPanel.close()
        item.menu = menu
        button.performClick(nil)
        if StatusItemClick.current() == .panel { item.menu = nil }
    }

    @objc private func showStatusMenuForAccessibility() -> Bool {
        showStatusMenu()
        return true
    }

    // MARK: StatusPanelSource

    func statusPanelInput() -> StatusPanelModel.Input {
        let menu = statusMenuInput(includingDownloads: false)
        guard let store, !shutdownInProgress, !shutdownComplete else {
            return StatusPanelModel.Input(menu: menu, library: [], update: AppUpdateNotice(store: updates.updater))
        }
        let held = Set(store.heldWallpaperIDs)
        let library = store.librarySnapshot.wallpapers.map { entry in
            StatusPanelModel.Wallpaper(
                id: entry.id, title: entry.title, kind: LibraryRow.Kind(entry.kind),
                previewFile: entry.previewPath.map { URL(fileURLWithPath: $0) },
                isPlayable: entry.supported && !held.contains(entry.id))
        }
        let switching = menu.displays.map(\.id).filter {
            store.commands.isActive(slot: BridgeStore.activationSlot(displayId: $0))
        }
        return StatusPanelModel.Input(
            menu: menu, library: library, favorites: PanelPreferences.favorites(),
            hold: statusPanelHold(store: store), switching: Set(switching),
            targetDisplayID: controlPanelNavigation.targetDisplayID,
            snapshotRevision: store.snapshotRevision, libraryRevision: store.libraryRefreshRevision,
            update: AppUpdateNotice(store: updates.updater))
    }

    func performStatusPanel(_ command: StatusPanelModel.Command) async throws {
        switch command {
        case .menu(let menuCommand):
            guard statusMenuCommandCanRun(menuCommand) else { return }
            if let automation = menuCommand.automation {
                try await performStatusPanelAutomation(automation)
            } else {
                openStatusMenuDestination(menuCommand)
            }
        case .unmuteAll:
            try await performStatusPanelAutomation(.unmute)
        case .toggleFavorite(let id):
            // Not a renderer command, so it does not wait behind one, as the panel's heart does not.
            try PanelPreferences.toggleFavorite(try statusPanelWallpaper(id, store: statusPanelStore()),
                                                in: ClientPreferences.defaults)
        case .setVolume(let id, let volume):
            // The inspector of an open control panel may show another wallpaper: it keeps its options.
            let store = try statusPanelStore()
            let value = try PanelValueRules.volume(volume)
            try await store.commands.run {
                try await store.setVolumeAsync(
                    wallpaperId: try self.statusPanelWallpaper(id, store: store), volume: value, keepingOpenOptions: true)
            }
        case .setMuted(let id, let muted):
            let store = try statusPanelStore()
            try await store.commands.run {
                try await store.setMutedAsync(
                    wallpaperId: try self.statusPanelWallpaper(id, store: store), muted: muted, keepingOpenOptions: true)
            }
        case .openSettings:
            openSettings()
        case .openUpdates:
            showAboutSettings()
        case .quit:
            exitApplication()
        }
    }

    func statusPanelVolume(of wallpaperID: String) async throws -> StatusPanelModel.Volume {
        let store = try statusPanelStore()
        let options = try await store.wallpaperOptionsSnapshotAsync(wallpaperId: wallpaperID)
        return StatusPanelModel.Volume(wallpaperID: wallpaperID, volume: Double(options.volume), muted: options.muted)
    }

    // MARK: Helpers

    /// As `runAutomation` runs a menu item's command, but awaited, so the panel can say what failed.
    /// A failure shows at the foot of the menu too.
    private func performStatusPanelAutomation(_ command: AutomationCommand) async throws {
        do {
            try await AppAutomation.shared.perform(command)
            lastError = nil
            rebuildMenu()
        } catch {
            lastError = error
            AppLog.warn("\(String(describing: command)) failed: \(error.localizedDescription)")
            rebuildMenu()
            throw error
        }
    }

    private func statusPanelStore() throws -> BridgeStore {
        guard let store, !shutdownInProgress, !shutdownComplete else { throw AutomationError.notReady }
        return store
    }

    private func statusPanelWallpaper(_ id: String, store: BridgeStore) throws -> String {
        guard store.librarySnapshot.wallpapers.contains(where: { $0.id == id }) else {
            throw WallpaperActionError(message: L("This wallpaper is no longer installed. Refresh your library."))
        }
        return id
    }

    /// What holds every wallpaper still besides the user's Pause (`StatusPanelModel.hold`). The
    /// drive's status is observable, so an open panel follows its going and coming back. Sleep and a
    /// locked session are not offered, since nobody sees the panel then.
    private func statusPanelHold(store: BridgeStore) -> StatusPanelModel.Hold? {
        let settings = store.settingsSnapshot
        return StatusPanelModel.hold(
            libraryDriveDisconnected: LibraryDriveStatus.shared.disconnectedRoot != nil,
            condition: SystemConditionState.shared.engaged.strongestRuleAction,
            onBatteryPauses: settings.onBatteryPower && settings.batteryMode == .pause,
            presentation: presentationPolicy.flatMap { $0.isUnattended ? nil : $0.globalPresentation })
    }
}
