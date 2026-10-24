/// Projects a complete inventory into a visible, freshly annotated snapshot.
pub(crate) fn library_snapshot(
    entries: &[crate::api::BridgeWallpaperEntry],
    selected: Option<&str>,
    active: &[String],
    visible: impl Fn(crate::api::BridgeWallpaperKind) -> bool,
) -> crate::api::BridgeLibrarySnapshot {
    use crate::api::{BridgeLibraryScanStatus, BridgeLibrarySnapshot, BridgeWallpaperKind};

    let mut snapshot = BridgeLibrarySnapshot {
        wallpapers: Vec::new(),
        scan_status: BridgeLibraryScanStatus {
            scanning: false,
            done: 0,
            total: 0,
        },
        scene_count: 0,
        video_count: 0,
        webpage_count: 0,
        unknown_count: 0,
    };

    for entry in entries {
        match entry.kind {
            BridgeWallpaperKind::ProjectScene => snapshot.scene_count += 1,
            BridgeWallpaperKind::Video => snapshot.video_count += 1,
            BridgeWallpaperKind::Webpage => snapshot.webpage_count += 1,
            BridgeWallpaperKind::Unknown => snapshot.unknown_count += 1,
        }

        if visible(entry.kind) {
            let mut projected = entry.clone();
            projected.selected = selected == Some(entry.id.as_str());
            projected.active = active.iter().any(|id| id == &entry.id);
            snapshot.wallpapers.push(projected);
        }
    }

    snapshot
}

/// Measures each encountered path independently, following filesystem links.
/// Cyclic directory-link graphs have no finite-result guarantee.
pub(crate) fn directory_size(path: &std::path::Path) -> u64 {
    let Ok(metadata) = std::fs::metadata(path) else {
        return 0;
    };

    if metadata.is_file() {
        return metadata.len();
    }
    if !metadata.is_dir() {
        return 0;
    }

    let Ok(entries) = std::fs::read_dir(path) else {
        return 0;
    };
    let mut total = 0;
    for entry in entries {
        if let Ok(entry) = entry {
            total += directory_size(&entry.path());
        }
    }
    total
}

#[cfg(test)]
mod tests {
    use super::{directory_size, library_snapshot};
    use crate::api::{
        BridgeLibraryScanStatus, BridgeLibrarySnapshot, BridgeWallpaperEntry, BridgeWallpaperKind,
    };
    use std::fs;
    use std::path::PathBuf;

    fn entry(
        id: &str,
        title: &str,
        kind: BridgeWallpaperKind,
        supported: bool,
        active: bool,
        selected: bool,
        preview_path: Option<&str>,
    ) -> BridgeWallpaperEntry {
        BridgeWallpaperEntry {
            id: id.to_owned(),
            title: title.to_owned(),
            kind,
            supported,
            active,
            selected,
            preview_path: preview_path.map(str::to_owned),
        }
    }

    #[test]
    fn filtering_preserves_payload_order_and_counts_the_complete_inventory() {
        use BridgeWallpaperKind::{ProjectScene, Unknown, Video, Webpage};

        let entries = vec![
            entry(
                "scene",
                "Scene title",
                ProjectScene,
                true,
                true,
                true,
                Some("scene.png"),
            ),
            entry("hidden-video", "Video title", Video, true, true, true, None),
            entry(
                "page",
                "Page title",
                Webpage,
                false,
                false,
                false,
                Some("page preview.png"),
            ),
            entry("unknown", "Unknown title", Unknown, false, true, true, None),
            entry(
                "scene",
                "Duplicate ID, distinct payload",
                ProjectScene,
                false,
                false,
                false,
                None,
            ),
        ];
        let original = entries.clone();
        let active = vec!["page".to_owned(), "hidden-video".to_owned()];
        let original_active = active.clone();

        let snapshot = library_snapshot(&entries, Some("scene"), &active, |kind| {
            matches!(kind, ProjectScene | Webpage)
        });

        assert_eq!(
            snapshot,
            BridgeLibrarySnapshot {
                wallpapers: vec![
                    entry(
                        "scene",
                        "Scene title",
                        ProjectScene,
                        true,
                        false,
                        true,
                        Some("scene.png")
                    ),
                    entry(
                        "page",
                        "Page title",
                        Webpage,
                        false,
                        true,
                        false,
                        Some("page preview.png")
                    ),
                    entry(
                        "scene",
                        "Duplicate ID, distinct payload",
                        ProjectScene,
                        false,
                        false,
                        true,
                        None
                    ),
                ],
                scan_status: BridgeLibraryScanStatus {
                    scanning: false,
                    done: 0,
                    total: 0
                },
                scene_count: 2,
                video_count: 1,
                webpage_count: 1,
                unknown_count: 1,
            }
        );
        assert_eq!(entries, original);
        assert_eq!(active, original_active);
    }

    #[test]
    fn absent_selection_clears_flags_and_multiple_active_ids_use_exact_equality() {
        use BridgeWallpaperKind::{ProjectScene, Unknown, Video, Webpage};

        let entries = vec![
            entry("A", "First", Video, true, false, true, Some("first.jpg")),
            entry("B", "Second", Webpage, false, false, true, None),
            entry("a", "Case differs", ProjectScene, true, true, true, None),
            entry(
                " A",
                "Space differs",
                Unknown,
                false,
                true,
                true,
                Some("last.jpg"),
            ),
        ];
        let original = entries.clone();
        let active = vec!["A".to_owned(), "B".to_owned(), "missing".to_owned()];
        let original_active = active.clone();

        let snapshot = library_snapshot(&entries, None, &active, |_| true);

        assert_eq!(
            snapshot.wallpapers,
            vec![
                entry("A", "First", Video, true, true, false, Some("first.jpg")),
                entry("B", "Second", Webpage, false, true, false, None),
                entry("a", "Case differs", ProjectScene, true, false, false, None),
                entry(
                    " A",
                    "Space differs",
                    Unknown,
                    false,
                    false,
                    false,
                    Some("last.jpg")
                ),
            ]
        );
        assert_eq!(entries, original);
        assert_eq!(active, original_active);
    }

    #[test]
    fn empty_and_fully_filtered_inventories_have_no_visible_records() {
        use BridgeWallpaperKind::Unknown;

        let empty = library_snapshot(&[], Some("missing"), &[], |_| true);
        assert_eq!(
            empty,
            BridgeLibrarySnapshot {
                wallpapers: vec![],
                scan_status: BridgeLibraryScanStatus {
                    scanning: false,
                    done: 0,
                    total: 0
                },
                scene_count: 0,
                video_count: 0,
                webpage_count: 0,
                unknown_count: 0,
            }
        );
        let entries = [entry("missing", "Hidden", Unknown, false, true, true, None)];
        let hidden = library_snapshot(&entries, Some("missing"), &["missing".to_owned()], |_| {
            false
        });
        assert!(hidden.wallpapers.is_empty());
        assert_eq!(hidden.unknown_count, 1);
    }

    fn temporary_root() -> (tempfile::TempDir, PathBuf) {
        let owner = tempfile::tempdir().expect("create isolated system-temp directory");
        let root = owner
            .path()
            .canonicalize()
            .expect("canonicalize new temporary root");
        (owner, root)
    }

    #[test]
    fn sums_explicit_file_lengths_and_nested_directories() {
        let (_owner, root) = temporary_root();
        fs::create_dir_all(root.join("nested/deeper")).expect("create nested directories");
        fs::create_dir(root.join("empty-directory")).expect("create empty directory");
        fs::write(root.join("root-file"), b"12345").expect("write five bytes");
        fs::write(root.join("nested/file"), b"1234567").expect("write seven bytes");
        fs::write(root.join("nested/deeper/file"), b"12345678901").expect("write eleven bytes");
        fs::write(root.join("nested/zero"), b"").expect("write empty file");

        assert_eq!(directory_size(&root.join("root-file")), 5);
        assert_eq!(directory_size(&root.join("nested/zero")), 0);
        assert_eq!(directory_size(&root.join("empty-directory")), 0);
        assert_eq!(directory_size(&root.join("nested")), 18);
        assert_eq!(directory_size(&root), 23);
        assert_eq!(directory_size(&root.join("missing")), 0);
        assert_eq!(directory_size(&root.join("root-file/not-a-directory")), 0);
    }

    #[cfg(unix)]
    #[test]
    fn repeated_file_links_and_directory_links_are_each_counted() {
        use std::os::unix::fs::symlink;

        let (_owner, root) = temporary_root();
        fs::create_dir(root.join("nested")).expect("create target directory");
        fs::write(root.join("file"), b"12345").expect("write five-byte target");
        fs::write(root.join("nested/file"), b"1234567").expect("write seven-byte descendant");
        fs::write(root.join("nested/zero"), b"").expect("write empty descendant");
        symlink("file", root.join("file-link-one")).expect("link first file path");
        symlink("file", root.join("file-link-two")).expect("link second file path");
        symlink("nested", root.join("directory-link")).expect("link directory path");
        symlink("missing", root.join("broken-link")).expect("create broken link");

        assert_eq!(directory_size(&root.join("file-link-one")), 5);
        assert_eq!(directory_size(&root.join("file-link-two")), 5);
        assert_eq!(directory_size(&root.join("directory-link")), 7);
        assert_eq!(directory_size(&root.join("broken-link")), 0);
        // The original five-byte file and both links each contribute five;
        // the original seven-byte directory and its link each contribute seven.
        assert_eq!(directory_size(&root), 29);
    }
}
