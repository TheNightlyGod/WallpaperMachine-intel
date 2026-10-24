// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! The JSON inside annotation comments (R56 to R61) and the conversion of
//! default text to typed values (R8).
//!
//! The reader is deliberately small and forgiving, not a JSON parser: it finds
//! the object, reads `"key": value` entries left to right, and stops silently at
//! the first entry it cannot read. Strings are never unescaped.

use crate::request::RequestError;
use crate::response::UniformValue;

/// What kind of comment an annotation is (R56).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AnnotationKind {
    /// `// [COMBO] {...}`
    Combo,
    /// `// {...}`
    Json,
    /// `// [COMBO_DISABLED]`, `// [PASS] ...`: ignored by metadata.
    Bracket,
}

/// R56: remove leading `/` characters and blanks, then look at the start.
pub fn annotation_kind(text: &str) -> AnnotationKind {
    let body = text.trim_start_matches(['/', ' ', '\t']);
    if body.starts_with("[COMBO]") {
        AnnotationKind::Combo
    } else if body.starts_with('{') {
        AnnotationKind::Json
    } else {
        AnnotationKind::Bracket
    }
}

/// The raw value of an entry.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Raw<'a> {
    /// The text between the quotes, not unescaped.
    Str(&'a str),
    /// `{...}` including the braces.
    Object(&'a str),
    /// `[...]` including the brackets.
    Array(&'a str),
    /// A number, `true`, `false`, `null` or bare text, trimmed.
    Bare(&'a str),
}

/// A `default` entry after validation (R60).
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Default<'a> {
    Absent,
    Text(&'a str),
    /// The numeric prefix as written, and its value.
    Number { text: &'a str, value: f32 },
    Bool(bool),
    /// `null`, an array, an object, other text.
    Other,
}

/// The entries of one annotation's object.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct AnnotationJson<'a> {
    entries: Vec<(&'a str, Raw<'a>)>,
}

/// The end (exclusive) of a string that starts at `start` (a `"`), or `None` when unterminated.
fn string_end(s: &str, start: usize) -> Option<usize> {
    let bytes = s.as_bytes();
    let mut i = start + 1;
    while i < bytes.len() {
        match bytes[i] {
            b'\\' => i += 2,
            b'"' => return Some(i + 1),
            _ => i += 1,
        }
    }
    None
}

/// The end (exclusive) of a bracketed value starting at `start`, skipping strings.
fn balanced_end(s: &str, start: usize, open: u8, close: u8) -> Option<usize> {
    let bytes = s.as_bytes();
    let mut depth = 0usize;
    let mut i = start;
    while i < bytes.len() {
        let b = bytes[i];
        if b == b'"' {
            i = string_end(s, i)?;
            continue;
        }
        if b == open {
            depth += 1;
        } else if b == close {
            depth -= 1;
            if depth == 0 {
                return Some(i + 1);
            }
        }
        i += 1;
    }
    None
}

/// R57: the object text from the first `{` to the end, when its braces balance exactly at the end.
pub fn locate_object(annotation: &str) -> Option<&str> {
    let object = annotation[annotation.find('{')?..].trim();
    if !object.ends_with('}') {
        return None;
    }
    let bytes = object.as_bytes();
    let mut depth = 0usize;
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b'"' => {
                i = string_end(object, i)?;
                continue;
            }
            b'{' => depth += 1,
            b'}' => {
                depth = depth.checked_sub(1)?;
                if depth == 0 && i + 1 != bytes.len() {
                    return None;
                }
            }
            _ => {}
        }
        i += 1;
    }
    (depth == 0).then_some(object)
}

fn read_entries(inner: &str) -> Vec<(&str, Raw<'_>)> {
    let bytes = inner.as_bytes();
    let mut entries: Vec<(&str, Raw<'_>)> = Vec::new();
    let mut i = 0;
    loop {
        while i < bytes.len() && (bytes[i] == b',' || bytes[i].is_ascii_whitespace()) {
            i += 1;
        }
        if i >= bytes.len() || bytes[i] != b'"' {
            break;
        }
        let Some(key_end) = string_end(inner, i) else { break };
        let key = &inner[i + 1..key_end - 1];
        i = key_end;
        while i < bytes.len() && bytes[i].is_ascii_whitespace() {
            i += 1;
        }
        if bytes.get(i) != Some(&b':') {
            break;
        }
        i += 1;
        while i < bytes.len() && bytes[i].is_ascii_whitespace() {
            i += 1;
        }
        if i >= bytes.len() {
            break;
        }
        let (raw, next) = match bytes[i] {
            b'"' => {
                let Some(end) = string_end(inner, i) else { break };
                (Raw::Str(&inner[i + 1..end - 1]), end)
            }
            b'{' => {
                let Some(end) = balanced_end(inner, i, b'{', b'}') else { break };
                (Raw::Object(&inner[i..end]), end)
            }
            b'[' => {
                let Some(end) = balanced_end(inner, i, b'[', b']') else { break };
                (Raw::Array(&inner[i..end]), end)
            }
            _ => {
                let end = inner[i..]
                    .find(',')
                    .or_else(|| inner[i..].find('}'))
                    .map_or(inner.len(), |p| i + p);
                (Raw::Bare(inner[i..end].trim()), end)
            }
        };
        // The first occurrence of a key wins.
        if !entries.iter().any(|(k, _)| *k == key) {
            entries.push((key, raw));
        }
        i = next;
    }
    entries
}

/// The longest prefix made of `0-9 + - . e E` (R60).
fn numeric_prefix(text: &str) -> &str {
    let end = text.bytes().position(|b| !matches!(b, b'0'..=b'9' | b'+' | b'-' | b'.' | b'e' | b'E')).unwrap_or(text.len());
    &text[..end]
}

pub fn invalid_number() -> RequestError {
    RequestError::Metadata("metadata number is invalid".to_string())
}

impl<'a> AnnotationJson<'a> {
    /// Locates the object in an annotation's text and reads its entries. `None` when the annotation is ignored (R57).
    pub fn parse(annotation: &'a str) -> Option<AnnotationJson<'a>> {
        let object = locate_object(annotation)?;
        Some(AnnotationJson { entries: read_entries(&object[1..object.len() - 1]) })
    }

    /// Reads the entries of an object value (`{...}`).
    pub fn parse_object(object: &'a str) -> Option<AnnotationJson<'a>> {
        let object = object.trim();
        (object.starts_with('{') && object.ends_with('}') && object.len() >= 2)
            .then(|| AnnotationJson { entries: read_entries(&object[1..object.len() - 1]) })
    }

    pub fn get(&self, key: &str) -> Option<Raw<'a>> {
        self.entries.iter().find(|(k, _)| *k == key).map(|(_, v)| *v)
    }

    /// The string value of `key` (R59); `None` when absent or not a string.
    pub fn string(&self, key: &str) -> Option<&'a str> {
        match self.get(key)? {
            Raw::Str(s) => Some(s),
            _ => None,
        }
    }

    /// The `default` entry (R60). A numeric prefix that does not parse as a 32-bit float is an error.
    pub fn default(&self) -> Result<Default<'a>, RequestError> {
        let Some(raw) = self.get("default") else { return Ok(Default::Absent) };
        let text = match raw {
            Raw::Str(s) => return Ok(Default::Text(s)),
            Raw::Object(_) | Raw::Array(_) => return Ok(Default::Other),
            Raw::Bare(text) => text,
        };
        let prefix = numeric_prefix(text);
        if !prefix.is_empty() {
            let value = prefix.parse::<f32>().map_err(|_| invalid_number())?;
            return Ok(Default::Number { text: prefix, value });
        }
        if text.starts_with("true") {
            Ok(Default::Bool(true))
        } else if text.starts_with("false") {
            Ok(Default::Bool(false))
        } else {
            Ok(Default::Other)
        }
    }

    /// The `components` array (R61): per colour component, the combo of its object, if any.
    pub fn components(&self) -> Vec<Option<&'a str>> {
        let Some(Raw::Array(array)) = self.get("components") else { return Vec::new() };
        let mut out = Vec::new();
        let mut rest = &array[1..];
        loop {
            rest = rest.trim_start_matches(|c: char| c == ',' || c.is_whitespace());
            if !rest.starts_with('{') {
                break;
            }
            let Some(end) = balanced_end(rest, 0, b'{', b'}') else { break };
            let object = &rest[..end];
            out.push(AnnotationJson::parse_object(object).and_then(|o| o.string("combo")));
            rest = &rest[end..];
        }
        out
    }
}

/// R8: converts the text of a metadata default into a typed value.
pub fn convert_default_text(text: &str) -> Result<UniformValue, RequestError> {
    let mut values: Vec<f32> = Vec::new();
    for piece in text.split(|c: char| c.is_ascii_whitespace() || c == ',') {
        if piece.is_empty() {
            continue;
        }
        values.push(piece.parse::<f32>().map_err(|_| invalid_number())?);
    }
    Ok(match values.len() {
        1 => UniformValue::Number(values[0]),
        2 => UniformValue::Vec2([values[0], values[1]]),
        3 => UniformValue::Vec3([values[0], values[1], values[2]]),
        4 => UniformValue::Vec4([values[0], values[1], values[2], values[3]]),
        16 => UniformValue::Matrix4(values.try_into().expect("sixteen values")),
        _ => UniformValue::Text(text.to_string()),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn json(text: &str) -> AnnotationJson<'_> {
        AnnotationJson::parse(text).unwrap_or_else(|| panic!("ignored: {text}"))
    }

    #[test]
    fn kinds_follow_the_text_after_the_slashes() {
        assert_eq!(annotation_kind("// [COMBO] {\"combo\":\"A\"}"), AnnotationKind::Combo);
        assert_eq!(annotation_kind("//[COMBO] {}"), AnnotationKind::Combo);
        assert_eq!(annotation_kind("///\t [COMBO]{}"), AnnotationKind::Combo);
        assert_eq!(annotation_kind("// {\"a\":1}"), AnnotationKind::Json);
        assert_eq!(annotation_kind("//{\"a\":1}"), AnnotationKind::Json);
        assert_eq!(annotation_kind("// [COMBO_DISABLED] {\"combo\":\"A\"}"), AnnotationKind::Bracket);
        assert_eq!(annotation_kind("// [PASS] shadow fx"), AnnotationKind::Bracket);
        assert_eq!(annotation_kind("// [Combo] {}"), AnnotationKind::Bracket);
    }

    #[test]
    fn the_object_must_close_exactly_at_the_end() {
        assert!(locate_object("// {\"a\":1}").is_some());
        assert!(locate_object("// [COMBO] LEVEL=2 high").is_none());
        assert!(locate_object("// {\"default\":1} note").is_none());
        assert!(locate_object("// {\"default\":1").is_none());
        assert!(locate_object("// {\"a\":\"x}\"}").is_some());
        assert!(locate_object("// {\"a\":\"x}\"").is_none());
        // A string with a missing closing quote unbalances the object.
        assert!(locate_object("// {\"a\":\"open, \"b\":1}").is_none());
        assert!(locate_object("// {\"a\":{\"b\":1}}").is_some());
        assert!(locate_object("// {\"a\":1}}").is_none());
        assert!(locate_object("// {\"a\":\"q\\\"}\"}").is_some());
        assert!(locate_object("// }").is_none());
        assert_eq!(locate_object("//  {\"a\":1}  "), Some("{\"a\":1}"));
    }

    #[test]
    fn entries_tolerate_commas_whitespace_and_stop_at_the_first_unreadable_one() {
        let j = json("// {\"a\":1, ,, \"b\" : \"two\" , \"c\":true,}");
        assert_eq!(j.get("a"), Some(Raw::Bare("1")));
        assert_eq!(j.string("b"), Some("two"));
        assert_eq!(j.get("c"), Some(Raw::Bare("true")));
        // An entry without a colon stops the reading: later entries are invisible.
        let j = json("// {\"a\":1,\"broken\" 2,\"b\":3}");
        assert!(j.get("a").is_some() && j.get("b").is_none() && j.get("broken").is_none());
        let j = json("// {\"a\":1, junk, \"b\":2}");
        assert!(j.get("b").is_none());
        // An unterminated string makes the whole annotation ignored.
        assert!(AnnotationJson::parse("// {\"a\":1,\"unterminated:2}").is_none());
    }

    #[test]
    fn nested_structures_are_skipped_whole() {
        let j = json("// {\"range\":[0.0, 2.0], \"options\":{\"a\":1,\"b\":2}, \"x\":\"y\", \"label\":\"a,b\"}");
        assert_eq!(j.get("range"), Some(Raw::Array("[0.0, 2.0]")));
        assert_eq!(j.get("options"), Some(Raw::Object("{\"a\":1,\"b\":2}")));
        assert_eq!(j.string("x"), Some("y"));
        assert_eq!(j.string("label"), Some("a,b"));
        let j = json("// {\"arr\":[\"]\", 1], \"next\":2}");
        assert_eq!(j.get("arr"), Some(Raw::Array("[\"]\", 1]")));
        assert_eq!(j.get("next"), Some(Raw::Bare("2")));
    }

    #[test]
    fn duplicate_keys_first_wins_and_keys_are_case_sensitive() {
        let j = json("// {\"default\":1,\"default\":2,\"Default\":3}");
        assert_eq!(j.get("default"), Some(Raw::Bare("1")));
        assert_eq!(j.get("Default"), Some(Raw::Bare("3")));
        assert_eq!(j.get("DEFAULT"), None);
    }

    #[test]
    fn strings_are_not_unescaped() {
        let j = json("// {\"label\":\"a\\\"b\\n\"}");
        assert_eq!(j.string("label"), Some("a\\\"b\\n"));
        // A key with escapes is compared on its raw text.
        let j = json("// {\"a\\\"b\":1}");
        assert!(j.get("a\\\"b").is_some());
    }

    #[test]
    fn a_non_string_value_has_no_string() {
        let j = json("// {\"material\":5,\"combo\":null}");
        assert_eq!(j.string("material"), None);
        assert_eq!(j.string("combo"), None);
    }

    #[test]
    fn bare_values_end_at_the_next_comma_or_closing_brace() {
        let j = json("// {\"a\":1.5e3 , \"b\":  -4}");
        assert_eq!(j.get("a"), Some(Raw::Bare("1.5e3")));
        assert_eq!(j.get("b"), Some(Raw::Bare("-4")));
    }

    #[test]
    fn default_values() {
        fn d(t: &str) -> Result<Default<'_>, RequestError> {
            json(t).default()
        }
        assert_eq!(d("// {\"x\":1}"), Ok(Default::Absent));
        assert_eq!(d("// {\"default\":\"1 1 1\"}"), Ok(Default::Text("1 1 1")));
        assert_eq!(d("// {\"default\":7}"), Ok(Default::Number { text: "7", value: 7.0 }));
        assert_eq!(d("// {\"default\":0.50}"), Ok(Default::Number { text: "0.50", value: 0.5 }));
        assert_eq!(d("// {\"default\":-4}"), Ok(Default::Number { text: "-4", value: -4.0 }));
        assert_eq!(d("// {\"default\":1e3}"), Ok(Default::Number { text: "1e3", value: 1000.0 }));
        assert_eq!(d("// {\"default\":true}"), Ok(Default::Bool(true)));
        assert_eq!(d("// {\"default\":false}"), Ok(Default::Bool(false)));
        assert_eq!(d("// {\"default\":null}"), Ok(Default::Other));
        assert_eq!(d("// {\"default\":[1,2]}"), Ok(Default::Other));
        assert_eq!(d("// {\"default\":{\"a\":1}}"), Ok(Default::Other));
        for bad in ["1.2.3", "-", "+", "1e", "--1", "e", "1-2", "1e+"] {
            let err = d(&format!("// {{\"default\":{bad}}}")).unwrap_err();
            assert_eq!(err.to_string(), "invalid shader request: metadata number is invalid", "{bad}");
        }
        // The numeric prefix is what counts: trailing text is dropped.
        assert_eq!(d("// {\"default\":5x}"), Ok(Default::Number { text: "5", value: 5.0 }));
    }

    #[test]
    fn components_are_read_as_consecutive_objects() {
        fn c(t: &str) -> Vec<Option<&str>> {
            json(t).components()
        }
        assert_eq!(c("// {\"components\":[{\"combo\":\"METALLIC\"},{\"combo\":\"ROUGH\"}]}"), [Some("METALLIC"), Some("ROUGH")]);
        assert_eq!(c("// {\"components\":[{\"label\":\"x\"},{\"combo\":\"B\"}]}"), [None, Some("B")]);
        assert_eq!(c("// {\"components\":[{\"combo\":\"A\"}, 5, {\"combo\":\"B\"}]}"), [Some("A")]);
        assert_eq!(c("// {\"components\":[ , {\"combo\":\"A\"},, {\"combo\":\"B\", \"x\":[1,2]}]}"), [Some("A"), Some("B")]);
        assert_eq!(c("// {\"components\":\"no\"}"), Vec::<Option<&str>>::new());
        assert_eq!(c("// {\"components\":[]}"), Vec::<Option<&str>>::new());
        assert_eq!(c("// {\"x\":1}"), Vec::<Option<&str>>::new());
    }

    #[test]
    fn default_text_conversion() {
        let n = |t: &str| convert_default_text(t);
        assert_eq!(n("6"), Ok(UniformValue::Number(6.0)));
        assert_eq!(n("6 5"), Ok(UniformValue::Vec2([6.0, 5.0])));
        assert_eq!(n("0.5 0.25"), Ok(UniformValue::Vec2([0.5, 0.25])));
        assert_eq!(n("4, 5, 6"), Ok(UniformValue::Vec3([4.0, 5.0, 6.0])));
        assert_eq!(n("7, 8, 9"), Ok(UniformValue::Vec3([7.0, 8.0, 9.0])));
        assert_eq!(n("1 2 3 4"), Ok(UniformValue::Vec4([1.0, 2.0, 3.0, 4.0])));
        let sixteen = (1..=16).map(|i| i.to_string()).collect::<Vec<_>>().join(" ");
        let UniformValue::Matrix4(m) = n(&sixteen).unwrap() else { panic!() };
        assert_eq!(m[0], 1.0);
        assert_eq!(m[15], 16.0);
        assert_eq!(n("9 8 7 6 5"), Ok(UniformValue::Text("9 8 7 6 5".into())));
        assert_eq!(n("1 2 3 4 5 6"), Ok(UniformValue::Text("1 2 3 4 5 6".into())));
        assert_eq!(n(""), Ok(UniformValue::Text(String::new())));
        assert_eq!(n("   "), Ok(UniformValue::Text("   ".into())));
        assert_eq!(n("util/white").unwrap_err().to_string(), "invalid shader request: metadata number is invalid");
        assert!(n("3 y").is_err());
        assert_eq!(n("+1.5 .5 5. 1e3"), Ok(UniformValue::Vec4([1.5, 0.5, 5.0, 1000.0])));
        assert_eq!(n(" 1,,2 "), Ok(UniformValue::Vec2([1.0, 2.0])));
        assert!(matches!(n("inf"), Ok(UniformValue::Number(v)) if v.is_infinite()));
        assert!(matches!(n("nan"), Ok(UniformValue::Number(v)) if v.is_nan()));
    }
}
