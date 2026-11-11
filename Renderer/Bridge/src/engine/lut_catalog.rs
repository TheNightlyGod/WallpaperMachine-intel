//! The image filters (Wallpaper Engine's colour lookup tables) the shared scene
//! assets offer: the `.tex` files directly in `materials/lut`.

use std::{
    path::{Path, PathBuf},
    time::SystemTime,
};

use crate::config::is_image_filter_name;

/// At most this many filters are listed; the shipped assets hold 28.
pub const MAX_IMAGE_FILTERS: usize = 256;

/// The filters found under one assets folder, kept until the folder changes.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct LutCatalog {
    root: PathBuf,
    modified: Option<SystemTime>,
    names: Vec<String>,
}

impl LutCatalog {
    /// The filters, sorted without regard to case.
    #[must_use]
    pub fn names(&self) -> &[String] {
        &self.names
    }

    #[must_use]
    pub fn contains(&self, name: &str) -> bool {
        self.names.iter().any(|known| known == name)
    }

    /// The catalog of `assets_root`, read again only when the folder is
    /// another one or its `materials/lut` changed since `cached` was read.
    #[must_use]
    pub fn refreshed(cached: Option<&Self>, assets_root: &Path) -> Self {
        let directory = lut_directory(assets_root);
        let modified = std::fs::metadata(&directory).and_then(|metadata| metadata.modified()).ok();
        if let Some(cached) = cached
            && cached.root == assets_root
            && cached.modified == modified
            && modified.is_some()
        {
            return cached.clone();
        }
        Self {
            root: assets_root.to_path_buf(),
            modified,
            names: list(&directory),
        }
    }
}

/// Where the filters live under the shared assets.
#[must_use]
pub fn lut_directory(assets_root: &Path) -> PathBuf {
    assets_root.join("materials").join("lut")
}

/// The `.tex` file of filter `name`, when it is a plain name.
#[must_use]
pub fn lut_file(assets_root: &Path, name: &str) -> Option<PathBuf> {
    is_image_filter_name(name).then(|| lut_directory(assets_root).join(format!("{name}.tex")))
}

/// The regular `.tex` files directly in `directory` whose stem is a plain name,
/// sorted without regard to case, at most [`MAX_IMAGE_FILTERS`]. A folder that
/// cannot be read holds none.
fn list(directory: &Path) -> Vec<String> {
    let Ok(entries) = std::fs::read_dir(directory) else {
        return Vec::new();
    };
    let mut names: Vec<String> = entries
        .filter_map(Result::ok)
        .filter(|entry| entry.file_type().is_ok_and(|kind| kind.is_file()))
        .filter_map(|entry| {
            let path = entry.path();
            if !path.extension().is_some_and(|extension| extension.eq_ignore_ascii_case("tex")) {
                return None;
            }
            let stem = path.file_stem()?.to_str()?.to_owned();
            is_image_filter_name(&stem).then_some(stem)
        })
        .collect();
    names.sort_by(|left, right| {
        left.to_ascii_lowercase()
            .cmp(&right.to_ascii_lowercase())
            .then_with(|| left.cmp(right))
    });
    names.dedup();
    names.truncate(MAX_IMAGE_FILTERS);
    names
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write(dir: &Path, name: &str) {
        std::fs::write(dir.join(name), b"TEXV0005").unwrap();
    }

    #[test]
    fn lists_plain_tex_stems_sorted_without_case_and_skips_the_rest() {
        let root = tempfile::tempdir().unwrap();
        let lut = lut_directory(root.path());
        std::fs::create_dir_all(&lut).unwrap();
        for name in ["lutx32_daisy.tex", "Amber.TEX", "k23_b.tex", "notes.txt", "bad name.tex", "..tex"] {
            write(&lut, name);
        }
        std::fs::create_dir(lut.join("folder.tex")).unwrap();

        let catalog = LutCatalog::refreshed(None, root.path());

        assert_eq!(catalog.names(), ["Amber", "k23_b", "lutx32_daisy"]);
        assert!(catalog.contains("k23_b"));
        assert!(!catalog.contains("bad name"));
    }

    #[test]
    fn a_missing_folder_offers_no_filter() {
        let root = tempfile::tempdir().unwrap();
        assert!(LutCatalog::refreshed(None, root.path()).names().is_empty());
    }

    #[test]
    fn a_file_name_that_is_not_plain_names_no_file() {
        let root = Path::new("/assets");
        assert_eq!(lut_file(root, "amber"), Some(PathBuf::from("/assets/materials/lut/amber.tex")));
        assert_eq!(lut_file(root, "../x"), None);
        assert_eq!(lut_file(root, ""), None);
    }
}
