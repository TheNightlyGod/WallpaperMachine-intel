mod api_intent_consumer_contract_tests;
mod playback_consumer_contract_tests;
mod power_consumer_contract_tests;
mod property_consumer_contract_tests;

use std::{
    any::Any,
    fs,
    future::Future,
    io,
    panic::{resume_unwind, AssertUnwindSafe},
    path::{Component, Path, PathBuf},
    pin::Pin,
    sync::atomic::{AtomicU64, Ordering},
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use futures_util::FutureExt;

use crate::api::{
    BridgeBuilder, BridgeLibrarySnapshot, BridgeWallpaperEntry,
    BridgeWallpaperKind, WallpaperBridge,
};
use crate::paths::BridgePaths;

const WATCHDOG: Duration = Duration::from_secs(20);
static NEXT_ROOT: AtomicU64 = AtomicU64::new(0);

/// Deletes only this test's successfully created directory. While an actor may
/// still own paths, deletion is disarmed until shutdown_and_drain succeeds.
struct OwnedRoot {
    path: PathBuf,
    remove_on_drop: bool,
}

impl OwnedRoot {
    fn new() -> Self {
        let parent = fs::canonicalize(std::env::temp_dir())
            .expect("canonicalize the system user temporary directory");
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system clock is after the Unix epoch")
            .as_nanos();
        loop {
            let serial = NEXT_ROOT.fetch_add(1, Ordering::Relaxed);
            let candidate = parent.join(format!(
                "wallpaper-small-library-{}-{stamp}-{serial}",
                std::process::id()
            ));
            match fs::create_dir(&candidate) {
                Ok(()) => {
                    let mut owned = Self {
                        path: candidate,
                        remove_on_drop: true,
                    };
                    owned.path = fs::canonicalize(&owned.path)
                        .expect("canonicalize the newly owned temporary directory");
                    assert!(owned.path.starts_with(&parent));
                    return owned;
                }
                Err(error) if error.kind() == io::ErrorKind::AlreadyExists => continue,
                Err(error) => panic!("create an owned temporary directory: {error}"),
            }
        }
    }

    fn checked(&self, path: PathBuf) -> PathBuf {
        assert!(path.is_absolute(), "test path must be absolute: {path:?}");
        assert!(
            path.starts_with(&self.path),
            "refusing a path outside the owned root: {path:?}"
        );
        assert!(
            !path.components().any(|part| part == Component::ParentDir),
            "refusing a path containing a parent traversal: {path:?}"
        );
        let mut existing = path.as_path();
        while !existing.exists() {
            existing = existing.parent().expect("owned path has an existing ancestor");
        }
        let actual = fs::canonicalize(existing).expect("canonicalize existing path ancestor");
        assert!(
            actual.starts_with(&self.path),
            "refusing an existing ancestor outside the owned root: {actual:?}"
        );
        path
    }

    fn bridge_paths(&self) -> BridgePaths {
        let home = self.checked(self.path.join("home"));
        fs::create_dir_all(&home).expect("create the owned bridge home");
        let paths = BridgePaths::for_home(home);
        // Check every builder-owned location before allowing the builder to
        // create anything. Ambient overrides must never reach user data.
        for path in [
            paths.steam_workshop_root(),
            paths.app_support_root(),
            paths.assets_root(),
            paths.user_assets_root(),
            paths.shader_cache_root(),
            paths.logs_root(),
        ] {
            self.checked(path);
        }
        paths
    }

    fn remove_now(&mut self) -> io::Result<()> {
        fs::remove_dir_all(&self.path)?;
        self.remove_on_drop = false;
        Ok(())
    }
}

impl Drop for OwnedRoot {
    fn drop(&mut self) {
        if self.remove_on_drop {
            if let Err(error) = fs::remove_dir_all(&self.path) {
                eprintln!("could not remove owned test root {:?}: {error}", self.path);
            }
        }
    }
}

type TestBody<'a> = Pin<Box<dyn Future<Output = ()> + 'a>>;
type PanicPayload = Box<dyn Any + Send>;

async fn with_bridges<F>(count: usize, body: F)
where
    F: for<'a> FnOnce(&'a OwnedRoot, &'a BridgePaths, &'a [WallpaperBridge]) -> TestBody<'a>,
{
    let mut root = OwnedRoot::new();
    let paths = root.bridge_paths();
    let mut bridges = Vec::with_capacity(count);
    root.remove_on_drop = false;
    let result: Result<(), PanicPayload> = AssertUnwindSafe(async {
        for _ in 0..count {
            let engine = crate::api::mounted_lifecycle::ControlledEngine::new(Vec::new());
            let login = crate::api::lifecycle_test_support::inert_login_controller(
                crate::login::LaunchAtLoginStatus::Unavailable,
            );
            bridges.push(
                BridgeBuilder::new(engine)
                    .with_paths(paths.clone())
                    .with_launch_at_login(login)
                    .with_mouse_polling_enabled(false)
                    .with_power_watching_enabled(false)
                    .build()
                    .expect("build the real non-rendering bridge"),
            );
        }
        tokio::time::timeout(WATCHDOG, body(&root, &paths, &bridges))
            .await
            .expect("public library operations exceeded the watchdog");
    })
    .catch_unwind()
    .await;

    // The body only borrowed handles; no fixture actor clones survive here.
    // Catch both assertion failures and shutdown failures without ever deleting
    // files while an undrained actor might still be using them.
    let mut shutdown_errors = Vec::new();
    for bridge in bridges {
        let shutdown = AssertUnwindSafe(tokio::time::timeout(
            WATCHDOG,
            crate::api::mounted_lifecycle::shutdown_and_drain(bridge),
        ))
        .catch_unwind()
        .await;
        match shutdown {
            Ok(Ok(Ok(()))) => {}
            Ok(Ok(Err(error))) => shutdown_errors.push(format!("shutdown failed: {error:?}")),
            Ok(Err(error)) => shutdown_errors.push(format!("shutdown watchdog expired: {error}")),
            Err(_) => shutdown_errors.push("shutdown panicked".to_owned()),
        }
    }

    if shutdown_errors.is_empty() {
        root.remove_on_drop = true;
        if let Err(error) = root.remove_now() {
            shutdown_errors.push(format!("remove owned root {:?}: {error}", root.path));
        }
    } else {
        shutdown_errors.push(format!(
            "retained owned root {:?} because actor drain was not confirmed",
            root.path
        ));
    }
    if let Err(payload) = result {
        if !shutdown_errors.is_empty() {
            eprintln!("cleanup after test failure: {shutdown_errors:?}");
        }
        resume_unwind(payload);
    }
    assert!(shutdown_errors.is_empty(), "{shutdown_errors:?}");
}

fn write_project(root: &OwnedRoot, workshop: &Path, id: &str, json: &str) {
    let project = root.checked(workshop.join(id));
    fs::create_dir_all(&project).expect("create an owned workshop entry");
    let manifest = root.checked(project.join("project.json"));
    fs::write(manifest, json).expect("write an independently authored project.json");
}

fn assert_scene_video_inventory(
    library: &BridgeLibrarySnapshot,
    scene_id: &str,
    video_id: &str,
    video_visible: bool,
) {
    assert_eq!(library.scene_count, 1, "scene inventory count");
    assert_eq!(library.video_count, 1, "hidden video remains in inventory");
    assert_eq!(library.wallpapers.len(), if video_visible { 2 } else { 1 });
    let scene = library
        .wallpapers
        .iter()
        .find(|entry| entry.id == scene_id)
        .expect("scene stays visible");
    assert_eq!(scene.kind, BridgeWallpaperKind::ProjectScene);
    assert!(scene.supported);
    let video = library.wallpapers.iter().find(|entry| entry.id == video_id);
    if video_visible {
        let video = video.expect("re-enabling video reveals the retained inventory row");
        assert_eq!(video.kind, BridgeWallpaperKind::Video);
        assert!(video.supported);
    } else {
        assert!(video.is_none(), "disabled video is absent from the projection");
    }
}

async fn inject(bridge: &WallpaperBridge, id: &str, kind: BridgeWallpaperKind) {
    crate::api::lifecycle_test_support::actor(bridge)
        .ask(crate::actor::messages::InjectWallpaperForTest {
            id: id.to_owned(),
            title: format!("Owned consumer entry {id}"),
            kind,
        })
        .await
        .expect("the actual receiver accepts inventory injection");
}

#[tokio::test]
async fn actual_filter_mutation_preserves_video_across_public_snapshots() {
    with_bridges(1, |_, _, bridges| {
        Box::pin(async move {
            let bridge = &bridges[0];
            let scene = "consumer-scene-481";
            let video = "consumer-video-936";
            inject(bridge, scene, BridgeWallpaperKind::ProjectScene).await;
            inject(bridge, video, BridgeWallpaperKind::Video).await;

            let disabled = bridge
                .set_filter(BridgeWallpaperKind::Video, false)
                .await
                .expect("disable video through the real actor");
            assert_scene_video_inventory(&disabled.library, scene, video, false);
            let later = bridge.library_snapshot().await.expect("read a later public library snapshot");
            assert_scene_video_inventory(&later, scene, video, false);
            let enabled = bridge
                .set_filter(BridgeWallpaperKind::Video, true)
                .await
                .expect("re-enable video without reinjecting or rescanning");
            assert_scene_video_inventory(&enabled.library, scene, video, true);
        })
    })
    .await;
}

#[tokio::test]
async fn owned_refresh_retains_hidden_video_on_separate_real_actors() {
    with_bridges(2, |root, paths, bridges| {
        Box::pin(async move {
            let workshop = root.checked(paths.steam_workshop_root());
            fs::create_dir_all(&workshop).expect("create the owned workshop root");
            let scene = "35821";
            let video = "72946";
            write_project(root, &workshop, scene, r#"{"type":"scene","title":"Copper orbit"}"#);
            write_project(root, &workshop, video, r#"{"type":"video","title":"Quiet harbor"}"#);

            let first = &bridges[0];
            first.set_filter(BridgeWallpaperKind::Video, false).await.expect("disable video before refresh");
            let refreshed = first.refresh_library().await.expect("refresh the real owned workshop");
            assert_scene_video_inventory(&refreshed.library, scene, video, false);
            let enabled = first.set_filter(BridgeWallpaperKind::Video, true).await.expect("reveal the scanned video");
            assert_scene_video_inventory(&enabled.library, scene, video, true);

            // A distinct actor shares only these explicitly supplied owned
            // paths. The concurrent snapshot may precede or follow refresh;
            // neither outcome is used to infer a scheduling order.
            let second = &bridges[1];
            second.set_filter(BridgeWallpaperKind::Video, false).await.expect("disable video on the second actor");
            let (refresh, snapshot) = tokio::join!(second.refresh_library(), second.library_snapshot());
            let refresh = refresh.expect("concurrent owned refresh completes");
            let snapshot = snapshot.expect("concurrent public snapshot completes");
            assert_scene_video_inventory(&refresh.library, scene, video, false);
            assert!(snapshot.wallpapers.iter().all(|entry| entry.id != video));
            let enabled = second.set_filter(BridgeWallpaperKind::Video, true).await.expect("reveal video after both concurrent calls return");
            assert_scene_video_inventory(&enabled.library, scene, video, true);
        })
    })
    .await;
}

#[test]
fn scanner_keeps_supported_scene_and_web_and_visible_unsupported_application() {
    use wallpaper_core::project::WallpaperProjectType;

    let root = OwnedRoot::new();
    let workshop = root.checked(root.path.join("scan-workshop"));
    fs::create_dir_all(&workshop).expect("create a real scanner root");
    // Creation order intentionally differs from the required workshop-ID order.
    write_project(&root, &workshop, "863", r#"{"type":"web","title":"Distant lattice"}"#);
    write_project(&root, &workshop, "214", r#"{"type":"application","title":"Local instrument"}"#);
    write_project(&root, &workshop, "527", r#"{"type":"scene","title":"Paper satellite"}"#);

    let scanned = crate::library::scan(&workshop).expect("scan the actual owned projects");
    assert_eq!(scanned.len(), 3, "unsupported application remains visible");
    assert_eq!(
        scanned.iter().map(|entry| entry.workshop_id.as_str()).collect::<Vec<_>>(),
        vec!["214", "527", "863"],
        "scanner returns workshop-ID ordering rather than creation order"
    );
    // Core represents the explicit application manifest as Unknown; it does
    // not expose a separate Application enum variant.
    assert_eq!(scanned[0].project_type, WallpaperProjectType::Unknown);
    assert!(!scanned[0].supported, "application is not a supported wallpaper");
    assert_eq!(scanned[1].project_type, WallpaperProjectType::Scene);
    assert!(scanned[1].supported, "scene remains supported beside application");
    assert_eq!(scanned[2].project_type, WallpaperProjectType::Web);
    assert!(scanned[2].supported, "web retains the existing supported policy");
}

#[tokio::test]
async fn replacement_clears_removed_selection_in_both_public_snapshots() {
    with_bridges(1, |_, _, bridges| {
        Box::pin(async move {
            let bridge = &bridges[0];
            let removed = "selection-removed-642";
            let remaining = "selection-retained-985";
            inject(bridge, removed, BridgeWallpaperKind::ProjectScene).await;
            inject(bridge, remaining, BridgeWallpaperKind::ProjectScene).await;
            let selected = bridge.select_wallpaper(removed.to_owned()).await.expect("select the actual inventory entry");
            assert_eq!(selected.app.selected_wallpaper_id.as_deref(), Some(removed));
            assert!(selected.library.wallpapers.iter().any(|entry| entry.id == removed && entry.selected));

            crate::api::lifecycle_test_support::actor(bridge)
                .ask(crate::actor::messages::ReplaceLibraryForTest {
                    entries: vec![BridgeWallpaperEntry {
                        id: remaining.to_owned(),
                        title: "Still present after replacement".to_owned(),
                        kind: BridgeWallpaperKind::ProjectScene,
                        supported: true,
                        active: false,
                        selected: true,
                        preview_path: None,
                    }],
                })
                .await
                .expect("the actual receiver replaces inventory");

            let app = bridge.app_snapshot().await.expect("independently read public app state");
            let library = bridge.library_snapshot().await.expect("independently read public library state");
            assert_eq!(app.selected_wallpaper_id, None);
            assert_eq!(library.wallpapers.len(), 1);
            assert_eq!(library.wallpapers[0].id, remaining);
            assert!(library.wallpapers.iter().all(|entry| !entry.selected), "public selection is recomputed, not copied from the supplied selected flag");
        })
    })
    .await;
}

#[test]
fn config_round_trip_reopens_store_with_filter_and_independent_primary_assignment() {
    use crate::config::{AppConfig, ConfigStore, MonitorCfg, SerializedSelector};

    let root = OwnedRoot::new();
    let config_root = root.checked(root.path.join("saved-config"));
    fs::create_dir_all(&config_root).expect("create the owned config store root");
    let mut expected = AppConfig::default();
    expected.ui.filter.scene = false;
    expected.monitors = vec![MonitorCfg {
        selector: SerializedSelector::Primary,
        enabled: true,
        mode: "independent".to_owned(),
        wallpaper: Some("config-owned-wallpaper-573".to_owned()),
        mirror_target: None,
    }];
    {
        let writer = ConfigStore::open(config_root.clone());
        writer.save_app_config(&expected).expect("persist the represented nondefault config");
    }
    // The writer was dropped: this load cannot reuse its in-memory state.
    let reopened = ConfigStore::open(config_root);
    let loaded = reopened.load().expect("load config through a distinct newly opened store");
    assert_eq!(loaded.config, expected, "the complete represented config survives save and reopen");
}
