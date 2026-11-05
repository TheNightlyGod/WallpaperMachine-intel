import XCTest
@testable import WallpaperMachine

@MainActor
final class AppRuleMonitorTests: XCTestCase {
    private var defaults: UserDefaults!
    private var preferences: PlaybackPreferences!
    private var workspaceCenter: NotificationCenter!
    private var windowCenter: NotificationCenter!
    /// Whether the app in front shows a window on screen, and how many times the monitor asked.
    private var showsWindow = true
    private var windowReads = 0
    private var running: Set<String> = []
    private var frontmost: String?
    private var onBattery = false
    /// How many times the monitor asked for the power source.
    private var batteryReads = 0

    override func setUpWithError() throws {
        try super.setUpWithError()
        defaults = try TemporaryDefaults.make(for: self).defaults
        preferences = PlaybackPreferences(defaults: defaults)
        workspaceCenter = NotificationCenter()
        windowCenter = NotificationCenter()
        showsWindow = true
        windowReads = 0
        running = []
        frontmost = nil
        onBattery = false
        batteryReads = 0
    }

    override func tearDown() {
        defaults = nil
        preferences = nil
        workspaceCenter = nil
        windowCenter = nil
        super.tearDown()
    }

    private func makeMonitor() -> AppRuleMonitor {
        AppRuleMonitor(
            preferences: preferences,
            workspaceCenter: workspaceCenter,
            windowCenter: windowCenter,
            runningBundleIDs: { self.running },
            frontmostBundleID: { self.frontmost },
            onBattery: {
                self.batteryReads += 1
                return self.onBattery
            },
            frontmostShowsWindow: {
                self.windowReads += 1
                return self.showsWindow
            },
            desktopBundleIDs: ["com.apple.finder", "com.example.Self"])
    }

    private func activate(_ bundleID: String?) {
        frontmost = bundleID
        workspaceCenter.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
    }

    func testAnotherAppInFrontActsUntilTheDesktopIsInFront() {
        preferences.otherAppInFrontAction = .mute
        frontmost = "com.apple.finder"
        let monitor = makeMonitor()
        monitor.start()
        defer { monitor.stop() }
        XCTAssertTrue(monitor.actions.isEmpty, "Finder in front is the desktop")

        activate("com.example.Editor")
        XCTAssertEqual(monitor.actions, [.mute])
        activate("com.example.Self")
        XCTAssertTrue(monitor.actions.isEmpty, "This app in front counts as the desktop")
        activate("com.example.Browser")
        XCTAssertEqual(monitor.actions, [.mute])
        activate(nil)
        XCTAssertTrue(monitor.actions.isEmpty, "No app in front is not another app")

        preferences.otherAppInFrontAction = .pause
        activate("com.example.Editor")
        XCTAssertEqual(monitor.actions, [.pause], "A changed choice applies at once")
        preferences.otherAppInFrontAction = .keepRunning
        XCTAssertTrue(monitor.actions.isEmpty)
        activate("com.example.Browser")
        XCTAssertTrue(monitor.actions.isEmpty, "Keep running stops watching for activations")
    }

    /// Pause on battery pauses for another app in front only on battery; the desktop apps never
    /// pause, mains power never does, and a change of power source is worked out again at once.
    func testPauseOnBatteryPausesForAnotherAppOnlyOnBattery() {
        preferences.otherAppInFrontAction = .pauseOnBattery
        onBattery = true
        frontmost = "com.apple.finder"
        let changes = ChangeCount()
        let monitor = makeMonitor()
        monitor.onChange = { changes.value += 1 }
        monitor.start()
        defer { monitor.stop() }
        XCTAssertTrue(monitor.actions.isEmpty, "Finder in front is the desktop, on battery too")
        XCTAssertEqual(batteryReads, 0, "With the desktop in front the power source is not read")

        activate("com.example.Editor")
        XCTAssertEqual(monitor.actions, [.pause], "Another app in front on battery pauses")
        activate("com.example.Self")
        XCTAssertTrue(monitor.actions.isEmpty, "This app in front counts as the desktop")
        activate("com.example.Editor")
        XCTAssertEqual(monitor.actions, [.pause])

        onBattery = false
        monitor.refresh()
        XCTAssertTrue(monitor.actions.isEmpty, "Plugging in ends the pause at once")
        activate("com.example.Browser")
        XCTAssertTrue(monitor.actions.isEmpty, "On mains power another app in front changes nothing")

        onBattery = true
        monitor.refresh()
        XCTAssertEqual(monitor.actions, [.pause], "Unplugging with another app in front pauses at once")
        XCTAssertEqual(changes.value, 5, "Each change is published once")

        monitor.refresh()
        XCTAssertEqual(changes.value, 5, "A refresh that finds the same source publishes nothing")
    }

    /// The monitor keeps watching activations for Pause on battery while plugged in, so an unplug
    /// finds the app in front already known; a refresh while stopped does nothing.
    func testPauseOnBatteryIsWatchedOnMainsPowerToo() {
        XCTAssertFalse(AppRuleMonitor.isNeeded(for: preferences))
        preferences.otherAppInFrontAction = .pauseOnBattery
        XCTAssertTrue(AppRuleMonitor.isNeeded(for: preferences))

        let monitor = makeMonitor()
        monitor.start()
        activate("com.example.Editor")
        XCTAssertTrue(monitor.actions.isEmpty)
        onBattery = true
        monitor.refresh()
        XCTAssertEqual(monitor.actions, [.pause])

        monitor.stop()
        XCTAssertTrue(monitor.actions.isEmpty)
        monitor.refresh()
        XCTAssertTrue(monitor.actions.isEmpty, "A stopped monitor stays silent")
    }

    /// Mute and Pause act on every power source, as they always did, without reading it.
    func testMuteAndPauseIgnoreThePowerSource() {
        preferences.otherAppInFrontAction = .pause
        frontmost = "com.example.Editor"
        let monitor = makeMonitor()
        monitor.start()
        defer { monitor.stop() }
        XCTAssertEqual(monitor.actions, [.pause])
        onBattery = true
        monitor.refresh()
        XCTAssertEqual(monitor.actions, [.pause])
        preferences.otherAppInFrontAction = .mute
        XCTAssertEqual(monitor.actions, [.mute])
        XCTAssertEqual(batteryReads, 0, "Only Pause on battery asks for the power source")
    }

    private func windowsChanged() {
        windowCenter.post(name: NSWindow.didChangeOcclusionStateNotification, object: nil)
    }

    /// An app stays in front after its last window is minimized: the window change that follows
    /// finds it without a window and the wallpaper plays, until a window shows again or an app is
    /// activated. An activation counts at once, before its first window has opened.
    func testAnAppInFrontWithoutAWindowOnScreenIsNotInTheWay() {
        preferences.otherAppInFrontAction = .pauseOnBattery
        onBattery = true
        frontmost = "com.example.Editor"
        let monitor = makeMonitor()
        monitor.start()
        defer { monitor.stop() }
        XCTAssertEqual(monitor.actions, [.pause])

        showsWindow = false
        windowsChanged()
        XCTAssertTrue(monitor.actions.isEmpty, "Minimizing the last window plays the wallpaper")
        monitor.refresh()
        XCTAssertTrue(monitor.actions.isEmpty, "A power refresh keeps what the window change found")

        showsWindow = true
        windowsChanged()
        XCTAssertEqual(monitor.actions, [.pause], "Restoring the window pauses again")

        showsWindow = false
        windowsChanged()
        activate("com.example.Browser")
        XCTAssertEqual(monitor.actions, [.pause], "A newly activated app counts before its window opens")

        onBattery = false
        windowsChanged()
        showsWindow = true
        windowsChanged()
        onBattery = true
        monitor.refresh()
        XCTAssertEqual(monitor.actions, [.pause], "A window restored on mains power is known at the unplug")
    }

    /// The window server is asked only while another app is in front and the choice watches it.
    func testWindowChangesAskOnlyWhileAnotherAppIsInFront() {
        preferences.otherAppInFrontAction = .pause
        frontmost = "com.apple.finder"
        let monitor = makeMonitor()
        monitor.start()
        windowsChanged()
        XCTAssertEqual(windowReads, 0, "The desktop in front is never asked about")

        activate("com.example.Editor")
        windowsChanged()
        XCTAssertEqual(windowReads, 1)

        preferences.otherAppInFrontAction = .keepRunning
        windowsChanged()
        XCTAssertEqual(windowReads, 1, "Keep running stops watching window changes")
        preferences.otherAppInFrontAction = .pause
        monitor.stop()
        windowsChanged()
        XCTAssertEqual(windowReads, 1, "A stopped monitor stops watching window changes")
    }

    func testAnotherAppInFrontComposesWithAnAppRule() {
        let rule = preferences.addRule(bundleIdentifier: "com.example.Game", name: "Game")
        try? preferences.updateRule(id: rule.id, condition: .frontmost)
        try? preferences.updateRule(id: rule.id, action: .stop)
        preferences.otherAppInFrontAction = .mute
        let monitor = makeMonitor()
        monitor.start()
        defer { monitor.stop() }

        activate("com.example.Game")
        XCTAssertEqual(monitor.actions, [.stop, .mute])
        activate("com.apple.finder")
        XCTAssertTrue(monitor.actions.isEmpty)
    }

    func testTheMonitorIsNeededOnlyForARuleOrAnInFrontChoice() {
        XCTAssertFalse(AppRuleMonitor.isNeeded(for: preferences))
        preferences.otherAppInFrontAction = .mute
        XCTAssertTrue(AppRuleMonitor.isNeeded(for: preferences))
        preferences.otherAppInFrontAction = .keepRunning
        preferences.addRule(bundleIdentifier: "com.example.Player", name: "Player")
        XCTAssertTrue(AppRuleMonitor.isNeeded(for: preferences))
    }

    func testRunningRuleFiresOnlyWhileThatAppIsRunning() {
        let rule = preferences.addRule(bundleIdentifier: "com.example.Player", name: "Player")
        try? preferences.updateRule(id: rule.id, action: .pause)
        let monitor = makeMonitor()
        monitor.start()
        defer { monitor.stop() }
        XCTAssertTrue(monitor.actions.isEmpty, "A running rule does not fire before the app launches")

        running = ["com.example.Player"]
        workspaceCenter.post(name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        XCTAssertEqual(monitor.actions, [.pause])

        running = []
        workspaceCenter.post(name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        XCTAssertTrue(monitor.actions.isEmpty)
    }

    func testFrontmostRuleIgnoresABackgroundInstance() {
        let rule = preferences.addRule(bundleIdentifier: "com.example.Player", name: "Player")
        try? preferences.updateRule(id: rule.id, condition: .frontmost)
        try? preferences.updateRule(id: rule.id, action: .mute)
        running = ["com.example.Player"]
        let monitor = makeMonitor()
        monitor.start()
        defer { monitor.stop() }
        XCTAssertTrue(monitor.actions.isEmpty, "Running in the background is not in front")

        frontmost = "com.example.Player"
        workspaceCenter.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        XCTAssertEqual(monitor.actions, [.mute])

        frontmost = "com.example.Other"
        workspaceCenter.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        XCTAssertTrue(monitor.actions.isEmpty)
    }

    func testRemovingTheLastRuleClearsActionsEvenIfTheAppStaysRunning() {
        let rule = preferences.addRule(bundleIdentifier: "com.example.Player", name: "Player")
        running = ["com.example.Player"]
        let changes = ChangeCount()
        let monitor = makeMonitor()
        monitor.onChange = { changes.value += 1 }
        monitor.start()
        defer { monitor.stop() }
        XCTAssertEqual(monitor.actions, [.pause])
        XCTAssertEqual(changes.value, 1)

        preferences.removeRule(id: rule.id)
        XCTAssertTrue(monitor.actions.isEmpty)
        running = ["com.example.Player", "com.example.Other"]
        workspaceCenter.post(name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        XCTAssertTrue(monitor.actions.isEmpty, "With no rules left, launches do not revive an action")
    }
}

private final class ChangeCount: @unchecked Sendable {
    var value = 0
}
