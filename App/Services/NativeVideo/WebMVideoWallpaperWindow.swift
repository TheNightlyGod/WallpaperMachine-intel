import AVFoundation
import AppKit
import WallpaperMedia

/// One desktop window playing a plain WebM or Matroska video with `WebMPlayer`.
///
/// The twin of `NativeVideoWallpaperWindow` for the files AVFoundation cannot open. It is a window of
/// its own class (found by the presentation policy and the poster sync by class name, like the
/// others) and a `NativeVideoSurface`, so the host routes, suspends, checks and closes it exactly as
/// it does the AVFoundation player.
///
/// The file is opened before this is made when it can be (admission opened it to judge it, and its
/// reader is kept for the surface); when it was not, the window opens it in the background, shows
/// nothing and reports a failure the way a file that fails to play does. Everything the host says
/// before the player exists (volume, placement, pause) is kept and applied when it does.
@objc(MWEWebMVideoDesktopWindow)
final class WebMVideoWallpaperWindow: NSWindow {
    private struct Desired {
        var volume: Float = 1
        var muted = false
        var mode: BridgeScalingMode = .fill
        var factor = 1.0
        var pan = NativeVideoLayout.Pan.centered
        var userPaused: Bool
        var suspended = false
    }

    private let surface: RuntimeSurfaceKey
    private let counters: RuntimeCounters
    private let container: NativeVideoContainerView
    private var player: WebMPlayer?
    private var desired: Desired
    private var opening: Task<Void, Never>?
    private var closed = false
    private var pendingFailure: (detail: String, settled: Bool)?
    private var readyHandler: (@MainActor () -> Void)?
    private var failureHandler: (@MainActor (UInt64, String, Bool) -> Void)?
    private var audioDroppedHandler: (@MainActor (String) -> Void)?
    private var pendingAudioDrop: String?
    private var healthHandler: (@MainActor (NativeVideoHealthEvent) -> Void)?

    /// `file` is the opened reader when the caller has one; otherwise the window opens `url` itself.
    init(
        frame: NSRect, url: URL, file: WebMFile?, surface: RuntimeSurfaceKey, counters: RuntimeCounters,
        paused: Bool
    ) {
        self.surface = surface
        self.counters = counters
        self.desired = Desired(userPaused: paused)
        container = NativeVideoContainerView(frame: NSRect(origin: .zero, size: frame.size))
        super.init(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        configureAsDesktopVideoWindow()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        container.autoresizesSubviews = true
        container.onLayout = { [weak self] bounds, scale in self?.player?.relayout(bounds: bounds, backingScale: scale) }
        contentView = container
        if let file {
            makePlayer(file)
        } else {
            opening = Task { @MainActor [weak self] in
                let result = await Task.detached(priority: .userInitiated) { WebMOpening.open(url: url) }.value
                guard let self, !self.closed, !Task.isCancelled else { return }
                self.opening = nil
                switch result {
                case .success(let file): self.makePlayer(file)
                case .failure(let failure):
                    let settled: Bool
                    switch failure.kind {
                    case .unsupported, .notMatroska, .damaged: settled = true
                    case .unreadable: settled = false
                    }
                    self.report(failure: failure.detail, settled: settled)
                }
            }
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// The player in use, for tests.
    var playerForTest: WebMPlayer? { player }

    private func makePlayer(_ file: WebMFile) {
        let player = WebMPlayer(file: file, withAudio: true, paused: desired.userPaused || desired.suspended)
        self.player = player
        counters.record(.nativeVideoItemCreated, for: surface)
        player.onFailure = { [weak self] detail, settled in self?.report(failure: detail, settled: settled) }
        player.onAudioDropped = { [weak self] detail in self?.audioDropped(detail) }
        player.onHealthReport = { [weak self] report in self?.health(report) }
        player.attach(to: container.layer ?? CALayer())
        player.relayout(bounds: container.bounds, backingScale: backingScaleFactor)
        applyDesired(to: player)
        player.onReadyForDisplay = { [weak self] in self?.readyHandler?() }
        if let reason = player.audioUnavailableReason { audioDropped(reason) }
        player.start()
    }

    private func applyDesired(to player: WebMPlayer) {
        player.setVolume(desired.volume, muted: desired.muted)
        player.setScaling(desired.mode.layoutMode, factor: desired.factor, pan: desired.pan)
        player.setPaused(desired.userPaused || desired.suspended)
    }

    private func report(failure detail: String, settled: Bool) {
        guard !closed else { return }
        guard let failureHandler else {
            // The host installs its handler after constructing the surface: a failure before that is
            // held, not lost.
            pendingFailure = (detail, settled)
            return
        }
        failureHandler(surface.generation, detail, settled)
    }

    private func audioDropped(_ detail: String) {
        guard !closed else { return }
        if let audioDroppedHandler { audioDroppedHandler(detail) } else { pendingAudioDrop = detail }
    }

    private func health(_ report: WebMHealthReport) {
        let verdict: NativeVideoLiveness
        switch report.verdict {
        case .advancing: verdict = .advancing
        case .stalled(let detail): verdict = .stalled(detail)
        }
        var event = NativeVideoHealthEvent(trigger: report.trigger, verdict: verdict)
        event.stage = report.afterRepair ? .afterRebuild : .initial
        switch report.repair {
        case .none: event.next = .done
        case .restarted:
            // The player restarted itself; a restart the host asked for is counted in `restartPlayback`.
            event.next = .rebuild
            counters.record(.nativeVideoPlaybackRebuild, for: surface)
        case .gaveUp: event.next = .giveUp("the pipeline did not recover after a restart")
        }
        healthHandler?(event)
    }
}

extension WebMVideoWallpaperWindow: NativeVideoSurface {
    var posterLayer: CALayer? { contentView?.layer }

    func setScreenFrame(_ frame: NSRect) {
        if self.frame != frame { setFrame(frame, display: false) }
    }

    func setVolume(_ volume: Float, muted: Bool) {
        desired.volume = volume
        desired.muted = muted
        player?.setVolume(volume, muted: muted)
    }

    func setScaling(_ mode: BridgeScalingMode, factor: Double, pan: NativeVideoLayout.Pan) {
        desired.mode = mode
        desired.factor = factor
        desired.pan = pan
        player?.setScaling(mode.layoutMode, factor: factor, pan: pan)
    }

    func setUserPaused(_ paused: Bool) {
        desired.userPaused = paused
        player?.setPaused(desired.userPaused || desired.suspended)
    }

    func setPresentationSuspended(_ suspended: Bool) {
        desired.suspended = suspended
        player?.setPaused(desired.userPaused || desired.suspended)
    }

    var isPlaying: Bool { player?.isPlaying ?? false }
    var isReadyForDisplay: Bool { player?.isReadyForDisplay ?? false }

    var onReadyForDisplay: (@MainActor () -> Void)? {
        get { readyHandler }
        set {
            readyHandler = newValue
            // A player that already has its picture says so to a handler that arrives late.
            if newValue != nil, player?.isReadyForDisplay == true { newValue?() }
        }
    }

    func posterImage() async -> CGImage? {
        guard let player, let image = await player.posterImage() else { return nil }
        return NativeVideoWallpaperWindow.fittedPoster(
            image,
            pixelSize: CGSize(width: frame.width * backingScaleFactor, height: frame.height * backingScaleFactor),
            backingScale: backingScaleFactor, mode: desired.mode, factor: desired.factor, pan: desired.pan)
    }

    var onPreparationFailure: (@MainActor (UInt64, String, Bool) -> Void)? {
        get { failureHandler }
        set {
            failureHandler = newValue
            guard let newValue, let pending = pendingFailure else { return }
            pendingFailure = nil
            newValue(surface.generation, pending.detail, pending.settled)
        }
    }

    var onAudioDropped: (@MainActor (String) -> Void)? {
        get { audioDroppedHandler }
        set {
            audioDroppedHandler = newValue
            guard let newValue, let pending = pendingAudioDrop else { return }
            pendingAudioDrop = nil
            newValue(pending)
        }
    }

    var onHealthEvent: (@MainActor (NativeVideoHealthEvent) -> Void)? {
        get { healthHandler }
        set { healthHandler = newValue }
    }

    var stateSummary: String { player?.stateSummary ?? "the file is still being opened" }

    func restartPlayback(reason: String) -> Bool {
        guard let player else { return false }
        let restarted = player.restartPlayback(reason: reason)
        if restarted { counters.record(.nativeVideoPlaybackRebuild, for: surface) }
        return restarted
    }

    func verifyPlayback(reason: String) { player?.verifyPlayback(reason: reason) }

    func present() { orderFrontRegardless() }

    func stop() {
        guard !closed else { return }
        closed = true
        opening?.cancel()
        opening = nil
        if let player {
            player.stop()
            counters.record(.nativeVideoItemReleased, for: surface)
        }
        player = nil
        orderOut(nil)
        close()
    }
}
