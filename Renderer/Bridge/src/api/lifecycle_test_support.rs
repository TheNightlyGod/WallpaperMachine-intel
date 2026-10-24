use super::{ArcEngineFacade, FirstFrameHandoff, WallpaperBridge};
use crate::{
    actor::BridgeActorHandle,
    login::{LaunchAtLoginController, LaunchAtLoginStatus},
};

pub(super) fn actor(bridge: &WallpaperBridge) -> &BridgeActorHandle<ArcEngineFacade> {
    &bridge.actor
}

pub(super) fn handoff(bridge: &WallpaperBridge) -> &FirstFrameHandoff {
    &bridge.first_frame_handoff
}

pub(crate) fn inert_login_controller(status: LaunchAtLoginStatus) -> LaunchAtLoginController {
    LaunchAtLoginController::fake(status)
}

pub(super) fn journal(bridge: &WallpaperBridge) -> &crate::engine::LoadJournal {
    &bridge.load_journal
}

pub(super) async fn stop_handoff(bridge: &mut WallpaperBridge) {
    bridge.first_frame_handoff.stop_for_test().await;
}
