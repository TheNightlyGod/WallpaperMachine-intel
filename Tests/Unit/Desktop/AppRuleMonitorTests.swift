import XCTest
@testable import WallpaperMachine

@MainActor
final class AppRuleMonitorTests: XCTestCase {
    private var defaults: UserDefaults!
    private var preferences: PlaybackPreferences!
    private var workspaceCenter: NotificationCenter!
    private var running: Set<String> = []
    private var frontmost: String?

    override func setUpWithError() throws {
        try super.setUpWithError()
        defaults = try TemporaryDefaults.make(for: self).defaults
        preferences = PlaybackPreferences(defaults: defaults)
        workspaceCenter = NotificationCenter()
        running = []
        frontmost = nil
    }

    override func tearDown() {
        defaults = nil
        preferences = nil
        workspaceCenter = nil
        super.tearDown()
    }

    private func makeMonitor() -> AppRuleMonitor {
        AppRuleMonitor(
            preferences: preferences,
            workspaceCenter: workspaceCenter,
            runningBundleIDs: { self.running },
            frontmostBundleID: { self.frontmost },
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
