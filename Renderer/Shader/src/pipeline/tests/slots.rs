// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! Amendments 1, D5 and D6: the Metal slot of a resource is its rank within its namespace (buffers,
//! textures, samplers), per stage, by ascending binding and without gaps (d R46, replacing a-contract
//! R35 and R39); and the block of a video plane variant may sit anywhere that collides with nothing
//! (relaxing a-contract R102(b) and c2 R29). Each test is the black-box check of its amendment.

use std::collections::HashSet;

use super::support::*;
use crate::binding::{Binding, SlotKind};
use crate::error::ErrorCategory;
use crate::pipeline::CompiledProgram;
use crate::request::{StageKind, TextureRecord, VideoPlanes};

const VERTEX: &str = "attribute vec3 a_Position;\nvoid main() { gl_Position = vec4(a_Position, 1.0); }";

fn records(p: &CompiledProgram, kind: StageKind) -> &[Binding] {
    &p.stage(kind).unwrap().payload.bindings
}

fn slot_of(p: &CompiledProgram, kind: StageKind, name: &str) -> (SlotKind, u32, u32) {
    let b = records(p, kind).iter().find(|b| b.name == name).unwrap_or_else(|| panic!("no record for {name}"));
    (b.slot_kind, b.binding, b.slot)
}

/// The slots of one namespace of one stage, sorted.
fn slots_of_kind(p: &CompiledProgram, stage: StageKind, kind: SlotKind) -> Vec<u32> {
    let mut slots: Vec<u32> = records(p, stage).iter().filter(|b| b.slot_kind == kind).map(|b| b.slot).collect();
    slots.sort_unstable();
    slots
}

/// Gap-free from 0 in each namespace of the stage, and no two records share kind and slot.
fn assert_dense(p: &CompiledProgram, stage: StageKind) {
    for kind in [SlotKind::Buffer, SlotKind::Texture, SlotKind::Sampler] {
        let slots = slots_of_kind(p, stage, kind);
        assert_eq!(slots, (0..slots.len() as u32).collect::<Vec<_>>(), "{} slots of the {} stage", kind.name(), stage.name());
    }
    let mut seen = HashSet::new();
    for b in records(p, stage) {
        assert!(seen.insert((b.slot_kind.name(), b.slot)), "{} slot {} twice", b.slot_kind.name(), b.slot);
    }
}

fn samplers(n: usize) -> (String, Vec<TextureRecord>) {
    // Textures with canonical names, each sampled once: every one has its own sampler.
    let declarations: String = (0..n).map(|i| format!("uniform sampler2D g_Texture{i};\n")).collect();
    let sum: String = (0..n).map(|i| format!("texSample2D(g_Texture{i}, v_Tex)")).collect::<Vec<_>>().join(" + ");
    (format!("varying vec2 v_Tex;\n{declarations}uniform float g_Alpha;\nvoid main() {{ gl_FragColor = ({sum}) * g_Alpha; }}"), (0..n as u8).map(texture).collect())
}

#[test]
fn slots_are_dense_per_namespace_while_the_bindings_stay_as_they_were() {
    let (f, textures) = samplers(2);
    let p = Req::new(VERTEX, &f).texture(textures[0]).texture(textures[1]).ok();
    let fragment = |name: &str| slot_of(&p, StageKind::Fragment, name);
    // One block at buffer slot 0, textures 0 and 1, samplers 0 and 1; the bindings keep their numbers.
    assert_eq!(fragment("GlobalUniforms"), (SlotKind::Buffer, 2, 0));
    assert_eq!(fragment("g_Texture0"), (SlotKind::Texture, 0, 0));
    assert_eq!(fragment("g_Texture1"), (SlotKind::Texture, 1, 1));
    assert_eq!(fragment("_we_Sampler_g_Texture0"), (SlotKind::Sampler, 3, 0));
    assert_eq!(fragment("_we_Sampler_g_Texture1"), (SlotKind::Sampler, 4, 1));
    assert_dense(&p, StageKind::Fragment);
    assert_dense(&p, StageKind::Vertex);
    // The block is buffer slot 0 whenever it is the stage's only buffer, which is every generated program.
    assert_eq!(slot_of(&p, StageKind::Vertex, "GlobalUniforms").2, 0);
    // The reflection reports bindings, never slots.
    assert!(p.reflection.descriptor_bindings.iter().any(|d| d.name == "_we_Sampler_g_Texture1" && d.binding == 4));
}

#[test]
fn thirteen_textures_and_the_block_compile_with_sampler_slots_0_to_12() {
    let (f, textures) = samplers(13);
    let mut req = Req::new(VERTEX, &f);
    for t in textures {
        req = req.texture(t);
    }
    let p = req.ok();
    assert_eq!(slots_of_kind(&p, StageKind::Fragment, SlotKind::Sampler), (0..13).collect::<Vec<u32>>());
    assert_eq!(slots_of_kind(&p, StageKind::Fragment, SlotKind::Texture), (0..13).collect::<Vec<u32>>());
    assert_eq!(slots_of_kind(&p, StageKind::Fragment, SlotKind::Buffer), [0]);
    assert_dense(&p, StageKind::Fragment);
}

#[test]
fn more_than_sixteen_distinct_samplers_fail_with_the_argument_table_limit() {
    let (f, textures) = samplers(17);
    let mut req = Req::new(VERTEX, &f);
    for t in textures {
        req = req.texture(t);
    }
    let e = req.err();
    assert_eq!(e.category(), ErrorCategory::Reflection, "{e}");
    let text = e.to_string();
    assert!(text.contains("argument-table limit of 15") && text.contains("sampler") && text.contains("slot 16"), "{text}");
    assert!(text.contains("_we_Sampler_g_Texture16"), "the resource is named: {text}");
}

#[test]
fn stages_that_declare_different_subsets_each_number_their_own_records_without_gaps() {
    let v = "attribute vec3 a_Position;\nuniform vec2 g_Offset;\nvoid main() { gl_Position = vec4(a_Position.xy + g_Offset, a_Position.z, 1.0); }";
    let f = "varying vec2 v_Tex;\nuniform sampler2D g_Texture3; uniform sampler2D g_Texture5; uniform float g_Alpha;\nvoid main() { gl_FragColor = texSample2D(g_Texture3, v_Tex) * texSample2D(g_Texture5, v_Tex) * g_Alpha; }";
    let p = Req::new(v, f).texture(texture(3)).texture(texture(5)).ok();
    for stage in [StageKind::Vertex, StageKind::Fragment] {
        assert_dense(&p, stage);
    }
    // The textures have the ranks 0 and 1 although their bindings are 3 and 5.
    assert_eq!(slot_of(&p, StageKind::Fragment, "g_Texture3").2, 0);
    assert_eq!(slot_of(&p, StageKind::Fragment, "g_Texture5").2, 1);
    assert_eq!(slot_of(&p, StageKind::Fragment, "g_Texture5").1, 5);
    // The vertex stage declares no texture and no sampler.
    assert!(records(&p, StageKind::Vertex).iter().all(|b| b.slot_kind == SlotKind::Buffer));
    // A vertex stage that samples a different texture ranks from 0 on its own side.
    let v = "attribute vec3 a_Position; attribute vec2 a_TexCoord;\nuniform sampler2D g_Texture5;\nvoid main() { gl_Position = vec4(a_Position, 1.0) + texSample2DLod(g_Texture5, a_TexCoord, 0.0); }";
    let f = "varying vec2 v_Tex;\nuniform sampler2D g_Texture1;\nvoid main() { gl_FragColor = texSample2D(g_Texture1, v_Tex); }";
    let p = Req::new(v, f).texture(texture(1)).texture(texture(5)).ok();
    for stage in [StageKind::Vertex, StageKind::Fragment] {
        assert_dense(&p, stage);
    }
    assert_eq!(slot_of(&p, StageKind::Vertex, "g_Texture5").2, 0);
    assert_eq!(slot_of(&p, StageKind::Fragment, "g_Texture1").2, 0);
}

#[test]
fn the_same_request_twice_gives_identical_records() {
    let (f, textures) = samplers(5);
    let build = || {
        let mut req = Req::new(VERTEX, &f);
        for t in textures.iter().copied() {
            req = req.texture(t);
        }
        req.ok()
    };
    let (a, b) = (build(), build());
    for stage in [StageKind::Vertex, StageKind::Fragment] {
        assert_eq!(records(&a, stage), records(&b, stage));
    }
    assert_eq!(a, b);
}

// ---- D6 ----

fn plane_texture(slot: u8) -> TextureRecord {
    let mut t = texture(slot);
    t.video_planes = VideoPlanes::Nv12Biplanar;
    t
}

#[test]
fn a_plane_variant_without_an_authored_uniform_places_the_block_where_nothing_collides() {
    let f = "varying vec2 v_Tex;\nuniform sampler2D g_Texture0; uniform sampler2D g_Texture1;\nvoid main() { gl_FragColor = texSample2D(g_Texture0, v_Tex) * texSample2D(g_Texture1, v_Tex); }";
    let plain = Req::new(VERTEX, f).texture(texture(0)).texture(texture(1)).ok();
    let planar = Req::new(VERTEX, f).texture(plane_texture(0)).texture(texture(1)).ok();
    let stage = StageKind::Fragment;
    // The block and the chroma resources exist under their names.
    for name in ["GlobalUniforms", "_we_VideoChroma0", "_we_Sampler__we_VideoChroma0"] {
        slot_of(&planar, stage, name);
    }
    // Every binding is unique.
    let bindings: Vec<u32> = records(&planar, stage).iter().map(|b| b.binding).collect();
    assert_eq!(bindings.len(), bindings.iter().collect::<HashSet<_>>().len(), "{bindings:?}");
    // The author's resources keep the bindings they have in the plain variant.
    for name in ["g_Texture0", "g_Texture1", "_we_Sampler_g_Texture0", "_we_Sampler_g_Texture1"] {
        assert_eq!(slot_of(&planar, stage, name).1, slot_of(&plain, stage, name).1, "{name}");
    }
    // The chroma bindings are above every author texture and sampler (above 3 here).
    assert!(slot_of(&planar, stage, "_we_VideoChroma0").1 > 3 && slot_of(&planar, stage, "_we_Sampler__we_VideoChroma0").1 > 3);
    // The block carries the four plane members, in order.
    let members: Vec<&str> = planar.reflection.uniform_blocks[0].members.iter().map(|m| m.name.as_str()).collect();
    assert_eq!(members, ["_we_VideoRange0", "_we_VideoMatrix0", "_we_VideoUvTransform0", "_we_VideoUvOffset0"]);
    // The chroma resources are the third texture and the third sampler of the stage (D5).
    assert_eq!(slot_of(&planar, stage, "_we_VideoChroma0").2, 2);
    assert_eq!(slot_of(&planar, stage, "_we_Sampler__we_VideoChroma0").2, 2);
    assert_dense(&planar, stage);
    // Nothing orders the block against the chroma resources: only the properties above are checked,
    // so a layout that numbers the block after them, or before them, is equally valid.
}

#[test]
fn a_plane_variant_with_an_authored_uniform_keeps_the_block_before_the_samplers() {
    // a-contract R102(a) is unchanged: the author's block is laid out as in the plain variant.
    let f = "varying vec2 v_Tex;\nuniform sampler2D g_Texture0; uniform sampler2D g_Texture1; uniform float g_Alpha;\nvoid main() { gl_FragColor = texSample2D(g_Texture0, v_Tex) * texSample2D(g_Texture1, v_Tex) * g_Alpha; }";
    let plain = Req::new(VERTEX, f).texture(texture(0)).texture(texture(1)).ok();
    let planar = Req::new(VERTEX, f).texture(plane_texture(0)).texture(texture(1)).ok();
    for name in ["g_Texture0", "g_Texture1", "_we_Sampler_g_Texture0", "_we_Sampler_g_Texture1", "GlobalUniforms"] {
        assert_eq!(slot_of(&planar, StageKind::Fragment, name).1, slot_of(&plain, StageKind::Fragment, name).1, "{name}");
    }
    assert!(slot_of(&planar, StageKind::Fragment, "GlobalUniforms").1 < slot_of(&planar, StageKind::Fragment, "_we_Sampler_g_Texture0").1);
}
