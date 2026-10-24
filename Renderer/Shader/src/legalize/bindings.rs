// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! Descriptor binding assignment (spec C2, 4.5): one flat number space in set 0 shared by the
//! uniform block, the textures and the samplers of both stages.

use std::collections::{BTreeMap, HashMap};

use super::collect::{StageDecls, TextureDecl};
use super::error::LegalizeError;

/// The highest descriptor binding the renderer-neutral model accepts (R30).
pub const MAX_BINDING: u32 = 31;

#[derive(Clone, Debug, PartialEq, Eq)]
enum Res {
    Block,
    Texture(String),
    Sampler(String),
    Kept(String),
}

impl Res {
    fn describe(&self) -> String {
        match self {
            Res::Block => "the uniform block `GlobalUniforms`".to_string(),
            Res::Texture(n) => format!("texture `{n}`"),
            Res::Sampler(n) => format!("the sampler of `{n}`"),
            Res::Kept(n) => format!("sampler uniform `{n}`"),
        }
    }
}

/// The bindings of one texture: the texture object and its sampler.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TextureBinding {
    pub texture: u32,
    pub sampler: u32,
}

/// What the allocation decided.
#[derive(Clone, Debug, Default)]
pub(crate) struct Bindings {
    pub block: Option<u32>,
    /// By texture name.
    pub textures: HashMap<String, TextureBinding>,
    /// Video chroma planes by material slot.
    pub planes: BTreeMap<u8, TextureBinding>,
}

#[derive(Default)]
struct Table {
    used: BTreeMap<u32, Res>,
    /// Set when the model's highest binding is not enforced here (the pipeline leaves it to
    /// reflection, which reports a resource the stage uses as outside the model limits).
    unlimited: bool,
}

impl Table {
    fn reserve(&mut self, binding: u32, res: Res) -> Result<(), LegalizeError> {
        if binding > MAX_BINDING && !self.unlimited {
            return Err(LegalizeError::request(format!(
                "descriptor binding {binding} of {} is above the highest binding {MAX_BINDING}",
                res.describe()
            )));
        }
        match self.used.get(&binding) {
            Some(other) if *other != res => Err(LegalizeError::request(format!(
                "descriptor binding {binding}: two incompatible resources claim it, {} and {}",
                other.describe(),
                res.describe()
            ))),
            _ => {
                self.used.insert(binding, res);
                Ok(())
            }
        }
    }

    fn lowest_free(&self) -> u32 {
        (0..).find(|b| !self.used.contains_key(b)).unwrap_or(u32::MAX)
    }

    fn take_lowest(&mut self, res: Res) -> Result<u32, LegalizeError> {
        let b = self.lowest_free();
        self.reserve(b, res)?;
        Ok(b)
    }
}

/// The single explicit binding of the block, if the uniform declarations name one.
fn explicit_block(stages: &[&StageDecls]) -> Result<Option<u32>, LegalizeError> {
    let mut found: Option<(u32, &str)> = None;
    for s in stages {
        for (binding, name) in &s.explicit_block {
            match found {
                Some((b, other)) if b != *binding => {
                    return Err(LegalizeError::request(format!(
                        "conflicting explicit GlobalUniforms descriptor bindings: `{other}` asks for {b} and `{name}` for {binding}"
                    )));
                }
                Some(_) => {}
                None => found = Some((*binding, name.as_str())),
            }
        }
    }
    Ok(found.map(|(b, _)| b))
}

fn reserve_known(table: &mut Table, stages: &[&StageDecls]) -> Result<(), LegalizeError> {
    for s in stages {
        let mut encoded: HashMap<u32, &str> = HashMap::new();
        for t in &s.textures {
            let Some(n) = t.encoded() else { continue };
            if let Some(other) = encoded.get(&n)
                && *other != t.name {
                    return Err(LegalizeError::stage_local(
                        s.kind,
                        Some(t.span.clone()),
                        format!("textures `{other}` and `{}` both encode descriptor binding {n}", t.name),
                    ));
                }
            encoded.insert(n, &t.name);
            table.reserve(n, Res::Texture(t.name.clone()))?;
        }
    }
    for s in stages {
        for k in &s.kept {
            if k.set == 0
                && let Some(b) = k.binding {
                    table.reserve(b, Res::Kept(k.name.clone()))?;
                }
        }
    }
    Ok(())
}

/// A texture's declaration order across the program: the vertex stage's, then the fragment's
/// (R28), each name once.
fn program_textures<'a>(stages: &[&'a StageDecls]) -> Vec<&'a TextureDecl> {
    let mut seen = std::collections::HashSet::new();
    let mut out = Vec::new();
    for s in stages {
        for t in &s.textures {
            if seen.insert(t.name.as_str()) {
                out.push(t);
            }
        }
    }
    out
}

/// Program numbering (R24 to R29): `stages` is the vertex stage then the fragment stage.
pub(crate) fn allocate_program(
    stages: &[&StageDecls],
    has_block: bool,
    has_author_uniforms: bool,
    plane_slots: &[u8],
    unlimited: bool,
) -> Result<Bindings, LegalizeError> {
    let mut table = Table { unlimited, ..Table::default() };
    let mut out = Bindings::default();
    reserve_known(&mut table, stages)?;
    let explicit = explicit_block(stages)?;
    if has_block && has_author_uniforms {
        out.block = Some(match explicit {
            Some(b) => {
                table.reserve(b, Res::Block)?;
                b
            }
            None => table.take_lowest(Res::Block)?,
        });
    }
    for t in program_textures(stages) {
        let texture = match t.encoded() {
            Some(n) => n,
            None => table.take_lowest(Res::Texture(t.name.clone()))?,
        };
        table.reserve(texture, Res::Texture(t.name.clone()))?;
        let sampler = table.take_lowest(Res::Sampler(t.name.clone()))?;
        out.textures.insert(t.name.clone(), TextureBinding { texture, sampler });
    }
    allocate_tail(&mut table, &mut out, explicit, has_block, plane_slots)?;
    Ok(out)
}

/// Standalone numbering of one stage (R31): block, then the textures that name no binding,
/// then every sampler in source order.
pub(crate) fn allocate_standalone(
    stage: &StageDecls,
    has_block: bool,
    has_author_uniforms: bool,
    plane_slots: &[u8],
) -> Result<Bindings, LegalizeError> {
    let stages = [stage];
    let mut table = Table::default();
    let mut out = Bindings::default();
    reserve_known(&mut table, &stages)?;
    let explicit = explicit_block(&stages)?;
    if has_block && has_author_uniforms {
        out.block = Some(match explicit {
            Some(b) => {
                table.reserve(b, Res::Block)?;
                b
            }
            None => table.take_lowest(Res::Block)?,
        });
    }
    let textures = program_textures(&stages);
    let mut texture_bindings: Vec<u32> = Vec::with_capacity(textures.len());
    for t in &textures {
        let b = match t.encoded() {
            Some(n) => n,
            None => table.take_lowest(Res::Texture(t.name.clone()))?,
        };
        texture_bindings.push(b);
    }
    for (t, texture) in textures.iter().zip(texture_bindings) {
        let sampler = table.take_lowest(Res::Sampler(t.name.clone()))?;
        out.textures.insert(t.name.clone(), TextureBinding { texture, sampler });
    }
    allocate_tail(&mut table, &mut out, explicit, has_block, plane_slots)?;
    Ok(out)
}

/// Video-plane resources take the lowest free bindings after every author resource (R29).
fn allocate_tail(
    table: &mut Table,
    out: &mut Bindings,
    explicit: Option<u32>,
    has_block: bool,
    plane_slots: &[u8],
) -> Result<(), LegalizeError> {
    if has_block && out.block.is_none() {
        out.block = Some(match explicit {
            Some(b) => {
                table.reserve(b, Res::Block)?;
                b
            }
            None => table.take_lowest(Res::Block)?,
        });
    }
    for &slot in plane_slots {
        let name = crate::names::video_chroma_name(u32::from(slot));
        let texture = table.take_lowest(Res::Texture(name.clone()))?;
        let sampler = table.take_lowest(Res::Sampler(name))?;
        out.planes.insert(slot, TextureBinding { texture, sampler });
    }
    Ok(())
}
