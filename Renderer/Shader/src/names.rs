// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! Names that the engine matches by value (spec 2.7), and the rules for what
//! counts as a usable name (R31, R51, R104).

/// The generated uniform block, in reflection, bindings and the MSL record.
pub const GLOBAL_UNIFORMS: &str = "GlobalUniforms";
/// Prefix of the sampler that is paired with a texture.
pub const SAMPLER_PREFIX: &str = "_we_Sampler_";
/// Prefix of a material texture slot name.
pub const TEXTURE_PREFIX: &str = "g_Texture";
/// Prefix of the generated chroma plane of a video slot.
pub const VIDEO_CHROMA_PREFIX: &str = "_we_VideoChroma";
/// Highest material texture slot the layer accepts (R13, R36).
pub const MAX_TEXTURE_SLOT: u32 = 31;

/// `g_Texture<n>`.
pub fn texture_name(slot: u32) -> String {
    format!("{TEXTURE_PREFIX}{slot}")
}

/// The sampler that pairs with `texture`: `_we_Sampler_` plus the texture's name.
pub fn sampler_name(texture: &str) -> String {
    format!("{SAMPLER_PREFIX}{texture}")
}

/// `_we_VideoChroma<n>`.
pub fn video_chroma_name(slot: u32) -> String {
    format!("{VIDEO_CHROMA_PREFIX}{slot}")
}

/// `_we_VideoRange<n>` (vec4).
pub fn video_range_member(slot: u32) -> String {
    format!("_we_VideoRange{slot}")
}

/// `_we_VideoMatrix<n>` (vec4).
pub fn video_matrix_member(slot: u32) -> String {
    format!("_we_VideoMatrix{slot}")
}

/// `_we_VideoUvTransform<n>` (vec4).
pub fn video_uv_transform_member(slot: u32) -> String {
    format!("_we_VideoUvTransform{slot}")
}

/// `_we_VideoUvOffset<n>` (vec2).
pub fn video_uv_offset_member(slot: u32) -> String {
    format!("_we_VideoUvOffset{slot}")
}

/// How a resource name reads as a material texture slot.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SlotName {
    /// `g_Texture` followed by canonical decimal digits. The number saturates
    /// at `u32::MAX` for absurdly long digit strings.
    Canonical(u32),
    /// `g_Texture` followed by digits with a leading zero (`g_Texture007`).
    NonCanonical,
    /// Anything else, including `g_Texture1x` and a bare `g_Texture`.
    NotASlot,
}

/// Classifies `name` by its text alone (R31, R51): never by binding index.
pub fn classify_slot_name(name: &str) -> SlotName {
    let Some(digits) = name.strip_prefix(TEXTURE_PREFIX) else {
        return SlotName::NotASlot;
    };
    if digits.is_empty() || !digits.bytes().all(|b| b.is_ascii_digit()) {
        return SlotName::NotASlot;
    }
    if digits.len() > 1 && digits.starts_with('0') {
        return SlotName::NonCanonical;
    }
    SlotName::Canonical(digits.parse::<u32>().unwrap_or(u32::MAX))
}

/// An ASCII identifier: a letter or underscore, then letters, digits, underscores.
pub fn is_identifier(s: &str) -> bool {
    let mut bytes = s.bytes();
    match bytes.next() {
        Some(b) if b.is_ascii_alphabetic() || b == b'_' => {}
        _ => return false,
    }
    bytes.all(|b| b.is_ascii_alphanumeric() || b == b'_')
}

/// A name the response documents may carry (R104): an ASCII identifier, or
/// dot-separated segments that are each one.
pub fn is_valid_resource_name(name: &str) -> bool {
    !name.is_empty() && name.split('.').all(is_identifier)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn generated_names_follow_the_vocabulary() {
        assert_eq!(texture_name(3), "g_Texture3");
        assert_eq!(sampler_name("g_Texture3"), "_we_Sampler_g_Texture3");
        assert_eq!(video_chroma_name(2), "_we_VideoChroma2");
        assert_eq!(sampler_name(&video_chroma_name(2)), "_we_Sampler__we_VideoChroma2");
        assert_eq!(video_range_member(2), "_we_VideoRange2");
        assert_eq!(video_matrix_member(2), "_we_VideoMatrix2");
        assert_eq!(video_uv_transform_member(2), "_we_VideoUvTransform2");
        assert_eq!(video_uv_offset_member(2), "_we_VideoUvOffset2");
    }

    #[test]
    fn slot_names_are_classified_by_text() {
        assert_eq!(classify_slot_name("g_Texture0"), SlotName::Canonical(0));
        assert_eq!(classify_slot_name("g_Texture12"), SlotName::Canonical(12));
        assert_eq!(classify_slot_name("g_Texture40"), SlotName::Canonical(40));
        assert_eq!(classify_slot_name("g_Texture007"), SlotName::NonCanonical);
        assert_eq!(classify_slot_name("g_Texture00"), SlotName::NonCanonical);
        assert_eq!(classify_slot_name("g_Texture1x"), SlotName::NotASlot);
        assert_eq!(classify_slot_name("g_Texture"), SlotName::NotASlot);
        assert_eq!(classify_slot_name("u_Overlay"), SlotName::NotASlot);
        assert_eq!(classify_slot_name("g_Texture0Resolution"), SlotName::NotASlot);
        assert_eq!(classify_slot_name("_we_VideoChroma0"), SlotName::NotASlot);
        assert_eq!(classify_slot_name("g_Texture-1"), SlotName::NotASlot);
        assert_eq!(classify_slot_name("g_Texture99999999999999999999"), SlotName::Canonical(u32::MAX));
    }

    #[test]
    fn identifiers_and_resource_names() {
        for ok in ["a", "_a", "A1_b", "GlobalUniforms", "a.b", "a.b_c.d"] {
            assert!(is_valid_resource_name(ok), "{ok}");
        }
        for bad in ["", "1a", "a-b", "a b", "é", ".a", "a.", "a..b", "a.1b", "a\0"] {
            assert!(!is_valid_resource_name(bad), "{bad:?}");
        }
        assert!(is_identifier("TRANSFORMUV"));
        assert!(!is_identifier("a.b"));
        assert!(!is_identifier(""));
    }
}
