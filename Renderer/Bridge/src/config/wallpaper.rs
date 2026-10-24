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
