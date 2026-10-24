// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! Reflection of a translated naga module (spec D, 4.6, R53 to R62): the descriptors the stage
//! uses, its uniform blocks with their layout, its vertex inputs and the material texture slots
//! it samples.
//!
//! Reflection reads the module the Metal text was written from, never the GLSL again, and it
//! needs nothing from the front end: a module built with naga's own API reflects the same way.

use std::collections::{BTreeSet, HashMap};

use naga::valid::{Capabilities, ModuleInfo, ValidationFlags, Validator};
use naga::{Binding as NagaBinding, Module, ScalarKind, TypeInner, VectorSize};

use crate::backend::CompiledStage;
use crate::error::ShaderError;
use crate::nagair::{HandleCount, ResourceClass, classify, error_chain, handle_count, resource_name};
use crate::reflection::{
    BlockMember, DescriptorBinding, DescriptorKind, Reflection, ReflectionError, StageMask, UniformBlock,
    VertexFormat, VertexInput, VertexScalar, active_slot_for_texture,
};
use crate::request::StageKind;

/// The names a vertex input is reported under (D R58): the legalizer may declare an input the
/// shader writes under another name, and reflection reports the author's.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct InputNames {
    author_of: HashMap<String, String>,
}

impl InputNames {
    /// No renaming: every input is reported under its declared name.
    pub fn none() -> InputNames {
        InputNames::default()
    }

    /// Builds the map from `(declared name, author name)` pairs.
    pub fn from_pairs<'a>(pairs: impl IntoIterator<Item = (&'a str, &'a str)>) -> InputNames {
        InputNames { author_of: pairs.into_iter().map(|(d, a)| (d.to_string(), a.to_string())).collect() }
    }

    fn author<'a>(&'a self, declared: &'a str) -> &'a str {
        self.author_of.get(declared).map_or(declared, String::as_str)
    }
}

/// A step of the pipeline that can be replaced (D R6): describes a compiled stage.
pub trait StageReflector: Sync {
    fn reflect(&self, kind: StageKind, stage: &CompiledStage, names: &InputNames) -> Result<Reflection, ShaderError>;
}

/// The default reflector: reads the naga module of the compiled stage.
#[derive(Clone, Copy, Debug, Default)]
pub struct NagaReflector;

impl StageReflector for NagaReflector {
    fn reflect(&self, kind: StageKind, stage: &CompiledStage, names: &InputNames) -> Result<Reflection, ShaderError> {
        let Some(translated) = &stage.translated else {
            return Err(ShaderError::Internal { message: Some("the stage has no translated module to reflect".into()) });
        };
        // The module was validated once for translation; its usage information is reused (R53).
        reflect_module(kind, &translated.module, &translated.info, names).map_err(ShaderError::from)
    }
}

/// Reflects a module that is not validated yet: validation runs with every flag and every
/// capability so that usage information exists for any module naga can describe (D R53).
pub fn reflect_untranslated(kind: StageKind, module: &Module, names: &InputNames) -> Result<Reflection, ReflectionError> {
    let info = Validator::new(ValidationFlags::all(), Capabilities::all())
        .validate(module)
        .map_err(|e| ReflectionError::Validation { message: error_chain(e.as_inner()) })?;
    reflect_module(kind, module, &info, names)
}

fn stage_of(kind: StageKind) -> naga::ShaderStage {
    match kind {
        StageKind::Vertex => naga::ShaderStage::Vertex,
        StageKind::Fragment => naga::ShaderStage::Fragment,
    }
}

/// The backend and reflector both select the first entry of the requested stage. The
/// diagnostic retainer shares this selection, rather than guessing from the emitted MSL name.
#[inline]
pub(crate) fn selected_entry(kind: StageKind, module: &Module) -> Option<usize> {
    let stage = stage_of(kind);
    module.entry_points.iter().position(|e| e.stage == stage)
}

/// The existing reflection resource policy, shared with the opt-in diagnostic retainer.
/// This is a lazy, allocation-free iterator over the same globals in the same order.
#[inline]
pub(crate) fn active_resources<'a>(
    module: &'a Module,
    info: &'a ModuleInfo,
    entry: usize,
) -> impl Iterator<Item = (naga::Handle<naga::GlobalVariable>, &'a naga::GlobalVariable, ResourceClass)> + 'a {
    let usage = info.get_entry_point(entry);
    module.global_variables.iter().filter_map(move |(handle, var)| {
        let class = classify(module, var);
        if class == ResourceClass::NotAResource || usage[handle].is_empty() {
            None
        } else {
            Some((handle, var, class))
        }
    })
}

/// Reflects the entry point of `kind` of a validated module.
pub fn reflect_module(
    kind: StageKind,
    module: &Module,
    info: &ModuleInfo,
    names: &InputNames,
) -> Result<Reflection, ReflectionError> {
    let Some(index) = selected_entry(kind, module) else {
        return Err(ReflectionError::NoEntryPoint { stage: kind.name() });
    };
    let mask = StageMask::of(kind);

    let mut descriptors = Vec::new();
    let mut blocks = Vec::new();
    let mut slots = BTreeSet::new();
    for (_, var, class) in active_resources(module, info, index) {
        let name = resource_name(module, var);
        let (set, binding) = match &var.binding {
            Some(b) => (b.group, Some(b.binding)),
            None => (0, None),
        };
        let unsupported = |what: &str| ReflectionError::UnsupportedDescriptor {
            name: name.clone(),
            set,
            binding: binding.unwrap_or(0),
            what: what.to_string(),
        };
        let descriptor = match class {
            ResourceClass::NotAResource => continue,
            ResourceClass::UniformBuffer => DescriptorKind::UniformBuffer,
            ResourceClass::SampledImage => DescriptorKind::SampledImage,
            ResourceClass::Sampler => DescriptorKind::Sampler,
            ResourceClass::StorageBuffer => return Err(unsupported("a storage buffer")),
            ResourceClass::StorageImage => return Err(unsupported("a storage texture")),
            ResourceClass::Immediate => return Err(unsupported("immediate (push-constant) data")),
            ResourceClass::Unsupported(what) => return Err(unsupported(what)),
        };
        if class == ResourceClass::UniformBuffer {
            blocks.push(block_of(module, var, &name, set, binding)?);
        }
        if class == ResourceClass::SampledImage
            && let Some(slot) = active_slot_for_texture(&name)?
        {
            slots.insert(slot);
        }
        let Some(binding) = binding else { continue };
        let count = match handle_count(module, var) {
            None => 1,
            Some(HandleCount::Constant(n)) => n,
            Some(HandleCount::Unsized) => 0,
        };
        descriptors.push(DescriptorBinding { name, set, binding, descriptor, stages: mask, count });
    }

    let vertex_inputs = if kind == StageKind::Vertex { inputs_of(module, index, names)? } else { Vec::new() };
    let reflection = Reflection {
        descriptor_bindings: descriptors,
        uniform_blocks: blocks,
        vertex_inputs,
        active_texture_slots: slots,
    };
    reflection.check_limits()?;
    Ok(reflection)
}

/// The number of scalar components of one element of a type (D R56).
fn element_count(module: &Module, ty: naga::Handle<naga::Type>) -> u32 {
    match &module.types[ty].inner {
        TypeInner::Scalar(_) | TypeInner::Atomic(_) => 1,
        TypeInner::Vector { size, .. } => vector_len(*size),
        TypeInner::Matrix { columns, rows, .. } => vector_len(*columns) * vector_len(*rows),
        TypeInner::Array { base, .. } => element_count(module, *base),
        _ => 0,
    }
}

fn vector_len(size: VectorSize) -> u32 {
    match size {
        VectorSize::Bi => 2,
        VectorSize::Tri => 3,
        VectorSize::Quad => 4,
    }
}

fn block_of(
    module: &Module,
    var: &naga::GlobalVariable,
    name: &str,
    set: u32,
    binding: Option<u32>,
) -> Result<UniformBlock, ReflectionError> {
    let unusable = |reason: &str| ReflectionError::UnusableBlock { name: name.to_string(), reason: reason.to_string() };
    if name.is_empty() {
        return Err(unusable("it has neither a name nor a type name"));
    }
    let Some(binding) = binding else {
        return Err(unusable("it has no set and binding"));
    };
    let TypeInner::Struct { members, span } = &module.types[var.ty].inner else {
        return Err(unusable("it is not a structure"));
    };
    let ctx = module.to_ctx();
    let members = members
        .iter()
        .map(|m| {
            let inner = &module.types[m.ty].inner;
            let (array_count, array_stride) = match inner {
                TypeInner::Array { size: naga::ArraySize::Constant(n), stride, .. } => (n.get(), *stride),
                TypeInner::Array { stride, .. } => (0, *stride),
                _ => (0, 0),
            };
            BlockMember {
                name: m.name.clone().unwrap_or_default(),
                offset: m.offset,
                size: inner.size(ctx),
                element_count: element_count(module, m.ty),
                array_count,
                array_stride,
            }
        })
        .collect();
    Ok(UniformBlock { name: name.to_string(), set, binding, size: *span, members })
}

/// The format of a vertex input type, or `None` when no format carries it (D R59).
fn vertex_format(inner: &TypeInner) -> Option<VertexFormat> {
    let scalar_of = |s: &naga::Scalar| {
        if s.width != 4 {
            return None;
        }
        match s.kind {
            ScalarKind::Float => Some(VertexScalar::Float),
            ScalarKind::Uint => Some(VertexScalar::Uint),
            ScalarKind::Sint => Some(VertexScalar::Sint),
            _ => None,
        }
    };
    match inner {
        TypeInner::Scalar(s) => VertexFormat::new(scalar_of(s)?, 1),
        TypeInner::Vector { size, scalar } => VertexFormat::new(scalar_of(scalar)?, vector_len(*size) as u8),
        _ => None,
    }
}

/// A short GLSL-like spelling of a type for messages.
fn describe(module: &Module, ty: naga::Handle<naga::Type>) -> String {
    let scalar = |s: &naga::Scalar| match (s.kind, s.width) {
        (ScalarKind::Float, 4) => "float".to_string(),
        (ScalarKind::Float, w) => format!("float{}", u32::from(w) * 8),
        (ScalarKind::Sint, 4) => "int".to_string(),
        (ScalarKind::Sint, w) => format!("int{}", u32::from(w) * 8),
        (ScalarKind::Uint, 4) => "uint".to_string(),
        (ScalarKind::Uint, w) => format!("uint{}", u32::from(w) * 8),
        (ScalarKind::Bool, _) => "bool".to_string(),
        (other, _) => format!("{other:?}").to_lowercase(),
    };
    match &module.types[ty].inner {
        TypeInner::Scalar(s) => scalar(s),
        TypeInner::Vector { size, scalar: s } => format!("{}vec{}", scalar(s), vector_len(*size)),
        TypeInner::Matrix { columns, rows, scalar: s } => {
            format!("{}mat{}x{}", scalar(s), vector_len(*columns), vector_len(*rows))
        }
        TypeInner::Array { base, .. } => format!("array of {}", describe(module, *base)),
        TypeInner::Struct { .. } => module.types[ty].name.clone().unwrap_or_else(|| "struct".into()),
        other => format!("{other:?}"),
    }
}

/// Every location-bound argument of the entry point, read or not, in argument order (D R57).
fn inputs_of(module: &Module, entry: usize, names: &InputNames) -> Result<Vec<VertexInput>, ReflectionError> {
    let mut out = Vec::new();
    let mut add = |name: &str, location: u32, ty: naga::Handle<naga::Type>| -> Result<(), ReflectionError> {
        let name = names.author(name).to_string();
        let Some(format) = vertex_format(&module.types[ty].inner) else {
            return Err(ReflectionError::UnsupportedVertexInput { name, ty: describe(module, ty) });
        };
        out.push(VertexInput { name, location, format });
        Ok(())
    };
    for arg in &module.entry_points[entry].function.arguments {
        match &arg.binding {
            Some(NagaBinding::Location { location, .. }) => {
                add(arg.name.as_deref().unwrap_or(""), *location, arg.ty)?;
            }
            Some(NagaBinding::BuiltIn(_)) => {}
            None => {
                if let TypeInner::Struct { members, .. } = &module.types[arg.ty].inner {
                    for m in members {
                        if let Some(NagaBinding::Location { location, .. }) = &m.binding {
                            add(m.name.as_deref().unwrap_or(""), *location, m.ty)?;
                        }
                    }
                }
            }
        }
    }
    Ok(out)
}

#[cfg(test)]
mod tests;
