//! Independent operation-consumer tests; mounted as a child of `crate::api`.
//! All synchronization is bounded and all engine work runs on the real actor runtime.

mod apply_consumer_contract_tests;
mod settings_consumer_contract_tests;

use super::*;
use crate::actor::state::BridgeActorState;
use crate::actor::{BridgeActor, BridgeActorHandle, messages::*};
use crate::api::lifecycle_test_support::{actor, inert_login_controller};
use crate::api::mounted_lifecycle::{
    ControlledEngine, EngineObservation, FaultTiming, OperationControl, OperationPhase,
    PropertyPreviewPhase, ReconcileControl, ReconcileResultShape, SelectedSetter,
};
use crate::api::operation_contract_test_support::*;
use crate::config::{
    AppConfig, ConfigStore, MonitorCfg, MonitorRender, SerializedSelector, WallpaperConfig,
};
use crate::display::DisplaySnapshotExt;
use crate::engine::{LoadJournal, LoadTicket};
use crate::login::LaunchAtLoginStatus;
use crate::paths::BridgePaths;
use kameo::message::{Context, Message};
use kameo::reply::Reply;
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{
    Arc,
    atomic::{AtomicU64, Ordering},
    mpsc,
};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use wallpaper_core::project::{ScalingMode, SceneDesc, SceneHandle, SceneResult, SceneTemplate};
use wallpaper_core::{
    DisplayDesc, DisplayIdentity, DisplaySelector, DisplaySnapshotEntry, EngineError,
    WallpaperAssignment,
};

const DEADLINE: Duration = Duration::from_secs(12);
const QUANTUM: Duration = Duration::from_millis(2);
const A: &str = "410001";
const B: &str = "410002";
const PROJECT: &str = r#"{"type":"scene","title":"Independent scalar scene","file":"scene.json","general":{"properties":{"gain":{"type":"slider","text":"Gain","value":0.25,"min":0,"max":1},"pulse":{"type":"bool","text":"Pulse","value":false}}}}"#;
static NEXT_ROOT: AtomicU64 = AtomicU64::new(0);

struct OwnedRoot(PathBuf);
impl OwnedRoot {
    fn new() -> Self {
        let parent = std::env::temp_dir()
            .canonicalize()
            .expect("canonical system-user temp");
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let path = parent.join(format!(
            "wm-operation-contract-{}-{nonce}-{}",
            std::process::id(),
            NEXT_ROOT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&path).unwrap();
        Self(path.canonicalize().unwrap())
    }
    fn check(&self, path: &Path) {
        assert!(
            path.starts_with(&self.0),
            "path escaped owned fixture: {}",
            path.display()
        );
        assert!(
            !path
                .components()
                .any(|part| matches!(part, std::path::Component::ParentDir)),
            "parent traversal is outside the owned fixture contract"
        );
    }
}
impl Drop for OwnedRoot {
    fn drop(&mut self) {
        if !thread::panicking() {
            fs::remove_dir_all(&self.0).expect("remove owned fixture");
        }
    }
}

fn selector(id: u32) -> SerializedSelector {
    SerializedSelector::LiveDisplayId { display_id: id }
}
fn connected(id: u32) -> SerializedSelector {
    empty_row(id, 60).connected_selector()
}
fn identity(id: u32) -> DisplayIdentity {
    DisplayIdentity {
        uuid: Some(format!("independent-display-{id}")),
        vendor_id: Some(415),
        model_id: Some(72),
        serial_number: Some(id),
        unit_number: None,
        name: Some(format!("Panel {id}")),
    }
}
fn empty_row(id: u32, hz: u32) -> DisplaySnapshotEntry {
    let identity = identity(id);
    DisplaySnapshotEntry {
        desc: DisplayDesc::with_identity(
            id,
            identity.clone(),
            ((id - 1) * 1920) as i32,
            0,
            1920,
            1080,
            1.0,
        )
        .with_refresh_rate(hz),
        identity,
        handle: None,
        accepts_pointer_input: false,
        paused: false,
        window_active: false,
        assignment: None,
    }
}
fn assignment(selector: SerializedSelector, id: Option<&str>) -> MonitorCfg {
    MonitorCfg {
        selector,
        enabled: true,
        mode: "independent".into(),
        wallpaper: id.map(str::to_owned),
        mirror_target: None,
    }
}
fn configured() -> AppConfig {
    let mut app = AppConfig::default();
    app.monitors = vec![assignment(SerializedSelector::Primary, Some(A))];
    app.general.last_selected_wallpaper = Some(A.into());
    app
}
fn reduced() -> AppConfig {
    let mut app = configured();
    app.quality.render_scale = 0.5;
    app
}
fn remembered_rows(entries: &[(&str, &str)]) -> BTreeMap<String, BridgeDisplaySettingsRow> {
    entries
        .iter()
        .map(|(id, title)| {
            (
                (*id).to_owned(),
                BridgeDisplaySettingsRow {
                    display_id: (*id).to_owned(),
                    title: (*title).to_owned(),
                    enabled: true,
                    mode: BridgeDisplayMode::Standalone,
                    mirror_targets: Vec::new(),
                    selected_mirror_target: None,
                    scaling_mode: BridgeScalingMode::Match,
                    scaling_factor: 0.87,
                    target_fps: 48,
                    max_fps: 144,
                    muted: true,
                    volume: 0.34,
                },
            )
        })
        .collect()
}
fn result(display: u32, raw: u64) -> SceneResult {
    SceneResult::new(display, SceneHandle::new(raw), 0)
}
fn error_pair(error: &BridgeError) -> (BridgeErrorKind, String) {
    (error.kind(), error.message().to_owned())
}
fn assert_error(error: BridgeError, kind: BridgeErrorKind, message: &str) {
    assert_eq!(error.kind(), kind);
    assert_eq!(error.message(), message);
}
fn engine_boundary(message: &str) -> String {
    EngineError::Render(message.into()).to_string()
}

struct Pending<T> {
    reply: mpsc::Receiver<Result<T, BridgeError>>,
    thread: thread::JoinHandle<()>,
}
fn request<T: Send + 'static>(
    call: impl FnOnce() -> Result<T, BridgeError> + Send + 'static,
) -> Pending<T> {
    let (tx, reply) = mpsc::sync_channel(1);
    let thread = thread::spawn(move || {
        let _ = tx.send(call());
    });
    Pending { reply, thread }
}
impl<T> Pending<T> {
    fn is_pending(&self) {
        assert!(
            matches!(self.reply.try_recv(), Err(mpsc::TryRecvError::Empty)),
            "ordinary reply arrived before the blocked engine was released"
        );
    }
    fn finish(self, engine: &ControlledEngine, handles: &[SceneHandle]) -> Result<T, BridgeError> {
        let end = Instant::now() + DEADLINE;
        let reply = loop {
            for handle in handles {
                if engine
                    .display_rows()
                    .iter()
                    .any(|row| row.handle == Some(*handle))
                {
                    engine.emit_first_frame(*handle);
                }
            }
            match self.reply.recv_timeout(QUANTUM) {
                Ok(reply) => break reply,
                Err(mpsc::RecvTimeoutError::Timeout) => assert!(
                    Instant::now() < end,
                    "real receiving-side operation reply exceeded deadline"
                ),
                Err(mpsc::RecvTimeoutError::Disconnected) => panic!("request thread lost reply"),
            }
        };
        self.thread.join().expect("request thread panicked");
        reply
    }
}
struct Entered {
    scenes: Vec<SceneDesc>,
    release: tokio::sync::oneshot::Sender<()>,
}
fn entered(mut gate: ReconcileControl) -> Entered {
    let end = Instant::now() + DEADLINE;
    loop {
        match gate.entered.try_recv() {
            Ok(scenes) => {
                return Entered {
                    scenes,
                    release: gate.release,
                };
            }
            Err(tokio::sync::oneshot::error::TryRecvError::Empty) => {
                assert!(
                    Instant::now() < end,
                    "actual core receipt exceeded deadline"
                );
                thread::sleep(QUANTUM);
            }
            Err(tokio::sync::oneshot::error::TryRecvError::Closed) => {
                panic!("reconcile gate lost producer")
            }
        }
    }
}
impl Entered {
    fn release(self) {
        self.release.send(()).expect("actual worker still waiting");
    }
}

struct RepairsIdle;
impl Message<RepairsIdle> for BridgeActor<ArcEngineFacade> {
    type Reply = Result<bool, BridgeError>;
    fn name() -> &'static str {
        "IndependentOperationRepairsIdle"
    }
    async fn handle(&mut self, _: RepairsIdle, _: &mut Context<Self, Self::Reply>) -> Self::Reply {
        Ok(self.operation_repairs_idle())
    }
}

struct RepairActive;
impl Message<RepairActive> for BridgeActor<ArcEngineFacade> {
    type Reply = Result<bool, BridgeError>;
    fn name() -> &'static str {
        "IndependentOperationRepairActive"
    }
    async fn handle(&mut self, _: RepairActive, _: &mut Context<Self, Self::Reply>) -> Self::Reply {
        Ok(self.operation_repair_active())
    }
}

#[derive(Clone)]
struct BoundedHandle {
    actor: BridgeActorHandle<ArcEngineFacade>,
    engine: ControlledEngine,
}
impl BoundedHandle {
    fn blocking_ask<M, T>(&self, message: M) -> Result<T, BridgeError>
    where
        BridgeActor<ArcEngineFacade>: Message<M>,
        <BridgeActor<ArcEngineFacade> as Message<M>>::Reply: Reply<Ok = T, Error = BridgeError>,
        M: Send + 'static,
        T: Send + 'static,
    {
        let handle = self.actor.clone();
        request(move || handle.blocking_ask(message)).finish(&self.engine, &[])
    }
}

struct Fixture {
    bridge: WallpaperBridge,
    engine: ControlledEngine,
    store: ConfigStore,
    paths: BridgePaths,
    root: OwnedRoot,
    clock: Arc<AtomicU64>,
    prior_tickets: Vec<LoadTicket>,
}
impl Fixture {
    fn new(app: AppConfig, rows: Vec<DisplaySnapshotEntry>) -> Self {
        Self::seeded(app, rows, &[], false)
    }
    fn with_holds(app: AppConfig, rows: Vec<DisplaySnapshotEntry>, owners: &[&str]) -> Self {
        Self::seeded(app, rows, owners, true)
    }
    fn with_strikes(app: AppConfig, rows: Vec<DisplaySnapshotEntry>, owners: &[&str]) -> Self {
        Self::seeded(app, rows, owners, false)
    }
    fn seeded(
        app: AppConfig,
        rows: Vec<DisplaySnapshotEntry>,
        owners: &[&str],
        startup: bool,
    ) -> Self {
        Self::assemble(app, rows, owners, startup, BTreeMap::new(), &[])
    }
    fn with_initial(
        app: AppConfig,
        rows: Vec<DisplaySnapshotEntry>,
        remembered: BTreeMap<String, BridgeDisplaySettingsRow>,
        uncached: &[&str],
    ) -> Self {
        Self::assemble(app, rows, &[], false, remembered, uncached)
    }
    fn assemble(
        app: AppConfig,
        rows: Vec<DisplaySnapshotEntry>,
        owners: &[&str],
        startup: bool,
        remembered: BTreeMap<String, BridgeDisplaySettingsRow>,
        uncached: &[&str],
    ) -> Self {
        let root = OwnedRoot::new();
        let paths = BridgePaths::for_home(root.0.join("home"));
        for path in [
            paths.app_support_root(),
            paths.steam_workshop_root(),
            paths.assets_root(),
            paths.user_assets_root(),
            paths.shader_cache_root(),
            paths.logs_root(),
        ] {
            root.check(&path);
            fs::create_dir_all(path).unwrap();
        }
        for id in [A, B] {
            let project = paths.project_json(id);
            root.check(&project);
            fs::create_dir_all(project.parent().unwrap()).unwrap();
            fs::write(&project, PROJECT).unwrap();
            fs::write(
                project.parent().unwrap().join("scene.json"),
                "{\"objects\":[]}",
            )
            .unwrap();
        }
        let store = ConfigStore::open(paths.app_support_root());
        store.save_app_config(&app).unwrap();
        for id in [A, B] {
            store
                .save_wallpaper(&WallpaperConfig::new_for(id, "scene"))
                .unwrap();
        }
        let clock = Arc::new(AtomicU64::new(1_700_000_000_000));
        let now: Arc<dyn Fn() -> u64 + Send + Sync> = {
            let clock = clock.clone();
            Arc::new(move || clock.load(Ordering::Relaxed))
        };
        let build = crate::engine::build_stamp();
        let mut journal = LoadJournal::open_with(
            Some(store.root()),
            &build,
            now.clone(),
            Duration::from_secs(3600),
        );
        let mut prior_tickets = Vec::new();
        for owner in owners {
            for _ in 0..16 {
                if journal.held().contains(*owner) {
                    break;
                }
                prior_tickets.push(journal.begin(vec![(owner.to_string(), 1)]));
                journal = LoadJournal::open_with(
                    Some(store.root()),
                    &build,
                    now.clone(),
                    Duration::from_secs(3600),
                );
            }
            assert!(
                journal.held().contains(*owner),
                "genuine unfinished-session reopen guard exhausted"
            );
        }
        let engine = ControlledEngine::new(rows);
        let builder = BridgeBuilder::new(engine.clone())
            .with_config_store(store.clone())
            .with_paths(paths.clone())
            .with_launch_at_login(inert_login_controller(LaunchAtLoginStatus::Unavailable))
            .with_mouse_polling_enabled(false)
            .with_power_watching_enabled(false);
        let use_initial = !startup && (!remembered.is_empty() || !uncached.is_empty());
        let builder = if startup {
            builder
        } else if use_initial {
            let library = [A, B]
                .into_iter()
                .map(|id| BridgeWallpaperEntry {
                    id: id.into(),
                    title: format!("Independent {id}"),
                    kind: BridgeWallpaperKind::ProjectScene,
                    supported: true,
                    active: false,
                    selected: app.general.last_selected_wallpaper.as_deref() == Some(id),
                    preview_path: None,
                })
                .collect();
            let models = [A, B]
                .into_iter()
                .map(|id| {
                    (
                        id.to_owned(),
                        crate::project::ProjectModel::parse(id, PROJECT).unwrap(),
                    )
                })
                .collect();
            let wallpapers = [A, B]
                .into_iter()
                .filter(|id| !uncached.contains(id))
                .map(|id| (id.to_owned(), WallpaperConfig::new_for(id, "scene")))
                .collect();
            builder.with_state(initial_operation_state(
                app, library, models, wallpapers, remembered,
            ))
        } else {
            builder.with_state(BridgeActorState::from_app_config(app))
        };
        let bridge = with_journal(builder, journal).build().unwrap();
        let fixture = Self {
            bridge,
            engine,
            store,
            paths,
            root,
            clock,
            prior_tickets,
        };
        if !use_initial {
            for id in [A, B] {
                fixture
                    .handle()
                    .blocking_ask(InjectSceneProjectForTest {
                        id: id.into(),
                        title: format!("Independent {id}"),
                        project_json: PROJECT.into(),
                    })
                    .unwrap();
                fixture
                    .handle()
                    .blocking_ask(ReplaceWallpaperConfigForTest {
                        id: id.into(),
                        config: WallpaperConfig::new_for(id, "scene"),
                    })
                    .unwrap();
            }
        }
        fixture
    }
    fn handle(&self) -> BoundedHandle {
        BoundedHandle {
            actor: actor(&self.bridge).clone(),
            engine: self.engine.clone(),
        }
    }
    fn key(&self, live_id: u32) -> String {
        let rows = self.engine.display_rows();
        let index = rows
            .iter()
            .position(|row| row.desc.display_id == live_id)
            .expect("actual connected display");
        if index == 0 {
            "primary".into()
        } else {
            rows[index].connected_selector().id()
        }
    }
    fn snapshots(&self) -> BridgeSnapshotBundle {
        self.handle().blocking_ask(GetAllSnapshots).unwrap()
    }
    fn edit(&self, id: &str, value: f64) {
        self.handle()
            .blocking_ask(EditProperty {
                wallpaper_id: id.into(),
                property_id: "gain".into(),
                value: BridgePropertyValue::Number { value },
            })
            .unwrap();
    }
    fn select(&self, id: &str) {
        self.handle()
            .blocking_ask(SelectWallpaper { id: id.into() })
            .unwrap();
    }
    fn enable_draft(&self, id: &str, display: &str, enabled: bool) {
        self.handle()
            .blocking_ask(SetDisplayConfigEnabled {
                wallpaper_id: id.into(),
                display_id: display.into(),
                enabled,
            })
            .unwrap();
    }
    fn preview(&self, id: &str, value: f64) -> Result<(), BridgeError> {
        self.handle().blocking_ask(PreviewWallpaperProperties {
            wallpaper_id: id.into(),
            show: true,
            pending: vec![BridgePropertyEdit {
                property_id: "gain".into(),
                value: BridgePropertyValue::Number { value },
            }],
        })
    }
    fn start_apply(&self, id: &str, user: bool) -> Pending<BridgeWallpaperMutationBundle> {
        let handle = self.handle().clone();
        let wallpaper_id = id.to_owned();
        request(move || {
            handle.blocking_ask(ApplyWallpaperOptions {
                wallpaper_id,
                user_initiated: user,
            })
        })
    }
    fn start_mode(
        &self,
        id: &str,
        mode: BridgeDisplayMode,
    ) -> Pending<BridgeDisplayMutationBundle> {
        let handle = self.handle().clone();
        let display_id = id.to_owned();
        request(move || handle.blocking_ask(SetDisplayMode { display_id, mode }))
    }
    fn cancel(&self, id: &str) -> Result<BridgeWallpaperMutationBundle, BridgeError> {
        self.handle().blocking_ask(CancelWallpaperOptions {
            wallpaper_id: id.into(),
        })
    }
    fn app_bytes(&self) -> Vec<u8> {
        fs::read(self.store.root().join("config.toml")).unwrap()
    }
    fn wallpaper_bytes(&self, id: &str) -> Vec<u8> {
        fs::read(
            self.store
                .root()
                .join("wallpapers")
                .join(format!("{id}.json")),
        )
        .unwrap()
    }
    fn repairs_idle(&self) {
        let end = Instant::now() + DEADLINE;
        while !self.handle().blocking_ask(RepairsIdle).unwrap() {
            assert!(
                Instant::now() < end,
                "receiving-side repair settlement exceeded deadline"
            );
            thread::sleep(QUANTUM);
        }
        self.snapshots();
    }
    fn successful_apply(&self, id: &str, handles: &[(u32, u64)]) -> Vec<SceneDesc> {
        let gate = self
            .engine
            .hold_next_reconcile(Ok(handles.iter().map(|(d, h)| result(*d, *h)).collect()));
        let reply = self.start_apply(id, true);
        let receipt = entered(gate);
        let scenes = receipt.scenes.clone();
        receipt.release();
        reply
            .finish(
                &self.engine,
                &handles
                    .iter()
                    .map(|(_, h)| SceneHandle::new(*h))
                    .collect::<Vec<_>>(),
            )
            .unwrap();
        self.repairs_idle();
        scenes
    }
    fn count(&self, predicate: impl Fn(&EngineObservation) -> bool) -> usize {
        self.engine
            .observations()
            .iter()
            .filter(|observation| predicate(observation))
            .count()
    }
}

fn property(options: &BridgeWallpaperOptionsSnapshot) -> f64 {
    match &options
        .properties
        .iter()
        .find(|p| p.id == "gain")
        .unwrap()
        .value
    {
        BridgePropertyValue::Number { value } => *value,
        other => panic!("unexpected scalar projection: {other:?}"),
    }
}
fn row(settings: &BridgeSettingsSnapshot, id: &str) -> BridgeDisplaySettingsRow {
    settings
        .displays
        .iter()
        .find(|row| row.display_id == id)
        .unwrap()
        .clone()
}
fn started_reconciles(engine: &ControlledEngine) -> usize {
    engine
        .observations()
        .iter()
        .filter(|o| {
            matches!(
                o,
                EngineObservation::Reconcile {
                    phase: OperationPhase::Started,
                    ..
                }
            )
        })
        .count()
}

#[tokio::test]
async fn apply_commits_requested_wallpaper_without_changing_selection_and_is_responsive() {
    let f = Fixture::new(
        AppConfig::default(),
        vec![empty_row(1, 60), empty_row(2, 144)],
    );
    f.select(B);
    f.edit(A, 0.6);
    f.enable_draft(A, "2", true);
    let old_app = f.app_bytes();
    let gate = f.engine.hold_next_reconcile(Ok(vec![result(2, 1002)]));
    let pending = f.start_apply(A, true);
    let receipt = entered(gate);
    assert_eq!(receipt.scenes.len(), 1);
    assert_eq!(receipt.scenes[0].display.display_id, 2);
    assert_eq!(f.snapshots().app.selected_wallpaper_id.as_deref(), Some(B));
    pending.is_pending();
    assert_eq!(f.app_bytes(), old_app);
    receipt.release();
    let reply = pending
        .finish(&f.engine, &[SceneHandle::new(1002)])
        .unwrap();
    assert_eq!(reply.app.selected_wallpaper_id.as_deref(), Some(B));
    assert_eq!(reply.wallpaper_options.wallpaper_id, A);
    assert_eq!(property(&reply.wallpaper_options), 0.6);
    assert!(!reply.wallpaper_options.dirty);
    assert_eq!(reply.app.active_wallpaper_ids, vec![A.to_owned()]);
    assert_ne!(f.app_bytes(), old_app);
    assert_eq!(
        f.store.load_wallpaper(A).unwrap().property_overrides["gain"].as_f64(),
        Some(0.6)
    );
    f.repairs_idle();
    f.close().await;
}

#[tokio::test]
async fn unknown_apply_is_early_invalid_input_without_saves_or_engine_work() {
    let f = Fixture::new(configured(), vec![empty_row(1, 60)]);
    let disk = f.app_bytes();
    let baseline = f.wallpaper_bytes(A);
    f.edit(A, 0.62);
    let gate = f.engine.hold_next_reconcile(Ok(vec![result(1, 5701)]));
    let earlier = f.start_apply(A, true);
    let work = entered(gate);
    let error = f
        .start_apply("missing-member", true)
        .finish(&f.engine, &[])
        .unwrap_err();
    assert_eq!(error.kind(), BridgeErrorKind::InvalidInput);
    assert_eq!(
        started_reconciles(&f.engine),
        1,
        "unknown member adds no engine work"
    );
    assert_eq!(f.app_bytes(), disk);
    assert_eq!(f.wallpaper_bytes(A), baseline);
    work.release();
    let reply = earlier
        .finish(&f.engine, &[SceneHandle::new(5701)])
        .unwrap();
    assert!(
        !reply.wallpaper_options.dirty,
        "early refusal must not supersede an already reserved valid Apply"
    );
    assert_eq!(
        f.store.load_wallpaper(A).unwrap().property_overrides["gain"].as_f64(),
        Some(0.62)
    );
    f.repairs_idle();
    f.close().await;
}

#[tokio::test]
async fn display_preparation_refusals_do_not_delegate_or_save() {
    let f = Fixture::new(configured(), vec![empty_row(1, 60)]);
    let disk = f.app_bytes();
    for error in [
        f.handle()
            .blocking_ask::<_, BridgeDisplayMutationBundle>(SetDisplayMode {
                display_id: "primary".into(),
                mode: BridgeDisplayMode::Mirror,
            })
            .unwrap_err(),
        f.handle()
            .blocking_ask::<_, BridgeDisplayMutationBundle>(SetDisplayMode {
                display_id: "1".into(),
                mode: BridgeDisplayMode::Mirror,
            })
            .unwrap_err(),
        f.handle()
            .blocking_ask::<_, BridgeDisplayMutationBundle>(SetDisplayEnabled {
                display_id: "not-a-display".into(),
                enabled: false,
            })
            .unwrap_err(),
        f.handle()
            .blocking_ask::<_, BridgeDisplayMutationBundle>(EjectWallpaperFromDisplay {
                display_id: "primary".into(),
                wallpaper_id: B.into(),
            })
            .unwrap_err(),
    ] {
        assert_eq!(error.kind(), BridgeErrorKind::InvalidInput);
    }
    assert_eq!(started_reconciles(&f.engine), 0);
    assert_eq!(f.app_bytes(), disk);
    f.repairs_idle();
    f.close().await;
}

#[tokio::test]
async fn immediate_mirror_value_validation_precedes_unknown_display_lookup() {
    let f = Fixture::new(mirrored(), vec![empty_row(1, 60), empty_row(2, 144)]);
    let disk = f.app_bytes();
    let factor_lookup = f
        .handle()
        .blocking_ask::<_, BridgeDisplayMutationBundle>(SetMirrorScalingFactor {
            display_id: "absent".into(),
            factor: 0.8,
        })
        .unwrap_err();
    let volume_lookup = f
        .handle()
        .blocking_ask::<_, BridgeDisplayMutationBundle>(SetMirrorVolume {
            display_id: "absent".into(),
            volume: 0.5,
        })
        .unwrap_err();
    assert_eq!(factor_lookup.kind(), BridgeErrorKind::InvalidInput);
    assert_eq!(volume_lookup.kind(), BridgeErrorKind::InvalidInput);
    for factor in [f64::NAN, f64::INFINITY, 0.0, -1.0] {
        let genuine_value_error = f
            .handle()
            .blocking_ask::<_, BridgeDisplayMutationBundle>(SetMirrorScalingFactor {
                display_id: "2".into(),
                factor,
            })
            .unwrap_err();
        let unknown_source_error = f
            .handle()
            .blocking_ask::<_, BridgeDisplayMutationBundle>(SetMirrorScalingFactor {
                display_id: "absent".into(),
                factor,
            })
            .unwrap_err();
        assert_eq!(genuine_value_error.kind(), BridgeErrorKind::InvalidInput);
        assert_eq!(
            error_pair(&unknown_source_error),
            error_pair(&genuine_value_error)
        );
        assert_ne!(
            error_pair(&unknown_source_error),
            error_pair(&factor_lookup)
        );
    }
    for volume in [f32::NAN, -0.1, 1.1] {
        let genuine_value_error = f
            .handle()
            .blocking_ask::<_, BridgeDisplayMutationBundle>(SetMirrorVolume {
                display_id: "2".into(),
                volume,
            })
            .unwrap_err();
        let unknown_source_error = f
            .handle()
            .blocking_ask::<_, BridgeDisplayMutationBundle>(SetMirrorVolume {
                display_id: "absent".into(),
                volume,
            })
            .unwrap_err();
        assert_eq!(genuine_value_error.kind(), BridgeErrorKind::InvalidInput);
        assert_eq!(
            error_pair(&unknown_source_error),
            error_pair(&genuine_value_error)
        );
        assert_ne!(
            error_pair(&unknown_source_error),
            error_pair(&volume_lookup)
        );
    }
    assert_eq!(f.app_bytes(), disk);
    assert_eq!(
        f.count(|observation| matches!(
            observation,
            EngineObservation::ScalingFactor {
                phase: OperationPhase::Started,
                ..
            } | EngineObservation::Volume {
                phase: OperationPhase::Started,
                ..
            }
        )),
        0
    );
    assert_eq!(started_reconciles(&f.engine), 0);
    f.close().await;
}

#[tokio::test]
async fn partial_core_and_actual_prune_error_precedence_preserve_live_effects() {
    for prune_fault in [false, true] {
        let mut app = configured();
        app.monitors.push(assignment(connected(2), Some(A)));
        let f = Fixture::new(app, vec![empty_row(1, 60), empty_row(2, 144)]);
        f.edit(A, 0.3);
        let baseline = f.successful_apply(A, &[(1, 2001), (2, 2003)]);
        let retained_capture = f.engine.audio_capture_state(SceneHandle::new(2001));
        assert!(retained_capture.is_some());
        assert!(
            f.engine
                .audio_capture_state(SceneHandle::new(2003))
                .is_some()
        );
        let old_disk = f.wallpaper_bytes(A);
        let before = f.engine.observations().len();
        let mut partial_rows = f.engine.display_rows();
        for (row, scene) in partial_rows.iter_mut().zip(&baseline) {
            let mut changed = scene.clone();
            changed.property_override_json = Some("{\"gain\":0.8}".into());
            row.assignment = Some(WallpaperAssignment::Direct(SceneTemplate::from_scene_desc(
                &changed,
            )));
            if row.desc.display_id == 2 {
                row.handle = Some(SceneHandle::new(2002));
            }
        }
        f.edit(A, 0.8);
        let core = EngineError::Render("partial core boundary".into());
        let core_text = core.to_string();
        let gate = f.engine.hold_next_partial_reconcile(partial_rows, core);
        if prune_fault {
            f.engine
                .fail_next_prune_after_pruning("prune boundary".into());
        }
        let ordinary = f.start_apply(A, true);
        let work = entered(gate);
        let repair = f.engine.hold_next_reconcile(Err(EngineError::Render(
            "independent repair boundary".into(),
        )));
        work.release();
        let expected = if prune_fault {
            EngineError::Platform("prune boundary".into()).to_string()
        } else {
            core_text
        };
        assert_error(
            ordinary.finish(&f.engine, &[]).unwrap_err(),
            BridgeErrorKind::Engine,
            &expected,
        );
        let restoring = entered(repair);
        assert_eq!(
            restoring.scenes[0].property_override_json,
            baseline[0].property_override_json
        );
        assert_eq!(
            f.engine
                .display_rows()
                .iter()
                .find(|row| row.desc.display_id == 2)
                .unwrap()
                .handle,
            Some(SceneHandle::new(2002))
        );
        assert!(
            f.engine
                .live_scene_controls(SceneHandle::new(2003))
                .is_none()
        );
        assert!(
            f.engine
                .audio_capture_state(SceneHandle::new(2003))
                .is_none()
        );
        assert_eq!(
            f.engine.audio_capture_state(SceneHandle::new(2001)),
            retained_capture,
            "actual prune retains the still-live capture owner even before injected rejection"
        );
        assert!(
            f.engine
                .live_scene_controls(SceneHandle::new(2001))
                .is_some()
        );
        assert!(
            f.engine
                .live_scene_controls(SceneHandle::new(2002))
                .is_some()
        );
        assert_eq!(f.wallpaper_bytes(A), old_disk);
        let observed = f.engine.observations();
        let tail = &observed[before..];
        let core_rejected = tail
            .iter()
            .position(|o| {
                matches!(
                    o,
                    EngineObservation::ReconcileCore {
                        phase: OperationPhase::Rejected
                    }
                )
            })
            .unwrap();
        let pruned = tail
            .iter()
            .position(|o| {
                matches!(
                    o,
                    EngineObservation::ReconcilePrune {
                        phase: OperationPhase::Applied | OperationPhase::Rejected
                    }
                )
            })
            .unwrap();
        assert!(core_rejected < pruned);
        assert!(!tail.iter().any(|o| matches!(
            o,
            EngineObservation::Volume {
                phase: OperationPhase::Started,
                ..
            } | EngineObservation::Muted {
                phase: OperationPhase::Started,
                ..
            } | EngineObservation::AudioResponse {
                phase: OperationPhase::Started,
                ..
            } | EngineObservation::Capture {
                phase: OperationPhase::Started,
                ..
            } | EngineObservation::RenderScale {
                phase: OperationPhase::Started,
                ..
            }
        )));
        assert_eq!(
            f.snapshots().app.errors.last().map(String::as_str),
            Some(expected.as_str())
        );
        restoring.release();
        f.repairs_idle();
        let errors = f.snapshots().app.errors;
        assert_eq!(
            errors
                .iter()
                .filter(|message| **message == expected)
                .count(),
            1
        );
        assert_eq!(
            errors.last().unwrap(),
            &engine_boundary("independent repair boundary")
        );
        f.close().await;
    }
}

#[tokio::test]
async fn successful_core_with_prune_failure_skips_all_poststeps() {
    let f = Fixture::new(configured(), vec![empty_row(1, 60)]);
    f.edit(A, 0.7);
    let ordinary_gate = f.engine.hold_next_reconcile(Ok(vec![result(1, 2101)]));
    f.engine
        .fail_next_prune_after_pruning("successful-core prune failure".into());
    let ordinary = f.start_apply(A, true);
    let work = entered(ordinary_gate);
    let repair_gate = f
        .engine
        .hold_next_reconcile(Err(EngineError::Render("repair stops".into())));
    work.release();
    assert_error(
        ordinary.finish(&f.engine, &[]).unwrap_err(),
        BridgeErrorKind::Engine,
        &EngineError::Platform("successful-core prune failure".into()).to_string(),
    );
    let repair = entered(repair_gate);
    assert!(
        f.engine
            .live_scene_controls(SceneHandle::new(2101))
            .is_some()
    );
    assert_eq!(
        f.count(|o| matches!(
            o,
            EngineObservation::Volume {
                phase: OperationPhase::Started,
                ..
            }
        )),
        0
    );
    repair.release();
    f.repairs_idle();
    f.close().await;
}

#[tokio::test]
async fn selected_real_poststep_errors_stop_later_steps_after_observable_mutation() {
    for (which, setter) in [
        (0, SelectedSetter::Volume),
        (1, SelectedSetter::Muted),
        (2, SelectedSetter::AudioResponse),
        (3, SelectedSetter::AudioCapture),
    ] {
        let f = Fixture::new(AppConfig::default(), vec![empty_row(1, 60)]);
        let mut saved = WallpaperConfig::new_for(A, "scene");
        saved.audio.volume = 0.37;
        saved.audio.muted = true;
        saved.audio.response_enabled = false;
        f.handle()
            .blocking_ask(ReplaceWallpaperConfigForTest {
                id: A.into(),
                config: saved,
            })
            .unwrap();
        f.select(A);
        f.enable_draft(A, "primary", true);
        f.edit(A, 0.55);
        let handle = SceneHandle::new(2200 + which);
        let gate = f
            .engine
            .hold_next_reconcile(Ok(vec![SceneResult::new(1, handle, 0)]));
        f.engine.fail_selected_setter(
            setter,
            handle,
            1,
            FaultTiming::AfterMutation,
            EngineError::Render(format!("selected poststep {which}")),
        );
        let pending = f.start_apply(A, true);
        let work = entered(gate);
        assert_eq!(f.in_flight().len(), 1);
        assert!(
            f.in_flight()[0].get("settled_until").is_none()
                || f.in_flight()[0]["settled_until"].is_null()
        );
        let repair_gate = f
            .engine
            .hold_next_reconcile(Err(EngineError::Render("repair terminal".into())));
        work.release();
        wait_live(&f.engine, &[handle]);
        f.engine.require_audio(handle, true);
        assert_error(
            pending.finish(&f.engine, &[handle]).unwrap_err(),
            BridgeErrorKind::Engine,
            &engine_boundary(&format!("selected poststep {which}")),
        );
        let repair = entered(repair_gate);
        assert!(repair.scenes.is_empty());
        assert!(
            f.in_flight().is_empty(),
            "reported poststep failure removes the attempt, not succeeds it"
        );
        assert!(
            f.journal().strikes().is_empty(),
            "reported failure is not a crash strike"
        );
        let observations = f.engine.observations();
        let rejected = observations
            .iter()
            .position(|o| match o {
                EngineObservation::Volume {
                    handle: h,
                    phase: OperationPhase::Rejected,
                    ..
                } => which == 0 && *h == handle,
                EngineObservation::Muted {
                    handle: h,
                    phase: OperationPhase::Rejected,
                    ..
                } => which == 1 && *h == handle,
                EngineObservation::AudioResponse {
                    handle: h,
                    phase: OperationPhase::Rejected,
                    ..
                } => which == 2 && *h == handle,
                EngineObservation::Capture {
                    handle: h,
                    phase: OperationPhase::Rejected,
                    ..
                } => which == 3 && *h == handle,
                _ => false,
            })
            .expect("real selected poststep rejection");
        assert!(!observations[rejected + 1..].iter().any(|o| matches!(o,
            EngineObservation::RenderScale { handle: h, phase: OperationPhase::Started, .. } if *h == handle)));
        assert!(!observations[rejected + 1..].iter().any(|o| match o {
            EngineObservation::Muted {
                handle: h,
                phase: OperationPhase::Started,
                ..
            } => which < 1 && *h == handle,
            EngineObservation::AudioResponse {
                handle: h,
                phase: OperationPhase::Started,
                ..
            } => which < 2 && *h == handle,
            EngineObservation::Capture {
                handle: h,
                phase: OperationPhase::Started,
                ..
            } => which < 3 && *h == handle,
            _ => false,
        }));
        let controls = f.engine.live_scene_controls(handle).unwrap();
        if which == 0 {
            assert_eq!(f32::from(controls.audio_volume), 0.37);
        }
        if which == 1 {
            assert!(controls.audio_muted);
        }
        if which == 2 {
            assert!(!controls.audio_response_enabled);
        }
        if which == 3 {
            assert!(f.engine.audio_capture_state(handle).is_some());
        }
        assert!(f.snapshots().wallpaper_options.unwrap().dirty);
        repair.release();
        f.repairs_idle();
        f.close().await;
    }
}

#[tokio::test]
async fn shaped_missing_and_duplicate_results_use_coherent_live_rows_and_once_per_display_poststeps()
 {
    for duplicate in [false, true] {
        let mut app = configured();
        app.monitors.push(assignment(connected(2), Some(A)));
        let f = Fixture::new(app, vec![empty_row(1, 60), empty_row(2, 144)]);
        f.edit(A, 0.42);
        let shape = if duplicate {
            ReconcileResultShape::DuplicateDisplay(2)
        } else {
            ReconcileResultShape::MissingDisplay(2)
        };
        let gate = f
            .engine
            .hold_next_reconcile_with_result_shape(vec![result(1, 2301), result(2, 2302)], shape);
        let pending = f.start_apply(A, true);
        let receipt = entered(gate);
        assert_eq!(receipt.scenes.len(), 2);
        receipt.release();
        let reply = pending
            .finish(&f.engine, &[SceneHandle::new(2301), SceneHandle::new(2302)])
            .unwrap();
        f.repairs_idle();
        assert_eq!(
            f.engine
                .display_rows()
                .iter()
                .filter(|row| row.handle.is_some())
                .count(),
            2
        );
        assert_eq!(reply.app.active_wallpaper_ids, vec![A.to_owned()]);
        assert!(!reply.wallpaper_options.dirty);
        for (handle, expected) in [
            (SceneHandle::new(2301), 1),
            (SceneHandle::new(2302), usize::from(duplicate)),
        ] {
            assert_eq!(f.count(|o| matches!(o,
                EngineObservation::Volume { handle: h, phase: OperationPhase::Started, .. } if *h == handle)), expected);
            assert_eq!(f.count(|o| matches!(o,
                EngineObservation::Muted { handle: h, phase: OperationPhase::Started, .. } if *h == handle)), expected);
        }
        f.close().await;
    }
}

#[tokio::test]
async fn preview_refusal_invalidates_confirmation_for_both_retry_and_restore_a() {
    for retry_b in [false, true] {
        let f = Fixture::new(configured(), vec![empty_row(1, 60)]);
        f.edit(A, 0.3);
        f.successful_apply(A, &[(1, 2401)]);
        let handle = SceneHandle::new(2401);
        let confirmed = f.engine.shown_property_state(handle).unwrap();
        assert!(confirmed.flat_json.is_some());
        f.preview(A, 0.45).unwrap();
        let a = f
            .engine
            .shown_property_state(handle)
            .unwrap()
            .flat_json
            .unwrap();
        f.engine
            .fail_next_property_preview(EngineError::Render("preview B refusal".into()));
        assert_error(
            f.preview(A, 0.7).unwrap_err(),
            BridgeErrorKind::Engine,
            &engine_boundary("preview B refusal"),
        );
        assert!(f.engine.display_rows()[0].handle.is_some());
        assert!(
            f.engine.shown_property_state(handle).is_none(),
            "refusal invalidates all confirmation"
        );
        let before = f.engine.observations().len();
        f.preview(A, if retry_b { 0.7 } else { 0.45 }).unwrap();
        let observations = f.engine.observations();
        let tail = &observations[before..];
        assert_eq!(tail.iter().filter(|o| matches!(o,
            EngineObservation::PropertyPreview { handle: h, phase: PropertyPreviewPhase::Attempted, .. } if *h == handle)).count(), 1);
        assert!(!tail.iter().any(|o| matches!(
            o,
            EngineObservation::PropertyPreview {
                phase: PropertyPreviewPhase::Unchanged,
                ..
            }
        )));
        if !retry_b {
            assert_eq!(
                f.engine
                    .shown_property_state(handle)
                    .unwrap()
                    .flat_json
                    .as_deref(),
                Some(a.as_str())
            );
        }
        f.close().await;
    }
}

struct SaveObstruction {
    destination: PathBuf,
    backup: PathBuf,
}
impl SaveObstruction {
    fn new(f: &Fixture, wallpaper: bool) -> Self {
        let destination = if wallpaper {
            f.store.root().join("wallpapers").join(format!("{A}.json"))
        } else {
            f.store.root().join("config.toml")
        };
        f.root.check(&destination);
        let backup = destination.with_extension("owned-prior");
        fs::rename(&destination, &backup).unwrap();
        fs::create_dir(&destination).unwrap();
        Self {
            destination,
            backup,
        }
    }
}
impl Drop for SaveObstruction {
    fn drop(&mut self) {
        fs::remove_dir(&self.destination).expect("remove owned save obstruction");
        fs::rename(&self.backup, &self.destination).expect("restore owned prior bytes");
    }
}

#[tokio::test]
async fn reconciled_apply_save_failures_publish_actual_desktop_but_keep_property_baseline_retryable()
 {
    for wallpaper_save in [false, true] {
        let f = Fixture::new(configured(), vec![empty_row(1, 60), empty_row(2, 144)]);
        f.edit(A, 0.3);
        f.successful_apply(A, &[(1, 2500)]);
        f.edit(A, 0.64);
        f.preview(A, 0.64).unwrap();
        assert!(f.preview_mark());
        f.enable_draft(A, "primary", false);
        f.enable_draft(A, "2", true);
        let old_app = f.app_bytes();
        let old_wallpaper = f.wallpaper_bytes(A);
        let obstruction = SaveObstruction::new(&f, wallpaper_save);
        let expected = if wallpaper_save {
            f.store
                .save_wallpaper(&WallpaperConfig::new_for(A, "scene"))
        } else {
            f.store.save_app_config(&AppConfig::default())
        }
        .unwrap_err();
        let gate = f.engine.hold_next_reconcile(Ok(vec![result(2, 2501)]));
        let pending = f.start_apply(A, true);
        entered(gate).release();
        let error = pending
            .finish(&f.engine, &[SceneHandle::new(2501)])
            .unwrap_err();
        assert_eq!(error_pair(&error), error_pair(&expected));
        let snapshots = f.snapshots();
        assert_eq!(snapshots.app.active_wallpaper_ids, vec![A.to_owned()]);
        assert!(
            snapshots
                .monitor_information
                .rows
                .iter()
                .any(|row| row.wallpaper_id == A)
        );
        assert!(
            snapshots
                .monitor_information
                .rows
                .iter()
                .any(|row| row.display_id == f.key(2) && row.wallpaper_id == A)
        );
        assert!(
            !f.preview_mark(),
            "engine success/save error forgets superseded unsaved property preview"
        );
        let draft = f.draft(A);
        assert_eq!(draft.saved.property_overrides["gain"].as_f64(), Some(0.3));
        assert_eq!(
            draft.published.unwrap().property_overrides["gain"].as_f64(),
            Some(0.3)
        );
        assert_eq!(
            draft.pending.property_overrides["gain"].as_f64(),
            Some(0.64)
        );
        let options = snapshots.wallpaper_options.unwrap();
        assert!(options.dirty);
        assert_eq!(property(&options), 0.64);
        assert!(
            snapshots.app.errors.is_empty(),
            "save errors are not reconcile errors"
        );
        assert_eq!(started_reconciles(&f.engine), 2);
        if wallpaper_save {
            assert_ne!(f.app_bytes(), old_app);
        }
        drop(obstruction);
        assert_eq!(f.wallpaper_bytes(A), old_wallpaper);
        if !wallpaper_save {
            assert_eq!(f.app_bytes(), old_app);
        }
        f.repairs_idle();
        let retry_gate = f.engine.hold_next_reconcile(Ok(vec![result(2, 2502)]));
        let retry = f.start_apply(A, true);
        entered(retry_gate).release();
        let accepted = retry.finish(&f.engine, &[SceneHandle::new(2502)]).unwrap();
        assert!(!accepted.wallpaper_options.dirty);
        assert_eq!(
            f.store.load_wallpaper(A).unwrap().property_overrides["gain"].as_f64(),
            Some(0.64)
        );
        f.repairs_idle();
        f.close().await;
    }
}

#[tokio::test]
async fn display_save_failure_has_no_apply_publication_exception_and_no_automatic_repair() {
    let mut app = configured();
    app.monitors.push(assignment(connected(2), None));
    let f = Fixture::new(app, vec![empty_row(1, 60), empty_row(2, 144)]);
    let before = f.snapshots();
    let obstruction = SaveObstruction::new(&f, false);
    let expected = f.store.save_app_config(&AppConfig::default()).unwrap_err();
    let gate = f
        .engine
        .hold_next_reconcile(Ok(vec![result(1, 2601), result(2, 2602)]));
    let pending = f.start_mode("2", BridgeDisplayMode::Mirror);
    entered(gate).release();
    let error = pending
        .finish(&f.engine, &[SceneHandle::new(2601), SceneHandle::new(2602)])
        .unwrap_err();
    assert_eq!(error_pair(&error), error_pair(&expected));
    let after = f.snapshots();
    assert_eq!(after.settings.displays, before.settings.displays);
    assert_eq!(
        after.app.active_wallpaper_ids,
        before.app.active_wallpaper_ids
    );
    assert!(after.app.errors.is_empty());
    assert!(
        f.engine
            .display_rows()
            .iter()
            .any(|row| row.handle == Some(SceneHandle::new(2602)))
    );
    f.repairs_idle();
    assert_eq!(started_reconciles(&f.engine), 1);
    drop(obstruction);
    f.close().await;
}

#[tokio::test]
async fn stale_apply_keeps_new_edits_and_preview_while_preview_alone_does_not_stale() {
    for mutation in 0..5 {
        let invalidate = mutation != 0;
        let f = Fixture::new(configured(), vec![empty_row(1, 60)]);
        f.edit(A, 0.3);
        f.successful_apply(A, &[(1, 2701)]);
        f.edit(A, 0.5);
        let old_disk = f.wallpaper_bytes(A);
        let gate = f.engine.hold_next_reconcile(Ok(vec![result(1, 2702)]));
        let pending = f.start_apply(A, true);
        let receipt = entered(gate);
        match mutation {
            0 => {}
            1 => f.edit(A, 0.9),
            2 => f.select(B),
            3 => {
                f.handle()
                    .blocking_ask(SetFilter {
                        kind: BridgeWallpaperKind::ProjectScene,
                        enabled: false,
                    })
                    .unwrap();
            }
            4 => {
                f.handle()
                    .blocking_ask(SetAudioSuppressed { suppressed: true })
                    .unwrap();
            }
            _ => unreachable!(),
        }
        f.preview(A, 0.9).unwrap();
        let repair_gate = if invalidate {
            Some(
                f.engine
                    .hold_next_reconcile(Err(EngineError::Render("stale repair terminal".into()))),
            )
        } else {
            None
        };
        receipt.release();
        let reply = pending
            .finish(&f.engine, &[SceneHandle::new(2702)])
            .unwrap();
        if invalidate {
            assert_eq!(
                property(&reply.wallpaper_options),
                if mutation == 1 { 0.9 } else { 0.5 }
            );
            assert!(reply.wallpaper_options.dirty);
            assert_eq!(f.wallpaper_bytes(A), old_disk);
            assert_eq!(reply.wallpaper_options.wallpaper_id, A);
            assert!(
                f.preview_mark(),
                "stale success cannot clear newer preview membership"
            );
            if mutation == 2 {
                assert_eq!(reply.app.selected_wallpaper_id.as_deref(), Some(B));
            }
            let repair = entered(repair_gate.unwrap());
            assert_eq!(
                json_gain(&repair.scenes[0].property_override_json),
                Some(0.3)
            );
            if mutation == 4 {
                assert!(
                    repair.scenes[0].audio_muted,
                    "repair captures current suppression policy"
                );
            }
            repair.release();
        } else {
            assert_eq!(property(&reply.wallpaper_options), 0.5);
            assert!(!reply.wallpaper_options.dirty);
            assert_ne!(f.wallpaper_bytes(A), old_disk);
            assert!(!f.preview_mark());
        }
        f.repairs_idle();
        f.close().await;
    }
}

#[tokio::test]
async fn library_disappearance_during_apply_returns_real_required_options_failure() {
    let f = Fixture::new(reduced(), vec![empty_row(1, 60)]);
    f.select(A);
    f.edit(A, 0.77);
    let disk = f.wallpaper_bytes(A);
    let (pending, work) = f.parked_apply(A, &[(1, 2801)]);
    let owned_project = f.paths.project_json(A);
    let owned_wallpaper = owned_project.parent().unwrap();
    f.root.check(owned_wallpaper);
    let disappeared = f.root.0.join("removed-owned-wallpaper");
    fs::rename(owned_wallpaper, &disappeared).unwrap();
    f.handle().blocking_ask(RefreshLibrary).unwrap();
    let scanned = f.snapshots();
    assert!(!scanned.library.wallpapers.iter().any(|entry| entry.id == A));
    assert_eq!(scanned.app.selected_wallpaper_id, None);
    let required_error = f
        .handle()
        .blocking_ask(GetWallpaperOptionsSnapshot {
            wallpaper_id: A.into(),
        })
        .unwrap_err();
    let repair_gate = f.engine.hold_next_reconcile(Ok(vec![]));
    work.release();
    let error = pending.finish(&f.engine, &[]).unwrap_err();
    assert_eq!(error.kind(), BridgeErrorKind::InvalidInput);
    assert_eq!(error_pair(&error), error_pair(&required_error));
    assert_eq!(f.wallpaper_bytes(A), disk);
    let repair = entered(repair_gate);
    assert!(repair.scenes.is_empty());
    repair.release();
    f.repairs_idle();
    assert!(
        f.snapshots().wallpaper_options.is_none(),
        "the successful disappearance scan clears missing selection"
    );
    f.close().await;
}

#[tokio::test]
async fn two_reservations_both_completion_orders_never_publish_superseded_candidates() {
    for newer_first in [false, true] {
        for newest_stale in [false, true] {
            let f = Fixture::new(reduced(), vec![empty_row(1, 60)]);
            f.edit(A, 0.4);
            let (a, work_a) = f.parked_apply(A, &[(1, 2901)]);
            f.edit(A, 0.8);
            let (b, work_b) = f.parked_apply(A, &[(1, 2902)]);
            if newest_stale {
                f.edit(A, 0.95);
            }
            let repair_gate = f
                .engine
                .hold_next_reconcile(Err(EngineError::Render("ordered repair terminal".into())));
            if newer_first {
                work_b.release();
                let reply_b = b.finish(&f.engine, &[SceneHandle::new(2902)]).unwrap();
                assert_eq!(
                    property(&reply_b.wallpaper_options),
                    if newest_stale { 0.95 } else { 0.8 }
                );
                work_a.release();
                let reply_a = a.finish(&f.engine, &[SceneHandle::new(2901)]).unwrap();
                assert_eq!(
                    property(&reply_a.wallpaper_options),
                    if newest_stale { 0.95 } else { 0.8 }
                );
            } else {
                work_a.release();
                let reply_a = a.finish(&f.engine, &[SceneHandle::new(2901)]).unwrap();
                assert_eq!(
                    property(&reply_a.wallpaper_options),
                    if newest_stale { 0.95 } else { 0.8 }
                );
                b.is_pending();
                assert_eq!(
                    started_reconciles(&f.engine),
                    2,
                    "stale older success defers behind unfinished newest"
                );
                work_b.release();
                b.finish(&f.engine, &[SceneHandle::new(2902)]).unwrap();
            }
            let repair = entered(repair_gate);
            let saved = f.store.load_wallpaper(A).unwrap();
            assert_eq!(
                saved
                    .property_overrides
                    .get("gain")
                    .and_then(|v| v.as_f64()),
                if newest_stale { None } else { Some(0.8) }
            );
            assert_ne!(
                saved
                    .property_overrides
                    .get("gain")
                    .and_then(|v| v.as_f64()),
                Some(0.4)
            );
            if newest_stale {
                assert_eq!(repair.scenes[0].property_override_json, None);
            } else {
                assert_eq!(
                    json_gain(&repair.scenes[0].property_override_json),
                    Some(0.8)
                );
            }
            let followup = if newer_first && newest_stale {
                Some(f.engine.hold_next_reconcile(Err(EngineError::Render(
                    "coalesced ordered repair".into(),
                ))))
            } else {
                None
            };
            repair.release();
            if let Some(followup) = followup {
                entered(followup).release();
            }
            f.repairs_idle();
            f.close().await;
        }
    }
}

fn mirrored() -> AppConfig {
    let mut app = configured();
    app.monitors.push(MonitorCfg {
        selector: connected(2),
        enabled: true,
        mode: "mirror".into(),
        wallpaper: None,
        mirror_target: Some(SerializedSelector::Primary),
    });
    app
}

#[tokio::test]
async fn mirror_follow_uses_own_refresh_then_live_cap_in_both_refresh_arrangements() {
    for (primary_hz, mirror_hz) in [(60, 144), (144, 60)] {
        let mut app = mirrored();
        app.quality.frame_rate_cap = Some(90);
        let f = Fixture::new(app, vec![empty_row(1, primary_hz), empty_row(2, mirror_hz)]);
        f.edit(A, 0.3);
        let consumed = f.successful_apply(A, &[(1, 3001), (2, 3002)]);
        assert_eq!(
            consumed
                .iter()
                .find(|scene| scene.display.display_id == 1)
                .unwrap()
                .fps,
            primary_hz.min(60).min(90).max(1)
        );
        assert_eq!(
            consumed
                .iter()
                .find(|scene| scene.display.display_id == 2)
                .unwrap()
                .fps,
            mirror_hz.min(60).min(90).max(1)
        );
        assert!(consumed.iter().all(|scene| !scene.audio_muted));
        let reply = f
            .handle()
            .blocking_ask::<_, BridgeDisplayMutationBundle>(SetMirrorTargetFps {
                display_id: "2".into(),
                fps: mirror_hz,
            })
            .unwrap();
        let saved = f.store.load().unwrap().config;
        let settings = saved
            .monitor_settings
            .iter()
            .find(|entry| entry.selector == connected(2))
            .unwrap();
        assert_eq!(
            settings.frame_rate,
            if mirror_hz > 60 {
                Some(mirror_hz)
            } else {
                None
            },
            "144 is an explicit own-native preference; 60 retains the accepted default/follow representation"
        );
        assert_eq!(row(&reply.settings, &f.key(2)).max_fps, mirror_hz);
        assert!(f.engine.observations().iter().any(|o| matches!(o,
            EngineObservation::Fps { handle, fps, phase: OperationPhase::Applied }
                if *handle == SceneHandle::new(3002) && *fps == mirror_hz.min(90))));
        f.edit(A, 0.31);
        let explicit = f.successful_apply(A, &[(1, 3003), (2, 3004)]);
        assert_eq!(
            explicit
                .iter()
                .find(|scene| scene.display.display_id == 1)
                .unwrap()
                .fps,
            primary_hz.min(60).min(90).max(1)
        );
        assert_eq!(
            explicit
                .iter()
                .find(|scene| scene.display.display_id == 2)
                .unwrap()
                .fps,
            mirror_hz.min(90).max(1),
            "the actual worker consumes the mirror's explicit own-native preference under the live cap"
        );
        let before = f.count(|o| {
            matches!(
                o,
                EngineObservation::Fps {
                    phase: OperationPhase::Started,
                    ..
                }
            )
        });
        f.handle()
            .blocking_ask::<_, BridgeDisplayMutationBundle>(SetMirrorTargetFps {
                display_id: "2".into(),
                fps: mirror_hz,
            })
            .unwrap();
        assert_eq!(
            f.count(|o| matches!(
                o,
                EngineObservation::Fps {
                    phase: OperationPhase::Started,
                    ..
                }
            )),
            before + 1,
            "repeated values still exercise the actual live setter"
        );
        f.close().await;
    }
}

#[tokio::test]
async fn mirror_absent_handle_persists_and_setter_failure_keeps_saved_published_value() {
    let f = Fixture::new(mirrored(), vec![empty_row(1, 60), empty_row(2, 144)]);
    let persistence_only = f
        .handle()
        .blocking_ask::<_, BridgeDisplayMutationBundle>(SetMirrorVolume {
            display_id: "2".into(),
            volume: 0.23,
        })
        .unwrap();
    assert_eq!(row(&persistence_only.settings, &f.key(2)).volume, 0.23);
    assert_eq!(
        f.count(|o| matches!(
            o,
            EngineObservation::Volume {
                phase: OperationPhase::Started,
                ..
            }
        )),
        0
    );
    f.edit(A, 0.4);
    f.successful_apply(A, &[(1, 3101), (2, 3102)]);
    f.engine.fail_selected_setter(
        SelectedSetter::Volume,
        SceneHandle::new(3102),
        1,
        FaultTiming::BeforeMutation,
        EngineError::Render("mirror live volume".into()),
    );
    let error = f
        .handle()
        .blocking_ask::<_, BridgeDisplayMutationBundle>(SetMirrorVolume {
            display_id: "2".into(),
            volume: 0.81,
        })
        .unwrap_err();
    assert_error(
        error,
        BridgeErrorKind::Engine,
        &engine_boundary("mirror live volume"),
    );
    assert_eq!(row(&f.snapshots().settings, &f.key(2)).volume, 0.81);
    assert_eq!(
        f.store
            .load()
            .unwrap()
            .config
            .monitor_settings
            .iter()
            .find(|entry| entry.selector == connected(2))
            .unwrap()
            .volume,
        0.81
    );
    assert_eq!(
        f32::from(
            f.engine
                .live_scene_controls(SceneHandle::new(3102))
                .unwrap()
                .audio_volume
        ),
        0.23
    );
    let count = f.count(|o| {
        matches!(
            o,
            EngineObservation::Volume {
                phase: OperationPhase::Started,
                ..
            }
        )
    });
    let obstruction = SaveObstruction::new(&f, false);
    assert!(
        f.handle()
            .blocking_ask::<_, BridgeDisplayMutationBundle>(SetMirrorVolume {
                display_id: "2".into(),
                volume: 0.19
            })
            .is_err()
    );
    assert_eq!(row(&f.snapshots().settings, &f.key(2)).volume, 0.81);
    assert_eq!(
        f.count(|o| matches!(
            o,
            EngineObservation::Volume {
                phase: OperationPhase::Started,
                ..
            }
        )),
        count
    );
    drop(obstruction);
    f.close().await;
}

#[tokio::test]
async fn enabled_mode_target_validate_whole_candidate_but_eject_does_not() {
    for (enabled, mirror_target) in [
        (true, None),
        (false, None),
        (false, Some(selector(99))),
        (false, Some(connected(2))),
    ] {
        let mut app = configured();
        app.monitors.push(MonitorCfg {
            selector: connected(2),
            enabled,
            mode: "mirror".into(),
            wallpaper: None,
            mirror_target: mirror_target.clone(),
        });
        app.monitors.push(assignment(connected(3), None));
        let f = Fixture::new(
            app,
            vec![empty_row(1, 60), empty_row(2, 60), empty_row(3, 60)],
        );
        let disk = f.app_bytes();
        for error in [
            f.handle()
                .blocking_ask::<_, BridgeDisplayMutationBundle>(SetDisplayEnabled {
                    display_id: "3".into(),
                    enabled: false,
                })
                .unwrap_err(),
            f.handle()
                .blocking_ask::<_, BridgeDisplayMutationBundle>(SetDisplayMode {
                    display_id: "3".into(),
                    mode: BridgeDisplayMode::Standalone,
                })
                .unwrap_err(),
            f.handle()
                .blocking_ask::<_, BridgeDisplayMutationBundle>(SetMirrorTarget {
                    display_id: "3".into(),
                    target_display_id: "1".into(),
                })
                .unwrap_err(),
        ] {
            assert_eq!(error.kind(), BridgeErrorKind::InvalidInput);
        }
        assert_eq!(started_reconciles(&f.engine), 0);
        assert_eq!(f.app_bytes(), disk);
        let gate = f.engine.hold_next_reconcile(Ok(vec![]));
        let handle = f.handle().clone();
        let pending = request(move || {
            handle.blocking_ask(EjectWallpaperFromDisplay {
                display_id: "primary".into(),
                wallpaper_id: A.into(),
            })
        });
        let receipt = entered(gate);
        assert!(receipt.scenes.is_empty());
        receipt.release();
        pending.finish(&f.engine, &[]).unwrap();
        f.repairs_idle();
        let saved = f.store.load().unwrap().config;
        assert!(
            saved
                .monitors
                .iter()
                .find(|m| m.selector == SerializedSelector::Primary)
                .unwrap()
                .wallpaper
                .is_none()
        );
        assert!(saved.monitors.iter().any(|m| m.selector == connected(2)
            && m.mode == "mirror"
            && m.enabled == enabled
            && m.mirror_target.is_none() == mirror_target.is_none()));
        f.close().await;
    }
}

#[tokio::test]
async fn current_display_success_rebases_assignments_and_already_standalone_still_reconciles() {
    let mut app = configured();
    app.monitors.push(assignment(connected(2), Some(B)));
    let f = Fixture::new(app, vec![empty_row(1, 60), empty_row(2, 144)]);
    f.select(B);
    let gate = f
        .engine
        .hold_next_reconcile(Ok(vec![result(1, 3201), result(2, 3202)]));
    let pending = f.start_mode("2", BridgeDisplayMode::Standalone);
    let receipt = entered(gate);
    assert_eq!(receipt.scenes.len(), 2);
    receipt.release();
    let reply = pending
        .finish(&f.engine, &[SceneHandle::new(3201), SceneHandle::new(3202)])
        .unwrap();
    assert_eq!(
        row(&reply.settings, &f.key(2)).mode,
        BridgeDisplayMode::Standalone
    );
    assert_eq!(
        reply
            .app
            .active_wallpaper_ids
            .iter()
            .cloned()
            .collect::<BTreeSet<_>>(),
        [A.to_owned(), B.to_owned()].into_iter().collect()
    );
    assert!(!f.snapshots().wallpaper_options.unwrap().dirty);
    assert_eq!(started_reconciles(&f.engine), 1);
    assert_eq!(
        f.store
            .load()
            .unwrap()
            .config
            .monitors
            .iter()
            .find(|m| m.selector == connected(2))
            .unwrap()
            .mode,
        "independent"
    );
    f.repairs_idle();
    let gate = f
        .engine
        .hold_next_reconcile(Ok(vec![result(1, 3203), result(2, 3204)]));
    let mirror = f.start_mode("2", BridgeDisplayMode::Mirror);
    entered(gate).release();
    let mirror = mirror
        .finish(&f.engine, &[SceneHandle::new(3203), SceneHandle::new(3204)])
        .unwrap();
    assert_eq!(mirror.app.active_wallpaper_ids, vec![A.to_owned()]);
    assert_eq!(mirror.app.selected_wallpaper_id.as_deref(), Some(B));
    let rebased = f.draft(B);
    assert!(rebased.enabled.is_empty());
    assert!(rebased.pending_enabled.is_empty());
    assert!(
        !rebased.dirty,
        "actual display publication rebases the selected draft after assignment becomes mirror"
    );
    f.repairs_idle();
    f.close().await;
}

#[tokio::test]
async fn empty_inventory_uses_remembered_numeric_overlay_and_primary_title_fallback() {
    let mut app = configured();
    app.monitors.push(assignment(selector(2), Some(B)));
    let mut remembered = remembered_rows(&[
        ("primary", "Remembered panel (1 - Primary)"),
        ("1", "Remembered first"),
        ("2", "Remembered second"),
    ]);
    let stale_primary = remembered.get_mut("primary").unwrap();
    stale_primary.enabled = false;
    stale_primary.mode = BridgeDisplayMode::Mirror;
    stale_primary.selected_mirror_target = Some("2".into());
    let f = Fixture::with_initial(app, vec![], remembered, &[]);
    let before = f.snapshots();
    let gate = f.engine.hold_next_reconcile(Ok(vec![]));
    let handle = f.handle().clone();
    let pending = request(move || {
        handle.blocking_ask(SetDisplayEnabled {
            display_id: "2".into(),
            enabled: false,
        })
    });
    entered(gate).release();
    let reply: BridgeDisplayMutationBundle = pending.finish(&f.engine, &[]).unwrap();
    let primary = row(&reply.settings, "primary");
    assert!(primary.enabled);
    assert_eq!(primary.mode, BridgeDisplayMode::Standalone);
    assert_eq!(primary.selected_mirror_target, None);
    let second = row(&reply.settings, "2");
    assert!(!second.enabled);
    let remembered: BTreeMap<String, BridgeDisplaySettingsRow> =
        f.handle().blocking_ask(ReadRememberedRows).unwrap();
    assert!(!remembered["2"].enabled);
    assert!(remembered["primary"].enabled);
    let old_second = row(&before.settings, "2");
    assert_eq!(second.title, old_second.title);
    assert_eq!(second.scaling_factor, old_second.scaling_factor);
    assert_eq!(second.max_fps, old_second.max_fps);
    assert_eq!(second.volume, old_second.volume);
    let mirror_gate = f.engine.hold_next_reconcile(Ok(vec![]));
    let handle = f.handle().clone();
    let mirror = request(move || {
        handle.blocking_ask(SetMirrorTarget {
            display_id: "2".into(),
            target_display_id: "primary".into(),
        })
    });
    entered(mirror_gate).release();
    let mirrored: BridgeDisplayMutationBundle = mirror.finish(&f.engine, &[]).unwrap();
    assert_eq!(row(&mirrored.settings, "2").mode, BridgeDisplayMode::Mirror);
    f.repairs_idle();
    f.close().await;
}

#[tokio::test]
async fn empty_inventory_rejects_unremembered_host_ids_but_accepts_valid_unconnected_identity() {
    let f = Fixture::new(AppConfig::default(), vec![]);
    for id in ["primary", "98", "malformed-host", "identity:{"] {
        let error = f
            .handle()
            .blocking_ask::<_, BridgeDisplayMutationBundle>(SetDisplayEnabled {
                display_id: id.into(),
                enabled: false,
            })
            .unwrap_err();
        assert_eq!(error.kind(), BridgeErrorKind::InvalidInput);
    }
    assert_eq!(started_reconciles(&f.engine), 0);
    let unconnected = SerializedSelector::Identity {
        uuid: Some("unconnected-owned-fixture".into()),
        vendor_id: None,
        model_id: None,
        serial_number: None,
        unit_number: None,
        name: None,
    };
    let gate = f.engine.hold_next_reconcile(Ok(vec![]));
    let handle = f.handle().clone();
    let display_id = unconnected.id();
    let pending = request(move || {
        handle.blocking_ask(SetDisplayEnabled {
            display_id,
            enabled: false,
        })
    });
    entered(gate).release();
    let _: BridgeDisplayMutationBundle = pending.finish(&f.engine, &[]).unwrap();
    assert!(
        f.store
            .load()
            .unwrap()
            .config
            .monitors
            .iter()
            .any(|m| m.selector == unconnected && !m.enabled)
    );
    let before_mode = f.app_bytes();
    let error = f
        .handle()
        .blocking_ask::<_, BridgeDisplayMutationBundle>(SetDisplayMode {
            display_id: unconnected.id(),
            mode: BridgeDisplayMode::Standalone,
        })
        .unwrap_err();
    assert_eq!(
        error.kind(),
        BridgeErrorKind::InvalidInput,
        "Standalone resolves an actual source unlike the preceding enabled request"
    );
    assert_eq!(f.app_bytes(), before_mode);
    assert_eq!(
        started_reconciles(&f.engine),
        1,
        "Mode source refusal cannot delegate"
    );
    f.repairs_idle();
    f.close().await;
}

#[tokio::test]
async fn stable_identity_survives_renumbering_and_live_primary_alias_stays_independent() {
    for stable_uuid in [false, true] {
        let mut rows = vec![empty_row(1, 60), empty_row(2, 144)];
        if !stable_uuid {
            for row in &mut rows {
                row.identity.uuid = None;
                row.identity.name = Some("Identical model panel".into());
                row.desc.identity = row.identity.clone();
            }
        }
        let first =
            SerializedSelector::from_selector(&DisplaySelector::Identity(rows[0].identity.clone()));
        let mut second_identity = rows[1].identity.clone();
        if !stable_uuid {
            second_identity.name = Some("Obsolete saved panel label".into());
        }
        let second = SerializedSelector::from_selector(&DisplaySelector::Identity(second_identity));
        let mut app = AppConfig::default();
        app.monitors = vec![
            assignment(first.clone(), Some(A)),
            assignment(second.clone(), Some(B)),
        ];
        let f = Fixture::new(app, rows);
        let mut renumbered = f.engine.display_rows();
        renumbered[0].desc.display_id = 11;
        renumbered[1].desc.display_id = 22;
        f.engine.replace_display_rows(renumbered);
        let gate = f.engine.hold_next_reconcile(Ok(vec![result(11, 3301)]));
        let handle = f.handle().clone();
        let display_id = second.id();
        let pending = request(move || {
            handle.blocking_ask(SetDisplayEnabled {
                display_id,
                enabled: false,
            })
        });
        let receipt = entered(gate);
        assert_eq!(
            receipt
                .scenes
                .iter()
                .map(|s| s.display.display_id)
                .collect::<Vec<_>>(),
            vec![11]
        );
        receipt.release();
        let reply: BridgeDisplayMutationBundle = pending
            .finish(&f.engine, &[SceneHandle::new(3301)])
            .unwrap();
        assert!(!row(&reply.settings, &f.key(22)).enabled);
        let gate = f.engine.hold_next_reconcile(Ok(vec![result(11, 3302)]));
        let handle = f.handle().clone();
        let pending = request(move || {
            handle.blocking_ask(SetDisplayEnabled {
                display_id: "11".into(),
                enabled: false,
            })
        });
        entered(gate).release();
        let reply: BridgeDisplayMutationBundle = pending
            .finish(&f.engine, &[SceneHandle::new(3302)])
            .unwrap();
        assert!(row(&reply.settings, "primary").enabled);
        assert_eq!(
            row(&reply.settings, "primary").mode,
            BridgeDisplayMode::Standalone
        );
        f.repairs_idle();
        f.close().await;
    }
}

#[tokio::test]
async fn refresh_with_transient_inventory_loss_preserves_remembered_rows_and_primary_assignment() {
    let mut app = configured();
    app.monitors.push(assignment(connected(2), None));
    let f = Fixture::new(app, vec![empty_row(1, 60), empty_row(2, 144)]);
    f.edit(A, 0.33);
    f.successful_apply(A, &[(1, 3401)]);
    let publication = f.engine.hold_next_reconcile(Ok(vec![result(1, 3402)]));
    let publish_rows = f.start_mode("primary", BridgeDisplayMode::Standalone);
    entered(publication).release();
    publish_rows
        .finish(&f.engine, &[SceneHandle::new(3402)])
        .unwrap();
    let remembered: BTreeMap<String, BridgeDisplaySettingsRow> =
        f.handle().blocking_ask(ReadRememberedRows).unwrap();
    assert_eq!(
        remembered.keys().cloned().collect::<BTreeSet<_>>(),
        ["primary".into(), f.key(2)].into_iter().collect()
    );
    let active = f.snapshots().app.active_wallpaper_ids;
    let count = started_reconciles(&f.engine);
    f.engine.replace_display_rows(vec![]);
    f.handle().blocking_ask(RefreshDisplays).unwrap();
    let after = f.snapshots();
    assert_eq!(
        after
            .settings
            .displays
            .into_iter()
            .map(|row| (row.display_id.clone(), row))
            .collect::<BTreeMap<_, _>>(),
        remembered
    );
    assert!(
        after.monitor_information.rows.is_empty(),
        "no live inventory means no monitor-information rows"
    );
    assert_eq!(after.app.active_wallpaper_ids, active);
    assert_eq!(
        f.app()
            .monitors
            .iter()
            .find(|monitor| monitor.selector == SerializedSelector::Primary)
            .unwrap()
            .wallpaper
            .as_deref(),
        Some(A)
    );
    assert_eq!(
        f.handle()
            .blocking_ask::<_, BTreeMap<String, BridgeDisplaySettingsRow>>(ReadRememberedRows)
            .unwrap(),
        remembered
    );
    assert_eq!(started_reconciles(&f.engine), count);
    f.repairs_idle();
    f.close().await;
}

fn entered_with_frames(
    mut gate: ReconcileControl,
    engine: &ControlledEngine,
    handles: &[SceneHandle],
) -> Entered {
    let end = Instant::now() + DEADLINE;
    loop {
        for handle in handles {
            if engine
                .display_rows()
                .iter()
                .any(|row| row.handle == Some(*handle))
            {
                engine.emit_first_frame(*handle);
            }
        }
        match gate.entered.try_recv() {
            Ok(scenes) => {
                return Entered {
                    scenes,
                    release: gate.release,
                };
            }
            Err(tokio::sync::oneshot::error::TryRecvError::Empty) => {
                assert!(
                    Instant::now() < end,
                    "repair follow-up core receipt exceeded deadline"
                );
                thread::sleep(QUANTUM);
            }
            Err(tokio::sync::oneshot::error::TryRecvError::Closed) => {
                panic!("repair gate lost producer")
            }
        }
    }
}

#[tokio::test]
async fn active_repair_retains_coalesced_followup_across_stale_success_and_error() {
    for stale_error in [false, true] {
        let f = Fixture::new(reduced(), vec![empty_row(1, 60)]);
        f.edit(A, 0.4);
        f.engine
            .fail_next_render_scale(EngineError::Render("second worker failure".into()));
        let (second_failure, second_work) = f.parked_apply(A, &[(1, 3504)]);
        f.edit(A, 0.7);
        let (ordinary, ordinary_work) = f.parked_apply(A, &[(1, 3502)]);
        f.edit(A, 0.6);
        let failed_gate = f
            .engine
            .hold_next_reconcile(Err(EngineError::Render("initial worker failure".into())));
        let failed = f.start_apply(A, true);
        let initial = entered(failed_gate);
        let repair_gate = if stale_error {
            f.engine.hold_next_reconcile(Err(EngineError::Render(
                "stale repair must be suppressed".into(),
            )))
        } else {
            f.engine.hold_next_reconcile(Ok(vec![result(1, 3501)]))
        };
        initial.release();
        assert_error(
            failed.finish(&f.engine, &[]).unwrap_err(),
            BridgeErrorKind::Engine,
            &engine_boundary("initial worker failure"),
        );
        let active_repair = entered(repair_gate);
        assert_eq!(active_repair.scenes[0].property_override_json, None);
        f.edit(A, 0.9);
        ordinary_work.release();
        assert!(
            ordinary
                .finish(&f.engine, &[])
                .unwrap()
                .wallpaper_options
                .dirty
        );
        second_work.release();
        assert_error(
            second_failure.finish(&f.engine, &[]).unwrap_err(),
            BridgeErrorKind::Engine,
            &engine_boundary("second worker failure"),
        );
        let followup_gate = f.engine.hold_next_reconcile(Ok(vec![result(1, 3503)]));
        assert!(!f.handle().blocking_ask(RepairsIdle).unwrap());
        assert_eq!(
            started_reconciles(&f.engine),
            4,
            "follow-up does not overlap active repair"
        );
        active_repair.release();
        let followup = entered_with_frames(followup_gate, &f.engine, &[SceneHandle::new(3501)]);
        assert_eq!(
            followup.scenes[0].property_override_json, None,
            "repair captures committed, not failed candidate"
        );
        followup.release();
        let end = Instant::now() + DEADLINE;
        while !f.handle().blocking_ask(RepairsIdle).unwrap() {
            if f.engine
                .display_rows()
                .iter()
                .any(|row| row.handle == Some(SceneHandle::new(3503)))
            {
                f.engine.emit_first_frame(SceneHandle::new(3503));
            }
            assert!(
                Instant::now() < end,
                "follow-up receiving-side completion exceeded deadline"
            );
            thread::sleep(QUANTUM);
        }
        let errors = f.snapshots().app.errors;
        assert_eq!(
            errors,
            vec![
                engine_boundary("initial worker failure"),
                engine_boundary("second worker failure")
            ]
        );
        assert_eq!(
            started_reconciles(&f.engine),
            5,
            "exactly one retained follow-up, no unsolicited retry"
        );
        f.close().await;
    }
}

#[tokio::test]
async fn stale_display_ownership_and_incompatible_wallpaper_map_each_prevent_publication() {
    for incompatible_map in [false, true] {
        let mut app = configured();
        app.monitors.push(assignment(connected(2), Some(B)));
        let f = Fixture::new(app, vec![empty_row(1, 60), empty_row(2, 144)]);
        let disk = f.app_bytes();
        let gate = f
            .engine
            .hold_next_reconcile(Ok(vec![result(1, 3601), result(2, 3602)]));
        let pending = f.start_mode("2", BridgeDisplayMode::Mirror);
        let work = entered(gate);
        if incompatible_map {
            let mut changed = WallpaperConfig::new_for(B, "scene");
            changed.audio.volume = 0.29;
            f.handle()
                .blocking_ask(ReplaceWallpaperConfigForTest {
                    id: B.into(),
                    config: changed,
                })
                .unwrap();
        } else {
            f.select(B);
        }
        let repair_gate = f
            .engine
            .hold_next_reconcile(Err(EngineError::Render("display repair terminal".into())));
        work.release();
        let reply = pending
            .finish(&f.engine, &[SceneHandle::new(3601), SceneHandle::new(3602)])
            .unwrap();
        assert_eq!(
            row(&reply.settings, &f.key(2)).mode,
            BridgeDisplayMode::Standalone
        );
        assert_eq!(f.app_bytes(), disk);
        let repair = entered(repair_gate);
        assert!(
            repair
                .scenes
                .iter()
                .any(|scene| scene.display.display_id == 2)
        );
        repair.release();
        f.repairs_idle();
        f.close().await;
    }
}

#[tokio::test]
async fn delegated_display_error_is_recorded_once_and_preserves_current_bundle_baseline() {
    for stale in [false, true] {
        let mut app = configured();
        app.monitors.push(assignment(connected(2), Some(B)));
        let f = Fixture::new(app, vec![empty_row(1, 60), empty_row(2, 144)]);
        let disk = f.app_bytes();
        let gate = f.engine.hold_next_reconcile(Err(EngineError::Platform(
            "display platform boundary".into(),
        )));
        let pending = f.start_mode("2", BridgeDisplayMode::Mirror);
        let work = entered(gate);
        if stale {
            f.edit(B, 0.7);
        }
        let repair_gate = f
            .engine
            .hold_next_reconcile(Err(EngineError::Render("display failure repair".into())));
        work.release();
        let expected = EngineError::Platform("display platform boundary".into()).to_string();
        assert_error(
            pending.finish(&f.engine, &[]).unwrap_err(),
            BridgeErrorKind::Engine,
            &expected,
        );
        let repair = entered(repair_gate);
        assert_eq!(f.app_bytes(), disk);
        assert_eq!(
            row(&f.snapshots().settings, &f.key(2)).mode,
            BridgeDisplayMode::Standalone
        );
        assert_eq!(
            f.snapshots()
                .app
                .errors
                .iter()
                .filter(|error| **error == expected)
                .count(),
            1
        );
        repair.release();
        f.repairs_idle();
        f.close().await;
    }
}

#[tokio::test]
async fn unload_true_always_reconciles_but_same_value_and_empty_reload_do_not() {
    let f = Fixture::new(AppConfig::default(), vec![]);
    let gate = f.engine.hold_next_reconcile(Ok(vec![]));
    let handle = f.handle().clone();
    let pending = request(move || handle.blocking_ask(SetPresentationUnloaded { unloaded: true }));
    let receipt = entered(gate);
    assert!(
        receipt.scenes.is_empty(),
        "true unload runs the actual empty worker"
    );
    pending.is_pending();
    receipt.release();
    pending.finish(&f.engine, &[]).unwrap();
    assert_eq!(started_reconciles(&f.engine), 1);
    f.handle()
        .blocking_ask(SetPresentationUnloaded { unloaded: true })
        .unwrap();
    assert_eq!(
        started_reconciles(&f.engine),
        1,
        "same-value unload remains a no-op"
    );
    f.handle()
        .blocking_ask(SetPresentationUnloaded { unloaded: false })
        .unwrap();
    assert_eq!(
        started_reconciles(&f.engine),
        1,
        "false reload takes configured empty early exit"
    );
    f.repairs_idle();
    f.close().await;
}

#[tokio::test]
async fn configured_refresh_unchanged_classifier_avoids_extra_core_and_keeps_active_marks() {
    let f = Fixture::new(configured(), vec![empty_row(1, 60)]);
    f.edit(A, 0.31);
    f.successful_apply(A, &[(1, 3701)]);
    let live_before_unload = f.engine.display_rows();
    let before = f.snapshots();
    let count = started_reconciles(&f.engine);
    f.handle().blocking_ask(RefreshDisplays).unwrap();
    assert_eq!(started_reconciles(&f.engine), count);
    assert_eq!(
        f.snapshots().app.active_wallpaper_ids,
        before.app.active_wallpaper_ids
    );
    let gate = f.engine.hold_next_reconcile(Ok(vec![]));
    let handle = f.handle().clone();
    let pending = request(move || handle.blocking_ask(SetPresentationUnloaded { unloaded: true }));
    entered(gate).release();
    pending.finish(&f.engine, &[]).unwrap();
    assert_eq!(
        f.snapshots().app.active_wallpaper_ids,
        before.app.active_wallpaper_ids,
        "unload discards worker output instead of erasing active IDs"
    );
    let count = started_reconciles(&f.engine);
    f.handle().blocking_ask(RefreshDisplays).unwrap();
    assert_eq!(
        started_reconciles(&f.engine),
        count,
        "configured unloaded/no-live refresh skips core"
    );
    f.engine.replace_display_rows(live_before_unload);
    let gate = f.engine.hold_next_reconcile(Ok(vec![]));
    let handle = f.handle().clone();
    let refresh = request(move || handle.blocking_ask(RefreshDisplays));
    let work = entered(gate);
    assert!(
        work.scenes.is_empty(),
        "configured refresh with unloaded=true and live handle really reconciles empty"
    );
    work.release();
    refresh.finish(&f.engine, &[]).unwrap();
    assert_eq!(
        f.snapshots().app.active_wallpaper_ids,
        before.app.active_wallpaper_ids
    );
    f.repairs_idle();
    f.close().await;
}

#[tokio::test]
async fn reload_load_error_restores_unloaded_flag_before_failure_repair_captures_inputs() {
    let mut app = configured();
    app.monitors.push(assignment(connected(2), Some(B)));
    let f = Fixture::with_initial(
        app,
        vec![empty_row(1, 60), empty_row(2, 144)],
        BTreeMap::new(),
        &[A],
    );
    let unload_gate = f.engine.hold_next_reconcile(Ok(vec![]));
    let handle = f.handle().clone();
    let unload = request(move || handle.blocking_ask(SetPresentationUnloaded { unloaded: true }));
    entered(unload_gate).release();
    unload.finish(&f.engine, &[]).unwrap();
    let wallpaper_path = f.store.root().join("wallpapers").join(format!("{A}.json"));
    let old = fs::read(&wallpaper_path).unwrap();
    let mut future = WallpaperConfig::new_for(A, "scene");
    future.schema_version = u32::MAX;
    let future_bytes = serde_json::to_vec(&future).unwrap();
    fs::write(&wallpaper_path, &future_bytes).unwrap();
    let expected = f.store.load_wallpaper(A).unwrap_err();
    assert_eq!(expected.kind(), BridgeErrorKind::Config);
    assert_eq!(
        fs::read(&wallpaper_path).unwrap(),
        future_bytes,
        "expected-error observation is nondestructive"
    );
    let repair_gate = f.engine.hold_next_reconcile(Ok(vec![]));
    let handle = f.handle().clone();
    let reload = request(move || handle.blocking_ask(SetPresentationUnloaded { unloaded: false }));
    let error = reload.finish(&f.engine, &[]).unwrap_err();
    assert_eq!(error_pair(&error), error_pair(&expected));
    let repair = entered(repair_gate);
    assert!(
        repair.scenes.is_empty(),
        "prior unloaded flag is restored before repair planning"
    );
    repair.release();
    f.repairs_idle();
    fs::write(wallpaper_path, old).unwrap();
    f.close().await;
}

#[tokio::test]
async fn mirror_mode_retains_valid_target_and_replaces_obsolete_target_with_first_alternate() {
    for valid_target in [false, true] {
        let mut app = configured();
        app.monitors.push(MonitorCfg {
            selector: connected(2),
            enabled: true,
            mode: "mirror".into(),
            wallpaper: None,
            mirror_target: Some(if valid_target {
                connected(3)
            } else {
                selector(99)
            }),
        });
        app.monitors.push(assignment(connected(3), Some(B)));
        let f = Fixture::new(
            app,
            vec![empty_row(1, 60), empty_row(2, 144), empty_row(3, 75)],
        );
        let gate = f.engine.hold_next_reconcile(Ok(vec![
            result(1, 3801),
            result(2, 3802),
            result(3, 3803),
        ]));
        let pending = f.start_mode("2", BridgeDisplayMode::Mirror);
        let receipt = entered(gate);
        assert_eq!(receipt.scenes.len(), 3);
        let target_scene = receipt
            .scenes
            .iter()
            .find(|s| s.display.display_id == if valid_target { 3 } else { 1 })
            .unwrap();
        let mirror_scene = receipt
            .scenes
            .iter()
            .find(|s| s.display.display_id == 2)
            .unwrap();
        assert_eq!(mirror_scene.scene_path, target_scene.scene_path);
        receipt.release();
        let reply = pending
            .finish(
                &f.engine,
                &[
                    SceneHandle::new(3801),
                    SceneHandle::new(3802),
                    SceneHandle::new(3803),
                ],
            )
            .unwrap();
        assert_eq!(
            row(&reply.settings, &f.key(2)).selected_mirror_target,
            Some(if valid_target {
                f.key(3)
            } else {
                "primary".into()
            })
        );
        f.repairs_idle();
        f.close().await;
    }
}

#[tokio::test]
async fn one_remembered_nonprimary_has_no_mirror_alternate_and_refuses_before_work() {
    let mut app = AppConfig::default();
    app.monitors.push(assignment(selector(2), None));
    let f = Fixture::new(app, vec![]);
    f.handle()
        .blocking_ask(InjectDisplayForTest {
            display_id: "2".into(),
            title: "Only remembered panel".into(),
        })
        .unwrap();
    let before = f.app_bytes();
    assert_error(
        f.handle()
            .blocking_ask::<_, BridgeDisplayMutationBundle>(SetDisplayMode {
                display_id: "2".into(),
                mode: BridgeDisplayMode::Mirror,
            })
            .unwrap_err(),
        BridgeErrorKind::InvalidInput,
        "mirror mode requires another display",
    );
    assert_eq!(started_reconciles(&f.engine), 0);
    assert_eq!(f.app_bytes(), before);
    f.close().await;
}

#[tokio::test]
async fn eject_clears_only_matching_actual_primary_aliases_and_preserves_other_assignment() {
    let physical_primary = SerializedSelector::Identity {
        uuid: identity(1).uuid,
        vendor_id: Some(415),
        model_id: Some(72),
        serial_number: Some(1),
        unit_number: None,
        name: Some("Panel 1".into()),
    };
    let mut app = configured();
    app.monitors.push(assignment(physical_primary, Some(A)));
    app.monitors.push(assignment(selector(1), Some(A)));
    app.monitors.push(assignment(connected(2), Some(A)));
    let f = Fixture::new(app, vec![empty_row(1, 60), empty_row(2, 144)]);
    let gate = f.engine.hold_next_reconcile(Ok(vec![result(2, 3902)]));
    let handle = f.handle().clone();
    let pending = request(move || {
        handle.blocking_ask(EjectWallpaperFromDisplay {
            display_id: "1".into(),
            wallpaper_id: A.into(),
        })
    });
    let receipt = entered(gate);
    assert_eq!(
        receipt
            .scenes
            .iter()
            .map(|s| s.display.display_id)
            .collect::<Vec<_>>(),
        vec![2]
    );
    receipt.release();
    let _: BridgeDisplayMutationBundle = pending
        .finish(&f.engine, &[SceneHandle::new(3902)])
        .unwrap();
    let saved = f.store.load().unwrap().config;
    assert!(
        saved
            .monitors
            .iter()
            .any(|m| m.selector == connected(2) && m.wallpaper.as_deref() == Some(A))
    );
    assert!(
        !saved
            .monitors
            .iter()
            .any(|m| m.selector != connected(2) && m.wallpaper.as_deref() == Some(A))
    );
    f.repairs_idle();
    f.close().await;
}

#[tokio::test]
async fn reduced_render_scale_failure_follows_successful_audio_poststeps_without_committing() {
    let mut app = AppConfig::default();
    app.quality.render_scale = 0.5;
    let f = Fixture::new(app, vec![empty_row(1, 60)]);
    f.select(A);
    f.enable_draft(A, "primary", true);
    f.edit(A, 0.49);
    f.engine
        .fail_next_render_scale(EngineError::Render("reduced scale poststep".into()));
    let gate = f.engine.hold_next_reconcile(Ok(vec![result(1, 4001)]));
    let pending = f.start_apply(A, true);
    let work = entered(gate);
    assert_eq!(f.in_flight().len(), 1);
    let repair_gate = f
        .engine
        .hold_next_reconcile(Err(EngineError::Render("scale repair terminal".into())));
    work.release();
    assert_error(
        pending
            .finish(&f.engine, &[SceneHandle::new(4001)])
            .unwrap_err(),
        BridgeErrorKind::Engine,
        &engine_boundary("reduced scale poststep"),
    );
    let repair = entered(repair_gate);
    assert!(repair.scenes.is_empty());
    assert!(
        f.in_flight().is_empty(),
        "late reduced-scale error must not succeed the real ticket"
    );
    assert!(f.journal().strikes().is_empty());
    let observations = f.engine.observations();
    let scale = observations
        .iter()
        .position(|o| {
            matches!(
                o,
                EngineObservation::RenderScale {
                    phase: OperationPhase::Rejected,
                    ..
                }
            )
        })
        .unwrap();
    for predicate in [
        (|o: &EngineObservation| {
            matches!(
                o,
                EngineObservation::Volume {
                    phase: OperationPhase::Applied,
                    ..
                }
            )
        }) as fn(&EngineObservation) -> bool,
        |o| {
            matches!(
                o,
                EngineObservation::Muted {
                    phase: OperationPhase::Applied,
                    ..
                }
            )
        },
        |o| {
            matches!(
                o,
                EngineObservation::AudioResponse {
                    phase: OperationPhase::Applied,
                    ..
                }
            )
        },
        |o| {
            matches!(
                o,
                EngineObservation::Capture {
                    phase: OperationPhase::Applied,
                    ..
                }
            )
        },
    ] {
        assert!(observations[..scale].iter().any(predicate));
    }
    assert!(f.snapshots().wallpaper_options.unwrap().dirty);
    assert!(
        f.store
            .load_wallpaper(A)
            .unwrap()
            .property_overrides
            .is_empty()
    );
    repair.release();
    f.repairs_idle();
    f.close().await;
}

#[tokio::test]
async fn predicted_activation_refusal_preserves_its_boundary_without_engine_or_save() {
    let app = configured();
    let f = Fixture::new(app.clone(), vec![empty_row(1, 60)]);
    let mut invalid = WallpaperConfig::new_for(A, "scene");
    invalid.audio.volume = 2.0;
    f.handle()
        .blocking_ask(ReplaceWallpaperConfigForTest {
            id: A.into(),
            config: invalid.clone(),
        })
        .unwrap();
    f.edit(A, 0.7);
    invalid
        .property_overrides
        .insert("gain".into(), serde_json::json!(0.7));
    let wallpapers = [(A.to_owned(), invalid)].into_iter().collect();
    let models = [(
        A.to_owned(),
        crate::project::ProjectModel::parse(A, PROJECT).unwrap(),
    )]
    .into_iter()
    .collect();
    let displays = f.engine.display_rows();
    let library = [BridgeWallpaperEntry {
        id: A.into(),
        title: format!("Independent {A}"),
        kind: BridgeWallpaperKind::ProjectScene,
        supported: true,
        active: false,
        selected: true,
        preview_path: None,
    }];
    let suspended = BTreeSet::new();
    let held = BTreeSet::new();
    let expected = crate::engine::ActivationInputs {
        app_config: &app,
        wallpapers: &wallpapers,
        library: Some(&library),
        displays: &displays,
        paused: false,
        suspended_displays: &suspended,
        paths: &f.paths,
        force_shader_refresh: false,
        project_models: &models,
        frame_rate_cap: None,
        audio_suppressed: false,
        held: &held,
    }
    .build_owned()
    .unwrap_err();
    let disk = f.app_bytes();
    let wallpaper_disk = f.wallpaper_bytes(A);
    let error = f.start_apply(A, true).finish(&f.engine, &[]).unwrap_err();
    assert_eq!(error_pair(&error), error_pair(&expected));
    assert_eq!(started_reconciles(&f.engine), 0);
    assert_eq!(f.app_bytes(), disk);
    assert_eq!(f.wallpaper_bytes(A), wallpaper_disk);
    assert!(f.snapshots().app.errors.is_empty());
    f.repairs_idle();
    f.close().await;
}

#[tokio::test]
async fn cancel_property_restore_refusal_preserves_draft_and_real_retry_succeeds_without_saving() {
    let f = Fixture::new(configured(), vec![empty_row(1, 60)]);
    f.edit(A, 0.3);
    f.successful_apply(A, &[(1, 4101)]);
    f.edit(A, 0.8);
    f.preview(A, 0.8).unwrap();
    let app_disk = f.app_bytes();
    let wallpaper_disk = f.wallpaper_bytes(A);
    let handle = SceneHandle::new(4101);
    f.engine
        .fail_next_property_preview(EngineError::Render("cancel property refusal".into()));
    assert_error(
        f.cancel(A).unwrap_err(),
        BridgeErrorKind::Engine,
        &engine_boundary("cancel property refusal"),
    );
    let options = f.snapshots().wallpaper_options.unwrap();
    assert!(options.dirty);
    assert_eq!(property(&options), 0.8);
    assert!(f.engine.shown_property_state(handle).is_none());
    let before = f.engine.observations().len();
    let reply = f.cancel(A).unwrap();
    assert!(!reply.wallpaper_options.dirty);
    assert_eq!(property(&reply.wallpaper_options), 0.3);
    let observations = f.engine.observations();
    assert_eq!(observations[before..].iter().filter(|o| matches!(o,
        EngineObservation::PropertyPreview { handle: h, phase: PropertyPreviewPhase::Attempted, .. } if *h == handle)).count(), 1);
    assert_eq!(
        json_gain(&f.engine.shown_property_state(handle).unwrap().flat_json),
        Some(0.3)
    );
    assert_eq!(f.app_bytes(), app_disk);
    assert_eq!(f.wallpaper_bytes(A), wallpaper_disk);
    f.repairs_idle();
    f.close().await;
}

#[tokio::test]
async fn cancel_without_live_scene_discards_real_pending_draft_and_invalidates_older_apply() {
    let f = Fixture::new(configured(), vec![empty_row(1, 60)]);
    f.edit(A, 0.65);
    let disk = f.wallpaper_bytes(A);
    let gate = f.engine.hold_next_reconcile(Ok(vec![result(1, 4201)]));
    let pending = f.start_apply(A, true);
    let work = entered(gate);
    let cancelled = f.cancel(A).unwrap();
    assert!(!cancelled.wallpaper_options.dirty);
    assert_eq!(property(&cancelled.wallpaper_options), 0.25);
    let repair_gate = f
        .engine
        .hold_next_reconcile(Err(EngineError::Render("cancelled stale repair".into())));
    work.release();
    let stale = pending
        .finish(&f.engine, &[SceneHandle::new(4201)])
        .unwrap();
    assert_eq!(property(&stale.wallpaper_options), 0.25);
    assert!(!stale.wallpaper_options.dirty);
    assert_eq!(f.wallpaper_bytes(A), disk);
    let repair = entered(repair_gate);
    assert_eq!(repair.scenes[0].property_override_json, None);
    repair.release();
    f.repairs_idle();
    f.close().await;
}

#[tokio::test]
async fn confirmed_no_override_is_distinct_from_refused_unconfirmed_live_scene() {
    let f = Fixture::new(AppConfig::default(), vec![empty_row(1, 60)]);
    f.select(A);
    f.enable_draft(A, "primary", true);
    f.successful_apply(A, &[(1, 4301)]);
    let handle = SceneHandle::new(4301);
    assert_eq!(
        f.engine.shown_property_state(handle).unwrap().flat_json,
        None
    );
    f.engine
        .fail_next_property_preview(EngineError::Render("unconfirm default scene".into()));
    assert!(f.preview(A, 0.7).is_err());
    assert_eq!(f.engine.display_rows()[0].handle, Some(handle));
    assert!(f.engine.shown_property_state(handle).is_none());
    f.edit(A, 0.7);
    let before = f.engine.observations().len();
    f.cancel(A).unwrap();
    assert!(f.engine.shown_property_state(handle).is_some());
    assert!(f.engine.observations()[before..].iter().any(|o| matches!(
        o,
        EngineObservation::PropertyPreview {
            phase: PropertyPreviewPhase::Attempted,
            ..
        }
    )));
    f.close().await;
}

fn json_gain(document: &Option<String>) -> Option<f64> {
    document
        .as_ref()
        .and_then(|json| serde_json::from_str::<serde_json::Value>(json).unwrap()["gain"].as_f64())
}

#[tokio::test]
async fn public_ok_uses_explicit_apply_and_returns_actual_publication_reply() {
    let f = Fixture::new(configured(), vec![empty_row(1, 60)]);
    f.edit(A, 0.56);
    let gate = f.engine.hold_next_reconcile(Ok(vec![result(1, 4401)]));
    let engine = f.engine.clone();
    let (finished, done) = mpsc::sync_channel(1);
    let driver = thread::spawn(move || {
        let receipt = entered(gate);
        assert_eq!(
            json_gain(&receipt.scenes[0].property_override_json),
            Some(0.56)
        );
        receipt.release();
        let end = Instant::now() + DEADLINE;
        loop {
            if engine
                .display_rows()
                .iter()
                .any(|row| row.handle == Some(SceneHandle::new(4401)))
            {
                engine.emit_first_frame(SceneHandle::new(4401));
            }
            match done.recv_timeout(QUANTUM) {
                Ok(()) | Err(mpsc::RecvTimeoutError::Disconnected) => break,
                Err(mpsc::RecvTimeoutError::Timeout) => {
                    assert!(Instant::now() < end, "public OK deadline")
                }
            }
        }
    });
    let reply = tokio::time::timeout(DEADLINE, f.bridge.ok_wallpaper_options(A.into())).await;
    let _ = finished.send(());
    driver.join().unwrap();
    let reply = reply.expect("public OK reply deadline").unwrap();
    assert!(!reply.wallpaper_options.dirty);
    assert_eq!(property(&reply.wallpaper_options), 0.56);
    assert_eq!(
        f.store.load_wallpaper(A).unwrap().property_overrides["gain"].as_f64(),
        Some(0.56)
    );
    f.repairs_idle();
    f.close().await;
}

#[tokio::test]
async fn new_reservation_supersedes_deferred_repair_but_later_actual_effects_still_restore() {
    let f = Fixture::new(reduced(), vec![empty_row(1, 60)]);
    f.edit(A, 0.4);
    let (a, work_a) = f.parked_apply(A, &[(1, 4501)]);
    f.edit(A, 0.6);
    let (b, work_b) = f.parked_apply(A, &[(1, 4502)]);
    work_a.release();
    a.finish(&f.engine, &[SceneHandle::new(4501)]).unwrap();
    assert!(
        !f.handle().blocking_ask(RepairsIdle).unwrap(),
        "older stale success has deferred repair"
    );
    f.edit(A, 0.9);
    let gate_c = f.engine.hold_next_reconcile(Ok(vec![result(1, 4503)]));
    let c = f.start_apply(A, true);
    let work_c = entered(gate_c);
    let repair_gate = f.engine.hold_next_reconcile(Err(EngineError::Render(
        "superseded deferred repair terminal".into(),
    )));
    work_c.release();
    let current = c.finish(&f.engine, &[SceneHandle::new(4503)]).unwrap();
    assert_eq!(property(&current.wallpaper_options), 0.9);
    assert!(
        f.handle().blocking_ask(RepairsIdle).unwrap(),
        "new reservation removed old deferred repair"
    );
    b.is_pending();
    work_b.release();
    let stale = b.finish(&f.engine, &[SceneHandle::new(4502)]).unwrap();
    assert_eq!(property(&stale.wallpaper_options), 0.9);
    let repair = entered(repair_gate);
    assert_eq!(
        json_gain(&repair.scenes[0].property_override_json),
        Some(0.9)
    );
    repair.release();
    f.repairs_idle();
    f.close().await;
}

#[tokio::test]
async fn failed_delegated_work_starts_repair_while_newer_ordinary_work_is_still_blocked() {
    let f = Fixture::new(reduced(), vec![empty_row(1, 60)]);
    f.edit(A, 0.4);
    f.engine
        .fail_next_render_scale(EngineError::Render("older boundary failure".into()));
    let (older, older_work) = f.parked_apply(A, &[(1, 4601)]);
    f.edit(A, 0.8);
    let newer_gate = f.engine.hold_next_reconcile(Ok(vec![result(1, 4602)]));
    let newer = f.start_apply(A, true);
    let newer_work = entered(newer_gate);
    let newer_completion = f
        .engine
        .hold_next_render_scale_completion(SceneHandle::new(4602));
    let mut repair_gate = f
        .engine
        .hold_next_reconcile(Err(EngineError::Render("repair ahead of newer".into())));
    older_work.release();
    assert_error(
        older.finish(&f.engine, &[]).unwrap_err(),
        BridgeErrorKind::Engine,
        &engine_boundary("older boundary failure"),
    );
    assert!(
        f.handle().blocking_ask(RepairActive).unwrap(),
        "failure repair is admitted while newer core holds its turn"
    );
    wait_admitted(&f.engine, 3);
    assert!(matches!(
        repair_gate.entered.try_recv(),
        Err(tokio::sync::oneshot::error::TryRecvError::Empty)
    ));
    newer.is_pending();
    newer_work.release();
    let repair = entered_with_frames(repair_gate, &f.engine, &[SceneHandle::new(4602)]);
    assert_eq!(repair.scenes[0].property_override_json, None);
    let followup_gate = f
        .engine
        .hold_next_reconcile(Err(EngineError::Render("late newer repair".into())));
    repair.release();
    let newer_completed =
        completed_render_scale(newer_completion, &f.engine, &[SceneHandle::new(4602)]);
    f.repairs_idle();
    newer_completed.release();
    newer.finish(&f.engine, &[]).unwrap();
    entered(followup_gate).release();
    f.repairs_idle();
    assert_eq!(
        f.store
            .load_wallpaper(A)
            .unwrap()
            .property_overrides
            .get("gain"),
        None
    );
    f.close().await;
}

#[tokio::test]
async fn mirror_scaling_and_mute_use_saved_settings_and_actual_live_controls() {
    let f = Fixture::new(mirrored(), vec![empty_row(1, 60), empty_row(2, 144)]);
    let reply = f
        .handle()
        .blocking_ask::<_, BridgeDisplayMutationBundle>(SetMirrorScalingMode {
            display_id: "2".into(),
            mode: BridgeScalingMode::Match,
        })
        .unwrap();
    assert_eq!(
        row(&reply.settings, &f.key(2)).scaling_mode,
        BridgeScalingMode::Match
    );
    let reply = f
        .handle()
        .blocking_ask::<_, BridgeDisplayMutationBundle>(SetMirrorScalingFactor {
            display_id: "2".into(),
            factor: 0.72,
        })
        .unwrap();
    assert_eq!(row(&reply.settings, &f.key(2)).scaling_factor, 0.72);
    f.handle()
        .blocking_ask::<_, BridgeDisplayMutationBundle>(SetMirrorMuted {
            display_id: "2".into(),
            muted: true,
        })
        .unwrap();
    let saved = f.store.load().unwrap().config;
    let settings = saved
        .monitor_settings
        .iter()
        .find(|entry| entry.selector == connected(2))
        .unwrap();
    assert_eq!(settings.parse_scaling_mode(), ScalingMode::Fit);
    assert_eq!(settings.scaling_factor, 0.72);
    assert!(settings.muted);
    f.edit(A, 0.39);
    let consumed = f.successful_apply(A, &[(1, 4701), (2, 4702)]);
    assert!(
        consumed
            .iter()
            .find(|scene| scene.display.display_id == 2)
            .unwrap()
            .audio_muted
    );
    assert!(
        !consumed
            .iter()
            .find(|scene| scene.display.display_id == 1)
            .unwrap()
            .audio_muted
    );
    let handle = SceneHandle::new(4702);
    assert_eq!(
        f.engine.live_scene_controls(handle).unwrap().scaling_mode,
        ScalingMode::Fit
    );
    f.handle()
        .blocking_ask::<_, BridgeDisplayMutationBundle>(SetMirrorScalingFactor {
            display_id: "2".into(),
            factor: 0.83,
        })
        .unwrap();
    assert_eq!(
        f.engine.live_scene_controls(handle).unwrap().scaling_factor,
        0.83
    );
    f.engine.fail_selected_setter(
        SelectedSetter::Muted,
        handle,
        1,
        FaultTiming::AfterMutation,
        EngineError::Render("mirror after-mutation mute".into()),
    );
    assert_error(
        f.handle()
            .blocking_ask::<_, BridgeDisplayMutationBundle>(SetMirrorMuted {
                display_id: "2".into(),
                muted: false,
            })
            .unwrap_err(),
        BridgeErrorKind::Engine,
        &engine_boundary("mirror after-mutation mute"),
    );
    assert!(!f.engine.live_scene_controls(handle).unwrap().audio_muted);
    assert!(!row(&f.snapshots().settings, &f.key(2)).muted);
    assert!(
        !f.store
            .load()
            .unwrap()
            .config
            .monitor_settings
            .iter()
            .find(|entry| entry.selector == connected(2))
            .unwrap()
            .muted
    );
    f.close().await;
}

impl Fixture {
    async fn close(self) {
        let Self {
            bridge,
            engine,
            store,
            paths,
            root,
            clock,
            prior_tickets,
        } = self;
        drop(engine);
        drop(store);
        drop(paths);
        tokio::time::timeout(
            DEADLINE,
            crate::api::mounted_lifecycle::shutdown_and_drain(bridge),
        )
        .await
        .expect("genuine shutdown/drain deadline")
        .expect("genuine shutdown/drain");
        drop(prior_tickets);
        drop(clock);
        drop(root);
    }
    fn stage_factor(&self, display: &str, factor: f64) {
        self.handle()
            .blocking_ask(SetScalingFactor {
                wallpaper_id: A.into(),
                display_id: display.into(),
                factor,
            })
            .unwrap();
    }
    fn app(&self) -> AppConfig {
        self.handle().blocking_ask(ReadAppConfig).unwrap()
    }
    fn draft(&self, id: &str) -> DraftConfigObservation {
        self.handle()
            .blocking_ask(ReadDraftConfig {
                wallpaper_id: id.into(),
            })
            .unwrap()
    }
    fn journal(&self) -> LoadJournal {
        self.handle().blocking_ask(ReadJournal).unwrap()
    }
    fn holds(&self) -> BTreeSet<String> {
        self.handle().blocking_ask(ReadHeld).unwrap()
    }
    fn preview_mark(&self) -> bool {
        self.handle()
            .blocking_ask(ReadPropertyPreviewMark {
                wallpaper_id: A.into(),
            })
            .unwrap()
    }
    fn in_flight(&self) -> Vec<serde_json::Value> {
        let bytes = match fs::read(self.store.root().join("load-journal.json")) {
            Ok(bytes) => bytes,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Vec::new(),
            Err(error) => panic!("read genuine journal record: {error}"),
        };
        serde_json::from_slice::<serde_json::Value>(&bytes).unwrap()["in_flight"]
            .as_array()
            .unwrap()
            .clone()
    }
}

#[tokio::test]
async fn scaling_only_apply_saves_and_commits_without_reconcile_and_both_save_errors_are_retryable()
{
    for failure in [0, 1, 2] {
        let f = Fixture::new(configured(), vec![empty_row(1, 60)]);
        f.stage_factor("primary", 0.73);
        let before_app = f.app();
        let committed = f.draft(A).saved;
        assert!(!f.draft(A).requires_reconcile);
        let app_disk = f.app_bytes();
        let wallpaper_disk = f.wallpaper_bytes(A);
        let obstruction = if failure == 0 {
            None
        } else {
            Some(SaveObstruction::new(&f, failure == 2))
        };
        if failure == 2 {
            fs::remove_file(f.store.root().join("config.toml")).unwrap();
        }
        let outcome = f.start_apply(A, true).finish(&f.engine, &[]);
        assert_eq!(started_reconciles(&f.engine), 0);
        if failure == 0 {
            let reply = outcome.unwrap();
            assert!(!reply.wallpaper_options.dirty);
            assert_eq!(
                reply
                    .wallpaper_options
                    .display_configurations
                    .iter()
                    .find(|row| row.display_id == "primary")
                    .unwrap()
                    .scaling_factor,
                0.73
            );
            assert_eq!(
                f.store.load_wallpaper(A).unwrap().monitors[0].scaling_factor,
                0.73
            );
        } else {
            assert!(outcome.is_err());
            assert!(f.snapshots().wallpaper_options.unwrap().dirty);
            assert!(f.snapshots().app.errors.is_empty());
            assert_eq!(
                f.app(),
                before_app,
                "no-reconcile save failure has no in-memory Apply exception"
            );
            assert_eq!(f.draft(A).saved, committed);
            if failure == 2 {
                assert!(
                    f.store.root().join("config.toml").is_file(),
                    "first app save created its real destination"
                );
                assert!(
                    f.store
                        .load()
                        .unwrap()
                        .config
                        .monitors
                        .iter()
                        .any(|m| m.wallpaper.as_deref() == Some(A))
                );
            }
            drop(obstruction);
            assert_eq!(f.wallpaper_bytes(A), wallpaper_disk);
            if failure == 1 {
                assert_eq!(f.app_bytes(), app_disk);
            }
            let retry = f.start_apply(A, true).finish(&f.engine, &[]).unwrap();
            assert!(!retry.wallpaper_options.dirty);
            assert_eq!(started_reconciles(&f.engine), 0);
        }
        f.repairs_idle();
        f.close().await;
    }
}

#[tokio::test]
async fn cancel_after_mutation_rolls_back_every_attempted_handle_and_preserves_original_error_if_rollback_fails()
 {
    for rollback_fails in [false, true] {
        let mut app = configured();
        app.monitors.push(assignment(connected(2), Some(A)));
        app.monitors.push(assignment(connected(3), Some(B)));
        let f = Fixture::new(
            app,
            vec![empty_row(1, 60), empty_row(2, 144), empty_row(3, 75)],
        );
        let mut other = WallpaperConfig::new_for(B, "scene");
        other.monitors.push(MonitorRender {
            selector: connected(3),
            scaling_factor: 0.93,
            ..MonitorRender::default()
        });
        f.handle()
            .blocking_ask(ReplaceWallpaperConfigForTest {
                id: B.into(),
                config: other,
            })
            .unwrap();
        f.edit(A, 0.3);
        f.successful_apply(A, &[(1, 4801), (2, 4802), (3, 4803)]);
        let mut committed = f.draft(A).saved;
        committed.monitors.clear();
        f.handle()
            .blocking_ask(ReplaceWallpaperConfigForTest {
                id: A.into(),
                config: committed,
            })
            .unwrap();
        assert!(
            f.draft(A).saved.monitors.is_empty(),
            "restoration must use accepted missing-monitor default"
        );
        f.stage_factor("primary", 0.6);
        f.stage_factor("2", 0.8);
        f.stage_factor("3", 0.4);
        let first = SceneHandle::new(4801);
        let failing = SceneHandle::new(4802);
        assert_eq!(
            f.engine.live_scene_controls(first).unwrap().scaling_factor,
            0.6
        );
        assert_eq!(
            f.engine
                .live_scene_controls(failing)
                .unwrap()
                .scaling_factor,
            0.8
        );
        f.engine.fail_selected_setter(
            SelectedSetter::ScalingFactor,
            failing,
            1,
            FaultTiming::AfterMutation,
            EngineError::Render("cancel reset after mutation".into()),
        );
        if rollback_fails {
            f.engine.fail_selected_setter(
                SelectedSetter::ScalingFactor,
                failing,
                2,
                FaultTiming::BeforeMutation,
                EngineError::Render("independent rollback failure".into()),
            );
        }
        let app_disk = f.app_bytes();
        let wallpaper_disk = f.wallpaper_bytes(A);
        let before = f.engine.observations().len();
        assert_error(
            f.cancel(A).unwrap_err(),
            BridgeErrorKind::Engine,
            &engine_boundary("cancel reset after mutation"),
        );
        assert!(f.snapshots().wallpaper_options.unwrap().dirty);
        assert!(
            f.snapshots().app.errors.is_empty(),
            "rollback diagnostic must not become a replacement app error"
        );
        assert_eq!(
            f.engine.live_scene_controls(first).unwrap().scaling_factor,
            0.6
        );
        assert_eq!(
            f.engine
                .live_scene_controls(failing)
                .unwrap()
                .scaling_factor,
            if rollback_fails { 1.0 } else { 0.8 }
        );
        let observations = f.engine.observations();
        for handle in [first, failing] {
            assert_eq!(observations[before..].iter().filter(|o| matches!(o,
                EngineObservation::ScalingFactor { handle: h, phase: OperationPhase::Started, .. } if *h == handle)).count(), 2);
        }
        assert_eq!(f.app_bytes(), app_disk);
        assert_eq!(f.wallpaper_bytes(A), wallpaper_disk);
        let retry = f.cancel(A).unwrap();
        assert!(!retry.wallpaper_options.dirty);
        assert_eq!(
            f.engine.live_scene_controls(first).unwrap().scaling_factor,
            1.0
        );
        assert_eq!(
            f.engine
                .live_scene_controls(failing)
                .unwrap()
                .scaling_factor,
            1.0
        );
        assert_eq!(f.wallpaper_bytes(A), wallpaper_disk);
        assert_eq!(
            f.engine
                .live_scene_controls(SceneHandle::new(4803))
                .unwrap()
                .scaling_factor,
            0.93
        );
        assert!(!f.engine.observations()[before..].iter().any(|o| matches!(o,
            EngineObservation::ScalingFactor { handle, phase: OperationPhase::Started, .. } if *handle == SceneHandle::new(4803))),
            "Cancel only resets matching current direct wallpaper handles");
        f.repairs_idle();
        f.close().await;
    }
}

#[tokio::test]
async fn successful_property_restore_is_not_resent_after_later_scaling_failure_or_cancel_retry() {
    let f = Fixture::new(configured(), vec![empty_row(1, 60)]);
    f.edit(A, 0.3);
    f.successful_apply(A, &[(1, 4901)]);
    f.edit(A, 0.8);
    f.preview(A, 0.8).unwrap();
    f.stage_factor("primary", 0.7);
    let handle = SceneHandle::new(4901);
    f.engine.fail_selected_setter(
        SelectedSetter::ScalingFactor,
        handle,
        1,
        FaultTiming::AfterMutation,
        EngineError::Render("scaling after property restore".into()),
    );
    let before = f.engine.observations().len();
    assert_error(
        f.cancel(A).unwrap_err(),
        BridgeErrorKind::Engine,
        &engine_boundary("scaling after property restore"),
    );
    assert_eq!(
        json_gain(&f.engine.shown_property_state(handle).unwrap().flat_json),
        Some(0.3)
    );
    let observations = f.engine.observations();
    let property_restore = observations[before..]
        .iter()
        .position(|o| {
            matches!(
                o,
                EngineObservation::PropertyPreview {
                    phase: PropertyPreviewPhase::Applied,
                    ..
                }
            )
        })
        .unwrap();
    let scaling = observations[before..]
        .iter()
        .position(|o| {
            matches!(
                o,
                EngineObservation::ScalingFactor {
                    phase: OperationPhase::Rejected,
                    ..
                }
            )
        })
        .unwrap();
    assert!(property_restore < scaling);
    let before_retry = f.engine.observations().len();
    let retry = f.cancel(A).unwrap();
    assert!(!retry.wallpaper_options.dirty);
    assert!(
        !f.engine.observations()[before_retry..]
            .iter()
            .any(|o| matches!(
                o,
                EngineObservation::PropertyPreview {
                    phase: PropertyPreviewPhase::Attempted | PropertyPreviewPhase::Applied,
                    ..
                }
            ))
    );
    f.close().await;
}

#[tokio::test]
async fn cancel_preserves_saved_position_audio_media_scaling_mode_and_rate() {
    let f = Fixture::new(configured(), vec![empty_row(1, 60)]);
    f.edit(A, 0.3);
    f.successful_apply(A, &[(1, 5001)]);
    f.stage_factor("primary", 0.7);
    f.edit(A, 0.8);
    f.preview(A, 0.8).unwrap();
    f.handle()
        .blocking_ask(SetDisplayPosition {
            wallpaper_id: A.into(),
            display_id: "primary".into(),
            pan_x: Some(0.2),
            pan_y: Some(0.8),
        })
        .unwrap();
    f.handle()
        .blocking_ask(SetScalingMode {
            wallpaper_id: A.into(),
            display_id: "primary".into(),
            mode: BridgeScalingMode::Match,
        })
        .unwrap();
    f.handle()
        .blocking_ask(SetTargetFps {
            wallpaper_id: A.into(),
            display_id: "primary".into(),
            fps: 37,
        })
        .unwrap();
    f.handle()
        .blocking_ask(SetVolume {
            wallpaper_id: A.into(),
            volume: 0.41,
        })
        .unwrap();
    f.handle()
        .blocking_ask(SetMuted {
            wallpaper_id: A.into(),
            muted: true,
        })
        .unwrap();
    f.handle()
        .blocking_ask(SetAudioResponseEnabled {
            wallpaper_id: A.into(),
            enabled: false,
        })
        .unwrap();
    f.handle()
        .blocking_ask(SetMediaIntegrationEnabled {
            wallpaper_id: A.into(),
            enabled: true,
        })
        .unwrap();
    let saved = f.store.load_wallpaper(A).unwrap();
    assert_eq!(saved.audio.volume, 0.41);
    assert!(saved.audio.muted);
    assert!(!saved.audio.response_enabled);
    assert!(saved.media_integration_enabled);
    assert!(
        saved
            .monitors
            .iter()
            .any(|m| m.parse_scaling_mode() == ScalingMode::Fit
                && m.frame_rate == Some(37)
                && m.framing.pan_x == 0.2
                && m.framing.pan_y == 0.8)
    );
    let disk = f.wallpaper_bytes(A);
    let reply = f.cancel(A).unwrap();
    assert!(!reply.wallpaper_options.dirty);
    assert_eq!(property(&reply.wallpaper_options), 0.3);
    assert_eq!(reply.wallpaper_options.volume, 0.41);
    assert!(reply.wallpaper_options.muted);
    assert!(!reply.wallpaper_options.audio_response_enabled);
    assert!(
        !f.engine
            .live_scene_controls(SceneHandle::new(5001))
            .unwrap()
            .audio_response_enabled
    );
    assert!(reply.wallpaper_options.media_integration_enabled);
    assert_eq!(f.store.load_wallpaper(A).unwrap(), saved);
    assert_eq!(f.wallpaper_bytes(A), disk);
    let display = reply
        .wallpaper_options
        .display_configurations
        .iter()
        .find(|row| row.display_id == "primary")
        .unwrap();
    assert_eq!(display.scaling_mode, BridgeScalingMode::Match);
    assert_eq!(display.target_fps, 37);
    assert_eq!(display.framing.pan_x, 0.2);
    assert_eq!(display.framing.pan_y, 0.8);
    f.close().await;
}

#[tokio::test]
async fn explicit_unchanged_held_apply_lifts_memory_only_and_forgives_before_every_late_outcome() {
    for late in [0, 1, 2, 3] {
        let f = Fixture::with_holds(configured(), vec![], &[A, B]);
        f.handle().blocking_ask(Bootstrap).unwrap();
        assert!(f.holds().contains(A));
        assert!(f.holds().contains(B));
        assert_eq!(
            f.snapshots().app.held_wallpaper_ids,
            vec![A.to_owned()],
            "unassigned held owner remains memory-only"
        );
        f.engine.replace_display_rows(vec![empty_row(1, 60)]);
        let initial = f.draft(A);
        assert!(!initial.dirty);
        assert!(!initial.requires_reconcile);
        let strikes = f.journal().strikes();
        let obstruction = if late >= 2 {
            Some(SaveObstruction::new(&f, late == 3))
        } else {
            None
        };
        let gate = f.engine.hold_next_reconcile(Ok(vec![result(1, 5101)]));
        let ordinary = f.start_apply(A, true);
        let work = entered(gate);
        assert_eq!(
            work.scenes.len(),
            1,
            "unchanged held user Apply is forced through real reconcile"
        );
        assert!(!f.holds().contains(A));
        assert!(f.holds().contains(B));
        assert_eq!(
            f.journal().strikes(),
            strikes,
            "lifting memory is not forgiveness"
        );
        let repair_gate = if late == 1 {
            f.edit(A, 0.8);
            Some(f.engine.hold_next_reconcile(Err(EngineError::Render(
                "held stale repair terminal".into(),
            ))))
        } else {
            None
        };
        work.release();
        let outcome = ordinary.finish(&f.engine, &[SceneHandle::new(5101)]);
        if late >= 2 {
            assert!(outcome.is_err());
        } else {
            let reply = outcome.unwrap();
            assert_eq!(reply.wallpaper_options.dirty, late == 1);
        }
        assert!(
            !f.journal().strikes().contains_key(A),
            "worker success forgives before stale/save publication outcome"
        );
        assert!(f.journal().strikes().contains_key(B));
        assert!(!f.holds().contains(A));
        if let Some(repair_gate) = repair_gate {
            let repair = entered(repair_gate);
            assert_eq!(
                repair.scenes.len(),
                1,
                "repair sees successful forgiveness, not a restored old hold"
            );
            repair.release();
        }
        drop(obstruction);
        f.repairs_idle();
        f.close().await;
    }
}

#[tokio::test]
async fn held_user_failure_restores_memory_before_actual_repair_plan_and_automation_never_lifts_or_forgives()
 {
    for user in [false, true] {
        let f = Fixture::with_holds(configured(), vec![], &[A]);
        f.handle().blocking_ask(Bootstrap).unwrap();
        f.engine.replace_display_rows(vec![empty_row(1, 60)]);
        let strikes = f.journal().strikes();
        if user {
            let gate = f
                .engine
                .hold_next_reconcile(Err(EngineError::Render("held user boundary".into())));
            let ordinary = f.start_apply(A, true);
            let work = entered(gate);
            assert!(!f.holds().contains(A));
            let repair_gate = f.engine.hold_next_reconcile(Ok(vec![]));
            work.release();
            assert_error(
                ordinary.finish(&f.engine, &[]).unwrap_err(),
                BridgeErrorKind::Engine,
                &engine_boundary("held user boundary"),
            );
            let repair = entered(repair_gate);
            assert!(
                repair.scenes.is_empty(),
                "lifted hold must be restored before repair captures inputs"
            );
            assert!(f.holds().contains(A));
            assert_eq!(f.journal().strikes(), strikes);
            repair.release();
        } else {
            let before = started_reconciles(&f.engine);
            f.start_apply(A, false).finish(&f.engine, &[]).unwrap();
            assert_eq!(started_reconciles(&f.engine), before);
            assert!(f.holds().contains(A));
            assert_eq!(f.journal().strikes(), strikes);
            f.edit(A, 0.72);
            let gate = f.engine.hold_next_reconcile(Ok(vec![]));
            let ordinary = f.start_apply(A, false);
            let work = entered(gate);
            assert!(
                work.scenes.is_empty(),
                "automated changed draft still omits genuinely held owner"
            );
            assert!(f.holds().contains(A));
            work.release();
            ordinary.finish(&f.engine, &[]).unwrap();
            assert_eq!(f.journal().strikes(), strikes);
        }
        f.repairs_idle();
        f.close().await;
    }
}

#[tokio::test]
async fn no_reconcile_user_forgiveness_waits_for_successful_real_publication() {
    for failure in [0, 1, 2] {
        // Genuine injected journal with real crash history; intentionally no Bootstrap:
        // memory holds have not been populated, so the actual no-reconcile branch is reachable.
        let f = Fixture::with_strikes(configured(), vec![empty_row(1, 60)], &[A]);
        assert!(f.holds().is_empty());
        assert!(f.journal().strikes().contains_key(A));
        f.stage_factor("primary", 0.74);
        assert!(!f.draft(A).requires_reconcile);
        let strikes = f.journal().strikes();
        let obstruction = if failure == 0 {
            None
        } else {
            Some(SaveObstruction::new(&f, failure == 2))
        };
        let outcome = f.start_apply(A, true).finish(&f.engine, &[]);
        assert_eq!(started_reconciles(&f.engine), 0);
        if failure == 0 {
            assert!(!outcome.unwrap().wallpaper_options.dirty);
            assert!(!f.journal().strikes().contains_key(A));
            assert!(!f.draft(A).dirty);
        } else {
            assert!(outcome.is_err());
            assert_eq!(f.journal().strikes(), strikes);
            assert!(f.draft(A).dirty);
        }
        drop(obstruction);
        f.close().await;
    }
}

#[tokio::test]
async fn actual_ticket_spans_core_readiness_and_all_poststeps_with_correct_mirror_owner() {
    let f = Fixture::new(mirrored(), vec![empty_row(1, 60), empty_row(2, 144)]);
    f.edit(A, 0.61);
    let gate = f
        .engine
        .hold_next_reconcile(Ok(vec![result(1, 5201), result(2, 5202)]));
    let pending = f.start_apply(A, true);
    let work = entered(gate);
    let openings = f.in_flight();
    assert_eq!(
        openings
            .iter()
            .map(|row| (
                row["wallpaper"].as_str().unwrap().to_owned(),
                row["display"].as_u64().unwrap()
            ))
            .collect::<BTreeSet<_>>(),
        [(A.to_owned(), 1), (A.to_owned(), 2)].into_iter().collect()
    );
    assert!(
        openings
            .iter()
            .all(|row| row.get("settled_until").is_none() || row["settled_until"].is_null())
    );
    work.release();
    let end = Instant::now() + DEADLINE;
    while !f.engine.observations().iter().any(|o| {
        matches!(
            o,
            EngineObservation::ReconcilePrune {
                phase: OperationPhase::Applied
            }
        )
    }) {
        assert!(Instant::now() < end, "actual prune completion deadline");
        thread::sleep(QUANTUM);
    }
    pending.is_pending();
    assert!(
        f.in_flight()
            .iter()
            .all(|row| row.get("settled_until").is_none() || row["settled_until"].is_null()),
        "core/prune success must not succeed the ticket before first-frame readiness"
    );
    pending
        .finish(&f.engine, &[SceneHandle::new(5201), SceneHandle::new(5202)])
        .unwrap();
    assert!(
        f.in_flight()
            .iter()
            .all(|row| row["settled_until"].as_u64().is_some()),
        "actual worker success retains succeeded openings through the genuine settle window"
    );
    assert_eq!(f.in_flight().len(), 2);
    f.close().await;
}

#[tokio::test]
async fn running_and_unload_plans_do_not_create_new_journal_suspects() {
    let f = Fixture::new(configured(), vec![empty_row(1, 60)]);
    f.edit(A, 0.32);
    f.successful_apply(A, &[(1, 5301)]);
    let successful = f.in_flight();
    assert_eq!(successful.len(), 1);
    f.clock.fetch_add(1000, Ordering::Relaxed);
    let gate = f.engine.hold_next_reconcile(Ok(vec![result(1, 5301)]));
    let running = f.start_mode("primary", BridgeDisplayMode::Standalone);
    entered(gate).release();
    running
        .finish(&f.engine, &[SceneHandle::new(5301)])
        .unwrap();
    assert_eq!(
        f.in_flight(),
        successful,
        "identical running descriptor does not begin a new load attempt"
    );
    let gate = f.engine.hold_next_reconcile(Ok(vec![]));
    let handle = f.handle().clone();
    let unload = request(move || handle.blocking_ask(SetPresentationUnloaded { unloaded: true }));
    let work = entered(gate);
    assert!(work.scenes.is_empty());
    work.release();
    unload.finish(&f.engine, &[]).unwrap();
    assert_eq!(
        f.in_flight(),
        successful,
        "empty unload worker does not fabricate opening owners"
    );
    f.close().await;
}

#[tokio::test]
async fn journal_shutdown_during_real_blocked_load_cannot_be_reopened_by_late_worker_success() {
    let f = Fixture::new(configured(), vec![empty_row(1, 60)]);
    f.edit(A, 0.63);
    let gate = f.engine.hold_next_reconcile(Ok(vec![result(1, 5401)]));
    let pending = f.start_apply(A, true);
    let work = entered(gate);
    assert_eq!(f.in_flight().len(), 1);
    let journal = f.journal();
    journal.clean_shutdown();
    assert!(f.in_flight().is_empty());
    work.release();
    pending
        .finish(&f.engine, &[SceneHandle::new(5401)])
        .unwrap();
    assert!(f.in_flight().is_empty());
    assert!(journal.strikes().is_empty());
    drop(journal);
    f.close().await;
}

#[tokio::test]
async fn genuine_cache_clear_runs_force_refresh_worker_and_preserves_committed_draft() {
    let f = Fixture::new(configured(), vec![empty_row(1, 60)]);
    f.edit(A, 0.34);
    f.successful_apply(A, &[(1, 5501)]);
    let cache_file = f.paths.shader_cache_root().join("owned-obsolete-cache.bin");
    f.root.check(&cache_file);
    fs::create_dir_all(cache_file.parent().unwrap()).unwrap();
    fs::write(&cache_file, b"owned old shader bytes").unwrap();
    let baseline = f.draft(A).saved;
    let app_disk = f.app_bytes();
    let gate = f.engine.hold_next_reconcile(Ok(vec![result(1, 5502)]));
    let handle = f.handle().clone();
    let pending = request(move || handle.blocking_ask(ClearShaderCache));
    let work = entered(gate);
    assert!(work.scenes.iter().all(|scene| scene.force_shader_refresh));
    assert!(
        !cache_file.exists(),
        "genuine cache IO precedes forced worker"
    );
    work.release();
    pending
        .finish(&f.engine, &[SceneHandle::new(5502)])
        .unwrap();
    assert_eq!(f.draft(A).saved, baseline);
    assert!(!f.draft(A).dirty);
    assert_eq!(f.app_bytes(), app_disk);
    assert_eq!(f.snapshots().app.active_wallpaper_ids, vec![A.to_owned()]);
    f.repairs_idle();
    f.close().await;
}

#[tokio::test]
async fn assigned_genuine_holds_are_sorted_and_predicted_activation_error_restores_lift_without_repair()
 {
    let mut app = configured();
    app.monitors.push(assignment(connected(2), Some(B)));
    let f = Fixture::with_holds(app, vec![], &[B, A]);
    f.handle().blocking_ask(Bootstrap).unwrap();
    assert_eq!(
        f.snapshots().app.held_wallpaper_ids,
        vec![A.to_owned(), B.to_owned()]
    );
    f.engine
        .replace_display_rows(vec![empty_row(1, 60), empty_row(2, 144)]);
    let mut invalid = f.draft(A).saved;
    invalid.audio.volume = 2.0;
    f.handle()
        .blocking_ask(ReplaceWallpaperConfigForTest {
            id: A.into(),
            config: invalid,
        })
        .unwrap();
    let strikes = f.journal().strikes();
    let before = started_reconciles(&f.engine);
    let app = f.app();
    let wallpapers = [
        (A.to_owned(), f.draft(A).pending),
        (B.to_owned(), f.draft(B).pending),
    ]
    .into_iter()
    .collect();
    let models = [A, B]
        .into_iter()
        .map(|id| {
            (
                id.to_owned(),
                crate::project::ProjectModel::parse(id, PROJECT).unwrap(),
            )
        })
        .collect();
    let displays = f.engine.display_rows();
    let library = f.snapshots().library.wallpapers;
    let suspended = BTreeSet::new();
    let mut held = f.holds();
    held.remove(A);
    let expected = crate::engine::ActivationInputs {
        app_config: &app,
        wallpapers: &wallpapers,
        library: Some(&library),
        displays: &displays,
        paused: false,
        suspended_displays: &suspended,
        paths: &f.paths,
        force_shader_refresh: false,
        project_models: &models,
        frame_rate_cap: None,
        audio_suppressed: false,
        held: &held,
    }
    .build_owned()
    .unwrap_err();
    let error = f.start_apply(A, true).finish(&f.engine, &[]).unwrap_err();
    assert_eq!(error_pair(&error), error_pair(&expected));
    assert!(f.holds().contains(A));
    assert_eq!(f.journal().strikes(), strikes);
    assert_eq!(started_reconciles(&f.engine), before);
    assert!(f.handle().blocking_ask(RepairsIdle).unwrap());
    f.close().await;
}

#[tokio::test]
async fn immediate_mirror_live_mute_ors_suppression_without_saving_suppression_as_user_preference()
{
    let f = Fixture::new(mirrored(), vec![empty_row(1, 60), empty_row(2, 144)]);
    f.edit(A, 0.35);
    f.successful_apply(A, &[(1, 5601), (2, 5602)]);
    f.handle()
        .blocking_ask(SetAudioSuppressed { suppressed: true })
        .unwrap();
    f.edit(A, 0.36);
    let consumed = f.successful_apply(A, &[(1, 5603), (2, 5604)]);
    assert!(
        consumed.iter().all(|scene| scene.audio_muted),
        "authoritative worker descriptors consume live suppression, not only saved mute values"
    );
    assert!(!f.store.load_wallpaper(A).unwrap().audio.muted);
    let reply = f
        .handle()
        .blocking_ask::<_, BridgeDisplayMutationBundle>(SetMirrorMuted {
            display_id: "2".into(),
            muted: false,
        })
        .unwrap();
    assert!(!row(&reply.settings, &f.key(2)).muted);
    assert!(
        f.engine
            .live_scene_controls(SceneHandle::new(5604))
            .unwrap()
            .audio_muted
    );
    assert!(
        !f.store
            .load()
            .unwrap()
            .config
            .monitor_settings
            .iter()
            .find(|m| m.selector == connected(2))
            .unwrap()
            .muted
    );
    f.handle()
        .blocking_ask(SetAudioSuppressed { suppressed: false })
        .unwrap();
    f.handle()
        .blocking_ask::<_, BridgeDisplayMutationBundle>(SetMirrorMuted {
            display_id: "2".into(),
            muted: false,
        })
        .unwrap();
    assert!(
        !f.engine
            .live_scene_controls(SceneHandle::new(5604))
            .unwrap()
            .audio_muted
    );
    f.close().await;
}

#[tokio::test]
async fn mirror_relationship_refusals_preserve_committed_state_before_delegation() {
    for cycle in [false, true] {
        let mut app = configured();
        app.monitors.push(assignment(connected(2), Some(B)));
        app.monitors.push(MonitorCfg {
            selector: connected(3),
            enabled: true,
            mode: "mirror".into(),
            wallpaper: None,
            mirror_target: Some(connected(if cycle { 4 } else { 2 })),
        });
        if cycle {
            app.monitors.push(MonitorCfg {
                selector: connected(4),
                enabled: true,
                mode: "mirror".into(),
                wallpaper: None,
                mirror_target: Some(connected(3)),
            });
        }
        let f = Fixture::new(app, (1..=4).map(|id| empty_row(id, 60)).collect());
        let before = f.app();
        let disk = f.app_bytes();
        for target in ["2", "3", "unknown-target", ""] {
            let error = f
                .handle()
                .blocking_ask::<_, BridgeDisplayMutationBundle>(SetMirrorTarget {
                    display_id: "2".into(),
                    target_display_id: target.into(),
                })
                .unwrap_err();
            assert_eq!(error.kind(), BridgeErrorKind::InvalidInput);
            assert_eq!(f.app(), before);
            assert_eq!(f.app_bytes(), disk);
        }
        assert_eq!(started_reconciles(&f.engine), 0);
        f.close().await;
    }
}

#[tokio::test]
async fn empty_inventory_identity_target_still_requires_real_live_resolution() {
    let mut app = configured();
    app.monitors.push(assignment(selector(2), None));
    let remembered = remembered_rows(&[
        ("primary", "Owned primary (1 - Primary)"),
        ("2", "Owned second"),
    ]);
    let f = Fixture::with_initial(app, vec![], remembered, &[]);
    let target = SerializedSelector::Identity {
        uuid: Some("not-connected-owned-panel".into()),
        vendor_id: None,
        model_id: None,
        serial_number: None,
        unit_number: None,
        name: None,
    };
    let before = f.app_bytes();
    let error = f
        .handle()
        .blocking_ask::<_, BridgeDisplayMutationBundle>(SetMirrorTarget {
            display_id: "2".into(),
            target_display_id: target.id(),
        })
        .unwrap_err();
    assert_eq!(error.kind(), BridgeErrorKind::InvalidInput);
    assert_eq!(f.app_bytes(), before);
    assert_eq!(started_reconciles(&f.engine), 0);
    f.close().await;
}

#[tokio::test]
async fn no_reconcile_save_failure_does_not_invalidate_older_work_but_success_does() {
    for fail in [false, true] {
        let f = Fixture::new(configured(), vec![empty_row(1, 60), empty_row(2, 144)]);
        f.handle()
            .blocking_ask(SetScalingFactor {
                wallpaper_id: B.into(),
                display_id: "2".into(),
                factor: 0.71,
            })
            .unwrap();
        assert!(!f.draft(B).requires_reconcile);
        f.edit(A, 0.66);
        let gate = f.engine.hold_next_reconcile(Ok(vec![result(1, 5801)]));
        let older = f.start_apply(A, true);
        let work = entered(gate);
        let obstruction = if fail {
            Some(SaveObstruction::new(&f, false))
        } else {
            None
        };
        let outcome = f.start_apply(B, true).finish(&f.engine, &[]);
        if fail {
            assert!(outcome.is_err());
        } else {
            assert!(!outcome.unwrap().wallpaper_options.dirty);
        }
        drop(obstruction);
        assert_eq!(started_reconciles(&f.engine), 1);
        let repair_gate = if fail {
            None
        } else {
            Some(f.engine.hold_next_reconcile(Err(EngineError::Render(
                "no-reconcile supersession repair".into(),
            ))))
        };
        work.release();
        let reply = older.finish(&f.engine, &[SceneHandle::new(5801)]).unwrap();
        assert_eq!(reply.wallpaper_options.dirty, !fail);
        assert_eq!(
            f.store
                .load_wallpaper(A)
                .unwrap()
                .property_overrides
                .get("gain")
                .and_then(|v| v.as_f64()),
            if fail { Some(0.66) } else { None }
        );
        if let Some(repair_gate) = repair_gate {
            entered(repair_gate).release();
        }
        f.repairs_idle();
        f.close().await;
    }
}

#[tokio::test]
async fn empty_inventory_primary_eject_does_not_guess_physical_aliases_from_title() {
    let mut app = configured();
    app.monitors.push(assignment(selector(1), Some(A)));
    app.monitors.push(assignment(connected(1), Some(A)));
    app.monitors.push(assignment(selector(2), Some(B)));
    let remembered = remembered_rows(&[
        ("primary", "An owned panel (unrelated group) (1 - Primary)"),
        ("2", "Owned second"),
    ]);
    let f = Fixture::with_initial(app, vec![], remembered, &[]);
    let gate = f.engine.hold_next_reconcile(Ok(vec![]));
    let handle = f.handle().clone();
    let pending = request(move || {
        handle.blocking_ask(EjectWallpaperFromDisplay {
            display_id: "primary".into(),
            wallpaper_id: A.into(),
        })
    });
    let work = entered(gate);
    assert!(work.scenes.is_empty());
    work.release();
    let _: BridgeDisplayMutationBundle = pending.finish(&f.engine, &[]).unwrap();
    let saved = f.store.load().unwrap().config;
    assert!(
        saved
            .monitors
            .iter()
            .find(|m| m.selector == SerializedSelector::Primary)
            .unwrap()
            .wallpaper
            .is_none()
    );
    assert_eq!(
        saved
            .monitors
            .iter()
            .find(|m| m.selector == selector(1))
            .unwrap()
            .wallpaper
            .as_deref(),
        Some(A)
    );
    assert_eq!(
        saved
            .monitors
            .iter()
            .find(|m| m.selector == connected(1))
            .unwrap()
            .wallpaper
            .as_deref(),
        Some(A)
    );
    assert!(
        saved
            .monitors
            .iter()
            .any(|m| m.selector == selector(2) && m.wallpaper.as_deref() == Some(B))
    );
    f.close().await;
}

#[tokio::test]
async fn standalone_refuses_unusable_remembered_primary_source_but_accepts_known_numeric_source() {
    for usable_primary in [false, true] {
        let title = if usable_primary {
            "Owned panel (unrelated group) (1 - Primary)"
        } else {
            "Owned panel without a usable source group"
        };
        let remembered = remembered_rows(&[("primary", title), ("2", "Owned numeric second")]);
        let f = Fixture::with_initial(AppConfig::default(), vec![], remembered, &[]);
        let app = f.app();
        let disk = f.app_bytes();
        if usable_primary {
            let gate = f.engine.hold_next_reconcile(Ok(vec![]));
            let primary = f.start_mode("primary", BridgeDisplayMode::Standalone);
            entered(gate).release();
            let reply = primary.finish(&f.engine, &[]).unwrap();
            assert!(row(&reply.settings, "primary").enabled);
            assert_eq!(
                row(&reply.settings, "primary").mode,
                BridgeDisplayMode::Standalone
            );
        } else {
            let error = f
                .handle()
                .blocking_ask::<_, BridgeDisplayMutationBundle>(SetDisplayMode {
                    display_id: "primary".into(),
                    mode: BridgeDisplayMode::Standalone,
                })
                .unwrap_err();
            assert_eq!(error.kind(), BridgeErrorKind::InvalidInput);
            assert_eq!(f.app(), app);
            assert_eq!(f.app_bytes(), disk);
            assert_eq!(started_reconciles(&f.engine), 0);
        }
        let gate = f.engine.hold_next_reconcile(Ok(vec![]));
        let positive = f.start_mode("2", BridgeDisplayMode::Standalone);
        let work = entered(gate);
        assert!(work.scenes.is_empty());
        work.release();
        let reply = positive.finish(&f.engine, &[]).unwrap();
        assert_eq!(
            row(&reply.settings, "2").mode,
            BridgeDisplayMode::Standalone
        );
        assert_eq!(
            started_reconciles(&f.engine),
            if usable_primary { 2 } else { 1 }
        );
        f.close().await;
    }
}

#[tokio::test]
async fn mirror_mode_case_variant_supports_immediate_controls_and_empty_inventory_overlay() {
    for mode in ["mirror", "Mirror"] {
        let mut app = configured();
        app.monitors.push(MonitorCfg {
            selector: selector(2),
            enabled: true,
            mode: mode.into(),
            wallpaper: None,
            mirror_target: Some(SerializedSelector::Primary),
        });
        let remembered = remembered_rows(&[
            ("primary", "Owned primary (1 - Primary)"),
            ("1", "Owned first"),
            ("2", "Owned second"),
        ]);
        let f = Fixture::with_initial(app, vec![], remembered, &[]);
        f.handle()
            .blocking_ask::<_, BridgeDisplayMutationBundle>(SetMirrorVolume {
                display_id: "2".into(),
                volume: 0.43,
            })
            .unwrap();
        assert_eq!(
            f.store
                .load()
                .unwrap()
                .config
                .monitor_settings
                .iter()
                .find(|settings| settings.selector == selector(2))
                .unwrap()
                .volume,
            0.43
        );
        assert_eq!(
            f.count(|observation| matches!(
                observation,
                EngineObservation::Volume {
                    phase: OperationPhase::Started,
                    ..
                }
            )),
            0,
            "the accepted case variant also supports genuine persistence-only immediate control"
        );
        let gate = f.engine.hold_next_reconcile(Ok(vec![]));
        let handle = f.handle().clone();
        let disable = request(move || {
            handle.blocking_ask(SetDisplayEnabled {
                display_id: "2".into(),
                enabled: false,
            })
        });
        entered(gate).release();
        let reply: BridgeDisplayMutationBundle = disable.finish(&f.engine, &[]).unwrap();
        let changed = row(&reply.settings, "2");
        assert!(!changed.enabled);
        assert_eq!(changed.mode, BridgeDisplayMode::Mirror);
        assert_eq!(changed.selected_mirror_target.as_deref(), Some("primary"));
        let remembered: BTreeMap<String, BridgeDisplaySettingsRow> =
            f.handle().blocking_ask(ReadRememberedRows).unwrap();
        assert_eq!(remembered["2"].mode, BridgeDisplayMode::Mirror);
        assert_eq!(
            remembered["2"].selected_mirror_target.as_deref(),
            Some("primary")
        );
        assert_eq!(
            f.app()
                .monitors
                .iter()
                .find(|monitor| monitor.selector == selector(2))
                .unwrap()
                .mode,
            mode,
            "local case compatibility does not introduce global mode normalization"
        );
        f.close().await;
    }
}

#[tokio::test]
async fn unloaded_apply_prediction_refusal_restores_hold_without_superseding_blocked_valid_apply() {
    let mut app = configured();
    app.monitors.push(assignment(connected(2), Some(B)));
    let f = Fixture::with_holds(app, vec![], &[A, B]);
    f.handle().blocking_ask(Bootstrap).unwrap();
    f.engine
        .replace_display_rows(vec![empty_row(1, 60), empty_row(2, 144)]);
    let unload_gate = f.engine.hold_next_reconcile(Ok(vec![]));
    let handle = f.handle().clone();
    let unload = request(move || handle.blocking_ask(SetPresentationUnloaded { unloaded: true }));
    let unloading = entered(unload_gate);
    assert!(unloading.scenes.is_empty());
    unloading.release();
    unload.finish(&f.engine, &[]).unwrap();
    let mut invalid = f.draft(A).saved;
    invalid.audio.volume = 2.0;
    f.handle()
        .blocking_ask(ReplaceWallpaperConfigForTest {
            id: A.into(),
            config: invalid,
        })
        .unwrap();
    f.edit(B, 0.81);
    let valid_gate = f.engine.hold_next_reconcile(Ok(vec![]));
    let valid = f.start_apply(B, true);
    let valid_work = entered(valid_gate);
    assert!(
        valid_work.scenes.is_empty(),
        "the real authoritative unloaded worker plan is empty"
    );
    assert!(f.holds().contains(A));
    assert!(!f.holds().contains(B));
    let strikes = f.journal().strikes();
    let before = started_reconciles(&f.engine);
    let app = f.app();
    let wallpapers = [
        (A.to_owned(), f.draft(A).pending),
        (B.to_owned(), f.draft(B).saved),
    ]
    .into_iter()
    .collect();
    let models = [A, B]
        .into_iter()
        .map(|id| {
            (
                id.to_owned(),
                crate::project::ProjectModel::parse(id, PROJECT).unwrap(),
            )
        })
        .collect();
    let displays = f.engine.display_rows();
    let library = f.snapshots().library.wallpapers;
    let suspended = BTreeSet::new();
    let mut held_for_prediction = f.holds();
    held_for_prediction.remove(A);
    let expected = crate::engine::ActivationInputs {
        app_config: &app,
        wallpapers: &wallpapers,
        library: Some(&library),
        displays: &displays,
        paused: false,
        suspended_displays: &suspended,
        paths: &f.paths,
        force_shader_refresh: false,
        project_models: &models,
        frame_rate_cap: None,
        audio_suppressed: false,
        held: &held_for_prediction,
    }
    .build_owned()
    .unwrap_err();
    let error = f.start_apply(A, true).finish(&f.engine, &[]).unwrap_err();
    assert_eq!(error_pair(&error), error_pair(&expected));
    assert!(
        f.holds().contains(A),
        "early prediction refusal restores the lifted memory hold"
    );
    assert_eq!(f.journal().strikes(), strikes);
    assert_eq!(
        started_reconciles(&f.engine),
        before,
        "unloaded does not skip prediction or delegate the refused candidate"
    );
    assert!(
        f.handle().blocking_ask(RepairsIdle).unwrap(),
        "prediction refusal must not retain repair behind the known blocked valid operation"
    );
    assert!(f.snapshots().app.errors.is_empty());
    valid_work.release();
    let committed = valid.finish(&f.engine, &[]).unwrap();
    assert!(
        !committed.wallpaper_options.dirty,
        "refused Apply must not reserve over the blocked valid operation"
    );
    assert_eq!(property(&committed.wallpaper_options), 0.81);
    assert_eq!(
        f.store.load_wallpaper(B).unwrap().property_overrides["gain"].as_f64(),
        Some(0.81)
    );
    f.repairs_idle();
    let mut repaired_input = f.draft(A).saved;
    repaired_input.audio.volume = 1.0;
    f.handle()
        .blocking_ask(ReplaceWallpaperConfigForTest {
            id: A.into(),
            config: repaired_input,
        })
        .unwrap();
    let positive_gate = f.engine.hold_next_reconcile(Ok(vec![]));
    let positive = f.start_apply(A, true);
    let positive_work = entered(positive_gate);
    assert!(positive_work.scenes.is_empty());
    positive_work.release();
    assert!(
        !positive
            .finish(&f.engine, &[])
            .unwrap()
            .wallpaper_options
            .dirty
    );
    assert!(!f.holds().contains(A));
    assert!(!f.journal().strikes().contains_key(A));
    f.close().await;
}

#[tokio::test]
async fn stale_repair_finishing_before_newer_apply_defers_without_inventing_a_prior_followup() {
    for stale_error in [false, true] {
        let f = Fixture::new(reduced(), vec![empty_row(1, 60)]);
        f.edit(A, 0.41);
        let failed_gate = f
            .engine
            .hold_next_reconcile(Err(EngineError::Render("initial repair cause".into())));
        let failed = f.start_apply(A, true);
        let failed_work = entered(failed_gate);
        let repair_gate = f.engine.hold_next_reconcile(Ok(vec![result(1, 6101)]));
        failed_work.release();
        assert_error(
            failed.finish(&f.engine, &[]).unwrap_err(),
            BridgeErrorKind::Engine,
            &engine_boundary("initial repair cause"),
        );
        let repair = entered(repair_gate);
        assert_eq!(repair.scenes[0].property_override_json, None);
        if stale_error {
            f.engine.fail_next_render_scale(EngineError::Render(
                "stale R result must not append".into(),
            ));
        }
        let repair_completion = f
            .engine
            .hold_next_render_scale_completion(SceneHandle::new(6101));
        repair.release();
        let repair =
            completed_render_scale(repair_completion, &f.engine, &[SceneHandle::new(6101)]);
        f.edit(A, 0.82);
        let newer_gate = f.engine.hold_next_reconcile(Ok(vec![result(1, 6102)]));
        let newer = f.start_apply(A, true);
        wait_admitted(&f.engine, 3);
        assert!(f.handle().blocking_ask(RepairActive).unwrap());
        // No completed stale/failed request has asked for a follow-up since R started.
        repair.release();
        let end = Instant::now() + DEADLINE;
        while f.handle().blocking_ask(RepairActive).unwrap() {
            assert!(
                Instant::now() < end,
                "actual stale-R receiving-side ownership release deadline"
            );
            thread::sleep(QUANTUM);
        }
        let newer_work = entered(newer_gate);
        let mut deferred_gate = f
            .engine
            .hold_next_reconcile(Err(EngineError::Render("repair after current B".into())));
        assert!(
            !f.handle().blocking_ask(RepairsIdle).unwrap(),
            "R is acknowledged inactive while its repair waits behind known unfinished B"
        );
        newer.is_pending();
        assert!(matches!(
            deferred_gate.entered.try_recv(),
            Err(tokio::sync::oneshot::error::TryRecvError::Empty)
        ));
        assert_eq!(
            f.snapshots().app.errors,
            vec![engine_boundary("initial repair cause")]
        );
        newer_work.release();
        let current = newer.finish(&f.engine, &[SceneHandle::new(6102)]).unwrap();
        assert!(
            !current.wallpaper_options.dirty,
            "stale R without a prior follow-up must not supersede B publication"
        );
        assert_eq!(property(&current.wallpaper_options), 0.82);
        assert_eq!(
            f.store.load_wallpaper(A).unwrap().property_overrides["gain"].as_f64(),
            Some(0.82)
        );
        let deferred = entered(deferred_gate);
        assert_eq!(
            json_gain(&deferred.scenes[0].property_override_json),
            Some(0.82),
            "only after B commits does deferred repair capture its newly committed state"
        );
        deferred.release();
        f.repairs_idle();
        assert_eq!(
            f.snapshots().app.errors,
            vec![
                engine_boundary("initial repair cause"),
                engine_boundary("repair after current B")
            ]
        );
        f.close().await;
    }
}

fn wait_live(engine: &ControlledEngine, handles: &[SceneHandle]) {
    let end = Instant::now() + DEADLINE;
    loop {
        let rows = engine.display_rows();
        if handles
            .iter()
            .all(|handle| rows.iter().any(|row| row.handle == Some(*handle)))
        {
            return;
        }
        assert!(
            Instant::now() < end,
            "exact actual live-handle publication deadline"
        );
        thread::sleep(QUANTUM);
    }
}

fn wait_admitted(engine: &ControlledEngine, count: usize) {
    let end = Instant::now() + DEADLINE;
    while started_reconciles(engine) < count {
        assert!(
            Instant::now() < end,
            "actual outer reconcile admission deadline"
        );
        thread::sleep(QUANTUM);
    }
}

struct CompletedRenderScale {
    release: tokio::sync::oneshot::Sender<()>,
}
impl CompletedRenderScale {
    fn release(self) {
        self.release
            .send(())
            .expect("real final poststep still parked");
    }
}
fn completed_render_scale(
    mut control: OperationControl,
    engine: &ControlledEngine,
    handles: &[SceneHandle],
) -> CompletedRenderScale {
    let end = Instant::now() + DEADLINE;
    loop {
        for handle in handles {
            if engine
                .display_rows()
                .iter()
                .any(|row| row.handle == Some(*handle))
            {
                engine.emit_first_frame(*handle);
            }
        }
        match control.entered.try_recv() {
            Ok(()) => {
                return CompletedRenderScale {
                    release: control.release,
                };
            }
            Err(tokio::sync::oneshot::error::TryRecvError::Empty) => {
                assert!(
                    Instant::now() < end,
                    "actual final poststep completion deadline"
                );
                thread::sleep(QUANTUM);
            }
            Err(tokio::sync::oneshot::error::TryRecvError::Closed) => {
                panic!("final poststep completion lost producer")
            }
        }
    }
}
impl Fixture {
    fn parked_apply(
        &self,
        id: &str,
        handles: &[(u32, u64)],
    ) -> (Pending<BridgeWallpaperMutationBundle>, CompletedRenderScale) {
        assert_eq!(
            self.snapshots().settings.render_scale,
            0.5,
            "terminal hold requires explicit effective reduced scale"
        );
        let core = self.engine.hold_next_reconcile(Ok(handles
            .iter()
            .map(|(display, handle)| result(*display, *handle))
            .collect()));
        let pending = self.start_apply(id, true);
        let work = entered(core);
        assert_eq!(
            work.scenes.len(),
            handles.len(),
            "this helper requires complete coherent results"
        );
        let last = work
            .scenes
            .iter()
            .rev()
            .find_map(|scene| {
                handles
                    .iter()
                    .find(|(display, _)| *display == scene.display.display_id)
                    .map(|(_, handle)| SceneHandle::new(*handle))
            })
            .expect("at least one actual processed descriptor");
        let completion = self.engine.hold_next_render_scale_completion(last);
        work.release();
        let completion = completed_render_scale(
            completion,
            &self.engine,
            &handles
                .iter()
                .map(|(_, handle)| SceneHandle::new(*handle))
                .collect::<Vec<_>>(),
        );
        pending.is_pending();
        (pending, completion)
    }
}

#[tokio::test]
async fn failed_cancel_after_mutation_and_failed_rollback_does_not_supersede_held_changed_apply() {
    let f = Fixture::new(configured(), vec![empty_row(1, 60)]);
    f.edit(A, 0.3);
    f.successful_apply(A, &[(1, 6301)]);
    f.stage_factor("primary", 0.7);
    f.edit(A, 0.84);
    let old_handle = SceneHandle::new(6301);
    let core = f.engine.hold_next_reconcile(Ok(vec![result(1, 6302)]));
    let older = f.start_apply(A, true);
    let work = entered(core);
    assert_eq!(f.engine.display_rows()[0].handle, Some(old_handle));
    f.engine.fail_selected_setter(
        SelectedSetter::ScalingFactor,
        old_handle,
        1,
        FaultTiming::AfterMutation,
        EngineError::Render("failed Cancel with reserved Apply".into()),
    );
    f.engine.fail_selected_setter(
        SelectedSetter::ScalingFactor,
        old_handle,
        2,
        FaultTiming::BeforeMutation,
        EngineError::Render("rollback refusal with reserved Apply".into()),
    );
    assert_error(
        f.cancel(A).unwrap_err(),
        BridgeErrorKind::Engine,
        &engine_boundary("failed Cancel with reserved Apply"),
    );
    assert_eq!(
        f.engine
            .live_scene_controls(old_handle)
            .unwrap()
            .scaling_factor,
        1.0
    );
    assert!(f.draft(A).dirty);
    assert!(f.snapshots().app.errors.is_empty());
    assert!(f.handle().blocking_ask(RepairsIdle).unwrap());
    work.release();
    let committed = older.finish(&f.engine, &[SceneHandle::new(6302)]).unwrap();
    assert!(
        !committed.wallpaper_options.dirty,
        "failed Cancel cannot invalidate already reserved Apply"
    );
    assert_eq!(property(&committed.wallpaper_options), 0.84);
    let saved = f.store.load_wallpaper(A).unwrap();
    assert_eq!(saved.property_overrides["gain"].as_f64(), Some(0.84));
    assert!(
        saved
            .monitors
            .iter()
            .any(|monitor| monitor.scaling_factor == 0.7)
    );
    assert_eq!(
        f.engine.display_rows()[0].handle,
        Some(SceneHandle::new(6302))
    );
    f.repairs_idle();
    f.close().await;
}

#[tokio::test]
async fn primary_role_is_distinct_from_identity_addressed_disable_eject_and_mirror() {
    for stable_uuid in [false, true] {
        let mut rows = vec![empty_row(1, 60), empty_row(2, 144)];
        if !stable_uuid {
            for row in &mut rows {
                row.identity.uuid = None;
                row.desc.identity = row.identity.clone();
            }
        }
        let physical_primary = rows[0].connected_selector();
        let other = rows[1].connected_selector();
        let mut app = configured();
        app.monitors = vec![
            assignment(SerializedSelector::Primary, Some(A)),
            assignment(physical_primary.clone(), Some(A)),
            assignment(other.clone(), Some(B)),
        ];
        let f = Fixture::new(app, rows);
        let before = f.app_bytes();
        let error = f
            .handle()
            .blocking_ask::<_, BridgeDisplayMutationBundle>(SetDisplayMode {
                display_id: "primary".into(),
                mode: BridgeDisplayMode::Mirror,
            })
            .unwrap_err();
        assert_eq!(error.kind(), BridgeErrorKind::InvalidInput);
        assert_eq!(f.app_bytes(), before);
        assert_eq!(started_reconciles(&f.engine), 0);

        let disable_gate = f
            .engine
            .hold_next_reconcile(Ok(vec![result(1, 7101), result(2, 7102)]));
        let handle = f.handle().clone();
        let source = physical_primary.id();
        let disable = request(move || {
            handle.blocking_ask(SetDisplayEnabled {
                display_id: source,
                enabled: false,
            })
        });
        let disabling = entered(disable_gate);
        let role_path = disabling
            .scenes
            .iter()
            .find(|scene| scene.display.display_id == 1)
            .unwrap()
            .scene_path
            .clone();
        let other_path = disabling
            .scenes
            .iter()
            .find(|scene| scene.display.display_id == 2)
            .unwrap()
            .scene_path
            .clone();
        assert_ne!(role_path, other_path);
        disabling.release();
        let _: BridgeDisplayMutationBundle = disable
            .finish(&f.engine, &[SceneHandle::new(7101), SceneHandle::new(7102)])
            .unwrap();
        let saved = f.app();
        assert!(
            !saved
                .monitors
                .iter()
                .find(|monitor| monitor.selector == physical_primary)
                .unwrap()
                .enabled
        );
        let role = saved
            .monitors
            .iter()
            .find(|monitor| monitor.selector == SerializedSelector::Primary)
            .unwrap();
        assert!(role.enabled);
        assert_eq!(role.mode, "independent");
        assert_eq!(role.wallpaper.as_deref(), Some(A));

        let eject_gate = f
            .engine
            .hold_next_reconcile(Ok(vec![result(1, 7111), result(2, 7112)]));
        let handle = f.handle().clone();
        let source = physical_primary.id();
        let eject = request(move || {
            handle.blocking_ask(EjectWallpaperFromDisplay {
                display_id: source,
                wallpaper_id: A.into(),
            })
        });
        let ejecting = entered(eject_gate);
        assert_eq!(
            ejecting
                .scenes
                .iter()
                .find(|scene| scene.display.display_id == 1)
                .unwrap()
                .scene_path,
            role_path
        );
        assert_eq!(
            ejecting
                .scenes
                .iter()
                .find(|scene| scene.display.display_id == 2)
                .unwrap()
                .scene_path,
            other_path
        );
        ejecting.release();
        let _: BridgeDisplayMutationBundle = eject
            .finish(&f.engine, &[SceneHandle::new(7111), SceneHandle::new(7112)])
            .unwrap();
        let saved = f.store.load().unwrap().config;
        assert!(
            saved
                .monitors
                .iter()
                .find(|monitor| monitor.selector == physical_primary)
                .unwrap()
                .wallpaper
                .is_none()
        );
        assert_eq!(
            saved
                .monitors
                .iter()
                .find(|monitor| monitor.selector == SerializedSelector::Primary)
                .unwrap()
                .wallpaper
                .as_deref(),
            Some(A)
        );
        assert_eq!(
            saved
                .monitors
                .iter()
                .find(|monitor| monitor.selector == other)
                .unwrap()
                .wallpaper
                .as_deref(),
            Some(B)
        );

        let mirror_gate = f
            .engine
            .hold_next_reconcile(Ok(vec![result(1, 7121), result(2, 7122)]));
        let mirror = f.start_mode(&physical_primary.id(), BridgeDisplayMode::Mirror);
        let mirroring = entered(mirror_gate);
        assert_eq!(
            mirroring
                .scenes
                .iter()
                .find(|scene| scene.display.display_id == 1)
                .unwrap()
                .scene_path,
            role_path
        );
        mirroring.release();
        mirror
            .finish(&f.engine, &[SceneHandle::new(7121), SceneHandle::new(7122)])
            .unwrap();
        let saved = f.app();
        let physical = saved
            .monitors
            .iter()
            .find(|monitor| monitor.selector == physical_primary)
            .unwrap();
        assert!(physical.enabled);
        assert_eq!(physical.mode, "mirror");
        assert_eq!(physical.mirror_target.as_ref(), Some(&other));
        let role = saved
            .monitors
            .iter()
            .find(|monitor| monitor.selector == SerializedSelector::Primary)
            .unwrap();
        assert!(role.enabled);
        assert_eq!(role.mode, "independent");
        assert_eq!(role.mirror_target, None);
        assert_eq!(role.wallpaper.as_deref(), Some(A));
        f.close().await;
    }
}
