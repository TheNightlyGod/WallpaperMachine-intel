import AVFoundation
import AppKit
import VideoToolbox

/// Owns the `AVQueuePlayer` / `AVPlayerLooper` / `AVPlayerLayer` trio for one
/// display.
///
/// `AVPlayerLooper` is what makes gapless looping the system's problem rather
/// than ours; it keeps more than one copy of the item queued by design, which
/// is why the counters report queued items rather than claiming a single one.
@MainActor
final class NativeVideoPlayer {
    /// Ceiling on how long one poster request will wait for the playing item
    /// to hand over a frame before falling back. Bounded so a stalled item
    /// cannot hold a request open, and short enough that a poster request is
    /// never mistaken for a reason to keep the decoder awake.
    static let posterWaitStep = Duration.milliseconds(25)
    static let posterWaitSteps = 12

    private let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private let layer = AVPlayerLayer()
    private let surface: RuntimeSurfaceKey
    private let counters: RuntimeCounters
    /// The user's own Play/Pause choice, kept apart from presentation
    /// suspension so revealing a display never overrides it.
    private var userPaused: Bool
    private var presentationSuspended = false
    private var stopped = false

    /// Attached only while a poster request is in flight, and always to the
    /// item that is playing right now rather than to the looper's template.
    /// A permanently attached output would mean a second, continuous readback
    /// of every frame for a picture nobody asked for.
    private var videoOutput: AVPlayerItemVideoOutput?
    private weak var outputItem: AVPlayerItem?
    /// The single in-flight poster request. Concurrent callers await this one
    /// instead of each opening their own read path.
    private var posterRequest: Task<CGImage?, Never>?
    /// Last frame this player actually produced. A paused player answers from
    /// here rather than resuming to make a picture.
    private var lastPoster: CGImage?
    /// KVO on the item's and the looper's status. Held for the player's life
    /// so a failure that arrives late still reaches the host.
    private var statusObservations: [NSKeyValueObservation] = []
    /// Status observation for the item that is playing right now, re-pointed
    /// as the loop replaces it.
    private var currentItemObservation: NSKeyValueObservation?
    private weak var observedItem: AVPlayerItem?
    private var failureReported = false
    /// The file this player was loaded with. Once the audio has been dropped
    /// the playing item's asset is a composition, so the poster fallback and
    /// the silent rebuild open the file from here rather than from the item.
    private var mediaURL: URL?
    /// Set once the item carrying the clip's audio has failed and been
    /// replaced by a video-only one. One attempt only: a failure of the
    /// video-only item is about the picture and goes to the host.
    private var audioDropped = false
    /// The one in-flight rebuild of the item, whether it is the first load,
    /// the silent fallback above or a restart the host asked for. A second
    /// repair never starts while one is pending.
    private var rebuild: Task<Void, Never>?
    /// How many times this surface may rebuild its pipeline before the host
    /// has to give the wallpaper up. Owned here, one per surface, so it
    /// outlives every item the player replaces.
    private var recovery: NativeVideoRecoveryBudget
    private let now: @MainActor () -> ContinuousClock.Instant
    /// The clip's display matrix, read once at load. `nil` until the read
    /// finishes; a clip whose matrix cannot be read is treated as upright.
    ///
    /// The picture the layer shows has this matrix applied, but the frames a
    /// video output hands back do not, so it decides which poster path can be
    /// trusted for an upright result.
    private var displayTransform: CGAffineTransform?
    private var orientationTask: Task<Void, Never>?

    /// Looks at the pipeline after a long pause. Owned here because its verdict
    /// is about this player's item, and it dies with the player.
    private let supervisor: NativeVideoHealthSupervisor
    private let healthPolicy: NativeVideoHealthSupervisor.Policy
    /// Since when the player has not been playing, whatever the reason: the
    /// user's pause and a hidden display both stop the decoder. `nil` while it
    /// plays.
    private var pausedSince: ContinuousClock.Instant?
    /// Whether a picture has ever been on the layer. A pipeline that never
    /// showed one is the first-frame watch's to judge, not the health check's.
    private var hasShownFrame = false
    /// Attached only while a health check is sampling, and to the item playing
    /// at that moment. It takes the source's own pixel format, so reading it
    /// converts nothing.
    private var livenessOutput: AVPlayerItemVideoOutput?
    private weak var livenessItem: AVPlayerItem?

    /// What the user chose, and the geometry it is applied to. The layer is
    /// positioned from these by `applyPlacement`, never by autoresizing: a
    /// picture that is larger or smaller than its display has to follow the
    /// layout rules, not the view's edges.
    private var scalingMode: BridgeScalingMode = .fill
    private var scalingFactor = 1.0
    private var scalingPan = NativeVideoLayout.Pan.centered
    private var viewportBounds = CGRect.zero
    private var backingScale: CGFloat = 1
    /// The size the picture is shown at, rotation applied, as the playing item
    /// reports it. `nil` until an item has reported one; a loop copy that has
    /// not loaded yet reports zero, which says nothing and is ignored.
    private var presentationSize: CGSize?
    /// Follows the playing item's `presentationSize`, re-pointed with it.
    private var sizeObservation: NSKeyValueObservation?
    /// Reported when the clip keeps playing without its audio, with the
    /// failure that caused it, so the host can log it against its load.
    var onAudioDropped: (@MainActor (String) -> Void)?
    /// What each look of a health check concluded, and what the check does
    /// next. Reported for the host's log; the repair itself is the player's.
    var onHealthEvent: (@MainActor (NativeVideoHealthEvent) -> Void)?
    /// A failure seen before anyone was listening. The host installs its
    /// callback after constructing the surface, and a synchronous failure at
    /// load would otherwise be dropped on the floor — which is the one case
    /// where the display ends up black with no hand-off.
    private var pendingFailure: (detail: String, settled: Bool)?
    var isReadyForDisplay: Bool { !stopped && layer.isReadyForDisplay }
    var onReadyForDisplay: (@MainActor () -> Void)? {
        didSet { if isReadyForDisplay { onReadyForDisplay?() } }
    }

    /// Reported when the platform player cannot prepare or play the asset,
    /// with this surface's generation so a late failure cannot be attributed
    /// to whatever replaced it. The last argument is whether the failure is a
    /// verdict on the file; see `NativeVideoSurface.onPreparationFailure`.
    var onPreparationFailure: (@MainActor (UInt64, String, Bool) -> Void)? {
        didSet {
            guard let pendingFailure, onPreparationFailure != nil else { return }
            self.pendingFailure = nil
            onPreparationFailure?(surface.generation, pendingFailure.detail, pendingFailure.settled)
        }
    }

    init(
        surface: RuntimeSurfaceKey,
        counters: RuntimeCounters,
        paused: Bool,
        recovery: NativeVideoRecoveryBudget.Policy = .init(),
        health: NativeVideoHealthSupervisor.Policy = .init(),
        now: @escaping @MainActor () -> ContinuousClock.Instant = { .now },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.surface = surface
        self.counters = counters
        self.userPaused = paused
        self.recovery = NativeVideoRecoveryBudget(policy: recovery)
        self.now = now
        self.healthPolicy = health
        self.supervisor = NativeVideoHealthSupervisor(policy: health, sleep: sleep)
        player.actionAtItemEnd = .advance
        // Nothing here needs the system's "now playing" treatment, and taking
        // the audio session focus would interrupt whatever the user is
        // listening to.
        player.preventsDisplaySleepDuringVideoPlayback = false
        layer.player = player
        layer.videoGravity = .resizeAspectFill
        supervisor.target = self
    }

    func attach(to view: NSView) {
        // A picture larger than the display (Fill, Original size, a scale
        // factor above one) overflows its layer's parent; the overflow is
        // cropped here, so it never spills over a neighbouring display's
        // window or the desktop around it.
        view.layer?.masksToBounds = true
        view.layer?.addSublayer(layer)
        relayout(bounds: view.bounds, backingScale: view.window?.backingScaleFactor ?? 1)
    }

    /// The display's size or pixel density changed. Called by the view that
    /// hosts the layer, synchronously, so a resize never shows the picture at
    /// its old geometry for a frame.
    func relayout(bounds: CGRect, backingScale: CGFloat) {
        viewportBounds = bounds
        self.backingScale = backingScale
        applyPlacement()
    }

    /// Positions the layer for the current scaling choice, picture size and
    /// display geometry.
    private func applyPlacement() {
        guard !stopped else { return }
        let placement = NativeVideoLayout.placement(
            mode: scalingMode.layoutMode, factor: scalingFactor, videoSize: presentationSize,
            viewport: viewportBounds.size, backingScale: backingScale, pan: scalingPan)
        // Implicit animation would visibly slide the picture to its new place
        // every time the display is resized or the user changes the mode.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        switch placement {
        case .gravity(let gravity):
            layer.videoGravity = gravity
            layer.frame = viewportBounds
        case .frame(let rect):
            // The rectangle already has the picture's own aspect; anything but
            // a plain stretch would re-apply an aspect rule to it.
            layer.videoGravity = .resize
            // The layout measures from the top edge and the container's layer
            // grows upward, so the rectangle is flipped into it.
            layer.frame = NativeVideoLayout.layerFrame(
                rect, viewportHeight: viewportBounds.height
            ).offsetBy(dx: viewportBounds.minX, dy: viewportBounds.minY)
        case .pending:
            break
        }
    }

    func load(url: URL) {
        mediaURL = url
        let item = AVPlayerItem(url: url)
        readDisplayTransform(of: item.asset)
        // Held as the pending rebuild so a repair cannot start an item of its
        // own before this one is playing, and `stop()` cancels it.
        rebuild = Task { @MainActor [weak self] in
            let range = await Self.loopRange(of: item.asset)
            guard let self, !self.stopped, !Task.isCancelled else { return }
            self.rebuild = nil
            self.start(item, looping: range)
        }
    }

    /// The stretch of the file one pass of the loop plays: the video track's
    /// own time range, or `.invalid` (the whole item) when it cannot be read.
    ///
    /// An unbounded looper ends each pass at the end of the item, which a clip
    /// with sound reaches only once its audio has drained. Even muted, and
    /// even when both tracks report the same duration, that held a 4K clip's
    /// last frame for about a quarter of a second at every seam (issue 76);
    /// bounded by the picture, the seam is as smooth as any other frame.
    nonisolated static func loopRange(of asset: AVAsset) async -> CMTimeRange {
        guard let video = try? await asset.loadTracks(withMediaType: .video).first,
            let range = try? await video.load(.timeRange),
            range.isValid, range.start.isNumeric, range.duration.isNumeric,
            range.duration > .zero
        else { return .invalid }
        return range
    }

    /// Reads the display matrix from the asset the player itself is loading,
    /// so the file is not opened a second time for it.
    private func readDisplayTransform(of asset: AVAsset) {
        orientationTask?.cancel()
        orientationTask = Task { @MainActor [weak self] in
            let transform: CGAffineTransform
            do {
                transform = try await Self.loadDisplayTransform(of: asset)
            } catch {
                AppLog.debug(
                    "native video: could not read the clip's orientation "
                        + "(\(Self.describe(error))); treating it as upright")
                transform = .identity
            }
            guard let self, !self.stopped, !Task.isCancelled else { return }
            self.displayTransform = transform
        }
    }

    /// The display matrix of the clip's first video track, or the identity for
    /// a clip with no video track.
    nonisolated static func loadDisplayTransform(of asset: AVAsset) async throws
        -> CGAffineTransform
    {
        guard let video = try await asset.loadTracks(withMediaType: .video).first else {
            return .identity
        }
        return try await video.load(.preferredTransform)
    }

    /// Whether a frame read back from a video output differs in orientation
    /// from the picture the layer shows.
    ///
    /// Any rotation or flip does: `AVPlayerItem.presentationSize` and the layer
    /// follow the matrix, while the output's buffers stay in the file's own
    /// orientation. Such a clip is read with `AVAssetImageGenerator`, which
    /// applies the matrix itself.
    nonisolated static func needsUprightGenerator(_ transform: CGAffineTransform) -> Bool {
        !transform.isIdentity
    }

    private func start(_ item: AVPlayerItem, looping range: CMTimeRange) {
        // AVPlayerLooper takes ownership of the queue, so it is created once
        // per item and replaced wholesale rather than mutated.
        let looper = AVPlayerLooper(player: player, templateItem: item, timeRange: range)
        self.looper = looper
        counters.record(.nativeVideoItemCreated, for: surface)
        observeFailures(looper: looper)
        applyPlaybackState()
    }

    /// Takes the looper and its queued copies down, leaving the player and
    /// its layer in place for whatever is loaded next.
    private func releaseItem(cancellingCheck: Bool = true) {
        guard let looper else { return }
        // Removing the queue makes the item fail on its way out; that is this
        // teardown, not a fault worth reacting to.
        statusObservations.removeAll()
        currentItemObservation = nil
        sizeObservation = nil
        observedItem = nil
        // A check in flight describes the item that is going away, unless it is
        // the check that is replacing it.
        if cancellingCheck { supervisor.cancel() }
        detachLivenessOutput()
        detachPosterOutput()
        // The looper holds the queue; disabling it first stops it re-filling
        // the queue while the items are being removed.
        looper.disableLooping()
        self.looper = nil
        player.removeAllItems()
        counters.record(.nativeVideoItemReleased, for: surface)
    }

    /// Watches for the asset turning out to be unplayable after admission
    /// already accepted it.
    ///
    /// Admission reads metadata; this is playback. A track whose properties
    /// load cleanly can still fail to decode — a truncated file, a codec this
    /// machine cannot play, a busy decoder. Nothing else observes that, so
    /// without this the wallpaper stays selected by a backend that cannot show
    /// it while the scene engine is excluded.
    ///
    /// **Not the template item.** `AVPlayerLooper` does not play the item it
    /// was constructed with; it enqueues copies of it. Observing the template
    /// watches an object that never plays and never fails, which is a fault
    /// that no fake-surface test can see. What matters is whatever
    /// `currentItem` is at the time, and the loop replaces that, so the
    /// observation follows it.
    private func observeFailures(looper: AVPlayerLooper) {
        statusObservations = [
            layer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
                guard layer.isReadyForDisplay else { return }
                Task { @MainActor [weak self] in
                    guard let self, !self.stopped else { return }
                    // A frame on the layer is the evidence that earns the
                    // rebuild allowance back, once it has lasted.
                    self.hasShownFrame = true
                    self.recovery.healthy(at: self.now())
                    self.onReadyForDisplay?()
                }
            },
            // `.initial` matters: the looper can already be `.failed` by the
            // time this runs, and a `.new`-only subscription would miss it.
            looper.observe(\.status, options: [.initial, .new]) { [weak self] looper, _ in
                guard looper.status == .failed else { return }
                let detail = looper.error.map(Self.describe) ?? "player looper failed"
                MainActor.assumeIsolated { self?.playbackFailed(detail) }
            },
            player.observe(\.currentItem, options: [.initial, .new]) { [weak self] player, _ in
                MainActor.assumeIsolated { self?.followCurrentItem(player.currentItem) }
            },
        ]
    }

    /// Re-points the item-status observation at whatever is playing now.
    private func followCurrentItem(_ item: AVPlayerItem?) {
        guard !stopped else { return }
        guard let item else {
            currentItemObservation = nil
            sizeObservation = nil
            return
        }
        guard item !== observedItem else { return }
        observedItem = item
        currentItemObservation = item.observe(\.status, options: [.initial, .new]) {
            [weak self] item, _ in
            guard item.status == .failed else { return }
            let detail = item.error.map(Self.describe) ?? "player item failed"
            MainActor.assumeIsolated { self?.playbackFailed(detail) }
        }
        // The picture's size is what Fit, Original size and the scale factor
        // are computed from, and it only exists once the item has loaded.
        sizeObservation = item.observe(\.presentationSize, options: [.initial, .new]) {
            [weak self] item, _ in
            let size = item.presentationSize
            MainActor.assumeIsolated { self?.presentationSizeChanged(size) }
        }
    }

    private func presentationSizeChanged(_ size: CGSize) {
        guard !stopped, size.width > 0, size.height > 0, size != presentationSize else { return }
        presentationSize = size
        applyPlacement()
    }

    /// The platform player failed. A clip with sound gets one more attempt
    /// without it before the host is told.
    ///
    /// AVFoundation fails the whole item when its audio output cannot start —
    /// no output device, or one that will not start (`kAudioQueueErr_CannotStart`)
    /// — and reports it as the generic `AVErrorUnknown`, with nothing that
    /// says which half of the clip failed. Muting does not help: the muted
    /// player still starts the audio queue. Handing that to the scene engine
    /// recorded the clip as unplayable for the session, although its picture
    /// plays perfectly well. Which half failed is decided by evidence rather
    /// than by error code: the clip is rebuilt with its video track alone, and
    /// a fault in the picture fails that item too and reaches the host as
    /// before. A clip with no audio has nothing to leave out and is reported
    /// straight away.
    private func playbackFailed(_ detail: String) {
        guard !stopped, !failureReported, rebuild == nil else { return }
        guard !audioDropped, let mediaURL else {
            reportPreparationFailure(detail)
            return
        }
        audioDropped = true
        rebuild = Task { @MainActor [weak self] in
            let silent = await Self.videoOnlyItem(url: mediaURL)
            var range = CMTimeRange.invalid
            if let silent { range = await Self.loopRange(of: silent.asset) }
            guard let self, !self.stopped else { return }
            self.rebuild = nil
            guard let silent else {
                self.reportPreparationFailure(detail)
                return
            }
            self.releaseItem()
            self.onAudioDropped?(detail)
            self.start(silent, looping: range)
        }
    }

    /// The clip with its audio left out, or `nil` when it has no audio track
    /// to leave out or its video track cannot be read.
    static func videoOnlyItem(url: URL) async -> AVPlayerItem? {
        let asset = AVURLAsset(url: url)
        do {
            guard try await !asset.loadTracks(withMediaType: .audio).isEmpty,
                let video = try await asset.loadTracks(withMediaType: .video).first
            else { return nil }
            let (range, transform) = try await video.load(.timeRange, .preferredTransform)
            let composition = AVMutableComposition()
            guard
                let track = composition.addMutableTrack(
                    withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { return nil }
            try track.insertTimeRange(range, of: video, at: .zero)
            track.preferredTransform = transform
            return AVPlayerItem(asset: composition)
        } catch {
            return nil
        }
    }

    /// Rebuilds the playback pipeline from the file, on the host's request.
    ///
    /// For a clip that reached `readyToPlay` and then never produced a picture:
    /// no failure was reported, so none of the observers above fire, and
    /// waiting longer changes nothing. A fresh item and looper is the repair
    /// that does not need to know why. Returns whether a rebuild was started;
    /// false means the caller has nothing left to try and must give the
    /// wallpaper up. The answer is false when the surface is stopped, when a
    /// failure has already been reported (a restart never resurrects it), when
    /// another rebuild is pending, and when the recovery budget has no
    /// allowance left, which is what stops a pipeline that stalls the same way
    /// every time from being rebuilt for ever.
    ///
    /// The user's pause, the volume and the placement belong to the player, not
    /// to the item, so they carry over untouched. A clip already playing
    /// without its audio is rebuilt without it.
    func restartPlayback(reason: String) -> Bool {
        startRebuild(reason: reason, keepingCheck: false)
    }

    /// `keepingCheck` is for the health check's own rebuild: it goes on to look
    /// at the new item, so the item going away must not end it. Any other
    /// rebuild ends a check at once, since what the check would conclude is
    /// about an item that is about to be replaced.
    private func startRebuild(reason: String, keepingCheck: Bool) -> Bool {
        guard !stopped, !failureReported, let mediaURL, rebuild == nil else { return false }
        guard recovery.permit(at: now()) else { return false }
        if !keepingCheck { supervisor.cancel() }
        AppLog.debug(
            "native video: restarting playback (\(reason)); rebuild \(recovery.spent) of "
                + "\(recovery.policy.maximum); \(stateSummary)")
        let silent = audioDropped
        rebuild = Task { @MainActor [weak self] in
            let item: AVPlayerItem?
            if silent {
                item = await Self.videoOnlyItem(url: mediaURL)
            } else {
                item = AVPlayerItem(url: mediaURL)
            }
            var range = CMTimeRange.invalid
            if let item { range = await Self.loopRange(of: item.asset) }
            guard let self, !self.stopped, !Task.isCancelled else { return }
            self.rebuild = nil
            guard let item else {
                self.reportPreparationFailure("the clip could not be reopened for a restart")
                return
            }
            self.releaseItem(cancellingCheck: !keepingCheck)
            self.start(item, looping: range)
        }
        return true
    }

    /// Asks for a health check of the pipeline, for a reason the host knows
    /// and the player does not (the Mac or its displays woke, the session came
    /// back). A surface that is paused, hidden or has never shown a picture is
    /// not checked, and a check already repairing absorbs the request.
    func verifyPlayback(reason: String) {
        guard !stopped else { return }
        supervisor.schedule(trigger: reason)
    }

    /// Where the pipeline stands, in one line, for the log. Read when a clip
    /// has gone wrong, so it reports the facts that tell the failures apart: a
    /// ready item with no picture size and a clock that runs is a decoder that
    /// never produced anything, which is not the same thing as a stall or a
    /// file that is still arriving.
    var stateSummary: String {
        guard !stopped else { return "stopped" }
        let item = player.currentItem
        let size = item?.presentationSize ?? .zero
        var control: String
        switch player.timeControlStatus {
        case .paused: control = "paused"
        case .playing: control = "playing"
        case .waitingToPlayAtSpecifiedRate:
            control = "waiting"
            if let reason = player.reasonForWaitingToPlay { control += " (\(reason.rawValue))" }
        @unknown default: control = "unknown"
        }
        let status: String
        switch item?.status {
        case .readyToPlay?: status = "readyToPlay"
        case .failed?: status = "failed"
        case .unknown?: status = "unknown"
        case nil: status = "none"
        @unknown default: status = "unknown"
        }
        return "item \(status), presentationSize \(Int(size.width))x\(Int(size.height)), "
            + "timeControl \(control), layerReady \(layer.isReadyForDisplay), "
            + "queued \(queuedItemCount)"
    }

    /// The error with its domain and code, and those of the errors beneath
    /// it. AVFoundation's own description is often only "The operation could
    /// not be completed", localized; the codes are what tell an audio device
    /// that would not start from a decoder fault in a report.
    nonisolated static func describe(_ error: Error) -> String {
        var codes: [String] = []
        var next: NSError? = error as NSError
        while let current = next, codes.count < 4 {
            codes.append("\(current.domain) \(current.code)")
            next = current.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return "\(error.localizedDescription) (\(codes.joined(separator: " < ")))"
    }

    /// Reported once. Both observations can fire for one underlying fault, and
    /// a second report would be a second hand-off for a wallpaper the host has
    /// already given away. `settled` is true for a failure that is a fact about
    /// the file (it could not be opened or decoded) and false for one that is
    /// not (the pipeline stopped delivering and the repairs did not revive it).
    private func reportPreparationFailure(_ detail: String, settled: Bool = true) {
        guard !stopped, !failureReported else { return }
        failureReported = true
        guard onPreparationFailure != nil else {
            // Nobody is listening yet. Held rather than dropped; installing
            // the callback delivers it.
            pendingFailure = (detail, settled)
            return
        }
        onPreparationFailure?(surface.generation, detail, settled)
    }

    /// The user's scaling and position choice for this display. Applied to the layer
    /// immediately and again whenever the picture's size or the display's
    /// geometry changes; a repeated identical choice does nothing.
    func setScaling(
        _ mode: BridgeScalingMode, factor: Double, pan: NativeVideoLayout.Pan = .centered
    ) {
        let pan = pan.normalized
        guard mode != scalingMode || factor != scalingFactor || pan != scalingPan else { return }
        scalingMode = mode
        scalingFactor = factor
        scalingPan = pan
        applyPlacement()
    }

    func setVolume(_ volume: Float, muted: Bool) {
        player.volume = max(0, min(volume, 1))
        player.isMuted = muted
    }

    /// The user's own pause. Independent of presentation suspension: a display
    /// becoming visible again must not start a wallpaper the user paused.
    func setUserPaused(_ paused: Bool) {
        userPaused = paused
        applyPlaybackState()
    }

    func setPresentationSuspended(_ suspended: Bool) {
        guard presentationSuspended != suspended else { return }
        presentationSuspended = suspended
        counters.record(
            suspended ? .presentationSuspended : .presentationResumed, for: surface)
        applyPlaybackState()
    }

    var isPlaying: Bool { player.rate > 0 }

    /// Queued item count, as the system actually reports it.
    ///
    /// `AVPlayerLooper` keeps more than one copy of the template item queued to
    /// make the seam gapless, so this is deliberately not claimed to be one.
    var queuedItemCount: Int { player.items().count }
    /// Where each queued copy stops playing, which the looper sets from the
    /// range it was given.
    var queuedItemEndTimesForTest: [CMTime] { player.items().map(\.forwardPlaybackEndTime) }

    /// The item the player is actually playing. Exposed because the loop
    /// replaces it: a poster taken from the looper's template would be a
    /// frame from a different object than the one on screen.
    var currentItemForTest: AVPlayerItem? { player.currentItem }
    var posterOutputIsAttachedForTest: Bool { videoOutput != nil }
    /// Playback position inside the item that is playing. A loop restarts it,
    /// which is how a test tells a wrap from a stall.
    var playbackTimeForTest: CMTime { player.currentItem?.currentTime() ?? .invalid }
    /// `AVPlayerLayer.isReadyForDisplay`. This means the layer has a frame it
    /// could display — not that anything reached a screen. The two are
    /// reported separately and the second one is not observable here.
    var layerIsReadyForDisplayForTest: Bool { layer.isReadyForDisplay }
    var itemStatusForTest: AVPlayerItem.Status? { player.currentItem?.status }
    var audioDroppedForTest: Bool { audioDropped }
    /// The player layer's frame in its parent's coordinates, in points.
    var layerFrameForTest: CGRect { layer.frame }
    var layerGravityForTest: AVLayerVideoGravity { layer.videoGravity }
    /// Where AVFoundation draws the picture inside the layer, in the layer's
    /// own coordinates.
    var layerVideoRectForTest: CGRect { layer.videoRect }
    var presentationSizeForTest: CGSize? { presentationSize }
    /// Sends the audio to an output that does not exist: an audio path that
    /// cannot start, reproduced without opening a real output device.
    func setAudioOutputDeviceForTest(_ uniqueID: String) {
        player.audioOutputDeviceUniqueID = uniqueID
    }

    /// One frame for a poster request, from the item that is playing.
    ///
    /// Concurrent requests coalesce into one. Nothing here resumes playback:
    /// a paused player answers from the last frame it produced, because
    /// resuming to take a screenshot would restart decode, audio and power
    /// draw the user had stopped.
    func posterImage() async -> CGImage? {
        guard !stopped else { return nil }
        if let posterRequest { return await posterRequest.value }
        let request = Task { @MainActor [weak self] in
            await self?.producePoster() ?? nil
        }
        posterRequest = request
        let image = await request.value
        if posterRequest == request { posterRequest = nil }
        return image
    }

    private func producePoster() async -> CGImage? {
        defer { detachPosterOutput() }
        // A header read that normally finished long ago; awaited so the first
        // request can never pick the path before the orientation is known.
        await orientationTask?.value
        if Self.needsUprightGenerator(displayTransform ?? .identity) {
            // The playing item's frames would come back un-rotated. Skip the
            // video output altogether rather than read frames to discard them.
            guard !stopped, let item = player.currentItem else { return lastPoster }
            return await generatorPoster(for: item) ?? lastPoster
        }
        for step in 0..<Self.posterWaitSteps {
            guard !stopped, let item = player.currentItem else { return lastPoster }
            // Re-resolved every step: crossing a loop boundary replaces
            // `currentItem`, and an output attached to the retired copy would
            // never produce another frame.
            let output = attachPosterOutput(to: item)
            let time = item.currentTime()
            if output.hasNewPixelBuffer(forItemTime: time),
                let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil),
                let image = Self.makeImage(from: buffer)
            {
                counters.record(.readinessFrameRendered, for: surface)
                lastPoster = image
                return image
            }
            if step + 1 < Self.posterWaitSteps {
                try? await Task.sleep(for: Self.posterWaitStep)
            }
        }
        guard !stopped else { return nil }
        if let item = player.currentItem, let image = await generatorPoster(for: item) {
            return image
        }
        // Still nothing: the last frame this player produced is a truthful
        // answer, and nil is a truthful "none yet". Neither resumes playback.
        return lastPoster
    }

    /// One upright frame from a one-shot image generator, created and
    /// released inside this request.
    ///
    /// It is a second decode of a few frames, which is why it is counted: a
    /// permanently retained generator would be a second decoder for the whole
    /// session. A rotated or mirrored clip takes this path for every poster,
    /// an upright one only when the playing item produced no frame in time.
    /// Playback is never resumed to make the picture.
    private func generatorPoster(for item: AVPlayerItem) async -> CGImage? {
        guard let mediaURL else { return nil }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: mediaURL))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        counters.record(.nativeVideoPosterFallback, for: surface)
        guard let image = try? await generator.image(at: item.currentTime()).image,
            !stopped
        else { return nil }
        lastPoster = image
        return image
    }

    private func attachPosterOutput(to item: AVPlayerItem) -> AVPlayerItemVideoOutput {
        if let output = videoOutput, outputItem === item { return output }
        detachPosterOutput()
        let output = AVPlayerItemVideoOutput(outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        item.add(output)
        videoOutput = output
        outputItem = item
        return output
    }

    private func detachPosterOutput() {
        if let output = videoOutput, let item = outputItem {
            item.remove(output)
        }
        videoOutput = nil
        outputItem = nil
    }

    private static func makeImage(from buffer: CVPixelBuffer) -> CGImage? {
        var image: CGImage?
        // Retains nothing: no Core Image context is kept alive between
        // requests, so a failed poster leaves no converter behind.
        guard VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &image)
            == noErr
        else { return nil }
        return image
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        // A request still in flight belongs to this surface. Cancelling it
        // here is what keeps its frame from being delivered to whatever opens
        // next on the same display.
        posterRequest?.cancel()
        posterRequest = nil
        rebuild?.cancel()
        rebuild = nil
        orientationTask?.cancel()
        orientationTask = nil
        sizeObservation = nil
        supervisor.cancel()
        detachLivenessOutput()
        detachPosterOutput()
        lastPoster = nil
        pendingFailure = nil
        onPreparationFailure = nil
        onReadyForDisplay = nil
        onAudioDropped = nil
        onHealthEvent = nil
        player.pause()
        releaseItem()
        layer.player = nil
        layer.removeFromSuperlayer()
    }

    private func applyPlaybackState() {
        guard !stopped else { return }
        if userPaused || presentationSuspended {
            if pausedSince == nil { pausedSince = now() }
            // What a check in flight would conclude no longer holds.
            supervisor.cancel()
            player.pause()
        } else {
            let paused = pausedSince.map { now() - $0 }
            pausedSince = nil
            player.play()
            // The decoder can be reclaimed while nothing is playing, and
            // `play()` does not say whether the clip has one again. A long
            // enough pause earns a look at whether pictures come out.
            if let paused, paused >= healthPolicy.minimumPause {
                supervisor.schedule(trigger: "resumed after \(Self.describe(pause: paused))")
            }
        }
    }

    nonisolated static func describe(pause: Duration) -> String {
        let seconds = Int(pause.components.seconds)
        if seconds < 120 { return "\(seconds) s" }
        if seconds < 7_200 { return "\(seconds / 60) min" }
        return "\(seconds / 3_600) h"
    }
}

// MARK: Health checks

extension NativeVideoPlayer: NativeVideoHealthTarget {
    /// A rebuild in flight does not make the surface ineligible: the check's
    /// own rebuild is followed by a look at the new item, and `liveSample`
    /// has nothing to show until it exists.
    var isEligibleForCheck: Bool {
        !stopped && !userPaused && !presentationSuspended && hasShownFrame
    }

    /// One look at the pipeline: where the clock is, and whether the playing
    /// item handed over a frame nobody has read yet.
    ///
    /// The frame is what matters. A pipeline whose decoder died keeps a clock
    /// that runs, so the position alone would call it healthy. A video output
    /// reports each frame once and has to be read to consume it; leaving one
    /// unread would answer yes for ever after the first.
    func liveSample() -> NativeVideoLivenessEvaluator.Sample? {
        guard !stopped, rebuild == nil, let item = player.currentItem else { return nil }
        let output = attachLivenessOutput(to: item)
        let time = item.currentTime()
        var produced = false
        if output.hasNewPixelBuffer(forItemTime: time) {
            produced = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) != nil
        }
        return NativeVideoLivenessEvaluator.Sample(
            time: time, item: ObjectIdentifier(item), producedFrame: produced,
            waiting: player.timeControlStatus == .waitingToPlayAtSpecifiedRate)
    }

    func finishSampling() {
        detachLivenessOutput()
    }

    func reportHealth(_ event: NativeVideoHealthEvent) {
        guard !stopped else { return }
        onHealthEvent?(event)
    }

    func canRebuildPlayback() -> Bool {
        !stopped && !failureReported && mediaURL != nil && rebuild == nil
            && recovery.wouldPermit(at: now())
    }

    /// The cheap repair. A zero-tolerance seek to where the clip already is
    /// makes the player re-request the picture at that time, which a stuck
    /// output needs and a healthy one does not notice; `play()` then covers a
    /// player the system left paused. Never starts a clip the user paused or a
    /// display that is hidden.
    func kickPlayback() {
        guard !stopped, !userPaused, !presentationSuspended, rebuild == nil,
            player.currentItem != nil
        else { return }
        counters.record(.nativeVideoPlaybackKick, for: surface)
        let time = player.currentTime()
        if time.isNumeric {
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        player.play()
    }

    func rebuildPlayback(reason: String) -> Bool {
        guard startRebuild(reason: reason, keepingCheck: true) else { return false }
        counters.record(.nativeVideoPlaybackRebuild, for: surface)
        return true
    }

    func playbackProvedHealthy() {
        guard !stopped else { return }
        recovery.healthy(at: now())
    }

    /// The repairs ran out. Reported as unsettled: a pipeline that stalled after
    /// a wake or a resume says nothing about whether the file can play, so the
    /// host does not remember the hand-off as a verdict and tries the clip
    /// afresh if the bridge offers it again.
    func giveUpOnPlayback(trigger: String, detail: String) {
        reportPreparationFailure(
            "playback stalled after \(trigger): \(detail); recovery budget "
                + "\(recovery.spent) of \(recovery.policy.maximum) rebuilds spent",
            settled: false)
    }

    /// Re-attached whenever the loop replaces the playing item: an output left
    /// on the retired copy would never see another frame.
    private func attachLivenessOutput(to item: AVPlayerItem) -> AVPlayerItemVideoOutput {
        if let output = livenessOutput, livenessItem === item { return output }
        detachLivenessOutput()
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
        item.add(output)
        livenessOutput = output
        livenessItem = item
        return output
    }

    private func detachLivenessOutput() {
        if let output = livenessOutput, let item = livenessItem {
            item.remove(output)
        }
        livenessOutput = nil
        livenessItem = nil
    }

    var livenessOutputIsAttachedForTest: Bool { livenessOutput != nil }
    /// Stands in for a picture shown earlier, so a pipeline that is dead from
    /// the start can be put through the checks that only apply to one that
    /// died after it worked.
    func markPictureShownForTest() { hasShownFrame = true }
}
