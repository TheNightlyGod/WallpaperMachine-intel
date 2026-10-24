//! When macOS makes another display the main one, the `primary` block hands
//! its wallpaper back to the display it described and takes over the new main
//! display's own choice.
use wallpaper_core::{DisplayDesc, DisplayIdentity, DisplaySnapshotEntry};

use super::DisplaySnapshotExt;
use crate::config::{AppConfig, ConfigStore, MonitorCfg, SerializedSelector};

fn display(display_id: u32, uuid: Option<&str>, x: i32) -> DisplaySnapshotEntry {
    let identity = DisplayIdentity {
        uuid: uuid.map(str::to_owned),
        vendor_id: uuid.map(|_| 1552),
        model_id: uuid.map(|_| 42_000 + display_id),
        serial_number: uuid.map(|_| 5_000 + display_id),
        unit_number: Some(display_id),
        name: Some(format!("Monitor {display_id}")),
    };
    DisplaySnapshotEntry {
        desc: DisplayDesc::with_identity(display_id, identity.clone(), x, 0, 2560, 1440, 2.0),
        identity,
        handle: None,
        accepts_pointer_input: false,
        paused: false,
        window_active: true,
        assignment: None,
    }
}

fn studio() -> DisplaySnapshotEntry {
    display(2, Some("studio-display"), 0)
}

fn ultrafine() -> DisplaySnapshotEntry {
    display(4, Some("ultrafine"), 2560)
}

fn projector() -> DisplaySnapshotEntry {
    display(9, Some("projector"), -1920)
}

fn selector(entry: &DisplaySnapshotEntry) -> SerializedSelector {
    entry
        .stable_identity_selector()
        .expect("a display with a stable identity")
}

fn block(selector: SerializedSelector, wallpaper: Option<&str>) -> MonitorCfg {
    MonitorCfg {
        selector,
        wallpaper: wallpaper.map(str::to_owned),
        ..MonitorCfg::default()
    }
}

fn block_for<'a>(config: &'a AppConfig, wanted: &SerializedSelector) -> Option<&'a MonitorCfg> {
    config
        .monitors
        .iter()
        .find(|block| &block.selector == wanted)
}

fn wallpaper_of(config: &AppConfig, wanted: &SerializedSelector) -> Option<String> {
    block_for(config, wanted).and_then(|block| block.wallpaper.clone())
}

/// The Studio Display was main and showed `aurora`; the UltraFine has a block
/// of its own.
fn studio_was_main(ultrafine_block: MonitorCfg) -> AppConfig {
    let mut config = AppConfig::default();
    config.monitors = vec![
        block(SerializedSelector::Primary, Some("aurora")),
        ultrafine_block,
    ];
    config.primary_display = Some(selector(&studio()));
    config
}

#[test]
fn sync_records_the_display_the_primary_block_describes() {
    let mut config = AppConfig::default();
    assert_eq!(config.primary_display, None);

    assert!(config.sync_known_monitors(&[studio(), ultrafine()]));
    assert_eq!(config.primary_display, Some(selector(&studio())));
    assert!(
        !config.sync_known_monitors(&[studio(), ultrafine()]),
        "nothing changes twice"
    );

    // A main display without a stable identity is not recorded.
    let anonymous = display(11, None, 0);
    assert!(config.sync_known_monitors(&[anonymous]));
    assert_eq!(config.primary_display, None);
}

#[test]
fn a_new_main_display_hands_the_wallpaper_back_and_shows_its_own() {
    let mut config = studio_was_main(block(selector(&ultrafine()), Some("basalt")));

    assert!(config.sync_known_monitors(&[ultrafine(), studio()]));

    assert_eq!(
        wallpaper_of(&config, &selector(&studio())).as_deref(),
        Some("aurora")
    );
    assert_eq!(
        wallpaper_of(&config, &SerializedSelector::Primary).as_deref(),
        Some("basalt")
    );
    assert_eq!(config.primary_display, Some(selector(&ultrafine())));

    // And back again.
    assert!(config.sync_known_monitors(&[studio(), ultrafine()]));
    assert_eq!(
        wallpaper_of(&config, &SerializedSelector::Primary).as_deref(),
        Some("aurora")
    );
    assert_eq!(
        wallpaper_of(&config, &selector(&ultrafine())).as_deref(),
        Some("basalt")
    );
    assert_eq!(config.primary_display, Some(selector(&studio())));
}

#[test]
fn the_previous_main_displays_block_is_created_when_it_has_none() {
    let mut config = studio_was_main(block(selector(&ultrafine()), Some("basalt")));
    assert!(block_for(&config, &selector(&studio())).is_none());

    config.sync_known_monitors(&[ultrafine(), studio()]);

    let created = block_for(&config, &selector(&studio())).expect("the Studio Display's block");
    assert_eq!(created.wallpaper.as_deref(), Some("aurora"));
    assert!(created.enabled);
    assert_eq!(created.mode, "independent");
}

#[test]
fn the_previous_main_displays_block_is_written_back_while_it_is_disconnected() {
    let mut config = studio_was_main(block(selector(&ultrafine()), Some("basalt")));

    // The lid closes: only the UltraFine is left, and it is main.
    config.sync_known_monitors(&[ultrafine()]);

    assert_eq!(
        wallpaper_of(&config, &selector(&studio())).as_deref(),
        Some("aurora")
    );
    assert_eq!(
        wallpaper_of(&config, &SerializedSelector::Primary).as_deref(),
        Some("basalt")
    );
}

#[test]
fn the_previous_main_display_keeps_what_it_showed_over_an_old_block() {
    let mut config = studio_was_main(block(selector(&ultrafine()), Some("basalt")));
    let mut old = block(selector(&studio()), Some("faded"));
    old.enabled = false;
    config.monitors.push(old);

    config.sync_known_monitors(&[ultrafine(), studio()]);

    let written = block_for(&config, &selector(&studio())).expect("the Studio Display's block");
    assert_eq!(written.wallpaper.as_deref(), Some("aurora"));
    assert!(
        written.enabled,
        "it keeps showing the wallpaper it showed as main"
    );
}

#[test]
fn a_new_main_display_that_is_switched_off_shows_nothing() {
    let mut off = block(selector(&ultrafine()), Some("basalt"));
    off.enabled = false;
    let mut config = studio_was_main(off);

    config.sync_known_monitors(&[ultrafine(), studio()]);

    assert_eq!(wallpaper_of(&config, &SerializedSelector::Primary), None);
    assert_eq!(
        wallpaper_of(&config, &selector(&studio())).as_deref(),
        Some("aurora")
    );
    let primary = block_for(&config, &SerializedSelector::Primary).expect("primary block");
    assert!(primary.enabled, "the role itself stays enabled");
}

#[test]
fn a_new_main_display_that_mirrors_shows_nothing_of_its_own() {
    let mirroring = MonitorCfg {
        selector: selector(&ultrafine()),
        mode: "mirror".into(),
        mirror_target: Some(SerializedSelector::Primary),
        wallpaper: Some("basalt".into()),
        ..MonitorCfg::default()
    };
    let mut config = studio_was_main(mirroring);

    config.sync_known_monitors(&[ultrafine(), studio()]);

    assert_eq!(wallpaper_of(&config, &SerializedSelector::Primary), None);
    assert_eq!(
        wallpaper_of(&config, &selector(&studio())).as_deref(),
        Some("aurora")
    );
}

#[test]
fn a_never_configured_main_display_starts_with_the_previous_main_displays_wallpaper() {
    let mut config = studio_was_main(block(selector(&ultrafine()), Some("basalt")));

    config.sync_known_monitors(&[projector(), studio(), ultrafine()]);

    assert_eq!(
        wallpaper_of(&config, &SerializedSelector::Primary).as_deref(),
        Some("aurora")
    );
    assert_eq!(
        wallpaper_of(&config, &selector(&studio())).as_deref(),
        Some("aurora")
    );
    assert_eq!(
        wallpaper_of(&config, &selector(&ultrafine())).as_deref(),
        Some("basalt")
    );
    assert!(
        block_for(&config, &selector(&projector())).is_none(),
        "the role describes it"
    );
    assert_eq!(config.primary_display, Some(selector(&projector())));
}

#[test]
fn an_older_configuration_without_a_record_hands_nothing_over_the_first_time() {
    let text = r#"
schema_version = 1

[[monitors]]
kind = "primary"
wallpaper = "aurora"

[[monitors]]
kind = "identity"
uuid = "ultrafine"
vendor_id = 1552
model_id = 42004
serial_number = 5004
unit_number = 4
name = "Monitor 4"
wallpaper = "basalt"
"#;
    let home = tempfile::tempdir().expect("temporary home");
    std::fs::write(home.path().join("config.toml"), text).expect("older file");
    let mut config = ConfigStore::open(home.path()).load().expect("load").config;
    assert_eq!(config.primary_display, None);

    config.sync_known_monitors(&[ultrafine(), studio()]);

    // Which display the role described is unknown, so nothing moves.
    assert_eq!(
        wallpaper_of(&config, &SerializedSelector::Primary).as_deref(),
        Some("aurora")
    );
    assert_eq!(
        wallpaper_of(&config, &selector(&ultrafine())).as_deref(),
        Some("basalt")
    );
    assert_eq!(config.primary_display, Some(selector(&ultrafine())));
}

#[test]
fn the_record_is_saved_and_loaded() {
    let home = tempfile::tempdir().expect("temporary home");
    let store = ConfigStore::open(home.path());
    let mut config = AppConfig::default();
    config.sync_known_monitors(&[studio(), ultrafine()]);
    store.save_app_config(&config).expect("save");
    assert_eq!(store.load().expect("load").config, config);

    let mut unrecorded = AppConfig::default();
    unrecorded.sync_known_monitors(&[display(11, None, 0)]);
    store.save_app_config(&unrecorded).expect("save");
    let text = std::fs::read_to_string(home.path().join("config.toml")).expect("saved file");
    assert!(
        !text.contains("primary_display"),
        "nothing is written without a record:\n{text}"
    );
    assert_eq!(store.load().expect("load").config, unrecorded);
}

#[test]
fn an_empty_primary_block_takes_only_a_wallpaper_its_displays_block_shows() {
    let mut showing = AppConfig::default();
    showing.monitors = vec![
        block(SerializedSelector::Primary, None),
        block(selector(&studio()), Some("aurora")),
    ];
    showing.sync_known_monitors(&[studio(), ultrafine()]);
    assert_eq!(
        wallpaper_of(&showing, &SerializedSelector::Primary).as_deref(),
        Some("aurora")
    );

    let mut off = AppConfig::default();
    let mut switched_off = block(selector(&studio()), Some("aurora"));
    switched_off.enabled = false;
    off.monitors = vec![block(SerializedSelector::Primary, None), switched_off];
    off.sync_known_monitors(&[studio(), ultrafine()]);
    assert_eq!(wallpaper_of(&off, &SerializedSelector::Primary), None);

    let mut mirroring = AppConfig::default();
    mirroring.monitors = vec![
        block(SerializedSelector::Primary, None),
        MonitorCfg {
            selector: selector(&studio()),
            mode: "mirror".into(),
            mirror_target: Some(selector(&ultrafine())),
            wallpaper: Some("aurora".into()),
            ..MonitorCfg::default()
        },
    ];
    mirroring.sync_known_monitors(&[studio(), ultrafine()]);
    assert_eq!(wallpaper_of(&mirroring, &SerializedSelector::Primary), None);
}
