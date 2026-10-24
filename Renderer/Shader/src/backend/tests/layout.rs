// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! Uniform layout parity (spec D test 24, R51): for every supported member type, alone and in
//! an array, in blocks that mix them, the offsets, strides and total size the reflection
//! reports equal those of the MSL struct, which is checked by parsing the MSL text (padding
//! members included). A difference would be a defect, not a limitation.

use std::collections::HashMap;

use crate::error::ErrorCategory;
use crate::pipeline::tests::support::{PASS_VERTEX, Req, ok};
use crate::reflection::UniformBlock;

/// The struct definitions of an MSL text: name to members `(type, name, array length)`.
type Member = (String, String, Option<u32>);
type Structs = HashMap<String, Vec<Member>>;

fn parse_structs(msl: &str) -> Structs {
    let mut out = Structs::new();
    let mut current: Option<(String, Vec<Member>)> = None;
    for line in msl.lines() {
        let line = line.trim();
        if let Some(name) = line.strip_prefix("struct ").and_then(|r| r.strip_suffix(" {")) {
            current = Some((name.to_string(), Vec::new()));
        } else if line == "};" {
            if let Some((name, members)) = current.take() {
                out.insert(name, members);
            }
        } else if let Some((_, members)) = &mut current
            && let Some(decl) = line.strip_suffix(';')
            && !decl.contains("[[")
        {
            let (decl, array) = match decl.split_once('[') {
                Some((head, tail)) => (head, Some(tail.trim_end_matches(']').parse::<u32>().expect("an array length"))),
                None => (decl, None),
            };
            let (ty, name) = decl.rsplit_once(' ').expect("a type and a name");
            members.push((ty.to_string(), name.to_string(), array));
        }
    }
    out
}

fn round_up(x: u64, to: u64) -> u64 {
    x.div_ceil(to) * to
}

/// Size and alignment of an MSL type of a uniform block.
fn size_align(ty: &str, structs: &Structs) -> (u64, u64) {
    let ty = ty.strip_prefix("metal::").unwrap_or(ty);
    let packed = ty.strip_prefix("packed_");
    let base = packed.unwrap_or(ty);
    let vector = |prefix: &str| -> Option<u64> { base.strip_prefix(prefix).and_then(|n| n.parse().ok()).filter(|n| (2..=4).contains(n)) };
    match ty {
        "float" | "int" | "uint" => return (4, 4),
        "bool" | "char" => return (1, 1),
        _ => {}
    }
    for prefix in ["float", "int", "uint"] {
        if let Some(n) = vector(prefix) {
            return if packed.is_some() { (4 * n, 4) } else if n == 2 { (8, 8) } else { (16, 16) };
        }
        // floatCxR: C columns of R-component vectors.
        if let Some(rest) = ty.strip_prefix(prefix)
            && let Some((c, r)) = rest.split_once('x')
            && let (Ok(c), Ok(r)) = (c.parse::<u64>(), r.parse::<u64>())
        {
            let column = if r == 2 { 8 } else { 16 };
            return (c * column, column);
        }
    }
    let members = structs.get(ty).unwrap_or_else(|| panic!("unknown MSL type {ty}"));
    let (size, align, _) = layout_of(members, structs);
    (size, align)
}

/// Total size, alignment and the offsets of the members of an MSL struct (padding included).
fn layout_of(members: &[Member], structs: &Structs) -> (u64, u64, Vec<u64>) {
    let (mut offset, mut align, mut offsets) = (0u64, 1u64, Vec::new());
    for (ty, _, array) in members {
        let (size, a) = size_align(ty, structs);
        offset = round_up(offset, a);
        offsets.push(offset);
        offset += match array {
            Some(n) => u64::from(*n) * round_up(size, a),
            None => size,
        };
        align = align.max(a);
    }
    (round_up(offset, align), align, offsets)
}

/// Compares the reflected block with the MSL struct `GlobalUniforms` of the fragment stage.
fn assert_parity(label: &str, glsl_members: &str) {
    let fragment = format!("{glsl_members}\nvoid main() {{ gl_FragColor = vec4(pre + post); }}");
    let p = ok(PASS_VERTEX, &fragment);
    let block: &UniformBlock = p.reflection.uniform_blocks.first().unwrap_or_else(|| panic!("{label}: no block reflected"));
    let msl = &p.stage(crate::request::StageKind::Fragment).unwrap().payload.msl_source;
    let structs = parse_structs(msl);
    let members = structs.get("GlobalUniforms").unwrap_or_else(|| panic!("{label}: no GlobalUniforms struct in\n{msl}"));
    let (size, _, offsets) = layout_of(members, &structs);
    let real: Vec<usize> = members.iter().enumerate().filter(|(_, (_, name, _))| !name.starts_with("_pad")).map(|(i, _)| i).collect();
    assert_eq!(real.len(), block.members.len(), "{label}: member count\n{msl}");
    for (i, reflected) in real.iter().zip(&block.members) {
        assert_eq!(offsets[*i], u64::from(reflected.offset), "{label}: offset of {}\n{msl}", reflected.name);
        let (ty, _, array) = &members[*i];
        match array {
            Some(n) => assert_eq!(*n, reflected.array_count, "{label}: array length of {}", reflected.name),
            None => {
                // A wrapper struct `{ T inner[N]; }` is how the writer spells a GLSL array.
                if let Some(inner) = structs.get(ty).filter(|m| m.len() == 1 && m[0].1 == "inner") {
                    let (e_size, e_align) = size_align(&inner[0].0, &structs);
                    let stride = round_up(e_size, e_align);
                    assert_eq!(stride, u64::from(reflected.array_stride), "{label}: stride of {}\n{msl}", reflected.name);
                    assert_eq!(inner[0].2, Some(reflected.array_count), "{label}: length of {}", reflected.name);
                } else {
                    assert_eq!(reflected.array_count, 0, "{label}: {} is not an array in the text", reflected.name);
                }
            }
        }
    }
    assert_eq!(size, u64::from(block.size), "{label}: block size\n{msl}");
}

fn block_of(members: &[(&str, &str)]) -> String {
    let mut text = String::new();
    for (ty, name) in members {
        text.push_str(&format!("uniform {ty} {name};\n"));
    }
    text
}

const SINGLE: [&str; 26] = [
    "bool", "int", "uint", "float", "vec2", "vec3", "vec4", "ivec2", "ivec3", "ivec4", "uvec2", "uvec3", "uvec4", "bvec2", "bvec3",
    "bvec4", "mat3", "mat4", "mat2x3", "mat2x4", "mat3x4", "mat4x3", "mat2", "mat2x2", "mat3x2", "mat4x2",
];

const ARRAYS: [&str; 23] = [
    "int", "uint", "float", "vec2", "vec3", "vec4", "ivec2", "ivec3", "ivec4", "uvec2", "uvec3", "uvec4", "mat3", "mat4", "mat2x3", "mat2x4",
    "mat3x4", "mat4x3", "float", "mat2", "mat2x2", "mat3x2", "mat4x2",
];

#[test]
fn every_member_type_alone_between_floats() {
    for ty in SINGLE {
        assert_parity(ty, &block_of(&[("float", "pre"), (ty, "x"), ("float", "post")]));
        assert_parity(&format!("{ty} first"), &block_of(&[(ty, "x"), ("float", "pre"), ("float", "post")]));
        assert_parity(&format!("{ty} before a vec3"), &block_of(&[("float", "pre"), (ty, "x"), ("vec3", "v"), ("float", "post")]));
    }
}

#[test]
fn every_member_type_as_an_array() {
    for ty in ARRAYS {
        assert_parity(&format!("{ty}[3]"), &block_of(&[("float", "pre"), (ty, "x[3]"), ("float", "post")]));
        assert_parity(&format!("{ty}[1]"), &block_of(&[("float", "pre"), (ty, "x[1]"), ("vec2", "v"), ("float", "post")]));
        assert_parity(&format!("{ty}[5] between vec4"), &block_of(&[("vec4", "a"), ("float", "pre"), (ty, "x[5]"), ("vec4", "b"), ("float", "post")]));
    }
}

#[test]
fn the_cases_the_spec_names() {
    // vec3 followed by float; mat3; float array between vec4 members; uint array; mat4x3 array;
    // int and ivec3 arrays; mat2x3 alone and in arrays.
    assert_parity("vec3 then float", &block_of(&[("float", "pre"), ("vec3", "b"), ("float", "c"), ("float", "post")]));
    assert_parity("mat3", &block_of(&[("float", "pre"), ("mat3", "m"), ("float", "post")]));
    assert_parity(
        "float array between vec4",
        &block_of(&[("float", "pre"), ("vec4", "a"), ("float", "bands[64]"), ("vec4", "b"), ("float", "post")]),
    );
    assert_parity("uint offsets", &block_of(&[("float", "pre"), ("uint", "offsets[16]"), ("vec4", "after"), ("float", "post")]));
    assert_parity("mat4x3 array", &block_of(&[("float", "pre"), ("mat4x3", "bones[4]"), ("float", "post")]));
    assert_parity("int and ivec3 arrays", &block_of(&[("float", "pre"), ("int", "i[7]"), ("ivec3", "v[3]"), ("float", "post")]));
    assert_parity("mat2x3", &block_of(&[("float", "pre"), ("mat2x3", "m"), ("mat2x3", "ms[2]"), ("float", "post")]));
    assert_parity("mat2", &block_of(&[("float", "pre"), ("mat2", "m"), ("mat2", "ms[2]"), ("float", "post")]));
    assert_parity("mat2 then float", &block_of(&[("float", "pre"), ("mat2", "m"), ("float", "post")]));
}

#[test]
fn a_block_that_mixes_everything() {
    assert_parity(
        "mixed",
        &block_of(&[
            ("float", "pre"),
            ("vec3", "a"),
            ("float", "fa[3]"),
            ("vec4", "b[2]"),
            ("mat3", "c"),
            ("uint", "u[3]"),
            ("ivec3", "iv[2]"),
            ("mat4x3", "m[2]"),
            ("bool", "flag"),
            ("bvec3", "bv"),
            ("vec2", "t"),
            ("mat2x3", "n[2]"),
            ("ivec2", "i2"),
            ("uvec3", "u3[2]"),
            ("vec2", "v2a[4]"),
            ("mat3x4", "q"),
            ("bvec2", "b2"),
            ("float", "post"),
        ]),
    );
}

#[test]
fn arrays_of_booleans_are_refused_naming_the_member() {
    // Arrays of booleans have no widened form: they are refused up front (spec C2 R87 allows
    // it, NOTES). Two-row matrices are laid out, see `every_member_type_alone_between_floats`.
    for (ty, name) in [("bool", "flags[4]"), ("bvec2", "flags[2]")] {
        let fragment = format!("uniform {ty} {name};\nvoid main() {{ gl_FragColor = vec4(0.0); }}");
        let e = Req::new(PASS_VERTEX, &fragment).err();
        assert_eq!(e.category(), ErrorCategory::InvalidRequest, "{ty}: {e}");
        let member = name.split('[').next().unwrap();
        assert!(e.to_string().contains(&format!("`{member}`")), "{e}");
    }
}

#[test]
fn the_struct_reader_follows_the_rules_of_msl() {
    let text = "
struct type_4 {
    metal::float4 inner[2];
};
struct type_5 {
    float inner[3];
};
struct Sample {
    float a;
    char _pad1[12];
    metal::packed_float3 b;
    float c;
    metal::float3x3 d;
    type_4 e;
    type_5 f;
    metal::float2 g;
};
";
    let structs = parse_structs(text);
    let (size, align, offsets) = layout_of(&structs["Sample"], &structs);
    assert_eq!(offsets, [0, 4, 16, 28, 32, 80, 112, 128]);
    assert_eq!((size, align), (144, 16));
    // A float array has a natural stride of 4, which is why the block widens it.
    let (e_size, e_align) = size_align("float", &structs);
    assert_eq!(round_up(e_size, e_align), 4);
}
