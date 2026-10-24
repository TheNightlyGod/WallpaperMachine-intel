//! Reading the manifest the app writes for managed `file`/`directory` property assets.
//!
//! The app owns the store: it copies the user's pick into
//! `<user assets root>/<wallpaper id>/<property id>/<asset id>/<file name>` and records
//! what it did in `<user assets root>/<wallpaper id>/manifest.json`. The bridge only
//! reads that manifest, so the control panel can say whether the app holds a copy of an
//! asset and whether the user's own file can still be found.
//!
//! Nothing here writes. A manifest that is absent, unreadable, or written by a version
//! this build does not understand reads as "no managed assets", which is the same
//! answer a fresh install gives.

use std::{
    collections::HashMap,
    path::{Path, PathBuf},
};

use serde::Deserialize;

/// The only manifest layout this build understands.
const SUPPORTED_VERSION: u32 = 1;

const MANIFEST_FILE: &str = "manifest.json";

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UserAssetManifest {
    #[serde(default)]
    pub version: u32,
    #[serde(default)]
    pub properties: HashMap<String, UserAssetPropertyRecord>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UserAssetPropertyRecord {
    /// The file or folder the user picked, as it was when they picked it.
    #[serde(default)]
    pub source_path: String,
    #[serde(default)]
    pub assets: Vec<UserAssetEntry>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UserAssetEntry {
    pub asset_id: String,
    pub file_name: String,
}

/// What the control panel needs to render one file or directory property.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct UserAssetStatus {
    /// The app holds its own copy, and that copy is on disk right now.
    pub managed: bool,
    /// The property names something, and neither the user's own path nor a managed
    /// copy resolves. Distinct from an unset property, which is neither.
    pub missing: bool,
}

impl UserAssetManifest {
    /// Loads one wallpaper's manifest, or `None` when there is nothing usable to read.
    #[must_use]
    pub fn load(root: &Path, wallpaper_id: &str) -> Option<Self> {
        if wallpaper_id.is_empty() || Path::new(wallpaper_id).components().count() != 1 {
            return None;
        }
        let path = root.join(wallpaper_id).join(MANIFEST_FILE);
        let raw = std::fs::read(path).ok()?;
        let manifest: Self = serde_json::from_slice(&raw).ok()?;
        (manifest.version == SUPPORTED_VERSION).then_some(manifest)
    }

    /// Where the store keeps one recorded file.
    fn stored_path(root: &Path, wallpaper_id: &str, property_id: &str, entry: &UserAssetEntry) -> PathBuf {
        root.join(wallpaper_id)
            .join(property_id)
            .join(&entry.asset_id)
            .join(&entry.file_name)
    }

    /// The user's own path for a property, as the app recorded it. Empty when the
    /// property was never imported.
    #[must_use]
    pub fn source_path(&self, property_id: &str) -> Option<&str> {
        let recorded = self.properties.get(property_id)?.source_path.as_str();
        (!recorded.is_empty()).then_some(recorded)
    }

    /// Whether the app holds a copy of this property's assets, and whether the property
    /// points at something nothing can resolve any more.
    ///
    /// `value` is the property's current value: the path the user picked. An empty value
    /// is an unset property, which is never "missing".
    #[must_use]
    pub fn status(
        &self,
        root: &Path,
        wallpaper_id: &str,
        property_id: &str,
        value: &str,
    ) -> UserAssetStatus {
        let managed = self.properties.get(property_id).is_some_and(|record| {
            record.assets.iter().any(|entry| {
                Self::stored_path(root, wallpaper_id, property_id, entry).exists()
            })
        });
        let source = self.source_path(property_id).unwrap_or(value);
        let missing = !value.is_empty() && !managed && !Path::new(source).exists();
        UserAssetStatus { managed, missing }
    }
}

/// The status of a property no manifest covers: the app holds nothing, and the property
/// is missing only when it names a path that is not there.
#[must_use]
pub fn unmanaged_status(value: &str) -> UserAssetStatus {
    UserAssetStatus {
        managed: false,
        missing: !value.is_empty() && !Path::new(value).exists(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write_manifest(root: &Path, wallpaper_id: &str, body: &str) {
        let directory = root.join(wallpaper_id);
        std::fs::create_dir_all(&directory).expect("manifest directory");
        std::fs::write(directory.join(MANIFEST_FILE), body).expect("manifest");
    }

    fn store_asset(root: &Path, wallpaper_id: &str, property_id: &str, asset_id: &str, name: &str) {
        let directory = root.join(wallpaper_id).join(property_id).join(asset_id);
        std::fs::create_dir_all(&directory).expect("asset directory");
        std::fs::write(directory.join(name), b"bytes").expect("asset");
    }

    fn temp_root() -> tempfile::TempDir {
        tempfile::tempdir().expect("temp root")
    }

    #[test]
    fn a_stored_asset_is_managed_even_when_the_users_own_file_is_gone() {
        let temp = temp_root();
        let root = temp.path();
        write_manifest(
            root,
            "2001",
            r#"{"version":1,"wallpaperId":"2001","properties":{"background":{"kind":"file","sourcePath":"/gone/clouds.png","truncated":false,"migratedLegacyPaths":[],"assets":[{"assetId":"abc","fileName":"clouds.png","sourcePath":"/gone/clouds.png","size":5,"modified":"2024-01-01T00:00:00Z","digest":"abc"}]}}}"#,
        );
        store_asset(root, "2001", "background", "abc", "clouds.png");

        let manifest = UserAssetManifest::load(root, "2001").expect("manifest");
        let status = manifest.status(root, "2001", "background", "/gone/clouds.png");

        assert!(status.managed);
        assert!(
            !status.missing,
            "a property the app still has a copy of is usable, not missing"
        );
        assert_eq!(manifest.source_path("background"), Some("/gone/clouds.png"));

    }

    #[test]
    fn a_recorded_asset_absent_from_the_store_is_missing() {
        let temp = temp_root();
        let root = temp.path();
        write_manifest(
            root,
            "2001",
            r#"{"version":1,"wallpaperId":"2001","properties":{"background":{"kind":"file","sourcePath":"/gone/clouds.png","truncated":false,"migratedLegacyPaths":[],"assets":[{"assetId":"abc","fileName":"clouds.png","sourcePath":"/gone/clouds.png","size":5,"modified":"2024-01-01T00:00:00Z","digest":"abc"}]}}}"#,
        );

        let manifest = UserAssetManifest::load(root, "2001").expect("manifest");
        let status = manifest.status(root, "2001", "background", "/gone/clouds.png");

        assert!(!status.managed);
        assert!(status.missing);

    }

    #[test]
    fn an_unset_property_is_neither_managed_nor_missing() {
        let temp = temp_root();
        let root = temp.path();
        let manifest = UserAssetManifest::default();

        assert_eq!(
            manifest.status(root, "2001", "background", ""),
            UserAssetStatus::default()
        );
        assert_eq!(unmanaged_status(""), UserAssetStatus::default());

    }

    #[test]
    fn a_manifest_from_a_future_version_reads_as_no_managed_assets() {
        let temp = temp_root();
        let root = temp.path();
        write_manifest(root, "2001", r#"{"version":99,"properties":{}}"#);

        assert!(UserAssetManifest::load(root, "2001").is_none());

    }

    #[test]
    fn a_wallpaper_id_with_path_separators_cannot_reach_outside_the_store() {
        let temp = temp_root();
        let root = temp.path();
        write_manifest(root, "2001", r#"{"version":1,"properties":{}}"#);

        assert!(UserAssetManifest::load(root, "../2001").is_none());
        assert!(UserAssetManifest::load(root, "a/b").is_none());

    }
}
