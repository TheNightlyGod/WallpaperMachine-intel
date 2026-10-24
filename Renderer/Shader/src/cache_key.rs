// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! The program cache key returned with a response (R80 to R84).
//!
//! The key is a 128-bit SHA-256 prefix, written as 32 lower-case hex digits
//! (non-empty, ASCII, filename-safe). It is computed over a framed byte
//! stream: every string is length-prefixed and every section is tagged, so
//! moving a boundary between two adjacent strings changes the key (R82).
//!
//! What it covers: the key-format version and the compiler identity (which
//! carries the pipeline revision, the compiler dependency version and the
//! compile options); the shader name; the target; the cache mode and scene id;
//! the effective combo set; every texture record; every property binding with
//! its kind and exact number bit patterns; and per stage the kind, the source
//! text as given, the preprocessed text and the translated GLSL.
//!
//! Choices recorded in `NOTES.md`: combos and texture records are hashed in a
//! canonical order (the key does not change when only their order in the
//! request changes); properties keep request order (their input is unused and
//! order could matter to a future reader); the raw source is hashed besides
//! the preprocessed text because annotations live in comments the
//! preprocessor drops but the metadata depends on.

use crate::identity::compiler_identity;
use crate::request::{CachePolicy, Combo, PropertyValue, StageKind, ValidRequest};
use crate::sha256::{Sha256, to_hex};

/// Bumped when the layout of the hashed stream changes.
pub const KEY_FORMAT_VERSION: u32 = 1;

/// The texts a stage contributes once the pipeline has produced them.
#[derive(Clone, Copy, Debug)]
pub struct StageKeyInput<'a> {
    pub kind: StageKind,
    /// The stage text with includes expanded and combos applied.
    pub preprocessed: &'a str,
    /// The GLSL handed to the downstream compiler.
    pub translated_glsl: &'a str,
}

#[derive(Clone, Copy, Debug)]
pub struct ProgramKeyInput<'a> {
    pub request: &'a ValidRequest,
    /// The request's combos plus the values the layer supplied for the ones it did not give (R60).
    pub effective_combos: &'a [Combo],
    /// In output order, which is request order (R9).
    pub stages: &'a [StageKeyInput<'a>],
}

/// The key of a program under this build's compiler identity.
pub fn program_key(input: &ProgramKeyInput<'_>) -> String {
    program_key_with_identity(compiler_identity(), input)
}

/// The key under an explicit identity; separate so tests can show that the identity matters.
pub fn program_key_with_identity(identity: &str, input: &ProgramKeyInput<'_>) -> String {
    let mut s = Stream::new();
    s.tag("wm-shader-program-key");
    s.u32(KEY_FORMAT_VERSION);
    s.str(identity);

    let request = input.request;
    s.tag("name");
    s.str(request.shader_name());
    s.tag("target");
    s.str(request.target().name());

    s.tag("cache");
    match request.cache_policy() {
        CachePolicy::Disabled => s.u8(0),
        CachePolicy::Enabled { scene_id } => {
            s.u8(1);
            s.str(scene_id);
        }
    }

    s.tag("combos");
    let mut combos: Vec<&Combo> = input.effective_combos.iter().collect();
    combos.sort_by(|a, b| (&a.name, &a.value).cmp(&(&b.name, &b.value)));
    s.len(combos.len());
    for combo in combos {
        s.str(&combo.name);
        s.str(&combo.value);
    }

    s.tag("textures");
    let mut textures: Vec<_> = request.textures().iter().collect();
    textures.sort_by_key(|t| t.slot);
    s.len(textures.len());
    for t in textures {
        s.u8(t.slot);
        s.bool(t.present);
        s.bool(t.enabled);
        s.str(t.format.name());
        s.bool(t.components.compo1);
        s.bool(t.components.compo2);
        s.bool(t.components.compo3);
        s.bool(t.components.compo4);
        s.str(t.video_planes.name());
    }

    s.tag("properties");
    s.len(request.properties().len());
    for property in request.properties() {
        s.str(&property.name);
        s.str(property.value.kind_name());
        match &property.value {
            PropertyValue::String(text) => s.str(text),
            PropertyValue::Number(n) => s.f64(*n),
            PropertyValue::Bool(b) => s.bool(*b),
            PropertyValue::Vec2(v) => s.f64s(v),
            PropertyValue::Vec3(v) => s.f64s(v),
            PropertyValue::Vec4(v) => s.f64s(v),
            PropertyValue::Matrix4(v) => s.f64s(v),
            PropertyValue::None => {}
        }
    }

    s.tag("stages");
    s.len(input.stages.len());
    for stage in input.stages {
        s.str(stage.kind.name());
        s.str(&request.stage(stage.kind).source);
        s.str(stage.preprocessed);
        s.str(stage.translated_glsl);
    }

    s.finish()
}

/// The framed byte stream being hashed.
struct Stream {
    hasher: Sha256,
}

impl Stream {
    fn new() -> Stream {
        Stream { hasher: Sha256::new() }
    }

    fn raw(&mut self, bytes: &[u8]) {
        self.hasher.update(bytes);
    }

    /// A section marker: framed like a string so it cannot be confused with data.
    fn tag(&mut self, name: &str) {
        self.str(name);
    }

    fn str(&mut self, text: &str) {
        self.u64(text.len() as u64);
        self.raw(text.as_bytes());
    }

    fn len(&mut self, n: usize) {
        self.u64(n as u64);
    }

    fn u8(&mut self, v: u8) {
        self.raw(&[v]);
    }

    fn bool(&mut self, v: bool) {
        self.u8(u8::from(v));
    }

    fn u32(&mut self, v: u32) {
        self.raw(&v.to_le_bytes());
    }

    fn u64(&mut self, v: u64) {
        self.raw(&v.to_le_bytes());
    }

    /// The exact bit pattern, so `0.0` and `-0.0` differ.
    fn f64(&mut self, v: f64) {
        self.u64(v.to_bits());
    }

    fn f64s(&mut self, values: &[f64]) {
        self.len(values.len());
        for v in values {
            self.f64(*v);
        }
    }

    fn finish(self) -> String {
        to_hex(&self.hasher.finalize()[..16])
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::request::{
        Property, ShaderRequest, TextureFormat, TextureRecord, VideoPlanes,
        test_support::{minimal, stage},
    };

    /// Everything a key depends on, as plain data so a test can change one thing at a time.
    #[derive(Clone)]
    struct Case {
        request: ShaderRequest,
        effective_combos: Vec<(String, String)>,
        preprocessed: [String; 2],
        glsl: [String; 2],
        identity: String,
    }

    fn base() -> Case {
        let mut request = minimal();
        request.shader_name = "genericimage2".into();
        request.stages[0] = stage(StageKind::Vertex, "// vertex source\nvoid main() {}");
        request.stages[1] = stage(StageKind::Fragment, "// fragment source\nvoid main() {}");
        request.textures.push(TextureRecord::new(0));
        request.properties.push(Property { name: "p".into(), value: PropertyValue::Number(1.0) });
        Case {
            request,
            effective_combos: vec![("TRANSFORMUV".into(), "1".into()), ("BLEND".into(), "0".into())],
            preprocessed: ["void main() {}".into(), "void main() {}".into()],
            glsl: ["#version 450\nvoid main() {}".into(), "#version 450\nvoid main() {}".into()],
            identity: compiler_identity().to_string(),
        }
    }

    fn key(case: &Case) -> String {
        let request = case.request.clone().validate().unwrap();
        let combos: Vec<Combo> =
            case.effective_combos.iter().map(|(n, v)| Combo { name: n.clone(), value: v.clone() }).collect();
        // Output stages follow the request's stage order.
        let stages: Vec<StageKeyInput> = request
            .stages()
            .iter()
            .map(|s| {
                let i = if s.kind == StageKind::Vertex { 0 } else { 1 };
                StageKeyInput { kind: s.kind, preprocessed: &case.preprocessed[i], translated_glsl: &case.glsl[i] }
            })
            .collect();
        program_key_with_identity(&case.identity, &ProgramKeyInput { request: &request, effective_combos: &combos, stages: &stages })
    }

    fn assert_changes(label: &str, change: impl FnOnce(&mut Case)) {
        let original = base();
        let mut changed = original.clone();
        change(&mut changed);
        assert_ne!(key(&original), key(&changed), "{label} must change the key");
    }

    #[test]
    fn a_key_is_non_empty_filename_safe_and_deterministic() {
        let k = key(&base());
        assert_eq!(k.len(), 32, "128 bits");
        assert!(k.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)), "{k}");
        assert_eq!(k, key(&base()));
        let request = base().request.validate().unwrap();
        let stages = [
            StageKeyInput { kind: StageKind::Vertex, preprocessed: "a", translated_glsl: "b" },
            StageKeyInput { kind: StageKind::Fragment, preprocessed: "c", translated_glsl: "d" },
        ];
        let input = ProgramKeyInput { request: &request, effective_combos: &[], stages: &stages };
        assert_eq!(program_key(&input), program_key_with_identity(compiler_identity(), &input));
    }

    #[test]
    fn every_item_of_the_request_changes_the_key() {
        assert_changes("shader name", |c| c.request.shader_name = "other".into());
        assert_changes("scene id", |c| c.request.cache_policy = CachePolicy::Enabled { scene_id: "a".into() });
        assert_changes("cache mode", |c| {
            // Disabled versus enabled with an empty scene id.
            c.request.cache_policy = CachePolicy::Enabled { scene_id: String::new() };
        });
        assert_changes("vertex source text", |c| c.request.stages[0].source.push(' '));
        assert_changes("fragment source text", |c| c.request.stages[1].source.push(' '));
        assert_changes("vertex preprocessed text", |c| c.preprocessed[0].push(' '));
        assert_changes("fragment preprocessed text", |c| c.preprocessed[1].push(' '));
        assert_changes("translated vertex GLSL", |c| c.glsl[0].push(' '));
        assert_changes("translated fragment GLSL", |c| c.glsl[1].push(' '));
        assert_changes("combo value", |c| c.effective_combos[0].1 = "2".into());
        assert_changes("combo name", |c| c.effective_combos[0].0 = "OTHER".into());
        assert_changes("an extra combo", |c| c.effective_combos.push(("X".into(), "1".into())));
        assert_changes("a combo removed", |c| {
            c.effective_combos.pop();
        });
        assert_changes("compiler identity (pipeline revision)", |c| c.identity.push('x'));
    }

    #[test]
    fn every_texture_field_changes_the_key() {
        assert_changes("a texture record added", |c| c.request.textures.push(TextureRecord::new(1)));
        assert_changes("the slot", |c| c.request.textures[0].slot = 1);
        assert_changes("presence", |c| c.request.textures[0].present = false);
        assert_changes("enabled state", |c| c.request.textures[0].enabled = true);
        assert_changes("format r8", |c| c.request.textures[0].format = TextureFormat::R8);
        assert_changes("format rg8", |c| c.request.textures[0].format = TextureFormat::Rg8);
        assert_changes("format rgba8", |c| c.request.textures[0].format = TextureFormat::Rgba8);
        assert_changes("compo1", |c| c.request.textures[0].components.compo1 = true);
        assert_changes("compo2", |c| c.request.textures[0].components.compo2 = true);
        assert_changes("compo3", |c| c.request.textures[0].components.compo3 = true);
        assert_changes("compo4", |c| c.request.textures[0].components.compo4 = true);
        assert_changes("the plane flag", |c| c.request.textures[0].video_planes = VideoPlanes::Nv12Biplanar);
        assert_changes("the plane flag on a slot the shader never declares", |c| {
            let mut t = TextureRecord::new(9);
            t.video_planes = VideoPlanes::Nv12Biplanar;
            c.request.textures.push(t);
        });
    }

    #[test]
    fn every_property_field_and_kind_changes_the_key() {
        assert_changes("property name", |c| c.request.properties[0].name = "q".into());
        assert_changes("number value", |c| c.request.properties[0].value = PropertyValue::Number(2.0));
        assert_changes("bool kind", |c| c.request.properties[0].value = PropertyValue::Bool(true));
        assert_changes("string kind", |c| c.request.properties[0].value = PropertyValue::String("1".into()));
        assert_changes("a property added", |c| {
            c.request.properties.push(Property { name: "r".into(), value: PropertyValue::Bool(false) });
        });
        assert_changes("no properties", |c| c.request.properties.clear());
        assert_changes("sign of zero is part of the bit pattern", |c| {
            c.request.properties[0].value = PropertyValue::Number(0.0);
        });
        let mut zero = base();
        zero.request.properties[0].value = PropertyValue::Number(0.0);
        let mut negative_zero = base();
        negative_zero.request.properties[0].value = PropertyValue::Number(-0.0);
        assert_ne!(key(&zero), key(&negative_zero));
    }

    #[test]
    fn property_value_kinds_with_equal_numbers_differ() {
        let with = |value| {
            let mut c = base();
            c.request.properties[0].value = value;
            key(&c)
        };
        let vec2 = with(PropertyValue::Vec2([1.0, 1.0]));
        let vec3 = with(PropertyValue::Vec3([1.0, 1.0, 1.0]));
        let vec4 = with(PropertyValue::Vec4([1.0; 4]));
        let matrix = with(PropertyValue::Matrix4([1.0; 16]));
        let all = [&vec2, &vec3, &vec4, &matrix];
        for (i, a) in all.iter().enumerate() {
            for b in &all[i + 1..] {
                assert_ne!(a, b);
            }
        }
        // A vec4 holding sixteen-ish numbers is still not a matrix of the same numbers.
        assert_ne!(with(PropertyValue::Number(1.0)), vec2);
    }

    #[test]
    fn moving_text_between_adjacent_strings_changes_the_key() {
        let pair = |a: &str, b: &str| {
            let mut c = base();
            c.effective_combos = vec![("X".into(), a.into()), ("Y".into(), b.into())];
            key(&c)
        };
        assert_ne!(pair("ab", "c"), pair("a", "bc"));
        let name_value = |n: &str, v: &str| {
            let mut c = base();
            c.effective_combos = vec![(n.into(), v.into())];
            key(&c)
        };
        assert_ne!(name_value("AB", "1"), name_value("A", "B1"));
        let texts = |pre: &str, glsl: &str| {
            let mut c = base();
            c.preprocessed[0] = pre.into();
            c.glsl[0] = glsl.into();
            key(&c)
        };
        assert_ne!(texts("ab", "c"), texts("a", "bc"));
        let sources = |v: &str, f: &str| {
            let mut c = base();
            c.request.stages[0].source = v.into();
            c.request.stages[1].source = f.into();
            key(&c)
        };
        assert_ne!(sources("ab", "c"), sources("a", "bc"));
        let name_and_scene = |name: &str, scene: &str| {
            let mut c = base();
            c.request.shader_name = name.into();
            c.request.cache_policy = CachePolicy::Enabled { scene_id: scene.into() };
            key(&c)
        };
        assert_ne!(name_and_scene("ab", "c"), name_and_scene("a", "bc"));
        let properties = |n1: &str, n2: &str| {
            let mut c = base();
            c.request.properties = vec![
                Property { name: n1.into(), value: PropertyValue::String(n2.into()) },
            ];
            key(&c)
        };
        assert_ne!(properties("ab", "c"), properties("a", "bc"));
    }

    #[test]
    fn combo_and_texture_order_do_not_change_the_key_but_property_order_does() {
        let mut a = base();
        a.request.textures.push(TextureRecord::new(3));
        let mut b = a.clone();
        b.request.textures.reverse();
        assert_eq!(key(&a), key(&b), "texture records are hashed by slot");
        let mut c = a.clone();
        c.effective_combos.reverse();
        assert_eq!(key(&a), key(&c), "combos are hashed in canonical order");

        let mut p = base();
        p.request.properties.push(Property { name: "q".into(), value: PropertyValue::Bool(true) });
        let mut q = p.clone();
        q.request.properties.reverse();
        assert_ne!(key(&p), key(&q), "property order is part of the key");
    }

    #[test]
    fn request_stage_order_matters_because_the_output_order_follows_it() {
        let a = base();
        let mut b = base();
        b.request.stages.reverse();
        assert_ne!(key(&a), key(&b));
    }

    #[test]
    fn an_equivalent_request_written_with_explicit_defaults_has_the_same_key() {
        let a = base();
        let mut b = base();
        b.request.target = crate::request::Target::MetalMsl;
        b.request.textures[0] = TextureRecord {
            slot: 0,
            present: true,
            enabled: false,
            format: TextureFormat::Unknown,
            components: Default::default(),
            video_planes: VideoPlanes::None,
        };
        assert_eq!(key(&a), key(&b));
    }

    /// R88. Each row is a program-key value that was shipped under a compiler
    /// identity. Rows are only ever appended. A change to the hashed layout, to
    /// the key format version or to anything the key covers makes the row for
    /// the current identity fail; the fix is a deliberate bump of
    /// `PIPELINE_REVISION` and a new row, never an edit of an old row.
    const GOLDEN_KEYS: &[(&str, &str)] = &[
        ("1:naga-29.0.3-msl2.0-untransformed", "6f7ebe5f0135bd78c06498f63bf6494c"),
        ("2:naga-29.0.3-msl2.0-untransformed", "9d581ff6d5542ca737858b5baab20ae1"),
    ];

    fn golden_case() -> Case {
        let mut request = minimal();
        request.shader_name = "golden/shader".into();
        request.stages[0] = stage(StageKind::Vertex, "v-source");
        request.stages[1] = stage(StageKind::Fragment, "f-source");
        let mut t = TextureRecord::new(2);
        t.enabled = true;
        t.format = TextureFormat::Rg8;
        t.components.compo4 = true;
        request.textures.push(t);
        request.cache_policy = CachePolicy::Enabled { scene_id: "scene-1".into() };
        request.properties.push(Property { name: "p".into(), value: PropertyValue::Vec2([0.5, -2.0]) });
        Case {
            request,
            effective_combos: vec![("A".into(), "1".into()), ("B".into(), "".into())],
            preprocessed: ["v-pre".into(), "f-pre".into()],
            glsl: ["v-glsl".into(), "f-glsl".into()],
            identity: compiler_identity().to_string(),
        }
    }

    #[test]
    fn golden_keys_are_recorded_per_identity_and_never_change_silently() {
        let identity = compiler_identity();
        // A diagnostic identity intentionally changes keys, but must still exercise the
        // unchanged ordinary stream against its genuine historical golden. No diagnostic
        // digest is invented or presented as a shipped/executed value.
        #[cfg(feature = "observer-uniform-layout")]
        let identity = identity.strip_suffix("-observer-uniform-layout-v1").expect("diagnostic identity discriminator");
        let row = GOLDEN_KEYS.iter().find(|(id, _)| *id == identity).unwrap_or_else(|| {
            panic!("no golden row for identity {identity}: add one when bumping PIPELINE_REVISION")
        });
        let mut ordinary = golden_case();
        ordinary.identity = identity.to_string();
        assert_eq!(
            key(&ordinary),
            row.1,
            "the program key of a fixed input changed under identity {identity}: bump PIPELINE_REVISION and append a row"
        );
        #[cfg(feature = "observer-uniform-layout")]
        {
            let diagnostic = golden_case();
            assert_ne!(diagnostic.identity, ordinary.identity);
            assert_ne!(key(&diagnostic), key(&ordinary), "diagnostic metadata cannot reuse an ordinary cached response");
            assert_eq!(key(&diagnostic), key(&golden_case()), "diagnostic keys remain deterministic");
        }
        let mut ids: Vec<&str> = GOLDEN_KEYS.iter().map(|(id, _)| *id).collect();
        ids.sort_unstable();
        ids.dedup();
        assert_eq!(ids.len(), GOLDEN_KEYS.len(), "one row per identity");
    }
}
