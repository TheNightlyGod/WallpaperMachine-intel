// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! The request model (spec 2.4) and its validation (R10 to R16).
//!
//! `ShaderRequest` is the unchecked shape, convenient to build in code or to
//! fill from JSON (see `request_json`). `ShaderRequest::validate` turns it into
//! a `ValidRequest`, which can only be obtained that way and is what the rest
//! of the layer works from. Validation happens before any include is read and
//! before any compile work, and every failure names the offending value.

use std::collections::HashMap;
use std::fmt;

use crate::json::JsonError;
use crate::names::{MAX_TEXTURE_SLOT, is_identifier};
use crate::text::{quote, sanitize};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum StageKind {
    Vertex,
    Fragment,
}

impl StageKind {
    /// Lower-case spelling used in requests and reflection.
    pub fn name(self) -> &'static str {
        match self {
            StageKind::Vertex => "vertex",
            StageKind::Fragment => "fragment",
        }
    }

    /// Capitalised spelling used in the diagnostics document.
    pub fn label(self) -> &'static str {
        match self {
            StageKind::Vertex => "Vertex",
            StageKind::Fragment => "Fragment",
        }
    }

    /// The integer the C ABI reports: 0 vertex, 1 fragment.
    pub fn abi_value(self) -> i32 {
        match self {
            StageKind::Vertex => 0,
            StageKind::Fragment => 1,
        }
    }

    pub fn parse(s: &str) -> Option<StageKind> {
        match s {
            "vertex" => Some(StageKind::Vertex),
            "fragment" => Some(StageKind::Fragment),
            _ => None,
        }
    }
}

/// What the response is for. Only Metal is accepted (2.4); the type is an
/// enum so a later target is an addition, never a silent fallback.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub enum Target {
    #[default]
    MetalMsl,
}

impl Target {
    pub fn name(self) -> &'static str {
        match self {
            Target::MetalMsl => "metal_msl",
        }
    }

    pub fn parse(s: &str) -> Option<Target> {
        match s {
            "metal_msl" => Some(Target::MetalMsl),
            _ => None,
        }
    }

    /// The integer the C ABI reports for a stage of this target.
    pub fn abi_value(self) -> i32 {
        match self {
            Target::MetalMsl => 1,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Stage {
    pub kind: StageKind,
    pub source: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Combo {
    pub name: String,
    pub value: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub enum TextureFormat {
    #[default]
    Unknown,
    R8,
    Rg8,
    Rgba8,
}

impl TextureFormat {
    pub fn name(self) -> &'static str {
        match self {
            TextureFormat::Unknown => "unknown",
            TextureFormat::R8 => "r8",
            TextureFormat::Rg8 => "rg8",
            TextureFormat::Rgba8 => "rgba8",
        }
    }

    pub fn parse(s: &str) -> Option<TextureFormat> {
        match s {
            "unknown" => Some(TextureFormat::Unknown),
            "r8" => Some(TextureFormat::R8),
            "rg8" => Some(TextureFormat::Rg8),
            "rgba8" => Some(TextureFormat::Rgba8),
            _ => None,
        }
    }
}

/// Which colour components of a texture are used (`compo4` includes emissive masks).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub struct TextureComponents {
    pub compo1: bool,
    pub compo2: bool,
    pub compo3: bool,
    pub compo4: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub enum VideoPlanes {
    #[default]
    None,
    Nv12Biplanar,
}

impl VideoPlanes {
    pub fn name(self) -> &'static str {
        match self {
            VideoPlanes::None => "none",
            VideoPlanes::Nv12Biplanar => "nv12_biplanar",
        }
    }

    pub fn parse(s: &str) -> Option<VideoPlanes> {
        match s {
            "none" => Some(VideoPlanes::None),
            "nv12_biplanar" => Some(VideoPlanes::Nv12Biplanar),
            _ => None,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TextureRecord {
    /// Material texture slot. Validation accepts 0 to 31.
    pub slot: u8,
    /// The material (not the shader's own default) supplied a texture here.
    pub present: bool,
    /// The texture supplies component-usage information.
    pub enabled: bool,
    pub format: TextureFormat,
    pub components: TextureComponents,
    pub video_planes: VideoPlanes,
}

impl TextureRecord {
    /// A record with the documented defaults: present, not enabled, unknown
    /// format, no components, no planes.
    pub fn new(slot: u8) -> TextureRecord {
        TextureRecord {
            slot,
            present: true,
            enabled: false,
            format: TextureFormat::Unknown,
            components: TextureComponents::default(),
            video_planes: VideoPlanes::None,
        }
    }
}

/// A typed project property value. Numbers are kept as `f64`: properties never
/// reach the compiled output, only the cache key, which uses the bit patterns.
#[derive(Clone, Debug, PartialEq)]
pub enum PropertyValue {
    String(String),
    Number(f64),
    Bool(bool),
    Vec2([f64; 2]),
    Vec3([f64; 3]),
    Vec4([f64; 4]),
    Matrix4([f64; 16]),
    /// Present in the schema, rejected by validation (R14).
    None,
}

impl PropertyValue {
    pub fn kind_name(&self) -> &'static str {
        match self {
            PropertyValue::String(_) => "string",
            PropertyValue::Number(_) => "number",
            PropertyValue::Bool(_) => "bool",
            PropertyValue::Vec2(_) => "vec2",
            PropertyValue::Vec3(_) => "vec3",
            PropertyValue::Vec4(_) => "vec4",
            PropertyValue::Matrix4(_) => "matrix4",
            PropertyValue::None => "none",
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Property {
    pub name: String,
    pub value: PropertyValue,
}

/// The program cache policy. It only feeds the cache key (R15); the layer never
/// reads or writes a cache.
#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub enum CachePolicy {
    #[default]
    Disabled,
    Enabled { scene_id: String },
}

/// An unchecked request. Build one in code or fill it from JSON, then call
/// [`ShaderRequest::validate`].
#[derive(Clone, Debug, Default, PartialEq)]
pub struct ShaderRequest {
    pub shader_name: String,
    pub target: Target,
    pub cache_policy: CachePolicy,
    pub stages: Vec<Stage>,
    pub combos: Vec<Combo>,
    pub textures: Vec<TextureRecord>,
    pub properties: Vec<Property>,
}

/// What is wrong with the `stages` array (R11).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum StageProblem {
    Duplicate(StageKind),
    Missing(StageKind),
}

impl fmt::Display for StageProblem {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            StageProblem::Duplicate(kind) => write!(f, "duplicate {} stage", kind.name()),
            StageProblem::Missing(kind) => write!(f, "missing {} stage", kind.name()),
        }
    }
}

/// A request that could not be read or did not validate. The text always
/// carries the offending value (R10 to R16).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum RequestError {
    // Reading the document.
    NotUtf8 { valid_up_to: usize },
    Json(JsonError),
    /// A key is missing, has the wrong type, or holds an unknown enum spelling.
    Schema(String),
    UnknownTarget(String),
    // Validation.
    EmptyShaderName,
    ShaderNameHasNul,
    Stages(Vec<StageProblem>),
    EmptyComboName,
    InvalidComboName(String),
    DuplicateCombo { folded: String, first: String, second: String },
    TextureSlotOutOfRange(u8),
    DuplicateTextureSlot(u8),
    EmptyPropertyName,
    PropertyHasNoValue(String),
    /// A shader annotation that cannot be used (R75): an unparsable default,
    /// an empty material alias.
    Metadata(String),
    /// The resources or interface of the program cannot be laid out: a conflicting uniform
    /// or binding, an unresolved array bound, a video slot that cannot be sampled as planes
    /// (spec C2, R16 to R30, R39, R49).
    Program(String),
}

impl fmt::Display for RequestError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let text = match self {
            RequestError::NotUtf8 { valid_up_to } => {
                format!("request is not valid UTF-8 (valid up to byte {valid_up_to})")
            }
            RequestError::Json(e) => format!("json request parse failed: {e}"),
            RequestError::Schema(message) => format!("json request parse failed: {message}"),
            RequestError::UnknownTarget(target) => format!(
                "json request parse failed: unknown target {} (the only accepted target is `metal_msl`)",
                quote(target)
            ),
            RequestError::EmptyShaderName => "invalid shader request: shader name is empty".to_string(),
            RequestError::ShaderNameHasNul => {
                "invalid shader request: shader name contains a NUL character".to_string()
            }
            RequestError::Stages(problems) => {
                let list: Vec<String> = problems.iter().map(ToString::to_string).collect();
                format!("invalid shader request: {}", list.join("; "))
            }
            RequestError::EmptyComboName => "invalid shader request: combo name is empty".to_string(),
            RequestError::InvalidComboName(name) => format!(
                "invalid shader request: combo name {} is not an ASCII identifier (a letter or underscore, then letters, digits or underscores)",
                quote(name)
            ),
            RequestError::DuplicateCombo { folded, first, second } => format!(
                "invalid shader request: duplicate combo name {} (given as {} and {})",
                quote(folded),
                quote(first),
                quote(second)
            ),
            RequestError::TextureSlotOutOfRange(slot) => format!(
                "invalid shader request: texture slot {slot} is out of range (0 to {MAX_TEXTURE_SLOT})"
            ),
            RequestError::DuplicateTextureSlot(slot) => {
                format!("invalid shader request: duplicate texture slot {slot}")
            }
            RequestError::EmptyPropertyName => "invalid shader request: property name is empty".to_string(),
            RequestError::PropertyHasNoValue(name) => {
                format!("invalid shader request: property {} has no value", quote(name))
            }
            RequestError::Metadata(message) => format!("invalid shader request: {message}"),
            RequestError::Program(message) => format!("invalid shader request: {message}"),
        };
        f.write_str(&sanitize(&text))
    }
}

impl std::error::Error for RequestError {}

impl ShaderRequest {
    /// Checks the request and normalises it (R10 to R15). The first problem is
    /// reported; checks run in the order name, stages, combos, textures,
    /// properties.
    pub fn validate(self) -> Result<ValidRequest, RequestError> {
        // R10: backslashes become forward slashes, then the name must be non-empty.
        if self.shader_name.contains('\0') {
            return Err(RequestError::ShaderNameHasNul);
        }
        let shader_name = self.shader_name.replace('\\', "/");
        if shader_name.is_empty() {
            return Err(RequestError::EmptyShaderName);
        }

        // R11: exactly one vertex and one fragment stage.
        let mut problems = Vec::new();
        for kind in [StageKind::Vertex, StageKind::Fragment] {
            match self.stages.iter().filter(|s| s.kind == kind).count() {
                0 => problems.push(StageProblem::Missing(kind)),
                1 => {}
                _ => problems.push(StageProblem::Duplicate(kind)),
            }
        }
        if !problems.is_empty() {
            return Err(RequestError::Stages(problems));
        }

        // R12: identifier names, unique under ASCII case folding. Values are free text.
        let mut seen: HashMap<String, &str> = HashMap::new();
        for combo in &self.combos {
            if combo.name.is_empty() {
                return Err(RequestError::EmptyComboName);
            }
            if !is_identifier(&combo.name) {
                return Err(RequestError::InvalidComboName(combo.name.clone()));
            }
            let folded = combo.name.to_ascii_lowercase();
            if let Some(first) = seen.insert(folded.clone(), &combo.name) {
                return Err(RequestError::DuplicateCombo {
                    folded,
                    first: first.to_string(),
                    second: combo.name.clone(),
                });
            }
        }

        // R13: slots 0 to 31, at most one record per slot.
        let mut slots = [false; MAX_TEXTURE_SLOT as usize + 1];
        for record in &self.textures {
            let Some(seen) = slots.get_mut(usize::from(record.slot)) else {
                return Err(RequestError::TextureSlotOutOfRange(record.slot));
            };
            if std::mem::replace(seen, true) {
                return Err(RequestError::DuplicateTextureSlot(record.slot));
            }
        }

        // R14: named, and carrying a value.
        for property in &self.properties {
            if property.name.is_empty() {
                return Err(RequestError::EmptyPropertyName);
            }
            if property.value == PropertyValue::None {
                return Err(RequestError::PropertyHasNoValue(property.name.clone()));
            }
        }

        Ok(ValidRequest {
            shader_name,
            target: self.target,
            cache_policy: self.cache_policy,
            stages: self.stages,
            combos: self.combos,
            textures: self.textures,
            properties: self.properties,
        })
    }
}

/// A checked, normalised request. The only way to get one is
/// [`ShaderRequest::validate`] (or the JSON entry points built on it), so the
/// rest of the layer can rely on: a non-empty name without backslashes or NUL,
/// exactly one vertex and one fragment stage, unique identifier combo names,
/// unique texture slots within 0 to 31 and properties that all carry a value.
///
/// Omitting an optional key and writing its default give equal values (R79).
#[derive(Clone, Debug, PartialEq)]
pub struct ValidRequest {
    shader_name: String,
    target: Target,
    cache_policy: CachePolicy,
    stages: Vec<Stage>,
    combos: Vec<Combo>,
    textures: Vec<TextureRecord>,
    properties: Vec<Property>,
}

impl ValidRequest {
    /// The normalised shader name (what diagnostics and the cache key use).
    pub fn shader_name(&self) -> &str {
        &self.shader_name
    }

    pub fn target(&self) -> Target {
        self.target
    }

    pub fn cache_policy(&self) -> &CachePolicy {
        &self.cache_policy
    }

    /// The two stages in request order; output stage `i` is stage `i` here (R9).
    pub fn stages(&self) -> &[Stage] {
        &self.stages
    }

    /// The stage of `kind`; validation guarantees there is exactly one.
    pub fn stage(&self, kind: StageKind) -> &Stage {
        self.stages
            .iter()
            .find(|s| s.kind == kind)
            .expect("a validated request has both stages")
    }

    /// Combos as given, in request order.
    pub fn combos(&self) -> &[Combo] {
        &self.combos
    }

    /// The combo called `name`, compared ignoring ASCII case.
    pub fn combo(&self, name: &str) -> Option<&Combo> {
        self.combos.iter().find(|c| c.name.eq_ignore_ascii_case(name))
    }

    /// Texture records in request order.
    pub fn textures(&self) -> &[TextureRecord] {
        &self.textures
    }

    pub fn texture(&self, slot: u8) -> Option<&TextureRecord> {
        self.textures.iter().find(|t| t.slot == slot)
    }

    /// Slots flagged for the NV12 plane variant, in record order (R102).
    pub fn planar_slots(&self) -> Vec<u8> {
        self.textures
            .iter()
            .filter(|t| t.video_planes == VideoPlanes::Nv12Biplanar)
            .map(|t| t.slot)
            .collect()
    }

    pub fn properties(&self) -> &[Property] {
        &self.properties
    }
}

#[cfg(test)]
pub(crate) mod test_support {
    use super::*;

    pub fn stage(kind: StageKind, source: &str) -> Stage {
        Stage { kind, source: source.to_string() }
    }

    /// A request that validates: a name and one source per stage.
    pub fn minimal() -> ShaderRequest {
        ShaderRequest {
            shader_name: "genericimage2".into(),
            stages: vec![
                stage(StageKind::Vertex, "void main() {}"),
                stage(StageKind::Fragment, "void main() {}"),
            ],
            ..ShaderRequest::default()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::test_support::*;
    use super::*;

    fn err(req: ShaderRequest) -> RequestError {
        req.validate().unwrap_err()
    }

    #[test]
    fn minimal_request_is_valid_with_documented_defaults() {
        let valid = minimal().validate().unwrap();
        assert_eq!(valid.shader_name(), "genericimage2");
        assert_eq!(valid.target(), Target::MetalMsl);
        assert_eq!(valid.cache_policy(), &CachePolicy::Disabled);
        assert!(valid.combos().is_empty() && valid.textures().is_empty() && valid.properties().is_empty());
    }

    #[test]
    fn shader_name_is_normalised_and_checked() {
        let mut req = minimal();
        req.shader_name = "effects\\foo\\bar".into();
        assert_eq!(req.validate().unwrap().shader_name(), "effects/foo/bar");

        let mut req = minimal();
        req.shader_name = String::new();
        let e = err(req);
        assert_eq!(e, RequestError::EmptyShaderName);
        assert!(e.to_string().contains("shader name is empty"));

        let mut req = minimal();
        req.shader_name = "a\0b".into();
        assert!(err(req).to_string().contains("NUL"));

        // A name made only of backslashes is not empty once normalised.
        let mut req = minimal();
        req.shader_name = "\\".into();
        assert_eq!(req.validate().unwrap().shader_name(), "/");
    }

    #[test]
    fn stages_must_be_exactly_one_vertex_and_one_fragment() {
        let mut req = minimal();
        req.stages.clear();
        let text = err(req).to_string();
        assert!(text.contains("missing vertex stage") && text.contains("missing fragment stage"), "{text}");

        let mut req = minimal();
        req.stages.remove(1);
        assert!(err(req).to_string().contains("missing fragment stage"));

        let mut req = minimal();
        req.stages[1].kind = StageKind::Vertex;
        let text = err(req).to_string();
        assert!(text.contains("duplicate vertex stage"), "{text}");
        assert!(text.contains("missing fragment stage"), "both facts are reported: {text}");

        let mut req = minimal();
        req.stages.push(stage(StageKind::Fragment, ""));
        assert!(err(req).to_string().contains("duplicate fragment stage"));
    }

    #[test]
    fn reversed_stage_order_is_accepted_and_kept() {
        let mut req = minimal();
        req.stages.reverse();
        let valid = req.validate().unwrap();
        assert_eq!(valid.stages()[0].kind, StageKind::Fragment);
        assert_eq!(valid.stage(StageKind::Vertex).kind, StageKind::Vertex);
    }

    #[test]
    fn combo_names_must_be_identifiers() {
        for bad in ["", "1A", "A-B", "A B", "é", "A.B"] {
            let mut req = minimal();
            req.combos.push(Combo { name: bad.into(), value: "1".into() });
            let e = err(req);
            if bad.is_empty() {
                assert_eq!(e, RequestError::EmptyComboName);
            } else {
                assert!(e.to_string().contains(&format!("`{bad}`")), "{e}");
            }
        }
        let mut req = minimal();
        req.combos.push(Combo { name: "_ok1".into(), value: String::new() });
        req.combos.push(Combo { name: "V".into(), value: "not a number {{".into() });
        assert_eq!(req.validate().unwrap().combos().len(), 2, "values are never validated");
    }

    #[test]
    fn combo_names_clash_under_ascii_case_folding() {
        let mut req = minimal();
        req.combos.push(Combo { name: "TransformUV".into(), value: "1".into() });
        req.combos.push(Combo { name: "TRANSFORMUV".into(), value: "0".into() });
        let text = err(req).to_string();
        assert!(text.contains("duplicate combo name `transformuv`"), "{text}");
        assert!(text.contains("TransformUV") && text.contains("TRANSFORMUV"));
    }

    #[test]
    fn combo_lookup_ignores_ascii_case() {
        let mut req = minimal();
        req.combos.push(Combo { name: "transformuv".into(), value: "1".into() });
        let valid = req.validate().unwrap();
        assert_eq!(valid.combo("TRANSFORMUV").unwrap().value, "1");
        assert!(valid.combo("OTHER").is_none());
    }

    #[test]
    fn texture_slots_are_limited_and_unique() {
        for slot in [32u8, 33, 255] {
            let mut req = minimal();
            req.textures.push(TextureRecord::new(slot));
            let text = err(req).to_string();
            assert!(text.contains(&format!("texture slot {slot} is out of range")), "{text}");
        }
        let mut req = minimal();
        req.textures.push(TextureRecord::new(0));
        req.textures.push(TextureRecord::new(31));
        assert!(req.validate().is_ok());

        let mut req = minimal();
        req.textures.push(TextureRecord::new(4));
        req.textures.push(TextureRecord::new(4));
        assert!(err(req).to_string().contains("duplicate texture slot 4"));
    }

    #[test]
    fn a_record_for_a_slot_the_shader_never_declares_is_accepted() {
        // The request layer cannot know what the shader declares; any slot in range passes.
        let mut req = minimal();
        req.textures.push(TextureRecord::new(17));
        assert_eq!(req.validate().unwrap().texture(17).unwrap().slot, 17);
    }

    #[test]
    fn properties_need_a_name_and_a_value() {
        let mut req = minimal();
        req.properties.push(Property { name: String::new(), value: PropertyValue::Bool(true) });
        assert_eq!(err(req), RequestError::EmptyPropertyName);

        let mut req = minimal();
        req.properties.push(Property { name: "speed".into(), value: PropertyValue::None });
        assert!(err(req).to_string().contains("property `speed` has no value"));

        let mut req = minimal();
        req.properties.push(Property { name: "speed".into(), value: PropertyValue::Vec2([1.0, 2.0]) });
        assert_eq!(req.validate().unwrap().properties().len(), 1);
    }

    #[test]
    fn planar_slots_follow_record_order() {
        let mut req = minimal();
        for (slot, planes) in [(3u8, VideoPlanes::Nv12Biplanar), (1, VideoPlanes::None), (2, VideoPlanes::Nv12Biplanar)] {
            let mut t = TextureRecord::new(slot);
            t.video_planes = planes;
            req.textures.push(t);
        }
        assert_eq!(req.validate().unwrap().planar_slots(), vec![3, 2]);
    }

    #[test]
    fn explicit_defaults_equal_omitted_ones() {
        let omitted = minimal().validate().unwrap();
        let mut explicit = minimal();
        explicit.target = Target::MetalMsl;
        explicit.cache_policy = CachePolicy::Disabled;
        assert_eq!(explicit.validate().unwrap(), omitted);
        assert_eq!(TextureRecord::new(2), TextureRecord {
            slot: 2,
            present: true,
            enabled: false,
            format: TextureFormat::Unknown,
            components: TextureComponents { compo1: false, compo2: false, compo3: false, compo4: false },
            video_planes: VideoPlanes::None,
        });
    }

    #[test]
    fn error_text_is_plain_and_bounded() {
        let mut req = minimal();
        req.combos.push(Combo { name: "bad\u{1b}[31m".into(), value: String::new() });
        let text = err(req).to_string();
        assert!(!text.contains('\u{1b}'), "no terminal escapes: {text:?}");

        let mut req = minimal();
        req.combos.push(Combo { name: "x-".repeat(5000), value: String::new() });
        assert!(err(req).to_string().len() < 600);
    }

    #[test]
    fn enum_spellings_round_trip() {
        for k in [StageKind::Vertex, StageKind::Fragment] {
            assert_eq!(StageKind::parse(k.name()), Some(k));
        }
        for f in [TextureFormat::Unknown, TextureFormat::R8, TextureFormat::Rg8, TextureFormat::Rgba8] {
            assert_eq!(TextureFormat::parse(f.name()), Some(f));
        }
        for p in [VideoPlanes::None, VideoPlanes::Nv12Biplanar] {
            assert_eq!(VideoPlanes::parse(p.name()), Some(p));
        }
        assert_eq!(Target::parse("metal_msl"), Some(Target::MetalMsl));
        assert_eq!(Target::parse("vulkan_spirv"), None);
        assert_eq!(StageKind::parse("Vertex"), None);
        assert_eq!((StageKind::Vertex.abi_value(), StageKind::Fragment.abi_value(), Target::MetalMsl.abi_value()), (0, 1, 1));
    }
}
