import AVFoundation
import AppKit
import QuartzCore
import WallpaperMedia

/// The preview of a plain video: the app's own players in an ordinary view, the same ones that play
/// it on the desktop. The scene engine is never given a video, so the preview cannot use it either.
///
/// AVFoundation plays what it opens (MP4, MOV and the like) in a looping `AVPlayerLayer`; a WebM or
/// Matroska file it cannot open is played by `WebMPlayer`. A clip neither takes is a failed preview
/// with the reason, like a failed display on the desktop. The picture follows the wallpaper's scaling
/// mode; the preview does not reproduce the scale factor or the position the desktop applies.
@MainActor
final class VideoWallpaperPreviewSurface: WallpaperPreviewSurface {
    private final class ContentView: NSView {
        var resized: ((CGRect, CGFloat) -> Void)?
        override func layout() {
            super.layout()
            resized?(bounds, window?.backingScaleFactor ?? 1)
        }
        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            resized?(bounds, window?.backingScaleFactor ?? 1)
        }
    }

    let view: NSView
    var onReady: (() -> Void)?
    var onFailure: ((String) -> Void)?
    private let request: WallpaperPreviewRequest
    private let content: ContentView
    private var avPlayer: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var avLayer: AVPlayerLayer?
    private var observations: [NSKeyValueObservation] = []
    private var looperObservation: NSKeyValueObservation?
    private var compositionTask: Task<Void, Never>?
    private var avAsset: AVURLAsset?
    private var loopRange = CMTimeRange.invalid
    private var webM: WebMPlayer?
    /// The corrected copy an `hev1` clip plays from, held until the preview stops.
    private var copyLease: DerivedVideoCache.Lease?
    private let derivedVideos: DerivedVideoCache
    private var muted = true
    private var paused = false
    private var stopped = false
    private var ready = false
    /// Parameters update in place; the identity keeps the system's direct playback path.
    private let colorPipeline = VideoColorPipeline()
    private var options = WallpaperEngineOptions.identity

    init(request: WallpaperPreviewRequest, derivedVideos: DerivedVideoCache = .shared) {
        self.request = request
        self.derivedVideos = derivedVideos
        content = ContentView(frame: CGRect(x: 0, y: 0, width: 960, height: 540))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.black.cgColor
        content.layer?.masksToBounds = true
        view = content
        content.resized = { [weak self] bounds, scale in
            guard let self, !self.stopped else { return }
            self.placeAVLayer()
            self.webM?.relayout(bounds: bounds, backingScale: scale)
        }
        if let options = request.engineOptions { show(options) }
    }

    func start() async throws {
        guard !stopped, avPlayer == nil, webM == nil else { throw CancellationError() }
        let url = request.projectURL.appendingPathComponent(request.entryFile)
        let refusal = await NativeVideoAdmission.evaluate(url: url)
        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
        guard let refusal else {
            try await playWithAVFoundation(url: url)
            return
        }
        // AVFoundation never opens Matroska or WebM; the app's reader may.
        if case .notPlayable = refusal, case .success(let file) = WebMOpening.open(url: url) {
            playWithWebM(file)
            return
        }
        // HEVC tagged `hev1` plays from a copy retagged `hvc1`, as it does on the desktop, and a
        // copy that cannot be had is refused in the desktop's words.
        if case .notPlayable = refusal, let plan = await Self.retagPlan(of: url) {
            let failure = await Self.prepareCopy(of: url, plan: plan, in: derivedVideos)
            try Task.checkCancellation()
            guard !stopped else { throw CancellationError() }
            if let failure { throw WallpaperPreviewFailure(message: failure) }
            guard case let .copy(lease) = derivedVideos.playableFile(for: url) else {
                throw WallpaperPreviewFailure(message: refusal.reason)
            }
            copyLease = lease
            try await playWithAVFoundation(url: lease.url)
            return
        }
        throw WallpaperPreviewFailure(message: refusal.reason)
    }

    private func playWithAVFoundation(url: URL) async throws {
        let asset = AVURLAsset(url: url)
        let range = await NativeVideoPlayer.loopRange(of: asset)
        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
        try await playWithAVFoundation(asset, looping: range)
    }

    /// The retag of an `hev1` clip whose sample descriptions carry the parameter sets, read off the
    /// main actor; `nil` for any other file.
    private nonisolated static func retagPlan(of url: URL) async -> HevcSampleEntryRetag.Plan? {
        guard case let .retag(plan)? = try? HevcSampleEntryRetag.inspect(url: url) else { return nil }
        return plan
    }

    /// Makes its copy off the main actor, a full copy waited for unless the preview's task is
    /// cancelled. `nil` once the copy is there; otherwise what the desktop says about the clip.
    private nonisolated static func prepareCopy(
        of url: URL, plan: HevcSampleEntryRetag.Plan, in derived: DerivedVideoCache
    ) async -> String? {
        guard case let .failure(failure) = await derived.prepare(source: url, plan: plan, waiting: true) else {
            return nil
        }
        let format = VideoFormatSupport.Format(container: VideoFormatSupport.container(of: url).name, codec: "HEVC")
        return VideoFormatSupport.refusal(for: failure, format: format).reason
    }

    /// Loops `range` of the clip, which the desktop player bounds the same way: its picture,
    /// not the end of its audio.
    private func playWithAVFoundation(_ asset: AVURLAsset, looping range: CMTimeRange) async throws {
        let player = AVQueuePlayer()
        player.isMuted = muted
        player.volume = request.volume
        player.preventsDisplaySleepDuringVideoPlayback = false
        let item = AVPlayerItem(asset: asset)
        try await colorPipeline.configure(item)
        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
        player.defaultRate = Float(max(10, min(options.playbackRate, 200)) / 100)
        avAsset = asset
        loopRange = range
        looper = AVPlayerLooper(player: player, templateItem: item, timeRange: range)
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = Self.gravity(for: request.scalingMode)
        content.layer?.addSublayer(layer)
        avPlayer = player
        avLayer = layer
        placeAVLayer()
        observations = [
            layer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
                guard layer.isReadyForDisplay else { return }
                Task { @MainActor in self?.becameReady() }
            },
            player.observe(\.status, options: [.new]) { [weak self] player, _ in
                guard player.status == .failed else { return }
                let detail = player.error?.localizedDescription ?? "the player failed"
                Task { @MainActor in self?.failed(detail) }
            },
        ]
        observeLooper()
        if !paused { player.play() }
    }

    private func observeLooper() {
        looperObservation = looper?.observe(\.status, options: [.new]) { [weak self] looper, _ in
            guard looper.status == .failed else { return }
            let detail = looper.error?.localizedDescription ?? "the clip could not be looped"
            Task { @MainActor in
                guard let self, self.looper === looper else { return }
                self.failed(detail)
            }
        }
    }

    private func reloadComposition() {
        guard let asset = avAsset, let player = avPlayer, !stopped else { return }
        compositionTask?.cancel()
        compositionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let item = AVPlayerItem(asset: asset)
            do { try await self.colorPipeline.configure(item) }
            catch is CancellationError { return }
            catch { self.failed(error.localizedDescription); return }
            guard !self.stopped, !Task.isCancelled, self.avPlayer === player else { return }
            let time = player.currentTime()
            player.pause()
            self.looper?.disableLooping()
            player.removeAllItems()
            let looper = AVPlayerLooper(player: player, templateItem: item, timeRange: self.loopRange)
            self.looper = looper
            self.observeLooper()
            self.compositionTask = nil
            if time.isNumeric {
                player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, !self.stopped, self.looper === looper else { return }
                        if !self.paused { player.play() }
                    }
                }
            } else if !self.paused { player.play() }
        }
    }

    private func playWithWebM(_ file: WebMFile) {
        let player = WebMPlayer(file: file, withAudio: true, paused: paused)
        webM = player
        let mode = NativeVideoScalingMode(rendererValue: request.scalingMode) ?? .fill
        player.setVolume(request.volume, muted: muted)
        player.setScaling(mode, factor: 1, pan: .centered)
        player.attach(to: content.layer ?? CALayer())
        player.relayout(bounds: content.bounds, backingScale: content.window?.backingScaleFactor ?? 1)
        show(options)
        player.onFailure = { [weak self] detail, _ in self?.failed(detail) }
        player.onReadyForDisplay = { [weak self] in self?.becameReady() }
        player.start()
    }

    private func becameReady() {
        guard !stopped, !ready else { return }
        ready = true
        onReady?()
    }

    private func failed(_ detail: String) {
        guard !stopped else { return }
        onFailure?(detail)
    }

    func setPaused(_ paused: Bool) throws {
        self.paused = paused
        if let avPlayer {
            if paused { avPlayer.pause() } else { avPlayer.play() }  // play() honours defaultRate
        }
        webM?.setPaused(paused)
    }

    func setMuted(_ muted: Bool) throws {
        self.muted = muted
        avPlayer?.isMuted = muted
        webM?.setVolume(request.volume, muted: muted)
    }

    /// A video has no properties to follow.
    func applyProperties(_ json: String) throws {}

    /// A video's Wallpaper Engine options follow the draft in place: rate, flip, colour and filter.
    func applyEngineOptions(_ options: WallpaperEngineOptions) throws { show(options) }

    private func show(_ options: WallpaperEngineOptions) {
        guard !stopped else { return }
        self.options = options
        let lut = options.isFilterIdentity ? nil : VideoLutLoader.load(
            request.assetsURL.appendingPathComponent("materials/lut/\(options.imageFilter).tex"))
        let wasFiltered = VideoColorPipeline.needsComposition(colorPipeline.current)
        let parameters = VideoColorPipeline.Parameters(options: options, lut: lut)
        colorPipeline.update(parameters)
        let rate = Float(max(10, min(options.playbackRate, 200)) / 100)
        avPlayer?.defaultRate = rate
        if let avPlayer, avPlayer.rate > 0 { avPlayer.rate = rate }
        placeAVLayer()
        webM?.setEngineOptions(options, lut: lut, borderColor: nil)
        if wasFiltered != VideoColorPipeline.needsComposition(parameters) { reloadComposition() }
    }

    /// Bounds and position, then the flip about the centre.
    private func placeAVLayer() {
        guard let avLayer else { return }
        let bounds = content.bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        avLayer.setAffineTransform(.identity)
        avLayer.bounds = CGRect(origin: .zero, size: bounds.size)
        avLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        avLayer.setAffineTransform(options.flipHorizontal ? CGAffineTransform(scaleX: -1, y: 1) : .identity)
        CATransaction.commit()
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        onReady = nil
        onFailure = nil
        content.resized = nil
        compositionTask?.cancel()
        compositionTask = nil
        avAsset = nil
        looperObservation = nil
        observations.removeAll()
        avPlayer?.pause()
        looper?.disableLooping()
        looper = nil
        avPlayer = nil
        avLayer?.player = nil
        avLayer?.removeFromSuperlayer()
        avLayer = nil
        webM?.stop()
        webM = nil
        copyLease?.release()
        copyLease = nil
    }

    /// `none` has no gravity of its own; the nearest one that shows the whole picture stands in.
    private static func gravity(for scalingMode: Int32) -> AVLayerVideoGravity {
        switch NativeVideoScalingMode(rendererValue: scalingMode) ?? .fill {
        case .stretch: return .resize
        case .match, .matchBlurred, .none: return .resizeAspect
        case .fill: return .resizeAspectFill
        }
    }
}
