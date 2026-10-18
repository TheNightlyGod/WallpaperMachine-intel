import Combine
import CoreLocation
import Foundation
import Observation

/// Keeps automatic solar coordinates current for the app's lifetime. The saved source expresses
/// the user's intent even while permission is unavailable; only an explicit action can prompt.
@MainActor
@Observable
final class SolarLocationTracker {
    static let shared = SolarLocationTracker(store: .shared)

    private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined
    private(set) var servicesEnabled = true
    @ObservationIgnored private let store: WallpaperAutomationStore
    @ObservationIgnored private let manager: any SolarLocationManaging
    @ObservationIgnored private let openSettingsURL: @MainActor (URL) -> Bool
    @ObservationIgnored private var changes: AnyCancellable?
    @ObservationIgnored private var isStarted = false
    @ObservationIgnored private var isUpdating = false

    /// Construction and state reads do not initialize Core Location. The app starts the service
    /// after its unit-test launch guard; tests inject a manager which has no system dependencies.
    init(
        store: WallpaperAutomationStore,
        manager: (any SolarLocationManaging)? = nil,
        openSettings: (@MainActor (URL) -> Bool)? = nil
    ) {
        self.store = store
        self.manager = manager ?? SystemSolarLocationManager()
        openSettingsURL = openSettings ?? { DesktopActions.current.open($0) }
    }

    /// Observes every source change, including changes made outside the panel. Launch never asks
    /// for access: an existing authorization resumes, and an undecided one waits for a user action.
    func start() {
        guard !isStarted else { return }
        isStarted = true
        manager.authorizationChanged = { [weak self] in self?.authorizationChanged() }
        manager.locationChanged = { [weak self] in self?.receive($0) }
        changes = NotificationCenter.default.publisher(
            for: WallpaperAutomationStore.didChangeNotification, object: store
        ).sink { [weak self] _ in self?.synchronize() }
        synchronize()
    }

    func stop() {
        isStarted = false
        changes = nil
        manager.authorizationChanged = nil
        manager.locationChanged = nil
        stopUpdating()
    }

    /// Called only by a deliberate panel action. A denied request leads to System Settings;
    /// granting access there resumes automatically through the authorization callback.
    func requestAuthorization() {
        guard store.solar.source == .automatic else { return }
        start()
        authorizationChanged()
        if isDenied {
            openSettings()
        } else if authorizationStatus == .notDetermined {
            manager.requestAuthorization()
        }
    }

    var isDenied: Bool {
        !servicesEnabled || authorizationStatus == .denied || authorizationStatus == .restricted
    }

    func openSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices"
        ) else { return }
        _ = openSettingsURL(url)
    }

    private func synchronize() {
        guard isStarted else { return }
        guard store.solar.source == .automatic else {
            stopUpdating()
            return
        }
        authorizationChanged()
    }

    private func authorizationChanged() {
        guard isStarted else { return }
        authorizationStatus = manager.authorizationStatus
        servicesEnabled = manager.servicesEnabled
        guard store.solar.source == .automatic, servicesEnabled,
              authorizationStatus == .authorizedAlways else {
            stopUpdating()
            return
        }
        guard !isUpdating else { return }
        isUpdating = true
        manager.startUpdatingLocation()
    }

    private func stopUpdating() {
        guard isUpdating else { return }
        isUpdating = false
        manager.stopUpdatingLocation()
    }

    private func receive(_ location: WallpaperSolarLocation) {
        // A callback queued before a stop or source change must not overwrite manual coordinates.
        guard isStarted, isUpdating, store.solar.source == .automatic, location.isValid else { return }
        do { try store.setLocation(location) }
        catch { AppLog.warn("solar location: could not save location: \(error.localizedDescription)") }
    }
}
