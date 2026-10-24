// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! What the converter knows about calls by name: GLSL built-ins, the HLSL-style
//! vocabulary of the dialect (spec 3.5), the names that are refused (R22), and the
//! reserved words an author's identifier may collide with (R70).

/// How a built-in treats the shapes of its arguments (R28, R29).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Class {
    /// One float argument, result of the same shape: `floor sin sqrt normalize ...`.
    Unary,
    /// Like `Unary`, but integer arguments keep their type: `abs sign`.
    UnaryInt,
    /// Two float arguments of one shape: `pow atan(y, x) reflect`.
    Pair,
    /// `min max`: the second argument may be a scalar; integers allowed.
    MinMax,
    /// `mod`: the second argument may be a scalar.
    Mod,
    /// `step(edge, x)`: the edge may be a scalar.
    Step,
    /// `smoothstep(e0, e1, x)`: both edges scalar or both of the shape.
    Smoothstep,
    /// `clamp(x, lo, hi)`: both bounds scalar or both of the shape; integers allowed.
    Clamp,
    /// `mix(a, b, t)`: the mask may be a scalar.
    Mix,
    /// `dot`, `length`, `distance`: one scalar result, no argument conversion.
    ScalarResult,
    /// `cross`: 3-vector result.
    Cross,
    /// `transpose`, `determinant`, `inverse` and friends on matrices.
    Matrix,
    /// `lessThan` and the other component-wise comparisons: boolean vector result.
    Compare,
    /// `any all`: boolean result.
    Reduce,
    /// `texture`, `textureLod`, ... sampler calls.
    Texture,
    /// A known name with no shape rule here; the result is not typed.
    Other,
}

/// The class of a GLSL built-in by name.
pub fn class_of(name: &str) -> Option<Class> {
    Some(match name {
        "radians" | "degrees" | "sin" | "cos" | "tan" | "asin" | "acos" | "sinh" | "cosh" | "tanh" | "asinh"
        | "acosh" | "atanh" | "exp" | "log" | "exp2" | "log2" | "sqrt" | "inversesqrt" | "floor" | "ceil" | "fract"
        | "trunc" | "round" | "roundEven" | "normalize" | "dFdx" | "dFdy" | "fwidth" | "dFdxFine" | "dFdyFine"
        | "dFdxCoarse" | "dFdyCoarse" | "fwidthFine" | "fwidthCoarse" => Class::Unary,
        "abs" | "sign" => Class::UnaryInt,
        "pow" | "reflect" | "atan" => Class::Pair,
        "min" | "max" => Class::MinMax,
        "mod" => Class::Mod,
        "step" => Class::Step,
        "smoothstep" => Class::Smoothstep,
        "clamp" => Class::Clamp,
        "mix" => Class::Mix,
        "dot" | "length" | "distance" => Class::ScalarResult,
        "cross" => Class::Cross,
        "transpose" | "determinant" | "inverse" | "outerProduct" | "matrixCompMult" => Class::Matrix,
        "lessThan" | "lessThanEqual" | "greaterThan" | "greaterThanEqual" | "equal" | "notEqual" => Class::Compare,
        "any" | "all" | "isnan" | "isinf" => Class::Reduce,
        "texture" | "textureLod" | "textureSize" | "textureQueryLod" | "textureQueryLevels" | "texelFetch"
        | "textureGrad" | "textureOffset" | "textureProj" | "textureGather" | "textureLodOffset" | "textureProjLod" => {
            Class::Texture
        }
        "refract" | "faceforward" | "fma" | "frexp" | "ldexp" | "modf" | "floatBitsToInt" | "floatBitsToUint"
        | "intBitsToFloat" | "uintBitsToFloat" | "packHalf2x16" | "unpackHalf2x16" | "bitCount" | "findLSB"
        | "findMSB" | "not" | "interpolateAtCentroid" => Class::Other,
        _ => return None,
    })
}

/// True for the spellings of the dialect vocabulary that are calls (spec 3.5), whether or not
/// a built-in of the same name exists.
pub fn is_dialect_call(name: &str) -> bool {
    matches!(
        name,
        "mul"
            | "saturate"
            | "frac"
            | "lerp"
            | "atan2"
            | "ddx"
            | "ddy"
            | "fmod"
            | "log10"
            | "clip"
            | "CAST2"
            | "CAST3"
            | "CAST4"
            | "CAST3X3"
            | "CASTU"
            | "CASTF"
            | "CASTI"
            | "CAST4U"
            | "texSample2D"
            | "tex2D"
            | "texture2D"
            | "texSample2DLod"
            | "texture2DLod"
            | "tex2DLod"
            | "texSample3D"
            | "MAKE_SAMPLER2D_ARGUMENT"
    )
}

/// Names that are outside this compiler's scope, with the reason (R22).
pub fn unsupported_reason(name: &str) -> Option<&'static str> {
    Some(match name {
        "texSample2DCompare" | "sampler2DComparison" | "sampler2DShadow" | "textureCompare" => {
            "shadow-map comparison sampling is not supported"
        }
        "texLoad2D" => "texel fetch of the volumetric shader is not supported",
        "texSample2DBackBuffer" => "back-buffer sampling of the volumetric shader is not supported",
        _ => return None,
    })
}

/// GLSL 4.50 keywords and reserved words an author may use as an identifier in Wallpaper
/// Engine's dialect, plus the operator words C++-flavoured backends reserve (R70). The words
/// the parser itself treats as syntax (`in`, `out`, `const`, `uniform`, ...) cannot reach
/// identifier position and are not listed.
pub const RESERVED_IDENTIFIERS: &[&str] = &[
    "sample",
    "and",
    "or",
    "xor",
    "not",
    "input",
    "output",
    "filter",
    "common",
    "partition",
    "active",
    "resource",
    "patch",
    "half",
    "fixed",
    "buffer",
    "shared",
    "row_major",
    "asm",
    "class",
    "union",
    "enum",
    "typedef",
    "template",
    "this",
    "goto",
    "inline",
    "noinline",
    "public",
    "static",
    "extern",
    "external",
    "interface",
    "long",
    "short",
    "unsigned",
    "superp",
    "hvec2",
    "hvec3",
    "hvec4",
    "fvec2",
    "fvec3",
    "fvec4",
    "sizeof",
    "cast",
    "namespace",
    "using",
    "coherent",
    "volatile",
    "restrict",
    "readonly",
    "writeonly",
    "subroutine",
    "precise",
    "image2D",
    "dvec2",
    "dvec3",
    "dvec4",
    "atomic_uint",
];

pub fn is_reserved_identifier(name: &str) -> bool {
    RESERVED_IDENTIFIERS.contains(&name)
}

/// The names a stage may restate with a stage qualifier although the backend provides them,
/// whatever type they are written with (interface part R11). `gl_VertexID` and `gl_InstanceID`
/// are restatements only with the type `uint`; the converter handles them by that rule.
pub const RESTATED_BUILTINS: [&str; 11] = [
    "gl_Position",
    "gl_PointSize",
    "gl_VertexIndex",
    "gl_InstanceIndex",
    "gl_BaseVertex",
    "gl_BaseInstance",
    "gl_FragCoord",
    "gl_FrontFacing",
    "gl_PointCoord",
    "gl_FragDepth",
    "gl_SampleID",
];

/// The type of a GLSL built-in variable by name, for the variables a stage may read or write.
pub fn builtin_variable(name: &str) -> Option<super::ty::Ty> {
    use super::ty::{BOOL, FLOAT, Sc, Ty};
    Some(match name {
        "gl_FragCoord" | "gl_FragColor" | "gl_Position" => Ty::vec(4),
        "gl_PointCoord" => Ty::vec(2),
        "gl_PointSize" | "gl_FragDepth" => FLOAT,
        "gl_FrontFacing" => BOOL,
        "gl_VertexID" | "gl_InstanceID" | "gl_VertexIndex" | "gl_InstanceIndex" => Ty::Scalar(Sc::Uint),
        _ => return None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn classes_cover_the_shape_rules_of_r28() {
        assert_eq!(class_of("mix"), Some(Class::Mix));
        assert_eq!(class_of("pow"), Some(Class::Pair));
        assert_eq!(class_of("floor"), Some(Class::Unary));
        assert_eq!(class_of("dot"), Some(Class::ScalarResult));
        assert_eq!(class_of("mul"), None);
        assert!(is_dialect_call("mul") && !is_dialect_call("mix"));
    }

    #[test]
    fn reserved_words_are_recognised() {
        assert!(is_reserved_identifier("sample"));
        assert!(is_reserved_identifier("input"));
        assert!(!is_reserved_identifier("gain"));
        assert!(unsupported_reason("texLoad2D").is_some());
        assert!(unsupported_reason("texture").is_none());
    }
}
