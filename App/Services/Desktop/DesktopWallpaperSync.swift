import AppKit
import CryptoKit
import ImageIO
import QuartzCore
import UniformTypeIdentifiers

/// JPEG rather than PNG: a full-size Retina frame encodes several times faster
/// and is about a third of the size, and the system wallpaper is mostly seen
/// scaled down in Mission Control or for a moment beneath a loading renderer.
enum DesktopPosterEncoder {
    static let fileExtension = "jpg"
    static let quality = 0.9

    /// The picture behind renderer pixels, tagged sRGB like the renderer's own layer. Nil for
    /// pixels that do not fill `width` by `height` exactly or a size beyond what is read back.
    static func image(pixels: Data, width: Int, height: Int, bgra: Bool) -> CGImage? {
        guard let layout = pixelLayout(pixels: pixels, width: width, height: height) else { return nil }
        // BGRA is little-endian with the alpha slot first in the word; RGBA is big-endian with it last.
        let info = CGBitmapInfo(rawValue: bgra
            ? CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
            : CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue)
        guard let provider = CGDataProvider(data: pixels as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: layout.width, height: layout.height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: layout.width * 4, space: space, bitmapInfo: info, provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    static func jpeg(pixels: Data, width: Int, height: Int, bgra: Bool) throws -> Data {
        guard let picture = image(pixels: pixels, width: width, height: height, bgra: bgra) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, picture,
                                   [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return output as Data
    }

    /// Largest edge and pixel count a frame may have; beyond them a readback is not a wallpaper.
    private static let maximumEdge = 16_384
    private static let maximumPixels = 33_554_432

    /// The checked size of a frame whose byte count equals width times height times four.
    fileprivate static func pixelLayout(pixels: Data, width: Int, height: Int) -> (width: Int, height: Int)? {
        guard (1...maximumEdge).contains(width), (1...maximumEdge).contains(height),
              width * height <= maximumPixels, pixels.count == width * height * 4 else { return nil }
        return (width, height)
    }
}

/// What only the app does with a frame (`Shared/DesktopPosterFrame.swift` declares it and its
/// notification codec, which the lock-screen extension reads too).
extension DesktopPosterFrame {
    /// Identifies the pixels, so a frame identical to the current poster is
    /// neither encoded nor written again.
    var digest: Data {
        var hash = SHA256()
        withUnsafeBytes(of: (width, height, bgra)) { hash.update(bufferPointer: $0) }
        hash.update(data: pixels)
        return Data(hash.finalize())
    }

    static func rgba(_ image: CGImage) -> DesktopPosterFrame? {
        let width = image.width, height = image.height
        guard (1...16_384).contains(width), (1...16_384).contains(height), width * height <= 33_554_432,
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var pixels = Data(count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? DesktopPosterFrame(pixels: pixels, width: width, height: height, bgra: false) : nil
    }

    @MainActor
    func publish(for layer: CALayer, to center: NotificationCenter, context: String? = nil) {
        center.post(name: DesktopPosterNotification.ready, object: layer, userInfo: userInfo(context: context))
    }

    /// The frame as a picture; nil when its size and pixel count disagree or are beyond what the
    /// encoder accepts.
    func cgImage() -> CGImage? {
        DesktopPosterEncoder.image(pixels: pixels, width: width, height: height, bgra: bgra)
    }
}

/// `layer` identifies the surface: the renderer's `CAMetalLayer`, or a web
/// wallpaper view's backing layer. Its owner answers the poster request.
struct DesktopPosterSurface {
    var layer: CALayer
    var display: String
    /// The window server's number of the window the layer is in, when known: what tells which
    /// wallpaper it draws.
    var window: Int? = nil
}

enum DesktopPosterScope: Equatable {
    case all
    case desktop(id: String, context: String)
    case hold

    var context: String? { if case .desktop(_, let context) = self { return context }; return nil }
}

/// What an engine snapshot must change for every desktop poster to be taken again: each
/// display's wallpaper and how it is placed, the wallpapers' files and the screens' sizes.
/// Playback, audio, quality, frame rates, volumes and the panel's selection are left out, so a
/// snapshot that changes only those keeps the posters that have settled. A wallpaper switch, a
/// property apply and a move ask for posters themselves.
struct DesktopPosterLayout: Equatable {
    struct Screen: Equatable {
        var frame: CGRect
        var scale: CGFloat
    }

    private struct Shown: Equatable {
        var display: String
        var wallpaper: String
        var mirrorTarget: String?
        var scaling: String
    }

    private struct Placement: Equatable {
        var display: String
        var enabled: Bool
        var mode: BridgeDisplayMode
        var mirrorTarget: String?
        var scaling: BridgeScalingMode
        var scalingFactor: Double
    }

    private let shown: [Shown]
    private let placements: [Placement]
    private let screens: [Screen]
    private let contentRevision: UInt64

    init(monitors: [BridgeMonitorInfoRow], displays: [BridgeDisplaySettingsRow], screens: [Screen],
         contentRevision: UInt64) {
        shown = monitors.map {
            Shown(display: $0.displayId, wallpaper: $0.wallpaperId,
                  mirrorTarget: $0.mirrorTargetDisplayId, scaling: $0.scalingMode)
        }
        placements = displays.map {
            Placement(display: $0.displayId, enabled: $0.enabled, mode: $0.mode,
                      mirrorTarget: $0.selectedMirrorTarget, scaling: $0.scalingMode,
                      scalingFactor: $0.scalingFactor)
        }
        self.screens = screens
        self.contentRevision = contentRevision
    }
}

/// The first ready frame is submitted to all native desktop Spaces immediately.
/// Window enumeration and frame encoding are injected for headless regression
/// tests, including layer replacement and out-of-order completion.
///
/// Mission Control shows this system wallpaper, not the live window, so the
/// poster is taken again shortly after a wallpaper starts, changes or resumes
/// (intros, fades and settings that take a moment to show), and optionally every
/// few minutes. A frame identical to the current poster costs a readback and a
/// hash; nothing is encoded or written.
///
/// Once a surface's poster has settled it stays until what the display shows
/// changes: a Space change, a wake, a resume and an engine change that leaves the
/// wallpaper as it was take nothing new, however long ago the poster was taken.
/// An animated wallpaper turns every capture into a new image file, and macOS 26
/// and later keep a full-size bitmap of every file a desktop has shown in
/// WallpaperAgent's cache and never delete it, so retaking posters as time passes
/// fills the disk. For the same reason a wallpaper that comes back with the same look
/// (`posterLook`) gets its last settled poster back from `settledPosters` instead of
/// being captured again.
@MainActor
final class DesktopWallpaperSync {
    /// Delays after a start, change or resume at which the poster is taken again.
    static let settleCaptureDelays: [Duration] = [.seconds(3), .seconds(15)]
    static let periodicRefreshInterval: Duration = .seconds(300)

    /// What a refresh asks the surfaces for. Coalesced calls keep the largest request.
    enum CaptureRequest: Comparable {
        case none
        /// Only surfaces without a poster for the current scope.
        case missingPoster
        /// Only surfaces without a settled poster.
        case unsettled
        /// Every surface, taken again as the wallpaper settles: what a new or changed wallpaper needs.
        case all
    }

    private let ledger: DesktopWallpaperLedger
    private var frameObserver: NSObjectProtocol?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var posters: [ObjectIdentifier: Data] = [:]
    private var posterScopes: [ObjectIdentifier: DesktopPosterScope] = [:]
    /// The pixels each layer's poster was encoded from.
    private var frameDigests: [ObjectIdentifier: Data] = [:]
    private var revisions: [ObjectIdentifier: UInt64] = [:]
    /// When each layer's poster frame was received, so a display that briefly has two wallpaper
    /// windows (one replacing the other) shows the newer poster, never neither. Counted on
    /// receipt, not when encoding ends, so a slow encode cannot reverse the order.
    private var arrivals: [ObjectIdentifier: UInt64] = [:]
    private var arrivalCount: UInt64 = 0
    private let surfaces: @MainActor () -> [DesktopPosterSurface]
    private let frameCenter: NotificationCenter
    private let workspaceCenter: NotificationCenter?
    private let encode: @Sendable (DesktopPosterFrame) async throws -> Data
    private let scope: @MainActor (String) -> DesktopPosterScope
    private let beforeDesktopChange: @MainActor () -> Void
    private let retainedDisplays: @MainActor () -> Set<String>
    private var knownDisplays = Set<String>()
    private var retry: Task<Void, Never>?
    /// Synchronizes again once unconfirmed poster writes should read back.
    private var confirming: Task<Void, Never>?
    private let confirmationDelay: Duration
    private var lastRefresh: ContinuousClock.Instant?
    private var coalesced: Task<Void, Never>?
    private static let refreshInterval: Duration = .milliseconds(500)
    private let settleDelays: [Duration]
    private let settleSleep: @Sendable (Duration) async throws -> Void
    private let periodicInterval: Duration
    private let clock: @MainActor () -> ContinuousClock.Instant
    /// When each layer's latest accepted frame arrived while its wallpaper was presenting.
    /// Counted for identical frames too, and not for a frame a paused surface kept.
    private var capturedAt: [ObjectIdentifier: ContinuousClock.Instant] = [:]
    /// When every surface was last asked for a frame because a wallpaper started or changed.
    /// Frames that arrived before its settle captures are not final.
    private var lastFullRequest: ContinuousClock.Instant?
    private var settling: Task<Void, Never>?
    private enum LayerSelection {
        case all
        case only(Set<ObjectIdentifier>)

        func contains(_ key: ObjectIdentifier) -> Bool {
            switch self {
            case .all: true
            case .only(let keys): keys.contains(key)
            }
        }
    }

    /// Layers covered by the current settle sequence.
    private var settlingLayers = LayerSelection.all
    /// Layers asked for a frame that has not arrived yet. A frame nobody asked for comes
    /// from a renderer that started drawing on its own. Any frame from a layer answers what
    /// it was asked: a renderer answers piled-up requests with one frame. A host that
    /// answers each request separately sends a second answer that counts as unasked, which
    /// is ignored once the poster has settled; it is no newer than the first.
    private var awaitingFrames = Set<ObjectIdentifier>()
    /// Responses that only owe an intermediate settle frame. A final or explicit request wins.
    private var intermediateSettleFrames = Set<ObjectIdentifier>()
    /// Layers with an installed poster since the last full refresh.
    private var currentPosters = Set<ObjectIdentifier>()
    /// Surfaces whose poster is a settled one `settledPosters` gave back, with the look it was
    /// given for. Such a poster counts as settled: settle captures skip the surface, and only a
    /// frame that could itself be kept as settled replaces it, not a renderer's first (often an
    /// intro) nor one the periodic setting asks for while the wallpaper starts again.
    private var reusedLooks: [ObjectIdentifier: DesktopPosterLook] = [:]
    /// Per surface, the look its wallpaper had when every poster was last taken again or when a
    /// frame was last asked for under another look, and since when. Only a frame asked for a
    /// whole settle window after that is kept for the wallpaper's return: a look that changed
    /// just before or after a frame was asked for (an apply lands between the two) is never
    /// kept under the other look.
    private var lookBaselines: [ObjectIdentifier: (look: DesktopPosterLook?, since: ContinuousClock.Instant)] = [:]
    /// Per surface, the look and time of the request the frame on its way answers; a nil look
    /// when piled-up requests disagree.
    private var pendingLooks: [ObjectIdentifier: (look: DesktopPosterLook?, at: ContinuousClock.Instant)] = [:]
    /// The layout of the last engine snapshot this sync saw, nil before the first.
    private var lastLayout: DesktopPosterLayout?
    /// The surfaces, and their displays, the last pass over the desktops was made for; nil until
    /// a pass succeeds and after one fails, so the next change of windows tries again.
    private var synchronizedSurfaces: [ObjectIdentifier: String]?
    private var periodic: Task<Void, Never>?
    /// Whether a surface's wallpaper is presenting, so a later capture can show
    /// something new. Settling and periodic captures skip the others; a new
    /// wallpaper, a Space change and a wake still capture every surface.
    var canCapture: @MainActor (DesktopPosterSurface) -> Bool = { _ in true }
    /// Whether a surface draws a look nobody saved, such as property edits shown before Apply
    /// changes. Its frames are neither asked for nor taken as the poster, so Mission Control and
    /// the moment before a wallpaper loads keep the saved look; the owner asks for a refresh when
    /// the surface draws the saved look again. A frame already on its way is dropped on arrival.
    var showsUnsavedLook: @MainActor (DesktopPosterSurface) -> Bool = { _ in false }
    /// The last poster of each desktop's wallpaper on a display whose posters are scoped to one
    /// desktop, keyed by Space id. The current desktop takes it only until a fresh one is taken.
    var desktopPosters: @MainActor (String) -> [String: Data] = { _ in [:] }
    /// A poster was taken from a surface on a display, for the scope it was taken in.
    var onPosterAccepted: (@MainActor (String, DesktopPosterScope, Data) -> Void)?
    /// The settled posters kept for wallpapers that come back; nil keeps none and reuses none.
    var settledPosters: DesktopSettledPosterStore?
    /// What a surface's poster would show now, or nil when that cannot be told (its wallpaper
    /// unknown, still loading or failed, or drawn under a look this cannot name): then nothing
    /// is reused for it or kept from it.
    var posterLook: @MainActor (DesktopPosterSurface) -> DesktopPosterLook? = { _ in nil }
    /// Takes the poster again every `periodicRefreshInterval` while on.
    var refreshesPeriodically = false {
        didSet { if refreshesPeriodically != oldValue { schedulePeriodicCaptures() } }
    }
    private var stopped = false
    private var pendingRequest = CaptureRequest.none
    var isSuspended: Bool { stopped }

    /// `excludedWindows` names windows that are not a desktop's picture now, such as the paused
    /// wallpaper a display keeps for a desktop the person left: their frame belongs to that desktop.
    convenience init(folder: URL, scope: @escaping @MainActor (String) -> DesktopPosterScope = { _ in .all },
                     retainedDisplays: @escaping @MainActor () -> Set<String> = { [] },
                     beforeDesktopChange: @escaping @MainActor () -> Void = {},
                     excludedWindows: @escaping @MainActor () -> Set<Int> = { [] }) throws {
        try self.init(folder: folder, workspace: SystemDesktopPictureWorkspace(), surfaces: {
            let excluded = excludedWindows()
            return WallpaperPresentationPolicy.wallpaperWindows().compactMap { window in
                guard !excluded.contains(window.windowNumber), let layer = window.contentView?.layer,
                      let screen = window.screen, let id = SystemDesktopPictureWorkspace.id(screen) else { return nil }
                return DesktopPosterSurface(layer: layer, display: id, window: window.windowNumber)
            }
        }, frameCenter: .default, workspaceCenter: NSWorkspace.shared.notificationCenter,
                      scope: scope, retainedDisplays: retainedDisplays, beforeDesktopChange: beforeDesktopChange)
    }

    init(folder: URL, workspace: any DesktopPictureWorkspace,
         surfaces: @escaping @MainActor () -> [DesktopPosterSurface],
         frameCenter: NotificationCenter, workspaceCenter: NotificationCenter? = nil,
         scope: @escaping @MainActor (String) -> DesktopPosterScope = { _ in .all },
         retainedDisplays: @escaping @MainActor () -> Set<String> = { [] },
         beforeDesktopChange: @escaping @MainActor () -> Void = {},
         systemDefaultPicture: URL = DesktopWallpaperLedger.systemDefaultPictureURL,
         encode: @escaping @Sendable (DesktopPosterFrame) async throws -> Data = { frame in
             try await Task.detached(priority: .userInitiated) {
                 try DesktopPosterEncoder.jpeg(pixels: frame.pixels, width: frame.width, height: frame.height, bgra: frame.bgra)
             }.value
         },
         settleDelays: [Duration] = DesktopWallpaperSync.settleCaptureDelays,
         settleSleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         periodicInterval: Duration = DesktopWallpaperSync.periodicRefreshInterval,
         confirmationDelay: Duration = DesktopWallpaperLedger.confirmationWindow,
         clock: @escaping @MainActor () -> ContinuousClock.Instant = { ContinuousClock.now }) throws {
        ledger = try DesktopWallpaperLedger(folder: folder, workspace: workspace,
                                            confirmationWindow: confirmationDelay,
                                            systemDefaultPicture: systemDefaultPicture)
        self.confirmationDelay = confirmationDelay
        self.surfaces = surfaces
        self.frameCenter = frameCenter
        self.workspaceCenter = workspaceCenter
        self.scope = scope; self.beforeDesktopChange = beforeDesktopChange
        self.retainedDisplays = retainedDisplays
        self.encode = encode
        self.settleDelays = settleDelays.sorted()
        self.settleSleep = settleSleep
        self.periodicInterval = periodicInterval
        self.clock = clock
    }

    func start() {
        guard !stopped, frameObserver == nil else { return }
        frameObserver = frameCenter.addObserver(forName: DesktopPosterNotification.ready, object: nil,
                                                queue: .main) { [weak self] notification in
            MainActor.assumeIsolated { self?.receive(notification) }
        }
        if let center = workspaceCenter {
            for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didWakeNotification] {
                workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.refreshAfterDesktopChange(capture: name == NSWorkspace.didWakeNotification
                                                        ? .unsettled : .missingPoster)
                    }
                })
            }
        }
        schedulePeriodicCaptures()
    }

    /// Brings every desktop up to date with the current poster, after asking the
    /// surfaces `capture` names for a fresh frame. `.all` is what a new or changed
    /// wallpaper needs and also takes the poster again as the wallpaper settles;
    /// `.missingPoster` reuses the current image across Space changes, even while
    /// it settles; `.unsettled` can retake it after events such as wake.
    func refresh(capture: CaptureRequest = .all) {
        refresh(capture, settle: capture == .all)
    }

    /// An engine snapshot was applied. One that changes the layout since the last snapshot this
    /// sync saw, or the first one, takes every poster again as a new wallpaper does; any other
    /// keeps the posters already installed.
    func snapshotApplied(_ layout: DesktopPosterLayout) {
        let capture: CaptureRequest = layout == lastLayout ? .missingPoster : .all
        lastLayout = layout
        refresh(capture: capture)
    }

    /// A display's wallpaper plays again after a pause, a cover or display
    /// sleep: an intro may only now be running, so a poster taken before the
    /// wallpaper settled, or while it was paused, is taken again as it settles.
    /// A display whose poster has settled keeps it.
    func presentationResumed() {
        // An intro may run again: no frame of the next settle window is kept for a return.
        restartLookBaselines()
        scheduleSettleCaptures(staleOnly: true)
    }

    /// Every surface's look starts its settle window now.
    private func restartLookBaselines() {
        guard settledPosters != nil else { return }
        let now = clock()
        for surface in surfaces() {
            lookBaselines[ObjectIdentifier(surface.layer)] =
                (scope(surface.display) == .all ? posterLook(surface) : nil, now)
        }
    }

    /// Notes the look a frame is asked for under, before the request goes out.
    private func noteRequestLook(_ surface: DesktopPosterSurface, scope: DesktopPosterScope) {
        guard settledPosters != nil else { return }
        let key = ObjectIdentifier(surface.layer)
        let now = clock()
        let look = scope == .all ? posterLook(surface) : nil
        if lookBaselines[key].map({ $0.look != look }) ?? true { lookBaselines[key] = (look, now) }
        if awaitingFrames.contains(key), let pending = pendingLooks[key] {
            if pending.look != look { pendingLooks[key] = (nil, pending.at) }
        } else {
            pendingLooks[key] = (look, now)
        }
    }

    /// Whether a frame asked for under `look` at `requested` shows the wallpaper settled with
    /// that look, which still holds: the look had held a whole settle window when it was asked.
    private func isSettled(_ look: DesktopPosterLook, requested: ContinuousClock.Instant,
                           surface: DesktopPosterSurface) -> Bool {
        guard let baseline = lookBaselines[ObjectIdentifier(surface.layer)], baseline.look == look,
              requested >= baseline.since.advanced(by: settleDelays.last ?? .zero),
              scope(surface.display) == .all, !showsUnsavedLook(surface) else { return false }
        return posterLook(surface) == look
    }

    /// Wallpaper windows opened or closed after the snapshot that asked for posters, as a host's
    /// do once it has read what to show. A window that opened, and has neither answered nor been
    /// asked, is asked at once, presenting or not, and settles as a new wallpaper does: a
    /// sequence already asking every surface would skip it as covered, and settle captures skip
    /// a display that does not present. A display left without a window gets its own picture
    /// back. Settled posters stay, and a call that finds the windows of the last pass does nothing.
    func surfacesChanged() {
        guard !stopped else { return }
        let current = surfaces()
        var asked = Set<ObjectIdentifier>()
        var reused = false
        for surface in current {
            let key = ObjectIdentifier(surface.layer)
            guard revisions[key] == nil, !awaitingFrames.contains(key) else { continue }
            if reuseSettledPoster(for: surface) {
                reused = true
                continue
            }
            requestFrame(for: surface)
            // A display on hold or drawing an unsaved look is not asked; its owner asks later.
            if awaitingFrames.contains(key), !settlesAgain(surface) { asked.insert(key) }
        }
        if !asked.isEmpty { scheduleSettleCaptures(staleOnly: true, adding: asked) }
        let shown = Dictionary(current.map { (ObjectIdentifier($0.layer), $0.display) }) { first, _ in first }
        if reused || shown != synchronizedSurfaces { synchronizeAllSpaces() }
    }

    private func refresh(_ request: CaptureRequest, settle: Bool) {
        guard !stopped else { return }
        // Before the settle captures are scheduled, so the last of them lands after it.
        if request == .all {
            lastFullRequest = clock()
            currentPosters.removeAll()
            restartLookBaselines()
        }
        if settle { scheduleSettleCaptures(staleOnly: false) }
        pendingRequest = max(pendingRequest, request)
        let now = ContinuousClock.now
        if let last = lastRefresh, now - last < Self.refreshInterval {
            guard coalesced == nil else { return }
            let wait = Self.refreshInterval - (now - last)
            coalesced = Task { [weak self] in
                do { try await Task.sleep(for: wait) } catch { return }
                guard let self, !self.stopped else { return }
                self.coalesced = nil
                self.lastRefresh = ContinuousClock.now
                self.performRefresh()
            }
            return
        }
        lastRefresh = now
        performRefresh()
    }

    /// A Space change or wake shows a desktop the poster may not be on yet: the
    /// current poster is applied at once. Desktops that kept refusing posters
    /// are tried again.
    private func refreshAfterDesktopChange(capture: CaptureRequest) {
        beforeDesktopChange()
        ledger.retryRefusedDesktops()
        refresh(capture, settle: false)
    }

    /// Whether a refresh that is not for a new or changed wallpaper leaves the
    /// surface's poster as it is: it was taken once the wallpaper had settled, or a
    /// settle capture still to come takes it. A poster scoped to a Space must confirm
    /// its context, so it is never kept.
    private func keepsPoster(of surface: DesktopPosterSurface) -> Bool {
        scope(surface.display) == .all && (settlesAgain(surface) || hasSettledPoster(surface))
    }

    /// Whether the surface's latest frame arrived, while its wallpaper presented, after
    /// the settle captures of the last new or changed wallpaper could have landed.
    private func hasSettledPoster(_ surface: DesktopPosterSurface) -> Bool {
        if reusedLooks[ObjectIdentifier(surface.layer)] != nil { return true }
        guard let taken = capturedAt[ObjectIdentifier(surface.layer)] else { return false }
        if let requested = lastFullRequest, taken < requested.advanced(by: settleDelays.last ?? .zero) {
            return false
        }
        return true
    }

    private func settlesAgain(_ surface: DesktopPosterSurface) -> Bool {
        settling != nil && settlingLayers.contains(ObjectIdentifier(surface.layer))
    }

    /// `staleOnly` leaves out the surfaces whose poster is kept, and does nothing,
    /// not even restarting a sequence already running, when there are none. A
    /// sequence that is restarted keeps asking the surfaces it was going to ask.
    private func scheduleSettleCaptures(staleOnly: Bool, adding layers: Set<ObjectIdentifier> = []) {
        var selection = LayerSelection.all
        if staleOnly {
            let stale = Set(surfaces().filter { !keepsPoster(of: $0) }.map { ObjectIdentifier($0.layer) }).union(layers)
            guard !stale.isEmpty else { return }
            if settling == nil {
                selection = .only(stale)
            } else if case .only(let active) = settlingLayers {
                selection = .only(active.union(stale))
            }
        }
        settling?.cancel()
        settling = nil
        settlingLayers = .all
        guard !stopped, frameObserver != nil, !settleDelays.isEmpty else { return }
        let delays = settleDelays
        let sleep = settleSleep
        settlingLayers = selection
        settling = Task { [weak self] in
            var elapsed = Duration.zero
            for (index, delay) in delays.enumerated() {
                do { try await sleep(delay - elapsed) } catch { return }
                elapsed = delay
                guard !Task.isCancelled, let self, !self.stopped else { return }
                self.requestPresentingFrames(selection, settlePass: index == delays.count - 1 ? .final : .intermediate)
            }
            // A replacement cancels this sequence before it starts its own.
            guard !Task.isCancelled else { return }
            self?.settling = nil
            self?.settlingLayers = .all
        }
    }

    private func schedulePeriodicCaptures() {
        periodic?.cancel()
        periodic = nil
        guard refreshesPeriodically, !stopped, frameObserver != nil else { return }
        let interval = periodicInterval
        periodic = Task { [weak self] in
            while true {
                // The poster only has to be roughly this old, so let the system coalesce it.
                do { try await Task.sleep(for: interval, tolerance: interval / 10) } catch { return }
                guard !Task.isCancelled, let self, !self.stopped, self.refreshesPeriodically else { return }
                self.requestPresentingFrames()
            }
        }
    }

    private enum SettlePass {
        case intermediate
        case final
    }

    /// Asks only presenting surfaces. A paused surface would return the frame it already shows.
    private func requestPresentingFrames(_ layers: LayerSelection = .all, settlePass: SettlePass? = nil) {
        for surface in surfaces() where canCapture(surface) && layers.contains(ObjectIdentifier(surface.layer)) {
            if settlePass != nil, reusedLooks[ObjectIdentifier(surface.layer)] != nil { continue }
            requestFrame(for: surface, intermediateSettle: settlePass == .intermediate)
        }
    }

    /// Gives the surface the settled poster its wallpaper last had on the display with the same
    /// look, instead of asking for a frame. False when there is none, or the surface's poster
    /// cannot be reused (scoped to a Space, drawing an unsaved look, a look nobody can name).
    private func reuseSettledPoster(for surface: DesktopPosterSurface) -> Bool {
        guard let store = settledPosters, scope(surface.display) == .all, !showsUnsavedLook(surface),
              let look = posterLook(surface) else { return false }
        let key = ObjectIdentifier(surface.layer)
        // Already showing it: nothing to read again.
        if reusedLooks[key] == look, posters[key] != nil { return true }
        guard let poster = store.poster(for: look) else { return false }
        // A frame on its way, or an encode still running, is older than this poster.
        revisions[key] = (revisions[key] ?? 0) &+ 1
        awaitingFrames.remove(key)
        intermediateSettleFrames.remove(key)
        pendingLooks[key] = nil
        arrivalCount &+= 1
        arrivals[key] = arrivalCount
        posters[key] = poster
        currentPosters.insert(key)
        posterScopes[key] = .all
        frameDigests[key] = nil
        reusedLooks[key] = look
        return true
    }

    private func requestFrame(for surface: DesktopPosterSurface, intermediateSettle: Bool = false) {
        let scope = scope(surface.display)
        guard scope != .hold, !showsUnsavedLook(surface) else { return }
        let key = ObjectIdentifier(surface.layer)
        if intermediateSettle {
            if !awaitingFrames.contains(key) { intermediateSettleFrames.insert(key) }
        } else {
            intermediateSettleFrames.remove(key)
        }
        noteRequestLook(surface, scope: scope)
        awaitingFrames.insert(key)
        frameCenter.post(name: DesktopPosterNotification.request, object: surface.layer,
                         userInfo: [DesktopPosterNotification.Key.context: scope.context ?? ""])
    }

    private func performRefresh() {
        guard !stopped else { return }
        let request = pendingRequest
        pendingRequest = .none
        // Request GPU pixels before potentially slow native Space enumeration
        // and journal I/O, so readback can overlap synchronization.
        // No debounce: an Apply must not wait for a 400 ms timer, another
        // snapshot, or an activeSpaceDidChange notification to request pixels.
        if request != .none {
            var kept: [String] = []
            var reused: [String] = []
            for surface in surfaces() {
                let key = ObjectIdentifier(surface.layer)
                let hasCurrentPoster = posters[key] != nil && posterScopes[key] == scope(surface.display)
                if (request == .missingPoster && hasCurrentPoster)
                    || (request == .unsettled && keepsPoster(of: surface)) {
                    kept.append(surface.display)
                } else if reuseSettledPoster(for: surface) {
                    reused.append(surface.display)
                } else {
                    reusedLooks[key] = nil
                    requestFrame(for: surface)
                }
            }
            if !kept.isEmpty { AppLog.debug("desktop poster: kept the current poster on display \(kept.joined(separator: ", "))") }
            if !reused.isEmpty {
                AppLog.debug("desktop poster: gave back the settled poster of the same look on display \(reused.joined(separator: ", "))")
            }
        }
        synchronizeAllSpaces()
    }

    func stop() {
        do { try stopAndRestore() } catch { report(error) }
    }

    /// Stop poster writes without restoring through the legacy image API. The
    /// native provider journals the current poster; keep its file and ledger
    /// alive until that provider releases ownership.
    func suspendForNativeProvider() {
        stopped = true
        retry?.cancel()
        confirming?.cancel()
        confirming = nil
        coalesced?.cancel()
        coalesced = nil
        settling?.cancel()
        settling = nil
        settlingLayers = .all
        periodic?.cancel()
        periodic = nil
        lastRefresh = nil
        capturedAt.removeAll()
        lastFullRequest = nil
        if let frameObserver { frameCenter.removeObserver(frameObserver) }
        frameObserver = nil
        for observer in workspaceObservers { workspaceCenter?.removeObserver(observer) }
        workspaceObservers.removeAll()
        posters.removeAll()
        posterScopes.removeAll()
        reusedLooks.removeAll()
        lookBaselines.removeAll()
        pendingLooks.removeAll()
        intermediateSettleFrames.removeAll()
        currentPosters.removeAll()
        synchronizedSurfaces = nil
        knownDisplays.removeAll()
        frameDigests.removeAll()
        revisions.removeAll()
        arrivals.removeAll()
    }

    func stopAndRestore() throws {
        suspendForNativeProvider()
        try ledger.restoreAll()
    }

    /// Native Desktop/Idle restoration signals WallpaperAgent to reload. Wait
    /// for its poster selection to become readable and for our restoration to
    /// persist before allowing the app to exit.
    ///
    /// A poster can stay named where no per-Space write reaches it: macOS 27 can
    /// copy a Space write into the display-wide and system-default
    /// selections. Once every desktop that can be written is restored and
    /// reads back, that leftover reference no longer blocks quitting, or the
    /// app could never quit. A restoration that never reads back still does.
    func restoreForTermination(
        wait: () async throws -> Void = { try await Task.sleep(for: .milliseconds(200)) }
    ) async throws {
        suspendForNativeProvider()
        for attempt in 0..<25 {
            try Task.checkCancellation()
            do {
                try ledger.restoreAll()
                return
            } catch {
                guard attempt < 24 else {
                    guard error as? DesktopWallpaperLedger.Failure == .restorationPending else { throw error }
                    AppLog.warn("Quitting while macOS still names a desktop poster in its wallpaper store; every writable desktop was restored")
                    return
                }
                try await wait()
            }
        }
    }

    private func receive(_ notification: Notification) {
        guard !stopped, let layer = notification.object as? CALayer,
              let surface = surfaces().first(where: { $0.layer === layer }) else { return }
        let key = ObjectIdentifier(layer)
        // Before anything drops the frame: one frame answering piled-up requests can carry
        // another request's context, such as a switch hold's, and still answers this one.
        let asked = awaitingFrames.remove(key) != nil
        let intermediateSettle = intermediateSettleFrames.remove(key) != nil
        let pending = pendingLooks.removeValue(forKey: key)
        guard let values = notification.userInfo,
              let frame = DesktopPosterFrame(userInfo: values),
              !showsUnsavedLook(surface) else { return }
        let receivedScope = scope(surface.display)
        guard receivedScope != .hold,
              (DesktopPosterNotification.context(in: values) ?? "") == (receivedScope.context ?? "") else { return }
        // A frame kept for the wallpaper's return: asked for, while presenting, under a look that
        // had settled. The look must still be the same when the poster is accepted.
        let keepable: (look: DesktopPosterLook, requested: ContinuousClock.Instant)? = {
            guard asked, canCapture(surface), settledPosters != nil, let pending, let look = pending.look,
                  isSettled(look, requested: pending.at, surface: surface) else { return nil }
            return (look, pending.at)
        }()
        // A reused settled poster is the wallpaper as it settles. Settle captures skip the
        // surface, so a frame that is not settled (a renderer's first, often an intro, or a
        // periodic one while the wallpaper starts again) would stay; it is dropped.
        if reusedLooks[key] != nil, keepable == nil { return }
        // Keep an installed startup poster through intermediate samples. The final settle
        // frame still replaces it, including when the initial frame was an intro or black.
        if intermediateSettle, !refreshesPeriodically, receivedScope == .all,
           currentPosters.contains(key), posterScopes[key] == receivedScope { return }
        if !asked, receivedScope == .all, !settlesAgain(surface) {
            // A renderer sends its first frame unasked, often an intro. One started again in the
            // same window draws the same wallpaper (a new wallpaper, a move or a new screen size
            // asks for posters itself), so a settled poster stays. A surface without one, such
            // as a window that just opened, takes the frame and settles like a new wallpaper,
            // unless its wallpaper's settled poster of the same look can be given back.
            if hasSettledPoster(surface) { return }
            if reuseSettledPoster(for: surface) {
                synchronizeAllSpaces()
                return
            }
            scheduleSettleCaptures(staleOnly: true, adding: [key])
        }
        // A surface that is not presenting answers with the frame it kept, however long ago
        // it drew it. That frame is still the poster, but it says nothing about the wallpaper
        // as it plays now, so it must not make the poster fresh: the resume that follows
        // would otherwise skip the capture that shows the wallpaper running again. Nor does
        // a frame nobody asked for, which may be the first of an intro.
        if asked, canCapture(surface) { capturedAt[key] = clock() }
        let revision = (revisions[key] ?? 0) &+ 1
        revisions[key] = revision
        arrivalCount &+= 1
        let arrival = arrivalCount
        let encode = self.encode
        Task(priority: .userInitiated) { [weak self, weak layer] in
            let digest = await Task.detached(priority: .userInitiated) { frame.digest }.value
            guard let self, let layer, self.isNewest(revision, of: layer),
                  self.scope(surface.display) == receivedScope else { return }
            if self.posters[key] != nil, self.frameDigests[key] == digest {
                // The same pixels can belong to a new Space visit. Reuse their encoding
                // only after a fresh response validates the new context, then publish there.
                self.posterScopes[key] = receivedScope
                self.currentPosters.insert(key)
                self.arrivals[key] = arrival
                if let poster = self.posters[key] {
                    self.onPosterAccepted?(surface.display, receivedScope, poster)
                    self.keepSettled(poster, keepable, surface: surface)
                }
                self.synchronizeAllSpaces()
                return
            }
            do {
                let image = try await encode(frame)
                guard self.isNewest(revision, of: layer),
                      self.scope(surface.display) == receivedScope else { return }
                self.posters[key] = image
                self.currentPosters.insert(key)
                self.posterScopes[key] = receivedScope
                self.frameDigests[key] = digest
                self.arrivals[key] = arrival
                self.reusedLooks[key] = nil
                self.onPosterAccepted?(surface.display, receivedScope, image)
                self.keepSettled(image, keepable, surface: surface)
                self.synchronizeAllSpaces()
            } catch {
                // No poster came of this frame, so the next trigger takes another.
                if self.isNewest(revision, of: layer) { self.capturedAt[key] = nil }
                self.report(error)
            }
        }
    }

    /// Keeps a poster that settled for the wallpaper's return, when its look still holds as it
    /// did when the frame was asked for.
    private func keepSettled(_ poster: Data, _ keepable: (look: DesktopPosterLook, requested: ContinuousClock.Instant)?,
                             surface: DesktopPosterSurface) {
        guard let keepable, let store = settledPosters,
              isSettled(keepable.look, requested: keepable.requested, surface: surface) else { return }
        store.store(poster, for: keepable.look)
    }

    /// Only the newest frame of a surface still on screen may become its poster.
    private func isNewest(_ revision: UInt64, of layer: CALayer) -> Bool {
        !stopped && revisions[ObjectIdentifier(layer)] == revision
            && surfaces().contains(where: { $0.layer === layer })
    }

    private func synchronizeAllSpaces(attempt: Int = 0) {
        let surfaces = surfaces()
        let keys = Set(surfaces.map { ObjectIdentifier($0.layer) })
        posters = posters.filter { keys.contains($0.key) }
        posterScopes = posterScopes.filter { keys.contains($0.key) }
        frameDigests = frameDigests.filter { keys.contains($0.key) }
        revisions = revisions.filter { keys.contains($0.key) }
        arrivals = arrivals.filter { keys.contains($0.key) }
        capturedAt = capturedAt.filter { keys.contains($0.key) }
        reusedLooks = reusedLooks.filter { keys.contains($0.key) }
        lookBaselines = lookBaselines.filter { keys.contains($0.key) }
        awaitingFrames.formIntersection(keys)
        intermediateSettleFrames.formIntersection(keys)
        currentPosters.formIntersection(keys)
        pendingLooks = pendingLooks.filter { awaitingFrames.contains($0.key) }
        var byDisplay: [String: Data] = [:]
        var newest: [String: UInt64] = [:]
        var targetSpaces: [String: Set<String>] = [:]
        var spacePosters: [String: [String: Data]] = [:]
        let retained = retainedDisplays()
        knownDisplays.formUnion(surfaces.map(\.display))
        knownDisplays.formUnion(retained)
        for display in knownDisplays {
            switch scope(display) {
            case .all: continue
            case .desktop(let id, _): targetSpaces[display] = [id]
            case .hold: targetSpaces[display] = []
            }
            let saved = desktopPosters(display)
            if !saved.isEmpty { spacePosters[display] = saved }
        }
        for surface in surfaces {
            let currentScope = scope(surface.display)
            // A window with no poster yet must not take away the one its sibling has.
            let key = ObjectIdentifier(surface.layer)
            guard currentScope != .hold, posterScopes[key] == currentScope,
                  let poster = posters[key], let arrival = arrivals[key],
                  arrival >= newest[surface.display] ?? 0 else { continue }
            byDisplay[surface.display] = poster
            newest[surface.display] = arrival
        }
        retry?.cancel()
        defer { scheduleConfirmation() }
        do {
            try ledger.synchronize(posters: byDisplay, liveDisplays: Set(surfaces.map(\.display)).union(retained),
                                   targetSpaces: targetSpaces, spacePosters: spacePosters)
            synchronizedSurfaces = Dictionary(surfaces.map { (ObjectIdentifier($0.layer), $0.display) }) { first, _ in first }
        } catch {
            // A display whose picture could not be put back is tried again by the next change of
            // windows, even one that leaves them as they are.
            synchronizedSurfaces = nil
            report(error)
            // Retry native asynchronous acknowledgement/Space creation races,
            // not the initial update. Never require the user to visit a Space.
            guard attempt < 3, !stopped else { return }
            retry = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(100 * (attempt + 1))) } catch { return }
                guard let self, !self.stopped else { return }
                self.synchronizeAllSpaces(attempt: attempt + 1)
            }
        }
    }

    /// A poster write WallpaperAgent has not applied yet is checked again,
    /// rather than rewritten or counted as refused at once.
    private func scheduleConfirmation() {
        confirming?.cancel()
        confirming = nil
        guard ledger.awaitsConfirmation, !stopped else { return }
        let delay = confirmationDelay
        confirming = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, !self.stopped else { return }
            self.confirming = nil
            self.synchronizeAllSpaces()
        }
    }

    private func report(_ error: Error) {
        AppLog.error("Native desktop poster sync failed: \(error.localizedDescription)")
    }
}
