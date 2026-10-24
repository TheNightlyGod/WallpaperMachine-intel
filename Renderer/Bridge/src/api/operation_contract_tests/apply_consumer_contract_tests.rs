//! Fresh real-actor Apply consumers, mounted beneath `operation_contract_tests`.
//! Controlled observations establish requested IO, not native renderer output.

use super::*;
use crate::api::mounted_lifecycle::shutdown_and_drain;
use std::any::Any;
use std::panic::{AssertUnwindSafe, catch_unwind, resume_unwind};

fn unassigned_app() -> AppConfig {
    let mut app = AppConfig::default();
    app.general.last_selected_wallpaper = Some(A.into());
    app.monitors = vec![MonitorCfg {
        selector: SerializedSelector::Primary,
        enabled: false,
        mode: "independent".into(),
        wallpaper: None,
        mirror_target: None,
    }];
    app
}

fn options(fixture: &ConsumerFixture, id: &str) -> BridgeWallpaperOptionsSnapshot {
    fixture
        .handle()
        .blocking_ask(GetWallpaperOptionsSnapshot {
            wallpaper_id: id.into(),
        })
        .unwrap()
}

fn option_row<'a>(
    options: &'a BridgeWallpaperOptionsSnapshot,
    key: &str,
) -> &'a BridgeDisplayConfigRow {
    options
        .display_configurations
        .iter()
        .find(|row| row.display_id == key)
        .expect("connected configuration-selector options row")
}

fn observations_since(fixture: &ConsumerFixture, mark: usize) -> Vec<EngineObservation> {
    fixture.engine.observations()[mark..].to_vec()
}

fn scale_calls(observations: &[EngineObservation]) -> Vec<EngineObservation> {
    observations
        .iter()
        .filter(|observation| matches!(observation, EngineObservation::ScalingFactor { .. }))
        .cloned()
        .collect()
}

fn audio_calls(observations: &[EngineObservation]) -> Vec<EngineObservation> {
    observations
        .iter()
        .filter(|observation| {
            matches!(
                observation,
                EngineObservation::Volume { .. }
                    | EngineObservation::Muted { .. }
                    | EngineObservation::AudioResponse { .. }
                    | EngineObservation::Capture { .. }
            )
        })
        .cloned()
        .collect()
}

// The case, not a fallible completion call, owns each helper's JoinHandle.
// Cancellation stops only helper-side waiting; actor shutdown still drains the
// genuine operation. It never supplies a synthetic operation reply.
struct ApplyRequestHelper {
    release: Option<tokio::sync::oneshot::Sender<()>>,
    cancel: Option<tokio::sync::oneshot::Sender<()>>,
    thread: Option<thread::JoinHandle<()>>,
}

#[derive(Default)]
struct ApplyRequestRegistry {
    helpers: std::sync::Mutex<Vec<ApplyRequestHelper>>,
}

impl ApplyRequestRegistry {
    fn register(&self, helper: ApplyRequestHelper) -> usize {
        let mut helpers = self.helpers.lock().unwrap_or_else(|poison| poison.into_inner());
        let index = helpers.len();
        helpers.push(helper);
        index
    }

    fn release(&self, index: usize) {
        let release = self.helpers.lock().unwrap_or_else(|poison| poison.into_inner())
            [index].release.take();
        if let Some(release) = release {
            let _ = release.send(());
        }
    }

    fn cancel(&self, index: usize) {
        let cancel = self.helpers.lock().unwrap_or_else(|poison| poison.into_inner())
            [index].cancel.take();
        if let Some(cancel) = cancel {
            let _ = cancel.send(());
        }
    }

    fn join(&self, index: usize) -> Result<(), String> {
        let thread = self.helpers.lock().unwrap_or_else(|poison| poison.into_inner())
            [index].thread.take();
        if let Some(thread) = thread {
            thread.join().map_err(|payload| {
                let detail = payload.downcast_ref::<String>().map(String::as_str)
                    .or_else(|| payload.downcast_ref::<&str>().copied())
                    .unwrap_or("non-string panic payload");
                format!("registered Apply request helper panicked: {detail}")
            })?;
        }
        Ok(())
    }

    fn shutdown_and_join(&self) -> Vec<String> {
        let count = self.helpers.lock().unwrap_or_else(|poison| poison.into_inner()).len();
        for index in 0..count {
            self.release(index);
        }
        for index in 0..count {
            self.cancel(index);
        }
        let mut errors = Vec::new();
        for index in 0..count {
            if let Err(error) = self.join(index) {
                errors.push(error);
            }
        }
        errors
    }
}

struct ConsumerRequest<T> {
    reply: mpsc::Receiver<Result<T, BridgeError>>,
    helpers: Arc<ApplyRequestRegistry>,
    helper: usize,
}

impl<T> ConsumerRequest<T> {
    fn is_pending(&self) {
        assert!(matches!(self.reply.try_recv(), Err(mpsc::TryRecvError::Empty)),
            "ordinary reply arrived before the blocked engine was released");
    }

    fn release(&self) {
        self.helpers.release(self.helper);
    }

    fn finish(
        self,
        engine: &ControlledEngine,
        handles: &[SceneHandle],
    ) -> Result<T, BridgeError> {
        self.release();
        let deadline = Instant::now() + DEADLINE;
        let reply = loop {
            for handle in handles {
                if engine.display_rows().iter().any(|row| row.handle == Some(*handle)) {
                    engine.emit_first_frame(*handle);
                }
            }
            match self.reply.recv_timeout(QUANTUM) {
                Ok(reply) => break reply,
                Err(mpsc::RecvTimeoutError::Timeout) => assert!(
                    Instant::now() < deadline,
                    "real receiving-side operation reply exceeded deadline"
                ),
                Err(mpsc::RecvTimeoutError::Disconnected) => panic!("request thread lost reply"),
            }
        };
        self.helpers.join(self.helper).expect("consumer request helper did not join cleanly");
        reply
    }
}

impl<T> Drop for ConsumerRequest<T> {
    fn drop(&mut self) {
        // On any wait/assertion unwind, the case retains cancellation and join
        // ownership for this request, including responsiveness-only reads.
        self.release();
    }
}

struct ConsumerHandle {
    actor: BridgeActorHandle<ArcEngineFacade>,
    engine: ControlledEngine,
    helpers: Arc<ApplyRequestRegistry>,
}

impl ConsumerHandle {
    fn start_ask<M, T>(
        &self,
        message: M,
        release: Option<tokio::sync::oneshot::Sender<()>>,
    ) -> ConsumerRequest<T>
    where
        BridgeActor<ArcEngineFacade>: Message<M>,
        <BridgeActor<ArcEngineFacade> as Message<M>>::Reply: Reply<Ok = T, Error = BridgeError>,
        M: Send + 'static,
        T: Send + 'static,
    {
        let (sender, reply) = mpsc::sync_channel(1);
        let (cancel, cancelled) = tokio::sync::oneshot::channel();
        let runtime = tokio::runtime::Handle::current();
        let actor = self.actor.clone();
        let thread = thread::spawn(move || {
            let result = runtime.block_on(async move {
                tokio::select! {
                    _ = cancelled => None,
                    result = actor.ask::<M, T>(message) => Some(result),
                }
            });
            if let Some(result) = result {
                let _ = sender.send(result);
            }
        });
        let helper = self.helpers.register(ApplyRequestHelper {
            release,
            cancel: Some(cancel),
            thread: Some(thread),
        });
        ConsumerRequest { reply, helpers: self.helpers.clone(), helper }
    }

    fn blocking_ask<M, T>(&self, message: M) -> Result<T, BridgeError>
    where
        BridgeActor<ArcEngineFacade>: Message<M>,
        <BridgeActor<ArcEngineFacade> as Message<M>>::Reply: Reply<Ok = T, Error = BridgeError>,
        M: Send + 'static,
        T: Send + 'static,
    {
        self.start_ask(message, None).finish(&self.engine, &[])
    }
}

struct HeldApply {
    request: ConsumerRequest<BridgeWallpaperMutationBundle>,
    scenes: Vec<SceneDesc>,
    engine: ControlledEngine,
    handles: Vec<SceneHandle>,
}

impl HeldApply {
    fn new(
        fixture: &ConsumerFixture,
        result: Result<Vec<SceneResult>, EngineError>,
        handles: Vec<SceneHandle>,
    ) -> Self {
        Self::new_for(fixture, A, result, handles)
    }

    fn new_for(
        fixture: &ConsumerFixture,
        id: &str,
        result: Result<Vec<SceneResult>, EngineError>,
        handles: Vec<SceneHandle>,
    ) -> Self {
        let ReconcileControl { mut entered, release } = fixture.engine.hold_next_reconcile(result);
        let request = fixture.handle().start_ask(ApplyWallpaperOptions {
            wallpaper_id: id.into(),
            user_initiated: true,
        }, Some(release));
        let mut held = Self {
            request,
            scenes: Vec::new(),
            engine: fixture.engine.clone(),
            handles,
        };
        let deadline = Instant::now() + DEADLINE;
        held.scenes = loop {
            match entered.try_recv() {
                Ok(scenes) => break scenes,
                Err(tokio::sync::oneshot::error::TryRecvError::Empty) => {
                    assert!(Instant::now() < deadline, "actual core receipt exceeded deadline");
                    thread::sleep(QUANTUM);
                }
                Err(tokio::sync::oneshot::error::TryRecvError::Closed) => {
                    panic!("reconcile gate lost producer");
                }
            }
        };
        held
    }

    fn scenes(&self) -> &[SceneDesc] {
        &self.scenes
    }

    fn assert_pending(&self) {
        self.request.is_pending();
    }

    fn release(&mut self) {
        self.request.release();
    }

    fn finish(self) -> Result<BridgeWallpaperMutationBundle, BridgeError> {
        self.request.finish(&self.engine, &self.handles)
    }
}

// This gate parks only the actual last reduced-scale completion, after its
// mutation and lock release. Its sender shares case-owned unwind protection
// with the earlier core gate; neither phase is treated as operation completion.
struct ParkedApplyCompletion {
    entered: tokio::sync::oneshot::Receiver<()>,
    helpers: Arc<ApplyRequestRegistry>,
    release: usize,
}

impl ParkedApplyCompletion {
    fn new(fixture: &ConsumerFixture, handle: SceneHandle) -> Self {
        let OperationControl { entered, release } =
            fixture.engine.hold_next_render_scale_completion(handle);
        let release = fixture.helpers.register(ApplyRequestHelper {
            release: Some(release),
            cancel: None,
            thread: None,
        });
        Self { entered, helpers: fixture.helpers.clone(), release }
    }

    fn wait_for_entry(&mut self, fixture: &ConsumerFixture, handle: SceneHandle) {
        let deadline = Instant::now() + DEADLINE;
        loop {
            if fixture.engine.display_rows().iter().any(|row| row.handle == Some(handle)) {
                fixture.engine.emit_first_frame(handle);
            }
            match self.entered.try_recv() {
                Ok(()) => return,
                Err(tokio::sync::oneshot::error::TryRecvError::Empty) => {
                    assert!(Instant::now() < deadline,
                        "actual terminal render-scale completion exceeded deadline");
                    thread::sleep(QUANTUM);
                }
                Err(tokio::sync::oneshot::error::TryRecvError::Closed) => {
                    panic!("terminal render-scale gate lost producer");
                }
            }
        }
    }

    fn release(&self) {
        self.helpers.release(self.release);
    }
}

impl Drop for ParkedApplyCompletion {
    fn drop(&mut self) {
        self.release();
    }
}

// Reuse the accepted fixture as the real setup/store/engine owner. This private
// view changes only scenario request ownership, never actor or engine policy.
struct ConsumerFixture {
    inner: Fixture,
    helpers: Arc<ApplyRequestRegistry>,
}

impl std::ops::Deref for ConsumerFixture {
    type Target = Fixture;

    fn deref(&self) -> &Self::Target {
        &self.inner
    }
}

impl ConsumerFixture {
    fn handle(&self) -> ConsumerHandle {
        ConsumerHandle {
            actor: actor(&self.inner.bridge).clone(),
            engine: self.inner.engine.clone(),
            helpers: self.helpers.clone(),
        }
    }

    fn snapshots(&self) -> BridgeSnapshotBundle {
        self.handle().blocking_ask(GetAllSnapshots).unwrap()
    }

    fn select(&self, id: &str) {
        self.handle().blocking_ask(SelectWallpaper { id: id.into() }).unwrap();
    }

    fn edit(&self, id: &str, value: f64) {
        self.handle().blocking_ask(EditProperty {
            wallpaper_id: id.into(),
            property_id: "gain".into(),
            value: BridgePropertyValue::Number { value },
        }).unwrap();
    }

    fn enable_draft(&self, id: &str, display: &str, enabled: bool) {
        self.handle().blocking_ask(SetDisplayConfigEnabled {
            wallpaper_id: id.into(),
            display_id: display.into(),
            enabled,
        }).unwrap();
    }

    fn start_apply(&self, id: &str, user: bool) -> ConsumerRequest<BridgeWallpaperMutationBundle> {
        self.handle().start_ask(ApplyWallpaperOptions {
            wallpaper_id: id.into(),
            user_initiated: user,
        }, None)
    }

    fn cancel(&self, id: &str) -> Result<BridgeWallpaperMutationBundle, BridgeError> {
        self.handle().blocking_ask(CancelWallpaperOptions { wallpaper_id: id.into() })
    }

    fn repairs_idle(&self) {
        let deadline = Instant::now() + DEADLINE;
        while !self.handle().blocking_ask(RepairsIdle).unwrap() {
            assert!(Instant::now() < deadline, "receiving-side repair settlement exceeded deadline");
            thread::sleep(QUANTUM);
        }
        self.snapshots();
    }

    fn successful_apply(&self, id: &str, handles: &[(u32, u64)]) -> Vec<SceneDesc> {
        let held = HeldApply::new_for(
            self,
            id,
            Ok(handles.iter().map(|(display, raw)| result(*display, *raw)).collect()),
            handles.iter().map(|(_, raw)| SceneHandle::new(*raw)).collect(),
        );
        let scenes = held.scenes().to_vec();
        held.finish().unwrap();
        self.repairs_idle();
        scenes
    }
}

// The fixture remains owned outside the assertion-unwind boundary. Both real
// actors drain on the external test runtime before any owned root is removed.
struct ConsumerRun {
    fixture: Option<ConsumerFixture>,
    reopened: Option<WallpaperBridge>,
    helpers: Arc<ApplyRequestRegistry>,
}

impl ConsumerRun {
    fn fixture(&self) -> &ConsumerFixture {
        self.fixture.as_ref().unwrap()
    }

    async fn finish(self, outcome: Result<(), Box<dyn Any + Send>>) {
        let Fixture {
            bridge,
            engine,
            store,
            paths,
            root,
            clock,
            prior_tickets,
        } = self.fixture.unwrap().inner;
        let helpers = self.helpers;
        let mut drain_errors = tokio::task::spawn_blocking(move || helpers.shutdown_and_join())
            .await
            .expect("Apply request-helper teardown task panicked");
        if let Some(reopened) = self.reopened {
            if let Err(error) = shutdown_and_drain(reopened).await {
                drain_errors.push(error.to_string());
            }
        }
        if let Err(error) = shutdown_and_drain(bridge).await {
            drain_errors.push(error.to_string());
        }
        drop(prior_tickets);
        drop((engine, store, paths, clock));
        if outcome.is_err() || !drain_errors.is_empty() {
            for error in &drain_errors {
                eprintln!("Apply consumer teardown failure: {error}");
            }
            eprintln!("preserving failed Apply consumer evidence at {}", root.0.display());
            std::mem::forget(root);
        } else {
            drop(root);
        }
        if let Err(payload) = outcome {
            resume_unwind(payload);
        }
        assert!(drain_errors.is_empty(), "real helper join/actor drain failed: {drain_errors:?}");
    }
}

async fn consumer_case(
    app: AppConfig,
    rows: Vec<DisplaySnapshotEntry>,
    body: impl FnOnce(&mut ConsumerRun) + Send + 'static,
) {
    // Keep the external runtime driver available to the held helper's genuine
    // async ask and cancellation, including on current-thread test runtimes.
    let (run, outcome) = tokio::task::spawn_blocking(move || {
        let helpers = Arc::new(ApplyRequestRegistry::default());
        let mut run = ConsumerRun {
            fixture: Some(ConsumerFixture {
                inner: Fixture::new(app, rows),
                helpers: helpers.clone(),
            }),
            reopened: None,
            helpers,
        };
        let outcome = catch_unwind(AssertUnwindSafe(|| body(&mut run)));
        (run, outcome)
    })
    .await
    .expect("Apply consumer assertion harness task panicked");
    run.finish(outcome).await;
}

#[tokio::test]
async fn active_factor_commit_and_independent_store_reopen() {
    consumer_case(unassigned_app(), vec![empty_row(1, 73)], |run| {
        let fixture = run.fixture();
        let key = fixture.key(1);
        fixture.select(A);
        assert!(!option_row(&options(fixture, A), &key).enabled);
        fixture
            .handle()
            .blocking_ask(SetVolume {
                wallpaper_id: A.into(),
                volume: 0.3125,
            })
            .unwrap();
        fixture.enable_draft(A, &key, true);
        let staged = options(fixture, A);
        assert!(staged.dirty);
        assert!(option_row(&staged, &key).enabled);
        assert_eq!(staged.volume, 0.3125);

        let handle = SceneHandle::new(75001);
        let requested = fixture.successful_apply(A, &[(1, handle.raw())]);
        assert_eq!(requested.len(), 1);
        assert_eq!(requested[0].display.display_id, 1);
        let active = fixture.snapshots();
        assert_eq!(active.app.playback_state, BridgePlaybackState::Playing);
        let clean = options(fixture, A);
        assert!(!clean.dirty);
        assert!(!option_row(&clean, &key).dirty);
        assert!(option_row(&clean, &key).enabled);
        assert_eq!(option_row(&clean, &key).scaling_factor, 1.0);
        assert_eq!(fixture.engine.display_rows()[0].handle, Some(handle));

        let invalid_mark = fixture.engine.observations().len();
        let clean_before_invalid = options(fixture, A);
        for factor in [0.0, -0.625, f64::INFINITY, f64::NEG_INFINITY, f64::NAN] {
            let error = fixture
                .handle()
                .blocking_ask(SetScalingFactor {
                    wallpaper_id: A.into(),
                    display_id: key.clone(),
                    factor,
                })
                .unwrap_err();
            assert_eq!(error.kind(), BridgeErrorKind::InvalidInput);
            assert_eq!(options(fixture, A), clean_before_invalid);
            assert_eq!(
                fixture.engine.live_scene_controls(handle).unwrap().scaling_factor,
                1.0
            );
        }
        fixture.repairs_idle();
        assert!(scale_calls(&observations_since(fixture, invalid_mark)).is_empty());

        let preview_mark = fixture.engine.observations().len();
        fixture
            .handle()
            .blocking_ask(SetScalingFactor {
                wallpaper_id: A.into(),
                display_id: key.clone(),
                factor: 1.375,
            })
            .unwrap();
        fixture.repairs_idle();
        assert_eq!(
            scale_calls(&observations_since(fixture, preview_mark)),
            vec![
                EngineObservation::ScalingFactor {
                    handle,
                    factor: 1.375,
                    phase: OperationPhase::Started,
                },
                EngineObservation::ScalingFactor {
                    handle,
                    factor: 1.375,
                    phase: OperationPhase::Applied,
                },
            ]
        );
        assert_eq!(
            fixture.engine.live_scene_controls(handle).unwrap().scaling_factor,
            1.375
        );
        let pending_factor = options(fixture, A);
        assert!(pending_factor.dirty);
        assert!(option_row(&pending_factor, &key).dirty);
        assert_eq!(option_row(&pending_factor, &key).scaling_factor, 1.375);

        let reconcile_count = started_reconciles(&fixture.engine);
        let apply_mark = fixture.engine.observations().len();
        let applied = fixture
            .start_apply(A, true)
            .finish(&fixture.engine, &[handle])
            .unwrap();
        fixture.repairs_idle();
        assert_eq!(started_reconciles(&fixture.engine), reconcile_count);
        assert_eq!(fixture.engine.display_rows()[0].handle, Some(handle));
        assert!(!applied.wallpaper_options.dirty);
        assert!(option_row(&applied.wallpaper_options, &key).dirty);
        assert!(option_row(&applied.wallpaper_options, &key).can_restore_defaults);
        assert_eq!(option_row(&applied.wallpaper_options, &key).scaling_factor, 1.375);
        assert!(scale_calls(&observations_since(fixture, apply_mark)).is_empty());
        assert_eq!(
            fixture.engine.live_scene_controls(handle).unwrap().scaling_factor,
            1.375
        );
        let wallpaper_on_disk: WallpaperConfig =
            serde_json::from_slice(&fixture.wallpaper_bytes(A)).unwrap();
        assert_eq!(wallpaper_on_disk.audio.volume, 0.3125);
        assert_eq!(
            wallpaper_on_disk
                .monitors
                .iter()
                .find(|monitor| monitor.selector.id() == key)
                .unwrap()
                .scaling_factor,
            1.375
        );
        let app_on_disk: AppConfig =
            toml::from_str(std::str::from_utf8(&fixture.app_bytes()).unwrap()).unwrap();
        assert!(app_on_disk.monitors.iter().any(|monitor| {
            monitor.selector.id() == key
                && monitor.enabled
                && monitor.wallpaper.as_deref() == Some(A)
        }));

        fixture.root.check(fixture.store.root());
        fixture.root.check(&fixture.paths.app_support_root());
        let reopened_engine = ControlledEngine::new(vec![empty_row(1, 73)]);
        let reopened = BridgeBuilder::new(reopened_engine.clone())
            .with_config_store(ConfigStore::open(fixture.store.root().to_path_buf()))
            .with_paths(fixture.paths.clone())
            .with_launch_at_login(inert_login_controller(LaunchAtLoginStatus::Unavailable))
            .with_mouse_polling_enabled(false)
            .with_power_watching_enabled(false)
            .build()
            .unwrap();
        run.reopened = Some(reopened);
        let reopened = run.reopened.as_ref().unwrap();
        let reader = ConsumerHandle {
            actor: actor(reopened).clone(),
            engine: reopened_engine,
            helpers: run.helpers.clone(),
        };
        reader.blocking_ask(RefreshLibrary).unwrap();
        reader
            .blocking_ask(SelectWallpaper { id: A.into() })
            .unwrap();
        let loaded: BridgeWallpaperOptionsSnapshot = reader
            .blocking_ask(GetWallpaperOptionsSnapshot {
                wallpaper_id: A.into(),
            })
            .unwrap();
        assert!(!loaded.dirty);
        assert!(option_row(&loaded, &key).dirty);
        assert!(option_row(&loaded, &key).can_restore_defaults);
        assert!(option_row(&loaded, &key).enabled);
        assert_eq!(option_row(&loaded, &key).scaling_factor, 1.375);
        assert_eq!(loaded.volume, 0.3125);
    })
    .await;
}

#[tokio::test]
async fn paused_native_follow_scene_and_last_assignment_removal() {
    consumer_case(unassigned_app(), vec![empty_row(1, 47)], |run| {
        let fixture = run.fixture();
        let key = fixture.key(1);
        fixture.select(A);
        let pause_mark = fixture.engine.observations().len();
        fixture
            .handle()
            .blocking_ask(SetGlobalPlayback {
                playback_state: BridgePlaybackState::Paused,
            })
            .unwrap();
        assert_eq!(fixture.snapshots().app.playback_state, BridgePlaybackState::Paused);
        fixture.enable_draft(A, &key, true);
        let handle = SceneHandle::new(76001);
        let before_apply = started_reconciles(&fixture.engine);
        let requested = fixture.successful_apply(A, &[(1, handle.raw())]);
        assert_eq!(started_reconciles(&fixture.engine), before_apply + 1);
        assert_eq!(requested.len(), 1);
        assert_eq!(requested[0].display.display_id, 1);
        assert_eq!(requested[0].display.refresh_rate_hz, 47);
        assert_eq!(requested[0].fps, 47);
        assert!(requested[0].paused);
        let pause_trace: Vec<_> = observations_since(fixture, pause_mark)
            .into_iter()
            .filter(|observation| {
                matches!(observation, EngineObservation::PauseAll { .. } | EngineObservation::PauseDisplay { .. })
            })
            .collect();
        assert!(pause_trace.iter().any(|observation| {
            matches!(observation, EngineObservation::PauseAll { paused: true, phase: OperationPhase::Applied, .. })
        }));
        assert!(pause_trace.iter().all(|observation| {
            matches!(observation,
                EngineObservation::PauseAll { paused: true, .. }
                    | EngineObservation::PauseDisplay { paused: true, .. })
        }), "Apply must not send an unpause: {pause_trace:?}");
        let active = fixture.snapshots();
        assert_eq!(active.app.playback_state, BridgePlaybackState::Paused);
        assert_eq!(active.app.active_wallpaper_ids, vec![A.to_owned()]);
        assert!(active.library.wallpapers.iter().find(|entry| entry.id == A).unwrap().active);
        assert_eq!(
            active.monitor_information.rows.iter().find(|row| row.display_id == key).unwrap().wallpaper_id,
            A
        );
        assert!(!options(fixture, A).dirty);

        fixture.enable_draft(A, &key, false);
        let disabled_draft = options(fixture, A);
        assert!(disabled_draft.dirty);
        assert!(!option_row(&disabled_draft, &key).enabled);
        let before_disable = started_reconciles(&fixture.engine);
        let unload_request = fixture.successful_apply(A, &[]);
        assert!(unload_request.is_empty());
        assert_eq!(started_reconciles(&fixture.engine), before_disable + 1);
        let inactive = fixture.snapshots();
        assert!(inactive.app.active_wallpaper_ids.is_empty());
        assert!(!inactive.library.wallpapers.iter().find(|entry| entry.id == A).unwrap().active);
        assert!(!option_row(&options(fixture, A), &key).enabled);
        assert!(!options(fixture, A).dirty);
    })
    .await;
}

#[tokio::test]
async fn rejected_initial_core_keeps_immediate_audio_but_not_assignment_on_disk() {
    consumer_case(unassigned_app(), vec![empty_row(1, 59)], |run| {
        let fixture = run.fixture();
        let key = fixture.key(1);
        fixture.select(A);
        fixture
            .handle()
            .blocking_ask(SetVolume {
                wallpaper_id: A.into(),
                volume: 0.4375,
            })
            .unwrap();
        assert!(!options(fixture, A).dirty);
        let saved_audio_bytes = fixture.wallpaper_bytes(A);
        let saved_audio: WallpaperConfig = serde_json::from_slice(&saved_audio_bytes).unwrap();
        assert_eq!(saved_audio.audio.volume, 0.4375);
        let app_path = fixture.store.root().join("config.toml");
        fixture.root.check(&app_path);
        fs::remove_file(&app_path).unwrap();
        assert_eq!(fs::read(&app_path).unwrap_err().kind(), std::io::ErrorKind::NotFound);

        fixture.enable_draft(A, &key, true);
        assert!(options(fixture, A).dirty);
        assert_eq!(fs::read(&app_path).unwrap_err().kind(), std::io::ErrorKind::NotFound);
        let failed_mark = fixture.engine.observations().len();
        let held = HeldApply::new(
            fixture,
            Err(EngineError::Render("owned initial core refusal".into())),
            Vec::new(),
        );
        assert_eq!(held.scenes().len(), 1);
        assert_eq!(held.scenes()[0].display.display_id, 1);
        held.assert_pending();
        let error = held.finish().unwrap_err();
        assert_error(error, BridgeErrorKind::Engine, &engine_boundary("owned initial core refusal"));
        fixture.repairs_idle();
        let failed_trace = observations_since(fixture, failed_mark);
        assert!(failed_trace.iter().any(|observation| {
            matches!(observation, EngineObservation::ReconcileCore { phase: OperationPhase::Rejected })
        }));
        assert!(failed_trace.iter().any(|observation| {
            matches!(observation, EngineObservation::Reconcile { phase: OperationPhase::Rejected, .. })
        }));
        assert!(audio_calls(&failed_trace).is_empty());
        let failed_options = options(fixture, A);
        assert!(failed_options.dirty);
        assert!(option_row(&failed_options, &key).enabled);
        assert_eq!(failed_options.volume, 0.4375);
        assert_eq!(fs::read(&app_path).unwrap_err().kind(), std::io::ErrorKind::NotFound);
        assert_eq!(fixture.wallpaper_bytes(A), saved_audio_bytes);
        let after_failure: WallpaperConfig =
            serde_json::from_slice(&fixture.wallpaper_bytes(A)).unwrap();
        assert_eq!(after_failure, saved_audio);
        assert_eq!(after_failure.audio.volume, 0.4375);
        assert!(fixture.engine.display_rows().iter().all(|row| row.handle.is_none()));

        let cancelled = fixture.cancel(A).unwrap();
        fixture.repairs_idle();
        assert!(!cancelled.wallpaper_options.dirty);
        assert!(!option_row(&cancelled.wallpaper_options, &key).enabled);
        assert_eq!(cancelled.wallpaper_options.volume, 0.4375);
        let after_cancel = options(fixture, A);
        assert!(!after_cancel.dirty);
        assert!(!option_row(&after_cancel, &key).enabled);
        assert_eq!(after_cancel.volume, 0.4375);
        assert_eq!(fixture.wallpaper_bytes(A), saved_audio_bytes);
    })
    .await;
}

#[tokio::test]
async fn another_wallpaper_factor_edit_does_not_touch_the_current_owner() {
    consumer_case(unassigned_app(), vec![empty_row(1, 67)], |run| {
        let fixture = run.fixture();
        let key = fixture.key(1);
        fixture.select(B);
        fixture.enable_draft(B, &key, true);
        let owner_handle = SceneHandle::new(78002);
        let requested = fixture.successful_apply(B, &[(1, owner_handle.raw())]);
        assert_eq!(requested.len(), 1);
        let active = fixture.snapshots();
        assert_eq!(active.app.active_wallpaper_ids, vec![B.to_owned()]);
        assert_eq!(
            active.monitor_information.rows.iter().find(|row| row.display_id == key).unwrap().wallpaper_id,
            B
        );
        fixture.select(A);
        let before = fixture.engine.live_scene_controls(owner_handle).unwrap().scaling_factor;
        let edit_mark = fixture.engine.observations().len();
        fixture
            .handle()
            .blocking_ask(SetScalingFactor {
                wallpaper_id: A.into(),
                display_id: key.clone(),
                factor: 1.625,
            })
            .unwrap();
        fixture.repairs_idle();
        let edited = options(fixture, A);
        assert!(edited.dirty);
        assert_eq!(option_row(&edited, &key).scaling_factor, 1.625);
        assert!(!option_row(&edited, &key).enabled);
        assert!(scale_calls(&observations_since(fixture, edit_mark)).iter().all(|observation| {
            !matches!(observation, EngineObservation::ScalingFactor { handle, .. } if *handle == owner_handle)
        }));
        assert_eq!(fixture.engine.display_rows()[0].handle, Some(owner_handle));
        assert_eq!(fixture.engine.live_scene_controls(owner_handle).unwrap().scaling_factor, before);
    })
    .await;
}

#[tokio::test]
async fn wallpaper_mode_and_rate_are_immediate_on_the_active_handle() {
    consumer_case(unassigned_app(), vec![empty_row(1, 83)], |run| {
        let fixture = run.fixture();
        let key = fixture.key(1);
        fixture.select(A);
        fixture.enable_draft(A, &key, true);
        let handle = SceneHandle::new(79001);
        fixture.successful_apply(A, &[(1, handle.raw())]);
        let reconcile_count = started_reconciles(&fixture.engine);
        let mark = fixture.engine.observations().len();
        fixture
            .handle()
            .blocking_ask(SetScalingMode {
                wallpaper_id: A.into(),
                display_id: key.clone(),
                mode: BridgeScalingMode::Match,
            })
            .unwrap();
        fixture
            .handle()
            .blocking_ask(SetTargetFps {
                wallpaper_id: A.into(),
                display_id: key.clone(),
                fps: 29,
            })
            .unwrap();
        fixture.repairs_idle();
        let controls: Vec<_> = observations_since(fixture, mark)
            .into_iter()
            .filter(|observation| {
                matches!(observation, EngineObservation::ScalingMode { .. } | EngineObservation::Fps { .. })
            })
            .collect();
        assert_eq!(controls, vec![
            EngineObservation::ScalingMode { handle, mode: ScalingMode::Fit, phase: OperationPhase::Started },
            EngineObservation::ScalingMode { handle, mode: ScalingMode::Fit, phase: OperationPhase::Applied },
            EngineObservation::Fps { handle, fps: 29, phase: OperationPhase::Started },
            EngineObservation::Fps { handle, fps: 29, phase: OperationPhase::Applied },
        ]);
        assert_eq!(fixture.engine.live_scene_controls(handle).unwrap().scaling_mode, ScalingMode::Fit);
        let immediate = options(fixture, A);
        assert!(!immediate.dirty);
        assert!(option_row(&immediate, &key).dirty);
        assert!(option_row(&immediate, &key).can_restore_defaults);
        assert_eq!(option_row(&immediate, &key).scaling_mode, BridgeScalingMode::Match);
        assert_eq!(option_row(&immediate, &key).target_fps, 29);
        let applied = fixture.start_apply(A, true).finish(&fixture.engine, &[handle]).unwrap();
        fixture.repairs_idle();
        assert_eq!(started_reconciles(&fixture.engine), reconcile_count);
        assert_eq!(fixture.engine.display_rows()[0].handle, Some(handle));
        assert!(!applied.wallpaper_options.dirty);
        assert!(option_row(&applied.wallpaper_options, &key).dirty);
        assert!(option_row(&applied.wallpaper_options, &key).can_restore_defaults);
        assert_eq!(option_row(&applied.wallpaper_options, &key).scaling_mode, BridgeScalingMode::Match);
        assert_eq!(option_row(&applied.wallpaper_options, &key).target_fps, 29);
    })
    .await;
}

fn wait_for_live_handle(fixture: &ConsumerFixture, handle: SceneHandle) {
    let deadline = Instant::now() + DEADLINE;
    while !fixture.engine.display_rows().iter().any(|row| row.handle == Some(handle)) {
        assert!(Instant::now() < deadline, "controlled core did not publish its actual result handle");
        thread::sleep(QUANTUM);
    }
}

// Compare all handles in each relevant control stream. This catches accidental
// obsolete-handle delivery without imposing an order on unrelated async IO.
fn assert_audio_batch(
    observations: &[EngineObservation],
    handle: SceneHandle,
    volume: f32,
    muted: bool,
    response: bool,
    capture: bool,
) {
    let volume_calls: Vec<_> = observations.iter()
        .filter(|observation| matches!(observation, EngineObservation::Volume { .. }))
        .cloned().collect();
    let muted_calls: Vec<_> = observations.iter()
        .filter(|observation| matches!(observation, EngineObservation::Muted { .. }))
        .cloned().collect();
    let activation_calls: Vec<_> = observations.iter()
        .filter(|observation| matches!(observation,
            EngineObservation::Capture { .. } | EngineObservation::AudioResponse { .. }))
        .cloned().collect();
    assert_eq!(volume_calls, vec![
        EngineObservation::Volume { handle, volume: volume.try_into().unwrap(), phase: OperationPhase::Started },
        EngineObservation::Volume { handle, volume: volume.try_into().unwrap(), phase: OperationPhase::Applied },
    ]);
    assert_eq!(muted_calls, vec![
        EngineObservation::Muted { handle, muted, phase: OperationPhase::Started },
        EngineObservation::Muted { handle, muted, phase: OperationPhase::Applied },
    ]);
    assert_eq!(activation_calls, vec![
        EngineObservation::Capture { handle, enabled: capture, phase: OperationPhase::Started },
        EngineObservation::Capture { handle, enabled: capture, phase: OperationPhase::Applied },
        EngineObservation::AudioResponse { handle, enabled: response, phase: OperationPhase::Started },
        EngineObservation::AudioResponse { handle, enabled: response, phase: OperationPhase::Applied },
    ]);
}

#[tokio::test]
async fn saved_audio_initializes_once_and_immediate_controls_follow_replacement() {
    consumer_case(unassigned_app(), vec![empty_row(1, 71)], |run| {
        let fixture = run.fixture();
        let key = fixture.key(1);
        fixture.select(A);
        fixture.handle().blocking_ask(SetVolume {
            wallpaper_id: A.into(), volume: 0.375,
        }).unwrap();
        fixture.handle().blocking_ask(SetMuted {
            wallpaper_id: A.into(), muted: true,
        }).unwrap();
        let before_startup = options(fixture, A);
        assert!(!before_startup.dirty);
        assert!(before_startup.audio_response_enabled);
        assert_eq!(before_startup.volume, 0.375);
        assert!(before_startup.muted);
        let saved: WallpaperConfig = serde_json::from_slice(&fixture.wallpaper_bytes(A)).unwrap();
        assert_eq!(saved.audio.volume, 0.375);
        assert!(saved.audio.muted);
        assert!(saved.audio.response_enabled);
        fixture.enable_draft(A, &key, true);

        let first = SceneHandle::new(82001);
        let startup_mark = fixture.engine.observations().len();
        let mut startup = HeldApply::new(fixture, Ok(vec![result(1, first.raw())]), vec![first]);
        assert_eq!(startup.scenes().len(), 1);
        assert_eq!(f32::from(startup.scenes()[0].audio_volume), 0.375);
        assert!(startup.scenes()[0].audio_muted);
        assert!(startup.scenes()[0].audio_response_enabled);
        startup.release();
        wait_for_live_handle(fixture, first);
        fixture.engine.require_audio(first, true);
        startup.finish().unwrap();
        fixture.repairs_idle();
        assert_audio_batch(&observations_since(fixture, startup_mark), first, 0.375, true, true, true);
        let initial_controls = fixture.engine.live_scene_controls(first).unwrap();
        assert_eq!(f32::from(initial_controls.audio_volume), 0.375);
        assert!(initial_controls.audio_muted);
        assert!(initial_controls.audio_response_enabled);
        assert!(initial_controls.audio_capture_enabled);
        assert_eq!(fixture.engine.audio_capture_state(first), Some(true));

        let original_audio_reconciles = started_reconciles(&fixture.engine);
        let edit_mark = fixture.engine.observations().len();
        fixture.handle().blocking_ask(SetVolume {
            wallpaper_id: A.into(), volume: 0.6875,
        }).unwrap();
        fixture.handle().blocking_ask(SetMuted {
            wallpaper_id: A.into(), muted: false,
        }).unwrap();
        fixture.handle().blocking_ask(SetAudioResponseEnabled {
            wallpaper_id: A.into(), enabled: false,
        }).unwrap();
        fixture.repairs_idle();
        assert_eq!(started_reconciles(&fixture.engine), original_audio_reconciles);
        assert_audio_batch(&observations_since(fixture, edit_mark), first, 0.6875, false, false, false);
        let edited_controls = fixture.engine.live_scene_controls(first).unwrap();
        assert_eq!(f32::from(edited_controls.audio_volume), 0.6875);
        assert!(!edited_controls.audio_muted);
        assert!(!edited_controls.audio_response_enabled);
        assert!(!edited_controls.audio_capture_enabled);
        assert_eq!(fixture.engine.audio_capture_state(first), Some(false));
        let immediate = options(fixture, A);
        assert!(!immediate.dirty);
        assert_eq!(immediate.volume, 0.6875);
        assert!(!immediate.muted);
        assert!(!immediate.audio_response_enabled);

        // A real property edit requires a subsequent engine construction. The
        // replacement is supplied by that actual successful reconcile result.
        fixture.edit(A, 0.8125);
        assert!(options(fixture, A).dirty);
        let replacement = SceneHandle::new(82002);
        let replacement_mark = fixture.engine.observations().len();
        let before_replacement = started_reconciles(&fixture.engine);
        let mut replacing = HeldApply::new(
            fixture, Ok(vec![result(1, replacement.raw())]), vec![replacement],
        );
        assert_eq!(replacing.scenes().len(), 1);
        assert_eq!(f32::from(replacing.scenes()[0].audio_volume), 0.6875);
        assert!(!replacing.scenes()[0].audio_muted);
        assert!(!replacing.scenes()[0].audio_response_enabled);
        replacing.release();
        wait_for_live_handle(fixture, replacement);
        fixture.engine.require_audio(replacement, true);
        replacing.finish().unwrap();
        fixture.repairs_idle();
        assert_eq!(started_reconciles(&fixture.engine), before_replacement + 1);
        assert_eq!(fixture.engine.display_rows()[0].handle, Some(replacement));
        assert!(fixture.engine.live_scene_controls(first).is_none());
        assert_audio_batch(
            &observations_since(fixture, replacement_mark), replacement, 0.6875, false, false, false,
        );

        let replacement_audio_reconciles = started_reconciles(&fixture.engine);
        let replacement_edit_mark = fixture.engine.observations().len();
        fixture.handle().blocking_ask(SetVolume {
            wallpaper_id: A.into(), volume: 0.5625,
        }).unwrap();
        fixture.handle().blocking_ask(SetMuted {
            wallpaper_id: A.into(), muted: true,
        }).unwrap();
        fixture.handle().blocking_ask(SetAudioResponseEnabled {
            wallpaper_id: A.into(), enabled: true,
        }).unwrap();
        fixture.repairs_idle();
        assert_eq!(started_reconciles(&fixture.engine), replacement_audio_reconciles);
        assert_audio_batch(
            &observations_since(fixture, replacement_edit_mark), replacement, 0.5625, true, true, true,
        );
        let replacement_controls = fixture.engine.live_scene_controls(replacement).unwrap();
        assert_eq!(f32::from(replacement_controls.audio_volume), 0.5625);
        assert!(replacement_controls.audio_muted);
        assert!(replacement_controls.audio_response_enabled);
        assert!(replacement_controls.audio_capture_enabled);
        assert_eq!(fixture.engine.audio_capture_state(replacement), Some(true));
        let clean = options(fixture, A);
        assert!(!clean.dirty);
        assert!(!option_row(&clean, &key).dirty);
        assert_eq!(clean.volume, 0.5625);
        assert!(clean.muted);
        assert!(clean.audio_response_enabled);

        let reconcile_count = started_reconciles(&fixture.engine);
        let clean_apply_mark = fixture.engine.observations().len();
        let applied = fixture.start_apply(A, true).finish(&fixture.engine, &[replacement]).unwrap();
        fixture.repairs_idle();
        assert_eq!(started_reconciles(&fixture.engine), reconcile_count);
        assert_eq!(fixture.engine.display_rows()[0].handle, Some(replacement));
        assert!(!applied.wallpaper_options.dirty);
        assert_eq!(applied.wallpaper_options.volume, 0.5625);
        assert!(applied.wallpaper_options.muted);
        assert!(applied.wallpaper_options.audio_response_enabled);
        assert!(audio_calls(&observations_since(fixture, clean_apply_mark)).is_empty());
    })
    .await;
}

#[tokio::test]
async fn one_blocked_apply_keeps_options_responsive_and_cannot_restore_old_selection_or_playback() {
    let mut app = unassigned_app();
    app.quality.render_scale = 0.5;
    consumer_case(app, vec![empty_row(1, 53)], |run| {
        let fixture = run.fixture();
        let key = fixture.key(1);
        fixture.select(A);
        assert_eq!(fixture.snapshots().settings.render_scale, 0.5);
        fixture.enable_draft(A, &key, true);
        let handle = SceneHandle::new(83001);
        let mut terminal = ParkedApplyCompletion::new(fixture, handle);
        let mut held = HeldApply::new(fixture, Ok(vec![result(1, handle.raw())]), vec![handle]);
        assert_eq!(held.scenes().len(), 1);
        assert!(!held.scenes()[0].paused);
        held.assert_pending();
        let while_blocked = options(fixture, A);
        assert!(while_blocked.dirty);
        assert!(option_row(&while_blocked, &key).enabled);

        fixture.select(B);
        held.assert_pending();
        assert_eq!(fixture.snapshots().app.selected_wallpaper_id.as_deref(), Some(B));

        // Selection and options were responsive during core exclusion. Pause
        // also mutates audio demand, so exercise it after this SAME Apply has
        // finished core/prune/readiness/audio and parked its terminal setter.
        held.release();
        terminal.wait_for_entry(fixture, handle);
        held.assert_pending();
        assert!(fixture.engine.observations().iter().any(|observation| {
            matches!(observation, EngineObservation::RenderScale {
                handle: actual, scale, phase: OperationPhase::Applied,
            } if *actual == handle && *scale == 0.5)
        }));
        fixture.handle().blocking_ask(SetGlobalPlayback {
            playback_state: BridgePlaybackState::Paused,
        }).unwrap();
        held.assert_pending();
        let newer = fixture.snapshots();
        assert_eq!(newer.app.selected_wallpaper_id.as_deref(), Some(B));
        assert_eq!(newer.app.playback_state, BridgePlaybackState::Paused);
        let still_pending = options(fixture, A);
        assert!(still_pending.dirty);
        assert!(option_row(&still_pending, &key).enabled);

        terminal.release();
        let completed = held.finish().unwrap();
        fixture.repairs_idle();
        assert_eq!(completed.app.selected_wallpaper_id.as_deref(), Some(B));
        assert_eq!(completed.app.playback_state, BridgePlaybackState::Paused);
        let settled = fixture.snapshots();
        assert_eq!(settled.app.selected_wallpaper_id.as_deref(), Some(B));
        assert_eq!(settled.app.playback_state, BridgePlaybackState::Paused);
        assert!(settled.library.wallpapers.iter().find(|entry| entry.id == B).unwrap().selected);
        assert!(!settled.library.wallpapers.iter().find(|entry| entry.id == A).unwrap().selected);
    })
    .await;
}