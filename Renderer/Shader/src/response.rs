// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! The response model that is not reflection: the per-stage payload (spec
//! 2.6.1) and the program-wide metadata (2.6.2), with their JSON documents.
//!
//! Documents are compact and keys are written in the order of the spec (R8);
//! the keys the engine reads with a hard requirement are always present (R94).

use std::collections::BTreeSet;

use crate::binding::Binding;
use crate::error::ShaderError;
use crate::identity::MSL_LANGUAGE_VERSION;
use crate::json;
use crate::request::{StageKind, Target};

/// Which coordinate transforms the translated source applies (R26). Each flag
/// is true if and only if the source really applies that transform.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Conventions {
    pub clip_space_y_flipped: bool,
    pub clip_space_depth_remapped: bool,
    pub texture_origin_flipped: bool,
}

impl Conventions {
    pub fn to_json(self) -> String {
        json::object(&[
            ("clip_space_y_flipped", json::boolean(self.clip_space_y_flipped)),
            ("clip_space_depth_remapped", json::boolean(self.clip_space_depth_remapped)),
            ("texture_origin_flipped", json::boolean(self.texture_origin_flipped)),
        ])
    }
}

/// What the engine receives for one stage: MSL text through its own accessor
/// and a small JSON payload.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct StagePayload {
    pub kind: StageKind,
    pub msl_source: String,
    /// The function to look up with `newFunctionWithName:`; never assumed to be `main`.
    pub entry_point: String,
    /// `"major.minor"`.
    pub language_version: String,
    /// Every resource global of the stage, in declaration order (R37).
    pub bindings: Vec<Binding>,
    pub conventions: Conventions,
}

impl StagePayload {
    /// A payload with the current language version and untransformed conventions.
    pub fn new(kind: StageKind, msl_source: String, entry_point: String, bindings: Vec<Binding>) -> StagePayload {
        StagePayload {
            kind,
            msl_source,
            entry_point,
            language_version: MSL_LANGUAGE_VERSION.to_string(),
            bindings,
            conventions: Conventions::default(),
        }
    }

    /// Every stage of the Metal path reports target 1.
    pub fn target(&self) -> Target {
        Target::MetalMsl
    }

    /// The per-stage JSON document: `entry_point`, `language_version`, `bindings`, `conventions`.
    pub fn to_json(&self) -> String {
        json::object(&[
            ("entry_point", json::string(&self.entry_point)),
            ("language_version", json::string(&self.language_version)),
            ("bindings", json::array(self.bindings.iter().map(Binding::to_json))),
            ("conventions", self.conventions.to_json()),
        ])
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ComboEntry {
    pub name: String,
    pub value: String,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct AliasEntry {
    pub material: String,
    pub uniform: String,
    /// The editor displays degrees while the shader stores radians.
    pub rad2deg: bool,
}

/// A default uniform value from a shader annotation.
#[derive(Clone, Debug, PartialEq)]
pub enum UniformValue {
    Number(f32),
    Bool(bool),
    Vec2([f32; 2]),
    Vec3([f32; 3]),
    Vec4([f32; 4]),
    Matrix4([f32; 16]),
    /// A value the engine ignores (a default that is a list of another length).
    Text(String),
}

impl UniformValue {
    pub fn kind_name(&self) -> &'static str {
        match self {
            UniformValue::Number(_) => "number",
            UniformValue::Bool(_) => "bool",
            UniformValue::Vec2(_) => "vec2",
            UniformValue::Vec3(_) => "vec3",
            UniformValue::Vec4(_) => "vec4",
            UniformValue::Matrix4(_) => "matrix4",
            UniformValue::Text(_) => "string",
        }
    }

    /// `None` when a component is not finite.
    fn value_json(&self) -> Option<String> {
        fn list(values: &[f32]) -> Option<String> {
            let tokens: Option<Vec<String>> = values.iter().map(|v| json::f32_token(*v)).collect();
            tokens.map(json::array)
        }
        match self {
            UniformValue::Number(v) => json::f32_token(*v),
            UniformValue::Bool(b) => Some(json::boolean(*b)),
            UniformValue::Vec2(v) => list(v),
            UniformValue::Vec3(v) => list(v),
            UniformValue::Vec4(v) => list(v),
            UniformValue::Matrix4(v) => list(v),
            UniformValue::Text(s) => Some(json::string(s)),
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct DefaultUniform {
    pub name: String,
    pub value: UniformValue,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DefaultTexture {
    pub slot: u8,
    pub path: String,
}

/// What the shader's own annotations declare (R53 to R59).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Metadata {
    pub combos: Vec<ComboEntry>,
    pub aliases: Vec<AliasEntry>,
    pub default_uniforms: Vec<DefaultUniform>,
    pub default_textures: Vec<DefaultTexture>,
    /// Ascending, no duplicates by construction; identical in the reflection document (R52).
    pub active_texture_slots: BTreeSet<u8>,
}

impl Metadata {
    /// The metadata document. Fails when a default value is not a finite number:
    /// JSON cannot carry it and `null` would be a lie, so it is a compile error (2.6.2).
    pub fn to_json(&self) -> Result<String, ShaderError> {
        let combos = json::array(self.combos.iter().map(|c| {
            json::object(&[("name", json::string(&c.name)), ("value", json::string(&c.value))])
        }));
        let aliases = json::array(self.aliases.iter().map(|a| {
            let mut fields = vec![("material", json::string(&a.material)), ("uniform", json::string(&a.uniform))];
            if a.rad2deg { fields.push(("rad2deg", "true".to_string())); }
            json::object(&fields)
        }));
        let mut uniforms = Vec::with_capacity(self.default_uniforms.len());
        for u in &self.default_uniforms {
            let value = u
                .value
                .value_json()
                .ok_or_else(|| ShaderError::NonFiniteDefault { name: u.name.clone() })?;
            let typed = json::object(&[("kind", json::string(u.value.kind_name())), ("value", value)]);
            uniforms.push(json::object(&[("name", json::string(&u.name)), ("value", typed)]));
        }
        let textures = json::array(self.default_textures.iter().map(|t| {
            json::object(&[("slot", t.slot.to_string()), ("path", json::string(&t.path))])
        }));
        Ok(json::object(&[
            ("combos", combos),
            ("aliases", aliases),
            ("default_uniforms", json::array(uniforms)),
            ("default_textures", textures),
            ("active_texture_slots", json::array(self.active_texture_slots.iter().map(u8::to_string))),
        ]))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::binding::SlotKind;
    use crate::json::Value;

    fn parsed(text: &str) -> Vec<(String, Value)> {
        let Value::Object(m) = json::parse(text).unwrap() else { panic!("{text}") };
        m
    }

    fn keys(text: &str) -> Vec<String> {
        parsed(text).into_iter().map(|(k, _)| k).collect()
    }

    #[test]
    fn the_stage_payload_has_the_required_keys_in_order() {
        let bindings = vec![
            Binding { name: "g_Texture0".into(), set: 0, binding: 0, slot_kind: SlotKind::Texture, slot: 0 },
            Binding { name: "GlobalUniforms".into(), set: 0, binding: 1, slot_kind: SlotKind::Buffer, slot: 1 },
        ];
        let payload = StagePayload::new(StageKind::Fragment, "msl".into(), "main0".into(), bindings);
        let text = payload.to_json();
        assert_eq!(keys(&text), ["entry_point", "language_version", "bindings", "conventions"]);
        assert_eq!(
            text,
            concat!(
                r#"{"entry_point":"main0","language_version":"2.0","bindings":["#,
                r#"{"name":"g_Texture0","set":0,"binding":0,"slot_kind":"texture","slot":0},"#,
                r#"{"name":"GlobalUniforms","set":0,"binding":1,"slot_kind":"buffer","slot":1}],"#,
                r#""conventions":{"clip_space_y_flipped":false,"clip_space_depth_remapped":false,"texture_origin_flipped":false}}"#
            )
        );
        assert_eq!(payload.target().abi_value(), 1);
        assert_eq!(payload.kind.abi_value(), 1);
    }

    #[test]
    fn conventions_default_to_untransformed_and_report_each_flag() {
        assert_eq!(Conventions::default(), Conventions { clip_space_y_flipped: false, clip_space_depth_remapped: false, texture_origin_flipped: false });
        let c = Conventions { clip_space_y_flipped: true, clip_space_depth_remapped: false, texture_origin_flipped: true };
        assert_eq!(c.to_json(), r#"{"clip_space_y_flipped":true,"clip_space_depth_remapped":false,"texture_origin_flipped":true}"#);
    }

    #[test]
    fn the_language_version_is_2_0() {
        let p = StagePayload::new(StageKind::Vertex, String::new(), "m".into(), vec![]);
        assert_eq!(p.language_version, "2.0");
    }

    #[test]
    fn empty_metadata_has_all_five_arrays_in_order() {
        let text = Metadata::default().to_json().unwrap();
        assert_eq!(
            text,
            r#"{"combos":[],"aliases":[],"default_uniforms":[],"default_textures":[],"active_texture_slots":[]}"#
        );
        assert_eq!(keys(&text), ["combos", "aliases", "default_uniforms", "default_textures", "active_texture_slots"]);
    }

    #[test]
    fn metadata_entries_carry_the_fields_the_engine_requires() {
        let m = Metadata {
            combos: vec![
                ComboEntry { name: "NORMALMAP".into(), value: "0".into() },
                ComboEntry { name: "FOG".into(), value: "1".into() },
            ],
            aliases: vec![AliasEntry { material: "speed".into(), uniform: "g_Speed".into(), ..Default::default() }],
            default_uniforms: vec![
                DefaultUniform { name: "g_A".into(), value: UniformValue::Number(0.5) },
                DefaultUniform { name: "g_B".into(), value: UniformValue::Bool(true) },
                DefaultUniform { name: "g_C".into(), value: UniformValue::Vec2([1.0, 2.5]) },
                DefaultUniform { name: "g_D".into(), value: UniformValue::Vec3([1.0, 0.0, -1.0]) },
                DefaultUniform { name: "g_E".into(), value: UniformValue::Vec4([0.0, 0.1, 0.2, 1.0]) },
                DefaultUniform { name: "g_F".into(), value: UniformValue::Text("1 2 3 4 5".into()) },
            ],
            default_textures: vec![DefaultTexture { slot: 1, path: "util/noise".into() }],
            active_texture_slots: BTreeSet::from([2, 0]),
        };
        let text = m.to_json().unwrap();
        assert!(text.contains(r#""combos":[{"name":"NORMALMAP","value":"0"},{"name":"FOG","value":"1"}]"#), "{text}");
        assert!(text.contains(r#""aliases":[{"material":"speed","uniform":"g_Speed"}]"#));
        assert!(text.contains(r#"{"name":"g_A","value":{"kind":"number","value":0.5}}"#));
        assert!(text.contains(r#"{"name":"g_B","value":{"kind":"bool","value":true}}"#));
        assert!(text.contains(r#"{"name":"g_C","value":{"kind":"vec2","value":[1,2.5]}}"#));
        assert!(text.contains(r#"{"name":"g_D","value":{"kind":"vec3","value":[1,0,-1]}}"#));
        assert!(text.contains(r#"{"name":"g_E","value":{"kind":"vec4","value":[0,0.1,0.2,1]}}"#));
        assert!(text.contains(r#"{"name":"g_F","value":{"kind":"string","value":"1 2 3 4 5"}}"#));
        assert!(text.contains(r#""default_textures":[{"slot":1,"path":"util/noise"}]"#));
        assert!(text.ends_with(r#""active_texture_slots":[0,2]}"#), "ascending: {text}");
    }

    #[test]
    fn a_matrix_default_writes_sixteen_numbers() {
        let mut identity = [0.0f32; 16];
        for i in 0..4 {
            identity[i * 5] = 1.0;
        }
        let m = Metadata {
            default_uniforms: vec![DefaultUniform { name: "g_M".into(), value: UniformValue::Matrix4(identity) }],
            ..Metadata::default()
        };
        let text = m.to_json().unwrap();
        assert!(text.contains(r#""kind":"matrix4","value":[1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1]"#), "{text}");
    }

    #[test]
    fn floats_are_the_shortest_text_that_reads_back_identically() {
        let m = Metadata {
            default_uniforms: vec![DefaultUniform { name: "g_A".into(), value: UniformValue::Number(0.1) }],
            ..Metadata::default()
        };
        let text = m.to_json().unwrap();
        assert!(text.contains(r#""value":0.1}"#), "{text}");
        let Value::Object(top) = json::parse(&text).unwrap() else { panic!() };
        let Value::Array(uniforms) = &top[2].1 else { panic!() };
        let Value::Object(entry) = &uniforms[0] else { panic!() };
        let Value::Object(typed) = &entry[1].1 else { panic!() };
        let Value::Number(n) = &typed[1].1 else { panic!() };
        assert_eq!(n.as_str().parse::<f32>().unwrap().to_bits(), 0.1f32.to_bits());
    }

    #[test]
    fn a_non_finite_default_is_a_compile_error_never_null() {
        for value in [
            UniformValue::Number(f32::NAN),
            UniformValue::Vec2([1.0, f32::INFINITY]),
            UniformValue::Matrix4([f32::NEG_INFINITY; 16]),
        ] {
            let m = Metadata {
                default_uniforms: vec![DefaultUniform { name: "g_Bad".into(), value }],
                ..Metadata::default()
            };
            let err = m.to_json().unwrap_err();
            assert!(err.to_string().contains("`g_Bad`") && err.to_string().contains("not a finite number"), "{err}");
        }
    }

    #[test]
    fn duplicates_across_entries_are_kept_in_order() {
        let m = Metadata {
            combos: vec![
                ComboEntry { name: "A".into(), value: "1".into() },
                ComboEntry { name: "A".into(), value: "2".into() },
            ],
            aliases: vec![
                AliasEntry { material: "m".into(), uniform: "u".into(), ..Default::default() },
                AliasEntry { material: "m".into(), uniform: "u".into(), ..Default::default() },
            ],
            ..Metadata::default()
        };
        let text = m.to_json().unwrap();
        assert!(text.contains(r#"[{"name":"A","value":"1"},{"name":"A","value":"2"}]"#));
        assert_eq!(text.matches(r#"{"material":"m","uniform":"u"}"#).count(), 2);
    }

    #[test]
    fn a_minimal_reader_of_the_required_keys_succeeds() {
        // R94: a reader that looks at nothing but the keys the engine reads with a hard requirement.
        let m = Metadata {
            combos: vec![ComboEntry { name: "A".into(), value: "1".into() }],
            aliases: vec![AliasEntry { material: "m".into(), uniform: "u".into(), ..Default::default() }],
            default_uniforms: vec![DefaultUniform { name: "g".into(), value: UniformValue::Number(1.0) }],
            default_textures: vec![DefaultTexture { slot: 0, path: "p".into() }],
            active_texture_slots: BTreeSet::new(),
        };
        let top = parsed(&m.to_json().unwrap());
        let get = |members: &[(String, Value)], key: &str| -> Value {
            members.iter().find(|(k, _)| k == key).map(|(_, v)| v.clone()).unwrap_or_else(|| panic!("missing {key}"))
        };
        let Value::Array(combos) = get(&top, "combos") else { panic!() };
        let Value::Object(c) = &combos[0] else { panic!() };
        get(c, "name");
        get(c, "value");
        let Value::Array(aliases) = get(&top, "aliases") else { panic!() };
        let Value::Object(a) = &aliases[0] else { panic!() };
        get(a, "material");
        get(a, "uniform");
        let Value::Array(defaults) = get(&top, "default_uniforms") else { panic!() };
        let Value::Object(d) = &defaults[0] else { panic!() };
        get(d, "name");
        let Value::Object(v) = get(d, "value") else { panic!() };
        get(&v, "kind");
        get(&v, "value");
        let Value::Array(textures) = get(&top, "default_textures") else { panic!() };
        let Value::Object(t) = &textures[0] else { panic!() };
        get(t, "slot");
        get(t, "path");
    }
}
