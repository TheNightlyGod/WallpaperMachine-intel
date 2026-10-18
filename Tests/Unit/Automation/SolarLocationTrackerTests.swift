import CoreLocation
import Observation
import XCTest

@testable import WallpaperMachine

@MainActor
final class SolarLocationTrackerTests: XCTestCase {
    private var store: WallpaperAutomationStore!
    private var manager: FakeSolarLocationManager!
    private var tracker: SolarLocationTracker!
    private var openedSettings: [URL] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        store = WallpaperAutomationStore(defaults: try TemporaryDefaults.make(for: self).defaults)
        manager = FakeSolarLocationManager()
        tracker = SolarLocationTracker(store: store, manager: manager, openSettings: { [weak self] url in
            self?.openedSettings.append(url)
            return true
        })
    }

    override func tearDownWithError() throws {
        tracker.stop()
        tracker = nil
        try super.tearDownWithError()
    }

    private func source(_ value: WallpaperSolarSource) throws {
        var solar = store.solar
        solar.source = value
        try store.setSolar(solar)
    }

    func testConstructionAndManualStartupDoNotReadLocationServices() {
        XCTAssertEqual(manager.authorizationReads, 0)
        XCTAssertEqual(manager.servicesReads, 0)
        _ = tracker.isDenied
        _ = tracker.servicesEnabled
        tracker.start()
        XCTAssertEqual(manager.authorizationReads, 0)
        XCTAssertEqual(manager.servicesReads, 0)
        XCTAssertEqual(manager.requests, 0)
        XCTAssertEqual(manager.starts, 0)
    }

    func testStartupRestoresAuthorizedAutomaticWithoutRequestingPermission() throws {
        try source(.automatic)
        manager.authorization = .authorizedAlways
        tracker.start()
        tracker.start()
        XCTAssertEqual(manager.starts, 1)
        XCTAssertEqual(manager.requests, 0)
        XCTAssertTrue(openedSettings.isEmpty)
    }

    func testUndecidedAndDeniedStartupNeverRequestOrOpenSettings() throws {
        try source(.automatic)
        tracker.start()
        XCTAssertEqual(manager.requests, 0)
        XCTAssertEqual(manager.starts, 0)
        manager.changeAuthorization(to: .denied)
        XCTAssertTrue(tracker.isDenied)
        XCTAssertEqual(manager.requests, 0)
        XCTAssertTrue(openedSettings.isEmpty)
    }

    func testChangingSourceStopsTrackingAndRejectsLateCoordinates() throws {
        try source(.automatic)
        manager.authorization = .authorizedAlways
        tracker.start()
        manager.send(.init(latitude: 30.08, longitude: 103.87))
        XCTAssertEqual(store.location?.latitude, 30.08)

        try source(.coordinates)
        XCTAssertEqual(manager.stops, 1)
        let manual = WallpaperSolarLocation(latitude: 51.5, longitude: -0.1)
        try store.setLocation(manual)
        manager.send(.init(latitude: 40.7, longitude: -74.0))
        XCTAssertEqual(store.location, manual)

        try source(.automatic)
        XCTAssertEqual(manager.starts, 2)
        try source(.fixed)
        XCTAssertEqual(manager.stops, 2)
        manager.send(.init(latitude: 40.7, longitude: -74.0))
        XCTAssertEqual(store.location, manual)
    }

    func testRestoringPermissionResumesOnlyTheAutomaticSource() throws {
        try source(.automatic)
        manager.authorization = .authorizedAlways
        tracker.start()
        manager.changeAuthorization(to: .denied)
        XCTAssertEqual(manager.stops, 1)
        XCTAssertTrue(tracker.isDenied)
        manager.changeAuthorization(to: .authorizedAlways)
        XCTAssertEqual(manager.starts, 2)
        XCTAssertFalse(tracker.isDenied)
        XCTAssertEqual(manager.requests, 0)

        try source(.coordinates)
        manager.changeAuthorization(to: .denied)
        manager.changeAuthorization(to: .authorizedAlways)
        XCTAssertEqual(manager.starts, 2)
    }

    func testGlobalLocationSwitchUpdatesObservedStateAndRecovers() throws {
        try source(.automatic)
        manager.authorization = .authorizedAlways
        tracker.start()
        let changed = expectation(description: "permission state is observable")
        withObservationTracking {
            _ = tracker.isDenied
        } onChange: {
            changed.fulfill()
        }
        manager.enabled = false
        manager.changeAuthorization(to: .denied)
        XCTAssertFalse(tracker.servicesEnabled)
        XCTAssertEqual(manager.stops, 1)
        wait(for: [changed], timeout: 1)
        manager.enabled = true
        manager.changeAuthorization(to: .authorizedAlways)
        XCTAssertTrue(tracker.servicesEnabled)
        XCTAssertEqual(manager.starts, 2)
    }

    func testOnlyAnExplicitAutomaticRequestCanPromptOrOpenSettings() throws {
        tracker.requestAuthorization()
        XCTAssertEqual(manager.requests, 0)
        try source(.automatic)
        tracker.requestAuthorization()
        XCTAssertEqual(manager.requests, 1)
        manager.changeAuthorization(to: .denied)
        tracker.requestAuthorization()
        XCTAssertEqual(manager.requests, 1)
        XCTAssertEqual(openedSettings.count, 1)
        XCTAssertEqual(openedSettings.first?.scheme, "x-apple.systempreferences")
        manager.changeAuthorization(to: .authorizedAlways)
        XCTAssertEqual(manager.starts, 1)
    }

    func testStopRejectsPendingUpdatesAndPermissionCallbacks() throws {
        try source(.automatic)
        manager.authorization = .authorizedAlways
        tracker.start()
        let pendingLocation = manager.locationChanged
        let pendingAuthorization = manager.authorizationChanged
        tracker.stop()
        pendingLocation?(.init(latitude: 30.08, longitude: 103.87))
        pendingAuthorization?()
        XCTAssertNil(store.location)
        XCTAssertEqual(manager.starts, 1)
        XCTAssertEqual(manager.stops, 1)
    }
}

/// Shared by service and panel fixtures so no test constructs a system location manager.
@MainActor
final class FakeSolarLocationManager: SolarLocationManaging {
    var authorization: CLAuthorizationStatus = .notDetermined
    var enabled = true
    private(set) var authorizationReads = 0
    private(set) var servicesReads = 0
    private(set) var requests = 0
    private(set) var starts = 0
    private(set) var stops = 0
    var authorizationChanged: (() -> Void)?
    var locationChanged: ((WallpaperSolarLocation) -> Void)?

    var authorizationStatus: CLAuthorizationStatus {
        authorizationReads += 1
        return authorization
    }
    var servicesEnabled: Bool {
        servicesReads += 1
        return enabled
    }
    func requestAuthorization() { requests += 1 }
    func startUpdatingLocation() { starts += 1 }
    func stopUpdatingLocation() { stops += 1 }
    func changeAuthorization(to value: CLAuthorizationStatus) {
        authorization = value
        authorizationChanged?()
    }
    func send(_ location: WallpaperSolarLocation) { locationChanged?(location) }
}
