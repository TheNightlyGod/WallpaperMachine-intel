use super::*;
use crate::engine::facade::{
    AudioRestartState, OutputWatchGate, OwnedCaptureLane, RestartAction,
    apply_audio_capture_demand, handle_audio_restart_retry, handle_output_device_change,
    mutate_audio, mutate_scenes_and_prune, retain_capture_live, schedule_audio_restart,
};
use wallpaper_core::{DisplayDesc, DisplayIdentity, DisplaySnapshotEntry, EngineError};

const ALPHA: u64 = 47_123;
const BETA: u64 = 83_219;

fn external() -> AudioCaptureDemand {
    AudioCaptureDemand {
        suspended: false,
        external_consumers: true,
    }
}

fn suspended() -> AudioCaptureDemand {
    AudioCaptureDemand {
        suspended: true,
        external_consumers: false,
    }
}

fn display(id: u32, scene: Option<u64>) -> DisplaySnapshotEntry {
    DisplaySnapshotEntry {
        identity: DisplayIdentity::default(),
        desc: DisplayDesc::new(id, 0, 0, 320, 240, 1.0),
        handle: scene.map(handle),
        accepts_pointer_input: false,
        paused: false,
        window_active: false,
        assignment: None,
    }
}

// Only IO/observation adapters live here. All controller, retention, demand,
// restart, watch-edge, serialization and ownership decisions are production code.
struct PolicyIo {
    reading: Mutex<Vec<DisplaySnapshotEntry>>,
    samples: Mutex<Vec<Vec<SceneHandle>>>,
    actions: Mutex<Vec<RestartAction>>,
    watch_attempts: AtomicUsize,
    watch_drops: AtomicUsize,
    watching: AtomicUsize,
}

impl PolicyIo {
    fn new(live: &[u64]) -> Arc<Self> {
        Arc::new(Self {
            reading: Mutex::new(
                live.iter()
                    .enumerate()
                    .map(|(index, raw)| display(index as u32 + 10, Some(*raw)))
                    .collect(),
            ),
            samples: Mutex::new(Vec::new()),
            actions: Mutex::new(Vec::new()),
            watch_attempts: AtomicUsize::new(0),
            watch_drops: AtomicUsize::new(0),
            watching: AtomicUsize::new(0),
        })
    }

    fn set_live(&self, live: &[u64]) {
        *self.reading.lock().unwrap() = live
            .iter()
            .enumerate()
            .map(|(index, raw)| display(index as u32 + 10, Some(*raw)))
            .collect();
    }

    fn action(&self) -> RestartAction {
        *self
            .actions
            .lock()
            .unwrap()
            .last()
            .expect("missing real policy decision")
    }
}

struct CountedWatch {
    shared: Arc<Shared>,
    io: Arc<PolicyIo>,
}

impl Drop for CountedWatch {
    fn drop(&mut self) {
        self.io.watch_drops.fetch_add(1, Ordering::SeqCst);
        self.io.watching.fetch_sub(1, Ordering::SeqCst);
        self.shared.record(Mark::WatchStopped);
    }
}

struct PolicyAssembly {
    base: TestAssembly,
    io: Arc<PolicyIo>,
    restart: AudioRestartState,
    watch: OutputWatchGate<CountedWatch>,
}

impl CaptureAssembly for PolicyAssembly {
    type Backend = TestBackend;

    fn make_controller(&mut self) -> Result<AudioCaptureController<TestBackend>, String> {
        self.base.make_controller()
    }

    fn retain_live(
        &mut self,
        controller: &mut AudioCaptureController<TestBackend>,
    ) -> Result<Vec<SceneHandle>, String> {
        let shared = &self.base.shared;
        let _operation = shared.enter("retain");
        let gate = shared.controls.lock().unwrap().before_retain.take();
        if let Some(gate) = gate {
            gate.block();
        }
        // The reading is deliberately sampled here, after the gate/core change.
        let result = {
            let reading = self.io.reading.lock().unwrap();
            retain_capture_live(controller, &reading)
        };
        if let Ok(handles) = &result {
            self.io.samples.lock().unwrap().push(handles.clone());
        }
        shared.capture(controller);
        let gate = shared.controls.lock().unwrap().after_retain.take();
        if let Some(gate) = gate {
            gate.block();
        }
        result
    }

    fn apply_demand(
        &mut self,
        controller: &mut AudioCaptureController<TestBackend>,
        demand: AudioCaptureDemand,
    ) -> Result<(), String> {
        let shared = &self.base.shared;
        let _operation = shared.enter("demand");
        shared.record(Mark::Demand(demand));
        let gate = shared.controls.lock().unwrap().demand.take();
        if let Some(gate) = gate {
            gate.block();
        }
        let result = apply_audio_capture_demand(controller, demand);
        shared.capture(controller);
        result
    }

    fn output_changed(
        &mut self,
        controller: &mut AudioCaptureController<TestBackend>,
        _: &CaptureEvents,
    ) {
        let shared = &self.base.shared;
        let _operation = shared.enter("device");
        shared.record(Mark::Device);
        let action = handle_output_device_change(controller, &mut self.restart);
        self.io.actions.lock().unwrap().push(action);
        shared.capture(controller);
    }

    fn retry_restart(
        &mut self,
        controller: &mut AudioCaptureController<TestBackend>,
        generation: u64,
        attempt: usize,
        _: &CaptureEvents,
    ) {
        let shared = &self.base.shared;
        let _operation = shared.enter("retry");
        shared.record(Mark::Retry(generation, attempt));
        let action = handle_audio_restart_retry(controller, &self.restart, generation, attempt);
        self.io.actions.lock().unwrap().push(action);
        shared.capture(controller);
    }

    fn sync_watch(&mut self, wanted: bool, _: &CaptureEvents) {
        let shared = &self.base.shared;
        let _operation = shared.enter("watch");
        let (gate, unavailable) = {
            let mut controls = shared.controls.lock().unwrap();
            (controls.watch.take(), controls.watch_unavailable)
        };
        self.watch.sync(wanted, || {
            self.io.watch_attempts.fetch_add(1, Ordering::SeqCst);
            if unavailable {
                return None;
            }
            self.io.watching.fetch_add(1, Ordering::SeqCst);
            Some(CountedWatch {
                shared: shared.clone(),
                io: self.io.clone(),
            })
        });
        assert_eq!(
            self.watch.is_watching(),
            self.io.watching.load(Ordering::SeqCst) == 1
        );
        shared.record(Mark::Watch {
            wanted,
            unavailable,
        });
        // Blocking after sync proves synchronization precedes the command reply.
        if let Some(gate) = gate {
            gate.block();
        }
    }

    fn stop_watch(&mut self) {
        let _operation = self.base.shared.enter("stop_watch");
        self.watch
            .sync(false, || unreachable!("stopping cannot start a watcher"));
        assert!(!self.watch.is_watching());
    }
}

struct PolicyLane {
    owner: OwnedCaptureLane,
    shared: Arc<Shared>,
    io: Arc<PolicyIo>,
    terminated: mpsc::Receiver<()>,
}

impl PolicyLane {
    fn start(live: &[u64]) -> Self {
        Self::with_shared(Shared::new(&[]), PolicyIo::new(live))
    }

    fn with_shared(shared: Arc<Shared>, io: Arc<PolicyIo>) -> Self {
        let (sender, terminated) = mpsc::channel();
        let mailbox = start_capture_lane(PolicyAssembly {
            base: TestAssembly {
                shared: shared.clone(),
                terminated: Some(sender),
            },
            io: io.clone(),
            restart: AudioRestartState::default(),
            watch: OutputWatchGate::default(),
        });
        Self {
            owner: OwnedCaptureLane::from_mailbox(mailbox),
            shared,
            io,
            terminated,
        }
    }

    fn demand(&self, demand: AudioCaptureDemand) -> Driven {
        let owner = self.owner.clone();
        Driven::new(async move { owner.mailbox().update_demand(demand).await })
    }

    fn scene(&self, scene: u64, enabled: bool) -> Driven {
        let owner = self.owner.clone();
        Driven::new(async move { owner.mailbox().enable_scene(handle(scene), enabled).await })
    }

    fn prune(&self) -> Driven {
        let owner = self.owner.clone();
        Driven::new(async move { owner.mailbox().prune_scenes().await })
    }

    fn output(&self) -> RestartAction {
        let next = self.shared.count(|m| *m == Mark::End("device")) + 1;
        self.owner.mailbox().events().output_changed();
        self.shared.wait_count(|m| *m == Mark::End("device"), next);
        self.io.action()
    }

    fn retry(&self, generation: u64, attempt: usize) -> RestartAction {
        let next = self.shared.count(|m| *m == Mark::End("retry")) + 1;
        self.owner
            .mailbox()
            .events()
            .retry_restart(generation, attempt);
        self.shared.wait_count(|m| *m == Mark::End("retry"), next);
        self.io.action()
    }

    fn close(self) {
        let Self {
            owner,
            shared,
            io: _,
            terminated,
        } = self;
        drop(owner); // Never post Finish from a test-only lifetime guard.
        terminated
            .recv_timeout(LIMIT)
            .expect("actual final owner did not end worker");
        shared.assert_serial_worker();
    }
}

fn retry_parts(action: RestartAction, millis: u64, expected_attempt: usize) -> (u64, usize) {
    match action {
        RestartAction::RetryIn {
            delay,
            generation,
            attempt,
        } => {
            assert_eq!(delay, Duration::from_millis(millis));
            assert_eq!(attempt, expected_attempt);
            (generation, attempt)
        }
        other => panic!("expected finite retry, got {other:?}"),
    }
}

fn assert_no_overlap(shared: &Shared) {
    assert_eq!(shared.count(|m| *m == Mark::OverlapRejected), 0);
    assert_eq!(shared.backend.lock().unwrap().largest_retained, 1);
    let starts = shared.starts();
    assert!(!starts.is_empty());
    assert!(starts.iter().all(|(_, consumer)| *consumer == starts[0].1));
    assert!(starts.windows(2).all(|pair| pair[0].0 != pair[1].0));
}

#[test]
fn ap01_aw18_external_permission_and_atomic_demand_use_real_policy() {
    let shared = Shared::new(&[]);
    hint(&shared, true, true);
    let lane = PolicyLane::with_shared(shared.clone(), PolicyIo::new(&[]));
    assert_eq!(lane.demand(external()).wait(), Ok(()));
    let state = shared.latest_snapshot();
    assert_eq!((state.owners, state.wanted, state.healthy), (0, true, true));
    assert_eq!(shared.permission_requests(), 1);
    assert_eq!(shared.starts().len(), 1);
    assert_eq!(lane.demand(suspended()).wait(), Ok(()));
    let state = shared.latest_snapshot();
    assert_eq!(
        (state.owners, state.wanted, state.healthy),
        (0, false, false)
    );
    assert_eq!(lane.demand(AudioCaptureDemand::default()).wait(), Ok(()));
    let state = shared.latest_snapshot();
    assert_eq!(
        (state.owners, state.wanted, state.healthy),
        (0, false, false)
    );
    assert_eq!(shared.starts().len(), 1);
    assert_eq!(shared.permission_requests(), 1);
    lane.close();
}

#[test]
fn ap01_aw18_permission_hint_is_not_grant_and_causes_remain_distinct() {
    for case in 0..4 {
        let shared = Shared::new(&[]);
        let cause = match case {
            0 => {
                hint(&shared, true, true);
                let text = "request accepted; native start denied [p41]";
                shared
                    .backend
                    .lock()
                    .unwrap()
                    .start_errors
                    .push_back(text.to_owned());
                Some(text)
            }
            1 => {
                hint(&shared, false, false);
                None
            }
            2 => {
                let text = "status transport [p73]";
                shared.backend.lock().unwrap().status_error = Some(text.to_owned());
                Some(text)
            }
            _ => {
                let text = "request transport [p97]";
                let mut state = shared.backend.lock().unwrap();
                state.permission = false;
                state
                    .permission_replies
                    .push_back(PermissionReply::Error(text.to_owned()));
                Some(text)
            }
        };
        let lane = PolicyLane::with_shared(shared.clone(), PolicyIo::new(&[]));
        let error = lane
            .demand(external())
            .wait()
            .expect_err("permission path must fail");
        if let Some(cause) = cause {
            assert!(error.contains(cause));
        }
        assert!(!error.is_empty());
        assert_eq!(shared.permission_requests(), if case == 2 { 0 } else { 1 });
        assert!(shared.starts().is_empty());
        assert_eq!(
            shared.count(|m| matches!(m, Mark::StartFailed(_))),
            if case == 0 { 1 } else { 0 }
        );
        let state = shared.latest_snapshot();
        assert_eq!(
            (state.owners, state.wanted, state.healthy),
            (0, false, false)
        );
        lane.close();
    }
}

#[tokio::test]
async fn ap02_aw19_failed_demand_preserves_both_causes_flags_and_committed_prune() {
    let lane = PolicyLane::start(&[ALPHA]);
    assert_eq!(lane.demand(external()).wait(), Ok(()));
    assert_eq!(lane.scene(ALPHA, true).wait(), Ok(()));
    lane.io.set_live(&[]);
    fail_stop(&lane.shared, "transition close [d17]", false);
    fail_stop(&lane.shared, "rollback close [d31]", false);
    let owner = lane.owner.clone();
    let exclusion = tokio::sync::Mutex::new(());
    let raw_failure = Arc::new(Mutex::new(None));
    let observed = raw_failure.clone();
    let result = mutate_audio(&exclusion, || async move {
        let result = owner.mailbox().update_demand(suspended()).await;
        *observed.lock().unwrap() = result.as_ref().err().cloned();
        result
    })
    .await;
    let text = match result {
        Err(EngineError::Platform(text)) => text,
        other => panic!("expected real Platform envelope: {other:?}"),
    };
    assert_eq!(raw_failure.lock().unwrap().as_ref(), Some(&text));
    assert!(text.contains("transition close [d17]"));
    assert!(text.contains("rollback close [d31]"));
    let state = lane.shared.latest_snapshot();
    // With no scene owners wanted=true requires BOTH previous demand flags.
    assert_eq!(
        (state.owners, state.wanted, state.healthy, state.cleanup),
        (0, true, false, true)
    );
    assert!(lane.io.samples.lock().unwrap().last().unwrap().is_empty());
    assert_eq!(lane.prune().wait(), Ok(()));
    let state = lane.shared.latest_snapshot();
    assert_eq!((state.owners, state.wanted, state.healthy), (0, true, true));
    assert_eq!(lane.demand(suspended()).wait(), Ok(()));
    assert_no_overlap(&lane.shared);
    lane.close();
}

#[test]
fn ap03_aw20_partial_cleanup_retries_real_policy_with_literal_budget() {
    let lane = PolicyLane::start(&[]);
    assert_eq!(lane.demand(external()).wait(), Ok(()));
    let first_session = lane.shared.starts()[0];
    fail_stop(&lane.shared, "event cleanup [r13]", false);
    let (generation, attempt) = retry_parts(lane.output(), 500, 1);
    let state = lane.shared.latest_snapshot();
    assert_eq!(
        (state.wanted, state.healthy, state.running, state.cleanup),
        (true, false, false, true)
    );
    assert_eq!(state.session, Some(first_session.0));
    assert_eq!(lane.shared.starts().len(), 1);
    assert_eq!(lane.retry(generation, attempt), RestartAction::Done);
    let state = lane.shared.latest_snapshot();
    assert_eq!((state.healthy, state.cleanup), (true, false));
    assert_eq!(lane.shared.starts().len(), 2);
    assert_no_overlap(&lane.shared);
    assert_eq!(lane.shared.permission_requests(), 0);

    lane.shared.backend.lock().unwrap().persistent_stop_fault = Some(StopFault {
        text: "persistent teardown [r29]".to_owned(),
        still_running: true,
    });
    let before = lane.shared.count(|m| matches!(m, Mark::StopFailed(_)));
    let (g0, a0) = retry_parts(lane.output(), 500, 1);
    let (g1, a1) = retry_parts(lane.retry(g0, a0), 1000, 2);
    let (g2, a2) = retry_parts(lane.retry(g1, a1), 1500, 3);
    assert_eq!((g0, g1), (g1, g2));
    assert_eq!(lane.retry(g2, a2), RestartAction::GaveUp);
    assert_eq!(
        lane.shared.count(|m| matches!(m, Mark::StopFailed(_))) - before,
        4
    );
    assert_eq!(lane.shared.starts().len(), 2);
    assert_eq!(lane.shared.permission_requests(), 0);
    lane.shared.backend.lock().unwrap().persistent_stop_fault = None;
    lane.close();
}

#[test]
fn ap04_aw21_new_event_supersedes_retry_and_request_healing_makes_it_inert() {
    let lane = PolicyLane::start(&[ALPHA]);
    assert_eq!(lane.scene(ALPHA, true).wait(), Ok(()));
    fail_stop(&lane.shared, "old generation [g13]", false);
    let (old, old_attempt) = retry_parts(lane.output(), 500, 1);
    fail_stop(&lane.shared, "new generation [g37]", false);
    let (new, new_attempt) = retry_parts(lane.output(), 500, 1);
    assert_ne!(old, new);
    let stops = lane.shared.count(|m| matches!(m, Mark::Stop(_)));
    assert_eq!(lane.retry(old, old_attempt), RestartAction::Done);
    assert_eq!(lane.shared.count(|m| matches!(m, Mark::Stop(_))), stops);
    assert_eq!(lane.shared.starts().len(), 1);
    assert_eq!(lane.scene(ALPHA, true).wait(), Ok(()));
    assert_eq!(lane.prune().wait(), Ok(()));
    assert!(lane.shared.latest_snapshot().healthy);
    let starts = lane.shared.starts().len();
    let stops = lane.shared.count(|m| matches!(m, Mark::Stop(_)));
    assert_eq!(lane.retry(new, new_attempt), RestartAction::Done);
    assert_eq!(lane.shared.starts().len(), starts);
    assert_eq!(lane.shared.count(|m| matches!(m, Mark::Stop(_))), stops);

    fail_stop(&lane.shared, "demand heals [g59]", false);
    let (generation, attempt) = retry_parts(lane.output(), 500, 1);
    assert_eq!(lane.demand(external()).wait(), Ok(()));
    assert!(lane.shared.latest_snapshot().healthy);
    let starts = lane.shared.starts().len();
    assert_eq!(lane.retry(generation, attempt), RestartAction::Done);
    assert_eq!(lane.shared.starts().len(), starts);
    assert_eq!(lane.shared.permission_requests(), 0);
    assert_no_overlap(&lane.shared);
    lane.close();
}

#[test]
fn ap04_aw21_noncapturing_event_advances_generation() {
    let lane = PolicyLane::start(&[]);
    assert_eq!(lane.output(), RestartAction::Done);
    assert_eq!(lane.demand(external()).wait(), Ok(()));
    fail_stop(&lane.shared, "first wanted failure [n11]", false);
    let (old, attempt) = retry_parts(lane.output(), 500, 1);
    assert_eq!(lane.demand(suspended()).wait(), Ok(()));
    assert_eq!(lane.output(), RestartAction::Done); // no healthy or wanted capture
    assert_eq!(lane.demand(external()).wait(), Ok(()));
    fail_stop(&lane.shared, "must remain pending [n23]", false);
    // A normal demand mutation fails both synchronization and rollback, leaving
    // wanted pending cleanup WITHOUT generating a newer device event.
    fail_stop(&lane.shared, "rollback must remain pending [n47]", false);
    assert!(lane.demand(suspended()).wait().is_err());
    assert!(lane.shared.latest_snapshot().cleanup);
    let starts = lane.shared.starts().len();
    let stops = lane.shared.count(|m| matches!(m, Mark::Stop(_)));
    assert_eq!(lane.retry(old, attempt), RestartAction::Done);
    assert_eq!(lane.shared.starts().len(), starts);
    assert_eq!(lane.shared.count(|m| matches!(m, Mark::Stop(_))), stops);
    lane.close();
}

#[test]
fn ap04_aw21_unwanted_retry_cleans_without_replacement() {
    let lane = PolicyLane::start(&[ALPHA]);
    assert_eq!(lane.scene(ALPHA, true).wait(), Ok(()));
    fail_stop(&lane.shared, "event partial [u11]", false);
    let (generation, attempt) = retry_parts(lane.output(), 500, 1);
    // Disable commits its removal even when closing residual resources fails.
    // Retention before disable must leave the pending session for this selected
    // operation, so keep failing until the request has replied.
    lane.shared.backend.lock().unwrap().persistent_stop_fault = Some(StopFault {
        text: "unwanted cleanup [u29]".to_owned(),
        still_running: false,
    });
    lane.io.set_live(&[]);
    assert!(lane.prune().wait().is_err());
    let state = lane.shared.latest_snapshot();
    assert_eq!(
        (state.owners, state.wanted, state.cleanup),
        (0, false, true)
    );
    lane.shared.backend.lock().unwrap().persistent_stop_fault = None;
    let starts = lane.shared.starts().len();
    let stops = lane.shared.count(|m| matches!(m, Mark::Stop(_)));
    assert_eq!(lane.retry(generation, attempt), RestartAction::Done);
    let state = lane.shared.latest_snapshot();
    assert_eq!(
        (state.wanted, state.healthy, state.cleanup, state.session),
        (false, false, false, None)
    );
    assert_eq!(lane.shared.starts().len(), starts);
    assert_eq!(lane.shared.count(|m| matches!(m, Mark::Stop(_))), stops + 1);
    assert_eq!(lane.shared.permission_requests(), 0);
    lane.close();
}

#[test]
fn ap05_scheduler_posts_actual_retry_to_actual_policy_and_preserves_mapping() {
    let lane = PolicyLane::start(&[]);
    assert_eq!(lane.demand(external()).wait(), Ok(()));
    fail_stop(&lane.shared, "scheduler seed [s13]", false);
    let (generation, attempt) = retry_parts(lane.output(), 500, 1);
    fail_stop(&lane.shared, "scheduled attempt [s31]", false);
    let next = lane.shared.count(|m| *m == Mark::End("retry")) + 1;
    schedule_audio_restart(
        RestartAction::RetryIn {
            delay: Duration::ZERO,
            generation,
            attempt,
        },
        &lane.owner.mailbox().events(),
    );
    lane.shared.wait_count(|m| *m == Mark::End("retry"), next);
    let (next_generation, next_attempt) = retry_parts(lane.io.action(), 1000, 2);
    assert_eq!(next_generation, generation);
    assert_eq!(lane.shared.starts().len(), 1);
    fail_stop(&lane.shared, "second scheduled attempt [s47]", false);
    let next = lane.shared.count(|m| *m == Mark::End("retry")) + 1;
    schedule_audio_restart(
        RestartAction::RetryIn {
            delay: Duration::ZERO,
            generation: next_generation,
            attempt: next_attempt,
        },
        &lane.owner.mailbox().events(),
    );
    lane.shared.wait_count(|m| *m == Mark::End("retry"), next);
    let (last_generation, last_attempt) = retry_parts(lane.io.action(), 1500, 3);
    assert_eq!(last_generation, generation);
    assert_eq!(lane.shared.starts().len(), 1);
    assert_eq!(
        lane.retry(last_generation, last_attempt),
        RestartAction::Done
    );
    assert_eq!(lane.shared.starts().len(), 2);
    let retries = lane.shared.count(|m| matches!(m, Mark::Retry(_, _)));
    schedule_audio_restart(RestartAction::Done, &lane.owner.mailbox().events());
    schedule_audio_restart(RestartAction::GaveUp, &lane.owner.mailbox().events());
    assert_eq!(lane.prune().wait(), Ok(()));
    assert_eq!(
        lane.shared.count(|m| matches!(m, Mark::Retry(_, _))),
        retries
    );
    assert_no_overlap(&lane.shared);
    lane.close(); // bounded worker-disposal signal, not an echo-hook assertion
}

#[test]
fn ap06_aw22_watch_gate_edges_and_failure_sync_precede_reply() {
    let lane = PolicyLane::start(&[]);
    lane.shared.controls.lock().unwrap().watch_unavailable = true;
    assert_eq!(lane.demand(external()).wait(), Ok(()));
    assert_eq!(lane.io.watch_attempts.load(Ordering::SeqCst), 1);
    assert_eq!(lane.io.watching.load(Ordering::SeqCst), 0);
    lane.shared.controls.lock().unwrap().watch_unavailable = false;
    assert_eq!(lane.prune().wait(), Ok(()));
    assert_eq!(lane.io.watch_attempts.load(Ordering::SeqCst), 1);
    assert_eq!(lane.demand(suspended()).wait(), Ok(()));
    assert_eq!(lane.demand(external()).wait(), Ok(()));
    assert_eq!(lane.io.watch_attempts.load(Ordering::SeqCst), 2);
    assert_eq!(lane.io.watching.load(Ordering::SeqCst), 1);

    // Selected operation failure: demand rollback restores wanted=true.
    fail_stop(&lane.shared, "selected demand failure [w17]", true);
    let gate = HeldGate::new();
    lane.shared.controls.lock().unwrap().watch = Some(gate.0.clone());
    let before = lane.shared.count(|m| matches!(m, Mark::Watch { .. }));
    let mut selected = lane.demand(suspended());
    gate.wait_entered();
    selected.assert_pending();
    assert_eq!(
        lane.shared.count(|m| matches!(m, Mark::Watch { .. })),
        before + 1
    );
    assert!(matches!(
        lane.shared.marks().last(),
        Some(Mark::Watch { wanted: true, .. })
    ));
    assert_eq!(lane.io.watching.load(Ordering::SeqCst), 1);
    gate.release();
    assert!(
        selected
            .wait()
            .unwrap_err()
            .contains("selected demand failure [w17]")
    );
    assert_eq!(lane.io.watch_attempts.load(Ordering::SeqCst), 2);
    lane.close();
}

#[test]
fn ap06_aw22_prune_failure_syncs_false_and_finish_orders_disposal() {
    let lane = PolicyLane::start(&[ALPHA]);
    assert_eq!(lane.scene(ALPHA, true).wait(), Ok(()));
    assert_eq!(lane.io.watching.load(Ordering::SeqCst), 1);
    lane.io.set_live(&[]);
    fail_stop(&lane.shared, "prune close failure [w43]", false);
    let gate = HeldGate::new();
    lane.shared.controls.lock().unwrap().watch = Some(gate.0.clone());
    let mut request = lane.prune();
    gate.wait_entered();
    request.assert_pending();
    assert_eq!(lane.io.watching.load(Ordering::SeqCst), 0);
    assert_eq!(lane.io.watch_drops.load(Ordering::SeqCst), 1);
    assert_eq!(lane.shared.latest_snapshot().owners, 0);
    gate.release();
    assert!(
        request
            .wait()
            .unwrap_err()
            .contains("prune close failure [w43]")
    );
    assert_eq!(lane.demand(external()).wait(), Ok(()));
    let mailbox = lane.owner.mailbox().clone();
    let events = mailbox.events();
    let shared = lane.shared.clone();
    let io = lane.io.clone();
    lane.close();
    assert_eq!(io.watch_drops.load(Ordering::SeqCst), 2);
    let marks = shared.marks();
    let last_watch = marks
        .iter()
        .rposition(|m| *m == Mark::WatchStopped)
        .unwrap();
    let last_stop = marks
        .iter()
        .rposition(|m| matches!(m, Mark::Stop(_)))
        .unwrap();
    let backend = position(&marks, |m| matches!(m, Mark::BackendDropped { .. }));
    assert!(last_watch < last_stop && last_stop < backend);
    events.output_changed();
    events.retry_restart(7, 1);
    assert!(
        Driven::new(async move { mailbox.prune_scenes().await })
            .wait()
            .is_err()
    );
    assert_eq!(shared.count(|m| *m == Mark::Begin("initialize")), 1);
}

#[test]
fn ap07_aw23_actual_owner_clones_and_unpolled_future_control_lifetime() {
    let lane = PolicyLane::start(&[]);
    assert_eq!(lane.demand(external()).wait(), Ok(()));
    let PolicyLane {
        owner,
        shared,
        io: _,
        terminated,
    } = lane;
    let mailbox = owner.mailbox().clone();
    let events = mailbox.events();
    drop(owner.clone());
    let other = owner.clone();
    drop(owner);
    let probe_owner = other.clone();
    assert_eq!(
        Driven::new(async move { probe_owner.mailbox().prune_scenes().await }).wait(),
        Ok(())
    );
    let request_owner = other.clone();
    let unpolled = Box::pin(async move { request_owner.mailbox().prune_scenes().await });
    drop(other);
    // A successful real request establishes positive liveness while only the
    // unpolled future owns the guard; transport itself does not own it.
    let probe = mailbox.clone();
    assert_eq!(
        Driven::new(async move { probe.prune_scenes().await }).wait(),
        Ok(())
    );
    assert_eq!(
        shared.count(|m| matches!(m, Mark::BackendDropped { .. })),
        0
    );
    assert!(matches!(
        terminated.try_recv(),
        Err(mpsc::TryRecvError::Empty)
    ));
    let (release, wait) = mpsc::channel();
    let delayed = events.clone();
    let join = thread::spawn(move || {
        wait.recv_timeout(LIMIT)
            .expect("late-event release missing");
        delayed.output_changed();
        delayed.retry_restart(8, 0);
    });
    drop(unpolled);
    terminated
        .recv_timeout(LIMIT)
        .expect("unpolled future drop did not release final real owner");
    assert_eq!(
        shared.count(|m| matches!(m, Mark::BackendDropped { .. })),
        1
    );
    release.send(()).unwrap();
    join.join().expect("late poster panicked");
    assert!(
        Driven::new(async move { mailbox.prune_scenes().await })
            .wait()
            .is_err()
    );
    assert_eq!(shared.count(|m| *m == Mark::Begin("initialize")), 1);
    shared.assert_serial_worker();
}

#[test]
fn ap07_aw23_pending_future_drop_and_completion_both_release_final_owner() {
    for abandon in [true, false] {
        let lane = PolicyLane::start(&[]);
        assert_eq!(lane.demand(external()).wait(), Ok(()));
        let gate = HeldGate::new();
        lane.shared.controls.lock().unwrap().before_retain = Some(gate.0.clone());
        let PolicyLane {
            owner,
            shared,
            io: _,
            terminated,
        } = lane;
        let mailbox = owner.mailbox().clone();
        let events = mailbox.events();
        let request_owner = owner.clone();
        let mut request =
            Driven::new(async move { request_owner.mailbox().update_demand(suspended()).await });
        gate.wait_entered();
        request.assert_pending();
        drop(owner);
        assert_eq!(
            shared.count(|m| matches!(m, Mark::BackendDropped { .. })),
            0
        );
        assert!(matches!(
            terminated.try_recv(),
            Err(mpsc::TryRecvError::Empty)
        ));
        if abandon {
            drop(request); // posts Finish behind the already admitted operation
            gate.release();
        } else {
            gate.release();
            // The request was proven Pending above and has not been repolled.
            // Positive lane liveness after it has replied distinguishes real
            // future ownership from a gate merely preventing premature Finish.
            let probe = mailbox.clone();
            assert_eq!(
                Driven::new(async move { probe.prune_scenes().await }).wait(),
                Ok(())
            );
            assert_eq!(
                shared.count(|m| matches!(m, Mark::BackendDropped { .. })),
                0
            );
            assert_eq!(request.wait(), Ok(()));
        }
        terminated
            .recv_timeout(LIMIT)
            .expect("pending request retained final owner forever");
        assert_eq!(shared.count(|m| *m == Mark::Demand(suspended())), 1);
        let state = shared.latest_snapshot();
        assert_eq!((state.wanted, state.healthy), (false, false));
        assert_eq!(
            shared.count(|m| matches!(m, Mark::BackendDropped { .. })),
            1
        );
        events.output_changed();
        events.retry_restart(9, 2);
        assert!(
            Driven::new(async move { mailbox.prune_scenes().await })
                .wait()
                .is_err()
        );
        shared.assert_serial_worker();
    }
}

async fn bounded<F: Future>(future: F) -> F::Output {
    tokio::time::timeout(LIMIT, future)
        .await
        .expect("controlled async operation exceeded bound")
}

#[tokio::test]
async fn ap08_aw24_fm02_real_envelope_excludes_capture_across_core_and_fresh_prune() {
    let lane = PolicyLane::start(&[ALPHA, BETA]);
    assert_eq!(lane.scene(ALPHA, true).wait(), Ok(()));
    assert_eq!(lane.scene(BETA, true).wait(), Ok(()));
    let exclusion = tokio::sync::Mutex::new(());
    let (core_entered, core_seen) = oneshot::channel();
    let (release_core, core_release) = oneshot::channel();
    let prune_gate = HeldGate::new();
    lane.shared.controls.lock().unwrap().before_retain = Some(prune_gate.0.clone());
    let io = lane.io.clone();
    let prune_owner = lane.owner.clone();
    let mut scenes = Box::pin(mutate_scenes_and_prune(
        &exclusion,
        || async move {
            core_entered.send(()).unwrap();
            core_release.await.unwrap();
            // A failed core operation nevertheless published a partial result.
            *io.reading.lock().unwrap() = vec![display(19, Some(BETA)), display(29, None)];
            Err::<Option<u64>, _>(EngineError::Render("partial core [e17]".to_owned()))
        },
        || async move { prune_owner.mailbox().prune_scenes().await },
    ));
    assert!(futures_util::poll!(scenes.as_mut()).is_pending());
    bounded(core_seen).await.unwrap();
    let entered_capture = Arc::new(AtomicUsize::new(0));
    let entered = entered_capture.clone();
    let capture_owner = lane.owner.clone();
    let mut capture = Box::pin(mutate_audio(&exclusion, || {
        entered.fetch_add(1, Ordering::SeqCst);
        async move { capture_owner.mailbox().update_demand(external()).await }
    }));
    assert!(futures_util::poll!(capture.as_mut()).is_pending());
    assert_eq!(entered_capture.load(Ordering::SeqCst), 0);
    release_core.send(()).unwrap();
    assert!(futures_util::poll!(scenes.as_mut()).is_pending());
    prune_gate.wait_entered();
    assert!(futures_util::poll!(capture.as_mut()).is_pending());
    assert_eq!(entered_capture.load(Ordering::SeqCst), 0);
    prune_gate.release();
    match bounded(scenes).await {
        Err(EngineError::Render(text)) => assert_eq!(text, "partial core [e17]"),
        other => panic!("core error was not preserved: {other:?}"),
    }
    assert_eq!(lane.shared.latest_snapshot().owners, 1);
    assert_eq!(
        lane.io.samples.lock().unwrap().last().unwrap(),
        &vec![handle(BETA)]
    );
    assert!(bounded(capture).await.is_ok());
    assert_eq!(entered_capture.load(Ordering::SeqCst), 1);
    assert_eq!(lane.shared.latest_snapshot().owners, 1);
    assert_eq!(lane.scene(BETA, false).wait(), Ok(()));
    assert_eq!(lane.prune().wait(), Ok(()));
    let state = lane.shared.latest_snapshot();
    assert_eq!((state.owners, state.wanted, state.healthy), (0, true, true));
    assert_eq!(lane.shared.starts().len(), 1);
    lane.close();
}

#[tokio::test]
async fn ap08_aw24_core_prune_result_matrix_uses_actual_controller_failures() {
    for core_fails in [false, true] {
        for prune_fails in [false, true] {
            for value in [None, Some(BETA)] {
                let lane = PolicyLane::start(&[ALPHA]);
                assert_eq!(lane.scene(ALPHA, true).wait(), Ok(()));
                let exclusion = tokio::sync::Mutex::new(());
                let io = lane.io.clone();
                let shared = lane.shared.clone();
                let owner = lane.owner.clone();
                let result = bounded(mutate_scenes_and_prune(
                    &exclusion,
                    || async move {
                        io.set_live(&[]);
                        if prune_fails {
                            fail_stop(&shared, "matrix prune [m31]", false);
                        }
                        if core_fails {
                            Err(EngineError::Crash("matrix core [m17]".to_owned()))
                        } else {
                            Ok(value)
                        }
                    },
                    || async move { owner.mailbox().prune_scenes().await },
                ))
                .await;
                match result {
                    Err(EngineError::Platform(text)) if prune_fails => {
                        assert!(text.contains("matrix prune [m31]"))
                    }
                    Err(EngineError::Crash(text)) if core_fails && !prune_fails => {
                        assert_eq!(text, "matrix core [m17]")
                    }
                    Ok(actual) if !core_fails && !prune_fails => assert_eq!(actual, value),
                    other => panic!("wrong core/prune precedence: {other:?}"),
                }
                let state = lane.shared.latest_snapshot();
                assert_eq!((state.owners, state.wanted), (0, false));
                assert_eq!(state.cleanup, prune_fails);
                assert_eq!(lane.prune().wait(), Ok(()));
                assert!(!lane.shared.latest_snapshot().cleanup);
                lane.close();
            }
        }
    }
}

#[tokio::test]
async fn ap08_aw24_unit_value_and_surviving_owner_after_failed_cleanup() {
    let lane = PolicyLane::start(&[ALPHA, BETA]);
    assert_eq!(lane.scene(ALPHA, true).wait(), Ok(()));
    assert_eq!(lane.scene(BETA, true).wait(), Ok(()));
    fail_stop(&lane.shared, "initial partial teardown [v13]", false);
    let _pending = retry_parts(lane.output(), 500, 1);
    let exclusion = tokio::sync::Mutex::new(());
    let shared = lane.shared.clone();
    let io = lane.io.clone();
    let owner = lane.owner.clone();
    let result = bounded(mutate_scenes_and_prune(
        &exclusion,
        || async move {
            io.set_live(&[BETA]);
            fail_stop(&shared, "survivor cleanup [v37]", false);
            Ok(())
        },
        || async move { owner.mailbox().prune_scenes().await },
    ))
    .await;
    match result {
        Err(EngineError::Platform(text)) => assert!(text.contains("survivor cleanup [v37]")),
        other => panic!("expected real retention failure: {other:?}"),
    }
    let state = lane.shared.latest_snapshot();
    assert_eq!(
        (state.owners, state.wanted, state.healthy, state.cleanup),
        (1, true, false, true)
    );
    let owner = lane.owner.clone();
    assert!(
        bounded(mutate_scenes_and_prune(
            &exclusion,
            || async { Ok(()) },
            || async move { owner.mailbox().prune_scenes().await },
        ))
        .await
        .is_ok()
    );
    let state = lane.shared.latest_snapshot();
    assert_eq!(
        (state.owners, state.wanted, state.healthy, state.cleanup),
        (1, true, true, false)
    );
    assert_eq!(
        lane.io.samples.lock().unwrap().last().unwrap(),
        &vec![handle(BETA)]
    );
    assert_eq!(lane.scene(BETA, false).wait(), Ok(()));
    assert_eq!(lane.prune().wait(), Ok(()));
    assert_eq!(lane.shared.latest_snapshot().owners, 0);
    assert!(!lane.shared.latest_snapshot().wanted); // absent ALPHA did not return
    assert_no_overlap(&lane.shared);
    lane.close();
}
