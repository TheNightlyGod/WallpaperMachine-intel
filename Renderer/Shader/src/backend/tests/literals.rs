// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! Float literals in the Metal text (spec D test 25, R52): a 32-bit float written in the GLSL
//! must read back bit for bit from the MSL, including the edges of the type.

use super::support::*;

/// Writes the values four at a time as `c += vec4(...)` and reads the constructor arguments
/// back out of the MSL text, in order.
fn round_trip(values: &[f32]) -> Vec<f32> {
    let mut text = String::from("#version 450\nlayout(location = 0) out vec4 c;\nlayout(location = 0) in vec4 i;\nvoid main() {\n  c = i;\n");
    for chunk in values.chunks(4) {
        let mut parts: Vec<String> = chunk.iter().map(|v| format!("{v:.9e}")).collect();
        // A literal such as `1.5e0` is a float literal in GLSL; negative zero keeps its sign.
        while parts.len() < 4 {
            parts.push("0.0".into());
        }
        text.push_str(&format!("  c += vec4({});\n", parts.join(", ")));
    }
    text.push_str("}\n");
    let f = fragment(&text);
    let mut out = Vec::new();
    for line in msl(&f).lines().filter(|l| l.contains("metal::float4(") && l.contains("_e")) {
        let args = line.split_once("metal::float4(").unwrap().1.trim_end_matches(");");
        for a in args.split(", ") {
            out.push(a.trim_end_matches('f').parse::<f32>().unwrap_or_else(|_| panic!("a float literal: {a} in {line}")));
        }
    }
    out.truncate(values.len().div_ceil(4) * 4);
    out
}

fn assert_bit_identical(values: &[f32]) {
    let back = round_trip(values);
    assert!(back.len() >= values.len(), "{} literals read back for {}", back.len(), values.len());
    for (i, v) in values.iter().enumerate() {
        assert_eq!(back[i].to_bits(), v.to_bits(), "value {i}: wrote {v:e} ({:#010x}), read {:e} ({:#010x})", v.to_bits(), back[i], back[i].to_bits());
    }
}

#[test]
fn the_edges_of_the_type_read_back_bit_identically() {
    assert_bit_identical(&[
        f32::MIN_POSITIVE,          // the smallest normal, 1.17549435e-38
        f32::MAX,                   // the largest finite
        -f32::MAX,
        f32::from_bits(0x3f80_0001), // needs nine significant digits to be told from 1.0
        f32::from_bits(0x3f7f_ffff),
        -0.0,
        0.0,
        0.1,
        1.0 / 3.0,
        16_777_217.0, // 2^24 + 1 does not exist as an f32: it reads back as 2^24
        8_388_609.0,
        std::f32::consts::PI,
    ]);
}

#[test]
fn negative_zero_keeps_its_sign() {
    let back = round_trip(&[-0.0, 0.0]);
    assert_eq!(back[0].to_bits(), (-0.0f32).to_bits());
    assert_eq!(back[1].to_bits(), 0.0f32.to_bits());
}

#[test]
fn the_smallest_normal_is_written_out_in_full() {
    let f = fragment("#version 450\nlayout(location = 0) out vec4 c;\nvoid main() { c = vec4(1.17549435e-38); }\n");
    let text = msl(&f);
    // Not truncated to a handful of digits, and not rounded up to the next float.
    let value: f32 = text
        .lines()
        .find(|l| l.contains("0.0000000000000000000000000000000000000117"))
        .and_then(|l| l.split(|c: char| !(c.is_ascii_digit() || c == '.' || c == 'e' || c == '-')).find(|w| w.starts_with("0.000")))
        .expect("the literal is written out")
        .parse()
        .unwrap();
    assert_eq!(value.to_bits(), f32::MIN_POSITIVE.to_bits());
}

#[test]
fn a_spread_of_values_across_the_exponent_range_reads_back_bit_identically() {
    let mut state: u64 = 0x9e37_79b9_7f4a_7c15;
    let mut next = move || {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        state
    };
    let mut values = Vec::new();
    while values.len() < 600 {
        let v = f32::from_bits((next() >> 32) as u32);
        if v.is_finite() && (v == 0.0 || v.is_normal()) {
            values.push(v);
        }
    }
    assert_bit_identical(&values);
}
