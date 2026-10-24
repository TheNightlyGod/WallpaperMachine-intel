use super::LaunchAtLoginStatus;
use crate::BridgeError;
use objc2_foundation::NSBundle;
use std::path::{Path, PathBuf};

pub(super) fn bundle_location() -> Option<PathBuf> {
    let bundle = NSBundle::mainBundle();
    let url = bundle.bundleURL();
    let path = url.path()?;
    Some(PathBuf::from(path.to_string()))
}

pub(super) fn location_is_eligible(bundle: Option<&Path>, home: Option<&Path>) -> bool {
    let Some(bundle) = bundle else {
        return false;
    };

    bundle.starts_with("/Applications")
        || home
            .map(|home| bundle.starts_with(home.join("Applications")))
            .unwrap_or(false)
}

pub(super) fn current_location_is_eligible() -> bool {
    let Some(bundle) = bundle_location() else {
        return false;
    };
    let home = dirs::home_dir();
    location_is_eligible(Some(&bundle), home.as_deref())
}

pub(super) fn change_enabled<O, R, U>(
    enabled: bool,
    mut observe: O,
    mut register: R,
    mut unregister: U,
) -> Result<LaunchAtLoginStatus, BridgeError>
where
    O: FnMut() -> Result<LaunchAtLoginStatus, BridgeError>,
    R: FnMut() -> Result<(), BridgeError>,
    U: FnMut() -> Result<(), BridgeError>,
{
    let initial = observe()?;
    match initial {
        LaunchAtLoginStatus::Unavailable => {
            return Err(BridgeError::invalid_input(
                "launch at login is available only when the app is installed in Applications",
            ));
        }
        LaunchAtLoginStatus::Available { enabled: current } if current == enabled => {
            return Ok(initial);
        }
        LaunchAtLoginStatus::RequiresApproval if enabled => return Ok(initial),
        _ => {}
    }

    if enabled {
        register()?;
    } else {
        unregister()?;
    }
    observe()
}

#[cfg(test)]
pub(super) struct SyntheticLoginStatus {
    status: std::sync::Mutex<LaunchAtLoginStatus>,
}

#[cfg(test)]
impl SyntheticLoginStatus {
    pub(super) fn new(status: LaunchAtLoginStatus) -> Self {
        Self {
            status: std::sync::Mutex::new(status),
        }
    }

    pub(super) fn observe(&self) -> Result<LaunchAtLoginStatus, BridgeError> {
        let status = self
            .status
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        Ok(*status)
    }

    pub(super) fn change_enabled(&self, enabled: bool) -> Result<LaunchAtLoginStatus, BridgeError> {
        let mut stored = self
            .status
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        let status = std::cell::Cell::new(*stored);
        let result = change_enabled(
            enabled,
            || Ok(status.get()),
            || {
                status.set(LaunchAtLoginStatus::Available { enabled: true });
                Ok(())
            },
            || {
                status.set(LaunchAtLoginStatus::Available { enabled: false });
                Ok(())
            },
        );
        *stored = status.get();
        result
    }
}

#[cfg(test)]
#[path = "contract_tests.rs"]
mod contract_tests;
