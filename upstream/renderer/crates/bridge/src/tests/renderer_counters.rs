//! Reporting of renderer work counters.
//!
//! The increments themselves live in the renderer: the frame clock, the draw
//! handler, the queue submission, the present request and the decoder. What is
//! checked here is the reporting contract the application depends on — that
//! counting stays off until it is asked for, that surfaces are kept apart, that
//! surface-exclusive work is reported separately from shared source work, and
//! that nothing is presented as a measurement the platform cannot make.

use wallpaper_core::{
    DisplayDesc, DisplayIdentity, DisplaySnapshotEntry,
    project::SceneHandle,
    render::{RendererCounterKind, RendererPauseReason, RendererSurfaceCounters},
};

use crate::{api::BridgeBuilder, engine::FakeEngineFacade};

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
    // Both scenes are live now; the fake's reconcile hands out handles by
    // position, which is display order here.
    engine.set_snapshot(vec![
        DisplaySnapshotEntry { handle: Some(SceneHandle::new(1)), ..display_snapshot(7) },
        DisplaySnapshotEntry { handle: Some(SceneHandle::new(2)), ..display_snapshot(9) },
    ]);
    bridge
}

/// Builds one surface's counter values in `owe_renderer_counter` order.
fn surface(
    display_id: u32,
    handle: u64,
    generation: u64,
    source: &str,
    paused: bool,
    entries: &[(RendererCounterKind, u64)],
) -> RendererSurfaceCounters {
    let width = entries
        .iter()
        .map(|(kind, _)| kind.index() + 1)
        .chain(std::iter::once(RendererCounterKind::VideoSeeks.index() + 1))
        .max()
        .unwrap_or(0);
    let mut values = vec![0u64; width];
    for (kind, value) in entries {
        values[kind.index()] = *value;
    }
    RendererSurfaceCounters {
        display_id,
        handle: SceneHandle::new(handle),
        generation,
        source_path: source.to_string(),
        paused,
        values,
    }
}

#[tokio::test]
async fn counting_is_off_until_a_diagnostic_session_asks_for_it() {
    let engine = FakeEngineFacade::default();
    let bridge = two_display_bridge(&engine).await;

    assert!(!engine.renderer_counters_enabled());
    let report = bridge.renderer_counters().await.unwrap();
    assert!(
        !report.recording,
        "a report taken with counting off must say so rather than presenting zeroes as no work"
    );

    bridge.set_renderer_counters_enabled(true).await.unwrap();
    assert!(engine.renderer_counters_enabled());
    assert!(bridge.renderer_counters().await.unwrap().recording);

    bridge.set_renderer_counters_enabled(false).await.unwrap();
    assert!(!engine.renderer_counters_enabled());
    assert!(!bridge.renderer_counters().await.unwrap().recording);
}

#[tokio::test]
async fn a_hidden_surface_stops_its_own_work_while_a_shared_source_keeps_serving_the_other() {
    use RendererCounterKind as K;
    let engine = FakeEngineFacade::default();
    let bridge = two_display_bridge(&engine).await;
    bridge.set_renderer_counters_enabled(true).await.unwrap();

    // Two surfaces of the same source file. Display 9 is hidden: it stopped
    // submitting and presenting. Display 7 is visible and still running, and
    // the decoder kept producing frames that it consumes.
    engine.set_renderer_counters(
        vec![
            surface(7, 1, 1, "/library/clip/project.json", false, &[
                (K::TimerWakeups, 600),
                (K::DrawRequests, 600),
                (K::DrawsExecuted, 600),
                (K::RenderSubmissions, 600),
                (K::PresentRequests, 600),
                (K::GpuCompletions, 600),
                (K::VideoDecodeOutputs, 600),
                (K::VideoFramesSelected, 600),
            ]),
            surface(9, 2, 1, "/library/clip/project.json", true, &[
                (K::TimerWakeups, 120),
                (K::DrawRequests, 120),
                (K::DrawsExecuted, 120),
                (K::RenderSubmissions, 120),
                (K::PresentRequests, 120),
                (K::GpuCompletions, 120),
                (K::VideoDecodeOutputs, 600),
                (K::VideoFramesSelected, 120),
                (K::PauseReasons, RendererPauseReason::ClockStopped.mask()),
            ]),
        ],
        vec![],
    );

    let report = bridge.renderer_counters().await.unwrap();
    let visible = report
        .surfaces
        .iter()
        .find(|row| row.display_id == "7")
        .expect("visible surface reported");
    let hidden = report
        .surfaces
        .iter()
        .find(|row| row.display_id == "9")
        .expect("hidden surface reported");

    assert!(!visible.paused);
    assert_eq!(visible.present_requests, 600);
    assert!(hidden.paused);
    assert_eq!(hidden.effective_pause_reasons, vec!["clockStopped"]);
    assert!(
        hidden.present_requests < visible.present_requests,
        "a hidden surface must not keep presenting"
    );
    // The decoded source is shared work: the hidden surface's own submissions
    // stopped while the same source kept producing frames for the visible one.
    assert_eq!(hidden.video_decode_outputs, visible.video_decode_outputs);
    assert_eq!(hidden.source_path, visible.source_path);
    assert_ne!(hidden.surface_id, visible.surface_id);
}

#[tokio::test]
async fn a_paused_surface_keeps_the_work_it_already_did() {
    use RendererCounterKind as K;
    let engine = FakeEngineFacade::default();
    let bridge = two_display_bridge(&engine).await;
    bridge.set_renderer_counters_enabled(true).await.unwrap();

    // Suspension stops new work; it must not clear the record of the old work.
    // A row that zeroed itself on pause would make any surface look like it had
    // always been idle, which is exactly the claim these counters exist to test.
    engine.set_renderer_counters(
        vec![surface(9, 2, 1, "/library/clip/project.json", true, &[
            (K::PresentRequests, 120),
            (K::RenderSubmissions, 120),
            (K::PauseReasons, RendererPauseReason::ClockStopped.mask()),
        ])],
        vec![],
    );

    let row = &bridge.renderer_counters().await.unwrap().surfaces[0];
    assert!(row.paused);
    assert_eq!(row.present_requests, 120);
    assert_eq!(row.render_submissions, 120);
}

#[tokio::test]
async fn a_source_identity_names_a_running_decoder_not_a_file() {
    use RendererCounterKind as K;
    let engine = FakeEngineFacade::default();
    let bridge = two_display_bridge(&engine).await;
    bridge.set_renderer_counters_enabled(true).await.unwrap();

    // Two surfaces, one file, two decoders. Keying on the path would fold them
    // into one decode that never happened.
    engine.set_renderer_counters(
        vec![
            surface(7, 1, 1, "/library/clip/project.json", false, &[
                (K::VideoSourceCount, 1),
                (K::VideoSourceInstance, 4),
            ]),
            surface(9, 2, 1, "/library/clip/project.json", false, &[
                (K::VideoSourceCount, 1),
                (K::VideoSourceInstance, 5),
            ]),
        ],
        vec![],
    );

    let report = bridge.renderer_counters().await.unwrap();
    assert_eq!(report.surfaces[0].source_id, "instance:4");
    assert_eq!(report.surfaces[1].source_id, "instance:5");
    assert_eq!(report.surfaces[0].source_path, report.surfaces[1].source_path);
    assert_eq!(report.surfaces[0].source_count, 1);
}

#[tokio::test]
async fn a_surface_without_one_identifiable_decoder_reports_unknown() {
    use RendererCounterKind as K;
    let engine = FakeEngineFacade::default();
    let bridge = two_display_bridge(&engine).await;
    bridge.set_renderer_counters_enabled(true).await.unwrap();

    engine.set_renderer_counters(
        vec![surface(7, 1, 1, "/library/scene/project.json", false, &[
            (K::VideoSourceCount, 3),
            (K::VideoSourceInstance, 0),
        ])],
        vec![],
    );

    let report = bridge.renderer_counters().await.unwrap();
    assert_eq!(report.surfaces[0].source_id, "unknown");
    assert_eq!(report.surfaces[0].source_count, 3);
}

#[tokio::test]
async fn two_wallpapers_that_reused_one_display_are_not_merged() {
    use RendererCounterKind as K;
    let engine = FakeEngineFacade::default();
    let bridge = two_display_bridge(&engine).await;
    bridge.set_renderer_counters_enabled(true).await.unwrap();

    engine.set_renderer_counters(
        vec![
            surface(7, 1, 1, "/library/old/project.json", false, &[(K::DrawRequests, 90)]),
            surface(7, 1, 2, "/library/new/project.json", false, &[(K::DrawRequests, 4)]),
        ],
        vec![],
    );

    let report = bridge.renderer_counters().await.unwrap();
    assert_eq!(report.surfaces.len(), 2);
    let generations: Vec<u64> = report.surfaces.iter().map(|row| row.generation).collect();
    assert_eq!(generations, vec![1, 2]);
    // The path is a label; the identity is the running decoder, which these
    // rows do not have, so it reads as unknown rather than as the path.
    let sources: Vec<&str> = report.surfaces.iter().map(|row| row.source_path.as_str()).collect();
    assert_eq!(sources, vec!["/library/old/project.json", "/library/new/project.json"]);
}

#[tokio::test]
async fn every_pause_reason_is_reported_rather_than_the_first() {
    use RendererCounterKind as K;
    let engine = FakeEngineFacade::default();
    let bridge = two_display_bridge(&engine).await;
    bridge.set_renderer_counters_enabled(true).await.unwrap();

    let bits = RendererPauseReason::ClockStopped.mask()
        | RendererPauseReason::RenderBlocked.mask()
        | RendererPauseReason::NoScene.mask();
    engine.set_renderer_counters(
        vec![surface(7, 1, 1, "/library/clip/project.json", true, &[(K::PauseReasons, bits)])],
        vec![],
    );

    let report = bridge.renderer_counters().await.unwrap();
    assert_eq!(
        report.surfaces[0].effective_pause_reasons,
        vec!["clockStopped", "renderBlocked", "noScene"]
    );
}

#[tokio::test]
async fn a_request_to_present_is_never_reported_as_a_displayed_frame() {
    use RendererCounterKind as K;
    let engine = FakeEngineFacade::default();
    let bridge = two_display_bridge(&engine).await;
    bridge.set_renderer_counters_enabled(true).await.unwrap();

    engine.set_renderer_counters(
        vec![surface(7, 1, 1, "/library/clip/project.json", false, &[
            (K::PresentRequests, 300),
            (K::GpuCompletions, 300),
        ])],
        vec![],
    );

    let report = bridge.renderer_counters().await.unwrap();
    assert!(
        !report.presentation_feedback_available,
        "this backend cannot observe which frames the compositor displayed"
    );
    assert_eq!(report.surfaces[0].present_requests, 300);
    assert_eq!(report.surfaces[0].gpu_completions, 300);
}

#[tokio::test]
async fn audio_consumers_follow_visibility_the_same_way_the_capture_tap_does() {
    let engine = FakeEngineFacade::default();
    let bridge = two_display_bridge(&engine).await;
    bridge.set_renderer_counters_enabled(true).await.unwrap();
    // Audio response defaults to enabled, so both committed scenes consume.
    assert_eq!(bridge.renderer_counters().await.unwrap().audio_active_consumers, 2);

    bridge
        .set_display_presentation_suspended("9".into(), true)
        .await
        .unwrap();
    assert_eq!(bridge.renderer_counters().await.unwrap().audio_active_consumers, 1);

    bridge
        .set_display_presentation_suspended("7".into(), true)
        .await
        .unwrap();
    let report = bridge.renderer_counters().await.unwrap();
    assert_eq!(
        report.audio_active_consumers, 0,
        "with every consumer hidden the tap has nobody to serve"
    );
}

#[tokio::test]
async fn process_wide_audio_analysis_is_reported_apart_from_any_surface() {
    let engine = FakeEngineFacade::default();
    let bridge = two_display_bridge(&engine).await;
    bridge.set_renderer_counters_enabled(true).await.unwrap();

    engine.set_renderer_counters(Vec::new(), vec![42, 4096]);

    let report = bridge.renderer_counters().await.unwrap();
    assert_eq!(report.audio_analysis_deliveries, 42);
    assert_eq!(report.audio_accepted_frames, 4096);
    assert!(report.surfaces.is_empty());
}

#[tokio::test]
async fn a_renderer_built_against_a_shorter_counter_list_reads_as_zero_not_as_an_error() {
    let engine = FakeEngineFacade::default();
    let bridge = two_display_bridge(&engine).await;
    bridge.set_renderer_counters_enabled(true).await.unwrap();

    engine.set_renderer_counters(
        vec![RendererSurfaceCounters {
            display_id: 7,
            handle: SceneHandle::new(1),
            generation: 1,
            source_path: "/library/clip/project.json".to_string(),
            paused: false,
            values: vec![12],
        }],
        vec![7],
    );

    let report = bridge.renderer_counters().await.unwrap();
    assert_eq!(report.surfaces[0].timer_wakeups, 12);
    assert_eq!(report.surfaces[0].video_imports, 0);
    assert_eq!(report.audio_analysis_deliveries, 7);
    assert_eq!(report.audio_accepted_frames, 0);
}
