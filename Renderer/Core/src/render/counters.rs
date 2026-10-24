//! Renderer work counters.
//!
//! The renderer is the only place that knows whether the work for a surface
//! actually stopped. A pause decision recorded on the application side proves
//! that a decision was delivered, not that a frame clock stopped ticking, a
//! command buffer stopped being submitted or a decoder stopped producing.
//!
//! Counting is process-wide and off by default. With it off every value is
//! zero, which reads as "not recorded" rather than "no work".

use crate::{owe::sys, project::SceneHandle};

/// One counted renderer event or state, named so callers never carry raw
//  indices across the FFI boundary.
///
/// The two groups answer different questions. Surface-exclusive work must stop
/// for a surface nobody can see. Source work belongs to the decoded media and
/// may legitimately keep running while one of its consumers is hidden, as long
/// as another consumer still presents the frames.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum RendererCounterKind {
    // Surface-exclusive work.
    TimerWakeups,
    DrawRequests,
    DrawTicksSuppressed,
    DrawsExecuted,
    DrawsDropped,
    RenderSubmissions,
    RenderFailures,
    PresentRequests,
    GpuCompletions,
    SimulationTicks,
    /// Frames that ran but were not drawn or presented because they would have
    /// put back exactly the pixels already on the surface.
    PresentsSkippedUnchanged,
    // Surface state.
    PauseReasons,
    TickIntervalMicros,
    ContentPeriodMicros,
    // Consumer work: this surface's use of decoded frames, including the
    // conversions and imports its own texture cache performs.
    VideoFramesSelected,
    VideoFramesReused,
    VideoFramesSkipped,
    VideoSelectedGeneration,
    VideoConversions,
    VideoImports,
    /// Bytes of converted video destination textures one surface's texture
    /// cache is keeping alive, and the most it ever kept alive. Gauges, not
    /// running totals. The ledger covers those destination textures alone:
    /// decode pixel buffers, Core Video plane wrappers and the drawables
    /// the layer hands out are outside it, so this is an
    /// allocation figure and never a residency or footprint measurement.
    VideoConversionLiveBytes,
    VideoConversionPeakLiveBytes,
    // Source work, shareable between consumers.
    VideoSourceCount,
    VideoSourceInstance,
    VideoDecodeOutputs,
    VideoSeeks,
}

impl RendererCounterKind {
    #[must_use]
    pub fn index(self) -> usize {
        let raw = match self {
            Self::TimerWakeups => sys::owe_renderer_counter_OWE_RC_TIMER_WAKEUPS,
            Self::DrawRequests => sys::owe_renderer_counter_OWE_RC_DRAW_REQUESTS,
            Self::DrawTicksSuppressed => sys::owe_renderer_counter_OWE_RC_DRAW_TICKS_SUPPRESSED,
            Self::DrawsExecuted => sys::owe_renderer_counter_OWE_RC_DRAWS_EXECUTED,
            Self::DrawsDropped => sys::owe_renderer_counter_OWE_RC_DRAWS_DROPPED,
            Self::RenderSubmissions => sys::owe_renderer_counter_OWE_RC_RENDER_SUBMISSIONS,
            Self::RenderFailures => sys::owe_renderer_counter_OWE_RC_RENDER_FAILURES,
            Self::PresentRequests => sys::owe_renderer_counter_OWE_RC_PRESENT_REQUESTS,
            Self::GpuCompletions => sys::owe_renderer_counter_OWE_RC_GPU_COMPLETIONS,
            Self::SimulationTicks => sys::owe_renderer_counter_OWE_RC_SIMULATION_TICKS,
            Self::PresentsSkippedUnchanged => {
                sys::owe_renderer_counter_OWE_RC_PRESENTS_SKIPPED_UNCHANGED
            }
            Self::PauseReasons => sys::owe_renderer_counter_OWE_RC_PAUSE_REASONS,
            Self::TickIntervalMicros => sys::owe_renderer_counter_OWE_RC_TICK_INTERVAL_MICROS,
            Self::ContentPeriodMicros => sys::owe_renderer_counter_OWE_RC_CONTENT_PERIOD_MICROS,
            Self::VideoSourceCount => sys::owe_renderer_counter_OWE_RC_VIDEO_SOURCE_COUNT,
            Self::VideoSourceInstance => sys::owe_renderer_counter_OWE_RC_VIDEO_SOURCE_INSTANCE,
            Self::VideoDecodeOutputs => sys::owe_renderer_counter_OWE_RC_VIDEO_DECODE_OUTPUTS,
            Self::VideoSeeks => sys::owe_renderer_counter_OWE_RC_VIDEO_SEEKS,
            Self::VideoFramesSelected => sys::owe_renderer_counter_OWE_RC_VIDEO_FRAMES_SELECTED,
            Self::VideoFramesReused => sys::owe_renderer_counter_OWE_RC_VIDEO_FRAMES_REUSED,
            Self::VideoFramesSkipped => sys::owe_renderer_counter_OWE_RC_VIDEO_FRAMES_SKIPPED,
            Self::VideoSelectedGeneration => {
                sys::owe_renderer_counter_OWE_RC_VIDEO_SELECTED_GENERATION
            }
            Self::VideoConversions => sys::owe_renderer_counter_OWE_RC_VIDEO_CONVERSIONS,
            Self::VideoImports => sys::owe_renderer_counter_OWE_RC_VIDEO_IMPORTS,
            Self::VideoConversionLiveBytes => {
                sys::owe_renderer_counter_OWE_RC_VIDEO_CONVERSION_LIVE_BYTES
            }
            Self::VideoConversionPeakLiveBytes => {
                sys::owe_renderer_counter_OWE_RC_VIDEO_CONVERSION_PEAK_LIVE_BYTES
            }
        };
        raw as usize
    }
}

/// Why a surface is not presenting. Independent bits: clearing one never clears
/// another, so a user's pause and a released surface stay distinguishable.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum RendererPauseReason {
    /// The frame clock was stopped by a pause decision.
    ClockStopped,
    /// The render surface was released or never initialized.
    RenderBlocked,
    /// No scene is loaded.
    NoScene,
}

impl RendererPauseReason {
    const ALL: [Self; 3] = [Self::ClockStopped, Self::RenderBlocked, Self::NoScene];

    #[must_use]
    pub fn mask(self) -> u64 {
        let raw = match self {
            Self::ClockStopped => sys::owe_renderer_pause_reason_OWE_RC_PAUSE_CLOCK_STOPPED,
            Self::RenderBlocked => sys::owe_renderer_pause_reason_OWE_RC_PAUSE_RENDER_BLOCKED,
            Self::NoScene => sys::owe_renderer_pause_reason_OWE_RC_PAUSE_NO_SCENE,
        };
        raw as u64
    }

    #[must_use]
    pub fn name(self) -> &'static str {
        match self {
            Self::ClockStopped => "clockStopped",
            Self::RenderBlocked => "renderBlocked",
            Self::NoScene => "noScene",
        }
    }

    #[must_use]
    pub fn decode(bits: u64) -> Vec<Self> {
        Self::ALL
            .into_iter()
            .filter(|reason| bits & reason.mask() != 0)
            .collect()
    }
}

/// Process-wide counters that belong to no single surface.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RendererSharedCounterKind {
    AudioAnalysisDeliveries,
    AudioAcceptedFrames,
}

impl RendererSharedCounterKind {
    #[must_use]
    pub fn index(self) -> usize {
        let raw = match self {
            Self::AudioAnalysisDeliveries => {
                sys::owe_renderer_shared_counter_OWE_RC_SHARED_AUDIO_ANALYSIS_DELIVERIES
            }
            Self::AudioAcceptedFrames => {
                sys::owe_renderer_shared_counter_OWE_RC_SHARED_AUDIO_ACCEPTED_FRAMES
            }
        };
        raw as usize
    }
}

/// Renderer work counters for one surface, with the identity a report needs to
/// keep surfaces apart.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RendererSurfaceCounters {
    pub display_id: u32,
    pub handle: SceneHandle,
    /// Renderer object identity. Two wallpapers that reused one display and one
    /// handle have different generations and must not be merged.
    pub generation: u64,
    /// Scene source this surface renders — the identity a shared decode session
    /// would key on.
    pub source_path: String,
    pub paused: bool,
    /// In `owe_renderer_counter` order. May be shorter than the caller's list
    /// if the renderer was built against a shorter one; missing values read as
    /// zero rather than as an error.
    pub values: Vec<u64>,
}

impl RendererSurfaceCounters {
    #[must_use]
    pub fn value(&self, counter: RendererCounterKind) -> u64 {
        self.values.get(counter.index()).copied().unwrap_or(0)
    }

    #[must_use]
    pub fn pause_reasons(&self) -> Vec<RendererPauseReason> {
        RendererPauseReason::decode(self.value(RendererCounterKind::PauseReasons))
    }
}

/// Reads one process-wide counter out of a shared snapshot.
#[must_use]
pub fn shared_value(values: &[u64], counter: RendererSharedCounterKind) -> u64 {
    values.get(counter.index()).copied().unwrap_or(0)
}
