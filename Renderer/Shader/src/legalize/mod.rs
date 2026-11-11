// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! Interface and resource legalisation (spec part C2): turns the converted stages of a
//! program into the GLSL 450 that naga's GLSL front end accepts, with one shared uniform
//! block, a texture object and a sampler object per `sampler2D`, explicit descriptor
//! bindings and explicit interface locations, and the facts the reflection part reports.
//!
//! The dialect conversion (part C1) has already expanded macros, repaired types and
//! renamed the legacy spellings. Because it hands over a tree, the "rewrites compose in any
//! nesting" property of the spec holds by construction: no rewrite is a text edit, so none can
//! overlap another (R3, R81).
//!
//! Entry points: [`legalize`] for a program (both stages, the numbering the engine uses) and
//! [`legalize_stage`] for one stage alone (R31, R41).

mod bindings;
mod block;
mod collect;
mod error;
mod interface;
mod planes;
mod rewrite;
mod stage;

#[cfg(test)]
mod tests;

use std::collections::HashSet;

use crate::dialect::{convert_parsed, parse_stage};
use crate::names::{sampler_name, texture_name, video_chroma_name};
use crate::request::StageKind;
use crate::uniforms::{BlockLayout, UniformError};

pub use bindings::{MAX_BINDING, TextureBinding};
pub use block::BlockMemberPlan;
pub use error::LegalizeError;
pub use interface::{InterfacePlan, MAX_LOCATION, VaryingPlan};
pub use stage::LegalStage;

use bindings::{Bindings, allocate_program, allocate_standalone};
use block::{Member, plan_block};
use collect::{StageDecls, collect, normalize};
pub use collect::TexKind;
use interface::{StageInterface, assign_program, assign_standalone, input_plans, output_plans, reconcile};

/// What to legalize. A missing stage means the other one is legalized alone.
#[derive(Clone, Copy, Debug)]
pub struct ProgramInput<'a> {
    pub vertex: Option<&'a str>,
    pub fragment: Option<&'a str>,
    /// Material slots flagged for the NV12 plane variant (R45).
    pub planar_slots: &'a [u8],
    /// Leave the model's highest binding index (R30) to the reflection step, which reports a
    /// resource the stage uses above it, instead of refusing the layout here.
    pub unlimited_bindings: bool,
    /// `BACKBUFFER_MS` is set for the program (E-D8): `sampler2DBackBuffer` is multisampled.
    pub backbuffer_ms: bool,
    /// MS declarations whose bound image is resolved and has one physical sample.
    pub single_sample_slots: &'a [u8],
}

impl<'a> ProgramInput<'a> {
    pub fn program(vertex: &'a str, fragment: &'a str) -> ProgramInput<'a> {
        ProgramInput {
            vertex: Some(vertex),
            fragment: Some(fragment),
            planar_slots: &[],
            unlimited_bindings: false,
            backbuffer_ms: false,
            single_sample_slots: &[],
        }
    }

    pub fn with_planes(mut self, slots: &'a [u8]) -> ProgramInput<'a> {
        self.planar_slots = slots;
        self
    }

    /// The layout is not refused for a binding above the model's highest; see
    /// [`ProgramInput::unlimited_bindings`].
    pub fn without_binding_limit(mut self) -> ProgramInput<'a> {
        self.unlimited_bindings = true;
        self
    }

    /// The program is compiled with `BACKBUFFER_MS`; see [`ProgramInput::backbuffer_ms`].
    pub fn with_backbuffer_ms(mut self, on: bool) -> ProgramInput<'a> {
        self.backbuffer_ms = on;
        self
    }
}

/// The generated uniform block of a program.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct BlockPlan {
    pub binding: u32,
    pub members: Vec<BlockMemberPlan>,
}

impl BlockPlan {
    /// The std140 offsets, sizes and strides of the members (R22).
    pub fn layout(&self) -> Result<BlockLayout, UniformError> {
        let decls: Vec<crate::uniforms::MemberDecl> = self
            .members
            .iter()
            .map(|m| crate::uniforms::MemberDecl { name: m.name.clone(), ty: m.ty, array: m.array })
            .collect();
        crate::uniforms::layout_std140(&decls)
    }
}

/// A split texture of the program.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TexturePlan {
    pub name: String,
    pub sampler_name: String,
    pub texture_binding: u32,
    pub sampler_binding: u32,
    /// What the texture is (2D, 3D, a comparison depth texture, multisampled).
    pub kind: TexKind,
    pub in_vertex: bool,
    pub in_fragment: bool,
}

/// The chroma plane of a flagged video slot (R46).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PlanePlan {
    pub slot: u8,
    pub luma_texture: String,
    pub chroma_texture: String,
    pub chroma_sampler: String,
    pub texture_binding: u32,
    pub sampler_binding: u32,
    /// The stages that sample the slot and so declare the chroma resources.
    pub in_vertex: bool,
    pub in_fragment: bool,
}

/// A sampler-like uniform that is left as written and takes no part in the layout (R9).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct KeptResource {
    pub name: String,
    pub set: u32,
    pub binding: Option<u32>,
}

/// Everything the layout decided for the program, for reflection and the binding map.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ProgramLayout {
    pub block: Option<BlockPlan>,
    pub textures: Vec<TexturePlan>,
    pub planes: Vec<PlanePlan>,
    pub kept: Vec<KeptResource>,
    pub vertex_inputs: Vec<InterfacePlan>,
    pub fragment_outputs: Vec<InterfacePlan>,
    pub varyings: Vec<VaryingPlan>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LegalProgram {
    pub vertex: Option<LegalStage>,
    pub fragment: Option<LegalStage>,
    pub layout: ProgramLayout,
}

impl LegalProgram {
    pub fn stage(&self, kind: StageKind) -> Option<&LegalStage> {
        match kind {
            StageKind::Vertex => self.vertex.as_ref(),
            StageKind::Fragment => self.fragment.as_ref(),
        }
    }
}

struct Parsed {
    kind: StageKind,
    text: String,
    module: crate::dialect::Module,
    taken: HashSet<String>,
}

fn parse(kind: StageKind, text: &str) -> Result<Parsed, LegalizeError> {
    let (mut module, taken) = parse_stage(kind, text).map_err(LegalizeError::Front)?;
    normalize(&mut module);
    Ok(Parsed { kind, text: text.to_string(), module, taken })
}

/// Legalizes a program, or a single stage when the other is absent.
pub fn legalize(input: &ProgramInput<'_>) -> Result<LegalProgram, LegalizeError> {
    let mut parsed: Vec<Parsed> = Vec::new();
    if let Some(v) = input.vertex {
        parsed.push(parse(StageKind::Vertex, v)?);
    }
    if let Some(f) = input.fragment {
        parsed.push(parse(StageKind::Fragment, f)?);
    }
    if parsed.is_empty() {
        return Err(LegalizeError::request("no stage to legalize"));
    }
    let standalone = parsed.len() == 1;
    if standalone {
        collect(&parsed[0].module, parsed[0].kind)?.check_interface_bounds(&parsed[0].text)?;
    } else {
        let (v, f) = parsed.split_at_mut(1);
        reconcile(&mut v[0].module, &mut f[0].module, &v[0].text, &f[0].text)?;
    }

    // Convert (C1), then classify what the converted stages declare.
    let mut work = Vec::new();
    let mut decl_list: Vec<(StageKind, StageDecls)> = Vec::new();
    for p in parsed {
        let kind = p.kind;
        let options = crate::dialect::ConvertOptions { backbuffer_ms: input.backbuffer_ms, ..Default::default() };
        let c = convert_parsed(kind, p.module, p.taken, &p.text, options).map_err(LegalizeError::Front)?;
        let mut module = c.module;
        normalize(&mut module);
        let mut decls = collect(&module, kind)?;
        for texture in &mut decls.textures {
            if texture.kind == TexKind::D2Ms && texture.encoded()
                .is_some_and(|slot| input.single_sample_slots.iter().any(|s| u32::from(*s) == slot)) {
                // texelFetch(..., sample 0) and texelFetch(..., mip 0) have the
                // same coordinates and value for this one-sample resource.
                texture.kind = TexKind::D2;
            }
        }
        decl_list.push((kind, decls));
        work.push((kind, p.text, module));
    }
    let find = |kind: StageKind| decl_list.iter().find(|(k, _)| *k == kind).map(|(_, d)| d);
    let (vdecls, fdecls) = (find(StageKind::Vertex), find(StageKind::Fragment));
    let stage_decls: Vec<&StageDecls> = [vdecls, fdecls].into_iter().flatten().collect();

    // Planes exist only for flagged slots some stage declares (R45).
    let mut plane_slots: Vec<u8> = Vec::new();
    for &slot in input.planar_slots {
        let name = texture_name(u32::from(slot));
        if !plane_slots.contains(&slot) && stage_decls.iter().any(|s| s.textures.iter().any(|t| t.name == name)) {
            plane_slots.push(slot);
        }
    }

    // The uniform block and the descriptor bindings.
    let extra: Vec<_> = plane_slots.iter().flat_map(|s| planes::plane_members(*s)).collect();
    let members: Vec<Member> = plan_block(vdecls, fdecls, &extra)?;
    let has_author = stage_decls.iter().any(|s| !s.uniforms.is_empty());
    let bindings: Bindings = if standalone {
        allocate_standalone(stage_decls[0], !members.is_empty(), has_author, &plane_slots)?
    } else {
        allocate_program(&stage_decls, !members.is_empty(), has_author, &plane_slots, input.unlimited_bindings)?
    };

    // The interface.
    let (mut v_if, mut f_if) = (StageInterface::default(), StageInterface::default());
    let mut varyings = Vec::new();
    if standalone {
        let only = stage_decls[0];
        let i = assign_standalone(only)?;
        match only.kind {
            StageKind::Vertex => v_if = i,
            StageKind::Fragment => f_if = i,
        }
    } else {
        let (v, f, plans) = assign_program(vdecls.expect("two stages"), fdecls.expect("two stages"))?;
        v_if = v;
        f_if = f;
        varyings = plans;
    }

    // Finish each stage.
    let mut vertex = None;
    let mut fragment = None;
    let mut sampled: Vec<(StageKind, Vec<u8>)> = Vec::new();
    for (kind, text, module) in work {
        let decls = find(kind).expect("classified above");
        let interface = if kind == StageKind::Vertex { &v_if } else { &f_if };
        let done = stage::finish(stage::StageInput {
            kind,
            module,
            decls,
            interface,
            members: &members,
            bindings: &bindings,
            plane_slots: &plane_slots,
            text: &text,
        })?;
        sampled.push((kind, done.sampled_planes.clone()));
        match kind {
            StageKind::Vertex => vertex = Some(done),
            StageKind::Fragment => fragment = Some(done),
        }
    }

    // The facts for reflection.
    let layout = ProgramLayout {
        block: bindings.block.filter(|_| !members.is_empty()).map(|binding| BlockPlan {
            binding,
            members: members.iter().map(|m| m.plan.clone()).collect(),
        }),
        textures: program_textures(vdecls, fdecls, &bindings),
        planes: plane_slots
            .iter()
            .map(|&slot| {
                let b = bindings.planes[&slot];
                let sampled_in = |kind: StageKind| sampled.iter().any(|(k, s)| *k == kind && s.contains(&slot));
                let chroma = video_chroma_name(u32::from(slot));
                PlanePlan {
                    slot,
                    luma_texture: texture_name(u32::from(slot)),
                    chroma_sampler: sampler_name(&chroma),
                    chroma_texture: chroma,
                    texture_binding: b.texture,
                    sampler_binding: b.sampler,
                    in_vertex: sampled_in(StageKind::Vertex),
                    in_fragment: sampled_in(StageKind::Fragment),
                }
            })
            .collect(),
        kept: stage_decls
            .iter()
            .flat_map(|s| s.kept.iter())
            .map(|k| KeptResource { name: k.name.clone(), set: k.set, binding: k.binding })
            .collect(),
        vertex_inputs: input_plans(&v_if),
        fragment_outputs: output_plans(&f_if),
        varyings,
    };
    Ok(LegalProgram { vertex, fragment, layout })
}

fn program_textures(v: Option<&StageDecls>, f: Option<&StageDecls>, bindings: &Bindings) -> Vec<TexturePlan> {
    let mut out: Vec<TexturePlan> = Vec::new();
    for s in [v, f].into_iter().flatten() {
        for t in &s.textures {
            let b = bindings.textures[&t.name];
            match out.iter_mut().find(|p| p.name == t.name) {
                Some(p) => match s.kind {
                    StageKind::Vertex => p.in_vertex = true,
                    StageKind::Fragment => p.in_fragment = true,
                },
                None => out.push(TexturePlan {
                    name: t.name.clone(),
                    sampler_name: sampler_name(&t.name),
                    texture_binding: b.texture,
                    sampler_binding: b.sampler,
                    kind: t.kind,
                    in_vertex: s.kind == StageKind::Vertex,
                    in_fragment: s.kind == StageKind::Fragment,
                }),
            }
        }
    }
    out
}

/// Legalizes one stage alone with the numbering of R31 and R41.
pub fn legalize_stage(kind: StageKind, text: &str) -> Result<(LegalStage, ProgramLayout), LegalizeError> {
    let input = match kind {
        StageKind::Vertex => ProgramInput {
            vertex: Some(text),
            fragment: None,
            planar_slots: &[],
            unlimited_bindings: false,
            backbuffer_ms: false,
            single_sample_slots: &[],
        },
        StageKind::Fragment => ProgramInput {
            vertex: None,
            fragment: Some(text),
            planar_slots: &[],
            unlimited_bindings: false,
            backbuffer_ms: false,
            single_sample_slots: &[],
        },
    };
    let program = legalize(&input)?;
    let stage = match kind {
        StageKind::Vertex => program.vertex,
        StageKind::Fragment => program.fragment,
    };
    Ok((stage.expect("the requested stage"), program.layout))
}
