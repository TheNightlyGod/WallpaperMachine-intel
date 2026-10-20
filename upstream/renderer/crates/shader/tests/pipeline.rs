use shader::{
    BindingIndex, BindingSet, ComboName, CompiledShaderStage, CompiledStageArtifact,
    CompiledStageCode, InMemoryShaderSourceProvider, IncludePath, PropertyName, PropertyValue,
    ShaderCacheStrategy, ShaderComboValue, ShaderCompiler, ShaderDescriptorKind, ShaderError,
    ShaderName, ShaderProgramRequest, ShaderReflection, ShaderReflector, ShaderResult,
    ShaderStageKind, ShaderStageSource, ShaderTarget, ShaderTextureInfo, ShaderUniformBlock,
    ShaderUniformMember, TextureFormatHint, TextureSlot,
    compile::NagaCompiler,
    legalize::CodegenStageSource,
    pipeline::{DefaultShaderPipeline, ShaderPipeline, ShaderPipelineRevision},
};

const SPIRV_MAGIC: u32 = 0x0723_0203;

#[test]
fn redefined_array_bound_uses_the_current_macro_in_reflection_and_backend() {
    for target in [ShaderTarget::VulkanSpirv, ShaderTarget::MetalMsl] {
        let request = ShaderProgramRequest::builder(ShaderName::new("redefined_array_bound").unwrap())
            .target(target)
            .stage(ShaderStageSource::new(ShaderStageKind::Vertex,
                "attribute vec2 a_Position; void main() { gl_Position = vec4(a_Position, 0.0, 1.0); }"))
            .stage(ShaderStageSource::new(ShaderStageKind::Fragment, concat!(
                "#define COUNT 2\n#undef COUNT\n#define COUNT 3\n",
                "uniform vec4 values[COUNT];\n",
                "void main() { gl_FragColor = values[2]; }\n",
            )))
            .build().unwrap();
        let program = pipeline().compile(&request).expect("redefined uniform bounds compile");
        let member = program.reflection().uniform_blocks().iter().flat_map(|block| block.members())
            .find(|member| member.name() == "values").unwrap();
        assert_eq!(member.array_count(), 3);
    }
}

#[test]
fn float_remainder_reaches_both_backends_without_repeating_operands() {
    for target in [ShaderTarget::VulkanSpirv, ShaderTarget::MetalMsl] {
        let request = ShaderProgramRequest::builder(ShaderName::new("float_remainder").unwrap())
            .target(target)
            .stage(ShaderStageSource::new(ShaderStageKind::Vertex, concat!(
                "attribute vec2 a_Position;\n",
                "void main() { float offset = -5.5 % 2.0; gl_Position = vec4(a_Position + offset, 0.0, 1.0); }\n",
            )))
            .stage(ShaderStageSource::new(ShaderStageKind::Fragment, concat!(
                "float counter = 0.0;\n",
                "float next_value() { counter += 1.0; return -5.5; }\n",
                "void main() {\n",
                "float value = next_value() % 2.0;\n",
                "float nested = (-5.5 % -2.0) % 1.0;\n",
                "int integral = int(value % 2.0);\n",
                "gl_FragColor = vec4(value + nested + float(integral) + counter);\n",
                "}\n",
            )))
            .build().unwrap();
        let program = pipeline().compile(&request)
            .expect("float remainder is legal on SPIR-V and Metal backends");
        let fragment = program.stages().iter()
            .find(|stage| stage.kind() == ShaderStageKind::Fragment).unwrap()
            .legalized_source().unwrap();
        assert_eq!(fragment.matches("next_value()").count(), 2,
            "one definition and one evaluation; modulo must not duplicate an operand");
    }
}

/// Compiles a fragment shader that reads `v_TexCoord` for both backends.
fn compile_fragment_for_both_backends(name: &str, fragment: &str) {
    for target in [ShaderTarget::VulkanSpirv, ShaderTarget::MetalMsl] {
        let request = ShaderProgramRequest::builder(ShaderName::new(name).unwrap())
            .target(target)
            .stage(ShaderStageSource::new(ShaderStageKind::Vertex, concat!(
                "attribute vec2 a_Position;\n",
                "varying vec2 v_TexCoord;\n",
                "void main() {\n",
                "  v_TexCoord = a_Position;\n",
                "  gl_Position = vec4(a_Position, 0.0, 1.0);\n",
                "}\n",
            )))
            .stage(ShaderStageSource::new(ShaderStageKind::Fragment, fragment))
            .build().unwrap();
        if let Err(error) = pipeline().compile(&request) {
            panic!("{name} should compile for {target:?}: {error:?}");
        }
    }
}

#[test]
fn array_suffix_declares_only_its_own_declarator() {
    // `float color[4], f;` declares one array and one scalar. Naga applied the
    // suffix to every later name in the list, so `f + vec2` failed validation.
    compile_fragment_for_both_backends("array_declarator_lists", concat!(
        "const float WEIGHTS[2] = float[2](0.25, 0.75), SCALE = 2.0;\n",
        "varying vec2 v_TexCoord;\n",
        "void main() {\n",
        "  float color[4], f;\n",
        "  float3 tints[2], tint = float3(0.5, 0.5, 0.5);\n",
        "  float a, b[2], c[3], d;\n",
        "  for (int i = 0; i < 4; i++) {\n",
        "    f = float(i);\n",
        "    color[i] = (vec2(v_TexCoord.x, pow(v_TexCoord.y, 2)) + f).x;\n",
        "  }\n",
        "  tints[1] = tint;\n",
        "  a = color[3];\n",
        "  b[1] = a;\n",
        "  c[2] = b[1];\n",
        "  d = c[2] * SCALE * WEIGHTS[1];\n",
        "  gl_FragColor = vec4(tints[1] * d, color[0]);\n",
        "}\n",
    ));
}

#[test]
fn integer_clamp_keeps_integer_literals() {
    // Integer literals in `clamp` become floats for float operands, which the
    // legacy shaders rely on; an `int` or `uint` operand selects the integer
    // overload instead, and a float literal there fails validation.
    compile_fragment_for_both_backends("integer_clamp", concat!(
        "uniform float g_AudioSpectrum64Left[64];\n",
        "const int BANDS = 64;\n",
        "varying vec2 v_TexCoord;\n",
        "float band(int index, int maxBand) {\n",
        "  index = abs(index);\n",
        "  if (index > maxBand) { index = maxBand - (index - maxBand); }\n",
        "  index = clamp(index, 0, BANDS - 1);\n",
        "  return g_AudioSpectrum64Left[index];\n",
        "}\n",
        "void main() {\n",
        "  ivec2 cell = ivec2(v_TexCoord * 10.0);\n",
        "  cell = clamp(cell, 0, 5);\n",
        "  int row = clamp(int(v_TexCoord.y * 9.0), 0, 5);\n",
        "  uint level = clamp(uint(v_TexCoord.y * 9.0), 0, 5);\n",
        "  level = max(level, 1) + min(level, 3);\n",
        "  float x = clamp(v_TexCoord.x, 0, 1);\n",
        "  gl_FragColor = vec4(band(int(x * 63.0), 48), float(cell.x + row), float(level), 1.0);\n",
        "}\n",
    ));
}

/// Wallpaper Engine's installed `assets/shaders` directory. Honors the same
/// `WALLPAPER_MACHINE_ASSETS_ROOT` override the bridge uses
/// (`crates/bridge/src/paths.rs`), falling back to the standard Steam location
/// under the current user's home. These assets are licensed content that never
/// enters Git, so tests needing them skip when the directory is absent.
fn asset_shader_root() -> Option<std::path::PathBuf> {
    let root = std::env::var_os("WALLPAPER_MACHINE_ASSETS_ROOT")
        .map(std::path::PathBuf::from)
        .or_else(|| {
            std::env::var_os("HOME").map(|home| {
                std::path::PathBuf::from(home).join(
                    "Library/Application Support/Steam/steamapps/common/wallpaper_engine/assets",
                )
            })
        })?
        .join("shaders");
    root.is_dir().then_some(root)
}

/// Root for shaders unpacked from workshop packages. Defaults to `unpack/` at
/// the workspace root; override with `WALLPAPER_MACHINE_UNPACK_ROOT`.
fn unpack_root() -> std::path::PathBuf {
    if let Some(root) = std::env::var_os("WALLPAPER_MACHINE_UNPACK_ROOT") {
        return std::path::PathBuf::from(root);
    }
    std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(std::path::Path::parent)
        .expect("workspace root should be two levels above shader crate")
        .join("unpack")
}

/// Reads a corpus file, or reports why the calling test is being skipped.
/// Returns `None` instead of panicking: the local wallpaper corpus is optional
/// and machine-specific (see `docs/wallpaper-corpus.md`).
fn corpus_source_or_skip(path: &std::path::Path, test: &str) -> Option<String> {
    match std::fs::read_to_string(path) {
        Ok(source) => Some(source),
        Err(error) => {
            eprintln!(
                "skipping {test}: local wallpaper corpus file {} is unavailable ({error}). Set \
                 WALLPAPER_MACHINE_ASSETS_ROOT / WALLPAPER_MACHINE_UNPACK_ROOT to run it.",
                path.display()
            );
            None
        }
    }
}

#[test]
fn compiles_program_and_merges_metadata_reflection_and_diagnostics() {
    let pipeline = pipeline();
    let request = request("1.0", "1");

    let program = pipeline
        .compile(&request)
        .expect("pipeline should compile both shader stages");

    assert_eq!(program.shader_name().as_str(), "effects/pipeline");
    assert_eq!(program.stages().len(), 2);
    assert!(
        program
            .stages()
            .iter()
            .all(|stage| stage.spirv().and_then(<[u32]>::first) == Some(&SPIRV_MAGIC))
    );
    assert!(program.stages().iter().any(|stage| {
        stage.kind() == ShaderStageKind::Vertex
            && stage
                .legalized_source()
                .is_some_and(|source| source.contains("shared_uv"))
    }));

    assert_eq!(
        program.metadata().combos()[0].name().as_str(),
        "HAS_TEXTURE"
    );
    assert_eq!(program.metadata().combos()[0].value(), "1");
    assert_eq!(program.metadata().aliases()[0].material(), "brightness");
    assert_eq!(
        program.metadata().default_uniforms()[0].uniform(),
        "g_Brightness"
    );
    assert_eq!(program.metadata().default_textures()[0].slot().index(), 0);
    assert_eq!(program.metadata().active_texture_slots()[0].index(), 0);

    assert!(
        program
            .reflection()
            .vertex_inputs()
            .iter()
            .any(|input| input.name() == "a_Position" && input.location().index() == 0)
    );
    assert!(
        program
            .reflection()
            .descriptor_bindings()
            .iter()
            .any(|binding| binding.name() == "g_Texture0"
                && binding.binding().binding() == 0
                && binding.stages().fragment())
    );
    assert!(
        program
            .reflection()
            .uniform_blocks()
            .iter()
            .any(|block| block.name() == "GlobalUniforms")
    );
    assert!(
        program
            .diagnostics()
            .iter()
            .any(|diagnostic| diagnostic.pass() == Some("Codegen"))
    );
}

#[test]
fn cache_key_tracks_sources_combos_revision_and_legalized_output() {
    let pipeline = pipeline();
    let base = pipeline
        .compile(&request("1.0", "1"))
        .expect("base request should compile")
        .cache_key()
        .clone();
    let source_change = pipeline
        .compile(&request("2.0", "1"))
        .expect("source change should compile")
        .cache_key()
        .clone();
    let combo_change = pipeline
        .compile(&request("1.0", "0"))
        .expect("combo change should compile")
        .cache_key()
        .clone();
    let revision_change = pipeline
        .clone()
        .with_revision(ShaderPipelineRevision::new(
            ShaderPipelineRevision::CURRENT.value() + 1,
        ))
        .compile(&request("1.0", "1"))
        .expect("revision change should compile")
        .cache_key()
        .clone();
    let legalized_change = pipeline
        .compile(&request_with_fragment_call(
            "1.0",
            "texture(g_Texture0, v_Uv)",
            "1",
        ))
        .expect("legalized output change should compile")
        .cache_key()
        .clone();

    assert_ne!(base, source_change);
    assert_ne!(base, combo_change);
    assert_ne!(base, revision_change);
    assert_ne!(base, legalized_change);
}

#[test]
fn cache_key_separates_spirv_and_metal_targets_for_identical_sources() {
    let pipeline = pipeline();
    let spirv = pipeline
        .compile(&request_with_target("1.0", "1", ShaderTarget::VulkanSpirv))
        .expect("vulkan_spirv request should compile");
    let metal = pipeline
        .compile(&request_with_target("1.0", "1", ShaderTarget::MetalMsl))
        .expect("metal_msl request should compile");

    assert_eq!(spirv.stages().len(), metal.stages().len());
    assert!(
        spirv
            .stages()
            .iter()
            .all(|stage| stage.target() == ShaderTarget::VulkanSpirv)
    );
    assert!(
        metal
            .stages()
            .iter()
            .all(|stage| stage.target() == ShaderTarget::MetalMsl)
    );
    assert_ne!(
        spirv.cache_key(),
        metal.cache_key(),
        "a spirv cache entry must never be served for a metal request or the reverse"
    );
}

#[test]
fn cache_key_tracks_typed_vector_and_matrix_property_values() {
    let pipeline = source_capture_pipeline();
    let vec2 = pipeline
        .compile(&request_with_property(
            "scale",
            PropertyValue::Vec2([1.0, 1.0]),
        ))
        .expect("vec2 property request should compile")
        .cache_key()
        .clone();
    let vec4 = pipeline
        .compile(&request_with_property(
            "scale",
            PropertyValue::Vec4([1.0, 1.0, 1.0, 1.0]),
        ))
        .expect("vec4 property request should compile")
        .cache_key()
        .clone();
    let matrix4 = pipeline
        .compile(&request_with_property(
            "scale",
            PropertyValue::Matrix4([
                1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0,
            ]),
        ))
        .expect("matrix4 property request should compile")
        .cache_key()
        .clone();

    assert_ne!(vec2, vec4);
    assert_ne!(vec2, matrix4);
    assert_ne!(vec4, matrix4);
}

#[test]
fn text_style_shader_preserves_uniform_block_binding_in_merged_reflection() {
    let pipeline = pipeline();
    let request = ShaderProgramRequest::builder(ShaderName::new("text").expect("valid name"))
        .stage(ShaderStageSource::new(
            ShaderStageKind::Vertex,
            concat!(
                "layout(binding = 1) uniform mat4 g_ModelViewProjectionMatrix;\n",
                "in vec3 a_Position;\n",
                "in vec2 a_TexCoord;\n",
                "out vec2 v_TexCoord;\n",
                "void main() {\n",
                "  gl_Position = g_ModelViewProjectionMatrix * vec4(a_Position, 1.0);\n",
                "  v_TexCoord = a_TexCoord;\n",
                "}\n",
            ),
        ))
        .stage(ShaderStageSource::new(
            ShaderStageKind::Fragment,
            concat!(
                "uniform sampler2D g_Texture0;\n",
                "in vec2 v_TexCoord;\n",
                "void main() {\n",
                "  gl_FragColor = texture(g_Texture0, v_TexCoord);\n",
                "}\n",
            ),
        ))
        .texture(ShaderTextureInfo::new(
            TextureSlot::new(0).expect("valid texture slot"),
            true,
            TextureFormatHint::Rgba8,
        ))
        .build()
        .expect("text-style request should be valid");

    let program = pipeline
        .compile(&request)
        .expect("text-style request should compile");

    assert!(
        program
            .reflection()
            .descriptor_bindings()
            .iter()
            .any(|binding| { binding.name() == "g_Texture0" && binding.binding().binding() == 0 })
    );
    assert!(
        program
            .reflection()
            .uniform_blocks()
            .iter()
            .any(|block| { block.name() == "GlobalUniforms" && block.binding().binding() == 1 })
    );
}

#[test]
fn generated_uniform_block_uses_one_program_binding_across_stages() {
    let pipeline = pipeline();
    let request =
        ShaderProgramRequest::builder(ShaderName::new("program_uniforms").expect("valid name"))
            .stage(ShaderStageSource::new(
                ShaderStageKind::Vertex,
                concat!(
                    "uniform float g_Time;\n",
                    "in vec3 a_Position;\n",
                    "void main() {\n",
                    "  gl_Position = vec4(a_Position.xy * g_Time, a_Position.z, 1.0);\n",
                    "}\n",
                ),
            ))
            .stage(ShaderStageSource::new(
                ShaderStageKind::Fragment,
                concat!(
                    "uniform sampler2D g_Texture0;\n",
                    "uniform sampler2D g_Texture1;\n",
                    "uniform float g_Opacity;\n",
                    "void main() {\n",
                    "  gl_FragColor = mix(\n",
                    "      texture(g_Texture0, vec2(0.25)),\n",
                    "      texture(g_Texture1, vec2(0.75)),\n",
                    "      g_Opacity);\n",
                    "}\n",
                ),
            ))
            .texture(ShaderTextureInfo::new(
                TextureSlot::new(0).expect("valid texture slot"),
                true,
                TextureFormatHint::Rgba8,
            ))
            .texture(ShaderTextureInfo::new(
                TextureSlot::new(1).expect("valid texture slot"),
                true,
                TextureFormatHint::Rgba8,
            ))
            .build()
            .expect("program-uniform request should be valid");

    let program = pipeline
        .compile(&request)
        .expect("program-uniform request should compile");
    let vertex_source = program
        .stages()
        .iter()
        .find(|stage| stage.kind() == ShaderStageKind::Vertex)
        .and_then(CompiledShaderStage::legalized_source)
        .expect("vertex legalized source should be captured");
    let fragment_source = program
        .stages()
        .iter()
        .find(|stage| stage.kind() == ShaderStageKind::Fragment)
        .and_then(CompiledShaderStage::legalized_source)
        .expect("fragment legalized source should be captured");
    let uniform_binding = program
        .reflection()
        .uniform_blocks()
        .iter()
        .find(|block| block.name() == "GlobalUniforms")
        .map(|block| block.binding().binding())
        .expect("merged reflection should contain GlobalUniforms");
    let uniform_layout =
        format!("layout(std140, set = 0, binding = {uniform_binding}) uniform GlobalUniforms");

    assert!(vertex_source.contains(&uniform_layout));
    assert!(fragment_source.contains(&uniform_layout));
    assert_ne!(uniform_binding, 0);
    assert_ne!(uniform_binding, 1);

    assert_eq!(
        program
            .reflection()
            .uniform_blocks()
            .iter()
            .filter(|block| block.name() == "GlobalUniforms")
            .count(),
        1
    );
    let uniform_descriptors: Vec<_> = program
        .reflection()
        .descriptor_bindings()
        .iter()
        .filter(|binding| binding.name() == "GlobalUniforms")
        .collect();
    assert_eq!(uniform_descriptors.len(), 1);
    assert_eq!(uniform_descriptors[0].binding().binding(), uniform_binding);
    assert!(matches!(
        uniform_descriptors[0].kind(),
        ShaderDescriptorKind::UniformBuffer
    ));
    assert!(uniform_descriptors[0].stages().vertex());
    assert!(uniform_descriptors[0].stages().fragment());
}

#[test]
fn generated_uniform_block_uses_one_program_member_layout_across_stages() {
    let pipeline = pipeline();
    let vertex_source = concat!(
        "uniform mat4 g_ModelViewProjectionMatrix;\n",
        "in vec3 a_Position;\n",
        "void main() {\n",
        "  gl_Position = g_ModelViewProjectionMatrix * vec4(a_Position, 1.0);\n",
        "}\n",
    );
    let fragment_source = concat!(
        "uniform sampler2D g_Texture0;\n",
        "uniform vec4 g_Texture0Resolution;\n",
        "uniform float g_Time;\n",
        "uniform float u_Opacity;\n",
        "void main() {\n",
        "  gl_FragColor = texture(g_Texture0, vec2(g_Time)) * u_Opacity + \
         vec4(g_Texture0Resolution.xy, 0.0, 0.0);\n",
        "}\n",
    );

    let program = pipeline
        .compile(&program_uniform_layout_request(
            "program_uniform_layout",
            [
                (ShaderStageKind::Vertex, vertex_source),
                (ShaderStageKind::Fragment, fragment_source),
            ],
        ))
        .expect("program-uniform-layout request should compile");
    let reversed_program = pipeline
        .compile(&program_uniform_layout_request(
            "program_uniform_layout_reversed",
            [
                (ShaderStageKind::Fragment, fragment_source),
                (ShaderStageKind::Vertex, vertex_source),
            ],
        ))
        .expect("reversed program-uniform-layout request should compile");
    let vertex_source = legalized_stage_source(&program, ShaderStageKind::Vertex);
    let fragment_source = legalized_stage_source(&program, ShaderStageKind::Fragment);

    for member in [
        "mat4 g_ModelViewProjectionMatrix;",
        "vec4 g_Texture0Resolution;",
        "float g_Time;",
        "float u_Opacity;",
    ] {
        assert!(vertex_source.contains(member), "vertex missing {member}");
        assert!(
            fragment_source.contains(member),
            "fragment missing {member}"
        );
    }
    assert!(
        vertex_source.find("mat4 g_ModelViewProjectionMatrix;")
            < vertex_source.find("vec4 g_Texture0Resolution;")
    );
    assert_uniform_block_member_order(
        vertex_source,
        &[
            "mat4 g_ModelViewProjectionMatrix;",
            "vec4 g_Texture0Resolution;",
            "float g_Time;",
            "float u_Opacity;",
        ],
    );
    assert_uniform_block_member_order(
        fragment_source,
        &[
            "mat4 g_ModelViewProjectionMatrix;",
            "vec4 g_Texture0Resolution;",
            "float g_Time;",
            "float u_Opacity;",
        ],
    );

    let block = program
        .reflection()
        .uniform_blocks()
        .iter()
        .find(|block| block.name() == "GlobalUniforms")
        .expect("merged reflection should contain GlobalUniforms");
    let member_names: Vec<_> = block.members().iter().map(|member| member.name()).collect();
    assert_eq!(
        member_names,
        [
            "g_ModelViewProjectionMatrix",
            "g_Texture0Resolution",
            "g_Time",
            "u_Opacity"
        ]
    );
    let member_offsets: Vec<_> = block
        .members()
        .iter()
        .map(|member| member.offset())
        .collect();
    assert_eq!(member_offsets, [0, 64, 80, 84]);

    let reversed_block = reversed_program
        .reflection()
        .uniform_blocks()
        .iter()
        .find(|block| block.name() == "GlobalUniforms")
        .expect("merged reversed reflection should contain GlobalUniforms");
    let reversed_member_names: Vec<_> = reversed_block
        .members()
        .iter()
        .map(|member| member.name())
        .collect();
    assert_eq!(reversed_member_names, member_names);
    let reversed_member_offsets: Vec<_> = reversed_block
        .members()
        .iter()
        .map(|member| member.offset())
        .collect();
    assert_eq!(reversed_member_offsets, member_offsets);
}

#[test]
fn generated_uniform_block_excludes_unsupported_sampler_uniforms() {
    let pipeline = source_capture_pipeline();
    let request = ShaderProgramRequest::builder(
        ShaderName::new("program_uniform_unsupported_samplers").expect("valid name"),
    )
    .stage(ShaderStageSource::new(
        ShaderStageKind::Vertex,
        concat!(
            "uniform mat4 g_ModelViewProjectionMatrix;\n",
            "in vec3 a_Position;\n",
            "void main() {\n",
            "  gl_Position = g_ModelViewProjectionMatrix * vec4(a_Position, 1.0);\n",
            "}\n",
        ),
    ))
    .stage(ShaderStageSource::new(
        ShaderStageKind::Fragment,
        concat!(
            "layout(set = 0, binding = 0) uniform samplerCube g_Environment;\n",
            "layout(set = 0, binding = 2) uniform sampler g_Sampler;\n",
            "uniform float g_Exposure;\n",
            "void main() {\n",
            "  gl_FragColor = vec4(g_Exposure);\n",
            "}\n",
        ),
    ))
    .build()
    .expect("program-uniform-sampler-cube request should be valid");

    let program = pipeline
        .compile(&request)
        .expect("program with unsupported sampler uniform should compile");
    let vertex_source = legalized_stage_source(&program, ShaderStageKind::Vertex);
    let fragment_source = legalized_stage_source(&program, ShaderStageKind::Fragment);
    let uniform_block = fragment_source
        .lines()
        .find(|line| line.contains("uniform GlobalUniforms"))
        .expect("fragment should contain GlobalUniforms");

    assert!(
        fragment_source.contains("layout(set = 0, binding = 0) uniform samplerCube g_Environment;")
    );
    assert!(fragment_source.contains("layout(set = 0, binding = 2) uniform sampler g_Sampler;"));
    assert!(
        uniform_block.contains("binding = 1"),
        "GlobalUniforms should avoid the kept sampler binding: {uniform_block}"
    );
    assert_uniform_block_member_order(
        vertex_source,
        &["mat4 g_ModelViewProjectionMatrix;", "float g_Exposure;"],
    );
    assert_uniform_block_member_order(
        fragment_source,
        &["mat4 g_ModelViewProjectionMatrix;", "float g_Exposure;"],
    );
    assert!(!vertex_source.contains("samplerCube g_Environment;"));
    assert!(!vertex_source.contains("sampler g_Sampler;"));
    assert!(!uniform_block.contains("samplerCube g_Environment;"));
    assert!(!uniform_block.contains("sampler g_Sampler;"));
    assert_eq!(
        fragment_source
            .matches("samplerCube g_Environment;")
            .count(),
        1
    );
    assert_eq!(fragment_source.matches("sampler g_Sampler;").count(), 1);
}

#[test]
fn generated_texture_sampler_avoids_program_reserved_kept_sampler_binding() {
    let pipeline = source_capture_pipeline();
    let request = ShaderProgramRequest::builder(
        ShaderName::new("program_uniform_split_texture_reserved_sampler").expect("valid name"),
    )
    .stage(ShaderStageSource::new(
        ShaderStageKind::Vertex,
        concat!(
            "in vec3 a_Position;\n",
            "void main() {\n",
            "  gl_Position = vec4(a_Position, 1.0);\n",
            "}\n",
        ),
    ))
    .stage(ShaderStageSource::new(
        ShaderStageKind::Fragment,
        concat!(
            "layout(binding = 1) uniform samplerCube env;\n",
            "uniform sampler2D g_Texture0;\n",
            "uniform float g_Exposure;\n",
            "void main() {\n",
            "  gl_FragColor = texture(g_Texture0, vec2(0.5)) * g_Exposure;\n",
            "}\n",
        ),
    ))
    .texture(ShaderTextureInfo::new(
        TextureSlot::new(0).expect("valid texture slot"),
        true,
        TextureFormatHint::Rgba8,
    ))
    .build()
    .expect("program-uniform-reserved-sampler request should be valid");

    let program = pipeline
        .compile(&request)
        .expect("program with kept sampler and split texture should compile");
    let fragment_source = legalized_stage_source(&program, ShaderStageKind::Fragment);
    let uniform_block = fragment_source
        .lines()
        .find(|line| line.contains("uniform GlobalUniforms"))
        .expect("fragment should contain GlobalUniforms");

    assert!(fragment_source.contains("layout(binding = 1) uniform samplerCube env;"));
    assert!(
        fragment_source.contains("layout(std140, set = 0, binding = 2) uniform GlobalUniforms")
    );
    assert!(
        fragment_source
            .contains("layout(set = 0, binding = 3) uniform sampler _we_Sampler_g_Texture0;"),
        "generated sampler must avoid kept sampler binding:\n{fragment_source}"
    );
    assert!(!uniform_block.contains("samplerCube env;"));
    assert!(!uniform_block.contains("_we_Sampler_g_Texture0"));
    assert_uniform_block_member_order(fragment_source, &["float g_Exposure;"]);
}

#[test]
fn generated_texture_sampler_avoids_program_reserved_texture_binding_from_other_stage() {
    let pipeline = source_capture_pipeline();
    let request = ShaderProgramRequest::builder(
        ShaderName::new("program_uniform_split_texture_reserved_other_stage").expect("valid name"),
    )
    .stage(ShaderStageSource::new(
        ShaderStageKind::Vertex,
        concat!(
            "uniform sampler2D g_Texture0;\n",
            "in vec3 a_Position;\n",
            "void main() {\n",
            "  gl_Position = texture(g_Texture0, vec2(0.5)) + vec4(a_Position, 1.0);\n",
            "}\n",
        ),
    ))
    .stage(ShaderStageSource::new(
        ShaderStageKind::Fragment,
        concat!(
            "uniform sampler2D u_Mask;\n",
            "uniform float g_Exposure;\n",
            "void main() {\n",
            "  gl_FragColor = texture(u_Mask, vec2(0.5)) * g_Exposure;\n",
            "}\n",
        ),
    ))
    .texture(ShaderTextureInfo::new(
        TextureSlot::new(0).expect("valid texture slot"),
        true,
        TextureFormatHint::Rgba8,
    ))
    .build()
    .expect("program-uniform-cross-stage texture request should be valid");

    let program = pipeline
        .compile(&request)
        .expect("program with split texture in both stages should compile");
    let vertex_source = legalized_stage_source(&program, ShaderStageKind::Vertex);
    let fragment_source = legalized_stage_source(&program, ShaderStageKind::Fragment);

    assert!(
        fragment_source.contains("layout(std140, set = 0, binding = 1) uniform GlobalUniforms")
    );
    assert!(
        vertex_source
            .contains("layout(set = 0, binding = 2) uniform sampler _we_Sampler_g_Texture0;"),
        "encoded texture sampler must be assigned before later stage resources:\n{vertex_source}"
    );
    assert!(fragment_source.contains("layout(set = 0, binding = 3) uniform texture2D u_Mask;"));
    assert!(
        fragment_source
            .contains("layout(set = 0, binding = 4) uniform sampler _we_Sampler_u_Mask;"),
        "generated sampler must avoid other-stage texture binding 0 and \
         GlobalUniforms:\n{fragment_source}"
    );
    assert!(!fragment_source.contains("binding = 0) uniform sampler _we_Sampler_u_Mask;"));
    assert!(!fragment_source.contains("binding = 1) uniform sampler _we_Sampler_u_Mask;"));
    assert!(!fragment_source.contains("binding = 2) uniform sampler _we_Sampler_u_Mask;"));
}

#[test]
fn split_texture_rejects_same_name_kept_sampler_binding_collision() {
    let pipeline = source_capture_pipeline();
    let request = ShaderProgramRequest::builder(
        ShaderName::new("program_same_name_kept_sampler_collision").expect("valid name"),
    )
    .stage(ShaderStageSource::new(
        ShaderStageKind::Vertex,
        concat!(
            "layout(binding = 0) uniform samplerCube g_Texture0;\n",
            "in vec3 a_Position;\n",
            "void main() {\n",
            "  gl_Position = texture(g_Texture0, vec3(1.0, 0.0, 0.0)) + vec4(a_Position, 1.0);\n",
            "}\n",
        ),
    ))
    .stage(ShaderStageSource::new(
        ShaderStageKind::Fragment,
        concat!(
            "uniform sampler2D g_Texture0;\n",
            "void main() {\n",
            "  gl_FragColor = texture(g_Texture0, vec2(0.5));\n",
            "}\n",
        ),
    ))
    .texture(ShaderTextureInfo::new(
        TextureSlot::new(0).expect("valid texture slot"),
        true,
        TextureFormatHint::Rgba8,
    ))
    .build()
    .expect("same-name collision request should be syntactically valid");

    let error = pipeline
        .compile(&request)
        .expect_err("incompatible same-name descriptors must not share binding 0");

    assert!(matches!(error, ShaderError::InvalidRequest { .. }));
}

#[test]
fn same_name_split_texture_uses_one_program_binding_across_stages() {
    let pipeline = pipeline();
    let request = ShaderProgramRequest::builder(
        ShaderName::new("program_same_texture_both_stages").expect("valid name"),
    )
    .stage(ShaderStageSource::new(
        ShaderStageKind::Vertex,
        concat!(
            "uniform sampler2D g_Texture0;\n",
            "in vec3 a_Position;\n",
            "void main() {\n",
            "  vec4 sampled = textureLod(g_Texture0, vec2(0.5), 0.0);\n",
            "  gl_Position = vec4(a_Position.xy + sampled.xy * 0.0, a_Position.z, 1.0);\n",
            "}\n",
        ),
    ))
    .stage(ShaderStageSource::new(
        ShaderStageKind::Fragment,
        concat!(
            "uniform sampler2D g_Texture0;\n",
            "void main() {\n",
            "  gl_FragColor = texture(g_Texture0, vec2(0.5));\n",
            "}\n",
        ),
    ))
    .texture(ShaderTextureInfo::new(
        TextureSlot::new(0).expect("valid texture slot"),
        true,
        TextureFormatHint::Rgba8,
    ))
    .build()
    .expect("same split texture request should be valid");

    let program = pipeline
        .compile(&request)
        .expect("same split texture in both stages should compile");
    let vertex_source = legalized_stage_source(&program, ShaderStageKind::Vertex);
    let fragment_source = legalized_stage_source(&program, ShaderStageKind::Fragment);

    assert!(vertex_source.contains("layout(set = 0, binding = 0) uniform texture2D g_Texture0;"));
    assert!(
        vertex_source
            .contains("layout(set = 0, binding = 1) uniform sampler _we_Sampler_g_Texture0;"),
        "{vertex_source}"
    );
    assert!(fragment_source.contains("layout(set = 0, binding = 0) uniform texture2D g_Texture0;"));
    assert!(
        fragment_source
            .contains("layout(set = 0, binding = 1) uniform sampler _we_Sampler_g_Texture0;"),
        "{fragment_source}"
    );

    let texture_bindings: Vec<_> = program
        .reflection()
        .descriptor_bindings()
        .iter()
        .filter(|binding| binding.name() == "g_Texture0")
        .collect();
    assert_eq!(texture_bindings.len(), 1);
    assert_eq!(
        texture_bindings[0].kind(),
        ShaderDescriptorKind::SampledImage
    );
    assert_eq!(texture_bindings[0].binding().binding(), 0);
    assert!(texture_bindings[0].stages().vertex());
    assert!(texture_bindings[0].stages().fragment());

    let sampler_bindings: Vec<_> = program
        .reflection()
        .descriptor_bindings()
        .iter()
        .filter(|binding| binding.name() == "_we_Sampler_g_Texture0")
        .collect();
    assert_eq!(sampler_bindings.len(), 1);
    assert_eq!(sampler_bindings[0].kind(), ShaderDescriptorKind::Sampler);
    assert_eq!(sampler_bindings[0].binding().binding(), 1);
    assert!(sampler_bindings[0].stages().vertex());
    assert!(sampler_bindings[0].stages().fragment());
}

#[test]
fn kept_resource_in_nonzero_set_does_not_reserve_generated_set_zero_binding() {
    let pipeline = source_capture_pipeline();
    let request = ShaderProgramRequest::builder(
        ShaderName::new("program_set_aware_resource_reservations").expect("valid name"),
    )
    .stage(ShaderStageSource::new(
        ShaderStageKind::Vertex,
        concat!(
            "in vec3 a_Position;\n",
            "void main() {\n",
            "  gl_Position = vec4(a_Position, 1.0);\n",
            "}\n",
        ),
    ))
    .stage(ShaderStageSource::new(
        ShaderStageKind::Fragment,
        concat!(
            "layout(set = 1, binding = 0) uniform samplerCube env;\n",
            "uniform sampler2D u_Mask;\n",
            "void main() {\n",
            "  gl_FragColor = texture(u_Mask, vec2(0.5));\n",
            "}\n",
        ),
    ))
    .build()
    .expect("nonzero-set kept resource request should be valid");

    let program = pipeline
        .compile(&request)
        .expect("nonzero-set kept resource should not collide with set zero generated bindings");
    let fragment_source = legalized_stage_source(&program, ShaderStageKind::Fragment);

    assert!(fragment_source.contains("layout(set = 1, binding = 0) uniform samplerCube env;"));
    assert!(fragment_source.contains("layout(set = 0, binding = 0) uniform texture2D u_Mask;"));
    assert!(
        fragment_source
            .contains("layout(set = 0, binding = 1) uniform sampler _we_Sampler_u_Mask;"),
        "{fragment_source}"
    );
}

#[test]
fn split_texture_descriptors_are_unique_across_program_stages() {
    let pipeline = source_capture_pipeline();
    let request = ShaderProgramRequest::builder(
        ShaderName::new("program_split_texture_unique_bindings").expect("valid name"),
    )
    .stage(ShaderStageSource::new(
        ShaderStageKind::Vertex,
        concat!(
            "uniform sampler2D u_VertexTex;\n",
            "in vec3 a_Position;\n",
            "void main() {\n",
            "  gl_Position = texture(u_VertexTex, vec2(0.5)) + vec4(a_Position, 1.0);\n",
            "}\n",
        ),
    ))
    .stage(ShaderStageSource::new(
        ShaderStageKind::Fragment,
        concat!(
            "uniform sampler2D u_Mask;\n",
            "uniform float g_Exposure;\n",
            "void main() {\n",
            "  gl_FragColor = texture(u_Mask, vec2(0.5)) * g_Exposure;\n",
            "}\n",
        ),
    ))
    .build()
    .expect("program split texture request should be valid");

    let program = pipeline
        .compile(&request)
        .expect("program with non-encoded split textures should compile");
    let vertex_source = legalized_stage_source(&program, ShaderStageKind::Vertex);
    let fragment_source = legalized_stage_source(&program, ShaderStageKind::Fragment);

    assert!(vertex_source.contains("layout(set = 0, binding = 1) uniform texture2D u_VertexTex;"));
    assert!(
        vertex_source
            .contains("layout(set = 0, binding = 2) uniform sampler _we_Sampler_u_VertexTex;"),
        "{vertex_source}"
    );
    assert!(fragment_source.contains("layout(set = 0, binding = 3) uniform texture2D u_Mask;"));
    assert!(
        fragment_source
            .contains("layout(set = 0, binding = 4) uniform sampler _we_Sampler_u_Mask;"),
        "{fragment_source}"
    );
}

#[test]
fn split_texture_descriptor_assignments_are_stable_when_stage_request_order_reverses() {
    let pipeline = source_capture_pipeline();
    let vertex_source = concat!(
        "uniform sampler2D u_VertexTex;\n",
        "in vec3 a_Position;\n",
        "void main() {\n",
        "  gl_Position = texture(u_VertexTex, vec2(0.5)) + vec4(a_Position, 1.0);\n",
        "}\n",
    );
    let fragment_source = concat!(
        "uniform sampler2D u_Mask;\n",
        "uniform float g_Exposure;\n",
        "void main() {\n",
        "  gl_FragColor = texture(u_Mask, vec2(0.5)) * g_Exposure;\n",
        "}\n",
    );

    let program = pipeline
        .compile(&program_split_texture_request(
            "program_split_texture_stable",
            [
                (ShaderStageKind::Vertex, vertex_source),
                (ShaderStageKind::Fragment, fragment_source),
            ],
        ))
        .expect("program with split textures should compile");
    let reversed_program = pipeline
        .compile(&program_split_texture_request(
            "program_split_texture_stable_reversed",
            [
                (ShaderStageKind::Fragment, fragment_source),
                (ShaderStageKind::Vertex, vertex_source),
            ],
        ))
        .expect("reversed program with split textures should compile");

    for compiled in [&program, &reversed_program] {
        let vertex_source = legalized_stage_source(compiled, ShaderStageKind::Vertex);
        let fragment_source = legalized_stage_source(compiled, ShaderStageKind::Fragment);

        assert!(
            vertex_source.contains("layout(set = 0, binding = 1) uniform texture2D u_VertexTex;")
        );
        assert!(
            vertex_source
                .contains("layout(set = 0, binding = 2) uniform sampler _we_Sampler_u_VertexTex;")
        );
        assert!(fragment_source.contains("layout(set = 0, binding = 3) uniform texture2D u_Mask;"));
        assert!(
            fragment_source
                .contains("layout(set = 0, binding = 4) uniform sampler _we_Sampler_u_Mask;")
        );
    }
}

#[test]
fn encoded_and_non_encoded_split_texture_descriptors_do_not_collide_across_stages() {
    let pipeline = source_capture_pipeline();
    let request = ShaderProgramRequest::builder(
        ShaderName::new("program_encoded_non_encoded_split_textures").expect("valid name"),
    )
    .stage(ShaderStageSource::new(
        ShaderStageKind::Vertex,
        concat!(
            "uniform sampler2D g_Texture0;\n",
            "in vec3 a_Position;\n",
            "void main() {\n",
            "  gl_Position = texture(g_Texture0, vec2(0.5)) + vec4(a_Position, 1.0);\n",
            "}\n",
        ),
    ))
    .stage(ShaderStageSource::new(
        ShaderStageKind::Fragment,
        concat!(
            "uniform sampler2D u_Mask;\n",
            "void main() {\n",
            "  gl_FragColor = texture(u_Mask, vec2(0.5));\n",
            "}\n",
        ),
    ))
    .texture(ShaderTextureInfo::new(
        TextureSlot::new(0).expect("valid texture slot"),
        true,
        TextureFormatHint::Rgba8,
    ))
    .build()
    .expect("encoded/non-encoded split texture request should be valid");

    let program = pipeline
        .compile(&request)
        .expect("program with encoded and non-encoded split textures should compile");
    let vertex_source = legalized_stage_source(&program, ShaderStageKind::Vertex);
    let fragment_source = legalized_stage_source(&program, ShaderStageKind::Fragment);

    assert!(vertex_source.contains("layout(set = 0, binding = 0) uniform texture2D g_Texture0;"));
    assert!(
        vertex_source
            .contains("layout(set = 0, binding = 1) uniform sampler _we_Sampler_g_Texture0;"),
        "{vertex_source}"
    );
    assert!(fragment_source.contains("layout(set = 0, binding = 2) uniform texture2D u_Mask;"));
    assert!(
        fragment_source
            .contains("layout(set = 0, binding = 3) uniform sampler _we_Sampler_u_Mask;"),
        "{fragment_source}"
    );
}

#[test]
fn generated_uniform_block_rejects_duplicate_name_with_conflicting_type() {
    let pipeline = source_capture_pipeline();
    let request = interface_request(
        concat!(
            "uniform float g_Time;\n",
            "void main() {\n",
            "  gl_Position = vec4(g_Time);\n",
            "}\n",
        ),
        concat!(
            "uniform vec2 g_Time;\n",
            "void main() {\n",
            "  gl_FragColor = vec4(g_Time, 0.0, 1.0);\n",
            "}\n",
        ),
    );

    let error = pipeline
        .compile(&request)
        .expect_err("conflicting duplicate uniform member type should be rejected");

    assert!(matches!(error, ShaderError::InvalidRequest { .. }));
    assert!(
        error
            .to_string()
            .contains("conflicting GlobalUniforms member declarations")
    );
}

#[test]
fn generated_uniform_block_rejects_duplicate_name_with_conflicting_array_suffix() {
    let pipeline = source_capture_pipeline();
    let request = interface_request(
        concat!(
            "uniform vec4 g_Offsets[2];\n",
            "void main() {\n",
            "  gl_Position = g_Offsets[0];\n",
            "}\n",
        ),
        concat!(
            "uniform vec4 g_Offsets[3];\n",
            "void main() {\n",
            "  gl_FragColor = g_Offsets[0];\n",
            "}\n",
        ),
    );

    let error = pipeline
        .compile(&request)
        .expect_err("conflicting duplicate uniform member array suffix should be rejected");

    assert!(matches!(error, ShaderError::InvalidRequest { .. }));
    assert!(
        error
            .to_string()
            .contains("conflicting GlobalUniforms member declarations")
    );
}

#[test]
fn generated_uniform_block_canonicalizes_numeric_array_suffixes() {
    let pipeline = source_capture_pipeline();
    let request = interface_request(
        concat!(
            "uniform vec4 g_Offsets[ 2 ];\n",
            "void main() {\n",
            "  gl_Position = g_Offsets[0];\n",
            "}\n",
        ),
        concat!(
            "uniform vec4 g_Offsets[02];\n",
            "void main() {\n",
            "  gl_FragColor = g_Offsets[1];\n",
            "}\n",
        ),
    );

    let program = pipeline
        .compile(&request)
        .expect("equivalent numeric array suffixes should share one generated member");
    let vertex_source = legalized_stage_source(&program, ShaderStageKind::Vertex);
    let fragment_source = legalized_stage_source(&program, ShaderStageKind::Fragment);

    assert_uniform_block_member_order(vertex_source, &["vec4 g_Offsets[2];"]);
    assert_uniform_block_member_order(fragment_source, &["vec4 g_Offsets[2];"]);
    assert!(!vertex_source.contains("[ 2 ]"));
    assert!(!fragment_source.contains("[02]"));
}

#[test]
fn generated_uniform_block_rejects_stage_local_struct_uniforms_before_codegen() {
    let pipeline = source_capture_pipeline();
    let request = interface_request(
        "void main() { gl_Position = vec4(0.0); }\n",
        concat!(
            "struct Params { float value; };\n",
            "uniform Params u_Params;\n",
            "void main() {\n",
            "  gl_FragColor = vec4(u_Params.value);\n",
            "}\n",
        ),
    );

    let error = pipeline
        .compile(&request)
        .expect_err("stage-local struct uniform should be rejected before codegen");

    assert!(matches!(error, ShaderError::InvalidRequest { .. }));
    assert!(
        error
            .to_string()
            .contains("unsupported GlobalUniforms member type")
    );
}

#[test]
fn generated_uniform_block_resolves_stage_local_leading_array_macro_before_codegen() {
    let pipeline = source_capture_pipeline();
    let request = interface_request(
        "void main() { gl_Position = vec4(0.0); }\n",
        concat!(
            "#define LOCAL_COUNT 2\n",
            "uniform vec4 g_Offsets[LOCAL_COUNT];\n",
            "void main() {\n",
            "  gl_FragColor = g_Offsets[0];\n",
            "}\n",
        ),
    );

    let program = pipeline
        .compile(&request)
        .expect("stage-local leading uniform array macro should resolve before codegen");
    let vertex_source = legalized_stage_source(&program, ShaderStageKind::Vertex);
    let fragment_source = legalized_stage_source(&program, ShaderStageKind::Fragment);

    assert!(
        vertex_source.contains("vec4 g_Offsets[2];"),
        "vertex generated block should use resolved array size:\n{vertex_source}"
    );
    assert!(
        fragment_source.contains("vec4 g_Offsets[2];"),
        "fragment generated block should use resolved array size:\n{fragment_source}"
    );
    assert!(!vertex_source.contains("LOCAL_COUNT"));
}

#[test]
fn pipeline_rejects_conflicting_reflected_uniform_block_layouts() {
    let pipeline = ShaderPipeline::with_reflector(
        InMemoryShaderSourceProvider::new(),
        SourceCaptureCompiler,
        ConflictingUniformBlockReflector,
    );
    let request = interface_request(
        concat!(
            "uniform float g_Time;\n",
            "void main() {\n",
            "  gl_Position = vec4(g_Time);\n",
            "}\n",
        ),
        concat!(
            "uniform float g_Time;\n",
            "void main() {\n",
            "  gl_FragColor = vec4(g_Time);\n",
            "}\n",
        ),
    );

    let error = pipeline
        .compile(&request)
        .expect_err("conflicting reflected GlobalUniforms layouts should be rejected");

    assert!(matches!(error, ShaderError::InvalidRequest { .. }));
    assert!(error.to_string().contains("GlobalUniforms"));
}

#[test]
fn generated_uniform_block_allows_matching_member_with_one_explicit_binding() {
    let pipeline = pipeline();
    let request = ShaderProgramRequest::builder(
        ShaderName::new("program_uniform_explicit_binding").expect("valid name"),
    )
    .stage(ShaderStageSource::new(
        ShaderStageKind::Vertex,
        concat!(
            "layout(binding = 2) uniform float g_Time;\n",
            "in vec3 a_Position;\n",
            "void main() {\n",
            "  gl_Position = vec4(a_Position.xy * g_Time, a_Position.z, 1.0);\n",
            "}\n",
        ),
    ))
    .stage(ShaderStageSource::new(
        ShaderStageKind::Fragment,
        concat!(
            "uniform float g_Time;\n",
            "void main() {\n",
            "  gl_FragColor = vec4(g_Time);\n",
            "}\n",
        ),
    ))
    .build()
    .expect("program-uniform-explicit-binding request should be valid");

    let program = pipeline
        .compile(&request)
        .expect("matching duplicate uniform member should compile");
    let block = program
        .reflection()
        .uniform_blocks()
        .iter()
        .find(|block| block.name() == "GlobalUniforms")
        .expect("merged reflection should contain GlobalUniforms");

    assert_eq!(block.binding().binding(), 2);
    assert_eq!(
        block
            .members()
            .iter()
            .map(|member| member.name())
            .collect::<Vec<_>>(),
        ["g_Time"]
    );
}

#[test]
fn pipeline_preserves_layout_binding_and_array_suffix_facts_through_assembly() {
    let pipeline = pipeline();
    let request = interface_request(
        concat!(
            "#define LOCAL_COUNT 4\n",
            "layout(binding = 5) uniform vec4 g_Offsets[LOCAL_COUNT];\n",
            "void main() {\n",
            "  gl_Position = g_Offsets[3];\n",
            "}\n",
        ),
        concat!(
            "#define LOCAL_COUNT 4\n",
            "uniform vec4 g_Offsets[LOCAL_COUNT];\n",
            "void main() {\n",
            "  gl_FragColor = g_Offsets[2];\n",
            "}\n",
        ),
    );

    let program = pipeline
        .compile(&request)
        .expect("layout binding and array suffix facts should assemble");
    let vertex_source = legalized_stage_source(&program, ShaderStageKind::Vertex);
    let fragment_source = legalized_stage_source(&program, ShaderStageKind::Fragment);
    let block = program
        .reflection()
        .uniform_blocks()
        .iter()
        .find(|block| block.name() == "GlobalUniforms")
        .expect("merged reflection should contain GlobalUniforms");

    assert_eq!(block.binding().binding(), 5);
    assert_uniform_block_member_order(vertex_source, &["vec4 g_Offsets[4];"]);
    assert_uniform_block_member_order(fragment_source, &["vec4 g_Offsets[4];"]);
    assert!(vertex_source.contains("layout(std140, set = 0, binding = 5) uniform GlobalUniforms"));
    assert!(
        fragment_source.contains("layout(std140, set = 0, binding = 5) uniform GlobalUniforms")
    );
}

#[test]
fn pipeline_preserves_comment_separated_layout_binding_facts() {
    let pipeline = pipeline();
    let request = interface_request(
        concat!(
            "layout /*outer*/ (binding /*inner*/ = 5) uniform vec4 g_Offsets[4];\n",
            "void main() {\n",
            "  gl_Position = g_Offsets[3];\n",
            "}\n",
        ),
        concat!(
            "uniform vec4 g_Offsets[4];\n",
            "void main() {\n",
            "  gl_FragColor = g_Offsets[2];\n",
            "}\n",
        ),
    );

    let program = pipeline
        .compile(&request)
        .expect("comment-separated layout binding should assemble");
    let block = program
        .reflection()
        .uniform_blocks()
        .iter()
        .find(|block| block.name() == "GlobalUniforms")
        .expect("merged reflection should contain GlobalUniforms");

    assert_eq!(block.binding().binding(), 5);
}

#[test]
fn pipeline_preserves_first_binding_across_repeated_layout_qualifiers() {
    let pipeline = pipeline();
    let request = interface_request(
        concat!(
            "layout(binding = 5) layout(std140) uniform vec4 g_Offsets[4];\n",
            "void main() {\n",
            "  gl_Position = g_Offsets[3];\n",
            "}\n",
        ),
        concat!(
            "uniform vec4 g_Offsets[4];\n",
            "void main() {\n",
            "  gl_FragColor = g_Offsets[2];\n",
            "}\n",
        ),
    );

    let program = pipeline
        .compile(&request)
        .expect("repeated layout qualifiers should preserve explicit binding");
    let block = program
        .reflection()
        .uniform_blocks()
        .iter()
        .find(|block| block.name() == "GlobalUniforms")
        .expect("merged reflection should contain GlobalUniforms");

    assert_eq!(block.binding().binding(), 5);
}

#[test]
fn active_texture_slots_follow_source_texture_names_not_descriptor_bindings() {
    let pipeline = pipeline();
    let request = ShaderProgramRequest::builder(
        ShaderName::new("effects/program_resource_slots").expect("valid name"),
    )
    .stage(ShaderStageSource::new(
        ShaderStageKind::Vertex,
        concat!(
            "uniform mat4 g_ModelViewProjectionMatrix;\n",
            "attribute vec2 a_Position;\n",
            "varying vec2 v_Uv;\n",
            "void main() {\n",
            "  v_Uv = a_Position;\n",
            "  gl_Position = g_ModelViewProjectionMatrix * vec4(a_Position, 0.0, 1.0);\n",
            "}\n",
        ),
    ))
    .stage(ShaderStageSource::new(
        ShaderStageKind::Fragment,
        concat!(
            "uniform sampler2D g_Texture0;\n",
            "uniform sampler2D g_Texture1;\n",
            "uniform float g_Time;\n",
            "varying vec2 v_Uv;\n",
            "void main() {\n",
            "  gl_FragColor = texture2D(g_Texture1, v_Uv) * g_Time;\n",
            "}\n",
        ),
    ))
    .texture(ShaderTextureInfo::new(
        TextureSlot::new(0).expect("valid texture slot"),
        true,
        TextureFormatHint::Rgba8,
    ))
    .texture(ShaderTextureInfo::new(
        TextureSlot::new(1).expect("valid texture slot"),
        true,
        TextureFormatHint::Rgba8,
    ))
    .build()
    .expect("valid request");

    let program = pipeline.compile(&request).expect("shader should compile");
    let active_slots: Vec<_> = program
        .reflection()
        .active_texture_slots()
        .iter()
        .map(|slot| slot.index())
        .collect();

    assert_eq!(active_slots, vec![1]);
}

#[test]
fn pipeline_rejects_leading_zero_encoded_source_texture_binding() {
    let pipeline = pipeline();
    let request = ShaderProgramRequest::builder(
        ShaderName::new("effects/leading_zero_texture_slot").expect("valid name"),
    )
    .stage(ShaderStageSource::new(
        ShaderStageKind::Vertex,
        concat!(
            "attribute vec2 a_Position;\n",
            "void main() {\n",
            "  gl_Position = vec4(a_Position, 0.0, 1.0);\n",
            "}\n",
        ),
    ))
    .stage(ShaderStageSource::new(
        ShaderStageKind::Fragment,
        concat!(
            "uniform sampler2D g_Texture01;\n",
            "void main() {\n",
            "  gl_FragColor = texture2D(g_Texture01, vec2(0.5));\n",
            "}\n",
        ),
    ))
    .texture(ShaderTextureInfo::new(
        TextureSlot::new(1).expect("valid texture slot"),
        true,
        TextureFormatHint::Rgba8,
    ))
    .build()
    .expect("valid request");

    let error = pipeline
        .compile(&request)
        .expect_err("leading-zero encoded texture slot should be rejected");

    let ShaderError::Codegen { diagnostics } = error else {
        panic!("expected structured codegen error");
    };
    let diagnostic = diagnostics
        .first()
        .expect("leading-zero rejection should include diagnostic");
    assert_eq!(diagnostic.pass(), Some("Codegen"));
    assert!(diagnostic.message().contains("g_Texture01"));
    assert!(diagnostic.message().contains("canonical"));
}

#[test]
fn active_texture_slots_ignore_non_encoded_split_texture_descriptor_bindings() {
    let pipeline = pipeline();
    let request = ShaderProgramRequest::builder(
        ShaderName::new("effects/non_encoded_texture_slots").expect("valid name"),
    )
    .stage(ShaderStageSource::new(
        ShaderStageKind::Vertex,
        concat!(
            "uniform sampler2D g_Texture0;\n",
            "attribute vec2 a_Position;\n",
            "void main() {\n",
            "  vec4 sampled = textureLod(g_Texture0, vec2(0.5), 0.0);\n",
            "  gl_Position = sampled + vec4(a_Position, 0.0, 1.0);\n",
            "}\n",
        ),
    ))
    .stage(ShaderStageSource::new(
        ShaderStageKind::Fragment,
        concat!(
            "uniform sampler2D u_Mask;\n",
            "void main() {\n",
            "  gl_FragColor = texture2D(u_Mask, vec2(0.5));\n",
            "}\n",
        ),
    ))
    .texture(ShaderTextureInfo::new(
        TextureSlot::new(0).expect("valid texture slot"),
        true,
        TextureFormatHint::Rgba8,
    ))
    .build()
    .expect("valid request");

    let program = pipeline
        .compile(&request)
        .expect("shader with non-encoded split texture should compile");
    let fragment_source = legalized_stage_source(&program, ShaderStageKind::Fragment);
    let active_slots: Vec<_> = program
        .reflection()
        .active_texture_slots()
        .iter()
        .map(|slot| slot.index())
        .collect();
    let metadata_slots: Vec<_> = program
        .metadata()
        .active_texture_slots()
        .iter()
        .map(|slot| slot.index())
        .collect();

    assert!(fragment_source.contains("layout(set = 0, binding = 2) uniform texture2D u_Mask;"));
    assert!(
        fragment_source
            .contains("layout(set = 0, binding = 3) uniform sampler _we_Sampler_u_Mask;")
    );
    assert_eq!(active_slots, vec![0]);
    assert_eq!(metadata_slots, vec![0]);
}

#[test]
fn pipeline_extracts_metadata_from_expanded_includes_before_main() {
    let pipeline = ShaderPipeline::with_reflector(
        InMemoryShaderSourceProvider::new().with_source(
            IncludePath::new("common/material.glsl").expect("valid include path"),
            "uniform sampler2D g_Texture0; // {\"default\":\"white\",\"combo\":\"HAS_TEX\"}\n",
        ),
        SourceCaptureCompiler,
        EmptyReflector,
    );
    let request =
        ShaderProgramRequest::builder(ShaderName::new("include_meta").expect("valid name"))
            .stage(ShaderStageSource::new(
                ShaderStageKind::Vertex,
                "void main() { gl_Position = vec4(0.0); }\n",
            ))
            .stage(ShaderStageSource::new(
                ShaderStageKind::Fragment,
                concat!("#include \"common/material.glsl\"\n", "void main() {}\n",),
            ))
            .texture(ShaderTextureInfo::new(
                TextureSlot::new(0).expect("valid texture slot"),
                true,
                TextureFormatHint::Rgba8,
            ))
            .build()
            .expect("valid request");

    let program = pipeline
        .compile(&request)
        .expect("pipeline should compile include metadata source");

    assert_eq!(
        program.metadata().combos(),
        &[ShaderComboValue::new(
            ComboName::new("HAS_TEX").expect("valid combo"),
            "1"
        )]
    );
    assert_eq!(program.metadata().default_textures().len(), 1);
    assert_eq!(program.metadata().default_textures()[0].slot().index(), 0);
    assert_eq!(program.metadata().default_textures()[0].path(), "white");
}

#[test]
fn pipeline_extracts_blur_style_vec2_metadata_default_from_vertex_stage() {
    let pipeline = source_capture_pipeline();
    let request = interface_request(
        concat!(
            "// [COMBO] {\"material\":\"ui_editor_properties_kernel_size\",\"combo\":\"KERNEL\",",
            "\"type\":\"options\",\"default\":0,\"options\":{\"13x13\":0,\"7x7\":1,\"3x3\":2}}\n",
            "// [COMBO] {\"combo\":\"VERTICAL\",\"default\":1}\n",
            "attribute vec3 a_Position;\n",
            "attribute vec2 a_TexCoord;\n",
            "uniform mat4 g_ModelViewProjectionMatrix;\n",
            "uniform vec2 g_Scale; // {\"default\":\"1 1\",",
            "\"label\":\"ui_editor_properties_scale\",\"linked\":true,\"material\":\"scale\",",
            "\"range\":[0.01,2.0]}\n",
            "uniform vec4 g_Texture0Resolution;\n",
            "varying vec4 v_TexCoord;\n",
            "void main() {\n",
            "#if VERTICAL\n",
            "  gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);\n",
            "#else\n",
            "  gl_Position = vec4(a_Position, 1.0);\n",
            "#endif\n",
            "  v_TexCoord.xy = a_TexCoord;\n",
            "#if VERTICAL\n",
            "  v_TexCoord.z = 0;\n",
            "  v_TexCoord.w = g_Scale.y / g_Texture0Resolution.w;\n",
            "#else\n",
            "  v_TexCoord.z = g_Scale.x / g_Texture0Resolution.z;\n",
            "  v_TexCoord.w = 0;\n",
            "#endif\n",
            "}\n",
        ),
        "void main() { gl_FragColor = vec4(1.0); }\n",
    );

    let program = pipeline
        .compile(&request)
        .expect("blur-style shader should compile through metadata pipeline");

    assert_eq!(
        program.metadata().default_uniforms(),
        &[
            shader::DefaultUniformValue::new("g_Scale", PropertyValue::Vec2([1.0, 1.0]))
                .expect("valid default uniform")
        ]
    );

    let vertex_source = legalized_stage_source(&program, ShaderStageKind::Vertex);
    assert!(
        vertex_source
            .contains("gl_Position = ((g_ModelViewProjectionMatrix) * (vec4(a_Position, 1.0)));"),
        "{vertex_source}"
    );
    assert!(
        vertex_source.contains("v_TexCoord.w = g_Scale.y / g_Texture0Resolution.w;"),
        "{vertex_source}"
    );
}

#[test]
fn pipeline_extracts_inactive_combo_metadata_before_condition_stripping() {
    let pipeline = source_capture_pipeline();
    let request = interface_request(
        "void main() { gl_Position = vec4(0.0); }\n",
        concat!(
            "#if 0\n",
            "// [COMBO] {\"combo\":\"HIDDEN\",\"default\":1}\n",
            "#endif\n",
            "void main() {}\n",
        ),
    );

    let program = pipeline
        .compile(&request)
        .expect("pipeline should compile inactive metadata source");

    assert_eq!(
        program.metadata().combos(),
        &[ShaderComboValue::new(
            ComboName::new("HIDDEN").expect("valid combo"),
            "1"
        )]
    );
}

#[test]
fn pipeline_uses_annotation_combo_defaults_as_compile_macros() {
    let pipeline = pipeline();
    let request = interface_request(
        "void main() { gl_Position = vec4(0.0); }\n",
        concat!(
            "// [COMBO] {\"combo\":\"BLENDMODE\",\"default\":30}\n",
            "// [COMBO] {\"combo\":\"RESOLUTION\",\"default\":32}\n",
            "// [COMBO] {\"combo\":\"INVERT\",\"default\":0}\n",
            "vec3 ApplyBlending(int mode, vec3 base, vec3 tint, float mask) {\n",
            "  return mode == 30 ? mix(base, tint, mask) : base;\n",
            "}\n",
            "void main() {\n",
            "  float frequency = 0.5 * float(RESOLUTION);\n",
            "  float mask = frequency + float(INVERT);\n",
            "  vec3 color = ApplyBlending(BLENDMODE, vec3(0.0), vec3(1.0), mask);\n",
            "  gl_FragColor = vec4(color, 1.0);\n",
            "}\n",
        ),
    );

    let program = pipeline
        .compile(&request)
        .expect("annotation combo defaults should be visible to live shader expressions");
    let fragment_source = legalized_stage_source(&program, ShaderStageKind::Fragment);

    assert!(fragment_source.contains("#define BLENDMODE 30"));
    assert!(fragment_source.contains("#define RESOLUTION 32"));
    assert!(fragment_source.contains("#define INVERT 0"));
}

#[test]
fn conditional_texture_annotations_enable_the_sampled_mask_on_both_backends() {
    // The switch is declared inside the branch it enables, including through
    // an include. Discovering it after condition stripping loses the mask.
    for target in [ShaderTarget::VulkanSpirv, ShaderTarget::MetalMsl] {
        for (present, override_value, expected) in [
            (true, None, true),
            (false, None, false),
            (true, Some("0"), false),
            (true, Some("1"), true),
        ] {
            let mut provider = InMemoryShaderSourceProvider::new();
            provider.insert(
                IncludePath::new("mask.h").unwrap(),
                concat!(
                    "#if USE_MASK\n",
                    "uniform sampler2D g_Texture2; // {\"combo\":\"USE_MASK\",\"default\":\"util/white\"}\n",
                    "// [COMBO] {\"combo\":\"MASK_CHANNEL\",\"default\":1}\n",
                    "#endif\n",
                ),
            );
            let pipeline = DefaultShaderPipeline::new(provider, NagaCompiler);
            let mut request = ShaderProgramRequest::builder(
                ShaderName::new("effects/conditional_texture").unwrap(),
            )
            .target(target)
            .stage(ShaderStageSource::new(
                ShaderStageKind::Vertex,
                concat!(
                    "attribute vec2 a_Position;\n",
                    "#if USE_MASK\n",
                    "varying vec2 v_MaskUV;\n",
                    "#endif\n",
                    "void main() {\n",
                    "  gl_Position = vec4(a_Position, 0.0, 1.0);\n",
                    "#if USE_MASK\n",
                    "  v_MaskUV = a_Position * 0.5 + 0.5;\n",
                    "#endif\n",
                    "}\n",
                ),
            ))
            .stage(ShaderStageSource::new(
                ShaderStageKind::Fragment,
                concat!(
                    "#include \"mask.h\"\n",
                    "#if USE_MASK\n",
                    "varying vec2 v_MaskUV;\n",
                    "#endif\n",
                    "void main() {\n",
                    "  float mask = 1.0;\n",
                    "#if USE_MASK\n",
                    "  mask = texture2D(g_Texture2, v_MaskUV)[MASK_CHANNEL];\n",
                    "#endif\n",
                    "  gl_FragColor = vec4(mask);\n",
                    "}\n",
                ),
            ))
            .texture(ShaderTextureInfo::with_presence(
                TextureSlot::new(2).unwrap(),
                present,
                true,
                TextureFormatHint::Rgba8,
                [shader::TextureComponentState::disabled(); 4],
            ));
            if let Some(value) = override_value {
                request = request.combo(ShaderComboValue::new(
                    ComboName::new("USE_MASK").unwrap(),
                    value,
                ));
            }
            let program = pipeline.compile(&request.build().unwrap()).unwrap();
            let slots: Vec<_> = program
                .reflection()
                .active_texture_slots()
                .iter()
                .map(|slot| slot.index())
                .collect();
            assert_eq!(
                slots,
                if expected { vec![2] } else { vec![] },
                "{target:?}, present={present}, override={override_value:?}"
            );
            assert_eq!(
                program.reflection().descriptor_bindings().iter()
                    .any(|binding| binding.name() == "g_Texture2"),
                expected
            );
        }
    }
}

#[test]
fn disabled_texture_slots_do_not_enable_texture_annotation_combos() {
    let pipeline = pipeline();
    let request =
        ShaderProgramRequest::builder(ShaderName::new("genericimage4").expect("valid name"))
            .stage(ShaderStageSource::new(
                ShaderStageKind::Vertex,
                concat!(
                    "attribute vec2 a_Position;\n",
                    "void main() {\n",
                    "  gl_Position = vec4(a_Position, 0.0, 1.0);\n",
                    "}\n",
                ),
            ))
            .stage(ShaderStageSource::new(
                ShaderStageKind::Fragment,
                concat!(
                    "// [COMBO] {\"combo\":\"LIGHTING\",\"default\":1}\n",
                    "uniform sampler2D g_Texture0; // {\"default\":\"util/white\"}\n",
                    "#if LIGHTING\n",
                    "uniform sampler2D g_Texture1; // {\"combo\":\"NORMALMAP\",",
                    "\"format\":\"rg88\",\"formatcombo\":true}\n",
                    "#endif\n",
                    "void main() {\n",
                    "  vec4 color = texture2D(g_Texture0, vec2(0.5));\n",
                    "#if LIGHTING && NORMALMAP\n",
                    "  color += texture2D(g_Texture1, vec2(0.5));\n",
                    "#endif\n",
                    "  gl_FragColor = color;\n",
                    "}\n",
                ),
            ))
            .texture(ShaderTextureInfo::new(
                TextureSlot::new(0).expect("valid texture slot"),
                true,
                TextureFormatHint::Rgba8,
            ))
            .texture(ShaderTextureInfo::with_presence(
                TextureSlot::new(1).expect("valid texture slot"),
                false,
                false,
                TextureFormatHint::Unknown,
                [shader::TextureComponentState::disabled(); 4],
            ))
            .build()
            .expect("request should be valid");

    let program = pipeline
        .compile(&request)
        .expect("disabled texture slot should compile");
    let normalmap = program
        .metadata()
        .combos()
        .iter()
        .find(|combo| combo.name().as_str() == "NORMALMAP")
        .expect("texture annotation should emit NORMALMAP");

    assert_eq!(normalmap.value(), "0");
    assert!(
        !program
            .reflection()
            .descriptor_bindings()
            .iter()
            .any(|binding| binding.name() == "g_Texture1"),
        "disabled normal-map texture should not be reflected as a live descriptor"
    );
}

#[test]
fn pipeline_resolves_combo_sized_uniform_arrays_in_generated_block() {
    let pipeline = pipeline();
    let request = ShaderProgramRequest::builder(
        ShaderName::new("models/bonecount_array").expect("valid name"),
    )
    .stage(ShaderStageSource::new(
        ShaderStageKind::Vertex,
        concat!(
            "uniform mat4x3 g_Bones[BONECOUNT];\n",
            "attribute vec3 a_Position;\n",
            "void main() {\n",
            "    vec3 localPos = a_Position;\n",
            "    localPos = mul(vec4(localPos, 1.0), g_Bones[0]);\n",
            "    gl_Position = vec4(localPos, 1.0);\n",
            "}\n",
        ),
    ))
    .stage(ShaderStageSource::new(
        ShaderStageKind::Fragment,
        "void main() { gl_FragColor = vec4(1.0); }\n",
    ))
    .combo(ShaderComboValue::new(
        ComboName::new("BONECOUNT").expect("valid combo"),
        "1",
    ))
    .build()
    .expect("request should be valid");

    let program = pipeline
        .compile(&request)
        .expect("combo-sized generated uniform array should compile");
    let vertex_source = legalized_stage_source(&program, ShaderStageKind::Vertex);

    assert!(
        vertex_source.contains("mat4x3 g_Bones[1];"),
        "BONECOUNT should be resolved before Naga parses generated uniforms:\n{vertex_source}"
    );
    assert!(!vertex_source.contains("g_Bones[BONECOUNT]"));
}

#[test]
fn pipeline_does_not_restore_inactive_annotation_combo_default_after_request_combo_stabilizes() {
    let pipeline = source_capture_pipeline();
    let request = ShaderProgramRequest::builder(
        ShaderName::new("effects/default_texture_stabilized").expect("valid name"),
    )
    .stage(ShaderStageSource::new(
        ShaderStageKind::Vertex,
        concat!(
            "attribute vec2 a_Position;\n",
            "varying vec2 v_Uv;\n",
            "void main() {\n",
            "  v_Uv = a_Position;\n",
            "  gl_Position = vec4(a_Position, 0.0, 1.0);\n",
            "}\n",
        ),
    ))
    .stage(ShaderStageSource::new(
        ShaderStageKind::Fragment,
        concat!(
            "uniform sampler2D g_Texture0; // {\"default\":\"fallback-r8.tex\"}\n",
            "#ifndef TEX0FORMAT\n",
            "// [COMBO] {\"combo\":\"FIRST_PASS_ONLY\",\"default\":1}\n",
            "#endif\n",
            "#if FIRST_PASS_ONLY\n",
            "uniform float g_StaleFirstPassMarker;\n",
            "#endif\n",
            "#if TEX0FORMAT == 9\n",
            "uniform sampler2D g_Texture1; // {\"default\":\"second-r8.tex\"}\n",
            "#endif\n",
            "#if TEX1FORMAT == 9\n",
            "uniform float g_CascadedDefaultObserved;\n",
            "#endif\n",
            "varying vec2 v_Uv;\n",
            "void main() {\n",
            "  vec4 color = texture(g_Texture0, v_Uv);\n",
            "#if TEX1FORMAT == 9\n",
            "  color += texture(g_Texture1, v_Uv);\n",
            "  color.r += g_CascadedDefaultObserved;\n",
            "#endif\n",
            "  gl_FragColor = color;\n",
            "}\n",
        ),
    ))
    .texture(ShaderTextureInfo::new(
        TextureSlot::new(0).expect("valid texture slot"),
        true,
        TextureFormatHint::R8,
    ))
    .texture(ShaderTextureInfo::new(
        TextureSlot::new(1).expect("valid texture slot"),
        true,
        TextureFormatHint::R8,
    ))
    .combo(ShaderComboValue::new(
        ComboName::new("TEX0FORMAT").expect("valid combo"),
        "9",
    ))
    .combo(ShaderComboValue::new(
        ComboName::new("TEX1FORMAT").expect("valid combo"),
        "9",
    ))
    .build()
    .expect("valid request");

    let program = pipeline
        .compile(&request)
        .expect("stabilized request should compile");
    let fragment_source = legalized_stage_source(&program, ShaderStageKind::Fragment);

    assert!(fragment_source.contains("g_CascadedDefaultObserved"));
    assert!(!fragment_source.contains("g_StaleFirstPassMarker"));
    assert!(!fragment_source.contains("#define FIRST_PASS_ONLY 1"));
}

#[test]
fn pipeline_reflects_split_images_and_per_texture_samplers() {
    let pipeline = pipeline();
    let request = ShaderProgramRequest::builder(
        ShaderName::new("effects/split_texture_samplers").expect("valid name"),
    )
    .stage(ShaderStageSource::new(
        ShaderStageKind::Vertex,
        concat!(
            "attribute vec2 a_Position;\n",
            "varying vec2 v_Uv;\n",
            "void main() {\n",
            "  v_Uv = a_Position;\n",
            "  gl_Position = vec4(a_Position, 0.0, 1.0);\n",
            "}\n",
        ),
    ))
    .stage(ShaderStageSource::new(
        ShaderStageKind::Fragment,
        concat!(
            "uniform sampler2D g_Texture0;\n",
            "uniform sampler2D g_Texture1;\n",
            "varying vec2 v_Uv;\n",
            "void main() {\n",
            "  gl_FragColor = texture2D(g_Texture0, v_Uv) + texture2D(g_Texture1, v_Uv);\n",
            "}\n",
        ),
    ))
    .texture(ShaderTextureInfo::new(
        TextureSlot::new(0).expect("valid texture slot"),
        true,
        TextureFormatHint::Rgba8,
    ))
    .texture(ShaderTextureInfo::new(
        TextureSlot::new(1).expect("valid texture slot"),
        true,
        TextureFormatHint::Rgba8,
    ))
    .build()
    .expect("valid request");

    let program = pipeline.compile(&request).expect("shader should compile");

    assert!(
        program
            .reflection()
            .descriptor_bindings()
            .iter()
            .any(|binding| {
                binding.name() == "g_Texture0"
                    && binding.kind() == ShaderDescriptorKind::SampledImage
            })
    );
    assert!(
        program
            .reflection()
            .descriptor_bindings()
            .iter()
            .any(|binding| {
                binding.name() == "g_Texture1"
                    && binding.kind() == ShaderDescriptorKind::SampledImage
            })
    );
    assert!(
        program
            .reflection()
            .descriptor_bindings()
            .iter()
            .any(|binding| {
                binding.name() == "_we_Sampler_g_Texture0"
                    && binding.kind() == ShaderDescriptorKind::Sampler
            })
    );
    assert!(
        program
            .reflection()
            .descriptor_bindings()
            .iter()
            .any(|binding| {
                binding.name() == "_we_Sampler_g_Texture1"
                    && binding.kind() == ShaderDescriptorKind::Sampler
            })
    );
}

#[test]
fn pipeline_omits_inactive_texture_descriptors_from_runtime_reflection() {
    let pipeline = pipeline();
    let request = ShaderProgramRequest::builder(
        ShaderName::new("effects/inactive_texture_descriptor").expect("valid name"),
    )
    .stage(ShaderStageSource::new(
        ShaderStageKind::Vertex,
        concat!(
            "attribute vec2 a_Position;\n",
            "varying vec2 v_Uv;\n",
            "void main() {\n",
            "  v_Uv = a_Position;\n",
            "  gl_Position = vec4(a_Position, 0.0, 1.0);\n",
            "}\n",
        ),
    ))
    .stage(ShaderStageSource::new(
        ShaderStageKind::Fragment,
        concat!(
            "uniform sampler2D g_Texture0;\n",
            "uniform sampler2D g_Texture1;\n",
            "varying vec2 v_Uv;\n",
            "void main() {\n",
            "  gl_FragColor = texture2D(g_Texture0, v_Uv);\n",
            "}\n",
        ),
    ))
    .texture(ShaderTextureInfo::new(
        TextureSlot::new(0).expect("valid texture slot"),
        true,
        TextureFormatHint::Rgba8,
    ))
    .texture(ShaderTextureInfo::new(
        TextureSlot::new(1).expect("valid texture slot"),
        true,
        TextureFormatHint::Rgba8,
    ))
    .build()
    .expect("valid request");

    let program = pipeline.compile(&request).expect("shader should compile");
    let descriptor_names: Vec<&str> = program
        .reflection()
        .descriptor_bindings()
        .iter()
        .map(shader::ShaderDescriptorBinding::name)
        .collect();

    assert!(descriptor_names.contains(&"g_Texture0"));
    assert!(descriptor_names.contains(&"_we_Sampler_g_Texture0"));
    assert!(!descriptor_names.contains(&"g_Texture1"));
    assert!(!descriptor_names.contains(&"_we_Sampler_g_Texture1"));
}

#[test]
fn pipeline_preserves_inactive_metadata_without_resolving_inactive_missing_include() {
    let pipeline = source_capture_pipeline();
    let request = interface_request(
        "void main() { gl_Position = vec4(0.0); }\n",
        concat!(
            "#if 0\n",
            "#include \"optional_or_platform_only.glsl\"\n",
            "// [COMBO] {\"combo\":\"HIDDEN\",\"default\":1}\n",
            "#endif\n",
            "void main() {}\n",
        ),
    );

    let program = pipeline
        .compile(&request)
        .expect("inactive missing include should not be resolved");

    assert_eq!(
        program.metadata().combos(),
        &[ShaderComboValue::new(
            ComboName::new("HIDDEN").expect("valid combo"),
            "1"
        )]
    );
}

#[test]
fn pipeline_synthesizes_vertex_output_for_fragment_only_varying() {
    let pipeline = source_capture_pipeline();
    let request = interface_request(
        concat!(
            "attribute vec2 a_Position;\n",
            "void main() {\n",
            "  gl_Position = vec4(a_Position, 0.0, 1.0);\n",
            "}\n",
        ),
        concat!(
            "varying vec2 v_Uv;\n",
            "void main() {\n",
            "  gl_FragColor = vec4(v_Uv, 0.0, 1.0);\n",
            "}\n",
        ),
    );

    let program = pipeline
        .compile(&request)
        .expect("fragment-only varying should be supplied by a synthesized vertex output");
    let vertex_source = legalized_stage_source(&program, ShaderStageKind::Vertex);

    assert!(vertex_source.contains("layout(location = 0) out vec2 v_Uv;"));
    assert!(vertex_source.contains("v_Uv = vec2(0.0);"));
}

#[test]
fn pipeline_synthesized_vertex_output_initialization_compiles_through_naga() {
    let pipeline = pipeline();
    let request = interface_request(
        concat!(
            "attribute vec3 a_Position;\n",
            "void main() {\n",
            "  vec3 position = a_Position;\n",
            "  gl_Position = vec4(position, 1.0);\n",
            "}\n",
        ),
        concat!(
            "varying vec2 v_TexCoord;\n",
            "void main() {\n",
            "  gl_FragColor = vec4(v_TexCoord, 0.0, 1.0);\n",
            "}\n",
        ),
    );

    let program = pipeline
        .compile(&request)
        .expect("genericimage4-style synthesized vertex output should validate");
    let vertex_source = legalized_stage_source(&program, ShaderStageKind::Vertex);

    assert!(vertex_source.contains("layout(location = 0) out vec2 v_TexCoord;"));
    assert!(vertex_source.contains("v_TexCoord = vec2(0.0);"));
}

#[test]
fn pipeline_synthesizes_unique_vertex_output_when_fragment_only_name_collides_with_vertex_input() {
    let pipeline = source_capture_pipeline();
    let request = interface_request(
        concat!(
            "attribute vec2 v_Uv;\n",
            "void main() {\n",
            "  gl_Position = vec4(v_Uv, 0.0, 1.0);\n",
            "}\n",
        ),
        concat!(
            "varying vec2 v_Uv;\n",
            "void main() {\n",
            "  gl_FragColor = vec4(v_Uv, 0.0, 1.0);\n",
            "}\n",
        ),
    );

    let program = pipeline
        .compile(&request)
        .expect("fragment-only varying should avoid colliding with vertex globals");
    let vertex_source = legalized_stage_source(&program, ShaderStageKind::Vertex);
    let fragment_source = legalized_stage_source(&program, ShaderStageKind::Fragment);

    assert!(vertex_source.contains("layout(location = 0) in vec2 v_Uv;"));
    assert!(vertex_source.contains("layout(location = 0) out vec2 _we_out_v_Uv;"));
    assert!(vertex_source.contains("_we_out_v_Uv = vec2(0.0);"));
    assert!(!vertex_source.contains("layout(location = 0) out vec2 v_Uv;"));
    assert!(fragment_source.contains("layout(location = 0) in vec2 v_Uv;"));
}

#[test]
fn pipeline_synthesizes_unique_vertex_output_when_fragment_only_name_collides_with_vertex_global() {
    let pipeline = source_capture_pipeline();
    let request = interface_request(
        concat!(
            "vec2 v_Uv;\n",
            "void main() {\n",
            "  v_Uv = vec2(1.0);\n",
            "  gl_Position = vec4(v_Uv, 0.0, 1.0);\n",
            "}\n",
        ),
        concat!(
            "varying vec2 v_Uv;\n",
            "void main() {\n",
            "  gl_FragColor = vec4(v_Uv, 0.0, 1.0);\n",
            "}\n",
        ),
    );

    let program = pipeline
        .compile(&request)
        .expect("fragment-only varying should avoid colliding with vertex globals");
    let vertex_source = legalized_stage_source(&program, ShaderStageKind::Vertex);
    let fragment_source = legalized_stage_source(&program, ShaderStageKind::Fragment);

    assert!(vertex_source.contains("vec2 v_Uv;"));
    assert!(vertex_source.contains("layout(location = 0) out vec2 _we_out_v_Uv;"));
    assert!(vertex_source.contains("_we_out_v_Uv = vec2(0.0);"));
    assert!(!vertex_source.contains("layout(location = 0) out vec2 v_Uv;"));
    assert!(fragment_source.contains("layout(location = 0) in vec2 v_Uv;"));
}

#[test]
fn pipeline_reserves_generated_vertex_output_names_for_later_fragment_only_varyings() {
    let pipeline = source_capture_pipeline();
    let request = interface_request(
        concat!(
            "attribute vec2 v_Uv;\n",
            "attribute vec2 v_Uv_1;\n",
            "vec2 _we_out_v_Uv;\n",
            "void main() {\n",
            "  gl_Position = vec4(v_Uv + v_Uv_1 + _we_out_v_Uv, 0.0, 1.0);\n",
            "}\n",
        ),
        concat!(
            "varying vec2 v_Uv;\n",
            "varying vec2 v_Uv_1;\n",
            "void main() {\n",
            "  gl_FragColor = vec4(v_Uv + v_Uv_1, 0.0, 1.0);\n",
            "}\n",
        ),
    );

    let program = pipeline
        .compile(&request)
        .expect("generated vertex outputs should be unique across fragment-only varyings");
    let vertex_source = legalized_stage_source(&program, ShaderStageKind::Vertex);

    assert!(vertex_source.contains("layout(location = 0) out vec2 _we_out_v_Uv_1;"));
    assert!(vertex_source.contains("layout(location = 1) out vec2 _we_out_v_Uv_1_1;"));
    assert!(vertex_source.contains("_we_out_v_Uv_1 = vec2(0.0);"));
    assert!(vertex_source.contains("_we_out_v_Uv_1_1 = vec2(0.0);"));
}

#[test]
fn pipeline_keeps_vertex_only_varying_without_fragment_input() {
    let pipeline = source_capture_pipeline();
    let request = interface_request(
        concat!(
            "attribute vec2 a_Position;\n",
            "varying vec2 v_Uv;\n",
            "void main() {\n",
            "  v_Uv = a_Position;\n",
            "  gl_Position = vec4(a_Position, 0.0, 1.0);\n",
            "}\n",
        ),
        concat!("void main() {\n", "  gl_FragColor = vec4(1.0);\n", "}\n",),
    );

    let program = pipeline
        .compile(&request)
        .expect("vertex-only varying should not block scene shader compilation");
    let vertex_source = legalized_stage_source(&program, ShaderStageKind::Vertex);
    let fragment_source = legalized_stage_source(&program, ShaderStageKind::Fragment);

    assert!(vertex_source.contains("layout(location = 0) out vec2 v_Uv;"));
    assert!(!fragment_source.contains("v_Uv"));
}

#[test]
fn pipeline_normalizes_cross_stage_varying_to_fragment_width_when_vertex_writes_subset() {
    let capture_pipeline = source_capture_pipeline();
    let request = interface_request(
        concat!(
            "attribute vec2 a_Position;\n",
            "varying vec4 v_TexCoord;\n",
            "void main() {\n",
            "  v_TexCoord.xy = a_Position;\n",
            "  gl_Position = vec4(a_Position, 0.0, 1.0);\n",
            "}\n",
        ),
        concat!(
            "varying vec2 v_TexCoord;\n",
            "void main() {\n",
            "  gl_FragColor = vec4(v_TexCoord, 0.0, 1.0);\n",
            "}\n",
        ),
    );

    let program = capture_pipeline
        .compile(&request)
        .expect("vertex vec4 varying written through .xy should match fragment vec2 input");
    let vertex_source = legalized_stage_source(&program, ShaderStageKind::Vertex);
    let fragment_source = legalized_stage_source(&program, ShaderStageKind::Fragment);

    assert!(vertex_source.contains("layout(location = 0) out vec2 v_TexCoord;"));
    assert!(vertex_source.contains("v_TexCoord.xy = a_Position;"));
    assert!(fragment_source.contains("layout(location = 0) in vec2 v_TexCoord;"));

    let _compiled = pipeline()
        .compile(&request)
        .expect("narrowed cross-stage varying should compile through Naga");
}

#[test]
fn pipeline_widens_fragment_varying_for_components_beyond_its_declaration() {
    // Sine Wave Circle declares a vec2 fragment input but unconditionally
    // samples its .zw mask coordinates. The vec4 producer only writes .zw
    // when the mask combo is enabled; neither variant may narrow the interface.
    for mask in [0, 1] {
        let request = interface_request(
            format!(
                "#define MASK {mask}\n{}",
                concat!(
                    "attribute vec2 a_Position;\n",
                    "varying vec4 v_TexCoord;\n",
                    "void main() {\n",
                    "  gl_Position = vec4(a_Position, 0.0, 1.0);\n",
                    "  v_TexCoord.xy = a_Position;\n",
                    "#if MASK == 1\n",
                    "  v_TexCoord.zw = a_Position * 0.5;\n",
                    "#endif\n",
                    "}\n",
                ),
            ),
            concat!(
                "uniform vec4 g_Texture0Resolution;\n",
                "varying vec2 v_TexCoord;\n",
                "uniform sampler2D g_Texture0;\n",
                "uniform sampler2D g_Texture1;\n",
                "vec3 ApplyBlending(int mode, vec3 base, vec3 color, float amount) {\n",
                "  return mix(base, color, amount);\n",
                "}\n",
                "void main() {\n",
                "  vec4 scene = texture(g_Texture0, v_TexCoord);\n",
                "  float mask = texture(g_Texture1, v_TexCoord.zw).r;\n",
                "  vec2 p = v_TexCoord * g_Texture0Resolution.xy;\n",
                "  vec3 color = vec3(p, 0.5);\n",
                "  color = ApplyBlending(0, scene.rgb, color.rgb, 0.25 + color * mask);\n",
                "  gl_FragColor = vec4(color, scene.a);\n",
                "}\n",
            ),
        );

        let program = pipeline()
            .compile(&request)
            .expect("out-of-declaration fragment swizzle should compile through Naga");
        for stage in program.stages() {
            let naga_stage = match stage.kind() {
                ShaderStageKind::Vertex => naga::ShaderStage::Vertex,
                ShaderStageKind::Fragment => naga::ShaderStage::Fragment,
            };
            let module = naga::front::glsl::Frontend::default()
                .parse(
                    &naga::front::glsl::Options::from(naga_stage),
                    stage.legalized_source().expect("compiled GLSL is retained"),
                )
                .expect("compiled stage remains valid GLSL");
            let varying = module
                .global_variables
                .iter()
                .find_map(|(_, variable)| {
                    (variable.name.as_deref() == Some("v_TexCoord")).then_some(variable)
                })
                .expect("stage retains texture coordinate varying");
            assert!(matches!(
                module.types[varying.ty].inner,
                naga::TypeInner::Vector {
                    size: naga::VectorSize::Quad,
                    ..
                }
            ));
        }
    }
}

#[test]
fn pipeline_rejects_cross_stage_narrowing_when_vertex_writes_discarded_components() {
    let pipeline = pipeline();
    let request = interface_request(
        concat!(
            "attribute vec2 a_Position;\n",
            "varying vec4 v_Uv;\n",
            "void main() {\n",
            "  v_Uv.xy = a_Position;\n",
            "  v_Uv.zw = vec2(1.0);\n",
            "  gl_Position = vec4(a_Position, 0.0, 1.0);\n",
            "}\n",
        ),
        concat!(
            "varying vec2 v_Uv;\n",
            "void main() {\n",
            "  gl_FragColor = vec4(v_Uv, 0.0, 1.0);\n",
            "}\n",
        ),
    );

    let err = pipeline
        .compile(&request)
        .expect_err("discarded vertex output components should block narrowing");

    assert_cross_stage_error(
        err,
        "cross-stage varying `v_Uv` type mismatch: vertex outputs vec4 but fragment inputs vec2",
    );
}

#[test]
fn pipeline_does_not_export_macro_aliased_sv_position_as_cross_stage_output() {
    let capture_pipeline = source_capture_pipeline();
    let request = interface_request(
        concat!(
            "#define gl_Position _ww_sv_position\n",
            "out vec2 v_TexCoord;\n",
            "out vec4 _ww_sv_position;\n",
            "void main() {\n",
            "  v_TexCoord = vec2(0.25, 0.75);\n",
            "  _ww_sv_position = vec4(0.0, 0.0, 0.0, 1.0);\n",
            "#undef gl_Position\n",
            "  gl_Position = _ww_sv_position;\n",
            "}\n",
        ),
        concat!(
            "in vec2 v_TexCoord;\n",
            "void main() {\n",
            "  gl_FragColor = vec4(v_TexCoord, 0.0, 1.0);\n",
            "}\n",
        ),
    );

    let program = capture_pipeline
        .compile(&request)
        .expect("macro-aliased position should not participate in cross-stage IO");
    let vertex_source = legalized_stage_source(&program, ShaderStageKind::Vertex);
    let fragment_source = legalized_stage_source(&program, ShaderStageKind::Fragment);

    assert!(vertex_source.contains("layout(location = 0) out vec2 v_TexCoord;"));
    assert!(!vertex_source.contains("out vec4 _ww_sv_position"));
    assert!(!vertex_source.contains("layout(location = 1) out vec4 _ww_sv_position"));
    assert!(vertex_source.contains("vec4 _ww_sv_position;"));
    assert!(fragment_source.contains("layout(location = 0) in vec2 v_TexCoord;"));

    let _compiled = pipeline()
        .compile(&request)
        .expect("macro-aliased position source should compile through Naga");
}

#[test]
fn pipeline_narrows_plain_vertex_output_assignment_to_fragment_varying_width() {
    let capture_pipeline = source_capture_pipeline();
    let request = interface_request(
        concat!(
            "attribute vec3 a_Position;\n",
            "attribute vec2 a_TexCoord;\n",
            "uniform mat4 g_ModelViewProjectionMatrix;\n",
            "varying vec4 v_TexCoord;\n",
            "void main() {\n",
            "  gl_Position = g_ModelViewProjectionMatrix * vec4(a_Position, 1.0);\n",
            "  v_TexCoord = a_TexCoord.xyxy;\n",
            "}\n",
        ),
        concat!(
            "varying vec2 v_TexCoord;\n",
            "void main() {\n",
            "  gl_FragColor = vec4(v_TexCoord, 0.0, 1.0);\n",
            "}\n",
        ),
    );

    let program = capture_pipeline
        .compile(&request)
        .expect("vertex vec4 varying should normalize to fragment vec2 input");
    let vertex_source = legalized_stage_source(&program, ShaderStageKind::Vertex);

    assert!(vertex_source.contains("layout(location = 0) out vec2 v_TexCoord;"));
    assert!(vertex_source.contains("v_TexCoord = a_TexCoord.xyxy.xy;"));

    let _compiled = pipeline()
        .compile(&request)
        .expect("narrowed vertex output assignment should compile through Naga");
}

// The shipped `cloudmotion` effect assigns its whole `vec4 v_TexCoord` to the
// `vec2 v_NoiseCoord` varying. HLSL keeps the leading components; GLSL refuses
// the assignment, and the whole effect used to fail to load. A local vector
// assigned from a wider one takes the same path through declaration facts.
#[test]
fn pipeline_narrows_whole_vector_identifier_assigned_to_narrower_target() {
    let capture_pipeline = source_capture_pipeline();
    let request = interface_request(
        concat!(
            "attribute vec3 a_Position;\n",
            "attribute vec2 a_TexCoord;\n",
            "uniform mat4 g_ModelViewProjectionMatrix;\n",
            "varying vec4 v_TexCoord;\n",
            "varying vec2 v_NoiseCoord;\n",
            "void main() {\n",
            "  gl_Position = g_ModelViewProjectionMatrix * vec4(a_Position, 1.0);\n",
            "  v_TexCoord.xyzw = a_TexCoord.xyxy;\n",
            "  v_NoiseCoord = v_TexCoord;\n",
            "  vec3 wide = vec3(v_NoiseCoord, 1.0);\n",
            "  vec2 shift = vec2(0.0, 0.0);\n",
            "  shift = wide;\n",
            "  v_NoiseCoord += shift;\n",
            "}\n",
        ),
        concat!(
            "varying vec4 v_TexCoord;\n",
            "varying vec2 v_NoiseCoord;\n",
            "uniform sampler2D g_Texture0;\n",
            "void main() {\n",
            "  gl_FragColor = texSample2D(g_Texture0, v_TexCoord.xy + v_NoiseCoord);\n",
            "}\n",
        ),
    );

    let program = capture_pipeline
        .compile(&request)
        .expect("a whole vector assigned to a narrower target should narrow");
    let vertex_source = legalized_stage_source(&program, ShaderStageKind::Vertex);

    assert!(vertex_source.contains("v_NoiseCoord = v_TexCoord.xy;"), "{vertex_source}");
    assert!(vertex_source.contains("shift = wide.xy;"), "{vertex_source}");

    let _compiled = pipeline()
        .compile(&request)
        .expect("the narrowed assignments should compile through Naga");
}

#[test]
fn pipeline_compiles_vec4_varying_assigned_from_repeated_vec2_swizzle() {
    let request = interface_request(
        concat!(
            "attribute vec3 a_Position;\n",
            "attribute vec2 a_TexCoord;\n",
            "uniform mat4 g_ModelViewProjectionMatrix;\n",
            "varying vec4 v_TexCoord;\n",
            "varying vec2 v_TexCoordIris;\n",
            "void main() {\n",
            "  gl_Position = g_ModelViewProjectionMatrix * vec4(a_Position, 1.0);\n",
            "  v_TexCoord = a_TexCoord.xyxy;\n",
            "  v_TexCoordIris = vec2(0.0);\n",
            "}\n",
        ),
        concat!(
            "varying vec4 v_TexCoord;\n",
            "varying vec2 v_TexCoordIris;\n",
            "uniform sampler2D g_Texture0;\n",
            "void main() {\n",
            "  vec4 albedo = texture(g_Texture0, v_TexCoord.xy + v_TexCoordIris.xy);\n",
            "  gl_FragColor = albedo;\n",
            "}\n",
        ),
    );

    let _compiled = pipeline()
        .compile(&request)
        .expect("vec4 varying assigned from repeated vec2 swizzle should compile through Naga");
}

#[test]
fn pipeline_narrows_generated_vec4_fragment_coordinate_for_sampler2d() {
    let request = interface_request(
        concat!(
            "attribute vec3 a_Position;\n",
            "attribute vec2 a_TexCoord;\n",
            "varying vec4 v_TexCoord;\n",
            "void main() {\n",
            "  gl_Position = vec4(a_Position, 1.0);\n",
            "  v_TexCoord = a_TexCoord.xyxy;\n",
            "}\n",
        ),
        concat!(
            "varying vec4 v_TexCoord;\n",
            "uniform sampler2D g_Texture0;\n",
            "void main() {\n",
            "  vec4 scene = texSample2D(g_Texture0, v_TexCoord);\n",
            "  gl_FragColor = scene;\n",
            "}\n",
        ),
    );

    let program = pipeline()
        .compile(&request)
        .expect("generated vec4 fragment coordinate should compile through Naga");
    let fragment_source = legalized_stage_source(&program, ShaderStageKind::Fragment);

    assert!(fragment_source.contains(
        "vec4 scene = texture(sampler2D(g_Texture0, _we_Sampler_g_Texture0), v_TexCoord.xy);"
    ));
    assert!(
        !fragment_source.contains("sampler2D(g_Texture0, _we_Sampler_g_Texture0), v_TexCoord);")
    );
}

/// The parts of Wallpaper Engine's `common_pbr_2.h` a generated lighting block
/// calls, reduced to the same signatures.
const PBR_LIGHTING_STUB: &str = concat!(
    "#define CAST3(x) vec3(x)\n",
    "vec3 PointSegmentDelta(vec3 pos, vec3 a, vec3 b) { return a - pos + (b - a) * 0.5; }\n",
    "vec3 ComputePBRLightShadow(vec3 N, vec3 L, vec3 V, vec3 albedo, vec3 lightColor,\n",
    "    float radius, float exponent, vec3 specularTint, vec3 baseReflectance, float roughness,\n",
    "    float metallic, float shadowFactor) {\n",
    "  float falloff = clamp(1.0 - length(L) / radius, 0.0, 1.0);\n",
    "  return albedo * lightColor * pow(falloff, exponent) * max(dot(N, normalize(L)), 0.0) * shadowFactor;\n",
    "}\n",
    "vec3 ComputePBRLightShadowInfinite(vec3 N, vec3 L, vec3 V, vec3 albedo, vec3 lightColor,\n",
    "    vec3 specularTint, vec3 baseReflectance, float roughness, float metallic, float shadowFactor) {\n",
    "  return albedo * lightColor * max(dot(N, L), 0.0) * shadowFactor;\n",
    "}\n",
);

fn lit_layer_request(target: ShaderTarget, combos: &[(&str, &str)]) -> ShaderProgramRequest {
    let mut builder = ShaderProgramRequest::builder(ShaderName::new("lit_layer").unwrap())
        .target(target)
        .stage(ShaderStageSource::new(ShaderStageKind::Vertex, concat!(
            "uniform mat4 g_ModelViewProjectionMatrix;\n",
            "attribute vec3 a_Position;\n",
            "varying vec3 v_WorldPos;\n",
            "void main() { v_WorldPos = a_Position; gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix); }\n",
        )))
        .stage(ShaderStageSource::new(ShaderStageKind::Fragment, concat!(
            "// [COMBO] {\"material\":\"lighting\",\"combo\":\"LIGHTING\",\"default\":0}\n",
            "#include \"common_pbr_2.h\"\n",
            "varying vec3 v_WorldPos;\n",
            "#require LightingV1\n",
            "void main() {\n",
            "  vec3 color = vec3(0.5);\n",
            "#if LIGHTING\n",
            "  color = PerformLighting_V1(v_WorldPos, color, vec3(0.0, 0.0, 1.0), vec3(0.0, 0.0, 1.0),\n",
            "      CAST3(1.0), CAST3(0.04), 1.0, 0.0);\n",
            "#endif\n",
            "  gl_FragColor = vec4(color, 1.0);\n",
            "}\n",
        )));
    for (name, value) in combos {
        builder = builder.combo(ShaderComboValue::new(ComboName::new(*name).unwrap(), *value));
    }
    builder.build().unwrap()
}

fn lit_layer_pipeline() -> DefaultShaderPipeline<InMemoryShaderSourceProvider> {
    DefaultShaderPipeline::new(
        InMemoryShaderSourceProvider::new()
            .with_source(IncludePath::new("common_pbr_2.h").unwrap(), PBR_LIGHTING_STUB),
        NagaCompiler,
    )
}

#[test]
fn a_lit_pass_gets_wallpaper_engines_light_arrays_sized_by_the_scene_on_both_backends() {
    for target in [ShaderTarget::VulkanSpirv, ShaderTarget::MetalMsl] {
        let request = lit_layer_request(target, &[
            ("LIGHTING", "1"),
            ("LIGHTS_POINT", "3"),
            ("LIGHTS_SPOT", "1"),
            ("LIGHTS_TUBE", "2"),
            ("LIGHTS_DIRECTIONAL", "1"),
        ]);
        let program = lit_layer_pipeline().compile(&request)
            .unwrap_or_else(|error| panic!("lit pass should compile for {target:?}: {error}"));
        let members: Vec<_> = program.reflection().uniform_blocks().iter()
            .flat_map(|block| block.members())
            .map(|member| (member.name().to_owned(), member.array_count()))
            .collect();
        for (name, count) in [
            ("g_LPoint_Color", 3), ("g_LPoint_Origin", 3),
            ("g_LSpot_Color", 1), ("g_LSpot_Origin", 1), ("g_LSpot_Direction", 1), ("g_LSpot_Exponent", 1),
            ("g_LTube_Color", 2), ("g_LTube_OriginA", 2), ("g_LTube_OriginB", 2),
            ("g_LDirectional_Color", 1), ("g_LDirectional_Direction", 1),
        ] {
            assert!(members.contains(&(name.to_owned(), count)),
                "{target:?}: {name}[{count}] missing from {members:?}");
        }
    }
}

#[test]
fn an_unlit_pass_declares_no_light_arrays() {
    for target in [ShaderTarget::VulkanSpirv, ShaderTarget::MetalMsl] {
        let request = lit_layer_request(target, &[("LIGHTS_POINT", "3")]);
        let program = lit_layer_pipeline().compile(&request)
            .unwrap_or_else(|error| panic!("unlit pass should compile for {target:?}: {error}"));
        assert!(!program.reflection().uniform_blocks().iter()
            .flat_map(|block| block.members())
            .any(|member| member.name().starts_with("g_L")));
    }
}

#[test]
fn every_asset_shader_that_requires_lighting_compiles_lit_and_fogged_on_both_backends() {
    let test = "every_asset_shader_that_requires_lighting_compiles_lit_and_fogged_on_both_backends";
    let Some(root) = asset_shader_root() else {
        eprintln!(
            "skipping {test}: no Wallpaper Engine assets/shaders directory. Set \
             WALLPAPER_MACHINE_ASSETS_ROOT to run it."
        );
        return;
    };
    // fur4 is left out: its instanced shells read the dialect's `CASTF` cast
    // macro, which the compiler does not supply, lit or unlit.
    for shader in ["genericimage4", "generic4", "genericparticle", "genericropeparticle",
                   "foliage4", "chroma4"] {
        let (Some(vertex), Some(fragment)) = (
            corpus_source_or_skip(&root.join(format!("{shader}.vert")), test),
            corpus_source_or_skip(&root.join(format!("{shader}.frag")), test),
        ) else {
            continue;
        };
        for target in [ShaderTarget::VulkanSpirv, ShaderTarget::MetalMsl] {
            let mut builder = ShaderProgramRequest::builder(ShaderName::new(shader).unwrap())
                .target(target)
                .stage(ShaderStageSource::new(ShaderStageKind::Vertex, vertex.clone()))
                .stage(ShaderStageSource::new(ShaderStageKind::Fragment, fragment.clone()))
                .texture(ShaderTextureInfo::new(
                    TextureSlot::new(0).expect("valid texture slot"),
                    true,
                    TextureFormatHint::Rgba8,
                ));
            // Lit and fogged at once, as a scene with lights and both fogs
            // compiles them.
            for (name, value) in [
                ("LIGHTING", "1"), ("SCENE_ORTHO", "1"), ("HDR", "0"),
                ("LIGHTS_POINT", "3"), ("LIGHTS_SPOT", "1"), ("LIGHTS_TUBE", "3"),
                ("LIGHTS_DIRECTIONAL", "1"),
                ("FOG_DIST", "1"), ("FOG_HEIGHT", "1"), ("FOG_COMPUTED", "1"),
            ] {
                builder = builder.combo(ShaderComboValue::new(ComboName::new(name).unwrap(), value));
            }
            let request = builder.build().expect("lit request should be valid");
            let program = ShaderPipeline::new(AssetShaderProvider, NagaCompiler)
                .compile(&request)
                .unwrap_or_else(|error| panic!("lit {shader} should compile for {target:?}: {error:?}"));
            let members: Vec<_> = program.reflection().uniform_blocks().iter()
                .flat_map(|block| block.members())
                .map(|member| (member.name().to_owned(), member.array_count()))
                .collect();
            assert!(members.contains(&("g_LTube_OriginB".to_owned(), 3)),
                "{shader} {target:?}: {members:?}");
            assert!(members.contains(&("g_LPoint_Origin".to_owned(), 3)),
                "{shader} {target:?}: {members:?}");
        }
    }
}

#[test]
fn asset_vertex_stages_with_if_hlsl_blocks_compile_on_both_backends() {
    let test = "asset_vertex_stages_with_if_hlsl_blocks_compile_on_both_backends";
    let Some(root) = asset_shader_root() else {
        eprintln!(
            "skipping {test}: no Wallpaper Engine assets/shaders directory. Set \
             WALLPAPER_MACHINE_ASSETS_ROOT to run it."
        );
        return;
    };
    // The cast macros the shipped morph shaders use are part of the dialect's
    // own prelude, which the compiler does not supply (yet); define the ones
    // the vertex stages below read.
    let prelude = "#define CASTU(x) uint(x)\n#define CASTF(x) float(x)\n";
    let fragment = concat!(
        "varying vec2 v_TexCoord;\nuniform sampler2D g_Texture0;\n",
        "void main() { gl_FragColor = texSample2D(g_Texture0, v_TexCoord); }\n",
    );
    // Each pair puts a shipped `#if HLSL` block in the compiled source: the
    // screen coordinate flip of a compositing effect, and the redeclared
    // vertex index of a morph target shader, which the stage reads as `uint`.
    let cases: [(&str, &str, &[(&str, &str)]); 3] = [
        ("effectcomposebackground", "", &[]),
        ("generic4", prelude, &[("MORPHING", "1")]),
        ("generic4", prelude, &[("MORPHING", "1"), ("MORPHING_NORMALS", "1"), ("SKINNING", "1"),
                                ("BONECOUNT", "4"), ("LIGHTING", "1")]),
    ];
    for (shader, prelude, combos) in cases {
        let Some(vertex) = corpus_source_or_skip(&root.join(format!("{shader}.vert")), test) else {
            continue;
        };
        for target in [ShaderTarget::VulkanSpirv, ShaderTarget::MetalMsl] {
            let mut builder = ShaderProgramRequest::builder(ShaderName::new(shader).unwrap())
                .target(target)
                .stage(ShaderStageSource::new(ShaderStageKind::Vertex, format!("{prelude}{vertex}")))
                .stage(ShaderStageSource::new(ShaderStageKind::Fragment, fragment));
            for (name, value) in combos {
                builder = builder.combo(ShaderComboValue::new(ComboName::new(*name).unwrap(), *value));
            }
            let request = builder.build().expect("asset request should be valid");
            let program = ShaderPipeline::new(AssetShaderProvider, NagaCompiler)
                .compile(&request)
                .unwrap_or_else(|error| {
                    panic!("{shader} {combos:?} should compile for {target:?}: {error:?}")
                });
            let vertex_source = legalized_stage(&program, ShaderStageKind::Vertex);
            assert!(!vertex_source.contains("gl_VertexID"), "{shader} {target:?}");
            if shader == "effectcomposebackground" {
                assert!(vertex_source.contains("v_ScreenCoord.y = -v_ScreenCoord.y;"), "{target:?}");
            } else {
                assert!(vertex_source.contains("gl_VertexIndex"), "{shader} {target:?}");
                assert!(
                    !program.reflection().vertex_inputs().iter()
                        .any(|input| input.name().starts_with("gl_")),
                    "{shader} {target:?}: no builtin is a vertex input"
                );
            }
        }
    }
}

#[test]
fn pipeline_compiles_asset_genericimage4_without_widening_rotate_vec2_helper() {
    let test = "pipeline_compiles_asset_genericimage4_without_widening_rotate_vec2_helper";
    let Some(root) = asset_shader_root() else {
        eprintln!(
            "skipping {test}: no Wallpaper Engine assets/shaders directory. Set \
             WALLPAPER_MACHINE_ASSETS_ROOT to run it."
        );
        return;
    };
    let (Some(vertex), Some(fragment)) = (
        corpus_source_or_skip(&root.join("genericimage4.vert"), test),
        corpus_source_or_skip(&root.join("genericimage4.frag"), test),
    ) else {
        return;
    };

    let pipeline =
        ShaderPipeline::with_reflector(AssetShaderProvider, SourceCaptureCompiler, EmptyReflector);
    let request =
        ShaderProgramRequest::builder(ShaderName::new("genericimage4").expect("valid name"))
            .stage(ShaderStageSource::new(ShaderStageKind::Vertex, vertex))
            .stage(ShaderStageSource::new(ShaderStageKind::Fragment, fragment))
            .texture(ShaderTextureInfo::new(
                TextureSlot::new(0).expect("valid texture slot"),
                true,
                TextureFormatHint::Rgba8,
            ))
            .build()
            .expect("genericimage4 request should be valid");

    let program = pipeline
        .compile(&request)
        .expect("asset genericimage4 should compile through shader pipeline");
    let fragment = legalized_stage_source(&program, ShaderStageKind::Fragment);

    assert!(
        fragment.contains("vec2 cs = vec2(cos(r), sin(r));"),
        "{fragment}"
    );
    assert!(!fragment.contains("vec2 cs = vec3(vec2(cos(r), sin(r)), 0.0);"));
}

#[test]
fn pipeline_compiles_3414858021_depthparallax_with_line_continuations() {
    let Some(request) = unpacked_shader_pair_request(
        "workshop/3370055069/effects/depthparallax",
        "3414858021/shaders/workshop/3370055069/effects/depthparallax.vert",
        "3414858021/shaders/workshop/3370055069/effects/depthparallax.frag",
        "pipeline_compiles_3414858021_depthparallax_with_line_continuations",
    ) else {
        return;
    };

    let program = ShaderPipeline::new(AssetShaderProvider, NagaCompiler)
        .compile(&request)
        .expect("depthparallax line continuations should compile through shader pipeline");
    assert!(!program.stages().is_empty());
}

#[test]
fn pipeline_compiles_3414858021_auto_sway_with_unknown_punctuation_tokens() {
    let Some(request) = unpacked_shader_pair_request(
        "workshop/3235948233/effects/auto_sway",
        "3414858021/shaders/workshop/3235948233/effects/auto_sway.vert",
        "3414858021/shaders/workshop/3235948233/effects/auto_sway.frag",
        "pipeline_compiles_3414858021_auto_sway_with_unknown_punctuation_tokens",
    ) else {
        return;
    };

    let program = ShaderPipeline::new(AssetShaderProvider, NagaCompiler)
        .compile(&request)
        .expect("auto_sway unknown punctuation should compile through shader pipeline");
    assert!(!program.stages().is_empty());
}

#[test]
fn pipeline_compiles_semicolon_terminated_audio_sample_conditionals() {
    let request = ShaderProgramRequest::builder(
        ShaderName::new("effects/simple_gradient_audio_bar").expect("valid name"),
    )
    .stage(ShaderStageSource::new(
        ShaderStageKind::Vertex,
        concat!(
            "attribute vec3 a_Position;\n",
            "void main() {\n",
            "  gl_Position = vec4(a_Position, 1.0);\n",
            "}\n",
        ),
    ))
    .stage(ShaderStageSource::new(
        ShaderStageKind::Fragment,
        concat!(
            "#if AUDIOSAMPLES == 16\n",
            "uniform float g_AudioSpectrum16Left[16];\n",
            "#elif AUDIOSAMPLES == 32;\n",
            "uniform float g_AudioSpectrum32Left[32];\n",
            "#elif AUDIOSAMPLES == 64;\n",
            "uniform float g_AudioSpectrum64Left[64];\n",
            "#endif\n",
            "varying vec2 v_TexCoord;\n",
            "void main() {\n",
            "#if AUDIOSAMPLES == 16\n",
            "  float left[AUDIOSAMPLES] = g_AudioSpectrum16Left;\n",
            "#elif AUDIOSAMPLES == 32;\n",
            "  float left[AUDIOSAMPLES] = g_AudioSpectrum32Left;\n",
            "#elif AUDIOSAMPLES == 64;\n",
            "  float left[AUDIOSAMPLES] = g_AudioSpectrum64Left;\n",
            "#endif\n",
            "  float i = floor(v_TexCoord.x * AUDIOSAMPLES);\n",
            "  gl_FragColor = vec4(left[i]);\n",
            "}\n",
        ),
    ))
    .replace_combo(ShaderComboValue::new(
        ComboName::new("AUDIOSAMPLES").expect("valid combo"),
        "32",
    ))
    .build()
    .expect("simple gradient audio bar request should be valid");

    let program = ShaderPipeline::new(AssetShaderProvider, NagaCompiler)
        .compile(&request)
        .expect("semicolon-terminated audio sample conditionals should compile");
    assert!(!program.stages().is_empty());
}

#[test]
fn pipeline_compiles_iris_movement_follow_cursor_vertex_path() {
    let request = interface_request(
        concat!(
            "// [COMBO] {\"material\":\"Follow \
             Cursor\",\"combo\":\"FOLLOWCURSOR\",\"default\":1}\n",
            "// [COMBO] {\"material\":\"Manual \
             Control\",\"combo\":\"MANUALCONTROL\",\"default\":0}\n",
            "uniform mat4 g_ModelViewProjectionMatrix;\n",
            "uniform mat4 g_EffectTextureProjectionMatrixInverse;\n",
            "uniform vec2 g_PointerPosition;\n",
            "uniform vec2 g_CursorScale;\n",
            "uniform vec2 g_CursorScaleMultiplier;\n",
            "uniform vec2 g_CursorScaleLimit;\n",
            "attribute vec3 a_Position;\n",
            "attribute vec2 a_TexCoord;\n",
            "varying vec4 v_TexCoord;\n",
            "varying vec2 v_TexCoordIris;\n",
            "void main() {\n",
            "  gl_Position = g_ModelViewProjectionMatrix * vec4(a_Position, 1.0);\n",
            "  v_TexCoord = a_TexCoord.xyxy;\n",
            "#if FOLLOWCURSOR && !MANUALCONTROL\n",
            "  vec2 cursorPositionAdjusted = g_PointerPosition;\n",
            "  cursorPositionAdjusted.y = 1.0 - cursorPositionAdjusted.y;\n",
            "  cursorPositionAdjusted.x = (cursorPositionAdjusted.x - 0.5) * 2.0;\n",
            "  cursorPositionAdjusted.y = (cursorPositionAdjusted.y - 0.5) * 2.0;\n",
            "  vec4 transformedCursorPosition = g_EffectTextureProjectionMatrixInverse * \
             vec4(cursorPositionAdjusted, 0.0, 1.0);\n",
            "  transformedCursorPosition.xy = clamp(transformedCursorPosition.xy, \
             -g_CursorScaleLimit, g_CursorScaleLimit);\n",
            "  transformedCursorPosition.x *= -1.0;\n",
            "  vec2 da = transformedCursorPosition * g_CursorScale * g_CursorScaleMultiplier * \
             0.001;\n",
            "  v_TexCoordIris = da.xy;\n",
            "#endif\n",
            "}\n",
        ),
        concat!(
            "// [COMBO] {\"material\":\"ui_editor_properties_background\",\"combo\":\"BACKGROUND\",\"default\":0}\n",
            "varying vec4 v_TexCoord;\n",
            "varying vec2 v_TexCoordIris;\n",
            "uniform sampler2D g_Texture0;\n",
            "uniform sampler2D g_Texture1; // {\"combo\":\"MASK\"}\n",
            "void main() {\n",
            "  vec4 albedo = texture(g_Texture0, v_TexCoord.xy);\n",
            "#if MASK\n",
            "  albedo *= texture(g_Texture1, v_TexCoord.zw);\n",
            "#else\n",
            "  vec4 iris = texture(g_Texture0, v_TexCoord.xy + v_TexCoordIris.xy);\n",
            "#endif\n",
            "  gl_FragColor = iris;\n",
            "}\n",
        ),
    );

    let _compiled = pipeline()
        .compile(&request)
        .expect("iris movement follow-cursor vertex path should compile through Naga");
}

#[test]
fn pipeline_rejects_cross_stage_varying_type_mismatch_when_vertex_uses_missing_components() {
    let pipeline = pipeline();
    let request = interface_request(
        concat!(
            "attribute vec2 a_Position;\n",
            "varying vec2 v_Uv;\n",
            "void main() {\n",
            "  v_Uv = a_Position;\n",
            "  gl_Position = vec4(a_Position, 0.0, 1.0);\n",
            "}\n",
        ),
        concat!(
            "varying vec3 v_Uv;\n",
            "void main() {\n",
            "  gl_FragColor = vec4(v_Uv, 1.0);\n",
            "}\n",
        ),
    );

    let err = pipeline
        .compile(&request)
        .expect_err("cross-stage type mismatch should be rejected before compilation");

    assert_cross_stage_error(
        err,
        "cross-stage varying `v_Uv` type mismatch: vertex outputs vec2 but fragment inputs vec3",
    );
}

#[test]
fn pipeline_normalizes_fragment_input_to_vertex_width_when_fragment_reads_subset() {
    let capture_pipeline = source_capture_pipeline();
    let request = interface_request(
        concat!(
            "attribute vec2 a_Position;\n",
            "varying vec2 v_AccumulationRate;\n",
            "void main() {\n",
            "  v_AccumulationRate.x = a_Position.x;\n",
            "  v_AccumulationRate.y = a_Position.y;\n",
            "  gl_Position = vec4(a_Position, 0.0, 1.0);\n",
            "}\n",
        ),
        concat!(
            "varying vec3 v_AccumulationRate;\n",
            "void main() {\n",
            "  gl_FragColor = vec4(v_AccumulationRate.x, v_AccumulationRate.y, 0.0, 1.0);\n",
            "}\n",
        ),
    );

    let program = capture_pipeline
        .compile(&request)
        .expect("fragment vec3 varying should normalize when only xy are read");
    let vertex_source = legalized_stage_source(&program, ShaderStageKind::Vertex);
    let fragment_source = legalized_stage_source(&program, ShaderStageKind::Fragment);

    assert!(vertex_source.contains("layout(location = 0) out vec2 v_AccumulationRate;"));
    assert!(fragment_source.contains("layout(location = 0) in vec2 v_AccumulationRate;"));

    let _compiled = pipeline()
        .compile(&request)
        .expect("normalized fragment input should compile through Naga");
}

#[test]
fn workshop_3471294034_audio_buffer_accumulation_compiles_through_naga() {
    let pipeline = DefaultShaderPipeline::new(
        InMemoryShaderSourceProvider::new().with_source(
            IncludePath::new("common_blending.h").expect("valid include path"),
            "",
        ),
        NagaCompiler,
    );
    let request = ShaderProgramRequest::builder(
        ShaderName::new("workshop/3351849630/effects/audio_buffer_accumulation_accumulation")
            .expect("valid shader name"),
    )
    .stage(ShaderStageSource::new(
        ShaderStageKind::Vertex,
        include_str!(
            "fixtures/3471294034/shaders/workshop/3351849630/effects/\
             audio_buffer_accumulation_accumulation.vert"
        ),
    ))
    .stage(ShaderStageSource::new(
        ShaderStageKind::Fragment,
        include_str!(
            "fixtures/3471294034/shaders/workshop/3351849630/effects/\
             audio_buffer_accumulation_accumulation.frag"
        ),
    ))
    .texture(ShaderTextureInfo::new(
        TextureSlot::new(0).expect("valid texture slot"),
        true,
        TextureFormatHint::Rgba8,
    ))
    .texture(ShaderTextureInfo::new(
        TextureSlot::new(1).expect("valid texture slot"),
        true,
        TextureFormatHint::Rgba8,
    ))
    .build()
    .expect("audio accumulation request should be valid");

    let _program = pipeline
        .compile(&request)
        .expect("audio accumulation shader should compile through Naga");
}

#[test]
fn pipeline_rejects_fragment_wider_varying_when_fragment_reads_missing_component() {
    let pipeline = pipeline();
    let request = interface_request(
        concat!(
            "attribute vec2 a_Position;\n",
            "varying vec2 v_AccumulationRate;\n",
            "void main() {\n",
            "  v_AccumulationRate = a_Position;\n",
            "  gl_Position = vec4(a_Position, 0.0, 1.0);\n",
            "}\n",
        ),
        concat!(
            "varying vec3 v_AccumulationRate;\n",
            "void main() {\n",
            "  gl_FragColor = vec4(v_AccumulationRate.z);\n",
            "}\n",
        ),
    );

    let err = pipeline
        .compile(&request)
        .expect_err("fragment reads outside vertex output width should be rejected");

    assert_cross_stage_error(
        err,
        "cross-stage varying `v_AccumulationRate` type mismatch: vertex outputs vec2 but fragment \
         inputs vec3",
    );
}

#[test]
fn pipeline_rejects_fragment_wider_varying_when_fragment_reads_whole_variable() {
    let pipeline = pipeline();
    let request = interface_request(
        concat!(
            "attribute vec2 a_Position;\n",
            "varying vec2 v_AccumulationRate;\n",
            "void main() {\n",
            "  v_AccumulationRate = a_Position;\n",
            "  gl_Position = vec4(a_Position, 0.0, 1.0);\n",
            "}\n",
        ),
        concat!(
            "varying vec3 v_AccumulationRate;\n",
            "void main() {\n",
            "  gl_FragColor = vec4(v_AccumulationRate, 1.0);\n",
            "}\n",
        ),
    );

    let err = pipeline
        .compile(&request)
        .expect_err("whole-variable fragment read should require the fragment declaration width");

    assert_cross_stage_error(
        err,
        "cross-stage varying `v_AccumulationRate` type mismatch: vertex outputs vec2 but fragment \
         inputs vec3",
    );
}

#[test]
fn pipeline_treats_cross_stage_float1_varying_as_float() {
    let pipeline = pipeline();
    let request = interface_request(
        concat!(
            "attribute vec2 a_Position;\n",
            "varying float1 v_Amount;\n",
            "void main() {\n",
            "  v_Amount = a_Position.x;\n",
            "  gl_Position = vec4(a_Position, 0.0, 1.0);\n",
            "}\n",
        ),
        concat!(
            "varying float v_Amount;\n",
            "void main() {\n",
            "  gl_FragColor = vec4(v_Amount);\n",
            "}\n",
        ),
    );

    let program = pipeline
        .compile(&request)
        .expect("float1 and float cross-stage varying types should normalize");

    assert!(program.stages().iter().any(|stage| {
        stage.kind() == ShaderStageKind::Vertex
            && stage
                .legalized_source()
                .is_some_and(|source| source.contains("layout(location = 0) out float v_Amount;"))
    }));
}

#[test]
fn pipeline_matches_cross_stage_varying_locations_by_name_not_declaration_order() {
    let pipeline = source_capture_pipeline();
    let request = interface_request(
        concat!(
            "attribute vec2 a_Position;\n",
            "varying vec2 v_Uv;\n",
            "varying vec4 v_Color;\n",
            "void main() {\n",
            "  v_Uv = a_Position;\n",
            "  v_Color = vec4(a_Position, 0.0, 1.0);\n",
            "  gl_Position = vec4(a_Position, 0.0, 1.0);\n",
            "}\n",
        ),
        concat!(
            "varying vec4 v_Color;\n",
            "varying vec2 v_Uv;\n",
            "void main() {\n",
            "  gl_FragColor = vec4(v_Uv, 0.0, 1.0) * v_Color;\n",
            "}\n",
        ),
    );

    let program = pipeline
        .compile(&request)
        .expect("same-name varyings should receive matching locations across stages");
    let vertex_source = legalized_stage_source(&program, ShaderStageKind::Vertex);
    let fragment_source = legalized_stage_source(&program, ShaderStageKind::Fragment);

    assert!(vertex_source.contains("layout(location = 0) out vec4 v_Color;"));
    assert!(fragment_source.contains("layout(location = 0) in vec4 v_Color;"));
    assert!(vertex_source.contains("layout(location = 1) out vec2 v_Uv;"));
    assert!(fragment_source.contains("layout(location = 1) in vec2 v_Uv;"));
}

#[test]
fn pipeline_compiles_array_varyings_followed_by_scalar_varyings() {
    let request = interface_request(
        "attribute vec2 a_Position;\nvarying vec2 taps[4];\nvarying vec2 uv;\nvoid main() { for (int i=0;i<4;i++) taps[i]=a_Position; uv=a_Position; gl_Position=vec4(a_Position,0,1); }",
        "varying vec2 taps[4];\nvarying vec2 uv;\nvoid main() { gl_FragColor=vec4(taps[0]+taps[3]+uv,0,1); }");
    let _ = pipeline().compile(&request).expect("array locations must not overlap the next varying");
}

#[test]
fn pipeline_compiles_macro_sized_varyings_without_overlapping_locations() {
    for target in [ShaderTarget::VulkanSpirv, ShaderTarget::MetalMsl] {
        for count in [None, Some(2), Some(4), Some(8)] {
            let mut request = ShaderProgramRequest::builder(
                ShaderName::new("effects/macro_array_interface").unwrap(),
            )
            .target(target)
            .stage(ShaderStageSource::new(
                ShaderStageKind::Vertex,
                concat!(
                    "// [COMBO] {\"combo\":\"COUNT\",\"default\":3}\n",
                    "attribute vec2 a_Position;\n",
                    "varying vec2 taps[COUNT];\nvarying vec2 extra[COUNT];\nvarying vec2 uv;\n",
                    "void main() { for (int i=0;i<COUNT;i++) { taps[i]=a_Position; extra[i]=a_Position*2.0; }\n",
                    "uv=a_Position; gl_Position=vec4(a_Position,0,1); }",
                ),
            ))
            .stage(ShaderStageSource::new(
                ShaderStageKind::Fragment,
                concat!(
                    "varying vec2 taps[COUNT];\nvarying vec2 extra[COUNT];\nvarying vec2 uv;\n",
                    "void main() { gl_FragColor=vec4(taps[0]+taps[COUNT-1]+extra[COUNT-1]+uv,0,1); }",
                ),
            ));
            if let Some(count) = count {
                request = request.combo(ShaderComboValue::new(
                    ComboName::new("COUNT").unwrap(),
                    count.to_string(),
                ));
            }
            let _ = pipeline()
                .compile(&request.build().unwrap())
                .expect("macro arrays must compile on both backends with disjoint locations");
        }
    }
}

#[test]
fn pipeline_resolves_macro_array_bounds_at_each_declaration() {
    for target in [ShaderTarget::VulkanSpirv, ShaderTarget::MetalMsl] {
        for change in [
            "#undef COUNT\n#define COUNT 4\n",
            "float helper() {\n#undef COUNT\n#define COUNT 4\nreturn 0.0;\n}\n",
        ] {
            let interfaces = format!(
                "#define COUNT 2\nvarying vec2 first[COUNT];\n{change}\
                 varying vec2 second[COUNT];\nvarying vec2 uv;\n"
            );
            let request = ShaderProgramRequest::builder(
                ShaderName::new("effects/declaration_scoped_array_bounds").unwrap(),
            )
            .target(target)
            .stage(ShaderStageSource::new(ShaderStageKind::Vertex, format!(
                "{interfaces}attribute vec2 a_Position;\nvoid main() {{\
                 first[0]=a_Position; first[1]=a_Position;\
                 for(int i=0;i<COUNT;i++) second[i]=a_Position;\
                 uv=a_Position; gl_Position=vec4(a_Position,0,1); }}"
            )))
            .stage(ShaderStageSource::new(ShaderStageKind::Fragment, format!(
                "{interfaces}void main() {{ gl_FragColor=vec4(first[1]+second[3]+uv,0,1); }}"
            )))
            .build().unwrap();
            let program = pipeline().compile(&request)
                .expect("each array must use the definition visible at its own declaration");
            for stage in [ShaderStageKind::Vertex, ShaderStageKind::Fragment] {
                let source = legalized_stage_source(&program, stage);
                assert!(source.contains("vec2 first[2];"), "{source}");
                assert!(source.contains("vec2 second[4];"), "{source}");
                assert!(source.contains("layout(location = 6)"), "{source}");
            }
        }
    }
}

#[test]
fn pipeline_rejects_unresolved_interface_array_bounds_before_layout() {
    for target in [ShaderTarget::VulkanSpirv, ShaderTarget::MetalMsl] {
        for (prefix, suffix, late) in [
            ("#define COUNT 4+1\n", "COUNT", ""),
            ("#define COUNT (2+1)\n", "COUNT", ""),
            ("#define COUNT 0\n", "COUNT", ""),
            ("#define COUNT -1\n", "COUNT", ""),
            ("#define COUNT 2\nuniform float preceding;\n#undef COUNT\n", "COUNT", ""),
            ("#define COUNT 2\nuniform float preceding;\n#define COUNT(x) x\n", "COUNT", ""),
            ("", "COUNT", "#define COUNT 3\n"),
            ("", "COUNT", ""),
            ("", "2+1", ""),
        ] {
            let request = ShaderProgramRequest::builder(
                ShaderName::new("effects/unsupported_array_bound").unwrap(),
            )
            .target(target)
            .stage(ShaderStageSource::new(ShaderStageKind::Vertex, format!(
                "{prefix}varying vec2 taps[{suffix}];\n{late}varying vec2 uv;\n\
                 void main() {{ taps[0]=vec2(0); uv=vec2(0); gl_Position=vec4(0); }}"
            )))
            .stage(ShaderStageSource::new(ShaderStageKind::Fragment, format!(
                "{prefix}varying vec2 taps[{suffix}];\n{late}varying vec2 uv;\n\
                 void main() {{ gl_FragColor=vec4(taps[0]+uv,0,1); }}"
            )))
            .build().unwrap();
            let error = pipeline().compile(&request).expect_err("unsupported bounds must not reserve one location");
            assert!(error.to_string().contains("unsupported stage-interface array bound"), "{error}");
        }
    }
}

#[test]
fn pipeline_legalizes_nested_legacy_calls_in_macro_replacements() {
    for target in [ShaderTarget::VulkanSpirv, ShaderTarget::MetalMsl] {
        let request = ShaderProgramRequest::builder(
            ShaderName::new("effects/macro_builtins").unwrap(),
        )
        .target(target)
        .stage(ShaderStageSource::new(
            ShaderStageKind::Vertex,
            "attribute vec2 a_Position;\nvoid main() { gl_Position=vec4(a_Position,0,1); }",
        ))
        .stage(ShaderStageSource::new(
            ShaderStageKind::Fragment,
            concat!(
                "uniform vec3 tint;\n",
                "void main() {\n",
                "#define corrected pow(tint, CAST3(2.0))\n",
                "#define blend(x) lerp(corrected, CAST3(x), saturate(x))\n",
                "gl_FragColor=vec4(blend(0.5),1.0); }",
            ),
        ))
        .build()
        .unwrap();
        let _ = pipeline()
            .compile(&request)
            .expect("nested macro builtins must reach GLSL and MSL");
    }
}

#[test]
fn pipeline_narrows_user_vector_arguments_to_declared_width() {
    let request = interface_request(
        "attribute vec2 a_Position;\nvoid main() { gl_Position=vec4(a_Position,0,1); }",
        "vec2 rotateVec2(vec2 v, float r) { return vec2(v.x*cos(r)-v.y*sin(r),v.x*sin(r)+v.y*cos(r)); }\nvoid main() { gl_FragColor=vec4(rotateVec2(vec4(1,0,0,1),1.0),0,1); }");
    let _ = pipeline().compile(&request).expect("legacy function calls consume the declared vector prefix");
}

#[test]
fn pipeline_shares_vector_uniform_with_scalar_prefix_in_other_stage() {
    let request = interface_request(
        "uniform vec2 u_size;\nattribute vec2 a_Position;\nvoid main() { gl_Position=vec4(a_Position*u_size,0,1); }",
        "uniform float u_size;\nvoid main() { gl_FragColor=vec4(u_size); }");
    let _ = pipeline().compile(&request).expect("stage-local scalar view of a shared vector uniform");
}

/// Compiles one program from vertex and fragment source, for either backend.
fn compile_program(
    name: &str,
    target: ShaderTarget,
    vertex: &str,
    fragment: &str,
) -> shader::CompiledShaderProgram {
    let request = ShaderProgramRequest::builder(ShaderName::new(name).unwrap())
        .target(target)
        .stage(ShaderStageSource::new(ShaderStageKind::Vertex, vertex))
        .stage(ShaderStageSource::new(ShaderStageKind::Fragment, fragment))
        .build()
        .unwrap();
    pipeline()
        .compile(&request)
        .unwrap_or_else(|error| panic!("{name} should compile for {target:?}: {error:?}"))
}

/// Returns one stage's legalized source from a compiled program.
fn legalized_stage(program: &shader::CompiledShaderProgram, kind: ShaderStageKind) -> &str {
    program
        .stages()
        .iter()
        .find(|stage| stage.kind() == kind)
        .and_then(CompiledShaderStage::legalized_source)
        .expect("the stage keeps its legalized source")
}

#[test]
fn a_compositing_effect_turns_the_screen_coordinate_over_under_if_hlsl() {
    // Wallpaper Engine's `effectcomposebackground`, the first pass of every
    // effect that composes a layer over the screen, flips `v_ScreenCoord.y`
    // under `#if HLSL` for the Direct3D convention this renderer shares.
    // While the macro was 0 the block was skipped, and every such effect
    // sampled the screen mirrored vertically.
    let vertex = concat!(
        "uniform mat4 g_ModelViewProjectionMatrix;\n",
        "uniform mat4 g_EffectModelViewProjectionMatrix;\n",
        "attribute vec3 a_Position;\n",
        "attribute vec2 a_TexCoord;\n",
        "varying vec2 v_TexCoord;\n",
        "varying vec3 v_ScreenCoord;\n",
        "void main() {\n",
        "    gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);\n",
        "    v_TexCoord = a_TexCoord;\n",
        "    v_ScreenCoord = mul(vec4((a_Position), 1.0), g_EffectModelViewProjectionMatrix).xyw;\n",
        "#if HLSL\n",
        "    v_ScreenCoord.y = -v_ScreenCoord.y;\n",
        "#endif\n",
        "#if !HLSL\n",
        "    v_ScreenCoord.x = -v_ScreenCoord.x;\n",
        "#endif\n",
        "}\n",
    );
    let fragment = concat!(
        "uniform sampler2D g_Texture0;\n",
        "uniform sampler2D g_Texture1;\n",
        "varying vec2 v_TexCoord;\n",
        "varying vec3 v_ScreenCoord;\n",
        "void main() {\n",
        "    vec2 screen = v_ScreenCoord.xy / v_ScreenCoord.z * 0.5 + 0.5;\n",
        "    gl_FragColor = texSample2D(g_Texture0, v_TexCoord) + texSample2D(g_Texture1, screen);\n",
        "}\n",
    );
    for target in [ShaderTarget::VulkanSpirv, ShaderTarget::MetalMsl] {
        let program = compile_program("compose_background", target, vertex, fragment);
        let source = legalized_stage(&program, ShaderStageKind::Vertex);
        assert!(source.contains("v_ScreenCoord.y = -v_ScreenCoord.y;"), "{target:?}: {source}");
        assert!(!source.contains("v_ScreenCoord.x = -v_ScreenCoord.x;"), "{target:?}: {source}");
    }
}

#[test]
fn a_bokeh_style_kernel_compiles_from_its_if_hlsl_brace_list_on_both_backends() {
    // The kernel is a brace list under `#if HLSL` and an array constructor
    // otherwise, both spelled with the same macro of commas. The first branch
    // is the one compiled now.
    let fragment = concat!(
        "#define KERNEL vec2(0,0),vec2(0.5,0),vec2(-0.5,0.25),vec2(0,-1)\n",
        "#define kernelSampleCount 4\n",
        "#if HLSL\n",
        "const vec2 kernel[kernelSampleCount] = {KERNEL};\n",
        "#else\n",
        "const vec2 kernel[kernelSampleCount] = vec2[kernelSampleCount](KERNEL);\n",
        "#endif\n",
        "varying vec2 v_TexCoord;\n",
        "uniform sampler2D g_Texture0;\n",
        "void main() {\n",
        "    vec4 sum = vec4(0.0);\n",
        "    for (int i = 0; i < kernelSampleCount; i++) {\n",
        "        sum += texSample2D(g_Texture0, v_TexCoord + kernel[i] * 0.01);\n",
        "    }\n",
        "    gl_FragColor = sum / float(kernelSampleCount);\n",
        "}\n",
    );
    let vertex = concat!(
        "attribute vec3 a_Position;\nattribute vec2 a_TexCoord;\nvarying vec2 v_TexCoord;\n",
        "void main() { gl_Position = vec4(a_Position, 1.0); v_TexCoord = a_TexCoord; }\n",
    );
    for target in [ShaderTarget::VulkanSpirv, ShaderTarget::MetalMsl] {
        let program = compile_program("bokeh_kernel", target, vertex, fragment);
        let source = legalized_stage(&program, ShaderStageKind::Fragment);
        assert!(source.contains("= {KERNEL};"), "{target:?}: {source}");
        assert!(!source.contains("vec2[kernelSampleCount](KERNEL)"), "{target:?}: {source}");
    }
}

#[test]
fn the_direct3d_light_falloff_is_defined_for_zero_and_stays_finite_on_both_backends() {
    // `common_pbr_2.h` raises the falloff to the light's exponent as
    // `pow(falloff + FLT_MIN, exponent)` under `#if HLSL`, so the base is
    // positive even beyond the light's radius, where the falloff is exactly 0.
    // The constant is the smallest normal float, the one thing that survives
    // an `f32` round trip through the generated source untouched.
    let vertex = concat!(
        "attribute vec3 a_Position;\nvarying float v_Distance;\n",
        "void main() { v_Distance = a_Position.z; gl_Position = vec4(a_Position, 1.0); }\n",
    );
    let fragment = concat!(
        "uniform vec3 g_LightColor;\n",
        "uniform float g_Radius;\n",
        "uniform float g_Exponent;\n",
        "varying float v_Distance;\n",
        "vec3 Radiance(vec3 lightColor, float distance, float radius, float exponent) {\n",
        "    float falloff = saturate(1.0 - distance / radius);\n",
        "    // Ensure x > 0 && y >= 0 to avoid undefined behavior\n",
        "#if HLSL\n",
        "    vec3 radiance = lightColor * pow(falloff + 1.17549435e-38, exponent);\n",
        "#else\n",
        "    float flt_min = 6.103515625e-5;\n",
        "    vec3 radiance = lightColor * mix(0.0, pow(falloff + flt_min, exponent), step(0.0, falloff - flt_min));\n",
        "#endif\n",
        "    return radiance;\n",
        "}\n",
        "void main() {\n",
        "    gl_FragColor = vec4(Radiance(g_LightColor, v_Distance, g_Radius, g_Exponent), 1.0);\n",
        "}\n",
    );
    for target in [ShaderTarget::VulkanSpirv, ShaderTarget::MetalMsl] {
        let program = compile_program("light_falloff", target, vertex, fragment);
        let source = legalized_stage(&program, ShaderStageKind::Fragment);
        assert!(source.contains("pow(falloff + 1.17549435e-38, exponent)"), "{target:?}: {source}");
        assert!(!source.contains("flt_min"), "{target:?}: {source}");
        if target == ShaderTarget::MetalMsl {
            let msl = program
                .stages()
                .iter()
                .find(|stage| stage.kind() == ShaderStageKind::Fragment)
                .and_then(CompiledShaderStage::metal)
                .expect("Metal stage")
                .source();
            // The MSL writer spells the constant out in decimal; a compiler
            // that rounds correctly reads it back as the smallest normal.
            let spelled = "0.000000000000000000000000000000000000011754944";
            assert_eq!(spelled.parse::<f32>().unwrap().to_bits(), f32::MIN_POSITIVE.to_bits());
            assert!(
                msl.contains(&format!(" + {spelled}, ")),
                "the smallest normal float reaches MSL exactly:\n{msl}"
            );
        }
    }
}

#[test]
fn a_redeclared_vertex_index_is_no_vertex_input_of_the_compiled_program() {
    // Reflection feeds the renderer's vertex layout: a phantom `gl_VertexID`
    // input would ask for an attribute no mesh has.
    let vertex = concat!(
        "attribute vec3 a_Position;\n",
        "#if HLSL\n",
        "in uint gl_VertexID;\n",
        "#endif\n",
        "uniform uint g_MorphOffsets[4];\n",
        "varying float v_Offset;\n",
        "void main() {\n",
        "    v_Offset = float(gl_VertexID + g_MorphOffsets[1u]);\n",
        "    gl_Position = vec4(a_Position, 1.0);\n",
        "}\n",
    );
    let fragment = "varying float v_Offset;\nvoid main() { gl_FragColor = vec4(v_Offset); }\n";
    for target in [ShaderTarget::VulkanSpirv, ShaderTarget::MetalMsl] {
        let program = compile_program("morph_offset", target, vertex, fragment);
        let names: Vec<_> = program
            .reflection()
            .vertex_inputs()
            .iter()
            .map(|input| input.name().to_owned())
            .collect();
        assert_eq!(names, ["a_Position"], "{target:?}");
    }
}

#[test]
fn a_vertex_input_the_shader_writes_keeps_the_attribute_name_the_mesh_provides() {
    // HLSL lets a vertex shader assign to its inputs, so the legalizer reads a
    // written input through a local copy. Reflection feeds the renderer's
    // lookup of the mesh attribute by name: a name carrying the copy's prefix
    // matches no attribute and the renderer would bind the position instead.
    let vertex = concat!(
        "attribute vec3 a_Position;\n",
        "attribute vec2 a_TexCoord;\n",
        "attribute vec4 a_Color;\n",
        "uniform mat4 g_ModelViewProjectionMatrix;\n",
        "uniform float g_Scale;\n",
        "varying vec2 v_TexCoord;\n",
        "varying vec4 v_Color;\n",
        "void main() {\n",
        "    a_Position.xy *= g_Scale;\n",
        "    a_TexCoord *= g_Scale;\n",
        "    gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);\n",
        "    v_TexCoord = a_TexCoord;\n",
        "    v_Color = a_Color;\n",
        "}\n",
    );
    // The fragment stage copies a written varying the same way; it is linked
    // by location, so it still meets the vertex stage's output.
    let fragment = concat!(
        "varying vec2 v_TexCoord;\nvarying vec4 v_Color;\n",
        "void main() {\n",
        "    v_TexCoord.x += 0.0;\n",
        "    gl_FragColor = v_Color * v_TexCoord.x;\n",
        "}\n",
    );
    for target in [ShaderTarget::VulkanSpirv, ShaderTarget::MetalMsl] {
        let program = compile_program("written_inputs", target, vertex, fragment);
        assert!(
            legalized_stage(&program, ShaderStageKind::Fragment)
                .contains("vec2 v_TexCoord = _we_in_v_TexCoord;"),
            "the written varying is read through a local copy for {target:?}"
        );
        assert!(
            legalized_stage(&program, ShaderStageKind::Vertex)
                .contains("vec2 a_TexCoord = _we_in_a_TexCoord;"),
            "the written input is read through a local copy for {target:?}"
        );
        let inputs: Vec<_> = program
            .reflection()
            .vertex_inputs()
            .iter()
            .map(|input| (input.name().to_owned(), input.location().index()))
            .collect();
        assert_eq!(
            inputs,
            [
                ("a_Position".to_owned(), 0),
                ("a_TexCoord".to_owned(), 1),
                ("a_Color".to_owned(), 2),
            ],
            "{target:?}"
        );
    }
}

fn pipeline() -> DefaultShaderPipeline<InMemoryShaderSourceProvider> {
    DefaultShaderPipeline::new(
        InMemoryShaderSourceProvider::new().with_source(
            IncludePath::new("common/shared.glsl").expect("valid include path"),
            "vec2 shared_uv(vec2 uv) { return uv; }\n",
        ),
        NagaCompiler,
    )
}

fn source_capture_pipeline()
-> ShaderPipeline<InMemoryShaderSourceProvider, SourceCaptureCompiler, EmptyReflector> {
    ShaderPipeline::with_reflector(
        InMemoryShaderSourceProvider::new(),
        SourceCaptureCompiler,
        EmptyReflector,
    )
}

#[derive(Clone, Debug)]
struct SourceCaptureCompiler;

impl ShaderCompiler for SourceCaptureCompiler {
    type Module = ();

    fn compile_stage(
        &self,
        _target: ShaderTarget,
        stage: ShaderStageKind,
        source: &CodegenStageSource,
    ) -> ShaderResult<CompiledStageArtifact<Self::Module>> {
        let compiled_stage = CompiledShaderStage::new(
            stage,
            CompiledStageCode::VulkanSpirv(Box::from([SPIRV_MAGIC])),
            Some(source.source().to_owned()),
            Box::from([]),
        );
        Ok(CompiledStageArtifact::new(
            compiled_stage,
            (),
            Box::from([]),
        ))
    }
}

#[derive(Clone, Debug)]
struct EmptyReflector;

impl ShaderReflector<()> for EmptyReflector {
    fn reflect_stage(
        &self,
        _stage: ShaderStageKind,
        _module: &(),
    ) -> ShaderResult<ShaderReflection> {
        Ok(ShaderReflection::empty())
    }
}

#[derive(Clone, Debug)]
struct AssetShaderProvider;

impl shader::ShaderSourceProvider for AssetShaderProvider {
    fn read_to_string(&self, path: &IncludePath) -> ShaderResult<String> {
        let source = asset_shader_root()
            .ok_or_else(|| std::io::Error::other("no Wallpaper Engine assets/shaders directory"))
            .and_then(|root| std::fs::read_to_string(root.join(path.as_str())));
        source.map_err(|error| ShaderError::SourceRead {
            path: path.clone(),
            message: error.to_string(),
        })
    }
}

#[derive(Clone, Debug)]
struct ConflictingUniformBlockReflector;

impl ShaderReflector<()> for ConflictingUniformBlockReflector {
    fn reflect_stage(
        &self,
        stage: ShaderStageKind,
        _module: &(),
    ) -> ShaderResult<ShaderReflection> {
        let byte_size = match stage {
            ShaderStageKind::Vertex => 4,
            ShaderStageKind::Fragment => 8,
        };
        let member = ShaderUniformMember::new("g_Time", 0, byte_size, 1, 0, 0)?;
        let block = ShaderUniformBlock::new(
            "GlobalUniforms",
            BindingSet::new(0)?,
            BindingIndex::new(0)?,
            byte_size,
            Box::from([member]),
        )?;

        Ok(ShaderReflection::new(
            Box::from([]),
            Box::from([block]),
            Box::from([]),
            Box::from([]),
        ))
    }
}

fn legalized_stage_source(program: &shader::CompiledShaderProgram, stage: ShaderStageKind) -> &str {
    program
        .stages()
        .iter()
        .find(|compiled_stage| compiled_stage.kind() == stage)
        .and_then(CompiledShaderStage::legalized_source)
        .expect("stage should include legalized source")
}

fn assert_uniform_block_member_order(source: &str, members: &[&str]) {
    let block_start = source
        .find("uniform GlobalUniforms")
        .expect("source should contain GlobalUniforms");
    let block_end = source[block_start..]
        .find("};")
        .map(|offset| block_start + offset)
        .expect("GlobalUniforms block should close");
    let block = &source[block_start..block_end];
    let mut previous = 0usize;
    for member in members {
        let index = block
            .find(member)
            .unwrap_or_else(|| panic!("GlobalUniforms block missing {member}"));
        assert!(
            index >= previous,
            "GlobalUniforms member {member} was emitted out of order"
        );
        previous = index;
    }
}

fn request(brightness: &str, combo_value: &str) -> ShaderProgramRequest {
    request_with_fragment_call(brightness, "texture2D(g_Texture0, v_Uv)", combo_value)
}

fn request_with_target(
    brightness: &str,
    combo_value: &str,
    target: ShaderTarget,
) -> ShaderProgramRequest {
    let base = request(brightness, combo_value);
    let mut builder = ShaderProgramRequest::builder(base.shader_name().clone())
        .target(target)
        .cache_strategy(base.cache_strategy().clone());

    for stage in base.stages() {
        builder = builder.stage(stage.clone());
    }
    for combo in base.combos() {
        builder = builder.combo(combo.clone());
    }
    for texture in base.textures() {
        builder = builder.texture(texture.clone());
    }
    for property in base.properties() {
        builder = builder.property(property.clone());
    }

    builder.build().expect("request should be valid")
}

fn request_with_fragment_call(
    brightness: &str,
    texture_call: &str,
    combo_value: &str,
) -> ShaderProgramRequest {
    ShaderProgramRequest::builder(ShaderName::new("effects/pipeline").expect("valid name"))
        .stage(ShaderStageSource::new(
            ShaderStageKind::Vertex,
            concat!(
                "#include \"common/shared.glsl\"\n",
                "attribute vec2 a_Position;\n",
                "varying vec2 v_Uv;\n",
                "void main() {\n",
                "    v_Uv = shared_uv(a_Position);\n",
                "    gl_Position = vec4(a_Position, 0.0, 1.0);\n",
                "}\n",
            ),
        ))
        .stage(ShaderStageSource::new(
            ShaderStageKind::Fragment,
            format!(
                concat!(
                    "varying vec2 v_Uv;\n",
                    "uniform sampler2D g_Texture0; // \
                     {{\"combo\":\"HAS_TEXTURE\",\"default\":\"materials/default.png\"}}\n",
                    "uniform float g_Brightness; // \
                     {{\"material\":\"brightness\",\"default\":{brightness}}}\n",
                    "void main() {{\n",
                    "    gl_FragColor = {texture_call} * g_Brightness;\n",
                    "}}\n",
                ),
                brightness = brightness,
                texture_call = texture_call,
            ),
        ))
        .texture(ShaderTextureInfo::new(
            TextureSlot::new(0).expect("valid texture slot"),
            true,
            TextureFormatHint::Rgba8,
        ))
        .property(shader::ProjectPropertyBinding::new(
            PropertyName::new("brightness").expect("valid property"),
            PropertyValue::Number(1.0),
        ))
        .cache_strategy(ShaderCacheStrategy::Enabled {
            scene_id: "pipeline-test".to_owned(),
        })
        .replace_combo(ShaderComboValue::new(
            ComboName::new("HAS_TEXTURE").expect("valid combo"),
            combo_value,
        ))
        .build()
        .expect("request should be valid")
}

fn request_with_property(name: &str, value: PropertyValue) -> ShaderProgramRequest {
    ShaderProgramRequest::builder(ShaderName::new("effects/property-cache").expect("valid name"))
        .stage(ShaderStageSource::new(
            ShaderStageKind::Vertex,
            "void main() { gl_Position = vec4(0.0); }\n",
        ))
        .stage(ShaderStageSource::new(
            ShaderStageKind::Fragment,
            "void main() { gl_FragColor = vec4(1.0); }\n",
        ))
        .property(shader::ProjectPropertyBinding::new(
            PropertyName::new(name).expect("valid property"),
            value,
        ))
        .build()
        .expect("request should be valid")
}

fn program_uniform_layout_request(
    name: &str,
    stages: [(ShaderStageKind, &'static str); 2],
) -> ShaderProgramRequest {
    let mut builder = ShaderProgramRequest::builder(ShaderName::new(name).expect("valid name"));
    for (stage, source) in stages {
        builder = builder.stage(ShaderStageSource::new(stage, source));
    }
    builder
        .texture(ShaderTextureInfo::new(
            TextureSlot::new(0).expect("valid texture slot"),
            true,
            TextureFormatHint::Rgba8,
        ))
        .build()
        .expect("program-uniform-layout request should be valid")
}

fn program_split_texture_request(
    name: &str,
    stages: [(ShaderStageKind, &'static str); 2],
) -> ShaderProgramRequest {
    let mut builder = ShaderProgramRequest::builder(ShaderName::new(name).expect("valid name"));
    for (stage, source) in stages {
        builder = builder.stage(ShaderStageSource::new(stage, source));
    }
    builder
        .build()
        .expect("program split texture request should be valid")
}

fn interface_request(
    vertex: impl Into<String>,
    fragment: impl Into<String>,
) -> ShaderProgramRequest {
    ShaderProgramRequest::builder(ShaderName::new("effects/interface").expect("valid name"))
        .stage(ShaderStageSource::new(ShaderStageKind::Vertex, vertex))
        .stage(ShaderStageSource::new(ShaderStageKind::Fragment, fragment))
        .build()
        .expect("request should be valid")
}

fn unpacked_shader_pair_request(
    name: &str,
    vertex_path: &str,
    fragment_path: &str,
    test: &str,
) -> Option<ShaderProgramRequest> {
    let root = unpack_root();
    let vertex = corpus_source_or_skip(&root.join(vertex_path), test)?;
    let fragment = corpus_source_or_skip(&root.join(fragment_path), test)?;
    Some(
        ShaderProgramRequest::builder(ShaderName::new(name).expect("valid shader name"))
            .stage(ShaderStageSource::new(ShaderStageKind::Vertex, vertex))
            .stage(ShaderStageSource::new(ShaderStageKind::Fragment, fragment))
            .texture(ShaderTextureInfo::new(
                TextureSlot::new(0).expect("valid texture slot"),
                true,
                TextureFormatHint::Rgba8,
            ))
            .build()
            .expect("unpacked shader pair request should be valid"),
    )
}

fn assert_cross_stage_error(err: ShaderError, expected: &str) {
    let ShaderError::Codegen { diagnostics } = err else {
        panic!("expected cross-stage codegen diagnostic");
    };
    let diagnostic = diagnostics
        .first()
        .expect("cross-stage rejection should include diagnostic");

    assert_eq!(diagnostic.pass(), Some("PipelineInterface"));
    assert_eq!(diagnostic.message(), expected);
}
