//! The temporary reduced-quality request.
//!
//! The host can ask for the reduced-quality profile for reasons the saved
//! battery mode knows nothing about. Three properties matter. It lowers what
//! runs live, through the same calls the battery profile and the quality
//! sliders use, and clearing it hands the user's own values back. It can only
//! lower: no combination of a throttle, the battery profile and the user's own
//! settings may run above the user's choice, or above what the throttle alone
//! would allow. And it is runtime state, so a saved file never carries it and
//! a new bridge starts without one.
//!
//! Every test here holds an [`EngineRelease`] for its engine, so the threads a
//! bridge starts go when its test ends, and the tests share a bridge between the
//! phases of one property instead of building one per assertion.

use std::fs;

use wallpaper_core::{DisplayDesc, DisplayIdentity, DisplaySnapshotEntry, project::SceneHandle};

use super::engine_release::EngineRelease;
use crate::{
    BridgeBatteryMode, BridgeQualityThrottleCause, BridgeSettingsSnapshot,
    api::{BridgeBuilder, BridgeErrorKind},
    config::ConfigStore,
    engine::FakeEngineFacade,
    paths::BridgePaths,
    power::PowerSource,
};

const SCENE: &str = r#"{"type":"scene","title":"Scene","file":"scene.pkg","description":""}"#;
const WEB: &str = r#"{"type":"web","title":"Web","file":"index.html","description":""}"#;
const CLIP: &str = r#"{"type":"video","title":"Clip","file":"clip.mp4","description":""}"#;

/// The profile's own defaults, which every test here relies on.
const PROFILE_SCALE: f32 = 0.75;
const PROFILE_FPS: u32 = 30;

fn display(display_id: u32, handle: Option<u64>) -> DisplaySnapshotEntry {
    let desc =
        DisplayDesc::with_identity(display_id, DisplayIdentity::default(), 0, 0, 1920, 1080, 1.0)
            .with_refresh_rate(60);
    DisplaySnapshotEntry {
        identity: DisplayIdentity::default(),
        desc,
        handle: handle.map(SceneHandle::new),
        accepts_pointer_input: false,
        paused: false,
        window_active: true,
        assignment: None,
    }
}

fn bridge_with(engine: &FakeEngineFacade, temp: &tempfile::TempDir) -> crate::api::WallpaperBridge {
    let paths = BridgePaths::for_home(temp.path().to_path_buf());
    let clip = paths.steam_workshop_root().join("400");
    fs::create_dir_all(&clip).unwrap();
    fs::write(clip.join("clip.mp4"), b"presence is all the native player checks").unwrap();
    BridgeBuilder::new(engine.clone())
        .with_state(crate::actor::state::BridgeActorState::default())
        .with_paths(paths)
        .build()
        .unwrap()
}

async fn commit(
    bridge: &crate::api::WallpaperBridge,
    wallpaper: &str,
    project_json: &str,
    display: &str,
) {
    bridge
        .inject_scene_project_for_test(wallpaper, "Wallpaper", project_json)
        .await;
    bridge
        .inject_scene_wallpaper_config_for_test(wallpaper, "Wallpaper")
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

/// What a test keeps alive beside its bridge: the folder the bridge works in, and the
/// release that lets its threads go when the test ends.
struct Scratch {
    _release: EngineRelease,
    _folder: tempfile::TempDir,
}

/// A running scene on display 7, handle 1, at the display's own 60 fps.
async fn running_scene() -> (FakeEngineFacade, crate::api::WallpaperBridge, Scratch) {
    let temp = tempfile::tempdir().unwrap();
    let engine = FakeEngineFacade::default();
    let release = EngineRelease::of(&engine);
    engine.set_snapshot(vec![display(7, Some(1))]);
    let bridge = bridge_with(&engine, &temp);
    commit(&bridge, "100", SCENE, "7").await;
    (
        engine,
        bridge,
        Scratch {
            _release: release,
            _folder: temp,
        },
    )
}

async fn settings(bridge: &crate::api::WallpaperBridge) -> BridgeSettingsSnapshot {
    bridge.settings_snapshot().await.unwrap()
}

fn last_scale(engine: &FakeEngineFacade) -> (SceneHandle, f32) {
    *engine
        .render_scale_calls()
        .last()
        .expect("a quality change must reach the renderer")
}

fn last_fps(engine: &FakeEngineFacade) -> (SceneHandle, u32) {
    *engine
        .fps_calls()
        .last()
        .expect("a quality change must reach the renderer")
}

fn heat() -> Vec<BridgeQualityThrottleCause> {
    vec![BridgeQualityThrottleCause::Heat]
}

#[tokio::test]
async fn a_throttle_lowers_open_scenes_live_and_hands_the_saved_values_back() {
    let (engine, bridge, _temp) = running_scene().await;
    bridge.set_render_scale(0.9).await.unwrap();
    bridge
        .set_battery_quality_profile(0.5, 30)
        .await
        .unwrap();
    let reconciles = engine.calls().len();

    let lowered = bridge.set_quality_throttle(heat()).await.unwrap().settings;

    assert_eq!(lowered.render_scale, 0.5);
    assert_eq!(
        lowered.preferred_render_scale, 0.9,
        "a throttle must not overwrite what the user saved"
    );
    assert_eq!(
        lowered.frame_rate_cap, None,
        "the saved cap is the user's, and a throttle leaves it alone"
    );
    assert_eq!(lowered.effective_frame_rate_cap, Some(30));
    assert_eq!(lowered.quality_throttle, heat());
    assert_eq!(
        lowered.battery_mode,
        BridgeBatteryMode::KeepRunning,
        "a throttle is not a battery mode"
    );
    assert_eq!(last_scale(&engine), (SceneHandle::new(1), 0.5));
    assert_eq!(last_fps(&engine), (SceneHandle::new(1), 30));
    assert_eq!(
        engine.calls().len(),
        reconciles,
        "a throttle is a live property, not a rebuild of the scene list"
    );

    let restored = bridge.set_quality_throttle(Vec::new()).await.unwrap().settings;

    assert_eq!(restored.render_scale, 0.9);
    assert_eq!(restored.frame_rate_cap, None);
    assert_eq!(restored.effective_frame_rate_cap, None);
    assert!(restored.quality_throttle.is_empty());
    assert_eq!(last_scale(&engine), (SceneHandle::new(1), 0.9));
    assert_eq!(
        last_fps(&engine),
        (SceneHandle::new(1), 60),
        "clearing hands back the display's own rate, not a remembered constant"
    );
    assert_eq!(engine.calls().len(), reconciles);

    // Several causes at once: they are reported sorted and counted once, and
    // the throttle holds until the last of them ends.
    let both = bridge
        .set_quality_throttle(vec![
            BridgeQualityThrottleCause::Heat,
            BridgeQualityThrottleCause::LowPowerMode,
        ])
        .await
        .unwrap()
        .settings;
    assert_eq!(
        both.quality_throttle,
        vec![
            BridgeQualityThrottleCause::LowPowerMode,
            BridgeQualityThrottleCause::Heat
        ],
        "the causes are reported sorted, whatever order they were asked in"
    );
    let repeated = bridge
        .set_quality_throttle(vec![BridgeQualityThrottleCause::Heat; 3])
        .await
        .unwrap()
        .settings;
    assert_eq!(repeated.quality_throttle, heat(), "a repeated cause counts once");
    let one_left = bridge.set_quality_throttle(heat()).await.unwrap().settings;
    assert_eq!(one_left.render_scale, 0.5);
    assert_eq!(
        last_fps(&engine).1,
        30,
        "one cause ending must not restore what another still holds down"
    );

    // Every cause asks for the same profile.
    for cause in [
        BridgeQualityThrottleCause::LowPowerMode,
        BridgeQualityThrottleCause::Heat,
        BridgeQualityThrottleCause::LowBattery,
    ] {
        let alone = bridge
            .set_quality_throttle(vec![cause])
            .await
            .unwrap()
            .settings;
        assert_eq!(alone.effective_frame_rate_cap, Some(30), "{cause:?}");
        assert_eq!(alone.render_scale, 0.5, "{cause:?}");
        assert_eq!(alone.frame_rate_cap, None, "{cause:?}");
    }

    let none = bridge.set_quality_throttle(Vec::new()).await.unwrap().settings;
    assert!(none.quality_throttle.is_empty());
    assert_eq!(none.render_scale, 0.9);
    assert_eq!(last_fps(&engine).1, 60);
}

/// One bridge walks every combination, so each row also proves that what runs
/// follows the state in force and not the path that led to it. The rows with a
/// user scale or cap below the profile are the ones that must never be raised.
#[tokio::test]
async fn the_throttle_and_the_battery_profile_never_stack_into_something_higher() {
    let (engine, bridge, _temp) = running_scene().await;
    for preferred in [0.5_f32, 0.9] {
        for global in [None, Some(15_u32), Some(45)] {
            for battery in [false, true] {
                for throttled in [false, true] {
                    let case = format!(
                        "preferred {preferred}, cap {global:?}, battery {battery}, throttle {throttled}"
                    );
                    bridge
                        .set_battery_mode(if battery {
                            BridgeBatteryMode::ReducedQuality
                        } else {
                            BridgeBatteryMode::KeepRunning
                        })
                        .await
                        .unwrap();
                    bridge
                        .set_power_source_for_test(if battery {
                            PowerSource::Battery
                        } else {
                            PowerSource::External
                        })
                        .await;
                    bridge.set_render_scale(preferred).await.unwrap();
                    bridge.set_frame_rate_cap(global).await.unwrap();
                    let causes = if throttled {
                        vec![BridgeQualityThrottleCause::LowPowerMode]
                    } else {
                        Vec::new()
                    };
                    let snapshot = bridge.set_quality_throttle(causes).await.unwrap().settings;

                    let scale = if throttled {
                        preferred.min(PROFILE_SCALE)
                    } else if battery {
                        PROFILE_SCALE
                    } else {
                        preferred
                    };
                    let ceiling = match (global, battery || throttled) {
                        (Some(cap), true) => Some(cap.min(PROFILE_FPS)),
                        (Some(cap), false) => Some(cap),
                        (None, true) => Some(PROFILE_FPS),
                        (None, false) => None,
                    };
                    assert_eq!(snapshot.render_scale, scale, "{case}");
                    assert_eq!(last_scale(&engine).1, scale, "{case}");
                    assert_eq!(snapshot.effective_frame_rate_cap, ceiling, "{case}");
                    assert_eq!(
                        last_fps(&engine).1,
                        ceiling.map_or(60, |ceiling| ceiling.min(60)),
                        "{case}"
                    );
                    assert_eq!(snapshot.frame_rate_cap, global, "{case}");
                    assert_eq!(snapshot.preferred_render_scale, preferred, "{case}");
                }
            }
        }
    }
}

#[tokio::test]
async fn throttling_never_touches_playback_and_asking_again_applies_a_refused_update() {
    let (engine, bridge, _temp) = running_scene().await;
    bridge.pause_all().await.unwrap();

    bridge.set_quality_throttle(heat()).await.unwrap();
    assert_eq!(
        bridge.app_snapshot().await.unwrap().playback_state,
        crate::BridgePlaybackState::Paused,
        "a throttle must not resume what the user paused"
    );
    bridge.set_quality_throttle(Vec::new()).await.unwrap();
    assert_eq!(
        bridge.app_snapshot().await.unwrap().playback_state,
        crate::BridgePlaybackState::Paused
    );

    bridge.play_all().await.unwrap();
    bridge.set_quality_throttle(heat()).await.unwrap();
    assert_eq!(
        bridge.app_snapshot().await.unwrap().playback_state,
        crate::BridgePlaybackState::Playing,
        "a throttle lowers quality; it never pauses"
    );
    bridge.set_quality_throttle(Vec::new()).await.unwrap();
    assert_eq!(
        bridge.app_snapshot().await.unwrap().playback_state,
        crate::BridgePlaybackState::Playing
    );

    // The renderer refuses the new scale. The request is kept, so asking
    // again with the same causes finishes what the first attempt did not.
    bridge.set_render_scale(0.9).await.unwrap();
    engine.fail_next_render_scale();
    let refused = bridge
        .set_quality_throttle(heat())
        .await
        .expect_err("the renderer refused the new scale");
    assert_eq!(refused.kind(), BridgeErrorKind::Engine);

    let retried = bridge.set_quality_throttle(heat()).await.unwrap().settings;

    assert_eq!(retried.quality_throttle, heat());
    assert_eq!(last_scale(&engine), (SceneHandle::new(1), PROFILE_SCALE));
    assert_eq!(
        last_fps(&engine),
        (SceneHandle::new(1), PROFILE_FPS),
        "the request that failed halfway has to be fully applied by asking again"
    );
}

#[tokio::test]
async fn a_throttle_is_not_saved_and_a_new_bridge_starts_without_one() {
    let root = tempfile::tempdir().unwrap();
    let engine = FakeEngineFacade::default();
    let _release = EngineRelease::of(&engine);
    engine.set_snapshot(vec![display(7, Some(1))]);
    let bridge = BridgeBuilder::new(engine.clone())
        .with_config_store(ConfigStore::open(root.path().to_path_buf()))
        .build()
        .unwrap();
    bridge.set_frame_rate_cap(Some(50)).await.unwrap();
    let saved = fs::read(root.path().join("config.toml")).unwrap();

    bridge.set_quality_throttle(heat()).await.unwrap();
    assert_eq!(
        fs::read(root.path().join("config.toml")).unwrap(),
        saved,
        "a throttle is not a setting"
    );
    bridge.set_quality_throttle(Vec::new()).await.unwrap();
    assert_eq!(fs::read(root.path().join("config.toml")).unwrap(), saved);

    bridge.set_quality_throttle(heat()).await.unwrap();
    let engine = FakeEngineFacade::default();
    let _reopened_release = EngineRelease::of(&engine);
    engine.set_snapshot(vec![display(7, Some(1))]);
    let reopened = BridgeBuilder::new(engine)
        .with_config_store(ConfigStore::open(root.path().to_path_buf()))
        .build()
        .unwrap();
    let snapshot = settings(&reopened).await;
    assert!(snapshot.quality_throttle.is_empty());
    assert_eq!(
        snapshot.effective_frame_rate_cap,
        Some(50),
        "only the saved cap is in force after a restart"
    );
    assert_eq!(snapshot.render_scale, 1.0);
}

/// A scene, a web page and a plain video side by side, none of them with a
/// live renderer handle of its own to be told: what they run at has to be in
/// the descriptors they are opened or handed with.
#[tokio::test]
async fn new_scenes_and_every_host_descriptor_follow_the_throttle() {
    let temp = tempfile::tempdir().unwrap();
    let engine = FakeEngineFacade::default();
    let _release = EngineRelease::of(&engine);
    engine.set_snapshot(vec![display(7, None), display(8, None), display(9, None)]);
    let bridge = bridge_with(&engine, &temp);
    bridge.set_video_backend("native_preferred".into()).await.unwrap();
    bridge.set_render_scale(0.9).await.unwrap();
    bridge.set_quality_throttle(heat()).await.unwrap();

    // A wallpaper applied under the throttle opens at the throttled quality.
    commit(&bridge, "100", SCENE, "7").await;
    commit(&bridge, "300", WEB, "8").await;
    commit(&bridge, "400", CLIP, "9").await;
    assert_eq!(
        engine.rendered_scenes()[0].fps, PROFILE_FPS,
        "a scene opens at its descriptor's rate, so the descriptor carries the ceiling"
    );
    assert_eq!(
        last_scale(&engine).1,
        PROFILE_SCALE,
        "the newly opened scene has to be told the throttled scale"
    );

    // A web page gets the throttled scale, and never a higher one.
    let page = bridge.web_wallpapers().await.unwrap();
    assert_eq!(page[0].render_scale, PROFILE_SCALE);
    assert_eq!(page[0].fps, PROFILE_FPS);
    bridge.set_render_scale(0.5).await.unwrap();
    let below = bridge.web_wallpapers().await.unwrap();
    assert_eq!(
        below[0].render_scale, 0.5,
        "a page the user already runs below the profile is not raised to it"
    );

    // The lock screen and the screen saver play at the same ceiling.
    let exported = bridge.lock_screen_scenes().await.unwrap();
    assert!(
        exported.iter().all(|row| row.fps == PROFILE_FPS),
        "{:?}",
        exported.iter().map(|row| (row.display_id, row.fps)).collect::<Vec<_>>()
    );

    // The native player is judged against the same target rate.
    let at_throttle = bridge.native_video_wallpapers().await.unwrap();
    assert_eq!(at_throttle[0].admission_fps, PROFILE_FPS);

    // Clearing hands every descriptor the user's own values back.
    bridge.set_quality_throttle(Vec::new()).await.unwrap();
    let restored = bridge.web_wallpapers().await.unwrap();
    assert_eq!(restored[0].render_scale, 0.5);
    assert_eq!(restored[0].fps, 60);
    assert!(
        bridge
            .lock_screen_scenes()
            .await
            .unwrap()
            .iter()
            .all(|row| row.fps == 60)
    );
    let at_full = bridge.native_video_wallpapers().await.unwrap();
    assert_eq!(at_full[0].admission_fps, 60);
    assert_ne!(
        at_full[0].admission_key, at_throttle[0].admission_key,
        "the target rate is part of what the host judges, so it is part of the key"
    );

    // A refusal recorded for one rate does not outlive that rate: the native
    // player is offered the clip again, and the engine lets go of it.
    bridge
        .reject_native_video("400".into(), at_full[0].admission_key, "refused at 60".into())
        .await
        .unwrap();
    assert!(bridge.native_video_wallpapers().await.unwrap().is_empty());
    assert!(
        engine
            .rendered_scenes()
            .iter()
            .any(|scene| scene.scene_path.contains("/400/")),
        "a refused clip plays in the scene engine"
    );
    bridge.set_quality_throttle(heat()).await.unwrap();
    // Before the host polls: the change itself has to hand the clip back.
    assert!(
        !engine
            .rendered_scenes()
            .iter()
            .any(|scene| scene.scene_path.contains("/400/")),
        "the refusal described a rate that is no longer the target"
    );
    assert_eq!(
        bridge.native_video_wallpapers().await.unwrap()[0].admission_fps,
        PROFILE_FPS
    );
}

/// A scene on display 7 and a clip on display 9 that the native player was
/// offered at the display's own 60 fps and refused, so the scene engine plays
/// it. The scene's handle is live, so a quality change reaches a renderer and
/// can be refused by it.
async fn clip_refused_at_full_rate() -> (FakeEngineFacade, crate::api::WallpaperBridge, Scratch) {
    let temp = tempfile::tempdir().unwrap();
    let engine = FakeEngineFacade::default();
    let release = EngineRelease::of(&engine);
    engine.set_snapshot(vec![display(7, Some(1)), display(9, None)]);
    let bridge = bridge_with(&engine, &temp);
    bridge.set_video_backend("native_preferred".into()).await.unwrap();
    commit(&bridge, "100", SCENE, "7").await;
    commit(&bridge, "400", CLIP, "9").await;
    refuse_clip(&bridge, &engine, 60).await;
    (
        engine,
        bridge,
        Scratch {
            _release: release,
            _folder: temp,
        },
    )
}

/// The host judges the clip against the target rate in force and cannot
/// honour it, so the scene engine has to be playing it.
async fn refuse_clip(
    bridge: &crate::api::WallpaperBridge,
    engine: &FakeEngineFacade,
    expected_fps: u32,
) {
    let offered = bridge.native_video_wallpapers().await.unwrap();
    assert_eq!(offered.len(), 1, "the clip is offered to the native player");
    assert_eq!(offered[0].admission_fps, expected_fps);
    bridge
        .reject_native_video("400".into(), offered[0].admission_key, "refused".into())
        .await
        .unwrap();
    assert!(plays_in_scene_engine(engine), "a refused clip plays in the scene engine");
}

fn plays_in_scene_engine(engine: &FakeEngineFacade) -> bool {
    engine
        .rendered_scenes()
        .iter()
        .any(|scene| scene.scene_path.contains("/400/"))
}

/// A request that moved the ceiling and failed halfway has already changed
/// what it asked for when it is repeated, so the repeat cannot find the change
/// by comparing before with after.
#[tokio::test]
async fn a_clip_is_handed_back_when_the_throttle_that_refused_it_failed_halfway_and_is_asked_again() {
    let (engine, bridge, _scratch) = clip_refused_at_full_rate().await;

    engine.fail_next_render_scale();
    bridge
        .set_quality_throttle(heat())
        .await
        .expect_err("the renderer refused the new scale");
    bridge.set_quality_throttle(heat()).await.unwrap();

    assert!(
        !plays_in_scene_engine(&engine),
        "the refusal described a rate that is no longer the target, so the engine lets go of the clip"
    );
    let offered = bridge.native_video_wallpapers().await.unwrap();
    assert_eq!(offered[0].admission_fps, PROFILE_FPS);
}

#[tokio::test]
async fn a_clip_is_handed_back_when_the_hand_back_itself_failed() {
    let (engine, bridge, _scratch) = clip_refused_at_full_rate().await;

    // The throttle takes effect and the scene list cannot be rebuilt, so the
    // refusal is gone and the engine still plays the clip.
    engine.fail_reconcile_with("the engine is busy");
    bridge
        .set_quality_throttle(heat())
        .await
        .expect_err("the scene list could not be rebuilt");
    assert!(plays_in_scene_engine(&engine));
    engine.clear_reconcile_failure();

    // There is no refusal left to drop, yet the host must not be offered a
    // clip the engine still plays.
    let offered = bridge.native_video_wallpapers().await.unwrap();

    assert_eq!(offered.len(), 1);
    assert!(
        !plays_in_scene_engine(&engine),
        "the engine let go of the clip before the native player was offered it"
    );
}

/// Every change that moves the ceiling ends in the same place, so a refusal
/// recorded at the old ceiling is released whichever of them moved it, without
/// waiting for the host to ask what to play.
#[tokio::test]
async fn editing_the_reduced_frame_rate_under_a_throttle_hands_a_refused_clip_back() {
    let (engine, bridge, _scratch) = clip_refused_at_full_rate().await;
    bridge.set_quality_throttle(heat()).await.unwrap();
    assert!(!plays_in_scene_engine(&engine), "the throttle moved the ceiling to 30");
    refuse_clip(&bridge, &engine, PROFILE_FPS).await;

    bridge.set_battery_quality_profile(PROFILE_SCALE, 45).await.unwrap();

    assert!(
        !plays_in_scene_engine(&engine),
        "'Frame rate when reduced' moved the ceiling the throttle holds"
    );
}

#[tokio::test]
async fn leaving_reduced_quality_on_battery_hands_a_refused_clip_back() {
    let (engine, bridge, _scratch) = clip_refused_at_full_rate().await;
    bridge.set_battery_mode(BridgeBatteryMode::ReducedQuality).await.unwrap();
    bridge.set_power_source_for_test(PowerSource::Battery).await;
    assert!(!plays_in_scene_engine(&engine), "the profile moved the ceiling to 30");
    refuse_clip(&bridge, &engine, PROFILE_FPS).await;

    bridge.set_battery_mode(BridgeBatteryMode::KeepRunning).await.unwrap();

    assert!(!plays_in_scene_engine(&engine), "leaving the mode lifted the ceiling");
}

#[tokio::test]
async fn plugging_in_while_reduced_quality_is_chosen_hands_a_refused_clip_back() {
    let (engine, bridge, _scratch) = clip_refused_at_full_rate().await;
    bridge.set_battery_mode(BridgeBatteryMode::ReducedQuality).await.unwrap();
    bridge.set_power_source_for_test(PowerSource::Battery).await;
    refuse_clip(&bridge, &engine, PROFILE_FPS).await;

    bridge.set_power_source_for_test(PowerSource::External).await;

    assert!(!plays_in_scene_engine(&engine), "the power source lifted the ceiling");
}

#[tokio::test]
async fn the_users_own_frame_rate_cap_hands_a_refused_clip_back() {
    let (engine, bridge, _scratch) = clip_refused_at_full_rate().await;

    bridge.set_frame_rate_cap(Some(30)).await.unwrap();

    assert!(!plays_in_scene_engine(&engine), "the cap moved the ceiling to 30");
}
