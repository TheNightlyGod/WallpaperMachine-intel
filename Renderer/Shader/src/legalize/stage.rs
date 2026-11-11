// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! Assembly of one legalized stage (spec C2, 4.2): the generated declarations, the main
//! prelude and the author's code with the rewrites applied.

use std::collections::{HashMap, HashSet};

use crate::dialect::ast::*;
use crate::dialect::print::module_to_string;
use crate::dialect::HEADER;
use crate::diagnostic::Diagnostic;
use crate::names::sampler_name;
use crate::request::StageKind;

use super::bindings::Bindings;
use super::block::{Member, block_declaration, own_view};
use super::collect::StageDecls;
use super::error::LegalizeError;
use super::interface::StageInterface;
use super::planes;
use super::rewrite::{MemberCx, Rewriter, StageCx, TexCx};

/// A legalized stage.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LegalStage {
    pub kind: StageKind,
    /// The GLSL 450 text handed to the compiler.
    pub text: String,
    /// One informational entry (R74).
    pub diagnostics: Vec<Diagnostic>,
    /// The video planes this stage samples, by material slot.
    pub sampled_planes: Vec<u8>,
}

pub(crate) struct StageInput<'a> {
    pub kind: StageKind,
    pub module: Module,
    pub decls: &'a StageDecls,
    pub interface: &'a StageInterface,
    pub members: &'a [Member],
    pub bindings: &'a Bindings,
    /// Flagged slots that have a plane in this program.
    pub plane_slots: &'a [u8],
    /// The stage text the tree came from.
    pub text: &'a str,
}

/// Identifier-like words of a text: the names a generated name must not collide with.
fn identifiers_of(text: &str) -> HashSet<String> {
    let mut out = HashSet::new();
    let mut word = String::new();
    for c in text.chars().chain(std::iter::once(' ')) {
        if c.is_ascii_alphanumeric() || c == '_' {
            word.push(c);
        } else if !word.is_empty() {
            out.insert(std::mem::take(&mut word));
        }
    }
    out
}

fn fresh(base: &str, taken: &mut HashSet<String>) -> String {
    let mut name = base.to_string();
    let mut n = 0;
    while taken.contains(&name) {
        n += 1;
        name = format!("{base}_{n}");
    }
    taken.insert(name.clone());
    name
}

pub(crate) fn finish(input: StageInput<'_>) -> Result<LegalStage, LegalizeError> {
    let StageInput { kind, mut module, decls, interface, members, bindings, plane_slots, text } = input;
    let mut taken = identifiers_of(&module_to_string(&module));

    // Items that stay, with `#extension` lines first (they must precede any declaration).
    let items = std::mem::take(&mut module.items);
    let mut hoisted: Vec<Item> = Vec::new();
    let mut rest: Vec<Item> = Vec::new();
    for (i, item) in items.into_iter().enumerate() {
        if decls.removed.contains(&i) {
            continue;
        }
        match &item {
            Item::Directive(t) if t.trim_start().starts_with("#extension") => hoisted.push(item),
            _ => rest.push(item),
        }
    }
    let mut rest = Module { items: rest };

    // The context of the rewrite.
    let mut cx = StageCx {
        kind,
        members: HashMap::new(),
        textures: HashMap::new(),
        frag_out: None,
        plane_helpers: HashMap::new(),
    };
    for u in &decls.uniforms {
        if let Some(m) = members.iter().find(|m| m.plan.name == u.name) {
            cx.members.insert(u.name.clone(), MemberCx { read: m.read.clone(), view: own_view(m, kind) });
        }
    }
    for t in &decls.textures {
        let plane = crate::names::classify_slot_name(&t.name);
        let slot = match plane {
            crate::names::SlotName::Canonical(n) => u8::try_from(n).ok().filter(|s| plane_slots.contains(s)),
            _ => None,
        };
        cx.textures.insert(t.name.clone(), TexCx { kind: t.kind, sampler: sampler_name(&t.name), plane: slot });
    }
    if kind == StageKind::Fragment {
        cx.frag_out = Some(fresh("_we_FragColor", &mut taken));
    }
    let mut converts: HashMap<u8, String> = HashMap::new();
    for &slot in plane_slots {
        if decls.textures.iter().any(|t| t.name == crate::names::texture_name(u32::from(slot))) {
            cx.plane_helpers.insert(slot, fresh(&format!("_we_plane{slot}"), &mut taken));
            converts.insert(slot, fresh(&format!("_we_nv12_convert{slot}"), &mut taken));
        }
    }

    let mut rewriter = Rewriter::new(&cx);
    rewriter.module(&mut rest);
    let found = rewriter.found;
    if let Some(e) = found.errors.into_iter().next() {
        return Err(e);
    }

    // Generated declarations (R6).
    let mut head = String::new();
    let mut seen = HashSet::new();
    let textures: Vec<_> = decls.textures.iter().filter(|t| seen.insert(t.name.as_str())).collect();
    for t in &textures {
        let b = bindings.textures[&t.name];
        head.push_str(&format!("layout(set = 0, binding = {}) uniform {} {};\n", b.texture, t.kind.object_type(), t.name));
    }
    for t in &textures {
        let b = bindings.textures[&t.name];
        head.push_str(&format!(
            "layout(set = 0, binding = {}) uniform {} {};\n",
            b.sampler,
            t.kind.sampler_type(),
            sampler_name(&t.name)
        ));
    }
    for slot in &found.sampled_planes {
        let b = bindings.planes[slot];
        head.push_str(&planes::chroma_declarations(*slot, b.texture, b.sampler));
    }
    if !head.is_empty() {
        head.push('\n');
    }
    if !members.is_empty()
        && let Some(binding) = bindings.block {
            head.push_str(&block_declaration(members, binding));
            head.push('\n');
        }
    let mut interface_text = String::new();
    for p in &interface.vars {
        interface_text.push_str(&p.declaration());
    }
    if found.used_frag_color
        && let Some(out) = &cx.frag_out {
            interface_text.push_str(&format!("layout(location = 0) out vec4 {out};\n"));
        }
    if !interface_text.is_empty() {
        interface_text.push('\n');
    }
    head.push_str(&interface_text);
    for slot in &found.sampled_planes {
        let texture = crate::names::texture_name(u32::from(*slot));
        head.push_str(&planes::helper_source(*slot, &texture, &cx.plane_helpers[slot], &converts[slot]));
    }

    // The main prelude: synthesized outputs start from zero (R8).
    let zero: Vec<String> = interface.vars.iter().filter(|p| p.synthesized).map(|p| p.zero_statement()).collect();
    if !zero.is_empty() {
        for item in rest.items.iter_mut() {
            if let Item::Function(f) = item
                && f.name == "main"
                && let Some(body) = &mut f.body {
                    let stmts: Vec<Stmt> = zero.iter().map(|s| Stmt::Directive(s.clone())).collect();
                    body.splice(0..0, stmts);
                    break;
                }
        }
    }

    let mut out = String::from(HEADER);
    out.push('\n');
    out.push_str(&module_to_string(&Module { items: hoisted }));
    out.push_str(&head);
    out.push_str(&module_to_string(&rest));
    Ok(LegalStage {
        kind,
        text: out,
        diagnostics: vec![Diagnostic::codegen_info(kind, text)],
        sampled_planes: found.sampled_planes.into_iter().collect(),
    })
}
