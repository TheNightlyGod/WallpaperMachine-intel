//! How the launch-at-login status moves when the user asks for it on or off.

use std::cell::Cell;

use super::{LaunchAtLoginStatus, operations::SyntheticLoginStatus};
use crate::api::BridgeErrorKind;

const ENABLED: LaunchAtLoginStatus = LaunchAtLoginStatus::Available { enabled: true };
const DISABLED: LaunchAtLoginStatus = LaunchAtLoginStatus::Available { enabled: false };

#[test]
fn a_request_leaves_the_status_the_table_predicts() {
    let table = [
        (ENABLED, true, ENABLED),
        (ENABLED, false, DISABLED),
        (DISABLED, true, ENABLED),
        (DISABLED, false, DISABLED),
        // Registering cannot grant approval the user withdrew.
        (LaunchAtLoginStatus::RequiresApproval, true, LaunchAtLoginStatus::RequiresApproval),
        // Unregistering clears the pending approval.
        (LaunchAtLoginStatus::RequiresApproval, false, DISABLED),
    ];

    for (initial, request, expected) in table {
        let status = SyntheticLoginStatus::new(initial);
        assert_eq!(status.observe().unwrap(), initial, "initial {initial:?}");

        let returned = status.change_enabled(request).unwrap();

        assert_eq!(returned, expected, "{initial:?} asked {request}");
        assert_eq!(status.observe().unwrap(), expected, "{initial:?} asked {request}, observed after");
    }
}

#[test]
fn only_a_request_that_changes_something_touches_the_system_service() {
    // (initial, request, registrations, unregistrations)
    let table = [
        (ENABLED, true, 0, 0),
        (ENABLED, false, 0, 1),
        (DISABLED, true, 1, 0),
        (DISABLED, false, 0, 0),
        (LaunchAtLoginStatus::RequiresApproval, true, 0, 0),
        (LaunchAtLoginStatus::RequiresApproval, false, 0, 1),
    ];

    for (initial, request, registrations, unregistrations) in table {
        let status = Cell::new(initial);
        let (registered, unregistered) = (Cell::new(0), Cell::new(0));

        super::operations::change_enabled(
            request,
            || Ok(status.get()),
            || {
                registered.set(registered.get() + 1);
                status.set(ENABLED);
                Ok(())
            },
            || {
                unregistered.set(unregistered.get() + 1);
                status.set(DISABLED);
                Ok(())
            },
        )
        .unwrap();

        assert_eq!(
            (registered.get(), unregistered.get()),
            (registrations, unregistrations),
            "{initial:?} asked {request}"
        );
    }
}

#[test]
fn an_app_outside_applications_cannot_change_the_setting() {
    let status = SyntheticLoginStatus::new(LaunchAtLoginStatus::Unavailable);

    for request in [true, false] {
        let error = status.change_enabled(request).unwrap_err();

        assert_eq!(error.kind(), BridgeErrorKind::InvalidInput, "asked {request}");
        assert_eq!(status.observe().unwrap(), LaunchAtLoginStatus::Unavailable);
    }
}
