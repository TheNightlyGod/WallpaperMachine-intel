use std::collections::BTreeMap;

use crate::api::{
    BridgeComboOption, BridgeDirectoryMode, BridgeDisplayConfigRow, BridgeDisplayMode,
    BridgeDisplaySettingsRow, BridgeFileFilter, BridgeMonitorInfoRow,
    BridgeMonitorInformationSnapshot, BridgePropertyDescriptor, BridgeScalingMode,
    BridgeSliderMetadata, BridgeWallpaperEntry, BridgeWallpaperOptionsSnapshot,
};
use crate::config::{
    AppConfig, AudioCfg, MonitorRender, MonitorSettingsCfg, SerializedSelector, WallpaperConfig,
};
use crate::display::{DisplayLabelExt, DisplaySelectorExt, DisplaySnapshotExt, MonitorRow};
use crate::project::{ProjectModel, ProjectProperty, PropertyValue};
use crate::state::drafts::WallpaperOptionsDraft;
use wallpaper_core::{DisplaySnapshotEntry, WallpaperAssignment};

/// Values supplied by the retained localization/visibility/metadata/asset policy.
/// The caller shares one manifest and override context across all invocations.
pub(super) struct PropertyAnnotation {
    pub(super) label_html: String,
    pub(super) slider: Option<BridgeSliderMetadata>,
    pub(super) combo_options: Vec<BridgeComboOption>,
    pub(super) file_filter: Option<BridgeFileFilter>,
    pub(super) directory_mode: Option<BridgeDirectoryMode>,
    pub(super) enabled: bool,
    pub(super) asset_managed: bool,
    pub(super) asset_missing: bool,
    pub(super) asset_source_path: Option<String>,
}

/// ID validation, genuine draft acquisition, manifest loading and override decoding
/// precede this value operation and remain the caller's responsibility.
pub(super) fn project_options(
    entry: &BridgeWallpaperEntry,
    draft: &WallpaperOptionsDraft,
    active_enabled_displays: &[SerializedSelector],
    model: Option<&ProjectModel>,
    overrides: &BTreeMap<String, PropertyValue>,
    app: &AppConfig,
    displays: &[DisplaySnapshotEntry],
    mut annotate: impl FnMut(&ProjectProperty, &PropertyValue) -> PropertyAnnotation,
) -> BridgeWallpaperOptionsSnapshot {
    let current = draft.current();
    let properties = model.map_or_else(Vec::new, |model| {
        model
            .properties
            .iter()
            .map(|property| {
                let value = property.effective_value(overrides);
                let dirty = !property.value_is_default(&value);
                let annotation = annotate(property, &value);
                BridgePropertyDescriptor {
                    id: property.id.clone(),
                    kind: (&property.kind).into(),
                    label_html: annotation.label_html,
                    value: value.into(),
                    default_value: property.default_value().into(),
                    slider: annotation.slider,
                    combo_options: annotation.combo_options,
                    file_filter: annotation.file_filter,
                    directory_mode: annotation.directory_mode,
                    dirty,
                    can_restore_defaults: dirty,
                    enabled: annotation.enabled,
                    asset_managed: annotation.asset_managed,
                    asset_missing: annotation.asset_missing,
                    asset_source_path: annotation.asset_source_path,
                }
            })
            .collect()
    });
    let normalized = app.normalized(displays);
    let rows = normalized.monitor_rows(displays);
    let display_configurations = rows
        .iter()
        .filter_map(|row| {
            if !row.connected || !row.config.enabled || row.config.mode == "mirror" {
                return None;
            }
            let display = displays.get(row.display_index?)?;
            let default = MonitorRender {
                selector: row.selector.clone(),
                ..MonitorRender::default()
            };
            let render = current
                .monitors
                .iter()
                .find(|render| render.selector == row.selector)
                .unwrap_or(&default);
            let dirty =
                render != &default || draft.display_dirty(&row.selector, active_enabled_displays);
            let max_fps = display.desc.refresh_rate_hz.max(1);
            Some(BridgeDisplayConfigRow {
                display_id: row.selector.id(),
                title: display.title_with_role(row.selector == SerializedSelector::Primary),
                enabled: draft.effective_display_enabled(&row.selector, active_enabled_displays),
                scaling_mode: render.parse_scaling_mode().into(),
                scaling_factor: render.scaling_factor,
                framing: render.framing.into(),
                target_fps: render.fps_on(max_fps),
                max_fps,
                muted: current.audio.muted,
                volume: current.audio.volume,
                dirty,
                can_restore_defaults: dirty,
            })
        })
        .collect();
    BridgeWallpaperOptionsSnapshot {
        wallpaper_id: entry.id.clone(),
        title: entry.title.clone(),
        kind: entry.kind,
        supported: entry.supported,
        dirty: draft.is_dirty(active_enabled_displays),
        properties,
        display_configurations,
        audio_response_enabled: current.audio.response_enabled,
        media_integration_enabled: current.media_integration_enabled,
        muted: current.audio.muted,
        volume: current.audio.volume,
    }
}

pub(super) fn project_monitors<'a>(
    app: &AppConfig,
    displays: &[DisplaySnapshotEntry],
    committed_config: impl Fn(&str) -> Option<&'a WallpaperConfig>,
    library_title: impl Fn(&str) -> Option<&'a str>,
) -> BridgeMonitorInformationSnapshot {
    let normalized = app.normalized(displays);
    let rows = normalized.monitor_rows(displays);
    let rows = rows
        .iter()
        .filter_map(|row| {
            if !row.connected || !row.config.enabled {
                return None;
            }
            let display = displays.get(row.display_index?)?;
            let target = if row.config.mode == "mirror" {
                match row.config.mirror_target.as_ref() {
                    Some(selector) => {
                        let display = selector.to_selector().resolve_display(displays)?;
                        let selector = display.config_selector(displays);
                        let row = rows.iter().find(|row| row.selector == selector)?;
                        Some((display, row))
                    }
                    None => None,
                }
            } else {
                None
            };
            let source_row = target.map_or(row, |(_, row)| row);
            let wallpaper_id = source_row.config.wallpaper.as_deref()?;
            let config = committed_config(wallpaper_id);
            let default_render;
            let render = match config.and_then(|config| {
                config
                    .monitors
                    .iter()
                    .find(|render| render.selector == source_row.selector)
            }) {
                Some(render) => render,
                None => {
                    default_render = MonitorRender {
                        selector: source_row.selector.clone(),
                        ..MonitorRender::default()
                    };
                    &default_render
                }
            };
            let primary = row.selector == SerializedSelector::Primary;
            Some(BridgeMonitorInfoRow {
                display_id: row.selector.id(),
                title: display.title_with_suffix(&format!(
                    "({} - {} - {})",
                    display.desc.display_id,
                    if primary { "Primary" } else { "Secondary" },
                    wallpaper_id
                )),
                wallpaper_id: wallpaper_id.to_owned(),
                wallpaper_title: library_title(wallpaper_id)
                    .unwrap_or(wallpaper_id)
                    .to_owned(),
                mirror_target_display_id: target.map(|(_, row)| row.selector.id()),
                mirror_target_title: target.map(|(display, row)| {
                    display.title_with_role(row.selector == SerializedSelector::Primary)
                }),
                scaling_mode: match BridgeScalingMode::from(render.parse_scaling_mode()) {
                    BridgeScalingMode::None => "None",
                    BridgeScalingMode::Stretch => "Stretch",
                    BridgeScalingMode::Match => "Match",
                    BridgeScalingMode::Fill => "Fill",
                    BridgeScalingMode::MatchBlurred => "MatchBlurred",
                }
                .to_owned(),
                target_fps: render
                    .fps_on(display.desc.refresh_rate_hz.max(1))
                    .to_string(),
                audio_response: config.map_or_else(
                    || AudioCfg::default().response_enabled,
                    |config| config.audio.response_enabled,
                ),
            })
        })
        .collect();
    BridgeMonitorInformationSnapshot { rows }
}

/// `normalized` is shared with retained settings reports; do not normalize here.
/// Remembered rows are borrowed lazily and cloned only for empty inventory.
pub(super) fn project_settings_rows<'a, I>(
    normalized: &AppConfig,
    displays: &[DisplaySnapshotEntry],
    remembered: impl FnOnce() -> I,
) -> Vec<BridgeDisplaySettingsRow>
where
    I: IntoIterator<Item = &'a BridgeDisplaySettingsRow>,
{
    if displays.is_empty() {
        return remembered().into_iter().cloned().collect();
    }
    let rows = normalized.monitor_rows(displays);
    rows.iter()
        .filter_map(|row| {
            let display = displays.get(row.display_index?)?;
            let mirror_targets = rows
                .iter()
                .filter_map(|candidate| {
                    if candidate.selector == row.selector
                        || !candidate.connected
                        || !candidate.config.enabled
                        || candidate.config.mode == "mirror"
                    {
                        return None;
                    }
                    let display = displays.get(candidate.display_index?)?;
                    Some(display.config_selector(displays).id())
                })
                .collect();
            Some(settings_row(
                normalized,
                displays,
                row,
                display,
                mirror_targets,
            ))
        })
        .collect()
}

fn settings_row(
    normalized: &AppConfig,
    displays: &[DisplaySnapshotEntry],
    row: &MonitorRow,
    display: &DisplaySnapshotEntry,
    mirror_targets: Vec<String>,
) -> BridgeDisplaySettingsRow {
    let configured = normalized
        .monitors
        .iter()
        .find(|config| config.selector == row.selector);
    let primary = row.selector == SerializedSelector::Primary;
    let mode = match configured {
        Some(config) if !primary && config.mode.eq_ignore_ascii_case("mirror") => {
            BridgeDisplayMode::Mirror
        }
        Some(_) => BridgeDisplayMode::Standalone,
        None if matches!(display.assignment, Some(WallpaperAssignment::Mirror(_))) => {
            BridgeDisplayMode::Mirror
        }
        None => BridgeDisplayMode::Standalone,
    };
    let selected_mirror_target = if mode == BridgeDisplayMode::Mirror {
        match configured {
            Some(config) => config
                .mirror_target
                .as_ref()
                .and_then(|target| target.mirror_target_id(display, displays)),
            None => match &display.assignment {
                Some(WallpaperAssignment::Mirror(target)) => {
                    SerializedSelector::from_selector(target).mirror_target_id(display, displays)
                }
                _ => None,
            },
        }
    } else {
        None
    };
    let default;
    let settings = match normalized
        .monitor_settings
        .iter()
        .find(|settings| settings.selector == row.selector)
    {
        Some(settings) => settings,
        None => {
            default = MonitorSettingsCfg {
                selector: row.selector.clone(),
                ..MonitorSettingsCfg::default()
            };
            &default
        }
    };
    let max_fps = display.desc.refresh_rate_hz.max(1);
    BridgeDisplaySettingsRow {
        display_id: row.selector.id(),
        title: display.title_with_role(primary),
        enabled: primary || row.config.enabled,
        mode,
        mirror_targets,
        selected_mirror_target,
        scaling_mode: settings.parse_scaling_mode().into(),
        scaling_factor: settings.scaling_factor,
        target_fps: settings.fps_on(max_fps),
        max_fps,
        muted: settings.muted,
        volume: settings.volume,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::{BridgePropertyKind, BridgePropertyValue, BridgeWallpaperKind};
    use crate::config::{FramingCfg, MonitorCfg};
    use wallpaper_core::{DisplayDesc, DisplayIdentity, DisplaySelector};

    fn display(id: u32, hz: u32) -> DisplaySnapshotEntry {
        let identity = DisplayIdentity {
            uuid: Some(format!("projection-panel-{id}")),
            name: Some(format!("Panel {id}")),
            ..DisplayIdentity::default()
        };
        DisplaySnapshotEntry {
            identity: identity.clone(),
            desc: DisplayDesc {
                display_id: id,
                identity,
                x: 0,
                y: 0,
                width: 1700,
                height: 1000,
                scale_factor: 1.0,
                refresh_rate_hz: hz,
            },
            handle: None,
            accepts_pointer_input: false,
            paused: false,
            window_active: false,
            assignment: None,
        }
    }

    fn entry() -> BridgeWallpaperEntry {
        BridgeWallpaperEntry {
            id: "value-study".into(),
            title: "Requested entry".into(),
            kind: BridgeWallpaperKind::ProjectScene,
            supported: true,
            active: false,
            selected: false,
            preview_path: None,
        }
    }

    // Explicit policy inputs, not implementations or evidence of retained policy.
    fn annotation(property: &ProjectProperty, _: &PropertyValue) -> PropertyAnnotation {
        PropertyAnnotation {
            label_html: format!("<b>{}</b>", property.id),
            slider: None,
            combo_options: Vec::new(),
            file_filter: None,
            directory_mode: None,
            enabled: false,
            asset_managed: false,
            asset_missing: false,
            asset_source_path: Some("recorded-nonasset-input".into()),
        }
    }

    fn model() -> ProjectModel {
        ProjectModel::parse(
            "value-study",
            r#"{
            "type":"scene","title":"Model is not entry title",
            "general":{"properties":{
                "level":{"type":"slider","value":0.25,"min":0,"max":1,"order":1},
                "tint":{"type":"color","value":"0.1 0.2 0.3","order":2},
                "note":{"type":"unrecognized-future-kind","order":3},
                "choice":{"type":"combo","value":"first","order":4,
                    "options":[{"label":"One","value":"first"},{"label":"Two","value":2}]}
            }}
        }"#,
        )
        .unwrap()
    }

    #[test]
    fn properties_use_real_values_defaults_order_and_opaque_draft_queries() {
        let model = model();
        let mut saved = WallpaperConfig::new_for("value-study", "scene");
        saved
            .property_overrides
            .insert("level".into(), serde_json::json!(0.75));
        let mut draft = WallpaperOptionsDraft::from_committed(saved);
        let overrides = model.override_values(&draft.current().property_overrides);
        let app = AppConfig::default();
        let mut calls = Vec::new();
        let snapshot = project_options(
            &entry(),
            &draft,
            &[],
            Some(&model),
            &overrides,
            &app,
            &[],
            |property, value| {
                calls.push((property.id.clone(), value.clone()));
                annotation(property, value)
            },
        );
        assert!(!snapshot.dirty);
        assert_eq!(snapshot.title, "Requested entry");
        assert_eq!(
            snapshot
                .properties
                .iter()
                .map(|row| row.id.as_str())
                .collect::<Vec<_>>(),
            ["level", "tint", "note", "choice"]
        );
        assert_eq!(calls.len(), 4);
        let level = &snapshot.properties[0];
        assert_eq!(level.value, BridgePropertyValue::Number { value: 0.75 });
        assert_eq!(
            level.default_value,
            BridgePropertyValue::Number { value: 0.25 }
        );
        assert!(level.dirty && level.can_restore_defaults && !level.enabled);
        assert_eq!(level.kind, BridgePropertyKind::Slider);
        assert_eq!(level.label_html, "<b>level</b>");
        assert_eq!(
            level.asset_source_path.as_deref(),
            Some("recorded-nonasset-input")
        );
        assert!(!level.asset_managed && !level.asset_missing);
        assert_eq!(
            snapshot.properties[1].value,
            BridgePropertyValue::ColorRgb {
                red: 0.1_f32 as f64,
                green: 0.2_f32 as f64,
                blue: 0.3_f32 as f64,
            }
        );
        assert_eq!(snapshot.properties[2].kind, BridgePropertyKind::Unknown);
        assert_eq!(snapshot.properties[2].value, BridgePropertyValue::Empty);
        assert_eq!(
            snapshot.properties[3].value,
            BridgePropertyValue::String {
                value: "first".into()
            }
        );
        draft.edit_property(&model, "level", PropertyValue::Number(0.25));
        draft.set_muted(true);
        let overrides = model.override_values(&draft.current().property_overrides);
        let changed = project_options(
            &entry(),
            &draft,
            &[],
            Some(&model),
            &overrides,
            &app,
            &[],
            annotation,
        );
        assert!(changed.dirty && changed.muted);
        assert!(!changed.properties[0].dirty && !changed.properties[0].can_restore_defaults);
        assert_eq!(
            draft.committed().property_overrides.get("level"),
            Some(&serde_json::json!(0.75))
        );
        assert_eq!(
            model.properties[0].default_value(),
            PropertyValue::Number(0.25)
        );
    }

    #[test]
    fn annotation_metadata_is_preserved_without_changing_values() {
        let model = model();
        let draft =
            WallpaperOptionsDraft::from_committed(WallpaperConfig::new_for("value-study", "scene"));
        let snapshot = project_options(
            &entry(),
            &draft,
            &[],
            Some(&model),
            &BTreeMap::new(),
            &AppConfig::default(),
            &[],
            |property, value| {
                let mut result = annotation(property, value);
                if property.id == "level" {
                    result.slider = Some(BridgeSliderMetadata {
                        min: -0.125,
                        max: 1.875,
                        step: 0.0625,
                        precision: 4_000_000_000,
                    });
                }
                if property.id == "choice" {
                    result.combo_options = vec![
                        BridgeComboOption {
                            label: "Second first".into(),
                            value: BridgePropertyValue::String { value: "2".into() },
                        },
                        BridgeComboOption {
                            label: "First second".into(),
                            value: BridgePropertyValue::String {
                                value: "first".into(),
                            },
                        },
                    ];
                }
                result
            },
        );
        assert_eq!(
            snapshot.properties[0].slider.as_ref().unwrap().precision,
            4_000_000_000
        );
        assert_eq!(snapshot.properties[0].slider.as_ref().unwrap().step, 0.0625);
        assert!(snapshot.properties[1].slider.is_none());
        assert!(snapshot.properties[1].file_filter.is_none());
        assert!(snapshot.properties[1].directory_mode.is_none());
        assert_eq!(
            snapshot.properties[3].combo_options[0].value,
            BridgePropertyValue::String { value: "2".into() }
        );
        assert_eq!(
            snapshot.properties[3].combo_options[1].label,
            "First second"
        );
    }

    #[test]
    fn missing_model_keeps_audio_consent_and_display_values() {
        let displays = [display(71, 0), display(93, 48), display(115, 165)];
        let selectors: Vec<_> = displays
            .iter()
            .map(|display| display.config_selector(&displays))
            .collect();
        let mut config = WallpaperConfig::new_for("value-study", "scene");
        config.media_integration_enabled = true;
        config.audio.volume = 0.375;
        config.audio.muted = true;
        config.audio.response_enabled = false;
        config.monitors = vec![
            MonitorRender {
                selector: selectors[1].clone(),
                ..MonitorRender::default()
            },
            MonitorRender {
                selector: selectors[2].clone(),
                scaling_mode: "fit".into(),
                scaling_factor: 1.25,
                frame_rate: Some(120),
                framing: FramingCfg {
                    pan_x: f64::NAN,
                    pan_y: 2.0,
                },
            },
        ];
        let mut draft =
            WallpaperOptionsDraft::from_committed_with_enabled_displays(config, selectors.clone());
        draft.set_display_enabled(selectors[1].clone(), false, &selectors);
        let result = project_options(
            &entry(),
            &draft,
            &selectors,
            None,
            &BTreeMap::new(),
            &AppConfig::default(),
            &displays,
            |_, _| panic!("no model annotation"),
        );
        assert!(result.properties.is_empty());
        assert!(result.media_integration_enabled && result.muted && result.dirty);
        assert!(!result.audio_response_enabled);
        assert_eq!(result.volume, 0.375);
        assert_eq!(result.display_configurations.len(), 3);
        let rows = &result.display_configurations;
        assert_eq!((rows[0].target_fps, rows[0].max_fps), (1, 1));
        assert!(!rows[0].dirty);
        assert_eq!((rows[1].target_fps, rows[1].max_fps), (48, 48));
        assert!(!rows[1].enabled && rows[1].dirty && rows[1].can_restore_defaults);
        assert_eq!((rows[2].target_fps, rows[2].max_fps), (120, 165));
        assert_eq!(rows[2].scaling_mode, BridgeScalingMode::Match);
        assert_eq!(rows[2].scaling_factor, 1.25);
        assert_eq!((rows[2].framing.pan_x, rows[2].framing.pan_y), (0.5, 1.0));
        assert!(rows[2].dirty);
        assert!(rows.iter().all(|row| row.muted && row.volume == 0.375));
        // A selector-matched explicit default is clean without assignment staging.
        let clean = WallpaperOptionsDraft::from_committed(draft.committed().clone());
        let baseline = project_options(
            &entry(),
            &clean,
            &selectors,
            None,
            &BTreeMap::new(),
            &AppConfig::default(),
            &displays,
            |_, _| unreachable!(),
        );
        assert!(!baseline.display_configurations[1].dirty);
    }

    #[test]
    fn eligibility_is_exact_and_settings_include_disabled_rows() {
        let displays = [
            display(81, 60),
            display(82, 60),
            display(83, 60),
            display(84, 60),
        ];
        let mut app = AppConfig::default().normalized(&displays);
        app.monitors[1].enabled = false;
        app.monitors[2].mode = "mirror".into();
        app.monitors[2].mirror_target = Some(SerializedSelector::Primary);
        app.monitors[3].mode = "MiRrOr".into();
        app.monitors[3].mirror_target = Some(SerializedSelector::Primary);
        app.monitors.push(MonitorCfg {
            selector: SerializedSelector::LiveDisplayId { display_id: 999 },
            wallpaper: Some("disconnected".into()),
            ..MonitorCfg::default()
        });
        let draft =
            WallpaperOptionsDraft::from_committed(WallpaperConfig::new_for("value-study", "scene"));
        let options = project_options(
            &entry(),
            &draft,
            &[],
            None,
            &BTreeMap::new(),
            &app,
            &displays,
            |_, _| unreachable!(),
        );
        assert_eq!(
            options
                .display_configurations
                .iter()
                .map(|row| row.display_id.clone())
                .collect::<Vec<_>>(),
            vec![
                "primary".to_owned(),
                displays[3].config_selector(&displays).id()
            ]
        );
        let normalized = app.normalized(&displays);
        let settings = project_settings_rows(
            &normalized,
            &displays,
            || -> std::iter::Empty<&BridgeDisplaySettingsRow> { panic!("must remain lazy") },
        );
        assert_eq!(settings.len(), 4);
        assert!(!settings[1].enabled);
        assert_eq!(settings[3].mode, BridgeDisplayMode::Mirror);
        assert_eq!(
            settings[3].selected_mirror_target.as_deref(),
            Some("primary")
        );
        assert_eq!(
            settings[0].mirror_targets,
            vec![settings[3].display_id.clone()]
        );
        assert_eq!(
            settings[1].mirror_targets,
            vec!["primary".to_owned(), settings[3].display_id.clone()]
        );
        // Repeated identical nonprimary inventory entries use the genuine domain
        // row route; no synthetic normalization or selector deduplication is added.
        let secondary = display(86, 60);
        let repeated = [display(85, 60), secondary.clone(), secondary];
        let normalized = AppConfig::default().normalized(&repeated);
        let repeated_rows = project_settings_rows(&normalized, &repeated, std::iter::empty);
        let secondary_id = repeated[1].config_selector(&repeated).id();
        assert_eq!(
            repeated_rows
                .iter()
                .filter(|row| row.display_id == secondary_id)
                .count(),
            2
        );
        for row in repeated_rows
            .iter()
            .filter(|row| row.display_id == secondary_id)
        {
            assert_eq!(row.mirror_targets, vec!["primary".to_owned()]);
        }
    }

    #[test]
    fn monitors_use_committed_target_render_but_own_refresh() {
        let displays = [display(201, 144), display(202, 47), display(203, 0)];
        let mut app = AppConfig::default().normalized(&displays);
        app.monitors[0].wallpaper = Some("saved-source".into());
        for row in &mut app.monitors[1..] {
            row.mode = "mirror".into();
            row.wallpaper = Some("ignored-own".into());
            row.mirror_target = Some(SerializedSelector::Primary);
        }
        let mut committed = WallpaperConfig::new_for("saved-source", "scene");
        committed.audio.response_enabled = false;
        committed.monitors.push(MonitorRender {
            selector: SerializedSelector::Primary,
            scaling_mode: "fit".into(),
            frame_rate: Some(110),
            ..MonitorRender::default()
        });
        let mut pending = WallpaperOptionsDraft::from_committed(committed.clone());
        pending.set_muted(true);
        let result = project_monitors(
            &app,
            &displays,
            |id| {
                if id == "saved-source" {
                    Some(&committed)
                } else {
                    None
                }
            },
            |id| {
                if id == "saved-source" {
                    Some("Saved library title")
                } else {
                    None
                }
            },
        );
        assert_eq!(result.rows.len(), 3);
        assert_eq!(
            result
                .rows
                .iter()
                .map(|row| row.target_fps.as_str())
                .collect::<Vec<_>>(),
            ["110", "47", "1"]
        );
        assert_eq!(result.rows[1].wallpaper_id, "saved-source");
        assert_eq!(result.rows[1].wallpaper_title, "Saved library title");
        assert_eq!(result.rows[1].scaling_mode, "Match");
        assert!(!result.rows[1].audio_response);
        assert_eq!(
            result.rows[1].mirror_target_display_id.as_deref(),
            Some("primary")
        );
        assert_eq!(
            result.rows[1].mirror_target_title,
            Some(displays[0].title_with_role(true))
        );
        assert!(
            result.rows[1]
                .title
                .ends_with("(202 - Secondary - saved-source)")
        );
        assert_ne!(result.rows[1].display_id, "202");
        assert_ne!(pending.current(), pending.committed());
    }

    #[test]
    fn monitor_target_presence_and_direct_assignment_are_not_recursive() {
        let displays = [display(301, 60), display(302, 60)];
        let mut app = AppConfig::default().normalized(&displays);
        app.monitors[1].mode = "mirror".into();
        app.monitors[1].wallpaper = Some("own".into());
        let rows = project_monitors(&app, &displays, |_| None, |_| None).rows;
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].wallpaper_title, "own");
        assert_eq!(rows[0].scaling_mode, "Fill");
        assert_eq!(rows[0].target_fps, "60");
        assert!(rows[0].audio_response);
        assert!(rows[0].mirror_target_display_id.is_none());
        app.monitors[1].mirror_target = Some(SerializedSelector::Primary);
        assert!(
            project_monitors(&app, &displays, |_| None, |_| None)
                .rows
                .is_empty()
        );
        app.monitors[1].mirror_target = Some(SerializedSelector::LiveDisplayId { display_id: 999 });
        assert!(
            project_monitors(&app, &displays, |_| None, |_| None)
                .rows
                .is_empty()
        );
        app.monitors[1].mirror_target = None;
        app.monitors[1].wallpaper = None;
        assert!(
            project_monitors(&app, &displays, |_| None, |_| None)
                .rows
                .is_empty()
        );
    }

    #[test]
    fn settings_app_values_rates_and_loaded_targets_are_not_choice_validation() {
        let displays = [display(401, 0), display(402, 49), display(403, 180)];
        let mut app = AppConfig::default().normalized(&displays);
        let last = displays[2].config_selector(&displays);
        app.monitors[2].enabled = false;
        app.monitors[1].mode = "mirror".into();
        app.monitors[1].mirror_target = Some(last.clone());
        app.monitor_settings.push(MonitorSettingsCfg {
            selector: last,
            scaling_mode: "stretch".into(),
            scaling_factor: 1.75,
            frame_rate: Some(140),
            muted: true,
            volume: 0.625,
        });
        let normalized = app.normalized(&displays);
        let rows = project_settings_rows(
            &normalized,
            &displays,
            || -> std::iter::Empty<&BridgeDisplaySettingsRow> { panic!("not empty") },
        );
        assert_eq!((rows[0].target_fps, rows[0].max_fps), (1, 1));
        assert_eq!((rows[1].target_fps, rows[1].max_fps), (49, 49));
        assert_eq!((rows[2].target_fps, rows[2].max_fps), (140, 180));
        assert_eq!(rows[2].scaling_mode, BridgeScalingMode::Stretch);
        assert_eq!(rows[2].scaling_factor, 1.75);
        assert!(rows[2].muted && !rows[2].enabled);
        assert_eq!(rows[2].volume, 0.625);
        assert_eq!(
            rows[1].selected_mirror_target,
            Some(rows[2].display_id.clone())
        );
        assert!(!rows[1].mirror_targets.contains(&rows[2].display_id));
        assert!(rows[1].mirror_targets.contains(&"primary".to_owned()));
        let remembered = vec![rows[2].clone(), rows[0].clone()];
        assert_eq!(
            project_settings_rows(&AppConfig::default(), &[], || rows.iter().rev().step_by(2)),
            remembered
        );
    }

    #[test]
    fn private_settings_row_preserves_unconfigured_live_fallback_and_target_resolution() {
        let mut displays = [display(501, 60), display(502, 60)];
        displays[1].assignment = Some(WallpaperAssignment::Mirror(DisplaySelector::Primary));
        let selector = displays[1].config_selector(&displays);
        let row = MonitorRow {
            selector: selector.clone(),
            config: MonitorCfg {
                selector,
                ..MonitorCfg::default()
            },
            connected: true,
            display_index: Some(1),
        };
        let app = AppConfig::default();
        let mirror = settings_row(&app, &displays, &row, &displays[1], vec!["primary".into()]);
        assert_eq!(mirror.mode, BridgeDisplayMode::Mirror);
        assert_eq!(mirror.selected_mirror_target.as_deref(), Some("primary"));
        displays[1].assignment = Some(WallpaperAssignment::Mirror(DisplaySelector::LiveDisplayId(
            502,
        )));
        assert!(
            settings_row(&app, &displays, &row, &displays[1], vec![])
                .selected_mirror_target
                .is_none()
        );
        displays[1].assignment = Some(WallpaperAssignment::Mirror(DisplaySelector::LiveDisplayId(
            999,
        )));
        assert!(
            settings_row(&app, &displays, &row, &displays[1], vec![])
                .selected_mirror_target
                .is_none()
        );
        displays[1].assignment = None;
        let standalone = settings_row(&app, &displays, &row, &displays[1], vec![]);
        assert_eq!(standalone.mode, BridgeDisplayMode::Standalone);
        assert!(standalone.selected_mirror_target.is_none());
    }

    #[test]
    fn role_ids_remain_stable_when_live_numeric_id_changes() {
        let first = [display(601, 60), display(602, 60)];
        let mut changed = first.clone();
        changed[0].desc.display_id = 701;
        changed[1].desc.display_id = 702;
        let app = AppConfig::default().normalized(&first);
        let before = project_settings_rows(&app, &first, std::iter::empty);
        let normalized = app.normalized(&changed);
        let after = project_settings_rows(&normalized, &changed, std::iter::empty);
        assert_eq!(
            before.iter().map(|row| &row.display_id).collect::<Vec<_>>(),
            after.iter().map(|row| &row.display_id).collect::<Vec<_>>()
        );
        assert_ne!(before[0].title, after[0].title);
        assert_ne!(before[1].title, after[1].title);
        assert!(after[0].title.ends_with("(701 - Primary)"));
        assert!(after[1].title.ends_with("(702)"));
    }
}
