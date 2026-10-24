// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! The generated `LightingV1` block (R32 to R34).
//!
//! A lit stock shader says `#require LightingV1` where Wallpaper Engine would
//! generate the light uniforms and a `PerformLighting_V1` function. The text is
//! ordinary dialect source, written with constant indices so that every array
//! element is visibly used at the array's full size (reflection and the
//! uniform block layout depend on that). Shadows and cookies are not used: the
//! shadow factor is the constant `1.0` (R34 item 4).

use std::collections::HashMap;

/// Most lights of one type.
pub const MAX_LIGHTS: usize = 15;

/// Counts of point, spot, tube and directional lights.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct LightCounts {
    pub point: usize,
    pub spot: usize,
    pub tube: usize,
    pub directional: usize,
}

/// R33: a count is the macro's decimal integer text; anything else or a
/// negative number is 0, and more than 15 is 15.
fn count_of(env: &HashMap<String, String>, name: &str) -> usize {
    let Some(text) = env.get(name) else { return 0 };
    let text = text.trim();
    let digits = text.strip_prefix('+').unwrap_or(text);
    if digits.is_empty() || !digits.bytes().all(|b| b.is_ascii_digit()) {
        // A negative integer (`-7`) and non-numbers both count as 0.
        return 0;
    }
    digits.parse::<usize>().map_or(MAX_LIGHTS, |n| n.min(MAX_LIGHTS))
}

pub fn light_counts(env: &HashMap<String, String>) -> LightCounts {
    LightCounts {
        point: count_of(env, "LIGHTS_POINT"),
        spot: count_of(env, "LIGHTS_SPOT"),
        tube: count_of(env, "LIGHTS_TUBE"),
        directional: count_of(env, "LIGHTS_DIRECTIONAL"),
    }
}

/// R33: `LIGHTING` must be defined, and its text must be a non-integer or a non-zero integer.
pub fn lighting_enabled(env: &HashMap<String, String>) -> bool {
    let Some(text) = env.get("LIGHTING") else { return false };
    let text = text.trim();
    let digits = text.strip_prefix(['+', '-']).unwrap_or(text);
    let is_integer = !digits.is_empty() && digits.bytes().all(|b| b.is_ascii_digit());
    if is_integer { digits.bytes().any(|b| b != b'0') } else { true }
}

/// The text written in place of `#require LightingV1`, one line per element.
pub fn lighting_block(counts: LightCounts) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    let arrays: [(usize, &[&str]); 4] = [
        (counts.point, &["g_LPoint_Color", "g_LPoint_Origin"]),
        (counts.spot, &["g_LSpot_Color", "g_LSpot_Origin", "g_LSpot_Direction", "g_LSpot_Exponent"]),
        (counts.tube, &["g_LTube_Color", "g_LTube_OriginA", "g_LTube_OriginB"]),
        (counts.directional, &["g_LDirectional_Color", "g_LDirectional_Direction"]),
    ];
    for (n, names) in arrays {
        if n > 0 {
            for name in names {
                out.push(format!("uniform vec4 {name}[{n}];"));
            }
        }
    }
    out.push(
        "vec3 PerformLighting_V1(vec3 worldPos, vec3 color, vec3 normal, vec3 viewVector, vec3 specularTint, vec3 baseReflectance, float roughness, float metallic)"
            .to_string(),
    );
    out.push("{".to_string());
    out.push("\tvec3 light = vec3(0.0, 0.0, 0.0);".to_string());
    let common = "viewVector, color";
    let tail = "specularTint, baseReflectance, roughness, metallic, 1.0";
    for i in 0..counts.point {
        out.push(format!(
            "\tlight += ComputePBRLightShadow(normal, g_LPoint_Origin[{i}].xyz - worldPos, {common}, g_LPoint_Color[{i}].rgb, g_LPoint_Color[{i}].w, g_LPoint_Origin[{i}].w, {tail});"
        ));
    }
    for i in 0..counts.spot {
        out.push("\t{".to_string());
        out.push(format!("\t\tvec3 lightDelta = g_LSpot_Origin[{i}].xyz - worldPos;"));
        out.push(format!(
            "\t\tfloat spotCone = smoothstep(g_LSpot_Direction[{i}].w, g_LSpot_Origin[{i}].w, -dot(normalize(lightDelta), g_LSpot_Direction[{i}].xyz));"
        ));
        out.push(format!(
            "\t\tlight += ComputePBRLightShadow(normal, lightDelta, {common}, g_LSpot_Color[{i}].rgb * spotCone, g_LSpot_Color[{i}].w, g_LSpot_Exponent[{i}].x, {tail});"
        ));
        out.push("\t}".to_string());
    }
    for i in 0..counts.tube {
        out.push("\t{".to_string());
        out.push(format!(
            "\t\tvec3 lightDelta = PointSegmentDelta(worldPos, g_LTube_OriginA[{i}].xyz, g_LTube_OriginB[{i}].xyz);"
        ));
        out.push(format!(
            "\t\tlight += ComputePBRLightShadow(normal, lightDelta, {common}, g_LTube_Color[{i}].rgb, g_LTube_Color[{i}].w, g_LTube_OriginA[{i}].w, {tail});"
        ));
        out.push("\t}".to_string());
    }
    for i in 0..counts.directional {
        out.push(format!(
            "\tlight += ComputePBRLightShadowInfinite(normal, g_LDirectional_Direction[{i}].xyz, {common}, g_LDirectional_Color[{i}].rgb, {tail});"
        ));
    }
    out.push("\treturn light;".to_string());
    out.push("}".to_string());
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn env(pairs: &[(&str, &str)]) -> HashMap<String, String> {
        pairs.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect()
    }

    #[test]
    fn counts_are_clamped_and_bad_text_is_zero() {
        let c = light_counts(&env(&[
            ("LIGHTS_POINT", "99"),
            ("LIGHTS_SPOT", "-7"),
            ("LIGHTS_TUBE", "x9"),
            ("LIGHTS_DIRECTIONAL", " 3 "),
        ]));
        assert_eq!(c, LightCounts { point: 15, spot: 0, tube: 0, directional: 3 });
        assert_eq!(light_counts(&env(&[])), LightCounts::default());
        assert_eq!(light_counts(&env(&[("LIGHTS_POINT", "99999999999999999999999")])).point, 15);
        assert_eq!(light_counts(&env(&[("LIGHTS_POINT", "15")])).point, 15);
        assert_eq!(light_counts(&env(&[("LIGHTS_POINT", "16")])).point, 15);
    }

    #[test]
    fn lighting_needs_a_defined_non_zero_or_non_integer_macro() {
        assert!(!lighting_enabled(&env(&[])));
        assert!(!lighting_enabled(&env(&[("LIGHTING", "0")])));
        assert!(!lighting_enabled(&env(&[("LIGHTING", "000")])));
        assert!(lighting_enabled(&env(&[("LIGHTING", "1")])));
        assert!(lighting_enabled(&env(&[("LIGHTING", "2")])));
        assert!(lighting_enabled(&env(&[("LIGHTING", "yes")])));
        assert!(lighting_enabled(&env(&[("LIGHTING", "-1")])));
    }

    #[test]
    fn a_block_without_lights_declares_nothing_and_calls_nothing() {
        let text = lighting_block(LightCounts::default()).join("\n");
        assert!(!text.contains("uniform"));
        assert!(!text.contains("ComputePBR") && !text.contains("PointSegmentDelta"));
        assert!(text.contains("vec3 PerformLighting_V1(vec3 worldPos, vec3 color, vec3 normal, vec3 viewVector, vec3 specularTint, vec3 baseReflectance, float roughness, float metallic)"));
        assert!(text.contains("return light;"));
    }

    #[test]
    fn every_element_of_every_declared_array_is_used() {
        let counts = LightCounts { point: 4, spot: 2, tube: 1, directional: 3 };
        let text = lighting_block(counts).join("\n");
        for (name, n) in [
            ("g_LPoint_Color", 4),
            ("g_LPoint_Origin", 4),
            ("g_LSpot_Color", 2),
            ("g_LSpot_Origin", 2),
            ("g_LSpot_Direction", 2),
            ("g_LSpot_Exponent", 2),
            ("g_LTube_Color", 1),
            ("g_LTube_OriginA", 1),
            ("g_LTube_OriginB", 1),
            ("g_LDirectional_Color", 3),
            ("g_LDirectional_Direction", 3),
        ] {
            assert!(text.contains(&format!("uniform vec4 {name}[{n}];")), "{name}");
            for i in 0..n {
                assert!(text.contains(&format!("{name}[{i}]")), "{name}[{i}]");
            }
            assert!(!text.contains(&format!("{name}[{n}]")) || text.contains(&format!("uniform vec4 {name}[{n}];")));
        }
        assert_eq!(text.matches("ComputePBRLightShadow(").count(), 4 + 2 + 1);
        assert_eq!(text.matches("ComputePBRLightShadowInfinite(").count(), 3);
        assert_eq!(text.matches("PointSegmentDelta(").count(), 1);
        assert_eq!(text.matches("smoothstep(").count(), 2);
        assert_eq!(text.matches(", 1.0);").count(), 10);
    }

    #[test]
    fn types_with_zero_lights_declare_nothing() {
        let text = lighting_block(LightCounts { point: 2, ..LightCounts::default() }).join("\n");
        assert!(text.contains("g_LPoint_Color[2]"));
        for absent in ["g_LSpot", "g_LTube", "g_LDirectional", "smoothstep", "PointSegmentDelta", "Infinite"] {
            assert!(!text.contains(absent), "{absent}");
        }
    }

    #[test]
    fn the_per_type_argument_mapping_follows_the_spec() {
        let text = lighting_block(LightCounts { point: 1, spot: 1, tube: 1, directional: 1 }).join("\n");
        // Point: radius is the colour w, exponent the origin w.
        assert!(text.contains("g_LPoint_Color[0].w, g_LPoint_Origin[0].w"));
        // Spot: colour scaled by the cone, exponent from the Exponent array's x.
        assert!(text.contains("g_LSpot_Color[0].rgb * spotCone, g_LSpot_Color[0].w, g_LSpot_Exponent[0].x"));
        assert!(text.contains("smoothstep(g_LSpot_Direction[0].w, g_LSpot_Origin[0].w, -dot(normalize(lightDelta), g_LSpot_Direction[0].xyz))"));
        // Tube: exponent from the first end point's w.
        assert!(text.contains("g_LTube_Color[0].w, g_LTube_OriginA[0].w"));
        assert!(text.contains("PointSegmentDelta(worldPos, g_LTube_OriginA[0].xyz, g_LTube_OriginB[0].xyz)"));
        // Directional: no radius or exponent.
        assert!(text.contains("ComputePBRLightShadowInfinite(normal, g_LDirectional_Direction[0].xyz, viewVector, color, g_LDirectional_Color[0].rgb, specularTint"));
    }
}
