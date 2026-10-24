import Foundation

struct WallpaperBackupService: Sendable {
    static let packageTypeIdentifier = "app.wallpapermachine.backup"
    static let packageExtension = "wmbackup"
    static let pendingDirectoryName = ".PendingBackupRestore"
    static let transactionDirectoryName = ".BackupRestoreTransaction"
    let supportRoot: URL
    /// The folder holding `Library`: the support root unless the library was moved
    /// (`StorageLocation`). Every logical `Library/…` path lives here.
    let storageRoot: URL
    let limits: WallpaperBackupLimits
    private let referenceRoot: String
    private var manager: FileManager { .default }
    private var files: WallpaperBackupFiles { .init(limits: limits) }
    private let managedRoots = ["config.toml", "wallpapers", "Library", "UserAssets"]
    private static let solarLocationKey = "WallpaperMachine.solarLocation"
    private static let solarSettingsKey = "WallpaperMachine.solarSettings"
    private static let solarKeys: Set<String> = [solarLocationKey, solarSettingsKey]

    /// `storageRoot` nil keeps the library in `supportRoot`; the app passes `ClientPaths.storageURL`.
    init(supportRoot: URL = ClientPaths.supportURL, storageRoot: URL? = nil, limits: WallpaperBackupLimits = .init()) {
        self.supportRoot = supportRoot.standardizedFileURL.resolvingSymlinksInPath()
        self.storageRoot = (storageRoot ?? supportRoot).standardizedFileURL.resolvingSymlinksInPath()
        referenceRoot = supportRoot.standardizedFileURL.path
        self.limits = limits
    }

    /// Where a logical path of the package lives on this Mac.
    private func liveRoot(_ logical: String) -> URL {
        logical == "Library" || logical.hasPrefix("Library/") ? storageRoot : supportRoot
    }

    private func live(_ logical: String) -> URL { liveRoot(logical).appendingPathComponent(logical) }

    private static func isLibrary(_ logical: String) -> Bool { logical == "Library" || logical.hasPrefix("Library/") }

    /// Where a restore keeps a unit's `old/` and `ready/`: on the volume of the unit's live copy, so
    /// publishing it and putting it back are renames. A library on another disk has its own
    /// transaction folder there, which the journal names (`libraryRoot`).
    private func unitTransaction(_ logical: String, transaction: URL, libraryRoot: URL) -> URL {
        Self.isLibrary(logical) && libraryRoot.path != supportRoot.path
            ? libraryRoot.appendingPathComponent(Self.transactionDirectoryName, isDirectory: true) : transaction
    }

    /// The library's transaction folder, when it is not the support root's.
    private func libraryTransaction(libraryRoot: URL, transaction: URL) -> URL? {
        libraryRoot.path == supportRoot.path ? nil : unitTransaction("Library", transaction: transaction, libraryRoot: libraryRoot)
    }

    var pendingRestore: Bool {
        manager.fileExists(atPath: supportRoot.appendingPathComponent(Self.pendingDirectoryName).path)
    }

    var lastStartupError: String? {
        guard let data = try? files.readMetadata(root: supportRoot, path: ".BackupRestoreFailure.json", maximum: limits.maximumManifestBytes) else { return nil }
        return try? JSONDecoder().decode(String.self, from: data)
    }

    func export(to package: URL, includeLibrary: Bool, preferences: WallpaperBackupPreferences) throws {
        try Task.checkCancellation()
        let destination = package.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
            .appendingPathComponent(package.lastPathComponent)
        guard destination.pathExtension.lowercased() == Self.packageExtension,
              !contains(destination, in: supportRoot), !contains(destination, in: storageRoot) else {
            throw WallpaperBackupFailure(message: String(localized: "Save the backup outside WallpaperMachine’s support folder with the .wmbackup extension."))
        }
        try validatePreferences(preferences.values)
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".wmbackup-export-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: temporary) }
        let payload = temporary.appendingPathComponent("data")
        try manager.createDirectory(at: payload, withIntermediateDirectories: true)
        var entries: [WallpaperBackupEntry] = []
        for name in managedRoots where name != "Library" || includeLibrary {
            let source = live(name)
            guard manager.fileExists(atPath: source.path) else { continue }
            let (kind, size) = try files.kind(at: source)
            guard (name == "config.toml" && kind == .file) || (name != "config.toml" && kind == .directory) else {
                throw files.unsafe(name)
            }
            entries.append(.init(path: name, kind: kind, size: size))
            if kind == .directory {
                entries += try files.scan(source).map {
                    .init(path: name + "/" + $0.path, kind: $0.kind, size: $0.size)
                }
            }
        }
        try validateEntries(entries, includesLibrary: includeLibrary)
        // A moved library's own paths (`<storage>/Library/…`) are named through its root.
        let aliases = Array(Set([referenceRoot, storageRoot.path]).subtracting([supportRoot.path])).sorted()
        var manifest = WallpaperBackupManifest(createdAt: Date(), sourceSupportRoot: supportRoot.path,
                                               sourceSupportAliases: aliases.isEmpty ? nil : aliases,
                                               includesLibrary: includeLibrary, preferences: preferences.values,
                                               entries: entries.sorted { $0.path < $1.path })
        // Hex digests have a fixed encoded size. Check the complete manifest before
        // reading payload bytes, including escaped paths and base64 preferences.
        for index in manifest.entries.indices where manifest.entries[index].kind == .file {
            manifest.entries[index].digest = String(repeating: "0", count: 64)
        }
        _ = try encodedManifest(manifest)
        for index in manifest.entries.indices {
            var entry = manifest.entries[index]
            entry.digest = nil
            let target = payload.appendingPathComponent(entry.path)
            if entry.kind == .directory {
                try manager.createDirectory(at: target, withIntermediateDirectories: true)
            } else {
                manifest.entries[index].digest = try files.stream(root: liveRoot(entry.path), entry: entry, to: target, rejectHardLinks: false)
            }
        }
        try writeManifest(manifest, at: temporary)
        try Task.checkCancellation()
        try publishPackage(temporary, to: destination)
    }

    func preview(package: URL, preferences: WallpaperBackupPreferences) throws -> WallpaperBackupPreview {
        let (manifest, digest) = try validatedPackage(package)
        try validateReferences(manifest: manifest, package: package)
        var conflicts = try resourceUnits(manifest.entries).filter {
            manager.fileExists(atPath: live($0).path)
        }
        conflicts += manifest.preferences.keys.filter {
            !Self.solarKeys.contains($0) && preferences.values[$0] != nil
        }.map { "Preferences/" + $0 }
        if !Self.solarKeys.isDisjoint(with: manifest.preferences.keys),
           !Self.solarKeys.isDisjoint(with: preferences.values.keys) {
            conflicts.append("Preferences/" + Self.solarSettingsKey)
        }
        let warnings = try diagnose(manifest: manifest, package: package)
        return WallpaperBackupPreview(name: package.lastPathComponent, createdAt: manifest.createdAt,
            wallpaperCount: wallpaperIDs(manifest.entries).count,
            presetCount: try recordCount(manifest.preferences["WallpaperMachine.wallpaperPresets"], field: "items"),
            collectionCount: try recordCount(manifest.preferences["WallpaperMachine.collections"], field: nil),
            includesLibrary: manifest.includesLibrary,
            byteCount: manifest.entries.reduce(0) { $0 + $1.size }, conflicts: conflicts.sorted(),
            warnings: warnings, manifestDigest: digest)
    }

    /// Revalidates every byte and builds the complete pending package before replacing
    /// a previous pending restore. Running settings and wallpapers are never touched.
    func stageRestore(package: URL, preview: WallpaperBackupPreview, policy: WallpaperBackupConflictPolicy) throws {
        let (manifest, digest) = try validatedPackage(package)
        guard digest == preview.manifestDigest else { throw files.changed() }
        try validateReferences(manifest: manifest, package: package)
        try manager.createDirectory(at: supportRoot, withIntermediateDirectories: true)
        let staging = supportRoot.appendingPathComponent(".BackupStage-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: staging) }
        let payload = staging.appendingPathComponent("data")
        try manager.createDirectory(at: payload, withIntermediateDirectories: true)
        for entry in manifest.entries {
            let target = payload.appendingPathComponent(entry.path)
            if entry.kind == .directory {
                try manager.createDirectory(at: target, withIntermediateDirectories: true)
            } else {
                try files.stream(root: package.appendingPathComponent("data"), entry: entry, to: target)
            }
        }
        // Retained bytes remain independent of the picker URL after confirmation.
        let stagedDigest = try writeManifest(manifest, at: staging)
        try writeJSON(WallpaperBackupPending(policy: policy, manifestDigest: stagedDigest),
                      to: staging.appendingPathComponent("pending.json"))
        try Task.checkCancellation()
        try publishPackage(staging, to: supportRoot.appendingPathComponent(Self.pendingDirectoryName))
        let failure = supportRoot.appendingPathComponent(".BackupRestoreFailure.json")
        if manager.fileExists(atPath: failure.path) { try manager.removeItem(at: failure) }
    }

    func cancelPendingRestore() throws {
        let pending = supportRoot.appendingPathComponent(Self.pendingDirectoryName)
        if manager.fileExists(atPath: pending.path) { try manager.removeItem(at: pending) }
        let failure = supportRoot.appendingPathComponent(".BackupRestoreFailure.json")
        if manager.fileExists(atPath: failure.path) { try manager.removeItem(at: failure) }
    }

    /// The app calls this before initializing any preferences, Library or renderer.
    /// It is synchronous because those consumers must not race startup publication.
    @MainActor
    static func applyPendingRestore(supportRoot: URL = ClientPaths.supportURL, storageRoot: URL? = nil,
                                    defaults: UserDefaults = ClientPreferences.defaults,
                                    domainName: String = ClientPreferences.domainName) throws -> WallpaperBackupRestoreReport? {
        let service = WallpaperBackupService(supportRoot: supportRoot, storageRoot: storageRoot)
        do {
            return try service.applyPendingRestore(defaults: defaults, domainName: domainName)
        } catch {
            // The next panel can explain a failed startup without opening a window.
            try? service.manager.createDirectory(at: service.supportRoot, withIntermediateDirectories: true)
            try? service.writeJSON(error.localizedDescription, to: service.supportRoot.appendingPathComponent(".BackupRestoreFailure.json"))
            throw error
        }
    }

    @MainActor
    func applyPendingRestore(defaults: UserDefaults,
                             domainName: String = ClientPreferences.domainName,
                             beforePublish: ((String) throws -> Void)? = nil) throws -> WallpaperBackupRestoreReport? {
        let transaction = supportRoot.appendingPathComponent(Self.transactionDirectoryName)
        var recovered = false
        if manager.fileExists(atPath: transaction.path) {
            try recover(transaction: transaction, defaults: defaults)
            recovered = true
        }
        let libraryTransaction = libraryTransaction(libraryRoot: storageRoot, transaction: transaction)
        // Without the support root's transaction, one beside the library holds only prepared
        // copies or what a committed restore replaced: it is cleared after the journal's own.
        if let libraryTransaction, manager.fileExists(atPath: libraryTransaction.path) {
            try manager.removeItem(at: libraryTransaction)
        }
        let pending = supportRoot.appendingPathComponent(Self.pendingDirectoryName)
        guard pendingRestore, lastStartupError == nil else {
            return recovered ? .init(restoredPaths: [], warnings: [], recoveredInterruptedRestore: true) : nil
        }
        let (manifest, digest) = try validatedPackage(pending, isPending: true)
        let pendingState = try readJSON(WallpaperBackupPending.self, at: pending, name: "pending.json")
        guard pendingState.version == 1, digest == pendingState.manifestDigest else { throw files.changed() }
        let current = try WallpaperBackupPreferences(defaults: defaults, domainName: domainName)
        try validateReferences(manifest: manifest, package: pending)
        let selected = try resourceUnits(manifest.entries).filter {
            pendingState.policy == .replace || !manager.fileExists(atPath: live($0).path)
        }
        let context = referenceContext(manifest: manifest, package: pending, selected: Set(selected))
        // A restored project must not turn an existing text override into a newly
        // authorized file selection. The preserved config cannot be rewritten.
        for path in selected where path.hasPrefix("Library/") {
            let id = String(path.dropFirst("Library/".count))
            let configPath = "wallpapers/\(id).json"
            if !selected.contains(configPath), manager.fileExists(atPath: supportRoot.appendingPathComponent(configPath).path) {
                let original = try readObject(root: supportRoot, path: configPath)
                let rewritten = try rewrittenMetadata(original, logicalPath: configPath, context: context)
                let oldOverrides = original["property_overrides"] as? [String: Any] ?? [:]
                let newOverrides = rewritten["property_overrides"] as? [String: Any] ?? [:]
                guard NSDictionary(dictionary: oldOverrides).isEqual(to: newOverrides) else { throw files.unsafe(configPath) }
            }
        }
        let warnings = try diagnose(manifest: manifest, package: pending)
        let prepared = transaction.appendingPathComponent("ready")
        try manager.createDirectory(at: prepared, withIntermediateDirectories: true)
        func ready(_ path: String) -> URL {
            unitTransaction(path, transaction: transaction, libraryRoot: storageRoot).appendingPathComponent("ready/" + path)
        }
        // A failure before the journal is published has not touched live data.
        do {
            for path in selected {
                let source = pending.appendingPathComponent("data/" + path)
                let target = ready(path)
                try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                let (kind, size) = try files.kind(at: source, rejectHardLinks: true)
                if kind == .directory {
                    try files.copyTree(from: source, to: target, rejectingHardLinks: true)
                } else {
                    let entry = WallpaperBackupEntry(path: path, kind: .file, size: size)
                    try files.stream(root: pending.appendingPathComponent("data"), entry: entry, to: target)
                }
                try remapMetadata(in: target, logicalPath: path, context: context)
            }
            let nextPreferences = try mergedPreferences(manifest.preferences, existing: current.values,
                policy: pendingState.policy, context: context)
            try validatePreferences(nextPreferences.values)
            try validateRendererConfiguration(root: prepared, entries: manifest.entries.filter { entry in
                selected.contains(where: { entry.path == $0 || entry.path.hasPrefix($0 + "/") })
            })
            let resetsAutomation = nextPreferences.values["WallpaperMachine.automaticWallpapers"] != nil
                || nextPreferences.values["WallpaperMachine.playlists"] != nil
                || selected.contains(where: { $0 == "config.toml" || $0.hasPrefix("wallpapers/") })
            let transientKeys = resetsAutomation ? WallpaperBackupPreferences.localRecoveryKeys : []
            let removedKeys = nextPreferences.removedKeys.union(transientKeys)
            let changedKeys = Set(nextPreferences.values.keys).union(removedKeys).sorted()
            var previousValues = current.values
            let domain = defaults.persistentDomain(forName: domainName) ?? [:]
            for key in transientKeys {
                if let value = domain[key] { previousValues[key] = try WallpaperBackupPreferences.encode(value) }
            }
            var journal = WallpaperBackupJournal(units: selected.map {
                .init(path: $0, existed: manager.fileExists(atPath: live($0).path))
            }, originalPreferences: previousValues.filter { changedKeys.contains($0.key) },
                absentPreferences: changedKeys.filter { previousValues[$0] == nil },
                libraryRoot: libraryTransaction == nil ? nil : storageRoot.path,
                libraryMarker: libraryTransaction == nil ? nil : StorageLocation.marker(at: storageRoot))
            try writeJSON(journal, to: transaction.appendingPathComponent("journal.json"))
            do {
                for unit in journal.units {
                    try beforePublish?(unit.path)
                    let live = live(unit.path)
                    let old = unitTransaction(unit.path, transaction: transaction, libraryRoot: storageRoot)
                        .appendingPathComponent("old/" + unit.path)
                    try ensureSafeParents(of: unit.path, root: liveRoot(unit.path))
                    if unit.existed {
                        try manager.createDirectory(at: old.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try manager.moveItem(at: live, to: old)
                    }
                    try manager.createDirectory(at: live.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try manager.moveItem(at: ready(unit.path), to: live)
                }
                // Preferences are last, after every referenced file is safely in place.
                try beforePublish?("Preferences")
                for (key, data) in nextPreferences.values { defaults.set(try WallpaperBackupPreferences.decode(data), forKey: key) }
                for key in removedKeys { defaults.removeObject(forKey: key) }
                guard defaults.synchronize() else {
                    throw WallpaperBackupFailure(message: String(localized: "Restored preferences could not be saved. The previous state has been retained."))
                }
                journal.preferencesCommitted = true
                try writeJSON(journal, to: transaction.appendingPathComponent("journal.json"))
            } catch {
                try recover(transaction: transaction, defaults: defaults)
                throw error
            }
            // A committed journal is a durable completion marker; recovery only cleans it.
            try finishCommitted(transaction: transaction, libraryTransaction: libraryTransaction)
            return .init(restoredPaths: selected, warnings: warnings, recoveredInterruptedRestore: recovered)
        } catch {
            if !manager.fileExists(atPath: transaction.appendingPathComponent("journal.json").path) {
                if let libraryTransaction { try? manager.removeItem(at: libraryTransaction) }
                try? manager.removeItem(at: transaction)
            }
            throw error
        }
    }

    private func validatedPackage(_ package: URL, isPending: Bool = false) throws -> (WallpaperBackupManifest, String) {
        guard try files.kind(at: package).0 == .directory else { throw files.unsafe(package.lastPathComponent) }
        var topLevel = Set<String>()
        var enumerationError: Error?
        guard let enumerator = manager.enumerator(at: package, includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants], errorHandler: { _, error in enumerationError = error; return false }) else {
            throw files.unsafe(package.lastPathComponent)
        }
        for case let url as URL in enumerator {
            guard topLevel.count < 3 else { throw files.unsafe(url.lastPathComponent) }
            topLevel.insert(url.lastPathComponent)
        }
        if let enumerationError { throw enumerationError }
        guard topLevel == Set(isPending ? ["manifest.json", "data", "pending.json"] : ["manifest.json", "data"]) else {
            throw files.unsafe(package.lastPathComponent)
        }
        let data = try files.readMetadata(root: package, path: "manifest.json", maximum: limits.maximumManifestBytes)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest: WallpaperBackupManifest
        do { manifest = try decoder.decode(WallpaperBackupManifest.self, from: data) }
        catch { throw WallpaperBackupFailure(message: String(localized: "This is not a supported WallpaperMachine backup manifest.")) }
        guard manifest.version == WallpaperBackupManifest.version,
              manifest.createdAt.timeIntervalSince1970.isFinite,
              (manifest.sourceSupportAliases?.count ?? 0) <= 3,
              manifest.referenceRoots.allSatisfy({ $0.hasPrefix("/") && $0 != "/" && !$0.contains("\0")
                && $0.utf8.count <= limits.maximumPathBytes && ($0 as NSString).standardizingPath == $0 }) else {
            throw WallpaperBackupFailure(message: String(localized: "This backup version or source path is not supported."))
        }
        try validatePreferences(manifest.preferences)
        try validateEntries(manifest.entries, includesLibrary: manifest.includesLibrary, requireDigests: true)
        let payload = package.appendingPathComponent("data")
        let actual = try files.scan(payload, rejectingHardLinks: true)
        let expected = Dictionary(uniqueKeysWithValues: manifest.entries.map { ($0.path, $0) })
        guard actual.count == expected.count,
              actual.allSatisfy({ expected[$0.path]?.kind == $0.kind && expected[$0.path]?.size == $0.size }) else {
            throw files.changed()
        }
        for entry in manifest.entries where entry.kind == .file { try files.stream(root: payload, entry: entry) }
        try validateRendererConfiguration(root: payload, entries: manifest.entries)
        return (manifest, WallpaperBackupFiles.digest(data))
    }

    private func validateEntries(_ entries: [WallpaperBackupEntry], includesLibrary: Bool,
                                 requireDigests: Bool = false) throws {
        guard entries.count <= limits.maximumEntries else { throw files.oversized() }
        var seen = Set<String>()
        var directoryPaths = Set<String>()
        var bytes: Int64 = 0
        for entry in entries.sorted(by: { $0.path < $1.path }) {
            try files.validateRelative(entry.path)
            // Case-folding and NFC disallow aliases when a package crosses filesystems.
            let canonical = entry.path.precomposedStringWithCanonicalMapping.lowercased()
            guard seen.insert(canonical).inserted, entry.size >= 0,
                  entry.size <= limits.maximumFileBytes, entry.size <= limits.maximumBytes - bytes else { throw files.unsafe(entry.path) }
            bytes += entry.size
            let parts = entry.path.split(separator: "/")
            let root = String(parts[0])
            guard managedRoots.contains(root), root != "Library" || includesLibrary,
                  root != "config.toml" || (parts.count == 1 && entry.kind == .file),
                  root != "wallpapers" || parts.count == 1 || (parts.count == 2 && entry.kind == .file && entry.path.hasSuffix(".json")),
                  parts.count != 1 || root == "config.toml" || entry.kind == .directory else { throw files.unsafe(entry.path) }
            if parts.count > 1 {
                let parent = parts.dropLast().joined(separator: "/")
                guard directoryPaths.contains(parent) else { throw files.unsafe(entry.path) }
            }
            if entry.kind == .directory {
                guard entry.size == 0, entry.digest == nil else { throw files.unsafe(entry.path) }
                directoryPaths.insert(entry.path)
            } else if requireDigests {
                guard let digest = entry.digest, digest.count == 64,
                      digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw files.unsafe(entry.path) }
            }
        }
    }

    private func validatePreferences(_ values: [String: Data]) throws {
        guard Set(values.keys).isSubset(of: WallpaperBackupPreferences.allowedKeys) else {
            throw WallpaperBackupFailure(message: String(localized: "The backup contains preferences that WallpaperMachine does not allow restoring."))
        }
        var bytes = 0
        for (key, data) in values {
            guard data.count <= limits.maximumPreferenceBytes - bytes else { throw files.oversized() }
            bytes += data.count
            let value = try WallpaperBackupPreferences.decode(data)
            try validateValue(value, depth: 0)
            try WallpaperBackupPreferences.validate(value, forKey: key)
        }
    }

    private func validateValue(_ value: Any, depth: Int) throws {
        guard depth <= limits.maximumDepth else { throw files.oversized() }
        if let number = value as? NSNumber, !number.doubleValue.isFinite { throw files.oversized() }
        if let date = value as? Date, !date.timeIntervalSince1970.isFinite { throw files.oversized() }
        if let data = value as? Data {
            if let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
                try validateValue(json, depth: depth + 1)
            }
        } else if let dictionary = value as? [String: Any] {
            guard dictionary.count <= limits.maximumEntries else { throw files.oversized() }
            for child in dictionary.values { try validateValue(child, depth: depth + 1) }
        } else if let array = value as? [Any] {
            guard array.count <= limits.maximumEntries else { throw files.oversized() }
            for child in array { try validateValue(child, depth: depth + 1) }
        }
    }

    private func resourceUnits(_ entries: [WallpaperBackupEntry]) throws -> [String] {
        var units = Set<String>()
        for entry in entries {
            let parts = entry.path.split(separator: "/")
            if parts.count == 1 && entry.kind == .file {
                units.insert(entry.path)
            } else if parts.count == 2 && entry.path != "UserAssets/PresetAssets" {
                units.insert(entry.path)
            } else if parts.count == 3 && parts[0] == "UserAssets" && parts[1] == "PresetAssets" {
                units.insert(entry.path)
            }
        }
        return units.sorted()
    }

    private func wallpaperIDs(_ entries: [WallpaperBackupEntry]) -> Set<String> {
        var ids = Set<String>()
        for entry in entries {
            let parts = entry.path.split(separator: "/")
            if parts.count == 2, parts[0] == "Library" { ids.insert(String(parts[1])) }
            if parts.count == 2, parts[0] == "wallpapers", parts[1].hasSuffix(".json") {
                ids.insert(String(parts[1].dropLast(5)))
            }
        }
        return ids
    }

    private func recordCount(_ data: Data?, field: String?) throws -> Int {
        guard let data, let jsonData = try WallpaperBackupPreferences.decode(data) as? Data,
              let json = try? JSONSerialization.jsonObject(with: jsonData) else { return 0 }
        if let field {
            guard let dictionary = json as? [String: Any] else { return 0 }
            return (dictionary[field] as? [Any])?.count ?? 0
        }
        return (json as? [Any])?.count ?? 0
    }

    private func encodedManifest(_ manifest: WallpaperBackupManifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(manifest)
        guard data.count <= limits.maximumManifestBytes else { throw files.oversized() }
        return data
    }

    @discardableResult
    private func writeManifest(_ manifest: WallpaperBackupManifest, at root: URL) throws -> String {
        let data = try encodedManifest(manifest)
        try data.write(to: root.appendingPathComponent("manifest.json"), options: .atomic)
        return WallpaperBackupFiles.digest(data)
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    private func readJSON<T: Decodable>(_ type: T.Type, at root: URL, name: String) throws -> T {
        try JSONDecoder().decode(type, from: files.readMetadata(root: root, path: name, maximum: limits.maximumManifestBytes))
    }

    private func publishPackage(_ source: URL, to destination: URL) throws {
        let old = destination.deletingLastPathComponent().appendingPathComponent(".wmbackup-old-\(UUID().uuidString)")
        let existed = manager.fileExists(atPath: destination.path)
        if existed {
            guard try files.kind(at: destination).0 == .directory else { throw files.unsafe(destination.lastPathComponent) }
            try manager.moveItem(at: destination, to: old)
        }
        do { try manager.moveItem(at: source, to: destination) }
        catch {
            if existed { try manager.moveItem(at: old, to: destination) }
            throw error
        }
        if existed { try manager.removeItem(at: old) }
    }

    private func contains(_ child: URL, in parent: URL) -> Bool {
        child.path == parent.path || child.path.hasPrefix(parent.path + "/")
    }

    private func ensureSafeParents(of path: String, root: URL) throws {
        var directory = root
        for component in path.split(separator: "/").dropLast() {
            directory.appendPathComponent(String(component))
            if manager.fileExists(atPath: directory.path) {
                guard try files.kind(at: directory).0 == .directory else { throw files.unsafe(path) }
            } else { try manager.createDirectory(at: directory, withIntermediateDirectories: false) }
        }
    }

    @MainActor
    private func recover(transaction: URL, defaults: UserDefaults) throws {
        guard try files.kind(at: transaction).0 == .directory else { throw files.unsafe(transaction.lastPathComponent) }
        let journalURL = transaction.appendingPathComponent("journal.json")
        guard manager.fileExists(atPath: journalURL.path) else {
            // Preparation never moves live files before the journal exists.
            guard try files.kind(at: transaction).0 == .directory else { throw files.unsafe(transaction.lastPathComponent) }
            guard !manager.fileExists(atPath: transaction.appendingPathComponent("old").path) else {
                throw WallpaperBackupFailure(message: String(localized: "Restore recovery found old files without its journal. Keep this support folder intact; the old files have not been deleted."))
            }
            try manager.removeItem(at: transaction)
            return
        }
        let journal = try readJSON(WallpaperBackupJournal.self, at: transaction, name: "journal.json")
        let recoveryKeys = WallpaperBackupPreferences.allowedKeys.union(WallpaperBackupPreferences.localRecoveryKeys)
        guard journal.version == 1,
              Set(journal.absentPreferences).isSubset(of: recoveryKeys),
              Set(journal.absentPreferences).isDisjoint(with: journal.originalPreferences.keys),
              journal.units.count <= limits.maximumEntries else { throw files.unsafe("journal.json") }
        // The journal is our exact old state, including preferences an old app could
        // not hydrate. Recovery must not reject those originals under a newer schema.
        guard Set(journal.originalPreferences.keys).isSubset(of: recoveryKeys) else { throw files.unsafe("journal.json") }
        for data in journal.originalPreferences.values { try validateValue(WallpaperBackupPreferences.decode(data), depth: 0) }
        // The library where this restore found it, which may not be where it is now.
        let libraryRoot: URL
        let drive = WallpaperBackupFailure(message: String(localized: "Restore recovery needs the drive that holds the wallpaper library. Connect it and open WallpaperMachine again; nothing has been deleted."))
        if let recorded = journal.libraryRoot {
            libraryRoot = URL(fileURLWithPath: recorded, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
            // A folder that is merely there is not enough: a disconnected drive can leave its
            // empty mount point behind.
            guard recorded.hasPrefix("/"), manager.fileExists(atPath: libraryRoot.path),
                  journal.libraryMarker == nil || StorageLocation.marker(at: libraryRoot) == journal.libraryMarker else { throw drive }
        } else {
            libraryRoot = supportRoot
        }
        let libraryTransaction = libraryTransaction(libraryRoot: libraryRoot, transaction: transaction)
        // Every library unit was prepared there before the journal was written.
        if let libraryTransaction, journal.units.contains(where: { Self.isLibrary($0.path) }),
           !manager.fileExists(atPath: libraryTransaction.path) { throw drive }
        func staged(_ unit: String) -> URL { unitTransaction(unit, transaction: transaction, libraryRoot: libraryRoot) }
        func liveRoot(_ unit: String) -> URL { Self.isLibrary(unit) ? libraryRoot : supportRoot }
        var paths = Set<String>()
        for unit in journal.units {
            try files.validateRelative(unit.path)
            try ensureSafeParents(of: "old/" + unit.path, root: staged(unit.path))
            try ensureSafeParents(of: "ready/" + unit.path, root: staged(unit.path))
            let parts = unit.path.split(separator: "/")
            guard paths.insert(unit.path).inserted,
                  unit.path == "config.toml" || (parts.count == 2 && ["wallpapers", "Library", "UserAssets"].contains(String(parts[0])) && unit.path != "UserAssets/PresetAssets")
                    || (parts.count == 3 && parts[0] == "UserAssets" && parts[1] == "PresetAssets") else {
                throw files.unsafe(unit.path)
            }
        }
        if journal.preferencesCommitted {
            try finishCommitted(transaction: transaction, libraryTransaction: libraryTransaction)
            return
        }
        // A unit that was here is moved aside before its replacement is published, so one of the
        // two copies is always there. Neither means the copies are not where the journal says:
        // nothing is rolled back and the journal is kept.
        for unit in journal.units where unit.existed {
            let staging = staged(unit.path)
            guard manager.fileExists(atPath: staging.appendingPathComponent("old/" + unit.path).path)
                    || manager.fileExists(atPath: staging.appendingPathComponent("ready/" + unit.path).path) else {
                throw WallpaperBackupFailure(message: String(localized: "Restore recovery could not find the copies it set aside. The restore folder has been kept and nothing has been deleted."))
            }
        }
        for unit in journal.units.reversed() {
            try ensureSafeParents(of: unit.path, root: liveRoot(unit.path))
            let live = liveRoot(unit.path).appendingPathComponent(unit.path)
            let old = staged(unit.path).appendingPathComponent("old/" + unit.path)
            let ready = staged(unit.path).appendingPathComponent("ready/" + unit.path)
            if manager.fileExists(atPath: old.path) {
                _ = try files.kind(at: old)
                if manager.fileExists(atPath: live.path) { try manager.removeItem(at: live) }
                try manager.moveItem(at: old, to: live)
            } else if !unit.existed && !manager.fileExists(atPath: ready.path) {
                // No old state and ready moved: this unit was newly published.
                if manager.fileExists(atPath: live.path) { try manager.removeItem(at: live) }
            }
        }
        for (key, data) in journal.originalPreferences { defaults.set(try WallpaperBackupPreferences.decode(data), forKey: key) }
        for key in journal.absentPreferences { defaults.removeObject(forKey: key) }
        guard defaults.synchronize() else {
            throw WallpaperBackupFailure(message: String(localized: "The previous preferences could not be saved. Restore recovery will retry at the next launch."))
        }
        // The library's folder first: the journal beside the support root is what names it.
        if let libraryTransaction, manager.fileExists(atPath: libraryTransaction.path) { try manager.removeItem(at: libraryTransaction) }
        try manager.removeItem(at: transaction)
    }

    private func finishCommitted(transaction: URL, libraryTransaction: URL?) throws {
        // Delete pending first: a crash cannot leave a completed restore to repeat.
        try cancelPendingRestore()
        if let libraryTransaction, manager.fileExists(atPath: libraryTransaction.path) { try manager.removeItem(at: libraryTransaction) }
        try manager.removeItem(at: transaction)
    }

    private struct PreferenceChanges {
        var values: [String: Data] = [:]
        var removedKeys: Set<String> = []
    }

    private func mergedPreferences(_ incoming: [String: Data], existing: [String: Data],
                                   policy: WallpaperBackupConflictPolicy, context: ReferenceContext) throws -> PreferenceChanges {
        let solar = try mergedSolarPreferences(incoming, existing: existing, policy: policy)
        var result = solar.values
        let existingDisplays = try playlistDisplays(existing["WallpaperMachine.playlists"])
        for (key, value) in incoming {
            if Self.solarKeys.contains(key) { continue }
            // Scene asset-directory authority is local. A backup never selects a new
            // external root, even if it names an existing directory on this Mac.
            if key == "WallpaperMachineAssetsPath" { continue }
            if policy == .keepExisting, key == "WallpaperMachine.playlistNextChange" { continue }
            let decoded = try WallpaperBackupPreferences.decode(value)
            let remapped: Any
            if key == "WallpaperMachine.wallpaperPresets" { remapped = try remapPresets(decoded, context: context) }
            else { remapped = decoded }
            if policy == .keepExisting, let old = existing[key] {
                let current = try WallpaperBackupPreferences.decode(old)
                switch key {
                case "WallpaperMachine.collections", "WallpaperMachine.playlistPlans", "WallpaperMachine.displayLayouts", "WallpaperMachine.favoriteWallpaperIDs",
                     "WallpaperMachine.wallpaperPresets", "WallpaperMachine.imagePlacements", "WallpaperMachine.playlists", "WallpaperMachine.automaticWallpapers":
                    guard let oldJSON = current as? Data, let newJSON = remapped as? Data else { throw files.changed() }
                    let oldValue = try JSONSerialization.jsonObject(with: oldJSON)
                    let newValue = try JSONSerialization.jsonObject(with: newJSON)
                    let merged: Any
                    if key == "WallpaperMachine.playlists" || key == "WallpaperMachine.automaticWallpapers" {
                        guard let oldMap = oldValue as? [String: Any], let newMap = newValue as? [String: Any] else { throw files.changed() }
                        merged = newMap.merging(oldMap) { _, old in old }
                    } else { merged = mergeJSON(existing: oldValue, incoming: newValue) }
                    result[key] = try WallpaperBackupPreferences.encode(JSONSerialization.data(withJSONObject: merged, options: [.sortedKeys]))
                default: continue
                }
            } else { result[key] = try WallpaperBackupPreferences.encode(remapped) }
        }
        if policy == .keepExisting, incoming["WallpaperMachine.playlists"] != nil || incoming["WallpaperMachine.playlistNextChange"] != nil {
            let deadlineKey = "WallpaperMachine.playlistNextChange"
            func deadlines(_ encoded: Data?) throws -> [String: Any] {
                guard let encoded else { return [:] }
                guard let map = try WallpaperBackupPreferences.decode(encoded) as? [String: Any] else { throw files.changed() }
                return map
            }
            var merged = try deadlines(existing[deadlineKey])
            let new = try deadlines(incoming[deadlineKey])
            let incomingDisplays = try playlistDisplays(incoming["WallpaperMachine.playlists"])
            // A deadline belongs to its record: new records take the incoming
            // deadline (including absence), conflicting records retain local state.
            for display in incomingDisplays.subtracting(existingDisplays) { merged[display] = new[display] }
            for (display, date) in new where !existingDisplays.contains(display) { merged[display] = date }
            result[deadlineKey] = try WallpaperBackupPreferences.encode(merged)
        }
        return PreferenceChanges(values: result, removedKeys: solar.removedKeys)
    }

    private func mergedSolarPreferences(_ incoming: [String: Data], existing: [String: Data],
                                        policy: WallpaperBackupConflictPolicy) throws -> PreferenceChanges {
        guard !Self.solarKeys.isDisjoint(with: incoming.keys),
              policy != .keepExisting || Self.solarKeys.isDisjoint(with: existing.keys) else {
            return PreferenceChanges()
        }
        func json(_ key: String) throws -> Data {
            guard let encoded = incoming[key], let data = try WallpaperBackupPreferences.decode(encoded) as? Data else {
                throw files.changed()
            }
            return data
        }
        // Both keys describe one setting. New records take precedence, as they do in the store;
        // a legacy backup must replace the current record, rather than leave it masking the import.
        let settings: WallpaperSolarSettings
        if incoming[Self.solarSettingsKey] != nil {
            settings = try JSONDecoder().decode(WallpaperSolarSettings.self, from: json(Self.solarSettingsKey))
        } else {
            let location = try JSONDecoder().decode(WallpaperSolarLocation.self, from: json(Self.solarLocationKey))
            settings = WallpaperSolarSettings(location: location)
        }
        var result = PreferenceChanges(values: [
            Self.solarSettingsKey: try WallpaperBackupPreferences.encode(JSONEncoder().encode(settings)),
        ])
        if let location = settings.location {
            result.values[Self.solarLocationKey] = try WallpaperBackupPreferences.encode(JSONEncoder().encode(location))
        } else {
            result.removedKeys.insert(Self.solarLocationKey)
        }
        return result
    }

    private func playlistDisplays(_ data: Data?) throws -> Set<String> {
        guard let data, let json = try WallpaperBackupPreferences.decode(data) as? Data else { return [] }
        return Set(try JSONDecoder().decode([String: DisplayPlaylist].self, from: json).keys)
    }

    private func mergeJSON(existing: Any, incoming: Any) -> Any {
        if let old = existing as? [String: Any], let new = incoming as? [String: Any] {
            var merged = old
            for (key, value) in new {
                if let current = old[key] { merged[key] = mergeJSON(existing: current, incoming: value) }
                else { merged[key] = value }
            }
            return merged
        }
        if let old = existing as? [Any], let new = incoming as? [Any] {
            if let oldStrings = old as? [String], let newStrings = new as? [String] {
                return Array(Set(oldStrings + newStrings)).sorted()
            }
            if old.allSatisfy({ ($0 as? [String: Any])?["id"] is String }),
               new.allSatisfy({ ($0 as? [String: Any])?["id"] is String }) {
                let ids = Set(old.compactMap { ($0 as? [String: Any])?["id"] as? String })
                return old + new.filter { !ids.contains(($0 as? [String: Any])?["id"] as? String ?? "") }
            }
        }
        return existing
    }

    private struct ReferenceContext {
        var payload: URL
        var roots: [String]
        var entries: [String: WallpaperBackupEntry]
        var selected: Set<String>?
    }

    private func referenceContext(manifest: WallpaperBackupManifest, package: URL, selected: Set<String>? = nil) -> ReferenceContext {
        .init(payload: package.appendingPathComponent("data"), roots: manifest.referenceRoots,
              entries: Dictionary(uniqueKeysWithValues: manifest.entries.map { ($0.path, $0) }), selected: selected)
    }

    private func validateRendererConfiguration(root: URL, entries: [WallpaperBackupEntry]) throws {
        var app: String?
        var wallpapers: [String: String] = [:]
        for entry in entries where entry.kind == .file && (entry.path == "config.toml" || entry.path.hasPrefix("wallpapers/")) {
            let data = try files.readMetadata(root: root, path: entry.path, maximum: limits.maximumMetadataBytes)
            guard let text = String(data: data, encoding: .utf8) else { throw files.changed() }
            if entry.path == "config.toml" { app = text }
            else { wallpapers[entry.path] = text }
        }
        try validateBackupRendererConfiguration(appConfig: app, wallpaperConfigs: wallpapers)
    }

    private func readObject(root: URL, path: String) throws -> [String: Any] {
        let data = try files.readMetadata(root: root, path: path, maximum: limits.maximumMetadataBytes)
        let json = try JSONSerialization.jsonObject(with: data)
        try validateValue(json, depth: 0)
        guard let object = json as? [String: Any] else { throw files.changed() }
        return object
    }

    private func projectProperties(_ id: String, context: ReferenceContext) throws -> [String: [String: Any]] {
        try files.validateRelative(id)
        guard !id.contains("/") else { throw files.unsafe(id) }
        let path = "Library/\(id)/project.json"
        let useIncoming = context.entries[path] != nil && (context.selected == nil || context.selected!.contains("Library/" + id))
        let root = useIncoming ? context.payload : storageRoot
        guard manager.fileExists(atPath: root.appendingPathComponent(path).path) else { return [:] }
        let object = try readObject(root: root, path: path)
        return (object["general"] as? [String: Any])?["properties"] as? [String: [String: Any]] ?? [:]
    }

    private func isWebProject(_ id: String, context: ReferenceContext) throws -> Bool {
        let path = "Library/\(id)/project.json"
        let useIncoming = context.entries[path] != nil && (context.selected == nil || context.selected!.contains("Library/" + id))
        let root = useIncoming ? context.payload : storageRoot
        guard manager.fileExists(atPath: root.appendingPathComponent(path).path) else { return false }
        return (try readObject(root: root, path: path)["type"] as? String)?.lowercased() == "web"
    }

    private func isResourceKind(_ kind: String?) -> Bool {
        ["file", "directory", "texture", "scenetexture"].contains(kind?.lowercased() ?? "")
    }

    private func referencePath(_ text: String) throws -> String {
        let path: String
        if text.hasPrefix("file:") {
            guard let url = URL(string: text), url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost" else { throw files.unsafe(text) }
            path = url.path
        } else { path = text }
        guard !path.contains("\0"), path.utf8.count <= limits.maximumPathBytes,
              !path.contains("\\"), !path.hasPrefix("~"),
              (path as NSString).standardizingPath == path || path.isEmpty else { throw files.unsafe(text) }
        return path
    }

    private func localAuthorizes(_ text: String, wallpaper: String, property: String) throws -> Bool {
        let wanted = try referencePath(text)
        let localManifestPath = "UserAssets/\(wallpaper)/manifest.json"
        if manager.fileExists(atPath: supportRoot.appendingPathComponent(localManifestPath).path) {
            let object = try readObject(root: supportRoot, path: localManifestPath)
            if let record = ((object["properties"] as? [String: Any])?[property] as? [String: Any]) {
                if record["originalSourceUnauthorized"] as? Bool == true { return false }
                if let selected = record["authorizedSourcePath"] as? String,
                   try referencePath(selected) != wanted { return false }
            }
        }
        let projectPath = "Library/\(wallpaper)/project.json"
        var descriptor: [String: Any]?
        if manager.fileExists(atPath: live(projectPath).path) {
            let object = try readObject(root: storageRoot, path: projectPath)
            descriptor = ((object["general"] as? [String: Any])?["properties"] as? [String: [String: Any]])?[property]
        }
        let configPath = "wallpapers/\(wallpaper).json"
        if isResourceKind(descriptor?["type"] as? String), manager.fileExists(atPath: supportRoot.appendingPathComponent(configPath).path) {
            let object = try readObject(root: supportRoot, path: configPath)
            if let current = (object["property_overrides"] as? [String: Any])?[property] as? String,
               try referencePath(current) == wanted { return true }
        }
        let manifestPath = "UserAssets/\(wallpaper)/manifest.json"
        if manager.fileExists(atPath: supportRoot.appendingPathComponent(manifestPath).path) {
            let object = try readObject(root: supportRoot, path: manifestPath)
            if let record = ((object["properties"] as? [String: Any])?[property] as? [String: Any]),
               record["originalSourceUnauthorized"] as? Bool != true,
               let current = record["sourcePath"] as? String,
               try referencePath(current) == wanted { return true }
        }
        return false
    }


    private func remapReference(_ text: String, wallpaper: String, property: String,
                                context: ReferenceContext, retainedPreset: String? = nil,
                                allowsRetainedSource: Bool = false) throws -> String {
        let path = try referencePath(text)
        guard !path.isEmpty else { return text }
        if !path.hasPrefix("/") {
            try files.validateRelative(path)
            return text
        }
        for root in context.roots where path.hasPrefix(root + "/") {
            let relative = String(path.dropFirst(root.count + 1))
            try files.validateRelative(relative)
            let owned = relative.hasPrefix("UserAssets/\(wallpaper)/\(property)/")
                || relative.hasPrefix("Library/\(wallpaper)/") || relative == retainedPreset
                || (retainedPreset != nil && relative.hasPrefix(retainedPreset! + "/"))
            if owned, context.entries[relative] != nil {
                if let selected = context.selected, !selected.contains(where: { relative == $0 || relative.hasPrefix($0 + "/") }) {
                    let live = live(relative)
                    guard live.resolvingSymlinksInPath().path == live.path else { throw files.unsafe(relative) }
                }
                let mapped = live(relative)
                return text.hasPrefix("file:") ? mapped.absoluteString : mapped.path
            }
        }
        if try localAuthorizes(text, wallpaper: wallpaper, property: property) { return text }
        // An external original accompanied by genuine property-owned copied bytes
        // is recoverable without authorizing any new external read.
        let manifestPath = "UserAssets/\(wallpaper)/manifest.json"
        if context.entries[manifestPath] != nil {
            let object = try readObject(root: context.payload, path: manifestPath)
            if let record = (object["properties"] as? [String: [String: Any]])?[property],
               let source = record["sourcePath"] as? String, try referencePath(source) == path,
               let assets = record["assets"] as? [[String: Any]], !assets.isEmpty {
                // Only the Web asset host enforces retained-only source state. A
                // scene renderer reads paths directly, so it must receive real bytes.
                if allowsRetainedSource { return text }
                if record["kind"] as? String == "file", assets.count == 1,
                   let assetID = assets[0]["assetId"] as? String,
                   let name = assets[0]["fileName"] as? String {
                    try files.validateRelative(assetID)
                    try files.validateRelative(name)
                    guard !assetID.contains("/"), !name.contains("/") else { throw files.unsafe(text) }
                    let relative = "UserAssets/\(wallpaper)/\(property)/\(assetID)/\(name)"
                    guard let entry = context.entries[relative], entry.kind == .file,
                          entry.size == (assets[0]["size"] as? NSNumber)?.int64Value,
                          entry.digest == assets[0]["digest"] as? String else { throw files.changed() }
                    if let selected = context.selected, !selected.contains("UserAssets/" + wallpaper) {
                        // Keep-existing may preserve another asset tree. The exact
                        // retained file must still exist and match the reviewed bytes.
                        try files.stream(root: supportRoot, entry: entry, rejectHardLinks: false)
                    }
                    return supportRoot.appendingPathComponent(relative).path
                }
            }
        }
        throw WallpaperBackupFailure(message: String(localized: "A backup resource has no local authorization or retained copy. Reselect it in the wallpaper’s properties before restoring: \(text)"))
    }

    private func remapPresets(_ value: Any, context: ReferenceContext) throws -> Data {
        guard let data = value as? Data else { throw files.changed() }
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var items = object["items"] as! [[String: Any]]
        for index in items.indices {
            let wallpaper = items[index]["wallpaperID"] as! String
            let preset = items[index]["id"] as! String
            var properties = items[index]["properties"] as! [[String: Any]]
            for p in properties.indices where isResourceKind(properties[p]["kind"] as? String) {
                let property = properties[p]["id"] as! String
                let retainedBase = "UserAssets/PresetAssets/\(preset)/\(property)"
                if let retained = properties[p]["retainedPath"] as? String {
                    properties[p]["retainedPath"] = try remapReference(retained, wallpaper: wallpaper, property: property,
                        context: context, retainedPreset: retainedBase)
                }
                if var enumValue = properties[p]["value"] as? [String: Any], var string = enumValue["string"] as? [String: Any],
                   let path = string["_0"] as? String {
                    if let retained = properties[p]["retainedPath"] as? String { string["_0"] = retained }
                    else { string["_0"] = try remapReference(path, wallpaper: wallpaper, property: property, context: context, retainedPreset: retainedBase) }
                    enumValue["string"] = string
                    properties[p]["value"] = enumValue
                }
            }
            items[index]["properties"] = properties
        }
        object["items"] = items
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func rewrittenMetadata(_ object: [String: Any], logicalPath: String, context: ReferenceContext) throws -> [String: Any] {
        var result = object
        let parts = logicalPath.split(separator: "/").map(String.init)
        if parts[0] == "wallpapers" {
            let wallpaper = String(parts[1].dropLast(5))
            let descriptors = try projectProperties(wallpaper, context: context)
            let web = try isWebProject(wallpaper, context: context)
            var overrides = result["property_overrides"] as? [String: Any] ?? [:]
            for (property, value) in overrides {
                guard let text = value as? String else { continue }
                let kind = descriptors[property]?["type"] as? String
                if isResourceKind(kind) || (kind == nil && (text.hasPrefix("/") || text.hasPrefix("file:"))) {
                    overrides[property] = try remapReference(text, wallpaper: wallpaper, property: property, context: context,
                        allowsRetainedSource: web && ["file", "directory"].contains(kind?.lowercased() ?? ""))
                }
            }
            result["property_overrides"] = overrides
        } else if parts[0] == "Library" {
            let wallpaper = parts[1]
            for field in ["file", "preview"] {
                if let text = result[field] as? String {
                    result[field] = try remapReference(text, wallpaper: wallpaper, property: "__project_" + field, context: context)
                }
            }
            if var general = result["general"] as? [String: Any], var properties = general["properties"] as? [String: [String: Any]] {
                let web = (result["type"] as? String)?.lowercased() == "web"
                for (property, var descriptor) in properties where isResourceKind(descriptor["type"] as? String) {
                    if let path = descriptor["value"] as? String {
                        descriptor["value"] = try remapReference(path, wallpaper: wallpaper, property: property, context: context,
                            allowsRetainedSource: web && ["file", "directory"].contains((descriptor["type"] as? String)?.lowercased() ?? ""))
                    }
                    properties[property] = descriptor
                }
                general["properties"] = properties
                result["general"] = general
            }
        } else if parts[0] == "UserAssets" {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let manifest = try decoder.decode(UserAssetManifest.self, from: JSONSerialization.data(withJSONObject: object))
            guard manifest.version == UserAssetManifest.currentVersion, manifest.wallpaperId == parts[1] else { throw files.changed() }
            var properties = object["properties"] as? [String: [String: Any]] ?? [:]
            for (property, var record) in properties {
                try files.validateRelative(property)
                guard !property.contains("/") else { throw files.unsafe(property) }
                let source = record["sourcePath"] as! String
                let incomingRetainedOnly = record["originalSourceUnauthorized"] as? Bool == true
                let authorized: Bool
                if incomingRetainedOnly { authorized = false }
                else { authorized = try localAuthorizes(source, wallpaper: parts[1], property: property) }
                record["originalSourceUnauthorized"] = !authorized
                // Incoming scope is metadata, not local user authority.
                record.removeValue(forKey: "authorizedSourcePath")
                record["migratedLegacyPaths"] = []
                var assets = record["assets"] as! [[String: Any]]
                var seen = Set<String>()
                for index in assets.indices {
                    let assetID = assets[index]["assetId"] as! String
                    let name = assets[index]["fileName"] as! String
                    try files.validateRelative(assetID); try files.validateRelative(name)
                    guard !assetID.contains("/"), !name.contains("/"), seen.insert(assetID + "/" + name).inserted else { throw files.unsafe(name) }
                    let relative = "UserAssets/\(parts[1])/\(property)/\(assetID)/\(name)"
                    guard let entry = context.entries[relative], entry.kind == .file,
                          entry.size == (assets[index]["size"] as? NSNumber)?.int64Value,
                          entry.digest == assets[index]["digest"] as? String else { throw files.changed() }
                    // Keep the actual original path as provenance, never a sentinel.
                }
                record["assets"] = assets
                properties[property] = record
            }
            result["properties"] = properties
        }
        return result
    }

    private func validateReferences(manifest: WallpaperBackupManifest, package: URL) throws {
        let context = referenceContext(manifest: manifest, package: package)
        for entry in manifest.entries where isReferenceMetadata(entry) {
            _ = try rewrittenMetadata(readObject(root: context.payload, path: entry.path), logicalPath: entry.path, context: context)
        }
        if let data = manifest.preferences["WallpaperMachine.wallpaperPresets"] {
            _ = try remapPresets(WallpaperBackupPreferences.decode(data), context: context)
        }
    }

    private func remapMetadata(in target: URL, logicalPath: String, context: ReferenceContext) throws {
        let metadataPath: String
        if logicalPath.hasPrefix("wallpapers/") { metadataPath = logicalPath }
        else if logicalPath.hasPrefix("Library/") { metadataPath = logicalPath + "/project.json" }
        else if logicalPath.hasPrefix("UserAssets/"), !logicalPath.hasPrefix("UserAssets/PresetAssets/") { metadataPath = logicalPath + "/manifest.json" }
        else { return }
        guard context.entries[metadataPath] != nil else { return }
        let object = try readObject(root: context.payload, path: metadataPath)
        let remapped = try rewrittenMetadata(object, logicalPath: metadataPath, context: context)
        let url = logicalPath.hasPrefix("wallpapers/") ? target : target.appendingPathComponent(metadataPath.hasSuffix("project.json") ? "project.json" : "manifest.json")
        try JSONSerialization.data(withJSONObject: remapped, options: [.sortedKeys]).write(to: url, options: .atomic)
    }

    private func diagnose(manifest: WallpaperBackupManifest, package: URL) throws -> [String] {
        var warnings = Set<String>()
        let payload = package.appendingPathComponent("data")
        let paths = Set(manifest.entries.map(\.path))
        let ids = wallpaperIDs(manifest.entries)
        for id in ids where !paths.contains("Library/" + id) && !manager.fileExists(atPath: live("Library/" + id).path) {
            warnings.insert(String(localized: "Wallpaper \(id) is not included or installed. Reinstall its project files after restoring."))
        }
        let context = referenceContext(manifest: manifest, package: package)
        var hasScene = false
        for entry in manifest.entries where isReferenceMetadata(entry) {
            let json = try readObject(root: payload, path: entry.path)
            if json["type"] as? String == "scene" { hasScene = true }
            if entry.path.hasPrefix("UserAssets/"), let properties = json["properties"] as? [String: [String: Any]] {
                let wallpaper = entry.path.split(separator: "/")[1]
                for (property, record) in properties {
                    if let source = record["sourcePath"] as? String,
                       try !localAuthorizes(source, wallpaper: String(wallpaper), property: property) {
                        warnings.insert(String(localized: "A retained resource will use its backed-up bytes instead of authorizing its original source: \(source)"))
                    }
                }
            }
            _ = try rewrittenMetadata(json, logicalPath: entry.path, context: context)
        }
        if hasScene {
            warnings.insert(String(localized: "Shared scene shaders and materials are not included in backups. Install or locate Wallpaper Engine’s complete scene assets if they are unavailable on this Mac."))
        }
        if manifest.preferences["WallpaperMachineAssetsPath"] != nil {
            warnings.insert(String(localized: "The scene assets folder remains the one already selected on this Mac. Reselect it in Settings if needed."))
        }
        return warnings.sorted()
    }

    private func isReferenceMetadata(_ entry: WallpaperBackupEntry) -> Bool {
        guard entry.kind == .file else { return false }
        let parts = entry.path.split(separator: "/")
        if parts.count == 2 && parts[0] == "wallpapers" { return true }
        if parts.count == 3 && parts[0] == "Library" && parts[2] == "project.json" { return true }
        return parts.count == 3 && parts[0] == "UserAssets" && parts[1] != "PresetAssets" && parts[2] == "manifest.json"
    }
}
