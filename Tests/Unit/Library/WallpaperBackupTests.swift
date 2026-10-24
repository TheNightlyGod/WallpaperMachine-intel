import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import WallpaperMachine

@MainActor
final class WallpaperBackupTests: XCTestCase {
    private var root: URL!
    private var source: URL { root.appendingPathComponent("source") }
    private var destination: URL { root.appendingPathComponent("destination") }
    private var package: URL { root.appendingPathComponent("Roundtrip.wmbackup") }
    private var domains: [ObjectIdentifier: String] = [:]
    private let presetID = "00000000-0000-4000-8000-000000000001"
    private let existingPresetID = "00000000-0000-4000-8000-000000000002"
    private struct PresetArchive: Codable { var version = 1; var items: [WallpaperPropertyPreset] }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Backup-tests-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private func defaults() throws -> UserDefaults {
        let (defaults, name) = try TemporaryDefaults.make(for: self)
        domains[ObjectIdentifier(defaults)] = name
        return defaults
    }

    private func domainName(for defaults: UserDefaults) -> String {
        domains[ObjectIdentifier(defaults)]!
    }

    private func put(_ string: String, _ path: String, in directory: URL) throws {
        let url = directory.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(string.utf8).write(to: url)
    }

    private func json(_ path: String, in directory: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent(path))) as? [String: Any])
    }

    private func fixture() throws -> UserDefaults {
        let preferences = try defaults()
        try put("schema_version = 1\n[general]\nlast_selected_wallpaper = \"101\"\n", "config.toml", in: source)
        try put(#"{"workshop_id":"101","type":"scene","property_overrides":{"photo":"PATH/UserAssets/101/photo/asset/画 像.png"}}"#
            .replacingOccurrences(of: "PATH", with: source.path), "wallpapers/101.json", in: source)
        try put(#"{"title":"Original","type":"scene","file":"scene.json","general":{"properties":{"photo":{"type":"file","value":""},"caption":{"type":"textInput","value":""}}}}"#, "Library/101/project.json", in: source)
        try put(#"{"layers":[]}"#, "Library/101/scene.json", in: source)
        try put("retained image bytes", "UserAssets/101/photo/asset/画 像.png", in: source)
        let bytes = Data("retained image bytes".utf8)
        let asset = ManagedUserAsset(assetId: "asset", fileName: "画 像.png",
            sourcePath: source.appendingPathComponent("UserAssets/101/photo/asset/画 像.png").path,
            size: Int64(bytes.count), modified: Date(timeIntervalSince1970: 100), digest: WallpaperBackupFiles.digest(bytes))
        var manifest = UserAssetManifest(wallpaperId: "101")
        manifest.properties["photo"] = .init(kind: .file, sourcePath: asset.sourcePath, assets: [asset])
        try ManagedUserAssetStore(root: source.appendingPathComponent("UserAssets")).write(manifest)
        // An imported file named manifest.json is user data, not store metadata.
        try put("do not parse or rewrite me", "UserAssets/101/photo/asset/manifest.json", in: source)
        let retained = "UserAssets/PresetAssets/\(presetID)/photo/retained.png"
        try put("preset bytes", retained, in: source)
        let property = WallpaperPresetProperty(id: "photo", kind: "file", value: .string(source.appendingPathComponent(retained).path),
            usesDefault: false, retainedPath: source.appendingPathComponent(retained).path)
        let preset = WallpaperPropertyPreset(id: presetID, wallpaperID: "101", name: "My preset", properties: [property])
        preferences.set(try JSONEncoder().encode(PresetArchive(items: [preset])), forKey: "WallpaperMachine.wallpaperPresets")
        preferences.set(try JSONSerialization.data(withJSONObject: [["id": "collection-one", "name": "Calm", "wallpaperIDs": ["101"]]]), forKey: "WallpaperMachine.collections")
        preferences.set("mute", forKey: "WallpaperMachine.otherAudioAction")
        preferences.set("sensitive cookie", forKey: "WallpaperMachine.steamCookie")
        try put("credential", "SteamCMD/config/loginusers.vdf", in: source)
        try put("log", "Logs/session.log", in: source)
        try put("cache", "Cache/cache.bin", in: source)
        return preferences
    }

    func testAutomationRulesMergeByDisplayAndRestoreClearsOnlyLocalRecoveryState() async throws {
        let original = try fixture()
        let incoming = WallpaperAutomationStore(defaults: original)
        for display in ["primary", "secondary"] {
            try incoming.update(display) {
                $0.mode = .appearance; $0.light = .init(kind: .wallpaper, id: "101")
                $0.spaces["desktop-uuid"] = .init(kind: .wallpaper, id: "101")
            }
        }
        try incoming.setLocation(.init(latitude: 1.35, longitude: 103.82))
        incoming.markHandled("source event", on: "primary")
        let export = try WallpaperBackupPreferences(defaults: original, domainName: domainName(for: original))
        for key in WallpaperBackupPreferences.localRecoveryKeys { XCTAssertNil(export.values[key]) }
        try WallpaperBackupService(supportRoot: source).export(to: package, includeLibrary: true, preferences: export)
        let live = try defaults()
        let existing = WallpaperAutomationStore(defaults: live)
        try existing.update("primary") { $0.mode = .schedule; $0.rules = [.init(target: .init(kind: .wallpaper, id: "own"))] }
        let primary = existing.configuration(for: "primary")
        for key in WallpaperBackupPreferences.localRecoveryKeys { live.set(Data("local state".utf8), forKey: key) }
        let service = WallpaperBackupService(supportRoot: destination)
        let preview = try service.preview(package: package, preferences: .init(defaults: live, domainName: domainName(for: live)))
        try service.stageRestore(package: package, preview: preview, policy: .keepExisting)
        _ = try service.applyPendingRestore(defaults: live, domainName: domainName(for: live))
        let restored = WallpaperAutomationStore(defaults: live)
        XCTAssertEqual(restored.configuration(for: "primary"), primary)
        XCTAssertEqual(restored.configuration(for: "secondary").light?.id, "101")
        XCTAssertEqual(restored.configuration(for: "secondary").spaces["desktop-uuid"]?.id, "101")
        XCTAssertEqual(restored.location, incoming.location)
        for key in WallpaperBackupPreferences.localRecoveryKeys { XCTAssertNil(live.object(forKey: key)) }
    }

    func testFailedPublicationRestoresTheExactLocalAutomationRecoveryValues() async throws {
        let original = try fixture()
        let incoming = WallpaperAutomationStore(defaults: original)
        try incoming.update("primary") { $0.mode = .appearance; $0.dark = .init(kind: .wallpaper, id: "101") }
        try WallpaperBackupService(supportRoot: source).export(to: package, includeLibrary: true,
            preferences: .init(defaults: original, domainName: domainName(for: original)))
        let live = try defaults()
        let prior = Data("previous local Focus state".utf8)
        for key in WallpaperBackupPreferences.localRecoveryKeys { live.set(prior, forKey: key) }
        let service = WallpaperBackupService(supportRoot: destination)
        let preview = try service.preview(package: package, preferences: .init(defaults: live, domainName: domainName(for: live)))
        try service.stageRestore(package: package, preview: preview, policy: .replace)
        XCTAssertThrowsError(try service.applyPendingRestore(defaults: live, domainName: domainName(for: live), beforePublish: { path in
            guard path == "Preferences" else { return }
            // Emulate interruption after a transient-key write; rollback must use the journal.
            for key in WallpaperBackupPreferences.localRecoveryKeys { live.removeObject(forKey: key) }
            throw CocoaError(.fileWriteUnknown)
        }))
        for key in WallpaperBackupPreferences.localRecoveryKeys { XCTAssertEqual(live.data(forKey: key), prior) }
        XCTAssertNil(live.object(forKey: WallpaperAutomationStore.configurationsKey))
    }

    func testDisplayLayoutsRoundTripAndKeepExistingMergesByLayoutIdentity() async throws {
        let original = try fixture()
        let layouts = WallpaperDisplayLayoutStore(defaults: original)
        let assignment = WallpaperDisplayAssignment(displayID: "identity:external", displayTitle: "Studio", wallpaperID: "101")
        let first = try layouts.save(name: "Original", assignments: [assignment])
        let second = try layouts.save(name: "Another", assignments: [assignment])
        let live = try defaults()
        var local = first; local.name = "Keep this name"
        live.set(try JSONEncoder().encode([local]), forKey: WallpaperDisplayLayoutStore.storageKey)
        try WallpaperBackupService(supportRoot: source).export(to: package, includeLibrary: true,
            preferences: .init(defaults: original, domainName: domainName(for: original)))
        let service = WallpaperBackupService(supportRoot: destination)
        let preview = try service.preview(package: package, preferences: .init(defaults: live, domainName: domainName(for: live)))
        try service.stageRestore(package: package, preview: preview, policy: .keepExisting)
        _ = try service.applyPendingRestore(defaults: live, domainName: domainName(for: live))
        let restored = WallpaperDisplayLayoutStore(defaults: live)
        XCTAssertEqual(try restored.layout(first.id), local)
        XCTAssertEqual(try restored.layout(second.id), second)
    }

    func testBackupExportsOnlyPersistentPreferencesAndKeepExistingIgnoresInheritedValues() async throws {
        let original = try defaults()
        let target = try defaults()
        let languageKey = "AppleLanguages"
        let actionKey = "WallpaperMachine.otherAudioAction"
        let originalArguments = original.volatileDomain(forName: UserDefaults.argumentDomain)
        let originalRegistration = original.volatileDomain(forName: UserDefaults.registrationDomain)
        original.setVolatileDomain([languageKey: ["ja"]], forName: UserDefaults.argumentDomain)
        original.register(defaults: [actionKey: "mute"])
        defer {
            original.setVolatileDomain(originalArguments, forName: UserDefaults.argumentDomain)
            original.setVolatileDomain(originalRegistration, forName: UserDefaults.registrationDomain)
        }
        XCTAssertEqual(original.stringArray(forKey: languageKey), ["ja"])
        XCTAssertEqual(original.string(forKey: actionKey), "mute")
        var preferences = try WallpaperBackupPreferences(defaults: original, domainName: domainName(for: original))
        XCTAssertNil(preferences.values[languageKey])
        XCTAssertNil(preferences.values[actionKey])
        original.set(["zh-Hans"], forKey: languageKey)
        original.set("pause", forKey: actionKey)
        preferences = try WallpaperBackupPreferences(defaults: original, domainName: domainName(for: original))
        XCTAssertEqual(try WallpaperBackupPreferences.decode(XCTUnwrap(preferences.values[languageKey])) as? [String], ["zh-Hans"])
        try WallpaperBackupService(supportRoot: source).export(to: package, includeLibrary: false, preferences: preferences)
        let targetArguments = target.volatileDomain(forName: UserDefaults.argumentDomain)
        target.setVolatileDomain([languageKey: ["en"], actionKey: "ignore"], forName: UserDefaults.argumentDomain)
        defer { target.setVolatileDomain(targetArguments, forName: UserDefaults.argumentDomain) }
        let service = WallpaperBackupService(supportRoot: destination)
        let preview = try service.preview(package: package,
            preferences: .init(defaults: target, domainName: domainName(for: target)))
        XCTAssertFalse(preview.conflicts.contains("Preferences/" + languageKey))
        XCTAssertFalse(preview.conflicts.contains("Preferences/" + actionKey))
        try service.stageRestore(package: package, preview: preview, policy: .keepExisting)
        _ = try service.applyPendingRestore(defaults: target, domainName: domainName(for: target))
        let persistent = target.persistentDomain(forName: domainName(for: target))
        XCTAssertEqual(persistent?[languageKey] as? [String], ["zh-Hans"])
        XCTAssertEqual(persistent?[actionKey] as? String, "pause")
    }

    func testFailedRestoreDoesNotPersistInheritedLanguage() async throws {
        let original = try fixture()
        original.set(["ja"], forKey: "AppleLanguages")
        let target = try defaults()
        let targetArguments = target.volatileDomain(forName: UserDefaults.argumentDomain)
        target.setVolatileDomain(["AppleLanguages": ["en"]], forName: UserDefaults.argumentDomain)
        defer { target.setVolatileDomain(targetArguments, forName: UserDefaults.argumentDomain) }
        try WallpaperBackupService(supportRoot: source).export(to: package, includeLibrary: true,
            preferences: .init(defaults: original, domainName: domainName(for: original)))
        let service = WallpaperBackupService(supportRoot: destination)
        let preview = try service.preview(package: package,
            preferences: .init(defaults: target, domainName: domainName(for: target)))
        try service.stageRestore(package: package, preview: preview, policy: .replace)
        XCTAssertThrowsError(try service.applyPendingRestore(defaults: target, domainName: domainName(for: target), beforePublish: { path in
            if path == "Preferences" { throw CocoaError(.fileWriteUnknown) }
        }))
        XCTAssertNil(target.persistentDomain(forName: domainName(for: target))?["AppleLanguages"])
        XCTAssertEqual(target.stringArray(forKey: "AppleLanguages"), ["en"])
        XCTAssertTrue(service.pendingRestore)
    }

    func testBackupAcceptsMaximumSizePresetArchive() async throws {
        var archive = try JSONEncoder().encode(PresetArchive(items: []))
        archive.append(Data(repeating: 32, count: WallpaperPresetStore.maximumDocumentBytes - archive.count))
        try WallpaperPresetStore.validateArchiveData(archive)
        let preferences = WallpaperBackupPreferences(values: [
            "WallpaperMachine.wallpaperPresets": try WallpaperBackupPreferences.encode(archive),
        ])
        let service = WallpaperBackupService(supportRoot: source)
        try service.export(to: package, includeLibrary: false, preferences: preferences)
        let preview = try service.preview(package: package, preferences: .init(values: [:]))
        XCTAssertEqual(preview.presetCount, 0)
        let manifest = try json("manifest.json", in: package)
        let values = try XCTUnwrap(manifest["preferences"] as? [String: String])
        let bytes = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(values["WallpaperMachine.wallpaperPresets"])))
        XCTAssertEqual(try WallpaperBackupPreferences.decode(bytes) as? Data, archive)
    }

    func testManifestLimitFailsBeforeOpeningPayloadAndPreservesExistingPackage() async throws {
        try put("payload", "UserAssets/asset.bin", in: source)
        let asset = source.appendingPathComponent("UserAssets/asset.bin")
        XCTAssertEqual(chmod(asset.path, 0), 0)
        defer { _ = chmod(asset.path, 0o600) }
        XCTAssertThrowsError(try FileHandle(forReadingFrom: asset))
        try put("previous backup", "sentinel", in: package)
        var limits = WallpaperBackupLimits()
        limits.maximumManifestBytes = 1
        let service = WallpaperBackupService(supportRoot: source, limits: limits)
        XCTAssertThrowsError(try service.export(to: package, includeLibrary: false, preferences: .init(values: [:]))) { error in
            XCTAssertEqual(error as? WallpaperBackupFailure, WallpaperBackupFiles(limits: limits).oversized())
        }
        XCTAssertEqual(try String(contentsOf: package.appendingPathComponent("sentinel"), encoding: .utf8), "previous backup")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".wmbackup-export-") })
    }

    func testExportPreviewPendingAndIsolatedStartupRoundtripRemapsRetainedPaths() async throws {
        let original = try fixture()
        let targetDefaults = try defaults()
        let exporter = WallpaperBackupService(supportRoot: source)
        try exporter.export(to: package, includeLibrary: true, preferences: .init(defaults: original, domainName: domainName(for: original)))
        let importer = WallpaperBackupService(supportRoot: destination)
        let preview = try importer.preview(package: package, preferences: .init(defaults: targetDefaults, domainName: domainName(for: targetDefaults)))
        XCTAssertEqual(preview.wallpaperCount, 1)
        XCTAssertEqual(preview.presetCount, 1)
        XCTAssertEqual(preview.collectionCount, 1)
        let manifest = try json("manifest.json", in: package)
        let exportedPreferences = try XCTUnwrap(manifest["preferences"] as? [String: Any])
        XCTAssertNil(exportedPreferences["WallpaperMachine.steamCookie"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: package.appendingPathComponent("data/SteamCMD").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: package.appendingPathComponent("data/Logs").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: package.appendingPathComponent("data/Cache").path))
        try importer.stageRestore(package: package, preview: preview, policy: .replace)
        XCTAssertTrue(importer.pendingRestore)
        XCTAssertNil(targetDefaults.object(forKey: "WallpaperMachine.otherAudioAction"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("config.toml").path))
        // The staged package is complete and independent of the selected source.
        try FileManager.default.removeItem(at: package)
        let report = try XCTUnwrap(WallpaperBackupService.applyPendingRestore(supportRoot: destination, defaults: targetDefaults, domainName: domainName(for: targetDefaults)))
        XCTAssertTrue(report.restoredPaths.contains("Library/101"))
        XCTAssertEqual(targetDefaults.string(forKey: "WallpaperMachine.otherAudioAction"), "mute")
        let overrides = try XCTUnwrap(json("wallpapers/101.json", in: destination)["property_overrides"] as? [String: String])
        XCTAssertEqual(overrides["photo"], destination.appendingPathComponent("UserAssets/101/photo/asset/画 像.png").path)
        let presetJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(targetDefaults.data(forKey: "WallpaperMachine.wallpaperPresets"))) as? [String: Any])
        let preset = try XCTUnwrap((presetJSON["items"] as? [[String: Any]])?.first)
        let property = try XCTUnwrap((preset["properties"] as? [[String: Any]])?.first)
        XCTAssertEqual(property["retainedPath"] as? String, destination.appendingPathComponent("UserAssets/PresetAssets/\(presetID)/photo/retained.png").path)
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("UserAssets/101/photo/asset/manifest.json"), encoding: .utf8), "do not parse or rewrite me")
        XCTAssertFalse(importer.pendingRestore)
        XCTAssertNil(try WallpaperBackupService.applyPendingRestore(supportRoot: destination, defaults: targetDefaults, domainName: domainName(for: targetDefaults)))
    }

    func testMovedLibraryIsBackedUpFromAndRestoredToWhereItIsKept() async throws {
        let original = try fixture()
        let targetDefaults = try defaults()
        // Both Macs keep the library on another disk (Settings › Storage).
        let sourceDrive = root.appendingPathComponent("source-drive")
        let destinationDrive = root.appendingPathComponent("destination-drive")
        try FileManager.default.createDirectory(at: sourceDrive, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationDrive, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: source.appendingPathComponent("Library"), to: sourceDrive.appendingPathComponent("Library"))
        // A file property that names a file inside the wallpaper's own folder.
        try put(#"{"title":"Original","type":"scene","file":"scene.json","general":{"properties":{"photo":{"type":"file","value":""},"backdrop":{"type":"file","value":""}}}}"#,
                "Library/101/project.json", in: sourceDrive)
        let backdrop = sourceDrive.appendingPathComponent("Library/101/scene.json").path
        try put(#"{"workshop_id":"101","type":"scene","property_overrides":{"photo":"PHOTO","backdrop":"BACKDROP"}}"#
            .replacingOccurrences(of: "PHOTO", with: source.appendingPathComponent("UserAssets/101/photo/asset/画 像.png").path)
            .replacingOccurrences(of: "BACKDROP", with: backdrop), "wallpapers/101.json", in: source)

        let exporter = WallpaperBackupService(supportRoot: source, storageRoot: sourceDrive)
        try exporter.export(to: package, includeLibrary: true, preferences: .init(defaults: original, domainName: domainName(for: original)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: package.appendingPathComponent("data/Library/101/scene.json").path))

        let importer = WallpaperBackupService(supportRoot: destination, storageRoot: destinationDrive)
        let preview = try importer.preview(package: package, preferences: .init(defaults: targetDefaults, domainName: domainName(for: targetDefaults)))
        XCTAssertEqual(preview.wallpaperCount, 1)
        try importer.stageRestore(package: package, preview: preview, policy: .replace)
        let report = try XCTUnwrap(WallpaperBackupService.applyPendingRestore(
            supportRoot: destination, storageRoot: destinationDrive, defaults: targetDefaults, domainName: domainName(for: targetDefaults)))
        XCTAssertTrue(report.restoredPaths.contains("Library/101"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destinationDrive.appendingPathComponent("Library/101/scene.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("Library").path),
                       "the library is restored where it is kept, not into app support")
        let overrides = try XCTUnwrap(json("wallpapers/101.json", in: destination)["property_overrides"] as? [String: String])
        XCTAssertEqual(overrides["photo"], destination.appendingPathComponent("UserAssets/101/photo/asset/画 像.png").path)
        XCTAssertEqual(overrides["backdrop"], destinationDrive.appendingPathComponent("Library/101/scene.json").path)
    }

    func testKeepExistingPreservesCollidingWallpaperAndImportsIndependentCollectionsAndPresetBytes() async throws {
        let original = try fixture()
        let targetDefaults = try defaults()
        try put("old config", "config.toml", in: destination)
        try put(#"{"type":"scene","workshop_id":"101","property_overrides":{}}"#, "wallpapers/101.json", in: destination)
        try put(#"{"title":"Keep me","type":"scene"}"#, "Library/101/project.json", in: destination)
        targetDefaults.set("pause", forKey: "WallpaperMachine.otherAudioAction")
        targetDefaults.set(try JSONSerialization.data(withJSONObject: [
            ["id": "collection-one", "name": "Keep collection", "wallpaperIDs": ["old"]],
            ["id": "collection-existing", "name": "Existing", "wallpaperIDs": ["old"]],
        ]), forKey: "WallpaperMachine.collections")
        let existing = WallpaperPropertyPreset(id: existingPresetID, wallpaperID: "101", name: "Existing", properties: [])
        targetDefaults.set(try JSONEncoder().encode(PresetArchive(items: [existing])), forKey: "WallpaperMachine.wallpaperPresets")
        try put("old preset", "UserAssets/PresetAssets/\(existingPresetID)/photo/old.png", in: destination)
        try WallpaperBackupService(supportRoot: source).export(to: package, includeLibrary: true, preferences: .init(defaults: original, domainName: domainName(for: original)))
        let importer = WallpaperBackupService(supportRoot: destination)
        let preview = try importer.preview(package: package, preferences: .init(defaults: targetDefaults, domainName: domainName(for: targetDefaults)))
        XCTAssertTrue(preview.conflicts.contains("Library/101"))
        XCTAssertTrue(preview.conflicts.contains("Preferences/WallpaperMachine.collections"))
        try importer.stageRestore(package: package, preview: preview, policy: .keepExisting)
        _ = try importer.applyPendingRestore(defaults: targetDefaults, domainName: domainName(for: targetDefaults))
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("config.toml"), encoding: .utf8), "old config")
        XCTAssertEqual(try json("Library/101/project.json", in: destination)["title"] as? String, "Keep me")
        XCTAssertEqual(targetDefaults.string(forKey: "WallpaperMachine.otherAudioAction"), "pause")
        let collections = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(targetDefaults.data(forKey: "WallpaperMachine.collections"))) as? [[String: Any]])
        XCTAssertEqual(collections.first?["name"] as? String, "Keep collection")
        let presets = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(targetDefaults.data(forKey: "WallpaperMachine.wallpaperPresets"))) as? [String: Any])
        XCTAssertEqual(Set((presets["items"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }), [existingPresetID, presetID])
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("UserAssets/PresetAssets/\(presetID)/photo/retained.png"), encoding: .utf8), "preset bytes")
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("UserAssets/PresetAssets/\(existingPresetID)/photo/old.png"), encoding: .utf8), "old preset")
    }

    func testReplaceChangesConflictingStateButKeepsUnrelatedWallpaper() async throws {
        let original = try fixture()
        let targetDefaults = try defaults()
        try put("old config", "config.toml", in: destination)
        try put(#"{"title":"Unrelated","type":"web"}"#, "Library/999/project.json", in: destination)
        targetDefaults.set("pause", forKey: "WallpaperMachine.otherAudioAction")
        try WallpaperBackupService(supportRoot: source).export(to: package, includeLibrary: false, preferences: .init(defaults: original, domainName: domainName(for: original)))
        let importer = WallpaperBackupService(supportRoot: destination)
        let preview = try importer.preview(package: package, preferences: .init(defaults: targetDefaults, domainName: domainName(for: targetDefaults)))
        XCTAssertFalse(preview.includesLibrary)
        XCTAssertTrue(preview.warnings.contains(where: { $0.contains("101") }))
        try importer.stageRestore(package: package, preview: preview, policy: .replace)
        _ = try importer.applyPendingRestore(defaults: targetDefaults, domainName: domainName(for: targetDefaults))
        XCTAssertEqual(targetDefaults.string(forKey: "WallpaperMachine.otherAudioAction"), "mute")
        XCTAssertEqual(try json("Library/999/project.json", in: destination)["title"] as? String, "Unrelated")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("Library/101").path))
    }

    func testFailureAfterPublicationRollsBackAllFilesAndPreferencesAndRetainsPending() async throws {
        let original = try fixture()
        let targetDefaults = try defaults()
        try put("old config", "config.toml", in: destination)
        targetDefaults.set("pause", forKey: "WallpaperMachine.otherAudioAction")
        try WallpaperBackupService(supportRoot: source).export(to: package, includeLibrary: true, preferences: .init(defaults: original, domainName: domainName(for: original)))
        let importer = WallpaperBackupService(supportRoot: destination)
        let preview = try importer.preview(package: package, preferences: .init(defaults: targetDefaults, domainName: domainName(for: targetDefaults)))
        try importer.stageRestore(package: package, preview: preview, policy: .replace)
        XCTAssertThrowsError(try importer.applyPendingRestore(defaults: targetDefaults, domainName: domainName(for: targetDefaults), beforePublish: { path in
            if path == "Preferences" { throw CocoaError(.fileWriteOutOfSpace) }
        }))
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("config.toml"), encoding: .utf8), "old config")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("Library/101").path))
        XCTAssertEqual(targetDefaults.string(forKey: "WallpaperMachine.otherAudioAction"), "pause")
        XCTAssertNil(targetDefaults.object(forKey: "WallpaperMachine.collections"))
        XCTAssertTrue(importer.pendingRestore)
        _ = try importer.applyPendingRestore(defaults: targetDefaults, domainName: domainName(for: targetDefaults))
        XCTAssertEqual(targetDefaults.string(forKey: "WallpaperMachine.otherAudioAction"), "mute")
    }

    func testRestoreIntoAMovedLibraryKeepsItsOldCopyBesideTheLibraryAndPutsItBack() async throws {
        let original = try fixture()
        let targetDefaults = try defaults()
        let destinationDrive = root.appendingPathComponent("destination-drive")
        try put(#"{"title":"Local","type":"scene","file":"scene.json"}"#, "Library/101/project.json", in: destinationDrive)
        try WallpaperBackupService(supportRoot: source).export(to: package, includeLibrary: true, preferences: .init(defaults: original, domainName: domainName(for: original)))
        let importer = WallpaperBackupService(supportRoot: destination, storageRoot: destinationDrive)
        let preview = try importer.preview(package: package, preferences: .init(defaults: targetDefaults, domainName: domainName(for: targetDefaults)))
        try importer.stageRestore(package: package, preview: preview, policy: .replace)
        let libraryTransaction = destinationDrive.appendingPathComponent(WallpaperBackupService.transactionDirectoryName)
        let supportTransaction = destination.appendingPathComponent(WallpaperBackupService.transactionDirectoryName)
        var oldCopyBesideTheLibrary = false
        var oldCopyInSupport = true
        XCTAssertThrowsError(try importer.applyPendingRestore(defaults: targetDefaults, domainName: domainName(for: targetDefaults), beforePublish: { path in
            guard path == "Preferences" else { return }
            // Every move of a library unit was a rename on the library's own disk.
            oldCopyBesideTheLibrary = FileManager.default.fileExists(atPath: libraryTransaction.appendingPathComponent("old/Library/101/project.json").path)
            oldCopyInSupport = FileManager.default.fileExists(atPath: supportTransaction.appendingPathComponent("old/Library").path)
            throw CocoaError(.fileWriteOutOfSpace)
        }))
        XCTAssertTrue(oldCopyBesideTheLibrary)
        XCTAssertFalse(oldCopyInSupport)
        XCTAssertEqual(try json("Library/101/project.json", in: destinationDrive)["title"] as? String, "Local", "recovery puts the old copy back")
        XCTAssertFalse(FileManager.default.fileExists(atPath: libraryTransaction.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: supportTransaction.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("Library").path))

        _ = try importer.applyPendingRestore(defaults: targetDefaults, domainName: domainName(for: targetDefaults))
        XCTAssertEqual(try json("Library/101/project.json", in: destinationDrive)["title"] as? String, "Original")
        XCTAssertFalse(FileManager.default.fileExists(atPath: libraryTransaction.path))
    }

    func testRecoveryWaitsForTheLibraryDriveInsteadOfAnEmptyMountPoint() async throws {
        let original = try fixture()
        let targetDefaults = try defaults()
        let drive = root.appendingPathComponent("drive")
        let unplugged = root.appendingPathComponent("unplugged")
        try put(#"{"title":"Local","type":"scene","file":"scene.json"}"#, "Library/101/project.json", in: drive)
        try StorageLocation.writeMarker("drive-id", at: drive)
        try WallpaperBackupService(supportRoot: source).export(to: package, includeLibrary: true, preferences: .init(defaults: original, domainName: domainName(for: original)))
        let importer = WallpaperBackupService(supportRoot: destination, storageRoot: drive)
        let preview = try importer.preview(package: package, preferences: .init(defaults: targetDefaults, domainName: domainName(for: targetDefaults)))
        try importer.stageRestore(package: package, preview: preview, policy: .replace)
        // The drive goes away part-way and leaves its empty mount point behind.
        XCTAssertThrowsError(try importer.applyPendingRestore(defaults: targetDefaults, domainName: domainName(for: targetDefaults), beforePublish: { path in
            guard path == "Preferences" else { return }
            try FileManager.default.moveItem(at: drive, to: unplugged)
            try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
            throw CocoaError(.fileWriteOutOfSpace)
        }))
        let transaction = destination.appendingPathComponent(WallpaperBackupService.transactionDirectoryName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: transaction.appendingPathComponent("journal.json").path), "the journal waits for the drive")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: drive.path).isEmpty, "nothing is written to the mount point")

        // The drive is back: the next launch puts the wallpaper it replaced back first.
        try FileManager.default.removeItem(at: drive)
        try FileManager.default.moveItem(at: unplugged, to: drive)
        _ = try importer.applyPendingRestore(defaults: targetDefaults, domainName: domainName(for: targetDefaults))
        XCTAssertFalse(FileManager.default.fileExists(atPath: transaction.path))
        XCTAssertEqual(try json("Library/101/project.json", in: drive)["title"] as? String, "Original")
    }

    func testInterruptedUncommittedJournalRestoresOriginalBeforeStoresReadPreferences() async throws {
        let targetDefaults = try defaults()
        let transaction = destination.appendingPathComponent(WallpaperBackupService.transactionDirectoryName)
        try put("original", "old/config.toml", in: transaction)
        try put("half published", "config.toml", in: destination)
        targetDefaults.set("mute", forKey: "WallpaperMachine.otherAudioAction")
        let original = try WallpaperBackupPreferences.encode("pause")
        let journal = WallpaperBackupJournal(units: [.init(path: "config.toml", existed: true)],
            originalPreferences: ["WallpaperMachine.otherAudioAction": original], absentPreferences: [])
        try JSONEncoder().encode(journal).write(to: transaction.appendingPathComponent("journal.json"))
        let report = try XCTUnwrap(WallpaperBackupService.applyPendingRestore(supportRoot: destination, defaults: targetDefaults, domainName: domainName(for: targetDefaults)))
        XCTAssertTrue(report.recoveredInterruptedRestore)
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("config.toml"), encoding: .utf8), "original")
        XCTAssertEqual(targetDefaults.string(forKey: "WallpaperMachine.otherAudioAction"), "pause")
        XCTAssertFalse(FileManager.default.fileExists(atPath: transaction.path))
    }

    func testChangedPackageCannotStageOverAnExistingPendingRestore() async throws {
        let original = try fixture()
        let targetDefaults = try defaults()
        try WallpaperBackupService(supportRoot: source).export(to: package, includeLibrary: true, preferences: .init(defaults: original, domainName: domainName(for: original)))
        let importer = WallpaperBackupService(supportRoot: destination)
        let preview = try importer.preview(package: package, preferences: .init(defaults: targetDefaults, domainName: domainName(for: targetDefaults)))
        try importer.stageRestore(package: package, preview: preview, policy: .replace)
        try put("changed bytes", "data/Library/101/scene.json", in: package)
        XCTAssertThrowsError(try importer.stageRestore(package: package, preview: preview, policy: .keepExisting))
        XCTAssertTrue(importer.pendingRestore)
        _ = try importer.applyPendingRestore(defaults: targetDefaults, domainName: domainName(for: targetDefaults))
        XCTAssertEqual(try json("Library/101/scene.json", in: destination)["layers"] as? [String], [])
    }

    func testTraversalLinksSpecialFilesAndDisallowedPreferencesAreRejected() async throws {
        let original = try fixture()
        let importer = WallpaperBackupService(supportRoot: destination)
        let emptyDefaults = try defaults()
        let preferences = try WallpaperBackupPreferences(defaults: emptyDefaults, domainName: domainName(for: emptyDefaults))
        try WallpaperBackupService(supportRoot: source).export(to: package, includeLibrary: true, preferences: .init(defaults: original, domainName: domainName(for: original)))
        try FileManager.default.createSymbolicLink(at: package.appendingPathComponent("data/Library/101/escape"), withDestinationURL: root)
        XCTAssertThrowsError(try importer.preview(package: package, preferences: preferences))
        try FileManager.default.removeItem(at: package.appendingPathComponent("data/Library/101/escape"))
        let fifo = package.appendingPathComponent("data/Library/101/fifo")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertThrowsError(try importer.preview(package: package, preferences: preferences))
        try FileManager.default.removeItem(at: fifo)
        let hardLink = package.appendingPathComponent("data/Library/101/hardlink")
        try FileManager.default.linkItem(at: package.appendingPathComponent("data/Library/101/scene.json"), to: hardLink)
        XCTAssertThrowsError(try importer.preview(package: package, preferences: preferences))
        try FileManager.default.removeItem(at: hardLink)
        var manifest = try json("manifest.json", in: package)
        var entries = try XCTUnwrap(manifest["entries"] as? [[String: Any]])
        entries[0]["path"] = "../escape"
        manifest["entries"] = entries
        try JSONSerialization.data(withJSONObject: manifest).write(to: package.appendingPathComponent("manifest.json"))
        XCTAssertThrowsError(try importer.preview(package: package, preferences: preferences))
        XCTAssertThrowsError(try WallpaperBackupService(supportRoot: source).export(to: root.appendingPathComponent("Forbidden.wmbackup"), includeLibrary: false,
            preferences: .init(values: ["WallpaperMachine.steamCookie": WallpaperBackupPreferences.encode("secret")])))
    }

    func testCopyLimitsAndCancelledExportLeaveNoPublishedPackage() async throws {
        let original = try fixture()
        var limits = WallpaperBackupLimits()
        limits.maximumBytes = 8
        let bounded = WallpaperBackupService(supportRoot: source, limits: limits)
        XCTAssertThrowsError(try bounded.export(to: package, includeLibrary: true, preferences: .init(defaults: original, domainName: domainName(for: original))))
        XCTAssertFalse(FileManager.default.fileExists(atPath: package.path))
        let service = WallpaperBackupService(supportRoot: source)
        let preferences = try WallpaperBackupPreferences(defaults: original, domainName: domainName(for: original))
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try service.export(to: package, includeLibrary: true, preferences: preferences)
        }
        do { try await cancelled.value; XCTFail("A cancelled copy must not publish") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: package.path))
    }

    func testStoreStagesWithoutMutatingRunningPreferencesAndCancelsPending() async throws {
        let original = try fixture()
        let targetDefaults = try defaults()
        try WallpaperBackupService(supportRoot: source).export(to: package, includeLibrary: true, preferences: .init(defaults: original, domainName: domainName(for: original)))
        let store = WallpaperBackupStore(service: .init(supportRoot: destination), defaults: targetDefaults, domainName: domainName(for: targetDefaults),
            exportDestination: { nil }, restoreSource: { self.package })
        try await store.choosePreview()
        try await store.stageRestore(policy: .replace)
        XCTAssertTrue(store.pendingRestore)
        XCTAssertNil(targetDefaults.object(forKey: "WallpaperMachine.otherAudioAction"))
        try store.cancelRestore()
        XCTAssertFalse(store.pendingRestore)
        XCTAssertNil(try WallpaperBackupService.applyPendingRestore(supportRoot: destination, defaults: targetDefaults, domainName: domainName(for: targetDefaults)))
    }

    func testStartupRestoredPreferencesHydrateRealPresetCollectionPlanAndPlacementStores() async throws {
        struct Archive: Codable { var version = 1; var items: [WallpaperPropertyPreset] }
        let original = try fixture()
        let targetDefaults = try defaults()
        let presetID = "00000000-0000-4000-8000-000000000001"
        let assetPath = "UserAssets/PresetAssets/\(presetID)/photo/retained.png"
        try put("retained by the preset", assetPath, in: source)
        let sourceAsset = source.appendingPathComponent(assetPath).path
        let property = WallpaperPresetProperty(id: "photo", kind: "file", value: .string(sourceAsset),
            usesDefault: false, retainedPath: sourceAsset)
        let preset = WallpaperPropertyPreset(id: presetID, wallpaperID: "101", name: "Night", properties: [property])
        original.set(try JSONEncoder().encode(Archive(items: [preset])), forKey: WallpaperPresetStore.preferenceKey)
        let collections = WallpaperCollectionStore(defaults: original)
        let collection = try collections.create(name: "Night collection", wallpaperIDs: ["101"])
        let playlists = PlaylistStore(defaults: original)
        playlists.update("display-one") {
            $0.mode = .rotate
            $0.source = .collection
            $0.collectionID = collection.id
            $0.interval = 45
            $0.trigger = .unlock
        }
        let plan = try playlists.savePlan(from: "display-one", name: "Night plan")
        let placement = try StillImagePlacement(x: 0.2, y: 0.7, zoom: 1.5)
        try StillImagePlacementStore(defaults: original, library: source.appendingPathComponent("Library"))
            .set(placement, wallpaperID: "image-test", displayID: "display-one")
        try WallpaperBackupService(supportRoot: source).export(to: package, includeLibrary: true, preferences: .init(defaults: original, domainName: domainName(for: original)))
        let service = WallpaperBackupService(supportRoot: destination)
        let preview = try service.preview(package: package, preferences: .init(defaults: targetDefaults, domainName: domainName(for: targetDefaults)))
        try service.stageRestore(package: package, preview: preview, policy: .replace)
        _ = try WallpaperBackupService.applyPendingRestore(supportRoot: destination, defaults: targetDefaults, domainName: domainName(for: targetDefaults))
        let restoredPresets = WallpaperPresetStore(defaults: targetDefaults,
            managed: ManagedUserAssetStore(root: destination.appendingPathComponent("UserAssets")))
        let restoredProperty = try XCTUnwrap(restoredPresets.preset(id: presetID).properties.first)
        let destinationAsset = destination.appendingPathComponent(assetPath).path
        XCTAssertEqual(restoredProperty.retainedPath, destinationAsset)
        XCTAssertEqual(restoredProperty.value, .string(destinationAsset))
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: destinationAsset), encoding: .utf8), "retained by the preset")
        XCTAssertEqual(WallpaperCollectionStore(defaults: targetDefaults).collection(id: collection.id), collection)
        let restoredPlaylists = PlaylistStore(defaults: targetDefaults)
        XCTAssertEqual(restoredPlaylists.plan(id: plan.id), plan)
        XCTAssertEqual(restoredPlaylists.playlist(for: "display-one").collectionID, collection.id)
        XCTAssertEqual(restoredPlaylists.playlist(for: "display-one").trigger, .unlock, "a playlist that changes on unlock restores as one")
        XCTAssertEqual(restoredPlaylists.plan(id: plan.id)?.playlist.trigger, .unlock)
        XCTAssertEqual(StillImagePlacementStore(defaults: targetDefaults, library: destination.appendingPathComponent("Library"))
            .placement(wallpaperID: "image-test", displayID: "display-one"), placement)
    }

    func testCommittedRecoveryCleansPendingWithoutRollingBackOrReapplying() async throws {
        let targetDefaults = try defaults()
        let transaction = destination.appendingPathComponent(WallpaperBackupService.transactionDirectoryName)
        try put("old", "old/config.toml", in: transaction)
        try put("committed new", "config.toml", in: destination)
        try put("stale pending bytes", "manifest.json", in: destination.appendingPathComponent(WallpaperBackupService.pendingDirectoryName))
        targetDefaults.set("mute", forKey: "WallpaperMachine.otherAudioAction")
        var journal = WallpaperBackupJournal(units: [.init(path: "config.toml", existed: true)],
            originalPreferences: ["WallpaperMachine.otherAudioAction": try WallpaperBackupPreferences.encode("pause")], absentPreferences: [])
        journal.preferencesCommitted = true
        try JSONEncoder().encode(journal).write(to: transaction.appendingPathComponent("journal.json"))
        let report = try XCTUnwrap(WallpaperBackupService.applyPendingRestore(supportRoot: destination, defaults: targetDefaults, domainName: domainName(for: targetDefaults)))
        XCTAssertTrue(report.recoveredInterruptedRestore)
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("config.toml"), encoding: .utf8), "committed new")
        XCTAssertEqual(targetDefaults.string(forKey: "WallpaperMachine.otherAudioAction"), "mute")
        XCTAssertFalse(WallpaperBackupService(supportRoot: destination).pendingRestore)
        XCTAssertNil(try WallpaperBackupService.applyPendingRestore(supportRoot: destination, defaults: targetDefaults, domainName: domainName(for: targetDefaults)))
    }

    func testNonFinitePreferencesUnknownVersionsAndCaseAliasedPathsCannotBeRestored() async throws {
        let original = try fixture()
        let targetDefaults = try defaults()
        let exporter = WallpaperBackupService(supportRoot: source)
        XCTAssertThrowsError(try exporter.export(to: package, includeLibrary: false, preferences: .init(values: [
            "WallpaperMachine.playlistNextChange": try WallpaperBackupPreferences.encode(["screen": Double.infinity]),
        ])))
        try exporter.export(to: package, includeLibrary: true, preferences: .init(defaults: original, domainName: domainName(for: original)))
        let importer = WallpaperBackupService(supportRoot: destination)
        let preferences = try WallpaperBackupPreferences(defaults: targetDefaults, domainName: domainName(for: targetDefaults))
        let manifestURL = package.appendingPathComponent("manifest.json")
        let baseline = try Data(contentsOf: manifestURL)
        var manifest = try json("manifest.json", in: package)
        manifest["version"] = 2
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
        XCTAssertThrowsError(try importer.preview(package: package, preferences: preferences))
        try baseline.write(to: manifestURL)
        manifest = try json("manifest.json", in: package)
        var entries = try XCTUnwrap(manifest["entries"] as? [[String: Any]])
        var duplicate = try XCTUnwrap(entries.first(where: { ($0["path"] as? String) == "Library/101/scene.json" }))
        duplicate["path"] = "Library/101/SCENE.JSON"
        entries.append(duplicate)
        manifest["entries"] = entries
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
        XCTAssertThrowsError(try importer.preview(package: package, preferences: preferences))
        XCTAssertFalse(importer.pendingRestore)
        XCTAssertNil(targetDefaults.object(forKey: "WallpaperMachine.otherAudioAction"))
    }

    func testStartupFailureIsVisibleAndDoesNotRetryUntilExplicitlyRestaged() async throws {
        let original = try fixture()
        let targetDefaults = try defaults()
        try put("old current config", "config.toml", in: destination)
        targetDefaults.set("pause", forKey: "WallpaperMachine.otherAudioAction")
        try WallpaperBackupService(supportRoot: source).export(to: package, includeLibrary: true, preferences: .init(defaults: original, domainName: domainName(for: original)))
        let service = WallpaperBackupService(supportRoot: destination)
        let preview = try service.preview(package: package, preferences: .init(defaults: targetDefaults, domainName: domainName(for: targetDefaults)))
        try service.stageRestore(package: package, preview: preview, policy: .replace)
        let pending = destination.appendingPathComponent(WallpaperBackupService.pendingDirectoryName)
        try put("corrupted pending bytes", "data/config.toml", in: pending)
        XCTAssertThrowsError(try WallpaperBackupService.applyPendingRestore(supportRoot: destination, defaults: targetDefaults, domainName: domainName(for: targetDefaults)))
        let store = WallpaperBackupStore(service: service, defaults: targetDefaults, domainName: domainName(for: targetDefaults),
            exportDestination: { nil }, restoreSource: { self.package })
        XCTAssertNotNil(store.error)
        XCTAssertTrue(store.pendingRestore)
        XCTAssertNil(try WallpaperBackupService.applyPendingRestore(supportRoot: destination, defaults: targetDefaults, domainName: domainName(for: targetDefaults)))
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("config.toml"), encoding: .utf8), "old current config")
        XCTAssertEqual(targetDefaults.string(forKey: "WallpaperMachine.otherAudioAction"), "pause")
        try await store.choosePreview()
        try await store.stageRestore(policy: .replace)
        _ = try WallpaperBackupService.applyPendingRestore(supportRoot: destination, defaults: targetDefaults, domainName: domainName(for: targetDefaults))
        XCTAssertEqual(targetDefaults.string(forKey: "WallpaperMachine.otherAudioAction"), "mute")
        XCTAssertFalse(service.pendingRestore)
        XCTAssertNil(service.lastStartupError)
    }

    func testManagedPathsFromSymlinkedSupportOverrideRemainPortableAfterOriginalDisappears() async throws {
        let original = try fixture()
        let targetDefaults = try defaults()
        let alias = root.appendingPathComponent("source-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
        let configURL = source.appendingPathComponent("wallpapers/101.json")
        let aliasedConfig = try String(contentsOf: configURL, encoding: .utf8)
            .replacingOccurrences(of: source.path, with: alias.path)
        try Data(aliasedConfig.utf8).write(to: configURL)
        try WallpaperBackupService(supportRoot: alias).export(to: package, includeLibrary: true, preferences: .init(defaults: original, domainName: domainName(for: original)))
        let service = WallpaperBackupService(supportRoot: destination)
        let preview = try service.preview(package: package, preferences: .init(defaults: targetDefaults, domainName: domainName(for: targetDefaults)))
        try service.stageRestore(package: package, preview: preview, policy: .replace)
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.removeItem(at: source)
        _ = try WallpaperBackupService.applyPendingRestore(supportRoot: destination, defaults: targetDefaults, domainName: domainName(for: targetDefaults))
        let overrides = try XCTUnwrap(json("wallpapers/101.json", in: destination)["property_overrides"] as? [String: String])
        XCTAssertEqual(overrides["photo"], destination.appendingPathComponent("UserAssets/101/photo/asset/画 像.png").path)
    }

    private func replaceManifestPreference(_ key: String, value: Any) throws {
        var manifest = try json("manifest.json", in: package)
        var preferences = try XCTUnwrap(manifest["preferences"] as? [String: Any])
        preferences[key] = try WallpaperBackupPreferences.encode(value).base64EncodedString()
        manifest["preferences"] = preferences
        try JSONSerialization.data(withJSONObject: manifest).write(to: package.appendingPathComponent("manifest.json"))
    }

    func testLowBatteryChoicesAreBackedUpAndOnlyOfferedValuesRestore() throws {
        let preferences = try defaults()
        preferences.set("stop", forKey: "WallpaperMachine.lowBatteryAction")
        preferences.set(30, forKey: "WallpaperMachine.lowBatteryThreshold")
        let export = try WallpaperBackupPreferences(defaults: preferences, domainName: domainName(for: preferences))
        for (key, expected) in [("WallpaperMachine.lowBatteryAction", "stop" as Any), ("WallpaperMachine.lowBatteryThreshold", 30 as Any)] {
            let stored = try WallpaperBackupPreferences.decode(XCTUnwrap(export.values[key], key))
            try WallpaperBackupPreferences.validate(stored, forKey: key)
            XCTAssertEqual("\(stored)", "\(expected)")
        }
        let conditionKeys = ["WallpaperMachine.lowPowerModeAction", "WallpaperMachine.thermalAction", "WallpaperMachine.lowBatteryAction"]
        for key in conditionKeys {
            for action in ["keepRunning", "reduceQuality", "pause", "stop"] {
                XCTAssertNoThrow(try WallpaperBackupPreferences.validate(action, forKey: key), "\(action) for \(key)")
            }
        }
        for level in [10, 20, 30] {
            XCTAssertNoThrow(try WallpaperBackupPreferences.validate(NSNumber(value: level), forKey: "WallpaperMachine.lowBatteryThreshold"))
        }
        for key in conditionKeys {
            // "reducedQuality" is the on-battery mode's name, not a condition action.
            for action: Any in ["nap", "", "reducedQuality", 1, true] {
                XCTAssertThrowsError(try WallpaperBackupPreferences.validate(action, forKey: key), "\(action) for \(key)")
            }
        }
        for level: Any in [0, 15, 25, 31, -20, 20.5, "20", true, NSNumber(value: 1e30)] {
            XCTAssertThrowsError(try WallpaperBackupPreferences.validate(level, forKey: "WallpaperMachine.lowBatteryThreshold"), "\(level)")
        }
    }

    func testPlayingOnlyOnTheActiveDisplayIsBackedUpAndOnlyABooleanRestores() throws {
        let preferences = try defaults()
        preferences.set(true, forKey: "WallpaperMachine.playOnlyOnActiveDisplay")
        let export = try WallpaperBackupPreferences(defaults: preferences, domainName: domainName(for: preferences))
        let key = "WallpaperMachine.playOnlyOnActiveDisplay"

        let stored = try WallpaperBackupPreferences.decode(XCTUnwrap(export.values[key], key))
        try WallpaperBackupPreferences.validate(stored, forKey: key)
        XCTAssertEqual(stored as? Bool, true)
        for value: Any in [true, false] {
            XCTAssertNoThrow(try WallpaperBackupPreferences.validate(value, forKey: key), "\(value)")
        }
        for value: Any in ["yes", 1, 0, 2.5, NSNull(), ["true"]] {
            XCTAssertThrowsError(try WallpaperBackupPreferences.validate(value, forKey: key), "\(value)")
        }
    }

    /// Muting every wallpaper is local to this Mac: a backup never carries it, and a package that
    /// claims to cannot silence a Mac whose owner did not ask.
    func testMutingEveryWallpaperIsNeitherBackedUpNorRestored() async throws {
        let original = try fixture()
        original.set(true, forKey: "WallpaperMachine.wallpapersMuted")
        original.set(true, forKey: "WallpaperMachine.playOnlyOnActiveDisplay")
        let export = try WallpaperBackupPreferences(defaults: original, domainName: domainName(for: original))
        XCTAssertNotNil(export.values["WallpaperMachine.playOnlyOnActiveDisplay"], "a neighbouring playback choice is backed up")
        XCTAssertNil(export.values["WallpaperMachine.wallpapersMuted"])

        let live = try defaults()
        try WallpaperBackupService(supportRoot: source).export(to: package, includeLibrary: true, preferences: export)
        let service = WallpaperBackupService(supportRoot: destination)
        try replaceManifestPreference("WallpaperMachine.playOnlyOnActiveDisplay", value: false)
        XCTAssertNoThrow(try service.preview(package: package, preferences: .init(defaults: live, domainName: domainName(for: live))),
                         "an allowed playback choice in the same package is fine")
        try replaceManifestPreference("WallpaperMachine.wallpapersMuted", value: true)
        XCTAssertThrowsError(try service.preview(package: package, preferences: .init(defaults: live, domainName: domainName(for: live))))
    }

    func testStructuredPreferenceRejectionPreservesPendingAndLiveArchive() async throws {
        let original = try fixture()
        let live = try defaults()
        let archive = try XCTUnwrap(original.data(forKey: "WallpaperMachine.wallpaperPresets"))
        live.set(archive, forKey: "WallpaperMachine.wallpaperPresets")
        let service = WallpaperBackupService(supportRoot: destination)
        try WallpaperBackupService(supportRoot: source).export(to: package, includeLibrary: true, preferences: .init(defaults: original, domainName: domainName(for: original)))
        let preview = try service.preview(package: package, preferences: .init(defaults: live, domainName: domainName(for: live)))
        try service.stageRestore(package: package, preview: preview, policy: .replace)
        let pendingManifest = destination.appendingPathComponent("\(WallpaperBackupService.pendingDirectoryName)/manifest.json")
        let baseline = try Data(contentsOf: pendingManifest)
        let invalidValues: [(String, Data)] = [
            ("WallpaperMachine.wallpaperPresets", Data("not json".utf8)),
            ("WallpaperMachine.wallpaperPresets", Data(#"{"version":2,"items":[]}"#.utf8)),
            ("WallpaperMachine.collections", Data(#"[{"id":"x","name":"Missing members"}]"#.utf8)),
            ("WallpaperMachine.playlistPlans", Data(#"[{"id":"p","name":"Bad","playlist":{"mode":"unknown"}}]"#.utf8)),
            ("WallpaperMachine.playlists", Data(#"{"screen":{"wallpaperIDs":["a"],"interval":0}}"#.utf8)),
            ("WallpaperMachine.playlists", Data(#"{"screen":{"mode":"rotate","trigger":"weekly"}}"#.utf8)),
            ("WallpaperMachine.playlists", Data(#"{"screen":{"mode":"rotate","trigger":5}}"#.utf8)),
            ("WallpaperMachine.playlistPlans", Data(#"[{"id":"p","name":"Bad","playlist":{"mode":"rotate","trigger":"weekly"}}]"#.utf8)),
            ("WallpaperMachine.imagePlacements", Data(#"{"version":1,"placements":{"w":{"screen":{"x":2,"y":0.5,"zoom":1}}}}"#.utf8)),
            ("WallpaperMachine.imagePlacements", Data(#"{"version":2,"placements":{}}"#.utf8)),
            ("WallpaperMachine.hotKeys", Data(#"{"togglePlayback":{"keyCode":"oops","modifiers":0,"label":"P"}}"#.utf8)),
            ("WallpaperMachine.appRules", Data(#"[{"id":"not-uuid"}]"#.utf8)),
            ("WallpaperMachine.automaticWallpapers", Data(#"{"primary":{"mode":"unknown","rules":[],"revision":0}}"#.utf8)),
            ("WallpaperMachine.solarLocation", Data(#"{"latitude":100,"longitude":0}"#.utf8)),
            ("WallpaperMachine.displayLayouts", Data(#"[{"id":"layout","name":"Empty","assignments":[]}]"#.utf8)),
        ]
        let manifestBaseline = try Data(contentsOf: package.appendingPathComponent("manifest.json"))
        for (key, value) in invalidValues {
            try manifestBaseline.write(to: package.appendingPathComponent("manifest.json"))
            try replaceManifestPreference(key, value: value)
            XCTAssertThrowsError(try service.preview(package: package, preferences: .init(defaults: live, domainName: domainName(for: live))), key)
            XCTAssertThrowsError(try service.stageRestore(package: package, preview: preview, policy: .replace), key)
            XCTAssertEqual(try Data(contentsOf: pendingManifest), baseline)
            XCTAssertEqual(live.data(forKey: "WallpaperMachine.wallpaperPresets"), archive)
        }
    }

    func testProductionRendererParserRejectsMalformedAndFutureConfigurationsBeforePublication() async throws {
        let original = try fixture()
        let live = try defaults()
        try put("live config must survive", "config.toml", in: destination)
        for invalid in ["[broken", "schema_version = 4294967295\n"] {
            try put(invalid, "config.toml", in: source)
            try WallpaperBackupService(supportRoot: source).export(to: package, includeLibrary: true, preferences: .init(defaults: original, domainName: domainName(for: original)))
            XCTAssertThrowsError(try WallpaperBackupService(supportRoot: destination).preview(package: package, preferences: .init(defaults: live, domainName: domainName(for: live))))
            XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("config.toml"), encoding: .utf8), "live config must survive")
        }
        try put("schema_version = 1\n", "config.toml", in: source)
        try put(#"{"schema_version":4294967295,"workshop_id":"101","type":"scene"}"#, "wallpapers/101.json", in: source)
        try WallpaperBackupService(supportRoot: source).export(to: package, includeLibrary: true, preferences: .init(defaults: original, domainName: domainName(for: original)))
        XCTAssertThrowsError(try WallpaperBackupService(supportRoot: destination).preview(package: package, preferences: .init(defaults: live, domainName: domainName(for: live))))
    }

    func testExistingExternalFileCannotAuthorizeIncomingOverridesDefaultsOrPresets() async throws {
        let original = try fixture()
        let live = try defaults()
        let privatePath = root.appendingPathComponent("private-photo.png").path
        try put("private bytes", "private-photo.png", in: root)
        let originalConfig = try Data(contentsOf: source.appendingPathComponent("wallpapers/101.json"))
        let originalProject = try Data(contentsOf: source.appendingPathComponent("Library/101/project.json"))
        let service = WallpaperBackupService(supportRoot: destination)
        try put(#"{"workshop_id":"101","type":"scene","property_overrides":{"photo":"\#(privatePath)"}}"#, "wallpapers/101.json", in: source)
        try WallpaperBackupService(supportRoot: source).export(to: package, includeLibrary: true, preferences: .init(defaults: original, domainName: domainName(for: original)))
        XCTAssertThrowsError(try service.preview(package: package, preferences: .init(defaults: live, domainName: domainName(for: live))))
        try originalConfig.write(to: source.appendingPathComponent("wallpapers/101.json"))
        var project = try json("Library/101/project.json", in: source)
        project["general"] = ["properties": ["photo": ["type": "file", "value": privatePath]]]
        try JSONSerialization.data(withJSONObject: project).write(to: source.appendingPathComponent("Library/101/project.json"))
        try WallpaperBackupService(supportRoot: source).export(to: package, includeLibrary: true, preferences: .init(defaults: original, domainName: domainName(for: original)))
        XCTAssertThrowsError(try service.preview(package: package, preferences: .init(defaults: live, domainName: domainName(for: live))))
        try originalProject.write(to: source.appendingPathComponent("Library/101/project.json"))
        let property = WallpaperPresetProperty(id: "photo", kind: "file", value: .string(privatePath), usesDefault: false)
        original.set(try JSONEncoder().encode(PresetArchive(items: [
            WallpaperPropertyPreset(id: presetID, wallpaperID: "101", name: "Unsafe", properties: [property]),
        ])), forKey: "WallpaperMachine.wallpaperPresets")
        try WallpaperBackupService(supportRoot: source).export(to: package, includeLibrary: true, preferences: .init(defaults: original, domainName: domainName(for: original)))
        XCTAssertThrowsError(try service.preview(package: package, preferences: .init(defaults: live, domainName: domainName(for: live))))
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: privatePath), encoding: .utf8), "private bytes")
        XCTAssertFalse(service.pendingRestore)
    }

    func testAlreadySelectedExternalReferenceIsScopedToSameWallpaperAndProperty() async throws {
        let original = try fixture()
        let live = try defaults()
        let external = root.appendingPathComponent("chosen.png").path
        try put("chosen", "chosen.png", in: root)
        try put(#"{"type":"scene","workshop_id":"101","property_overrides":{"photo":"\#(external)"}}"#, "wallpapers/101.json", in: source)
        try put(#"{"type":"scene","general":{"properties":{"photo":{"type":"file","value":""}}}}"#, "Library/101/project.json", in: destination)
        try put(#"{"type":"scene","workshop_id":"101","property_overrides":{"other":"\#(external)"}}"#, "wallpapers/101.json", in: destination)
        try WallpaperBackupService(supportRoot: source).export(to: package, includeLibrary: true, preferences: .init(defaults: original, domainName: domainName(for: original)))
        let service = WallpaperBackupService(supportRoot: destination)
        XCTAssertThrowsError(try service.preview(package: package, preferences: .init(defaults: live, domainName: domainName(for: live))))
        try put(#"{"type":"scene","workshop_id":"101","property_overrides":{"photo":"\#(external)"}}"#, "wallpapers/101.json", in: destination)
        let preview = try service.preview(package: package, preferences: .init(defaults: live, domainName: domainName(for: live)))
        try service.stageRestore(package: package, preview: preview, policy: .replace)
        _ = try service.applyPendingRestore(defaults: live, domainName: domainName(for: live))
        XCTAssertEqual((try json("wallpapers/101.json", in: destination)["property_overrides"] as? [String: String])?["photo"], external)
    }

    func testManagedMetadataCannotAuthorizeExternalReadAndCopiedBytesStillRecover() async throws {
        let original = try fixture()
        let live = try defaults()
        let external = root.appendingPathComponent("unselected-private.png").path
        try put("private original", "unselected-private.png", in: root)
        let managed = ManagedUserAssetStore(root: source.appendingPathComponent("UserAssets"))
        var manifest = try managed.manifest(wallpaperId: "101")
        manifest.properties["photo"]?.sourcePath = external
        manifest.properties["photo"]?.assets[0].sourcePath = external
        try managed.write(manifest)
        try put(#"{"type":"scene","workshop_id":"101","property_overrides":{"photo":"\#(external)"}}"#, "wallpapers/101.json", in: source)
        try WallpaperBackupService(supportRoot: source).export(to: package, includeLibrary: true, preferences: .init(defaults: original, domainName: domainName(for: original)))
        // An installed author's shipped default is not a user-selected source.
        try put(#"{"type":"scene","general":{"properties":{"photo":{"type":"file","value":"\#(external)"}}}}"#, "Library/101/project.json", in: destination)
        let service = WallpaperBackupService(supportRoot: destination)
        let preview = try service.preview(package: package, preferences: .init(defaults: live, domainName: domainName(for: live)))
        XCTAssertTrue(preview.warnings.contains { $0.contains(external) })
        try service.stageRestore(package: package, preview: preview, policy: .replace)
        _ = try service.applyPendingRestore(defaults: live, domainName: domainName(for: live))
        let restored = ManagedUserAssetStore(root: destination.appendingPathComponent("UserAssets"))
        let safePath = try XCTUnwrap(try restored.manifest(wallpaperId: "101").properties["photo"]?.sourcePath)
        XCTAssertEqual(safePath, external)
        XCTAssertEqual(try restored.manifest(wallpaperId: "101").properties["photo"]?.originalSourceUnauthorized, true)
        let store = UserAssetStore(projectURL: destination.appendingPathComponent("Library/101"), wallpaperId: "101", managed: restored)
        let asset = try await store.importFile(at: URL(fileURLWithPath: safePath), propertyId: "photo", filter: .image)
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: asset.stagedPath), encoding: .utf8), "retained image bytes")
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: external), encoding: .utf8), "private original")
        let secondPackage = root.appendingPathComponent("second.wmbackup")
        try service.export(to: secondPackage, includeLibrary: true, preferences: .init(defaults: live, domainName: domainName(for: live)))
        let secondPreview = try service.preview(package: secondPackage, preferences: .init(defaults: live, domainName: domainName(for: live)))
        try service.stageRestore(package: secondPackage, preview: secondPreview, policy: .replace)
        _ = try service.applyPendingRestore(defaults: live, domainName: domainName(for: live))
        XCTAssertEqual(try restored.manifest(wallpaperId: "101").properties["photo"]?.originalSourceUnauthorized, true)
        let secondStore = UserAssetStore(projectURL: destination.appendingPathComponent("Library/101"), wallpaperId: "101", managed: restored)
        let again = try await secondStore.importFile(at: URL(fileURLWithPath: external), propertyId: "photo", filter: .image)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: again.stagedPath)), Data("retained image bytes".utf8))
        try restored.authorizeSelection(wallpaperId: "101", propertyId: "photo", selectedSourcePath: external)
        let reselected = try await secondStore.importFile(at: URL(fileURLWithPath: external), propertyId: "photo", filter: .image)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: reselected.stagedPath)), Data("private original".utf8))
        XCTAssertNil(try restored.manifest(wallpaperId: "101").properties["photo"]?.originalSourceUnauthorized)
    }

    func testSceneTextureOverridesAndDefaultsReadRetainedImagesNotExistingOriginals() async throws {
        let original = try fixture()
        let live = try defaults()
        original.removeObject(forKey: WallpaperPresetStore.preferenceKey)
        let originalURL = root.appendingPathComponent("private original.png")
        let retainedURL = root.appendingPathComponent("retained.png")
        let privateBytes = try texturePNG(red: 1)
        let retainedBytes = try texturePNG(red: 0)
        try privateBytes.write(to: originalURL)
        try retainedBytes.write(to: retainedURL)
        let managed = ManagedUserAssetStore(root: source.appendingPathComponent("UserAssets"))
        var manifest = UserAssetManifest(wallpaperId: "101")
        for property in ["photo", "defaultPhoto"] {
            let asset = try managed.adopt(readingFrom: retainedURL, fileName: "retained.png",
                sourcePath: originalURL.path, wallpaperId: "101", propertyId: property, known: nil)
            manifest.properties[property] = .init(kind: .file, sourcePath: originalURL.path, assets: [asset])
        }
        try managed.write(manifest)
        try put(#"{"type":"scene","workshop_id":"101","property_overrides":{"photo":"\#(originalURL.path)"}}"#,
            "wallpapers/101.json", in: source)
        let project: [String: Any] = ["type": "scene", "title": "Retained textures", "file": "scene.json",
            "general": ["properties": [
                "photo": ["type": "scenetexture", "value": ""],
                "defaultPhoto": ["type": "texture", "value": originalURL.path],
            ]]]
        try JSONSerialization.data(withJSONObject: project).write(to: source.appendingPathComponent("Library/101/project.json"))
        try WallpaperBackupService(supportRoot: source).export(to: package, includeLibrary: true, preferences: .init(defaults: original, domainName: domainName(for: original)))
        let service = WallpaperBackupService(supportRoot: destination)
        let preview = try service.preview(package: package, preferences: .init(defaults: live, domainName: domainName(for: live)))
        try service.stageRestore(package: package, preview: preview, policy: .replace)
        _ = try service.applyPendingRestore(defaults: live, domainName: domainName(for: live))

        let overrides = try XCTUnwrap(json("wallpapers/101.json", in: destination)["property_overrides"] as? [String: String])
        let general = try XCTUnwrap(json("Library/101/project.json", in: destination)["general"] as? [String: Any])
        let properties = try XCTUnwrap(general["properties"] as? [String: [String: Any]])
        let restored = ManagedUserAssetStore(root: destination.appendingPathComponent("UserAssets"))
        let paths = ["photo": try XCTUnwrap(overrides["photo"]),
                     "defaultPhoto": try XCTUnwrap(properties["defaultPhoto"]?["value"] as? String)]
        for (property, path) in paths {
            let record = try XCTUnwrap(try restored.manifest(wallpaperId: "101").properties[property])
            let stored = try restored.storedURL(wallpaperId: "101", propertyId: property, asset: XCTUnwrap(record.assets.first))
            XCTAssertEqual(URL(fileURLWithPath: path).resolvingSymlinksInPath(), stored.resolvingSymlinksInPath())
            // Scene textures open the committed absolute path directly, without UserAssetStore.
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), retainedBytes)
            XCTAssertNotEqual(path, originalURL.path)
            XCTAssertEqual(record.sourcePath, originalURL.path)
            XCTAssertEqual(record.originalSourceUnauthorized, true)
        }
        XCTAssertEqual(try Data(contentsOf: originalURL), privateBytes)
    }

    func testSceneRetainedReferenceCannotUseMissingBytesFromKeepExistingAssetTree() async throws {
        let original = try fixture()
        let live = try defaults()
        original.removeObject(forKey: WallpaperPresetStore.preferenceKey)
        let external = root.appendingPathComponent("private.png").path
        try put("private", "private.png", in: root)
        let managed = ManagedUserAssetStore(root: source.appendingPathComponent("UserAssets"))
        var manifest = try managed.manifest(wallpaperId: "101")
        manifest.properties["photo"]?.sourcePath = external
        manifest.properties["photo"]?.assets[0].sourcePath = external
        try managed.write(manifest)
        try put(#"{"type":"scene","workshop_id":"101","property_overrides":{"photo":"\#(external)"}}"#,
            "wallpapers/101.json", in: source)
        try put(#"{"type":"scene","file":"scene.json","general":{"properties":{"photo":{"type":"scenetexture","value":""}}}}"#,
            "Library/101/project.json", in: source)
        let existing = ManagedUserAssetStore(root: destination.appendingPathComponent("UserAssets"))
        try existing.write(UserAssetManifest(wallpaperId: "101"))
        let before = try Data(contentsOf: destination.appendingPathComponent("UserAssets/101/manifest.json"))
        try WallpaperBackupService(supportRoot: source).export(to: package, includeLibrary: true, preferences: .init(defaults: original, domainName: domainName(for: original)))
        let service = WallpaperBackupService(supportRoot: destination)
        let preview = try service.preview(package: package, preferences: .init(defaults: live, domainName: domainName(for: live)))
        try service.stageRestore(package: package, preview: preview, policy: .keepExisting)
        XCTAssertThrowsError(try service.applyPendingRestore(defaults: live, domainName: domainName(for: live)))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("UserAssets/101/manifest.json")), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("wallpapers/101.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("Library/101").path))
    }

    private func texturePNG(red: CGFloat) throws -> Data {
        let bitmap = try XCTUnwrap(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        bitmap.setFillColor(red: red, green: 0, blue: 1 - red, alpha: 1)
        bitmap.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let bytes = NSMutableData()
        let output = try XCTUnwrap(CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(output, try XCTUnwrap(bitmap.makeImage()), nil)
        guard CGImageDestinationFinalize(output) else { throw CocoaError(.fileWriteUnknown) }
        return bytes as Data
    }

    func testKeepExistingPreservesAtomicPlaybackOrderPlanAndAbsentDeadline() async throws {
        let original = try fixture()
        let live = try defaults()
        let current = PlaylistStore(defaults: live)
        current.update("shared") { $0.mode = .rotate; $0.source = .list; $0.wallpaperIDs = ["300", "100", "200"] }
        let plan = try current.savePlan(from: "shared", name: "Current")
        try current.applyPlan(plan.id, to: "shared")
        let deadline = Date(timeIntervalSince1970: 123456)
        current.schedule("shared", at: deadline)
        current.update("unscheduled") { $0.wallpaperIDs = ["b", "a"] }
        let before = current.playlist(for: "shared")
        let incoming = PlaylistStore(defaults: original)
        incoming.update("shared") { $0.mode = .dayNight; $0.wallpaperIDs = ["other"] }
        incoming.schedule("shared", at: Date(timeIntervalSince1970: 987654))
        incoming.update("unscheduled") { $0.mode = .rotate; $0.wallpaperIDs = ["intruder"] }
        incoming.schedule("unscheduled", at: deadline)
        incoming.update("new") { $0.mode = .rotate; $0.wallpaperIDs = ["z", "x", "y"] }
        incoming.schedule("new", at: deadline)
        live.set(try JSONEncoder().encode(["300"]), forKey: "WallpaperMachine.favoriteWallpaperIDs")
        original.set(try JSONEncoder().encode(["100"]), forKey: "WallpaperMachine.favoriteWallpaperIDs")
        try WallpaperBackupService(supportRoot: source).export(to: package, includeLibrary: true, preferences: .init(defaults: original, domainName: domainName(for: original)))
        let service = WallpaperBackupService(supportRoot: destination)
        let preview = try service.preview(package: package, preferences: .init(defaults: live, domainName: domainName(for: live)))
        try service.stageRestore(package: package, preview: preview, policy: .keepExisting)
        _ = try service.applyPendingRestore(defaults: live, domainName: domainName(for: live))
        let after = PlaylistStore(defaults: live)
        XCTAssertEqual(after.playlist(for: "shared"), before)
        XCTAssertEqual(after.nextChange["shared"], deadline)
        XCTAssertEqual(after.playlist(for: "unscheduled").wallpaperIDs, ["b", "a"])
        XCTAssertNil(after.nextChange["unscheduled"])
        XCTAssertEqual(after.playlist(for: "new").wallpaperIDs, ["z", "x", "y"])
        XCTAssertEqual(after.nextChange["new"], deadline)
        XCTAssertEqual(Set(try JSONDecoder().decode([String].self, from: XCTUnwrap(live.data(forKey: "WallpaperMachine.favoriteWallpaperIDs")))), ["300", "100"])
    }

    func testPlainTextAndNamesKeepSourceRootWhileOnlyResourcePathsMove() async throws {
        let original = try fixture()
        let live = try defaults()
        let text = source.path + "/UserAssets/101/photo/asset/画 像.png"
        var config = try json("wallpapers/101.json", in: source)
        var overrides = config["property_overrides"] as! [String: Any]
        overrides["caption"] = text
        config["property_overrides"] = overrides
        try JSONSerialization.data(withJSONObject: config).write(to: source.appendingPathComponent("wallpapers/101.json"))
        var project = try json("Library/101/project.json", in: source)
        var general = project["general"] as! [String: Any]
        var properties = general["properties"] as! [String: [String: Any]]
        properties["caption"]?["value"] = text
        general["properties"] = properties
        project["general"] = general
        project["title"] = text
        try JSONSerialization.data(withJSONObject: project).write(to: source.appendingPathComponent("Library/101/project.json"))
        let preset = WallpaperPropertyPreset(id: presetID, wallpaperID: "101", name: text.prefix(120).description,
            properties: [.init(id: "caption", kind: "textInput", value: .string(text), usesDefault: false)])
        original.set(try JSONEncoder().encode(PresetArchive(items: [preset])), forKey: "WallpaperMachine.wallpaperPresets")
        try WallpaperBackupService(supportRoot: source).export(to: package, includeLibrary: true, preferences: .init(defaults: original, domainName: domainName(for: original)))
        let service = WallpaperBackupService(supportRoot: destination)
        let preview = try service.preview(package: package, preferences: .init(defaults: live, domainName: domainName(for: live)))
        try service.stageRestore(package: package, preview: preview, policy: .replace)
        _ = try service.applyPendingRestore(defaults: live, domainName: domainName(for: live))
        let restoredConfig = try json("wallpapers/101.json", in: destination)["property_overrides"] as! [String: String]
        XCTAssertEqual(restoredConfig["caption"], text)
        XCTAssertEqual(restoredConfig["photo"], destination.appendingPathComponent("UserAssets/101/photo/asset/画 像.png").path)
        let restoredProject = try json("Library/101/project.json", in: destination)
        XCTAssertEqual(restoredProject["title"] as? String, text)
        let defaults = (restoredProject["general"] as? [String: Any])?["properties"] as? [String: [String: Any]]
        XCTAssertEqual(defaults?["caption"]?["value"] as? String, text)
        let restoredPreset = try JSONDecoder().decode(PresetArchive.self, from: XCTUnwrap(live.data(forKey: "WallpaperMachine.wallpaperPresets"))).items[0]
        XCTAssertEqual(restoredPreset, preset)
    }

    func testKeepExistingCannotReinterpretPreservedTextAsNewExternalFileSelection() async throws {
        let original = try fixture()
        let live = try defaults()
        let privatePath = root.appendingPathComponent("private.png").path
        try put("private", "private.png", in: root)
        try put(#"{"workshop_id":"101","type":"scene","property_overrides":{"photo":"\#(privatePath)"}}"#, "wallpapers/101.json", in: destination)
        // Restoring a file descriptor cannot upgrade an old untyped string to read authority.
        let baseline = try Data(contentsOf: destination.appendingPathComponent("wallpapers/101.json"))
        try WallpaperBackupService(supportRoot: source).export(to: package, includeLibrary: true, preferences: .init(defaults: original, domainName: domainName(for: original)))
        let service = WallpaperBackupService(supportRoot: destination)
        let preview = try service.preview(package: package, preferences: .init(defaults: live, domainName: domainName(for: live)))
        try service.stageRestore(package: package, preview: preview, policy: .keepExisting)
        XCTAssertThrowsError(try service.applyPendingRestore(defaults: live, domainName: domainName(for: live)))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("wallpapers/101.json")), baseline)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("Library/101").path))
        XCTAssertTrue(service.pendingRestore)
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: privatePath), encoding: .utf8), "private")
    }


}
