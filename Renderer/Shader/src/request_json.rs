// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! Reading the request JSON document (spec 2.4) into a [`ShaderRequest`].
//!
//! Unknown keys are ignored at every level; known keys are checked strictly:
//! a wrong type, a missing required key, an unknown enum spelling or a key
//! given twice is a parse error whose text starts with "json request parse
//! failed" and names the offending value (R3, R15, R16). The range and
//! uniqueness rules of R10 to R14 belong to validation, not to reading.

use crate::json::{self, Number, Value};
use crate::request::{
    CachePolicy, Combo, PointGeometry, Property, PropertyValue, RequestError, ShaderRequest, Stage, StageKind, Target,
    TextureComponents, TextureFormat, TextureRecord, ValidRequest, VideoPlanes,
};
use crate::text::quote;

/// Reads and validates a request document in one step.
pub fn parse_request(text: &str) -> Result<ValidRequest, RequestError> {
    ShaderRequest::from_json(text)?.validate()
}

/// Like [`parse_request`] for bytes that may not be UTF-8 (R3).
pub fn parse_request_bytes(bytes: &[u8]) -> Result<ValidRequest, RequestError> {
    ShaderRequest::from_json_bytes(bytes)?.validate()
}

impl ShaderRequest {
    /// Reads a request document without validating the rules of R10 to R14.
    pub fn from_json(text: &str) -> Result<ShaderRequest, RequestError> {
        let value = json::parse(text).map_err(RequestError::Json)?;
        let root = Obj::new(&value, "request")?;
        let mut request = ShaderRequest {
            shader_name: root.required_str("shader_name")?.to_string(),
            ..ShaderRequest::default()
        };

        if let Some(v) = root.get("target")? {
            let name = expect_str(v, "target")?;
            request.target = Target::parse(name).ok_or_else(|| RequestError::UnknownTarget(name.to_string()))?;
        }
        request.cache_policy = read_cache_policy(&root)?;

        for (i, item) in root.required_array("stages")?.iter().enumerate() {
            request.stages.push(read_stage(item, &format!("stages[{i}]"))?);
        }
        if let Some(v) = root.get("combos")? {
            for (i, item) in expect_array(v, "combos")?.iter().enumerate() {
                request.combos.push(read_combo(item, &format!("combos[{i}]"))?);
            }
        }
        if let Some(v) = root.get("textures")? {
            for (i, item) in expect_array(v, "textures")?.iter().enumerate() {
                request.textures.push(read_texture(item, &format!("textures[{i}]"))?);
            }
        }
        if let Some(v) = root.get("properties")? {
            for (i, item) in expect_array(v, "properties")?.iter().enumerate() {
                request.properties.push(read_property(item, &format!("properties[{i}]"))?);
            }
        }
        if let Some(value) = root.get("point_geometry")? {
            let geometry = Obj::new(value, "point_geometry")?;
            let count = expect_number(geometry.required("max_vertices")?, "point_geometry.max_vertices")?
                .as_str().parse::<u32>().map_err(|_| schema("point_geometry.max_vertices must be an unsigned integer".into()))?;
            request.point_geometry = Some(PointGeometry {
                source: geometry.required_str("source")?.into(),
                max_vertices: count,
                output_index_attribute: geometry.required_str("output_index_attribute")?.into(),
            });
        }
        Ok(request)
    }

    /// Like [`ShaderRequest::from_json`] for bytes that may not be UTF-8 (R3).
    pub fn from_json_bytes(bytes: &[u8]) -> Result<ShaderRequest, RequestError> {
        let text = std::str::from_utf8(bytes)
            .map_err(|e| RequestError::NotUtf8 { valid_up_to: e.valid_up_to() })?;
        ShaderRequest::from_json(text)
    }
}

fn schema(message: String) -> RequestError {
    RequestError::Schema(message)
}

/// An object whose known keys are looked up by name, with its path for messages.
struct Obj<'a> {
    path: String,
    members: &'a [(String, Value)],
}

impl<'a> Obj<'a> {
    fn new(value: &'a Value, path: &str) -> Result<Obj<'a>, RequestError> {
        match value {
            Value::Object(members) => Ok(Obj { path: path.to_string(), members }),
            other => Err(schema(format!("{path}: expected an object, found {}", other.type_name()))),
        }
    }

    fn child(&self, key: &str) -> String {
        format!("{}.{key}", self.path)
    }

    /// The value under `key`; a key present twice is an error.
    fn get(&self, key: &str) -> Result<Option<&'a Value>, RequestError> {
        let mut found = None;
        for (k, v) in self.members {
            if k == key {
                if found.is_some() {
                    return Err(schema(format!("{}: duplicate key {}", self.path, quote(key))));
                }
                found = Some(v);
            }
        }
        Ok(found)
    }

    fn required(&self, key: &str) -> Result<&'a Value, RequestError> {
        self.get(key)?
            .ok_or_else(|| schema(format!("{}: missing field {}", self.path, quote(key))))
    }

    fn required_str(&self, key: &str) -> Result<&'a str, RequestError> {
        expect_str(self.required(key)?, &self.child(key))
    }

    fn required_array(&self, key: &str) -> Result<&'a [Value], RequestError> {
        expect_array(self.required(key)?, &self.child(key))
    }

    fn optional_bool(&self, key: &str, default: bool) -> Result<bool, RequestError> {
        match self.get(key)? {
            None => Ok(default),
            Some(v) => expect_bool(v, &self.child(key)),
        }
    }

    fn required_bool(&self, key: &str) -> Result<bool, RequestError> {
        expect_bool(self.required(key)?, &self.child(key))
    }
}

fn mismatch(path: &str, expected: &str, found: &Value) -> RequestError {
    schema(format!("{path}: expected {expected}, found {}", found.type_name()))
}

fn expect_str<'a>(v: &'a Value, path: &str) -> Result<&'a str, RequestError> {
    match v {
        Value::String(s) => Ok(s),
        other => Err(mismatch(path, "a string", other)),
    }
}

fn expect_bool(v: &Value, path: &str) -> Result<bool, RequestError> {
    match v {
        Value::Bool(b) => Ok(*b),
        other => Err(mismatch(path, "a boolean", other)),
    }
}

fn expect_array<'a>(v: &'a Value, path: &str) -> Result<&'a [Value], RequestError> {
    match v {
        Value::Array(items) => Ok(items),
        other => Err(mismatch(path, "an array", other)),
    }
}

fn expect_number<'a>(v: &'a Value, path: &str) -> Result<&'a Number, RequestError> {
    match v {
        Value::Number(n) => Ok(n),
        other => Err(mismatch(path, "a number", other)),
    }
}

fn expect_f64(v: &Value, path: &str) -> Result<f64, RequestError> {
    let n = expect_number(v, path)?;
    n.as_f64()
        .ok_or_else(|| schema(format!("{path}: number {} is out of range", quote(n.as_str()))))
}

fn read_cache_policy(root: &Obj) -> Result<CachePolicy, RequestError> {
    // `cache_strategy` is the legacy spelling of `cache_policy`; giving both is a duplicate key (R15).
    let policy = root.get("cache_policy")?;
    let strategy = root.get("cache_strategy")?;
    let (key, value) = match (policy, strategy) {
        (None, None) => return Ok(CachePolicy::Disabled),
        (Some(_), Some(_)) => {
            return Err(schema(format!(
                "{}: duplicate key `cache_policy` (also given as `cache_strategy`)",
                root.path
            )));
        }
        (Some(v), None) => ("cache_policy", v),
        (None, Some(v)) => ("cache_strategy", v),
    };
    let obj = Obj::new(value, key)?;
    match obj.required_str("mode")? {
        "disabled" => Ok(CachePolicy::Disabled),
        "enabled" => match obj.get("scene_id")? {
            Some(v) => Ok(CachePolicy::Enabled { scene_id: expect_str(v, &obj.child("scene_id"))?.to_string() }),
            None => Err(schema(format!("{key}: mode `enabled` requires a `scene_id`"))),
        },
        other => Err(schema(format!(
            "{}: unknown cache mode {} (expected `disabled` or `enabled`)",
            obj.child("mode"),
            quote(other)
        ))),
    }
}

fn read_stage(value: &Value, path: &str) -> Result<Stage, RequestError> {
    let obj = Obj::new(value, path)?;
    let kind = obj.required_str("kind")?;
    let kind = StageKind::parse(kind).ok_or_else(|| {
        schema(format!(
            "{}: unknown stage kind {} (expected `vertex` or `fragment`)",
            obj.child("kind"),
            quote(kind)
        ))
    })?;
    Ok(Stage { kind, source: obj.required_str("source")?.to_string() })
}

fn read_combo(value: &Value, path: &str) -> Result<Combo, RequestError> {
    let obj = Obj::new(value, path)?;
    Ok(Combo {
        name: obj.required_str("name")?.to_string(),
        value: obj.required_str("value")?.to_string(),
    })
}

fn read_texture(value: &Value, path: &str) -> Result<TextureRecord, RequestError> {
    let obj = Obj::new(value, path)?;
    let slot_path = obj.child("slot");
    let number = expect_number(obj.required("slot")?, &slot_path)?;
    // A value that does not fit a byte is a parse error; 32 to 255 is a range error found by validation (R13).
    let slot = number
        .as_u64()
        .and_then(|n| u8::try_from(n).ok())
        .ok_or_else(|| schema(format!("{slot_path}: {} does not fit in a byte (0 to 255)", quote(number.as_str()))))?;

    let mut record = TextureRecord::new(slot);
    record.present = obj.optional_bool("present", true)?;
    record.enabled = obj.required_bool("enabled")?;
    if let Some(v) = obj.get("format")? {
        let name = expect_str(v, &obj.child("format"))?;
        record.format = TextureFormat::parse(name).ok_or_else(|| {
            schema(format!(
                "{}: unknown texture format {} (expected `unknown`, `r8`, `rg8` or `rgba8`)",
                obj.child("format"),
                quote(name)
            ))
        })?;
    }
    if let Some(v) = obj.get("components")? {
        let comps = Obj::new(v, &obj.child("components"))?;
        record.components = TextureComponents {
            compo1: comps.optional_bool("compo1", false)?,
            compo2: comps.optional_bool("compo2", false)?,
            compo3: comps.optional_bool("compo3", false)?,
            compo4: comps.optional_bool("compo4", false)?,
        };
    }
    if let Some(v) = obj.get("video_planes")? {
        let name = expect_str(v, &obj.child("video_planes"))?;
        record.video_planes = VideoPlanes::parse(name).ok_or_else(|| {
            schema(format!(
                "{}: unknown video plane layout {} (expected `none` or `nv12_biplanar`)",
                obj.child("video_planes"),
                quote(name)
            ))
        })?;
    }
    if let Some(v) = obj.get("sample_count")? {
        let path = obj.child("sample_count");
        let number = expect_number(v, &path)?;
        record.sample_count = Some(number.as_u64().and_then(|n| u32::try_from(n).ok())
            .ok_or_else(|| schema(format!("{path}: expected an unsigned 32-bit integer")))?);
    }
    Ok(record)
}

fn read_floats<const N: usize>(value: &Value, path: &str) -> Result<[f64; N], RequestError> {
    let items = expect_array(value, path)?;
    if items.len() != N {
        return Err(schema(format!("{path}: expected {N} numbers, found {}", items.len())));
    }
    let mut out = [0.0; N];
    for (i, item) in items.iter().enumerate() {
        out[i] = expect_f64(item, &format!("{path}[{i}]"))?;
    }
    Ok(out)
}

fn read_property(value: &Value, path: &str) -> Result<Property, RequestError> {
    let obj = Obj::new(value, path)?;
    let name = obj.required_str("name")?.to_string();
    let typed_path = obj.child("value");
    let typed = Obj::new(obj.required("value")?, &typed_path)?;
    let kind = typed.required_str("kind")?;
    let payload_path = typed.child("value");
    let payload = || typed.required("value");
    let value = match kind {
        "none" => PropertyValue::None,
        "string" => PropertyValue::String(expect_str(payload()?, &payload_path)?.to_string()),
        "number" => PropertyValue::Number(expect_f64(payload()?, &payload_path)?),
        "bool" => PropertyValue::Bool(expect_bool(payload()?, &payload_path)?),
        "vec2" => PropertyValue::Vec2(read_floats(payload()?, &payload_path)?),
        "vec3" => PropertyValue::Vec3(read_floats(payload()?, &payload_path)?),
        "vec4" => PropertyValue::Vec4(read_floats(payload()?, &payload_path)?),
        "matrix4" => PropertyValue::Matrix4(read_floats(payload()?, &payload_path)?),
        other => {
            return Err(schema(format!(
                "{}: unknown property kind {}",
                typed.child("kind"),
                quote(other)
            )));
        }
    };
    Ok(Property { name, value })
}

#[cfg(test)]
mod tests {
    use super::*;

    const STAGES: &str = r#""stages":[{"kind":"vertex","source":"v"},{"kind":"fragment","source":"f"}]"#;

    fn doc(extra: &str) -> String {
        format!(r#"{{"shader_name":"s",{STAGES}{extra}}}"#)
    }

    fn parse_err(text: &str) -> String {
        parse_request(text).unwrap_err().to_string()
    }

    #[test]
    fn minimal_document_gets_every_default() {
        let req = parse_request(&doc("")).unwrap();
        assert_eq!(req.shader_name(), "s");
        assert_eq!(req.target(), Target::MetalMsl);
        assert_eq!(req.cache_policy(), &CachePolicy::Disabled);
        assert_eq!(req.stage(StageKind::Vertex).source, "v");
        assert_eq!(req.stage(StageKind::Fragment).source, "f");
        assert!(req.combos().is_empty() && req.textures().is_empty() && req.properties().is_empty());
    }

    #[test]
    fn omitted_and_explicit_defaults_give_the_same_request() {
        let omitted = parse_request(&doc(r#","textures":[{"slot":1,"enabled":false}]"#)).unwrap();
        let explicit = parse_request(&doc(
            r#","target":"metal_msl","cache_policy":{"mode":"disabled"},"combos":[],"properties":[],
               "textures":[{"slot":1,"present":true,"enabled":false,"format":"unknown",
                            "components":{"compo1":false,"compo2":false,"compo3":false,"compo4":false},
                            "video_planes":"none"}]"#,
        ))
        .unwrap();
        assert_eq!(omitted, explicit);
    }

    #[test]
    fn physical_texture_samples_are_optional_and_have_supported_counts() {
        for count in [1, 2, 4, 8] {
            let request = parse_request(&doc(&format!(r#", "textures":[{{"slot":0,"enabled":true,"sample_count":{count}}}]"#))).unwrap();
            assert_eq!(request.texture(0).unwrap().sample_count, Some(count));
        }
        for count in ["0", "3", "16", "-1", "1.5", "null", "\"1\""] {
            assert!(parse_request(&doc(&format!(r#", "textures":[{{"slot":0,"enabled":true,"sample_count":{count}}}]"#))).is_err(), "{count}");
        }
        let request = parse_request(&doc(r#", "textures":[{"slot":0,"enabled":true}]"#)).unwrap();
        assert_eq!(request.texture(0).unwrap().sample_count, None);
    }

    #[test]
    fn unknown_keys_are_ignored_at_every_level() {
        let text = r#"{"future":1,"shader_name":"s","target":"metal_msl","cache_policy":{"mode":"disabled","x":1},
              "stages":[{"kind":"vertex","source":"v","extra":[1]},{"kind":"fragment","source":"f","extra":null}],
              "combos":[{"name":"A","value":"1","note":"n"}],
              "textures":[{"slot":0,"enabled":true,"components":{"compo1":true,"compo9":true},"more":{}}],
              "properties":[{"name":"p","value":{"kind":"bool","value":true,"unit":"x"},"more":1}]}"#;
        let req = parse_request(text).unwrap();
        assert_eq!(req.combos()[0].value, "1");
        assert!(req.texture(0).unwrap().components.compo1);
    }

    #[test]
    fn invalid_json_is_a_json_failure() {
        for bad in ["", "{", "not json", "[]", "null", "{\"shader_name\":}"] {
            let text = parse_err(bad);
            assert!(text.to_lowercase().contains("json"), "{bad:?}: {text}");
        }
        assert!(parse_err("[]").contains("expected an object"));
    }

    #[test]
    fn invalid_utf8_is_reported_as_such() {
        let e = parse_request_bytes(b"{\"shader_name\":\"\xff\"}").unwrap_err();
        assert!(matches!(e, RequestError::NotUtf8 { valid_up_to: 16 }));
        assert!(e.to_string().contains("not valid UTF-8"));
        assert!(parse_request_bytes(doc("").as_bytes()).is_ok());
    }

    #[test]
    fn required_keys_and_types_are_enforced_with_their_names() {
        assert!(parse_err(&format!("{{{STAGES}}}")).contains("missing field `shader_name`"));
        assert!(parse_err(r#"{"shader_name":"s"}"#).contains("missing field `stages`"));
        assert!(parse_err(r#"{"shader_name":3,"stages":[]}"#).contains("shader_name: expected a string"));
        assert!(parse_err(r#"{"shader_name":"s","stages":{}}"#).contains("stages: expected an array"));
        assert!(parse_err(&doc(r#","combos":[{"name":"A"}]"#)).contains("combos[0]: missing field `value`"));
        assert!(parse_err(&doc(r#","combos":[{"name":"A","value":1}]"#)).contains("combos[0].value: expected a string"));
        assert!(parse_err(&doc(r#","combos":{}"#)).contains("combos: expected an array"));
    }

    #[test]
    fn stage_kinds_are_exactly_the_two_spellings() {
        let bad = r#"{"shader_name":"s","stages":[{"kind":"geometry","source":""}]}"#;
        let text = parse_err(bad);
        assert!(text.contains("unknown stage kind `geometry`"), "{text}");
        let bad = r#"{"shader_name":"s","stages":[{"kind":"Vertex","source":""}]}"#;
        assert!(parse_err(bad).contains("`Vertex`"));
    }

    #[test]
    fn validation_failures_surface_through_the_json_entry_point() {
        let text = parse_err(r#"{"shader_name":"s","stages":[{"kind":"vertex","source":""}]}"#);
        assert!(text.contains("missing fragment stage"), "{text}");
        let text = parse_err(r#"{"shader_name":"","stages":[]}"#);
        assert!(text.contains("shader name is empty"), "empty name is reported first: {text}");
        let text = parse_err(&format!(r#"{{"shader_name":"a\u0000b",{STAGES}}}"#));
        assert!(text.contains("NUL"), "{text}");
        let text = parse_err(&doc(r#","combos":[{"name":"A","value":"1"},{"name":"a","value":"2"}]"#));
        assert!(text.contains("duplicate combo name `a`"), "{text}");
        let text = parse_err(&doc(r#","combos":[{"name":"9x","value":"1"}]"#));
        assert!(text.contains("`9x`"), "{text}");
    }

    #[test]
    fn shader_name_backslashes_are_normalised() {
        let text = format!(r#"{{"shader_name":"effects\\foo",{STAGES}}}"#);
        assert_eq!(parse_request(&text).unwrap().shader_name(), "effects/foo");
    }

    #[test]
    fn target_default_and_rejection() {
        assert_eq!(parse_request(&doc(r#","target":"metal_msl""#)).unwrap().target(), Target::MetalMsl);
        let text = parse_err(&doc(r#","target":"vulkan_spirv""#));
        assert!(text.contains("json request parse failed"), "{text}");
        assert!(text.contains("vulkan_spirv"), "the offending string appears verbatim: {text}");
        assert!(parse_err(&doc(r#","target":"METAL_MSL""#)).contains("METAL_MSL"));
        assert!(parse_err(&doc(",\"target\":\"\"")).contains("unknown target"));
        assert!(parse_err(&doc(r#","target":null"#)).contains("target: expected a string"));
    }

    #[test]
    fn cache_policy_modes() {
        let enabled = parse_request(&doc(r#","cache_policy":{"mode":"enabled","scene_id":"abc"}"#)).unwrap();
        assert_eq!(enabled.cache_policy(), &CachePolicy::Enabled { scene_id: "abc".into() });
        let legacy = parse_request(&doc(r#","cache_strategy":{"mode":"enabled","scene_id":"abc"}"#)).unwrap();
        assert_eq!(legacy, enabled, "the legacy spelling means the same");
        let legacy = parse_request(&doc(r#","cache_strategy":{"mode":"disabled"}"#)).unwrap();
        assert_eq!(legacy.cache_policy(), &CachePolicy::Disabled);

        let text = parse_err(&doc(r#","cache_policy":{"mode":"enabled"}"#));
        assert!(text.contains("requires a `scene_id`"), "{text}");
        let text = parse_err(&doc(r#","cache_policy":{"mode":"sometimes"}"#));
        assert!(text.contains("`sometimes`"), "{text}");
        assert!(parse_err(&doc(r#","cache_policy":{}"#)).contains("missing field `mode`"));
        assert!(parse_err(&doc(r#","cache_policy":"disabled""#)).contains("expected an object"));
    }

    #[test]
    fn giving_both_cache_spellings_is_a_duplicate_key() {
        let text = parse_err(&doc(r#","cache_policy":{"mode":"disabled"},"cache_strategy":{"mode":"disabled"}"#));
        assert!(text.contains("duplicate key"), "{text}");
    }

    #[test]
    fn a_known_key_given_twice_is_rejected() {
        let text = parse_err(r#"{"shader_name":"a","shader_name":"b","stages":[]}"#);
        assert!(text.contains("duplicate key `shader_name`"), "{text}");
        // Unknown keys may repeat: they are never read.
        assert!(parse_request(&doc(r#","x":1,"x":2"#)).is_ok());
    }

    #[test]
    fn texture_record_fields_and_defaults() {
        let req = parse_request(&doc(
            r#","textures":[
                {"slot":0,"enabled":true},
                {"slot":3,"present":false,"enabled":false,"format":"rgba8"},
                {"slot":5,"enabled":true,"format":"rg8","components":{"compo1":true,"compo4":true},"video_planes":"nv12_biplanar"}]"#,
        ))
        .unwrap();
        let t0 = req.texture(0).unwrap();
        assert!(t0.present && t0.enabled);
        assert_eq!(t0.format, TextureFormat::Unknown);
        assert_eq!(t0.components, TextureComponents::default());
        assert_eq!(t0.video_planes, VideoPlanes::None);
        let t3 = req.texture(3).unwrap();
        assert!(!t3.present && !t3.enabled);
        assert_eq!(t3.format, TextureFormat::Rgba8);
        let t5 = req.texture(5).unwrap();
        assert_eq!(t5.format, TextureFormat::Rg8);
        assert_eq!(
            t5.components,
            TextureComponents { compo1: true, compo2: false, compo3: false, compo4: true }
        );
        assert_eq!(req.planar_slots(), vec![5]);
    }

    #[test]
    fn texture_enabled_is_required() {
        let text = parse_err(&doc(r#","textures":[{"slot":1}]"#));
        assert!(text.contains("missing field `enabled`"), "{text}");
    }

    #[test]
    fn texture_slot_range_and_fit() {
        // 32 to 255: a range error from validation.
        for slot in [32, 255] {
            let text = parse_err(&doc(&format!(r#","textures":[{{"slot":{slot},"enabled":true}}]"#)));
            assert!(text.contains(&format!("texture slot {slot} is out of range")), "{text}");
        }
        // Not fitting a byte, negative or fractional: a parse error.
        for slot in ["256", "300", "-1", "1.5", "1e1", "\"2\"", "null"] {
            let text = parse_err(&doc(&format!(r#","textures":[{{"slot":{slot},"enabled":true}}]"#)));
            assert!(text.contains("json request parse failed") && text.contains("slot"), "{slot}: {text}");
        }
        let text = parse_err(&doc(r#","textures":[{"slot":300,"enabled":true}]"#));
        assert!(text.contains("`300`"), "{text}");
        let text = parse_err(&doc(
            r#","textures":[{"slot":2,"enabled":true},{"slot":2,"enabled":false}]"#,
        ));
        assert!(text.contains("duplicate texture slot 2"), "{text}");
    }

    #[test]
    fn texture_enum_spellings_are_checked() {
        assert!(parse_err(&doc(r#","textures":[{"slot":0,"enabled":true,"format":"bc1"}]"#)).contains("`bc1`"));
        assert!(
            parse_err(&doc(r#","textures":[{"slot":0,"enabled":true,"video_planes":"yuv"}]"#)).contains("`yuv`")
        );
        assert!(
            parse_err(&doc(r#","textures":[{"slot":0,"enabled":true,"components":{"compo1":1}}]"#))
                .contains("compo1")
        );
    }

    #[test]
    fn properties_cover_every_kind() {
        let req = parse_request(&doc(
            r#","properties":[
                {"name":"s","value":{"kind":"string","value":"hi"}},
                {"name":"n","value":{"kind":"number","value":1.5}},
                {"name":"b","value":{"kind":"bool","value":true}},
                {"name":"v2","value":{"kind":"vec2","value":[1,2]}},
                {"name":"v3","value":{"kind":"vec3","value":[1,2,3]}},
                {"name":"v4","value":{"kind":"vec4","value":[1,2,3,4]}},
                {"name":"m","value":{"kind":"matrix4","value":[1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1]}}]"#,
        ))
        .unwrap();
        let kinds: Vec<&str> = req.properties().iter().map(|p| p.value.kind_name()).collect();
        assert_eq!(kinds, ["string", "number", "bool", "vec2", "vec3", "vec4", "matrix4"]);
        assert_eq!(req.properties()[1].value, PropertyValue::Number(1.5));
        assert_eq!(req.properties()[3].value, PropertyValue::Vec2([1.0, 2.0]));
    }

    #[test]
    fn property_errors_name_the_property_or_the_path() {
        let text = parse_err(&doc(r#","properties":[{"name":"gone","value":{"kind":"none"}}]"#));
        assert!(text.contains("property `gone` has no value"), "{text}");
        let text = parse_err(&doc(r#","properties":[{"name":"gone","value":{"kind":"none","value":null}}]"#));
        assert!(text.contains("property `gone` has no value"), "{text}");
        let text = parse_err(&doc(r#","properties":[{"name":"","value":{"kind":"bool","value":true}}]"#));
        assert!(text.contains("property name is empty"), "{text}");
        let text = parse_err(&doc(r#","properties":[{"name":"p","value":{"kind":"vec2","value":[1,2,3]}}]"#));
        assert!(text.contains("expected 2 numbers, found 3"), "{text}");
        let text = parse_err(&doc(r#","properties":[{"name":"p","value":{"kind":"vec2","value":[1,"x"]}}]"#));
        assert!(text.contains("value[1]: expected a number"), "{text}");
        let text = parse_err(&doc(r#","properties":[{"name":"p","value":{"kind":"quaternion","value":[1]}}]"#));
        assert!(text.contains("`quaternion`"), "{text}");
        let text = parse_err(&doc(r#","properties":[{"name":"p","value":{"kind":"number","value":1e999}}]"#));
        assert!(text.contains("out of range"), "{text}");
        let text = parse_err(&doc(r#","properties":[{"name":"p"}]"#));
        assert!(text.contains("missing field `value`"), "{text}");
        let text = parse_err(&doc(r#","properties":[{"name":"p","value":{"kind":"bool"}}]"#));
        assert!(text.contains("missing field `value`"), "{text}");
    }

    #[test]
    fn deeply_nested_documents_fail_cleanly() {
        let nested = format!(r#"{{"shader_name":"s","x":{}{}}}"#, "[".repeat(5000), "]".repeat(5000));
        let text = std::thread::Builder::new()
            .stack_size(512 * 1024)
            .spawn(move || parse_err(&nested))
            .unwrap()
            .join()
            .unwrap();
        assert!(text.contains("too deep"), "{text}");
    }
}
