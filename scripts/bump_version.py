#!/usr/bin/env python3
"""Bump app versions from a `release:` commit message.

Commit subject or a line in the message:

  release: patch
  release: minor
  release: major
  release: 1.2.3
  release: v1.2.3

`project.yml` is the source of truth. The generated Xcode project is updated
to match so a committed pbxproj stays in sync without running xcodegen.

On a `hotfix/` branch (`--branch`, or `GITHUB_REF_NAME` with `--ci`) only a patch
release is allowed, and it must be newer than every `vx.y.z` tag: a hotfix is cut
from the newest release and becomes the newest release (docs/release.md#hotfix-releases).
Any other branch releases only once it contains the newest tag, so `main` never ships
without a hotfix whose merge back failed.
With `--ci`, a pushed commit that a version tag already contains is not scanned, so
merging a released hotfix branch into `main` does not release its `release:` line again.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROJECT_YML = "project.yml"
PBXPROJ = "WallpaperMachine.xcodeproj/project.pbxproj"

RELEASE_LINE = re.compile(
    r"^release:\s*v?(major|minor|patch|\d+\.\d+\.\d+)\s*$",
    re.IGNORECASE | re.MULTILINE,
)
SEMVER = re.compile(r"^(\d+)\.(\d+)\.(\d+)$")
YML_MARKETING = re.compile(r'(MARKETING_VERSION:\s*")([^"]+)(")')
YML_BUILD = re.compile(r'(CURRENT_PROJECT_VERSION:\s*")([^"]+)(")')
PBX_MARKETING = re.compile(r"(MARKETING_VERSION = )([^;]+)(;)")
PBX_BUILD = re.compile(r"(CURRENT_PROJECT_VERSION = )([^;]+)(;)")
BUMP_RANK = {"patch": 1, "minor": 2, "major": 3}
HOTFIX_PREFIX = "hotfix/"


class VersionError(Exception):
    pass


def parse_specs(message: str) -> list[str]:
    return [match.group(1).lower() for match in RELEASE_LINE.finditer(message or "")]


def resolve_specs(specs: list[str]) -> str | None:
    if not specs:
        return None
    explicit = [spec for spec in specs if spec[0].isdigit()]
    if explicit:
        return explicit[-1]
    return max(specs, key=lambda spec: BUMP_RANK[spec])


def parse_semver(value: str) -> tuple[int, int, int]:
    match = SEMVER.fullmatch(value.strip())
    if not match:
        raise VersionError(f"invalid version {value!r}; expected x.y.z")
    return int(match.group(1)), int(match.group(2)), int(match.group(3))


def format_semver(parts: tuple[int, int, int]) -> str:
    return f"{parts[0]}.{parts[1]}.{parts[2]}"


def bump_marketing(current: str, spec: str) -> str:
    spec = spec.lower().lstrip("v")
    if not spec:
        raise VersionError("empty release spec")
    if spec[0].isdigit():
        target = format_semver(parse_semver(spec))
        if parse_semver(target) < parse_semver(current):
            raise VersionError(f"refusing to lower version from {current} to {target}")
        return target
    if spec not in BUMP_RANK:
        raise VersionError(f"unknown release spec {spec!r}")
    major, minor, patch = parse_semver(current)
    if spec == "major":
        return format_semver((major + 1, 0, 0))
    if spec == "minor":
        return format_semver((major, minor + 1, 0))
    return format_semver((major, minor, patch + 1))


def read_yml_versions(text: str) -> tuple[str, str]:
    marketing = YML_MARKETING.search(text)
    build = YML_BUILD.search(text)
    if not marketing or not build:
        raise VersionError("project.yml is missing MARKETING_VERSION or CURRENT_PROJECT_VERSION")
    return marketing.group(2), build.group(2)


def _replace_all(pattern: re.Pattern[str], text: str, value: str, label: str) -> str:
    updated, count = pattern.subn(rf"\g<1>{value}\g<3>", text)
    if count == 0:
        raise VersionError(f"no {label} entries to update")
    return updated


def replace_project_yml(text: str, marketing: str, build: str) -> str:
    text = _replace_all(YML_MARKETING, text, marketing, "MARKETING_VERSION")
    return _replace_all(YML_BUILD, text, build, "CURRENT_PROJECT_VERSION")


def replace_pbxproj(text: str, marketing: str, build: str) -> str:
    text = _replace_all(PBX_MARKETING, text, marketing, "MARKETING_VERSION")
    return _replace_all(PBX_BUILD, text, build, "CURRENT_PROJECT_VERSION")


def next_build(current: str) -> str:
    try:
        number = int(current)
    except ValueError as error:
        raise VersionError(f"CURRENT_PROJECT_VERSION must be an integer, got {current!r}") from error
    if number < 1:
        raise VersionError(f"CURRENT_PROJECT_VERSION must be >= 1, got {current}")
    return str(number + 1)


def collect_event_messages(event: dict, released=lambda commit_id: False) -> list[str]:
    """The messages of a push, leaving out commits `released` says a version tag already contains."""
    messages: list[str] = []
    head = event.get("head_commit") or {}
    for commit in [head, *(event.get("commits") or [])]:
        message = commit.get("message") or ""
        if not message or message in messages:
            continue
        if commit.get("id") and released(commit["id"]):
            continue
        messages.append(message)
    return messages


def version_tags(root: Path) -> list[str]:
    listed = subprocess.run(["git", "tag", "--list", "v*"], cwd=root, capture_output=True, text=True, check=False)
    return [tag for tag in listed.stdout.split() if SEMVER.fullmatch(tag[1:])]


def tagged_commit(root: Path, commit_id: str) -> bool:
    """Whether a `vx.y.z` tag contains the commit, which then was released already."""
    listed = subprocess.run(["git", "tag", "--list", "v*", "--contains", commit_id],
                            cwd=root, capture_output=True, text=True, check=False)
    return listed.returncode == 0 and any(SEMVER.fullmatch(tag[1:]) for tag in listed.stdout.split())


def newest_tag(tags: list[str]) -> str | None:
    return max(tags, key=lambda tag: parse_semver(tag[1:]), default=None)


def check_contains_newest_release(root: Path, tags: list[str]) -> None:
    """A release outside a hotfix branch must carry the newest released version."""
    newest = newest_tag(tags)
    if newest is None:
        return
    contained = subprocess.run(["git", "merge-base", "--is-ancestor", newest, "HEAD"],
                               cwd=root, capture_output=True, check=False)
    if contained.returncode != 0:
        raise VersionError(
            f"{newest} is not merged into this branch; merge that hotfix (`git merge --no-ff {newest}`) "
            "before releasing from here")


def check_hotfix(current: str, new: str, tags: list[str]) -> None:
    """A hotfix release is the next patch of the release it was cut from, and the newest version."""
    old, target = parse_semver(current), parse_semver(new)
    if target[:2] != old[:2] or target[2] <= old[2]:
        raise VersionError(f"a hotfix branch releases a patch of {current}, not {new}; use `release: patch`")
    newest = max((parse_semver(tag[1:]) for tag in tags), default=(0, 0, 0))
    if tags and old != newest:
        raise VersionError(
            f"this branch carries {current}, not the newest released {format_semver(newest)}; cut hotfix "
            "branches from the newest release tag")
    if target <= newest:
        raise VersionError(
            f"hotfix {new} is not newer than the released {format_semver(newest)}; cut hotfix branches "
            "from the newest release tag")


def spec_from_messages(messages: list[str]) -> str | None:
    specs: list[str] = []
    for message in messages:
        specs.extend(parse_specs(message))
    return resolve_specs(specs)


def plan_bump(root: Path, spec: str) -> dict[str, str | bool]:
    yml_path = root / PROJECT_YML
    text = yml_path.read_text()
    current_marketing, current_build = read_yml_versions(text)
    new_marketing = bump_marketing(current_marketing, spec)
    changed = new_marketing != current_marketing
    new_build = next_build(current_build) if changed else current_build
    return {
        "spec": spec,
        "old_marketing": current_marketing,
        "new_marketing": new_marketing,
        "old_build": current_build,
        "new_build": new_build,
        "changed": changed,
        "tag": f"v{new_marketing}",
    }


def apply_bump(root: Path, marketing: str, build: str) -> None:
    yml_path = root / PROJECT_YML
    pbx_path = root / PBXPROJ
    yml_path.write_text(replace_project_yml(yml_path.read_text(), marketing, build))
    pbx_path.write_text(replace_pbxproj(pbx_path.read_text(), marketing, build))


def write_github_output(path: Path, result: dict[str, str | bool]) -> None:
    lines = [f"{key}={str(value).lower() if isinstance(value, bool) else value}" for key, value in result.items()]
    with path.open("a", encoding="utf-8") as handle:
        handle.write("\n".join(lines) + "\n")


def resolve_cli_spec(args: argparse.Namespace) -> str | None:
    if args.spec:
        return args.spec.strip().lower().lstrip("v")
    messages: list[str] = []
    if args.message:
        messages.append(args.message)
    if args.message_file:
        messages.append(Path(args.message_file).read_text())
    if args.ci:
        spec = os.environ.get("RELEASE_SPEC", "").strip()
        if spec:
            return spec.lower().lstrip("v")
        event_path = os.environ.get("GITHUB_EVENT_PATH")
        if event_path:
            event = json.loads(Path(event_path).read_text())
            messages.extend(collect_event_messages(event, lambda commit_id: tagged_commit(args.root, commit_id)))
    return spec_from_messages(messages)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--spec", help="patch, minor, major, or x.y.z")
    parser.add_argument("--message", help="commit message to scan for release: lines")
    parser.add_argument("--message-file", help="file containing commit message(s)")
    parser.add_argument("--apply", action="store_true", help="write project.yml and the Xcode project")
    parser.add_argument("--ci", action="store_true", help="read RELEASE_SPEC or GITHUB_EVENT_PATH")
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--branch", help="branch being released (defaults to GITHUB_REF_NAME with --ci)")
    parser.add_argument("--output", help="GitHub Actions output file (defaults to GITHUB_OUTPUT)")
    args = parser.parse_args()
    try:
        spec = resolve_cli_spec(args)
        if not spec:
            result: dict[str, str | bool] = {"changed": False, "spec": ""}
            print("No release: spec in commit message; skipping.")
        else:
            result = plan_bump(args.root, spec)
            branch = args.branch or (os.environ.get("GITHUB_REF_NAME", "") if args.ci else "")
            if result["changed"] and branch.startswith(HOTFIX_PREFIX):
                check_hotfix(str(result["old_marketing"]), str(result["new_marketing"]), version_tags(args.root))
            elif result["changed"] and branch:
                check_contains_newest_release(args.root, version_tags(args.root))
            if result["changed"] and args.apply:
                apply_bump(args.root, str(result["new_marketing"]), str(result["new_build"]))
            if result["changed"]:
                print(
                    f"{result['old_marketing']} ({result['old_build']}) -> "
                    f"{result['new_marketing']} ({result['new_build']})"
                )
            else:
                print(f"Version already {result['new_marketing']}; skipping.")
        output = args.output or os.environ.get("GITHUB_OUTPUT")
        if output:
            write_github_output(Path(output), result)
        return 0
    except (VersionError, OSError, json.JSONDecodeError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
