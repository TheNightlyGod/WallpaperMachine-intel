mod activation;
mod facade;
mod load_journal;
pub(crate) mod revalidate;

pub use activation::{
    ActivationInputs, NativeVideoRejection, NativeVideoRejections, RenderBackendSurvey,
    VideoBackendRouting, WallpaperAssignmentExt,
};
#[cfg(test)]
pub(crate) use facade::{
    AudioRestartState, OutputWatchGate, RestartAction, apply_audio_capture_demand,
    handle_audio_restart_retry, handle_output_device_change,
};
#[cfg(test)]
pub use facade::FakeEngineFacade;
pub(crate) use facade::displays_awaiting_first_frame;
pub use facade::{AudioCaptureDemand, EngineFacade, RealEngineFacade, RendererVideoPipelineState, SceneRuntimeReport};
pub(crate) use load_journal::build_stamp;
pub use load_journal::{LoadJournal, LoadTicket};
