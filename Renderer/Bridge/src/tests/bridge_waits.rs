//! Helpers the lifecycle tests of this suite share for waiting on the fake
//! engine and driving the common "show this wallpaper on the primary display"
//! sequence.

use std::time::{Duration, Instant};

use crate::WallpaperBridge;
use crate::engine::FakeEngineFacade;

/// Polls until the engine has been asked to reconcile exactly `expected` times.
/// Exact equality: a run that reconciled more has done something else.
pub(super) async fn wait_for_reconciles(
    engine: &FakeEngineFacade,
    expected: usize,
    bound: Duration,
) -> bool {
    let deadline = Instant::now() + bound;
    loop {
        if engine.reconcile_call_count() == expected {
            return true;
        }
        if Instant::now() >= deadline {
            return false;
        }
        tokio::time::sleep(Duration::from_millis(1)).await;
    }
}

/// Polls until the engine has been asked to reconcile at least `minimum` times.
pub(super) async fn wait_for_at_least(
    engine: &FakeEngineFacade,
    minimum: usize,
    bound: Duration,
) -> bool {
    let deadline = Instant::now() + bound;
    loop {
        if engine.reconcile_call_count() >= minimum {
            return true;
        }
        if Instant::now() >= deadline {
            return false;
        }
        tokio::time::sleep(Duration::from_millis(1)).await;
    }
}

/// Turns the wallpaper on for the primary display and applies it.
pub(super) async fn apply_on_primary(bridge: &WallpaperBridge, wallpaper_id: &str) {
    bridge
        .set_display_config_enabled(wallpaper_id.to_owned(), "primary".to_owned(), true)
        .await
        .expect("the primary display should accept the wallpaper");
    bridge
        .apply_wallpaper_options(wallpaper_id.to_owned(), true)
        .await
        .expect("applying the wallpaper should succeed");
}
