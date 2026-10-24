use super::{LaunchAtLoginStatus, SyntheticLoginStatus, change_enabled, location_is_eligible};
use crate::{BridgeError, BridgeErrorKind};
use std::cell::{Cell, RefCell};
use std::path::Path;
use std::sync::Arc;

#[derive(Debug, PartialEq, Eq)]
enum Request {
    Observe,
    Register,
    Unregister,
}

fn attempt(
    enabled: bool,
    observations: impl IntoIterator<Item = Result<LaunchAtLoginStatus, BridgeError>>,
    register_result: Result<(), BridgeError>,
    unregister_result: Result<(), BridgeError>,
) -> (Result<LaunchAtLoginStatus, BridgeError>, Vec<Request>) {
    let mut observations = observations.into_iter();
    let mut register_result = Some(register_result);
    let mut unregister_result = Some(unregister_result);
    let requests = RefCell::new(Vec::new());
    let result = change_enabled(
        enabled,
        || {
            requests.borrow_mut().push(Request::Observe);
            observations.next().expect("unexpected extra observation")
        },
        || {
            requests.borrow_mut().push(Request::Register);
            register_result.take().expect("registration repeated")
        },
        || {
            requests.borrow_mut().push(Request::Unregister);
            unregister_result.take().expect("unregistration repeated")
        },
    );
    (result, requests.into_inner())
}

fn assert_status(result: Result<LaunchAtLoginStatus, BridgeError>, expected: LaunchAtLoginStatus) {
    match result {
        Ok(actual) => assert_eq!(actual, expected),
        Err(_) => panic!("expected successful status"),
    }
}

fn assert_error_kind(result: Result<LaunchAtLoginStatus, BridgeError>, expected: BridgeErrorKind) {
    let error = match result {
        Err(error) => error,
        Ok(_) => panic!("expected an error"),
    };
    assert_eq!(error.kind(), expected);
}

#[test]
fn missing_or_empty_bundle_is_not_an_installed_location() {
    let home = Some(Path::new("/Users/Rowan"));
    assert!(!location_is_eligible(None, None));
    assert!(!location_is_eligible(None, home));
    assert!(!location_is_eligible(Some(Path::new("")), home));
}

#[test]
fn system_prefix_uses_components_without_resolving_parent_directories() {
    for (bundle, eligible) in [
        ("/Applications", true),
        ("/Applications/Unusual name", true),
        ("/Applications//./Nested/Orchid.app", true),
        ("/Applications/../Elsewhere/Orchid.app", true),
        ("/ApplicationsBackup/Orchid.app", false),
        ("/System/Applications/Orchid.app", false),
        ("/applications/Orchid.app", false),
        ("Applications/Orchid.app", false),
        ("/Volumes/Staging/Applications/Orchid.app", false),
        ("/Scratch/../Applications/Orchid.app", false),
    ] {
        assert_eq!(
            location_is_eligible(Some(Path::new(bundle)), None),
            eligible,
            "{bundle}",
        );
    }
}

#[test]
fn home_prefix_is_an_independent_optional_alternative() {
    for (bundle, home, eligible) in [
        ("/Applications/Maple.app", Some("/Users/Rowan"), true),
        ("/Applications/Maple.app", None, true),
        ("/Users/Rowan/Applications", Some("/Users/Rowan"), true),
        (
            "/Users/Rowan/Applications/Maple",
            Some("/Users/Rowan"),
            true,
        ),
        (
            "/Users/Rowan/Applications/../Outside/Maple.app",
            Some("/Users/Rowan"),
            true,
        ),
        ("/Users/Rowan/Applications/Maple.app", None, false),
        (
            "/Users/Rowan/Applications/Maple.app",
            Some("/Users/Casey"),
            false,
        ),
        (
            "/Users/Rowan/Applications-old/Maple.app",
            Some("/Users/Rowan"),
            false,
        ),
        (
            "/Users/Rowan/Desktop/Maple.app",
            Some("/Users/Rowan"),
            false,
        ),
    ] {
        assert_eq!(
            location_is_eligible(Some(Path::new(bundle)), home.map(Path::new)),
            eligible,
            "bundle={bundle}, home={home:?}",
        );
    }
}

#[test]
fn supplied_home_is_joined_without_extra_location_validation() {
    for (bundle, home, eligible) in [
        (
            "profiles/rowan/Applications/Unpackaged",
            "profiles/rowan",
            true,
        ),
        ("Applications/Unpackaged", "", true),
        (
            "/Users/Rowan/../Casey/Applications/Cedar.app",
            "/Users/Rowan/../Casey",
            true,
        ),
        (
            "/Users/Casey/Applications/Cedar.app",
            "/Users/Rowan/../Casey",
            false,
        ),
    ] {
        assert_eq!(
            location_is_eligible(Some(Path::new(bundle)), Some(Path::new(home))),
            eligible,
            "bundle={bundle}, home={home}",
        );
    }
}

#[test]
fn satisfied_requests_and_approval_enable_need_only_the_initial_observation() {
    for (enabled, initial) in [
        (true, LaunchAtLoginStatus::Available { enabled: true }),
        (false, LaunchAtLoginStatus::Available { enabled: false }),
        (true, LaunchAtLoginStatus::RequiresApproval),
    ] {
        let (result, requests) = attempt(enabled, [Ok(initial)], Ok(()), Ok(()));
        assert_status(result, initial);
        assert_eq!(requests, [Request::Observe]);
    }
}

#[test]
fn initial_unavailability_rejects_either_request_without_a_mutation() {
    for enabled in [false, true] {
        let (result, requests) = attempt(
            enabled,
            [Ok(LaunchAtLoginStatus::Unavailable)],
            Ok(()),
            Ok(()),
        );
        assert_error_kind(result, BridgeErrorKind::InvalidInput);
        assert_eq!(requests, [Request::Observe]);
    }
}

#[test]
fn initial_observation_errors_do_not_issue_an_operation() {
    for (enabled, error, expected) in [
        (
            true,
            BridgeError::engine("initial provider interrupted"),
            BridgeErrorKind::Engine,
        ),
        (
            false,
            BridgeError::invalid_input("initial provider rejected observation"),
            BridgeErrorKind::InvalidInput,
        ),
    ] {
        let (result, requests) = attempt(enabled, [Err(error)], Ok(()), Ok(()));
        assert_error_kind(result, expected);
        assert_eq!(requests, [Request::Observe]);
    }
}

#[test]
fn register_success_reports_every_possible_confirmation_instead_of_the_target() {
    for confirmed in [
        LaunchAtLoginStatus::Available { enabled: false },
        LaunchAtLoginStatus::RequiresApproval,
        LaunchAtLoginStatus::Unavailable,
        LaunchAtLoginStatus::Available { enabled: true },
    ] {
        let (result, requests) = attempt(
            true,
            [
                Ok(LaunchAtLoginStatus::Available { enabled: false }),
                Ok(confirmed),
            ],
            Ok(()),
            Ok(()),
        );
        assert_status(result, confirmed);
        assert_eq!(
            requests,
            [Request::Observe, Request::Register, Request::Observe]
        );
    }
}

#[test]
fn unregister_success_reports_every_confirmation_from_enabled_or_approval() {
    for initial in [
        LaunchAtLoginStatus::RequiresApproval,
        LaunchAtLoginStatus::Available { enabled: true },
    ] {
        for confirmed in [
            LaunchAtLoginStatus::RequiresApproval,
            LaunchAtLoginStatus::Available { enabled: true },
            LaunchAtLoginStatus::Available { enabled: false },
            LaunchAtLoginStatus::Unavailable,
        ] {
            let (result, requests) = attempt(false, [Ok(initial), Ok(confirmed)], Ok(()), Ok(()));
            assert_status(result, confirmed);
            assert_eq!(
                requests,
                [Request::Observe, Request::Unregister, Request::Observe],
            );
        }
    }
}

#[test]
fn operation_rejections_skip_confirmation_and_any_other_operation() {
    let (result, requests) = attempt(
        true,
        [
            Ok(LaunchAtLoginStatus::Available { enabled: false }),
            Ok(LaunchAtLoginStatus::Available { enabled: true }),
        ],
        Err(BridgeError::engine("registration denied by the service")),
        Ok(()),
    );
    assert_error_kind(result, BridgeErrorKind::Engine);
    assert_eq!(requests, [Request::Observe, Request::Register]);

    for initial in [
        LaunchAtLoginStatus::Available { enabled: true },
        LaunchAtLoginStatus::RequiresApproval,
    ] {
        let (result, requests) = attempt(
            false,
            [
                Ok(initial),
                Ok(LaunchAtLoginStatus::Available { enabled: false }),
            ],
            Ok(()),
            Err(BridgeError::engine("unregistration denied by the service")),
        );
        assert_error_kind(result, BridgeErrorKind::Engine);
        assert_eq!(requests, [Request::Observe, Request::Unregister]);
    }
}

#[test]
fn confirmation_errors_remain_errors_after_a_successful_operation() {
    let (result, requests) = attempt(
        true,
        [
            Ok(LaunchAtLoginStatus::Available { enabled: false }),
            Err(BridgeError::invalid_input(
                "confirmation source unavailable",
            )),
        ],
        Ok(()),
        Ok(()),
    );
    assert_error_kind(result, BridgeErrorKind::InvalidInput);
    assert_eq!(
        requests,
        [Request::Observe, Request::Register, Request::Observe]
    );

    for initial in [
        LaunchAtLoginStatus::RequiresApproval,
        LaunchAtLoginStatus::Available { enabled: true },
    ] {
        let (result, requests) = attempt(
            false,
            [
                Ok(initial),
                Err(BridgeError::engine("confirmation provider interrupted")),
            ],
            Ok(()),
            Ok(()),
        );
        assert_error_kind(result, BridgeErrorKind::Engine);
        assert_eq!(
            requests,
            [Request::Observe, Request::Unregister, Request::Observe],
        );
    }
}

#[test]
fn losing_an_eligible_path_during_registration_is_a_successful_unavailable_result() {
    let bundle = Cell::new(Path::new("/Applications/Willow.app"));
    let reads = Cell::new(0);
    let registrations = Cell::new(0);
    let unregistrations = Cell::new(0);
    let result = change_enabled(
        true,
        || {
            reads.set(reads.get() + 1);
            if location_is_eligible(Some(bundle.get()), None) {
                Ok(LaunchAtLoginStatus::Available { enabled: false })
            } else {
                Ok(LaunchAtLoginStatus::Unavailable)
            }
        },
        || {
            registrations.set(registrations.get() + 1);
            bundle.set(Path::new("/Volumes/Staging/Willow.app"));
            Ok(())
        },
        || {
            unregistrations.set(unregistrations.get() + 1);
            Ok(())
        },
    );
    assert_status(result, LaunchAtLoginStatus::Unavailable);
    assert_eq!(reads.get(), 2);
    assert_eq!(registrations.get(), 1);
    assert_eq!(unregistrations.get(), 0);
}

#[test]
fn synthetic_unavailability_is_unchanged_by_either_rejected_request() {
    let state = SyntheticLoginStatus::new(LaunchAtLoginStatus::Unavailable);
    for enabled in [true, false, true] {
        assert_error_kind(state.change_enabled(enabled), BridgeErrorKind::InvalidInput);
        assert_status(state.observe(), LaunchAtLoginStatus::Unavailable);
    }
}

#[test]
fn synthetic_shared_state_retains_successive_mutations_without_native_access() {
    fn require_send_sync<T: Send + Sync>() {}
    require_send_sync::<SyntheticLoginStatus>();

    let first = Arc::new(SyntheticLoginStatus::new(
        LaunchAtLoginStatus::RequiresApproval,
    ));
    let second = Arc::clone(&first);
    assert_status(
        first.change_enabled(true),
        LaunchAtLoginStatus::RequiresApproval,
    );
    assert_status(second.observe(), LaunchAtLoginStatus::RequiresApproval);
    assert_status(
        second.change_enabled(false),
        LaunchAtLoginStatus::Available { enabled: false },
    );
    assert_status(
        first.observe(),
        LaunchAtLoginStatus::Available { enabled: false },
    );
    assert_status(
        first.change_enabled(true),
        LaunchAtLoginStatus::Available { enabled: true },
    );
    assert_status(
        second.observe(),
        LaunchAtLoginStatus::Available { enabled: true },
    );
}
