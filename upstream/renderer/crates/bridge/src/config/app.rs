use serde::{Deserialize, Serialize};
use wallpaper_core::{DisplayIdentity, DisplaySelector, project::ScalingMode};

pub const SCHEMA_VERSION: u32 = 1;
const DEFAULT_MONITOR_VOLUME: f32 = 1.0;
/// Lowest internal rasterization scale the renderer will honour. Below this a
/// wallpaper stops being a quality tier and becomes a visibly broken image.
pub const MIN_RENDER_SCALE: f32 = 0.25;
pub const MAX_RENDER_SCALE: f32 = 1.0;
const DEFAULT_BATTERY_RENDER_SCALE: f32 = 0.75;
const DEFAULT_BATTERY_TARGET_FPS: u32 = 30;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct AppConfig {
    #[serde(default = "default_schema_version")]
    pub schema_version: u32,
    #[serde(default)]
    pub general: GeneralCfg,
    #[serde(default)]
    pub power: PowerCfg,
    #[serde(default)]
    pub ui: UiCfg,
    #[serde(default)]
    pub experimental: ExperimentalCfg,
    /// Which renderer plays a plain local video. Replaces the former
    /// `experimental.native_video_backend` flag; see
    /// [`AppConfig::migrate_legacy_keys`].
    #[serde(default)]
    pub video_backend: VideoBackendModeCfg,
    /// Which renderer draws a scene wallpaper. Independent of
    /// [`AppConfig::video_backend`]: a scene is not a plain video, and the two
    /// choices route different wallpapers. New in this schema, so unlike
    /// `video_backend` it has no predecessor key to migrate from.
    #[serde(default)]
    pub scene_renderer: SceneRendererModeCfg,
    /// Whether this config has been through the one-time move to Native Metal
    /// preferred as the default scene renderer. Absent (false) in a config
    /// written before that change, where `scene_renderer` holds the old default
    /// more often than a choice; see [`AppConfig::migrate_legacy_keys`]. Older
    /// builds ignore the key.
    #[serde(default)]
    pub native_metal_default_applied: bool,
    #[serde(default)]
    pub quality: QualityCfg,
    #[serde(default)]
    pub monitors: Vec<MonitorCfg>,
    #[serde(default)]
    pub monitor_settings: Vec<MonitorSettingsCfg>,
    /// The display the `primary` block of `monitors` last described, by its
    /// stable identity. The block follows the role (whichever display macOS
    /// makes the main one), so when another display takes that role display
    /// sync hands the block over instead of moving its wallpaper along; see
    /// [`AppConfig::sync_known_monitors`]. Absent in a config written before
    /// this key and while the main display has no stable identity.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub primary_display: Option<SerializedSelector>,
    #[serde(default)]
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
            video_backend: VideoBackendModeCfg::default(),
            scene_renderer: SceneRendererModeCfg::default(),
            native_metal_default_applied: true,
            quality: QualityCfg::default(),
            monitors: Vec::new(),
            monitor_settings: Vec::new(),
            primary_display: None,
            diagnostics: DiagnosticsCfg::default(),
        }
    }
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct GeneralCfg {
    pub last_selected_wallpaper: Option<String>,
}

/// Which renderer plays a plain local video wallpaper.
///
/// `Compatibility` is the scene engine, which supports every wallpaper.
/// `NativePreferred` asks for the platform player where the wallpaper falls
/// inside its declared subset and falls back to the scene engine otherwise, so
/// the choice is a preference rather than a guarantee.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum VideoBackendModeCfg {
    #[default]
    Compatibility,
    NativePreferred,
}

/// Which renderer draws a scene wallpaper.
///
/// `NativeMetalPreferred`, the default, asks for the native Metal backend where
/// the whole scene falls inside the subset it can draw, and falls back to
/// Compatibility as a whole scene otherwise, so the choice is a preference
/// rather than a guarantee. `Compatibility` is the Vulkan/MoltenVK path, which
/// supports every scene, for every scene.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SceneRendererModeCfg {
    Compatibility,
    #[default]
    NativeMetalPreferred,
}

/// How many pixels a 2D scene is rasterized with, before the internal render
/// scale divides them.
///
/// `Display`, the default, rasterizes the canvas at the size it is presented at
/// on the display, which is what Wallpaper Engine does and what keeps a
/// high-resolution display sharp. `Canvas` rasterizes at the size the author
/// made it and stretches the result, which costs the least. A perspective
/// scene and a plain video are unaffected by either.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SceneResolutionCfg {
    Canvas,
    #[default]
    Display,
}

/// Internal rasterization size and frame rate the renderer targets.
///
/// This is the reduced-quality profile. The battery mode applies it while the
/// Mac is on battery, and a quality throttle the host asks for applies it too;
/// both lower what runs without touching what the user saved.
///
/// `render_scale` is the fraction of the display's native pixel grid the scene
/// is actually rasterized at. It is not window scaling and not wallpaper
/// scaling: at 0.5 the renderer does a quarter of the pixel work.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct QualityProfileCfg {
    #[serde(default = "default_battery_render_scale")]
    pub render_scale: f32,
    #[serde(default = "default_battery_target_fps")]
    pub target_fps: u32,
}

impl Default for QualityProfileCfg {
    fn default() -> Self {
        Self {
            render_scale: DEFAULT_BATTERY_RENDER_SCALE,
            target_fps: DEFAULT_BATTERY_TARGET_FPS,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct QualityCfg {
    /// The scale the user chose. Always the preference, never the value in
    /// force: a power profile can lower what the renderer runs at without
    /// overwriting what the user asked for.
    #[serde(default = "default_render_scale")]
    pub render_scale: f32,
    /// Global frame-rate ceiling. Absent means no limit. Never written when
    /// absent, so a saved file round-trips `None` rather than a null.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub frame_rate_cap: Option<u32>,
    /// Where the battery quality-profile switch used to live. Read so an
    /// existing opt-in survives the move to [`PowerCfg::on_battery`], and
    /// never written again.
    #[serde(default, rename = "battery_profile_enabled", skip_serializing)]
    pub legacy_battery_profile_enabled: Option<bool>,
    #[serde(default)]
    pub battery: QualityProfileCfg,
    /// Scene-renderer static-subgraph caching and redundant copy-pass
    /// elimination. On by default: it is a rendering optimization with no
    /// intended visual difference, so the switch exists to take it away when
    /// a wallpaper disagrees, not to opt in.
    #[serde(default = "default_true")]
    pub scene_optimization_enabled: bool,
    /// Stop the scene's periodic tick when the scene has no continuing reason
    /// to redraw, waking it on events instead. Off by default: unlike
    /// `scene_optimization_enabled` this changes when a scene runs at all, so
    /// it is opted into rather than taken away.
    #[serde(default)]
    pub scene_on_demand_enabled: bool,
    /// How many pixels a 2D scene is rasterized with before `render_scale`
    /// divides them. A preference over every scene, applied live.
    #[serde(default)]
    pub scene_resolution: SceneResolutionCfg,
}

impl Default for QualityCfg {
    fn default() -> Self {
        Self {
            render_scale: MAX_RENDER_SCALE,
            frame_rate_cap: None,
            legacy_battery_profile_enabled: None,
            battery: QualityProfileCfg::default(),
            scene_optimization_enabled: default_true(),
            scene_on_demand_enabled: false,
            scene_resolution: SceneResolutionCfg::default(),
        }
    }
}

/// Opt-in behaviour that is not ready to be a default.
///
/// Anything here is off unless the user turns it on, survives a restart, and is
/// expected to be reported as experimental wherever it is surfaced.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExperimentalCfg {
    /// Where the video backend choice used to live. Read so an existing opt-in
    /// survives the move to [`AppConfig::video_backend`], and never written
    /// again: once a config has been saved by this build the key is gone, so
    /// the migration cannot fire against a choice the user has since changed.
    #[serde(default, rename = "native_video_backend", skip_serializing)]
    pub legacy_native_video_backend: Option<bool>,
    /// Pace scene content production to the target rate instead of producing a
    /// frame per display refresh.
    #[serde(default)]
    pub content_pacing: bool,
    /// Let displays showing the same video share one decode session instead of
    /// decoding the file once per surface.
    #[serde(default)]
    pub shared_video_decode: bool,
    /// Let a native Metal scene's materials sample a video's NV12 planes
    /// directly instead of one pre-converted colour image. Off by default: the
    /// pre-converted path is what every Metal scene has been drawing, and the
    /// two are not unconditionally identical once clamping and the chroma
    /// resolution are involved.
    #[serde(default)]
    pub scene_video_plane_sampling: bool,
}

/// What the machine does with wallpapers while it is on battery.
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
    #[serde(default)]
    pub on_battery: BatteryModeCfg,
    /// Where pause-on-battery used to live. Read so an existing opt-in
    /// survives the move to [`PowerCfg::on_battery`], and never written again.
    #[serde(default, rename = "pause_on_battery_power", skip_serializing)]
    pub legacy_pause_on_battery_power: Option<bool>,
    /// Set when the file named `on_battery`. Not a setting: migration must
    /// not overwrite an explicit choice, including the default value.
    #[serde(skip)]
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
        struct Raw {
            #[serde(default)]
            on_battery: Option<BatteryModeCfg>,
            #[serde(default, rename = "pause_on_battery_power")]
            legacy_pause_on_battery_power: Option<bool>,
        }

        let raw = Raw::deserialize(deserializer)?;
        Ok(Self {
            on_battery: raw.on_battery.unwrap_or_default(),
            legacy_pause_on_battery_power: raw.legacy_pause_on_battery_power,
            on_battery_explicit: raw.on_battery.is_some(),
        })
    }
}

/// How much the application log records.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct DiagnosticsCfg {
    /// Debug-level lines on top of the default informational ones. Persisted,
    /// so a problem that shows up at launch is captured on the next launch.
    #[serde(default)]
    pub verbose_logging: bool,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct UiCfg {
    #[serde(default = "default_selector_window")]
    pub selector_window: WindowGeom,
    #[serde(default = "default_settings_window")]
    pub settings_window: WindowGeom,
    #[serde(default)]
    pub filter: FilterCfg,
}

impl Default for UiCfg {
    fn default() -> Self {
        Self {
            selector_window: default_selector_window(),
            settings_window: default_settings_window(),
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

#[allow(clippy::struct_excessive_bools)]
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
#[serde(tag = "kind", rename_all = "lowercase")]
pub enum SerializedSelector {
    #[default]
    Primary,
    Identity {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        uuid: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        vendor_id: Option<u32>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        model_id: Option<u32>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        serial_number: Option<u32>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        unit_number: Option<u32>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        name: Option<String>,
    },
    #[serde(rename = "live_display_id")]
    LiveDisplayId { display_id: u32 },
}

impl SerializedSelector {
    #[must_use]
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

    #[must_use]
    pub fn from_selector(sel: &DisplaySelector) -> Self {
        match sel {
            DisplaySelector::Primary => Self::Primary,
            DisplaySelector::Identity(identity) => Self::Identity {
                uuid: identity.uuid.clone(),
                vendor_id: identity.vendor_id,
                model_id: identity.model_id,
                serial_number: identity.serial_number,
                unit_number: identity.unit_number,
                name: identity.name.clone(),
            },
            DisplaySelector::LiveDisplayId(display_id) => Self::LiveDisplayId {
                display_id: *display_id,
            },
        }
    }

    #[must_use]
    /// # Panics
    ///
    /// Panics if a display identity selector cannot be serialized to JSON.
    pub fn id(&self) -> String {
        const PRIMARY_DISPLAY_ID: &str = "primary";
        const IDENTITY_DISPLAY_ID_PREFIX: &str = "identity:";

        match self {
            SerializedSelector::Primary => PRIMARY_DISPLAY_ID.to_string(),
            SerializedSelector::LiveDisplayId { display_id } => display_id.to_string(),
            SerializedSelector::Identity { .. } => {
                let DisplaySelector::Identity(identity) = self.to_selector() else {
                    unreachable!("identity selector must convert to identity")
                };
                format!(
                    "{IDENTITY_DISPLAY_ID_PREFIX}{}",
                    serde_json::to_string(&identity)
                        .expect("display identity selector should serialize")
                )
            }
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct MonitorCfg {
    #[serde(flatten, default)]
    pub selector: SerializedSelector,
    #[serde(default = "default_true")]
    pub enabled: bool,
    #[serde(default = "default_monitor_mode")]
    pub mode: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub wallpaper: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mirror_target: Option<SerializedSelector>,
}

impl Default for MonitorCfg {
    fn default() -> Self {
        Self {
            selector: SerializedSelector::default(),
            enabled: true,
            mode: default_monitor_mode(),
            wallpaper: None,
            mirror_target: None,
        }
    }
}

/// Presentation settings stored on the app config, used by mirror displays.
///
/// `frame_rate` absent means follow that display's native refresh. Older
/// files stored `target_fps = 60` as the untouched default; that value loads
/// as absent and is never written again.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(from = "MonitorSettingsCfgRaw")]
pub struct MonitorSettingsCfg {
    #[serde(flatten, default)]
    pub selector: SerializedSelector,
    #[serde(default = "default_scaling_mode")]
    pub scaling_mode: String,
    #[serde(default = "default_scaling_factor")]
    pub scaling_factor: f64,
    /// `None` follows the display's native refresh. A number is an explicit
    /// cap below that refresh and is omitted when absent.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub frame_rate: Option<u32>,
    #[serde(default = "default_monitor_volume")]
    pub volume: f32,
    #[serde(default)]
    pub muted: bool,
}

#[derive(Deserialize)]
struct MonitorSettingsCfgRaw {
    #[serde(flatten, default)]
    selector: SerializedSelector,
    #[serde(default = "default_scaling_mode")]
    scaling_mode: String,
    #[serde(default = "default_scaling_factor")]
    scaling_factor: f64,
    /// Outer `Some` means the key was present, so it wins over legacy
    /// `target_fps` even when the value is null.
    #[serde(default, deserialize_with = "super::deserialize_present")]
    frame_rate: Option<Option<u32>>,
    #[serde(default)]
    target_fps: Option<u32>,
    #[serde(default = "default_monitor_volume")]
    volume: f32,
    #[serde(default)]
    muted: bool,
}

impl From<MonitorSettingsCfgRaw> for MonitorSettingsCfg {
    fn from(raw: MonitorSettingsCfgRaw) -> Self {
        Self {
            selector: raw.selector,
            scaling_mode: raw.scaling_mode,
            scaling_factor: raw.scaling_factor,
            frame_rate: super::frame_rate_from_legacy(raw.frame_rate, raw.target_fps),
            volume: raw.volume,
            muted: raw.muted,
        }
    }
}

impl Default for MonitorSettingsCfg {
    fn default() -> Self {
        Self {
            selector: SerializedSelector::default(),
            scaling_mode: default_scaling_mode(),
            scaling_factor: default_scaling_factor(),
            frame_rate: None,
            volume: default_monitor_volume(),
            muted: false,
        }
    }
}

impl MonitorSettingsCfg {
    #[must_use]
    pub fn parse_scaling_mode(&self) -> ScalingMode {
        match self.scaling_mode.to_ascii_lowercase().as_str() {
            "none" => ScalingMode::None,
            "stretch" => ScalingMode::Stretch,
            "fill" => ScalingMode::Fill,
            "fit" => ScalingMode::Fit,
            _ => ScalingMode::default(),
        }
    }

    /// The rate this display should run at: the saved cap, or the display's
    /// own refresh when the user has not chosen one.
    #[must_use]
    pub fn fps_on(&self, refresh_hz: u32) -> u32 {
        super::resolve_frame_rate(self.frame_rate, refresh_hz)
    }
}

impl AppConfig {
    /// Folds keys this build no longer writes into their replacements.
    ///
    /// Called once on load. The video backend choice moved out of
    /// `experimental`; an existing opt-in has to keep its behaviour, so the
    /// legacy flag is honoured exactly while the new key is still absent. A
    /// config this build has saved never carries the legacy key again, so a
    /// later change of mind cannot be overwritten by it.
    ///
    /// Pause-on-battery and the battery quality-profile switch folded into
    /// [`PowerCfg::on_battery`]. Pause wins when both legacy flags are set.
    /// An explicit `on_battery`, including `keep_running`, wins over either.
    ///
    /// Native Metal preferred became the default scene renderer once it drew
    /// every scene the compatibility renderer did. A config written before then
    /// stores `compatibility` whether or not anyone chose it, so it moves to the
    /// new default once; the marker it gains keeps any later choice, including
    /// a return to Compatibility, from being moved again.
    pub fn migrate_legacy_keys(&mut self) {
        if !self.native_metal_default_applied {
            self.scene_renderer = SceneRendererModeCfg::NativeMetalPreferred;
            self.native_metal_default_applied = true;
        }

        let legacy_native = self.experimental.legacy_native_video_backend.take();
        if legacy_native == Some(true) && self.video_backend == VideoBackendModeCfg::Compatibility {
            self.video_backend = VideoBackendModeCfg::NativePreferred;
        }

        let legacy_pause = self.power.legacy_pause_on_battery_power.take();
        let legacy_profile = self.quality.legacy_battery_profile_enabled.take();
        if !self.power.on_battery_explicit {
            if legacy_pause == Some(true) {
                self.power.on_battery = BatteryModeCfg::Pause;
            } else if legacy_profile == Some(true) {
                self.power.on_battery = BatteryModeCfg::ReducedQuality;
            }
        }
    }

    /// The render scale in force right now.
    ///
    /// A throttle takes the lower of the user's scale and the profile's, so
    /// asking for less work can never raise quality above what the user
    /// chose, and adding a throttle to the battery profile never raises it
    /// either. The battery profile alone keeps the profile's scale as is, even
    /// when that is higher than a lower saved scale; with neither held the
    /// user's scale runs.
    #[must_use]
    pub fn effective_render_scale(&self, in_force: QualityInForce) -> f32 {
        let preferred = clamp_render_scale(self.quality.render_scale);
        let profile = clamp_render_scale(self.quality.battery.render_scale);
        let scale = if in_force.throttled {
            preferred.min(profile)
        } else if in_force.battery_profile {
            profile
        } else {
            preferred
        };
        clamp_render_scale(scale)
    }
}

/// Which reasons for the reduced-quality profile hold right now.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct QualityInForce {
    /// Reduced quality is the saved battery mode and the Mac is on battery.
    pub battery_profile: bool,
    /// The host asked for less work, whatever the power source.
    pub throttled: bool,
}

/// Confines a render scale to the range the renderer honours.
///
/// A non-finite value is not a scale at all and falls back to native rather
/// than to the low end, because the failure mode of guessing wrong here is a
/// permanently blurry desktop.
#[must_use]
pub fn clamp_render_scale(scale: f32) -> f32 {
    if !scale.is_finite() {
        return MAX_RENDER_SCALE;
    }
    scale.clamp(MIN_RENDER_SCALE, MAX_RENDER_SCALE)
}

#[allow(clippy::single_call_fn)]
fn default_schema_version() -> u32 {
    SCHEMA_VERSION
}

fn default_true() -> bool {
    true
}

#[allow(clippy::single_call_fn)]
fn default_render_scale() -> f32 {
    MAX_RENDER_SCALE
}

#[allow(clippy::single_call_fn)]
fn default_battery_render_scale() -> f32 {
    DEFAULT_BATTERY_RENDER_SCALE
}

#[allow(clippy::single_call_fn)]
fn default_battery_target_fps() -> u32 {
    DEFAULT_BATTERY_TARGET_FPS
}

fn default_monitor_mode() -> String {
    "independent".to_string()
}

fn default_scaling_mode() -> String {
    ScalingMode::default().to_string()
}

fn default_scaling_factor() -> f64 {
    1.0
}

fn default_monitor_volume() -> f32 {
    DEFAULT_MONITOR_VOLUME
}

fn default_selector_window() -> WindowGeom {
    WindowGeom {
        x: 200,
        y: 200,
        width: 1100,
        height: 720,
    }
}

fn default_settings_window() -> WindowGeom {
    WindowGeom {
        x: 520,
        y: 260,
        width: 520,
        height: 440,
    }
}
