// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! The stage interface (spec C2, 4.6): locations of vertex inputs and varyings, matching of
//! varyings by name across the stages, reconciliation of their widths, and the vertex outputs
//! synthesized for fragment-only varyings.

use std::collections::HashSet;

use crate::dialect::ast::{Item, Module};
use crate::dialect::usage::{UseFacts, use_facts};
use crate::request::StageKind;

use super::collect::{Bound, Dir, IfaceDecl, StageDecls, collect, location_count};
use super::error::LegalizeError;

/// The highest location of a vertex input or a fragment output the renderer-neutral model accepts
/// (R30). Cross-stage varyings have no cap on their location numbers (amendment c2 R90): their limit
/// is [`MAX_INTERSTAGE_COMPONENTS`].
pub const MAX_LOCATION: u32 = 31;

/// The most components of stage-to-stage varyings the Metal compiler accepts in a fragment stage's
/// inputs (amendment d R66). A fixed number, not a value asked of a device, so the layer stays a
/// pure function of the request.
pub const MAX_INTERSTAGE_COMPONENTS: u32 = 124;

/// The prefix of a synthesized vertex output whose plain name is taken (`<out-prefix>`).
const SYNTH_PREFIX: &str = "_we_out_";

/// A declaration with the location it was given.
#[derive(Clone, Debug)]
pub(crate) struct Placed {
    pub decl: IfaceDecl,
    pub location: u32,
    /// A vertex output made up for a fragment-only varying (R35).
    pub synthesized: bool,
}

impl Placed {
    /// The `layout(location = L) in|out T name[N];` line (R10).
    pub fn declaration(&self) -> String {
        let d = &self.decl;
        let dir = match d.dir {
            Dir::In => "in",
            Dir::Out => "out",
        };
        let interp: String = d.interp.iter().map(|w| format!("{w} ")).collect();
        let suffix = d.bound.count().map(|n| format!("[{n}]")).unwrap_or_default();
        format!("layout(location = {}) {interp}{dir} {} {}{suffix};\n", self.location, d.ty, d.name)
    }

    /// The statement that gives a synthesized output a defined value (R8, R82).
    pub fn zero_statement(&self) -> String {
        let d = &self.decl;
        let zero = match d.ty.as_str() {
            "float" => "0.0".to_string(),
            t if t.starts_with("vec") => format!("{t}(0.0)"),
            t => format!("{t}(0)"),
        };
        match d.bound.count() {
            Some(n) => {
                let list = vec![zero; n as usize].join(", ");
                format!("{} = {}[{n}]({list});", d.name, d.ty)
            }
            None => format!("{} = {zero};", d.name),
        }
    }
}

/// The interface of one stage, in emission order.
#[derive(Clone, Debug, Default)]
pub(crate) struct StageInterface {
    pub vars: Vec<Placed>,
}

/// One varying as the program sees it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct VaryingPlan {
    pub name: String,
    pub location: u32,
    pub ty: String,
    pub array: Option<u32>,
    pub in_vertex: bool,
    pub in_fragment: bool,
    /// The name of the vertex output when the stage had to synthesize it.
    pub synthesized: Option<String>,
}

/// A vertex input or a fragment output.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct InterfacePlan {
    /// The author's name (reflection reports this, never the `_we_in_` copy).
    pub name: String,
    pub emitted_name: String,
    pub ty: String,
    pub array: Option<u32>,
    pub location: u32,
}

fn plan_of(p: &Placed) -> InterfacePlan {
    InterfacePlan {
        name: p.decl.author.clone(),
        emitted_name: p.decl.name.clone(),
        ty: p.decl.ty.clone(),
        array: p.decl.bound.count(),
        location: p.location,
    }
}

pub(crate) fn input_plans(i: &StageInterface) -> Vec<InterfacePlan> {
    i.vars.iter().filter(|p| p.decl.dir == Dir::In).map(plan_of).collect()
}

pub(crate) fn output_plans(i: &StageInterface) -> Vec<InterfacePlan> {
    i.vars.iter().filter(|p| p.decl.dir == Dir::Out && !p.synthesized).map(plan_of).collect()
}

fn width_of(ty: &str) -> Option<u8> {
    match ty {
        "float" => Some(1),
        "vec2" => Some(2),
        "vec3" => Some(3),
        "vec4" => Some(4),
        _ => None,
    }
}

fn type_for(width: u8) -> &'static str {
    match width {
        1 => "float",
        2 => "vec2",
        3 => "vec3",
        _ => "vec4",
    }
}

fn check_duplicates(s: &StageDecls, list: &[IfaceDecl]) -> Result<(), LegalizeError> {
    let mut seen = HashSet::new();
    for d in list {
        if !seen.insert(d.author.as_str()) {
            return Err(LegalizeError::cross_stage(
                s.kind,
                Some(d.span.clone()),
                format!("cross-stage varying `{}` is declared twice in the {} stage", d.author, s.kind.name()),
            ));
        }
    }
    Ok(())
}

/// What the width reconciliation decided for one varying (R36).
enum Verdict {
    Same,
    /// New types for the vertex output and the fragment input.
    Narrow { vertex: Option<&'static str>, fragment: Option<&'static str> },
    Mismatch,
}

fn decide(v: &IfaceDecl, f: &IfaceDecl, vu: UseFacts, fu: UseFacts) -> Verdict {
    if v.ty == f.ty {
        return Verdict::Same;
    }
    let (Some(vw), Some(fw)) = (width_of(&v.ty), width_of(&f.ty)) else { return Verdict::Mismatch };
    let neither_array = v.bound == Bound::None && f.bound == Bound::None;
    // (a) the vertex output is wider than the fragment input and nothing touches the extra components.
    if vw > fw && !vu.read_whole && vu.max_component <= fw && fu.max_component <= fw {
        return Verdict::Narrow { vertex: Some(type_for(fw)), fragment: None };
    }
    // (b) the vertex output is narrower and the fragment never needs more than it has.
    if vw < fw && !fu.read_whole && fu.max_component <= vw {
        return Verdict::Narrow { vertex: None, fragment: Some(type_for(vw)) };
    }
    // (c) the fragment declares fewer components than it selects and the vertex has enough.
    if neither_array && fu.max_component > fw && vw >= fu.max_component {
        return Verdict::Narrow { vertex: Some(type_for(vw)), fragment: Some(type_for(vw)) };
    }
    Verdict::Mismatch
}

fn set_type(module: &mut Module, item: usize, ty: &str) {
    if let Some(Item::Var(d)) = module.items.get_mut(item) {
        d.ty.name = ty.to_string();
    }
}

/// Reconciles the widths of the varyings the two stages declare under one name (R33 to R37,
/// R84) on the parsed stages, before they are converted, so that the converter sees the
/// reconciled types (C1 R89).
pub(crate) fn reconcile(vertex: &mut Module, fragment: &mut Module, vertex_text: &str, fragment_text: &str) -> Result<(), LegalizeError> {
    let vd = collect(vertex, StageKind::Vertex)?;
    let fd = collect(fragment, StageKind::Fragment)?;
    vd.check_interface_bounds(vertex_text)?;
    fd.check_interface_bounds(fragment_text)?;
    let v_out: Vec<IfaceDecl> = vd.outputs.clone();
    let f_in: Vec<IfaceDecl> = fd.inputs.clone();
    check_duplicates(&vd, &v_out)?;
    check_duplicates(&fd, &f_in)?;
    for f in &f_in {
        let Some(v) = v_out.iter().find(|v| v.author == f.author) else { continue };
        let vu = use_facts(vertex, &v.author);
        let fu = use_facts(fragment, &f.author);
        match decide(v, f, vu, fu) {
            Verdict::Same => {}
            Verdict::Narrow { vertex: vt, fragment: ft } => {
                if let Some(t) = vt {
                    set_type(vertex, v.item, t);
                }
                if let Some(t) = ft {
                    set_type(fragment, f.item, t);
                }
            }
            Verdict::Mismatch => {
                return Err(LegalizeError::cross_stage(
                    StageKind::Fragment,
                    Some(f.span.clone()),
                    format!("cross-stage varying `{}` type mismatch: vertex outputs {} but fragment inputs {}", f.author, v.ty, f.ty),
                ));
            }
        }
    }
    // Arrays of different sizes would overlap later locations or mis-link (R84).
    let vd = collect(vertex, StageKind::Vertex)?;
    let fd = collect(fragment, StageKind::Fragment)?;
    for f in &fd.inputs {
        let Some(v) = vd.outputs.iter().find(|v| v.author == f.author) else { continue };
        if v.bound != f.bound {
            let show = |d: &IfaceDecl| match d.bound.count() {
                Some(n) => format!("{}[{n}]", d.ty),
                None => format!("{} (not an array)", d.ty),
            };
            return Err(LegalizeError::cross_stage(
                StageKind::Fragment,
                Some(f.span.clone()),
                format!(
                    "cross-stage varying `{}` array bound mismatch: vertex outputs {} but fragment inputs {}",
                    f.author,
                    show(v),
                    show(f)
                ),
            ));
        }
    }
    Ok(())
}

fn vertex_input_count(d: &IfaceDecl) -> u32 {
    // An array of attributes is one location (R32); a matrix takes a location per column.
    location_count(&d.ty, None)
}

fn check_location(d: &IfaceDecl, location: u32, count: u32, kind: StageKind) -> Result<(), LegalizeError> {
    let last = location.saturating_add(count.max(1) - 1);
    if last > MAX_LOCATION {
        return Err(LegalizeError::request(format!(
            "interface location {last} of `{}` in the {} stage is above the highest location {MAX_LOCATION}",
            d.author,
            kind.name()
        )));
    }
    Ok(())
}

/// The components a varying of type `ty` and `array` elements adds to the inter-stage budget (R66): a
/// scalar is 1, a vector of width N is N, a matrix is columns times rows, an array multiplies. A type
/// this layer cannot size counts as a four-wide vector, the conservative reading.
fn component_count(ty: &str, array: Option<u32>) -> u32 {
    use crate::dialect::ty::{Ty, builtin_type};
    let each = match builtin_type(ty) {
        Some(Ty::Scalar(_)) => 1,
        Some(Ty::Vec(_, width)) => u32::from(width),
        Some(Ty::Mat(columns, rows)) => u32::from(columns) * u32::from(rows),
        _ => 4,
    };
    each.saturating_mul(array.unwrap_or(1))
}

/// R66: the components of the fragment stage's varying inputs, in source order, must not exceed
/// [`MAX_INTERSTAGE_COMPONENTS`]. Vertex outputs no fragment input names are free. The failure names
/// the total, the limit, the stage and the varying whose addition first crossed the limit.
fn check_component_budget(inputs: &[IfaceDecl], kind: StageKind) -> Result<(), LegalizeError> {
    let mut total = 0u32;
    let mut crossed: Option<&IfaceDecl> = None;
    for d in inputs {
        total = total.saturating_add(component_count(&d.ty, d.bound.count()));
        if total > MAX_INTERSTAGE_COMPONENTS && crossed.is_none() {
            crossed = Some(d);
        }
    }
    match crossed {
        Some(first) => Err(LegalizeError::request(format!(
            "the {} stage declares {total} components of stage-to-stage varyings, above the limit of {MAX_INTERSTAGE_COMPONENTS} (the addition of `{}` crossed it)",
            kind.name(),
            first.author
        ))),
        None => Ok(()),
    }
}

fn by_item(mut list: Vec<IfaceDecl>) -> Vec<IfaceDecl> {
    list.sort_by_key(|d| d.item);
    list
}

/// Locations for both stages (R32 to R38).
pub(crate) fn assign_program(
    vertex: &StageDecls,
    fragment: &StageDecls,
) -> Result<(StageInterface, StageInterface, Vec<VaryingPlan>), LegalizeError> {
    let mut v = StageInterface::default();
    let mut f = StageInterface::default();
    let mut plans: Vec<VaryingPlan> = Vec::new();

    // Vertex inputs, in source order.
    let mut next = 0u32;
    let mut vertex_vars: Vec<Placed> = Vec::new();
    for d in by_item(vertex.inputs.clone()) {
        let count = vertex_input_count(&d);
        check_location(&d, next, count, StageKind::Vertex)?;
        vertex_vars.push(Placed { decl: d, location: next, synthesized: false });
        next += count;
    }

    // Varyings: the fragment stage drives, vertex-only ones follow (R33).
    let f_in = by_item(fragment.inputs.clone());
    let v_out = by_item(vertex.outputs.clone());
    check_component_budget(&f_in, StageKind::Fragment)?;
    let mut running = 0u32;
    let mut vertex_out_loc: Vec<Option<u32>> = vec![None; v_out.len()];
    let mut fragment_vars: Vec<Placed> = Vec::new();
    let mut synth: Vec<Placed> = Vec::new();
    let mut taken: HashSet<String> = vertex.top_names.clone();
    for d in f_in {
        let count = d.location_count();
        let location = running;
        running = running.saturating_add(count);
        let matched = v_out.iter().position(|o| o.author == d.author);
        let mut synthesized = None;
        match matched {
            Some(i) => vertex_out_loc[i] = Some(location),
            None => {
                let name = synth_name(&d.author, &mut taken);
                synthesized = Some(name.clone());
                let decl = IfaceDecl { name, dir: Dir::Out, item: usize::MAX, ..d.clone() };
                synth.push(Placed { decl, location, synthesized: true });
            }
        }
        plans.push(VaryingPlan {
            name: d.author.clone(),
            location,
            ty: d.ty.clone(),
            array: d.bound.count(),
            in_vertex: matched.is_some(),
            in_fragment: true,
            synthesized,
        });
        fragment_vars.push(Placed { decl: d, location, synthesized: false });
    }
    for (i, d) in v_out.into_iter().enumerate() {
        let location = match vertex_out_loc[i] {
            Some(l) => l,
            None => {
                let count = d.location_count();
                let l = running;
                running = running.saturating_add(count);
                plans.push(VaryingPlan {
                    name: d.author.clone(),
                    location: l,
                    ty: d.ty.clone(),
                    array: d.bound.count(),
                    in_vertex: true,
                    in_fragment: false,
                    synthesized: None,
                });
                l
            }
        };
        vertex_vars.push(Placed { decl: d, location, synthesized: false });
    }

    // Fragment outputs the author declared (R38).
    let mut out_loc = 0u32;
    for d in by_item(fragment.outputs.clone()) {
        let count = d.location_count();
        check_location(&d, out_loc, count, StageKind::Fragment)?;
        fragment_vars.push(Placed { decl: d, location: out_loc, synthesized: false });
        out_loc += count;
    }

    vertex_vars.sort_by_key(|p| p.decl.item);
    fragment_vars.sort_by_key(|p| p.decl.item);
    vertex_vars.extend(synth);
    v.vars = vertex_vars;
    f.vars = fragment_vars;
    Ok((v, f, plans))
}

fn synth_name(author: &str, taken: &mut HashSet<String>) -> String {
    let mut name = if taken.contains(author) { format!("{SYNTH_PREFIX}{author}") } else { author.to_string() };
    let mut n = 0;
    while taken.contains(&name) {
        n += 1;
        name = format!("{SYNTH_PREFIX}{author}_{n}");
    }
    taken.insert(name.clone());
    name
}

/// Locations of a stage legalized alone (R41): inputs and outputs are numbered separately
/// from 0 in source order. A declaration takes one location, and an array or a matrix as many as
/// it has elements or columns, as in a program: naga refuses two variables on one location, so
/// the one-location-per-array numbering of the old standalone mode cannot be kept.
pub(crate) fn assign_standalone(stage: &StageDecls) -> Result<StageInterface, LegalizeError> {
    let mut vars = Vec::new();
    let (mut next_in, mut next_out) = (0u32, 0u32);
    let mut all: Vec<IfaceDecl> = stage.inputs.iter().chain(&stage.outputs).cloned().collect();
    all.sort_by_key(|d| d.item);
    if stage.kind == StageKind::Fragment {
        check_component_budget(&by_item(stage.inputs.clone()), stage.kind)?;
    }
    for d in all {
        let counter = if d.dir == Dir::In { &mut next_in } else { &mut next_out };
        let count = d.location_count();
        // Only vertex inputs and fragment outputs have a location cap; a varying is limited by components.
        let is_varying = (d.dir == Dir::Out) == (stage.kind == StageKind::Vertex);
        if !is_varying {
            check_location(&d, *counter, count, stage.kind)?;
        }
        let location = *counter;
        *counter = counter.saturating_add(count);
        vars.push(Placed { decl: d, location, synthesized: false });
    }
    Ok(StageInterface { vars })
}
