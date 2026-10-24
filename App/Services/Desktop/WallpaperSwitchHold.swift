import AppKit
import QuartzCore

/// What the renderer's window code announces for every content layer a wallpaper window gets.
///
/// `window.rs` posts the notification on the default center, synchronously on the main thread
/// and before the layer is first composited; `object` is the new layer. Nothing checks these
/// strings at compile time, so `window::tests` pins the same spelling on the Rust side and
/// `WallpaperSwitchHoldTests` pins it here.
enum WallpaperSwitchHoldNotification {
    static let layerInstalled = Notification.Name("WallpaperMachine.wallpaperLayerInstalled")
    /// The CoreGraphics display id, an `NSNumber`.
    static let displayIDKey = "displayID"
    /// Why the layer was installed, one of `Reason`.
    static let reasonKey = "reason"

    enum Reason: String {
        /// A window was just opened.
        case open
        /// A scene replacement installed a fresh layer for its renderer.
        case replace
        /// A display reconfigure installed a fresh layer. A renderer with a picture keeps it; one
        /// that is still loading has none yet and loses its veil with the layer it replaced.
        case reconfigure
    }
}

/// Keeps the picture a display showed on screen while the wallpaper that replaces it loads.
///
/// A switch that the person asked for, or that a playlist or rule made, tears the old renderer
/// down before the new one has drawn anything, and the window in between is black. Just before
/// the switch the hold asks the visible wallpaper for a still through the poster pipeline
/// (`DesktopPosterNotification`), and carries that still as a sublayer, the veil, of whichever
/// window shows the successor. The veil goes away with a short fade once the successor says it
/// has a picture: the engine's apply returning, which waits for a presented first frame, for
/// a scene; the host's own ready callback for a web page or a clip.
///
/// Everything is per display and bounded. A display that cannot give a still within
/// `Configuration.grabTimeout` is not held and switches as it always did, a veil that nothing
/// releases is removed after `holdCeiling`, and one that no window picks up after the engine has
/// finished goes after `hostGrace`.
///
/// State per display: capturing, then armed (a still waits for a window), then carried by a
/// scene's layer or a host's, then dismissing while it fades, then gone.
@MainActor
final class WallpaperSwitchHold {
    struct Configuration {
        /// How long the visible wallpaper has to answer the still request.
        var grabTimeout: Duration = .milliseconds(250)
        /// The longest a veil may cover a display, whatever the successor does.
        var holdCeiling: Duration = .seconds(30)
        /// How long an armed veil waits for a host window once the engine has finished.
        var hostGrace: Duration = .seconds(8)
        /// The fade-out, in seconds; none under Reduce Motion.
        var fade: TimeInterval = 0.2
    }

    enum Phase: Equatable {
        case capturing
        case armed
        case onScene
        case onHost
        case dismissing
    }

    /// A requested still on its way, so `stop()` can end the wait.
    private struct Capture {
        let token: UInt64
        let grab: PosterGrab
    }

    private final class Ticket {
        let generation: UInt64
        let veil: SwitchHoldVeil
        let heldAt: ContinuousClock.Instant
        var phase = Phase.armed
        var deadline: ContinuousClock.Instant
        var deadlineIsGrace = false
        var expiry: Task<Void, Never>?
        var settle: Task<Void, Never>?
        var removal: Task<Void, Never>?

        init(generation: UInt64, veil: SwitchHoldVeil, heldAt: ContinuousClock.Instant,
             deadline: ContinuousClock.Instant) {
            self.generation = generation
            self.veil = veil
            self.heldAt = heldAt
            self.deadline = deadline
        }

        func cancelTasks() {
            expiry?.cancel()
            settle?.cancel()
            removal?.cancel()
        }
    }

    private let center: NotificationCenter
    private let layers: @MainActor (UInt32) -> [CALayer]
    private let shouldHold: @MainActor (UInt32) -> Bool
    private let reduceMotion: @MainActor () -> Bool
    private let concealed: @MainActor (UInt32) -> Bool
    private let sleep: @Sendable (Duration) async throws -> Void
    private let now: @MainActor () -> ContinuousClock.Instant
    private let configuration: Configuration
    private var installObserver: NSObjectProtocol?
    private var tickets: [UInt32: Ticket] = [:]
    private var captures: [UInt32: Capture] = [:]
    private var generation: UInt64 = 0
    /// Called once a display's veil is gone, faded or not.
    var onReleased: (@MainActor (UInt32) -> Void)?

    /// `layers` lists a display's live wallpaper content layers, the front one first;
    /// `shouldHold` says whether anyone can see the display (a suspended one is not held, and a
    /// suspended surface may not answer the request); `reduceMotion` is the person's setting;
    /// `concealed` says a display's windows are hidden, so its veil goes without a fade.
    init(center: NotificationCenter = .default,
         layers: @escaping @MainActor (UInt32) -> [CALayer],
         shouldHold: @escaping @MainActor (UInt32) -> Bool,
         reduceMotion: @escaping @MainActor () -> Bool,
         concealed: @escaping @MainActor (UInt32) -> Bool = { _ in false },
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         now: @escaping @MainActor () -> ContinuousClock.Instant = { ContinuousClock.now },
         configuration: Configuration = Configuration()) {
        self.center = center
        self.layers = layers
        self.shouldHold = shouldHold
        self.reduceMotion = reduceMotion
        self.concealed = concealed
        self.sleep = sleep
        self.now = now
        self.configuration = configuration
    }

    /// Displays whose still is waiting for a window or covering one.
    var activeDisplayIDs: Set<UInt32> {
        Set(tickets.filter { $0.value.phase != .dismissing }.keys)
    }

    /// Whether a still is being taken for the display or a veil still covers it.
    func isHolding(_ display: UInt32) -> Bool { captures[display] != nil || tickets[display] != nil }

    func stateForTest(display: UInt32) -> Phase? {
        captures[display] != nil ? .capturing : tickets[display]?.phase
    }

    // MARK: Lifecycle

    func start() {
        guard installObserver == nil else { return }
        // No queue: the renderer posts this on the main thread inside its window operation, and
        // the veil has to be on the new layer before that operation returns and the window is
        // composited. The observer only moves a layer.
        installObserver = center.addObserver(
            forName: WallpaperSwitchHoldNotification.layerInstalled, object: nil, queue: nil
        ) { [weak self] notification in
            MainActor.assumeIsolated { self?.layerInstalled(notification) }
        }
    }

    /// Removes every veil at once and ends what is waiting.
    func stop() {
        if let installObserver { center.removeObserver(installObserver) }
        installObserver = nil
        for capture in captures.values { capture.grab.cancel() }
        captures.removeAll()
        for display in Array(tickets.keys) { remove(display) }
    }

    // MARK: Switching

    /// Takes a still of each display's visible wallpaper, ahead of a switch. Returns once the
    /// stills are in, or the time allowed is over: the caller applies the new wallpaper after it.
    func begin(displays: [UInt32]) async {
        guard installObserver != nil else { return }
        var requests: [(display: UInt32, layer: CALayer, capture: Capture)] = []
        var seen = Set<UInt32>()
        for display in displays where seen.insert(display).inserted {
            guard captures[display] == nil else { continue }
            if let ticket = tickets[display] {
                if ticket.phase != .dismissing {
                    // A second switch while the first still loads: what is on screen is the
                    // held picture already, so it stays and its time starts again.
                    ticket.deadline = now() + configuration.holdCeiling
                    ticket.deadlineIsGrace = false
                    scheduleExpiry(for: display)
                    continue
                }
                remove(display)
            }
            guard shouldHold(display), let layer = layers(display).first else { continue }
            generation += 1
            let capture = Capture(token: generation, grab: PosterGrab(center: center))
            captures[display] = capture
            requests.append((display, layer, capture))
        }
        guard !requests.isEmpty else { return }
        let started = now()
        let timeout = configuration.grabTimeout
        let sleep = self.sleep
        await withTaskGroup(of: (UInt32, UInt64, DesktopPosterFrame?).self) { group in
            for request in requests {
                group.addTask { @MainActor in
                    let frame = await request.capture.grab.run(on: request.layer, timeout: timeout, sleep: sleep)
                    return (request.display, request.capture.token, frame)
                }
            }
            for await (display, token, frame) in group {
                arm(display: display, token: token, frame: frame, since: started)
            }
        }
    }

    /// The engine's apply returned: a scene successor has presented its first frame.
    func engineSettled(displays: [UInt32]) {
        for display in displays {
            guard let ticket = tickets[display] else { continue }
            switch ticket.phase {
            case .onScene:
                dismiss(display, because: "scene first frame")
            case .armed:
                // No scene took it. A host window may still come, or nothing changed.
                let grace = now() + configuration.hostGrace
                if grace < ticket.deadline {
                    ticket.deadline = grace
                    ticket.deadlineIsGrace = true
                    scheduleExpiry(for: display)
                }
            case .onHost, .dismissing, .capturing:
                break
            }
        }
    }

    /// A host window for the display's successor is about to be shown in `layer`: the veil goes
    /// onto it. False when no veil waits, or when the one that does covers a window that is
    /// still on screen and so is not a stale one to take over.
    @discardableResult
    func adopt(into layer: CALayer, displayID: UInt32) -> Bool {
        guard let ticket = tickets[displayID], ticket.phase != .dismissing else { return false }
        if let parent = ticket.veil.parent, parent !== layer,
           layers(displayID).contains(where: { $0 === parent }) {
            return false
        }
        ticket.settle?.cancel()
        ticket.settle = nil
        ticket.veil.attach(to: layer, flush: true)
        ticket.phase = .onHost
        ticket.deadline = now() + configuration.holdCeiling
        ticket.deadlineIsGrace = false
        scheduleExpiry(for: displayID)
        AppLog.info("switch hold: display \(displayID) adopted by host")
        return true
    }

    /// The host's window has content. The veil goes `settle` later: a page's first paint comes
    /// some time after it reports loaded. Without a veil on a host window this does nothing.
    func contentReady(displayID: UInt32, after settle: Duration = .zero) {
        guard let ticket = tickets[displayID], ticket.phase == .onHost, ticket.settle == nil else { return }
        guard settle > .zero else {
            dismiss(displayID, because: "host ready")
            return
        }
        let id = ticket.generation
        let sleep = self.sleep
        ticket.settle = Task { [weak self] in
            do { try await sleep(settle) } catch { return }
            guard let self, let ticket = self.tickets[displayID],
                  ticket.generation == id, ticket.phase == .onHost else { return }
            self.dismiss(displayID, because: "host ready")
        }
    }

    /// A host closed `layer`'s window for good and has no window of its own to put in its place.
    ///
    /// A veil that sat on that window goes with it: it covers nothing anyone sees, and kept for
    /// the rest of its ceiling it would be taken for the picture on screen by the next switch
    /// and shown again, out of date. A veil that still waits for a window, or sits on a scene,
    /// is not this window's and stays for its successor, which is often the other host, still
    /// to reconcile. A window that is closed to be replaced does not call this: its successor
    /// takes the veil with `adopt`.
    func windowClosed(_ layer: CALayer?, displayID: UInt32) {
        guard let layer, let ticket = tickets[displayID], ticket.phase != .dismissing,
              ticket.veil.parent === layer else { return }
        ticket.veil.detach()
        dismiss(displayID, because: "window closed")
    }

    /// The switch failed or was called off: the display shows its own wallpaper again, so the
    /// held picture goes.
    func cancel(displays: [UInt32]) {
        for display in displays {
            if let capture = captures.removeValue(forKey: display) {
                capture.grab.cancel()
                if tickets[display] == nil { onReleased?(display) }
            }
            dismiss(display, because: "cancelled")
        }
    }

    // MARK: Steps

    private func arm(display: UInt32, token: UInt64, frame: DesktopPosterFrame?,
                     since started: ContinuousClock.Instant) {
        // A cancel or stop while the still was on its way took the capture away.
        guard captures[display]?.token == token else { return }
        captures[display] = nil
        guard !Task.isCancelled else { return }
        guard let frame else {
            defer { onReleased?(display) }
            AppLog.warn("switch hold: display \(display) poster not delivered within "
                + "\(configuration.grabTimeout.wholeMilliseconds) ms; not holding")
            return
        }
        guard let image = frame.cgImage() else {
            defer { onReleased?(display) }
            AppLog.warn("switch hold: display \(display) poster frame \(frame.width)x\(frame.height) "
                + "could not be used; not holding")
            return
        }
        let held = now()
        generation += 1
        let ticket = Ticket(generation: generation, veil: SwitchHoldVeil(image: image), heldAt: held,
                            deadline: held + configuration.holdCeiling)
        tickets[display] = ticket
        scheduleExpiry(for: display)
        AppLog.info("switch hold: display \(display) frame captured in "
            + "\(started.duration(to: held).wholeMilliseconds) ms (\(frame.width)x\(frame.height))")
    }

    private func layerInstalled(_ notification: Notification) {
        guard let layer = notification.object as? CALayer,
              let values = notification.userInfo,
              let display = (values[WallpaperSwitchHoldNotification.displayIDKey] as? NSNumber)?.uint32Value,
              let reason = (values[WallpaperSwitchHoldNotification.reasonKey] as? String)
                .flatMap(WallpaperSwitchHoldNotification.Reason.init(rawValue:)),
              let ticket = tickets[display], ticket.phase != .dismissing else { return }
        if reason == .reconfigure {
            // A renderer that is showing a picture keeps it through a reconfigure, so a veil
            // that waits for a window, or sits on a host's, loses nothing. A scene successor
            // that has not presented yet has no picture to keep: the layer it leaves is the
            // one the veil sits on, and the veil goes with it unless it follows. The load did
            // not start over, so the ceiling keeps counting from where it was.
            guard ticket.phase == .onScene else { return }
            ticket.veil.attach(to: layer, flush: false)
            Task { AppLog.info("switch hold: display \(display) veil followed a display reconfigure") }
            return
        }
        ticket.veil.attach(to: layer, flush: false)
        ticket.phase = .onScene
        ticket.deadline = now() + configuration.holdCeiling
        ticket.deadlineIsGrace = false
        scheduleExpiry(for: display)
        // After the renderer's window operation, which this runs inside: logging calls the bridge.
        Task { AppLog.info("switch hold: display \(display) veil on scene layer") }
    }

    /// Restarts the display's timer for its current deadline.
    private func scheduleExpiry(for display: UInt32) {
        guard let ticket = tickets[display] else { return }
        ticket.expiry?.cancel()
        let wait = max(.zero, now().duration(to: ticket.deadline))
        let id = ticket.generation
        let sleep = self.sleep
        ticket.expiry = Task { [weak self] in
            do { try await sleep(wait) } catch { return }
            self?.expire(display, generation: id)
        }
    }

    private func expire(_ display: UInt32, generation id: UInt64) {
        guard let ticket = tickets[display], ticket.generation == id, ticket.phase != .dismissing else { return }
        if ticket.deadlineIsGrace {
            dismiss(display, because: "no window took it")
        } else {
            AppLog.warn("switch hold: display \(display) ceiling reached after "
                + "\(configuration.holdCeiling.wholeMilliseconds / 1_000) s; releasing")
            dismiss(display, because: "ceiling")
        }
    }

    /// Fades the veil out and forgets the display; at once when it is not on a window, nobody
    /// sees the window or the person asked for less motion.
    private func dismiss(_ display: UInt32, because reason: String) {
        guard let ticket = tickets[display], ticket.phase != .dismissing else { return }
        ticket.phase = .dismissing
        ticket.expiry?.cancel()
        ticket.settle?.cancel()
        let seconds = Double(ticket.heldAt.duration(to: now()).wholeMilliseconds) / 1_000
        AppLog.info("switch hold: display \(display) released after "
            + "\(String(format: "%.1f", seconds)) s (\(reason))")
        guard ticket.veil.isAttached, configuration.fade > 0, !reduceMotion(), !concealed(display) else {
            remove(display)
            return
        }
        ticket.veil.beginFade(duration: configuration.fade)
        let id = ticket.generation
        let sleep = self.sleep
        // From a timer and not the animation's completion, which does not run for a layer
        // that is off screen and would leave the veil on it.
        let wait = Duration.seconds(configuration.fade) + .milliseconds(50)
        ticket.removal = Task { [weak self] in
            do { try await sleep(wait) } catch { return }
            guard let self, self.tickets[display]?.generation == id else { return }
            self.remove(display)
        }
    }

    private func remove(_ display: UInt32) {
        guard let ticket = tickets.removeValue(forKey: display) else { return }
        ticket.cancelTasks()
        ticket.veil.detach()
        onReleased?(display)
    }
}

/// One request for a still and the wait for its answer.
@MainActor
private final class PosterGrab {
    private let center: NotificationCenter
    private var continuation: CheckedContinuation<DesktopPosterFrame?, Never>?
    private var observer: NSObjectProtocol?
    private var timeout: Task<Void, Never>?

    init(center: NotificationCenter) { self.center = center }

    /// Asks `layer`'s surface for a frame and waits for it, up to `timeout`. The first frame the
    /// layer reports is taken whatever it was asked for: another request for the same layer (the
    /// poster sync's) yields an equally fresh one, and the sync ignores a frame that carries
    /// this request's context, so the still can never become the desktop poster. The listener
    /// is in place before the request goes out, because an answer may come back inside it.
    func run(on layer: CALayer, timeout: Duration,
             sleep: @escaping @Sendable (Duration) async throws -> Void) async -> DesktopPosterFrame? {
        await withCheckedContinuation { (continuation: CheckedContinuation<DesktopPosterFrame?, Never>) in
            self.continuation = continuation
            observer = center.addObserver(
                forName: DesktopPosterNotification.ready, object: layer, queue: .main
            ) { [weak self] notification in
                MainActor.assumeIsolated {
                    if let frame = DesktopPosterFrame(userInfo: notification.userInfo) { self?.finish(frame) }
                }
            }
            self.timeout = Task { [weak self] in
                do { try await sleep(timeout) } catch { return }
                self?.finish(nil)
            }
            center.post(name: DesktopPosterNotification.request, object: layer,
                        userInfo: ["context": "switch-hold:" + UUID().uuidString])
        }
    }

    /// Ends the wait with no frame.
    func cancel() { finish(nil) }

    private func finish(_ frame: DesktopPosterFrame?) {
        guard let continuation else { return }
        self.continuation = nil
        if let observer { center.removeObserver(observer) }
        observer = nil
        timeout?.cancel()
        timeout = nil
        continuation.resume(returning: frame)
    }
}
