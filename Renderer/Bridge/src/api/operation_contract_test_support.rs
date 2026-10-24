use std::collections::BTreeMap;

use crate::{
    actor::state::BridgeActorState,
    api::{BridgeBuilder, BridgeDisplaySettingsRow, BridgeWallpaperEntry},
    config::{AppConfig, SerializedSelector, WallpaperConfig},
    engine::{EngineFacade, LoadJournal},
    project::ProjectModel,
};

pub(crate) struct ReadAppConfig;
pub(crate) struct ReadDraftConfig {
    pub wallpaper_id: String,
}
pub(crate) struct ReadJournal;
pub(crate) struct ReadHeld;
pub(crate) struct ReadPropertyPreviewMark {
    pub wallpaper_id: String,
}
pub(crate) struct ReadRememberedRows;

#[derive(Debug)]
pub(crate) struct DraftConfigObservation {
    pub saved: WallpaperConfig,
    pub pending: WallpaperConfig,
    pub published: Option<WallpaperConfig>,
    pub enabled: Vec<SerializedSelector>,
    pub pending_enabled: Vec<SerializedSelector>,
    pub dirty: bool,
    pub requires_reconcile: bool,
}

pub(crate) fn with_journal<E: EngineFacade>(
    mut builder: BridgeBuilder<E>,
    journal: LoadJournal,
) -> BridgeBuilder<E> {
    builder.journal_for_tests = Some(journal);
    builder
}

pub(crate) fn initial_operation_state(
    app: AppConfig,
    library: Vec<BridgeWallpaperEntry>,
    models: BTreeMap<String, ProjectModel>,
    wallpapers: BTreeMap<String, WallpaperConfig>,
    remembered: BTreeMap<String, BridgeDisplaySettingsRow>,
) -> BridgeActorState {
    let mut state = BridgeActorState::from_app_config(app);
    state.library = library;
    state.project_models = models;
    state.wallpaper_configs = wallpapers;
    state.display_settings = remembered;
    state
}
