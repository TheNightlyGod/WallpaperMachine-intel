//! Whole-scene on-demand updating and the scene renderer preference.
//!
//! Four properties matter here. Both settings have to survive a restart and be
//! pushed back into the renderer, because the switches live in C rather than in
//! the config file. Both have to reach the engine through *both* halves of the
//! facade — `RealEngineFacade` and the `ArcEngineFacade` the bridge actually
//! holds — because a forward added to only one of the two compiles cleanly and
//! silently does nothing. An unrecognised renderer name has to be refused
//! rather than quietly becoming Compatibility. And the live per-scene status
//! has to keep `unknown` apart from `continuous`: a scene that is running and
//! could not be read is not evidence that anything is ticking.

use wallpaper_core::{
    DisplayDesc, DisplayIdentity, DisplaySnapshotEntry, SceneBackend, SceneDemandReasons,
    SceneRendererPreference, SceneResolution, SceneRuntimeReport, SceneUpdateMode, SceneVideoPath,
    SurfaceHealth, SurfaceStopReason, project::SceneHandle,
};

use crate::{
    api::{BridgeBuilder, WallpaperBridge},
    config::ConfigStore,
    engine::FakeEngineFacade,
};

fn report(display_id: u32, handle: u64) -> SceneRuntimeReport {
    SceneRuntimeReport {
        display_id,
        handle,
        update_mode: Some(SceneUpdateMode::Continuous),
        demand_reasons: SceneDemandReasons::default(),
        backend: Some(SceneBackend::LegacyVulkan),
        fallback_reason: None,
        video_path: SceneVideoPath::None,
        optimization_applied: Some(true),
        surface: None,
    }
}

/// A surface the renderer read that is drawing normally.
fn healthy_surface() -> SurfaceHealth {
    SurfaceHealth::from_raw(600, 600, 0, 16, 0)
}

/// A surface the renderer read that stopped after `reason`.
fn stopped_surface(reason: SurfaceStopReason) -> SurfaceHealth {
    SurfaceHealth {
        stop: Some(reason),
        failed_frames: 1,
        ..healthy_surface()
    }
}

fn bridge(engine: &FakeEngineFacade) -> WallpaperBridge {
    BridgeBuilder::new(engine.clone()).build().unwrap()
}

#[tokio::test]
async fn scene_on_demand_defaults_off_and_reaches_the_engine_through_both_facade_halves() {
    let temp = tempfile::tempdir().unwrap();
    let store = ConfigStore::open(temp.path().to_path_buf());
    let engine = FakeEngineFacade::default();
    let bridge = BridgeBuilder::new(engine.clone())
        .with_config_store(store.clone())
        .build()
        .unwrap();

    assert!(
        !bridge
            .settings_snapshot()
            .await
            .unwrap()
            .scene_on_demand_enabled,
        "a setting that changes whether a scene ticks at all is opted into, not out of"
    );

    let snapshot = bridge
        .set_scene_on_demand_enabled(true)
        .await
        .unwrap()
        .settings;
    assert!(snapshot.scene_on_demand_enabled);
    // The bridge holds an `ArcEngineFacade`, so an empty log here means the
    // call stopped at a default trait method instead of reaching the engine.
    // This is the assertion that catches a forward wired into only one half.
    assert_eq!(
        engine.scene_on_demand_calls(),
        vec![true],
        "the renderer must be told; a delegation missing from ArcEngineFacade would no-op silently"
    );
    assert!(
        engine.rendered_scenes().is_empty(),
        "changing when a scene ticks must not reopen, reparse or restart a wallpaper"
    );

    drop(bridge);
    let restarted_engine = FakeEngineFacade::default();
    let restarted = BridgeBuilder::new(restarted_engine.clone())
        .with_config_store(store)
        .build()
        .unwrap();
    assert!(
        restarted
            .settings_snapshot()
            .await
            .unwrap()
            .scene_on_demand_enabled
    );
    restarted.bootstrap().await.unwrap();
    assert_eq!(
        restarted_engine.scene_on_demand_calls().last().copied(),
        Some(true),
        "a process-wide renderer switch lives in C, so a saved opt-in has to be pushed back in"
    );
}

#[tokio::test]
async fn scene_renderer_defaults_to_native_metal_and_reaches_both_facade_halves() {
    let temp = tempfile::tempdir().unwrap();
    let store = ConfigStore::open(temp.path().to_path_buf());
    let engine = FakeEngineFacade::default();
    let bridge = BridgeBuilder::new(engine.clone())
        .with_config_store(store.clone())
        .build()
        .unwrap();

    assert_eq!(
        bridge.settings_snapshot().await.unwrap().scene_renderer,
        "native_metal_preferred"
    );

    let snapshot = bridge
        .set_scene_renderer("compatibility".into())
        .await
        .unwrap()
        .settings;
    assert_eq!(snapshot.scene_renderer, "compatibility");
    // End state only: the switch is process-wide while the rebuild is per
    // wallpaper, so the number of transitions is not a contract.
    assert_eq!(
        engine.scene_renderer_calls().last().copied(),
        Some(SceneRendererPreference::Compatibility),
        "a delegation missing from ArcEngineFacade would leave this log empty"
    );

    drop(bridge);
    let restarted_engine = FakeEngineFacade::default();
    let restarted = BridgeBuilder::new(restarted_engine.clone())
        .with_config_store(store)
        .build()
        .unwrap();
    restarted.bootstrap().await.unwrap();
    assert_eq!(
        restarted_engine.scene_renderer_calls().last().copied(),
        Some(SceneRendererPreference::Compatibility),
        "the saved choice has to be pushed back in before anything opens, and a \
         return to Compatibility is not moved to the default again"
    );
}

#[tokio::test]
async fn an_unknown_scene_renderer_name_is_refused_and_changes_nothing() {
    let engine = FakeEngineFacade::default();
    let bridge = bridge(&engine);

    let error = bridge
        .set_scene_renderer("metal".into())
        .await
        .expect_err("only the two declared names exist");

    assert_eq!(error.kind(), crate::BridgeErrorKind::InvalidInput);
    assert!(
        engine.scene_renderer_calls().is_empty(),
        "a refused name must not be silently substituted with Compatibility"
    );
    assert_eq!(
        bridge.settings_snapshot().await.unwrap().scene_renderer,
        "native_metal_preferred",
        "the saved preference must be untouched by a rejected call"
    );
}

fn display_with_scene(display_id: u32, handle: u64) -> DisplaySnapshotEntry {
    let desc =
        DisplayDesc::with_identity(display_id, DisplayIdentity::default(), 0, 0, 1920, 1080, 1.0)
            .with_refresh_rate(60);
    DisplaySnapshotEntry {
        identity: DisplayIdentity::default(),
        desc,
        handle: Some(SceneHandle::new(handle)),
        accepts_pointer_input: false,
        paused: false,
        window_active: true,
        assignment: None,
    }
}

#[tokio::test]
async fn scene_resolution_defaults_to_the_display_and_reaches_both_facade_halves() {
    let temp = tempfile::tempdir().unwrap();
    let store = ConfigStore::open(temp.path().to_path_buf());
    let engine = FakeEngineFacade::default();
    let bridge = BridgeBuilder::new(engine.clone())
        .with_config_store(store.clone())
        .build()
        .unwrap();

    assert_eq!(
        bridge.settings_snapshot().await.unwrap().scene_resolution,
        "display"
    );
    bridge.bootstrap().await.unwrap();
    assert_eq!(
        engine.scene_resolution_calls().last().copied(),
        Some(SceneResolution::Display),
        "the engine's own default is the canvas, so the shipped default has to be pushed in too"
    );

    let snapshot = bridge
        .set_scene_resolution("canvas".into())
        .await
        .unwrap()
        .settings;
    assert_eq!(snapshot.scene_resolution, "canvas");
    // The bridge holds an `ArcEngineFacade`, so a log that still ends at the
    // default means the call stopped at a default trait method.
    assert_eq!(
        engine.scene_resolution_calls().last().copied(),
        Some(SceneResolution::Canvas),
        "a delegation missing from ArcEngineFacade would leave this log unchanged"
    );

    drop(bridge);
    let restarted_engine = FakeEngineFacade::default();
    let restarted = BridgeBuilder::new(restarted_engine.clone())
        .with_config_store(store)
        .build()
        .unwrap();
    assert_eq!(
        restarted.settings_snapshot().await.unwrap().scene_resolution,
        "canvas"
    );
    restarted.bootstrap().await.unwrap();
    assert_eq!(
        restarted_engine.scene_resolution_calls().last().copied(),
        Some(SceneResolution::Canvas),
        "a process-wide renderer switch lives in C, so the saved choice has to be pushed back in \
         and a return to the canvas is not moved to the default again"
    );
}

#[tokio::test]
async fn a_scene_resolution_change_reaches_open_scenes_through_their_render_scale() {
    let engine = FakeEngineFacade::default();
    engine.set_snapshot(vec![display_with_scene(7, 1), display_with_scene(9, 2)]);
    let bridge = bridge(&engine);
    bridge.set_render_scale(0.5).await.unwrap();
    let reconciles = engine.calls().len();
    let renders = engine.render_scale_calls().len();

    bridge.set_scene_resolution("canvas".into()).await.unwrap();

    // A running scene reads the process switch when its render scale is
    // applied, so every open scene is handed the scale it already has: the one
    // in force, not a constant.
    assert_eq!(
        engine.render_scale_calls()[renders..],
        [(SceneHandle::new(1), 0.5), (SceneHandle::new(2), 0.5)],
        "an open scene never learns of the choice if its render scale is not re-sent"
    );
    assert_eq!(
        engine.calls().len(),
        reconciles,
        "a quality choice must not reparse a project or reopen a video"
    );
    assert!(engine.rendered_scenes().is_empty());

    // Choosing what is already chosen is no event at all.
    bridge.set_scene_resolution("canvas".into()).await.unwrap();
    assert_eq!(engine.render_scale_calls().len(), renders + 2);
    assert_eq!(
        engine.scene_resolution_calls(),
        vec![SceneResolution::Canvas],
        "the renderer is told once"
    );
}

#[tokio::test]
async fn an_unknown_scene_resolution_is_refused_and_changes_nothing() {
    let engine = FakeEngineFacade::default();
    let bridge = bridge(&engine);

    let error = bridge
        .set_scene_resolution("native".into())
        .await
        .expect_err("only the two declared names exist");

    assert_eq!(error.kind(), crate::BridgeErrorKind::InvalidInput);
    assert!(engine.scene_resolution_calls().is_empty());
    assert_eq!(
        bridge.settings_snapshot().await.unwrap().scene_resolution,
        "display",
        "the saved choice must be untouched by a rejected call"
    );
}

#[tokio::test]
async fn an_unreadable_running_scene_reports_unknown_rather_than_continuous() {
    let engine = FakeEngineFacade::default();
    // Three scenes: one idle with no demand, one ticking with named reasons,
    // and one the renderer could not answer for.
    engine.set_scene_runtime_reports(vec![
        SceneRuntimeReport {
            update_mode: Some(SceneUpdateMode::WaitingForEvent),
            ..report(7, 1)
        },
        SceneRuntimeReport {
            update_mode: Some(SceneUpdateMode::Continuous),
            demand_reasons: SceneDemandReasons::VIDEO | SceneDemandReasons::SOUND,
            ..report(8, 2)
        },
        SceneRuntimeReport {
            update_mode: None,
            backend: None,
            ..report(9, 3)
        },
    ]);
    let bridge = bridge(&engine);

    let modes = bridge.settings_snapshot().await.unwrap().scene_update_modes;

    assert_eq!(
        modes.len(),
        3,
        "a scene the renderer cannot answer for is still a running scene and must not be dropped"
    );
    assert_eq!(modes[0].mode, "waiting_for_event");
    assert!(
        modes[0].reasons.is_empty(),
        "nothing is demanding updates, which is a real answer"
    );
    assert_eq!(modes[1].mode, "continuous");
    assert_eq!(modes[1].reasons, vec!["video", "sound"]);
    assert_eq!(
        modes[2].mode, "unknown",
        "could-not-read must never serialise as a state the user could act on"
    );
}

#[tokio::test]
async fn an_unnamed_demand_bit_survives_as_unknown_input() {
    let engine = FakeEngineFacade::default();
    // A renderer newer than this binary sets a bit this build has no name for.
    // Dropping it would turn "I do not understand this scene" into "this scene
    // is idle", which is the one answer this feature must never invent.
    engine.set_scene_runtime_reports(vec![SceneRuntimeReport {
        demand_reasons: SceneDemandReasons::from_raw(1 << 30),
        ..report(7, 1)
    }]);
    let bridge = bridge(&engine);

    let modes = bridge.settings_snapshot().await.unwrap().scene_update_modes;

    assert_eq!(modes.len(), 1);
    assert!(
        modes[0].reasons.contains(&"unknown_input".to_string()),
        "an unrecognised reason must reach the user, not vanish: {:?}",
        modes[0].reasons
    );
}

#[tokio::test]
async fn a_user_pause_outranks_the_renderers_own_classification() {
    let engine = FakeEngineFacade::default();
    engine.set_scene_runtime_reports(vec![report(7, 1)]);
    let bridge = bridge(&engine);

    assert_eq!(
        bridge.settings_snapshot().await.unwrap().scene_update_modes[0].mode,
        "continuous"
    );

    bridge.pause_all().await.unwrap();

    assert_eq!(
        bridge.settings_snapshot().await.unwrap().scene_update_modes[0].mode,
        "user_paused",
        "a wallpaper the user paused is paused, whatever the renderer's classifier says"
    );
}

#[tokio::test]
async fn a_scene_that_stopped_after_a_failure_reads_stopped_after_failure_unless_the_user_paused_it()
{
    let engine = FakeEngineFacade::default();
    // Both kinds of stop, a healthy surface the renderer read, and one it did
    // not read at all, each next to a renderer classification that on its own
    // would say the scene is ticking.
    engine.set_scene_runtime_reports(vec![
        SceneRuntimeReport {
            surface: Some(stopped_surface(SurfaceStopReason::FrameFailed)),
            ..report(7, 1)
        },
        SceneRuntimeReport {
            surface: Some(stopped_surface(SurfaceStopReason::GraphFailed)),
            ..report(8, 2)
        },
        SceneRuntimeReport {
            surface: Some(healthy_surface()),
            ..report(9, 3)
        },
        SceneRuntimeReport {
            surface: None,
            update_mode: None,
            ..report(10, 4)
        },
    ]);
    let bridge = bridge(&engine);

    let modes = bridge.settings_snapshot().await.unwrap().scene_update_modes;

    assert_eq!(
        modes[0].mode, "stopped_after_failure",
        "a frame that failed is not a scene that is continuously updating"
    );
    assert_eq!(modes[1].mode, "stopped_after_failure");
    assert_eq!(modes[2].mode, "continuous");
    assert_eq!(
        modes[3].mode, "unknown",
        "a surface the renderer did not read is unknown, never stopped and never running"
    );

    bridge.pause_all().await.unwrap();
    let paused = bridge.settings_snapshot().await.unwrap().scene_update_modes;
    assert!(
        paused.iter().all(|row| row.mode == "user_paused"),
        "a pause the user chose outranks a stop they have not seen: {:?}",
        paused.iter().map(|row| row.mode.as_str()).collect::<Vec<_>>()
    );

    bridge.play_all().await.unwrap();
    let resumed = bridge.settings_snapshot().await.unwrap().scene_update_modes;
    assert_eq!(
        resumed[0].mode, "stopped_after_failure",
        "lifting the pause shows the failure that was latched underneath it"
    );
}

#[tokio::test]
async fn a_suspended_display_outranks_a_stopped_surface() {
    let engine = FakeEngineFacade::default();
    engine.set_scene_runtime_reports(vec![SceneRuntimeReport {
        surface: Some(stopped_surface(SurfaceStopReason::FrameFailed)),
        ..report(7, 1)
    }]);
    let bridge = bridge(&engine);

    bridge
        .set_display_presentation_suspended("7".into(), true)
        .await
        .unwrap();

    assert_eq!(
        bridge.settings_snapshot().await.unwrap().scene_update_modes[0].mode,
        "policy_suspended",
        "a display the app deliberately suspended is not reported as a failure"
    );
}

#[tokio::test]
async fn a_report_without_surface_health_keeps_its_existing_mode() {
    let engine = FakeEngineFacade::default();
    engine.set_scene_runtime_reports(vec![
        SceneRuntimeReport {
            update_mode: Some(SceneUpdateMode::WaitingForEvent),
            surface: None,
            ..report(7, 1)
        },
        SceneRuntimeReport {
            update_mode: Some(SceneUpdateMode::Continuous),
            surface: None,
            ..report(8, 2)
        },
    ]);
    let bridge = bridge(&engine);

    let modes = bridge.settings_snapshot().await.unwrap().scene_update_modes;

    assert_eq!(modes[0].mode, "waiting_for_event");
    assert_eq!(modes[1].mode, "continuous");
}

#[tokio::test]
async fn a_suspended_display_reports_policy_rather_than_the_users_own_pause() {
    let engine = FakeEngineFacade::default();
    engine.set_scene_runtime_reports(vec![report(7, 1)]);
    let bridge = bridge(&engine);

    bridge
        .set_display_presentation_suspended("7".into(), true)
        .await
        .unwrap();

    assert_eq!(
        bridge.settings_snapshot().await.unwrap().scene_update_modes[0].mode,
        "policy_suspended",
        "the app suspending a display is not the user pausing a wallpaper"
    );
}

#[tokio::test]
async fn the_backend_report_names_what_ran_and_only_real_fallbacks() {
    let engine = FakeEngineFacade::default();
    engine.set_scene_runtime_reports(vec![
        SceneRuntimeReport {
            backend: Some(SceneBackend::NativeMetal),
            ..report(7, 1)
        },
        SceneRuntimeReport {
            backend: Some(SceneBackend::LegacyVulkan),
            fallback_reason: Some("the scene uses a puppet the native backend cannot draw".into()),
            ..report(8, 2)
        },
        SceneRuntimeReport {
            backend: None,
            ..report(9, 3)
        },
    ]);
    let bridge = bridge(&engine);

    let renderers = bridge.settings_snapshot().await.unwrap().scene_renderers;

    assert_eq!(renderers[0].backend, "native_metal");
    assert_eq!(
        renderers[0].fallback_reason, None,
        "a scene that got what was asked for did not fall back"
    );
    assert_eq!(renderers[1].backend, "legacy_vulkan");
    assert_eq!(
        renderers[1].fallback_reason.as_deref(),
        Some("the scene uses a puppet the native backend cannot draw")
    );
    assert_eq!(
        renderers[2].backend, "unknown",
        "a backend the renderer could not name must not be reported as the preference"
    );
}

/// No GPU backend exists until a scene has been parsed and one has been chosen,
/// so an absent backend is a phase of the scene's life rather than a failed
/// reading. It has to reach the panel as its own value, distinct from both real
/// backends and from the preference, and it has to carry no fallback reason:
/// nothing has fallen back while nothing has been chosen.
#[tokio::test]
async fn a_scene_with_no_backend_yet_is_reported_separately_from_a_fallback() {
    let engine = FakeEngineFacade::default();
    engine.set_scene_runtime_reports(vec![
        SceneRuntimeReport {
            backend: None,
            ..report(7, 1)
        },
        SceneRuntimeReport {
            backend: Some(SceneBackend::LegacyVulkan),
            fallback_reason: Some("the scene uses a puppet the native backend cannot draw".into()),
            ..report(8, 2)
        },
    ]);
    let bridge = bridge(&engine);
    bridge
        .set_scene_renderer(SceneRendererPreference::NativeMetalPreferred.as_str().into())
        .await
        .unwrap();

    let settings = bridge.settings_snapshot().await.unwrap();
    let renderers = &settings.scene_renderers;

    assert_eq!(
        renderers.len(),
        2,
        "a scene still choosing a backend is a running scene and must not be dropped"
    );
    assert_eq!(renderers[0].backend, "unknown");
    assert_ne!(
        renderers[0].backend, settings.scene_renderer,
        "preferring the native backend must not be published as having got it"
    );
    assert_ne!(
        renderers[0].backend, renderers[1].backend,
        "not chosen yet and chose compatibility are different answers"
    );
    assert_eq!(
        renderers[0].fallback_reason, None,
        "nothing has been chosen, so nothing has fallen back"
    );
    assert_eq!(
        renderers[1].fallback_reason.as_deref(),
        Some("the scene uses a puppet the native backend cannot draw"),
        "the renderer's own reason is what the panel shows, so it must survive the snapshot"
    );
}

#[tokio::test]
async fn nothing_running_is_reported_as_nothing_running() {
    let engine = FakeEngineFacade::default();
    let bridge = bridge(&engine);

    let settings = bridge.settings_snapshot().await.unwrap();

    assert!(settings.scene_update_modes.is_empty());
    assert!(settings.scene_renderers.is_empty());
}
