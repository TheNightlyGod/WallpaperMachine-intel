use wallpaper_core::WallpaperEngineConfig;

#[tokio::test(flavor = "current_thread")]
async fn actor_processes_test_messages_in_mailbox_order() {
    let engine = wallpaper_core::WallpaperEngine::with_config(WallpaperEngineConfig::default())
        .expect("engine should initialize");

    let first = engine.actor_sequence_for_test(1).await.unwrap();
    let second = engine.actor_sequence_for_test(2).await.unwrap();

    assert_eq!(first, 1);
    assert_eq!(second, 2);
}
