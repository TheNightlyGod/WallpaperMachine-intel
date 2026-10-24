use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use image::{ImageError, ImageFormat, Rgba, RgbaImage};
use tempfile::TempDir;
use wallpaper_core::project::WallpaperProjectType as Kind;

use crate::BridgeErrorKind;
use crate::config::FilterCfg;
use crate::project::ProjectModel;

use super::scanner::test_controls::{Failures, with_failures};
use super::{
    ThumbKey, ThumbnailCache, ThumbnailRgba, TypeFilter, WallpaperEntry, decode_and_crop,
    resolve_preview, scan,
};

fn sandbox() -> TempDir {
    let root = std::env::temp_dir();
    assert!(root.is_absolute());
    tempfile::Builder::new()
        .prefix("wallpaper-library-contract-")
        .tempdir_in(root)
        .unwrap()
}

fn project(root: &Path, id: &str, json: &str) -> PathBuf {
    let folder = root.join(id);
    fs::create_dir_all(&folder).unwrap();
    fs::write(folder.join("project.json"), json).unwrap();
    folder
}

fn mtime(path: &Path) -> Option<SystemTime> {
    fs::metadata(path).ok()?.modified().ok()
}

fn expected_entry(
    folder: &Path,
    title: &str,
    kind: Kind,
    preview: Option<PathBuf>,
) -> WallpaperEntry {
    WallpaperEntry {
        workshop_id: folder.file_name().unwrap().to_string_lossy().into_owned(),
        title: title.to_owned(),
        project_type: kind,
        preview_mtime: preview.as_deref().and_then(mtime),
        preview_path: preview,
        project_json_mtime: mtime(&folder.join("project.json")),
        supported: kind != Kind::Unknown,
    }
}

#[derive(Debug, PartialEq, Eq)]
enum Node {
    Directory(SystemTime),
    File(Vec<u8>, SystemTime),
    Link(PathBuf, SystemTime),
}

fn tree_state(root: &Path) -> Vec<(PathBuf, Node)> {
    fn visit(root: &Path, path: &Path, nodes: &mut Vec<(PathBuf, Node)>) {
        let metadata = fs::symlink_metadata(path).unwrap();
        let modified = metadata.modified().unwrap();
        let node = if metadata.file_type().is_symlink() {
            Node::Link(fs::read_link(path).unwrap(), modified)
        } else if metadata.is_dir() {
            Node::Directory(modified)
        } else {
            Node::File(fs::read(path).unwrap(), modified)
        };
        nodes.push((path.strip_prefix(root).unwrap().to_owned(), node));
        if metadata.is_dir() {
            for child in fs::read_dir(path).unwrap() {
                visit(root, &child.unwrap().path(), nodes);
            }
        }
    }
    let mut nodes = Vec::new();
    visit(root, root, &mut nodes);
    nodes.sort_by(|left, right| left.0.cmp(&right.0));
    nodes
}

#[test]
fn root_absence_regular_file_empty_directory_and_listing_error_are_distinct() {
    let temp = sandbox();
    let missing = temp.path().join("absent-root");
    let error = scan(&missing).unwrap_err();
    assert_eq!(error.kind(), BridgeErrorKind::Library);
    assert!(error.message().contains(&missing.display().to_string()));

    let regular = temp.path().join("ordinary-file");
    fs::write(&regular, b"not a directory").unwrap();
    let before = tree_state(temp.path());
    let error = scan(&regular).unwrap_err();
    assert_eq!(error.kind(), BridgeErrorKind::Io);
    assert!(error.message().contains(&regular.display().to_string()));
    assert!(scan(temp.path()).unwrap().is_empty());

    let error = with_failures(
        Failures {
            listing: Some(temp.path().to_owned()),
            ..Failures::default()
        },
        || scan(temp.path()).unwrap_err(),
    );
    assert_eq!(error.kind(), BridgeErrorKind::Io);
    assert!(error.message().contains(&temp.path().display().to_string()));
    let error = with_failures(
        Failures {
            listing: Some(missing.clone()),
            ..Failures::default()
        },
        || scan(&missing).unwrap_err(),
    );
    assert_eq!(error.kind(), BridgeErrorKind::Library);
    assert!(scan(temp.path()).unwrap().is_empty());
    assert_eq!(tree_state(temp.path()), before);
}

#[test]
fn stable_mixed_inventory_excludes_bad_and_nested_projects_without_filtering_kinds() {
    let temp = sandbox();
    let root = temp.path();
    let a = project(
        root,
        "10",
        r#"{"title":"  authored title  ","type":"ScEnE","preview":"bad-image.png"}"#,
    );
    fs::write(
        a.join("bad-image.png"),
        b"not an image; scanning must not decode it",
    )
    .unwrap();
    let b = project(root, "2", r#"{"title":"Movie","type":"VIDEO"}"#);
    let c = project(root, "alpha", r#"{"title":"Browser","type":"web"}"#);
    let d = project(root, "beta", r#"{"title":37,"type":" scene "}"#);
    let e = project(root, "delta", r#"{"title":"Unknown kind","type":"opaque"}"#);
    let f = project(root, "epsilon", r#"{}"#);
    let g = project(root, "gamma", r#"{"title":"No string kind","type":false}"#);
    fs::write(root.join("plain-child"), b"ordinary").unwrap();
    fs::create_dir(root.join("without-manifest")).unwrap();
    fs::create_dir_all(root.join("manifest-directory/project.json")).unwrap();
    project(root, "invalid-json", "{broken");
    project(root, "non-object", "[1,2]");
    let invalid_utf8 = project(root, "invalid-utf8", "{}");
    fs::write(invalid_utf8.join("project.json"), [0xff, 0xfe, b'{']).unwrap();
    project(
        &root.join("container"),
        "nested-good",
        r#"{"type":"scene"}"#,
    );

    let before = tree_state(root);
    let expected = vec![
        expected_entry(
            &a,
            "  authored title  ",
            Kind::Scene,
            Some(a.join("bad-image.png")),
        ),
        expected_entry(&b, "Movie", Kind::Video, None),
        expected_entry(&c, "Browser", Kind::Web, None),
        expected_entry(&d, "", Kind::Unknown, None),
        expected_entry(&e, "Unknown kind", Kind::Unknown, None),
        expected_entry(&f, "", Kind::Unknown, None),
        expected_entry(&g, "No string kind", Kind::Unknown, None),
    ];
    assert_eq!(scan(root).unwrap(), expected);
    assert_eq!(tree_state(root), before);
}

#[test]
fn enumeration_and_file_type_errors_preserve_real_usable_siblings_and_files() {
    let temp = sandbox();
    let a = project(temp.path(), "a", r#"{"title":"Left","type":"scene"}"#);
    let b = project(temp.path(), "b", r#"{"title":"Middle","type":"video"}"#);
    let c = project(temp.path(), "c", r#"{"title":"Right","type":"web"}"#);
    let before = tree_state(temp.path());
    let left = expected_entry(&a, "Left", Kind::Scene, None);
    let middle = expected_entry(&b, "Middle", Kind::Video, None);
    let right = expected_entry(&c, "Right", Kind::Web, None);
    let without_middle = vec![left.clone(), right.clone()];
    assert_eq!(
        with_failures(
            Failures {
                enumeration: Some(b.clone()),
                ..Failures::default()
            },
            || scan(temp.path()).unwrap(),
        ),
        without_middle,
    );
    assert_eq!(
        with_failures(
            Failures {
                file_type: Some(b),
                ..Failures::default()
            },
            || scan(temp.path()).unwrap(),
        ),
        without_middle,
    );
    assert_eq!(scan(temp.path()).unwrap(), vec![left, middle, right]);
    assert_eq!(tree_state(temp.path()), before);
}

#[test]
fn scoped_controls_restore_nested_state_and_unwind_without_leaking_to_another_thread() {
    let temp = sandbox();
    let folder = project(temp.path(), "actual", r#"{"title":"Real","type":"web"}"#);
    let expected = vec![expected_entry(&folder, "Real", Kind::Web, None)];
    let root = temp.path().to_owned();
    with_failures(
        Failures {
            listing: Some(root.clone()),
            ..Failures::default()
        },
        || {
            assert_eq!(scan(&root).unwrap_err().kind(), BridgeErrorKind::Io);
            assert_eq!(
                with_failures(Failures::default(), || scan(&root).unwrap()),
                expected,
            );
            assert_eq!(scan(&root).unwrap_err().kind(), BridgeErrorKind::Io);
            std::thread::scope(|scope| {
                assert_eq!(
                    scope.spawn(|| scan(&root).unwrap()).join().unwrap(),
                    expected
                );
            });
        },
    );
    let unwind = std::panic::catch_unwind(|| {
        with_failures(
            Failures {
                listing: Some(root.clone()),
                ..Failures::default()
            },
            || panic!("exercise scope restoration"),
        );
    });
    assert!(unwind.is_err());
    assert_eq!(scan(&root).unwrap(), expected);
}

#[cfg(unix)]
#[test]
fn unix_links_keep_root_and_file_link_support_but_exclude_directory_children() {
    use std::os::unix::fs::symlink;

    let temp = sandbox();
    let root = temp.path().join("library");
    fs::create_dir(&root).unwrap();
    let outside = project(
        temp.path(),
        "outside",
        r#"{"title":"Linked manifest","type":"web","preview":"poster.png"}"#,
    );
    fs::write(outside.join("poster.png"), b"preview target").unwrap();
    symlink(&outside, root.join("directory-link")).unwrap();
    let admitted = root.join("file-links");
    fs::create_dir(&admitted).unwrap();
    symlink(outside.join("project.json"), admitted.join("project.json")).unwrap();
    symlink(outside.join("poster.png"), admitted.join("poster.png")).unwrap();
    let broken = root.join("broken-manifest");
    fs::create_dir(&broken).unwrap();
    symlink(temp.path().join("no-target"), broken.join("project.json")).unwrap();
    symlink(
        temp.path().join("no-directory"),
        root.join("broken-directory"),
    )
    .unwrap();
    let root_link = temp.path().join("root-link");
    symlink(&root, &root_link).unwrap();
    let broken_root = temp.path().join("broken-root");
    symlink(temp.path().join("no-root"), &broken_root).unwrap();
    let before = tree_state(temp.path());

    assert_eq!(
        scan(&root).unwrap(),
        vec![expected_entry(
            &admitted,
            "Linked manifest",
            Kind::Web,
            Some(admitted.join("poster.png"))
        )],
    );
    let linked_folder = root_link.join("file-links");
    assert_eq!(
        scan(&root_link).unwrap(),
        vec![expected_entry(
            &linked_folder,
            "Linked manifest",
            Kind::Web,
            Some(linked_folder.join("poster.png"))
        )],
    );
    let error = scan(&broken_root).unwrap_err();
    assert_eq!(error.kind(), BridgeErrorKind::Library);
    assert!(error.message().contains(&broken_root.display().to_string()));
    assert_eq!(tree_state(temp.path()), before);
}

#[cfg(unix)]
#[test]
fn controlled_filename_values_preserve_lossy_collisions_and_title_order_with_real_files() {
    use std::ffi::OsString;
    use std::os::unix::ffi::OsStringExt;

    let temp = sandbox();
    let first = project(
        temp.path(),
        "physical-a",
        r#"{"title":"Zulu","type":"video","preview":"first.png"}"#,
    );
    let second = project(
        temp.path(),
        "physical-b",
        r#"{"title":"Alpha","type":"scene","preview":"second.png"}"#,
    );
    fs::write(first.join("first.png"), b"first actual preview bytes").unwrap();
    fs::write(second.join("second.png"), b"different second preview bytes").unwrap();
    let before = tree_state(temp.path());
    let physical = vec![
        expected_entry(&first, "Zulu", Kind::Video, Some(first.join("first.png"))),
        expected_entry(
            &second,
            "Alpha",
            Kind::Scene,
            Some(second.join("second.png")),
        ),
    ];
    let mut expected = vec![physical[1].clone(), physical[0].clone()];
    for entry in &mut expected {
        entry.workshop_id = "x\u{fffd}".to_owned();
    }
    let filename_values = || {
        vec![
            (first.clone(), OsString::from_vec(vec![b'x', 0xff])),
            (second.clone(), OsString::from_vec(vec![b'x', 0xfe])),
        ]
    };
    assert_eq!(scan(temp.path()).unwrap(), physical);
    let actual = with_failures(
        Failures {
            file_names: filename_values(),
            ..Failures::default()
        },
        || {
            assert_eq!(
                with_failures(Failures::default(), || scan(temp.path()).unwrap()),
                physical,
            );
            std::thread::scope(|scope| {
                assert_eq!(
                    scope.spawn(|| scan(temp.path()).unwrap()).join().unwrap(),
                    physical
                );
            });
            scan(temp.path()).unwrap()
        },
    );
    assert_eq!(actual, expected);
    assert_eq!(actual[0].workshop_id, "x\u{fffd}");
    assert_eq!(actual[0].workshop_id, actual[1].workshop_id);
    assert_eq!(actual[0].title, "Alpha");
    assert_eq!(actual[1].title, "Zulu");
    let unwind = std::panic::catch_unwind(|| {
        with_failures(
            Failures {
                file_names: filename_values(),
                ..Failures::default()
            },
            || panic!("restore controlled filename values on unwind"),
        );
    });
    assert!(unwind.is_err());
    assert_eq!(scan(temp.path()).unwrap(), physical);
    assert_eq!(tree_state(temp.path()), before);
}

#[test]
fn authored_preview_values_are_not_replaced_by_fallbacks_or_containment_rules() {
    let temp = sandbox();
    let root = temp.path().join("library");
    fs::create_dir(&root).unwrap();
    let absent = project(&root, "a-absent", r#"{"type":"scene"}"#);
    fs::write(absent.join("preview.gif"), b"fallback must stay separate").unwrap();
    let nonstring = project(&root, "b-nonstring", r#"{"preview":14,"type":"video"}"#);
    let empty = project(&root, "c-empty", r#"{"preview":"","type":"web"}"#);
    let relative = project(
        &root,
        "d-relative",
        r#"{"preview":"art/card.png","type":"scene"}"#,
    );
    fs::create_dir(relative.join("art")).unwrap();
    fs::write(relative.join("art/card.png"), b"existing preview").unwrap();
    let absolute_preview = temp.path().join("absolute.png");
    fs::write(&absolute_preview, b"absolute preview").unwrap();
    let absolute_json = format!(
        r#"{{"preview":{},"type":"video"}}"#,
        serde_json::to_string(&absolute_preview.to_string_lossy()).unwrap()
    );
    let absolute = project(&root, "e-absolute", &absolute_json);
    fs::write(root.join("shared.png"), b"parent-component preview").unwrap();
    let parent = project(
        &root,
        "f-parent",
        r#"{"preview":"../shared.png","type":"web"}"#,
    );
    let missing = project(
        &root,
        "g-missing",
        r#"{"preview":"gone.png","type":"unknown"}"#,
    );
    let before = tree_state(temp.path());
    assert_eq!(
        scan(&root).unwrap(),
        vec![
            expected_entry(&absent, "", Kind::Scene, None),
            expected_entry(&nonstring, "", Kind::Video, None),
            expected_entry(&empty, "", Kind::Web, Some(empty.join(""))),
            expected_entry(
                &relative,
                "",
                Kind::Scene,
                Some(relative.join("art/card.png"))
            ),
            expected_entry(&absolute, "", Kind::Video, Some(absolute_preview)),
            expected_entry(&parent, "", Kind::Web, Some(parent.join("../shared.png"))),
            expected_entry(&missing, "", Kind::Unknown, Some(missing.join("gone.png"))),
        ],
    );
    assert_eq!(resolve_preview(&absent), Some(absent.join("preview.gif")));
    assert_eq!(tree_state(temp.path()), before);
}

#[test]
fn standalone_preview_priority_requires_regular_files_and_observes_every_candidate() {
    let temp = sandbox();
    let names = ["preview.gif", "preview.jpg", "preview.jpeg", "preview.png"];
    assert_eq!(resolve_preview(temp.path()), None);
    for name in names.into_iter().rev() {
        fs::write(temp.path().join(name), b"lookup does not decode").unwrap();
        let before = tree_state(temp.path());
        assert_eq!(resolve_preview(temp.path()), Some(temp.path().join(name)));
        assert_eq!(tree_state(temp.path()), before);
    }
    for name in names {
        fs::remove_file(temp.path().join(name)).unwrap();
        fs::create_dir(temp.path().join(name)).unwrap();
        let expected = names
            .iter()
            .skip_while(|candidate| **candidate != name)
            .nth(1);
        assert_eq!(
            resolve_preview(temp.path()),
            expected.map(|name| temp.path().join(name))
        );
    }
    assert_eq!(resolve_preview(&temp.path().join("missing")), None);
}

#[cfg(unix)]
#[test]
fn standalone_preview_accepts_file_links_but_not_broken_or_directory_links() {
    use std::os::unix::fs::symlink;

    let temp = sandbox();
    let folder = temp.path().join("candidates");
    fs::create_dir(&folder).unwrap();
    let target = temp.path().join("pixels");
    fs::write(&target, b"regular target").unwrap();
    symlink(temp.path().join("missing"), folder.join("preview.gif")).unwrap();
    symlink(temp.path(), folder.join("preview.jpg")).unwrap();
    symlink(&target, folder.join("preview.jpeg")).unwrap();
    fs::write(folder.join("preview.png"), b"lower priority").unwrap();
    let before = tree_state(temp.path());
    assert_eq!(resolve_preview(&folder), Some(folder.join("preview.jpeg")));
    assert_eq!(tree_state(temp.path()), before);
}

#[test]
fn real_models_convert_all_kinds_without_changing_owned_fields() {
    let cases = [
        ("scene", Kind::Scene, true),
        ("ViDeO", Kind::Video, true),
        ("WEB", Kind::Web, true),
        ("other", Kind::Unknown, false),
        (" web ", Kind::Unknown, false),
    ];
    for (spelling, kind, supported) in cases {
        let json = format!(r#"{{"title":"  full title  ","type":"{spelling}"}}"#);
        let model = ProjectModel::parse("nonnumeric/id", &json).unwrap();
        let before = model.clone();
        assert_eq!(
            WallpaperEntry::from_model(&model),
            WallpaperEntry {
                workshop_id: "nonnumeric/id".into(),
                title: "  full title  ".into(),
                project_type: kind,
                preview_path: None,
                preview_mtime: None,
                project_json_mtime: None,
                supported,
            },
        );
        assert_eq!(model, before);
    }

    let temp = sandbox();
    let folder = project(
        temp.path(),
        "anchored",
        r#"{"title":"Path","type":"web","preview":"relative.png"}"#,
    );
    fs::write(folder.join("relative.png"), b"metadata only").unwrap();
    let raw = ProjectModel::parse("raw", r#"{"preview":"relative.png"}"#).unwrap();
    assert_eq!(raw.preview_file, Some(PathBuf::from("relative.png")));
    let loaded = ProjectModel::load("loaded", folder.join("project.json")).unwrap();
    assert_eq!(loaded.preview_file, Some(folder.join("relative.png")));
    let entry = WallpaperEntry::from_model(&loaded);
    assert_eq!(entry.workshop_id, "loaded");
    assert_eq!(entry.title, "Path");
    assert_eq!(entry.project_type, Kind::Web);
    assert!(entry.supported);
    assert_eq!(entry.preview_path, Some(folder.join("relative.png")));
    assert_eq!(entry.preview_mtime, mtime(&folder.join("relative.png")));
    assert_eq!(entry.project_json_mtime, None);
}

#[test]
fn metadata_and_modified_failures_are_nonfatal_and_do_not_change_other_observations() {
    let temp = sandbox();
    let folder = project(
        temp.path(),
        "entry",
        r#"{"title":"Metadata","type":"web","preview":"poster"}"#,
    );
    let preview = folder.join("poster");
    fs::write(&preview, b"existing bytes").unwrap();
    let manifest = folder.join("project.json");
    let before = tree_state(temp.path());
    let expected = expected_entry(&folder, "Metadata", Kind::Web, Some(preview.clone()));
    assert!(expected.preview_mtime.is_some());
    assert!(expected.project_json_mtime.is_some());
    assert_eq!(scan(temp.path()).unwrap(), vec![expected.clone()]);
    for failures in [
        Failures {
            metadata: Some(preview.clone()),
            ..Failures::default()
        },
        Failures {
            modified: Some(preview.clone()),
            ..Failures::default()
        },
    ] {
        let mut missing_preview_time = expected.clone();
        missing_preview_time.preview_mtime = None;
        assert_eq!(
            with_failures(failures, || scan(temp.path()).unwrap()),
            vec![missing_preview_time],
        );
    }
    for failures in [
        Failures {
            metadata: Some(manifest.clone()),
            ..Failures::default()
        },
        Failures {
            modified: Some(manifest),
            ..Failures::default()
        },
    ] {
        let mut missing_manifest_time = expected.clone();
        missing_manifest_time.project_json_mtime = None;
        assert_eq!(
            with_failures(failures, || scan(temp.path()).unwrap()),
            vec![missing_manifest_time],
        );
    }
    assert_eq!(scan(temp.path()).unwrap(), vec![expected]);
    assert_eq!(tree_state(temp.path()), before);

    for path in [
        preview.clone(),
        folder.clone(),
        temp.path().join("missing-preview"),
    ] {
        let mut model = ProjectModel::parse("direct", r#"{"type":"scene"}"#).unwrap();
        model.preview_file = Some(path.clone());
        let entry = WallpaperEntry::from_model(&model);
        assert_eq!(entry.preview_path, Some(path.clone()));
        assert_eq!(entry.preview_mtime, mtime(&path));
        assert_eq!(entry.project_json_mtime, None);
        assert!(entry.supported);
    }
}

#[test]
fn every_filter_configuration_round_trips_and_accepts_only_by_kind() {
    let all = FilterCfg {
        scene: true,
        video: true,
        web: true,
        unknown: true,
    };
    assert_eq!(FilterCfg::default(), all);
    assert_eq!(TypeFilter::default().to_config(), all);
    for mask in 0_u8..16 {
        let flags = [mask & 1 != 0, mask & 2 != 0, mask & 4 != 0, mask & 8 != 0];
        let config = FilterCfg {
            scene: flags[0],
            video: flags[1],
            web: flags[2],
            unknown: flags[3],
        };
        let filter = TypeFilter::from_config(&config);
        assert_eq!(
            filter,
            TypeFilter {
                scene: flags[0],
                video: flags[1],
                web: flags[2],
                unknown: flags[3]
            },
        );
        assert_eq!(filter.to_config(), config);
        for (index, kind) in [Kind::Scene, Kind::Video, Kind::Web, Kind::Unknown]
            .into_iter()
            .enumerate()
        {
            for supported in [false, true] {
                let entry = WallpaperEntry {
                    workshop_id: "irrelevant".into(),
                    title: "  independently owned  ".into(),
                    project_type: kind,
                    preview_path: Some(PathBuf::from("/not-observed-by-filter")),
                    preview_mtime: Some(UNIX_EPOCH + Duration::from_secs(17)),
                    project_json_mtime: None,
                    supported,
                };
                assert_eq!(filter.accepts(&entry), flags[index]);
            }
        }
        let mut independently_owned = filter.to_config();
        independently_owned.scene = !independently_owned.scene;
        assert_ne!(independently_owned, config);
        assert_eq!(filter.to_config(), config);
        let mut independently_owned_filter = TypeFilter::from_config(&config);
        independently_owned_filter.web = !independently_owned_filter.web;
        assert_eq!(TypeFilter::from_config(&config), filter);
    }
}

fn key(id: &str, seconds: Option<u64>) -> ThumbKey {
    ThumbKey {
        id: id.to_owned(),
        mtime: seconds.map(|seconds| UNIX_EPOCH + Duration::from_secs(seconds)),
    }
}

fn payload(marker: u8) -> ThumbnailRgba {
    ThumbnailRgba {
        width: 0,
        height: 37,
        rgba: vec![marker, 0, 255],
    }
}

#[test]
fn zero_and_one_capacity_caches_preserve_exact_payloads_and_owned_returns() {
    let a = key("a", None);
    let b = key("b", Some(2));
    let mut zero = ThumbnailCache::new(0);
    zero.insert(a.clone(), payload(1));
    assert_eq!(zero.get(&a), None);
    assert_eq!(zero.peek(&a), None);

    let mut one = ThumbnailCache::new(1);
    assert_eq!(one.get(&a), None);
    assert_eq!(one.peek(&a), None);
    let mut original = payload(11);
    one.insert(a.clone(), original.clone());
    original.width = 98;
    original.rgba.clear();
    assert_eq!(one.peek(&a), Some(payload(11)));
    let mut returned = one.get(&a).unwrap();
    returned.rgba[0] = 99;
    returned.width = 400;
    assert_eq!(one.get(&a), Some(payload(11)));
    let mut peeked = one.peek(&a).unwrap();
    peeked.height = 0;
    peeked.rgba.push(13);
    assert_eq!(one.peek(&a), Some(payload(11)));
    one.insert(
        a.clone(),
        ThumbnailRgba {
            width: u32::MAX,
            height: 0,
            rgba: Vec::new(),
        },
    );
    assert_eq!(
        one.get(&a),
        Some(ThumbnailRgba {
            width: u32::MAX,
            height: 0,
            rgba: Vec::new()
        })
    );
    one.insert(b.clone(), payload(12));
    assert_eq!(one.peek(&a), None);
    assert_eq!(one.get(&b), Some(payload(12)));
}

#[test]
fn cache_get_promotes_peek_does_not_and_replacement_is_most_recent() {
    let [a, b, c, d] = [
        key("a", None),
        key("b", None),
        key("c", None),
        key("d", None),
    ];
    let mut cache = ThumbnailCache::new(3);
    cache.insert(a.clone(), payload(1));
    cache.insert(b.clone(), payload(2));
    cache.insert(c.clone(), payload(3));
    assert_eq!(cache.peek(&a), Some(payload(1)));
    assert_eq!(cache.peek(&a), Some(payload(1)));
    cache.insert(d.clone(), payload(4));
    assert_eq!(cache.peek(&a), None);
    assert_eq!(cache.peek(&b), Some(payload(2)));
    assert_eq!(cache.get(&b), Some(payload(2)));
    assert_eq!(cache.get(&b), Some(payload(2)));
    cache.insert(a.clone(), payload(5));
    assert_eq!(cache.peek(&c), None);
    assert_eq!(cache.peek(&d), Some(payload(4)));
    assert_eq!(cache.peek(&b), Some(payload(2)));
    cache.insert(d.clone(), payload(40));
    cache.insert(c.clone(), payload(30));
    assert_eq!(cache.peek(&b), None);
    assert_eq!(cache.peek(&a), Some(payload(5)));
    assert_eq!(cache.peek(&d), Some(payload(40)));
    assert_eq!(cache.peek(&c), Some(payload(30)));
    for marker in 41..45 {
        cache.insert(d.clone(), payload(marker));
        assert_eq!(cache.get(&d), Some(payload(marker)));
    }
    cache.insert(b.clone(), payload(20));
    assert_eq!(cache.peek(&a), None);
    assert_eq!(cache.peek(&c), Some(payload(30)));
    assert_eq!(cache.peek(&d), Some(payload(44)));
    assert_eq!(cache.peek(&b), Some(payload(20)));
}

#[test]
fn cache_keys_include_id_and_optional_timestamp_without_cross_key_invalidation() {
    let keys = [
        key("same", None),
        key("same", Some(1)),
        key("same", Some(2)),
        key("other", Some(1)),
    ];
    let mut cache = ThumbnailCache::new(4);
    for (index, key) in keys.iter().enumerate() {
        cache.insert(key.clone(), payload(index as u8));
    }
    for (index, key) in keys.iter().enumerate() {
        assert_eq!(cache.peek(key), Some(payload(index as u8)));
    }
    assert_eq!(cache.get(&key("same", Some(3))), None);
    assert_eq!(cache.get(&key("other", None)), None);
    cache.insert(keys[1].clone(), payload(99));
    assert_eq!(cache.peek(&keys[0]), Some(payload(0)));
    assert_eq!(cache.peek(&keys[1]), Some(payload(99)));
    assert_eq!(cache.peek(&keys[2]), Some(payload(2)));
    assert_eq!(cache.peek(&keys[3]), Some(payload(3)));
    cache.insert(key("fifth", None), payload(5));
    assert_eq!(cache.peek(&keys[0]), None);
    assert_eq!(cache.peek(&keys[1]), Some(payload(99)));
}

fn source_pixel(x: u32, y: u32) -> [u8; 4] {
    [
        ((17 * x + 3 * y + 19) % 256) as u8,
        ((5 * x + 29 * y + 71) % 256) as u8,
        ((x * y + 11 * x + 7 * y + 43) % 256) as u8,
        ((13 * x + 23 * y) % 256) as u8,
    ]
}

fn assert_shape(thumbnail: &ThumbnailRgba) {
    assert_eq!(thumbnail.width, 200);
    assert_eq!(thumbnail.height, 200);
    assert_eq!(thumbnail.rgba.len(), 160_000);
}

#[test]
fn png_exact_geometry_preserves_orientation_alpha_and_integer_centering() {
    let temp = sandbox();
    for (index, (width, height, left, top)) in [
        (200, 200, 0, 0),
        (208, 200, 4, 0),
        (207, 200, 3, 0),
        (200, 210, 0, 5),
        (200, 209, 0, 4),
    ]
    .into_iter()
    .enumerate()
    {
        let image = RgbaImage::from_fn(width, height, |x, y| Rgba(source_pixel(x, y)));
        let path = temp.path().join(format!("case-{index}.wrong-extension"));
        image.save_with_format(&path, ImageFormat::Png).unwrap();
        let before = tree_state(temp.path());
        let actual = decode_and_crop(&path).unwrap();
        assert_shape(&actual);
        let mut expected = Vec::with_capacity(160_000);
        for y in 0..200 {
            for x in 0..200 {
                expected.extend_from_slice(&source_pixel(x + left, y + top));
            }
        }
        assert_eq!(actual.rgba, expected, "geometry case {index}");
        assert_eq!(tree_state(temp.path()), before);
    }
}

#[test]
fn constant_png_upscale_preserves_every_rgba_channel() {
    let temp = sandbox();
    let path = temp.path().join("constant.gif");
    let color = [73, 151, 29, 91];
    RgbaImage::from_fn(5, 3, |_, _| Rgba(color))
        .save_with_format(&path, ImageFormat::Png)
        .unwrap();
    let before = tree_state(temp.path());
    let actual = decode_and_crop(&path).unwrap();
    assert_shape(&actual);
    assert_eq!(actual.rgba, color.repeat(40_000));
    assert_eq!(tree_state(temp.path()), before);
}

#[test]
fn gif_content_detection_uses_first_frame_and_preserves_transparency() {
    for (first, second) in [
        ([255, 0, 0, 255], [0, 255, 0, 255]),
        ([0, 0, 0, 0], [0, 0, 255, 255]),
    ] {
        let temp = sandbox();
        let path = temp.path().join("animation.png");
        {
            let file = fs::File::create(&path).unwrap();
            let mut encoder = image::codecs::gif::GifEncoder::new(file);
            encoder
                .encode_frame(image::Frame::new(RgbaImage::from_fn(4, 3, |_, _| {
                    Rgba(first)
                })))
                .unwrap();
            encoder
                .encode_frame(image::Frame::new(RgbaImage::from_fn(4, 3, |_, _| {
                    Rgba(second)
                })))
                .unwrap();
        }
        let before = tree_state(temp.path());
        let actual = decode_and_crop(&path).unwrap();
        assert_shape(&actual);
        assert_eq!(actual.rgba, first.repeat(40_000));
        assert_eq!(tree_state(temp.path()), before);
    }
}

#[test]
fn decoder_errors_keep_image_error_classes_and_never_mutate_inputs_or_inventory() {
    let temp = sandbox();
    let missing = temp.path().join("missing.png");
    let before = tree_state(temp.path());
    match decode_and_crop(&missing).unwrap_err() {
        ImageError::IoError(error) => assert_eq!(error.kind(), std::io::ErrorKind::NotFound),
        other => panic!("missing file must remain an IO error, got {other:?}"),
    }
    assert_eq!(tree_state(temp.path()), before);

    let directory = temp.path().join("directory.png");
    fs::create_dir(&directory).unwrap();
    let unknown = temp.path().join("unknown.png");
    fs::write(&unknown, b"new synthetic bytes with no image signature").unwrap();
    let unsupported = temp.path().join("disabled-bmp.png");
    fs::write(&unsupported, [b'B', b'M', 0, 0, 0, 0, 0, 0]).unwrap();
    let truncated = temp.path().join("truncated.png");
    fs::write(&truncated, b"\x89PNG\r\n\x1a\n").unwrap();
    let before = tree_state(temp.path());
    assert!(matches!(
        decode_and_crop(&directory),
        Err(ImageError::IoError(_))
    ));
    assert!(matches!(
        decode_and_crop(&unknown),
        Err(ImageError::Unsupported(_))
    ));
    assert!(matches!(
        decode_and_crop(&unsupported),
        Err(ImageError::Unsupported(_))
    ));
    match decode_and_crop(&truncated).unwrap_err() {
        ImageError::IoError(error) => assert_eq!(error.kind(), std::io::ErrorKind::UnexpectedEof),
        other => panic!("signature-only PNG must retain its observed IO class, got {other:?}"),
    }
    assert_eq!(tree_state(temp.path()), before);
}

#[test]
fn empty_root_returns_an_empty_inventory_without_creating_files() {
    let temp = sandbox();
    let before = tree_state(temp.path());
    assert_eq!(scan(temp.path()).unwrap(), Vec::<WallpaperEntry>::new());
    assert_eq!(tree_state(temp.path()), before);
}

#[test]
fn entry_conversion_owns_strings_and_preview_independently_of_the_real_model() {
    let temp = sandbox();
    let preview = temp.path().join("preview");
    fs::write(&preview, b"stable metadata input").unwrap();
    let mut model =
        ProjectModel::parse("original", r#"{"title":"Original title","type":"web"}"#).unwrap();
    model.preview_file = Some(preview.clone());
    let before = tree_state(temp.path());
    let entry = WallpaperEntry::from_model(&model);
    model.workshop_id.clear();
    model.title.push_str(" changed");
    model.project_type = Kind::Unknown;
    model.preview_file = Some(temp.path().join("different"));
    assert_eq!(
        entry,
        WallpaperEntry {
            workshop_id: "original".into(),
            title: "Original title".into(),
            project_type: Kind::Web,
            preview_path: Some(preview.clone()),
            preview_mtime: mtime(&preview),
            project_json_mtime: None,
            supported: true,
        },
    );
    assert_eq!(tree_state(temp.path()), before);
}

#[test]
fn unrecognized_contents_never_select_a_decoder_from_an_enabled_filename_extension() {
    let temp = sandbox();
    let bytes = b"independently authored content with no image signature";
    for name in [
        "unrecognized.png",
        "unrecognized.jpg",
        "unrecognized.jpeg",
        "unrecognized.gif",
        "unrecognized",
    ] {
        let path = temp.path().join(name);
        fs::write(&path, bytes).unwrap();
        let before = tree_state(temp.path());
        assert!(matches!(
            decode_and_crop(&path),
            Err(ImageError::Unsupported(_))
        ));
        assert_eq!(tree_state(temp.path()), before);
    }
}

fn low_byte(value: u32) -> u8 {
    (value & 255) as u8
}

fn fnv1a64(bytes: &[u8]) -> u64 {
    bytes.iter().fold(0xcbf29ce484222325_u64, |hash, byte| {
        (hash ^ u64::from(*byte)).wrapping_mul(0x100000001b)
    })
}

fn assert_numeric_reference(path: &Path, fingerprint: u64, samples: [[u8; 4]; 10]) {
    let actual = decode_and_crop(path).unwrap();
    assert_shape(&actual);
    assert_eq!(
        fnv1a64(&actual.rgba),
        fingerprint,
        "whole-buffer reference for {}",
        path.display()
    );
    let coordinates = [
        (0, 0),
        (199, 0),
        (0, 199),
        (199, 199),
        (100, 100),
        (99, 101),
        (1, 198),
        (198, 1),
        (37, 151),
        (151, 37),
    ];
    for ((x, y), expected) in coordinates.into_iter().zip(samples) {
        let offset = (y * 200 + x) * 4;
        assert_eq!(
            &actual.rgba[offset..offset + 4],
            expected.as_slice(),
            "reference pixel ({x}, {y}) for {}",
            path.display(),
        );
    }
}

#[test]
fn frozen_original_api_references_cover_nonconstant_png_jpeg_and_first_gif_frame() {
    // REFERENCE.md thumbnail-source-reference/2 supplies inputs and immutable
    // original-API observations. These are compatibility fingerprints, not a
    // separately derived mathematical Lanczos or codec proof.
    let temp = sandbox();
    let landscape = temp.path().join("landscape.payload");
    RgbaImage::from_fn(273, 226, |x, y| {
        Rgba([
            low_byte(37 * x + 73 * y + ((x ^ (3 * y)) & 31) * 11),
            low_byte(97 * x + 19 * y + ((x / 3 + y / 5) & 1) * 109),
            low_byte(13 * x + 151 * y + ((x + y) % 7) * 23),
            low_byte(53 * x + 101 * y + ((x / 2 + y / 3) & 1) * 79),
        ])
    })
    .save_with_format(&landscape, ImageFormat::Png)
    .unwrap();

    let portrait = temp.path().join("portrait.packet");
    RgbaImage::from_fn(219, 284, |x, y| {
        Rgba([
            low_byte(61 * x + 17 * y + (x * y) % 251),
            low_byte(11 * x + 103 * y + ((x / 2 + y / 7) & 1) * 137),
            low_byte(157 * x + 47 * y + ((x ^ y) & 15) * 9),
            low_byte(71 * x + 31 * y + ((x / 5 + y / 3) & 1) * 67),
        ])
    })
    .save_with_format(&portrait, ImageFormat::Png)
    .unwrap();

    let jpeg = temp.path().join("rgb-photo.record");
    image::RgbImage::from_fn(307, 233, |x, y| {
        image::Rgb([
            low_byte(89 * x + 41 * y + ((x / 2 + y / 3) & 1) * 113),
            low_byte(23 * x + 127 * y + (x * y) % 241),
            low_byte(149 * x + 7 * y + ((x ^ y) % 13) * 17),
        ])
    })
    .save_with_format(&jpeg, ImageFormat::Jpeg)
    .unwrap();

    let gif = temp.path().join("two-frames.bundle");
    {
        let mut encoder = image::codecs::gif::GifEncoder::new(fs::File::create(&gif).unwrap());
        let first = RgbaImage::from_fn(23, 17, |x, y| {
            Rgba([
                if (x / 2 + y / 3) % 2 == 0 { 230 } else { 12 },
                low_byte(29 * x + 11 * y),
                low_byte(7 * x + 47 * y + 31),
                255,
            ])
        });
        let second = RgbaImage::from_fn(23, 17, |x, y| {
            Rgba([
                low_byte(13 * x + 3 * y + 17),
                if (x / 3 + y / 2) % 2 == 0 { 9 } else { 241 },
                low_byte(43 * x + 19 * y + 197),
                255,
            ])
        });
        encoder.encode_frame(image::Frame::new(first)).unwrap();
        encoder.encode_frame(image::Frame::new(second)).unwrap();
    }

    let before = tree_state(temp.path());
    assert_numeric_reference(
        &landscape,
        0xff7728a2d896dd2c,
        [
            [88, 32, 72, 55],
            [204, 221, 219, 116],
            [92, 109, 41, 124],
            [71, 56, 188, 138],
            [34, 112, 209, 24],
            [177, 29, 87, 72],
            [82, 137, 180, 133],
            [164, 162, 80, 189],
            [7, 164, 209, 66],
            [79, 119, 80, 50],
        ],
    );
    assert_numeric_reference(
        &portrait,
        0x2c56ac55f2a1512a,
        [
            [33, 212, 207, 197],
            [216, 177, 206, 147],
            [166, 45, 68, 154],
            [174, 234, 141, 184],
            [125, 202, 135, 231],
            [112, 95, 73, 64],
            [213, 163, 130, 188],
            [84, 134, 139, 73],
            [0, 82, 78, 67],
            [111, 61, 138, 143],
        ],
    );
    assert_numeric_reference(
        &jpeg,
        0x7702e2f5773bc49f,
        [
            [184, 118, 103, 255],
            [133, 64, 27, 255],
            [93, 6, 111, 255],
            [80, 38, 56, 255],
            [111, 149, 0, 255],
            [41, 68, 190, 255],
            [87, 158, 57, 255],
            [137, 123, 207, 255],
            [52, 224, 105, 255],
            [209, 129, 98, 255],
        ],
    );
    assert_numeric_reference(
        &gif,
        0xb16f2d785d5e7e07,
        [
            [0, 70, 56, 255],
            [23, 39, 132, 255],
            [253, 0, 50, 255],
            [210, 214, 130, 255],
            [25, 166, 200, 255],
            [27, 164, 189, 255],
            [249, 0, 53, 255],
            [22, 40, 135, 255],
            [68, 44, 144, 255],
            [134, 221, 88, 255],
        ],
    );
    assert_eq!(tree_state(temp.path()), before);
}

#[test]
fn real_zero_image_gif_retains_its_observed_decoding_error_without_mutation() {
    let temp = sandbox();
    let path = temp.path().join("zero-images.stream");
    fs::write(
        &path,
        [
            0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0x01, 0x00, 0x01, 0x00, 0x80, 0x00, 0x00, 0x00,
            0x00, 0x00, 0xff, 0xff, 0xff, 0x3b,
        ],
    )
    .unwrap();
    let before = tree_state(temp.path());
    assert!(matches!(
        decode_and_crop(&path),
        Err(ImageError::Decoding(_))
    ));
    assert_eq!(tree_state(temp.path()), before);
}

#[test]
fn injected_first_frame_exhaustion_uses_normal_io_handling_once_and_restores_scope() {
    use super::thumbnails::test_controls::with_exhausted_first_frame;

    let temp = sandbox();
    let gif = temp.path().join("valid-animation.payload");
    let first = [255, 0, 0, 255];
    {
        let mut encoder = image::codecs::gif::GifEncoder::new(fs::File::create(&gif).unwrap());
        encoder
            .encode_frame(image::Frame::new(RgbaImage::from_fn(4, 3, |_, _| {
                Rgba(first)
            })))
            .unwrap();
        encoder
            .encode_frame(image::Frame::new(RgbaImage::from_fn(4, 3, |_, _| {
                Rgba([0, 255, 0, 255])
            })))
            .unwrap();
    }
    let png = temp.path().join("ordinary.png");
    RgbaImage::from_fn(3, 3, |_, _| Rgba([11, 22, 33, 44]))
        .save_with_format(&png, ImageFormat::Png)
        .unwrap();
    let before = tree_state(temp.path());
    let assert_real_frame = || {
        let actual = decode_and_crop(&gif).unwrap();
        assert_shape(&actual);
        assert_eq!(actual.rgba, first.repeat(40_000));
    };
    let assert_exhaustion = || match decode_and_crop(&gif).unwrap_err() {
        ImageError::IoError(error) => assert_eq!(error.kind(), std::io::ErrorKind::Other),
        other => {
            panic!("injected exhaustion must use ordinary no-frame IO handling, got {other:?}")
        }
    };
    with_exhausted_first_frame(|| {
        let png_pixels = decode_and_crop(&png).unwrap();
        assert_shape(&png_pixels);
        assert_eq!(png_pixels.rgba, [11, 22, 33, 44].repeat(40_000));
        std::thread::scope(|scope| scope.spawn(&assert_real_frame).join().unwrap());
        with_exhausted_first_frame(&assert_exhaustion);
        assert_exhaustion();
        assert_real_frame();
    });
    let unwind = std::panic::catch_unwind(|| {
        with_exhausted_first_frame(|| panic!("restore armed exhaustion on unwind"));
    });
    assert!(unwind.is_err());
    assert_real_frame();
    assert_eq!(tree_state(temp.path()), before);
}
