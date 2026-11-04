#!/usr/bin/env python3
"""Build WallpaperMachine's Rust/C++ renderer and SwiftUI application with Homebrew.

Stages, in order: cargo builds the renderer workspace, `uniffi-bindgen` regenerates
the Swift bridge into `App/Bridge/Generated`, `xcodegen` regenerates the Xcode project
from `project.yml`, and `xcodebuild` builds the app. See docs/build.md.

`--compile-app-icon DIR` only compiles the Icon Composer icon and the asset catalog
into DIR, the way Xcode would; `--app-icon DIR` builds the app with that output instead
of compiling the icon. Xcode 26's actool crashes on most attempts to compile an `.icon`
on macOS 15, where releases are built, so CI compiles it on macOS 26 and hands it over.
The release build does not wait for it: `--no-app-icon` builds without the icon, and
`--install-app-icon DIR` puts the handed-over icon into that build once it arrives.

Each stage's full output goes to `artifacts/build/<stage>-<timestamp>.log`; the
terminal only sees errors and the final verdict unless `--verbose` is given.
"""
import argparse
from datetime import datetime
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys

from lib.glyphs import markers
from lib.homebrew import RENDERER_PACKAGES
from lib.paths import APP, BUILD, BUILD_ARTIFACTS, GENERATED_BRIDGE, PRODUCTS, RENDERER, ROOT, XCODEPROJ, app_bundle
from lib.xcode import run_quiet

MARK = markers()
STAMP = datetime.now().strftime("%Y%m%d-%H%M%S")
VERBOSE = False

# project.yml's deployment target and app icon; the icon is compiled with them.
DEPLOYMENT_TARGET = "15.0"
APP_ICON = APP / "Resources/AppIcon.icon"
ASSET_CATALOG = APP / "Resources/Assets.xcassets"
# What actool writes for the app icon: the catalog, the legacy icon file, and the
# Info.plist keys (CFBundleIconFile, CFBundleIconName) that name them.
APP_ICON_OUTPUTS = ("Assets.car", "AppIcon.icns")
APP_ICON_PLIST = "partial-info.plist"


def run(args, cwd=ROOT, env=None, stage="build"):
    print(MARK.step, " ".join(map(str, args)), flush=True)
    log = BUILD_ARTIFACTS / f"{stage}-{STAMP}.log"
    completed, _ = run_quiet(args, log, cwd=cwd, env=env, verbose=VERBOSE)
    if completed.returncode != 0:
        print(f"{MARK.missing} {stage} failed (exit {completed.returncode}); full log: {log}", flush=True)
        raise subprocess.CalledProcessError(completed.returncode, list(map(str, args)))


def repository_commit(root=ROOT):
    """Short commit of `root`, stamped into the build as the source it came from."""
    return subprocess.check_output(["git", "-C", str(root), "rev-parse", "--short", "HEAD"], text=True).strip()


def build_environment():
    result = os.environ.copy()
    prefix = subprocess.check_output(["brew", "--prefix"], text=True).strip()
    roots = [str(Path(prefix) / "opt" / name) for name in RENDERER_PACKAGES]
    result["PATH"] = f"{prefix}/bin:" + result.get("PATH", "")
    result["CMAKE_PREFIX_PATH"] = ";".join(roots + [prefix])
    result["PKG_CONFIG_PATH"] = ":".join(str(Path(p) / "lib/pkgconfig") for p in roots)
    result["OWE_NIX_LIBRARY_PATH"] = ":".join(str(Path(p) / "lib") for p in roots) + f":{prefix}/lib"
    result["LIBCLANG_PATH"] = subprocess.check_output(["xcode-select", "-p"], text=True).strip() + "/Toolchains/XcodeDefault.xctoolchain/usr/lib"
    result["SDKROOT"] = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
    result["CC"] = "/usr/bin/clang"
    result["CXX"] = "/usr/bin/clang++"
    result["MACOSX_DEPLOYMENT_TARGET"] = DEPLOYMENT_TARGET
    result["GIT_SHORT_COMMIT"] = repository_commit()
    return result


def cargo_environment():
    """The build environment with the deployment target renamed for cargo.

    Cargo builds proc-macro crates and build scripts for the host and then
    dlopens them in the running compiler. A pinned deployment target applies to
    those host dylibs too, and the ones this toolchain then produces are
    rejected at load with "mis-aligned LINKEDIT" -- which the compiler reports
    as `can't find crate for <macro>`, so every crate behind a derive fails to
    build.

    The pin is not dropped, only moved: the renderer crate's build script reads
    `OWE_MACOSX_DEPLOYMENT_TARGET` and hands it to CMake, so the C++ engine is
    still built for the same minimum as the app that links it. Rust's own
    objects fall back to the compiler default, which is below that minimum and
    therefore links without complaint.
    """
    result = build_environment()
    pinned = result.pop("MACOSX_DEPLOYMENT_TARGET", None)
    if pinned is not None:
        result["OWE_MACOSX_DEPLOYMENT_TARGET"] = pinned
    return result


def compile_app_icon(output):
    """Compile the app icon and asset catalog into `output` with Xcode's arguments."""
    output.mkdir(parents=True, exist_ok=True)
    run(["xcrun", "actool", APP_ICON, ASSET_CATALOG, "--compile", output,
         "--output-format", "human-readable-text", "--notices", "--warnings",
         "--output-partial-info-plist", output / APP_ICON_PLIST, "--app-icon", "AppIcon",
         "--enable-on-demand-resources", "NO", "--development-region", "en", "--target-device", "mac",
         "--minimum-deployment-target", DEPLOYMENT_TARGET, "--platform", "macosx"], stage="actool")
    missing = [name for name in (*APP_ICON_OUTPUTS, APP_ICON_PLIST) if not (output / name).is_file()]
    if missing:
        raise SystemExit(f"actool wrote no {', '.join(missing)} in {output}")


def install_app_icon(app, compiled):
    """Put a compiled app icon into a bundle built without one, then re-sign it.

    The Assets.car from `compile_app_icon` holds the asset catalog too, so it replaces
    the one Xcode compiled from the catalog alone.
    """
    resources = app / "Contents/Resources"
    for name in APP_ICON_OUTPUTS:
        shutil.copy2(compiled / name, resources / name)
    info_path = app / "Contents/Info.plist"
    info = plistlib.loads(info_path.read_bytes())
    info.update(plistlib.loads((compiled / APP_ICON_PLIST).read_bytes()))
    info_path.write_bytes(plistlib.dumps(info))
    run(["codesign", "--force", "--sign", "-", "--preserve-metadata=entitlements,requirements,flags,runtime", app], stage="codesign")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--swift-only", action="store_true")
    parser.add_argument("--renderer-only", action="store_true")
    parser.add_argument("--configuration", choices=["Debug", "Release"], default="Debug")
    parser.add_argument("--compile-app-icon", type=Path, metavar="DIR",
        help="Only compile the app icon and asset catalog into DIR.")
    parser.add_argument("--app-icon", type=Path, metavar="DIR",
        help="Build with the icon --compile-app-icon wrote to DIR instead of compiling it.")
    parser.add_argument("--no-app-icon", action="store_true",
        help="Build without compiling the app icon; --install-app-icon adds it afterwards.")
    parser.add_argument("--install-app-icon", type=Path, metavar="DIR",
        help="Only put the icon --compile-app-icon wrote to DIR into the built app, and re-sign it.")
    parser.add_argument("--xcode-setting", action="append", default=[], metavar="NAME=VALUE",
        help="Pass a build setting to xcodebuild; repeatable (CodeQL's traced Swift build uses it).")
    parser.add_argument("--verbose", action="store_true", help="Echo every tool line instead of only errors.")
    args = parser.parse_args()
    global VERBOSE
    VERBOSE = args.verbose
    for setting in args.xcode_setting:
        if "=" not in setting:
            parser.error(f"--xcode-setting expects NAME=VALUE, got {setting!r}")
    if args.app_icon and args.no_app_icon:
        parser.error("--app-icon already builds without compiling the icon; drop --no-app-icon")
    if args.compile_app_icon:
        compile_app_icon(args.compile_app_icon.resolve())
        print(f"{MARK.ok} Compiled the app icon into {args.compile_app_icon}")
        return
    compiled_icon = args.app_icon or args.install_app_icon
    compiled_icon = compiled_icon.resolve() if compiled_icon else None
    if compiled_icon and not all((compiled_icon / name).is_file() for name in (*APP_ICON_OUTPUTS, APP_ICON_PLIST)):
        raise SystemExit(f"{compiled_icon} is not --compile-app-icon output")
    if args.install_app_icon:
        app = app_bundle(args.configuration)
        if not (app / "Contents/Info.plist").is_file():
            raise SystemExit(f"No built app at {app}; build it with --no-app-icon first")
        install_app_icon(app, compiled_icon)
        print(f"{MARK.ok} Added the app icon to {app}")
        return
    env = build_environment()
    if not args.swift_only:
        run(["cargo", "build", "--workspace", "--release"], RENDERER, cargo_environment(), stage="cargo")
        run([RENDERER / "target/release/uniffi-bindgen", "generate", "--library", RENDERER / "target/release/libwallpaper_bridge.a", "--language", "swift", "--no-format", "--out-dir", GENERATED_BRIDGE], cwd=RENDERER, env=env, stage="bindgen")
    if args.renderer_only:
        if args.swift_only:
            print(f"{MARK.warn} Renderer build skipped by --swift-only")
        else:
            print(f"{MARK.ok} Built renderer and regenerated Swift bindings")
        return
    # `--use-cache` skips rewriting the project when `project.yml` has not changed,
    # which keeps Xcode's incremental build state (and `scripts/test.py` agrees).
    run(["xcodegen", "generate", "--use-cache", "--quiet"], env=env, stage="xcodegen")
    settings = []
    if compiled_icon or args.no_app_icon:
        # The asset catalog is still compiled; only the .icon is left out, and with it
        # the app-icon name actool would otherwise look for in the catalog.
        settings = [f"EXCLUDED_SOURCE_FILE_NAMES={APP_ICON.name}", "ASSETCATALOG_COMPILER_APPICON_NAME="]
    settings += args.xcode_setting
    run(["xcodebuild", "-project", XCODEPROJ.name, "-scheme", "WallpaperMachine", "-configuration", args.configuration, "-derivedDataPath", BUILD, "build", *settings], env=env, stage=f"xcodebuild-{args.configuration}")
    if compiled_icon:
        install_app_icon(app_bundle(args.configuration), compiled_icon)
    print(f"{MARK.ok} Built {PRODUCTS / args.configuration / 'WallpaperMachine.app'}")


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as error:
        sys.exit(error.returncode)
