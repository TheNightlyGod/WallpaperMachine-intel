"""Build and assemble WallpaperMachine using Command Line Tools (swiftc, cmake, clang)
when xcodebuild / Xcode.app is unavailable.
"""
import glob
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys

from .paths import ROOT, APP, EXTENSION, SHARED, PRODUCTS, BUILD, GENERATED_BRIDGE, RENDERER
from .glyphs import markers

MARK = markers()


def run_cmd(cmd, cwd=ROOT, env=None):
    cmd_str = " ".join(str(c) for c in cmd)
    print(f"{MARK.step} {cmd_str}", flush=True)
    res = subprocess.run(cmd, cwd=cwd, env=env)
    if res.returncode != 0:
        raise subprocess.CalledProcessError(res.returncode, cmd)


def get_brew_prefix():
    candidates = [
        shutil.which("brew"),
        str(Path.home() / "homebrew/bin/brew"),
        "/usr/local/bin/brew",
        "/opt/homebrew/bin/brew",
    ]
    for c in candidates:
        if c and Path(c).is_file() and os.access(c, os.X_OK):
            out = subprocess.check_output([c, "--prefix"], text=True).strip()
            return Path(out)
    return Path("/usr/local")


def compile_app_icon(output_icns: Path):
    """Generate AppIcon.icns using sips and iconutil."""
    icon_src = APP / "Resources/Assets.xcassets/AppIconDay.imageset/day.png"
    if not icon_src.is_file():
        raise FileNotFoundError(f"Missing icon source: {icon_src}")
    
    iconset = BUILD / "AppIcon.iconset"
    shutil.rmtree(iconset, ignore_errors=True)
    iconset.mkdir(parents=True, exist_ok=True)
    
    sizes = [
        (16, "16x16"),
        (32, "16x16@2x"),
        (32, "32x32"),
        (64, "32x32@2x"),
        (128, "128x128"),
        (256, "128x128@2x"),
        (256, "256x256"),
        (512, "256x256@2x"),
        (512, "512x512"),
        (1024, "512x512@2x"),
    ]
    for px, name in sizes:
        out = iconset / f"icon_{name}.png"
        subprocess.run(["sips", "-z", str(px), str(px), str(icon_src), "--out", str(out)], check=True, capture_output=True)
    
    output_icns.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(output_icns)], check=True)
    shutil.rmtree(iconset, ignore_errors=True)


def convert_xcstrings(xcstrings_path: Path, output_dir: Path):
    """Convert Localizable.xcstrings into {lang}.lproj/Localizable.strings dictionaries."""
    if not xcstrings_path.is_file():
        return
    with open(xcstrings_path, "r", encoding="utf-8") as f:
        data = json.load(f)
    languages = set()
    for entry in data.get("strings", {}).values():
        languages.update(entry.get("localizations", {}).keys())
    
    def escape_strings(s):
        return s.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n').replace('\r', '\\r')

    for lang in languages:
        lproj_dir = output_dir / f"{lang}.lproj"
        lproj_dir.mkdir(parents=True, exist_ok=True)
        strings_file = lproj_dir / "Localizable.strings"
        lines = []
        for key, entry in data.get("strings", {}).items():
            loc = entry.get("localizations", {}).get(lang)
            if loc and "stringUnit" in loc and "value" in loc["stringUnit"]:
                val = loc["stringUnit"]["value"]
                lines.append(f'"{escape_strings(key)}" = "{escape_strings(val)}";\n')
        strings_file.write_text("".join(lines), encoding="utf-8")


def build_mediaremote_adapter(build_env):
    """Build MediaRemoteAdapter.framework via cmake if needed."""
    mra_dir = BUILD / "MediaRemoteAdapter"
    framework = mra_dir / "MediaRemoteAdapter.framework"
    if framework.exists():
        return framework
    mra_dir.mkdir(parents=True, exist_ok=True)
    run_cmd(["cmake", "-S", str(ROOT / "upstream/mediaremote-adapter"), "-B", str(mra_dir),
             "-DCMAKE_BUILD_TYPE=Release", "-DCMAKE_OSX_ARCHITECTURES=x86_64"], cwd=ROOT, env=build_env)
    run_cmd(["cmake", "--build", str(mra_dir), "--config", "Release"], cwd=ROOT, env=build_env)
    run_cmd(["codesign", "--force", "--sign", "-", str(framework)], cwd=ROOT, env=build_env)
    return framework


def get_project_versions():
    marketing_version = "1.4.1"
    project_version = "34"
    proj_yml = ROOT / "project.yml"
    if proj_yml.is_file():
        text = proj_yml.read_text(encoding="utf-8")
        import re
        m_mkt = re.search(r'MARKETING_VERSION:\s*["\']?([^"\'\n]+)', text)
        if m_mkt:
            marketing_version = m_mkt.group(1).strip()
        m_ver = re.search(r'CURRENT_PROJECT_VERSION:\s*["\']?([^"\'\n]+)', text)
        if m_ver:
            project_version = m_ver.group(1).strip()
    return marketing_version, project_version


def build_app_bundle(configuration="Release", env=None):
    """Compile binaries with swiftc and assemble WallpaperMachine.app."""
    prefix = get_brew_prefix()
    build_env = os.environ.copy() if env is None else env.copy()
    build_env["PATH"] = f"{prefix}/bin:" + build_env.get("PATH", "")

    app_dir = PRODUCTS / configuration / "WallpaperMachine.app"
    contents = app_dir / "Contents"
    macos = contents / "MacOS"
    resources = contents / "Resources"
    frameworks = contents / "Frameworks"
    extensions = contents / "Extensions"
    plugins = contents / "PlugIns"

    # Clean existing app bundle
    if app_dir.exists():
        shutil.rmtree(app_dir)
    macos.mkdir(parents=True, exist_ok=True)
    resources.mkdir(parents=True, exist_ok=True)
    frameworks.mkdir(parents=True, exist_ok=True)
    extensions.mkdir(parents=True, exist_ok=True)

    # 1. MediaRemoteAdapter
    mra_framework = build_mediaremote_adapter(build_env)
    shutil.copytree(mra_framework, frameworks / "MediaRemoteAdapter.framework", symlinks=True)

    # 2. Extension binary & appex
    ext_files = sorted(str(p) for p in EXTENSION.glob("*.swift"))
    shared_files = sorted(str(p) for p in SHARED.glob("*.swift"))

    appex_dir = extensions / "WallpaperMachineExtension.appex"
    appex_macos = appex_dir / "Contents/MacOS"
    appex_resources = appex_dir / "Contents/Resources"
    appex_macos.mkdir(parents=True, exist_ok=True)
    appex_resources.mkdir(parents=True, exist_ok=True)

    ext_bin = appex_macos / "WallpaperMachineExtension"
    ext_cmd = [
        "swiftc",
        "-O" if configuration == "Release" else "-Onone",
        "-target", "x86_64-apple-macos15.0",
        "-import-objc-header", str(EXTENSION / "WallpaperExtensionBridge.h"),
        "-I", str(GENERATED_BRIDGE),
        "-I", str(RENDERER / "external/open-wallpaper-engine/src/Platform/Apple"),
        "-Xcc", f"-fmodule-map-file={GENERATED_BRIDGE / 'WallpaperBridgeFFI.modulemap'}",
        "-L", str(RENDERER / "target/release"),
        f"-L{prefix}/opt/mwe-ffmpeg/lib",
        f"-L{prefix}/lib",
        f"-L{prefix}/opt/quickjs-ng/lib",
        f"-L{prefix}/opt/glslang/lib",
        "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
        "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../../../../Frameworks",
        f"-Xlinker", "-rpath", "-Xlinker", f"{prefix}/opt/mwe-ffmpeg/lib",
        f"-Xlinker", "-rpath", "-Xlinker", f"{prefix}/lib",
        f"-Xlinker", "-rpath", "-Xlinker", f"{prefix}/opt/quickjs-ng/lib",
        "-lwallpaper_bridge", "-lc++", "-lvulkan", "-llz4", "-lfreetype",
        "-lavformat", "-lavcodec", "-lavutil", "-lswresample", "-lavfilter", "-lavdevice", "-lswscale",
        "-lqjs", "-lglslang", "-lSPIRV", "-lglslang-default-resource-limits", "-liconv",
        "-framework", "WebKit", "-framework", "AppKit", "-framework", "Foundation",
        "-framework", "CoreGraphics", "-framework", "Metal", "-framework", "QuartzCore",
        "-framework", "IOSurface", "-framework", "CoreVideo", "-framework", "CoreMedia",
        "-framework", "CoreAudio", "-framework", "AudioToolbox", "-framework", "VideoToolbox",
        "-framework", "Accelerate",
        *ext_files,
        *shared_files,
        "-o", str(ext_bin)
    ]
    run_cmd(ext_cmd, cwd=ROOT, env=build_env)

    # Extension resources & Info.plist
    shutil.copy2(ROOT / "Resources/StarterWallpaper/preview.jpg", appex_resources / "preview.jpg")
    shutil.copy2(EXTENSION / "Phosphene-LICENSE.txt", appex_resources / "Phosphene-LICENSE.txt")
    
    marketing_version, project_version = get_project_versions()

    ext_plist = {
        "CFBundleDevelopmentRegion": "en",
        "CFBundleDisplayName": "WallpaperMachine Wallpapers",
        "CFBundleExecutable": "WallpaperMachineExtension",
        "CFBundleIdentifier": "app.wallpapermachine.wallpaper-extension",
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleName": "WallpaperMachineExtension",
        "CFBundlePackageType": "XPC!",
        "CFBundleShortVersionString": marketing_version,
        "CFBundleVersion": project_version,
        "LSMinimumSystemVersion": "15.0",
        "EXAppExtensionAttributes": {
            "EXExtensionPointIdentifier": "com.apple.wallpaper"
        }
    }
    with open(appex_dir / "Contents/Info.plist", "wb") as f:
        plistlib.dump(ext_plist, f)

    # Sign extension
    run_cmd(["codesign", "--force", "--sign", "-", "--entitlements", str(EXTENSION / "WallpaperExtension.entitlements"), str(appex_dir)], cwd=ROOT, env=build_env)

    # Also duplicate into Contents/PlugIns
    shutil.copytree(appex_dir, plugins / "WallpaperMachineExtension.appex", symlinks=True)

    # 3. Main App binary
    app_files = []
    for p in sorted(APP.rglob("*.swift")):
        if "Bridge/Generated" in str(p) and p.name != "WallpaperBridge.swift":
            continue
        app_files.append(str(p))

    main_bin = macos / "WallpaperMachine"
    main_cmd = [
        "swiftc",
        "-O" if configuration == "Release" else "-Onone",
        "-target", "x86_64-apple-macos15.0",
        "-import-objc-header", str(APP / "Bridge/WallpaperPreviewBridge.h"),
        "-I", str(GENERATED_BRIDGE),
        "-I", str(RENDERER / "external/open-wallpaper-engine/src/Platform/Apple"),
        "-Xcc", f"-fmodule-map-file={GENERATED_BRIDGE / 'WallpaperBridgeFFI.modulemap'}",
        "-L", str(RENDERER / "target/release"),
        f"-L{prefix}/opt/mwe-ffmpeg/lib",
        f"-L{prefix}/lib",
        f"-L{prefix}/opt/quickjs-ng/lib",
        f"-L{prefix}/opt/glslang/lib",
        "-F", str(BUILD / "MediaRemoteAdapter"),
        "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
        f"-Xlinker", "-rpath", "-Xlinker", f"{prefix}/opt/mwe-ffmpeg/lib",
        f"-Xlinker", "-rpath", "-Xlinker", f"{prefix}/lib",
        f"-Xlinker", "-rpath", "-Xlinker", f"{prefix}/opt/quickjs-ng/lib",
        "-lwallpaper_bridge", "-lc++", "-lvulkan", "-llz4", "-lfreetype",
        "-lavformat", "-lavcodec", "-lavutil", "-lswresample", "-lavfilter", "-lavdevice", "-lswscale",
        "-lqjs", "-lglslang", "-lSPIRV", "-lglslang-default-resource-limits", "-liconv",
        "-framework", "WebKit", "-framework", "AppKit", "-framework", "Foundation",
        "-framework", "CoreGraphics", "-framework", "Metal", "-framework", "QuartzCore",
        "-framework", "IOSurface", "-framework", "CoreVideo", "-framework", "CoreMedia",
        "-framework", "CoreAudio", "-framework", "AudioToolbox", "-framework", "VideoToolbox",
        "-framework", "Accelerate", "-framework", "CoreData", "-framework", "CoreImage",
        "-framework", "CoreText", "-framework", "OpenGL", "-framework", "UniformTypeIdentifiers",
        *app_files,
        *shared_files,
        "-o", str(main_bin)
    ]
    run_cmd(main_cmd, cwd=ROOT, env=build_env)

    # 4. App Resources
    app_icon = resources / "AppIcon.icns"
    compile_app_icon(app_icon)

    if (ROOT / "WebUI").is_dir():
        shutil.copytree(ROOT / "WebUI", resources / "WebUI", dirs_exist_ok=True)
    if (ROOT / "Resources/ReleaseBanners").is_dir():
        shutil.copytree(ROOT / "Resources/ReleaseBanners", resources / "ReleaseBanners", dirs_exist_ok=True)
    shutil.copytree(ROOT / "Resources/StarterWallpaper", resources / "StarterWallpaper", dirs_exist_ok=True)
    shutil.copy2(ROOT / "CHANGELOG.md", resources / "CHANGELOG.md")
    shutil.copy2(ROOT / "upstream/mediaremote-adapter/bin/mediaremote-adapter.pl", resources / "mediaremote-adapter.pl")
    shutil.copy2(ROOT / "upstream/mediaremote-adapter/LICENSE", resources / "LICENSE")

    convert_xcstrings(APP / "Resources/Localizable.xcstrings", resources)

    # Info.plist
    with open(APP / "Resources/Info.plist", "rb") as f:
        main_plist = plistlib.load(f)

    # Variable replacements
    main_plist["CFBundleDevelopmentRegion"] = "en"
    main_plist["CFBundleDisplayName"] = "WallpaperMachine"
    main_plist["CFBundleExecutable"] = "WallpaperMachine"
    main_plist["CFBundleIdentifier"] = "app.wallpapermachine"
    main_plist["CFBundleName"] = "WallpaperMachine"
    main_plist["CFBundlePackageType"] = "APPL"
    main_plist["CFBundleShortVersionString"] = marketing_version
    main_plist["CFBundleVersion"] = project_version
    main_plist["LSMinimumSystemVersion"] = "15.0"
    main_plist["CFBundleIconFile"] = "AppIcon"
    main_plist["CFBundleIconName"] = "AppIcon"

    with open(contents / "Info.plist", "wb") as f:
        plistlib.dump(main_plist, f)

    # Sign whole app bundle
    run_cmd(["codesign", "--force", "--sign", "-", str(frameworks / "MediaRemoteAdapter.framework")], cwd=ROOT, env=build_env)
    run_cmd(["codesign", "--force", "--sign", "-", "--options", "0", str(app_dir)], cwd=ROOT, env=build_env)

    print(f"{MARK.ok} Successfully assembled {app_dir}")
