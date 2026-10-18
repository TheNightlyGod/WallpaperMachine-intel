import XCTest
@testable import WallpaperMachine

@MainActor
final class WallpaperAutomationStoreTests: XCTestCase {
    func testPreSpacePreferencesDecodeAndSpaceChoicesRoundTrip() throws {
        let old = Data(#"{"mode":"appearance","rules":[],"revision":2,"light":{"kind":"wallpaper","id":"a"}}"#.utf8)
        var value = try JSONDecoder().decode(DisplayWallpaperAutomation.self, from: old)
        XCTAssertTrue(value.spaces.isEmpty)
        value.mode = .spaces; value.spaces["desktop-uuid"] = .init(kind: .wallpaper, id: "ocean")
        XCTAssertEqual(try JSONDecoder().decode(DisplayWallpaperAutomation.self, from: JSONEncoder().encode(value)), value)
    }
    private var defaults: UserDefaults!
    override func setUpWithError() throws {
        try super.setUpWithError()
        defaults = try TemporaryDefaults.make(for: self).defaults
    }

    func testRulesLocationAndHandledStatePersistAndUnchangedEditsKeepTheRevision() throws {
        let store = WallpaperAutomationStore(defaults: defaults)
        let rule = WallpaperAutomationRule(weekdays: [2, 6], event: .sunset, offset: 30,
            target: .init(kind: .wallpaper, id: "sunset"))
        try store.update("screen") { $0.mode = .schedule }
        try store.saveRule(rule, on: "screen")
        let revision = store.configuration(for: "screen").revision
        try store.saveRule(rule, on: "screen")
        XCTAssertEqual(store.configuration(for: "screen").revision, revision)
        try store.setLocation(.init(latitude: -33.87, longitude: 151.21))
        store.markHandled("event", on: "screen")
        let loaded = WallpaperAutomationStore(defaults: defaults)
        XCTAssertEqual(loaded.configuration(for: "screen"), store.configuration(for: "screen"))
        XCTAssertEqual(loaded.location, store.location)
        XCTAssertEqual(loaded.handled["screen"], "event")
        loaded.retry("screen")
        XCTAssertNil(WallpaperAutomationStore(defaults: defaults).handled["screen"])
    }

    func testInvalidUpdatesAreAtomicAndCorruptStoredRulesAreReported() throws {
        let store = WallpaperAutomationStore(defaults: defaults)
        try store.update("screen") { $0.mode = .appearance; $0.light = .init(kind: .wallpaper, id: "a") }
        let before = defaults.data(forKey: WallpaperAutomationStore.configurationsKey)
        XCTAssertThrowsError(try store.update("screen") { $0.dark = .init(kind: .wallpaper, id: "") })
        XCTAssertEqual(defaults.data(forKey: WallpaperAutomationStore.configurationsKey), before)
        XCTAssertThrowsError(try store.setLocation(.init(latitude: .nan, longitude: 0)))
        defaults.set(Data("not JSON".utf8), forKey: WallpaperAutomationStore.configurationsKey)
        let corrupt = WallpaperAutomationStore(defaults: defaults)
        XCTAssertNotNil(corrupt.loadError)
        XCTAssertTrue(corrupt.configurations.isEmpty)
    }

    func testImportedConfigurationBoundsAndDeletedWallpaperPruning() throws {
        let store = WallpaperAutomationStore(defaults: defaults)
        try store.update("screen") {
            $0.mode = .schedule
            $0.rules = [.init(target: .init(kind: .wallpaper, id: "a")), .init(target: .init(kind: .playlist, id: "p"))]
            $0.light = .init(kind: .wallpaper, id: "a")
        }
        try store.forgetWallpapers(["a"])
        XCTAssertNil(store.configuration(for: "screen").light)
        XCTAssertEqual(store.configuration(for: "screen").rules.map(\.target.id), ["p"])
        let tooMany = Dictionary(uniqueKeysWithValues: (0..<65).map { (String($0), DisplayWallpaperAutomation()) })
        let data = try JSONEncoder().encode(tooMany)
        XCTAssertThrowsError(try WallpaperAutomationStore.validateConfigurations(data))
        defaults.set(data, forKey: WallpaperAutomationStore.configurationsKey)
        XCTAssertTrue(WallpaperAutomationStore(defaults: defaults).configurations.isEmpty)
    }

    func testALocationSavedBeforeTheSourceExistedReadsAsCoordinates() throws {
        let legacy = WallpaperSolarLocation(latitude: 30.0827, longitude: 103.874)
        defaults.set(try JSONEncoder().encode(legacy), forKey: WallpaperAutomationStore.locationKey)
        let store = WallpaperAutomationStore(defaults: defaults)
        XCTAssertEqual(store.solar.source, .coordinates)
        XCTAssertEqual(store.solar.location, legacy)
        XCTAssertEqual(store.solar.fixedSunriseMinute, 7 * 60)
        XCTAssertEqual(store.solar.fixedSunsetMinute, 18 * 60)
        XCTAssertNil(store.loadError)
    }

    func testFixedTimesSurviveAReloadWithoutACoordinate() throws {
        let store = WallpaperAutomationStore(defaults: defaults)
        try store.setSolar(.init(
            source: .fixed, location: nil,
            fixedSunriseMinute: 6 * 60 + 15, fixedSunsetMinute: 19 * 60 + 45))
        let loaded = WallpaperAutomationStore(defaults: defaults)
        XCTAssertEqual(loaded.solar.source, .fixed)
        XCTAssertEqual(loaded.solar.fixedSunriseMinute, 6 * 60 + 15)
        XCTAssertEqual(loaded.solar.fixedSunsetMinute, 19 * 60 + 45)
        XCTAssertNil(loaded.location)
        XCTAssertNil(loaded.loadError)
    }

    func testAutomaticSourceKeepsTheLocationItTracks() throws {
        let store = WallpaperAutomationStore(defaults: defaults)
        let location = WallpaperSolarLocation(latitude: 30.0827, longitude: 103.874)
        try store.setSolar(.init(source: .automatic, location: location))
        let loaded = WallpaperAutomationStore(defaults: defaults)
        XCTAssertEqual(loaded.solar.source, .automatic)
        XCTAssertEqual(loaded.solar.location, location)
        XCTAssertNil(loaded.loadError)
    }

    func testAFixedTimeOutsideTheDayIsRefused() {
        let store = WallpaperAutomationStore(defaults: defaults)
        XCTAssertThrowsError(try store.setSolar(.init(
            source: .fixed, location: nil,
            fixedSunriseMinute: 24 * 60, fixedSunsetMinute: 18 * 60)))
    }
}
