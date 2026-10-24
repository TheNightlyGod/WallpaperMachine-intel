mod error;
mod first_frame_handoff;
#[cfg(test)]
pub(crate) mod lifecycle_test_support;
#[cfg(test)]
pub(crate) mod mounted_lifecycle;
#[cfg(test)]
mod mounted_state;
#[cfg(test)]
pub(crate) mod operation_contract_test_support;
#[cfg(test)]
mod operation_contract_tests;
#[cfg(test)]
mod small_library_contract_tests;
mod types;

use std::{
    pin::Pin,
    sync::{Arc, Condvar, Mutex, MutexGuard},
    time::Duration,
};

pub use error::{BridgeError, BridgeErrorKind};
use first_frame_handoff::FirstFrameHandoff;
pub(crate) use first_frame_handoff::{FirstFrameDelivery, FirstFrameTarget};
use futures_util::Future;
pub use types::{
    BridgeAppSnapshot, BridgeAudioSpectrum, BridgeComboOption, BridgeDirectoryMode,
    BridgeDisplayConfigRow, BridgeDisplayMode, BridgeDisplayMutationBundle,
    BridgeDisplaySettingsRow, BridgeFileFilter, BridgeFraming, BridgeLibraryScanStatus,
    BridgeLibrarySnapshot,
    BridgeLockScreenScene, BridgeLogLevel, BridgeLogStatus, BridgeMonitorInfoRow, BridgeWallpaperPreview,
    BridgeNativeVideoWallpaper, BridgeMediaSnapshot,
    BridgeMonitorInformationSnapshot, BridgePlaybackState, BridgeBatteryMode, BridgePropertyDescriptor,
    BridgePropertyEdit, BridgePropertyKind, BridgePropertyValue, BridgeQualityThrottleCause,
    BridgeRendererCountersReport,
    BridgeRendererSurfaceCounters, BridgeScalingMode, BridgeSceneBackendReport,
    BridgeSceneUpdateModeReport, BridgeSettingsSnapshot, BridgeUserShortcut,
    BridgeSliderMetadata, BridgeSnapshotBundle, BridgeStorageStatus, BridgeSurfaceCheck,
    BridgeVideoBackendReport, BridgeWallpaperEntry,
    BridgeWallpaperKind, BridgeWallpaperMutationBundle, BridgeWallpaperOptionsSnapshot,
    BridgeSceneWindow, BridgeWebWallpaper,
};

impl From<crate::config::BatteryModeCfg> for BridgeBatteryMode {
    fn from(mode: crate::config::BatteryModeCfg) -> Self {
        match mode {
            crate::config::BatteryModeCfg::KeepRunning => Self::KeepRunning,
            crate::config::BatteryModeCfg::ReducedQuality => Self::ReducedQuality,
            crate::config::BatteryModeCfg::Pause => Self::Pause,
        }
    }
}

impl From<BridgeBatteryMode> for crate::config::BatteryModeCfg {
    fn from(mode: BridgeBatteryMode) -> Self {
        match mode {
            BridgeBatteryMode::KeepRunning => Self::KeepRunning,
            BridgeBatteryMode::ReducedQuality => Self::ReducedQuality,
            BridgeBatteryMode::Pause => Self::Pause,
        }
    }
}
use wallpaper_core::{
    DisplaySelector, FirstFrameCallback, WallpaperAssignment, WallpaperEngine,
    media::audio::AudioVolume,
    project::{ScalingMode, SceneHandle, SceneResult},
};

#[cfg(test)]
use crate::actor::messages::{
    InitialFrameReady, InjectDisplayForTest, InjectSceneProjectForTest, InjectSceneWallpaperConfigForTest,
    InjectWallpaperForTest, ReplaceLibraryForTest, ReplaceWallpaperConfigForTest, SetPowerSource,
};
#[cfg(test)]
use crate::config::WallpaperConfig;
#[cfg(test)]
use crate::engine::FakeEngineFacade;
use crate::{
    actor::{
        BridgeActorHandle,
        messages::{
            ApplyWallpaperOptions, Bootstrap, CancelWallpaperOptions, ClearShaderCache,
            EditProperty, EjectWallpaperFromDisplay, GetAllSnapshots, GetAppSnapshot,
            GetLibrarySnapshot, GetLockScreenScenes, GetWallpaperPreview, GetMonitorInformationSnapshot,
            GetSettingsSnapshot, GetWallpaperOptionsSnapshot, GetWebWallpapers,
            GetNativeVideoWallpapers, PollMousePosition, RendererCounters,
            RefreshDisplays, RefreshLibrary, ReleaseHeldWallpaper, RestoreAllPropertyDefaults,
            RestorePropertyDefault,
            SelectWallpaper,
            SetAudioResponseEnabled, SetDisplayConfigEnabled, SetDisplayEnabled, SetDisplayMode,
            PreviewDisplayPosition, PreviewWallpaperProperties, SetDisplayPosition,
            SetDisplayParkedWallpapers, SetDisplayPresentationSuspended,
            SetFilter, SetGlobalPlayback, SetLaunchAtLogin, SetMirrorMuted, SetMirrorScalingFactor,
            SetMirrorScalingMode, SetMirrorTarget, SetMirrorTargetFps, SetMirrorVolume, SetMuted,
            SetAudioSuppressed, SetBatteryMode, SetBatteryQualityProfile,
            SetFrameRateCap, SetLabelLanguages, SetMediaIntegrationEnabled,
            SetPresentationUnloaded, SetPresentationSuspended, SetPropertyPath,
            SetQualityThrottle, SetRenderScale,
            SetVerboseLogging,
            SetRendererCountersEnabled, SetScalingFactor, SetScalingMode,
            SetSceneOnDemandEnabled, SetSceneOptimizationEnabled,
            SetSceneResolution, SetSceneVideoPlaneSamplingEnabled,
            SetTargetFps, SetVolume,
            SetWebAudioSubscribed, Shutdown,
        },
        state::BridgeActorState,
    },
    config::{ConfigStore, SceneResolutionCfg},
    engine::{EngineFacade, LoadJournal, RealEngineFacade},
    media::SystemMediaStore,
    paths::BridgePaths,
    power::PowerWatcher,
};

/// Validates an imported configuration before any restore publication; no engine is initialized.
#[uniffi::export]
pub fn validate_backup_renderer_configuration(
    app_config: Option<String>,
    wallpaper_configs: std::collections::HashMap<String, String>,
) -> Result<(), BridgeError> {
    if let Some(raw) = app_config {
        ConfigStore::validate_app_config_text(&raw)?;
    }
    for (name, raw) in wallpaper_configs {
        ConfigStore::validate_wallpaper_config_text(&raw).map_err(|error| BridgeError::Error {
            kind: BridgeErrorKind::Config,
            message: format!("{name}: {error}"),
        })?;
    }
    Ok(())
}

pub(crate) fn bridge_log_status(status: crate::logging::LogStatus) -> BridgeLogStatus {
    BridgeLogStatus {
        logs_root: status.logs_root.to_string_lossy().into_owned(),
        active_session: status.active_session,
        active_file: status.active_file.to_string_lossy().into_owned(),
        active_file_size_bytes: status.active_file_size_bytes,
    }
}

pub struct BridgeBuilder<E: crate::engine::EngineFacade> {
    engine: E,
    state: Option<crate::actor::state::BridgeActorState>,
    config_store: Option<crate::config::ConfigStore>,
    #[cfg(test)]
    journal_for_tests: Option<crate::engine::LoadJournal>,
    launch_at_login: crate::login::LaunchAtLoginController,
    paths: crate::paths::BridgePaths,
    mouse_polling_enabled: bool,
    power_watching_enabled: bool,
    startup_power_source: Option<crate::power::PowerSource>,
    wake_check_grace: std::time::Duration,
    power_reader: std::sync::Arc<
        dyn Fn() -> crate::power::PowerSource + Send + Sync + 'static,
    >,
}

impl<E: crate::engine::EngineFacade> BridgeBuilder<E> {
    pub fn new(engine: E) -> Self {
        Self {
            engine,
            state: None,
            config_store: None,
            #[cfg(test)]
            journal_for_tests: None,
            launch_at_login: crate::login::LaunchAtLoginController::default(),
            paths: crate::paths::BridgePaths::new(),
            mouse_polling_enabled: true,
            power_watching_enabled: !cfg!(test),
            startup_power_source: None,
            wake_check_grace: crate::engine::revalidate::GRACE,
            power_reader: std::sync::Arc::new(crate::power::SystemPowerSource::current),
        }
    }

    pub fn with_config_store(mut self, store: crate::config::ConfigStore) -> Self {
        self.config_store = Some(store);
        self
    }

    pub fn with_paths(mut self, paths: crate::paths::BridgePaths) -> Self {
        self.paths = paths;
        self
    }

    #[cfg(test)]
    pub fn with_state(mut self, state: crate::actor::state::BridgeActorState) -> Self {
        self.state = Some(state);
        self
    }

    #[cfg(test)]
    pub fn with_launch_at_login(
        mut self,
        controller: crate::login::LaunchAtLoginController,
    ) -> Self {
        self.launch_at_login = controller;
        self
    }

    #[cfg(test)]
    pub fn with_mouse_polling_enabled(mut self, enabled: bool) -> Self {
        self.mouse_polling_enabled = enabled;
        self
    }

    #[cfg(test)]
    pub fn with_power_watching_enabled(mut self, enabled: bool) -> Self {
        self.power_watching_enabled = enabled;
        self
    }

    #[cfg(test)]
    pub fn with_startup_power_source(mut self, source: crate::power::PowerSource) -> Self {
        self.startup_power_source = Some(source);
        self
    }

    #[cfg(test)]
    pub fn with_wake_check_grace(mut self, grace: std::time::Duration) -> Self {
        self.wake_check_grace = grace;
        self
    }

    #[cfg(test)]
    pub fn with_power_reader(
        mut self,
        reader: std::sync::Arc<
            dyn Fn() -> crate::power::PowerSource + Send + Sync + 'static,
        >,
    ) -> Self {
        self.power_reader = reader;
        self
    }

    pub fn build(self) -> Result<WallpaperBridge, BridgeError> {
        use crate::engine::EngineFacade;

        let Self {
            engine,
            state,
            config_store,
            #[cfg(test)]
            journal_for_tests,
            launch_at_login,
            paths,
            mouse_polling_enabled,
            power_watching_enabled,
            startup_power_source,
            wake_check_grace,
            power_reader,
        } = self;

        // The initial sample is independent of watcher enablement and its reader.
        #[cfg(not(test))]
        let startup_power_source = Some(
            startup_power_source.unwrap_or_else(crate::power::SystemPowerSource::current),
        );

        // Loading is unconditional when a store was supplied, even with explicit state.
        let loaded_config = match config_store.as_ref() {
            Some(store) => Some(store.load()?.config),
            None => None,
        };
        let mut state = match state {
            Some(state) => state,
            None => match loaded_config {
                Some(config) => crate::actor::state::BridgeActorState::from_app_config(config),
                None => crate::actor::state::BridgeActorState::default(),
            },
        };
        if let Some(source) = startup_power_source {
            state.apply_startup_power_source(source);
            log::info!("Startup power source: {:?}", source);
        }

        let config = &state.app_config;
        crate::logging::ApplicationLogger::set_verbose(config.diagnostics.verbose_logging);
        log::info!("Requested render scale: {}", config.quality.render_scale);
        log::info!("Requested battery mode: {:?}", config.power.on_battery);
        log::info!(
            "Requested battery profile: target FPS {}, render scale {}",
            config.quality.battery.target_fps,
            config.quality.battery.render_scale,
        );
        match config.quality.frame_rate_cap {
            Some(cap) => log::info!("Requested frame-rate cap: {}", cap),
            None => log::info!("Requested frame-rate cap: no cap"),
        }
        log::info!(
            "Requested scene optimization: {}",
            config.quality.scene_optimization_enabled,
        );
        log::info!(
            "Requested on-demand rendering: {}",
            config.quality.scene_on_demand_enabled,
        );
        log::info!(
            "Requested scene resolution: {:?}",
            config.quality.scene_resolution,
        );
        log::info!(
            "Requested video-plane sampling: {}",
            config.experimental.scene_video_plane_sampling,
        );

        let engine = ArcEngineFacade::new(engine);
        let pointer_control = std::sync::Arc::new(MousePollingControl::new());
        let consumer_control = std::sync::Arc::downgrade(&pointer_control);
        engine.set_pointer_consumer_callback(Some(std::sync::Arc::new(move |has_consumers| {
            if let Some(control) = consumer_control.upgrade() {
                control.set_has_consumers(has_consumers);
            }
        })));
        let activity_control = std::sync::Arc::downgrade(&pointer_control);
        engine.set_pointer_activity_callback(Some(std::sync::Arc::new(move |activity| {
            if let Some(control) = activity_control.upgrade() {
                control.record_activity(activity);
            }
        })));

        #[cfg(test)]
        let journal = journal_for_tests.unwrap_or_else(|| crate::engine::LoadJournal::open(
            config_store.as_ref().map(|store| store.root()),
            &crate::engine::build_stamp(),
        ));
        #[cfg(not(test))]
        let journal = crate::engine::LoadJournal::open(
            config_store.as_ref().map(|store| store.root()),
            &crate::engine::build_stamp(),
        );
        let actor = crate::actor::BridgeActorHandle::spawn(
            state,
            engine.clone(),
            config_store.clone(),
            launch_at_login,
            paths,
            pointer_control.clone(),
            journal.clone(),
        )?;
        let (runtime, target) = actor.first_frame_handoff_inputs()?;
        let handoff = FirstFrameHandoff::start(&runtime, target);
        engine.set_first_frame_callback(handoff.callback());
        engine.set_audio_requirement_callback(actor.audio_requirement_relay());

        let mouse_poller = if mouse_polling_enabled {
            Some(MousePoller::spawn(
                actor.clone(),
                pointer_control,
                engine.clone(),
            ))
        } else {
            None
        };
        let power_watcher = if power_watching_enabled {
            Some(crate::power::PowerWatcher::spawn(actor.clone(), move || {
                power_reader()
            }))
        } else {
            None
        };

        let (shortcut_callback, shortcuts) = builder_shortcut_channel();
        engine.set_user_shortcut_callback(Some(shortcut_callback));

        Ok(WallpaperBridge {
            first_frame_handoff: handoff,
            actor,
            mouse_poller,
            power_watcher,
            system_media: SystemMediaStore::default(),
            system_media_submission: tokio::sync::Mutex::new(()),
            engine,
            _config_store: config_store,
            load_journal: journal,
            user_shortcuts: tokio::sync::Mutex::new(shortcuts),
            wake_check_turn: Arc::new(tokio::sync::Mutex::new(())),
            wake_check_grace,
        })
    }
}

// Keep the actual admission callback independently exercisable without creating an actor.
fn builder_shortcut_channel() -> (
    wallpaper_core::UserShortcutObserverCallback,
    tokio::sync::mpsc::Receiver<BridgeUserShortcut>,
) {
    let (sender, receiver) = tokio::sync::mpsc::channel(8);
    let callback: wallpaper_core::UserShortcutObserverCallback =
        std::sync::Arc::new(move |scene, property, value| {
            let event = BridgeUserShortcut {
                scene_handle: scene.raw(),
                property,
                value,
            };
            if let Err(error) = sender.try_send(event) {
                log::warn!("Dropping user shortcut after admission failure: {}", error);
            }
        });
    (callback, receiver)
}

#[cfg(test)]
mod api_assembly_tests {
    use super::*;

    fn callback_batch_finishes(action: impl FnOnce() + Send + 'static) {
        let (finished, completion) = std::sync::mpsc::sync_channel(1);
        let worker = std::thread::spawn(move || {
            action();
            let _ = finished.send(());
        });
        completion
            .recv_timeout(std::time::Duration::from_secs(5))
            .expect("shortcut callback batch did not finish");
        worker.join().expect("shortcut callback batch panicked");
    }

    #[test]
    fn shortcut_callback_preserves_handle_extremes_and_owned_strings() {
        let (callback, mut receiver) = builder_shortcut_channel();
        for (handle, property, value) in [
            (0, String::new(), "\0\n\t".to_owned()),
            (u64::MAX, "任意.property\0".to_owned(), " {\"raw\": true} ".to_owned()),
        ] {
            let expected = BridgeUserShortcut {
                scene_handle: handle,
                property: property.clone(),
                value: value.clone(),
            };
            let callback = callback.clone();
            callback_batch_finishes(move || {
                callback(wallpaper_core::project::SceneHandle::new(handle), property, value);
            });
            assert_eq!(receiver.try_recv().unwrap(), expected);
        }
    }

    #[test]
    fn shortcut_capacity_is_eight_and_full_admission_preserves_fifo() {
        let (callback, mut receiver) = builder_shortcut_channel();
        let producer = callback.clone();
        callback_batch_finishes(move || {
            for handle in 0..9 {
                producer(
                    wallpaper_core::project::SceneHandle::new(handle),
                    format!("property-{handle}"),
                    format!("value-{handle}"),
                );
            }
        });
        for handle in 0..8 {
            assert_eq!(
                receiver.try_recv().unwrap(),
                BridgeUserShortcut {
                    scene_handle: handle,
                    property: format!("property-{handle}"),
                    value: format!("value-{handle}"),
                },
            );
        }
        assert_eq!(
            receiver.try_recv().unwrap_err(),
            tokio::sync::mpsc::error::TryRecvError::Empty,
        );
        callback_batch_finishes(move || {
            callback(
                wallpaper_core::project::SceneHandle::new(9),
                "after-drain".to_owned(),
                "still-live".to_owned(),
            );
        });
        assert_eq!(receiver.try_recv().unwrap().scene_handle, 9);
    }
}

struct MousePoller {
    control: Arc<MousePollingControl>,
    worker: Option<std::thread::JoinHandle<()>>,
}

struct MousePollingState {
    policy_enabled: bool,
    has_consumers: bool,
    /// The event monitors can miss motion, so the poller checks the cursor.
    monitor_gap: bool,
    stopped: bool,
}

impl MousePollingState {
    fn eligible(&self) -> bool {
        self.policy_enabled && self.has_consumers && !self.stopped
    }
}

/// Why the poller woke.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct MouseWake {
    /// Input arrived or the last sample was invalidated: sample regardless.
    pub(crate) input: bool,
    /// The monitors have a gap: compare a cursor probe before sampling.
    pub(crate) monitor_gap: bool,
}

/// Gates the pointer poller. Sampling is armed by input rather than a timer:
/// the poller sleeps until a consumer is eligible and something marked the
/// pointer dirty (an OS event, a new or resumed consumer, a policy re-enable,
/// or a delivery reset in the engine).
pub(crate) struct MousePollingControl {
    state: Mutex<MousePollingState>,
    changed: Condvar,
    /// Set from the AppKit main thread on every monitored event, so it lives
    /// outside the mutex: only the false -> true edge takes the lock.
    dirty: std::sync::atomic::AtomicBool,
}

impl MousePollingControl {
    pub(crate) fn new() -> Self {
        Self {
            state: Mutex::new(MousePollingState {
                policy_enabled: false,
                has_consumers: false,
                monitor_gap: false,
                stopped: false,
            }),
            changed: Condvar::new(),
            dirty: std::sync::atomic::AtomicBool::new(false),
        }
    }

    fn recover_poison<'a>(
        &self,
        mut state: MutexGuard<'a, MousePollingState>,
    ) -> MutexGuard<'a, MousePollingState> {
        if !state.stopped {
            log::error!("mouse polling control poisoned; stopping worker");
        }
        state.stopped = true;
        state.policy_enabled = false;
        state.has_consumers = false;
        self.changed.notify_all();
        state
    }

    fn lock(&self) -> MutexGuard<'_, MousePollingState> {
        self.state
            .lock()
            .unwrap_or_else(|error| self.recover_poison(error.into_inner()))
    }

    /// A re-enabled policy owes the consumers their current pointer state.
    pub(crate) fn set_policy_enabled(&self, enabled: bool) {
        let mut state = self.lock();
        if state.stopped {
            return;
        }
        let was_eligible = state.eligible();
        if enabled && !state.policy_enabled {
            self.dirty.store(true, std::sync::atomic::Ordering::Release);
        }
        state.policy_enabled = enabled;
        if state.eligible() != was_eligible {
            self.changed.notify_all();
        }
    }

    /// A consumer that appears (new, or resumed) is sampled at once, so it gets
    /// the current position and button baseline without waiting for input.
    pub(crate) fn set_has_consumers(&self, has_consumers: bool) {
        let mut state = self.lock();
        if state.stopped {
            return;
        }
        let was_eligible = state.eligible();
        if has_consumers && !state.has_consumers {
            self.dirty.store(true, std::sync::atomic::Ordering::Release);
        }
        state.has_consumers = has_consumers;
        if state.eligible() != was_eligible {
            self.changed.notify_all();
        }
    }

    pub(crate) fn record_activity(&self, activity: wallpaper_core::PointerActivity) {
        match activity {
            wallpaper_core::PointerActivity::Input => self.mark_dirty(),
            wallpaper_core::PointerActivity::MonitorGap(gap) => self.set_monitor_gap(gap),
        }
    }

    /// Runs on the AppKit main thread for every monitored event: no allocation,
    /// and the lock is taken only on the clean -> dirty edge, so a burst of
    /// motion between two samples costs one lock and one wakeup.
    fn mark_dirty(&self) {
        if !self.dirty.swap(true, std::sync::atomic::Ordering::AcqRel) {
            // Taking the lock orders this with a waiter between its dirty check
            // and its wait, so the notification cannot be lost.
            let _state = self.lock();
            self.changed.notify_all();
        }
    }

    fn set_monitor_gap(&self, gap: bool) {
        let mut state = self.lock();
        if state.monitor_gap != gap {
            state.monitor_gap = gap;
            self.changed.notify_all();
        }
    }

    pub(crate) fn is_enabled(&self) -> bool {
        self.lock().eligible()
    }

    pub(crate) fn stop(&self) {
        self.lock().stopped = true;
        self.changed.notify_all();
    }

    /// Waits until a consumer is eligible and either the pointer is dirty or
    /// the monitors have a gap. Clears dirty when it reports input. `None`
    /// once stopped.
    pub(crate) fn wait_for_sample(&self) -> Option<MouseWake> {
        let mut state = self.lock();
        loop {
            if state.stopped {
                return None;
            }
            if state.eligible() {
                let input = self.dirty.swap(false, std::sync::atomic::Ordering::AcqRel);
                if input || state.monitor_gap {
                    return Some(MouseWake { input, monitor_gap: state.monitor_gap });
                }
            }
            state = self
                .changed
                .wait(state)
                .unwrap_or_else(|error| self.recover_poison(error.into_inner()));
        }
    }

    /// The minimum spacing between samples; returns early when the poller
    /// stops being eligible.
    pub(crate) fn wait_interval(&self, interval: std::time::Duration) -> bool {
        let deadline = std::time::Instant::now() + interval;
        let mut state = self.lock();
        while state.eligible() {
            let remaining = deadline.saturating_duration_since(std::time::Instant::now());
            if remaining.is_zero() {
                break;
            }
            state = match self.changed.wait_timeout(state, remaining) {
                Ok((state, _)) => state,
                Err(error) => self.recover_poison(error.into_inner().0),
            };
        }
        !state.stopped
    }
}

impl MousePoller {
    /// Minimum spacing between samples. Input that arrives inside it is
    /// coalesced into one sample at its end; input after a quiet period is
    /// sampled at once.
    const INTERVAL: std::time::Duration = std::time::Duration::from_millis(16);

    #[allow(clippy::single_call_fn)]
    fn spawn(
        actor: BridgeActorHandle<ArcEngineFacade>,
        control: Arc<MousePollingControl>,
        engine: ArcEngineFacade,
    ) -> Self {
        let worker_control = Arc::clone(&control);
        let worker = std::thread::Builder::new()
            .name("wallpaper-bridge-mouse-poller".to_string())
            .spawn(move || {
                let mut last_probe = None;
                while let Some(wake) = worker_control.wait_for_sample() {
                    // Inside a monitor gap, check the cursor on this thread and
                    // skip both actor hops and the main-thread read when
                    // nothing changed. Pending edges and delivery resets
                    // arrive as input, so they always sample.
                    let probe = wake.monitor_gap.then(|| engine.probe_pointer());
                    let moved = probe != last_probe;
                    last_probe = probe;
                    if wake.input || moved {
                        let poll_result: Result<(), BridgeError> =
                            actor.blocking_ask(PollMousePosition);
                        if let Err(error) = poll_result {
                            log::debug!("mouse poll skipped: {error}");
                        }
                    }
                    if !worker_control.wait_interval(Self::INTERVAL) {
                        break;
                    }
                }
            })
            .ok();

        Self { control, worker }
    }
}

impl Drop for MousePoller {
    fn drop(&mut self) {
        self.control.stop();
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}

#[derive(uniffi::Object)]
pub struct WallpaperBridge {
    first_frame_handoff: FirstFrameHandoff,
    actor: BridgeActorHandle<ArcEngineFacade>,
    #[allow(dead_code)]
    mouse_poller: Option<MousePoller>,
    power_watcher: Option<PowerWatcher>,
    /// Last known system media state, held for replay into pages that load
    /// after the fact. Process-wide, like the system player it describes, so
    /// it is deliberately not actor state.
    system_media: SystemMediaStore,
    /// Orders acceptance and live publication as one submission operation.
    system_media_submission: tokio::sync::Mutex<()>,
    /// The engine the actor drives, kept here so the process-wide audio
    /// analysis can be read without an actor round trip on every poll.
    engine: ArcEngineFacade,
    _config_store: Option<ConfigStore>,
    /// The actor's load journal, so a quit can close it without the actor: the
    /// actor may be inside a startup load that lasts longer than the quit does.
    load_journal: LoadJournal,
    /// Requests waiting for `next_user_shortcut`. Bounded, and outside the
    /// actor: awaiting one inside a message handler would stall the mailbox for
    /// every other request while nobody is pressing anything.
    user_shortcuts: tokio::sync::Mutex<tokio::sync::mpsc::Receiver<BridgeUserShortcut>>,
    /// One check after a wake at a time. Two overlapping checks would each find
    /// the same stalled scene and spend two rungs of its recovery ladder on one
    /// fault.
    wake_check_turn: Arc<tokio::sync::Mutex<()>>,
    wake_check_grace: Duration,
}

impl Drop for WallpaperBridge {
    fn drop(&mut self) {
        // Cancel before actor/runtime teardown without touching the shared callback slot.
        self.first_frame_handoff.close();
    }
}

/// What a forwarded engine call returns: the wrapped engine's own boxed
/// future, the same type as `EngineFuture` of the facade trait.
type ForwardedUnit = Pin<Box<dyn Future<Output = Result<(), wallpaper_core::EngineError>> + Send>>;
type ForwardedHandle =
    Pin<Box<dyn Future<Output = Result<Option<SceneHandle>, wallpaper_core::EngineError>> + Send>>;

#[derive(Clone)]
struct ArcEngineFacade(Arc<dyn EngineFacade>);

impl ArcEngineFacade {
    #[allow(clippy::single_call_fn)]
    fn new<E: EngineFacade>(engine: E) -> Self {
        Self(Arc::new(engine))
    }
}

impl EngineFacade for ArcEngineFacade {
    fn update_media(&self, handle: wallpaper_core::project::SceneHandle, enabled: bool,
        state: wallpaper_core::media::MediaPollResult) -> futures_util::future::BoxFuture<'static, Result<(), wallpaper_core::EngineError>> {
        self.0.update_media(handle, enabled, state)
    }
    fn reconcile_scenes(
        &self,
        scenes: Vec<wallpaper_core::project::SceneDesc>,
    ) -> Pin<Box<dyn Future<Output = Result<Vec<SceneResult>, wallpaper_core::EngineError>> + Send>>
    {
        self.0.reconcile_scenes(scenes)
    }

    fn refresh_displays(
        &self,
    ) -> Pin<Box<dyn Future<Output = Result<(), wallpaper_core::EngineError>> + Send>> {
        self.0.refresh_displays()
    }

    fn display_snapshot(&self) -> Vec<wallpaper_core::DisplaySnapshotEntry> {
        self.0.display_snapshot()
    }

    fn scene_windows(&self) -> Vec<wallpaper_core::SceneWindowEntry> {
        self.0.scene_windows()
    }

    fn set_parked_scenes(
        &self,
        display_id: u32,
        scene_paths: Vec<String>,
    ) -> Pin<Box<dyn Future<Output = Result<(), wallpaper_core::EngineError>> + Send>> {
        self.0.set_parked_scenes(display_id, scene_paths)
    }

    fn close_all_scenes(
        &self,
    ) -> Pin<Box<dyn Future<Output = Result<(), wallpaper_core::EngineError>> + Send>> {
        self.0.close_all_scenes()
    }

    fn set_all_paused(
        &self,
        paused: bool,
        suspended_displays: Vec<u32>,
    ) -> Pin<Box<dyn Future<Output = Result<(), wallpaper_core::EngineError>> + Send>> {
        self.0.set_all_paused(paused, suspended_displays)
    }

    fn set_display_paused(
        &self,
        display_id: u32,
        paused: bool,
    ) -> Pin<Box<dyn Future<Output = Result<(), wallpaper_core::EngineError>> + Send>> {
        self.0.set_display_paused(display_id, paused)
    }

    fn set_renderer_counters_enabled(
        &self,
        enabled: bool,
    ) -> Result<(), wallpaper_core::EngineError> {
        self.0.set_renderer_counters_enabled(enabled)
    }

    fn set_scene_optimization_enabled(
        &self,
        enabled: bool,
    ) -> Result<(), wallpaper_core::EngineError> {
        self.0.set_scene_optimization_enabled(enabled)
    }

    fn set_scene_on_demand_enabled(
        &self,
        enabled: bool,
    ) -> Result<(), wallpaper_core::EngineError> {
        self.0.set_scene_on_demand_enabled(enabled)
    }

    fn set_scene_video_plane_sampling_enabled(
        &self,
        enabled: bool,
    ) -> Result<(), wallpaper_core::EngineError> {
        self.0.set_scene_video_plane_sampling_enabled(enabled)
    }

    fn set_scene_resolution(
        &self,
        resolution: wallpaper_core::SceneResolution,
    ) -> Result<(), wallpaper_core::EngineError> {
        self.0.set_scene_resolution(resolution)
    }

    fn scene_runtime_reports(&self) -> Vec<crate::engine::SceneRuntimeReport> {
        self.0.scene_runtime_reports()
    }

    fn recover_surface(
        &self,
        display_id: u32,
        reason: wallpaper_core::RecoveryReason,
    ) -> Pin<
        Box<
            dyn Future<Output = Result<wallpaper_core::RecoveryOutcome, wallpaper_core::EngineError>>
                + Send,
        >,
    > {
        self.0.recover_surface(display_id, reason)
    }

    fn current_audio_spectrum(
        &self,
    ) -> Result<Option<wallpaper_core::AudioSpectrum128>, wallpaper_core::EngineError> {
        self.0.current_audio_spectrum()
    }

    fn renderer_counters(
        &self,
    ) -> Pin<
        Box<
            dyn Future<
                    Output = Result<
                        (
                            Vec<wallpaper_core::render::RendererSurfaceCounters>,
                            Vec<u64>,
                        ),
                        wallpaper_core::EngineError,
                    >,
                > + Send,
        >,
    > {
        self.0.renderer_counters()
    }

    fn set_audio_volume(
        &self,
        handle: SceneHandle,
        volume: AudioVolume,
    ) -> Pin<Box<dyn Future<Output = Result<(), wallpaper_core::EngineError>> + Send>> {
        self.0.set_audio_volume(handle, volume)
    }

    fn set_audio_muted(
        &self,
        handle: SceneHandle,
        muted: bool,
    ) -> Pin<Box<dyn Future<Output = Result<(), wallpaper_core::EngineError>> + Send>> {
        self.0.set_audio_muted(handle, muted)
    }

    fn set_audio_response_enabled(
        &self,
        handle: SceneHandle,
        enabled: bool,
    ) -> Pin<Box<dyn Future<Output = Result<(), wallpaper_core::EngineError>> + Send>> {
        self.0.set_audio_response_enabled(handle, enabled)
    }

    fn set_media_integration_enabled(
        &self,
        handle: SceneHandle,
        enabled: bool,
    ) -> Pin<Box<dyn Future<Output = Result<(), wallpaper_core::EngineError>> + Send>> {
        self.0.set_media_integration_enabled(handle, enabled)
    }

    fn submit_media_event_json(
        &self,
        handle: SceneHandle,
        json: String,
    ) -> Pin<Box<dyn Future<Output = Result<(), wallpaper_core::EngineError>> + Send>> {
        self.0.submit_media_event_json(handle, json)
    }

    fn apply_system_media_artwork(
        &self,
        handle: SceneHandle,
        width: u32,
        height: u32,
        rgba: Vec<u8>,
    ) -> Pin<Box<dyn Future<Output = Result<(), wallpaper_core::EngineError>> + Send>> {
        self.0
            .apply_system_media_artwork(handle, width, height, rgba)
    }

    fn set_audio_capture_enabled(
        &self,
        handle: SceneHandle,
        enabled: bool,
    ) -> Pin<Box<dyn Future<Output = Result<(), wallpaper_core::EngineError>> + Send>> {
        self.0.set_audio_capture_enabled(handle, enabled)
    }

    fn set_audio_capture_demand(
        &self,
        demand: crate::engine::AudioCaptureDemand,
    ) -> Pin<Box<dyn Future<Output = Result<(), wallpaper_core::EngineError>> + Send>> {
        self.0.set_audio_capture_demand(demand)
    }

    fn set_scaling_mode(
        &self,
        handle: SceneHandle,
        mode: ScalingMode,
    ) -> Pin<Box<dyn Future<Output = Result<(), wallpaper_core::EngineError>> + Send>> {
        self.0.set_scaling_mode(handle, mode)
    }

    fn set_scaling_factor(
        &self,
        handle: SceneHandle,
        factor: f64,
    ) -> Pin<Box<dyn Future<Output = Result<(), wallpaper_core::EngineError>> + Send>> {
        self.0.set_scaling_factor(handle, factor)
    }

    fn set_framing(
        &self,
        handle: SceneHandle,
        framing: wallpaper_core::project::SceneFraming,
    ) -> Pin<Box<dyn Future<Output = Result<(), wallpaper_core::EngineError>> + Send>> {
        self.0.set_framing(handle, framing)
    }

    fn preview_framing(
        &self,
        handle: SceneHandle,
        framing: wallpaper_core::project::SceneFraming,
    ) -> Pin<Box<dyn Future<Output = Result<(), wallpaper_core::EngineError>> + Send>> {
        self.0.preview_framing(handle, framing)
    }

    fn preview_property_override(
        &self,
        handle: SceneHandle,
        scene_path: String,
        flat_json: String,
    ) -> Pin<Box<dyn Future<Output = Result<wallpaper_core::PropertyPreview, wallpaper_core::EngineError>> + Send>> {
        self.0.preview_property_override(handle, scene_path, flat_json)
    }

    fn set_fps(
        &self,
        handle: SceneHandle,
        fps: u32,
    ) -> Pin<Box<dyn Future<Output = Result<(), wallpaper_core::EngineError>> + Send>> {
        self.0.set_fps(handle, fps)
    }

    fn set_render_scale(
        &self,
        handle: SceneHandle,
        scale: f32,
    ) -> Pin<Box<dyn Future<Output = Result<(), wallpaper_core::EngineError>> + Send>> {
        self.0.set_render_scale(handle, scale)
    }

    fn poll_mouse_position(
        &self,
    ) -> Pin<Box<dyn Future<Output = Result<(), wallpaper_core::EngineError>> + Send>> {
        self.0.poll_mouse_position()
    }

    fn set_mouse_position(
        &self,
        handle: SceneHandle,
        x: f64,
        y: f64,
    ) -> Pin<Box<dyn Future<Output = Result<(), wallpaper_core::EngineError>> + Send>> {
        self.0.set_mouse_position(handle, x, y)
    }

    fn set_mouse_button(
        &self,
        handle: SceneHandle,
        button: u32,
        pressed: bool,
    ) -> Pin<Box<dyn Future<Output = Result<(), wallpaper_core::EngineError>> + Send>> {
        self.0.set_mouse_button(handle, button, pressed)
    }

    // The next three calls pass straight through: the wrapped engine's future
    // is returned as it is, with no extra await, mapping or logging.
    fn set_mouse_entered(&self, handle: SceneHandle, entered: bool) -> ForwardedUnit {
        self.0.set_mouse_entered(handle, entered)
    }

    fn create_window_for_display(&self, selector: DisplaySelector) -> ForwardedHandle {
        self.0.create_window_for_display(selector)
    }

    fn set_wallpaper_for_display(
        &self,
        selector: DisplaySelector,
        assignment: WallpaperAssignment,
    ) -> ForwardedHandle {
        self.0.set_wallpaper_for_display(selector, assignment)
    }

    fn set_first_frame_callback(&self, callback: FirstFrameCallback) {
        self.0.set_first_frame_callback(callback);
    }

    fn set_pointer_consumer_callback(
        &self,
        callback: Option<wallpaper_core::PointerConsumerCallback>,
    ) {
        self.0.set_pointer_consumer_callback(callback);
    }

    fn set_pointer_activity_callback(
        &self,
        callback: Option<wallpaper_core::PointerActivityCallback>,
    ) {
        self.0.set_pointer_activity_callback(callback);
    }

    fn probe_pointer(&self) -> wallpaper_core::PointerProbe {
        self.0.probe_pointer()
    }

    fn set_user_shortcut_callback(
        &self,
        callback: Option<wallpaper_core::UserShortcutObserverCallback>,
    ) {
        self.0.set_user_shortcut_callback(callback);
    }

    fn scene_requires_audio(&self, handle: SceneHandle) -> bool {
        self.0.scene_requires_audio(handle)
    }

    fn set_audio_requirement_callback(
        &self,
        callback: Option<wallpaper_core::AudioRequirementCallback>,
    ) {
        self.0.set_audio_requirement_callback(callback);
    }
}

#[uniffi::export]
impl WallpaperBridge {
    #[uniffi::constructor]
    /// # Errors
    ///
    /// Returns an error when the native engine cannot start or persisted
    /// configuration cannot load.
    pub fn new() -> Result<Self, BridgeError> {
        let paths = BridgePaths::new();
        crate::logging::ApplicationLogger::install(&paths)?;
        let engine =
            WallpaperEngine::new().map_err(|error| BridgeError::engine(error.to_string()))?;

        BridgeBuilder::new(RealEngineFacade::new(engine))
            .with_config_store(ConfigStore::open(ConfigStore::default_root()))
            .with_paths(paths)
            .build()
    }

    /// # Errors
    ///
    /// Returns an error when the bridge actor cannot produce an app snapshot.
    pub async fn app_snapshot(&self) -> Result<BridgeAppSnapshot, BridgeError> {
        self.actor.ask(GetAppSnapshot).await
    }

    /// # Errors
    ///
    /// Returns an error when the bridge actor cannot produce a library
    /// snapshot.
    pub async fn library_snapshot(&self) -> Result<BridgeLibrarySnapshot, BridgeError> {
        self.actor.ask(GetLibrarySnapshot).await
    }

    /// Returns committed wallpaper inputs for native lock-screen and screen-saver
    /// displays, including web projects, native-preferred videos and mirrors.
    /// Drafts and transient desktop suspension/unload do not affect these inputs.
    ///
    /// # Errors
    ///
    /// Returns an error when scene resolution or renderer-input conversion fails.
    pub async fn lock_screen_scenes(&self) -> Result<Vec<BridgeLockScreenScene>, BridgeError> {
        self.actor.ask(GetLockScreenScenes).await
    }

    /// Exports current draft inputs for an isolated preview, without selecting, applying,
    /// persisting or opening any wallpaper. Preview playback is owned by the host.
    ///
    /// `pending` holds values the host is showing without having saved them, a
    /// slider still being dragged: each is made to the draft's properties, in
    /// order, for this export alone, so the draft, the dirty state and the
    /// snapshots stay as they are. An entry is checked like
    /// [`WallpaperBridge::edit_property`] checks its value.
    ///
    /// # Errors
    /// Returns an error for a missing or unsupported project, invalid input paths, or a
    /// pending value the property does not accept. Nothing is exported then.
    pub async fn wallpaper_preview(
        &self, wallpaper_id: String, display_id: String, pending: Vec<BridgePropertyEdit>,
    ) -> Result<BridgeWallpaperPreview, BridgeError> {
        self.actor.ask(GetWallpaperPreview { wallpaper_id, display_id, pending }).await
    }

    /// Returns committed web wallpapers for the currently connected displays.
    /// The host renders these in web views; the scene engine never opens a
    /// window for them. Draft options do not affect these inputs.
    ///
    /// # Errors
    ///
    /// Returns an error when a web project has no entry file or its path
    /// cannot be resolved.
    pub async fn web_wallpapers(&self) -> Result<Vec<BridgeWebWallpaper>, BridgeError> {
        self.actor.ask(GetWebWallpapers).await
    }

    /// Completes the first host-rendered frame wait, or reports terminal load failure.
    /// Echo the descriptor's revision and, for native video, its admission key.
    /// Stale assignments are ignored and a user's explicit pause/resume wins.
    ///
    /// # Errors
    /// Returns an error if current assignments cannot be read or power policy fails.
    pub async fn report_host_wallpaper_startup(
        &self,
        display_id: u32,
        wallpaper_id: String,
        startup_revision: u64,
        native_admission_key: Option<u64>,
        ready: bool,
    ) -> Result<BridgeSnapshotBundle, BridgeError> {
        self.actor.ask(crate::actor::messages::ReportHostWallpaperStartup {
            display_id, wallpaper_id, startup_revision, native_admission_key, ready,
        }).await
    }

    /// # Errors
    ///
    /// Returns an error when the bridge actor cannot produce monitor
    /// information.
    pub async fn monitor_information_snapshot(
        &self,
    ) -> Result<BridgeMonitorInformationSnapshot, BridgeError> {
        self.actor.ask(GetMonitorInformationSnapshot).await
    }

    /// # Errors
    ///
    /// Returns an error when the bridge actor cannot produce settings.
    pub async fn settings_snapshot(&self) -> Result<BridgeSettingsSnapshot, BridgeError> {
        self.actor.ask(GetSettingsSnapshot).await
    }

    /// Writes one line from the host. `load` attributes it to a wallpaper load
    /// from [`Self::begin_host_load_log`]; `unix_millis` is when the host
    /// produced it, so lines it buffered before the bridge existed keep their
    /// time.
    ///
    /// # Errors
    ///
    /// Returns an error when GUI log emission cannot be accepted.
    #[allow(clippy::needless_pass_by_value)]
    pub fn emit_gui_log(
        &self,
        level: BridgeLogLevel,
        file: String,
        line: u32,
        message: String,
        load: Option<u64>,
        unix_millis: Option<i64>,
    ) -> Result<(), BridgeError> {
        let level = match level {
            BridgeLogLevel::Trace => log::Level::Trace,
            BridgeLogLevel::Debug => log::Level::Debug,
            BridgeLogLevel::Info => log::Level::Info,
            BridgeLogLevel::Warn => log::Level::Warn,
            BridgeLogLevel::Error => log::Level::Error,
        };
        crate::logging::ApplicationLogger::emit_gui_log(
            level,
            &file,
            line,
            &message,
            load,
            unix_millis,
        );
        Ok(())
    }

    /// Starts the log of a wallpaper load the host performs itself (web
    /// pages, native video): allocates its `load#N` and writes the header
    /// naming the project at `project_path` and the host's `detail`.
    #[allow(clippy::needless_pass_by_value)]
    pub fn begin_host_load_log(&self, kind: String, project_path: String, detail: String) -> u64 {
        wallpaper_core::log_context::begin_load(
            &kind,
            std::path::Path::new(&project_path),
            detail,
        )
    }

    /// Records debug-level lines too, from now on and after relaunch.
    ///
    /// # Errors
    ///
    /// Returns an error when the setting cannot be persisted.
    pub async fn set_verbose_logging(
        &self,
        enabled: bool,
    ) -> Result<BridgeSnapshotBundle, BridgeError> {
        self.actor.ask(SetVerboseLogging { enabled }).await
    }

    /// # Errors
    ///
    /// Returns an error when the logger has not been installed.
    pub fn log_folder_path(&self) -> Result<String, BridgeError> {
        crate::logging::ApplicationLogger::logs_root()
            .map(|path| path.to_string_lossy().into_owned())
            .ok_or_else(|| BridgeError::Error {
                kind: BridgeErrorKind::Io,
                message: "application logger is not installed".to_string(),
            })
    }

    /// # Errors
    ///
    /// Returns an error when a new log session cannot be created.
    pub fn clear_logs(&self) -> Result<BridgeLogStatus, BridgeError> {
        crate::logging::ApplicationLogger::clear().map(bridge_log_status)
    }

    /// # Errors
    ///
    /// Returns an error when the shader cache cannot be cleared or active
    /// scenes cannot be rebuilt.
    pub async fn clear_shader_cache(&self) -> Result<BridgeSettingsSnapshot, BridgeError> {
        self.actor.ask(ClearShaderCache).await
    }

    /// # Errors
    ///
    /// Returns an error when any snapshot in the bundle cannot be produced.
    pub async fn all_snapshots(&self) -> Result<BridgeSnapshotBundle, BridgeError> {
        self.actor.ask(GetAllSnapshots).await
    }

    /// # Errors
    ///
    /// Returns an error when the wallpaper id is unknown or its options cannot
    /// be read.
    pub async fn wallpaper_options_snapshot(
        &self,
        wallpaper_id: String,
    ) -> Result<BridgeWallpaperOptionsSnapshot, BridgeError> {
        self.actor
            .ask(GetWallpaperOptionsSnapshot { wallpaper_id })
            .await
    }

    /// # Errors
    ///
    /// Returns an error when the library cannot be scanned.
    pub async fn refresh_library(&self) -> Result<BridgeSnapshotBundle, BridgeError> {
        self.actor.ask(RefreshLibrary).await
    }

    /// # Errors
    ///
    /// Returns an error when display refresh, library refresh, config load, or
    /// reconciliation fails.
    pub async fn bootstrap(&self) -> Result<BridgeSnapshotBundle, BridgeError> {
        self.actor.ask(Bootstrap).await
    }

    /// # Errors
    ///
    /// Returns an error when display refresh fails.
    pub async fn refresh_displays(&self) -> Result<BridgeSnapshotBundle, BridgeError> {
        self.actor.ask(RefreshDisplays).await
    }

    /// Opens a wallpaper the load journal holds back after repeated crashes
    /// while it loaded, and lifts the hold. A wallpaper that is not held is
    /// left alone.
    ///
    /// # Errors
    ///
    /// Returns an error when the configuration cannot be reconciled; the
    /// wallpaper then stays held.
    pub async fn release_held_wallpaper(
        &self,
        wallpaper_id: String,
    ) -> Result<BridgeSnapshotBundle, BridgeError> {
        self.actor.ask(ReleaseHeldWallpaper { wallpaper_id }).await
    }

    /// # Errors
    ///
    /// Returns an error when host pointer state cannot be forwarded to active
    /// wallpaper scenes.
    pub async fn poll_mouse_position(&self) -> Result<(), BridgeError> {
        self.actor.ask(PollMousePosition).await
    }

    /// # Errors
    ///
    /// Returns an error when the wallpaper id is unknown or selection cannot be
    /// committed.
    pub async fn select_wallpaper(&self, id: String) -> Result<BridgeSnapshotBundle, BridgeError> {
        self.actor.ask(SelectWallpaper { id }).await
    }

    /// # Errors
    ///
    /// Returns an error when filter state cannot be persisted.
    pub async fn set_filter(
        &self,
        kind: BridgeWallpaperKind,
        enabled: bool,
    ) -> Result<BridgeSnapshotBundle, BridgeError> {
        self.actor.ask(SetFilter { kind, enabled }).await
    }

    /// # Errors
    ///
    /// Returns an error when the wallpaper id is unknown, the volume is
    /// invalid, or persistence fails.
    pub async fn set_volume(
        &self,
        wallpaper_id: String,
        volume: f32,
    ) -> Result<BridgeWallpaperMutationBundle, BridgeError> {
        self.actor
            .ask(SetVolume {
                wallpaper_id,
                volume,
            })
            .await
    }

    /// # Errors
    ///
    /// Returns an error when the wallpaper id is unknown or persistence fails.
    pub async fn set_muted(
        &self,
        wallpaper_id: String,
        muted: bool,
    ) -> Result<BridgeWallpaperMutationBundle, BridgeError> {
        self.actor
            .ask(SetMuted {
                wallpaper_id,
                muted,
            })
            .await
    }

    /// # Errors
    ///
    /// Returns an error when the wallpaper id is unknown or persistence fails.
    pub async fn set_audio_response_enabled(
        &self,
        wallpaper_id: String,
        enabled: bool,
    ) -> Result<BridgeWallpaperMutationBundle, BridgeError> {
        self.actor
            .ask(SetAudioResponseEnabled {
                wallpaper_id,
                enabled,
            })
            .await
    }

    /// # Errors
    ///
    /// Returns an error when the wallpaper or display id is unknown.
    pub async fn set_display_config_enabled(
        &self,
        wallpaper_id: String,
        display_id: String,
        enabled: bool,
    ) -> Result<BridgeWallpaperMutationBundle, BridgeError> {
        self.actor
            .ask(SetDisplayConfigEnabled {
                wallpaper_id,
                display_id,
                enabled,
            })
            .await
    }

    /// # Errors
    ///
    /// Returns an error when the wallpaper or display id is unknown, or
    /// persistence fails.
    pub async fn set_scaling_mode(
        &self,
        wallpaper_id: String,
        display_id: String,
        mode: BridgeScalingMode,
    ) -> Result<BridgeWallpaperMutationBundle, BridgeError> {
        self.actor
            .ask(SetScalingMode {
                wallpaper_id,
                display_id,
                mode,
            })
            .await
    }

    /// # Errors
    ///
    /// Returns an error when the wallpaper or display id is unknown, the
    /// scaling factor is invalid, or live engine update fails.
    pub async fn edit_scaling_factor(
        &self,
        wallpaper_id: String,
        display_id: String,
        factor: f64,
    ) -> Result<BridgeWallpaperMutationBundle, BridgeError> {
        self.actor
            .ask(SetScalingFactor {
                wallpaper_id,
                display_id,
                factor,
            })
            .await
    }

    /// Moves a wallpaper on one display: `pan_x` and `pan_y` are fractions from
    /// 0 (left, top) to 1 (right, bottom) of the room the display leaves around
    /// the wallpaper, and an axis passed as `None` keeps its saved value. The
    /// running scene follows without being rebuilt and the position is saved at
    /// once, like the scaling mode and unlike the scale factor, so it is not
    /// part of the draft that Apply and Cancel decide on. Repeating a position
    /// changes nothing.
    ///
    /// # Errors
    ///
    /// Returns an error when the wallpaper or display id is unknown, an axis is
    /// not a finite fraction between 0 and 1, persistence fails, or the live
    /// engine update fails. A failed engine update leaves the position saved,
    /// and the next time the scene is reconciled it is applied.
    pub async fn set_display_position(
        &self,
        wallpaper_id: String,
        display_id: String,
        pan_x: Option<f64>,
        pan_y: Option<f64>,
    ) -> Result<BridgeWallpaperMutationBundle, BridgeError> {
        self.actor
            .ask(SetDisplayPosition {
                wallpaper_id,
                display_id,
                pan_x,
                pan_y,
            })
            .await
    }

    /// Shows a wallpaper at a position on one display while a drag toward it
    /// is under way, and keeps nothing: the running scene follows, but the
    /// position is not saved, no snapshot changes and the lock screen and
    /// screen saver are not told, so a page can call it for every step of a
    /// drag. `pan_x` and `pan_y` are read as for `set_display_position`.
    /// The drag must end with `set_display_position` for the value it
    /// settled on, which saves it (and puts the scene back at the saved
    /// position when that is where the drag ended). A display that is gone or
    /// that no scene draws, such as one the native video player plays, has
    /// nothing to move and is not an error.
    ///
    /// # Errors
    ///
    /// Returns an error when the wallpaper id is unknown, an axis is not a
    /// finite fraction between 0 and 1, or the live engine update fails.
    pub async fn preview_display_position(
        &self,
        wallpaper_id: String,
        display_id: String,
        pan_x: Option<f64>,
        pan_y: Option<f64>,
    ) -> Result<(), BridgeError> {
        self.actor
            .ask(PreviewDisplayPosition {
                wallpaper_id,
                display_id,
                pan_x,
                pan_y,
            })
            .await
    }

    /// Shows a wallpaper's pending property edits on every scene that draws it,
    /// mirrors included, without applying them, or with `show` false puts the
    /// saved look back. The scenes follow the whole pending edit: what the
    /// panel's inspector holds, except a texture, a file or a folder, which
    /// stay at what is saved because a texture is read only while a scene loads
    /// and a file or folder is saved the moment it is picked. Nothing is saved,
    /// the draft stays as it is, no snapshot changes and the lock screen and
    /// screen saver are not told, so a page can call it after every edit.
    ///
    /// `pending` holds values the host is showing without having saved them, a
    /// slider or colour still being dragged. Each is made to the draft for this
    /// call alone, in order, as [`WallpaperBridge::edit_property`] would make
    /// it, so the scenes follow the drag; none is kept, and the next call
    /// shows the draft again unless it names them anew. Each is checked like
    /// an edit's value, and one the property does not accept refuses the call
    /// before any scene is told anything. A texture, a file or a folder in
    /// `pending` stays at what is saved, like one in the draft. With `show`
    /// false it has no effect on what the scenes are given.
    ///
    /// Asking for what the scenes already show, or for the saved look when they
    /// are showing it, sends the engine nothing. Cancelling the options puts
    /// the saved look back by itself, and applying them loads the scenes from
    /// the saved configuration. Anything else that loads a scene again, a
    /// display change or a wake for one, also shows the saved look, and the next
    /// call shows the edit again. A wallpaper that is a video or a web page, or
    /// that no display shows, has nothing to show and is not an error.
    ///
    /// # Errors
    ///
    /// Returns an error when the wallpaper id is unknown, a scene wallpaper's
    /// pending value is not one its property accepts, or the live engine
    /// update fails. A refused update leaves the call to be repeated.
    pub async fn preview_wallpaper_properties(
        &self,
        wallpaper_id: String,
        show: bool,
        pending: Vec<BridgePropertyEdit>,
    ) -> Result<(), BridgeError> {
        self.actor
            .ask(PreviewWallpaperProperties {
                wallpaper_id,
                show,
                pending,
            })
            .await
    }

    /// # Errors
    ///
    /// Returns an error when the wallpaper or display id is unknown, or
    /// persistence fails.
    pub async fn set_target_fps(
        &self,
        wallpaper_id: String,
        display_id: String,
        fps: u32,
    ) -> Result<BridgeWallpaperMutationBundle, BridgeError> {
        self.actor
            .ask(SetTargetFps {
                wallpaper_id,
                display_id,
                fps,
            })
            .await
    }

    /// # Errors
    ///
    /// Returns an error when the display id is unknown or the display update
    /// fails.
    pub async fn set_display_enabled(
        &self,
        display_id: String,
        enabled: bool,
    ) -> Result<BridgeDisplayMutationBundle, BridgeError> {
        self.actor
            .ask(SetDisplayEnabled {
                display_id,
                enabled,
            })
            .await
    }

    /// # Errors
    ///
    /// Returns an error when the display id is unknown or the mode update
    /// fails.
    pub async fn set_display_mode(
        &self,
        display_id: String,
        mode: BridgeDisplayMode,
    ) -> Result<BridgeDisplayMutationBundle, BridgeError> {
        self.actor.ask(SetDisplayMode { display_id, mode }).await
    }

    /// # Errors
    ///
    /// Returns an error when the display id, target display id, or mirror graph
    /// is invalid.
    pub async fn set_mirror_target(
        &self,
        display_id: String,
        target_display_id: String,
    ) -> Result<BridgeDisplayMutationBundle, BridgeError> {
        self.actor
            .ask(SetMirrorTarget {
                display_id,
                target_display_id,
            })
            .await
    }

    /// # Errors
    ///
    /// Returns an error when the display id is unknown, not in mirror mode, or
    /// the display update fails.
    pub async fn set_mirror_scaling_mode(
        &self,
        display_id: String,
        mode: BridgeScalingMode,
    ) -> Result<BridgeDisplayMutationBundle, BridgeError> {
        self.actor
            .ask(SetMirrorScalingMode { display_id, mode })
            .await
    }

    /// # Errors
    ///
    /// Returns an error when the display id is unknown, not in mirror mode, the
    /// factor is invalid, or the display update fails.
    pub async fn set_mirror_scaling_factor(
        &self,
        display_id: String,
        factor: f64,
    ) -> Result<BridgeDisplayMutationBundle, BridgeError> {
        self.actor
            .ask(SetMirrorScalingFactor { display_id, factor })
            .await
    }

    /// # Errors
    ///
    /// Returns an error when the display id is unknown, not in mirror mode, or
    /// the display update fails.
    pub async fn set_mirror_target_fps(
        &self,
        display_id: String,
        fps: u32,
    ) -> Result<BridgeDisplayMutationBundle, BridgeError> {
        self.actor.ask(SetMirrorTargetFps { display_id, fps }).await
    }

    /// # Errors
    ///
    /// Returns an error when the display id is unknown, not in mirror mode, the
    /// volume is invalid, or the display update fails.
    pub async fn set_mirror_volume(
        &self,
        display_id: String,
        volume: f32,
    ) -> Result<BridgeDisplayMutationBundle, BridgeError> {
        self.actor.ask(SetMirrorVolume { display_id, volume }).await
    }

    /// # Errors
    ///
    /// Returns an error when the display id is unknown, not in mirror mode, or
    /// the display update fails.
    pub async fn set_mirror_muted(
        &self,
        display_id: String,
        muted: bool,
    ) -> Result<BridgeDisplayMutationBundle, BridgeError> {
        self.actor.ask(SetMirrorMuted { display_id, muted }).await
    }

    /// # Errors
    ///
    /// Returns an error when launch at login is unavailable or
    /// `ServiceManagement` rejects the update.
    pub async fn set_launch_at_login(
        &self,
        enabled: bool,
    ) -> Result<BridgeDisplayMutationBundle, BridgeError> {
        self.actor.ask(SetLaunchAtLogin { enabled }).await
    }

    /// Chooses what wallpapers do on battery: keep running, reduced quality,
    /// or pause. Leaving pause resumes a pause this policy asked for. Leaving
    /// reduced quality restores the saved scale and rates immediately.
    ///
    /// # Errors
    ///
    /// Returns an error when the setting cannot be persisted or an immediate
    /// power-policy playback transition fails.
    pub async fn set_battery_mode(
        &self,
        mode: BridgeBatteryMode,
    ) -> Result<BridgeSnapshotBundle, BridgeError> {
        self.actor
            .ask(SetBatteryMode {
                mode: mode.into(),
            })
            .await
    }

    /// Sets the global frame-rate ceiling. `None` means no limit. A number is
    /// stored at least 1. Open scenes take it live; saved per-display rates
    /// are not rewritten.
    ///
    /// # Errors
    ///
    /// Returns an error when the cap cannot be saved or a running scene
    /// rejects the resulting rate.
    pub async fn set_frame_rate_cap(
        &self,
        cap: Option<u32>,
    ) -> Result<BridgeSnapshotBundle, BridgeError> {
        self.actor.ask(SetFrameRateCap { cap }).await
    }

    /// Asks for the reduced-quality profile for as long as any of `causes`
    /// holds, on top of the battery mode the user saved. The same frame-rate
    /// ceiling and render scale the battery profile uses apply live to every
    /// open scene, web page and native video, and the empty list hands the
    /// user's own values back. Not persisted: a new bridge starts without any
    /// cause, and the host asks again.
    ///
    /// It can only lower what runs. A scale or rate already below the profile
    /// stays where the user put it, and playback is untouched, so a pause the
    /// user asked for survives. Asking again with the same causes re-applies
    /// them, which is how a caller whose last request failed retries.
    ///
    /// # Errors
    ///
    /// Returns an error when a running scene rejects the resulting scale or
    /// rate. The request is kept, so asking again retries it.
    pub async fn set_quality_throttle(
        &self,
        causes: Vec<BridgeQualityThrottleCause>,
    ) -> Result<BridgeSnapshotBundle, BridgeError> {
        self.actor.ask(SetQualityThrottle { causes }).await
    }

    /// Closes every scene runtime so the host can free wallpaper memory,
    /// without changing assignments. Clearing it opens the configured scenes
    /// again, paused if playback is paused.
    ///
    /// # Errors
    ///
    /// Returns an error when the scene list cannot be reconciled. The previous
    /// unload state is restored and a repair is scheduled.
    pub async fn set_presentation_unloaded(
        &self,
        unloaded: bool,
    ) -> Result<BridgeSnapshotBundle, BridgeError> {
        self.actor
            .ask(SetPresentationUnloaded { unloaded })
            .await
    }

    /// Mutes or restores every open scene on top of its saved mute. Not
    /// persisted. A user unmute while this is set stays muted until it clears.
    ///
    /// # Errors
    ///
    /// Returns an error when a running scene rejects the mute.
    pub async fn set_audio_suppressed(
        &self,
        suppressed: bool,
    ) -> Result<BridgeSnapshotBundle, BridgeError> {
        self.actor.ask(SetAudioSuppressed { suppressed }).await
    }

    /// Names the languages a wallpaper's own translated labels are read in,
    /// most preferred first, as Wallpaper Engine locale codes such as `zh-chs`
    /// or `ja-jp`. English is added as the fallback. Not persisted: the host
    /// supplies it at start and again whenever its language changes, and the
    /// next options snapshot reflects it.
    ///
    /// # Errors
    ///
    /// Returns an error when the actor cannot take the request.
    pub async fn set_label_languages(&self, locales: Vec<String>) -> Result<(), BridgeError> {
        self.actor.ask(SetLabelLanguages { locales }).await
    }

    /// Suspends or resumes rendering and system-audio capture for every
    /// wallpaper without changing the user-visible playback state. Used for
    /// conditions where no wallpaper pixel can reach a display: screens asleep,
    /// session locked, or every wallpaper window fully occluded.
    ///
    /// # Errors
    ///
    /// Returns an error when the actor rejects the update or the engine fails
    /// to apply the pause.
    pub async fn set_presentation_suspended(&self, suspended: bool) -> Result<(), BridgeError> {
        self.actor.ask(SetPresentationSuspended { suspended }).await
    }

    /// Suspends or resumes rendering for one display without touching the
    /// others or the user-visible playback state. Used for conditions that are
    /// specific to a screen, such as a window fully covering that wallpaper:
    /// one display being hidden must not stop a display that is still visible.
    ///
    /// # Errors
    ///
    /// Returns an error when the display id is not a known display, or the
    /// engine fails to apply the pause.
    pub async fn set_display_presentation_suspended(
        &self,
        display_id: String,
        suspended: bool,
    ) -> Result<(), BridgeError> {
        self.actor
            .ask(SetDisplayPresentationSuspended {
                display_id,
                suspended,
            })
            .await
    }

    /// Sets which wallpapers the display `display_id` keeps loaded and paused
    /// when it moves on to another one, so that one runs on from where it
    /// stopped when it comes back instead of loading again. Only a scene that
    /// has drawn is kept; its window stays where the host put it. A kept scene
    /// whose wallpaper is no longer listed is closed now, and an empty list
    /// frees every one the display keeps. Runtime state, never saved.
    ///
    /// # Errors
    ///
    /// Returns an error when the display id is not a number or the engine
    /// fails to close a scene.
    pub async fn set_display_parked_wallpapers(
        &self,
        display_id: String,
        wallpaper_ids: Vec<String>,
    ) -> Result<(), BridgeError> {
        self.actor
            .ask(SetDisplayParkedWallpapers {
                display_id,
                wallpaper_ids,
            })
            .await
    }

    /// The window of every open scene wallpaper, live and parked, so the host
    /// can keep each one on the desktops that show its wallpaper. Web and
    /// video windows are the host's own and are not listed.
    ///
    /// Synchronous on purpose: it reads the engine's last published state,
    /// which no actor owns, and the host asks whenever windows may have moved.
    pub fn scene_windows(&self) -> Vec<BridgeSceneWindow> {
        self.engine
            .scene_windows()
            .into_iter()
            .filter_map(|window| {
                let wallpaper_id = std::path::Path::new(&window.desc.scene_path)
                    .parent()?
                    .file_name()?
                    .to_string_lossy()
                    .into_owned();
                Some(BridgeSceneWindow {
                    display_id: window.display_id,
                    wallpaper_id,
                    window_number: i64::try_from(window.window_number?).ok()?,
                    parked: window.parked,
                })
            })
            .collect()
    }

    /// Turns renderer work counting on or off for the whole process.
    ///
    /// Off is the default. Enabling adds one relaxed atomic increment per
    /// counted event; it starts no thread, no timer and no output stream, and
    /// counters are only ever read by an explicit `renderer_counters` call.
    ///
    /// # Errors
    ///
    /// Returns an error when the renderer rejects the call.
    pub async fn set_renderer_counters_enabled(&self, enabled: bool) -> Result<(), BridgeError> {
        self.actor.ask(SetRendererCountersEnabled { enabled }).await
    }

    /// Reads renderer work counters for every open scene.
    ///
    /// This is the evidence half of the per-surface suspension work: it answers
    /// whether a hidden surface actually stopped submitting and presenting,
    /// rather than whether a suspend decision was delivered to it.
    ///
    /// # Errors
    ///
    /// Returns an error when the renderer rejects the call.
    pub async fn renderer_counters(&self) -> Result<BridgeRendererCountersReport, BridgeError> {
        self.actor.ask(RendererCounters).await
    }

    /// Confirms that every scene that should be drawing still is, and has the
    /// engine rebuild the surface of any that is not. The host calls it once
    /// after the Mac or its displays wake, and again when presentation resumes
    /// after a wake that landed on a locked session.
    ///
    /// Nothing is rebuilt on a healthy Mac. The check reads each scene's frame
    /// counter, waits a few seconds and reads it again; only a continuous scene
    /// on an unpaused display whose counter did not move, or one that has
    /// stopped itself after a failure, is repaired, through the same budgeted
    /// recovery the engine uses for a failed frame. Paused and suspended
    /// displays, scenes that update on events, web pages and native video are
    /// never touched. One row comes back for every display with a scene open.
    ///
    /// The wait happens outside the actor, so it stalls no other request, and
    /// a second call waits for the first rather than overlapping it. `reason`
    /// names what triggered the check in the log.
    ///
    /// # Errors
    ///
    /// Returns an error when the bridge's runtime is gone or the check task
    /// failed.
    pub async fn revalidate_scene_presentation(
        &self,
        reason: String,
    ) -> Result<Vec<BridgeSurfaceCheck>, BridgeError> {
        let engine = self.engine.clone();
        let turn = Arc::clone(&self.wake_check_turn);
        let grace = self.wake_check_grace;
        // The check waits on a timer, which needs the bridge's own runtime: the
        // future the host polls is not running on one.
        let checks = self
            .actor
            .run_on_runtime(async move {
                let _turn = turn.lock().await;
                log::info!(
                    "[wallpaper-bridge power] wake check ({reason}): looking at scene surfaces"
                );
                crate::engine::revalidate::revalidate_presentation(&engine, grace).await
            })
            .await?;
        Ok(checks
            .into_iter()
            .map(|check| BridgeSurfaceCheck {
                display_id: check.display_id,
                outcome: check.outcome().to_owned(),
                frames_before: check.frames_before,
                frames_after: check.frames_after,
            })
            .collect())
    }

    /// Sets the internal rasterization scale the user prefers.
    ///
    /// Clamped to the range the renderer honours. This is a preference: while
    /// a power profile is in force the running scale is that profile's, and
    /// the snapshot reports both.
    ///
    /// # Errors
    ///
    /// Returns an error when the preference cannot be saved or a running
    /// scene rejects the new scale.
    pub async fn set_render_scale(
        &self,
        scale: f32,
    ) -> Result<BridgeSnapshotBundle, BridgeError> {
        self.actor.ask(SetRenderScale { scale }).await
    }

    /// Sets the scale and frame rate used while battery mode is reduced quality.
    ///
    /// Does not itself select that mode. A machine already on reduced quality
    /// picks the new values up immediately.
    ///
    /// # Errors
    ///
    /// Returns an error when the profile cannot be saved or a running scene
    /// rejects the resulting scale or rate.
    pub async fn set_battery_quality_profile(
        &self,
        render_scale: f32,
        target_fps: u32,
    ) -> Result<BridgeSnapshotBundle, BridgeError> {
        self.actor
            .ask(SetBatteryQualityProfile {
                render_scale,
                target_fps,
            })
            .await
    }

    /// Turns the scene renderer's static-subgraph caching and redundant
    /// copy-pass elimination on or off for the renderer process.
    ///
    /// On by default, and applied to running scenes in place: it changes how a
    /// frame is built, never what the scene is, so nothing is rebuilt and no
    /// wallpaper restarts.
    ///
    /// # Errors
    ///
    /// Returns an error when the setting cannot be saved or the renderer
    /// rejects the call.
    pub async fn set_scene_optimization_enabled(
        &self,
        enabled: bool,
    ) -> Result<BridgeSnapshotBundle, BridgeError> {
        self.actor.ask(SetSceneOptimizationEnabled { enabled }).await
    }

    /// Turns whole-scene on-demand updating on or off for the renderer
    /// process.
    ///
    /// Off by default. With it on, a scene the renderer can prove has no
    /// continuing reason to redraw stops its periodic tick and wakes on
    /// events; a scene it cannot prove that about keeps running. It is not a
    /// frame-rate cap, and it is not the scene optimisation setting: that one
    /// changes how a frame is built, this one changes whether one is built at
    /// all. The snapshot's `scene_update_modes` reports what each running
    /// scene actually settled on.
    ///
    /// # Errors
    ///
    /// Returns an error when the setting cannot be saved or the renderer
    /// rejects the call.
    pub async fn set_scene_on_demand_enabled(
        &self,
        enabled: bool,
    ) -> Result<BridgeSnapshotBundle, BridgeError> {
        self.actor.ask(SetSceneOnDemandEnabled { enabled }).await
    }

    /// Lets a native Metal scene's materials sample a video's NV12 planes
    /// directly instead of one pre-converted colour image.
    ///
    /// Off by default, and experimental. It selects between two programs that
    /// were both compiled with the scene's graph, so a running scene picks it
    /// up at its next frame boundary without being reparsed or restarted. A
    /// material with no usable plane variant, and any frame that is not 8-bit
    /// NV12, keeps converting whatever this says. The snapshot's
    /// `scene_renderers` reports the path each running scene's video textures
    /// actually took.
    ///
    /// # Errors
    ///
    /// Returns an error when the setting cannot be saved or the renderer
    /// rejects the call.
    pub async fn set_scene_video_plane_sampling_enabled(
        &self,
        enabled: bool,
    ) -> Result<BridgeSnapshotBundle, BridgeError> {
        self.actor
            .ask(SetSceneVideoPlaneSamplingEnabled { enabled })
            .await
    }

    /// Chooses how many pixels a 2D scene wallpaper is rasterized with.
    ///
    /// `"display"` (the default) rasterizes the canvas at the size it is
    /// presented at on the display, as Wallpaper Engine does; `"canvas"`
    /// rasterizes at the size the author made it and stretches the result,
    /// which costs the least. The internal render scale divides whichever is
    /// chosen. Perspective scenes and plain videos ignore it. Running scenes
    /// resize their render targets in place; nothing is reparsed, a scene's
    /// own video layers stay open and carry on, and a pause the user asked for
    /// is untouched.
    ///
    /// # Errors
    ///
    /// Returns an error when `mode` is not one of the two names, when the
    /// setting cannot be saved, or when the renderer rejects the change.
    pub async fn set_scene_resolution(
        &self,
        mode: String,
    ) -> Result<BridgeSnapshotBundle, BridgeError> {
        let resolution = match mode.as_str() {
            "canvas" => SceneResolutionCfg::Canvas,
            "display" => SceneResolutionCfg::Display,
            other => {
                return Err(BridgeError::invalid_input(format!(
                    "unknown scene resolution {other}"
                )));
            }
        };
        self.actor.ask(SetSceneResolution { resolution }).await
    }

    /// The most recent process-wide audio analysis, or `None` when none has
    /// been produced. `None` and a spectrum with `stereo` false are different
    /// states: nothing has been analysed yet, versus a mono capture.
    ///
    /// 128 bins: 0..=63 the left channel, 64..=127 the right, low index meaning
    /// low frequency. `stereo` reports how the signal was captured, not whether
    /// the halves differ; see [`BridgeAudioSpectrum`].
    ///
    /// Synchronous on purpose: this is polled at the page's callback rate and
    /// reads a process-wide buffer that no actor owns.
    ///
    /// # Errors
    ///
    /// Returns an error when the renderer rejects the read.
    pub fn web_audio_spectrum(&self) -> Result<Option<BridgeAudioSpectrum>, BridgeError> {
        let spectrum = self
            .engine
            .current_audio_spectrum()
            .map_err(|error| BridgeError::engine(error.to_string()))?;

        Ok(spectrum.map(|spectrum| BridgeAudioSpectrum {
            generation: spectrum.generation,
            stereo: spectrum.stereo,
            bins: spectrum.bins.to_vec(),
        }))
    }

    /// Records or withdraws one web page as a live consumer of the system
    /// audio capture.
    ///
    /// A web wallpaper has no renderer scene, so without this the capture tap
    /// stays shut for a display showing only web wallpapers. Withdrawing the
    /// last consumer closes the tap again. Mute and volume are unrelated: a
    /// silenced wallpaper still analyses what the system is playing.
    ///
    /// # Errors
    ///
    /// Returns an error when the renderer rejects the capture change.
    pub async fn set_web_audio_subscribed(
        &self,
        wallpaper_id: String,
        display_id: u32,
        subscribed: bool,
    ) -> Result<(), BridgeError> {
        self.actor
            .ask(SetWebAudioSubscribed {
                wallpaper_id,
                display_id,
                subscribed,
            })
            .await
    }

    /// Turns system media integration on or off for one wallpaper.
    ///
    /// On by default; a saved choice is kept. Turning it on allows a search for
    /// a system media source, not a promise that one exists.
    ///
    /// # Errors
    ///
    /// Returns an error when the wallpaper id is unknown or the setting cannot
    /// be saved.
    pub async fn set_media_integration_enabled(
        &self,
        wallpaper_id: String,
        enabled: bool,
    ) -> Result<BridgeWallpaperMutationBundle, BridgeError> {
        self.actor
            .ask(SetMediaIntegrationEnabled {
                wallpaper_id,
                enabled,
            })
            .await
    }

    /// Records one system media event so a page loading later can be brought
    /// up to date.
    ///
    /// The bridge neither reads the system player nor delivers to any page:
    /// the host owns both ends and this only remembers the latest event of
    /// each kind, verbatim. An event carrying a `generation` older than one
    /// already stored is dropped rather than overwriting newer state, which is
    /// what makes a late artwork fetch harmless.
    ///
    /// # Errors
    ///
    /// Returns an error when `json` is not an object or its `type` is not a
    /// media event tag.
    pub async fn submit_system_media_event(&self, json: String) -> Result<(), BridgeError> {
        let _submission = self.system_media_submission.lock().await;
        if self.system_media.submit(&json)? == crate::media::MediaSubmission::Stale {
            return Ok(());
        }
        self.actor
            .ask(crate::actor::messages::FanOutSystemMediaEvent { json })
            .await
    }

    /// Uploads `$mediaThumbnail` RGBA to every opted-in desktop scene.
    ///
    /// # Errors
    ///
    /// Returns an error when the payload is not `width * height * 4` bytes or
    /// the renderer rejects the upload.
    pub async fn apply_system_media_artwork(
        &self,
        width: u32,
        height: u32,
        rgba: Vec<u8>,
    ) -> Result<(), BridgeError> {
        self.actor
            .ask(crate::actor::messages::FanOutSystemMediaArtwork {
                width,
                height,
                rgba,
            })
            .await
    }

    /// Which applied desktop scenes have consented to now-playing.
    ///
    /// The host starts and stops its system media source from this, so a
    /// machine whose wallpapers all have the setting off is never asked for
    /// Automation permission and nothing reads what is playing. A handle that
    /// was not in the previous answer is a scene with no media state yet, which
    /// is what tells the host to replay what it already knows.
    ///
    /// # Errors
    ///
    /// Returns an error when the bridge actor is gone.
    /// Waits for the next `engine.openUserShortcut` request from a wallpaper
    /// whose user has consented to media integration.
    ///
    /// Long-polls rather than returning immediately: a press is rare, and a
    /// caller that had to ask repeatedly would burn wakeups finding nothing.
    /// The wait happens outside the actor, so it stalls no other request.
    ///
    /// Requests from wallpapers without that consent are dropped here rather
    /// than handed on -- a wallpaper the user has not let near their media must
    /// not reach a media player through this.
    ///
    /// # Errors
    ///
    /// Returns an error when the engine has shut the channel.
    pub async fn next_user_shortcut(&self) -> Result<BridgeUserShortcut, BridgeError> {
        loop {
            let event = {
                let mut receiver = self.user_shortcuts.lock().await;
                receiver.recv().await
            };
            let Some(event) = event else {
                log::warn!("the user shortcut channel closed: every sender was dropped");
                return Err(BridgeError::engine("the engine stopped reporting user shortcuts"));
            };
            // Consent, not liveness: this asks whether the user allowed this
            // wallpaper near their media, which does not stop being true
            // because playback is paused or a display went dark.
            // A momentary failure to read consent is not a reason to stop
            // taking presses; the caller would have to treat it as the channel
            // having closed, which is permanent.
            let consented = match self.system_media_consent_handles().await {
                Ok(handles) => handles,
                Err(error) => {
                    log::warn!("could not read media consent for a user shortcut: {error}");
                    continue;
                }
            };
            if consented.contains(&event.scene_handle) {
                return Ok(event);
            }
            // A press is rare and deliberate, and being dropped here is
            // indistinguishable from never having been reported at all.
            log::info!(
                "ignored user shortcut {} from scene handle {}, which has no media consent; consented: {:?}",
                event.property,
                event.scene_handle,
                consented
            );
        }
    }

    pub async fn system_media_scene_handles(&self) -> Result<Vec<u64>, BridgeError> {
        self.actor
            .ask(crate::actor::messages::GetSystemMediaSceneHandles)
            .await
    }

    /// Handles whose user allowed media integration, whether or not they are
    /// currently being fed. Use `system_media_scene_handles` to decide whether
    /// to consume at all.
    ///
    /// # Errors
    ///
    /// Returns an error when the bridge actor is gone.
    pub async fn system_media_consent_handles(&self) -> Result<Vec<u64>, BridgeError> {
        self.actor
            .ask(crate::actor::messages::GetSystemMediaConsentHandles)
            .await
    }

    /// Every retained media event as a JSON array, in replay order, or `None`
    /// when nothing has been submitted yet.
    #[must_use]
    pub fn current_system_media_state(&self) -> Option<String> {
        self.system_media.current_state_json()
    }

    /// Running scene wallpapers whose users enabled music information.
    pub async fn scene_media_wallpaper_ids(&self) -> Result<Vec<String>, BridgeError> {
        self.actor.ask(crate::actor::messages::GetSceneMediaWallpapers).await
    }

    /// Publishes a bounded player snapshot; delivery rechecks per-wallpaper consent.
    pub async fn update_scene_media(&self, wallpaper_id: String, snapshot: BridgeMediaSnapshot) -> Result<(), BridgeError> {
        let state = snapshot.into_state()?;
        self.actor.ask(crate::actor::messages::UpdateSceneMedia { wallpaper_id, state }).await
    }

    /// Stores the path the host staged for a file or directory property, or
    /// clears it when `path` is `None`.
    ///
    /// The value is persisted exactly as given and reaches the page's
    /// `applyUserProperties` unchanged. The host decides what a page can open,
    /// so nothing here rewrites, resolves or escapes the path. Refused for any
    /// other property kind, including texture pickers, which name scene assets
    /// rather than paths.
    ///
    /// # Errors
    ///
    /// Returns an error when the wallpaper or property id is unknown, the
    /// property is not a file or directory property, or the value cannot be
    /// saved.
    pub async fn set_property_path(
        &self,
        wallpaper_id: String,
        property_id: String,
        path: Option<String>,
    ) -> Result<BridgeWallpaperMutationBundle, BridgeError> {
        self.actor
            .ask(SetPropertyPath {
                wallpaper_id,
                property_id,
                path,
            })
            .await
    }

    /// Plain local videos the host should play natively. Empty while the
    /// backend is off.
    ///
    /// # Errors
    ///
    /// Returns an error when a media path cannot be represented.
    pub async fn native_video_wallpapers(
        &self,
    ) -> Result<Vec<BridgeNativeVideoWallpaper>, BridgeError> {
        self.actor.ask(GetNativeVideoWallpapers).await
    }

    /// # Errors
    ///
    /// Returns an error when the wallpaper id, property id, or value is
    /// invalid.
    pub async fn edit_property(
        &self,
        wallpaper_id: String,
        property_id: String,
        value: BridgePropertyValue,
    ) -> Result<BridgeWallpaperMutationBundle, BridgeError> {
        self.actor
            .ask(EditProperty {
                wallpaper_id,
                property_id,
                value,
            })
            .await
    }

    /// # Errors
    ///
    /// Returns an error when the wallpaper or property id is unknown.
    pub async fn restore_property_default(
        &self,
        wallpaper_id: String,
        property_id: String,
    ) -> Result<BridgeWallpaperMutationBundle, BridgeError> {
        self.actor
            .ask(RestorePropertyDefault {
                wallpaper_id,
                property_id,
            })
            .await
    }

    /// Stages the authored default for every property of the wallpaper except
    /// the files and folders the user chose; cancelling the options undoes it.
    ///
    /// # Errors
    ///
    /// Returns an error when the wallpaper id is unknown.
    pub async fn restore_all_property_defaults(
        &self,
        wallpaper_id: String,
    ) -> Result<BridgeWallpaperMutationBundle, BridgeError> {
        self.actor
            .ask(RestoreAllPropertyDefaults { wallpaper_id })
            .await
    }

    /// `user_initiated` says the user asked for this wallpaper themselves. Only
    /// then does applying it lift the crash-loop guard's hold on it: a playlist,
    /// a schedule or a rule that comes back to a wallpaper that crashed the app
    /// must not reopen it, or the guard would stop nothing.
    ///
    /// # Errors
    ///
    /// Returns an error when pending options cannot be applied or persisted.
    pub async fn apply_wallpaper_options(
        &self,
        wallpaper_id: String,
        user_initiated: bool,
    ) -> Result<BridgeWallpaperMutationBundle, BridgeError> {
        self.actor
            .ask(ApplyWallpaperOptions {
                wallpaper_id,
                user_initiated,
            })
            .await
    }

    /// # Errors
    ///
    /// Returns an error when the wallpaper id is unknown.
    pub async fn cancel_wallpaper_options(
        &self,
        wallpaper_id: String,
    ) -> Result<BridgeWallpaperMutationBundle, BridgeError> {
        self.actor
            .ask(CancelWallpaperOptions { wallpaper_id })
            .await
    }

    /// # Errors
    ///
    /// Returns an error when pending options cannot be applied or persisted.
    pub async fn ok_wallpaper_options(
        &self,
        wallpaper_id: String,
    ) -> Result<BridgeWallpaperMutationBundle, BridgeError> {
        // The OK button of the options dialog is the user's own choice.
        self.apply_wallpaper_options(wallpaper_id, true).await
    }

    /// # Errors
    ///
    /// Returns an error when the engine cannot pause all scenes.
    pub async fn pause_all(&self) -> Result<BridgeSnapshotBundle, BridgeError> {
        self.actor
            .ask(SetGlobalPlayback {
                playback_state: BridgePlaybackState::Paused,
            })
            .await
    }

    /// # Errors
    ///
    /// Returns an error when the engine cannot resume all scenes.
    pub async fn play_all(&self) -> Result<BridgeSnapshotBundle, BridgeError> {
        self.actor
            .ask(SetGlobalPlayback {
                playback_state: BridgePlaybackState::Playing,
            })
            .await
    }

    /// # Errors
    ///
    /// Returns an error when the display update cannot be committed.
    pub async fn eject_wallpaper_from_display(
        &self,
        display_id: String,
        wallpaper_id: String,
    ) -> Result<BridgeDisplayMutationBundle, BridgeError> {
        self.actor
            .ask(EjectWallpaperFromDisplay {
                display_id,
                wallpaper_id,
            })
            .await
    }

    /// Asks the power watcher to read the power source again and apply the battery policy if
    /// it differs from the one last applied. The host calls it when the Mac wakes, because a
    /// plug or unplug during sleep may not have been reported. Safe at any time; it returns at
    /// once, and does nothing when the bridge is not watching the power source.
    pub fn resample_power_source(&self) {
        if let Some(watcher) = &self.power_watcher {
            watcher.resample();
        }
    }

    /// # Errors
    ///
    /// Returns an error when the engine cannot shut down active scenes.
    pub async fn shutdown(&self) -> Result<(), BridgeError> {
        // Before the request, not inside it: the actor handles one message at
        // a time, and startup holds it until the first scene shows a frame.
        // Asking first would leave the record open for as long as the load
        // takes, and a quit that gives up waiting would count it as a crash.
        self.load_journal.clean_shutdown();
        self.actor.ask(Shutdown).await
    }
}

#[cfg(test)]
impl WallpaperBridge {
    pub(crate) async fn mounted_state_for_test(&self) -> Result<BridgeActorState, BridgeError> {
        self.actor
            .ask(crate::actor::lifecycle_test_support::MountedStateObservation)
            .await
    }

    /// # Panics
    ///
    /// Panics if the test bridge actor cannot be spawned.
    #[must_use]
    pub fn new_for_test() -> Self {
        BridgeBuilder::new(FakeEngineFacade::default())
            .build()
            .expect("tokio runtime and config load for wallpaper bridge")
    }

    /// # Panics
    ///
    /// Panics if the actor rejects the test wallpaper injection.
    pub async fn inject_wallpaper_for_test(
        &self,
        id: &str,
        title: &str,
        kind: BridgeWallpaperKind,
    ) {
        self.actor
            .ask(InjectWallpaperForTest {
                id: id.to_string(),
                title: title.to_string(),
                kind,
            })
            .await
            .expect("test wallpaper injection should succeed");
    }

    /// # Panics
    ///
    /// Panics if the actor rejects the test scene wallpaper config injection.
    pub async fn inject_scene_wallpaper_config_for_test(&self, id: &str, title: &str) {
        self.actor
            .ask(InjectSceneWallpaperConfigForTest {
                id: id.to_string(),
                title: title.to_string(),
            })
            .await
            .expect("test scene wallpaper config injection should succeed");
    }

    /// # Panics
    ///
    /// Panics if the actor rejects the test scene project injection.
    pub async fn inject_scene_project_for_test(&self, id: &str, title: &str, project_json: &str) {
        self.actor
            .ask(InjectSceneProjectForTest {
                id: id.to_string(),
                title: title.to_string(),
                project_json: project_json.to_string(),
            })
            .await
            .expect("test scene project injection should succeed");
    }

    /// # Panics
    ///
    /// Panics if the actor rejects the test display injection.
    pub async fn inject_display_for_test(&self, display_id: &str, title: &str) {
        self.actor
            .ask(InjectDisplayForTest {
                display_id: display_id.to_string(),
                title: title.to_string(),
            })
            .await
            .expect("test display injection should succeed");
    }

    /// # Panics
    ///
    /// Panics if the actor rejects the test library replacement.
    pub async fn replace_library_for_test(&self, entries: Vec<BridgeWallpaperEntry>) {
        self.actor
            .ask(ReplaceLibraryForTest { entries })
            .await
            .expect("test library replacement should succeed");
    }

    /// # Panics
    ///
    /// Panics if the actor rejects the test wallpaper config replacement.
    pub async fn replace_wallpaper_config_for_test(&self, id: &str, config: WallpaperConfig) {
        self.actor
            .ask(ReplaceWallpaperConfigForTest {
                id: id.to_string(),
                config,
            })
            .await
            .expect("test wallpaper config replacement should succeed");
    }

    /// # Panics
    ///
    /// Panics if the actor rejects the test power source update.
    pub async fn set_power_source_for_test(&self, source: crate::power::PowerSource) {
        self.actor
            .ask(SetPowerSource {
                source,
                initial_sample: false,
            })
            .await
            .expect("test power source update should succeed");
    }

    /// # Panics
    ///
    /// Panics if the actor rejects the test initial power source update.
    pub async fn set_initial_power_source_for_test(&self, source: crate::power::PowerSource) {
        self.actor
            .ask(SetPowerSource {
                source,
                initial_sample: true,
            })
            .await
            .expect("test initial power source update should succeed");
    }

    /// # Panics
    ///
    /// Panics if the actor rejects the test initial-frame readiness update.
    pub async fn initial_frame_ready_for_test(&self) {
        self.actor
            .ask(InitialFrameReady)
            .await
            .expect("test initial-frame readiness update should succeed");
    }
}

impl From<&crate::library::WallpaperEntry> for BridgeWallpaperEntry {
    fn from(entry: &crate::library::WallpaperEntry) -> Self {
        Self {
            id: entry.workshop_id.clone(),
            title: entry.title.clone(),
            kind: BridgeWallpaperKind::from(entry.project_type),
            supported: entry.supported,
            active: false,
            selected: false,
            preview_path: entry
                .preview_path
                .as_ref()
                .map(|path| path.to_string_lossy().to_string()),
        }
    }
}

impl From<BridgeScalingMode> for ScalingMode {
    fn from(value: BridgeScalingMode) -> Self {
        match value {
            BridgeScalingMode::None => Self::None,
            BridgeScalingMode::Stretch => Self::Stretch,
            BridgeScalingMode::Match => Self::Fit,
            BridgeScalingMode::Fill => Self::Fill,
            BridgeScalingMode::MatchBlurred => Self::FitBlurred,
        }
    }
}

impl From<ScalingMode> for BridgeScalingMode {
    fn from(value: ScalingMode) -> Self {
        match value {
            ScalingMode::None => Self::None,
            ScalingMode::Stretch => Self::Stretch,
            ScalingMode::Fit => Self::Match,
            ScalingMode::Fill => Self::Fill,
            ScalingMode::FitBlurred => Self::MatchBlurred,
        }
    }
}

impl From<&crate::project::PropertyKind> for BridgePropertyKind {
    fn from(kind: &crate::project::PropertyKind) -> Self {
        use crate::project::PropertyKind;
        match kind {
            PropertyKind::Slider => Self::Slider,
            PropertyKind::Combo => Self::Combo,
            PropertyKind::Bool => Self::Bool,
            PropertyKind::Color => Self::Color,
            PropertyKind::TextInput => Self::TextInput,
            PropertyKind::Text => Self::Text,
            PropertyKind::Group => Self::Group,
            PropertyKind::File => Self::File,
            PropertyKind::Directory => Self::Directory,
            PropertyKind::Texture => Self::Texture,
            PropertyKind::Unknown(_) => Self::Unknown,
        }
    }
}

impl From<crate::project::PropertyValue> for BridgePropertyValue {
    fn from(value: crate::project::PropertyValue) -> Self {
        match value {
            crate::project::PropertyValue::Bool(value) => Self::Bool { value },
            crate::project::PropertyValue::Number(value) => Self::Number { value },
            crate::project::PropertyValue::String(value) => Self::String { value },
            crate::project::PropertyValue::ColorRgb(red, green, blue) => Self::ColorRgb {
                red: f64::from(red),
                green: f64::from(green),
                blue: f64::from(blue),
            },
            crate::project::PropertyValue::Null => Self::Empty,
        }
    }
}

/// The reverse of the widening conversion above. Colour channels narrow with a
/// plain cast and are not clamped, so a value that came from an `f32` returns
/// to it exactly.
#[allow(clippy::cast_possible_truncation)]
impl From<BridgePropertyValue> for crate::project::PropertyValue {
    fn from(value: BridgePropertyValue) -> Self {
        use BridgePropertyValue as Bridge;
        match value {
            Bridge::Empty => Self::Null,
            Bridge::Number { value } => Self::Number(value),
            Bridge::Bool { value } => Self::Bool(value),
            Bridge::String { value } => Self::String(value),
            Bridge::ColorRgb { red, green, blue } => {
                Self::ColorRgb(red as f32, green as f32, blue as f32)
            }
        }
    }
}

#[cfg(test)]
mod mouse_polling_tests {
    use super::MousePollingControl;
    use std::sync::{Arc, Barrier, mpsc};
    use std::time::Duration;

    #[test]
    fn policy_and_consumer_changes_never_overwrite_each_other() {
        let control = MousePollingControl::new();
        control.set_policy_enabled(true);
        assert!(!control.is_enabled());
        control.set_has_consumers(true);
        assert!(control.is_enabled());
        control.set_policy_enabled(false);
        control.set_has_consumers(false);
        control.set_has_consumers(true);
        assert!(!control.is_enabled());
        control.set_policy_enabled(true);
        assert!(control.is_enabled());
        control.set_has_consumers(false);
        control.set_policy_enabled(false);
        control.set_policy_enabled(true);
        assert!(!control.is_enabled());
        control.stop();
        control.set_has_consumers(true);
        control.set_policy_enabled(true);
        assert!(!control.is_enabled());
        assert!(control.wait_for_sample().is_none());
        assert!(!control.wait_interval(Duration::from_millis(16)));
    }

    #[test]
    fn consumer_arrival_wakes_waiter_and_stop_wakes_ineligible_waiter() {
        for activate in [false, true] {
            let control = Arc::new(MousePollingControl::new());
            control.set_policy_enabled(true);
            let started = Arc::new(Barrier::new(2));
            let (send, receive) = mpsc::channel();
            let worker_control = control.clone();
            let worker_started = started.clone();
            let worker = std::thread::spawn(move || {
                worker_started.wait();
                send.send(worker_control.wait_for_sample().is_some()).unwrap();
            });
            started.wait();
            if activate {
                control.set_has_consumers(true);
            } else {
                control.stop();
                control.set_has_consumers(true);
            }
            assert_eq!(receive.recv_timeout(Duration::from_secs(1)).unwrap(), activate);
            worker.join().unwrap();
        }
    }

    #[test]
    fn poisoned_control_fails_closed_and_rejects_late_callbacks() {
        let control = Arc::new(MousePollingControl::new());
        control.set_policy_enabled(true);
        control.set_has_consumers(true);
        let poisoned = control.clone();
        assert!(std::thread::spawn(move || {
            let Ok(_guard) = poisoned.state.lock() else {
                panic!("control was already poisoned");
            };
            panic!("injected control poison");
        }).join().is_err());
        assert!(!control.is_enabled());
        control.set_has_consumers(true);
        control.set_policy_enabled(true);
        assert!(control.wait_for_sample().is_none());
        assert!(!control.wait_interval(Duration::from_millis(16)));
    }
}
