use serde_json::{Map, Value};
use std::collections::BTreeMap;

pub const MAX_LOCALES: usize = 64;
pub const MAX_KEYS_PER_LOCALE: usize = 4096;
pub const MAX_KEY_BYTES: usize = 128;
pub const MAX_VALUE_BYTES: usize = 2048;
pub const MAX_TOTAL_BYTES: usize = 1_048_576;
pub const FALLBACK_LOCALE: &str = "en-us";
pub const MAX_PREFERRED_LOCALES: usize = 4;

#[derive(Clone, Debug, Default, PartialEq)]
pub struct ProjectLocalization {
    tables: BTreeMap<String, BTreeMap<String, String>>,
}

pub fn normalize_locale(code: &str) -> Option<String> {
    if !(2..=12).contains(&code.len())
        || !code
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-' || byte == b'_')
    {
        return None;
    }
    Some(
        code.bytes()
            .map(|byte| {
                if byte == b'_' {
                    '-'
                } else {
                    byte.to_ascii_lowercase() as char
                }
            })
            .collect(),
    )
}

pub fn preferred_locales(requested: &[String]) -> Vec<String> {
    let mut result = Vec::with_capacity(MAX_PREFERRED_LOCALES + 1);
    for code in requested {
        let Some(code) = normalize_locale(code) else {
            continue;
        };
        if !result.contains(&code) {
            result.push(code);
            if result.len() == MAX_PREFERRED_LOCALES {
                break;
            }
        }
    }
    if !result.iter().any(|code| code == FALLBACK_LOCALE) {
        result.push(FALLBACK_LOCALE.to_owned());
    }
    result
}

impl ProjectLocalization {
    pub fn from_general(general: &Map<String, Value>) -> Self {
        let mut result = Self::default();
        let Some(locales) = general.get("localization").and_then(Value::as_object) else {
            return result;
        };
        let mut bytes = 0;
        for (code, table) in locales {
            let Some(code) = normalize_locale(code) else {
                continue;
            };
            let Some(table) = table.as_object() else {
                continue;
            };
            if let Some(retained) = result.tables.get_mut(&code) {
                retain_entries(retained, table, &mut bytes);
            } else if result.tables.len() < MAX_LOCALES {
                let mut retained = BTreeMap::new();
                retain_entries(&mut retained, table, &mut bytes);
                if !retained.is_empty() {
                    result.tables.insert(code, retained);
                }
            }
        }
        result
    }

    pub fn is_empty(&self) -> bool {
        self.tables.is_empty()
    }

    pub fn resolve<'a>(&'a self, token: &str, locales: &[String]) -> Option<&'a str> {
        let token = token.trim();
        locales
            .iter()
            .find_map(|locale| self.tables.get(locale)?.get(token).map(String::as_str))
    }
}

fn retain_entries(
    retained: &mut BTreeMap<String, String>,
    table: &Map<String, Value>,
    bytes: &mut usize,
) {
    for (key, value) in table {
        if retained.len() == MAX_KEYS_PER_LOCALE {
            break;
        }
        let Some(value) = value.as_str() else {
            continue;
        };
        if key.len() > MAX_KEY_BYTES
            || value.len() > MAX_VALUE_BYTES
            || key.trim().is_empty()
            || value.trim().is_empty()
            || retained.contains_key(key)
        {
            continue;
        }
        let cost = key.len() + value.len();
        if cost > MAX_TOTAL_BYTES - *bytes {
            continue;
        }
        retained.insert(key.clone(), value.to_owned());
        *bytes += cost;
    }
}
