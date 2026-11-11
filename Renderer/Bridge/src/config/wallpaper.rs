use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use serde_json::Value;
use wallpaper_core::project::{ScalingMode, SceneFraming};

use super::{Presence, SerializedSelector, read_frame_rate, resolve_frame_rate};
use crate::project::PropertyValue;

pub const SCHEMA_VERSION: u32 = 1;

/// Whether a wallpaper shares the system's now-playing information when its
/// configuration has no saved choice: a new configuration and an older file
/// without the field alike. A saved choice always wins.
pub const MEDIA_INTEGRATION_DEFAULT: bool = true;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct WallpaperConfig {
    pub schema_version: u32,
    pub workshop_id: String,
    pub r#type: String,
    pub audio: AudioCfg,
    pub media_integration_enabled: bool,
    pub monitors: Vec<MonitorRender>,
    pub property_overrides: BTreeMap<String, Value>,
    /// Wallpaper Engine's per-wallpaper options (its injected `wec_*`, `wcc_*`,
    /// `alignmentfliph`, `cameraparallax` and `rate` properties). Not written
    /// while every option is at its default.
    #[serde(skip_serializing_if = "EngineOptionsCfg::is_default")]
    pub engine_options: EngineOptionsCfg,
}

impl Default for WallpaperConfig {
    fn default() -> Self {
        Self {
            schema_version: SCHEMA_VERSION,
            workshop_id: String::new(),
            r#type: String::new(),
            audio: AudioCfg::default(),
            media_integration_enabled: MEDIA_INTEGRATION_DEFAULT,
            monitors: Vec::new(),
            property_overrides: BTreeMap::new(),
            engine_options: EngineOptionsCfg::default(),
        }
    }
}

impl WallpaperConfig {
    pub fn new_for(workshop_id: impl Into<String>, type_str: impl Into<String>) -> Self {
        Self {
            workshop_id: workshop_id.into(),
            r#type: type_str.into(),
            ..Self::default()
        }
    }

    pub fn override_json(&self, id: &str) -> Option<&Value> {
        self.property_overrides.get(id)
    }

    pub fn override_value(&self, id: &str) -> Option<PropertyValue> {
        self.override_json(id).map(PropertyValue::from_json)
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct AudioCfg {
    pub volume: f32,
    pub response_enabled: bool,
    pub muted: bool,
}

impl Default for AudioCfg {
    fn default() -> Self {
        Self {
            volume: 1.0,
            response_enabled: true,
            muted: false,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct MonitorRender {
    pub selector: SerializedSelector,
    pub scaling_mode: String,
    pub scaling_factor: f64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub frame_rate: Option<u32>,
    #[serde(skip_serializing_if = "FramingCfg::is_default")]
    pub framing: FramingCfg,
}

impl Default for MonitorRender {
    fn default() -> Self {
        Self {
            selector: SerializedSelector::default(),
            scaling_mode: "fill".to_owned(),
            scaling_factor: 1.0,
            frame_rate: None,
            framing: FramingCfg::default(),
        }
    }
}

impl<'de> Deserialize<'de> for MonitorRender {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        #[derive(Deserialize)]
        struct Fields {
            #[serde(default)]
            selector: SerializedSelector,
            #[serde(default = "scaling_mode_default")]
            scaling_mode: String,
            #[serde(default = "scaling_factor_default")]
            scaling_factor: f64,
            #[serde(default)]
            frame_rate: Presence<Option<u32>>,
            #[serde(default)]
            fps: Option<u32>,
            #[serde(default)]
            framing: FramingCfg,
        }
        fn scaling_mode_default() -> String {
            "fill".to_owned()
        }
        fn scaling_factor_default() -> f64 {
            1.0
        }
        let fields = Fields::deserialize(deserializer)?;
        Ok(Self {
            selector: fields.selector,
            scaling_mode: fields.scaling_mode,
            scaling_factor: fields.scaling_factor,
            frame_rate: read_frame_rate(fields.frame_rate, fields.fps),
            framing: fields.framing,
        })
    }
}

impl MonitorRender {
    pub fn parse_scaling_mode(&self) -> ScalingMode {
        super::scaling_mode(&self.scaling_mode)
    }

    pub fn fps_on(&self, refresh_hz: u32) -> u32 {
        resolve_frame_rate(self.frame_rate, refresh_hz)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Serialize)]
pub struct FramingCfg {
    pub pan_x: f64,
    pub pan_y: f64,
}

impl Default for FramingCfg {
    fn default() -> Self {
        Self {
            pan_x: 0.5,
            pan_y: 0.5,
        }
    }
}

fn normalized_axis(value: f64) -> f64 {
    if value.is_finite() {
        value.clamp(0.0, 1.0)
    } else {
        0.5
    }
}

impl<'de> Deserialize<'de> for FramingCfg {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        use serde::de::{IgnoredAny, MapAccess, SeqAccess, Visitor};

        #[derive(Deserialize)]
        #[serde(field_identifier)]
        enum AxisKey {
            #[serde(rename = "pan_x")]
            X,
            #[serde(rename = "pan_y")]
            Y,
            #[serde(other)]
            Other,
        }

        struct Axis(f64);
        struct AxisVisitor;
        impl<'de> Visitor<'de> for AxisVisitor {
            type Value = Axis;

            fn expecting(&self, formatter: &mut std::fmt::Formatter) -> std::fmt::Result {
                formatter.write_str("a framing axis or a value interpreted as centered")
            }

            fn visit_f64<E: serde::de::Error>(self, value: f64) -> Result<Axis, E> {
                Ok(Axis(normalized_axis(value)))
            }
            fn visit_i64<E: serde::de::Error>(self, value: i64) -> Result<Axis, E> {
                self.visit_f64(value as f64)
            }
            fn visit_u64<E: serde::de::Error>(self, value: u64) -> Result<Axis, E> {
                self.visit_f64(value as f64)
            }
            fn visit_bool<E: serde::de::Error>(self, _: bool) -> Result<Axis, E> {
                Ok(Axis(0.5))
            }
            fn visit_str<E: serde::de::Error>(self, _: &str) -> Result<Axis, E> {
                Ok(Axis(0.5))
            }
            fn visit_unit<E: serde::de::Error>(self) -> Result<Axis, E> {
                Ok(Axis(0.5))
            }
            fn visit_seq<A: SeqAccess<'de>>(self, mut sequence: A) -> Result<Axis, A::Error> {
                while sequence.next_element::<IgnoredAny>()?.is_some() {}
                Ok(Axis(0.5))
            }
            fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<Axis, A::Error> {
                while map.next_entry::<IgnoredAny, IgnoredAny>()?.is_some() {}
                Ok(Axis(0.5))
            }
        }

        impl<'de> Deserialize<'de> for Axis {
            fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
                deserializer.deserialize_any(AxisVisitor)
            }
        }

        struct FramingVisitor;
        impl<'de> Visitor<'de> for FramingVisitor {
            type Value = FramingCfg;

            fn expecting(&self, formatter: &mut std::fmt::Formatter) -> std::fmt::Result {
                formatter.write_str("framing or a value interpreted as centered")
            }

            fn visit_bool<E: serde::de::Error>(self, _: bool) -> Result<FramingCfg, E> {
                Ok(FramingCfg::default())
            }
            fn visit_str<E: serde::de::Error>(self, _: &str) -> Result<FramingCfg, E> {
                Ok(FramingCfg::default())
            }
            fn visit_unit<E: serde::de::Error>(self) -> Result<FramingCfg, E> {
                Ok(FramingCfg::default())
            }
            fn visit_i64<E: serde::de::Error>(self, _: i64) -> Result<FramingCfg, E> {
                Ok(FramingCfg::default())
            }
            fn visit_u64<E: serde::de::Error>(self, _: u64) -> Result<FramingCfg, E> {
                Ok(FramingCfg::default())
            }
            fn visit_f64<E: serde::de::Error>(self, _: f64) -> Result<FramingCfg, E> {
                Ok(FramingCfg::default())
            }
            fn visit_seq<A: SeqAccess<'de>>(self, mut sequence: A) -> Result<FramingCfg, A::Error> {
                while sequence.next_element::<IgnoredAny>()?.is_some() {}
                Ok(FramingCfg::default())
            }
            fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<FramingCfg, A::Error> {
                let mut framing = FramingCfg::default();
                while let Some(key) = map.next_key::<AxisKey>()? {
                    match key {
                        AxisKey::X => framing.pan_x = map.next_value::<Axis>()?.0,
                        AxisKey::Y => framing.pan_y = map.next_value::<Axis>()?.0,
                        AxisKey::Other => {
                            map.next_value::<IgnoredAny>()?;
                        }
                    }
                }
                Ok(framing)
            }
        }

        deserializer.deserialize_any(FramingVisitor)
    }
}

impl FramingCfg {
    pub fn is_default(&self) -> bool {
        self.pan_x == 0.5 && self.pan_y == 0.5
    }

    pub fn normalized(self) -> Self {
        Self {
            pan_x: normalized_axis(self.pan_x),
            pan_y: normalized_axis(self.pan_y),
        }
    }

    pub fn to_scene(self) -> SceneFraming {
        let framing = self.normalized();
        SceneFraming {
            pan_x: framing.pan_x,
            pan_y: framing.pan_y,
        }
    }
}

/// Wallpaper Engine's per-wallpaper options as saved under `"engine_options"`.
///
/// The ranges and defaults are the ones `wallpaper64.exe` `sub_140104B60` gives
/// the properties it injects (`artifacts/we-parity/decompiles/H-P0-2.md`): the
/// four colour sliders 0 to 100 around 50, the image filter's strength 0 to 100
/// (100 by default), and the playback rate 10 to 200 percent, which Wallpaper
/// Engine offers for scenes as well as videos.
///
/// Reading is tolerant per field, like [`FramingCfg`]: a value of the wrong
/// type or a number that is not finite reads as that field's default, a number
/// outside its range is held to it, an image filter that is not a plain file
/// name reads as none, and keys this build does not know are ignored.
#[allow(clippy::struct_excessive_bools)]
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct EngineOptionsCfg {
    pub color_enabled: bool,
    pub brightness: f64,
    pub contrast: f64,
    pub saturation: f64,
    pub hue_shift: f64,
    /// A file stem under the shared assets' `materials/lut`; empty for none.
    pub image_filter: String,
    pub filter_strength: f64,
    pub flip_horizontal: bool,
    pub mouse_parallax: bool,
    pub playback_rate: f64,
}

impl Default for EngineOptionsCfg {
    fn default() -> Self {
        Self {
            color_enabled: false,
            brightness: 50.0,
            contrast: 50.0,
            saturation: 50.0,
            hue_shift: 50.0,
            image_filter: String::new(),
            filter_strength: 100.0,
            flip_horizontal: false,
            mouse_parallax: true,
            playback_rate: 100.0,
        }
    }
}

/// One of Wallpaper Engine's per-wallpaper options.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum EngineOptionId {
    ColorEnabled,
    Brightness,
    Contrast,
    Saturation,
    HueShift,
    ImageFilter,
    FilterStrength,
    FlipHorizontal,
    MouseParallax,
    PlaybackRate,
}

impl EngineOptionId {
    /// Every option, in the order an editor lists them.
    pub const ALL: [Self; 10] = [
        Self::ColorEnabled,
        Self::Brightness,
        Self::Contrast,
        Self::Saturation,
        Self::HueShift,
        Self::ImageFilter,
        Self::FilterStrength,
        Self::FlipHorizontal,
        Self::MouseParallax,
        Self::PlaybackRate,
    ];

    /// The inclusive range of a slider option; `None` for a switch or the
    /// image filter.
    #[must_use]
    pub fn range(self) -> Option<(f64, f64)> {
        match self {
            Self::Brightness | Self::Contrast | Self::Saturation | Self::HueShift | Self::FilterStrength => {
                Some((0.0, 100.0))
            }
            Self::PlaybackRate => Some((10.0, 200.0)),
            Self::ColorEnabled | Self::ImageFilter | Self::FlipHorizontal | Self::MouseParallax => None,
        }
    }

    /// Whether the option is a switch.
    #[must_use]
    pub fn is_switch(self) -> bool {
        matches!(self, Self::ColorEnabled | Self::FlipHorizontal | Self::MouseParallax)
    }
}

/// Whether `name` can be an image filter: a plain file stem of 1 to 64 of
/// `[A-Za-z0-9._-]`, never `.` or `..`, so it can only name a file directly in
/// `materials/lut`.
#[must_use]
pub fn is_image_filter_name(name: &str) -> bool {
    (1..=64).contains(&name.len())
        && name != "."
        && name != ".."
        && name
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
}

impl EngineOptionsCfg {
    #[must_use]
    pub fn is_default(&self) -> bool {
        *self == Self::default()
    }

    /// The value of one option.
    #[must_use]
    pub fn get(&self, option: EngineOptionId) -> PropertyValue {
        match option {
            EngineOptionId::ColorEnabled => PropertyValue::Bool(self.color_enabled),
            EngineOptionId::Brightness => PropertyValue::Number(self.brightness),
            EngineOptionId::Contrast => PropertyValue::Number(self.contrast),
            EngineOptionId::Saturation => PropertyValue::Number(self.saturation),
            EngineOptionId::HueShift => PropertyValue::Number(self.hue_shift),
            EngineOptionId::ImageFilter => PropertyValue::String(self.image_filter.clone()),
            EngineOptionId::FilterStrength => PropertyValue::Number(self.filter_strength),
            EngineOptionId::FlipHorizontal => PropertyValue::Bool(self.flip_horizontal),
            EngineOptionId::MouseParallax => PropertyValue::Bool(self.mouse_parallax),
            EngineOptionId::PlaybackRate => PropertyValue::Number(self.playback_rate),
        }
    }

    /// Sets one option. A value of the wrong kind for the option is ignored and
    /// a number is held to the option's range; callers check edits first, so
    /// this only keeps the saved file inside what the reader accepts.
    pub fn set(&mut self, option: EngineOptionId, value: &PropertyValue) {
        match (option, value) {
            (EngineOptionId::ColorEnabled, PropertyValue::Bool(on)) => self.color_enabled = *on,
            (EngineOptionId::FlipHorizontal, PropertyValue::Bool(on)) => self.flip_horizontal = *on,
            (EngineOptionId::MouseParallax, PropertyValue::Bool(on)) => self.mouse_parallax = *on,
            (EngineOptionId::ImageFilter, PropertyValue::String(name)) => {
                self.image_filter = if is_image_filter_name(name) { name.clone() } else { String::new() };
            }
            (option, PropertyValue::Number(number)) => {
                let Some((min, max)) = option.range() else { return };
                if !number.is_finite() {
                    return;
                }
                let number = number.clamp(min, max);
                match option {
                    EngineOptionId::Brightness => self.brightness = number,
                    EngineOptionId::Contrast => self.contrast = number,
                    EngineOptionId::Saturation => self.saturation = number,
                    EngineOptionId::HueShift => self.hue_shift = number,
                    EngineOptionId::FilterStrength => self.filter_strength = number,
                    EngineOptionId::PlaybackRate => self.playback_rate = number,
                    _ => {}
                }
            }
            _ => {}
        }
    }

    /// Puts one option back at its default.
    pub fn restore(&mut self, option: EngineOptionId) {
        self.set(option, &Self::default().get(option));
    }

    /// The options as the scene renderer takes them.
    #[must_use]
    #[allow(clippy::cast_possible_truncation)]
    pub fn to_scene(&self) -> wallpaper_core::project::SceneUserOptions {
        wallpaper_core::project::SceneUserOptions {
            color_enabled: self.color_enabled,
            brightness: self.brightness as f32,
            contrast: self.contrast as f32,
            saturation: self.saturation as f32,
            hue: self.hue_shift as f32,
            lut: self.image_filter.clone(),
            lut_strength: self.filter_strength as f32,
            flip_horizontal: self.flip_horizontal,
            mouse_parallax: self.mouse_parallax,
            playback_rate: self.playback_rate as f32,
        }
    }

    fn from_json(value: &Value) -> Self {
        let mut options = Self::default();
        let Some(map) = value.as_object() else {
            return options;
        };
        let keys = [
            ("color_enabled", EngineOptionId::ColorEnabled),
            ("brightness", EngineOptionId::Brightness),
            ("contrast", EngineOptionId::Contrast),
            ("saturation", EngineOptionId::Saturation),
            ("hue_shift", EngineOptionId::HueShift),
            ("image_filter", EngineOptionId::ImageFilter),
            ("filter_strength", EngineOptionId::FilterStrength),
            ("flip_horizontal", EngineOptionId::FlipHorizontal),
            ("mouse_parallax", EngineOptionId::MouseParallax),
            ("playback_rate", EngineOptionId::PlaybackRate),
        ];
        for (key, option) in keys {
            let read = match map.get(key) {
                Some(Value::Bool(on)) if option.is_switch() => PropertyValue::Bool(*on),
                Some(Value::String(name)) if option == EngineOptionId::ImageFilter => {
                    PropertyValue::String(name.clone())
                }
                Some(Value::Number(number)) if option.range().is_some() => match number.as_f64() {
                    Some(number) => PropertyValue::Number(number),
                    None => continue,
                },
                _ => continue,
            };
            options.set(option, &read);
        }
        options
    }
}

impl<'de> Deserialize<'de> for EngineOptionsCfg {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        Ok(Self::from_json(&Value::deserialize(deserializer)?))
    }
}
