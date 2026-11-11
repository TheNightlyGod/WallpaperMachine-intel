//! Wallpaper Engine's per-wallpaper options (plan step 10.2): which rows each
//! kind of wallpaper offers, which edits the bridge refuses, Apply and Revert,
//! and the live preview of a scene, against the fake engine.

use wallpaper_core::{SceneTraits, project::SceneUserOptions};

use super::display_position::{identified_display, running};
use crate::{
    BridgeEngineOptionEdit, BridgeEngineOptionId, BridgeEngineOptions, BridgeErrorKind,
    BridgePropertyValue, WallpaperBridge,
    api::BridgeBuilder,
    config::ConfigStore,
    engine::{EngineFacade as _, FakeEngineFacade},
    paths::BridgePaths,
};

const SCENE: &str = r#"{"type":"scene","title":"Scene","file":"scene.pkg",
    "general":{"properties":{"glow":{"type":"bool","text":"Glow","value":false,"order":1}}}}"#;
const VIDEO: &str = r#"{"type":"video","title":"Clip","file":"clip.mp4","general":{"properties":{}}}"#;
const WEB: &str = r#"{"type":"web","title":"Web","file":"index.html","general":{"properties":{}}}"#;

struct Harness {
    bridge: WallpaperBridge,
    engine: FakeEngineFacade,
    paths: BridgePaths,
    _home: tempfile::TempDir,
}

/// A bridge over a home of its own whose shared assets offer the image
/// filters `amber` and `teal`.
fn harness(engine: &FakeEngineFacade) -> Harness {
    let home = tempfile::tempdir().unwrap();
    let paths = BridgePaths::for_home(home.path());
    let lut = crate::engine::lut_catalog::lut_directory(&paths.assets_root());
    std::fs::create_dir_all(&lut).unwrap();
    for name in ["teal.tex", "amber.tex"] {
        std::fs::write(lut.join(name), b"TEXV0005").unwrap();
    }
    let bridge = BridgeBuilder::new(engine.clone())
        .with_config_store(ConfigStore::open(home.path().join("store")))
        .with_paths(paths.clone())
        .with_mouse_polling_enabled(false)
        .with_power_watching_enabled(false)
        .build()
        .expect("bridge over a temporary home");
    Harness { bridge, engine: engine.clone(), paths, _home: home }
}

impl Harness {
    async fn options(&self, id: &str) -> Option<BridgeEngineOptions> {
        self.bridge.wallpaper_options_snapshot(id.into()).await.unwrap().engine_options
    }

    async fn edit(&self, id: &str, option: BridgeEngineOptionId, value: BridgePropertyValue) -> Result<(), crate::BridgeError> {
        self.bridge.edit_engine_option(id.into(), option, value).await.map(|_| ())
    }

    /// Wallpaper `id` applied to display 7 and running.
    async fn running_on_display(&self, id: &str, project: &str) {
        self.engine.set_snapshot(vec![identified_display(7)]);
        self.bridge.inject_scene_project_for_test(id, "Wallpaper", project).await;
        self.bridge.set_display_config_enabled(id.into(), "7".into(), true).await.unwrap();
        self.bridge.apply_wallpaper_options(id.into(), true).await.unwrap();
        self.engine.set_snapshot(running(&self.engine.rendered_scenes()));
    }
}

fn number(value: f64) -> BridgePropertyValue {
    BridgePropertyValue::Number { value }
}
fn on(value: bool) -> BridgePropertyValue {
    BridgePropertyValue::Bool { value }
}
fn text(value: &str) -> BridgePropertyValue {
    BridgePropertyValue::String { value: value.into() }
}

fn ids(options: &BridgeEngineOptions) -> Vec<BridgeEngineOptionId> {
    options.rows.iter().map(|row| row.id).collect()
}

#[tokio::test]
async fn each_kind_offers_wallpaper_engines_rows_and_a_scene_offers_mouse_parallax_from_its_file() {
    use BridgeEngineOptionId as Id;
    let engine = FakeEngineFacade::default();
    let h = harness(&engine);
    h.bridge.inject_scene_project_for_test("scene", "Scene", SCENE).await;
    h.bridge.inject_scene_project_for_test("parallax", "Scene", SCENE).await;
    h.bridge.inject_scene_project_for_test("video", "Clip", VIDEO).await;
    h.bridge.inject_scene_project_for_test("web", "Web", WEB).await;
    engine.set_scene_traits(h.paths.project_json("parallax"), SceneTraits { camera_parallax_offered: true });

    let scene = h.options("scene").await.expect("a scene has options");
    assert_eq!(
        ids(&scene),
        [Id::ColorEnabled, Id::Brightness, Id::Contrast, Id::Saturation, Id::HueShift, Id::ImageFilter,
         Id::FilterStrength, Id::FlipHorizontal, Id::PlaybackRate]
    );
    assert_eq!(scene.image_filters, ["amber", "teal"]);
    let parallax = h.options("parallax").await.unwrap();
    assert!(ids(&parallax).contains(&Id::MouseParallax));
    let video = h.options("video").await.unwrap();
    assert!(ids(&video).contains(&Id::PlaybackRate));
    assert!(!ids(&video).contains(&Id::MouseParallax));
    assert!(h.options("web").await.is_none());

    // Read once per version of the scene file, not on every snapshot.
    let reads = engine.scene_traits_reads().len();
    h.options("parallax").await;
    assert_eq!(engine.scene_traits_reads().len(), reads);
}

#[tokio::test]
async fn rows_are_enabled_by_the_colour_switch_and_the_chosen_filter() {
    use BridgeEngineOptionId as Id;
    let engine = FakeEngineFacade::default();
    let h = harness(&engine);
    h.bridge.inject_scene_project_for_test("scene", "Scene", SCENE).await;
    let row = |options: &BridgeEngineOptions, id| options.rows.iter().find(|row| row.id == id).unwrap().clone();

    let options = h.options("scene").await.unwrap();
    assert!(!row(&options, Id::Brightness).enabled);
    assert!(!row(&options, Id::FilterStrength).enabled);
    assert!(row(&options, Id::FlipHorizontal).enabled);
    assert_eq!(row(&options, Id::FilterStrength).default_value, number(100.0));

    h.edit("scene", Id::ColorEnabled, on(true)).await.unwrap();
    h.edit("scene", Id::ImageFilter, text("amber")).await.unwrap();
    let options = h.options("scene").await.unwrap();
    assert!(row(&options, Id::Brightness).enabled);
    assert!(row(&options, Id::FilterStrength).enabled);
    assert!(row(&options, Id::ColorEnabled).modified);
    assert_eq!(row(&options, Id::ImageFilter).value, text("amber"));
    assert!(h.bridge.wallpaper_options_snapshot("scene".into()).await.unwrap().dirty);
}

#[tokio::test]
async fn edits_the_wallpaper_does_not_take_are_refused_and_change_nothing() {
    use BridgeEngineOptionId as Id;
    let engine = FakeEngineFacade::default();
    let h = harness(&engine);
    h.bridge.inject_scene_project_for_test("scene", "Scene", SCENE).await;
    h.bridge.inject_scene_project_for_test("video", "Clip", VIDEO).await;
    h.bridge.inject_scene_project_for_test("web", "Web", WEB).await;

    let refused = [
        ("web", Id::FlipHorizontal, on(true)),
        ("scene", Id::MouseParallax, on(false)),
        ("video", Id::MouseParallax, on(false)),
        ("scene", Id::ColorEnabled, number(1.0)),
        ("scene", Id::Brightness, on(true)),
        ("scene", Id::Brightness, number(f64::NAN)),
        ("scene", Id::Brightness, number(100.5)),
        ("scene", Id::PlaybackRate, number(9.0)),
        ("scene", Id::PlaybackRate, number(201.0)),
        ("scene", Id::ImageFilter, text("violet")),
        ("scene", Id::ImageFilter, text("../amber")),
        ("scene", Id::ImageFilter, number(1.0)),
        ("missing", Id::FlipHorizontal, on(true)),
    ];
    for (id, option, value) in refused {
        let error = h.edit(id, option, value.clone()).await.expect_err(&format!("{id} {option:?} {value:?}"));
        assert_eq!(error.kind(), BridgeErrorKind::InvalidInput, "{id} {option:?}");
    }
    assert!(!h.bridge.wallpaper_options_snapshot("scene".into()).await.unwrap().dirty);
    assert!(h.bridge.restore_all_engine_option_defaults("web".into()).await.is_err());
    assert!(h.bridge.restore_engine_option_default("video".into(), Id::MouseParallax).await.is_err());

    h.edit("scene", Id::ImageFilter, text("")).await.unwrap();
    h.edit("scene", Id::PlaybackRate, number(10.0)).await.unwrap();
    h.edit("video", Id::PlaybackRate, number(200.0)).await.unwrap();
}

#[tokio::test]
async fn apply_loads_the_scene_with_the_options_and_revert_puts_the_saved_ones_back() {
    use BridgeEngineOptionId as Id;
    let engine = FakeEngineFacade::default();
    let h = harness(&engine);
    h.running_on_display("100", SCENE).await;
    assert_eq!(engine.rendered_scenes()[0].user_options, SceneUserOptions::default());

    h.edit("100", Id::ColorEnabled, on(true)).await.unwrap();
    h.edit("100", Id::Brightness, number(60.0)).await.unwrap();
    h.edit("100", Id::PlaybackRate, number(150.0)).await.unwrap();
    assert_eq!(engine.rendered_scenes()[0].user_options, SceneUserOptions::default(), "an edit waits for Apply");
    h.bridge.apply_wallpaper_options("100".into(), true).await.unwrap();
    let applied = engine.rendered_scenes()[0].user_options.clone();
    assert!(applied.color_enabled);
    assert_eq!((applied.brightness, applied.playback_rate), (60.0, 150.0));

    h.edit("100", Id::FlipHorizontal, on(true)).await.unwrap();
    h.bridge.cancel_wallpaper_options("100".into()).await.unwrap();
    let options = h.options("100").await.unwrap();
    let flip = options.rows.iter().find(|row| row.id == Id::FlipHorizontal).unwrap();
    assert_eq!(flip.value, on(false));
    assert!(!h.bridge.wallpaper_options_snapshot("100".into()).await.unwrap().dirty);

    h.bridge.restore_all_engine_option_defaults("100".into()).await.unwrap();
    h.bridge.apply_wallpaper_options("100".into(), true).await.unwrap();
    assert_eq!(engine.rendered_scenes()[0].user_options, SceneUserOptions::default());
}

#[tokio::test]
async fn a_scene_is_shown_the_pending_options_and_the_saved_ones_when_the_preview_ends() {
    use BridgeEngineOptionId as Id;
    let engine = FakeEngineFacade::default();
    let h = harness(&engine);
    h.running_on_display("100", SCENE).await;
    let handle = engine.display_snapshot()[0].handle.unwrap();

    // Nothing edited and nothing shown: the engine is not asked.
    h.bridge.preview_wallpaper_properties("100".into(), true, Vec::new(), Vec::new()).await.unwrap();
    assert!(engine.preview_user_options_calls().is_empty());

    h.edit("100", Id::FlipHorizontal, on(true)).await.unwrap();
    let dragged = vec![BridgeEngineOptionEdit { option: Id::PlaybackRate, value: number(40.0) }];
    h.bridge.preview_wallpaper_properties("100".into(), true, Vec::new(), dragged).await.unwrap();
    let (shown_on, shown) = engine.preview_user_options_calls().last().cloned().unwrap();
    assert_eq!(shown_on, handle);
    assert!(shown.flip_horizontal);
    assert_eq!(shown.playback_rate, 40.0);
    assert!(h.options("100").await.unwrap().rows.iter().all(|row| row.id != Id::PlaybackRate || row.value == number(100.0)),
        "a value being shown is not an edit");

    h.bridge.preview_wallpaper_properties("100".into(), false, Vec::new(), Vec::new()).await.unwrap();
    let (_, saved) = engine.preview_user_options_calls().last().cloned().unwrap();
    assert_eq!(saved, SceneUserOptions::default());

    // A pending value the option does not take refuses the call before any
    // scene is told anything.
    let before = engine.preview_user_options_calls().len();
    let bad = vec![BridgeEngineOptionEdit { option: Id::Brightness, value: number(400.0) }];
    assert!(h.bridge.preview_wallpaper_properties("100".into(), true, Vec::new(), bad).await.is_err());
    assert_eq!(engine.preview_user_options_calls().len(), before);
}

#[tokio::test]
async fn the_preview_window_export_carries_the_pending_options_and_the_filter_file() {
    use BridgeEngineOptionId as Id;
    let engine = FakeEngineFacade::default();
    let h = harness(&engine);
    h.bridge.inject_scene_project_for_test("scene", "Scene", SCENE).await;
    h.bridge.inject_scene_project_for_test("web", "Web", WEB).await;
    h.edit("scene", Id::ImageFilter, text("amber")).await.unwrap();

    let dragged = vec![BridgeEngineOptionEdit { option: Id::FilterStrength, value: number(25.0) }];
    let preview = h.bridge.wallpaper_preview("scene".into(), "primary".into(), Vec::new(), dragged).await.unwrap();
    let options = preview.engine_options.expect("a scene preview has options");
    assert_eq!((options.image_filter.as_str(), options.filter_strength), ("amber", 25.0));
    let lut = preview.lut_path.expect("the chosen filter's file exists");
    assert!(lut.ends_with("materials/lut/amber.tex"), "{lut}");

    let web = h.bridge.wallpaper_preview("web".into(), "primary".into(), Vec::new(), Vec::new()).await.unwrap();
    assert!(web.engine_options.is_none() && web.lut_path.is_none());
}

#[tokio::test]
async fn a_scenes_lock_screen_export_carries_its_options_and_quality_and_no_border() {
    let engine = FakeEngineFacade::default();
    let h = harness(&engine);
    h.running_on_display("scene", SCENE).await;
    let lock = h.bridge.lock_screen_scenes().await.unwrap();
    let lock = lock.iter().find(|row| row.wallpaper_id == "scene").expect("the scene is exported");
    assert!(lock.engine_options.is_some());
    assert!(lock.scene_quality.is_some());
    assert!(lock.border_color.is_none());
}
