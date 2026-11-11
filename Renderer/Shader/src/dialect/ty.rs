// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! The type model of the dialect front end (spec 3.4, R24).
//!
//! Types are deliberately coarse: scalars, vectors, float matrices, arrays,
//! structs, samplers, `void` and `Unknown`. `Unknown` is the answer whenever a
//! type cannot be decided; every rule treats it as "leave the construct alone"
//! (P3).

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum Sc {
    Bool,
    Int,
    Uint,
    Float,
}

impl Sc {
    pub fn is_numeric(self) -> bool {
        self != Sc::Bool
    }

    pub fn is_integer(self) -> bool {
        matches!(self, Sc::Int | Sc::Uint)
    }

    /// The constructor name of the scalar type.
    pub fn name(self) -> &'static str {
        match self {
            Sc::Bool => "bool",
            Sc::Int => "int",
            Sc::Uint => "uint",
            Sc::Float => "float",
        }
    }

    /// The literal that is zero in this type.
    pub fn zero(self) -> &'static str {
        match self {
            Sc::Bool => "false",
            Sc::Int => "0",
            Sc::Uint => "0u",
            Sc::Float => "0.0",
        }
    }

    pub fn one(self) -> &'static str {
        match self {
            Sc::Bool => "true",
            Sc::Int => "1",
            Sc::Uint => "1u",
            Sc::Float => "1.0",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum SamplerKind {
    D2,
    D3,
    D2Array,
    Cube,
    /// `sampler2DComparison` (Wallpaper Engine's `Texture2D` + `SamplerComparisonState`) and
    /// `sampler2DShadow`: a depth texture sampled with a comparison.
    Shadow,
    /// `sampler2DMS`: a multisampled texture, read with `texelFetch` (the multisampled
    /// `sampler2DBackBuffer`, E-D8).
    D2Ms,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Ty {
    Void,
    Scalar(Sc),
    /// Component type and width (2 to 4).
    Vec(Sc, u8),
    /// Columns and rows; always float.
    Mat(u8, u8),
    Array(Box<Ty>, Option<u32>),
    /// Index into the converter's struct table.
    Struct(usize),
    Sampler(SamplerKind),
    Unknown,
}

pub const FLOAT: Ty = Ty::Scalar(Sc::Float);
pub const INT: Ty = Ty::Scalar(Sc::Int);
pub const UINT: Ty = Ty::Scalar(Sc::Uint);
pub const BOOL: Ty = Ty::Scalar(Sc::Bool);

impl Ty {
    pub fn vec(width: u8) -> Ty {
        Ty::Vec(Sc::Float, width)
    }

    /// Scalar of kind `k`, or a vector of that kind and width `w` (`w` of 1 is a scalar).
    pub fn of(kind: Sc, width: u8) -> Ty {
        if width <= 1 { Ty::Scalar(kind) } else { Ty::Vec(kind, width) }
    }

    pub fn is_unknown(&self) -> bool {
        matches!(self, Ty::Unknown)
    }

    pub fn is_scalar(&self) -> bool {
        matches!(self, Ty::Scalar(_))
    }

    pub fn is_vector(&self) -> bool {
        matches!(self, Ty::Vec(..))
    }

    pub fn is_matrix(&self) -> bool {
        matches!(self, Ty::Mat(..))
    }

    /// The scalar kind of a scalar or vector.
    pub fn kind(&self) -> Option<Sc> {
        match self {
            Ty::Scalar(k) | Ty::Vec(k, _) => Some(*k),
            _ => None,
        }
    }

    /// Component count of a scalar (1) or vector; `None` for everything else.
    pub fn width(&self) -> Option<u8> {
        match self {
            Ty::Scalar(_) => Some(1),
            Ty::Vec(_, n) => Some(*n),
            _ => None,
        }
    }

    pub fn vec_width(&self) -> Option<u8> {
        match self {
            Ty::Vec(_, n) => Some(*n),
            _ => None,
        }
    }

    pub fn is_float_like(&self) -> bool {
        self.kind() == Some(Sc::Float)
    }

    pub fn is_integer_like(&self) -> bool {
        self.kind().is_some_and(Sc::is_integer)
    }

    pub fn is_bool_scalar(&self) -> bool {
        *self == BOOL
    }

    pub fn is_numeric_scalar(&self) -> bool {
        matches!(self, Ty::Scalar(k) if k.is_numeric())
    }

    /// True when a value of this type can be a scalar or a vector in arithmetic.
    pub fn is_aggregate_blocker(&self) -> bool {
        matches!(self, Ty::Struct(_) | Ty::Array(..) | Ty::Sampler(_))
    }

    pub fn is_sampler(&self) -> bool {
        matches!(self, Ty::Sampler(_))
    }

    /// The type with its scalar kind replaced (matrices and others unchanged).
    pub fn with_kind(&self, kind: Sc) -> Ty {
        match self {
            Ty::Scalar(_) => Ty::Scalar(kind),
            Ty::Vec(_, n) => Ty::Vec(kind, *n),
            other => other.clone(),
        }
    }

    pub fn with_width(&self, width: u8) -> Ty {
        match self.kind() {
            Some(k) => Ty::of(k, width),
            None => self.clone(),
        }
    }

    /// The GLSL spelling for the types that have a plain one.
    pub fn glsl_name(&self) -> Option<String> {
        Some(match self {
            Ty::Void => "void".to_string(),
            Ty::Scalar(k) => k.name().to_string(),
            Ty::Vec(k, n) => {
                let prefix = match k {
                    Sc::Float => "",
                    Sc::Int => "i",
                    Sc::Uint => "u",
                    Sc::Bool => "b",
                };
                format!("{prefix}vec{n}")
            }
            Ty::Mat(c, r) if c == r => format!("mat{c}"),
            Ty::Mat(c, r) => format!("mat{c}x{r}"),
            Ty::Sampler(SamplerKind::D2) => "sampler2D".to_string(),
            Ty::Sampler(SamplerKind::D3) => "sampler3D".to_string(),
            Ty::Sampler(SamplerKind::D2Array) => "sampler2DArray".to_string(),
            Ty::Sampler(SamplerKind::Cube) => "samplerCube".to_string(),
            Ty::Sampler(SamplerKind::Shadow) => "sampler2DShadow".to_string(),
            Ty::Sampler(SamplerKind::D2Ms) => "sampler2DMS".to_string(),
            _ => return None,
        })
    }
}

/// The built-in type a spelling names, with the HLSL aliases `float1` to `float4` folded in
/// (R8). Struct names are not decided here.
pub fn builtin_type(name: &str) -> Option<Ty> {
    let vec_of = |kind: Sc, rest: &str| -> Option<Ty> {
        let n: u8 = rest.parse().ok()?;
        (2..=4).contains(&n).then_some(Ty::Vec(kind, n))
    };
    Some(match name {
        "void" => Ty::Void,
        "bool" => BOOL,
        "int" => INT,
        "uint" => UINT,
        "float" | "float1" => FLOAT,
        "float2" => Ty::vec(2),
        "float3" => Ty::vec(3),
        "float4" => Ty::vec(4),
        "int2" => Ty::Vec(Sc::Int, 2),
        "int3" => Ty::Vec(Sc::Int, 3),
        "int4" => Ty::Vec(Sc::Int, 4),
        "uint2" => Ty::Vec(Sc::Uint, 2),
        "uint3" => Ty::Vec(Sc::Uint, 3),
        "uint4" => Ty::Vec(Sc::Uint, 4),
        "bool2" => Ty::Vec(Sc::Bool, 2),
        "bool3" => Ty::Vec(Sc::Bool, 3),
        "bool4" => Ty::Vec(Sc::Bool, 4),
        "mat2x2" => Ty::Mat(2, 2),
        "mat3x3" => Ty::Mat(3, 3),
        "mat4x4" => Ty::Mat(4, 4),
        "sampler2D" => Ty::Sampler(SamplerKind::D2),
        "sampler3D" => Ty::Sampler(SamplerKind::D3),
        "sampler2DArray" => Ty::Sampler(SamplerKind::D2Array),
        "samplerCube" => Ty::Sampler(SamplerKind::Cube),
        "sampler2DComparison" | "sampler2DShadow" => Ty::Sampler(SamplerKind::Shadow),
        "sampler2DMS" => Ty::Sampler(SamplerKind::D2Ms),
        _ => {
            if let Some(rest) = name.strip_prefix("vec") {
                return vec_of(Sc::Float, rest);
            }
            if let Some(rest) = name.strip_prefix("ivec") {
                return vec_of(Sc::Int, rest);
            }
            if let Some(rest) = name.strip_prefix("uvec") {
                return vec_of(Sc::Uint, rest);
            }
            if let Some(rest) = name.strip_prefix("bvec") {
                return vec_of(Sc::Bool, rest);
            }
            if let Some(rest) = name.strip_prefix("mat") {
                let b = rest.as_bytes();
                return match b {
                    [c @ b'2'..=b'4'] => Some(Ty::Mat(c - b'0', c - b'0')),
                    [c @ b'2'..=b'4', b'x', r @ b'2'..=b'4'] => Some(Ty::Mat(c - b'0', r - b'0')),
                    _ => None,
                };
            }
            return None;
        }
    })
}

/// The canonical spelling of a type word: HLSL aliases and square matrix spellings fold into
/// the short GLSL names. Unknown words come back unchanged.
pub fn canonical_type_name(name: &str) -> String {
    match name {
        "float1" => "float".to_string(),
        "float2" => "vec2".to_string(),
        "float3" => "vec3".to_string(),
        "float4" => "vec4".to_string(),
        "mat2x2" => "mat2".to_string(),
        "mat3x3" => "mat3".to_string(),
        "mat4x4" => "mat4".to_string(),
        other => other.to_string(),
    }
}

/// True for the words that can start a type and are known without declarations.
pub fn is_builtin_type_word(name: &str) -> bool {
    builtin_type(name).is_some()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn spellings_round_trip() {
        for name in [
            "bool", "int", "uint", "float", "vec2", "vec3", "vec4", "ivec2", "ivec3", "uvec4", "bvec2", "mat2", "mat3",
            "mat4", "mat2x3", "mat4x3", "mat3x4", "sampler2D", "sampler3D", "samplerCube",
        ] {
            let ty = builtin_type(name).unwrap();
            assert_eq!(ty.glsl_name().unwrap(), name, "{name}");
        }
        assert_eq!(builtin_type("float3"), Some(Ty::vec(3)));
        assert_eq!(builtin_type("float1"), Some(FLOAT));
        assert_eq!(builtin_type("mat4x4"), Some(Ty::Mat(4, 4)));
        assert_eq!(builtin_type("vec5"), None);
        assert_eq!(builtin_type("half"), None);
        assert_eq!(builtin_type("mat2x5"), None);
        assert_eq!(canonical_type_name("float4"), "vec4");
        assert_eq!(canonical_type_name("Light"), "Light");
    }

    #[test]
    fn shapes() {
        assert_eq!(Ty::of(Sc::Int, 1), INT);
        assert_eq!(Ty::of(Sc::Float, 3), Ty::vec(3));
        assert_eq!(Ty::vec(4).with_width(2), Ty::vec(2));
        assert_eq!(Ty::vec(4).with_kind(Sc::Uint), Ty::Vec(Sc::Uint, 4));
        assert_eq!(Ty::Mat(3, 3).width(), None);
    }
}
