import AVFoundation
import AppKit

/// Keeps one native video window per display in step with the bridge's
/// committed plain-video wallpapers.
///
/// This is the whole host side of plain video. The bridge offers every plain video with a file to
/// play and gives the scene engine none of them, so this host is the only player: it plays what it
/// can and reports what it cannot as a failed state of that display (the display keeps the picture it
/// had, and the panel shows the reason). Nothing takes a failed video over, and it never silently
/// substitutes a setting it cannot honour.
@MainActor
final class NativeVideoWallpaperHost {
    private let fetch: @MainActor () async throws -> [BridgeNativeVideoWallpaper]
    private let screens: @MainActor () -> [(id: UInt32, frame: NSRect)]
    /// Decides whether a wallpaper can be played. Injected so the failure rules can be tested
    /// without an asset or a window server.
    private let refusal: @MainActor (URL) async -> NativeVideoRefusal?
    /// Builds one display's surface. Injected so the routing and suspension
    /// rules can be exercised without opening a desktop window.
    private let makeSurface: @MainActor (URL, NSRect, RuntimeSurfaceKey, Bool) -> NativeVideoSurface
    private let counters: RuntimeCounters
    private let frameCenter: NotificationCenter
    /// Where the system announces that the Mac or its displays woke and that
    /// the session came back. Injected so a wake can be posted by a test.
    private let workspaceCenter: NotificationCenter
    /// Waits for a duration. Injected so the limits below can be fired by hand
    /// instead of waited out.
    private let sleep: @Sendable (Duration) async throws -> Void
    /// Where a wallpaper's file lives, which sets how long its metadata read
    /// may take. Injected so the limits can be tested without a slow volume.
    private let storage: @MainActor (URL) async -> NativeVideoStoragePolicy.Location
    /// Keeps the picture of the wallpaper a switch replaces on screen until the new clip has
    /// its first frame. `nil` for a host that never holds one, as in most of the tests.
    private let switchHold: WallpaperSwitchHold?

    private var surfaces: [UInt32: NativeVideoSurface] = [:]
    private var descriptors: [UInt32: BridgeNativeVideoWallpaper] = [:]
    /// The `load#N` each display's current clip was logged under, so a later
    /// playback failure is attributed to the load it belongs to.
    private var logLoads: [UInt32: UInt64] = [:]
    /// Displays suspended on their own, kept apart from the global flag so one
    /// occluded screen cannot stop a video on a visible screen.
    private var suspendedDisplays: Set<UInt32> = []
    private var suspended = false
    /// What this host knows has failed for a display's current offer, so the file is not opened
    /// again for every snapshot. A failure that is a verdict on the file is kept in
    /// `admissionCache` under its key; one that is not (a read that never finished, a pipeline that
    /// stalled) is kept here until the bridge's startup revision moves on, which any new apply or
    /// reconcile does, and the clip is then tried afresh. Cleared on shutdown.
    private struct FailedOffer {
        let key: UInt64
        let revision: UInt64
        let refusal: NativeVideoRefusal
    }
    private var failures: [UInt32: FailedOffer] = [:]
    /// Decisions already taken this session, so a display reconfiguration does
    /// not re-read the same file. Bounded, and cleared on shutdown.
    private var admissionCache: [UInt64: NativeVideoRefusal?] = [:]
    private var admissionCacheOrder: [UInt64] = []
    static let admissionCacheLimit = 16
    /// How many times one offer's metadata is re-read after an unsettled
    /// failure before the display is reported as failed. Bounded so a file that
    /// never loads cannot hold the reconcile pass indefinitely, and greater
    /// than one so a single transient error is not a failure.
    static let admissionAttemptLimit = 3
    static let admissionRetryDelay = Duration.milliseconds(150)
    /// Files whose metadata read has started and not yet returned, with the
    /// serial of that read. A read that outlives its limit stays here until it
    /// finally returns, so the same file is never read twice at once: a volume
    /// that has stopped answering would otherwise gain one more blocked load
    /// per offer. Keyed by path because the stuck thing is the file, not the
    /// offer; the serial stops a late return from clearing a newer read.
    private var outstandingProbes: [String: UInt64] = [:]
    private var probeSerial: UInt64 = 0
    /// One display's wait for its first picture. `task` is the countdown, and
    /// is `nil` while the watch is parked because the display cannot be judged.
    private struct FirstFrameWatch {
        var task: Task<Void, Never>?
        let url: URL
        /// Whether the player has already been rebuilt once for this clip.
        let restarted: Bool
    }
    private var firstFrameWatches: [UInt32: FirstFrameWatch] = [:]
    private var surfaceGeneration: UInt64 = 0
    /// Moves on every `apply`, so a pass that was overtaken while it waited on
    /// a metadata read can tell and stop acting on the list it was given.
    private var applyGeneration: UInt64 = 0
    private var reconcileInFlight = false
    private var reconcileRequested = false
    private var stopped = false
    private var posterObserver: NSObjectProtocol?
    /// How long after a wake the playing surfaces are asked to check their
    /// pipelines. The system may need a moment after the displays come on to
    /// give the video decoder back, and a check made at once could find it still
    /// gone and start repairs that its return would have made unnecessary. Not
    /// tuned on a real wake yet (see manual-smoke.md).
    static let wakeSettle = Duration.seconds(1)
    private var wakeObservers: [NSObjectProtocol] = []
    /// Moves on every wake, so a settle that a newer wake superseded can tell.
    private var wakeGeneration: UInt64 = 0
    private var wakeTask: Task<Void, Never>?

    var onError: (@MainActor (String) -> Void)?
    var onSurfacesChanged: (@MainActor () -> Void)?
    var onStateChanged: (@MainActor (HostWallpaperState) -> Void)?
    private var states: [UInt32: HostWallpaperState] = [:]
    /// The wallpapers each display may keep paused for a desktop the person left
    /// (`WallpaperSpaceParking`), by display.
    private var keepPlan: [UInt32: Set<String>] = [:]
    /// A clip a display keeps paused in its own window for a desktop the person left, so the
    /// clip runs on from there when that desktop comes back instead of opening again.
    private struct KeptClip {
        let surface: NativeVideoSurface
        let descriptor: BridgeNativeVideoWallpaper
        let load: UInt64?
    }
    private var kept: [UInt32: [String: KeptClip]] = [:]

    init(
        fetch: @escaping @MainActor () async throws -> [BridgeNativeVideoWallpaper],
        screens: (@MainActor () -> [(id: UInt32, frame: NSRect)])? = nil,
        refusal: (@MainActor (URL) async -> NativeVideoRefusal?)? = nil,
        makeSurface: (
            @MainActor (URL, NSRect, RuntimeSurfaceKey, Bool) -> NativeVideoSurface
        )? = nil,
        frameCenter: NotificationCenter = .default,
        workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        counters: RuntimeCounters? = nil,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        storage: (@MainActor (URL) async -> NativeVideoStoragePolicy.Location)? = nil,
        switchHold: WallpaperSwitchHold? = nil
    ) {
        self.fetch = fetch
        self.screens = screens ?? { WebWallpaperHost.systemScreens() }
        self.refusal = refusal ?? { url in
            await VideoFormatSupport.refusal(url: url)
        }
        let sharedCounters = counters ?? .shared
        self.makeSurface = makeSurface ?? { url, frame, surface, paused in
            // AVFoundation plays what it opens; Matroska and WebM, which it never does, go to the
            // app's own player. The format check opened the file and kept it for this.
            if let file = WebMOpenedFiles.shared.file(for: url) {
                return WebMVideoWallpaperWindow(
                    frame: frame, url: url, file: file, surface: surface, counters: sharedCounters,
                    paused: paused)
            }
            if VideoFormatSupport.isMatroska(url) {
                return WebMVideoWallpaperWindow(
                    frame: frame, url: url, file: nil, surface: surface, counters: sharedCounters,
                    paused: paused)
            }
            let player = NativeVideoPlayer(
                surface: surface, counters: sharedCounters, paused: paused)
            let window = NativeVideoWallpaperWindow(frame: frame, player: player)
            player.load(url: url)
            return window
        }
        self.frameCenter = frameCenter
        self.workspaceCenter = workspaceCenter
        self.counters = counters ?? .shared
        self.sleep = sleep
        self.storage = storage ?? { url in await NativeVideoStoragePolicy.location(of: url) }
        self.switchHold = switchHold
    }

    convenience init(bridge: WallpaperBridge, switchHold: WallpaperSwitchHold? = nil) {
        self.init(
            fetch: { try await bridge.nativeVideoWallpapers() },
            switchHold: switchHold)
    }

    var activeDisplayIDs: Set<UInt32> { Set(surfaces.keys) }
    var isEmpty: Bool { surfaces.isEmpty }

    /// The windows of the clips kept paused for other desktops.
    var keptWindowNumbers: Set<Int> { Set(kept.values.flatMap(\.values).map(\.surface.windowNumber)) }

    /// The wallpapers the display keeps paused for its other desktops.
    func keptWallpapers(on displayID: UInt32) -> Set<String> { Set((kept[displayID] ?? [:]).keys) }

    /// The wallpaper each of this host's windows shows, live and kept, by window number.
    var windowWallpapers: [Int: String] {
        var wallpapers: [Int: String] = [:]
        for (displayID, surface) in surfaces {
            if let wallpaper = descriptors[displayID]?.wallpaperId { wallpapers[surface.windowNumber] = wallpaper }
        }
        for clips in kept.values {
            for (wallpaper, clip) in clips { wallpapers[clip.surface.windowNumber] = wallpaper }
        }
        return wallpapers
    }

    /// Sets which wallpapers each display may keep paused for a desktop the person left, and
    /// closes the kept clips the plan no longer names.
    func setKeptWallpapers(_ plan: [UInt32: Set<String>]) {
        keepPlan = plan
        releaseKeptClips()
    }
    /// Displays the bridge offered a wallpaper for in the last pass that this
    /// host's screen list does not contain. The bridge reads the active displays
    /// from CoreGraphics and this host reads AppKit's screens, and the two can
    /// disagree about a hardware mirror set, an AirPlay or Sidecar screen, or a
    /// built-in display whose lid is closed. Nothing can be drawn on a display
    /// that is not in this list, so these offers are left alone until the lists
    /// agree. Empty when every offered display is visible here. Only the tests
    /// read it: the host retries nothing, and the pass that finds the display
    /// listed opens it.
    private(set) var offeredButUnseenDisplayIDsForTest: Set<UInt32> = []
    /// An offer the host has already said it cannot place.
    private struct UnseenOffer: Hashable {
        let displayID: UInt32
        let wallpaperID: String
    }
    /// The unseen offers that were logged, so a display
    /// that stays unseen is said once and not on every snapshot. An entry goes
    /// when its display shows up or the bridge stops offering the wallpaper
    /// there, so the same disagreement coming back is news again.
    private var warnedUnseen: Set<UnseenOffer> = []
    private(set) var unseenWarningCountForTest = 0

    /// Whether this display's player is running. The observable the suspension
    /// rules are argued from: a decision delivered is not a player stopped.
    func isPlaying(displayID: UInt32) -> Bool? {
        surfaces[displayID]?.isPlaying
    }

    var surfaceGenerationForTest: UInt64 { surfaceGeneration }
    /// Metadata reads that have not returned, including ones already given up
    /// on.
    var outstandingProbeCountForTest: Int { outstandingProbes.count }
    /// First-frame watches counting down, and ones waiting for their display to
    /// become visible again.
    var armedFirstFrameWatchCountForTest: Int {
        firstFrameWatches.values.filter { $0.task != nil }.count
    }
    var parkedFirstFrameWatchCountForTest: Int {
        firstFrameWatches.values.filter { $0.task == nil }.count
    }

    func start() {
        guard posterObserver == nil else { return }
        posterObserver = frameCenter.addObserver(
            forName: DesktopPosterNotification.request,
            object: nil, queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated { self?.answerPosterRequest(notification) }
        }
        for (name, reason) in [
            (NSWorkspace.screensDidWakeNotification, "the displays woke"),
            (NSWorkspace.didWakeNotification, "the Mac woke"),
            (NSWorkspace.sessionDidBecomeActiveNotification, "the session became active"),
        ] {
            wakeObservers.append(workspaceCenter.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.systemWoke(reason: reason) }
            })
        }
        stopped = false
    }

    // MARK: Wake

    /// The Mac or its displays woke, or the user's session came back.
    ///
    /// Playback that was running before may no longer be: the system may take
    /// the video decoder away while the displays sleep, and neither a plain
    /// `play()` nor the presentation policy's resume says whether pictures come
    /// out again. After a short settle every playing surface is asked to check
    /// itself; a healthy one pays a brief look and shows no change. The wake
    /// notifications arrive in a burst (the displays, then the Mac, then the
    /// session), so a newer one replaces the settle in flight and the surfaces
    /// are asked once.
    ///
    /// Nothing is started while no surface is open, which is every wake with no
    /// video wallpaper: the observers are cheap, a timer for no consumer is not. A surface that opens during the settle has just been
    /// built and has no pipeline to have lost yet.
    private func systemWoke(reason: String) {
        guard !stopped, !surfaces.isEmpty else { return }
        wakeGeneration &+= 1
        let generation = wakeGeneration
        wakeTask?.cancel()
        let sleep = self.sleep
        wakeTask = Task { @MainActor [weak self] in
            do { try await sleep(Self.wakeSettle) } catch { return }
            guard let self, !self.stopped, generation == self.wakeGeneration else { return }
            self.wakeTask = nil
            for surface in self.surfaces.values where surface.isPlaying {
                surface.verifyPlayback(reason: reason)
            }
        }
    }

    /// Re-reads the committed native wallpapers and diffs them against open
    /// windows. Overlapping calls coalesce into one trailing pass.
    ///
    /// A descriptor's `paused` is the bridge's composed flag: Play/Pause, the
    /// battery Pause, and presentation, global and per display. A presentation
    /// change returns no snapshot, so whoever delivers one calls this once the
    /// bridge has committed it (`WallpaperHosts.reconcile`). Without that, a
    /// pass that ran while the desktop was covered leaves the clip user-paused
    /// by a reading that is out of date the moment the desktop is uncovered.
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
                guard !self.stopped else { return }
                await self.apply(wallpapers)
            } catch {
                AppLog.error("native video wallpapers could not be read: \(error.localizedDescription)")
                self.onError?(error.localizedDescription)
            }
        }
    }

    func apply(_ wallpapers: [BridgeNativeVideoWallpaper]) async {
        applyGeneration &+= 1
        let generation = applyGeneration
        let screenIDs = Set(screens().map { $0.id })
        var wanted: [UInt32: BridgeNativeVideoWallpaper] = [:]
        var unseen: [BridgeNativeVideoWallpaper] = []
        for wallpaper in wallpapers {
            if screenIDs.contains(wallpaper.displayId) {
                wanted[wallpaper.displayId] = wallpaper
            } else {
                unseen.append(wallpaper)
            }
        }
        noteUnseen(unseen, screenIDs: screenIDs)
        for (displayID, var state) in states where wanted[displayID] == nil {
            state.phase = .closed
            onStateChanged?(state)
            states.removeValue(forKey: displayID)
        }

        releaseKeptClips()
        // Close first. A wallpaper that moved to another backend, or to another
        // display, must stop playing here before anything else starts, so the
        // clip is never decoded or heard twice. One the display keeps for the
        // desktop the person left is paused instead.
        for (displayID, surface) in surfaces where wanted[displayID] == nil {
            if !keep(displayID: displayID, surface: surface) { closeVacated(displayID: displayID, surface: surface) }
        }
        // A surface is bound to the admission key it was accepted under, not
        // just to a wallpaper id. When the key changes the decision that
        // allowed this player to run no longer applies to what is being asked
        // for: replacing the media at the same path leaves the id untouched.
        // Keeping the player would show the stale file — so the surface is
        // torn down and the new identity goes through admission from the
        // start. A frame-rate target is not part of the identity: the clip
        // plays at its own rate, whatever the target.
        //
        // The decision is taken first and the old surface closed after it. Reading
        // the file can take seconds, and a surface closed before that read would
        // leave the display without a picture for as long (the system picture
        // shows through, or black). The verdict is cached by admission key, so
        // `open` below reuses it, and the old player is still stopped before any
        // new one exists: nothing is decoded or heard twice. Old stops and new
        // surfaces then follow each other without waiting for a file, which is
        // what lets a held picture bridge them.
        var replaced: [(displayID: UInt32, surface: NativeVideoSurface)] = []
        for (displayID, wallpaper) in wanted.sorted(by: { $0.key < $1.key }) {
            guard let existing = descriptors[displayID], let surface = surfaces[displayID] else {
                continue
            }
            if existing.wallpaperId != wallpaper.wallpaperId
                || existing.admissionKey != wallpaper.admissionKey
            {
                // A clip kept for this display was admitted when it opened.
                if kept[displayID]?[wallpaper.wallpaperId]?.descriptor.admissionKey == wallpaper.admissionKey {
                    replaced.append((displayID, surface))
                    continue
                }
                _ = await admission(
                    for: URL(fileURLWithPath: wallpaper.mediaPath), wallpaper: wallpaper, load: nil)
                // The read may have been long; a newer pass or a shutdown took over
                // meanwhile, and what is left of this list is out of date.
                guard !stopped, generation == applyGeneration else { return }
                replaced.append((displayID, surface))
            }
        }
        for (displayID, surface) in replaced where surfaces[displayID] === surface {
            if !keep(displayID: displayID, surface: surface) { close(displayID: displayID, surface: surface) }
        }

        for (displayID, wallpaper) in wanted.sorted(by: { $0.key < $1.key }) {
            // Every open before this one may have waited on a metadata read, and
            // a newer pass can have taken over meanwhile. What is left of this
            // list is then out of date: opening from it would read files
            // nobody wants any more, and updating from it would put an older
            // volume or scaling over what the newer pass already applied.
            guard !stopped, generation == applyGeneration else { break }
            // No local skip list. If the bridge is still offering this key,
            // this host must either play it or say again that it cannot —
            // silently ignoring an offer is how a display ends up with no
            // backend at all.
            //
            // The frame is read when it is used, not once at the top: a display
            // can move or go away while an earlier display's file is read.
            if let surface = surfaces[displayID] {
                if let frame = currentFrame(of: displayID) { surface.setScreenFrame(frame) }
                update(surface: surface, with: wallpaper, displayID: displayID)
                continue
            }
            guard currentFrame(of: displayID) != nil else { continue }
            if resumeKept(wallpaper, displayID: displayID) { continue }
            // A file already found to fail is not opened again for every snapshot: the failure
            // stays what the display and the panel show, and is restated under this offer's
            // startup revision so the bridge's wait for it ends.
            if let refusal = knownFailure(of: wallpaper) {
                if let state = states[displayID], state.phase == .failed,
                    state.nativeAdmissionKey == wallpaper.admissionKey
                {
                    recordState(wallpaper, phase: .failed, message: refusal.reason)
                } else {
                    // Decided while the old surface was being replaced: the first time this offer
                    // is answered, so it is reported, not only restated.
                    fail(wallpaper: wallpaper, refusal: refusal, load: logLoads[displayID])
                }
                continue
            }
            await open(wallpaper: wallpaper, displayID: displayID, generation: generation)
        }
        // A newer pass reports its own result, and reporting this one's would
        // describe a list that has been replaced.
        guard generation == applyGeneration else { return }
        notifySurfacesChanged()
    }

    /// Records the offers for displays this host cannot see, and says so the
    /// first time each one is met.
    ///
    /// Such an offer used to be dropped without a word: the wallpaper never
    /// appeared and nothing in the log said why. It is still not drawn, since
    /// there is no screen to put a window on, but the cause is now on record. No
    /// retry is scheduled. The bridge re-offers the wallpaper on its next
    /// snapshot and a real screen change refreshes the bridge, so the display is
    /// opened by the pass that finds it in the list.
    private func noteUnseen(_ unseen: [BridgeNativeVideoWallpaper], screenIDs: Set<UInt32>) {
        offeredButUnseenDisplayIDsForTest = Set(unseen.map(\.displayId))
        let current = Set(unseen.map { UnseenOffer(displayID: $0.displayId, wallpaperID: $0.wallpaperId) })
        warnedUnseen.formIntersection(current)
        let listed = screenIDs.sorted().map(String.init).joined(separator: ", ")
        for offer in current.sorted(by: { ($0.displayID, $0.wallpaperID) < ($1.displayID, $1.wallpaperID) })
        where warnedUnseen.insert(offer).inserted {
            unseenWarningCountForTest += 1
            AppLog.warn(
                "native video wallpaper \(offer.wallpaperID) is offered for display \(offer.displayID), "
                    + "which this host cannot see (AppKit screens: \(listed.isEmpty ? "none" : listed)); "
                    + "nothing is shown there until the screen lists agree")
        }
    }

    /// The failure this host holds for the offer, so its file is neither read nor opened again: a
    /// settled verdict on the file under its key, or an unsettled failure of this offer's own
    /// revision (a newer revision, from any apply or reconcile, tries the clip again).
    private func knownFailure(of wallpaper: BridgeNativeVideoWallpaper) -> NativeVideoRefusal? {
        if let entry = admissionCache[wallpaper.admissionKey], let refusal = entry, refusal.isSettled {
            return refusal
        }
        if let failed = failures[wallpaper.displayId], failed.key == wallpaper.admissionKey,
            wallpaper.startupRevision <= failed.revision
        {
            return failed.refusal
        }
        return nil
    }

    private func currentFrame(of displayID: UInt32) -> NSRect? {
        screens().first { $0.id == displayID }?.frame
    }

    /// What this display should be opened with, or `nil` when the offer was
    /// overtaken while its file was read.
    ///
    /// Reading a file can take seconds, and the bridge goes on committing
    /// snapshots meanwhile. The reconcile that is running coalesces them into
    /// one trailing pass, which closes whatever the earlier list opened: a
    /// decoder and a visible window built for a wallpaper that was already
    /// replaced. So when a newer pass is queued, the bridge is asked again and
    /// the open goes ahead only if it still wants this wallpaper under this
    /// admission key.
    ///
    /// Asking again, rather than giving up whenever a newer pass is queued, is
    /// what stops a burst of snapshots that keep offering the same wallpaper
    /// (a volume slider being dragged) from starving its open: every pass would
    /// be abandoned by the next one. The answer is the fresher descriptor, so a
    /// clip does not start at the old volume or pause state. If the bridge
    /// cannot be asked, the clip is presented as it was offered and the
    /// trailing pass corrects it.
    private func currentOffer(
        for wallpaper: BridgeNativeVideoWallpaper, displayID: UInt32, generation: UInt64,
        load: UInt64?
    ) async -> BridgeNativeVideoWallpaper? {
        guard !stopped, generation == applyGeneration else { return nil }
        // Nothing newer is queued, so this is still what the bridge holds.
        guard reconcileRequested else { return wallpaper }
        var latest: [BridgeNativeVideoWallpaper]?
        var failure: String?
        do {
            latest = try await fetch()
        } catch {
            failure = error.localizedDescription
        }
        guard !stopped, generation == applyGeneration else { return nil }
        guard let latest else {
            AppLog.warn(
                "native video wallpaper \(wallpaper.wallpaperId): the bridge could not be asked "
                    + "whether it is still wanted (\(failure ?? "unknown error")); presenting it as "
                    + "offered", load: load)
            return wallpaper
        }
        return latest.first {
            $0.displayId == displayID && $0.wallpaperId == wallpaper.wallpaperId
                && $0.admissionKey == wallpaper.admissionKey
        }
    }

    private func open(
        wallpaper: BridgeNativeVideoWallpaper, displayID: UInt32, generation: UInt64
    ) async {
        recordState(wallpaper, phase: .loading)
        let url = URL(fileURLWithPath: wallpaper.mediaPath)
        let load = AppLog.beginLoad("native video", project: wallpaper.mediaPath, detail: """
            wallpaper \(wallpaper.wallpaperId) “\(wallpaper.title)” media \(url.lastPathComponent), \
            \(DiagnosticEnvironment.display(displayID)), \
            scaling \(wallpaper.scalingMode) x\(wallpaper.scalingFactor), paused \(wallpaper.paused)
            """)
        logLoads[displayID] = load
        // Decided before a window exists, so a refusal never shows a black
        // rectangle on the desktop.
        if let refusal = await admission(for: url, wallpaper: wallpaper, load: load) {
            guard !stopped, !Task.isCancelled else { return }
            fail(wallpaper: wallpaper, refusal: refusal, load: load)
            return
        }
        guard !stopped else { return }
        // Admission may have taken a while. Nothing below waits again, so what
        // is decided here is what gets built: a window is only ordered onto the
        // desktop for a wallpaper that is still wanted, on a display that is
        // still there, at the frame it has now. The verdict stays cached, so an
        // abandoned read is not repeated if the wallpaper comes back. The state
        // this left (`loading`, a log entry) is overwritten by the pass that
        // follows, or swept when the display is no longer wanted.
        guard let wallpaper = await currentOffer(
            for: wallpaper, displayID: displayID, generation: generation, load: load)
        else {
            AppLog.info(
                "native video wallpaper \(wallpaper.wallpaperId): superseded while its metadata "
                    + "was read; not presented", load: load)
            return
        }
        guard let frame = currentFrame(of: displayID) else {
            AppLog.info(
                "native video wallpaper \(wallpaper.wallpaperId): \(DiagnosticEnvironment.display(displayID)) "
                    + "is no longer in the screen list; not presented", load: load)
            return
        }
        surfaceGeneration += 1
        let key = RuntimeSurfaceKey(
            kind: .desktopNativeVideo, displayID: displayID, generation: surfaceGeneration)
        let surface = makeSurface(url, frame, key, wallpaper.paused)
        surfaces[displayID] = surface
        descriptors[displayID] = wallpaper
        // Admission read metadata; this covers the asset failing when it is
        // actually played. The generation is checked on the way back in, so a
        // failure from a surface that has since been replaced cannot condemn
        // its successor.
        surface.onPreparationFailure = { [weak self, weak surface] _, detail, settled in
            guard let surface else { return }
            self?.handlePreparationFailure(
                displayID: displayID, surface: surface, detail: detail, settled: settled)
        }
        surface.onAudioDropped = { [weak self, weak surface] detail in
            guard let self, let surface, self.surfaces[displayID] === surface else { return }
            AppLog.warn(
                "native video wallpaper \(wallpaper.wallpaperId): the platform player could not "
                    + "play the clip with its audio (\(detail)); playing it without sound",
                load: self.logLoads[displayID])
        }
        surface.onReadyForDisplay = { [weak self, weak surface] in
            guard let self, let surface, self.surfaces[displayID] === surface,
                  let current = self.descriptors[displayID] else { return }
            self.cancelFirstFrameWatch(displayID)
            self.recordState(current, phase: .ready)
            // The clip has a picture: the held one, if this window carries it, goes. A window
            // that carries none does not mind.
            self.switchHold?.contentReady(displayID: displayID)
        }
        surface.onHealthEvent = { [weak self, weak surface] event in
            guard let self, let surface, self.surfaces[displayID] === surface else { return }
            self.record(health: event, displayID: displayID, surface: surface)
        }
        // Installing the callback can deliver a failure the player was already
        // holding, and that runs the failure synchronously — closing this
        // surface and removing it from the registry before the next line.
        // Presenting anyway would order a stopped window onto the desktop that
        // nothing owns and nothing can close.
        guard surfaces[displayID] === surface else { return }
        update(surface: surface, with: wallpaper, displayID: displayID)
        // The window opens with the picture it replaces over the clip, so that it never
        // reaches the screen black. The veil is on before `present`, which orders it in.
        let holding = adoptHeldPicture(into: surface, displayID: displayID)
        surface.present()
        // A layer that already had its picture when the callback was installed reported it
        // before the veil existed; the veil goes now.
        if holding, surface.isReadyForDisplay { switchHold?.contentReady(displayID: displayID) }
        armFirstFrameWatch(displayID: displayID, surface: surface, url: url, restarted: false)
    }

    /// Puts the picture a switch held for this display over the window about to open. False
    /// when the display holds none, or the window has no layer to carry it.
    private func adoptHeldPicture(into surface: NativeVideoSurface, displayID: UInt32) -> Bool {
        guard let switchHold, let layer = surface.posterLayer else { return false }
        return switchHold.adopt(into: layer, displayID: displayID)
    }

    // MARK: First frame

    /// Starts the wait for a surface's first picture.
    ///
    /// Presenting a window says nothing about whether the clip will ever show.
    /// A clip the platform calls playable can reach `readyToPlay` with its
    /// clock running and still never produce a frame, and no observer fires for
    /// that, so without a deadline the display stays black with the scene
    /// engine excluded and the wallpaper's state stuck at loading. The deadline
    /// follows where the file lives, like the metadata read's: the same clip
    /// takes seconds longer to start from a share than from the internal drive.
    ///
    /// The countdown holds no reference to the host, so a host that is dropped
    /// is not kept alive by a clip that never starts. `location` is passed on
    /// by the second wait of a restarted clip, so the volume is looked at once.
    private func armFirstFrameWatch(
        displayID: UInt32, surface: NativeVideoSurface, url: URL, restarted: Bool,
        location known: NativeVideoStoragePolicy.Location? = nil
    ) {
        cancelFirstFrameWatch(displayID)
        guard !stopped, !surface.isReadyForDisplay else { return }
        let storage = self.storage
        let sleep = self.sleep
        let task = Task { @MainActor [weak self, weak surface] in
            let location: NativeVideoStoragePolicy.Location
            if let known {
                location = known
            } else {
                location = await storage(url)
            }
            guard !Task.isCancelled else { return }
            let limit = NativeVideoStoragePolicy.firstFrameDeadline(location)
            do { try await sleep(limit) } catch { return }
            guard !Task.isCancelled, let self, let surface else { return }
            self.firstFrameDeadlinePassed(
                displayID: displayID, surface: surface, url: url, location: location,
                limit: limit, restarted: restarted)
        }
        firstFrameWatches[displayID] = FirstFrameWatch(task: task, url: url, restarted: restarted)
    }

    private func cancelFirstFrameWatch(_ displayID: UInt32) {
        firstFrameWatches.removeValue(forKey: displayID)?.task?.cancel()
    }

    /// A surface's first-frame deadline passed.
    ///
    /// The surface is judged only if it is still this display's surface, still
    /// has no picture and can show one. A hidden or asleep display is not
    /// judged: the watch waits for it, and starts again with a full deadline
    /// when it returns. A clip that has not shown by then gets one rebuild of
    /// its pipeline and a second deadline of the same length; if that does not
    /// help, or the player has no rebuild left to spend, the display is reported
    /// as failed. The failure is not recorded as a verdict on the file: a slow
    /// volume or a one-off stall is not proof that the clip cannot play, so the
    /// next apply or reconcile tries it again (see `failures`).
    private func firstFrameDeadlinePassed(
        displayID: UInt32, surface: NativeVideoSurface, url: URL,
        location: NativeVideoStoragePolicy.Location, limit: Duration, restarted: Bool
    ) {
        guard !stopped, surfaces[displayID] === surface else { return }
        guard !surface.isReadyForDisplay else {
            firstFrameWatches.removeValue(forKey: displayID)
            return
        }
        if suspended || suspendedDisplays.contains(displayID) {
            firstFrameWatches[displayID] = FirstFrameWatch(
                task: nil, url: url, restarted: restarted)
            return
        }
        counters.record(
            .nativeVideoFirstFrameTimeout,
            for: RuntimeSurfaceKey(kind: .desktopNativeVideo, displayID: displayID))
        let seconds = limit.components.seconds
        let wallpaperID = descriptors[displayID]?.wallpaperId ?? "?"
        let load = logLoads[displayID]
        if !restarted, surface.restartPlayback(reason: "no first frame within \(seconds) s") {
            AppLog.warn(
                "native video wallpaper \(wallpaperID): no first frame within \(seconds) s "
                    + "(\(location.label)); \(surface.stateSummary); restarting playback once",
                load: load)
            armFirstFrameWatch(
                displayID: displayID, surface: surface, url: url, restarted: true,
                location: location)
            return
        }
        firstFrameWatches.removeValue(forKey: displayID)
        let detail = "no first frame within \(seconds) s\(restarted ? " after one restart" : ""): "
            + surface.stateSummary
        handlePreparationFailure(
            displayID: displayID, surface: surface, detail: detail, settled: false)
    }

    // MARK: Health

    /// Logs and counts what a health check found at one look.
    ///
    /// The surface repairs its own pipeline (a kick, one rebuild, then a
    /// preparation failure that `handlePreparationFailure` turns into a failed
    /// display), so this only reports. A stall is counted once per check, at
    /// the first look: the looks that follow a repair are the same stall seen
    /// again, and the kick and rebuild counters say how far it went.
    private func record(
        health event: NativeVideoHealthEvent, displayID: UInt32, surface: NativeVideoSurface
    ) {
        let wallpaperID = descriptors[displayID]?.wallpaperId ?? "?"
        let load = logLoads[displayID]
        let subject = "native video wallpaper \(wallpaperID)"
        let next: String
        switch event.next {
        case .done: next = ""
        case .recheck: next = "; looking again"
        case .kick: next = "; kicking it with a seek and play"
        case .rebuild: next = "; rebuilding its pipeline"
        case .giveUp: next = "; giving up on it"
        }
        let after: String
        switch event.stage {
        case .initial: after = event.trigger
        case .afterKick: after = "a kick (\(event.trigger))"
        case .afterRebuild: after = "a rebuild (\(event.trigger))"
        }
        switch event.verdict {
        case .advancing:
            let line = "\(subject): playback advancing after \(after)"
            // A repair that worked is worth a line of its own; a healthy
            // pipeline is not.
            if event.stage == .initial {
                AppLog.debug(line, load: load)
            } else {
                AppLog.info(line, load: load)
            }
        case let .waiting(detail):
            let line = "\(subject): playback not judged after \(after): \(detail)\(next)"
            if event.next == .recheck || event.next == .done {
                AppLog.debug(line, load: load)
            } else {
                // The player went on waiting long enough to be treated as stuck.
                AppLog.warn(line, load: load)
            }
        case let .stalled(detail):
            if event.stage == .initial {
                counters.record(
                    .nativeVideoPlaybackStalled,
                    for: RuntimeSurfaceKey(kind: .desktopNativeVideo, displayID: displayID))
            }
            AppLog.warn(
                "\(subject): playback did not advance after \(after): \(detail) "
                    + "(\(surface.stateSummary))\(next)", load: load)
        }
    }

    /// Starts the countdown again for a parked watch whose display can be
    /// judged once more.
    private func resumeParkedFirstFrameWatch(_ displayID: UInt32) {
        guard !suspended, !suspendedDisplays.contains(displayID),
            let watch = firstFrameWatches[displayID], watch.task == nil,
            let surface = surfaces[displayID]
        else { return }
        armFirstFrameWatch(
            displayID: displayID, surface: surface, url: watch.url, restarted: watch.restarted)
    }

    /// The player could not play an asset admission had accepted.
    ///
    /// A different failure from a metadata refusal, handled the same way: the surface is closed, the
    /// display is reported as failed with the reason, and nothing takes the clip over, because
    /// nothing else can play it. `settled` says whether the failure is a verdict on the file. A
    /// decoder that could not open the track is, and is remembered under the file's key, so the
    /// same file is not opened again until it changes. A clip that merely never showed a frame in
    /// time, or whose pipeline stalled and was not revived by the repairs (the system can take the
    /// decoder back while the Mac sleeps), is not: it is remembered for this offer's revision only,
    /// and the next apply or reconcile opens it afresh.
    private func handlePreparationFailure(
        displayID: UInt32, surface: NativeVideoSurface, detail: String, settled: Bool = true
    ) {
        guard !stopped, let wallpaper = descriptors[displayID] else { return }
        // Staleness is identity, not a counter. `surfaceGeneration` is
        // host-wide and moves whenever ANY display opens a surface, so
        // comparing against it discards a live display's real failure as soon
        // as a second display has opened since.
        guard surfaces[displayID] === surface else { return }
        let refusal = NativeVideoRefusal.playbackFailed(detail)
        let load = logLoads[displayID]
        close(displayID: displayID, surface: surface)
        // The window the held picture sat on is closed, and nothing takes its place.
        switchHold?.cancel(displays: [displayID])
        if settled { admissionCache[wallpaper.admissionKey] = refusal }
        fail(wallpaper: wallpaper, refusal: refusal, load: load)
        notifySurfacesChanged()
    }

    /// The admission decision for one offer, taken at most once per admission
    /// key. The key already covers the media file's identity and every setting
    /// the decision depends on, so a cache hit cannot return a verdict for a
    /// configuration that has since changed, and a reconcile storm cannot turn
    /// into repeated file reads.
    ///
    /// An unsettled failure — metadata that could not be read, as opposed to
    /// content this backend cannot play — is retried a bounded number of
    /// times before it is reported, and is never cached as a verdict. Without
    /// that split, one I/O blip would fail a wallpaper for the rest of the
    /// session; without the bound, a file that never loads would hold the
    /// reconcile pass for as long as it is offered.
    ///
    /// Every read is also bounded in time, by where the file lives. Admission
    /// runs inside the one reconcile pass, so a read that never returns — a
    /// disk that will not spin up, a share that went away, an evicted cloud
    /// file — would otherwise hold every other display's open, close and pause
    /// behind it. A read that outlives its limit ends the attempt at once: the
    /// budget is already spent, so it is neither retried nor cached.
    ///
    /// Not caching it is all this host can do about it. The display is reported
    /// as failed for this offer's revision (see `failures`) and the file is read
    /// afresh when the bridge offers it again under a newer one.
    private func admission(
        for url: URL, wallpaper: BridgeNativeVideoWallpaper, load: UInt64?
    ) async -> NativeVideoRefusal? {
        if let cached = admissionCache[wallpaper.admissionKey] { return cached }
        // At most one read per file. The earlier one is still blocked, and
        // starting another would only add a second blocked call on the same
        // volume.
        if outstandingProbes[url.path] != nil { return Self.probeStillPending }
        let location = await storage(url)
        guard !stopped, !Task.isCancelled else { return Self.probeAbandoned }
        let limit = NativeVideoStoragePolicy.metadataProbeDeadline(location)
        // A mirror cannot fall back on its own — the engine only ever gives it
        // a scene by copying its source's — so the group shares its source's
        // key and is judged once, on the file all of it plays.
        var read = await boundedProbe(
            url: url, wallpaper: wallpaper, location: location, limit: limit, load: load)
        var attempt = 1
        while !read.abandoned, let unsettled = read.decision, !unsettled.isSettled,
            attempt < Self.admissionAttemptLimit
        {
            attempt += 1
            AppLog.warn(
                "native video wallpaper \(wallpaper.wallpaperId): \(unsettled.reason); "
                    + "retrying (\(attempt)/\(Self.admissionAttemptLimit))", load: load)
            try? await Task.sleep(for: Self.admissionRetryDelay)
            guard !stopped else { return unsettled }
            read = await boundedProbe(
                url: url, wallpaper: wallpaper, location: location, limit: limit, load: load)
        }
        // Not a verdict about the file: the next offer starts afresh.
        if read.abandoned { return read.decision }
        admissionCache[wallpaper.admissionKey] = read.decision
        admissionCacheOrder.append(wallpaper.admissionKey)
        while admissionCacheOrder.count > Self.admissionCacheLimit {
            admissionCache.removeValue(forKey: admissionCacheOrder.removeFirst())
        }
        return read.decision
    }

    /// One metadata read, given up on after `limit`.
    ///
    /// `abandoned` means the read neither answered nor failed in time, so its
    /// refusal says nothing about the file and must be neither retried nor
    /// remembered. The read itself is not killed — it may be blocked where
    /// cancellation cannot reach — so it stays in `outstandingProbes` until it
    /// returns on its own, and no second read of that file starts meanwhile.
    ///
    /// The file is entered in `outstandingProbes` by the read itself, when it
    /// starts, not by this method before the race. A caller that is already
    /// cancelled gets `.cancelled` back without the read ever running, and an
    /// entry made for a read that never began would have nothing to remove it:
    /// every later offer of that file would be refused as still being read.
    private func boundedProbe(
        url: URL, wallpaper: BridgeNativeVideoWallpaper,
        location: NativeVideoStoragePolicy.Location, limit: Duration, load: UInt64?
    ) async -> (decision: NativeVideoRefusal?, abandoned: Bool) {
        let path = url.path
        probeSerial += 1
        let serial = probeSerial
        let refusal = self.refusal
        let outcome = await NativeVideoDeadline.race(limit, sleep: sleep) { [weak self] in
            self?.outstandingProbes[path] = serial
            let decision = await refusal(url)
            if self?.outstandingProbes[path] == serial { self?.outstandingProbes[path] = nil }
            return decision
        }
        switch outcome {
        case let .value(decision):
            return (decision, false)
        case .cancelled:
            return (Self.probeAbandoned, true)
        case .timedOut:
            guard !stopped else { return (Self.probeAbandoned, true) }
            let reason = "the metadata read did not finish within \(limit.components.seconds) s "
                + "(\(location.label))"
            counters.record(
                .nativeVideoProbeTimeout,
                for: RuntimeSurfaceKey(kind: .desktopNativeVideo, displayID: wallpaper.displayId))
            AppLog.warn(
                "native video wallpaper \(wallpaper.wallpaperId): \(reason); giving up on it "
                    + "and not reading this file again until that read returns", load: load)
            return (.preparationFailed(reason), true)
        }
    }

    /// Answers for an offer whose file already has a read that has not
    /// returned. Unsettled, like the timeout it follows from.
    private static let probeStillPending = NativeVideoRefusal.preparationFailed(
        "an earlier metadata read of this file has not returned")
    private static let probeAbandoned = NativeVideoRefusal.preparationFailed(
        "the metadata read was abandoned")

    /// Reports a wallpaper this host cannot play.
    ///
    /// The display is reported as failed with the reason and keeps the picture it had: no window
    /// covers it, and nothing else plays the clip. Counted and logged once per failure (an offer
    /// that is already known to have failed is restated, not logged again). An unsettled failure is
    /// remembered for this offer's revision; see `failures`.
    private func fail(
        wallpaper: BridgeNativeVideoWallpaper, refusal: NativeVideoRefusal, load: UInt64?
    ) {
        recordState(wallpaper, phase: .failed, message: refusal.reason)
        if !refusal.isSettled {
            failures[wallpaper.displayId] = FailedOffer(
                key: wallpaper.admissionKey, revision: wallpaper.startupRevision, refusal: refusal)
        }
        counters.record(
            .nativeVideoRefused,
            for: RuntimeSurfaceKey(kind: .desktopNativeVideo, displayID: 0))
        AppLog.warn(
            "native video wallpaper \(wallpaper.wallpaperId): \(refusal.reason); "
                + "not played, the previous picture stays", load: load)
        // Nothing will cover the display, so a picture held for a successor is not waiting for one.
        switchHold?.engineSettled(displays: [wallpaper.displayId])
    }

    private func update(
        surface: NativeVideoSurface, with wallpaper: BridgeNativeVideoWallpaper,
        displayID: UInt32
    ) {
        let priorDescriptor = descriptors[displayID]
        descriptors[displayID] = wallpaper
        surface.setVolume(wallpaper.volume, muted: wallpaper.muted)
        // A scaling change moves the picture on a running surface; it neither
        // reopens it nor re-reads the file. Logged under the clip's load so a
        // report shows which choice the picture followed.
        if let before = priorDescriptor, before.scalingMode != wallpaper.scalingMode
            || before.scalingFactor != wallpaper.scalingFactor
            || before.framing != wallpaper.framing
        {
            AppLog.debug(
                "native video wallpaper \(wallpaper.wallpaperId): scaling "
                    + "\(before.scalingMode) x\(before.scalingFactor) at "
                    + "\(before.framing.panX),\(before.framing.panY) -> "
                    + "\(wallpaper.scalingMode) x\(wallpaper.scalingFactor) at "
                    + "\(wallpaper.framing.panX),\(wallpaper.framing.panY)",
                load: logLoads[displayID])
        }
        surface.setScaling(
            wallpaper.scalingMode, factor: wallpaper.scalingFactor,
            pan: .init(x: wallpaper.framing.panX, y: wallpaper.framing.panY))
        // The descriptor's paused flag already carries the user's own choice
        // and this display's suspension, as the activation rules combined them.
        surface.setUserPaused(wallpaper.paused)
        surface.setPresentationSuspended(suspended || suspendedDisplays.contains(displayID))
        if surface.isReadyForDisplay { recordState(wallpaper, phase: .ready) }
        else if let prior = states[displayID], prior.startupRevision != wallpaper.startupRevision {
            recordState(wallpaper, phase: prior.phase, message: prior.message)
        }
    }

    private func recordState(
        _ wallpaper: BridgeNativeVideoWallpaper, phase: HostWallpaperState.Phase, message: String? = nil
    ) {
        let state = HostWallpaperState(kind: .nativeVideo, displayID: wallpaper.displayId,
            wallpaperID: wallpaper.wallpaperId, startupRevision: wallpaper.startupRevision,
            nativeAdmissionKey: wallpaper.admissionKey, phase: phase, message: message)
        guard states[wallpaper.displayId] != state else { return }
        states[wallpaper.displayId] = state
        onStateChanged?(state)
    }

    /// Closes the window of a display that has no native clip to show any more, because its
    /// wallpaper went to another backend, was ejected, or the display is gone.
    ///
    /// A held picture that sat on this very window goes with it: nothing here takes its place,
    /// and kept for the rest of its ceiling it would be taken for what is on screen by the next
    /// switch and shown again, out of date. A picture that still waits for a window, or sits on
    /// a scene, is not this window's and stays for its successor. A window that is closed to be
    /// replaced does not come through here: its successor takes the picture with `adopt`.
    private func closeVacated(displayID: UInt32, surface: NativeVideoSurface) {
        let layer = surface.posterLayer
        close(displayID: displayID, surface: surface)
        switchHold?.windowClosed(layer, displayID: displayID)
    }

    /// Pauses the clip of a display that moves on to another wallpaper and keeps it, when the
    /// display may keep that wallpaper for the desktop the person left and the clip has a picture
    /// to show there. False when it is to be closed instead.
    private func keep(displayID: UInt32, surface: NativeVideoSurface) -> Bool {
        guard let descriptor = descriptors[displayID], surface.isReadyForDisplay,
              keepPlan[displayID]?.contains(descriptor.wallpaperId) == true else { return false }
        let load = logLoads[displayID]
        cancelFirstFrameWatch(displayID)
        recordState(descriptor, phase: .closed)
        states.removeValue(forKey: displayID)
        surface.setUserPaused(true)
        surfaces.removeValue(forKey: displayID)
        descriptors.removeValue(forKey: displayID)
        kept[displayID]?[descriptor.wallpaperId]?.surface.stop()
        kept[displayID, default: [:]][descriptor.wallpaperId] = KeptClip(surface: surface, descriptor: descriptor, load: load)
        AppLog.info("native video wallpaper \(descriptor.wallpaperId): kept paused on "
            + "\(DiagnosticEnvironment.display(displayID)) for the desktop the person left", load: load)
        return true
    }

    /// Makes the clip the display keeps for `wallpaper` its live one again, when it is the same
    /// file: no admission, no new window, no wait for a first picture.
    private func resumeKept(_ wallpaper: BridgeNativeVideoWallpaper, displayID: UInt32) -> Bool {
        guard let clip = kept[displayID]?[wallpaper.wallpaperId] else { return false }
        kept[displayID]?[wallpaper.wallpaperId] = nil
        if kept[displayID]?.isEmpty == true { kept[displayID] = nil }
        guard clip.descriptor.admissionKey == wallpaper.admissionKey else {
            clip.surface.stop()
            return false
        }
        surfaces[displayID] = clip.surface
        descriptors[displayID] = clip.descriptor
        logLoads[displayID] = clip.load
        if let frame = currentFrame(of: displayID) { clip.surface.setScreenFrame(frame) }
        update(surface: clip.surface, with: wallpaper, displayID: displayID)
        AppLog.info("native video wallpaper \(wallpaper.wallpaperId): runs again on "
            + "\(DiagnosticEnvironment.display(displayID)) without opening", load: clip.load)
        return true
    }

    /// Closes the kept clips whose display may no longer keep them or is gone, and keeps the
    /// others fitted to their display.
    private func releaseKeptClips() {
        for (displayID, clips) in kept {
            let frame = currentFrame(of: displayID)
            for (wallpaper, clip) in clips {
                if let frame, keepPlan[displayID]?.contains(wallpaper) == true {
                    clip.surface.setScreenFrame(frame)
                    continue
                }
                clip.surface.stop()
                kept[displayID]?[wallpaper] = nil
                AppLog.info("native video wallpaper \(wallpaper): no longer kept on "
                    + "\(DiagnosticEnvironment.display(displayID))", load: clip.load)
            }
            if kept[displayID]?.isEmpty == true { kept[displayID] = nil }
        }
    }

    private func close(displayID: UInt32, surface: NativeVideoSurface) {
        cancelFirstFrameWatch(displayID)
        if let wallpaper = descriptors[displayID] { recordState(wallpaper, phase: .closed) }
        states.removeValue(forKey: displayID)
        surface.stop()
        surfaces.removeValue(forKey: displayID)
        descriptors.removeValue(forKey: displayID)
    }

    /// Global suspension: no display can show a wallpaper pixel at all.
    func setPresentationSuspended(_ value: Bool) {
        suspended = value
        for (displayID, surface) in surfaces {
            surface.setPresentationSuspended(value || suspendedDisplays.contains(displayID))
        }
        if !value {
            for displayID in Array(firstFrameWatches.keys) { resumeParkedFirstFrameWatch(displayID) }
        }
    }

    /// One display's own suspension. A hidden screen must not stop a visible
    /// one, and resuming must not clear the global reason.
    func setPresentationSuspended(_ value: Bool, forDisplay displayID: UInt32) {
        if value {
            suspendedDisplays.insert(displayID)
        } else {
            suspendedDisplays.remove(displayID)
        }
        guard let surface = surfaces[displayID] else { return }
        surface.setPresentationSuspended(suspended || value)
        if !value { resumeParkedFirstFrameWatch(displayID) }
    }

    func shutdown() {
        stopped = true
        if let posterObserver {
            frameCenter.removeObserver(posterObserver)
            self.posterObserver = nil
        }
        for observer in wakeObservers { workspaceCenter.removeObserver(observer) }
        wakeObservers.removeAll()
        wakeTask?.cancel()
        wakeTask = nil
        for (displayID, surface) in surfaces {
            close(displayID: displayID, surface: surface)
        }
        surfaces.removeAll()
        descriptors.removeAll()
        for clip in kept.values.flatMap(\.values) { clip.surface.stop() }
        kept.removeAll()
        keepPlan.removeAll()
        for watch in firstFrameWatches.values { watch.task?.cancel() }
        firstFrameWatches.removeAll()
        admissionCache.removeAll()
        admissionCacheOrder.removeAll()
        failures.removeAll()
        outstandingProbes.removeAll()
        offeredButUnseenDisplayIDsForTest.removeAll()
        warnedUnseen.removeAll()
    }

    /// Answers a desktop poster request from the player that is already
    /// running. A second player would decode the same clip twice.
    private func answerPosterRequest(_ notification: Notification) {
        guard let layer = notification.object as? CALayer,
            let (displayID, surface) = surfaces.first(where: { $0.value.posterLayer === layer })
        else { return }
        let context = notification.userInfo?["context"] as? String
        Task { @MainActor [weak self] in
            let image = await surface.posterImage()
            guard let self, !self.stopped, let image else { return }
            // The surface that answered must still be this display's surface.
            // A poster produced by a wallpaper that has since been replaced is
            // a frame of the wrong clip, and publishing it would show it.
            guard self.surfaces[displayID] === surface, surface.posterLayer === layer,
                  let frame = DesktopPosterFrame.rgba(image) else { return }
            frame.publish(for: layer, to: self.frameCenter, context: context)
        }
    }

    private func notifySurfacesChanged() {
        onSurfacesChanged?()
    }
}
