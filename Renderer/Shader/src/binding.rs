// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! The per-stage Metal binding map (spec 2.6.1, R31 to R40, R104): one record
//! per shader resource, naming the resource by its original shader-visible
//! name and the Metal argument-table slot it was given.

use std::fmt;

use crate::json;
use crate::names::{SlotName, classify_slot_name, is_valid_resource_name};
use crate::text::{quote, sanitize};

/// Which Metal argument-table namespace a slot is in.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SlotKind {
    Buffer,
    Texture,
    Sampler,
}

impl SlotKind {
    pub fn name(self) -> &'static str {
        match self {
            SlotKind::Buffer => "buffer",
            SlotKind::Texture => "texture",
            SlotKind::Sampler => "sampler",
        }
    }

    /// The highest slot of this namespace the layer hands out (R35). The limit applies to the dense
    /// slot of d R46, not to the binding. The block is buffer slot 0 whenever it is the stage's only
    /// buffer (every generated program), so it cannot meet the host's vertex streams.
    pub fn max_slot(self) -> u32 {
        match self {
            SlotKind::Buffer => 30,
            SlotKind::Texture => 127,
            SlotKind::Sampler => 15,
        }
    }
}

/// One resource of one stage.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Binding {
    /// The original shader-visible name (`GlobalUniforms`, `g_Texture0`, `_we_Sampler_g_Texture0`).
    pub name: String,
    /// Always 0: Metal has no descriptor sets, the field is kept for the engine's reader (R96).
    pub set: u32,
    /// The resource index of the program's layout, the key reflection reports.
    pub binding: u32,
    pub slot_kind: SlotKind,
    /// The Metal argument-table index within its kind: the rank of `binding` among the stage's
    /// resources of the same kind (D R46, see [`assign_stage_slots`]). The host reads only this.
    pub slot: u32,
}

impl Binding {
    /// One object of the per-stage `bindings` array, keys in the order of spec 2.6.1.
    pub fn to_json(&self) -> String {
        json::object(&[
            ("name", json::string(&self.name)),
            ("set", self.set.to_string()),
            ("binding", self.binding.to_string()),
            ("slot_kind", json::string(self.slot_kind.name())),
            ("slot", self.slot.to_string()),
        ])
    }
}

/// A resource that cannot be given a Metal slot, or a name that cannot be used.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum BindingError {
    InvalidName { name: String },
    UnmappableSet { name: String, set: u32 },
    NoBinding { name: String },
    SlotLimit { kind: SlotKind, slot: u32, name: String },
    NonCanonicalTextureName { name: String },
    DuplicateTextureIndex { index: u32, first: String, second: String },
}

impl fmt::Display for BindingError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let text = match self {
            BindingError::InvalidName { name } => format!(
                "metal binding map cannot name a global resource: {} is not an ASCII identifier",
                quote(name)
            ),
            BindingError::UnmappableSet { name, set } => format!(
                "metal binding map cannot cover global {}: it uses descriptor set {set}",
                quote(name)
            ),
            BindingError::NoBinding { name } => format!(
                "metal binding map cannot cover global {}: it has no binding and no slot can be invented",
                quote(name)
            ),
            BindingError::SlotLimit { kind, slot, name } => format!(
                "metal binding map: resource {} needs {} slot {slot}, above the argument-table limit of {} for {} slots",
                quote(name),
                kind.name(),
                kind.max_slot(),
                kind.name()
            ),
            BindingError::NonCanonicalTextureName { name } => {
                format!("{} is not a canonical g_TextureN binding name", quote(name))
            }
            BindingError::DuplicateTextureIndex { index, first, second } => format!(
                "textures {} and {} both encode resource index {index}",
                quote(first),
                quote(second)
            ),
        };
        f.write_str(&sanitize(&text))
    }
}

impl std::error::Error for BindingError {}

/// R31: a name that starts with `g_Texture` and digits with a leading zero is
/// an error in whichever pass first sees it.
pub fn check_canonical_texture_name(name: &str) -> Result<(), BindingError> {
    match classify_slot_name(name) {
        SlotName::NonCanonical => Err(BindingError::NonCanonicalTextureName { name: name.to_string() }),
        _ => Ok(()),
    }
}

/// One resource global of one stage, as the translated module declares it (D R45).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct StageResource {
    pub name: String,
    pub set: u32,
    pub binding: Option<u32>,
    pub kind: SlotKind,
}

/// The Metal slots of the resources of one stage (D R45, R46).
///
/// `resources` are every resource global of the stage in declaration order, used or not. Each
/// record keeps the pipeline's `binding` and gets, as its `slot`, the rank of that binding
/// among the stage's resources of the same kind (ascending binding, ties in declaration
/// order), counted from 0 without gaps. The result is in the order of `resources`.
///
/// A name that is not a usable symbol, a set other than 0 and a missing binding are errors for
/// any resource; a rank above the limit of its namespace names the kind, the slot, the resource
/// and the limit.
pub fn assign_stage_slots(resources: &[StageResource]) -> Result<Vec<Binding>, BindingError> {
    let mut checked: Vec<(u32, &StageResource)> = Vec::with_capacity(resources.len());
    for r in resources {
        if !is_valid_resource_name(&r.name) {
            return Err(BindingError::InvalidName { name: r.name.clone() });
        }
        if r.set != 0 {
            return Err(BindingError::UnmappableSet { name: r.name.clone(), set: r.set });
        }
        let Some(binding) = r.binding else {
            return Err(BindingError::NoBinding { name: r.name.clone() });
        };
        checked.push((binding, r));
    }
    let mut out: Vec<Binding> = checked
        .iter()
        .map(|(binding, r)| Binding { name: r.name.clone(), set: 0, binding: *binding, slot_kind: r.kind, slot: 0 })
        .collect();
    for kind in [SlotKind::Buffer, SlotKind::Texture, SlotKind::Sampler] {
        let mut of_kind: Vec<usize> = (0..out.len()).filter(|&i| out[i].slot_kind == kind).collect();
        of_kind.sort_by_key(|&i| out[i].binding);
        for (rank, i) in of_kind.into_iter().enumerate() {
            let slot = rank as u32;
            if slot > kind.max_slot() {
                return Err(BindingError::SlotLimit { kind, slot, name: out[i].name.clone() });
            }
            out[i].slot = slot;
        }
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn res(name: &str, binding: u32, kind: SlotKind) -> StageResource {
        StageResource { name: name.to_string(), set: 0, binding: Some(binding), kind }
    }

    fn slots(list: &[StageResource]) -> Vec<(String, u32, u32)> {
        assign_stage_slots(list).unwrap().into_iter().map(|b| (b.name, b.binding, b.slot)).collect()
    }

    #[test]
    fn limits_are_per_namespace() {
        assert_eq!((SlotKind::Buffer.max_slot(), SlotKind::Texture.max_slot(), SlotKind::Sampler.max_slot()), (30, 127, 15));
    }

    #[test]
    fn slots_are_ranks_within_each_namespace_not_binding_indices() {
        let mut list = vec![res("GlobalUniforms", 0, SlotKind::Buffer)];
        for n in 0..10u32 {
            list.push(res(&format!("g_Texture{n}"), 1 + 2 * n, SlotKind::Texture));
            list.push(res(&format!("_we_Sampler_g_Texture{n}"), 2 + 2 * n, SlotKind::Sampler));
        }
        let map = assign_stage_slots(&list).unwrap();
        assert_eq!(map[0].slot, 0);
        let last_sampler = map.last().unwrap();
        assert_eq!((last_sampler.binding, last_sampler.slot), (20, 9));
        let texture_slots: Vec<u32> = map.iter().filter(|b| b.slot_kind == SlotKind::Texture).map(|b| b.slot).collect();
        assert_eq!(texture_slots, (0..10).collect::<Vec<_>>());
        assert_eq!(map.iter().map(|b| b.name.as_str()).collect::<Vec<_>>(), list.iter().map(|r| r.name.as_str()).collect::<Vec<_>>(), "declaration order is kept");
    }

    #[test]
    fn ranks_follow_ascending_binding_whatever_the_declaration_order() {
        let list = vec![res("b", 9, SlotKind::Texture), res("a", 2, SlotKind::Texture), res("c", 5, SlotKind::Texture)];
        assert_eq!(slots(&list), [("b".to_string(), 9, 2), ("a".to_string(), 2, 0), ("c".to_string(), 5, 1)]);
    }

    #[test]
    fn no_two_records_of_one_kind_share_a_slot() {
        let list = vec![res("a", 3, SlotKind::Buffer), res("b", 3, SlotKind::Texture), res("c", 3, SlotKind::Sampler), res("d", 4, SlotKind::Buffer)];
        let map = assign_stage_slots(&list).unwrap();
        let mut keys: Vec<(&str, u32)> = map.iter().map(|b| (b.slot_kind.name(), b.slot)).collect();
        keys.sort_unstable();
        keys.dedup();
        assert_eq!(keys.len(), 4);
    }

    #[test]
    fn the_boundary_counts_of_each_namespace() {
        let many = |n: u32, kind: SlotKind| -> Vec<StageResource> { (0..n).map(|i| res(&format!("r{i}"), i, kind)).collect() };
        assert!(assign_stage_slots(&many(31, SlotKind::Buffer)).is_ok());
        assert!(assign_stage_slots(&many(128, SlotKind::Texture)).is_ok());
        assert!(assign_stage_slots(&many(16, SlotKind::Sampler)).is_ok());
        for (kind, over, limit, slot) in [(SlotKind::Buffer, 32, 30, 31), (SlotKind::Texture, 129, 127, 128), (SlotKind::Sampler, 17, 15, 16)] {
            let text = assign_stage_slots(&many(over, kind)).unwrap_err().to_string();
            let name = format!("`r{slot}`");
            for needle in [kind.name().to_string(), format!("slot {slot}"), name, limit.to_string()] {
                assert!(text.contains(&needle), "{needle}: {text}");
            }
        }
    }

    #[test]
    fn a_namespace_does_not_use_up_another() {
        let mut list = many_of(16, SlotKind::Sampler);
        list.extend(many_of(128, SlotKind::Texture));
        list.extend(many_of(31, SlotKind::Buffer));
        assert!(assign_stage_slots(&list).is_ok());
    }

    fn many_of(n: u32, kind: SlotKind) -> Vec<StageResource> {
        (0..n).map(|i| res(&format!("{}{i}", kind.name()), i, kind)).collect()
    }

    #[test]
    fn only_set_zero_with_a_binding_can_be_mapped() {
        let mut r = res("g_Cube", 0, SlotKind::Texture);
        r.set = 1;
        let text = assign_stage_slots(&[r]).unwrap_err().to_string();
        assert!(text.contains("metal binding map cannot cover global `g_Cube`: it uses descriptor set 1"), "{text}");
        let mut r = res("g_Cube", 0, SlotKind::Texture);
        r.binding = None;
        let text = assign_stage_slots(&[r]).unwrap_err().to_string();
        assert!(text.contains("metal binding map cannot cover global `g_Cube`"), "{text}");
    }

    #[test]
    fn names_must_be_ascii_identifiers_even_when_unused() {
        for bad in ["", "1x", "a-b", "é", "a b"] {
            let text = assign_stage_slots(&[res(bad, 0, SlotKind::Texture)]).unwrap_err().to_string();
            assert!(text.contains("metal binding map cannot name a global resource"), "{text}");
        }
        assert!(assign_stage_slots(&[res("a.b", 0, SlotKind::Texture)]).is_ok());
    }

    #[test]
    fn json_has_the_required_keys_in_order() {
        let b = Binding { name: "GlobalUniforms".into(), set: 0, binding: 2, slot_kind: SlotKind::Buffer, slot: 0 };
        assert_eq!(b.to_json(), r#"{"name":"GlobalUniforms","set":0,"binding":2,"slot_kind":"buffer","slot":0}"#);
    }

    #[test]
    fn non_canonical_texture_names_are_rejected_by_name() {
        let text = check_canonical_texture_name("g_Texture007").unwrap_err().to_string();
        assert!(text.contains("not a canonical g_TextureN binding name") && text.contains("g_Texture007"), "{text}");
        for ok in ["g_Texture0", "g_Texture10", "g_Texture1x", "u_Overlay", "g_Texture"] {
            assert!(check_canonical_texture_name(ok).is_ok(), "{ok}");
        }
        let text = BindingError::DuplicateTextureIndex { index: 1, first: "a".into(), second: "b".into() }.to_string();
        assert!(text.contains("`a`") && text.contains("`b`") && text.contains('1'));
    }
}
