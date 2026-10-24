use super::{BridgeActor, operations};
use crate::{
    actor::state::BridgeActorState,
    api::BridgeDisplaySettingsRow,
    config::{AppConfig, ConfigStore, WallpaperConfig},
    engine::{EngineFacade, LoadJournal},
    login::LaunchAtLoginStatus,
    paths::BridgePaths,
};
use std::collections::{BTreeMap, BTreeSet};

impl<E: EngineFacade> BridgeActor<E> {
    pub(super) fn operation_values(&self) -> &BridgeActorState {
        &self.state
    }

    pub(super) fn operation_values_mut(&mut self) -> &mut BridgeActorState {
        &mut self.state
    }

    pub(super) fn operation_app(&self) -> &AppConfig {
        &self.state.app_config
    }

    pub(super) fn operation_app_slot(&mut self) -> &mut AppConfig {
        &mut self.state.app_config
    }

    pub(super) fn operation_wallpapers(&self) -> &BTreeMap<String, WallpaperConfig> {
        &self.state.wallpaper_configs
    }

    pub(super) fn operation_rows(&self) -> &BTreeMap<String, BridgeDisplaySettingsRow> {
        &self.state.display_settings
    }

    pub(super) fn operation_rows_slot(
        &mut self,
    ) -> &mut BTreeMap<String, BridgeDisplaySettingsRow> {
        &mut self.state.display_settings
    }

    pub(super) fn operation_holds(&self) -> &BTreeSet<String> {
        &self.state.held_wallpapers
    }

    pub(super) fn operation_holds_slot(&mut self) -> &mut BTreeSet<String> {
        &mut self.state.held_wallpapers
    }

    pub(super) fn operation_engine(&self) -> &E {
        &self.engine
    }

    pub(super) fn operation_paths(&self) -> &BridgePaths {
        &self.paths
    }

    pub(super) fn operation_store(&self) -> Option<&ConfigStore> {
        self.config_store.as_ref()
    }

    pub(super) fn operation_journal(&self) -> &LoadJournal {
        &self.load_journal
    }

    pub(super) fn operation_suspended_displays(&self) -> &BTreeSet<u32> {
        &self.state.suspended_displays
    }

    pub(super) fn operation_unloaded(&self) -> bool {
        self.state.presentation_unloaded
    }

    pub(super) fn operation_audio_suppressed(&self) -> bool {
        self.state.audio_suppressed
    }

    pub(super) fn operation_owner(&self) -> &operations::OperationState {
        &self.operation_state
    }

    pub(super) fn operation_owner_mut(&mut self) -> &mut operations::OperationState {
        &mut self.operation_state
    }

    pub(super) fn operation_login_status(&self) -> LaunchAtLoginStatus {
        self.launch_at_login.status()
    }

    pub(super) fn operation_append_error(&mut self, message: String) {
        self.state.errors.push(message);
    }

    pub(super) fn operation_forget_property_preview(&mut self, id: &str) {
        self.previewed_properties.remove(id);
    }
}
