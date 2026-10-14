#!/usr/bin/env python3
"""Release notes and CHANGELOG.md sections for the commits between two version tags.

Two writers read the same input, the commits in the range:

* `--ai` hands them to a language model (Claude Opus behind an Anthropic Messages API
  gateway; the key comes from RELEASE_NOTES_API_KEY) that writes the same notes in
  English and Simplified Chinese, merging related commits and leaving internal work
  out. Releases always use it. A reply that is missing either language is refused.
* Without it the commits are listed in English, grouped by the `type(scope): subject`
  convention the repository follows. That listing is a developer preview: it is not
  published. Documentation, test and tooling commits are counted rather than listed,
  and an unrecognised commit lands under "Other changes", so none disappears silently.

A version's notes are written once, into its CHANGELOG.md section, when the version
is cut. The app bundles both languages. `--release-body` publishes only the English
part and the compare link on GitHub, then adds the install footer. A hand-pushed
tag with no section is written once, into the working tree, before the build.
A recorded bilingual section is reused without another model request.
A `##` heading that is not `x.y.z` — `## Unreleased`, a prerelease token, or a
heading inside the notes — stops publishing. The app rejects that whole file, so
the heading is not kept and not dropped.

    python3 scripts/release_notes.py                              # English listing, not for publish
    python3 scripts/release_notes.py --ai --tag v0.6.0 --to HEAD  # bilingual notes, before the tag exists
    python3 scripts/release_notes.py --tag v0.6.0 --release-body --output notes.md
    python3 scripts/release_notes.py --ai --changelog --apply
    python3 scripts/release_notes.py --rebuild-changelog --apply

`CHANGELOG.md` is written with `--apply`, and also when `--release-body` has to
generate the current section. `--output` writes the file it is given.
"""
from __future__ import annotations

import argparse
from datetime import date
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
from typing import NamedTuple
import urllib.error
import urllib.request

from lib import dmg
from lib.glyphs import markers
from lib.paths import PROJECT_YML, ROOT

MARK = markers()
CHANGELOG = ROOT / "CHANGELOG.md"
APPLICATION = "WallpaperMachine"

# `type(scope)!: subject`, the convention docs/conventions.md describes.
CONVENTIONAL = re.compile(r"^(?P<type>[a-z]+)(?:\((?P<scope>[^)]*)\))?(?P<breaking>!)?:[ \t]*(?P<subject>.+)$")
VERSION_TAG = re.compile(r"^v?(\d+)\.(\d+)\.(\d+)$")
# The Version workflow's own commit; it describes the release, it is not part of it.
BUMP_COMMIT = re.compile(r"^chore: bump version to \d+\.\d+\.\d+$")
BREAKING_BODY = re.compile(r"^BREAKING[ -]CHANGE:", re.MULTILINE)
MARKETING_VERSION = re.compile(r'MARKETING_VERSION:\s*"([^"]+)"')
REMOTE_SLUG = re.compile(r"(?:https://github\.com/|git@github\.com:)(?P<slug>[^/]+/[^/\s]+?)(?:\.git)?/?$")
DEPLOYMENT_TARGET = re.compile(r"MACOSX_DEPLOYMENT_TARGET:\s*\"?([\d.]+)")

# One bullet, one line: past this a subject is cut at a word boundary and the linked
# commit carries the rest.
SUBJECT_LIMIT = 140

# Boundary between the notes the in-app updater shows and the download instructions
# that belong only to the release page. App/Services/GitHub reads the same marker.
NOTES_END = "<!-- release-notes-end -->"

FIELD = "\x1f"
RECORD = "\x1e"

# Where a commit type is reported. A type that is absent is user-visible by
# default: an unrecognised commit is listed under "Other changes", never hidden.
GROUPS = {
    "feat": "features",
    "fix": "fixes",
    "perf": "performance",
    "docs": "internal",
    "test": "internal",
    "tests": "internal",
    "chore": "internal",
    "ci": "internal",
    "build": "internal",
    "style": "internal",
    "refactor": "internal",
}
SECTIONS = (
    ("breaking", "Breaking changes"),
    ("features", "New"),
    ("fixes", "Fixed"),
    ("performance", "Performance"),
    ("other", "Other changes"),
)

CHANGELOG_PREAMBLE = """\
# Changelog

Every published version, newest first. Each section is written when its version is
cut, by [`scripts/release_notes.py`](scripts/release_notes.py) from the commits
between two version tags: a language model writes them up for users, where older
sections list the commits. Each section states the same notes in English and
Simplified Chinese. The app's What's New window offers both translations; the
GitHub Release body repeats only the English notes. See
[docs/release.md](docs/release.md) for how a version is cut.

"""

# The release-notes model. Every setting but the key has a default; the key is a
# secret and only ever comes from the environment.
API_KEY_VARIABLE = "RELEASE_NOTES_API_KEY"
API_BASE_VARIABLE = "RELEASE_NOTES_API_BASE"
MODEL_VARIABLE = "RELEASE_NOTES_MODEL"
API_BASE = "https://sub2api.moraxcheng.me"
MODEL = "claude-opus-5-5"
# Cloudflare in front of the gateway refuses urllib's default agent (error 1010).
USER_AGENT = "WallpaperMachine-release-notes"
# Room for the notes and for any thinking the gateway turns on. The reply streams, so
# a slow answer never trips a proxy's time-to-first-byte limit; a quiet connection
# times out after READ_TIMEOUT and the whole reply after DEADLINE seconds, because the
# Version workflow holds its branch lock while it waits.
MAX_TOKENS = 32000
READ_TIMEOUT = 120
DEADLINE = 600
# What the model reads of each commit: user-visible commits bring their body, cut at
# BODY_LIMIT, until BODIES_BUDGET characters are spent; the rest bring their subject.
# A squash merge's body is read per commit it lists, each with its own BODY_LIMIT.
BODY_LIMIT = 1500
BODIES_BUDGET = 120_000
# A squash merge lists each of its commits as `* type(scope): subject`, then its body.
SQUASHED = re.compile(r"^\* (?=[a-z]+(?:\([^)]*\))?!?:)", re.MULTILINE)
# Trailers and the rule GitHub puts before a squash merge's own; they only spend the budget.
TRAILER = re.compile(r"^(?:(?:co-authored-by|signed-off-by|reviewed-by|claude-session):.*|-{3,}[ \t]*)$",
                     re.IGNORECASE | re.MULTILINE)
MODEL_SECTIONS = (
    ("breaking", "Breaking changes"),
    ("new", "New"),
    ("improved", "Improved"),
    ("fixed", "Fixed"),
)
# Category headings inside a language block. Chinese names match the panel's
# existing translations where it has them; Improved has no panel key, so 改进.
LANGUAGE_HEADINGS = {
    "english": {key: heading for key, heading in MODEL_SECTIONS},
    "chinese": {
        "breaking": "不兼容变更",
        "new": "新增",
        "improved": "改进",
        "fixed": "修复",
    },
}
LANGUAGE_BLOCKS = (("english", "English"), ("chinese", "简体中文"))
CJK = re.compile(r"[\u4e00-\u9fff]")
LATIN = re.compile(r"[A-Za-z]")
SYSTEM_PROMPT = """\
You are the release editor for WallpaperMachine, a native macOS app for Apple silicon \
that plays Wallpaper Engine scene, video and web wallpapers on the desktop and, \
experimentally, the lock screen. Its control panel manages the wallpaper library, \
browses and downloads Steam Workshop items and holds the settings. The panel ships \
in English and Simplified Chinese (简体中文).

You turn the commits of one release into the notes users read on the GitHub release \
page, in CHANGELOG.md and in the app's What's New window. Write each note twice: \
once in English, once in Simplified Chinese. The two say the same thing.

Rules:
- Write for people who use the app, not for its developers: what they can do now, \
what works better, what no longer goes wrong. No code identifiers, file or class \
names, commit hashes, test names or internal jargon.
- Report only what the commits support. Never invent features, numbers, platforms or \
dates. Leave a change out when you cannot tell whether users would notice it.
- Leave out purely internal work: documentation, tests, CI, refactoring, build \
tooling and verification records.
- One bullet per user-visible change, in both languages. Merge commits that describe \
the same change. Order each list by how much it matters to users. The chinese string \
of a bullet is the english string's equivalent, not a summary of a different change \
and not a copy of the English.
- Each string is one plain sentence, at most 30 words, with no trailing period and no \
Markdown, links or emoji. chinese is Simplified Chinese, not Traditional, not a \
romanization, and not English with a character added. Keep product names \
(WallpaperMachine, Steam, Workshop, macOS) as they are.
- Name places in the app the way the panel does: Settings 设置, General 通用, \
Appearance 外观, Performance 性能, Playback 播放, Library & Steam 壁纸库与 Steam, \
Discover 发现, Installed 已安装, About 关于, Lock screen 锁定屏幕.
- breaking: changes that make users act or take away behaviour they relied on. new: \
things users can do that they could not before. improved: faster, smoother or \
clearer behaviour, performance included. fixed: problems that no longer happen, \
described by what the user saw. A section is the same length in both languages.
- summary: one or two sentences on what the release means for users, in both \
languages, or empty strings in both when the lists say it all. Never fill only one.
- Claims: never claim energy, battery or power savings, even when a commit measured \
less work. Never call anything fully supported or fully compatible. Keep \
"optional", "experimental" or "off by default" on opt-in features such as the \
Native Metal renderer, native video playback, content pacing and on-demand scene \
idle, and on the animated lock screen. The Chinese keeps the same qualifier.

Reply with only a JSON object, no prose and no code fence, with exactly these keys:
{"summary": {"english": string, "chinese": string}, "breaking": [{"english": string, "chinese": string}], "new": [{"english": string, "chinese": string}], "improved": [{"english": string, "chinese": string}], "fixed": [{"english": string, "chinese": string}]}
Use an empty list for a section with nothing in it. Do not write headings; the \
script adds them."""


class NotesError(Exception):
    """A condition that stops note generation; the message is the whole report."""


class Change(NamedTuple):
    """One commit, already classified for the section it belongs to."""

    group: str
    scope: str
    subject: str
    sha: str


def git(*args, cwd=ROOT):
    result = subprocess.run(["git", *map(str, args)], cwd=cwd, capture_output=True, text=True)
    if result.returncode != 0:
        raise NotesError(f"git {' '.join(map(str, args))} failed: {result.stderr.strip() or result.stdout.strip()}")
    return result.stdout


def version_key(value):
    match = VERSION_TAG.match(value.strip())
    if not match:
        raise NotesError(f"Not an x.y.z version: {value!r}")
    return tuple(int(part) for part in match.groups())


def display_version(value):
    return ".".join(str(part) for part in version_key(value))


def repository(cwd=ROOT):
    """`owner/repo` from the GitHub origin remote, or None when there is no usable one."""
    try:
        url = git("config", "--get", "remote.origin.url", cwd=cwd).strip()
    except NotesError:
        return None
    match = REMOTE_SLUG.search(url)
    return match.group("slug") if match else None


def current_version(project=PROJECT_YML):
    match = MARKETING_VERSION.search(Path(project).read_text(encoding="utf-8"))
    if not match:
        raise NotesError(f"No MARKETING_VERSION in {project}")
    return match.group(1)


def deployment_target(project=PROJECT_YML):
    match = DEPLOYMENT_TARGET.search(Path(project).read_text(encoding="utf-8"))
    return match.group(1) if match else None


def version_tags(cwd=ROOT):
    """Every `vx.y.z` tag, oldest version first."""
    tags = [tag for tag in git("tag", "--list", "v*", cwd=cwd).split() if VERSION_TAG.match(tag)]
    return sorted(tags, key=version_key)


def is_ancestor(candidate, revision, cwd=ROOT):
    result = subprocess.run(["git", "merge-base", "--is-ancestor", candidate, revision], cwd=cwd, capture_output=True, text=True)
    return result.returncode == 0


def previous_tag(version, revision, cwd=ROOT, tags=None):
    """The newest released version below `version` that `revision` descends from."""
    target = version_key(version)
    for tag in reversed(tags if tags is not None else version_tags(cwd)):
        if version_key(tag) >= target:
            continue
        if is_ancestor(tag, revision, cwd):
            return tag
    return None


def commits(previous, revision, cwd=ROOT):
    """`(sha, subject, body)` for every non-merge commit in the range, newest first."""
    span = f"{previous}..{revision}" if previous else revision
    raw = git("log", "--no-merges", f"--format=%h{FIELD}%s{FIELD}%b{RECORD}", span, cwd=cwd)
    for record in raw.split(RECORD):
        record = record.strip("\n")
        if not record:
            continue
        sha, subject, body = record.split(FIELD, 2)
        yield sha, subject, body


def sentence(text):
    """A bullet reads as a sentence: no trailing period, leading capital, one line long.

    A commit message that ran to a paragraph would otherwise widen the whole section;
    the linked commit still carries every word.
    """
    text = " ".join(text.split()).rstrip(".").strip()
    if len(text) > SUBJECT_LIMIT:
        head = text[:SUBJECT_LIMIT].rsplit(" ", 1)[0].rstrip(",;:—-")
        text = f"{head}…"
    return text[:1].upper() + text[1:] if text else text


def classify(sha, subject, body=""):
    """The change a commit contributes, or None when it only records the release itself."""
    if BUMP_COMMIT.match(subject.strip()):
        return None
    match = CONVENTIONAL.match(subject.strip())
    if not match:
        return Change("other", "", sentence(subject), sha)
    breaking = bool(match.group("breaking")) or bool(BREAKING_BODY.search(body or ""))
    group = "breaking" if breaking else GROUPS.get(match.group("type"), "other")
    return Change(group, (match.group("scope") or "").strip(), sentence(match.group("subject")), sha)


def changes(previous, revision, cwd=ROOT):
    collected = []
    for sha, subject, body in commits(previous, revision, cwd):
        change = classify(sha, subject, body)
        if change is not None:
            collected.append(change)
    return collected


def group_changes(collected):
    """Section key -> its changes, newest first, with repeated wording collapsed."""
    grouped = {}
    seen = set()
    for change in collected:
        key = (change.group, change.scope, change.subject.lower())
        if key in seen:
            continue
        seen.add(key)
        grouped.setdefault(change.group, []).append(change)
    return grouped


def commit_link(sha, repo=None):
    return f"[`{sha}`](https://github.com/{repo}/commit/{sha})" if repo else f"`{sha}`"


def bullet(change, repo=None):
    scope = f"**{change.scope}** — " if change.scope else ""
    return f"- {scope}{change.subject} ({commit_link(change.sha, repo)})"


def compare_link(previous, tag, repo):
    if not repo:
        return None
    if previous:
        return f"**Full changelog**: https://github.com/{repo}/compare/{previous}...{tag}"
    return f"**Full changelog**: https://github.com/{repo}/commits/{tag}"


def nothing_to_say(previous):
    span = f"since `{previous}`" if previous else "in this history"
    return f"No user-visible changes {span}."


def nothing_to_say_zh(previous):
    if previous:
        return f"自 `{previous}` 以来没有用户能察觉的变化。"
    return "这段历史里没有用户能察觉的变化。"


def install_footer(version, target=None, built_from=None):
    """The part of the release body that belongs to the web page, not to the app.

    The marker is the contract with the in-app updater: everything after it is
    download instructions the app already knows, so its "What's new" card stops there.

    `built_from` names the revision the image was built from. The build provenance
    attestation cannot: its SLSA predicate records the revision that triggered the
    workflow run, which for a CI-produced tag is the push that asked for the bump,
    not the bump commit the tag points at. This line is checkable —
    `git rev-parse <tag>^{commit}` must equal it.
    """
    image = dmg.image_name(display_version(version))
    tag = f"v{display_version(version)}"
    requirement = f"Apple silicon (arm64), macOS {target} or later." if target else "Apple silicon (arm64)."
    lines = [
        NOTES_END,
        "",
        "### Install",
        "",
        f"1. Download `{image}` and open it.",
        f"2. Drag {APPLICATION} onto the Applications folder in the window that opens. In-app updates",
        "   replace a copy in `/Applications` or `~/Applications` and nowhere else.",
        "3. The app is signed with the project's own certificate but not notarized, so macOS stops",
        "   its first launch: open System Settings → Privacy & Security, click Open Anyway, and confirm.",
        "",
        "### Verify the download",
        "",
        "```sh",
        f"shasum -a 256 -c {image}.sha256",
        "```",
        "",
        requirement,
    ]
    if built_from:
        lines += ["", f"Built from `{tag}` at `{built_from}` (`git rev-parse {tag}^{{commit}}` must match)."]
    return "\n".join(lines)


def release_body(notes, version, built_from=None):
    """What GitHub shows: English notes, the compare link, then the install footer."""
    english, chinese = language_blocks(require_bilingual(notes))
    parts = [f"### English\n\n{english.strip()}"]
    parts.extend(line for line in chinese.splitlines() if line.startswith("**Full changelog**:"))
    parts.append(install_footer(version, deployment_target(), built_from))
    return "\n\n".join(parts) + "\n"


def render(version, collected, previous=None, repo=None, internal_label=True):
    """The listed notes for one version: sections, an internal-work count, a compare link."""
    tag = f"v{display_version(version)}"
    grouped = group_changes(collected)
    parts = []
    for key, heading in SECTIONS:
        entries = grouped.get(key)
        if not entries:
            continue
        parts.append(f"### {heading}\n\n" + "\n".join(bullet(change, repo) for change in entries))
    internal = len(grouped.get("internal", ()))
    if not parts:
        parts.append(nothing_to_say(previous))
    elif internal and internal_label:
        noun = "commit" if internal == 1 else "commits"
        parts.append(f"Plus {internal} documentation, test and tooling {noun}.")
    link = compare_link(previous, tag, repo)
    if link:
        parts.append(link)
    return "\n\n".join(parts).strip() + "\n"


# --- Written by the release-notes model ---------------------------------------------


def model_settings(environ=None):
    """`(messages URL, model, key)`; a missing key stops the run before any request."""
    environ = os.environ if environ is None else environ
    key = environ.get(API_KEY_VARIABLE, "").strip()
    if not key:
        raise NotesError(f"{API_KEY_VARIABLE} is not set; --ai needs the release-notes model's key (docs/release.md)")
    base = (environ.get(API_BASE_VARIABLE, "").strip() or API_BASE).rstrip("/")
    url = base + ("/messages" if base.endswith("/v1") else "/v1/messages")
    return url, environ.get(MODEL_VARIABLE, "").strip() or MODEL, key


def body_parts(body):
    """`(text, [(subject, body, internal), ...])`: a commit body without its trailers.

    A squash merge's body lists the commits it merged, each as a `* type(scope): subject`
    line followed by that commit's body; those come back one by one, and `text` is what
    precedes the first. Any other body is all `text`.
    """
    def tidy(text):
        return re.sub(r"\n{3,}", "\n\n", text).strip()

    text, *squashed = SQUASHED.split(TRAILER.sub("", body))
    parts = []
    for part in squashed:
        subject, _, rest = part.partition("\n")
        subject = " ".join(subject.split())
        match = CONVENTIONAL.match(subject)
        parts.append((subject, tidy(rest), bool(match) and GROUPS.get(match.group("type")) == "internal"))
    return tidy(text), parts


def model_prompt(version, previous, entries):
    """The user turn: the release, then its commits newest first.

    `entries` holds `(sha, subject, body, internal)`. Internal commits bring only their
    subject, which is enough to leave them out; the others bring their body too, cut
    at BODY_LIMIT, until BODIES_BUDGET characters of bodies are spent. A squash merge
    brings every commit it lists the same way, so a long one loses none of them.
    """
    since = f"since {previous}" if previous else "from the start of the history"
    noun = "commit" if len(entries) == 1 else "commits"
    lines = [f"WallpaperMachine {display_version(version)}: {len(entries)} {noun} {since}, newest first.", ""]
    budget = BODIES_BUDGET

    def add(text, indent):
        nonlocal budget
        if text and budget > 0:
            if len(text) > BODY_LIMIT:
                text = text[:BODY_LIMIT].rstrip() + "…"
            budget -= len(text)
            lines.extend(f"{indent}{row}".rstrip() for row in text.splitlines())

    for sha, subject, body, internal in entries:
        lines.append(f"* {sha} {subject}")
        if not internal:
            text, squashed = body_parts(body)
            add(text, "    ")
            for part_subject, part_body, part_internal in squashed:
                lines.append(f"    * {part_subject}")
                if not part_internal:
                    add(part_body, "      ")
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def stream(url, key, payload):
    """POST a streaming Messages API request; the server-sent event lines of the reply."""
    request = urllib.request.Request(url, data=json.dumps(payload).encode(), method="POST", headers={
        "content-type": "application/json",
        "accept": "text/event-stream",
        "anthropic-version": "2023-06-01",
        "x-api-key": key,
        "user-agent": USER_AGENT,
    })
    started = time.monotonic()
    try:
        with urllib.request.urlopen(request, timeout=READ_TIMEOUT) as response:
            for raw in response:
                if time.monotonic() - started > DEADLINE:
                    raise NotesError(f"The release-notes model had not finished after {DEADLINE} seconds")
                yield raw.decode("utf-8", errors="replace").rstrip("\r\n")
    except urllib.error.HTTPError as error:
        detail = error.read().decode("utf-8", errors="replace").strip()
        try:
            detail = json.loads(detail)["error"]["message"]
        except (ValueError, KeyError, TypeError):
            detail = detail[:300]
        raise NotesError(f"The release-notes model refused the request (HTTP {error.code}): {detail}") from None
    except (urllib.error.URLError, OSError) as error:
        raise NotesError(f"Could not reach the release-notes model at {url}: {getattr(error, 'reason', error)}") from None


def streamed_text(lines):
    """The text of a streamed Messages API reply. Thinking blocks and pings are skipped;
    an error event or a reply cut off at the token limit stops the run."""
    text = []
    stop = None
    for line in lines:
        if not line.startswith("data:"):
            continue
        data = line[5:].strip()
        if data == "[DONE]":
            continue
        try:
            event = json.loads(data)
        except ValueError:
            raise NotesError(f"The release-notes model sent an unreadable event: {data[:120]!r}") from None
        kind = event.get("type")
        if kind == "content_block_delta" and event.get("delta", {}).get("type") == "text_delta":
            text.append(event["delta"].get("text", ""))
        elif kind == "message_delta":
            stop = event.get("delta", {}).get("stop_reason") or stop
        elif kind == "error":
            error = event.get("error") or {}
            raise NotesError(f"The release-notes model failed: {error.get('message') or error.get('type') or event}")
    if stop == "max_tokens":
        raise NotesError(f"The release-notes model ran out of its {MAX_TOKENS} output tokens before it finished")
    return "".join(text)


def plain_line(text):
    """One line of prose: whitespace collapsed, no list or heading marker. The
    release-notes boundary comment would end the in-app card early, so HTML comments
    are refused."""
    line = re.sub(r"^(?:[-*•]|#+)\s+", "", " ".join(text.split()))
    if "<!--" in line or "-->" in line:
        raise NotesError(f"The release-notes model wrote an HTML comment into the notes: {line[:120]!r}")
    return line


def language_text(value, label):
    """One required string. A missing or non-text language stops the run."""
    if not isinstance(value, str):
        raise NotesError(f"The release-notes model's {label} is not text")
    return plain_line(value)


def require_translation(english, chinese, label):
    """Both sides of a note must be present, and the Chinese must be Chinese."""
    if bool(english) != bool(chinese):
        raise NotesError(f"The release-notes model's {label} is missing a language")
    if not chinese:
        return
    if not LATIN.search(english):
        raise NotesError(f"The release-notes model's {label} English is not English: {english[:80]!r}")
    if not CJK.search(chinese):
        raise NotesError(f"The release-notes model's {label} is not Simplified Chinese: {chinese[:80]!r}")
    if english == chinese:
        raise NotesError(f"The release-notes model's {label} repeats the English as Chinese")


def parse_pair(value, label):
    """`{"english": str, "chinese": str}`, or None when both sides are empty."""
    if not isinstance(value, dict) or set(value) != {"english", "chinese"}:
        raise NotesError(f"The release-notes model's {label} must be english and chinese text")
    english = language_text(value["english"], f"{label}.english").rstrip(".。")
    chinese = language_text(value["chinese"], f"{label}.chinese").rstrip(".。")
    if not english and not chinese:
        return None
    require_translation(english, chinese, label)
    return english, chinese


def parse_notes(text):
    """The model's JSON reply as bilingual summary and section pairs, checked.

    A section item is `(english, chinese)`. Missing sections are empty. The old
    English-only shape, a missing language, or Chinese that is not Chinese stops
    the run.
    """
    reply = text.strip()
    fenced = re.fullmatch(r"```(?:json)?\s*(.*?)\s*```", reply, re.DOTALL)
    if fenced:
        reply = fenced.group(1)
    try:
        data = json.loads(reply)
    except ValueError:
        raise NotesError(f"The release-notes model did not reply with JSON: {text.strip()[:200]!r}") from None
    keys = {"summary", *(key for key, _ in MODEL_SECTIONS)}
    if not isinstance(data, dict) or set(data) - keys:
        raise NotesError(f"The release-notes model replied with unexpected fields: {text.strip()[:200]!r}")
    summary = data.get("summary")
    if summary in (None, ""):
        summary = {"english": "", "chinese": ""}
    parsed = parse_pair(summary, "summary")
    notes = {"summary": parsed or ("", "")}
    for key, _ in MODEL_SECTIONS:
        items = data.get(key) or []
        if not isinstance(items, list):
            raise NotesError(f"The release-notes model's {key!r} is not a list of bilingual bullets")
        bullets = []
        for index, item in enumerate(items):
            pair = parse_pair(item, f"{key}[{index}]")
            if pair:
                bullets.append(pair)
        notes[key] = bullets
    return notes


def empty_notes():
    return {"summary": ("", ""), **{key: [] for key, _ in MODEL_SECTIONS}}


def render_language(code, heading, notes, previous):
    """One language block: optional summary, then `####` categories, or the empty line."""
    index = 0 if code == "english" else 1
    parts = [notes["summary"][index]] if notes["summary"][index] else []
    for key, _ in MODEL_SECTIONS:
        items = [item[index] for item in notes[key] if item[index]]
        if items:
            parts.append(f"#### {LANGUAGE_HEADINGS[code][key]}\n\n" + "\n".join(f"- {item}" for item in items))
    if not parts:
        parts.append(nothing_to_say(previous) if code == "english" else nothing_to_say_zh(previous))
    return f"### {heading}\n\n" + "\n\n".join(parts)


def render_model_notes(version, notes, previous=None, repo=None):
    """Bilingual notes: `### English`, then `### 简体中文`, categories at `####`.

    The compare link follows both blocks, outside either language's prose.
    """
    parts = [render_language(code, heading, notes, previous) for code, heading in LANGUAGE_BLOCKS]
    link = compare_link(previous, f"v{display_version(version)}", repo)
    if link:
        parts.append(link)
    return "\n\n".join(parts).strip() + "\n"


def language_blocks(text):
    """`(english prose, chinese prose)` from notes that use the two required headings.

    A trailing compare link stays with the Chinese span; callers that only need
    prose ignore that line. None when the headings are missing or out of order.
    """
    english = re.search(r"^### English[ \t]*$", text, re.MULTILINE)
    chinese = re.search(r"^### 简体中文[ \t]*$", text, re.MULTILINE)
    if not english or not chinese or english.start() > chinese.start():
        return None
    return text[english.end():chinese.start()], text[chinese.end():]


def require_bilingual(text):
    """Bundled-history contract: English, then 简体中文, categories at `####`, Chinese present.

    Listed English notes, a missing language, or a `###` category heading fail.
    The compare link may follow the Chinese block.
    """
    body = text.split(NOTES_END, 1)[0]
    headings = re.findall(r"^###[ \t]+(.+?)[ \t]*$", body, re.MULTILINE)
    if headings != ["English", "简体中文"]:
        raise NotesError(
            "Release notes must be ### English then ### 简体中文, with category headings at ####. "
            "Listed English notes are a developer preview and are not published."
        )
    blocks = language_blocks(body)
    if blocks is None:
        raise NotesError("Release notes are missing a language block")
    prose = [
        "\n".join(line for line in block.splitlines()
                  if not line.startswith("#") and not line.startswith("**Full changelog**")).strip()
        for block in blocks
    ]
    english, chinese = prose
    if not english or not chinese:
        raise NotesError("Release notes are missing a language")
    require_translation(english, chinese, "recorded notes")
    if len(re.findall(r"^[-*] ", english, re.MULTILINE)) != len(re.findall(r"^[-*] ", chinese, re.MULTILINE)):
        raise NotesError("Release notes have different numbers of English and Chinese changes")
    return text


def bundled_heading_version(line):
    """The `x.y.z` `AppReleaseHistory` accepts for this `##` line, or None.

    Swift takes the first token after `## ` and parses a semantic version:
    optional `v`/`V`, three numeric components, no leading zeros. `## Unreleased`
    and a `## ` line inside notes are not versions.
    """
    if not line.startswith("## "):
        return None
    token = line[3:].lstrip(" ").split(" ", 1)[0].strip()
    token = token[1:] if token[:1] in "vV" else token
    numbers = token.split(".")
    if len(numbers) != 3 or any(
        not number.isascii() or not number.isdigit() or (len(number) > 1 and number.startswith("0"))
        or len(number) > 19 or int(number) > (1 << 63) - 1
        for number in numbers
    ):
        return None
    return tuple(int(number) for number in numbers)


def require_bundled_history(text):
    """Refuse a changelog `AppReleaseHistory` cannot parse.

    Every `## ` line is a release heading. One that is not `x.y.z` fails the whole
    file in the app, so publishing must fail here rather than keep or drop it.
    """
    seen = set()
    for entry in split_sections(text or "")[1]:
        heading, _, body = entry.partition("\n")
        version = bundled_heading_version(heading)
        if version is None:
            raise NotesError(
                f"Changelog heading {heading!r} is not a semantic version. "
                "The app rejects every ## line that is not x.y.z, including ## Unreleased and headings inside notes."
            )
        if version in seen:
            raise NotesError(f"Changelog repeats {'.'.join(str(part) for part in version)}.")
        seen.add(version)
        require_bilingual(body)
    return text


def write_with_model(version, previous, revision, repo=None, cwd=ROOT, transport=None, environ=None):
    """Notes the release-notes model writes from the commits in the range. A range with
    no commits is reported in both languages without a request."""
    entries = []
    for sha, subject, body in commits(previous, revision, cwd):
        change = classify(sha, subject, body)
        if change is not None:
            entries.append((sha, " ".join(subject.split()), body, change.group == "internal"))
    if not entries:
        return render_model_notes(version, empty_notes(), previous, repo)
    url, model, key = model_settings(environ)
    payload = {
        "model": model,
        "max_tokens": MAX_TOKENS,
        "stream": True,
        "system": SYSTEM_PROMPT,
        "messages": [{"role": "user", "content": model_prompt(version, previous, entries)}],
    }
    text = streamed_text((transport or stream)(url, key, payload))
    return render_model_notes(version, parse_notes(text), previous, repo)


def notes_for(version, previous, revision, repo=None, ai=False, cwd=ROOT, transport=None, environ=None):
    if ai:
        return write_with_model(version, previous, revision, repo, cwd, transport, environ)
    return render(version, changes(previous, revision, cwd), previous, repo)


def published_notes(version, previous, revision, repo, changelog_text, day, ai=False, cwd=ROOT, transport=None, environ=None):
    """Bilingual source notes and the changelog text the build must bundle.

    A recorded bilingual section is returned unchanged and the model is not called.
    A missing section is written once, with `--ai`, and inserted before the build.
    GitHub publishes its English part. English-only history and a `##` heading the
    app cannot parse are refused: neither is kept nor dropped.
    Returns `(notes, changelog_text, generated)`.
    """
    require_bundled_history(changelog_text)
    recorded = recorded_notes(changelog_text, version)
    if recorded is not None:
        require_bilingual(recorded)
        return recorded, changelog_text, False
    if not ai:
        raise NotesError(
            "Publishing needs bilingual notes. Listed notes are a developer preview; "
            "pass --ai, or record a ### English / ### 简体中文 section first."
        )
    notes = notes_for(version, previous, revision, repo, ai=True, cwd=cwd, transport=transport, environ=environ)
    require_bilingual(notes)
    updated = insert_section(changelog_text or CHANGELOG_PREAMBLE, version, section(version, day, notes))
    require_bundled_history(updated)
    stored = recorded_notes(updated, version)
    if stored is None or stored.strip() != notes.strip():
        raise NotesError("Generated notes were not stored unchanged in the changelog")
    return stored, updated, True


# --- CHANGELOG.md -------------------------------------------------------------------


def tag_date(tag, cwd=ROOT):
    """The commit date of a tag, or today when the tag does not exist yet."""
    try:
        return git("log", "-1", "--format=%cs", tag, cwd=cwd).strip() or date.today().isoformat()
    except NotesError:
        return date.today().isoformat()


def section(version, day, body):
    return f"## {display_version(version)} — {day}\n\n{body.strip()}\n\n"


def split_sections(text):
    """`(preamble, [section, ...])`; each section starts at a `## ` heading."""
    positions = [match.start() for match in re.finditer(r"^## ", text, re.MULTILINE)]
    if not positions:
        return text, []
    bounds = positions + [len(text)]
    return text[: positions[0]], [text[bounds[index] : bounds[index + 1]] for index in range(len(positions))]


def section_version(text):
    return bundled_heading_version(text.partition("\n")[0])


def recorded_notes(text, version):
    """The notes of `version`'s section in a changelog, without its heading, or None."""
    target = version_key(version)
    for item in split_sections(text or "")[1]:
        if section_version(item) == target:
            return item.split("\n", 1)[1].strip() + "\n"
    return None


def insert_section(text, version, entry):
    """`entry` replaces any section for the same version and lands in descending order."""
    preamble, sections = split_sections(text or CHANGELOG_PREAMBLE)
    target = version_key(version)
    kept = [item for item in sections if section_version(item) != target]
    index = next((position for position, item in enumerate(kept) if (section_version(item) or (0, 0, 0)) < target), len(kept))
    kept.insert(index, entry)
    return preamble.rstrip("\n") + "\n\n" + "".join(kept).rstrip("\n") + "\n"


def rebuild_changelog(repo=None, cwd=ROOT, recorded=""):
    """A whole changelog with a section for every version tag, newest first.

    A section `recorded` (the current changelog) already holds is kept word for word,
    so the model's notes survive; the others list their commits. A recorded `##`
    heading that is not `x.y.z` is refused, not dropped. It never calls the
    model: one request per tag would rewrite history nobody asked to change.
    """
    kept = {}
    for item in split_sections(recorded or "")[1]:
        heading = item.split("\n", 1)[0]
        version = bundled_heading_version(heading)
        if version is None:
            raise NotesError(
                f"Changelog heading {heading!r} is not a semantic version. "
                "The app rejects every ## line that is not x.y.z, including ## Unreleased and headings inside notes."
            )
        if version in kept:
            raise NotesError(f"Changelog repeats {'.'.join(str(part) for part in version)}.")
        kept[version] = item.rstrip("\n") + "\n\n"
    tags = version_tags(cwd)
    if not tags:
        raise NotesError("No vx.y.z tags to build a changelog from.")
    body = CHANGELOG_PREAMBLE
    for position in range(len(tags) - 1, -1, -1):
        tag = tags[position]
        earlier = tags[position - 1] if position else None
        body += kept.get(version_key(tag)) or section(tag, tag_date(tag, cwd), render(tag, changes(earlier, tag, cwd), earlier, repo))
    return body.rstrip("\n") + "\n"


def resolve(args):
    """Version, range and repository for this invocation."""
    version = display_version(args.tag or current_version())
    revision = args.to or f"v{version}"
    repo = args.repository or repository()
    if args.previous is not None:
        earlier = args.previous or None
    else:
        earlier = previous_tag(version, revision)
    return version, revision, earlier, repo


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--tag", help="Version being released; defaults to MARKETING_VERSION in project.yml.")
    parser.add_argument("--to", help="Revision the range ends at; defaults to the version's tag.")
    parser.add_argument("--previous", help="Tag the range starts after; empty string means the whole history.")
    parser.add_argument("--repository", help="owner/repo for commit and compare links; defaults to the origin remote.")
    parser.add_argument("--ai", action="store_true",
                        help=f"Have the release-notes model write English and Simplified Chinese (needs {API_KEY_VARIABLE}). Without it, commits are listed in English and are not published.")
    parser.add_argument("--release-body", action="store_true",
                        help="The release page: only the English notes and compare link from the bilingual CHANGELOG.md section (generated once when missing), plus the install footer.")
    parser.add_argument("--built-from", help="Revision the disk image was built from; recorded in the footer.")
    parser.add_argument("--output", help="Write the notes here instead of stdout.")
    parser.add_argument("--changelog", action="store_true", help="Write this version's bilingual section into CHANGELOG.md.")
    parser.add_argument("--rebuild-changelog", action="store_true", help="Rewrite every section of CHANGELOG.md from the version tags, keeping recorded sections.")
    parser.add_argument("--apply", action="store_true", help="Write CHANGELOG.md; without it the planned change is only described.")
    args = parser.parse_args(argv)

    if args.rebuild_changelog:
        if args.ai:
            raise NotesError("--rebuild-changelog never calls the model: it keeps recorded sections and lists the commits of the rest")
        if not args.apply:
            print(f"{MARK.step} Would rewrite {CHANGELOG.relative_to(ROOT)} from {len(version_tags())} tags; --apply writes it")
            return 0
        recorded = CHANGELOG.read_text(encoding="utf-8") if CHANGELOG.exists() else ""
        rebuilt = rebuild_changelog(args.repository or repository(), recorded=recorded)
        require_bundled_history(rebuilt)
        CHANGELOG.write_text(rebuilt, encoding="utf-8")
        print(f"{MARK.ok} Rewrote {CHANGELOG.relative_to(ROOT)} from {len(version_tags())} tags, keeping recorded sections")
        return 0

    version, revision, earlier, repo = resolve(args)
    day = tag_date(f"v{version}") if args.to is None else date.today().isoformat()
    if args.changelog and not (args.apply or args.output):
        print(f"{MARK.step} Would write {CHANGELOG.relative_to(ROOT)}: {version} — {day}; --apply writes it")
        return 0

    existing = CHANGELOG.read_text(encoding="utf-8") if CHANGELOG.exists() else CHANGELOG_PREAMBLE
    generated = False
    recorded = None
    if args.release_body:
        notes, updated, generated = published_notes(
            version, earlier, revision, repo, existing, day, ai=args.ai)
        if generated:
            CHANGELOG.write_text(updated, encoding="utf-8")
            print(f"{MARK.ok} Wrote bilingual notes for {version} into {CHANGELOG.relative_to(ROOT)} before publish", file=sys.stderr)
        recorded = notes
        body = release_body(notes, version, args.built_from)
    else:
        if args.changelog:
            require_bundled_history(existing)
        notes = notes_for(version, earlier, revision, repo, ai=args.ai)
        body = notes
        updated = insert_section(existing, version, section(version, day, notes))

    if args.changelog and not args.release_body:
        require_bilingual(notes)
        require_bundled_history(updated)
        if args.apply:
            CHANGELOG.write_text(updated, encoding="utf-8")
            print(f"{MARK.ok} {CHANGELOG.relative_to(ROOT)}: {version} — {day}")
        else:
            print(f"{MARK.step} Would write {CHANGELOG.relative_to(ROOT)}: {version} — {day}; --apply writes it")

    if args.output:
        destination = Path(args.output)
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(body, encoding="utf-8")
        source = "its CHANGELOG.md section" if recorded is not None and not generated else f"{earlier or 'first release'}..{revision}"
        if generated:
            writer = ", written once into CHANGELOG.md"
        elif recorded is not None:
            writer = ", reused from CHANGELOG.md"
        else:
            writer = ", written by the release-notes model" if args.ai else ""
        print(f"{MARK.ok} Notes for {version} ({source}{writer}): {destination}")
    elif not args.changelog:
        sys.stdout.write(body)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except NotesError as error:
        print(f"{markers().missing} {error}", file=sys.stderr)
        raise SystemExit(1)
