//! Scene descriptors and templates carry every field across: what a caller
//! hands in is what the renderer later reads back.

use crate::{
    DisplayDesc, EngineError,
    media::audio::AudioVolume,
    project::{ScalingMode, SceneDesc, SceneFraming, SceneTemplate},
};

const EPSILON: f64 = f64::EPSILON;

fn secondary_display() -> DisplayDesc {
    DisplayDesc::new(42, -1920, 0, 1920, 1080, 2.0)
}

/// A scene whose every field differs from the builder defaults.
fn busy_scene() -> SceneDesc {
    SceneDesc::builder(secondary_display(), "/scene/project.json")
        .assets_path("/scene/assets")
        .fps(75)
        .scaling_mode(ScalingMode::Fit)
        .scaling_factor(1.25)
        .framing(SceneFraming { pan_x: 0.1, pan_y: 0.9 })
        .paused(true)
        .audio_response_enabled(true)
        .media_integration_enabled(true)
        .audio_volume(0.5)
        .audio_muted(true)
        .property_override_json(r#"{"general":{"brightness":1}}"#)
        .shader_cache_path("/tmp/cache")
        .force_shader_refresh(true)
        .build()
        .unwrap()
}

#[test]
fn a_new_scene_keeps_its_arguments_and_defaults_the_rest() {
    let display = secondary_display();

    let SceneDesc {
        display: kept_display,
        scene_path,
        assets_path,
        fps,
        paused,
        audio_response_enabled,
        media_integration_enabled,
        audio_muted,
        force_shader_refresh,
        property_override_json,
        shader_cache_path,
        ..
    } = SceneDesc::new(display.clone(), "/scene/project.json", "/scene/assets", 60, false);

    assert_eq!(kept_display, display);
    assert_eq!(kept_display.display_id, 42);
    assert_eq!(
        (scene_path.as_str(), assets_path.as_str(), fps, paused),
        ("/scene/project.json", "/scene/assets", 60, false)
    );
    assert_eq!(
        [audio_response_enabled, media_integration_enabled, audio_muted, force_shader_refresh],
        [false; 4]
    );
    assert_eq!((property_override_json, shader_cache_path), (None, None));
}

#[test]
fn a_template_with_every_option_copies_all_of_them_into_a_scene_for_a_display() {
    const OVERRIDES: &str = r#"{"general":{"brightness":1}}"#;
    const CACHE: &str = "/tmp/cache";
    let display = secondary_display();
    let template = SceneTemplate::builder("/scene/project.json")
        .fps(75)
        .assets_path("/scene/assets")
        .scaling_factor(1.25)
        .scaling_mode(ScalingMode::Fill)
        .audio_volume(0.5)
        .paused(true)
        .audio_muted(true)
        .audio_response_enabled(true)
        .media_integration_enabled(true)
        .force_shader_refresh(true)
        .property_override_json(OVERRIDES)
        .shader_cache_path(CACHE)
        .build()
        .unwrap();

    let scene = template.for_display(display.clone());

    assert_eq!(scene.display, display);
    assert_eq!(
        (scene.scene_path.as_str(), scene.assets_path.as_str(), scene.fps),
        ("/scene/project.json", "/scene/assets", 75)
    );
    assert_eq!(scene.scaling_mode, ScalingMode::Fill);
    assert!((scene.scaling_factor - 1.25).abs() <= EPSILON);
    assert_eq!(scene.audio_volume, AudioVolume::try_from(0.5).unwrap());
    assert_eq!(
        [
            scene.paused,
            scene.audio_response_enabled,
            scene.media_integration_enabled,
            scene.audio_muted,
            scene.force_shader_refresh,
        ],
        [true; 5]
    );
    assert_eq!(scene.property_override_json.as_deref(), Some(OVERRIDES));
    assert_eq!(scene.shader_cache_path.as_deref(), Some(CACHE));
}

#[test]
fn a_template_copied_from_a_scene_keeps_the_scheduling_fields() {
    let scene = SceneDesc::builder(DisplayDesc::new(1, 0, 0, 1920, 1080, 1.0), "/tmp/project.json")
        .assets_path("/tmp/assets")
        .fps(30)
        .build()
        .unwrap();

    let template = SceneTemplate::from_scene_desc(&scene);

    assert_eq!(template.scene_path, scene.scene_path);
    assert_eq!(template.assets_path, scene.assets_path);
    assert_eq!(template.fps, scene.fps);
    assert_eq!(template.scaling_mode, scene.scaling_mode);
    assert!((template.scaling_factor - scene.scaling_factor).abs() <= EPSILON);
}

#[test]
fn a_scene_survives_the_trip_through_a_template_and_back() {
    let scene = busy_scene();

    let again = SceneTemplate::from_scene_desc(&scene).for_display(scene.display.clone());

    assert_eq!(again, scene);
}

#[test]
fn a_template_copied_from_a_scene_carries_the_options_too() {
    let scene = busy_scene();

    let template = SceneTemplate::from_scene_desc(&scene);

    assert_eq!(template.framing, scene.framing);
    assert_eq!(template.paused, scene.paused);
    assert_eq!(template.audio_response_enabled, scene.audio_response_enabled);
    assert_eq!(template.media_integration_enabled, scene.media_integration_enabled);
    assert_eq!(template.audio_volume, scene.audio_volume);
    assert_eq!(template.audio_muted, scene.audio_muted);
    assert_eq!(template.property_override_json, scene.property_override_json);
    assert_eq!(template.shader_cache_path, scene.shader_cache_path);
    assert_eq!(template.force_shader_refresh, scene.force_shader_refresh);
}

#[test]
fn a_scene_is_the_same_wallpaper_on_another_display_or_while_paused_differently() {
    let scene = busy_scene();
    let mut moved = scene.clone();
    moved.display = DisplayDesc::new(7, 100, 200, 800, 600, 1.0);
    moved.paused = !scene.paused;

    assert!(scene.same_wallpaper(&moved));
    assert!(moved.same_wallpaper(&scene));
    assert!(scene.same_wallpaper(&scene.clone()));
}

#[test]
fn changing_any_compared_field_makes_it_a_different_wallpaper() {
    let scene = busy_scene();
    let changes: [(&str, fn(&mut SceneDesc)); 13] = [
        ("scene path", |scene| scene.scene_path.push('x')),
        ("assets path", |scene| scene.assets_path.push('x')),
        ("fps", |scene| scene.fps += 1),
        ("scaling mode", |scene| scene.scaling_mode = ScalingMode::Stretch),
        ("scaling factor", |scene| scene.scaling_factor += 1e-9),
        ("framing", |scene| scene.framing.pan_x = 0.5),
        ("audio response", |scene| scene.audio_response_enabled = false),
        ("media integration", |scene| scene.media_integration_enabled = false),
        ("volume", |scene| scene.audio_volume = AudioVolume::try_from(0.25).unwrap()),
        ("mute", |scene| scene.audio_muted = false),
        ("override json", |scene| scene.property_override_json = None),
        ("shader cache path", |scene| scene.shader_cache_path = None),
        ("force refresh", |scene| scene.force_shader_refresh = false),
    ];

    for (field, change) in changes {
        let mut other = scene.clone();
        change(&mut other);
        assert!(!scene.same_wallpaper(&other), "{field} is not compared");
        assert!(!other.same_wallpaper(&scene), "{field} is not compared (reversed)");
    }
}

#[test]
fn a_scaling_factor_one_epsilon_apart_is_still_the_same_wallpaper() {
    let scene = busy_scene();
    let mut nudged = scene.clone();
    nudged.scaling_factor += EPSILON;
    assert_ne!(nudged.scaling_factor, scene.scaling_factor, "the nudge must change the value");

    assert!(scene.same_wallpaper(&nudged));
    assert!(nudged.same_wallpaper(&scene));
}

#[test]
fn completing_a_shader_refresh_only_clears_the_force_flag() {
    let scene = busy_scene();
    let mut completed = scene.clone();

    completed.mark_shader_refresh_complete();

    assert!(!completed.force_shader_refresh);
    let mut expected = scene;
    expected.force_shader_refresh = false;
    assert_eq!(completed, expected);
}

#[test]
fn builders_report_the_first_problem_in_a_fixed_order() {
    let invalid = |result: Result<SceneTemplate, EngineError>| match result {
        Err(EngineError::InvalidInput(message)) => message,
        other => panic!("expected invalid input, got {other:?}"),
    };

    assert_eq!(
        invalid(SceneTemplate::builder("").audio_volume(f32::NAN).build()),
        "scene_path must not be empty"
    );
    assert_eq!(
        invalid(SceneTemplate::builder("/p.json").fps(0).audio_volume(f32::NAN).build()),
        "fps must be greater than zero"
    );
    assert_eq!(
        invalid(SceneTemplate::builder("/p.json").audio_volume(f32::NAN).build()),
        "audio_volume must be finite and within [0.0, 1.0]"
    );
    for volume in [0.0, 0.5, 1.0] {
        let template = SceneTemplate::builder("/p.json").audio_volume(volume).build().unwrap();
        assert_eq!(template.audio_volume, AudioVolume::try_from(volume).unwrap());
    }
}

#[test]
fn a_scene_builder_does_not_check_the_display_and_orders_its_errors_the_same_way() {
    let display = DisplayDesc::new(0, 0, 0, 1920, 1080, 1.0);

    let scene = SceneDesc::builder(display.clone(), "/p.json").build().unwrap();
    assert_eq!(scene.display.display_id, 0);
    assert!(scene.validate().is_err());

    for (builder, expected) in [
        (SceneDesc::builder(display.clone(), "").audio_volume(f32::NAN), "scene_path must not be empty"),
        (SceneDesc::builder(display.clone(), "/p.json").fps(0).audio_volume(2.0), "fps must be greater than zero"),
        (
            SceneDesc::builder(display, "/p.json").audio_volume(-1.0),
            "audio_volume must be finite and within [0.0, 1.0]",
        ),
    ] {
        match builder.build() {
            Err(EngineError::InvalidInput(message)) => assert_eq!(message, expected),
            other => panic!("expected invalid input {expected:?}, got {other:?}"),
        }
    }
}
