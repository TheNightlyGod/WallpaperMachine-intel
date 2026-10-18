//! Per-display presentation suspension and the audio consumer gate it feeds.
//!
//! One screen being covered must stop that screen's work and nothing else, and
//! system audio capture must follow the wallpapers that are actually presenting
//! rather than a single global pause flag.

use std::time::{Duration, Instant};

use wallpaper_core::{
    DisplayDesc, DisplayIdentity, DisplaySnapshotEntry, WallpaperAssignment,
    project::{SceneHandle, SceneTemplate},
};

use crate::{
    BridgePlaybackState, api::BridgeBuilder, engine::{EngineFacade as _, FakeEngineFacade},
};

fn display_snapshot(display_id: u32) -> DisplaySnapshotEntry {
    let desc =
        DisplayDesc::with_identity(display_id, DisplayIdentity::default(), 0, 0, 1920, 1080, 1.0)
            .with_refresh_rate(60);
    DisplaySnapshotEntry {
        identity: DisplayIdentity::default(),
        desc,
        handle: None,
        accepts_pointer_input: false,
        paused: false,
        window_active: false,
        assignment: None,
    }
}

/// Sets audio response for one committed wallpaper and commits the change.
/// Audio response defaults to enabled, so every test that reasons about audio
/// consumers states the value it means explicitly.
async fn set_audio_response(bridge: &crate::api::WallpaperBridge, wallpaper: &str, enabled: bool) {
    bridge
        .set_audio_response_enabled(wallpaper.into(), enabled)
        .await
        .unwrap();
    bridge.apply_wallpaper_options(wallpaper.into(), true).await.unwrap();
}

/// Two displays, each with its own scene wallpaper committed to it.
async fn two_display_bridge(engine: &FakeEngineFacade) -> crate::api::WallpaperBridge {
    engine.set_snapshot(vec![display_snapshot(7), display_snapshot(9)]);
    let bridge = BridgeBuilder::new(engine.clone())
        .with_state(crate::actor::state::BridgeActorState::default())
        .build()
        .unwrap();
    for (wallpaper, display) in [("100", "7"), ("200", "9")] {
        bridge
            .inject_scene_wallpaper_config_for_test(wallpaper, "Scene")
            .await;
        bridge
            .set_display_config_enabled(wallpaper.into(), display.into(), true)
            .await
            .unwrap();
        bridge
            .apply_wallpaper_options(wallpaper.into(), true)
            .await
            .unwrap();
    }
    // Both scenes are live now. The fake's reconcile hands out handles by
    // position, which is display order here: 7 -> 1, 9 -> 2.
    engine.set_snapshot(vec![live_display(7, 1), live_display(9, 2)]);
    bridge
}

fn live_display(display_id: u32, handle: u64) -> DisplaySnapshotEntry {
    DisplaySnapshotEntry { handle: Some(SceneHandle::new(handle)), ..display_snapshot(display_id) }
}

/// Waits for the bridge actor to act on a renderer report, which reaches it
/// asynchronously through the engine's relay.
async fn eventually(what: &str, mut condition: impl FnMut() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(2);
    while !condition() {
        assert!(Instant::now() < deadline, "timed out waiting for {what}");
        tokio::time::sleep(Duration::from_millis(5)).await;
    }
}

fn capture_enables(engine: &FakeEngineFacade, handle: u64) -> usize {
    engine
        .audio_capture_calls()
        .iter()
        .filter(|call| **call == (SceneHandle::new(handle), true))
        .count()
}

fn last_capture_call(engine: &FakeEngineFacade, handle: u64) -> Option<bool> {
    engine
        .audio_capture_calls()
        .iter()
        .rev()
        .find(|(call_handle, _)| *call_handle == SceneHandle::new(handle))
        .map(|(_, enabled)| *enabled)
}

async fn audio_consumers(bridge: &crate::api::WallpaperBridge) -> u32 {
    bridge.renderer_counters().await.unwrap().audio_active_consumers
}

fn paused_by_display(engine: &FakeEngineFacade) -> Vec<(u32, bool)> {
    let mut scenes: Vec<(u32, bool)> = engine
        .rendered_scenes()
        .iter()
        .map(|scene| (scene.display.display_id, scene.paused))
        .collect();
    scenes.sort_unstable();
    scenes
}

fn live_pause_by_display(engine: &FakeEngineFacade) -> Vec<(u32, bool)> {
    let mut displays: Vec<_> = engine.display_snapshot().iter()
        .filter(|display| display.handle.is_some())
        .map(|display| (display.desc.display_id, display.paused))
        .collect();
    displays.sort_unstable();
    displays
}

#[tokio::test]
async fn reconcile_releases_a_retained_pause_only_on_the_display_that_should_play() {
    let engine = FakeEngineFacade::default();
    let _release = super::engine_release::EngineRelease::of(&engine);
    let bridge = two_display_bridge(&engine).await;
    bridge.set_display_presentation_suspended("7".into(), true).await.unwrap();
    let rendered = engine.rendered_scenes();
    let mut snapshot = engine.display_snapshot();
    for display in &mut snapshot {
        let scene = rendered.iter().find(|scene| scene.display.display_id == display.desc.display_id).unwrap();
        display.assignment = Some(WallpaperAssignment::Direct(SceneTemplate::from_scene_desc(scene)));
    }
    engine.set_snapshot(snapshot);

    // A renderer can retain the pause of the window it replaced. The bridge
    // already considers display 9 visible, so no visibility edge will resend
    // its resume. A descriptor's initial pause alone does not replace the
    // core's retained runtime pause; its live snapshot is authoritative.
    engine.set_display_paused(9, true).await.unwrap();
    assert_eq!(live_pause_by_display(&engine), vec![(7, true), (9, true)]);
    let reconciles = engine.calls().len();
    bridge.refresh_displays().await.unwrap();

    assert_eq!(live_pause_by_display(&engine), vec![(7, true), (9, false)]);
    assert_eq!(paused_by_display(&engine), vec![(7, true), (9, false)]);
    assert_eq!(engine.calls().len(), reconciles, "correcting a live pause must not reopen the scenes");

    // An unchanged Apply also reasserts presentation without rebuilding.
    engine.set_display_paused(9, true).await.unwrap();
    bridge.apply_wallpaper_options("200".into(), true).await.unwrap();
    assert_eq!(live_pause_by_display(&engine), vec![(7, true), (9, false)]);
    assert_eq!(engine.calls().len(), reconciles);

    // A different scene follows the delegated reconcile path and can inherit
    // the old renderer's runtime pause too.
    bridge.inject_scene_wallpaper_config_for_test("300", "Replacement").await;
    bridge.set_display_config_enabled("300".into(), "9".into(), true).await.unwrap();
    engine.set_display_paused(9, true).await.unwrap();
    bridge.apply_wallpaper_options("300".into(), true).await.unwrap();
    assert_eq!(live_pause_by_display(&engine), vec![(7, true), (9, false)]);

    // A later global user pause remains authoritative over both displays.
    bridge.pause_all().await.unwrap();
    engine.set_display_paused(9, false).await.unwrap();
    bridge.refresh_displays().await.unwrap();
    assert_eq!(live_pause_by_display(&engine), vec![(7, true), (9, true)]);
}

#[tokio::test]
async fn a_presentation_change_during_reconcile_wins_over_its_older_display_pause() {
    let engine = FakeEngineFacade::default();
    let _release = super::engine_release::EngineRelease::of(&engine);
    let bridge = std::sync::Arc::new(two_display_bridge(&engine).await);
    for display in ["7", "9"] {
        bridge.set_display_presentation_suspended(display.into(), true).await.unwrap();
    }
    for (wallpaper, paused) in [("300", false), ("400", true)] {
        bridge.inject_scene_wallpaper_config_for_test(wallpaper, "Replacement").await;
        bridge.set_display_config_enabled(wallpaper.into(), "9".into(), true).await.unwrap();
        let gate = engine.block_next_reconcile();
        let applying = bridge.clone();
        let job = std::thread::spawn(move || {
            tokio::runtime::Runtime::new().unwrap()
                .block_on(applying.apply_wallpaper_options(wallpaper.into(), true))
        });
        assert!(gate.wait_until_blocked(Duration::from_secs(2)));
        bridge.set_display_presentation_suspended("9".into(), paused).await.unwrap();
        let delivered = engine.display_paused_calls().len();
        gate.release();
        job.join().unwrap().unwrap();

        eventually("the latest per-display pause to replace the stale reconcile", || {
            live_pause_by_display(&engine) == vec![(7, true), (9, paused)]
                && paused_by_display(&engine) == vec![(7, true), (9, paused)]
        }).await;
        assert!(engine.display_paused_calls()[delivered..].iter()
            .all(|(display, value)| *display != 9 || *value == paused),
            "the worker's older policy must not undo the newer presentation choice");
    }
}

#[tokio::test]
async fn suspending_one_display_leaves_the_other_rendering() {
    let engine = FakeEngineFacade::default();
    let bridge = two_display_bridge(&engine).await;
    assert_eq!(paused_by_display(&engine), vec![(7, false), (9, false)]);

    bridge
        .set_display_presentation_suspended("9".into(), true)
        .await
        .unwrap();

    assert_eq!(
        engine.display_paused_calls(),
        vec![(9, true)],
        "only the covered display is told to stop"
    );
    assert_eq!(
        bridge.app_snapshot().await.unwrap().playback_state,
        BridgePlaybackState::Playing,
        "occluding one screen is not the user's Play/Pause choice"
    );

    // The next reconcile has to rebuild the same split, not one global state.
    bridge.refresh_displays().await.unwrap();
    assert_eq!(paused_by_display(&engine), vec![(7, false), (9, true)]);
}

#[tokio::test]
async fn resuming_one_display_does_not_resume_a_display_that_is_still_hidden() {
    let engine = FakeEngineFacade::default();
    let bridge = two_display_bridge(&engine).await;

    for display in ["7", "9"] {
        bridge
            .set_display_presentation_suspended(display.into(), true)
            .await
            .unwrap();
    }
    bridge
        .set_display_presentation_suspended("7".into(), false)
        .await
        .unwrap();

    assert_eq!(
        engine.display_paused_calls(),
        vec![(7, true), (9, true), (7, false)]
    );
    bridge.refresh_displays().await.unwrap();
    assert_eq!(paused_by_display(&engine), vec![(7, false), (9, true)]);
}

#[tokio::test]
async fn a_global_resume_never_restarts_a_display_that_is_still_covered() {
    let engine = FakeEngineFacade::default();
    let bridge = two_display_bridge(&engine).await;

    bridge
        .set_display_presentation_suspended("7".into(), true)
        .await
        .unwrap();
    let suspended_at = engine.scene_pause_log().len();
    // Display sleep, then wake: the global transition must not restart the
    // display that is still covered by a window, not even for a moment.
    bridge.set_presentation_suspended(true).await.unwrap();
    bridge.set_presentation_suspended(false).await.unwrap();

    let after_suspend = &engine.scene_pause_log()[suspended_at..];
    assert!(
        !after_suspend.contains(&(7, false)),
        "display 7 was resumed while still covered: {after_suspend:?}"
    );
    assert!(after_suspend.contains(&(9, false)), "the visible display resumes");
    assert_eq!(paused_by_display(&engine), vec![(7, true), (9, false)]);
}

#[tokio::test]
async fn a_user_pause_survives_per_display_resume() {
    let engine = FakeEngineFacade::default();
    let bridge = two_display_bridge(&engine).await;

    bridge.pause_all().await.unwrap();
    bridge
        .set_display_presentation_suspended("7".into(), true)
        .await
        .unwrap();
    bridge
        .set_display_presentation_suspended("7".into(), false)
        .await
        .unwrap();

    assert_eq!(
        bridge.app_snapshot().await.unwrap().playback_state,
        BridgePlaybackState::Paused
    );
    assert_eq!(paused_by_display(&engine), vec![(7, true), (9, true)]);
}

#[tokio::test]
async fn repeated_and_unknown_requests_are_rejected_or_ignored() {
    let engine = FakeEngineFacade::default();
    let bridge = two_display_bridge(&engine).await;

    bridge
        .set_display_presentation_suspended("9".into(), true)
        .await
        .unwrap();
    bridge
        .set_display_presentation_suspended("9".into(), true)
        .await
        .unwrap();
    assert_eq!(
        engine.display_paused_calls(),
        vec![(9, true)],
        "an unchanged decision must not be sent again"
    );

    let error = bridge
        .set_display_presentation_suspended("not-a-display".into(), true)
        .await
        .unwrap_err();
    assert!(error.message().contains("not-a-display"), "{error}");
}

#[tokio::test]
async fn a_failed_display_transition_rolls_back_and_can_be_retried() {
    let engine = FakeEngineFacade::default();
    let bridge = two_display_bridge(&engine).await;

    engine.fail_next_display_pause();
    assert!(
        bridge
            .set_display_presentation_suspended("9".into(), true)
            .await
            .is_err()
    );
    bridge.refresh_displays().await.unwrap();
    assert_eq!(
        paused_by_display(&engine),
        vec![(7, false), (9, false)],
        "a rejected transition must not leave the display recorded as suspended"
    );

    bridge
        .set_display_presentation_suspended("9".into(), true)
        .await
        .unwrap();
    bridge.refresh_displays().await.unwrap();
    assert_eq!(paused_by_display(&engine), vec![(7, false), (9, true)]);
}

// MARK: - A01: audio capture follows visible consumers

#[tokio::test]
async fn audio_capture_stops_when_the_only_audio_consumer_is_hidden() {
    let engine = FakeEngineFacade::default();
    let bridge = two_display_bridge(&engine).await;
    set_audio_response(&bridge, "100", false).await;
    set_audio_response(&bridge, "200", true).await;

    // The only audio-response wallpaper lives on display 9. While it presents,
    // the tap has to run.
    bridge
        .set_display_presentation_suspended("7".into(), true)
        .await
        .unwrap();
    assert!(
        !engine.audio_capture_suspended(),
        "hiding a display with no audio consumer must not stop the analysis"
    );

    bridge
        .set_display_presentation_suspended("9".into(), true)
        .await
        .unwrap();
    assert!(
        engine.audio_capture_suspended(),
        "with every audio consumer hidden there is nothing left to analyse"
    );

    bridge
        .set_display_presentation_suspended("9".into(), false)
        .await
        .unwrap();
    assert!(
        !engine.audio_capture_suspended(),
        "the consumer became visible again"
    );
}

#[tokio::test]
async fn a_presentation_transition_never_opens_the_tap_without_a_consumer() {
    let engine = FakeEngineFacade::default();
    let bridge = two_display_bridge(&engine).await;
    set_audio_response(&bridge, "100", false).await;
    set_audio_response(&bridge, "200", false).await;
    let before_transitions = engine.audio_capture_suspend_calls().len();

    // Neither wallpaper asked for audio response, so no presentation
    // transition is a reason to open the system audio tap.
    bridge
        .set_display_presentation_suspended("7".into(), true)
        .await
        .unwrap();
    bridge
        .set_display_presentation_suspended("7".into(), false)
        .await
        .unwrap();
    bridge.set_presentation_suspended(true).await.unwrap();
    bridge.set_presentation_suspended(false).await.unwrap();
    assert!(
        engine
            .audio_capture_suspend_calls()
            .iter()
            .skip(before_transitions)
            .all(|suspended| *suspended),
        "resuming presentation with nothing to analyse must not start capture: {:?}",
        engine.audio_capture_suspend_calls()
    );

    // With a consumer on a presenting display, the same transition does open it.
    set_audio_response(&bridge, "100", true).await;
    bridge.set_presentation_suspended(true).await.unwrap();
    bridge.set_presentation_suspended(false).await.unwrap();
    assert!(!engine.audio_capture_suspended());
}

#[tokio::test]
async fn muting_a_wallpaper_does_not_stop_its_audio_response() {
    let engine = FakeEngineFacade::default();
    let bridge = two_display_bridge(&engine).await;
    set_audio_response(&bridge, "200", false).await;
    bridge
        .set_audio_response_enabled("100".into(), true)
        .await
        .unwrap();
    bridge.set_muted("100".into(), true).await.unwrap();
    bridge.set_volume("100".into(), 0.0).await.unwrap();
    bridge.apply_wallpaper_options("100".into(), true).await.unwrap();
    // A pause transition is what recomputes the gate.
    bridge.set_presentation_suspended(true).await.unwrap();
    bridge.set_presentation_suspended(false).await.unwrap();

    assert!(
        !engine.audio_capture_suspended(),
        "silencing wallpaper playback is a different control from system audio response"
    );
}

// MARK: - R3: the tap waits for a scene that reads audio

#[tokio::test]
async fn audio_response_alone_does_not_open_the_tap_for_a_scene_that_reads_no_audio() {
    let engine = FakeEngineFacade::default();
    engine.scenes_start_without_audio();
    // Audio response is on for both wallpapers by default.
    let bridge = two_display_bridge(&engine).await;
    bridge.set_renderer_counters_enabled(true).await.unwrap();
    bridge.set_presentation_suspended(true).await.unwrap();
    bridge.set_presentation_suspended(false).await.unwrap();

    assert_eq!(capture_enables(&engine, 1) + capture_enables(&engine, 2), 0,
        "no scene reads audio, so none registers as a consumer: {:?}", engine.audio_capture_calls());
    assert!(engine.audio_capture_suspended(), "nothing to analyse, so the tap stays shut");
    assert_eq!(audio_consumers(&bridge).await, 0);

    // The scene on display 9 starts reading audio -- at load or, for a
    // script, later. The tap opens for it, once, without a reconcile.
    engine.report_requires_audio(SceneHandle::new(2), true);
    eventually("the audio scene to register", || !engine.audio_capture_suspended()).await;
    assert_eq!(capture_enables(&engine, 2), 1, "{:?}", engine.audio_capture_calls());
    assert_eq!(capture_enables(&engine, 1), 0);
    assert_eq!(audio_consumers(&bridge).await, 1);

    // Hidden or paused, it is still not a consumer.
    bridge.set_display_presentation_suspended("9".into(), true).await.unwrap();
    assert!(engine.audio_capture_suspended());
    assert_eq!(audio_consumers(&bridge).await, 0);
    bridge.set_display_presentation_suspended("9".into(), false).await.unwrap();
    assert!(!engine.audio_capture_suspended());
    bridge.pause_all().await.unwrap();
    assert!(engine.audio_capture_suspended());
    assert_eq!(audio_consumers(&bridge).await, 0);
}

#[tokio::test]
async fn replacing_an_audio_scene_with_one_that_reads_nothing_closes_the_tap() {
    let engine = FakeEngineFacade::default();
    engine.scenes_start_without_audio();
    let bridge = two_display_bridge(&engine).await;
    bridge.set_renderer_counters_enabled(true).await.unwrap();
    engine.report_requires_audio(SceneHandle::new(1), true);
    eventually("the audio scene to register", || last_capture_call(&engine, 1) == Some(true))
        .await;
    assert!(!engine.audio_capture_suspended());

    // Another wallpaper replaces it on the same display and handle. Its
    // renderer starts at "reads nothing", which is what it reports.
    bridge.inject_scene_wallpaper_config_for_test("300", "Still").await;
    bridge.set_display_config_enabled("300".into(), "7".into(), true).await.unwrap();
    bridge.apply_wallpaper_options("300".into(), true).await.unwrap();
    engine.report_requires_audio(SceneHandle::new(1), false);
    eventually("the replaced scene to release the tap", || engine.audio_capture_suspended()).await;
    assert_eq!(last_capture_call(&engine, 1), Some(false));
    assert_eq!(audio_consumers(&bridge).await, 0);
}
