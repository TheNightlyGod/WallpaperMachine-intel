//! Wallpaper Engine's generated `#require LightingV1` block.
//!
//! A shader that lights itself (`genericimage4`, `generic4`, the particle and
//! fluid shaders) declares no light uniforms and no `PerformLighting_V1`; it
//! asks for them with `#require LightingV1` and Wallpaper Engine writes both in
//! at that line, sized by the scene's light counts. The counts arrive as the
//! `LIGHTS_*` combos and the block is written only when the pass's `LIGHTING`
//! combo is on. Each light is one unrolled block, so the arrays are indexed by
//! constants and every light type reads its own uniform arrays:
//!
//! - point: `g_LPoint_Color` (colour x intensity, radius) and `g_LPoint_Origin`
//!   (world position, exponent);
//! - spot: `g_LSpot_Color`, `g_LSpot_Origin` (`w` = cos inner cone),
//!   `g_LSpot_Direction` (`w` = cos outer cone) and `g_LSpot_Exponent`;
//! - tube: `g_LTube_Color`, `g_LTube_OriginA` (`w` = exponent) and
//!   `g_LTube_OriginB`;
//! - directional: `g_LDirectional_Color` and `g_LDirectional_Direction`.
//!
//! The radiance itself is the author's `ComputePBRLightShadow` and
//! `ComputePBRLightShadowInfinite` from Wallpaper Engine's `common_pbr_2.h`,
//! which the requiring shader includes.
//!
//! Shadow maps and spot cookies are not drawn: a shadow-casting or cookie light
//! is lit like the plain light of its type with a shadow factor of one, which
//! is what Wallpaper Engine draws with its shadow setting off or with nothing
//! in the scene casting a shadow.

use std::fmt::Write as _;

use super::MacroTable;

/// The `#require` name this block answers.
pub(super) const LIGHTING_V1: &str = "LightingV1";

/// Largest count Wallpaper Engine packs for one light type (four bits).
const MAX_LIGHTS_PER_TYPE: u32 = 15;

/// Light counts the scene's `lightconfig` hands every lit pass.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
struct LightCounts {
    point: u32,
    spot: u32,
    tube: u32,
    directional: u32,
}

impl LightCounts {
    /// Reads the counts from the macros visible at the `#require` line.
    fn from_macros(macros: &MacroTable) -> Self {
        Self {
            point: macro_count(macros, "LIGHTS_POINT"),
            spot: macro_count(macros, "LIGHTS_SPOT"),
            tube: macro_count(macros, "LIGHTS_TUBE"),
            directional: macro_count(macros, "LIGHTS_DIRECTIONAL"),
        }
    }
}

/// A macro's integer value, zero when it is undefined or not a number.
fn macro_count(macros: &MacroTable, name: &str) -> u32 {
    macros
        .value(name)
        .and_then(|value| value.trim().parse::<i64>().ok())
        .map_or(0, |value| {
            u32::try_from(value.clamp(0, i64::from(MAX_LIGHTS_PER_TYPE))).unwrap_or(0)
        })
}

/// Whether the pass lights itself: `LIGHTING` set to anything but zero.
fn lighting_enabled(macros: &MacroTable) -> bool {
    macros
        .value("LIGHTING")
        .is_some_and(|value| value.trim().parse::<i64>().map_or(true, |value| value != 0))
}

/// The block `#require LightingV1` stands for, or `None` when the pass does
/// not light itself and nothing is written.
pub(super) fn lighting_v1_source(macros: &MacroTable) -> Option<String> {
    if !lighting_enabled(macros) {
        return None;
    }
    let counts = LightCounts::from_macros(macros);
    let mut source = String::new();
    write_lighting_v1(&mut source, counts).ok()?;
    Some(source)
}

/// Writes the uniform arrays and the unrolled `PerformLighting_V1`.
fn write_lighting_v1(out: &mut String, counts: LightCounts) -> std::fmt::Result {
    for (count, names) in [
        (counts.point, &["g_LPoint_Color", "g_LPoint_Origin"][..]),
        (
            counts.spot,
            &[
                "g_LSpot_Color",
                "g_LSpot_Origin",
                "g_LSpot_Direction",
                "g_LSpot_Exponent",
            ][..],
        ),
        (
            counts.tube,
            &["g_LTube_Color", "g_LTube_OriginA", "g_LTube_OriginB"][..],
        ),
        (
            counts.directional,
            &["g_LDirectional_Color", "g_LDirectional_Direction"][..],
        ),
    ] {
        if count == 0 {
            continue;
        }
        for name in names {
            writeln!(out, "uniform vec4 {name}[{count}];")?;
        }
    }

    writeln!(
        out,
        "vec3 PerformLighting_V1(vec3 worldPos, vec3 color, vec3 normal, vec3 viewVector, \
         vec3 specularTint, vec3 ambient, float roughness, float metallic)\n{{\n\tvec3 light = \
         CAST3(0.0);"
    )?;
    for index in 0..counts.point {
        writeln!(
            out,
            "\t{{\n\tconst uint i = {index}u;\n\
             \tvec3 lightDelta = g_LPoint_Origin[i].xyz - worldPos;\n\
             \tlight += ComputePBRLightShadow(normal, lightDelta, viewVector, color, \
             g_LPoint_Color[i].rgb, g_LPoint_Color[i].w, g_LPoint_Origin[i].w, specularTint, \
             ambient, roughness, metallic, 1.0);\n\t}}"
        )?;
    }
    for index in 0..counts.spot {
        writeln!(
            out,
            "\t{{\n\tconst uint i = {index}u;\n\
             \tvec3 lightDelta = g_LSpot_Origin[i].xyz - worldPos;\n\
             \tfloat spotCookie = -dot(normalize(lightDelta), g_LSpot_Direction[i].xyz);\n\
             \tspotCookie = smoothstep(g_LSpot_Direction[i].w, g_LSpot_Origin[i].w, spotCookie);\n\
             \tlight += ComputePBRLightShadow(normal, lightDelta, viewVector, color, \
             g_LSpot_Color[i].rgb * spotCookie, g_LSpot_Color[i].w, g_LSpot_Exponent[i].x, \
             specularTint, ambient, roughness, metallic, 1.0);\n\t}}"
        )?;
    }
    for index in 0..counts.tube {
        writeln!(
            out,
            "\t{{\n\tconst uint i = {index}u;\n\
             \tvec3 lightDelta = PointSegmentDelta(worldPos, g_LTube_OriginA[i].xyz, \
             g_LTube_OriginB[i].xyz);\n\
             \tlight += ComputePBRLightShadow(normal, lightDelta, viewVector, color, \
             g_LTube_Color[i].rgb, g_LTube_Color[i].w, g_LTube_OriginA[i].w, specularTint, \
             ambient, roughness, metallic, 1.0);\n\t}}"
        )?;
    }
    for index in 0..counts.directional {
        writeln!(
            out,
            "\t{{\n\tconst uint i = {index}u;\n\
             \tlight += ComputePBRLightShadowInfinite(normal, g_LDirectional_Direction[i].xyz, \
             viewVector, color, g_LDirectional_Color[i].rgb, specularTint, ambient, roughness, \
             metallic, 1.0);\n\t}}"
        )?;
    }
    writeln!(out, "\treturn light;\n}}")
}

#[cfg(test)]
mod tests {
    use super::{MacroTable, lighting_v1_source};

    fn macros(values: &[(&str, &str)]) -> MacroTable {
        let mut table = MacroTable::new();
        for (name, value) in values {
            table.define(name, value);
        }
        table
    }

    #[test]
    fn nothing_is_written_unless_the_pass_lights_itself() {
        assert_eq!(lighting_v1_source(&macros(&[("LIGHTS_POINT", "2")])), None);
        assert_eq!(
            lighting_v1_source(&macros(&[("LIGHTING", "0"), ("LIGHTS_POINT", "2")])),
            None
        );
    }

    #[test]
    fn a_lit_pass_without_lights_still_gets_a_function_that_adds_nothing() {
        let source = lighting_v1_source(&macros(&[("LIGHTING", "1")])).unwrap();
        assert!(!source.contains("uniform"), "{source}");
        assert!(source.contains("vec3 PerformLighting_V1("), "{source}");
        assert!(!source.contains("ComputePBR"), "{source}");
        assert!(source.contains("return light;"), "{source}");
    }

    #[test]
    fn each_light_type_reads_its_own_arrays_sized_by_its_count() {
        let source = lighting_v1_source(&macros(&[
            ("LIGHTING", "1"),
            ("LIGHTS_POINT", "2"),
            ("LIGHTS_SPOT", "1"),
            ("LIGHTS_TUBE", "3"),
            ("LIGHTS_DIRECTIONAL", "1"),
        ]))
        .unwrap();
        for declaration in [
            "uniform vec4 g_LPoint_Color[2];",
            "uniform vec4 g_LPoint_Origin[2];",
            "uniform vec4 g_LSpot_Exponent[1];",
            "uniform vec4 g_LTube_OriginB[3];",
            "uniform vec4 g_LDirectional_Direction[1];",
        ] {
            assert!(source.contains(declaration), "missing {declaration}:\n{source}");
        }
        assert_eq!(source.matches("g_LPoint_Origin[i].xyz - worldPos").count(), 2);
        assert_eq!(source.matches("PointSegmentDelta(").count(), 3);
        assert_eq!(source.matches("ComputePBRLightShadowInfinite(").count(), 1);
        assert_eq!(source.matches("smoothstep(g_LSpot_Direction[i].w").count(), 1);
        assert!(source.contains("const uint i = 2u;"), "{source}");
    }

    #[test]
    fn counts_outside_wallpaper_engines_range_are_clamped() {
        let source = lighting_v1_source(&macros(&[
            ("LIGHTING", "1"),
            ("LIGHTS_POINT", "40"),
            ("LIGHTS_TUBE", "-2"),
            ("LIGHTS_SPOT", "two"),
        ]))
        .unwrap();
        assert!(source.contains("uniform vec4 g_LPoint_Color[15];"), "{source}");
        assert!(!source.contains("g_LTube"), "{source}");
        assert!(!source.contains("g_LSpot"), "{source}");
    }
}
