// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! Helper functions the converter adds to a stage (R18, R86, R91).
//!
//! Helpers are emitted only when the stage uses them, once each, ahead of the first
//! function. Their names carry a prefix no identifier of the stage starts with (R92).

use std::collections::BTreeSet;

use crate::lexer::lex;

use super::super::ast::Item;
use super::super::ty::{Sc, Ty};
use super::super::expand::expand;
use super::super::parse::parse;

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub(in crate::dialect) enum HelperKind {
    /// Discards the fragment when a component is negative; the width of the argument.
    Clip(u8),
    /// Columns (zero for scalar/vector), rows, and output component kind.
    Modf(u8, u8, Sc),
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
        HelperKind::Modf(columns, rows, kind) => {
            let ty = if columns == 0 { Ty::vec(rows).glsl_name() } else { Ty::Mat(columns, rows).glsl_name() };
            let ty = if columns == 0 && rows == 1 { "float".to_string() } else { ty.expect("modf value type") };
            let output = if columns == 0 { Ty::of(kind, rows).glsl_name().expect("modf output type") } else { ty.clone() };
            let whole = if columns == 0 { "trunc(x)".to_string() } else {
                format!("{ty}({})", (0..columns).map(|i| format!("trunc(x[{i}])")).collect::<Vec<_>>().join(", "))
            };
            format!("{ty} {p}modf_{columns}_{rows}_{}({ty} x, out {output} integral) {{ {ty} whole = {whole}; integral = {output}(whole); return x - whole; }}\n", kind.name())
        }
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
        h.need(HelperKind::Lighting);
        let items = h.items("_wm_");
        assert_eq!(items.len(), 4 + 2);
    }

    #[test]
    fn nothing_is_emitted_when_nothing_is_used() {
        assert!(Helpers::default().items("_wm_").is_empty());
    }
}
