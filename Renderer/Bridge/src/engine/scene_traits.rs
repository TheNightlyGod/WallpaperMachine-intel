//! What a scene's own file says about the per-wallpaper options Wallpaper
//! Engine offers for it, read once per version of the file.

use std::{
    collections::BTreeMap,
    path::{Path, PathBuf},
    time::UNIX_EPOCH,
};

pub use wallpaper_core::SceneTraits;

/// The traits read for each wallpaper, with the stamp of the file they were
/// read from.
#[derive(Clone, Debug, Default)]
pub struct SceneTraitsCache {
    entries: BTreeMap<String, (u64, SceneTraits)>,
}

impl SceneTraitsCache {
    /// The traits last read for `wallpaper_id`; not offered when nothing was
    /// read.
    #[must_use]
    pub fn get(&self, wallpaper_id: &str) -> SceneTraits {
        self.entries.get(wallpaper_id).map(|(_, traits)| *traits).unwrap_or_default()
    }

    /// Reads the traits of scene `wallpaper_id`, whose project file is
    /// `project_json`, with `read` unless the scene file is the one read last
    /// time. A scene that cannot be read offers no mouse-parallax switch, and
    /// is logged once per version of its file.
    pub fn refresh(
        &mut self,
        wallpaper_id: &str,
        project_json: &Path,
        read: impl FnOnce(&Path) -> Result<SceneTraits, wallpaper_core::EngineError>,
    ) -> SceneTraits {
        let stamp = scene_file_stamp(project_json);
        if let Some((cached, traits)) = self.entries.get(wallpaper_id)
            && *cached == stamp
        {
            return *traits;
        }
        let traits = read(project_json).unwrap_or_else(|error| {
            log::warn!(
                "scene traits: {wallpaper_id} could not be read, so it offers no mouse-parallax switch: {error}"
            );
            SceneTraits::default()
        });
        self.entries.insert(wallpaper_id.to_owned(), (stamp, traits));
        traits
    }
}

/// The length and modification time of the scene's file (`scene.pkg`, else
/// the loose entry the project names, else the project file), hashed.
fn scene_file_stamp(project_json: &Path) -> u64 {
    let folder = project_json.parent().map(Path::to_path_buf).unwrap_or_default();
    let candidates = [folder.join("scene.pkg"), loose_entry(project_json, &folder), project_json.to_path_buf()];
    let Some((path, metadata)) = candidates
        .iter()
        .find_map(|path| std::fs::metadata(path).ok().filter(std::fs::Metadata::is_file).map(|metadata| (path, metadata)))
    else {
        return 0;
    };
    let modified = metadata
        .modified()
        .ok()
        .and_then(|modified| modified.duration_since(UNIX_EPOCH).ok())
        .map_or(0, |since| since.as_nanos());
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for byte in path
        .as_os_str()
        .as_encoded_bytes()
        .iter()
        .chain(&metadata.len().to_le_bytes())
        .chain(&modified.to_le_bytes())
    {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x0100_0000_01b3);
    }
    hash
}

fn loose_entry(project_json: &Path, folder: &Path) -> PathBuf {
    std::fs::read(project_json)
        .ok()
        .and_then(|bytes| serde_json::from_slice::<serde_json::Value>(&bytes).ok())
        .and_then(|project| project.get("file").and_then(|file| file.as_str()).map(str::to_owned))
        .filter(|file| !file.is_empty() && !file.contains(".."))
        .map_or_else(|| folder.join("scene.json"), |file| folder.join(file))
}

#[cfg(test)]
mod tests {
    use std::cell::Cell;

    use super::*;

    #[test]
    fn a_scene_file_is_read_once_per_version_and_an_unreadable_one_offers_nothing() {
        let root = tempfile::tempdir().unwrap();
        let project = root.path().join("project.json");
        std::fs::write(&project, br#"{"type":"scene","file":"scene.json"}"#).unwrap();
        std::fs::write(root.path().join("scene.json"), b"{}").unwrap();
        let reads = Cell::new(0);
        let offered = SceneTraits { camera_parallax_offered: true };
        let mut cache = SceneTraitsCache::default();

        let read = |_: &Path| {
            reads.set(reads.get() + 1);
            Ok(offered)
        };
        assert_eq!(cache.refresh("1", &project, read), offered);
        assert_eq!(cache.refresh("1", &project, read), offered);
        assert_eq!(reads.get(), 1, "the same file is not read again");
        assert_eq!(cache.get("1"), offered);

        std::fs::write(root.path().join("scene.json"), b"{ \"general\": {} }").unwrap();
        let failed = cache.refresh("1", &project, |_| {
            Err(wallpaper_core::EngineError::InvalidInput("unreadable".into()))
        });
        assert_eq!(failed, SceneTraits::default());
        assert_eq!(cache.get("2"), SceneTraits::default());
    }
}
