use serde::{Deserialize, Serialize};
use wallpaper_core::project::ScalingMode;
use wallpaper_core::{DisplayIdentity, DisplaySelector};

use super::{Presence, read_frame_rate, resolve_frame_rate};

pub const SCHEMA_VERSION: u32 = 1;
pub const MIN_RENDER_SCALE: f32 = 0.25;
pub const MAX_RENDER_SCALE: f32 = 1.0;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct AppConfig {
    pub schema_version: u32,
    pub general: GeneralCfg,
    pub power: PowerCfg,
    pub ui: UiCfg,
    pub experimental: ExperimentalCfg,
    pub quality: QualityCfg,
    /// The stable identity of the display the `primary` block last described,
    /// so a change of main display can be told apart from a renamed one. Absent
    /// in older configurations and while the main display has no stable
    /// identity.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub primary_display: Option<SerializedSelector>,
    pub monitors: Vec<MonitorCfg>,
    pub monitor_settings: Vec<MonitorSettingsCfg>,
    pub diagnostics: DiagnosticsCfg,
}

impl Default for AppConfig {
    fn default() -> Self {
        Self {
            schema_version: SCHEMA_VERSION,
            general: GeneralCfg::default(),
            power: PowerCfg::default(),
            ui: UiCfg::default(),
            experimental: ExperimentalCfg::default(),
            quality: QualityCfg::default(),
            primary_display: None,
            monitors: Vec::new(),
            monitor_settings: Vec::new(),
            diagnostics: DiagnosticsCfg::default(),
        }
    }
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct GeneralCfg {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_selected_wallpaper: Option<String>,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SceneResolutionCfg {
    Canvas,
    #[default]
    Display,
}

#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct QualityProfileCfg {
    pub render_scale: f32,
    pub target_fps: u32,
}

impl Default for QualityProfileCfg {
    fn default() -> Self {
        Self {
            render_scale: 0.75,
            target_fps: 30,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct QualityCfg {
    pub render_scale: f32,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub frame_rate_cap: Option<u32>,
    #[serde(rename = "battery_profile_enabled", skip_serializing)]
    pub legacy_battery_profile_enabled: Option<bool>,
    pub battery: QualityProfileCfg,
    pub scene_optimization_enabled: bool,
    pub scene_on_demand_enabled: bool,
    pub scene_resolution: SceneResolutionCfg,
}

impl Default for QualityCfg {
    fn default() -> Self {
        Self {
            render_scale: 1.0,
            frame_rate_cap: None,
            legacy_battery_profile_enabled: None,
            battery: QualityProfileCfg::default(),
            scene_optimization_enabled: true,
            scene_on_demand_enabled: false,
            scene_resolution: SceneResolutionCfg::default(),
        }
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct ExperimentalCfg {
    pub scene_video_plane_sampling: bool,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum BatteryModeCfg {
    #[default]
    KeepRunning,
    ReducedQuality,
    Pause,
}

#[derive(Clone, Copy, Debug, Default, Serialize)]
pub struct PowerCfg {
    pub on_battery: BatteryModeCfg,
    #[serde(skip_serializing)]
    pub legacy_pause_on_battery_power: Option<bool>,
    #[serde(skip_serializing)]
    pub on_battery_explicit: bool,
}

impl PartialEq for PowerCfg {
    fn eq(&self, other: &Self) -> bool {
        self.on_battery == other.on_battery
            && self.legacy_pause_on_battery_power == other.legacy_pause_on_battery_power
    }
}

impl Eq for PowerCfg {}

impl<'de> Deserialize<'de> for PowerCfg {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        #[derive(Deserialize)]
        struct Fields {
            #[serde(default)]
            on_battery: Presence<BatteryModeCfg>,
            #[serde(default, rename = "pause_on_battery_power")]
            legacy_pause_on_battery_power: Option<bool>,
        }
        let fields = Fields::deserialize(deserializer)?;
        let (on_battery, on_battery_explicit) = match fields.on_battery {
            Presence::Missing => (BatteryModeCfg::default(), false),
            Presence::Present(mode) => (mode, true),
        };
        Ok(Self {
            on_battery,
            legacy_pause_on_battery_power: fields.legacy_pause_on_battery_power,
            on_battery_explicit,
        })
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct DiagnosticsCfg {
    pub verbose_logging: bool,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct UiCfg {
    pub selector_window: WindowGeom,
    pub settings_window: WindowGeom,
    pub filter: FilterCfg,
}

impl Default for UiCfg {
    fn default() -> Self {
        Self {
            selector_window: WindowGeom {
                x: 200,
                y: 200,
                width: 1100,
                height: 720,
            },
            settings_window: WindowGeom {
                x: 520,
                y: 260,
                width: 520,
                height: 440,
            },
            filter: FilterCfg::default(),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct WindowGeom {
    pub x: i32,
    pub y: i32,
    pub width: u32,
    pub height: u32,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct FilterCfg {
    pub scene: bool,
    pub video: bool,
    pub web: bool,
    pub unknown: bool,
}

impl Default for FilterCfg {
    fn default() -> Self {
        Self {
            scene: true,
            video: true,
            web: true,
            unknown: true,
        }
    }
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum SerializedSelector {
    #[default]
    Primary,
    /// A display named by what it is, not by the number it got this boot.
    /// Fields that are not known are left out of the file, and a file that
    /// lacks a field reads it as unknown, so older and newer files interoperate.
    Identity {
        #[serde(skip_serializing_if = "Option::is_none", default)]
        uuid: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none", default)]
        vendor_id: Option<u32>,
        #[serde(skip_serializing_if = "Option::is_none", default)]
        model_id: Option<u32>,
        #[serde(skip_serializing_if = "Option::is_none", default)]
        serial_number: Option<u32>,
        #[serde(skip_serializing_if = "Option::is_none", default)]
        unit_number: Option<u32>,
        #[serde(skip_serializing_if = "Option::is_none", default)]
        name: Option<String>,
    },
    LiveDisplayId {
        display_id: u32,
    },
}

impl SerializedSelector {
    pub fn to_selector(&self) -> DisplaySelector {
        match self {
            Self::Primary => DisplaySelector::Primary,
            Self::Identity {
                uuid,
                vendor_id,
                model_id,
                serial_number,
                unit_number,
                name,
            } => DisplaySelector::Identity(DisplayIdentity {
                uuid: uuid.clone(),
                vendor_id: *vendor_id,
                model_id: *model_id,
                serial_number: *serial_number,
                unit_number: *unit_number,
                name: name.clone(),
            }),
            Self::LiveDisplayId { display_id } => DisplaySelector::LiveDisplayId(*display_id),
        }
    }

    pub fn from_selector(sel: &DisplaySelector) -> Self {
        match sel {
            DisplaySelector::Primary => Self::Primary,
            DisplaySelector::LiveDisplayId(display_id) => Self::LiveDisplayId {
                display_id: *display_id,
            },
            DisplaySelector::Identity(DisplayIdentity {
                uuid,
                vendor_id,
                model_id,
                serial_number,
                unit_number,
                name,
            }) => Self::Identity {
                uuid: uuid.clone(),
                vendor_id: *vendor_id,
                model_id: *model_id,
                serial_number: *serial_number,
                unit_number: *unit_number,
                name: name.clone(),
            },
        }
    }

    pub fn id(&self) -> String {
        match self {
            Self::Primary => "primary".to_owned(),
            Self::LiveDisplayId { display_id } => display_id.to_string(),
            Self::Identity {
                uuid,
                vendor_id,
                model_id,
                serial_number,
                unit_number,
                name,
            } => {
                // Borrow the core identity record's wire fields without cloning its strings.
                #[derive(Serialize)]
                struct IdentityRecord<'a> {
                    uuid: &'a Option<String>,
                    vendor_id: &'a Option<u32>,
                    model_id: &'a Option<u32>,
                    serial_number: &'a Option<u32>,
                    unit_number: &'a Option<u32>,
                    name: &'a Option<String>,
                }
                let mut bytes = b"identity:".to_vec();
                serde_json::to_writer(
                    &mut bytes,
                    &IdentityRecord {
                        uuid,
                        vendor_id,
                        model_id,
                        serial_number,
                        unit_number,
                        name,
                    },
                )
                .expect("identity fields are JSON-serializable");
                String::from_utf8(bytes).expect("JSON serialization produces UTF-8")
            }
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct MonitorCfg {
    #[serde(flatten)]
    pub selector: SerializedSelector,
    #[serde(default = "enabled_default")]
    pub enabled: bool,
    #[serde(default = "assignment_mode_default")]
    pub mode: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub wallpaper: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mirror_target: Option<SerializedSelector>,
}

fn enabled_default() -> bool {
    true
}
fn assignment_mode_default() -> String {
    "independent".to_owned()
}
fn scaling_mode_default() -> String {
    "fill".to_owned()
}
fn scaling_factor_default() -> f64 {
    1.0
}
fn volume_default() -> f32 {
    1.0
}

impl Default for MonitorCfg {
    fn default() -> Self {
        Self {
            selector: SerializedSelector::default(),
            enabled: true,
            mode: assignment_mode_default(),
            wallpaper: None,
            mirror_target: None,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct MonitorSettingsCfg {
    #[serde(flatten)]
    pub selector: SerializedSelector,
    pub scaling_mode: String,
    pub scaling_factor: f64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub frame_rate: Option<u32>,
    pub volume: f32,
    pub muted: bool,
}

impl Default for MonitorSettingsCfg {
    fn default() -> Self {
        Self {
            selector: SerializedSelector::default(),
            scaling_mode: scaling_mode_default(),
            scaling_factor: 1.0,
            frame_rate: None,
            volume: 1.0,
            muted: false,
        }
    }
}

impl<'de> Deserialize<'de> for MonitorSettingsCfg {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        #[derive(Deserialize)]
        struct Fields {
            #[serde(flatten)]
            selector: SerializedSelector,
            #[serde(default = "scaling_mode_default")]
            scaling_mode: String,
            #[serde(default = "scaling_factor_default")]
            scaling_factor: f64,
            #[serde(default)]
            frame_rate: Presence<Option<u32>>,
            #[serde(default)]
            target_fps: Option<u32>,
            #[serde(default = "volume_default")]
            volume: f32,
            #[serde(default)]
            muted: bool,
        }
        let fields = Fields::deserialize(deserializer)?;
        Ok(Self {
            selector: fields.selector,
            scaling_mode: fields.scaling_mode,
            scaling_factor: fields.scaling_factor,
            frame_rate: read_frame_rate(fields.frame_rate, fields.target_fps),
            volume: fields.volume,
            muted: fields.muted,
        })
    }
}

impl MonitorSettingsCfg {
    pub fn parse_scaling_mode(&self) -> ScalingMode {
        super::scaling_mode(&self.scaling_mode)
    }

    pub fn fps_on(&self, refresh_hz: u32) -> u32 {
        resolve_frame_rate(self.frame_rate, refresh_hz)
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct QualityInForce {
    pub battery_profile: bool,
    pub throttled: bool,
}

pub fn clamp_render_scale(scale: f32) -> f32 {
    if scale.is_finite() {
        scale.clamp(MIN_RENDER_SCALE, MAX_RENDER_SCALE)
    } else {
        MAX_RENDER_SCALE
    }
}

impl AppConfig {
    pub fn migrate_legacy_keys(&mut self) {
        let pause = self.power.legacy_pause_on_battery_power.take();
        let profile = self.quality.legacy_battery_profile_enabled.take();
        if !self.power.on_battery_explicit {
            if pause == Some(true) {
                self.power.on_battery = BatteryModeCfg::Pause;
            } else if profile == Some(true) {
                self.power.on_battery = BatteryModeCfg::ReducedQuality;
            }
        }
    }

    pub fn effective_render_scale(&self, in_force: QualityInForce) -> f32 {
        let preferred = clamp_render_scale(self.quality.render_scale);
        let profile = clamp_render_scale(self.quality.battery.render_scale);
        if in_force.throttled {
            preferred.min(profile)
        } else if in_force.battery_profile {
            profile
        } else {
            preferred
        }
    }
}
