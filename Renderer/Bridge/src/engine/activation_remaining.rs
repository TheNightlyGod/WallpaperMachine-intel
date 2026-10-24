use crate::BridgeError;
use crate::config::{MonitorCfg, MonitorSettingsCfg, SerializedSelector, WallpaperConfig};
use crate::display::{DisplayDescExt, DisplaySelectorExt};
use crate::engine::ActivationInputs;
use crate::project::scene_property_override_json;
use wallpaper_core::media::audio::AudioVolume;
use wallpaper_core::project::{ScalingMode, SceneDesc, SceneFraming, SceneTemplate};
use wallpaper_core::{
    DisplayDesc, DisplaySelector, DisplaySnapshotEntry, EngineError, WallpaperAssignment,
};

pub(super) fn visit_selected<'a>(
    inputs: &ActivationInputs<'a>,
    mut direct: impl FnMut(&'a MonitorCfg, &'a WallpaperConfig, &'a DisplaySnapshotEntry),
    mut mirror: impl FnMut(
        &'a MonitorCfg,
        &'a DisplaySnapshotEntry,
        u32,
        Option<&'a MonitorSettingsCfg>,
    ),
) {
    let mut occupied: Vec<&DisplayDesc> = Vec::new();
    for primary in [true, false] {
        for monitor in &inputs.app_config.monitors {
            if matches!(&monitor.selector, SerializedSelector::Primary) != primary {
                continue;
            }
            if !monitor.enabled {
                continue;
            }
            let Some(id) = monitor.wallpaper.as_deref() else {
                continue;
            };
            let Some(wallpaper) = inputs.wallpapers.get(id) else {
                continue;
            };
            if inputs
                .library
                .is_some_and(|library| !library.iter().any(|entry| entry.id == id))
            {
                log::debug!("Skipping assigned wallpaper {id:?}: missing library entry");
                continue;
            }
            if inputs.held.contains(id) {
                log::debug!("Skipping assigned wallpaper {id:?}: held");
                continue;
            }
            if monitor.mode == "mirror" {
                continue;
            }
            let Some(display) = monitor
                .selector
                .to_selector()
                .resolve_display(inputs.displays)
            else {
                continue;
            };
            if occupied
                .iter()
                .any(|accepted| accepted.same_physical_display(&display.desc))
            {
                continue;
            }
            occupied.push(&display.desc);
            direct(monitor, wallpaper, display);
        }
    }

    for monitor in &inputs.app_config.monitors {
        if !monitor.enabled || !monitor.mode.eq_ignore_ascii_case("mirror") {
            continue;
        }
        let Some(display) = monitor
            .selector
            .to_selector()
            .resolve_display(inputs.displays)
        else {
            continue;
        };
        if occupied
            .iter()
            .any(|accepted| accepted.same_physical_display(&display.desc))
        {
            continue;
        }
        let Some(target) = monitor.mirror_target.as_ref() else {
            continue;
        };
        let Some(target) = target.to_selector().resolve_display(inputs.displays) else {
            continue;
        };
        let settings = inputs
            .app_config
            .monitor_settings
            .iter()
            .find(|settings| settings.selector == monitor.selector);
        mirror(monitor, display, target.desc.display_id, settings);
    }
}

fn engine_error(error: EngineError) -> BridgeError {
    BridgeError::engine(error.to_string())
}

fn validated_volume(volume: f32) -> Result<AudioVolume, BridgeError> {
    AudioVolume::try_from(volume)
        .map_err(|error| engine_error(EngineError::InvalidInput(error.to_string())))
}

pub(super) fn build_configured_scene(
    inputs: &ActivationInputs<'_>,
    monitor: &MonitorCfg,
    wallpaper_id: &str,
    wallpaper: &WallpaperConfig,
    display: DisplayDesc,
) -> Result<SceneDesc, BridgeError> {
    let volume = validated_volume(wallpaper.audio.volume)?;
    let setting = super::render_settings::select_render_setting(
        &wallpaper.monitors,
        &monitor.selector,
        &display,
        inputs.displays,
    );
    let (scaling_mode, scaling_factor, framing, frame_rate) = match setting {
        Some(setting) => (
            setting.parse_scaling_mode(),
            setting.scaling_factor,
            setting.framing.to_scene(),
            setting.frame_rate,
        ),
        None => (ScalingMode::Fill, 1.0, SceneFraming::CENTERED, None),
    };
    let properties = if wallpaper.r#type.eq_ignore_ascii_case("scene") {
        scene_property_override_json(
            inputs.project_models.get(wallpaper_id),
            &wallpaper.property_overrides,
        )
    } else {
        None
    };
    let mut builder = SceneTemplate::builder(
        inputs
            .paths
            .project_json(wallpaper_id)
            .to_string_lossy()
            .into_owned(),
    )
    .assets_path(inputs.paths.assets_root().to_string_lossy().into_owned())
    .shader_cache_path(
        inputs
            .paths
            .shader_cache_root()
            .to_string_lossy()
            .into_owned(),
    )
    .fps(crate::config::resolve_frame_rate(
        frame_rate,
        display.refresh_rate_hz,
    ))
    .scaling_mode(scaling_mode)
    .scaling_factor(scaling_factor)
    .framing(framing)
    .paused(inputs.paused || inputs.suspended_displays.contains(&display.display_id))
    .audio_response_enabled(wallpaper.audio.response_enabled)
    .media_integration_enabled(wallpaper.media_integration_enabled)
    .audio_volume(f32::from(volume))
    .audio_muted(wallpaper.audio.muted)
    .force_shader_refresh(inputs.force_shader_refresh);
    if let Some(properties) = properties {
        builder = builder.property_override_json(properties);
    }
    Ok(builder.build().map_err(engine_error)?.for_display(display))
}

pub(super) fn build_mirror_scene(
    inputs: &ActivationInputs<'_>,
    source: &SceneDesc,
    display: DisplayDesc,
    settings: &MonitorSettingsCfg,
) -> Result<SceneDesc, BridgeError> {
    let volume = validated_volume(settings.volume)?;
    let mut scene = source.clone();
    scene.paused = inputs.paused || inputs.suspended_displays.contains(&display.display_id);
    scene.fps = settings.fps_on(display.refresh_rate_hz);
    scene.display = display;
    scene.scaling_mode = settings.parse_scaling_mode();
    scene.scaling_factor = settings.scaling_factor;
    scene.framing = SceneFraming::CENTERED;
    scene.audio_volume = volume;
    scene.audio_muted = settings.muted;
    scene.validate().map_err(engine_error)?;
    Ok(scene)
}

/// Builds the mirror assignments the saved configuration asks for.
///
/// A mirror is an assignment of its own kind: the display shows whatever its
/// source shows, so the engine needs to hear about it apart from the scenes.
pub trait WallpaperAssignmentExt {
    /// One pair per usable mirror monitor, in the order the config lists them.
    /// The source need not be connected; the engine decides what to show then.
    fn build_mirror_assignments(
        config: &crate::config::AppConfig,
        displays: &[DisplaySnapshotEntry],
    ) -> Vec<MirrorPair>;
}

/// The display that mirrors, and what it was told to show.
pub type MirrorPair = (DisplaySelector, WallpaperAssignment);

impl WallpaperAssignmentExt for WallpaperAssignment {
    fn build_mirror_assignments(
        config: &crate::config::AppConfig,
        displays: &[DisplaySnapshotEntry],
    ) -> Vec<MirrorPair> {
        config
            .monitors
            .iter()
            .filter(|monitor| monitor.enabled && monitor.mode == "mirror")
            .filter_map(|monitor| {
                let own = monitor.selector.to_selector();
                own.resolve_display(displays)?;
                let target = monitor.mirror_target.as_ref()?.to_selector();
                Some((own, WallpaperAssignment::Mirror(target)))
            })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::{AppConfig, FramingCfg, MonitorRender};
    use crate::paths::BridgePaths;
    use crate::project::ProjectModel;
    use crate::{BridgeErrorKind, BridgeWallpaperEntry, BridgeWallpaperKind};
    use serde_json::{Value, json};
    use std::cell::RefCell;
    use std::collections::{BTreeMap, BTreeSet};
    use std::ptr;
    use wallpaper_core::DisplayIdentity;

    struct Data {
        config: AppConfig,
        wallpapers: BTreeMap<String, WallpaperConfig>,
        displays: Vec<DisplaySnapshotEntry>,
        paths: BridgePaths,
        models: BTreeMap<String, ProjectModel>,
        held: BTreeSet<String>,
        suspended: BTreeSet<u32>,
    }

    impl Data {
        fn new(displays: Vec<DisplaySnapshotEntry>) -> Self {
            Self {
                config: AppConfig::default(),
                wallpapers: BTreeMap::new(),
                displays,
                paths: BridgePaths::for_home("independent-fixture-house"),
                models: BTreeMap::new(),
                held: BTreeSet::new(),
                suspended: BTreeSet::new(),
            }
        }

        fn inputs(&self) -> ActivationInputs<'_> {
            ActivationInputs {
                app_config: &self.config,
                wallpapers: &self.wallpapers,
                library: None,
                displays: &self.displays,
                paused: false,
                suspended_displays: &self.suspended,
                paths: &self.paths,
                force_shader_refresh: false,
                project_models: &self.models,
                frame_rate_cap: None,
                audio_suppressed: false,
                held: &self.held,
            }
        }

        fn add(&mut self, selector: SerializedSelector, id: &str) {
            self.config.monitors.push(direct(selector, id));
            self.wallpapers
                .entry(id.into())
                .or_insert_with(|| WallpaperConfig::new_for(format!("saved-{id}"), "scene"));
        }
    }

    fn live(display_id: u32) -> SerializedSelector {
        SerializedSelector::LiveDisplayId { display_id }
    }

    fn uuid(value: &str) -> DisplayIdentity {
        DisplayIdentity {
            uuid: Some(value.into()),
            ..DisplayIdentity::default()
        }
    }

    fn identity(value: &DisplayIdentity) -> SerializedSelector {
        SerializedSelector::Identity {
            uuid: value.uuid.clone(),
            vendor_id: value.vendor_id,
            model_id: value.model_id,
            serial_number: value.serial_number,
            unit_number: value.unit_number,
            name: value.name.clone(),
        }
    }

    fn display(id: u32, refresh: u32, tag: &str) -> DisplaySnapshotEntry {
        let identity = uuid(tag);
        DisplaySnapshotEntry {
            identity: identity.clone(),
            desc: DisplayDesc {
                display_id: id,
                identity,
                x: 0,
                y: 0,
                width: 960,
                height: 540,
                scale_factor: 1.0,
                refresh_rate_hz: refresh,
            },
            handle: None,
            accepts_pointer_input: false,
            paused: false,
            window_active: false,
            assignment: None,
        }
    }

    fn direct(selector: SerializedSelector, id: &str) -> MonitorCfg {
        MonitorCfg {
            selector,
            wallpaper: Some(id.into()),
            ..MonitorCfg::default()
        }
    }

    fn mirror(selector: SerializedSelector, target: SerializedSelector) -> MonitorCfg {
        MonitorCfg {
            selector,
            mode: "mirror".into(),
            mirror_target: Some(target),
            ..MonitorCfg::default()
        }
    }

    type Direct<'a> = (
        &'a MonitorCfg,
        &'a WallpaperConfig,
        &'a DisplaySnapshotEntry,
    );
    type Mirror<'a> = (
        &'a MonitorCfg,
        &'a DisplaySnapshotEntry,
        u32,
        Option<&'a MonitorSettingsCfg>,
    );

    fn decisions<'a>(inputs: &ActivationInputs<'a>) -> (Vec<Direct<'a>>, Vec<Mirror<'a>>) {
        let mut direct = Vec::new();
        let mut mirror = Vec::new();
        visit_selected(
            inputs,
            |m, w, d| direct.push((m, w, d)),
            |m, d, t, s| mirror.push((m, d, t, s)),
        );
        (direct, mirror)
    }

    fn assignments(data: &Data) -> Vec<(DisplaySelector, WallpaperAssignment)> {
        <WallpaperAssignment as WallpaperAssignmentExt>::build_mirror_assignments(
            &data.config,
            &data.displays,
        )
    }

    fn configured(data: &Data, id: &str, display_index: usize) -> SceneDesc {
        build_configured_scene(
            &data.inputs(),
            &direct(live(data.displays[display_index].desc.display_id), id),
            id,
            &data.wallpapers[id],
            data.displays[display_index].desc.clone(),
        )
        .unwrap()
    }

    fn assert_engine(error: BridgeError, expected: EngineError) {
        assert_eq!(error.kind(), BridgeErrorKind::Engine);
        assert_eq!(error.message(), expected.to_string());
    }

    fn volume_error(value: f32) -> EngineError {
        EngineError::InvalidInput(AudioVolume::try_from(value).unwrap_err().to_string())
    }

    fn parsed_document(scene: &SceneDesc) -> Option<Value> {
        scene
            .property_override_json
            .as_deref()
            .map(|document| serde_json::from_str(document).unwrap())
    }

    #[test]
    fn ar01_empty_and_ineligible_records_and_present_empty_key() {
        let mut data = Data::new(vec![display(311, 48, "one")]);
        assert!(decisions(&data.inputs()).0.is_empty());
        assert!(decisions(&data.inputs()).1.is_empty());
        assert!(assignments(&data).is_empty());
        data.add(live(311), "loaded");
        data.config.monitors[0].enabled = false;
        data.config.monitors.push(MonitorCfg::default());
        data.config.monitors.push(direct(live(311), "not-loaded"));
        data.config.monitors.push(direct(live(999), "loaded"));
        assert!(decisions(&data.inputs()).0.is_empty());
        data.add(live(311), "");
        let selected = decisions(&data.inputs()).0;
        assert_eq!(selected.len(), 1);
        assert!(ptr::eq(selected[0].0, &data.config.monitors[4]));
        assert!(ptr::eq(selected[0].1, &data.wallpapers[""]));
        data.config.monitors.push(mirror(live(311), live(311)));
        data.displays.clear();
        let (direct, mirror) = decisions(&data.inputs());
        assert!(direct.is_empty() && mirror.is_empty());
        assert!(assignments(&data).is_empty());
    }

    #[test]
    fn ar02_primary_priority_saved_order_and_ineligible_nonreservation() {
        let mut data = Data::new(vec![
            display(731, 60, "first"),
            display(19, 60, "second"),
            display(83, 60, "third"),
        ]);
        data.add(live(731), "early-live");
        data.add(SerializedSelector::Primary, "first-primary");
        data.add(SerializedSelector::Primary, "second-primary");
        data.add(live(83), "third");
        data.add(live(19), "second");
        let selected = decisions(&data.inputs()).0;
        assert_eq!(
            selected
                .iter()
                .map(|(_, _, d)| d.desc.display_id)
                .collect::<Vec<_>>(),
            [731, 83, 19]
        );
        assert!(ptr::eq(selected[0].0, &data.config.monitors[1]));
        assert!(ptr::eq(selected[1].0, &data.config.monitors[3]));
        assert!(ptr::eq(selected[2].0, &data.config.monitors[4]));
        data.config.monitors[1].enabled = false;
        data.wallpapers.remove("second-primary");
        assert!(ptr::eq(
            decisions(&data.inputs()).0[0].0,
            &data.config.monitors[0]
        ));
        data.config.monitors[1].enabled = true;
        data.held.insert("first-primary".into());
        assert!(ptr::eq(
            decisions(&data.inputs()).0[0].0,
            &data.config.monitors[0]
        ));
    }

    #[test]
    fn ar03_physical_dedup_and_independent_reuse() {
        let mut data = Data::new(vec![
            display(311, 48, "same"),
            display(312, 48, "same"),
            display(313, 48, "other"),
        ]);
        data.add(live(311), "shared");
        data.add(identity(&uuid("same")), "alias");
        data.add(live(312), "alias");
        data.add(live(313), "shared");
        let selected = decisions(&data.inputs()).0;
        assert_eq!(selected.len(), 2);
        assert!(ptr::eq(selected[0].0, &data.config.monitors[0]));
        assert!(ptr::eq(selected[1].0, &data.config.monitors[3]));
        assert!(ptr::eq(selected[0].1, selected[1].1));
        let unit = DisplayIdentity {
            vendor_id: Some(71),
            model_id: Some(82),
            unit_number: Some(6),
            ..DisplayIdentity::default()
        };
        data.displays[0].identity = unit.clone();
        data.displays[0].desc.identity = unit.clone();
        data.displays[1].identity = unit.clone();
        data.displays[1].desc.identity = unit;
        data.config.monitors = vec![
            direct(live(311), "shared"),
            direct(live(312), "alias"),
            direct(live(313), "shared"),
        ];
        let selected = decisions(&data.inputs()).0;
        assert_eq!(
            selected
                .iter()
                .map(|(_, _, d)| d.desc.display_id)
                .collect::<Vec<_>>(),
            [311, 313]
        );
    }

    #[test]
    fn ar04_resolution_is_first_match_and_dedup_uses_descriptor_identity() {
        let mut first = display(311, 48, "temporary");
        first.identity = DisplayIdentity {
            vendor_id: Some(71),
            model_id: Some(82),
            unit_number: Some(6),
            ..DisplayIdentity::default()
        };
        let mut stronger = display(312, 48, "stronger");
        stronger.identity = DisplayIdentity {
            uuid: Some("requested".into()),
            vendor_id: Some(71),
            model_id: Some(82),
            serial_number: Some(93),
            unit_number: Some(6),
            name: Some("named".into()),
        };
        let requested = stronger.identity.clone();
        first.desc.identity = uuid("descriptor-alias");
        stronger.desc.identity = uuid("descriptor-alias");
        let mut data = Data::new(vec![first, stronger]);
        data.add(identity(&requested), "first");
        data.add(live(312), "second");
        data.add(live(999), "first");
        let selected = decisions(&data.inputs()).0;
        assert_eq!(selected.len(), 1);
        assert!(ptr::eq(selected[0].2, &data.displays[0]));
        assert!(ptr::eq(selected[0].0, &data.config.monitors[0]));
        data.config.monitors.remove(0);
        let selected = decisions(&data.inputs()).0;
        assert_eq!(selected.len(), 1);
        assert!(ptr::eq(selected[0].2, &data.displays[1]));
        data.displays[1].desc.identity = uuid("physically-different");
        data.config
            .monitors
            .insert(0, direct(identity(&requested), "first"));
        assert_eq!(decisions(&data.inputs()).0.len(), 2);
    }

    #[test]
    fn ar05_library_and_hold_are_reversible_nonmutating_filters() {
        let mut data = Data::new(vec![display(311, 48, "one")]);
        data.add(live(311), "blocked");
        data.add(live(311), "later");
        data.config
            .monitor_settings
            .push(MonitorSettingsCfg::default());
        let config = data.config.clone();
        let wallpapers = data.wallpapers.clone();
        assert!(ptr::eq(
            decisions(&data.inputs()).0[0].0,
            &data.config.monitors[0]
        ));
        let empty = [];
        let mut inputs = data.inputs();
        inputs.library = Some(&empty);
        assert!(decisions(&inputs).0.is_empty());
        let later_only = [BridgeWallpaperEntry {
            id: "later".into(),
            title: "irrelevant".into(),
            kind: BridgeWallpaperKind::Unknown,
            supported: false,
            active: false,
            selected: false,
            preview_path: None,
        }];
        inputs.library = Some(&later_only);
        assert!(ptr::eq(decisions(&inputs).0[0].0, &data.config.monitors[1]));
        let both = [
            BridgeWallpaperEntry {
                id: "blocked".into(),
                ..later_only[0].clone()
            },
            later_only[0].clone(),
        ];
        inputs.library = Some(&both);
        assert!(ptr::eq(decisions(&inputs).0[0].0, &data.config.monitors[0]));
        data.held.insert("blocked".into());
        assert!(ptr::eq(
            decisions(&data.inputs()).0[0].0,
            &data.config.monitors[1]
        ));
        data.held.clear();
        assert!(ptr::eq(
            decisions(&data.inputs()).0[0].0,
            &data.config.monitors[0]
        ));
        assert_eq!(data.config, config);
        assert_eq!(data.wallpapers, wallpapers);
    }

    #[test]
    fn ar06_three_distinct_mode_predicates() {
        let mut data = Data::new(vec![
            display(311, 48, "one"),
            display(312, 48, "two"),
            display(313, 48, "three"),
        ]);
        data.add(live(311), "loaded");
        data.config.monitors[0].mode = "MiRrOr".into();
        data.config.monitors[0].mirror_target = Some(live(313));
        let mut unloaded = mirror(live(312), live(313));
        unloaded.mode = "MiRrOr".into();
        data.config.monitors.push(unloaded);
        let mut exact = mirror(live(313), live(311));
        exact.wallpaper = Some("loaded".into());
        data.config.monitors.push(exact);
        let (direct, mirror) = decisions(&data.inputs());
        assert_eq!(direct.len(), 1);
        assert!(ptr::eq(direct[0].0, &data.config.monitors[0]));
        assert_eq!(
            mirror
                .iter()
                .map(|(_, d, _, _)| d.desc.display_id)
                .collect::<Vec<_>>(),
            [312, 313]
        );
        assert_eq!(
            assignments(&data),
            vec![(
                DisplaySelector::LiveDisplayId(313),
                WallpaperAssignment::Mirror(DisplaySelector::LiveDisplayId(311))
            )]
        );
        data.config.monitors[0].mode = "future-mode".into();
        assert_eq!(decisions(&data.inputs()).0.len(), 1);
    }

    #[test]
    fn ar07_mirror_order_resolution_and_unrestricted_targets() {
        let mut data = Data::new(vec![
            display(311, 48, "one"),
            display(312, 48, "two"),
            display(313, 48, "three"),
            display(314, 48, "three"),
        ]);
        data.add(live(313), "direct");
        data.config.monitors.extend([
            mirror(live(312), live(311)),
            mirror(SerializedSelector::Primary, live(312)),
            mirror(live(313), live(311)),
            mirror(live(314), live(313)),
            mirror(live(999), live(311)),
            mirror(live(311), live(999)),
            MonitorCfg {
                selector: live(311),
                mode: "mirror".into(),
                ..MonitorCfg::default()
            },
            mirror(live(312), live(312)),
        ]);
        data.config.monitors[1].wallpaper = Some("held-without-loaded-config".into());
        data.held.insert("held-without-loaded-config".into());
        let empty = [];
        let mut inputs = data.inputs();
        // Only the direct loaded assignment has a library entry; mirror wallpaper eligibility is irrelevant.
        let library = [BridgeWallpaperEntry {
            id: "direct".into(),
            title: String::new(),
            kind: BridgeWallpaperKind::Unknown,
            supported: false,
            active: false,
            selected: false,
            preview_path: None,
        }];
        inputs.library = Some(&library);
        let (direct, mirrors) = decisions(&inputs);
        assert_eq!(direct.len(), 1);
        assert_eq!(
            mirrors
                .iter()
                .map(|(_, d, t, _)| (d.desc.display_id, *t))
                .collect::<Vec<_>>(),
            [(312, 311), (311, 312), (312, 312)]
        );
        assert!(ptr::eq(mirrors[0].0, &data.config.monitors[1]));
        assert!(ptr::eq(mirrors[1].0, &data.config.monitors[2]));
        inputs.library = Some(&empty);
        assert!(decisions(&inputs).0.is_empty());
        // Neither an own live ID nor a physical alias remains reserved after direct omission.
        assert_eq!(decisions(&inputs).1.len(), 5);
    }

    #[test]
    fn ar08_duplicate_candidates_and_first_exact_borrowed_settings() {
        let mut data = Data::new(vec![
            display(311, 165, "one"),
            display(312, 48, "two"),
            display(313, 48, "three"),
        ]);
        data.config.monitors = vec![
            mirror(live(312), live(311)),
            mirror(live(312), live(311)),
            mirror(live(313), live(311)),
        ];
        data.config.monitor_settings = vec![
            MonitorSettingsCfg {
                selector: identity(&uuid("two")),
                volume: 0.1,
                ..MonitorSettingsCfg::default()
            },
            MonitorSettingsCfg {
                selector: live(311),
                volume: 0.2,
                ..MonitorSettingsCfg::default()
            },
            MonitorSettingsCfg {
                selector: live(312),
                volume: 0.3,
                ..MonitorSettingsCfg::default()
            },
            MonitorSettingsCfg {
                selector: live(312),
                volume: 0.4,
                ..MonitorSettingsCfg::default()
            },
        ];
        data.add(live(311), "loaded");
        let wallpaper = data.wallpapers.get_mut("loaded").unwrap();
        wallpaper.audio.volume = 0.23;
        wallpaper.audio.muted = true;
        wallpaper.monitors.push(MonitorRender {
            selector: live(311),
            scaling_mode: "fit".into(),
            scaling_factor: 1.7,
            frame_rate: Some(137),
            framing: FramingCfg {
                pan_x: 0.2,
                pan_y: 0.8,
            },
        });
        let mirrors = decisions(&data.inputs()).1;
        assert_eq!(mirrors.len(), 3);
        assert!(ptr::eq(
            mirrors[0].3.unwrap(),
            &data.config.monitor_settings[2]
        ));
        assert!(ptr::eq(
            mirrors[1].3.unwrap(),
            &data.config.monitor_settings[2]
        ));
        assert!(mirrors[2].3.is_none());
        assert_eq!(mirrors[2].0.selector, live(313));
        let owned = data.inputs().build_owned().unwrap();
        assert_eq!(
            owned
                .iter()
                .map(|(scene, owner)| (scene.display.display_id, owner.as_str()))
                .collect::<Vec<_>>(),
            [(311, "loaded"), (312, "loaded"), (313, "loaded")]
        );
        let source = &owned[0].0;
        assert_eq!(
            (source.scaling_mode, source.scaling_factor, source.fps),
            (ScalingMode::Fit, 1.7, 137)
        );
        assert_eq!(
            source.framing,
            SceneFraming {
                pan_x: 0.2,
                pan_y: 0.8
            }
        );
        assert_eq!(f32::from(source.audio_volume), 0.23);
        assert!(source.audio_muted);
        let defaulted_mirror = &owned[2].0;
        assert_eq!(defaulted_mirror.display, data.displays[2].desc);
        assert_eq!(
            (
                defaulted_mirror.scaling_mode,
                defaulted_mirror.scaling_factor,
                defaulted_mirror.fps
            ),
            (ScalingMode::Fill, 1.0, 48)
        );
        assert_eq!(defaulted_mirror.framing, SceneFraming::CENTERED);
        assert_eq!(f32::from(defaulted_mirror.audio_volume), 1.0);
        assert!(!defaulted_mirror.audio_muted);
        assert!(!defaulted_mirror.paused);
        assert_eq!(
            data.inputs().build().unwrap(),
            owned
                .into_iter()
                .map(|(scene, _)| scene)
                .collect::<Vec<_>>()
        );
    }

    #[test]
    fn ar09_callbacks_borrow_actual_records_beyond_wrapper_and_emit_in_phases() {
        let mut data = Data::new(vec![display(311, 48, "one"), display(312, 48, "two")]);
        data.config.monitors.push(mirror(live(312), live(311)));
        data.add(live(311), "loaded");
        data.config.monitor_settings.push(MonitorSettingsCfg {
            selector: live(312),
            ..MonitorSettingsCfg::default()
        });
        let before_config = data.config.clone();
        let before_wallpapers = data.wallpapers.clone();
        let before_displays = data.displays.clone();
        let events = RefCell::new(Vec::new());
        let mut direct_refs = Vec::new();
        let mut mirror_refs = Vec::new();
        {
            let temporary = data.inputs();
            visit_selected(
                &temporary,
                |m, w, d| {
                    events.borrow_mut().push("direct");
                    direct_refs.push((m, w, d));
                },
                |m, d, t, s| {
                    events.borrow_mut().push("mirror");
                    mirror_refs.push((m, d, t, s));
                },
            );
        }
        assert_eq!(*events.borrow(), ["direct", "mirror"]);
        assert!(ptr::eq(direct_refs[0].0, &data.config.monitors[1]));
        assert!(ptr::eq(direct_refs[0].1, &data.wallpapers["loaded"]));
        assert!(ptr::eq(direct_refs[0].2, &data.displays[0]));
        assert!(ptr::eq(mirror_refs[0].0, &data.config.monitors[0]));
        assert!(ptr::eq(mirror_refs[0].1, &data.displays[1]));
        assert!(ptr::eq(
            mirror_refs[0].3.unwrap(),
            &data.config.monitor_settings[0]
        ));
        assert_eq!(data.config, before_config);
        assert_eq!(data.wallpapers, before_wallpapers);
        assert_eq!(data.displays, before_displays);
    }

    #[test]
    fn ar10_configured_scene_sets_all_fields_and_uses_assigned_key() {
        let mut data = Data::new(vec![display(311, 48, "one")]);
        data.add(live(311), "assigned-key");
        let wallpaper = data.wallpapers.get_mut("assigned-key").unwrap();
        wallpaper.workshop_id = "different-saved-id".into();
        wallpaper.audio.volume = 0.35;
        wallpaper.audio.response_enabled = false;
        wallpaper.audio.muted = true;
        wallpaper.media_integration_enabled = true;
        wallpaper.monitors.push(MonitorRender {
            selector: live(311),
            scaling_mode: "FiT".into(),
            scaling_factor: 1.75,
            frame_rate: Some(37),
            framing: FramingCfg {
                pan_x: 0.2,
                pan_y: 0.8,
            },
        });
        data.models.insert("assigned-key".into(), ProjectModel::parse("model-other-id", r#"{"type":"scene","general":{"properties":{"rewind_previous_action":{"type":"usershortcut","value":""}}}}"#).unwrap());
        data.models.insert(
            "different-saved-id".into(),
            ProjectModel::parse("different-saved-id", "{}").unwrap(),
        );
        data.suspended.insert(311);
        let mut inputs = data.inputs();
        inputs.force_shader_refresh = true;
        let scene = build_configured_scene(
            &inputs,
            &data.config.monitors[0],
            "assigned-key",
            &data.wallpapers["assigned-key"],
            data.displays[0].desc.clone(),
        )
        .unwrap();
        assert_eq!(scene.display, data.displays[0].desc);
        assert_eq!(
            scene.scene_path,
            data.paths.project_json("assigned-key").to_string_lossy()
        );
        assert!(!std::path::Path::new(&scene.scene_path).is_absolute());
        assert_eq!(
            scene.assets_path,
            data.paths.assets_root().to_string_lossy()
        );
        assert_eq!(
            scene.shader_cache_path.as_deref(),
            Some(data.paths.shader_cache_root().to_string_lossy().as_ref())
        );
        assert_eq!(scene.fps, 37);
        assert_eq!(scene.scaling_mode, ScalingMode::Fit);
        assert_eq!(scene.scaling_factor, 1.75);
        assert_eq!(
            scene.framing,
            SceneFraming {
                pan_x: 0.2,
                pan_y: 0.8
            }
        );
        assert!(scene.paused);
        assert!(!scene.audio_response_enabled);
        assert!(scene.media_integration_enabled && scene.audio_muted && scene.force_shader_refresh);
        assert_eq!(f32::from(scene.audio_volume), 0.35);
        assert_eq!(
            parsed_document(&scene),
            Some(json!({"rewind_previous_action":"media:previous"}))
        );
    }

    #[test]
    fn ar11_defaults_exact_lookup_fallback_rate_and_scaling() {
        let mut data = Data::new(vec![display(311, 165, "one")]);
        data.add(live(311), "loaded");
        let default = configured(&data, "loaded", 0);
        assert_eq!(
            (
                default.scaling_mode,
                default.scaling_factor,
                default.framing,
                default.fps
            ),
            (ScalingMode::Fill, 1.0, SceneFraming::CENTERED, 60)
        );
        data.displays[0].desc.refresh_rate_hz = 48;
        assert_eq!(configured(&data, "loaded", 0).fps, 48);
        data.displays[0].desc.refresh_rate_hz = 165;
        data.wallpapers.get_mut("loaded").unwrap().monitors = vec![
            MonitorRender {
                selector: identity(&uuid("one")),
                scaling_factor: 2.0,
                ..MonitorRender::default()
            },
            MonitorRender {
                selector: live(311),
                scaling_mode: "sTrEtCh".into(),
                scaling_factor: 3.0,
                frame_rate: Some(240),
                ..MonitorRender::default()
            },
        ];
        let exact = configured(&data, "loaded", 0);
        assert_eq!(
            (exact.scaling_mode, exact.scaling_factor, exact.fps),
            (ScalingMode::Stretch, 3.0, 165)
        );
        data.wallpapers.get_mut("loaded").unwrap().monitors.pop();
        assert_eq!(configured(&data, "loaded", 0).scaling_factor, 2.0);
        let wallpaper = data.wallpapers.get_mut("loaded").unwrap();
        wallpaper.monitors[0].selector = live(311);
        wallpaper.monitors[0].frame_rate = Some(0);
        wallpaper.monitors[0].scaling_mode = "NoNe".into();
        let scene = configured(&data, "loaded", 0);
        assert_eq!((scene.fps, scene.scaling_mode), (1, ScalingMode::None));
        data.displays[0].desc.refresh_rate_hz = 0;
        data.wallpapers.get_mut("loaded").unwrap().monitors[0].frame_rate = None;
        data.wallpapers.get_mut("loaded").unwrap().monitors[0].scaling_mode = "unrecognized".into();
        let scene = configured(&data, "loaded", 0);
        assert_eq!((scene.fps, scene.scaling_mode), (1, ScalingMode::Fill));
    }

    #[test]
    fn ar12_framing_normalization_and_real_template_factor_errors() {
        let mut data = Data::new(vec![display(311, 48, "one")]);
        data.add(live(311), "loaded");
        data.wallpapers
            .get_mut("loaded")
            .unwrap()
            .monitors
            .push(MonitorRender {
                selector: live(311),
                framing: FramingCfg {
                    pan_x: -2.0,
                    pan_y: 4.0,
                },
                ..MonitorRender::default()
            });
        assert_eq!(
            configured(&data, "loaded", 0).framing,
            SceneFraming {
                pan_x: 0.0,
                pan_y: 1.0
            }
        );
        data.wallpapers.get_mut("loaded").unwrap().monitors[0].framing = FramingCfg {
            pan_x: f64::NAN,
            pan_y: 0.3,
        };
        assert_eq!(
            configured(&data, "loaded", 0).framing,
            SceneFraming {
                pan_x: 0.5,
                pan_y: 0.3
            }
        );
        data.wallpapers.get_mut("loaded").unwrap().monitors[0].framing = FramingCfg {
            pan_x: 0.7,
            pan_y: f64::INFINITY,
        };
        assert_eq!(
            configured(&data, "loaded", 0).framing,
            SceneFraming {
                pan_x: 0.7,
                pan_y: 0.5
            }
        );
        for factor in [0.0, -1.0, f64::NAN, f64::INFINITY] {
            data.wallpapers.get_mut("loaded").unwrap().monitors[0].scaling_factor = factor;
            let expected = SceneTemplate::builder("independent-project.json")
                .fps(48)
                .scaling_factor(factor)
                .framing(SceneFraming::CENTERED)
                .audio_volume(1.0)
                .build()
                .unwrap_err();
            let error = build_configured_scene(
                &data.inputs(),
                &data.config.monitors[0],
                "loaded",
                &data.wallpapers["loaded"],
                data.displays[0].desc.clone(),
            )
            .unwrap_err();
            assert_engine(error, expected);
        }
    }

    #[test]
    fn ar13_direct_volume_priority_raw_display_and_no_transient_normalization() {
        let mut data = Data::new(vec![display(311, 165, "one")]);
        data.add(live(311), "loaded");
        data.wallpapers
            .get_mut("loaded")
            .unwrap()
            .monitors
            .push(MonitorRender {
                selector: live(311),
                scaling_factor: 0.0,
                ..MonitorRender::default()
            });
        let mut invalid_display = data.displays[0].desc.clone();
        invalid_display.display_id = 0;
        invalid_display.width = 0;
        invalid_display.height = 0;
        for volume in [-0.2, 1.2, f32::NAN, f32::INFINITY] {
            data.wallpapers.get_mut("loaded").unwrap().audio.volume = volume;
            let error = build_configured_scene(
                &data.inputs(),
                &data.config.monitors[0],
                "loaded",
                &data.wallpapers["loaded"],
                invalid_display.clone(),
            )
            .unwrap_err();
            assert_engine(error, volume_error(volume));
        }
        data.wallpapers.get_mut("loaded").unwrap().audio.volume = 0.0;
        data.wallpapers.get_mut("loaded").unwrap().monitors[0].scaling_factor = 1.0;
        let raw = build_configured_scene(
            &data.inputs(),
            &data.config.monitors[0],
            "loaded",
            &data.wallpapers["loaded"],
            invalid_display.clone(),
        )
        .unwrap();
        assert_eq!(raw.display, invalid_display);
        assert_eq!(f32::from(raw.audio_volume), 0.0);
        data.wallpapers.get_mut("loaded").unwrap().audio.volume = 1.0;
        data.wallpapers.get_mut("loaded").unwrap().monitors[0].frame_rate = Some(120);
        let mut inputs = data.inputs();
        inputs.frame_rate_cap = Some(24);
        inputs.audio_suppressed = true;
        let raw = build_configured_scene(
            &inputs,
            &data.config.monitors[0],
            "loaded",
            &data.wallpapers["loaded"],
            data.displays[0].desc.clone(),
        )
        .unwrap();
        assert_eq!(raw.fps, 120);
        assert!(!raw.audio_muted);
        assert_eq!(f32::from(raw.audio_volume), 1.0);
    }

    #[test]
    fn ar14_pause_and_saved_flags_are_independent() {
        let mut data = Data::new(vec![display(311, 48, "one")]);
        data.add(live(311), "loaded");
        for global in [false, true] {
            for suspended in [false, true] {
                data.suspended = if suspended {
                    BTreeSet::from([311, 999])
                } else {
                    BTreeSet::from([999])
                };
                let mut inputs = data.inputs();
                inputs.paused = global;
                let scene = build_configured_scene(
                    &inputs,
                    &data.config.monitors[0],
                    "loaded",
                    &data.wallpapers["loaded"],
                    data.displays[0].desc.clone(),
                )
                .unwrap();
                assert_eq!(scene.paused, global || suspended);
            }
        }
        data.suspended.clear();
        for flag in 0..4 {
            let wallpaper = data.wallpapers.get_mut("loaded").unwrap();
            wallpaper.audio.response_enabled = flag == 0;
            wallpaper.media_integration_enabled = flag == 1;
            wallpaper.audio.muted = flag == 2;
            let mut inputs = data.inputs();
            inputs.force_shader_refresh = flag == 3;
            let scene = build_configured_scene(
                &inputs,
                &data.config.monitors[0],
                "loaded",
                &data.wallpapers["loaded"],
                data.displays[0].desc.clone(),
            )
            .unwrap();
            assert_eq!(scene.audio_response_enabled, flag == 0);
            assert_eq!(scene.media_integration_enabled, flag == 1);
            assert_eq!(scene.audio_muted, flag == 2);
            assert_eq!(scene.force_shader_refresh, flag == 3);
        }
    }

    #[test]
    fn ar15_property_documents_use_real_parsed_defaults_overrides_and_saved_type() {
        let mut data = Data::new(vec![display(311, 48, "one")]);
        data.add(live(311), "loaded");
        assert_eq!(parsed_document(&configured(&data, "loaded", 0)), None);
        data.wallpapers
            .get_mut("loaded")
            .unwrap()
            .property_overrides
            .insert("undeclared_scalar".into(), json!(17));
        let document = parsed_document(&configured(&data, "loaded", 0)).unwrap();
        assert_eq!(
            document
                .as_object()
                .unwrap()
                .keys()
                .map(String::as_str)
                .collect::<Vec<_>>(),
            ["undeclared_scalar"]
        );
        assert_eq!(document["undeclared_scalar"].as_f64(), Some(17.0));
        data.wallpapers
            .get_mut("loaded")
            .unwrap()
            .property_overrides
            .clear();
        let authored = ProjectModel::parse("parsed-independent", r#"{"type":"scene","general":{"properties":{"authored_switch":{"type":"bool","value":true},"authored_shortcut":{"type":"usershortcut","value":"custom:action"}}}}"#).unwrap();
        assert!(
            authored
                .properties
                .iter()
                .all(|property| !property.default_is_host_supplied)
        );
        data.models.insert("loaded".into(), authored);
        assert_eq!(parsed_document(&configured(&data, "loaded", 0)), None);
        let model = ProjectModel::parse("parsed-independent", r#"{"type":"video","general":{"properties":{"step_previous_action":{"type":"usershortcut","value":""},"authored_switch":{"type":"bool","value":true},"picked_file":{"type":"file","value":"base.txt"},"picked_directory":{"type":"directory","value":"base"},"picked_texture":{"type":"texture","value":"base.png"}}}}"#).unwrap();
        assert!(
            model
                .properties
                .iter()
                .any(|property| property.id == "step_previous_action"
                    && property.default_is_host_supplied)
        );
        data.models.insert("loaded".into(), model);
        data.wallpapers.get_mut("loaded").unwrap().r#type = "ScEnE".into();
        assert_eq!(
            parsed_document(&configured(&data, "loaded", 0)),
            Some(json!({"step_previous_action":"media:previous"}))
        );
        data.wallpapers
            .get_mut("loaded")
            .unwrap()
            .property_overrides
            .insert("step_previous_action".into(), json!("custom:rewind"));
        assert_eq!(
            parsed_document(&configured(&data, "loaded", 0)),
            Some(json!({"step_previous_action":"custom:rewind"}))
        );
        let overrides = BTreeMap::from([
            ("step_previous_action".into(), json!("")),
            ("picked_file".into(), json!("other.txt")),
            ("picked_directory".into(), json!("nested/other")),
            ("picked_texture".into(), json!("other.png")),
            ("unknown_property".into(), json!(false)),
            ("ordinary_text".into(), json!("independent text")),
        ]);
        data.wallpapers
            .get_mut("loaded")
            .unwrap()
            .property_overrides = overrides;
        let document = parsed_document(&configured(&data, "loaded", 0)).unwrap();
        assert_eq!(document.as_object().unwrap().len(), 6);
        assert_eq!(document["step_previous_action"], json!(""));
        assert_eq!(document["picked_file"], json!("other.txt"));
        assert_eq!(document["picked_directory"], json!("nested/other"));
        assert_eq!(document["picked_texture"], json!("other.png"));
        assert_eq!(document["unknown_property"], json!(false));
        assert_eq!(document["ordinary_text"], json!("independent text"));
        assert!(document.get("authored_switch").is_none());
        data.models.insert(
            "loaded".into(),
            ProjectModel::parse("loaded", r#"{"type":"scene"}"#).unwrap(),
        );
        for saved_type in ["web", "video", "unknown"] {
            data.wallpapers.get_mut("loaded").unwrap().r#type = saved_type.into();
            assert_eq!(parsed_document(&configured(&data, "loaded", 0)), None);
        }
    }

    #[test]
    fn ar16_mirror_inheritance_replacement_and_own_pause() {
        let mut data = Data::new(vec![
            display(311, 165, "source"),
            display(312, 48, "mirror"),
        ]);
        data.add(live(311), "loaded");
        let wallpaper = data.wallpapers.get_mut("loaded").unwrap();
        wallpaper.audio.response_enabled = false;
        wallpaper.media_integration_enabled = true;
        wallpaper.audio.muted = true;
        wallpaper.audio.volume = 0.2;
        wallpaper
            .property_overrides
            .insert("independent_value".into(), json!("saved"));
        wallpaper.monitors.push(MonitorRender {
            selector: live(311),
            framing: FramingCfg {
                pan_x: 0.1,
                pan_y: 0.9,
            },
            ..MonitorRender::default()
        });
        data.suspended.insert(311);
        let mut inputs = data.inputs();
        inputs.force_shader_refresh = true;
        let source = build_configured_scene(
            &inputs,
            &data.config.monitors[0],
            "loaded",
            &data.wallpapers["loaded"],
            data.displays[0].desc.clone(),
        )
        .unwrap();
        let before = source.clone();
        let settings = MonitorSettingsCfg {
            selector: live(312),
            scaling_mode: "sTrEtCh".into(),
            scaling_factor: 1.4,
            frame_rate: Some(31),
            volume: 0.7,
            muted: false,
        };
        let scene =
            build_mirror_scene(&inputs, &source, data.displays[1].desc.clone(), &settings).unwrap();
        assert_eq!(scene.display, data.displays[1].desc);
        assert_eq!(scene.scene_path, source.scene_path);
        assert_eq!(scene.assets_path, source.assets_path);
        assert_eq!(scene.shader_cache_path, source.shader_cache_path);
        assert_eq!(scene.property_override_json, source.property_override_json);
        assert_eq!(scene.audio_response_enabled, source.audio_response_enabled);
        assert_eq!(
            scene.media_integration_enabled,
            source.media_integration_enabled
        );
        assert_eq!(scene.force_shader_refresh, source.force_shader_refresh);
        assert_eq!(
            (
                scene.fps,
                scene.scaling_mode,
                scene.scaling_factor,
                scene.framing
            ),
            (31, ScalingMode::Stretch, 1.4, SceneFraming::CENTERED)
        );
        assert_eq!(f32::from(scene.audio_volume), 0.7);
        assert!(!scene.audio_muted && !scene.paused);
        assert!(source.paused);
        assert_eq!(source, before);
        for global in [false, true] {
            for suspended in [false, true] {
                data.suspended = if suspended {
                    BTreeSet::from([312])
                } else {
                    BTreeSet::from([311])
                };
                let mut inputs = data.inputs();
                inputs.paused = global;
                assert_eq!(
                    build_mirror_scene(&inputs, &source, data.displays[1].desc.clone(), &settings)
                        .unwrap()
                        .paused,
                    global || suspended
                );
            }
        }
    }

    #[test]
    fn ar17_mirror_rate_uses_own_refresh_and_ignores_transient_controls() {
        let mut data = Data::new(vec![
            display(311, 165, "source"),
            display(312, 48, "mirror"),
        ]);
        data.add(live(311), "loaded");
        data.wallpapers
            .get_mut("loaded")
            .unwrap()
            .monitors
            .push(MonitorRender {
                selector: live(311),
                frame_rate: Some(165),
                ..MonitorRender::default()
            });
        let source = configured(&data, "loaded", 0);
        assert_eq!(source.fps, 165);
        let mut settings = MonitorSettingsCfg {
            selector: live(312),
            scaling_mode: "FIT".into(),
            scaling_factor: 2.0,
            volume: 0.4,
            muted: false,
            ..MonitorSettingsCfg::default()
        };
        let mut inputs = data.inputs();
        inputs.frame_rate_cap = Some(24);
        inputs.audio_suppressed = true;
        let scene =
            build_mirror_scene(&inputs, &source, data.displays[1].desc.clone(), &settings).unwrap();
        assert_eq!(scene.fps, 48);
        assert_eq!(scene.scaling_mode, ScalingMode::Fit);
        assert_eq!(scene.scaling_factor, 2.0);
        assert_eq!(f32::from(scene.audio_volume), 0.4);
        assert!(!scene.audio_muted);
        settings.frame_rate = Some(95);
        settings.muted = true;
        let scene =
            build_mirror_scene(&inputs, &source, data.displays[1].desc.clone(), &settings).unwrap();
        assert_eq!(scene.fps, 48);
        assert!(scene.audio_muted);
        let mut fast = data.displays[1].desc.clone();
        fast.refresh_rate_hz = 144;
        settings.frame_rate = None;
        assert_eq!(
            build_mirror_scene(&inputs, &source, fast, &settings)
                .unwrap()
                .fps,
            60
        );
    }

    #[test]
    fn ar18_mirror_uses_full_validation_after_volume_and_replacements() {
        let mut data = Data::new(vec![
            display(311, 165, "source"),
            display(312, 48, "mirror"),
        ]);
        data.add(live(311), "loaded");
        let valid = configured(&data, "loaded", 0);
        assert!(valid.validate().is_ok());
        // Each dependency-origin expectation has exactly one fault, independently of the competing faults below.
        let id_error = {
            let mut only_id = valid.clone();
            only_id.display.display_id = 0;
            only_id.validate().unwrap_err()
        };
        let size_error = {
            let mut only_size = valid.clone();
            only_size.display.width = 0;
            only_size.validate().unwrap_err()
        };
        let path_error = {
            let mut only_path = valid.clone();
            only_path.scene_path.clear();
            only_path.validate().unwrap_err()
        };
        let factor_error = {
            let mut only_factor = valid.clone();
            only_factor.scaling_factor = 0.0;
            only_factor.validate().unwrap_err()
        };
        let mut source = valid;
        source.scene_path.clear();
        source.scaling_factor = 0.0;
        source.fps = 0;
        let before = source.clone();
        let mut bad_display = data.displays[1].desc.clone();
        bad_display.display_id = 0;
        bad_display.width = 0;
        let mut settings = MonitorSettingsCfg {
            selector: live(312),
            scaling_factor: 0.0,
            volume: -0.5,
            ..MonitorSettingsCfg::default()
        };
        let result = build_mirror_scene(&data.inputs(), &source, bad_display.clone(), &settings);
        assert!(result.is_err());
        assert_engine(result.unwrap_err(), volume_error(-0.5));
        assert_eq!(source, before);
        settings.volume = 1.0;
        assert_engine(
            build_mirror_scene(&data.inputs(), &source, bad_display.clone(), &settings)
                .unwrap_err(),
            id_error,
        );
        bad_display.display_id = 312;
        assert_engine(
            build_mirror_scene(&data.inputs(), &source, bad_display.clone(), &settings)
                .unwrap_err(),
            size_error,
        );
        bad_display.width = 960;
        assert_engine(
            build_mirror_scene(&data.inputs(), &source, bad_display.clone(), &settings)
                .unwrap_err(),
            path_error,
        );
        source.scene_path = data
            .paths
            .project_json("loaded")
            .to_string_lossy()
            .into_owned();
        assert_engine(
            build_mirror_scene(&data.inputs(), &source, bad_display.clone(), &settings)
                .unwrap_err(),
            factor_error,
        );
        settings.scaling_factor = 1.0;
        source.display.display_id = 0;
        source.display.width = 0;
        source.scaling_factor = f64::NAN;
        source.framing = SceneFraming {
            pan_x: f64::NAN,
            pan_y: -1.0,
        };
        let scene = build_mirror_scene(&data.inputs(), &source, bad_display, &settings).unwrap();
        assert_eq!(scene.fps, 48);
        assert_eq!(scene.display.display_id, 312);
        assert_eq!(scene.display.width, 960);
        assert_eq!(scene.scaling_factor, 1.0);
        assert_eq!(scene.framing, SceneFraming::CENTERED);
        assert!(scene.validate().is_ok());
    }

    #[test]
    fn ar19_public_assignments_preserve_saved_pairs_and_order() {
        let mut data = Data::new(vec![
            display(311, 48, "one"),
            display(312, 48, "two"),
            display(313, 48, "two"),
        ]);
        let own_identity = identity(&DisplayIdentity {
            uuid: Some("two".into()),
            name: Some("saved-name".into()),
            ..DisplayIdentity::default()
        });
        let target_identity = identity(&DisplayIdentity {
            uuid: Some("disconnected".into()),
            vendor_id: Some(71),
            model_id: Some(82),
            serial_number: Some(93),
            unit_number: Some(6),
            name: Some("saved-target".into()),
        });
        data.config.monitors = vec![
            mirror(own_identity.clone(), target_identity.clone()),
            mirror(SerializedSelector::Primary, SerializedSelector::Primary),
            mirror(live(313), live(313)),
            mirror(own_identity.clone(), target_identity.clone()),
            MonitorCfg {
                enabled: false,
                ..mirror(live(311), live(312))
            },
            MonitorCfg {
                mode: "MiRrOr".into(),
                ..mirror(live(311), live(312))
            },
            direct(live(311), "unused"),
            MonitorCfg {
                selector: live(311),
                mode: "mirror".into(),
                ..MonitorCfg::default()
            },
            mirror(live(999), live(311)),
        ];
        let core_own = DisplaySelector::Identity(DisplayIdentity {
            uuid: Some("two".into()),
            name: Some("saved-name".into()),
            ..DisplayIdentity::default()
        });
        let core_target = DisplaySelector::Identity(DisplayIdentity {
            uuid: Some("disconnected".into()),
            vendor_id: Some(71),
            model_id: Some(82),
            serial_number: Some(93),
            unit_number: Some(6),
            name: Some("saved-target".into()),
        });
        assert_eq!(
            assignments(&data),
            vec![
                (
                    core_own.clone(),
                    WallpaperAssignment::Mirror(core_target.clone())
                ),
                (
                    DisplaySelector::Primary,
                    WallpaperAssignment::Mirror(DisplaySelector::Primary)
                ),
                (
                    DisplaySelector::LiveDisplayId(313),
                    WallpaperAssignment::Mirror(DisplaySelector::LiveDisplayId(313))
                ),
                (core_own, WallpaperAssignment::Mirror(core_target)),
            ]
        );
    }

    #[test]
    fn ar20_retained_owned_build_order_owners_atomic_errors_and_purity() {
        let mut data = Data::new(vec![
            display(311, 165, "one"),
            display(312, 48, "two"),
            display(313, 48, "three"),
            display(314, 48, "four"),
        ]);
        data.add(live(312), "shared");
        data.add(SerializedSelector::Primary, "assigned-owner");
        data.add(live(314), "shared");
        data.config.monitors.push(mirror(live(313), live(312)));
        let config = data.config.clone();
        let wallpapers = data.wallpapers.clone();
        let displays = data.displays.clone();
        let owned = data.inputs().build_owned().unwrap();
        assert_eq!(
            owned
                .iter()
                .map(|(scene, owner)| (scene.display.display_id, owner.as_str()))
                .collect::<Vec<_>>(),
            [
                (311, "assigned-owner"),
                (312, "shared"),
                (314, "shared"),
                (313, "shared")
            ]
        );
        let plain = data.inputs().build().unwrap();
        assert_eq!(
            plain,
            owned
                .iter()
                .map(|(scene, _)| scene.clone())
                .collect::<Vec<_>>()
        );
        assert_eq!(data.config, config);
        assert_eq!(data.wallpapers, wallpapers);
        assert_eq!(data.displays, displays);
        data.config.monitor_settings.push(MonitorSettingsCfg {
            selector: live(313),
            volume: -0.8,
            ..MonitorSettingsCfg::default()
        });
        data.wallpapers.get_mut("shared").unwrap().audio.volume = 1.4;
        let before = data.wallpapers.clone();
        let before_config = data.config.clone();
        assert_engine(data.inputs().build_owned().unwrap_err(), volume_error(1.4));
        assert_engine(data.inputs().build().unwrap_err(), volume_error(1.4));
        assert_eq!(data.wallpapers, before);
        assert_eq!(data.config, before_config);
        assert_eq!(data.displays, displays);
        data.wallpapers.get_mut("shared").unwrap().audio.volume = 1.0;
        data.wallpapers
            .get_mut("shared")
            .unwrap()
            .monitors
            .push(MonitorRender {
                selector: live(312),
                scaling_factor: 0.0,
                ..MonitorRender::default()
            });
        let expected = SceneTemplate::builder("independent-project.json")
            .fps(48)
            .scaling_factor(0.0)
            .framing(SceneFraming::CENTERED)
            .audio_volume(1.0)
            .build()
            .unwrap_err();
        assert_engine(data.inputs().build_owned().unwrap_err(), expected);
        assert_eq!(data.config, before_config);
        assert_eq!(data.displays, displays);
        data.wallpapers.get_mut("shared").unwrap().monitors.clear();
        let before_mirror_error = data.wallpapers.clone();
        assert_engine(data.inputs().build_owned().unwrap_err(), volume_error(-0.8));
        assert_eq!(data.wallpapers, before_mirror_error);
        assert_eq!(data.config, before_config);
        assert_eq!(data.displays, displays);
    }

    #[test]
    fn ar21_retained_mirror_source_availability_order_and_reservation() {
        let mut data = Data::new(vec![
            display(311, 165, "a"),
            display(312, 48, "b"),
            display(313, 48, "c"),
            display(314, 48, "unrepresented"),
            display(315, 48, "b"),
        ]);
        data.add(live(311), "owner");
        data.config
            .monitors
            .extend([mirror(live(312), live(311)), mirror(live(313), live(312))]);
        let owned = data.inputs().build_owned().unwrap();
        assert_eq!(
            owned
                .iter()
                .map(|(scene, owner)| (scene.display.display_id, owner.as_str()))
                .collect::<Vec<_>>(),
            [(311, "owner"), (312, "owner"), (313, "owner")]
        );
        data.config.monitors.swap(1, 2);
        assert_eq!(
            data.inputs()
                .build()
                .unwrap()
                .iter()
                .map(|scene| scene.display.display_id)
                .collect::<Vec<_>>(),
            [311, 312]
        );
        data.config.monitors = vec![
            direct(live(311), "owner"),
            mirror(live(312), live(314)),
            mirror(live(312), live(311)),
            mirror(live(315), live(311)),
        ];
        data.config.monitor_settings.push(MonitorSettingsCfg {
            selector: live(315),
            volume: -0.7,
            ..MonitorSettingsCfg::default()
        });
        assert_eq!(
            data.inputs()
                .build()
                .unwrap()
                .iter()
                .map(|scene| scene.display.display_id)
                .collect::<Vec<_>>(),
            [311, 312]
        );
        // The unavailable source prevents validation of even an invalid-volume candidate.
        data.config.monitors = vec![direct(live(311), "owner"), mirror(live(313), live(314))];
        data.config.monitor_settings.push(MonitorSettingsCfg {
            selector: live(313),
            volume: -0.6,
            ..MonitorSettingsCfg::default()
        });
        let owned = data.inputs().build_owned().unwrap();
        assert_eq!(owned.len(), 1);
        assert_eq!(owned[0].0.display.display_id, 311);
        assert_eq!(owned[0].1, "owner");
    }

    #[test]
    fn ar22_retained_kind_routing_and_lock_screen_video_descriptions() {
        let mut data = Data::new(vec![
            display(311, 60, "web"),
            display(312, 60, "video"),
            display(313, 60, "unknown"),
            display(314, 60, "missing"),
            display(315, 60, "web-mirror"),
            display(316, 60, "video-mirror"),
        ]);
        data.add(live(311), "web-key");
        data.add(live(312), "video-key");
        data.add(live(313), "unknown-key");
        data.add(live(314), "missing-key");
        // Saved scene type deliberately does not perform routing; the real model does.
        data.models.insert(
            "web-key".into(),
            ProjectModel::parse("web-key", r#"{"type":"web"}"#).unwrap(),
        );
        data.models.insert(
            "video-key".into(),
            ProjectModel::parse("video-key", r#"{"type":"video"}"#).unwrap(),
        );
        data.models.insert(
            "unknown-key".into(),
            ProjectModel::parse("unknown-key", "{}").unwrap(),
        );
        data.config.monitors.extend([
            direct(live(311), "missing-key"),
            direct(live(312), "missing-key"),
            mirror(live(315), live(311)),
            mirror(live(316), live(312)),
        ]);
        assert!(data.models["video-key"].entry_file.is_none());
        let owned = data.inputs().build_owned().unwrap();
        assert_eq!(
            owned
                .iter()
                .map(|(scene, owner)| (scene.display.display_id, owner.as_str()))
                .collect::<Vec<_>>(),
            [(313, "unknown-key"), (314, "missing-key")]
        );
        assert_eq!(
            data.inputs()
                .build()
                .unwrap()
                .iter()
                .map(|scene| scene.display.display_id)
                .collect::<Vec<_>>(),
            [313, 314]
        );
        let locked = data.inputs().build_lock_screen().unwrap();
        assert_eq!(
            locked
                .iter()
                .map(|scene| scene.display.display_id)
                .collect::<Vec<_>>(),
            [312, 313, 314, 316]
        );
        assert_eq!(
            locked[0].scene_path,
            data.paths.project_json("video-key").to_string_lossy()
        );
        assert_eq!(locked[3].scene_path, locked[0].scene_path);
    }

    #[test]
    fn ar23_retained_rate_survey_includes_source_less_candidates_and_caps_only_projection() {
        let mut data = Data::new(vec![
            display(311, 165, "direct"),
            display(312, 48, "mirror"),
            display(313, 144, "unrepresented"),
        ]);
        data.add(live(311), "owner");
        data.wallpapers
            .get_mut("owner")
            .unwrap()
            .monitors
            .push(MonitorRender {
                selector: live(311),
                frame_rate: Some(120),
                ..MonitorRender::default()
            });
        data.config.monitors.push(mirror(live(312), live(313)));
        let mut inputs = data.inputs();
        inputs.frame_rate_cap = Some(24);
        let scenes = inputs.build().unwrap();
        assert_eq!(scenes.len(), 1);
        assert_eq!(scenes[0].display.display_id, 311);
        assert_eq!(scenes[0].fps, 120);
        assert_eq!(
            inputs.target_frame_rates(),
            BTreeMap::from([(311, 24), (312, 24)])
        );
        inputs.frame_rate_cap = None;
        assert_eq!(
            inputs.target_frame_rates(),
            BTreeMap::from([(311, 120), (312, 48)])
        );
    }
}
