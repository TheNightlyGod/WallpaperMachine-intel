mod activation;
mod activation_remaining;
mod audio_requests;
#[cfg(test)]
mod controlled_support;
mod facade;
mod facade_readiness;
mod load_journal;
mod render_settings;
pub(crate) mod revalidate;

pub use activation::{ActivationInputs, RenderBackendSurvey, VideoBackendRouting};
pub use activation_remaining::WallpaperAssignmentExt;
#[cfg(test)]
pub use facade::FakeEngineFacade;
pub(crate) use facade::displays_awaiting_first_frame;
pub use facade::{AudioCaptureDemand, EngineFacade, RealEngineFacade, SceneRuntimeReport};
#[cfg(test)]
pub(crate) use facade::{
    AudioRestartState, OutputWatchGate, RestartAction, apply_audio_capture_demand,
    handle_audio_restart_retry, handle_output_device_change,
};

#[cfg(test)]
pub(crate) mod mounted_readiness {
    pub(crate) use super::facade::{
        mutate_audio, mutate_scenes_and_prune, reconcile_with_readiness,
        register_first_frame_callback,
    };
    pub(crate) use super::facade_readiness::FirstFrameReadiness;
}
pub(crate) use load_journal::build_stamp;
pub use load_journal::{LoadJournal, LoadTicket};
