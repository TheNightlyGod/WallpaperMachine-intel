#!/usr/bin/env python3
"""Release notes and CHANGELOG.md sections for the commits between two version tags.

Two writers read the same input, the commits in the range:

* `--ai` hands them to a language model (Claude Opus behind an Anthropic Messages API
  gateway; the key comes from RELEASE_NOTES_API_KEY) that writes the same notes in
  English, Simplified Chinese and Korean, merging related commits and leaving internal
  work out. Releases always use it. A reply missing any language is refused.
* Without it the commits are listed in English, grouped by the `type(scope): subject`
  convention the repository follows. That listing is a developer preview: it is not
  published. Documentation, test and tooling commits are counted rather than listed,
  and an unrecognised commit lands under "Other Changes", so none disappears silently.

The layout is conventional-changelog's: `## [x.y.z](<compare link>) (YYYY-MM-DD)`, then
`### English` / `### 简体中文` / `### 한국어` blocks with `####` categories (Features,
Bug Fixes, ...). Every bullet ends with the issues its commits close and links to those
commits, ` (closes [#N](...)) ([abc1234](...))`; the model names the commits, the
script writes the links.

A version's notes are written once, into its CHANGELOG.md section, when the version
is cut. Sections carry all three languages from v1.5.7; older recorded English and
Simplified Chinese sections remain valid. The update manifest carries the newest
sections, which the app's update window shows (scripts/update_manifest.py
--changelog). `--release-body` publishes only the English part and the compare link
on GitHub, then adds the install footer. Each language block of a new section ends by
thanking the outside contributors whose commits are in the range, by GitHub login;
the script writes that line, not the model. A hand-pushed tag with no section is written
once, into the working tree, before the build. A recorded localized section is reused
without another model request.
A version with a banner picture in Resources/ReleaseBanners/ (`x.y.z.jpg` or `.png`,
and optionally Chinese `x.y.z.zh-Hans` and Korean `x.y.z.ko` pictures) gets an image
line at the top of each language block; languages without a picture share English's.
A version with a developer's note in Resources/ReleaseNotes/ (`x.y.z.md`, `x.y.z.zh-Hans.md`
and `x.y.z.ko.md`, all three or none) gets it under its own heading after the summary,
word for word: the model never sees or rewrites it.
A `##` heading that is not a version — `## Unreleased`, a prerelease token, or a
heading inside the notes — stops publishing. The app rejects that whole changelog,
so the heading is not kept and not dropped.

    python3 scripts/release_notes.py                              # English listing, not for publish
    python3 scripts/release_notes.py --ai --tag v0.6.0 --to HEAD  # trilingual notes, before the tag exists
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
# A version's banner picture, committed before the version is cut; GitHub shows it in
# CHANGELOG.md and on the release page.
BANNERS = Path("Resources") / "ReleaseBanners"
BANNER_TYPES = (".png", ".jpg")
# The file name each language block's banner takes after `x.y.z`; translations fall back to English's.
BANNER_SUFFIXES = {"english": "", "chinese": ".zh-Hans", "korean": ".ko"}
BANNER = re.compile(r"^!\[(?P<alt>[^\]\n]*)\]\((?P<path>Resources/ReleaseBanners/(?P<name>[^/)\s]+))\)[ \t]*$", re.MULTILINE)
# A version's note from the developer, committed before the version is cut in every language,
# with the same file-name suffixes as the banners. It is printed as written, never by the model.
DEVELOPER_NOTES = Path("Resources") / "ReleaseNotes"
DEVELOPER_NOTE_HEADINGS = {"english": "A note from the developer", "chinese": "开发者的话", "korean": "개발자의 말"}
APPLICATION = "WallpaperMachine"

# `type(scope)!: subject`, the convention docs/conventions.md describes.
CONVENTIONAL = re.compile(r"^(?P<type>[a-z]+)(?:\((?P<scope>[^)]*)\))?(?P<breaking>!)?:[ \t]*(?P<subject>.+)$")
VERSION_TAG = re.compile(r"^v?(\d+)\.(\d+)\.(\d+)$")
# The Version workflow's own commit; it describes the release, it is not part of it.
BUMP_COMMIT = re.compile(r"^chore: bump version to \d+\.\d+\.\d+$")
BREAKING_BODY = re.compile(r"^BREAKING[ -]CHANGE:", re.MULTILINE)
MARKETING_VERSION = re.compile(r'MARKETING_VERSION:\s*"([^"]+)"')
# GitHub's closing keywords followed by a same-repository issue: `Fixes #12`, `closes: #3`.
CLOSING_REF = re.compile(r"\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?):?[ \t]+#(\d+)\b", re.IGNORECASE)
# `## [x.y.z](<compare link>) (YYYY-MM-DD)`; the older `## x.y.z — YYYY-MM-DD` is still read.
LINKED_HEADING = re.compile(r"^\[(?P<token>[^\]\n]*)\]\((?P<url>[^)\s]+)\)(?: \((?P<date>\d{4}-\d{2}-\d{2})\))?[ \t]*$")
# Where version headings link when no repository is known (no GitHub origin remote).
DEFAULT_REPOSITORY = "WallpaperMachine/WallpaperMachine"
REMOTE_SLUG = re.compile(r"(?:https://github\.com/|git@github\.com:)(?P<slug>[^/]+/[^/\s]+?)(?:\.git)?/?$")
DEPLOYMENT_TARGET = re.compile(r"MACOSX_DEPLOYMENT_TARGET:\s*\"?([\d.]+)")

# One bullet, one line: past this a subject is cut at a word boundary and the linked
# commit carries the rest.
SUBJECT_LIMIT = 140
# A commit's link text, conventional-changelog's short hash.
SHORT_HASH = 7

# Boundary between the notes the in-app updater shows and the download instructions
# that belong only to the release page. App/Services/GitHub reads the same marker.
NOTES_END = "<!-- release-notes-end -->"

FIELD = "\x1f"
RECORD = "\x1e"

# Where a commit type is reported. A type that is absent is user-visible by
# default: an unrecognised commit is listed under "Other Changes", never hidden.
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
# Listed commit groups -> the category they share with the model's notes.
SECTIONS = (
    ("breaking", "breaking"),
    ("features", "new"),
    ("fixes", "fixed"),
    ("performance", "performance"),
    ("other", "other"),
)

CHANGELOG_PREAMBLE = """\
# Changelog

Every published version, newest first. Each section is written when its version is
cut, by [`scripts/release_notes.py`](scripts/release_notes.py) from the commits
between two version tags: a language model writes them up for users, where older
sections list the commits. A section's heading links the version to its comparison
with the previous one and gives the release date. Under it, the same notes in English,
Simplified Chinese and Korean (from 1.5.7; earlier sections keep their original
translations) are grouped into Features, Bug Fixes and the other categories, and
newer bullets end with the issues they close and the commits they describe. The
app's update window shows the sections of every version newer than the installed
one, in the app's language; the GitHub Release body repeats only the English notes.
See [docs/release.md](docs/release.md) for how a version is cut.

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
# Who a release thanks: the GitHub accounts behind the commits of the range, from a
# `<id>+login@users.noreply.github.com` address or, with RELEASE_NOTES_GITHUB_TOKEN set,
# GitHub's own record of each commit's author. Maintainers, the coding agents that
# commit for them and bots are not thanked; an address GitHub links to no account is
# not credited, so a maintainer's new address can never be thanked by name.
GITHUB_TOKEN_VARIABLE = "RELEASE_NOTES_GITHUB_TOKEN"
GITHUB_API = "https://api.github.com"
GITHUB_TIMEOUT = 20
MAINTAINERS = frozenset({"bobbyhuang-dev", "fzlzjerry", "t3code"})
NOREPLY = re.compile(r"^(?:\d+\+)?(?P<login>[^@\s]+)@users\.noreply\.github\.com$", re.IGNORECASE)
LOGIN = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})$")
CO_AUTHOR = re.compile(r"^co-authored-by:[ \t]*[^<\n]*<(?P<email>[^>\n]+)>[ \t]*$", re.IGNORECASE | re.MULTILINE)
MODEL_SECTIONS = (
    ("highlights", "Highlights"),
    ("breaking", "Breaking Changes"),
    ("new", "Features"),
    ("improved", "Improvements"),
    ("fixed", "Bug Fixes"),
)
# Category headings inside a language block, conventional-changelog's names. The
# model writes the first five; performance and other appear only in commit listings
# and older sections.
LANGUAGE_HEADINGS = {
    "english": {**dict(MODEL_SECTIONS), "performance": "Performance Improvements", "other": "Other Changes"},
    "chinese": {
        "highlights": "亮点",
        "breaking": "不兼容变更",
        "new": "新功能",
        "improved": "改进",
        "fixed": "问题修复",
        "performance": "性能改进",
        "other": "其他变更",
    },
    "korean": {
        "highlights": "주요 변경 사항",
        "breaking": "호환되지 않는 변경 사항",
        "new": "새로운 기능",
        "improved": "개선 사항",
        "fixed": "버그 수정",
        "performance": "성능 개선",
        "other": "기타 변경 사항",
    },
}
LANGUAGE_BLOCKS = (("english", "English"), ("chinese", "简体中文"), ("korean", "한국어"))
# Shared version boundary with the app's release-history validation.
KOREAN_NOTES_VERSION = (1, 5, 7)
CJK = re.compile(r"[\u4e00-\u9fff]")
HANGUL = re.compile(r"[\u1100-\u11ff\u3130-\u318f\uac00-\ud7af]")
LATIN = re.compile(r"[A-Za-z]")
SYSTEM_PROMPT = """\
You are the release editor for WallpaperMachine, a native macOS app for Apple silicon \
that plays Wallpaper Engine scene, video and web wallpapers on the desktop and, \
experimentally, the lock screen. Its control panel manages the wallpaper library, \
browses and downloads Steam Workshop items and holds the settings. The panel ships \
in English, Simplified Chinese (简体中文) and Korean (한국어).

You turn the commits of one release into the notes users read on the GitHub release \
page, in CHANGELOG.md and in the app's update window. Write each note three times: \
once in English, once in Simplified Chinese, once in Korean. All three say the same thing.

Rules:
- Write for people who use the app, not for its developers: what they can do now, \
what works better, what no longer goes wrong. No code identifiers, file or class \
names, commit hashes, test names or internal jargon. Lead with the benefit and name \
the thing the user sees (a wallpaper, a window, a setting), in the active voice: \
"Text layers now show their outline and shadow", not "Implemented text outline \
rendering". Do not open several bullets in a row with the same words.
- Report only what the commits support. Never invent features, numbers, platforms or \
dates. Leave a change out when you cannot tell whether users would notice it.
- Leave out purely internal work: documentation, tests, CI, refactoring, build \
tooling and verification records.
- One bullet per user-visible change, in all three languages. Merge commits that describe \
the same change. When many commits fix or extend one area (for example text layers, \
particles or lighting in scenes), write one bullet for the area that names what users \
will see, not one per commit; keep each section to about 15 bullets, so a long \
release reads in a few minutes. The chinese and korean strings \
of a bullet are the english string's equivalents, not summaries of different changes \
and not copies of the English or of each other.
- Each string is one plain sentence, at most 30 words, with no trailing period and no \
Markdown, links or emoji. chinese is Simplified Chinese, not Traditional, not a \
romanization, and not English with a character added; write it the way a Chinese \
Mac app would, not word for word. korean is natural Korean in Hangul, not Chinese, \
romanization or English with a Hangul character added. Order each list by how much \
it matters to users. Keep product names (WallpaperMachine, Wallpaper \
Engine, Steam, Workshop, pixiv, macOS) as they are.
- Name places in the app the way the panel does (English / Chinese / Korean): \
Settings / 设置 / 설정, General / 通用 / 일반, Appearance / 外观 / 화면 모드, \
Performance / 性能 / 성능, Playback / 播放 / 재생, Library & Steam / 壁纸库与 Steam / 보관함 및 Steam, \
Library / 壁纸库 / 보관함, Steam Workshop / Steam 创意工坊 / Steam 창작마당, \
Collections / 合集 / 컬렉션, Now Playing / 正在播放 / 지금 재생 중, \
Downloads / 下载 / 다운로드, About / 关于 / 정보, Lock screen / 锁定屏幕 / 잠금 화면.
- highlights: only when the user turn says this is a feature release, the three to \
five changes that define it, most important first, each one sentence a user would \
repeat to a friend. A highlight may sum up several bullets of the other sections, \
which still list those changes. Otherwise an empty list.
- breaking: changes that make users act or take away behaviour they relied on. new: \
things users can do that they could not before. improved: faster, smoother or \
clearer behaviour, performance included. fixed: problems that no longer happen, \
described by what the user saw. A section is the same length in all three languages.
- summary: one or two sentences on what the release means for users, its theme \
first, in all three languages, or empty strings in all three when the lists say it all. Never \
fill only some languages. Do not list the changes again.
- Claims: never claim energy, battery or power savings, even when a commit measured \
less work. Never call anything fully supported or fully compatible. Keep \
"optional", "experimental" or "off by default" on opt-in features such as content \
pacing, on-demand scene idle and drawing only the visible part of cropped scenes, \
and on the animated lock screen. Native Metal is \
the only scene renderer, not an option, and the app's own video players are the \
only way a video wallpaper plays (a format they cannot play is refused with its \
format named), not an option either. Every language keeps \
the same qualifier: optional / 可选 / 선택 사항, experimental / 实验性 / 실험적, \
off by default / 默认关闭 / 기본적으로 꺼짐.
- commits: every bullet names the commits it describes, by the short hash each commit \
line of the user turn starts with, at least one. A bullet that merges several commits \
names all of them. Name only commits of this release. The summary names none.

Reply with only a JSON object, no prose and no code fence, with exactly these keys:
{"summary": {"english": string, "chinese": string, "korean": string}, "highlights": [BULLET], "breaking": [BULLET], "new": [BULLET], "improved": [BULLET], "fixed": [BULLET]}
where each BULLET is {"english": string, "chinese": string, "korean": string, "commits": [string]}.
Use an empty list for a section with nothing in it. Do not write headings, links, \
issue numbers or hashes into the text; the script adds them from commits."""


class NotesError(Exception):
    """A condition that stops note generation; the message is the whole report."""


class Change(NamedTuple):
    """One commit, already classified for the section it belongs to.

    `sha` is the full hash when it comes from git; `closes` holds the issue numbers the
    commit message closes.
    """

    group: str
    scope: str
    subject: str
    sha: str
    closes: tuple = ()


class Commit(NamedTuple):
    """One commit of the range: full and abbreviated hash, subject, body and author address."""

    sha: str
    short: str
    subject: str
    body: str
    email: str = ""


class Bullet(NamedTuple):
    """One model-written change: its text per language and the commits it describes."""

    texts: dict
    commits: tuple


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
    """A `Commit` for every non-merge commit in the range, newest first."""
    span = f"{previous}..{revision}" if previous else revision
    raw = git("log", "--no-merges", f"--format=%H{FIELD}%h{FIELD}%ae{FIELD}%s{FIELD}%b{RECORD}", span, cwd=cwd)
    for record in raw.split(RECORD):
        record = record.strip("\n")
        if not record:
            continue
        sha, short, email, subject, body = record.split(FIELD, 4)
        yield Commit(sha, short, subject, body, email)


def closing_refs(message):
    """Issue numbers a commit message closes with GitHub's keywords, ascending."""
    return tuple(sorted({int(number) for number in CLOSING_REF.findall(message or "")}))


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
    closes = closing_refs(f"{subject}\n{body or ''}")
    match = CONVENTIONAL.match(subject.strip())
    if not match:
        return Change("other", "", sentence(subject), sha, closes)
    breaking = bool(match.group("breaking")) or bool(BREAKING_BODY.search(body or ""))
    group = "breaking" if breaking else GROUPS.get(match.group("type"), "other")
    return Change(group, (match.group("scope") or "").strip(), sentence(match.group("subject")), sha, closes)


def release_commits(previous, revision, cwd=ROOT):
    """`(Commit, Change)` for every commit of the range but CI's bump commit, newest first."""
    for entry in commits(previous, revision, cwd):
        change = classify(entry.sha, entry.subject, entry.body)
        if change is not None:
            yield entry, change


def changes(previous, revision, cwd=ROOT):
    return [change for _, change in release_commits(previous, revision, cwd)]


def group_changes(collected):
    """Section key -> its bullets, newest first, each a list of the changes it stands for.

    Repeated wording collapses into one bullet that links every commit behind it.
    """
    grouped = {}
    bullets = {}
    for change in collected:
        key = (change.group, change.scope, change.subject.lower())
        if key in bullets:
            bullets[key].append(change)
            continue
        bullets[key] = [change]
        grouped.setdefault(change.group, []).append(bullets[key])
    return grouped


def issue_link(number, repo=None):
    return f"[#{number}](https://github.com/{repo}/issues/{number})" if repo else f"#{number}"


def commit_link(sha, repo=None):
    short = sha[:SHORT_HASH]
    return f"[{short}](https://github.com/{repo}/commit/{sha})" if repo else short


def link_suffix(shas, closes, repo=None):
    """What every bullet ends with, in every language: ` (closes [#N](…)) ([abc1234](…))`.

    The issues part appears only when one of the commits closes an issue.
    """
    suffix = ""
    issues = sorted(set(closes))
    if issues:
        suffix += " (" + ", ".join(f"closes {issue_link(number, repo)}" for number in issues) + ")"
    shas = list(dict.fromkeys(shas))
    if shas:
        suffix += " (" + ", ".join(commit_link(sha, repo) for sha in shas) + ")"
    return suffix


def bullet(changes_behind, repo=None):
    """One listed bullet for the changes that share its wording; a single Change works too."""
    if isinstance(changes_behind, Change):
        changes_behind = [changes_behind]
    first = changes_behind[0]
    scope = f"**{first.scope}** — " if first.scope else ""
    closes = [number for change in changes_behind for number in change.closes]
    return f"- {scope}{first.subject}{link_suffix([change.sha for change in changes_behind], closes, repo)}"


def github_author(repo, sha, token):
    """`(login, type)` GitHub records as the author of `sha`, or None when the address
    links no account or GitHub does not know the commit (one not pushed yet)."""
    request = urllib.request.Request(f"{GITHUB_API}/repos/{repo}/commits/{sha}", headers={
        "accept": "application/vnd.github+json",
        "authorization": f"Bearer {token}",
        "user-agent": USER_AGENT,
        "x-github-api-version": "2022-11-28",
    })
    try:
        with urllib.request.urlopen(request, timeout=GITHUB_TIMEOUT) as response:
            author = json.load(response).get("author") or {}
    except urllib.error.HTTPError as error:
        error.close()
        if error.code in (404, 422):
            return None
        raise NotesError(f"GitHub refused to name the author of {sha[:SHORT_HASH]} (HTTP {error.code})") from None
    except (urllib.error.URLError, OSError, ValueError) as error:
        raise NotesError(f"Could not ask GitHub who wrote {sha[:SHORT_HASH]}: {getattr(error, 'reason', error)}") from None
    return (author["login"], author.get("type")) if author.get("login") else None


def outside_contributors(entries, repo=None, environ=None, lookup=None):
    """The GitHub logins a release thanks, in the order of their first commit (oldest first).

    A commit's author counts by the login in a GitHub noreply address, else by what
    `lookup(sha)` answers (GitHub's record, asked once per address, when
    RELEASE_NOTES_GITHUB_TOKEN is set); a co-author only by a noreply address. Maintainers
    and bots are left out, and so is anyone without a login.
    """
    environ = os.environ if environ is None else environ
    token = environ.get(GITHUB_TOKEN_VARIABLE, "").strip()
    if lookup is None and token and repo:
        lookup = lambda sha: github_author(repo, sha, token)  # noqa: E731
    logins = {}
    thanked = {}

    def credit(login):
        if login and LOGIN.match(login) and login.lower() not in MAINTAINERS:
            thanked.setdefault(login.lower(), login)

    for entry in reversed(list(entries)):
        address = entry.email.strip()
        if address.lower() not in logins:
            noreply = NOREPLY.match(address)
            author = None if noreply or not (lookup and address) else lookup(entry.sha)
            if noreply:
                logins[address.lower()] = noreply.group("login")
            else:
                logins[address.lower()] = author[0] if author and author[1] != "Bot" else None
        credit(logins[address.lower()])
        for match in CO_AUTHOR.finditer(entry.body or ""):
            noreply = NOREPLY.match(match.group("email").strip())
            credit(noreply and noreply.group("login"))
    return tuple(thanked.values())


def thanks_line(code, logins):
    """The sentence a language block ends with when outside contributors are in the range."""
    if not logins:
        return None
    names = [f"[@{login}](https://github.com/{login})" for login in logins]
    if code == "english":
        listed = names[0] if len(names) == 1 else ", ".join(names[:-1]) + " and " + names[-1]
        return f"Thanks to {listed} for contributing to this release."
    if code == "chinese":
        listed = names[0] if len(names) == 1 else "、".join(names[:-1]) + " 和 " + names[-1]
        return f"感谢 {listed} 为本版本做出的贡献。"
    return f"이번 릴리스에 기여해 주신 {', '.join(names)} 님께 감사드립니다."


def compare_url(previous, tag, repo):
    """The comparison with the previous version, or the commit list of a first release."""
    if not repo:
        return None
    if previous:
        return f"https://github.com/{repo}/compare/{previous}...{tag}"
    return f"https://github.com/{repo}/commits/{tag}"


def banner_path(version, root=ROOT, code="english"):
    """A language's banner picture relative to `root`, as a POSIX path, or None.

    A language without its own picture shares the English one.
    """
    for suffix in dict.fromkeys((BANNER_SUFFIXES[code], "")):
        for kind in BANNER_TYPES:
            candidate = BANNERS / f"{display_version(version)}{suffix}{kind}"
            if (Path(root) / candidate).is_file():
                return candidate.as_posix()
    return None


def banner_line(version, root=ROOT, code="english"):
    """The image line a language block opens with when the version has a banner, or None."""
    path = banner_path(version, root, code)
    return f"![{APPLICATION} {display_version(version)}]({path})" if path else None


def banner_names(version):
    """Every banner file name a section of `version` may point at."""
    number = display_version(version)
    return {(BANNERS / f"{number}{suffix}{kind}").as_posix()
            for suffix in BANNER_SUFFIXES.values() for kind in BANNER_TYPES}


def developer_notes(version, root=ROOT):
    """The version's note from the developer in every language, one paragraph per line, or None.

    The note is all three files or none: a language without its own would read another's.
    It is prose, so it may not open a heading, a list, a picture or the boundary marker,
    any of which would change how the section is read.
    """
    number = display_version(version)
    paths = {code: Path(root) / DEVELOPER_NOTES / f"{number}{BANNER_SUFFIXES[code]}.md" for code, _ in LANGUAGE_BLOCKS}
    present = {code for code, path in paths.items() if path.is_file()}
    if not present:
        return None
    if len(present) != len(paths):
        missing = ", ".join(paths[code].relative_to(root).as_posix() for code in paths if code not in present)
        raise NotesError(f"The developer's note of {number} is missing {missing}")
    notes = {}
    for code, path in paths.items():
        paragraphs = [" ".join(chunk.split()) for chunk in re.split(r"\n[ \t]*\n", path.read_text(encoding="utf-8"))]
        paragraphs = [paragraph for paragraph in paragraphs if paragraph]
        for paragraph in paragraphs:
            if paragraph.startswith(("#", "- ", "* ", "![", "**Full changelog**")) or "<!--" in paragraph:
                raise NotesError(f"The developer's note {path.relative_to(root).as_posix()} must be plain "
                                 f"paragraphs, not {paragraph[:40]!r}")
        notes[code] = "\n\n".join(paragraphs)
    require_translations(notes, f"developer's note of {number}")
    return notes


def nothing_to_say(previous):
    span = f"since `{previous}`" if previous else "in this history"
    return f"No user-visible changes {span}."


def nothing_to_say_zh(previous):
    if previous:
        return f"自 `{previous}` 以来没有用户能察觉的变化。"
    return "这段历史里没有用户能察觉的变化。"


def nothing_to_say_ko(previous):
    if previous:
        return f"`{previous}` 이후 사용자에게 표시되는 변경 사항이 없습니다."
    return "이 기록에는 사용자에게 표시되는 변경 사항이 없습니다."


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
        "3. Open it. The app is signed with the project's Developer ID and notarized by Apple, so it",
        "   opens on its first launch without a trip to System Settings.",
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


def release_body(notes, version, built_from=None, repo=None, compare=None):
    """What GitHub shows: the banner, English notes, the compare link, then the install footer.

    `compare` is the comparison the version's changelog heading links; notes recorded
    in the older layout carry it as a `**Full changelog**` line instead.
    The banner is read from the version's tag, because the page is not served from the
    repository; without a repository there is no address for it, and it is left out.
    """
    validated = require_localized_notes(notes, version).split(NOTES_END, 1)[0]
    english = language_blocks(validated)["english"]

    def published(match):
        if not repo:
            return ""
        address = f"https://raw.githubusercontent.com/{repo}/v{display_version(version)}/{match.group('path')}"
        return f"![{match.group('alt')}]({address})"

    english = BANNER.sub(published, english)
    parts = [f"### English\n\n{english.strip()}"]
    if compare:
        parts.append(f"**Full changelog**: {compare}")
    else:
        parts.extend(line for line in validated.splitlines()
                     if line.startswith("**Full changelog**:") and line not in english.splitlines())
    parts.append(install_footer(version, deployment_target(), built_from))
    return "\n\n".join(parts) + "\n"


def render(version, collected, previous=None, repo=None, internal_label=True, thanks=()):
    """The listed notes for one version: an English block of `####` categories, an
    internal-work count and the thanks line. The section heading carries the compare link."""
    grouped = group_changes(collected)
    parts = []
    for key, category in SECTIONS:
        entries = grouped.get(key)
        if not entries:
            continue
        heading = LANGUAGE_HEADINGS["english"][category]
        parts.append(f"#### {heading}\n\n" + "\n".join(bullet(entry, repo) for entry in entries))
    internal = len(grouped.get("internal", ()))
    if not parts:
        parts.append(nothing_to_say(previous))
    elif internal and internal_label:
        noun = "commit" if internal == 1 else "commits"
        parts.append(f"Plus {internal} documentation, test and tooling {noun}.")
    if thanks:
        parts.append(thanks_line("english", thanks))
    return "### English\n\n" + "\n\n".join(parts).strip() + "\n"


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


def is_feature_release(version, previous=None):
    """The first release of a minor or major version, the ones that get highlights.

    That is `x.y.0`, or a later patch whose notes start below `x.y`: one that replaces an
    `x.y.0` that was tagged but never published, so nobody saw that version's highlights.
    """
    major, minor, patch = version_key(version)
    if patch == 0:
        return True
    return previous is not None and version_key(previous)[:2] < (major, minor)


def model_prompt(version, previous, entries):
    """The user turn: the release, then its commits newest first.

    `entries` holds `(short hash, subject, body, internal)`; the model cites the hash.
    Internal commits bring only their
    subject, which is enough to leave them out; the others bring their body too, cut
    at BODY_LIMIT, until BODIES_BUDGET characters of bodies are spent. A squash merge
    brings every commit it lists the same way, so a long one loses none of them.
    """
    since = f"since {previous}" if previous else "from the start of the history"
    noun = "commit" if len(entries) == 1 else "commits"
    lines = [f"WallpaperMachine {display_version(version)}: {len(entries)} {noun} {since}, newest first."]
    if is_feature_release(version, previous):
        lines.append("This is a feature release: write its highlights.")
    else:
        lines.append("This is a patch release: leave highlights empty.")
    lines.append("")
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


def require_translations(texts, label):
    """Every expected language is present and uses its script, without copied translations."""
    if not all(texts.values()):
        raise NotesError(f"Release notes {label} are missing a language")
    scripts = {"english": LATIN, "chinese": CJK, "korean": HANGUL}
    for code, text in texts.items():
        if not scripts[code].search(text):
            raise NotesError(f"Release notes {label} are not {code}: {text[:80]!r}")
    if len(set(texts.values())) != len(texts):
        raise NotesError(f"Release notes {label} repeat a language as another translation")


def parse_translations(value, label, extra=()):
    """A language-keyed string object, or None when all three translations are empty.

    `extra` names the other keys the object must carry; they are not read here.
    """
    codes = {code for code, _ in LANGUAGE_BLOCKS}
    if not isinstance(value, dict) or set(value) != codes | set(extra):
        fields = "english, chinese and korean text" + "".join(f" and {name}" for name in extra)
        raise NotesError(f"The release-notes model's {label} must be {fields}")
    texts = {code: language_text(value[code], f"{label}.{code}").rstrip(".。") for code, _ in LANGUAGE_BLOCKS}
    if not any(texts.values()):
        return None
    require_translations(texts, label)
    return texts


def cited_commits(value, available, label):
    """The commits a bullet names, resolved against the range, in the order given.

    Each entry is a hash prefix of a commit in `available`; an empty or non-list value,
    a hash that matches no commit or more than one stops the run.
    """
    if not isinstance(value, list) or not value:
        raise NotesError(f"The release-notes model's {label}.commits must list the commits the bullet describes")
    resolved = []
    for cited in value:
        prefix = cited.strip().lower() if isinstance(cited, str) else ""
        if not re.fullmatch(r"[0-9a-f]{4,40}", prefix):
            raise NotesError(f"The release-notes model's {label}.commits holds {cited!r}, not a commit hash")
        matches = [entry for entry in available if entry.sha.lower().startswith(prefix)]
        if len(matches) != 1:
            problem = "matches no commit of this release" if not matches else "names more than one commit"
            raise NotesError(f"The release-notes model's {label}.commits: {cited!r} {problem}")
        if matches[0] not in resolved:
            resolved.append(matches[0])
    return tuple(resolved)


def parse_notes(text, available=()):
    """The model's JSON reply as language-keyed summary and section bullets, checked.

    Missing sections are empty. Summary and every bullet require English, Simplified
    Chinese and Korean strings; a missing language or incorrect script stops the run.
    Every bullet names the commits of `available` it describes.
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
    parsed = parse_translations(data.get("summary"), "summary")
    notes = {"summary": parsed or {code: "" for code, _ in LANGUAGE_BLOCKS}}
    for key, _ in MODEL_SECTIONS:
        items = data.get(key) or []
        if not isinstance(items, list):
            raise NotesError(f"The release-notes model's {key!r} is not a list of translated bullets")
        bullets = []
        for index, item in enumerate(items):
            label = f"{key}[{index}]"
            translations = parse_translations(item, label, extra=("commits",))
            cited = cited_commits(item["commits"], available, label)
            if translations:
                bullets.append(Bullet(translations, cited))
        notes[key] = bullets
    return notes


def empty_notes():
    return {"summary": {code: "" for code, _ in LANGUAGE_BLOCKS}, **{key: [] for key, _ in MODEL_SECTIONS}}


def bullet_suffix(item, repo=None):
    """The issue and commit links a model-written bullet ends with."""
    closes = [number for entry in item.commits for number in closing_refs(f"{entry.subject}\n{entry.body}")]
    return link_suffix([entry.sha for entry in item.commits], closes, repo)


def render_language(code, heading, notes, previous, banner=None, repo=None, thanks=(), note=None):
    """One language block: its banner, optional summary and developer's note, then `####`
    categories, or the empty line; then the thanks line when outside contributors are in the range."""
    parts = [banner] if banner else []
    if notes["summary"][code]:
        parts.append(notes["summary"][code])
    if note:
        parts.append(f"#### {DEVELOPER_NOTE_HEADINGS[code]}\n\n{note}")
    changes = len(parts)
    for key, _ in MODEL_SECTIONS:
        items = [f"{item.texts[code]}{bullet_suffix(item, repo)}" for item in notes[key] if item.texts[code]]
        if items:
            parts.append(f"#### {LANGUAGE_HEADINGS[code][key]}\n\n" + "\n".join(f"- {item}" for item in items))
    if len(parts) == changes and not notes["summary"][code]:
        no_changes = {"english": nothing_to_say, "chinese": nothing_to_say_zh, "korean": nothing_to_say_ko}
        parts.append(no_changes[code](previous))
    if thanks:
        parts.append(thanks_line(code, thanks))
    return f"### {heading}\n\n" + "\n\n".join(parts)


def render_model_notes(version, notes, previous=None, repo=None, banners=None, thanks=(), developer=None):
    """Trilingual notes: English, 简体中文, then 한국어; categories at `####`.

    `banners` maps a language to the image line its block opens with, and `developer`
    to its developer's note. Every bullet ends with the same issue and commit links in
    all three languages; the compare link belongs to the section heading. `thanks`
    holds the logins every block thanks.
    """
    banners = banners or {}
    developer = developer or {}
    parts = [render_language(code, heading, notes, previous, banners.get(code), repo, thanks, developer.get(code))
             for code, heading in LANGUAGE_BLOCKS]
    return "\n\n".join(parts).strip() + "\n"


def language_blocks(text):
    """Language-keyed spans in English / 简体中文 [/ 한국어] order, or None.

    A trailing compare link (older sections) stays in the final span; prose consumers ignore it.
    Duplicate, unknown or misordered `###` headings are never accepted.
    """
    body = text.split(NOTES_END, 1)[0]
    headings = list(re.finditer(r"^###[ \t]+(.+?)[ \t]*$", body, re.MULTILINE))
    # The app rejects every malformed three-hash line too, not just known headings.
    if len(headings) != len(re.findall(r"^###(?!#).*?$", body, re.MULTILINE)):
        return None
    names = [match.group(1) for match in headings]
    expected = [heading for _, heading in LANGUAGE_BLOCKS]
    if names not in (expected[:2], expected):
        return None
    ends = [match.start() for match in headings[1:]] + [len(body)]
    return {code: body[match.end():end] for (code, _), match, end in zip(LANGUAGE_BLOCKS, headings, ends)}


def require_localized_notes(text, version):
    """Bundled notes: ordered language blocks with prose and matching bullet counts.

    Korean is required from KOREAN_NOTES_VERSION. Legacy bilingual sections stay
    valid unchanged; a legacy section may also include Korean. Categories use `####`.
    """
    body = text.split(NOTES_END, 1)[0]
    blocks = language_blocks(body)
    if blocks is None:
        raise NotesError(
            "Release notes must be ### English then ### 简体中文 then ### 한국어, "
            "with category headings at #### (legacy sections may omit Korean). "
            "Listed English notes are a developer preview and are not published."
        )
    if version_key(version) >= KOREAN_NOTES_VERSION and "korean" not in blocks:
        raise NotesError(f"Release notes for {display_version(version)} are missing Korean (### 한국어)")
    for line in body.splitlines():
        if "![" not in line:
            continue
        match = BANNER.fullmatch(line)
        if not match or match.group("path") not in banner_names(version):
            raise NotesError(f"The banner of {display_version(version)} must name its own version in "
                             f"{BANNERS.as_posix()}, not {line!r}.")
    # Headings, the compare link and banner pictures are not translated content.
    prose = {
        code: "\n".join(line for line in block.splitlines()
                        if not line.startswith("#") and not line.startswith("**Full changelog**")
                        and not BANNER.fullmatch(line)).strip()
        for code, block in blocks.items()
    }
    require_translations(prose, "recorded notes")
    counts = {len(re.findall(r"^[-*] ", block, re.MULTILINE)) for block in prose.values()}
    if len(counts) != 1:
        raise NotesError("Release notes have different numbers of translated changes")
    return text


def bundled_heading_version(line):
    """The `x.y.z` `AppReleaseHistory` accepts for this `##` line, or None.

    The heading is `## [x.y.z](<compare link>) (YYYY-MM-DD)`, or the older
    `## x.y.z — YYYY-MM-DD`, whose first token is the version. Swift parses a
    semantic version: optional `v`/`V`, three numeric components, no leading zeros.
    `## Unreleased` and a `## ` line inside notes are not versions.
    """
    if not line.startswith("## "):
        return None
    rest = line[3:].lstrip(" ")
    if rest.startswith("["):
        linked = LINKED_HEADING.match(rest.rstrip("\n"))
        if not linked:
            return None
        token = linked.group("token")
    else:
        token = rest.split(" ", 1)[0].strip()
    token = token[1:] if token[:1] in "vV" else token
    numbers = token.split(".")
    if len(numbers) != 3 or any(
        not number.isascii() or not number.isdigit() or (len(number) > 1 and number.startswith("0"))
        or len(number) > 19 or int(number) > (1 << 63) - 1
        for number in numbers
    ):
        return None
    return tuple(int(number) for number in numbers)


def require_bundled_history(text, root=ROOT):
    """Refuse a changelog `AppReleaseHistory` cannot parse.

    The update manifest carries the newest sections to the app's update window. Every
    `## ` line is a release heading; one that is not a version fails the whole
    changelog in the app, so publishing must fail here rather than keep or drop it.
    Localized notes are validated against each section's version; every named banner
    must also exist under `root`, where GitHub serves it from.
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
        number = ".".join(str(part) for part in version)
        require_localized_notes(body, number)
        for match in BANNER.finditer(body):
            if not (Path(root) / match.group("path")).is_file():
                raise NotesError(f"The banner of {number} is missing: {match.group('path')}")
    return text


def write_with_model(version, previous, revision, repo=None, cwd=ROOT, transport=None, environ=None, lookup=None):
    """Notes the release-notes model writes from the commits in the range. A range with
    no commits is reported in all three languages without a request. The model names
    each bullet's commits; their issue and commit links, and the thanks line, are added here."""
    entries = []
    available = []
    for entry, change in release_commits(previous, revision, cwd):
        available.append(entry)
        entries.append((entry.short, " ".join(entry.subject.split()), entry.body, change.group == "internal"))
    banners = {code: banner_line(version, cwd, code) for code, _ in LANGUAGE_BLOCKS}
    developer = developer_notes(version, cwd)
    if not entries:
        return render_model_notes(version, empty_notes(), previous, repo, banners, developer=developer)
    thanks = outside_contributors(available, repo, environ, lookup)
    url, model, key = model_settings(environ)
    payload = {
        "model": model,
        "max_tokens": MAX_TOKENS,
        "stream": True,
        "system": SYSTEM_PROMPT,
        "messages": [{"role": "user", "content": model_prompt(version, previous, entries)}],
    }
    text = streamed_text((transport or stream)(url, key, payload))
    return render_model_notes(version, parse_notes(text, available), previous, repo, banners, thanks, developer)


def notes_for(version, previous, revision, repo=None, ai=False, cwd=ROOT, transport=None, environ=None, lookup=None):
    if ai:
        return write_with_model(version, previous, revision, repo, cwd, transport, environ, lookup)
    pairs = list(release_commits(previous, revision, cwd))
    thanks = outside_contributors([entry for entry, _ in pairs], repo, environ, lookup)
    return render(version, [change for _, change in pairs], previous, repo, thanks=thanks)


def published_notes(version, previous, revision, repo, changelog_text, day, ai=False, cwd=ROOT, transport=None, environ=None,
                    lookup=None):
    """Localized source notes and the changelog text the update manifest must carry.

    A recorded localized section is returned unchanged and the model is not called.
    A missing section is written once, with `--ai`, and inserted before the build.
    GitHub publishes its English part. English-only history and a `##` heading the
    app cannot parse are refused: neither is kept nor dropped.
    Returns `(notes, changelog_text, generated)`.
    """
    require_bundled_history(changelog_text, root=cwd)
    recorded = recorded_notes(changelog_text, version)
    if recorded is not None:
        require_localized_notes(recorded, version)
        return recorded, changelog_text, False
    if not ai:
        raise NotesError(
            "Publishing needs localized notes. Listed notes are a developer preview; "
            "pass --ai, or record a ### English / ### 简体中文 / ### 한국어 section first."
        )
    notes = notes_for(version, previous, revision, repo, ai=True, cwd=cwd, transport=transport, environ=environ,
                      lookup=lookup)
    require_localized_notes(notes, version)
    entry = section(version, day, notes, previous, repo)
    updated = insert_section(changelog_text or CHANGELOG_PREAMBLE, version, entry)
    require_bundled_history(updated, root=cwd)
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


def heading(version, day, previous=None, repo=None):
    """`## [x.y.z](<compare link>) (YYYY-MM-DD)`, linking the comparison with `previous`."""
    number = display_version(version)
    url = compare_url(previous, f"v{number}", repo or DEFAULT_REPOSITORY)
    return f"## [{number}]({url}) ({day})"


def section(version, day, body, previous=None, repo=None):
    return f"{heading(version, day, previous, repo)}\n\n{body.strip()}\n\n"


def split_sections(text):
    """`(preamble, [section, ...])`; each section starts at a `## ` heading."""
    positions = [match.start() for match in re.finditer(r"^## ", text, re.MULTILINE)]
    if not positions:
        return text, []
    bounds = positions + [len(text)]
    return text[: positions[0]], [text[bounds[index] : bounds[index + 1]] for index in range(len(positions))]


def section_version(text):
    return bundled_heading_version(text.partition("\n")[0])


def recorded_link(text, version):
    """The compare link `version`'s section heading carries, or None (older headings carry none)."""
    target = version_key(version)
    for item in split_sections(text or "")[1]:
        if section_version(item) == target:
            linked = LINKED_HEADING.match(item.partition("\n")[0][3:].lstrip(" "))
            return linked.group("url") if linked else None
    return None


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
        body += kept.get(version_key(tag)) or section(
            tag, tag_date(tag, cwd), render(tag, changes(earlier, tag, cwd), earlier, repo), earlier, repo)
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
                        help=f"Have the release-notes model write English, Simplified Chinese and Korean (needs {API_KEY_VARIABLE}). Without it, commits are listed in English and are not published.")
    parser.add_argument("--release-body", action="store_true",
                        help="The release page: only the English notes from the localized CHANGELOG.md section (generated once when missing), its compare link and the install footer.")
    parser.add_argument("--built-from", help="Revision the disk image was built from; recorded in the footer.")
    parser.add_argument("--output", help="Write the notes here instead of stdout.")
    parser.add_argument("--changelog", action="store_true", help="Write this version's localized section into CHANGELOG.md.")
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
            print(f"{MARK.ok} Wrote localized notes for {version} into {CHANGELOG.relative_to(ROOT)} before publish", file=sys.stderr)
        recorded = notes
        compare = recorded_link(updated, version) or compare_url(earlier, f"v{version}", repo)
        body = release_body(notes, version, args.built_from, repo, compare)
    else:
        if args.changelog:
            require_bundled_history(existing)
        notes = notes_for(version, earlier, revision, repo, ai=args.ai)
        body = section(version, day, notes, earlier, repo)
        updated = insert_section(existing, version, body)

    if args.changelog and not args.release_body:
        require_localized_notes(notes, version)
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
