import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem?
    private var controlPanelWindow: NSWindow?
    private var whatsNewWindow: NSWindow?
    private var previewWindow: WallpaperPreviewWindowController?
    private lazy var whatsNewStore = WhatsNewStore()
    private let controlPanelNavigation = ControlPanelNavigation()
    private lazy var workshopStore = WorkshopStore()
    private lazy var pixivStore = PixivStore()
    private lazy var libraryImports = LibraryImportStore()
    /// Files handed to the app before it finished launching, imported once it has.
    private var pendingOpenedFiles: [URL] = []
    private var finishedLaunching = false
    private lazy var appUpdater = AppUpdateStore()
    private var automaticUpdates: Task<Void, Never>?
    /// The version the unattended check last prompted for ("Later" holds until the next launch)
    /// and whether a prompt is waiting for wallpapers to present again.
    private var updatePrompts = UpdatePromptLedger()
    private var displayChangeObserver: NSObjectProtocol?
    private var powerOffObserver: NSObjectProtocol?
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
    private var desktopWallpaperSync: DesktopWallpaperSync?
    private var desktopMediaSession: DesktopMediaSession?
    private var sceneMediaSink: SceneMediaSink?
    private var webWallpaperHost: WebWallpaperHost?
    private var nativeVideoHost: NativeVideoWallpaperHost?
    private var wallpaperHosts: WallpaperHosts {
        WallpaperHosts(web: webWallpaperHost, native: nativeVideoHost)
    }
    private var presentationPolicy: WallpaperPresentationPolicy?
    /// Keeps the previous picture on screen while a switched wallpaper loads.
    private var switchHold: WallpaperSwitchHold?
    private var windowAuditor: WallpaperWindowAuditor?
    private var wakeRevalidator: SystemWakeRevalidator?
    private var memoryPressureMonitor: MemoryPressureMonitor?
    private var appRuleMonitor: AppRuleMonitor?
    private var otherAudioMonitor: OtherAudioMonitor?
    private var systemConditionMonitor: SystemConditionMonitor?
    private var powerSourceMonitor: PowerSourceMonitor?
    private var powerSourceRefresh: Task<Void, Never>?
    private var activeDisplayTracker: ActiveDisplayTracker?
    private var playlistScheduler: PlaylistScheduler?
    private var automaticWallpapers: WallpaperAutomationController?
    private var desktopSpaces: WallpaperSpaceMonitor?
    private var powerSourceResampler: PowerSourceResampler?
    private var posterRefreshTask: Task<Void, Never>?
    /// Putting the user's own desktop picture back after the Settings switch went off, or after
    /// a poster was found left behind.
    private var restoringDesktopPicture: Task<Void, Never>?
    /// A restore has run since a poster could last have been written, whether it worked or not.
    /// It is not tried again until the switch is turned on again or the lock screen hands the
    /// desktop back; a failed one is retried by quitting, which keeps its suspended sync.
    private var desktopPictureRestoreSettled = false
    private var globalHotKeys: GlobalHotKeys?
    private var playbackPreferencesObserver: NSObjectProtocol?
    private var wallpaperEnergy: WallpaperEnergyRecorder?
    private var telemetry: TelemetryService?
    /// Last presentation the bridge accepted, so leaving unloaded clears that flag first.
    private var appliedGlobalPresentation: GlobalPresentation = .running
    private var store: BridgeStore?
    private var startupError: Error?
    private var lastError: Error?
    private var playbackSnapshotCurrent = false
    private var shutdownInProgress = false
    private var shutdownComplete = false
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
    private var themeSubscription: AnyCancellable?
    private var iconSubscription: AnyCancellable?
    private var diagnostics: RuntimeDiagnosticsSession?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hosted unit tests need the executable's types, not its desktop lifecycle.
        // UI tests run in a separate runner, so the real app still starts normally.
        if NSClassFromString("XCTestCase") != nil {
            NSApp.setActivationPolicy(.prohibited)
            return
        }
        let launchEvent = NSAppleEventManager.shared().currentAppleEvent
        themeSubscription = AppThemeStore.shared.$preferences
            .map(\.mode).removeDuplicates()
            .sink { mode in NSApp.appearance = mode.appearance }
        iconSubscription = AppThemeStore.shared.$preferences
            .map(\.icon).removeDuplicates()
            .sink { icon in
                do {
                    NSApp.applicationIconImage = try icon.image()
                } catch {
                    AppLog.error("Dock icon \(icon.rawValue) could not load: \(error.localizedDescription)")
                }
            }
        AppLog.info("startup: didFinishLaunching start")
        BridgeEnvironment.configureVulkanICDIfNeeded()
        AppLog.info("startup: vulkan icd configured")
        // Automatic sun times follow the Mac's position across launches, not only after the
        // source is picked again.
        SolarLocationTracker.shared.start()
        do {
            try ClientPaths.prepare()
            let created = try BridgeStore()
            store = created
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
        pixivStore.restoreSession()
        workshopStore.restoreSteamWebSession()
        // A crash during a download leaves its staging behind, holding the whole downloaded item.
        let stagingRoot = ClientPaths.supportURL
        let pixivStagingRoot = PixivWallpaperPackager.stagingRoot(forLibrary: ClientPaths.libraryURL)
        let importStagingRoot = WallpaperImportService.stagingRoot(forLibrary: ClientPaths.libraryURL)
        Task.detached(priority: .utility) {
            WorkshopDownloader.removeAbandonedStaging(in: stagingRoot)
            PixivWallpaperPackager.removeAbandonedStaging(in: pixivStagingRoot)
            WallpaperImportService.removeAbandonedStaging(in: importStagingRoot)
        }

        NSApp.setActivationPolicy(.accessory)
        AppLog.info("startup: activation policy set to accessory")
        WebSignInWindowController.onClosed = { [weak self] in self?.leaveDockUnlessAWindowIsOpen() }
        installStatusItem()
        synchronizeStatusItem()
        installDisplayChangeObserver()
        AppLog.info("startup: display change observer installed")
        installPowerOffObserver()
        installApplicationMenu()
        AppLog.info("startup: application menu installed")
        if let store {
            workshopStore.startDownloadLifecycle(bridge: store)
            let lockScreen = LockScreenConfiguration.isSupportedBySystem
                ? LockScreenWallpaperService(bridge: store.bridge, contentRevision: { [weak store] in store?.wallpaperContentRevision ?? 0 }) : nil
            if let lockScreen {
                store.lockScreenWallpaper = lockScreen
                lockScreen.beforeActivation = { [weak self] in
                    guard let self else { return }
                    if self.desktopWallpaperSync == nil {
                        self.desktopWallpaperSync = try DesktopWallpaperSync(
                            folder: ClientPaths.supportURL.appendingPathComponent("DesktopPosters"))
                    }
                    self.desktopWallpaperSync?.suspendForNativeProvider()
                }
                lockScreen.afterDeactivation = { [weak self] in
                    guard let self, !self.shutdownInProgress else { return }
                    self.desktopWallpaperSync = nil
                    try self.startDesktopWallpaperSync()
                    // With the switch off, a poster the provider handed back is not kept.
                    self.desktopPictureRestoreSettled = false
                    self.applyDesktopPicturePreference()
                }
            }
            // Created before the hosts, which take over the picture it keeps on screen once their
            // window opens. Its policy is read when a switch starts, not now, so the policy that
            // is set up further down is still found.
            let hold = WallpaperSwitchHold(
                layers: { Self.wallpaperLayers(on: $0) },
                // The rule the poster sync's captures follow: a suspended display is not seen,
                // and its surface may not answer a request for a frame.
                shouldHold: { [weak self] display in
                    guard let policy = self?.presentationPolicy else { return false }
                    return !policy.isSuspended && !policy.suspendedDisplayIDs.contains(display)
                },
                reduceMotion: { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion })
            switchHold = hold
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
                guard lockScreen?.ownsDesktopProvider != true else { return }
                do { try self.startDesktopWallpaperSync() } catch {
                    AppLog.error("Desktop poster sync could not be restarted: \(error.localizedDescription)")
                }
            }
            webHost.start()
            // The experimental native video backend. The bridge returns nothing
            // for it unless the user turned it on, so this host opens no window
            // and starts no player by default.
            let nativeVideo = NativeVideoWallpaperHost(bridge: store.bridge, switchHold: hold)
            nativeVideoHost = nativeVideo
            nativeVideo.onStateChanged = { [weak store] state in store?.receiveHostState(state) }
            nativeVideo.onError = { [weak self] message in
                self?.lastError = WallpaperActionError(message: message)
                self?.rebuildMenu()
            }
            nativeVideo.onSurfacesChanged = { [weak self] in
                guard let self, !self.shutdownInProgress else { return }
                self.presentationPolicy?.evaluate()
                self.windowAuditor?.windowsMayHaveChanged()
            }
            nativeVideo.start()
            store.onSnapshotApplied = { [weak self, weak lockScreen] in
                guard let self, !self.shutdownInProgress else { return }
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
                // Play, pause and a changed library or display set are when a waiting playlist
                // change can happen.
                self.automaticWallpapers?.scheduler.evaluate()
                self.playlistScheduler?.evaluate()
                if let lockScreen, lockScreen.canRefreshAutomatically {
                    lockScreen.refresh()
                }
                // Posters keep the desktop unless the native provider has it or an animated lock
                // screen is on its way to taking it; a screen saver chosen on its own leaves it here.
                if lockScreen?.claimsDesktopPicture != true {
                    // A suspended poster sync must never outlive the native provider.
                    do { try self.startDesktopWallpaperSync() } catch {
                        self.lastError = error
                        AppLog.error("Desktop poster sync could not be restarted: \(error.localizedDescription)")
                    }
                }
            }
            let preferences = PlaybackPreferences.shared
            let appRules = AppRuleMonitor(preferences: preferences)
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
            let policy = WallpaperPresentationPolicy(
                displaySleepAction: { preferences.displaySleepAction },
                // Low Power Mode, a hot Mac and a Focus filter act exactly as app rules do.
                appRuleActions: { appRules.actions.union(conditions.actions) },
                otherAudioActive: { otherAudio.isActive },
                otherAudioAction: { preferences.otherAudioAction },
                // The user's own mute of every wallpaper, on top of the rules above and never
                // written into any wallpaper's saved sound settings.
                userMuted: { preferences.wallpapersMuted },
                desktopCoveredAction: { preferences.desktopCoveredAction },
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
                    self.webWallpaperHost?.setPresentationSuspended(hostsSuspended)
                    self.nativeVideoHost?.setPresentationSuspended(hostsSuspended)
                    let leavingUnloaded = self.appliedGlobalPresentation == .unloaded
                        && presentation != .unloaded
                    let resuming = presentation == .running && self.appliedGlobalPresentation != .running
                    self.wallpaperEnergy?.invalidate()
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
                            // back by sleep, a lock or an app rule may appear.
                            self.retryHeldUpdatePrompt()
                            completion(.success(()))
                        } catch {
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
                            if !suspended { self.retryHeldUpdatePrompt() }
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
            power.onChange = { [weak self] source in self?.powerSourceChanged(source) }
            power.start()
            policy.start()
            desktopSpaces = .shared
            desktopSpaces?.start()
            // After the Space monitor, whose topology the auditor reads to tell a
            // full-screen Space from a wallpaper window that is missing.
            let auditor = WallpaperWindowAuditor(
                canExpectVisible: { [weak self] in self?.presentationPolicy?.globalPresentation == .running },
                isDesktopSpace: { WallpaperWindowAuditor.spaceIsDesktop(displayID: $0, in: .shared) })
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
            startPlaylistScheduler(store: store)
            startAutomaticWallpapers(store: store)
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
        AppLog.info("startup: bootstrap dispatched")
        startDiagnosticsSessionIfRequested()
        finishedLaunching = true
        startTerminationSignalRelay()
        let opened = pendingOpenedFiles
        pendingOpenedFiles = []
        let opensPanel = ControlPanelLaunch.opensPanel(
            launchEvent: launchEvent,
            welcomeSeen: PanelPreferences.welcomeSeen(),
            startupFailed: store == nil)
        if !opensPanel { AppLog.info("startup: launched at login; control panel stays closed") }
        DispatchQueue.main.async { [weak self] in
            if opensPanel { self?.showControlPanel(selection: .wallpaper) }
            self?.showWhatsNewAfterUpdate()
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
    private func startPlaylistScheduler(store: BridgeStore) {
        let playlists = PlaylistStore.shared
        store.onWallpaperApplied = { [weak self] wallpaper, display in
            playlists.clearFailure(wallpaper, on: display)
            self?.schedulePosterRefresh()
        }
        let scheduler = PlaylistScheduler(
            store: playlists,
            collections: WallpaperCollectionStore.shared,
            displays: {
                store.settingsSnapshot.displays.filter { $0.enabled && $0.mode == .standalone }.map(\.displayId)
            },
            library: { store.librarySnapshot.wallpapers.filter(\.supported).map(\.id) },
            favorites: { Self.favoriteWallpaperIDs() },
            current: { store.shownWallpaperID(on: $0) },
            isRunning: { [weak self] display in
                guard store.appSnapshot.playbackState == .playing,
                    self?.automaticWallpapers?.scheduler.inFlight.contains(display) != true,
                    let policy = self?.presentationPolicy, policy.globalPresentation == .running,
                    let row = store.settingsSnapshot.displays.first(where: { $0.displayId == display }),
                    let physicalID = ResolvedDisplayTitles.liveDisplayID(display, title: row.title)
                else { return false }
                return !policy.suspendedDisplayIDs.contains(physicalID)
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
    }

    private func startAutomaticWallpapers(store: BridgeStore) {
        guard let playlistScheduler else { return }
        let controller = WallpaperAutomationController(bridge: store, rules: .shared, playlists: .shared, collections: .shared,
            focus: .shared, displays: { Self.availableAutomationDisplays(store: store).map(\.displayId) },
            targetDisplay: { [weak self] in self?.controlPanelNavigation.targetDisplayID ?? "primary" },
            canRun: { [weak self] display in
                guard store.appSnapshot.playbackState == .playing,
                      let policy = self?.presentationPolicy, policy.globalPresentation == .running,
                      let row = store.settingsSnapshot.displays.first(where: { $0.displayId == display }),
                      let physical = ResolvedDisplayTitles.liveDisplayID(display, title: row.title) else { return false }
                return !policy.suspendedDisplayIDs.contains(physical)
            }, playlistScheduler: playlistScheduler, spaceMonitor: desktopSpaces,
            onSettled: { [weak self] in self?.schedulePosterRefresh() })
        automaticWallpapers = controller
        store.onUserWallpaperChoice = { [weak self, weak controller] _, display in
            controller?.scheduler.noteManualChoice(display)
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
    }

    /// The panel's favorites, which a playlist can rotate through.
    private static func favoriteWallpaperIDs() -> Set<String> {
        PanelPreferences.favorites()
    }

    /// Rates each wallpaper's energy use from background samples while it plays alone.
    /// See `WallpaperEnergyRecorder`; `wallpaperEnergyContext()` decides when a sample
    /// can be credited.
    private func startWallpaperEnergyRecorder(store: BridgeStore) {
        let ratings = WallpaperEnergyRatings(
            file: ClientPaths.supportURL.appendingPathComponent("EnergyRatings.json"),
            batteryWattHours: { BatteryCapacity.fullChargeWattHours() })
        store.wallpaperEnergyRatings = ratings
        let recorder = WallpaperEnergyRecorder(
            source: CoalitionEnergySource(), ratings: ratings
        ) { [weak self] in self?.wallpaperEnergyContext() }
        wallpaperEnergy = recorder
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
                backend: scene.backend, fallback: scene.fallbackReason != nil, mode: modes[scene.displayId])
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
        let connected = Set(WebWallpaperHost.systemScreens().map(\.id))
        let liveDisplays = Dictionary(store.monitorInformationSnapshot.rows.compactMap { row in
            ResolvedDisplayTitles.liveDisplayID(row.displayId, title: row.title)
                .flatMap { connected.contains($0) ? (row.displayId, $0) : nil }
        }, uniquingKeysWith: { first, _ in first })
        return WallpaperEnergyContext.resolve(
            assignments: store.monitorInformationSnapshot.rows.map {
                (display: $0.displayId, wallpaper: $0.wallpaperId)
            },
            suspendedDisplays: policy.suspendedDisplayIDs,
            nativeVideoDisplays: nativeVideoHost?.activeDisplayIDs ?? [],
            frameRateCap: settings.effectiveFrameRateCap, renderScale: settings.renderScale,
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
        presentationPolicy?.stop()
        presentationPolicy = nil
        windowAuditor?.stop()
        windowAuditor = nil
        wakeRevalidator?.stop()
        wakeRevalidator = nil
        memoryPressureMonitor?.stop()
        memoryPressureMonitor = nil
        switchHold?.stop()
        switchHold = nil
        desktopWallpaperSync?.stop()
        previewWindow?.session.close()
        previewWindow?.close()
        previewWindow = nil
        sceneMediaSink?.shutdown()
        webWallpaperHost?.shutdown()
        nativeVideoHost?.shutdown()
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
        let whatsNewWasVisible = whatsNewWindow?.isVisible == true
        previewWindow?.session.close()
        previewWindow?.close()
        previewWindow = nil
        // The quit restores the desktop itself; a restore the switch started must not race it.
        restoringDesktopPicture?.cancel()
        desktopWallpaperSync?.suspendForNativeProvider()
        // Keep this restorer through native-provider callbacks and reloads.
        let wallpaperRestorer = desktopWallpaperSync
        controlPanelWindow?.orderOut(nil)
        whatsNewWindow?.orderOut(nil)
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
                    restoringPanel: panelWasVisible, whatsNew: whatsNewWasVisible)
                sender.reply(toApplicationShouldTerminate: false)
                presentQuitFailure(cancellation)
                // An installer waiting for this app to quit would replace it whenever it did. The
                // helper takes up to two seconds to answer, which is why this comes last.
                await appUpdater.cancelPendingInstall()
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
            .init(name: "services") { [self] in
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
                presentationPolicy?.stop()
                presentationPolicy = nil
                windowAuditor?.stop()
                windowAuditor = nil
                wakeRevalidator?.stop()
                wakeRevalidator = nil
                memoryPressureMonitor?.stop()
                memoryPressureMonitor = nil
                switchHold?.stop()
                switchHold = nil
                desktopWallpaperSync = nil
                sceneMediaSink?.shutdown()
                sceneMediaSink = nil
                webWallpaperHost?.shutdown()
                webWallpaperHost = nil
                automaticUpdates?.cancel()
                appUpdater.cancel()
            },
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

    /// The desktop could not be restored in time or at all, so the app keeps running:
    /// everything the quit stopped starts again and the panel comes back. Synchronous on
    /// purpose: the caller replies to the system right after it, and the app must not count
    /// as running again before that reply is on its way (see `applicationShouldTerminate`).
    /// A pending update install is called off by the caller afterwards.
    private func cancelQuit(
        _ cancellation: QuitSupervisor.Cancellation, restorationBudget: Duration,
        restoringPanel: Bool, whatsNew: Bool
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
        if whatsNew, let whatsNewWindow {
            NSApp.setActivationPolicy(.regular)
            whatsNewWindow.makeKeyAndOrderFront(nil)
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
        let appleEventReason = QuitReason.appleEventReason(from: NSAppleEventManager.shared().currentAppleEvent)
        let signal = terminationSignal
        terminationSignal = nil
        let powerOffNotified = powerOffNotice.isCurrent()
        let updateInstallPending = appUpdater.isInstallPending
        let reason = QuitReason.classify(
            appleEventReason: appleEventReason,
            powerOffNotified: powerOffNotified,
            updateInstallPending: updateInstallPending,
            terminationSignal: signal)
        let mode = QuitMode.resolve(reason: reason, powerOffNotified: powerOffNotified)
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none"
        AppLog.info(
            "quit: reason=\(reason.rawValue) mode=\(mode.rawValue) "
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
        if preferences.appRules.isEmpty {
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
    /// rate and render scale that came with it.
    private func powerSourceChanged(_ source: PowerSourceMonitor.Source) {
        guard let store, !shutdownInProgress, !shutdownComplete else { return }
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

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // A Dock click returns to the last native section, even after releasing the page.
        showControlPanel(selection: controlPanelNavigation.selection ?? .wallpaper)
        return false
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshStoreSnapshot()
        rebuildMenu(menu)
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard sender === controlPanelWindow else { return frameSize }
        return ControlPanelWindow.clampedFrameSize(frameSize, for: sender)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === controlPanelWindow else { return }
        retryHeldUpdatePrompt()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === whatsNewWindow {
            whatsNewWindow = nil
            window.contentViewController = nil
            leaveDockUnlessAWindowIsOpen()
            retryHeldUpdatePrompt()
            return
        }
        guard window === controlPanelWindow else { return }

        controlPanelWindow = nil
        // Closing releases the panel's controller and its observations; reopening builds a
        // fresh view around the existing stores and navigation.
        window.contentViewController = nil
        leaveDockUnlessAWindowIsOpen()
        rebuildMenu()
    }

    /// Drops to `.accessory` once none of the app's ordinary windows is open
    /// (`ActivationPolicyRule`). A window that is closing still reports itself visible, so
    /// callers forget it first; whatever opens a window raises the policy itself.
    private func leaveDockUnlessAWindowIsOpen() {
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
        if window === whatsNewWindow { return .whatsNew }
        if window === previewWindow?.window { return .preview }
        if WebSignInWindowController.isOpen(window) { return .signIn }
        return nil
    }

    private func startDesktopWallpaperSync() throws {
        guard !shutdownInProgress else { return }
        // Every start comes through here, so with the switch off no poster can be written.
        guard PlaybackPreferences.shared.writesDesktopPicture else { return }
        // A restore the switch started still owns the journal and the posters folder, and its
        // sync is suspended: a second sync would write posters the restore then overwrites.
        // The restore re-runs this through `applyDesktopPicturePreference` when it ends.
        guard restoringDesktopPicture == nil else { return }
        if let sync = desktopWallpaperSync, !sync.isSuspended {
            sync.refresh()
            return
        }
        let sync = try DesktopWallpaperSync(folder: ClientPaths.supportURL.appendingPathComponent("DesktopPosters"),
            scope: { [weak self] display in self?.desktopPosterScope(display) ?? .all },
            retainedDisplays: { [weak self] in self?.retainedSpacePosterDisplays() ?? [] },
            beforeDesktopChange: { [weak self] in self?.desktopSpaces?.refresh() })
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
        sync.refreshesPeriodically = PlaybackPreferences.shared.refreshesDesktopPicturePeriodically
        sync.start()
        sync.refresh()
    }

    /// Makes the desktop picture follow Settings › General › Use the wallpaper as the macOS desktop
    /// picture. On, posters start if they are not running. Off, the user's own picture is put
    /// back with the same verified restore a quit uses, and the poster sync is dropped; a poster
    /// that a crash or an earlier run left behind is found in the journal and put back too.
    /// Idle while the animated lock screen has the desktop: the switch is locked then, and the
    /// native provider journals the poster as its own original.
    private func applyDesktopPicturePreference() {
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
        let folder = ClientPaths.supportURL.appendingPathComponent("DesktopPosters")
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
        guard let row = store.settingsSnapshot.displays.first(where: {
            ResolvedDisplayTitles.liveDisplayID($0.displayId, title: $0.title).map(String.init) == physicalDisplay
        }) else { return WallpaperAutomationStore.shared.configurations.values.contains { $0.mode == .spaces } ? .hold : .all }
        guard row.enabled, row.mode == .standalone,
              WallpaperAutomationStore.shared.configuration(for: row.displayId).mode == .spaces else { return .all }
        guard store.lockScreenWallpaper?.isRequested != true, store.lockScreenWallpaper?.ownsDesktopProvider != true,
              store.activatingWallpaperID == nil, store.applyingWallpaperID == nil,
              automaticWallpapers?.scheduler.selectionIsSettled(on: row.displayId) == true,
              let visit = desktopSpaces?.visit(for: physicalDisplay) else { return .hold }
        let wallpaper = store.monitorInformationSnapshot.rows.first(where: { $0.displayId == row.displayId })?.wallpaperId ?? ""
        return .desktop(id: visit.spaceID, context: "\(visit.token):\(wallpaper):\(store.wallpaperContentRevision)")
    }

    private func retainedSpacePosterDisplays() -> Set<String> {
        guard let store else { return [] }
        return Set(store.settingsSnapshot.displays.compactMap { row in
            guard row.enabled, row.mode == .standalone,
                  WallpaperAutomationStore.shared.configuration(for: row.displayId).mode == .spaces,
                  let physical = ResolvedDisplayTitles.liveDisplayID(row.displayId, title: row.title),
                  automaticWallpapers?.scheduler.inFlight.contains(row.displayId) == true
                    || store.monitorInformationSnapshot.rows.contains(where: { $0.displayId == row.displayId && !$0.wallpaperId.isEmpty }) else { return nil }
            return String(physical)
        })
    }

    /// Apply callbacks run before BridgeStore releases its activation flag. Request scoped
    /// pixels on the next actor turn, after that flag and manual-choice bookkeeping settle.
    private func schedulePosterRefresh() {
        guard posterRefreshTask == nil, !shutdownInProgress, !shutdownComplete else { return }
        posterRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { posterRefreshTask = nil }
            guard !Task.isCancelled, !shutdownInProgress, !shutdownComplete else { return }
            desktopWallpaperSync?.refresh()
        }
    }

    private func installStatusItem() {
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
        item.menu = menu
        rebuildMenu(menu)
    }

    /// Work around an AppKit/SwiftUI timing issue: when launched via
    /// LaunchServices (Finder double-click) in `.accessory` activation
    /// policy, a status item created in `applicationDidFinishLaunching`
    /// may be created correctly but never rendered because the SwiftUI
    /// Scene phase hasn't stabilized yet. Deferring by one runloop turn
    /// gives the Scene phase time to settle. Re-asserting the activation
    /// policy afterwards forces AppKit to re-register accessory-mode
    /// status items with the Window Server; rebuilding the menu alone
    /// only mutates `NSMenu` items and does not touch the status item's
    /// backing window, so it is insufficient by itself.
    private func synchronizeStatusItem() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.statusItem != nil else { return }
            // Re-assert the activation policy to force AppKit to
            // re-register the accessory-mode status item with the
            // Window Server after the SwiftUI Scene phase has settled.
            self.leaveDockUnlessAWindowIsOpen()
            self.rebuildMenu()
        }
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

    private func installApplicationMenu() {
        let menu = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu(title: "WallpaperMachine")
        let settings = menuItem("Settings…", action: #selector(openSettings))
        settings.keyEquivalent = ","
        applicationMenu.addItem(settings)
        applicationMenu.addItem(menuItem("Check for Updates…", action: #selector(checkForUpdates)))
        applicationMenu.addItem(.separator())
        let quit = menuItem("Quit WallpaperMachine", action: #selector(exitApplication))
        quit.keyEquivalent = "q"
        applicationMenu.addItem(quit)
        applicationItem.submenu = applicationMenu
        menu.addItem(applicationItem)

        // Command-W reaches the key window, so the panel hides exactly as its close button does.
        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: String(localized: "File"))
        fileMenu.addItem(
            withTitle: String(localized: "Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu
        menu.addItem(fileItem)

        // Keep standard text editing shortcuts in search and setup fields.
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: String(localized: "Edit"))
        let editCommands: [(String.LocalizationValue, Selector, String)] = [
            ("Undo", Selector(("undo:")), "z"),
            ("Redo", Selector(("redo:")), "Z"),
            ("Cut", #selector(NSText.cut(_:)), "x"),
            ("Copy", #selector(NSText.copy(_:)), "c"),
            ("Paste", #selector(NSText.paste(_:)), "v"),
            ("Select All", #selector(NSText.selectAll(_:)), "a")
        ]
        for (title, action, key) in editCommands {
            editMenu.addItem(withTitle: String(localized: title), action: action, keyEquivalent: key)
        }
        editItem.submenu = editMenu
        menu.addItem(editItem)
        NSApp.mainMenu = menu
    }

    private func rebuildMenu(_ menu: NSMenu? = nil) {
        guard let menu = menu ?? statusItem?.menu else {
            return
        }

        menu.removeAllItems()
        statusMenuItems(for: StatusMenuModel.entries(for: statusMenuInput())).forEach(menu.addItem)

        if let item = updateMenuItem() {
            menu.addItem(.separator())
            menu.addItem(item)
        }

        // A login launch leaves the panel closed, so the menu is where a held wallpaper shows.
        if let store, !store.heldWallpaperIDs.isEmpty {
            menu.addItem(.separator())
            menu.addItem(disabledMenuItem(String(localized: "A wallpaper was held back after a crash")))
        }

        if let error = startupError ?? lastError {
            menu.addItem(.separator())
            menu.addItem(disabledMenuItem(error.localizedDescription))
        }

        menu.addItem(.separator())
        // A second Exit is refused while a quit runs, so say that it is running.
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
    /// offered, since a command on one could not run.
    private func statusMenuInput() -> StatusMenuModel.Input {
        var displays: [StatusMenuModel.Display] = []
        if let store, !shutdownInProgress, !shutdownComplete {
            let screens = WebWallpaperHost.systemScreens()
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
        let downloads = store != nil && !shutdownInProgress && !shutdownComplete
            ? StatusMenuModel.DownloadActivity.make(workshopStore.downloader.inProgressTransfers) : nil
        return StatusMenuModel.Input(
            playbackIsCurrent: playbackSnapshotCurrent,
            hasActiveWallpapers: !(store?.appSnapshot.activeWallpaperIds.isEmpty ?? true),
            paused: store?.appSnapshot.playbackState == .paused,
            wallpapersMuted: PlaybackPreferences.shared.wallpapersMuted,
            downloads: downloads,
            displays: displays, canLockScreen: ScreenLock.isAvailable)
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
        guard let command = sender.representedObject as? StatusMenuModel.Command else { return }
        switch command {
        case .openControlPanel:
            openControlPanel()
        case .openDownloads:
            showDiscover()
        case .playPause:
            togglePlayback()
        case .toggleMute:
            runAutomation(.toggleMute)
        case .previous(let display):
            runAutomation(.previous(display: display))
        case .next(let display):
            guard let store, !shutdownInProgress, !shutdownComplete,
                  canActivateNextWallpaper(store: store, displayId: display)
            else { return }
            runAutomation(.next(display: display))
        case .random(let display):
            runAutomation(.random(display: display, pool: .all))
        case .apply(let id, let display), .startAgain(let id, let display):
            runAutomation(.apply(wallpaperID: id, display: display))
        case .remove(let display):
            runAutomation(.removeWallpaper(display: display))
        case .openInPanel(let display):
            // The panel's own target check, since the display may have changed since the menu opened.
            if let store, store.settingsSnapshot.displays.contains(where: {
                $0.displayId == display && $0.enabled && $0.mode == .standalone
            }) {
                controlPanelNavigation.targetDisplayID = display
            }
            showControlPanel(selection: .wallpaper)
        case .lockScreen:
            lockScreen()
        }
    }

    @objc private func openControlPanel() {
        showControlPanel(selection: .wallpaper)
    }

    /// Discover, which lists the downloads; a first visit starts its search, as the link to it does.
    private func showDiscover() {
        if !workshopStore.hasLoaded && !workshopStore.isLoading { workshopStore.search() }
        showControlPanel(selection: .workshop)
    }

    @objc func openSettings() {
        showControlPanel(selection: .settings)
    }

    @objc func checkForUpdates() {
        controlPanelNavigation.revealSettingsSection(.about)
        showControlPanel(selection: .settings)
        Task { _ = await appUpdater.checkForUpdates() }
    }

    /// Checks at launch and every six hours after, because a menu-bar app can run for weeks
    /// without relaunching. `Task.sleep` follows the continuous clock, so a Mac that slept
    /// through the interval checks as soon as it wakes.
    private func startAutomaticUpdates() {
        guard automaticUpdates == nil else { return }
        automaticUpdates = Task { [weak self] in
            while !Task.isCancelled {
                await self?.runAutomaticUpdate()
                try? await Task.sleep(for: .seconds(6 * 60 * 60))
            }
        }
    }

    /// Asks the Workshop about installed items at most once a day, unless turned off; the
    /// automatic update loop calls this too, since the app can run for weeks.
    private func checkWorkshopUpdatesIfDue() {
        guard let store, !shutdownInProgress, !shutdownComplete, playbackSnapshotCurrent else { return }
        workshopStore.updates.checkIfDue(
            installed: store.librarySnapshot.wallpapers.map(\.id), library: ClientPaths.libraryURL)
    }

    private func runAutomaticUpdate() async {
        checkWorkshopUpdatesIfDue()
        let state = await appUpdater.checkInBackground()
        rebuildMenu()
        offerUpdateIfNeeded(state)
    }

    /// Offers the update in `state` once per version, but only when `UpdatePromptGate` says an
    /// alert would not interrupt (not over a full-screen app, a locked screen or a sleeping
    /// display). A held prompt is not marked offered; `retryHeldUpdatePrompt` asks again
    /// without a network check when one of the gate's inputs changes.
    private func offerUpdateIfNeeded(_ state: AppUpdateState) {
        let version: String?
        switch state {
        case .ready(_, let ready): version = ready
        case .available(_, let available), .manual(_, let available): version = available
        default: version = nil
        }
        switch updatePrompts.offer(version: version, input: updatePromptInput()) {
        case .none:
            return
        case .held(let reason, let isNew):
            if isNew { AppLog.info("update prompt deferred: \(reason.rawValue)") }
        case .present(let version):
            if case .ready = state {
                promptUpdate(
                    title: String(localized: "WallpaperMachine \(version) is ready to install"),
                    detail: String(localized: "It has been downloaded. WallpaperMachine quits and reopens to finish installing it."),
                    confirm: String(localized: "Restart to Update"),
                    confirmed: installDownloadedUpdate)
            } else {
                promptUpdate(
                    title: String(localized: "WallpaperMachine \(version) is available"),
                    detail: String(localized: "See what's new and download it in Settings."),
                    confirm: String(localized: "View Update"),
                    confirmed: showUpdate)
            }
        }
    }

    private func updatePromptInput() -> UpdatePromptGate.Input {
        UpdatePromptGate.Input(
            panelVisibleAndActive: controlPanelWindow.map { $0.isVisible && $0.isKeyWindow } ?? false,
            globalPresentation: presentationPolicy?.globalPresentation ?? .running,
            hasSuspendedDisplay: presentationPolicy?.hiddenDisplayIDs.isEmpty == false,
            whatsNewOpen: whatsNewWindow != nil,
            shuttingDown: shutdownInProgress || shutdownComplete)
    }

    /// Asks again for a prompt the gate held, with the update state the app already has.
    private func retryHeldUpdatePrompt() {
        guard updatePrompts.holdReason != nil else { return }
        offerUpdateIfNeeded(appUpdater.state)
    }

    /// Shown from the main run loop, not this task: a modal run inside a main-actor task would
    /// stall every other main-actor task until the alert closes.
    private func promptUpdate(title: String, detail: String, confirm: String, confirmed: @escaping () -> Void) {
        AppUpdateStore.performOnMainRunLoop { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.shutdownInProgress, !self.shutdownComplete else { return }
                let alert = NSAlert()
                alert.messageText = title
                alert.informativeText = detail
                alert.addButton(withTitle: confirm)
                alert.addButton(withTitle: String(localized: "Later"))
                NSApp.activate(ignoringOtherApps: true)
                guard alert.runModal() == .alertFirstButtonReturn, !self.shutdownInProgress else { return }
                confirmed()
            }
        }
    }

    /// An error alert, shown from the main run loop for the reason `promptUpdate` gives; the
    /// callers run inside main-actor tasks and main-queue jobs.
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

    /// "Later" leaves the update one click away in the status menu.
    private func updateMenuItem() -> NSMenuItem? {
        switch appUpdater.state {
        case .ready(_, let version):
            return menuItem("Restart to Update to \(version)", action: #selector(installDownloadedUpdate))
        case .available(_, let version), .manual(_, let version):
            return menuItem("WallpaperMachine \(version) Available…", action: #selector(showUpdate))
        default:
            return nil
        }
    }

    @objc private func installDownloadedUpdate() {
        Task {
            await appUpdater.installUpdate()
            // A failed install explains itself, and offers GitHub Releases, in About.
            if case .error = appUpdater.state { showUpdate() }
        }
    }

    @objc private func showUpdate() {
        controlPanelNavigation.revealSettingsSection(.about)
        showControlPanel(selection: .settings)
    }

    private func showWhatsNewAfterUpdate() {
        guard !shutdownInProgress, whatsNewWindow == nil else { return }
        do {
            let history = try AppReleaseHistory()
            guard let announcement = whatsNewStore.announcement(
                history: history, existingUser: PanelPreferences.welcomeSeen()
            ) else { return }
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: WhatsNewViewController.defaultContentSize),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false)
            window.title = String(localized: "What’s New")
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentViewController = WhatsNewViewController(
                announcement: announcement, preferences: whatsNewStore,
                initialLanguage: AppLanguageStore.shared.effective,
                close: { [weak window] in window?.performClose(nil) })
            window.contentMinSize = NSSize(width: 600, height: 480)
            // Installing a controller can resize the window to its content view's fitting size.
            window.setContentSize(WhatsNewViewController.defaultContentSize)
            window.center()
            ControlPanelWindow.moveToActiveSpace(window)
            whatsNewWindow = window
            NSApp.setActivationPolicy(.regular)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            whatsNewStore.didPresent(announcement)
        } catch {
            AppLog.error("Bundled release history could not load: \(error.localizedDescription)")
        }
    }

    private func showControlPanel(selection: SidebarSelection) {
        controlPanelNavigation.selection = selection
        NSApp.setActivationPolicy(.regular)

        if let controlPanelWindow {
            ControlPanelWindow.constrainToScreen(controlPanelWindow)
            ControlPanelWindow.bringForward(controlPanelWindow)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let controller: NSHostingController<AnyView>
        if let store {
            controller = NSHostingController(
                rootView: AnyView(
                    ControlPanelView(
                        store: store,
                        navigation: controlPanelNavigation,
                        workshop: workshopStore,
                        pixiv: pixivStore,
                        updater: appUpdater,
                        imports: libraryImports
                    )
                )
            )
        } else {
            controller = NSHostingController(
                rootView: AnyView(BridgeUnavailableView(error: startupError ?? lastError))
            )
        }

        // AppKit owns this resizable window's bounds; content must accept its proposal
        // instead of promoting a long label or a split pane's ideal width to a window minimum.
        // The hosted view's `.toolbar` and `.navigationTitle` drive the window's own.
        controller.sizingOptions = []
        controller.sceneBridgingOptions = [.toolbars, .title]
        let window = ControlPanelWindow.make(contentViewController: controller, delegate: self)
        let frameName = ControlPanelWindow.frameAutosaveName
        if !window.setFrameUsingName(frameName) { window.center() }
        ControlPanelWindow.constrainToScreen(window)
        window.setFrameAutosaveName(frameName)

        controlPanelWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func togglePlayback() {
        guard let store,
              !shutdownInProgress,
              !shutdownComplete,
              playbackSnapshotCurrent,
              !store.appSnapshot.activeWallpaperIds.isEmpty
        else {
            return
        }

        Task {
            do {
                if store.appSnapshot.playbackState == .paused {
                    try await store.playAllAsync()
                } else {
                    try await store.pauseAllAsync()
                }
                lastError = nil
                playbackSnapshotCurrent = true
                rebuildMenu()
            } catch {
                lastError = error
                playbackSnapshotCurrent = false
                rebuildMenu()
                presentErrorAlert(error)
            }
        }
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

    private func canActivateNextWallpaper(store: BridgeStore, displayId: String) -> Bool {
        if PlaylistStore.shared.playlist(for: displayId).mode == .rotate {
            return playlistScheduler?.canSkip(displayId) ?? false
        }
        return store.nextWallpaperID(displayId: displayId) != nil
    }

    /// Runs a command from a link, a keyboard shortcut or the menu bar. A failure shows in the
    /// menu bar menu, as one from the menu itself does.
    private func runAutomation(_ command: AutomationCommand) {
        Task {
            do {
                try await AppAutomation.shared.perform(command)
                lastError = nil
            } catch {
                lastError = error
                AppLog.warn("\(String(describing: command)) failed: \(error.localizedDescription)")
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
            try await store.commands.run {
                let paused = store.appSnapshot.playbackState == .paused
                let play = command == .play || (command == .togglePlayback && paused)
                if play, paused {
                    try await store.playAllAsync()
                } else if !play, !paused {
                    try await store.pauseAllAsync()
                }
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
                favorites: Self.favoriteWallpaperIDs(), playlists: .shared)
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
                                         connected: Set(WebWallpaperHost.systemScreens().map(\.id)))
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

    @objc private func lockScreen() {
        ScreenLock.lock()
    }

    @objc private func exitApplication() {
        NSApp.terminate(nil)
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
            startAutomaticUpdates()
        }
    }

    private func refreshStoreSnapshot() {
        guard let store,
              !shutdownInProgress,
              !shutdownComplete
        else {
            return
        }

        Task {
            do {
                try await store.refreshAllAsync()
                lastError = nil
                playbackSnapshotCurrent = true
            } catch {
                lastError = error
                playbackSnapshotCurrent = false
            }
            rebuildMenu()
        }
    }

    /// Whether the bridge took the refresh.
    private func refreshDisplaysFromSystemEvent() async -> Bool {
        guard let store,
              !shutdownInProgress,
              !shutdownComplete
        else {
            return false
        }

        let refreshed: Bool
        do {
            try await store.refreshDisplaysAsync()
            lastError = nil
            playbackSnapshotCurrent = true
            refreshed = true
        } catch {
            lastError = error
            playbackSnapshotCurrent = false
            refreshed = false
        }
        rebuildMenu()
        return refreshed
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
    /// A window that was closed is no longer ordered in, so it is not listed.
    private static func wallpaperLayers(on displayID: UInt32) -> [CALayer] {
        WallpaperPresentationPolicy.orderedWallpaperWindows().compactMap { window in
            guard window.isVisible, let screen = window.screen,
                  SystemDesktopPictureWorkspace.id(screen) == String(displayID) else { return nil }
            return window.contentView?.layer
        }
    }

}

private struct BridgeUnavailableView: View {
    let error: Error?

    var body: some View {
        ContentUnavailableView(
            "Bridge Unavailable",
            systemImage: "exclamationmark.triangle",
            description: Text(error?.localizedDescription ?? String(localized: "The rendering bridge could not be started."))
        )
        .frame(minWidth: 640, minHeight: 420)
    }
}
