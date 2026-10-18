import Foundation

struct FocusWallpaperSelection: Codable, Equatable, Sendable {
    let target: WallpaperAutomationTarget
    let displayID: String?

    var key: String {
        // Length-delimited fields do not alias ids containing punctuation.
        [target.kind.rawValue, target.id, displayID ?? ""].map { "\($0.utf8.count):\($0)" }.joined()
    }
}

struct WallpaperAutomationDisplayState: Codable, Equatable, Sendable {
    var playlist: DisplayPlaylist
    var wallpaperID: String?
}

struct FocusWallpaperRestore: Codable, Equatable, Sendable {
    var key: String
    var before: WallpaperAutomationDisplayState
    var expectedPlaylist: DisplayPlaylist
    var preserveWallpaper = false
    var baselineKey: String?
    var pending = false
}

/// Persistent rules and local Focus recovery; runtime status is separate from settings.
@MainActor
final class WallpaperAutomationStore {
    static let shared = WallpaperAutomationStore()
    static let configurationsKey = "WallpaperMachine.automaticWallpapers"
    static let locationKey = "WallpaperMachine.solarLocation"
    static let solarKey = "WallpaperMachine.solarSettings"
    static let handledKey = "WallpaperMachine.automaticWallpaperHandled"
    static let focusRestoreKey = "WallpaperMachine.focusWallpaperRestore"
    static let didChangeNotification = Notification.Name("WallpaperMachine.automationSettingsChanged")
    static let statusChangedNotification = Notification.Name("WallpaperMachine.automationStatusChanged")
    private let defaults: UserDefaults
    private(set) var configurations: [String: DisplayWallpaperAutomation]
    private(set) var solar: WallpaperSolarSettings
    /// The coordinates the sunset and sunrise rules plan with, whatever their source.
    var location: WallpaperSolarLocation? { solar.location }
    private(set) var handled: [String: String]
    private(set) var focusRestore: [String: FocusWallpaperRestore]
    private(set) var loadError: String?
    private(set) var errors: [String: String] = [:]
    private(set) var next: [String: WallpaperAutomationOccurrence] = [:]
    private(set) var focusedDisplays: Set<String> = []
    var manualChoice: (@MainActor (String) -> Void)?

    init(defaults: UserDefaults = ClientPreferences.defaults) {
        self.defaults = defaults
        var failed = false
        func read<T: Decodable>(_ key: String, _ type: T.Type, fallback: T) -> T {
            guard let data = defaults.data(forKey: key) else { return fallback }
            guard data.count <= 2 * 1024 * 1024, let value = try? JSONDecoder().decode(type, from: data) else {
                failed = true
                return fallback
            }
            return value
        }
        let stored = read(Self.configurationsKey, [String: DisplayWallpaperAutomation].self, fallback: [:])
        configurations = stored.count <= 64 ? stored.filter { Self.validDisplay($0.key) && $0.value.isValid } : [:]
        if configurations.count != stored.count { failed = true }
        if let data = defaults.data(forKey: Self.solarKey),
           let stored = try? JSONDecoder().decode(WallpaperSolarSettings.self, from: data),
           stored.isValid {
            solar = stored
        } else {
            if defaults.data(forKey: Self.solarKey) != nil { failed = true }
            // Settings written before the source existed hold a bare location; read it as the
            // coordinates source so an upgrade keeps the user's position. Only the fallback
            // reads it: a corrupt legacy value must not fail a working settings record.
            let legacyLocation: WallpaperSolarLocation? = defaults.data(forKey: Self.locationKey).flatMap {
                guard let value = try? JSONDecoder().decode(WallpaperSolarLocation.self, from: $0),
                      value.isValid else { failed = true; return nil }
                return value
            }
            solar = WallpaperSolarSettings(location: legacyLocation)
        }
        handled = read(Self.handledKey, [String: String].self, fallback: [:])
            .filter { Self.validDisplay($0.key) && $0.value.count <= 4096 }
        focusRestore = read(Self.focusRestoreKey, [String: FocusWallpaperRestore].self, fallback: [:])
            .filter { Self.validDisplay($0.key) && $0.value.key.count <= 4096 }
        if failed {
            loadError = String(localized: "Some automatic wallpaper settings could not be read. Check your rules and Focus choices before using them.")
            AppLog.warn("automatic wallpaper preferences could not be fully decoded")
        }
    }

    func configuration(for display: String) -> DisplayWallpaperAutomation { configurations[display] ?? .init() }

    func update(_ display: String, _ change: (inout DisplayWallpaperAutomation) throws -> Void) throws {
        guard Self.validDisplay(display), configurations[display] != nil || configurations.count < 64 else { throw Self.invalid() }
        let before = configuration(for: display)
        var value = before
        try change(&value)
        guard value.isValid else { throw Self.invalid() }
        guard value != before else { return }
        value.revision = before.revision &+ 1
        var updated = configurations
        updated[display] = value
        let data = try JSONEncoder().encode(updated)
        configurations = updated
        defaults.set(data, forKey: Self.configurationsKey)
        loadError = nil
        changed()
    }

    func saveRule(_ rule: WallpaperAutomationRule, on display: String) throws {
        guard rule.isValid else { throw Self.invalid() }
        try update(display) { value in
            if let index = value.rules.firstIndex(where: { $0.id == rule.id }) { value.rules[index] = rule }
            else { value.rules.append(rule) }
        }
    }

    func removeRule(_ id: String, from display: String) throws {
        try update(display) { $0.rules.removeAll { $0.id == id } }
    }

    func setLocation(_ value: WallpaperSolarLocation?) throws {
        guard value?.isValid != false else { throw Self.invalid() }
        guard solar.location != value else { return }
        var updated = solar
        updated.location = value
        try setSolar(updated)
    }

    func setSolar(_ value: WallpaperSolarSettings) throws {
        guard value.isValid else { throw Self.invalid() }
        guard solar != value else { return }
        defaults.set(try JSONEncoder().encode(value), forKey: Self.solarKey)
        // Keep the pre-source key in step so backups and older builds still find a location.
        if let location = value.location {
            defaults.set(try JSONEncoder().encode(location), forKey: Self.locationKey)
        } else {
            defaults.removeObject(forKey: Self.locationKey)
        }
        solar = value
        changed()
    }

    func retry(_ display: String) {
        handled[display] = nil
        errors[display] = nil
        persistHandled()
        changed()
    }

    func markHandled(_ key: String, on display: String, error: String? = nil) {
        handled[display] = key
        errors[display] = error
        persistHandled()
        statusChanged()
    }

    func setStatus(on display: String, next: WallpaperAutomationOccurrence?, focused: Bool) {
        let changed = self.next[display] != next || focusedDisplays.contains(display) != focused
        self.next[display] = next
        if focused { focusedDisplays.insert(display) } else { focusedDisplays.remove(display) }
        if changed { statusChanged() }
    }

    func rememberFocus(_ record: FocusWallpaperRestore, on display: String) throws {
        var updated = focusRestore
        updated[display] = record
        let data = try JSONEncoder().encode(updated)
        focusRestore = updated
        defaults.set(data, forKey: Self.focusRestoreKey)
        statusChanged()
    }

    func forgetFocus(on display: String) throws {
        guard focusRestore[display] != nil else { return }
        var updated = focusRestore
        updated[display] = nil
        let data = try JSONEncoder().encode(updated)
        focusRestore = updated
        defaults.set(data, forKey: Self.focusRestoreKey)
        statusChanged()
    }

    func preserveManualWallpaper(on display: String) {
        guard var record = focusRestore[display], !record.preserveWallpaper else { return }
        record.preserveWallpaper = true
        do { try rememberFocus(record, on: display) }
        catch { AppLog.error("could not save manual Focus wallpaper choice: \(error.localizedDescription)") }
    }

    func forgetWallpapers(_ ids: Set<String>) throws {
        for display in configurations.keys {
            try update(display) { value in
                value.rules.removeAll { $0.target.kind == .wallpaper && ids.contains($0.target.id) }
                if let target = value.light, target.kind == .wallpaper, ids.contains(target.id) { value.light = nil }
                if let target = value.dark, target.kind == .wallpaper, ids.contains(target.id) { value.dark = nil }
                value.spaces = value.spaces.filter { $0.value.kind != .wallpaper || !ids.contains($0.value.id) }
            }
        }
    }

    /// Deleting a saved plan detaches its active copy; that metadata-only change is not
    /// a manual replacement of the temporary Focus playlist.
    func forgetPlan(_ id: String) throws {
        var updated = focusRestore
        for display in updated.keys {
            if updated[display]?.before.playlist.planID == id { updated[display]?.before.playlist.planID = nil }
            if updated[display]?.expectedPlaylist.planID == id { updated[display]?.expectedPlaylist.planID = nil }
        }
        guard updated != focusRestore else { return }
        let data = try JSONEncoder().encode(updated)
        focusRestore = updated
        defaults.set(data, forKey: Self.focusRestoreKey)
        statusChanged()
    }

    nonisolated static func validateConfigurations(_ data: Data) throws {
        guard data.count <= 2 * 1024 * 1024 else { throw invalid() }
        let records = try JSONDecoder().decode([String: DisplayWallpaperAutomation].self, from: data)
        guard records.count <= 64, records.allSatisfy({ validDisplay($0.key) && $0.value.isValid }) else { throw invalid() }
    }

    nonisolated private static func validDisplay(_ id: String) -> Bool { !id.isEmpty && id.count <= 2048 && !id.contains("\0") }
    nonisolated private static func invalid() -> AutomationError {
        AutomationError(message: String(localized: "Choose a valid display, time, weekday and wallpaper or saved playlist."))
    }
    private func persistHandled() {
        if let data = try? JSONEncoder().encode(handled) { defaults.set(data, forKey: Self.handledKey) }
    }
    private func changed() { NotificationCenter.default.post(name: Self.didChangeNotification, object: self) }
    private func statusChanged() { NotificationCenter.default.post(name: Self.statusChangedNotification, object: self) }
}
