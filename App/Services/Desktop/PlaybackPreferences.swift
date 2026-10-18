import Foundation

enum DisplaySleepAction: String, Codable, CaseIterable, Sendable {
    case pause
    case stop
}

enum OtherAudioAction: String, Codable, CaseIterable, Sendable {
    case keepRunning
    case mute
    case pause
}

/// What a wallpaper does while other windows cover its display's working area.
enum DesktopCoveredAction: String, Codable, CaseIterable, Sendable {
    case pause
    case keepRunning
}

/// What wallpapers do while a condition of the whole Mac holds: Low Power Mode, macOS
/// reporting it hot, or a low battery.
enum SystemConditionAction: String, Codable, CaseIterable, Sendable {
    case keepRunning
    /// Keep playing, but under a lower frame-rate ceiling and render scale. Not a rule action: it
    /// never pauses, mutes or stops anything by itself. Its stored name differs from the battery
    /// mode's `reducedQuality` on purpose, so the two choices cannot be mistaken for each other.
    case reduceQuality
    case pause
    case stop

    /// The rule action it contributes, the same way an app rule's does; nil while it keeps
    /// running or only reduces quality.
    var ruleAction: AppRuleAction? {
        switch self {
        case .keepRunning, .reduceQuality: nil
        case .pause: .pause
        case .stop: .stop
        }
    }

    var reducesQuality: Bool { self == .reduceQuality }
}

/// Why wallpapers are asked to run at reduced quality. Declared in the order the causes are
/// named when several hold: heat first, then Low Power Mode, then a low battery.
enum QualityReduction: String, CaseIterable, Comparable, Sendable {
    case heat
    case lowPowerMode
    case lowBattery

    /// The words the log uses for it.
    var logLabel: String {
        switch self {
        case .heat: "heat"
        case .lowPowerMode: "Low Power Mode"
        case .lowBattery: "low battery"
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (Self.allCases.firstIndex(of: lhs) ?? 0) < (Self.allCases.firstIndex(of: rhs) ?? 0)
    }
}

enum AppRuleCondition: String, Codable, CaseIterable, Sendable {
    case running
    case frontmost
}

enum AppRuleAction: String, Codable, CaseIterable, Sendable {
    case pause
    case mute
    case stop
}

struct AppRule: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var bundleIdentifier: String
    var name: String
    var condition: AppRuleCondition
    var action: AppRuleAction
}

/// UserDefaults-backed playback rules for display sleep, other-app audio, a
/// covered desktop, Low Power Mode, a hot Mac, a low battery, playing only on the display in use
/// and per-app pause, mute and stop, whether every wallpaper is muted, and whether the macOS
/// desktop picture is written at all. Mutations post `didChangeNotification` once.
@MainActor
final class PlaybackPreferences {
    static let didChangeNotification = Notification.Name("WallpaperMachine.playbackPreferencesDidChange")
    static let shared = PlaybackPreferences()

    struct UnknownRule: LocalizedError, Equatable {
        var errorDescription: String? {
            String(localized: "That app rule no longer exists.")
        }
    }

    private static let displaySleepKey = "WallpaperMachine.displaySleepAction"
    private static let otherAudioKey = "WallpaperMachine.otherAudioAction"
    private static let desktopCoveredKey = "WallpaperMachine.desktopCoveredAction"
    private static let appRulesKey = "WallpaperMachine.appRules"
    private static let lowPowerModeKey = "WallpaperMachine.lowPowerModeAction"
    private static let thermalKey = "WallpaperMachine.thermalAction"
    private static let lowBatteryActionKey = "WallpaperMachine.lowBatteryAction"
    private static let lowBatteryThresholdKey = "WallpaperMachine.lowBatteryThreshold"
    private static let periodicDesktopPictureKey = "WallpaperMachine.refreshDesktopPicturePeriodically"
    private static let writeDesktopPictureKey = "WallpaperMachine.writeDesktopPicture"
    private static let playOnlyOnActiveDisplayKey = "WallpaperMachine.playOnlyOnActiveDisplay"
    private static let wallpapersMutedKey = "WallpaperMachine.wallpapersMuted"

    /// The charge levels the user can pick for the low-battery rule, in percent.
    nonisolated static let lowBatteryThresholds = [10, 20, 30]
    nonisolated static let defaultLowBatteryThreshold = 20

    private let defaults: UserDefaults

    init(defaults: UserDefaults = ClientPreferences.defaults) {
        self.defaults = defaults
        appRules = Self.loadRules(from: defaults)
    }

    var displaySleepAction: DisplaySleepAction {
        get { storedEnum(Self.displaySleepKey, default: .pause) }
        set { store(newValue.rawValue, forKey: Self.displaySleepKey) }
    }

    var otherAudioAction: OtherAudioAction {
        get { storedEnum(Self.otherAudioKey, default: .keepRunning) }
        set { store(newValue.rawValue, forKey: Self.otherAudioKey) }
    }

    var desktopCoveredAction: DesktopCoveredAction {
        get { storedEnum(Self.desktopCoveredKey, default: .pause) }
        set { store(newValue.rawValue, forKey: Self.desktopCoveredKey) }
    }

    /// Off until chosen, like battery: Low Power Mode alone never changes playback. Reduced quality
    /// lowers the frame-rate ceiling and render scale for as long as it lasts.
    var lowPowerModeAction: SystemConditionAction {
        get { storedEnum(Self.lowPowerModeKey, default: .keepRunning) }
        set { store(newValue.rawValue, forKey: Self.lowPowerModeKey) }
    }

    /// Applies while macOS reports the thermal state as serious or critical. Reduced quality
    /// applies from serious and adds a pause at critical, where macOS is at its limit; Pause and
    /// Stop apply from serious.
    var thermalAction: SystemConditionAction {
        get { storedEnum(Self.thermalKey, default: .keepRunning) }
        set { store(newValue.rawValue, forKey: Self.thermalKey) }
    }

    /// Off until chosen: a low battery alone never changes playback. Applies only while the Mac
    /// runs on its internal battery at or below `lowBatteryThreshold`; Reduced quality lowers the
    /// frame-rate ceiling and render scale instead of pausing.
    var lowBatteryAction: SystemConditionAction {
        get { storedEnum(Self.lowBatteryActionKey, default: .keepRunning) }
        set { store(newValue.rawValue, forKey: Self.lowBatteryActionKey) }
    }

    /// One of `lowBatteryThresholds`. A stored value outside the list, which only a hand edit or
    /// a damaged file can leave, reads as the default; setting one is ignored.
    var lowBatteryThreshold: Int {
        get {
            guard let stored = defaults.object(forKey: Self.lowBatteryThresholdKey) as? Int,
                  Self.lowBatteryThresholds.contains(stored) else { return Self.defaultLowBatteryThreshold }
            return stored
        }
        set {
            guard Self.lowBatteryThresholds.contains(newValue) else { return }
            defaults.set(newValue, forKey: Self.lowBatteryThresholdKey)
            postChange()
        }
    }

    /// Off by default. With two or more displays, only the one the pointer is on plays; the others
    /// pause a few seconds after the pointer leaves them. Never touches the user's own Play/Pause.
    var playsOnlyOnActiveDisplay: Bool {
        get { defaults.bool(forKey: Self.playOnlyOnActiveDisplayKey) }
        set {
            defaults.set(newValue, forKey: Self.playOnlyOnActiveDisplayKey)
            postChange()
        }
    }

    /// Off by default. Silences every wallpaper, in addition to whatever a wallpaper's own saved
    /// mute and volume say, which it never rewrites: turning it off lets each play as it was
    /// saved. It composes with the mute app rules, Focus filters and other-app audio rather than
    /// replacing them. Kept across relaunches, but local to this Mac and not part of a settings
    /// backup, so restoring one never silences a Mac without its owner asking. Setting the value
    /// it already has changes nothing and posts nothing.
    var wallpapersMuted: Bool {
        get { defaults.bool(forKey: Self.wallpapersMutedKey) }
        set {
            guard newValue != wallpapersMuted else { return }
            defaults.set(newValue, forKey: Self.wallpapersMutedKey)
            postChange()
        }
    }

    /// On until turned off. Whether the app installs a still frame of the wallpaper as macOS's own
    /// desktop picture, the one Mission Control and the moment before a wallpaper loads show. Off,
    /// no picture is written and the user's own comes back. Local to this Mac, so it is not part of
    /// a settings backup.
    var writesDesktopPicture: Bool {
        get { defaults.object(forKey: Self.writeDesktopPictureKey) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: Self.writeDesktopPictureKey)
            postChange()
        }
    }

    /// Off by default: the still picture Mission Control shows is otherwise
    /// taken again only when a wallpaper starts, changes or resumes.
    var refreshesDesktopPicturePeriodically: Bool {
        get { defaults.bool(forKey: Self.periodicDesktopPictureKey) }
        set {
            defaults.set(newValue, forKey: Self.periodicDesktopPictureKey)
            postChange()
        }
    }

    private(set) var appRules: [AppRule]

    @discardableResult
    func addRule(bundleIdentifier: String, name: String) -> AppRule {
        if let existing = appRules.first(where: { $0.bundleIdentifier == bundleIdentifier }) {
            return existing
        }
        let rule = AppRule(
            id: UUID(),
            bundleIdentifier: bundleIdentifier,
            name: name,
            condition: .running,
            action: .pause)
        appRules.append(rule)
        persistRules()
        return rule
    }

    func updateRule(id: UUID, condition: AppRuleCondition) throws {
        guard let index = appRules.firstIndex(where: { $0.id == id }) else { throw UnknownRule() }
        appRules[index].condition = condition
        persistRules()
    }

    func updateRule(id: UUID, action: AppRuleAction) throws {
        guard let index = appRules.firstIndex(where: { $0.id == id }) else { throw UnknownRule() }
        appRules[index].action = action
        persistRules()
    }

    func removeRule(id: UUID) {
        let count = appRules.count
        appRules.removeAll { $0.id == id }
        guard appRules.count != count else { return }
        persistRules()
    }

    /// Settings › Reset All Settings: every choice back to its default and every app rule removed,
    /// announced once.
    func resetToDefaults() {
        for key in [
            Self.displaySleepKey, Self.otherAudioKey, Self.desktopCoveredKey, Self.appRulesKey,
            Self.lowPowerModeKey, Self.thermalKey, Self.lowBatteryActionKey, Self.lowBatteryThresholdKey,
            Self.periodicDesktopPictureKey, Self.writeDesktopPictureKey, Self.playOnlyOnActiveDisplayKey,
            Self.wallpapersMutedKey,
        ] {
            defaults.removeObject(forKey: key)
        }
        appRules = []
        postChange()
    }

    private func storedEnum<T: RawRepresentable>(_ key: String, default fallback: T) -> T where T.RawValue == String {
        guard let raw = defaults.string(forKey: key), let value = T(rawValue: raw) else { return fallback }
        return value
    }

    private func store(_ raw: String, forKey key: String) {
        defaults.set(raw, forKey: key)
        postChange()
    }

    private func persistRules() {
        guard let data = try? JSONEncoder().encode(appRules) else { return }
        defaults.set(data, forKey: Self.appRulesKey)
        postChange()
    }

    private func postChange() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    private static func loadRules(from defaults: UserDefaults) -> [AppRule] {
        guard let data = defaults.data(forKey: appRulesKey),
              let decoded = try? JSONDecoder().decode([AppRule].self, from: data) else { return [] }
        return decoded
    }
}
