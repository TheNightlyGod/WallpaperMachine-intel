#!/usr/bin/env python3
"""Build WallpaperMachine's Rust/C++ renderer and SwiftUI application with Homebrew.

Stages, in order: cargo builds the renderer workspace, `uniffi-bindgen` regenerates
the Swift bridge into `App/Bridge/Generated`, `xcodegen` regenerates the Xcode project
from `project.yml`, and `xcodebuild` builds the app. See docs/build.md.

`--compile-app-icon DIR` only compiles the Icon Composer icon and the asset catalog
into DIR, the way Xcode would; `--app-icon DIR` builds the app with that output instead
of compiling the icon. Xcode 26's actool crashes on most attempts to compile an `.icon`
on macOS 15, where releases are built, so CI compiles it on macOS 26 and hands it over.

Each stage's full output goes to `artifacts/build/<stage>-<timestamp>.log`; the
terminal only sees errors and the final verdict unless `--verbose` is given.
"""
import argparse
from datetime import datetime
import os
from pathlib import Path
import platform
import plistlib
import shutil
import subprocess
import sys

from lib.glyphs import markers
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


def find_brew():
    candidates = [
        shutil.which("brew"),
        str(Path.home() / "homebrew/bin/brew"),
        "/usr/local/bin/brew",
        "/opt/homebrew/bin/brew",
    ]
    for c in candidates:
        if c and Path(c).is_file() and os.access(c, os.X_OK):
            return c
    return "brew"


def build_environment():
    result = os.environ.copy()
    brew_bin = find_brew()
    prefix = subprocess.check_output([brew_bin, "--prefix"], text=True).strip()
    packages = ["quickjs-ng", "freetype", "lz4", "nlohmann-json", "argparse"]
    roots = [str(Path(prefix) / "opt" / name) for name in packages]
    result["PATH"] = f"{prefix}/bin:" + result.get("PATH", "")
    result["CMAKE_PREFIX_PATH"] = ";".join(roots + [prefix])
    result["PKG_CONFIG_PATH"] = ":".join(str(Path(p) / "lib/pkgconfig") for p in roots)
    result["OWE_NIX_LIBRARY_PATH"] = ":".join(str(Path(p) / "lib") for p in roots) + f":{prefix}/lib"
    xcode_path = Path(subprocess.check_output(["xcode-select", "-p"], text=True).strip())
    toolchain_lib = xcode_path / "Toolchains/XcodeDefault.xctoolchain/usr/lib"
    clt_lib = xcode_path / "usr/lib"
    result["LIBCLANG_PATH"] = str(toolchain_lib if (toolchain_lib / "libclang.dylib").is_file() else clt_lib)
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
    parser.add_argument("--xcode-setting", action="append", default=[], metavar="NAME=VALUE",
        help="Pass a build setting to xcodebuild; repeatable (CodeQL's traced Swift build uses it).")
    parser.add_argument("--verbose", action="store_true", help="Echo every tool line instead of only errors.")
    args = parser.parse_args()
    global VERBOSE
    VERBOSE = args.verbose
    for setting in args.xcode_setting:
        if "=" not in setting:
            parser.error(f"--xcode-setting expects NAME=VALUE, got {setting!r}")
    if args.compile_app_icon:
        compile_app_icon(args.compile_app_icon.resolve())
        print(f"{MARK.ok} Compiled the app icon into {args.compile_app_icon}")
        return
    compiled_icon = args.app_icon.resolve() if args.app_icon else None
    if compiled_icon and not all((compiled_icon / name).is_file() for name in (*APP_ICON_OUTPUTS, APP_ICON_PLIST)):
        raise SystemExit(f"{compiled_icon} is not --compile-app-icon output")
    env = build_environment()
    if not args.swift_only:
        run(["cargo", "build", "--workspace", "--release"], RENDERER, cargo_environment(), stage="cargo")
        run([RENDERER / "target/release/uniffi-bindgen", "generate", "--library", RENDERER / "target/release/libwallpaper_bridge.a", "--language", "swift", "--no-format", "--out-dir", GENERATED_BRIDGE], cwd=RENDERER, env=env, stage="bindgen")
    if args.renderer_only:
        return
    has_xcodebuild = False
    if shutil.which("xcodebuild"):
        try:
            subprocess.check_output(["xcodebuild", "-version"], stderr=subprocess.DEVNULL)
            has_xcodebuild = True
        except Exception:
            has_xcodebuild = False

    if has_xcodebuild:
        # `--use-cache` skips rewriting the project when `project.yml` has not changed,
        # which keeps Xcode's incremental build state (and `scripts/test.py` agrees).
        run(["xcodegen", "generate", "--use-cache", "--quiet"], env=env, stage="xcodegen")
        settings = []
        if compiled_icon:
            # The asset catalog is still compiled; only the .icon is left out, and with it
            # the app-icon name actool would otherwise look for in the catalog.
            settings = [f"EXCLUDED_SOURCE_FILE_NAMES={APP_ICON.name}", "ASSETCATALOG_COMPILER_APPICON_NAME="]
        settings += args.xcode_setting
        destination = ["-destination", f"platform=macOS,arch={platform.machine()}"]
        run(["xcodebuild", "-project", XCODEPROJ.name, "-scheme", "WallpaperMachine", "-configuration", args.configuration, *destination, f"ARCHS={platform.machine()}", "-derivedDataPath", BUILD, "build", *settings], env=env, stage=f"xcodebuild-{args.configuration}")
        if compiled_icon:
            install_app_icon(app_bundle(args.configuration), compiled_icon)
    else:
        from lib.clt_build import build_app_bundle
        print(f"{MARK.step} Building directly with swiftc and Command Line Tools...")
        build_app_bundle(configuration=args.configuration, env=env)
    print(f"{MARK.ok} Built {PRODUCTS / args.configuration / 'WallpaperMachine.app'}")


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as error:
        sys.exit(error.returncode)
