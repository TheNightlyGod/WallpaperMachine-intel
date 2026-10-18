import Foundation
import XCTest
@testable import WallpaperMachine

@MainActor
final class WallpaperBackupSolarTests: XCTestCase {
    private var root: URL!
    private var domains: [ObjectIdentifier: String] = [:]
    private let locationKey = WallpaperAutomationStore.locationKey
    private let settingsKey = WallpaperAutomationStore.solarKey

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Backup-solar-tests-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
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

    private func preferences(_ defaults: UserDefaults) throws -> WallpaperBackupPreferences {
        try .init(defaults: defaults, domainName: domains[ObjectIdentifier(defaults)]!)
    }

    private func stage(_ incoming: UserDefaults, into live: UserDefaults, policy: WallpaperBackupConflictPolicy) throws
        -> (WallpaperBackupService, WallpaperBackupPreview) {
        let package = root.appendingPathComponent("Solar.wmbackup")
        try WallpaperBackupService(supportRoot: root.appendingPathComponent("source"))
            .export(to: package, includeLibrary: false, preferences: preferences(incoming))
        let service = WallpaperBackupService(supportRoot: root.appendingPathComponent("destination"))
        let preview = try service.preview(package: package, preferences: preferences(live))
        try service.stageRestore(package: package, preview: preview, policy: policy)
        return (service, preview)
    }

    private func apply(_ service: WallpaperBackupService, to live: UserDefaults) throws {
        _ = try service.applyPendingRestore(defaults: live, domainName: domains[ObjectIdentifier(live)]!)
    }

    func testReplaceLegacyCoordinatesOverridesExistingFixedSettings() throws {
        let incoming = try defaults()
        let location = WallpaperSolarLocation(latitude: 30, longitude: 40)
        incoming.set(try JSONEncoder().encode(location), forKey: locationKey)
        let live = try defaults()
        try WallpaperAutomationStore(defaults: live).setSolar(.init(source: .fixed, location: nil))

        let (service, preview) = try stage(incoming, into: live, policy: .replace)
        XCTAssertEqual(preview.conflicts, ["Preferences/" + settingsKey])
        try apply(service, to: live)

        XCTAssertEqual(WallpaperAutomationStore(defaults: live).solar, .init(location: location))
        XCTAssertEqual(try JSONDecoder().decode(WallpaperSolarLocation.self,
            from: XCTUnwrap(live.data(forKey: locationKey))), location)
    }

    func testKeepExistingLegacyCoordinatesDoesNotImportNewSettings() throws {
        let incoming = try defaults()
        try WallpaperAutomationStore(defaults: incoming).setSolar(.init(source: .fixed, location: nil))
        let live = try defaults()
        let location = WallpaperSolarLocation(latitude: 10, longitude: 20)
        let original = try JSONEncoder().encode(location)
        live.set(original, forKey: locationKey)

        let (service, preview) = try stage(incoming, into: live, policy: .keepExisting)
        XCTAssertEqual(preview.conflicts, ["Preferences/" + settingsKey])
        try apply(service, to: live)

        XCTAssertEqual(WallpaperAutomationStore(defaults: live).solar, .init(location: location))
        XCTAssertEqual(live.data(forKey: locationKey), original)
        XCTAssertNil(live.object(forKey: settingsKey))
    }

    func testReplaceFixedSettingsWithoutLocationRemovesOldCoordinates() throws {
        let incoming = try defaults()
        let fixed = WallpaperSolarSettings(source: .fixed, location: nil,
            fixedSunriseMinute: 390, fixedSunsetMinute: 1110)
        try WallpaperAutomationStore(defaults: incoming).setSolar(fixed)
        let live = try defaults()
        try WallpaperAutomationStore(defaults: live).setLocation(.init(latitude: 10, longitude: 20))

        let (service, _) = try stage(incoming, into: live, policy: .replace)
        try apply(service, to: live)

        XCTAssertEqual(WallpaperAutomationStore(defaults: live).solar, fixed)
        XCTAssertNil(live.object(forKey: locationKey))
    }

    func testReplaceUsesNewSettingsToSynchronizeConflictingLegacyCoordinates() throws {
        let incoming = try defaults()
        let settings = WallpaperSolarSettings(location: .init(latitude: 30, longitude: 40))
        try WallpaperAutomationStore(defaults: incoming).setSolar(settings)
        incoming.set(try JSONEncoder().encode(WallpaperSolarLocation(latitude: 10, longitude: 20)), forKey: locationKey)
        let live = try defaults()

        let (service, _) = try stage(incoming, into: live, policy: .replace)
        try apply(service, to: live)

        XCTAssertEqual(WallpaperAutomationStore(defaults: live).solar, settings)
        XCTAssertEqual(try JSONDecoder().decode(WallpaperSolarLocation.self,
            from: XCTUnwrap(live.data(forKey: locationKey))), settings.location)
    }

    func testBackupWithoutSolarPreferencesLeavesCurrentSettingsIntact() throws {
        let incoming = try defaults()
        let live = try defaults()
        let settings = WallpaperSolarSettings(source: .fixed, location: .init(latitude: 10, longitude: 20))
        try WallpaperAutomationStore(defaults: live).setSolar(settings)
        let before = try preferences(live).values

        let (service, _) = try stage(incoming, into: live, policy: .replace)
        try apply(service, to: live)

        XCTAssertEqual(try preferences(live).values, before)
    }

    func testFailedRestoreRestoresLegacyCoordinatesAndRemovesNewSettings() throws {
        let incoming = try defaults()
        let fixed = WallpaperSolarSettings(source: .fixed, location: nil)
        try WallpaperAutomationStore(defaults: incoming).setSolar(fixed)
        let live = try defaults()
        let original = try JSONEncoder().encode(WallpaperSolarLocation(latitude: 10, longitude: 20))
        live.set(original, forKey: locationKey)

        let (service, _) = try stage(incoming, into: live, policy: .replace)
        XCTAssertThrowsError(try service.applyPendingRestore(defaults: live,
            domainName: domains[ObjectIdentifier(live)]!, beforePublish: { path in
                guard path == "Preferences" else { return }
                // Emulate failure after the new record and legacy deletion reached preferences.
                live.set(try JSONEncoder().encode(fixed), forKey: self.settingsKey)
                live.removeObject(forKey: self.locationKey)
                throw CocoaError(.fileWriteUnknown)
            }))

        XCTAssertEqual(live.data(forKey: locationKey), original)
        XCTAssertNil(live.object(forKey: settingsKey))
    }
}
