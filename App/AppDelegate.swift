import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var statusItem: NSStatusItem?
    /// The status item's menu, filled from `StatusMenuModel` each time it opens. A right click or a
    /// Control-click on the icon opens it, and a left click too when Settings › General says so.
    var statusMenu: NSMenu?
    /// The panel a left click on the status item opens (`AppDelegate+StatusPanel`).
    private(set) lazy var statusPanel = StatusPanelPopover(source: self)
    var statusItemClickObserver: NSObjectProtocol?
    /// The menu bar's Wallpaper menu, filled from `StatusMenuModel` each time it opens.
    var wallpaperMenu: NSMenu?
    private(set) var controlPanelWindow: NSWindow?
    private var previewWindow: WallpaperPreviewWindowController?
    let controlPanelNavigation = ControlPanelNavigation()
    private(set) lazy var workshopStore = WorkshopStore()
    private lazy var pixivStore = PixivStore()
    private lazy var libraryImports = LibraryImportStore()
    /// Files handed to the app before it finished launching, imported once it has.
    private var pendingOpenedFiles: [URL] = []
    private var finishedLaunching = false
    private(set) lazy var updates = AppUpdateCoordinator(
        updater: AppUpdateStore(),
        isShuttingDown: { [weak self] in
            guard let self else { return true }
            return self.shutdownInProgress || self.shutdownComplete
        },
        isUnattended: { [weak self] in self?.presentationPolicy?.isUnattended == true },
        menuChanged: { [weak self] in self?.rebuildMenu() },
        showAbout: { [weak self] in self?.showAboutSettings() },
        // The automatic update loop asks the Workshop too, since the app can run for weeks.
        beforeAutomaticCheck: { [weak self] in self?.checkWorkshopUpdatesIfDue() },
        windowClosed: { [weak self] in self?.leaveDockUnlessAWindowIsOpen() })
    private var displayChangeObserver: NSObjectProtocol?
    private var powerOffObserver: NSObjectProtocol?
    /// Follows the drive of a library kept on another disk: stops its wallpapers when it goes, plays
    /// them when it returns, and opens a library the app launched without.
    private var libraryDrive: StorageVolumeMonitor?
    /// Set when macOS announces a logout, restart or shutdown, ahead of the quit event.
    private var powerOffNotice = PowerOffNotice()
    private lazy var displayRefresh = DisplayRefreshCoalescer(displayReturned: { [weak self] in
        guard let self, !self.shutdownInProgress else { return }
        // A display that went missing for a moment and came back is not refreshed for, and a
        // snapshot applied meanwhile can have closed its window on the screens AppKit listed
        // then. The refresh that used to follow the return is what opened it again, so the
        // hosts that draw per display look again themselves.
        self.webWallpaperHost?.reconcile()
        self.nativeVideoHost?.reconcile()
    }) { [weak self] in
        guard let self else { return false }
        return await self.refreshDisplaysFromSystemEvent()
    }
    var desktopWallpaperSync: DesktopWallpaperSync?
    private var desktopMediaSession: DesktopMediaSession?
    private var sceneMediaSink: SceneMediaSink?
    private(set) var webWallpaperHost: WebWallpaperHost?
    private(set) var nativeVideoHost: NativeVideoWallpaperHost?
    private var wallpaperHosts: WallpaperHosts {
        WallpaperHosts(web: webWallpaperHost, native: nativeVideoHost)
    }
    private(set) var presentationPolicy: WallpaperPresentationPolicy?
    /// Keeps the previous picture on screen while a switched wallpaper loads.
    private var switchHold: WallpaperSwitchHold?
    private var windowAuditor: WallpaperWindowAuditor?
    /// Settings › Desktop & Lock Screen › Hide the notch.
    private var notchMask: NotchMaskController?
    /// Keeps the windows of a display that follows desktop Spaces on its current desktop only.
    private(set) var spacePinning: WallpaperSpacePinning?
    private var spaceParking: WallpaperSpaceParking?
    private(set) var spaceReplicas: WallpaperSpaceReplicas?
    /// The last poster of each wallpaper a desktop Space is set to, for the desktops not on screen.
    let spacePosters = DesktopSpacePosterCache()
    /// The settled poster each wallpaper last had on each display, given back when it returns.
    /// Made when the first poster sync starts (`makeSettledPosters`), which empties what an
    /// earlier run left.
    var settledPosters: DesktopSettledPosterStore?
    /// The library the settled posters were last trimmed to.
    var settledPosterLibrary: Set<String>?
    var retainedSpacePosters: Set<DesktopSpacePosterCache.Key>?
    private var wakeRevalidator: SystemWakeRevalidator?
    private var memoryPressureMonitor: MemoryPressureMonitor?
    private var appRuleMonitor: AppRuleMonitor?
    private var otherAudioMonitor: OtherAudioMonitor?
    private var systemConditionMonitor: SystemConditionMonitor?
    private var powerSourceMonitor: PowerSourceMonitor?
    /// The source `powerSourceChanged` last heard, so a change can tell what it left.
    private var reportedPowerSource: PowerSourceMonitor.Source?
    private var powerSourceRefresh: Task<Void, Never>?
    private var activeDisplayTracker: ActiveDisplayTracker?
    private var playlistScheduler: PlaylistScheduler?
    private(set) var automaticWallpapers: WallpaperAutomationController?
    private(set) var desktopSpaces: WallpaperSpaceMonitor?
    private var powerSourceResampler: PowerSourceResampler?
    var posterRefreshTask: Task<Void, Never>?
    var pendingPosterCapture = DesktopWallpaperSync.CaptureRequest.none
    /// Putting the user's own desktop picture back after the Settings switch went off, or after
    /// a poster was found left behind.
    var restoringDesktopPicture: Task<Void, Never>?
    /// A restore has run since a poster could last have been written, whether it worked or not.
    /// It is not tried again until the switch is turned on again or the lock screen hands the
    /// desktop back; a failed one is retried by quitting, which keeps its suspended sync.
    var desktopPictureRestoreSettled = false
    private var globalHotKeys: GlobalHotKeys?
    private var playbackPreferencesObserver: NSObjectProtocol?
    private var wallpaperEnergy: WallpaperEnergyRecorder?
    /// The scene reports last handed to `BridgeStore.sceneDrawVerdicts`.
    private var recordedSceneReports: [BridgeSceneBackendReport] = []
    private var telemetry: TelemetryService?
    private var activeCount: TelemetryActiveCount?
    /// Last presentation the bridge accepted, so leaving unloaded clears that flag first.
    private var appliedGlobalPresentation: GlobalPresentation = .running
    private(set) var store: BridgeStore?
    private(set) var startupError: Error?
    var lastError: Error?
    private(set) var playbackSnapshotCurrent = false
    private(set) var shutdownInProgress = false
    private(set) var shutdownComplete = false
    /// Teardown stages the quit gave up waiting for, so the exit fuse is shorter and the
    /// session ledger does not call the run a clean quit.
    private var stalledQuitStages: [String] = []
    /// How the quit that is running, or ran last, behaves. Chosen when it starts.
    private var quitMode = QuitMode.interactive
    /// A logout, restart or shutdown asked to quit while a user's quit was running. That quit
    /// must then not be refused, because the system would take the refusal as its own.
    private var powerOffJoinedQuit = false
    /// Turns SIGTERM and SIGHUP into a quit; started once launching has finished.
    private var terminationSignals: TerminationSignalRelay?
    /// The signal that asked for the quit being requested, until `applicationShouldTerminate`
    /// reads it. Cleared when a quit is refused, so a later Quit is not taken for the signal's.
    private var terminationSignal: Int32?
    /// Set while the app's own Quit or Exit runs `terminate`, so the quit line can say so.
    var quitChosenFromMenu = false
    let terminateApplication: @MainActor () -> Void
    private var themeSubscription: AnyCancellable?
    private var iconSubscription: AnyCancellable?
    private var diagnostics: RuntimeDiagnosticsSession?

    init(terminateApplication: @escaping @MainActor () -> Void = { NSApp.terminate(nil) }) {
        self.terminateApplication = terminateApplication
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hosted unit tests need these types but not the desktop lifecycle, so they get no
        // windows, no status item and no services. The UI tests run in a separate runner process,
        // which is why the real app starts there.
        if NSClassFromString("XCTestCase") != nil {
            NSApp.setActivationPolicy(.prohibited)
            return
        }
        let launchEvent = NSAppleEventManager.shared().currentAppleEvent
        themeSubscription = AppThemeStore.shared.$preferences
            .map(\.mode).removeDuplicates()
            .sink { mode in NSApp.appearance = mode.appearance }
        // A season's icon stands in for the chosen one while the season is on.
        iconSubscription = AppThemeStore.shared.$preferences
            .combineLatest(AppThemeStore.shared.$season)
            .map { preferences, season in season?.dockImageName ?? preferences.icon.imageName }
            .removeDuplicates()
            .sink { name in
                do {
                    NSApp.applicationIconImage = try AppThemePreferences.dockImage(named: name)
                } catch {
                    AppLog.error("Dock icon \(name) could not load: \(error.localizedDescription)")
                }
            }
        AppLog.info("startup: didFinishLaunching start")
        openLibrary()
        startShell()
        startLibraryServices()
        finishLaunching(launchEvent: launchEvent)
    }

    /// Opens the library and the renderer bridge over it: at launch, and again when the drive the
    /// app launched without is connected (`openLibraryAfterLaunch`). When either cannot start,
    /// `store` stays nil and `startupError` says why.
    private func openLibrary() {
        do {
            try ClientPaths.prepare()
            let created = try BridgeStore()
            store = created
            created.sceneDrawVerdicts = SceneDrawVerdicts(file: ClientPaths.sceneDrawVerdictsURL)
            created.openPreview = { [weak self] selection in self?.showWallpaperPreview(selection) }
            created.onPropertyDraftChanged = { [weak self] id in self?.previewWindow?.session.propertiesDidChange(wallpaperID: id) }
            created.onPropertyDragged = { [weak self] id in
                self?.previewWindow?.session.propertiesDidChange(wallpaperID: id, whileDragging: true)
            }
            created.showsPropertyEditsOnDesktop = { LivePropertyEditing.isEnabled() }
            // A display that showed an edit was not asked for its picture; once it draws the saved
            // look again, Mission Control gets the picture it missed.
            created.onPropertyEditsOnDesktopEnded = { [weak self] in self?.schedulePosterRefresh() }
            AppLog.attach(created.bridge)
            // Reloading waits for a wallpaper being applied, so a page that lands meanwhile
            // appears once that finishes rather than failing.
            pixivStore.downloads.onInstalled = { [weak created] id in
                created?.supportPrompt?.recordDownload(wallpaperID: id)
                try await created?.refreshLibraryAsync()
            }
            libraryImports.refreshLibrary = { [weak created] in try await created?.refreshLibraryAsync() }
            libraryImports.reloadReplaced = { [weak created] id in
                do {
                    try await created?.reloadWallpaperAsync(id: id)
                } catch {
                    AppLog.warn("import: \(id) was replaced but could not be reloaded: \(error.localizedDescription)")
                }
            }
            // Videos imported before imports made a preview show an empty tile until they have one.
            let library = ClientPaths.libraryURL
            Task(priority: .utility) { [weak created] in
                guard !(await WallpaperImportService().addMissingVideoPreviews(in: library)).isEmpty else { return }
                do { try await created?.refreshLibraryAsync() } catch {
                    AppLog.warn("library: rescan after adding video previews failed: \(error.localizedDescription)")
                }
            }
            for line in DiagnosticEnvironment.current() { AppLog.info("environment: \(line)") }
            startupError = nil
            playbackSnapshotCurrent = false
            AppLog.info("startup: BridgeStore created")
        } catch {
            AppLog.detachToStandardError()
            AppLog.error("startup: BridgeStore FAILED: \(error.localizedDescription)")
            startupError = error
            playbackSnapshotCurrent = false
        }
    }

    /// What a launch starts once, whether or not the library opened.
    private func startShell() {
        pixivStore.restoreSession()
        workshopStore.restoreSteamWebSession()
        // Follows the Mac for Automatic sunrise and sunset. It asks for nothing here: access is
        // requested only from an explicit action in the panel.
        SolarLocationTracker.shared.start()
        AppLog.info("startup: solar location tracker started")
        removeAbandonedStaging()
        // A moved library leaves its old copy to delete too.
        let support = ClientPaths.supportURL
        Task.detached(priority: .utility) { StorageMoveService.removeRetiredCopies(support: support) }

        NSApp.setActivationPolicy(.accessory)
        AppLog.info("startup: activation policy set to accessory")
        WebSignInWindowController.onClosed = { [weak self] in self?.leaveDockUnlessAWindowIsOpen() }
        installStatusItem()
        synchronizeStatusItem()
        installDisplayChangeObserver()
        AppLog.info("startup: display change observer installed")
        installPowerOffObserver()
        startLibraryDriveMonitor()
        installApplicationMenu()
        AppLog.info("startup: application menu installed")
        // Keeps no window and does no work until Hide the notch is turned on.
        let notchMask = NotchMaskController()
        self.notchMask = notchMask
        notchMask.start()
    }

    /// Starts every service that works over the opened library, then loads it: at launch, and
    /// once more if the library opens later (`openLibraryAfterLaunch`). Without a library it only
    /// says so.
    private func startLibraryServices() {
        if let store {
            workshopStore.startDownloadLifecycle(bridge: store)
            let lockScreen = LockScreenConfiguration.isSupportedBySystem
                ? LockScreenWallpaperService(
                    bridge: store.bridge, contentRevision: { [weak store] in store?.wallpaperContentRevision ?? 0 }) : nil
            if let lockScreen {
                store.lockScreenWallpaper = lockScreen
                lockScreen.beforeActivation = { [weak self] in
                    guard let self else { return }
                    if self.desktopWallpaperSync == nil {
                        self.desktopWallpaperSync = try DesktopWallpaperSync(folder: ClientPaths.desktopPostersURL)
                    }
                    self.desktopWallpaperSync?.suspendForNativeProvider()
                    self.spacePinning?.update()
                    self.spaceParking?.update()
                }
                lockScreen.afterDeactivation = { [weak self] in
                    guard let self, !self.shutdownInProgress else { return }
                    self.desktopWallpaperSync = nil
                    try self.startDesktopWallpaperSync()
                    // With the switch off, a poster the provider handed back is not kept.
                    self.desktopPictureRestoreSettled = false
                    self.applyDesktopPicturePreference()
                    self.spacePinning?.update()
                    self.spaceParking?.update()
                }
            }
            // Created before the hosts, which take over the picture it keeps on screen once their
            // window opens. Its policy is read when a switch starts, not now, so the policy that
            // is set up further down is still found.
            let hold = WallpaperSwitchHold(
                layers: { [weak self] in Self.wallpaperLayers(on: $0, excluding: self?.keptWallpaperWindows() ?? []) },
                // The rule the poster sync's captures follow: a suspended display is not seen,
                // and its surface may not answer a request for a frame.
                shouldHold: { [weak self] display in
                    guard let self, let policy = self.presentationPolicy else { return false }
                    // Bringing back a wallpaper kept paused on this desktop loads nothing, so
                    // there is no gap to cover and no picture worth taking.
                    return !policy.isSuspended && !policy.suspendedDisplayIDs.contains(display)
                        && !self.switchResumesKeptWallpaper(on: display)
                },
                reduceMotion: { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion },
                // A display hidden while its desktop's wallpaper loads shows no veil to fade.
                concealed: { [weak self] display in self?.spacePinning?.isConcealed(display) ?? false })
            switchHold = hold
            // A hidden display is shown again once its successor no longer needs the veil.
            hold.onReleased = { [weak self] _ in self?.spacePinning?.update() }
            hold.start()
            store.willSwitchWallpaper = { [weak self] displays in await self?.switchHold?.begin(displays: displays) }
            store.didSettleWallpaperSwitch = { [weak self] displays in self?.switchHold?.engineSettled(displays: displays) }
            store.didAbandonWallpaperSwitch = { [weak self] displays in self?.switchHold?.cancel(displays: displays) }

            let mediaScheduler = FoundationMediaTimerScheduler()
            let mediaSession = DesktopMediaSession(
                provider: FallbackSystemMediaProvider(
                    primary: AdapterSystemMediaProvider(scheduler: mediaScheduler),
                    fallback: AppleScriptMediaProvider(scheduler: mediaScheduler),
                    scheduler: mediaScheduler))
            desktopMediaSession = mediaSession
            let webHost = WebWallpaperHost(bridge: store.bridge, mediaRelay: mediaSession.relay,
                contentRevision: { [weak store] in store?.wallpaperContentRevision ?? 0 },
                switchHold: hold)
            webWallpaperHost = webHost
            webHost.onStateChanged = { [weak store] state in store?.receiveHostState(state) }
            webHost.onDeliveryStateChanged = { [weak store] in store?.webWallpaperDeliveryRevision &+= 1 }
            webHost.onAssetsChanged = { [weak store] in
                store?.wallpaperContentRevision &+= 1
                if store?.lockScreenWallpaper?.canRefreshAutomatically == true { store?.lockScreenWallpaper?.refresh() }
            }
            store.retryHostWallpaper = { [weak webHost] wallpaperID, displayID in
                webHost?.retry(wallpaperID: wallpaperID, displayID: displayID)
            }
            store.invalidateHostAsset = { [weak webHost] wallpaperID, propertyID in
                webHost?.invalidateAsset(wallpaperID: wallpaperID, propertyID: propertyID)
            }
            // Mission Control shows the desktop picture, so a wallpaper moved on a display needs
            // it retaken; the sync coalesces requests that arrive close together.
            store.onDisplayFramingChanged = { [weak self] _, _ in self?.schedulePosterRefresh() }
            store.sceneMediaAvailability = { [weak mediaSession] in
                mediaSession?.availability ?? .unavailable(reason: String(localized: "Media integration has not been started."))
            }
            sceneMediaSink = SceneMediaSink(
                session: mediaSession,
                submit: { json in
                    try await store.bridge.submitSystemMediaEvent(json: json)
                },
                applyArtwork: { width, height, rgba in
                    try await store.bridge.applySystemMediaArtwork(
                        width: width, height: height, rgba: rgba)
                },
                fetchHandles: {
                    await Self.sceneMediaHandles(store: store)
                },
                nextShortcut: {
                    try await store.bridge.nextUserShortcut()
                })
            // The panel distinguishes the user's setting from what is actually
            // being delivered, which only the host knows. The provider is
            // process-wide, so a scene wallpaper can populate it too.
            store.webWallpaperDeliveryStatus = { [weak webHost] in
                webHost?.deliveryStatus ?? WebWallpaperHost.DeliveryStatus()
            }
            webHost.onError = { [weak self] message in
                self?.lastError = WallpaperActionError(message: message)
                self?.rebuildMenu()
            }
            webHost.onSurfacesChanged = { [weak self, weak lockScreen] in
                guard let self, !self.shutdownInProgress else { return }
                self.presentationPolicy?.evaluate()
                self.windowAuditor?.windowsMayHaveChanged()
                self.spacePinning?.update()
                guard lockScreen?.ownsDesktopProvider != true else { return }
                do { try self.startDesktopWallpaperSync() } catch {
                    AppLog.error("Desktop poster sync could not be restarted: \(error.localizedDescription)")
                }
            }
            webHost.start()
            // Plays every plain video. The bridge returns nothing for a library
            // with no video wallpaper assigned, so this host opens no window and
            // starts no player then.
            let nativeVideo = NativeVideoWallpaperHost(bridge: store.bridge, switchHold: hold)
            nativeVideoHost = nativeVideo
            nativeVideo.onStateChanged = { [weak store] state in store?.receiveHostState(state) }
            nativeVideo.onError = { [weak self] message in
                self?.lastError = WallpaperActionError(message: message)
                self?.rebuildMenu()
            }
            nativeVideo.onSurfacesChanged = { [weak self, weak lockScreen] in
                guard let self, !self.shutdownInProgress else { return }
                self.presentationPolicy?.evaluate()
                self.windowAuditor?.windowsMayHaveChanged()
                self.spacePinning?.update()
                guard lockScreen?.claimsDesktopPicture != true else { return }
                // The host opens and closes its windows after the snapshot that asked for posters,
                // once it has read the clip: the window that opened is asked for one, and a display
                // left without a window gets its own picture back.
                do { try self.startDesktopWallpaperSync(.surfacesChanged) } catch {
                    AppLog.error("Desktop poster sync could not be restarted: \(error.localizedDescription)")
                }
            }
            nativeVideo.start()
            store.onSnapshotApplied = { [weak self, weak lockScreen, weak store] in
                guard let self, !self.shutdownInProgress else { return }
                if let store { self.recordSceneDrawVerdicts(store) }
                // Any engine change (playback, assignment, quality) ends the interval
                // being measured; its two ends could otherwise match across it.
                self.wallpaperEnergy?.invalidate()
                self.telemetry?.invalidateFrames()
                // Web wallpapers live in host windows; open or close them before
                // the poster sync and the presentation policy look at the desktop.
                self.webWallpaperHost?.reconcile()
                self.sceneMediaSink?.reconcile()
                self.nativeVideoHost?.reconcile()
                self.presentationPolicy?.evaluate()
                self.windowAuditor?.windowsMayHaveChanged()
                self.spacePinning?.update()
                self.spaceParking?.update()
                // Play, pause and a changed library or display set are when a waiting playlist
                // change can happen.
                self.automaticWallpapers?.scheduler.evaluate()
                self.playlistScheduler?.evaluate()
                if let lockScreen, lockScreen.canRefreshAutomatically {
                    lockScreen.refresh()
                }
                self.retainSettledPosters()
                // Posters keep the desktop unless the native provider has it or an animated lock
                // screen is on its way to taking it; a screen saver chosen on its own leaves it here.
                if lockScreen?.claimsDesktopPicture != true {
                    // A suspended poster sync must never outlive the native provider.
                    do { try self.startDesktopWallpaperSync(.snapshot) } catch {
                        self.lastError = error
                        AppLog.error("Desktop poster sync could not be restarted: \(error.localizedDescription)")
                    }
                }
            }
            let preferences = PlaybackPreferences.shared
            // Pause on battery reads the source the power source monitor last reported (the
            // system's own until that monitor exists); `powerSourceChanged` refreshes the rules.
            let appRules = AppRuleMonitor(preferences: preferences, onBattery: { [weak self] in
                (self?.powerSourceMonitor?.source ?? PowerSourceMonitor.systemSource()) == .battery
            })
            let otherAudio = OtherAudioMonitor(preferences: preferences)
            let conditions = SystemConditionMonitor(preferences: preferences, focus: .shared, state: .shared)
            let activeDisplay = ActiveDisplayTracker()
            appRuleMonitor = appRules
            otherAudioMonitor = otherAudio
            systemConditionMonitor = conditions
            activeDisplayTracker = activeDisplay
            appRules.onChange = { [weak self] in self?.presentationPolicy?.evaluate() }
            otherAudio.onChange = { [weak self] in self?.presentationPolicy?.evaluate() }
            conditions.onChange = { [weak self] in self?.presentationPolicy?.evaluate() }
            activeDisplay.onChange = { [weak self] in self?.presentationPolicy?.evaluate() }
            playbackPreferencesObserver = NotificationCenter.default.addObserver(
                forName: PlaybackPreferences.didChangeNotification, object: preferences, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.syncPlaybackMonitors()
                    self?.presentationPolicy?.evaluate()
                    self?.desktopWallpaperSync?.refreshesPeriodically = preferences.refreshesDesktopPicturePeriodically
                    self?.applyDesktopPicturePreference()
                }
            }
            // Seed the Space snapshot before presentation first evaluates, including a launch
            // from a full-screen Space. Later topology changes re-evaluate the policy themselves.
            let spaces = WallpaperSpaceMonitor.shared
            desktopSpaces = spaces
            spaces.start()
            let policy = WallpaperPresentationPolicy(
                displaySleepAction: { preferences.displaySleepAction },
                // Low Power Mode, a hot Mac and a Focus filter act exactly as app rules do, and so
                // does the library's drive going away, as a Stop.
                appRuleActions: { [weak self] in
                    appRules.actions.union(conditions.actions).union(self?.libraryDrive?.presentationActions ?? [])
                },
                otherAudioActive: { otherAudio.isActive },
                otherAudioAction: { preferences.otherAudioAction },
                // The user's own mute of every wallpaper, on top of the rules above and never
                // written into any wallpaper's saved sound settings.
                userMuted: { preferences.wallpapersMuted },
                desktopCoveredAction: { preferences.desktopCoveredAction },
                // "When another app is in front" learns from the probes' occlusion that the app in
                // front minimized or closed the window over the desktop.
                keepsCoverageProbes: { preferences.otherAppInFrontAction.watchesFrontmostApp },
                // A translucent wallpaper can play as soon as AppKit shows it in
                // the incoming desktop preview, before that Space becomes active.
                // Another display than the one the pointer is on, for those who chose to play only there.
                inactiveDisplays: { known in
                    preferences.playsOnlyOnActiveDisplay ? activeDisplay.inactive(among: known) : []
                },
                // Conditions that chose Reduced quality instead of a rule action.
                qualityReductions: { conditions.qualityReductions },
                applyGlobal: { [weak self] presentation, completion in
                    guard let self, let store = self.store,
                          !self.shutdownInProgress, !self.shutdownComplete else {
                        completion(.failure(CancellationError()))
                        return
                    }
                    let hostsSuspended = presentation != .running
                    // Unloading frees memory, which the wallpapers kept for other desktops hold too.
                    if presentation == .unloaded { self.spaceParking?.setUnloaded(true) }
                    self.webWallpaperHost?.setPresentationSuspended(hostsSuspended)
                    self.nativeVideoHost?.setPresentationSuspended(hostsSuspended)
                    let leavingUnloaded = self.appliedGlobalPresentation == .unloaded
                        && presentation != .unloaded
                    let resuming = presentation == .running && self.appliedGlobalPresentation != .running
                    self.wallpaperEnergy?.invalidate()
                    // Nothing is rated while presentation is not running, so its ticks would only
                    // wake an unattended Mac.
                    self.wallpaperEnergy?.setParked(hostsSuspended)
                    self.telemetry?.invalidateFrames()
                    Task {
                        // Whether the bridge took it or not: it folds presentation
                        // into each web and native video wallpaper's `paused`, and
                        // the call returns no snapshot to carry that. A page or a
                        // clip held still by a `paused` read while covered would
                        // otherwise stay stopped after the desktop is uncovered.
                        defer { self.wallpaperHosts.reconcile() }
                        do {
                            if leavingUnloaded {
                                try await store.setPresentationUnloadedAsync(false)
                            }
                            switch presentation {
                            case .running:
                                try await store.setPresentationSuspendedAsync(false)
                            case .suspended:
                                try await store.setPresentationSuspendedAsync(true)
                            case .unloaded:
                                try await store.setPresentationSuspendedAsync(true)
                                try await store.setPresentationUnloadedAsync(true)
                            }
                            self.appliedGlobalPresentation = presentation
                            if presentation != .unloaded { self.spaceParking?.setUnloaded(false) }
                            if resuming {
                                self.desktopWallpaperSync?.presentationResumed()
                                self.windowAuditor?.presentationResumed()
                            }
                            // A playlist change that fell due while presentation was suspended
                            // happens now that it runs again.
                            self.automaticWallpapers?.scheduler.evaluate()
                            self.playlistScheduler?.evaluate()
                            // Presentation suspend commits without producing a
                            // snapshot, so nothing else would recompute who is
                            // still consuming system media. Without this the
                            // adapter process and its timeline ticker keep
                            // running for scenes that stopped presenting, until
                            // some unrelated UI change happens to apply one.
                            self.sceneMediaSink?.reconcile()
                            // Wallpapers presenting again is the moment an update alert held
                            // back by sleep, a lock or an app rule may appear, and sleep or a
                            // lock is the moment an automatic update installs.
                            self.updates.installIfUnattended()
                            completion(.success(()))
                        } catch {
                            // An unload that did not happen frees nothing: the kept wallpapers
                            // follow what was applied, not what was asked for.
                            self.spaceParking?.setUnloaded(self.appliedGlobalPresentation == .unloaded)
                            AppLog.error("presentation suspend failed: \(error.localizedDescription)")
                            completion(.failure(error))
                        }
                    }
                },
                applyAudio: { [weak self] suppressed, completion in
                    guard let self, let store = self.store,
                          !self.shutdownInProgress, !self.shutdownComplete else {
                        completion(.failure(CancellationError()))
                        return
                    }
                    Task {
                        do {
                            try await store.setAudioSuppressedAsync(suppressed)
                            completion(.success(()))
                        } catch {
                            AppLog.error("audio suppress failed: \(error.localizedDescription)")
                            completion(.failure(error))
                        }
                    }
                },
                applyQuality: { [weak self] reductions, completion in
                    guard let self, let store = self.store,
                          !self.shutdownInProgress, !self.shutdownComplete else {
                        completion(.failure(CancellationError()))
                        return
                    }
                    // The snapshot this returns reaches the hosts, the lock-screen export and the
                    // energy recorder through `onSnapshotApplied`, as a frame-rate cap change does.
                    Task {
                        do {
                            try await store.setQualityThrottleAsync(reductions)
                            completion(.success(()))
                        } catch {
                            AppLog.error("quality throttle failed: \(error.localizedDescription)")
                            completion(.failure(error))
                        }
                    }
                },
                applyDisplay: { [weak self] displayID, suspended, completion in
                    guard let self, let store = self.store,
                          !self.shutdownInProgress, !self.shutdownComplete else {
                        completion(.failure(CancellationError()))
                        return
                    }
                    // A display paused only for the pointer being elsewhere is still on screen,
                    // so a web page there draws its first frame before it stops.
                    self.webWallpaperHost?.setPresentationSuspended(
                        suspended, forDisplay: displayID,
                        stillVisible: suspended && self.presentationPolicy?.isSuspendedInPlainSight(displayID: displayID) == true)
                    self.nativeVideoHost?.setPresentationSuspended(suspended, forDisplay: displayID)
                    self.wallpaperEnergy?.invalidate()
                    self.telemetry?.invalidateFrames()
                    Task {
                        // As on the global path: the display's own suspension is part
                        // of that display's `paused`, and nothing else reads it again.
                        defer { self.wallpaperHosts.reconcile() }
                        do {
                            try await store.setDisplayPresentationSuspendedAsync(
                                displayID: displayID, suspended: suspended)
                            if !suspended { self.desktopWallpaperSync?.presentationResumed() }
                            // As on the global path, a change that fell due while this
                            // display was covered happens now that it shows again.
                            self.automaticWallpapers?.scheduler.evaluate()
                            self.playlistScheduler?.evaluate()
                            // Same reason as the global path: a display going
                            // dark changes the effective consumer set and
                            // produces no snapshot of its own.
                            self.sceneMediaSink?.reconcile()
                            // Leaving a full-screen app shows the hidden display again.
                            completion(.success(()))
                        } catch {
                            AppLog.error("""
                                presentation suspend for display \(displayID) failed: \
                                \(error.localizedDescription)
                                """)
                            completion(.failure(error))
                        }
                    }
                })
            presentationPolicy = policy
            syncPlaybackMonitors()
            conditions.start()
            let power = PowerSourceMonitor()
            powerSourceMonitor = power
            reportedPowerSource = power.source
            power.onChange = { [weak self] source in self?.powerSourceChanged(source) }
            power.start()
            policy.start()
            // After the Space monitor, whose topology the auditor reads to tell a
            // full-screen Space from a wallpaper window that is missing.
            let auditor = WallpaperWindowAuditor(
                canExpectVisible: { [weak self] in self?.presentationPolicy?.globalPresentation == .running },
                isDesktopSpace: { WallpaperWindowAuditor.spaceIsDesktop(displayID: $0, in: .shared) },
                isConcealed: { [weak self] display in display.map { self?.spacePinning?.isConcealed($0) ?? false } ?? false },
                isAwayFromCurrentDesktop: { [weak self] in self?.spacePinning?.isAwayFromCurrentDesktop($0) ?? false })
            windowAuditor = auditor
            auditor.start()
            let revalidator = SystemWakeRevalidator(
                isPresenting: { [weak self] in self?.presentationPolicy?.globalPresentation == .running },
                // Behind a running Apply, in its turn and without polling.
                waitForIdle: { [weak store] in _ = await store?.commands.run {} },
                perform: { [weak self, weak store] reason in
                    guard let self, let store, !self.shutdownInProgress, !self.shutdownComplete else { return [] }
                    return try await store.revalidateScenePresentationAsync(reason: reason)
                })
            wakeRevalidator = revalidator
            revalidator.start()
            policy.onResumed = { [weak self] in
                guard let self, !self.shutdownInProgress else { return }
                self.wakeRevalidator?.presentationResumed()
            }
            // Rotations that wait for the Mac to be unlocked. The edge comes from the policy's
            // corrected lock state, so an unlock whose notification was lost still counts.
            policy.onSessionUnlocked = { [weak self] in
                guard let self, !self.shutdownInProgress else { return }
                self.playlistScheduler?.noteUnlock()
            }
            // Records the system's memory-pressure events beside the app's footprint;
            // it never unloads or pauses anything.
            let pressure = MemoryPressureMonitor(presentingScenes: { [weak store] in
                MemoryPressureMonitor.presentingSceneCount(store?.settingsSnapshot.sceneUpdateModes ?? [])
            }, report: { [weak self] report in
                if report.isWarning { AppLog.warn(report.message) } else { AppLog.info(report.message) }
                self?.telemetry?.recordPressure(report)
            })
            // The wallpapers kept paused for other desktops are let go while pressure lasts.
            pressure.onPressureChanged = { [weak self] in self?.spaceParking?.setUnderPressure($0) }
            memoryPressureMonitor = pressure
            pressure.start()
            // A plug or unplug during sleep may never be reported. On wake the bridge reads
            // the source again; so do the power source monitor (it refreshes the hosts'
            // snapshot when the source differs from the one it last reported) and the
            // low-battery rule.
            powerSourceResampler = PowerSourceResampler { [weak self] in
                guard let self, !self.shutdownInProgress, !self.shutdownComplete else { return }
                self.store?.bridge.resamplePowerSource()
                self.powerSourceMonitor?.handleChange()
                self.systemConditionMonitor?.refreshBattery()
            }
            powerSourceResampler?.start()
            let playlists = startPlaylistScheduler(store: store)
            startAutomaticWallpapers(store: store, playlists: playlists, spaces: spaces, pressure: pressure)
            // The Shortcuts app lists these; commands wait for the handler set after bootstrap.
            AppAutomation.shared.wallpapers = {
                store.librarySnapshot.wallpapers.filter(\.supported).map { (id: $0.id, title: $0.title) }
            }
            AppAutomation.shared.displays = {
                let titles = DisplayTitleResolver.system.resolved()
                return Self.availableAutomationDisplays(store: store).map {
                    (id: $0.displayId, title: titles.title($0.title, displayId: $0.displayId))
                }
            }
            AppAutomation.shared.playlistPlans = { PlaylistStore.shared.plans.map { (id: $0.id, title: $0.name) } }
            AppAutomation.shared.displayLayouts = { WallpaperDisplayLayoutStore.shared.layouts.map { (id: $0.id, title: $0.name) } }
            AppAutomation.shared.propertyPresets = {
                store.librarySnapshot.wallpapers.filter(\.supported).flatMap { wallpaper in
                    WallpaperPresetStore.shared.presets(wallpaperID: wallpaper.id).map {
                        (id: $0.id, title: $0.name, wallpaper: wallpaper.title)
                    }
                }
            }
            let hotKeys = GlobalHotKeys(preferences: .shared)
            hotKeys.onPress = { [weak self] action in self?.runAutomation(action.command) }
            globalHotKeys = hotKeys
            hotKeys.start()
            Task { await WallpaperFocusFilter.refreshState() }
            startWallpaperEnergyRecorder(store: store)
            startTelemetry(store: store)
            startActiveCount()
            do {
                try lockScreen?.start()
                if lockScreen?.isRequested != true { try startDesktopWallpaperSync() }
                // With the switch off this puts back a poster a crash or an older run left behind.
                applyDesktopPicturePreference()
            } catch {
                lastError = error
                AppLog.error("startup: Native wallpaper recovery failed: \(error.localizedDescription)")
            }
        }
        bootstrapStore()
    }

    private func finishLaunching(launchEvent: NSAppleEventDescriptor?) {
        AppLog.info("startup: bootstrap dispatched")
        startDiagnosticsSessionIfRequested()
        finishedLaunching = true
        startTerminationSignalRelay()
        let opened = pendingOpenedFiles
        pendingOpenedFiles = []
        let opensPanel = ControlPanelLaunch.opensPanel(
            launchEvent: launchEvent,
            welcomeSeen: PanelPreferences.welcomeSeen(),
            startupFailed: store == nil,
            environment: ProcessInfo.processInfo.environment)
        if !opensPanel {
            let reason = ControlPanelLaunch.isLoginItemLaunch(launchEvent)
                ? "launched at login" : "\(ControlPanelLaunch.panelAtLaunchKey)=0"
            AppLog.info("startup: \(reason); control panel stays closed")
        }
        DispatchQueue.main.async { [weak self] in
            if opensPanel { self?.showControlPanel(selection: .wallpaper) }
            if !opened.isEmpty { self?.importOpenedFiles(opened) }
        }
    }

    /// Files dropped on the Dock icon, or opened with the app from Finder, go into the library
    /// the way Import does, skipping wallpapers already there. The panel opens on Installed so
    /// the import's progress and report are in view.
    func application(_ application: NSApplication, open urls: [URL]) {
        // `wallpapermachine://` links; see `AutomationCommand` for what they may ask.
        for url in urls where !url.isFileURL {
            guard let command = AutomationCommand(url: url) else {
                AppLog.warn("ignored a link WallpaperMachine does not understand: \(url.absoluteString)")
                continue
            }
            runAutomation(command)
        }
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        guard finishedLaunching else {
            pendingOpenedFiles.append(contentsOf: files)
            return
        }
        importOpenedFiles(files)
    }

    private func importOpenedFiles(_ files: [URL]) {
        guard store != nil, !shutdownInProgress, !shutdownComplete else { return }
        showControlPanel(selection: .wallpaper)
        do {
            try libraryImports.start(files, duplicates: .skip)
        } catch {
            lastError = error
            rebuildMenu()
            presentErrorAlert(error)
        }
    }

    /// Changes wallpapers on displays whose playlist rotates or follows the day. A switch goes
    /// through the display's command slot, like the panel's and the menu bar's, and picks its
    /// wallpaper when its turn comes.
    private func startPlaylistScheduler(store: BridgeStore) -> PlaylistScheduler {
        let playlists = PlaylistStore.shared
        store.onWallpaperApplied = { [weak self] wallpaper, display in
            playlists.clearFailure(wallpaper, on: display)
            self?.schedulePosterRefresh()
        }
        // Nil while wallpapers do not play on the display; otherwise whether it is paused only
        // because it is out of sight (covered, behind a full-screen app, not the display in use).
        let outOfSight: @MainActor (String) -> Bool? = { [weak self] display in
            guard self?.automaticWallpapers?.scheduler.inFlight.contains(display) != true else { return nil }
            return self?.ownSuspension(ofDisplay: display, store: store)
        }
        let scheduler = PlaylistScheduler(
            store: playlists,
            collections: WallpaperCollectionStore.shared,
            displays: {
                store.settingsSnapshot.displays.filter(\.isIndependent).map(\.displayId)
            },
            library: { store.librarySnapshot.wallpapers.filter(\.supported).map(\.id) },
            favorites: { PanelPreferences.favorites() },
            current: { store.shownWallpaperID(on: $0) },
            isRunning: { outOfSight($0) == false },
            isUnseen: { outOfSight($0) == true },
            // Only a plain video has an end to wait for, and only the video host plays one.
            watchClipEnd: { [weak self] display, wallpaper, ended in
                guard let host = self?.nativeVideoHost,
                      let row = store.settingsSnapshot.displays.first(where: { $0.displayId == display }),
                      let physical = ResolvedDisplayTitles.liveDisplayID(display, title: row.title) else { return nil }
                return host.watchClipEnd(displayID: physical, wallpaperID: wallpaper, ended: ended)
            },
            activate: { display, choose in
                var applied: String?
                try await store.commands.run(slot: BridgeStore.activationSlot(displayId: display), origin: .playlist) {
                    guard let id = choose() else { return }
                    try await store.activateWallpaperAsync(id: id, displayId: display, origin: .playlist)
                    applied = id
                }
                return applied
            }, commandRevision: { display in
                store.commands.revision(for: BridgeStore.activationSlot(displayId: display))
            })
        playlistScheduler = scheduler
        playlists.skipHandler = { [weak scheduler] display in
            guard scheduler?.skip(display) == true else { return false }
            WallpaperAutomationStore.shared.manualChoice?(display)
            return true
        }
        playlists.resumeHandler = { [weak scheduler] display in scheduler?.resume(display) }
        scheduler.start()
        return scheduler
    }

    /// Nil unless wallpapers play, presentation runs and the settings row `display` resolves to a
    /// display id; otherwise whether that display alone is suspended (covered, behind a
    /// full-screen app, not the display in use).
    private func ownSuspension(ofDisplay display: String, store: BridgeStore) -> Bool? {
        guard store.appSnapshot.playbackState == .playing,
              let policy = presentationPolicy, policy.globalPresentation == .running,
              let row = store.settingsSnapshot.displays.first(where: { $0.displayId == display }),
              let physical = ResolvedDisplayTitles.liveDisplayID(display, title: row.title) else { return nil }
        return policy.suspendedDisplayIDs.contains(physical)
    }

    /// Reconciles cached posters and window placement after automatic-selection inputs or results change.
    private func updateAutomaticWallpaperContext() {
        retainSpacePosters()
        spacePinning?.update()
        spaceParking?.update()
    }

    /// Needs the playlist scheduler, the Space monitor and the memory-pressure monitor, all
    /// started before it.
    private func startAutomaticWallpapers(
        store: BridgeStore, playlists playlistScheduler: PlaylistScheduler,
        spaces: WallpaperSpaceMonitor, pressure: MemoryPressureMonitor
    ) {
        let controller = WallpaperAutomationController(bridge: store, rules: .shared, playlists: .shared, collections: .shared,
            focus: .shared, displays: { Self.availableAutomationDisplays(store: store).map(\.displayId) },
            targetDisplay: { [weak self] in self?.controlPanelNavigation.targetDisplayID ?? "primary" },
            canRun: { [weak self] display in self?.ownSuspension(ofDisplay: display, store: store) == false },
            playlistScheduler: playlistScheduler, spaceMonitor: spaces,
            onInputsChanged: { [weak self] notification in
                self?.updateAutomaticWallpaperContext()
                self?.schedulePosterRefresh(after: notification)
            },
            onSettled: { [weak self] in
                self?.updateAutomaticWallpaperContext()
                self?.schedulePosterRefresh()
            })
        automaticWallpapers = controller
        store.onUserWallpaperChoice = { [weak self, weak controller] wallpaper, display in
            controller?.scheduler.noteManualChoice(display, wallpaperID: wallpaper)
            self?.playlistScheduler?.noteManualChoice(display)
            self?.schedulePosterRefresh()
        }
        // A display the user emptied stays empty: its playlist waits until a wallpaper is put on
        // it again or they resume it. A rule that is current is marked as handled, so it does
        // not fill the display the moment it was cleared.
        store.onUserWallpaperRemoved = { [weak controller] _, display in
            if PlaylistStore.shared.playlist(for: display).mode != .off {
                PlaylistStore.shared.setHold(.removedWallpaper, on: display)
                AppLog.info("playlist: display \(display) waits, since its wallpaper was removed")
            }
            controller?.scheduler.noteManualChoice(display)
        }
        controller.scheduler.start()
        let mover = SystemSpaceWindowMover()
        let replicas = WallpaperSpaceReplicas(
            plan: { [weak self] in self?.spaceReplicaPlan(keeping: self?.spaceParking?.current ?? [:]) ?? [:] },
            sources: { [weak self] in self?.spaceReplicaSources() ?? [] }, mover: mover)
        spaceReplicas = replicas
        let pinning = WallpaperSpacePinning(
            windows: { [weak self] in
                SystemPinnableWindow.all(wallpaperIDs: self?.wallpaperIDsByWindow() ?? [:]) { number, display, wallpaper in
                    self?.wallpaperWindowIsReady(number: number, display: display, wallpaper: wallpaper) ?? false
                }
            },
            pins: { [weak self] in self?.spacePins() ?? [:] },
            holding: { [weak self] display in self?.switchHold?.isHolding(display) ?? false },
            mover: mover)
        pinning.onUpdated = { [weak replicas] in replicas?.update() }
        spacePinning = pinning
        pinning.start()
        let parking = WallpaperSpaceParking(
            plan: { [weak self] in self?.spaceParkingPlan() ?? [:] },
            send: { [weak store] display, wallpapers in
                try await store?.setDisplayParkedWallpapersAsync(displayID: display, wallpaperIDs: wallpapers)
            },
            hosts: { [weak self] plan in
                self?.webWallpaperHost?.setKeptWallpapers(plan)
                self?.nativeVideoHost?.setKeptWallpapers(plan)
                self?.spaceReplicas?.update()
            },
            prepared: { [weak self] display, wallpaper in
                self?.desktopWallpaperIsLoaded(display: display, wallpaper: wallpaper) ?? true
            },
            preload: { [weak self] display, wallpaper in
                try await self?.preloadDesktopWallpaper(display: display, wallpaper: wallpaper)
            })
        spaceParking = parking
        parking.setUnderPressure(pressure.underPressure)
        parking.setUnloaded(appliedGlobalPresentation == .unloaded)
        parking.start()
    }

    /// Keeps what the running scenes say about being drawn, so the Compatibility card can tell it
    /// later without running them. Only a changed set of reports is handed over.
    private func recordSceneDrawVerdicts(_ store: BridgeStore) {
        let reports = store.settingsSnapshot.sceneRenderers
        guard reports != recordedSceneReports, let verdicts = store.sceneDrawVerdicts else { return }
        recordedSceneReports = reports
        let revision = store.snapshotRevision
        Task { await verdicts.record(reports: reports, revision: revision) }
    }

    /// Rates each wallpaper's energy use from background samples while it plays alone.
    /// See `WallpaperEnergyRecorder`; `wallpaperEnergyContext()` decides when a sample
    /// can be credited.
    private func startWallpaperEnergyRecorder(store: BridgeStore) {
        let ratings = WallpaperEnergyRatings(
            file: ClientPaths.energyRatingsURL,
            batteryWattHours: { BatteryCapacity.fullChargeWattHours() })
        store.wallpaperEnergyRatings = ratings
        let recorder = WallpaperEnergyRecorder(
            source: CoalitionEnergySource(), ratings: ratings
        ) { [weak self] in self?.wallpaperEnergyContext() }
        wallpaperEnergy = recorder
        // The policy started first and may already have suspended presentation.
        recorder.setParked(presentationPolicy.map { $0.globalPresentation != .running } ?? false)
        recorder.start()
    }

    /// See `TelemetryService`. It does nothing until **Send performance data** is on, and
    /// opens no frame window in a run that asked for a diagnostic window through the
    /// environment, so the two never switch the same counters.
    private func startTelemetry(store: BridgeStore) {
        let diagnosticsRequested = ProcessInfo.processInfo.environment[RuntimeDiagnosticsRequest.durationKey] != nil
        let sampler = diagnosticsRequested
            ? nil : TelemetrySampler(source: store) { [weak self] in self?.telemetryFrameContext() }
        var inputs = TelemetryService.Inputs()
        inputs.kind = { [weak store] id in store?.librarySnapshot.wallpapers.first { $0.id == id }?.kind }
        inputs.energy = { [weak store] in store?.wallpaperEnergyRatings?.entries ?? [:] }
        inputs.loadJournal = ClientPaths.supportURL.appendingPathComponent(DiagnosticsBundle.loadJournalFileName)
        let service = TelemetryService(
            preferences: TelemetryPreferences(), spool: TelemetrySpool(), uploader: TelemetryClient(),
            sampler: sampler, inputs: inputs)
        telemetry = service
        store.telemetry = service
        service.start()
    }

    /// See `TelemetryActiveCount`: once a day, for everyone, with no install id. A run with
    /// its own app-support folder or preferences sends nothing.
    private func startActiveCount() {
        guard TelemetryActiveCount.countsRun(environment: ProcessInfo.processInfo.environment) else { return }
        let count = TelemetryActiveCount(sender: TelemetryClient())
        activeCount = count
        count.start()
    }

    /// The scenes a frame window credits, by display. Nil while nothing plays; a display
    /// suspended on its own is left out, so its paused surface is not counted.
    private func telemetryFrameContext() -> TelemetryFrameContext? {
        guard let store, let policy = presentationPolicy, !shutdownInProgress,
              policy.globalPresentation == .running,
              store.appSnapshot.playbackState == .playing
        else { return nil }
        let settings = store.settingsSnapshot
        let kinds = Dictionary(store.librarySnapshot.wallpapers.map { ($0.id, $0.kind) },
                               uniquingKeysWith: { first, _ in first })
        let modes = Dictionary(settings.sceneUpdateModes.map { ($0.displayId, $0.mode) },
                               uniquingKeysWith: { first, _ in first })
        var scenes: [UInt32: TelemetryFrameContext.Scene] = [:]
        for scene in settings.sceneRenderers where !policy.suspendedDisplayIDs.contains(scene.displayId) {
            scenes[scene.displayId] = TelemetryFrameContext.Scene(
                wallpaperID: scene.wallpaperId, kind: TelemetryReport.Kind(kinds[scene.wallpaperId]),
                backend: scene.backend, mode: modes[scene.displayId])
        }
        let process = ProcessInfo.processInfo
        return TelemetryFrameContext(
            scenes: scenes, displays: TelemetryEnvironment.displaysByID(),
            frameRateCap: settings.effectiveFrameRateCap, renderScale: settings.renderScale,
            reducedQuality: !settings.qualityThrottle.isEmpty, battery: settings.onBatteryPower,
            lowPower: process.isLowPowerModeEnabled, thermal: TelemetryVocabulary.thermal(process.thermalState))
    }

    /// Nil whenever the app's energy is not one wallpaper's: playback paused or suspended
    /// (display sleep, lock, app rules, Low Power Mode, heat, a Focus filter, other audio,
    /// battery pause), the panel on screen
    /// with its WebKit work, a download running SteamCMD inside the app's coalition or
    /// fetching a pixiv original in the app itself, or a video on the native player,
    /// whose decoding and drawing macOS charges to no coalition of this app.
    private func wallpaperEnergyContext() -> WallpaperEnergyContext? {
        guard let store, let policy = presentationPolicy, !shutdownInProgress,
              previewWindow == nil,
              policy.globalPresentation == .running,
              store.appSnapshot.playbackState == .playing,
              !workshopStore.downloader.isRunning, !pixivStore.downloads.isRunning
        else { return nil }
        if let window = controlPanelWindow, window.isVisible, !window.isMiniaturized,
           window.occlusionState.contains(.visible) {
            return nil
        }
        let settings = store.settingsSnapshot
        let connected = Set(SystemDisplays.screens().map(\.id))
        let liveDisplays = Dictionary(store.monitorInformationSnapshot.rows.compactMap { row in
            ResolvedDisplayTitles.liveDisplayID(row.displayId, title: row.title)
                .flatMap { connected.contains($0) ? (row.displayId, $0) : nil }
        }, uniquingKeysWith: { first, _ in first })
        let library = store.librarySnapshot.wallpapers
        return WallpaperEnergyContext.resolve(
            assignments: store.monitorInformationSnapshot.rows.map {
                (display: $0.displayId, wallpaper: $0.wallpaperId)
            },
            suspendedDisplays: policy.suspendedDisplayIDs,
            nativeVideoDisplays: nativeVideoHost?.activeDisplayIDs ?? [],
            frameRateCap: settings.effectiveFrameRateCap, renderScale: settings.renderScale,
            scene: WallpaperEnergySceneSettings(
                resolution: settings.sceneResolution, quality: settings.sceneQuality,
                metalFXUpscaling: settings.metalfxUpscalingEnabled),
            // A wallpaper of unknown kind keeps the scene settings: rating it apart costs a
            // new measurement, rating it together could mix two costs.
            isScene: { id in
                let kind = library.first { $0.id == id }?.kind
                return kind != .video && kind != .webpage
            },
            resolveDisplay: { liveDisplays[$0] })
    }

    /// Opens a bounded diagnostic window when the environment explicitly asks
    /// for one. Absent the variable this starts nothing, counts nothing and
    /// creates no timer. The renderer's counters then run only in the frame
    /// windows of **Send performance data** when the user has turned it on
    /// (`TelemetryService`), and the in-process counters stay outside a session.
    /// With the variable set, telemetry opens no frame window at all.
    ///
    /// `WALLPAPER_MACHINE_DIAGNOSTICS` is a duration in seconds, and
    /// `WALLPAPER_MACHINE_DIAGNOSTICS_DELAY` optionally opens the window that
    /// many seconds after launch (see `RuntimeDiagnosticsRequest`). One
    /// aggregated report is written to the log when it elapses; nothing is
    /// emitted per frame, and no screenshot, pixel readback or periodic disk
    /// write is involved.
    private func startDiagnosticsSessionIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        guard let store, environment[RuntimeDiagnosticsRequest.durationKey] != nil else { return }
        guard let request = RuntimeDiagnosticsRequest(environment: environment) else {
            AppLog.error("""
                diagnostics not started: \(RuntimeDiagnosticsRequest.durationKey) and \
                \(RuntimeDiagnosticsRequest.delayKey) take whole seconds
                """)
            return
        }
        let session = RuntimeDiagnosticsSession(store: store)
        diagnostics = session
        Task { [weak self] in
            do {
                if request.delay > .zero {
                    try await Task.sleep(for: request.delay)
                    // Quit during the delay: there is nothing left to observe.
                    guard let self, self.diagnostics === session else { return }
                }
                try await session.start(duration: request.duration) { lines in
                    for line in lines { AppLog.info("diagnostics \(line)") }
                    self?.diagnostics = nil
                }
                AppLog.info("diagnostics session open for \(request.duration.components.seconds)s")
            } catch {
                AppLog.error("diagnostics session failed: \(error.localizedDescription)")
                self?.diagnostics = nil
            }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard !shutdownInProgress, !shutdownComplete,
              let window = controlPanelWindow, !window.isVisible || window.isMiniaturized else { return }
        NSApp.setActivationPolicy(.regular)
        ControlPanelWindow.bringForward(window)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // A quit that ran its stages restored the desktop and let the sync go; any other puts
        // the desktop back here.
        tearDownServices(restoringDesktop: true)
        if let displayChangeObserver {
            NotificationCenter.default.removeObserver(displayChangeObserver)
            self.displayChangeObserver = nil
        }
        if let powerOffObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(powerOffObserver)
            self.powerOffObserver = nil
        }
        displayRefresh.cancel()
        if let diagnostics {
            self.diagnostics = nil
            Task { await diagnostics.stop() }
        }
        // Last, so a run that dies while tearing down is not recorded as a clean quit. A quit
        // that left a stage running stays `quitting`, which the next launch reports as one
        // that did not finish.
        if stalledQuitStages.isEmpty { SessionLedger.shared?.markEnded() }
        armExitFuse()
    }

    /// The quit has finished, so nothing is left to restore: if the process is still here
    /// shortly after, ending it is safe and a hang in the exit path is not. Preferences are
    /// flushed first because `_exit` skips the flush a normal exit does.
    private func armExitFuse() {
        if NSClassFromString("XCTestCase") != nil { return }
        let delay = quitMode.budgets.exitFuse(stalled: stalledQuitStages)
        let defaults = ClientPreferences.defaults
        ExitFuse.arm(after: delay) {
            AppLog.error("quit: the process was still running \(delay.wholeMilliseconds) ms after the quit finished; ending it")
            defaults.synchronize()
            _exit(0)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // The test host must not instantiate services against the user's app-support folder.
        if NSClassFromString("XCTestCase") != nil { return .terminateNow }
        let (reason, mode, signal) = logQuitRequest()
        switch QuitRequestAnswer.answer(
            finished: shutdownComplete, running: shutdownInProgress ? quitMode : nil, request: mode)
        {
        case .terminateNow:
            return .terminateNow
        case .refuse:
            AppLog.info("quit: already in progress, this request is refused")
            return .terminateCancel
        case .wait:
            // Refusing would cancel a logout, restart or shutdown. The quit that is running
            // replies, and if it would have been refused it goes on instead (see the retry below).
            if quitMode == .interactive { powerOffJoinedQuit = true }
            AppLog.info("quit: already in progress, this request waits for it")
            return .terminateLater
        case .start:
            break
        }

        shutdownInProgress = true
        quitMode = mode
        powerOffJoinedQuit = false
        SessionLedger.shared?.markQuitting(reason: QuitReason.ledgerReason(for: reason, signal: signal))
        // A copy opened while this one quits waits for the library instead of handing over to it.
        InstanceLock.current?.setPhase(.quitting)
        let panelWasVisible = controlPanelWindow?.isVisible == true
        let updateWindowWasVisible = updates.window?.isVisible == true
        previewWindow?.session.close()
        previewWindow?.close()
        previewWindow = nil
        // The quit restores the desktop itself; a restore the switch started must not race it.
        restoringDesktopPicture?.cancel()
        desktopWallpaperSync?.suspendForNativeProvider()
        // Keep this restorer through native-provider callbacks and reloads.
        let wallpaperRestorer = desktopWallpaperSync
        controlPanelWindow?.orderOut(nil)
        updates.window?.orderOut(nil)
        leaveDockUnlessAWindowIsOpen()

        Task {
            var supervisor = QuitSupervisor(mode: mode)
            var outcome = await runQuitStages(on: supervisor, restorer: wallpaperRestorer)
            if case .cancel = outcome, powerOffJoinedQuit {
                // The user's quit would have been refused, but the system has asked to leave
                // in the meantime. Try again within its time limits and do not refuse.
                AppLog.info("quit: a logout, restart or shutdown arrived during this quit; going on under its time limits")
                quitMode = .powerOff
                supervisor = QuitSupervisor(mode: .powerOff)
                outcome = await runQuitStages(on: supervisor, restorer: wallpaperRestorer)
            }
            switch outcome {
            case .cancel(let cancellation):
                // Nothing here suspends between clearing `shutdownInProgress` and the reply, so a
                // request that arrives meanwhile is answered either by the running quit or, once
                // the reply is out, by a new one. The reply never lands on a quit that has begun.
                cancelQuit(
                    cancellation, restorationBudget: supervisor.budgets.restoration,
                    restoringPanel: panelWasVisible, updateWindow: updateWindowWasVisible)
                sender.reply(toApplicationShouldTerminate: false)
                if !updates.updater.isAutomaticInstallation { presentQuitFailure(cancellation) }
                // An installer waiting for this app to quit would replace it whenever it did. The
                // helper takes up to two seconds to answer, which is why this comes last.
                await updates.updater.cancelPendingInstall()
                await updates.resumeAfterCancelledQuit()
                rebuildMenu()
            case .proceed(let stalled):
                completeQuit(sender, reason: reason, signal: signal, desktopUnrestored: false, stalled: stalled)
            case .proceedUnrestored(_, let stalled):
                completeQuit(sender, reason: reason, signal: signal, desktopUnrestored: true, stalled: stalled)
            }
        }

        return .terminateLater
    }

    private func runQuitStages(on supervisor: QuitSupervisor, restorer: DesktopWallpaperSync?) async -> QuitSupervisor.Outcome {
        await supervisor.run(
            restoration: .init(name: "restore") { [self] in try await restoreDesktopForQuit(restorer) },
            teardown: servicesToTearDownForQuit())
    }

    /// The quit went on: tells the system the app may exit. What was left undone is kept
    /// in the session ledger, which stays `quitting` (see `applicationWillTerminate`) when
    /// a stage is still running, so the next launch can say which.
    private func completeQuit(
        _ sender: NSApplication, reason: QuitReason, signal: Int32?, desktopUnrestored: Bool, stalled: [String]
    ) {
        if !stalled.isEmpty {
            AppLog.warn("quit: going on without \(stalled.joined(separator: ", ")), which did not finish in time")
        }
        let note = QuitReason.ledgerText(for: reason, signal: signal, desktopUnrestored: desktopUnrestored, stalled: stalled)
        if note != QuitReason.ledgerReason(for: reason, signal: signal) { SessionLedger.shared?.markQuitting(reason: note) }
        stalledQuitStages = stalled
        shutdownInProgress = false
        shutdownComplete = true
        sender.reply(toApplicationShouldTerminate: true)
    }

    /// Puts the user's own desktop picture back, the lock screen's first. A failure or a
    /// stall cancels the quit.
    private func restoreDesktopForQuit(_ wallpaperRestorer: DesktopWallpaperSync?) async throws {
        if let lockScreen = store?.lockScreenWallpaper {
            try await lockScreen.shutdown {
                try await wallpaperRestorer?.restoreForTermination()
            }
        } else {
            try await wallpaperRestorer?.restoreForTermination()
        }
    }

    /// What is torn down once the desktop is restored, in order. The renderer's own shutdown
    /// is last, so earlier stages that stall cannot starve it (the supervisor keeps it a
    /// minimum of time).
    private func servicesToTearDownForQuit() -> [QuitSupervisor.Stage] {
        [
            .init(name: "services") { [self] in tearDownServices(restoringDesktop: false) },
            .init(name: "imports") { [self] in await libraryImports.shutdown() },
            .init(name: "steamcmd") { [self] in await workshopStore.steamCMDSetup.shutdown() },
            .init(name: "workshop") { [self] in await workshopStore.downloader.shutdown() },
            .init(name: "pixiv") { [self] in await pixivStore.downloads.shutdown() },
            .init(name: "bridge") { [self] in
                do {
                    try await store?.shutdownAsync()
                    lastError = nil
                } catch {
                    lastError = error
                    throw error
                }
            },
        ]
    }

    /// Stops the timers, monitors and hosts the app runs: the quit's `services` stage, and again
    /// in `applicationWillTerminate` for a quit that did not run its stages. Safe to run twice.
    /// The quit's `restore` stage already put the desktop back, so its `services` stage only lets
    /// the sync go; `applicationWillTerminate` restores it in the place it always has.
    private func tearDownServices(restoringDesktop: Bool) {
        libraryDrive?.stop()
        globalHotKeys?.stop()
        AppAutomation.shared.handler = nil
        AppAutomation.shared.displays = nil
        AppAutomation.shared.playlistPlans = nil
        AppAutomation.shared.displayLayouts = nil
        AppAutomation.shared.propertyPresets = nil
        automaticWallpapers?.scheduler.stop()
        desktopSpaces?.stop()
        playlistScheduler?.stop()
        stopPlaybackMonitoring()
        wallpaperEnergy?.stop()
        wallpaperEnergy = nil
        telemetry?.stop()
        telemetry = nil
        activeCount?.stop()
        activeCount = nil
        presentationPolicy?.stop()
        presentationPolicy = nil
        windowAuditor?.stop()
        windowAuditor = nil
        notchMask?.stop()
        notchMask = nil
        wakeRevalidator?.stop()
        wakeRevalidator = nil
        memoryPressureMonitor?.stop()
        memoryPressureMonitor = nil
        spaceReplicas?.stop()
        spaceReplicas = nil
        spacePinning?.stop()
        spacePinning = nil
        spaceParking?.stop()
        spaceParking = nil
        switchHold?.stop()
        switchHold = nil
        if restoringDesktop { desktopWallpaperSync?.stop() }
        desktopWallpaperSync = nil
        previewWindow?.session.close()
        previewWindow?.close()
        previewWindow = nil
        sceneMediaSink?.shutdown()
        sceneMediaSink = nil
        webWallpaperHost?.shutdown()
        webWallpaperHost = nil
        nativeVideoHost?.shutdown()
        nativeVideoHost = nil
        updates.cancel()
    }

    /// The desktop could not be restored in time or at all, so the app keeps running:
    /// everything the quit stopped starts again and the panel comes back. Synchronous on
    /// purpose: the caller replies to the system right after it, and the app must not count
    /// as running again before that reply is on its way (see `applicationShouldTerminate`).
    /// A pending update install is called off by the caller afterwards.
    private func cancelQuit(
        _ cancellation: QuitSupervisor.Cancellation, restorationBudget: Duration,
        restoringPanel: Bool, updateWindow restoringUpdateWindow: Bool
    ) {
        let failure = QuitFailure(cancellation)
        switch cancellation {
        case .restorationFailed:
            AppLog.error("Quit cancelled because wallpaper restoration failed: \(failure.localizedDescription)")
        case .restorationTimedOut:
            AppLog.error("Quit cancelled because wallpaper restoration did not finish within \(restorationBudget.wholeMilliseconds) ms")
        }
        lastError = failure
        shutdownInProgress = false
        InstanceLock.current?.setPhase(.running)
        SessionLedger.shared?.markRunning()
        // The system was told no, so an earlier announcement no longer applies. The same goes
        // for a signal: the next one asks for a quit again instead of forcing the end.
        powerOffNotice.clear()
        terminationSignal = nil
        terminationSignals?.reset()
        // Native restoration may already have released the desktop even
        // though poster restoration failed. Resume without waiting for
        // another bridge snapshot, but never overwrite an owned provider.
        if store?.lockScreenWallpaper?.ownsDesktopProvider != true {
            do { try startDesktopWallpaperSync() } catch {
                AppLog.error("Desktop poster sync could not be restarted: \(error.localizedDescription)")
            }
        }
        presentationPolicy?.evaluate()
        if restoringPanel {
            showControlPanel(selection: controlPanelNavigation.selection ?? .wallpaper)
        }
        if restoringUpdateWindow, let updateWindow = updates.window {
            NSApp.setActivationPolicy(.regular)
            ControlPanelWindow.bringForward(updateWindow)
        }
        rebuildMenu()
    }

    /// Tells the user the quit did not happen. The menu line alone is easy to miss when the
    /// quit came from the Dock, a logout dialog or an update.
    private func presentQuitFailure(_ cancellation: QuitSupervisor.Cancellation) {
        presentErrorAlert(QuitFailure(cancellation), bringForward: true)
    }

    /// Works out who asked for this quit and how it must behave, and logs both, also for a
    /// request that arrives while a quit is already running. The Apple event is only
    /// readable here, while it is being handled.
    private func logQuitRequest() -> (reason: QuitReason, mode: QuitMode, signal: Int32?) {
        let event = NSAppleEventManager.shared().currentAppleEvent
        let appleEventReason = QuitReason.appleEventReason(from: event)
        let requester = QuitRequester.resolve(
            menuChosen: quitChosenFromMenu, senderPID: QuitRequester.senderPID(of: event))
        quitChosenFromMenu = false
        let signal = terminationSignal
        terminationSignal = nil
        let powerOffNotified = powerOffNotice.isCurrent()
        let updateInstallPending = updates.updater.isInstallPending
        let reason = QuitReason.classify(
            appleEventReason: appleEventReason,
            powerOffNotified: powerOffNotified,
            updateInstallPending: updateInstallPending,
            terminationSignal: signal)
        let mode = QuitMode.resolve(reason: reason, powerOffNotified: powerOffNotified)
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none"
        AppLog.info(
            "quit: reason=\(reason.rawValue) mode=\(mode.rawValue) "
                + "from=\(requester.logText()) "
                + "frontmost=\(frontmost) "
                + "panelVisible=\(controlPanelWindow?.isVisible ?? false) "
                + "updateInstallPending=\(updateInstallPending) "
                + "alreadyInProgress=\(shutdownInProgress || shutdownComplete) "
                + "powerOffNotified=\(powerOffNotified) "
                + "appleEventReason=\(appleEventReason.map(QuitReason.text(forCode:)) ?? "none") "
                + "signal=\(signal.map(TerminationSignalRelay.name(of:)) ?? "none")")
        return (reason, mode, signal)
    }

    // MARK: Termination signals

    /// SIGTERM and SIGHUP become the quit the menu's Exit runs. Not before launching has
    /// finished: until then the default action applies, and a stop is as safe as it ever was.
    private func startTerminationSignalRelay() {
        let relay = TerminationSignalRelay(
            terminate: { [weak self] signal in
                // Logged here, off the main thread, so a stalled main thread still leaves the reason.
                AppLog.info(
                    "signal: \(TerminationSignalRelay.name(of: signal)) received; quitting in order, "
                        + "and a second one ends the app at once")
                // From the main run loop, never a main-queue job: a nested run loop entered from
                // inside one (AppKit's terminateLater wait) would never drain the main queue.
                // In every common mode, so that an open alert or menu does not hold the quit back.
                TerminationSignalRelay.performOnMainRunLoopInAnyMode {
                    MainActor.assumeIsolated { self?.quitBecauseOfSignal(signal) }
                }
            },
            forceDefault: Self.endAppBecauseOfSignal,
            forceAfter: QuitMode.interactive.budgets.longestQuit)
        do {
            try relay.start()
            terminationSignals = relay
        } catch {
            AppLog.warn("signal: SIGTERM and SIGHUP will end the app without a quit: \(error.localizedDescription)")
        }
    }

    private func quitBecauseOfSignal(_ signal: Int32) {
        terminationSignal = signal
        NSApp.terminate(nil)
    }

    /// The second signal, or the deadline for the first: the quit is stuck or the main thread
    /// is, and the sender has asked twice. Ends the process the way the signal always did.
    /// Whatever the quit had not finished is left to the next launch, like a kill.
    nonisolated private static let endAppBecauseOfSignal: @Sendable (Int32) -> Void = { signal in
        let name = TerminationSignalRelay.name(of: signal)
        AppLog.error("signal: \(name) again, or the quit did not finish in time; ending the app by its default action")
        SessionLedger.shared?.markCutShort(reason: "terminated by \(name); ended by force")
        TerminationSignalRelay.endByDefaultAction(signal)
    }

    private func syncPlaybackMonitors() {
        let preferences = PlaybackPreferences.shared
        if !AppRuleMonitor.isNeeded(for: preferences) {
            appRuleMonitor?.stop()
        } else {
            appRuleMonitor?.start()
        }
        if preferences.otherAudioAction == .keepRunning {
            otherAudioMonitor?.stop()
        } else {
            otherAudioMonitor?.start()
        }
        activeDisplayTracker?.setEnabled(preferences.playsOnlyOnActiveDisplay)
    }

    private func stopPlaybackMonitoring() {
        if let playbackPreferencesObserver {
            NotificationCenter.default.removeObserver(playbackPreferencesObserver)
            self.playbackPreferencesObserver = nil
        }
        appRuleMonitor?.stop()
        otherAudioMonitor?.stop()
        systemConditionMonitor?.stop()
        powerSourceMonitor?.stop()
        activeDisplayTracker?.stop()
        powerSourceResampler?.stop()
        powerSourceRefresh?.cancel()
        powerSourceRefresh = nil
    }

    /// The renderer applies its power policy (battery Pause, Reduced quality) when
    /// the source changes and reports nothing back. Reading the snapshot again is
    /// what makes the hosts here (web pages, native video) take in the pause, frame
    /// rate and render scale that came with it. The app's own battery-scoped rule
    /// ("When another app is in front" set to Pause on battery) is worked out again
    /// at once, and so are the post-wake reads, which arrive here when they find a
    /// different source.
    private func powerSourceChanged(_ source: PowerSourceMonitor.Source) {
        let previous = reportedPowerSource
        reportedPowerSource = source
        guard let store, !shutdownInProgress, !shutdownComplete else { return }
        // A wallpaper presenting across a change to or from battery played on battery, which
        // is what the one-time battery question waits for (a panel opened on battery sees it
        // for itself).
        if source == .battery || previous == .battery, wallpaperIsPresenting(store) {
            store.supportPrompt?.recordBatteryUse()
        }
        appRuleMonitor?.refresh()
        powerSourceRefresh?.cancel()
        powerSourceRefresh = Task { [weak self] in
            await PowerSourceRefresh.run(
                expectedOnBattery: source == .battery,
                refresh: {
                    do {
                        try await store.refreshAllAsync()
                        self?.lastError = nil
                        self?.playbackSnapshotCurrent = true
                    } catch {
                        self?.lastError = error
                        self?.playbackSnapshotCurrent = false
                        throw error
                    }
                },
                bridgeOnBattery: { store.settingsSnapshot.onBatteryPower })
            self?.rebuildMenu()
        }
    }

    /// A wallpaper is on a display and drawing: not paused by the user or by the presentation
    /// policy for every display, and its display is not suspended on its own (covered, behind a
    /// full-screen app, not the display in use).
    private func wallpaperIsPresenting(_ store: BridgeStore) -> Bool {
        store.settingsSnapshot.displays.contains { row in
            store.shownWallpaperID(on: row.displayId) != nil
                && ownSuspension(ofDisplay: row.displayId, store: store) == false
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// A click on the Dock icon returns to the section the panel last showed. The delegate has
    /// handled the reopen itself, so it answers false and AppKit adds nothing of its own.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showControlPanel(selection: controlPanelNavigation.selection ?? .wallpaper)
        return false
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard sender === controlPanelWindow else { return frameSize }
        return ControlPanelWindow.clampedFrameSize(frameSize, for: sender)
    }

    /// Closing the panel releases its controller; the stores and the navigation object outlive it,
    /// so opening it again builds a fresh view around them and resumes where it was.
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === controlPanelWindow else { return }

        controlPanelWindow = nil
        window.contentViewController = nil
        leaveDockUnlessAWindowIsOpen()
        rebuildMenu()
    }

    /// Drops to `.accessory` once none of the app's ordinary windows is open
    /// (`ActivationPolicyRule`). A window that is closing still reports itself visible, so
    /// callers forget it first; whatever opens a window raises the policy itself.
    func leaveDockUnlessAWindowIsOpen() {
        let windows = NSApp.windows.map { window in
            ActivationPolicyRule.Window(
                role: activationPolicyRole(of: window),
                isVisible: window.isVisible, isMiniaturized: window.isMiniaturized)
        }
        guard !ActivationPolicyRule.keepsRegular(windows, quitting: shutdownInProgress) else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    private func activationPolicyRole(of window: NSWindow) -> ActivationPolicyRule.Window.Role? {
        if window === controlPanelWindow { return .controlPanel }
        if window === updates.window { return .update }
        if window === previewWindow?.window { return .preview }
        if WebSignInWindowController.isOpen(window) { return .signIn }
        return nil
    }

    private func installDisplayChangeObserver() {
        displayChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.displayRefresh.request()
            }
        }
    }

    private func installPowerOffObserver() {
        powerOffObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.powerOffNotice.record()
                AppLog.info("system: logout, restart or shutdown announced")
            }
        }
    }

    /// Discover, which lists the downloads; a first visit starts its search, as the link to it does.
    func showDiscover() {
        if !workshopStore.hasLoaded && !workshopStore.isLoading { workshopStore.search() }
        showControlPanel(selection: .workshop)
    }

    /// Asks the Workshop about installed items at most once a day, unless turned off; the
    /// automatic update loop calls this too, since the app can run for weeks.
    private func checkWorkshopUpdatesIfDue() {
        guard let store, !shutdownInProgress, !shutdownComplete, playbackSnapshotCurrent else { return }
        workshopStore.updates.checkIfDue(
            installed: store.librarySnapshot.wallpapers.map(\.id), library: ClientPaths.libraryURL)
    }

    /// An error alert, shown from the main run loop: a modal run inside a main-actor task would
    /// stall every other main-actor task until the alert closes. The callers run inside
    /// main-actor tasks and main-queue jobs.
    private func presentErrorAlert(_ error: Error, bringForward: Bool = false) {
        AppUpdateStore.performOnMainRunLoop { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.shutdownInProgress, !self.shutdownComplete else { return }
                // An accessory app's alert opens behind the active app unless it is brought forward.
                if bringForward { NSApp.activate(ignoringOtherApps: true) }
                NSAlert(error: error).runModal()
            }
        }
    }

    /// Settings › About, which also explains updates.
    func showAboutSettings() {
        controlPanelNavigation.revealSettingsSection(.about)
        showControlPanel(selection: .settings)
    }

    func showControlPanel(selection: SidebarSelection) {
        controlPanelNavigation.selection = selection
        NSApp.setActivationPolicy(.regular)
        if let window = controlPanelWindow {
            ControlPanelWindow.constrainToScreen(window)
            ControlPanelWindow.bringForward(window)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: controlPanelRoot())
        // The window keeps its own size floor, and the hosted toolbar and title belong to it.
        hosting.sizingOptions = []
        hosting.sceneBridgingOptions = [.toolbars, .title]
        let window = ControlPanelWindow.make(contentViewController: hosting, delegate: self)
        if !window.setFrameUsingName(ControlPanelWindow.frameAutosaveName) { window.center() }
        ControlPanelWindow.constrainToScreen(window)
        // After the saved frame is restored, so restoring does not overwrite it.
        window.setFrameAutosaveName(ControlPanelWindow.frameAutosaveName)
        controlPanelWindow = window
        ControlPanelWindow.bringForward(window)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The panel over the open library, or what says why there is none.
    private func controlPanelRoot() -> AnyView {
        if let store {
            return AnyView(ControlPanelView(
                store: store, navigation: controlPanelNavigation, workshop: workshopStore,
                pixiv: pixivStore, updater: updates.updater, imports: libraryImports))
        }
        let error = startupError ?? lastError
        return AnyView(BridgeUnavailableView(
            error: error,
            useThisMac: error is StorageUnavailableError ? { [weak self] in self?.keepLibraryOnThisMac() } : nil))
    }

    /// A display whose playlist rotates moves along the playlist; any other display takes the
    /// next wallpaper in library order.
    private func showWallpaperPreview(_ selection: WallpaperPreviewSession.Selection) {
        guard let store, !shutdownInProgress, !shutdownComplete else { return }
        wallpaperEnergy?.invalidate()
        telemetry?.invalidateFrames()
        if previewWindow == nil {
            let loader = WallpaperPreviewLoader()
            let session = WallpaperPreviewSession(load: { [weak store] selection in
                guard let store else { throw CancellationError() }
                var request = try await store.wallpaperPreviewRequestAsync(id: selection.wallpaperID,
                    displayID: selection.displayID, textOverrides: selection.textOverrides)
                let placement = StillImagePlacementStore.shared
                if request.kind == .web, placement.generatedImage(wallpaperID: request.wallpaperID) != nil {
                    request.propertiesJSON = try placement.effectivePropertiesJSON(request.propertiesJSON,
                        wallpaperID: request.wallpaperID, displayID: selection.displayID)
                }
                return try await loader.validate(request)
            }, makeSurface: { request, generation in
                if request.kind == .web { return WebWallpaperPreviewSurface(request: request, generation: generation) }
                if request.kind == .video { return VideoWallpaperPreviewSurface(request: request) }
                return SceneWallpaperPreviewSurface(request: request)
            })
            let controller = WallpaperPreviewWindowController(session: session, displayAspect: { [weak store] displayID in
                guard let store else { return nil }
                let title = store.settingsSnapshot.displays.first { $0.displayId == displayID }?.title ?? ""
                return DisplayGeometry.aspectRatio(displayID: displayID, title: title)
            })
            controller.onClosed = { [weak self, weak controller] in
                guard let self, self.previewWindow === controller else { return }
                self.previewWindow = nil
                self.wallpaperEnergy?.invalidate()
                self.telemetry?.invalidateFrames()
                self.leaveDockUnlessAWindowIsOpen()
            }
            previewWindow = controller
        }
        NSApp.setActivationPolicy(.regular)
        previewWindow?.present(selection)
    }

    func canActivateNextWallpaper(store: BridgeStore, displayId: String) -> Bool {
        if PlaylistStore.shared.playlist(for: displayId).mode == .rotate {
            return playlistScheduler?.canSkip(displayId) ?? false
        }
        return store.nextWallpaperID(displayId: displayId) != nil
    }

    /// Runs a command from a link, a keyboard shortcut or the menu bar. A failure shows in the
    /// menu bar menu, as one from the menu itself does, and in an alert too when `alertsOnFailure`.
    func runAutomation(_ command: AutomationCommand, alertsOnFailure: Bool = false) {
        Task {
            do {
                try await AppAutomation.shared.perform(command)
                lastError = nil
            } catch {
                lastError = error
                AppLog.warn("\(String(describing: command)) failed: \(error.localizedDescription)")
                if alertsOnFailure { presentErrorAlert(error) }
            }
            rebuildMenu()
        }
    }

    /// Carries out a command from outside the window: the Shortcuts app, a link, a keyboard
    /// shortcut or the menu bar. Switches share the panel's per-display slot, so the latest
    /// request for a display wins.
    private func performAutomation(_ command: AutomationCommand) async throws {
        guard let store, !shutdownInProgress, !shutdownComplete else { throw AutomationError.notReady }
        switch command {
        case .play, .pause, .togglePlayback:
            do {
                try await store.commands.run {
                    let paused = store.appSnapshot.playbackState == .paused
                    let play = command == .play || (command == .togglePlayback && paused)
                    if play, paused {
                        try await store.playAllAsync()
                    } else if !play, !paused {
                        try await store.pauseAllAsync()
                    }
                }
            } catch {
                // What playback is in is not known until the next snapshot.
                playbackSnapshotCurrent = false
                throw error
            }
            playbackSnapshotCurrent = true
        case .mute, .unmute, .toggleMute:
            // A preference, not a renderer command: the presentation policy hears the change and
            // delivers it through its own serialized audio path, so this needs no queue turn.
            let preferences = PlaybackPreferences.shared
            let muted = command == .mute || (command == .toggleMute && !preferences.wallpapersMuted)
            guard muted != preferences.wallpapersMuted else { return }
            preferences.wallpapersMuted = muted
            AppLog.info("all wallpapers \(muted ? "muted" : "unmuted")")
        case .previous(let display):
            let displayId = try automationDisplay(display, store: store)
            try await store.commands.run(slot: BridgeStore.activationSlot(displayId: displayId)) {
                _ = try self.automationDisplay(displayId, store: store)
                try await store.activatePreviousWallpaperAsync(displayId: displayId)
            }
        case .next(let display):
            let displayId = try automationDisplay(display, store: store)
            // The playlist's own next, with a fresh interval after it; a switch it is already
            // making counts as the answer rather than falling back to the library order.
            if PlaylistStore.shared.playlist(for: displayId).mode == .rotate {
                guard PlaylistStore.shared.skipHandler?(displayId) == true else {
                    throw AutomationError(
                        message: String(localized: "This display’s playlist has no other wallpaper to change to."))
                }
                return
            }
            // "Next" is measured from whatever the display shows when this one gets its turn.
            try await store.commands.run(slot: BridgeStore.activationSlot(displayId: displayId)) {
                _ = try self.automationDisplay(displayId, store: store)
                guard let id = store.nextWallpaperID(displayId: displayId) else { return }
                try await store.activateWallpaperAsync(id: id, displayId: displayId, origin: .user)
            }
        case .random(let display, let pool):
            // The pick is made when the display's turn comes; see `activateRandomWallpaperAsync`.
            try await store.activateRandomWallpaperAsync(
                displayId: try automationDisplay(display, store: store), pool: pool,
                favorites: PanelPreferences.favorites(), playlists: .shared)
        case .apply(let id, let display):
            let displayId = try automationDisplay(display, store: store)
            guard store.librarySnapshot.wallpapers.contains(where: { $0.id == id }) else {
                throw AutomationError(message: String(localized: "No installed wallpaper has the id “\(id)”."))
            }
            try await store.commands.run(slot: BridgeStore.activationSlot(displayId: displayId), subject: id) {
                _ = try self.automationDisplay(displayId, store: store)
                try await store.activateWallpaperAsync(id: id, displayId: displayId, origin: .user)
            }
        case .applyEverywhere(let id):
            guard store.librarySnapshot.wallpapers.contains(where: { $0.id == id }) else {
                throw AutomationError(message: String(localized: "No installed wallpaper has the id “\(id)”."))
            }
            // One command for the whole operation, which takes its own turn in the queue.
            try await store.activateWallpaperEverywhereAsync(id: id)
        case .removeWallpaper(let display):
            // Takes the display's turn in the queue, and leaves its playlist waiting.
            try await store.removeShownWallpaperAsync(displayId: try automationDisplay(display, store: store))
        case .applyPlaylist(let id, let display):
            let displayID = try automationDisplay(display, store: store)
            try await store.commands.run(slot: BridgeStore.activationSlot(displayId: displayID)) {
                _ = try self.automationDisplay(displayID, store: store)
                try WallpaperAutomationController.applyPlaylist(id, to: displayID, playlists: .shared, collections: .shared)
                WallpaperAutomationStore.shared.manualChoice?(displayID)
            }
        case .applyPreset(let id):
            let presets = WallpaperPresetStore.shared
            let preset = try presets.preset(id: id)
            guard store.librarySnapshot.wallpapers.contains(where: { $0.id == preset.wallpaperID && $0.supported }) else {
                throw AutomationError(message: String(localized: "This preset’s wallpaper is no longer installed."))
            }
            try await store.commands.run(slot: "preset:\(preset.wallpaperID)", subject: preset.wallpaperID) {
                let current = try presets.preset(id: id)
                let options = try await store.wallpaperOptionsSnapshotAsync(wallpaperId: current.wallpaperID)
                try await presets.apply(current, options: options, bridge: store, userInitiated: true)
            }
        case .applyDisplayLayout(let id):
            let layout = try WallpaperDisplayLayoutStore.shared.layout(id)
            try await store.applyDisplayTransferAsync(.layout(layout.assignments))
        case .open(let page):
            switch page {
            case .discover?:
                showDiscover()
            case .pixiv?:
                if !pixivStore.hasLoaded && !pixivStore.isLoading { pixivStore.apply(pixivStore.query) }
                showControlPanel(selection: .pixiv)
            case .settings?:
                showControlPanel(selection: .settings)
            case .installed?:
                showControlPanel(selection: .wallpaper)
            case nil:
                showControlPanel(selection: controlPanelNavigation.selection ?? .wallpaper)
            }
        }
    }

    private static func availableAutomationDisplays(store: BridgeStore) -> [BridgeDisplaySettingsRow] {
        StatusMenuModel.eligibleDisplays(store.settingsSnapshot.displays,
                                         connected: Set(SystemDisplays.screens().map(\.id)))
    }

    /// The display a command names, or the panel's target display; only an enabled display
    /// that shows its own wallpaper can be switched.
    private func automationDisplay(_ requested: String?, store: BridgeStore) throws -> String {
        let id = requested ?? controlPanelNavigation.targetDisplayID
        guard Self.availableAutomationDisplays(store: store).contains(where: { $0.displayId == id }) else {
            throw AutomationError(message: String(localized: "No enabled display showing its own wallpaper has the id “\(id)”."))
        }
        return id
    }

    /// The library's drive is gone for good: from the next launch the library is WallpaperMachine's
    /// own folder on this Mac again. Nothing on the drive is touched. Quits, since the library a
    /// running app was started without cannot be opened in place.
    private func keepLibraryOnThisMac() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Keep the wallpaper library on this Mac?")
        alert.informativeText = String(localized: "From the next launch WallpaperMachine keeps its library in its own folder on this Mac, so the wallpapers on the drive are not shown. Nothing on the drive is deleted. WallpaperMachine quits now; open it again afterwards.")
        alert.addButton(withTitle: String(localized: "Use This Mac and Quit"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try StorageLocation.write(nil, support: ClientPaths.supportURL)
        } catch {
            AppLog.error("storage: could not go back to this Mac: \(error.localizedDescription)")
            NSAlert(error: error).runModal()
            return
        }
        AppLog.info("storage: the library is in WallpaperMachine's folder on this Mac from the next launch")
        NSApp.terminate(nil)
    }

    /// See `StorageVolumeMonitor`: it observes nothing unless the library is on another disk than
    /// the startup disk. Its stop reaches the wallpapers through the presentation policy.
    private func startLibraryDriveMonitor() {
        let monitor = StorageVolumeMonitor { [weak self] in
            do {
                try await self?.store?.refreshLibraryAsync()
            } catch {
                AppLog.warn("storage: the library could not be read again after its drive returned: \(error.localizedDescription)")
            }
        }
        monitor.onChange = { [weak self] in
            guard let self, !self.shutdownInProgress, !self.shutdownComplete else { return }
            // A preview plays from the library too, and holds its files open.
            if self.libraryDrive?.stopsWallpapers == true { self.previewWindow?.close() }
            self.presentationPolicy?.evaluate()
        }
        monitor.onDriveConnectedAfterLaunch = { [weak self] in self?.openLibraryAfterLaunch() }
        libraryDrive = monitor
        monitor.start()
    }

    /// The drive the app launched without is connected: the library opens in place with every
    /// service a launch starts over it, and an open panel shows it instead of the unavailable page.
    private func openLibraryAfterLaunch() {
        guard store == nil, !shutdownInProgress, !shutdownComplete else { return }
        ClientPaths.reloadStorageLocation()
        openLibrary()
        if store != nil {
            AppLog.info("storage: the library opened without a relaunch")
            // The launch's sweep looked where the drive was not.
            removeAbandonedStaging()
            startLibraryServices()
        }
        // The library, or why it still cannot open.
        (controlPanelWindow?.contentViewController as? NSHostingController<AnyView>)?.rootView = controlPanelRoot()
        rebuildMenu()
    }

    /// A crash during a download leaves its staging behind, holding the whole downloaded item:
    /// SteamCMD's half in app support, what it fetched beside the library. Swept in the background
    /// at launch, and again when the library opens later (`openLibraryAfterLaunch`); each sweep
    /// keeps staging a download or an import still claims, or wrote to recently.
    private func removeAbandonedStaging() {
        let stagingRoots = FileLocation.isSame(ClientPaths.supportURL, ClientPaths.storageURL)
            ? [ClientPaths.supportURL] : [ClientPaths.supportURL, ClientPaths.storageURL]
        let pixivStagingRoot = PixivWallpaperPackager.stagingRoot(forLibrary: ClientPaths.libraryURL)
        let importStagingRoot = WallpaperImportService.stagingRoot(forLibrary: ClientPaths.libraryURL)
        Task.detached(priority: .utility) {
            for root in stagingRoots { WorkshopDownloader.removeAbandonedStaging(in: root) }
            PixivWallpaperPackager.removeAbandonedStaging(in: pixivStagingRoot)
            WallpaperImportService.removeAbandonedStaging(in: importStagingRoot)
        }
    }

    private func bootstrapStore() {
        AppLog.info("startup: bootstrapAsync start")
        guard let store else {
            AppLog.info("startup: bootstrapAsync skipped: store is nil")
            return
        }

        Task {
            do {
                // Before the library loads, so the first options snapshot is already in the
                // language the app shows.
                do {
                    try await store.setLabelLanguageAsync(AppLanguageStore.shared.effective)
                } catch {
                    AppLog.warn("Property labels could not start in the app language: \(error.localizedDescription)")
                }
                try await store.bootstrapAsync()
                startupError = nil
                lastError = nil
                playbackSnapshotCurrent = true
                AppLog.info("startup: bootstrapAsync completed successfully")
                checkWorkshopUpdatesIfDue()
                // Links, keyboard shortcuts and the Shortcuts app act from here on.
                AppAutomation.shared.handler = { [weak self] command in
                    guard let self else { throw AutomationError.notReady }
                    try await self.performAutomation(command)
                }
            } catch {
                AppLog.error("startup: bootstrapAsync FAILED: \(error.localizedDescription)")
                lastError = error
                playbackSnapshotCurrent = false
                // The panel opens without a started library, and Settings is where a failed start
                // is put right; every other command answers at once instead of waiting it out.
                AppAutomation.shared.handler = { [weak self] command in
                    guard let self, case .open = command else { throw AutomationError.notReady }
                    try await self.performAutomation(command)
                }
            }
            rebuildMenu()
            // Also after a failed start: the update may be the fix.
            updates.startAutomaticChecks()
        }
    }

    func refreshStoreSnapshot() {
        guard let store, !shutdownInProgress, !shutdownComplete else { return }
        Task { [weak self] in
            do {
                try await store.refreshAllAsync()
                self?.lastError = nil
                self?.playbackSnapshotCurrent = true
            } catch {
                self?.lastError = error
                self?.playbackSnapshotCurrent = false
            }
            self?.rebuildMenu()
        }
    }

    /// Whether the bridge took the refresh.
    private func refreshDisplaysFromSystemEvent() async -> Bool {
        guard let store, !shutdownInProgress, !shutdownComplete else { return false }
        let accepted: Bool
        do {
            try await store.refreshDisplaysAsync()
            lastError = nil
            playbackSnapshotCurrent = true
            accepted = true
        } catch {
            lastError = error
            playbackSnapshotCurrent = false
            accepted = false
        }
        rebuildMenu()
        return accepted
    }

    /// The applied desktop Scenes that have consented to now-playing.
    ///
    /// The bridge answers, not the library snapshot: consent is per wallpaper
    /// and the snapshot does not carry it. Nothing reads the system player
    /// while this is empty, so a user who left the setting off is never asked
    /// for Automation permission, and a handle that was not there before is a
    /// scene that still has to be told what is playing.
    private static func sceneMediaHandles(store: BridgeStore) async -> Set<UInt64> {
        do {
            return Set(try await store.bridge.systemMediaSceneHandles())
        } catch {
            AppLog.warn("Scene media consumers could not be read: \(error.localizedDescription)")
            return []
        }
    }

    /// The content layers of the wallpaper windows showing on a display, the front one first.
    /// A window that was closed is no longer ordered in, so it is not listed, and neither is one
    /// kept paused for another desktop (`excluding`).
    private static func wallpaperLayers(on displayID: UInt32, excluding kept: Set<Int>) -> [CALayer] {
        WallpaperPresentationPolicy.orderedWallpaperWindows().compactMap { window in
            guard window.isVisible, !kept.contains(window.windowNumber), let screen = window.screen,
                  SystemDesktopPictureWorkspace.id(screen) == String(displayID) else { return nil }
            return window.contentView?.layer
        }
    }

}
