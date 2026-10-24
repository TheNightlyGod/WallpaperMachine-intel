//! Real settings consumers, mounted beneath the independent operation contract suite.
use super::*;
use crate::display::DisplayLabelExt;
use std::cell::RefCell;
use std::panic::{AssertUnwindSafe, catch_unwind, resume_unwind};

// Scenario code runs off the external executor. Each helper owns a cancelable
// async ask using its existing runtime handle, never a blocking_ask. Unwinding
// the scenario drops gate senders first; cleanup cancels every ask wait before
// joining any helper. Canceling the wait is NOT completion of actor work.
struct ConsumerWorker {
    cancel: Option<tokio::sync::oneshot::Sender<()>>,
    thread: thread::JoinHandle<()>,
}
struct ConsumerRequests {
    actor: BridgeActorHandle<ArcEngineFacade>,
    runtime: tokio::runtime::Handle,
    workers: RefCell<Vec<ConsumerWorker>>,
}
impl ConsumerRequests {
    fn new(bridge: &WallpaperBridge, runtime: tokio::runtime::Handle) -> Self {
        Self { actor: actor(bridge).clone(), runtime, workers: RefCell::new(Vec::new()) }
    }
    fn start<M, T>(&self, message: M) -> mpsc::Receiver<Result<T, BridgeError>>
    where
        BridgeActor<ArcEngineFacade>: Message<M>,
        <BridgeActor<ArcEngineFacade> as Message<M>>::Reply: Reply<Ok = T, Error = BridgeError>,
        M: Send + 'static,
        T: Send + 'static,
    {
        let actor = self.actor.clone();
        let runtime = self.runtime.clone();
        let (cancel, canceled) = tokio::sync::oneshot::channel();
        let (send, reply) = mpsc::sync_channel(1);
        let thread = thread::spawn(move || {
            let result = runtime.block_on(async move {
                tokio::select! {
                    biased;
                    _ = canceled => None,
                    result = actor.ask(message) => Some(result),
                }
            });
            if let Some(result) = result { let _ = send.send(result); }
        });
        self.workers.borrow_mut().push(ConsumerWorker { cancel: Some(cancel), thread });
        reply
    }
    fn wait<T>(&self, reply: mpsc::Receiver<Result<T, BridgeError>>) -> Result<T, BridgeError> {
        match reply.recv_timeout(DEADLINE) {
            Ok(result) => result,
            Err(mpsc::RecvTimeoutError::Timeout) => panic!("settings consumer reply deadline"),
            Err(mpsc::RecvTimeoutError::Disconnected) => panic!("settings request helper lost its reply"),
        }
    }
    fn ask<M, T>(&self, message: M) -> Result<T, BridgeError>
    where
        BridgeActor<ArcEngineFacade>: Message<M>,
        <BridgeActor<ArcEngineFacade> as Message<M>>::Reply: Reply<Ok = T, Error = BridgeError>,
        M: Send + 'static,
        T: Send + 'static,
    {
        self.wait(self.start(message))
    }
    fn cancel_and_join(self) -> bool {
        let Self { actor, runtime, workers } = self;
        let mut workers = workers.into_inner();
        for worker in &mut workers {
            if let Some(cancel) = worker.cancel.take() { let _ = cancel.send(()); }
        }
        let mut worker_failed = false;
        for worker in workers { worker_failed |= worker.thread.join().is_err(); }
        drop(actor);
        drop(runtime);
        worker_failed
    }
}

type ConsumerPanic = Box<dyn std::any::Any + Send + 'static>;

async fn owned_bridge_call<T: Send + 'static>(
    bridge: WallpaperBridge,
    body: impl FnOnce(&ConsumerRequests) -> T + Send + 'static,
) -> Result<T, ConsumerPanic> {
    let runtime = tokio::runtime::Handle::current();
    let joined = tokio::task::spawn_blocking(move || {
        let requests = ConsumerRequests::new(&bridge, runtime);
        let outcome = catch_unwind(AssertUnwindSafe(|| body(&requests)));
        let worker_failed = requests.cancel_and_join();
        (bridge, outcome, worker_failed)
    }).await;
    let (bridge, outcome, worker_failed) = match joined {
        Ok(value) => value,
        Err(error) => return Err(Box::new(format!("owned bridge request task failed: {error}"))),
    };
    let drained = crate::api::mounted_lifecycle::shutdown_and_drain(bridge).await;
    match outcome {
        Err(payload) => Err(payload),
        Ok(_) if worker_failed => Err(Box::new("settings request helper panicked".to_owned())),
        Ok(value) => drained.map(|()| value).map_err(|error| Box::new(error) as ConsumerPanic),
    }
}

struct ConsumerRun<'a> {
    fixture: &'a Fixture,
    requests: ConsumerRequests,
}
impl ConsumerRun<'_> {
    fn start<M, T>(&self, message: M) -> mpsc::Receiver<Result<T, BridgeError>>
    where
        BridgeActor<ArcEngineFacade>: Message<M>,
        <BridgeActor<ArcEngineFacade> as Message<M>>::Reply: Reply<Ok = T, Error = BridgeError>,
        M: Send + 'static,
        T: Send + 'static,
    {
        self.requests.start(message)
    }
    fn finish<T>(&self, reply: mpsc::Receiver<Result<T, BridgeError>>, handles: &[u64]) -> Result<T, BridgeError> {
        let end = Instant::now() + DEADLINE;
        loop {
            for raw in handles {
                let handle = SceneHandle::new(*raw);
                if self.fixture.engine.display_rows().iter().any(|r| r.handle == Some(handle)) {
                    self.fixture.engine.emit_first_frame(handle);
                }
            }
            match reply.recv_timeout(QUANTUM) {
                Ok(result) => return result,
                Err(mpsc::RecvTimeoutError::Timeout) => assert!(Instant::now() < end, "settings consumer reply deadline"),
                Err(mpsc::RecvTimeoutError::Disconnected) => panic!("settings request helper lost its reply"),
            }
        }
    }
    fn ask<M, T>(&self, message: M) -> Result<T, BridgeError>
    where
        BridgeActor<ArcEngineFacade>: Message<M>,
        <BridgeActor<ArcEngineFacade> as Message<M>>::Reply: Reply<Ok = T, Error = BridgeError>,
        M: Send + 'static,
        T: Send + 'static,
    {
        self.finish(self.start(message), &[])
    }
    fn snapshots(&self) -> BridgeSnapshotBundle {
        self.ask(GetAllSnapshots).unwrap()
    }
    fn select(&self, id: &str) {
        self.ask(SelectWallpaper { id: id.into() }).unwrap();
    }
    fn edit(&self, id: &str, value: f64) {
        self.ask(EditProperty {
            wallpaper_id: id.into(), property_id: "gain".into(),
            value: BridgePropertyValue::Number { value },
        }).unwrap();
    }
    fn enable_draft(&self, id: &str, display: &str, enabled: bool) {
        self.ask(SetDisplayConfigEnabled {
            wallpaper_id: id.into(), display_id: display.into(), enabled,
        }).unwrap();
    }
    fn repairs_idle(&self) {
        let end = Instant::now() + DEADLINE;
        while !self.ask(RepairsIdle).unwrap() {
            assert!(Instant::now() < end, "receiving-side repair settlement exceeded deadline");
            thread::sleep(QUANTUM);
        }
        self.snapshots();
    }
    fn reconcile<M, T>(&self, message: M, pairs: &[(u32, u64)]) -> (T, Vec<SceneDesc>)
    where
        BridgeActor<ArcEngineFacade>: Message<M>,
        <BridgeActor<ArcEngineFacade> as Message<M>>::Reply: Reply<Ok = T, Error = BridgeError>,
        M: Send + 'static,
        T: Send + 'static,
    {
        let gate = self.fixture.engine.hold_next_reconcile(Ok(pairs.iter().map(|(d, h)| result(*d, *h)).collect()));
        let reply = self.start(message);
        let receipt = entered(gate);
        let scenes = receipt.scenes.clone();
        receipt.release();
        let value = self.finish(reply, &pairs.iter().map(|(_, h)| *h).collect::<Vec<_>>()).unwrap();
        self.repairs_idle();
        (value, scenes)
    }
    fn apply(&self, id: &str, pairs: &[(u32, u64)]) -> (BridgeWallpaperMutationBundle, Vec<SceneDesc>) {
        self.reconcile(ApplyWallpaperOptions { wallpaper_id: id.into(), user_initiated: true }, pairs)
    }
    fn settle_repair(&self, gate: ReconcileControl, handles: &[u64]) -> Vec<SceneDesc> {
        let receipt = entered(gate);
        let scenes = receipt.scenes.clone();
        receipt.release();
        let end = Instant::now() + DEADLINE;
        loop {
            for raw in handles {
                self.fixture.engine.emit_first_frame(SceneHandle::new(*raw));
            }
            if self.ask(RepairsIdle).unwrap() {
                break;
            }
            assert!(Instant::now() < end, "settings repair completion deadline");
            thread::sleep(QUANTUM);
        }
        self.snapshots();
        scenes
    }
}

async fn consumer_dispose(fixture: Fixture, preserve: bool) -> Result<(), BridgeError> {
    let Fixture { bridge, engine, store, paths, root, clock, prior_tickets } = fixture;
    // Helper waits have already been canceled and joined. Actual queued actor
    // work, callbacks and handoff still require this genuine lifecycle drain.
    let drained = crate::api::mounted_lifecycle::shutdown_and_drain(bridge).await;
    drop(prior_tickets);
    drop(engine);
    drop(store);
    drop(paths);
    drop(clock);
    if preserve || drained.is_err() { std::mem::forget(root); } else { drop(root); }
    drained
}

async fn consumer_stage(
    fixture: Fixture,
    body: impl FnOnce(&ConsumerRun<'_>) + Send + 'static,
) -> Fixture {
    let runtime = tokio::runtime::Handle::current();
    let (fixture, outcome, worker_failed) = tokio::task::spawn_blocking(move || {
        let run = ConsumerRun { fixture: &fixture, requests: ConsumerRequests::new(&fixture.bridge, runtime) };
        let outcome = catch_unwind(AssertUnwindSafe(|| body(&run)));
        // Every gate local to body has now been released or dropped by unwind.
        // Signal ALL helper waits before joining ANY: a timed-out read cannot
        // strand cleanup behind its own still-pending actor reply.
        let worker_failed = run.requests.cancel_and_join();
        (fixture, outcome, worker_failed)
    }).await.expect("owned settings scenario task panicked outside its assertion boundary");
    if outcome.is_ok() && !worker_failed { return fixture; }
    // The external executor was free throughout the blocking scenario and now
    // awaits real actor shutdown, not merely cancellation of response futures.
    let drained = consumer_dispose(fixture, true).await;
    if let Err(payload) = outcome { resume_unwind(payload); }
    drained.unwrap();
    panic!("settings request helper panicked");
}

async fn consumer_case(
    fixture: Fixture,
    body: impl FnOnce(&ConsumerRun<'_>) + Send + 'static,
) {
    let fixture = consumer_stage(fixture, body).await;
    consumer_dispose(fixture, false).await.unwrap();
}

async fn reopen_consumer(fixture: Fixture, rows: Vec<DisplaySnapshotEntry>, status: LaunchAtLoginStatus) -> Fixture {
    let Fixture { bridge, engine, store, paths, root, clock, prior_tickets } = fixture;
    let drained = crate::api::mounted_lifecycle::shutdown_and_drain(bridge).await;
    drop(engine);
    drop(prior_tickets);
    if let Err(error) = drained {
        std::mem::forget(root);
        panic!("drain before real store restart: {error}");
    }
    let engine = ControlledEngine::new(rows);
    // Deliberately no with_state: the genuine builder must consume the saved app.
    let built = BridgeBuilder::new(engine.clone())
        .with_config_store(store.clone())
        .with_paths(paths.clone())
        .with_launch_at_login(inert_login_controller(status))
        .with_mouse_polling_enabled(false)
        .with_power_watching_enabled(false)
        .build();
    let bridge = match built {
        Ok(bridge) => bridge,
        Err(error) => { std::mem::forget(root); panic!("real store restart: {error}"); }
    };
    Fixture { bridge, engine, store, paths, root, clock, prior_tickets: Vec::new() }
}

fn two_sources() -> AppConfig {
    let mut app = configured();
    app.monitors.push(assignment(connected(2), Some(B)));
    app
}
fn two_same_source() -> AppConfig {
    let mut app = configured();
    app.monitors.push(assignment(connected(2), Some(A)));
    app
}
fn mirrored_source(id: &str) -> AppConfig {
    let mut app = configured();
    app.monitors[0].wallpaper = Some(id.into());
    app.general.last_selected_wallpaper = Some(id.into());
    let mut mirror = assignment(connected(2), None);
    mirror.mode = "mirror".into();
    mirror.mirror_target = Some(SerializedSelector::Primary);
    app.monitors.push(mirror);
    app
}
fn options(c: &ConsumerRun<'_>, id: &str) -> BridgeWallpaperOptionsSnapshot {
    c.ask(GetWallpaperOptionsSnapshot { wallpaper_id: id.into() }).unwrap()
}
fn option_row(options: &BridgeWallpaperOptionsSnapshot, key: &str) -> BridgeDisplayConfigRow {
    options.display_configurations.iter().find(|r| r.display_id == key).unwrap().clone()
}
fn assert_display(settings: &BridgeSettingsSnapshot, key: &str, enabled: bool, mode: BridgeDisplayMode, target: Option<&str>) {
    let actual = row(settings, key);
    assert_eq!((actual.enabled, actual.mode, actual.selected_mirror_target.as_deref()), (enabled, mode, target));
}
fn assert_active(snapshot: &BridgeSnapshotBundle, expected: &[&str]) {
    let expected: BTreeSet<String> = expected.iter().map(|id| (*id).to_owned()).collect();
    assert_eq!(snapshot.app.active_wallpaper_ids.iter().cloned().collect::<BTreeSet<_>>(), expected);
    assert_eq!(snapshot.library.wallpapers.iter().filter(|r| r.active).map(|r| r.id.clone()).collect::<BTreeSet<_>>(), expected);
}
fn scene_on(scenes: &[SceneDesc], display: u32) -> &SceneDesc {
    assert_eq!(scenes.iter().filter(|s| s.display.display_id == display).count(), 1);
    scenes.iter().find(|s| s.display.display_id == display).unwrap()
}
fn assert_scene_displays(scenes: &[SceneDesc], displays: &[u32]) {
    let mut actual: Vec<_> = scenes.iter().map(|s| s.display.display_id).collect();
    actual.sort_unstable();
    let mut expected = displays.to_vec();
    expected.sort_unstable();
    assert_eq!(actual, expected);
}
fn assert_source(f: &Fixture, scene: &SceneDesc, id: &str) {
    let project = f.paths.project_json(id);
    f.root.check(&project);
    // The retained activation path contract is supplied by the parent; this
    // comparison pins the specific source, not equality of arbitrary scenes.
    assert_eq!(Path::new(&scene.scene_path), project.as_path());
}
fn live_source(f: &Fixture, display: u32) -> SceneTemplate {
    let rows = f.engine.display_rows();
    match &rows.iter().find(|r| r.desc.display_id == display).unwrap().assignment {
        Some(WallpaperAssignment::Direct(template)) => template.clone(),
        other => panic!("expected real direct scene at {display}: {other:?}"),
    }
}
fn pulse(options: &BridgeWallpaperOptionsSnapshot) -> (bool, bool) {
    let descriptor = options.properties.iter().find(|p| p.id == "pulse").unwrap();
    assert_eq!(descriptor.kind, BridgePropertyKind::Bool);
    match descriptor.value {
        BridgePropertyValue::Bool { value } => (value, descriptor.dirty),
        ref other => panic!("Boolean fixture lost its typed boundary: {other:?}"),
    }
}

#[tokio::test]
async fn settings_disable_rebases_boolean_draft_and_survives_real_store_restart() {
    let f = Fixture::new(two_same_source(), vec![empty_row(1, 60), empty_row(2, 75)]);
    // This case deliberately retains its root across two separately drained actors.
    let f = consumer_stage(f, |run| {
        let f = run.fixture;
        let _: (BridgeSnapshotBundle, _) = run.reconcile(Bootstrap, &[(1, 5101), (2, 5102)]);
        run.select(A);
        assert_eq!(pulse(&options(run, A)), (false, false));
        run.ask(SetVolume { wallpaper_id: A.into(), volume: 0.37 }).unwrap();
        run.ask(EditProperty { wallpaper_id: A.into(), property_id: "pulse".into(), value: BridgePropertyValue::Bool { value: true } }).unwrap();
        assert_eq!(pulse(&options(run, A)), (true, true));
        let key = f.key(2);
        let before_disable: DraftConfigObservation = run.ask(ReadDraftConfig { wallpaper_id: A.into() }).unwrap();
        assert!(before_disable.enabled.contains(&connected(2)));
        assert!(before_disable.pending_enabled.contains(&connected(2)));
        let (disabled, scenes): (BridgeDisplayMutationBundle, _) = run.reconcile(SetDisplayEnabled { display_id: key.clone(), enabled: false }, &[(1, 5111)]);
        assert_scene_displays(&scenes, &[1]);
        assert_source(&f, &scenes[0], A);
        assert_display(&disabled.settings, &key, false, BridgeDisplayMode::Standalone, None);
        let live = f.engine.display_rows();
        assert!(live[1].assignment.is_none());
        assert!(live[1].handle.is_none());
        assert!(!live[1].window_active);
        let pending = options(run, A);
        assert!(pending.dirty);
        assert_eq!(pulse(&pending), (true, true));
        assert_eq!(pending.volume, 0.37);
        assert!(!pending.display_configurations.iter().any(|row| row.display_id == key));
        let rebased: DraftConfigObservation = run.ask(ReadDraftConfig { wallpaper_id: A.into() }).unwrap();
        assert!(!rebased.enabled.contains(&connected(2)));
        assert!(!rebased.pending_enabled.contains(&connected(2)));
        assert_eq!(
            rebased.enabled.iter().map(SerializedSelector::id).collect::<BTreeSet<_>>(),
            rebased.pending_enabled.iter().map(SerializedSelector::id).collect::<BTreeSet<_>>(),
        );
        assert!(rebased.dirty);
        assert_eq!(rebased.pending.audio.volume, 0.37);
        let (applied, scenes) = run.apply(A, &[(1, 5121)]);
        assert_scene_displays(&scenes, &[1]);
        assert!(!applied.wallpaper_options.dirty);
        // Reset markers compare against authored defaults, not the saved draft.
        assert_eq!(pulse(&applied.wallpaper_options), (true, true));
        assert!(applied.wallpaper_options.properties.iter().find(|property| property.id == "pulse").unwrap().can_restore_defaults);
        assert_eq!(applied.wallpaper_options.volume, 0.37);
        assert_display(&applied.settings, &key, false, BridgeDisplayMode::Standalone, None);
        assert!(!applied.wallpaper_options.display_configurations.iter().any(|row| row.display_id == key));
        let saved = f.store.load_wallpaper(A).unwrap();
        assert_eq!(saved.property_overrides.get("pulse"), Some(&serde_json::json!(true)));
        assert_eq!(saved.audio.volume, 0.37);
        assert!(!f.store.load().unwrap().config.monitors.iter().find(|m| m.selector == connected(2)).unwrap().enabled);
    }).await;
    let restarted = reopen_consumer(f, vec![empty_row(1, 60), empty_row(2, 75)], LaunchAtLoginStatus::Unavailable).await;
    consumer_case(restarted, |c| {
        let f = c.fixture;
        let key = f.key(2);
        assert_display(&c.snapshots().settings, &key, false, BridgeDisplayMode::Standalone, None);
        let (_, scenes): (BridgeSnapshotBundle, _) = c.reconcile(Bootstrap, &[(1, 5131)]);
        assert_scene_displays(&scenes, &[1]);
        assert_source(f, &scenes[0], A);
        assert_display(&c.snapshots().settings, &key, false, BridgeDisplayMode::Standalone, None);
    }).await;
}

#[tokio::test]
async fn settings_refusals_preserve_whole_rows_and_protect_primary_role_not_numeric_alias() {
    consumer_case(Fixture::new(two_sources(), vec![empty_row(1, 60), empty_row(2, 60)]), |c| {
        let f = c.fixture;
        let _: (BridgeSnapshotBundle, _) = c.reconcile(Bootstrap, &[(1, 5201), (2, 5202)]);
        let key = f.key(2);
        let _: (BridgeDisplayMutationBundle, _) = c.reconcile(SetDisplayEnabled { display_id: key.clone(), enabled: false }, &[(1, 5203)]);
        let _: (BridgeDisplayMutationBundle, _) = c.reconcile(SetDisplayEnabled { display_id: key.clone(), enabled: true }, &[(1, 5204), (2, 5205)]);
        let initial = c.snapshots();
        assert_eq!(initial.settings.displays.len(), 2);
        assert_eq!(initial.settings.displays.iter().filter(|r| r.display_id == "primary").count(), 1);
        assert!(!initial.settings.displays.iter().any(|r| r.display_id == "1"));
        assert_eq!(key, connected(2).id());
        assert_ne!(key, "2");
        assert_display(&initial.settings, "primary", true, BridgeDisplayMode::Standalone, None);
        assert_display(&initial.settings, &key, true, BridgeDisplayMode::Standalone, None);
        let before = started_reconciles(&f.engine);
        let unknown = c.ask(SetDisplayEnabled { display_id: "unknown-physical-panel".into(), enabled: false }).unwrap_err();
        assert_eq!(unknown.kind(), BridgeErrorKind::InvalidInput);
        assert_display(&c.snapshots().settings, &key, true, BridgeDisplayMode::Standalone, None);
        let unknown_target = c.ask(SetMirrorTarget { display_id: key.clone(), target_display_id: "unknown-source-panel".into() }).unwrap_err();
        assert_eq!(unknown_target.kind(), BridgeErrorKind::InvalidInput);
        assert_display(&c.snapshots().settings, &key, true, BridgeDisplayMode::Standalone, None);
        let remembered: BTreeMap<String, BridgeDisplaySettingsRow> = c.ask(ReadRememberedRows).unwrap();
        let remembered = remembered.get(&key).unwrap();
        assert_eq!((remembered.enabled, remembered.mode, remembered.selected_mirror_target.as_deref()), (true, BridgeDisplayMode::Standalone, None));
        assert_eq!(started_reconciles(&f.engine), before);
        let (ignored, preserved): (BridgeDisplayMutationBundle, _) = c.reconcile(
            SetDisplayEnabled { display_id: "primary".into(), enabled: false },
            &[(1, 5206), (2, 5207)],
        );
        assert_scene_displays(&preserved, &[1, 2]);
        assert_source(f, scene_on(&preserved, 1), A);
        assert_source(f, scene_on(&preserved, 2), B);
        assert_display(&ignored.settings, "primary", true, BridgeDisplayMode::Standalone, None);
        let before_forbidden = started_reconciles(&f.engine);
        let forbidden = c.ask(SetDisplayMode { display_id: "primary".into(), mode: BridgeDisplayMode::Mirror }).unwrap_err();
        assert_eq!(forbidden.kind(), BridgeErrorKind::InvalidInput);
        assert_display(&c.snapshots().settings, "primary", true, BridgeDisplayMode::Standalone, None);
        assert_eq!(started_reconciles(&f.engine), before_forbidden);
    }).await;
}

#[tokio::test]
async fn settings_mirror_requires_a_real_alternate_and_publishes_target_with_source() {
    let remembered = remembered_rows(&[("2", "Detached remembered panel")]);
    consumer_case(Fixture::with_initial(two_sources(), Vec::new(), remembered, &[]), |c| {
        let f = c.fixture;
        let lone = c.snapshots();
        assert_eq!(lone.settings.displays.len(), 1);
        assert_display(&lone.settings, "2", true, BridgeDisplayMode::Standalone, None);
        let before = started_reconciles(&f.engine);
        let error = c.ask(SetDisplayMode { display_id: "2".into(), mode: BridgeDisplayMode::Mirror }).unwrap_err();
        assert_eq!(error.kind(), BridgeErrorKind::InvalidInput);
        assert_display(&c.snapshots().settings, "2", true, BridgeDisplayMode::Standalone, None);
        assert_eq!(started_reconciles(&f.engine), before);
        f.engine.replace_display_rows(vec![empty_row(1, 60), empty_row(2, 120)]);
        let (_, discovered): (BridgeSnapshotBundle, _) = c.reconcile(RefreshDisplays, &[(1, 5311), (2, 5312)]);
        assert_scene_displays(&discovered, &[1, 2]);
        let key = f.key(2);
        assert_display(&c.snapshots().settings, &key, true, BridgeDisplayMode::Standalone, None);
        let (mirrored, scenes): (BridgeDisplayMutationBundle, _) = c.reconcile(SetDisplayMode { display_id: key.clone(), mode: BridgeDisplayMode::Mirror }, &[(1, 5321), (2, 5322)]);
        assert_display(&mirrored.settings, &key, true, BridgeDisplayMode::Mirror, Some("primary"));
        assert_source(f, scene_on(&scenes, 2), A);
        assert_eq!(scene_on(&scenes, 2).scene_path, scene_on(&scenes, 1).scene_path);
        let primary_info = mirrored.monitor_information.rows.iter().find(|r| r.display_id == "primary").unwrap();
        let mirror_info = mirrored.monitor_information.rows.iter().find(|r| r.display_id == key).unwrap();
        assert_eq!(mirrored.monitor_information.rows.len(), 2);
        assert_eq!(primary_info.wallpaper_id, A);
        assert_eq!(primary_info.mirror_target_display_id, None);
        assert_eq!(primary_info.mirror_target_title, None);
        assert_eq!(mirror_info.wallpaper_id, A);
        assert_eq!(mirror_info.wallpaper_title, primary_info.wallpaper_title);
        assert_eq!(mirror_info.mirror_target_display_id.as_deref(), Some("primary"));
        let live = f.engine.display_rows();
        let target_title = live[0].title_with_role(true);
        assert_eq!(mirror_info.mirror_target_title.as_deref(), Some(target_title.as_str()));
        let primary_suffix = format!("({} - Primary - {})", live[0].desc.display_id, primary_info.wallpaper_id);
        let mirror_suffix = format!("({} - Secondary - {})", live[1].desc.display_id, mirror_info.wallpaper_id);
        assert_eq!(primary_info.title, live[0].title_with_suffix(&primary_suffix));
        assert_eq!(mirror_info.title, live[1].title_with_suffix(&mirror_suffix));
        let source_entry = mirrored.library.wallpapers.iter().find(|entry| entry.id == primary_info.wallpaper_id).unwrap();
        assert_eq!(primary_info.wallpaper_title, source_entry.title);
    }).await;
}

#[tokio::test]
async fn settings_numeric_connected_address_consumes_real_saved_stale_record() {
    let mut app = two_sources();
    app.monitors.push(assignment(selector(92), Some(A)));
    let f = Fixture::new(app, vec![empty_row(1, 60), empty_row(2, 60)]);
    let f = reopen_consumer(f, vec![empty_row(1, 60), empty_row(2, 60)], LaunchAtLoginStatus::Unavailable).await;
    consumer_case(f, |c| {
        let f = c.fixture;
        let loaded: AppConfig = c.ask(ReadAppConfig).unwrap();
        let stale = loaded.monitors.iter().find(|m| m.selector == selector(92)).unwrap().clone();
        assert!(stale.enabled);
        assert_eq!(stale.wallpaper.as_deref(), Some(A));
        assert!(!f.engine.display_rows().iter().any(|r| r.desc.display_id == 92));
        assert!(loaded.monitors.iter().any(|m| m.selector == connected(2) && m.wallpaper.as_deref() == Some(B)));
        let (_, startup): (BridgeSnapshotBundle, _) = c.reconcile(Bootstrap, &[(1, 5391), (2, 5392)]);
        assert_source(f, scene_on(&startup, 1), A);
        assert_source(f, scene_on(&startup, 2), B);
        let (disabled, scenes): (BridgeDisplayMutationBundle, _) = c.reconcile(SetDisplayEnabled { display_id: "2".into(), enabled: false }, &[(1, 5401)]);
        assert_display(&disabled.settings, &connected(2).id(), false, BridgeDisplayMode::Standalone, None);
        assert_scene_displays(&scenes, &[1]);
        let committed: AppConfig = c.ask(ReadAppConfig).unwrap();
        assert!(!committed.monitors.iter().find(|m| m.selector == connected(2)).unwrap().enabled);
        assert_eq!(committed.monitors.iter().find(|m| m.selector == selector(92)), Some(&stale));
        let persisted = f.store.load().unwrap().config;
        assert_eq!(persisted.monitors.iter().find(|m| m.selector == selector(92)), Some(&stale));
    }).await;
}

#[tokio::test]
async fn settings_enable_unassigned_secondary_does_not_invent_or_replace_a_wallpaper() {
    let mut app = configured();
    let mut secondary = assignment(connected(2), None);
    secondary.enabled = false;
    app.monitors.push(secondary);
    consumer_case(Fixture::new(app, vec![empty_row(1, 60), empty_row(2, 60)]), |c| {
        let f = c.fixture;
        let (_, initial): (BridgeSnapshotBundle, _) = c.reconcile(Bootstrap, &[(1, 5501)]);
        let original = live_source(f, 1);
        let (enabled, scenes): (BridgeDisplayMutationBundle, _) = c.reconcile(SetDisplayEnabled { display_id: f.key(2), enabled: true }, &[(1, 5501)]);
        assert_display(&enabled.settings, &f.key(2), true, BridgeDisplayMode::Standalone, None);
        assert_eq!(scenes, initial);
        assert_eq!(live_source(f, 1), original);
        assert!(f.engine.display_rows().iter().find(|r| r.desc.display_id == 2).unwrap().assignment.is_none());
        assert_active(&c.snapshots(), &[A]);
        assert_eq!(enabled.monitor_information.rows.len(), 1);
        assert_eq!(enabled.monitor_information.rows[0].wallpaper_id, A);
    }).await;
}

#[tokio::test]
async fn settings_target_selection_bootstrap_and_apply_each_restore_the_configured_source() {
    // Deliberately use B as source; A remains a real but inactive library entry.
    let mut app = configured();
    app.monitors[0].wallpaper = Some(B.into());
    app.general.last_selected_wallpaper = Some(B.into());
    let mut inactive = assignment(connected(2), None);
    inactive.enabled = false;
    app.monitors.push(inactive);
    let f = Fixture::new(app, vec![empty_row(1, 60), empty_row(2, 144)]);
    let f = consumer_stage(f, |run| {
        let f = run.fixture;
        let _: (BridgeSnapshotBundle, _) = run.reconcile(Bootstrap, &[(1, 5601)]);
        assert!(!f.engine.display_rows()[1].window_active);
        let (selected, scenes): (BridgeDisplayMutationBundle, _) = run.reconcile(SetMirrorTarget { display_id: f.key(2), target_display_id: "primary".into() }, &[(1, 5611), (2, 5612)]);
        assert_display(&selected.settings, &f.key(2), true, BridgeDisplayMode::Mirror, Some("primary"));
        assert_scene_displays(&scenes, &[1, 2]);
        assert_source(&f, scene_on(&scenes, 2), B);
        assert!(f.engine.display_rows()[1].window_active);
        assert_eq!(f.engine.display_rows()[1].handle, Some(SceneHandle::new(5612)));
    }).await;
    let f = reopen_consumer(f, vec![empty_row(1, 60), empty_row(2, 144)], LaunchAtLoginStatus::Unavailable).await;
    consumer_case(f, |c| {
        let f = c.fixture;
        assert!(!f.engine.display_rows()[1].window_active);
        let (_, startup): (BridgeSnapshotBundle, _) = c.reconcile(Bootstrap, &[(1, 5621), (2, 5622)]);
        assert_scene_displays(&startup, &[1, 2]);
        assert_source(f, scene_on(&startup, 1), B);
        assert_source(f, scene_on(&startup, 2), B);
        assert!(f.engine.display_rows()[1].window_active);
        let mut rows = f.engine.display_rows();
        rows[1].window_active = false;
        rows[1].handle = None;
        rows[1].assignment = None;
        f.engine.replace_display_rows(rows);
        c.select(B);
        c.edit(B, 0.61);
        let (_, applied) = c.apply(B, &[(1, 5631), (2, 5632)]);
        assert_source(f, scene_on(&applied, 2), B);
        assert!(f.engine.display_rows()[1].window_active);
        assert_eq!(f.engine.display_rows()[1].handle, Some(SceneHandle::new(5632)));
        assert_display(&c.snapshots().settings, &f.key(2), true, BridgeDisplayMode::Mirror, Some("primary"));
    }).await;
}

#[tokio::test]
async fn settings_reconcile_selected_owners_override_saved_aliases_and_eject_only_one_source() {
    let app = two_sources();
    consumer_case(Fixture::new(app, vec![empty_row(1, 60), empty_row(2, 60)]), |c| {
        let f = c.fixture;
        // Two genuinely distinct owners, not two aliases of one wallpaper.
        let (_, initial): (BridgeSnapshotBundle, _) = c.reconcile(Bootstrap, &[(1, 5701), (2, 5702)]);
        assert_source(f, scene_on(&initial, 1), A);
        assert_source(f, scene_on(&initial, 2), B);
        assert_active(&c.snapshots(), &[A, B]);
        let (ejected, remaining): (BridgeDisplayMutationBundle, _) = c.reconcile(EjectWallpaperFromDisplay { display_id: "primary".into(), wallpaper_id: A.into() }, &[(2, 5712)]);
        assert_scene_displays(&remaining, &[2]);
        assert_source(f, &remaining[0], B);
        assert_display(&ejected.settings, "primary", true, BridgeDisplayMode::Standalone, None);
        let persisted = f.store.load().unwrap().config;
        let primary = persisted.monitors.iter().find(|monitor| monitor.selector == SerializedSelector::Primary).unwrap();
        let secondary = persisted.monitors.iter().find(|monitor| monitor.selector == connected(2)).unwrap();
        assert_eq!(
            (primary.enabled, primary.wallpaper.as_deref(), secondary.enabled, secondary.mode.as_str(), secondary.wallpaper.as_deref()),
            (true, None, true, "independent", Some(B)),
        );
        assert_eq!(ejected.app.active_wallpaper_ids, vec![B.to_owned()]);
        assert_eq!(ejected.monitor_information.rows.len(), 1);
        assert_eq!(ejected.monitor_information.rows[0].display_id, f.key(2));
        assert_eq!(ejected.monitor_information.rows[0].wallpaper_id, B);
        assert!(f.engine.display_rows()[0].assignment.is_none());
        assert_active(&c.snapshots(), &[B]);
    }).await;
    let mut app = configured();
    app.monitors.push(assignment(connected(1), Some(B)));
    app.monitors.push(assignment(connected(2), Some(A)));
    consumer_case(Fixture::new(app, vec![empty_row(1, 60), empty_row(2, 60)]), |c| {
        let f = c.fixture;
        let (_, scenes): (BridgeSnapshotBundle, _) = c.reconcile(Bootstrap, &[(1, 5721), (2, 5722)]);
        let committed: AppConfig = c.ask(ReadAppConfig).unwrap();
        assert!(committed.monitors.iter().any(|m| m.selector == connected(1) && m.wallpaper.as_deref() == Some(B)));
        assert_source(f, scene_on(&scenes, 1), A);
        assert_source(f, scene_on(&scenes, 2), A);
        let snapshot = c.snapshots();
        assert_active(&snapshot, &[A]);
        assert!(snapshot.library.wallpapers.iter().any(|r| r.id == B && !r.active));
        assert_eq!(snapshot.monitor_information.rows.iter().map(|r| r.wallpaper_id.as_str()).collect::<BTreeSet<_>>(), BTreeSet::from([A]));
    }).await;
}

#[tokio::test]
async fn settings_apply_saves_physical_primary_fallback_for_a_later_role_handover() {
    let mut app = configured();
    app.monitors.push(assignment(connected(2), None));
    consumer_case(Fixture::new(app, vec![empty_row(1, 60), empty_row(2, 60)]), |c| {
        let f = c.fixture;
        c.edit(A, 0.46);
        assert!(options(c, A).dirty);
        let (_, first) = c.apply(A, &[(1, 5801)]);
        assert_scene_displays(&first, &[1]);
        assert_source(f, &first[0], A);
        assert!(f.engine.display_rows()[1].assignment.is_none());
        let saved = f.store.load().unwrap().config;
        let fallback = saved.monitors.iter().find(|m| m.selector == connected(1)).unwrap();
        assert!(fallback.enabled);
        assert_eq!(fallback.wallpaper.as_deref(), Some(A));
        let rows = f.engine.display_rows();
        f.engine.replace_display_rows(vec![rows[1].clone(), rows[0].clone()]);
        let (_, handed_over): (BridgeSnapshotBundle, _) = c.reconcile(RefreshDisplays, &[(2, 5812), (1, 5811)]);
        assert_scene_displays(&handed_over, &[1, 2]);
        assert_source(f, scene_on(&handed_over, 1), A);
        assert_source(f, scene_on(&handed_over, 2), A);
        let live = f.engine.display_rows();
        assert_eq!(live.iter().filter(|r| r.assignment.is_some()).count(), 2);
        assert_eq!(live.iter().filter(|r| r.window_active).count(), 2);
        assert_active(&c.snapshots(), &[A]);
    }).await;
}

#[tokio::test]
async fn settings_assignment_conflicts_rebase_cleanly_but_preserve_explicit_enable_intent() {
    consumer_case(Fixture::new(configured(), vec![empty_row(1, 60)]), |c| {
        let _: (BridgeSnapshotBundle, _) = c.reconcile(Bootstrap, &[(1, 5901)]);
        c.select(B);
        c.enable_draft(B, "primary", true);
        c.apply(B, &[(1, 5902)]);
        let a = option_row(&options(c, A), "primary");
        assert!(!a.enabled);
        assert!(!a.dirty);
        assert_active(&c.snapshots(), &[B]);
        c.select(A);
        c.enable_draft(A, "primary", true);
        let pending = option_row(&options(c, A), "primary");
        assert!(pending.enabled && pending.dirty);
        c.select(B);
        c.select(A);
        let restored_options = options(c, A);
        assert!(restored_options.dirty);
        let restored = option_row(&restored_options, "primary");
        assert!(restored.enabled && restored.dirty);
        assert_active(&c.snapshots(), &[B]);
        // Put A back in control, then retain a separate explicit disable draft
        // across a competing B Apply. This intent is already satisfied by B.
        c.apply(A, &[(1, 5903)]);
        c.enable_draft(A, "primary", false);
        let disabled_options = options(c, A);
        assert!(disabled_options.dirty);
        let disabled = option_row(&disabled_options, "primary");
        assert!(!disabled.enabled && disabled.dirty);
        c.select(B);
        c.enable_draft(B, "primary", true);
        c.apply(B, &[(1, 5904)]);
        c.select(A);
        let rebased_options = options(c, A);
        assert!(!rebased_options.dirty);
        let rebased = option_row(&rebased_options, "primary");
        assert!(!rebased.enabled);
        assert!(!rebased.dirty);
        assert_active(&c.snapshots(), &[B]);
    }).await;
}

#[tokio::test]
async fn settings_switching_primary_uses_each_new_sources_saved_scaling_document() {
    let mut app = configured();
    app.monitors[0].wallpaper = None;
    let f = Fixture::with_initial(app, vec![empty_row(1, 60)], BTreeMap::new(), &[A, B]);
    let mut a = WallpaperConfig::new_for(A, "scene");
    a.monitors.push(MonitorRender { selector: SerializedSelector::Primary, scaling_mode: "fit".into(), scaling_factor: 0.73, ..MonitorRender::default() });
    let mut b = WallpaperConfig::new_for(B, "scene");
    b.monitors.push(MonitorRender { selector: SerializedSelector::Primary, scaling_mode: "stretch".into(), scaling_factor: 0.92, ..MonitorRender::default() });
    consumer_case(f, move |c| {
        let f = c.fixture;
        f.store.save_wallpaper(&a).unwrap();
        f.store.save_wallpaper(&b).unwrap();
        c.select(A);
        c.enable_draft(A, "primary", true);
        assert!(options(c, A).dirty);
        let (_, first) = c.apply(A, &[(1, 6001)]);
        assert_scene_displays(&first, &[1]);
        assert_source(f, &first[0], A);
        assert_eq!(first[0].scaling_mode, ScalingMode::Fit);
        assert_eq!(first[0].scaling_factor, 0.73);
        c.select(B);
        c.enable_draft(B, "primary", true);
        assert!(options(c, B).dirty);
        let (_, second) = c.apply(B, &[(1, 6002)]);
        assert_scene_displays(&second, &[1]);
        assert_source(f, &second[0], B);
        assert_eq!(second[0].scaling_mode, ScalingMode::Stretch);
        assert_eq!(second[0].scaling_factor, 0.92);
        assert_eq!(live_source(f, 1).scaling_mode, ScalingMode::Stretch);
        assert_active(&c.snapshots(), &[B]);
    }).await;
}

#[tokio::test]
async fn settings_transient_empty_inventory_keeps_primary_until_its_renumbered_return() {
    consumer_case(Fixture::new(configured(), vec![empty_row(1, 60)]), |c| {
        let f = c.fixture;
        let _: (BridgeSnapshotBundle, _) = c.reconcile(Bootstrap, &[(1, 6101)]);
        let before = started_reconciles(&f.engine);
        f.engine.replace_display_rows(Vec::new());
        let empty: BridgeSnapshotBundle = c.ask(RefreshDisplays).unwrap();
        assert_eq!(started_reconciles(&f.engine), before);
        assert_eq!(empty.app.active_wallpaper_ids, vec![A.to_owned()]);
        assert!(empty.monitor_information.rows.is_empty());
        let mut returned = empty_row(7, 75);
        returned.identity = identity(1);
        returned.desc.identity = identity(1);
        f.engine.replace_display_rows(vec![returned]);
        let (restored, scenes): (BridgeSnapshotBundle, _) = c.reconcile(RefreshDisplays, &[(7, 6107)]);
        assert_scene_displays(&scenes, &[7]);
        assert_source(f, &scenes[0], A);
        assert_active(&restored, &[A]);
        assert_eq!(restored.monitor_information.rows.len(), 1);
        assert_eq!(restored.monitor_information.rows[0].display_id, "primary");
        assert_eq!(restored.monitor_information.rows[0].wallpaper_id, A);
        assert!(f.engine.display_rows()[0].window_active);
    }).await;
}

fn terminal_entered(engine: &ControlledEngine, mut control: OperationControl) -> tokio::sync::oneshot::Sender<()> {
    let end = Instant::now() + DEADLINE;
    loop {
        for row in engine.display_rows() {
            if let Some(handle) = row.handle { engine.emit_first_frame(handle); }
        }
        match control.entered.try_recv() {
            Ok(()) => return control.release,
            Err(tokio::sync::oneshot::error::TryRecvError::Empty) => {
                assert!(Instant::now() < end, "terminal render-scale receipt deadline");
                thread::sleep(QUANTUM);
            }
            Err(tokio::sync::oneshot::error::TryRecvError::Closed) => panic!("terminal completion producer disappeared"),
        }
    }
}

#[tokio::test]
async fn settings_blocked_disable_keeps_snapshots_responsive_and_cannot_overwrite_pause() {
    let mut app = two_sources();
    app.quality.render_scale = 0.5;
    consumer_case(Fixture::new(app, vec![empty_row(1, 60), empty_row(2, 60)]), |c| {
        let f = c.fixture;
        let _: (BridgeSnapshotBundle, _) = c.reconcile(Bootstrap, &[(1, 6201), (2, 6202)]);
        let core = f.engine.hold_next_reconcile(Ok(vec![result(1, 6211)]));
        let terminal = f.engine.hold_next_render_scale_completion(SceneHandle::new(6211));
        let pending = c.start(SetDisplayEnabled { display_id: f.key(2), enabled: false });
        let blocked = entered(core);
        let public = c.snapshots();
        assert_active(&public, &[A, B]);
        assert_display(&public.settings, &f.key(2), true, BridgeDisplayMode::Standalone, None);
        assert_eq!(public.monitor_information.rows.iter().map(|r| r.wallpaper_id.as_str()).collect::<BTreeSet<_>>(), BTreeSet::from([A, B]));
        assert!(matches!(pending.try_recv(), Err(mpsc::TryRecvError::Empty)));
        blocked.release();
        let release = terminal_entered(&f.engine, terminal);
        let paused: BridgeSnapshotBundle = c.ask(SetGlobalPlayback { playback_state: BridgePlaybackState::Paused }).unwrap();
        assert_eq!(paused.app.playback_state, BridgePlaybackState::Paused);
        let repair = f.engine.hold_next_reconcile(Ok(vec![result(1, 6221), result(2, 6222)]));
        release.send(()).unwrap();
        let completion: BridgeDisplayMutationBundle = c.finish(pending, &[6211]).unwrap();
        assert_eq!(completion.app.playback_state, BridgePlaybackState::Paused);
        let repaired = c.settle_repair(repair, &[6221, 6222]);
        assert!(repaired.iter().all(|s| s.paused));
        let final_state = c.snapshots();
        assert_eq!(final_state.app.playback_state, BridgePlaybackState::Paused);
        assert_active(&final_state, &[A, B]);
    }).await;
}

#[tokio::test]
async fn settings_login_uses_only_injected_available_or_unavailable_controllers() {
    for initially_enabled in [true, false] {
        let f = Fixture::new(configured(), vec![empty_row(1, 60)]);
        let f = reopen_consumer(f, vec![empty_row(1, 60)], LaunchAtLoginStatus::Available { enabled: initially_enabled }).await;
        consumer_case(f, move |c| {
            let initial = c.snapshots().settings;
            assert!(initial.launch_at_login_available);
            assert_eq!(initial.launch_at_login_enabled, initially_enabled);
            assert!(!initial.launch_at_login_needs_approval);
            if !initially_enabled {
                let enabled: BridgeDisplayMutationBundle = c.ask(SetLaunchAtLogin { enabled: true }).unwrap();
                assert!(enabled.settings.launch_at_login_available);
                assert!(enabled.settings.launch_at_login_enabled);
                assert!(c.snapshots().settings.launch_at_login_enabled);
                let disabled: BridgeDisplayMutationBundle = c.ask(SetLaunchAtLogin { enabled: false }).unwrap();
                assert!(disabled.settings.launch_at_login_available);
                assert!(!disabled.settings.launch_at_login_enabled);
                assert!(!c.snapshots().settings.launch_at_login_enabled);
            }
        }).await;
    }
    consumer_case(Fixture::new(configured(), vec![empty_row(1, 60)]), |c| {
        let initial = c.snapshots().settings;
        assert!(!initial.launch_at_login_available && !initial.launch_at_login_enabled);
        let error = c.ask(SetLaunchAtLogin { enabled: true }).unwrap_err();
        assert_eq!(error.kind(), BridgeErrorKind::InvalidInput);
        let refused = c.snapshots().settings;
        assert!(!refused.launch_at_login_available);
        assert!(!refused.launch_at_login_enabled);
    }).await;
}

#[tokio::test]
async fn settings_source_audio_response_updates_exactly_its_direct_and_mirror_handles() {
    let mut app = mirrored_source(B);
    app.monitors.push(assignment(connected(3), Some(A)));
    consumer_case(Fixture::new(app, vec![empty_row(1, 60), empty_row(2, 120), empty_row(3, 60)]), |c| {
        let f = c.fixture;
        let (_, scenes): (BridgeSnapshotBundle, _) = c.reconcile(Bootstrap, &[(1, 6301), (2, 6302), (3, 6303)]);
        assert_source(f, scene_on(&scenes, 1), B);
        assert_source(f, scene_on(&scenes, 2), B);
        assert_source(f, scene_on(&scenes, 3), A);
        for handle in [6301, 6302, 6303] {
            f.engine.require_audio(SceneHandle::new(handle), true);
        }
        let reconcile_count = started_reconciles(&f.engine);
        for enabled in [false, true] {
            let start = f.engine.observations().len();
            c.ask(SetAudioResponseEnabled { wallpaper_id: B.into(), enabled }).unwrap();
            let observations = f.engine.observations();
            let mut capture: Vec<_> = observations[start..].iter().filter_map(|o| match o {
                EngineObservation::Capture { handle, enabled, phase: OperationPhase::Applied } => Some((handle.raw(), *enabled)),
                _ => None,
            }).collect();
            capture.sort_unstable();
            assert_eq!(capture, vec![(6301, enabled), (6302, enabled)]);
            let response_handles: BTreeSet<_> = observations[start..].iter().filter_map(|o| match o {
                EngineObservation::AudioResponse { handle, enabled: value, phase: OperationPhase::Applied } => { assert_eq!(*value, enabled); Some(handle.raw()) },
                _ => None,
            }).collect();
            assert_eq!(response_handles, BTreeSet::from([6301, 6302]));
            for raw in [6301, 6302] {
                let live = f.engine.live_scene_controls(SceneHandle::new(raw)).unwrap();
                assert_eq!(live.audio_response_enabled, enabled);
                assert_eq!(live.audio_capture_enabled, enabled);
                assert_eq!(f.engine.audio_capture_state(SceneHandle::new(raw)), Some(enabled));
            }
            assert!(f.engine.live_scene_controls(SceneHandle::new(6303)).unwrap().audio_response_enabled);
            assert_eq!(options(c, B).audio_response_enabled, enabled);
            assert_eq!(started_reconciles(&f.engine), reconcile_count);
        }
    }).await;
}

#[tokio::test]
async fn settings_older_success_defers_repair_until_newer_mirror_completion() {
    let mut app = two_same_source();
    app.quality.render_scale = 0.5;
    consumer_case(Fixture::new(app, vec![empty_row(1, 60), empty_row(2, 120)]), |c| {
        let f = c.fixture;
        let _: (BridgeSnapshotBundle, _) = c.reconcile(Bootstrap, &[(1, 6401), (2, 6402)]);
        let baseline = started_reconciles(&f.engine);
        let old_core = f.engine.hold_next_reconcile(Ok(vec![result(1, 6411)]));
        let old_terminal = f.engine.hold_next_render_scale_completion(SceneHandle::new(6411));
        let old = c.start(SetDisplayEnabled { display_id: f.key(2), enabled: false });
        let old_entry = entered(old_core);
        assert_scene_displays(&old_entry.scenes, &[1]);
        old_entry.release();
        let old_release = terminal_entered(&f.engine, old_terminal);

        // The second request is prepared from the same still-published enabled
        // Standalone generation; the first core is no longer held.
        assert_display(&c.snapshots().settings, &f.key(2), true, BridgeDisplayMode::Standalone, None);
        let new_core = f.engine.hold_next_reconcile(Ok(vec![result(1, 6421), result(2, 6422)]));
        let new_terminal = f.engine.hold_next_render_scale_completion(SceneHandle::new(6422));
        let new = c.start(SetDisplayMode { display_id: f.key(2), mode: BridgeDisplayMode::Mirror });
        let new_entry = entered(new_core);
        assert_scene_displays(&new_entry.scenes, &[1, 2]);
        assert_source(f, scene_on(&new_entry.scenes, 2), A);
        new_entry.release();
        let new_release = terminal_entered(&f.engine, new_terminal);

        let mut repair = f.engine.hold_next_reconcile(Ok(vec![result(1, 6431), result(2, 6432)]));
        old_release.send(()).unwrap();
        let old_result: BridgeDisplayMutationBundle = c.finish(old, &[6411]).unwrap();
        assert_display(&old_result.settings, &f.key(2), true, BridgeDisplayMode::Standalone, None);
        assert!(!c.ask(RepairActive).unwrap());
        assert!(matches!(repair.entered.try_recv(), Err(tokio::sync::oneshot::error::TryRecvError::Empty)));
        assert_eq!(started_reconciles(&f.engine), baseline + 2);
        assert!(matches!(new.try_recv(), Err(mpsc::TryRecvError::Empty)));

        new_release.send(()).unwrap();
        let new_result: BridgeDisplayMutationBundle = c.finish(new, &[6421, 6422]).unwrap();
        assert_display(&new_result.settings, &f.key(2), true, BridgeDisplayMode::Mirror, Some("primary"));
        let repaired = c.settle_repair(repair, &[6431, 6432]);
        assert_scene_displays(&repaired, &[1, 2]);
        assert_source(f, scene_on(&repaired, 2), A);
        assert_display(&c.snapshots().settings, &f.key(2), true, BridgeDisplayMode::Mirror, Some("primary"));
        assert_eq!(started_reconciles(&f.engine), baseline + 3);
    }).await;
}

#[tokio::test]
async fn settings_older_failure_admits_one_repair_while_newer_failed_completion_is_pending() {
    let mut app = two_same_source();
    app.quality.render_scale = 0.5;
    consumer_case(Fixture::new(app, vec![empty_row(1, 60), empty_row(2, 120)]), |c| {
        let f = c.fixture;
        let _: (BridgeSnapshotBundle, _) = c.reconcile(Bootstrap, &[(1, 6501), (2, 6502)]);
        let baseline = started_reconciles(&f.engine);
        let old_core = f.engine.hold_next_reconcile(Ok(vec![result(1, 6511)]));
        let old_terminal = f.engine.hold_next_render_scale_completion(SceneHandle::new(6511));
        f.engine.fail_next_render_scale(EngineError::Render("older display poststep".into()));
        let old = c.start(SetDisplayEnabled { display_id: f.key(2), enabled: false });
        entered(old_core).release();
        let old_release = terminal_entered(&f.engine, old_terminal);

        // The newer candidate is a genuinely different Mirror mutation. A
        // rejected first-handle RenderScale terminates the remaining poststeps,
        // so this computed failure is terminal without holding a core turn.
        let new_core = f.engine.hold_next_reconcile(Ok(vec![result(1, 6521), result(2, 6522)]));
        let new_terminal = f.engine.hold_next_render_scale_completion(SceneHandle::new(6521));
        f.engine.fail_next_render_scale(EngineError::Render("newer display poststep".into()));
        let new = c.start(SetDisplayMode { display_id: f.key(2), mode: BridgeDisplayMode::Mirror });
        let new_entry = entered(new_core);
        assert_scene_displays(&new_entry.scenes, &[1, 2]);
        assert_source(f, scene_on(&new_entry.scenes, 2), A);
        new_entry.release();
        let new_release = terminal_entered(&f.engine, new_terminal);
        assert_eq!(f.engine.display_rows()[0].handle, Some(SceneHandle::new(6521)));
        assert_eq!(f.engine.display_rows()[1].handle, Some(SceneHandle::new(6522)));
        assert!(!f.engine.observations().iter().any(|o| matches!(o,
            EngineObservation::RenderScale { handle, phase: OperationPhase::Started, .. }
                if *handle == SceneHandle::new(6522))));

        let repair = f.engine.hold_next_reconcile(Ok(vec![result(1, 6531), result(2, 6532)]));
        old_release.send(()).unwrap();
        let old_error = c.finish::<BridgeDisplayMutationBundle>(old, &[6511]).unwrap_err();
        assert_eq!(old_error.kind(), BridgeErrorKind::Engine);
        let repair_entry = entered(repair);
        assert!(c.ask(RepairActive).unwrap());
        assert!(matches!(new.try_recv(), Err(mpsc::TryRecvError::Empty)));
        assert_display(&c.snapshots().settings, &f.key(2), true, BridgeDisplayMode::Standalone, None);
        assert_scene_displays(&repair_entry.scenes, &[1, 2]);
        assert_eq!(started_reconciles(&f.engine), baseline + 3);
        let followup = f.engine.hold_next_reconcile(Ok(vec![result(1, 6541), result(2, 6542)]));
        new_release.send(()).unwrap();
        let new_error = c.finish::<BridgeDisplayMutationBundle>(new, &[6521, 6522]).unwrap_err();
        assert_eq!(new_error.kind(), BridgeErrorKind::Engine);
        repair_entry.release();
        for raw in [6531, 6532] { f.engine.emit_first_frame(SceneHandle::new(raw)); }
        let settled = c.settle_repair(followup, &[6541, 6542]);
        assert_scene_displays(&settled, &[1, 2]);
        assert_source(f, scene_on(&settled, 1), A);
        assert_source(f, scene_on(&settled, 2), A);
        assert_display(&c.snapshots().settings, &f.key(2), true, BridgeDisplayMode::Standalone, None);
        assert_eq!(started_reconciles(&f.engine), baseline + 4);
    }).await;
}

#[tokio::test]
async fn settings_new_mutation_invalidates_inflight_repair_and_repairs_newest_disabled_mirror() {
    let mut app = two_same_source();
    app.quality.render_scale = 0.5;
    consumer_case(Fixture::new(app, vec![empty_row(1, 60), empty_row(2, 120)]), |c| {
        let f = c.fixture;
        let _: (BridgeSnapshotBundle, _) = c.reconcile(Bootstrap, &[(1, 6601), (2, 6602)]);
        let baseline = started_reconciles(&f.engine);
        let old_core = f.engine.hold_next_reconcile(Ok(vec![result(1, 6611)]));
        let old_terminal = f.engine.hold_next_render_scale_completion(SceneHandle::new(6611));
        let old = c.start(SetDisplayEnabled { display_id: f.key(2), enabled: false });
        entered(old_core).release();
        let old_release = terminal_entered(&f.engine, old_terminal);

        let new_core = f.engine.hold_next_reconcile(Ok(vec![result(1, 6621), result(2, 6622)]));
        let new = c.start(SetDisplayMode { display_id: f.key(2), mode: BridgeDisplayMode::Mirror });
        let new_entry = entered(new_core);
        assert_source(f, scene_on(&new_entry.scenes, 2), A);
        new_entry.release();
        let new_result: BridgeDisplayMutationBundle = c.finish(new, &[6621, 6622]).unwrap();
        assert_display(&new_result.settings, &f.key(2), true, BridgeDisplayMode::Mirror, Some("primary"));

        let first_repair = f.engine.hold_next_reconcile(Ok(vec![result(1, 6631), result(2, 6632)]));
        let first_repair_terminal = f.engine.hold_next_render_scale_completion(SceneHandle::new(6632));
        old_release.send(()).unwrap();
        c.finish::<BridgeDisplayMutationBundle>(old, &[6611]).unwrap();
        let repair_entry = entered(first_repair);
        assert_source(f, scene_on(&repair_entry.scenes, 2), A);
        repair_entry.release();
        let repair_release = terminal_entered(&f.engine, first_repair_terminal);
        assert!(c.ask(RepairActive).unwrap());
        // First repair's core turn is released. Only its publication is parked
        // when a genuinely newer user mutation is admitted.
        let latest_core = f.engine.hold_next_reconcile(Ok(vec![result(1, 6641)]));
        let latest = c.start(SetDisplayEnabled { display_id: f.key(2), enabled: false });
        let latest_entry = entered(latest_core);
        assert_scene_displays(&latest_entry.scenes, &[1]);
        latest_entry.release();
        let latest_result: BridgeDisplayMutationBundle = c.finish(latest, &[6641]).unwrap();
        assert_display(&latest_result.settings, &f.key(2), false, BridgeDisplayMode::Mirror, Some("primary"));
        let replacement = f.engine.hold_next_reconcile(Ok(vec![result(1, 6651)]));
        repair_release.send(()).unwrap();
        let repaired = c.settle_repair(replacement, &[6651]);
        assert_scene_displays(&repaired, &[1]);
        assert_source(f, &repaired[0], A);
        let final_state = c.snapshots();
        assert_display(&final_state.settings, &f.key(2), false, BridgeDisplayMode::Mirror, Some("primary"));
        assert!(f.engine.display_rows().iter().find(|r| r.desc.display_id == 2).unwrap().assignment.is_none());
        assert_eq!(started_reconciles(&f.engine), baseline + 5);
    }).await;
}

fn applied_mirror_controls(observations: &[EngineObservation]) -> Vec<(u64, &'static str)> {
    observations.iter().filter_map(|o| match o {
        EngineObservation::Volume { handle, phase: OperationPhase::Applied, .. } => Some((handle.raw(), "volume")),
        EngineObservation::Muted { handle, phase: OperationPhase::Applied, .. } => Some((handle.raw(), "mute")),
        EngineObservation::ScalingMode { handle, phase: OperationPhase::Applied, .. } => Some((handle.raw(), "mode")),
        EngineObservation::ScalingFactor { handle, phase: OperationPhase::Applied, .. } => Some((handle.raw(), "factor")),
        EngineObservation::Fps { handle, phase: OperationPhase::Applied, .. } => Some((handle.raw(), "fps")),
        _ => None,
    }).collect()
}

#[tokio::test]
async fn settings_mirror_live_controls_survive_refresh_and_a_real_source_document_rebuild() {
    let mut app = mirrored_source(B);
    app.quality.render_scale = 0.5;
    consumer_case(Fixture::with_initial(app, vec![empty_row(1, 60), empty_row(2, 144)], BTreeMap::new(), &[A, B]), |c| {
        let f = c.fixture;
        let mut source = WallpaperConfig::new_for(B, "scene");
        source.audio.volume = 0.42;
        source.audio.muted = true;
        source.audio.response_enabled = false;
        source.media_integration_enabled = true;
        source.monitors.push(MonitorRender { selector: SerializedSelector::Primary, scaling_mode: "fit".into(), scaling_factor: 0.67, frame_rate: Some(36), ..MonitorRender::default() });
        source.property_overrides.insert("gain".into(), serde_json::json!(0.45));
        f.store.save_wallpaper(&source).unwrap();
        let (_, initial): (BridgeSnapshotBundle, _) = c.reconcile(Bootstrap, &[(1, 6701), (2, 6702)]);
        let direct = scene_on(&initial, 1);
        let mirror = scene_on(&initial, 2);
        assert_source(f, direct, B);
        assert_source(f, mirror, B);
        assert_eq!((direct.scaling_mode, direct.scaling_factor, direct.fps), (ScalingMode::Fit, 0.67, 36));
        assert_eq!((f32::from(direct.audio_volume), direct.audio_muted), (0.42, true));
        // Monitor-owned defaults are intentionally NOT the source's direct
        // render/audio overrides. Its document and response/media flags are.
        assert_eq!((mirror.scaling_mode, mirror.scaling_factor, mirror.fps), (ScalingMode::Fill, 1.0, 60));
        assert_eq!((mirror.framing.pan_x, mirror.framing.pan_y), (0.5, 0.5));
        assert_eq!((f32::from(mirror.audio_volume), mirror.audio_muted), (1.0, false));
        assert!(!mirror.audio_response_enabled);
        assert!(mirror.media_integration_enabled);
        assert_eq!(mirror.assets_path, direct.assets_path);
        assert_eq!(mirror.shader_cache_path, direct.shader_cache_path);
        assert_eq!(mirror.property_override_json, direct.property_override_json);
        let initial_document: serde_json::Value = serde_json::from_str(mirror.property_override_json.as_deref().unwrap()).unwrap();
        assert_eq!(initial_document["gain"], serde_json::json!(0.45));
        let key = f.key(2);
        let initial_row = row(&c.snapshots().settings, &key);
        assert_eq!((initial_row.scaling_mode, initial_row.scaling_factor, initial_row.target_fps, initial_row.volume, initial_row.muted), (BridgeScalingMode::Fill, 1.0, 60, 1.0, false));
        let original_direct = live_source(f, 1);
        let reconciles = started_reconciles(&f.engine);

        let start = f.engine.observations().len();
        let volume: BridgeDisplayMutationBundle = c.ask(SetMirrorVolume { display_id: key.clone(), volume: 0.23 }).unwrap();
        assert_eq!(row(&volume.settings, &key).volume, 0.23);
        assert_eq!(applied_mirror_controls(&f.engine.observations()[start..]), vec![(6702, "volume")]);
        assert_eq!(f32::from(f.engine.live_scene_controls(SceneHandle::new(6702)).unwrap().audio_volume), 0.23);

        let start = f.engine.observations().len();
        let muted: BridgeDisplayMutationBundle = c.ask(SetMirrorMuted { display_id: key.clone(), muted: true }).unwrap();
        assert!(row(&muted.settings, &key).muted);
        assert_eq!(applied_mirror_controls(&f.engine.observations()[start..]), vec![(6702, "mute")]);
        assert!(f.engine.live_scene_controls(SceneHandle::new(6702)).unwrap().audio_muted);

        let start = f.engine.observations().len();
        let mode: BridgeDisplayMutationBundle = c.ask(SetMirrorScalingMode { display_id: key.clone(), mode: BridgeScalingMode::Match }).unwrap();
        assert_eq!(row(&mode.settings, &key).scaling_mode, BridgeScalingMode::Match);
        assert_eq!(applied_mirror_controls(&f.engine.observations()[start..]), vec![(6702, "mode")]);
        assert_eq!(f.engine.live_scene_controls(SceneHandle::new(6702)).unwrap().scaling_mode, ScalingMode::Fit);

        let start = f.engine.observations().len();
        let factor: BridgeDisplayMutationBundle = c.ask(SetMirrorScalingFactor { display_id: key.clone(), factor: 0.62 }).unwrap();
        assert_eq!(row(&factor.settings, &key).scaling_factor, 0.62);
        assert_eq!(applied_mirror_controls(&f.engine.observations()[start..]), vec![(6702, "factor")]);
        assert_eq!(f.engine.live_scene_controls(SceneHandle::new(6702)).unwrap().scaling_factor, 0.62);

        let start = f.engine.observations().len();
        let fps: BridgeDisplayMutationBundle = c.ask(SetMirrorTargetFps { display_id: key.clone(), fps: 96 }).unwrap();
        assert_eq!(row(&fps.settings, &key).target_fps, 96);
        assert_eq!(applied_mirror_controls(&f.engine.observations()[start..]), vec![(6702, "fps")]);
        assert!(f.engine.observations()[start..].iter().any(|o| matches!(o, EngineObservation::Fps { handle, fps: 96, phase: OperationPhase::Applied } if *handle == SceneHandle::new(6702))));
        assert_eq!(live_source(f, 1), original_direct);
        assert_eq!(started_reconciles(&f.engine), reconciles);
        let overridden = row(&c.snapshots().settings, &key);
        assert_eq!((overridden.scaling_mode, overridden.scaling_factor, overridden.target_fps, overridden.volume, overridden.muted), (BridgeScalingMode::Match, 0.62, 96, 0.23, true));

        c.ask(SetScalingMode { wallpaper_id: B.into(), display_id: "primary".into(), mode: BridgeScalingMode::Stretch }).unwrap();
        assert_eq!(f.engine.live_scene_controls(SceneHandle::new(6701)).unwrap().scaling_mode, ScalingMode::Stretch);
        let live_saved = f.store.load_wallpaper(B).unwrap();
        assert_eq!(live_saved.monitors.iter().find(|r| r.selector == SerializedSelector::Primary).unwrap().scaling_mode, "stretch");
        let refreshed: BridgeSnapshotBundle = c.ask(RefreshDisplays).unwrap();
        assert_eq!(started_reconciles(&f.engine), reconciles);
        assert_eq!(row(&refreshed.settings, &key).scaling_factor, 0.62);
        assert_eq!(f.engine.display_rows()[0].handle, Some(SceneHandle::new(6701)));
        assert_eq!(f.engine.display_rows()[1].handle, Some(SceneHandle::new(6702)));

        c.ask(SetScalingFactor { wallpaper_id: B.into(), display_id: "primary".into(), factor: 0.81 }).unwrap();
        assert_eq!(f.engine.live_scene_controls(SceneHandle::new(6701)).unwrap().scaling_factor, 0.81);
        assert!(option_row(&options(c, B), "primary").dirty);
        let before_apply = f.store.load_wallpaper(B).unwrap();
        assert_eq!(before_apply.monitors.iter().find(|r| r.selector == SerializedSelector::Primary).unwrap().scaling_factor, 0.67);
        c.edit(B, 0.79);
        let (rebuilt, scenes) = c.apply(B, &[(1, 6711), (2, 6712)]);
        assert!(!rebuilt.wallpaper_options.dirty);
        let committed_factor = option_row(&rebuilt.wallpaper_options, "primary");
        assert_eq!(committed_factor.scaling_factor, 0.81);
        assert!(committed_factor.dirty);
        assert!(committed_factor.can_restore_defaults);
        assert_scene_displays(&scenes, &[1, 2]);
        let new_direct = scene_on(&scenes, 1);
        let new_mirror = scene_on(&scenes, 2);
        assert_source(f, new_direct, B);
        assert_source(f, new_mirror, B);
        assert_eq!((new_direct.scaling_mode, new_direct.scaling_factor), (ScalingMode::Stretch, 0.81));
        assert_eq!((new_mirror.scaling_mode, new_mirror.scaling_factor, new_mirror.fps), (ScalingMode::Fit, 0.62, 96));
        assert_eq!((f32::from(new_mirror.audio_volume), new_mirror.audio_muted), (0.23, true));
        assert!(!new_mirror.audio_response_enabled);
        assert!(new_mirror.media_integration_enabled);
        assert_eq!(new_mirror.property_override_json, new_direct.property_override_json);
        assert_ne!(new_mirror.property_override_json, mirror.property_override_json);
        let updated: serde_json::Value = serde_json::from_str(new_mirror.property_override_json.as_deref().unwrap()).unwrap();
        assert_eq!(updated["gain"], serde_json::json!(0.79));
        let public = row(&rebuilt.settings, &key);
        assert_eq!((public.scaling_mode, public.scaling_factor, public.target_fps, public.volume, public.muted), (BridgeScalingMode::Match, 0.62, 96, 0.23, true));
        let saved = f.store.load_wallpaper(B).unwrap();
        let primary = saved.monitors.iter().find(|r| r.selector == SerializedSelector::Primary).unwrap();
        assert_eq!(primary.scaling_mode, "stretch");
        assert_eq!(primary.scaling_factor, 0.81);
        assert_eq!(saved.property_overrides["gain"], serde_json::json!(0.79));
        let app = f.store.load().unwrap().config;
        let saved_mirror = app.monitor_settings.iter().find(|r| r.selector == connected(2)).unwrap();
        assert_eq!(saved_mirror.scaling_factor, 0.62);
        assert_eq!(saved_mirror.frame_rate, Some(96));
        assert_eq!((saved_mirror.volume, saved_mirror.muted), (0.23, true));
        assert_eq!(started_reconciles(&f.engine), reconciles + 1);
    }).await;
}

async fn separately_loaded_settings(fixture: &Fixture) -> Result<BridgeSnapshotBundle, ConsumerPanic> {
    fixture.root.check(fixture.store.root());
    let engine = ControlledEngine::new(vec![empty_row(1, 60), empty_row(2, 75)]);
    let bridge = BridgeBuilder::new(engine)
        .with_config_store(fixture.store.clone())
        .with_paths(fixture.paths.clone())
        .with_launch_at_login(inert_login_controller(LaunchAtLoginStatus::Unavailable))
        .with_mouse_polling_enabled(false)
        .with_power_watching_enabled(false)
        .build()
        .map_err(|error| Box::new(error) as ConsumerPanic)?;
    // No with_state and no shared journal override: this distinct real builder
    // loads the committed store while the original actor still owns its draft.
    owned_bridge_call(bridge, |requests| requests.ask(GetAllSnapshots).unwrap()).await
}

#[tokio::test]
async fn settings_disabling_the_only_assigned_secondary_empties_scenes_and_rebases_the_original_actor() {
    let mut app = configured();
    app.monitors[0].wallpaper = None;
    app.monitors.push(assignment(connected(2), None));
    let fixture = Fixture::new(app, vec![empty_row(1, 60), empty_row(2, 75)]);
    let fixture = consumer_stage(fixture, |c| {
        let f = c.fixture;
        let key = f.key(2);
        assert_eq!(started_reconciles(&f.engine), 0);
        c.select(A);
        c.enable_draft(A, &key, true);
        assert!(options(c, A).dirty);
        let (_, scenes) = c.apply(A, &[(2, 6802)]);
        assert_eq!(started_reconciles(&f.engine), 1);
        assert_scene_displays(&scenes, &[2]);
        assert_source(f, &scenes[0], A);
        assert!(f.engine.display_rows()[0].assignment.is_none());
        assert_active(&c.snapshots(), &[A]);

        c.enable_draft(A, &key, true);
        let restaged: DraftConfigObservation = c.ask(ReadDraftConfig { wallpaper_id: A.into() }).unwrap();
        assert!(restaged.pending_enabled.contains(&connected(2)));
        let (disabled, empty): (BridgeDisplayMutationBundle, _) = c.reconcile(
            SetDisplayEnabled { display_id: key.clone(), enabled: false }, &[],
        );
        assert!(empty.is_empty());
        assert_eq!(started_reconciles(&f.engine), 2);
        assert_display(&disabled.settings, &key, false, BridgeDisplayMode::Standalone, None);
        assert!(f.engine.display_rows().iter().all(|row| row.assignment.is_none() && row.handle.is_none() && !row.window_active));
        let rebased: DraftConfigObservation = c.ask(ReadDraftConfig { wallpaper_id: A.into() }).unwrap();
        assert!(!rebased.enabled.contains(&connected(2)));
        assert!(!rebased.pending_enabled.contains(&connected(2)));
        assert_active(&c.snapshots(), &[]);
        let saved = f.store.load().unwrap().config;
        assert!(!saved.monitors.iter().find(|monitor| monitor.selector == connected(2)).unwrap().enabled);
    }).await;

    let observed = match separately_loaded_settings(&fixture).await {
        Ok(snapshot) => snapshot,
        Err(payload) => {
            let _ = consumer_dispose(fixture, true).await;
            resume_unwind(payload);
        }
    };
    // The second actor has genuinely drained. Only the original actor, with its
    // already-existing/restaged wallpaper draft, receives this later Apply.
    consumer_case(fixture, move |c| {
        let f = c.fixture;
        let key = f.key(2);
        assert_display(&observed.settings, &key, false, BridgeDisplayMode::Standalone, None);
        assert_eq!(started_reconciles(&f.engine), 2);
        let applied: BridgeWallpaperMutationBundle = c.ask(ApplyWallpaperOptions { wallpaper_id: A.into(), user_initiated: true }).unwrap();
        assert_eq!(started_reconciles(&f.engine), 2);
        assert_display(&applied.settings, &key, false, BridgeDisplayMode::Standalone, None);
        assert!(!applied.wallpaper_options.dirty);
        assert!(!applied.wallpaper_options.display_configurations.iter().any(|row| row.display_id == key));
        assert!(f.engine.display_rows().iter().all(|row| row.assignment.is_none()));
        assert_active(&c.snapshots(), &[]);
        assert!(!f.store.load().unwrap().config.monitors.iter().find(|monitor| monitor.selector == connected(2)).unwrap().enabled);
    }).await;
}

#[tokio::test]
async fn settings_ordered_active_owners_come_from_three_real_scanned_projects_not_primary_aliases() {
    const C: &str = "410003";
    let mut app = configured();
    app.monitors.push(assignment(connected(1), Some(B)));
    app.monitors.push(assignment(connected(2), Some(C)));
    consumer_case(Fixture::new(app, vec![empty_row(1, 60), empty_row(2, 75)]), |c| {
        let f = c.fixture;
        let project = f.paths.project_json(C);
        f.root.check(&project);
        fs::create_dir_all(project.parent().unwrap()).unwrap();
        fs::write(&project, PROJECT).unwrap();
        let scene = project.parent().unwrap().join("scene.json");
        f.root.check(&scene);
        fs::write(&scene, "{\"objects\":[]}").unwrap();
        f.store.save_wallpaper(&WallpaperConfig::new_for(C, "scene")).unwrap();
        let scanned: BridgeSnapshotBundle = c.ask(RefreshLibrary).unwrap();
        assert!(scanned.library.wallpapers.iter().any(|entry| entry.id == C));
        assert!(scanned.library.wallpapers.iter().any(|entry| entry.id == B));

        let (_, scenes): (BridgeSnapshotBundle, _) = c.reconcile(Bootstrap, &[(1, 6901), (2, 6902)]);
        assert_scene_displays(&scenes, &[1, 2]);
        assert_source(f, scene_on(&scenes, 1), A);
        assert_source(f, scene_on(&scenes, 2), C);
        let committed: AppConfig = c.ask(ReadAppConfig).unwrap();
        assert!(committed.monitors.iter().any(|monitor| monitor.selector == connected(1) && monitor.wallpaper.as_deref() == Some(B)));
        let snapshot = c.snapshots();
        assert_eq!(snapshot.app.active_wallpaper_ids, vec![A.to_owned(), C.to_owned()]);
        assert_eq!(
            snapshot.library.wallpapers.iter().filter(|entry| entry.active).map(|entry| entry.id.clone()).collect::<Vec<_>>(),
            vec![A.to_owned(), C.to_owned()],
        );
        assert!(snapshot.library.wallpapers.iter().any(|entry| entry.id == B && !entry.active));
        assert_eq!(snapshot.monitor_information.rows.iter().find(|row| row.display_id == "primary").unwrap().wallpaper_id, A);
        assert_eq!(snapshot.monitor_information.rows.iter().find(|row| row.display_id == f.key(2)).unwrap().wallpaper_id, C);
    }).await;
}

struct ReleaseOnDrop<F: FnOnce()> {
    release: Option<F>,
}
impl<F: FnOnce()> ReleaseOnDrop<F> {
    fn release(mut self) {
        if let Some(release) = self.release.take() { release(); }
    }
}
impl<F: FnOnce()> Drop for ReleaseOnDrop<F> {
    fn drop(&mut self) {
        if let Some(release) = self.release.take() { release(); }
    }
}

#[tokio::test]
async fn settings_synthetic_core_blocked_admission_keeps_public_reads_and_pause_responsive() {
    let base = Fixture::new(two_sources(), vec![empty_row(1, 60), empty_row(2, 75)]);
    let Fixture { bridge, engine, store, paths, root, clock, prior_tickets } = base;
    let drained = crate::api::mounted_lifecycle::shutdown_and_drain(bridge).await;
    drop(engine);
    drop(prior_tickets);
    if let Err(error) = drained {
        std::mem::forget(root);
        panic!("drain before synthetic admission builder: {error}");
    }
    let a_path = paths.project_json(A);
    let b_path = paths.project_json(B);
    root.check(&a_path);
    root.check(&b_path);
    let fake = crate::engine::FakeEngineFacade::default();
    fake.set_snapshot(vec![empty_row(1, 60), empty_row(2, 75)]);
    let built = BridgeBuilder::new(fake.clone())
        .with_config_store(store.clone())
        .with_paths(paths.clone())
        .with_launch_at_login(inert_login_controller(LaunchAtLoginStatus::Unavailable))
        .with_mouse_polling_enabled(false)
        .with_power_watching_enabled(false)
        .build();
    let bridge = match built {
        Ok(bridge) => bridge,
        Err(error) => { std::mem::forget(root); panic!("synthetic admission builder: {error}"); }
    };
    let outcome = owned_bridge_call(bridge, move |requests| {
        // This accepted synthetic dependency has neither common first-frame
        // waiting nor common audio exclusion. It is NOT the real-turn test.
        let startup: BridgeSnapshotBundle = requests.ask(Bootstrap).unwrap();
        assert_eq!(startup.app.active_wallpaper_ids, vec![A.to_owned(), B.to_owned()]);
        let startup_calls = fake.calls();
        assert_eq!(startup_calls.len(), 1);
        assert_scene_displays(&startup_calls[0], &[1, 2]);
        assert_eq!(Path::new(&scene_on(&startup_calls[0], 1).scene_path), a_path.as_path());
        assert_eq!(Path::new(&scene_on(&startup_calls[0], 2).scene_path), b_path.as_path());

        // Deliberate retained-policy live input, derived from those actual
        // requests and the dependency's documented index+1 synthetic handles.
        // Fake reconcile itself does NOT publish display snapshot assignments.
        let mut rows = vec![empty_row(1, 60), empty_row(2, 75)];
        for (index, row) in rows.iter_mut().enumerate() {
            row.handle = Some(SceneHandle::new(index as u64 + 1));
            row.window_active = true;
            row.assignment = Some(WallpaperAssignment::Direct(SceneTemplate::from_scene_desc(
                scene_on(&startup_calls[0], row.desc.display_id),
            )));
        }
        fake.set_snapshot(rows);
        let key = connected(2).id();
        let block = fake.block_next_reconcile();
        let release = ReleaseOnDrop { release: Some(|| block.release()) };
        let pending = requests.start(SetDisplayEnabled { display_id: key.clone(), enabled: false });
        assert!(block.wait_until_blocked(DEADLINE), "synthetic reconcile admission deadline");
        let held_calls = fake.calls();
        assert_eq!(held_calls.len(), 2);
        assert_scene_displays(&held_calls[1], &[1]);
        assert_eq!(Path::new(&held_calls[1][0].scene_path), a_path.as_path());
        let responsive: BridgeSnapshotBundle = requests.ask(GetAllSnapshots).unwrap();
        assert_eq!(responsive.app.active_wallpaper_ids, vec![A.to_owned(), B.to_owned()]);
        assert_display(&responsive.settings, &key, true, BridgeDisplayMode::Standalone, None);
        let paused: BridgeSnapshotBundle = requests.ask(SetGlobalPlayback { playback_state: BridgePlaybackState::Paused }).unwrap();
        assert_eq!(paused.app.playback_state, BridgePlaybackState::Paused);
        assert!(matches!(pending.try_recv(), Err(mpsc::TryRecvError::Empty)));
        release.release();
        let completed: BridgeDisplayMutationBundle = requests.wait(pending).unwrap();
        assert_eq!(completed.app.playback_state, BridgePlaybackState::Paused);
        let end = Instant::now() + DEADLINE;
        while !requests.ask(RepairsIdle).unwrap() {
            assert!(Instant::now() < end, "synthetic receiving-side repair settlement deadline");
            thread::sleep(QUANTUM);
        }
        let final_state: BridgeSnapshotBundle = requests.ask(GetAllSnapshots).unwrap();
        assert_eq!(final_state.app.playback_state, BridgePlaybackState::Paused);
        assert_display(&final_state.settings, &key, true, BridgeDisplayMode::Standalone, None);
    }).await;
    drop(store);
    drop(paths);
    drop(clock);
    if outcome.is_err() { std::mem::forget(root); } else { drop(root); }
    if let Err(payload) = outcome { resume_unwind(payload); }
}
