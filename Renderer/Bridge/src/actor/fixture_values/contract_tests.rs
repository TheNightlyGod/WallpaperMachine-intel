use super::*;
use crate::api::{
    BridgeDisplayMode, BridgeDisplaySettingsRow, BridgeError, BridgeScalingMode,
    BridgeWallpaperEntry, BridgeWallpaperKind,
};
use crate::config::{AppConfig, FramingCfg, MonitorRender, SerializedSelector, WallpaperConfig};
use crate::project::{ProjectModel, PropertyValue};
use crate::state::drafts::WallpaperOptionsDraft;
use std::collections::BTreeMap;

fn selector(id: u32) -> SerializedSelector {
    SerializedSelector::LiveDisplayId { display_id: id }
}

fn marked_entry(id: &str, title: &str) -> BridgeWallpaperEntry {
    BridgeWallpaperEntry {
        id: id.into(),
        title: title.into(),
        kind: BridgeWallpaperKind::Unknown,
        supported: false,
        active: true,
        selected: true,
        preview_path: Some(format!("/fresh-preview/{id}.png")),
    }
}

fn assert_new_entry(
    entry: &BridgeWallpaperEntry,
    id: &str,
    title: &str,
    kind: BridgeWallpaperKind,
    supported: bool,
) {
    assert_eq!(
        entry,
        &BridgeWallpaperEntry {
            id: id.into(),
            title: title.into(),
            kind,
            supported,
            active: false,
            selected: false,
            preview_path: None,
        }
    );
}

fn rich_config(id: &str) -> WallpaperConfig {
    let mut config = WallpaperConfig::new_for(id, "fixture-non-scene");
    config.schema_version = 37;
    config.audio.volume = 0.27_f32;
    config.audio.response_enabled = false;
    config.audio.muted = true;
    config.media_integration_enabled = true;
    config.monitors = vec![
        MonitorRender {
            selector: selector(413),
            scaling_mode: "stretch".into(),
            scaling_factor: 1.625_f64,
            frame_rate: Some(43_u32),
            framing: FramingCfg {
                pan_x: 0.19,
                pan_y: 0.82,
            },
        },
        MonitorRender {
            selector: selector(719),
            scaling_mode: "fit".into(),
            scaling_factor: 0.875_f64,
            frame_rate: Some(91_u32),
            framing: FramingCfg {
                pan_x: 0.73,
                pan_y: 0.26,
            },
        },
    ];
    config
        .property_overrides
        .insert("fresh_gain_c83".into(), serde_json::json!(0.61));
    config
        .property_overrides
        .insert("fresh_gate_d41".into(), serde_json::json!(true));
    config.property_overrides.insert(
        "fresh_nested_e52".into(),
        serde_json::json!({"array": [4, "amber", false], "nested": {"x": 17}}),
    );
    config
}

fn dirty_draft(config: WallpaperConfig) -> WallpaperOptionsDraft {
    let mut draft = WallpaperOptionsDraft::from_committed(config);
    draft.set_muted(false);
    draft.set_volume(0.84).expect("legal pending volume");
    draft.set_display_enabled(selector(997), true, &[]);
    assert!(draft.is_dirty(&[]));
    assert!(
        draft
            .effective_enabled_displays(&[])
            .contains(&selector(997))
    );
    draft
}

fn assert_clean_baseline(draft: &WallpaperOptionsDraft, expected: &WallpaperConfig) {
    assert_eq!(draft.current(), expected);
    assert_eq!(draft.committed(), expected);
    assert!(!draft.is_dirty(&[]));
    assert!(draft.effective_enabled_displays(&[]).is_empty());
}

fn assert_same_draft(actual: &WallpaperOptionsDraft, expected: &WallpaperOptionsDraft) {
    assert_eq!(actual.current(), expected.current());
    assert_eq!(actual.committed(), expected.committed());
    for active in [
        vec![],
        vec![selector(997)],
        vec![selector(413), selector(719)],
    ] {
        assert_eq!(actual.is_dirty(&active), expected.is_dirty(&active));
        assert_eq!(
            actual.effective_enabled_displays(&active),
            expected.effective_enabled_displays(&active)
        );
    }
}

fn assert_same_drafts(
    actual: &BTreeMap<String, WallpaperOptionsDraft>,
    expected: &BTreeMap<String, WallpaperOptionsDraft>,
) {
    assert_eq!(
        actual.keys().collect::<Vec<_>>(),
        expected.keys().collect::<Vec<_>>()
    );
    for (key, draft) in expected {
        assert_same_draft(&actual[key], draft);
    }
}

fn fresh_property_text() -> String {
    serde_json::json!({
        "type": "scene", "title": "Copper Lantern Spectrum",
        "preview": "lantern-preview.png", "file": "lantern-scene.json",
        "general": {"properties": {
            "lantern_gain_c61": {"type": "slider", "value": 0.24,
                                  "min": 0.0, "max": 1.0},
            "lantern_gate_f82": {"type": "bool", "value": false}
        }}
    })
    .to_string()
}

#[test]
fn entry_append_preserves_existing_duplicates_and_distinguishes_support() {
    let mut library = vec![
        marked_entry("repeat-321", "first"),
        marked_entry("repeat-321", "second"),
    ];
    let before = library.clone();
    let cases = [
        (BridgeWallpaperKind::ProjectScene, true),
        (BridgeWallpaperKind::Video, true),
        (BridgeWallpaperKind::Webpage, true),
        (BridgeWallpaperKind::Unknown, false),
    ];
    for (index, (kind, supported)) in cases.into_iter().enumerate() {
        let title = format!("  supplied title {index}  ");
        add_entry(&mut library, "repeat-321".into(), title.clone(), kind);
        assert_eq!(&library[..2], before.as_slice());
        assert_eq!(library.len(), index + 3);
        assert_new_entry(&library[index + 2], "repeat-321", &title, kind, supported);
    }
    for (index, (kind, supported)) in cases.into_iter().enumerate() {
        assert_new_entry(
            &library[index + 2],
            "repeat-321",
            &format!("  supplied title {index}  "),
            kind,
            supported,
        );
    }
}

#[test]
fn scene_configuration_replaces_dirty_target_with_fresh_empty_baseline() {
    let target = "scene-target-526";
    let other = "scene-neighbor-847";
    let mut library = vec![
        marked_entry(target, "old duplicate"),
        marked_entry(other, "neighbor"),
    ];
    let before_library = library.clone();
    let mut configs = BTreeMap::from([
        (target.into(), rich_config("old-embedded-127")),
        (other.into(), rich_config("neighbor-embedded-934")),
    ]);
    let mut drafts = BTreeMap::from([
        (target.into(), dirty_draft(configs[target].clone())),
        (other.into(), dirty_draft(configs[other].clone())),
    ]);
    let other_config = configs[other].clone();
    let other_draft = drafts[other].clone();
    add_scene_configuration(
        &mut library,
        &mut configs,
        &mut drafts,
        target.into(),
        "  Fresh scene title  ".into(),
    );
    assert_eq!(library.len(), before_library.len() + 1);
    assert_eq!(&library[..before_library.len()], before_library.as_slice());
    assert_new_entry(
        library.last().unwrap(),
        target,
        "  Fresh scene title  ",
        BridgeWallpaperKind::ProjectScene,
        true,
    );
    let expected = WallpaperConfig::new_for(target, "scene");
    assert_eq!(configs.len(), 2);
    assert_eq!(drafts.len(), 2);
    assert_eq!(configs[target], expected);
    assert_clean_baseline(&drafts[target], &expected);
    assert_eq!(configs[other], other_config);
    assert_same_draft(&drafts[other], &other_draft);
}

#[test]
fn parsed_project_type_and_title_matrix_uses_genuine_complete_models() {
    let cases = [
        (
            serde_json::json!({"type":"ScEnE", "title":"Parsed copper"}),
            "",
            "Parsed copper",
            BridgeWallpaperKind::ProjectScene,
        ),
        (
            serde_json::json!({"type":"VIDEO", "title":"Parsed reel"}),
            "override reel",
            "override reel",
            BridgeWallpaperKind::Video,
        ),
        (
            serde_json::json!({"type":"wEb", "title":"Parsed page"}),
            " \t ",
            " \t ",
            BridgeWallpaperKind::Webpage,
        ),
        (
            serde_json::json!({"type":"unrecognized-lantern-kind", "title":"Parsed unknown"}),
            "",
            "Parsed unknown",
            BridgeWallpaperKind::Unknown,
        ),
        (
            serde_json::json!({"title":"No type"}),
            "",
            "No type",
            BridgeWallpaperKind::Unknown,
        ),
        (
            serde_json::json!({"type":"scene"}),
            "",
            "",
            BridgeWallpaperKind::ProjectScene,
        ),
        (
            serde_json::json!({"type":"web", "title":42}),
            "",
            "",
            BridgeWallpaperKind::Webpage,
        ),
    ];
    for (index, (input, supplied_title, expected_title, kind)) in cases.into_iter().enumerate() {
        let id = format!("parsed-matrix-{}", index + 581);
        let text = input.to_string();
        let expected_model = ProjectModel::parse(&id, &text).expect("fresh object parses");
        let mut library = vec![marked_entry(&id, "old duplicate")];
        let old_entry = library[0].clone();
        let mut models = BTreeMap::new();
        let mut configs = BTreeMap::new();
        let mut drafts = BTreeMap::new();
        add_project(
            &mut library,
            &mut models,
            &mut configs,
            &mut drafts,
            id.clone(),
            supplied_title.into(),
            &text,
        )
        .expect("valid project fixture");
        assert_eq!(library.len(), 2);
        assert_eq!(library[0], old_entry);
        assert_new_entry(&library[1], &id, expected_title, kind, true);
        assert_eq!(models.len(), 1);
        assert_eq!(models[&id], expected_model);
        let expected_config = WallpaperConfig::new_for(id.clone(), "scene");
        assert_eq!(configs.len(), 1);
        assert_eq!(drafts.len(), 1);
        assert_eq!(configs[&id], expected_config);
        assert_clean_baseline(&drafts[&id], &expected_config);
    }
}

#[test]
fn property_project_overwrites_target_retains_full_model_and_unrelated_dirty_state() {
    let id = "property-target-763";
    let other = "property-other-284";
    let text = fresh_property_text();
    let expected_model = ProjectModel::parse(id, &text).expect("property-bearing object");
    let old_model = ProjectModel::parse(
        id,
        r#"{"type":"video","title":"Prior violet reel","file":"old-reel.mp4"}"#,
    )
    .unwrap();
    let other_model = ProjectModel::parse(other, &text).unwrap();
    let mut models = BTreeMap::from([(id.into(), old_model), (other.into(), other_model)]);
    let before_other_model = models[other].clone();
    let mut library = vec![
        marked_entry(id, "old first"),
        marked_entry(id, "old second"),
    ];
    let before_library = library.clone();
    let mut configs = BTreeMap::from([
        (id.into(), rich_config(id)),
        (other.into(), rich_config(other)),
    ]);
    let mut target_draft = dirty_draft(configs[id].clone());
    target_draft.edit_property(
        &expected_model,
        "lantern_gain_c61",
        PropertyValue::Number(0.79),
    );
    target_draft.edit_property(
        &expected_model,
        "lantern_gate_f82",
        PropertyValue::Bool(true),
    );
    assert_eq!(
        target_draft.current().property_overrides["lantern_gain_c61"].as_f64(),
        Some(0.79)
    );
    assert_eq!(
        target_draft.current().property_overrides["lantern_gate_f82"].as_bool(),
        Some(true)
    );
    let mut drafts = BTreeMap::from([
        (id.into(), target_draft),
        (other.into(), dirty_draft(configs[other].clone())),
    ]);
    let before_other_config = configs[other].clone();
    let before_other_draft = drafts[other].clone();
    add_project(
        &mut library,
        &mut models,
        &mut configs,
        &mut drafts,
        id.into(),
        String::new(),
        &text,
    )
    .unwrap();
    assert_eq!(library.len(), 3);
    assert_eq!(&library[..2], before_library.as_slice());
    assert_new_entry(
        &library[2],
        id,
        "Copper Lantern Spectrum",
        BridgeWallpaperKind::ProjectScene,
        true,
    );
    assert_eq!(models.len(), 2);
    assert_eq!(models[id], expected_model);
    assert_eq!(models[other], before_other_model);
    let expected_config = WallpaperConfig::new_for(id, "scene");
    assert_eq!(configs[id], expected_config);
    assert!(configs[id].property_overrides.is_empty());
    assert_clean_baseline(&drafts[id], &expected_config);
    assert_eq!(configs[other], before_other_config);
    assert_same_draft(&drafts[other], &before_other_draft);
}

#[test]
fn project_parse_errors_preserve_all_collections_and_parser_display_message() {
    let id = "invalid-target-619";
    let model = ProjectModel::parse(id, &fresh_property_text()).unwrap();
    let mut library = vec![marked_entry(id, "sentinel"), marked_entry(id, "duplicate")];
    let mut models = BTreeMap::from([(id.into(), model.clone()), ("other-528".into(), model)]);
    let mut configs = BTreeMap::from([
        (id.into(), rich_config(id)),
        ("other-528".into(), rich_config("other-528")),
    ]);
    let mut drafts = BTreeMap::from([
        (id.into(), dirty_draft(configs[id].clone())),
        (
            "other-528".into(),
            dirty_draft(configs["other-528"].clone()),
        ),
    ]);
    let before_library = library.clone();
    let before_models = models.clone();
    let before_configs = configs.clone();
    let before_drafts = drafts.clone();
    for input in ["{", "[]", "null", "17", "\"scalar\""] {
        let parser_error = ProjectModel::parse(id, input).unwrap_err();
        let error = add_project(
            &mut library,
            &mut models,
            &mut configs,
            &mut drafts,
            id.into(),
            "must not appear".into(),
            input,
        )
        .unwrap_err();
        assert_eq!(error.kind(), BridgeError::invalid_input("").kind());
        assert_eq!(error.message(), parser_error.to_string());
        assert_eq!(library, before_library);
        assert_eq!(models, before_models);
        assert_eq!(configs, before_configs);
        assert_same_drafts(&drafts, &before_drafts);
    }
}

fn sentinel_row(id: &str) -> BridgeDisplaySettingsRow {
    BridgeDisplaySettingsRow {
        display_id: id.into(),
        title: "sentinel row title".into(),
        enabled: false,
        mode: BridgeDisplayMode::Mirror,
        mirror_targets: vec!["obsolete-target".into()],
        selected_mirror_target: Some("kept-selected-target".into()),
        scaling_mode: BridgeScalingMode::Stretch,
        scaling_factor: 1.375_f64,
        target_fps: 29_u32,
        max_fps: 117_u32,
        muted: true,
        volume: 0.32_f32,
    }
}

fn assert_row_defaults(row: &BridgeDisplaySettingsRow, id: &str, title: &str, targets: &[&str]) {
    assert_eq!(
        row,
        &BridgeDisplaySettingsRow {
            display_id: id.into(),
            title: title.into(),
            enabled: true,
            mode: BridgeDisplayMode::Standalone,
            mirror_targets: targets.iter().map(|s| (*s).to_string()).collect(),
            selected_mirror_target: None,
            scaling_mode: BridgeScalingMode::Fill,
            scaling_factor: 1.0_f64,
            target_fps: 60_u32,
            max_fps: 60_u32,
            muted: false,
            volume: 1.0_f32,
        }
    );
}

#[test]
fn display_parser_preserves_raw_keys_and_uses_genuine_default_monitor() {
    for (raw, number) in [
        ("73", 73_u32),
        ("0", 0),
        ("4294967295", u32::MAX),
        ("008", 8),
        ("+8", 8),
    ] {
        assert_eq!(raw.parse::<u32>().unwrap(), number);
        let mut app = AppConfig::default();
        app.general.last_selected_wallpaper = Some("keep-selection-924".into());
        let mut expected_app = app.clone();
        expected_app.ensure_monitor(selector(number));
        let mut rows = BTreeMap::new();
        add_display(
            &mut app,
            &mut rows,
            raw.into(),
            "  raw display title  ".into(),
        )
        .unwrap();
        assert_eq!(app, expected_app);
        assert_eq!(rows.len(), 1);
        assert_row_defaults(&rows[raw], raw, "  raw display title  ", &[]);
        let monitor = app.monitors.last().unwrap();
        assert_eq!(monitor.selector, selector(number));
        assert!(monitor.enabled);
        assert_eq!(monitor.mode, "independent");
        assert_eq!(monitor.wallpaper, None);
        assert_eq!(monitor.mirror_target, None);
    }
}

#[test]
fn display_parse_failures_leave_complete_app_and_rows_unchanged() {
    let mut app = AppConfig::default();
    app.general.last_selected_wallpaper = Some("selected-673".into());
    let monitor = app.ensure_monitor(selector(31));
    monitor.enabled = false;
    monitor.mode = "mirror".into();
    monitor.wallpaper = Some("assigned-428".into());
    monitor.mirror_target = Some(selector(4));
    let mut rows = BTreeMap::from([
        ("31".into(), sentinel_row("31")),
        ("odd-key".into(), sentinel_row("different-id")),
    ]);
    let before_app = app.clone();
    let before_rows = rows.clone();
    for raw in [
        "",
        "-1",
        " 31",
        "31 ",
        "\t31",
        "31\n",
        "4x",
        "++4",
        "4294967296",
    ] {
        assert!(raw.parse::<u32>().is_err());
        let error =
            add_display(&mut app, &mut rows, raw.into(), "rejected title".into()).unwrap_err();
        assert_eq!(error.kind(), BridgeError::invalid_input("").kind());
        assert_eq!(error.message(), format!("invalid display id {raw}"));
        assert_eq!(app, before_app);
        assert_eq!(rows, before_rows);
    }
}

#[test]
fn display_aliases_preserve_duplicate_monitors_and_reinjection_resets_only_target_row() {
    let mut app = AppConfig::default();
    app.general.last_selected_wallpaper = Some("unrelated-735".into());
    let first = app.ensure_monitor(selector(8));
    first.enabled = false;
    first.mode = "mirror".into();
    first.wallpaper = Some("assigned-original-683".into());
    first.mirror_target = Some(selector(31));
    let mut duplicate = first.clone();
    duplicate.enabled = true;
    duplicate.wallpaper = Some("assigned-duplicate-294".into());
    app.monitors.push(duplicate);
    let before_app = app.clone();
    let mut rows = BTreeMap::new();
    add_display(&mut app, &mut rows, "008".into(), "leading zero".into()).unwrap();
    add_display(&mut app, &mut rows, "8".into(), "ordinary".into()).unwrap();
    add_display(&mut app, &mut rows, "+8".into(), "explicit plus".into()).unwrap();
    assert_eq!(app, before_app);
    assert_eq!(rows.len(), 3);
    assert_row_defaults(&rows["+8"], "+8", "explicit plus", &["008", "8"]);
    assert_row_defaults(&rows["008"], "008", "leading zero", &["+8", "8"]);
    assert_row_defaults(&rows["8"], "8", "ordinary", &["+8", "008"]);
    rows.insert("008".into(), sentinel_row("008"));
    rows.insert("8".into(), sentinel_row("8"));
    let mut expected_other = rows["8"].clone();
    expected_other.mirror_targets = vec!["+8".into(), "008".into()];
    add_display(&mut app, &mut rows, "008".into(), "reset title".into()).unwrap();
    assert_eq!(app, before_app);
    assert_row_defaults(&rows["008"], "008", "reset title", &["+8", "8"]);
    assert_eq!(rows["8"], expected_other);
    assert_row_defaults(&rows["+8"], "+8", "explicit plus", &["008", "8"]);
}

#[test]
fn display_recomputes_full_lexical_vectors_excluding_row_id_not_map_key() {
    let mut app = AppConfig::default();
    let mut rows = BTreeMap::from([
        ("4".into(), sentinel_row("4")),
        ("31".into(), sentinel_row("31")),
        ("mismatch-key".into(), sentinel_row("31")),
        ("unmatched-key".into(), sentinel_row("not-a-map-key")),
    ]);
    let mut expected_four = rows["4"].clone();
    expected_four.mirror_targets = vec![
        "008".into(),
        "31".into(),
        "mismatch-key".into(),
        "unmatched-key".into(),
    ];
    let mut expected_thirty_one = rows["31"].clone();
    expected_thirty_one.mirror_targets = vec![
        "008".into(),
        "4".into(),
        "mismatch-key".into(),
        "unmatched-key".into(),
    ];
    let mut expected_mismatch = rows["mismatch-key"].clone();
    expected_mismatch.mirror_targets = vec![
        "008".into(),
        "4".into(),
        "mismatch-key".into(),
        "unmatched-key".into(),
    ];
    let mut expected_unmatched = rows["unmatched-key"].clone();
    expected_unmatched.mirror_targets = vec![
        "008".into(),
        "31".into(),
        "4".into(),
        "mismatch-key".into(),
        "unmatched-key".into(),
    ];
    add_display(
        &mut app,
        &mut rows,
        "008".into(),
        "lexical fresh row".into(),
    )
    .unwrap();
    assert_eq!(rows.len(), 5);
    assert_row_defaults(
        &rows["008"],
        "008",
        "lexical fresh row",
        &["31", "4", "mismatch-key", "unmatched-key"],
    );
    assert_eq!(rows["4"], expected_four);
    assert_eq!(rows["31"], expected_thirty_one);
    assert_eq!(rows["mismatch-key"], expected_mismatch);
    assert_eq!(rows["unmatched-key"], expected_unmatched);
}

#[test]
fn replacement_selection_matrix_preserves_exact_inventory_and_other_app_fields() {
    let mut unsupported_retained = marked_entry("retained-418", "unsupported member");
    unsupported_retained.active = false;
    unsupported_retained.selected = false;
    unsupported_retained.preview_path = None;
    let inventory = vec![
        marked_entry("other-692", "first"),
        unsupported_retained,
        marked_entry("retained-418", "duplicate member"),
    ];
    let cases = [
        (
            Some("retained-418"),
            Some("retained-418"),
            false,
            Some("retained-418"),
            Some("retained-418"),
        ),
        (
            Some("retained-418"),
            Some("mismatched-572"),
            false,
            Some("retained-418"),
            Some("mismatched-572"),
        ),
        (
            Some("retained-418"),
            None,
            false,
            Some("retained-418"),
            None,
        ),
        (
            Some("missing-824"),
            Some("mismatched-572"),
            false,
            None,
            None,
        ),
        (Some("missing-824"), None, false, None, None),
        (None, Some("stale-927"), false, None, Some("stale-927")),
        (None, None, false, None, None),
        (Some("retained-418"), Some("retained-418"), true, None, None),
        (None, Some("stale-927"), true, None, Some("stale-927")),
        (None, None, true, None, None),
    ];
    for (selected_before, persisted_before, empty, selected_after, persisted_after) in cases {
        let mut library = vec![marked_entry("old-inventory-316", "old")];
        let mut selected = selected_before.map(str::to_owned);
        let mut app = AppConfig::default();
        app.general.last_selected_wallpaper = persisted_before.map(str::to_owned);
        let monitor = app.ensure_monitor(selector(683));
        monitor.enabled = false;
        monitor.mode = "mirror".into();
        monitor.wallpaper = Some("unrelated-monitor-wallpaper-792".into());
        monitor.mirror_target = Some(selector(516));
        let mut expected_app = app.clone();
        expected_app.general.last_selected_wallpaper = persisted_after.map(str::to_owned);
        let replacement = if empty { vec![] } else { inventory.clone() };
        let expected_library = replacement.clone();
        replace_library(&mut library, &mut selected, &mut app, replacement);
        assert_eq!(library, expected_library);
        assert_eq!(selected, selected_after.map(str::to_owned));
        assert_eq!(app, expected_app);
    }
    // Retention must work when the unsupported, all-false entry is the sole match.
    let replacement = vec![inventory[1].clone()];
    let mut library = vec![];
    let mut selected = Some("retained-418".into());
    let mut app = AppConfig::default();
    app.general.last_selected_wallpaper = Some("unmatched-persisted-471".into());
    let expected_app = app.clone();
    replace_library(&mut library, &mut selected, &mut app, replacement.clone());
    assert_eq!(library, replacement);
    assert_eq!(selected.as_deref(), Some("retained-418"));
    assert_eq!(app, expected_app);
}

#[test]
fn configuration_replacement_preserves_rich_value_key_mismatch_and_unrelated_draft() {
    let key = "map-key-938";
    let other = "unrelated-key-265";
    let mut configs = BTreeMap::from([
        (key.into(), rich_config("old-embedded-482")),
        (other.into(), rich_config("unrelated-embedded-173")),
    ]);
    let mut drafts = BTreeMap::from([
        (key.into(), dirty_draft(configs[key].clone())),
        (other.into(), dirty_draft(configs[other].clone())),
    ]);
    let other_config = configs[other].clone();
    let other_draft = drafts[other].clone();
    let mut replacement = rich_config("embedded-not-map-key-651");
    replacement.r#type = "retained-custom-web-type-729".into();
    let expected = replacement.clone();
    replace_configuration(&mut configs, &mut drafts, key.into(), replacement);
    assert_eq!(configs.len(), 2);
    assert_eq!(drafts.len(), 2);
    assert_eq!(configs[key], expected);
    assert_ne!(configs[key].workshop_id, key);
    assert_eq!(configs[key].r#type, "retained-custom-web-type-729");
    assert_clean_baseline(&drafts[key], &expected);
    assert_eq!(configs[other], other_config);
    assert_same_draft(&drafts[other], &other_draft);
    // An equal saved value still replaces a newly dirty editable baseline.
    drafts.get_mut(key).unwrap().set_volume(0.93).unwrap();
    drafts
        .get_mut(key)
        .unwrap()
        .set_display_enabled(selector(997), true, &[]);
    assert!(drafts[key].is_dirty(&[]));
    replace_configuration(&mut configs, &mut drafts, key.into(), expected.clone());
    assert_eq!(configs[key], expected);
    assert_clean_baseline(&drafts[key], &expected);
    assert_eq!(configs[other], other_config);
    assert_same_draft(&drafts[other], &other_draft);
}
