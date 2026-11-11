// Wallpaper Engine 2.8.0.42 T13: authored HLSL vocabulary and modf's output argument.
mod support;
use support::*;
use wm_shader::dialect::{ConvertOptions, convert_stage_with};
use wm_shader::StageKind;

#[test]
fn t13_glsl_sampling_names_fail_in_authored_stages() {
    for call in [
        "texture(g_Texture0, v_TexCoord)",
        "texture2D(g_Texture0, v_TexCoord)",
        "tex2D(g_Texture0, v_TexCoord)",
        "texture2DLod(g_Texture0, v_TexCoord, 0.0)",
    ] {
        let source = format!("uniform sampler2D g_Texture0; varying vec2 v_TexCoord; void main() {{ gl_FragColor = {call}; }}");
        assert!(program(&source).is_err(), "WE refuses {call}");
    }
}

#[test]
fn t13_ivec2_is_not_an_authored_type_even_without_a_live_use() {
    for source in [
        "void unused() { ivec2 p; } void main() { gl_FragColor = CAST4(1.0); }",
        "uniform ivec2 g_P; void main() { gl_FragColor = vec4(float(g_P.x)); }",
        "void main() { gl_FragColor = vec4(ivec2(2,3),0,1); }",
    ] {
        assert!(program(source).is_err(), "WE refuses ivec2: {source}");
    }
}

#[test]
fn t13_modf_returns_fraction_and_writes_the_integral_part() {
    program_ok("varying vec2 v_TexCoord; void main() { float whole; float part = modf(1.25 + v_TexCoord.x * 0.0, whole); gl_FragColor = vec4(part,whole,0.0,1.0); }");
}

#[test]
fn generated_glsl_sampling_and_index_types_still_reconvert() {
    let source = "uniform sampler2D g_Texture0; varying vec2 v_TexCoord; void main() { ivec2 p = ivec2(1,2); gl_FragColor = texture(g_Texture0,v_TexCoord) + vec4(float(p.x)); }";
    convert_stage_with(StageKind::Fragment, source, ConvertOptions { glsl_builtins: true, ..ConvertOptions::default() }).unwrap();
}

#[test]
fn an_authors_texture_function_keeps_its_own_signature() {
    program_ok("vec4 texture(float x) { return vec4(x,x,x,1.0); } void main() { gl_FragColor = texture(0.25); }");
}

#[test]
fn measured_type_positions_keep_uniform_ivec4_and_hlsl_vector_aliases() {
    program_ok("uniform ivec4 g_P; void main() { gl_FragColor = vec4(float(g_P.x),0.0,0.0,1.0); }");
    for ty in ["int2", "int3", "int4", "uint2", "uint3", "uint4", "bool2", "bool3", "bool4", "uvec4"] {
        let width = ty.chars().last().unwrap().to_digit(10).unwrap();
        let args = vec![if ty.starts_with("bool") { "true" } else { "1" }; width as usize].join(",");
        program_ok(&format!("{ty} keep({ty} x) {{ return x; }} void main() {{ {ty} p={ty}({args}); p=keep(p); gl_FragColor=vec4(float(p.x),0.0,0.0,1.0); }}"));
    }
    for ty in ["ivec2", "ivec3", "uvec2", "uvec3", "bvec2", "bvec3", "bvec4"] {
        assert!(program(&format!("uniform {ty} g_P; void main() {{ gl_FragColor=vec4(float(g_P.x)); }}")).is_err(), "{ty} uniform");
    }
    assert!(program("void main() { ivec4 p; gl_FragColor=CAST4(1.0); }").is_err());
}

#[test]
fn measured_modf_output_kinds_shapes_and_authored_overload_compile() {
    for body in [
        "float i; float f=modf(3,i); gl_FragColor=vec4(f,i,0.0,1.0);",
        "int i; float f=modf(-2.75,i); gl_FragColor=vec4(f,float(i),0.0,1.0);",
        "uint i; float f=modf(2.75,i); gl_FragColor=vec4(f,float(i),0.0,1.0);",
        "bool i; float f=modf(2.75,i); gl_FragColor=vec4(f,float(i),0.0,1.0);",
        "vec2 i; vec2 f=modf(1.25,i); gl_FragColor=vec4(f,i);",
        "vec2 i; vec2 f=modf(vec2(1.25,-2.75),i.yx); gl_FragColor=vec4(f,i);",
        "int2 i; vec2 f=modf(vec2(1.25,-2.75),i.yx); gl_FragColor=vec4(f,vec2(i));",
        "bool2 i; vec2 f=modf(vec2(0.25,-2.75),i); gl_FragColor=vec4(f,vec2(i));",
        "mat2 i; mat2 f=modf(mat2(1.25,-2.75,3.5,-4.5),i); gl_FragColor=vec4(f[0],i[1]);",
    ] {
        program_ok(&format!("void main() {{ {body} }}"));
    }
    program_ok("float modf(float x,out float i) { i=42.0; return 0.5; } void main() { float i; float f=modf(1.25,i); gl_FragColor=vec4(f,i,0.0,1.0); }");
}

#[test]
fn measured_wrong_modf_outputs_and_sampling_arities_fail() {
    for body in [
        "float i; vec2 f=modf(vec2(1.25,2.75),i);",
        "vec2 i; vec2 f=modf(vec2(1.25,2.75),i.xx);",
        "float f=modf(1.25,1.0);",
        "float f=modf(1.25);",
    ] {
        assert!(program(&format!("void main() {{ {body} gl_FragColor=CAST4(1.0); }}")).is_err(), "{body}");
    }
    for call in ["texSample2D(g_Texture0,v_TexCoord,0.0)", "texSample2DLod(g_Texture0,v_TexCoord)"] {
        assert!(program(&format!("uniform sampler2D g_Texture0; varying vec2 v_TexCoord; void main() {{ gl_FragColor={call}; }}")).is_err(), "{call}");
    }
}

#[test]
fn modf_keeps_runtime_sign_out_conversions_and_evaluates_lvalues_once_on_gpu() {
    let source = format!("{KERNEL_HEAD}void main() {{
        float whole; float fraction=modf(data[0],whole); data[8]=fraction; data[9]=whole;
        int iw; data[10]=modf(data[0],iw); data[11]=iw;
        bool bw; data[12]=modf(data[0],bw); data[13]=bw;
        vec2 vw; vec2 vf=modf(data[1],vw); data[14]=vf.x; data[15]=vf.y; data[16]=vw.x; data[17]=vw.y;
        float once=data[1]; float parts[2]; int at=0;
        data[18]=modf(once++,parts[at++]); data[19]=once; data[20]=parts[0]; data[21]=at;
        float zw; float zf=modf(data[2],zw); data[22]=asuint(zf)==0u; data[23]=asuint(zw)==2147483648u;
        float infw; float inff=modf(data[3],infw); data[24]=isnan(inff); data[25]=isinf(infw);
        float nanw; float nanf=modf(data[4],nanw); data[26]=isnan(nanf); data[27]=isnan(nanw);
        mat2 mw; mat2 mf=modf(mat2(data[0],data[1],3.5,-4.5),mw); data[28]=mf[1][1]; data[29]=mw[1][1];
    }}");
    let code = kernel(&source);
    let Some(out) = gpu_run(&code, &[-2.75, 1.25, -0.0, f32::INFINITY, f32::NAN]) else { return };
    for (index, expected) in [(8,-0.75),(9,-2.0),(10,-0.75),(11,-2.0),(12,-0.75),(13,1.0),(14,0.25),(15,0.25),(16,1.0),(17,1.0),(18,0.25),(19,2.25),(20,1.0),(21,1.0),(28,-0.5),(29,-4.0)] {
        assert_eq!(out[index], expected, "slot {index}, values {:?}\n{}", &out[8..30], code.msl);
    }
    for index in 22..=27 { assert_eq!(out[index], 1.0, "runtime float class at {index}"); }
}

#[test]
fn authored_modf_overload_is_used_on_gpu() {
    let source = format!("{KERNEL_HEAD}float modf(float x,out float whole) {{ whole=42.0; return 0.5; }} void main() {{ float whole; data[8]=modf(data[0],whole); data[9]=whole; }}");
    let code = kernel(&source);
    let Some(out) = gpu_run(&code, &[1.25]) else { return };
    assert_eq!(out[8], 0.5);
    assert_eq!(out[9], 42.0);
}

#[test]
fn generated_modf_helpers_and_captured_indices_reconvert_unchanged() {
    let source = "void main() { float parts[2]; int i=0; int2 whole; vec2 f=modf(vec2(1.25,-2.75),whole); float p=modf(1.25,parts[i++]); gl_FragColor=vec4(f,p,float(whole.x)); }";
    let first = wm_shader::dialect::convert_stage(StageKind::Fragment, source).unwrap();
    let second = convert_stage_with(StageKind::Fragment, &first.text, ConvertOptions { glsl_builtins: true, ..ConvertOptions::default() }).unwrap();
    assert_eq!(first.text, second.text);
}
