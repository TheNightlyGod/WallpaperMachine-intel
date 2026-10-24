//! A scene is only built with an audio volume the renderer can use.

use wallpaper_core::{DisplayDesc, EngineError, media::audio::AudioVolume, project::SceneDesc};

fn build_with_volume(volume: f32) -> Result<SceneDesc, EngineError> {
    SceneDesc::builder(DisplayDesc::new(1, 0, 0, 2560, 1440, 2.0), "/tmp/project.json")
        .assets_path("/tmp/assets")
        .audio_volume(volume)
        .build()
}

#[test]
fn volumes_outside_zero_to_one_or_not_finite_are_rejected_with_one_message() {
    for volume in [f32::NAN, -0.01, 1.01, f32::INFINITY, f32::NEG_INFINITY] {
        match build_with_volume(volume) {
            Err(EngineError::InvalidInput(message)) => assert_eq!(
                message, "audio_volume must be finite and within [0.0, 1.0]",
                "volume {volume}"
            ),
            other => panic!("volume {volume} was not rejected as invalid input: {other:?}"),
        }
    }
}

#[test]
fn the_limits_themselves_are_accepted() {
    for volume in [0.0, 0.5, 1.0] {
        let scene = build_with_volume(volume).unwrap();
        assert_eq!(scene.audio_volume, AudioVolume::try_from(volume).unwrap());
    }
}
