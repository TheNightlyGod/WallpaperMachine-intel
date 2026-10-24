use kameo::message::{Context, Message};

use super::{BridgeActor, BridgeActorHandle};
use crate::{
    actor::state::BridgeActorState, api::BridgeError, config::QualityInForce, engine::EngineFacade,
};

pub(crate) fn runtime_probe<E: EngineFacade>(
    handle: &BridgeActorHandle<E>,
) -> crate::actor::transport::RuntimeDropProbe<E> {
    handle.runtime_probe()
}

pub(crate) struct MountedStateObservation;

impl<E: EngineFacade + Clone> Message<MountedStateObservation> for BridgeActor<E> {
    type Reply = Result<BridgeActorState, BridgeError>;

    async fn handle(
        &mut self,
        _message: MountedStateObservation,
        _context: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        Ok(self.state.clone())
    }
}

pub(crate) fn quality_in_force(state: &BridgeActorState) -> QualityInForce {
    state.quality_in_force()
}

pub(crate) fn active_target_fps_cap(state: &BridgeActorState) -> Option<u32> {
    state.active_target_fps_cap()
}
