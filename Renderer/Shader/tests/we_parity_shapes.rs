// Author-shader shape boundaries observed in Wallpaper Engine 2.8.0.42.
mod support;

use support::*;
use wm_shader::dialect::{ConvertOptions, convert_stage_with};
use wm_shader::pipeline::compile;
use wm_shader::source::NoIncludes;
use wm_shader::{ShaderRequest, Stage, StageKind};

fn vertex_program(vertex: &str) -> Result<wm_shader::pipeline::CompiledProgram, wm_shader::ShaderError> {
    let request = ShaderRequest {
        shader_name: "author-shape-probe".into(),
        stages: vec![
            Stage { kind: StageKind::Vertex, source: vertex.into() },
            Stage { kind: StageKind::Fragment, source: "void main() { gl_FragColor = vec4(1.0, 1.0, 1.0, 1.0); }".into() },
        ],
        ..ShaderRequest::default()
    }.validate().unwrap();
    compile(&request, &NoIncludes)
}

#[test]
fn author_shape_matrix_vector_assignment_matches_the_we_rejection() {
    // WE reports X3020 before assignment conversion; bare products also fail below.
    let source = "uniform mat4 g_ModelViewProjectionMatrix;\nattribute vec3 a_Position;
        void main() { gl_Position = g_ModelViewProjectionMatrix * vec4(a_Position, 1.0); }";
    assert!(vertex_program(source).is_err(), "WE rejects the authored matrix/vector assignment");
}

#[test]
fn author_shape_scalar_vec3_constructor_matches_the_we_rejection() {
    let source = "uniform float gray;\nvoid main() { vec3 color = vec3(gray); gl_FragColor = vec4(color, 1.0); }";
    assert!(program(source).is_err(), "WE rejects the scalar vec3 constructor with X3014");
}

#[test]
fn author_shape_validated_mul_and_explicit_components_remain_accepted() {
    vertex_program("uniform mat4 g_ModelViewProjectionMatrix; attribute vec3 a_Position;
        void main() { gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix); }").unwrap();
    program_ok("uniform float gray; void main() { vec3 color = vec3(gray, gray, gray); gl_FragColor = vec4(color, 1.0); }");
}

#[test]
fn author_shape_generated_glsl_keeps_matrix_products_and_scalar_splats() {
    let source = "layout(location = 0) in vec4 position;
        layout(std140, set = 0, binding = 0) uniform U { mat4 matrix; float gray; };
        void main() { gl_Position = matrix * position + vec4(gray); }";
    let generated = convert_stage_with(StageKind::Vertex, source,
        ConvertOptions { glsl_builtins: true, ..Default::default() }).unwrap();
    Ir::read(&generated.text, naga::ShaderStage::Vertex);
}

#[test]
fn author_shape_float_vector_constructors_require_their_component_count() {
    for constructor in ["vec2(gray)", "vec3(gray)", "vec4(gray)", "vec3(0.25)",
        "vec3(vec4(gray, gray, gray, 1.0))"] {
        let source = format!("uniform float gray;\nvoid main() {{ float q = ({constructor}).x; gl_FragColor = vec4(q, q, q, 1.0); }}");
        assert!(program(&source).is_err(), "WE rejects {constructor} with X3014");
    }
    for constructor in ["vec3(vec3(gray, gray, gray))", "vec3(vec2(gray, gray), gray)"] {
        program_ok(&format!("uniform float gray;\nvoid main() {{ vec3 q = {constructor}; gl_FragColor = vec4(q, 1.0); }}"));
    }
}

#[test]
fn author_shape_casts_keep_scalar_broadcast_separate_from_constructors() {
    for cast in ["CAST3(gray)", "(vec3)gray", "(float3)gray"] {
        program_ok(&format!("uniform float gray;\nvoid main() {{ vec3 q = {cast}; gl_FragColor = vec4(q, 1.0); }}"));
    }
    program_ok("vec3 own_color(float x) { return vec3(x, x, x); }\nvoid main() { gl_FragColor = vec4(own_color(0.25), 1.0); }");
}

#[test]
fn author_shape_matrix_vector_products_fail_before_their_result_is_used() {
    for body in [
        "vec4 q = m * p;",
        "mat4 q = m * p;",
        "vec4 q = p * m;",
        "mat4 q = p * m;",
        "m * p;",
        "float q = (m * p)[0][0];",
        "vec3 q = n * p.xyz;",
        "mat3 q = n * p.xyz;",
    ] {
        let source = format!("uniform mat4 m; uniform mat3 n; attribute vec4 p;\nvoid main() {{ {body} gl_Position = p; }}");
        let error = vertex_program(&source).expect_err(body);
        assert!(error.to_string().contains("requires `mul`"), "{body}: {error}");
    }
    for expression in ["m * m", "m * 2.0", "2.0 * m"] {
        vertex_program(&format!("uniform mat4 m; attribute vec4 p;\nvoid main() {{ mat4 q = {expression}; gl_Position = mul(p, q); }}")).unwrap();
    }
}

#[test]
fn author_shape_c_casts_preserve_unary_precedence_and_constant_initializers() {
    program_ok("uniform float gray; const vec3 bias = (vec3)0.25;\nvoid main() { vec3 q = (float3)-gray + bias; gl_FragColor = vec4(q, 1.0); }");
    program_ok("uniform vec4 color;\nvoid main() { vec3 q = (vec3)color; gl_FragColor = vec4(q, 1.0); }");
}
