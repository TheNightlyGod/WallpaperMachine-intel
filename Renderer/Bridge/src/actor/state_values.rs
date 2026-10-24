use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;

use crate::api::{BridgeError, BridgeErrorKind, BridgeWallpaperEntry};
use crate::config::{AppConfig, SerializedSelector, WallpaperConfig};
use crate::project::ProjectModel;
use crate::state::drafts::WallpaperOptionsDraft;

pub(crate) fn configured_ids(config: &AppConfig) -> Vec<String> {
    config
        .monitors
        .iter()
        .filter(|row| row.enabled && row.mode != "mirror")
        .filter_map(|row| row.wallpaper.as_deref())
        .collect::<BTreeSet<_>>()
        .into_iter()
        .map(str::to_owned)
        .collect()
}

pub(crate) fn enabled_selectors(config: &AppConfig, id: &str) -> Vec<SerializedSelector> {
    config
        .monitors
        .iter()
        .filter(|row| row.enabled && row.mode != "mirror" && row.wallpaper.as_deref() == Some(id))
        .map(|row| row.selector.clone())
        .collect()
}

pub(crate) fn ensure_present(
    library: &[BridgeWallpaperEntry],
    id: &str,
) -> Result<(), BridgeError> {
    if library.iter().any(|entry| entry.id == id) {
        Ok(())
    } else {
        Err(BridgeError::Error {
            kind: BridgeErrorKind::InvalidInput,
            message: format!("unknown wallpaper id {id}"),
        })
    }
}

pub(crate) fn model_for<'a>(
    library: &[BridgeWallpaperEntry],
    models: &'a BTreeMap<String, ProjectModel>,
    id: &str,
) -> Result<&'a ProjectModel, BridgeError> {
    ensure_present(library, id)?;
    models.get(id).ok_or_else(|| BridgeError::Error {
        kind: BridgeErrorKind::InvalidInput,
        message: format!("no project model loaded for wallpaper id {id}"),
    })
}

fn baseline(
    config: &AppConfig,
    saved: &BTreeMap<String, WallpaperConfig>,
    id: &str,
) -> WallpaperOptionsDraft {
    WallpaperOptionsDraft::from_committed_with_enabled_displays(
        saved
            .get(id)
            .cloned()
            .unwrap_or_else(|| WallpaperConfig::new_for(id, "scene")),
        enabled_selectors(config, id),
    )
}

pub(crate) fn draft_for(
    library: &[BridgeWallpaperEntry],
    config: &AppConfig,
    saved: &BTreeMap<String, WallpaperConfig>,
    drafts: &BTreeMap<String, WallpaperOptionsDraft>,
    id: &str,
) -> Result<WallpaperOptionsDraft, BridgeError> {
    ensure_present(library, id)?;
    Ok(drafts
        .get(id)
        .cloned()
        .unwrap_or_else(|| baseline(config, saved, id)))
}

pub(crate) fn draft_for_mut<'a>(
    library: &[BridgeWallpaperEntry],
    config: &AppConfig,
    saved: &BTreeMap<String, WallpaperConfig>,
    drafts: &'a mut BTreeMap<String, WallpaperOptionsDraft>,
    id: &str,
) -> Result<&'a mut WallpaperOptionsDraft, BridgeError> {
    ensure_present(library, id)?;
    if !drafts.contains_key(id) {
        drafts.insert(id.to_owned(), baseline(config, saved, id));
    }
    Ok(drafts.get_mut(id).expect("validated draft was inserted"))
}

pub(crate) struct PreparedApply {
    app: AppConfig,
    wallpapers: BTreeMap<String, WallpaperConfig>,
    prepared_id: String,
    effective_enabled: Vec<SerializedSelector>,
    reconcile: bool,
}

impl PreparedApply {
    pub(crate) fn app_config(&self) -> &AppConfig {
        &self.app
    }

    pub(crate) fn wallpaper_config(&self) -> &WallpaperConfig {
        self.wallpapers
            .get(&self.prepared_id)
            .expect("prepared wallpaper is retained")
    }

    pub(crate) fn wallpaper_configs(&self) -> &BTreeMap<String, WallpaperConfig> {
        &self.wallpapers
    }

    pub(crate) fn requires_reconcile(&self) -> bool {
        self.reconcile
    }

    pub(crate) fn into_publication(
        self,
        library: &[BridgeWallpaperEntry],
        id: &str,
    ) -> Result<
        (
            AppConfig,
            BTreeMap<String, WallpaperConfig>,
            WallpaperOptionsDraft,
        ),
        BridgeError,
    > {
        ensure_present(library, id)?;
        let committed = WallpaperOptionsDraft::from_committed_with_enabled_displays(
            self.wallpaper_config().clone(),
            self.effective_enabled,
        );
        Ok((self.app, self.wallpapers, committed))
    }

    pub(crate) fn into_app_config(self) -> AppConfig {
        self.app
    }
}

pub(crate) fn prepare_apply(
    library: &[BridgeWallpaperEntry],
    config: &AppConfig,
    saved: &BTreeMap<String, WallpaperConfig>,
    drafts: &BTreeMap<String, WallpaperOptionsDraft>,
    id: &str,
    primary_identity: Option<&SerializedSelector>,
) -> Result<PreparedApply, BridgeError> {
    ensure_present(library, id)?;
    let fallback;
    let draft = match drafts.get(id) {
        Some(draft) => draft,
        None => {
            fallback = baseline(config, saved, id);
            &fallback
        }
    };
    let active = enabled_selectors(config, id);
    let reconcile = draft.requires_reconcile(&active);
    let effective_enabled = draft.effective_enabled_displays(&active);
    let mut app = config.clone();
    let mut wallpaper = draft.current().clone();
    for row in &mut app.monitors {
        if row.wallpaper.as_deref() == Some(id) {
            row.wallpaper = None;
        }
    }
    for selector in &effective_enabled {
        let row = app.ensure_monitor(selector.clone());
        row.enabled = true;
        row.mode = "independent".to_owned();
        row.wallpaper = Some(id.to_owned());
    }
    if let Some(identity) = primary_identity {
        if let Some(mut row) = app
            .monitors
            .iter()
            .find(|row| row.selector == SerializedSelector::Primary)
            .cloned()
        {
            row.selector = identity.clone();
            if let Some(target) = app
                .monitors
                .iter_mut()
                .find(|row| &row.selector == identity)
            {
                *target = row;
            } else {
                app.monitors.push(row);
            }
        }
        if let Some(mut row) = wallpaper
            .monitors
            .iter()
            .find(|row| row.selector == SerializedSelector::Primary)
            .cloned()
        {
            row.selector = identity.clone();
            if let Some(target) = wallpaper
                .monitors
                .iter_mut()
                .find(|row| &row.selector == identity)
            {
                *target = row;
            } else {
                wallpaper.monitors.push(row);
            }
        }
    }
    let mut wallpapers = saved.clone();
    wallpapers.insert(id.to_owned(), wallpaper);
    Ok(PreparedApply {
        app,
        wallpapers,
        prepared_id: id.to_owned(),
        effective_enabled,
        reconcile,
    })
}

pub(crate) fn rebase_existing_drafts(
    config: &AppConfig,
    drafts: &mut BTreeMap<String, WallpaperOptionsDraft>,
) {
    for (id, draft) in drafts {
        draft.rebase_enabled_displays(enabled_selectors(config, id));
    }
}

pub(crate) fn clear_missing_selection(
    library: &[BridgeWallpaperEntry],
    selected: &mut Option<String>,
    config: &mut AppConfig,
) {
    if selected
        .as_deref()
        .is_some_and(|id| !library.iter().any(|entry| entry.id == id))
    {
        *selected = None;
        config.general.last_selected_wallpaper = None;
    }
}

pub(crate) fn active_ids_from_scenes<'a>(
    scene_paths: impl IntoIterator<Item = &'a str>,
    configured_web_ids: impl IntoIterator<Item = &'a str>,
) -> Vec<String> {
    scene_paths
        .into_iter()
        .filter_map(|path| Path::new(path).parent()?.file_name()?.to_str())
        .filter(|id| !id.is_empty())
        .chain(configured_web_ids)
        .collect::<BTreeSet<_>>()
        .into_iter()
        .map(str::to_owned)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::BridgeWallpaperKind;
    use crate::config::{FramingCfg, MonitorCfg, MonitorRender};
    use crate::project::PropertyValue;

    fn selector(n: u32) -> SerializedSelector {
        SerializedSelector::LiveDisplayId { display_id: n }
    }

    fn library() -> Vec<BridgeWallpaperEntry> {
        ["aurora", "basalt"]
            .into_iter()
            .map(|id| BridgeWallpaperEntry {
                id: id.to_owned(),
                title: format!("Independent {id}"),
                kind: BridgeWallpaperKind::Unknown,
                supported: false,
                active: false,
                selected: false,
                preview_path: None,
            })
            .collect()
    }

    fn monitor(selector: SerializedSelector, id: &str, enabled: bool, mode: &str) -> MonitorCfg {
        MonitorCfg {
            selector,
            wallpaper: Some(id.to_owned()),
            enabled,
            mode: mode.to_owned(),
            mirror_target: Some(super::tests::selector(91)),
        }
    }

    fn scalar_model() -> ProjectModel {
        ProjectModel::parse("aurora", r#"{"type":"scene","general":{"properties":{"drift_depth":{"type":"slider","value":0.25,"min":0.0,"max":1.0},"soft_edges":{"type":"bool","value":false}}}}"#).unwrap()
    }

    fn pending() -> WallpaperOptionsDraft {
        let mut config = WallpaperConfig::new_for("aurora", "scene");
        config.monitors = vec![MonitorRender {
            selector: SerializedSelector::Primary,
            scaling_mode: "fit".to_owned(),
            scaling_factor: 1.7,
            frame_rate: Some(37),
            framing: FramingCfg {
                pan_x: 0.23,
                pan_y: 0.81,
            },
        }];
        let mut draft = WallpaperOptionsDraft::from_committed_with_enabled_displays(
            config,
            vec![SerializedSelector::Primary],
        );
        draft.set_volume(0.37).unwrap();
        draft.set_muted(true);
        draft
            .set_scaling_factor(SerializedSelector::Primary, 1.9)
            .unwrap();
        let model = scalar_model();
        draft.edit_property(&model, "drift_depth", PropertyValue::Number(0.72));
        draft.edit_property(&model, "soft_edges", PropertyValue::Bool(true));
        draft
    }

    #[test]
    fn s01_ordered_selectors_and_sorted_configured_ids() {
        let mut config = AppConfig::default();
        config.general.last_selected_wallpaper = Some("not_scanned".to_owned());
        config.ui.filter.scene = false;
        config.ui.filter.web = false;
        config.monitors = vec![
            monitor(selector(2), "basalt", true, "unfamiliar"),
            monitor(selector(1), "aurora", true, "independent"),
            monitor(selector(1), "aurora", true, "independent"),
            monitor(selector(3), "hidden", false, "independent"),
            monitor(selector(4), "reflected", true, "mirror"),
        ];
        let before = config.clone();
        assert_eq!(configured_ids(&config), ["aurora", "basalt"]);
        assert_eq!(
            enabled_selectors(&config, "aurora"),
            vec![selector(1), selector(1)]
        );
        assert_eq!(config, before);
    }

    #[test]
    fn s03_membership_precedes_models_and_lookup_borrows() {
        let entries = library();
        let mut models = BTreeMap::new();
        models.insert("outside".to_owned(), scalar_model());
        let error = model_for(&entries, &models, "outside").unwrap_err();
        assert_eq!(error.kind(), BridgeErrorKind::InvalidInput);
        let membership_error = ensure_present(&entries, "outside").unwrap_err();
        assert_eq!(error.message(), membership_error.message());
        models.remove("outside");
        let unknown_without_model = model_for(&entries, &models, "outside").unwrap_err();
        assert_eq!(unknown_without_model.kind(), BridgeErrorKind::InvalidInput);
        assert_eq!(unknown_without_model.message(), membership_error.message());
        let error = model_for(&entries, &models, "aurora").unwrap_err();
        assert_eq!(error.kind(), BridgeErrorKind::InvalidInput);
        assert!(ensure_present(&entries, "aurora").is_ok());
        models.insert("aurora".to_owned(), scalar_model());
        assert!(std::ptr::eq(
            model_for(&entries, &models, "aurora").unwrap(),
            &models["aurora"]
        ));
    }

    #[test]
    fn s04_snapshots_defaults_saved_existing_and_single_insertion() {
        let entries = library();
        let mut config = AppConfig::default();
        config.monitors = vec![
            monitor(selector(5), "aurora", true, "custom"),
            monitor(selector(5), "aurora", true, "independent"),
        ];
        let mut saved = BTreeMap::new();
        let mut drafts = BTreeMap::new();
        let selectors = vec![selector(5), selector(5)];
        let fresh = draft_for(&entries, &config, &saved, &drafts, "aurora").unwrap();
        assert_eq!(
            fresh.current(),
            &WallpaperConfig::new_for("aurora", "scene")
        );
        assert_eq!(fresh.effective_enabled_displays(&selectors), selectors);
        assert!(!fresh.is_dirty(&selectors));
        assert!(drafts.is_empty());
        let mut committed = WallpaperConfig::new_for("aurora", "video");
        committed.audio.volume = 0.61;
        saved.insert("aurora".to_owned(), committed.clone());
        assert_eq!(
            draft_for(&entries, &config, &saved, &drafts, "aurora")
                .unwrap()
                .current(),
            &committed
        );
        assert!(drafts.is_empty());
        draft_for_mut(&entries, &config, &saved, &mut drafts, "aurora")
            .unwrap()
            .set_volume(0.19)
            .unwrap();
        assert_eq!(drafts.len(), 1);
        assert_eq!(
            draft_for_mut(&entries, &config, &saved, &mut drafts, "aurora")
                .unwrap()
                .current()
                .audio
                .volume,
            0.19
        );
        let snapshot = draft_for(&entries, &config, &saved, &drafts, "aurora").unwrap();
        assert_eq!(snapshot.current().audio.volume, 0.19);
        assert_eq!(snapshot.committed(), &committed);
        assert!(draft_for_mut(&entries, &config, &saved, &mut drafts, "outside").is_err());
        assert_eq!(drafts.len(), 1);
        assert_eq!(drafts["aurora"].current(), snapshot.current());
    }

    #[test]
    fn s05_s06_assignment_clearing_takeover_duplicates_and_nonmutation() {
        let entries = library();
        let mut config = AppConfig::default();
        config.monitors = vec![
            monitor(selector(1), "aurora", true, "independent"),
            monitor(selector(1), "aurora", true, "independent"),
            monitor(selector(2), "aurora", false, "independent"),
            monitor(selector(3), "aurora", true, "mirror"),
            monitor(selector(4), "basalt", false, "mirror"),
            monitor(selector(8), "basalt", true, "custom"),
        ];
        let original = config.clone();
        let saved = BTreeMap::from([(
            "basalt".to_owned(),
            WallpaperConfig::new_for("basalt", "video"),
        )]);
        let saved_before = saved.clone();
        let mut draft = WallpaperOptionsDraft::from_committed_with_enabled_displays(
            WallpaperConfig::new_for("aurora", "scene"),
            vec![selector(1), selector(1)],
        );
        let active = enabled_selectors(&config, "aurora");
        draft.set_display_enabled(selector(4), true, &active);
        draft.set_display_enabled(selector(6), true, &active);
        let current_before = draft.current().clone();
        let committed_before = draft.committed().clone();
        let effective_before = draft.effective_enabled_displays(&active);
        let drafts = BTreeMap::from([("aurora".to_owned(), draft)]);
        let prepared = prepare_apply(&entries, &config, &saved, &drafts, "aurora", None).unwrap();
        let rows = &prepared.app_config().monitors;
        assert_eq!(rows.len(), 7);
        assert_eq!(rows[0].wallpaper.as_deref(), Some("aurora"));
        assert_eq!(rows[1].wallpaper, None);
        for index in [1, 2, 3] {
            let mut expected = original.monitors[index].clone();
            expected.wallpaper = None;
            assert_eq!(rows[index], expected);
        }
        let mut takeover = original.monitors[4].clone();
        takeover.enabled = true;
        takeover.mode = "independent".to_owned();
        takeover.wallpaper = Some("aurora".to_owned());
        assert_eq!(rows[4], takeover);
        assert_eq!(rows[5], original.monitors[5]);
        assert_eq!(rows[6].selector, selector(6));
        assert_eq!(rows[6].mirror_target, None);
        assert_eq!(prepared.effective_enabled, effective_before);
        assert_eq!(
            prepared
                .effective_enabled
                .iter()
                .filter(|s| **s == selector(1))
                .count(),
            2
        );
        assert_eq!(prepared.wallpaper_configs()["basalt"], saved["basalt"]);
        assert_eq!(config, original);
        assert_eq!(saved, saved_before);
        assert_eq!(drafts["aurora"].current(), &current_before);
        assert_eq!(drafts["aurora"].committed(), &committed_before);
        assert_eq!(
            drafts["aurora"].effective_enabled_displays(&active),
            effective_before
        );
    }

    #[test]
    fn s06_duplicate_effective_selectors_append_only_once() {
        let entries = library();
        let mut config = AppConfig::default();
        config.monitors.clear();
        let baseline_enabled = vec![selector(6), selector(6)];
        let mut draft = WallpaperOptionsDraft::from_committed_with_enabled_displays(
            WallpaperConfig::new_for("aurora", "scene"),
            baseline_enabled.clone(),
        );
        draft.set_display_enabled(selector(7), true, &baseline_enabled);
        let drafts = BTreeMap::from([("aurora".to_owned(), draft)]);
        let prepared =
            prepare_apply(&entries, &config, &BTreeMap::new(), &drafts, "aurora", None).unwrap();
        assert_eq!(
            prepared.effective_enabled,
            vec![selector(6), selector(6), selector(7)]
        );
        let rows = &prepared.app_config().monitors;
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].selector, selector(6));
        assert_eq!(rows[1].selector, selector(7));
        assert!(rows.iter().all(|row| row.enabled
            && row.mode == "independent"
            && row.wallpaper.as_deref() == Some("aurora")));
        assert!(config.monitors.is_empty());
    }

    #[test]
    fn s07_complete_primary_copies_independent_collections_and_first_matches() {
        let entries = library();
        let identity = SerializedSelector::Identity {
            uuid: Some("new-independent-display".to_owned()),
            vendor_id: Some(17),
            model_id: Some(29),
            serial_number: None,
            unit_number: None,
            name: Some("Portrait".to_owned()),
        };
        for app_primary in [false, true] {
            for render_primary in [false, true] {
                for (app_identity, render_identity) in
                    [(false, false), (false, true), (true, false), (true, true)]
                {
                    let mut config = AppConfig::default();
                    config.monitors.clear();
                    if app_primary {
                        config.monitors.push(monitor(
                            SerializedSelector::Primary,
                            "basalt",
                            false,
                            "unusual",
                        ));
                        config.monitors.push(monitor(
                            SerializedSelector::Primary,
                            "basalt",
                            true,
                            "mirror",
                        ));
                    }
                    if app_identity {
                        config.monitors.push(monitor(
                            identity.clone(),
                            "basalt",
                            true,
                            "independent",
                        ));
                        config
                            .monitors
                            .push(monitor(identity.clone(), "basalt", false, "mirror"));
                    }
                    let mut wallpaper = WallpaperConfig::new_for("aurora", "scene");
                    wallpaper.monitors.clear();
                    if render_primary {
                        wallpaper.monitors.push(MonitorRender {
                            selector: SerializedSelector::Primary,
                            scaling_mode: "fit".to_owned(),
                            scaling_factor: 2.3,
                            frame_rate: Some(43),
                            framing: FramingCfg {
                                pan_x: 0.14,
                                pan_y: 0.92,
                            },
                        });
                        let mut second = wallpaper.monitors[0].clone();
                        second.frame_rate = Some(67);
                        wallpaper.monitors.push(second);
                    }
                    if render_identity {
                        let row = MonitorRender {
                            selector: identity.clone(),
                            ..MonitorRender::default()
                        };
                        wallpaper.monitors.extend([row.clone(), row]);
                    }
                    let saved = BTreeMap::from([("aurora".to_owned(), wallpaper.clone())]);
                    let prepared = prepare_apply(
                        &entries,
                        &config,
                        &saved,
                        &BTreeMap::new(),
                        "aurora",
                        Some(&identity),
                    )
                    .unwrap();
                    let mut expected_app = config.clone();
                    if app_primary {
                        let mut row = config.monitors[0].clone();
                        row.selector = identity.clone();
                        if app_identity {
                            expected_app.monitors[2] = row;
                        } else {
                            expected_app.monitors.push(row);
                        }
                    }
                    let mut expected_wallpaper = wallpaper.clone();
                    if render_primary {
                        let mut row = wallpaper.monitors[0].clone();
                        row.selector = identity.clone();
                        if render_identity {
                            expected_wallpaper.monitors[2] = row;
                        } else {
                            expected_wallpaper.monitors.push(row);
                        }
                    }
                    assert_eq!(prepared.app_config(), &expected_app);
                    assert_eq!(prepared.wallpaper_config(), &expected_wallpaper);
                    assert!(!prepared.requires_reconcile());
                    assert!(prepared.effective_enabled.is_empty());
                    assert_eq!(saved["aurora"], wallpaper);
                }
            }
        }
    }

    #[test]
    fn s08_pending_properties_audio_render_and_selector_intent_are_captured() {
        let entries = library();
        let mut config = AppConfig::default();
        config.monitors = vec![monitor(
            SerializedSelector::Primary,
            "aurora",
            true,
            "independent",
        )];
        let mut draft = pending();
        let active = enabled_selectors(&config, "aurora");
        draft.set_display_enabled(selector(31), true, &active);
        let expected = draft.current().clone();
        assert_eq!(
            expected.property_overrides["drift_depth"].as_f64(),
            Some(0.72)
        );
        assert_eq!(
            expected.property_overrides["soft_edges"].as_bool(),
            Some(true)
        );
        assert!(draft.committed().property_overrides.is_empty());
        let expected_enabled = draft.effective_enabled_displays(&active);
        assert!(draft.requires_reconcile(&active));
        let drafts = BTreeMap::from([("aurora".to_owned(), draft)]);
        let prepared = prepare_apply(
            &entries,
            &config,
            &BTreeMap::new(),
            &drafts,
            "aurora",
            Some(&selector(33)),
        )
        .unwrap();
        assert!(prepared.requires_reconcile());
        assert_eq!(prepared.effective_enabled, expected_enabled);
        let mut accepted = expected.clone();
        let mut copied = expected.monitors[0].clone();
        copied.selector = selector(33);
        accepted.monitors.push(copied);
        assert_eq!(prepared.wallpaper_config(), &accepted);
        assert_eq!(drafts["aurora"].current(), &expected);
    }

    #[test]
    fn s08_dirty_audio_or_scale_is_not_a_reconcile_substitute() {
        let entries = library();
        let mut config = AppConfig::default();
        config.monitors = vec![monitor(
            SerializedSelector::Primary,
            "aurora",
            true,
            "independent",
        )];
        let active = enabled_selectors(&config, "aurora");
        for scale in [false, true] {
            let mut wallpaper = WallpaperConfig::new_for("aurora", "scene");
            wallpaper.monitors = vec![MonitorRender {
                selector: SerializedSelector::Primary,
                ..MonitorRender::default()
            }];
            let mut draft = WallpaperOptionsDraft::from_committed_with_enabled_displays(
                wallpaper,
                active.clone(),
            );
            if scale {
                draft
                    .set_scaling_factor(SerializedSelector::Primary, 1.4)
                    .unwrap();
            } else {
                draft.set_volume(0.42).unwrap();
                draft.set_muted(true);
            }
            assert!(draft.is_dirty(&active));
            assert!(!draft.requires_reconcile(&active));
            let drafts = BTreeMap::from([("aurora".to_owned(), draft)]);
            let prepared = prepare_apply(
                &entries,
                &config,
                &BTreeMap::new(),
                &drafts,
                "aurora",
                Some(&selector(42)),
            )
            .unwrap();
            assert!(!prepared.requires_reconcile());
            assert_eq!(prepared.effective_enabled, active);
            assert_eq!(prepared.wallpaper_config().monitors.len(), 2);
        }
    }

    #[test]
    fn s09_revalidation_committed_baseline_borrowing_and_app_only_consumption() {
        fn owned_send<T: Send + 'static>(_: &T) {}
        let entries = library();
        let config = AppConfig::default();
        let saved = BTreeMap::from([(
            "basalt".to_owned(),
            WallpaperConfig::new_for("basalt", "video"),
        )]);
        let mut target = pending();
        target.set_display_enabled(SerializedSelector::Primary, true, &[]);
        let other = WallpaperOptionsDraft::from_committed_with_enabled_displays(
            saved["basalt"].clone(),
            vec![selector(61)],
        );
        let drafts = BTreeMap::from([("aurora".to_owned(), target), ("basalt".to_owned(), other)]);
        let target_before = drafts["aurora"].current().clone();
        let other_before = drafts["basalt"].current().clone();
        let prepared = prepare_apply(
            &entries,
            &config,
            &saved,
            &drafts,
            "aurora",
            Some(&selector(62)),
        )
        .unwrap();
        owned_send(&prepared);
        assert!(std::ptr::eq(
            prepared.wallpaper_config(),
            &prepared.wallpaper_configs()["aurora"]
        ));
        assert!(std::ptr::eq(prepared.app_config(), prepared.app_config()));
        let app_expected = prepared.app_config().clone();
        let map_expected = prepared.wallpaper_configs().clone();
        let enabled = prepared.effective_enabled.clone();
        assert!(prepared.into_publication(&entries[1..], "aurora").is_err());
        assert_eq!(saved.len(), 1);
        assert_eq!(drafts["aurora"].current(), &target_before);
        let prepared = prepare_apply(
            &entries,
            &config,
            &saved,
            &drafts,
            "aurora",
            Some(&selector(62)),
        )
        .unwrap();
        let (app, map, baseline) = prepared.into_publication(&entries, "aurora").unwrap();
        assert_eq!(app, app_expected);
        assert_eq!(map, map_expected);
        assert_eq!(baseline.current(), &map["aurora"]);
        assert_eq!(baseline.committed(), &map["aurora"]);
        assert_eq!(baseline.effective_enabled_displays(&enabled), enabled);
        assert!(!baseline.is_dirty(&enabled));
        assert_eq!(drafts["basalt"].current(), &other_before);
        assert_eq!(map["basalt"], saved["basalt"]);
        let app_only = prepare_apply(
            &entries,
            &config,
            &saved,
            &drafts,
            "aurora",
            Some(&selector(62)),
        )
        .unwrap()
        .into_app_config();
        assert_eq!(app_only, app_expected);
        assert_eq!(saved.len(), 1);
        assert_eq!(drafts["aurora"].current(), &target_before);
        assert!(drafts["aurora"].committed().property_overrides.is_empty());
    }

    #[test]
    fn s11_path_parent_ids_and_supplied_web_union() {
        assert_eq!(
            active_ids_from_scenes(
                [
                    "/library/zenith/scene.json",
                    "/other/zenith/again.json",
                    "relative/amber/project.json",
                    "file.json",
                    "/",
                    "/file.json",
                    "",
                    "/library/星雲/scene.json"
                ],
                ["web-only", "amber", "web-only"],
            ),
            vec!["amber", "web-only", "zenith", "星雲"]
        );
        assert!(active_ids_from_scenes([], []).is_empty());
    }

    #[test]
    fn s12_selection_clearing_preserves_absent_actor_and_retained_mismatch() {
        let entries = library();
        let mut config = AppConfig::default();
        config.general.last_selected_wallpaper = Some("persisted-other".to_owned());
        let before = config.clone();
        let mut selected = Some("aurora".to_owned());
        clear_missing_selection(&entries, &mut selected, &mut config);
        assert_eq!(selected.as_deref(), Some("aurora"));
        assert_eq!(config, before);
        selected = None;
        clear_missing_selection(&[], &mut selected, &mut config);
        assert_eq!(config, before);
        selected = Some("missing".to_owned());
        clear_missing_selection(&entries, &mut selected, &mut config);
        let mut expected = before;
        expected.general.last_selected_wallpaper = None;
        assert_eq!(config, expected);
        assert_eq!(selected, None);
    }

    #[test]
    fn s13_rebase_preserves_real_pending_edits_and_discards_old_selector_intent() {
        let mut target = pending();
        target.set_display_enabled(selector(70), true, &[SerializedSelector::Primary]);
        let current = target.current().clone();
        let committed = target.committed().clone();
        assert_eq!(
            current.property_overrides["drift_depth"].as_f64(),
            Some(0.72)
        );
        assert_eq!(
            current.property_overrides["soft_edges"].as_bool(),
            Some(true)
        );
        let mut drafts = BTreeMap::from([("aurora".to_owned(), target)]);
        let mut config = AppConfig::default();
        config.monitors = vec![
            monitor(selector(72), "aurora", true, "independent"),
            monitor(selector(72), "aurora", true, "independent"),
            monitor(selector(73), "aurora", false, "independent"),
            monitor(selector(74), "basalt", true, "independent"),
        ];
        let before = config.clone();
        rebase_existing_drafts(&config, &mut drafts);
        assert_eq!(drafts.len(), 1);
        assert!(!drafts.contains_key("basalt"));
        let draft = &drafts["aurora"];
        assert_eq!(draft.current(), &current);
        assert_eq!(draft.committed(), &committed);
        let active = vec![selector(72), selector(72)];
        assert_eq!(draft.effective_enabled_displays(&active), active);
        assert!(draft.is_dirty(&active));
        assert!(draft.requires_reconcile(&active));
        assert_eq!(config, before);
    }
}
