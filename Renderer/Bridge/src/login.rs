use std::{
    sync::{Arc, Mutex, PoisonError},
    time::{Duration, Instant},
};

use objc2_service_management::{SMAppService, SMAppServiceStatus};

use crate::api::BridgeError;

mod operations;
#[cfg(test)]
mod transition_tests;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LaunchAtLoginStatus {
    Available { enabled: bool },
    /// The user switched the app off in System Settings > General > Login
    /// Items. The login item does not run, and registering again cannot turn
    /// it back on: only the user can, in System Settings.
    RequiresApproval,
    Unavailable,
}

/// How long a status read stays current.
///
/// Every snapshot the bridge returns carries the status, and reading it is a
/// round trip to the system's service manager that costs far more than the
/// rest of a snapshot. Read per snapshot, it held every queued bridge request
/// behind it. The status changes through `set_enabled`, which records its own
/// result, or in System Settings, which a read this recent still reflects.
const STATUS_FRESHNESS: Duration = Duration::from_secs(2);

#[derive(Clone)]
pub struct LaunchAtLoginController {
    implementation: Arc<dyn LaunchAtLoginImpl>,
    /// The last status read and when it was taken, shared by every clone.
    last_read: Arc<Mutex<Option<(Instant, LaunchAtLoginStatus)>>>,
}

trait LaunchAtLoginImpl: Send + Sync {
    fn status(&self) -> Result<LaunchAtLoginStatus, BridgeError>;
    fn set_enabled(&self, enabled: bool) -> Result<LaunchAtLoginStatus, BridgeError>;
}

impl Default for LaunchAtLoginController {
    fn default() -> Self {
        Self::new(Arc::new(SystemLaunchAtLogin::new(Arc::new(SystemLoginItem))))
    }
}

impl LaunchAtLoginController {
    fn new(implementation: Arc<dyn LaunchAtLoginImpl>) -> Self {
        Self {
            implementation,
            last_read: Arc::new(Mutex::new(None)),
        }
    }

    #[must_use]
    pub fn status(&self) -> LaunchAtLoginStatus {
        self.status_at(Instant::now())
    }

    fn status_at(&self, now: Instant) -> LaunchAtLoginStatus {
        let mut last_read = self.last_read.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some((read_at, status)) = *last_read
            && now.saturating_duration_since(read_at) < STATUS_FRESHNESS
        {
            return status;
        }
        let status = self
            .implementation
            .status()
            .unwrap_or(LaunchAtLoginStatus::Unavailable);
        *last_read = Some((now, status));
        status
    }

    /// # Errors
    ///
    /// Returns an error when launch at login is unavailable or when the
    /// system service manager rejects the requested state.
    pub fn set_enabled(&self, enabled: bool) -> Result<LaunchAtLoginStatus, BridgeError> {
        let result = self.implementation.set_enabled(enabled);
        // A rejected change may still have moved the system state, so only a
        // confirmed one is remembered; otherwise the next read asks again.
        *self.last_read.lock().unwrap_or_else(PoisonError::into_inner) =
            result.as_ref().ok().map(|status| (Instant::now(), *status));
        result
    }

    #[cfg(test)]
    #[must_use]
    pub fn fake(status: LaunchAtLoginStatus) -> Self {
        Self::new(Arc::new(operations::SyntheticLoginStatus::new(status)))
    }
}

/// What the service manager says about the app's login item, reduced to what
/// the panel needs. `NotRegistered`, `NotFound` and any state a later macOS
/// adds all read as "not on".
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum ServiceState {
    Enabled,
    RequiresApproval,
    Off,
}

/// The system's login item service for the main app, so the rules below can be
/// tested without touching the real one.
trait LoginItemService: Send + Sync {
    /// Whether the app sits where macOS lets it register a login item.
    fn can_register(&self) -> bool;
    fn state(&self) -> ServiceState;
    fn register(&self) -> Result<(), BridgeError>;
    fn unregister(&self) -> Result<(), BridgeError>;
}

struct SystemLoginItem;

impl LoginItemService for SystemLoginItem {
    fn can_register(&self) -> bool {
        operations::current_location_is_eligible()
    }

    fn state(&self) -> ServiceState {
        let service = unsafe { SMAppService::mainAppService() };
        let status = unsafe { service.status() };
        if status == SMAppServiceStatus::Enabled {
            ServiceState::Enabled
        } else if status == SMAppServiceStatus::RequiresApproval {
            ServiceState::RequiresApproval
        } else {
            ServiceState::Off
        }
    }

    fn register(&self) -> Result<(), BridgeError> {
        let service = unsafe { SMAppService::mainAppService() };
        unsafe { service.registerAndReturnError() }
            .map_err(|error| BridgeError::engine(error.localizedDescription().to_string()))
    }

    fn unregister(&self) -> Result<(), BridgeError> {
        let service = unsafe { SMAppService::mainAppService() };
        unsafe { service.unregisterAndReturnError() }
            .map_err(|error| BridgeError::engine(error.localizedDescription().to_string()))
    }
}

struct SystemLaunchAtLogin {
    service: Arc<dyn LoginItemService>,
}

impl SystemLaunchAtLogin {
    fn new(service: Arc<dyn LoginItemService>) -> Self {
        Self { service }
    }
}

impl LaunchAtLoginImpl for SystemLaunchAtLogin {
    fn status(&self) -> Result<LaunchAtLoginStatus, BridgeError> {
        if !self.service.can_register() {
            return Ok(LaunchAtLoginStatus::Unavailable);
        }
        Ok(match self.service.state() {
            ServiceState::Enabled => LaunchAtLoginStatus::Available { enabled: true },
            ServiceState::RequiresApproval => LaunchAtLoginStatus::RequiresApproval,
            ServiceState::Off => LaunchAtLoginStatus::Available { enabled: false },
        })
    }

    fn set_enabled(&self, enabled: bool) -> Result<LaunchAtLoginStatus, BridgeError> {
        // Registering leaves a switched-off item switched off, so there is
        // nothing to ask the system for; the panel explains what the user
        // has to do. Turning it off again does unregister it.
        operations::change_enabled(
            enabled,
            || self.status(),
            || self.service.register(),
            || self.service.unregister(),
        )
    }
}

#[cfg(test)]
impl LaunchAtLoginImpl for operations::SyntheticLoginStatus {
    fn status(&self) -> Result<LaunchAtLoginStatus, BridgeError> {
        self.observe()
    }

    fn set_enabled(&self, enabled: bool) -> Result<LaunchAtLoginStatus, BridgeError> {
        self.change_enabled(enabled)
    }
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::{AtomicUsize, Ordering};

    use super::*;

    /// The service manager: the status System Settings shows, and how often it
    /// was asked for it.
    struct CountingLaunchAtLogin {
        status: Mutex<LaunchAtLoginStatus>,
        reads: AtomicUsize,
    }

    impl LaunchAtLoginImpl for CountingLaunchAtLogin {
        fn status(&self) -> Result<LaunchAtLoginStatus, BridgeError> {
            self.reads.fetch_add(1, Ordering::SeqCst);
            Ok(*self.status.lock().unwrap())
        }

        fn set_enabled(&self, enabled: bool) -> Result<LaunchAtLoginStatus, BridgeError> {
            let status = LaunchAtLoginStatus::Available { enabled };
            *self.status.lock().unwrap() = status;
            Ok(status)
        }
    }

    fn controller(enabled: bool) -> (LaunchAtLoginController, Arc<CountingLaunchAtLogin>) {
        let system = Arc::new(CountingLaunchAtLogin {
            status: Mutex::new(LaunchAtLoginStatus::Available { enabled }),
            reads: AtomicUsize::new(0),
        });
        (LaunchAtLoginController::new(system.clone()), system)
    }

    #[test]
    fn a_burst_of_snapshots_asks_the_service_manager_once() {
        let (controller, system) = controller(true);
        let start = Instant::now();

        for step in 0..100 {
            assert_eq!(
                controller.status_at(start + Duration::from_millis(step * 10)),
                LaunchAtLoginStatus::Available { enabled: true }
            );
        }

        assert_eq!(system.reads.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn a_change_made_in_system_settings_shows_once_the_last_read_has_aged() {
        let (controller, system) = controller(false);
        let start = Instant::now();
        assert_eq!(
            controller.status_at(start),
            LaunchAtLoginStatus::Available { enabled: false }
        );

        *system.status.lock().unwrap() = LaunchAtLoginStatus::Available { enabled: true };

        assert_eq!(
            controller.status_at(start + STATUS_FRESHNESS),
            LaunchAtLoginStatus::Available { enabled: true }
        );
    }

    /// The system's login item service: the state System Settings shows, the
    /// state a registration leaves behind, and what the app asked of it.
    struct FakeLoginItem {
        can_register: bool,
        state: Mutex<ServiceState>,
        state_after_register: ServiceState,
        registers: AtomicUsize,
        unregisters: AtomicUsize,
    }

    impl FakeLoginItem {
        fn new(state: ServiceState) -> Arc<Self> {
            Arc::new(Self {
                can_register: true,
                state: Mutex::new(state),
                state_after_register: ServiceState::Enabled,
                registers: AtomicUsize::new(0),
                unregisters: AtomicUsize::new(0),
            })
        }

        fn registrations(&self) -> usize {
            self.registers.load(Ordering::SeqCst)
        }

        fn unregistrations(&self) -> usize {
            self.unregisters.load(Ordering::SeqCst)
        }
    }

    impl LoginItemService for FakeLoginItem {
        fn can_register(&self) -> bool {
            self.can_register
        }

        fn state(&self) -> ServiceState {
            *self.state.lock().unwrap()
        }

        fn register(&self) -> Result<(), BridgeError> {
            self.registers.fetch_add(1, Ordering::SeqCst);
            *self.state.lock().unwrap() = self.state_after_register;
            Ok(())
        }

        fn unregister(&self) -> Result<(), BridgeError> {
            self.unregisters.fetch_add(1, Ordering::SeqCst);
            *self.state.lock().unwrap() = ServiceState::Off;
            Ok(())
        }
    }

    fn system(service: &Arc<FakeLoginItem>) -> SystemLaunchAtLogin {
        SystemLaunchAtLogin::new(service.clone())
    }

    #[test]
    fn what_the_service_manager_reports_decides_the_status() {
        for (state, expected) in [
            (ServiceState::Enabled, LaunchAtLoginStatus::Available { enabled: true }),
            (ServiceState::Off, LaunchAtLoginStatus::Available { enabled: false }),
            (ServiceState::RequiresApproval, LaunchAtLoginStatus::RequiresApproval),
        ] {
            let service = FakeLoginItem::new(state);
            assert_eq!(system(&service).status().unwrap(), expected, "{state:?}");
        }
    }

    #[test]
    fn an_app_outside_applications_is_unavailable_whatever_the_service_says() {
        let service = Arc::new(FakeLoginItem {
            can_register: false,
            state: Mutex::new(ServiceState::RequiresApproval),
            state_after_register: ServiceState::Enabled,
            registers: AtomicUsize::new(0),
            unregisters: AtomicUsize::new(0),
        });
        let login = system(&service);

        assert_eq!(login.status().unwrap(), LaunchAtLoginStatus::Unavailable);
        assert!(login.set_enabled(true).is_err());
        assert_eq!(service.registrations(), 0);
    }

    #[test]
    fn turning_it_on_registers_once_and_reports_what_the_system_made_of_it() {
        let service = FakeLoginItem::new(ServiceState::Off);

        let status = system(&service).set_enabled(true).unwrap();

        assert_eq!(status, LaunchAtLoginStatus::Available { enabled: true });
        assert_eq!(service.registrations(), 1);
    }

    #[test]
    fn a_registration_the_system_holds_back_reports_requires_approval() {
        let service = Arc::new(FakeLoginItem {
            can_register: true,
            state: Mutex::new(ServiceState::Off),
            state_after_register: ServiceState::RequiresApproval,
            registers: AtomicUsize::new(0),
            unregisters: AtomicUsize::new(0),
        });

        let status = system(&service).set_enabled(true).unwrap();

        assert_eq!(status, LaunchAtLoginStatus::RequiresApproval);
    }

    #[test]
    fn enabling_while_approval_is_pending_does_not_call_register_and_reports_requires_approval() {
        let service = FakeLoginItem::new(ServiceState::RequiresApproval);

        let status = system(&service).set_enabled(true).unwrap();

        assert_eq!(status, LaunchAtLoginStatus::RequiresApproval);
        assert_eq!(service.registrations(), 0, "registering cannot undo the user's choice");
    }

    #[test]
    fn disabling_while_approval_is_pending_unregisters() {
        let service = FakeLoginItem::new(ServiceState::RequiresApproval);

        let status = system(&service).set_enabled(false).unwrap();

        assert_eq!(status, LaunchAtLoginStatus::Available { enabled: false });
        assert_eq!(service.unregistrations(), 1);
    }

    #[test]
    fn asking_for_the_state_it_already_has_changes_nothing() {
        let on = FakeLoginItem::new(ServiceState::Enabled);
        assert_eq!(
            system(&on).set_enabled(true).unwrap(),
            LaunchAtLoginStatus::Available { enabled: true }
        );
        let off = FakeLoginItem::new(ServiceState::Off);
        assert_eq!(
            system(&off).set_enabled(false).unwrap(),
            LaunchAtLoginStatus::Available { enabled: false }
        );
        assert_eq!(on.registrations() + on.unregistrations(), 0);
        assert_eq!(off.registrations() + off.unregistrations(), 0);
    }

    #[test]
    fn approval_given_in_system_settings_shows_once_the_last_read_has_aged() {
        let (controller, system) = controller(false);
        *system.status.lock().unwrap() = LaunchAtLoginStatus::RequiresApproval;
        let start = Instant::now();
        assert_eq!(controller.status_at(start), LaunchAtLoginStatus::RequiresApproval);

        *system.status.lock().unwrap() = LaunchAtLoginStatus::Available { enabled: true };

        assert_eq!(
            controller.status_at(start + STATUS_FRESHNESS - Duration::from_millis(1)),
            LaunchAtLoginStatus::RequiresApproval,
            "a read this recent still stands"
        );
        assert_eq!(
            controller.status_at(start + STATUS_FRESHNESS),
            LaunchAtLoginStatus::Available { enabled: true }
        );
    }

    #[test]
    fn a_change_made_in_the_app_shows_at_once() {
        let (controller, _system) = controller(false);
        assert_eq!(
            controller.status(),
            LaunchAtLoginStatus::Available { enabled: false }
        );

        controller.set_enabled(true).unwrap();

        assert_eq!(
            controller.status(),
            LaunchAtLoginStatus::Available { enabled: true }
        );
    }
}
