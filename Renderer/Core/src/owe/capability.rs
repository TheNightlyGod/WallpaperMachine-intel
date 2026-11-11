//! Reading a scene without drawing it (`owe_scene_capability_probe`): whether Native Metal would
//! refuse it, and which files its layers name and lack.

use std::{
    ffi::{CStr, CString, c_char},
    path::Path,
};

use serde::Deserialize;

use crate::{
    EngineError,
    owe::{sys, unwind::UnwindSafeFFI},
};

/// A file the scene names that none of its file systems holds.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
pub struct SceneMissingFile {
    /// The layer being built when the file was asked for; empty when none was.
    pub layer: String,
    /// That layer's object id in the scene file, or -1.
    pub object_id: i32,
    /// The path below the scene's own space, such as `materials/rain.json`.
    pub path: String,
}

/// What reading a scene, without drawing it, says about it.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
pub struct SceneCapabilityProbe {
    /// Why the scene could not be read at all. Empty when it was; nothing else is known otherwise.
    pub read_error: String,
    /// `unsupported` or `compile` when Native Metal would refuse the scene, empty when it would not.
    pub failure_stage: String,
    /// The renderer's own English explanation of the refusal.
    pub failure_reason: String,
    pub missing_files: Vec<SceneMissingFile>,
}

/// Reads the scene of `project_file` the way loading it does, with `overrides` (a flat JSON object
/// of saved property choices) over its defaults. Blocks for as long as the parse takes, which is
/// seconds for a large scene: call it from a thread that may wait.
///
/// # Errors
///
/// Returns [`EngineError`] when a path holds a NUL byte, the engine refuses the call, or its
/// answer cannot be read. A scene that cannot be read is not an error: `read_error` says why.
pub fn probe_scene_capability(
    project_file: &Path,
    assets: &Path,
    cache: Option<&Path>,
    overrides: Option<&str>,
) -> Result<SceneCapabilityProbe, EngineError> {
    let text = |value: &str| {
        CString::new(value).map_err(|_| EngineError::InvalidInput(format!("{value:?} holds a NUL byte")))
    };
    let project_file = text(&project_file.to_string_lossy())?;
    let assets = text(&assets.to_string_lossy())?;
    let cache = cache.map(|cache| text(&cache.to_string_lossy())).transpose()?;
    let overrides = overrides.map(text).transpose()?;
    let mut answer: *mut c_char = std::ptr::null_mut();
    // SAFETY: every pointer is a live C string or null for the optional ones, and `answer` is a
    // valid place for the engine to write its allocation to.
    let status = unsafe {
        UnwindSafeFFI::new("owe_scene_capability_probe").call(|| {
            sys::owe_scene_capability_probe(
                project_file.as_ptr(),
                assets.as_ptr(),
                cache.as_ref().map_or(std::ptr::null(), |cache| cache.as_ptr()),
                overrides.as_ref().map_or(std::ptr::null(), |overrides| overrides.as_ptr()),
                &raw mut answer,
            )
        })?
    };
    if status != 0 {
        // SAFETY: the engine's thread-local error text is readable at any time.
        return Err(EngineError::Render(unsafe { UnwindSafeFFI::last_error() }));
    }
    if answer.is_null() {
        return Err(EngineError::Render("the scene probe returned no answer".to_owned()));
    }
    // SAFETY: on success the engine wrote a NUL-terminated string it allocated, released below.
    let document = unsafe { CStr::from_ptr(answer) }.to_string_lossy().into_owned();
    // SAFETY: `answer` came from the engine's allocator and is released exactly once.
    unsafe {
        UnwindSafeFFI::new("owe_free_string").call(|| sys::owe_free_string(answer))?;
    }
    serde_json::from_str(&document)
        .map_err(|error| EngineError::Render(format!("the scene probe's answer is unreadable: {error}")))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_engines_answer_reads_as_it_is_written() {
        let probe: SceneCapabilityProbe = serde_json::from_str(
            r#"{"read_error":"","failure_stage":"unsupported","failure_reason":"a light probe",
                "missing_files":[{"layer":"Rain","object_id":12,"path":"materials/rain.json"}]}"#,
        )
        .unwrap();
        assert_eq!(probe.failure_stage, "unsupported");
        assert_eq!(
            probe.missing_files,
            vec![SceneMissingFile {
                layer: "Rain".into(),
                object_id: 12,
                path: "materials/rain.json".into()
            }]
        );
    }
}
