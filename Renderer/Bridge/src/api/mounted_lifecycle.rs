//! Independently authored mounted tests. Source-only: parent compiles and executes.
use super::first_frame_handoff::{FirstFrameDelivery, FirstFrameHandoff, FirstFrameTarget};
use crate::{
    actor::lifecycle_test_support::{MountedStateObservation, runtime_probe},
    actor::{BridgeActor, BridgeActorHandle, state::BridgeActorState},
    api::{BridgeBuilder, BridgeError, BridgeErrorKind, WallpaperBridge},
    config::{
        AppConfig, BatteryModeCfg, ConfigStore, MonitorCfg, SerializedSelector, WallpaperConfig,
    },
    engine::mounted_readiness::{self, FirstFrameReadiness},
    engine::{AudioCaptureDemand, EngineFacade, LoadJournal},
    paths::BridgePaths,
    power::PowerSource,
};
use kameo::{
    actor::WeakActorRef,
    message::{Context, Message},
};
use std::{
    collections::{BTreeSet, HashMap, HashSet},
    future::{Future, poll_fn},
    panic::{AssertUnwindSafe, catch_unwind, resume_unwind},
    pin::Pin,
    sync::{
        Arc, Mutex,
        atomic::{AtomicU64, AtomicUsize, Ordering},
    },
    task::Poll,
    time::Duration,
};
use tokio::sync::{mpsc, oneshot};
use wallpaper_core::project::{SceneDesc, SceneHandle, SceneResult, SceneTemplate};
use wallpaper_core::{DisplaySnapshotEntry, EngineError, FirstFrameCallback};

type EngineFuture<T> = Pin<Box<dyn Future<Output = Result<T, EngineError>> + Send + 'static>>;
const LIMIT: Duration = Duration::from_secs(15);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum OperationPhase {
    Started,
    Applied,
    Rejected,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum SelectedSetter {
    Volume,
    Muted,
    ScalingMode,
    ScalingFactor,
    AudioResponse,
    AudioCapture,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum FaultTiming {
    BeforeMutation,
    AfterMutation,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum ReconcileResultShape {
    MissingDisplay(u32),
    DuplicateDisplay(u32),
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum PropertyPreviewPhase {
    Attempted,
    Declined,
    Rejected,
    Applied,
    Unchanged,
}
#[derive(Clone, Debug, PartialEq)]
pub(crate) struct LiveSceneControls {
    pub scaling_mode: wallpaper_core::project::ScalingMode,
    pub scaling_factor: f64,
    pub audio_volume: wallpaper_core::media::audio::AudioVolume,
    pub audio_muted: bool,
    pub audio_response_enabled: bool,
    pub audio_capture_enabled: bool,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct ShownPropertyState {
    pub scene_path: String,
    pub flat_json: Option<String>,
}
#[derive(Clone, Debug, PartialEq)]
pub(crate) enum EngineObservation {
    Reconcile {
        scenes: Vec<SceneDesc>,
        phase: OperationPhase,
    },
    ReconcileCore {
        phase: OperationPhase,
    },
    PartialReconcilePublished {
        displays: Vec<(u32, Option<SceneHandle>)>,
    },
    ReconcilePrune {
        phase: OperationPhase,
    },
    PropertyPreview {
        handle: SceneHandle,
        scene_path: String,
        flat_json: String,
        phase: PropertyPreviewPhase,
    },
    Refresh {
        phase: OperationPhase,
    },
    Close {
        phase: OperationPhase,
    },
    PauseAll {
        paused: bool,
        suspended_displays: Vec<u32>,
        phase: OperationPhase,
    },
    PauseDisplay {
        display_id: u32,
        paused: bool,
        phase: OperationPhase,
    },
    Volume {
        handle: SceneHandle,
        volume: wallpaper_core::media::audio::AudioVolume,
        phase: OperationPhase,
    },
    Muted {
        handle: SceneHandle,
        muted: bool,
        phase: OperationPhase,
    },
    AudioResponse {
        handle: SceneHandle,
        enabled: bool,
        phase: OperationPhase,
    },
    MediaIntegration {
        handle: SceneHandle,
        enabled: bool,
        phase: OperationPhase,
    },
    Capture {
        handle: SceneHandle,
        enabled: bool,
        phase: OperationPhase,
    },
    Demand {
        demand: AudioCaptureDemand,
        phase: OperationPhase,
    },
    Fps {
        handle: SceneHandle,
        fps: u32,
        phase: OperationPhase,
    },
    RenderScale {
        handle: SceneHandle,
        scale: f32,
        phase: OperationPhase,
    },
    ScalingMode {
        handle: SceneHandle,
        mode: wallpaper_core::project::ScalingMode,
        phase: OperationPhase,
    },
    ScalingFactor {
        handle: SceneHandle,
        factor: f64,
        phase: OperationPhase,
    },
    Framing {
        handle: SceneHandle,
        framing: wallpaper_core::project::SceneFraming,
        phase: OperationPhase,
    },
    PreviewFraming {
        handle: SceneHandle,
        framing: wallpaper_core::project::SceneFraming,
        phase: OperationPhase,
    },
    Optimization {
        enabled: bool,
        phase: OperationPhase,
    },
    OnDemand {
        enabled: bool,
        phase: OperationPhase,
    },
    VideoSampling {
        enabled: bool,
        phase: OperationPhase,
    },
    Resolution {
        resolution: wallpaper_core::SceneResolution,
        phase: OperationPhase,
    },
}

pub(crate) struct ReconcileControl {
    pub entered: oneshot::Receiver<Vec<SceneDesc>>,
    pub release: oneshot::Sender<()>,
}
pub(crate) struct OperationControl {
    pub entered: oneshot::Receiver<()>,
    pub release: oneshot::Sender<()>,
}
struct ReconcilePlan {
    entered: oneshot::Sender<Vec<SceneDesc>>,
    release: oneshot::Receiver<()>,
    outcome: ReconcileOutcome,
}
enum ReconcileOutcome {
    Exact(Result<Vec<SceneResult>, EngineError>),
    Partial {
        live_after: Vec<DisplaySnapshotEntry>,
        error: EngineError,
    },
    Shaped {
        complete_results: Vec<SceneResult>,
        shape: ReconcileResultShape,
    },
}
struct SelectedSetterFault {
    setter: SelectedSetter,
    handle: SceneHandle,
    remaining: u32,
    timing: FaultTiming,
    error: EngineError,
}
struct OperationPlan {
    entered: oneshot::Sender<()>,
    release: oneshot::Receiver<()>,
    result: Result<(), EngineError>,
}
struct RenderScaleCompletionPlan {
    handle: SceneHandle,
    entered: oneshot::Sender<()>,
    release: oneshot::Receiver<()>,
}

#[derive(Debug, PartialEq, Eq)]
enum ReconcileBoundary {
    CoreCompleted,
    PruneCompleted,
    WaitingPending,
}
struct ReconcileWitness {
    core_completed: std::sync::atomic::AtomicBool,
    prune_completed: std::sync::atomic::AtomicBool,
    events: mpsc::UnboundedSender<ReconcileBoundary>,
}
#[derive(Default)]
struct LiveControls {
    required: HashMap<SceneHandle, bool>,
    capture: HashMap<SceneHandle, bool>,
    media: HashMap<SceneHandle, bool>,
    scale: HashMap<SceneHandle, f32>,
    scaling_mode: HashMap<SceneHandle, wallpaper_core::project::ScalingMode>,
    scaling_factor: HashMap<SceneHandle, f64>,
    framing: HashMap<SceneHandle, wallpaper_core::project::SceneFraming>,
    preview: HashMap<SceneHandle, wallpaper_core::project::SceneFraming>,
    shown_properties: HashMap<SceneHandle, ShownPropertyState>,
}
struct Data {
    rows: Vec<DisplaySnapshotEntry>,
    observations: Vec<EngineObservation>,
    saved: Option<FirstFrameCallback>,
    registration_count: usize,
    synchronous: Option<SceneHandle>,
    panic_after: bool,
    reconcile: Option<ReconcilePlan>,
    reconcile_witness: Option<Arc<ReconcileWitness>>,
    pause: Option<OperationPlan>,
    demand_plan: Option<OperationPlan>,
    close: Option<OperationPlan>,
    fps_error: Option<EngineError>,
    scale_error: Option<EngineError>,
    prune_error: Option<String>,
    selected_setter_faults: Vec<SelectedSetterFault>,
    property_preview_error: Option<EngineError>,
    render_scale_completions: Vec<RenderScaleCompletionPlan>,
    controls: LiveControls,
    global_pause: bool,
    display_pause: BTreeSet<u32>,
    demand: AudioCaptureDemand,
    optimization: Option<bool>,
    on_demand: Option<bool>,
    video_sampling: Option<bool>,
    resolution: Option<wallpaper_core::SceneResolution>,
    counters_enabled: bool,
    pointer_consumer: Option<wallpaper_core::PointerConsumerCallback>,
    pointer_activity: Option<wallpaper_core::PointerActivityCallback>,
    shortcut: Option<wallpaper_core::UserShortcutObserverCallback>,
    audio_requirement: Option<wallpaper_core::AudioRequirementCallback>,
}
struct Inner {
    data: Mutex<Data>,
    readiness: FirstFrameReadiness,
    turn: tokio::sync::Mutex<()>,
    audio: tokio::sync::Mutex<()>,
    slot: wallpaper_core::contract_testing::FirstFrameSlot,
    renderer: FirstFrameCallback,
}
/// Test IO only: no actor, runtime, native device or policy owner is retained.
#[derive(Clone)]
pub(crate) struct ControlledEngine {
    inner: Arc<Inner>,
}
impl ControlledEngine {
    pub(crate) fn new(initial_displays: Vec<DisplaySnapshotEntry>) -> Self {
        validate_rows(&initial_displays);
        let controls = LiveControls {
            shown_properties: shown_properties_from_rows(&initial_displays),
            ..LiveControls::default()
        };
        let slot = wallpaper_core::contract_testing::FirstFrameSlot::new();
        let renderer = slot.renderer_callback(); // Acquired before any installation.
        Self {
            inner: Arc::new(Inner {
                readiness: FirstFrameReadiness::new(),
                turn: tokio::sync::Mutex::new(()),
                audio: tokio::sync::Mutex::new(()),
                slot,
                renderer,
                data: Mutex::new(Data {
                    rows: initial_displays,
                    observations: vec![],
                    saved: None,
                    registration_count: 0,
                    synchronous: None,
                    panic_after: false,
                    reconcile: None,
                    pause: None,
                    demand_plan: None,
                    close: None,
                    reconcile_witness: None,
                    fps_error: None,
                    scale_error: None,
                    prune_error: None,
                    selected_setter_faults: vec![],
                    property_preview_error: None,
                    render_scale_completions: vec![],
                    controls,
                    global_pause: false,
                    display_pause: BTreeSet::new(),
                    demand: AudioCaptureDemand::default(),
                    optimization: None,
                    on_demand: None,
                    video_sampling: None,
                    resolution: None,
                    counters_enabled: false,
                    pointer_consumer: None,
                    pointer_activity: None,
                    shortcut: None,
                    audio_requirement: None,
                }),
            }),
        }
    }
    pub(crate) fn display_rows(&self) -> Vec<DisplaySnapshotEntry> {
        self.inner.data.lock().unwrap().rows.clone()
    }
    pub(crate) fn live_scene_controls(&self, handle: SceneHandle) -> Option<LiveSceneControls> {
        let data = self.inner.data.lock().unwrap();
        let template = direct_template(&data, handle)?;
        Some(LiveSceneControls {
            scaling_mode: data.controls.scaling_mode.get(&handle)
                .cloned().unwrap_or_else(|| template.scaling_mode.clone()),
            scaling_factor: data.controls.scaling_factor.get(&handle)
                .copied().unwrap_or(template.scaling_factor),
            audio_volume: template.audio_volume,
            audio_muted: template.audio_muted,
            audio_response_enabled: template.audio_response_enabled,
            audio_capture_enabled: data.controls.capture.get(&handle).copied().unwrap_or(false),
        })
    }
    pub(crate) fn audio_capture_state(&self, handle: SceneHandle) -> Option<bool> {
        self.inner.data.lock().unwrap().controls.capture.get(&handle).copied()
    }
    pub(crate) fn shown_property_state(&self, handle: SceneHandle) -> Option<ShownPropertyState> {
        self.inner.data.lock().unwrap().controls.shown_properties.get(&handle).cloned()
    }
    pub(crate) fn replace_display_rows(&self, rows: Vec<DisplaySnapshotEntry>) {
        validate_rows(&rows);
        let mut data = self.inner.data.lock().unwrap();
        data.rows = rows;
        data.controls.shown_properties = shown_properties_from_rows(&data.rows);
        prune_controls(&mut data);
    }
    fn observe_next_reconcile(&self) -> mpsc::UnboundedReceiver<ReconcileBoundary> {
        let (events, received) = mpsc::unbounded_channel();
        let mut data = self.inner.data.lock().unwrap();
        assert!(
            data.reconcile_witness.is_none(),
            "unconsumed case-local reconcile witness"
        );
        data.reconcile_witness = Some(Arc::new(ReconcileWitness {
            core_completed: std::sync::atomic::AtomicBool::new(false),
            prune_completed: std::sync::atomic::AtomicBool::new(false),
            events,
        }));
        received
    }
    pub(crate) fn saved_first_frame(&self) -> Option<FirstFrameCallback> {
        self.inner.data.lock().unwrap().saved.clone()
    }
    pub(crate) fn emit_first_frame(&self, handle: SceneHandle) {
        (self.inner.renderer)(handle);
    }
    pub(crate) fn registration_behavior(
        &self,
        synchronous: Option<SceneHandle>,
        panic_after: bool,
    ) {
        let mut data = self.inner.data.lock().unwrap();
        data.synchronous = synchronous;
        data.panic_after = panic_after;
    }
    pub(crate) fn registration_count(&self) -> usize {
        self.inner.data.lock().unwrap().registration_count
    }
    pub(crate) fn hold_next_reconcile(
        &self,
        result: Result<Vec<SceneResult>, EngineError>,
    ) -> ReconcileControl {
        self.reconcile_plan(ReconcileOutcome::Exact(result))
    }
    pub(crate) fn hold_next_partial_reconcile(
        &self,
        live_after: Vec<DisplaySnapshotEntry>,
        error: EngineError,
    ) -> ReconcileControl {
        self.reconcile_plan(ReconcileOutcome::Partial { live_after, error })
    }
    pub(crate) fn hold_next_reconcile_with_result_shape(
        &self,
        complete_results: Vec<SceneResult>,
        shape: ReconcileResultShape,
    ) -> ReconcileControl {
        let display_id = match shape {
            ReconcileResultShape::MissingDisplay(id) | ReconcileResultShape::DuplicateDisplay(id) => id,
        };
        assert_eq!(complete_results.iter().filter(|r| r.display_id == display_id).count(), 1,
            "result-shape selection must name exactly one complete result");
        self.reconcile_plan(ReconcileOutcome::Shaped { complete_results, shape })
    }
    fn reconcile_plan(&self, outcome: ReconcileOutcome) -> ReconcileControl {
        let (entered_tx, entered) = oneshot::channel();
        let (release, release_rx) = oneshot::channel();
        let mut data = self.inner.data.lock().unwrap();
        assert!(data.reconcile.is_none(), "unconsumed reconcile plan");
        data.reconcile = Some(ReconcilePlan {
            entered: entered_tx,
            release: release_rx,
            outcome,
        });
        ReconcileControl { entered, release }
    }
    pub(crate) fn fail_next_prune_after_pruning(&self, error: String) {
        let mut data = self.inner.data.lock().unwrap();
        assert!(data.prune_error.is_none(), "unconsumed post-prune fault");
        data.prune_error = Some(error);
    }
    pub(crate) fn fail_selected_setter(
        &self,
        setter: SelectedSetter,
        handle: SceneHandle,
        occurrence: u32,
        timing: FaultTiming,
        error: EngineError,
    ) {
        assert!(occurrence > 0, "selected setter occurrence starts at one");
        let mut data = self.inner.data.lock().unwrap();
        assert!(!data.selected_setter_faults.iter().any(|fault|
            fault.setter == setter && fault.handle == handle && fault.remaining == occurrence),
            "ambiguous duplicate selected setter fault");
        data.selected_setter_faults.push(SelectedSetterFault {
            setter, handle, remaining: occurrence, timing, error,
        });
    }
    pub(crate) fn fail_next_property_preview(&self, error: EngineError) {
        let mut data = self.inner.data.lock().unwrap();
        assert!(data.property_preview_error.is_none(), "unconsumed property preview fault");
        data.property_preview_error = Some(error);
    }
    pub(crate) fn hold_next_render_scale_completion(
        &self,
        handle: SceneHandle,
    ) -> OperationControl {
        let (entered_tx, entered) = oneshot::channel();
        let (release, release_rx) = oneshot::channel();
        let mut data = self.inner.data.lock().unwrap();
        assert!(!data.render_scale_completions.iter().any(|plan| plan.handle == handle),
            "unconsumed render-scale completion plan for the same handle");
        data.render_scale_completions.push(RenderScaleCompletionPlan {
            handle,
            entered: entered_tx,
            release: release_rx,
        });
        OperationControl { entered, release }
    }
    pub(crate) fn fail_next_render_scale(&self, error: EngineError) {
        assert!(
            self.inner
                .data
                .lock()
                .unwrap()
                .scale_error
                .replace(error)
                .is_none(),
            "unconsumed scale fault"
        );
    }
    pub(crate) fn fail_next_fps(&self, error: EngineError) {
        assert!(
            self.inner
                .data
                .lock()
                .unwrap()
                .fps_error
                .replace(error)
                .is_none(),
            "unconsumed fps fault"
        );
    }
    pub(crate) fn require_audio(&self, handle: SceneHandle, required: bool) {
        let mut data = self.inner.data.lock().unwrap();
        known(&data, handle);
        data.controls.required.insert(handle, required);
    }
    pub(crate) fn observations(&self) -> Vec<EngineObservation> {
        self.inner.data.lock().unwrap().observations.clone()
    }
    pub(crate) fn hold_next_pause(&self, result: Result<(), EngineError>) -> OperationControl {
        self.plan(result, |d| &mut d.pause)
    }
    pub(crate) fn hold_next_demand(&self, result: Result<(), EngineError>) -> OperationControl {
        self.plan(result, |d| &mut d.demand_plan)
    }
    pub(crate) fn hold_next_close(&self, result: Result<(), EngineError>) -> OperationControl {
        self.plan(result, |d| &mut d.close)
    }
    fn plan(
        &self,
        result: Result<(), EngineError>,
        select: impl FnOnce(&mut Data) -> &mut Option<OperationPlan>,
    ) -> OperationControl {
        let (tx, entered) = oneshot::channel();
        let (release, rx) = oneshot::channel();
        let mut data = self.inner.data.lock().unwrap();
        let slot = select(&mut data);
        assert!(slot.is_none(), "unconsumed operation plan");
        *slot = Some(OperationPlan {
            entered: tx,
            release: rx,
            result,
        });
        OperationControl { entered, release }
    }
    fn mutation<E, M>(&self, event: E, mutate: M) -> EngineFuture<()>
    where
        E: Fn(OperationPhase) -> EngineObservation + Send + 'static,
        M: FnOnce(&mut Data) -> Result<(), EngineError> + Send + 'static,
    {
        let inner = self.inner.clone();
        Box::pin(async move {
            let mut data = inner.data.lock().unwrap();
            data.observations.push(event(OperationPhase::Started));
            let result = mutate(&mut data);
            data.observations.push(event(if result.is_ok() {
                OperationPhase::Applied
            } else {
                OperationPhase::Rejected
            }));
            result
        })
    }
    fn setting<E, M>(&self, event: E, mutate: M) -> Result<(), EngineError>
    where
        E: Fn(OperationPhase) -> EngineObservation,
        M: FnOnce(&mut Data),
    {
        let mut data = self.inner.data.lock().unwrap();
        data.observations.push(event(OperationPhase::Started));
        mutate(&mut data);
        data.observations.push(event(OperationPhase::Applied));
        Ok(())
    }
}
fn validate_rows(rows: &[DisplaySnapshotEntry]) {
    let mut ids = BTreeSet::new();
    for row in rows {
        assert_eq!(
            row.identity, row.desc.identity,
            "incoherent display identity"
        );
        assert!(ids.insert(row.desc.display_id), "duplicate display id");
    }
}
fn validate_partial_rows(rows: &[DisplaySnapshotEntry]) {
    validate_rows(rows);
    let mut handles = HashSet::new();
    for row in rows {
        if let Some(handle) = row.handle {
            assert!(handles.insert(handle), "duplicate partial live handle");
            assert!(row.assignment.is_some(), "partial live handle has no assignment");
        }
    }
}
fn direct_template(data: &Data, handle: SceneHandle) -> Option<&SceneTemplate> {
    data.rows.iter().find_map(|row| {
        if row.handle != Some(handle) {
            return None;
        }
        match row.assignment.as_ref() {
            Some(wallpaper_core::WallpaperAssignment::Direct(template)) => Some(template),
            _ => None,
        }
    })
}
fn shown_properties_from_rows(
    rows: &[DisplaySnapshotEntry],
) -> HashMap<SceneHandle, ShownPropertyState> {
    rows.iter().filter_map(|row| {
        let handle = row.handle?;
        match row.assignment.as_ref()? {
            wallpaper_core::WallpaperAssignment::Direct(template) => Some((handle, ShownPropertyState {
                scene_path: template.scene_path.clone(),
                flat_json: template.property_override_json.clone(),
            })),
            _ => None,
        }
    }).collect()
}
fn selected_setter_mutation(
    data: &mut Data,
    setter: SelectedSetter,
    handle: SceneHandle,
    mutate: impl FnOnce(&mut Data) -> Result<(), EngineError>,
) -> Result<(), EngineError> {
    known(data, handle);
    for fault in &mut data.selected_setter_faults {
        if fault.setter == setter && fault.handle == handle {
            fault.remaining -= 1;
        }
    }
    let fault = data.selected_setter_faults.iter().position(|fault|
        fault.setter == setter && fault.handle == handle && fault.remaining == 0)
        .map(|index| data.selected_setter_faults.remove(index));
    match fault {
        Some(fault) if fault.timing == FaultTiming::BeforeMutation => Err(fault.error),
        Some(fault) => {
            mutate(data)?;
            Err(fault.error)
        }
        None => mutate(data),
    }
}
async fn run_reconcile_core(
    engine: &ControlledEngine,
    scenes: Vec<SceneDesc>,
) -> Result<Vec<SceneResult>, EngineError> {
    let plan = engine.inner.data.lock().unwrap().reconcile.take();
    let (mut results, shape) = match plan {
        Some(plan) => {
            plan.entered.send(scenes.clone()).expect("reconcile observer disappeared");
            plan.release.await.expect("reconcile release disconnected");
            match plan.outcome {
                ReconcileOutcome::Exact(result) => (result?, None),
                ReconcileOutcome::Partial { live_after, error } => {
                    validate_partial_rows(&live_after);
                    let mut data = engine.inner.data.lock().unwrap();
                    data.rows = live_after;
                    data.controls.shown_properties = shown_properties_from_rows(&data.rows);
                    let displays = data.rows.iter().map(|row| (row.desc.display_id, row.handle)).collect();
                    data.observations.push(EngineObservation::PartialReconcilePublished { displays });
                    return Err(error);
                }
                ReconcileOutcome::Shaped { complete_results, shape } => (complete_results, Some(shape)),
            }
        }
        None => {
            assert!(scenes.is_empty(), "nonempty reconcile requires explicit exact results");
            (vec![], None)
        }
    };
    let wanted: BTreeSet<_> = scenes.iter().map(|s| s.display.display_id).collect();
    let actual: BTreeSet<_> = results.iter().map(|r| r.display_id).collect();
    assert_eq!(wanted.len(), scenes.len(), "duplicate requested displays");
    assert_eq!(actual.len(), results.len(), "duplicate result displays");
    assert_eq!(wanted, actual, "results do not match actual requested displays");
    let handles: HashSet<_> = results.iter().map(|r| r.handle).collect();
    assert_eq!(handles.len(), results.len(), "duplicate result handles");
    assert!(results.iter().all(|r| r.status == 0), "controlled success requires explicit zero statuses");
    {
        let mut data = engine.inner.data.lock().unwrap();
        for row in &mut data.rows {
            if let Some(scene) = scenes.iter().find(|s| s.display.display_id == row.desc.display_id) {
                let result = results.iter().find(|r| r.display_id == row.desc.display_id).unwrap();
                row.identity = scene.display.identity.clone();
                row.desc = scene.display.clone();
                row.handle = Some(result.handle);
                row.paused = scene.paused;
                row.assignment = Some(wallpaper_core::WallpaperAssignment::Direct(
                    SceneTemplate::from_scene_desc(scene),
                ));
                row.window_active = true;
            } else {
                row.handle = None;
                row.assignment = None;
                row.accepts_pointer_input = false;
                row.window_active = false;
            }
        }
        assert!(scenes.iter().all(|s| data.rows.iter()
            .any(|r| r.desc.display_id == s.display.display_id)), "requested unknown display");
        data.controls.shown_properties = shown_properties_from_rows(&data.rows);
    }
    if let Some(shape) = shape {
        let display_id = match shape {
            ReconcileResultShape::MissingDisplay(id) | ReconcileResultShape::DuplicateDisplay(id) => id,
        };
        let index = results.iter().position(|r| r.display_id == display_id)
            .expect("result-shape selection is absent from complete results");
        match shape {
            ReconcileResultShape::MissingDisplay(_) => { results.remove(index); }
            ReconcileResultShape::DuplicateDisplay(_) => {
                let selected = &results[index];
                let duplicate = SceneResult::new(selected.display_id, selected.handle, selected.status);
                results.push(duplicate);
            }
        }
    }
    Ok(results)
}
fn known(data: &Data, handle: SceneHandle) {
    assert!(
        data.rows.iter().any(|row| row.handle == Some(handle)),
        "unexpected scene operation: {handle:?}"
    );
}
fn template_mut(data: &mut Data, handle: SceneHandle, mutate: impl FnOnce(&mut SceneTemplate)) {
    known(data, handle);
    let template = data
        .rows
        .iter_mut()
        .find_map(|row| {
            if row.handle != Some(handle) {
                return None;
            }
            match row.assignment.as_mut() {
                Some(wallpaper_core::WallpaperAssignment::Direct(template)) => Some(template),
                _ => None,
            }
        })
        .expect("controlled scene has no direct template owner");
    mutate(template);
}
fn prune_controls(data: &mut Data) {
    let live: HashSet<_> = data.rows.iter().filter_map(|r| r.handle).collect();
    data.controls.required.retain(|h, _| live.contains(h));
    data.controls.capture.retain(|h, _| live.contains(h));
    data.controls.media.retain(|h, _| live.contains(h));
    data.controls.scale.retain(|h, _| live.contains(h));
    data.controls.scaling_mode.retain(|h, _| live.contains(h));
    data.controls.scaling_factor.retain(|h, _| live.contains(h));
    data.controls.framing.retain(|h, _| live.contains(h));
    data.controls.preview.retain(|h, _| live.contains(h));
    data.controls.shown_properties.retain(|h, _| live.contains(h));
}
fn apply_pause(data: &mut Data) {
    for row in &mut data.rows {
        row.paused = data.global_pause || data.display_pause.contains(&row.desc.display_id);
        if let Some(wallpaper_core::WallpaperAssignment::Direct(template)) = row.assignment.as_mut()
        {
            template.paused = row.paused;
        }
    }
}
async fn release_plan(plan: Option<OperationPlan>) -> Result<(), EngineError> {
    if let Some(plan) = plan {
        plan.entered
            .send(())
            .expect("operation observer disappeared");
        plan.release.await.expect("operation release disconnected");
        plan.result
    } else {
        Ok(())
    }
}
fn take_render_scale_completion(
    data: &mut Data,
    handle: SceneHandle,
) -> Option<RenderScaleCompletionPlan> {
    data.render_scale_completions.iter().position(|plan| plan.handle == handle)
        .map(|index| data.render_scale_completions.remove(index))
}
async fn finish_render_scale_completion(
    plan: Option<RenderScaleCompletionPlan>,
    result: Result<(), EngineError>,
) -> Result<(), EngineError> {
    if let Some(plan) = plan {
        plan.entered.send(()).expect("render-scale completion observer disappeared");
        plan.release.await.expect("render-scale completion release disconnected");
    }
    result
}
fn unsupported<T>(name: &'static str) -> EngineFuture<T> {
    Box::pin(async move { panic!("operation outside declared mounted scenario: {name}") })
}

impl EngineFacade for ControlledEngine {
    fn reconcile_scenes(&self, scenes: Vec<SceneDesc>) -> EngineFuture<Vec<SceneResult>> {
        let engine = self.clone();
        Box::pin(async move {
            engine
                .inner
                .data
                .lock()
                .unwrap()
                .observations
                .push(EngineObservation::Reconcile {
                    scenes: scenes.clone(),
                    phase: OperationPhase::Started,
                });
            let core_engine = engine.clone();
            let snapshot_engine = engine.clone();
            let prune_engine = engine.clone();
            let requested = scenes.clone();
            let witness = engine.inner.data.lock().unwrap().reconcile_witness.take();
            let core_witness = witness.clone();
            let prune_witness = witness.clone();
            let mut common = Box::pin(mounted_readiness::reconcile_with_readiness(
                &engine.inner.turn,
                &engine.inner.audio,
                &engine.inner.readiness,
                scenes,
                move || (snapshot_engine.display_rows(), Vec::new()),
                move |scenes| async move {
                    core_engine.inner.data.lock().unwrap().observations.push(
                        EngineObservation::ReconcileCore { phase: OperationPhase::Started });
                    let result = run_reconcile_core(&core_engine, scenes).await;
                    core_engine.inner.data.lock().unwrap().observations.push(
                        EngineObservation::ReconcileCore { phase: if result.is_ok() {
                            OperationPhase::Applied
                        } else {
                            OperationPhase::Rejected
                        } });
                    if let Some(witness) = core_witness {
                        witness.core_completed.store(true, Ordering::SeqCst);
                        let _ = witness.events.send(ReconcileBoundary::CoreCompleted);
                    }
                    result
                },
                move || async move {
                    let result = {
                        let mut data = prune_engine.inner.data.lock().unwrap();
                        data.observations.push(EngineObservation::ReconcilePrune {
                            phase: OperationPhase::Started,
                        });
                        prune_controls(&mut data);
                        let result = match data.prune_error.take() {
                            Some(error) => Err(error),
                            None => Ok(()),
                        };
                        data.observations.push(EngineObservation::ReconcilePrune {
                            phase: if result.is_ok() { OperationPhase::Applied } else { OperationPhase::Rejected },
                        });
                        result
                    };
                    if let Some(witness) = prune_witness {
                        witness.prune_completed.store(true, Ordering::SeqCst);
                        let _ = witness.events.send(ReconcileBoundary::PruneCompleted);
                    }
                    result
                },
            ));
            let mut waiting_reported = false;
            let result = poll_fn(|cx| match common.as_mut().poll(cx) {
                Poll::Pending => {
                    if let Some(witness) = &witness {
                        if !waiting_reported
                            && witness.core_completed.load(Ordering::SeqCst)
                            && witness.prune_completed.load(Ordering::SeqCst)
                        {
                            waiting_reported = true;
                            let _ = witness.events.send(ReconcileBoundary::WaitingPending);
                        }
                    }
                    Poll::Pending
                }
                Poll::Ready(result) => Poll::Ready(result),
            })
            .await;
            engine
                .inner
                .data
                .lock()
                .unwrap()
                .observations
                .push(EngineObservation::Reconcile {
                    scenes: requested,
                    phase: if result.is_ok() {
                        OperationPhase::Applied
                    } else {
                        OperationPhase::Rejected
                    },
                });
            result
        })
    }
    fn refresh_displays(&self) -> EngineFuture<()> {
        self.mutation(
            |phase| EngineObservation::Refresh { phase },
            |data| {
                validate_rows(&data.rows);
                Ok(())
            },
        )
    }
    fn display_snapshot(&self) -> Vec<DisplaySnapshotEntry> {
        self.display_rows()
    }
    fn close_all_scenes(&self) -> EngineFuture<()> {
        let engine = self.clone();
        Box::pin(async move {
            engine
                .inner
                .data
                .lock()
                .unwrap()
                .observations
                .push(EngineObservation::Close {
                    phase: OperationPhase::Started,
                });
            let core = engine.clone();
            let prune = engine.clone();
            let result = mounted_readiness::mutate_scenes_and_prune(
                &engine.inner.audio,
                move || async move {
                    let plan = core.inner.data.lock().unwrap().close.take();
                    release_plan(plan).await?;
                    let mut data = core.inner.data.lock().unwrap();
                    for row in &mut data.rows {
                        row.handle = None;
                        row.assignment = None;
                        row.accepts_pointer_input = false;
                        row.window_active = false;
                    }
                    Ok(())
                },
                move || async move {
                    prune_controls(&mut prune.inner.data.lock().unwrap());
                    Ok(())
                },
            )
            .await;
            engine
                .inner
                .data
                .lock()
                .unwrap()
                .observations
                .push(EngineObservation::Close {
                    phase: if result.is_ok() {
                        OperationPhase::Applied
                    } else {
                        OperationPhase::Rejected
                    },
                });
            result
        })
    }
    fn set_all_paused(&self, paused: bool, suspended_displays: Vec<u32>) -> EngineFuture<()> {
        let engine = self.clone();
        Box::pin(async move {
            engine
                .inner
                .data
                .lock()
                .unwrap()
                .observations
                .push(EngineObservation::PauseAll {
                    paused,
                    suspended_displays: suspended_displays.clone(),
                    phase: OperationPhase::Started,
                });
            let plan = engine.inner.data.lock().unwrap().pause.take();
            let result = release_plan(plan).await;
            let mut data = engine.inner.data.lock().unwrap();
            if result.is_ok() {
                data.global_pause = paused;
                data.display_pause = suspended_displays.iter().copied().collect();
                apply_pause(&mut data);
            }
            data.observations.push(EngineObservation::PauseAll {
                paused,
                suspended_displays,
                phase: if result.is_ok() {
                    OperationPhase::Applied
                } else {
                    OperationPhase::Rejected
                },
            });
            result
        })
    }
    fn set_display_paused(&self, display_id: u32, paused: bool) -> EngineFuture<()> {
        self.mutation(
            move |phase| EngineObservation::PauseDisplay {
                display_id,
                paused,
                phase,
            },
            move |d| {
                assert!(
                    d.rows.iter().any(|r| r.desc.display_id == display_id),
                    "unknown display pause"
                );
                if paused {
                    d.display_pause.insert(display_id);
                } else {
                    d.display_pause.remove(&display_id);
                }
                apply_pause(d);
                Ok(())
            },
        )
    }
    fn set_audio_volume(
        &self,
        handle: SceneHandle,
        volume: wallpaper_core::media::audio::AudioVolume,
    ) -> EngineFuture<()> {
        self.mutation(
            move |phase| EngineObservation::Volume {
                handle,
                volume,
                phase,
            },
            move |d| selected_setter_mutation(d, SelectedSetter::Volume, handle, |d| {
                template_mut(d, handle, |t| t.audio_volume = volume);
                Ok(())
            }),
        )
    }
    fn set_audio_muted(&self, handle: SceneHandle, muted: bool) -> EngineFuture<()> {
        self.mutation(
            move |phase| EngineObservation::Muted {
                handle,
                muted,
                phase,
            },
            move |d| selected_setter_mutation(d, SelectedSetter::Muted, handle, |d| {
                template_mut(d, handle, |t| t.audio_muted = muted);
                Ok(())
            }),
        )
    }
    fn set_audio_response_enabled(&self, handle: SceneHandle, enabled: bool) -> EngineFuture<()> {
        self.mutation(
            move |phase| EngineObservation::AudioResponse {
                handle,
                enabled,
                phase,
            },
            move |d| selected_setter_mutation(d, SelectedSetter::AudioResponse, handle, |d| {
                template_mut(d, handle, |t| t.audio_response_enabled = enabled);
                Ok(())
            }),
        )
    }
    fn set_media_integration_enabled(
        &self,
        handle: SceneHandle,
        enabled: bool,
    ) -> EngineFuture<()> {
        self.mutation(
            move |phase| EngineObservation::MediaIntegration {
                handle,
                enabled,
                phase,
            },
            move |d| {
                known(d, handle);
                d.controls.media.insert(handle, enabled);
                Ok(())
            },
        )
    }
    fn set_audio_capture_enabled(&self, handle: SceneHandle, enabled: bool) -> EngineFuture<()> {
        let engine = self.clone();
        Box::pin(async move {
            {
                let mut data = engine.inner.data.lock().unwrap();
                data.observations.push(EngineObservation::Capture {
                    handle,
                    enabled,
                    phase: OperationPhase::Started,
                });
            }
            mounted_readiness::mutate_audio(&engine.inner.audio, || async {
                let mut data = engine.inner.data.lock().unwrap();
                let result = selected_setter_mutation(&mut data, SelectedSetter::AudioCapture, handle, |data| {
                    data.controls.capture.insert(handle, enabled);
                    Ok(())
                });
                data.observations.push(EngineObservation::Capture {
                    handle,
                    enabled,
                    phase: if result.is_ok() { OperationPhase::Applied } else { OperationPhase::Rejected },
                });
                Ok::<Result<(), EngineError>, String>(result)
            })
            .await
            .and_then(|result| result)
        })
    }
    fn set_audio_capture_demand(&self, demand: AudioCaptureDemand) -> EngineFuture<()> {
        let engine = self.clone();
        Box::pin(async move {
            engine
                .inner
                .data
                .lock()
                .unwrap()
                .observations
                .push(EngineObservation::Demand {
                    demand,
                    phase: OperationPhase::Started,
                });
            let plan = engine.inner.data.lock().unwrap().demand_plan.take();
            let result = release_plan(plan).await;
            if result.is_ok() {
                mounted_readiness::mutate_audio(&engine.inner.audio, || async {
                    engine.inner.data.lock().unwrap().demand = demand;
                    Ok(())
                })
                .await?;
            }
            engine
                .inner
                .data
                .lock()
                .unwrap()
                .observations
                .push(EngineObservation::Demand {
                    demand,
                    phase: if result.is_ok() {
                        OperationPhase::Applied
                    } else {
                        OperationPhase::Rejected
                    },
                });
            result
        })
    }
    fn set_fps(&self, handle: SceneHandle, fps: u32) -> EngineFuture<()> {
        self.mutation(
            move |phase| EngineObservation::Fps { handle, fps, phase },
            move |d| {
                known(d, handle);
                if let Some(error) = d.fps_error.take() {
                    return Err(error);
                }
                template_mut(d, handle, |t| t.fps = fps);
                Ok(())
            },
        )
    }
    fn set_render_scale(&self, handle: SceneHandle, scale: f32) -> EngineFuture<()> {
        let engine = self.clone();
        Box::pin(async move {
            let (plan, result) = {
                let mut data = engine.inner.data.lock().unwrap();
                data.observations.push(EngineObservation::RenderScale {
                    handle,
                    scale,
                    phase: OperationPhase::Started,
                });
                let plan = take_render_scale_completion(&mut data, handle);
                known(&data, handle);
                let result = match data.scale_error.take() {
                    Some(error) => Err(error),
                    None => {
                        data.controls.scale.insert(handle, scale);
                        Ok(())
                    }
                };
                data.observations.push(EngineObservation::RenderScale {
                    handle,
                    scale,
                    phase: if result.is_ok() { OperationPhase::Applied } else { OperationPhase::Rejected },
                });
                (plan, result)
            };
            finish_render_scale_completion(plan, result).await
        })
    }
    fn set_scaling_mode(
        &self,
        handle: SceneHandle,
        mode: wallpaper_core::project::ScalingMode,
    ) -> EngineFuture<()> {
        let event_mode = mode.clone();
        self.mutation(
            move |phase| EngineObservation::ScalingMode {
                handle,
                mode: event_mode.clone(),
                phase,
            },
            move |d| selected_setter_mutation(d, SelectedSetter::ScalingMode, handle, |d| {
                d.controls.scaling_mode.insert(handle, mode);
                template_mut(d, handle, |template| template.scaling_mode = mode);
                Ok(())
            }),
        )
    }
    fn set_scaling_factor(&self, handle: SceneHandle, factor: f64) -> EngineFuture<()> {
        self.mutation(
            move |phase| EngineObservation::ScalingFactor {
                handle,
                factor,
                phase,
            },
            move |d| selected_setter_mutation(d, SelectedSetter::ScalingFactor, handle, |d| {
                d.controls.scaling_factor.insert(handle, factor);
                template_mut(d, handle, |template| template.scaling_factor = factor);
                Ok(())
            }),
        )
    }
    fn set_framing(
        &self,
        handle: SceneHandle,
        framing: wallpaper_core::project::SceneFraming,
    ) -> EngineFuture<()> {
        let event = framing.clone();
        self.mutation(
            move |phase| EngineObservation::Framing {
                handle,
                framing: event.clone(),
                phase,
            },
            move |d| {
                known(d, handle);
                d.controls.framing.insert(handle, framing);
                Ok(())
            },
        )
    }
    fn preview_framing(
        &self,
        handle: SceneHandle,
        framing: wallpaper_core::project::SceneFraming,
    ) -> EngineFuture<()> {
        let event = framing.clone();
        self.mutation(
            move |phase| EngineObservation::PreviewFraming {
                handle,
                framing: event.clone(),
                phase,
            },
            move |d| {
                known(d, handle);
                d.controls.preview.insert(handle, framing);
                Ok(())
            },
        )
    }
    fn set_first_frame_callback(&self, callback: FirstFrameCallback) {
        mounted_readiness::register_first_frame_callback(
            &self.inner.readiness,
            callback,
            |wrapped| {
                let (synchronous, panic_after) = {
                    let mut data = self.inner.data.lock().unwrap();
                    data.registration_count += 1;
                    data.saved = Some(wrapped.clone());
                    (data.synchronous, data.panic_after)
                };
                self.inner.slot.install(wrapped);
                if let Some(handle) = synchronous {
                    self.emit_first_frame(handle);
                }
                assert!(
                    !panic_after,
                    "controlled registration panic after actual install/invocation"
                );
            },
        );
    }
    fn set_pointer_consumer_callback(
        &self,
        value: Option<wallpaper_core::PointerConsumerCallback>,
    ) {
        self.inner.data.lock().unwrap().pointer_consumer = value;
    }
    fn set_pointer_activity_callback(
        &self,
        value: Option<wallpaper_core::PointerActivityCallback>,
    ) {
        self.inner.data.lock().unwrap().pointer_activity = value;
    }
    fn set_user_shortcut_callback(
        &self,
        value: Option<wallpaper_core::UserShortcutObserverCallback>,
    ) {
        self.inner.data.lock().unwrap().shortcut = value;
    }
    fn set_audio_requirement_callback(
        &self,
        value: Option<wallpaper_core::AudioRequirementCallback>,
    ) {
        self.inner.data.lock().unwrap().audio_requirement = value;
    }
    fn scene_requires_audio(&self, handle: SceneHandle) -> bool {
        let data = self.inner.data.lock().unwrap();
        known(&data, handle);
        data.controls
            .required
            .get(&handle)
            .copied()
            .unwrap_or(false)
    }
    fn set_renderer_counters_enabled(&self, enabled: bool) -> Result<(), EngineError> {
        self.inner.data.lock().unwrap().counters_enabled = enabled;
        Ok(())
    }
    fn scene_runtime_reports(&self) -> Vec<wallpaper_core::SceneRuntimeReport> {
        vec![]
    } // No measured renderer in this control.
    fn set_scene_optimization_enabled(&self, enabled: bool) -> Result<(), EngineError> {
        self.setting(
            move |phase| EngineObservation::Optimization { enabled, phase },
            |d| d.optimization = Some(enabled),
        )
    }
    fn set_scene_on_demand_enabled(&self, enabled: bool) -> Result<(), EngineError> {
        self.setting(
            move |phase| EngineObservation::OnDemand { enabled, phase },
            |d| d.on_demand = Some(enabled),
        )
    }
    fn set_scene_video_plane_sampling_enabled(&self, enabled: bool) -> Result<(), EngineError> {
        self.setting(
            move |phase| EngineObservation::VideoSampling { enabled, phase },
            |d| d.video_sampling = Some(enabled),
        )
    }
    fn set_scene_resolution(
        &self,
        resolution: wallpaper_core::SceneResolution,
    ) -> Result<(), EngineError> {
        let event = resolution.clone();
        self.setting(
            move |phase| EngineObservation::Resolution {
                resolution: event.clone(),
                phase,
            },
            |d| d.resolution = Some(resolution),
        )
    }
    fn update_media(
        &self,
        _: SceneHandle,
        _: bool,
        _: wallpaper_core::media::MediaPollResult,
    ) -> EngineFuture<()> {
        unsupported("update_media")
    }
    fn submit_media_event_json(&self, _: SceneHandle, _: String) -> EngineFuture<()> {
        unsupported("submit_media_event_json")
    }
    fn apply_system_media_artwork(
        &self,
        _: SceneHandle,
        _: u32,
        _: u32,
        _: Vec<u8>,
    ) -> EngineFuture<()> {
        unsupported("apply_system_media_artwork")
    }
    fn preview_property_override(
        &self,
        handle: SceneHandle,
        scene_path: String,
        flat_json: String,
    ) -> EngineFuture<wallpaper_core::PropertyPreview> {
        let engine = self.clone();
        Box::pin(async move {
            let mut data = engine.inner.data.lock().unwrap();
            let event = |phase| EngineObservation::PropertyPreview {
                handle,
                scene_path: scene_path.clone(),
                flat_json: flat_json.clone(),
                phase,
            };
            if !data.rows.iter().any(|row| row.handle == Some(handle)) {
                data.observations.push(event(PropertyPreviewPhase::Rejected));
                return Err(EngineError::InvalidInput(format!(
                    "property preview target is not a live controlled scene: {handle:?}"
                )));
            }
            if !direct_template(&data, handle).is_some_and(|template| template.scene_path == scene_path) {
                data.observations.push(event(PropertyPreviewPhase::Declined));
                return Ok(wallpaper_core::PropertyPreview::OtherWallpaper);
            }
            if data.controls.shown_properties.get(&handle).is_some_and(|shown|
                shown.scene_path == scene_path && shown.flat_json.as_deref() == Some(flat_json.as_str()))
            {
                data.observations.push(event(PropertyPreviewPhase::Unchanged));
                return Ok(wallpaper_core::PropertyPreview::Shown);
            }
            data.observations.push(event(PropertyPreviewPhase::Attempted));
            if let Some(error) = data.property_preview_error.take() {
                data.controls.shown_properties.remove(&handle);
                data.observations.push(event(PropertyPreviewPhase::Rejected));
                return Err(error);
            }
            let applied = event(PropertyPreviewPhase::Applied);
            data.controls.shown_properties.insert(handle, ShownPropertyState {
                scene_path,
                flat_json: Some(flat_json),
            });
            data.observations.push(applied);
            Ok(wallpaper_core::PropertyPreview::Shown)
        })
    }
    fn poll_mouse_position(&self) -> EngineFuture<()> {
        unsupported("poll_mouse_position")
    }
    fn set_mouse_position(&self, _: SceneHandle, _: f64, _: f64) -> EngineFuture<()> {
        unsupported("set_mouse_position")
    }
    fn set_mouse_button(&self, _: SceneHandle, _: u32, _: bool) -> EngineFuture<()> {
        unsupported("set_mouse_button")
    }
    fn set_mouse_entered(&self, _: SceneHandle, _: bool) -> EngineFuture<()> {
        unsupported("set_mouse_entered")
    }
    fn create_window_for_display(
        &self,
        _: wallpaper_core::DisplaySelector,
    ) -> EngineFuture<Option<SceneHandle>> {
        unsupported("create_window_for_display")
    }
    fn set_wallpaper_for_display(
        &self,
        _: wallpaper_core::DisplaySelector,
        _: wallpaper_core::WallpaperAssignment,
    ) -> EngineFuture<Option<SceneHandle>> {
        unsupported("set_wallpaper_for_display")
    }
    fn probe_pointer(&self) -> wallpaper_core::PointerProbe {
        panic!("native pointer probe outside mounted scenario")
    }
    fn renderer_counters(
        &self,
    ) -> EngineFuture<(
        Vec<wallpaper_core::render::RendererSurfaceCounters>,
        Vec<u64>,
    )> {
        unsupported("renderer_counters")
    }
    fn recover_surface(
        &self,
        _: u32,
        _: wallpaper_core::RecoveryReason,
    ) -> EngineFuture<wallpaper_core::RecoveryOutcome> {
        unsupported("recover_surface")
    }
    fn current_audio_spectrum(
        &self,
    ) -> Result<Option<wallpaper_core::AudioSpectrum128>, EngineError> {
        panic!("audio spectrum outside mounted scenario")
    }
}

struct ObserveWeak;
impl<E: EngineFacade + Clone> Message<ObserveWeak> for BridgeActor<E> {
    type Reply = Result<WeakActorRef<BridgeActor<E>>, BridgeError>;
    async fn handle(
        &mut self,
        _: ObserveWeak,
        ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        Ok(ctx.actor_ref().downgrade())
    }
}
struct Fence;
impl<E: EngineFacade + Clone> Message<Fence> for BridgeActor<E> {
    type Reply = Result<(), BridgeError>;
    async fn handle(&mut self, _: Fence, _: &mut Context<Self, Self::Reply>) -> Self::Reply {
        Ok(())
    }
}
struct Stop;
impl<E: EngineFacade + Clone> Message<Stop> for BridgeActor<E> {
    type Reply = Result<(), BridgeError>;
    async fn handle(&mut self, _: Stop, ctx: &mut Context<Self, Self::Reply>) -> Self::Reply {
        ctx.stop();
        Ok(())
    }
}
struct Gate {
    entered: oneshot::Sender<()>,
    release: oneshot::Receiver<()>,
}
impl<E: EngineFacade + Clone> Message<Gate> for BridgeActor<E> {
    type Reply = Result<(), BridgeError>;
    async fn handle(&mut self, msg: Gate, _: &mut Context<Self, Self::Reply>) -> Self::Reply {
        msg.entered
            .send(())
            .map_err(|_| BridgeError::engine("gate entered observer disappeared"))?;
        msg.release
            .await
            .map_err(|_| BridgeError::engine("gate release disconnected"))?;
        Ok(())
    }
}
struct ReleaseOnDrop(Option<oneshot::Sender<()>>);
impl ReleaseOnDrop {
    fn release(&mut self) {
        if let Some(tx) = self.0.take() {
            let _ = tx.send(());
        }
    }
}
impl Drop for ReleaseOnDrop {
    fn drop(&mut self) {
        self.release();
    }
}
struct HeldGate {
    release: ReleaseOnDrop,
    task: tokio::task::JoinHandle<Result<(), BridgeError>>,
}
impl HeldGate {
    async fn enter<E: EngineFacade + Clone>(handle: &BridgeActorHandle<E>) -> Self {
        let (tx, entered) = oneshot::channel();
        let (release, rx) = oneshot::channel();
        let actor = handle.clone();
        let task = tokio::spawn(async move {
            actor
                .ask(Gate {
                    entered: tx,
                    release: rx,
                })
                .await
        });
        let held = Self {
            release: ReleaseOnDrop(Some(release)),
            task,
        };
        bounded(entered).await.expect("gate never entered");
        held
    }
    async fn finish(mut self) {
        self.release.release();
        bounded(&mut self.task)
            .await
            .expect("gate task panic")
            .expect("gate handler failure");
    }
}
#[track_caller]
fn bounded<F: Future>(future: F) -> impl Future<Output = F::Output> {
    let caller = std::panic::Location::caller();
    async move {
        tokio::time::timeout(LIMIT, future)
            .await
            .unwrap_or_else(|error| {
                panic!("mounted scenario at {caller} exceeded finite guard: {error}")
            })
    }
}
#[track_caller]
fn eventually(mut predicate: impl FnMut() -> bool) -> impl Future<Output = ()> {
    bounded(async move {
        while !predicate() {
            tokio::task::yield_now().await;
        }
    })
}
async fn capture_panic<F: Future>(future: F) -> Result<F::Output, Box<dyn std::any::Any + Send>> {
    let mut future = Box::pin(future);
    poll_fn(
        |cx| match catch_unwind(AssertUnwindSafe(|| future.as_mut().poll(cx))) {
            Ok(Poll::Pending) => Poll::Pending,
            Ok(Poll::Ready(value)) => Poll::Ready(Ok(value)),
            Err(error) => Poll::Ready(Err(error)),
        },
    )
    .await
}
async fn callback_thread(callback: FirstFrameCallback, handle: SceneHandle) {
    let (tx, rx) = oneshot::channel();
    let thread = std::thread::spawn(move || {
        let result = catch_unwind(AssertUnwindSafe(|| callback(handle)));
        let _ = tx.send(result);
    });
    let result = bounded(rx).await.expect("callback thread disconnected");
    thread
        .join()
        .expect("callback return handshake must precede finite join");
    if let Err(error) = result {
        resume_unwind(error);
    }
}

static TEMP_ID: AtomicU64 = AtomicU64::new(1);
struct OwnedRoot {
    root: std::path::PathBuf,
    paths: BridgePaths,
}
impl OwnedRoot {
    fn new() -> Self {
        let temp = std::env::temp_dir()
            .canonicalize()
            .expect("canonical user temporary root");
        let root = temp.join(format!(
            "independent-mounted-{}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos(),
            TEMP_ID.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir(&root).unwrap();
        let paths = BridgePaths::for_home(&root);
        let owned = Self { root, paths };
        for path in [
            owned.paths.app_support_root(),
            owned.paths.steam_workshop_root(),
            owned.paths.assets_root(),
            owned.paths.user_assets_root(),
            owned.paths.shader_cache_root(),
        ] {
            assert!(
                path.starts_with(&owned.root),
                "parent runner must isolate every dynamic path override beneath owned root: {path:?}"
            );
        }
        owned
    }
    fn store(&self) -> ConfigStore {
        ConfigStore::open(self.paths.app_support_root())
    }
}
impl Drop for OwnedRoot {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}
fn login() -> crate::login::LaunchAtLoginController {
    crate::api::lifecycle_test_support::inert_login_controller(
        crate::login::LaunchAtLoginStatus::Unavailable,
    )
}
fn actor(
    root: &OwnedRoot,
    engine: ControlledEngine,
    state: BridgeActorState,
) -> BridgeActorHandle<ControlledEngine> {
    BridgeActorHandle::spawn(
        state,
        engine,
        None,
        login(),
        root.paths.clone(),
        Arc::new(crate::api::MousePollingControl::new()),
        LoadJournal::open(None, "independent-mounted"),
    )
    .expect("actual actor spawn")
}
fn builder(
    root: &OwnedRoot,
    engine: ControlledEngine,
    config: AppConfig,
    power: PowerSource,
) -> WallpaperBridge {
    root.store().save_app_config(&config).unwrap();
    BridgeBuilder::new(engine)
        .with_state(BridgeActorState::from_app_config(config))
        .with_config_store(root.store())
        .with_paths(root.paths.clone())
        .with_launch_at_login(login())
        .with_mouse_polling_enabled(false)
        .with_power_watching_enabled(false)
        .with_startup_power_source(power)
        .build()
        .expect("actual bridge build")
}
async fn stop_actor<E: EngineFacade + Clone>(
    handle: &BridgeActorHandle<E>,
    weak: &WeakActorRef<BridgeActor<E>>,
) {
    let reference = weak
        .upgrade()
        .expect("explicit handle must retain actor reference");
    if reference.is_alive() {
        let _ = bounded(handle.ask(Stop)).await;
    }
    bounded(reference.wait_for_shutdown()).await;
}

/// Shared consuming cleanup producer. Preserves the real public shutdown error,
/// but still joins the helper, stops/drains the actor and observes owned runtime release.
pub(crate) async fn shutdown_and_drain(mut bridge: WallpaperBridge) -> Result<(), BridgeError> {
    let runtime = runtime_probe(crate::api::lifecycle_test_support::actor(&bridge));
    let weak = match tokio::time::timeout(
        LIMIT,
        crate::api::lifecycle_test_support::actor(&bridge).ask(ObserveWeak),
    )
    .await
    {
        Ok(result) => result,
        Err(_) => Err(BridgeError::engine(
            "mounted cleanup: actor weak observation timed out",
        )),
    };
    let mut result = match tokio::time::timeout(LIMIT, bridge.shutdown()).await {
        Ok(result) => result,
        Err(_) => Err(BridgeError::engine(
            "mounted cleanup: public shutdown timed out",
        )),
    };
    let helper_result = capture_panic(tokio::time::timeout(
        LIMIT,
        crate::api::lifecycle_test_support::stop_handoff(&mut bridge),
    ))
    .await;
    if matches!(&helper_result, Ok(Err(_))) && result.is_ok() {
        result = Err(BridgeError::engine(
            "mounted cleanup: real helper join timed out",
        ));
    }
    if let Ok(weak) = &weak {
        if let Some(reference) = weak.upgrade() {
            if reference.is_alive() {
                let stopped = tokio::time::timeout(
                    LIMIT,
                    crate::api::lifecycle_test_support::actor(&bridge).ask(Stop),
                )
                .await;
                if result.is_ok() {
                    result = match stopped {
                        Ok(reply) => reply,
                        Err(_) => Err(BridgeError::engine("mounted cleanup: actor stop timed out")),
                    };
                }
            }
            if tokio::time::timeout(LIMIT, reference.wait_for_shutdown())
                .await
                .is_err()
                && result.is_ok()
            {
                result = Err(BridgeError::engine(
                    "mounted cleanup: actor shutdown acknowledgment timed out",
                ));
            }
        }
    }
    drop(bridge);
    let released = tokio::time::timeout(LIMIT, async {
        loop {
            let actor_released = match &weak {
                Ok(weak) => weak.strong_count() == 0,
                Err(_) => true,
            };
            if actor_released && runtime.is_released() {
                break;
            }
            tokio::task::yield_now().await;
        }
    })
    .await;
    if released.is_err() && result.is_ok() {
        result = Err(BridgeError::engine(
            "mounted cleanup: actor/runtime owner release timed out",
        ));
    }
    if result.is_ok() {
        if let Err(error) = weak {
            result = Err(error);
        }
    }
    if let Err(panic) = helper_result {
        resume_unwind(panic);
    }
    result
}
#[derive(Debug)]
enum DeliveryEvent {
    Pending,
    Dropped,
    Completed,
}
struct FutureDrop(mpsc::UnboundedSender<DeliveryEvent>);
impl Drop for FutureDrop {
    fn drop(&mut self) {
        let _ = self.0.send(DeliveryEvent::Dropped);
    }
}
struct PollObserved<T> {
    target: T,
    events: mpsc::UnboundedSender<DeliveryEvent>,
    starts: Arc<AtomicUsize>,
}
impl<T: FirstFrameTarget> FirstFrameTarget for PollObserved<T> {
    async fn deliver(&self, handle: SceneHandle) -> FirstFrameDelivery {
        self.starts.fetch_add(1, Ordering::SeqCst);
        let mut inner = Box::pin(self.target.deliver(handle));
        let _drop = FutureDrop(self.events.clone());
        let mut pending_sent = false;
        let outcome = poll_fn(|cx| match inner.as_mut().poll(cx) {
            Poll::Pending => {
                if !pending_sent {
                    pending_sent = true;
                    let _ = self.events.send(DeliveryEvent::Pending);
                }
                Poll::Pending
            }
            Poll::Ready(value) => Poll::Ready(value),
        })
        .await;
        let _ = self.events.send(DeliveryEvent::Completed);
        outcome
    }
}
async fn pending_once<F: Future>(future: Pin<&mut F>) {
    let mut future = future;
    poll_fn(|cx| match future.as_mut().poll(cx) {
        Poll::Pending => Poll::Ready(()),
        Poll::Ready(_) => panic!("actual operation replied before gated handler/IO completion"),
    })
    .await
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn actual_adapter_idle_success_stopped_mailbox_and_unavailable_runtime() {
    let root = OwnedRoot::new();
    let engine = ControlledEngine::new(vec![]);
    let handle = actor(&root, engine, BridgeActorState::default());
    let weak = bounded(handle.ask(ObserveWeak)).await.unwrap();
    let runtime = runtime_probe(&handle);
    let mut gate = Some(HeldGate::enter(&handle).await);
    let outcome = capture_panic(async {
        let baseline = weak.strong_count();
        let (runtime_handle, target) = handle.first_frame_handoff_inputs().unwrap();
        assert_eq!(weak.strong_count(), baseline);
        let unpolled = target.deliver(SceneHandle::new(9401));
        assert_eq!(weak.strong_count(), baseline);
        drop(unpolled);
        gate.take().unwrap().finish().await;
        assert!(matches!(
            bounded(target.deliver(SceneHandle::new(9402))).await,
            FirstFrameDelivery::Delivered
        ));
        assert!(
            bounded(handle.ask(MountedStateObservation))
                .await
                .unwrap()
                .initial_frame_ready
        );
        stop_actor(&handle, &weak).await;
        assert!(
            weak.upgrade().is_some(),
            "stopped mailbox is not weak unavailability"
        );
        match bounded(target.deliver(SceneHandle::new(9403))).await {
            FirstFrameDelivery::Failed(error) => assert_eq!(error.kind(), BridgeErrorKind::Engine),
            other => panic!("real stopped-mailbox send must fail: {other:?}"),
        }
        drop(runtime_handle);
        target
    })
    .await;
    if let Some(held) = gate.take() {
        held.finish().await;
    }
    stop_actor(&handle, &weak).await;
    drop(handle);
    eventually(|| weak.strong_count() == 0 && runtime.is_released()).await;
    match outcome {
        Ok(target) => assert!(matches!(
            bounded(target.deliver(SceneHandle::new(9404))).await,
            FirstFrameDelivery::TargetGone
        )),
        Err(error) => resume_unwind(error),
    }
}

async fn cancellation_case(explicit_stop: bool) {
    let root = OwnedRoot::new();
    let handle = actor(
        &root,
        ControlledEngine::new(vec![]),
        BridgeActorState::default(),
    );
    let weak = bounded(handle.ask(ObserveWeak)).await.unwrap();
    let runtime = runtime_probe(&handle);
    let gate = HeldGate::enter(&handle).await;
    let (actor_runtime, target) = handle.first_frame_handoff_inputs().unwrap();
    let baseline = weak.strong_count();
    let starts = Arc::new(AtomicUsize::new(0));
    let (events, mut received) = mpsc::unbounded_channel();
    let mut handoff = Some(FirstFrameHandoff::start(
        &actor_runtime,
        PollObserved {
            target,
            events,
            starts: starts.clone(),
        },
    ));
    let callback = handoff.as_ref().unwrap().callback();
    let result = capture_panic(async {
        assert_eq!(
            weak.strong_count(),
            baseline,
            "idle helper must not acquire actor owner"
        );
        callback_thread(callback.clone(), SceneHandle::new(9511)).await;
        assert!(matches!(
            bounded(received.recv()).await,
            Some(DeliveryEvent::Pending)
        ));
        let pending_owners = weak.strong_count();
        assert!(
            pending_owners > baseline,
            "actual pending weak upgrade must retain temporary actor owner"
        );
        callback_thread(callback.clone(), SceneHandle::new(9512)).await;
        callback_thread(callback.clone(), SceneHandle::new(9513)).await;
        if explicit_stop {
            handoff.as_ref().unwrap().close();
            handoff.as_ref().unwrap().close();
            bounded(handoff.take().unwrap().stop()).await;
        } else {
            drop(handoff.take());
        }
        assert!(matches!(
            bounded(received.recv()).await,
            Some(DeliveryEvent::Dropped)
        ));
        // An admitted Kameo message owns a separate actor reference until drained.
        eventually(|| weak.strong_count() < pending_owners).await;
        assert!(weak.strong_count() >= baseline);
        // Gate is still owned and unreleased: helper termination did not require actor progress.
        assert!(!gate.task.is_finished());
        callback_thread(callback.clone(), SceneHandle::new(9514)).await;
        if explicit_stop {
            assert_eq!(starts.load(Ordering::SeqCst), 1);
            assert!(
                bounded(received.recv()).await.is_none(),
                "joined dispatcher must own no event sender"
            );
        } else {
            assert!(
                bounded(received.recv()).await.is_none(),
                "Drop requires observed eventual dispatcher destruction"
            );
            assert_eq!(starts.load(Ordering::SeqCst), 1);
        }
    })
    .await;
    if let Some(owner) = handoff.take() {
        owner.close();
        bounded(owner.stop()).await;
    }
    gate.finish().await;
    bounded(handle.ask(Fence)).await.unwrap();
    stop_actor(&handle, &weak).await;
    drop(handle);
    drop(actor_runtime);
    eventually(|| weak.strong_count() == 0 && runtime.is_released()).await;
    callback_thread(callback, SceneHandle::new(9515)).await;
    if let Err(error) = result {
        resume_unwind(error);
    }
}
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn helper_close_stop_cancels_actual_ask_without_actor_progress() {
    cancellation_case(true).await;
}
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn helper_drop_releases_actual_temporary_owner_without_actor_progress() {
    cancellation_case(false).await;
}

async fn deferred_policy_case(fail: bool, demand_gate: bool) {
    let root = OwnedRoot::new();
    let engine = ControlledEngine::new(vec![]);
    let mut config = AppConfig::default();
    config.power.on_battery = BatteryModeCfg::Pause;
    let mut state = BridgeActorState::from_app_config(config);
    state.apply_startup_power_source(PowerSource::Battery);
    let handle = actor(&root, engine.clone(), state);
    let weak = bounded(handle.ask(ObserveWeak)).await.unwrap();
    let (_runtime, target) = handle.first_frame_handoff_inputs().unwrap();
    let before = bounded(handle.ask(MountedStateObservation)).await.unwrap();
    let result = capture_panic(async {
        assert!(!before.initial_frame_ready);
        assert!(before.pending_battery_pause_after_initial_frame);
        let operation_result = if fail {
            Err(EngineError::Render("mounted-policy-owned-cause-721".into()))
        } else {
            Ok(())
        };
        let control = if demand_gate {
            engine.hold_next_demand(operation_result)
        } else {
            engine.hold_next_pause(operation_result)
        };
        let mut release = ReleaseOnDrop(Some(control.release));
        let mut delivery = Box::pin(target.deliver(SceneHandle::new(9621)));
        pending_once(delivery.as_mut()).await;
        bounded(control.entered).await.unwrap();
        pending_once(delivery.as_mut()).await;
        release.release();
        match bounded(delivery).await {
            FirstFrameDelivery::Delivered if !fail => {}
            FirstFrameDelivery::Failed(error) if fail => {
                assert_eq!(error.kind(), BridgeErrorKind::Engine);
                assert!(error.message().contains("mounted-policy-owned-cause-721"));
            }
            other => panic!("actual policy result mismatch: {other:?}"),
        }
        let after = bounded(handle.ask(MountedStateObservation)).await.unwrap();
        assert!(after.initial_frame_ready);
        assert!(!after.pending_battery_pause_after_initial_frame);
        let applied_before = engine
            .observations()
            .iter()
            .filter(|e| {
                matches!(
                    e,
                    EngineObservation::PauseAll {
                        phase: OperationPhase::Started,
                        ..
                    }
                )
            })
            .count();
        assert!(matches!(
            bounded(target.deliver(SceneHandle::new(9622))).await,
            FirstFrameDelivery::Delivered
        ));
        assert_eq!(
            engine
                .observations()
                .iter()
                .filter(|e| matches!(
                    e,
                    EngineObservation::PauseAll {
                        phase: OperationPhase::Started,
                        ..
                    }
                ))
                .count(),
            applied_before,
            "duplicate receipt must not recreate consumed deferral"
        );
    })
    .await;
    stop_actor(&handle, &weak).await;
    drop(handle);
    if let Err(error) = result {
        resume_unwind(error);
    }
}
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn actual_first_frame_waits_for_deferred_policy_and_consumes_once() {
    deferred_policy_case(false, false).await;
}
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn actual_handler_owned_error_survives_weak_adapter_mapping() {
    deferred_policy_case(true, false).await;
}
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn actual_first_frame_waits_for_capture_demand_policy_completion() {
    deferred_policy_case(false, true).await;
}
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn actual_demand_error_and_rollback_preserve_owned_cause() {
    deferred_policy_case(true, true).await;
}

fn display(display_id: u32) -> DisplaySnapshotEntry {
    let identity = wallpaper_core::DisplayIdentity {
        uuid: Some(format!("independent-mounted-display-{display_id}")),
        vendor_id: None,
        model_id: None,
        serial_number: None,
        unit_number: None,
        name: Some("Independent controlled display".into()),
    };
    DisplaySnapshotEntry {
        desc: wallpaper_core::DisplayDesc {
            display_id,
            identity: identity.clone(),
            x: 0,
            y: 0,
            width: 1024,
            height: 768,
            scale_factor: 1.0,
            refresh_rate_hz: 60,
        },
        identity,
        handle: None,
        accepts_pointer_input: false,
        paused: false,
        window_active: false,
        assignment: None,
    }
}
fn nonempty_config(root: &OwnedRoot, id: &str, display_id: u32) -> AppConfig {
    let project = root.paths.project_json(id);
    assert!(
        project.starts_with(&root.root),
        "project path escaped owned root"
    );
    std::fs::create_dir_all(project.parent().unwrap()).unwrap();
    std::fs::write(project, r#"{"type":"scene","title":"Independent mounted first-frame contract","general":{"properties":{"contract_slider":{"type":"slider","value":0.375,"min":0,"max":1},"contract_bool":{"type":"bool","value":true}}}}"#).unwrap();
    root.store()
        .save_wallpaper(&WallpaperConfig::new_for(id, "scene"))
        .unwrap();
    let mut config = AppConfig::default();
    let mut monitor = MonitorCfg::default();
    monitor.selector = SerializedSelector::LiveDisplayId { display_id };
    monitor.enabled = true;
    monitor.mode = "independent".into();
    monitor.wallpaper = Some(id.into());
    monitor.mirror_target = None;
    config.monitors = vec![monitor];
    root.store().save_app_config(&config).unwrap();
    config
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn nonempty_bootstrap_releases_real_readiness_before_queued_first_frame_handler() {
    let root = OwnedRoot::new();
    let engine = ControlledEngine::new(vec![display(731)]);
    let config = nonempty_config(&root, "independent-mounted-project-731", 731);
    let bridge = builder(&root, engine.clone(), config, PowerSource::External);
    let handle = crate::api::lifecycle_test_support::actor(&bridge);
    let mut boundaries = engine.observe_next_reconcile();
    let control =
        engine.hold_next_reconcile(Ok(vec![SceneResult::new(731, SceneHandle::new(10731), 0)]));
    let mut release = ReleaseOnDrop(Some(control.release));
    let result = capture_panic(async {
        assert!(!bounded(bridge.mounted_state_for_test()).await.unwrap().initial_frame_ready);
        let mut bootstrap = Box::pin(bridge.bootstrap()); pending_once(bootstrap.as_mut()).await;
        let scenes = bounded(control.entered).await.unwrap(); assert_eq!(scenes.len(), 1); assert_eq!(scenes[0].display.display_id, 731);
        let observed = engine.observations();
        let reconcile_start = observed.iter().position(|e| matches!(e, EngineObservation::Reconcile { phase: OperationPhase::Started, .. })).unwrap();
        for index in [observed.iter().position(|e| matches!(e, EngineObservation::Optimization { phase: OperationPhase::Applied, .. })), observed.iter().position(|e| matches!(e, EngineObservation::OnDemand { phase: OperationPhase::Applied, .. })), observed.iter().position(|e| matches!(e, EngineObservation::Resolution { phase: OperationPhase::Applied, .. })), observed.iter().position(|e| matches!(e, EngineObservation::VideoSampling { phase: OperationPhase::Applied, .. }))] {
            assert!(index.expect("real bootstrap must configure renderer before opening") < reconcile_start);
        }
        release.release();
        assert_eq!(bounded(boundaries.recv()).await, Some(ReconcileBoundary::CoreCompleted));
        assert_eq!(bounded(boundaries.recv()).await, Some(ReconcileBoundary::PruneCompleted));
        assert_eq!(bounded(boundaries.recv()).await, Some(ReconcileBoundary::WaitingPending));
        // This acknowledgment follows a real common-future Pending AFTER core/prune completion.
        pending_once(bootstrap.as_mut()).await;
        callback_thread(engine.inner.renderer.clone(), SceneHandle::new(10731)).await;
        let bundle = bounded(&mut bootstrap).await.unwrap();
        assert!(bundle.app.active_wallpaper_ids.iter().any(|id| id == "independent-mounted-project-731"));
        assert!(engine.observations().iter().any(|e| matches!(e, EngineObservation::Reconcile { scenes: applied, phase: OperationPhase::Applied } if applied == &scenes)));
        bounded(async { loop {
            if bounded(bridge.mounted_state_for_test()).await.unwrap().initial_frame_ready { break; }
            tokio::task::yield_now().await;
        } }).await;
        bounded(handle.ask(Fence)).await.unwrap();
        assert!(crate::api::lifecycle_test_support::journal(&bridge).strikes().is_empty());
        // Independent live mirror aliases exercise real Shutdown's distinct-handle sampling.
        let first = engine.display_rows().into_iter().find(|r| r.handle.is_some()).unwrap();
        let mut mirror = display(732); mirror.handle = first.handle; mirror.window_active = true;
        mirror.assignment = Some(wallpaper_core::WallpaperAssignment::Mirror(wallpaper_core::DisplaySelector::LiveDisplayId(731)));
        let mut second = display(733); second.handle = Some(SceneHandle::new(10733)); second.window_active = true;
        let wallpaper_core::WallpaperAssignment::Direct(template) = first.assignment.clone().unwrap() else { panic!("actual reconcile must publish direct assignment") };
        second.assignment = Some(wallpaper_core::WallpaperAssignment::Direct(SceneTemplate::from_scene_desc(&template.for_display(second.desc.clone()))));
        let volume = wallpaper_core::media::audio::AudioVolume::try_from(0.42f32).unwrap();
        let muted = !template.audio_muted; let response = !template.audio_response_enabled;
        let mut expected_first = first.clone();
        let Some(wallpaper_core::WallpaperAssignment::Direct(expected)) = expected_first.assignment.as_mut() else { unreachable!() };
        expected.audio_volume = volume; expected.audio_muted = muted; expected.audio_response_enabled = response; expected.fps = 47;
        expected.scaling_mode = wallpaper_core::project::ScalingMode::Fit;
        expected.scaling_factor = 1.625;
        let unchanged_mirror = mirror.clone(); let unchanged_second = second.clone();
        engine.replace_display_rows(vec![mirror, first, second]); // Valid mirror alias precedes its direct owner.
        bounded(engine.set_audio_volume(SceneHandle::new(10731), volume)).await.unwrap();
        bounded(engine.set_audio_muted(SceneHandle::new(10731), muted)).await.unwrap();
        bounded(engine.set_audio_response_enabled(SceneHandle::new(10731), response)).await.unwrap();
        bounded(engine.set_fps(SceneHandle::new(10731), 47)).await.unwrap();
        bounded(engine.set_scaling_mode(SceneHandle::new(10731), wallpaper_core::project::ScalingMode::Fit)).await.unwrap();
        bounded(engine.set_scaling_factor(SceneHandle::new(10731), 1.625)).await.unwrap();
        assert_eq!(engine.display_rows(), vec![unchanged_mirror, expected_first, unchanged_second], "affected setters mutate only the matching direct owner, never its preceding mirror or another scene");
        let capture_before = engine.inner.data.lock().unwrap().controls.capture.get(&SceneHandle::new(10731)).copied();
        let capture_enabled = !capture_before.unwrap_or(false);
        let exclusion = bounded(engine.inner.audio.lock()).await;
        let capture_start = engine.observations().len();
        let mut capture = Box::pin(engine.set_audio_capture_enabled(SceneHandle::new(10731), capture_enabled));
        pending_once(capture.as_mut()).await;
        assert_eq!(&engine.observations()[capture_start..], &[EngineObservation::Capture { handle: SceneHandle::new(10731), enabled: capture_enabled, phase: OperationPhase::Started }], "Started belongs to outer polling, before actual audio exclusion admission");
        assert_eq!(engine.inner.data.lock().unwrap().controls.capture.get(&SceneHandle::new(10731)).copied(), capture_before);
        drop(exclusion);
        bounded(capture).await.unwrap();
        assert_eq!(engine.inner.data.lock().unwrap().controls.capture.get(&SceneHandle::new(10731)).copied(), Some(capture_enabled));
        assert_eq!(&engine.observations()[capture_start..], &[
            EngineObservation::Capture { handle: SceneHandle::new(10731), enabled: capture_enabled, phase: OperationPhase::Started },
            EngineObservation::Capture { handle: SceneHandle::new(10731), enabled: capture_enabled, phase: OperationPhase::Applied },
        ]);
        let close = engine.hold_next_close(Err(EngineError::Platform("mounted-close-owned-cause-733".into())));
        let mut close_release = ReleaseOnDrop(Some(close.release));
        let start = engine.observations().len();
        let mut shutdown = Box::pin(bridge.shutdown()); pending_once(shutdown.as_mut()).await;
        bounded(close.entered).await.unwrap(); pending_once(shutdown.as_mut()).await;
        let during = engine.observations();
        for scene in [SceneHandle::new(10731), SceneHandle::new(10733)] {
            assert_eq!(during[start..].iter().filter(|e| matches!(e, EngineObservation::Capture { handle, enabled: false, phase: OperationPhase::Applied } if *handle == scene)).count(), 1, "capture disabled once per distinct live handle, not once per display alias");
        }
        assert!(during[start..].iter().any(|e| matches!(e, EngineObservation::Demand { demand: AudioCaptureDemand { suspended: true, .. }, phase: OperationPhase::Applied })));
        assert_eq!(engine.display_rows().iter().filter(|r| r.handle.is_some()).count(), 3, "gated close has not removed rows");
        close_release.release();
        let error = bounded(shutdown).await.expect_err("real Shutdown must surface actual close error");
        assert_eq!(error.kind(), BridgeErrorKind::Engine); assert!(error.message().contains("mounted-close-owned-cause-733"));
        assert_eq!(engine.display_rows().iter().filter(|r| r.handle.is_some()).count(), 3, "rejected close preserves live rows");
        assert!(engine.observations().iter().any(|e| matches!(e, EngineObservation::Close { phase: OperationPhase::Rejected })));
        bounded(bridge.shutdown()).await.unwrap();
        assert!(engine.display_rows().iter().all(|r| r.handle.is_none() && r.assignment.is_none() && !r.accepts_pointer_input));
    }).await;
    release.release();
    shutdown_and_drain(bridge).await.unwrap();
    if let Err(error) = result {
        resume_unwind(error);
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn actual_builder_synchronous_registration_replacement_and_runtime_weak_ownership() {
    let sync_root = OwnedRoot::new();
    let a_root = OwnedRoot::new();
    let b_root = OwnedRoot::new();
    let engine = ControlledEngine::new(vec![]);
    engine.emit_first_frame(SceneHandle::new(10800)); // Held renderer dispatch before installation; no replay.
    engine.registration_behavior(Some(SceneHandle::new(10801)), false);
    let synchronous = builder(
        &sync_root,
        engine.clone(),
        AppConfig::default(),
        PowerSource::External,
    );
    let synchronous_result = capture_panic(async {
        assert_eq!(engine.registration_count(), 1);
        bounded(async {
            loop {
                if bounded(synchronous.mounted_state_for_test())
                    .await
                    .unwrap()
                    .initial_frame_ready
                {
                    break;
                }
                tokio::task::yield_now().await;
            }
        })
        .await;
    })
    .await;
    let synchronous_cleanup = capture_panic(shutdown_and_drain(synchronous)).await;
    if let Err(error) = synchronous_result {
        resume_unwind(error);
    }
    match synchronous_cleanup {
        Ok(result) => result.unwrap(),
        Err(error) => resume_unwind(error),
    }
    // A has never received a frame: its occupied baseline cannot contain a retiring constructor ask.
    engine.registration_behavior(None, false);
    let mut a = builder(
        &a_root,
        engine.clone(),
        AppConfig::default(),
        PowerSource::External,
    );
    let a_handle = crate::api::lifecycle_test_support::actor(&a);
    let a_weak = bounded(a_handle.ask(ObserveWeak)).await.unwrap();
    let a_runtime = runtime_probe(a_handle);
    let saved_a = engine.saved_first_frame().unwrap();
    let mut b = None;
    let mut a_gate = None;
    let result = capture_panic(async {
        assert_eq!(engine.registration_count(), 2);
        assert!(
            !bounded(a.mounted_state_for_test())
                .await
                .unwrap()
                .initial_frame_ready
        );
        b = Some(builder(
            &b_root,
            engine.clone(),
            AppConfig::default(),
            PowerSource::External,
        ));
        let b_ref = b.as_ref().unwrap();
        assert_eq!(engine.registration_count(), 3);
        assert!(
            !bounded(b_ref.mounted_state_for_test())
                .await
                .unwrap()
                .initial_frame_ready,
            "registration must not replay A receipts"
        );
        a_gate = Some(HeldGate::enter(crate::api::lifecycle_test_support::actor(&a)).await);
        let occupied_baseline = a_weak.strong_count();
        callback_thread(saved_a.clone(), SceneHandle::new(10802)).await;
        // The callback is the sole producer; occupied actor prevents its actual ask from completing.
        eventually(|| a_weak.strong_count() > occupied_baseline).await;
        assert!(!a_gate.as_ref().unwrap().task.is_finished());
        crate::api::lifecycle_test_support::handoff(&a).close();
        bounded(crate::api::lifecycle_test_support::stop_handoff(&mut a)).await;
        // At most the single admitted message can outlive its joined helper.
        eventually(|| a_weak.strong_count() <= occupied_baseline + 1).await;
        let queued_owners = a_weak.strong_count();
        assert!(queued_owners >= occupied_baseline);
        assert!(
            !a_gate.as_ref().unwrap().task.is_finished(),
            "actual helper join must not require opening A's actor gate"
        );
        callback_thread(saved_a.clone(), SceneHandle::new(10805)).await;
        assert_eq!(
            a_weak.strong_count(),
            queued_owners,
            "joined helper has closed intake even while A remains occupied"
        );
    })
    .await;
    let a_gate_cleanup = capture_panic(async {
        if let Some(gate) = a_gate.take() {
            gate.finish().await;
        }
        bounded(crate::api::lifecycle_test_support::actor(&a).ask(Fence))
            .await
            .unwrap();
    })
    .await;
    let a_cleanup = capture_panic(shutdown_and_drain(a)).await;
    let a_release = capture_panic(async {
        eventually(|| a_weak.strong_count() == 0 && a_runtime.is_released()).await;
        callback_thread(saved_a, SceneHandle::new(10806)).await;
    })
    .await;
    let b_cleanup = if let Some(bridge) = b {
        let observation = capture_panic(async {
            assert!(
                !bounded(bridge.mounted_state_for_test())
                    .await
                    .unwrap()
                    .initial_frame_ready
            );
            // A's joined helper/actor teardown has not cleared the genuine core slot's B sink.
            engine.emit_first_frame(SceneHandle::new(10807));
            bounded(async {
                loop {
                    if bounded(bridge.mounted_state_for_test())
                        .await
                        .unwrap()
                        .initial_frame_ready
                    {
                        break;
                    }
                    tokio::task::yield_now().await;
                }
            })
            .await;
            bounded(crate::api::lifecycle_test_support::actor(&bridge).ask(Fence))
                .await
                .unwrap();
        })
        .await;
        let drained = capture_panic(shutdown_and_drain(bridge)).await;
        Some((observation, drained))
    } else {
        None
    };
    if let Err(error) = result {
        resume_unwind(error);
    }
    if let Err(error) = a_gate_cleanup {
        resume_unwind(error);
    }
    match a_cleanup {
        Ok(result) => result.unwrap(),
        Err(error) => resume_unwind(error),
    }
    if let Err(error) = a_release {
        resume_unwind(error);
    }
    if let Some((observation, drained)) = b_cleanup {
        if let Err(error) = observation {
            resume_unwind(error);
        }
        match drained {
            Ok(result) => result.unwrap(),
            Err(error) => resume_unwind(error),
        }
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn actual_core_cell_acquired_a_survives_replacement_without_replay() {
    let engine = ControlledEngine::new(vec![]);
    let retained_renderer = engine.inner.renderer.clone();
    let (a_tx, mut a_rx) = mpsc::unbounded_channel();
    let (b_tx, mut b_rx) = mpsc::unbounded_channel();
    retained_renderer(SceneHandle::new(10900));
    let (entered_tx, entered_rx) = oneshot::channel();
    let entered_tx = Arc::new(Mutex::new(Some(entered_tx)));
    let (release_tx, release_rx) = std::sync::mpsc::channel();
    let release_rx = Mutex::new(release_rx);
    engine.set_first_frame_callback(Arc::new(move |h| {
        a_tx.send(h).unwrap();
        if let Some(tx) = entered_tx.lock().unwrap().take() {
            tx.send(()).unwrap();
            release_rx
                .lock()
                .unwrap()
                .recv_timeout(LIMIT)
                .expect("bounded acquired-A release");
        }
    }));
    assert!(
        a_rx.try_recv().is_err(),
        "installation does not replay pre-registration frame"
    );
    let (returned, done) = oneshot::channel();
    let renderer_a = retained_renderer.clone();
    let thread = std::thread::spawn(move || {
        renderer_a(SceneHandle::new(10901));
        let _ = returned.send(());
    });
    let result = capture_panic(async {
        bounded(entered_rx).await.unwrap(); // The REAL cell has acquired A and entered its sink.
        engine.set_first_frame_callback(Arc::new(move |h| {
            b_tx.send(h).unwrap();
        }));
        assert!(b_rx.try_recv().is_err(), "replacement does not replay A");
        retained_renderer(SceneHandle::new(10902));
        assert_eq!(bounded(a_rx.recv()).await, Some(SceneHandle::new(10901)));
        assert_eq!(bounded(b_rx.recv()).await, Some(SceneHandle::new(10902)));
    })
    .await;
    let _ = release_tx.send(());
    bounded(done).await.unwrap();
    thread.join().unwrap();
    if let Err(error) = result {
        resume_unwind(error);
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn public_shutdown_cleans_real_journal_before_actor_and_keeps_helper_open() {
    let root = OwnedRoot::new();
    let positive = OwnedRoot::new();
    let engine = ControlledEngine::new(vec![]);
    let bridge = builder(
        &root,
        engine.clone(),
        AppConfig::default(),
        PowerSource::External,
    );
    let h = crate::api::lifecycle_test_support::actor(&bridge);
    let gate = HeldGate::enter(h).await;
    let build = crate::engine::build_stamp();
    let positive_root = positive.paths.app_support_root();
    let positive_journal = LoadJournal::open(Some(&positive_root), &build);
    let positive_ticket = positive_journal.begin(vec![("positive-open-ticket-841".into(), 841)]);
    let actual_journal = crate::api::lifecycle_test_support::journal(&bridge);
    let ticket = actual_journal.begin(vec![("actual-shutdown-ticket-842".into(), 842)]);
    let actual_root = root.paths.app_support_root();
    let mut shutdown = Box::pin(bridge.shutdown());
    let result = capture_panic(async {
        pending_once(shutdown.as_mut()).await;
        let positive_reopen = LoadJournal::open(Some(&positive_root), &build);
        assert!(
            positive_reopen
                .strikes()
                .contains_key("positive-open-ticket-841"),
            "genuine reopen must detect still-live unfinished positive-control ticket"
        );
        let actual_reopen = LoadJournal::open(Some(&actual_root), &build);
        assert!(
            !actual_reopen
                .strikes()
                .contains_key("actual-shutdown-ticket-842"),
            "public shutdown must clean journal while actual Shutdown cannot handle"
        );
        assert!(!gate.task.is_finished());
        assert!(!engine.observations().iter().any(|e| matches!(
            e,
            EngineObservation::Close {
                phase: OperationPhase::Started
            }
        )));
    })
    .await;
    let late = capture_panic(async {
        gate.finish().await;
        let finished = bounded(&mut shutdown).await;
        finished.unwrap();
        let observations = engine.observations();
        let demand = observations
            .iter()
            .position(|e| {
                matches!(
                    e,
                    EngineObservation::Demand {
                        demand: AudioCaptureDemand {
                            suspended: true,
                            ..
                        },
                        phase: OperationPhase::Applied
                    }
                )
            })
            .expect("shutdown suspends capture demand");
        let close = observations
            .iter()
            .position(|e| {
                matches!(
                    e,
                    EngineObservation::Close {
                        phase: OperationPhase::Applied
                    }
                )
            })
            .expect("actual close completion");
        assert!(demand < close);
        assert!(
            !bounded(bridge.mounted_state_for_test())
                .await
                .unwrap()
                .initial_frame_ready
        );
        engine.emit_first_frame(SceneHandle::new(11842));
        bounded(async {
            loop {
                if bounded(bridge.mounted_state_for_test())
                    .await
                    .unwrap()
                    .initial_frame_ready
                {
                    break;
                }
                tokio::task::yield_now().await;
            }
        })
        .await;
        // Actual handler state after scene shutdown proves the retained helper was not latched closed.
        crate::api::lifecycle_test_support::handoff(&bridge).close();
    })
    .await;
    drop(shutdown);
    drop(ticket);
    drop(positive_ticket);
    actual_journal.clean_shutdown();
    positive_journal.clean_shutdown();
    let cleanup = capture_panic(shutdown_and_drain(bridge)).await;
    if let Err(error) = result {
        resume_unwind(error);
    }
    if let Err(error) = late {
        resume_unwind(error);
    }
    match cleanup {
        Ok(result) => result.unwrap(),
        Err(error) => resume_unwind(error),
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn dropping_only_bridge_releases_actor_runtime_with_engine_and_callbacks_retained() {
    let root = OwnedRoot::new();
    let engine = ControlledEngine::new(vec![]);
    let bridge = builder(
        &root,
        engine.clone(),
        AppConfig::default(),
        PowerSource::External,
    );
    let handle = crate::api::lifecycle_test_support::actor(&bridge);
    let weak = bounded(handle.ask(ObserveWeak)).await.unwrap();
    let runtime = runtime_probe(handle);
    let saved = engine.saved_first_frame().unwrap();
    bounded(handle.ask(Fence)).await.unwrap();
    drop(bridge); // No explicit stop: actual bridge/helper/handle Drop is the behavior under test.
    eventually(|| weak.strong_count() == 0 && runtime.is_released()).await;
    callback_thread(saved, SceneHandle::new(12851)).await;
    engine.emit_first_frame(SceneHandle::new(12852));
    assert_eq!(
        engine.registration_count(),
        1,
        "Drop must neither unregister nor install a replacement"
    );
    assert!(engine.saved_first_frame().is_some());
}


#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn genuine_crash_held_input_is_excluded_and_first_frame_does_not_forgive_it() {
    let root = OwnedRoot::new();
    let id = "independent-mounted-held-project-931";
    let mut config = nonempty_config(&root, id, 931);
    config.power.on_battery = BatteryModeCfg::Pause;
    let journal_root = root.paths.app_support_root();
    let build = crate::engine::build_stamp();
    let mut journal = LoadJournal::open(Some(&journal_root), &build);
    let mut tickets = Vec::new();
    // Induce genuine reopen transitions; no private journal schema/hold threshold is copied.
    for _ in 0..64 {
        if journal.held().contains(id) {
            break;
        }
        tickets.push(journal.begin(vec![(id.to_owned(), 931)]));
        journal = LoadJournal::open(Some(&journal_root), &build);
    }
    assert!(
        journal.held().contains(id),
        "bounded genuine crash induction must reach actual hold"
    );
    let engine = ControlledEngine::new(vec![display(931)]);
    let bridge = builder(&root, engine.clone(), config, PowerSource::Battery);
    let handle = crate::api::lifecycle_test_support::actor(&bridge);
    let result = capture_panic(async {
        let bundle = bounded(bridge.bootstrap()).await.unwrap();
        assert!(bundle.app.held_wallpaper_ids.iter().any(|held| held == id));
        assert!(
            !bundle
                .app
                .active_wallpaper_ids
                .iter()
                .any(|active| active == id)
        );
        assert!(engine.display_rows().iter().all(|row| row.handle.is_none()));
        assert!(
            !engine.observations().iter().any(
                |e| matches!(e, EngineObservation::Reconcile { scenes, .. } if !scenes.is_empty())
            ),
            "held exclusion must precede nonempty controlled opening"
        );
        let before = crate::api::lifecycle_test_support::journal(&bridge).held();
        let (_runtime, target) = handle.first_frame_handoff_inputs().unwrap();
        assert!(matches!(
            bounded(target.deliver(SceneHandle::new(13931))).await,
            FirstFrameDelivery::Delivered
        ));
        let after_frame = bounded(bridge.mounted_state_for_test()).await.unwrap();
        assert!(after_frame.initial_frame_ready);
        assert!(!after_frame.pending_battery_pause_after_initial_frame);
        assert_eq!(
            crate::api::lifecycle_test_support::journal(&bridge).held(),
            before
        );
        assert!(
            bounded(bridge.app_snapshot())
                .await
                .unwrap()
                .held_wallpaper_ids
                .iter()
                .any(|held| held == id)
        );
    })
    .await;
    shutdown_and_drain(bridge).await.unwrap();
    // Tickets remain alive throughout all causal observations, never leaked or prematurely succeeded.
    drop(tickets);
    journal.clean_shutdown();
    if let Err(error) = result {
        resume_unwind(error);
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn actual_scene_free_startup_source_mode_matrix_preserves_deferral_boundary() {
    for source in [
        PowerSource::External,
        PowerSource::Battery,
        PowerSource::Unknown,
    ] {
        for mode in [
            BatteryModeCfg::KeepRunning,
            BatteryModeCfg::ReducedQuality,
            BatteryModeCfg::Pause,
        ] {
            let root = OwnedRoot::new();
            let engine = ControlledEngine::new(vec![]);
            let defer = source == PowerSource::Battery && matches!(mode, BatteryModeCfg::Pause);
            let mut config = AppConfig::default();
            config.power.on_battery = mode;
            let mut state = BridgeActorState::from_app_config(config);
            state.apply_startup_power_source(source);
            let handle = actor(&root, engine.clone(), state);
            let weak = bounded(handle.ask(ObserveWeak)).await.unwrap();
            let result = capture_panic(async {
                let before = bounded(handle.ask(MountedStateObservation)).await.unwrap();
                assert_eq!(before.pending_battery_pause_after_initial_frame, defer);
                assert!(!before.initial_frame_ready);
                if defer {
                    assert!(!engine.observations().iter().any(|e| matches!(
                        e,
                        EngineObservation::PauseAll {
                            paused: true,
                            phase: OperationPhase::Applied,
                            ..
                        }
                    )));
                }
                let (_runtime, target) = handle.first_frame_handoff_inputs().unwrap();
                assert!(matches!(
                    bounded(target.deliver(SceneHandle::new(14951))).await,
                    FirstFrameDelivery::Delivered
                ));
                let after = bounded(handle.ask(MountedStateObservation)).await.unwrap();
                assert!(after.initial_frame_ready);
                assert!(!after.pending_battery_pause_after_initial_frame);
                bounded(handle.ask(crate::actor::messages::SetPowerSource {
                    source,
                    initial_sample: true,
                }))
                .await
                .unwrap();
                bounded(handle.ask(crate::actor::messages::SetPowerSource {
                    source,
                    initial_sample: false,
                }))
                .await
                .unwrap();
                assert!(
                    !bounded(handle.ask(MountedStateObservation))
                        .await
                        .unwrap()
                        .pending_battery_pause_after_initial_frame,
                    "later power samples do not recreate consumed startup deferral"
                );
            })
            .await;
            stop_actor(&handle, &weak).await;
            drop(handle);
            if let Err(error) = result {
                resume_unwind(error);
            }
        }
    }
}
