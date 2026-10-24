// M01-M32: public configuration/record arrangements and real model operations.
// Mounted by the parent as a #[cfg(test)] child of display::state.
use super::*;
use crate::project::{SceneDesc, SceneTemplate};
use crate::{
    DisplayConfig, DisplayDesc, DisplayIdentity, DisplaySelector, EngineError, WallpaperAssignment,
    WallpaperEngineConfig,
};

// These utilities arrange values only; they neither implement matching/planning
// nor open a runtime. Narrow sibling access permits parent-owned retained tests
// to reuse the new arrangements without compatibility aliases.
pub(super) fn contract_identity(token: u32) -> DisplayIdentity {
    DisplayIdentity {
        uuid: Some(format!("contract-panel-{token}")),
        vendor_id: Some(1979),
        model_id: Some(2029),
        serial_number: Some(token),
        unit_number: Some(token),
        name: Some(format!("Contract panel {token}")),
    }
}

pub(super) fn contract_display(display_id: u32) -> DisplayDesc {
    DisplayDesc::with_identity(
        display_id,
        contract_identity(display_id),
        -96,
        48,
        1680,
        1050,
        1.5,
    )
    .with_refresh_rate(90)
}

pub(super) fn contract_assignment(label: &str) -> WallpaperAssignment {
    WallpaperAssignment::Direct(
        SceneTemplate::builder(format!("contract-scenes/{label}/scene.json"))
            .build()
            .expect("nonempty synthetic scene path is valid"),
    )
}

pub(super) fn contract_config(
    selector: DisplaySelector,
    window_active: bool,
    wallpaper: Option<WallpaperAssignment>,
) -> DisplayConfig {
    DisplayConfig {
        selector,
        window_active,
        wallpaper,
    }
}

pub(super) fn contract_model(displays: Vec<DisplayConfig>) -> DisplayStateModel {
    DisplayStateModel::from_config(WallpaperEngineConfig { displays })
        .expect("arranged acyclic configuration is valid")
}

pub(super) struct RunningLayout {
    pub(super) model: DisplayStateModel,
    pub(super) primary_display: DisplayDesc,
    pub(super) secondary_display: DisplayDesc,
    pub(super) primary_assignment: WallpaperAssignment,
    pub(super) secondary_assignment: WallpaperAssignment,
}

pub(super) fn running_layout() -> RunningLayout {
    let primary_display = contract_display(117);
    let secondary_display =
        DisplayDesc::with_identity(229, contract_identity(229), 1584, -120, 2560, 1440, 2.0)
            .with_refresh_rate(120);
    let primary_assignment = contract_assignment("aurora");
    let secondary_assignment = contract_assignment("harbor");
    let model = DisplayStateModel {
        records: vec![
            DisplayRecord {
                key: DisplayKey::Primary,
                live_display: Some(primary_display.clone()),
                assignment: Some(primary_assignment.clone()),
                window_active: true,
                runtime_open: true,
                primary_inheritance_consumed: false,
                bound_to_display: false,
            },
            DisplayRecord {
                key: DisplayKey::Identity(secondary_display.identity.clone()),
                live_display: Some(secondary_display.clone()),
                assignment: Some(secondary_assignment.clone()),
                window_active: false,
                runtime_open: true,
                primary_inheritance_consumed: true,
                bound_to_display: false,
            },
        ],
    };
    RunningLayout {
        model,
        primary_display,
        secondary_display,
        primary_assignment,
        secondary_assignment,
    }
}

// M01
#[test]
fn empty_configuration_has_one_active_unattached_primary() {
    let model = DisplayStateModel::from_config(WallpaperEngineConfig::default())
        .expect("empty configuration is valid");
    assert_eq!(model.records.len(), 1);
    let primary = &model.records[0];
    assert_eq!(primary.key, DisplayKey::Primary);
    assert!(primary.window_active);
    assert_eq!(primary.assignment, None);
    assert_eq!(primary.live_display, None);
    assert!(!primary.runtime_open);
    assert!(!primary.should_have_runtime());
}

// M02
#[test]
fn future_identity_configuration_retains_activity_and_whole_assignment() {
    let identity = contract_identity(229);
    let assignment = contract_assignment("future-orchard");
    let model = contract_model(vec![contract_config(
        DisplaySelector::Identity(identity.clone()),
        true,
        Some(assignment.clone()),
    )]);
    assert_eq!(model.records.len(), 2);
    assert_eq!(model.records[0].key, DisplayKey::Primary);
    let future = &model.records[1];
    assert_eq!(future.key, DisplayKey::Identity(identity));
    assert!(future.window_active);
    assert_eq!(future.assignment, Some(assignment));
    assert_eq!(future.live_display, None);
    assert!(!future.runtime_open);
}

// M03
#[test]
fn automatic_secondary_inherits_once_and_remains_inactive() {
    let primary = contract_display(117);
    let secondary = contract_display(229);
    let first = contract_assignment("first-primary");
    let later = contract_assignment("later-primary");
    let mut model = contract_model(vec![contract_config(
        DisplaySelector::Primary,
        true,
        Some(first.clone()),
    )]);
    model
        .refresh_connected(primary.clone(), vec![primary.clone(), secondary.clone()])
        .expect("first connection succeeds");
    assert_eq!(model.records.len(), 2);
    assert_eq!(
        model.records[1].key,
        DisplayKey::Identity(secondary.identity.clone())
    );
    assert_eq!(model.records[1].live_display, Some(secondary.clone()));
    assert_eq!(model.records[1].assignment, Some(first.clone()));
    assert!(!model.records[1].window_active);
    assert!(model.records[1].primary_inheritance_consumed);

    model
        .set_assignment(&DisplaySelector::Primary, later.clone())
        .expect("new direct assignment is valid");
    model
        .refresh_connected(primary.clone(), vec![primary, secondary])
        .expect("repeat connection succeeds");
    assert_eq!(model.records[0].assignment, Some(later));
    assert_eq!(model.records[1].assignment, Some(first));
    assert!(!model.records[1].window_active);
}

// M04
#[test]
fn active_explicit_secondary_keeps_its_live_id_slot() {
    let primary = contract_display(117);
    let secondary = contract_display(229);
    let assignment = contract_assignment("explicit-secondary");
    let mut model = contract_model(vec![contract_config(
        DisplaySelector::LiveDisplayId(229),
        true,
        Some(assignment.clone()),
    )]);
    let actions = model
        .refresh_connected(primary.clone(), vec![primary, secondary.clone()])
        .expect("explicit live-id connection succeeds");
    assert_eq!(model.records.len(), 2);
    assert_eq!(model.records[0].key, DisplayKey::Primary);
    assert_eq!(model.records[1].key, DisplayKey::LiveDisplayId(229));
    assert_eq!(model.records[1].live_display, Some(secondary));
    assert_eq!(model.records[1].assignment, Some(assignment));
    assert!(model.records[1].window_active);
    assert_eq!(
        actions,
        vec![DisplayAction::Open(DisplayKey::LiveDisplayId(229))]
    );
}

// M05
#[test]
fn another_id_reporting_the_primary_identity_does_not_add_a_slot() {
    let primary = contract_display(117);
    let mut duplicate = primary.clone();
    duplicate.display_id = 338;
    duplicate.x = 2112;
    let mut model = contract_model(vec![]);
    model
        .refresh_connected(primary.clone(), vec![duplicate, primary.clone()])
        .expect("equivalent primary listing is ignored");
    assert_eq!(model.records.len(), 1);
    assert_eq!(model.records[0].key, DisplayKey::Primary);
    assert_eq!(model.records[0].live_display, Some(primary));
    assert!(!model.has_live_id(338));
}

// M06
#[test]
fn reconcile_reuses_connected_identity_and_preserves_requested_open_mark() {
    let primary = contract_display(117);
    let secondary = contract_display(229);
    let primary_assignment = contract_assignment("unrequested-primary");
    let mut model = contract_model(vec![
        contract_config(
            DisplaySelector::Primary,
            true,
            Some(primary_assignment.clone()),
        ),
        contract_config(
            DisplaySelector::Identity(secondary.identity.clone()),
            true,
            Some(contract_assignment("old-secondary")),
        ),
    ]);
    model
        .refresh_connected(primary.clone(), vec![primary.clone(), secondary.clone()])
        .expect("both displays connect");
    model.records[0].runtime_open = true;
    model.records[1].runtime_open = true;
    let requested = SceneDesc::new(
        secondary.clone(),
        "contract-scenes/reconciled/scene.json",
        "contract-assets",
        72,
        false,
    );
    let key = DisplayKey::Identity(secondary.identity.clone());
    let expected_assignment =
        WallpaperAssignment::Direct(SceneTemplate::from_scene_desc(&requested));
    assert_eq!(
        model
            .reconcile_key(&requested)
            .expect("connected request has a key"),
        key
    );
    model
        .apply_reconcile(&[requested])
        .expect("reconcile succeeds");

    assert_eq!(model.records.len(), 2);
    assert_eq!(model.records[0].key, DisplayKey::Primary);
    assert_eq!(model.records[0].live_display, Some(primary));
    assert_eq!(model.records[0].assignment, Some(primary_assignment));
    assert!(!model.records[0].window_active);
    assert!(!model.records[0].runtime_open);
    assert_eq!(model.records[1].key, key);
    assert_eq!(model.records[1].live_display, Some(secondary));
    assert_eq!(model.records[1].assignment, Some(expected_assignment));
    assert!(model.records[1].window_active);
    assert!(model.records[1].runtime_open);
    assert!(
        !model
            .records
            .iter()
            .any(|record| record.key == DisplayKey::LiveDisplayId(229))
    );
}

// M07
#[test]
fn secondary_connection_and_disconnection_have_exact_data_events() {
    let primary = contract_display(117);
    let secondary = contract_display(229);
    let key = DisplayKey::Identity(secondary.identity.clone());
    let mut model = contract_model(vec![]);
    model
        .refresh_connected(primary.clone(), vec![primary.clone()])
        .expect("primary connects");
    let without_secondary = model.clone();
    model
        .refresh_connected(primary.clone(), vec![primary.clone(), secondary.clone()])
        .expect("secondary connects");
    assert_eq!(
        model.debug_events_since(&without_secondary),
        vec![DisplayDebugEvent::Connected {
            key: key.clone(),
            display: secondary.clone()
        },]
    );
    let with_secondary = model.clone();
    model
        .refresh_connected(primary.clone(), vec![primary])
        .expect("secondary disconnects");
    assert_eq!(
        model.debug_events_since(&with_secondary),
        vec![DisplayDebugEvent::Disconnected {
            key: key.clone(),
            display: secondary
        },]
    );
    assert_eq!(model.records.len(), 2);
    assert_eq!(model.records[1].key, key);
    assert_eq!(model.records[1].live_display, None);
}

// M08
#[test]
fn scale_change_reports_both_descriptors_but_metadata_alone_is_not_geometry() {
    let original = contract_display(117);
    let mut changed = original.clone();
    changed.scale_factor = 2.25;
    let mut model = contract_model(vec![]);
    model
        .refresh_connected(original.clone(), vec![original.clone()])
        .expect("original display connects");
    let before = model.clone();
    model
        .refresh_connected(changed.clone(), vec![changed.clone()])
        .expect("scale change succeeds");
    assert_eq!(
        model.debug_events_since(&before),
        vec![DisplayDebugEvent::Changed {
            key: DisplayKey::Primary,
            before: original,
            after: changed,
        },]
    );

    let mut metadata_only = model.clone();
    let display = metadata_only.records[0]
        .live_display
        .as_mut()
        .expect("primary is live");
    display.identity.name = Some("Metadata-only name change".into());
    display.refresh_rate_hz = 165;
    assert!(metadata_only.debug_events_since(&model).is_empty());
}

// M09
#[test]
fn physical_primary_replacement_orders_connection_disconnection_then_change() {
    let original = contract_display(117);
    let replacement = contract_display(331);
    let mut model = contract_model(vec![]);
    model
        .refresh_connected(original.clone(), vec![original.clone()])
        .expect("original primary connects");
    let before = model.clone();
    model
        .refresh_connected(replacement.clone(), vec![replacement.clone()])
        .expect("replacement primary connects");
    assert_eq!(
        model.debug_events_since(&before),
        vec![
            DisplayDebugEvent::Connected {
                key: DisplayKey::Primary,
                display: replacement.clone()
            },
            DisplayDebugEvent::Disconnected {
                key: DisplayKey::Primary,
                display: original.clone()
            },
            DisplayDebugEvent::Changed {
                key: DisplayKey::Primary,
                before: original,
                after: replacement
            },
        ]
    );
}

// M10
#[test]
fn uuid_only_configuration_receives_the_full_live_identity_in_place() {
    let primary = contract_display(117);
    let secondary = contract_display(229);
    let partial = DisplayIdentity {
        uuid: secondary.identity.uuid.clone(),
        ..DisplayIdentity::default()
    };
    let mut model = contract_model(vec![contract_config(
        DisplaySelector::Identity(partial.clone()),
        true,
        None,
    )]);
    model
        .refresh_connected(primary.clone(), vec![primary, secondary.clone()])
        .expect("partial configured identity matches");
    assert_eq!(model.records.len(), 2);
    assert_eq!(model.records[1].key, DisplayKey::Identity(partial));
    assert_eq!(model.records[1].live_display, Some(secondary.clone()));
    assert!(
        !model
            .records
            .iter()
            .any(|record| { record.key == DisplayKey::Identity(secondary.identity.clone()) })
    );
}

// M11
#[test]
fn tied_best_identity_scores_reject_the_refresh_atomically() {
    let primary = contract_display(117);
    let secondary = contract_display(229);
    let first = DisplayIdentity {
        uuid: None,
        unit_number: Some(3),
        name: Some("Serial contender one".into()),
        ..secondary.identity.clone()
    };
    let second = DisplayIdentity {
        unit_number: Some(8),
        name: Some("Serial contender two".into()),
        ..first.clone()
    };
    assert_eq!(first.match_score(&secondary.identity), Some(3));
    assert_eq!(second.match_score(&secondary.identity), Some(3));
    let mut model = contract_model(vec![
        contract_config(
            DisplaySelector::Identity(first),
            true,
            Some(contract_assignment("tie-one")),
        ),
        contract_config(
            DisplaySelector::Identity(second),
            false,
            Some(contract_assignment("tie-two")),
        ),
    ]);
    let before = model.clone();
    let result = model.refresh_connected(primary.clone(), vec![primary, secondary]);
    assert!(matches!(result, Err(EngineError::InvalidInput(_))));
    assert_eq!(model, before);
}

// M12
#[test]
fn a_unique_serial_score_beats_tied_unit_scores() {
    let primary = contract_display(117);
    let secondary = contract_display(229);
    let lower_one = DisplayIdentity {
        uuid: None,
        serial_number: None,
        name: Some("Unit contender one".into()),
        ..secondary.identity.clone()
    };
    let lower_two = DisplayIdentity {
        name: Some("Unit contender two".into()),
        ..lower_one.clone()
    };
    let higher = DisplayIdentity {
        uuid: None,
        unit_number: Some(31),
        name: Some("Serial winner".into()),
        ..secondary.identity.clone()
    };
    assert_eq!(lower_one.match_score(&secondary.identity), Some(2));
    assert_eq!(lower_two.match_score(&secondary.identity), Some(2));
    assert_eq!(higher.match_score(&secondary.identity), Some(3));
    let mut model = contract_model(vec![
        contract_config(DisplaySelector::Identity(lower_one.clone()), false, None),
        contract_config(DisplaySelector::Identity(lower_two.clone()), false, None),
        contract_config(DisplaySelector::Identity(higher.clone()), true, None),
    ]);
    model
        .refresh_connected(primary.clone(), vec![primary, secondary.clone()])
        .expect("unique highest score wins");
    assert_eq!(model.records.len(), 4);
    assert_eq!(model.records[1].key, DisplayKey::Identity(lower_one));
    assert_eq!(model.records[2].key, DisplayKey::Identity(lower_two));
    assert_eq!(model.records[3].key, DisplayKey::Identity(higher));
    assert_eq!(model.records[1].live_display, None);
    assert_eq!(model.records[2].live_display, None);
    assert_eq!(model.records[3].live_display, Some(secondary));
}

// M13
#[test]
fn active_primary_displaces_an_inactive_stale_id_slot() {
    let primary = contract_display(117);
    let mut model = contract_model(vec![
        contract_config(
            DisplaySelector::Primary,
            true,
            Some(contract_assignment("active-primary")),
        ),
        contract_config(
            DisplaySelector::LiveDisplayId(117),
            false,
            Some(contract_assignment("stale-id")),
        ),
    ]);
    model.records[1].live_display = Some(primary.clone());
    let actions = model
        .refresh_connected(primary.clone(), vec![primary.clone()])
        .expect("active primary has precedence");
    assert_eq!(model.records.len(), 2);
    assert_eq!(model.records[0].key, DisplayKey::Primary);
    assert_eq!(model.records[0].live_display, Some(primary));
    assert_eq!(model.records[1].key, DisplayKey::LiveDisplayId(117));
    assert_eq!(model.records[1].live_display, None);
    assert!(!model.records[1].runtime_open);
    assert_eq!(actions, vec![DisplayAction::Open(DisplayKey::Primary)]);
}

// M14
#[test]
fn active_id_slot_can_host_primary_when_primary_slot_is_inactive_unopened() {
    let primary = contract_display(117);
    let primary_assignment = contract_assignment("inactive-primary");
    let mut model = contract_model(vec![
        contract_config(
            DisplaySelector::Primary,
            false,
            Some(primary_assignment.clone()),
        ),
        contract_config(
            DisplaySelector::LiveDisplayId(117),
            true,
            Some(contract_assignment("active-id")),
        ),
    ]);
    let actions = model
        .refresh_connected(primary.clone(), vec![primary.clone()])
        .expect("active live-id record has precedence");
    assert_eq!(model.records.len(), 2);
    assert_eq!(model.records[0].live_display, None);
    assert_eq!(model.records[0].assignment, Some(primary_assignment));
    assert!(!model.records[0].window_active);
    assert!(!model.records[0].runtime_open);
    assert_eq!(model.records[1].key, DisplayKey::LiveDisplayId(117));
    assert_eq!(model.records[1].live_display, Some(primary));
    assert_eq!(
        actions,
        vec![DisplayAction::Open(DisplayKey::LiveDisplayId(117))]
    );
}

// M15
#[test]
fn identity_slot_beats_an_inactive_assigned_id_fallback() {
    let primary = contract_display(117);
    let secondary = contract_display(229);
    let fallback_assignment = contract_assignment("inactive-fallback");
    let mut model = contract_model(vec![
        contract_config(
            DisplaySelector::LiveDisplayId(229),
            false,
            Some(fallback_assignment.clone()),
        ),
        contract_config(
            DisplaySelector::Identity(secondary.identity.clone()),
            true,
            Some(contract_assignment("identity-selected")),
        ),
    ]);
    model
        .refresh_connected(primary.clone(), vec![primary, secondary.clone()])
        .expect("configured identity takes the secondary");
    assert_eq!(model.records.len(), 3);
    assert_eq!(model.records[1].key, DisplayKey::LiveDisplayId(229));
    assert_eq!(model.records[1].live_display, None);
    assert_eq!(model.records[1].assignment, Some(fallback_assignment));
    assert!(!model.records[1].window_active);
    assert_eq!(
        model.records[2].key,
        DisplayKey::Identity(secondary.identity.clone())
    );
    assert_eq!(model.records[2].live_display, Some(secondary));
}

// M16
#[test]
fn two_distinct_live_ids_cannot_claim_one_configured_identity() {
    let primary = contract_display(117);
    let first = contract_display(229);
    let mut second = first.clone();
    second.display_id = 337;
    second.x = 3264;
    let partial = DisplayIdentity {
        uuid: first.identity.uuid.clone(),
        ..DisplayIdentity::default()
    };
    assert_ne!(first.display_id, second.display_id);
    assert_eq!(partial.match_score(&first.identity), Some(4));
    assert_eq!(partial.match_score(&second.identity), Some(4));
    let mut model = contract_model(vec![contract_config(
        DisplaySelector::Identity(partial),
        true,
        Some(contract_assignment("single-owner")),
    )]);
    let before = model.clone();
    let result = model.refresh_connected(primary.clone(), vec![primary, first, second]);
    assert!(matches!(result, Err(EngineError::InvalidInput(_))));
    assert_eq!(model, before);
}

// M17
#[test]
fn configured_active_future_secondary_inherits_without_losing_activity() {
    let primary = contract_display(117);
    let secondary = contract_display(229);
    let assignment = contract_assignment("configured-inheritance");
    let mut model = contract_model(vec![
        contract_config(DisplaySelector::Primary, true, Some(assignment.clone())),
        contract_config(
            DisplaySelector::Identity(secondary.identity.clone()),
            true,
            None,
        ),
    ]);
    assert_eq!(model.records[1].assignment, None);
    assert_eq!(model.records[1].live_display, None);
    model
        .refresh_connected(primary.clone(), vec![primary, secondary.clone()])
        .expect("configured secondary connects");
    assert_eq!(model.records.len(), 2);
    assert_eq!(model.records[1].live_display, Some(secondary));
    assert_eq!(model.records[1].assignment, Some(assignment));
    assert!(model.records[1].window_active);
    assert!(model.records[1].primary_inheritance_consumed);
}

// M18
#[test]
fn blank_first_inheritance_is_consumed_across_disconnect_and_reconnect() {
    let primary = contract_display(117);
    let secondary = contract_display(229);
    let mut model = contract_model(vec![]);
    model
        .refresh_connected(primary.clone(), vec![primary.clone(), secondary.clone()])
        .expect("blank primary and secondary connect");
    assert_eq!(model.records[1].assignment, None);
    assert!(model.records[1].primary_inheritance_consumed);
    model
        .set_assignment(&DisplaySelector::Primary, contract_assignment("too-late"))
        .expect("primary can subsequently acquire an assignment");
    model
        .refresh_connected(primary.clone(), vec![primary.clone()])
        .expect("secondary disconnects");
    assert_eq!(model.records[1].live_display, None);
    assert_eq!(model.records[1].assignment, None);
    assert!(model.records[1].primary_inheritance_consumed);
    model
        .refresh_connected(primary.clone(), vec![primary, secondary.clone()])
        .expect("secondary reconnects");
    assert_eq!(model.records.len(), 2);
    assert_eq!(model.records[1].live_display, Some(secondary));
    assert_eq!(model.records[1].assignment, None);
    assert!(!model.records[1].window_active);
    assert!(model.records[1].primary_inheritance_consumed);
}

// M19
#[test]
fn primary_switch_follows_both_running_physical_displays_in_slot_order() {
    let RunningLayout {
        primary_display,
        secondary_display,
        primary_assignment,
        secondary_assignment,
        ..
    } = running_layout();
    let old_secondary_key = DisplayKey::Identity(secondary_display.identity.clone());
    let former_primary_key = DisplayKey::Identity(primary_display.identity.clone());
    let destination_assignment = contract_assignment("switch-destination");
    let mut model = contract_model(vec![
        contract_config(DisplaySelector::Primary, true, Some(primary_assignment)),
        contract_config(
            DisplaySelector::Identity(secondary_display.identity.clone()),
            false,
            Some(secondary_assignment),
        ),
        contract_config(
            DisplaySelector::Identity(primary_display.identity.clone()),
            true,
            Some(destination_assignment.clone()),
        ),
    ]);
    model.records[0].live_display = Some(primary_display.clone());
    model.records[0].runtime_open = true;
    model.records[1].live_display = Some(secondary_display.clone());
    model.records[1].runtime_open = true;
    assert!(model.records[0].runtime_open);
    assert!(model.records[1].runtime_open);
    assert_eq!(model.records[2].key, former_primary_key);
    assert!(model.records[2].window_active);
    assert_eq!(
        model.records[2].assignment,
        Some(destination_assignment.clone())
    );
    assert_eq!(model.records[2].live_display, None);
    assert!(!model.records[2].runtime_open);
    let actions = model
        .refresh_connected(
            secondary_display.clone(),
            vec![secondary_display.clone(), primary_display.clone()],
        )
        .expect("main-display switch succeeds");

    assert_eq!(
        actions,
        vec![
            DisplayAction::Rebuild(DisplayKey::Primary),
            DisplayAction::Rebuild(former_primary_key.clone()),
        ]
    );
    assert_eq!(model.records.len(), 3);
    assert_eq!(model.records[0].key, DisplayKey::Primary);
    assert_eq!(model.records[0].live_display, Some(secondary_display));
    assert!(model.records[0].runtime_open);
    assert_eq!(model.records[1].key, old_secondary_key);
    assert_eq!(model.records[1].live_display, None);
    assert!(!model.records[1].runtime_open);
    assert_eq!(model.records[2].key, former_primary_key);
    assert_eq!(model.records[2].live_display, Some(primary_display));
    assert!(model.records[2].runtime_open);
    assert!(model.records[2].window_active);
    assert_eq!(model.records[2].assignment, Some(destination_assignment));
}

// M20
#[test]
fn mirror_reads_the_sources_current_assignment_not_an_initial_snapshot() {
    let identity = contract_identity(229);
    let key = DisplayKey::Identity(identity.clone());
    let mut model = contract_model(vec![contract_config(
        DisplaySelector::Identity(identity),
        false,
        Some(WallpaperAssignment::Mirror(DisplaySelector::Primary)),
    )]);
    assert_eq!(
        model
            .resolved_assignment(&key)
            .expect("blank source resolves"),
        None
    );
    let first = contract_assignment("mirror-first");
    model
        .set_assignment(&DisplaySelector::Primary, first.clone())
        .expect("source assignment can be added later");
    assert_eq!(
        model.resolved_assignment(&key).expect("mirror resolves"),
        Some(first)
    );
    let replacement = contract_assignment("mirror-replacement");
    model
        .set_assignment(&DisplaySelector::Primary, replacement.clone())
        .expect("source assignment can change");
    assert_eq!(
        model
            .resolved_assignment(&key)
            .expect("mirror follows source"),
        Some(replacement)
    );
}

// M21
#[test]
fn configuration_rejects_a_two_slot_mirror_cycle() {
    let secondary = DisplaySelector::Identity(contract_identity(229));
    let result = DisplayStateModel::from_config(WallpaperEngineConfig {
        displays: vec![
            contract_config(
                DisplaySelector::Primary,
                true,
                Some(WallpaperAssignment::Mirror(secondary.clone())),
            ),
            contract_config(
                secondary,
                true,
                Some(WallpaperAssignment::Mirror(DisplaySelector::Primary)),
            ),
        ],
    });
    assert!(matches!(result, Err(EngineError::InvalidInput(_))));
}

// M22
#[test]
fn self_mirror_assignment_rejection_preserves_the_entire_model() {
    let RunningLayout {
        mut model,
        secondary_display,
        ..
    } = running_layout();
    let selector = DisplaySelector::Identity(secondary_display.identity);
    let before = model.clone();
    let result = model.set_assignment(&selector, WallpaperAssignment::Mirror(selector.clone()));
    assert!(matches!(result, Err(EngineError::InvalidInput(_))));
    assert_eq!(model, before);
}

// M23
#[test]
fn inheritance_cannot_turn_a_blank_target_into_a_self_mirror() {
    let primary = contract_display(117);
    let secondary = contract_display(229);
    let selector = DisplaySelector::Identity(secondary.identity.clone());
    let mut model = contract_model(vec![
        contract_config(
            DisplaySelector::Primary,
            true,
            Some(WallpaperAssignment::Mirror(selector.clone())),
        ),
        contract_config(selector, false, None),
    ]);
    assert_eq!(model.records[1].assignment, None);
    assert!(!model.records[1].primary_inheritance_consumed);
    let before = model.clone();
    let result = model.refresh_connected(primary.clone(), vec![primary, secondary]);
    assert!(matches!(result, Err(EngineError::InvalidInput(_))));
    assert_eq!(model, before);
}

// M24
#[test]
fn first_usable_primary_connection_requests_exactly_one_open() {
    let primary = contract_display(117);
    let mut model = contract_model(vec![contract_config(
        DisplaySelector::Primary,
        true,
        Some(contract_assignment("opening-primary")),
    )]);
    assert!(!model.records[0].runtime_open);
    let actions = model
        .refresh_connected(primary.clone(), vec![primary.clone()])
        .expect("assigned active primary connects");
    assert_eq!(model.records[0].live_display, Some(primary));
    assert_eq!(actions, vec![DisplayAction::Open(DisplayKey::Primary)]);
}

// M25
#[test]
fn public_action_computation_rejects_an_arranged_cycle_without_mutation() {
    let primary = contract_display(117);
    let secondary = contract_display(229);
    let secondary_selector = DisplaySelector::Identity(secondary.identity.clone());
    let mut model = DisplayStateModel {
        records: vec![
            DisplayRecord {
                key: DisplayKey::Primary,
                live_display: Some(primary),
                assignment: Some(WallpaperAssignment::Mirror(secondary_selector)),
                window_active: true,
                runtime_open: false,
                primary_inheritance_consumed: false,
                bound_to_display: false,
            },
            DisplayRecord {
                key: DisplayKey::Identity(secondary.identity.clone()),
                live_display: Some(secondary),
                assignment: Some(WallpaperAssignment::Mirror(DisplaySelector::Primary)),
                window_active: true,
                runtime_open: false,
                primary_inheritance_consumed: true,
                bound_to_display: false,
            },
        ],
    };
    let before = model.clone();
    let result = model.set_window_active(&DisplaySelector::Primary, true);
    assert!(matches!(result, Err(EngineError::InvalidInput(_))));
    assert_eq!(model, before);
}

// M26
#[test]
fn active_connected_assigned_open_record_requests_rebuild() {
    let mut model = contract_model(vec![contract_config(
        DisplaySelector::Primary,
        true,
        Some(contract_assignment("active-rebuild")),
    )]);
    model.records[0].live_display = Some(contract_display(117));
    model.records[0].runtime_open = true;
    assert!(model.records[0].should_have_runtime());
    assert_eq!(
        model
            .set_window_active(&DisplaySelector::Primary, true)
            .expect("action computation succeeds"),
        vec![DisplayAction::Rebuild(DisplayKey::Primary)],
    );
}

// M27
#[test]
fn inactivity_alone_does_not_close_an_existing_assigned_runtime() {
    let mut model = contract_model(vec![contract_config(
        DisplaySelector::Primary,
        false,
        Some(contract_assignment("inactive-rebuild")),
    )]);
    model.records[0].live_display = Some(contract_display(117));
    model.records[0].runtime_open = true;
    assert!(model.records[0].should_have_runtime());
    assert_eq!(
        model
            .set_window_active(&DisplaySelector::Primary, false)
            .expect("action computation succeeds"),
        vec![DisplayAction::Rebuild(DisplayKey::Primary)],
    );
    assert!(!model.records[0].window_active);
    assert!(model.records[0].runtime_open);
}

// M28
#[test]
fn refresh_keeps_an_inactive_assigned_runtime_and_its_exact_live_descriptor() {
    let primary = contract_display(117);
    let assignment = contract_assignment("refresh-inactive-running");
    let mut model = contract_model(vec![contract_config(
        DisplaySelector::Primary,
        false,
        Some(assignment.clone()),
    )]);
    model.records[0].live_display = Some(primary.clone());
    model.records[0].runtime_open = true;
    let actions = model
        .refresh_connected(primary.clone(), vec![primary.clone()])
        .expect("running primary survives refresh");
    assert_eq!(actions, vec![DisplayAction::Rebuild(DisplayKey::Primary)]);
    assert_eq!(model.records[0].live_display, Some(primary));
    assert_eq!(model.records[0].assignment, Some(assignment));
    assert!(!model.records[0].window_active);
    assert!(model.records[0].runtime_open);
}

// M29
#[test]
fn destroying_an_inactive_open_window_closes_once_and_retains_other_state() {
    let mut model = contract_model(vec![contract_config(
        DisplaySelector::Primary,
        false,
        Some(contract_assignment("destroy-running")),
    )]);
    model.records[0].live_display = Some(contract_display(117));
    model.records[0].runtime_open = true;
    let mut expected = model.clone();
    expected.records[0].window_active = false;
    expected.records[0].runtime_open = false;
    assert_eq!(
        model
            .destroy_window(&DisplaySelector::Primary)
            .expect("destroy succeeds"),
        vec![DisplayAction::Close(DisplayKey::Primary)],
    );
    assert_eq!(model, expected);
    assert!(
        model
            .destroy_window(&DisplaySelector::Primary)
            .expect("repeat destroy succeeds")
            .is_empty()
    );
    assert_eq!(model, expected);
}

// M30: independent arrangements isolate both reasons for Close.
#[test]
fn missing_assignment_and_missing_live_descriptor_each_close_an_open_record() {
    let mut no_assignment = contract_model(vec![]);
    no_assignment.records[0].live_display = Some(contract_display(117));
    no_assignment.records[0].runtime_open = true;
    assert_eq!(no_assignment.records[0].assignment, None);
    assert!(!no_assignment.records[0].should_have_runtime());
    assert_eq!(
        no_assignment
            .set_window_active(&DisplaySelector::Primary, true)
            .expect("missing assignment has a valid close action"),
        vec![DisplayAction::Close(DisplayKey::Primary)],
    );

    let mut no_display = contract_model(vec![contract_config(
        DisplaySelector::Primary,
        true,
        Some(contract_assignment("not-connected")),
    )]);
    no_display.records[0].runtime_open = true;
    assert_eq!(no_display.records[0].live_display, None);
    assert!(no_display.records[0].assignment.is_some());
    assert!(!no_display.records[0].should_have_runtime());
    assert_eq!(
        no_display
            .set_window_active(&DisplaySelector::Primary, true)
            .expect("missing descriptor has a valid close action"),
        vec![DisplayAction::Close(DisplayKey::Primary)],
    );
}

// M31
#[test]
fn inactive_assigned_connected_slot_without_runtime_has_no_action() {
    let mut model = contract_model(vec![contract_config(
        DisplaySelector::Primary,
        false,
        Some(contract_assignment("dormant")),
    )]);
    model.records[0].live_display = Some(contract_display(117));
    assert!(!model.records[0].runtime_open);
    assert!(!model.records[0].should_have_runtime());
    assert!(
        model
            .set_window_active(&DisplaySelector::Primary, false)
            .expect("dormant action computation succeeds")
            .is_empty()
    );
}

// M32: unconfigured and configured never-connected transitional reports.
#[test]
fn zero_size_reports_do_not_open_until_a_real_surface_is_available() {
    let primary = contract_display(117);
    let usable = contract_display(229);
    let mut transitional = usable.clone();
    transitional.width = 0;
    transitional.height = 0;
    assert!(!transitional.has_presentable_size());
    assert!(usable.has_presentable_size());

    let mut unconfigured = contract_model(vec![]);
    let actions = unconfigured
        .refresh_connected_keeping(
            primary.clone(),
            vec![primary.clone()],
            &[transitional.clone()],
        )
        .expect("unconfigured transitional report is ignored");
    assert!(actions.is_empty());
    assert_eq!(unconfigured.records.len(), 1);
    assert_eq!(unconfigured.records[0].key, DisplayKey::Primary);
    assert!(!unconfigured.has_live_id(229));

    let assignment = contract_assignment("waiting-for-pixels");
    let key = DisplayKey::Identity(usable.identity.clone());
    let mut configured = contract_model(vec![contract_config(
        DisplaySelector::Identity(usable.identity.clone()),
        true,
        Some(assignment.clone()),
    )]);
    let actions = configured
        .refresh_connected_keeping(primary.clone(), vec![primary.clone()], &[transitional])
        .expect("configured never-connected transitional report stays descriptor-less");
    assert!(actions.is_empty());
    assert_eq!(configured.records.len(), 2);
    assert_eq!(configured.records[1].key, key);
    assert_eq!(configured.records[1].live_display, None);
    assert_eq!(configured.records[1].assignment, Some(assignment.clone()));
    assert!(configured.records[1].window_active);
    assert!(!configured.records[1].runtime_open);
    assert!(!configured.has_live_id(229));

    let actions = configured
        .refresh_connected(primary.clone(), vec![primary, usable.clone()])
        .expect("usable surface connects");
    assert_eq!(actions, vec![DisplayAction::Open(key.clone())]);
    assert_eq!(configured.records.len(), 2);
    assert_eq!(configured.records[1].key, key);
    assert_eq!(configured.records[1].live_display, Some(usable));
    assert_eq!(configured.records[1].assignment, Some(assignment));
    assert!(configured.records[1].window_active);
}
