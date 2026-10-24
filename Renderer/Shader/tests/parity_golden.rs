// This project's own code, written from the clean-room specification (no upstream code consulted).
//
// Amendment a-contract R112, the committed part of the parity corpus: the metadata and reflection
// documents of a few fresh programs are recorded in tests/golden/parity/ and compared byte for byte
// (the per-stage `slot` numbers are not part of them: they are the listed exception of D5). The files
// are recorded from THIS library, because the retired library's documents are not available to the
// implementers; they pin the binding numbers, array order, block member offsets, vertex input
// locations and metadata fields so that a later change shows up as a diff. Bless a deliberate change
// with WM_SHADER_BLESS=1. The shipped-tree half of the corpus is the sweeps of the crate's own tests,
// which print their skip reason when the tree is absent.

use std::path::PathBuf;

use wm_shader::pipeline::compile;
use wm_shader::source::NoIncludes;
use wm_shader::{Combo, ShaderRequest, Stage, StageKind, TextureRecord};

fn texture(slot: u8) -> TextureRecord {
    let mut t = TextureRecord::new(slot);
    t.enabled = true;
    t.components.compo1 = true;
    t.components.compo2 = true;
    t.components.compo3 = true;
    t.components.compo4 = true;
    t
}

struct Case {
    name: &'static str,
    vertex: &'static str,
    fragment: &'static str,
    combos: &'static [(&'static str, &'static str)],
    textures: Vec<TextureRecord>,
}

fn cases() -> Vec<Case> {
    vec![
        Case {
            name: "textured_quad",
            vertex: "attribute vec3 a_Position;\nattribute vec2 a_TexCoord;\nvarying vec2 v_TexCoord;\nuniform mat4 g_ModelViewProjectionMatrix;\nvoid main() { gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix); v_TexCoord = a_TexCoord; }\n",
            fragment: "varying vec2 v_TexCoord;\nuniform sampler2D g_Texture0;\nuniform float g_Alpha;\nvoid main() { gl_FragColor = texSample2D(g_Texture0, v_TexCoord) * g_Alpha; }\n",
            combos: &[],
            textures: vec![texture(0)],
        },
        Case {
            name: "annotated_effect",
            vertex: "attribute vec3 a_Position;\nattribute vec2 a_TexCoord;\nvarying vec4 v_TexCoord;\nuniform mat4 g_ModelViewProjectionMatrix;\nuniform vec4 g_Texture0Resolution;\nvoid main() { gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix); v_TexCoord = vec4(a_TexCoord, a_TexCoord * g_Texture0Resolution.zw); }\n",
            fragment: "// [COMBO] {\"material\":\"Mode\",\"combo\":\"MODE\",\"type\":\"options\",\"default\":1,\"options\":{\"plain\":0,\"masked\":1}}\nvarying vec4 v_TexCoord;\nuniform sampler2D g_Texture0;\nuniform sampler2D g_Texture1; // {\"material\":\"mask\",\"default\":\"util/white\"}\nuniform float g_Strength; // {\"material\":\"strength\",\"default\":0.5,\"range\":[0,1]}\nuniform vec3 g_Tint; // {\"material\":\"tint\",\"default\":\"1 0.5 0.25\",\"type\":\"color\"}\nuniform vec4 g_Rings[3];\nvoid main() {\n  vec4 c = texSample2D(g_Texture0, v_TexCoord.xy);\n#if MODE\n  c *= texSample2D(g_Texture1, v_TexCoord.zw).r;\n#endif\n  gl_FragColor = vec4(c.rgb * g_Tint * g_Strength + g_Rings[1].xyz, c.a);\n}\n",
            combos: &[],
            textures: vec![texture(0), texture(1)],
        },
        Case {
            name: "wide_interface",
            vertex: "attribute vec3 a_Position;\nattribute vec4 a_Color;\nattribute vec2 a_TexCoord;\nvarying vec4 v_Color;\nvarying vec2 v_Taps[3];\nvarying vec3 v_Unused;\nvoid main() { gl_Position = vec4(a_Position, 1.0); v_Color = a_Color; v_Taps[0] = a_TexCoord; v_Taps[1] = a_TexCoord * 2.0; v_Taps[2] = a_TexCoord * 3.0; v_Unused = a_Position; }\n",
            fragment: "varying vec4 v_Color;\nvarying vec2 v_Taps[3];\nvoid main() { gl_FragColor = v_Color + vec4(v_Taps[0] + v_Taps[2], 0.0, 0.0); }\n",
            combos: &[("TAPS", "3")],
            textures: vec![],
        },
    ]
}

/// The metadata and reflection documents of a case, one JSON object.
fn documents(case: &Case) -> String {
    let request = ShaderRequest {
        shader_name: format!("parity/{}", case.name),
        stages: vec![
            Stage { kind: StageKind::Vertex, source: case.vertex.into() },
            Stage { kind: StageKind::Fragment, source: case.fragment.into() },
        ],
        combos: case.combos.iter().map(|(n, v)| Combo { name: (*n).into(), value: (*v).into() }).collect(),
        textures: case.textures.clone(),
        ..ShaderRequest::default()
    }
    .validate()
    .unwrap();
    let program = compile(&request, &NoIncludes).unwrap_or_else(|e| panic!("{}: {e}", case.name));
    format!("{{\"metadata\":{},\"reflection\":{}}}\n", program.metadata.to_json().unwrap(), program.reflection.to_json())
}

fn golden_path(name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/golden/parity").join(format!("{name}.json"))
}

#[test]
fn metadata_and_reflection_of_fresh_programs_equal_their_golden_files() {
    for case in cases() {
        let got = documents(&case);
        let path = golden_path(case.name);
        if std::env::var_os("WM_SHADER_BLESS").is_some() {
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::write(&path, &got).unwrap();
        }
        let want = std::fs::read_to_string(&path).unwrap_or_else(|_| panic!("no golden file {}: run once with WM_SHADER_BLESS=1", path.display()));
        assert_eq!(got, want, "{}: the documents changed; if that is deliberate, rerun with WM_SHADER_BLESS=1", case.name);
    }
}
