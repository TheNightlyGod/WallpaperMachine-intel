use shader::{
    CompiledStageArtifact, MetalSlotKind, MetalStageCode, ShaderCompiler, ShaderError,
    ShaderStageKind, ShaderTarget, compile::NagaCompiler, legalize::CodegenStageSource,
};

/// Legalized textured-quad vertex stage, in the form the codegen pass emits.
const TEXTURED_QUAD_VERTEX: &str = r"#version 450
layout(location = 0) in vec2 a_Position;
layout(location = 1) in vec2 a_TexCoord;
layout(location = 0) out vec2 v_TexCoord;
void main() {
    v_TexCoord = a_TexCoord;
    gl_Position = vec4(a_Position, 0.0, 1.0);
}
";

/// Legalized textured-quad fragment stage with a uniform block, a sampled
/// texture, and the separate sampler the codegen pass generates for it.
const TEXTURED_QUAD_FRAGMENT: &str = r"#version 450
layout(set = 0, binding = 0) uniform texture2D g_Texture0;
layout(set = 0, binding = 1) uniform sampler _we_Sampler_g_Texture0;
layout(set = 0, binding = 2) uniform Globals {
    vec4 g_Color;
    vec2 g_TexelSize;
} u_Globals;
layout(location = 0) in vec2 v_TexCoord;
layout(location = 0) out vec4 frag_color;
void main() {
    frag_color = texture(sampler2D(g_Texture0, _we_Sampler_g_Texture0),
                         v_TexCoord + u_Globals.g_TexelSize) * u_Globals.g_Color;
}
";

#[test]
fn textured_quad_program_compiles_to_metal_source() {
    let vertex = compile_metal(ShaderStageKind::Vertex, TEXTURED_QUAD_VERTEX);
    let fragment = compile_metal(ShaderStageKind::Fragment, TEXTURED_QUAD_FRAGMENT);

    assert_eq!(vertex.language_version(), (2, 0));
    assert!(
        vertex.source().contains("#include <metal_stdlib>"),
        "{}",
        vertex.source()
    );

    // Naga renames entry points, so the reported name is the only thing the
    // renderer may look up; assert the report matches the emitted source.
    assert_ne!(vertex.entry_point(), "main");
    assert!(
        vertex
            .source()
            .contains(&format!("vertex main_Output {}(", vertex.entry_point())),
        "vertex entry point `{}` should be declared in the emitted source:\n{}",
        vertex.entry_point(),
        vertex.source()
    );
    assert!(
        fragment
            .source()
            .contains(&format!("fragment main_Output {}(", fragment.entry_point())),
        "fragment entry point `{}` should be declared in the emitted source:\n{}",
        fragment.entry_point(),
        fragment.source()
    );

    assert!(
        vertex
            .source()
            .contains("metal::float2 a_Position [[attribute(0)]]"),
        "vertex inputs should keep their declared locations:\n{}",
        vertex.source()
    );
    assert!(
        fragment.source().contains(
            "metal::texture2d<float, metal::access::sample> g_Texture0_ [[texture(0)]]"
        ),
        "sampled texture should be declared at its mapped texture slot:\n{}",
        fragment.source()
    );
    assert!(
        fragment
            .source()
            .contains("metal::sampler _we_Sampler_g_Texture0_ [[sampler(1)]]"),
        "generated sampler should be declared at its mapped sampler slot:\n{}",
        fragment.source()
    );
    assert!(
        fragment
            .source()
            .contains("constant Globals& u_Globals [[buffer(2)]]"),
        "uniform block should be declared at its mapped buffer slot:\n{}",
        fragment.source()
    );
}

#[test]
fn uniform_block_and_texture_get_distinct_deterministic_slots() {
    let first = compile_metal(ShaderStageKind::Fragment, TEXTURED_QUAD_FRAGMENT);
    let second = compile_metal(ShaderStageKind::Fragment, TEXTURED_QUAD_FRAGMENT);

    assert_eq!(
        binding_summary(&first),
        binding_summary(&second),
        "the metal binding map must be deterministic for identical input"
    );
    assert_eq!(
        binding_summary(&first),
        vec![
            ("g_Texture0".to_owned(), 0, MetalSlotKind::Texture, 0),
            (
                "_we_Sampler_g_Texture0".to_owned(),
                1,
                MetalSlotKind::Sampler,
                1
            ),
            ("u_Globals".to_owned(), 2, MetalSlotKind::Buffer, 2),
        ],
        "every metal slot must equal the resource's SPIR-V binding index"
    );

    let mut slots = first
        .bindings()
        .iter()
        .map(|binding| (binding.slot_kind(), binding.slot()))
        .collect::<Vec<_>>();
    let slot_count = slots.len();
    slots.sort_unstable();
    slots.dedup();
    assert_eq!(
        slots.len(),
        slot_count,
        "two resources must never share one metal argument-table slot"
    );

    for binding in first.bindings() {
        assert_eq!(binding.set(), 0);
    }
}

#[test]
fn global_outside_descriptor_set_zero_fails_instead_of_emitting_a_shader() {
    let source = r"#version 450
layout(set = 1, binding = 0) uniform texture2D g_Texture0;
layout(set = 0, binding = 1) uniform sampler _we_Sampler_g_Texture0;
layout(location = 0) in vec2 v_TexCoord;
layout(location = 0) out vec4 frag_color;
void main() {
    frag_color = texture(sampler2D(g_Texture0, _we_Sampler_g_Texture0), v_TexCoord);
}
";

    let message = compile_metal_error(ShaderStageKind::Fragment, source);

    assert!(
        message.contains("metal binding map cannot cover global `g_Texture0`"),
        "{message}"
    );
    assert!(message.contains("descriptor set 1"), "{message}");
}

#[test]
fn sampler_binding_beyond_the_argument_table_fails_instead_of_emitting_a_shader() {
    let source = r"#version 450
layout(set = 0, binding = 0) uniform texture2D g_Texture0;
layout(set = 0, binding = 16) uniform sampler _we_Sampler_g_Texture0;
layout(location = 0) in vec2 v_TexCoord;
layout(location = 0) out vec4 frag_color;
void main() {
    frag_color = texture(sampler2D(g_Texture0, _we_Sampler_g_Texture0), v_TexCoord);
}
";

    let error = NagaCompiler
        .compile_stage(
            ShaderTarget::MetalMsl,
            ShaderStageKind::Fragment,
            &legalized_source(ShaderStageKind::Fragment, source),
        )
        .expect_err("a slot outside the metal argument table must fail the compile");

    let ShaderError::Reflection { message } = error else {
        panic!("expected a reflection error for an unrepresentable metal slot");
    };
    assert!(
        message.contains("metal sampler slot 16 for `_we_Sampler_g_Texture0`"),
        "{message}"
    );
    assert!(message.contains("argument-table limit of 15"), "{message}");
}

#[test]
fn metal_output_does_not_adjust_clip_space_or_texture_origin() {
    let vertex = compile_metal(ShaderStageKind::Vertex, TEXTURED_QUAD_VERTEX);

    assert!(!vertex.conventions().clip_space_y_flipped());
    assert!(!vertex.conventions().clip_space_depth_remapped());
    assert!(!vertex.conventions().texture_origin_flipped());
    assert!(
        vertex
            .source()
            .contains("gl_Position = metal::float4(_e5.x, _e5.y, 0.0, 1.0);"),
        "the author's clip-space position must reach metal unmodified:\n{}",
        vertex.source()
    );
}

#[test]
fn metal_and_spirv_targets_produce_mutually_exclusive_code_for_one_source() {
    let source = legalized_source(ShaderStageKind::Fragment, TEXTURED_QUAD_FRAGMENT);

    let spirv = NagaCompiler
        .compile_stage(
            ShaderTarget::VulkanSpirv,
            ShaderStageKind::Fragment,
            &source,
        )
        .expect("fragment shader should compile to SPIR-V");
    let metal = NagaCompiler
        .compile_stage(ShaderTarget::MetalMsl, ShaderStageKind::Fragment, &source)
        .expect("fragment shader should compile to MSL");

    assert_eq!(spirv.stage().target(), ShaderTarget::VulkanSpirv);
    assert_eq!(metal.stage().target(), ShaderTarget::MetalMsl);
    assert!(spirv.stage().metal().is_none());
    assert!(metal.stage().spirv().is_none());
    assert_eq!(
        spirv.stage().legalized_source(),
        metal.stage().legalized_source(),
        "both targets must be generated from the same legalized source"
    );
}

fn compile_metal(stage: ShaderStageKind, source: &str) -> MetalStageCode {
    let artifact = NagaCompiler
        .compile_stage(
            ShaderTarget::MetalMsl,
            stage,
            &legalized_source(stage, source),
        )
        .unwrap_or_else(|error| {
            panic!(
                "{stage:?} shader should compile to MSL: {}",
                error.to_miette_report()
            )
        });
    metal(&artifact).clone()
}

fn compile_metal_error(stage: ShaderStageKind, source: &str) -> String {
    let error = NagaCompiler
        .compile_stage(
            ShaderTarget::MetalMsl,
            stage,
            &legalized_source(stage, source),
        )
        .expect_err("an uncoverable global must fail the compile");

    let ShaderError::Compile { diagnostics } = error else {
        panic!("expected a compile diagnostic error");
    };
    diagnostics
        .first()
        .expect("compile error should carry a diagnostic")
        .message()
        .to_owned()
}

fn metal<M>(artifact: &CompiledStageArtifact<M>) -> &MetalStageCode {
    artifact
        .stage()
        .metal()
        .expect("metal_msl target should produce Metal source")
}

fn legalized_source(stage: ShaderStageKind, source: &str) -> CodegenStageSource {
    CodegenStageSource::new(stage, source.to_owned(), Box::from([]))
}

fn binding_summary(metal: &MetalStageCode) -> Vec<(String, u32, MetalSlotKind, u32)> {
    metal
        .bindings()
        .iter()
        .map(|binding| {
            (
                binding.name().as_str().to_owned(),
                binding.binding(),
                binding.slot_kind(),
                binding.slot(),
            )
        })
        .collect()
}

/// Author-shaped scalar uniform array, next to the members that follow it.
const AUTHOR_SPECTRUM: &str = r"
uniform float g_AudioSpectrum64Left[64];
uniform float u_ReduceValue;
uniform vec2 u_FixedSize;
varying vec2 v_TexCoord;
void main() {
    float v = g_AudioSpectrum64Left[0] / u_ReduceValue;
    gl_FragColor = vec4(v, u_FixedSize.x, v_TexCoord.x, 1.0);
}
";

#[test]
fn scalar_uniform_arrays_keep_one_layout_on_both_targets() {
    // std140 pads every array element to 16 bytes, which is what the host packs
    // and the reflection reports. Metal's natural layout for `float[64]` is a
    // tight 4-byte stride, and the shader compiler emits it that way, so a
    // scalar array in a uniform block moved every member after it by 768 bytes
    // on one renderer and not the other. Declaring the member `vec4[N]` is the
    // only spelling both layouts agree on.
    let module = shader::syntax::ShaderModule::parse(ShaderStageKind::Fragment, AUTHOR_SPECTRUM)
        .expect("author source parses");
    let legalized = shader::legalize::Codegen
        .legalize(&module)
        .expect("author source legalizes");
    let source = legalized.source();

    assert!(
        source.contains("vec4 g_AudioSpectrum64Left[64];"),
        "{source}"
    );
    assert!(
        source.contains("g_AudioSpectrum64Left[0].x / u_ReduceValue"),
        "{source}"
    );

    let artifact = NagaCompiler
        .compile_stage(
            ShaderTarget::MetalMsl,
            ShaderStageKind::Fragment,
            &legalized,
        )
        .expect("legalized author source compiles to MSL");
    let msl = metal(&artifact).source().to_owned();
    assert!(msl.contains("metal::float4 inner[64];"), "{msl}");
    assert!(!msl.contains("float inner[64];"), "{msl}");
}

/// Author-shaped vertex stage inverting one matrix of every square size, the
/// way the stock perspective-warping effects undo `squareToQuad`.
const AUTHOR_MATRIX_INVERSE: &str = r"
uniform vec2 g_Point0;
uniform vec2 g_Point1;
uniform vec2 g_Point2;
uniform vec4 g_Shear;
attribute vec3 a_Position;
attribute vec2 a_TexCoord;
varying vec4 v_TexCoord;

mat3 squareToQuad(vec2 p0, vec2 p1, vec2 p2) {
    return mat3(vec3(p1 - p0, 0.0), vec3(p2 - p0, 0.0), vec3(p0, 1.0));
}

void main() {
    mat3 xform = inverse(squareToQuad(g_Point0, g_Point1, g_Point2));
    vec3 uvw = xform * vec3(a_TexCoord, 1.0);
    mat2 shear = inverse(mat2(1.0, g_Shear.x, g_Shear.y, 1.0));
    mat4 frame = inverse(mat4(vec4(g_Shear.z, 0.0, 0.0, 0.0), vec4(0.0, g_Shear.w, 0.0, 0.0),
                              vec4(0.0, 0.0, 1.0, 0.0), vec4(g_Point0, 0.0, 1.0)));
    v_TexCoord = vec4(shear * (uvw.xy / uvw.z), 0.0, 1.0);
    gl_Position = frame * vec4(a_Position, 1.0);
}
";

/// `GLSL.std.450` extended instruction number of `MatrixInverse`.
const GLSL_STD_450_MATRIX_INVERSE: u32 = 34;

#[test]
fn matrix_inverse_of_every_square_size_compiles_to_metal_and_stays_native_in_spirv() {
    // Naga's MSL writer has no `inverse`, so any stage that inverts a matrix
    // failed to translate and the native Metal renderer dropped the whole
    // effect (the stock perspective, lightshafts, reflection, clouds and
    // waterwaves effects among them), while the same stage drew under Vulkan.
    let module =
        shader::syntax::ShaderModule::parse(ShaderStageKind::Vertex, AUTHOR_MATRIX_INVERSE)
            .expect("author source parses");
    let legalized = shader::legalize::Codegen
        .legalize(&module)
        .expect("author source legalizes");

    let metal_artifact = NagaCompiler
        .compile_stage(ShaderTarget::MetalMsl, ShaderStageKind::Vertex, &legalized)
        .unwrap_or_else(|error| {
            panic!(
                "a stage that inverts matrices must translate to MSL: {}\n{}",
                error.to_miette_report(),
                legalized.source()
            )
        });
    assert!(
        !metal(&metal_artifact).source().contains("inverse("),
        "no builtin inverse may reach the metal source:\n{}",
        metal(&metal_artifact).source()
    );

    // SPIR-V keeps the driver's own MatrixInverse for each call and gains no
    // generated function over the same program without the inversions:
    // Vulkan output is what it was before the repair.
    let words = vertex_spirv(AUTHOR_MATRIX_INVERSE);
    let uninverted = vertex_spirv(&AUTHOR_MATRIX_INVERSE.replace("inverse(", "("));
    assert_eq!(
        spirv_instructions(&words, SPIRV_OP_FUNCTION).count(),
        spirv_instructions(&uninverted, SPIRV_OP_FUNCTION).count(),
        "no generated function may reach SPIR-V"
    );
    assert_eq!(
        spirv_instructions(&words, SPIRV_OP_EXT_INST)
            .filter(|operands| operands.get(3) == Some(&GLSL_STD_450_MATRIX_INVERSE))
            .count(),
        3
    );
}

/// Legalizes an author vertex stage and compiles it to SPIR-V words.
fn vertex_spirv(source: &str) -> Vec<u32> {
    let module = shader::syntax::ShaderModule::parse(ShaderStageKind::Vertex, source)
        .expect("author source parses");
    let legalized = shader::legalize::Codegen
        .legalize(&module)
        .expect("author source legalizes");
    NagaCompiler
        .compile_stage(
            ShaderTarget::VulkanSpirv,
            ShaderStageKind::Vertex,
            &legalized,
        )
        .expect("the stage compiles to SPIR-V")
        .stage()
        .spirv()
        .expect("vulkan_spirv target should produce SPIR-V words")
        .to_vec()
}

/// SPIR-V `OpFunction` opcode.
const SPIRV_OP_FUNCTION: u16 = 54;
/// SPIR-V `OpExtInst` opcode.
const SPIRV_OP_EXT_INST: u16 = 12;

/// Yields the operand words of every instruction with `opcode`.
fn spirv_instructions(words: &[u32], opcode: u16) -> impl Iterator<Item = &[u32]> {
    let mut index = 5;
    std::iter::from_fn(move || {
        while index < words.len() {
            let word_count = (words[index] >> 16) as usize;
            let instruction_opcode = (words[index] & 0xffff) as u16;
            if word_count == 0 || index + word_count > words.len() {
                return None;
            }
            let operands = &words[index + 1..index + word_count];
            index += word_count;
            if instruction_opcode == opcode {
                return Some(operands);
            }
        }
        None
    })
}

/// The `mat3 inverse(mat3)` Wallpaper Engine's `common_perspective.h` declares
/// for the Direct3D dialect, which has no matrix `inverse` of its own.
const AUTHOR_INVERSE_POLYFILL: &str = r"
mat3 inverse(mat3 m) {
    float a00 = m[0][0], a01 = m[0][1], a02 = m[0][2];
    float a10 = m[1][0], a11 = m[1][1], a12 = m[1][2];
    float a20 = m[2][0], a21 = m[2][1], a22 = m[2][2];
    float b01 = a22 * a11 - a12 * a21;
    float b11 = -a22 * a10 + a12 * a20;
    float b21 = a21 * a10 - a11 * a20;
    float det = a00 * b01 + a01 * b11 + a02 * b21;
    return mat3(b01, (-a22 * a01 + a02 * a21), (a12 * a01 - a02 * a11),
                b11, (a22 * a00 - a02 * a20), (-a12 * a00 + a02 * a10),
                b21, (-a21 * a00 + a01 * a20), (a11 * a00 - a01 * a10)) / det;
}
";

#[test]
fn a_stage_declaring_its_own_matrix_inverse_compiles_on_both_targets_and_calls_it() {
    // `#if HLSL` is true now, so the polyfill is part of the source. A function
    // with a builtin's name and parameters is the author's own: both targets
    // call it, Metal needs no generated helper, and SPIR-V keeps no
    // `MatrixInverse` of its own.
    let source = format!(
        "uniform vec2 g_Point0;\n\
         uniform vec2 g_Point1;\n\
         uniform vec2 g_Point2;\n\
         attribute vec3 a_Position;\n\
         attribute vec2 a_TexCoord;\n\
         varying vec3 v_TexCoord;\n\
         {AUTHOR_INVERSE_POLYFILL}\
         void main() {{\n\
             mat3 square = mat3(vec3(g_Point1 - g_Point0, 0.0), vec3(g_Point2 - g_Point0, 0.0), \
                                vec3(g_Point0, 1.0));\n\
             v_TexCoord = inverse(square) * vec3(a_TexCoord, 1.0);\n\
             gl_Position = vec4(a_Position, 1.0);\n\
         }}\n"
    );
    let module = shader::syntax::ShaderModule::parse(ShaderStageKind::Vertex, &source)
        .expect("author source parses");
    let legalized = shader::legalize::Codegen
        .legalize(&module)
        .expect("author source legalizes");
    let metal_artifact = NagaCompiler
        .compile_stage(ShaderTarget::MetalMsl, ShaderStageKind::Vertex, &legalized)
        .unwrap_or_else(|error| {
            panic!("the stage must translate to MSL: {}\n{}", error.to_miette_report(), legalized.source())
        });
    assert!(
        !legalized.source().contains("_we_Inverse"),
        "no generated helper may stand in for the author's function:\n{}",
        legalized.source()
    );
    assert!(!metal(&metal_artifact).source().is_empty());
    assert_eq!(
        spirv_instructions(&vertex_spirv(&source), SPIRV_OP_EXT_INST)
            .filter(|operands| operands.get(3) == Some(&GLSL_STD_450_MATRIX_INVERSE))
            .count(),
        0
    );
}

#[test]
fn a_redeclared_vertex_and_instance_index_reach_metal_as_builtins_not_attributes() {
    // `in uint gl_VertexID;` compiled as a vertex attribute at the next free
    // location, so a morph target offset read vertex data instead of the
    // vertex index. Both spellings must end up as the stage's own builtins.
    let source = concat!(
        "attribute vec3 a_Position;\n",
        "in uint gl_VertexID;\n",
        "in uint gl_InstanceID;\n",
        "uniform uint g_MorphOffsets[4];\n",
        "varying float v_Shell;\n",
        "void main() {\n",
        "    uint morphMapOffset = gl_VertexID + g_MorphOffsets[1u];\n",
        "    v_Shell = float(gl_InstanceID) / 3.0 + float(morphMapOffset % 4u);\n",
        "    gl_Position = vec4(a_Position, 1.0);\n",
        "}\n",
    );
    let module = shader::syntax::ShaderModule::parse(ShaderStageKind::Vertex, source)
        .expect("author source parses");
    let legalized = shader::legalize::Codegen
        .legalize(&module)
        .expect("author source legalizes");

    let artifact = NagaCompiler
        .compile_stage(ShaderTarget::MetalMsl, ShaderStageKind::Vertex, &legalized)
        .unwrap_or_else(|error| {
            panic!(
                "the stage must translate to MSL: {}\n{}",
                error.to_miette_report(),
                legalized.source()
            )
        });
    let msl = metal(&artifact).source();
    assert!(msl.contains("[[vertex_id]]"), "{msl}");
    assert!(msl.contains("[[instance_id]]"), "{msl}");
    assert!(msl.contains("[[attribute(0)]]"), "{msl}");
    assert!(
        !msl.contains("[[attribute(1)]]"),
        "no second vertex attribute may stand in for a builtin:\n{msl}"
    );

    let spirv = vertex_spirv(source);
    assert_eq!(
        spirv_instructions(&spirv, SPIRV_OP_DECORATE)
            .filter(|operands| {
                operands.get(1) == Some(&SPIRV_DECORATION_BUILTIN)
                    && matches!(
                        operands.get(2),
                        Some(&SPIRV_BUILTIN_VERTEX_INDEX | &SPIRV_BUILTIN_INSTANCE_INDEX)
                    )
            })
            .count(),
        2,
        "SPIR-V takes the vertex and instance index from the builtins"
    );
}

/// SPIR-V `OpDecorate` opcode.
const SPIRV_OP_DECORATE: u16 = 71;
/// SPIR-V `Decoration::BuiltIn`.
const SPIRV_DECORATION_BUILTIN: u32 = 11;
/// SPIR-V `BuiltIn::VertexIndex`.
const SPIRV_BUILTIN_VERTEX_INDEX: u32 = 42;
/// SPIR-V `BuiltIn::InstanceIndex`.
const SPIRV_BUILTIN_INSTANCE_INDEX: u32 = 43;
