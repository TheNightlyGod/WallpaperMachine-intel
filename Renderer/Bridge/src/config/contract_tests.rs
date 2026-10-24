use std::fs;
use std::path::{Path, PathBuf};

use serde_json::{Value, json};
use tempfile::TempDir;
use wallpaper_core::project::ScalingMode;
use wallpaper_core::{DisplayIdentity, DisplaySelector};

use super::app::{DiagnosticsCfg, ExperimentalCfg};
use super::*;
use crate::project::PropertyValue;
use crate::{BridgeError, BridgeErrorKind};

fn isolated_store() -> (TempDir, ConfigStore) {
    let temporary = tempfile::Builder::new()
        .prefix("wm-config-contract-")
        .tempdir_in(std::env::temp_dir())
        .expect("create parent-selected system-temp root");
    let store = ConfigStore::open(temporary.path().join("store"));
    (temporary, store)
}

fn put(path: &Path, bytes: impl AsRef<[u8]>) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, bytes).unwrap();
}

fn app_path(store: &ConfigStore) -> PathBuf {
    store.root().join("config.toml")
}
fn wallpaper_path(store: &ConfigStore, id: &str) -> PathBuf {
    store.root().join("wallpapers").join(format!("{id}.json"))
}

fn app_output(store: &ConfigStore) -> toml::Value {
    toml::from_str(&fs::read_to_string(app_path(store)).unwrap()).unwrap()
}

fn wallpaper_output(store: &ConfigStore, id: &str) -> Value {
    serde_json::from_slice(&fs::read(wallpaper_path(store, id)).unwrap()).unwrap()
}

fn assert_kind<T: std::fmt::Debug>(result: Result<T, BridgeError>, kind: BridgeErrorKind) {
    assert_eq!(result.unwrap_err().kind(), kind);
}

fn assert_default_app(config: &AppConfig) {
    assert_eq!(config.schema_version, 1);
    assert_eq!(config.general.last_selected_wallpaper, None);
    assert_eq!(config.power.on_battery, BatteryModeCfg::KeepRunning);
    assert_eq!(config.power.legacy_pause_on_battery_power, None);
    assert!(!config.power.on_battery_explicit);
    assert_eq!(
        config.ui.selector_window,
        WindowGeom {
            x: 200,
            y: 200,
            width: 1100,
            height: 720
        }
    );
    assert_eq!(
        config.ui.settings_window,
        WindowGeom {
            x: 520,
            y: 260,
            width: 520,
            height: 440
        }
    );
    assert_eq!(
        config.ui.filter,
        FilterCfg {
            scene: true,
            video: true,
            web: true,
            unknown: true
        }
    );
    assert!(!config.experimental.scene_video_plane_sampling);
    assert_eq!(config.quality.render_scale, 1.0);
    assert_eq!(config.quality.frame_rate_cap, None);
    assert_eq!(config.quality.legacy_battery_profile_enabled, None);
    assert_eq!(config.quality.battery.render_scale, 0.75);
    assert_eq!(config.quality.battery.target_fps, 30);
    assert!(config.quality.scene_optimization_enabled);
    assert!(!config.quality.scene_on_demand_enabled);
    assert_eq!(config.quality.scene_resolution, SceneResolutionCfg::Display);
    assert!(config.monitors.is_empty());
    assert!(config.monitor_settings.is_empty());
    assert!(!config.diagnostics.verbose_logging);
}

fn assert_default_wallpaper(config: &WallpaperConfig, id: &str, kind: &str) {
    assert_eq!(config.schema_version, 1);
    assert_eq!(config.workshop_id, id);
    assert_eq!(config.r#type, kind);
    assert_eq!(config.audio.volume, 1.0);
    assert!(config.audio.response_enabled);
    assert!(!config.audio.muted);
    assert!(config.media_integration_enabled);
    assert!(config.monitors.is_empty());
    assert!(config.property_overrides.is_empty());
}

fn selectors() -> Vec<SerializedSelector> {
    vec![
        SerializedSelector::Primary,
        SerializedSelector::Identity {
            uuid: Some("unit-Ω".to_owned()),
            vendor_id: Some(21),
            model_id: Some(0),
            serial_number: Some(900),
            unit_number: Some(u32::MAX),
            name: Some("Side \"A\"".to_owned()),
        },
        SerializedSelector::LiveDisplayId { display_id: 704 },
    ]
}

// C01: defaults are asserted against literals, rather than only another Default call.
#[test]
fn missing_files_and_absent_sections_have_distinct_default_identities() {
    let (_temporary, store) = isolated_store();
    assert!(!store.root().exists());
    assert_eq!(store.root(), store.clone().root());
    assert_eq!(store.flush().unwrap(), 0);
    let loaded = store.load().unwrap();
    assert_default_app(&loaded.config);
    assert!(loaded.backup_reported.is_empty());
    assert_default_wallpaper(
        &store.load_wallpaper("fresh-29").unwrap(),
        "fresh-29",
        "scene",
    );
    assert!(!store.root().exists());

    for raw in [
        "",
        "[general]\n[power]\n[ui]\n[experimental]\n[quality]\n[quality.battery]\n[diagnostics]\n",
    ] {
        let config: AppConfig = toml::from_str(raw).unwrap();
        assert_default_app(&config);
    }
    put(&wallpaper_path(&store, "fresh-29"), b"{}");
    let loaded = store.load_wallpaper("fresh-29").unwrap();
    assert_default_wallpaper(&loaded, "", "");
    assert_eq!(fs::read(wallpaper_path(&store, "fresh-29")).unwrap(), b"{}");
    assert_default_wallpaper(&WallpaperConfig::new_for("new", "web"), "new", "web");
    let opted_out: WallpaperConfig =
        serde_json::from_value(json!({"media_integration_enabled": false})).unwrap();
    assert!(!opted_out.media_integration_enabled);
    let nested: WallpaperConfig =
        serde_json::from_value(json!({"audio":{},"monitors":[{}]})).unwrap();
    assert_eq!(nested.audio.volume, 1.0);
    assert!(nested.audio.response_enabled);
    assert!(!nested.audio.muted);
    let monitor = &nested.monitors[0];
    assert_eq!(monitor.selector, SerializedSelector::Primary);
    assert_eq!(monitor.scaling_mode, "fill");
    assert_eq!(monitor.scaling_factor, 1.0);
    assert_eq!(monitor.frame_rate, None);
    assert_eq!(
        monitor.framing,
        FramingCfg {
            pan_x: 0.5,
            pan_y: 0.5
        }
    );
    let app: AppConfig =
        toml::from_str("[[monitors]]\nkind='primary'\n[[monitor_settings]]\nkind='primary'\n")
            .unwrap();
    let assignment = &app.monitors[0];
    assert_eq!(assignment.selector, SerializedSelector::Primary);
    assert!(assignment.enabled);
    assert_eq!(assignment.mode, "independent");
    assert_eq!(assignment.wallpaper, None);
    assert_eq!(assignment.mirror_target, None);
    let settings = &app.monitor_settings[0];
    assert_eq!(settings.selector, SerializedSelector::Primary);
    assert_eq!(settings.scaling_mode, "fill");
    assert_eq!(settings.scaling_factor, 1.0);
    assert_eq!(settings.frame_rate, None);
    assert_eq!(settings.volume, 1.0);
    assert!(!settings.muted);
}

#[test]
fn present_geometry_and_filter_tables_require_every_member() {
    for raw in [
        "[ui.selector_window]\n",
        "[ui.settings_window]\nx=1\ny=2\nwidth=3\n",
        "[ui.filter]\n",
        "[ui.filter]\nscene=true\nvideo=false\nweb=true\n",
        "[ui.selector_window]\nx=1\ny=2\nwidth=-1\nheight=4\n",
    ] {
        assert!(toml::from_str::<AppConfig>(raw).is_err(), "{raw}");
        assert_kind(
            ConfigStore::validate_app_config_text(raw),
            BridgeErrorKind::Config,
        );
    }
    let raw = "[ui.selector_window]\nx=-40\ny=-12\nwidth=0\nheight=0\n";
    let config: AppConfig = toml::from_str(raw).unwrap();
    assert_eq!(
        config.ui.selector_window,
        WindowGeom {
            x: -40,
            y: -12,
            width: 0,
            height: 0
        }
    );
    assert_eq!(config.ui.settings_window.width, 520);
}

// C02, C13, C16: complete represented records, raw preference preservation, immediate saves.
#[test]
fn all_app_fields_and_selector_variants_round_trip_without_normalizing_preferences() {
    let (_temporary, store) = isolated_store();
    for mode in [
        BatteryModeCfg::KeepRunning,
        BatteryModeCfg::ReducedQuality,
        BatteryModeCfg::Pause,
    ] {
        for resolution in [SceneResolutionCfg::Canvas, SceneResolutionCfg::Display] {
            for optional in [false, true] {
                let mut expected = AppConfig {
                    schema_version: 0,
                    primary_display: None,
                    general: GeneralCfg {
                        last_selected_wallpaper: optional.then(|| "item-52".to_owned()),
                    },
                    power: PowerCfg {
                        on_battery: mode,
                        ..PowerCfg::default()
                    },
                    ui: UiCfg {
                        selector_window: WindowGeom {
                            x: -721,
                            y: 9,
                            width: 17,
                            height: 2,
                        },
                        settings_window: WindowGeom {
                            x: 61,
                            y: -88,
                            width: 0,
                            height: 19,
                        },
                        filter: FilterCfg {
                            scene: false,
                            video: true,
                            web: false,
                            unknown: false,
                        },
                    },
                    experimental: ExperimentalCfg {
                        scene_video_plane_sampling: true,
                    },
                    quality: QualityCfg {
                        render_scale: 1.75,
                        frame_rate_cap: optional.then_some(0),
                        legacy_battery_profile_enabled: None,
                        battery: QualityProfileCfg {
                            render_scale: -0.5,
                            target_fps: 0,
                        },
                        scene_optimization_enabled: false,
                        scene_on_demand_enabled: true,
                        scene_resolution: resolution,
                    },
                    monitors: Vec::new(),
                    monitor_settings: Vec::new(),
                    diagnostics: DiagnosticsCfg {
                        verbose_logging: true,
                    },
                };
                for (index, selector) in selectors().into_iter().enumerate() {
                    expected.monitors.push(MonitorCfg {
                        selector: selector.clone(),
                        enabled: index != 1,
                        mode: if index == 0 {
                            "independent"
                        } else if index == 1 {
                            "mirror"
                        } else {
                            "custom-mode"
                        }
                        .to_owned(),
                        wallpaper: optional.then(|| format!("asset-{index}")),
                        mirror_target: optional.then(|| selectors()[(index + 1) % 3].clone()),
                    });
                    expected.monitor_settings.push(MonitorSettingsCfg {
                        selector,
                        scaling_mode: "FiT-custom".to_owned(),
                        scaling_factor: -2.5,
                        frame_rate: optional.then_some(0),
                        volume: 1.75,
                        muted: true,
                    });
                }
                store.save_app_config(&expected).unwrap();
                assert!(app_path(&store).is_file());
                let output = app_output(&store);
                assert_eq!(output["schema_version"].as_integer(), Some(0));
                assert_eq!(
                    output["general"].get("last_selected_wallpaper").is_some(),
                    optional
                );
                assert_eq!(output["quality"].get("frame_rate_cap").is_some(), optional);
                assert!(output["power"].get("pause_on_battery_power").is_none());
                assert!(output["power"].get("on_battery_explicit").is_none());
                assert!(output["quality"].get("battery_profile_enabled").is_none());
                for row in output["monitors"].as_array().unwrap() {
                    assert!(row.get("kind").is_some());
                    assert!(row.get("selector").is_none());
                    assert_eq!(row.get("wallpaper").is_some(), optional);
                    assert_eq!(row.get("mirror_target").is_some(), optional);
                }
                for row in output["monitor_settings"].as_array().unwrap() {
                    assert_eq!(row.get("frame_rate").is_some(), optional);
                    assert!(row.get("target_fps").is_none());
                    assert!(row.get("framing").is_none());
                }
                let loaded = store.load().unwrap();
                assert!(loaded.backup_reported.is_empty());
                assert_eq!(loaded.config, expected);
                assert!(loaded.config.power.on_battery_explicit);
                assert_eq!(store.flush().unwrap(), 0);
            }
        }
    }
}

#[test]
fn wallpaper_fields_round_trip_including_compound_overrides_and_optional_omission() {
    let (_temporary, store) = isolated_store();
    for optional in [false, true] {
        let mut expected = WallpaperConfig::new_for("local-83", "unrestricted-kind");
        expected.schema_version = 0;
        expected.audio = AudioCfg {
            volume: -0.25,
            response_enabled: false,
            muted: true,
        };
        expected.media_integration_enabled = true;
        expected.property_overrides = [
            ("unset".to_owned(), Value::Null),
            ("truth".to_owned(), json!(false)),
            ("amount".to_owned(), json!(9.25)),
            ("text".to_owned(), json!("a\\b\n")),
            ("items".to_owned(), json!([1, null, {"deep": true}])),
            ("object".to_owned(), json!({"value": [false, 2]})),
        ]
        .into_iter()
        .collect();
        for selector in selectors() {
            expected.monitors.push(MonitorRender {
                selector,
                scaling_mode: "StReTcH".to_owned(),
                scaling_factor: -4.0,
                frame_rate: optional.then_some(60),
                framing: if optional {
                    FramingCfg {
                        pan_x: 0.125,
                        pan_y: 0.875,
                    }
                } else {
                    FramingCfg::default()
                },
            });
        }
        store.save_wallpaper(&expected).unwrap();
        assert!(wallpaper_path(&store, "local-83").is_file());
        let output = wallpaper_output(&store, "local-83");
        assert_eq!(output["schema_version"], 0);
        assert_eq!(output["type"], "unrestricted-kind");
        for monitor in output["monitors"].as_array().unwrap() {
            assert!(monitor.get("selector").is_some());
            assert!(monitor.get("kind").is_none());
            assert_eq!(monitor.get("frame_rate").is_some(), optional);
            assert_eq!(monitor.get("framing").is_some(), optional);
            assert!(monitor.get("fps").is_none());
            assert!(monitor.get("scaling_mode").is_some());
            assert!(monitor.get("scaling_factor").is_some());
        }
        assert_eq!(store.load_wallpaper("local-83").unwrap(), expected);
        assert_eq!(store.flush().unwrap(), 0);
    }
    put(
        &wallpaper_path(&store, "requested"),
        br#"{"workshop_id":"different","type":"video"}"#,
    );
    let loaded = store.load_wallpaper("requested").unwrap();
    assert_eq!(loaded.workshop_id, "different");
    assert_eq!(loaded.r#type, "video");
}

// C03: unknown typed-format fields disappear; represented override data does not.
#[test]
fn unknown_fields_do_not_control_defaults_or_survive_typed_saves() {
    let (_temporary, store) = isolated_store();
    let raw = r#"
scene_renderer = { arbitrary = [1, 2] }
video_backend = ["unused"]
native_metal_default_applied = "ignored"
native_video_default_applied = 27
private_marker = true
[general]
last_selected_wallpaper = "retained"
extra = { flag = false }
[experimental]
scene_video_plane_sampling = true
native_video_backend = false
content_pacing = [3]
shared_video_decode = { anything = "valid" }
[quality]
render_scale = 0.5
unrecognized = "gone"
[unrecognized_table]
x = 1
"#;
    put(&app_path(&store), raw);
    let loaded = store.load().unwrap();
    assert_eq!(
        loaded.config.general.last_selected_wallpaper.as_deref(),
        Some("retained")
    );
    assert!(loaded.config.experimental.scene_video_plane_sampling);
    assert_eq!(loaded.config.quality.render_scale, 0.5);
    assert_eq!(loaded.config.power.on_battery, BatteryModeCfg::KeepRunning);
    assert_eq!(fs::read_to_string(app_path(&store)).unwrap(), raw);
    store.save_app_config(&loaded.config).unwrap();
    let output = app_output(&store);
    for key in [
        "scene_renderer",
        "video_backend",
        "native_metal_default_applied",
        "native_video_default_applied",
        "private_marker",
        "unrecognized_table",
    ] {
        assert!(output.get(key).is_none(), "{key}");
    }
    for key in [
        "native_video_backend",
        "content_pacing",
        "shared_video_decode",
    ] {
        assert!(output["experimental"].get(key).is_none());
    }
    assert!(output["general"].get("extra").is_none());
    assert!(output["quality"].get("unrecognized").is_none());
    assert_eq!(
        output["general"]["last_selected_wallpaper"].as_str(),
        Some("retained")
    );

    let raw = json!({
        "workshop_id":"unknown-fields", "type":"scene", "marker":{"x":1},
        "audio":{"volume":0.25,"discard":[1,2]},
        "monitors":[{"scaling_factor":2.0,"discard":true}],
        "property_overrides":{"null":null,"nested":{"array":[false,"x"]}}
    });
    put(
        &wallpaper_path(&store, "unknown-fields"),
        serde_json::to_vec(&raw).unwrap(),
    );
    let loaded = store.load_wallpaper("unknown-fields").unwrap();
    assert_eq!(loaded.audio.volume, 0.25);
    assert_eq!(loaded.monitors[0].scaling_factor, 2.0);
    store.save_wallpaper(&loaded).unwrap();
    let output = wallpaper_output(&store, "unknown-fields");
    assert!(output.get("marker").is_none());
    assert!(output["audio"].get("discard").is_none());
    assert!(output["monitors"][0].get("discard").is_none());
    assert_eq!(output["property_overrides"], raw["property_overrides"]);
}

// C04: every legacy presence/value pair crossed with absent and every explicit mode.
#[test]
fn migration_tracks_explicit_battery_mode_and_consumes_both_legacy_options() {
    let (_temporary, store) = isolated_store();
    let explicit_modes = [
        None,
        Some(("keep_running", BatteryModeCfg::KeepRunning)),
        Some(("reduced_quality", BatteryModeCfg::ReducedQuality)),
        Some(("pause", BatteryModeCfg::Pause)),
    ];
    for pause in [None, Some(false), Some(true)] {
        for profile in [None, Some(false), Some(true)] {
            for explicit in explicit_modes {
                let mut raw = "[power]\n".to_owned();
                if let Some((name, _)) = explicit {
                    raw.push_str(&format!("on_battery = '{name}'\n"));
                }
                if let Some(value) = pause {
                    raw.push_str(&format!("pause_on_battery_power = {value}\n"));
                }
                raw.push_str("[quality]\n");
                if let Some(value) = profile {
                    raw.push_str(&format!("battery_profile_enabled = {value}\n"));
                }
                let direct: AppConfig = toml::from_str(&raw).unwrap();
                assert_eq!(
                    direct.power.on_battery,
                    explicit.map_or(BatteryModeCfg::KeepRunning, |(_, mode)| mode)
                );
                assert_eq!(direct.power.on_battery_explicit, explicit.is_some());
                assert_eq!(direct.power.legacy_pause_on_battery_power, pause);
                assert_eq!(direct.quality.legacy_battery_profile_enabled, profile);
                ConfigStore::validate_app_config_text(&raw).unwrap();
                let expected = explicit.map(|(_, mode)| mode).unwrap_or_else(|| {
                    if pause == Some(true) {
                        BatteryModeCfg::Pause
                    } else if profile == Some(true) {
                        BatteryModeCfg::ReducedQuality
                    } else {
                        BatteryModeCfg::KeepRunning
                    }
                });
                let mut migrated = direct.clone();
                migrated.migrate_legacy_keys();
                assert_eq!(migrated.power.on_battery, expected);
                assert_eq!(migrated.power.legacy_pause_on_battery_power, None);
                assert_eq!(migrated.quality.legacy_battery_profile_enabled, None);
                migrated.migrate_legacy_keys();
                assert_eq!(migrated.power.on_battery, expected);
                put(&app_path(&store), &raw);
                let loaded = store.load().unwrap();
                assert_eq!(loaded.config, migrated);
                assert!(loaded.backup_reported.is_empty());
                assert_eq!(fs::read_to_string(app_path(&store)).unwrap(), raw);
                // A direct save omits compatibility fields but does not itself migrate.
                store.save_app_config(&direct).unwrap();
                let output = app_output(&store);
                assert!(output["power"].get("pause_on_battery_power").is_none());
                assert!(output["quality"].get("battery_profile_enabled").is_none());
                assert_eq!(
                    store.load().unwrap().config.power.on_battery,
                    direct.power.on_battery
                );
            }
        }
    }
    for mode in [
        BatteryModeCfg::KeepRunning,
        BatteryModeCfg::ReducedQuality,
        BatteryModeCfg::Pause,
    ] {
        let mut existing = AppConfig::default();
        existing.power.on_battery = mode;
        existing.power.legacy_pause_on_battery_power = Some(false);
        existing.quality.legacy_battery_profile_enabled = Some(false);
        existing.migrate_legacy_keys();
        assert_eq!(existing.power.on_battery, mode);
        assert_eq!(existing.power.legacy_pause_on_battery_power, None);
        assert_eq!(existing.quality.legacy_battery_profile_enabled, None);
    }
    let left = PowerCfg::default();
    let right = PowerCfg {
        on_battery_explicit: true,
        ..left
    };
    assert_eq!(left, right);
    for mode in ["keep_running", "reduced_quality", "pause"] {
        for raw in [
            format!("[power]\non_battery='{mode}'\npause_on_battery_power='wrong'\n"),
            format!("[power]\non_battery='{mode}'\n[quality]\nbattery_profile_enabled=9\n"),
        ] {
            assert!(toml::from_str::<AppConfig>(&raw).is_err());
            assert_kind(
                ConfigStore::validate_app_config_text(&raw),
                BridgeErrorKind::Config,
            );
        }
    }
}

// C05: typed version decisions are distinct from parse failures and do not rewrite bytes.
#[test]
fn supported_and_future_typed_schemas_do_not_rewrite_files() {
    let (_temporary, store) = isolated_store();
    for version in [None, Some(0), Some(1), Some(37)] {
        let app = version.map_or_else(String::new, |n| format!("schema_version = {n}\n"));
        let wall = version.map_or_else(
            || "{}".to_owned(),
            |n| format!("{{\"schema_version\":{n}}}"),
        );
        put(&app_path(&store), &app);
        put(&wallpaper_path(&store, "schema"), &wall);
        if version == Some(37) {
            assert_kind(store.load(), BridgeErrorKind::Config);
            assert_kind(store.load_wallpaper("schema"), BridgeErrorKind::Config);
            assert_kind(
                ConfigStore::validate_app_config_text(&app),
                BridgeErrorKind::Config,
            );
            assert_kind(
                ConfigStore::validate_wallpaper_config_text(&wall),
                BridgeErrorKind::Config,
            );
        } else {
            let loaded = store.load().unwrap();
            assert_eq!(loaded.config.schema_version, version.unwrap_or(1));
            assert!(loaded.backup_reported.is_empty());
            assert_eq!(
                store.load_wallpaper("schema").unwrap().schema_version,
                version.unwrap_or(1)
            );
            ConfigStore::validate_app_config_text(&app).unwrap();
            ConfigStore::validate_wallpaper_config_text(&wall).unwrap();
        }
        assert_eq!(fs::read_to_string(app_path(&store)).unwrap(), app);
        assert_eq!(
            fs::read_to_string(wallpaper_path(&store, "schema")).unwrap(),
            wall
        );
        assert_eq!(backups(&app_path(&store)).len(), 0);
        assert_eq!(backups(&wallpaper_path(&store, "schema")).len(), 0);
    }
}

fn backups(original: &Path) -> Vec<PathBuf> {
    let prefix = format!(
        "{}.corrupted-",
        original.file_name().unwrap().to_str().unwrap()
    );
    let mut paths: Vec<_> = fs::read_dir(original.parent().unwrap())
        .unwrap()
        .map(|entry| entry.unwrap().path())
        .filter(|path| {
            path.file_name()
                .unwrap()
                .to_str()
                .unwrap()
                .starts_with(&prefix)
        })
        .collect();
    paths.sort();
    paths
}

fn assert_backup(original: &Path, backup: &Path, payload: &[u8]) {
    assert_eq!(backup.parent(), original.parent());
    let prefix = format!(
        "{}.corrupted-",
        original.file_name().unwrap().to_str().unwrap()
    );
    let name = backup.file_name().unwrap().to_str().unwrap();
    let suffix = name
        .strip_prefix(&prefix)
        .expect("documented backup suffix");
    assert!(!suffix.is_empty());
    assert!(suffix.bytes().all(|byte| byte.is_ascii_digit()));
    suffix.parse::<u128>().unwrap();
    assert_eq!(fs::read(backup).unwrap(), payload);
    assert!(!original.exists());
}

// C05/C06: wrong schemas, malformed neighbors and invalid UTF-8 all take recovery.
#[test]
fn app_corruption_and_read_errors_backup_bytes_then_return_defaults() {
    let cases: Vec<Vec<u8>> = vec![
        b"[broken".to_vec(),
        b"schema_version=-1".to_vec(),
        b"schema_version=1.5".to_vec(),
        b"schema_version=4294967296".to_vec(),
        b"schema_version='one'".to_vec(),
        b"schema_version=37\n[general]\nlast_selected_wallpaper=8".to_vec(),
        vec![0xff, 0xfe, 0x61],
    ];
    for payload in cases {
        let (_temporary, store) = isolated_store();
        let path = app_path(&store);
        put(&path, &payload);
        let result = store.load().unwrap();
        assert_default_app(&result.config);
        assert_eq!(result.backup_reported.len(), 1);
        assert_backup(&path, &result.backup_reported[0], &payload);
        assert_eq!(backups(&path), result.backup_reported);
        let next = store.load().unwrap();
        assert_default_app(&next.config);
        assert!(next.backup_reported.is_empty());
        assert!(!path.exists());
        assert_eq!(backups(&path).len(), 1);
    }
}

#[test]
fn wallpaper_corruption_and_read_errors_backup_but_fail_the_first_load() {
    let cases: Vec<Vec<u8>> = vec![
        b"{\"broken\":".to_vec(),
        br#"{"schema_version":null}"#.to_vec(),
        br#"{"schema_version":-1}"#.to_vec(),
        br#"{"schema_version":0.5}"#.to_vec(),
        br#"{"schema_version":4294967296}"#.to_vec(),
        br#"{"schema_version":"one"}"#.to_vec(),
        br#"{"schema_version":37,"audio":{"muted":"wrong"}}"#.to_vec(),
        br#"{"audio":{"volume":NaN}}"#.to_vec(),
        vec![0xff, 0xfe, 0x62],
        br#"{"monitors":[{"framing":{"pan_x":0.2,"pan_y":]}}]}"#.to_vec(),
        br#"{"monitors":[{"framing":{"pan_x":1e400}}]}"#.to_vec(),
    ];
    for payload in cases {
        let (_temporary, store) = isolated_store();
        let path = wallpaper_path(&store, "broken-41");
        put(&path, &payload);
        let error = store.load_wallpaper("broken-41").unwrap_err();
        assert_eq!(error.kind(), BridgeErrorKind::Config);
        assert!(error.message().contains("broken-41"));
        let paths = backups(&path);
        assert_eq!(paths.len(), 1);
        assert_backup(&path, &paths[0], &payload);
        assert_default_wallpaper(
            &store.load_wallpaper("broken-41").unwrap(),
            "broken-41",
            "scene",
        );
        assert!(!path.exists());
        assert_eq!(backups(&path).len(), 1);
    }
}

// C07: fixed time only chooses a real destination collision; fs::rename actually fails.
#[test]
fn failed_corruption_backup_is_io_and_does_not_publish_default_recovery() {
    for payload in [
        b"not = [".as_slice(),
        b"[[monitors]]\nenabled=true\n".as_slice(),
        b"[[monitor_settings]]\n".as_slice(),
        &[0xff, 0xfe],
    ] {
        let (_temporary, store) = isolated_store();
        let path = app_path(&store);
        put(&path, payload);
        let collision = path.with_file_name("config.toml.corrupted-6153");
        fs::create_dir(&collision).unwrap();
        let error = store::backup_clock::during(6153, || store.load()).unwrap_err();
        assert_eq!(error.kind(), BridgeErrorKind::Io);
        assert_eq!(fs::read(&path).unwrap(), payload);
        assert!(collision.is_dir());
        assert_eq!(backups(&path), vec![collision]);
    }
    for payload in [b"{broken".as_slice(), &[0xff, 0xfe]] {
        let (_temporary, store) = isolated_store();
        let path = wallpaper_path(&store, "collision");
        put(&path, payload);
        let collision = path.with_file_name("collision.json.corrupted-6153");
        fs::create_dir(&collision).unwrap();
        let error =
            store::backup_clock::during(6153, || store.load_wallpaper("collision")).unwrap_err();
        assert_eq!(error.kind(), BridgeErrorKind::Io);
        assert_eq!(fs::read(&path).unwrap(), payload);
        assert!(collision.is_dir());
        assert_eq!(backups(&path), vec![collision]);
    }
}

// C08 local validators; free optional-app/map-key assembly belongs to the parent.
#[test]
fn text_validators_are_typed_version_checks_without_store_publication() {
    let (_temporary, store) = isolated_store();
    let sentinel = app_path(&store);
    put(&sentinel, b"sentinel, deliberately not TOML");
    for raw in [
        "",
        "schema_version=0",
        "schema_version=1",
        "[power]\npause_on_battery_power=true\n",
    ] {
        ConfigStore::validate_app_config_text(raw).unwrap();
    }
    for raw in [
        "[",
        "schema_version=2",
        "schema_version=-1",
        "[power]\non_battery='PAUSE'\n",
        "[ui.filter]\nscene=true\n",
    ] {
        assert_kind(
            ConfigStore::validate_app_config_text(raw),
            BridgeErrorKind::Config,
        );
    }
    for raw in [
        "{}",
        "{\"schema_version\":0}",
        "{\"schema_version\":1}",
        "{\"monitors\":[{\"framing\":\"ignored\"}]}",
    ] {
        ConfigStore::validate_wallpaper_config_text(raw).unwrap();
    }
    for raw in [
        "",
        "{",
        "{\"schema_version\":2}",
        "{\"schema_version\":null}",
        "{\"audio\":null}",
    ] {
        assert_kind(
            ConfigStore::validate_wallpaper_config_text(raw),
            BridgeErrorKind::Config,
        );
    }
    assert_eq!(
        fs::read(&sentinel).unwrap(),
        b"sentinel, deliberately not TOML"
    );
    assert_eq!(fs::read_dir(store.root()).unwrap().count(), 1);
    assert!(!store.root().join("wallpapers").exists());
}

// C09: both shapes, including JSON null versus omission, parse both known fields.
#[test]
fn modern_rate_presence_and_legacy_conversion_are_not_conflated() {
    let cases = [
        (json!({}), None),
        (json!({"frame_rate":null}), None),
        (json!({"frame_rate":0}), Some(0)),
        (json!({"frame_rate":60}), Some(60)),
        (json!({"frame_rate":103}), Some(103)),
        (json!({"legacy":null}), None),
        (json!({"legacy":0}), Some(1)),
        (json!({"legacy":60}), None),
        (json!({"legacy":103}), Some(103)),
        (json!({"frame_rate":null,"legacy":103}), None),
        (json!({"frame_rate":0,"legacy":103}), Some(0)),
        (json!({"frame_rate":60,"legacy":0}), Some(60)),
        (json!({"frame_rate":25,"legacy":60}), Some(25)),
    ];
    for (value, expected) in cases {
        let mut app = value.clone();
        let app_object = app.as_object_mut().unwrap();
        if let Some(legacy) = app_object.remove("legacy") {
            app_object.insert("target_fps".to_owned(), legacy);
        }
        app_object.insert("kind".to_owned(), json!("primary"));
        let app_monitor: MonitorSettingsCfg = serde_json::from_value(app).unwrap();
        assert_eq!(app_monitor.frame_rate, expected);
        let output = serde_json::to_value(&app_monitor).unwrap();
        assert_eq!(output.get("frame_rate").is_some(), expected.is_some());
        if let Some(rate) = expected {
            assert_eq!(output["frame_rate"], rate);
        }
        assert!(output.get("target_fps").is_none());
        let mut wallpaper = value;
        let object = wallpaper.as_object_mut().unwrap();
        if let Some(legacy) = object.remove("legacy") {
            object.insert("fps".to_owned(), legacy);
        }
        let monitor: MonitorRender = serde_json::from_value(wallpaper).unwrap();
        assert_eq!(monitor.frame_rate, expected);
        let output = serde_json::to_value(&monitor).unwrap();
        assert_eq!(output.get("frame_rate").is_some(), expected.is_some());
        if let Some(rate) = expected {
            assert_eq!(output["frame_rate"], rate);
        }
        assert!(output.get("fps").is_none());
    }
    for bad in [
        json!(-1),
        json!(0.5),
        json!(4294967296u64),
        json!("60"),
        json!(true),
        json!([]),
    ] {
        for key in ["frame_rate", "target_fps"] {
            let mut document = json!({"kind":"primary","frame_rate":25,"target_fps":60});
            document[key] = bad.clone();
            assert!(serde_json::from_value::<MonitorSettingsCfg>(document).is_err());
        }
        for key in ["frame_rate", "fps"] {
            let mut document = json!({"frame_rate":25,"fps":60});
            document[key] = bad.clone();
            assert!(serde_json::from_value::<MonitorRender>(document).is_err());
        }
    }
    for (fields, expected) in [
        ("", None),
        ("target_fps=60", None),
        ("target_fps=0", Some(1)),
        ("frame_rate=0\ntarget_fps=60", Some(0)),
        ("frame_rate=60", Some(60)),
        ("target_fps=27", Some(27)),
    ] {
        let raw = format!("[[monitor_settings]]\nkind='primary'\n{fields}\n");
        let config: AppConfig = toml::from_str(&raw).unwrap();
        assert_eq!(config.monitor_settings[0].frame_rate, expected);
        let output: toml::Value =
            toml::from_str(&toml::to_string_pretty(&config).unwrap()).unwrap();
        assert!(output["monitor_settings"][0].get("target_fps").is_none());
        assert_eq!(
            output["monitor_settings"][0].get("frame_rate").is_some(),
            expected.is_some()
        );
    }
    for fields in [
        "frame_rate=null",
        "frame_rate=-1",
        "frame_rate=1.2",
        "frame_rate=4294967296",
        "frame_rate=25\ntarget_fps='bad'",
        "frame_rate='bad'\ntarget_fps=30",
    ] {
        let raw = format!("[[monitor_settings]]\nkind='primary'\n{fields}\n");
        assert!(toml::from_str::<AppConfig>(&raw).is_err());
    }
}

// C10: rates are observed through the public monitor methods and crate-visible setters' seam.
#[test]
fn rates_follow_refresh_only_when_the_saved_choice_is_none() {
    for (refresh, default, resolutions, requests) in [
        (0, 1, vec![(0, 1), (200, 1)], vec![(0, None), (200, None)]),
        (
            50,
            50,
            vec![(0, 1), (80, 50)],
            vec![(50, None), (25, Some(25))],
        ),
        (
            60,
            60,
            vec![(0, 1), (120, 60)],
            vec![(60, None), (0, Some(1))],
        ),
        (
            144,
            60,
            vec![(100, 100), (200, 144)],
            vec![
                (60, None),
                (144, Some(144)),
                (200, Some(144)),
                (90, Some(90)),
            ],
        ),
    ] {
        assert_eq!(resolve_frame_rate(None, refresh), default);
        assert_eq!(MonitorSettingsCfg::default().fps_on(refresh), default);
        assert_eq!(MonitorRender::default().fps_on(refresh), default);
        for (explicit, expected) in resolutions {
            let app = MonitorSettingsCfg {
                frame_rate: Some(explicit),
                ..MonitorSettingsCfg::default()
            };
            let wallpaper = MonitorRender {
                frame_rate: Some(explicit),
                ..MonitorRender::default()
            };
            assert_eq!(app.fps_on(refresh), expected);
            assert_eq!(wallpaper.fps_on(refresh), expected);
        }
        for (requested, expected) in requests {
            assert_eq!(stored_frame_rate(requested, refresh), expected);
        }
    }
    let follow = MonitorRender::default();
    let explicit = MonitorRender {
        frame_rate: Some(50),
        ..MonitorRender::default()
    };
    assert_eq!(follow.fps_on(50), 50);
    assert_eq!(follow.fps_on(144), 60);
    assert_eq!(explicit.fps_on(144), 50);
    assert_eq!(explicit.frame_rate, Some(50));
}

// C11: malformed framing is axis-local recovery, not whole-document replacement.
#[test]
fn framing_json_normalizes_axes_and_retains_other_settings() {
    let cases = [
        (Value::Null, (0.5, 0.5)),
        (json!("off"), (0.5, 0.5)),
        (json!(false), (0.5, 0.5)),
        (json!([0.1, 0.2]), (0.5, 0.5)),
        (json!(0.2), (0.5, 0.5)),
        (json!({}), (0.5, 0.5)),
        (json!({"pan_x":0.5,"pan_y":0.5}), (0.5, 0.5)),
        (json!({"pan_x":0.2}), (0.2, 0.5)),
        (json!({"pan_y":0.9}), (0.5, 0.9)),
        (json!({"pan_x":-3,"pan_y":8}), (0.0, 1.0)),
        (json!({"pan_x":0,"pan_y":1}), (0.0, 1.0)),
        (json!({"pan_x":null,"pan_y":0.7}), (0.5, 0.7)),
        (json!({"pan_x":"0.1","pan_y":0.7}), (0.5, 0.7)),
        (json!({"pan_x":false,"pan_y":0.7}), (0.5, 0.7)),
        (json!({"pan_x":[],"pan_y":0.7}), (0.5, 0.7)),
        (json!({"pan_x":{},"pan_y":0.7}), (0.5, 0.7)),
        (json!({"pan_x":0.3,"pan_y":"bad"}), (0.3, 0.5)),
    ];
    for (value, (x, y)) in cases {
        let document = json!({"workshop_id":"framed","audio":{"muted":true},"monitors":[{
            "scaling_mode":"fit","scaling_factor":2.25,"frame_rate":41,"framing":value
        }]});
        let wallpaper: WallpaperConfig = serde_json::from_value(document).unwrap();
        assert!(wallpaper.audio.muted);
        let monitor = &wallpaper.monitors[0];
        assert_eq!(monitor.framing, FramingCfg { pan_x: x, pan_y: y });
        assert_eq!(monitor.scaling_mode, "fit");
        assert_eq!(monitor.scaling_factor, 2.25);
        assert_eq!(monitor.frame_rate, Some(41));
        let output = serde_json::to_value(monitor).unwrap();
        assert_eq!(output.get("framing").is_none(), x == 0.5 && y == 0.5);
        let again: MonitorRender = serde_json::from_value(output).unwrap();
        assert_eq!(again.framing, monitor.framing);
    }
    let mut monitor = MonitorRender::default();
    assert!(
        serde_json::to_value(&monitor)
            .unwrap()
            .get("framing")
            .is_none()
    );
    monitor.framing = FramingCfg {
        pan_x: 0.2,
        pan_y: 0.8,
    };
    let saved = serde_json::to_value(&monitor).unwrap();
    assert_eq!(saved["framing"], json!({"pan_x":0.2,"pan_y":0.8}));
    monitor.framing = FramingCfg {
        pan_x: 0.5,
        pan_y: 0.5,
    };
    assert!(
        serde_json::to_value(&monitor)
            .unwrap()
            .get("framing")
            .is_none()
    );
}

#[test]
fn framing_memory_normalization_and_scene_conversion_enforce_independent_axis_bounds() {
    for (x, expected_x) in [
        (f64::NAN, 0.5),
        (f64::INFINITY, 0.5),
        (f64::NEG_INFINITY, 0.5),
        (-0.2, 0.0),
        (1.2, 1.0),
        (0.3, 0.3),
    ] {
        let framing = FramingCfg {
            pan_x: x,
            pan_y: 0.8,
        };
        assert_eq!(
            framing.normalized(),
            FramingCfg {
                pan_x: expected_x,
                pan_y: 0.8
            }
        );
        let scene = framing.to_scene();
        assert_eq!(scene.pan_x, expected_x);
        assert_eq!(scene.pan_y, 0.8);
        assert!(scene.pan_x.is_finite() && (0.0..=1.0).contains(&scene.pan_x));
        let framing = FramingCfg {
            pan_x: 0.2,
            pan_y: x,
        };
        assert_eq!(
            framing.normalized(),
            FramingCfg {
                pan_x: 0.2,
                pan_y: expected_x
            }
        );
        let scene = framing.to_scene();
        assert_eq!(scene.pan_x, 0.2);
        assert_eq!(scene.pan_y, expected_x);
        assert!(scene.pan_y.is_finite() && (0.0..=1.0).contains(&scene.pan_y));
    }
    assert!(
        FramingCfg {
            pan_x: 0.5,
            pan_y: 0.5
        }
        .is_default()
    );
    assert!(
        !FramingCfg {
            pan_x: f64::from_bits(0.5f64.to_bits() + 1),
            pan_y: 0.5
        }
        .is_default()
    );
    assert!(
        !FramingCfg {
            pan_x: f64::NAN,
            pan_y: 0.5
        }
        .is_default()
    );
    assert!(
        FramingCfg {
            pan_x: f64::NAN,
            pan_y: f64::INFINITY
        }
        .normalized()
        .is_default()
    );
}

// C12: core conversion, two distinct identity encodings, required app discriminators.
#[test]
fn selectors_preserve_core_fields_and_identity_ids_have_ordered_nulls_and_escaping() {
    let identity = SerializedSelector::Identity {
        uuid: Some("A\"\\\n".to_owned()),
        vendor_id: Some(17),
        model_id: None,
        serial_number: Some(0),
        unit_number: Some(u32::MAX),
        name: Some("Screen\t雪".to_owned()),
    };
    assert_eq!(
        identity.id(),
        r#"identity:{"uuid":"A\"\\\n","vendor_id":17,"model_id":null,"serial_number":0,"unit_number":4294967295,"name":"Screen\t雪"}"#
    );
    let core = identity.to_selector();
    assert_eq!(
        core,
        DisplaySelector::Identity(DisplayIdentity {
            uuid: Some("A\"\\\n".to_owned()),
            vendor_id: Some(17),
            model_id: None,
            serial_number: Some(0),
            unit_number: Some(u32::MAX),
            name: Some("Screen\t雪".to_owned()),
        })
    );
    assert_eq!(SerializedSelector::from_selector(&core), identity);
    for (saved, expected_core, id) in [
        (
            SerializedSelector::Primary,
            DisplaySelector::Primary,
            "primary",
        ),
        (
            SerializedSelector::LiveDisplayId { display_id: 0 },
            DisplaySelector::LiveDisplayId(0),
            "0",
        ),
        (
            SerializedSelector::LiveDisplayId {
                display_id: u32::MAX,
            },
            DisplaySelector::LiveDisplayId(u32::MAX),
            "4294967295",
        ),
    ] {
        assert_eq!(saved.to_selector(), expected_core);
        assert_eq!(SerializedSelector::from_selector(&expected_core), saved);
        assert_eq!(saved.id(), id);
        assert_eq!(
            serde_json::from_value::<SerializedSelector>(serde_json::to_value(&saved).unwrap())
                .unwrap(),
            saved
        );
    }
    let empty: SerializedSelector =
        serde_json::from_value(json!({"kind":"identity","uuid":null})).unwrap();
    assert_eq!(
        serde_json::to_value(&empty).unwrap(),
        json!({"kind":"identity"})
    );
    assert_eq!(
        empty.id(),
        "identity:{\"uuid\":null,\"vendor_id\":null,\"model_id\":null,\"serial_number\":null,\"unit_number\":null,\"name\":null}"
    );
    let saved = serde_json::to_value(&identity).unwrap();
    assert_eq!(saved["kind"], "identity");
    assert!(saved.get("model_id").is_none());
    assert_eq!(saved["uuid"], "A\"\\\n");
    for bad in [
        json!({"kind":"unknown"}),
        json!({"kind":"live_display_id"}),
        json!({"kind":"identity","vendor_id":-1}),
        json!({"kind":"identity","uuid":3}),
        json!({"kind":"live_display_id","display_id":4294967296u64}),
    ] {
        assert!(serde_json::from_value::<SerializedSelector>(bad).is_err());
    }
}

#[test]
fn flattened_app_selectors_are_required_but_missing_nested_wallpaper_selectors_default() {
    for raw in [
        "[[monitors]]\n",
        "[[monitors]]\nenabled=true\n",
        "[[monitor_settings]]\n",
        "[[monitor_settings]]\nvolume=0.5\n",
    ] {
        assert!(toml::from_str::<AppConfig>(raw).is_err());
        assert_kind(
            ConfigStore::validate_app_config_text(raw),
            BridgeErrorKind::Config,
        );
        let (_temporary, store) = isolated_store();
        let path = app_path(&store);
        put(&path, raw);
        let recovered = store.load().unwrap();
        assert_default_app(&recovered.config);
        assert_eq!(recovered.backup_reported.len(), 1);
        assert_backup(&path, &recovered.backup_reported[0], raw.as_bytes());
    }
    let app: AppConfig = toml::from_str("").unwrap();
    assert!(app.monitors.is_empty());
    assert!(app.monitor_settings.is_empty());
    assert_eq!(
        serde_json::from_value::<MonitorRender>(json!({}))
            .unwrap()
            .selector,
        SerializedSelector::Primary
    );
    assert!(serde_json::from_value::<MonitorRender>(json!({"selector":null})).is_err());
    for value in [
        json!({"workshop_id":null}),
        json!({"type":null}),
        json!({"audio":null}),
        json!({"audio":{"volume":null}}),
        json!({"audio":{"muted":null}}),
        json!({"monitors":null}),
        json!({"property_overrides":null}),
        json!({"media_integration_enabled":null}),
    ] {
        assert!(serde_json::from_value::<WallpaperConfig>(value).is_err());
    }
}

#[test]
fn scaling_interpretation_is_ascii_case_insensitive_without_changing_saved_strings() {
    for (raw, expected) in [
        ("NoNe", ScalingMode::None),
        ("sTrEtCh", ScalingMode::Stretch),
        ("FiT", ScalingMode::Fit),
        ("fIlL", ScalingMode::Fill),
        ("unrecognized", ScalingMode::Fill),
        (" fit ", ScalingMode::Fill),
        ("ＦＩＴ", ScalingMode::Fill),
    ] {
        let app = MonitorSettingsCfg {
            scaling_mode: raw.to_owned(),
            ..MonitorSettingsCfg::default()
        };
        let wallpaper = MonitorRender {
            scaling_mode: raw.to_owned(),
            ..MonitorRender::default()
        };
        assert_eq!(app.parse_scaling_mode(), expected);
        assert_eq!(wallpaper.parse_scaling_mode(), expected);
        assert_eq!(serde_json::to_value(&app).unwrap()["scaling_mode"], raw);
        assert_eq!(
            serde_json::to_value(&wallpaper).unwrap()["scaling_mode"],
            raw
        );
    }
}

// C13: only effective calculations clamp; all four runtime flag states are tested.
#[test]
fn effective_quality_clamps_values_but_never_mutates_saved_preferences() {
    for (value, expected) in [
        (0.0, 0.25),
        (-10.0, 0.25),
        (0.25, 0.25),
        (0.625, 0.625),
        (1.0, 1.0),
        (2.0, 1.0),
        (f32::NAN, 1.0),
        (f32::INFINITY, 1.0),
        (f32::NEG_INFINITY, 1.0),
    ] {
        assert_eq!(clamp_render_scale(value), expected);
    }
    assert_eq!(
        QualityInForce::default(),
        QualityInForce {
            battery_profile: false,
            throttled: false
        }
    );
    for (preferred, profile, plain, battery, throttle) in [
        (0.4, 0.9, 0.4, 0.9, 0.4),
        (0.9, 0.4, 0.9, 0.4, 0.4),
        (-1.0, 2.0, 0.25, 1.0, 0.25),
        (f32::NAN, 0.6, 1.0, 0.6, 0.6),
    ] {
        let mut config = AppConfig::default();
        config.quality.render_scale = preferred;
        config.quality.battery.render_scale = profile;
        for (battery_profile, throttled, expected) in [
            (false, false, plain),
            (true, false, battery),
            (false, true, throttle),
            (true, true, throttle),
        ] {
            assert_eq!(
                config.effective_render_scale(QualityInForce {
                    battery_profile,
                    throttled
                }),
                expected
            );
            assert_eq!(config.quality.render_scale.to_bits(), preferred.to_bits());
            assert_eq!(
                config.quality.battery.render_scale.to_bits(),
                profile.to_bits()
            );
        }
    }
}

// C14: missing and explicit null differ; every external conversion variant is observable.
#[test]
fn overrides_borrow_represented_json_and_delegate_conversion_without_pruning() {
    let mut wallpaper = WallpaperConfig::new_for("overrides", "scene");
    let cases = [
        ("null", Value::Null, PropertyValue::Null),
        ("bool", json!(true), PropertyValue::Bool(true)),
        ("number", json!(5.5), PropertyValue::Number(5.5)),
        (
            "string",
            json!("hello"),
            PropertyValue::String("hello".to_owned()),
        ),
        (
            "rgb",
            json!(" 0.25\t0.5 1 "),
            PropertyValue::ColorRgb(0.25, 0.5, 1.0),
        ),
        (
            "too_many",
            json!("0 0 0 0"),
            PropertyValue::String("0 0 0 0".to_owned()),
        ),
        (
            "out_of_range",
            json!("1.1 0 0"),
            PropertyValue::String("1.1 0 0".to_owned()),
        ),
        (
            "not_numeric",
            json!("red 0 0"),
            PropertyValue::String("red 0 0".to_owned()),
        ),
        (
            "nan",
            json!("NaN 0 0"),
            PropertyValue::String("NaN 0 0".to_owned()),
        ),
        (
            "array",
            json!([1, null, false]),
            PropertyValue::String("[1,null,false]".to_owned()),
        ),
        (
            "object",
            json!({"a":2}),
            PropertyValue::String("{\"a\":2}".to_owned()),
        ),
    ];
    for (key, value, _) in &cases {
        wallpaper
            .property_overrides
            .insert((*key).to_owned(), value.clone());
    }
    assert_eq!(wallpaper.override_json("missing"), None);
    assert_eq!(wallpaper.override_value("missing"), None);
    for (key, value, expected) in cases {
        let borrowed = wallpaper.override_json(key).unwrap();
        assert_eq!(borrowed, &value);
        assert!(std::ptr::eq(
            borrowed,
            wallpaper.property_overrides.get(key).unwrap()
        ));
        assert_eq!(wallpaper.override_value(key), Some(expected));
    }
    let (_temporary, store) = isolated_store();
    store.save_wallpaper(&wallpaper).unwrap();
    assert_eq!(
        store
            .load_wallpaper("overrides")
            .unwrap()
            .property_overrides,
        wallpaper.property_overrides
    );
}

// C15 local writer cases. Relative-basename cwd behavior requires parent's isolated process.
#[test]
fn atomic_writes_create_parents_and_replace_complete_arbitrary_payloads() {
    let (temporary, _store) = isolated_store();
    let path = temporary.path().join("new/a/b/raw.dat");
    writer::atomic_write(&path, &[0, 0xff, 0x61, 0x00, 0x62]).unwrap();
    assert_eq!(fs::read(&path).unwrap(), [0, 0xff, 0x61, 0x00, 0x62]);
    writer::atomic_write(&path, b"z").unwrap();
    assert_eq!(fs::read(&path).unwrap(), b"z");
    writer::atomic_write(&path, b"").unwrap();
    assert_eq!(fs::read(&path).unwrap(), b"");
    for no_parent in [Path::new(""), Path::new("/")] {
        assert_eq!(
            writer::atomic_write(no_parent, b"must not publish")
                .unwrap_err()
                .kind(),
            std::io::ErrorKind::InvalidInput
        );
    }
}

#[test]
fn actual_parent_creation_and_replacement_failures_do_not_publish_target_bytes() {
    let (temporary, _store) = isolated_store();
    let blocking_file = temporary.path().join("blocked-parent");
    fs::write(&blocking_file, b"parent is a file").unwrap();
    assert!(writer::atomic_write(&blocking_file.join("target"), b"new").is_err());
    assert_eq!(fs::read(&blocking_file).unwrap(), b"parent is a file");
    let directory_target = temporary.path().join("directory-target");
    fs::create_dir(&directory_target).unwrap();
    fs::write(directory_target.join("sentinel"), b"keep").unwrap();
    assert!(writer::atomic_write(&directory_target, b"new").is_err());
    assert!(directory_target.is_dir());
    assert_eq!(
        fs::read(directory_target.join("sentinel")).unwrap(),
        b"keep"
    );
}

// Review-required deterministic IO faults execute the production publication algorithm.
#[test]
fn write_and_sync_faults_leave_existing_target_and_missing_target_unpublished() {
    for stage in [writer::fault::Stage::Write, writer::fault::Stage::Sync] {
        let (temporary, _store) = isolated_store();
        let existing = temporary.path().join("old.bin");
        let missing = temporary.path().join("nested/new.bin");
        fs::write(&existing, b"previous complete bytes").unwrap();
        for target in [&existing, &missing] {
            let result =
                writer::fault::during(stage, || writer::atomic_write(target, b"replacement"));
            assert!(result.is_err());
        }
        assert_eq!(fs::read(&existing).unwrap(), b"previous complete bytes");
        assert!(!missing.exists());
        writer::atomic_write(&existing, b"committed after fault").unwrap();
        assert_eq!(fs::read(&existing).unwrap(), b"committed after fault");
    }
}

// C16: saves publish now, flush never batches, failures retain IO ownership.
#[test]
fn save_failures_are_io_and_successful_saves_are_immediately_readable() {
    let (_temporary, store) = isolated_store();
    assert_eq!(store.flush().unwrap(), 0);
    let app = AppConfig::default();
    let wallpaper = WallpaperConfig::new_for("immediate", "web");
    store.save_app_config(&app).unwrap();
    store.save_wallpaper(&wallpaper).unwrap();
    assert_eq!(store.load().unwrap().config, app);
    assert_eq!(store.load_wallpaper("immediate").unwrap(), wallpaper);
    assert_eq!(store.flush().unwrap(), 0);
    let app_before = fs::read(app_path(&store)).unwrap();
    let wallpaper_before = fs::read(wallpaper_path(&store, "immediate")).unwrap();
    for stage in [writer::fault::Stage::Write, writer::fault::Stage::Sync] {
        let mut changed = app.clone();
        changed.general.last_selected_wallpaper = Some("not published".to_owned());
        assert_kind(
            writer::fault::during(stage, || store.save_app_config(&changed)),
            BridgeErrorKind::Io,
        );
        let mut changed = wallpaper.clone();
        changed.audio.muted = true;
        assert_kind(
            writer::fault::during(stage, || store.save_wallpaper(&changed)),
            BridgeErrorKind::Io,
        );
        assert_eq!(fs::read(app_path(&store)).unwrap(), app_before);
        assert_eq!(
            fs::read(wallpaper_path(&store, "immediate")).unwrap(),
            wallpaper_before
        );
        assert_eq!(store.flush().unwrap(), 0);
    }
    let (temporary, _unused) = isolated_store();
    let blocked = temporary.path().join("file-root");
    fs::write(&blocked, b"unchanged blocker").unwrap();
    let blocked_store = ConfigStore::open(&blocked);
    assert_kind(blocked_store.save_app_config(&app), BridgeErrorKind::Io);
    assert_kind(
        blocked_store.save_wallpaper(&wallpaper),
        BridgeErrorKind::Io,
    );
    assert_eq!(fs::read(blocked).unwrap(), b"unchanged blocker");
}

#[test]
fn save_does_not_apply_schema_acceptance_or_migration() {
    let (_temporary, store) = isolated_store();
    let mut app = AppConfig::default();
    app.schema_version = 48;
    app.power.legacy_pause_on_battery_power = Some(true);
    app.quality.legacy_battery_profile_enabled = Some(true);
    store.save_app_config(&app).unwrap();
    let output = app_output(&store);
    assert_eq!(output["schema_version"].as_integer(), Some(48));
    assert_eq!(output["power"]["on_battery"].as_str(), Some("keep_running"));
    assert!(output["power"].get("pause_on_battery_power").is_none());
    assert!(output["quality"].get("battery_profile_enabled").is_none());
    let app_bytes = fs::read(app_path(&store)).unwrap();
    assert_kind(store.load(), BridgeErrorKind::Config);
    assert_eq!(fs::read(app_path(&store)).unwrap(), app_bytes);
    assert!(backups(&app_path(&store)).is_empty());
    let mut wallpaper = WallpaperConfig::new_for("future-save", "scene");
    wallpaper.schema_version = 48;
    store.save_wallpaper(&wallpaper).unwrap();
    assert_eq!(
        wallpaper_output(&store, "future-save")["schema_version"],
        48
    );
    let bytes = fs::read(wallpaper_path(&store, "future-save")).unwrap();
    assert_kind(store.load_wallpaper("future-save"), BridgeErrorKind::Config);
    assert_eq!(
        fs::read(wallpaper_path(&store, "future-save")).unwrap(),
        bytes
    );
    assert!(backups(&wallpaper_path(&store, "future-save")).is_empty());
}
