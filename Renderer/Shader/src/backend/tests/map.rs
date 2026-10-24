// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! The binding map and its errors (spec D test 19, R45 to R47): every resource global is
//! recorded, used or not; what the map cannot cover is an error, never a guess.

use naga::{AddressSpace, ShaderStage, TypeInner};

use super::support::*;
use crate::binding::SlotKind;
use crate::diagnostic::Pass;
use crate::error::{ErrorCategory, ShaderError};
use crate::request::StageKind;

const EMPTY_MAIN: &str = "layout(location = 0) out vec4 c;\nvoid main() { c = vec4(1.0); }\n";

/// The failure's first diagnostic: its pass and message.
fn diagnostic(e: &ShaderError) -> (Pass, String) {
    let ShaderError::Source { failures, .. } = e else { panic!("expected a source failure: {e}") };
    let d = &failures[0].diagnostic;
    (d.pass.expect("a pass"), d.message.clone())
}

fn assert_msl_write(e: &ShaderError, needles: &[&str]) {
    assert_eq!(e.category(), ErrorCategory::Compile, "{e}");
    let (pass, message) = diagnostic(e);
    assert_eq!(pass, Pass::MslWrite, "{message}");
    for n in needles {
        assert!(message.contains(n), "{n}: {message}");
    }
}

#[test]
fn a_descriptor_set_other_than_zero_fails_naming_the_global_and_the_set() {
    let used = format!("#version 450\nlayout(set = 1, binding = 0) uniform sampler s;\nlayout(set = 0, binding = 1) uniform texture2D t;\n{EMPTY_MAIN}");
    let e = fail(StageKind::Fragment, &used);
    assert_msl_write(&e, &["`s`", "descriptor set 1"]);
    // Even when the stage never touches it (R47).
    let e = fail(StageKind::Fragment, &format!("#version 450\nlayout(set = 2, binding = 0) uniform sampler unused;\n{EMPTY_MAIN}"));
    assert_msl_write(&e, &["`unused`", "descriptor set 2"]);
}

#[test]
fn a_resource_without_set_and_binding_fails() {
    // The GLSL front end refuses the spelling itself ...
    let e = fail(StageKind::Fragment, &format!("#version 450\nuniform texture2D loose;\n{EMPTY_MAIN}"));
    assert_eq!(diagnostic(&e).0, Pass::GlslParse, "{e}");
    // ... and a module that has such a global (naga's own IR) is refused by the map, used or not.
    for space in [AddressSpace::Handle, AddressSpace::Uniform] {
        let mut ir = Ir::new();
        let ty = if space == AddressSpace::Handle { image_2d(&mut ir) } else { ir.ty(Some("Loose"), TypeInner::Struct { members: vec![], span: 4 }) };
        ir.global(Some("loose"), space, None, ty);
        ir.entry(ShaderStage::Fragment);
        let e = ir.translate(StageKind::Fragment).unwrap_err();
        assert_msl_write(&e, &["`loose`", "no binding"]);
    }
}

#[test]
fn push_constant_data_fails() {
    let text = "#version 450\nlayout(push_constant) uniform Push { float k; } push;\nlayout(location = 0) out vec4 c;\nvoid main() { c = vec4(push.k); }\n";
    let e = fail(StageKind::Fragment, text);
    assert_msl_write(&e, &["push", "immediate"]);
}

#[test]
fn handles_that_are_neither_textures_nor_samplers_fail() {
    // GLSL cannot express an acceleration structure, so the module is built with naga's IR.
    let mut ir = Ir::new();
    let tlas = ir.ty(None, TypeInner::AccelerationStructure { vertex_return: false });
    ir.global(Some("scene_tlas"), AddressSpace::Handle, Some((0, 0)), tlas);
    ir.entry(ShaderStage::Fragment);
    let e = ir.translate(StageKind::Fragment).unwrap_err();
    assert_msl_write(&e, &["`scene_tlas`", "acceleration structure"]);
}

#[test]
fn payload_address_spaces_and_immediates_in_the_ir_fail() {
    let mut ir = Ir::new();
    let f32_ty = f32_type(&mut ir);
    ir.global(Some("payload"), AddressSpace::RayPayload, None, f32_ty);
    ir.entry(ShaderStage::Fragment);
    let e = ir.translate(StageKind::Fragment).unwrap_err();
    assert_msl_write(&e, &["`payload`", "ray payload"]);

    let mut ir = Ir::new();
    let f32_ty = f32_type(&mut ir);
    ir.global(Some("p"), AddressSpace::Immediate, None, f32_ty);
    ir.entry(ShaderStage::Fragment);
    let e = ir.translate(StageKind::Fragment).unwrap_err();
    assert_msl_write(&e, &["`p`", "immediate"]);
}

#[test]
fn resource_names_must_be_symbols_even_when_unused() {
    for bad in ["", "a-b", "1x", "naïve"] {
        let mut ir = Ir::new();
        let image = image_2d(&mut ir);
        ir.global(Some(bad), AddressSpace::Handle, Some((0, 0)), image);
        ir.entry(ShaderStage::Fragment);
        let e = ir.translate(StageKind::Fragment).unwrap_err();
        assert_msl_write(&e, &["cannot name a global resource", "ASCII identifier"]);
    }
    // A block with no name of its own and no type name is just as unusable.
    let mut ir = Ir::new();
    let ty = ir.ty(None, TypeInner::Struct { members: vec![], span: 4 });
    ir.global(None, AddressSpace::Uniform, Some((0, 0)), ty);
    ir.entry(ShaderStage::Fragment);
    let e = ir.translate(StageKind::Fragment).unwrap_err();
    assert_msl_write(&e, &["cannot name a global resource"]);
}

#[test]
fn an_unused_valid_global_still_has_a_record() {
    let text = format!(
        "#version 450\nlayout(set = 0, binding = 5) uniform texture2D never_sampled;\nlayout(set = 0, binding = 6) uniform sampler never_used;\nlayout(std140, set = 0, binding = 7) uniform Unread {{ float k; }};\n{EMPTY_MAIN}"
    );
    let f = fragment(&text);
    assert_eq!(slot_of(&f, "never_sampled"), (SlotKind::Texture, 5, 0));
    assert_eq!(slot_of(&f, "never_used"), (SlotKind::Sampler, 6, 0));
    assert_eq!(slot_of(&f, "Unread"), (SlotKind::Buffer, 7, 0), "an instance-less block is named by its type");
    assert!(!msl(&f).contains("never_sampled"), "the text does not mention what the stage never reads");
}

fn many(kind: &str, n: u32) -> String {
    let mut text = String::from("#version 450\n");
    for i in 0..n {
        match kind {
            "buffer" => text.push_str(&format!("layout(std140, set = 0, binding = {i}) uniform B{i} {{ float x{i}; }};\n")),
            "texture" => text.push_str(&format!("layout(set = 0, binding = {i}) uniform texture2D t{i};\n")),
            _ => text.push_str(&format!("layout(set = 0, binding = {i}) uniform sampler s{i};\n")),
        }
    }
    text.push_str(EMPTY_MAIN);
    text
}

#[test]
fn the_boundary_counts_of_each_namespace_through_the_backend() {
    for (kind, ok, over, slot, limit) in [("buffer", 31, 32, 31, 30), ("texture", 128, 129, 128, 127), ("sampler", 16, 17, 16, 15)] {
        let c = fragment(&many(kind, ok));
        assert_eq!(c.payload.bindings.len(), ok as usize);
        let e = fail(StageKind::Fragment, &many(kind, over));
        assert_eq!(e.category(), ErrorCategory::Reflection, "{e}");
        let text = e.to_string();
        let prefix = match kind {
            "buffer" => "B",
            "texture" => "t",
            _ => "s",
        };
        for needle in [kind.to_string(), format!("slot {slot}"), format!("`{prefix}{slot}`"), limit.to_string()] {
            assert!(text.contains(&needle), "{needle}: {text}");
        }
    }
}

#[test]
fn a_full_namespace_does_not_use_up_another() {
    let mut text = String::from("#version 450\n");
    for i in 0..16 {
        text.push_str(&format!("layout(set = 0, binding = {i}) uniform sampler s{i};\n"));
    }
    for i in 0..128 {
        text.push_str(&format!("layout(set = 0, binding = {}) uniform texture2D t{i};\n", 16 + i));
    }
    for i in 0..31 {
        text.push_str(&format!("layout(std140, set = 0, binding = {}) uniform B{i} {{ float x{i}; }};\n", 144 + i));
    }
    text.push_str(EMPTY_MAIN);
    assert_eq!(fragment(&text).payload.bindings.len(), 16 + 128 + 31);
}

#[test]
fn the_records_are_deterministic_and_in_declaration_order() {
    let text = format!(
        "#version 450\nlayout(set = 0, binding = 9) uniform texture2D late;\nlayout(set = 0, binding = 1) uniform texture2D early;\n{EMPTY_MAIN}"
    );
    let a = fragment(&text);
    let b = fragment(&text);
    assert_eq!(a.payload.bindings, b.payload.bindings);
    let names: Vec<&str> = a.payload.bindings.iter().map(|b| b.name.as_str()).collect();
    assert_eq!(names, ["late", "early"]);
    assert_eq!((binding(&a, "late").slot, binding(&a, "early").slot), (1, 0), "ranks follow the binding index");
}
