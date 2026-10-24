//! Plain local videos and the host's own player.
//!
//! A plain video is played by the host and never by the scene engine: the bridge offers every
//! Video project with a resolvable file as a native descriptor and gives the engine no scene for
//! it, whether or not the file can be found, or the display would decode and present the same
//! content twice. There is no refusal and no hand-off to track: a file the host cannot play is
//! the host's to report.

use std::fs;

use wallpaper_core::{DisplayDesc, DisplayIdentity, DisplaySnapshotEntry};

use crate::{api::BridgeBuilder, engine::FakeEngineFacade, paths::BridgePaths};

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

/// A workshop tree with two video projects whose media files exist (300 and
/// 500), and one whose declared media file does not (400).
fn workshop_with_videos(paths: &BridgePaths) {
    for (id, write_media) in [("300", true), ("400", false), ("500", true)] {
        let dir = paths.steam_workshop_root().join(id);
        fs::create_dir_all(&dir).unwrap();
        fs::write(
            dir.join("project.json"),
            format!(
                r#"{{"type":"video","title":"Clip {id}","file":"clip.mp4","description":""}}"#
            ),
        )
        .unwrap();
        if write_media {
            fs::write(dir.join("clip.mp4"), b"not really a video, only its presence matters")
                .unwrap();
        }
    }
}

async fn video_bridge(
    engine: &FakeEngineFacade,
    temp: &tempfile::TempDir,
) -> crate::api::WallpaperBridge {
    engine.set_snapshot(vec![display_snapshot(7)]);
    let paths = BridgePaths::for_home(temp.path().to_path_buf());
    workshop_with_videos(&paths);
    let bridge = BridgeBuilder::new(engine.clone())
        .with_state(crate::actor::state::BridgeActorState::default())
        .with_paths(paths)
        .build()
        .unwrap();
    bridge
}

async fn commit(bridge: &crate::api::WallpaperBridge, wallpaper: &str, display: &str) {
    // The project model is what the routing reads: the wallpaper config alone
    // says nothing about the project's type or its media file.
    bridge
        .inject_scene_project_for_test(
            wallpaper,
            "Clip",
            &format!(
                r#"{{"type":"video","title":"Clip {wallpaper}","file":"clip.mp4","description":""}}"#
            ),
        )
        .await;
    bridge
        .inject_scene_wallpaper_config_for_test(wallpaper, "Video")
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

fn scene_ids(engine: &FakeEngineFacade) -> Vec<String> {
    engine
        .rendered_scenes()
        .iter()
        .map(|scene| scene.scene_path.clone())
        .collect()
}

/// The admission key the host would judge, read out of the descriptor the bridge offered.
async fn admission_key(bridge: &crate::api::WallpaperBridge, wallpaper: &str) -> u64 {
    bridge
        .native_video_wallpapers()
        .await
        .unwrap()
        .into_iter()
        .find(|row| row.wallpaper_id == wallpaper)
        .expect("the wallpaper has to be offered natively")
        .admission_key
}

async fn is_offered_natively(bridge: &crate::api::WallpaperBridge, wallpaper: &str) -> bool {
    bridge
        .native_video_wallpapers()
        .await
        .unwrap()
        .iter()
        .any(|row| row.wallpaper_id == wallpaper)
}

fn scenes_for(engine: &FakeEngineFacade, wallpaper: &str) -> usize {
    scene_ids(engine)
        .iter()
        .filter(|path| path.contains(wallpaper))
        .count()
}

/// Scenes the engine currently renders for this wallpaper on one display.
fn scenes_on(engine: &FakeEngineFacade, wallpaper: &str, display_id: u32) -> usize {
    engine
        .rendered_scenes()
        .iter()
        .filter(|scene| {
            scene.display.display_id == display_id && scene.scene_path.contains(wallpaper)
        })
        .count()
}

async fn native_display_ids(bridge: &crate::api::WallpaperBridge, wallpaper: &str) -> Vec<u32> {
    let mut ids: Vec<u32> = bridge
        .native_video_wallpapers()
        .await
        .unwrap()
        .iter()
        .filter(|row| row.wallpaper_id == wallpaper)
        .map(|row| row.display_id)
        .collect();
    ids.sort_unstable();
    ids
}

/// Two different clips on two displays, so the two slots have two distinct keys. The key
/// identifies a file; two displays showing the same file share one.
async fn two_display_bridge(
    engine: &FakeEngineFacade,
    temp: &tempfile::TempDir,
) -> crate::api::WallpaperBridge {
    engine.set_snapshot(vec![display_snapshot(7), display_snapshot(9)]);
    let paths = BridgePaths::for_home(temp.path().to_path_buf());
    workshop_with_videos(&paths);
    let bridge = BridgeBuilder::new(engine.clone())
        .with_state(crate::actor::state::BridgeActorState::default())
        .with_paths(paths)
        .build()
        .unwrap();
    commit(&bridge, "300", "7").await;
    commit(&bridge, "500", "9").await;
    bridge
}

/// Retargets the display's frame rate and commits it.
async fn retarget_fps(bridge: &crate::api::WallpaperBridge, wallpaper: &str, display: &str, fps: u32) {
    bridge
        .set_target_fps(wallpaper.into(), display.into(), fps)
        .await
        .unwrap();
    bridge
        .apply_wallpaper_options(wallpaper.into(), true)
        .await
        .unwrap();
}

#[tokio::test]
async fn a_plain_video_is_played_natively_and_never_given_to_the_scene_engine() {
    let temp = tempfile::tempdir().unwrap();
    let engine = FakeEngineFacade::default();
    let bridge = video_bridge(&engine, &temp).await;
    commit(&bridge, "300", "7").await;

    let native = bridge.native_video_wallpapers().await.unwrap();
    assert_eq!(native.len(), 1);
    assert_eq!(native[0].wallpaper_id, "300");
    assert_eq!(native[0].display_id, 7);
    assert!(native[0].media_path.ends_with("clip.mp4"));
    assert_eq!(
        scenes_for(&engine, "300"),
        0,
        "two renderers for one display would decode and present the same clip twice"
    );
}

#[tokio::test]
async fn a_video_whose_media_is_missing_gets_neither_a_window_nor_a_scene() {
    let temp = tempfile::tempdir().unwrap();
    let engine = FakeEngineFacade::default();
    let bridge = video_bridge(&engine, &temp).await;
    commit(&bridge, "400", "7").await;

    assert!(
        bridge.native_video_wallpapers().await.unwrap().is_empty(),
        "a window that can never play is worse than no window"
    );
    assert_eq!(scenes_for(&engine, "400"), 0, "no scene stands in for a file that cannot be found");
    let report = bridge.settings_snapshot().await.unwrap();
    assert_eq!(report.video_backends.len(), 1);
    assert_eq!(
        report.video_backends[0].fallback_reason.as_deref(),
        Some("the project's video file could not be found")
    );
}

#[tokio::test]
async fn the_native_descriptor_carries_the_users_own_settings() {
    let temp = tempfile::tempdir().unwrap();
    let engine = FakeEngineFacade::default();
    let bridge = video_bridge(&engine, &temp).await;
    commit(&bridge, "300", "7").await;

    bridge.set_volume("300".into(), 0.25).await.unwrap();
    bridge.set_muted("300".into(), true).await.unwrap();
    bridge.apply_wallpaper_options("300".into(), true).await.unwrap();

    let native = bridge.native_video_wallpapers().await.unwrap();
    assert_eq!(native.len(), 1);
    assert!((native[0].volume - 0.25).abs() < f32::EPSILON);
    assert!(native[0].muted);
}

#[tokio::test]
async fn hiding_a_display_pauses_only_its_native_wallpaper() {
    let temp = tempfile::tempdir().unwrap();
    let engine = FakeEngineFacade::default();
    engine.set_snapshot(vec![display_snapshot(7), display_snapshot(9)]);
    let paths = BridgePaths::for_home(temp.path().to_path_buf());
    workshop_with_videos(&paths);
    let bridge = BridgeBuilder::new(engine.clone())
        .with_state(crate::actor::state::BridgeActorState::default())
        .with_paths(paths)
        .build()
        .unwrap();
    commit(&bridge, "300", "7").await;
    commit(&bridge, "300", "9").await;

    bridge
        .set_display_presentation_suspended("9".into(), true)
        .await
        .unwrap();

    let native = bridge.native_video_wallpapers().await.unwrap();
    let hidden = native.iter().find(|row| row.display_id == 9).unwrap();
    let visible = native.iter().find(|row| row.display_id == 7).unwrap();
    assert!(hidden.paused);
    assert!(
        !visible.paused,
        "one screen being covered must not stop a screen that is still visible"
    );
}

#[tokio::test]
async fn the_target_rate_is_not_part_of_the_admission_key() {
    let temp = tempfile::tempdir().unwrap();
    let engine = FakeEngineFacade::default();
    let bridge = video_bridge(&engine, &temp).await;
    commit(&bridge, "300", "7").await;
    retarget_fps(&bridge, "300", "7", 60).await;
    let at_60 = admission_key(&bridge, "300").await;

    // The player plays a clip at its own rate, so no target rate decides whether
    // it may take one, and a clip it took stays with it at every target.
    retarget_fps(&bridge, "300", "7", 24).await;
    assert_eq!(
        admission_key(&bridge, "300").await,
        at_60,
        "the key identifies the file, so a new target rate must not change it"
    );
    assert!(is_offered_natively(&bridge, "300").await);
    assert_eq!(scenes_for(&engine, "300"), 0);
}

#[tokio::test]
async fn replacing_the_media_file_at_the_same_path_changes_the_key() {
    let temp = tempfile::tempdir().unwrap();
    let engine = FakeEngineFacade::default();
    let bridge = video_bridge(&engine, &temp).await;
    commit(&bridge, "300", "7").await;
    let before = admission_key(&bridge, "300").await;

    // The user replaces the clip, keeping the file name. The path is the same, so the host has to
    // be told that these are other bytes: it judges and opens a file by this key.
    let media = BridgePaths::for_home(temp.path().to_path_buf())
        .steam_workshop_root()
        .join("300")
        .join("clip.mp4");
    fs::write(&media, b"a different clip entirely, with a different length").unwrap();

    assert_ne!(admission_key(&bridge, "300").await, before);
    assert_eq!(scenes_for(&engine, "300"), 0);
}

#[tokio::test]
async fn two_displays_with_two_clips_each_get_their_own_descriptor_and_key() {
    let temp = tempfile::tempdir().unwrap();
    let engine = FakeEngineFacade::default();
    let bridge = two_display_bridge(&engine, &temp).await;

    assert_eq!(native_display_ids(&bridge, "300").await, vec![7]);
    assert_eq!(native_display_ids(&bridge, "500").await, vec![9]);
    assert_ne!(
        admission_key(&bridge, "300").await,
        admission_key(&bridge, "500").await,
        "a key identifies a file; two files are two keys"
    );
    assert_eq!(scenes_on(&engine, "300", 7), 0);
    assert_eq!(scenes_on(&engine, "500", 9), 0);
}

async fn mirror_group_bridge(
    engine: &FakeEngineFacade,
    temp: &tempfile::TempDir,
    source_fps: u32,
    mirror_fps: u32,
) -> crate::api::WallpaperBridge {
    engine.set_snapshot(vec![display_snapshot(7), display_snapshot(9)]);
    let paths = BridgePaths::for_home(temp.path().to_path_buf());
    workshop_with_videos(&paths);
    let bridge = BridgeBuilder::new(engine.clone())
        .with_state(crate::actor::state::BridgeActorState::default())
        .with_paths(paths)
        .build()
        .unwrap();
    commit(&bridge, "300", "7").await;
    bridge
        .set_display_mode("9".into(), crate::api::BridgeDisplayMode::Mirror)
        .await
        .unwrap();
    bridge.set_mirror_target("9".into(), "7".into()).await.unwrap();
    bridge.set_mirror_target_fps("9".into(), mirror_fps).await.unwrap();
    retarget_fps(&bridge, "300", "7", source_fps).await;
    bridge
}

fn native_row(
    rows: &[crate::api::BridgeNativeVideoWallpaper],
    display_id: u32,
) -> &crate::api::BridgeNativeVideoWallpaper {
    rows.iter()
        .find(|row| row.display_id == display_id)
        .expect("display must be offered natively")
}

#[tokio::test]
async fn a_mirror_shares_its_sources_key_and_carries_no_rate() {
    let temp = tempfile::tempdir().unwrap();
    let engine = FakeEngineFacade::default();
    let bridge = mirror_group_bridge(&engine, &temp, 60, 30).await;

    let rows = bridge.native_video_wallpapers().await.unwrap();
    let source = native_row(&rows, 7).clone();
    let mirror = native_row(&rows, 9);

    assert_eq!(
        source.admission_key, mirror.admission_key,
        "one verdict has to cover the group, so the group needs one key"
    );
    // No member's target rate takes part in the key.
    bridge.set_mirror_target_fps("9".into(), 24).await.unwrap();
    retarget_fps(&bridge, "300", "7", 30).await;
    assert_eq!(admission_key_on(&bridge, "300", 7).await, source.admission_key);
}

async fn admission_key_on(
    bridge: &crate::api::WallpaperBridge,
    wallpaper: &str,
    display_id: u32,
) -> u64 {
    bridge
        .native_video_wallpapers()
        .await
        .unwrap()
        .into_iter()
        .find(|row| row.wallpaper_id == wallpaper && row.display_id == display_id)
        .expect("the slot has to be offered natively")
        .admission_key
}

#[tokio::test]
async fn a_mirror_of_a_moved_clip_is_centred() {
    let temp = tempfile::tempdir().unwrap();
    let engine = FakeEngineFacade::default();
    let bridge = mirror_group_bridge(&engine, &temp, 60, 60).await;
    bridge
        .set_display_position("300".into(), "7".into(), Some(0.2), Some(0.8))
        .await
        .unwrap();

    let rows = bridge.native_video_wallpapers().await.unwrap();
    assert_eq!(
        (native_row(&rows, 7).framing.pan_x, native_row(&rows, 7).framing.pan_y),
        (0.2, 0.8),
        "the source follows its own position"
    );
    assert_eq!(
        (native_row(&rows, 9).framing.pan_x, native_row(&rows, 9).framing.pan_y),
        (0.5, 0.5),
        "a mirror's own settings carry no position, as the scene engine draws it"
    );
}

#[tokio::test]
async fn a_mirror_group_stays_native_whatever_its_members_targets() {
    let temp = tempfile::tempdir().unwrap();
    let engine = FakeEngineFacade::default();
    let bridge = mirror_group_bridge(&engine, &temp, 60, 30).await;

    assert_eq!(
        native_display_ids(&bridge, "300").await,
        vec![7, 9],
        "a clip plays at its own rate, so a stricter mirror does not take the group off the player"
    );
    assert_eq!(scenes_on(&engine, "300", 7), 0);
    assert_eq!(scenes_on(&engine, "300", 9), 0);
}

#[tokio::test]
async fn the_lock_screen_export_still_carries_a_plain_video_as_a_scene() {
    let temp = tempfile::tempdir().unwrap();
    let engine = FakeEngineFacade::default();
    let bridge = video_bridge(&engine, &temp).await;
    commit(&bridge, "300", "7").await;

    // The extension plays the clip itself and keeps the scene as what it draws when it cannot.
    let scenes = bridge.lock_screen_scenes().await.unwrap();
    assert_eq!(scenes.len(), 1);
    assert!(scenes[0].project_path.contains("300"));
    assert_eq!(scenes_for(&engine, "300"), 0, "the desktop's engine still gets none");
}
