"""Canonical repository paths, so no script re-derives them from `__file__`.

Two rules the layout depends on:

* `build/` holds Xcode derived data and built products, nothing else.
* `artifacts/` holds every piece of test or verification evidence. It is
  Git-ignored and disposable; `scripts/clean.py` removes it.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

APP = ROOT / "App"
EXTENSION = ROOT / "Extension"
SHARED = ROOT / "Shared"
TESTS = ROOT / "Tests"

# Swift bindings written by `uniffi-bindgen` during `scripts/build.py`.
GENERATED_BRIDGE = APP / "Bridge/Generated"

# The renderer: the Rust workspace (Shader, Core, Bridge; cargo's target/ is here) and
# the C++ areas, among them the scene engine the core crate builds with CMake.
RENDERER = ROOT / "Renderer"
ENGINE = RENDERER / "Engine"

# Vendored third-party code only, each item with its own license; provenance.json
# records where every vendored item and the project's imported code came from.
THIRD_PARTY = ROOT / "ThirdParty"
PROVENANCE = THIRD_PARTY / "provenance.json"

PROJECT_YML = ROOT / "project.yml"
XCODEPROJ = ROOT / "WallpaperMachine.xcodeproj"

BUILD = ROOT / "build"
PRODUCTS = BUILD / "Build/Products"

ARTIFACTS = ROOT / "artifacts"
TEST_ARTIFACTS = ARTIFACTS / "tests"
# Full tool logs from scripts/build.py; the terminal only shows their failures.
BUILD_ARTIFACTS = ARTIFACTS / "build"
RENDERER_ARTIFACTS = ARTIFACTS / "renderer"


def app_bundle(configuration="Debug"):
    """Path of the built application for a build configuration."""
    return PRODUCTS / configuration / "WallpaperMachine.app"


def main_checkout(root=ROOT):
    """The main checkout a tree belongs to: itself, or the one a worktree was made from."""
    import subprocess

    result = subprocess.run(["git", "-C", str(root), "rev-parse", "--path-format=absolute", "--git-common-dir"],
                            capture_output=True, text=True)
    return Path(result.stdout.strip()).parent if result.returncode == 0 else Path(root)
