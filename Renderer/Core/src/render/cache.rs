// Clean-room implementation from the WallpaperMachine spec r1c-core-media.md; written without access to the original source.
use std::{
    fs,
    io::ErrorKind,
    path::{Component, Path, PathBuf},
    time::UNIX_EPOCH,
};

use serde_json::{Value, json};

const MANIFEST_FILE: &str = "manifest.json";

#[cfg(test)]
#[path = "cache_link_tests.rs"]
mod link_tests;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ShaderCacheInputs {
    scene_id: String,
    cache_root: PathBuf,
    project_json_path: PathBuf,
    scene_pkg_path: PathBuf,
    unpacked_source: Option<(PathBuf, PathBuf)>,
    property_override_json: Option<String>,
    scene_quality_key: Option<String>,
    force_refresh: bool,
}

impl ShaderCacheInputs {
    #[must_use]
    pub fn builder(
        scene_id: impl Into<String>,
        cache_root: impl Into<PathBuf>,
    ) -> ShaderCacheInputsBuilder {
        ShaderCacheInputsBuilder {
            scene_id: scene_id.into(),
            cache_root: cache_root.into(),
            project_json_path: None,
            scene_pkg_path: None,
            unpacked_source: None,
            property_override_json: None,
            scene_quality_key: None,
            force_refresh: false,
        }
    }
}

impl AsRef<ShaderCacheInputs> for ShaderCacheInputs {
    fn as_ref(&self) -> &ShaderCacheInputs {
        self
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ShaderCacheInputsBuilder {
    scene_id: String,
    cache_root: PathBuf,
    project_json_path: Option<PathBuf>,
    scene_pkg_path: Option<PathBuf>,
    unpacked_source: Option<(PathBuf, PathBuf)>,
    property_override_json: Option<String>,
    scene_quality_key: Option<String>,
    force_refresh: bool,
}

impl ShaderCacheInputsBuilder {
    #[must_use]
    pub fn project_json_path(mut self, path: impl Into<PathBuf>) -> Self {
        self.project_json_path = Some(path.into());
        self
    }

    #[must_use]
    pub fn scene_pkg_path(mut self, path: impl Into<PathBuf>) -> Self {
        self.scene_pkg_path = Some(path.into());
        self
    }

    /// Sets the physical entry and resource root used when the package is absent.
    #[must_use]
    pub fn unpacked_source(mut self, entry: impl Into<PathBuf>, root: impl Into<PathBuf>) -> Self {
        self.unpacked_source = Some((entry.into(), root.into()));
        self
    }

    #[must_use]
    pub fn property_override_json(mut self, json: Option<impl Into<String>>) -> Self {
        self.property_override_json = json.map(Into::into);
        self
    }

    /// The scene quality the shaders are built for; another quality compiles
    /// other combos, so it must not reuse this cache.
    #[must_use]
    pub fn scene_quality_key(mut self, key: impl Into<String>) -> Self {
        self.scene_quality_key = Some(key.into());
        self
    }

    #[must_use]
    pub fn force_refresh(mut self, force_refresh: bool) -> Self {
        self.force_refresh = force_refresh;
        self
    }

    /// # Errors
    ///
    /// Returns an error if the scene id, cache root, project path, or package
    /// path is invalid or missing.
    pub fn build(self) -> Result<ShaderCacheInputs, crate::EngineError> {
        let invalid = |message: &str| crate::EngineError::InvalidInput(message.to_owned());

        if !is_single_component(&self.scene_id) {
            return Err(invalid(
                "scene id must be a single path component without separators",
            ));
        }
        if self.cache_root.as_os_str().is_empty() {
            return Err(invalid("shader cache root must not be empty"));
        }
        let project_json_path = self
            .project_json_path
            .filter(|path| !path.as_os_str().is_empty())
            .ok_or_else(|| invalid("shader cache needs the project.json path"))?;
        let scene_pkg_path = self
            .scene_pkg_path
            .filter(|path| !path.as_os_str().is_empty())
            .ok_or_else(|| invalid("shader cache needs the scene package path"))?;

        Ok(ShaderCacheInputs {
            scene_id: self.scene_id,
            cache_root: self.cache_root,
            project_json_path,
            scene_pkg_path,
            unpacked_source: self.unpacked_source,
            property_override_json: self.property_override_json,
            scene_quality_key: self.scene_quality_key,
            force_refresh: self.force_refresh,
        })
    }
}

/// A scene id may only name one ordinary folder: no separator of either kind, and
/// neither `.` nor `..`.
fn is_single_component(scene_id: &str) -> bool {
    if scene_id.is_empty() || scene_id.contains(['/', '\\']) {
        return false;
    }
    let mut components = Path::new(scene_id).components();
    matches!(
        (components.next(), components.next()),
        (Some(Component::Normal(_)), None)
    )
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ShaderCacheDecision {
    scene_cache_path: PathBuf,
    purged_cache: bool,
}

impl ShaderCacheDecision {
    /// # Errors
    ///
    /// Returns an error if cache metadata cannot be read/written or the cache
    /// directory cannot be prepared.
    pub fn prepare<T: AsRef<ShaderCacheInputs>>(inputs: T) -> Result<Self, crate::EngineError> {
        let inputs = inputs.as_ref();
        let scene_cache_path = inputs.cache_root.join(&inputs.scene_id);

        let mut wanted = json!({
            "project_mtime": modified_timestamp(&inputs.project_json_path, "project.json")?,
            "source": source_fingerprint(inputs)?,
            "property_override_json": inputs.property_override_json,
        });
        if let Some(key) = &inputs.scene_quality_key {
            wanted["scene_quality"] = json!(key);
        }
        let manifest_path = scene_cache_path.join(MANIFEST_FILE);

        let up_to_date = !inputs.force_refresh
            && fs::read_to_string(&manifest_path)
                .ok()
                .and_then(|text| serde_json::from_str::<Value>(&text).ok())
                .is_some_and(|stored| stored == wanted);

        let purged_cache = !up_to_date;
        if purged_cache {
            match fs::remove_dir_all(&scene_cache_path) {
                Ok(()) => {}
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                Err(error) => {
                    return Err(crate::EngineError::Render(format!(
                        "failed to clear scene shader cache: {error}"
                    )));
                }
            }
        }
        fs::create_dir_all(&scene_cache_path).map_err(|error| {
            crate::EngineError::Render(format!(
                "failed to create scene shader cache directory: {error}"
            ))
        })?;
        let text = serde_json::to_string_pretty(&wanted).map_err(|error| {
            crate::EngineError::Render(format!("failed to write shader cache manifest: {error}"))
        })?;
        fs::write(&manifest_path, text).map_err(|error| {
            crate::EngineError::Render(format!("failed to write shader cache manifest: {error}"))
        })?;

        Ok(Self {
            scene_cache_path,
            purged_cache,
        })
    }

    #[must_use]
    pub fn scene_cache_path(&self) -> &Path {
        &self.scene_cache_path
    }

    #[must_use]
    pub fn purged_cache(&self) -> bool {
        self.purged_cache
    }
}

/// Describes the scene's source for the manifest: the package file when there is one,
/// otherwise the unpacked entry plus every resource file under its root.
fn source_fingerprint(inputs: &ShaderCacheInputs) -> Result<Value, crate::EngineError> {
    let package = match fs::metadata(&inputs.scene_pkg_path) {
        Ok(found) => Some(found),
        Err(missing) if missing.kind() == ErrorKind::NotFound => {
            if inputs.unpacked_source.is_none() {
                return Err(crate::EngineError::Render(format!(
                    "failed to stat scene package: {missing}"
                )));
            }
            None
        }
        Err(other) => return Err(source_inspection_failed(other)),
    };
    if let Some(found) = package {
        return Ok(json!({
            "kind": "package",
            "mtime": stamp_of(&found, "scene package")?,
            "size": found.len(),
        }));
    }
    let (entry, resource_root) = inputs
        .unpacked_source
        .as_ref()
        .expect("the missing-package branch above guarantees an unpacked source");
    let entry_mtime = modified_timestamp(entry, "unpacked scene entry")?;
    let resources = resource_stamps(resource_root, &inputs.cache_root)?;
    Ok(json!({
        "kind": "unpacked",
        "entry": entry,
        "entry_mtime": entry_mtime,
        "files": resources,
    }))
}

/// Every regular file below `resource_root` as `[relative path, mtime, size]`, sorted,
/// leaving out whatever lives under `cache_root` (the cache must not invalidate itself).
fn resource_stamps(
    resource_root: &Path,
    cache_root: &Path,
) -> Result<Vec<(String, String, u64)>, crate::EngineError> {
    // The cache root has to exist before it can be resolved and excluded.
    fs::create_dir_all(cache_root).map_err(source_inspection_failed)?;
    let excluded = fs::canonicalize(cache_root).map_err(source_inspection_failed)?;
    let base = fs::canonicalize(resource_root).map_err(source_inspection_failed)?;
    let mut stamps = Vec::new();
    visit_directory(&base, &base, &excluded, &mut stamps)?;
    stamps.sort();
    Ok(stamps)
}

fn visit_directory(
    directory: &Path,
    base: &Path,
    excluded: &Path,
    stamps: &mut Vec<(String, String, u64)>,
) -> Result<(), crate::EngineError> {
    for entry in fs::read_dir(directory).map_err(source_inspection_failed)? {
        let path = entry.map_err(source_inspection_failed)?.path();
        if path.starts_with(excluded) {
            continue;
        }
        let own = fs::symlink_metadata(&path).map_err(source_inspection_failed)?;
        if own.is_dir() {
            // A directory reached through a link is never entered: `own` does not follow links.
            visit_directory(&path, base, excluded, stamps)?;
            continue;
        }
        let is_link = own.file_type().is_symlink();
        if !own.is_file() && !is_link {
            continue;
        }
        // A link outside the cache may still name one of its own outputs.
        // Resolve links before fingerprinting, but keep their lexical source names.
        let target = if is_link {
            match fs::canonicalize(&path) {
                Ok(target) if target.starts_with(excluded) => continue,
                Ok(target) => Some(target),
                Err(gone) if gone.kind() == ErrorKind::NotFound => continue,
                Err(other) => return Err(source_inspection_failed(other)),
            }
        } else {
            None
        };
        let resolved = match fs::metadata(target.as_deref().unwrap_or(&path)) {
            Ok(resolved) => resolved,
            Err(gone) if is_link && gone.kind() == ErrorKind::NotFound => continue,
            Err(other) => return Err(source_inspection_failed(other)),
        };
        if !resolved.is_file() {
            continue;
        }
        let relative = path.strip_prefix(base).unwrap_or(&path);
        stamps.push((
            relative.to_string_lossy().into_owned(),
            stamp_of(&resolved, "unpacked scene resource")?,
            resolved.len(),
        ));
    }
    Ok(())
}

fn source_inspection_failed(cause: std::io::Error) -> crate::EngineError {
    crate::EngineError::Render(format!("failed to inspect scene cache source ({cause})"))
}

/// Modification time as `<seconds>.<nine-digit nanoseconds>` since the epoch; a time
/// before the epoch reads as zero.
fn modified_timestamp(path: &Path, label: &str) -> Result<String, crate::EngineError> {
    let metadata = fs::metadata(path)
        .map_err(|error| crate::EngineError::Render(format!("failed to stat {label}: {error}")))?;
    stamp_of(&metadata, label)
}

fn stamp_of(metadata: &fs::Metadata, label: &str) -> Result<String, crate::EngineError> {
    let modified = metadata
        .modified()
        .map_err(|error| crate::EngineError::Render(format!("failed to stat {label}: {error}")))?;
    let elapsed = modified.duration_since(UNIX_EPOCH).unwrap_or_default();
    Ok(format!("{}.{:09}", elapsed.as_secs(), elapsed.subsec_nanos()))
}
