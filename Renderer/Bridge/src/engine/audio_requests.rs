use std::sync::mpsc;
use std::thread;

use tokio::sync::oneshot;
use wallpaper_core::media::audio::{AudioCaptureBackend, AudioCaptureController};
use wallpaper_core::project::SceneHandle;

use crate::engine::AudioCaptureDemand;

/// Transport only. The facade's separate last-owner guard posts `finish`.
#[derive(Clone)]
pub(super) struct CaptureMailbox {
    sender: mpsc::Sender<Envelope>,
}

/// Event producers never acquire ownership of the facade or the controller.
#[derive(Clone)]
pub(super) struct CaptureEvents {
    sender: mpsc::Sender<Envelope>,
}

pub(super) trait CaptureAssembly: Send + 'static {
    type Backend: AudioCaptureBackend + 'static;

    fn make_controller(&mut self) -> Result<AudioCaptureController<Self::Backend>, String>;
    fn retain_live(
        &mut self,
        controller: &mut AudioCaptureController<Self::Backend>,
    ) -> Result<Vec<SceneHandle>, String>;
    fn apply_demand(
        &mut self,
        controller: &mut AudioCaptureController<Self::Backend>,
        demand: AudioCaptureDemand,
    ) -> Result<(), String>;
    fn output_changed(
        &mut self,
        controller: &mut AudioCaptureController<Self::Backend>,
        events: &CaptureEvents,
    );
    fn retry_restart(
        &mut self,
        controller: &mut AudioCaptureController<Self::Backend>,
        generation: u64,
        attempt: usize,
        events: &CaptureEvents,
    );
    fn sync_watch(&mut self, wanted: bool, events: &CaptureEvents);
    fn stop_watch(&mut self);
}

enum Operation {
    Scene { handle: SceneHandle, enabled: bool },
    Demand(AudioCaptureDemand),
    Prune,
}

enum Envelope {
    Request {
        operation: Operation,
        reply: oneshot::Sender<Result<(), String>>,
    },
    OutputChanged,
    Retry {
        generation: u64,
        attempt: usize,
    },
    Finish,
}

pub(super) fn start_capture_lane<A: CaptureAssembly>(assembly: A) -> CaptureMailbox {
    let (sender, receiver) = mpsc::channel();
    let events = CaptureEvents {
        sender: sender.clone(),
    };
    let _ = thread::Builder::new()
        .name("wallpaper-bridge-audio-capture".to_owned())
        .spawn(move || run_lane(assembly, receiver, events))
        .expect("audio capture worker thread should start");
    CaptureMailbox { sender }
}

impl CaptureMailbox {
    pub(super) fn events(&self) -> CaptureEvents {
        CaptureEvents {
            sender: self.sender.clone(),
        }
    }

    pub(super) async fn enable_scene(
        &self,
        handle: SceneHandle,
        enabled: bool,
    ) -> Result<(), String> {
        self.request(Operation::Scene { handle, enabled }).await
    }

    pub(super) async fn update_demand(&self, demand: AudioCaptureDemand) -> Result<(), String> {
        self.request(Operation::Demand(demand)).await
    }

    pub(super) async fn prune_scenes(&self) -> Result<(), String> {
        self.request(Operation::Prune).await
    }

    async fn request(&self, operation: Operation) -> Result<(), String> {
        let (reply, response) = oneshot::channel();
        self.sender
            .send(Envelope::Request { operation, reply })
            .map_err(|error| format!("audio capture worker stopped: {error}"))?;
        response
            .await
            .map_err(|error| format!("audio capture worker did not reply: {error}"))?
    }
}

impl CaptureEvents {
    pub(super) fn output_changed(&self) {
        let _ = self.sender.send(Envelope::OutputChanged);
    }

    pub(super) fn retry_restart(&self, generation: u64, attempt: usize) {
        let _ = self.sender.send(Envelope::Retry {
            generation,
            attempt,
        });
    }

    pub(super) fn finish(&self) {
        let _ = self.sender.send(Envelope::Finish);
    }
}

fn run_lane<A: CaptureAssembly>(
    mut assembly: A,
    receiver: mpsc::Receiver<Envelope>,
    events: CaptureEvents,
) {
    // The backend is made here, not captured by the thread closure. It need not be Send.
    let mut initialized = assembly.make_controller();
    while let Ok(envelope) = receiver.recv() {
        match envelope {
            Envelope::Finish => break,
            Envelope::OutputChanged => {
                if let Ok(controller) = initialized.as_mut() {
                    assembly.output_changed(controller, &events);
                }
            }
            Envelope::Retry {
                generation,
                attempt,
            } => {
                if let Ok(controller) = initialized.as_mut() {
                    assembly.retry_restart(controller, generation, attempt, &events);
                }
            }
            Envelope::Request { operation, reply } => {
                let result = match initialized.as_mut() {
                    Err(error) => Err(error.clone()),
                    Ok(controller) => {
                        let result = match assembly.retain_live(controller) {
                            Err(error) => Err(error),
                            Ok(live) => match operation {
                                Operation::Scene { handle, enabled } => {
                                    apply_scene(controller, &live, handle, enabled)
                                }
                                Operation::Demand(demand) => {
                                    assembly.apply_demand(controller, demand)
                                }
                                Operation::Prune => Ok(()),
                            },
                        };
                        assembly.sync_watch(controller.wants_capture(), &events);
                        result
                    }
                };
                // Admission, not the continued existence of the waiter, commits this work.
                let _ = reply.send(result);
            }
        }
    }
    if initialized.is_ok() {
        assembly.stop_watch();
    }
    // Watcher disposal must precede the real controller's final cleanup attempt.
    drop(initialized);
}

fn apply_scene<B: AudioCaptureBackend>(
    controller: &mut AudioCaptureController<B>,
    live: &[SceneHandle],
    handle: SceneHandle,
    enabled: bool,
) -> Result<(), String> {
    if enabled {
        if !live.contains(&handle) {
            return Err("The wallpaper is no longer active.".to_owned());
        }
        let permitted = controller
            .has_permission()
            .map_err(|error| error.to_string())?;
        if !permitted
            && !controller
                .request_permission()
                .map_err(|error| error.to_string())?
        {
            return Err("System audio capture permission was not granted.".to_owned());
        }
    }
    controller
        .set_scene_capturing(handle, enabled)
        .map_err(|error| {
            let action = if enabled { "start" } else { "stop" };
            format!(
                "Audio response could not {action}: {error}. Check WallpaperMachine in System Settings > Privacy & Security > Screen & System Audio Recording."
            )
        })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::VecDeque;
    use std::future::Future;
    use std::pin::Pin;
    use std::rc::Rc;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::{Arc, Condvar, Mutex};
    use std::task::{Context, Poll, Wake, Waker};
    use std::thread::ThreadId;
    use std::time::{Duration, Instant};

    use wallpaper_core::media::audio::{
        AudioCaptureError, AudioFrameConsumer, InterleavedStereoF32, MonoPcmF32,
    };

    const LIMIT: Duration = Duration::from_secs(10);
    const FIRST: u64 = 6101;
    const SECOND: u64 = 6207;

    fn handle(raw: u64) -> SceneHandle {
        SceneHandle::new(raw)
    }

    #[derive(Clone, Debug, PartialEq, Eq)]
    struct Snapshot {
        owners: usize,
        wanted: bool,
        healthy: bool,
        running: bool,
        cleanup: bool,
        session: Option<u64>,
    }

    #[derive(Clone, Debug, PartialEq, Eq)]
    enum Mark {
        Begin(&'static str),
        End(&'static str),
        Status,
        PermissionRequest,
        RunningQuery,
        CleanupQuery,
        Start {
            session: u64,
            consumer: usize,
        },
        StartFailed(String),
        OverlapRejected,
        Stop(Option<u64>),
        StopFailed(String),
        Demand(AudioCaptureDemand),
        Device,
        Retry(u64, usize),
        Watch {
            wanted: bool,
            unavailable: bool,
        },
        WatchStopped,
        Snapshot(Snapshot),
        BackendDropped {
            running: bool,
            cleanup: bool,
            session: Option<u64>,
        },
        AssemblyDropped,
    }

    #[derive(Clone, Debug)]
    struct Entry {
        mark: Mark,
        thread: ThreadId,
    }

    struct GateState {
        entered: bool,
        released: bool,
    }

    struct Gate {
        state: Mutex<GateState>,
        changed: Condvar,
    }

    impl Gate {
        fn block(&self) {
            let deadline = Instant::now() + LIMIT;
            let mut state = self.state.lock().unwrap();
            state.entered = true;
            self.changed.notify_all();
            while !state.released {
                let remaining = deadline.saturating_duration_since(Instant::now());
                assert!(!remaining.is_zero(), "test gate was never released");
                let (next, _) = self.changed.wait_timeout(state, remaining).unwrap();
                state = next;
            }
        }

        fn release(&self) {
            self.state.lock().unwrap().released = true;
            self.changed.notify_all();
        }
    }

    // A failing assertion cannot leave the worker permanently blocked on its test gate.
    struct HeldGate(Arc<Gate>);

    impl HeldGate {
        fn new() -> Self {
            Self(Arc::new(Gate {
                state: Mutex::new(GateState {
                    entered: false,
                    released: false,
                }),
                changed: Condvar::new(),
            }))
        }

        fn wait_entered(&self) {
            let deadline = Instant::now() + LIMIT;
            let mut state = self.0.state.lock().unwrap();
            while !state.entered {
                let remaining = deadline.saturating_duration_since(Instant::now());
                assert!(!remaining.is_zero(), "worker did not enter test gate");
                let (next, _) = self.0.changed.wait_timeout(state, remaining).unwrap();
                state = next;
            }
        }

        fn release(&self) {
            self.0.release();
        }
    }

    impl Drop for HeldGate {
        fn drop(&mut self) {
            self.0.release();
        }
    }

    #[derive(Clone)]
    enum PermissionReply {
        Hint { accepted: bool, later_status: bool },
        Error(String),
    }

    #[derive(Clone)]
    struct StopFault {
        text: String,
        still_running: bool,
    }

    struct BackendState {
        permission: bool,
        status_error: Option<String>,
        permission_replies: VecDeque<PermissionReply>,
        start_errors: VecDeque<String>,
        stop_results: VecDeque<Option<StopFault>>,
        persistent_stop_fault: Option<StopFault>,
        running: bool,
        cleanup: bool,
        retained_session: Option<u64>,
        next_session: u64,
        largest_retained: usize,
    }

    impl BackendState {
        fn new() -> Self {
            Self {
                permission: true,
                status_error: None,
                permission_replies: VecDeque::new(),
                start_errors: VecDeque::new(),
                stop_results: VecDeque::new(),
                persistent_stop_fault: None,
                running: false,
                cleanup: false,
                retained_session: None,
                next_session: 1,
                largest_retained: 0,
            }
        }
    }

    #[derive(Default)]
    struct Controls {
        initializer: Option<Arc<Gate>>,
        before_retain: Option<Arc<Gate>>,
        after_retain: Option<Arc<Gate>>,
        demand: Option<Arc<Gate>>,
        watch: Option<Arc<Gate>>,
        initializer_error: Option<String>,
        demand_errors: VecDeque<String>,
        watch_unavailable: bool,
    }

    struct Shared {
        live: Mutex<Vec<SceneHandle>>,
        backend: Mutex<BackendState>,
        controls: Mutex<Controls>,
        entries: Mutex<Vec<Entry>>,
        changed: Condvar,
        active: AtomicUsize,
        maximum_active: AtomicUsize,
    }

    impl Shared {
        fn new(live: &[u64]) -> Arc<Self> {
            Arc::new(Self {
                live: Mutex::new(live.iter().copied().map(handle).collect()),
                backend: Mutex::new(BackendState::new()),
                controls: Mutex::new(Controls::default()),
                entries: Mutex::new(Vec::new()),
                changed: Condvar::new(),
                active: AtomicUsize::new(0),
                maximum_active: AtomicUsize::new(0),
            })
        }

        fn record(&self, mark: Mark) {
            self.entries.lock().unwrap().push(Entry {
                mark,
                thread: thread::current().id(),
            });
            self.changed.notify_all();
        }

        fn enter(&self, name: &'static str) -> OperationGuard<'_> {
            let active = self.active.fetch_add(1, Ordering::SeqCst) + 1;
            self.maximum_active.fetch_max(active, Ordering::SeqCst);
            self.record(Mark::Begin(name));
            OperationGuard { shared: self, name }
        }

        fn marks(&self) -> Vec<Mark> {
            self.entries
                .lock()
                .unwrap()
                .iter()
                .map(|entry| entry.mark.clone())
                .collect()
        }

        fn count(&self, predicate: impl Fn(&Mark) -> bool) -> usize {
            self.entries
                .lock()
                .unwrap()
                .iter()
                .filter(|entry| predicate(&entry.mark))
                .count()
        }

        fn wait_count(&self, predicate: impl Fn(&Mark) -> bool, minimum: usize) {
            let deadline = Instant::now() + LIMIT;
            let mut entries = self.entries.lock().unwrap();
            while entries
                .iter()
                .filter(|entry| predicate(&entry.mark))
                .count()
                < minimum
            {
                let remaining = deadline.saturating_duration_since(Instant::now());
                assert!(!remaining.is_zero(), "missing observation: {entries:?}");
                let (next, _) = self.changed.wait_timeout(entries, remaining).unwrap();
                entries = next;
            }
        }

        fn capture(&self, controller: &AudioCaptureController<TestBackend>) -> Snapshot {
            let owners = controller.active_scene_count();
            let wanted = controller.wants_capture();
            let healthy = controller.is_capturing();
            let backend = self.backend.lock().unwrap();
            let snapshot = Snapshot {
                owners,
                wanted,
                healthy,
                running: backend.running,
                cleanup: backend.cleanup,
                session: backend.retained_session,
            };
            drop(backend);
            self.record(Mark::Snapshot(snapshot.clone()));
            snapshot
        }

        fn latest_snapshot(&self) -> Snapshot {
            self.entries
                .lock()
                .unwrap()
                .iter()
                .rev()
                .find_map(|entry| {
                    if let Mark::Snapshot(snapshot) = &entry.mark {
                        Some(snapshot.clone())
                    } else {
                        None
                    }
                })
                .expect("controller was not observed")
        }

        fn set_live(&self, live: &[u64]) {
            *self.live.lock().unwrap() = live.iter().copied().map(handle).collect();
        }

        fn permission_requests(&self) -> usize {
            self.count(|mark| matches!(mark, Mark::PermissionRequest))
        }

        fn starts(&self) -> Vec<(u64, usize)> {
            self.marks()
                .into_iter()
                .filter_map(|mark| {
                    if let Mark::Start { session, consumer } = mark {
                        Some((session, consumer))
                    } else {
                        None
                    }
                })
                .collect()
        }

        fn assert_serial_worker(&self) {
            let entries = self.entries.lock().unwrap();
            let worker = entries
                .first()
                .expect("no initialization observation")
                .thread;
            assert_ne!(worker, thread::current().id());
            assert!(
                entries.iter().all(|entry| entry.thread == worker),
                "cross-thread controller work: {entries:?}"
            );
            assert_eq!(self.maximum_active.load(Ordering::SeqCst), 1);
            assert_eq!(self.active.load(Ordering::SeqCst), 0);
            assert_eq!(
                entries
                    .iter()
                    .filter(|entry| entry.mark == Mark::Begin("initialize"))
                    .count(),
                1
            );
            assert!(
                !entries
                    .iter()
                    .any(|entry| entry.mark == Mark::OverlapRejected)
            );
            assert!(self.backend.lock().unwrap().largest_retained <= 1);
        }
    }

    struct OperationGuard<'a> {
        shared: &'a Shared,
        name: &'static str,
    }

    impl Drop for OperationGuard<'_> {
        fn drop(&mut self) {
            self.shared.record(Mark::End(self.name));
            self.shared.active.fetch_sub(1, Ordering::SeqCst);
        }
    }

    struct RejectFrames;

    impl AudioFrameConsumer for RejectFrames {
        fn submit_audio_frames(
            &self,
            _: InterleavedStereoF32<'_>,
        ) -> Result<(), AudioCaptureError> {
            panic!("device-free request tests must not deliver stereo PCM");
        }

        fn submit_mono_audio_frames(&self, _: MonoPcmF32<'_>) -> Result<(), AudioCaptureError> {
            panic!("device-free request tests must not deliver mono PCM");
        }
    }

    struct TestBackend {
        shared: Arc<Shared>,
        // Compile-time coverage: a backend remains local even though the assembly is Send.
        _not_send: Rc<()>,
    }

    impl AudioCaptureBackend for TestBackend {
        fn has_permission(&self) -> Result<bool, AudioCaptureError> {
            self.shared.record(Mark::Status);
            let state = self.shared.backend.lock().unwrap();
            match &state.status_error {
                Some(text) => Err(AudioCaptureError::PermissionDenied(text.clone())),
                None => Ok(state.permission),
            }
        }

        fn request_permission(&mut self) -> Result<bool, AudioCaptureError> {
            self.shared.record(Mark::PermissionRequest);
            let mut state = self.shared.backend.lock().unwrap();
            match state.permission_replies.pop_front() {
                Some(PermissionReply::Hint {
                    accepted,
                    later_status,
                }) => {
                    state.permission = later_status;
                    Ok(accepted)
                }
                Some(PermissionReply::Error(text)) => Err(AudioCaptureError::Platform(text)),
                None => Err(AudioCaptureError::Engine(
                    "unexpected permission request in device-free test".to_owned(),
                )),
            }
        }

        fn start(
            &mut self,
            consumer: Arc<dyn AudioFrameConsumer>,
        ) -> Result<(), AudioCaptureError> {
            let needs_cleanup = {
                let state = self.shared.backend.lock().unwrap();
                if state.running && !state.cleanup && state.retained_session.is_some() {
                    return Ok(());
                }
                state.retained_session.is_some() || state.cleanup
            };
            if needs_cleanup {
                self.stop()?;
            }
            let mut state = self.shared.backend.lock().unwrap();
            if state.retained_session.is_some() || state.cleanup || state.running {
                self.shared.record(Mark::OverlapRejected);
                return Err(AudioCaptureError::Engine(
                    "replacement before retained cleanup".to_owned(),
                ));
            }
            if let Some(text) = state.start_errors.pop_front() {
                self.shared.record(Mark::StartFailed(text.clone()));
                return Err(AudioCaptureError::PermissionDenied(text));
            }
            let session = state.next_session;
            state.next_session += 1;
            state.retained_session = Some(session);
            state.running = true;
            state.cleanup = false;
            state.largest_retained = state.largest_retained.max(1);
            self.shared.record(Mark::Start {
                session,
                consumer: Arc::as_ptr(&consumer) as *const () as usize,
            });
            Ok(())
        }

        fn stop(&mut self) -> Result<(), AudioCaptureError> {
            let mut state = self.shared.backend.lock().unwrap();
            self.shared.record(Mark::Stop(state.retained_session));
            let fault = match state.stop_results.pop_front() {
                Some(result) => result,
                None => state.persistent_stop_fault.clone(),
            };
            if let Some(fault) = fault {
                state.running = fault.still_running;
                state.cleanup = state.retained_session.is_some();
                self.shared.record(Mark::StopFailed(fault.text.clone()));
                return Err(AudioCaptureError::Platform(fault.text));
            }
            state.running = false;
            state.cleanup = false;
            state.retained_session = None;
            Ok(())
        }

        fn is_running(&self) -> bool {
            self.shared.record(Mark::RunningQuery);
            self.shared.backend.lock().unwrap().running
        }

        fn has_pending_cleanup(&self) -> bool {
            self.shared.record(Mark::CleanupQuery);
            self.shared.backend.lock().unwrap().cleanup
        }
    }

    impl Drop for TestBackend {
        fn drop(&mut self) {
            let state = self.shared.backend.lock().unwrap();
            self.shared.record(Mark::BackendDropped {
                running: state.running,
                cleanup: state.cleanup,
                session: state.retained_session,
            });
            // Do not erase the retained-session marker after a failed final cleanup.
        }
    }

    struct TestAssembly {
        shared: Arc<Shared>,
        terminated: Option<mpsc::Sender<()>>,
    }

    impl CaptureAssembly for TestAssembly {
        type Backend = TestBackend;

        fn make_controller(&mut self) -> Result<AudioCaptureController<TestBackend>, String> {
            let _operation = self.shared.enter("initialize");
            let gate = self.shared.controls.lock().unwrap().initializer.take();
            if let Some(gate) = gate {
                gate.block();
            }
            if let Some(error) = self
                .shared
                .controls
                .lock()
                .unwrap()
                .initializer_error
                .take()
            {
                return Err(error);
            }
            Ok(AudioCaptureController::new(
                Arc::new(RejectFrames),
                TestBackend {
                    shared: self.shared.clone(),
                    _not_send: Rc::new(()),
                },
            ))
        }

        fn retain_live(
            &mut self,
            controller: &mut AudioCaptureController<TestBackend>,
        ) -> Result<Vec<SceneHandle>, String> {
            let _operation = self.shared.enter("retain");
            let before = self.shared.controls.lock().unwrap().before_retain.take();
            if let Some(gate) = before {
                gate.block();
            }
            let live = self.shared.live.lock().unwrap().clone();
            let result = controller
                .retain_scenes(&live)
                .map_err(|error| error.to_string());
            self.shared.capture(controller);
            let after = self.shared.controls.lock().unwrap().after_retain.take();
            if let Some(gate) = after {
                gate.block();
            }
            result.map(|()| live)
        }

        fn apply_demand(
            &mut self,
            controller: &mut AudioCaptureController<TestBackend>,
            demand: AudioCaptureDemand,
        ) -> Result<(), String> {
            let _operation = self.shared.enter("demand");
            self.shared.record(Mark::Demand(demand));
            let gate = self.shared.controls.lock().unwrap().demand.take();
            if let Some(gate) = gate {
                gate.block();
            }
            let error = self
                .shared
                .controls
                .lock()
                .unwrap()
                .demand_errors
                .pop_front();
            let result = match error {
                Some(error) => Err(error),
                None => controller
                    .set_demand(demand.suspended, demand.external_consumers)
                    .map_err(|error| error.to_string()),
            };
            self.shared.capture(controller);
            result
        }

        fn output_changed(
            &mut self,
            controller: &mut AudioCaptureController<TestBackend>,
            _: &CaptureEvents,
        ) {
            let _operation = self.shared.enter("device");
            self.shared.record(Mark::Device);
            self.shared.capture(controller);
        }

        fn retry_restart(
            &mut self,
            controller: &mut AudioCaptureController<TestBackend>,
            generation: u64,
            attempt: usize,
            _: &CaptureEvents,
        ) {
            let _operation = self.shared.enter("retry");
            self.shared.record(Mark::Retry(generation, attempt));
            self.shared.capture(controller);
        }

        fn sync_watch(&mut self, wanted: bool, _: &CaptureEvents) {
            let _operation = self.shared.enter("watch");
            let (gate, unavailable) = {
                let mut controls = self.shared.controls.lock().unwrap();
                (controls.watch.take(), controls.watch_unavailable)
            };
            self.shared.record(Mark::Watch {
                wanted,
                unavailable,
            });
            if let Some(gate) = gate {
                gate.block();
            }
        }

        fn stop_watch(&mut self) {
            let _operation = self.shared.enter("stop_watch");
            self.shared.record(Mark::WatchStopped);
        }
    }

    impl Drop for TestAssembly {
        fn drop(&mut self) {
            self.shared.record(Mark::AssemblyDropped);
            if let Some(terminated) = self.terminated.take() {
                let _ = terminated.send(());
            }
        }
    }

    struct WakeReply(mpsc::Sender<()>);

    impl Wake for WakeReply {
        fn wake(self: Arc<Self>) {
            let _ = self.0.send(());
        }
        fn wake_by_ref(self: &Arc<Self>) {
            let _ = self.0.send(());
        }
    }

    // Polls only after a real wake or an explicit assertion; never constructs a runtime.
    struct Driven {
        future: Pin<Box<dyn Future<Output = Result<(), String>> + Send>>,
        waker: Waker,
        wakes: mpsc::Receiver<()>,
        completed: Option<Result<(), String>>,
    }

    impl Driven {
        fn new(future: impl Future<Output = Result<(), String>> + Send + 'static) -> Self {
            let (sender, wakes) = mpsc::channel();
            let waker = Waker::from(Arc::new(WakeReply(sender)));
            let mut driven = Self {
                future: Box::pin(future),
                waker,
                wakes,
                completed: None,
            };
            let _ = driven.poll_once();
            driven
        }

        fn poll_once(&mut self) -> Option<Result<(), String>> {
            if self.completed.is_none() {
                let mut context = Context::from_waker(&self.waker);
                if let Poll::Ready(result) = self.future.as_mut().poll(&mut context) {
                    self.completed = Some(result);
                }
            }
            self.completed.clone()
        }

        fn assert_pending(&mut self) {
            assert!(
                self.poll_once().is_none(),
                "request replied before its gated work completed"
            );
        }

        fn wait(mut self) -> Result<(), String> {
            let deadline = Instant::now() + LIMIT;
            loop {
                if let Some(result) = self.poll_once() {
                    return result;
                }
                let remaining = deadline.saturating_duration_since(Instant::now());
                assert!(!remaining.is_zero(), "request never completed");
                self.wakes
                    .recv_timeout(remaining)
                    .expect("request never woke before the completion bound");
            }
        }
    }

    struct Lane {
        mailbox: CaptureMailbox,
        shared: Arc<Shared>,
        terminated: mpsc::Receiver<()>,
        finished: bool,
    }

    impl Lane {
        fn start(shared: Arc<Shared>) -> Self {
            let (sender, terminated) = mpsc::channel();
            let mailbox = start_capture_lane(TestAssembly {
                shared: shared.clone(),
                terminated: Some(sender),
            });
            Self {
                mailbox,
                shared,
                terminated,
                finished: false,
            }
        }

        fn scene(&self, raw: u64, enabled: bool) -> Driven {
            let mailbox = self.mailbox.clone();
            Driven::new(async move { mailbox.enable_scene(handle(raw), enabled).await })
        }

        fn demand(&self, demand: AudioCaptureDemand) -> Driven {
            let mailbox = self.mailbox.clone();
            Driven::new(async move { mailbox.update_demand(demand).await })
        }

        fn prune(&self) -> Driven {
            let mailbox = self.mailbox.clone();
            Driven::new(async move { mailbox.prune_scenes().await })
        }

        fn inspect(&self) -> Snapshot {
            let next = self.shared.count(|mark| *mark == Mark::End("device")) + 1;
            self.mailbox.events().output_changed();
            self.shared
                .wait_count(|mark| *mark == Mark::End("device"), next);
            self.shared.latest_snapshot()
        }

        fn finish(mut self) {
            self.mailbox.events().finish();
            self.terminated
                .recv_timeout(LIMIT)
                .expect("finish did not terminate the worker");
            self.finished = true;
            self.shared.assert_serial_worker();
        }
    }

    impl Drop for Lane {
        fn drop(&mut self) {
            if !self.finished {
                self.mailbox.events().finish();
                // Even a failed assertion must not silently abandon a worker.
                let result = self.terminated.recv_timeout(LIMIT);
                if !thread::panicking() {
                    result.expect("test left its worker alive");
                }
            }
        }
    }

    fn fail_stop(shared: &Shared, text: &str, still_running: bool) {
        shared
            .backend
            .lock()
            .unwrap()
            .stop_results
            .push_back(Some(StopFault {
                text: text.to_owned(),
                still_running,
            }));
    }

    fn hint(shared: &Shared, accepted: bool, later_status: bool) {
        let mut backend = shared.backend.lock().unwrap();
        backend.permission = false;
        backend.permission_replies.push_back(PermissionReply::Hint {
            accepted,
            later_status,
        });
    }

    fn position(marks: &[Mark], predicate: impl Fn(&Mark) -> bool) -> usize {
        marks
            .iter()
            .position(predicate)
            .expect("required operation missing from trace")
    }

    #[test]
    fn aw01_start_is_nonblocking_and_all_work_stays_on_one_thread() {
        fn transport<T: Clone + Send + Sync>() {}
        transport::<CaptureMailbox>();
        transport::<CaptureEvents>();
        let shared = Shared::new(&[FIRST]);
        let gate = HeldGate::new();
        shared.controls.lock().unwrap().initializer = Some(gate.0.clone());
        let lane = Lane::start(shared.clone());
        gate.wait_entered();
        let mut request = lane.scene(FIRST, true);
        request.assert_pending();
        lane.mailbox.events().output_changed();
        lane.mailbox.events().retry_restart(43, 2);
        assert_eq!(shared.count(|mark| *mark == Mark::Begin("retain")), 0);
        gate.release();
        assert_eq!(request.wait(), Ok(()));
        assert!(lane.inspect().healthy);
        lane.finish();
        assert_eq!(shared.count(|mark| *mark == Mark::Retry(43, 2)), 1);
    }

    #[test]
    fn aw02_initializer_failure_is_sticky_and_precedes_every_hook() {
        let shared = Shared::new(&[FIRST]);
        let failure = "initial construction failed: preserved verbatim.";
        shared.controls.lock().unwrap().initializer_error = Some(failure.to_owned());
        let lane = Lane::start(shared.clone());
        lane.mailbox.events().output_changed();
        lane.mailbox.events().retry_restart(99, 3);
        for result in [
            lane.scene(FIRST, true).wait(),
            lane.scene(FIRST, false).wait(),
            lane.demand(AudioCaptureDemand {
                suspended: false,
                external_consumers: true,
            })
            .wait(),
            lane.prune().wait(),
        ] {
            assert_eq!(result, Err(failure.to_owned()));
        }
        lane.finish();
        assert_eq!(
            shared.marks(),
            vec![
                Mark::Begin("initialize"),
                Mark::End("initialize"),
                Mark::AssemblyDropped
            ]
        );
    }

    #[test]
    fn aw03_serial_admission_prune_selection_watch_and_reply() {
        let shared = Shared::new(&[FIRST]);
        let lane = Lane::start(shared.clone());
        let first_gate = HeldGate::new();
        shared.controls.lock().unwrap().after_retain = Some(first_gate.0.clone());
        let mut first = lane.scene(FIRST, true);
        first_gate.wait_entered();
        let second_gate = HeldGate::new();
        shared.controls.lock().unwrap().before_retain = Some(second_gate.0.clone());
        let second = lane.demand(AudioCaptureDemand {
            suspended: false,
            external_consumers: false,
        });
        assert_eq!(shared.count(|mark| *mark == Mark::Begin("retain")), 1);
        assert_eq!(shared.count(|mark| matches!(mark, Mark::Demand(_))), 0);
        first.assert_pending();
        first_gate.release();
        second_gate.wait_entered();
        assert_eq!(
            first.poll_once(),
            Some(Ok(())),
            "the first reply must be sent before the next request enters"
        );
        second_gate.release();
        assert_eq!(second.wait(), Ok(()));
        let marks = shared.marks();
        let start = position(&marks, |mark| matches!(mark, Mark::Start { .. }));
        let first_watch = position(&marks, |mark| matches!(mark, Mark::Watch { .. }));
        let demand = position(&marks, |mark| matches!(mark, Mark::Demand(_)));
        assert!(position(&marks, |mark| *mark == Mark::End("retain")) < start);
        assert!(start < first_watch && first_watch < demand);
        assert_eq!(shared.count(|mark| matches!(mark, Mark::Watch { .. })), 2);
        assert_eq!(shared.count(|mark| *mark == Mark::Begin("retain")), 2);
        lane.finish();
    }

    #[test]
    fn aw04_live_permitted_enable_is_idempotent() {
        let shared = Shared::new(&[FIRST]);
        let lane = Lane::start(shared.clone());
        assert_eq!(lane.scene(FIRST, true).wait(), Ok(()));
        assert_eq!(lane.scene(FIRST, true).wait(), Ok(()));
        let snapshot = lane.inspect();
        assert_eq!(snapshot.owners, 1);
        assert!(snapshot.healthy && snapshot.wanted && !snapshot.cleanup);
        assert_eq!(shared.permission_requests(), 0);
        assert_eq!(shared.starts().len(), 1);
        lane.finish();
    }

    #[test]
    fn aw05_startup_hint_is_not_a_grant_or_a_healthy_session() {
        for (later_status, failure) in [
            (true, None),
            (true, Some("OS denied startup.")),
            (false, None),
        ] {
            let shared = Shared::new(&[FIRST]);
            hint(&shared, true, later_status);
            if let Some(text) = failure {
                shared
                    .backend
                    .lock()
                    .unwrap()
                    .start_errors
                    .push_back(text.to_owned());
            }
            let lane = Lane::start(shared.clone());
            let result = lane.scene(FIRST, true).wait();
            let snapshot = lane.inspect();
            assert_eq!(shared.permission_requests(), 1);
            match failure {
                Some(text) => {
                    assert!(result.unwrap_err().contains(text));
                    assert!(!snapshot.healthy);
                    assert_eq!(snapshot.owners, 0);
                    assert!(shared.starts().is_empty());
                }
                None if later_status => {
                    assert_eq!(result, Ok(()));
                    assert!(snapshot.healthy);
                    assert_eq!(snapshot.owners, 1);
                    assert_eq!(shared.starts().len(), 1);
                }
                None => {
                    assert_eq!(result, Ok(()));
                    assert_eq!(snapshot.owners, 1);
                    assert!(snapshot.wanted && !snapshot.healthy);
                    assert!(shared.starts().is_empty());
                }
            }
            let marks = shared.marks();
            let request = position(&marks, |mark| *mark == Mark::PermissionRequest);
            if let Some(start) = marks
                .iter()
                .position(|mark| matches!(mark, Mark::Start { .. } | Mark::StartFailed(_)))
            {
                assert!(request < start);
            }
            lane.finish();
        }
    }

    #[test]
    fn aw06_permission_errors_refusal_and_prior_owner_sync_are_distinct() {
        for scenario in 0..3 {
            let shared = Shared::new(&[FIRST]);
            let gate = HeldGate::new();
            shared.controls.lock().unwrap().after_retain = Some(gate.0.clone());
            let lane = Lane::start(shared.clone());
            let request = lane.scene(FIRST, true);
            gate.wait_entered();
            let expected = match scenario {
                0 => {
                    shared.backend.lock().unwrap().status_error =
                        Some("status unavailable: raw.".to_owned());
                    Some("status unavailable: raw.")
                }
                1 => {
                    let mut backend = shared.backend.lock().unwrap();
                    backend.permission = false;
                    backend
                        .permission_replies
                        .push_back(PermissionReply::Error("hint failed: raw.".to_owned()));
                    Some("hint failed: raw.")
                }
                _ => {
                    hint(&shared, false, false);
                    None
                }
            };
            gate.release();
            let error = request.wait().unwrap_err();
            if let Some(expected) = expected {
                assert_eq!(error, expected);
            }
            assert_eq!(lane.inspect().owners, 0);
            assert_eq!(shared.permission_requests(), usize::from(scenario != 0));
            lane.finish();
        }

        let shared = Shared::new(&[FIRST, SECOND]);
        hint(&shared, true, false);
        let lane = Lane::start(shared.clone());
        assert_eq!(lane.scene(FIRST, true).wait(), Ok(()));
        let gate = HeldGate::new();
        shared.controls.lock().unwrap().after_retain = Some(gate.0.clone());
        let request = lane.scene(SECOND, true);
        gate.wait_entered();
        hint(&shared, true, true);
        shared
            .backend
            .lock()
            .unwrap()
            .start_errors
            .push_back("old owner synchronization failed".to_owned());
        gate.release();
        assert_eq!(
            request.wait(),
            Err("old owner synchronization failed".to_owned())
        );
        let snapshot = lane.inspect();
        assert_eq!(snapshot.owners, 1);
        assert!(snapshot.wanted && !snapshot.healthy);
        assert_eq!(shared.permission_requests(), 2);
        lane.finish();
    }

    #[test]
    fn aw07_live_snapshot_controls_enable_but_not_disable_or_reused_handles() {
        let shared = Shared::new(&[FIRST]);
        let lane = Lane::start(shared.clone());
        assert_eq!(lane.scene(FIRST, true).wait(), Ok(()));
        let gate = HeldGate::new();
        shared.controls.lock().unwrap().demand = Some(gate.0.clone());
        let preceding = lane.demand(AudioCaptureDemand::default());
        gate.wait_entered();
        let enable = lane.scene(FIRST, true);
        shared.set_live(&[]);
        gate.release();
        assert_eq!(preceding.wait(), Ok(()));
        assert!(enable.wait().is_err());
        let marks = shared.marks();
        let prune = marks
            .iter()
            .rposition(|mark| *mark == Mark::End("retain"))
            .unwrap();
        assert!(
            !marks[prune + 1..].iter().any(|mark| matches!(
                mark,
                Mark::Status
                    | Mark::PermissionRequest
                    | Mark::Start { .. }
                    | Mark::StartFailed(_)
                    | Mark::Stop(_)
            )),
            "an absent enable must do no selected backend work after pruning"
        );
        assert_eq!(lane.inspect().owners, 0);
        assert_eq!(lane.scene(FIRST, false).wait(), Ok(()));
        assert_eq!(shared.permission_requests(), 0);
        shared.set_live(&[FIRST]);
        assert_eq!(lane.scene(FIRST, true).wait(), Ok(()));
        assert_eq!(lane.inspect().owners, 1);
        shared.set_live(&[]);
        fail_stop(&shared, "departed owner cleanup", false);
        assert_eq!(
            lane.scene(FIRST, false).wait(),
            Err("departed owner cleanup".to_owned())
        );
        let pending = lane.inspect();
        assert_eq!(pending.owners, 0);
        assert!(pending.cleanup);
        assert_eq!(lane.scene(FIRST, false).wait(), Ok(()));
        assert!(!lane.inspect().cleanup);
        assert_eq!(shared.permission_requests(), 0);
        lane.finish();
    }

    #[test]
    fn aw08_prune_failure_wins_and_commits_owner_removal() {
        let shared = Shared::new(&[FIRST]);
        let lane = Lane::start(shared.clone());
        assert_eq!(lane.scene(FIRST, true).wait(), Ok(()));
        shared.set_live(&[]);
        fail_stop(&shared, "prune teardown failed", false);
        shared.backend.lock().unwrap().status_error =
            Some("must not replace prune failure".to_owned());
        assert_eq!(
            lane.scene(SECOND, true).wait(),
            Err("prune teardown failed".to_owned())
        );
        let marks = shared.marks();
        let prune = marks
            .iter()
            .rposition(|mark| *mark == Mark::End("retain"))
            .unwrap();
        assert!(
            !marks[prune + 1..].iter().any(|mark| matches!(
                mark,
                Mark::Status
                    | Mark::PermissionRequest
                    | Mark::Start { .. }
                    | Mark::StartFailed(_)
                    | Mark::Stop(_)
            )),
            "prune failure must skip selected backend work"
        );
        let snapshot = lane.inspect();
        assert_eq!(snapshot.owners, 0);
        assert!(!snapshot.wanted && !snapshot.healthy && snapshot.cleanup);
        assert_eq!(
            shared.marks().iter().rev().find_map(|mark| {
                if let Mark::Watch { wanted, .. } = mark {
                    Some(*wanted)
                } else {
                    None
                }
            }),
            Some(false)
        );
        shared.backend.lock().unwrap().status_error = None;
        assert_eq!(lane.prune().wait(), Ok(()));
        assert_eq!(lane.inspect().owners, 0);
        assert_eq!(shared.starts().len(), 1);
        lane.finish();
    }

    #[test]
    fn aw09_scene_failures_preserve_core_ownership_and_cleanup_rules() {
        let shared = Shared::new(&[FIRST]);
        shared
            .backend
            .lock()
            .unwrap()
            .start_errors
            .push_back("new activation failed.".to_owned());
        let lane = Lane::start(shared.clone());
        assert!(
            lane.scene(FIRST, true)
                .wait()
                .unwrap_err()
                .contains("new activation failed.")
        );
        assert_eq!(lane.inspect().owners, 0);
        hint(&shared, true, false);
        assert_eq!(lane.scene(FIRST, true).wait(), Ok(()));
        assert_eq!(lane.inspect().owners, 1);
        let gate = HeldGate::new();
        shared.controls.lock().unwrap().after_retain = Some(gate.0.clone());
        let existing = lane.scene(FIRST, true);
        gate.wait_entered();
        {
            let mut backend = shared.backend.lock().unwrap();
            backend.permission = true;
            backend
                .start_errors
                .push_back("existing activation failed".to_owned());
        }
        gate.release();
        assert!(
            existing
                .wait()
                .unwrap_err()
                .contains("existing activation failed")
        );
        assert_eq!(lane.inspect().owners, 1);
        assert_eq!(lane.scene(FIRST, true).wait(), Ok(()));
        let session = lane.inspect().session;
        fail_stop(&shared, "final owner stop failed.", false);
        assert!(
            lane.scene(FIRST, false)
                .wait()
                .unwrap_err()
                .contains("final owner stop failed.")
        );
        let snapshot = lane.inspect();
        assert_eq!(snapshot.owners, 0);
        assert!(!snapshot.wanted && !snapshot.healthy && snapshot.cleanup);
        assert_eq!(snapshot.session, session);
        assert_eq!(lane.scene(FIRST, false).wait(), Ok(()));
        assert!(!lane.inspect().cleanup);
        assert_eq!(shared.starts().len(), 1);
        lane.finish();
    }

    #[test]
    fn aw11_pruning_uses_fresh_live_owners_and_preserves_external_demand() {
        let shared = Shared::new(&[FIRST, SECOND]);
        let lane = Lane::start(shared.clone());
        assert_eq!(lane.scene(FIRST, true).wait(), Ok(()));
        assert_eq!(lane.scene(SECOND, true).wait(), Ok(()));
        assert_eq!(
            lane.demand(AudioCaptureDemand {
                suspended: false,
                external_consumers: true
            })
            .wait(),
            Ok(())
        );
        shared.set_live(&[SECOND]);
        assert_eq!(lane.prune().wait(), Ok(()));
        assert_eq!(lane.inspect().owners, 1);
        shared.set_live(&[]);
        let stop_before = shared.count(|mark| matches!(mark, Mark::Stop(_)));
        assert_eq!(lane.prune().wait(), Ok(()));
        let snapshot = lane.inspect();
        assert_eq!(snapshot.owners, 0);
        assert!(snapshot.wanted && snapshot.healthy);
        assert_eq!(
            shared.count(|mark| matches!(mark, Mark::Stop(_))),
            stop_before
        );
        assert_eq!(shared.starts().len(), 1);
        assert_eq!(shared.permission_requests(), 0);
        lane.finish();
    }

    #[test]
    fn aw12_dropping_waiter_does_not_cancel_admitted_mutation() {
        let shared = Shared::new(&[FIRST]);
        let lane = Lane::start(shared.clone());
        let gate = HeldGate::new();
        shared.controls.lock().unwrap().after_retain = Some(gate.0.clone());
        let mut abandoned = lane.scene(FIRST, true);
        gate.wait_entered();
        abandoned.assert_pending();
        drop(abandoned);
        gate.release();
        assert_eq!(lane.prune().wait(), Ok(()));
        let snapshot = lane.inspect();
        assert_eq!(snapshot.owners, 1);
        assert!(snapshot.healthy);
        assert_eq!(shared.starts().len(), 1);
        assert_eq!(shared.count(|mark| matches!(mark, Mark::Watch { .. })), 2);
        lane.finish();
    }

    #[test]
    fn aw14_watch_sync_precedes_all_replies_and_never_replaces_results() {
        let shared = Shared::new(&[FIRST]);
        let lane = Lane::start(shared.clone());
        let gate = HeldGate::new();
        {
            let mut controls = shared.controls.lock().unwrap();
            controls.watch = Some(gate.0.clone());
            controls.watch_unavailable = true;
        }
        let mut success = lane.scene(FIRST, true);
        gate.wait_entered();
        success.assert_pending();
        assert!(shared.marks().contains(&Mark::Watch {
            wanted: true,
            unavailable: true
        }));
        gate.release();
        assert_eq!(success.wait(), Ok(()));

        let selected_gate = HeldGate::new();
        shared.controls.lock().unwrap().watch = Some(selected_gate.0.clone());
        shared
            .controls
            .lock()
            .unwrap()
            .demand_errors
            .push_back("selected operation failure".to_owned());
        let mut selected = lane.demand(AudioCaptureDemand {
            suspended: true,
            external_consumers: false,
        });
        selected_gate.wait_entered();
        selected.assert_pending();
        assert!(matches!(
            shared.marks().last(),
            Some(Mark::Watch {
                wanted: true,
                unavailable: true
            })
        ));
        selected_gate.release();
        assert_eq!(
            selected.wait(),
            Err("selected operation failure".to_owned())
        );

        shared.set_live(&[]);
        fail_stop(&shared, "pruning failure", true);
        let prune_gate = HeldGate::new();
        shared.controls.lock().unwrap().watch = Some(prune_gate.0.clone());
        let mut prune = lane.prune();
        prune_gate.wait_entered();
        prune.assert_pending();
        assert!(matches!(
            shared.marks().last(),
            Some(Mark::Watch {
                wanted: false,
                unavailable: true
            })
        ));
        let snapshot = shared.latest_snapshot();
        assert!(snapshot.running && snapshot.cleanup && !snapshot.healthy);
        prune_gate.release();
        assert_eq!(prune.wait(), Err("pruning failure".to_owned()));
        lane.finish();
    }

    #[test]
    fn aw15_finish_ignores_retained_senders_and_disposes_watch_before_controller() {
        let shared = Shared::new(&[FIRST]);
        let lane = Lane::start(shared.clone());
        assert_eq!(lane.scene(FIRST, true).wait(), Ok(()));
        fail_stop(&shared, "cleanup remains owed", false);
        assert!(
            lane.scene(FIRST, false)
                .wait()
                .unwrap_err()
                .contains("cleanup remains owed")
        );
        assert!(lane.inspect().cleanup);
        let retained_events = lane.mailbox.events();
        let retained_mailbox = lane.mailbox.clone();
        let stop_before = shared.count(|mark| matches!(mark, Mark::Stop(_)));
        lane.finish();
        let marks = shared.marks();
        let watch = position(&marks, |mark| *mark == Mark::WatchStopped);
        let last_stop = marks
            .iter()
            .rposition(|mark| matches!(mark, Mark::Stop(_)))
            .unwrap();
        let backend = position(&marks, |mark| matches!(mark, Mark::BackendDropped { .. }));
        let assembly = position(&marks, |mark| *mark == Mark::AssemblyDropped);
        assert!(watch < last_stop && last_stop < backend && backend < assembly);
        assert!(shared.count(|mark| matches!(mark, Mark::Stop(_))) > stop_before);
        let after = shared.marks();
        retained_events.output_changed();
        retained_events.retry_restart(909, 3);
        retained_events.finish();
        drop(retained_mailbox);
        assert_eq!(shared.marks(), after);
    }

    #[test]
    fn aw16_closed_and_queued_behind_finish_requests_fail_without_work() {
        let shared = Shared::new(&[]);
        let lane = Lane::start(shared.clone());
        drop(lane.mailbox.clone());
        drop(lane.mailbox.events());
        assert_eq!(lane.prune().wait(), Ok(()));
        let mailbox = lane.mailbox.clone();
        lane.finish();
        let stopped = Driven::new(async move { mailbox.prune_scenes().await }).wait();
        assert!(stopped.is_err());

        let shared = Shared::new(&[]);
        let gate = HeldGate::new();
        shared.controls.lock().unwrap().initializer = Some(gate.0.clone());
        let lane = Lane::start(shared.clone());
        gate.wait_entered();
        lane.mailbox.events().finish();
        let mut behind_finish = lane.prune();
        behind_finish.assert_pending();
        gate.release();
        assert!(behind_finish.wait().is_err());
        lane.finish();
        assert_eq!(shared.count(|mark| *mark == Mark::Begin("retain")), 0);
    }

    #[test]
    fn aw17_partial_teardown_never_overlaps_or_replaces_consumer_identity() {
        let shared = Shared::new(&[FIRST]);
        let lane = Lane::start(shared.clone());
        assert_eq!(lane.scene(FIRST, true).wait(), Ok(()));
        let first_session = lane.inspect().session;
        fail_stop(&shared, "initial cleanup failure", false);
        assert!(
            lane.scene(FIRST, false)
                .wait()
                .unwrap_err()
                .contains("initial cleanup failure")
        );
        let pending = lane.inspect();
        assert_eq!(pending.session, first_session);
        assert!(pending.cleanup && !pending.healthy);
        fail_stop(&shared, "cleanup still blocks replacement", false);
        let requests_before = shared.permission_requests();
        assert_eq!(
            lane.scene(FIRST, true).wait(),
            Err("cleanup still blocks replacement".to_owned())
        );
        let still_pending = lane.inspect();
        assert_eq!(still_pending.session, first_session);
        assert!(still_pending.cleanup && !still_pending.healthy);
        assert_eq!(shared.starts().len(), 1);
        assert_eq!(shared.permission_requests(), requests_before);

        // Let this request's prune recover the old retained session, then inject a
        // permission-path synchronization failure for a pre-existing pending owner.
        hint(&shared, true, false);
        assert_eq!(lane.scene(FIRST, true).wait(), Ok(()));
        assert_eq!(lane.inspect().owners, 1);
        let gate = HeldGate::new();
        shared.controls.lock().unwrap().after_retain = Some(gate.0.clone());
        let synchronization = lane.scene(FIRST, true);
        gate.wait_entered();
        hint(&shared, true, true);
        shared
            .backend
            .lock()
            .unwrap()
            .start_errors
            .push_back("permission synchronization failed".to_owned());
        gate.release();
        assert_eq!(
            synchronization.wait(),
            Err("permission synchronization failed".to_owned())
        );
        assert_eq!(lane.inspect().owners, 1);
        assert_eq!(lane.prune().wait(), Ok(()));
        assert!(lane.inspect().healthy);
        let starts = shared.starts();
        assert_eq!(starts.len(), 2);
        assert_ne!(starts[0].0, starts[1].0);
        assert_eq!(starts[0].1, starts[1].1);

        shared.backend.lock().unwrap().persistent_stop_fault = Some(StopFault {
            text: "persistent protected teardown".to_owned(),
            still_running: true,
        });
        assert!(
            lane.scene(FIRST, false)
                .wait()
                .unwrap_err()
                .contains("persistent protected teardown")
        );
        let retained = lane.inspect();
        assert!(retained.running && retained.cleanup && !retained.healthy && !retained.wanted);
        assert_eq!(
            lane.prune().wait(),
            Err("persistent protected teardown".to_owned())
        );
        assert_eq!(lane.inspect().owners, 0);
        assert_eq!(shared.starts().len(), 2);
        lane.finish();
        let dropped = shared
            .marks()
            .into_iter()
            .find_map(|mark| {
                if let Mark::BackendDropped {
                    running,
                    cleanup,
                    session,
                } = mark
                {
                    Some((running, cleanup, session))
                } else {
                    None
                }
            })
            .unwrap();
        assert_eq!(dropped, (true, true, retained.session));
        assert!(
            dropped.2.is_some(),
            "the lane must not manufacture complete native release"
        );
    }

    mod policy_tests;
}
