import AppKit
import WebKit

@MainActor
protocol WebWallpaperSurface: AnyObject {
    var page: WebWallpaperPage { get }
    /// The window server's number for the surface's window.
    var windowNumber: Int { get }
    var frame: NSRect { get }
    var posterLayer: CALayer? { get }
    func setScreenFrame(_ frame: NSRect)
    func present()
    func retire()
}

/// Borderless desktop-level window hosting one web wallpaper on one display.
/// Mirrors the renderer's `MWEWallpaperDesktopWindow` configuration so the
/// presentation policy and poster sync can treat both kinds alike. The
/// Objective-C name is stable: `WallpaperPresentationPolicy` and
/// `DesktopWallpaperSync` look it up by string.
@objc(MWEWebWallpaperDesktopWindow)
final class WebWallpaperWindow: NSWindow {
    let page: WebWallpaperPage

    init(frame: NSRect, page: WebWallpaperPage) {
        self.page = page
        super.init(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
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
        // The web view is a subview of a stable container rather than the
        // content view itself: suspension removes it from the window tree, and
        // the desktop poster sync identifies this surface by the content
        // layer, which must survive that.
        let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        container.autoresizesSubviews = true
        contentView = container
        page.attach(to: container)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    /// WebKit only hit-tests hover moves for pages whose window is active, and
    /// it derives that from `isKeyWindow`. A desktop window can never really be
    /// key (it must not take keyboard focus from the user's app), so it reports
    /// key to WebKit alone; AppKit never routes events to it either way.
    override var isKeyWindow: Bool { true }

    /// Desktop windows must cover the whole display, including under the menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

extension WebWallpaperWindow: WebWallpaperSurface {
    var posterLayer: CALayer? { contentView?.layer }
    func setScreenFrame(_ frame: NSRect) { setFrame(frame, display: true) }
    func present() { orderFrontRegardless() }
    func retire() { orderOut(nil); close() }
}

/// One `WKWebView` running a Wallpaper Engine web project, with the host side
/// of the `wallpaperPropertyListener` protocol.
@MainActor
final class WebWallpaperPage: NSObject, WKNavigationDelegate {
    /// How often a crashing page may be restarted, and what earns the budget
    /// back. A page that keeps dying after a successful load must stop being
    /// restarted; only a stable run clears its history.
    struct RecoveryPolicy {
        var maximumRestarts = 3
        var window: Duration = .seconds(120)
        var stableRun: Duration = .seconds(60)
        var initialBackoff: Duration = .seconds(2)
        var maximumBackoff: Duration = .seconds(30)
    }

    /// How long a paused page keeps running after its document finishes loading
    /// before the host detaches it, whether the user paused it or it is paused
    /// only because they are working on another display. `didFinish` fires
    /// before the first meaningful paint, the renderer defers a battery pause
    /// until the host reports startup, and a wallpaper can be applied while
    /// paused. Detaching at once would snapshot a blank view and may stop WebKit
    /// finishing the load, so the page gets this long to draw one frame first.
    /// The default matches the first settle capture of `DesktopWallpaperSync`.
    struct Timing {
        var firstFrameGrace: Duration = .seconds(3)
    }

    /// Everything the host has committed to this wallpaper. A reloaded document
    /// starts with none of it, so the whole snapshot is replayed on each new
    /// document generation rather than only the values that changed since.
    private struct CommittedState {
        var propertiesJSON: String?
        var fps: UInt32?
        /// The refresh rate of the display the page is on, 0 while unknown.
        var displayRefreshRate = 0
        /// Multiplies the page's `devicePixelRatio`; 1 is the display's own.
        var renderScale: Float = 1
        var volume: Float = 1
        var muted = false
        /// The bridge's composed pause, not only the Play/Pause button: user
        /// pause, battery Pause, and the renderer's own presentation and
        /// per-display suspension all arrive through `BridgeWebWallpaper.paused`.
        var userPaused = false
        var presentationSuspended = false
        /// The presentation suspension leaves the display in the user's sight, as
        /// when they chose to play only where they are working: nothing covers or
        /// sleeps the display, so the page still owes it a first frame.
        var suspendedInPlainSight = false

        /// The page pauses when the user paused playback or the presentation
        /// policy suspended rendering; either alone is sufficient.
        var isPaused: Bool { userPaused || presentationSuspended }
    }

    let webView: WKWebView
    let projectURL: URL
    let entryURL: URL
    /// Symlink-resolved entry path, used for identity only: two descriptors name
    /// the same page when this matches, whatever spelling the entry file used.
    let canonicalEntryURL: URL
    /// Whether the page draws at its display's full refresh instead of WebKit's
    /// default cadence near 60 fps. WebKit also hands a page one pointer move
    /// per drawn frame, so this caps hover too. WebKit reads it only when the
    /// web view is created, so it is fixed for the life of the page.
    let rendersAtDisplayRefresh: Bool
    private(set) var isLoaded = false
    /// Increments on every `load()`. Async host calls carry the generation they
    /// were issued for, so a late completion cannot write into a newer document.
    private(set) var documentGeneration: UInt64 = 0
    private var committed = CommittedState()
    private(set) var audioOutputCapabilities: WebWallpaperAudioOutput.Capabilities?
    private let surface: RuntimeSurfaceKey
    private let counters: RuntimeCounters
    private let recovery: RecoveryPolicy
    private let timing: Timing
    private let now: @MainActor () -> ContinuousClock.Instant
    private let wait: @Sendable (Duration) async throws -> Void
    private var restartHistory: [ContinuousClock.Instant] = []
    private var restartTask: Task<Void, Never>?
    /// Whether the current document has had its first-frame grace since it
    /// finished loading. A user pause waits for it, and so does a suspension of
    /// a display still in the user's sight; any other presentation suspension is
    /// immediate, as a surface that is already hidden never attaches. The grace
    /// counts only time the view is in the window: a page that finished loading
    /// while covered has drawn nothing yet.
    private var firstFrameSettled = false
    private var firstFrameTask: Task<Void, Never>?
    /// When the current document finished loading, so a crash can tell a page
    /// that ran stably from one that died shortly after every load.
    private var lastLoadFinished: ContinuousClock.Instant?
    private weak var container: NSView?
    private var placeholder: NSImageView?
    private(set) var hostSuspended = false
    /// The last frame captured when the view left the window tree; nil while the
    /// view is attached or when the snapshot failed. The desktop poster sync is
    /// answered from it, because a detached view cannot be snapshotted reliably.
    private(set) var suspensionPoster: NSImage?
    /// Invalidates an in-flight suspension poster when the decision changes.
    private var suspensionGeneration: UInt64 = 0
    /// Raised after host suspension turns on or off. The grace expiry has no
    /// host call behind it, so the host learns about it from here.
    var onHostSuspensionChanged: (@MainActor () -> Void)?
    /// A property change reached the paused page and `suspensionPoster` now holds
    /// the frame it drew, so the Space posters can be read again.
    var onSuspensionPosterRefreshed: (@MainActor () -> Void)?
    /// Set while a change shown to a paused page waits for the frame it will be
    /// detached with.
    private var posterOwed = false
    var onFailure: (@MainActor (String) -> Void)?
    var onLoaded: (@MainActor () -> Void)?
    var onLoading: (@MainActor () -> Void)?

    /// Which of the page's own media listeners a payload belongs to. Kept as a
    /// plain slot name so this file never has to know what a media property or
    /// a thumbnail actually contains.
    enum MediaSlot: String {
        case status, properties, thumbnail, playback, timeline
    }

    /// What the host must currently do for this page. `listening` is the page's
    /// own registration; `consuming` additionally requires the user's media
    /// integration setting, because a page that asked for the status listener
    /// still has to be told the feature is off without anything being captured.
    struct MediaDemand: Equatable {
        var listening = false
        var consuming = false
    }

    private struct RandomFileReply {
        var requestId: String
        var property: String
        var path: String
    }

    private struct DirectoryChange {
        var property: String
        var added: [String]
        var removed: [String]
    }

    /// Registered by the current document, so a reload or a crash restart starts
    /// from no subscription at all rather than inheriting the old one.
    private var audioListenerRegistered = false
    private var mediaListenerRegistered = false
    private var audioResponseEnabled = false
    private var mediaIntegrationEnabled = false
    private var audioDemand = false
    private var mediaDemand = MediaDemand()
    private var pendingRandomFileRequests: Set<String> = []
    /// Answers and directory deltas that arrived while the page was suspended.
    /// Media and audio are dropped instead: both are re-derived from current
    /// state on resume, whereas a dropped reply strands the page's callback and
    /// a dropped removal leaves a deleted file in its list.
    private var deferredRandomFileReplies: [RandomFileReply] = []
    private var deferredDirectoryChanges: [DirectoryChange] = []
    /// A page cannot be allowed to grow host memory by asking without waiting,
    /// nor to bank an unbounded replay across a long suspension.
    private static let maximumPendingRandomFileRequests = 32
    private static let maximumDeferredDirectoryChanges = 64
    private let messageProxy = ScriptMessageProxy()
    /// Installing the host script replaces the controller's whole script list,
    /// so the scripts the page's owner adds beside it (the preview denies
    /// capture) are kept here and installed again after it.
    private var extraUserScripts: [WKUserScript] = []
    /// Raised when the page's audio subscription actually changes, so the host
    /// can open and close the capture tap on real demand.
    var onAudioDemandChanged: (@MainActor (Bool) -> Void)?
    var onMediaDemandChanged: (@MainActor (MediaDemand) -> Void)?
    var onRandomFileRequest: (@MainActor (_ requestId: String, _ propertyId: String) -> Void)?


    /// `WKUserContentController` retains its message handlers, and the page owns
    /// that controller through its web view: conforming the page itself would
    /// make the pair immortal. The proxy owns nothing.
    private final class ScriptMessageProxy: NSObject, WKScriptMessageHandler {
        weak var page: WebWallpaperPage?

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            // The channel is registered for every frame, but only the wallpaper's
            // own document speaks for it: a frame it embeds, which may belong to
            // a remote site, must not subscribe to audio or ask for files.
            guard message.frameInfo.isMainFrame else { return }
            let body = message.body
            MainActor.assumeIsolated { page?.receiveScriptMessage(body) }
        }
    }

    /// `WKWebView` has no public entry point for hover: moves reach it through a
    /// private tracking-area owner, so hover uses the `_simulateMouseMove:`
    /// family WebKit ships for exactly this purpose. Clicks, drags and scrolls
    /// go through the ordinary responder methods.
    private static let simulateMove = NSSelectorFromString("_simulateMouseMove:")
    private static let simulateExit = NSSelectorFromString("_simulateMouseExit:")
    static var supportsHover: Bool { WKWebView.instancesRespond(to: simulateMove) }
    private static var hoverUnavailableLogged = false
    private static var fullRefreshUnavailableLogged = false

    /// WebKit keeps a page's rendering updates near 60 fps even on a faster
    /// display. The switch is a WebKit feature flag with no public setter, so it
    /// is reached through the same feature list Safari's developer settings
    /// use. Returns false when the running WebKit no longer offers it.
    private static func allowRenderingAboveNear60FPS(_ preferences: WKPreferences) -> Bool {
        let featuresSelector = NSSelectorFromString("_features")
        let setSelector = NSSelectorFromString("_setEnabled:forFeature:")
        guard WKPreferences.responds(to: featuresSelector), preferences.responds(to: setSelector),
              let features = WKPreferences.perform(featuresSelector)?.takeUnretainedValue() as? [NSObject],
              let feature = features.first(where: {
                  $0.value(forKey: "key") as? String == "PreferPageRenderingUpdatesNear60FPSEnabled"
              })
        else { return false }
        typealias SetEnabled = @convention(c) (AnyObject, Selector, Bool, AnyObject) -> Void
        unsafeBitCast(preferences.method(for: setSelector), to: SetEnabled.self)(
            preferences, setSelector, false, feature)
        return true
    }


    /// The `load#N` of the log header written when this page was opened; its
    /// later lines carry it so they can be told apart from another display's.
    var logLoad: UInt64?

    /// Closures are optional so their `@MainActor` defaults are built inside
    /// this initializer rather than in a caller-evaluated default argument.
    init(
        projectURL: URL,
        entryFile: String,
        surface: RuntimeSurfaceKey = RuntimeSurfaceKey(kind: .desktopWeb, displayID: 0),
        counters: RuntimeCounters? = nil,
        persistentData: Bool = true,
        inspectable: Bool = false,
        rendersAtDisplayRefresh: Bool = false,
        recovery: RecoveryPolicy = RecoveryPolicy(),
        timing: Timing = Timing(),
        now: (@MainActor () -> ContinuousClock.Instant)? = nil,
        wait: (@Sendable (Duration) async throws -> Void)? = nil
    ) {
        self.projectURL = projectURL
        self.entryURL = projectURL.appendingPathComponent(entryFile)
        self.canonicalEntryURL = WebWallpaperProtocol.canonicalEntryURL(projectURL: projectURL, entryFile: entryFile)
            ?? self.entryURL.standardizedFileURL
        self.surface = surface
        self.rendersAtDisplayRefresh = rendersAtDisplayRefresh
        self.counters = counters ?? .shared
        self.recovery = recovery
        self.timing = timing
        self.now = now ?? { ContinuousClock.now }
        self.wait = wait ?? { try await Task.sleep(for: $0) }
        let configuration = WKWebViewConfiguration()
        // Persistent: web wallpapers keep their own state (tasks, favourites) in
        // localStorage exactly as they do under Wallpaper Engine.
        configuration.websiteDataStore = persistentData ? .default() : .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        // Wallpaper Engine loads projects from file:// with sibling-file access;
        // ES modules and fetch() against project assets need the same origin
        // relaxation WebKit only exposes through these preference keys.
        configuration.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        configuration.setValue(true, forKey: "allowUniversalAccessFromFileURLs")
        // Lets WebKit throttle this page's own work once it leaves the window
        // tree. Media playback and capture are documented exceptions, which is
        // why suspension also suspends media explicitly.
        configuration.preferences.inactiveSchedulingPolicy = .suspend
        if rendersAtDisplayRefresh && !Self.allowRenderingAboveNear60FPS(configuration.preferences)
            && !Self.fullRefreshUnavailableLogged {
            Self.fullRefreshUnavailableLogged = true
            AppLog.warn("WebKit rendering-rate control unavailable; web wallpapers stay near 60 fps")
        }
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        messageProxy.page = self
        // Registered on the web view's own controller: `WKWebView` copies the
        // configuration it is given, so only the one reached through the web
        // view is guaranteed to be the live object. The host script is added
        // per document, in `load()`.
        webView.configuration.userContentController.add(messageProxy, name: WebWallpaperProtocol.messageHandlerName)
        webView.navigationDelegate = self
        webView.underPageBackgroundColor = .black
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsMagnification = false
        webView.setValue(false, forKey: "drawsBackground")
        // The presentation policy owns occlusion, including its settling delay.
        // WebKit otherwise stops rAF independently during a brief Space/desktop
        // transition, even when the host never suspends this page. Ignoring only
        // window occlusion keeps attached pages animating; host suspension still
        // detaches the view and applies inactiveSchedulingPolicy above.
        let occlusionSelector = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        if webView.responds(to: occlusionSelector) {
            typealias SetOcclusionDetection = @convention(c) (AnyObject, Selector, Bool) -> Void
            unsafeBitCast(webView.method(for: occlusionSelector), to: SetOcclusionDetection.self)(
                webView, occlusionSelector, false)
        } else {
            AppLog.warn("WebKit window occlusion control unavailable; web wallpapers use system scheduling")
        }
        webView.isInspectable = inspectable
    }

    /// Whether Safari's Web Inspector may attach to this page. The owner decides
    /// (see `WebWallpaperInspection`); it can change while the page runs.
    var isInspectable: Bool { webView.isInspectable }

    func setInspectable(_ enabled: Bool) {
        guard webView.isInspectable != enabled else { return }
        webView.isInspectable = enabled
    }

    func load() {
        // First, so the document about to start already carries the committed
        // frame-rate limit: its very first `requestAnimationFrame` call is paced.
        installUserScripts()
        restartTask?.cancel()
        restartTask = nil
        isLoaded = false
        documentGeneration += 1
        lastLoadFinished = nil
        resetFirstFrameWindow()
        forgetDocumentState()
        // A user-paused page that was detached has to be back in the window to
        // load, and is suspended again after its next first frame.
        reconcileHostSuspension()
        onLoading?()
        deliverAudioOutput()
        webView.loadFileURL(entryURL, allowingReadAccessTo: projectURL)
    }

    func stop() {
        restartTask?.cancel()
        restartTask = nil
        resetFirstFrameWindow()
        lastLoadFinished = nil
        // Invalidate any host call still in flight for the document being torn
        // down, so it cannot reach the blank page that replaces it.
        documentGeneration += 1
        isLoaded = false
        forgetDocumentState()
        _ = WebWallpaperAudioOutput.apply(volume: committed.volume, muted: true, to: webView)
        messageProxy.page = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: WebWallpaperProtocol.messageHandlerName)
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.loadHTMLString("", baseURL: nil)
    }

    /// Adds a script to run at the start of every document, after the host script.
    func addUserScript(_ script: WKUserScript) {
        extraUserScripts.append(script)
        installUserScripts()
    }

    /// Rebuilds the user scripts from the committed state. A script cannot be
    /// replaced alone, and the frame-rate limit and render scale are baked into
    /// the host script so a document sees them from its first line; the live
    /// paths in `deliverGeneralProperties` and `deliverRenderScale` keep a
    /// running document in step afterwards.
    private func installUserScripts() {
        let seed = WebWallpaperProtocol.Seed(
            framePacing: true, frameLimit: frameLimit, renderScale: Double(committed.renderScale))
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        for script in WebWallpaperProtocol.userScripts(seed: seed) { controller.addUserScript(script) }
        for script in extraUserScripts { controller.addUserScript(script) }
    }

    /// Rendering updates per second this page gets from WebKit: near 60, the
    /// display's refresh when that is lower, or the full refresh of a page created
    /// to draw at it.
    private var renderRate: Int {
        WebWallpaperProtocol.renderRate(
            displayRefreshRate: committed.displayRefreshRate, rendersAtDisplayRefresh: rendersAtDisplayRefresh)
    }

    /// Callbacks per second the page's `requestAnimationFrame` is held to, 0 for
    /// none: a frame rate that reaches `renderRate` leaves the page alone.
    private var frameLimit: Int {
        committed.fps.map { WebWallpaperProtocol.frameLimit(forFPS: $0, renderRate: renderRate) } ?? 0
    }

    /// The fewest seconds between two pointer moves forwarded to the page: no
    /// more than the page draws a second (WebKit hands it one move per drawn
    /// frame, so 60 near its default cadence and the display's refresh for a page
    /// that draws at it), and no more than the frame limit, since a page held to
    /// 30 frames cannot show 60 positions. Below 10 a second hover would stop
    /// following the pointer, so a very low limit does not slow it further.
    var pointerMoveInterval: TimeInterval {
        let limit = frameLimit
        return 1 / Double(limit == 0 ? renderRate : max(limit, Self.minimumPointerRate))
    }

    private static let minimumPointerRate = 10

    /// Drops everything that belonged to the document being replaced. The new
    /// document re-registers its own listeners, so inheriting the old ones would
    /// leave the capture tap open for a page that never asked for it, and would
    /// let a reply to a request the previous document made reach the new one.
    private func forgetDocumentState() {
        audioListenerRegistered = false
        mediaListenerRegistered = false
        pendingRandomFileRequests.removeAll()
        deferredRandomFileReplies.removeAll()
        deferredDirectoryChanges.removeAll()
        refreshDemand()
    }

    /// `propertiesJSON` is the bridge's `{ id: { value, type, … } }` payload,
    /// with any staged `file` value already substituted by the host. `restaged`
    /// names the `file` properties whose bytes the host replaced under the same
    /// staged path: their value reads as before, so the page is told to take them
    /// in again, once, and a paused page draws the new content like any edit.
    func applyUserProperties(json propertiesJSON: String, restaged: Set<String> = []) {
        let changed = committed.propertiesJSON != propertiesJSON || !restaged.isEmpty
        committed.propertiesJSON = propertiesJSON
        deliverUserProperties(restaged: restaged)
        if changed { showChangeWhilePaused() }
    }

    /// A change to a page that only its pause holds still would wait in the
    /// suspended web process until the user plays, and the desktop would keep
    /// the frame from before the edit. The page is given the first-frame grace
    /// again, so the change draws, and is detached again with the frame it drew.
    /// A page that is also covered waits for the cover to end, since it draws
    /// nothing meanwhile. Only a change to what the page shows counts: the frame
    /// limit and the render scale change how it draws, and apply when it plays.
    private func showChangeWhilePaused() {
        guard isLoaded, committed.userPaused, firstFrameSettled else { return }
        posterOwed = true
        resetFirstFrameWindow()
        reconcileHostSuspension()
    }

    func applyGeneralProperties(fps: UInt32) {
        let before = frameLimit
        committed.fps = fps
        logFrameLimit(changedFrom: before)
        deliverGeneralProperties()
    }

    /// The internal render scale in force. The page's `devicePixelRatio` is
    /// multiplied by it, so a page that sizes its drawing buffers from the ratio
    /// draws fewer pixels. A running document is told at once and rebuilds on the
    /// resize event that follows; a new document starts with it.
    func applyRenderScale(_ scale: Float) {
        let clamped = Float(WebWallpaperProtocol.clampedRenderScale(Double(scale)))
        guard clamped != committed.renderScale else { return }
        committed.renderScale = clamped
        AppLog.debug("web wallpaper \(projectURL.lastPathComponent): render scale \(clamped)", load: logLoad)
        deliverRenderScale()
    }

    /// The refresh rate of the display the page is on. It sets the rate the page
    /// draws at, so a frame rate that reached the old rate may no longer reach the
    /// new one (a display moved to a lower refresh), and a running document is
    /// told when the limit that follows from it changes.
    func applyDisplayRefreshRate(_ refreshRate: Int) {
        guard refreshRate != committed.displayRefreshRate else { return }
        let before = frameLimit
        committed.displayRefreshRate = refreshRate
        guard frameLimit != before else { return }
        logFrameLimit(changedFrom: before)
        deliverGeneralProperties()
    }

    private func logFrameLimit(changedFrom before: Int) {
        guard frameLimit != before else { return }
        AppLog.debug("""
            web wallpaper \(projectURL.lastPathComponent): frame limit \
            \(frameLimit == 0 ? "none" : String(frameLimit))
            """, load: logLoad)
    }

    func applyAudioOutput(volume: Float, muted: Bool) {
        guard committed.volume != volume || committed.muted != muted || audioOutputCapabilities == nil else {
            return
        }
        committed.volume = volume
        committed.muted = muted
        deliverAudioOutput()
    }

    func setPaused(_ paused: Bool) {
        committed.userPaused = paused
        if !paused { posterOwed = false }
        deliverPaused()
        reconcileHostSuspension()
        refreshDemand()
    }

    /// The user's per-wallpaper audio-response setting. Audio only reaches the
    /// page when the page asked for it *and* the user allowed it, so a page that
    /// registers a listener on a wallpaper with the setting off opens no tap.
    func setAudioResponseEnabled(_ enabled: Bool) {
        guard enabled != audioResponseEnabled else { return }
        audioResponseEnabled = enabled
        refreshDemand()
    }

    /// The user's per-wallpaper media-integration setting. Unlike audio this
    /// does not gate the status listener: a page is told the feature is off.
    func setMediaIntegrationEnabled(_ enabled: Bool) {
        guard enabled != mediaIntegrationEnabled else { return }
        mediaIntegrationEnabled = enabled
        refreshDemand()
    }

    /// Hosts the web view inside its window's container and remembers it, so
    /// suspension can take the view out of the window tree and put it back.
    func attach(to container: NSView) {
        self.container = container
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        guard !hostSuspended else { return }
        container.addSubview(webView)
    }

    /// `stillVisible` says the suspension does not hide the display: the user can
    /// see it and it is paused only because they are working on another one. Such
    /// a page draws its first frame before it is detached, as a paused page does,
    /// so a wallpaper set on that display is not left black. A hidden display
    /// needs no frame and its page is detached at once.
    func setPresentationSuspended(_ suspended: Bool, stillVisible: Bool = false) {
        committed.presentationSuspended = suspended
        committed.suspendedInPlainSight = suspended && stillVisible
        deliverPaused()
        reconcileHostSuspension()
    }

    /// The host suspends a page while no pixel can reach a display, and while it
    /// is paused once it has drawn its first frame. Both go through
    /// `applyHostSuspension`, so a page that ignores `setPaused` stops
    /// regardless; the two reasons compose, and clearing one leaves the other
    /// in force.
    private func reconcileHostSuspension() {
        applyHostSuspension(presentationHolds || userPauseHolds)
        runFirstFrameWindow()
    }

    private var userPauseHolds: Bool { committed.userPaused && firstFrameSettled }

    /// A presentation suspension holds at once unless the display is in the
    /// user's sight, when it waits for the first frame like a user pause.
    private var presentationHolds: Bool {
        committed.presentationSuspended && (!committed.suspendedInPlainSight || firstFrameSettled)
    }

    private func resetFirstFrameWindow() {
        firstFrameTask?.cancel()
        firstFrameTask = nil
        firstFrameSettled = false
    }

    /// Runs the first-frame grace of the loaded document while its view is in
    /// the window, and holds it while the view is out: a covered page draws
    /// nothing, so time spent covered would let a paused page detach with a
    /// blank frame the moment it is uncovered. Whatever changes where the view
    /// is ends up here through `reconcileHostSuspension`, so the grace starts
    /// when the page is first in view and starts over after each interruption.
    /// A zero grace settles at once instead of scheduling a task.
    private func runFirstFrameWindow() {
        if hostSuspended {
            firstFrameTask?.cancel()
            firstFrameTask = nil
            return
        }
        guard isLoaded, !firstFrameSettled, firstFrameTask == nil else { return }
        let grace = timing.firstFrameGrace
        guard grace > .zero else {
            firstFrameSettled = true
            reconcileHostSuspension()
            return
        }
        firstFrameTask = Task { @MainActor [weak self, wait] in
            try? await wait(grace)
            guard let self, !Task.isCancelled else { return }
            self.firstFrameTask = nil
            self.firstFrameSettled = true
            self.reconcileHostSuspension()
        }
    }

    /// Suspension the page cannot opt out of.
    ///
    /// `wallpaperPropertyListener.setPaused` is cooperative: a page that does
    /// not implement it, or that only stops part of its animation, keeps its
    /// timers, workers, WebGL and media running. Two host-side controls do not
    /// depend on the page at all — suspending media playback, and taking the
    /// web view out of the window tree, which is the documented condition for
    /// WebKit's inactive scheduling policy. Neither wraps
    /// `requestAnimationFrame` and neither touches the shared WebContent
    /// process, which other wallpapers and the control panel also use.
    private func applyHostSuspension(_ suspended: Bool) {
        guard suspended != hostSuspended else { return }
        hostSuspended = suspended
        suspensionGeneration += 1
        let generation = suspensionGeneration
        if suspended {
            // Suspend, never pause: unsuspending restores what each element was
            // doing, so media the user had paused stays paused.
            webView.setAllMediaPlaybackSuspended(true)
            counters.record(.webMediaSuspended, for: surface)
            captureDetachPoster(generation: generation)
        } else {
            reattachWebView()
            webView.setAllMediaPlaybackSuspended(false)
            counters.record(.webMediaResumed, for: surface)
        }
        // After the view tree has settled, so a resume flushes into a page that
        // is back where WebKit will run it.
        refreshDemand()
        if !suspended { flushDeferredDeliveries() }
        AppLog.debug("""
            web wallpaper \(projectURL.lastPathComponent): host suspension \
            \(suspended ? "on (\(suspensionReason))" : "off")
            """, load: logLoad)
        onHostSuspensionChanged?()
    }

    private var suspensionReason: String {
        switch (userPauseHolds, presentationHolds) {
        case (true, true): "both"
        case (true, false): "user pause"
        default: "presentation"
        }
    }

    /// Keeps the last frame on screen while the web view is out of the window.
    /// The snapshot is asynchronous, so a resume that arrives first cancels it.
    private func captureDetachPoster(generation: UInt64) {
        guard container != nil else { return }
        webView.takeSnapshot(with: nil) { [weak self] image, error in
            MainActor.assumeIsolated {
                guard let self, self.suspensionGeneration == generation, self.hostSuspended else { return }
                if let error {
                    AppLog.debug("""
                        web wallpaper \(self.projectURL.lastPathComponent): \
                        suspension poster unavailable: \(error.localizedDescription)
                        """, load: self.logLoad)
                }
                self.detachWebView(poster: image)
            }
        }
    }

    private func detachWebView(poster: NSImage?) {
        guard let container, webView.superview === container else { return }
        let placeholder = NSImageView(frame: container.bounds)
        placeholder.autoresizingMask = [.width, .height]
        placeholder.imageScaling = .scaleAxesIndependently
        placeholder.image = poster
        placeholder.wantsLayer = true
        container.addSubview(placeholder)
        self.placeholder = placeholder
        suspensionPoster = poster
        webView.removeFromSuperview()
        counters.record(.webDetached, for: surface)
        if posterOwed {
            posterOwed = false
            onSuspensionPosterRefreshed?()
        }
    }

    private func reattachWebView() {
        suspensionPoster = nil
        guard let container else { return }
        if webView.superview !== container {
            webView.frame = container.bounds
            container.addSubview(webView)
            counters.record(.webAttached, for: surface)
        }
        placeholder?.removeFromSuperview()
        placeholder = nil
    }

    /// Whether the web view is currently in its window's view tree. WebKit's
    /// inactive scheduling policy keys off exactly this.
    var isInWindowTree: Bool { container != nil && webView.superview === container }

    /// `restaged` is not committed: a document that loads later is given the whole
    /// set, which already carries the new staged bytes.
    private func deliverUserProperties(restaged: Set<String> = []) {
        guard isLoaded, let json = committed.propertiesJSON else { return }
        run(
            "window.__mweWallpaperHost.applyUserProperties(JSON.parse(json), restaged)",
            arguments: ["json": json, "restaged": restaged.sorted()])
    }

    private func deliverGeneralProperties() {
        guard isLoaded, let fps = committed.fps else { return }
        // One call, so the page's listener and its frame pacing change together.
        run("""
            window.__mweWallpaperHost.applyGeneralProperties(general);
            window.__mweWallpaperHost.setFrameLimit(limit);
            """, arguments: ["general": ["fps": Int(fps)], "limit": frameLimit])
    }

    private func deliverRenderScale() {
        guard isLoaded else { return }
        run("window.__mweWallpaperHost.setRenderScale(scale)", arguments: ["scale": Double(committed.renderScale)])
    }

    private func deliverAudioOutput() {
        audioOutputCapabilities = WebWallpaperAudioOutput.apply(
            volume: committed.volume, muted: committed.muted || committed.volume == 0, to: webView)
    }

    private func deliverPaused() {
        guard isLoaded else { return }
        run("window.__mweWallpaperHost.setPaused(paused)", arguments: ["paused": committed.isPaused])
    }

    /// Replays the whole committed snapshot into a freshly loaded document. A
    /// descriptor diff cannot do this: after a crash and reload nothing has
    /// changed, so nothing would be sent and the page would start blank.
    private func replayCommittedState() {
        counters.record(.webStateReplayed, for: surface)
        deliverAudioOutput()
        deliverUserProperties()
        deliverGeneralProperties()
        deliverRenderScale()
        deliverPaused()
    }

    // MARK: - author API delivery

    /// One audio frame: 128 floats, indices 0-63 the left channel and 64-127
    /// the right, as the Wallpaper Engine listener contract specifies.
    func deliverAudio(_ bins: [Float], completion: (@MainActor (Bool) -> Void)? = nil) {
        guard audioDemand, bins.count == 128, bins.allSatisfy(\.isFinite) else { completion?(false); return }
        let generation = documentGeneration
        Task { @MainActor [weak self] in
            guard let self, self.documentGeneration == generation, self.audioDemand else { completion?(false); return }
            do {
                let delivered = try await self.webView.callAsyncJavaScript(
                    "return window.__mweWallpaperHost.deliverAudio(bins)",
                    arguments: ["bins": bins.map { Double($0) }], in: nil, contentWorld: .page) as? Bool
                completion?(delivered == true && self.documentGeneration == generation && self.audioDemand)
            } catch { completion?(false) }
        }
    }

    /// One media listener payload. The host builds the event object, so this
    /// file never has to model what the system knows about the playing track.
    /// Dropped rather than deferred while suspended: the host replays current
    /// state on resume, and a stale event is worse than a late one.
    func deliverMediaEvent(slot: MediaSlot, event: [String: Any]) {
        guard mediaDemand.listening else { return }
        run("window.__mweWallpaperHost.deliverMedia(slot, event)",
            arguments: ["slot": slot.rawValue, "event": event])
    }

    /// Answers a `wallpaperRequestRandomFileForProperty` call. `token` is the
    /// value handed out with the request. A token the current document never
    /// asked for is dropped: the page numbers its own requests from one per
    /// document, so after a reload the previous wallpaper's answer would
    /// otherwise match the new page's first request exactly.
    func deliverRandomFile(requestId token: String, property: String, path: String) {
        guard pendingRandomFileRequests.remove(token) != nil,
              let separator = token.firstIndex(of: ":")
        else { return }
        let reply = RandomFileReply(
            requestId: String(token[token.index(after: separator)...]), property: property, path: path)
        guard isLoaded, !hostSuspended else {
            deferredRandomFileReplies.append(reply)
            return
        }
        send(reply)
    }

    /// A `fetchall` directory delta. Deltas are ordered, so a suspension holds
    /// them rather than dropping them: replaying only the current set would
    /// leave files the user deleted in the page's list.
    func deliverDirectoryFiles(property: String, added: [String], removed: [String]) {
        guard !added.isEmpty || !removed.isEmpty else { return }
        // A new document is sent the whole current set instead, so anything
        // buffered for the old one would arrive twice.
        guard isLoaded else { return }
        let change = DirectoryChange(property: property, added: added, removed: removed)
        guard !hostSuspended else {
            if deferredDirectoryChanges.count >= Self.maximumDeferredDirectoryChanges {
                deferredDirectoryChanges.removeFirst()
                AppLog.debug("""
                    web wallpaper \(projectURL.lastPathComponent): directory changes outran \
                    the suspension buffer; the oldest delta was dropped
                    """, load: logLoad)
            }
            deferredDirectoryChanges.append(change)
            return
        }
        send(change)
    }

    private func send(_ reply: RandomFileReply) {
        run("window.__mweWallpaperHost.deliverRandomFile(requestId, property, path)",
            arguments: ["requestId": reply.requestId, "property": reply.property, "path": reply.path])
    }

    private func send(_ change: DirectoryChange) {
        if !change.added.isEmpty {
            run("window.__mweWallpaperHost.userDirectoryFilesAddedOrChanged(property, files)",
                arguments: ["property": change.property, "files": change.added])
        }
        if !change.removed.isEmpty {
            run("window.__mweWallpaperHost.userDirectoryFilesRemoved(property, files)",
                arguments: ["property": change.property, "files": change.removed])
        }
    }

    private func flushDeferredDeliveries() {
        guard isLoaded, !hostSuspended else { return }
        let replies = deferredRandomFileReplies
        deferredRandomFileReplies.removeAll()
        for reply in replies { send(reply) }
        let changes = deferredDirectoryChanges
        deferredDirectoryChanges.removeAll()
        for change in changes { send(change) }
    }

    /// Recomputes what the host owes this page and reports only real changes,
    /// so a reconcile that alters nothing does not reopen the capture tap or
    /// re-add a consumer to the media provider.
    private func refreshDemand() {
        let live = isLoaded && !hostSuspended
        // The renderer stops capturing for a wallpaper the user paused, so nothing is polled for it.
        let audio = live && !committed.userPaused && audioListenerRegistered && audioResponseEnabled
        if audio != audioDemand {
            audioDemand = audio
            onAudioDemandChanged?(audio)
        }
        let media = MediaDemand(
            listening: live && mediaListenerRegistered,
            consuming: live && mediaListenerRegistered && mediaIntegrationEnabled)
        if media != mediaDemand {
            mediaDemand = media
            onMediaDemandChanged?(media)
        }
    }

    /// The one place that distrusts the page. Anything that is not a recognised
    /// tagged object with well-formed fields is dropped.
    fileprivate func receiveScriptMessage(_ body: Any) {
        guard let payload = body as? [String: Any], let type = payload["type"] as? String else {
            AppLog.debug("web wallpaper \(projectURL.lastPathComponent): malformed host message dropped", load: logLoad)
            return
        }
        switch type {
        case "audioSubscribed": audioListenerRegistered = true
        case "audioUnsubscribed": audioListenerRegistered = false
        case "mediaSubscribed": mediaListenerRegistered = true
        case "mediaUnsubscribed": mediaListenerRegistered = false
        case "randomFileRequest":
            guard let requestId = payload["requestId"] as? String, !requestId.isEmpty,
                  let propertyId = payload["propertyId"] as? String, !propertyId.isEmpty,
                  pendingRandomFileRequests.count < Self.maximumPendingRandomFileRequests
            else {
                AppLog.debug("""
                    web wallpaper \(projectURL.lastPathComponent): random file request dropped \
                    (malformed, or more than \(Self.maximumPendingRandomFileRequests) unanswered)
                    """, load: logLoad)
                return
            }
            // The page numbers its requests from one per document, so the id it
            // chose is only unique within that document. The token handed to
            // the host carries the generation, which makes it unique for the
            // life of the page.
            let token = "\(documentGeneration):\(requestId)"
            pendingRandomFileRequests.insert(token)
            onRandomFileRequest?(token, propertyId)
            return
        default:
            AppLog.debug("web wallpaper \(projectURL.lastPathComponent): unknown host message “\(type)” dropped", load: logLoad)
            return
        }
        refreshDemand()
    }

    private func run(_ script: String, arguments: [String: Any]) {
        let generation = documentGeneration
        Task { @MainActor [weak self] in
            guard let self, self.documentGeneration == generation else { return }
            do {
                _ = try await self.webView.callAsyncJavaScript(script, arguments: arguments, in: nil, contentWorld: .page)
            } catch {
                AppLog.warn("web wallpaper \(self.projectURL.lastPathComponent): host call failed: \(error.localizedDescription)", load: self.logLoad)
            }
        }
    }

    /// Replays a pointer event already rebased into the page's window. A
    /// suspended page consumes nothing: delivering to a view outside the window
    /// tree would both restart work and hit-test against stale geometry.
    func deliverMouse(_ event: NSEvent) {
        guard !hostSuspended else { return }
        counters.record(.pointerDelivered, for: surface)
        switch event.type {
        case .mouseMoved:
            guard Self.supportsHover else {
                if !Self.hoverUnavailableLogged {
                    Self.hoverUnavailableLogged = true
                    AppLog.warn("web wallpaper hover unavailable: WKWebView lacks _simulateMouseMove:")
                }
                return
            }
            webView.perform(Self.simulateMove, with: event)
        case .leftMouseDown: webView.mouseDown(with: event)
        case .leftMouseUp: webView.mouseUp(with: event)
        case .leftMouseDragged: webView.mouseDragged(with: event)
        case .rightMouseDown: webView.rightMouseDown(with: event)
        case .rightMouseUp: webView.rightMouseUp(with: event)
        case .rightMouseDragged: webView.rightMouseDragged(with: event)
        case .otherMouseDown: webView.otherMouseDown(with: event)
        case .otherMouseUp: webView.otherMouseUp(with: event)
        case .otherMouseDragged: webView.otherMouseDragged(with: event)
        case .scrollWheel: webView.scrollWheel(with: event)
        default: break
        }
    }

    /// Clears `:hover` and fires `mouseout` when the pointer leaves the desktop.
    func deliverMouseExit() {
        guard WKWebView.instancesRespond(to: Self.simulateExit),
              let exit = NSEvent.enterExitEvent(
                with: .mouseExited, location: NSPoint(x: -1, y: -1), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: webView.window?.windowNumber ?? 0,
                context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)
        else { return }
        webView.perform(Self.simulateExit, with: exit)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoaded = true
        lastLoadFinished = now()
        replayCommittedState()
        // A document that finishes again starts another grace; it runs once the
        // view is in the window, and a zero grace suspends the page right here.
        resetFirstFrameWindow()
        reconcileHostSuspension()
        // A document that already registered its listeners during load only
        // becomes deliverable now.
        refreshDemand()
        onLoaded?()
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // The page may fetch and embed anything it likes, but the top frame stays
        // on the project's own entry page: no wallpaper navigates the desktop away.
        guard action.targetFrame?.isMainFrame == true else {
            decisionHandler(.allow)
            return
        }
        decisionHandler(action.request.url?.standardizedFileURL == entryURL.standardizedFileURL ? .allow : .cancel)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        isLoaded = false
        onLoading?()
        // The crashed document's listeners died with it. Restarting inherits
        // nothing, so a page that crashes repeatedly cannot accumulate
        // subscriptions the host would keep feeding.
        resetFirstFrameWindow()
        forgetDocumentState()
        // The restart loads into the window tree, and a user-paused page is
        // suspended again after its next first frame.
        reconcileHostSuspension()
        let moment = now()
        // A load that finishes proves nothing on its own: a page that crashes
        // shortly after every load would otherwise clear its budget forever.
        // Only an uninterrupted run returns the restarts.
        if let finished = lastLoadFinished, moment - finished >= recovery.stableRun {
            restartHistory.removeAll()
        }
        lastLoadFinished = nil
        restartHistory.removeAll { moment - $0 >= recovery.window }
        guard restartHistory.count < recovery.maximumRestarts else {
            counters.record(.webRecoveryBudgetExhausted, for: surface)
            AppLog.error("""
                web wallpaper \(projectURL.lastPathComponent): content process terminated \
                \(restartHistory.count) times; restart budget exhausted
                """, load: logLoad)
            onFailure?(String(localized: "The web wallpaper stopped unexpectedly and could not be restarted."))
            return
        }
        // Back off exponentially so a page that dies immediately after loading
        // cannot spin the content process at full speed.
        let attempt = restartHistory.count
        restartHistory.append(moment)
        counters.record(.webRecoveryStarted, for: surface)
        let delay = min(recovery.initialBackoff * (1 << attempt), recovery.maximumBackoff)
        AppLog.warn("""
            web wallpaper \(projectURL.lastPathComponent): content process terminated; \
            restart \(attempt + 1) of \(recovery.maximumRestarts) in \(delay)
            """, load: logLoad)
        restartTask?.cancel()
        restartTask = Task { @MainActor [weak self, wait] in
            try? await wait(delay)
            guard let self, !Task.isCancelled else { return }
            self.restartTask = nil
            self.load()
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        isLoaded = false
        forgetDocumentState()
        onFailure?(error.localizedDescription)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoaded = false
        forgetDocumentState()
        onFailure?(error.localizedDescription)
    }
}
