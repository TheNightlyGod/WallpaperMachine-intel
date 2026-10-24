// WallpaperMachine diagnostics for its independently authored shader pipeline.
// Physical layout facts use the permitted Naga IR/layout API.
//! Opt-in, owned observations of the original translated Naga uniform storage types.
//!
//! These are compiler-origin observations, NOT Metal runtime reflection or native buffer
//! capture. Logical/authored component counts remain in ordinary reflection. Only this
//! module's feature-enabled serialization adds a diagnostic field to that existing document.

use naga::proc::Alignment;
use naga::{ArraySize, ScalarKind, TypeInner};

use crate::backend::CompiledStage;
use crate::json;
use crate::nagair::ResourceClass;
use crate::pipeline::CompiledProgram;
use crate::reflect::{active_resources, selected_entry};
use crate::request::StageKind;

pub const SCHEMA_VERSION: u32 = 1;
pub const MAX_BLOCKS: usize = 128;
pub const MAX_MEMBERS: usize = 4096;
pub const MAX_ARRAY_DIMENSIONS: usize = 16;
pub const MAX_NAME_BYTES: usize = 256 * 1024;

/// Failure to observe does not change shader compilation success. No unavailable observation
/// contains a default scalar, zero dimensions or a fabricated physical byte span.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Unavailable {
    TranslatedModuleAbsent,
    EntryPointAbsent,
    MissingResourceBinding,
    BlockNotStruct,
    UnsupportedType,
    UnsupportedScalar,
    NonConstantArray,
    LayoutSizeUnavailable,
    ObservationLimit,
}

impl Unavailable {
    pub fn code(self) -> &'static str {
        match self {
            Self::TranslatedModuleAbsent => "translated_module_absent",
            Self::EntryPointAbsent => "entry_point_absent",
            Self::MissingResourceBinding => "missing_resource_binding",
            Self::BlockNotStruct => "block_not_struct",
            Self::UnsupportedType => "unsupported_type",
            Self::UnsupportedScalar => "unsupported_scalar",
            Self::NonConstantArray => "non_constant_array",
            Self::LayoutSizeUnavailable => "layout_size_unavailable",
            Self::ObservationLimit => "observation_limit",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Observation<T> {
    Available(T),
    Unavailable(Unavailable),
}

impl<T> Observation<T> {
    fn to_json(&self, encode: impl FnOnce(&T) -> String) -> String {
        match self {
            Self::Available(value) => json::object(&[
                ("status", json::string("available")),
                ("value", encode(value)),
            ]),
            Self::Unavailable(reason) => json::object(&[
                ("status", json::string("unavailable")),
                ("reason", json::string(reason.code())),
            ]),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ScalarBase {
    Signed,
    Unsigned,
    Float,
    Bool,
}

impl ScalarBase {
    fn name(self) -> &'static str {
        match self {
            Self::Signed => "signed",
            Self::Unsigned => "unsigned",
            Self::Float => "float",
            Self::Bool => "bool",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct PhysicalScalar {
    pub base: ScalarBase,
    pub byte_width: u8,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ElementShape {
    Scalar,
    Vector { components: u8 },
    Matrix { columns: u8, rows: u8, column_stride: u32 },
}

impl ElementShape {
    fn name(self) -> &'static str {
        match self {
            Self::Scalar => "scalar",
            Self::Vector { .. } => "vector",
            Self::Matrix { .. } => "matrix",
        }
    }

    fn to_json(self) -> String {
        match self {
            Self::Scalar => json::object(&[("kind", json::string("scalar"))]),
            Self::Vector { components } => json::object(&[
                ("kind", json::string("vector")),
                ("components", components.to_string()),
            ]),
            Self::Matrix { columns, rows, column_stride } => json::object(&[
                ("kind", json::string("matrix")),
                ("columns", columns.to_string()),
                ("rows", rows.to_string()),
                ("column_stride", column_stride.to_string()),
            ]),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ArrayDimension {
    pub count: u32,
    pub stride: u32,
}

/// `arrays` is outermost first, empty for a non-array. `element_shape` describes the actual
/// leaf storage type, not the author's pre-legalization type. No per-element expansion.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PhysicalType {
    pub scalar: PhysicalScalar,
    pub element_shape: ElementShape,
    pub arrays: Vec<ArrayDimension>,
}

impl PhysicalType {
    fn to_json(&self) -> String {
        json::object(&[
            ("kind", json::string(if self.arrays.is_empty() { self.element_shape.name() } else { "array" })),
            ("scalar", json::object(&[
                ("base", json::string(self.scalar.base.name())),
                ("byte_width", self.scalar.byte_width.to_string()),
            ])),
            ("element_shape", self.element_shape.to_json()),
            ("array_dimensions", json::array(self.arrays.iter().map(|dimension| json::object(&[
                ("count", dimension.count.to_string()),
                ("stride", dimension.stride.to_string()),
            ])))),
        ])
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MemberLayout {
    /// Naga's size of the full physical member type, including array/matrix strides. This
    /// is not the gap to the next member or an authored value's packed byte count.
    pub byte_span: u32,
    pub ty: PhysicalType,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct UniformMember {
    pub member_index: usize,
    pub name: Option<String>,
    /// Relative to the block, copied directly from the translated StructMember.
    pub offset: u32,
    pub layout: Observation<MemberLayout>,
}

impl UniformMember {
    fn to_json(&self) -> String {
        json::object(&[
            ("member_index", self.member_index.to_string()),
            ("name", self.name.as_deref().map_or_else(json::null, json::string)),
            ("offset", self.offset.to_string()),
            ("layout", self.layout.to_json(|layout| json::object(&[
                ("byte_span", layout.byte_span.to_string()),
                ("type", layout.ty.to_json()),
            ]))),
        ])
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct BlockLayout {
    pub byte_span: u32,
    pub members: Vec<UniformMember>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct UniformBlock {
    /// Stable only within this original translated module; set/binding and name are also
    /// retained. No claim that this is a Metal argument index.
    pub global_index: usize,
    pub name: String,
    pub set: Option<u32>,
    pub binding: Option<u32>,
    pub layout: Observation<BlockLayout>,
}

impl UniformBlock {
    fn to_json(&self) -> String {
        json::object(&[
            ("global_index", self.global_index.to_string()),
            ("name", json::string(&self.name)),
            ("set", self.set.map_or_else(json::null, |value| value.to_string())),
            ("binding", self.binding.map_or_else(json::null, |value| value.to_string())),
            ("layout", self.layout.to_json(|layout| json::object(&[
                ("byte_span", layout.byte_span.to_string()),
                ("members", json::array(layout.members.iter().map(UniformMember::to_json))),
            ]))),
        ])
    }
}

/// Attached to the owning ProgramStage, never a process-global registry. Source and MSL
/// entry names are distinct because the writer may rename the selected entry point.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct StageUniformLayout {
    pub stage: StageKind,
    pub source_entry_point: Option<String>,
    pub msl_entry_point: Option<String>,
    pub blocks: Observation<Vec<UniformBlock>>,
}

impl StageUniformLayout {
    /// A consumer must refuse incomplete metadata, including an unsupported nested member.
    pub fn is_complete(&self) -> bool {
        let Observation::Available(blocks) = &self.blocks else { return false };
        blocks.iter().all(|block| match &block.layout {
            Observation::Available(layout) => layout.members.iter().all(|member| matches!(member.layout, Observation::Available(_))),
            Observation::Unavailable(_) => false,
        })
    }

    fn to_json(&self) -> String {
        json::object(&[
            ("stage", json::string(self.stage.name())),
            ("source_entry_point", self.source_entry_point.as_deref().map_or_else(json::null, json::string)),
            ("msl_entry_point", self.msl_entry_point.as_deref().map_or_else(json::null, json::string)),
            ("complete", json::boolean(self.is_complete())),
            ("blocks", self.blocks.to_json(|blocks| json::array(blocks.iter().map(UniformBlock::to_json)))),
        ])
    }
}

#[derive(Default)]
struct Budget {
    members: usize,
    name_bytes: usize,
}

impl Budget {
    fn name(&mut self, name: &str) -> Result<String, Unavailable> {
        if name.len() > MAX_NAME_BYTES - self.name_bytes {
            return Err(Unavailable::ObservationLimit);
        }
        self.name_bytes += name.len();
        Ok(name.to_string())
    }
}

fn physical_type(module: &naga::Module, mut ty: naga::Handle<naga::Type>) -> Result<PhysicalType, Unavailable> {
    let mut arrays = Vec::new();
    loop {
        let (scalar, element_shape) = match &module.types[ty].inner {
            TypeInner::Array { base, size, stride } => {
                if arrays.len() == MAX_ARRAY_DIMENSIONS {
                    return Err(Unavailable::ObservationLimit);
                }
                let ArraySize::Constant(count) = size else { return Err(Unavailable::NonConstantArray) };
                arrays.push(ArrayDimension { count: count.get(), stride: *stride });
                ty = *base;
                continue;
            }
            TypeInner::Scalar(scalar) => (*scalar, ElementShape::Scalar),
            TypeInner::Vector { size, scalar } => (*scalar, ElementShape::Vector { components: u8::from(*size) }),
            TypeInner::Matrix { columns, rows, scalar } => (*scalar, ElementShape::Matrix {
                columns: u8::from(*columns),
                rows: u8::from(*rows),
                // The exact Naga column-vector alignment rule, also used by TypeInner::try_size.
                // In particular, a 3-row float matrix has 16-byte columns, not 12; array stride
                // describes an entire matrix and must never be substituted here.
                column_stride: Alignment::from(*rows) * u32::from(scalar.width),
            }),
            _ => return Err(Unavailable::UnsupportedType),
        };
        let base = match scalar.kind {
            ScalarKind::Sint => ScalarBase::Signed,
            ScalarKind::Uint => ScalarBase::Unsigned,
            ScalarKind::Float => ScalarBase::Float,
            ScalarKind::Bool => ScalarBase::Bool,
            ScalarKind::AbstractInt | ScalarKind::AbstractFloat => return Err(Unavailable::UnsupportedScalar),
        };
        if !scalar.width.is_power_of_two() {
            return Err(Unavailable::UnsupportedScalar);
        }
        return Ok(PhysicalType { scalar: PhysicalScalar { base, byte_width: scalar.width }, element_shape, arrays });
    }
}

fn member_layout(module: &naga::Module, member: &naga::StructMember) -> Observation<MemberLayout> {
    let ty = match physical_type(module, member.ty) {
        Ok(ty) => ty,
        Err(reason) => return Observation::Unavailable(reason),
    };
    // Only supported, creation-fixed types reach this call: Naga's dynamic-array minimum
    // size or unresolved-override zero must not masquerade as an observed physical span.
    match module.types[member.ty].inner.try_size(module.to_ctx()) {
        Some(byte_span) => Observation::Available(MemberLayout { byte_span, ty }),
        None => Observation::Unavailable(Unavailable::LayoutSizeUnavailable),
    }
}

fn block_layout(module: &naga::Module, var: &naga::GlobalVariable, budget: &mut Budget) -> Result<Observation<BlockLayout>, Unavailable> {
    if var.binding.is_none() {
        return Ok(Observation::Unavailable(Unavailable::MissingResourceBinding));
    }
    let TypeInner::Struct { members, span } = &module.types[var.ty].inner else {
        return Ok(Observation::Unavailable(Unavailable::BlockNotStruct));
    };
    if members.len() > MAX_MEMBERS - budget.members {
        return Err(Unavailable::ObservationLimit);
    }
    budget.members += members.len();
    let mut retained = Vec::with_capacity(members.len());
    for (member_index, member) in members.iter().enumerate() {
        retained.push(UniformMember {
            member_index,
            name: member.name.as_deref().map(|name| budget.name(name)).transpose()?,
            offset: member.offset,
            layout: member_layout(module, member),
        });
    }
    Ok(Observation::Available(BlockLayout { byte_span: *span, members: retained }))
}

fn retain_blocks(
    translated: &crate::backend::TranslatedModule,
    entry: usize,
    budget: &mut Budget,
) -> Result<Vec<UniformBlock>, Unavailable> {
    let module = &translated.module;
    let mut blocks = Vec::new();
    for (handle, var, class) in active_resources(module, &translated.info, entry) {
        if class != ResourceClass::UniformBuffer {
            continue;
        }
        if blocks.len() == MAX_BLOCKS {
            return Err(Unavailable::ObservationLimit);
        }
        // Same fallback as nagair::resource_name, borrowing before the bounded owned copy.
        let name = var.name.as_deref().or(module.types[var.ty].name.as_deref()).unwrap_or("");
        blocks.push(UniformBlock {
            global_index: handle.index(),
            name: budget.name(name)?,
            set: var.binding.as_ref().map(|binding| binding.group),
            binding: var.binding.as_ref().map(|binding| binding.binding),
            layout: block_layout(module, var, budget)?,
        });
    }
    Ok(blocks)
}

/// Called once, inside the original stage compilation, before `CompiledStage.translated`
/// is dropped. Never parses source, invokes a compiler, validates again or reads defaults.
/// Sharing the reflector's entry/resource helpers keeps its existing usage policy intact.
pub(crate) fn retain(stage: StageKind, compiled: &CompiledStage) -> StageUniformLayout {
    let mut retained = StageUniformLayout {
        stage,
        source_entry_point: None,
        msl_entry_point: None,
        blocks: Observation::Unavailable(Unavailable::TranslatedModuleAbsent),
    };
    let mut budget = Budget::default();
    let result = (|| {
        retained.msl_entry_point = Some(budget.name(&compiled.payload.entry_point)?);
        let translated = compiled.translated.as_ref().ok_or(Unavailable::TranslatedModuleAbsent)?;
        let entry = selected_entry(stage, &translated.module).ok_or(Unavailable::EntryPointAbsent)?;
        retained.source_entry_point = Some(budget.name(&translated.module.entry_points[entry].name)?);
        retain_blocks(translated, entry, &mut budget)
    })();
    retained.blocks = match result {
        Ok(blocks) => Observation::Available(blocks),
        Err(reason) => Observation::Unavailable(reason),
    };
    retained
}

/// Extend only the existing program reflection document. Ordinary reflection serialization,
/// merge rules and authored component restoration are untouched. The FFI continues to own
/// the resulting CString and expose it through its existing reflection_json accessor.
pub fn reflection_json(program: &CompiledProgram) -> String {
    let diagnostic = json::object(&[
        ("schema_version", SCHEMA_VERSION.to_string()),
        ("origin", json::string("original-translated-naga-module")),
        ("stages", json::array(program.stages.iter().map(|stage| stage.uniform_layout.to_json()))),
    ]);
    let mut document = program.reflection.to_json();
    // Reflection::to_json always emits an object. Reuse its bytes instead of maintaining a
    // second implementation of the ordinary reflection schema.
    document.pop();
    document.push_str(",\"observer_uniform_layout\":");
    document.push_str(&diagnostic);
    document.push('}');
    document
}

#[cfg(test)]
mod tests;
