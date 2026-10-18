import CoreLocation
import Foundation

@MainActor
protocol SolarLocationManaging: AnyObject {
    var authorizationStatus: CLAuthorizationStatus { get }
    var servicesEnabled: Bool { get }
    var authorizationChanged: (() -> Void)? { get set }
    var locationChanged: ((WallpaperSolarLocation) -> Void)? { get set }
    func requestAuthorization()
    func startUpdatingLocation()
    func stopUpdatingLocation()
}

/// The only solar-location type that touches Core Location. Its manager is lazy so constructing
/// a panel or reading its cached permission state does not reach location hardware.
@MainActor
final class SystemSolarLocationManager: NSObject, SolarLocationManaging, CLLocationManagerDelegate {
    var authorizationChanged: (() -> Void)?
    var locationChanged: ((WallpaperSolarLocation) -> Void)?

    private lazy var manager: CLLocationManager = {
        let manager = CLLocationManager()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        manager.distanceFilter = 5_000
        return manager
    }()

    var authorizationStatus: CLAuthorizationStatus { manager.authorizationStatus }
    var servicesEnabled: Bool { CLLocationManager.locationServicesEnabled() }
    func requestAuthorization() { manager.requestWhenInUseAuthorization() }
    func startUpdatingLocation() { manager.startUpdatingLocation() }
    func stopUpdatingLocation() { manager.stopUpdatingLocation() }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in self?.authorizationChanged?() }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let fix = locations.last, fix.horizontalAccuracy >= 0 else { return }
        let location = WallpaperSolarLocation(
            latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude)
        Task { @MainActor [weak self] in self?.locationChanged?(location) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Keep the last known position until the next valid fix.
        AppLog.warn("solar location: update failed: \(error.localizedDescription)")
    }
}
