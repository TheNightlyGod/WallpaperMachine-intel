// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! The generated `LightingV1` block (R32 to R34).
//!
//! A lit stock shader says `#require LightingV1` where Wallpaper Engine would
//! generate the light uniforms and a `PerformLighting_V1` function. The text is
//! ordinary dialect source, written with constant indices so that every array
//! element is visibly used at the array's full size (reflection and the
//! uniform block layout depend on that). With `LIGHTS_SHADOW_MAPPING` a light
//! in a shadow partition (below) is shadowed the way Wallpaper Engine's writer
//! (`sub_140169140`) writes it: the stock `CalculateProjectedCoords*` and
//! `PerformShadowMapping` helpers over the `g_LFeature_*` arrays. Cookie spots
//! project through those same matrices even without a shadow atlas and sample
//! the scene cookie. Their sampled colour replaces the ordinary cone factor.

use std::collections::HashMap;

/// Most lights of one type.
pub const MAX_LIGHTS: usize = 15;

/// Counts of point, spot, tube and directional lights, and how many of a kind's
/// lights fall in each of its shadow and cookie subsets.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct LightCounts {
    pub point: usize,
    pub spot: usize,
    pub tube: usize,
    pub directional: usize,
    pub point_shadow: usize,
    pub spot_shadow: usize,
    pub spot_cookie: usize,
    pub spot_shadow_cookie: usize,
    pub directional_shadow: usize,
    /// `LIGHTS_SHADOW_MAPPING`: the shadow atlas is drawn and sampled.
    pub shadow_mapping: bool,
}

/// What a light's slot of its kind's array is for. Wallpaper Engine's
/// `PerformLighting_V1` writer (`sub_140169140`) gives each kind's subsets the
/// front of its array: spot `[shadow cookie][cookie][shadow][plain]`, point and
/// directional `[shadow][plain]`; the light packer (0x140190C80) fills the slots
/// the same way.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Partition {
    Plain,
    Shadow,
    Cookie,
    ShadowCookie,
}

impl LightCounts {
    /// The partition of point light `i`.
    pub fn point_partition(&self, i: usize) -> Partition {
        if i < self.point_shadow { Partition::Shadow } else { Partition::Plain }
    }

    /// The partition of spot light `i`.
    pub fn spot_partition(&self, i: usize) -> Partition {
        let cookie = self.spot_shadow_cookie + self.spot_cookie;
        if i < self.spot_shadow_cookie {
            Partition::ShadowCookie
        } else if i < cookie {
            Partition::Cookie
        } else if i < cookie + self.spot_shadow {
            Partition::Shadow
        } else {
            Partition::Plain
        }
    }

    /// The partition of directional light `i`.
    pub fn directional_partition(&self, i: usize) -> Partition {
        if i < self.directional_shadow { Partition::Shadow } else { Partition::Plain }
    }
}

/// Whether a light of `partition` samples the shadow atlas.
fn shadowed(counts: &LightCounts, partition: Partition) -> bool {
    counts.shadow_mapping && matches!(partition, Partition::Shadow | Partition::ShadowCookie)
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

/// A subset count: the macro's count, at most 3 (Wallpaper Engine keeps two bits).
fn subset_of(env: &HashMap<String, String>, name: &str) -> usize {
    count_of(env, name).min(3)
}

pub fn light_counts(env: &HashMap<String, String>) -> LightCounts {
    LightCounts {
        point: count_of(env, "LIGHTS_POINT"),
        spot: count_of(env, "LIGHTS_SPOT"),
        tube: count_of(env, "LIGHTS_TUBE"),
        directional: count_of(env, "LIGHTS_DIRECTIONAL"),
        point_shadow: subset_of(env, "LIGHTS_POINT_SHADOW"),
        spot_shadow: subset_of(env, "LIGHTS_SPOT_SHADOW"),
        spot_cookie: subset_of(env, "LIGHTS_SPOT_COOKIE"),
        spot_shadow_cookie: subset_of(env, "LIGHTS_SPOT_SHADOW_COOKIE"),
        directional_shadow: subset_of(env, "LIGHTS_DIRECTIONAL_SHADOW"),
        shadow_mapping: count_of(env, "LIGHTS_SHADOW_MAPPING") != 0,
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
    // The feature arrays (`sub_140169140`): one projection and atlas transform per spot of a
    // shadow or cookie subset, three per shadowed directional light; the point projection and
    // transform per shadowed point light.
    let spot_features = counts.spot_shadow_cookie + counts.spot_cookie + counts.spot_shadow;
    let features = spot_features + 3 * counts.directional_shadow;
    if features > 0 && (counts.shadow_mapping || counts.spot_cookie + counts.spot_shadow_cookie > 0) {
        out.push(format!("uniform mat4 g_LFeature_ShadowProjection[{features}];"));
        out.push(format!("uniform vec4 g_LFeature_ShadowProjectionTransform[{features}];"));
    }
    if counts.shadow_mapping && counts.point_shadow > 0 {
        out.push(format!("uniform vec4 g_LFeature_ShadowPointProjection[{}];", counts.point_shadow));
        out.push(format!("uniform vec4 g_LFeature_ShadowPointProjectionTransform[{}];", counts.point_shadow));
    }
    out.push(
        "vec3 PerformLighting_V1(vec3 worldPos, vec3 color, vec3 normal, vec3 viewVector, vec3 specularTint, vec3 baseReflectance, float roughness, float metallic)"
            .to_string(),
    );
    out.push("{".to_string());
    out.push("\tvec3 light = vec3(0.0, 0.0, 0.0);".to_string());
    let common = "viewVector, color";
    let tail = |shadow: &str| format!("specularTint, baseReflectance, roughness, metallic, {shadow}");
    for i in 0..counts.point {
        if shadowed(&counts, counts.point_partition(i)) {
            out.push("\t{".to_string());
            out.push(format!("\t\tvec3 lightDelta = g_LPoint_Origin[{i}].xyz - worldPos;"));
            out.push(format!(
                "\t\tvec4 projectedCoords = CalculateProjectedCoordsPoint(worldPos, g_LPoint_Origin[{i}].xyz, g_LFeature_ShadowPointProjection[{i}], g_LFeature_ShadowPointProjectionTransform[{i}]);"
            ));
            out.push("\t\tfloat shadowFactor = PerformPointShadowMapping(projectedCoords);".to_string());
            out.push(format!(
                "\t\tlight += ComputePBRLightShadow(normal, lightDelta, {common}, g_LPoint_Color[{i}].rgb, g_LPoint_Color[{i}].w, g_LPoint_Origin[{i}].w, {});",
                tail("shadowFactor")
            ));
            out.push("\t}".to_string());
            continue;
        }
        out.push(format!(
            "\tlight += ComputePBRLightShadow(normal, g_LPoint_Origin[{i}].xyz - worldPos, {common}, g_LPoint_Color[{i}].rgb, g_LPoint_Color[{i}].w, g_LPoint_Origin[{i}].w, {});",
            tail("1.0")
        ));
    }
    for i in 0..counts.spot {
        let partition = counts.spot_partition(i);
        let shadow = shadowed(&counts, partition);
        let cookie = matches!(partition, Partition::Cookie | Partition::ShadowCookie);
        out.push("\t{".to_string());
        out.push(format!("\t\tvec3 lightDelta = g_LSpot_Origin[{i}].xyz - worldPos;"));
        if !cookie {
            out.push(format!(
                "\t\tfloat spotCone = smoothstep(g_LSpot_Direction[{i}].w, g_LSpot_Origin[{i}].w, -dot(normalize(lightDelta), g_LSpot_Direction[{i}].xyz));"
            ));
        }
        if shadow || cookie {
            out.push(format!(
                "\t\tvec3 projectedCoords = CalculateProjectedCoords(worldPos, g_LFeature_ShadowProjection[{i}]);"
            ));
        }
        if shadow {
            out.push(format!(
                "\t\tfloat shadowFactor = PerformShadowMapping(projectedCoords, g_LFeature_ShadowProjectionTransform[{i}]);"
            ));
        }
        if cookie {
            out.push("\t\tvec3 colorCookie = texSample2D(COOKIE_SAMPLER, projectedCoords.xy).rgb;".to_string());
        }
        let factor = if cookie { "colorCookie" } else { "spotCone" };
        out.push(format!(
            "\t\tlight += ComputePBRLightShadow(normal, lightDelta, {common}, g_LSpot_Color[{i}].rgb * {factor}, g_LSpot_Color[{i}].w, g_LSpot_Exponent[{i}].x, {});",
            tail(if shadow { "shadowFactor" } else { "1.0" })
        ));
        out.push("\t}".to_string());
    }
    let plain = tail("1.0");
    for i in 0..counts.tube {
        out.push("\t{".to_string());
        out.push(format!(
            "\t\tvec3 lightDelta = PointSegmentDelta(worldPos, g_LTube_OriginA[{i}].xyz, g_LTube_OriginB[{i}].xyz);"
        ));
        out.push(format!(
            "\t\tlight += ComputePBRLightShadow(normal, lightDelta, {common}, g_LTube_Color[{i}].rgb, g_LTube_Color[{i}].w, g_LTube_OriginA[{i}].w, {plain});"
        ));
        out.push("\t}".to_string());
    }
    for i in 0..counts.directional {
        if shadowed(&counts, counts.directional_partition(i)) {
            // Wallpaper Engine steps the first cascade by one per light (`++m`), not three,
            // although its packer writes three per light: copied as it is.
            let p1 = spot_features + i;
            let (p2, p3) = (p1 + 1, p1 + 2);
            out.push("\t{".to_string());
            out.push(format!("\t\tvec4 projectedCoords1 = CalculateProjectedCoordsCascades(worldPos, g_LFeature_ShadowProjection[{p1}]);"));
            out.push(format!("\t\tvec4 projectedCoords2 = CalculateProjectedCoordsCascades(worldPos, g_LFeature_ShadowProjection[{p2}]);"));
            out.push(format!("\t\tvec4 projectedCoords3 = CalculateProjectedCoordsCascades(worldPos, g_LFeature_ShadowProjection[{p3}]);"));
            out.push("\t\tprojectedCoords1.xyz = mix(projectedCoords1.xyz, projectedCoords2.xyz, projectedCoords1.w);".to_string());
            out.push("\t\tprojectedCoords1.xyz = mix(projectedCoords1.xyz, projectedCoords3.xyz, projectedCoords2.w);".to_string());
            out.push(format!("\t\tvec4 uvTransforms = mix(g_LFeature_ShadowProjectionTransform[{p1}], g_LFeature_ShadowProjectionTransform[{p2}], projectedCoords1.w);"));
            out.push(format!("\t\tuvTransforms = mix(uvTransforms, g_LFeature_ShadowProjectionTransform[{p3}], projectedCoords2.w);"));
            out.push("\t\tfloat shadowFactor = max(projectedCoords3.w, PerformShadowMapping(projectedCoords1.xyz, uvTransforms));".to_string());
            out.push(format!(
                "\t\tlight += ComputePBRLightShadowInfinite(normal, g_LDirectional_Direction[{i}].xyz, {common}, g_LDirectional_Color[{i}].rgb, specularTint, baseReflectance, roughness, metallic, shadowFactor);"
            ));
            out.push("\t}".to_string());
            continue;
        }
        out.push(format!(
            "\tlight += ComputePBRLightShadowInfinite(normal, g_LDirectional_Direction[{i}].xyz, {common}, g_LDirectional_Color[{i}].rgb, specularTint, baseReflectance, roughness, metallic, 1.0);"
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
        assert_eq!(c, LightCounts { point: 15, spot: 0, tube: 0, directional: 3, ..LightCounts::default() });
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
        let counts = LightCounts { point: 4, spot: 2, tube: 1, directional: 3, ..LightCounts::default() };
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
        let text = lighting_block(LightCounts { point: 1, spot: 1, tube: 1, directional: 1, ..LightCounts::default() })
            .join("\n");
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

    #[test]
    fn spot_partitions_follow_the_subset_counts() {
        let counts = light_counts(&env(&[
            ("LIGHTS_SPOT", "4"),
            ("LIGHTS_SPOT_SHADOW", "1"),
            ("LIGHTS_SPOT_COOKIE", "1"),
            ("LIGHTS_POINT", "2"),
            ("LIGHTS_POINT_SHADOW", "9"),
            ("LIGHTS_DIRECTIONAL", "1"),
            ("LIGHTS_DIRECTIONAL_SHADOW", "1"),
        ]));
        assert_eq!((counts.spot_shadow, counts.spot_cookie, counts.spot_shadow_cookie), (1, 1, 0));
        assert_eq!(counts.point_shadow, 3, "a subset keeps two bits");
        // Wallpaper Engine's order: [shadow cookie][cookie][shadow][plain].
        let spots: Vec<_> = (0..4).map(|i| counts.spot_partition(i)).collect();
        assert_eq!(spots, [Partition::Cookie, Partition::Shadow, Partition::Plain, Partition::Plain]);
        let both = LightCounts { spot: 3, spot_shadow_cookie: 1, spot_cookie: 1, spot_shadow: 1, ..LightCounts::default() };
        let spots: Vec<_> = (0..3).map(|i| both.spot_partition(i)).collect();
        assert_eq!(spots, [Partition::ShadowCookie, Partition::Cookie, Partition::Shadow]);
        assert_eq!(counts.point_partition(0), Partition::Shadow);
        assert_eq!(counts.directional_partition(0), Partition::Shadow);
        assert_eq!(LightCounts { directional: 1, ..LightCounts::default() }.directional_partition(0), Partition::Plain);
        let text = lighting_block(counts).join("\n");
        assert_eq!(text.matches("texSample2D(COOKIE_SAMPLER").count(), 1);
        assert!(!text.contains("PerformShadowMapping("));
    }

    #[test]
    fn shadow_partitions_sample_the_atlas_with_wallpaper_engines_text() {
        let counts = light_counts(&env(&[
            ("LIGHTS_POINT", "2"),
            ("LIGHTS_POINT_SHADOW", "1"),
            ("LIGHTS_SPOT", "3"),
            ("LIGHTS_SPOT_SHADOW_COOKIE", "1"),
            ("LIGHTS_SPOT_SHADOW", "1"),
            ("LIGHTS_DIRECTIONAL", "1"),
            ("LIGHTS_DIRECTIONAL_SHADOW", "1"),
            ("LIGHTS_SHADOW_MAPPING", "1"),
        ]));
        assert!(counts.shadow_mapping);
        let text = lighting_block(counts).join("\n");
        // Two spot features (shadow cookie, shadow) and three cascades.
        assert!(text.contains("uniform mat4 g_LFeature_ShadowProjection[5];"), "{text}");
        assert!(text.contains("uniform vec4 g_LFeature_ShadowProjectionTransform[5];"));
        assert!(text.contains("uniform vec4 g_LFeature_ShadowPointProjection[1];"));
        assert!(text.contains("uniform vec4 g_LFeature_ShadowPointProjectionTransform[1];"));
        // Point 0 is shadowed, point 1 is not.
        assert!(text.contains("vec4 projectedCoords = CalculateProjectedCoordsPoint(worldPos, g_LPoint_Origin[0].xyz, g_LFeature_ShadowPointProjection[0], g_LFeature_ShadowPointProjectionTransform[0]);"));
        assert!(!text.contains("g_LPoint_Origin[1].xyz, g_LFeature"));
        assert_eq!(text.matches("PerformPointShadowMapping(projectedCoords)").count(), 1);
        // Spots 0 (shadow cookie) and 1 (shadow) are shadowed through their own feature slot.
        for i in 0..2 {
            assert!(text.contains(&format!("CalculateProjectedCoords(worldPos, g_LFeature_ShadowProjection[{i}]);")));
            assert!(text.contains(&format!("PerformShadowMapping(projectedCoords, g_LFeature_ShadowProjectionTransform[{i}]);")));
        }
        // The directional light reads its cascades after the spot features.
        assert!(text.contains("CalculateProjectedCoordsCascades(worldPos, g_LFeature_ShadowProjection[2]);"));
        assert!(text.contains("CalculateProjectedCoordsCascades(worldPos, g_LFeature_ShadowProjection[4]);"));
        assert!(text.contains("float shadowFactor = max(projectedCoords3.w, PerformShadowMapping(projectedCoords1.xyz, uvTransforms));"));
        assert_eq!(text.matches(", shadowFactor);").count(), 4);
        // Without the atlas the same subsets are written lit.
        let unshadowed = LightCounts { shadow_mapping: false, ..counts };
        let text = lighting_block(unshadowed).join("\n");
        assert!(!text.contains("PerformShadowMapping("));
        assert!(text.contains("g_LFeature_ShadowProjection[0]"));
        assert_eq!(text.matches("texSample2D(COOKIE_SAMPLER").count(), 1);
    }
    #[test]
    fn cookie_spots_project_without_shadows_and_replace_the_cone() {
        let counts = light_counts(&env(&[("LIGHTS_SPOT", "3"),
            ("LIGHTS_SPOT_COOKIE", "1"), ("LIGHTS_SPOT_SHADOW_COOKIE", "1"),
            ("LIGHTS_COOKIE", "1")]));
        let text = lighting_block(counts).join("\n");
        assert!(text.contains("uniform mat4 g_LFeature_ShadowProjection[2];"), "{text}");
        assert_eq!(text.matches("texSample2D(COOKIE_SAMPLER, projectedCoords.xy).rgb").count(), 2, "{text}");
        assert_eq!(text.matches("* colorCookie").count(), 2);
        assert_eq!(text.matches("* spotCone").count(), 1, "only the plain spot keeps its cone");
        assert!(!text.contains("PerformShadowMapping("));
    }

}
