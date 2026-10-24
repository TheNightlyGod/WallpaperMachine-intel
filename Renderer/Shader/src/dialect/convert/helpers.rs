// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! Helper functions the converter adds to a stage (R18, R86, R87, R91).
//!
//! Helpers are emitted only when the stage uses them, once each, ahead of the first
//! function. Their names carry a prefix no identifier of the stage starts with (R92).

use std::collections::BTreeSet;

use crate::lexer::lex;

use super::super::ast::Item;
use super::super::expand::expand;
use super::super::parse::parse;

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub(in crate::dialect) enum HelperKind {
    /// Discards the fragment when a component is negative; the width of the argument.
    Clip(u8),
    /// The exact inverse of a square matrix; its size.
    Inverse(u8),
    /// The stand-in lighting function with 8 and 9 parameters.
    Lighting,
}

#[derive(Default)]
pub(in crate::dialect) struct Helpers {
    used: BTreeSet<HelperKind>,
}

impl Helpers {
    pub fn need(&mut self, kind: HelperKind) {
        self.used.insert(kind);
    }

    /// The helper functions as items, in a fixed order.
    pub fn items(&self, prefix: &str) -> Vec<Item> {
        let mut text = String::new();
        for kind in &self.used {
            text.push_str(&source(*kind, prefix));
        }
        if text.is_empty() {
            return Vec::new();
        }
        let tokens = expand(&lex(&text)).expect("helper text has no macros");
        parse(&tokens).expect("helper text parses").items
    }
}

fn vec_name(width: u8) -> String {
    if width == 1 { "float".to_string() } else { format!("vec{width}") }
}

fn source(kind: HelperKind, p: &str) -> String {
    match kind {
        HelperKind::Clip(1) => format!("void {p}clip(float v) {{ if (v < 0.0) {{ discard; }} }}\n"),
        HelperKind::Clip(w) => {
            let t = vec_name(w);
            format!("void {p}clip({t} v) {{ if (any(lessThan(v, {t}(0.0)))) {{ discard; }} }}\n")
        }
        HelperKind::Inverse(2) => format!(
            "mat2 {p}inverse(mat2 m) {{\n  float det = m[0][0] * m[1][1] - m[0][1] * m[1][0];\n  return mat2(m[1][1], -m[0][1], -m[1][0], m[0][0]) / det;\n}}\n"
        ),
        HelperKind::Inverse(3) => format!(
            "mat3 {p}inverse(mat3 m) {{\n\
             \x20 float a00 = m[0][0], a01 = m[0][1], a02 = m[0][2];\n\
             \x20 float a10 = m[1][0], a11 = m[1][1], a12 = m[1][2];\n\
             \x20 float a20 = m[2][0], a21 = m[2][1], a22 = m[2][2];\n\
             \x20 float b01 = a22 * a11 - a12 * a21;\n\
             \x20 float b11 = -a22 * a10 + a12 * a20;\n\
             \x20 float b21 = a21 * a10 - a11 * a20;\n\
             \x20 float det = a00 * b01 + a01 * b11 + a02 * b21;\n\
             \x20 return mat3(b01, -a22 * a01 + a02 * a21, a12 * a01 - a02 * a11,\n\
             \x20             b11, a22 * a00 - a02 * a20, -a12 * a00 + a02 * a10,\n\
             \x20             b21, -a21 * a00 + a01 * a20, a11 * a00 - a01 * a10) / det;\n\
             }}\n"
        ),
        HelperKind::Inverse(_) => format!(
            "mat4 {p}inverse(mat4 m) {{\n\
             \x20 float a00 = m[0][0], a01 = m[0][1], a02 = m[0][2], a03 = m[0][3];\n\
             \x20 float a10 = m[1][0], a11 = m[1][1], a12 = m[1][2], a13 = m[1][3];\n\
             \x20 float a20 = m[2][0], a21 = m[2][1], a22 = m[2][2], a23 = m[2][3];\n\
             \x20 float a30 = m[3][0], a31 = m[3][1], a32 = m[3][2], a33 = m[3][3];\n\
             \x20 float b00 = a00 * a11 - a01 * a10;\n\
             \x20 float b01 = a00 * a12 - a02 * a10;\n\
             \x20 float b02 = a00 * a13 - a03 * a10;\n\
             \x20 float b03 = a01 * a12 - a02 * a11;\n\
             \x20 float b04 = a01 * a13 - a03 * a11;\n\
             \x20 float b05 = a02 * a13 - a03 * a12;\n\
             \x20 float b06 = a20 * a31 - a21 * a30;\n\
             \x20 float b07 = a20 * a32 - a22 * a30;\n\
             \x20 float b08 = a20 * a33 - a23 * a30;\n\
             \x20 float b09 = a21 * a32 - a22 * a31;\n\
             \x20 float b10 = a21 * a33 - a23 * a31;\n\
             \x20 float b11 = a22 * a33 - a23 * a32;\n\
             \x20 float det = b00 * b11 - b01 * b10 + b02 * b09 + b03 * b08 - b04 * b07 + b05 * b06;\n\
             \x20 return mat4(\n\
             \x20   a11 * b11 - a12 * b10 + a13 * b09,\n\
             \x20   a02 * b10 - a01 * b11 - a03 * b09,\n\
             \x20   a31 * b05 - a32 * b04 + a33 * b03,\n\
             \x20   a22 * b04 - a21 * b05 - a23 * b03,\n\
             \x20   a12 * b08 - a10 * b11 - a13 * b07,\n\
             \x20   a00 * b11 - a02 * b08 + a03 * b07,\n\
             \x20   a32 * b02 - a30 * b05 - a33 * b01,\n\
             \x20   a20 * b05 - a22 * b02 + a23 * b01,\n\
             \x20   a10 * b10 - a11 * b08 + a13 * b06,\n\
             \x20   a01 * b08 - a00 * b10 - a03 * b06,\n\
             \x20   a30 * b04 - a31 * b02 + a33 * b00,\n\
             \x20   a21 * b02 - a20 * b04 - a23 * b00,\n\
             \x20   a11 * b07 - a10 * b09 - a12 * b06,\n\
             \x20   a00 * b09 - a01 * b07 + a02 * b06,\n\
             \x20   a31 * b01 - a30 * b03 - a32 * b00,\n\
             \x20   a20 * b03 - a21 * b01 + a22 * b00) / det;\n\
             }}\n"
        ),
        HelperKind::Lighting => "\
vec3 PerformLighting_V1(vec3 worldPos, vec3 albedo, vec3 normal, vec3 viewVector, vec3 specularTint, vec3 ambientF0, float roughness, float metallic) {
  return albedo * clamp(dot(normalize(normal), normalize(viewVector)), 0.0, 1.0);
}
vec3 PerformLighting_V1(vec3 worldPos, vec3 albedo, vec3 normal, vec3 viewVector, vec3 specularTint, vec3 ambientF0, float roughness, float metallic, float ao) {
  return albedo * clamp(dot(normalize(normal), normalize(viewVector)), 0.0, 1.0) * ao;
}
"
        .to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_helper_parses() {
        let mut h = Helpers::default();
        for w in 1..=4 {
            h.need(HelperKind::Clip(w));
        }
        for n in 2..=4 {
            h.need(HelperKind::Inverse(n));
        }
        h.need(HelperKind::Lighting);
        let items = h.items("_wm_");
        assert_eq!(items.len(), 4 + 3 + 2);
    }

    #[test]
    fn nothing_is_emitted_when_nothing_is_used() {
        assert!(Helpers::default().items("_wm_").is_empty());
    }
}
