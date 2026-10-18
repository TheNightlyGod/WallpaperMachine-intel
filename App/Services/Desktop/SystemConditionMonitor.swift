import Foundation

/// Reports what conditions of the whole Mac ask for: Low Power Mode, a hot Mac and a low battery,
/// each as the user chose under Playback, and whatever a Focus filter set.
///
/// `actions` are rule actions. They join the app rules' actions in `WallpaperPresentationPolicy`,
/// so they pause, mute or stop wallpapers the same way and never change the user's own
/// Play/Pause. `qualityReductions` name the conditions that chose Reduced quality instead: they
/// pause nothing, they ask for a lower frame-rate ceiling and render scale. A hot Mac that chose
/// Reduced quality reduces from serious and also contributes a pause once macOS reports critical,
/// the state in which it is at its limit; Pause and Stop keep acting from serious.
///
/// `engaged` says which condition contributed what, and is written to `state` for the control
/// panel, so the panel names the rule behind a pause without working the conditions out again.
///
/// Only notifications are observed; nothing is polled. The one source added for the battery is
/// IOKit's power-source notification, and it is observed only while a low-battery action is
/// chosen.
@MainActor
final class SystemConditionMonitor {
    var onChange: (@MainActor () -> Void)?
    private(set) var actions: Set<AppRuleAction> = []
    private(set) var qualityReductions: Set<QualityReduction> = []
    /// Which conditions hold now and what each one's rule does; the Focus filter is not one.
    private(set) var engaged = EngagedSystemConditions()

    private let preferences: PlaybackPreferences
    private let focus: FocusFilterState
    private let systemCenter: NotificationCenter
    private let preferencesCenter: NotificationCenter
    private let isLowPowerModeEnabled: @MainActor () -> Bool
    private let thermalState: @MainActor () -> ProcessInfo.ThermalState
    private let battery: any BatteryLevelSource
    private let state: SystemConditionState
    private var lowBatteryGate = LowBatteryGate()
    private var isObservingBattery = false
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    init(
        preferences: PlaybackPreferences,
        focus: FocusFilterState,
        systemCenter: NotificationCenter = .default,
        preferencesCenter: NotificationCenter = .default,
        isLowPowerModeEnabled: (@MainActor () -> Bool)? = nil,
        thermalState: (@MainActor () -> ProcessInfo.ThermalState)? = nil,
        battery: (any BatteryLevelSource)? = nil,
        state: SystemConditionState? = nil
    ) {
        self.preferences = preferences
        self.focus = focus
        self.systemCenter = systemCenter
        self.preferencesCenter = preferencesCenter
        self.isLowPowerModeEnabled = isLowPowerModeEnabled ?? { ProcessInfo.processInfo.isLowPowerModeEnabled }
        self.thermalState = thermalState ?? { ProcessInfo.processInfo.thermalState }
        self.battery = battery ?? SystemBatteryLevel()
        // The app passes the shared state; anything else publishes where no panel reads it.
        self.state = state ?? SystemConditionState()
    }

    /// Serious and critical are the states in which macOS itself starts throttling.
    static func isHot(_ state: ProcessInfo.ThermalState) -> Bool {
        state == .serious || state == .critical
    }

    func start() {
        guard observers.isEmpty else {
            recompute()
            return
        }
        // ProcessInfo posts both on whichever thread noticed the change.
        let sources: [(NotificationCenter, Notification.Name, AnyObject?)] = [
            (systemCenter, .NSProcessInfoPowerStateDidChange, nil),
            (systemCenter, ProcessInfo.thermalStateDidChangeNotification, nil),
            (preferencesCenter, PlaybackPreferences.didChangeNotification, preferences),
            (preferencesCenter, FocusFilterState.didChangeNotification, focus),
        ]
        for (center, name, object) in sources {
            observers.append((center, center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.recompute() }
            }))
        }
        recompute()
    }

    func stop() {
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        stopObservingBattery()
        publish(Contributions())
    }

    /// Reads the battery again, for a moment the Mac may have changed it without a notification,
    /// such as a plug or unplug during sleep. Does nothing while no low-battery action is chosen.
    func refreshBattery() {
        guard isObservingBattery else { return }
        recompute()
    }

    private func recompute() {
        guard !observers.isEmpty else { return }
        var next = Contributions()
        if isLowPowerModeEnabled() {
            next.add(preferences.lowPowerModeAction, for: .lowPowerMode)
        }
        let thermal = thermalState()
        if Self.isHot(thermal) {
            // Reducing is the answer to serious heat; at critical it is no longer enough.
            next.add(preferences.thermalAction, for: .heat, pausesWhenReducing: thermal == .critical)
        }
        if let action = focus.action { next.actions.insert(action) }
        if let choice = lowBatteryAction() {
            next.add(choice, for: .lowBattery)
        }
        publish(next)
    }

    /// What the conditions evaluated together ask for.
    private struct Contributions {
        var actions = Set<AppRuleAction>()
        var qualityReductions = Set<QualityReduction>()
        var engaged = [EngagedSystemCondition]()

        /// Adds what `choice` contributes while `condition` holds: its rule action, or the
        /// reduction it names and, with `pausesWhenReducing`, a pause on top.
        mutating func add(
            _ choice: SystemConditionAction, for condition: SystemCondition, pausesWhenReducing: Bool = false
        ) {
            let effect: EngagedSystemCondition.Effect
            switch choice {
            case .keepRunning: return
            case .reduceQuality:
                qualityReductions.insert(condition.qualityReduction)
                if pausesWhenReducing { actions.insert(.pause) }
                effect = pausesWhenReducing ? .pause : .reducedQuality
            case .pause:
                actions.insert(.pause)
                effect = .pause
            case .stop:
                actions.insert(.stop)
                effect = .stop
            }
            engaged.append(EngagedSystemCondition(condition: condition, effect: effect))
        }
    }

    /// The low-battery action while the rule is engaged, nil otherwise. Chosen means observed:
    /// the power-source notification is registered for as long as an action other than keep
    /// running is saved, and the gate starts over whenever observation does.
    private func lowBatteryAction() -> SystemConditionAction? {
        let action = preferences.lowBatteryAction
        guard action != .keepRunning else {
            stopObservingBattery()
            return nil
        }
        startObservingBattery()
        let threshold = preferences.lowBatteryThreshold
        let reading = battery.reading
        let wasEngaged = lowBatteryGate.isEngaged
        let engaged = lowBatteryGate.update(reading, threshold: threshold)
        if engaged != wasEngaged {
            let charge = reading.map { "\($0.percent)%" } ?? "unknown"
            AppLog.info(engaged
                ? "battery at \(charge): low-battery rule engaged (threshold \(threshold)%, \(action.rawValue))"
                : "battery at \(charge): low-battery rule released (threshold \(threshold)%)")
        }
        return engaged ? action : nil
    }

    private func startObservingBattery() {
        guard !isObservingBattery else { return }
        isObservingBattery = true
        battery.start { [weak self] in self?.recompute() }
    }

    private func stopObservingBattery() {
        lowBatteryGate.reset()
        guard isObservingBattery else { return }
        isObservingBattery = false
        battery.stop()
    }

    private func publish(_ contributions: Contributions) {
        let next = contributions.actions
        let nextReductions = contributions.qualityReductions
        let nextEngaged = EngagedSystemConditions(contributions.engaged)
        // A second condition can engage with the same action as the first: nothing the policy reads
        // changes, but the panel names a different rule.
        let policyInputsChanged = next != actions || nextReductions != qualityReductions
        guard policyInputsChanged || nextEngaged != engaged else { return }
        actions = next
        qualityReductions = nextReductions
        engaged = nextEngaged
        state.set(nextEngaged)
        guard policyInputsChanged else { return }
        var asked = next.isEmpty ? "run" : next.map(\.rawValue).sorted().joined(separator: ", ")
        if !nextReductions.isEmpty {
            asked += ", reduced quality: \(nextReductions.sorted().map(\.logLabel).joined(separator: ", "))"
        }
        AppLog.info("system conditions ask wallpapers to \(asked)")
        onChange?()
    }
}
