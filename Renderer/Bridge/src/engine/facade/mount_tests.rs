//! Device-free tests of the actual parent sequencing capabilities.
//! No native engine, callback-registration slot, or facade is constructed here.
use super::{mutate_audio, mutate_scenes_and_prune, reconcile_with_readiness};
use crate::engine::{displays_awaiting_first_frame, facade_readiness::FirstFrameReadiness};
use std::{
    future::Future,
    pin::Pin,
    sync::{Arc, Mutex as StdMutex},
    task::{Context, Poll},
    time::Duration,
};
use tokio::sync::{Mutex, oneshot};
use wallpaper_core::project::{SceneDesc, SceneHandle, SceneResult, SceneTemplate};
use wallpaper_core::{
    DisplayDesc, DisplayIdentity, DisplaySnapshotEntry, EngineError, FirstFrameCallback,
    WallpaperAssignment,
};

const GRACE: Duration = Duration::from_secs(90);

fn step<F: Future>(future: Pin<&mut F>) -> Poll<F::Output> {
    future.poll(&mut Context::from_waker(
        futures_util::task::noop_waker_ref(),
    ))
}
fn pending<F: Future>(future: Pin<&mut F>) {
    assert!(step(future).is_pending());
}
fn completed<F: Future>(future: Pin<&mut F>) -> F::Output {
    match step(future) {
        Poll::Ready(value) => value,
        Poll::Pending => panic!("operation unexpectedly pending"),
    }
}
fn scene(id: u32, name: &str) -> SceneDesc {
    SceneDesc::new(
        DisplayDesc::new(id, -73, 19, 1440, 900, 1.5),
        name,
        "mount-assets-independent",
        47,
        false,
    )
}
fn live(scene: &SceneDesc, handle: Option<SceneHandle>) -> DisplaySnapshotEntry {
    DisplaySnapshotEntry {
        identity: DisplayIdentity::default(),
        desc: scene.display.clone(),
        handle,
        accepts_pointer_input: true,
        paused: scene.paused,
        window_active: false,
        assignment: Some(WallpaperAssignment::Direct(SceneTemplate::from_scene_desc(
            scene,
        ))),
    }
}
fn result(id: u32, raw: u64, status: i32) -> SceneResult {
    SceneResult::new(id, SceneHandle::new(raw), status)
}
fn observer() -> (
    FirstFrameReadiness,
    FirstFrameCallback,
    Arc<StdMutex<Vec<SceneHandle>>>,
) {
    let readiness = FirstFrameReadiness::new();
    let forwarded = Arc::new(StdMutex::new(Vec::new()));
    let sink = forwarded.clone();
    let callback =
        readiness.wrap_callback(Arc::new(move |handle| sink.lock().unwrap().push(handle)));
    (readiness, callback, forwarded)
}
fn render_error<T: std::fmt::Debug>(value: Result<T, EngineError>) {
    assert!(matches!(value, Err(EngineError::Render(_))), "{value:?}");
}

#[tokio::test(flavor = "current_thread", start_paused = true)]
async fn fm01_reconcile_four_way_precedence_and_failure_forwarding() {
    for core_fails in [false, true] {
        for prune_fails in [false, true] {
            let turn = Mutex::new(());
            let audio = Mutex::new(());
            let (readiness, callback, forwarded) = observer();
            let wanted = result(31, 0x917, -23);
            let trace = Arc::new(StdMutex::new(Vec::new()));
            let (core_tx, core_rx) = oneshot::channel::<()>();
            let (prune_tx, prune_rx) = oneshot::channel::<()>();
            let core_trace = trace.clone();
            let prune_trace = trace.clone();
            let mut operation = Box::pin(reconcile_with_readiness(
                &turn,
                &audio,
                &readiness,
                vec![scene(31, "matrix-wallpaper")],
                Default::default,
                move |_| async move {
                    core_trace.lock().unwrap().push("core-enter");
                    core_rx.await.unwrap();
                    core_trace.lock().unwrap().push("core-exit");
                    if core_fails {
                        Err(EngineError::Crash("matrix-core-271".into()))
                    } else {
                        Ok(vec![wanted])
                    }
                },
                move || async move {
                    prune_trace.lock().unwrap().push("prune-enter");
                    prune_rx.await.unwrap();
                    prune_trace.lock().unwrap().push("prune-exit");
                    if prune_fails {
                        Err("matrix-prune-683".into())
                    } else {
                        Ok(())
                    }
                },
            ));
            pending(operation.as_mut());
            assert_eq!(*trace.lock().unwrap(), ["core-enter"]);
            core_tx.send(()).unwrap();
            pending(operation.as_mut());
            assert_eq!(
                *trace.lock().unwrap(),
                ["core-enter", "core-exit", "prune-enter"]
            );
            // Failed operations must still forward evidence, including evidence whose
            // handle is unrelated to their requested display.
            if core_fails || prune_fails {
                callback(SceneHandle::new(0xBA31));
            }
            prune_tx.send(()).unwrap();
            if core_fails || prune_fails {
                let outcome = completed(operation.as_mut());
                match outcome {
                    Err(EngineError::Platform(payload)) if prune_fails => {
                        assert_eq!(payload, "matrix-prune-683")
                    }
                    Err(EngineError::Crash(payload)) if core_fails => {
                        assert_eq!(payload, "matrix-core-271")
                    }
                    other => panic!("wrong precedence: {other:?}"),
                }
                assert_eq!(*forwarded.lock().unwrap(), [SceneHandle::new(0xBA31)]);
            } else {
                pending(operation.as_mut());
                callback(wanted.handle);
                assert_eq!(completed(operation.as_mut()).unwrap(), vec![wanted]);
                assert_eq!(*forwarded.lock().unwrap(), [wanted.handle]);
            }
            assert_eq!(
                *trace.lock().unwrap(),
                ["core-enter", "core-exit", "prune-enter", "prune-exit"]
            );
        }
    }
}

#[tokio::test(flavor = "current_thread", start_paused = true)]
async fn fm02_partial_state_is_visible_to_prune_and_not_rolled_back() {
    let turn = Mutex::new(());
    let audio = Mutex::new(());
    let readiness = FirstFrameReadiness::new();
    let initial = live(&scene(48, "before-partial"), Some(SceneHandle::new(0xC41)));
    let changed = live(&scene(48, "after-partial"), Some(SceneHandle::new(0xF62)));
    let state = Arc::new(StdMutex::new(vec![initial.clone()]));
    let snapshot_state = state.clone();
    let core_state = state.clone();
    let prune_state = state.clone();
    let expected = changed.clone();
    let (tx, rx) = oneshot::channel::<()>();
    let mut operation = Box::pin(reconcile_with_readiness(
        &turn,
        &audio,
        &readiness,
        vec![scene(48, "after-partial")],
        move || (snapshot_state.lock().unwrap().clone(), Vec::new()),
        move |_| async move {
            assert_eq!(*core_state.lock().unwrap(), vec![initial]);
            *core_state.lock().unwrap() = vec![changed];
            rx.await.unwrap();
            Err(EngineError::Render("partial-core-394".into()))
        },
        move || async move {
            assert_eq!(*prune_state.lock().unwrap(), vec![expected]);
            Ok(())
        },
    ));
    pending(operation.as_mut());
    assert_eq!(
        *state.lock().unwrap(),
        vec![live(
            &scene(48, "after-partial"),
            Some(SceneHandle::new(0xF62))
        )]
    );
    tx.send(()).unwrap();
    match completed(operation.as_mut()) {
        Err(EngineError::Render(payload)) => assert_eq!(payload, "partial-core-394"),
        other => panic!("lost core error: {other:?}"),
    }
    assert_eq!(
        *state.lock().unwrap(),
        vec![live(
            &scene(48, "after-partial"),
            Some(SceneHandle::new(0xF62))
        )]
    );
}

#[tokio::test(flavor = "current_thread", start_paused = true)]
async fn fm03_full_post_core_post_prune_grace_and_preparation_evidence() {
    // Independently exercise no evidence, evidence during core, evidence during prune.
    for evidence_stage in [None, Some("core"), Some("prune")] {
        let turn = Mutex::new(());
        let audio = Mutex::new(());
        let (readiness, callback, forwarded) = observer();
        let expected = result(67, 0xD91, -81);
        let (core_tx, core_rx) = oneshot::channel::<()>();
        let (prune_tx, prune_rx) = oneshot::channel::<()>();
        let mut operation = Box::pin(reconcile_with_readiness(
            &turn,
            &audio,
            &readiness,
            vec![scene(67, "long-preparation")],
            Default::default,
            move |_| async move {
                core_rx.await.unwrap();
                Ok(vec![expected])
            },
            move || async move {
                prune_rx.await.unwrap();
                Ok(())
            },
        ));
        pending(operation.as_mut());
        tokio::time::advance(Duration::from_secs(137)).await;
        pending(operation.as_mut());
        if evidence_stage == Some("core") {
            callback(expected.handle);
        }
        core_tx.send(()).unwrap();
        pending(operation.as_mut());
        tokio::time::advance(Duration::from_secs(163)).await;
        pending(operation.as_mut());
        if evidence_stage == Some("prune") {
            callback(expected.handle);
        }
        prune_tx.send(()).unwrap();
        if evidence_stage.is_some() {
            assert_eq!(completed(operation.as_mut()).unwrap(), vec![expected]);
            assert_eq!(*forwarded.lock().unwrap(), [expected.handle]);
        } else {
            pending(operation.as_mut());
            tokio::time::advance(GRACE - Duration::from_millis(1)).await;
            pending(operation.as_mut());
            tokio::time::advance(Duration::from_millis(1)).await;
            render_error(completed(operation.as_mut()));
        }
    }
}

#[tokio::test(flavor = "current_thread", start_paused = true)]
async fn fm03_multiple_targets_share_original_deadline_and_preserve_results() {
    for finish_all in [false, true] {
        let turn = Mutex::new(());
        let audio = Mutex::new(());
        let (readiness, callback, _) = observer();
        let first = result(83, 0x81B, -12);
        let second = result(79, 0xA29, 43);
        let mut operation = Box::pin(reconcile_with_readiness(
            &turn,
            &audio,
            &readiness,
            vec![scene(79, "second-target"), scene(83, "first-target")],
            Default::default,
            move |_| async move { Ok(vec![first, second]) },
            || async { Ok(()) },
        ));
        pending(operation.as_mut());
        tokio::time::advance(Duration::from_secs(89)).await;
        callback(first.handle);
        pending(operation.as_mut());
        if finish_all {
            callback(second.handle);
            assert_eq!(completed(operation.as_mut()).unwrap(), vec![first, second]);
        } else {
            tokio::time::advance(Duration::from_secs(1)).await;
            render_error(completed(operation.as_mut()));
        }
    }
}

#[tokio::test(flavor = "current_thread", start_paused = true)]
async fn fm04_shared_turn_excludes_snapshot_core_and_stale_handle_evidence() {
    let turn = Arc::new(Mutex::new(()));
    let audio = Arc::new(Mutex::new(()));
    let (readiness, callback, forwarded) = observer();
    let clone_readiness = readiness.clone();
    let second_turn = turn.clone();
    let second_audio = audio.clone();
    let trace = Arc::new(StdMutex::new(Vec::new()));
    let a_trace = trace.clone();
    let b_snapshot = trace.clone();
    let b_core = trace.clone();
    let a = result(91, 0x931, 17);
    let b = result(92, 0x931, -29); // Deliberate handle reuse, not guessed numbering.
    let mut first = Box::pin(reconcile_with_readiness(
        &turn,
        &audio,
        &readiness,
        vec![scene(91, "turn-a")],
        move || {
            a_trace.lock().unwrap().push("a-snapshot");
            Default::default()
        },
        move |_| async move { Ok(vec![a]) },
        || async { Ok(()) },
    ));
    let mut second = Box::pin(reconcile_with_readiness(
        &second_turn,
        &second_audio,
        &clone_readiness,
        vec![scene(92, "turn-b")],
        move || {
            b_snapshot.lock().unwrap().push("b-snapshot");
            Default::default()
        },
        move |_| async move {
            b_core.lock().unwrap().push("b-core");
            Ok(vec![b])
        },
        || async { Ok(()) },
    ));
    pending(first.as_mut());
    pending(second.as_mut());
    assert_eq!(*trace.lock().unwrap(), ["a-snapshot"]);
    callback(a.handle);
    pending(second.as_mut());
    assert_eq!(*trace.lock().unwrap(), ["a-snapshot"]);
    assert_eq!(completed(first.as_mut()).unwrap(), vec![a]);
    pending(second.as_mut());
    assert_eq!(
        *trace.lock().unwrap(),
        ["a-snapshot", "b-snapshot", "b-core"]
    );
    tokio::time::advance(Duration::from_secs(89)).await;
    pending(second.as_mut());
    callback(b.handle);
    assert_eq!(completed(second.as_mut()).unwrap(), vec![b]);
    assert_eq!(*forwarded.lock().unwrap(), [a.handle, b.handle]);
}

#[tokio::test(flavor = "current_thread", start_paused = true)]
async fn fm05_audio_blocked_through_core_and_prune_but_released_for_readiness() {
    let turn = Mutex::new(());
    let audio = Mutex::new(());
    let (readiness, callback, _) = observer();
    let wanted = result(107, 0x711, 8);
    let (core_tx, core_rx) = oneshot::channel::<()>();
    let (prune_tx, prune_rx) = oneshot::channel::<()>();
    let mut operation = Box::pin(reconcile_with_readiness(
        &turn,
        &audio,
        &readiness,
        vec![scene(107, "audio-boundary")],
        Default::default,
        move |_| async move {
            core_rx.await.unwrap();
            Ok(vec![wanted])
        },
        move || async move {
            prune_rx.await.unwrap();
            Ok(())
        },
    ));
    let enabled = StdMutex::new(false);
    let demand = StdMutex::new(0_u32);
    let mut enable = Box::pin(mutate_audio(&audio, || async {
        *enabled.lock().unwrap() = true;
        Ok(())
    }));
    let mut set_demand = Box::pin(mutate_audio(&audio, || async {
        *demand.lock().unwrap() = 73;
        Ok(73_u32)
    }));
    pending(operation.as_mut());
    pending(enable.as_mut());
    pending(set_demand.as_mut());
    assert!(!*enabled.lock().unwrap());
    assert_eq!(*demand.lock().unwrap(), 0);
    core_tx.send(()).unwrap();
    pending(operation.as_mut());
    pending(enable.as_mut());
    pending(set_demand.as_mut());
    assert!(!*enabled.lock().unwrap());
    assert_eq!(*demand.lock().unwrap(), 0);
    prune_tx.send(()).unwrap();
    pending(operation.as_mut());
    assert_eq!(completed(enable.as_mut()).unwrap(), ());
    assert_eq!(completed(set_demand.as_mut()).unwrap(), 73);
    assert!(*enabled.lock().unwrap());
    assert_eq!(*demand.lock().unwrap(), 73);
    pending(operation.as_mut());
    callback(wanted.handle);
    assert_eq!(completed(operation.as_mut()).unwrap(), vec![wanted]);
    let mut failure = Box::pin(mutate_audio(&audio, || async {
        Err::<(), String>("capture-boundary-822".into())
    }));
    match completed(failure.as_mut()) {
        Err(EngineError::Platform(payload)) => assert_eq!(payload, "capture-boundary-822"),
        other => panic!("capture error mapping: {other:?}"),
    }
}

#[tokio::test(flavor = "current_thread", start_paused = true)]
async fn fm05_scene_capability_unit_option_shapes_and_error_precedence() {
    for core_fails in [false, true] {
        for prune_fails in [false, true] {
            let audio = Mutex::new(());
            let partial = StdMutex::new(11_u32);
            let (core_tx, core_rx) = oneshot::channel::<()>();
            let (prune_tx, prune_rx) = oneshot::channel::<()>();
            let mut operation = Box::pin(mutate_scenes_and_prune(
                &audio,
                || async {
                    *partial.lock().unwrap() = 64;
                    core_rx.await.unwrap();
                    if core_fails {
                        Err(EngineError::InvalidInput("scene-core-624".into()))
                    } else {
                        Ok(())
                    }
                },
                || async {
                    assert_eq!(*partial.lock().unwrap(), 64);
                    prune_rx.await.unwrap();
                    if prune_fails {
                        Err("scene-prune-905".into())
                    } else {
                        Ok(())
                    }
                },
            ));
            let captured = StdMutex::new(false);
            let mut capture = Box::pin(mutate_audio(&audio, || async {
                *captured.lock().unwrap() = true;
                Ok(())
            }));
            pending(operation.as_mut());
            pending(capture.as_mut());
            core_tx.send(()).unwrap();
            pending(operation.as_mut());
            pending(capture.as_mut());
            assert!(!*captured.lock().unwrap());
            prune_tx.send(()).unwrap();
            match completed(operation.as_mut()) {
                Err(EngineError::Platform(payload)) if prune_fails => {
                    assert_eq!(payload, "scene-prune-905")
                }
                Err(EngineError::InvalidInput(payload)) if core_fails => {
                    assert_eq!(payload, "scene-core-624")
                }
                Ok(()) if !core_fails && !prune_fails => assert_eq!(*partial.lock().unwrap(), 64),
                other => panic!("scene precedence: {other:?}"),
            }
            completed(capture.as_mut()).unwrap();
            assert!(*captured.lock().unwrap());
            assert_eq!(*partial.lock().unwrap(), 64);
        }
    }
    let audio = Mutex::new(());
    for expected in [Some(SceneHandle::new(0xB72)), None] {
        let observed = StdMutex::new(None);
        let mut operation = Box::pin(mutate_scenes_and_prune(
            &audio,
            || async {
                *observed.lock().unwrap() = Some(expected);
                Ok(expected)
            },
            || async {
                assert_eq!(*observed.lock().unwrap(), Some(expected));
                Ok(())
            },
        ));
        assert_eq!(completed(operation.as_mut()).unwrap(), expected);
    }
}

#[tokio::test(flavor = "current_thread", start_paused = true)]
async fn fm07_real_retained_predicate_and_mounted_readiness_agree() {
    let base = scene(126, "retained-independent");
    let existing_handle = SceneHandle::new(0xC51);
    // Each entry is a fresh genuine descriptor, not a wallpaper comparison model.
    let mut geometry = base.clone();
    geometry.display.x = 311;
    geometry.display.y = -129;
    geometry.display.width = 1728;
    geometry.display.height = 1117;
    geometry.display.scale_factor = 2.0;
    let mut refresh_rate = base.clone();
    refresh_rate.display.refresh_rate_hz = 119;
    let mut paused = base.clone();
    paused.paused = true;
    let mut consumed = base.clone();
    consumed.force_shader_refresh = true;
    let mut changed = base.clone();
    changed.scene_path = "retained-different-wallpaper".into();
    let mut explicit_refresh = base.clone();
    explicit_refresh.force_shader_refresh = true;
    let cases = vec![
        (
            "geometry",
            vec![live(&base, Some(existing_handle))],
            geometry,
            false,
        ),
        (
            "refresh-rate",
            vec![live(&base, Some(existing_handle))],
            refresh_rate,
            false,
        ),
        (
            "paused",
            vec![live(&base, Some(existing_handle))],
            paused,
            false,
        ),
        (
            "consumed-refresh",
            vec![live(&consumed, Some(existing_handle))],
            base.clone(),
            false,
        ),
        ("missing-display", vec![], base.clone(), true),
        (
            "missing-handle",
            vec![live(&base, None)],
            base.clone(),
            true,
        ),
        (
            "changed-wallpaper",
            vec![live(&base, Some(existing_handle))],
            changed,
            true,
        ),
        (
            "explicit-refresh",
            vec![live(&base, Some(existing_handle))],
            explicit_refresh,
            true,
        ),
    ];
    for (label, baseline, requested, needs_frame) in cases {
        let expected_ids = if needs_frame { vec![126] } else { vec![] };
        assert_eq!(
            displays_awaiting_first_frame(&baseline, &[], &[requested.clone()]),
            expected_ids,
            "{label}"
        );
        let turn = Mutex::new(());
        let audio = Mutex::new(());
        let (readiness, callback, _) = observer();
        let returned = result(126, 0xE68, -44);
        let expected_scene = requested.clone();
        let mut operation = Box::pin(reconcile_with_readiness(
            &turn,
            &audio,
            &readiness,
            vec![requested],
            move || (baseline, Vec::new()),
            move |scenes| async move {
                assert_eq!(scenes, vec![expected_scene]);
                Ok(vec![returned])
            },
            || async { Ok(()) },
        ));
        if needs_frame {
            pending(operation.as_mut());
            callback(returned.handle);
        }
        assert_eq!(
            completed(operation.as_mut()).unwrap(),
            vec![returned],
            "{label}"
        );
    }
}

#[tokio::test(flavor = "current_thread", start_paused = true)]
async fn fm08_dropping_owned_wait_releases_turn_without_erasing_progress() {
    let turn = Arc::new(Mutex::new(()));
    let audio = Arc::new(Mutex::new(()));
    let (readiness, callback, forwarded) = observer();
    let owner_to_drop = readiness.clone();
    let progress = Arc::new(StdMutex::new(Vec::<SceneResult>::new()));
    let core_progress = progress.clone();
    let first_result = result(143, 0xF13, -62);
    let mut owned_wait = Box::pin(reconcile_with_readiness(
        &turn,
        &audio,
        &readiness,
        vec![scene(143, "cancel-owned")],
        Default::default,
        move |_| async move {
            core_progress.lock().unwrap().push(first_result);
            Ok(vec![first_result])
        },
        || async { Ok(()) },
    ));
    pending(owned_wait.as_mut());
    assert_eq!(*progress.lock().unwrap(), vec![first_result]);
    assert!(turn.try_lock().is_err());
    drop(owner_to_drop); // Dropping one observer owner does not cancel the owned future.
    pending(owned_wait.as_mut());
    assert!(turn.try_lock().is_err());
    drop(owned_wait); // This is the actual pending future, not its Pin<&mut _> view.
    assert!(turn.try_lock().is_ok());
    assert!(audio.try_lock().is_ok());
    assert_eq!(*progress.lock().unwrap(), vec![first_result]);
    callback(first_result.handle);
    assert_eq!(*forwarded.lock().unwrap(), [first_result.handle]);
    let mut capture = Box::pin(mutate_audio(&audio, || async { Ok(29_u32) }));
    assert_eq!(completed(capture.as_mut()).unwrap(), 29);
    // A later turn must start; evidence emitted before its checkpoint is stale.
    let next_progress = progress.clone();
    let next_result = result(144, 0xF13, 35);
    let mut later = Box::pin(reconcile_with_readiness(
        &turn,
        &audio,
        &readiness,
        vec![scene(144, "after-cancel")],
        Default::default,
        move |_| async move {
            next_progress.lock().unwrap().push(next_result);
            Ok(vec![next_result])
        },
        || async { Ok(()) },
    ));
    pending(later.as_mut());
    assert_eq!(*progress.lock().unwrap(), vec![first_result, next_result]);
    callback(next_result.handle);
    assert_eq!(completed(later.as_mut()).unwrap(), vec![next_result]);
    assert_eq!(
        *forwarded.lock().unwrap(),
        [first_result.handle, next_result.handle]
    );
}

#[tokio::test(flavor = "current_thread", start_paused = true)]
async fn observer_records_before_forwarding_even_if_sink_unwinds() {
    let turn = Mutex::new(());
    let audio = Mutex::new(());
    let readiness = FirstFrameReadiness::new();
    let seen = Arc::new(StdMutex::new(Vec::new()));
    let sink_seen = seen.clone();
    let callback = readiness.wrap_callback(Arc::new(move |handle| {
        sink_seen.lock().unwrap().push(handle);
        panic!("controlled sink unwind");
    }));
    let returned = result(159, 0xAB42, -7);
    let mut operation = Box::pin(reconcile_with_readiness(
        &turn,
        &audio,
        &readiness,
        vec![scene(159, "before-forward")],
        Default::default,
        move |_| async move { Ok(vec![returned]) },
        || async { Ok(()) },
    ));
    pending(operation.as_mut());
    let unwind =
        std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| callback(returned.handle)));
    assert!(unwind.is_err());
    assert_eq!(*seen.lock().unwrap(), [returned.handle]);
    assert_eq!(completed(operation.as_mut()).unwrap(), vec![returned]);
}

#[tokio::test(flavor = "current_thread", start_paused = true)]
async fn fm05_capture_holds_exclusion_against_scene_mutation() {
    fn require_send<F: Future + Send>(future: F) -> F {
        future
    }
    let audio = Mutex::new(());
    let state = StdMutex::new(Vec::new());
    let (release, gate) = oneshot::channel::<()>();
    // These futures borrow fixture state; Send does not impose a 'static lifetime.
    let mut capture = Box::pin(require_send(mutate_audio(&audio, || async {
        state.lock().unwrap().push("capture-enter");
        gate.await.unwrap();
        state.lock().unwrap().push("capture-exit");
        Ok(())
    })));
    let wanted = Some(SceneHandle::new(0xB429));
    let mut scene_operation = Box::pin(require_send(mutate_scenes_and_prune(
        &audio,
        || async {
            state.lock().unwrap().push("scene-core");
            Ok(wanted)
        },
        || async {
            state.lock().unwrap().push("scene-prune");
            Ok(())
        },
    )));
    pending(capture.as_mut());
    pending(scene_operation.as_mut());
    assert_eq!(*state.lock().unwrap(), ["capture-enter"]);
    release.send(()).unwrap();
    completed(capture.as_mut()).unwrap();
    assert_eq!(completed(scene_operation.as_mut()).unwrap(), wanted);
    assert_eq!(
        *state.lock().unwrap(),
        ["capture-enter", "capture-exit", "scene-core", "scene-prune"]
    );
}
