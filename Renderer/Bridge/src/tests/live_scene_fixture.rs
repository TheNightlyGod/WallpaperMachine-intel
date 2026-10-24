//! A bridge on the fake engine with installed scene wallpapers and displays
//! whose live scenes a test describes directly.
use std::time::{Duration, Instant};

use wallpaper_core::{
    DisplaySnapshotEntry, WallpaperAssignment,
    project::{SceneDesc, SceneHandle, SceneTemplate},
};

use crate::{
    WallpaperBridge,
    actor::state::BridgeActorState,
    api::{BridgeBuilder, BridgeWallpaperEntry, BridgeWallpaperKind},
    config::{AppConfig, ConfigStore, MonitorCfg, SerializedSelector, WallpaperConfig},
    engine::FakeEngineFacade,
    paths::BridgePaths,
    state::drafts::WallpaperOptionsDraft,
};

pub(super) const WAIT: Duration = Duration::from_secs(5);

/// A configured block that shows `wallpaper` on its own.
pub(super) fn showing(selector: SerializedSelector, wallpaper: &str) -> MonitorCfg {
    MonitorCfg {
        selector,
        wallpaper: Some(wallpaper.to_owned()),
        ..MonitorCfg::default()
    }
}

/// Actor state with `wallpapers` installed as scenes, each with its saved
/// configuration (the default one when `None`).
pub(super) fn installed(
    app: AppConfig,
    wallpapers: Vec<(&str, Option<WallpaperConfig>)>,
) -> BridgeActorState {
    let mut state = BridgeActorState::from_app_config(app);
    for (id, config) in wallpapers {
        let config = config.unwrap_or_else(|| WallpaperConfig::new_for(id, "scene"));
        state.library.push(BridgeWallpaperEntry {
            id: id.to_owned(),
            title: format!("Wallpaper {id}"),
            kind: BridgeWallpaperKind::ProjectScene,
            supported: true,
            active: false,
            selected: false,
            preview_path: None,
        });
        state.wallpaper_drafts.insert(
            id.to_owned(),
            WallpaperOptionsDraft::from_committed(config.clone()),
        );
        state.wallpaper_configs.insert(id.to_owned(), config);
    }
    state.library_scanned = true;
    state
}

/// The bridge, and the temporary home its paths and optional store live in.
pub(super) struct Fixture {
    pub bridge: WallpaperBridge,
    pub home: tempfile::TempDir,
}

pub(super) fn bridge(
    engine: &FakeEngineFacade,
    state: BridgeActorState,
    with_store: bool,
) -> Fixture {
    let home = tempfile::tempdir().expect("temporary home");
    let mut builder = BridgeBuilder::new(engine.clone())
        .with_state(state)
        .with_paths(BridgePaths::for_home(home.path()))
        .with_mouse_polling_enabled(false)
        .with_power_watching_enabled(false);
    if with_store {
        builder = builder.with_config_store(ConfigStore::open(home.path().join("support")));
    }
    let bridge = builder.build().expect("test bridge");
    Fixture { bridge, home }
}

/// `display` running `scene` behind `handle`, paused or not.
pub(super) fn live(
    mut display: DisplaySnapshotEntry,
    handle: u64,
    scene: &SceneDesc,
    paused: bool,
) -> DisplaySnapshotEntry {
    display.handle = Some(SceneHandle::new(handle));
    display.assignment = Some(WallpaperAssignment::Direct(SceneTemplate::from_scene_desc(
        scene,
    )));
    display.window_active = true;
    display.paused = paused;
    display
}

/// A scene of `wallpaper` that no configuration produced, for a display that
/// still shows something else.
pub(super) fn foreign_scene(display: &DisplaySnapshotEntry, wallpaper: &str) -> SceneDesc {
    SceneDesc::builder(
        display.desc.clone(),
        format!("/elsewhere/{wallpaper}/project.json"),
    )
    .build()
    .expect("a valid scene descriptor")
}

/// Waits until `condition` holds, polling without blocking the runtime.
pub(super) async fn eventually(mut condition: impl FnMut() -> bool) -> bool {
    let started = Instant::now();
    while started.elapsed() < WAIT {
        if condition() {
            return true;
        }
        tokio::time::sleep(Duration::from_millis(2)).await;
    }
    condition()
}
