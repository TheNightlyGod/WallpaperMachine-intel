//! A wallpaper's position on one display: moved live, saved at once, never a
//! draft.
//!
//! The renderer is the fake engine, so what these tests establish is what the
//! bridge asks of the engine and what it keeps; how a position looks on a real
//! display is not covered.

use std::{
    path::{Path, PathBuf},
    sync::Arc,
};

use wallpaper_core::{
    DisplayDesc, DisplayIdentity, DisplaySnapshotEntry, WallpaperAssignment,
    project::{SceneDesc, SceneFraming, SceneHandle, SceneTemplate},
};

use crate::{
    BridgeDisplayMode, BridgeErrorKind, BridgeFraming, BridgeLockScreenScene, WallpaperBridge,
    api::BridgeBuilder,
    config::ConfigStore,
    engine::{EngineFacade as _, FakeEngineFacade},
    paths::BridgePaths,
};

/// A fake engine, and what lets go of it when the test ends.
///
/// The bridge registers a callback with its engine that holds the bridge's actor
/// and its runtime, and the engine is held by that actor in turn, so a test
/// bridge that is merely dropped keeps its twenty or so threads until the whole
/// test process exits. The bridge tests are already a few hundred threads short
/// of the limit a process has, so a test that builds bridges has to break that
/// loop itself.
pub(super) fn new_engine() -> (FakeEngineFacade, EngineRelease) {
    let engine = FakeEngineFacade::default();
    let release = EngineRelease(engine.clone());
    (engine, release)
}

pub(super) struct EngineRelease(FakeEngineFacade);

impl Drop for EngineRelease {
    fn drop(&mut self) {
        self.0.set_first_frame_callback(Arc::new(|_| {}));
    }
}

pub(super) fn identified_display(display_id: u32) -> DisplaySnapshotEntry {
    let identity = DisplayIdentity {
        uuid: Some(format!("display-{display_id}")),
        vendor_id: Some(10),
        model_id: Some(display_id),
        serial_number: Some(100 + display_id),
        unit_number: Some(display_id),
        name: Some(format!("Display {display_id}")),
    };
    DisplaySnapshotEntry {
        identity: identity.clone(),
        desc: DisplayDesc::with_identity(display_id, identity, 0, 0, 1920, 1080, 2.0)
            .with_refresh_rate(60),
        handle: None,
        accepts_pointer_input: false,
        paused: false,
        window_active: true,
        assignment: None,
    }
}

/// What the engine reports once it runs `scenes`: the fake hands out handles by
/// position, and every running scene carries the descriptor it was opened with.
pub(super) fn running(scenes: &[SceneDesc]) -> Vec<DisplaySnapshotEntry> {
    scenes
        .iter()
        .enumerate()
        .map(|(index, scene)| DisplaySnapshotEntry {
            identity: scene.display.identity.clone(),
            desc: scene.display.clone(),
            handle: Some(SceneHandle::new(index as u64 + 1)),
            accepts_pointer_input: true,
            paused: false,
            window_active: true,
            assignment: Some(WallpaperAssignment::Direct(SceneTemplate::from_scene_desc(
                scene,
            ))),
        })
        .collect()
}

/// Wallpaper `100` applied to each of `display_ids` through the same calls the
/// panel makes, and running: the first display holds handle 1, the next 2.
async fn shown_on(
    engine: &FakeEngineFacade,
    display_ids: &[u32],
) -> (WallpaperBridge, tempfile::TempDir) {
    let root = tempfile::tempdir().unwrap();
    engine.set_snapshot(
        display_ids
            .iter()
            .map(|&id| identified_display(id))
            .collect(),
    );
    let bridge = BridgeBuilder::new(engine.clone())
        .with_config_store(ConfigStore::open(root.path().to_path_buf()))
        .with_mouse_polling_enabled(false)
        .with_power_watching_enabled(false)
        .build()
        .expect("tokio runtime and config load for wallpaper bridge");
    bridge
        .inject_scene_wallpaper_config_for_test("100", "Scene")
        .await;
    for id in display_ids {
        bridge
            .set_display_config_enabled("100".into(), id.to_string(), true)
            .await
            .unwrap();
    }
    bridge
        .apply_wallpaper_options("100".into(), true)
        .await
        .unwrap();
    assert_eq!(engine.rendered_scenes().len(), display_ids.len());
    engine.set_snapshot(running(&engine.rendered_scenes()));
    (bridge, root)
}

/// The scenes a second launch opens from what the first one saved.
async fn scenes_after_restart(root: &Path, display_ids: &[u32]) -> Vec<SceneDesc> {
    let (engine, _release) = new_engine();
    engine.set_snapshot(
        display_ids
            .iter()
            .map(|&id| identified_display(id))
            .collect(),
    );
    let store = ConfigStore::open(root.to_path_buf());
    let saved = store.load_wallpaper("100").unwrap();
    let bridge = BridgeBuilder::new(engine.clone())
        .with_config_store(store)
        .with_mouse_polling_enabled(false)
        .with_power_watching_enabled(false)
        .build()
        .expect("tokio runtime and config load for wallpaper bridge");
    bridge
        .inject_scene_wallpaper_config_for_test("100", "Scene")
        .await;
    bridge.replace_wallpaper_config_for_test("100", saved).await;
    bridge.refresh_displays().await.unwrap();
    engine
        .calls()
        .first()
        .cloned()
        .expect("the restart opens the wallpaper")
}

fn framing(pan_x: f64, pan_y: f64) -> SceneFraming {
    SceneFraming { pan_x, pan_y }
}

fn on_display(scenes: &[SceneDesc], display_id: u32) -> &SceneDesc {
    scenes
        .iter()
        .find(|scene| scene.display.display_id == display_id)
        .unwrap_or_else(|| panic!("no scene for display {display_id}"))
}

fn wallpaper_file(root: &Path) -> PathBuf {
    root.join("wallpapers").join("100.json")
}

async fn move_to(
    bridge: &WallpaperBridge,
    pan_x: Option<f64>,
    pan_y: Option<f64>,
) -> Result<(), crate::BridgeError> {
    bridge
        .set_display_position("100".into(), "1".into(), pan_x, pan_y)
        .await
        .map(|_| ())
}

#[tokio::test]
async fn a_position_moves_the_live_scene_without_reopening_it_and_survives_a_restart() {
    let (engine, _release) = new_engine();
    let (bridge, root) = shown_on(&engine, &[1]).await;
    let reconciles = engine.calls().len();

    move_to(&bridge, Some(0.2), Some(0.8)).await.unwrap();

    assert_eq!(
        engine.framing_calls(),
        vec![(SceneHandle::new(1), framing(0.2, 0.8))],
        "the scene on that display is told once"
    );
    bridge.refresh_displays().await.unwrap();
    assert_eq!(
        engine.calls().len(),
        reconciles,
        "the running scene already is where the config says, so nothing reopens it"
    );

    let scenes = scenes_after_restart(root.path(), &[1]).await;
    assert_eq!(on_display(&scenes, 1).framing, framing(0.2, 0.8));
}

#[tokio::test]
async fn saying_the_same_position_again_neither_writes_nor_asks_the_engine() {
    let (engine, _release) = new_engine();
    let (bridge, root) = shown_on(&engine, &[1]).await;
    move_to(&bridge, Some(0.2), Some(0.8)).await.unwrap();
    let file = wallpaper_file(root.path());
    std::fs::remove_file(&file).unwrap();

    move_to(&bridge, Some(0.2), Some(0.8)).await.unwrap();
    move_to(&bridge, Some(0.2), None).await.unwrap();
    move_to(&bridge, None, Some(0.8)).await.unwrap();

    assert_eq!(engine.framing_calls().len(), 1);
    assert!(
        !file.exists(),
        "a position already held is not written again"
    );

    // The same holds for a display nobody ever positioned being told to stay
    // in the middle.
    let (engine, _release) = new_engine();
    let (bridge, root) = shown_on(&engine, &[1]).await;
    let file = wallpaper_file(root.path());
    std::fs::remove_file(&file).unwrap();

    move_to(&bridge, Some(0.5), Some(0.5)).await.unwrap();

    assert!(engine.framing_calls().is_empty());
    assert!(!file.exists());
}

#[tokio::test]
async fn an_axis_left_out_keeps_its_saved_value() {
    let (engine, _release) = new_engine();
    let (bridge, root) = shown_on(&engine, &[1]).await;

    move_to(&bridge, Some(0.1), Some(0.9)).await.unwrap();
    move_to(&bridge, Some(0.4), None).await.unwrap();
    move_to(&bridge, None, Some(0.0)).await.unwrap();

    let handle = SceneHandle::new(1);
    assert_eq!(
        engine.framing_calls(),
        vec![
            (handle, framing(0.1, 0.9)),
            (handle, framing(0.4, 0.9)),
            (handle, framing(0.4, 0.0)),
        ]
    );
    let scenes = scenes_after_restart(root.path(), &[1]).await;
    assert_eq!(on_display(&scenes, 1).framing, framing(0.4, 0.0));
}

#[tokio::test]
async fn naming_neither_axis_changes_nothing() {
    let (engine, _release) = new_engine();
    let (bridge, root) = shown_on(&engine, &[1]).await;
    move_to(&bridge, Some(0.3), Some(0.6)).await.unwrap();
    let file = wallpaper_file(root.path());
    std::fs::remove_file(&file).unwrap();

    move_to(&bridge, None, None).await.unwrap();

    assert_eq!(engine.framing_calls().len(), 1);
    assert!(!file.exists());
}

#[tokio::test]
async fn a_position_outside_the_display_is_refused_whole() {
    let (engine, _release) = new_engine();
    let (bridge, root) = shown_on(&engine, &[1]).await;
    move_to(&bridge, Some(0.25), Some(0.75)).await.unwrap();
    let file = wallpaper_file(root.path());
    let saved = std::fs::read(&file).unwrap();

    for bad in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY, -0.01, 1.01] {
        for (pan_x, pan_y) in [(Some(bad), None), (None, Some(bad)), (Some(0.9), Some(bad))] {
            let error = move_to(&bridge, pan_x, pan_y).await.unwrap_err();
            assert_eq!(
                error.kind(),
                BridgeErrorKind::InvalidInput,
                "{pan_x:?},{pan_y:?}"
            );
        }
    }

    assert_eq!(engine.framing_calls().len(), 1, "the engine heard nothing");
    assert_eq!(
        std::fs::read(&file).unwrap(),
        saved,
        "a refused position leaves the file alone, the good axis of a pair included"
    );
    // The edges themselves are positions.
    move_to(&bridge, Some(0.0), Some(1.0)).await.unwrap();
    assert_eq!(
        engine.framing_calls().last().map(|call| call.1),
        Some(framing(0.0, 1.0))
    );
}

#[tokio::test]
async fn an_unknown_display_or_wallpaper_is_an_error_and_saves_nothing() {
    let (engine, _release) = new_engine();
    let (bridge, root) = shown_on(&engine, &[1]).await;
    let file = wallpaper_file(root.path());
    let saved = std::fs::read(&file).unwrap();

    let display = bridge
        .set_display_position("100".into(), "99".into(), Some(0.1), Some(0.1))
        .await
        .unwrap_err();
    let wallpaper = bridge
        .set_display_position("404".into(), "1".into(), Some(0.1), Some(0.1))
        .await
        .unwrap_err();

    assert_eq!(display.kind(), BridgeErrorKind::InvalidInput);
    assert_eq!(wallpaper.kind(), BridgeErrorKind::InvalidInput);
    assert!(engine.framing_calls().is_empty());
    assert_eq!(std::fs::read(&file).unwrap(), saved);
    assert!(!root.path().join("wallpapers").join("404.json").exists());
}

#[tokio::test]
async fn a_position_is_not_a_draft_so_cancel_keeps_it_and_apply_does_not_reopen() {
    let (engine, _release) = new_engine();
    let (bridge, root) = shown_on(&engine, &[1]).await;
    let reconciles = engine.calls().len();

    // An unapplied scale factor is still a draft, and Cancel still undoes it.
    bridge
        .edit_scaling_factor("100".into(), "1".into(), 1.5)
        .await
        .unwrap();
    move_to(&bridge, Some(0.2), Some(0.8)).await.unwrap();
    bridge.cancel_wallpaper_options("100".into()).await.unwrap();

    assert_eq!(
        engine.scaling_factor_calls().last().map(|call| call.1),
        Some(1.0),
        "Cancel put the live scale factor back"
    );
    assert_eq!(
        engine.framing_calls().len(),
        1,
        "and left the position alone"
    );
    let scenes = scenes_after_restart(root.path(), &[1]).await;
    assert_eq!(on_display(&scenes, 1).framing, framing(0.2, 0.8));
    assert!((on_display(&scenes, 1).scaling_factor - 1.0).abs() <= f64::EPSILON);

    // With nothing else pending, Apply has no scene to reopen.
    bridge
        .apply_wallpaper_options("100".into(), true)
        .await
        .unwrap();
    assert_eq!(engine.calls().len(), reconciles);
    let scenes = scenes_after_restart(root.path(), &[1]).await;
    assert_eq!(on_display(&scenes, 1).framing, framing(0.2, 0.8));
}

#[tokio::test]
async fn applying_another_change_opens_the_scene_at_the_position() {
    let (engine, _release) = new_engine();
    let (bridge, root) = shown_on(&engine, &[1]).await;
    let mut snapshot = running(&engine.rendered_scenes());
    snapshot.push(identified_display(2));
    engine.set_snapshot(snapshot);
    let reconciles = engine.calls().len();
    move_to(&bridge, Some(0.2), Some(0.8)).await.unwrap();

    // Showing the wallpaper on a second display is a change Apply must carry
    // out, and it rebuilds the scenes from the saved config.
    bridge
        .set_display_config_enabled("100".into(), "2".into(), true)
        .await
        .unwrap();
    bridge
        .apply_wallpaper_options("100".into(), true)
        .await
        .unwrap();

    assert_eq!(engine.calls().len(), reconciles + 1);
    let reopened = engine.calls().pop().unwrap();
    assert_eq!(on_display(&reopened, 1).framing, framing(0.2, 0.8));
    assert_eq!(on_display(&reopened, 2).framing, SceneFraming::default());
    let scenes = scenes_after_restart(root.path(), &[1, 2]).await;
    assert_eq!(on_display(&scenes, 1).framing, framing(0.2, 0.8));
}

#[tokio::test]
async fn a_renderer_that_refuses_the_move_still_leaves_it_saved_for_the_next_reconcile() {
    let (engine, _release) = new_engine();
    let (bridge, root) = shown_on(&engine, &[1]).await;
    let reconciles = engine.calls().len();
    engine.fail_next_framing();

    let error = move_to(&bridge, Some(0.2), Some(0.8)).await.unwrap_err();

    assert_eq!(error.kind(), BridgeErrorKind::Engine);
    let scenes = scenes_after_restart(root.path(), &[1]).await;
    assert_eq!(
        on_display(&scenes, 1).framing,
        framing(0.2, 0.8),
        "the choice was kept"
    );
    // The running scene is still where it was, so the next reconcile does not
    // find it matching and builds it at the saved position.
    bridge.refresh_displays().await.unwrap();
    assert_eq!(engine.calls().len(), reconciles + 1);
    let reopened = engine.calls().pop().unwrap();
    assert_eq!(on_display(&reopened, 1).framing, framing(0.2, 0.8));
}

#[tokio::test]
async fn a_position_that_could_not_be_saved_is_saved_when_asked_for_again() {
    let (engine, _release) = new_engine();
    let (bridge, root) = shown_on(&engine, &[1]).await;
    // A file where the wallpapers folder should be: nothing can be written.
    let folder = root.path().join("wallpapers");
    std::fs::remove_dir_all(&folder).unwrap();
    std::fs::write(&folder, b"not a folder").unwrap();

    let error = move_to(&bridge, Some(0.2), Some(0.8)).await.unwrap_err();

    assert_ne!(error.kind(), BridgeErrorKind::InvalidInput);
    assert!(
        engine.framing_calls().is_empty(),
        "nothing was kept, so nothing moved"
    );

    std::fs::remove_file(&folder).unwrap();
    move_to(&bridge, Some(0.2), Some(0.8)).await.unwrap();

    assert_eq!(
        engine.framing_calls(),
        vec![(SceneHandle::new(1), framing(0.2, 0.8))]
    );
    let scenes = scenes_after_restart(root.path(), &[1]).await;
    assert_eq!(on_display(&scenes, 1).framing, framing(0.2, 0.8));
}

#[tokio::test]
async fn each_display_keeps_its_own_position() {
    let (engine, _release) = new_engine();
    let (bridge, root) = shown_on(&engine, &[1, 2]).await;

    bridge
        .set_display_position("100".into(), "2".into(), Some(0.0), Some(1.0))
        .await
        .unwrap();

    assert_eq!(
        engine.framing_calls(),
        vec![(SceneHandle::new(2), framing(0.0, 1.0))],
        "only the scene on that display moves"
    );
    let scenes = scenes_after_restart(root.path(), &[1, 2]).await;
    assert_eq!(on_display(&scenes, 2).framing, framing(0.0, 1.0));
    assert_eq!(
        on_display(&scenes, 1).framing,
        SceneFraming::default(),
        "the other display stays centred"
    );
}

#[tokio::test]
async fn a_wallpaper_nobody_shows_can_still_be_positioned_for_later() {
    let (engine, _release) = new_engine();
    let (bridge, root) = shown_on(&engine, &[1, 2]).await;
    bridge
        .set_display_config_enabled("100".into(), "2".into(), false)
        .await
        .unwrap();
    bridge
        .apply_wallpaper_options("100".into(), true)
        .await
        .unwrap();
    assert_eq!(engine.rendered_scenes().len(), 1);
    let mut snapshot = running(&engine.rendered_scenes());
    snapshot.push(identified_display(2));
    engine.set_snapshot(snapshot);

    bridge
        .set_display_position("100".into(), "2".into(), Some(0.9), None)
        .await
        .unwrap();

    assert!(
        engine.framing_calls().is_empty(),
        "no scene runs there, so there is nobody to tell"
    );
    bridge
        .set_display_config_enabled("100".into(), "2".into(), true)
        .await
        .unwrap();
    bridge
        .apply_wallpaper_options("100".into(), true)
        .await
        .unwrap();
    let reopened = engine.rendered_scenes();
    assert_eq!(on_display(&reopened, 2).framing, framing(0.9, 0.5));
    let scenes = scenes_after_restart(root.path(), &[1, 2]).await;
    assert_eq!(on_display(&scenes, 2).framing, framing(0.9, 0.5));
}

fn reported(pan_x: f64, pan_y: f64) -> BridgeFraming {
    BridgeFraming { pan_x, pan_y }
}

/// What the options snapshot says about each display, in the order it lists them.
async fn option_rows(bridge: &WallpaperBridge) -> Vec<(BridgeFraming, bool)> {
    bridge
        .wallpaper_options_snapshot("100".into())
        .await
        .unwrap()
        .display_configurations
        .iter()
        .map(|row| (row.framing, row.can_restore_defaults))
        .collect()
}

#[tokio::test]
async fn the_options_report_each_displays_position_and_offer_to_restore_it() {
    let (engine, _release) = new_engine();
    let (bridge, _root) = shown_on(&engine, &[1, 2]).await;
    assert_eq!(
        option_rows(&bridge).await,
        vec![(reported(0.5, 0.5), false), (reported(0.5, 0.5), false)],
        "a display nobody positioned is centred and has nothing to restore"
    );

    let moved = bridge
        .set_display_position("100".into(), "2".into(), Some(0.2), Some(0.8))
        .await
        .unwrap();

    let expected = vec![(reported(0.5, 0.5), false), (reported(0.2, 0.8), true)];
    assert_eq!(option_rows(&bridge).await, expected);
    assert_eq!(
        moved
            .wallpaper_options
            .display_configurations
            .iter()
            .map(|row| (row.framing, row.can_restore_defaults))
            .collect::<Vec<_>>(),
        expected,
        "the reply to the move already carries it, so the app need not ask again"
    );

    move_to_display(&bridge, "2", 0.5, 0.5).await;
    assert_eq!(
        option_rows(&bridge).await,
        vec![(reported(0.5, 0.5), false), (reported(0.5, 0.5), false)],
        "moving back to the middle leaves nothing to restore"
    );
}

async fn move_to_display(bridge: &WallpaperBridge, display: &str, pan_x: f64, pan_y: f64) {
    bridge
        .set_display_position("100".into(), display.into(), Some(pan_x), Some(pan_y))
        .await
        .unwrap();
}

#[tokio::test]
async fn the_options_report_the_position_a_restart_loads() {
    let (engine, _release) = new_engine();
    let (bridge, root) = shown_on(&engine, &[1]).await;
    move_to(&bridge, Some(0.35), Some(0.65)).await.unwrap();

    let (engine, _release) = new_engine();
    engine.set_snapshot(vec![identified_display(1)]);
    let store = ConfigStore::open(root.path().to_path_buf());
    let saved = store.load_wallpaper("100").unwrap();
    let reopened = BridgeBuilder::new(engine)
        .with_config_store(store)
        .with_mouse_polling_enabled(false)
        .with_power_watching_enabled(false)
        .build()
        .unwrap();
    reopened
        .inject_scene_wallpaper_config_for_test("100", "Scene")
        .await;
    reopened
        .replace_wallpaper_config_for_test("100", saved)
        .await;
    reopened
        .set_display_config_enabled("100".into(), "1".into(), true)
        .await
        .unwrap();

    assert_eq!(
        option_rows(&reopened).await,
        vec![(reported(0.35, 0.65), true)]
    );
}

/// A scene on display 1, a video on 2 and a web page on 3, display 4 mirroring
/// display 1, with the video player preferred, so the desktop plays the video
/// itself while the lock screen is handed the same wallpapers as scenes.
async fn shown_in_every_kind(engine: &FakeEngineFacade) -> (WallpaperBridge, tempfile::TempDir) {
    let temp = tempfile::tempdir().unwrap();
    let paths = BridgePaths::for_home(temp.path().to_path_buf());
    let clip = paths.steam_workshop_root().join("400");
    std::fs::create_dir_all(&clip).unwrap();
    std::fs::write(
        clip.join("clip.mp4"),
        b"presence is all the native player checks",
    )
    .unwrap();
    engine.set_snapshot((1..=4).map(identified_display).collect());
    let bridge = BridgeBuilder::new(engine.clone())
        .with_state(crate::actor::state::BridgeActorState::default())
        .with_paths(paths)
        .with_mouse_polling_enabled(false)
        .with_power_watching_enabled(false)
        .build()
        .unwrap();
    bridge
        .set_video_backend("native_preferred".into())
        .await
        .unwrap();
    for (id, title, project, display) in [
        (
            "100",
            "Scene",
            r#"{"type":"scene","file":"scene.pkg"}"#,
            "1",
        ),
        ("400", "Clip", r#"{"type":"video","file":"clip.mp4"}"#, "2"),
        ("300", "Web", r#"{"type":"web","file":"index.html"}"#, "3"),
    ] {
        bridge
            .inject_scene_project_for_test(id, title, project)
            .await;
        bridge
            .inject_scene_wallpaper_config_for_test(id, title)
            .await;
        bridge
            .set_display_config_enabled(id.into(), display.into(), true)
            .await
            .unwrap();
        bridge
            .apply_wallpaper_options(id.into(), true)
            .await
            .unwrap();
    }
    bridge
        .set_display_mode("4".into(), BridgeDisplayMode::Mirror)
        .await
        .unwrap();
    bridge
        .set_mirror_target("4".into(), "1".into())
        .await
        .unwrap();
    (bridge, temp)
}

fn exported(rows: &[BridgeLockScreenScene], display_id: u32) -> &BridgeLockScreenScene {
    rows.iter()
        .find(|row| row.display_id == display_id)
        .unwrap_or_else(|| panic!("nothing exported for display {display_id}"))
}

#[tokio::test]
async fn the_lock_screen_export_carries_each_displays_saved_position() {
    let (engine, _release) = new_engine();
    let (bridge, _temp) = shown_in_every_kind(&engine).await;
    let centred = bridge.lock_screen_scenes().await.unwrap();
    assert_eq!(centred.len(), 4);
    assert!(
        centred.iter().all(|row| row.framing == reported(0.5, 0.5)),
        "nothing was moved, so everything is exported centred"
    );
    assert_eq!(
        bridge.native_video_wallpapers().await.unwrap().len(),
        1,
        "the desktop plays the video itself"
    );

    for (wallpaper, display, pan_x, pan_y) in [
        ("100", "1", 0.2, 0.8),
        ("400", "2", 0.9, 0.1),
        ("300", "3", 0.3, 0.3),
    ] {
        bridge
            .set_display_position(wallpaper.into(), display.into(), Some(pan_x), Some(pan_y))
            .await
            .unwrap();
    }

    let rows = bridge.lock_screen_scenes().await.unwrap();
    assert_eq!(rows.len(), 4);
    assert_eq!(exported(&rows, 1).framing, reported(0.2, 0.8), "a scene");
    assert_eq!(
        exported(&rows, 2).framing,
        reported(0.9, 0.1),
        "a video, which the lock screen plays as a scene however the desktop does"
    );
    assert_eq!(
        exported(&rows, 3).framing,
        reported(0.5, 0.5),
        "a web page fills its window, so it is exported centred even if a position was saved"
    );
    assert_eq!(
        exported(&rows, 4).framing,
        reported(0.5, 0.5),
        "a mirror has its own settings, which carry no position"
    );
}

#[tokio::test]
async fn the_lock_screen_export_follows_a_position_at_once_but_not_an_unapplied_scale() {
    let (engine, _release) = new_engine();
    let (bridge, _temp) = shown_in_every_kind(&engine).await;
    bridge
        .edit_scaling_factor("100".into(), "1".into(), 1.5)
        .await
        .unwrap();
    move_to_display(&bridge, "1", 0.1, 0.9).await;

    let rows = bridge.lock_screen_scenes().await.unwrap();
    assert_eq!(exported(&rows, 1).framing, reported(0.1, 0.9));
    assert!(
        (exported(&rows, 1).scaling_factor - 1.0).abs() <= f64::EPSILON,
        "the scale factor is still a draft, so the lock screen does not have it"
    );

    bridge
        .apply_wallpaper_options("100".into(), true)
        .await
        .unwrap();
    let rows = bridge.lock_screen_scenes().await.unwrap();
    assert_eq!(exported(&rows, 1).framing, reported(0.1, 0.9));
    assert!((exported(&rows, 1).scaling_factor - 1.5).abs() <= f64::EPSILON);
}

async fn preview(
    bridge: &WallpaperBridge,
    pan_x: Option<f64>,
    pan_y: Option<f64>,
) -> Result<(), crate::BridgeError> {
    bridge
        .preview_display_position("100".into(), "1".into(), pan_x, pan_y)
        .await
}

#[tokio::test]
async fn a_preview_moves_the_live_scene_and_keeps_nothing() {
    let (engine, _release) = new_engine();
    let (bridge, root) = shown_on(&engine, &[1]).await;
    let reconciles = engine.calls().len();
    let exported = bridge.lock_screen_scenes().await.unwrap();
    let file = wallpaper_file(root.path());
    std::fs::remove_file(&file).unwrap();

    for pan_x in [0.1, 0.2, 0.3] {
        preview(&bridge, Some(pan_x), Some(0.8)).await.unwrap();
    }

    let handle = SceneHandle::new(1);
    assert_eq!(
        engine.preview_framing_calls(),
        vec![
            (handle, framing(0.1, 0.8)),
            (handle, framing(0.2, 0.8)),
            (handle, framing(0.3, 0.8)),
        ],
        "the scene on that display follows each step"
    );
    assert!(
        engine.framing_calls().is_empty(),
        "no step is a position the scene keeps"
    );
    assert!(!file.exists(), "no step is written");
    assert_eq!(
        bridge.lock_screen_scenes().await.unwrap(),
        exported,
        "the lock screen is not told about a drag"
    );
    assert_eq!(
        option_rows(&bridge).await,
        vec![(reported(0.5, 0.5), false)],
        "the options still say where the wallpaper is saved"
    );
    bridge.refresh_displays().await.unwrap();
    assert_eq!(
        engine.calls().len(),
        reconciles,
        "a drag that was never finished leaves nothing for a reconcile to rebuild"
    );
    let scenes = scenes_after_restart(root.path(), &[1]).await;
    assert_eq!(on_display(&scenes, 1).framing, SceneFraming::default());
}

#[tokio::test]
async fn a_preview_names_one_axis_and_the_other_follows_the_saved_position() {
    let (engine, _release) = new_engine();
    let (bridge, _root) = shown_on(&engine, &[1]).await;
    move_to(&bridge, Some(0.1), Some(0.9)).await.unwrap();

    preview(&bridge, Some(0.4), None).await.unwrap();
    preview(&bridge, None, Some(0.0)).await.unwrap();
    preview(&bridge, None, None).await.unwrap();

    let handle = SceneHandle::new(1);
    assert_eq!(
        engine.preview_framing_calls(),
        vec![
            (handle, framing(0.4, 0.9)),
            (handle, framing(0.1, 0.0)),
            (handle, framing(0.1, 0.9)),
        ],
        "an axis a drag does not move is the saved one, not the last previewed"
    );
}

#[tokio::test]
async fn a_preview_outside_the_display_is_refused_and_shows_nothing() {
    let (engine, _release) = new_engine();
    let (bridge, _root) = shown_on(&engine, &[1]).await;

    for bad in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY, -0.01, 1.01] {
        for (pan_x, pan_y) in [(Some(bad), None), (None, Some(bad)), (Some(0.9), Some(bad))] {
            let error = preview(&bridge, pan_x, pan_y).await.unwrap_err();
            assert_eq!(
                error.kind(),
                BridgeErrorKind::InvalidInput,
                "{pan_x:?},{pan_y:?}"
            );
        }
    }
    let unknown = bridge
        .preview_display_position("404".into(), "1".into(), Some(0.1), Some(0.1))
        .await
        .unwrap_err();
    assert_eq!(unknown.kind(), BridgeErrorKind::InvalidInput);
    assert!(engine.preview_framing_calls().is_empty());

    // The edges themselves are positions.
    preview(&bridge, Some(0.0), Some(1.0)).await.unwrap();
    assert_eq!(
        engine.preview_framing_calls(),
        vec![(SceneHandle::new(1), framing(0.0, 1.0))]
    );
}

#[tokio::test]
async fn a_preview_for_a_display_no_scene_draws_is_not_an_error() {
    let (engine, _release) = new_engine();
    let (bridge, _root) = shown_in_every_kind(&engine).await;
    // Only the scene on display 1 has a handle: the video on 2 is the native
    // player's, and nothing on 3 (a web page) or 4 (a mirror) is a scene a
    // position could move.
    let mut snapshot: Vec<_> = (1..=4).map(identified_display).collect();
    snapshot[0].handle = Some(SceneHandle::new(1));
    engine.set_snapshot(snapshot);

    for (wallpaper, display) in [("400", "2"), ("100", "2"), ("300", "3"), ("100", "99")] {
        bridge
            .preview_display_position(wallpaper.into(), display.into(), Some(0.2), Some(0.2))
            .await
            .unwrap_or_else(|error| panic!("{wallpaper} on {display}: {error:?}"));
    }
    assert!(
        engine.preview_framing_calls().is_empty(),
        "there was nothing to move"
    );

    bridge
        .preview_display_position("100".into(), "1".into(), Some(0.2), Some(0.2))
        .await
        .unwrap();
    assert_eq!(
        engine.preview_framing_calls(),
        vec![(SceneHandle::new(1), framing(0.2, 0.2))],
        "the scene that does run still follows"
    );
}

#[tokio::test]
async fn finishing_a_drag_saves_the_value_and_commits_it_to_the_scene() {
    let (engine, _release) = new_engine();
    let (bridge, root) = shown_on(&engine, &[1]).await;
    let handle = SceneHandle::new(1);

    preview(&bridge, Some(0.1), None).await.unwrap();
    preview(&bridge, Some(0.2), None).await.unwrap();
    move_to(&bridge, Some(0.2), None).await.unwrap();

    assert_eq!(engine.preview_framing_calls().len(), 2);
    assert_eq!(
        engine.framing_calls(),
        vec![(handle, framing(0.2, 0.5))],
        "the release is an ordinary commit, however many steps came before"
    );
    let scenes = scenes_after_restart(root.path(), &[1]).await;
    assert_eq!(on_display(&scenes, 1).framing, framing(0.2, 0.5));

    // The scene now holds the saved position, so saying it again is the
    // ordinary no-op and not another word with the renderer.
    move_to(&bridge, Some(0.2), None).await.unwrap();
    assert_eq!(engine.framing_calls().len(), 1);
}

#[tokio::test]
async fn a_drag_that_ends_where_it_began_puts_the_scene_back_without_saving() {
    let (engine, _release) = new_engine();
    let (bridge, root) = shown_on(&engine, &[1]).await;
    move_to(&bridge, Some(0.3), Some(0.6)).await.unwrap();
    let file = wallpaper_file(root.path());
    std::fs::remove_file(&file).unwrap();
    let handle = SceneHandle::new(1);

    preview(&bridge, Some(0.9), None).await.unwrap();
    // The release is at the position the wallpaper already had.
    move_to(&bridge, Some(0.3), None).await.unwrap();

    assert_eq!(
        engine.framing_calls(),
        vec![(handle, framing(0.3, 0.6)), (handle, framing(0.3, 0.6))],
        "the scene was showing the last step, so the saved position is told to it again"
    );
    assert!(!file.exists(), "and nothing changed, so nothing is written");

    // Once back, the same position again is the ordinary no-op.
    move_to(&bridge, Some(0.3), None).await.unwrap();
    assert_eq!(engine.framing_calls().len(), 2);
}

#[tokio::test]
async fn a_scene_that_was_not_previewed_is_not_told_a_position_it_already_has() {
    let (engine, _release) = new_engine();
    let (bridge, _root) = shown_on(&engine, &[1, 2]).await;
    move_to(&bridge, Some(0.3), Some(0.6)).await.unwrap();

    // A drag on the other display must not make this one's repeat count.
    bridge
        .preview_display_position("100".into(), "2".into(), Some(0.9), None)
        .await
        .unwrap();
    move_to(&bridge, Some(0.3), Some(0.6)).await.unwrap();

    assert_eq!(engine.framing_calls().len(), 1);
}

#[tokio::test]
async fn a_refused_release_keeps_the_drag_open_for_the_next_one() {
    let (engine, _release) = new_engine();
    let (bridge, root) = shown_on(&engine, &[1]).await;
    move_to(&bridge, Some(0.3), Some(0.6)).await.unwrap();
    let file = wallpaper_file(root.path());
    std::fs::remove_file(&file).unwrap();
    preview(&bridge, Some(0.9), None).await.unwrap();
    engine.fail_next_framing();

    let error = move_to(&bridge, Some(0.3), None).await.unwrap_err();
    assert_eq!(error.kind(), BridgeErrorKind::Engine);
    move_to(&bridge, Some(0.3), None).await.unwrap();

    assert_eq!(
        engine.framing_calls().len(),
        3,
        "the renderer never took the saved position, so the second release tries again"
    );
}
