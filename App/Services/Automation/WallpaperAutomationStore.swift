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
    nonisolated static let configurationsKey = "WallpaperMachine.automaticWallpapers"
    nonisolated static let locationKey = "WallpaperMachine.solarLocation"
    nonisolated static let solarKey = "WallpaperMachine.solarSettings"
    nonisolated static let handledKey = "WallpaperMachine.automaticWallpaperHandled"
    nonisolated static let focusRestoreKey = "WallpaperMachine.focusWallpaperRestore"
    static let didChangeNotification = Notification.Name("WallpaperMachine.automationSettingsChanged")
    static let statusChangedNotification = Notification.Name("WallpaperMachine.automationStatusChanged")
    private let defaults: UserDefaults
    private(set) var configurations: [String: DisplayWallpaperAutomation]
    private(set) var solar: WallpaperSolarSettings
    /// The coordinates the sunset and sunrise rules plan with, whatever their source.
    var location: WallpaperSolarLocation? { solar.location }
    private(set) var handled: [String: String]
    private(set) var focusRestore: [String: FocusWallpaperRestore]
    /// Displays whose saved rules, or Focus recovery record, this build could not read (a newer
    /// build's, or damaged), as they were saved. Every save writes them back unchanged, so
    /// editing one display never erases another's; giving such a display new rules replaces it.
    private var unreadConfigurations: [String: Data] = [:]
    private var unreadFocusRestore: [String: Data] = [:]
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
        // One display's record this build cannot read must not take the other displays' with it.
        func readKeyed<T: Decodable>(_ key: String, _ type: T.Type, accepts: (String, T) -> Bool)
            -> (values: [String: T], unread: [String: Data]) {
            guard let data = defaults.data(forKey: key) else { return ([:], [:]) }
            guard data.count <= 2 * 1024 * 1024,
                  let stored = PreservedJSON.readObject(data, as: type, accepts: accepts),
                  stored.values.count + stored.unread.count <= Self.displayLimit else {
                failed = true
                return ([:], [:])
            }
            if !stored.unread.isEmpty { failed = true }
            return stored
        }
        let stored = readKeyed(Self.configurationsKey, DisplayWallpaperAutomation.self) {
            Self.validDisplay($0) && $1.isValid
        }
        configurations = stored.values
        unreadConfigurations = stored.unread
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
        let restores = readKeyed(Self.focusRestoreKey, FocusWallpaperRestore.self) {
            Self.validDisplay($0) && $1.key.count <= 4096
        }
        focusRestore = restores.values
        unreadFocusRestore = restores.unread
        if failed {
            loadError = String(localized: "Some automatic wallpaper settings could not be read. Check your rules and Focus choices before using them.")
            AppLog.warn("automatic wallpaper preferences could not be fully decoded")
        }
    }

    func configuration(for display: String) -> DisplayWallpaperAutomation { configurations[display] ?? .init() }

    func update(_ display: String, _ change: (inout DisplayWallpaperAutomation) throws -> Void) throws {
        // A display whose record could not be read still holds one of the places.
        let held = configurations.count + unreadConfigurations.count
        guard Self.validDisplay(display),
              configurations[display] != nil || unreadConfigurations[display] != nil || held < Self.displayLimit
        else { throw Self.invalid() }
        let before = configuration(for: display)
        var value = before
        try change(&value)
        guard value.isValid else { throw Self.invalid() }
        guard value != before else { return }
        value.revision = before.revision &+ 1
        var updated = configurations
        updated[display] = value
        let data = try PreservedJSON.writeObject(updated, keeping: unreadConfigurations)
        configurations = updated
        // The display has rules this build wrote now; what it could not read there is replaced.
        unreadConfigurations[display] = nil
        defaults.set(data, forKey: Self.configurationsKey)
        // The warning stands while a display's rules are still set aside unread.
        if unreadConfigurations.isEmpty && unreadFocusRestore.isEmpty { loadError = nil }
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
        let data = try PreservedJSON.writeObject(updated, keeping: unreadFocusRestore)
        focusRestore = updated
        unreadFocusRestore[display] = nil
        defaults.set(data, forKey: Self.focusRestoreKey)
        statusChanged()
    }

    func forgetFocus(on display: String) throws {
        guard focusRestore[display] != nil else { return }
        var updated = focusRestore
        updated[display] = nil
        let data = try PreservedJSON.writeObject(updated, keeping: unreadFocusRestore)
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
        let data = try PreservedJSON.writeObject(updated, keeping: unreadFocusRestore)
        focusRestore = updated
        defaults.set(data, forKey: Self.focusRestoreKey)
        statusChanged()
    }

    nonisolated static func validateConfigurations(_ data: Data) throws {
        guard data.count <= 2 * 1024 * 1024 else { throw invalid() }
        let records = try JSONDecoder().decode([String: DisplayWallpaperAutomation].self, from: data)
        guard records.count <= displayLimit, records.allSatisfy({ validDisplay($0.key) && $0.value.isValid }) else { throw invalid() }
    }

    /// The most displays the store keeps rules for, the unread ones among them.
    nonisolated private static let displayLimit = 64
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
