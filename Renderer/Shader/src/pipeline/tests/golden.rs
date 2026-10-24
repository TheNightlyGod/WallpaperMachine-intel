// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! The golden Metal text next to the identity string (a-contract R88, amendment R77): the Metal text
//! of a few fixed programs is digested and recorded per compiler identity. A change of translation
//! output without a new identity fails here, and so does a revision number that is reused or reset.

use super::support::*;
use crate::identity::{PIPELINE_REVISION, compiler_identity};
use crate::sha256::{Sha256, to_hex};

/// Each row is `(identity, digest of the Metal text of the fixed programs)` as shipped. Rows are only
/// ever appended, in the order of release, and the revision in front of the colon only ever grows: a
/// revision is an opaque counter, compared for equality, and one that is reset or reused is a defect.
const SHIPPED: &[(&str, &str)] = &[
    ("1:naga-29.0.3-msl2.0-untransformed", "81d5f272f54deb9007775fa53bda918b9a6656b2773cc935d54c91a992d1c453"),
    ("2:naga-29.0.3-msl2.0-untransformed", "81d5f272f54deb9007775fa53bda918b9a6656b2773cc935d54c91a992d1c453"),
];

fn programs() -> Vec<crate::pipeline::CompiledProgram> {
    let textured = "varying vec2 v_Coord;\nuniform sampler2D g_Texture0; uniform float g_Alpha;\nvoid main() { gl_FragColor = texSample2D(g_Texture0, v_Coord) * g_Alpha; }";
    let vertex = "attribute vec3 a_Position; attribute vec2 a_Coord; varying vec2 v_Coord; uniform mat4 g_ModelViewProjectionMatrix;\nvoid main() { gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix); v_Coord = a_Coord; }";
    let haze_v = vertex_with("varying vec4 v_Haze;", "  v_Haze = vec4(a_Coord, 0.5, 1.0);");
    let haze_f = fragment_with("varying vec4 v_Haze.xy;", "  c = vec4(v_Haze.xy, 0.0, 1.0);");
    vec![
        Req::new(vertex, textured).texture(texture(0)).ok(),
        Req::new(&haze_v, &haze_f).ok(),
        ok(PASS_VERTEX, PASS_FRAGMENT),
    ]
}

fn digest() -> String {
    let mut hash = Sha256::new();
    for program in programs() {
        for stage in &program.stages {
            hash.update(stage.payload.msl_source.as_bytes());
            hash.update(&[0]);
        }
    }
    to_hex(&hash.finalize())
}

#[test]
fn the_metal_text_of_fixed_programs_is_recorded_per_identity() {
    let identity = compiler_identity();
    // Retaining diagnostics must not change generated MSL. Reuse the genuine ordinary
    // expectation under the explicitly distinct diagnostic identity, without claiming a new
    // executed digest or adding a fictitious shipped revision.
    #[cfg(feature = "observer-uniform-layout")]
    let identity = identity.strip_suffix("-observer-uniform-layout-v1").expect("diagnostic identity discriminator");
    let row = SHIPPED.iter().find(|(id, _)| *id == identity).unwrap_or_else(|| panic!("no row for identity {identity}: append one when bumping the revision"));
    assert_eq!(digest(), row.1, "the Metal text changed under identity {identity}: bump PIPELINE_REVISION and append a row, never edit one");
}

#[test]
fn a_revision_is_never_reused_or_reset() {
    let revisions: Vec<u32> = SHIPPED.iter().map(|(id, _)| id.split_once(':').unwrap().0.parse().unwrap()).collect();
    assert!(revisions.windows(2).all(|w| w[0] < w[1]), "revisions only grow, in release order: {revisions:?}");
    assert_eq!(revisions.last().copied(), Some(PIPELINE_REVISION), "the newest row is the current revision");
    // The identity is compared only for equality; the retired library's strings are never returned.
    assert!(!SHIPPED.iter().any(|(id, _)| id.starts_with("17:")));
}
