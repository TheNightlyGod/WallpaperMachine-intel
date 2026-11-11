use wm_shader::{parse_request, pipeline::compile, source::NoIncludes};

const VS: &str = "attribute vec4 position; void main() { gl_Position = position; }";
const FS: &str = "void main() { gl_FragColor = vec4(1.0, 1.0, 1.0, 1.0); }";
const GS: &str = "uniform vec3 geometryShift;
in vec4 gl_Position;
out vec4 gl_Position;
[maxvertexcount(2)]
void main() {
    PS_INPUT vertex;
    vertex.gl_Position = IN[0].gl_Position + vec4(geometryShift, 0.0);
    OUT.Append(vertex);
    vertex.gl_Position.x += 1.0;
    OUT.Append(vertex);
}";

fn request(geometry: &str, maximum: u32) -> String {
    format!(r#"{{"shader_name":"geometry-contract","stages":[{{"kind":"vertex","source":{VS:?}}},{{"kind":"fragment","source":{FS:?}}}],"point_geometry":{{"source":{geometry:?},"max_vertices":{maximum},"output_index_attribute":"a_GeometryVertex"}}}}"#)
}

#[test]
fn geometry_resources_and_output_selector_are_part_of_the_compiled_vertex_stage() {
    let program = compile(&parse_request(&request(GS, 2)).unwrap(), &NoIncludes).unwrap();
    assert!(program.reflection.uniform_blocks.iter().any(|block|
        block.members.iter().any(|member| member.name == "geometryShift")),
        "a uniform consumed only by the authored geometry stage must be bound");
    assert!(program.reflection.vertex_inputs.iter().any(|input| input.name == "a_GeometryVertex"),
        "the caller supplies a distinct emitted-vertex ordinal for each expanded vertex");
}

#[test]
fn geometry_source_and_dispatch_bounds_change_program_identity() {
    let compile_key = |source: &str| compile(&parse_request(&request(source, 2)).unwrap(), &NoIncludes).unwrap().cache_key;
    assert_ne!(compile_key(GS), compile_key(&GS.replace("+= 1.0", "+= 2.0")));
}

#[test]
fn geometry_author_code_keeps_scalar_swizzle_rejections() {
    let source = GS.replace("vertex.gl_Position.x += 1.0;", "float size = 1.0; vertex.gl_Position.x += size.w;");
    assert!(compile(&parse_request(&request(&source, 2)).unwrap(), &NoIncludes).is_err());
}

#[test]
fn declared_geometry_bound_must_match_the_dispatch_contract() {
    assert!(compile(&parse_request(&request(GS, 3)).unwrap(), &NoIncludes).is_err());
}
