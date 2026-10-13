#!/usr/bin/env python3
"""Install the project's LGPL FFmpeg build (`Formula/mwe-ffmpeg.rb`) through Homebrew.

Homebrew only installs formulae that live in a tap, so this publishes the
repository's formula into a local, git-less tap (`WallpaperMachine/local`)
and installs it from there. Re-running after the formula changed reinstalls it;
re-running otherwise is a no-op. Why the build exists at all is recorded in
LICENSING.md.
"""
import argparse
from pathlib import Path
import shutil
import subprocess
import sys

from lib.glyphs import markers
from lib.paths import ROOT

MARK = markers()
TAP = "WallpaperMachine/local"
FORMULA = "mwe-ffmpeg"
SOURCE = ROOT / "Formula" / f"{FORMULA}.rb"


def brew_bin():
    candidates = [
        shutil.which("brew"),
        str(Path.home() / "homebrew/bin/brew"),
        "/usr/local/bin/brew",
        "/opt/homebrew/bin/brew",
    ]
    for c in candidates:
        if c and Path(c).is_file():
            return c
    return "brew"


def brew(*args, capture=False):
    cmd = [brew_bin(), *args]
    if capture:
        return subprocess.run(cmd, text=True, capture_output=True)
    return subprocess.run(cmd, check=True)


def tap_formula_path():
    result = brew("--repository", TAP, capture=True)
    if not result.stdout.strip():
        raise RuntimeError(f"Cannot locate Homebrew tap: {result.stderr.strip()}")
    return Path(result.stdout.strip()) / "Formula" / SOURCE.name


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true", help="Report whether the installed formula matches the repository; install nothing.")
    args = parser.parse_args()
    target = tap_formula_path()
    published = target.is_file() and target.read_bytes() == SOURCE.read_bytes()
    installed = brew("list", "--versions", FORMULA, capture=True).returncode == 0
    prefix = brew("--prefix", FORMULA, capture=True)
    receipt = Path(prefix.stdout.strip()) / ".brew" / SOURCE.name if prefix.returncode == 0 else None
    current = installed and receipt is not None and receipt.is_file() and receipt.read_bytes() == SOURCE.read_bytes()
    if args.check:
        if current:
            print(f"{MARK.ok} {FORMULA} installed from the current formula")
            return 0
        print(f"{MARK.missing} {FORMULA} {'is not installed' if not installed else 'was installed from an older formula'}; run python3 scripts/install_ffmpeg.py")
        return 1
    if not target.parent.is_dir():
        brew("tap-new", "--no-git", TAP)
    if not published:
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(SOURCE, target)
    if not installed:
        brew("install", "--quiet", f"{TAP}/{FORMULA}")
    elif not current:
        brew("reinstall", "--quiet", f"{TAP}/{FORMULA}")
    print(f"{MARK.ok} {FORMULA} installed at {brew('--prefix', FORMULA, capture=True).stdout.strip()}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except subprocess.CalledProcessError as error:
        sys.exit(error.returncode)
