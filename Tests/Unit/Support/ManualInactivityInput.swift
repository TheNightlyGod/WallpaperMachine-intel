import AppKit
import XCTest
@testable import WallpaperMachine

/// What a `UserInactivityMonitor` reads, driven by hand: the seconds since the last input, whether
/// the displays sleep and whether this session has the screens, the timers it arms (fired by the
/// test, never by a clock), the pointer monitor it installs, and private notification centers for
/// sleep, wake, the session and the unlock. Nothing here reads real input or displays, or waits.
@MainActor
final class ManualInactivityInput {
    /// One timer the monitor armed.
    final class Armed {
        let delay: Duration
        fileprivate let fire: @MainActor () -> Void
        fileprivate(set) var isCancelled = false
        fileprivate(set) var hasFired = false
        var isLive: Bool { !isCancelled && !hasFired }

        fileprivate init(delay: Duration, fire: @escaping @MainActor () -> Void) {
            self.delay = delay
            self.fire = fire
        }
    }

    let workspaceCenter = NotificationCenter()
    let lockCenter = NotificationCenter()
    /// What macOS would answer for the seconds since the last input.
    var secondsSinceInput: TimeInterval = 0
    /// What the system would answer, asked each time; changing it posts nothing.
    var displaysAsleep = false
    var sessionOnConsole = true
    /// How often the monitor asked whether the displays sleep, and whether this session has the
    /// screens (a window-server round trip on a real Mac).
    private(set) var displayReads = 0
    private(set) var sessionReads = 0
    private(set) var timers: [Armed] = []
    private(set) var monitorInstalls = 0
    private(set) var monitorRemovals = 0
    private var pointerHandler: (@MainActor () -> Void)?

    /// The timers armed and neither fired nor cancelled.
    var liveTimers: [Armed] { timers.filter(\.isLive) }
    var isWatchingThePointer: Bool { pointerHandler != nil }

    func makeMonitor() -> UserInactivityMonitor {
        UserInactivityMonitor(
            secondsSinceInput: { [unowned self] in secondsSinceInput },
            displaysAsleep: { [unowned self] in
                displayReads += 1
                return displaysAsleep
            },
            sessionOnConsole: { [unowned self] in
                sessionReads += 1
                return sessionOnConsole
            },
            schedule: { [unowned self] delay, _, fire in
                let timer = Armed(delay: delay, fire: fire)
                timers.append(timer)
                return { timer.isCancelled = true }
            },
            installMonitor: { [unowned self] handler in
                monitorInstalls += 1
                pointerHandler = handler
                return { [unowned self] in
                    monitorRemovals += 1
                    pointerHandler = nil
                }
            },
            workspaceCenter: workspaceCenter, lockCenter: lockCenter)
    }

    /// Fires the one timer armed now, as its moment arriving would.
    func fireTimer(file: StaticString = #filePath, line: UInt = #line) {
        let live = liveTimers
        guard live.count == 1, let timer = live.first else {
            XCTFail("expected one armed timer, found \(live.count)", file: file, line: line)
            return
        }
        timer.hasFired = true
        timer.fire()
    }

    /// The pointer moves: the count starts again, and the monitor hears of it if it is watching.
    func movePointer() {
        secondsSinceInput = 0
        pointerHandler?()
    }

    func post(_ name: Notification.Name) {
        workspaceCenter.post(name: name, object: nil)
    }

    func postUnlock() {
        lockCenter.post(name: Notification.Name("com.apple.screenIsUnlocked"), object: nil)
    }
}
