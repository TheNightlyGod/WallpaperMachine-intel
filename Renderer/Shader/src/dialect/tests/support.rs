// This project's own code, written from the clean-room specification (no upstream code consulted).
#![allow(dead_code)]
//
//! Helpers shared by the dialect tests: converting a stage, compiling the result with naga
//! (GLSL front end, validator, Metal writer) and looking at the module naga builds.

use naga::front::glsl::{Frontend, Options};
use naga::valid::{Capabilities, ValidationFlags, Validator};

use crate::dialect::convert_stage;
use crate::request::StageKind;

pub fn convert(kind: StageKind, src: &str) -> String {
    match convert_stage(kind, src) {
        Ok(c) => c.text,
        Err(diags) => panic!("conversion failed: {:?}\n--- source ---\n{src}", diags.iter().map(|d| d.message.clone()).collect::<Vec<_>>()),
    }
}

pub fn frag(src: &str) -> String {
    convert(StageKind::Fragment, src)
}

pub fn vert(src: &str) -> String {
    convert(StageKind::Vertex, src)
}

pub fn convert_err(kind: StageKind, src: &str) -> Vec<String> {
    match convert_stage(kind, src) {
        Ok(c) => panic!("conversion should have failed, got:\n{}", c.text),
        Err(d) => d.into_iter().map(|d| d.message).collect(),
    }
}

/// What naga made of a converted stage.
pub struct Compiled {
    pub module: naga::Module,
    pub msl: String,
}

fn stage_of(kind: StageKind) -> naga::ShaderStage {
    match kind {
        StageKind::Vertex => naga::ShaderStage::Vertex,
        StageKind::Fragment => naga::ShaderStage::Fragment,
    }
}

/// Parses, validates and writes the GLSL; `Err` carries the first failure's text.
pub fn compile_glsl(kind: StageKind, glsl: &str) -> Result<Compiled, String> {
    let mut front = Frontend::default();
    let module = front
        .parse(&Options::from(stage_of(kind)), glsl)
        .map_err(|e| {
            let at = e
                .errors
                .first()
                .map(|x| {
                    let loc = x.meta.location(glsl);
                    format!(" at line {}: {}", loc.line_number, glsl.lines().nth(loc.line_number as usize - 1).unwrap_or("").trim())
                })
                .unwrap_or_default();
            format!("glsl parse: {}{at}\n{glsl}", e.errors.iter().map(|x| x.to_string()).collect::<Vec<_>>().join("; "))
        })?;
    let mut validator = Validator::new(ValidationFlags::all(), Capabilities::all());
    let info = validator.validate(&module).map_err(|e| {
        let mut chain = e.as_inner().to_string();
        let mut source = std::error::Error::source(e.as_inner());
        while let Some(s) = source {
            chain.push_str(": ");
            chain.push_str(&s.to_string());
            source = s.source();
        }
        format!("validate: {chain}\n{glsl}")
    })?;
    let options = naga::back::msl::Options { lang_version: (2, 0), ..Default::default() };
    let (msl, _) = naga::back::msl::write_string(&module, &info, &options, &naga::back::msl::PipelineOptions::default())
        .map_err(|e| format!("msl: {e}\n{glsl}"))?;
    Ok(Compiled { module, msl })
}

/// Converts a stage and compiles the result; panics with the reason on any failure.
pub fn compile(kind: StageKind, src: &str) -> Compiled {
    let glsl = convert(kind, src);
    match compile_glsl(kind, &glsl) {
        Ok(c) => c,
        Err(e) => panic!("naga rejected the converted stage: {e}\n--- source ---\n{src}"),
    }
}

pub fn compile_frag(src: &str) -> Compiled {
    compile(StageKind::Fragment, src)
}

pub fn compile_vert(src: &str) -> Compiled {
    compile(StageKind::Vertex, src)
}

/// True when naga accepts the converted stage.
pub fn compiles(kind: StageKind, src: &str) -> bool {
    match convert_stage(kind, src) {
        Ok(c) => compile_glsl(kind, &c.text).is_ok(),
        Err(_) => false,
    }
}

impl Compiled {
    fn type_text(&self, ty: naga::Handle<naga::Type>) -> String {
        use naga::{ScalarKind as K, TypeInner as I, VectorSize as V};
        let kind = |k: K, w: u8| match (k, w) {
            (K::Float, 4) => "f32",
            (K::Sint, 4) => "i32",
            (K::Uint, 4) => "u32",
            (K::Bool, _) => "bool",
            _ => "?",
        };
        let size = |s: V| match s {
            V::Bi => 2,
            V::Tri => 3,
            V::Quad => 4,
        };
        match &self.module.types[ty].inner {
            I::Scalar(s) => kind(s.kind, s.width).to_string(),
            I::Vector { size: n, scalar } => format!("vec{}<{}>", size(*n), kind(scalar.kind, scalar.width)),
            I::Matrix { columns, rows, .. } => format!("mat{}x{}", size(*columns), size(*rows)),
            I::Array { base, .. } => format!("array<{}>", self.type_text(*base)),
            I::Struct { .. } => "struct".to_string(),
            other => format!("{other:?}"),
        }
    }

    /// The type naga gave the local variable `name` of the entry point, as text such as
    /// `f32`, `vec3<f32>`, `i32`, `bool`.
    pub fn local_type(&self, name: &str) -> String {
        // The GLSL front end keeps `main` as an ordinary function the entry point calls.
        let mut seen = Vec::new();
        let candidates = self.module.functions.iter().filter(|(_, f)| f.name.as_deref() == Some("main")).map(|(_, f)| f).chain(self.module.entry_points.iter().map(|e| &e.function));
        for f in candidates {
            for (_, v) in f.local_variables.iter() {
                if v.name.as_deref() == Some(name) {
                    return self.type_text(v.ty);
                }
                seen.push(v.name.clone());
            }
        }
        panic!("no local `{name}`; locals: {seen:?}");
    }
}

/// Declarations most tests share, in GLSL 450 form so that a stage compiles as it is.
pub const PRE: &str = "\
layout(std140, set = 0, binding = 0) uniform U {
  vec4 u4; vec3 u3; vec2 u2; float uf; int ui; uint uu; int3 uiv3; uvec4 uuv4; mat4 um4; mat3 um3;
  mat4x3 ub[4]; vec4 ua[4]; float ug;
};
layout(location = 0) in vec4 i4;
layout(location = 1) in vec3 i3;
layout(location = 2) in vec2 i2;
layout(location = 3) in float i1;
layout(location = 0) out vec4 o;
";

/// A fragment stage with the shared declarations, extra declarations and a `main` body.
pub fn stage(decls: &str, body: &str) -> String {
    format!("{PRE}{decls}\nvoid main() {{\n{body}\n}}\n")
}

/// Compiles a fragment stage built with [`stage`].
pub fn ok(decls: &str, body: &str) -> Compiled {
    compile_frag(&stage(decls, body))
}

/// The converted text of a fragment stage built with [`stage`].
pub fn text(decls: &str, body: &str) -> String {
    frag(&stage(decls, body))
}

/// Legalizes a stage written in Wallpaper Engine's legacy form (converted, then given its
/// interface and resource layout by the legalizer) and compiles it.
pub fn legacy(kind: StageKind, src: &str) -> Compiled {
    let glsl = legacy_text(kind, src);
    match compile_glsl(kind, &glsl) {
        Ok(c) => c,
        Err(e) => panic!("naga rejected the legalized stage: {e}\n--- source ---\n{src}"),
    }
}

pub fn legacy_frag(src: &str) -> Compiled {
    legacy(StageKind::Fragment, src)
}

pub fn legacy_vert(src: &str) -> Compiled {
    legacy(StageKind::Vertex, src)
}

/// The legalized text of a legacy stage.
pub fn legacy_text(kind: StageKind, src: &str) -> String {
    match crate::legalize::legalize_stage(kind, src) {
        Ok((stage, _)) => stage.text,
        Err(e) => panic!("legalization failed: {e}\n--- source ---\n{src}"),
    }
}

impl Compiled {
    /// The type of the local `name` in the user function `function`.
    pub fn function_local_type(&self, function: &str, name: &str) -> String {
        for (_, f) in self.module.functions.iter() {
            if f.name.as_deref() == Some(function) {
                for (_, v) in f.local_variables.iter() {
                    if v.name.as_deref() == Some(name) {
                        return self.type_text(v.ty);
                    }
                }
            }
        }
        panic!("no local `{name}` in `{function}`");
    }

    /// True when the module has a user function of that name.
    pub fn has_function(&self, function: &str) -> bool {
        self.module.functions.iter().any(|(_, f)| f.name.as_deref() == Some(function))
    }

    /// How many functions of that name the module has (overloads are separate functions).
    pub fn function_count(&self, function: &str) -> usize {
        self.module.functions.iter().filter(|(_, f)| f.name.as_deref() == Some(function)).count()
    }
}

/// Counts non-overlapping occurrences of `needle` in `hay`.
pub fn count(hay: &str, needle: &str) -> usize {
    hay.matches(needle).count()
}

/// True when two stages compile to the same Metal text: the same program.
pub fn same_msl(a: &str, b: &str) -> bool {
    compile_frag(a).msl == compile_frag(b).msl
}

/// True when `word` occurs in `text` as a whole identifier.
pub fn has_word(text: &str, word: &str) -> bool {
    let is_id = |c: char| c.is_ascii_alphanumeric() || c == '_';
    text.match_indices(word).any(|(i, _)| {
        let before = text[..i].chars().next_back().is_none_or(|c| !is_id(c));
        let after = text[i + word.len()..].chars().next().is_none_or(|c| !is_id(c));
        before && after
    })
}
