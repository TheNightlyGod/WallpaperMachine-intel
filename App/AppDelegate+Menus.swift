import AppKit

/// The status item, the application menu and its Wallpaper menu, built from `StatusMenuModel`,
/// and the actions their items run. What a click on the status item opens is in
/// `AppDelegate+StatusPanel`.
extension AppDelegate: NSMenuDelegate, NSMenuItemValidation {
    func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item

        let button = item.button
        let trayIcon = NSImage(named: "TrayIcon")
        if let button {
            button.image = trayIcon
                ?? NSImage(systemSymbolName: "play.rectangle", accessibilityDescription: "WallpaperMachine")
            button.image?.isTemplate = true
        }

        AppLog.info("startup: statusItem installed: button=\(button != nil) trayIconAssetResolved=\(trayIcon != nil)")

        let menu = NSMenu()
        menu.delegate = self
        statusMenu = menu
        rebuildMenu(menu)
        // What a left click opens follows Settings › General at once.
        configureStatusItemClick()
        statusItemClickObserver = NotificationCenter.default.addObserver(
            forName: StatusItemClick.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.configureStatusItemClick() }
        }
    }

    /// An item created while Launch Services is still starting the app can stay out of the menu
    /// bar until the activation policy is set again and the menu rebuilt once the first run-loop
    /// turn has passed, so both happen then.
    func synchronizeStatusItem() {
        // On the next turn, not now: see above.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.statusItem != nil else { return }
                self.leaveDockUnlessAWindowIsOpen()
                self.rebuildMenu()
            }
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshStoreSnapshot()
        if menu === wallpaperMenu {
            rebuildWallpaperMenu(menu)
        } else {
            rebuildMenu(menu)
        }
    }

    func installApplicationMenu() {
        let main = NSMenu()

        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu(title: "WallpaperMachine")
        applicationMenu.addItem(menuItem("About WallpaperMachine", action: #selector(openAbout)))
        applicationMenu.addItem(.separator())
        let settings = menuItem("Settings…", action: #selector(openSettings))
        settings.keyEquivalent = ","
        applicationMenu.addItem(settings)
        applicationMenu.addItem(menuItem("Check for Updates…", action: #selector(checkForUpdates)))
        applicationMenu.addItem(.separator())
        let servicesItem = NSMenuItem(title: String(localized: "Services"), action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: String(localized: "Services"))
        servicesItem.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        applicationMenu.addItem(servicesItem)
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(NSMenuItem(title: String(localized: "Hide WallpaperMachine"),
                                           action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        let hideOthers = NSMenuItem(title: String(localized: "Hide Others"),
                                    action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        applicationMenu.addItem(hideOthers)
        applicationMenu.addItem(NSMenuItem(title: String(localized: "Show All"),
                                           action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: ""))
        applicationMenu.addItem(.separator())
        // Through the app's own exit handler, so the quit sequence runs.
        let quit = menuItem("Quit WallpaperMachine", action: #selector(exitApplication))
        quit.keyEquivalent = "q"
        applicationMenu.addItem(quit)
        applicationItem.submenu = applicationMenu
        main.addItem(applicationItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: String(localized: "File"))
        // The library's own two commands, for whoever looks for them in the menu bar or reaches
        // for the keys every Mac app gives them.
        let importItem = menuItem("Import…", action: #selector(importWallpapers))
        importItem.keyEquivalent = "o"
        fileMenu.addItem(importItem)
        let refresh = menuItem("Refresh Library", action: #selector(refreshLibrary))
        refresh.keyEquivalent = "r"
        fileMenu.addItem(refresh)
        fileMenu.addItem(.separator())
        let close = NSMenuItem(title: String(localized: "Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileMenu.addItem(close)
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        // Standard responder actions, so the search and setup fields get their shortcuts.
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: String(localized: "Edit"))
        editMenu.addItem(NSMenuItem(title: String(localized: "Undo"), action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: String(localized: "Redo"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: String(localized: "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: String(localized: "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: String(localized: "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: String(localized: "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = editMenu
        main.addItem(editItem)

        // The panel's tabs, Command-1 to Command-3 in tab order; Settings keeps Command-comma.
        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: String(localized: "View"))
        for (index, page) in PanelTabs.pages.enumerated() {
            let item = NSMenuItem(title: PanelTabs.name(of: page), action: #selector(showPage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = page.rawValue
            if page != .settings { item.keyEquivalent = String(index + 1) }
            viewMenu.addItem(item)
        }
        viewMenu.addItem(.separator())
        // The tile grids' size, as Finder and Photos zoom their icons.
        let zoomIn = menuItem("Zoom In", action: #selector(zoomTilesIn))
        zoomIn.keyEquivalent = "+"
        viewMenu.addItem(zoomIn)
        let zoomOut = menuItem("Zoom Out", action: #selector(zoomTilesOut))
        zoomOut.keyEquivalent = "-"
        viewMenu.addItem(zoomOut)
        let actualSize = menuItem("Actual Size", action: #selector(resetTileZoom))
        actualSize.keyEquivalent = "0"
        viewMenu.addItem(actualSize)
        viewMenu.addItem(.separator())
        // The window titles this item Enter or Exit Full Screen itself.
        let fullScreen = NSMenuItem(title: String(localized: "Enter Full Screen"),
                                    action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]
        viewMenu.addItem(fullScreen)
        viewItem.submenu = viewMenu
        main.addItem(viewItem)

        // What the status item offers, for whoever works in the panel and not the menu bar icon.
        let wallpaperItem = NSMenuItem()
        let wallpaperMenu = NSMenu(title: String(localized: "Wallpaper"))
        wallpaperMenu.delegate = self
        self.wallpaperMenu = wallpaperMenu
        rebuildWallpaperMenu(wallpaperMenu)
        wallpaperItem.submenu = wallpaperMenu
        main.addItem(wallpaperItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: String(localized: "Window"))
        windowMenu.addItem(NSMenuItem(title: String(localized: "Minimize"),
                                      action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(title: String(localized: "Zoom"),
                                      action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
        windowMenu.addItem(.separator())
        windowMenu.addItem(NSMenuItem(title: String(localized: "Bring All to Front"),
                                      action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: ""))
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        let helpItem = NSMenuItem()
        let helpMenu = NSMenu(title: String(localized: "Help"))
        helpMenu.addItem(menuItem("WallpaperMachine Guides", action: #selector(openGuides)))
        helpMenu.addItem(.separator())
        helpMenu.addItem(menuItem("WallpaperMachine on GitHub", action: #selector(openRepository)))
        helpMenu.addItem(menuItem("Release Notes", action: #selector(openReleaseNotes)))
        helpMenu.addItem(menuItem("Report an Issue…", action: #selector(openIssues)))
        helpMenu.addItem(.separator())
        helpMenu.addItem(menuItem("Join Discord", action: #selector(openDiscord)))
        helpItem.submenu = helpMenu
        main.addItem(helpItem)
        NSApp.helpMenu = helpMenu

        NSApp.mainMenu = main
    }

    /// The status item's playback and navigation commands, without its lines that open the panel.
    private func rebuildWallpaperMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let items = statusMenuItems(for: StatusMenuModel.wallpaperMenuEntries(for: statusMenuInput()))
        if items.isEmpty {
            menu.addItem(disabledMenuItem(String(localized: "No wallpaper is playing")))
        } else {
            items.forEach(menu.addItem)
        }
    }

    @objc private func zoomTilesIn() { controlPanelNavigation.tileZoomTarget?.zoomTiles(.zoomIn) }
    @objc private func zoomTilesOut() { controlPanelNavigation.tileZoomTarget?.zoomTiles(.zoomOut) }
    @objc private func resetTileZoom() { controlPanelNavigation.tileZoomTarget?.zoomTiles(.actualSize) }

    /// File › Import…: the library's file picker, on Installed. For an open panel, like the zoom
    /// commands: the picker is a sheet on its window.
    @objc private func importWallpapers() {
        guard let panel = controlPanelNavigation.tileZoomTarget else { return }
        showControlPanel(selection: .wallpaper)
        panel.library.chooseImportFiles()
    }

    /// File › Refresh Library: the Installed page's Refresh, which says what it found.
    @objc private func refreshLibrary() {
        controlPanelNavigation.tileZoomTarget?.library.refreshLibrary()
    }

    /// The website's guides, in Chinese for either Chinese and in English otherwise, the two
    /// languages they are written in.
    @objc private func openGuides() {
        ExternalLink.open(Self.guidesURL(languageTag: AppLanguageStore.shared.effective.tag))
    }

    nonisolated static func guidesURL(languageTag: String) -> URL {
        URL(string: languageTag.lowercased().hasPrefix("zh")
            ? "https://www.wallpapermachine.app/zh/guides/" : "https://www.wallpapermachine.app/guides/")!
    }

    func rebuildMenu(_ menu: NSMenu? = nil) {
        guard let menu = menu ?? statusMenu else { return }
        menu.removeAllItems()
        statusMenuItems(for: StatusMenuModel.entries(for: statusMenuInput())).forEach(menu.addItem)
        if let update = updates.menuItem() {
            menu.addItem(.separator())
            menu.addItem(update)
        }
        if let store, !store.heldWallpaperIDs.isEmpty {
            menu.addItem(.separator())
            menu.addItem(disabledMenuItem(String(localized: "A wallpaper was held back after a crash")))
        }
        if let error = startupError ?? lastError {
            menu.addItem(.separator())
            menu.addItem(disabledMenuItem(error.localizedDescription))
        }
        menu.addItem(.separator())
        if shutdownInProgress {
            menu.addItem(disabledMenuItem(String(localized: "Quitting…")))
        } else {
            menu.addItem(menuItem("Exit", action: #selector(exitApplication)))
        }
    }

    private func menuItem(_ title: String.LocalizationValue, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(
            title: String(localized: title),
            action: action,
            keyEquivalent: ""
        )
        item.target = self
        return item
    }

    private func disabledMenuItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// What the status menu's layout depends on. While the app starts or quits no display is
    /// offered, since a command on one could not run. The menu bar panel reads the same input
    /// without the downloads line, which it does not show.
    func statusMenuInput(includingDownloads: Bool = true) -> StatusMenuModel.Input {
        var displays: [StatusMenuModel.Display] = []
        if let store, !shutdownInProgress, !shutdownComplete {
            let screens = SystemDisplays.screens()
            let rows = StatusMenuModel.eligibleDisplays(store.settingsSnapshot.displays, connected: Set(screens.map(\.id)))
            let titles = DisplayTitleResolver.system.resolved()
            let candidates = rows.map { row -> StatusMenuModel.Candidate in
                let physicalID = ResolvedDisplayTitles.liveDisplayID(row.displayId, title: row.title)
                let frame = screens.first { $0.id == physicalID }?.frame
                return StatusMenuModel.Candidate(
                    id: row.displayId, title: titles.title(row.title, displayId: row.displayId),
                    physicalID: physicalID, minX: Double(frame?.minX ?? 0))
            }
            let wallpapers = Dictionary(store.librarySnapshot.wallpapers.filter(\.supported).map { ($0.id, $0.title) },
                                        uniquingKeysWith: { first, _ in first })
            let available = Set(wallpapers.keys)
            // The menu's Random Wallpaper draws from every wallpaper that can play and is not held
            // back, so it acts on a display when something other than what it shows is among them.
            let randomPool = AutomationCommand.RandomPool.all.candidates(
                library: Array(available), favorites: [], held: Set(store.heldWallpaperIDs))
            displays = StatusMenuModel.orderedDisplays(candidates, mainDisplay: screens.first?.id).map { candidate in
                let shown = store.shownWallpaperID(on: candidate.id)
                return StatusMenuModel.Display(
                    id: candidate.id, title: candidate.title, wallpaperID: shown,
                    canPrevious: store.previousWallpaperID(displayId: candidate.id) != nil,
                    canNext: canActivateNextWallpaper(store: store, displayId: candidate.id),
                    canRandom: randomPool.contains { $0 != shown },
                    recent: store.history.recent(on: candidate.id, available: available).map {
                        StatusMenuModel.Recent(id: $0, title: wallpapers[$0] ?? $0)
                    })
            }
        }
        // Not while the app starts or quits, when opening Discover would not be wanted.
        let downloads = includingDownloads && store != nil && !shutdownInProgress && !shutdownComplete
            ? StatusMenuModel.DownloadActivity.make(workshopStore.downloader.inProgressTransfers) : nil
        // The battery choice is the engine's, so it waits for the renderer like the displays.
        var battery: StatusMenuModel.Battery?
        if let store, !shutdownInProgress, !shutdownComplete {
            battery = .offered(
                hasBattery: BatteryReading.read() != nil, mode: store.settingsSnapshot.batteryMode,
                otherAppInFront: PlaybackPreferences.shared.otherAppInFrontAction)
        }
        return StatusMenuModel.Input(
            playbackIsCurrent: playbackSnapshotCurrent,
            hasActiveWallpapers: !(store?.appSnapshot.activeWallpaperIds.isEmpty ?? true),
            paused: store?.appSnapshot.playbackState == .paused,
            wallpapersMuted: PlaybackPreferences.shared.wallpapersMuted,
            downloads: downloads, battery: battery,
            displays: displays, canLockScreen: ScreenLock.isAvailable,
            // Read again for every build, so a change made in Terminal or elsewhere shows.
            desktopIconsHidden: shutdownInProgress || shutdownComplete ? nil : !FinderDesktopIcons().areShown)
    }

    private func statusMenuItems(for entries: [StatusMenuModel.Entry]) -> [NSMenuItem] {
        entries.map { entry -> NSMenuItem in
            switch entry {
            case .separator:
                return .separator()
            case .command(let command, let title, let checked):
                let item = NSMenuItem(title: title, action: #selector(statusMenuItemChosen(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = command
                item.state = checked ? .on : .off
                return item
            case .submenu(let title, let entries):
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                let submenu = NSMenu()
                statusMenuItems(for: entries).forEach(submenu.addItem)
                item.submenu = submenu
                return item
            }
        }
    }

    /// One action for every status menu item that runs a command: switching goes through the
    /// same path as a link or a shortcut key, so it shares the display's queue slot and shows
    /// a failure at the foot of the menu.
    @objc private func statusMenuItemChosen(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? StatusMenuModel.Command,
              statusMenuCommandCanRun(command) else { return }
        if let automation = command.automation {
            runAutomation(automation, alertsOnFailure: command == .playPause)
        } else {
            openStatusMenuDestination(command)
        }
    }

    /// Play/Pause is offered only with a current snapshot and wallpapers to play or pause, and
    /// Next only when the display has another wallpaper to go to; either can have changed since the
    /// menu or the menu bar panel showed it.
    func statusMenuCommandCanRun(_ command: StatusMenuModel.Command) -> Bool {
        switch command {
        case .playPause:
            guard let store, !shutdownInProgress, !shutdownComplete, playbackSnapshotCurrent else { return false }
            return !store.appSnapshot.activeWallpaperIds.isEmpty
        case .next(let display):
            guard let store, !shutdownInProgress, !shutdownComplete else { return false }
            return canActivateNextWallpaper(store: store, displayId: display)
        default:
            return true
        }
    }

    /// The items that open a window, lock the screen or change a battery choice rather than run an
    /// automation command.
    func openStatusMenuDestination(_ command: StatusMenuModel.Command) {
        switch command {
        case .openControlPanel:
            openControlPanel()
        case .openDownloads:
            showDiscover()
        case .batteryMode(let mode):
            chooseBatteryMode(mode)
        case .otherAppInFront(let action):
            // A preference, like Mute Wallpapers: the rule monitor hears the change itself. A
            // choice made here answers the one-time battery question.
            store?.supportPrompt?.recordBatteryAsked()
            PlaybackPreferences.shared.otherAppInFrontAction = action
            AppLog.info("when another app is in front: \(action.rawValue), from the menu bar")
        case .openInPanel(let display):
            // The panel's own target check, since the display may have changed since the menu opened.
            if let store, store.settingsSnapshot.displays.contains(where: {
                $0.displayId == display && $0.isIndependent
            }) {
                controlPanelNavigation.targetDisplayID = display
            }
            showControlPanel(selection: .wallpaper)
        case .toggleDesktopIcons:
            toggleDesktopIcons()
        case .lockScreen:
            lockScreen()
        case .playPause, .toggleMute, .previous, .next, .random, .apply, .remove, .startAgain:
            break
        }
    }

    @objc private func openControlPanel() {
        showControlPanel(selection: .wallpaper)
    }

    /// The menu bar's On Battery choice, through the same engine setter as Settings › Playback &
    /// Power, in its turn behind a running command. A failure shows at the foot of the menu. A
    /// choice made here answers the one-time battery question.
    private func chooseBatteryMode(_ mode: BridgeBatteryMode) {
        guard let store, !shutdownInProgress, !shutdownComplete else { return }
        store.supportPrompt?.recordBatteryAsked()
        Task {
            do {
                _ = try await store.commands.run { try await store.setBatteryModeAsync(mode) }
                store.onRenderingSettingAppliedElsewhere?()
                lastError = nil
                AppLog.info("on battery: \(mode), from the menu bar")
            } catch {
                lastError = error
                AppLog.warn("on battery \(mode) could not be set: \(error.localizedDescription)")
            }
            rebuildMenu()
        }
    }

    @objc private func showPage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let page = SidebarSelection(rawValue: raw) else { return }
        if page == .workshop { showDiscover() } else { showControlPanel(selection: page) }
    }

    @objc private func openAbout() {
        showAboutSettings()
    }

    @objc private func openRepository() {
        ExternalLink.open(ExternalLink.repository)
    }

    @objc private func openReleaseNotes() {
        ExternalLink.open(AppUpdateConfiguration.releasesURL)
    }

    @objc private func openIssues() {
        ExternalLink.open(ExternalLink.repositoryIssues)
    }

    /// MMFoundation's Discord, which also answers the panel's one-time Discord invitation.
    @objc private func openDiscord() {
        if ExternalLink.open(ExternalLink.discord) { store?.supportPrompt?.recordDiscordChosen() }
    }

    /// Ticks the View menu's page on show, and enables Zoom In, Zoom Out and Actual Size while a
    /// panel is open and has a step to go that way.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(showPage(_:)) {
            let shown = controlPanelWindow?.isVisible == true
                && controlPanelNavigation.selection?.rawValue == item.representedObject as? String
            item.state = shown ? .on : .off
        }
        let zoom: TileZoomCommand? =
            switch item.action {
            case #selector(zoomTilesIn)?: .zoomIn
            case #selector(zoomTilesOut)?: .zoomOut
            case #selector(resetTileZoom)?: .actualSize
            default: nil
            }
        if let zoom { return controlPanelNavigation.tileZoomTarget?.canZoomTiles(zoom) ?? false }
        // The library's commands need an open panel, and Refresh is not offered twice at once.
        if item.action == #selector(importWallpapers) { return controlPanelNavigation.tileZoomTarget != nil }
        if item.action == #selector(refreshLibrary) {
            guard let panel = controlPanelNavigation.tileZoomTarget else { return false }
            return !panel.isLibraryLoading && !panel.isBusy(PanelActionCoordinator.key("refresh"))
        }
        return true
    }

    @objc func openSettings() {
        showControlPanel(selection: .settings)
    }

    @objc func checkForUpdates() {
        // A check clears the release the open update window shows; that window is the answer.
        if updates.window != nil {
            updates.showWindow()
            return
        }
        showAboutSettings()
        updates.checkNow()
    }

    @objc private func lockScreen() {
        ScreenLock.lock()
    }

    /// Hide Desktop Icons: hides Finder's desktop icons, or shows them again. Finder restarts to
    /// apply it, so the menu asks first, as Settings does; Cancel changes nothing.
    private func toggleDesktopIcons() {
        guard !shutdownInProgress, !shutdownComplete else { return }
        let icons = FinderDesktopIcons()
        let hiding = icons.areShown
        // An accessory app's alert opens behind the active app unless it is brought forward.
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = hiding ? String(localized: "Hide desktop icons?") : String(localized: "Show desktop icons?")
        alert.informativeText = String(localized: "Finder restarts to apply this. Let any copy or move in Finder finish first.")
        alert.addButton(withTitle: String(localized: "Restart Finder"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try icons.setShown(!hiding)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @objc func exitApplication() {
        // The menu bar panel calls from a main-actor task. AppKit's terminateLater wait
        // cannot drain that queue from inside one of its jobs, so shutdown would never run.
        RunLoop.main.perform { [self] in
            MainActor.assumeIsolated {
                quitChosenFromMenu = true
                defer { quitChosenFromMenu = false }
                terminateApplication()
            }
        }
    }
}
