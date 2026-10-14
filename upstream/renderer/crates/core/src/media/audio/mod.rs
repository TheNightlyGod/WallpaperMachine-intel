mod capture;
pub mod device_watch;

use std::{
    borrow::Cow,
    collections::HashSet,
    error::Error,
    fmt::{Display, Formatter},
    sync::Arc,
    time::Duration,
};

pub use capture::{DefaultAudioResponseController, PlatformAudioCaptureBackend};

use crate::project::SceneHandle;

/// Safe audio volume wrapper
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct AudioVolume(f32);

impl TryFrom<f32> for AudioVolume {
    type Error = AudioInputError;

    fn try_from(value: f32) -> Result<Self, Self::Error> {
        if !value.is_finite() || !(0.0..=1.0).contains(&value) {
            return Err(AudioInputError::InvalidAudioVolume(value));
        }
        Ok(Self(value))
    }
}

impl From<AudioVolume> for f32 {
    fn from(value: AudioVolume) -> Self {
        value.0
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct InterleavedStereoF32<'a> {
    sample_rate: u32,
    samples: &'a [f32],
}

impl<'a> InterleavedStereoF32<'a> {
    /// Creates an interleaved stereo PCM view.
    ///
    /// # Errors
    ///
    /// Returns [`AudioInputError::InvalidSampleRate`] when `sample_rate` is
    /// zero, [`AudioInputError::EmptyInput`] when `samples` is empty, or
    /// [`AudioInputError::OddSampleCount`] when the buffer does not contain
    /// complete left/right sample pairs.
    pub fn new(sample_rate: u32, samples: &'a [f32]) -> Result<Self, AudioInputError> {
        if sample_rate == 0 {
            return Err(AudioInputError::InvalidSampleRate);
        }
        if samples.is_empty() {
            return Err(AudioInputError::EmptyInput);
        }
        if !samples.len().is_multiple_of(2) {
            return Err(AudioInputError::OddSampleCount(samples.len()));
        }

        Ok(Self {
            sample_rate,
            samples,
        })
    }

    #[must_use]
    pub fn sample_rate(self) -> u32 {
        self.sample_rate
    }

    #[must_use]
    pub fn frame_count(self) -> u32 {
        u32::try_from(self.samples.len() / 2).unwrap_or(u32::MAX)
    }

    #[must_use]
    pub fn samples(self) -> &'a [f32] {
        self.samples
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct MonoPcmF32<'a> {
    sample_rate: u32,
    samples: Cow<'a, [f32]>,
}

impl<'a> MonoPcmF32<'a> {
    /// Creates a borrowed mono PCM view.
    ///
    /// # Errors
    ///
    /// Returns [`AudioInputError::InvalidSampleRate`] when `sample_rate` is
    /// zero or [`AudioInputError::EmptyInput`] when `samples` is empty.
    pub fn borrowed(sample_rate: u32, samples: &'a [f32]) -> Result<Self, AudioInputError> {
        if sample_rate == 0 {
            return Err(AudioInputError::InvalidSampleRate);
        }
        if samples.is_empty() {
            return Err(AudioInputError::EmptyInput);
        }
        Ok(Self {
            sample_rate,
            samples: Cow::Borrowed(samples),
        })
    }

    /// Creates an owned mono PCM buffer.
    ///
    /// # Errors
    ///
    /// Returns [`AudioInputError::InvalidSampleRate`] when `sample_rate` is
    /// zero or [`AudioInputError::EmptyInput`] when `samples` is empty.
    pub fn owned(sample_rate: u32, samples: Vec<f32>) -> Result<Self, AudioInputError> {
        if sample_rate == 0 {
            return Err(AudioInputError::InvalidSampleRate);
        }
        if samples.is_empty() {
            return Err(AudioInputError::EmptyInput);
        }
        Ok(Self {
            sample_rate,
            samples: Cow::Owned(samples),
        })
    }

    #[must_use]
    pub fn sample_rate(&self) -> u32 {
        self.sample_rate
    }

    #[must_use]
    pub fn frame_count(&self) -> u32 {
        u32::try_from(self.samples.len()).unwrap_or(u32::MAX)
    }

    #[must_use]
    pub fn samples(&self) -> &[f32] {
        &self.samples
    }
}

/// Channel layout of the platform system-audio tap actually in use.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AudioTapChannelMode {
    Mono,
    Stereo,
}

/// One fixed-size analysis block ready for the renderer, borrowed from the
/// resampler's own storage so steady-state resampling never allocates.
#[derive(Clone, Debug, PartialEq)]
pub enum AudioResponseBlock<'a> {
    Mono(MonoPcmF32<'a>),
    Stereo(InterleavedStereoF32<'a>),
}

/// Resamples captured PCM to the fixed analysis rate, preserving the channel
/// layout it was fed: a stereo submission stays two independent channels all
/// the way to the analyser.
#[derive(Debug)]
pub struct AudioResponseResampler {
    /// Interleaved when `channels == 2`, otherwise one sample per frame.
    pending: Vec<f32>,
    channels: usize,
    source_position: f64,
    previous: [f32; 2],
    has_previous: bool,
    source_sample_rate: Option<u32>,
}

impl Default for AudioResponseResampler {
    fn default() -> Self {
        Self {
            pending: Vec::new(),
            channels: 1,
            source_position: 0.0,
            previous: [0.0; 2],
            has_previous: false,
            source_sample_rate: None,
        }
    }
}

impl AudioResponseResampler {
    /// The renderer's analysis rate (`kAudioResponseSampleRate`). The usual
    /// 48 kHz tap passes through untouched; the interpolation below has no
    /// anti-alias filter, so it must never decimate audible content.
    pub const TARGET_SAMPLE_RATE: u32 = 48_000;
    /// A 60th of a second per submission.
    pub const BLOCK_FRAMES: usize = 800;

    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Appends mono PCM and emits every complete fixed-size mono block.
    ///
    /// # Panics
    ///
    /// Panics only if the fixed-size block emitted internally is rejected as an
    /// invalid mono PCM buffer, which would indicate a broken resampler
    /// invariant.
    pub fn push_mono(
        &mut self,
        frames: &MonoPcmF32<'_>,
        mut emit: impl FnMut(AudioResponseBlock<'_>),
    ) {
        self.accept(frames.sample_rate(), frames.samples(), 1);
        self.drain_blocks(|block| {
            emit(AudioResponseBlock::Mono(
                MonoPcmF32::borrowed(Self::TARGET_SAMPLE_RATE, block)
                    .expect("resampler emits non-empty fixed-size blocks"),
            ));
        });
    }

    /// Appends interleaved stereo PCM and emits every complete fixed-size
    /// stereo block, keeping the two channels independent.
    ///
    /// # Panics
    ///
    /// Panics only if the fixed-size block emitted internally is rejected as an
    /// invalid stereo PCM buffer, which would indicate a broken resampler
    /// invariant.
    pub fn push_stereo(
        &mut self,
        frames: &InterleavedStereoF32<'_>,
        mut emit: impl FnMut(AudioResponseBlock<'_>),
    ) {
        self.accept(frames.sample_rate(), frames.samples(), 2);
        self.drain_blocks(|block| {
            emit(AudioResponseBlock::Stereo(
                InterleavedStereoF32::new(Self::TARGET_SAMPLE_RATE, block)
                    .expect("resampler emits non-empty fixed-size blocks"),
            ));
        });
    }

    fn accept(&mut self, source_sample_rate: u32, samples: &[f32], channels: usize) {
        // Interpolation state and buffered frames belong to one rate and one
        // channel layout; either change restarts from an empty buffer.
        if self.source_sample_rate != Some(source_sample_rate) || self.channels != channels {
            if self.channels != channels {
                self.pending.clear();
                self.channels = channels;
            }
            self.source_sample_rate = Some(source_sample_rate);
            self.has_previous = false;
            self.source_position = 0.0;
        }

        if source_sample_rate == Self::TARGET_SAMPLE_RATE {
            self.pending.extend_from_slice(samples);
        } else {
            self.append_resampled(source_sample_rate, samples);
        }
    }

    fn drain_blocks(&mut self, mut emit: impl FnMut(&[f32])) {
        let block_len = Self::BLOCK_FRAMES * self.channels;
        let mut consumed = 0usize;
        while consumed + block_len <= self.pending.len() {
            emit(&self.pending[consumed..consumed + block_len]);
            consumed += block_len;
        }
        if consumed > 0 {
            // One compaction of the sub-block remainder per call, never a
            // prefix shuffle per emitted block.
            self.pending.copy_within(consumed.., 0);
            self.pending.truncate(self.pending.len() - consumed);
        }
    }

    #[allow(
        clippy::cast_possible_truncation,
        clippy::cast_precision_loss,
        clippy::cast_sign_loss
    )]
    fn append_resampled(&mut self, source_sample_rate: u32, samples: &[f32]) {
        let channels = self.channels;
        let step = f64::from(source_sample_rate) / f64::from(Self::TARGET_SAMPLE_RATE);
        let carried = usize::from(self.has_previous);
        let previous = self.previous;
        let total_frames = carried + (samples.len() / channels);
        // The carried tail frame is addressed in place instead of being
        // prepended into a scratch buffer.
        let sample_at = |frame: usize, channel: usize| {
            if frame < carried {
                previous[channel]
            } else {
                samples[((frame - carried) * channels) + channel]
            }
        };

        while self.source_position + 1.0 < total_frames as f64 {
            let index = self.source_position.floor() as usize;
            let fraction = (self.source_position - index as f64) as f32;
            for channel in 0..channels {
                let current = sample_at(index, channel);
                let next = sample_at(index + 1, channel);
                self.pending.push(current + ((next - current) * fraction));
            }
            self.source_position += step;
        }

        if total_frames > 0 {
            for channel in 0..channels {
                self.previous[channel] = sample_at(total_frames - 1, channel);
            }
            self.has_previous = true;
            self.source_position = (self.source_position - (total_frames - 1) as f64).max(0.0);
        }
    }

    #[cfg(test)]
    #[must_use]
    pub fn pending_for_testing(&self) -> &[f32] {
        &self.pending
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum AudioInputError {
    InvalidSampleRate,
    EmptyInput,
    InvalidAudioVolume(f32),
    OddSampleCount(usize),
}

impl Display for AudioInputError {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::InvalidSampleRate => write!(f, "sample_rate must be greater than zero"),
            Self::EmptyInput => write!(f, "samples must not be empty"),
            Self::OddSampleCount(count) => {
                write!(f, "samples must contain stereo pairs, got {count} values")
            }
            Self::InvalidAudioVolume(volume) => {
                write!(f, "audio volume must be between 0.0 and 1.0, got {volume}")
            }
        }
    }
}

impl Error for AudioInputError {}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum AudioCaptureError {
    UnsupportedPlatform,
    PermissionDenied(String),
    Platform(String),
    Engine(String),
}

impl Display for AudioCaptureError {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::UnsupportedPlatform => {
                write!(f, "system audio capture is not supported on this platform")
            }
            Self::PermissionDenied(message) | Self::Platform(message) | Self::Engine(message) => {
                write!(f, "{message}")
            }
        }
    }
}

impl Error for AudioCaptureError {}

pub trait AudioFrameConsumer: Send + Sync {
    /// Accepts interleaved stereo `float32` PCM in LRLR order.
    /// The sample rate is supplied by the caller and is not resampled by this
    /// API.
    ///
    /// # Errors
    ///
    /// Returns [`AudioCaptureError`] when the consumer cannot forward or
    /// process the supplied frames.
    fn submit_audio_frames(
        &self,
        frames: InterleavedStereoF32<'_>,
    ) -> Result<(), AudioCaptureError>;

    /// Accepts mono `float32` PCM.
    ///
    /// Consumers must not satisfy this by duplicating the mono samples into an
    /// interleaved pair and forwarding them to [`Self::submit_audio_frames`]:
    /// downstream analysis reports a two-channel submission as stereo, and a
    /// mono source is not stereo.
    ///
    /// # Errors
    ///
    /// Returns [`AudioCaptureError`] when the consumer cannot forward or
    /// process the supplied frames.
    fn submit_mono_audio_frames(&self, frames: MonoPcmF32<'_>) -> Result<(), AudioCaptureError>;
}

pub trait AudioResponseEngine: AudioFrameConsumer {
    /// Enables or disables audio response for one scene.
    ///
    /// # Errors
    ///
    /// Returns [`AudioCaptureError`] when the engine cannot update the scene.
    fn set_audio_response_enabled(
        &self,
        handle: SceneHandle,
        enabled: bool,
    ) -> Result<(), AudioCaptureError>;
}

pub trait AudioCaptureBackend {
    /// Returns the backend's current permission status or capture-start hint.
    ///
    /// # Errors
    ///
    /// Returns [`AudioCaptureError`] when the platform permission check fails.
    fn has_permission(&self) -> Result<bool, AudioCaptureError>;
    /// Requests permission or allows a subsequent capture startup to request it.
    ///
    /// The macOS CoreAudio backend only records a hint here; OS authorization
    /// happens when tap recording starts. A `true` result is not an OS grant.
    ///
    /// # Errors
    ///
    /// Returns [`AudioCaptureError`] when the platform permission prompt or
    /// status check fails.
    fn request_permission(&mut self) -> Result<bool, AudioCaptureError>;
    /// Starts audio capture and forwards captured frames to `consumer`.
    ///
    /// # Errors
    ///
    /// Returns [`AudioCaptureError`] when platform capture setup fails.
    fn start(&mut self, consumer: Arc<dyn AudioFrameConsumer>) -> Result<(), AudioCaptureError>;
    /// Stops audio capture.
    ///
    /// # Errors
    ///
    /// Returns [`AudioCaptureError`] when platform teardown fails.
    fn stop(&mut self) -> Result<(), AudioCaptureError>;
    #[must_use]
    fn is_running(&self) -> bool;
}

/// How long to wait before each further attempt to bring the tap back after a
/// rebuild failed. The first attempt is immediate; these are the retries, so a
/// rebuild is tried four times in all before it is left to the next scene or
/// demand change.
pub const RESTART_RETRY_DELAYS: [Duration; 3] = [
    Duration::from_millis(500),
    Duration::from_millis(1000),
    Duration::from_millis(1500),
];

/// What [`AudioCaptureController::restart_capture`] did.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RestartOutcome {
    /// Nothing was rebuilt: nobody wants capture right now, it is suspended, or
    /// it was never running.
    NotRunning,
    /// The tap was stopped and started again.
    Restarted,
}

pub struct AudioCaptureController<B: AudioCaptureBackend> {
    consumer: Arc<dyn AudioFrameConsumer>,
    backend: B,
    enabled_handles: HashSet<SceneHandle>,
    suspended: bool,
    external_consumers: bool,
    /// A rebuild stopped the tap and could not start it again. Capture is still
    /// wanted, so the next [`AudioCaptureController::restart_capture`] starts
    /// it without a device change having to be seen again.
    restart_pending: bool,
}

impl<B: AudioCaptureBackend> AudioCaptureController<B> {
    #[must_use]
    pub fn new(consumer: Arc<dyn AudioFrameConsumer>, backend: B) -> Self {
        Self {
            consumer,
            backend,
            enabled_handles: HashSet::new(),
            suspended: false,
            external_consumers: false,
            restart_pending: false,
        }
    }

    /// Returns the backend's current permission status or capture-start hint.
    ///
    /// # Errors
    ///
    /// Returns [`AudioCaptureError`] when the backend permission check fails.
    pub fn has_permission(&self) -> Result<bool, AudioCaptureError> {
        self.backend.has_permission()
    }

    /// Requests permission (or enables the backend's startup authorization path)
    /// and starts capture if scenes are already enabled.
    ///
    /// # Errors
    ///
    /// Returns [`AudioCaptureError`] when permission or capture startup fails.
    pub fn request_permission(&mut self) -> Result<bool, AudioCaptureError> {
        let granted = self.backend.request_permission()?;
        if granted {
            self.sync_capture_state()?;
        }
        Ok(granted)
    }

    /// Enables or disables capture for one scene.
    /// Scenes remain pending when permission is unavailable. A failed new
    /// activation is rolled back; removals remain committed even if stopping
    /// fails, so departed scenes never retain capture ownership.
    ///
    /// # Errors
    ///
    /// Returns [`AudioCaptureError`] when synchronizing backend capture state
    /// fails.
    pub fn set_scene_capturing(
        &mut self,
        handle: SceneHandle,
        enabled: bool,
    ) -> Result<(), AudioCaptureError> {
        let inserted = if enabled {
            self.enabled_handles.insert(handle)
        } else {
            self.enabled_handles.remove(&handle);
            false
        };
        if let Err(error) = self.sync_capture_state() {
            if inserted {
                self.enabled_handles.remove(&handle);
            }
            return Err(error);
        }
        Ok(())
    }

    /// Releases capture ownership for scenes absent from `handles`.
    ///
    /// Removals are committed even if backend synchronization fails. Calling
    /// this again retries synchronization without resurrecting departed scenes.
    ///
    /// # Errors
    ///
    /// Returns [`AudioCaptureError`] when starting or stopping capture fails.
    pub fn retain_scenes(&mut self, handles: &[SceneHandle]) -> Result<(), AudioCaptureError> {
        self.enabled_handles
            .retain(|handle| handles.contains(handle));
        self.sync_capture_state()
    }

    /// Updates presentation suspension and demand from consumers without scene
    /// handles (such as web pages) together, without briefly restarting capture.
    /// Scene ownership is preserved. A failed transition restores both inputs.
    ///
    /// # Errors
    ///
    /// Returns [`AudioCaptureError`] when starting or stopping capture fails.
    pub fn set_demand(
        &mut self,
        suspended: bool,
        external_consumers: bool,
    ) -> Result<(), AudioCaptureError> {
        let previous = (self.suspended, self.external_consumers);
        self.suspended = suspended;
        self.external_consumers = external_consumers;
        if let Err(error) = self.sync_capture_state() {
            (self.suspended, self.external_consumers) = previous;
            if let Err(rollback) = self.sync_capture_state() {
                return Err(AudioCaptureError::Platform(format!(
                    "{error}; audio capture rollback failed: {rollback}"
                )));
            }
            return Err(error);
        }
        Ok(())
    }

    #[must_use]
    pub fn is_capturing(&self) -> bool {
        self.backend.is_running()
    }

    #[must_use]
    pub fn active_scene_count(&self) -> usize {
        self.enabled_handles.len()
    }

    #[must_use]
    pub fn backend(&self) -> &B {
        &self.backend
    }

    /// Stops the tap and starts it again, for a change underneath it such as a
    /// new default output device.
    ///
    /// Only a tap that is running is rebuilt, and only while capture is wanted.
    /// Permission was granted when it first started, so a rebuild never asks
    /// again; a controller that is suspended, has no consumers or was never
    /// started does nothing and starts fresh when it is next needed. If the tap
    /// stops but cannot start again, the error is returned and the next call
    /// tries to start it again, so a caller can retry without a second device
    /// change. Any scene or demand change that starts capture also heals it.
    ///
    /// # Errors
    ///
    /// Returns [`AudioCaptureError`] when stopping or starting the tap fails.
    pub fn restart_capture(&mut self) -> Result<RestartOutcome, AudioCaptureError> {
        if !self.wants_capture() {
            self.restart_pending = false;
            return Ok(RestartOutcome::NotRunning);
        }
        if self.backend.is_running() {
            self.backend.stop()?;
            self.restart_pending = true;
        } else if !self.restart_pending {
            return Ok(RestartOutcome::NotRunning);
        }
        if !self.backend.has_permission()? {
            self.restart_pending = false;
            return Ok(RestartOutcome::NotRunning);
        }
        self.backend.start(Arc::clone(&self.consumer))?;
        self.restart_pending = false;
        Ok(RestartOutcome::Restarted)
    }

    /// Whether a tap should be running right now: capture is not suspended
    /// and a scene or another consumer needs it. A change of output device
    /// matters only then, so this is what a caller watching for one keys off.
    #[must_use]
    pub fn wants_capture(&self) -> bool {
        !self.suspended && (self.external_consumers || !self.enabled_handles.is_empty())
    }

    fn sync_capture_state(&mut self) -> Result<(), AudioCaptureError> {
        let should_run = self.wants_capture();
        if should_run {
            if !self.backend.is_running() && self.backend.has_permission()? {
                self.backend.start(Arc::clone(&self.consumer))?;
            }
        } else if self.backend.is_running() {
            self.backend.stop()?;
        }
        if !should_run || self.backend.is_running() {
            self.restart_pending = false;
        }
        Ok(())
    }
}

impl<B: AudioCaptureBackend> Drop for AudioCaptureController<B> {
    fn drop(&mut self) {
        if self.backend.is_running() {
            let _ = self.backend.stop();
        }
    }
}

/// macOS hosts using the built-in backend must provide
/// `NSAudioCaptureUsageDescription` in the embedding app bundle. The native
/// backend captures system output audio and forwards interleaved stereo
/// `float32` PCM while preserving the source sample rate.
pub struct AudioResponseController<E: AudioResponseEngine + 'static, B: AudioCaptureBackend> {
    engine: Arc<E>,
    backend: B,
    enabled_handles: HashSet<SceneHandle>,
}

impl<E: AudioResponseEngine + 'static, B: AudioCaptureBackend> AudioResponseController<E, B> {
    #[must_use]
    pub fn new(engine: Arc<E>, backend: B) -> Self {
        Self {
            engine,
            backend,
            enabled_handles: HashSet::new(),
        }
    }

    /// Returns whether the backend currently has capture permission.
    ///
    /// # Errors
    ///
    /// Returns [`AudioCaptureError`] when the backend permission check fails.
    pub fn has_permission(&self) -> Result<bool, AudioCaptureError> {
        self.backend.has_permission()
    }

    /// Requests capture permission and starts capture if scenes are already
    /// enabled.
    ///
    /// # Errors
    ///
    /// Returns [`AudioCaptureError`] when permission or capture startup fails.
    pub fn request_permission(&mut self) -> Result<bool, AudioCaptureError> {
        let granted = self.backend.request_permission()?;
        if granted {
            self.sync_capture_state()?;
        }
        Ok(granted)
    }

    /// Enables or disables audio response for one scene and syncs capture
    /// state.
    ///
    /// # Errors
    ///
    /// Returns [`AudioCaptureError`] when the engine update or capture state
    /// sync fails.
    pub fn set_scene_enabled(
        &mut self,
        handle: SceneHandle,
        enabled: bool,
    ) -> Result<(), AudioCaptureError> {
        self.engine.set_audio_response_enabled(handle, enabled)?;
        if enabled {
            self.enabled_handles.insert(handle);
        } else {
            self.enabled_handles.remove(&handle);
        }
        self.sync_capture_state()
    }

    #[must_use]
    pub fn is_capturing(&self) -> bool {
        self.backend.is_running()
    }

    #[must_use]
    pub fn active_scene_count(&self) -> usize {
        self.enabled_handles.len()
    }

    #[must_use]
    pub fn backend(&self) -> &B {
        &self.backend
    }

    fn sync_capture_state(&mut self) -> Result<(), AudioCaptureError> {
        let should_run = !self.enabled_handles.is_empty();
        if should_run {
            if !self.backend.is_running() && self.backend.has_permission()? {
                self.backend.start(self.engine.clone())?;
            }
        } else if self.backend.is_running() {
            self.backend.stop()?;
        }
        Ok(())
    }
}

impl<E: AudioResponseEngine + 'static, B: AudioCaptureBackend> Drop
    for AudioResponseController<E, B>
{
    fn drop(&mut self) {
        if self.backend.is_running() {
            let _ = self.backend.stop();
        }
    }
}

#[cfg(test)]
mod capture_controller_tests {
    use super::*;

    #[derive(Default)]
    struct TestConsumer;

    impl AudioFrameConsumer for TestConsumer {
        fn submit_audio_frames(
            &self,
            _frames: InterleavedStereoF32<'_>,
        ) -> Result<(), AudioCaptureError> {
            Ok(())
        }

        fn submit_mono_audio_frames(
            &self,
            _frames: MonoPcmF32<'_>,
        ) -> Result<(), AudioCaptureError> {
            Ok(())
        }
    }

    #[derive(Default)]
    struct TestBackend {
        running: bool,
        permission_pending: bool,
        fail_start: bool,
        fail_stop: bool,
        starts: usize,
        stops: usize,
    }

    impl AudioCaptureBackend for TestBackend {
        fn has_permission(&self) -> Result<bool, AudioCaptureError> {
            Ok(!self.permission_pending)
        }

        fn request_permission(&mut self) -> Result<bool, AudioCaptureError> {
            self.permission_pending = false;
            Ok(true)
        }

        fn start(
            &mut self,
            _consumer: Arc<dyn AudioFrameConsumer>,
        ) -> Result<(), AudioCaptureError> {
            if std::mem::take(&mut self.fail_start) {
                return Err(AudioCaptureError::Platform("start failed".into()));
            }
            self.running = true;
            self.starts += 1;
            Ok(())
        }

        fn stop(&mut self) -> Result<(), AudioCaptureError> {
            if std::mem::take(&mut self.fail_stop) {
                return Err(AudioCaptureError::Platform("stop failed".into()));
            }
            self.running = false;
            self.stops += 1;
            Ok(())
        }

        fn is_running(&self) -> bool {
            self.running
        }
    }

    #[test]
    fn external_consumers_capture_without_scenes_and_share_the_existing_tap() {
        let mut controller =
            AudioCaptureController::new(Arc::new(TestConsumer), TestBackend::default());
        controller.set_demand(false, false).unwrap();
        assert!(!controller.is_capturing(), "resume alone is not capture demand");
        controller.set_demand(false, true).unwrap();
        assert!(controller.is_capturing(), "a web-only session needs no scene handle");
        assert_eq!(controller.active_scene_count(), 0);
        controller.set_demand(false, true).unwrap();
        controller.retain_scenes(&[]).unwrap();
        assert!(controller.is_capturing(), "scene cleanup must preserve web ownership");

        let handle = SceneHandle::new(7);
        controller.set_scene_capturing(handle, true).unwrap();
        controller.set_demand(false, false).unwrap();
        assert!(controller.is_capturing(), "the scene still owns capture");
        controller.set_demand(false, true).unwrap();
        controller.retain_scenes(&[]).unwrap();
        assert_eq!(controller.backend().starts, 1, "all consumers share one tap");
        assert_eq!(controller.backend().stops, 0);
        controller.set_demand(false, false).unwrap();
        assert!(!controller.is_capturing());
        assert_eq!(controller.backend().stops, 1);
    }

    #[test]
    fn external_demand_obeys_suspension_and_permission() {
        let backend = TestBackend { permission_pending: true, ..TestBackend::default() };
        let mut controller = AudioCaptureController::new(Arc::new(TestConsumer), backend);
        controller.set_demand(true, true).unwrap();
        controller.request_permission().unwrap();
        assert!(!controller.is_capturing(), "permission does not override suspension");
        controller.set_demand(false, true).unwrap();
        assert!(controller.is_capturing());
        controller.set_demand(true, true).unwrap();
        assert!(!controller.is_capturing());
        controller.set_demand(false, false).unwrap();
        assert!(!controller.is_capturing(), "a departed page must not resume capture");

        controller.backend.permission_pending = true;
        controller.set_demand(false, true).unwrap();
        assert!(!controller.is_capturing());
        controller.request_permission().unwrap();
        assert!(controller.is_capturing(), "pending external demand survives authorization");
    }

    #[test]
    fn failed_external_transition_restores_both_demand_inputs() {
        let backend = TestBackend { fail_start: true, ..TestBackend::default() };
        let mut controller = AudioCaptureController::new(Arc::new(TestConsumer), backend);
        controller.set_demand(true, false).unwrap();
        assert!(controller.set_demand(false, true).is_err());
        controller.retain_scenes(&[]).unwrap();
        assert!(!controller.is_capturing(), "failed subscription left no demand");
        controller.set_demand(false, false).unwrap();
        assert!(!controller.is_capturing());
        controller.set_demand(false, true).unwrap();
        controller.backend.fail_stop = true;
        assert!(controller.set_demand(true, false).is_err());
        controller.retain_scenes(&[]).unwrap();
        assert!(controller.is_capturing(), "failed stop restores the running intent");
        controller.set_demand(false, false).unwrap();
        assert!(!controller.is_capturing());
    }

    #[test]
    fn retaining_scenes_stops_capture_only_after_final_owner_departs() {
        let consumer = Arc::new(TestConsumer);
        let backend = TestBackend::default();
        let mut controller = AudioCaptureController::new(consumer, backend);
        let handle = SceneHandle::new(7);

        controller.set_scene_capturing(handle, true).unwrap();
        let other = SceneHandle::new(8);
        controller.set_scene_capturing(other, true).unwrap();
        controller.retain_scenes(&[other]).unwrap();

        assert!(controller.is_capturing());
        assert_eq!(controller.active_scene_count(), 1);
        controller.retain_scenes(&[]).unwrap();
        assert!(!controller.is_capturing());
        assert_eq!(controller.active_scene_count(), 0);
    }

    #[test]
    fn failed_new_activation_does_not_leave_capture_ownership() {
        let backend = TestBackend {
            fail_start: true,
            ..TestBackend::default()
        };
        let mut controller = AudioCaptureController::new(Arc::new(TestConsumer), backend);
        assert!(
            controller
                .set_scene_capturing(SceneHandle::new(7), true)
                .is_err()
        );
        assert_eq!(controller.active_scene_count(), 0);
        controller.request_permission().unwrap();
        assert!(!controller.is_capturing());
        controller
            .set_scene_capturing(SceneHandle::new(8), true)
            .unwrap();
        assert!(controller.is_capturing());
    }

    #[test]
    fn pending_scene_survives_failed_permission_start_and_repeated_enable() {
        let backend = TestBackend {
            permission_pending: true,
            fail_start: true,
            ..TestBackend::default()
        };
        let mut controller = AudioCaptureController::new(Arc::new(TestConsumer), backend);
        let handle = SceneHandle::new(7);
        controller.set_scene_capturing(handle, true).unwrap();
        assert!(!controller.is_capturing());
        assert!(controller.request_permission().is_err());
        assert_eq!(controller.active_scene_count(), 1);
        controller.backend.fail_start = true;
        assert!(controller.set_scene_capturing(handle, true).is_err());
        assert_eq!(controller.active_scene_count(), 1);
        controller.request_permission().unwrap();
        assert!(controller.is_capturing());
    }

    #[test]
    fn removals_stay_committed_when_stop_fails_and_allow_teardown_retry() {
        for retain in [false, true] {
            let backend = TestBackend {
                fail_stop: true,
                ..TestBackend::default()
            };
            let mut controller = AudioCaptureController::new(Arc::new(TestConsumer), backend);
            let handle = SceneHandle::new(7);
            controller.set_scene_capturing(handle, true).unwrap();
            let result = if retain {
                controller.retain_scenes(&[])
            } else {
                controller.set_scene_capturing(handle, false)
            };
            assert!(result.is_err());
            assert_eq!(controller.active_scene_count(), 0);
            assert!(controller.is_capturing());
            controller.retain_scenes(&[]).unwrap();
            assert!(!controller.is_capturing());
        }
    }

    #[test]
    fn suspending_stops_capture_and_resuming_restores_enabled_scenes() {
        let backend = TestBackend::default();
        let mut controller = AudioCaptureController::new(Arc::new(TestConsumer), backend);
        controller
            .set_scene_capturing(SceneHandle::new(1), true)
            .unwrap();
        assert!(controller.is_capturing());

        controller.set_demand(true, false).unwrap();
        assert!(!controller.is_capturing());
        assert_eq!(controller.active_scene_count(), 1);

        controller.set_demand(false, false).unwrap();
        assert!(controller.is_capturing());
    }

    #[test]
    fn failed_resume_preserves_suspension_across_capture_updates() {
        let mut controller =
            AudioCaptureController::new(Arc::new(TestConsumer), TestBackend::default());
        controller
            .set_scene_capturing(SceneHandle::new(1), true)
            .unwrap();
        controller.set_demand(true, false).unwrap();
        controller.backend.fail_start = true;

        let error = controller.set_demand(false, false).unwrap_err();
        assert_eq!(error, AudioCaptureError::Platform("start failed".into()));
        assert!(!controller.is_capturing());
        controller
            .set_scene_capturing(SceneHandle::new(2), true)
            .unwrap();
        assert!(!controller.is_capturing());

        controller.set_demand(true, false).unwrap();
        controller.set_demand(false, false).unwrap();
        assert!(controller.is_capturing());
        controller.set_demand(true, false).unwrap();
        assert!(!controller.is_capturing());
        assert_eq!(controller.active_scene_count(), 2);
    }

    #[test]
    fn restart_rebuilds_a_running_capture_once() {
        let mut controller =
            AudioCaptureController::new(Arc::new(TestConsumer), TestBackend::default());
        controller
            .set_scene_capturing(SceneHandle::new(1), true)
            .unwrap();
        controller
            .set_scene_capturing(SceneHandle::new(2), true)
            .unwrap();
        assert_eq!(controller.backend().starts, 1, "two scenes share one tap");

        assert_eq!(controller.restart_capture().unwrap(), RestartOutcome::Restarted);

        assert!(controller.is_capturing());
        assert_eq!(controller.backend().stops, 1, "the old tap is released first");
        assert_eq!(controller.backend().starts, 2, "one new tap serves both scenes");
        assert_eq!(controller.active_scene_count(), 2);
    }

    #[test]
    fn restart_is_a_no_op_while_stopped() {
        let mut controller =
            AudioCaptureController::new(Arc::new(TestConsumer), TestBackend::default());
        assert_eq!(controller.restart_capture().unwrap(), RestartOutcome::NotRunning);
        assert_eq!((controller.backend().starts, controller.backend().stops), (0, 0));

        // Capture is wanted but waiting for authorization: a device change
        // must not start it, because starting is what asks for permission.
        let backend = TestBackend { permission_pending: true, ..TestBackend::default() };
        let mut waiting = AudioCaptureController::new(Arc::new(TestConsumer), backend);
        waiting.set_scene_capturing(SceneHandle::new(1), true).unwrap();
        assert_eq!(waiting.restart_capture().unwrap(), RestartOutcome::NotRunning);
        assert_eq!(waiting.backend().starts, 0);
        assert!(!waiting.is_capturing());
    }

    #[test]
    fn restart_is_a_no_op_while_suspended() {
        let mut controller =
            AudioCaptureController::new(Arc::new(TestConsumer), TestBackend::default());
        controller
            .set_scene_capturing(SceneHandle::new(1), true)
            .unwrap();
        controller.set_demand(true, false).unwrap();
        assert!(!controller.is_capturing());
        let (starts, stops) = (controller.backend().starts, controller.backend().stops);

        assert_eq!(controller.restart_capture().unwrap(), RestartOutcome::NotRunning);

        assert_eq!((controller.backend().starts, controller.backend().stops), (starts, stops));
        controller.set_demand(false, false).unwrap();
        assert!(controller.is_capturing(), "resuming starts a tap on the current device");
    }

    #[test]
    fn a_failed_restart_leaves_capture_stopped_and_the_next_sync_starts_it() {
        let mut controller =
            AudioCaptureController::new(Arc::new(TestConsumer), TestBackend::default());
        controller
            .set_scene_capturing(SceneHandle::new(1), true)
            .unwrap();
        controller.backend.fail_start = true;

        let error = controller.restart_capture().unwrap_err();

        assert_eq!(error, AudioCaptureError::Platform("start failed".into()));
        assert!(!controller.is_capturing(), "the old tap is gone and no new one started");
        assert_eq!(controller.active_scene_count(), 1, "the scene keeps its claim on capture");
        controller.set_demand(false, false).unwrap();
        assert!(controller.is_capturing(), "the next scene or demand change heals it");
    }

    #[test]
    fn a_failed_restart_can_be_retried_without_another_device_change() {
        let mut controller =
            AudioCaptureController::new(Arc::new(TestConsumer), TestBackend::default());
        controller
            .set_scene_capturing(SceneHandle::new(1), true)
            .unwrap();
        controller.backend.fail_start = true;
        assert!(controller.restart_capture().is_err());
        assert!(!controller.is_capturing());

        assert_eq!(controller.restart_capture().unwrap(), RestartOutcome::Restarted);

        assert!(controller.is_capturing());
        assert_eq!(controller.backend().starts, 2);
        assert_eq!(
            controller.restart_capture().unwrap(),
            RestartOutcome::Restarted,
            "a healthy tap is rebuilt again on the next device change"
        );
        assert_eq!(controller.backend().starts, 3);
    }

    #[test]
    fn a_pending_restart_is_dropped_once_nobody_wants_capture() {
        for release in [
            |controller: &mut AudioCaptureController<TestBackend>| {
                controller.set_scene_capturing(SceneHandle::new(1), false).unwrap();
            },
            |controller: &mut AudioCaptureController<TestBackend>| {
                controller.set_demand(true, false).unwrap();
            },
        ] {
            let mut controller =
                AudioCaptureController::new(Arc::new(TestConsumer), TestBackend::default());
            controller
                .set_scene_capturing(SceneHandle::new(1), true)
                .unwrap();
            controller.backend.fail_start = true;
            assert!(controller.restart_capture().is_err());

            release(&mut controller);
            assert_eq!(controller.restart_capture().unwrap(), RestartOutcome::NotRunning);

            assert!(!controller.is_capturing());
            assert_eq!(controller.backend().starts, 1, "a stale retry never starts a tap");
        }
    }

    #[test]
    fn failed_suspend_preserves_running_capture_intent() {
        let mut controller =
            AudioCaptureController::new(Arc::new(TestConsumer), TestBackend::default());
        controller
            .set_scene_capturing(SceneHandle::new(1), true)
            .unwrap();
        controller.backend.fail_stop = true;

        let error = controller.set_demand(true, false).unwrap_err();
        assert_eq!(error, AudioCaptureError::Platform("stop failed".into()));
        controller
            .set_scene_capturing(SceneHandle::new(2), true)
            .unwrap();
        assert!(controller.is_capturing());
        controller.set_demand(true, false).unwrap();
        assert!(!controller.is_capturing());
        controller.set_demand(false, false).unwrap();
        assert!(controller.is_capturing());
    }
}
