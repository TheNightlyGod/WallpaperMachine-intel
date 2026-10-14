use shader::{
    CompiledStageArtifact, ShaderCompiler, ShaderError, ShaderStageKind, ShaderTarget,
    compile::NagaCompiler,
    legalize::{Codegen, CodegenStageSource},
    syntax::ShaderModule,
};

const SPIRV_MAGIC: u32 = 0x0723_0203;
const SPIRV_OP_FNEGATE: u16 = 127;
const SPIRV_OP_VECTOR_TIMES_MATRIX: u16 = 144;
const SPIRV_OP_MATRIX_TIMES_VECTOR: u16 = 145;

#[test]
fn compiles_legalized_vertex_shader_to_spirv() {
    let source_text = r"#version 450
layout(location = 0) in vec2 a_position;
void main() {
    gl_Position = vec4(a_position, 0.0, 1.0);
}
";
    let source = legalized_source(ShaderStageKind::Vertex, source_text);

    let artifact = NagaCompiler
        .compile_stage(ShaderTarget::VulkanSpirv, ShaderStageKind::Vertex, &source)
        .expect("legalized vertex shader should compile");

    assert_eq!(artifact.kind(), ShaderStageKind::Vertex);
    assert_eq!(artifact.stage().kind(), ShaderStageKind::Vertex);
    assert_eq!(
        artifact.stage().spirv().and_then(<[u32]>::first),
        Some(&SPIRV_MAGIC)
    );
    assert_eq!(artifact.stage().legalized_source(), Some(source_text));
    assert_eq!(artifact.module().entry_points.len(), 1);
    assert!(artifact.diagnostics().is_empty());
    assert!(artifact.stage().diagnostics().is_empty());
}

#[test]
fn vertex_spirv_does_not_inject_coordinate_space_y_flip() {
    let source_text = r"#version 450
layout(location = 0) in vec2 a_position;
void main() {
    gl_Position = vec4(a_position, 0.0, 1.0);
}
";
    let source = legalized_source(ShaderStageKind::Vertex, source_text);

    let artifact = NagaCompiler
        .compile_stage(ShaderTarget::VulkanSpirv, ShaderStageKind::Vertex, &source)
        .expect("legalized vertex shader should compile");

    assert!(
        !spirv_contains_opcode(spirv(&artifact), SPIRV_OP_FNEGATE),
        "vertex SPIR-V must not contain Naga's BuiltIn::Position coordinate-space Y flip"
    );
}

#[test]
fn hlsl_mul_mvp_transform_emits_matrix_times_vector_spirv() {
    let source_text = r"attribute vec3 a_Position;
uniform mat4 g_ModelViewProjectionMatrix;
void main() {
    gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
}
";
    let module = ShaderModule::parse(ShaderStageKind::Vertex, source_text).expect("module parses");
    let source = Codegen
        .legalize(&module)
        .expect("HLSL mul vertex shader legalizes");

    assert!(
        source
            .source()
            .contains("gl_Position = ((g_ModelViewProjectionMatrix) * (vec4(a_Position, 1.0)));"),
        "{}",
        source.source()
    );

    let artifact = NagaCompiler
        .compile_stage(ShaderTarget::VulkanSpirv, ShaderStageKind::Vertex, &source)
        .expect("legalized HLSL mul vertex shader should compile");

    assert!(
        spirv_contains_opcode(spirv(&artifact), SPIRV_OP_MATRIX_TIMES_VECTOR),
        "MVP transform should match known-good shader-cache/proper SPIR-V OpMatrixTimesVector"
    );
    assert!(
        !spirv_contains_opcode(spirv(&artifact), SPIRV_OP_VECTOR_TIMES_MATRIX),
        "MVP transform must not regress to OpVectorTimesMatrix"
    );
}

#[test]
fn compiles_legacy_vertex_shader_with_array_varying_output() {
    let source_text = r"attribute vec3 a_Position;
attribute vec2 a_TexCoord;
uniform vec2 g_TexelSize;
varying vec2 v_TexCoord[4];
void main() {
    gl_Position = vec4(a_Position, 1.0);
    v_TexCoord[0] = a_TexCoord - g_TexelSize;
    v_TexCoord[1] = a_TexCoord + g_TexelSize;
    v_TexCoord[2] = a_TexCoord + vec2(-g_TexelSize.x, g_TexelSize.y);
    v_TexCoord[3] = a_TexCoord + vec2(g_TexelSize.x, -g_TexelSize.y);
}
";
    let module = ShaderModule::parse(ShaderStageKind::Vertex, source_text).expect("module parses");
    let source = Codegen
        .legalize(&module)
        .expect("array varying shader legalizes");

    assert!(
        source
            .source()
            .contains("layout(location = 0) out vec2 v_TexCoord[4];")
    );

    let artifact = NagaCompiler
        .compile_stage(ShaderTarget::VulkanSpirv, ShaderStageKind::Vertex, &source)
        .expect("legalized bloom vertex shader with array varying should compile");

    assert_eq!(artifact.kind(), ShaderStageKind::Vertex);
    assert_eq!(artifact.module().entry_points.len(), 1);
}

#[test]
fn compiles_legalized_fragment_shader_to_spirv() {
    let source_text = r"#version 450
layout(location = 0) out vec4 frag_color;
void main() {
    frag_color = vec4(1.0, 0.0, 0.0, 1.0);
}
";
    let source = legalized_source(ShaderStageKind::Fragment, source_text);

    let artifact = NagaCompiler
        .compile_stage(ShaderTarget::VulkanSpirv, ShaderStageKind::Fragment, &source)
        .expect("legalized fragment shader should compile");

    assert_eq!(artifact.kind(), ShaderStageKind::Fragment);
    assert_eq!(artifact.stage().kind(), ShaderStageKind::Fragment);
    assert_eq!(
        artifact.stage().spirv().and_then(<[u32]>::first),
        Some(&SPIRV_MAGIC)
    );
    assert_eq!(artifact.stage().legalized_source(), Some(source_text));
    assert_eq!(artifact.module().entry_points.len(), 1);
    assert!(artifact.diagnostics().is_empty());
    assert!(artifact.stage().diagnostics().is_empty());
}

#[test]
fn compiles_legacy_fragment_with_scalar_expression_vector_max() {
    let source_text = r"float luma(vec3 color) {
    return dot(color, vec3(0.299, 0.587, 0.114));
}
void main() {
    vec3 color = vec3(1.25, 1.0, 0.75);
    color += max(luma(color) - 1.0, vec3(0.0));
    gl_FragColor = vec4(color, 1.0);
}
";
    let module =
        ShaderModule::parse(ShaderStageKind::Fragment, source_text).expect("module parses");
    let source = Codegen
        .legalize(&module)
        .expect("scalar expression vector max shader legalizes");

    assert!(
        source
            .source()
            .contains("color += max(vec3(luma(color) - 1.0), vec3(0.0));")
    );

    let artifact = NagaCompiler
        .compile_stage(ShaderTarget::VulkanSpirv, ShaderStageKind::Fragment, &source)
        .expect("scalar expression vector max shader should compile");

    assert_eq!(artifact.kind(), ShaderStageKind::Fragment);
    assert_eq!(artifact.module().entry_points.len(), 1);
}

#[test]
fn failure_diagnostics_preserve_stage_path_and_source_snippet() {
    let source_text = r"#version 450
layout(location = 0) out vec4 frag_color;
void main() {
    frag_color = missing_value;
}
";
    let source = legalized_source(ShaderStageKind::Fragment, source_text);

    let err = NagaCompiler
        .compile_stage(ShaderTarget::VulkanSpirv, ShaderStageKind::Fragment, &source)
        .expect_err("unknown GLSL symbol should fail compilation");

    let ShaderError::Compile { diagnostics } = err else {
        panic!("expected compile diagnostics");
    };
    let diagnostic = diagnostics
        .first()
        .expect("compile failure should contain a diagnostic");

    assert_eq!(diagnostic.stage(), Some(ShaderStageKind::Fragment));
    assert_eq!(diagnostic.pass(), Some("naga glsl parse"));
    assert_eq!(
        diagnostic.generated_source_path(),
        Some("generated/fragment.glsl")
    );
    assert!(diagnostic.message().contains("missing_value"));
    assert!(diagnostic.message().contains("generated/fragment.glsl"));
    assert!(diagnostic.message().contains("frag_color = missing_value;"));
    assert!(diagnostic.span().is_some());
}

#[test]
fn global_const_initialized_from_a_uniform_is_evaluated_before_main_reads_it() {
    // A global initializer that reads a uniform is no constant expression, so
    // a strict frontend rejects it. The permissive path evaluates it once the
    // uniforms are bound, before any code reads the global.
    let source_text = concat!(
        "uniform float u_Feather;\n",
        "const float FEATHER = u_Feather * 0.5;\n",
        "const float SPAN = FEATHER * 2.0;\n",
        "float edge(float x) { return smoothstep(0.5 - FEATHER, 0.5 + SPAN, x); }\n",
        "void main() { gl_FragColor = vec4(edge(0.25)); }\n",
    );

    for target in [ShaderTarget::VulkanSpirv, ShaderTarget::MetalMsl] {
        let artifact = compile_fragment(target, source_text);
        assert_eq!(
            runtime_global_stores(artifact.module(), &["FEATHER", "SPAN"]),
            ["FEATHER", "SPAN"],
            "{target:?}: both globals must be written, in declaration order"
        );
    }
}

#[test]
fn global_variable_initialized_from_a_uniform_keeps_its_value() {
    // The frontend accepts a mutable global with such an initializer but
    // silently drops the initializer, which reads as zero everywhere.
    let source_text = concat!(
        "uniform vec4 g_Texture0Resolution;\n",
        "vec2 texel = 1.0 / g_Texture0Resolution.xy;\n",
        "void main() { gl_FragColor = vec4(texel, 0.0, 1.0); }\n",
    );

    for target in [ShaderTarget::VulkanSpirv, ShaderTarget::MetalMsl] {
        let artifact = compile_fragment(target, source_text);
        assert_eq!(
            runtime_global_stores(artifact.module(), &["texel"]),
            ["texel"],
            "{target:?}: the initializer must still be applied"
        );
    }
}

#[test]
fn constant_global_initializers_stay_constant_expressions() {
    // Array sizes need a constant expression, so only initializers that read
    // runtime values move.
    let source_text = concat!(
        "uniform float u_Scale;\n",
        "const int COUNT = 2 * 2;\n",
        "const float HALF = 1.0 / 2.0;\n",
        "void main() {\n",
        "    float weights[COUNT];\n",
        "    for (int i = 0; i < COUNT; i++) { weights[i] = HALF * u_Scale; }\n",
        "    gl_FragColor = vec4(weights[0], weights[3], 0.0, 1.0);\n",
        "}\n",
    );
    let module = ShaderModule::parse(ShaderStageKind::Fragment, source_text).expect("module parses");
    let legalized = Codegen.legalize(&module).expect("shader legalizes");

    assert!(legalized.source().contains("const int COUNT = 2 * 2;"));
    assert!(legalized.source().contains("const float HALF = 1.0 / 2.0;"));
    for target in [ShaderTarget::VulkanSpirv, ShaderTarget::MetalMsl] {
        let _artifact = NagaCompiler
            .compile_stage(target, ShaderStageKind::Fragment, &legalized)
            .expect("constant globals should compile unchanged");
    }
}

fn compile_fragment(
    target: ShaderTarget,
    source_text: &str,
) -> CompiledStageArtifact<naga::Module> {
    let module = ShaderModule::parse(ShaderStageKind::Fragment, source_text).expect("module parses");
    let legalized = Codegen.legalize(&module).expect("shader legalizes");
    match NagaCompiler.compile_stage(target, ShaderStageKind::Fragment, &legalized) {
        Ok(artifact) => artifact,
        Err(error) => panic!(
            "{target:?}: {}\n{}",
            error.to_miette_report(),
            legalized.source()
        ),
    }
}

/// Returns the named private globals the entry point writes, in the order its
/// call graph writes them.
fn runtime_global_stores(module: &naga::Module, names: &[&str]) -> Vec<String> {
    fn walk(
        module: &naga::Module,
        function: &naga::Function,
        block: &naga::Block,
        names: &[&str],
        stores: &mut Vec<String>,
    ) {
        for statement in block.iter() {
            match statement {
                naga::Statement::Store { pointer, .. } => {
                    if let naga::Expression::GlobalVariable(global) = function.expressions[*pointer]
                        && let Some(name) = module.global_variables[global].name.as_deref()
                        && names.contains(&name)
                    {
                        stores.push(name.to_owned());
                    }
                }
                naga::Statement::Call { function: callee, .. } => {
                    let callee = &module.functions[*callee];
                    walk(module, callee, &callee.body, names, stores);
                }
                naga::Statement::Block(inner) => walk(module, function, inner, names, stores),
                _ => {}
            }
        }
    }

    let entry = module
        .entry_points
        .first()
        .expect("fragment module has an entry point");
    let mut stores = Vec::new();
    walk(module, &entry.function, &entry.function.body, names, &mut stores);
    stores
}

fn legalized_source(stage: ShaderStageKind, source: &str) -> CodegenStageSource {
    CodegenStageSource::new(stage, source.to_owned(), Box::from([]))
}

fn spirv<M>(artifact: &CompiledStageArtifact<M>) -> &[u32] {
    artifact
        .stage()
        .spirv()
        .expect("vulkan_spirv target should produce SPIR-V words")
}

fn spirv_contains_opcode(words: &[u32], opcode: u16) -> bool {
    let mut index = 5;
    while index < words.len() {
        let instruction = words[index];
        let word_count = (instruction >> 16) as usize;
        let instruction_opcode = (instruction & 0xffff) as u16;
        if instruction_opcode == opcode {
            return true;
        }
        if word_count == 0 {
            return false;
        }
        index += word_count;
    }
    false
}
