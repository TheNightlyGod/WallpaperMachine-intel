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
    private var webM: WebMPlayer?
    private var muted = true
    private var paused = false
    private var stopped = false
    private var ready = false

    init(request: WallpaperPreviewRequest) {
        self.request = request
        content = ContentView(frame: CGRect(x: 0, y: 0, width: 960, height: 540))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.black.cgColor
        content.layer?.masksToBounds = true
        view = content
        content.resized = { [weak self] bounds, scale in
            guard let self, !self.stopped else { return }
            self.avLayer?.frame = bounds
            self.webM?.relayout(bounds: bounds, backingScale: scale)
        }
    }

    func start() async throws {
        guard !stopped, avPlayer == nil, webM == nil else { throw CancellationError() }
        let url = request.projectURL.appendingPathComponent(request.entryFile)
        let refusal = await NativeVideoAdmission.evaluate(url: url)
        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
        guard let refusal else {
            let asset = AVURLAsset(url: url)
            let range = await NativeVideoPlayer.loopRange(of: asset)
            try Task.checkCancellation()
            guard !stopped else { throw CancellationError() }
            playWithAVFoundation(asset, looping: range)
            return
        }
        // AVFoundation never opens Matroska or WebM; the app's reader may.
        if case .notPlayable = refusal, case .success(let file) = WebMOpening.open(url: url) {
            playWithWebM(file)
            return
        }
        throw WallpaperPreviewFailure(message: refusal.reason)
    }

    /// Loops `range` of the clip, which the desktop player bounds the same way: its picture,
    /// not the end of its audio.
    private func playWithAVFoundation(_ asset: AVURLAsset, looping range: CMTimeRange) {
        let player = AVQueuePlayer()
        player.isMuted = muted
        player.volume = request.volume
        player.preventsDisplaySleepDuringVideoPlayback = false
        let item = AVPlayerItem(asset: asset)
        looper = AVPlayerLooper(player: player, templateItem: item, timeRange: range)
        let layer = AVPlayerLayer(player: player)
        layer.frame = content.bounds
        layer.videoGravity = Self.gravity(for: request.scalingMode)
        content.layer?.addSublayer(layer)
        avPlayer = player
        avLayer = layer
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
        if let looper {
            observations.append(
                looper.observe(\.status, options: [.new]) { [weak self] looper, _ in
                    guard looper.status == .failed else { return }
                    let detail = looper.error?.localizedDescription ?? "the clip could not be looped"
                    Task { @MainActor in self?.failed(detail) }
                })
        }
        if !paused { player.play() }
    }

    private func playWithWebM(_ file: WebMFile) {
        let player = WebMPlayer(file: file, withAudio: true, paused: paused)
        webM = player
        let mode = NativeVideoScalingMode(rendererValue: request.scalingMode) ?? .fill
        player.setVolume(request.volume, muted: muted)
        player.setScaling(mode, factor: 1, pan: .centered)
        player.attach(to: content.layer ?? CALayer())
        player.relayout(bounds: content.bounds, backingScale: content.window?.backingScaleFactor ?? 1)
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
            if paused { avPlayer.pause() } else { avPlayer.play() }
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

    func stop() {
        guard !stopped else { return }
        stopped = true
        onReady = nil
        onFailure = nil
        content.resized = nil
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
