use serde_json::Value;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum FileMedia {
    #[default]
    Image,
    Video,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct FileFilter {
    pub media: FileMedia,
    pub raw: Option<String>,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum DirectoryMode {
    #[default]
    OnDemand,
    FetchAll,
}

#[derive(Clone, Debug, PartialEq)]
pub enum PropertyKind {
    Slider,
    Combo,
    Bool,
    Color,
    TextInput,
    Text,
    Group,
    File,
    Directory,
    Texture,
    Unknown(String),
}

#[derive(Clone, Debug, PartialEq)]
pub enum PropertyMetadata {
    Slider {
        min: f64,
        max: f64,
        step: f64,
        precision: u32,
        fraction: bool,
    },
    Combo {
        options: Vec<ComboOption>,
    },
    Bool,
    Color,
    TextInput,
    Text,
    Group,
    File {
        filter: FileFilter,
    },
    Directory {
        filter: FileFilter,
        mode: DirectoryMode,
    },
    Texture,
    Unknown,
}

#[derive(Clone, Debug, PartialEq)]
pub struct ComboOption {
    pub label: String,
    pub value: String,
    pub json_value: Value,
}

#[derive(Clone, Debug, PartialEq)]
pub enum PropertyValue {
    Bool(bool),
    Number(f64),
    String(String),
    ColorRgb(f32, f32, f32),
    Null,
}

impl PropertyValue {
    pub fn to_json(&self) -> Value {
        match self {
            Self::Bool(value) => Value::Bool(*value),
            Self::Number(value) => {
                serde_json::Number::from_f64(*value).map_or(Value::Null, Value::Number)
            }
            Self::String(value) => Value::String(value.clone()),
            Self::ColorRgb(..) => Value::String(self.to_property_string()),
            Self::Null => Value::Null,
        }
    }

    pub fn json_scalar_to_string(value: &Value) -> String {
        match value {
            Value::String(value) => value.clone(),
            Value::Null => String::new(),
            _ => value.to_string(),
        }
    }

    pub fn from_json(value: &Value) -> Self {
        match value {
            Value::Bool(value) => Self::Bool(*value),
            Value::Number(value) => Self::Number(
                value
                    .as_f64()
                    .expect("JSON number has an f64 representation"),
            ),
            Value::Null => Self::Null,
            Value::String(value) => {
                let mut parts = value.split_whitespace();
                let rgb = (|| {
                    let red = parts.next()?.parse::<f32>().ok()?;
                    let green = parts.next()?.parse::<f32>().ok()?;
                    let blue = parts.next()?.parse::<f32>().ok()?;
                    if parts.next().is_some()
                        || ![red, green, blue].iter().all(|v| (0.0..=1.0).contains(v))
                    {
                        return None;
                    }
                    Some(Self::ColorRgb(red, green, blue))
                })();
                rgb.unwrap_or_else(|| Self::String(value.clone()))
            }
            Value::Array(_) | Value::Object(_) => Self::String(value.to_string()),
        }
    }

    pub fn to_property_string(&self) -> String {
        match self {
            Self::Bool(value) => value.to_string(),
            Self::Number(value) => value.to_string(),
            Self::String(value) => value.clone(),
            Self::ColorRgb(red, green, blue) => format!("{red} {green} {blue}"),
            Self::Null => String::new(),
        }
    }

    pub fn matches_with_override_semantics(&self, other: &Self) -> bool {
        match (self, other) {
            (Self::Number(left), Self::Number(right)) => {
                left == right
                    || (left.is_finite()
                        && right.is_finite()
                        && (left - right).abs()
                            <= f64::EPSILON * left.abs().max(right.abs()).max(1.0))
            }
            (Self::ColorRgb(lr, lg, lb), Self::ColorRgb(rr, rg, rb)) => {
                fn matches(left: f32, right: f32) -> bool {
                    left == right
                        || (left.is_finite()
                            && right.is_finite()
                            && (left - right).abs()
                                <= f32::EPSILON * left.abs().max(right.abs()).max(1.0))
                }
                matches(*lr, *rr) && matches(*lg, *rg) && matches(*lb, *rb)
            }
            _ => self == other,
        }
    }

    pub fn as_color_rgb(&self) -> Option<(f32, f32, f32)> {
        if let Self::ColorRgb(red, green, blue) = self {
            Some((*red, *green, *blue))
        } else {
            None
        }
    }
}
