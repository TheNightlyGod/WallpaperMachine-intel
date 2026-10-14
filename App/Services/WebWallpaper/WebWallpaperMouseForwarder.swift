import AppKit

/// Decides which web wallpaper window, if any, receives a desktop pointer
/// event. Pure state machine over window numbers so the policy is testable
/// without AppKit windows or a live pointer.
///
/// The desktop is everything the window server stacks beneath ordinary
/// application windows: the system wallpaper, Finder's icon window, desktop
/// widgets and our own wallpaper windows all report a negative window layer.
/// A press that was forwarded keeps its drags and release even when the pointer
/// wanders over an application window, so pages see complete gestures.
struct WebWallpaperMouseRouting {
    enum Kind: Equatable {
        case move
        case scroll
        case down(button: Int)
        case drag(button: Int)
        case up(button: Int)
    }

    enum Decision: Equatable {
        case ignore
        case deliver(to: Int)
        /// The pointer left `exit`; nothing else receives this event.
        case exit(Int)
        /// The pointer moved from one wallpaper window straight onto another.
        case exitThenDeliver(exit: Int, to: Int)
    }

    /// Wallpaper windows deliberately ignore mouse events, so the window the
    /// system reports under the pointer is normally Finder's desktop or the
    /// system wallpaper; both sit below layer 0.
    static let desktopLayerCeiling = 0

    private(set) var hoveredWindow: Int?
    private var pressTargets: [Int: Int] = [:]

    var isPressed: Bool { !pressTargets.isEmpty }

    mutating func reset() {
        hoveredWindow = nil
        pressTargets = [:]
    }

    /// - Parameters:
    ///   - wallpaperWindow: our window covering the pointer, if any.
    ///   - frontWindow: the window number the window server would hit with a mouse down.
    ///   - layer: resolves a front window's `kCGWindowLayer`; `nil` for unknown windows.
    mutating func route(
        _ kind: Kind, wallpaperWindow: Int?, frontWindow: Int, layer: (Int) -> Int?
    ) -> Decision {
        switch kind {
        case .drag(let button), .up(let button):
            guard let target = pressTargets[button] else { return .ignore }
            if case .up = kind { pressTargets[button] = nil }
            return .deliver(to: target)
        case .move, .scroll, .down:
            break
        }
        let onDesktop: Int? = {
            guard let wallpaperWindow else { return nil }
            if frontWindow == wallpaperWindow { return wallpaperWindow }
            guard let layer = layer(frontWindow), layer < Self.desktopLayerCeiling else { return nil }
            return wallpaperWindow
        }()
        guard let target = onDesktop else {
            if case .scroll = kind { return .ignore }
            guard let previous = hoveredWindow else { return .ignore }
            hoveredWindow = nil
            return .exit(previous)
        }
        if case .down(let button) = kind { pressTargets[button] = target }
        if case .scroll = kind { return .deliver(to: target) }
        let previous = hoveredWindow
        hoveredWindow = target
        if let previous, previous != target { return .exitThenDeliver(exit: previous, to: target) }
        return .deliver(to: target)
    }
}

/// Spacing policy for the pointer moves forwarded to a page, kept apart from
/// AppKit so it is testable with explicit timestamps.
///
/// A mouse reports up to 1000 positions a second, and every forwarded move costs
/// the main thread a rebuilt event and a hit test inside WebKit, long before the
/// page could draw more than one frame from it. Per window, a move after a quiet
/// stretch goes through at once (the leading edge, so a flick that starts
/// from rest is never delayed), moves inside the interval are held with only the
/// newest kept, and the held one is delivered when the interval ends (the
/// trailing edge, so the pointer always comes to rest where it stopped).
struct WebWallpaperMoveThrottle {
    enum Outcome: Equatable {
        /// Nothing went through inside the interval: deliver this move now.
        case deliverNow
        /// Keep this move as the newest. The delay is set for the first held
        /// move of a burst only, so one timer serves the whole burst.
        case hold(scheduleFlushAfter: TimeInterval?)
    }

    private struct State {
        var lastDelivery: TimeInterval
        var holding = false
    }

    private var windows: [Int: State] = [:]

    /// Judges a move that arrived at `now` (any monotonic clock the caller uses
    /// consistently, in seconds). A `deliverNow` verdict counts as the delivery;
    /// it also supersedes a move held earlier, which the caller drops.
    mutating func offer(window: Int, at now: TimeInterval, interval: TimeInterval) -> Outcome {
        guard var state = windows[window], now - state.lastDelivery < interval else {
            windows[window] = State(lastDelivery: now)
            return .deliverNow
        }
        let first = !state.holding
        state.holding = true
        windows[window] = state
        guard first else { return .hold(scheduleFlushAfter: nil) }
        let remaining = interval - (now - state.lastDelivery)
        return .hold(scheduleFlushAfter: min(interval, remaining))
    }

    /// A held move was delivered at `now`: the window's next interval starts
    /// from it, and nothing is held any more.
    mutating func delivered(window: Int, at now: TimeInterval) {
        windows[window] = State(lastDelivery: now)
    }

    /// Forgets a window that no longer exists or whose held move was discarded.
    mutating func cancel(window: Int) {
        windows[window] = nil
    }

    mutating func reset() {
        windows = [:]
    }
}

/// Holds the newest move per window while `WebWallpaperMoveThrottle` is
/// spacing deliveries, and delivers it when the interval ends or when anything
/// that must see the pointer's real position arrives first.
///
/// The events are already rebased into their wallpaper window, so replaying a
/// held one later still lands on the position it was observed at. Presses,
/// drags, releases, scrolls and exits are never held; the forwarder calls
/// `flush(window:)` before each of them so a gesture never sees a stale pointer
/// and an exit always follows the last move.
@MainActor
final class WebWallpaperMoveCoalescer {
    private var throttle = WebWallpaperMoveThrottle()
    private var pending: [Int: NSEvent] = [:]
    private var flushTasks: [Int: Task<Void, Never>] = [:]
    private let deliver: @MainActor (Int, NSEvent) -> Bool
    private let now: @MainActor () -> TimeInterval
    private let wait: @Sendable (TimeInterval) async throws -> Void

    /// - Parameters:
    ///   - deliver: hands a move to the page of the window with that number;
    ///     false when the window is gone.
    ///   - now: the clock `flush` stamps a delivery with, on the same timeline
    ///     as `NSEvent.timestamp` (seconds since boot).
    init(
        deliver: @escaping @MainActor (Int, NSEvent) -> Bool,
        now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        wait: (@Sendable (TimeInterval) async throws -> Void)? = nil
    ) {
        self.deliver = deliver
        self.now = now
        self.wait = wait ?? { try await Task.sleep(for: .seconds($0)) }
    }

    /// Whether a move is waiting for its interval to end.
    func hasPending(window: Int) -> Bool { pending[window] != nil }

    func move(_ event: NSEvent, window: Int, interval: TimeInterval) {
        switch throttle.offer(window: window, at: event.timestamp, interval: interval) {
        case .deliverNow:
            discardPending(window: window)
            _ = deliver(window, event)
        case .hold(let flushAfter):
            pending[window] = event
            if let flushAfter { scheduleFlush(window: window, after: flushAfter) }
        }
    }

    /// Delivers the held move of `window`, if any, right now.
    func flush(window: Int) {
        guard let event = pending.removeValue(forKey: window) else { return }
        flushTasks.removeValue(forKey: window)?.cancel()
        throttle.delivered(window: window, at: now())
        if !deliver(window, event) { throttle.cancel(window: window) }
    }

    /// Drops every held move and timer, for a monitor that is being removed.
    func reset() {
        for task in flushTasks.values { task.cancel() }
        flushTasks = [:]
        pending = [:]
        throttle.reset()
    }

    private func discardPending(window: Int) {
        pending[window] = nil
        flushTasks.removeValue(forKey: window)?.cancel()
    }

    private func scheduleFlush(window: Int, after delay: TimeInterval) {
        flushTasks[window]?.cancel()
        flushTasks[window] = Task { @MainActor [weak self, wait] in
            do { try await wait(delay) } catch { return }
            // A gesture, a newer move past the interval or a reset may have
            // taken the held move while this wake-up was queued.
            guard !Task.isCancelled else { return }
            self?.flush(window: window)
        }
    }
}

/// Mirrors desktop pointer input into web wallpaper pages. The wallpaper
/// windows stay mouse-transparent so Finder keeps owning icons and the system
/// keeps its own click handling; a global event monitor observes the same
/// events and replays them into the page under the pointer. Nothing is
/// consumed, so no Accessibility or Input Monitoring grant is involved.
@MainActor
protocol WebWallpaperPointerMonitoring: AnyObject {
    var isActive: Bool { get }
    func setActive(_ active: Bool)
}

@MainActor
final class WebWallpaperMouseForwarder: WebWallpaperPointerMonitoring {
    private static let mask: NSEvent.EventTypeMask = [
        .mouseMoved, .scrollWheel,
        .leftMouseDown, .leftMouseUp, .leftMouseDragged,
        .rightMouseDown, .rightMouseUp, .rightMouseDragged,
        .otherMouseDown, .otherMouseUp, .otherMouseDragged,
    ]

    private let windows: @MainActor () -> [WebWallpaperWindow]
    private var monitor: Any?
    private var routing = WebWallpaperMouseRouting()
    private var layers: [Int: Int] = [:]
    private var reportedMissingWindow = false
    private lazy var moves = WebWallpaperMoveCoalescer { [weak self] number, event in
        guard let window = self?.windows().first(where: { $0.windowNumber == number }) else { return false }
        window.page.deliverMouse(event)
        return true
    }

    init(windows: @escaping @MainActor () -> [WebWallpaperWindow]) {
        self.windows = windows
    }

    var isActive: Bool { monitor != nil }

    func setActive(_ active: Bool) {
        if active {
            guard monitor == nil else { return }
            monitor = NSEvent.addGlobalMonitorForEvents(matching: Self.mask) { [weak self] event in
                MainActor.assumeIsolated { self?.handle(event) }
            }
        } else if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
            routing.reset()
            layers.removeAll()
            moves.reset()
        }
    }

    private func handle(_ event: NSEvent) {
        guard let kind = Self.kind(of: event) else { return }
        let screenPoint = event.window.map { $0.convertPoint(toScreen: event.locationInWindow) } ?? event.locationInWindow
        guard let front = Self.frontWindow(of: event, kind: kind, hitTest: { [self] in
            if !reportedMissingWindow {
                reportedMissingWindow = true
                AppLog.warn("web wallpaper pointer: events carry no window under the pointer; asking the window server")
            }
            return NSWindow.windowNumber(at: screenPoint, belowWindowWithWindowNumber: 0)
        }) else { return }
        let windows = windows()
        let under = windows.first { $0.frame.contains(screenPoint) }
        let decision = routing.route(kind, wallpaperWindow: under?.windowNumber, frontWindow: front) { [self] in layer(of: $0) }
        switch decision {
        case .ignore:
            break
        case .deliver(let number):
            deliver(event, kind: kind, screenPoint: screenPoint, to: number, in: windows)
        case .exit(let number):
            forwardExit(from: number, in: windows)
        case .exitThenDeliver(let exit, let number):
            forwardExit(from: exit, in: windows)
            deliver(event, kind: kind, screenPoint: screenPoint, to: number, in: windows)
        }
    }

    /// The exit follows the last move the pointer made, so a held one goes first.
    private func forwardExit(from number: Int, in windows: [WebWallpaperWindow]) {
        moves.flush(window: number)
        windows.first { $0.windowNumber == number }?.page.deliverMouseExit()
    }

    /// Moves are paced to the page's rate; everything else reaches the page at
    /// once, after the held move so the page sees the pointer where it really is.
    private func deliver(
        _ event: NSEvent, kind: WebWallpaperMouseRouting.Kind, screenPoint: NSPoint, to number: Int,
        in windows: [WebWallpaperWindow]
    ) {
        guard let window = windows.first(where: { $0.windowNumber == number }) else { return }
        let local = window.convertPoint(fromScreen: screenPoint)
        guard let synthesized = Self.rebase(event, to: window, at: local) else { return }
        if case .move = kind {
            moves.move(synthesized, window: number, interval: window.page.pointerMoveInterval)
        } else {
            moves.flush(window: number)
            window.page.deliverMouse(synthesized)
        }
    }

    /// Rebuilds the observed event as if the wallpaper window had received it.
    /// Scroll events cannot be created through `NSEvent`, so their `CGEvent`
    /// is copied with a location chosen so AppKit's window-less conversion
    /// (`x`, primary display height − `y`) lands on the wallpaper-local point.
    static func rebase(_ event: NSEvent, to window: NSWindow, at local: NSPoint) -> NSEvent? {
        if event.type == .scrollWheel {
            guard let copy = event.cgEvent?.copy() else { return nil }
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            copy.location = CGPoint(x: local.x, y: primaryHeight - local.y)
            return NSEvent(cgEvent: copy)
        }
        return NSEvent.mouseEvent(
            with: event.type, location: local, modifierFlags: event.modifierFlags, timestamp: event.timestamp,
            windowNumber: window.windowNumber, context: nil, eventNumber: event.eventNumber,
            clickCount: event.type == .mouseMoved ? 0 : event.clickCount, pressure: event.pressure)
    }

    /// The window a pointer event hits, as the window server recorded it when
    /// it routed the event; nil drops the event.
    ///
    /// Asking again with `NSWindow.windowNumber(at:belowWindowWithWindowNumber:)`
    /// is a synchronous window-server round trip on the main thread for every
    /// move. During Show Desktop or a Space animation that round trip stalls,
    /// and WebKit applies a page's layer commits on the main thread, so every
    /// web wallpaper froze with it. The query remains only for a press or scroll
    /// that arrives without the field; a move without it is dropped, since the
    /// next move corrects hover, and drags and releases follow their press.
    nonisolated static func frontWindow(
        of event: NSEvent, kind: WebWallpaperMouseRouting.Kind, hitTest: () -> Int
    ) -> Int? {
        if let recorded = event.cgEvent?.getIntegerValueField(.mouseEventWindowUnderMousePointer), recorded > 0 {
            return Int(recorded)
        }
        switch kind {
        case .move: return nil
        case .drag, .up: return 0
        case .scroll, .down: return hitTest()
        }
    }

    static func kind(of event: NSEvent) -> WebWallpaperMouseRouting.Kind? {
        switch event.type {
        case .mouseMoved: return .move
        case .scrollWheel: return .scroll
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: return .down(button: event.buttonNumber)
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged: return .drag(button: event.buttonNumber)
        case .leftMouseUp, .rightMouseUp, .otherMouseUp: return .up(button: event.buttonNumber)
        default: return nil
        }
    }

    /// Window numbers are session-unique and the desktop windows are long
    /// lived, so a bounded cache makes the per-move lookup free.
    private func layer(of windowNumber: Int) -> Int? {
        if let cached = layers[windowNumber] { return cached }
        guard let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(windowNumber)) as? [[String: Any]])?.first,
              let layer = info[kCGWindowLayer as String] as? Int else { return nil }
        if layers.count >= 256 { layers.removeAll(keepingCapacity: true) }
        layers[windowNumber] = layer
        return layer
    }
}
