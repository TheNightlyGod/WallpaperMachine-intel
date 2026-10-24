//! The engine actor answers messages from its configured displays, and a
//! stopped actor reports itself as one.

use crate::{
    DisplayConfig, DisplayIdentity, DisplaySelector, EngineError, WallpaperEngine,
    WallpaperEngineConfig,
};

#[tokio::test(flavor = "current_thread")]
async fn an_engine_built_from_the_default_config_answers_a_ping() {
    let engine = WallpaperEngine::with_config(WallpaperEngineConfig::default()).unwrap();

    engine.actor_ping_for_test().await.unwrap();
}

#[tokio::test(flavor = "current_thread")]
async fn a_message_to_a_stopped_actor_is_a_platform_error_naming_the_actor() {
    let error = WallpaperEngine::actor_closed_error_for_test().await;

    assert!(matches!(error, EngineError::Platform(_)), "got {error:?}");
    assert!(error.to_string().contains("engine actor"), "got {error}");
}

#[tokio::test(flavor = "current_thread")]
async fn the_actor_starts_with_one_record_per_configured_display() {
    let external = DisplayIdentity {
        uuid: Some("external".to_owned()),
        vendor_id: Some(1),
        model_id: Some(2),
        serial_number: Some(3),
        unit_number: Some(4),
        name: None,
    };
    let engine = WallpaperEngine::with_config(WallpaperEngineConfig {
        displays: vec![
            DisplayConfig { selector: DisplaySelector::Primary, window_active: true, wallpaper: None },
            DisplayConfig {
                selector: DisplaySelector::Identity(external),
                window_active: true,
                wallpaper: None,
            },
        ],
    })
    .unwrap();

    assert_eq!(engine.actor_display_record_count_for_test().await.unwrap(), 2);
}
