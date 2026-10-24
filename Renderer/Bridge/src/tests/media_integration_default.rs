//! System media integration is on unless a wallpaper's saved choice says
//! otherwise; previews, the lock screen and the renderer's own defaults never
//! take part.
use wallpaper_core::{
    DisplaySnapshotEntry,
    project::{SceneDesc, SceneHandle, SceneTemplate},
};

use super::{
    fixture_values::identified,
    live_scene_fixture::{bridge, foreign_scene, installed, live, showing},
};
use crate::{
    api::{BridgeWallpaperEntry, BridgeWallpaperKind},
    config::{AppConfig, ConfigStore, SerializedSelector, WallpaperConfig},
    engine::FakeEngineFacade,
    project::ProjectModel,
    state::drafts::WallpaperOptionsDraft,
};

const NOCTURNE: &str = "nocturne";
const STATUS_EVENT: &str = r#"{"type":"mediaStatusChanged","enabled":true}"#;

fn main_display() -> DisplaySnapshotEntry {
    identified("media-main", 1, 60)
}

/// A configuration saved before the choice existed.
fn saved_without_a_choice(id: &str) -> WallpaperConfig {
    serde_json::from_value(serde_json::json!({
        "schema_version": 1,
        "workshop_id": id,
        "type": "scene",
        "monitors": []
    }))
    .expect("an older configuration")
}

#[test]
fn a_new_wallpaper_configuration_shares_media_by_default() {
    assert!(WallpaperConfig::new_for(NOCTURNE, "scene").media_integration_enabled);
    assert!(WallpaperConfig::new_for(NOCTURNE, "web").media_integration_enabled);
    assert!(WallpaperConfig::default().media_integration_enabled);
}

#[test]
fn a_configuration_without_a_saved_choice_loads_enabled() {
    assert!(saved_without_a_choice(NOCTURNE).media_integration_enabled);

    let home = tempfile::tempdir().expect("temporary home");
    let wallpapers = home.path().join("wallpapers");
    std::fs::create_dir_all(&wallpapers).expect("wallpapers folder");
    std::fs::write(
        wallpapers.join(format!("{NOCTURNE}.json")),
        format!(r#"{{"schema_version":1,"workshop_id":"{NOCTURNE}","type":"scene"}}"#),
    )
    .expect("older file");
    let loaded = ConfigStore::open(home.path())
        .load_wallpaper(NOCTURNE)
        .expect("load");
    assert!(loaded.media_integration_enabled);
    // A wallpaper that was never saved starts from the same default.
    let never_saved = ConfigStore::open(home.path())
        .load_wallpaper("unsaved")
        .expect("load unsaved");
    assert!(never_saved.media_integration_enabled);
}

#[test]
fn a_saved_choice_survives_load_and_save() {
    for choice in [true, false] {
        let home = tempfile::tempdir().expect("temporary home");
        let store = ConfigStore::open(home.path());
        let mut config = WallpaperConfig::new_for(NOCTURNE, "scene");
        config.media_integration_enabled = choice;
        store.save_wallpaper(&config).expect("save");
        let text = std::fs::read_to_string(
            home.path()
                .join("wallpapers")
                .join(format!("{NOCTURNE}.json")),
        )
        .expect("saved file");
        let raw: serde_json::Value = serde_json::from_str(&text).expect("saved JSON");
        assert_eq!(
            raw["media_integration_enabled"], choice,
            "the choice is written out"
        );

        let loaded = store.load_wallpaper(NOCTURNE).expect("load");
        assert_eq!(loaded.media_integration_enabled, choice);
        store.save_wallpaper(&loaded).expect("save again");
        assert_eq!(store.load_wallpaper(NOCTURNE).expect("reload"), config);
    }
}

#[test]
fn the_renderers_own_defaults_stay_off() {
    let scene = SceneDesc::builder(main_display().desc, "/library/nocturne/scene.json")
        .build()
        .expect("scene");
    assert!(!scene.media_integration_enabled);
    let template = SceneTemplate::builder("/library/nocturne/scene.json")
        .build()
        .expect("template");
    assert!(!template.media_integration_enabled);
}

#[tokio::test(flavor = "multi_thread")]
async fn a_desktop_scene_without_a_saved_choice_receives_media_with_no_setup() {
    let engine = FakeEngineFacade::default();
    let scene = foreign_scene(&main_display(), NOCTURNE);
    engine.set_snapshot(vec![live(main_display(), 7, &scene, false)]);
    let mut app = AppConfig::default();
    app.monitors = vec![showing(SerializedSelector::Primary, NOCTURNE)];
    let state = installed(
        app,
        vec![(NOCTURNE, Some(saved_without_a_choice(NOCTURNE)))],
    );
    let fixture = bridge(&engine, state, false);

    assert_eq!(
        fixture
            .bridge
            .system_media_scene_handles()
            .await
            .expect("handles"),
        vec![7]
    );
    fixture
        .bridge
        .submit_system_media_event(STATUS_EVENT.into())
        .await
        .expect("deliver");

    assert_eq!(
        engine.media_event_calls(),
        vec![(SceneHandle::new(7), STATUS_EVENT.to_owned())]
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn turning_media_off_and_on_again_still_works() {
    let engine = FakeEngineFacade::default();
    let scene = foreign_scene(&main_display(), NOCTURNE);
    engine.set_snapshot(vec![live(main_display(), 7, &scene, false)]);
    let mut app = AppConfig::default();
    app.monitors = vec![showing(SerializedSelector::Primary, NOCTURNE)];
    let fixture = bridge(&engine, installed(app, vec![(NOCTURNE, None)]), false);

    assert_eq!(
        fixture
            .bridge
            .system_media_consent_handles()
            .await
            .expect("consent"),
        vec![7]
    );
    fixture
        .bridge
        .set_media_integration_enabled(NOCTURNE.into(), false)
        .await
        .expect("turn off");
    assert!(
        fixture
            .bridge
            .system_media_consent_handles()
            .await
            .expect("consent")
            .is_empty()
    );
    assert!(
        fixture
            .bridge
            .system_media_scene_handles()
            .await
            .expect("handles")
            .is_empty()
    );
    let cleared = engine.media_calls();
    assert!(
        cleared
            .iter()
            .any(|(handle, enabled, _)| *handle == SceneHandle::new(7) && !enabled),
        "turning it off clears the scene's media state"
    );
    fixture
        .bridge
        .submit_system_media_event(STATUS_EVENT.into())
        .await
        .expect("deliver while off");
    assert!(engine.media_event_calls().is_empty());

    fixture
        .bridge
        .set_media_integration_enabled(NOCTURNE.into(), true)
        .await
        .expect("turn on");
    assert_eq!(
        fixture
            .bridge
            .system_media_scene_handles()
            .await
            .expect("handles"),
        vec![7]
    );
    assert_eq!(
        engine.media_integration_calls(),
        vec![(SceneHandle::new(7), false), (SceneHandle::new(7), true)]
    );
}

fn web_state(saved: Option<bool>) -> crate::actor::state::BridgeActorState {
    const PAGE: &str = "lantern";
    let mut app = AppConfig::default();
    app.monitors = vec![showing(SerializedSelector::Primary, PAGE)];
    let mut state = crate::actor::state::BridgeActorState::from_app_config(app);
    let model = ProjectModel::parse(
        PAGE,
        r#"{"title":"Lantern","type":"web","file":"index.html","general":{"properties":{}}}"#,
    )
    .expect("web project");
    let mut config = WallpaperConfig::new_for(PAGE, "web");
    if let Some(choice) = saved {
        config.media_integration_enabled = choice;
    }
    state.library.push(BridgeWallpaperEntry {
        id: PAGE.into(),
        title: "Lantern".into(),
        kind: BridgeWallpaperKind::Webpage,
        supported: true,
        active: false,
        selected: false,
        preview_path: None,
    });
    state.project_models.insert(PAGE.into(), model);
    state.wallpaper_drafts.insert(
        PAGE.into(),
        WallpaperOptionsDraft::from_committed(config.clone()),
    );
    state.wallpaper_configs.insert(PAGE.into(), config);
    state.library_scanned = true;
    state
}

#[tokio::test(flavor = "multi_thread")]
async fn a_web_wallpaper_inherits_the_choice() {
    for (saved, expected) in [(None, true), (Some(true), true), (Some(false), false)] {
        let engine = FakeEngineFacade::default();
        engine.set_snapshot(vec![main_display()]);
        let fixture = bridge(&engine, web_state(saved), false);
        let pages = fixture
            .bridge
            .web_wallpapers()
            .await
            .expect("web wallpapers");
        assert_eq!(pages.len(), 1);
        assert_eq!(
            pages[0].media_integration_enabled, expected,
            "saved choice {saved:?}"
        );
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn previews_and_the_lock_screen_do_not_take_the_media_choice() {
    let engine = FakeEngineFacade::default();
    engine.set_snapshot(vec![main_display()]);
    let mut app = AppConfig::default();
    app.monitors = vec![showing(SerializedSelector::Primary, NOCTURNE)];
    let mut state = installed(app, vec![(NOCTURNE, None)]);
    state.project_models.insert(
        NOCTURNE.into(),
        ProjectModel::parse(
            NOCTURNE,
            r#"{"title":"Nocturne","type":"scene","file":"scene.json","general":{"properties":{}}}"#,
        )
        .expect("scene project"),
    );
    let fixture = bridge(&engine, state, false);

    let mut exports = Vec::new();
    for choice in [true, false] {
        fixture
            .bridge
            .set_media_integration_enabled(NOCTURNE.into(), choice)
            .await
            .expect("media choice");
        let lock = fixture
            .bridge
            .lock_screen_scenes()
            .await
            .expect("lock screen");
        assert_eq!(lock.len(), 1);
        let preview = fixture
            .bridge
            .wallpaper_preview(NOCTURNE.into(), "primary".into(), Vec::new())
            .await
            .expect("preview");
        exports.push((lock, preview));
    }
    assert_eq!(
        exports[0], exports[1],
        "the media choice reaches neither export"
    );
}
