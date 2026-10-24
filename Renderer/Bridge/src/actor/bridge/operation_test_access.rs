use super::BridgeActor;
use crate::{
    api::{BridgeDisplaySettingsRow, BridgeError, operation_contract_test_support::*},
    config::AppConfig,
    engine::{EngineFacade, LoadJournal},
};
use kameo::message::{Context, Message};
use std::collections::{BTreeMap, BTreeSet};

impl<E: EngineFacade + Clone> Message<ReadAppConfig> for BridgeActor<E> {
    type Reply = Result<AppConfig, BridgeError>;
    async fn handle(
        &mut self,
        _: ReadAppConfig,
        _: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        Ok(self.state.app_config.clone())
    }
}

impl<E: EngineFacade + Clone> Message<ReadDraftConfig> for BridgeActor<E> {
    type Reply = Result<DraftConfigObservation, BridgeError>;
    async fn handle(
        &mut self,
        msg: ReadDraftConfig,
        _: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        let draft = self.state.wallpaper_draft(&msg.wallpaper_id)?;
        let enabled = self.state.enabled_selectors(&msg.wallpaper_id);
        Ok(DraftConfigObservation {
            saved: draft.committed().clone(),
            pending: draft.current().clone(),
            published: self.state.wallpaper_configs.get(&msg.wallpaper_id).cloned(),
            pending_enabled: draft.effective_enabled_displays(&enabled),
            dirty: draft.is_dirty(&enabled),
            requires_reconcile: draft.requires_reconcile(&enabled),
            enabled,
        })
    }
}

impl<E: EngineFacade + Clone> Message<ReadJournal> for BridgeActor<E> {
    type Reply = Result<LoadJournal, BridgeError>;
    async fn handle(&mut self, _: ReadJournal, _: &mut Context<Self, Self::Reply>) -> Self::Reply {
        Ok(self.load_journal.clone())
    }
}

impl<E: EngineFacade + Clone> Message<ReadHeld> for BridgeActor<E> {
    type Reply = Result<BTreeSet<String>, BridgeError>;
    async fn handle(&mut self, _: ReadHeld, _: &mut Context<Self, Self::Reply>) -> Self::Reply {
        Ok(self.state.held_wallpapers.clone())
    }
}

impl<E: EngineFacade + Clone> Message<ReadPropertyPreviewMark> for BridgeActor<E> {
    type Reply = Result<bool, BridgeError>;
    async fn handle(
        &mut self,
        msg: ReadPropertyPreviewMark,
        _: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        Ok(self.previewed_properties.contains(&msg.wallpaper_id))
    }
}

impl<E: EngineFacade + Clone> Message<ReadRememberedRows> for BridgeActor<E> {
    type Reply = Result<BTreeMap<String, BridgeDisplaySettingsRow>, BridgeError>;
    async fn handle(
        &mut self,
        _: ReadRememberedRows,
        _: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        Ok(self.state.display_settings.clone())
    }
}
