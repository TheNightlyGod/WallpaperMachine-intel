// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! Metadata extraction from annotations (R62 to R75).
//!
//! The walk goes over the items of one stage's text in order and stops at the
//! first `void main` function. A `[COMBO]` comment declares a combo; a JSON
//! comment on the same line as a `uniform` declaration annotates it (alias,
//! default value, default texture, switch combos). Conditionals are not
//! evaluated: annotations in every branch before `main` count.

use crate::annotation::{AnnotationJson, AnnotationKind, Default, annotation_kind, convert_default_text};
use crate::items::{DeclarationItem, Item, ItemKind, Qualifier};
use crate::names::{MAX_TEXTURE_SLOT, TEXTURE_PREFIX, is_identifier};
use crate::request::{RequestError, TextureRecord};
use crate::response::{AliasEntry, ComboEntry, DefaultTexture, DefaultUniform, Metadata, UniformValue};

/// What the walk collects.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ExtractMode {
    /// Everything of R62 to R69.
    Full,
    /// The texture-switch scan of R70: combo annotations are ignored and a JSON
    /// annotation is used only on a texture-slot uniform.
    TextureSwitchOnly,
}

/// R2 for a combo name read from an annotation.
fn check_combo_name(name: &str) -> Result<(), RequestError> {
    if name.is_empty() {
        Err(RequestError::EmptyComboName)
    } else if !is_identifier(name) {
        Err(RequestError::InvalidComboName(name.to_string()))
    } else {
        Ok(())
    }
}

/// R71: a later combo with the same name (ignoring ASCII case) replaces the earlier entry in place.
pub fn merge_combo(list: &mut Vec<ComboEntry>, name: &str, value: &str) {
    match list.iter_mut().find(|c| c.name.eq_ignore_ascii_case(name)) {
        Some(existing) => {
            existing.name = name.to_string();
            existing.value = value.to_string();
        }
        None => list.push(ComboEntry { name: name.to_string(), value: value.to_string() }),
    }
}

/// R65: `g_Texture` followed by decimal digits that fit in 8 bits. Above 31 is an error.
fn texture_slot(name: &str) -> Result<Option<u8>, RequestError> {
    let Some(digits) = name.strip_prefix(TEXTURE_PREFIX) else { return Ok(None) };
    if digits.is_empty() || !digits.bytes().all(|b| b.is_ascii_digit()) {
        return Ok(None);
    }
    let Ok(slot) = digits.parse::<u8>() else { return Ok(None) };
    if u32::from(slot) > MAX_TEXTURE_SLOT {
        return Err(RequestError::TextureSlotOutOfRange(slot));
    }
    Ok(Some(slot))
}

/// Extracts the metadata of one stage from its items.
pub fn extract(
    items: &[Item],
    text: &str,
    textures: &[TextureRecord],
    mode: ExtractMode,
) -> Result<Metadata, RequestError> {
    let mut out = Metadata::default();
    let mut awaiting: Option<&Item> = None;
    for item in items {
        match &item.kind {
            ItemKind::Annotation { text: annotation } => match annotation_kind(annotation) {
                AnnotationKind::Combo => {
                    if mode == ExtractMode::Full {
                        combo_annotation(annotation, &mut out)?;
                    }
                }
                AnnotationKind::Json => {
                    let declaration = awaiting.take();
                    if let Some(decl) = declaration
                        && !text[decl.span.end..item.span.start].contains(['\n', '\r'])
                        && let ItemKind::Declaration(d) = &decl.kind
                    {
                        uniform_annotation(annotation, d, textures, mode, &mut out)?;
                    }
                }
                AnnotationKind::Bracket => {}
            },
            ItemKind::Declaration(_) | ItemKind::Struct { .. } => awaiting = Some(item),
            ItemKind::Function(f) => {
                if f.return_type == "void" && f.name == "main" {
                    break;
                }
                awaiting = None;
            }
            ItemKind::Directive(_) | ItemKind::Opaque => awaiting = None,
        }
    }
    Ok(out)
}

/// R63.
fn combo_annotation(annotation: &str, out: &mut Metadata) -> Result<(), RequestError> {
    let Some(json) = AnnotationJson::parse(annotation) else { return Ok(()) };
    let default = json.default()?;
    let Some(name) = json.string("combo") else { return Ok(()) };
    check_combo_name(name)?;
    let value = match default {
        Default::Number { text, .. } => text,
        _ => "0",
    };
    merge_combo(&mut out.combos, name, value);
    Ok(())
}

/// R64 to R69.
fn uniform_annotation(
    annotation: &str,
    decl: &DeclarationItem,
    textures: &[TextureRecord],
    mode: ExtractMode,
    out: &mut Metadata,
) -> Result<(), RequestError> {
    let (Some(Qualifier::Uniform), Some(name)) = (decl.qualifier, decl.name.as_deref()) else { return Ok(()) };
    let slot = texture_slot(name)?;
    if mode == ExtractMode::TextureSwitchOnly && slot.is_none() {
        return Ok(());
    }
    let Some(json) = AnnotationJson::parse(annotation) else { return Ok(()) };
    let default = json.default()?;
    if let Some(material) = json.string("material") {
        if material.is_empty() {
            return Err(RequestError::Metadata("material alias is empty".to_string()));
        }
        // A NUL byte cannot be part of a reported name (R10); such an alias is dropped.
        if !material.contains('\0') {
            out.aliases.push(AliasEntry {
                material: material.to_string(), uniform: name.to_string(),
                rad2deg: json.string("conversion") == Some("rad2deg"),
            });
        }
    }
    match slot {
        Some(slot) => texture_annotation(&json, default, slot, textures, out),
        None => {
            let value = match default {
                Default::Text(s) => Some(convert_default_text(s)?),
                Default::Number { value, .. } => Some(UniformValue::Number(value)),
                Default::Bool(b) => Some(UniformValue::Bool(b)),
                Default::Absent | Default::Other => None,
            };
            if let Some(value) = value {
                out.default_uniforms.push(DefaultUniform { name: name.to_string(), value });
            }
            // R69: a combo key on a plain uniform records that combo as 1.
            if let Some(combo) = json.string("combo") {
                check_combo_name(combo)?;
                merge_combo(&mut out.combos, combo, "1");
            }
            Ok(())
        }
    }
}

/// R66 and R67.
fn texture_annotation(
    json: &AnnotationJson<'_>,
    default: Default<'_>,
    slot: u8,
    textures: &[TextureRecord],
    out: &mut Metadata,
) -> Result<(), RequestError> {
    if let Default::Text(path) = default
        && !path.is_empty()
        && !path.contains('\0')
    {
        out.default_textures.push(DefaultTexture { slot, path: path.to_string() });
    }
    let fact = textures.iter().find(|t| t.slot == slot && t.present);
    if let Some(combo) = json.string("combo") {
        check_combo_name(combo)?;
        merge_combo(&mut out.combos, combo, if fact.is_some() { "1" } else { "0" });
    }
    if let Some(fact) = fact
        && fact.enabled
    {
        let flags = [fact.components.compo1, fact.components.compo2, fact.components.compo3, fact.components.compo4];
        for (combo, on) in json.components().into_iter().zip(flags) {
            if let (Some(combo), true) = (combo, on) {
                check_combo_name(combo)?;
                merge_combo(&mut out.combos, combo, "1");
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests;
