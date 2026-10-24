import AppKit
import WebKit

/// What the web host needs from the staged user-asset store: enough to put the
/// user's own files where a page is allowed to read them, and to hear about a
/// watched directory changing. `UserAssetStore` is the production
/// implementation; a test substitutes its own.
@MainActor
protocol WebWallpaperAssetSource: AnyObject {
    var onDirectoryChanged: ((String, [UserAssetImport], [UserAssetImport]) -> Void)? { get set }
    func importFile(at url: URL, propertyId: String, filter: UserAssetFilter) async throws -> UserAssetImport
    func importDirectory(at url: URL, propertyId: String, filter: UserAssetFilter, limit: Int) async throws -> [UserAssetImport]
    func randomFile(propertyId: String) -> UserAssetImport?
    func isTruncated(propertyId: String) -> Bool
    func clear(propertyId: String) async throws
    func cancelImport(propertyId: String)
    func cancelImports()
}

extension UserAssetStore: WebWallpaperAssetSource {}

/// Keeps one desktop web view per display in step with the bridge's committed
/// web wallpapers. The renderer owns assignment, persistence and playback
/// state; this host only mirrors `webWallpapers()` into windows, pushes
/// property values into the pages, and answers desktop-poster requests.
@MainActor
final class WebWallpaperHost {
    private let fetch: @MainActor () async throws -> [BridgeWebWallpaper]
    private let screens: @MainActor () -> [(id: UInt32, frame: NSRect)]
    private let refreshRate: @MainActor (UInt32) -> Int
    private let frameCenter: NotificationCenter
    private let imagePlacement: StillImagePlacementStore
    private var windows: [UInt32: any WebWallpaperSurface] = [:]
    private let makeSurface: @MainActor (NSRect, WebWallpaperPage) -> any WebWallpaperSurface
    private let pointerMonitorOverride: (any WebWallpaperPointerMonitoring)?
    private let pageTiming: WebWallpaperPage.Timing
    private lazy var mouse: any WebWallpaperPointerMonitoring = pointerMonitorOverride ?? WebWallpaperMouseForwarder { [weak self] in
        self?.windows.values.compactMap { $0 as? WebWallpaperWindow } ?? []
    }
    private var descriptors: [UInt32: BridgeWebWallpaper] = [:]
    private var posterObserver: NSObjectProtocol?
    private var inspectionObserver: NSObjectProtocol?
    /// Whether pages may be attached to Safari's Web Inspector, read when a page
    /// is made and again whenever the preference changes.
    private let inspectionEnabled: @MainActor () -> Bool
    private var imagePlacementObserver: NSObjectProtocol?
    private var placementDirtyDisplays = Set<UInt32>()
    private var reconcileInFlight = false
    private var reconcileRequested = false
    private var applyGeneration: UInt64 = 0
    private var suspended = false
    /// Displays suspended on their own, kept apart from the global flag so one
    /// occluded screen cannot suspend a page on a visible screen.
    private var suspendedDisplays: Set<UInt32> = []
    /// The part of `suspendedDisplays` the user can still see: paused only because
    /// they are working on another display, not covered, asleep or behind a
    /// full-screen app. A page on such a display is given its first frame before it
    /// is detached, including one created after the display was suspended.
    private var suspendedInPlainSight: Set<UInt32> = []
    private var stopped = false
    private let counters: RuntimeCounters
    /// Keeps the picture of the wallpaper a switch replaces on screen until the new page has
    /// loaded and painted. `nil` for a host that never holds one, as in most of the tests.
    private let switchHold: WallpaperSwitchHold?
    /// How long after a page reports it has loaded the held picture stays. `didFinish` comes
    /// before the first meaningful paint (see `scheduleSurfaceChange`, which reads the poster
    /// again two seconds later), so taking the picture away at once could show the empty page.
    /// A fade over a page that has painted anyway hides what is left of the lag.
    static let firstPaintSettle = Duration.milliseconds(500)
    /// Distinguishes surfaces that reused one display id across a wallpaper
    /// switch, so their counters are not merged.
    private var surfaceGeneration: UInt64 = 0
    /// Surfaced to the app the same way renderer failures are.
    var onError: (@MainActor (String) -> Void)?
    /// Fired after windows open, close, or finish loading their page, so the
    /// presentation policy and the desktop poster sync re-read the desktop.
    var onSurfacesChanged: (@MainActor () -> Void)?
    var onStateChanged: (@MainActor (HostWallpaperState) -> Void)?
    private var states: [UInt32: HostWallpaperState] = [:]
    /// The wallpapers each display may keep paused for a desktop the person left
    /// (`WallpaperSpaceParking`), by display.
    private var keepPlan: [UInt32: Set<String>] = [:]
    /// A page a display keeps suspended in its own window for a desktop the person left, so it
    /// runs on from there when that desktop comes back instead of loading again.
    private struct KeptPage {
        let window: any WebWallpaperSurface
        let descriptor: BridgeWebWallpaper
        let projectRevision: String
    }
    private var kept: [UInt32: [String: KeptPage]] = [:]
    private var surfaceChangePending = false
    /// One pump for every display: the audio analysis is process-global.
    private let audioPump: WebWallpaperAudioPump
    private let setAudioSubscribed: @MainActor (_ wallpaperId: String, _ displayId: UInt32, _ subscribed: Bool) async throws -> Void
    /// Subscription changes are chained rather than fired in parallel, so two
    /// rapid transitions cannot land out of order and leave the tap open.
    private var audioSubscriptionTask: Task<Void, Never>?
    private var audioSubscriptions: [UInt32: Bool] = [:]
    private var audioSubscriptionTokens: [UInt32: UUID] = [:]
    private var confirmedAudioDisplays = Set<UInt32>()
    private var failedAudioDisplays = Set<UInt32>()
    private var audioDeliveredAt: [UInt32: TimeInterval] = [:]
    private var audioExpiryTask: Task<Void, Never>?
    private let audioClock: @MainActor () -> TimeInterval
    private let contentRevision: @MainActor () -> UInt64
    private let projectRevisions = WallpaperProjectRevision()
    private var loadedProjectRevisions: [UInt32: String] = [:]
    var onAssetsChanged: (@MainActor () -> Void)?
    var onDeliveryStateChanged: (@MainActor () -> Void)?
    static let audioDeliveryLifetime: TimeInterval = 2
    private let mediaRelay: WebWallpaperMediaRelay
    /// Held, not derived from a temporary. `ObjectIdentifier` is an address,
    /// and an address freed the moment it was taken can be handed to the next
    /// allocation — which would let two listeners share one key in a shared
    /// relay and silently overwrite or remove each other.
    private let mediaListenerToken = MediaListenerKey()
    private var mediaListenerKey: ObjectIdentifier { ObjectIdentifier(mediaListenerToken) }
    private final class MediaListenerKey {}
    /// Pages currently able to receive media events, which is not the same as
    /// the pages consuming the provider: a page whose user turned integration
    /// off still has to be told so.
    private var mediaListeners: Set<ObjectIdentifier> = []
    /// Built per project, and keyed on the stable wallpaper id so the managed store
    /// survives the project being deleted and downloaded again.
    private let makeAssetStore: (@MainActor (URL, String) -> any WebWallpaperAssetSource)?
    private var assetStores: [String: any WebWallpaperAssetSource] = [:]
    private var assetOwners: [String: String] = [:]
    private var assetRequests: [String: [String: UUID]] = [:]
    private var invalidatedAssets: [String: Set<String>] = [:]
    /// What each `file`/`directory` property was last staged from, so a
    /// reconcile that changed nothing does not re-link a whole directory.
    private var stagedAssets: [String: [String: StagedAsset]] = [:]
    /// Current staged contents of each watched directory, so a new document can
    /// be handed the whole `fetchall` set it missed.
    private var directoryFiles: [String: [String: [String]]] = [:]
    private var fetchAllProperties: [String: Set<String>] = [:]

    private struct StagedAsset {
        var source: String
        var pageValue: String
    }

    init(
        fetch: @escaping @MainActor () async throws -> [BridgeWebWallpaper],
        screens: (@MainActor () -> [(id: UInt32, frame: NSRect)])? = nil,
        refreshRate: (@MainActor (UInt32) -> Int)? = nil,
        frameCenter: NotificationCenter = .default,
        counters: RuntimeCounters? = nil,
        audioPump: WebWallpaperAudioPump? = nil,
        setAudioSubscribed: (@MainActor (String, UInt32, Bool) async throws -> Void)? = nil,
        mediaRelay: WebWallpaperMediaRelay? = nil,
        mediaProvider: (any SystemMediaProvider)? = nil,
        assetStore: (@MainActor (URL, String) -> any WebWallpaperAssetSource)? = nil,
        imagePlacement: StillImagePlacementStore? = nil,
        pointerMonitor: (any WebWallpaperPointerMonitoring)? = nil,
        pageTiming: WebWallpaperPage.Timing = .init(),
        inspectionEnabled: @escaping @MainActor () -> Bool = { WebWallpaperInspection.isEnabled() },
        audioClock: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        contentRevision: @escaping @MainActor () -> UInt64 = { 0 },
        switchHold: WallpaperSwitchHold? = nil,
        makeSurface: @escaping @MainActor (NSRect, WebWallpaperPage) -> any WebWallpaperSurface = {
            WebWallpaperWindow(frame: $0, page: $1)
        }
    ) {
        self.fetch = fetch
        self.switchHold = switchHold
        self.makeSurface = makeSurface
        self.pointerMonitorOverride = pointerMonitor
        self.pageTiming = pageTiming
        self.inspectionEnabled = inspectionEnabled
        self.audioClock = audioClock
        self.contentRevision = contentRevision
        self.screens = screens ?? { Self.systemScreens() }
        self.refreshRate = refreshRate ?? { Self.systemRefreshRate(displayID: $0) }
        self.frameCenter = frameCenter
        self.counters = counters ?? .shared
        self.audioPump = audioPump ?? WebWallpaperAudioPump(read: { nil })
        self.setAudioSubscribed = setAudioSubscribed ?? { _, _, _ in }
        self.mediaRelay = mediaRelay ?? WebWallpaperMediaRelay(provider: mediaProvider ?? UnavailableSystemMediaProvider())
        self.makeAssetStore = assetStore
        self.imagePlacement = imagePlacement ?? .shared
        self.audioPump.onSpectrum = { [weak self] spectrum in self?.broadcast(spectrum) }
        if mediaRelay != nil {
            self.mediaRelay.addListener(mediaListenerKey) { [weak self] event in self?.broadcast(event) }
        } else {
            self.mediaRelay.onChange = { [weak self] event in self?.broadcast(event) }
        }
    }

    convenience init(bridge: WallpaperBridge, mediaRelay: WebWallpaperMediaRelay? = nil,
                     contentRevision: @escaping @MainActor () -> UInt64 = { 0 },
                     switchHold: WallpaperSwitchHold? = nil) {
        self.init(
            fetch: { try await bridge.webWallpapers() },
            audioPump: WebWallpaperAudioPump(read: { try bridge.webAudioSpectrum() }),
            setAudioSubscribed: { wallpaperId, displayId, subscribed in
                try await bridge.setWebAudioSubscribed(
                    wallpaperId: wallpaperId, displayId: displayId, subscribed: subscribed)
            },
            mediaRelay: mediaRelay,
            mediaProvider: mediaRelay == nil ? AdapterSystemMediaProvider() : nil,
            assetStore: { UserAssetStore(projectURL: $0, wallpaperId: $1) }, contentRevision: contentRevision,
            switchHold: switchHold)
    }

    static func systemScreens() -> [(id: UInt32, frame: NSRect)] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return (number.uint32Value, screen.frame)
        }
    }

    static func systemRefreshRate(displayID: UInt32) -> Int {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }?.maximumFramesPerSecond ?? 0
    }

    /// WebKit offers a page two cadences: near 60 fps, or the display's full
    /// refresh. The wallpaper's frame rate is a ceiling, so the full refresh is
    /// used only when that rate already reaches it; a display at 60 Hz or below
    /// is drawn at its refresh either way.
    nonisolated static func rendersAtDisplayRefresh(fps: UInt32, refreshRate: Int) -> Bool {
        refreshRate > 60 && Int(fps) >= refreshRate
    }

    var activeDisplayIDs: Set<UInt32> { Set(windows.keys) }
    /// True while a loaded, unsuspended page can use pointer events. A window
    /// that exists but is host-suspended installs no global monitor.
    var isPointerMonitorActive: Bool { mouse.isActive }
    var isEmpty: Bool { windows.isEmpty }

    /// Displays whose page has actually registered an audio listener and is
    /// being fed. This is not the user's setting: a wallpaper that never calls
    /// `wallpaperRegisterAudioListener` reacts to nothing however the setting
    /// is left, and the control panel has to be able to say which it is.
    var audioSubscribedDisplayIDs: Set<UInt32> {
        confirmedAudioDisplays
    }

    /// Whether a system media provider can supply anything at all, and why not
    /// when it cannot. Distinct again from the user's setting.
    var systemMediaAvailability: SystemMediaAvailability { mediaRelay.availability }

    /// What the control panel needs to tell the user apart: their setting, and
    /// whether anything is actually being delivered. A wallpaper that never
    /// calls the register function reacts to nothing however the setting is
    /// left, and a system with no readable media source supplies nothing
    /// however the toggle is set.
    struct DeliveryStatus: Equatable, Sendable {
        var audioSubscribedDisplayIDs: Set<UInt32> = []
        var audioStates: [String: AudioDeliveryState] = [:]
        var audioOutputControls: [String: WebWallpaperAudioOutput.Capabilities] = [:]
        /// Nil when a provider can supply media; otherwise why it cannot.
        var mediaUnavailableReason: String?
    }

    enum AudioDeliveryState: String, Sendable {
        case idle, failed, connecting, subscribed, delivering
        var priority: Int {
            switch self { case .idle: 0; case .failed: 1; case .connecting: 2; case .subscribed: 3; case .delivering: 4 }
        }
    }

    private var audioStates: [String: AudioDeliveryState] {
        var result: [String: AudioDeliveryState] = [:]
        for (displayID, wallpaper) in descriptors {
            let state: AudioDeliveryState
            if let delivered = audioDeliveredAt[displayID], audioClock() - delivered < Self.audioDeliveryLifetime {
                state = .delivering
            } else if confirmedAudioDisplays.contains(displayID) { state = .subscribed }
            else if failedAudioDisplays.contains(displayID) { state = .failed }
            else if audioSubscriptions[displayID] == true { state = .connecting }
            else { state = .idle }
            if result[wallpaper.wallpaperId].map({ $0.priority < state.priority }) ?? true {
                result[wallpaper.wallpaperId] = state
            }
        }
        return result
    }

    var deliveryStatus: DeliveryStatus {
        DeliveryStatus(
            audioSubscribedDisplayIDs: audioSubscribedDisplayIDs,
            audioStates: audioStates,
            audioOutputControls: audioOutputControls,
            mediaUnavailableReason: {
                switch systemMediaAvailability {
                case .available: nil
                case let .unavailable(reason): reason
                }
            }())
    }

    private var audioOutputControls: [String: WebWallpaperAudioOutput.Capabilities] {
        var controls: [String: WebWallpaperAudioOutput.Capabilities] = [:]
        for (displayID, window) in windows {
            guard let wallpaper = descriptors[displayID], let value = window.page.audioOutputCapabilities else { continue }
            if let previous = controls[wallpaper.wallpaperId] {
                controls[wallpaper.wallpaperId] = .init(
                    mediaVolume: previous.mediaVolume && value.mediaVolume,
                    pageMute: previous.pageMute && value.pageMute)
            } else {
                controls[wallpaper.wallpaperId] = value
            }
        }
        return controls
    }

    func start() {
        guard posterObserver == nil else { return }
        posterObserver = frameCenter.addObserver(
            forName: DesktopPosterNotification.request, object: nil, queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated { self?.answerPosterRequest(notification) }
        }
        stopped = false
        // The center is the one that carries poster requests, so a test that
        // injects it also owns what reaches the host.
        inspectionObserver = frameCenter.addObserver(
            forName: WebWallpaperInspection.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyInspection() }
        }
        imagePlacementObserver = NotificationCenter.default.addObserver(
            forName: StillImagePlacementStore.didChangeNotification, object: imagePlacement, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard note.userInfo?["metadataOnly"] as? Bool != true,
                    let wallpaperID = note.userInfo?["wallpaperID"] as? String
                else { return }
                self?.refreshImagePlacement(
                    wallpaperID: wallpaperID, displayKey: note.userInfo?["displayID"] as? String,
                    reloadUpgradedPage: note.userInfo?["pageUpgraded"] as? Bool == true)
            }
        }
    }

    /// Re-reads the committed web wallpapers and diffs them against open windows.
    /// Overlapping calls coalesce into one trailing pass.
    ///
    /// A descriptor's `paused` is the bridge's composed flag (Play/Pause, battery
    /// Pause, presentation and per-display suspension), and the page is held still
    /// by what was last read. Presentation and power-source changes return no
    /// snapshot, so whoever applies them calls this once the bridge has committed.
    func reconcile() {
        guard !stopped else { return }
        guard !reconcileInFlight else {
            reconcileRequested = true
            return
        }
        reconcileInFlight = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.reconcileInFlight = false
                if self.reconcileRequested {
                    self.reconcileRequested = false
                    self.reconcile()
                }
            }
            do {
                let wallpapers = try await self.fetch()
                for wallpaper in wallpapers
                where self.windows[wallpaper.displayId] == nil
                    || self.descriptors[wallpaper.displayId]?.wallpaperId != wallpaper.wallpaperId {
                    do { _ = try await self.imagePlacement.prepare(wallpaperID: wallpaper.wallpaperId) }
                    catch {
                        AppLog.error("image wallpaper preparation failed: \(error.localizedDescription)")
                        self.onError?(error.localizedDescription)
                    }
                }
                guard !self.reconcileRequested else { return }
                guard !self.stopped else { return }
                await self.apply(wallpapers)
            } catch {
                AppLog.error("web wallpapers could not be read: \(error.localizedDescription)")
                self.onError?(error.localizedDescription)
            }
        }
    }

    /// The windows of the pages kept suspended for other desktops.
    var keptWindowNumbers: Set<Int> { Set(kept.values.flatMap(\.values).map(\.window.windowNumber)) }

    /// The wallpapers the display keeps suspended for its other desktops.
    func keptWallpapers(on displayID: UInt32) -> Set<String> { Set((kept[displayID] ?? [:]).keys) }

    /// The wallpaper each of this host's windows shows, live and kept, by window number.
    var windowWallpapers: [Int: String] {
        var wallpapers: [Int: String] = [:]
        for (displayID, window) in windows {
            if let wallpaper = descriptors[displayID]?.wallpaperId { wallpapers[window.windowNumber] = wallpaper }
        }
        for pages in kept.values {
            for (wallpaper, page) in pages { wallpapers[page.window.windowNumber] = wallpaper }
        }
        return wallpapers
    }

    /// Sets which wallpapers each display may keep suspended for a desktop the person left, and
    /// closes the kept pages the plan no longer names.
    func setKeptWallpapers(_ plan: [UInt32: Set<String>]) {
        keepPlan = plan
        releaseKeptPages()
    }

    func apply(_ wallpapers: [BridgeWebWallpaper]) async {
        applyGeneration &+= 1
        let generation = applyGeneration
        releaseKeptPages()
        let screens = Dictionary(screens().map { ($0.id, $0.frame) }, uniquingKeysWith: { first, _ in first })
        var next: [UInt32: BridgeWebWallpaper] = [:]
        for wallpaper in wallpapers where screens[wallpaper.displayId] != nil {
            next[wallpaper.displayId] = wallpaper
        }
        for (displayID, var state) in states where next[displayID] == nil {
            state.phase = .closed
            onStateChanged?(state)
            states.removeValue(forKey: displayID)
        }
        var changed = false
        for (displayID, window) in windows where next[displayID] == nil {
            if !keep(window, displayID: displayID) { closeVacated(window, displayID: displayID) }
            changed = true
        }
        for (displayID, wallpaper) in next {
            guard let frame = screens[displayID] else { continue }
            let projectURL = URL(fileURLWithPath: wallpaper.projectPath, isDirectory: true)
            // Identity is the resolved entry path, not its last component: a
            // nested entry compared by file name alone never matches itself, so
            // every reconcile would discard a working page and build a new one.
            guard let canonicalEntry = WebWallpaperProtocol.canonicalEntryURL(
                projectURL: projectURL, entryFile: wallpaper.entryFile) else {
                AppLog.error("""
                    web wallpaper \(wallpaper.wallpaperId): entry file \(wallpaper.entryFile) \
                    resolves outside its project folder
                    """)
                onError?(String(localized: "Web wallpaper “\(wallpaper.title)” could not load: its entry file is outside the project folder."))
                if let window = windows[displayID] {
                    closeVacated(window, displayID: displayID)
                    changed = true
                }
                recordState(wallpaper, phase: .failed,
                    message: String(localized: "The wallpaper entry file is outside its project folder."))
                continue
            }
            let projectRevision: String
            do {
                projectRevision = try await projectRevisions.fingerprint(projectURL, revision: contentRevision())
            } catch {
                guard !stopped, generation == applyGeneration else { return }
                recordState(wallpaper, phase: .failed, message: error.localizedDescription)
                onError?(error.localizedDescription)
                continue
            }
            guard !stopped, generation == applyGeneration else { return }
            let displayRefreshRate = refreshRate(displayID)
            // Fixed when the web view is created, so a frame rate that crosses
            // the display's refresh rebuilds the page.
            let rendersAtDisplayRefresh = Self.rendersAtDisplayRefresh(
                fps: wallpaper.fps, refreshRate: displayRefreshRate)
            if let window = windows[displayID], window.page.canonicalEntryURL == canonicalEntry,
               loadedProjectRevisions[displayID] == projectRevision,
               window.page.rendersAtDisplayRefresh == rendersAtDisplayRefresh {
                if window.frame != frame {
                    window.setScreenFrame(frame)
                    changed = true
                }
                window.page.applyDisplayRefreshRate(displayRefreshRate)
                await push(wallpaper, into: window.page, previous: descriptors[displayID])
                guard !stopped, generation == applyGeneration else { return }
            } else if let page = kept[displayID]?[wallpaper.wallpaperId], page.window.page.canonicalEntryURL == canonicalEntry,
                      page.projectRevision == projectRevision,
                      page.window.page.rendersAtDisplayRefresh == rendersAtDisplayRefresh {
                // The page the display kept for this wallpaper runs on: no load, no new window.
                if let window = windows[displayID], !keep(window, displayID: displayID) { close(window) }
                kept[displayID]?[wallpaper.wallpaperId] = nil
                if kept[displayID]?.isEmpty == true { kept[displayID] = nil }
                windows[displayID] = page.window
                loadedProjectRevisions[displayID] = projectRevision
                if page.window.frame != frame { page.window.setScreenFrame(frame) }
                page.window.page.applyDisplayRefreshRate(displayRefreshRate)
                await push(wallpaper, into: page.window.page, previous: page.descriptor)
                guard !stopped, generation == applyGeneration else { return }
                AppLog.info("web wallpaper \(wallpaper.wallpaperId) runs again on display \(displayID) without a load",
                            load: page.window.page.logLoad)
                changed = true
            } else {
                if let window = windows[displayID], !keep(window, displayID: displayID) { close(window) }
                surfaceGeneration += 1
                let surface = RuntimeSurfaceKey(
                    kind: .desktopWeb, displayID: displayID, generation: surfaceGeneration)
                let page = WebWallpaperPage(
                    projectURL: projectURL, entryFile: wallpaper.entryFile,
                    surface: surface, counters: counters, inspectable: inspectionEnabled(),
                    rendersAtDisplayRefresh: rendersAtDisplayRefresh, timing: pageTiming)
                let load = AppLog.beginLoad("web", project: wallpaper.projectPath, detail: """
                    wallpaper \(wallpaper.wallpaperId) “\(wallpaper.title)” entry \(wallpaper.entryFile), \
                    \(DiagnosticEnvironment.display(displayID)), fps \(wallpaper.fps)\
                    \(rendersAtDisplayRefresh ? " at display refresh" : ""), \
                    render scale \(wallpaper.renderScale), paused \(wallpaper.paused)
                    """)
                page.logLoad = load
                counters.record(.webPageCreated, for: surface)
                page.onLoading = { [weak self, weak page] in
                    guard let self, let page, self.windows[displayID]?.page === page,
                          let current = self.descriptors[displayID] else { return }
                    self.recordState(current, phase: .loading)
                }
                page.onFailure = { [weak self, weak page] message in
                    guard let self, let page, self.windows[displayID]?.page === page,
                          let current = self.descriptors[displayID] else { return }
                    AppLog.error("web wallpaper \(wallpaper.wallpaperId) on display \(displayID): \(message)", load: load)
                    self.recordState(current, phase: .failed, message: message, canRetry: true)
                    self.onError?(String(localized: "Web wallpaper “\(wallpaper.title)” could not load: \(message)"))
                    // Nothing is coming to replace the held picture with: the failed page, and
                    // the retry that is offered, belong on screen and not behind it.
                    self.switchHold?.contentReady(displayID: displayID)
                }
                page.onLoaded = { [weak self, weak page] in
                    guard let self, let page, self.windows[displayID]?.page === page,
                          let current = self.descriptors[displayID] else { return }
                    self.recordState(current, phase: .ready)
                    self.switchHold?.contentReady(displayID: displayID, after: Self.firstPaintSettle)
                    self.replayDirectories(displayID: displayID)
                    self.scheduleSurfaceChange()
                    self.refreshAudioOutputs()
                    self.refreshPointerMonitor()
                }
                // The first-frame grace expires without any host call, so the
                // pointer monitor and the audio owners would otherwise never
                // learn that a paused page has just been detached.
                page.onHostSuspensionChanged = { [weak self, weak page] in
                    guard let self, let page, self.windows[displayID]?.page === page else { return }
                    self.refreshPointerMonitor()
                    self.refreshAudioOutputs()
                }
                // An edit shown to a paused page has been drawn and the page is
                // detached again, so its Space posters are read from the new frame.
                page.onSuspensionPosterRefreshed = { [weak self, weak page] in
                    guard let self, let page, !self.stopped,
                          self.windows[displayID]?.page === page else { return }
                    self.onSurfacesChanged?()
                }
                page.onAudioDemandChanged = { [weak self, weak page] subscribed in
                    guard let self, let page else { return }
                    self.setAudioDemand(subscribed, page: page, displayID: displayID)
                }
                page.onMediaDemandChanged = { [weak self, weak page] demand in
                    guard let self, let page else { return }
                    self.setMediaDemand(demand, page: page, displayID: displayID)
                }
                page.onRandomFileRequest = { [weak self, weak page] requestId, propertyId in
                    guard let self, let page else { return }
                    self.answerRandomFile(requestId: requestId, propertyId: propertyId, page: page)
                }
                let window = makeSurface(frame, page)
                windows[displayID] = window
                loadedProjectRevisions[displayID] = projectRevision
                recordState(wallpaper, phase: .loading)
                page.applyDisplayRefreshRate(displayRefreshRate)
                await push(wallpaper, into: page, previous: nil)
                guard !stopped, generation == applyGeneration, windows[displayID]?.page === page else { return }
                page.applyAudioOutput(volume: wallpaper.volume, muted: true)
                page.load()
                // The window opens with the picture it replaces over the page, so that it never
                // reaches the screen black. The veil is on before `present` orders it in.
                adoptHeldPicture(into: window, displayID: displayID)
                window.present()
                AppLog.info("web wallpaper \(wallpaper.wallpaperId) opened on display \(displayID)", load: load)
                changed = true
            }
        }
        pruneAssetState()
        refreshPointerMonitor()
        refreshAudioOutputs()
        if changed { onSurfacesChanged?() }
    }

    /// Suspends the page of a display that moves on to another wallpaper and keeps it, when the
    /// display may keep that wallpaper for the desktop the person left and the page has loaded.
    /// The page is suspended while it is still the display's, so it gives up the system audio and
    /// media it listened to through the usual path. False when it is to be closed instead.
    private func keep(_ window: any WebWallpaperSurface, displayID: UInt32) -> Bool {
        guard let descriptor = descriptors[displayID], window.page.isLoaded,
              let revision = loadedProjectRevisions[displayID],
              keepPlan[displayID]?.contains(descriptor.wallpaperId) == true else { return false }
        window.page.setPresentationSuspended(true, stillVisible: false)
        recordState(descriptor, phase: .closed)
        states.removeValue(forKey: displayID)
        loadedProjectRevisions.removeValue(forKey: displayID)
        windows[displayID] = nil
        descriptors[displayID] = nil
        if let earlier = kept[displayID]?[descriptor.wallpaperId] { retire(earlier.window) }
        kept[displayID, default: [:]][descriptor.wallpaperId] = KeptPage(
            window: window, descriptor: descriptor, projectRevision: revision)
        AppLog.info("web wallpaper \(descriptor.wallpaperId) kept suspended on display \(displayID) "
            + "for the desktop the person left", load: window.page.logLoad)
        return true
    }

    /// Closes the kept pages whose display may no longer keep them or is gone, and keeps the
    /// others fitted to their display.
    private func releaseKeptPages() {
        let frames = Dictionary(screens().map { ($0.id, $0.frame) }, uniquingKeysWith: { first, _ in first })
        for (displayID, pages) in kept {
            for (wallpaper, page) in pages {
                if let frame = frames[displayID], keepPlan[displayID]?.contains(wallpaper) == true {
                    if page.window.frame != frame { page.window.setScreenFrame(frame) }
                    continue
                }
                retire(page.window)
                kept[displayID]?[wallpaper] = nil
                AppLog.info("web wallpaper \(wallpaper) no longer kept on display \(displayID)", load: page.window.page.logLoad)
            }
            if kept[displayID]?.isEmpty == true { kept[displayID] = nil }
        }
    }

    /// Stops a page that is no longer any display's and takes its window away.
    private func retire(_ window: any WebWallpaperSurface) {
        window.page.stop()
        window.retire()
    }

    /// Puts the picture a switch held for this display over the window about to open. A window
    /// with no content layer to carry it, or a display that holds none, opens as it always did.
    private func adoptHeldPicture(into window: any WebWallpaperSurface, displayID: UInt32) {
        guard let switchHold, let layer = window.posterLayer else { return }
        switchHold.adopt(into: layer, displayID: displayID)
    }

    /// Closes the window of a display that has no web wallpaper to show any more, because its
    /// wallpaper went to another backend, the display is gone, or the entry file is unusable.
    ///
    /// A held picture waiting for the next window, such as a clip's, is left alone: this
    /// reconcile often runs just before the other host's, and the other host is the successor
    /// that picture was kept for. Only a picture that sat on this very window goes with it.
    private func closeVacated(_ window: any WebWallpaperSurface, displayID: UInt32) {
        let layer = window.posterLayer
        close(window)
        windows[displayID] = nil
        descriptors[displayID] = nil
        switchHold?.windowClosed(layer, displayID: displayID)
    }

    /// A page reports `didFinish` before its first meaningful paint, so the
    /// poster is re-read once immediately and once after the page has had time
    /// to render its initial frame.
    private func scheduleSurfaceChange() {
        onSurfacesChanged?()
        guard !surfaceChangePending else { return }
        surfaceChangePending = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self else { return }
            self.surfaceChangePending = false
            guard !self.stopped else { return }
            self.onSurfacesChanged?()
        }
    }

    private func push(_ wallpaper: BridgeWebWallpaper, into page: WebWallpaperPage, previous: BridgeWebWallpaper?) async {
        // Recorded before anything is pushed: the page reports its own demand
        // back synchronously, and answering it from a stale descriptor would
        // tell the page the previous wallpaper's settings.
        descriptors[wallpaper.displayId] = wallpaper
        let staged = await stageAssets(for: wallpaper)
        guard !stopped, windows[wallpaper.displayId]?.page === page,
              descriptors[wallpaper.displayId] == wallpaper else { return }
        page.setAudioResponseEnabled(wallpaper.audioResponseEnabled)
        page.setMediaIntegrationEnabled(wallpaper.mediaIntegrationEnabled)
        if previous?.propertiesJson != wallpaper.propertiesJson || staged.restaged
            || placementDirtyDisplays.remove(wallpaper.displayId) != nil {
            do {
                let json = imagePlacement.generatedImage(wallpaperID: wallpaper.wallpaperId) == nil
                    ? staged.json
                    : try imagePlacement.effectivePropertiesJSON(
                        staged.json, wallpaperID: wallpaper.wallpaperId, displayID: wallpaper.displayKey)
                page.applyUserProperties(json: json, restaged: staged.restagedFiles)
            } catch {
                AppLog.error("image wallpaper properties could not be applied: \(error.localizedDescription)")
                onError?(error.localizedDescription)
            }
        }
        if previous?.fps != wallpaper.fps {
            page.applyGeneralProperties(fps: wallpaper.fps)
        }
        if previous?.renderScale != wallpaper.renderScale {
            page.applyRenderScale(wallpaper.renderScale)
        }
        if previous?.paused != wallpaper.paused {
            page.setPaused(wallpaper.paused)
        }
        applyPresentationSuspension(to: page, displayID: wallpaper.displayId)
        if page.isLoaded { recordState(wallpaper, phase: .ready) }
        else if let prior = states[wallpaper.displayId], prior.startupRevision != wallpaper.startupRevision {
            recordState(wallpaper, phase: prior.phase, message: prior.message, canRetry: prior.canRetry)
        }
    }

    private func recordState(
        _ wallpaper: BridgeWebWallpaper, phase: HostWallpaperState.Phase,
        message: String? = nil, canRetry: Bool = false
    ) {
        let state = HostWallpaperState(kind: .web, displayID: wallpaper.displayId,
            wallpaperID: wallpaper.wallpaperId, startupRevision: wallpaper.startupRevision,
            nativeAdmissionKey: nil, phase: phase, message: message, canRetry: canRetry)
        guard states[wallpaper.displayId] != state else { return }
        states[wallpaper.displayId] = state
        onStateChanged?(state)
    }

    func retry(wallpaperID: String, displayID: UInt32) {
        guard !stopped, let wallpaper = descriptors[displayID], wallpaper.wallpaperId == wallpaperID,
              let page = windows[displayID]?.page, states[displayID]?.phase == .failed,
              states[displayID]?.canRetry == true else { return }
        recordState(wallpaper, phase: .loading)
        page.load()
    }

    private func refreshImagePlacement(wallpaperID: String, displayKey: String?, reloadUpgradedPage: Bool) {
        for (displayID, wallpaper) in descriptors
        where wallpaper.wallpaperId == wallpaperID && (displayKey == nil || wallpaper.displayKey == displayKey) {
            guard let page = windows[displayID]?.page else { continue }
            placementDirtyDisplays.insert(displayID)
            Task { @MainActor [weak self, weak page] in
                guard let self, let page else { return }
                await self.push(wallpaper, into: page, previous: wallpaper)
                guard self.windows[displayID]?.page === page else { return }
                if reloadUpgradedPage { page.load() }
            }
        }
        refreshAudioOutputs()
        scheduleSurfaceChange()
    }

    private func refreshAudioOutputs() {
        let owners = WebWallpaperAudioOwnership.owners(in: descriptors) { displayID in
            windows[displayID]?.page.isLoaded == true && !isSuspended(displayID: displayID)
        }
        // Retire the old audible page before enabling its replacement.
        for (displayID, window) in windows {
            guard let wallpaper = descriptors[displayID], owners[wallpaper.audioSourceDisplayId] != displayID else { continue }
            window.page.applyAudioOutput(volume: wallpaper.volume, muted: true)
        }
        for displayID in owners.values {
            guard let wallpaper = descriptors[displayID], let page = windows[displayID]?.page else { continue }
            page.applyAudioOutput(volume: wallpaper.volume, muted: wallpaper.muted)
        }
    }

    private func isSuspended(displayID: UInt32) -> Bool {
        suspended || suspendedDisplays.contains(displayID)
    }

    /// The desktop-wide conditions (sleep, lock, an app rule) hide every display,
    /// so they leave nothing in sight whatever one display was told.
    private func applyPresentationSuspension(to page: WebWallpaperPage, displayID: UInt32) {
        page.setPresentationSuspended(
            isSuspended(displayID: displayID),
            stillVisible: !suspended && suspendedInPlainSight.contains(displayID))
    }

    /// Mirrors `WallpaperPresentationPolicy`: pages suspend while no pixel can
    /// reach any display, without touching the user's play/pause choice.
    func setPresentationSuspended(_ suspended: Bool) {
        self.suspended = suspended
        for (displayID, window) in windows {
            applyPresentationSuspension(to: window.page, displayID: displayID)
        }
        refreshPointerMonitor()
        refreshAudioOutputs()
    }

    /// Suspends the page on one display only. A window covering the wallpaper
    /// on one screen must not stop the page on another. `stillVisible` marks a
    /// display the user can see that is paused only because they are working on
    /// another one, whose page draws a frame before it is detached.
    func setPresentationSuspended(_ suspended: Bool, forDisplay displayID: UInt32, stillVisible: Bool = false) {
        if suspended {
            suspendedDisplays.insert(displayID)
        } else {
            suspendedDisplays.remove(displayID)
        }
        if suspended && stillVisible {
            suspendedInPlainSight.insert(displayID)
        } else {
            suspendedInPlainSight.remove(displayID)
        }
        if let page = windows[displayID]?.page { applyPresentationSuspension(to: page, displayID: displayID) }
        refreshPointerMonitor()
        refreshAudioOutputs()
    }

    /// Hover, click and scroll reach a page only while it is loaded and in the
    /// window tree. The first such page installs the monitor; the last one
    /// leaving removes it, and the next resume installs it again.
    private func refreshPointerMonitor() {
        let live = windows.values.contains { $0.page.isLoaded && !$0.page.hostSuspended }
        mouse.setActive(live)
    }

    /// Brings every running page in line with the preference without a reload.
    private func applyInspection() {
        let enabled = inspectionEnabled()
        for window in windows.values { window.page.setInspectable(enabled) }
    }

    func shutdown() {
        stopped = true
        applyGeneration &+= 1
        for store in assetStores.values { store.cancelImports() }
        if let posterObserver {
            frameCenter.removeObserver(posterObserver)
            self.posterObserver = nil
        }
        if let inspectionObserver {
            frameCenter.removeObserver(inspectionObserver)
            self.inspectionObserver = nil
        }
        if let imagePlacementObserver {
            NotificationCenter.default.removeObserver(imagePlacementObserver)
            self.imagePlacementObserver = nil
        }
        mouse.setActive(false)
        // Each page drops its own subscriptions as it stops; the sweep after
        // the loop is what guarantees the invariant rather than trusting it.
        for window in windows.values { close(window) }
        windows.removeAll()
        for page in kept.values.flatMap(\.values) { retire(page.window) }
        kept.removeAll()
        keepPlan.removeAll()
        audioPump.removeAllSubscribers()
        mediaRelay.removeListener(mediaListenerKey)
        mediaRelay.removeAllConsumers()
        mediaListeners.removeAll()
        for (displayID, subscribed) in audioSubscriptions where subscribed {
            guard let wallpaperId = descriptors[displayID]?.wallpaperId else { continue }
            flushAudioSubscription(wallpaperId: wallpaperId, displayID: displayID, subscribed: false)
        }
        audioSubscriptions.removeAll()
        audioSubscriptionTokens.removeAll()
        confirmedAudioDisplays.removeAll()
        failedAudioDisplays.removeAll()
        audioDeliveredAt.removeAll()
        audioExpiryTask?.cancel()
        audioExpiryTask = nil
        descriptors.removeAll()
        loadedProjectRevisions.removeAll()
        pruneAssetState()
    }

    /// A project nothing displays any more keeps no staged index. The store is
    /// in memory, so holding it would only pin the file list of a wallpaper the
    /// user has moved on from; the staged copies themselves stay on disk and
    /// are removed with the project or by `python3 scripts/clean.py`.
    private func pruneAssetState() {
        let live = Set(windows.values.map { Self.projectKey($0.page.projectURL.path) })
        for project in Array(assetStores.keys) where !live.contains(project) {
            assetStores[project]?.cancelImports()
            assetStores[project] = nil
            assetOwners[project] = nil
            assetRequests[project] = nil
            invalidatedAssets[project] = nil
            stagedAssets[project] = nil
            directoryFiles[project] = nil
            fetchAllProperties[project] = nil
        }
    }

    private func close(_ window: any WebWallpaperSurface) {
        if let (displayID, _) = windows.first(where: { $0.value === window }),
           let wallpaper = descriptors[displayID] {
            recordState(wallpaper, phase: .closed)
            states.removeValue(forKey: displayID)
            loadedProjectRevisions.removeValue(forKey: displayID)
        }
        window.page.stop()
        window.retire()
    }

    // MARK: - audio

    /// A page's audio subscription changed. The shared pump decides whether any
    /// polling happens at all; the bridge call opens and closes the capture tap
    /// so an idle desktop is not recording the user's output.
    private func setAudioDemand(_ subscribed: Bool, page: WebWallpaperPage, displayID: UInt32) {
        guard windows[displayID]?.page === page else { return }
        if !subscribed { audioPump.setSubscribed(false, for: ObjectIdentifier(page)) }
        // A display nobody ever subscribed is already unsubscribed: a page that
        // stops without ever having asked must not send the bridge a close for
        // a tap that was never opened.
        guard (audioSubscriptions[displayID] ?? false) != subscribed,
              let wallpaperId = descriptors[displayID]?.wallpaperId else { return }
        audioSubscriptions[displayID] = subscribed
        let token = UUID()
        audioSubscriptionTokens[displayID] = token
        confirmedAudioDisplays.remove(displayID)
        failedAudioDisplays.remove(displayID)
        audioDeliveredAt.removeValue(forKey: displayID)
        onDeliveryStateChanged?()
        flushAudioSubscription(wallpaperId: wallpaperId, displayID: displayID, subscribed: subscribed,
            page: page, token: token)
    }

    /// Chained rather than fired independently: an unsubscribe overtaking the
    /// subscribe that preceded it would leave the tap open with nobody reading.
    private func flushAudioSubscription(wallpaperId: String, displayID: UInt32, subscribed: Bool,
                                        page: WebWallpaperPage? = nil, token: UUID? = nil) {
        let previous = audioSubscriptionTask
        audioSubscriptionTask = Task { @MainActor [weak self, weak page, setAudioSubscribed] in
            await previous?.value
            do {
                try await setAudioSubscribed(wallpaperId, displayID, subscribed)
                guard let self, let page, !self.stopped, self.windows[displayID]?.page === page,
                      self.audioSubscriptionTokens[displayID] == token else { return }
                if subscribed {
                    self.confirmedAudioDisplays.insert(displayID)
                    self.audioPump.setSubscribed(true, for: ObjectIdentifier(page))
                }
                self.onDeliveryStateChanged?()
            } catch {
                if let self, self.audioSubscriptionTokens[displayID] == token {
                    self.failedAudioDisplays.insert(displayID)
                    self.confirmedAudioDisplays.remove(displayID)
                    self.audioDeliveredAt.removeValue(forKey: displayID)
                    self.onDeliveryStateChanged?()
                }
                AppLog.warn("""
                    web wallpaper audio on display \(displayID): subscription could not be \
                    \(subscribed ? "opened" : "closed"): \(error.localizedDescription)
                    """)
            }
        }
    }

    private func broadcast(_ spectrum: BridgeAudioSpectrum) {
        guard spectrum.bins.count == 128, spectrum.bins.allSatisfy(\.isFinite) else { return }
        for (displayID, window) in windows where confirmedAudioDisplays.contains(displayID) {
            let page = window.page
            let token = audioSubscriptionTokens[displayID]
            page.deliverAudio(spectrum.bins) { [weak self, weak page] delivered in
                guard let self, let page, delivered, !self.stopped,
                      self.windows[displayID]?.page === page,
                      self.audioSubscriptionTokens[displayID] == token,
                      self.confirmedAudioDisplays.contains(displayID) else { return }
                let wasDelivering = self.audioDeliveredAt[displayID]
                    .map { self.audioClock() - $0 < Self.audioDeliveryLifetime } ?? false
                self.audioDeliveredAt[displayID] = self.audioClock()
                if !wasDelivering { self.onDeliveryStateChanged?() }
                self.scheduleAudioExpiry()
            }
        }
    }

    func expireAudioDeliveries() {
        let expired = audioDeliveredAt.filter { audioClock() - $0.value >= Self.audioDeliveryLifetime }.map(\.key)
        for id in expired { audioDeliveredAt.removeValue(forKey: id) }
        if !expired.isEmpty { onDeliveryStateChanged?() }
    }

    private func scheduleAudioExpiry() {
        guard audioExpiryTask == nil else { return }
        audioExpiryTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, !self.stopped else { return }
                self.expireAudioDeliveries()
                if self.audioDeliveredAt.isEmpty { self.audioExpiryTask = nil; return }
            }
        }
    }

    // MARK: - media

    private func setMediaDemand(_ demand: WebWallpaperPage.MediaDemand, page: WebWallpaperPage, displayID: UInt32) {
        let key = ObjectIdentifier(page)
        mediaRelay.setConsuming(demand.consuming, for: key)
        guard demand.listening else {
            mediaListeners.remove(key)
            return
        }
        mediaListeners.insert(key)
        // A page that has just registered, reloaded or resumed is given the
        // whole current state; the page drops any part of it that has not
        // actually changed since it last saw it.
        let enabled = descriptors[displayID]?.mediaIntegrationEnabled ?? false
        for event in mediaRelay.currentEvents(userEnabled: enabled) {
            page.deliverMediaEvent(slot: event.slot, event: event.payload)
        }
    }

    private func broadcast(_ event: WebWallpaperMediaRelay.Event) {
        let payload = event.payload
        for window in windows.values where mediaListeners.contains(ObjectIdentifier(window.page)) {
            window.page.deliverMediaEvent(slot: event.slot, event: payload)
        }
    }

    // MARK: - file and directory properties

    /// Puts the user's `file` and `directory` selections where the page is
    /// allowed to read them, and rewrites the payload so a `file` property
    /// carries the staged value the page can actually load.
    ///
    /// A `directory` value is left alone: the protocol only uses it so a page
    /// can tell "no directory set" from "one is set", and neither mode loads it
    /// directly — `ondemand` asks for a random file and `fetchall` is told the
    /// contents through the listener.
    ///
    /// `restagedFiles` names the `file` properties staged again on this call. Their
    /// staged path is built from the property id and the file's name, so a selection
    /// whose bytes changed under the same name reads exactly as it did before, and
    /// the page is told to take it in again.
    func stageAssets(
        for wallpaper: BridgeWebWallpaper
    ) async -> (json: String, restaged: Bool, restagedFiles: Set<String>) {
        let properties = Self.pathProperties(in: wallpaper.propertiesJson)
        guard !properties.isEmpty else { return (wallpaper.propertiesJson, false, []) }
        let project = Self.projectKey(wallpaper.projectPath)
        assetOwners[project] = wallpaper.wallpaperId
        var restaged = false
        var restagedFiles = Set<String>()
        for property in properties {
            // Registered before staging: the import itself announces the files
            // it found, and routing that announcement needs the mode already
            // recorded.
            if property.kind == .directory {
                if property.fetchAll {
                    fetchAllProperties[project, default: []].insert(property.id)
                } else {
                    fetchAllProperties[project]?.remove(property.id)
                }
            }
            if stagedAssets[project]?[property.id]?.source != property.source
                || invalidatedAssets[project]?.contains(property.id) == true {
                await restage(
                    property, project: project, wallpaperId: wallpaper.wallpaperId,
                    title: wallpaper.title)
                restaged = true
                if property.kind == .file { restagedFiles.insert(property.id) }
            }
        }
        let staged = properties.filter { $0.kind == .file }.reduce(into: [String: String]()) {
            $0[$1.id] = stagedAssets[project]?[$1.id]?.pageValue ?? ""
        }
        guard !staged.isEmpty else { return (wallpaper.propertiesJson, restaged, restagedFiles) }
        return (
            Self.substituting(staged, in: wallpaper.propertiesJson) ?? wallpaper.propertiesJson,
            restaged, restagedFiles)
    }

    /// The `file` and `directory` properties the bridge's payload declares.
    /// Anything else — including `texture` and `scenetexture`, which are scene
    /// texture pickers with no directory semantics — is not a path property.
    static func pathProperties(in propertiesJson: String) -> [PathProperty] {
        guard let data = propertiesJson.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return [] }
        return root.compactMap { PathProperty(id: $0.key, entry: $0.value) }
            .sorted { $0.id < $1.id }
    }

    /// Replaces the `value` of the named properties, leaving every other key in
    /// the payload untouched. Returns nil when the payload is not an object.
    static func substituting(_ values: [String: String], in propertiesJson: String) -> String? {
        guard let data = propertiesJson.data(using: .utf8),
              var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        for (id, value) in values {
            var entry = (root[id] as? [String: Any]) ?? [:]
            entry["value"] = value
            root[id] = entry
        }
        // Sorted so two pushes of the same selection produce the same payload
        // rather than differing by dictionary order alone.
        guard let encoded = try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        else { return nil }
        return String(data: encoded, encoding: .utf8)
    }

    private func restage(
        _ property: PathProperty, project: String, wallpaperId: String, title: String
    ) async {
        guard let store = assetStore(forProject: project, wallpaperId: wallpaperId) else {
            // Nothing can stage the file, so the page is told the property is
            // unset rather than handed a path it is not allowed to read.
            stagedAssets[project, default: [:]][property.id] = StagedAsset(source: property.source, pageValue: "")
            return
        }
        // Only a genuinely cleared property is cleared in the store. Re-importing the
        // same selection must not discard the app's managed copy and fetch it again.
        let previousFiles = directoryFiles[project]?[property.id] ?? []
        let request = UUID()
        assetRequests[project, default: [:]][property.id] = request
        let source = URL(fileURLWithPath: property.source)
        do {
            if property.source.isEmpty {
                try await store.clear(propertyId: property.id)
                guard !stopped, assetRequests[project]?[property.id] == request else { return }
                directoryFiles[project]?[property.id] = nil
                stagedAssets[project, default: [:]][property.id] = StagedAsset(source: "", pageValue: "")
                invalidatedAssets[project]?.remove(property.id)
                onAssetsChanged?()
                if !previousFiles.isEmpty {
                    deliverDirectory(project: project, propertyId: property.id, added: [], removed: previousFiles)
                }
                return
            }
            switch property.kind {
            case .file:
                let staged = try await store.importFile(
                    at: source, propertyId: property.id, filter: property.filter)
                guard !stopped, assetRequests[project]?[property.id] == request else { return }
                stagedAssets[project, default: [:]][property.id] =
                    StagedAsset(source: property.source, pageValue: staged.pageValue)
                invalidatedAssets[project]?.remove(property.id)
                onAssetsChanged?()
            case .directory:
                let staged = try await store.importDirectory(
                    at: source, propertyId: property.id, filter: property.filter,
                    limit: UserAssetStore.defaultDirectoryFileLimit)
                guard !stopped, assetRequests[project]?[property.id] == request else { return }
                let files = staged.map(\.pageValue)
                directoryFiles[project, default: [:]][property.id] = files
                stagedAssets[project, default: [:]][property.id] =
                    StagedAsset(source: property.source, pageValue: property.source)
                invalidatedAssets[project]?.remove(property.id)
                onAssetsChanged?()
                if store.isTruncated(propertyId: property.id) {
                    let limit = UserAssetStore.defaultDirectoryFileLimit
                    onError?(String(localized: "Web wallpaper “\(title)” uses only the first \(limit) files in the folder you chose."))
                }
                deliverDirectory(project: project, propertyId: property.id, added: files, removed: previousFiles)
            }
        } catch is CancellationError {
            return
        } catch {
            guard !stopped, assetRequests[project]?[property.id] == request else { return }
            // A failed replacement leaves the last published value and directory
            // contents usable, just as the managed transaction preserves their bytes.
            AppLog.error("web wallpaper \(project): \(property.id) could not be staged: \(error.localizedDescription)")
            onError?(String(localized: "Web wallpaper “\(title)” could not use the file you chose: \(error.localizedDescription)"))
        }
    }

    private func assetStore(
        forProject project: String, wallpaperId: String
    ) -> (any WebWallpaperAssetSource)? {
        if let existing = assetStores[project] { return existing }
        guard let makeAssetStore else { return nil }
        let store = makeAssetStore(URL(fileURLWithPath: project, isDirectory: true), wallpaperId)
        store.onDirectoryChanged = { [weak self] propertyId, added, removed in
            MainActor.assumeIsolated {
                self?.directoryChanged(
                    project: project, propertyId: propertyId,
                    added: added.map(\.pageValue), removed: removed.map(\.pageValue))
            }
        }
        assetStores[project] = store
        return store
    }

    func invalidateAsset(wallpaperID: String, propertyID: String) {
        for (project, owner) in assetOwners where owner == wallpaperID {
            assetStores[project]?.cancelImport(propertyId: propertyID)
            assetRequests[project, default: [:]][propertyID] = UUID()
            invalidatedAssets[project, default: []].insert(propertyID)
        }
    }

    private func directoryChanged(project: String, propertyId: String, added: [String], removed: [String]) {
        onAssetsChanged?()
        var files = directoryFiles[project]?[propertyId] ?? []
        files.removeAll { removed.contains($0) }
        files.append(contentsOf: added.filter { !files.contains($0) })
        directoryFiles[project, default: [:]][propertyId] = files
        deliverDirectory(project: project, propertyId: propertyId, added: added, removed: removed)
    }

    private func deliverDirectory(project: String, propertyId: String, added: [String], removed: [String]) {
        guard fetchAllProperties[project]?.contains(propertyId) == true else { return }
        for window in windows.values where Self.projectKey(window.page.projectURL.path) == project {
            window.page.deliverDirectoryFiles(property: propertyId, added: added, removed: removed)
        }
    }

    /// A new document never saw the files the host already knows about, so the
    /// whole current set is replayed into it as an addition.
    private func replayDirectories(displayID: UInt32) {
        guard let page = windows[displayID]?.page else { return }
        let project = Self.projectKey(page.projectURL.path)
        for propertyId in fetchAllProperties[project] ?? [] {
            let files = directoryFiles[project]?[propertyId] ?? []
            guard !files.isEmpty else { continue }
            page.deliverDirectoryFiles(property: propertyId, added: files, removed: [])
        }
    }

    /// Answers `wallpaperRequestRandomFileForProperty`. A property with no
    /// usable directory answers with an empty path: the page's callback must
    /// run either way, because a wallpaper that waits for it would never draw.
    private func answerRandomFile(requestId: String, propertyId: String, page: WebWallpaperPage) {
        let project = Self.projectKey(page.projectURL.path)
        let path = assetStores[project]?.randomFile(propertyId: propertyId)?.pageValue ?? ""
        page.deliverRandomFile(requestId: requestId, property: propertyId, path: path)
    }

    /// Project paths reach this host from two directions — the descriptor and
    /// the page's own URL — so both are reduced to one spelling before use.
    private static func projectKey(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
    }

    /// A `file` or `directory` property as the project declared it, resolved
    /// against the path the user currently has selected.
    struct PathProperty: Equatable {
        enum Kind: String { case file, directory }

        var id: String
        var kind: Kind
        var filter: UserAssetFilter
        var fetchAll: Bool
        /// The user's own path, as the bridge persisted it. Empty when unset.
        var source: String

        init?(id: String, entry: Any) {
            guard let entry = entry as? [String: Any],
                  let kind = (entry["type"] as? String).flatMap(Kind.init(rawValue:))
            else { return nil }
            self.id = id
            self.kind = kind
            // An author who declared no file-type option restricted nothing, so
            // neither does the import.
            self.filter = (entry["fileFilter"] as? String).flatMap(UserAssetFilter.init(rawValue:)) ?? .any
            self.fetchAll = kind == .directory && (entry["mode"] as? String) == "fetchall"
            self.source = (entry["value"] as? String) ?? ""
        }
    }

    /// `DesktopWallpaperSync` asks each desktop surface for pixels by its layer.
    /// A web surface answers with a `WKWebView` snapshot in the same RGBA
    /// contract the renderer uses, so Space posters match the live page.
    private func answerPosterRequest(_ notification: Notification) {
        guard let layer = notification.object as? CALayer,
              let window = windows.values.first(where: { $0.posterLayer === layer }) else { return }
        let webView = window.page.webView
        let center = frameCenter
        let context = notification.userInfo?["context"] as? String
        // A suspended page has left the window tree and WebKit does not promise
        // a snapshot of a detached view, so its own detach poster is the frame.
        // Published a turn later, like a live snapshot, because the requester
        // is still inside its own refresh when it asks.
        if let poster = window.page.suspensionPoster {
            Task { @MainActor in
                guard let frame = Self.rgbaPixels(of: poster) else { return }
                DesktopPosterFrame(pixels: frame.pixels, width: frame.width, height: frame.height, bgra: false)
                    .publish(for: layer, to: center, context: context)
            }
            return
        }
        webView.takeSnapshot(with: nil) { image, error in
            MainActor.assumeIsolated {
                guard let image else {
                    if let error { AppLog.warn("web wallpaper poster snapshot failed: \(error.localizedDescription)") }
                    return
                }
                guard let frame = Self.rgbaPixels(of: image) else { return }
                DesktopPosterFrame(pixels: frame.pixels, width: frame.width, height: frame.height, bgra: false)
                    .publish(for: layer, to: center, context: context)
            }
        }
    }

    static func rgbaPixels(of image: NSImage) -> (pixels: Data, width: Int, height: Int)? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        guard let frame = DesktopPosterFrame.rgba(cgImage) else { return nil }
        return (frame.pixels, frame.width, frame.height)
    }
}
