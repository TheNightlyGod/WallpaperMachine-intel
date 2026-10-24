use super::{
    DisplayDescExt, DisplayIdentityExt, DisplayLabelExt, DisplaySelectorExt, DisplaySnapshotExt,
    MonitorRow,
};
use crate::api::BridgeErrorKind;
use crate::config::{
    AppConfig, MonitorCfg, MonitorRender, MonitorSettingsCfg, SerializedSelector,
    resolve_frame_rate, stored_frame_rate,
};
use wallpaper_core::{
    DisplayDesc, DisplayIdentity, DisplaySelector, DisplaySnapshotEntry, WallpaperAssignment,
};

fn named_identity(uuid: Option<&str>, name: Option<&str>) -> DisplayIdentity {
    DisplayIdentity {
        uuid: uuid.map(str::to_owned),
        name: name.map(str::to_owned),
        ..DisplayIdentity::default()
    }
}

fn hardware_identity(
    vendor: Option<u32>,
    model: Option<u32>,
    serial: Option<u32>,
    unit: Option<u32>,
) -> DisplayIdentity {
    DisplayIdentity {
        vendor_id: vendor,
        model_id: model,
        serial_number: serial,
        unit_number: unit,
        ..DisplayIdentity::default()
    }
}

fn inventory_entry(display_id: u32, identity: DisplayIdentity) -> DisplaySnapshotEntry {
    DisplaySnapshotEntry {
        desc: DisplayDesc {
            display_id,
            identity: identity.clone(),
            x: -37,
            y: 19,
            width: 1733,
            height: 977,
            scale_factor: 1.25,
            refresh_rate_hz: 83,
        },
        identity,
        handle: None,
        accepts_pointer_input: true,
        paused: false,
        window_active: true,
        assignment: None,
    }
}

fn identity_selector(identity: &DisplayIdentity) -> SerializedSelector {
    SerializedSelector::from_selector(&DisplaySelector::Identity(identity.clone()))
}

fn live(display_id: u32) -> SerializedSelector {
    SerializedSelector::LiveDisplayId { display_id }
}

fn saved(selector: SerializedSelector, wallpaper: Option<&str>) -> MonitorCfg {
    MonitorCfg {
        selector,
        wallpaper: wallpaper.map(str::to_owned),
        ..MonitorCfg::default()
    }
}

fn edge(selector: SerializedSelector, target: SerializedSelector) -> MonitorCfg {
    MonitorCfg {
        mode: "mirror".into(),
        mirror_target: Some(target),
        ..saved(selector, None)
    }
}

fn tuned_settings(selector: SerializedSelector, rate: u32, volume: f32) -> MonitorSettingsCfg {
    MonitorSettingsCfg {
        selector,
        scaling_mode: "fit".into(),
        scaling_factor: 1.75,
        frame_rate: Some(rate),
        volume,
        muted: true,
    }
}

fn row(config: MonitorCfg, index: Option<usize>) -> MonitorRow {
    MonitorRow {
        selector: config.selector.clone(),
        config,
        connected: index.is_some(),
        display_index: index,
    }
}

fn configuration(monitors: Vec<MonitorCfg>) -> AppConfig {
    let mut value = AppConfig::default();
    value.schema_version = 47;
    value.monitors = monitors;
    value
}

#[test]
fn d01_stable_availability_is_not_physical_or_stable_matching() {
    let cases = [
        (DisplayIdentity::default(), false),
        (named_identity(Some(""), None), false),
        (named_identity(Some(" "), None), true),
        (named_identity(Some("unparsed-token"), None), true),
        (named_identity(None, Some("Only a name")), false),
        (hardware_identity(Some(0), Some(0), Some(0), None), true),
        (hardware_identity(Some(0), Some(0), None, Some(0)), true),
        (hardware_identity(Some(7), Some(9), None, None), false),
        (hardware_identity(None, Some(9), Some(0), Some(0)), false),
        (hardware_identity(Some(7), None, Some(0), Some(0)), false),
    ];
    for (identity, available) in cases {
        assert_eq!(identity.has_stable_identity(), available, "{identity:?}");
        let entry = inventory_entry(0, identity.clone());
        assert_eq!(entry.stable_identity_selector().is_some(), available);
        assert_eq!(
            entry.connected_selector(),
            if available {
                identity_selector(&identity)
            } else {
                live(0)
            }
        );
    }
    let mut empty_uuid_hardware = hardware_identity(Some(0), Some(0), None, Some(0));
    empty_uuid_hardware.uuid = Some(String::new());
    assert!(empty_uuid_hardware.has_stable_identity());
    let no_identity = inventory_entry(u32::MAX, DisplayIdentity::default());
    assert_eq!(no_identity.connected_selector(), live(u32::MAX));

    let unit = hardware_identity(Some(23), Some(71), None, Some(0));
    assert_eq!(unit.match_score(&unit), Some(2));
    assert!(!unit.has_stable_match(&unit));
    assert!(unit.same_physical_identity(&unit));
    let mut serial = unit.clone();
    serial.serial_number = Some(0);
    assert_eq!(serial.match_score(&serial), Some(3));
    assert!(serial.has_stable_match(&serial));
    let mut conflicting_serial = serial.clone();
    conflicting_serial.serial_number = Some(99);
    assert_eq!(serial.match_score(&conflicting_serial), None);
    assert!(!serial.has_stable_match(&conflicting_serial));
    assert!(!serial.same_physical_identity(&conflicting_serial));

    let mut uuid_a = serial.clone();
    uuid_a.uuid = Some("panel-a-62".into());
    let mut uuid_b = uuid_a.clone();
    uuid_b.uuid = Some("panel-b-93".into());
    assert_eq!(uuid_a.match_score(&uuid_a), Some(4));
    assert!(uuid_a.has_stable_match(&uuid_a));
    assert_eq!(uuid_a.match_score(&uuid_b), None);
    assert!(!uuid_a.has_stable_match(&uuid_b));
    assert!(!uuid_a.same_physical_identity(&uuid_b));
    assert!(!DisplayIdentity::default().same_physical_identity(&DisplayIdentity::default()));
    let name_only = named_identity(None, Some("Same label"));
    assert_eq!(name_only.match_score(&name_only), None);
    assert!(!name_only.has_stable_match(&name_only));
}

#[test]
fn d02_distinct_panels_keep_assignments_and_settings_across_two_reconnects() {
    let primary = inventory_entry(997, named_identity(Some("main-copper"), None));
    let mut old_a = hardware_identity(Some(31), Some(41), Some(501), Some(1));
    old_a.uuid = Some("panel-copper-a".into());
    old_a.name = Some("West".into());
    let mut old_b = hardware_identity(Some(31), Some(41), Some(502), Some(2));
    old_b.uuid = Some("panel-copper-b".into());
    old_b.name = Some("East".into());
    let mut current_a = old_a.clone();
    current_a.unit_number = Some(2);
    current_a.name = Some("East".into());
    let mut current_b = old_b.clone();
    current_b.unit_number = Some(1);
    current_b.name = Some("West".into());

    let mut assignment_a = saved(identity_selector(&old_a), Some("art-copper"));
    assignment_a.enabled = false;
    let assignment_b = saved(identity_selector(&old_b), Some("art-indigo"));
    let reference = edge(live(773), identity_selector(&old_a));
    let mut config = configuration(vec![
        saved(SerializedSelector::Primary, Some("art-main")),
        assignment_a.clone(),
        assignment_b.clone(),
        reference.clone(),
    ]);
    config.monitor_settings = vec![
        tuned_settings(identity_selector(&old_a), 27, 0.25),
        tuned_settings(identity_selector(&old_b), 43, 0.75),
    ];
    let before = config.clone();
    let inventory = vec![
        primary.clone(),
        inventory_entry(211, current_b.clone()),
        inventory_entry(433, current_a.clone()),
    ];
    let normalized = config.normalized(&inventory);
    assert_eq!(config, before);
    let mut expected = before.clone();
    expected.primary_display = Some(identity_selector(&primary.identity));
    expected.monitors[1].selector = identity_selector(&current_a);
    expected.monitors[2].selector = identity_selector(&current_b);
    expected.monitors[3].mirror_target = Some(identity_selector(&current_a));
    expected.monitor_settings[0].selector = identity_selector(&current_a);
    expected.monitor_settings[1].selector = identity_selector(&current_b);
    assert_eq!(normalized, expected);

    current_a.unit_number = Some(8);
    current_a.name = Some("Upper".into());
    current_b.unit_number = Some(9);
    current_b.name = Some("Lower".into());
    let returned = vec![
        primary,
        inventory_entry(887, current_a.clone()),
        inventory_entry(223, current_b.clone()),
    ];
    let mut second = normalized;
    assert!(second.sync_known_monitors(&returned));
    expected.monitors[1].selector = identity_selector(&current_a);
    expected.monitors[2].selector = identity_selector(&current_b);
    expected.monitors[3].mirror_target = Some(identity_selector(&current_a));
    expected.monitor_settings[0].selector = identity_selector(&current_a);
    expected.monitor_settings[1].selector = identity_selector(&current_b);
    assert_eq!(second, expected);
    assert!(!second.sync_known_monitors(&returned));
    assert_eq!(second, expected);
}

#[test]
fn d02_retained_aliases_keep_first_assignment_but_prefer_current_settings() {
    let old = named_identity(Some("stable-fern"), Some("Earlier"));
    let current = named_identity(Some("stable-fern"), Some("Current"));
    let primary = inventory_entry(601, named_identity(Some("primary-fern"), None));
    let panel = inventory_entry(607, current.clone());
    let mut first = edge(identity_selector(&old), SerializedSelector::Primary);
    first.wallpaper = Some("first-art".into());
    first.enabled = false;
    let later = saved(identity_selector(&current), Some("discarded-art"));
    let mut current_settings = tuned_settings(identity_selector(&current), 53, 0.875);
    current_settings.scaling_mode = "stretch".into();
    current_settings.scaling_factor = 2.25;
    current_settings.muted = false;
    let mut config = configuration(vec![
        saved(SerializedSelector::Primary, Some("seed-art")),
        first.clone(),
        later,
        edge(live(619), identity_selector(&old)),
    ]);
    config.monitor_settings = vec![
        tuned_settings(identity_selector(&old), 17, 0.125),
        current_settings.clone(),
    ];
    let recorded_primary = identity_selector(&primary.identity);
    let normalized = config.normalized(&[primary, panel]);
    first.selector = identity_selector(&current);
    let mut expected = config.clone();
    expected.primary_display = Some(recorded_primary);
    expected.monitors = vec![
        saved(SerializedSelector::Primary, Some("seed-art")),
        first,
        edge(live(619), identity_selector(&current)),
    ];
    expected.monitor_settings = vec![current_settings];
    assert_eq!(normalized, expected);

    let mut without_current_settings = config.clone();
    without_current_settings.monitor_settings.pop();
    let mut expected_first = without_current_settings.monitor_settings[0].clone();
    expected_first.selector = identity_selector(&current);
    let normalized = without_current_settings.normalized(&[
        inventory_entry(601, named_identity(Some("primary-fern"), None)),
        inventory_entry(607, current),
    ]);
    assert_eq!(normalized.monitor_settings, vec![expected_first]);
}

#[test]
fn d02_disconnected_stable_duplicates_collapse_but_unit_only_pairs_do_not() {
    let first_identity = named_identity(Some("offline-ochre"), Some("First"));
    let later_identity = named_identity(Some("offline-ochre"), Some("Later"));
    let mut unit_a = hardware_identity(Some(97), Some(13), None, Some(4));
    unit_a.name = Some("Unit first".into());
    let mut unit_b = unit_a.clone();
    unit_b.name = Some("Unit later".into());
    let first = saved(identity_selector(&first_identity), Some("keep-ochre"));
    let unit_first = saved(identity_selector(&unit_a), Some("keep-unit-a"));
    let unit_later = saved(identity_selector(&unit_b), Some("keep-unit-b"));
    let mut config = configuration(vec![
        saved(SerializedSelector::Primary, None),
        first.clone(),
        saved(identity_selector(&later_identity), Some("lose-ochre")),
        unit_first.clone(),
        unit_later.clone(),
    ]);
    let settings_first = tuned_settings(identity_selector(&first_identity), 29, 0.375);
    config.monitor_settings = vec![
        settings_first.clone(),
        tuned_settings(identity_selector(&later_identity), 47, 0.625),
    ];
    assert_eq!(
        config.monitor_rows(&[]),
        vec![
            row(saved(SerializedSelector::Primary, None), None),
            row(first.clone(), None),
            row(
                saved(identity_selector(&later_identity), Some("lose-ochre")),
                None
            ),
            row(unit_first.clone(), None),
            row(unit_later.clone(), None),
        ]
    );
    let normalized = config.normalized(&[]);
    let mut expected = config.clone();
    expected.monitors = vec![
        saved(SerializedSelector::Primary, None),
        first,
        unit_first,
        unit_later,
    ];
    expected.monitor_settings = vec![settings_first];
    assert_eq!(normalized, expected);
    assert!(unit_a.same_physical_identity(&unit_b));
    assert!(!unit_a.has_stable_match(&unit_b));
}

#[test]
fn d03_primary_order_aliases_and_first_match_borrows_are_distinct() {
    let primary = inventory_entry(991, named_identity(Some("first-primary"), Some("Main")));
    let same_live = inventory_entry(991, named_identity(Some("different-id"), None));
    let physical_alias = inventory_entry(7, primary.identity.clone());
    let secondary = inventory_entry(1, named_identity(Some("true-secondary"), None));
    let inventory = vec![
        primary.clone(),
        same_live,
        physical_alias.clone(),
        secondary.clone(),
    ];
    assert_eq!(
        primary.config_selector(&inventory),
        SerializedSelector::Primary
    );
    assert_eq!(
        primary.connected_selector(),
        identity_selector(&primary.identity)
    );
    assert_eq!(
        physical_alias.config_selector(&inventory),
        SerializedSelector::Primary
    );
    assert_eq!(
        secondary.config_selector(&inventory),
        identity_selector(&secondary.identity)
    );
    assert_eq!(primary.config_selector(&[]), primary.connected_selector());
    assert!(!DisplaySelector::Primary.matches_display(&primary));
    assert!(DisplaySelector::Primary.matches_primary(&secondary, &[]));
    assert!(std::ptr::eq(
        DisplaySelector::Primary
            .resolve_display(&inventory)
            .unwrap(),
        &inventory[0]
    ));
    assert!(DisplaySelector::LiveDisplayId(7).matches_primary(&primary, &inventory));
    assert!(!DisplaySelector::LiveDisplayId(7).matches_primary(&primary, &[primary.clone()]));
    assert!(DisplaySelector::LiveDisplayId(991).matches_primary(&primary, &[]));
    assert_eq!(DisplaySelector::Primary.resolve_display(&[]), None);
    assert_eq!(
        DisplaySelector::LiveDisplayId(404).resolve_display(&inventory),
        None
    );
    assert_eq!(
        DisplaySelector::Identity(named_identity(Some("unknown"), None))
            .resolve_display(&inventory),
        None
    );
    let rows = AppConfig::default().monitor_rows(&inventory);
    assert_eq!(
        rows,
        vec![
            row(saved(SerializedSelector::Primary, None), Some(0)),
            row(saved(identity_selector(&secondary.identity), None), Some(3)),
        ]
    );

    let mut desired = hardware_identity(Some(17), Some(67), Some(89), Some(3));
    desired.uuid = Some("strong-ruby".into());
    let weak = hardware_identity(Some(17), Some(67), None, Some(3));
    let mut earlier = inventory_entry(431, weak);
    earlier.paused = true;
    earlier.window_active = false;
    earlier.accepts_pointer_input = false;
    earlier.desc.refresh_rate_hz = 117;
    earlier.assignment = Some(WallpaperAssignment::Mirror(DisplaySelector::LiveDisplayId(
        999,
    )));
    let later = inventory_entry(433, desired.clone());
    assert_eq!(desired.match_score(&earlier.identity), Some(2));
    assert_eq!(desired.match_score(&later.identity), Some(4));
    let candidates = [earlier, later];
    let selected = DisplaySelector::Identity(desired)
        .resolve_display(&candidates)
        .unwrap();
    assert!(std::ptr::eq(selected, &candidates[0]));
    assert_eq!(selected, &candidates[0]);
    assert_ne!(selected, &candidates[1]);
}

#[test]
fn d03_explicit_primary_and_first_duplicate_live_id_control_matching() {
    let explicit = inventory_entry(733, named_identity(Some("explicit-lake"), None));
    let first = inventory_entry(739, named_identity(Some("not-lake"), None));
    let later = inventory_entry(739, explicit.identity.clone());
    let inventory = [first.clone(), later.clone()];
    assert!(!DisplaySelector::LiveDisplayId(739).matches_primary(&explicit, &inventory));
    assert!(
        DisplaySelector::LiveDisplayId(739)
            .matches_primary(&explicit, &[later.clone(), first.clone()])
    );
    assert!(
        DisplaySelector::Identity(explicit.identity.clone()).matches_primary(&explicit, &inventory)
    );
    let selected = DisplaySelector::LiveDisplayId(739)
        .resolve_display(&inventory)
        .unwrap();
    assert!(std::ptr::eq(selected, &inventory[0]));
    assert_eq!(selected, &first);
    assert_eq!(
        later.config_selector(&inventory),
        SerializedSelector::Primary
    );
}

#[test]
fn d03_snapshot_and_descriptor_identity_evidence_is_not_unified() {
    let mut a = inventory_entry(
        811,
        named_identity(Some("snapshot-pair"), Some("Snapshot name")),
    );
    let mut b = inventory_entry(823, a.identity.clone());
    a.desc.identity = named_identity(Some("descriptor-a"), Some("Wrong label"));
    b.desc.identity = named_identity(Some("descriptor-b"), None);
    assert!(a.matches_primary(&b));
    assert!(!a.desc.same_physical_display(&b.desc));
    assert!(DisplaySelector::Identity(a.identity.clone()).matches_display(&b));
    assert_eq!(a.title(), "Snapshot name (811)");
    assert_eq!(a.connected_selector(), identity_selector(&a.identity));
    b.identity = named_identity(Some("other-snapshot"), None);
    b.desc.identity = a.desc.identity.clone();
    assert!(!a.matches_primary(&b));
    assert!(a.desc.same_physical_display(&b.desc));
    assert!(!DisplaySelector::Identity(a.desc.identity.clone()).matches_display(&a));
    b.desc.display_id = a.desc.display_id;
    b.desc.identity = named_identity(Some("another-descriptor"), None);
    assert!(a.matches_primary(&b));
    assert!(a.desc.same_physical_display(&b.desc));
}

#[test]
fn d04_real_conversions_ids_and_saved_encoding_remain_distinct() {
    let identity = DisplayIdentity {
        uuid: Some("tag\"\\\n".into()),
        vendor_id: Some(0),
        model_id: Some(29),
        serial_number: Some(0),
        unit_number: Some(u32::MAX),
        name: Some("North (Q)".into()),
    };
    let selector = identity_selector(&identity);
    assert_eq!(
        selector.to_selector(),
        DisplaySelector::Identity(identity.clone())
    );
    assert_eq!(
        selector.id(),
        r#"identity:{"uuid":"tag\"\\\n","vendor_id":0,"model_id":29,"serial_number":0,"unit_number":4294967295,"name":"North (Q)"}"#
    );
    let sparse = identity_selector(&named_identity(None, Some("Only \"name\"")));
    assert_eq!(
        sparse.id(),
        r#"identity:{"uuid":null,"vendor_id":null,"model_id":null,"serial_number":null,"unit_number":null,"name":"Only \"name\""}"#
    );
    assert_eq!(
        serde_json::to_value(&sparse).unwrap(),
        serde_json::json!({
            "kind": "identity", "name": "Only \"name\""
        })
    );
    for (serialized, core, id, json) in [
        (
            SerializedSelector::Primary,
            DisplaySelector::Primary,
            "primary",
            serde_json::json!({"kind": "primary"}),
        ),
        (
            live(0),
            DisplaySelector::LiveDisplayId(0),
            "0",
            serde_json::json!({"kind": "live_display_id", "display_id": 0}),
        ),
        (
            live(u32::MAX),
            DisplaySelector::LiveDisplayId(u32::MAX),
            "4294967295",
            serde_json::json!({"kind": "live_display_id", "display_id": 4294967295u32}),
        ),
    ] {
        assert_eq!(serialized.to_selector(), core);
        assert_eq!(SerializedSelector::from_selector(&core), serialized);
        assert_eq!(serialized.id(), id);
        assert_eq!(serde_json::to_value(&serialized).unwrap(), json);
    }
    let flattened = serde_json::to_value(saved(sparse.clone(), None)).unwrap();
    assert_eq!(flattened["kind"], "identity");
    assert_eq!(flattened["name"], "Only \"name\"");
    assert!(flattened.get("selector").is_none());
    assert!(flattened.get("wallpaper").is_none());
    assert!(flattened.get("mirror_target").is_none());
    let settings = MonitorSettingsCfg {
        selector: sparse,
        ..MonitorSettingsCfg::default()
    };
    let flattened_settings = serde_json::to_value(settings).unwrap();
    assert_eq!(flattened_settings["kind"], "identity");
    assert!(flattened_settings.get("selector").is_none());
    assert!(flattened_settings.get("frame_rate").is_none());
}

fn consumed_final_live_id(title: &str) -> u32 {
    let (_, group) = title.rsplit_once('(').expect("a final title group");
    let group = group.strip_suffix(')').expect("a closed final title group");
    group
        .split_once(" - ")
        .map_or(group, |(number, _)| number)
        .parse()
        .unwrap()
}

#[test]
fn d05_labels_preserve_literal_names_hardware_and_suffix_data() {
    let cases = [
        (None, None, None, "Display"),
        (Some("Display"), None, None, "Display"),
        (None, Some(0), None, "Vendor 0"),
        (Some("Display"), None, Some(0), "Model 0"),
        (None, Some(83), Some(17), "Vendor 83 - Model 17"),
        (Some("Display"), Some(83), Some(17), "Vendor 83 - Model 17"),
        (Some(""), None, None, ""),
        (Some(""), Some(83), Some(17), " - Vendor 83 - Model 17"),
        (
            Some("display"),
            Some(83),
            Some(17),
            "display - Vendor 83 - Model 17",
        ),
        (Some(" Display "), None, None, " Display "),
        (
            Some("Desk (arch)"),
            Some(83),
            None,
            "Desk (arch) - Vendor 83",
        ),
        (
            Some("Desk (arch)"),
            None,
            Some(17),
            "Desk (arch) - Model 17",
        ),
        (
            Some("Desk (arch)"),
            Some(83),
            Some(17),
            "Desk (arch) - Vendor 83 - Model 17",
        ),
    ];
    for (name, vendor, model, body) in cases {
        let mut identity = named_identity(None, name);
        identity.vendor_id = vendor;
        identity.model_id = model;
        let mut entry = inventory_entry(1867, identity);
        entry.desc.identity = named_identity(Some("irrelevant"), Some("Descriptor substitute"));
        assert_eq!(entry.title(), format!("{body} (1867)"));
        assert_eq!(entry.title_with_role(false), format!("{body} (1867)"));
        assert_eq!(
            entry.title_with_role(true),
            format!("{body} (1867 - Primary)")
        );
        assert_eq!(entry.title_with_suffix(""), format!("{body} "));
        assert_eq!(
            entry.title_with_suffix(" \nraw() "),
            format!("{body}  \nraw() ")
        );
        assert_eq!(consumed_final_live_id(&entry.title()), 1867);
        assert_eq!(consumed_final_live_id(&entry.title_with_role(true)), 1867);
        let monitor = entry.title_with_suffix("(1867 - Secondary - mural-violet)");
        assert_eq!(monitor, format!("{body} (1867 - Secondary - mural-violet)"));
        assert_eq!(consumed_final_live_id(&monitor), 1867);
        assert_ne!(monitor, entry.title_with_role(false));
        let primary_monitor = entry.title_with_suffix("(1867 - Primary - mural-gold)");
        assert_eq!(
            primary_monitor,
            format!("{body} (1867 - Primary - mural-gold)")
        );
        assert_eq!(consumed_final_live_id(&primary_monitor), 1867);
    }
    let inventory = [
        inventory_entry(
            1907,
            named_identity(Some("title-primary"), Some("Main (old 999)")),
        ),
        inventory_entry(
            1913,
            named_identity(Some("title-stable"), Some("Panel (side)")),
        ),
        inventory_entry(0, named_identity(None, Some("Live (fallback)"))),
    ];
    let rows = AppConfig::default().monitor_rows(&inventory);
    assert_eq!(
        rows.iter()
            .map(|row| row.selector.clone())
            .collect::<Vec<_>>(),
        vec![
            SerializedSelector::Primary,
            identity_selector(&inventory[1].identity),
            live(0),
        ]
    );
    for (domain_row, expected_live_id) in rows.iter().zip([1907, 1913, 0]) {
        let entry = &inventory[domain_row.display_index.unwrap()];
        let title = entry.title_with_role(domain_row.selector == SerializedSelector::Primary);
        assert_eq!(consumed_final_live_id(&title), expected_live_id);
    }
}

#[test]
fn d06_normalized_is_a_preserving_clone_and_sync_is_idempotent() {
    let primary = inventory_entry(919, named_identity(Some("main-slate"), None));
    let mut independent = inventory_entry(927, named_identity(Some("secondary-slate"), None));
    independent.window_active = false;
    let mut mirrored = inventory_entry(937, named_identity(Some("mirror-slate"), None));
    mirrored.assignment = Some(WallpaperAssignment::Mirror(DisplaySelector::Primary));
    let mut malformed_primary = edge(SerializedSelector::Primary, live(927));
    malformed_primary.enabled = false;
    malformed_primary.wallpaper = Some("main-slate-art".into());
    let config = configuration(vec![malformed_primary]);
    let before = config.clone();
    let recorded_primary = identity_selector(&primary.identity);
    let inventory = [primary, independent.clone(), mirrored.clone()];
    let normalized = config.normalized(&inventory);
    assert_eq!(config, before);
    let mut expected = config.clone();
    expected.primary_display = Some(recorded_primary);
    expected.monitors = vec![
        saved(SerializedSelector::Primary, Some("main-slate-art")),
        saved(
            identity_selector(&independent.identity),
            Some("main-slate-art"),
        ),
        edge(
            identity_selector(&mirrored.identity),
            SerializedSelector::Primary,
        ),
    ];
    assert_eq!(normalized, expected);
    assert_eq!(normalized.schema_version, 47);
    let mut synchronized = config.clone();
    assert!(synchronized.sync_known_monitors(&inventory));
    assert_eq!(synchronized, expected);
    assert!(!synchronized.sync_known_monitors(&inventory));
    assert_eq!(synchronized, expected);

    synchronized.monitors[1].enabled = false;
    let disabled = synchronized.clone();
    assert!(!synchronized.sync_known_monitors(&[]));
    assert_eq!(synchronized, disabled);
    assert!(!synchronized.sync_known_monitors(&inventory));
    assert_eq!(synchronized, disabled);
}

#[test]
fn d06_primary_wallpaper_precedence_and_live_alias_removal_are_exact() {
    let primary = inventory_entry(953, named_identity(Some("primary-coral"), Some("Current")));
    let alias = inventory_entry(959, primary.identity.clone());
    let stable = identity_selector(&primary.identity);
    for (first, expected_art) in [
        (Some("primary-art"), Some("primary-art")),
        (Some(""), Some("")),
        (None, Some("live-art")),
    ] {
        let mut config = configuration(vec![
            saved(live(959), Some("live-art")),
            saved(stable.clone(), Some("stable-art")),
            saved(SerializedSelector::Primary, first),
        ]);
        config.monitor_settings = vec![tuned_settings(live(959), 33, 0.625)];
        let before_settings = config.monitor_settings.clone();
        assert!(config.sync_known_monitors(&[primary.clone(), alias.clone()]));
        assert_eq!(
            config.monitors,
            vec![
                saved(SerializedSelector::Primary, expected_art),
                saved(stable.clone(), Some("stable-art")),
            ]
        );
        assert_eq!(config.monitor_settings, before_settings);
    }
    let mut config = configuration(vec![
        saved(live(953), None),
        saved(stable.clone(), Some("stable-fallback")),
    ]);
    assert!(config.sync_known_monitors(&[primary]));
    assert_eq!(
        config.monitors,
        vec![
            saved(SerializedSelector::Primary, Some("stable-fallback")),
            saved(stable, Some("stable-fallback")),
        ]
    );
}

#[test]
fn d06_settings_only_alias_change_and_float_partial_equality_drive_changed() {
    let old = named_identity(Some("settings-sage"), Some("Before"));
    let current = named_identity(Some("settings-sage"), Some("After"));
    let inventory = [
        inventory_entry(1013, named_identity(Some("main-sage"), None)),
        inventory_entry(1019, current.clone()),
    ];
    let mut config = configuration(vec![
        saved(SerializedSelector::Primary, Some("sage-art")),
        saved(identity_selector(&current), Some("own-sage")),
    ]);
    config.monitor_settings = vec![tuned_settings(identity_selector(&old), 39, 0.25)];
    let monitors = config.monitors.clone();
    let mut expected_setting = config.monitor_settings[0].clone();
    expected_setting.selector = identity_selector(&current);
    assert!(config.sync_known_monitors(&inventory));
    assert_eq!(config.monitors, monitors);
    assert_eq!(config.monitor_settings, vec![expected_setting]);
    assert!(!config.sync_known_monitors(&inventory));

    for volume_nan in [false, true] {
        let mut config = configuration(vec![saved(SerializedSelector::Primary, None)]);
        let mut setting = tuned_settings(live(1021), 39, 0.25);
        if volume_nan {
            setting.volume = f32::NAN;
        } else {
            setting.scaling_factor = f64::NAN;
        }
        let original_scaling = setting.scaling_factor.to_bits();
        let original_volume = setting.volume.to_bits();
        config.monitor_settings = vec![setting];
        for _ in 0..2 {
            assert!(config.sync_known_monitors(&[]));
            assert_eq!(
                config.monitors,
                vec![saved(SerializedSelector::Primary, None)]
            );
            assert_eq!(config.monitor_settings.len(), 1);
            assert_eq!(config.monitor_settings[0].selector, live(1021));
            assert_eq!(
                config.monitor_settings[0].scaling_factor.to_bits(),
                original_scaling
            );
            assert_eq!(config.monitor_settings[0].volume.to_bits(), original_volume);
            assert_eq!(config.monitor_settings[0].frame_rate, Some(39));
            assert_eq!(config.schema_version, 47);
        }
    }
    let mut infinity = configuration(vec![saved(SerializedSelector::Primary, None)]);
    let mut setting = tuned_settings(live(1031), 39, f32::INFINITY);
    setting.scaling_factor = f64::NEG_INFINITY;
    infinity.monitor_settings = vec![setting];
    let before = infinity.clone();
    assert!(!infinity.sync_known_monitors(&[]));
    assert_eq!(infinity, before);
}

#[test]
fn d06_ensure_and_repeated_primary_keep_first_exact_record_semantics() {
    let nonprimary = saved(live(1061), Some("side-art"));
    let mut first = edge(SerializedSelector::Primary, live(1063));
    first.mode = "Mirror".into();
    first.enabled = false;
    let mut later = edge(SerializedSelector::Primary, live(1069));
    later.enabled = false;
    later.wallpaper = Some("late-primary-art".into());
    let original = configuration(vec![nonprimary.clone(), first.clone(), later.clone()]);
    assert_eq!(
        original.monitor_rows(&[]),
        vec![row(nonprimary.clone(), None), row(first.clone(), None)]
    );
    let mut ensured = original.clone();
    {
        let selected = ensured.ensure_monitor(SerializedSelector::Primary);
        assert_eq!(selected, &first);
        selected.wallpaper = Some("borrow-written".into());
    }
    let mut expected = original.clone();
    expected.monitors[1].wallpaper = Some("borrow-written".into());
    assert_eq!(ensured, expected);
    let missing = live(1087);
    assert_eq!(
        ensured.ensure_monitor(missing.clone()),
        &MonitorCfg {
            selector: missing.clone(),
            ..MonitorCfg::default()
        }
    );
    expected.monitors.push(saved(missing.clone(), None));
    assert_eq!(ensured, expected);
    ensured.ensure_monitor(missing).enabled = false;
    expected.monitors.last_mut().unwrap().enabled = false;
    assert_eq!(ensured, expected);

    let normalized = original.normalized(&[]);
    let protected = saved(SerializedSelector::Primary, None);
    let mut expected_normalized = original.clone();
    expected_normalized.monitors = vec![protected.clone(), nonprimary.clone(), later];
    assert_eq!(normalized, expected_normalized);
    assert_eq!(
        normalized.monitor_rows(&[]),
        vec![row(protected, None), row(nonprimary, None)]
    );
    let mut repeated = normalized.clone();
    assert!(!repeated.sync_known_monitors(&[]));
    assert_eq!(repeated, normalized);
    assert_eq!(original.monitors[1], first);
}

#[test]
fn d06_existing_secondary_modes_are_literal_and_first_seen_mirror_is_not_primary_protection() {
    let primary = inventory_entry(1091, named_identity(Some("mode-main"), None));
    let secondary = inventory_entry(1093, named_identity(Some("mode-secondary"), None));
    for mode in ["Mirror", "MIRROR", "mirror ", "", "unrecognized"] {
        let mut existing = edge(
            identity_selector(&secondary.identity),
            SerializedSelector::Primary,
        );
        existing.mode = mode.into();
        existing.enabled = false;
        existing.wallpaper = Some("literal-art".into());
        let mut config = configuration(vec![
            saved(SerializedSelector::Primary, None),
            existing.clone(),
        ]);
        let mut before = config.clone();
        before.primary_display = Some(identity_selector(&primary.identity));
        assert!(
            config.sync_known_monitors(&[primary.clone(), secondary.clone()]),
            "the first sync records the main display"
        );
        assert_eq!(config, before);
        assert!(!config.sync_known_monitors(&[primary.clone(), secondary.clone()]));
        assert_eq!(config, before);
        assert_eq!(
            config.monitor_rows(&[primary.clone(), secondary.clone()]),
            vec![
                row(saved(SerializedSelector::Primary, None), Some(0)),
                row(existing, Some(1)),
            ]
        );
    }
    let mut mirror_primary = primary;
    mirror_primary.assignment = Some(WallpaperAssignment::Mirror(DisplaySelector::LiveDisplayId(
        1093,
    )));
    let config = configuration(Vec::new());
    assert_eq!(
        config.monitor_rows(&[mirror_primary.clone()]),
        vec![row(edge(SerializedSelector::Primary, live(1093)), Some(0)),]
    );
    let normalized = config.normalized(&[mirror_primary.clone()]);
    assert_eq!(
        normalized.monitors,
        vec![saved(SerializedSelector::Primary, None)]
    );
    assert_eq!(
        normalized.monitor_rows(&[mirror_primary]),
        vec![row(saved(SerializedSelector::Primary, None), Some(0))]
    );
}

#[test]
fn d07_raw_rows_keep_connected_indexes_then_first_unmatched_saved_order_without_mutation() {
    let primary = inventory_entry(1193, named_identity(Some("rows-main"), None));
    let alias = inventory_entry(1199, primary.identity.clone());
    let secondary = inventory_entry(11, DisplayIdentity::default());
    let mut repeated_secondary = secondary.clone();
    repeated_secondary.desc.refresh_rate_hz = 144;
    let inventory = [primary.clone(), alias, secondary, repeated_secondary];
    let mut malformed_primary = edge(SerializedSelector::Primary, live(11));
    malformed_primary.enabled = false;
    malformed_primary.wallpaper = Some("raw-primary".into());
    let mut disabled = saved(live(11), Some("raw-secondary"));
    disabled.enabled = false;
    let offline = saved(live(1213), Some("offline-first"));
    let offline_identity = saved(
        identity_selector(&named_identity(Some("rows-offline"), None)),
        Some("offline-last"),
    );
    let primary_identity = saved(identity_selector(&primary.identity), Some("primary-alias"));
    let config = configuration(vec![
        offline.clone(),
        malformed_primary.clone(),
        disabled.clone(),
        saved(live(1199), Some("live-alias")),
        offline_identity.clone(),
        saved(live(1213), Some("shadowed-offline")),
        primary_identity.clone(),
    ]);
    let before = config.clone();
    assert_eq!(
        config.monitor_rows(&inventory),
        vec![
            row(malformed_primary.clone(), Some(0)),
            row(disabled.clone(), Some(2)),
            row(disabled.clone(), Some(3)),
            row(offline.clone(), None),
            row(offline_identity.clone(), None),
        ]
    );
    assert_eq!(config, before);
    assert_eq!(
        config.monitor_rows(&[]),
        vec![
            row(offline, None),
            row(malformed_primary, None),
            row(disabled, None),
            row(saved(live(1199), Some("live-alias")), None),
            row(offline_identity, None),
            row(primary_identity, None),
        ]
    );
    assert_eq!(config, before);
}

#[test]
fn d07_secondary_physical_duplicates_remain_connected_and_retained_alias_transition_remains_real() {
    let primary = inventory_entry(1237, named_identity(Some("duplicate-main"), None));
    let near = inventory_entry(
        1249,
        named_identity(Some("duplicate-panel"), Some("Near bank")),
    );
    let far = inventory_entry(
        1259,
        named_identity(Some("duplicate-panel"), Some("Far bank")),
    );
    let inventory = [primary, near.clone(), far.clone()];
    let p = saved(SerializedSelector::Primary, Some("seed-teal"));
    let n = saved(identity_selector(&near.identity), Some("seed-teal"));
    let f = saved(identity_selector(&far.identity), Some("seed-teal"));
    let mut config = configuration(vec![p.clone()]);
    assert!(config.sync_known_monitors(&inventory));
    assert_eq!(config.monitors, vec![p.clone(), n.clone(), f.clone()]);
    assert!(config.sync_known_monitors(&inventory));
    assert_eq!(config.monitors, vec![p.clone(), f.clone(), n.clone()]);
    assert!(!config.sync_known_monitors(&inventory));
    assert_eq!(config.monitors, vec![p.clone(), f.clone(), n.clone()]);
    assert_eq!(
        config.monitor_rows(&inventory),
        vec![row(p, Some(0)), row(n, Some(1)), row(f, Some(2))]
    );

    let unit = hardware_identity(Some(43), Some(61), None, Some(0));
    let inventory = [
        inventory_entry(1261, unit.clone()),
        inventory_entry(1277, unit),
    ];
    assert_eq!(
        AppConfig::default().monitor_rows(&inventory),
        vec![row(saved(SerializedSelector::Primary, None), Some(0))]
    );
    let other = inventory_entry(1283, named_identity(Some("other-primary"), None));
    let repeated = inventory_entry(
        1289,
        named_identity(Some("same-secondary"), Some("same exact")),
    );
    let inventory = [other, repeated.clone(), repeated.clone()];
    let secondary = saved(identity_selector(&repeated.identity), Some("same-record"));
    let config = configuration(vec![
        saved(SerializedSelector::Primary, None),
        secondary.clone(),
    ]);
    assert_eq!(
        config.monitor_rows(&inventory),
        vec![
            row(saved(SerializedSelector::Primary, None), Some(0)),
            row(secondary.clone(), Some(1)),
            row(secondary, Some(2)),
        ]
    );
}

fn assert_narrow_case(
    monitors: Vec<MonitorCfg>,
    source: &SerializedSelector,
    target: &SerializedSelector,
    accepts: bool,
) {
    let mut config = configuration(monitors);
    config.monitor_settings = vec![tuned_settings(live(2003), 31, 0.375)];
    let before = config.clone();
    match config.validate_mirror_change(source, target) {
        Ok(()) => assert!(
            accepts,
            "unexpected acceptance: {before:?}, {source:?}, {target:?}"
        ),
        Err(error) => {
            assert!(
                !accepts,
                "unexpected refusal: {before:?}, {source:?}, {target:?}"
            );
            assert_eq!(error.kind(), BridgeErrorKind::InvalidInput);
        }
    }
    assert_eq!(config, before);
}

#[test]
fn d09_narrow_validator_covers_the_complete_first_effective_row_partition() {
    let s = live(2011);
    let a = live(2017);
    let b = live(2027);
    let missing = live(2029);
    let unused = live(2039);
    let stop = |selector: &SerializedSelector| saved(selector.clone(), Some("kept-art"));
    let link = |from: &SerializedSelector, to: &SerializedSelector| edge(from.clone(), to.clone());
    let mut no_target = stop(&a);
    no_target.mode = "mirror".into();
    let cases = vec![
        (vec![], false),
        (vec![stop(&unused)], true),
        (vec![link(&a, &missing)], false),
        (vec![link(&a, &b), link(&b, &missing)], false),
        (vec![link(&a, &b), link(&b, &missing), stop(&unused)], true),
        (vec![link(&a, &b), link(&b, &missing), stop(&a)], true),
        (vec![stop(&a), link(&a, &s)], true),
        (vec![link(&a, &s), stop(&a)], false),
        (vec![link(&a, &b), link(&b, &a), stop(&b)], false),
        (vec![link(&a, &b), stop(&b), link(&b, &a)], true),
        (vec![link(&a, &missing), link(&a, &s)], true),
        (vec![stop(&a)], true),
        (vec![no_target], true),
        (vec![link(&a, &s), stop(&unused)], false),
        (vec![stop(&s), link(&a, &missing)], true),
        (vec![stop(&s), link(&a, &s)], false),
        (vec![stop(&s), link(&a, &b), stop(&b)], true),
        (vec![stop(&s), link(&a, &b), link(&b, &a)], false),
        (vec![stop(&a), link(&b, &b)], true),
        (vec![link(&a, &a), stop(&unused)], false),
    ];
    for (monitors, accepts) in cases {
        assert_narrow_case(monitors, &s, &a, accepts);
    }
    assert_narrow_case(vec![], &s, &s, false);
    assert_narrow_case(vec![stop(&unused)], &s, &s, false);
    for mode in [
        "Mirror",
        "MIRROR",
        "mirror ",
        "",
        "independent",
        "unrecognized",
    ] {
        let mut terminal = link(&a, &s);
        terminal.mode = mode.into();
        terminal.enabled = false;
        assert_narrow_case(vec![terminal], &s, &a, true);
    }
    let mut disabled_edge = link(&a, &s);
    disabled_edge.enabled = false;
    assert_narrow_case(vec![disabled_edge, stop(&unused)], &s, &a, false);
    assert_narrow_case(
        vec![link(&a, &missing)],
        &SerializedSelector::Primary,
        &a,
        false,
    );
    assert_narrow_case(
        vec![link(&a, &missing), stop(&unused)],
        &SerializedSelector::Primary,
        &a,
        true,
    );
    assert_narrow_case(
        vec![
            stop(&SerializedSelector::Primary),
            edge(SerializedSelector::Primary, s.clone()),
        ],
        &s,
        &SerializedSelector::Primary,
        true,
    );
    assert_narrow_case(
        vec![
            edge(SerializedSelector::Primary, s.clone()),
            stop(&SerializedSelector::Primary),
        ],
        &s,
        &SerializedSelector::Primary,
        false,
    );

    let physical_a = named_identity(Some("same-physical-graph"), Some("Name one"));
    let physical_b = named_identity(Some("same-physical-graph"), Some("Name two"));
    assert!(physical_a.same_physical_identity(&physical_b));
    let source = identity_selector(&physical_a);
    let target = identity_selector(&physical_b);
    assert_ne!(source, target);
    assert_narrow_case(vec![saved(target.clone(), None)], &source, &target, true);
    assert_narrow_case(
        vec![edge(target.clone(), source.clone())],
        &source,
        &target,
        false,
    );
    assert_narrow_case(
        vec![saved(live(0), None)],
        &SerializedSelector::Primary,
        &live(0),
        true,
    );
}

#[test]
fn d11_mirror_target_id_preserves_self_id_exclusion_and_primary_alias_asymmetry() {
    let primary = inventory_entry(2111, named_identity(Some("target-main"), None));
    let alias = inventory_entry(2113, primary.identity.clone());
    let secondary = inventory_entry(2129, named_identity(Some("target-secondary"), None));
    let inventory = [primary.clone(), alias.clone(), secondary.clone()];
    assert_eq!(
        SerializedSelector::Primary.mirror_target_id(&secondary, &inventory),
        Some("primary".into())
    );
    assert_eq!(
        SerializedSelector::Primary.mirror_target_id(&primary, &inventory),
        None
    );
    assert_eq!(
        live(2113).mirror_target_id(&primary, &inventory),
        Some("primary".into())
    );
    assert_eq!(
        identity_selector(&primary.identity).mirror_target_id(&primary, &inventory),
        Some("primary".into())
    );
    assert_eq!(
        live(2111).mirror_target_id(&secondary, &inventory),
        Some("primary".into())
    );
    assert_eq!(live(2129).mirror_target_id(&secondary, &inventory), None);
    assert_eq!(
        identity_selector(&secondary.identity).mirror_target_id(&secondary, &inventory),
        None
    );
    assert_eq!(live(9999).mirror_target_id(&secondary, &inventory), None);
    assert_eq!(
        identity_selector(&named_identity(Some("unknown-target"), None))
            .mirror_target_id(&secondary, &inventory),
        None
    );
    assert_eq!(
        SerializedSelector::Primary.mirror_target_id(&secondary, &[]),
        None
    );
    assert_eq!(
        identity_selector(&primary.identity).mirror_target_id(&primary, &[primary.clone()]),
        None
    );
    assert_eq!(live(2113).mirror_target_id(&primary, &[]), None);

    let mut target = hardware_identity(Some(59), Some(79), Some(101), Some(5));
    target.uuid = Some("best-but-later".into());
    let own = inventory_entry(2131, target.clone());
    let weak_identity = hardware_identity(Some(59), Some(79), None, Some(5));
    let weak = inventory_entry(2137, weak_identity.clone());
    let stronger = inventory_entry(2141, target.clone());
    let inventory = [primary, own.clone(), weak.clone(), stronger];
    let before = inventory.clone();
    assert_eq!(
        identity_selector(&target).mirror_target_id(&own, &inventory),
        Some(identity_selector(&weak_identity).id())
    );
    assert_eq!(inventory, before);
    let mut contradictory = weak.clone();
    contradictory.desc.identity = named_identity(Some("descriptor-not-target"), None);
    assert_eq!(
        identity_selector(&target)
            .mirror_target_id(&own, &[inventory[0].clone(), own.clone(), contradictory]),
        Some(identity_selector(&weak_identity).id())
    );
}

#[test]
fn d12_real_rate_helpers_store_choices_and_use_each_supplied_refresh() {
    let cases = [
        (120, None, 60),
        (120, Some(0), 1),
        (120, Some(1), 1),
        (120, Some(60), 60),
        (120, Some(90), 90),
        (120, Some(999), 120),
        (60, None, 60),
        (60, Some(90), 60),
        (30, None, 30),
        (30, Some(90), 30),
        (0, None, 1),
        (0, Some(0), 1),
        (0, Some(90), 1),
    ];
    for (refresh, choice, expected) in cases {
        assert_eq!(resolve_frame_rate(choice, refresh), expected);
        let settings = MonitorSettingsCfg {
            frame_rate: choice,
            ..MonitorSettingsCfg::default()
        };
        let render = MonitorRender {
            frame_rate: choice,
            ..MonitorRender::default()
        };
        assert_eq!(settings.fps_on(refresh), expected);
        assert_eq!(render.fps_on(refresh), expected);
    }
    for (refresh, request, expected) in [
        (120, 0, Some(1)),
        (120, 1, Some(1)),
        (120, 60, None),
        (120, 90, Some(90)),
        (120, 999, Some(120)),
        (60, 0, Some(1)),
        (60, 1, Some(1)),
        (60, 60, None),
        (60, 90, None),
        (30, 30, None),
        (30, 90, None),
        (0, 0, None),
        (0, 1, None),
        (0, 90, None),
    ] {
        assert_eq!(stored_frame_rate(request, refresh), expected);
    }
    // These are configuration value observations, not actor/reporting/presenter rows.
    let preferred = MonitorSettingsCfg {
        frame_rate: Some(90),
        ..MonitorSettingsCfg::default()
    };
    assert_eq!(preferred.fps_on(120), 90);
    assert_eq!(preferred.fps_on(60), 60);
    assert_eq!(preferred.frame_rate, Some(90));
}

#[test]
fn d06_live_primary_aliases_remove_none_rows_and_carry_first_present_literal_wallpaper() {
    let primary = inventory_entry(2221, named_identity(Some("carry-main"), None));
    let aliases = [
        primary.clone(),
        inventory_entry(2227, primary.identity.clone()),
        inventory_entry(2237, primary.identity.clone()),
    ];
    let stable = identity_selector(&primary.identity);
    let mut empty_alias = edge(live(2221), live(9991));
    empty_alias.enabled = false;
    let mut first_present = edge(live(2227), live(9997));
    first_present.mode = "Mirror".into();
    first_present.enabled = false;
    first_present.wallpaper = Some(String::new());
    let mut config = configuration(vec![
        empty_alias,
        first_present,
        saved(live(2237), Some("later-live-art")),
        saved(stable.clone(), Some("stable-must-not-win")),
        saved(SerializedSelector::Primary, None),
    ]);
    config.monitor_settings = vec![tuned_settings(live(2221), 37, 0.375)];
    let mut expected = config.clone();
    expected.primary_display = Some(stable.clone());
    expected.monitors = vec![
        saved(SerializedSelector::Primary, Some("")),
        saved(stable, Some("stable-must-not-win")),
    ];
    assert!(config.sync_known_monitors(&aliases));
    assert_eq!(config, expected);
    assert!(!config.sync_known_monitors(&aliases));
    assert_eq!(config, expected);
}

#[test]
fn d02_serial_stable_without_uuid_renames_assignment_settings_and_references() {
    let mut previous = hardware_identity(Some(0), Some(113), Some(0), Some(2));
    previous.name = Some("Serial before".into());
    let mut current = previous.clone();
    current.unit_number = Some(5);
    current.name = Some("Serial now".into());
    assert_eq!(previous.match_score(&current), Some(3));
    assert!(previous.has_stable_match(&current));
    let mut assignment = saved(identity_selector(&previous), Some("serial-art"));
    assignment.enabled = false;
    let mut config = configuration(vec![
        saved(SerializedSelector::Primary, Some("serial-seed")),
        assignment.clone(),
        edge(live(2273), identity_selector(&previous)),
    ]);
    config.monitor_settings = vec![tuned_settings(identity_selector(&previous), 41, 0.625)];
    let mut expected = config.clone();
    expected.primary_display = Some(identity_selector(&named_identity(
        Some("serial-primary"),
        None,
    )));
    expected.monitors[1].selector = identity_selector(&current);
    expected.monitors[2].mirror_target = Some(identity_selector(&current));
    expected.monitor_settings[0].selector = identity_selector(&current);
    let inventory = [
        inventory_entry(2267, named_identity(Some("serial-primary"), None)),
        inventory_entry(2269, current),
    ];
    assert!(config.sync_known_monitors(&inventory));
    assert_eq!(config, expected);
    assert!(!config.sync_known_monitors(&inventory));
    assert_eq!(config, expected);
}

#[test]
fn d01_missing_hardware_evidence_never_becomes_a_physical_match() {
    for identity in [
        hardware_identity(None, Some(19), Some(0), Some(0)),
        hardware_identity(Some(13), None, Some(0), Some(0)),
        hardware_identity(Some(13), Some(19), None, None),
    ] {
        assert_eq!(identity.match_score(&identity), None);
        assert!(!identity.has_stable_match(&identity));
        assert!(!identity.same_physical_identity(&identity));
        assert!(!identity.has_stable_identity());
    }
}
