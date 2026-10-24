//! File and directory wallpaper properties.
//!
//! `file`, `directory` and the texture pickers used to be one kind, which meant
//! a scene texture picker and a folder the page reads were indistinguishable.
//! What matters here is that the split reaches the two consumers that act on
//! it: the editor, which needs the filter and the mode to present a control,
//! and the page, which cannot stage a file or decide between `applyUserProperties`
//! and the fetchall callbacks without them. And that a staged path is handed to
//! the page exactly as the host stored it.

use wallpaper_core::{DisplayDesc, DisplayIdentity, DisplaySnapshotEntry};

use crate::{
    BridgeDirectoryMode, BridgeFileFilter, BridgePropertyKind, BridgePropertyValue,
    api::{BridgeBuilder, WallpaperBridge},
    engine::FakeEngineFacade,
    paths::BridgePaths,
};

const PROJECT: &str = r#"{
    "type":"web",
    "title":"Web",
    "file":"index.html",
    "general":{"properties":{
        "clip":{"type":"file","fileType":"video","text":"Clip","order":1},
        "photos":{"type":"directory","mode":"fetchall","fileType":"image","text":"Photos","order":2},
        "pool":{"type":"directory","text":"Pool","order":3},
        "backdrop":{"type":"scenetexture","value":"","text":"Backdrop","order":4}
    }}
}"#;

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
        window_active: true,
        assignment: None,
    }
}

async fn bridge_with_project() -> WallpaperBridge {
    bridge_with_paths(BridgePaths::new()).await
}

async fn bridge_with_paths(paths: BridgePaths) -> WallpaperBridge {
    let engine = FakeEngineFacade::default();
    engine.set_snapshot(vec![display_snapshot(7)]);
    let bridge = BridgeBuilder::new(engine)
        .with_state(crate::actor::state::BridgeActorState::default())
        .with_paths(paths)
        .build()
        .expect("tokio runtime and config load for wallpaper bridge");
    bridge
        .inject_scene_project_for_test("300", "Web", PROJECT)
        .await;
    bridge
        .set_display_config_enabled("300".into(), "7".into(), true)
        .await
        .unwrap();
    bridge.apply_wallpaper_options("300".into(), true).await.unwrap();
    bridge
}

async fn page_properties(bridge: &WallpaperBridge) -> serde_json::Value {
    let web = bridge.web_wallpapers().await.unwrap();
    serde_json::from_str(&web[0].properties_json).unwrap()
}

#[tokio::test]
async fn the_editor_sees_file_directory_and_texture_as_three_different_things() {
    let bridge = bridge_with_project().await;

    let snapshot = bridge
        .wallpaper_options_snapshot("300".into())
        .await
        .unwrap();
    let property = |id: &str| {
        snapshot
            .properties
            .iter()
            .find(|property| property.id == id)
            .unwrap_or_else(|| panic!("{id} must be offered to the editor"))
            .clone()
    };

    let clip = property("clip");
    assert_eq!(clip.kind, BridgePropertyKind::File);
    assert_eq!(clip.file_filter, Some(BridgeFileFilter::Video));
    assert_eq!(
        clip.directory_mode, None,
        "a single file has no directory mode to choose"
    );

    let photos = property("photos");
    assert_eq!(photos.kind, BridgePropertyKind::Directory);
    assert_eq!(photos.file_filter, Some(BridgeFileFilter::Image));
    assert_eq!(photos.directory_mode, Some(BridgeDirectoryMode::FetchAll));

    let pool = property("pool");
    assert_eq!(pool.kind, BridgePropertyKind::Directory);
    assert_eq!(
        pool.file_filter, None,
        "an author who declared no filter must not be shown one this build invented"
    );
    assert_eq!(pool.directory_mode, Some(BridgeDirectoryMode::OnDemand));

    let backdrop = property("backdrop");
    assert_eq!(
        backdrop.kind,
        BridgePropertyKind::Texture,
        "a scene texture picker names a scene asset, not a path"
    );
    assert_eq!(backdrop.file_filter, None);
    assert_eq!(backdrop.directory_mode, None);
    assert_eq!(
        backdrop.value,
        BridgePropertyValue::String {
            value: String::new()
        },
        "texture pickers keep the empty-string default they had before the split"
    );
}

#[tokio::test]
async fn the_page_is_told_each_property_kind_and_its_directory_options() {
    let bridge = bridge_with_project().await;

    let properties = page_properties(&bridge).await;

    assert_eq!(properties["clip"]["type"], "file");
    assert_eq!(properties["clip"]["fileFilter"], "video");
    assert!(properties["clip"].get("mode").is_none());

    assert_eq!(properties["photos"]["type"], "directory");
    assert_eq!(properties["photos"]["fileFilter"], "image");
    assert_eq!(properties["photos"]["mode"], "fetchall");

    assert_eq!(properties["pool"]["mode"], "ondemand");
    assert!(
        properties["pool"].get("fileFilter").is_none(),
        "no declared filter means no restriction, which is not the same as an image filter"
    );

    assert_eq!(properties["backdrop"]["type"], "texture");

    // A directory property still carries a value in both modes, so a page can
    // tell "no directory chosen" from one that is simply empty.
    assert_eq!(properties["photos"]["value"], "");
}

#[tokio::test]
async fn a_staged_path_reaches_the_page_exactly_as_the_host_stored_it() {
    let bridge = bridge_with_project().await;
    // The host stages the file and decides what the page is given. Characters
    // that a well-meaning rewrite would mangle are the point of this value.
    let staged = "/Users/someone/Library/Application Support/x/.mwe-user-assets/clip/a b+c'&d.webm";

    bridge
        .set_property_path("300".into(), "clip".into(), Some(staged.into()))
        .await
        .unwrap();

    assert_eq!(page_properties(&bridge).await["clip"]["value"], staged);

    bridge
        .set_property_path("300".into(), "clip".into(), None)
        .await
        .unwrap();

    assert_eq!(
        page_properties(&bridge).await["clip"]["value"], "",
        "clearing restores the empty default the page reads as nothing chosen"
    );
}

#[tokio::test]
async fn a_staged_path_is_committed_rather_than_left_in_the_editor_draft() {
    let bridge = bridge_with_project().await;

    bridge
        .set_property_path("300".into(), "photos".into(), Some("/tmp/pictures".into()))
        .await
        .unwrap();

    // Nothing was applied after the call, so a draft-only edit would leave the
    // page on the old value and the editor claiming unsaved changes.
    assert_eq!(
        page_properties(&bridge).await["photos"]["value"],
        "/tmp/pictures"
    );
    assert!(
        !bridge
            .wallpaper_options_snapshot("300".into())
            .await
            .unwrap()
            .dirty
    );
}

#[tokio::test]
async fn a_path_is_refused_for_a_property_that_is_not_a_file_or_directory() {
    let bridge = bridge_with_project().await;

    let error = bridge
        .set_property_path("300".into(), "backdrop".into(), Some("/tmp/x.png".into()))
        .await
        .unwrap_err();
    assert_eq!(error.kind(), crate::BridgeErrorKind::InvalidInput);

    let missing = bridge
        .set_property_path("300".into(), "nope".into(), Some("/tmp/x.png".into()))
        .await
        .unwrap_err();
    assert_eq!(missing.kind(), crate::BridgeErrorKind::InvalidInput);

    assert_eq!(page_properties(&bridge).await["backdrop"]["value"], "");
}

/// What the inspector renders beside a `file`/`directory` control: whether the app
/// holds its own copy, whether the selection has gone missing, and the user's own
/// path to show. A texture picker names a file inside the package and must never be
/// reported as a missing user asset.
#[tokio::test]
async fn the_editor_is_told_whether_a_picked_asset_is_managed_or_missing() {
    async fn property(bridge: &WallpaperBridge, id: &str) -> crate::BridgePropertyDescriptor {
        bridge
            .wallpaper_options_snapshot("300".into())
            .await
            .unwrap()
            .properties
            .iter()
            .find(|property| property.id == id)
            .unwrap_or_else(|| panic!("{id} must be offered to the editor"))
            .clone()
    }

    // A private home rather than a process-wide environment variable: these tests run
    // in parallel in one process, and a global override would leak between them.
    let home = tempfile::tempdir().expect("home");
    let paths = BridgePaths::for_home(home.path());
    let store = paths.user_assets_root();
    let bridge = bridge_with_paths(BridgePaths::for_home(home.path())).await;

    let unset = property(&bridge, "clip").await;
    assert!(!unset.asset_managed);
    assert!(
        !unset.asset_missing,
        "a property the user never set is unset, not missing"
    );
    assert_eq!(unset.asset_source_path, None);

    bridge
        .set_property_path("300".into(), "clip".into(), Some("/gone/a b+c.webm".into()))
        .await
        .unwrap();
    let gone = property(&bridge, "clip").await;
    assert!(!gone.asset_managed);
    assert!(
        gone.asset_missing,
        "a selection that resolves nowhere has to be reported, not silently cleared"
    );
    assert_eq!(gone.asset_source_path.as_deref(), Some("/gone/a b+c.webm"));

    // The app copied it in and recorded that. Same unreachable original, but the
    // wallpaper still works, so the inspector must not call it missing.
    let asset = store.join("300").join("clip").join("abc123");
    std::fs::create_dir_all(&asset).expect("managed asset directory");
    std::fs::write(asset.join("a b+c.webm"), b"bytes").expect("managed asset");
    std::fs::write(
        store.join("300").join("manifest.json"),
        r#"{"version":1,"wallpaperId":"300","properties":{"clip":{"kind":"file","sourcePath":"/gone/a b+c.webm","truncated":false,"migratedLegacyPaths":[],"assets":[{"assetId":"abc123","fileName":"a b+c.webm","sourcePath":"/gone/a b+c.webm","size":5,"modified":"2024-01-01T00:00:00Z","digest":"abc123"}]}}}"#,
    )
    .expect("manifest");

    let managed = property(&bridge, "clip").await;
    assert!(managed.asset_managed);
    assert!(!managed.asset_missing);
    assert_eq!(
        managed.asset_source_path.as_deref(),
        Some("/gone/a b+c.webm"),
        "the path shown is the user's own, not the app's copy"
    );

    let backdrop = property(&bridge, "backdrop").await;
    assert!(!backdrop.asset_managed);
    assert!(
        !backdrop.asset_missing,
        "a scene texture names a file inside the package; it is not a user asset"
    );
}
