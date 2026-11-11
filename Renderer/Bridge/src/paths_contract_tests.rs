//! Independently authored contract tests. No process environment or storage mutation.

use super::{BUNDLE_IDENTIFIER, BridgePaths};
use std::cell::RefCell;
use std::collections::BTreeMap;
use std::ffi::OsString;
use std::path::{Path, PathBuf};

const SUPPORT: &str = "WALLPAPER_MACHINE_SUPPORT_ROOT";
const LIBRARY: &str = "WALLPAPER_MACHINE_LIBRARY_ROOT";
const ASSETS: &str = "WALLPAPER_MACHINE_ASSETS_ROOT";
const USER: &str = "WALLPAPER_MACHINE_USER_ASSETS_ROOT";
const KEYS: [&str; 4] = [SUPPORT, LIBRARY, ASSETS, USER];

#[derive(Default)]
struct Inputs {
    home: Option<PathBuf>,
    overrides: BTreeMap<&'static str, OsString>,
}

thread_local! {
    static INPUTS: RefCell<Option<Inputs>> = const { RefCell::new(None) };
}

// The outer Option distinguishes an inactive seam from controlled absence.
// Neither hook computes any path: the public production methods do all resolution.
pub(super) fn home_input() -> Option<Option<PathBuf>> {
    INPUTS.with(|slot| slot.borrow().as_ref().map(|inputs| inputs.home.clone()))
}

pub(super) fn override_input(key: &str) -> Option<Option<OsString>> {
    INPUTS.with(|slot| {
        slot.borrow()
            .as_ref()
            .map(|inputs| inputs.overrides.get(key).cloned())
    })
}

fn with_inputs(home: Option<PathBuf>, body: impl FnOnce()) {
    // Restoration is unwind-safe and local to this thread. This is not a mutex
    // around process state: no set_var/remove_var or real home discovery is used.
    struct Restore(Option<Inputs>);
    impl Drop for Restore {
        fn drop(&mut self) {
            INPUTS.with(|slot| {
                *slot.borrow_mut() = self.0.take();
            });
        }
    }

    let previous = INPUTS.with(|slot| {
        slot.replace(Some(Inputs {
            home,
            ..Inputs::default()
        }))
    });
    let _restore = Restore(previous);
    body();
}

fn update_inputs(body: impl FnOnce(&mut Inputs)) {
    INPUTS.with(|slot| {
        body(slot.borrow_mut().as_mut().expect("controlled test scope"));
    });
}

fn set_override(key: &'static str, value: Option<OsString>) {
    update_inputs(|inputs| match value {
        Some(value) => {
            inputs.overrides.insert(key, value);
        }
        None => {
            inputs.overrides.remove(key);
        }
    });
}

fn assert_locations(
    paths: &BridgePaths,
    support: &Path,
    workshop: &Path,
    assets: &Path,
    user: &Path,
) {
    assert_eq!(paths.app_support_root(), support);
    assert_eq!(paths.steam_workshop_root(), workshop);
    assert_eq!(paths.assets_root(), assets);
    assert_eq!(paths.user_assets_root(), user);
    assert_eq!(paths.shader_cache_root(), support.join("shader-cache"));
    assert_eq!(paths.logs_root(), support.join("Logs"));
    assert_eq!(paths.scene_storage_root(), support.join("SceneStorage"));
    assert_eq!(paths.scene_storage_dir("item-01"), support.join("SceneStorage/item-01"));
    assert_eq!(
        paths.log_session_root("session-01"),
        support.join("Logs/session-01")
    );
    assert_eq!(
        paths.project_json("item-01"),
        workshop.join("item-01/project.json")
    );
}

#[test]
fn public_surface_and_owned_capabilities() {
    fn capabilities<T: Clone + std::fmt::Debug + Default + Send + Sync + 'static>() {}
    capabilities::<BridgePaths>();
    assert_eq!(BUNDLE_IDENTIFIER, "app.wallpapermachine");

    let _: fn() -> BridgePaths = BridgePaths::new;
    let _: fn(PathBuf) -> BridgePaths = BridgePaths::for_home;
    let _: fn(&BridgePaths) -> PathBuf = BridgePaths::app_support_root;
    let _: fn(&BridgePaths) -> PathBuf = BridgePaths::steam_workshop_root;
    let _: fn(&BridgePaths, &str) -> PathBuf = BridgePaths::project_json;
    let _: fn(&BridgePaths) -> PathBuf = BridgePaths::assets_root;
    let _: fn(&BridgePaths) -> PathBuf = BridgePaths::user_assets_root;
    let _: fn(&BridgePaths) -> PathBuf = BridgePaths::shader_cache_root;
    let _: fn(&BridgePaths) -> PathBuf = BridgePaths::logs_root;
    let _: fn(&BridgePaths, &str) -> PathBuf = BridgePaths::log_session_root;
    let _: fn() -> BridgePaths = <BridgePaths as Default>::default;
    let _: fn(&BridgePaths) -> BridgePaths = <BridgePaths as Clone>::clone;

    with_inputs(None, || {
        let paths = {
            let caller_owned = String::from("owned-home");
            BridgePaths::for_home(caller_owned.as_str())
        };
        let _debug_without_format_contract = format!("{paths:?}");
        assert_eq!(
            paths.app_support_root(),
            Path::new("owned-home/Library/Application Support/app.wallpapermachine")
        );
    });
}

#[test]
fn owned_values_move_and_share_across_threads_with_isolated_test_inputs() {
    with_inputs(None, || {
        let shared = std::sync::Arc::new({
            let home = String::from("thread-owned-home");
            BridgePaths::for_home(home.as_str())
        });
        let handles: Vec<_> = ["thread-support-a", "thread-support-b"]
            .into_iter()
            .map(|support| {
                let shared = std::sync::Arc::clone(&shared);
                std::thread::spawn(move || {
                    with_inputs(None, || {
                        assert_eq!(
                            shared.app_support_root(),
                            Path::new(
                                "thread-owned-home/Library/Application Support/app.wallpapermachine"
                            )
                        );
                        set_override(SUPPORT, Some(OsString::from(support)));
                        assert_eq!(shared.app_support_root(), Path::new(support));
                        assert_eq!(shared.clone().logs_root(), Path::new(support).join("Logs"));
                    });
                })
            })
            .collect();
        for handle in handles {
            handle.join().expect("controlled worker completes");
        }
        assert_eq!(
            shared.app_support_root(),
            Path::new("thread-owned-home/Library/Application Support/app.wallpapermachine")
        );
    });
}

#[test]
fn explicit_homes_include_empty_relative_and_literal_components() {
    for home in ["/contract-home", "relative-home", "", "~/literal/./../home"] {
        with_inputs(Some(PathBuf::from("unused-discovery")), || {
            let paths = BridgePaths::for_home(home);
            let home = Path::new(home);
            let support = home.join("Library/Application Support/app.wallpapermachine");
            let workshop =
                home.join("Library/Application Support/Steam/steamapps/workshop/content/431960");
            let assets = home
                .join("Library/Application Support/Steam/steamapps/common/wallpaper_engine/assets");
            assert_locations(
                &paths,
                &support,
                &workshop,
                &assets,
                &support.join("UserAssets"),
            );
        });
    }
}

#[test]
fn discovered_and_missing_home_fallbacks_cover_all_locations() {
    for home in [Some(PathBuf::from("discovered-home")), Some(PathBuf::new())] {
        with_inputs(home.clone(), || {
            let basis = home.as_ref().expect("present home case");
            let support = basis.join("Library/Application Support/app.wallpapermachine");
            let workshop =
                basis.join("Library/Application Support/Steam/steamapps/workshop/content/431960");
            let assets = basis
                .join("Library/Application Support/Steam/steamapps/common/wallpaper_engine/assets");
            for paths in [BridgePaths::new(), BridgePaths::default()] {
                assert_locations(
                    &paths,
                    &support,
                    &workshop,
                    &assets,
                    &support.join("UserAssets"),
                );
            }
        });
    }

    with_inputs(None, || {
        for paths in [BridgePaths::new(), BridgePaths::default()] {
            assert_locations(
                &paths,
                Path::new("./app.wallpapermachine"),
                Path::new("/missing/workshop"),
                Path::new("/missing/assets"),
                Path::new("./app.wallpapermachine/UserAssets"),
            );
            assert_eq!(
                paths.app_support_root().as_os_str(),
                Path::new("./app.wallpapermachine").as_os_str()
            );
        }
    });
}

#[test]
fn construction_captures_home_once_but_not_overrides() {
    with_inputs(Some(PathBuf::from("first-home")), || {
        set_override(SUPPORT, Some(OsString::from("construction-override")));
        let first = BridgePaths::new();
        let first_default = BridgePaths::default();
        update_inputs(|inputs| {
            inputs.home = Some(PathBuf::from("second-home"));
        });
        let clone = first.clone();
        let explicit = BridgePaths::for_home("explicit-home");
        let later = BridgePaths::default();
        set_override(SUPPORT, None);
        for paths in [&first, &first_default, &clone] {
            assert_eq!(
                paths.app_support_root(),
                Path::new("first-home/Library/Application Support/app.wallpapermachine")
            );
        }
        assert_eq!(
            later.app_support_root(),
            Path::new("second-home/Library/Application Support/app.wallpapermachine")
        );
        assert_eq!(
            explicit.app_support_root(),
            Path::new("explicit-home/Library/Application Support/app.wallpapermachine")
        );
        update_inputs(|inputs| inputs.home = None);
        let missing = BridgePaths::new();
        let missing_clone = missing.clone();
        update_inputs(|inputs| inputs.home = Some(PathBuf::from("third-home")));
        assert_eq!(
            missing.app_support_root(),
            Path::new("./app.wallpapermachine")
        );
        assert_eq!(missing_clone.assets_root(), Path::new("/missing/assets"));
        assert_eq!(
            first.steam_workshop_root(),
            Path::new(
                "first-home/Library/Application Support/Steam/steamapps/workshop/content/431960"
            )
        );
    });
}

fn exercise_override_values(values: Vec<OsString>) {
    with_inputs(None, || {
        let paths = BridgePaths::new();
        let clone = paths.clone();
        for key in KEYS {
            for value in &values {
                set_override(key, Some(value.clone()));
                let root = PathBuf::from(value.clone());
                let default_support = Path::new("./app.wallpapermachine");
                let support = if key == SUPPORT {
                    root.as_path()
                } else {
                    default_support
                };
                let workshop = if key == LIBRARY {
                    root.as_path()
                } else {
                    Path::new("/missing/workshop")
                };
                let assets = if key == ASSETS {
                    root.as_path()
                } else {
                    Path::new("/missing/assets")
                };
                let user = if key == USER {
                    root.clone()
                } else {
                    support.join("UserAssets")
                };
                for paths in [&paths, &clone] {
                    assert_locations(paths, support, workshop, assets, &user);
                    // Compare platform strings, not just normalized Path equality.
                    let actual = match key {
                        SUPPORT => paths.app_support_root(),
                        LIBRARY => paths.steam_workshop_root(),
                        ASSETS => paths.assets_root(),
                        USER => paths.user_assets_root(),
                        _ => unreachable!(),
                    };
                    assert_eq!(actual.as_os_str(), value.as_os_str());
                }
            }
            set_override(key, None);
            for paths in [&paths, &clone] {
                assert_locations(
                    paths,
                    Path::new("./app.wallpapermachine"),
                    Path::new("/missing/workshop"),
                    Path::new("/missing/assets"),
                    Path::new("./app.wallpapermachine/UserAssets"),
                );
            }
            set_override(key, Some(OsString::from("restored/../root")));
            let expected = Path::new("restored/../root");
            let actual = match key {
                SUPPORT => clone.app_support_root(),
                LIBRARY => clone.steam_workshop_root(),
                ASSETS => clone.assets_root(),
                USER => clone.user_assets_root(),
                _ => unreachable!(),
            };
            assert_eq!(actual.as_os_str(), expected.as_os_str());
            set_override(key, None);
        }
    });
}

#[test]
fn each_override_is_dynamic_independent_and_accepts_empty_or_relative_values() {
    exercise_override_values(vec![
        OsString::new(),
        OsString::from("relative/./root/../value"),
        OsString::from("/absolute-contract-root"),
        OsString::from("~/not-expanded/$HOME"),
    ]);
}

#[cfg(unix)]
fn non_utf8_value() -> OsString {
    use std::os::unix::ffi::OsStringExt;
    OsString::from_vec(b"relative-\xff-root".to_vec())
}

#[cfg(windows)]
fn non_utf8_value() -> OsString {
    use std::os::windows::ffi::OsStringExt;
    OsString::from_wide(&[0x72, 0xD800, 0x74])
}

#[cfg(any(unix, windows))]
#[test]
fn non_utf8_overrides_and_home_remain_platform_path_values() {
    let value = non_utf8_value();
    assert!(value.to_str().is_none());
    exercise_override_values(vec![value.clone()]);
    with_inputs(Some(PathBuf::from(value.clone())), || {
        let paths = BridgePaths::new();
        let expected =
            PathBuf::from(value.clone()).join("Library/Application Support/app.wallpapermachine");
        assert_eq!(paths.app_support_root().as_os_str(), expected.as_os_str());
        assert_eq!(
            paths.log_session_root("text/../session").as_os_str(),
            expected.join("Logs").join("text/../session").as_os_str()
        );
    });
}

#[test]
fn simultaneous_overrides_mask_only_their_own_dependencies_and_allow_overlap() {
    with_inputs(None, || {
        let paths = BridgePaths::for_home("basis");
        set_override(SUPPORT, Some(OsString::from("support-one")));
        set_override(LIBRARY, Some(OsString::from("workshop-one")));
        set_override(ASSETS, Some(OsString::from("shared-one")));
        set_override(USER, Some(OsString::from("pinned-user")));
        let clone = paths.clone();
        for support in ["support-one", "support-two"] {
            set_override(SUPPORT, Some(OsString::from(support)));
            for paths in [&paths, &clone] {
                assert_locations(
                    paths,
                    Path::new(support),
                    Path::new("workshop-one"),
                    Path::new("shared-one"),
                    Path::new("pinned-user"),
                );
            }
        }
        set_override(USER, None);
        assert_eq!(
            paths.user_assets_root(),
            Path::new("support-two/UserAssets")
        );
        assert_ne!(paths.user_assets_root(), paths.shader_cache_root());
        set_override(USER, Some(OsString::from("support-two/shader-cache")));
        assert_eq!(paths.user_assets_root(), paths.shader_cache_root());
        set_override(USER, Some(OsString::from("support-two")));
        assert_eq!(paths.user_assets_root(), paths.app_support_root());
        set_override(LIBRARY, Some(OsString::from("workshop-two")));
        set_override(ASSETS, Some(OsString::from("shared-two")));
        assert_locations(
            &clone,
            Path::new("support-two"),
            Path::new("workshop-two"),
            Path::new("shared-two"),
            Path::new("support-two"),
        );
    });
}

#[test]
fn identifier_and_session_arguments_use_unrestricted_rust_path_joining() {
    with_inputs(None, || {
        let paths = BridgePaths::for_home("relative-home");
        set_override(SUPPORT, Some(OsString::from("relative/../support")));
        set_override(LIBRARY, Some(OsString::from("relative/./workshop")));
        for argument in [
            "",
            "/absolute/value",
            ".",
            "..",
            "a/b",
            "a/../b",
            "a//b/",
            "~/value",
        ] {
            assert_eq!(
                paths.log_session_root(argument).as_os_str(),
                Path::new("relative/../support/Logs")
                    .join(argument)
                    .as_os_str()
            );
            assert_eq!(
                paths.project_json(argument).as_os_str(),
                Path::new("relative/./workshop")
                    .join(argument)
                    .join("project.json")
                    .as_os_str()
            );
        }
        assert_eq!(
            paths.log_session_root("/absolute/session"),
            Path::new("/absolute/session")
        );
        assert_eq!(
            paths.project_json("/absolute/project"),
            Path::new("/absolute/project/project.json")
        );
    });
}

#[test]
fn resolution_needs_no_storage_fixture_or_existing_target() {
    // These are arbitrary path values, never opened, inspected or created. This
    // test establishes fixture-free resolution, not a dynamic proof of no IO.
    // The accompanying handoff records the source-level effect review and gap.
    with_inputs(None, || {
        let paths = BridgePaths::for_home("unprovisioned/../literal-home");
        set_override(SUPPORT, Some(OsString::from("unprovisioned-support")));
        set_override(LIBRARY, Some(OsString::from("unprovisioned-workshop")));
        set_override(ASSETS, Some(OsString::from("unprovisioned-assets")));
        assert_locations(
            &paths,
            Path::new("unprovisioned-support"),
            Path::new("unprovisioned-workshop"),
            Path::new("unprovisioned-assets"),
            Path::new("unprovisioned-support/UserAssets"),
        );
    });
}
