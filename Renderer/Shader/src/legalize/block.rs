// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! The uniform block (spec C2, 4.4): one program-wide `GlobalUniforms` block holding every
//! non-sampler uniform of both stages, its member types, widening of narrow arrays and the
//! stage-local views of members that the stages declare with different widths.

use crate::request::StageKind;
use crate::uniforms::{Scalar, UniformError, UniformType};

use super::collect::StageDecls;
use super::error::LegalizeError;

/// One member of the generated block, as the layout and reflection parts need it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct BlockMemberPlan {
    pub name: String,
    /// The type of one value as the author means it (the wider type when the stages differ).
    pub ty: UniformType,
    pub array: Option<u32>,
    /// The type as the block declares it: narrow array elements are widened to four
    /// components (R20, R87), two-row matrices to four rows and booleans are stored as
    /// unsigned integers.
    pub declared_type: String,
    /// One of the generated video-plane constants (4.8).
    pub video: bool,
}

/// How a read of a member is restored to the author's type once the block stores it
/// differently.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(crate) struct ReadInfo {
    pub array: Option<u32>,
    /// Component selector appended to an element read (`x`, `xy`, `xyz`).
    pub select: Option<&'static str>,
    /// The element is a scalar: a second subscript selects the one component (R21).
    pub scalar_element: bool,
    /// The author's element type, for a read of the whole array.
    pub author_element: String,
    /// A boolean stored as unsigned integers: the number of components (1 for a scalar).
    pub as_bool: Option<u8>,
    /// A matrix with two rows stored with four (std140 gives its columns 16 bytes, and the
    /// compiler's own two-row matrix has 8): the author's matrix type, which a read restores
    /// by taking the upper-left submatrix of the stored one.
    pub narrow_matrix: Option<String>,
}

#[derive(Clone, Debug)]
pub(crate) struct Member {
    pub plan: BlockMemberPlan,
    pub read: ReadInfo,
    /// The type each stage declares, by stage (vertex, fragment).
    pub stage_ty: [Option<UniformType>; 2],
}

pub(crate) fn stage_index(kind: StageKind) -> usize {
    match kind {
        StageKind::Vertex => 0,
        StageKind::Fragment => 1,
    }
}

fn describe(ty: UniformType, array: Option<u32>) -> String {
    match array {
        Some(n) => format!("{}[{n}]", ty.glsl_name()),
        None => ty.glsl_name(),
    }
}

fn select_for(width: u8) -> &'static str {
    match width {
        1 => "x",
        2 => "xy",
        _ => "xyz",
    }
}

/// The declared type and read restoration of one member (R20, R83, R87, R99). A two-row matrix
/// is declared with four rows and read back through the constructor of the author's type.
fn declare(name: &str, ty: UniformType, array: Option<u32>) -> Result<(String, ReadInfo), LegalizeError> {
    let plain = || (ty.glsl_name(), ReadInfo { array, ..ReadInfo::default() });
    match (ty, array) {
        (UniformType::Scalar(Scalar::Bool) | UniformType::Vector(Scalar::Bool, _), Some(_)) => Err(LegalizeError::request(format!(
            "GlobalUniforms member `{name}` is an array of `{}`: boolean arrays cannot be laid out (declare integers)",
            ty.glsl_name()
        ))),
        (UniformType::Matrix { columns, rows: 2 }, _) => Ok((
            format!("mat{columns}x4"),
            ReadInfo { array, author_element: ty.glsl_name(), narrow_matrix: Some(ty.glsl_name()), ..ReadInfo::default() },
        )),
        (UniformType::Scalar(Scalar::Bool), None) => {
            Ok(("uint".to_string(), ReadInfo { as_bool: Some(1), ..ReadInfo::default() }))
        }
        (UniformType::Vector(Scalar::Bool, n), None) => {
            Ok((format!("uvec{n}"), ReadInfo { as_bool: Some(n), ..ReadInfo::default() }))
        }
        (UniformType::Scalar(s), Some(_)) | (UniformType::Vector(s, 2 | 3), Some(_)) => {
            let width = match ty {
                UniformType::Vector(_, n) => n,
                _ => 1,
            };
            let declared = match s {
                Scalar::Float => "vec4",
                Scalar::Int => "ivec4",
                _ => "uvec4",
            };
            Ok((
                declared.to_string(),
                ReadInfo {
                    array,
                    select: Some(select_for(width)),
                    scalar_element: width == 1,
                    author_element: ty.glsl_name(),
                    as_bool: None,
                    narrow_matrix: None,
                },
            ))
        }
        _ => Ok(plain()),
    }
}

fn member(name: &str, ty: UniformType, array: Option<u32>, video: bool) -> Result<Member, LegalizeError> {
    let (declared_type, read) = declare(name, ty, array)?;
    Ok(Member {
        plan: BlockMemberPlan { name: name.to_string(), ty, array, declared_type, video },
        read,
        stage_ty: [None, None],
    })
}

/// The program's block members (R14 to R21): the uniforms of the vertex stage, then those of
/// the fragment stage not yet present, then the generated `extra` members.
pub(crate) fn plan_block(
    vertex: Option<&StageDecls>,
    fragment: Option<&StageDecls>,
    extra: &[(String, UniformType)],
) -> Result<Vec<Member>, LegalizeError> {
    let mut members: Vec<Member> = Vec::new();
    for stage in [vertex, fragment].into_iter().flatten() {
        let si = stage_index(stage.kind);
        for u in &stage.uniforms {
            let ty = UniformType::parse(&u.ty)
                .ok_or_else(|| LegalizeError::Uniform(UniformError::UnsupportedType { ty: u.ty.clone() }))?;
            let array = match &u.bound {
                super::collect::Bound::None => None,
                super::collect::Bound::Count(n) => Some(*n),
                super::collect::Bound::Bad(text) => {
                    return Err(LegalizeError::Uniform(UniformError::UnresolvedArraySuffix {
                        suffix: format!("[{text}]"),
                        member: u.name.clone(),
                        stage: stage.kind,
                    }));
                }
            };
            match members.iter_mut().find(|m| m.plan.name == u.name) {
                None => {
                    let mut m = member(&u.name, ty, array, false)?;
                    m.stage_ty[si] = Some(ty);
                    members.push(m);
                }
                Some(m) => {
                    let (cur_ty, cur_array) = (m.plan.ty, m.plan.array);
                    if m.stage_ty[si].is_some() {
                        if (cur_ty, cur_array) != (ty, array) && m.stage_ty[si] != Some(ty) {
                            return Err(conflict(&u.name, cur_ty, cur_array, ty, array));
                        }
                        continue;
                    }
                    if (cur_ty, cur_array) == (ty, array) {
                        m.stage_ty[si] = Some(ty);
                        continue;
                    }
                    let lenient = array.is_none()
                        && cur_array.is_none()
                        && !u.name.starts_with("g_")
                        && cur_ty.float_width().is_some()
                        && ty.float_width().is_some();
                    if !lenient {
                        return Err(conflict(&u.name, cur_ty, cur_array, ty, array));
                    }
                    if ty.float_width() > cur_ty.float_width() {
                        let mut wider = member(&u.name, ty, None, false)?;
                        wider.stage_ty = m.stage_ty;
                        wider.stage_ty[si] = Some(ty);
                        *m = wider;
                    } else {
                        m.stage_ty[si] = Some(ty);
                    }
                }
            }
        }
    }
    for (name, ty) in extra {
        if members.iter().any(|m| &m.plan.name == name) {
            continue;
        }
        let mut m = member(name, *ty, None, true)?;
        m.stage_ty = [Some(*ty), Some(*ty)];
        members.push(m);
    }
    Ok(members)
}

fn conflict(name: &str, a: UniformType, aa: Option<u32>, b: UniformType, ba: Option<u32>) -> LegalizeError {
    LegalizeError::Uniform(UniformError::ConflictingDeclarations {
        name: name.to_string(),
        first: describe(a, aa),
        second: describe(b, ba),
    })
}

/// The component selector a stage reads a member through when the stage declares it narrower
/// than the block does (R19).
pub(crate) fn own_view(member: &Member, kind: StageKind) -> Option<&'static str> {
    let own = member.stage_ty[stage_index(kind)]?;
    let (own_w, block_w) = (own.float_width()?, member.plan.ty.float_width()?);
    (member.plan.array.is_none() && own_w < block_w).then(|| select_for(own_w))
}

/// The text of the block declaration (R6).
pub(crate) fn block_declaration(members: &[Member], binding: u32) -> String {
    let mut out = format!("layout(std140, set = 0, binding = {binding}) uniform {} {{\n", crate::names::GLOBAL_UNIFORMS);
    for m in members {
        let suffix = m.plan.array.map(|n| format!("[{n}]")).unwrap_or_default();
        out.push_str(&format!("    {} {}{suffix};\n", m.plan.declared_type, m.plan.name));
    }
    out.push_str("};\n");
    out
}
