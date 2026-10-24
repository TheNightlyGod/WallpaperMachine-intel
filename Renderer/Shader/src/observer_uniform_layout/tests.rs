// WallpaperMachine diagnostics for its independently authored shader pipeline.
// Physical layout facts use the permitted Naga IR/layout API.
//! Transformed cases use the ordinary Pipeline::metal path. IR-only cases exercise
//! unavailable and nesting boundaries, not native reflection.

use std::num::NonZeroU32;
use std::sync::atomic::{AtomicUsize, Ordering};

use super::*;
use crate::backend::{StageCompiler, compile_glsl};
use crate::error::ShaderError;
use crate::json::Value;
use crate::legalize::LegalStage;
use crate::pipeline::{Pipeline, tests::support::{PASS_FRAGMENT, PASS_VERTEX, Req}};
use crate::reflect::{InputNames, NagaReflector, StageReflector};
use crate::reflection::Reflection;
use crate::response::StagePayload;
use crate::source::NoIncludes;

fn available<T: std::fmt::Debug>(observation: &Observation<T>) -> &T {
    match observation {
        Observation::Available(value) => value,
        Observation::Unavailable(reason) => panic!("unavailable: {reason:?}"),
    }
}

fn stage_blocks(program: &CompiledProgram, stage: StageKind) -> &[UniformBlock] {
    available(&program.stage(stage).unwrap().uniform_layout.blocks)
}

fn member<'a>(block: &'a UniformBlock, name: &str) -> &'a UniformMember {
    available(&block.layout).members.iter().find(|member| member.name.as_deref() == Some(name)).unwrap()
}

fn layout<'a>(block: &'a UniformBlock, name: &str) -> &'a MemberLayout {
    available(&member(block, name).layout)
}

fn field<'a>(value: &'a Value, key: &str) -> &'a Value {
    let Value::Object(fields) = value else { panic!("not an object: {value:?}") };
    fields.iter().find(|(name, _)| name == key).map(|(_, value)| value).unwrap_or_else(|| panic!("missing {key}"))
}

#[test]
fn original_pipeline_retains_scalar_vector_and_signed_unsigned_float_storage_boundaries() {
    let fragment = "uniform float g_F; uniform int g_I; uniform uint g_U; uniform vec3 g_V; uniform bool g_B;\n\
        void main() { gl_FragColor = vec4(g_V, g_F + float(g_I) + float(g_U) + (g_B ? 1.0 : 0.0)); }";
    let program = Req::new(PASS_VERTEX, fragment).ok();
    let blocks = stage_blocks(&program, StageKind::Fragment);
    assert_eq!(blocks.len(), 1);
    let block = &blocks[0];
    assert_eq!((block.name.as_str(), block.set, block.binding), ("GlobalUniforms", Some(0), Some(0)));
    assert_eq!(available(&block.layout).byte_span, 32);
    for (index, name, offset, span, base, shape) in [
        (0, "g_F", 0, 4, ScalarBase::Float, ElementShape::Scalar),
        (1, "g_I", 4, 4, ScalarBase::Signed, ElementShape::Scalar),
        (2, "g_U", 8, 4, ScalarBase::Unsigned, ElementShape::Scalar),
        (3, "g_V", 16, 12, ScalarBase::Float, ElementShape::Vector { components: 3 }),
        // The source says bool, but the actual legalizer/compiler storage is unsigned 32-bit.
        (4, "g_B", 28, 4, ScalarBase::Unsigned, ElementShape::Scalar),
    ] {
        let member = member(block, name);
        let layout = available(&member.layout);
        assert_eq!((member.member_index, member.offset, layout.byte_span), (index, offset, span), "{name}");
        assert_eq!(layout.ty.scalar, PhysicalScalar { base, byte_width: 4 }, "{name}");
        assert_eq!(layout.ty.element_shape, shape, "{name}");
        assert!(layout.ty.arrays.is_empty(), "{name} must not be inferred to be an array");
    }
    assert!(stage_blocks(&program, StageKind::Vertex).is_empty(), "declared-but-unused block must not leak into the vertex record");
}

#[test]
fn widened_two_row_matrix_and_padded_arrays_remain_physical_not_authored_counts() {
    let fragment = "uniform mat2 g_M; uniform mat4x2 g_MS[2]; uniform float g_F[3]; uniform vec2 g_V[1];\n\
        void main() { gl_FragColor = vec4(g_M[0] + g_MS[1][2] + g_V[0], g_F[2], 1.0); }";
    let program = Req::new(PASS_VERTEX, fragment).ok();
    let block = &stage_blocks(&program, StageKind::Fragment)[0];
    let matrix = layout(block, "g_M");
    assert_eq!(matrix.byte_span, 32);
    assert_eq!(matrix.ty.element_shape, ElementShape::Matrix { columns: 2, rows: 4, column_stride: 16 });
    assert!(matrix.ty.arrays.is_empty());
    let matrices = layout(block, "g_MS");
    assert_eq!((member(block, "g_MS").offset, matrices.byte_span), (32, 128));
    assert_eq!(matrices.ty.element_shape, ElementShape::Matrix { columns: 4, rows: 4, column_stride: 16 });
    assert_eq!(matrices.ty.arrays, [ArrayDimension { count: 2, stride: 64 }]);
    let floats = layout(block, "g_F");
    assert_eq!((member(block, "g_F").offset, floats.byte_span), (160, 48));
    assert_eq!(floats.ty.element_shape, ElementShape::Vector { components: 4 });
    assert_eq!(floats.ty.arrays, [ArrayDimension { count: 3, stride: 16 }]);
    let vectors = layout(block, "g_V");
    assert_eq!((member(block, "g_V").offset, vectors.byte_span), (208, 16));
    assert_eq!(vectors.ty.element_shape, ElementShape::Vector { components: 4 });
    assert_eq!(vectors.ty.arrays, [ArrayDimension { count: 1, stride: 16 }], "one element remains an array, not a vector");
    assert_eq!(available(&block.layout).byte_span, 224);
    // The existing author-facing restoration is still intact and must not supply native types.
    let logical = &program.reflection.uniform_blocks[0];
    assert_eq!(logical.members.iter().find(|member| member.name == "g_M").unwrap().element_count, 4);
    assert_eq!(logical.members.iter().find(|member| member.name == "g_MS").unwrap().element_count, 8);
    let raw = reflection_json(&program);
    let diagnostic = json::parse(&raw).unwrap();
    assert_eq!(field(field(&diagnostic, "observer_uniform_layout"), "origin"), &Value::String("original-translated-naga-module".into()));
    assert!(raw.contains("\"rows\":4,\"column_stride\":16"));
    assert!(raw.contains("\"count\":2,\"stride\":64"));
}

#[test]
fn matrix_column_alignment_is_not_packed_rows_or_the_whole_matrix_array_stride() {
    let fragment = "uniform mat2x3 g_M; uniform mat2x3 g_MS[2];\n\
        void main() { gl_FragColor = vec4(g_M[0] + g_MS[1][1], 1.0); }";
    let program = Req::new(PASS_VERTEX, fragment).ok();
    let block = &stage_blocks(&program, StageKind::Fragment)[0];
    let matrix = layout(block, "g_M");
    let array = layout(block, "g_MS");
    assert_eq!(matrix.ty.element_shape, ElementShape::Matrix { columns: 2, rows: 3, column_stride: 16 });
    assert_eq!(matrix.byte_span, 32);
    assert_eq!(array.ty.element_shape, matrix.ty.element_shape);
    assert_eq!(array.ty.arrays, [ArrayDimension { count: 2, stride: 32 }]);
    assert_eq!((member(block, "g_MS").offset, array.byte_span), (32, 64));
}

struct OriginalStages {
    calls: AtomicUsize,
}

impl StageCompiler for OriginalStages {
    fn compile(&self, kind: StageKind, _stage: &LegalStage) -> Result<CompiledStage, ShaderError> {
        self.calls.fetch_add(1, Ordering::Relaxed);
        let declarations = "#version 450\n\
            layout(std140, set = 0, binding = 3) uniform VertexOnly { float v; };\n\
            layout(std140, set = 0, binding = 7) uniform FragmentOnly { vec4 f; };\n\
            layout(std140, set = 0, binding = 11) uniform Unused { mat4 unused_value; };\n";
        let body = match kind {
            StageKind::Vertex => "void main() { gl_Position = vec4(v); }",
            StageKind::Fragment => "layout(location = 0) out vec4 colour; void main() { colour = f; }",
        };
        compile_glsl(kind, &format!("{declarations}{body}"))
    }
}

#[test]
fn each_owned_stage_keeps_only_its_original_selected_entry_active_blocks() {
    let compiler = OriginalStages { calls: AtomicUsize::new(0) };
    let request = Req::new(PASS_VERTEX, PASS_FRAGMENT).fragment_first().build();
    let program = Pipeline { compiler: &compiler, reflector: &NagaReflector }.compile(&request, &NoIncludes).unwrap();
    assert_eq!(compiler.calls.load(Ordering::Relaxed), 2, "one original compile per stage, no metadata recompile");
    assert_eq!(program.stages[0].kind, StageKind::Fragment);
    for (kind, name, binding) in [(StageKind::Vertex, "VertexOnly", 3), (StageKind::Fragment, "FragmentOnly", 7)] {
        let stage = program.stage(kind).unwrap();
        let retained = &stage.uniform_layout;
        assert_eq!(retained.stage, kind);
        assert_eq!(retained.source_entry_point.as_deref(), Some("main"));
        assert_eq!(retained.msl_entry_point.as_deref(), Some(stage.payload.entry_point.as_str()));
        assert!(retained.is_complete());
        let blocks = available(&retained.blocks);
        assert_eq!(blocks.len(), 1);
        assert_eq!((blocks[0].name.as_str(), blocks[0].set, blocks[0].binding), (name, Some(0), Some(binding)));
    }
    assert_eq!(program.reflection.uniform_blocks.len(), 2, "ordinary reflection still merges the distinct blocks");
    let serialized = json::parse(&reflection_json(&program)).unwrap();
    let diagnostic = field(&serialized, "observer_uniform_layout");
    let Value::Number(version) = field(diagnostic, "schema_version") else { panic!() };
    assert_eq!(version.as_u64(), Some(1));
    let Value::Array(stages) = field(diagnostic, "stages") else { panic!() };
    assert_eq!(field(&stages[0], "stage"), &Value::String("fragment".into()));
    assert_eq!(field(&stages[1], "stage"), &Value::String("vertex".into()));
    // Strip only the additive field and compare the full ordinary object, not selected keys.
    let Value::Object(mut fields) = serialized else { panic!() };
    let (last_key, _) = fields.pop().unwrap();
    assert_eq!(last_key, "observer_uniform_layout");
    assert_eq!(Value::Object(fields), json::parse(&program.reflection.to_json()).unwrap());
    let cloned = program.clone();
    drop(program);
    assert_eq!(stage_blocks(&cloned, StageKind::Vertex)[0].name, "VertexOnly", "metadata outlives the compiler module and program clone source");
}

struct NoModule;

impl StageCompiler for NoModule {
    fn compile(&self, kind: StageKind, _stage: &LegalStage) -> Result<CompiledStage, ShaderError> {
        // Deliberate injected test compiler, never claimed as native/compiler evidence.
        Ok(CompiledStage {
            payload: StagePayload::new(kind, "test payload".into(), "test_entry".into(), Vec::new()),
            translated: None,
            diagnostics: Vec::new(),
        })
    }
}

struct EmptyReflection;

impl StageReflector for EmptyReflection {
    fn reflect(&self, _kind: StageKind, _stage: &CompiledStage, _names: &InputNames) -> Result<Reflection, ShaderError> {
        Ok(Reflection::default())
    }
}

#[test]
fn unavailable_compiler_module_is_explicit_without_breaking_injected_pipeline_success() {
    let request = Req::new(PASS_VERTEX, PASS_FRAGMENT).build();
    let program = Pipeline { compiler: &NoModule, reflector: &EmptyReflection }.compile(&request, &NoIncludes).unwrap();
    for stage in &program.stages {
        assert_eq!(stage.uniform_layout.blocks, Observation::Unavailable(Unavailable::TranslatedModuleAbsent));
        assert_eq!(stage.uniform_layout.source_entry_point, None);
        assert!(!stage.uniform_layout.is_complete());
    }
    let text = reflection_json(&program);
    let document = json::parse(&text).unwrap();
    let Value::Array(stages) = field(field(&document, "observer_uniform_layout"), "stages") else { panic!() };
    for stage in stages {
        assert_eq!(field(stage, "complete"), &Value::Bool(false));
        assert_eq!(field(field(stage, "blocks"), "reason"), &Value::String("translated_module_absent".into()));
    }
    assert!(!text.contains("\"byte_span\"") && !text.contains("\"scalar\""), "no fabricated zero/scalar layout");
}

fn ty(module: &mut naga::Module, inner: TypeInner) -> naga::Handle<naga::Type> {
    module.types.insert(naga::Type { name: None, inner }, naga::Span::UNDEFINED)
}

fn array(module: &mut naga::Module, base: naga::Handle<naga::Type>, count: u32, stride: u32) -> naga::Handle<naga::Type> {
    ty(module, TypeInner::Array { base, size: ArraySize::Constant(NonZeroU32::new(count).unwrap()), stride })
}

#[test]
fn nested_ir_array_dimensions_are_retained_outermost_first_without_expansion() {
    let mut module = naga::Module::default();
    let scalar = ty(&mut module, TypeInner::Scalar(naga::Scalar::I32));
    let inner = array(&mut module, scalar, 3, 16);
    let outer = array(&mut module, inner, 2, 48);
    let observed = physical_type(&module, outer).unwrap();
    assert_eq!(observed.scalar, PhysicalScalar { base: ScalarBase::Signed, byte_width: 4 });
    assert_eq!(observed.element_shape, ElementShape::Scalar);
    assert_eq!(observed.arrays, [ArrayDimension { count: 2, stride: 48 }, ArrayDimension { count: 3, stride: 16 }]);
    let member = naga::StructMember { name: Some("nested".into()), ty: outer, binding: None, offset: 16 };
    assert_eq!(available(&member_layout(&module, &member)).byte_span, 96);
}

#[test]
fn unsupported_or_unresolved_ir_types_are_unavailable_not_zero_sized_scalars() {
    let mut module = naga::Module::default();
    let structure = ty(&mut module, TypeInner::Struct { members: Vec::new(), span: 16 });
    let scalar = ty(&mut module, TypeInner::Scalar(naga::Scalar::F32));
    let dynamic_array = ty(&mut module, TypeInner::Array { base: scalar, size: ArraySize::Dynamic, stride: 16 });
    for (handle, reason) in [(structure, Unavailable::UnsupportedType), (dynamic_array, Unavailable::NonConstantArray)] {
        let member = naga::StructMember { name: None, ty: handle, binding: None, offset: 0 };
        let observed = member_layout(&module, &member);
        assert_eq!(observed, Observation::Unavailable(reason));
        let text = observed.to_json(|_| panic!("an unavailable observation must not encode a physical value"));
        assert!(!text.contains("\"value\"") && !text.contains("\"byte_span\""));
    }
}

#[test]
fn retention_limits_are_explicit_and_do_not_silently_truncate_dimensions_or_names() {
    let mut module = naga::Module::default();
    let mut current = ty(&mut module, TypeInner::Scalar(naga::Scalar::U32));
    for _ in 0..MAX_ARRAY_DIMENSIONS {
        current = array(&mut module, current, 1, 16);
    }
    assert_eq!(physical_type(&module, current).unwrap().arrays.len(), MAX_ARRAY_DIMENSIONS);
    current = array(&mut module, current, 1, 16);
    assert_eq!(physical_type(&module, current), Err(Unavailable::ObservationLimit));
    let mut budget = Budget::default();
    assert_eq!(budget.name(&"a".repeat(MAX_NAME_BYTES)).unwrap().len(), MAX_NAME_BYTES);
    assert_eq!(budget.name("b"), Err(Unavailable::ObservationLimit));
}

#[test]
fn signed_unsigned_and_boolean_vectors_keep_the_translated_scalar_base_and_width() {
    let fragment = "uniform ivec2 g_I; uniform uvec3 g_U; uniform bvec2 g_B;\n\
        void main() { gl_FragColor = vec4(float(g_I.x) + float(g_U.z) + (g_B.x ? 1.0 : 0.0)); }";
    let program = Req::new(PASS_VERTEX, fragment).ok();
    let block = &stage_blocks(&program, StageKind::Fragment)[0];
    for (name, base, components, byte_span) in [
        ("g_I", ScalarBase::Signed, 2, 8),
        ("g_U", ScalarBase::Unsigned, 3, 12),
        ("g_B", ScalarBase::Unsigned, 2, 8),
    ] {
        let observed = layout(block, name);
        assert_eq!(observed.ty.scalar, PhysicalScalar { base, byte_width: 4 });
        assert_eq!(observed.ty.element_shape, ElementShape::Vector { components });
        assert_eq!(observed.byte_span, byte_span);
        assert!(observed.ty.arrays.is_empty());
    }
}

#[test]
fn absent_selected_entry_is_unavailable_not_an_empty_successful_layout() {
    let compiled = compile_glsl(StageKind::Fragment, "#version 450\nlayout(location = 0) out vec4 colour; void main() { colour = vec4(1.0); }").unwrap();
    let retained = retain(StageKind::Vertex, &compiled);
    assert_eq!(retained.blocks, Observation::Unavailable(Unavailable::EntryPointAbsent));
    assert_eq!(retained.source_entry_point, None);
    assert!(!retained.is_complete());
}
