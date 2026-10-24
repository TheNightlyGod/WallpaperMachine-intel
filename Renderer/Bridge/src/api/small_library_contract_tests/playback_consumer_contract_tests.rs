use super::*;

use crate::api::mounted_lifecycle::{
    ControlledEngine, EngineObservation, OperationControl, OperationPhase,
};
use crate::api::{BridgeErrorKind, BridgePlaybackState};
use crate::engine::EngineFacade;
use wallpaper_core::project::{SceneHandle, SceneTemplate};
use wallpaper_core::{
    DisplayDesc, DisplayIdentity, DisplaySnapshotEntry, EngineError, WallpaperAssignment,
};

struct ReleaseHeldOperation(Option<tokio::sync::oneshot::Sender<()>>);

impl ReleaseHeldOperation {
    fn release(mut self) {
        self.0
            .take()
            .expect("the held operation still has its release sender")
            .send(())
            .expect("the entered operation still accepts release");
    }
}

impl Drop for ReleaseHeldOperation {
    fn drop(&mut self) {
        if let Some(release) = self.0.take() {
            let _ = release.send(());
        }
    }
}

fn finish_held_operation<F, T, I>(
    control: OperationControl,
    request: F,
    inspect_entered: I,
) -> impl Future<Output = T>
where
    F: Future<Output = T>,
    I: FnOnce(),
{
    let OperationControl { entered, release } = control;
    let release = ReleaseHeldOperation(Some(release));
    async move {
        tokio::pin!(request);
        tokio::select! {
            receipt = entered => receipt.expect("the real controlled operation entered"),
            _ = &mut request => panic!("the request completed before its held operation entered"),
        }
        inspect_entered();
        release.release();
        request.await
    }
}

async fn with_playback_bridge<S, F>(setup: S, body: F)
where
    S: FnOnce(&OwnedRoot) -> Vec<DisplaySnapshotEntry>,
    F: for<'a> FnOnce(
        &'a OwnedRoot,
        &'a WallpaperBridge,
        &'a ControlledEngine,
    ) -> TestBody<'a>,
{
    let mut root = OwnedRoot::new();
    let paths = root.bridge_paths();
    let engine = ControlledEngine::new(setup(&root));
    let mut bridge = None;
    root.remove_on_drop = false;
    let result: Result<(), PanicPayload> = AssertUnwindSafe(async {
        let login = crate::api::lifecycle_test_support::inert_login_controller(
            crate::login::LaunchAtLoginStatus::Unavailable,
        );
        bridge = Some(
            BridgeBuilder::new(engine.clone())
                .with_paths(paths)
                .with_launch_at_login(login)
                .with_mouse_polling_enabled(false)
                .with_power_watching_enabled(false)
                .build()
                .expect("build the real controlled playback bridge"),
        );
        tokio::time::timeout(
            WATCHDOG,
            body(
                &root,
                bridge.as_ref().expect("the bridge was constructed"),
                &engine,
            ),
        )
        .await
        .expect("public playback operations exceeded the watchdog");
    })
    .catch_unwind()
    .await;

    let mut cleanup_errors = Vec::new();
    if let Some(bridge) = bridge.take() {
        let shutdown = AssertUnwindSafe(tokio::time::timeout(
            WATCHDOG,
            crate::api::mounted_lifecycle::shutdown_and_drain(bridge),
        ))
        .catch_unwind()
        .await;
        match shutdown {
            Ok(Ok(Ok(()))) => {}
            Ok(Ok(Err(error))) => cleanup_errors.push(format!("shutdown failed: {error:?}")),
            Ok(Err(error)) => {
                cleanup_errors.push(format!("shutdown watchdog expired: {error}"));
            }
            Err(_) => cleanup_errors.push("shutdown panicked".to_owned()),
        }
    } else {
        cleanup_errors.push("bridge construction did not return an owned drain handle".to_owned());
    }
    drop(engine);

    if cleanup_errors.is_empty() {
        root.remove_on_drop = true;
        if let Err(error) = root.remove_now() {
            cleanup_errors.push(format!("remove owned root {:?}: {error}", root.path));
        }
    } else {
        cleanup_errors.push(format!(
            "retained owned root {:?} because actor drain was not confirmed",
            root.path
        ));
    }
    if let Err(payload) = result {
        if !cleanup_errors.is_empty() {
            eprintln!("cleanup after playback test failure: {cleanup_errors:?}");
        }
        resume_unwind(payload);
    }
    assert!(cleanup_errors.is_empty(), "{cleanup_errors:?}");
}

fn close_phases(observations: &[EngineObservation]) -> Vec<OperationPhase> {
    observations
        .iter()
        .filter_map(|observation| match observation {
            EngineObservation::Close { phase } => Some(*phase),
            _ => None,
        })
        .collect()
}

fn live_capture_row(root: &OwnedRoot, handle: SceneHandle) -> DisplaySnapshotEntry {
    let project = root.checked(root.path.join("live-capture-project"));
    fs::create_dir_all(&project).expect("create the owned live scene project");
    let manifest = root.checked(project.join("project.json"));
    fs::write(
        &manifest,
        r#"{"title":"Tidal Lantern","type":"scene","file":"scene.json"}"#,
    )
    .expect("write independently authored live scene metadata");
    let scene = root.checked(project.join("scene.json"));
    fs::write(&scene, "{}\n").expect("write the owned non-rendered scene input");
    let template = SceneTemplate::builder(manifest.to_string_lossy().into_owned())
        .audio_response_enabled(true)
        .build()
        .expect("construct a real direct scene template on the owned path");
    let identity = DisplayIdentity {
        uuid: Some("playback-tidal-display".to_owned()),
        name: Some("Tidal Display".to_owned()),
        ..DisplayIdentity::default()
    };
    DisplaySnapshotEntry {
        desc: DisplayDesc::with_identity(93, identity.clone(), 0, 0, 1440, 900, 1.0),
        identity,
        handle: Some(handle),
        accepts_pointer_input: false,
        paused: false,
        window_active: true,
        assignment: Some(WallpaperAssignment::Direct(template)),
    }
}

#[tokio::test]
async fn public_pause_then_play_publishes_state_and_delivers_both_engine_values() {
    with_playback_bridge(
        |_| Vec::new(),
        |_, bridge, engine| {
            Box::pin(async move {
                let initial = bridge.app_snapshot().await.expect("read initial playback");
                assert_eq!(initial.playback_state, BridgePlaybackState::Playing);
                let baseline = engine.observations().len();

                let paused = finish_held_operation(
                    engine.hold_next_pause(Ok(())),
                    bridge.pause_all(),
                    || {},
                )
                .await
                .expect("public pause succeeds");
                assert_eq!(paused.app.playback_state, BridgePlaybackState::Paused);
                assert_eq!(
                    bridge.app_snapshot().await.expect("read published pause"),
                    paused.app
                );

                let playing = finish_held_operation(
                    engine.hold_next_pause(Ok(())),
                    bridge.play_all(),
                    || {},
                )
                .await
                .expect("public play succeeds");
                assert_eq!(playing.app.playback_state, BridgePlaybackState::Playing);
                assert_eq!(
                    bridge.app_snapshot().await.expect("read published play"),
                    playing.app
                );

                let observations = engine.observations();
                let applied: Vec<bool> = observations[baseline..]
                    .iter()
                    .filter_map(|observation| match observation {
                        EngineObservation::PauseAll {
                            paused,
                            phase: OperationPhase::Applied,
                            ..
                        } => Some(*paused),
                        _ => None,
                    })
                    .collect();
                assert_eq!(applied, vec![true, false]);
            })
        },
    )
    .await;
}

#[tokio::test]
async fn rejected_public_pause_preserves_playing_and_the_controlled_engine_cause() {
    const CAUSE: &str = "tidal pause admission refused by controlled core";
    with_playback_bridge(
        |_| Vec::new(),
        |_, bridge, engine| {
            Box::pin(async move {
                let before = bridge.app_snapshot().await.expect("read initial playback");
                assert_eq!(before.playback_state, BridgePlaybackState::Playing);
                let baseline = engine.observations().len();
                let error = finish_held_operation(
                    engine.hold_next_pause(Err(EngineError::Render(CAUSE.to_owned()))),
                    bridge.pause_all(),
                    || {},
                )
                .await
                .expect_err("the real held pause failure reaches the public caller");
                assert_eq!(error.kind(), BridgeErrorKind::Engine);
                assert!(error.message().contains(CAUSE));

                let after = bridge.app_snapshot().await.expect("read rejected pause state");
                assert_eq!(after.playback_state, before.playback_state);
                assert_eq!(after.playback_state, BridgePlaybackState::Playing);
                assert_eq!(
                    bridge.app_snapshot().await.expect("reread rejected pause state"),
                    after
                );

                let observations = engine.observations();
                let events = &observations[baseline..];
                let started = events
                    .iter()
                    .position(|event| matches!(event, EngineObservation::PauseAll {
                        paused: true,
                        phase: OperationPhase::Started,
                        ..
                    }))
                    .expect("the real pause request entered the retained dependency");
                let rejected = events
                    .iter()
                    .position(|event| matches!(event, EngineObservation::PauseAll {
                        paused: true,
                        phase: OperationPhase::Rejected,
                        ..
                    }))
                    .expect("the controlled pause actually rejected");
                assert!(started < rejected);
            })
        },
    )
    .await;
}

#[tokio::test]
async fn public_shutdown_completes_exactly_one_close_before_fixture_drain() {
    with_playback_bridge(
        |_| Vec::new(),
        |_, bridge, engine| {
            Box::pin(async move {
                let baseline = engine.observations().len();
                finish_held_operation(
                    engine.hold_next_close(Ok(())),
                    bridge.shutdown(),
                    || {
                        let observations = engine.observations();
                        assert_eq!(
                            close_phases(&observations[baseline..]),
                            vec![OperationPhase::Started]
                        );
                    },
                )
                .await
                .expect("public shutdown succeeds after real close release");
                let observations = engine.observations();
                assert_eq!(
                    close_phases(&observations[baseline..]),
                    vec![OperationPhase::Started, OperationPhase::Applied]
                );
            })
        },
    )
    .await;
}

#[tokio::test]
async fn public_shutdown_disables_live_capture_before_its_single_close_invocation() {
    let handle = SceneHandle::new(6_793);
    with_playback_bridge(
        |root| vec![live_capture_row(root, handle)],
        |_, bridge, engine| {
            Box::pin(async move {
                let initial_rows = engine.display_rows();
                assert_eq!(initial_rows.len(), 1);
                assert_eq!(initial_rows[0].handle, Some(handle));
                assert!(matches!(
                    &initial_rows[0].assignment,
                    Some(WallpaperAssignment::Direct(scene)) if scene.audio_response_enabled
                ));
                engine
                    .set_audio_capture_enabled(handle, true)
                    .await
                    .expect("enable real controlled capture for the live direct scene");
                assert_eq!(engine.audio_capture_state(handle), Some(true));
                let baseline = engine.observations().len();

                finish_held_operation(
                    engine.hold_next_close(Ok(())),
                    bridge.shutdown(),
                    || {
                        let observations = engine.observations();
                        let events = &observations[baseline..];
                        let close_started = events
                            .iter()
                            .position(|event| matches!(event, EngineObservation::Close {
                                phase: OperationPhase::Started,
                            }))
                            .expect("the actual close invocation has started");
                        let actor_disables: Vec<SceneHandle> = events[..close_started]
                            .iter()
                            .filter_map(|event| match event {
                                EngineObservation::Capture {
                                    handle,
                                    enabled: false,
                                    phase: OperationPhase::Applied,
                                } => Some(*handle),
                                _ => None,
                            })
                            .collect();
                        // Only observations before Close Started can witness the
                        // actor's pre-close disable; facade cleanup is not an
                        // additional actor request.
                        assert_eq!(actor_disables, vec![handle]);
                        assert_eq!(engine.audio_capture_state(handle), Some(false));
                        assert_eq!(
                            close_phases(events),
                            vec![OperationPhase::Started]
                        );
                    },
                )
                .await
                .expect("shutdown closes the genuine controlled live scene");

                let observations = engine.observations();
                assert_eq!(
                    close_phases(&observations[baseline..]),
                    vec![OperationPhase::Started, OperationPhase::Applied]
                );
                assert!(engine.display_rows().iter().all(|row| row.handle.is_none()));
                assert!(engine.live_scene_controls(handle).is_none());
                assert_eq!(engine.audio_capture_state(handle), None);
            })
        },
    )
    .await;
}
