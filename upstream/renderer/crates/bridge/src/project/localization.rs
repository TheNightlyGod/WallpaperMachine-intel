//! A project's own translated label table (`general.localization`).
//!
//! Wallpaper Engine lets an author keep every user-facing label of a
//! wallpaper as a short token such as `ui_speed` and ship the real text per
//! language beside it:
//!
//! ```json
//! "localization": {
//!     "en-us":  { "ui_speed": "Speed" },
//!     "zh-chs": { "ui_speed": "速度" }
//! }
//! ```
//!
//! The table comes from a downloaded project, so it is untrusted input: it is
//! bounded while it is read, and anything outside the bounds or the expected
//! shape is skipped without failing the project.

use std::collections::BTreeMap;

use serde_json::{Map, Value};

/// Most languages kept from one project.
pub const MAX_LOCALES: usize = 64;
/// Most tokens kept per language.
pub const MAX_KEYS_PER_LOCALE: usize = 4_096;
/// Longest token kept, in bytes.
pub const MAX_KEY_BYTES: usize = 128;
/// Longest translated text kept, in bytes. Longer text is not a label.
pub const MAX_VALUE_BYTES: usize = 2_048;
/// Most text kept across the whole table, tokens and values together.
pub const MAX_TOTAL_BYTES: usize = 1024 * 1024;

/// The language every label falls back to, and the one used until the host
/// names another.
pub const FALLBACK_LOCALE: &str = "en-us";
/// Most languages the host may name; English is added after them if absent.
pub const MAX_PREFERRED_LOCALES: usize = 4;

/// Longest and shortest accepted language code.
const LOCALE_LENGTH: std::ops::RangeInclusive<usize> = 2..=12;

/// Token to text, per language, exactly as the project supplied it.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct ProjectLocalization {
    tables: BTreeMap<String, BTreeMap<String, String>>,
}

impl ProjectLocalization {
    /// Reads the `localization` entry of a project's `general` object. A
    /// missing or malformed entry is an empty table.
    #[must_use]
    pub fn from_general(general: &Map<String, Value>) -> Self {
        let Some(languages) = general.get("localization").and_then(Value::as_object) else {
            return Self::default();
        };

        let mut tables: BTreeMap<String, BTreeMap<String, String>> = BTreeMap::new();
        let mut total_bytes = 0_usize;
        for (code, entries) in languages {
            let Some(code) = normalize_locale(code) else {
                continue;
            };
            let Some(entries) = entries.as_object() else {
                continue;
            };
            // A second spelling of a language already kept adds to it; only a
            // new language counts against the limit.
            if tables.len() >= MAX_LOCALES && !tables.contains_key(&code) {
                continue;
            }

            let mut table = tables.remove(&code).unwrap_or_default();
            for (token, text) in entries {
                if table.len() >= MAX_KEYS_PER_LOCALE {
                    break;
                }
                let Some(text) = text.as_str() else {
                    continue;
                };
                if token.trim().is_empty()
                    || token.len() > MAX_KEY_BYTES
                    || text.trim().is_empty()
                    || text.len() > MAX_VALUE_BYTES
                    || table.contains_key(token)
                    || total_bytes + token.len() + text.len() > MAX_TOTAL_BYTES
                {
                    continue;
                }
                total_bytes += token.len() + text.len();
                let _ = table.insert(token.clone(), text.to_owned());
            }
            // A language with nothing usable in it is not kept, so it never
            // uses up one of the language slots.
            if !table.is_empty() {
                let _ = tables.insert(code, table);
            }
        }
        Self { tables }
    }

    /// True when the project supplied no usable text at all.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.tables.is_empty()
    }

    /// The text for a whole label, in the first of `locales` that has it.
    ///
    /// Only a label that is exactly a token (ignoring surrounding spaces) is
    /// replaced; text that merely mentions one is left to the caller. `locales`
    /// are expected to be [`normalize_locale`] output, most preferred first.
    #[must_use]
    pub fn resolve(&self, token: &str, locales: &[String]) -> Option<&str> {
        let token = token.trim();
        if token.is_empty() || self.tables.is_empty() {
            return None;
        }
        locales
            .iter()
            .filter_map(|locale| self.tables.get(locale.as_str()))
            .find_map(|table| table.get(token))
            .map(String::as_str)
    }
}

/// A language code in the form project tables are matched by: lower case with
/// `-` as the separator (`zh_CN` is `zh-cn`). Anything that cannot be a
/// language code is `None`.
#[must_use]
pub fn normalize_locale(code: &str) -> Option<String> {
    if !LOCALE_LENGTH.contains(&code.len()) {
        return None;
    }
    let normalized: String = code
        .chars()
        .map(|character| match character {
            '_' => '-',
            other => other.to_ascii_lowercase(),
        })
        .collect();
    normalized
        .bytes()
        .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'-')
        .then_some(normalized)
}

/// The languages to read labels in for a host's request: the usable codes in
/// the order given, without repeats and at most [`MAX_PREFERRED_LOCALES`], then
/// English if it is not already there.
#[must_use]
pub fn preferred_locales(requested: &[String]) -> Vec<String> {
    let mut locales: Vec<String> = Vec::new();
    for code in requested {
        if locales.len() == MAX_PREFERRED_LOCALES {
            break;
        }
        if let Some(code) = normalize_locale(code)
            && !locales.contains(&code)
        {
            locales.push(code);
        }
    }
    if !locales.iter().any(|locale| locale == FALLBACK_LOCALE) {
        locales.push(FALLBACK_LOCALE.to_owned());
    }
    locales
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn general(localization: Value) -> Map<String, Value> {
        let Value::Object(general) = json!({ "localization": localization }) else {
            unreachable!("json! of an object literal is an object");
        };
        general
    }

    fn locales(codes: &[&str]) -> Vec<String> {
        codes.iter().map(|code| (*code).to_owned()).collect()
    }

    #[test]
    fn parse_is_bounded_and_ignores_junk() {
        // Junk shapes and codes are skipped, codes are lower-cased, and a
        // sibling of junk is still read.
        let table = ProjectLocalization::from_general(&general(json!({
            "EN-US": { "ui_a": "A", "ui_number": 3, "ui_object": {"x": 1}, "ui_blank": "  " },
            "zh_CHS": { "ui_a": "甲" },
            "not a code": { "ui_a": "ignored" },
            "x": { "ui_a": "too short a code" },
            "ja-jp": "not a table",
        })));
        assert_eq!(table.resolve("ui_a", &locales(&["en-us"])), Some("A"));
        assert_eq!(table.resolve("ui_a", &locales(&["zh-chs"])), Some("甲"));
        assert_eq!(table.resolve("ui_number", &locales(&["en-us"])), None);
        assert_eq!(table.resolve("ui_object", &locales(&["en-us"])), None);
        assert_eq!(table.resolve("ui_blank", &locales(&["en-us"])), None);
        assert_eq!(table.resolve("ui_a", &locales(&["ja-jp"])), None);

        // 5,000 tokens keep only the first 4,096, and a token or text over its
        // size limit is dropped whole rather than cut into a different label.
        let mut crowded = Map::new();
        for index in 0..5_000 {
            crowded.insert(format!("ui_{index}"), Value::String(format!("text {index}")));
        }
        crowded.insert("k".repeat(MAX_KEY_BYTES + 1), json!("long key"));
        crowded.insert("ui_long_value".to_owned(), json!("v".repeat(MAX_VALUE_BYTES + 1)));
        crowded.insert("ui_longest_ok".to_owned(), json!("v".repeat(MAX_VALUE_BYTES)));
        let table = ProjectLocalization::from_general(&general(json!({ "en-us": crowded })));
        let english = locales(&["en-us"]);
        assert_eq!(table.resolve("ui_0", &english), Some("text 0"));
        assert_eq!(table.resolve("ui_4095", &english), Some("text 4095"));
        assert_eq!(table.resolve("ui_4096", &english), None);
        assert_eq!(table.resolve("ui_long_value", &english), None);
        assert_eq!(table.resolve(&"k".repeat(MAX_KEY_BYTES + 1), &english), None);

        // A hostile table of 200 languages keeps 64, and the first ones win.
        let mut hostile = Map::new();
        for index in 0..200 {
            hostile.insert(format!("l{index:03}"), json!({ "ui_a": format!("text {index}") }));
        }
        let table = ProjectLocalization::from_general(&general(Value::Object(hostile)));
        assert_eq!(table.tables.len(), MAX_LOCALES);
        assert_eq!(table.resolve("ui_a", &locales(&["l000"])), Some("text 0"));
        assert_eq!(table.resolve("ui_a", &locales(&["l063"])), Some("text 63"));
        assert_eq!(table.resolve("ui_a", &locales(&["l064"])), None);
    }

    #[test]
    fn parse_stops_at_the_overall_text_budget() {
        // 40 languages of 30 texts at 1,500 bytes is about 1.8 MiB offered.
        let mut offered = Map::new();
        for language in 0..40 {
            let mut entries = Map::new();
            for index in 0..30 {
                entries.insert(format!("ui_{index}"), json!("t".repeat(1_500)));
            }
            offered.insert(format!("l{language:02}"), Value::Object(entries));
        }
        let table = ProjectLocalization::from_general(&general(Value::Object(offered)));
        let kept: usize = table
            .tables
            .values()
            .flat_map(|entries| entries.iter())
            .map(|(token, text)| token.len() + text.len())
            .sum();
        assert!(kept <= MAX_TOTAL_BYTES, "kept {kept} bytes");
        assert!(kept > MAX_TOTAL_BYTES / 2, "the budget should be used, kept {kept}");
        assert!(table.resolve("ui_0", &locales(&["l00"])).is_some());
        assert!(table.resolve("ui_29", &locales(&["l39"])).is_none());
    }

    #[test]
    fn missing_or_malformed_localization_is_an_empty_table() {
        for value in [json!(null), json!([]), json!("x"), json!({})] {
            let table = ProjectLocalization::from_general(&general(value));
            assert!(table.is_empty());
            assert_eq!(table.resolve("ui_a", &locales(&["en-us"])), None);
        }
        assert!(ProjectLocalization::from_general(&Map::new()).is_empty());
        // A language whose every entry was refused leaves nothing behind.
        let table = ProjectLocalization::from_general(&general(json!({
            "en-us": { "ui_a": 1, "ui_b": "" },
        })));
        assert!(table.is_empty());
    }

    #[test]
    fn resolve_prefers_the_first_locale_then_english_then_none() {
        let table = ProjectLocalization::from_general(&general(json!({
            "en-us": { "ui_both": "Both", "ui_english_only": "English only", "ui_blank_zh": "Blank zh" },
            "zh-chs": { "ui_both": "两者", "ui_blank_zh": "   ", "ui_chinese_only": "仅中文" },
        })));
        let chinese_first = locales(&["zh-chs", "en-us"]);
        assert_eq!(table.resolve("ui_both", &chinese_first), Some("两者"));
        // Absent from the preferred language: the next one answers.
        assert_eq!(table.resolve("ui_english_only", &chinese_first), Some("English only"));
        // Blank in the preferred language counts as absent.
        assert_eq!(table.resolve("ui_blank_zh", &chinese_first), Some("Blank zh"));
        // The order of the list is the order of preference.
        assert_eq!(table.resolve("ui_both", &locales(&["en-us", "zh-chs"])), Some("Both"));
        // Surrounding spaces on the label do not matter; the text is as supplied.
        assert_eq!(table.resolve("  ui_both \n", &chinese_first), Some("两者"));
        // Unknown token, empty label, no locales and unknown locales are None.
        assert_eq!(table.resolve("ui_unknown", &chinese_first), None);
        assert_eq!(table.resolve("", &chinese_first), None);
        assert_eq!(table.resolve("   ", &chinese_first), None);
        assert_eq!(table.resolve("ui_both", &[]), None);
        assert_eq!(table.resolve("ui_both", &locales(&["ko-kr"])), None);
        // Only a whole label is replaced.
        assert_eq!(table.resolve("ui_both and more", &chinese_first), None);
        assert_eq!(table.resolve("UI_BOTH", &chinese_first), None);
    }

    #[test]
    fn the_hosts_languages_are_cleaned_capped_and_end_with_english() {
        let requested = |codes: &[&str]| preferred_locales(&locales(codes));
        assert_eq!(requested(&[]), ["en-us"]);
        assert_eq!(requested(&["zh-CHS", "en-US"]), ["zh-chs", "en-us"]);
        // Junk and repeats are dropped; the host's order is kept.
        assert_eq!(
            requested(&["ja_JP", "bad code!", "JA-jp", "", "x"]),
            ["ja-jp", "en-us"]
        );
        // English stays where the host put it instead of moving to the end.
        assert_eq!(requested(&["en-us", "zh-chs"]), ["en-us", "zh-chs"]);
        // At most four are kept before English is added.
        assert_eq!(
            requested(&["aa", "bb", "cc", "dd", "ee", "ff"]),
            ["aa", "bb", "cc", "dd", "en-us"]
        );
    }

    #[test]
    fn locale_codes_are_normalized_or_refused() {
        assert_eq!(normalize_locale("zh-CHS").as_deref(), Some("zh-chs"));
        assert_eq!(normalize_locale("zh_TW").as_deref(), Some("zh-tw"));
        assert_eq!(normalize_locale("ja").as_deref(), Some("ja"));
        assert_eq!(normalize_locale("es419").as_deref(), Some("es419"));
        assert_eq!(normalize_locale("a"), None);
        assert_eq!(normalize_locale(""), None);
        assert_eq!(normalize_locale("abcdefghijklm"), None);
        assert_eq!(normalize_locale("en us"), None);
        assert_eq!(normalize_locale("en.us"), None);
        assert_eq!(normalize_locale("日本語"), None);
    }
}
