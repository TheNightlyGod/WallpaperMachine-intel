import AppKit

/// Tells when nobody is using the Mac: no keyboard, mouse or trackpad input for the time the
/// Playback & Power rule chose. It only reports; `SystemConditionMonitor` turns an inactive Mac
/// into that rule's pause or stop, so Play and Pause are never involved and nothing needs restoring.
///
/// How long the Mac has gone without input is macOS's own count for the whole login session
/// (`CGEventSource.secondsSinceLastEventType` with the combined session state), which needs no
/// permission and counts the events other apps post into the session as well as the keyboard,
/// pointer, clicks and scrolling.
///
/// Nothing runs until `setTimeout(_:)` names a timeout. While someone uses the Mac the only work
/// is then one one-shot timer, armed for the moment the timeout is reached if no input comes. When
/// it fires the count is read again: input since then arms it again for the time left, and none
/// makes the Mac inactive. Inactive, the monitor waits for the first input with one global and
/// one local event monitor for the pointer, clicks and scrolling (neither needs Accessibility or
/// Input Monitoring; a global key monitor would need Accessibility, so there is none) and a
/// tolerant timer that reads the count every `recheckInterval`, which is how typing alone is
/// noticed. While the displays sleep or another session has the screens no input can reach this
/// session, so that timer waits. Both are asked of the system, never remembered from notifications
/// (see `DisplayPowerProbe`): the displays each time the timer would be armed, the session (a
/// window-server round trip) only when a run of reads begins, because it cannot leave or return
/// without a notice. Watching that starts while the displays already sleep arms nothing, and
/// displays that fall asleep with no notice stop the timer at its next read. Sleep, wake, the
/// session leaving or returning and an unlock read the count at once and arm the timer whatever the
/// system answers then, since a notice can come before the state it announces has settled (see
/// `LockScreenReevaluationBurst`). That read asks both again: a real sleep stops it after one
/// turn, and a wake or return the system had not yet shown still lets typing end the inactivity.
/// The first input removes the monitors and the timer and arms the deadline again.
@MainActor
final class UserInactivityMonitor {
    /// Arms a one-shot timer that calls `fire` once, `delay` from now and at most `leeway` later,
    /// and returns the function that cancels it.
    typealias Schedule = @MainActor (
        _ delay: Duration, _ leeway: Duration, _ fire: @escaping @MainActor () -> Void
    ) -> @MainActor () -> Void
    /// Calls the handler for every pointer, click or scroll event, and returns the function that
    /// stops that.
    typealias InstallMonitor = ActiveDisplayTracker.InstallMonitor

    /// Called when the Mac becomes inactive and when it is used again; never from `setTimeout(_:)`.
    var onChange: (@MainActor () -> Void)?
    /// From the moment the count reached the timeout until the next input.
    private(set) var isInactive = false

    private let secondsSinceInput: @MainActor () -> TimeInterval
    /// Every display is asleep, so no input can reach this session.
    private let displaysAsleep: @MainActor () -> Bool
    /// This session has the screens; false while fast user switching has another session, or the
    /// login window, on them.
    private let sessionOnConsole: @MainActor () -> Bool
    private let schedule: Schedule
    private let installMonitor: InstallMonitor
    private let workspaceCenter: NotificationCenter
    private let lockCenter: NotificationCenter
    private let recheckInterval: Duration
    private let leeway: Duration

    /// In seconds; nil while nothing is watched.
    private var timeout: TimeInterval?
    /// Cancels the one timer armed now: the deadline while the Mac is in use, the recheck while it
    /// is inactive.
    private var cancelTimer: (@MainActor () -> Void)?
    private var removeMonitor: (@MainActor () -> Void)?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    /// What a read of the count asks the system before it arms the read for typing.
    private enum Ask {
        /// The displays, then the session: watching starting, the deadline, a pointer event and
        /// the read after a notice each begin a run of reads.
        case displaysAndSession
        /// The displays only, within a run: the session had the screens when the run began and
        /// cannot leave without a notice, which starts the run over.
        case displays
        /// Nothing, after a notice: the read is armed whatever the system says, because the state
        /// a notice announces can trail it, and that read asks both.
        case nothing
    }

    /// Closures are optional so their `@MainActor` defaults are built inside this initializer.
    init(
        secondsSinceInput: (@MainActor () -> TimeInterval)? = nil,
        displaysAsleep: (@MainActor () -> Bool)? = nil,
        sessionOnConsole: (@MainActor () -> Bool)? = nil,
        schedule: Schedule? = nil,
        installMonitor: InstallMonitor? = nil,
        workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        lockCenter: NotificationCenter = DistributedNotificationCenter.default(),
        recheckInterval: Duration = .seconds(2),
        leeway: Duration = .seconds(1)
    ) {
        self.secondsSinceInput = secondsSinceInput ?? { Self.systemSecondsSinceInput() }
        self.displaysAsleep = displaysAsleep ?? { DisplayPowerProbe.system.displaysAsleep(for: nil) }
        self.sessionOnConsole = sessionOnConsole ?? { WallpaperPresentationAuthority.SessionState.current().onConsole }
        self.schedule = schedule ?? { Self.systemSchedule($0, $1, $2) }
        self.installMonitor = installMonitor ?? { ActiveDisplayTracker.systemMonitor($0) }
        self.workspaceCenter = workspaceCenter
        self.lockCenter = lockCenter
        self.recheckInterval = recheckInterval
        self.leeway = leeway
    }

    /// Watches for `timeout` seconds without input, for a different timeout, or with nil for
    /// nothing, leaving no timer, monitor or observer behind. Settles `isInactive` before it
    /// returns and does not call `onChange` for it: the caller reads it.
    func setTimeout(_ timeout: TimeInterval?) {
        guard timeout != self.timeout else { return }
        let starting = self.timeout == nil
        self.timeout = timeout
        guard timeout != nil else {
            stopWatching()
            return
        }
        if starting { observeSystem() }
        evaluate(announcing: false)
    }

    /// Reads the count and acts on it: inactive from the timeout on, in use below it.
    private func evaluate(announcing: Bool, asking ask: Ask = .displaysAndSession) {
        guard let timeout else { return }
        cancelTimer?()
        cancelTimer = nil
        let reading = secondsSinceInput()
        let idle = reading.isFinite ? max(reading, 0) : 0
        let inactive = idle >= timeout
        let changed = inactive != isInactive
        isInactive = inactive
        if inactive {
            if removeMonitor == nil {
                removeMonitor = installMonitor { [weak self] in self?.inputSeen() }
            }
            armRead(asking: ask)
        } else {
            removeMonitor?()
            removeMonitor = nil
            armDeadline(after: timeout - idle)
        }
        guard changed else { return }
        AppLog.info(inactive
            ? "no input for \(Int(idle)) s: the Mac counts as inactive"
            : "input after inactivity: the Mac is in use again")
        if announcing { onChange?() }
    }

    /// A pointer event while inactive. A burst of them before the monitors are gone reads once.
    private func inputSeen() {
        guard isInactive else { return }
        evaluate(announcing: true)
    }

    private func armDeadline(after remaining: TimeInterval) {
        // Never sooner than a second, so a count read a hair short of the timeout cannot spin.
        cancelTimer = schedule(.seconds(max(remaining, 1)), leeway) { [weak self] in
            self?.cancelTimer = nil
            self?.evaluate(announcing: true)
        }
    }

    /// Arms the read for typing while input can reach this session, as the system says now. The
    /// deadline of a Mac in use does not ask: it fires once, and the read it leads to asks then.
    private func armRead(asking ask: Ask) {
        switch ask {
        case .displaysAndSession: guard !displaysAsleep(), sessionOnConsole() else { return }
        case .displays: guard !displaysAsleep() else { return }
        case .nothing: break
        }
        let next: Ask = ask == .nothing ? .displaysAndSession : .displays
        cancelTimer = schedule(recheckInterval, leeway) { [weak self] in
            self?.cancelTimer = nil
            self?.evaluate(announcing: true, asking: next)
        }
    }

    /// The moments the count can have changed without a pointer event this app sees, and the ones
    /// in which input stops or starts reaching this session. Each one reads the count again and,
    /// while the Mac stays inactive, arms one read that asks the system once the notice has settled.
    private func observeSystem() {
        let names: [(NotificationCenter, Notification.Name)] = [
            (workspaceCenter, NSWorkspace.screensDidSleepNotification),
            (workspaceCenter, NSWorkspace.screensDidWakeNotification),
            (workspaceCenter, NSWorkspace.sessionDidResignActiveNotification),
            (workspaceCenter, NSWorkspace.sessionDidBecomeActiveNotification),
            (workspaceCenter, NSWorkspace.didWakeNotification),
            (lockCenter, Notification.Name("com.apple.screenIsUnlocked")),
        ]
        for (center, name) in names {
            observers.append((center, center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.evaluate(announcing: true, asking: .nothing) }
            }))
        }
    }

    private func stopWatching() {
        cancelTimer?()
        cancelTimer = nil
        removeMonitor?()
        removeMonitor = nil
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        isInactive = false
    }

    // MARK: - The system

    /// Seconds since the last input event of any kind in this login session.
    static func systemSecondsSinceInput() -> TimeInterval {
        // All bits set is kCGAnyInputEventType: the newest event of every kind.
        guard let anyInput = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }

    /// One tolerant sleep on the continuous clock, so a deadline that passed while the Mac slept
    /// fires on wake and reads the count again.
    static func systemSchedule(
        _ delay: Duration, _ leeway: Duration, _ fire: @escaping @MainActor () -> Void
    ) -> @MainActor () -> Void {
        let task = Task { @MainActor in
            do { try await Task.sleep(for: delay, tolerance: leeway) } catch { return }
            // A sleep that ignores cancellation still returns, and must not fire a cancelled timer.
            guard !Task.isCancelled else { return }
            fire()
        }
        return { task.cancel() }
    }
}
