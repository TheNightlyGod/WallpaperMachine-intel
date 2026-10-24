// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! The closed list of types a loose uniform may have (R99) and the std140
//! layout of the generated block (R45, R46 widening, R101).
//!
//! This is the part of the block model that needs no compiler: given the
//! members in order, it computes offsets, byte sizes, element counts, array
//! counts and strides exactly as they are reported in the reflection document.

use std::fmt;

use crate::reflection::BlockMember;
use crate::request::StageKind;
use crate::text::{quote, sanitize};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Scalar {
    Bool,
    Int,
    Uint,
    Float,
}

/// A type the generated block can hold.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum UniformType {
    Scalar(Scalar),
    /// Two to four components.
    Vector(Scalar, u8),
    /// GLSL order: `columns` columns of `rows` rows (`mat4x3` is four columns of three rows).
    Matrix { columns: u8, rows: u8 },
}

impl UniformType {
    /// Reads a GLSL or HLSL spelling from the closed list of R99. `None` for
    /// anything else (a structure, an unknown name, a sampler).
    pub fn parse(spelling: &str) -> Option<UniformType> {
        use Scalar::*;
        let scalar = |s| Some(UniformType::Scalar(s));
        let vector = |s, n| Some(UniformType::Vector(s, n));
        match spelling {
            "bool" => return scalar(Bool),
            "int" => return scalar(Int),
            "uint" => return scalar(Uint),
            "float" | "float1" => return scalar(Float),
            "vec2" | "float2" => return vector(Float, 2),
            "vec3" | "float3" => return vector(Float, 3),
            "vec4" | "float4" => return vector(Float, 4),
            "ivec2" => return vector(Int, 2),
            "ivec3" => return vector(Int, 3),
            "ivec4" => return vector(Int, 4),
            "uvec2" => return vector(Uint, 2),
            "uvec3" => return vector(Uint, 3),
            "uvec4" => return vector(Uint, 4),
            "bvec2" => return vector(Bool, 2),
            "bvec3" => return vector(Bool, 3),
            "bvec4" => return vector(Bool, 4),
            "mat2" => return Some(UniformType::Matrix { columns: 2, rows: 2 }),
            "mat3" => return Some(UniformType::Matrix { columns: 3, rows: 3 }),
            "mat4" => return Some(UniformType::Matrix { columns: 4, rows: 4 }),
            _ => {}
        }
        // matCxR with C and R each 2, 3 or 4.
        let dims = spelling.strip_prefix("mat")?.as_bytes();
        let [c @ b'2'..=b'4', b'x', r @ b'2'..=b'4'] = dims else {
            return None;
        };
        Some(UniformType::Matrix { columns: c - b'0', rows: r - b'0' })
    }

    /// The GLSL spelling written into the block (HLSL spellings are rewritten: `float3` is `vec3`).
    pub fn glsl_name(self) -> String {
        match self {
            UniformType::Scalar(Scalar::Bool) => "bool".into(),
            UniformType::Scalar(Scalar::Int) => "int".into(),
            UniformType::Scalar(Scalar::Uint) => "uint".into(),
            UniformType::Scalar(Scalar::Float) => "float".into(),
            UniformType::Vector(s, n) => {
                let prefix = match s {
                    Scalar::Bool => "b",
                    Scalar::Int => "i",
                    Scalar::Uint => "u",
                    Scalar::Float => "",
                };
                format!("{prefix}vec{n}")
            }
            UniformType::Matrix { columns, rows } if columns == rows => format!("mat{columns}"),
            UniformType::Matrix { columns, rows } => format!("mat{columns}x{rows}"),
        }
    }

    /// Scalar components of one element: 1 for a scalar, 2 to 4 for a vector,
    /// columns times rows for a matrix (R101).
    pub fn element_count(self) -> u32 {
        match self {
            UniformType::Scalar(_) => 1,
            UniformType::Vector(_, n) => u32::from(n),
            UniformType::Matrix { columns, rows } => u32::from(columns) * u32::from(rows),
        }
    }

    /// True for `float` and the float vectors: the types the cross-stage
    /// width leniency of R46 applies to.
    pub fn is_float_scalar_or_vector(self) -> bool {
        matches!(self, UniformType::Scalar(Scalar::Float) | UniformType::Vector(Scalar::Float, _))
    }

    /// Components of a float scalar or vector (1 to 4), `None` for other types.
    pub fn float_width(self) -> Option<u8> {
        match self {
            UniformType::Scalar(Scalar::Float) => Some(1),
            UniformType::Vector(Scalar::Float, n) => Some(n),
            _ => None,
        }
    }

    /// The element type of an array of this type as the block stores it: float,
    /// vec2 and vec3 elements are widened to vec4 (R46), others are kept (R101).
    pub fn array_element_type(self) -> UniformType {
        match self.float_width() {
            Some(width) if width < 4 => UniformType::Vector(Scalar::Float, 4),
            _ => self,
        }
    }

    /// std140 base alignment in bytes.
    fn alignment(self) -> u64 {
        match self {
            UniformType::Scalar(_) | UniformType::Vector(_, 1) => 4,
            UniformType::Vector(_, 2) => 8,
            UniformType::Vector(..) | UniformType::Matrix { .. } => 16,
        }
    }

    /// Byte size of one value outside an array. A matrix is an array of
    /// columns whose stride is rounded up to 16, so the true std140 footprint
    /// of `mat2` is 32 and of `mat3` 48 (Q17).
    fn size(self) -> u64 {
        match self {
            UniformType::Scalar(_) => 4,
            UniformType::Vector(_, n) => 4 * u64::from(n),
            UniformType::Matrix { columns, .. } => 16 * u64::from(columns),
        }
    }
}

/// A member as declared, with its array bound already resolved to a number.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MemberDecl {
    pub name: String,
    pub ty: UniformType,
    /// `Some(n)` for an array of `n` elements.
    pub array: Option<u32>,
}

/// The laid-out block: members in declaration order and the std140 span.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct BlockLayout {
    pub members: Vec<BlockMember>,
    /// A multiple of 16, at least the end of the last member.
    pub size: u32,
}

/// Problems with a uniform declaration. Their text is the wording the
/// contract fixes (R46, R99, R100); they carry no prefix so that it starts
/// with it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum UniformError {
    UnsupportedType { ty: String },
    UnresolvedArraySuffix { suffix: String, member: String, stage: StageKind },
    ConflictingDeclarations { name: String, first: String, second: String },
    InvalidArrayCount { name: String, count: u32 },
    BlockTooLarge { name: String },
}

impl fmt::Display for UniformError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let text = match self {
            UniformError::UnsupportedType { ty } => {
                format!("unsupported GlobalUniforms member type {}", quote(ty))
            }
            UniformError::UnresolvedArraySuffix { suffix, member, stage } => format!(
                "unresolved GlobalUniforms member array suffix {} of member {} in the {} stage ({}) (the bound must be a decimal integer, or a macro or combo with a decimal integer value)",
                quote(suffix),
                quote(member),
                stage.name(),
                stage.label()
            ),
            UniformError::ConflictingDeclarations { name, first, second } => format!(
                "conflicting GlobalUniforms member declarations for {}: {} against {}",
                quote(name),
                quote(first),
                quote(second)
            ),
            UniformError::InvalidArrayCount { name, count } => {
                format!("GlobalUniforms member {} has an invalid array count {count}", quote(name))
            }
            UniformError::BlockTooLarge { name } => {
                format!("GlobalUniforms block is too large at member {}", quote(name))
            }
        };
        f.write_str(&sanitize(&text))
    }
}

impl std::error::Error for UniformError {}

fn align_up(value: u64, align: u64) -> u64 {
    value.div_ceil(align) * align
}

/// Lays the members out with std140 rules.
///
/// Reported per member: `offset` (aligned start), `size` (the type's byte size,
/// or stride times count for an array), `element_count` (of one element; of the
/// widened element for float, vec2 and vec3 arrays), `array_count` and
/// `array_stride` (0 when not an array). The block size is the end of the last
/// member rounded up to 16.
pub fn layout_std140(decls: &[MemberDecl]) -> Result<BlockLayout, UniformError> {
    let mut members = Vec::with_capacity(decls.len());
    let mut cursor: u64 = 0;
    for decl in decls {
        let too_large = || UniformError::BlockTooLarge { name: decl.name.clone() };
        let member = match decl.array {
            None => {
                let offset = align_up(cursor, decl.ty.alignment());
                let size = decl.ty.size();
                cursor = offset + size;
                (offset, size, decl.ty.element_count(), 0u32, 0u32)
            }
            Some(0) => return Err(UniformError::InvalidArrayCount { name: decl.name.clone(), count: 0 }),
            Some(count) => {
                let element = decl.ty.array_element_type();
                let stride = align_up(element.size(), 16);
                let offset = align_up(cursor, 16);
                let size = stride * u64::from(count);
                cursor = offset + size;
                (offset, size, element.element_count(), count, stride as u32)
            }
        };
        let (offset, size, element_count, array_count, array_stride) = member;
        if cursor > u64::from(u32::MAX) {
            return Err(too_large());
        }
        members.push(BlockMember {
            name: decl.name.clone(),
            offset: offset as u32,
            size: size as u32,
            element_count,
            array_count,
            array_stride,
        });
    }
    let size = align_up(cursor, 16);
    if size > u64::from(u32::MAX) {
        return Err(UniformError::BlockTooLarge { name: String::new() });
    }
    Ok(BlockLayout { members, size: size as u32 })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn decl(name: &str, ty: &str, array: Option<u32>) -> MemberDecl {
        MemberDecl { name: name.into(), ty: UniformType::parse(ty).unwrap(), array }
    }

    fn member<'a>(layout: &'a BlockLayout, name: &str) -> &'a BlockMember {
        layout.members.iter().find(|m| m.name == name).unwrap()
    }

    #[test]
    fn the_closed_list_parses_and_everything_else_does_not() {
        let accepted = [
            "bool", "int", "uint", "float", "vec2", "vec3", "vec4", "ivec2", "ivec3", "ivec4", "uvec2",
            "uvec3", "uvec4", "bvec2", "bvec3", "bvec4", "mat2", "mat3", "mat4", "mat2x2", "mat2x3",
            "mat2x4", "mat3x2", "mat3x3", "mat3x4", "mat4x2", "mat4x3", "mat4x4", "float1", "float2",
            "float3", "float4",
        ];
        for ty in accepted {
            assert!(UniformType::parse(ty).is_some(), "{ty}");
        }
        for bad in [
            "", "Light", "sampler2D", "samplerCube", "double", "dvec2", "mat5", "mat1x2", "mat2x5", "mat4x",
            "mat", "Vec3", "float5", "half3", "int2", "mat2x2x2", "vec", "bvec5",
        ] {
            assert!(UniformType::parse(bad).is_none(), "{bad}");
        }
    }

    #[test]
    fn hlsl_and_glsl_spellings_are_the_same_type() {
        for (hlsl, glsl) in [("float1", "float"), ("float2", "vec2"), ("float3", "vec3"), ("float4", "vec4")] {
            assert_eq!(UniformType::parse(hlsl), UniformType::parse(glsl));
            assert_eq!(UniformType::parse(hlsl).unwrap().glsl_name(), glsl);
        }
        assert_eq!(UniformType::parse("mat4x4").unwrap().glsl_name(), "mat4");
        assert_eq!(UniformType::parse("mat4x3").unwrap().glsl_name(), "mat4x3");
        assert_eq!(UniformType::parse("bvec3").unwrap().glsl_name(), "bvec3");
        assert_eq!(UniformType::parse("uvec2").unwrap().glsl_name(), "uvec2");
    }

    #[test]
    fn element_counts_follow_r101() {
        let counts = [
            ("float", 1), ("bool", 1), ("vec2", 2), ("ivec3", 3), ("uvec4", 4), ("bvec2", 2), ("mat2", 4),
            ("mat3", 9), ("mat4", 16), ("mat4x3", 12), ("mat3x4", 12), ("mat2x3", 6),
        ];
        for (ty, n) in counts {
            assert_eq!(UniformType::parse(ty).unwrap().element_count(), n, "{ty}");
        }
    }

    #[test]
    fn the_documented_std140_example() {
        // float u_A; vec3 u_B; float u_C; mat4 u_D; vec4 u_E[2];
        let layout = layout_std140(&[
            decl("u_A", "float", None),
            decl("u_B", "vec3", None),
            decl("u_C", "float", None),
            decl("u_D", "mat4", None),
            decl("u_E", "vec4", Some(2)),
        ])
        .unwrap();
        let a = member(&layout, "u_A");
        assert_eq!((a.offset, a.size), (0, 4));
        let b = member(&layout, "u_B");
        assert_eq!((b.offset, b.size), (16, 12));
        let c = member(&layout, "u_C");
        assert_eq!((c.offset, c.size), (28, 4), "fits in the slot the vec3 leaves free");
        let d = member(&layout, "u_D");
        assert_eq!((d.offset, d.size, d.element_count, d.array_count, d.array_stride), (32, 64, 16, 0, 0));
        let e = member(&layout, "u_E");
        assert_eq!((e.offset, e.size, e.element_count, e.array_count, e.array_stride), (96, 32, 4, 2, 16));
        assert_eq!(layout.size, 128);
    }

    #[test]
    fn small_float_arrays_are_widened_to_vec4_elements() {
        for ty in ["float", "vec2", "vec3"] {
            let layout = layout_std140(&[decl("u_Taps", ty, Some(3))]).unwrap();
            let m = member(&layout, "u_Taps");
            assert_eq!((m.element_count, m.array_count, m.array_stride, m.size), (4, 3, 16, 48), "{ty}");
        }
        let layout = layout_std140(&[decl("u_Taps", "vec4", Some(3))]).unwrap();
        assert_eq!(member(&layout, "u_Taps").array_stride, 16);
    }

    #[test]
    fn other_array_element_types_are_not_widened() {
        let layout = layout_std140(&[
            decl("a", "int", Some(2)),
            decl("b", "ivec3", Some(2)),
            decl("c", "mat4", Some(2)),
            decl("d", "mat2", Some(2)),
            decl("e", "mat3", Some(2)),
        ])
        .unwrap();
        let a = member(&layout, "a");
        assert_eq!((a.element_count, a.array_stride, a.offset), (1, 16, 0), "std140 pads int elements to 16");
        let b = member(&layout, "b");
        assert_eq!((b.element_count, b.array_stride, b.offset), (3, 16, 32));
        let c = member(&layout, "c");
        assert_eq!((c.element_count, c.array_stride, c.size, c.offset), (16, 64, 128, 64));
        let d = member(&layout, "d");
        assert_eq!((d.element_count, d.array_stride, d.offset), (4, 32, 192));
        let e = member(&layout, "e");
        assert_eq!((e.element_count, e.array_stride, e.offset), (9, 48, 256));
        assert_eq!(layout.size, 256 + 96);
    }

    #[test]
    fn the_puppet_skeleton_reflects_with_the_documented_shape() {
        // uniform mat4x3 g_Bones[BONECOUNT] with BONECOUNT resolved to 53.
        let layout = layout_std140(&[decl("g_Bones", "mat4x3", Some(53))]).unwrap();
        let m = member(&layout, "g_Bones");
        assert_eq!(m.element_count, 12);
        assert_eq!(m.array_count, 53);
        assert!(m.array_stride >= 64, "the engine writes sixteen floats per bone");
        assert_eq!(m.array_stride, 64);
        assert_eq!(m.size, 64 * 53);
        assert_eq!(layout.size, 64 * 53);
    }

    #[test]
    fn matrices_report_their_true_std140_footprint() {
        // mat2 is two 16-byte columns, mat3 three: following offsets stay consistent.
        let layout = layout_std140(&[
            decl("m2", "mat2", None),
            decl("after2", "float", None),
            decl("m3", "mat3", None),
            decl("after3", "float", None),
            decl("m43", "mat4x3", None),
            decl("m34", "mat3x4", None),
        ])
        .unwrap();
        assert_eq!((member(&layout, "m2").offset, member(&layout, "m2").size), (0, 32));
        assert_eq!(member(&layout, "after2").offset, 32);
        assert_eq!((member(&layout, "m3").offset, member(&layout, "m3").size), (48, 48));
        assert_eq!(member(&layout, "after3").offset, 96);
        assert_eq!((member(&layout, "m43").offset, member(&layout, "m43").size), (112, 64));
        assert_eq!((member(&layout, "m34").offset, member(&layout, "m34").size), (176, 48));
        assert_eq!(layout.size, 224);
    }

    #[test]
    fn vector_alignment_and_packing() {
        let layout = layout_std140(&[
            decl("a", "float", None),
            decl("b", "vec2", None),
            decl("c", "vec2", None),
            decl("d", "vec3", None),
            decl("e", "vec2", None),
            decl("f", "ivec3", None),
            decl("g", "uint", None),
            decl("h", "bvec4", None),
        ])
        .unwrap();
        let offsets: Vec<u32> = layout.members.iter().map(|m| m.offset).collect();
        assert_eq!(offsets, [0, 8, 16, 32, 48, 64, 76, 80]);
        assert_eq!(layout.size, 96);
        assert_eq!(layout.size % 16, 0);
        let sizes: Vec<u32> = layout.members.iter().map(|m| m.size).collect();
        assert_eq!(sizes, [4, 8, 8, 12, 8, 12, 4, 16]);
    }

    #[test]
    fn block_size_is_a_multiple_of_16_and_covers_the_last_member() {
        let layout = layout_std140(&[decl("a", "float", None)]).unwrap();
        assert_eq!(layout.size, 16);
        let layout = layout_std140(&[decl("a", "vec3", None)]).unwrap();
        assert_eq!(layout.size, 16);
        assert_eq!(layout_std140(&[]).unwrap().size, 0);
    }

    #[test]
    fn an_array_starts_on_a_16_byte_boundary() {
        let layout = layout_std140(&[decl("a", "float", None), decl("b", "float", Some(2)), decl("c", "float", None)])
            .unwrap();
        assert_eq!(member(&layout, "b").offset, 16);
        assert_eq!(member(&layout, "c").offset, 48);
    }

    #[test]
    fn degenerate_arrays_and_huge_blocks_are_errors() {
        let e = layout_std140(&[decl("x", "float", Some(0))]).unwrap_err();
        assert!(e.to_string().contains("invalid array count 0"));
        let e = layout_std140(&[decl("big", "mat4", Some(u32::MAX))]).unwrap_err();
        assert!(matches!(e, UniformError::BlockTooLarge { .. }), "{e}");
        assert!(e.to_string().contains("`big`"));
    }

    #[test]
    fn error_text_uses_the_contract_wording() {
        let t = UniformError::UnsupportedType { ty: "Light".into() }.to_string();
        assert_eq!(t, "unsupported GlobalUniforms member type `Light`");
        let t = UniformError::UnresolvedArraySuffix { suffix: "N + 1".into(), member: "u_Arr".into(), stage: StageKind::Fragment }.to_string();
        assert!(t.starts_with("unresolved GlobalUniforms member array suffix `N + 1`") && t.contains("fragment") && t.contains("Fragment") && t.contains("`u_Arr`"), "{t}");
        let t = UniformError::ConflictingDeclarations { name: "u_X".into(), first: "vec2".into(), second: "vec4[2]".into() }
            .to_string();
        assert!(t.starts_with("conflicting GlobalUniforms member declarations"), "{t}");
        assert!(t.contains("`u_X`") && t.contains("`vec2`") && t.contains("`vec4[2]`"));
    }
}
