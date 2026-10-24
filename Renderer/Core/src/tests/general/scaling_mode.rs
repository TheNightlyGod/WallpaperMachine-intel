//! "Fit with blurred backdrop" travels from a scene descriptor to the engine's
//! scaling-mode property without disturbing the other modes.
use crate::{
    DisplayDesc,
    owe::backend::scaling_mode_property_value,
    project::{ScalingMode, SceneDesc, SceneTemplate},
};

#[test]
fn fit_with_blurred_backdrop_reaches_the_engine_as_mode_four() {
    assert_eq!(scaling_mode_property_value(ScalingMode::FitBlurred), 4);
}

#[test]
fn the_other_scaling_modes_keep_their_engine_values() {
    let values = [
        ScalingMode::None,
        ScalingMode::Stretch,
        ScalingMode::Fit,
        ScalingMode::Fill,
    ]
    .map(scaling_mode_property_value);
    assert_eq!(values, [0, 1, 2, 3]);
}

#[test]
fn a_scene_keeps_the_blurred_fit_through_its_template() {
    let display = DisplayDesc::new(4, 0, 0, 5120, 2880, 2.0);
    let scene = SceneDesc::builder(display.clone(), "/library/drift/scene.json")
        .scaling_mode(ScalingMode::FitBlurred)
        .build()
        .expect("a valid scene descriptor");
    let template = SceneTemplate::from_scene_desc(&scene);
    assert_eq!(template.scaling_mode, ScalingMode::FitBlurred);
    let rebuilt = template.for_display(display);
    assert_eq!(rebuilt.scaling_mode, ScalingMode::FitBlurred);
    assert_eq!(rebuilt, scene);
}

#[test]
fn the_blurred_fit_has_its_own_configuration_name() {
    assert_eq!(ScalingMode::FitBlurred.to_string(), "fit_blurred");
    assert_eq!(ScalingMode::Fit.to_string(), "fit");
}
