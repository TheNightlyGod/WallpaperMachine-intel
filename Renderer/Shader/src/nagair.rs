// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! What the backend and the reflection both need to know about the globals of a naga module:
//! which of them are resources, of what class, and under what name (D R45, R54, R56).

use naga::{AddressSpace, GlobalVariable, ImageClass, Module, TypeInner};

/// The class of a module-level variable as a host would have to bind it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum ResourceClass {
    /// A variable that is not a resource: private, workgroup or function data.
    NotAResource,
    UniformBuffer,
    StorageBuffer,
    /// A sampled or depth image.
    SampledImage,
    StorageImage,
    Sampler,
    /// Immediate (push-constant) data: not a bound resource at all.
    Immediate,
    /// A resource kind the Metal target cannot take, with a phrase saying what it is.
    Unsupported(&'static str),
}

/// How many elements a handle global holds: `None` for an ordinary one.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum HandleCount {
    Constant(u32),
    Unsized,
}

fn class_of_type(module: &Module, ty: naga::Handle<naga::Type>) -> ResourceClass {
    match &module.types[ty].inner {
        TypeInner::Image { class, .. } => match class {
            ImageClass::Sampled { .. } | ImageClass::Depth { .. } => ResourceClass::SampledImage,
            ImageClass::Storage { .. } => ResourceClass::StorageImage,
            ImageClass::External => ResourceClass::Unsupported("an external texture"),
        },
        TypeInner::Sampler { .. } => ResourceClass::Sampler,
        TypeInner::BindingArray { base, .. } => class_of_type(module, *base),
        TypeInner::AccelerationStructure { .. } => ResourceClass::Unsupported("an acceleration structure"),
        TypeInner::RayQuery { .. } => ResourceClass::Unsupported("a ray query"),
        _ => ResourceClass::Unsupported("a handle that is neither a texture nor a sampler"),
    }
}

/// The class of one global variable (D R45, R47).
pub(crate) fn classify(module: &Module, var: &GlobalVariable) -> ResourceClass {
    match var.space {
        AddressSpace::Function | AddressSpace::Private | AddressSpace::WorkGroup => ResourceClass::NotAResource,
        AddressSpace::Uniform => ResourceClass::UniformBuffer,
        AddressSpace::Storage { .. } => ResourceClass::StorageBuffer,
        AddressSpace::Immediate => ResourceClass::Immediate,
        AddressSpace::Handle => class_of_type(module, var.ty),
        AddressSpace::TaskPayload => ResourceClass::Unsupported("task payload data"),
        AddressSpace::RayPayload | AddressSpace::IncomingRayPayload => ResourceClass::Unsupported("ray payload data"),
    }
}

/// The element count of a handle global that is a binding array.
pub(crate) fn handle_count(module: &Module, var: &GlobalVariable) -> Option<HandleCount> {
    match &module.types[var.ty].inner {
        TypeInner::BindingArray { size, .. } => Some(match size {
            naga::ArraySize::Constant(n) => HandleCount::Constant(n.get()),
            naga::ArraySize::Pending(_) | naga::ArraySize::Dynamic => HandleCount::Unsized,
        }),
        _ => None,
    }
}

/// The declared name of a resource global; the type's name when the global has none (an
/// instance-less uniform block); empty when neither exists.
pub(crate) fn resource_name(module: &Module, var: &GlobalVariable) -> String {
    var.name.clone().or_else(|| module.types[var.ty].name.clone()).unwrap_or_default()
}

/// An error and the chain of its sources, joined with `: ` (naga's validation errors carry the
/// useful part in the source).
pub(crate) fn error_chain(error: &dyn std::error::Error) -> String {
    let mut text = error.to_string();
    let mut source = error.source();
    while let Some(s) = source {
        text.push_str(": ");
        text.push_str(&s.to_string());
        source = s.source();
    }
    text
}
