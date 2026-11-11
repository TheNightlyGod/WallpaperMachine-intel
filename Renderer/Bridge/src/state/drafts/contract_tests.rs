use super::WallpaperOptionsDraft;
use crate::BridgeErrorKind;
use crate::config::{FramingCfg, MonitorRender, SerializedSelector, WallpaperConfig};
use crate::project::{ProjectModel, PropertyValue};
use serde_json::json;
use wallpaper_core::project::ScalingMode;

fn live(display_id: u32) -> SerializedSelector {
    SerializedSelector::LiveDisplayId { display_id }
}

fn identity(unit: u32) -> SerializedSelector {
    SerializedSelector::Identity {
        uuid: Some("contract-panel-river".into()),
        vendor_id: Some(271),
        model_id: Some(413),
        serial_number: Some(881),
        unit_number: Some(unit),
        name: Some("River panel".into()),
    }
}

fn default_row(selector: SerializedSelector) -> MonitorRender {
    MonitorRender {
        selector,
        ..MonitorRender::default()
    }
}

fn saved_config() -> WallpaperConfig {
    let mut config = WallpaperConfig::new_for("contract-orbit-491", "scene");
    config.schema_version = 17;
    config.audio.volume = 0.42;
    config.audio.response_enabled = true;
    config.audio.muted = false;
    config.media_integration_enabled = true;
    config.monitors = vec![
        MonitorRender {
            selector: SerializedSelector::Primary,
            scaling_mode: "fit".into(),
            scaling_factor: 1.75,
            frame_rate: Some(23),
            framing: FramingCfg {
                pan_x: 0.3,
                pan_y: 0.8,
            },
        },
        MonitorRender {
            selector: live(73),
            scaling_mode: "stretch".into(),
            scaling_factor: 0.625,
            frame_rate: None,
            framing: FramingCfg {
                pan_x: 0.9,
                pan_y: 0.2,
            },
        },
    ];
    config
        .property_overrides
        .insert("orbit_gain".into(), json!(8));
    config
        .property_overrides
        .insert("obsolete_label".into(), json!("retained"));
    config
}

fn model() -> ProjectModel {
    ProjectModel::parse(
        "contract-orbit-491",
        r#"{
            "type": "scene",
            "general": {
                "properties": {
                    "orbit_gain": {
                        "type": "slider", "text": "Orbit gain",
                        "value": 3, "min": 0, "max": 20
                    },
                    "show_trails": {
                        "type": "bool", "text": "Show trails", "value": false
                    }
                }
            }
        }"#,
    )
    .expect("independently authored in-memory scene model")
}

fn status(
    draft: &WallpaperOptionsDraft,
    active: &[SerializedSelector],
    dirty: bool,
    reconcile: bool,
) {
    assert_eq!(draft.is_dirty(active), dirty);
    assert_eq!(draft.requires_reconcile(active), reconcile);
}

#[test]
fn constructors_clone_cancel_and_apply_preserve_owned_values() {
    fn clone_and_debug<T: Clone + std::fmt::Debug>() {}
    clone_and_debug::<WallpaperOptionsDraft>();
    let saved = saved_config();
    let a = SerializedSelector::Primary;
    let b = live(73);
    let preference = vec![b.clone(), a.clone(), b.clone()];
    let plain = WallpaperOptionsDraft::from_committed(saved.clone());
    let _: &WallpaperConfig = plain.current();
    assert_eq!(plain.current(), &saved);
    assert_eq!(plain.committed(), &saved);
    assert!(plain.enabled_displays().is_empty());
    status(&plain, &[], false, false);

    let mut draft = WallpaperOptionsDraft::from_committed_with_enabled_displays(
        saved.clone(),
        preference.clone(),
    );
    assert_eq!(draft.current(), &saved);
    assert_eq!(draft.committed(), &saved);
    assert_eq!(draft.enabled_displays(), preference.as_slice());
    status(&draft, &preference, false, false);
    let mut independent = draft.clone();
    draft.set_volume(0.18).unwrap();
    draft.set_scaling_factor(a.clone(), 2.25).unwrap();
    draft.edit_property(&model(), "orbit_gain", PropertyValue::Number(11.0));
    draft.set_display_enabled(a.clone(), false, &preference);
    assert_eq!(draft.committed(), &saved);
    assert_eq!(independent.current(), &saved);
    assert_eq!(independent.enabled_displays(), preference.as_slice());
    independent.set_muted(true);
    assert!(!draft.current().audio.muted);
    draft.cancel();
    assert_eq!(draft.current(), &saved);
    assert_eq!(draft.enabled_displays(), preference.as_slice());
    status(&draft, &preference, false, false);

    draft.set_volume(0.18).unwrap();
    draft.set_scaling_factor(a.clone(), 2.25).unwrap();
    draft.edit_property(&model(), "orbit_gain", PropertyValue::Number(11.0));
    draft.set_display_enabled(a, false, &preference);
    let mut expected = saved.clone();
    expected.audio.volume = 0.18;
    expected.monitors[0].scaling_factor = 2.25;
    expected
        .property_overrides
        .insert("orbit_gain".into(), json!(11.0));
    let mut returned = draft.apply();
    assert_eq!(returned, expected);
    assert_eq!(draft.current(), &expected);
    assert_eq!(draft.committed(), &expected);
    assert_eq!(draft.enabled_displays(), &[b.clone(), b.clone()]);
    status(&draft, &[b.clone()], false, false);
    returned.audio.volume = 0.91;
    returned.monitors.clear();
    returned.property_overrides.clear();
    assert_eq!(draft.committed(), &expected);
    assert_eq!(draft.apply(), expected);
    draft.cancel();
    draft.cancel();
    assert_eq!(draft.current(), &expected);
    assert_eq!(draft.enabled_displays(), &[b.clone(), b]);
}

#[test]
fn empty_values_and_constructor_non_normalization_remain_observable() {
    let empty = WallpaperConfig::default();
    let mut draft = WallpaperOptionsDraft::from_committed(empty.clone());
    status(&draft, &[], false, false);
    assert_eq!(draft.apply(), empty);
    draft.cancel();
    assert_eq!(draft.current(), &empty);

    let mut unusual = WallpaperConfig::new_for("", "UNRECOGNIZED");
    unusual.schema_version = 91;
    unusual.audio.volume = -0.0;
    unusual.monitors = vec![MonitorRender {
        selector: identity(8),
        scaling_mode: "FiLl".into(),
        scaling_factor: -7.0,
        frame_rate: Some(0),
        framing: FramingCfg {
            pan_x: -2.0,
            pan_y: 4.0,
        },
    }];
    unusual
        .property_overrides
        .insert("raw_array".into(), json!([9, 4]));
    let selectors = vec![identity(8), identity(8), live(109)];
    let draft = WallpaperOptionsDraft::from_committed_with_enabled_displays(
        unusual.clone(),
        selectors.clone(),
    );
    assert_eq!(draft.current(), &unusual);
    assert_eq!(draft.committed(), &unusual);
    assert_eq!(draft.current().audio.volume.to_bits(), (-0.0_f32).to_bits());
    assert_eq!(draft.enabled_displays(), selectors.as_slice());
    status(&draft, &selectors, false, false);
}

#[test]
fn active_observations_do_not_replace_preference_and_intent_survives_clean_observation() {
    let a = SerializedSelector::Primary;
    let b = live(73);
    let c = live(109);
    let d = identity(8);
    let e = identity(9);
    let baseline = vec![a.clone(), b.clone()];
    let mut draft = WallpaperOptionsDraft::from_committed_with_enabled_displays(
        WallpaperConfig::default(),
        baseline.clone(),
    );
    let active = vec![c.clone(), b.clone(), a.clone()];
    assert_eq!(
        draft.effective_enabled_displays(&active),
        vec![a.clone(), b.clone(), c.clone()]
    );
    for selector in [&a, &b, &c, &d, &e] {
        assert!(!draft.display_dirty(selector, &active));
    }
    assert!(!draft.display_enabled(&c));
    assert!(draft.effective_display_enabled(&c, &active));
    assert!(draft.effective_display_enabled(&d, &[d.clone()]));
    assert!(!draft.effective_display_enabled(&e, &[d.clone()]));
    assert_eq!(draft.enabled_displays(), baseline.as_slice());
    status(&draft, &active, false, false);

    draft.set_display_enabled(b.clone(), false, &baseline);
    let expanded = vec![a.clone(), b.clone(), c.clone()];
    assert_eq!(draft.effective_enabled_displays(&expanded), vec![a.clone()]);
    assert!(draft.display_dirty(&b, &expanded));
    assert!(draft.display_dirty(&c, &expanded));
    assert!(!draft.display_dirty(&a, &expanded));
    status(&draft, &expanded, true, true);
    status(&draft, &[a.clone()], false, false);
    assert_eq!(draft.enabled_displays(), &[a.clone()]);
    draft.set_display_enabled(d.clone(), true, &[a.clone(), c.clone()]);
    assert_eq!(draft.enabled_displays(), &[a.clone(), d.clone()]);
    assert!(!draft.display_enabled(&c));
    assert!(!draft.display_enabled(&e));
    assert!(draft.current().monitors.is_empty());
    draft.cancel();
    assert_eq!(draft.enabled_displays(), baseline.as_slice());

    draft.set_display_enabled(c.clone(), true, &baseline);
    assert!(draft.display_dirty(&c, &baseline));
    draft.set_display_enabled(a, false, &[d.clone()]);
    assert_eq!(draft.enabled_displays(), &[b.clone(), c.clone()]);
    let _saved = draft.apply();
    assert_eq!(draft.enabled_displays(), &[b, c]);
    assert_eq!(
        draft.effective_enabled_displays(&[d.clone()]),
        vec![d.clone()]
    );
    status(&draft, &[d], false, false);
}

#[test]
fn caller_alias_groups_preserve_order_remove_all_matches_and_capture_empty_groups() {
    let a = SerializedSelector::Primary;
    let b = live(73);
    let d = identity(8);
    let active = vec![a.clone(), b.clone(), a.clone()];
    let mut draft = WallpaperOptionsDraft::from_committed(WallpaperConfig::default());
    draft.set_display_aliases_enabled(&[], true, &active);
    assert_eq!(draft.enabled_displays(), active.as_slice());
    status(&draft, &active, false, false);
    draft.set_display_aliases_enabled(&[b.clone(), b.clone(), d.clone(), a.clone()], true, &active);
    assert_eq!(
        draft.enabled_displays(),
        &[a.clone(), b.clone(), a.clone(), d.clone()]
    );
    draft.set_display_aliases_enabled(&[], false, &[live(900)]);
    assert_eq!(
        draft.enabled_displays(),
        &[a.clone(), b.clone(), a.clone(), d.clone()]
    );
    draft.set_display_aliases_enabled(&[a.clone(), a.clone()], false, &[]);
    assert_eq!(draft.enabled_displays(), &[b.clone(), d.clone()]);
    draft.set_display_aliases_enabled(&[identity(9)], false, &[]);
    assert_eq!(draft.enabled_displays(), &[b.clone(), d.clone()]);
    draft.set_display_aliases_enabled(&[b.clone()], true, &[]);
    assert_eq!(draft.enabled_displays(), &[b.clone(), d.clone()]);
    assert_eq!(draft.current(), &WallpaperConfig::default());
    assert_eq!(draft.committed(), &WallpaperConfig::default());

    let mut single = draft.clone();
    let mut group = draft.clone();
    for enabled in [false, true, true] {
        single.set_display_enabled(b.clone(), enabled, &active);
        group.set_display_aliases_enabled(&[b.clone()], enabled, &active);
        assert_eq!(single.enabled_displays(), group.enabled_displays());
        assert_eq!(single.current(), group.current());
        assert_eq!(
            single.effective_enabled_displays(&active),
            group.effective_enabled_displays(&active)
        );
        assert_eq!(single.is_dirty(&active), group.is_dirty(&active));
    }
    assert!(!draft.display_enabled(&identity(9)));
}

#[test]
fn duplicate_and_order_only_preferences_use_length_and_membership_not_sets_or_sorting() {
    let a = SerializedSelector::Primary;
    let b = live(73);
    let c = live(109);
    let draft = WallpaperOptionsDraft::from_committed_with_enabled_displays(
        WallpaperConfig::default(),
        vec![a.clone(), a.clone(), b.clone()],
    );
    let active = vec![b.clone(), a.clone(), a.clone(), c.clone(), c.clone()];
    assert_eq!(
        draft.effective_enabled_displays(&active),
        vec![a.clone(), a.clone(), b.clone(), c.clone()]
    );
    status(&draft, &active, false, false);

    let mut duplicates = WallpaperOptionsDraft::from_committed_with_enabled_displays(
        WallpaperConfig::default(),
        vec![a.clone(), a.clone()],
    );
    duplicates.set_display_enabled(a.clone(), false, &[a.clone(), a.clone()]);
    duplicates.set_display_aliases_enabled(&[a.clone(), b.clone()], true, &[c.clone()]);
    assert_eq!(duplicates.enabled_displays(), &[a.clone(), b.clone()]);
    duplicates.set_display_enabled(a.clone(), false, &[c.clone()]);
    assert_eq!(duplicates.enabled_displays(), &[b.clone()]);
    duplicates.cancel();
    assert_eq!(duplicates.enabled_displays(), &[a.clone(), a.clone()]);
    let mut captured = WallpaperOptionsDraft::from_committed(WallpaperConfig::default());
    captured.set_display_aliases_enabled(&[], true, &[a.clone(), a.clone()]);
    assert_eq!(captured.enabled_displays(), &[a.clone(), a.clone()]);
    status(&captured, &[a.clone()], false, false);

    let mut order_only = WallpaperOptionsDraft::from_committed_with_enabled_displays(
        WallpaperConfig::default(),
        vec![a.clone(), b.clone()],
    );
    order_only.set_display_enabled(a.clone(), false, &[a.clone(), b.clone()]);
    order_only.set_display_enabled(a.clone(), true, &[a.clone(), b.clone()]);
    assert_eq!(order_only.enabled_displays(), &[b.clone(), a.clone()]);
    assert_eq!(
        order_only.effective_enabled_displays(&[c.clone(), b.clone()]),
        vec![b.clone(), c.clone()]
    );
    status(&order_only, &[c.clone(), b.clone()], false, false);
    order_only.set_display_enabled(identity(8), true, &[c.clone(), b.clone()]);
    assert_eq!(order_only.enabled_displays(), &[c, b, identity(8)]);
}

#[test]
fn rebase_discards_only_assignment_intent_and_is_used_by_cancel_and_apply() {
    let a = SerializedSelector::Primary;
    let b = live(73);
    let c = identity(8);
    let saved = saved_config();
    let mut draft = WallpaperOptionsDraft::from_committed_with_enabled_displays(
        saved.clone(),
        vec![a.clone(), b.clone()],
    );
    draft.set_volume(0.29).unwrap();
    draft.set_scaling_factor(a.clone(), 3.5).unwrap();
    draft.edit_property(&model(), "orbit_gain", PropertyValue::Number(12.0));
    draft.set_display_enabled(b.clone(), false, &[a.clone(), b]);
    let mut pending = saved.clone();
    pending.audio.volume = 0.29;
    pending.monitors[0].scaling_factor = 3.5;
    pending
        .property_overrides
        .insert("orbit_gain".into(), json!(12.0));
    let rebased = vec![c.clone(), c.clone(), a.clone()];
    draft.rebase_enabled_displays(rebased.clone());
    assert_eq!(draft.current(), &pending);
    assert_eq!(draft.committed(), &saved);
    assert_eq!(draft.enabled_displays(), rebased.as_slice());
    assert_eq!(
        draft.effective_enabled_displays(&[live(109)]),
        vec![live(109)]
    );
    assert!(!draft.display_dirty(&c, &[]));
    let mut applied = draft.clone();
    assert_eq!(applied.apply(), pending);
    assert_eq!(applied.enabled_displays(), rebased.as_slice());
    status(&applied, &[], false, false);
    draft.cancel();
    assert_eq!(draft.current(), &saved);
    assert_eq!(draft.enabled_displays(), rebased.as_slice());
    assert_eq!(draft.effective_enabled_displays(&[a.clone()]), vec![a]);
    status(&draft, &[], false, false);
}

#[test]
fn dirty_and_reconcile_distinguish_audio_scale_default_rows_and_structural_edits() {
    let a = SerializedSelector::Primary;
    let b = live(73);
    let empty = WallpaperConfig::default();
    for field in 0..3 {
        let mut draft = WallpaperOptionsDraft::from_committed(empty.clone());
        match field {
            0 => draft.set_volume(0.34).unwrap(),
            1 => draft.set_muted(true),
            _ => draft.set_audio_response_enabled(false),
        }
        status(&draft, &[], true, false);
    }
    let mut config = empty.clone();
    config.monitors.push(default_row(a.clone()));
    let mut draft = WallpaperOptionsDraft::from_committed(config.clone());
    draft.set_scaling_factor(a.clone(), 4.25).unwrap();
    status(&draft, &[], true, false);
    draft.cancel();
    draft.set_display_render_enabled(b.clone(), true);
    assert_eq!(
        draft.current().monitors,
        vec![default_row(a.clone()), default_row(b.clone())]
    );
    status(&draft, &[], true, false);
    draft.cancel();
    draft.set_scaling_factor(b.clone(), 0.375).unwrap();
    status(&draft, &[], true, false);
    draft.cancel();
    draft.set_scaling_mode(b.clone(), ScalingMode::Fit);
    status(&draft, &[], true, true);
    draft.cancel();
    draft.set_target_fps(b.clone(), 19, 90);
    status(&draft, &[], true, true);
    draft.cancel();
    draft.edit_property(&model(), "orbit_gain", PropertyValue::Number(13.0));
    status(&draft, &[], true, true);
    draft.edit_property(&model(), "orbit_gain", PropertyValue::Number(3.0));
    status(&draft, &[], false, false);
    draft.set_display_render_enabled(a.clone(), false);
    status(&draft, &[], true, true);

    config.monitors.push(default_row(b.clone()));
    let mut reordered = WallpaperOptionsDraft::from_committed(config);
    reordered.set_display_render_enabled(a.clone(), false);
    reordered.set_display_render_enabled(a.clone(), true);
    assert_eq!(
        reordered.current().monitors,
        vec![default_row(b), default_row(a.clone())]
    );
    status(&reordered, &[], true, true);

    let mut fixed = WallpaperConfig::default();
    let mut row = default_row(a.clone());
    row.frame_rate = Some(60);
    fixed.monitors.push(row);
    let mut follow = WallpaperOptionsDraft::from_committed(fixed);
    follow.set_target_fps(a, 60, 60);
    assert_eq!(follow.current().monitors[0].frame_rate, None);
    status(&follow, &[], true, true);
}

#[test]
fn directly_supplied_nan_and_duplicate_factors_keep_genuine_comparison_behavior() {
    let mut audio_nan = WallpaperConfig::default();
    audio_nan.audio.volume = f32::NAN;
    let mut draft = WallpaperOptionsDraft::from_committed(audio_nan);
    assert!(draft.current().audio.volume.is_nan());
    assert!(draft.committed().audio.volume.is_nan());
    status(&draft, &[], true, true);
    draft.set_volume(0.4).unwrap();
    assert_eq!(draft.current().audio.volume, 0.4);
    assert!(draft.committed().audio.volume.is_nan());
    status(&draft, &[], true, true);
    let returned = draft.set_volume_immediate(0.4).unwrap();
    assert_eq!(returned.audio.volume, 0.4);
    status(&draft, &[], false, false);

    let a = SerializedSelector::Primary;
    let mut malformed = WallpaperConfig::default();
    let mut first = default_row(a.clone());
    first.scaling_factor = 0.75;
    let mut second = default_row(a.clone());
    second.scaling_factor = 1.25;
    malformed.monitors = vec![first.clone(), second];
    let unequal_duplicates = WallpaperOptionsDraft::from_committed(malformed.clone());
    status(&unequal_duplicates, &[], false, true);
    malformed.monitors[1].scaling_factor = 0.75;
    let equal_duplicates = WallpaperOptionsDraft::from_committed(malformed);
    status(&equal_duplicates, &[], false, false);

    first.scaling_factor = f64::NAN;
    let mut config = WallpaperConfig::default();
    config.monitors = vec![first];
    let scale_nan = WallpaperOptionsDraft::from_committed(config);
    assert!(scale_nan.current().monitors[0].scaling_factor.is_nan());
    status(&scale_nan, &[], true, true);
    let mut config = WallpaperConfig::default();
    let mut row = default_row(a);
    row.framing.pan_y = f64::NAN;
    config.monitors.push(row);
    let framing_nan = WallpaperOptionsDraft::from_committed(config);
    assert!(framing_nan.current().monitors[0].framing.pan_y.is_nan());
    status(&framing_nan, &[], true, true);
}

#[test]
fn each_immediate_audio_field_is_isolated_from_all_other_pending_work() {
    let a = SerializedSelector::Primary;
    let b = live(73);
    let active = vec![a.clone(), b.clone()];
    for field in 0..3 {
        let saved = saved_config();
        let mut draft = WallpaperOptionsDraft::from_committed_with_enabled_displays(
            saved.clone(),
            active.clone(),
        );
        draft.set_volume(0.19).unwrap();
        draft.set_muted(true);
        draft.set_audio_response_enabled(false);
        draft.set_scaling_factor(a.clone(), 2.875).unwrap();
        draft.set_scaling_mode(a.clone(), ScalingMode::None);
        draft.edit_property(&model(), "orbit_gain", PropertyValue::Number(14.0));
        draft.set_display_enabled(b.clone(), false, &active);
        let mut expected_saved = saved.clone();
        let mut expected_pending = saved;
        expected_pending.audio.volume = 0.19;
        expected_pending.audio.muted = true;
        expected_pending.audio.response_enabled = false;
        expected_pending.monitors[0].scaling_factor = 2.875;
        expected_pending.monitors[0].scaling_mode = "none".into();
        expected_pending
            .property_overrides
            .insert("orbit_gain".into(), json!(14.0));
        let returned = match field {
            0 => {
                expected_saved.audio.volume = 0.77;
                expected_pending.audio.volume = 0.77;
                draft.set_volume_immediate(0.77).unwrap()
            }
            1 => {
                expected_saved.audio.muted = false;
                expected_pending.audio.muted = false;
                draft.set_muted_immediate(false)
            }
            _ => {
                expected_saved.audio.response_enabled = true;
                expected_pending.audio.response_enabled = true;
                draft.set_audio_response_enabled_immediate(true)
            }
        };
        assert_eq!(returned, expected_saved);
        assert_eq!(draft.committed(), &expected_saved);
        assert_eq!(draft.current(), &expected_pending);
        assert_eq!(draft.enabled_displays(), &[a.clone()]);
        let mut canceled = draft.clone();
        canceled.cancel();
        assert_eq!(canceled.current(), &expected_saved);
        assert_eq!(canceled.enabled_displays(), active.as_slice());
        assert_eq!(draft.apply(), expected_pending);
        assert_eq!(draft.enabled_displays(), &[a.clone()]);
    }
}

#[test]
fn audio_endpoints_signed_zero_bool_directions_and_equal_repeats_are_values() {
    for volume in [0.0_f32, 1.0, -0.0, 0.37] {
        let saved = WallpaperConfig::default();
        let mut draft = WallpaperOptionsDraft::from_committed(saved.clone());
        draft.set_volume(volume).unwrap();
        assert_eq!(draft.current().audio.volume.to_bits(), volume.to_bits());
        assert_eq!(draft.committed(), &saved);
        let returned = draft.set_volume_immediate(volume).unwrap();
        assert_eq!(returned.audio.volume.to_bits(), volume.to_bits());
        assert_eq!(draft.committed().audio.volume.to_bits(), volume.to_bits());
        let repeated = draft.set_volume_immediate(volume).unwrap();
        assert_eq!(repeated, returned);
        status(&draft, &[], false, false);
    }
    let mut draft = WallpaperOptionsDraft::from_committed(WallpaperConfig::default());
    for muted in [true, false, false, true] {
        draft.set_muted(muted);
        assert_eq!(draft.current().audio.muted, muted);
        let returned = draft.set_muted_immediate(muted);
        assert_eq!(returned.audio.muted, muted);
        status(&draft, &[], false, false);
    }
    for enabled in [false, true, true, false] {
        draft.set_audio_response_enabled(enabled);
        assert_eq!(draft.current().audio.response_enabled, enabled);
        let returned = draft.set_audio_response_enabled_immediate(enabled);
        assert_eq!(returned.audio.response_enabled, enabled);
        status(&draft, &[], false, false);
    }
}

#[test]
fn both_invalid_volume_forms_leave_every_existing_value_and_intent_unchanged() {
    let a = SerializedSelector::Primary;
    let b = live(73);
    let active = vec![a.clone(), b.clone()];
    for volume in [-0.01_f32, 1.01, f32::NAN, f32::INFINITY, f32::NEG_INFINITY] {
        for immediate in [false, true] {
            let saved = saved_config();
            let mut draft = WallpaperOptionsDraft::from_committed_with_enabled_displays(
                saved.clone(),
                active.clone(),
            );
            draft.set_muted(true);
            draft.set_scaling_factor(a.clone(), 2.5).unwrap();
            draft.set_display_enabled(b.clone(), false, &active);
            let mut pending = saved.clone();
            pending.audio.muted = true;
            pending.monitors[0].scaling_factor = 2.5;
            let error = if immediate {
                draft.set_volume_immediate(volume).unwrap_err()
            } else {
                draft.set_volume(volume).unwrap_err()
            };
            assert_eq!(error.kind(), BridgeErrorKind::InvalidInput);
            assert_eq!(draft.committed(), &saved);
            assert_eq!(draft.current(), &pending);
            assert_eq!(draft.enabled_displays(), &[a.clone()]);
            assert_eq!(draft.effective_enabled_displays(&active), vec![a.clone()]);
            assert!(draft.display_dirty(&b, &active));
            status(&draft, &active, true, true);
        }
    }
}

#[test]
fn render_rows_are_separate_from_assignment_and_duplicate_edits_touch_only_first() {
    let a = SerializedSelector::Primary;
    let b = live(73);
    let c = live(109);
    let mut saved = WallpaperConfig::default();
    let mut first = default_row(a.clone());
    first.scaling_factor = 1.5;
    first.frame_rate = Some(29);
    first.framing = FramingCfg {
        pan_x: 0.2,
        pan_y: 0.7,
    };
    let mut second = default_row(a.clone());
    second.scaling_mode = "stretch".into();
    second.scaling_factor = 0.5;
    saved.monitors = vec![
        first.clone(),
        default_row(b.clone()),
        second.clone(),
        default_row(c.clone()),
    ];
    let mut draft = WallpaperOptionsDraft::from_committed(saved.clone());
    draft.set_display_render_enabled(identity(8), true);
    assert_eq!(draft.current().monitors.len(), 5);
    assert_eq!(draft.current().monitors[4], default_row(identity(8)));
    assert!(draft.enabled_displays().is_empty());
    assert!(!draft.display_enabled(&identity(8)));
    draft.set_display_render_enabled(identity(8), true);
    assert_eq!(draft.current().monitors.len(), 5);
    draft.set_display_render_enabled(a.clone(), true);
    assert_eq!(draft.current().monitors[0], first);
    draft.set_scaling_mode(a.clone(), ScalingMode::None);
    draft.set_scaling_factor(a.clone(), 0.875).unwrap();
    first.scaling_mode = "none".into();
    first.scaling_factor = 0.875;
    assert_eq!(draft.current().monitors[0], first);
    assert_eq!(draft.current().monitors[2], second);
    assert_eq!(draft.committed(), &saved);
    draft.set_display_render_enabled(a, false);
    assert_eq!(
        draft.current().monitors,
        vec![default_row(b), default_row(c), default_row(identity(8))]
    );
    assert!(draft.enabled_displays().is_empty());
    draft.set_display_render_enabled(live(900), false);
    assert_eq!(draft.current().monitors.len(), 3);
}

#[test]
fn mode_spelling_is_exact_and_default_immediate_requests_still_insert_rows() {
    let a = identity(8);
    for (mode, spelling) in [
        (ScalingMode::None, "none"),
        (ScalingMode::Stretch, "stretch"),
        (ScalingMode::Fit, "fit"),
        (ScalingMode::Fill, "fill"),
    ] {
        let mut draft = WallpaperOptionsDraft::from_committed(WallpaperConfig::default());
        draft.set_scaling_mode(a.clone(), mode);
        let mut expected_row = default_row(a.clone());
        expected_row.scaling_mode = spelling.into();
        assert_eq!(draft.current().monitors, vec![expected_row.clone()]);
        assert!(draft.committed().monitors.is_empty());
        let returned = draft.set_scaling_mode_immediate(a.clone(), mode);
        assert_eq!(returned.monitors, vec![expected_row.clone()]);
        assert_eq!(draft.current().monitors, vec![expected_row]);
        status(&draft, &[], false, false);
    }
    let mut missing_both = WallpaperOptionsDraft::from_committed(WallpaperConfig::default());
    let returned = missing_both.set_scaling_mode_immediate(a.clone(), ScalingMode::Fill);
    assert_eq!(returned.monitors, vec![default_row(a.clone())]);
    assert_eq!(missing_both.current().monitors, vec![default_row(a)]);
    missing_both.cancel();
    assert_eq!(missing_both.current(), &returned);
}

#[test]
fn immediate_mode_edits_independent_rows_without_committing_pending_scale_rate_or_properties() {
    let a = SerializedSelector::Primary;
    let saved = saved_config();
    let mut draft = WallpaperOptionsDraft::from_committed(saved.clone());
    draft.set_scaling_factor(a.clone(), 3.25).unwrap();
    draft.set_target_fps(a.clone(), 17, 90);
    draft.edit_property(&model(), "orbit_gain", PropertyValue::Number(15.0));
    let mut expected_saved = saved.clone();
    expected_saved.monitors[0].scaling_mode = "none".into();
    let mut expected_pending = expected_saved.clone();
    expected_pending.monitors[0].scaling_factor = 3.25;
    expected_pending.monitors[0].frame_rate = Some(17);
    expected_pending
        .property_overrides
        .insert("orbit_gain".into(), json!(15.0));
    assert_eq!(
        draft.set_scaling_mode_immediate(a.clone(), ScalingMode::None),
        expected_saved
    );
    assert_eq!(draft.current(), &expected_pending);
    assert_eq!(draft.committed(), &expected_saved);
    draft.cancel();
    assert_eq!(draft.current(), &expected_saved);

    let mut absent_pending = WallpaperOptionsDraft::from_committed(saved.clone());
    absent_pending.set_display_render_enabled(a.clone(), false);
    let returned = absent_pending.set_scaling_mode_immediate(a.clone(), ScalingMode::Stretch);
    let mut saved_stretch = saved.clone();
    saved_stretch.monitors[0].scaling_mode = "stretch".into();
    assert_eq!(returned, saved_stretch);
    let mut inserted = default_row(a.clone());
    inserted.scaling_mode = "stretch".into();
    assert_eq!(
        absent_pending.current().monitors,
        vec![saved.monitors[1].clone(), inserted]
    );
    let mut absent_saved = WallpaperOptionsDraft::from_committed(WallpaperConfig::default());
    absent_saved.set_scaling_factor(a.clone(), 5.25).unwrap();
    let returned = absent_saved.set_scaling_mode_immediate(a.clone(), ScalingMode::Fit);
    let mut expected = default_row(a);
    expected.scaling_mode = "fit".into();
    assert_eq!(returned.monitors, vec![expected.clone()]);
    expected.scaling_factor = 5.25;
    assert_eq!(absent_saved.current().monitors, vec![expected]);

    let mut duplicates = WallpaperConfig::default();
    let mut duplicate = default_row(live(109));
    duplicate.scaling_mode = "none".into();
    duplicates.monitors = vec![default_row(live(109)), duplicate.clone()];
    let mut draft = WallpaperOptionsDraft::from_committed(duplicates);
    let returned = draft.set_scaling_mode_immediate(live(109), ScalingMode::Fit);
    assert_eq!(returned.monitors[0].scaling_mode, "fit");
    assert_eq!(returned.monitors[1], duplicate);
    assert_eq!(draft.current().monitors[1], duplicate);
}

#[test]
fn positive_factors_include_subnormals_and_maximum_and_invalid_inputs_never_insert() {
    for factor in [0.375, f64::from_bits(1), f64::MAX] {
        let mut draft = WallpaperOptionsDraft::from_committed(WallpaperConfig::default());
        draft.set_scaling_factor(identity(8), factor).unwrap();
        let mut expected = default_row(identity(8));
        expected.scaling_factor = factor;
        assert_eq!(draft.current().monitors, vec![expected]);
        assert!(draft.committed().monitors.is_empty());
        assert!(draft.enabled_displays().is_empty());
        status(&draft, &[], true, false);
    }
    let a = SerializedSelector::Primary;
    let b = live(73);
    let active = vec![a.clone(), b.clone()];
    for factor in [
        0.0,
        -0.0,
        -0.375,
        f64::NAN,
        f64::INFINITY,
        f64::NEG_INFINITY,
    ] {
        for selector in [a.clone(), identity(9)] {
            let saved = saved_config();
            let mut draft = WallpaperOptionsDraft::from_committed_with_enabled_displays(
                saved.clone(),
                active.clone(),
            );
            draft.set_muted(true);
            draft.set_display_enabled(b.clone(), false, &active);
            let mut pending = saved.clone();
            pending.audio.muted = true;
            let error = draft.set_scaling_factor(selector, factor).unwrap_err();
            assert_eq!(error.kind(), BridgeErrorKind::InvalidInput);
            assert_eq!(draft.current(), &pending);
            assert_eq!(draft.committed(), &saved);
            assert_eq!(draft.enabled_displays(), &[a.clone()]);
            assert_eq!(draft.effective_enabled_displays(&active), vec![a.clone()]);
        }
    }
}

#[test]
fn stored_rate_table_covers_follow_clamp_zero_and_full_u32_domains() {
    let cases = [
        (0, 90, Some(1)),
        (24, 90, Some(24)),
        (60, 90, None),
        (61, 90, Some(61)),
        (200, 90, Some(90)),
        (45, 45, None),
        (200, 45, None),
        (0, 0, None),
        (1, 0, None),
        (u32::MAX, 0, None),
        (0, 1, None),
        (u32::MAX, 1, None),
        (0, 37, Some(1)),
        (36, 37, Some(36)),
        (37, 37, None),
        (u32::MAX, 37, None),
        (0, 60, Some(1)),
        (60, 60, None),
        (u32::MAX, 60, None),
        (59, 120, Some(59)),
        (60, 120, None),
        (u32::MAX, 120, Some(120)),
        (1, u32::MAX, Some(1)),
        (60, u32::MAX, None),
        (u32::MAX, u32::MAX, Some(u32::MAX)),
    ];
    for (fps, refresh, expected_rate) in cases {
        let selector = identity(8);
        let mut expected = default_row(selector.clone());
        expected.frame_rate = expected_rate;
        let mut deferred = WallpaperOptionsDraft::from_committed(WallpaperConfig::default());
        deferred.set_target_fps(selector.clone(), fps, refresh);
        assert_eq!(deferred.current().monitors, vec![expected.clone()]);
        assert!(deferred.committed().monitors.is_empty());
        deferred.cancel();
        assert!(deferred.current().monitors.is_empty());
        let mut immediate = WallpaperOptionsDraft::from_committed(WallpaperConfig::default());
        let returned = immediate.set_target_fps_immediate(selector, fps, refresh);
        assert_eq!(returned.monitors, vec![expected.clone()]);
        assert_eq!(immediate.current().monitors, vec![expected]);
        immediate.cancel();
        assert_eq!(immediate.current(), &returned);
        status(&immediate, &[], false, false);
    }
}

#[test]
fn immediate_rate_preserves_both_views_fields_duplicate_rows_and_assignment_intent() {
    let a = SerializedSelector::Primary;
    let b = live(73);
    let active = vec![a.clone(), b.clone()];
    let mut saved = saved_config();
    let mut duplicate = default_row(a.clone());
    duplicate.frame_rate = Some(43);
    saved.monitors.push(duplicate.clone());
    let mut draft =
        WallpaperOptionsDraft::from_committed_with_enabled_displays(saved.clone(), active.clone());
    draft.set_scaling_factor(a.clone(), 4.5).unwrap();
    draft.set_scaling_mode(a.clone(), ScalingMode::None);
    draft.set_volume(0.26).unwrap();
    draft.edit_property(&model(), "orbit_gain", PropertyValue::Number(16.0));
    draft.set_display_enabled(b, false, &active);
    draft.set_target_fps(a.clone(), 22, 90);
    assert_eq!(draft.current().monitors[0].frame_rate, Some(22));
    assert_eq!(draft.current().monitors[2], duplicate);
    assert_eq!(draft.committed(), &saved);
    let mut expected_saved = saved;
    expected_saved.monitors[0].frame_rate = Some(61);
    let mut expected_pending = expected_saved.clone();
    expected_pending.monitors[0].scaling_factor = 4.5;
    expected_pending.monitors[0].scaling_mode = "none".into();
    expected_pending.audio.volume = 0.26;
    expected_pending
        .property_overrides
        .insert("orbit_gain".into(), json!(16.0));
    let returned = draft.set_target_fps_immediate(a.clone(), 61, 90);
    assert_eq!(returned, expected_saved);
    assert_eq!(draft.current(), &expected_pending);
    assert_eq!(draft.current().monitors[2], duplicate);
    assert_eq!(draft.enabled_displays(), &[a.clone()]);
    let mut canceled = draft.clone();
    canceled.cancel();
    assert_eq!(canceled.current(), &expected_saved);
    assert_eq!(canceled.enabled_displays(), active.as_slice());
    assert_eq!(draft.apply(), expected_pending);
    assert_eq!(draft.enabled_displays(), &[a.clone()]);

    let mut absent_pending = WallpaperOptionsDraft::from_committed(expected_saved.clone());
    absent_pending.set_display_render_enabled(a.clone(), false);
    let returned = absent_pending.set_target_fps_immediate(a.clone(), 60, 120);
    expected_saved.monitors[0].frame_rate = None;
    assert_eq!(returned, expected_saved);
    assert_eq!(
        absent_pending.current().monitors.last(),
        Some(&default_row(a))
    );
}

#[test]
fn genuine_property_edits_omit_defaults_accept_unknown_ids_and_keep_saved_until_apply() {
    let model = model();
    let saved = WallpaperConfig::default();
    let mut draft = WallpaperOptionsDraft::from_committed(saved.clone());
    draft.edit_property(&model, "orbit_gain", PropertyValue::Number(31.0));
    assert_eq!(
        draft.current().property_overrides.get("orbit_gain"),
        Some(&json!(31.0))
    );
    assert_eq!(draft.committed(), &saved);
    status(&draft, &[], true, true);
    draft.edit_property(&model, "orbit_gain", PropertyValue::Number(3.0));
    assert!(draft.current().property_overrides.is_empty());
    status(&draft, &[], false, false);
    draft.edit_property(&model, "not_authored_here", PropertyValue::Bool(true));
    draft.edit_property(&model, "show_trails", PropertyValue::Bool(true));
    let mut expected = saved;
    expected
        .property_overrides
        .insert("not_authored_here".into(), json!(true));
    expected
        .property_overrides
        .insert("show_trails".into(), json!(true));
    assert_eq!(draft.current(), &expected);
    assert_eq!(draft.apply(), expected);
    draft.edit_property(&model, "show_trails", PropertyValue::Bool(false));
    assert!(
        !draft
            .current()
            .property_overrides
            .contains_key("show_trails")
    );
    assert_eq!(draft.committed(), &expected);
    draft.cancel();
    assert_eq!(draft.current(), &expected);
    draft.edit_property(&model, "show_trails", PropertyValue::Bool(false));
    expected.property_overrides.remove("show_trails");
    assert_eq!(draft.apply(), expected);
    status(&draft, &[], false, false);
}

#[test]
fn property_edit_preserves_complete_model_conversion_not_only_target_insertion() {
    let mut saved = WallpaperConfig::default();
    saved
        .property_overrides
        .insert("unregistered_sequence".into(), json!([2, 7]));
    saved
        .property_overrides
        .insert("stale_flag".into(), json!(true));
    let mut draft = WallpaperOptionsDraft::from_committed(saved.clone());
    draft.edit_property(&model(), "orbit_gain", PropertyValue::Number(9.0));
    let mut expected = WallpaperConfig::default();
    expected
        .property_overrides
        .insert("unregistered_sequence".into(), json!("[2,7]"));
    expected
        .property_overrides
        .insert("stale_flag".into(), json!(true));
    expected
        .property_overrides
        .insert("orbit_gain".into(), json!(9.0));
    assert_eq!(draft.current(), &expected);
    assert_eq!(draft.committed(), &saved);
    assert_eq!(
        draft
            .committed()
            .property_overrides
            .get("unregistered_sequence"),
        Some(&json!([2, 7]))
    );
    assert_eq!(draft.apply(), expected);
    assert_eq!(draft.committed(), &expected);
}

#[test]
fn single_restore_removes_exact_pending_key_without_model_or_keep_policy() {
    let a = SerializedSelector::Primary;
    let b = live(73);
    let active = vec![a.clone(), b.clone()];
    let mut saved = saved_config();
    saved
        .property_overrides
        .insert("hidden/path".into(), json!("literal/raw/path"));
    saved
        .property_overrides
        .insert("prefix".into(), json!(true));
    saved
        .property_overrides
        .insert("prefix.child".into(), json!(17));
    let mut draft =
        WallpaperOptionsDraft::from_committed_with_enabled_displays(saved.clone(), active.clone());
    draft.set_muted(true);
    draft.set_display_enabled(b, false, &active);
    draft.restore_property_default("orbit_gain");
    draft.restore_property_default("obsolete_label");
    draft.restore_property_default("hidden/path");
    draft.restore_property_default("prefix");
    draft.restore_property_default("never_existed");
    let mut expected = saved.clone();
    expected.audio.muted = true;
    expected.property_overrides.remove("orbit_gain");
    expected.property_overrides.remove("obsolete_label");
    expected.property_overrides.remove("hidden/path");
    expected.property_overrides.remove("prefix");
    assert_eq!(draft.current(), &expected);
    assert_eq!(
        draft.current().property_overrides.get("prefix.child"),
        Some(&json!(17))
    );
    assert_eq!(draft.committed(), &saved);
    assert_eq!(draft.enabled_displays(), &[a]);
    let mut canceled = draft.clone();
    canceled.cancel();
    assert_eq!(canceled.current(), &saved);
    assert_eq!(canceled.enabled_displays(), active.as_slice());
    assert_eq!(draft.apply(), expected);
}

#[test]
fn retained_position_uses_saved_omitted_axis_and_changes_only_first_rows_framing() {
    let a = SerializedSelector::Primary;
    let b = live(73);
    let active = vec![a.clone(), b.clone()];
    let mut saved = saved_config();
    let mut duplicate = default_row(a.clone());
    duplicate.framing = FramingCfg {
        pan_x: 0.14,
        pan_y: 0.68,
    };
    duplicate.scaling_factor = 1.75;
    saved.monitors.push(duplicate.clone());
    let mut draft =
        WallpaperOptionsDraft::from_committed_with_enabled_displays(saved.clone(), active.clone());
    draft.set_display_render_enabled(a.clone(), false);
    draft.set_display_render_enabled(a.clone(), true);
    draft.set_scaling_factor(a.clone(), 4.25).unwrap();
    draft.set_scaling_mode(a.clone(), ScalingMode::None);
    draft.set_target_fps(a.clone(), 17, 90);
    draft.set_volume(0.22).unwrap();
    draft.edit_property(&model(), "orbit_gain", PropertyValue::Number(11.0));
    draft.set_display_enabled(b, false, &active);
    assert_eq!(draft.current().monitors[1].framing, FramingCfg::default());
    let moved = FramingCfg {
        pan_x: 0.61,
        pan_y: 0.8,
    };
    let result = draft
        .set_position_immediate(a.clone(), Some(0.61), None)
        .unwrap();
    assert!(result.changed);
    assert_eq!(
        result.previous,
        FramingCfg {
            pan_x: 0.3,
            pan_y: 0.8
        }
    );
    assert_eq!(result.framing, moved);
    let mut expected_saved = saved.clone();
    expected_saved.monitors[0].framing = moved;
    let mut expected_pending = saved;
    expected_pending.monitors = vec![
        expected_pending.monitors[1].clone(),
        MonitorRender {
            selector: a.clone(),
            scaling_mode: "none".into(),
            scaling_factor: 4.25,
            frame_rate: Some(17),
            framing: moved,
        },
    ];
    expected_pending.audio.volume = 0.22;
    expected_pending
        .property_overrides
        .insert("orbit_gain".into(), json!(11.0));
    assert_eq!(result.config, expected_saved);
    assert_eq!(draft.committed(), &expected_saved);
    assert_eq!(draft.current(), &expected_pending);
    assert_eq!(draft.committed().monitors[2], duplicate);
    assert_eq!(draft.enabled_displays(), &[a.clone()]);
    let mut returned = result.clone().config;
    returned.monitors.clear();
    returned.audio.volume = 0.99;
    assert_eq!(draft.committed(), &expected_saved);
    let mut canceled = draft.clone();
    canceled.cancel();
    assert_eq!(canceled.current(), &expected_saved);
    assert_eq!(canceled.enabled_displays(), active.as_slice());
    assert_eq!(draft.apply(), expected_pending);
    assert_eq!(draft.enabled_displays(), &[a]);
}

#[test]
fn retained_position_equal_and_omitted_requests_preserve_pending_and_missing_rows() {
    let a = SerializedSelector::Primary;
    let b = live(73);
    let missing = identity(9);
    let active = vec![a.clone(), b.clone()];
    let saved = saved_config();
    let mut draft =
        WallpaperOptionsDraft::from_committed_with_enabled_displays(saved.clone(), active.clone());
    draft.set_display_render_enabled(a.clone(), false);
    draft.set_display_render_enabled(a.clone(), true);
    draft.set_muted(true);
    draft.set_display_enabled(b, false, &active);
    let mut expected_pending = saved.clone();
    expected_pending.monitors = vec![saved.monitors[1].clone(), default_row(a.clone())];
    expected_pending.audio.muted = true;
    for (selector, x, y, framing) in [
        (
            a.clone(),
            None,
            None,
            FramingCfg {
                pan_x: 0.3,
                pan_y: 0.8,
            },
        ),
        (
            a.clone(),
            Some(0.3),
            Some(0.8),
            FramingCfg {
                pan_x: 0.3,
                pan_y: 0.8,
            },
        ),
        (missing.clone(), None, None, FramingCfg::default()),
        (missing.clone(), Some(0.5), Some(0.5), FramingCfg::default()),
        (missing.clone(), Some(0.5), None, FramingCfg::default()),
    ] {
        let result = draft.set_position_immediate(selector, x, y).unwrap();
        assert!(!result.changed);
        assert_eq!(result.previous, framing);
        assert_eq!(result.framing, framing);
        assert_eq!(result.config, saved);
        assert_eq!(draft.committed(), &saved);
        assert_eq!(draft.current(), &expected_pending);
        assert_eq!(draft.enabled_displays(), &[a.clone()]);
        assert!(
            !draft
                .current()
                .monitors
                .iter()
                .any(|row| row.selector == missing)
        );
    }
}

#[test]
fn retained_position_invalid_supplied_axes_never_mutate_either_view_or_intent() {
    let a = SerializedSelector::Primary;
    let b = live(73);
    let active = vec![a.clone(), b.clone()];
    for invalid in [-0.01, 1.01, f64::NAN, f64::INFINITY, f64::NEG_INFINITY] {
        for selector in [a.clone(), identity(9)] {
            for (x, y) in [
                (Some(invalid), None),
                (None, Some(invalid)),
                (Some(invalid), Some(0.7)),
                (Some(0.2), Some(invalid)),
            ] {
                let saved = saved_config();
                let mut draft = WallpaperOptionsDraft::from_committed_with_enabled_displays(
                    saved.clone(),
                    active.clone(),
                );
                draft.set_volume(0.32).unwrap();
                draft.set_scaling_factor(a.clone(), 3.75).unwrap();
                draft.edit_property(&model(), "orbit_gain", PropertyValue::Number(12.0));
                draft.set_display_enabled(b.clone(), false, &active);
                let mut expected_pending = saved.clone();
                expected_pending.audio.volume = 0.32;
                expected_pending.monitors[0].scaling_factor = 3.75;
                expected_pending
                    .property_overrides
                    .insert("orbit_gain".into(), json!(12.0));
                let error = draft
                    .set_position_immediate(selector.clone(), x, y)
                    .unwrap_err();
                assert_eq!(error.kind(), BridgeErrorKind::InvalidInput);
                assert_eq!(draft.committed(), &saved);
                assert_eq!(draft.current(), &expected_pending);
                assert_eq!(draft.enabled_displays(), &[a.clone()]);
                assert_eq!(draft.effective_enabled_displays(&active), vec![a.clone()]);
                assert!(draft.display_dirty(&b, &active));
            }
        }
    }
}

#[test]
fn retained_position_endpoints_insert_independent_defaults_and_keep_omitted_saved_values() {
    let selector = identity(8);
    let mut draft = WallpaperOptionsDraft::from_committed(WallpaperConfig::default());
    draft.set_scaling_factor(selector.clone(), 3.125).unwrap();
    let result = draft
        .set_position_immediate(selector.clone(), Some(0.0), Some(1.0))
        .unwrap();
    let endpoints = FramingCfg {
        pan_x: 0.0,
        pan_y: 1.0,
    };
    assert!(result.changed);
    assert_eq!(result.previous, FramingCfg::default());
    assert_eq!(result.framing, endpoints);
    let mut expected_saved = WallpaperConfig::default();
    let mut row = default_row(selector.clone());
    row.framing = endpoints;
    expected_saved.monitors.push(row.clone());
    assert_eq!(result.config, expected_saved);
    row.scaling_factor = 3.125;
    assert_eq!(draft.current().monitors, vec![row]);
    draft.cancel();
    assert_eq!(draft.current(), &expected_saved);
    let reverse = draft
        .set_position_immediate(selector.clone(), Some(1.0), Some(0.0))
        .unwrap();
    assert!(reverse.changed);
    assert_eq!(reverse.previous, endpoints);
    assert_eq!(
        reverse.framing,
        FramingCfg {
            pan_x: 1.0,
            pan_y: 0.0
        }
    );
    let repeated = draft
        .set_position_immediate(selector, Some(1.0), None)
        .unwrap();
    assert!(!repeated.changed);
    assert_eq!(repeated.config, reverse.config);

    let mut unusual = WallpaperConfig::default();
    let mut row = default_row(live(109));
    row.framing = FramingCfg {
        pan_x: -2.0,
        pan_y: 0.4,
    };
    unusual.monitors.push(row);
    let mut draft = WallpaperOptionsDraft::from_committed(unusual.clone());
    let unchanged = draft.set_position_immediate(live(109), None, None).unwrap();
    assert!(!unchanged.changed);
    assert_eq!(unchanged.config, unusual);
    let moved = draft
        .set_position_immediate(live(109), None, Some(0.72))
        .unwrap();
    assert!(moved.changed);
    assert_eq!(
        moved.framing,
        FramingCfg {
            pan_x: -2.0,
            pan_y: 0.72
        }
    );
}

#[test]
fn retained_position_omitted_nan_axis_preserves_nan_and_takes_the_changed_branch() {
    for nan_x in [true, false] {
        let selector = live(109);
        let mut saved = WallpaperConfig::default();
        let mut row = default_row(selector.clone());
        row.framing = if nan_x {
            FramingCfg {
                pan_x: f64::NAN,
                pan_y: 0.76,
            }
        } else {
            FramingCfg {
                pan_x: 0.34,
                pan_y: f64::NAN,
            }
        };
        saved.monitors.push(row);
        let mut draft = WallpaperOptionsDraft::from_committed(saved.clone());
        draft.set_muted(true);
        draft.set_scaling_factor(selector.clone(), 2.625).unwrap();
        let result = draft
            .set_position_immediate(selector.clone(), None, None)
            .unwrap();
        assert!(result.changed);
        for framing in [
            result.previous,
            result.framing,
            result.config.monitors[0].framing,
            draft.committed().monitors[0].framing,
            draft.current().monitors[0].framing,
        ] {
            if nan_x {
                assert!(framing.pan_x.is_nan());
                assert_eq!(framing.pan_y, 0.76);
            } else {
                assert_eq!(framing.pan_x, 0.34);
                assert!(framing.pan_y.is_nan());
            }
        }
        let mut expected_saved = saved;
        let mut observed_saved = draft.committed().clone();
        let mut observed_returned = result.config;
        let mut observed_pending = draft.current().clone();
        if nan_x {
            expected_saved.monitors[0].framing.pan_x = 0.0;
            observed_saved.monitors[0].framing.pan_x = 0.0;
            observed_returned.monitors[0].framing.pan_x = 0.0;
            observed_pending.monitors[0].framing.pan_x = 0.0;
        } else {
            expected_saved.monitors[0].framing.pan_y = 0.0;
            observed_saved.monitors[0].framing.pan_y = 0.0;
            observed_returned.monitors[0].framing.pan_y = 0.0;
            observed_pending.monitors[0].framing.pan_y = 0.0;
        }
        assert_eq!(observed_saved, expected_saved);
        assert_eq!(observed_returned, expected_saved);
        let mut expected_pending = expected_saved;
        expected_pending.audio.muted = true;
        expected_pending.monitors[0].scaling_factor = 2.625;
        assert_eq!(observed_pending, expected_pending);
        let result = if nan_x {
            draft.set_position_immediate(selector.clone(), Some(0.58), None)
        } else {
            draft.set_position_immediate(selector.clone(), None, Some(0.58))
        }
        .unwrap();
        assert!(result.changed);
        assert_eq!(
            result.framing,
            if nan_x {
                FramingCfg {
                    pan_x: 0.58,
                    pan_y: 0.76,
                }
            } else {
                FramingCfg {
                    pan_x: 0.34,
                    pan_y: 0.58,
                }
            }
        );
        let result = draft.set_position_immediate(selector, None, None).unwrap();
        assert!(!result.changed);
    }
}

#[test]
fn retained_media_consent_both_directions_are_isolated_from_all_pending_work() {
    let a = SerializedSelector::Primary;
    let b = live(73);
    let active = vec![a.clone(), b.clone()];
    for enabled in [false, true] {
        let mut saved = saved_config();
        saved.media_integration_enabled = !enabled;
        let mut draft = WallpaperOptionsDraft::from_committed_with_enabled_displays(
            saved.clone(),
            active.clone(),
        );
        draft.set_volume(0.28).unwrap();
        draft.set_muted(true);
        draft.set_audio_response_enabled(false);
        draft.set_scaling_factor(a.clone(), 2.375).unwrap();
        draft.edit_property(&model(), "orbit_gain", PropertyValue::Number(15.0));
        draft.set_display_enabled(b.clone(), false, &active);
        let mut expected_saved = saved;
        expected_saved.media_integration_enabled = enabled;
        let mut expected_pending = expected_saved.clone();
        expected_pending.audio.volume = 0.28;
        expected_pending.audio.muted = true;
        expected_pending.audio.response_enabled = false;
        expected_pending.monitors[0].scaling_factor = 2.375;
        expected_pending
            .property_overrides
            .insert("orbit_gain".into(), json!(15.0));
        assert_eq!(
            draft.set_media_integration_enabled_immediate(enabled),
            expected_saved
        );
        assert_eq!(
            draft.set_media_integration_enabled_immediate(enabled),
            expected_saved
        );
        assert_eq!(draft.committed(), &expected_saved);
        assert_eq!(draft.current(), &expected_pending);
        assert_eq!(draft.enabled_displays(), &[a.clone()]);
        let mut canceled = draft.clone();
        canceled.cancel();
        assert_eq!(canceled.current(), &expected_saved);
        assert_eq!(canceled.enabled_displays(), active.as_slice());
        assert_eq!(draft.apply(), expected_pending);
    }
}

#[test]
fn retained_transient_overlay_is_ordered_independent_and_preserves_selector_intent() {
    let a = SerializedSelector::Primary;
    let b = live(73);
    let active = vec![a.clone(), b.clone()];
    let mut saved = saved_config();
    saved
        .property_overrides
        .insert("show_trails".into(), json!(true));
    let mut source =
        WallpaperOptionsDraft::from_committed_with_enabled_displays(saved.clone(), active.clone());
    source.set_volume(0.31).unwrap();
    source.set_scaling_factor(a.clone(), 4.0).unwrap();
    source.edit_property(&model(), "orbit_gain", PropertyValue::Number(9.0));
    source.set_display_enabled(b.clone(), false, &active);
    let mut expected_source = saved.clone();
    expected_source.audio.volume = 0.31;
    expected_source.monitors[0].scaling_factor = 4.0;
    expected_source
        .property_overrides
        .insert("orbit_gain".into(), json!(9.0));
    let edits = vec![
        ("orbit_gain".into(), PropertyValue::Number(6.0)),
        ("orbit_gain".into(), PropertyValue::Number(14.0)),
        ("show_trails".into(), PropertyValue::Bool(false)),
        ("transient_unknown".into(), PropertyValue::Bool(true)),
    ];
    let mut overlay = source.with_edits(&model(), &edits);
    let mut expected_overlay = expected_source.clone();
    expected_overlay
        .property_overrides
        .insert("orbit_gain".into(), json!(14.0));
    expected_overlay.property_overrides.remove("show_trails");
    expected_overlay
        .property_overrides
        .insert("transient_unknown".into(), json!(true));
    assert_eq!(overlay.current(), &expected_overlay);
    assert_eq!(overlay.committed(), &saved);
    assert_eq!(overlay.enabled_displays(), &[a.clone()]);
    assert_eq!(source.current(), &expected_source);
    assert_eq!(source.committed(), &saved);
    assert_eq!(source.enabled_displays(), &[a.clone()]);
    status(&source, &active, true, true);
    let empty = source.with_edits(&model(), &[]);
    assert_eq!(empty.current(), &expected_source);
    assert_eq!(empty.committed(), &saved);
    assert_eq!(empty.enabled_displays(), &[a.clone()]);
    for observation in [active.clone(), vec![a.clone()], vec![identity(9)]] {
        assert_eq!(
            empty.effective_enabled_displays(&observation),
            source.effective_enabled_displays(&observation)
        );
        assert_eq!(empty.is_dirty(&observation), source.is_dirty(&observation));
        assert_eq!(
            empty.requires_reconcile(&observation),
            source.requires_reconcile(&observation)
        );
    }
    let defaulted = source.with_edits(
        &model(),
        &[("orbit_gain".into(), PropertyValue::Number(3.0))],
    );
    let mut expected_defaulted = expected_source.clone();
    expected_defaulted.property_overrides.remove("orbit_gain");
    assert_eq!(defaulted.current(), &expected_defaulted);
    overlay.set_volume(0.88).unwrap();
    overlay.set_display_enabled(a, false, &[identity(9)]);
    assert!(overlay.enabled_displays().is_empty());
    assert_eq!(source.current(), &expected_source);
    assert_eq!(source.enabled_displays(), &[SerializedSelector::Primary]);
    expected_overlay.audio.volume = 0.88;
    assert_eq!(overlay.apply(), expected_overlay);
    assert_eq!(source.committed(), &saved);
    assert_eq!(source.current(), &expected_source);
}

#[test]
fn retained_changed_position_inserts_only_missing_rows_and_preserves_present_duplicates() {
    let a = SerializedSelector::Primary;
    let b = live(73);
    let moved = FramingCfg {
        pan_x: 0.47,
        pan_y: 0.93,
    };
    let mut empty = WallpaperOptionsDraft::from_committed(WallpaperConfig::default());
    empty.set_muted(true);
    let result = empty
        .set_position_immediate(a.clone(), Some(0.47), Some(0.93))
        .unwrap();
    let mut new_saved = WallpaperConfig::default();
    let mut new_row = default_row(a.clone());
    new_row.framing = moved;
    new_saved.monitors.push(new_row.clone());
    assert!(result.changed);
    assert_eq!(result.previous, FramingCfg::default());
    assert_eq!(result.config, new_saved);
    assert_eq!(empty.current().monitors, vec![new_row]);
    assert!(empty.current().audio.muted);
    assert!(!empty.committed().audio.muted);

    let mut saved = saved_config();
    let mut duplicate = default_row(a.clone());
    duplicate.scaling_mode = "none".into();
    duplicate.frame_rate = Some(37);
    duplicate.framing = FramingCfg {
        pan_x: 0.11,
        pan_y: 0.64,
    };
    saved.monitors.push(duplicate.clone());
    let mut present = WallpaperOptionsDraft::from_committed(saved.clone());
    present.set_scaling_factor(a.clone(), 3.875).unwrap();
    let result = present
        .set_position_immediate(a.clone(), Some(0.47), Some(0.93))
        .unwrap();
    let mut expected_saved = saved.clone();
    expected_saved.monitors[0].framing = moved;
    let mut expected_pending = expected_saved.clone();
    expected_pending.monitors[0].scaling_factor = 3.875;
    assert_eq!(result.config, expected_saved);
    assert_eq!(present.current(), &expected_pending);
    assert_eq!(present.current().monitors[2], duplicate);
    assert_eq!(present.committed().monitors[2], duplicate);

    let mut absent_pending = WallpaperOptionsDraft::from_committed(saved.clone());
    absent_pending.set_display_render_enabled(a.clone(), false);
    absent_pending.set_scaling_factor(b, 2.125).unwrap();
    let result = absent_pending
        .set_position_immediate(a.clone(), Some(0.47), Some(0.93))
        .unwrap();
    assert_eq!(result.config, expected_saved);
    let mut remaining = saved.monitors[1].clone();
    remaining.scaling_factor = 2.125;
    let mut inserted = default_row(a);
    inserted.framing = moved;
    assert_eq!(absent_pending.current().monitors, vec![remaining, inserted]);
    assert_eq!(absent_pending.committed().monitors[2], duplicate);
}

#[test]
fn retained_immediate_path_does_not_add_property_type_validation_or_normalize_literals() {
    let a = SerializedSelector::Primary;
    let b = live(73);
    let active = vec![a.clone(), b.clone()];
    let saved = saved_config();
    let mut draft =
        WallpaperOptionsDraft::from_committed_with_enabled_displays(saved.clone(), active.clone());
    draft.set_muted(true);
    draft.set_scaling_factor(a.clone(), 3.625).unwrap();
    draft.edit_property(&model(), "show_trails", PropertyValue::Bool(true));
    draft.set_display_enabled(b, false, &active);
    let literal = "../odd//segment/./ asset\\clip?.dat";
    let returned = draft.set_property_path_immediate(&model(), "orbit_gain", Some(literal.into()));
    let mut expected_saved = saved;
    expected_saved
        .property_overrides
        .insert("orbit_gain".into(), json!(literal));
    let mut expected_pending = expected_saved.clone();
    expected_pending.audio.muted = true;
    expected_pending.monitors[0].scaling_factor = 3.625;
    expected_pending
        .property_overrides
        .insert("show_trails".into(), json!(true));
    assert_eq!(returned, expected_saved);
    assert_eq!(draft.committed(), &expected_saved);
    assert_eq!(draft.current(), &expected_pending);
    assert_eq!(draft.enabled_displays(), &[a.clone()]);
    let returned = draft.set_property_path_immediate(&model(), "orbit_gain", None);
    expected_saved
        .property_overrides
        .insert("orbit_gain".into(), json!(""));
    expected_pending
        .property_overrides
        .insert("orbit_gain".into(), json!(""));
    assert_eq!(returned, expected_saved);
    assert_eq!(draft.current(), &expected_pending);
    let mut canceled = draft.clone();
    canceled.cancel();
    assert_eq!(canceled.current(), &expected_saved);
    assert_eq!(canceled.enabled_displays(), active.as_slice());
    assert_eq!(draft.apply(), expected_pending);
    assert_eq!(draft.enabled_displays(), &[a]);
}

#[test]
fn retained_restore_all_keeps_exact_stale_values_and_handles_empty_and_superset_sets() {
    use std::collections::BTreeSet;
    let a = SerializedSelector::Primary;
    let b = live(73);
    let active = vec![a.clone(), b.clone()];
    let mut saved = saved_config();
    saved
        .property_overrides
        .insert("kept/old".into(), json!([6, 1]));
    saved
        .property_overrides
        .insert("discarded/old".into(), json!({"untyped": 27}));
    let mut draft =
        WallpaperOptionsDraft::from_committed_with_enabled_displays(saved.clone(), active.clone());
    draft.set_volume(0.21).unwrap();
    draft.set_audio_response_enabled(false);
    draft.set_scaling_factor(a.clone(), 1.125).unwrap();
    draft.set_display_enabled(b, false, &active);
    let mut expected_pending = saved.clone();
    expected_pending.audio.volume = 0.21;
    expected_pending.audio.response_enabled = false;
    expected_pending.monitors[0].scaling_factor = 1.125;
    let mut superset = draft.clone();
    let mut all: BTreeSet<String> = saved.property_overrides.keys().cloned().collect();
    all.insert("not-present".into());
    superset.restore_all_property_defaults(&all);
    assert_eq!(superset.current(), &expected_pending);
    assert_eq!(superset.committed(), &saved);
    assert_eq!(superset.enabled_displays(), &[a.clone()]);
    let mut empty = draft.clone();
    empty.restore_all_property_defaults(&BTreeSet::new());
    let mut expected_empty = expected_pending.clone();
    expected_empty.property_overrides.clear();
    assert_eq!(empty.current(), &expected_empty);
    assert_eq!(empty.committed(), &saved);
    assert_eq!(empty.enabled_displays(), &[a.clone()]);
    empty.cancel();
    assert_eq!(empty.current(), &saved);
    assert_eq!(empty.enabled_displays(), active.as_slice());
    let keep: BTreeSet<String> = ["kept/old", "obsolete_label", "not-present"]
        .iter()
        .map(|id| (*id).into())
        .collect();
    draft.restore_all_property_defaults(&keep);
    expected_pending.property_overrides.clear();
    expected_pending
        .property_overrides
        .insert("kept/old".into(), json!([6, 1]));
    expected_pending
        .property_overrides
        .insert("obsolete_label".into(), json!("retained"));
    assert_eq!(draft.current(), &expected_pending);
    assert_eq!(draft.committed(), &saved);
    assert_eq!(draft.enabled_displays(), &[a.clone()]);
    assert_eq!(draft.apply(), expected_pending);
    assert_eq!(draft.committed(), &expected_pending);
    assert_eq!(draft.enabled_displays(), &[a]);
}

fn retained_path_model() -> ProjectModel {
    ProjectModel::parse(
        "contract-fern-682",
        r#"{
            "type": "scene",
            "general": {
                "properties": {
                    "sample_clip": { "type": "file", "text": "Sample clip", "value": "" },
                    "source_tree": { "type": "directory", "text": "Source tree", "value": "library/base//" },
                    "surface_layer": { "type": "scenetexture", "text": "Surface layer", "value": "textures/seed.png" },
                    "motion_gain": { "type": "slider", "text": "Motion gain", "value": 4, "min": 0, "max": 30 },
                    "visible_toggle": { "type": "bool", "text": "Visible toggle", "value": false },
                    "hidden_kept": { "type": "bool", "text": "Hidden kept", "value": false, "condition": "false" },
                    "hidden_removed": { "type": "bool", "text": "Hidden removed", "value": false, "condition": "false" }
                }
            }
        }"#,
    ).expect("independently authored file/directory/texture and hidden-property model")
}

fn retained_path_config() -> WallpaperConfig {
    let mut config = WallpaperConfig::new_for("contract-fern-682", "scene");
    config.audio.volume = 0.47;
    config.audio.response_enabled = false;
    config.media_integration_enabled = true;
    let mut row = default_row(SerializedSelector::Primary);
    row.scaling_factor = 1.625;
    row.frame_rate = Some(26);
    row.framing = FramingCfg {
        pan_x: 0.22,
        pan_y: 0.81,
    };
    config.monitors = vec![row, default_row(live(73))];
    config
        .property_overrides
        .insert("motion_gain".into(), json!(7.0));
    config
        .property_overrides
        .insert("visible_toggle".into(), json!(true));
    config
}

fn assert_canonical_document(actual: &str, expected: serde_json::Value) {
    let observed: serde_json::Value =
        serde_json::from_str(actual).expect("valid scene override JSON");
    assert_eq!(observed, expected);
    // Expected object literals below are independently authored in lexical key order.
    assert_eq!(actual, serde_json::to_string(&expected).unwrap());
}

#[test]
fn retained_real_path_kinds_edit_each_map_independently_and_omit_their_own_defaults() {
    let model = retained_path_model();
    let a = SerializedSelector::Primary;
    let b = live(73);
    let active = vec![a.clone(), b.clone()];
    for (id, authored_default) in [
        ("sample_clip", ""),
        // The authored folder is no default: a directory starts empty.
        ("source_tree", ""),
        ("surface_layer", "textures/seed.png"),
    ] {
        let mut saved = retained_path_config();
        saved
            .property_overrides
            .insert(id.into(), json!("saved//literal/../source"));
        let mut draft = WallpaperOptionsDraft::from_committed_with_enabled_displays(
            saved.clone(),
            active.clone(),
        );
        draft.set_volume(0.23).unwrap();
        draft.set_scaling_factor(a.clone(), 2.875).unwrap();
        draft.edit_property(
            &model,
            id,
            PropertyValue::String("pending-only/../path".into()),
        );
        draft.edit_property(&model, "motion_gain", PropertyValue::Number(13.0));
        draft.set_display_enabled(b.clone(), false, &active);
        let literal = "  ../fern//raw\\leaf/./ item?.bin  ";
        let returned = draft.set_property_path_immediate(&model, id, Some(literal.into()));
        let mut expected_saved = saved;
        expected_saved
            .property_overrides
            .insert(id.into(), json!(literal));
        let mut expected_pending = expected_saved.clone();
        expected_pending.audio.volume = 0.23;
        expected_pending.monitors[0].scaling_factor = 2.875;
        expected_pending
            .property_overrides
            .insert("motion_gain".into(), json!(13.0));
        assert_eq!(returned, expected_saved);
        assert_eq!(draft.committed(), &expected_saved);
        assert_eq!(draft.current(), &expected_pending);
        assert_eq!(draft.enabled_displays(), &[a.clone()]);

        // Saved has this override while pending does not: default omission is per view.
        draft.restore_property_default(id);
        expected_pending.property_overrides.remove(id);
        assert_eq!(draft.current(), &expected_pending);
        let returned = draft.set_property_path_immediate(&model, id, Some(authored_default.into()));
        expected_saved.property_overrides.remove(id);
        assert_eq!(returned, expected_saved);
        assert_eq!(draft.current(), &expected_pending);
        // Reverse the presence asymmetry and exercise the same authored default again.
        draft.edit_property(&model, id, PropertyValue::String("pending-again".into()));
        assert_eq!(draft.committed(), &expected_saved);
        let returned = draft.set_property_path_immediate(&model, id, Some(authored_default.into()));
        assert_eq!(returned, expected_saved);
        assert_eq!(draft.current(), &expected_pending);

        let returned = draft.set_property_path_immediate(&model, id, None);
        if authored_default.is_empty() {
            expected_saved.property_overrides.remove(id);
            expected_pending.property_overrides.remove(id);
        } else {
            expected_saved
                .property_overrides
                .insert(id.into(), json!(""));
            expected_pending
                .property_overrides
                .insert(id.into(), json!(""));
        }
        assert_eq!(returned, expected_saved);
        assert_eq!(draft.committed(), &expected_saved);
        assert_eq!(draft.current(), &expected_pending);
        assert_eq!(draft.enabled_displays(), &[a.clone()]);
        let mut canceled = draft.clone();
        canceled.cancel();
        assert_eq!(canceled.current(), &expected_saved);
        assert_eq!(canceled.enabled_displays(), active.as_slice());
        assert_eq!(draft.apply(), expected_pending);
        assert_eq!(draft.enabled_displays(), &[a.clone()]);
    }
}

#[test]
fn retained_nonlive_documents_defer_all_three_path_kinds_including_default_removal() {
    let model = retained_path_model();
    let saved = WallpaperConfig::new_for("contract-fern-682", "scene");
    let mut draft = WallpaperOptionsDraft::from_committed(saved.clone());
    let empty = draft.property_documents(&model);
    assert_eq!(empty.shown, "{}");
    assert_eq!(empty.saved, "{}");
    let clip = "clips/../literal\\sample.bin";
    let directory = "sources//fern/./";
    let texture = "textures/fern tile.png";
    for (id, value) in [
        ("surface_layer", texture),
        ("sample_clip", clip),
        ("source_tree", directory),
    ] {
        draft.edit_property(&model, id, PropertyValue::String(value.into()));
    }
    let mut expected_pending = saved.clone();
    expected_pending
        .property_overrides
        .insert("sample_clip".into(), json!(clip));
    expected_pending
        .property_overrides
        .insert("source_tree".into(), json!(directory));
    expected_pending
        .property_overrides
        .insert("surface_layer".into(), json!(texture));
    assert_eq!(draft.current(), &expected_pending);
    assert_eq!(draft.committed(), &saved);
    let only_nonlive = draft.property_documents(&model);
    assert_eq!(only_nonlive.shown, "{}");
    assert_eq!(only_nonlive.saved, "{}");
    draft.edit_property(&model, "visible_toggle", PropertyValue::Bool(true));
    draft.edit_property(&model, "motion_gain", PropertyValue::Number(12.5));
    expected_pending
        .property_overrides
        .insert("motion_gain".into(), json!(12.5));
    expected_pending
        .property_overrides
        .insert("visible_toggle".into(), json!(true));
    let staged = draft.property_documents(&model);
    assert_canonical_document(
        &staged.shown,
        json!({"motion_gain": 12.5, "visible_toggle": true}),
    );
    assert_eq!(staged.saved, "{}");
    assert_ne!(staged.shown, staged.saved);
    assert_eq!(draft.current(), &expected_pending);
    assert_eq!(draft.committed(), &saved);
    assert_eq!(draft.property_documents(&model), staged);
    assert_eq!(draft.apply(), expected_pending);
    let committed = draft.property_documents(&model);
    assert_canonical_document(
        &committed.saved,
        json!({
            "motion_gain": 12.5, "sample_clip": clip, "source_tree": directory,
            "surface_layer": texture, "visible_toggle": true,
        }),
    );
    assert_eq!(committed.shown, committed.saved);

    draft.restore_property_default("sample_clip");
    draft.edit_property(
        &model,
        "source_tree",
        PropertyValue::String(String::new()),
    );
    draft.edit_property(
        &model,
        "surface_layer",
        PropertyValue::String("textures/seed.png".into()),
    );
    draft.edit_property(&model, "motion_gain", PropertyValue::Number(4.0));
    draft.edit_property(&model, "visible_toggle", PropertyValue::Bool(false));
    assert!(draft.current().property_overrides.is_empty());
    let removing = draft.property_documents(&model);
    assert_canonical_document(
        &removing.shown,
        json!({
            "sample_clip": clip, "source_tree": directory, "surface_layer": texture,
        }),
    );
    assert_eq!(removing.saved, committed.saved);
    assert_ne!(removing.shown, removing.saved);
    let mut canceled = draft.clone();
    canceled.cancel();
    assert_eq!(canceled.current(), &expected_pending);
    assert_eq!(canceled.property_documents(&model), committed);
    assert_eq!(draft.apply(), saved);
    let removed = draft.property_documents(&model);
    assert_eq!(removed.shown, "{}");
    assert_eq!(removed.saved, "{}");
    status(&draft, &[], false, false);
}

#[test]
fn retained_restore_all_uses_explicit_path_hidden_and_stale_keep_ids_without_discovery() {
    use std::collections::BTreeSet;
    let model = retained_path_model();
    let a = SerializedSelector::Primary;
    let b = live(73);
    let active = vec![a.clone(), b.clone()];
    let mut saved = retained_path_config();
    saved
        .property_overrides
        .insert("sample_clip".into(), json!("saved//clip.bin"));
    saved
        .property_overrides
        .insert("source_tree".into(), json!("saved/../directory/"));
    saved
        .property_overrides
        .insert("surface_layer".into(), json!("saved/texture.png"));
    saved
        .property_overrides
        .insert("hidden_kept".into(), json!(true));
    saved
        .property_overrides
        .insert("hidden_removed".into(), json!(true));
    saved
        .property_overrides
        .insert("stale_kept".into(), json!("opaque//old/value"));
    saved
        .property_overrides
        .insert("stale_removed".into(), json!(false));
    let mut draft =
        WallpaperOptionsDraft::from_committed_with_enabled_displays(saved.clone(), active.clone());
    draft.edit_property(&model, "hidden_kept", PropertyValue::Bool(true));
    draft.edit_property(&model, "motion_gain", PropertyValue::Number(11.0));
    draft.set_muted(true);
    draft.set_scaling_factor(a.clone(), 2.75).unwrap();
    draft.set_display_enabled(b, false, &active);
    let keep: BTreeSet<String> = [
        "sample_clip",
        "source_tree",
        "hidden_kept",
        "stale_kept",
        "absent_kept",
    ]
    .iter()
    .map(|id| (*id).into())
    .collect();
    draft.restore_all_property_defaults(&keep);
    let mut expected_pending = saved.clone();
    expected_pending.audio.muted = true;
    expected_pending.monitors[0].scaling_factor = 2.75;
    expected_pending.property_overrides.clear();
    expected_pending
        .property_overrides
        .insert("sample_clip".into(), json!("saved//clip.bin"));
    expected_pending
        .property_overrides
        .insert("source_tree".into(), json!("saved/../directory/"));
    expected_pending
        .property_overrides
        .insert("hidden_kept".into(), json!(true));
    expected_pending
        .property_overrides
        .insert("stale_kept".into(), json!("opaque//old/value"));
    assert_eq!(draft.current(), &expected_pending);
    assert_eq!(draft.committed(), &saved);
    assert_eq!(draft.enabled_displays(), &[a.clone()]);
    let documents = draft.property_documents(&model);
    assert_canonical_document(
        &documents.saved,
        json!({
            "hidden_kept": true, "hidden_removed": true, "motion_gain": 7.0,
            "sample_clip": "saved//clip.bin", "source_tree": "saved/../directory/",
            "stale_kept": "opaque//old/value", "stale_removed": false,
            "surface_layer": "saved/texture.png", "visible_toggle": true,
        }),
    );
    assert_canonical_document(
        &documents.shown,
        json!({
            "hidden_kept": true, "sample_clip": "saved//clip.bin",
            "source_tree": "saved/../directory/", "stale_kept": "opaque//old/value",
            "surface_layer": "saved/texture.png",
        }),
    );
    let mut canceled = draft.clone();
    canceled.cancel();
    assert_eq!(canceled.current(), &saved);
    assert_eq!(canceled.enabled_displays(), active.as_slice());
    assert_eq!(draft.apply(), expected_pending);
    let applied = draft.property_documents(&model);
    assert_canonical_document(
        &applied.saved,
        json!({
            "hidden_kept": true, "sample_clip": "saved//clip.bin",
            "source_tree": "saved/../directory/", "stale_kept": "opaque//old/value",
        }),
    );
    assert_eq!(applied.shown, applied.saved);
    assert_eq!(draft.enabled_displays(), &[a]);
}

#[test]
fn retained_path_overlay_keeps_nonlive_saved_values_until_its_independent_apply() {
    let model = retained_path_model();
    let a = SerializedSelector::Primary;
    let b = live(73);
    let active = vec![a.clone(), b.clone()];
    let mut saved = WallpaperConfig::new_for("contract-fern-682", "scene");
    saved
        .property_overrides
        .insert("motion_gain".into(), json!(7.0));
    saved
        .property_overrides
        .insert("sample_clip".into(), json!("clips/saved.bin"));
    saved
        .property_overrides
        .insert("source_tree".into(), json!("sources/saved/"));
    saved
        .property_overrides
        .insert("surface_layer".into(), json!("textures/saved.png"));
    let mut source =
        WallpaperOptionsDraft::from_committed_with_enabled_displays(saved.clone(), active.clone());
    source.set_muted(true);
    source.edit_property(
        &model,
        "sample_clip",
        PropertyValue::String("clips/source-pending.bin".into()),
    );
    source.set_display_enabled(b, false, &active);
    let mut expected_source = saved.clone();
    expected_source.audio.muted = true;
    expected_source
        .property_overrides
        .insert("sample_clip".into(), json!("clips/source-pending.bin"));
    let mut overlay = source.with_edits(
        &model,
        &[
            (
                "sample_clip".into(),
                PropertyValue::String("clips/earlier.bin".into()),
            ),
            (
                "source_tree".into(),
                PropertyValue::String(String::new()),
            ),
            (
                "sample_clip".into(),
                PropertyValue::String("clips/later.bin".into()),
            ),
            (
                "surface_layer".into(),
                PropertyValue::String("textures/seed.png".into()),
            ),
            ("motion_gain".into(), PropertyValue::Number(9.5)),
        ],
    );
    let mut expected_overlay = expected_source.clone();
    expected_overlay.property_overrides.clear();
    expected_overlay
        .property_overrides
        .insert("motion_gain".into(), json!(9.5));
    expected_overlay
        .property_overrides
        .insert("sample_clip".into(), json!("clips/later.bin"));
    assert_eq!(overlay.current(), &expected_overlay);
    assert_eq!(overlay.committed(), &saved);
    assert_eq!(overlay.enabled_displays(), &[a.clone()]);
    assert_eq!(source.current(), &expected_source);
    assert_eq!(source.committed(), &saved);
    assert_eq!(source.enabled_displays(), &[a.clone()]);
    let source_documents = source.property_documents(&model);
    assert_canonical_document(
        &source_documents.saved,
        json!({
            "motion_gain": 7.0, "sample_clip": "clips/saved.bin",
            "source_tree": "sources/saved/", "surface_layer": "textures/saved.png",
        }),
    );
    assert_eq!(source_documents.shown, source_documents.saved);
    let overlay_documents = overlay.property_documents(&model);
    assert_eq!(overlay_documents.saved, source_documents.saved);
    assert_canonical_document(
        &overlay_documents.shown,
        json!({
            "motion_gain": 9.5, "sample_clip": "clips/saved.bin",
            "source_tree": "sources/saved/", "surface_layer": "textures/saved.png",
        }),
    );
    let mut canceled = overlay.clone();
    canceled.cancel();
    assert_eq!(canceled.current(), &saved);
    assert_eq!(canceled.enabled_displays(), active.as_slice());
    assert_eq!(overlay.apply(), expected_overlay);
    let committed = overlay.property_documents(&model);
    assert_canonical_document(
        &committed.saved,
        json!({
            "motion_gain": 9.5, "sample_clip": "clips/later.bin",
        }),
    );
    assert_eq!(committed.shown, committed.saved);
    assert_eq!(source.property_documents(&model), source_documents);
    assert_eq!(source.current(), &expected_source);
    assert_eq!(source.committed(), &saved);
    status(&source, &active, true, true);
}

#[test]
fn retained_documents_include_required_host_defaults_and_explicit_values_take_precedence() {
    let model = ProjectModel::parse(
        "contract-fern-host-953",
        r#"{
            "type": "scene",
            "general": { "properties": {
                "fern_NextAction": { "type": "usershortcut", "value": "" },
                "fern_manualPlay": { "type": "usershortcut", "value": "local:authored" },
                "fern_unbound": { "type": "usershortcut" }
            } }
        }"#,
    )
    .expect("independent required-host-default declarations");
    let saved = WallpaperConfig::new_for("contract-fern-host-953", "scene");
    let mut draft = WallpaperOptionsDraft::from_committed(saved.clone());
    let initial = draft.property_documents(&model);
    assert_canonical_document(&initial.saved, json!({"fern_NextAction": "media:next"}));
    assert_eq!(initial.shown, initial.saved);
    assert!(draft.current().property_overrides.is_empty());
    assert_eq!(draft.current(), &saved);
    draft.edit_property(
        &model,
        "fern_NextAction",
        PropertyValue::String("literal:override".into()),
    );
    let mut expected = saved.clone();
    expected
        .property_overrides
        .insert("fern_NextAction".into(), json!("literal:override"));
    assert_eq!(draft.current(), &expected);
    assert_eq!(draft.committed(), &saved);
    let pending = draft.property_documents(&model);
    assert_canonical_document(
        &pending.shown,
        json!({"fern_NextAction": "literal:override"}),
    );
    assert_eq!(pending.saved, initial.saved);
    assert_eq!(draft.apply(), expected);
    let applied = draft.property_documents(&model);
    assert_canonical_document(
        &applied.saved,
        json!({"fern_NextAction": "literal:override"}),
    );
    assert_eq!(applied.shown, applied.saved);
    draft.edit_property(
        &model,
        "fern_NextAction",
        PropertyValue::String("media:next".into()),
    );
    assert!(draft.current().property_overrides.is_empty());
    let defaulted = draft.property_documents(&model);
    assert_canonical_document(&defaulted.shown, json!({"fern_NextAction": "media:next"}));
    assert_eq!(defaulted.saved, applied.saved);
    assert_eq!(draft.apply(), saved);
    assert_eq!(draft.property_documents(&model), initial);
    status(&draft, &[], false, false);
}

#[test]
fn engine_option_edits_are_pending_until_apply_need_a_reconcile_and_revert_undoes_them() {
    use crate::config::{EngineOptionId, EngineOptionsCfg};
    let mut draft = WallpaperOptionsDraft::from_committed(WallpaperConfig::new_for("w", "scene"));
    assert!(!draft.requires_reconcile(&[]));

    draft.edit_engine_option(EngineOptionId::FlipHorizontal, &PropertyValue::Bool(true));
    draft.edit_engine_option(EngineOptionId::Brightness, &PropertyValue::Number(70.0));
    assert!(draft.current().engine_options.flip_horizontal);
    assert!(!draft.committed().engine_options.flip_horizontal, "an edit waits for Apply");
    assert!(draft.is_dirty(&[]));
    assert!(draft.requires_reconcile(&[]), "Apply has to reach the renderers");

    draft.restore_engine_option_default(EngineOptionId::Brightness);
    assert_eq!(draft.current().engine_options.brightness, 50.0);
    assert!(draft.current().engine_options.flip_horizontal);

    draft.edit_engine_option(EngineOptionId::PlaybackRate, &PropertyValue::Number(150.0));
    draft.restore_all_engine_option_defaults();
    assert_eq!(draft.current().engine_options, EngineOptionsCfg::default());
    assert!(!draft.requires_reconcile(&[]));

    draft.edit_engine_option(EngineOptionId::ImageFilter, &PropertyValue::String("amber".into()));
    let saved = draft.apply();
    assert_eq!(saved.engine_options.image_filter, "amber");
    assert!(!draft.requires_reconcile(&[]));

    draft.edit_engine_option(EngineOptionId::ImageFilter, &PropertyValue::String(String::new()));
    draft.cancel();
    assert_eq!(draft.current().engine_options.image_filter, "amber");
}

#[test]
fn engine_option_values_being_shown_leave_the_draft_alone() {
    use crate::config::EngineOptionId;
    let draft = WallpaperOptionsDraft::from_committed(WallpaperConfig::new_for("w", "scene"));
    let shown = draft.with_engine_edits(&[
        (EngineOptionId::ColorEnabled, PropertyValue::Bool(true)),
        (EngineOptionId::Saturation, PropertyValue::Number(20.0)),
        (EngineOptionId::Saturation, PropertyValue::Number(30.0)),
    ]);
    assert!(shown.current().engine_options.color_enabled);
    assert_eq!(shown.current().engine_options.saturation, 30.0);
    assert!(!draft.current().engine_options.color_enabled);
    assert!(!draft.is_dirty(&[]));
}

#[test]
fn restoring_every_engine_option_leaves_the_properties_alone() {
    use crate::config::EngineOptionId;
    let mut committed = WallpaperConfig::new_for("w", "scene");
    committed.property_overrides.insert("glow".into(), json!(true));
    let mut draft = WallpaperOptionsDraft::from_committed(committed);
    draft.edit_engine_option(EngineOptionId::HueShift, &PropertyValue::Number(10.0));
    draft.restore_all_engine_option_defaults();
    assert_eq!(draft.current().property_overrides.get("glow"), Some(&json!(true)));
}
