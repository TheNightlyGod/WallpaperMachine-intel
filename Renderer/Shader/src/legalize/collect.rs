// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! Declaration planning (spec C2, 4.3): which top-level declarations of a stage are
//! re-emitted (split textures, uniform block members, stage inputs and outputs), which are
//! dropped (re-declared builtins) and which stay where they are.

use std::collections::HashSet;
use std::ops::Range;

use crate::dialect::ast::*;
use crate::dialect::builtins::RESTATED_BUILTINS;
use crate::dialect::print::expr_to_string;
use crate::dialect::ty::canonical_type_name;
use crate::names::{SlotName, TEXTURE_PREFIX, classify_slot_name};
use crate::request::StageKind;

use super::error::LegalizeError;

/// The prefix the converter gives a stage input the shader writes to (R77).
pub(crate) const WRITTEN_INPUT_PREFIX: &str = "_we_in_";

/// What a split texture is: its object type, the sampler type beside it and the combined type
/// a call joins them into.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TexKind {
    D2,
    D3,
    /// A depth texture sampled with a comparison (`sampler2DComparison`, E-D8).
    Shadow,
    /// A multisampled texture (`sampler2DBackBuffer` under `BACKBUFFER_MS`, E-D8).
    D2Ms,
}

impl TexKind {
    /// The GLSL type of the texture object.
    pub fn object_type(self) -> &'static str {
        match self {
            TexKind::D2 | TexKind::Shadow => "texture2D",
            TexKind::D3 => "texture3D",
            TexKind::D2Ms => "texture2DMS",
        }
    }

    /// The combined sampler type the object and its sampler are joined into at a call.
    pub fn combined_type(self) -> &'static str {
        match self {
            TexKind::D2 => "sampler2D",
            TexKind::D3 => "sampler3D",
            TexKind::Shadow => "sampler2DShadow",
            TexKind::D2Ms => "sampler2DMS",
        }
    }

    /// The GLSL type of the sampler declared beside the object.
    pub fn sampler_type(self) -> &'static str {
        match self {
            TexKind::Shadow => "samplerShadow",
            _ => "sampler",
        }
    }
}

#[derive(Clone, Debug)]
pub(crate) struct TextureDecl {
    pub name: String,
    pub kind: TexKind,
    pub span: Range<usize>,
}

impl TextureDecl {
    /// The binding the name encodes, if it is `g_Texture<N>` with a number that fits (R24).
    pub fn encoded(&self) -> Option<u32> {
        encoded_binding(&self.name)
    }
}

/// `g_Texture<N>` with canonical digits and a number below 2^32 (R24); other names encode nothing.
pub(crate) fn encoded_binding(name: &str) -> Option<u32> {
    let digits = name.strip_prefix(TEXTURE_PREFIX)?;
    if digits.is_empty() || !digits.bytes().all(|b| b.is_ascii_digit()) || digits.len() > 10 {
        return None;
    }
    if digits.len() > 1 && digits.starts_with('0') {
        return None;
    }
    digits.parse::<u32>().ok()
}

#[derive(Clone, Debug)]
pub(crate) struct KeptDecl {
    pub name: String,
    pub set: u32,
    pub binding: Option<u32>,
}

/// An array bound as the declaration spells it, once macros are expanded.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum Bound {
    /// Not an array.
    None,
    Count(u32),
    /// Not a positive decimal integer literal; the text of what was written.
    Bad(String),
}

impl Bound {
    pub fn count(&self) -> Option<u32> {
        match self {
            Bound::Count(n) => Some(*n),
            _ => None,
        }
    }
}

#[derive(Clone, Debug)]
pub(crate) struct UniformDecl {
    pub name: String,
    pub ty: String,
    pub bound: Bound,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Dir {
    In,
    Out,
}

#[derive(Clone, Debug)]
pub(crate) struct IfaceDecl {
    /// The name the declaration carries (`_we_in_` plus the author's name for a written input).
    pub name: String,
    /// The author's name: what reflection and the other stage know the variable by.
    pub author: String,
    pub ty: String,
    pub bound: Bound,
    /// `flat`, `smooth`, `noperspective`: carried over; everything else is dropped (R10).
    pub interp: Vec<String>,
    pub dir: Dir,
    pub span: Range<usize>,
    /// Index of the declaring item in the module.
    pub item: usize,
}

impl IfaceDecl {
    /// Locations the variable occupies: one per element, and one per column of a matrix (R34).
    pub fn location_count(&self) -> u32 {
        location_count(&self.ty, self.bound.count())
    }
}

pub(crate) fn location_count(ty: &str, array: Option<u32>) -> u32 {
    let columns = match crate::dialect::ty::builtin_type(ty) {
        Some(crate::dialect::ty::Ty::Mat(c, _)) => u32::from(c),
        _ => 1,
    };
    columns.saturating_mul(array.unwrap_or(1))
}

/// What a stage declares at top level, classified.
#[derive(Clone, Debug)]
pub(crate) struct StageDecls {
    pub kind: StageKind,
    pub textures: Vec<TextureDecl>,
    pub kept: Vec<KeptDecl>,
    pub uniforms: Vec<UniformDecl>,
    pub inputs: Vec<IfaceDecl>,
    pub outputs: Vec<IfaceDecl>,
    /// Explicit `layout(binding = B)` values found on uniform declarations, with the name.
    pub explicit_block: Vec<(u32, String)>,
    /// Every top-level declaration name (R35).
    pub top_names: HashSet<String>,
    /// Items that are re-emitted or dropped, by index.
    pub removed: HashSet<usize>,
}

fn is_qualified(d: &VarDecl) -> bool {
    d.quals.iter().any(|q| matches!(q, Qualifier::Word(w) if matches!(w.as_str(), "uniform" | "attribute" | "varying" | "in" | "out")))
}

/// Splits every qualified declaration with several declarators into one declaration each, so
/// that every later step sees one variable per item (a conforming implementation handles every
/// declarator, section 5).
pub(crate) fn normalize(module: &mut Module) {
    let items = std::mem::take(&mut module.items);
    let mut out = Vec::with_capacity(items.len());
    for item in items {
        match item {
            Item::Var(d) if d.declarators.len() > 1 && is_qualified(&d) => {
                for decl in d.declarators {
                    out.push(Item::Var(VarDecl { quals: d.quals.clone(), ty: d.ty.clone(), declarators: vec![decl], span: d.span.clone() }));
                }
            }
            other => out.push(other),
        }
    }
    module.items = out;
}

/// `sampler`, `sampler2D`, `samplerCube`, `isampler2D`, `usampler2D`: the type name starts with
/// `sampler`, `isampler` or `usampler` and what follows is empty, a digit or an upper-case letter.
pub(crate) fn is_sampler_like(ty: &str) -> bool {
    for prefix in ["sampler", "isampler", "usampler"] {
        if let Some(rest) = ty.strip_prefix(prefix) {
            return rest.chars().next().is_none_or(|c| c.is_ascii_digit() || c.is_ascii_uppercase());
        }
    }
    false
}

fn literal_count(e: &Expr) -> Option<u32> {
    let ExprKind::Number(t) = &e.peel().kind else { return None };
    // A decimal integer literal: a suffix (`3u`), a prefix (`0x4`) or a fraction (`2.0`) is not one.
    if t.is_empty() || !t.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    let n: u64 = t.parse().ok()?;
    (n > 0).then(|| u32::try_from(n).ok()).flatten()
}

fn bound_of(dims: &[Option<Expr>]) -> Bound {
    match dims {
        [] => Bound::None,
        [Some(e)] => literal_count(e).map_or_else(|| Bound::Bad(expr_to_string(e)), Bound::Count),
        [None] => Bound::Bad(String::new()),
        many => Bound::Bad(
            many.iter().map(|d| format!("[{}]", d.as_ref().map(expr_to_string).unwrap_or_default())).collect::<String>(),
        ),
    }
}

fn all_dims(d: &VarDecl, x: &Declarator) -> Vec<Option<Expr>> {
    d.ty.dims.iter().chain(x.dims.iter()).cloned().collect()
}

fn layout_number(text: &str, key: &str) -> Option<u32> {
    for part in text.split(',') {
        let mut it = part.splitn(2, '=');
        let (Some(k), Some(v)) = (it.next(), it.next()) else { continue };
        if k.trim() == key {
            return v.trim().parse().ok();
        }
    }
    None
}

/// The `(set, binding)` a declaration's `layout` qualifiers give: the first qualifier that
/// declares a binding wins, even with other qualifiers in between (R26).
pub(crate) fn explicit_binding(quals: &[Qualifier]) -> (Option<u32>, Option<u32>) {
    let mut set = None;
    let mut binding = None;
    for q in quals {
        if let Qualifier::Layout(text) = q {
            if binding.is_none() {
                binding = layout_number(text, "binding");
            }
            if set.is_none() {
                set = layout_number(text, "set");
            }
        }
    }
    (set, binding)
}

fn interpolation(d: &VarDecl) -> Vec<String> {
    d.quals
        .iter()
        .filter_map(|q| match q {
            Qualifier::Word(w) if matches!(w.as_str(), "flat" | "smooth" | "noperspective") => Some(w.clone()),
            _ => None,
        })
        .collect()
}

/// Classifies the top-level declarations of one stage.
pub(crate) fn collect(module: &Module, kind: StageKind) -> Result<StageDecls, LegalizeError> {
    let mut out = StageDecls {
        kind,
        textures: Vec::new(),
        kept: Vec::new(),
        uniforms: Vec::new(),
        inputs: Vec::new(),
        outputs: Vec::new(),
        explicit_block: Vec::new(),
        top_names: HashSet::new(),
        removed: HashSet::new(),
    };
    for (index, item) in module.items.iter().enumerate() {
        match item {
            Item::Function(f) => {
                out.top_names.insert(f.name.clone());
            }
            Item::Struct(s) => {
                out.top_names.extend(s.name.iter().cloned());
                out.top_names.extend(s.declarators.iter().map(|x| x.name.clone()));
            }
            Item::Block(b) => {
                out.top_names.insert(b.name.clone());
                out.top_names.extend(b.instance.iter().map(|x| x.name.clone()));
            }
            Item::Var(d) => {
                out.top_names.extend(d.declarators.iter().map(|x| x.name.clone()));
                if d.declarators.len() != 1 || !is_qualified(d) {
                    continue;
                }
                classify(&mut out, index, d)?;
            }
            _ => {}
        }
    }
    Ok(out)
}

fn classify(out: &mut StageDecls, index: usize, d: &VarDecl) -> Result<(), LegalizeError> {
    let x = &d.declarators[0];
    let ty = canonical_type_name(&d.ty.name);
    let kind = out.kind;
    if d.has_word("uniform") {
        if is_sampler_like(&ty) {
            let tex = match ty.as_str() {
                "sampler2D" => Some(TexKind::D2),
                // naga reads no combined sampler of any kind; the 3D texture is split like the
                // 2D one so that the colour-correction pass can be translated (C1 R105d).
                "sampler3D" => Some(TexKind::D3),
                // The dialect's `sampler2DComparison` and the multisampled back buffer (E-D8).
                "sampler2DShadow" => Some(TexKind::Shadow),
                "sampler2DMS" => Some(TexKind::D2Ms),
                _ => None,
            };
            match tex {
                Some(tk) => {
                    if classify_slot_name(&x.name) == SlotName::NonCanonical {
                        return Err(LegalizeError::stage_local(
                            kind,
                            Some(d.span.clone()),
                            format!("texture `{}` has a non-canonical slot suffix: write `g_TextureN` with N in plain decimal digits, without leading zeros", x.name),
                        ));
                    }
                    out.textures.push(TextureDecl { name: x.name.clone(), kind: tk, span: d.span.clone() });
                    out.removed.insert(index);
                }
                None => {
                    let (set, binding) = explicit_binding(&d.quals);
                    out.kept.push(KeptDecl { name: x.name.clone(), set: set.unwrap_or(0), binding });
                }
            }
            return Ok(());
        }
        let (_, binding) = explicit_binding(&d.quals);
        if let Some(b) = binding {
            out.explicit_block.push((b, x.name.clone()));
        }
        out.uniforms.push(UniformDecl {
            name: x.name.clone(),
            ty,
            bound: bound_of(&all_dims(d, x)),
        });
        out.removed.insert(index);
        return Ok(());
    }
    let attribute = d.has_word("attribute");
    let varying = d.has_word("varying");
    let is_in = d.has_word("in");
    let is_out = d.has_word("out");
    if !(attribute || varying || is_in || is_out) {
        return Ok(());
    }
    if RESTATED_BUILTINS.contains(&x.name.as_str()) {
        out.removed.insert(index);
        return Ok(());
    }
    let dir = match kind {
        StageKind::Vertex => {
            if attribute || is_in {
                Dir::In
            } else {
                Dir::Out
            }
        }
        StageKind::Fragment => {
            if is_out {
                Dir::Out
            } else {
                Dir::In
            }
        }
    };
    let author = x.name.strip_prefix(WRITTEN_INPUT_PREFIX).filter(|_| dir == Dir::In).unwrap_or(&x.name).to_string();
    let decl = IfaceDecl {
        name: x.name.clone(),
        author,
        ty,
        bound: bound_of(&all_dims(d, x)),
        interp: interpolation(d),
        dir,
        span: d.span.clone(),
        item: index,
    };
    match dir {
        Dir::In => out.inputs.push(decl),
        Dir::Out => out.outputs.push(decl),
    }
    out.removed.insert(index);
    Ok(())
}

impl StageDecls {
    /// The interface array bounds that are not resolved to a positive literal (R39). `source` is
    /// the text of the stage the declarations were read from: the message quotes the bound as it
    /// is written there.
    pub fn check_interface_bounds(&self, source: &str) -> Result<(), LegalizeError> {
        for d in self.inputs.iter().chain(&self.outputs) {
            if let Bound::Bad(text) = &d.bound {
                let written = written_bound(source, d);
                let shown = match &written {
                    Some(w) if w.split_whitespace().collect::<String>() != text.split_whitespace().collect::<String>() => {
                        format!("`[{w}]` (read as `[{text}]`)")
                    }
                    Some(w) => format!("`[{w}]`"),
                    None => format!("`[{text}]`"),
                };
                return Err(LegalizeError::request(format!(
                    "unsupported stage-interface array bound {shown} on `{}` in the {} stage: an interface array is sized by a positive decimal integer literal, or by a macro whose value at that declaration is one",
                    d.author,
                    self.kind.name()
                )));
            }
        }
        Ok(())
    }
}

/// The text between the brackets of the declaration `d` as written in `source`.
fn written_bound(source: &str, d: &IfaceDecl) -> Option<String> {
    let decl = source.get(d.span.clone())?;
    let name_at = decl.find(d.author.as_str())?;
    let rest = &decl[name_at + d.author.len()..];
    let open = rest.find('[')?;
    let mut depth = 0usize;
    for (i, c) in rest[open..].char_indices() {
        match c {
            '[' => depth += 1,
            ']' => {
                depth -= 1;
                if depth == 0 {
                    return Some(rest[open + 1..open + i].trim().to_string());
                }
            }
            _ => {}
        }
    }
    None
}
