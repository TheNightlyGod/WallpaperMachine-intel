import AVFoundation
import AppKit

/// What the host needs from one display's surface.
///
/// The real implementation is a desktop window owning the platform player.
/// Keeping it behind this boundary is what lets the host's routing, fallback
/// and suspension rules be checked without opening a window: the desktop is
/// not available to an automated run, and a test that ordered a
/// desktop-level window onto the screen would be doing exactly that.
@MainActor
protocol NativeVideoSurface: AnyObject {
    /// The window server's number for the surface's window.
    var windowNumber: Int { get }
    var posterLayer: CALayer? { get }
    func setScreenFrame(_ frame: NSRect)
    func setVolume(_ volume: Float, muted: Bool)
    /// The user's scaling mode, scale factor and position. All three are honoured on
    /// this backend exactly as Compatibility draws them, so the surface never
    /// substitutes another mode, or a centred picture, for the one chosen.
    func setScaling(_ mode: BridgeScalingMode, factor: Double, pan: NativeVideoLayout.Pan)
    func setUserPaused(_ paused: Bool)
    func setPresentationSuspended(_ suspended: Bool)
    var isPlaying: Bool { get }
    var isReadyForDisplay: Bool { get }
    var onReadyForDisplay: (@MainActor () -> Void)? { get set }
    func posterImage() async -> CGImage?
    /// Called when the platform player fails to prepare or play the asset.
    ///
    /// Metadata loading succeeding says nothing about whether playback will:
    /// a track can be readable and still fail to decode, and the failure only
    /// surfaces on `AVPlayerItem.status`. Without this the display shows a
    /// black rectangle for as long as it is assigned, with nothing said about
    /// why. The host closes the surface and reports the display as failed. The argument is the
    /// surface's own generation, so a failure from a surface that has since
    /// been replaced cannot condemn its successor.
    ///
    /// The last argument says whether the failure is a verdict on the file
    /// (`settled`): a decoder that could not open the track will fail the same
    /// way next time, so the host may remember it. A pipeline that stopped
    /// delivering pictures and was not revived is not (a decoder the system took
    /// back while the Mac slept says nothing about the clip), and the host must
    /// not remember the failure it causes as one: the clip is tried again when
    /// the bridge offers it under a newer revision.
    var onPreparationFailure: (@MainActor (UInt64, String, Bool) -> Void)? { get set }
    /// Called when the clip failed with its audio and keeps playing without
    /// it, with the failure. Not a failure of the display: the surface is still playing.
    var onAudioDropped: (@MainActor (String) -> Void)? { get set }
    /// Called with what each look of a health check concluded about the
    /// pipeline, together with the step the surface takes next (a kick, a
    /// rebuild, giving up). A report for the log and the counters: the surface
    /// carries out the repair itself, and a give-up reaches the host as an
    /// `onPreparationFailure`, not through here.
    var onHealthEvent: (@MainActor (NativeVideoHealthEvent) -> Void)? { get set }
    /// Asks the surface to check that pictures still come out, and to repair
    /// the pipeline if they do not, for a reason the surface cannot see itself:
    /// the Mac or its displays woke, or the session came back. A kick and at
    /// most one rebuild are tried; if neither helps the surface reports a
    /// preparation failure, which reports the display as failed. A
    /// surface that is paused or hidden, or has not yet shown a picture, is not
    /// checked.
    func verifyPlayback(reason: String)
    /// Where the platform pipeline stands, in one line for the log: the item's
    /// status, the picture size it reports, whether the clock runs and whether
    /// the layer has a frame. Read when a clip has not shown a picture, to tell
    /// a file that is slow to arrive from a decoder that produced nothing.
    var stateSummary: String { get }
    /// Rebuilds the playback pipeline from the file, for a clip that is
    /// nominally playing and shows no picture. True means a rebuild started;
    /// false means nothing was done and none is left to try (the surface is
    /// stopped or has failed, or its recovery allowance is spent), so the caller
    /// gives the wallpaper up instead. Never changes the user's pause, the
    /// volume or the placement.
    func restartPlayback(reason: String) -> Bool
    /// Puts the surface on the desktop. Separate from construction so the
    /// caller decides when a surface becomes visible.
    func present()
    func stop()
}

/// One desktop window playing a plain local video with the platform player.
///
/// The window is a sibling of the renderer's Metal window and the web
/// wallpaper window, and is discovered by the same class-name lookup, so the
/// presentation policy and the desktop poster sync see it without special
/// cases.
@objc(MWENativeVideoDesktopWindow)
final class NativeVideoWallpaperWindow: NSWindow {
    let player: NativeVideoPlayer
    private var scalingMode: BridgeScalingMode = .fill
    private var scalingFactor = 1.0
    private var scalingPan = NativeVideoLayout.Pan.centered

    init(frame: NSRect, player: NativeVideoPlayer) {
        self.player = player
        super.init(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        configureAsDesktopVideoWindow()
        let container = NativeVideoContainerView(frame: NSRect(origin: .zero, size: frame.size))
        container.player = player
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        container.autoresizesSubviews = true
        contentView = container
        player.attach(to: container)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

extension NSWindow {
    /// What every window that carries a plain video on the desktop shares: a borderless window at
    /// the desktop level that follows the Spaces, takes no input and cannot be hidden with the app.
    func configureAsDesktopVideoWindow() {
        isReleasedWhenClosed = false
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = true
        hasShadow = false
        isMovable = false
        isRestorable = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        // Hiding the app hides the panel, never the desktop it decorates.
        canHide = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        backgroundColor = .black
    }
}

extension NativeVideoWallpaperWindow: NativeVideoSurface {
    var posterLayer: CALayer? { contentView?.layer }
    func setScreenFrame(_ frame: NSRect) {
        if self.frame != frame { setFrame(frame, display: false) }
    }
    func setVolume(_ volume: Float, muted: Bool) { player.setVolume(volume, muted: muted) }
    func setScaling(_ mode: BridgeScalingMode, factor: Double, pan: NativeVideoLayout.Pan) {
        scalingMode = mode
        scalingFactor = factor
        scalingPan = pan
        player.setScaling(mode, factor: factor, pan: pan)
    }
    func setUserPaused(_ paused: Bool) { player.setUserPaused(paused) }
    func setPresentationSuspended(_ suspended: Bool) {
        player.setPresentationSuspended(suspended)
    }
    var isPlaying: Bool { player.isPlaying }
    var isReadyForDisplay: Bool { player.isReadyForDisplay }
    var onReadyForDisplay: (@MainActor () -> Void)? {
        get { player.onReadyForDisplay }
        set { player.onReadyForDisplay = newValue }
    }
    func posterImage() async -> CGImage? {
        guard let image = await player.posterImage() else { return nil }
        return Self.fittedPoster(image, pixelSize: CGSize(
            width: frame.width * backingScaleFactor, height: frame.height * backingScaleFactor),
            backingScale: backingScaleFactor, mode: scalingMode, factor: scalingFactor,
            pan: scalingPan)
    }

    /// The desktop picture API stretches the supplied poster to the display.
    /// Draw the clip's frame where the live layer puts the picture first, so
    /// other Spaces show the same crop, bars and zoom: Fit leaves black bars,
    /// Fill and Original size crop, a scale factor magnifies, and a position moves it.
    static func fittedPoster(
        _ image: CGImage, pixelSize: CGSize, backingScale: CGFloat, mode: BridgeScalingMode,
        factor: Double, pan: NativeVideoLayout.Pan = .centered
    ) -> CGImage? {
        NativeVideoLayout.composeFrame(
            image, pixelSize: pixelSize, backingScale: backingScale, mode: mode.layoutMode,
            factor: factor, pan: pan)
    }
    /// Forwarded straight to the player, which is what observes
    /// `AVPlayerItem.status` and knows its own surface generation.
    var onPreparationFailure: (@MainActor (UInt64, String, Bool) -> Void)? {
        get { player.onPreparationFailure }
        set { player.onPreparationFailure = newValue }
    }
    var onAudioDropped: (@MainActor (String) -> Void)? {
        get { player.onAudioDropped }
        set { player.onAudioDropped = newValue }
    }
    var onHealthEvent: (@MainActor (NativeVideoHealthEvent) -> Void)? {
        get { player.onHealthEvent }
        set { player.onHealthEvent = newValue }
    }
    var stateSummary: String { player.stateSummary }
    func restartPlayback(reason: String) -> Bool { player.restartPlayback(reason: reason) }
    func verifyPlayback(reason: String) { player.verifyPlayback(reason: reason) }
    func present() { orderFrontRegardless() }
    func stop() {
        player.stop()
        orderOut(nil)
        close()
    }
}

/// The window's content view. It tells the player about every change to the
/// display's size or pixel density the moment it happens.
///
/// `setFrameSize` rather than `layout()`: a window that is not on screen
/// never lays its views out, and a wallpaper window moved between displays
/// must not show the picture at the old display's geometry until it is.
final class NativeVideoContainerView: NSView {
    weak var player: NativeVideoPlayer?
    /// Another kind of player's way of hearing about the same changes.
    var onLayout: ((CGRect, CGFloat) -> Void)?

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        relayoutPlayer()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        relayoutPlayer()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        relayoutPlayer()
    }

    private func relayoutPlayer() {
        let scale = window?.backingScaleFactor ?? 1
        player?.relayout(bounds: bounds, backingScale: scale)
        onLayout?(bounds, scale)
    }
}

extension BridgeScalingMode {
    /// The same choice as the layout rules, which the lock-screen extension shares, name it.
    var layoutMode: NativeVideoScalingMode {
        switch self {
        case .none: .none
        case .stretch: .stretch
        case .match: .match
        case .fill: .fill
        case .matchBlurred: .matchBlurred
        }
    }
}
