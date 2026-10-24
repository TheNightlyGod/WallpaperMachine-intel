pub mod app;
pub mod store;
pub mod wallpaper;
pub mod writer;

pub use app::{
    AppConfig, BatteryModeCfg, FilterCfg, GeneralCfg, MonitorCfg, MonitorSettingsCfg, PowerCfg,
    QualityCfg, QualityInForce, QualityProfileCfg, SceneResolutionCfg, SerializedSelector, UiCfg,
    WindowGeom, clamp_render_scale,
};
pub use store::{ConfigLoad, ConfigStore};
pub use wallpaper::{
    AudioCfg, FramingCfg, MEDIA_INTEGRATION_DEFAULT, MonitorRender, WallpaperConfig,
};

pub(crate) fn resolve_frame_rate(frame_rate: Option<u32>, refresh_hz: u32) -> u32 {
    let refresh = refresh_hz.max(1);
    frame_rate.map_or(refresh.min(60), |rate| rate.clamp(1, refresh))
}

pub(crate) fn stored_frame_rate(requested: u32, refresh_hz: u32) -> Option<u32> {
    let bounded = requested.clamp(1, refresh_hz.max(1));
    (bounded != resolve_frame_rate(None, refresh_hz)).then_some(bounded)
}

fn scaling_mode(raw: &str) -> wallpaper_core::project::ScalingMode {
    use wallpaper_core::project::ScalingMode;
    if raw.eq_ignore_ascii_case("none") {
        ScalingMode::None
    } else if raw.eq_ignore_ascii_case("stretch") {
        ScalingMode::Stretch
    } else if raw.eq_ignore_ascii_case("fit") {
        ScalingMode::Fit
    } else if raw.eq_ignore_ascii_case("fit_blurred") {
        ScalingMode::FitBlurred
    } else {
        ScalingMode::Fill
    }
}

#[derive(Default)]
enum Presence<T> {
    #[default]
    Missing,
    Present(T),
}

impl<'de, T: serde::Deserialize<'de>> serde::Deserialize<'de> for Presence<T> {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        T::deserialize(deserializer).map(Self::Present)
    }
}

fn read_frame_rate(modern: Presence<Option<u32>>, legacy: Option<u32>) -> Option<u32> {
    match modern {
        Presence::Present(rate) => rate,
        Presence::Missing => legacy.filter(|&rate| rate != 60).map(|rate| rate.max(1)),
    }
}

#[cfg(test)]
mod contract_tests;
