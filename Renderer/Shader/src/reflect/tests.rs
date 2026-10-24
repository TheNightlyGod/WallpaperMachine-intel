// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! Behaviour tests of reflection, written from the behaviour list of spec part D (section 8,
//! items 27 to 32). Most modules come from legalized GLSL written out in full and read by
//! naga's own front end; the ones GLSL cannot express are built with naga's IR directly.

use naga::valid::{Capabilities, ModuleInfo, ValidationFlags, Validator};
use naga::{
    AddressSpace, Binding as NagaBinding, Expression, FunctionArgument, FunctionResult, ImageClass, Module,
    SampleLevel, ScalarKind, ShaderStage, Span, Statement, StructMember, Type, TypeInner, VectorSize,
};

use super::{InputNames, inputs_of, reflect_module, reflect_untranslated};
use crate::backend::tests::support::{Ir, f32_type, image_2d, sampler_type};
use crate::reflection::{DescriptorKind, Reflection, ReflectionError, StageMask, VertexScalar};
use crate::request::StageKind;

/// Reads the text with naga's front end, validates it as the backend does and reflects it.
fn reflect(kind: StageKind, text: &str) -> Result<Reflection, ReflectionError> {
    let mut front = naga::front::glsl::Frontend::default();
    let stage = if kind == StageKind::Vertex { ShaderStage::Vertex } else { ShaderStage::Fragment };
    let module = front.parse(&naga::front::glsl::Options::from(stage), text).unwrap_or_else(|e| panic!("front end: {e:?}\n{text}"));
    let info = Validator::new(ValidationFlags::all(), Capabilities::default())
        .validate(&module)
        .unwrap_or_else(|e| panic!("validation: {}\n{text}", e.as_inner()));
    reflect_module(kind, &module, &info, &InputNames::none())
}

fn frag(text: &str) -> Reflection {
    reflect(StageKind::Fragment, text).unwrap_or_else(|e| panic!("reflection failed: {e}\n{text}"))
}

fn frag_err(text: &str) -> String {
    reflect(StageKind::Fragment, text).expect_err("reflection should fail").to_string()
}

const OUT: &str = "layout(location = 0) out vec4 c;\n";

fn names(r: &Reflection) -> Vec<&str> {
    r.descriptor_bindings.iter().map(|d| d.name.as_str()).collect()
}

// ---- 27: descriptors by use ----

#[test]
fn only_resources_the_entry_point_uses_are_listed() {
    let r = frag(&format!(
        "#version 450\nlayout(set = 0, binding = 0) uniform texture2D used_tex;\nlayout(set = 0, binding = 1) uniform texture2D unused_tex;\nlayout(set = 0, binding = 2) uniform sampler used_smp;\nlayout(set = 0, binding = 3) uniform sampler unused_smp;\nlayout(std140, set = 0, binding = 4) uniform Used {{ float a; }};\nlayout(std140, set = 0, binding = 5) uniform Unused {{ float b; }};\n{OUT}void main() {{ c = texture(sampler2D(used_tex, used_smp), vec2(a)); }}\n"
    ));
    assert_eq!(names(&r), ["used_tex", "used_smp", "Used"]);
    assert_eq!(r.uniform_blocks.len(), 1);
    assert_eq!(r.uniform_blocks[0].name, "Used");
}

#[test]
fn kinds_masks_and_counts_of_ordinary_resources() {
    let r = frag(&format!(
        "#version 450\nlayout(set = 0, binding = 0) uniform texture2D t;\nlayout(set = 0, binding = 1) uniform sampler s;\nlayout(std140, set = 0, binding = 2) uniform B {{ float a; }};\n{OUT}void main() {{ c = texture(sampler2D(t, s), vec2(a)); }}\n"
    ));
    let kinds: Vec<DescriptorKind> = r.descriptor_bindings.iter().map(|d| d.descriptor).collect();
    assert_eq!(kinds, [DescriptorKind::SampledImage, DescriptorKind::Sampler, DescriptorKind::UniformBuffer]);
    for d in &r.descriptor_bindings {
        assert_eq!((d.set, d.count, d.stages), (0, 1, StageMask::FRAGMENT), "{}", d.name);
    }
    let v = reflect(
        StageKind::Vertex,
        "#version 450\nlayout(std140, set = 0, binding = 2) uniform B { float a; };\nvoid main() { gl_Position = vec4(a); }\n",
    )
    .unwrap();
    assert_eq!(v.descriptor_bindings[0].stages, StageMask::VERTEX, "only the reflected stage");
}

#[test]
fn a_depth_texture_is_a_sampled_image_and_a_comparison_sampler_is_a_sampler() {
    let r = frag(&format!(
        "#version 450\nlayout(set = 0, binding = 0) uniform texture2D g_Texture2;\nlayout(set = 0, binding = 1) uniform samplerShadow s;\n{OUT}void main() {{ c = vec4(texture(sampler2DShadow(g_Texture2, s), vec3(0.5))); }}\n"
    ));
    let kinds: Vec<DescriptorKind> = r.descriptor_bindings.iter().map(|d| d.descriptor).collect();
    assert_eq!(kinds, [DescriptorKind::SampledImage, DescriptorKind::Sampler]);
    assert_eq!(r.active_texture_slots.iter().copied().collect::<Vec<_>>(), [2]);
}

#[test]
fn a_used_storage_buffer_fails_naming_the_resource_set_and_binding() {
    let text = format!("#version 450\nlayout(std430, set = 0, binding = 1) buffer Data {{ float data[]; }};\n{OUT}void main() {{ c = vec4(data[0]); }}\n");
    let e = frag_err(&text);
    for needle in ["Data", "set 0", "binding 1", "unsupported"] {
        assert!(e.contains(needle), "{needle}: {e}");
    }
}

#[test]
fn an_unused_storage_buffer_is_silently_absent() {
    let r = frag(&format!("#version 450\nlayout(std430, set = 0, binding = 1) buffer Data {{ float data[]; }};\n{OUT}void main() {{ c = vec4(1.0); }}\n"));
    assert!(r.descriptor_bindings.is_empty() && r.uniform_blocks.is_empty(), "{r:?}");
}

/// The IR of a fragment entry point that samples element `index` of a binding array of images
/// (or the image itself when `array` is `None`) with a sampler, plus the globals it uses.
fn sampling_module(array: Option<naga::ArraySize>, image_name: &str, class: ImageClass) -> Module {
    let mut ir = Ir::new();
    let image = ir.ty(None, TypeInner::Image { dim: naga::ImageDimension::D2, arrayed: false, class });
    let image_ty = match array {
        Some(size) => ir.ty(None, TypeInner::BindingArray { base: image, size }),
        None => image,
    };
    let sampler_ty = sampler_type(&mut ir);
    let vec2 = ir.ty(None, TypeInner::Vector { size: VectorSize::Bi, scalar: naga::Scalar::F32 });
    let images = ir.global(Some(image_name), AddressSpace::Handle, Some((0, 0)), image_ty);
    let sampler = ir.global(Some("smp"), AddressSpace::Handle, Some((0, 1)), sampler_ty);
    ir.entry(ShaderStage::Fragment);
    let f = &mut ir.module.entry_points[0].function;
    let e_images = f.expressions.append(Expression::GlobalVariable(images), Span::UNDEFINED);
    let image_expr = if array.is_some() {
        let zero = f.expressions.append(Expression::Literal(naga::Literal::U32(0)), Span::UNDEFINED);
        let start = f.expressions.len();
        let access = f.expressions.append(Expression::Access { base: e_images, index: zero }, Span::UNDEFINED);
        f.body.push(Statement::Emit(f.expressions.range_from(start)), Span::UNDEFINED);
        access
    } else {
        e_images
    };
    let e_sampler = f.expressions.append(Expression::GlobalVariable(sampler), Span::UNDEFINED);
    let half = f.expressions.append(Expression::Literal(naga::Literal::F32(0.5)), Span::UNDEFINED);
    let start = f.expressions.len();
    let coordinate = f.expressions.append(Expression::Compose { ty: vec2, components: vec![half, half] }, Span::UNDEFINED);
    let _sample = f.expressions.append(
        Expression::ImageSample {
            image: image_expr,
            sampler: e_sampler,
            gather: None,
            coordinate,
            array_index: None,
            offset: None,
            level: SampleLevel::Auto,
            depth_ref: None,
            clamp_to_edge: false,
        },
        Span::UNDEFINED,
    );
    f.body.push(Statement::Emit(f.expressions.range_from(start)), Span::UNDEFINED);
    ir.module
}

fn sampled_float() -> ImageClass {
    ImageClass::Sampled { kind: ScalarKind::Float, multi: false }
}

#[test]
fn a_binding_array_has_its_constant_length_as_the_count() {
    let m = sampling_module(Some(naga::ArraySize::Constant(std::num::NonZeroU32::new(4).unwrap())), "textures", sampled_float());
    let r = reflect_untranslated(StageKind::Fragment, &m, &InputNames::none()).unwrap();
    let d = r.descriptor_bindings.iter().find(|d| d.name == "textures").unwrap();
    assert_eq!((d.count, d.descriptor), (4, DescriptorKind::SampledImage));
    assert_eq!(r.descriptor_bindings.iter().find(|d| d.name == "smp").unwrap().count, 1);
}

#[test]
fn an_unsized_binding_array_has_count_zero() {
    let m = sampling_module(Some(naga::ArraySize::Dynamic), "textures", sampled_float());
    let r = reflect_untranslated(StageKind::Fragment, &m, &InputNames::none()).unwrap();
    assert_eq!(r.descriptor_bindings.iter().find(|d| d.name == "textures").unwrap().count, 0);
}

// ---- 28: blocks ----

#[test]
fn block_members_report_offset_size_counts_and_stride() {
    let r = frag(&format!(
        "#version 450\nlayout(std140, set = 0, binding = 0) uniform GlobalUniforms {{\n float a; vec3 b; float c; mat3 d; mat4 e; vec4 ring[2]; float tail;\n}};\n{OUT}void main() {{ c = vec4(a + b.x + c + d[0].x + e[0].x + ring[1].x + tail); }}\n"
    ));
    let block = &r.uniform_blocks[0];
    assert_eq!((block.name.as_str(), block.set, block.binding), ("GlobalUniforms", 0, 0));
    let m = |name: &str| block.members.iter().find(|m| m.name == name).unwrap();
    // {float a; vec3 b; float c; mat3 d;} sit at 0, 16, 28, 32 (a vec3 leaves room for a float).
    assert_eq!((m("a").offset, m("b").offset, m("c").offset, m("d").offset), (0, 16, 28, 32));
    assert_eq!((m("b").size, m("b").element_count), (12, 3));
    assert_eq!((m("d").size, m("d").element_count), (48, 9));
    assert_eq!((m("e").size, m("e").element_count), (64, 16));
    // A vec4 array between two scalars: offset 16 or later, size 32, 4 components, 2 elements, stride 16.
    let ring = m("ring");
    assert_eq!((ring.size, ring.element_count, ring.array_count, ring.array_stride), (32, 4, 2, 16));
    assert_eq!(m("tail").offset, ring.offset + 32);
    assert_eq!(m("a").array_count, 0);
    assert_eq!(m("a").array_stride, 0);
}

#[test]
fn the_documented_block_expectations() {
    // `vec4 u_Ring[2]` between `float u_Lead` and `float u_Tail`: offset 16, size 32, tail at 48.
    let r = frag(&format!(
        "#version 450\nlayout(std140, set = 0, binding = 0) uniform B {{ float u_Lead; vec4 u_Ring[2]; float u_Tail; }};\n{OUT}void main() {{ c = vec4(u_Lead + u_Ring[1].x + u_Tail); }}\n"
    ));
    let m = &r.uniform_blocks[0].members;
    assert_eq!((m[1].offset, m[1].size, m[1].element_count, m[1].array_count, m[1].array_stride), (16, 32, 4, 2, 16));
    assert_eq!(m[2].offset, 48);
    // `{vec3 v; vec3 w;}` has offsets 0 and 16 and a size of at least 28.
    let r = frag(&format!(
        "#version 450\nlayout(std140, set = 0, binding = 0) uniform B {{ vec3 v; vec3 w; }};\n{OUT}void main() {{ c = vec4(v + w, 1.0); }}\n"
    ));
    let b = &r.uniform_blocks[0];
    assert_eq!((b.members[0].offset, b.members[1].offset), (0, 16));
    assert!(b.size >= 28);
}

#[test]
fn a_block_with_no_used_member_is_not_listed_but_a_used_one_is_whole() {
    let r = frag(&format!(
        "#version 450\nlayout(std140, set = 0, binding = 0) uniform B {{ float a; float b; }};\n{OUT}void main() {{ c = vec4(a); }}\n"
    ));
    assert_eq!(r.uniform_blocks[0].members.len(), 2, "the layout is the whole block's, not the used part");
}

#[test]
fn an_instance_less_block_is_named_by_its_type_and_a_named_instance_by_the_instance() {
    let r = frag(&format!("#version 450\nlayout(std140, set = 0, binding = 0) uniform Ty {{ float a; }} inst;\n{OUT}void main() {{ c = vec4(inst.a); }}\n"));
    assert_eq!(r.uniform_blocks[0].name, "inst");
    let r = frag(&format!("#version 450\nlayout(std140, set = 0, binding = 0) uniform Ty {{ float a; }};\n{OUT}void main() {{ c = vec4(a); }}\n"));
    assert_eq!(r.uniform_blocks[0].name, "Ty");
}

/// A module whose entry point loads the uniform global `g` of type `ty`, so it is used.
fn loading_module(name: Option<&str>, struct_name: Option<&str>, as_struct: bool) -> Module {
    let mut ir = Ir::new();
    let f32_ty = f32_type(&mut ir);
    let ty = if as_struct {
        ir.ty(struct_name, TypeInner::Struct { members: vec![StructMember { name: Some("a".into()), ty: f32_ty, binding: None, offset: 0 }], span: 4 })
    } else {
        f32_ty
    };
    let g = ir.global(name, AddressSpace::Uniform, Some((0, 0)), ty);
    ir.entry(ShaderStage::Fragment);
    let f = &mut ir.module.entry_points[0].function;
    let e = f.expressions.append(Expression::GlobalVariable(g), Span::UNDEFINED);
    let start = f.expressions.len();
    let pointer = if as_struct {
        f.expressions.append(Expression::AccessIndex { base: e, index: 0 }, Span::UNDEFINED)
    } else {
        e
    };
    f.expressions.append(Expression::Load { pointer }, Span::UNDEFINED);
    f.body.push(Statement::Emit(f.expressions.range_from(start)), Span::UNDEFINED);
    ir.module
}

fn reflect_loose(module: &Module) -> Result<Reflection, ReflectionError> {
    // Validation flags are off: the module is odd on purpose and only usage information matters.
    let info: ModuleInfo = Validator::new(ValidationFlags::empty(), Capabilities::all()).validate(module).expect("analysis");
    reflect_module(StageKind::Fragment, module, &info, &InputNames::none())
}

#[test]
fn a_used_uniform_that_is_not_a_structure_fails() {
    let e = reflect_loose(&loading_module(Some("u_Loose"), None, false)).unwrap_err().to_string();
    assert!(e.contains("u_Loose") && e.contains("not a structure"), "{e}");
}

#[test]
fn a_block_with_neither_a_name_nor_a_type_name_fails() {
    let e = reflect_loose(&loading_module(None, None, true)).unwrap_err().to_string();
    assert!(e.contains("neither a name nor a type name"), "{e}");
    assert!(reflect_loose(&loading_module(None, Some("Ty"), true)).is_ok());
}

// ---- 29: vertex inputs ----

const VERTEX_TAIL: &str = "void main() { gl_Position = vec4(a_Position, 1.0); }\n";

#[test]
fn every_declared_input_is_listed_read_or_not_in_order_without_builtins() {
    let r = reflect(
        StageKind::Vertex,
        &format!("#version 450\nlayout(location = 0) in vec3 a_Position;\nlayout(location = 1) in vec2 a_TexCoord;\nlayout(location = 2) in vec4 a_Color;\n{VERTEX_TAIL}"),
    )
    .unwrap();
    let list: Vec<(&str, u32)> = r.vertex_inputs.iter().map(|i| (i.name.as_str(), i.location)).collect();
    assert_eq!(list, [("a_Position", 0), ("a_TexCoord", 1), ("a_Color", 2)]);
    let with_index = reflect(
        StageKind::Vertex,
        "#version 450\nlayout(location = 0) in vec3 a_Position;\nvoid main() { gl_Position = vec4(a_Position, float(gl_VertexIndex)); }\n",
    )
    .unwrap();
    assert_eq!(with_index.vertex_inputs.len(), 1, "no phantom gl_VertexID input");
}

#[test]
fn the_twelve_vertex_formats() {
    for (scalar, glsl, label) in [(VertexScalar::Float, "", "sfloat"), (VertexScalar::Uint, "u", "uint"), (VertexScalar::Sint, "i", "sint")] {
        for n in 1..=4u8 {
            let ty = match (n, glsl) {
                (1, "") => "float".to_string(),
                (1, "u") => "uint".to_string(),
                (1, _) => "int".to_string(),
                (n, g) => format!("{g}vec{n}"),
            };
            let r = reflect(
                StageKind::Vertex,
                &format!("#version 450\nlayout(location = 0) in {ty} a_Value;\nvoid main() {{ gl_Position = vec4(1.0); }}\n"),
            )
            .unwrap();
            let f = r.vertex_inputs[0].format;
            assert_eq!((f.scalar(), f.components()), (scalar, n), "{ty}");
            let name = f.name();
            assert!(name.ends_with(label), "{name}");
        }
    }
}

fn location_binding(location: u32) -> Option<NagaBinding> {
    Some(NagaBinding::Location { location, interpolation: None, sampling: None, blend_src: None, per_primitive: false })
}

/// A vertex entry point with one input and a position output, so that naga accepts it.
fn input_module(ty: Type, name: &str, location: u32) -> Module {
    let mut ir = Ir::new();
    let ty = ir.module.types.insert(ty, Span::UNDEFINED);
    let vec4 = ir.ty(None, TypeInner::Vector { size: VectorSize::Quad, scalar: naga::Scalar::F32 });
    ir.entry(ShaderStage::Vertex);
    let f = &mut ir.module.entry_points[0].function;
    f.arguments.push(FunctionArgument { name: Some(name.into()), ty, binding: location_binding(location) });
    f.result = Some(FunctionResult { ty: vec4, binding: Some(NagaBinding::BuiltIn(naga::BuiltIn::Position { invariant: false })) });
    let zero = f.expressions.append(Expression::Literal(naga::Literal::F32(0.0)), Span::UNDEFINED);
    let start = f.expressions.len();
    let position = f.expressions.append(Expression::Compose { ty: vec4, components: vec![zero; 4] }, Span::UNDEFINED);
    f.body.push(Statement::Emit(f.expressions.range_from(start)), Span::UNDEFINED);
    f.body.push(Statement::Return { value: Some(position) }, Span::UNDEFINED);
    ir.module
}

fn reflect_input(module: &Module) -> Result<Reflection, ReflectionError> {
    reflect_untranslated(StageKind::Vertex, module, &InputNames::none())
}

#[test]
fn types_with_no_vertex_format_fail_naming_the_input_and_the_type() {
    let cases = [
        (TypeInner::Matrix { columns: VectorSize::Quad, rows: VectorSize::Quad, scalar: naga::Scalar::F32 }, "mat4x4"),
        (TypeInner::Scalar(naga::Scalar::BOOL), "bool"),
        (TypeInner::Scalar(naga::Scalar { kind: ScalarKind::Float, width: 2 }), "float16"),
        (TypeInner::Vector { size: VectorSize::Tri, scalar: naga::Scalar { kind: ScalarKind::Float, width: 8 } }, "float64vec3"),
    ];
    for (inner, spelling) in cases {
        // naga's validator refuses most of these argument types before reflection can see them
        // (so through the pipeline they are compile errors); the input reader is called directly.
        let m = input_module(Type { name: None, inner }, "a_Odd", 3);
        let e = inputs_of(&m, 0, &InputNames::none()).unwrap_err().to_string();
        assert!(e.contains("a_Odd") && e.contains(spelling), "{spelling}: {e}");
    }
}

#[test]
fn a_location_of_thirty_is_accepted_and_thirty_one_fails() {
    let ty = || Type { name: None, inner: TypeInner::Vector { size: VectorSize::Quad, scalar: naga::Scalar::F32 } };
    assert!(reflect_input(&input_module(ty(), "a_Last", 30)).is_ok());
    let e = reflect_input(&input_module(ty(), "a_Far", 31)).unwrap_err().to_string();
    assert!(e.contains("a_Far") && e.contains("31") && e.contains("out of range"), "{e}");
}

#[test]
fn a_struct_argument_is_flattened_to_its_location_members() {
    let mut ir = Ir::new();
    let vec2 = ir.ty(None, TypeInner::Vector { size: VectorSize::Bi, scalar: naga::Scalar::F32 });
    let location = location_binding;
    let s = ir.ty(
        Some("Inputs"),
        TypeInner::Struct {
            members: vec![
                StructMember { name: Some("uv".into()), ty: vec2, binding: location(4), offset: 0 },
                StructMember { name: Some("uv2".into()), ty: vec2, binding: location(7), offset: 8 },
            ],
            span: 16,
        },
    );
    let vec4 = ir.ty(None, TypeInner::Vector { size: VectorSize::Quad, scalar: naga::Scalar::F32 });
    ir.entry(ShaderStage::Vertex);
    let f = &mut ir.module.entry_points[0].function;
    f.arguments.push(FunctionArgument { name: Some("input".into()), ty: s, binding: None });
    f.result = Some(FunctionResult { ty: vec4, binding: Some(NagaBinding::BuiltIn(naga::BuiltIn::Position { invariant: false })) });
    let zero = f.expressions.append(Expression::Literal(naga::Literal::F32(0.0)), Span::UNDEFINED);
    let start = f.expressions.len();
    let position = f.expressions.append(Expression::Compose { ty: vec4, components: vec![zero; 4] }, Span::UNDEFINED);
    f.body.push(Statement::Emit(f.expressions.range_from(start)), Span::UNDEFINED);
    f.body.push(Statement::Return { value: Some(position) }, Span::UNDEFINED);
    let r = reflect_input(&ir.module).unwrap();
    let list: Vec<(&str, u32)> = r.vertex_inputs.iter().map(|i| (i.name.as_str(), i.location)).collect();
    assert_eq!(list, [("uv", 4), ("uv2", 7)]);
}

// ---- 30: active texture slots ----

fn sampling_text(textures: &[(&str, u32)], sampled: &[&str]) -> String {
    let mut t = String::from("#version 450\nlayout(set = 0, binding = 30) uniform sampler s;\n");
    for (name, binding) in textures {
        t.push_str(&format!("layout(set = 0, binding = {binding}) uniform texture2D {name};\n"));
    }
    t.push_str(OUT);
    t.push_str("void main() {\n  c = vec4(0.0);\n");
    for name in sampled {
        t.push_str(&format!("  c += texture(sampler2D({name}, s), vec2(0.5));\n"));
    }
    t.push_str("}\n");
    t
}

fn slots(r: &Reflection) -> Vec<u8> {
    r.active_texture_slots.iter().copied().collect()
}

#[test]
fn slots_follow_names_in_ascending_order_and_unused_textures_are_absent() {
    let r = frag(&sampling_text(&[("g_Texture5", 9), ("g_Texture1", 2), ("g_Texture6", 4)], &["g_Texture5", "g_Texture1"]));
    assert_eq!(slots(&r), [1, 5]);
    assert!(!names(&r).contains(&"g_Texture6"), "{:?}", names(&r));
}

#[test]
fn a_slot_does_not_depend_on_the_binding_index() {
    let a = frag(&sampling_text(&[("g_Texture3", 0)], &["g_Texture3"]));
    let b = frag(&sampling_text(&[("g_Texture3", 17)], &["g_Texture3"]));
    assert_eq!((slots(&a), slots(&b)), (vec![3], vec![3]));
}

#[test]
fn other_names_contribute_no_slot_but_stay_descriptors() {
    let r = frag(&sampling_text(&[("u_Diffuse", 1), ("g_Texture_Smp", 2), ("g_Texture1x", 3), ("g_Texture", 4)], &["u_Diffuse", "g_Texture_Smp", "g_Texture1x", "g_Texture"]));
    assert!(r.active_texture_slots.is_empty());
    for n in ["u_Diffuse", "g_Texture_Smp", "g_Texture1x", "g_Texture"] {
        assert!(names(&r).contains(&n), "{n}");
    }
}

#[test]
fn a_binding_array_is_judged_by_its_own_name() {
    let size = Some(naga::ArraySize::Constant(std::num::NonZeroU32::new(2).unwrap()));
    let r = reflect_untranslated(StageKind::Fragment, &sampling_module(size, "g_TexturePool", sampled_float()), &InputNames::none()).unwrap();
    assert!(r.active_texture_slots.is_empty(), "a word after g_Texture is not a slot");
    let r = reflect_untranslated(StageKind::Fragment, &sampling_module(size, "g_Texture7", sampled_float()), &InputNames::none()).unwrap();
    assert_eq!(slots(&r), [7]);
}

#[test]
fn depth_images_count_by_name_too() {
    let m = sampling_module(None, "g_Texture4", ImageClass::Depth { multi: false });
    // The sampler is a plain one here; only usage information is wanted.
    let info = Validator::new(ValidationFlags::empty(), Capabilities::all()).validate(&m).unwrap();
    let r = reflect_module(StageKind::Fragment, &m, &info, &InputNames::none()).unwrap();
    assert_eq!(slots(&r), [4]);
}

#[test]
fn a_leading_zero_32_and_300_fail_when_the_texture_is_used() {
    let e = frag_err(&sampling_text(&[("g_Texture07", 1)], &["g_Texture07"]));
    assert!(e.contains("canonical") && e.contains("g_Texture07"), "{e}");
    let e = frag_err(&sampling_text(&[("g_Texture32", 1)], &["g_Texture32"]));
    assert!(e.contains("model limits") && e.contains("g_Texture32"), "{e}");
    let e = frag_err(&sampling_text(&[("g_Texture300", 1)], &["g_Texture300"]));
    assert!(e.contains("g_Texture300") && !e.contains("model limits") && e.contains("slot suffix"), "{e}");
    // 31 is the last slot.
    assert_eq!(slots(&frag(&sampling_text(&[("g_Texture31", 1)], &["g_Texture31"]))), [31]);
}

#[test]
fn a_bad_texture_name_is_no_error_when_the_stage_never_uses_it() {
    let r = frag(&sampling_text(&[("g_Texture07", 1), ("g_Texture32", 2), ("g_Texture300", 3)], &[]));
    assert!(r.active_texture_slots.is_empty() && r.descriptor_bindings.is_empty());
}

// ---- 31: limits and symbols ----

#[test]
fn model_limits_apply_to_the_reflected_output() {
    let e = frag_err(&sampling_text(&[("u_Late", 32)], &["u_Late"]).replace("binding = 30", "binding = 5"));
    assert!(e.contains("model limits") && e.contains("u_Late") && e.contains("32"), "{e}");
    assert!(reflect(StageKind::Fragment, &sampling_text(&[("u_Edge", 31)], &["u_Edge"]).replace("binding = 30", "binding = 5")).is_ok());
    let e = frag_err(&format!("#version 450\nlayout(set = 4, binding = 0) uniform sampler far;\nlayout(set = 0, binding = 1) uniform texture2D t;\n{OUT}void main() {{ c = texture(sampler2D(t, far), vec2(0.5)); }}\n"));
    assert!(e.contains("model limits") && e.contains("set 4"), "{e}");
    assert!(reflect(StageKind::Fragment, &format!("#version 450\nlayout(set = 3, binding = 0) uniform sampler far;\nlayout(set = 0, binding = 1) uniform texture2D t;\n{OUT}void main() {{ c = texture(sampler2D(t, far), vec2(0.5)); }}\n")).is_ok());
}

#[test]
fn symbol_names_must_be_identifiers() {
    // A used resource with a name no host could look up fails reflection.
    let m = sampling_module(None, "bad name", sampled_float());
    let e = reflect_untranslated(StageKind::Fragment, &m, &InputNames::none()).unwrap_err().to_string();
    assert!(e.contains("not a usable symbol") && e.contains("bad name"), "{e}");
    // The same for a vertex input and a block member.
    let ty = Type { name: None, inner: TypeInner::Vector { size: VectorSize::Quad, scalar: naga::Scalar::F32 } };
    let e = reflect_input(&input_module(ty, "a-x", 0)).unwrap_err().to_string();
    assert!(e.contains("not a usable symbol"), "{e}");
}

// ---- 32: a module built without GLSL ----

#[test]
fn a_module_built_with_nagas_api_reflects() {
    let mut ir = Ir::new();
    let f32_ty = f32_type(&mut ir);
    let vec4 = ir.ty(None, TypeInner::Vector { size: VectorSize::Quad, scalar: naga::Scalar::F32 });
    let block = ir.ty(
        Some("GlobalUniforms"),
        TypeInner::Struct {
            members: vec![
                StructMember { name: Some("g_Alpha".into()), ty: f32_ty, binding: None, offset: 0 },
                StructMember { name: Some("g_Tint".into()), ty: vec4, binding: None, offset: 16 },
            ],
            span: 32,
        },
    );
    let image = image_2d(&mut ir);
    let sampler = sampler_type(&mut ir);
    let vec2 = ir.ty(None, TypeInner::Vector { size: VectorSize::Bi, scalar: naga::Scalar::F32 });
    let u = ir.global(None, AddressSpace::Uniform, Some((0, 0)), block);
    let t = ir.global(Some("g_Texture3"), AddressSpace::Handle, Some((0, 1)), image);
    let s = ir.global(Some("_we_Sampler_g_Texture3"), AddressSpace::Handle, Some((0, 2)), sampler);
    ir.entry(ShaderStage::Fragment);
    let f = &mut ir.module.entry_points[0].function;
    f.arguments.push(FunctionArgument {
        name: Some("uv".into()),
        ty: vec2,
        binding: Some(NagaBinding::Location { location: 0, interpolation: Some(naga::Interpolation::Perspective), sampling: None, blend_src: None, per_primitive: false }),
    });
    f.result = Some(FunctionResult {
        ty: vec4,
        binding: Some(NagaBinding::Location { location: 0, interpolation: None, sampling: None, blend_src: None, per_primitive: false }),
    });
    let uv = f.expressions.append(Expression::FunctionArgument(0), Span::UNDEFINED);
    let e_t = f.expressions.append(Expression::GlobalVariable(t), Span::UNDEFINED);
    let e_s = f.expressions.append(Expression::GlobalVariable(s), Span::UNDEFINED);
    let e_u = f.expressions.append(Expression::GlobalVariable(u), Span::UNDEFINED);
    let start = f.expressions.len();
    let sample = f.expressions.append(
        Expression::ImageSample {
            image: e_t,
            sampler: e_s,
            gather: None,
            coordinate: uv,
            array_index: None,
            offset: None,
            level: SampleLevel::Auto,
            depth_ref: None,
            clamp_to_edge: false,
        },
        Span::UNDEFINED,
    );
    let tint_ptr = f.expressions.append(Expression::AccessIndex { base: e_u, index: 1 }, Span::UNDEFINED);
    let tint = f.expressions.append(Expression::Load { pointer: tint_ptr }, Span::UNDEFINED);
    let product = f.expressions.append(Expression::Binary { op: naga::BinaryOperator::Multiply, left: sample, right: tint }, Span::UNDEFINED);
    f.body.push(Statement::Emit(f.expressions.range_from(start)), Span::UNDEFINED);
    f.body.push(Statement::Return { value: Some(product) }, Span::UNDEFINED);

    let r = reflect_untranslated(StageKind::Fragment, &ir.module, &InputNames::none()).unwrap();
    assert_eq!(names(&r), ["GlobalUniforms", "g_Texture3", "_we_Sampler_g_Texture3"]);
    assert_eq!(slots(&r), [3]);
    let block = &r.uniform_blocks[0];
    assert_eq!((block.name.as_str(), block.size), ("GlobalUniforms", 32));
    assert_eq!((block.members[1].name.as_str(), block.members[1].offset, block.members[1].element_count), ("g_Tint", 16, 4));
    assert!(r.vertex_inputs.is_empty(), "a fragment stage has no vertex inputs");
}

#[test]
fn an_invalid_module_is_a_reflection_error_naming_the_cause() {
    let mut ir = Ir::new();
    ir.entry(ShaderStage::Vertex); // a vertex entry point that returns no position
    let e = reflect_untranslated(StageKind::Vertex, &ir.module, &InputNames::none()).unwrap_err().to_string();
    assert!(e.contains("cannot be reflected") && e.contains("position"), "{e}");
    let e = reflect_untranslated(StageKind::Fragment, &Module::default(), &InputNames::none()).unwrap_err().to_string();
    assert!(e.contains("no fragment entry point"), "{e}");
}
