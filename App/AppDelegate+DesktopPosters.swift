import AppKit

/// The macOS desktop picture: the poster sync and its one gate, the Settings switch that puts the
/// user's own picture back, and the posters, pins and kept wallpapers of displays that follow
/// desktop Spaces.
extension AppDelegate {
    /// What has the poster sync start or look at the desktops again.
    enum DesktopPosterTrigger {
        /// Every poster is taken again.
        case refresh
        /// An engine snapshot: every poster is taken again only when it changed what the displays show.
        case snapshot
        /// Wallpaper windows opened or closed: only those are looked at.
        case surfacesChanged
    }

    /// A sync that starts takes every poster. A running one does what `trigger` asks.
    func startDesktopWallpaperSync(_ trigger: DesktopPosterTrigger = .refresh) throws {
        guard !shutdownInProgress else { return }
        // Every start comes through here, so with the switch off no poster can be written.
        guard PlaybackPreferences.shared.writesDesktopPicture else { return }
        // A restore the switch started still owns the journal and the posters folder, and its
        // sync is suspended: a second sync would write posters the restore then overwrites.
        // The restore re-runs this through `applyDesktopPicturePreference` when it ends.
        guard restoringDesktopPicture == nil else { return }
        if let sync = desktopWallpaperSync, !sync.isSuspended {
            switch trigger {
            case .refresh: sync.refresh()
            case .snapshot: sync.snapshotApplied(desktopPosterLayout())
            case .surfacesChanged: sync.surfacesChanged()
            }
            return
        }
        let sync = try DesktopWallpaperSync(folder: ClientPaths.desktopPostersURL,
            scope: { [weak self] display in self?.desktopPosterScope(display) ?? .all },
            retainedDisplays: { [weak self] in self?.retainedSpacePosterDisplays() ?? [] },
            beforeDesktopChange: { [weak self] in self?.desktopSpaces?.refresh() },
            excludedWindows: { [weak self] in self?.keptWallpaperWindows() ?? [] })
        desktopWallpaperSync = sync
        sync.canCapture = { [weak self] surface in
            guard let policy = self?.presentationPolicy else { return true }
            return !policy.isSuspended
                && !(UInt32(surface.display).map(policy.suspendedDisplayIDs.contains) ?? false)
        }
        // Property edits shown on a display before Apply changes stay out of the picture macOS shows.
        sync.showsUnsavedLook = { [weak self] surface in
            self?.store?.isShowingPropertyEdits(onDisplay: surface.display) ?? false
        }
        // Desktops that follow Spaces but are not on screen show their own wallpaper's last poster.
        sync.desktopPosters = { [weak self] display in self?.savedDesktopPosters(display) ?? [:] }
        sync.onPosterAccepted = { [weak self] display, scope, poster in
            guard case .desktop = scope else { return }
            self?.keepSpacePoster(poster, display: display)
        }
        // A wallpaper that comes back with the same look gets its settled poster back.
        sync.settledPosters = makeSettledPosters()
        sync.posterLook = { [weak self] surface in self?.desktopPosterLook(surface) }
        sync.refreshesPeriodically = PlaybackPreferences.shared.refreshesDesktopPicturePeriodically
        sync.start()
        sync.snapshotApplied(desktopPosterLayout())
    }

    /// Makes the desktop picture follow Settings › General › Use the wallpaper as the macOS desktop
    /// picture. On, posters start if they are not running. Off, the user's own picture is put
    /// back with the same verified restore a quit uses, and the poster sync is dropped; a poster
    /// that a crash or an earlier run left behind is found in the journal and put back too.
    /// Idle while the animated lock screen has the desktop: the switch is locked then, and the
    /// native provider journals the poster as its own original.
    func applyDesktopPicturePreference() {
        // Poster writing is optional: prepared windows stay on their own desktops either way.
        defer { spacePinning?.update() }
        guard store != nil, !shutdownInProgress, !shutdownComplete, restoringDesktopPicture == nil,
              store?.lockScreenWallpaper?.claimsDesktopPicture != true else { return }
        if PlaybackPreferences.shared.writesDesktopPicture {
            desktopPictureRestoreSettled = false
            // Another preference changing must not take every poster again.
            if desktopWallpaperSync?.isSuspended == false { return }
            do { try startDesktopWallpaperSync() } catch {
                lastError = error
                AppLog.error("Desktop poster sync could not be started: \(error.localizedDescription)")
            }
            return
        }
        guard !desktopPictureRestoreSettled else { return }
        let folder = ClientPaths.desktopPostersURL
        let sync: DesktopWallpaperSync
        if let running = desktopWallpaperSync {
            sync = running
        } else if DesktopWallpaperLedger.hasRecordedOriginals(in: folder) {
            do { sync = try DesktopWallpaperSync(folder: folder) } catch {
                lastError = error
                AppLog.error("Desktop picture could not be restored: \(error.localizedDescription)")
                return
            }
        } else {
            return
        }
        AppLog.info("Desktop picture: writing is off; putting the macOS wallpaper back")
        // At once, not when the task starts: no frame may be written in between.
        sync.suspendForNativeProvider()
        restoringDesktopPicture = Task { @MainActor [weak self] in
            do {
                try await sync.restoreForTermination()
                guard let self else { return }
                self.desktopPictureRestoreSettled = true
                if self.desktopWallpaperSync === sync { self.desktopWallpaperSync = nil }
                AppLog.info("Desktop picture: the macOS wallpaper is back")
            } catch is CancellationError {
                // A quit began and restores the desktop itself.
            } catch {
                guard let self else { return }
                // Kept suspended, so quitting retries the restore.
                if self.desktopWallpaperSync == nil { self.desktopWallpaperSync = sync }
                self.desktopPictureRestoreSettled = true
                self.lastError = error
                AppLog.error("Desktop picture could not be put back: \(error.localizedDescription)")
                self.rebuildMenu()
            }
            // The switch may have been turned on again meanwhile; a restore that ran is not repeated here.
            self?.restoringDesktopPicture = nil
            self?.applyDesktopPicturePreference()
        }
    }

    private func desktopPosterScope(_ physicalDisplay: String) -> DesktopPosterScope {
        guard let store else { return .hold }
        guard let row = Self.settingsRow(onPhysicalDisplay: physicalDisplay, in: store) else {
            return WallpaperAutomationStore.shared.configurations.values.contains { $0.mode == .spaces } ? .hold : .all
        }
        guard row.isIndependent,
              WallpaperAutomationStore.shared.configuration(for: row.displayId).mode == .spaces else { return .all }
        guard store.lockScreenWallpaper?.isRequested != true, store.lockScreenWallpaper?.ownsDesktopProvider != true,
              store.activatingWallpaperID == nil, store.applyingWallpaperID == nil,
              automaticWallpapers?.scheduler.selectionIsSettled(on: row.displayId) == true,
              let visit = desktopSpaces?.visit(for: physicalDisplay) else { return .hold }
        let wallpaper = store.monitorInformationSnapshot.rows.first(where: { $0.displayId == row.displayId })?.wallpaperId ?? ""
        return .desktop(id: visit.spaceID, context: "\(visit.token):\(wallpaper):\(store.wallpaperContentRevision)")
    }

    /// The settings row of the display macOS numbers `physicalDisplay`.
    private static func settingsRow(onPhysicalDisplay physicalDisplay: String, in store: BridgeStore) -> BridgeDisplaySettingsRow? {
        store.settingsSnapshot.displays.first { physicalDisplayID(of: $0) == physicalDisplay }
    }

    /// The number macOS gives the display a settings row is for, as the poster sync names displays.
    nonisolated private static func physicalDisplayID(of row: BridgeDisplaySettingsRow) -> String? {
        ResolvedDisplayTitles.liveDisplayID(row.displayId, title: row.title).map(String.init)
    }

    /// Displays whose prepared wallpaper windows stay on their chosen desktops, with optional
    /// posters as the fallback while a wallpaper is not ready.
    func spacePins() -> [UInt32: WallpaperSpacePin] {
        guard let store, let spaces = desktopSpaces, spaces.available,
              let scheduler = automaticWallpapers?.scheduler,
              store.lockScreenWallpaper?.isRequested != true,
              store.lockScreenWallpaper?.ownsDesktopProvider != true else { return [:] }
        var pins: [UInt32: WallpaperSpacePin] = [:]
        for row in store.settingsSnapshot.displays where row.isIndependent {
            let configuration = WallpaperAutomationStore.shared.configuration(for: row.displayId)
            guard configuration.mode == .spaces,
                  let physical = ResolvedDisplayTitles.liveDisplayID(row.displayId, title: row.title),
                  let topology = spaces.displays[String(physical)] else { continue }
            var content = WallpaperSpacePin.Content.ready
            var incoming: String?
            if let target = scheduler.pendingTarget(on: row.displayId),
               !(target.kind == .wallpaper && target.id == store.shownWallpaperID(on: row.displayId)) {
                if target.kind == .wallpaper { incoming = target.id }
                // A wallpaper kept paused on the desktop runs on as it is: nothing loads there.
                if incoming == nil || !keptWallpapers(on: physical).contains(target.id) {
                    content = scheduler.isApplying(on: row.displayId) ? .loading : .waiting
                }
            }
            pins[physical] = .init(space: topology.currentManagedID, content: content,
                                   desktops: Self.spaceDesktops(configuration, topology: topology), incoming: incoming)
        }
        return pins
    }

    /// The desktops (the window server's numbers) each wallpaper of a display is chosen for; a
    /// desktop without a choice takes Desktop 1's, as it plays it. Playlists are left out.
    private static func spaceDesktops(_ configuration: DisplayWallpaperAutomation,
                                      topology: WallpaperDisplaySpaces) -> [String: Set<UInt64>] {
        let first = topology.spaces.first?.id
        var desktops: [String: Set<UInt64>] = [:]
        for desktop in topology.spaces {
            guard let space = desktop.managedID,
                  let target = configuration.desktopTarget(desktop.id, firstDesktop: first),
                  target.kind == .wallpaper else { continue }
            desktops[target.id, default: []].insert(space)
        }
        return desktops
    }

    /// The wallpapers each display that follows Spaces may keep paused for its other desktops:
    /// those its desktops are chosen for. None where windows cannot be kept on a desktop of their
    /// own.
    func spaceParkingPlan() -> WallpaperSpaceParking.Plan {
        guard spacePinning?.isActive == true else { return [:] }
        return spacePins().mapValues { Set($0.desktops.keys) }
    }

    func desktopWallpaperIsLoaded(display: UInt32, wallpaper: String) -> Bool {
        (store?.sceneWindows().contains { $0.displayId == display && $0.wallpaperId == wallpaper } ?? false)
            || (webWallpaperHost?.containsWallpaper(wallpaper, on: display) ?? false)
            || (nativeVideoHost?.containsWallpaper(wallpaper, on: display) ?? false)
    }

    /// No active assignment changes here. Only the bridge preparation takes the activation lane;
    /// the first-frame wait yields to manual choices, desktop switches and memory-pressure cleanup.
    func preloadDesktopWallpaper(display: UInt32, wallpaper: String) async throws {
        guard let store else { throw CancellationError() }
        do {
            try await prepareDesktopWallpaper(display: display, wallpaper: wallpaper, store: store)
            try await store.bridge.completeDesktopPreload(displayId: display, wallpaperId: wallpaper, succeeded: true)
        } catch {
            do { try await store.bridge.completeDesktopPreload(displayId: display, wallpaperId: wallpaper, succeeded: false) }
            catch { AppLog.warn("space preload: could not close the load journal entry: \(error.localizedDescription)") }
            throw error
        }
    }

    private func prepareDesktopWallpaper(display: UInt32, wallpaper: String, store: BridgeStore) async throws {
        let content = try await store.preloadDesktopWallpaperAsync(displayID: display, wallpaperID: wallpaper)
        try Task.checkCancellation()
        if let web = content.web { try await webWallpaperHost?.preload(web) }
        if let video = content.video { try await nativeVideoHost?.preload(video) }
        spacePinning?.update()
        let deadline = ContinuousClock.now + .seconds(90)
        while desktopWallpaperIsLoaded(display: display, wallpaper: wallpaper) {
            try Task.checkCancellation()
            let scene = store.sceneWindows().first { $0.displayId == display && $0.wallpaperId == wallpaper }
            // A concurrent switch owns its own first-frame wait once it promotes this instance.
            if scene?.parked == false || scene?.ready == true || webWallpaperHost?.wallpaperIsReady(wallpaper, on: display) == true
                || nativeVideoHost?.wallpaperIsReady(wallpaper, on: display) == true {
                spacePinning?.update()
                return
            }
            guard ContinuousClock.now < deadline else { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        webWallpaperHost?.discardUnreadyWallpaper(wallpaper, on: display)
        nativeVideoHost?.discardUnreadyWallpaper(wallpaper, on: display)
        throw DesktopPreloadError.noFrame
    }

    private enum DesktopPreloadError: Error { case noFrame }

    /// The windows of wallpapers kept paused for desktops the person is not on: the scene windows
    /// the renderer reports as parked and the web and video hosts' own.
    func keptWallpaperWindows() -> Set<Int> {
        var numbers = Set((store?.sceneWindows() ?? []).filter(\.parked).map { Int($0.windowNumber) })
        numbers.formUnion(webWallpaperHost?.keptWindowNumbers ?? [])
        numbers.formUnion(nativeVideoHost?.keptWindowNumbers ?? [])
        return numbers
    }

    /// The wallpapers a display keeps paused, by id.
    private func keptWallpapers(on display: UInt32) -> Set<String> {
        var ids = Set((store?.sceneWindows() ?? []).filter { $0.parked && $0.ready && $0.displayId == display }.map(\.wallpaperId))
        ids.formUnion(webWallpaperHost?.keptWallpapers(on: display) ?? [])
        ids.formUnion(nativeVideoHost?.keptWallpapers(on: display) ?? [])
        return ids
    }

    /// Whether this exact scene window, or its page or clip host, has a picture.
    func wallpaperWindowIsReady(number: Int, display: UInt32?, wallpaper: String?) -> Bool {
        if store?.sceneWindows().contains(where: { Int($0.windowNumber) == number && $0.ready }) == true { return true }
        guard let display, let wallpaper else { return false }
        return webWallpaperHost?.wallpaperIsReady(wallpaper, on: display) == true
            || nativeVideoHost?.wallpaperIsReady(wallpaper, on: display) == true
    }

    /// The wallpaper each wallpaper window shows, by window number.
    func wallpaperIDsByWindow() -> [Int: String] {
        var ids: [Int: String] = [:]
        for window in store?.sceneWindows() ?? [] { ids[Int(window.windowNumber)] = window.wallpaperId }
        ids.merge(webWallpaperHost?.windowWallpapers ?? [:]) { $1 }
        ids.merge(nativeVideoHost?.windowWallpapers ?? [:]) { $1 }
        return ids
    }

    /// Only repeated wallpapers need extra Space-local pictures. Parking owns the lifetime,
    /// including its memory-pressure and unload gates; system desktop-picture writing is separate.
    func spaceReplicaPlan(keeping: WallpaperSpaceParking.Plan) -> WallpaperSpaceReplicas.Plan {
        guard spacePinning?.isActive == true else { return [:] }
        var plan: WallpaperSpaceReplicas.Plan = [:]
        for (display, pin) in spacePins() {
            for (wallpaper, spaces) in pin.desktops where spaces.count > 1 && keeping[display]?.contains(wallpaper) == true {
                plan[.init(display: display, wallpaper: wallpaper)] = spaces
            }
        }
        return plan
    }

    func spaceReplicaSources() -> [WallpaperSpaceReplicas.Source] {
        let ids = wallpaperIDsByWindow()
        let kept = keptWallpaperWindows()
        let scenes = store?.sceneWindows() ?? []
        let pins = spacePins()
        return WallpaperPresentationPolicy.wallpaperWindows().compactMap { window in
            let number = window.windowNumber
            guard let wallpaper = ids[number],
                  let display = SystemPinnableWindow(window: window).displayID,
                  window.isVisible, let layer = window.contentView?.layer,
                  scenes.contains(where: { Int($0.windowNumber) == number && $0.ready })
                    || webWallpaperHost?.wallpaperIsReady(wallpaper, on: display) == true
                    || nativeVideoHost?.wallpaperIsReady(wallpaper, on: display) == true else { return nil }
            return .init(key: .init(display: display, wallpaper: wallpaper), window: number, layer: layer,
                         frame: window.frame, revision: store?.wallpaperContentRevision ?? 0,
                         parked: kept.contains(number), visit: pins[display]?.space)
        }
    }

    /// Whether a switch on `display` brings back a wallpaper kept paused on the desktop the person
    /// is on: its window is there already.
    func switchResumesKeptWallpaper(on display: UInt32) -> Bool {
        let kept = keptWallpaperWindows()
        guard !kept.isEmpty else { return false }
        return WallpaperPresentationPolicy.wallpaperWindows().contains { window in
            kept.contains(window.windowNumber) && window.isOnActiveSpace
                && window.screen.flatMap(SystemDesktopPictureWorkspace.id) == String(display)
        }
    }

    /// The Space-mode row of a physical display, with its choices.
    private func spaceModeDisplay(_ physicalDisplay: String) -> (row: String, configuration: DisplayWallpaperAutomation)? {
        guard let store, store.lockScreenWallpaper?.isRequested != true,
              store.lockScreenWallpaper?.ownsDesktopProvider != true,
              let row = Self.settingsRow(onPhysicalDisplay: physicalDisplay, in: store), row.isIndependent else { return nil }
        let configuration = WallpaperAutomationStore.shared.configuration(for: row.displayId)
        return configuration.mode == .spaces ? (row.displayId, configuration) : nil
    }

    /// The last poster of each desktop's wallpaper, by Space id; a desktop without a choice takes
    /// Desktop 1's, as it plays it. The current desktop's own poster comes from the wallpaper
    /// playing there once one is taken.
    private func savedDesktopPosters(_ physicalDisplay: String) -> [String: Data] {
        guard let (row, configuration) = spaceModeDisplay(physicalDisplay),
              let spaces = desktopSpaces, spaces.available,
              let topology = spaces.displays[physicalDisplay] else { return [:] }
        let first = topology.spaces.first?.id
        var posters: [String: Data] = [:]
        for desktop in topology.spaces {
            guard let target = configuration.desktopTarget(desktop.id, firstDesktop: first),
                  target.kind == .wallpaper else { continue }
            posters[desktop.id] = spacePosters.poster(display: row, wallpaperID: target.id)
        }
        return posters
    }

    /// Keeps a poster taken on a desktop when another desktop of the display is set to the same
    /// wallpaper, or that desktop is.
    private func keepSpacePoster(_ poster: Data, display physicalDisplay: String) {
        guard let store, let (row, configuration) = spaceModeDisplay(physicalDisplay),
              let wallpaper = store.monitorInformationSnapshot.rows.first(where: { $0.displayId == row })?.wallpaperId,
              !wallpaper.isEmpty,
              configuration.spaces.values.contains(where: { $0.kind == .wallpaper && $0.id == wallpaper }) else { return }
        spacePosters.store(poster, display: row, wallpaperID: wallpaper)
    }

    /// Lets go of the posters of wallpapers no desktop is set to any more. Keyed by the
    /// display's settings id, so a display that is unplugged keeps its own.
    func retainSpacePosters() {
        var keys = Set<DesktopSpacePosterCache.Key>()
        for (display, configuration) in WallpaperAutomationStore.shared.configurations where configuration.mode == .spaces {
            for target in configuration.spaces.values where target.kind == .wallpaper {
                keys.insert(.init(display: display, wallpaperID: target.id))
            }
        }
        guard keys != retainedSpacePosters else { return }
        retainedSpacePosters = keys
        spacePosters.retain(keys)
    }

    /// Tells the settle clock what each display shows and whether it presents: after every engine
    /// snapshot (a switch, a pause), every host pass (a page's or a clip's window opening) and
    /// every change of presentation, the moments any of it can change.
    func observeWallpaperSettling() {
        guard !shutdownInProgress else { return }
        let kept = keptWallpaperWindows()
        let ids = wallpaperIDsByWindow()
        let revision = store?.wallpaperContentRevision ?? 0
        let paused = store?.appSnapshot.playbackState == .paused
        let policy = presentationPolicy
        var displays: [UInt32: WallpaperSettleClock.Observation] = [:]
        for screen in NSScreen.screens {
            guard let display = SystemDesktopPictureWorkspace.id(screen).flatMap(UInt32.init),
                  let window = Self.wallpaperWindows(on: display, excluding: kept).first else { continue }
            let presenting = !paused && policy.map {
                !$0.isSuspended && !$0.suspendedDisplayIDs.contains(display)
            } ?? false
            displays[display] = .init(
                identity: .init(wallpaperID: ids[window.windowNumber] ?? "", window: window.windowNumber,
                                contentRevision: revision),
                presenting: presenting)
        }
        wallpaperSettling.observe(displays)
    }

    /// The front wallpaper window of `display` as the panel's picture of it asks it: its layer,
    /// how far it has played and its look.
    func previewSurface(on display: UInt32) -> DesktopWallpaperFrames.Surface? {
        observeWallpaperSettling()
        guard let window = Self.wallpaperWindows(on: display, excluding: keptWallpaperWindows()).first,
              let layer = window.contentView?.layer else { return nil }
        let surface = DesktopPosterSurface(layer: layer, display: String(display), window: window.windowNumber)
        return .init(layer: layer, isSettled: wallpaperSettling.isSettled(display),
                     remaining: wallpaperSettling.remaining(display), look: desktopPosterLook(surface))
    }

    /// What `surface`'s poster would show now, for giving a wallpaper's settled poster back
    /// (`DesktopPosterLook.resolve`). Nil when the window's wallpaper is unknown.
    private func desktopPosterLook(_ surface: DesktopPosterSurface) -> DesktopPosterLook? {
        guard let store, let window = surface.window, let wallpaper = wallpaperIDsByWindow()[window],
              !wallpaper.isEmpty, !wallpaper.contains("/"), !wallpaper.hasPrefix(".") else { return nil }
        let kind = store.librarySnapshot.wallpapers.first { $0.id == wallpaper }?.kind
        let host: HostWallpaperState.Kind? = kind == .webpage ? .web : kind == .video ? .nativeVideo : nil
        let hostPhase = host.flatMap { host in
            UInt32(surface.display).flatMap { store.hostWallpaperStates[HostWallpaperState.key(kind: host, displayID: $0)] }
                .flatMap { $0.wallpaperID == wallpaper ? $0.phase : nil }
        }
        var extras = [
            "appearance": NSApp.effectiveAppearance.name.rawValue,
            "labelLanguages": AppLanguageStore.shared.effective.labelLocales.joined(separator: ","),
        ]
        if kind == .webpage, let row = Self.settingsRow(onPhysicalDisplay: surface.display, in: store) {
            let placement = StillImagePlacementStore.shared
            extras["stillImage"] = String(describing: placement.placement(wallpaperID: wallpaper, displayID: row.displayId))
                + " " + (placement.generatedImage(wallpaperID: wallpaper)?.imageFile ?? "")
        }
        let screen = NSScreen.screens.first { SystemDesktopPictureWorkspace.id($0) == surface.display }
        let settingsFile = ClientPaths.wallpaperSettingsURL(wallpaperID: wallpaper)
        return DesktopPosterLook.resolve(
            display: surface.display, wallpaperID: wallpaper, kind: kind, settings: store.settingsSnapshot,
            monitors: store.monitorInformationSnapshot.rows, hostPhase: hostPhase,
            screen: screen.map { .init(frame: $0.frame, scale: $0.backingScaleFactor) },
            contentRevision: store.wallpaperContentRevision,
            wallpaperSettings: try? Data(contentsOf: settingsFile), extras: extras,
            physicalDisplay: { Self.physicalDisplayID(of: $0) })
    }

    /// Nil with `WALLPAPER_MACHINE_DESKTOP_POSTER_REUSE=0`, which takes every return again as
    /// before, for an A/B comparison ([power benchmark](docs/testing/power-benchmark.md)).
    private func makeSettledPosters() -> DesktopSettledPosterStore? {
        if let settledPosters { return settledPosters }
        guard ProcessInfo.processInfo.environment["WALLPAPER_MACHINE_DESKTOP_POSTER_REUSE"] != "0" else { return nil }
        let posters = DesktopSettledPosterStore()
        settledPosters = posters
        return posters
    }

    /// Lets go of the settled posters of wallpapers that left the library.
    func retainSettledPosters() {
        guard let store, let posters = settledPosters, store.libraryLoadState == .loaded else { return }
        let library = Set(store.librarySnapshot.wallpapers.map(\.id))
        guard library != settledPosterLibrary else { return }
        settledPosterLibrary = library
        posters.retain(wallpaperIDs: library)
    }

    /// What the current snapshot shows on the displays, as far as desktop posters are concerned.
    /// An animated wallpaper makes each poster a new image file, and macOS keeps a full-size copy
    /// of every one (docs/features/desktop-picture.md), so only a change here retakes them all.
    private func desktopPosterLayout() -> DesktopPosterLayout {
        DesktopPosterLayout(
            monitors: store?.monitorInformationSnapshot.rows ?? [], displays: store?.settingsSnapshot.displays ?? [],
            screens: NSScreen.screens.map { .init(frame: $0.frame, scale: $0.backingScaleFactor) },
            contentRevision: store?.wallpaperContentRevision ?? 0)
    }

    private func retainedSpacePosterDisplays() -> Set<String> {
        guard let store else { return [] }
        return Set(store.settingsSnapshot.displays.compactMap { row in
            guard row.isIndependent,
                  WallpaperAutomationStore.shared.configuration(for: row.displayId).mode == .spaces,
                  let physical = ResolvedDisplayTitles.liveDisplayID(row.displayId, title: row.title),
                  automaticWallpapers?.scheduler.inFlight.contains(row.displayId) == true
                    || store.monitorInformationSnapshot.rows.contains(where: { $0.displayId == row.displayId && !$0.wallpaperId.isEmpty }) else { return nil }
            return String(physical)
        })
    }

    /// A Space change reuses the installed picture; other automation inputs may change its look.
    func schedulePosterRefresh(after notification: Notification.Name) {
        schedulePosterRefresh(capture: notification == WallpaperSpaceMonitor.didChangeNotification ? .missingPoster : .all)
    }

    /// Apply callbacks run before BridgeStore releases its activation flag. Request scoped
    /// pixels on the next actor turn, after that flag and manual-choice bookkeeping settle.
    func schedulePosterRefresh(capture: DesktopWallpaperSync.CaptureRequest = .all) {
        guard !shutdownInProgress, !shutdownComplete else { return }
        pendingPosterCapture = max(pendingPosterCapture, capture)
        guard posterRefreshTask == nil else { return }
        posterRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let capture = pendingPosterCapture
            pendingPosterCapture = .none
            posterRefreshTask = nil
            guard !Task.isCancelled, !shutdownInProgress, !shutdownComplete else { return }
            desktopWallpaperSync?.refresh(capture: capture)
        }
    }
}
