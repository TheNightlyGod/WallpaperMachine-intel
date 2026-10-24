import CoreFoundation
import Foundation

struct WallpaperBackupFailure: LocalizedError, Equatable, Sendable {
    let message: String
    var errorDescription: String? { message }
}

enum WallpaperBackupConflictPolicy: String, Codable, Sendable {
    case keepExisting, replace
}

struct WallpaperBackupLimits: Sendable {
    private static let entryLimit = 100_000
    private static let pathByteLimit = 1_024
    private static let preferenceByteLimit = WallpaperPresetStore.maximumDocumentBytes + 16 * 1_024 * 1_024
    var maximumEntries = Self.entryLimit
    var maximumBytes: Int64 = 64 * 1_024 * 1_024 * 1_024
    var maximumFileBytes: Int64 = 32 * 1_024 * 1_024 * 1_024
    // Budget JSON path escaping, entry fields/digests, base64 preferences and the header.
    var maximumManifestBytes = Self.entryLimit * (6 * Self.pathByteLimit + 256)
        + ((Self.preferenceByteLimit + 2) / 3) * 4 + 16 * 1_024
    var maximumPreferenceBytes = Self.preferenceByteLimit
    var maximumMetadataBytes = 16 * 1_024 * 1_024
    var maximumPathBytes = Self.pathByteLimit
    var maximumDepth = 32
}

struct WallpaperBackupEntry: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case file, directory }
    var path: String
    var kind: Kind
    var size: Int64
    var digest: String?
}

struct WallpaperBackupManifest: Codable, Sendable {
    static let version = 1
    var version = Self.version
    var createdAt: Date
    var sourceSupportRoot: String
    var sourceSupportAliases: [String]?
    var includesLibrary: Bool
    /// Each value is an independently encoded property list, preserving Data vs dictionaries.
    var preferences: [String: Data]
    var entries: [WallpaperBackupEntry]
    var referenceRoots: [String] {
        Array(Set([sourceSupportRoot] + (sourceSupportAliases ?? []))).sorted { $0.count > $1.count }
    }
}

struct WallpaperBackupPreview: Sendable {
    var name: String
    var createdAt: Date
    var wallpaperCount: Int
    var presetCount: Int
    var collectionCount: Int
    var includesLibrary: Bool
    var byteCount: Int64
    var conflicts: [String]
    var warnings: [String]
    /// Binds confirmation to the package the user actually reviewed.
    var manifestDigest: String
}

struct WallpaperBackupRestoreReport: Sendable {
    var restoredPaths: [String]
    var warnings: [String]
    var recoveredInterruptedRestore: Bool = false
}

struct WallpaperBackupPending: Codable, Sendable {
    var version = 1
    var policy: WallpaperBackupConflictPolicy
    var manifestDigest: String
}

struct WallpaperBackupJournal: Codable, Sendable {
    struct Unit: Codable, Sendable {
        var path: String
        var existed: Bool
    }
    var version = 1
    var units: [Unit]
    var originalPreferences: [String: Data]
    var absentPreferences: [String]
    var preferencesCommitted = false
    /// The folder holding the live `Library` units and their own `old/` and `ready/`, when the
    /// library is not in the support root (`StorageLocation`); nil for the support root.
    var libraryRoot: String?
    /// That folder's `StorageLocation` marker, so recovery never takes an empty mount point left
    /// by a disconnected drive for it.
    var libraryMarker: String?
}

/// Deliberately enumerated. Cookies, login/session state, SteamCMD paths, update history,
/// diagnostics and caches must never enter a backup through a broad defaults prefix.
struct WallpaperBackupPreferences: Sendable {
    /// Local transaction recovery may restore these, but backup packages may never supply them.
    static let localRecoveryKeys: Set<String> = ["WallpaperMachine.automaticWallpaperHandled", "WallpaperMachine.focusWallpaperRestore", "WallpaperMachine.spaceVisits"]
    static let allowedKeys: Set<String> = [
        "WallpaperMachine.collections", "WallpaperMachine.playlistPlans",
        "WallpaperMachine.wallpaperPresets", "WallpaperMachine.imagePlacements",
        "WallpaperMachine.playlists", "WallpaperMachine.playlistNextChange",
        "WallpaperMachine.automaticWallpapers", "WallpaperMachine.solarLocation",
        "WallpaperMachine.solarSettings",
        "WallpaperMachine.displayLayouts",
        "WallpaperMachine.favoriteWallpaperIDs", "WallpaperMachine.appTheme",
        "WallpaperMachine.appLanguage", "AppleLanguages", "WallpaperMachine.hotKeys",
        "WallpaperMachine.displaySleepAction", "WallpaperMachine.otherAudioAction",
        "WallpaperMachine.desktopCoveredAction", "WallpaperMachine.appRules",
        "WallpaperMachine.lowPowerModeAction", "WallpaperMachine.thermalAction",
        "WallpaperMachine.lowBatteryAction", "WallpaperMachine.lowBatteryThreshold",
        "WallpaperMachine.playOnlyOnActiveDisplay",
        "WallpaperMachine.hideAfterActivating", "WallpaperMachine.concurrentDownloads",
        "WallpaperMachine.workshopUpdateChecks", "WallpaperMachineAssetsPath",
        // No longer read since filters became a popover; still accepted so that backups made
        // by earlier versions, which carry them, keep restoring.
        "WallpaperMachine.workshopFiltersCollapsed", "WallpaperMachine.installedFiltersCollapsed",
        "WallpaperMachine.pixivFiltersCollapsed",
    ]
    var values: [String: Data]

    /// Pass the suite name when injecting suite-based defaults.
    @MainActor
    init(defaults: UserDefaults, domainName: String = ClientPreferences.domainName) throws {
        values = [:]
        let persistent = defaults.persistentDomain(forName: domainName) ?? [:]
        for key in Self.allowedKeys.sorted() {
            if let value = persistent[key] {
                values[key] = try Self.encode(value)
            }
        }
    }

    init(values: [String: Data]) { self.values = values }

    static func encode(_ value: Any) throws -> Data {
        // A wrapper permits scalar preferences as well as collections.
        try PropertyListSerialization.data(fromPropertyList: ["value": value], format: .binary, options: 0)
    }

    static func decode(_ data: Data) throws -> Any {
        guard let wrapper = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
            as? [String: Any], wrapper.count == 1, let value = wrapper["value"] else {
            throw WallpaperBackupFailure(message: String(localized: "The backup contains an invalid preference value."))
        }
        return value
    }

    /// Validate at the restore boundary, rather than letting stores silently hydrate defaults.
    static func validate(_ value: Any, forKey key: String) throws {
        func invalid() -> WallpaperBackupFailure {
            .init(message: String(localized: "The backup contains an invalid preference value."))
        }
        func data() throws -> Data {
            guard let data = value as? Data else { throw invalid() }
            return data
        }
        func identities(_ ids: [String]) throws {
            guard Set(ids).count == ids.count, ids.allSatisfy({ !$0.isEmpty && !$0.contains("\0") && $0.utf8.count <= 1024 }) else { throw invalid() }
        }
        func name(_ text: String) throws {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 128,
                  !text.contains(where: { $0.isNewline || $0 == "\0" }) else { throw invalid() }
        }
        func playlists(_ json: Any) throws {
            guard let records = json as? [String: Any] else { throw invalid() }
            for (display, record) in records {
                try identities([display])
                guard let record = record as? [String: Any] else { throw invalid() }
                let allowed: Set<String> = ["mode", "source", "order", "trigger", "interval", "wallpaperIDs", "collectionID", "planID", "dayWallpaperID", "nightWallpaperID", "dayStart", "nightStart"]
                guard Set(record.keys).isSubset(of: allowed) else { throw invalid() }
                for (key, item) in record {
                    switch key {
                    case "mode": guard let raw = item as? String, PlaylistMode(rawValue: raw) != nil else { throw invalid() }
                    case "source": guard let raw = item as? String, PlaylistSource(rawValue: raw) != nil else { throw invalid() }
                    case "order": guard let raw = item as? String, PlaylistOrder(rawValue: raw) != nil else { throw invalid() }
                    case "trigger": guard let raw = item as? String, PlaylistTrigger(rawValue: raw) != nil else { throw invalid() }
                    case "interval", "dayStart", "nightStart":
                        guard let number = item as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                              number.doubleValue == Double(number.intValue),
                              (key == "interval" ? DisplayPlaylist.intervalRange.contains(number.intValue) : DisplayPlaylist.minuteOfDay(number.intValue) != nil) else { throw invalid() }
                    case "wallpaperIDs": guard let ids = item as? [String] else { throw invalid() }; try identities(ids)
                    default:
                        if item is NSNull { continue }
                        guard let id = item as? String else { throw invalid() }; try identities([id])
                    }
                }
            }
        }
        switch key {
        case "WallpaperMachine.automaticWallpapers": try WallpaperAutomationStore.validateConfigurations(data())
        case "WallpaperMachine.displayLayouts": _ = try WallpaperDisplayLayoutStore.decode(data())
        case "WallpaperMachine.solarLocation":
            let location = try JSONDecoder().decode(WallpaperSolarLocation.self, from: data())
            guard location.isValid else { throw invalid() }
        case "WallpaperMachine.solarSettings":
            let solar = try JSONDecoder().decode(WallpaperSolarSettings.self, from: data())
            guard solar.isValid else { throw invalid() }
        case "WallpaperMachine.wallpaperPresets": try WallpaperPresetStore.validateArchiveData(data())
        case "WallpaperMachine.collections":
            let records = try JSONDecoder().decode([WallpaperCollection].self, from: data())
            try identities(records.map(\.id))
            for record in records { try name(record.name); try identities(record.wallpaperIDs) }
        case "WallpaperMachine.playlistPlans":
            let bytes = try data()
            let records = try JSONDecoder().decode([PlaylistPlan].self, from: bytes)
            try identities(records.map(\.id))
            guard let raw = try JSONSerialization.jsonObject(with: bytes) as? [[String: Any]] else { throw invalid() }
            for (index, record) in records.enumerated() {
                try name(record.name)
                try playlists([record.id: raw[index]["playlist"] as Any])
            }
        case "WallpaperMachine.playlists":
            let bytes = try data()
            _ = try JSONDecoder().decode([String: DisplayPlaylist].self, from: bytes)
            try playlists(JSONSerialization.jsonObject(with: bytes))
        case "WallpaperMachine.imagePlacements":
            let record = try JSONDecoder().decode(WallpaperBackupPlacementArchive.self, from: data())
            guard record.version == 1 else { throw invalid() }
            try identities(Array(record.placements.keys))
            for displays in record.placements.values { try identities(Array(displays.keys)) }
        case "WallpaperMachine.favoriteWallpaperIDs": try identities(JSONDecoder().decode([String].self, from: data()))
        case "WallpaperMachine.hotKeys":
            let bindings = try JSONDecoder().decode([String: HotKey].self, from: data())
            guard bindings.keys.allSatisfy({ HotKeyAction(rawValue: $0) != nil }) else { throw invalid() }
            for binding in bindings.values {
                guard binding.keyCode <= 127, binding.label.count <= 128, !binding.label.contains("\0") else { throw invalid() }
            }
        case "WallpaperMachine.appRules":
            let rules = try JSONDecoder().decode([AppRule].self, from: data())
            try identities(rules.map { $0.id.uuidString })
            for rule in rules { try identities([rule.bundleIdentifier]); guard !rule.name.contains("\0") else { throw invalid() } }
        case "WallpaperMachine.playlistNextChange":
            guard let records = value as? [String: Any] else { throw invalid() }
            try identities(Array(records.keys))
            for item in records.values {
                guard let number = item as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { throw invalid() }
            }
        case "WallpaperMachine.appTheme":
            guard let record = value as? [String: String], Set(record.keys).isSubset(of: ["mode", "accent", "tone", "icon"]) else { throw invalid() }
            for (key, item) in record {
                switch key {
                case "mode": guard AppThemePreferences.Mode(rawValue: item) != nil else { throw invalid() }
                case "tone": guard AppThemePreferences.Tone(rawValue: item) != nil else { throw invalid() }
                case "icon": guard AppThemePreferences.Icon(rawValue: item) != nil else { throw invalid() }
                default: guard AppThemePreferences.validAccent(item) else { throw invalid() }
                }
            }
        case "WallpaperMachine.appLanguage": guard let raw = value as? String, raw == "system" || AppLanguage.named(raw) != nil else { throw invalid() }
        case "AppleLanguages": guard let values = value as? [String], values.count <= 32, values.allSatisfy({ !$0.isEmpty && !$0.contains("\0") && $0.count <= 128 }) else { throw invalid() }
        case "WallpaperMachine.displaySleepAction": guard let raw = value as? String, DisplaySleepAction(rawValue: raw) != nil else { throw invalid() }
        case "WallpaperMachine.otherAudioAction": guard let raw = value as? String, OtherAudioAction(rawValue: raw) != nil else { throw invalid() }
        case "WallpaperMachine.desktopCoveredAction": guard let raw = value as? String, DesktopCoveredAction(rawValue: raw) != nil else { throw invalid() }
        case "WallpaperMachine.lowPowerModeAction", "WallpaperMachine.thermalAction", "WallpaperMachine.lowBatteryAction":
            guard let raw = value as? String, SystemConditionAction(rawValue: raw) != nil else { throw invalid() }
        case "WallpaperMachine.lowBatteryThreshold":
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue == Double(number.intValue),
                  PlaybackPreferences.lowBatteryThresholds.contains(number.intValue) else { throw invalid() }
        case "WallpaperMachine.concurrentDownloads":
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue == Double(number.intValue),
                  WorkshopDownloadManager.concurrentDownloadRange.contains(number.intValue) else { throw invalid() }
        case "WallpaperMachineAssetsPath": guard let path = value as? String, !path.contains("\0"), path.utf8.count <= 1024 else { throw invalid() }
        default: guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw invalid() }
        }
    }

}

private struct WallpaperBackupPlacementArchive: Decodable {
    var version: Int
    var placements: [String: [String: StillImagePlacement]]
}
