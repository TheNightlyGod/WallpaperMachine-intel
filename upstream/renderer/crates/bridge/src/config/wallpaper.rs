use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use serde_json::Value;
use wallpaper_core::project::{ScalingMode, SceneFraming};

use super::app::SerializedSelector;
use crate::project::PropertyValue;

pub const SCHEMA_VERSION: u32 = 1;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct WallpaperConfig {
    #[serde(default = "default_schema_version")]
    pub schema_version: u32,
    #[serde(default)]
    pub workshop_id: String,
    #[serde(default, rename = "type")]
    pub r#type: String,
    #[serde(default)]
    pub audio: AudioCfg,
    /// Whether this wallpaper may read system media state.
    ///
    /// Enabled unless a saved choice says otherwise, including for older
    /// configurations without this field.
    #[serde(default = "default_media_integration_enabled")]
    pub media_integration_enabled: bool,
    #[serde(default)]
    pub monitors: Vec<MonitorRender>,
    #[serde(default)]
    pub property_overrides: BTreeMap<String, Value>,
}

impl Default for WallpaperConfig {
    fn default() -> Self {
        Self {
            schema_version: SCHEMA_VERSION,
            workshop_id: String::new(),
            r#type: String::new(),
            audio: AudioCfg::default(),
            media_integration_enabled: default_media_integration_enabled(),
            monitors: Vec::new(),
            property_overrides: BTreeMap::new(),
        }
    }
}

impl WallpaperConfig {
    #[must_use]
    pub fn new_for(workshop_id: impl Into<String>, type_str: impl Into<String>) -> Self {
        Self {
            workshop_id: workshop_id.into(),
            r#type: type_str.into(),
            ..Self::default()
        }
    }

    #[must_use]
    pub fn override_json(&self, id: &str) -> Option<&Value> {
        self.property_overrides.get(id)
    }

    pub fn override_value(&self, id: &str) -> Option<PropertyValue> {
        self.override_json(id).map(PropertyValue::from_json)
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct AudioCfg {
    #[serde(default = "default_audio_volume")]
    pub volume: f32,
    #[serde(default = "default_audio_response_enabled")]
    pub response_enabled: bool,
    #[serde(default)]
    pub muted: bool,
}

impl Default for AudioCfg {
    fn default() -> Self {
        Self {
            volume: default_audio_volume(),
            response_enabled: default_audio_response_enabled(),
            muted: false,
        }
    }
}

/// Per-display render overrides for one wallpaper.
///
/// `frame_rate` absent means follow that display's native refresh. Older
/// files stored a hard-coded `fps` of 60 even when nobody had chosen a rate;
/// that value is not a choice and loads as absent. A file this build writes
/// never carries `fps`.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(from = "MonitorRenderRaw")]
pub struct MonitorRender {
    #[serde(default)]
    pub selector: SerializedSelector,
    #[serde(default = "default_scaling_mode")]
    pub scaling_mode: String,
    #[serde(default = "default_scaling_factor")]
    pub scaling_factor: f64,
    /// `None` follows the display's native refresh. A number is an explicit
    /// cap below that refresh and is omitted when absent.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub frame_rate: Option<u32>,
    /// Where the wallpaper sits inside the room this display leaves around it.
    /// Absent when centred, so a file nobody positioned never carries the key.
    #[serde(default, skip_serializing_if = "FramingCfg::is_default")]
    pub framing: FramingCfg,
}

#[derive(Deserialize)]
struct MonitorRenderRaw {
    #[serde(default)]
    selector: SerializedSelector,
    #[serde(default = "default_scaling_mode")]
    scaling_mode: String,
    #[serde(default = "default_scaling_factor")]
    scaling_factor: f64,
    /// Outer `Some` means the key was present, so it wins over legacy `fps`
    /// even when the value is null.
    #[serde(default, deserialize_with = "super::deserialize_present")]
    frame_rate: Option<Option<u32>>,
    #[serde(default)]
    fps: Option<u32>,
    #[serde(default)]
    framing: FramingCfg,
}

impl From<MonitorRenderRaw> for MonitorRender {
    fn from(raw: MonitorRenderRaw) -> Self {
        Self {
            selector: raw.selector,
            scaling_mode: raw.scaling_mode,
            scaling_factor: raw.scaling_factor,
            frame_rate: super::frame_rate_from_legacy(raw.frame_rate, raw.fps),
            framing: raw.framing,
        }
    }
}

impl Default for MonitorRender {
    fn default() -> Self {
        Self {
            selector: SerializedSelector::default(),
            scaling_mode: default_scaling_mode(),
            scaling_factor: default_scaling_factor(),
            frame_rate: None,
            framing: FramingCfg::default(),
        }
    }
}

impl MonitorRender {
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

/// Where a wallpaper sits on one display when that display leaves room around
/// it: a Fit or Original size wallpaper smaller than the display, or a Fill or
/// zoomed one larger than it.
///
/// Each axis is a fraction, `0.0` (left, top) to `1.0` (right, bottom), of the
/// room the wallpaper could move through, so a position means the same on
/// every resolution and survives a display being swapped for another size.
/// `0.5` on both axes is the centred layout every wallpaper had before this
/// existed.
///
/// A hand-edited file may hold anything, and a wallpaper file that fails to
/// parse is set aside as corrupted with every other setting in it. So an axis
/// out of range is clamped, and one that is not a number, or a `framing` that
/// is not an object, is read as centred; none of them is an error.
#[derive(Clone, Copy, Debug, PartialEq, Serialize)]
pub struct FramingCfg {
    pub pan_x: f64,
    pub pan_y: f64,
}

impl FramingCfg {
    const CENTERED: Self = Self {
        pan_x: CENTERED_AXIS,
        pan_y: CENTERED_AXIS,
    };

    /// Whether this is the centred layout, which is stored as no key at all.
    #[must_use]
    pub fn is_default(&self) -> bool {
        *self == Self::CENTERED
    }

    /// The same position with each axis a finite fraction between 0 and 1: an
    /// out-of-range axis is pulled to the nearest edge and a non-finite one
    /// falls back to the middle.
    #[must_use]
    pub fn normalized(self) -> Self {
        Self {
            pan_x: normalize_axis(self.pan_x),
            pan_y: normalize_axis(self.pan_y),
        }
    }

    /// The position the engine is handed, always a valid framing.
    #[must_use]
    pub fn to_scene(self) -> SceneFraming {
        let Self { pan_x, pan_y } = self.normalized();
        SceneFraming { pan_x, pan_y }
    }
}

impl Default for FramingCfg {
    fn default() -> Self {
        Self::CENTERED
    }
}

impl<'de> Deserialize<'de> for FramingCfg {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        let value = Value::deserialize(deserializer)?;
        let axis = |key: &str| {
            value
                .get(key)
                .and_then(Value::as_f64)
                .map_or(CENTERED_AXIS, normalize_axis)
        };
        Ok(Self {
            pan_x: axis("pan_x"),
            pan_y: axis("pan_y"),
        })
    }
}

/// The middle of the room on one axis.
const CENTERED_AXIS: f64 = 0.5;

fn normalize_axis(pan: f64) -> f64 {
    if pan.is_finite() {
        pan.clamp(0.0, 1.0)
    } else {
        CENTERED_AXIS
    }
}

fn default_schema_version() -> u32 {
    SCHEMA_VERSION
}

fn default_audio_volume() -> f32 {
    1.0
}

fn default_audio_response_enabled() -> bool {
    true
}

fn default_media_integration_enabled() -> bool {
    true
}

fn default_scaling_mode() -> String {
    ScalingMode::default().to_string()
}

fn default_scaling_factor() -> f64 {
    1.0
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::app::MonitorSettingsCfg;

    #[test]
    fn scaling_defaults_to_fill_and_preserves_saved_choices() {
        assert_eq!(
            MonitorRender::default().parse_scaling_mode(),
            ScalingMode::Fill
        );
        assert_eq!(
            MonitorSettingsCfg::default().parse_scaling_mode(),
            ScalingMode::Fill
        );

        for (json, expected) in [
            (r#"{}"#, ScalingMode::Fill),
            (r#"{"scaling_mode":"fit"}"#, ScalingMode::Fit),
            (r#"{"scaling_mode":"fill"}"#, ScalingMode::Fill),
            (r#"{"scaling_mode":"stretch"}"#, ScalingMode::Stretch),
            (r#"{"scaling_mode":"none"}"#, ScalingMode::None),
            (r#"{"scaling_mode":"unknown"}"#, ScalingMode::Fill),
        ] {
            let wallpaper: MonitorRender = serde_json::from_str(json).unwrap();
            // Display settings flatten their selector, so include its required tag.
            let mut display_json = serde_json::to_value(SerializedSelector::default()).unwrap();
            let fields: serde_json::Map<String, Value> = serde_json::from_str(json).unwrap();
            display_json.as_object_mut().unwrap().extend(fields);
            let display: MonitorSettingsCfg = serde_json::from_value(display_json).unwrap();
            assert_eq!(wallpaper.parse_scaling_mode(), expected);
            assert_eq!(display.parse_scaling_mode(), expected);
        }
    }

    #[test]
    fn a_display_nobody_positioned_is_centred_and_writes_no_framing_key() {
        let missing: MonitorRender = serde_json::from_str("{}").unwrap();
        assert_eq!(missing.framing, FramingCfg::default());
        assert!(missing.framing.is_default());
        assert_eq!(missing.framing.to_scene(), SceneFraming::default());

        let saved = serde_json::to_value(MonitorRender::default()).unwrap();
        assert!(saved.get("framing").is_none(), "{saved}");

        // Positioning back to the middle is the same as never positioning: the
        // file goes back to what an older build would write and read.
        let recentred: MonitorRender =
            serde_json::from_str(r#"{"framing":{"pan_x":0.5,"pan_y":0.5}}"#).unwrap();
        let saved = serde_json::to_value(recentred).unwrap();
        assert!(saved.get("framing").is_none(), "{saved}");
    }

    #[test]
    fn a_saved_position_round_trips_and_reaches_the_engine() {
        let positioned = MonitorRender {
            framing: FramingCfg {
                pan_x: 0.2,
                pan_y: 0.8,
            },
            ..MonitorRender::default()
        };
        let json = serde_json::to_string(&positioned).unwrap();
        let loaded: MonitorRender = serde_json::from_str(&json).unwrap();
        assert_eq!(loaded, positioned);
        assert!(!loaded.framing.is_default());
        assert_eq!(
            loaded.framing.to_scene(),
            SceneFraming {
                pan_x: 0.2,
                pan_y: 0.8
            }
        );

        // One axis moved: the other stays in the middle rather than defaulting
        // to an edge.
        let horizontal: MonitorRender =
            serde_json::from_str(r#"{"framing":{"pan_x":0.25}}"#).unwrap();
        assert_eq!(
            horizontal.framing,
            FramingCfg {
                pan_x: 0.25,
                pan_y: 0.5
            }
        );
    }

    /// A wallpaper file that fails to parse is set aside as corrupted with all
    /// its other settings, so a bad position must degrade to a usable one
    /// instead of being an error.
    #[test]
    fn a_hand_edited_position_degrades_instead_of_discarding_the_wallpaper() {
        let centred = FramingCfg::default();
        for (json, expected) in [
            // Out of range is pulled to the nearest edge.
            (
                r#"{"pan_x":7.0,"pan_y":-3}"#,
                FramingCfg {
                    pan_x: 1.0,
                    pan_y: 0.0,
                },
            ),
            // Whole numbers are numbers.
            (
                r#"{"pan_x":1,"pan_y":0}"#,
                FramingCfg {
                    pan_x: 1.0,
                    pan_y: 0.0,
                },
            ),
            // Not a number is not a position: that axis is centred, the other
            // axis keeps what it says.
            (
                r#"{"pan_x":"left","pan_y":0.25}"#,
                FramingCfg {
                    pan_x: 0.5,
                    pan_y: 0.25,
                },
            ),
            (r#"{"pan_x":null,"pan_y":true}"#, centred),
            (r#"{"pan_x":[0.1],"pan_y":{"a":1}}"#, centred),
            // A framing that is not an object at all.
            ("5", centred),
            ("null", centred),
            (r#""left""#, centred),
            ("[0.1,0.2]", centred),
        ] {
            let render: MonitorRender =
                serde_json::from_str(&format!(r#"{{"scaling_mode":"fit","framing":{json}}}"#))
                    .unwrap_or_else(|error| panic!("framing {json} must load: {error}"));
            assert_eq!(render.framing, expected, "framing {json}");
            assert_eq!(render.parse_scaling_mode(), ScalingMode::Fit, "{json}");
            assert!(render.framing.to_scene().is_valid(), "{json}");
        }

        let wallpaper: WallpaperConfig = serde_json::from_str(
            r#"{"workshop_id":"1","type":"scene","audio":{"volume":0.3},
                "monitors":[{"scaling_mode":"fit","framing":{"pan_x":"left","pan_y":9}}]}"#,
        )
        .unwrap();
        assert!((wallpaper.audio.volume - 0.3).abs() <= f32::EPSILON);
        assert_eq!(wallpaper.monitors[0].parse_scaling_mode(), ScalingMode::Fit);
        assert_eq!(
            wallpaper.monitors[0].framing,
            FramingCfg {
                pan_x: 0.5,
                pan_y: 1.0
            }
        );
    }

    #[test]
    fn the_engine_is_never_handed_a_position_it_would_refuse() {
        for (pan_x, pan_y) in [
            (f64::NAN, 0.5),
            (0.5, f64::INFINITY),
            (f64::NEG_INFINITY, 2.0),
            (-0.01, 1.01),
        ] {
            let scene = FramingCfg { pan_x, pan_y }.to_scene();
            scene
                .validate()
                .unwrap_or_else(|error| panic!("{pan_x},{pan_y} reached the engine: {error}"));
        }
        assert_eq!(
            FramingCfg {
                pan_x: f64::NAN,
                pan_y: 2.0
            }
            .to_scene(),
            SceneFraming {
                pan_x: 0.5,
                pan_y: 1.0
            }
        );
        assert_eq!(FramingCfg::default().to_scene(), SceneFraming::default());
    }

    #[test]
    fn legacy_fps_follows_the_display_unless_it_was_an_explicit_cap() {
        let untouched: MonitorRender = serde_json::from_str(r#"{"fps":60}"#).unwrap();
        assert_eq!(untouched.frame_rate, None);
        let missing: MonitorRender = serde_json::from_str("{}").unwrap();
        assert_eq!(missing.frame_rate, None);

        let capped: MonitorRender = serde_json::from_str(r#"{"fps":30}"#).unwrap();
        assert_eq!(capped.frame_rate, Some(30));
        let zero: MonitorRender = serde_json::from_str(r#"{"fps":0}"#).unwrap();
        assert_eq!(zero.frame_rate, Some(1));

        let newer_wins: MonitorRender =
            serde_json::from_str(r#"{"frame_rate":24,"fps":30}"#).unwrap();
        assert_eq!(newer_wins.frame_rate, Some(24));
        let explicit_native_wins: MonitorRender =
            serde_json::from_str(r#"{"frame_rate":null,"fps":30}"#).unwrap();
        assert_eq!(explicit_native_wins.frame_rate, None);

        let saved = serde_json::to_value(MonitorRender::default()).unwrap();
        assert!(saved.get("fps").is_none(), "{saved}");
        assert!(saved.get("frame_rate").is_none(), "{saved}");
        let written = serde_json::to_value(MonitorRender {
            frame_rate: Some(30),
            ..MonitorRender::default()
        })
        .unwrap();
        assert!(written.get("fps").is_none(), "{written}");
        assert_eq!(written["frame_rate"], 30);

        assert_eq!(MonitorRender::default().fps_on(120), 60, "the default stops at 60");
        assert_eq!(MonitorRender::default().fps_on(60), 60);
        assert_eq!(MonitorRender::default().fps_on(48), 48, "below 60 the default follows the display");
        assert_eq!(MonitorRender::default().fps_on(0), 1);
        assert_eq!(capped.fps_on(120), 30);
        assert_eq!(capped.fps_on(24), 24);
    }
}
