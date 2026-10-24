use std::collections::BTreeMap;

use crate::actor::state_values::clear_missing_selection;
use crate::api::{
    BridgeDisplayMode, BridgeDisplaySettingsRow, BridgeError, BridgeScalingMode,
    BridgeWallpaperEntry, BridgeWallpaperKind,
};
use crate::config::{AppConfig, SerializedSelector, WallpaperConfig};
use crate::project::ProjectModel;
use crate::state::drafts::WallpaperOptionsDraft;
use wallpaper_core::project::ScalingMode;

pub(crate) fn add_entry(
    library: &mut Vec<BridgeWallpaperEntry>,
    id: String,
    title: String,
    kind: BridgeWallpaperKind,
) {
    library.push(BridgeWallpaperEntry {
        id,
        title,
        kind,
        supported: matches!(
            kind,
            BridgeWallpaperKind::ProjectScene
                | BridgeWallpaperKind::Video
                | BridgeWallpaperKind::Webpage
        ),
        active: false,
        selected: false,
        preview_path: None,
    });
}

pub(crate) fn add_scene_configuration(
    library: &mut Vec<BridgeWallpaperEntry>,
    configs: &mut BTreeMap<String, WallpaperConfig>,
    drafts: &mut BTreeMap<String, WallpaperOptionsDraft>,
    id: String,
    title: String,
) {
    let config = WallpaperConfig::new_for(id.clone(), "scene");
    let draft = WallpaperOptionsDraft::from_committed(config.clone());

    library.push(BridgeWallpaperEntry {
        id: id.clone(),
        title,
        kind: BridgeWallpaperKind::ProjectScene,
        supported: true,
        active: false,
        selected: false,
        preview_path: None,
    });
    configs.insert(id.clone(), config);
    drafts.insert(id, draft);
}

pub(crate) fn add_project(
    library: &mut Vec<BridgeWallpaperEntry>,
    models: &mut BTreeMap<String, ProjectModel>,
    configs: &mut BTreeMap<String, WallpaperConfig>,
    drafts: &mut BTreeMap<String, WallpaperOptionsDraft>,
    id: String,
    title: String,
    project_text: &str,
) -> Result<(), BridgeError> {
    let model = ProjectModel::parse(&id, project_text)
        .map_err(|error| BridgeError::invalid_input(error.to_string()))?;
    let title = if title.is_empty() {
        model.title.clone()
    } else {
        title
    };
    let kind = BridgeWallpaperKind::from(model.project_type);
    let config = WallpaperConfig::new_for(id.clone(), "scene");
    let draft = WallpaperOptionsDraft::from_committed(config.clone());

    library.push(BridgeWallpaperEntry {
        id: id.clone(),
        title,
        kind,
        supported: true,
        active: false,
        selected: false,
        preview_path: None,
    });
    models.insert(id.clone(), model);
    configs.insert(id.clone(), config);
    drafts.insert(id, draft);
    Ok(())
}

pub(crate) fn add_display(
    app: &mut AppConfig,
    rows: &mut BTreeMap<String, BridgeDisplaySettingsRow>,
    display_id: String,
    title: String,
) -> Result<(), BridgeError> {
    let numeric_id = display_id
        .parse::<u32>()
        .map_err(|_| BridgeError::invalid_input(format!("invalid display id {display_id}")))?;

    app.ensure_monitor(SerializedSelector::LiveDisplayId {
        display_id: numeric_id,
    });
    rows.insert(
        display_id.clone(),
        BridgeDisplaySettingsRow {
            display_id,
            title,
            enabled: true,
            mode: BridgeDisplayMode::Standalone,
            mirror_targets: Vec::new(),
            selected_mirror_target: None,
            scaling_mode: BridgeScalingMode::from(ScalingMode::default()),
            scaling_factor: 1.0_f64,
            target_fps: 60_u32,
            max_fps: 60_u32,
            muted: false,
            volume: 1.0_f32,
        },
    );

    // Snapshot lexical keys before taking mutable row borrows. Exclusion is
    // based on the row's display ID, even when it differs from its map key.
    let keys: Vec<String> = rows.keys().cloned().collect();
    for row in rows.values_mut() {
        row.mirror_targets = keys
            .iter()
            .filter(|key| *key != &row.display_id)
            .cloned()
            .collect();
    }
    Ok(())
}

pub(crate) fn replace_library(
    library: &mut Vec<BridgeWallpaperEntry>,
    selected: &mut Option<String>,
    app: &mut AppConfig,
    replacement: Vec<BridgeWallpaperEntry>,
) {
    *library = replacement;
    clear_missing_selection(library, selected, app);
}

pub(crate) fn replace_configuration(
    configs: &mut BTreeMap<String, WallpaperConfig>,
    drafts: &mut BTreeMap<String, WallpaperOptionsDraft>,
    id: String,
    config: WallpaperConfig,
) {
    let draft = WallpaperOptionsDraft::from_committed(config.clone());
    configs.insert(id.clone(), config);
    drafts.insert(id, draft);
}

#[cfg(test)]
mod contract_tests;
