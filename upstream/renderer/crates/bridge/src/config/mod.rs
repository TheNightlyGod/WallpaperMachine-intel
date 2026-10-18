//! On-disk persistence.

use serde::Deserialize;

pub mod app;
pub mod store;
pub mod wallpaper;
pub mod writer;

pub use app::{
    AppConfig, BatteryModeCfg, FilterCfg, GeneralCfg, MonitorCfg, MonitorSettingsCfg, PowerCfg,
    QualityCfg, QualityInForce, QualityProfileCfg, SceneRendererModeCfg, SceneResolutionCfg,
    SerializedSelector, UiCfg, VideoBackendModeCfg, WindowGeom, clamp_render_scale,
};
pub use store::{ConfigLoad, ConfigStore};
pub use wallpaper::{AudioCfg, FramingCfg, MonitorRender, WallpaperConfig};

/// The rate older builds wrote when the user had never chosen one.
///
/// Indistinguishable from an untouched value, so loading it means "the
/// default" rather than "the user asked for 60".
pub(crate) const LEGACY_DEFAULT_FRAME_RATE: u32 = 60;

/// The highest rate a display runs at when nobody chose one.
///
/// A wallpaper's cost follows its frame rate: on a 120 Hz M3 Max display a
/// scene drawn about 89 times a second took about 5.1 W of app power and 0.5 W
/// of WindowServer compositing, and about 3.1 W and 0.3 W at 60. So a display
/// that refreshes faster runs at 60 until the user picks more.
pub(crate) const DEFAULT_FRAME_RATE_CEILING: u32 = 60;

/// The rate `None` stands for on a display: its refresh, at most
/// [`DEFAULT_FRAME_RATE_CEILING`].
#[must_use]
pub(crate) fn default_frame_rate(refresh_hz: u32) -> u32 {
    refresh_hz.max(1).min(DEFAULT_FRAME_RATE_CEILING)
}

/// Resolves a saved rate against the display refresh.
///
/// `None` follows the display up to the default ceiling. A saved rate is never
/// below 1 and never above what the display can present.
#[must_use]
pub(crate) fn resolve_frame_rate(frame_rate: Option<u32>, refresh_hz: u32) -> u32 {
    let max = refresh_hz.max(1);
    frame_rate.map_or_else(|| default_frame_rate(refresh_hz), |fps| fps.max(1).min(max))
}

/// The default rate for this display is stored as `None`, so it keeps
/// following the display; any other rate, including a refresh above the
/// default, is stored as chosen, clamped to 1...refresh.
#[must_use]
pub(crate) fn stored_frame_rate(requested: u32, refresh_hz: u32) -> Option<u32> {
    let requested = requested.max(1).min(refresh_hz.max(1));
    if requested == default_frame_rate(refresh_hz) {
        None
    } else {
        Some(requested)
    }
}

/// `explicit` is `Some` when the new key was present, including a JSON null,
/// so a legacy key cannot override a choice this build (or a hand edit) wrote.
#[must_use]
pub(crate) fn frame_rate_from_legacy(
    explicit: Option<Option<u32>>,
    legacy: Option<u32>,
) -> Option<u32> {
    explicit.unwrap_or_else(|| match legacy {
        Some(LEGACY_DEFAULT_FRAME_RATE) | None => None,
        Some(rate) => Some(rate.max(1)),
    })
}

/// Distinguishes a missing field from a present one, including JSON null.
///
/// `#[serde(default)]` alone collapses both to `None`, which would let a
/// legacy key override an explicit `frame_rate` of null.
pub(crate) fn deserialize_present<'de, T, D>(deserializer: D) -> Result<Option<T>, D::Error>
where
    T: Deserialize<'de>,
    D: serde::Deserializer<'de>,
{
    T::deserialize(deserializer).map(Some)
}
