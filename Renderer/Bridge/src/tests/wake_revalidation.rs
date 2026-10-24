//! The check that confirms scenes present again after the Mac wakes.
//!
//! What matters is who gets touched. A healthy scene must cost two reads and
//! nothing else, a scene that is idle or paused on purpose must never be
//! mistaken for a dead one, and a dead one must be handed to the engine's
//! budgeted recovery exactly once. Every reading is scripted, so the tests need
//! no clock beyond a short real wait.

use std::time::Duration;

use wallpaper_core::{
    DisplayDesc, DisplayIdentity, DisplaySnapshotEntry, RecoveryOutcome, RecoveryReason,
    SceneBackend, SceneDemandReasons, SceneRuntimeReport, SceneUpdateMode,
    SceneVideoPath, SurfaceHealth, SurfaceStopReason, project::SceneHandle,
};

use crate::{
    api::BridgeBuilder,
    engine::{FakeEngineFacade, revalidate::revalidate_presentation},
};

const GRACE: Duration = Duration::from_millis(20);

fn display(display_id: u32, handle: Option<u64>, paused: bool) -> DisplaySnapshotEntry {
    DisplaySnapshotEntry {
        identity: DisplayIdentity::default(),
        desc: DisplayDesc::with_identity(
            display_id,
            DisplayIdentity::default(),
            0,
            0,
            1920,
            1080,
            1.0,
        ),
        handle: handle.map(SceneHandle::new),
        accepts_pointer_input: false,
        paused,
        window_active: true,
        assignment: None,
    }
}

fn report(handle: u64, display_id: u32, frames: u64) -> SceneRuntimeReport {
    SceneRuntimeReport {
        display_id,
        handle,
        update_mode: Some(SceneUpdateMode::Continuous),
        demand_reasons: SceneDemandReasons::default(),
        backend: Some(SceneBackend::NativeMetal),
        failure: None,
        video_path: SceneVideoPath::None,
        optimization_applied: Some(true),
        surface: Some(SurfaceHealth::from_raw(frames, frames, 0, 16, 0)),
    }
}

fn stopped(handle: u64, display_id: u32, frames: u64) -> SceneRuntimeReport {
    SceneRuntimeReport {
        surface: Some(SurfaceHealth {
            stop: Some(SurfaceStopReason::FrameFailed),
            failed_frames: 1,
            ..SurfaceHealth::from_raw(frames, frames, 0, 16, 0)
        }),
        ..report(handle, display_id, frames)
    }
}

fn in_mode(mode: Option<SceneUpdateMode>, report: SceneRuntimeReport) -> SceneRuntimeReport {
    SceneRuntimeReport { update_mode: mode, ..report }
}

fn outcomes(checks: &[crate::engine::revalidate::SurfaceCheck]) -> Vec<(u32, &'static str)> {
    checks.iter().map(|check| (check.display_id, check.outcome())).collect()
}

#[tokio::test]
async fn a_scene_whose_frames_advanced_is_left_alone() {
    let engine = FakeEngineFacade::default();
    engine.set_snapshot(vec![display(1, Some(10), false)]);
    engine.script_scene_runtime_reports(vec![
        vec![report(10, 1, 412)],
        vec![report(10, 1, 598)],
    ]);

    let checks = revalidate_presentation(&engine, GRACE).await;

    assert_eq!(outcomes(&checks), vec![(1, "ok")]);
    assert_eq!((checks[0].frames_before, checks[0].frames_after), (412, 598));
    assert!(
        engine.recover_calls().is_empty(),
        "a Mac that woke well must not have a single surface rebuilt"
    );
}

#[tokio::test]
async fn a_continuous_scene_with_flat_frames_is_recovered_once() {
    let engine = FakeEngineFacade::default();
    engine.set_snapshot(vec![display(1, Some(10), false)]);
    engine.script_scene_runtime_reports(vec![
        vec![report(10, 1, 412)],
        vec![report(10, 1, 412)],
    ]);

    let checks = revalidate_presentation(&engine, GRACE).await;

    assert_eq!(outcomes(&checks), vec![(1, "repaired")]);
    assert_eq!(
        engine.recover_calls(),
        vec![(1, RecoveryReason::Stalled)],
        "a liveness check spends the scene's budget; it must never start a fresh one the way the user's Retry does"
    );
}

#[tokio::test]
async fn a_paused_or_suspended_display_is_never_probed() {
    // Paused for any reason: the user, power policy, a covered or sleeping
    // display. The frame counter standing still is the decision working.
    let engine = FakeEngineFacade::default();
    engine.set_snapshot(vec![display(1, Some(10), true)]);
    engine.script_scene_runtime_reports(vec![vec![report(10, 1, 50)], vec![report(10, 1, 50)]]);

    let checks = revalidate_presentation(&engine, GRACE).await;

    assert_eq!(outcomes(&checks), vec![(1, "skipped_paused")]);
    assert!(engine.recover_calls().is_empty());

    // Paused during the wait: the second reading must not count a scene the
    // host stopped on purpose as one that died.
    let engine = FakeEngineFacade::default();
    engine.script_display_snapshots(vec![
        vec![display(1, Some(10), false)],
        vec![display(1, Some(10), true)],
    ]);
    engine.script_scene_runtime_reports(vec![vec![report(10, 1, 50)], vec![report(10, 1, 50)]]);

    let checks = revalidate_presentation(&engine, GRACE).await;

    assert_eq!(outcomes(&checks), vec![(1, "skipped_paused")]);
    assert!(engine.recover_calls().is_empty());
}

#[tokio::test]
async fn a_stopped_scene_on_a_paused_display_is_left_to_the_pause() {
    let engine = FakeEngineFacade::default();
    engine.set_snapshot(vec![display(1, Some(10), true)]);
    engine.set_scene_runtime_reports(vec![stopped(10, 1, 50)]);

    let checks = revalidate_presentation(&engine, GRACE).await;

    assert_eq!(outcomes(&checks), vec![(1, "skipped_paused")]);
    assert!(
        engine.recover_calls().is_empty(),
        "recovery never plays what was paused"
    );
}

#[tokio::test]
async fn a_waiting_for_event_scene_is_never_recovered_even_with_flat_frames() {
    // An event-driven scene, one waiting for a deadline and one whose clock the
    // host stopped all stand still without being dead.
    for mode in [
        SceneUpdateMode::WaitingForEvent,
        SceneUpdateMode::WaitingForDeadline,
        SceneUpdateMode::ClockStopped,
        SceneUpdateMode::NotApplicable,
    ] {
        let engine = FakeEngineFacade::default();
        engine.set_snapshot(vec![display(1, Some(10), false)]);
        engine.set_scene_runtime_reports(vec![in_mode(Some(mode), report(10, 1, 70))]);

        let checks = revalidate_presentation(&engine, GRACE).await;

        assert_eq!(
            outcomes(&checks),
            vec![(1, "skipped_not_continuous")],
            "{mode:?}"
        );
        assert!(engine.recover_calls().is_empty(), "{mode:?}");
    }
}

#[tokio::test]
async fn a_scene_that_became_idle_during_the_wait_is_not_stale() {
    let engine = FakeEngineFacade::default();
    engine.set_snapshot(vec![display(1, Some(10), false)]);
    engine.script_scene_runtime_reports(vec![
        vec![report(10, 1, 70)],
        vec![in_mode(Some(SceneUpdateMode::WaitingForEvent), report(10, 1, 70))],
    ]);

    let checks = revalidate_presentation(&engine, GRACE).await;

    assert_eq!(outcomes(&checks), vec![(1, "skipped_not_continuous")]);
    assert!(engine.recover_calls().is_empty());
}

#[tokio::test]
async fn a_surface_the_renderer_could_not_read_is_not_taken_for_a_healthy_or_a_dead_one() {
    let engine = FakeEngineFacade::default();
    engine.set_snapshot(vec![
        display(1, Some(10), false),
        display(2, Some(20), false),
        display(3, Some(30), false),
    ]);
    engine.set_scene_runtime_reports(vec![
        // The renderer returned no surface reading.
        SceneRuntimeReport { surface: None, ..report(10, 1, 0) },
        // It could not classify the scene.
        in_mode(None, report(20, 2, 5)),
        // No row at all for the third scene.
    ]);

    let checks = revalidate_presentation(&engine, GRACE).await;

    assert_eq!(
        outcomes(&checks),
        vec![(1, "skipped_unreadable"), (2, "skipped_unreadable"), (3, "skipped_unreadable")]
    );
    assert!(engine.recover_calls().is_empty());
}

#[tokio::test]
async fn a_stopped_latch_is_recovered_without_waiting_for_the_grace() {
    let engine = FakeEngineFacade::default();
    engine.set_snapshot(vec![display(1, Some(10), false)]);
    engine.set_scene_runtime_reports(vec![stopped(10, 1, 300)]);

    // A minute of grace: a check that waited for it would never finish inside
    // the timeout.
    let checks = tokio::time::timeout(
        Duration::from_secs(5),
        revalidate_presentation(&engine, Duration::from_secs(60)),
    )
    .await
    .expect("a scene that already stopped itself needs no waiting to be known stale");

    assert_eq!(outcomes(&checks), vec![(1, "repaired")]);
    assert_eq!(engine.recover_calls(), vec![(1, RecoveryReason::Stalled)]);
}

#[tokio::test]
async fn a_scene_that_stops_during_the_wait_is_recovered_as_stopped() {
    let engine = FakeEngineFacade::default();
    engine.set_snapshot(vec![display(1, Some(10), false)]);
    engine.script_scene_runtime_reports(vec![vec![report(10, 1, 300)], vec![stopped(10, 1, 301)]]);

    let checks = revalidate_presentation(&engine, GRACE).await;

    assert_eq!(outcomes(&checks), vec![(1, "repaired")]);
    assert_eq!(engine.recover_calls(), vec![(1, RecoveryReason::Stalled)]);
}

#[tokio::test]
async fn a_replaced_renderer_whose_counter_restarted_is_not_stale() {
    let engine = FakeEngineFacade::default();
    engine.set_snapshot(vec![display(1, Some(10), false)]);
    // A new renderer counts from zero. Reading 40 after 5000 is a scene that
    // began again, not one that stood still.
    engine.script_scene_runtime_reports(vec![vec![report(10, 1, 5000)], vec![report(10, 1, 40)]]);

    let checks = revalidate_presentation(&engine, GRACE).await;

    assert_eq!(outcomes(&checks), vec![(1, "ok")]);
    assert!(engine.recover_calls().is_empty());
}

#[tokio::test]
async fn a_scene_replaced_by_another_during_the_wait_is_not_compared_with_its_predecessor() {
    let engine = FakeEngineFacade::default();
    engine.script_display_snapshots(vec![
        vec![display(1, Some(10), false)],
        // A different wallpaper now runs on the display.
        vec![display(1, Some(11), false)],
    ]);
    engine.script_scene_runtime_reports(vec![
        vec![report(10, 1, 70)],
        vec![report(11, 1, 70)],
    ]);

    let checks = revalidate_presentation(&engine, GRACE).await;

    assert_eq!(outcomes(&checks), vec![(1, "skipped_changed")]);
    assert!(engine.recover_calls().is_empty());

    // The display lost its scene altogether.
    let engine = FakeEngineFacade::default();
    engine.script_display_snapshots(vec![
        vec![display(1, Some(10), false)],
        vec![display(1, None, false)],
    ]);
    engine.script_scene_runtime_reports(vec![vec![report(10, 1, 70)], vec![]]);

    let checks = revalidate_presentation(&engine, GRACE).await;

    assert_eq!(outcomes(&checks), vec![(1, "skipped_changed")]);
    assert!(engine.recover_calls().is_empty());
}

#[tokio::test]
async fn only_the_display_that_stalled_is_repaired_and_a_display_with_no_scene_has_no_row() {
    let engine = FakeEngineFacade::default();
    engine.set_snapshot(vec![
        display(1, Some(10), false),
        display(2, None, false),
        display(3, Some(30), false),
    ]);
    engine.script_scene_runtime_reports(vec![
        vec![report(10, 1, 100), report(30, 3, 900)],
        vec![report(10, 1, 160), report(30, 3, 900)],
    ]);

    let checks = revalidate_presentation(&engine, GRACE).await;

    assert_eq!(outcomes(&checks), vec![(1, "ok"), (3, "repaired")]);
    assert_eq!(
        engine.recover_calls(),
        vec![(3, RecoveryReason::Stalled)],
        "the healthy display must not be rebuilt because its neighbour was"
    );
}

#[tokio::test]
async fn a_spent_budget_and_a_failed_repair_are_reported_and_do_not_stop_the_other_displays() {
    let engine = FakeEngineFacade::default();
    engine.set_snapshot(vec![display(1, Some(10), false)]);
    engine.set_scene_runtime_reports(vec![stopped(10, 1, 5)]);
    engine.set_recover_result(Ok(RecoveryOutcome::GaveUp));
    assert_eq!(
        outcomes(&revalidate_presentation(&engine, GRACE).await),
        vec![(1, "gave_up")],
        "a scene the engine will no longer rebuild stays stopped and is said to"
    );

    engine.set_recover_result(Ok(RecoveryOutcome::InProgress));
    assert_eq!(
        outcomes(&revalidate_presentation(&engine, GRACE).await),
        vec![(1, "recovery_pending")]
    );

    engine.set_recover_result(Err("the device was lost".to_owned()));
    engine.set_snapshot(vec![display(1, Some(10), false), display(2, Some(20), false)]);
    engine.script_scene_runtime_reports(vec![
        vec![stopped(10, 1, 5), report(20, 2, 1)],
        vec![stopped(10, 1, 5), report(20, 2, 80)],
    ]);
    let checks = revalidate_presentation(&engine, GRACE).await;
    assert_eq!(
        outcomes(&checks),
        vec![(1, "recovery_failed"), (2, "ok")],
        "one display's failed repair must not hide the verdict on the next"
    );
}

#[tokio::test]
async fn a_scene_the_engine_no_longer_has_is_not_reported_as_repaired() {
    let engine = FakeEngineFacade::default();
    engine.set_snapshot(vec![display(1, Some(10), false)]);
    engine.set_scene_runtime_reports(vec![stopped(10, 1, 5)]);
    engine.set_recover_result(Ok(RecoveryOutcome::NoScene));

    assert_eq!(
        outcomes(&revalidate_presentation(&engine, GRACE).await),
        vec![(1, "skipped_changed")]
    );
}

#[tokio::test]
async fn the_call_reaches_the_engine_through_both_facade_halves() {
    let engine = FakeEngineFacade::default();
    engine.set_snapshot(vec![display(1, Some(10), false)]);
    engine.script_scene_runtime_reports(vec![vec![report(10, 1, 412)], vec![report(10, 1, 412)]]);
    // The bridge holds an `ArcEngineFacade`. A forward missing from it compiles
    // cleanly and answers "no scene" to every repair, so this call would report
    // `skipped_changed` and leave the engine's log empty.
    let bridge = BridgeBuilder::new(engine.clone())
        .with_wake_check_grace(GRACE)
        .build()
        .unwrap();

    let checks = bridge.revalidate_scene_presentation("didWake".to_owned()).await.unwrap();

    assert_eq!(checks.len(), 1);
    assert_eq!(checks[0].display_id, 1);
    assert_eq!(checks[0].outcome, "repaired");
    assert_eq!((checks[0].frames_before, checks[0].frames_after), (412, 412));
    assert_eq!(
        engine.recover_calls(),
        vec![(1, RecoveryReason::Stalled)],
        "the repair must reach the engine, not stop at a default trait method"
    );
}

#[tokio::test]
async fn two_checks_at_once_run_one_after_the_other() {
    let engine = FakeEngineFacade::default();
    engine.set_snapshot(vec![display(1, Some(10), false)]);
    // Read in order, two per check. Run one after the other the first check
    // sees 100 then 100 (stalled) and the second 200 then 300 (drawing). Run
    // together their readings interleave and neither sees a stall, so the
    // single repair below could not happen.
    engine.script_scene_runtime_reports(vec![
        vec![report(10, 1, 100)],
        vec![report(10, 1, 100)],
        vec![report(10, 1, 200)],
        vec![report(10, 1, 300)],
    ]);
    let bridge = BridgeBuilder::new(engine.clone())
        .with_wake_check_grace(GRACE)
        .build()
        .unwrap();

    let (first, second) = tokio::join!(
        bridge.revalidate_scene_presentation("didWake".to_owned()),
        bridge.revalidate_scene_presentation("screensDidWake".to_owned()),
    );
    let mut outcomes: Vec<String> = [first.unwrap(), second.unwrap()]
        .into_iter()
        .map(|checks| checks[0].outcome.clone())
        .collect();
    outcomes.sort();

    assert_eq!(outcomes, vec!["ok".to_owned(), "repaired".to_owned()]);
    assert_eq!(
        engine.recover_calls().len(),
        1,
        "one stalled scene is one repair, however many wakes noticed it"
    );
}
