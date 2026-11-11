#!/usr/bin/env python3
"""Unit tests for scripts/release_notes.py."""
from __future__ import annotations

import contextlib
import http.server
import importlib.util
import io
import json
import subprocess
import sys
import tempfile
import threading
import unittest
import urllib.request
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
SPEC = importlib.util.spec_from_file_location("release_notes", SCRIPTS / "release_notes.py")
release_notes = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(release_notes)

REPOSITORY = "owner/repo"


def git(*args, cwd):
    subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True)


def commit(cwd, message, name="file.txt"):
    (Path(cwd) / name).write_text(message, encoding="utf-8")
    git("add", "-A", cwd=cwd)
    git("commit", "-m", message, cwd=cwd)


def head(cwd, revision="HEAD"):
    """The full hash of `revision`."""
    return release_notes.git("rev-parse", revision, cwd=cwd).strip()


def suffix(sha, *issues, repo=REPOSITORY):
    """The links a bullet ends with for one commit closing `issues`."""
    links = ", ".join(f"closes [#{number}](https://github.com/{repo}/issues/{number})" for number in issues)
    closes = f" ({links})" if issues else ""
    return f"{closes} ([{sha[:7]}](https://github.com/{repo}/commit/{sha}))"


class ClassifyTests(unittest.TestCase):
    def test_feature_carries_its_scope(self):
        change = release_notes.classify("abc1234", "feat(panel): add a filter rail")
        self.assertEqual(change.group, "features")
        self.assertEqual(change.scope, "panel")
        self.assertEqual(change.subject, "Add a filter rail")

    def test_fix_and_performance_reach_their_sections(self):
        self.assertEqual(release_notes.classify("a", "fix(scene): stop a crash").group, "fixes")
        self.assertEqual(release_notes.classify("b", "perf(renderer): skip a pass").group, "performance")

    def test_documentation_and_tooling_are_internal(self):
        for subject in ("docs: record a run", "test(panel): settle first", "chore(xcode): regenerate", "ci: cache cargo",
                        "refactor(media): remove an unused provider"):
            self.assertEqual(release_notes.classify("a", subject).group, "internal", subject)

    def test_unconventional_subject_is_listed_not_dropped(self):
        change = release_notes.classify("abc1234", "Revert the album-cover rejection")
        self.assertEqual(change.group, "other")
        self.assertEqual(change.scope, "")
        self.assertEqual(change.subject, "Revert the album-cover rejection")

    def test_bang_marks_a_breaking_change(self):
        self.assertEqual(release_notes.classify("a", "feat(bridge)!: drop the old call").group, "breaking")

    def test_breaking_change_trailer_outranks_the_type(self):
        change = release_notes.classify("a", "fix(bridge): rename a field", "BREAKING CHANGE: callers must update")
        self.assertEqual(change.group, "breaking")

    def test_the_bump_commit_is_not_part_of_the_release(self):
        self.assertIsNone(release_notes.classify("a", "chore: bump version to 1.2.3"))

    def test_closing_keywords_name_the_issues_a_commit_closes(self):
        change = release_notes.classify("a", "fix(panel): keep long names (#86)",
                                        "Fixes #76\nCLOSES #12, resolves: #76\nSee #3; fixed owner/other#9; prefix#4")
        self.assertEqual(change.closes, (12, 76))
        self.assertEqual(release_notes.classify("a", "fix(scene): stop a crash").closes, ())
        for keyword in ("close", "closed", "fix", "fixed", "resolve", "Resolved"):
            self.assertEqual(release_notes.closing_refs(f"{keyword} #5"), (5,), keyword)

    def test_a_paragraph_subject_is_cut_at_a_word_boundary(self):
        subject = "fix(media): " + "word " * 60
        change = release_notes.classify("a", subject)
        self.assertLessEqual(len(change.subject), release_notes.SUBJECT_LIMIT + 1)
        self.assertTrue(change.subject.endswith("…"))
        self.assertNotIn("  ", change.subject)


class RenderTests(unittest.TestCase):
    def setUp(self):
        self.changes = [
            release_notes.Change("features", "panel", "Add a filter rail", "aaa1111"),
            release_notes.Change("fixes", "scene", "Stop a crash", "bbb2222"),
            release_notes.Change("internal", "", "Record a run", "ccc3333"),
            release_notes.Change("internal", "", "Record another run", "ddd4444"),
        ]

    def test_sections_are_ordered_and_linked(self):
        body = release_notes.render("0.6.0", self.changes, "v0.5.0", REPOSITORY)
        self.assertTrue(body.startswith("### English\n\n#### Features\n\n"))
        self.assertLess(body.index("#### Features"), body.index("#### Bug Fixes"))
        self.assertIn("- **panel** — Add a filter rail ([aaa1111](https://github.com/owner/repo/commit/aaa1111))", body)
        self.assertNotIn("Full changelog", body, "The section heading carries the compare link")
        entry = release_notes.section("0.6.0", "2026-01-01", body, "v0.5.0", REPOSITORY)
        self.assertTrue(entry.startswith(
            "## [0.6.0](https://github.com/owner/repo/compare/v0.5.0...v0.6.0) (2026-01-01)\n\n### English\n"))

    def test_a_bullet_links_the_issues_and_every_commit_behind_it(self):
        full = "f" * 40
        changes = [
            release_notes.Change("fixes", "panel", "Keep long names", full, (76,)),
            release_notes.Change("fixes", "panel", "keep long names", "e" * 40, (12, 76)),
            release_notes.Change("performance", "", "Skip a pass", "d" * 40),
        ]
        body = release_notes.render("0.6.0", changes, "v0.5.0", REPOSITORY)
        self.assertIn(
            "- **panel** — Keep long names (closes [#12](https://github.com/owner/repo/issues/12), "
            "closes [#76](https://github.com/owner/repo/issues/76)) "
            f"([fffffff](https://github.com/owner/repo/commit/{full}), "
            f"[eeeeeee](https://github.com/owner/repo/commit/{'e' * 40}))\n", body)
        self.assertIn("#### Performance Improvements\n\n- Skip a pass ([ddddddd]", body)

    def test_internal_work_is_counted_not_listed(self):
        body = release_notes.render("0.6.0", self.changes, "v0.5.0", REPOSITORY)
        self.assertIn("Plus 2 documentation, test and tooling commits.", body)
        self.assertNotIn("Record a run", body)

    def test_repeated_wording_collapses(self):
        twice = self.changes + [release_notes.Change("fixes", "scene", "stop a crash", "eee5555")]
        self.assertEqual(release_notes.render("0.6.0", twice, "v0.5.0", REPOSITORY).count("Stop a crash"), 1)

    def test_a_release_with_only_internal_work_says_so(self):
        body = release_notes.render("0.6.0", self.changes[2:], "v0.5.0", REPOSITORY)
        self.assertIn("No user-visible changes since `v0.5.0`.", body)

    def test_a_first_release_links_the_commit_list(self):
        body = release_notes.render("0.1.0", self.changes, None, REPOSITORY)
        self.assertEqual(release_notes.heading("0.1.0", "2026-01-01", None, REPOSITORY),
                         "## [0.1.0](https://github.com/owner/repo/commits/v0.1.0) (2026-01-01)")
        self.assertNotIn("Full changelog", body)

    def test_the_install_footer_names_the_image_the_updater_selects(self):
        footer = release_notes.install_footer("0.6.0", "26.0")
        self.assertLess(footer.index(release_notes.NOTES_END), footer.index("### Install"))
        expected_dmg = release_notes.dmg.image_name("0.6.0")
        self.assertIn(f"`{expected_dmg}`", footer)
        self.assertIn(f"shasum -a 256 -c {expected_dmg}.sha256", footer)
        self.assertIn("macOS 26.0 or later", footer)


class ChangelogTests(unittest.TestCase):
    def section(self, version, body="### Fixed\n\n- Something\n"):
        return release_notes.section(version, "2026-01-01", body)

    def test_newest_version_lands_first(self):
        text = release_notes.insert_section(release_notes.CHANGELOG_PREAMBLE, "0.5.0", self.section("0.5.0"))
        text = release_notes.insert_section(text, "0.6.0", self.section("0.6.0"))
        self.assertLess(text.index("## [0.6.0]"), text.index("## [0.5.0]"))

    def test_an_older_version_lands_below_a_newer_one(self):
        text = release_notes.insert_section(release_notes.CHANGELOG_PREAMBLE, "0.6.0", self.section("0.6.0"))
        text = release_notes.insert_section(text, "0.5.0", self.section("0.5.0"))
        self.assertLess(text.index("## [0.6.0]"), text.index("## [0.5.0]"))

    def test_the_heading_links_the_comparison_and_dates_the_version(self):
        self.assertEqual(release_notes.heading("1.6.2", "2026-10-24", "v1.6.1", REPOSITORY),
                         "## [1.6.2](https://github.com/owner/repo/compare/v1.6.1...v1.6.2) (2026-10-24)")
        self.assertEqual(release_notes.heading("v1.6.2", "2026-10-24"),
                         "## [1.6.2](https://github.com/WallpaperMachine/WallpaperMachine/commits/v1.6.2) (2026-10-24)")
        text = release_notes.insert_section(release_notes.CHANGELOG_PREAMBLE, "1.6.2", release_notes.section(
            "1.6.2", "2026-10-24", "### Fixed\n\n- Something\n", "v1.6.1", REPOSITORY))
        self.assertEqual(release_notes.recorded_link(text, "1.6.2"), "https://github.com/owner/repo/compare/v1.6.1...v1.6.2")
        self.assertIsNone(release_notes.recorded_link("## 1.6.1 — 2026-10-24\n\n- Old\n", "1.6.1"))

    def test_both_heading_forms_name_their_version(self):
        for line, version in (
            ("## [1.6.2](https://github.com/owner/repo/compare/v1.6.1...v1.6.2) (2026-10-24)", (1, 6, 2)),
            ("## [0.1.0](https://github.com/owner/repo/commits/v0.1.0) (2026-09-15)", (0, 1, 0)),
            ("## 1.6.1 — 2026-10-24", (1, 6, 1)),
            ("## [1.6.2](https://example.com/x) (2026-10-24) trailing", None),
            ("## [1.6.2] (2026-10-24)", None),
            ("## [1.6.2](https://example.com/x with space) (2026-10-24)", None),
            ("## [1.6.2-beta](https://example.com/x) (2026-10-24)", None),
            ("## [Unreleased](https://example.com/x)", None),
        ):
            with self.subTest(line=line):
                self.assertEqual(release_notes.bundled_heading_version(line), version)

    def test_rerunning_replaces_rather_than_duplicates(self):
        text = release_notes.insert_section(release_notes.CHANGELOG_PREAMBLE, "0.6.0", self.section("0.6.0"))
        text = release_notes.insert_section(text, "0.6.0", self.section("0.6.0", "### New\n\n- Rewritten\n"))
        self.assertEqual(text.count("## [0.6.0]"), 1)
        self.assertIn("Rewritten", text)
        self.assertNotIn("Something", text)

    def test_the_preamble_survives(self):
        text = release_notes.insert_section(release_notes.CHANGELOG_PREAMBLE, "0.6.0", self.section("0.6.0"))
        self.assertTrue(text.startswith("# Changelog"))

    def test_a_recorded_section_is_read_back_without_its_heading(self):
        text = release_notes.insert_section(release_notes.CHANGELOG_PREAMBLE, "0.5.0", self.section("0.5.0"))
        text = release_notes.insert_section(text, "0.6.0", self.section("0.6.0", "### New\n\n- Recorded\n"))
        self.assertEqual(release_notes.recorded_notes(text, "v0.6.0"), "### New\n\n- Recorded\n")
        self.assertEqual(release_notes.recorded_notes(text, "0.5.0"), "### Fixed\n\n- Something\n")

    def test_a_version_without_a_section_has_no_recorded_notes(self):
        text = release_notes.insert_section(release_notes.CHANGELOG_PREAMBLE, "0.5.0", self.section("0.5.0"))
        self.assertIsNone(release_notes.recorded_notes(text, "0.6.0"))

    def test_an_older_heading_is_still_read_and_replaced_by_the_new_form(self):
        text = release_notes.CHANGELOG_PREAMBLE + "## 0.5.0 — 2026-01-01\n\n### Fixed\n\n- Old\n"
        self.assertEqual(release_notes.recorded_notes(text, "0.5.0"), "### Fixed\n\n- Old\n")
        text = release_notes.insert_section(text, "0.5.0", self.section("0.5.0", "### Fixed\n\n- New\n"))
        self.assertNotIn("## 0.5.0 —", text)
        self.assertEqual(text.count("## [0.5.0]"), 1)

    def test_the_committed_changelog_is_valid_history(self):
        text = release_notes.CHANGELOG.read_text(encoding="utf-8")
        self.assertEqual(release_notes.require_bundled_history(text), text)
        self.assertTrue(text.startswith(release_notes.CHANGELOG_PREAMBLE))
        for line in text.splitlines():
            if line.startswith("## "):
                self.assertRegex(line, release_notes.LINKED_HEADING.pattern.replace("^", "^## ", 1))


def model_reply(text, stop="end_turn"):
    """A streamed Messages API reply carrying `text`, the way the gateway sends it:
    a thinking block and a ping first, then the text in several deltas."""
    events = [
        {"type": "message_start", "message": {"id": "msg", "role": "assistant", "content": []}},
        {"type": "ping"},
        {"type": "content_block_start", "index": 0, "content_block": {"type": "thinking", "thinking": ""}},
        {"type": "content_block_delta", "index": 0, "delta": {"type": "thinking_delta", "thinking": "{\"not\": \"notes\"}"}},
        {"type": "content_block_stop", "index": 0},
        {"type": "content_block_start", "index": 1, "content_block": {"type": "text", "text": ""}},
    ]
    step = max(1, len(text) // 3)
    events += [{"type": "content_block_delta", "index": 1, "delta": {"type": "text_delta", "text": text[start:start + step]}}
               for start in range(0, len(text), step)]
    events += [{"type": "content_block_stop", "index": 1},
               {"type": "message_delta", "delta": {"stop_reason": stop}},
               {"type": "message_stop"}]
    lines = []
    for event in events:
        lines += [f"event: {event['type']}", "data: " + json.dumps(event), ""]
    return lines


class Transport:
    """Stands in for the gateway: records each request and answers with `lines`."""

    def __init__(self, lines):
        self.lines = lines
        self.requests = []

    def __call__(self, url, key, payload):
        self.requests.append((url, key, payload))
        return iter(self.lines)


KEY = {"RELEASE_NOTES_API_KEY": "test-key"}


def translations(english, chinese, korean):
    return {"english": english, "chinese": chinese, "korean": korean}


# The commits the model replies below may cite: the first closes two issues.
FIX_SHA = "a1b2c3d" + "4" * 33
COMMITS = (
    release_notes.Commit(FIX_SHA, "a1b2c3d", "fix(scene): keep layers in place (#20)", "Fixes #12\nCloses #3\n"),
    release_notes.Commit("a1b2c99" + "5" * 33, "a1b2c99", "feat(panel): count downloads", ""),
    release_notes.Commit("c0ffee1" + "6" * 33, "c0ffee1", "docs: record a run", ""),
)


def trilingual(commits=("a1b2c3d",), **sections):
    """A new model reply in the required shape. Omitted sections are empty; a bullet
    without its own `commits` cites `commits`."""
    notes = {"summary": sections.pop("summary", translations("", "", ""))}
    for key, _heading in release_notes.MODEL_SECTIONS:
        items = sections.pop(key, [])
        notes[key] = [dict(item, commits=list(commits)) if isinstance(item, dict) and "commits" not in item else item
                      for item in items]
    if sections:
        raise AssertionError(f"unknown sections {sorted(sections)}")
    return json.dumps(notes)


LAYERS = translations("Layers stay in place", "图层保持原位", "레이어가 제자리에 유지됨")
WAKE = translations("A crash on wake", "唤醒时不再崩溃", "잠자기에서 깨어날 때 충돌하지 않음")


class ModelReplyTests(unittest.TestCase):
    def notes(self, reply):
        return release_notes.render_model_notes(
            "0.6.0", release_notes.parse_notes(release_notes.streamed_text(reply), COMMITS), "v0.5.0", REPOSITORY)

    def test_all_languages_keep_the_same_changes_in_order(self):
        body = self.notes(model_reply(trilingual(
            summary=translations("Music wallpapers work again.", "音乐壁纸恢复正常。", "음악 배경화면이 다시 작동함."),
            fixed=[translations("Album covers show again.", "专辑封面重新显示", "앨범 표지가 다시 표시됨")],
            new=[translations("- Choose how many downloads run at once", "可以选择同时进行的下载数量", "동시 다운로드 수를 선택할 수 있음")],
            breaking=[translations("Old presets are no longer read", "不再读取旧的预设", "이전 사전 설정을 더 이상 읽지 않음")],
        )))
        blocks = release_notes.language_blocks(body)
        english, chinese, korean = (blocks[code] for code in ("english", "chinese", "korean"))
        links = suffix(FIX_SHA, 3, 12)
        self.assertTrue(body.startswith("### English\n\nMusic wallpapers work again\n"))
        self.assertLess(english.index("#### Breaking Changes"), english.index("#### Features"))
        self.assertLess(english.index("#### Features"), english.index("#### Bug Fixes"))
        self.assertNotIn("#### Improvements", body)
        self.assertIn(f"- Choose how many downloads run at once{links}\n", english)
        self.assertIn(f"- Album covers show again{links}\n", english)
        self.assertLess(chinese.index("#### 不兼容变更"), chinese.index("#### 新功能"))
        self.assertLess(chinese.index("#### 新功能"), chinese.index("#### 问题修复"))
        self.assertIn(f"- 可以选择同时进行的下载数量{links}\n", chinese)
        self.assertIn(f"- 专辑封面重新显示{links}\n", chinese)
        self.assertLess(korean.index("#### 호환되지 않는 변경 사항"), korean.index("#### 새로운 기능"))
        self.assertLess(korean.index("#### 새로운 기능"), korean.index("#### 버그 수정"))
        self.assertIn(f"- 앨범 표지가 다시 표시됨{links}\n", korean)
        self.assertLess(body.index("### 简体中文"), body.index("### 한국어"))
        self.assertNotIn("Full changelog", body, "The section heading carries the compare link")
        release_notes.require_localized_notes(body, "0.6.0")

    def test_a_bullet_links_every_commit_it_names(self):
        body = self.notes(model_reply(trilingual(commits=("A1B2C9", "a1b2c3d4", "a1b2c3d"), fixed=[WAKE])))
        links = (" (closes [#3](https://github.com/owner/repo/issues/3), closes [#12](https://github.com/owner/repo/issues/12))"
                 f" ([a1b2c99](https://github.com/owner/repo/commit/{COMMITS[1].sha}),"
                 f" [a1b2c3d](https://github.com/owner/repo/commit/{FIX_SHA}))")
        for text in WAKE.values():
            self.assertIn(f"- {text}{links}\n", body)
        docs = self.notes(model_reply(trilingual(commits=("c0ffee1",), fixed=[WAKE])))
        self.assertIn(f"- A crash on wake ([c0ffee1](https://github.com/owner/repo/commit/{COMMITS[2].sha}))\n", docs)

    def test_every_bullet_must_name_commits_of_the_release(self):
        for commits in ([], "a1b2c3d", None, {"sha": "a1b2c3d"}, [7], ["zzzzzzz"], ["a1b"], ["deadbee"],
                        ["a1b2c3d", "ffff"]):
            reply = trilingual(fixed=[dict(WAKE, commits=commits)])
            with self.subTest(commits=commits), self.assertRaisesRegex(release_notes.NotesError, "commits"):
                self.notes(model_reply(reply))
        for section in ("highlights", "breaking", "new", "improved", "fixed"):
            with self.subTest(section=section), self.assertRaisesRegex(release_notes.NotesError, "more than one commit"):
                self.notes(model_reply(trilingual(commits=("a1b2c",), **{section: [WAKE]})))
        data = json.loads(trilingual(fixed=[WAKE]))
        del data["fixed"][0]["commits"]
        with self.assertRaisesRegex(release_notes.NotesError, "commits"):
            self.notes(model_reply(json.dumps(data)))
        with self.assertRaises(release_notes.NotesError):
            self.notes(model_reply(trilingual(summary=dict(WAKE, commits=["a1b2c3d"]))))

    def test_highlights_lead_all_languages(self):
        body = self.notes(model_reply(trilingual(
            highlights=[translations("A rebuilt control panel", "全新的控制面板", "새롭게 설계된 제어 패널")],
            new=[translations("Choose how many downloads run at once", "可以选择同时进行的下载数量", "동시 다운로드 수를 선택할 수 있음")],
            improved=[translations("Faster searches", "搜索更快", "더 빠른 검색")],
        )))
        blocks = release_notes.language_blocks(body)
        english, chinese, korean = (blocks[code] for code in ("english", "chinese", "korean"))
        links = suffix(FIX_SHA, 3, 12)
        self.assertLess(english.index(f"#### Highlights\n\n- A rebuilt control panel{links}\n"), english.index("#### Features"))
        self.assertLess(english.index("#### Features"), english.index("#### Improvements"))
        self.assertLess(chinese.index(f"#### 亮点\n\n- 全新的控制面板{links}\n"), chinese.index("#### 新功能"))
        self.assertLess(chinese.index("#### 新功能"), chinese.index("#### 改进"))
        self.assertLess(korean.index(f"#### 주요 변경 사항\n\n- 새롭게 설계된 제어 패널{links}\n"), korean.index("#### 새로운 기능"))
        self.assertLess(korean.index("#### 새로운 기능"), korean.index("#### 개선 사항"))
        release_notes.require_localized_notes(body, "0.6.0")

    def test_a_reply_in_a_code_fence_is_still_read(self):
        body = self.notes(model_reply("```json\n" + trilingual(fixed=[WAKE]) + "\n```"))
        self.assertIn(f"### English\n\n#### Bug Fixes\n\n- A crash on wake{suffix(FIX_SHA, 3, 12)}\n", body)
        self.assertIn(f"### 简体中文\n\n#### 问题修复\n\n- 唤醒时不再崩溃{suffix(FIX_SHA, 3, 12)}\n", body)

    def test_notes_with_nothing_in_them_say_so_in_all_languages(self):
        body = self.notes(model_reply(trilingual(fixed=[translations(" ", " ", " ")])))
        self.assertIn("### English\n\nNo user-visible changes since `v0.5.0`.", body)
        self.assertIn("### 简体中文\n\n自 `v0.5.0` 以来没有用户能察觉的变化。", body)
        self.assertIn("### 한국어\n\n`v0.5.0` 이후 사용자에게 표시되는 변경 사항이 없습니다.", body)
        self.assertNotIn("](https://", body)

    def test_empty_notes_without_a_previous_tag_are_translated(self):
        body = release_notes.render_model_notes("1.5.7", release_notes.empty_notes())
        self.assertIn("### English\n\nNo user-visible changes in this history.", body)
        self.assertIn("### 简体中文\n\n这段历史里没有用户能察觉的变化。", body)
        self.assertIn("### 한국어\n\n이 기록에는 사용자에게 표시되는 변경 사항이 없습니다.", body)
        release_notes.require_localized_notes(body, "1.5.7")

    def test_a_multi_line_entry_cannot_open_a_changelog_section(self):
        body = self.notes(model_reply(trilingual(
            summary=translations("## 9.9.9\nSurprise", "意外的摘要不会另起一节", "요약이 새 절을 열지 않음"),
            fixed=[translations("One\n## 9.9.9 heading", "一行里的标题不会另起一节", "제목이 새 절을 열지 않음")],
        )))
        self.assertEqual(len(release_notes.split_sections("# Changelog\n\n## 0.6.0 — day\n\n" + body)[1]), 1)

    def test_the_release_notes_boundary_is_refused(self):
        with self.assertRaises(release_notes.NotesError):
            self.notes(model_reply(trilingual(fixed=[translations("Fixed <!-- release-notes-end --> early", "提前结束", "조기 종료")])))

    def test_a_missing_language_stops_the_run(self):
        for reply in (
            json.dumps({"summary": "Music wallpapers work again.", "fixed": ["Album covers show again."]}),
            trilingual(fixed=[{"english": "Album covers show again"}]),
            trilingual(summary=translations("Music wallpapers work again.", "", "음악 배경화면이 다시 작동함")),
            trilingual(fixed=[translations("Album covers show again.", "Album covers show again.", "앨범 표지가 다시 표시됨")]),
            trilingual(fixed=[translations("Album covers show again.", "OK", "앨범 표지가 다시 표시됨")]),
            trilingual(fixed=[translations("专辑封面", "专辑封面重新显示", "앨범 표지가 다시 표시됨")]),
        ):
            with self.assertRaises(release_notes.NotesError):
                self.notes(model_reply(reply))

    def test_korean_is_required_in_the_summary_and_every_bullet(self):
        for field in ("summary", "fixed"):
            for korean in (None, "", " ", "Layers stay in place", "图层保持原位", "Layer ga jejari", 7):
                item = dict(LAYERS, korean=korean)
                if korean is None:
                    del item["korean"]
                reply = trilingual(**{field: item if field == "summary" else [item]})
                with self.subTest(field=field, korean=korean), self.assertRaises(release_notes.NotesError):
                    self.notes(model_reply(reply))

    def test_copied_korean_is_rejected_even_when_the_source_contains_hangul(self):
        for source in ("english", "chinese"):
            item = dict(LAYERS)
            item[source] += " 다시"
            item["korean"] = item[source]
            with self.subTest(source=source), self.assertRaises(release_notes.NotesError):
                self.notes(model_reply(trilingual(fixed=[item])))

    def test_the_summary_must_be_a_trilingual_object(self):
        for summary in (None, "", {}, {"english": "", "chinese": ""}):
            with self.subTest(summary=summary), self.assertRaises(release_notes.NotesError):
                self.notes(model_reply(trilingual(summary=summary)))
        data = json.loads(trilingual())
        del data["summary"]
        with self.assertRaises(release_notes.NotesError):
            self.notes(model_reply(json.dumps(data)))

    def test_translation_objects_reject_unknown_fields_and_non_text_values(self):
        for field in ("summary", "fixed"):
            for item in (dict(LAYERS, japanese="翻訳"), dict(LAYERS, english=7), dict(LAYERS, chinese=[])):
                with self.subTest(field=field, item=item), self.assertRaises(release_notes.NotesError):
                    self.notes(model_reply(trilingual(**{field: item if field == "summary" else [item]})))

    def test_a_reply_that_is_not_json_stops_the_run(self):
        with self.assertRaises(release_notes.NotesError):
            self.notes(model_reply("### English\n\n- Something"))

    def test_unexpected_fields_stop_the_run(self):
        with self.assertRaises(release_notes.NotesError):
            self.notes(model_reply(json.dumps({"summary": translations("", "", ""), "security": [WAKE]})))

    def test_a_reply_cut_off_at_the_token_limit_stops_the_run(self):
        with self.assertRaises(release_notes.NotesError):
            release_notes.streamed_text(model_reply(trilingual(fixed=[WAKE]), stop="max_tokens"))

    def test_an_error_event_stops_the_run(self):
        lines = model_reply("")[:6] + ["event: error", 'data: {"type": "error", "error": {"type": "overloaded_error", "message": "Overloaded"}}']
        with self.assertRaisesRegex(release_notes.NotesError, "Overloaded"):
            release_notes.streamed_text(lines)

    def test_the_gateway_base_may_name_its_api_version(self):
        self.assertEqual(release_notes.model_settings(KEY)[0], "https://sub2api.moraxcheng.me/v1/messages")
        with_version = dict(KEY, RELEASE_NOTES_API_BASE="https://gateway.example/v1/")
        self.assertEqual(release_notes.model_settings(with_version)[0], "https://gateway.example/v1/messages")

class Gateway(http.server.BaseHTTPRequestHandler):
    """A local stand-in for the gateway: answers each POST with `reply`, keeps the requests."""

    reply = (200, "text/event-stream", b"")
    requests = []

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("content-length", 0)))
        Gateway.requests.append((self.path, {name.lower(): value for name, value in self.headers.items()}, json.loads(body)))
        status, kind, payload = Gateway.reply
        self.send_response(status)
        self.send_header("content-type", kind)
        self.send_header("content-length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *args):
        pass


class GatewayTransportTests(unittest.TestCase):
    """The real request over HTTP, which the fake transports above never make."""

    def setUp(self):
        Gateway.reply, Gateway.requests = (200, "text/event-stream", b""), []
        # Straight to the local server whatever proxy this machine is set up with.
        urllib.request.install_opener(urllib.request.build_opener(urllib.request.ProxyHandler({})))
        self.addCleanup(urllib.request.install_opener, None)
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Gateway)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        self.url, _, self.key = release_notes.model_settings(
            dict(KEY, RELEASE_NOTES_API_BASE=f"http://127.0.0.1:{server.server_address[1]}"))

    def ask(self):
        return release_notes.streamed_text(release_notes.stream(self.url, self.key, {"model": release_notes.MODEL, "stream": True}))

    def test_the_reply_streams_back_with_the_headers_the_gateway_needs(self):
        reply = json.dumps({"summary": "", "fixed": ["A crash on wake"]})
        Gateway.reply = (200, "text/event-stream", ("\n".join(model_reply(reply)) + "\n").encode())
        self.assertEqual(self.ask(), reply)
        path, headers, payload = Gateway.requests[0]
        self.assertEqual(path, "/v1/messages")
        self.assertEqual(payload["stream"], True)
        # Cloudflare in front of the real gateway refuses urllib's default agent.
        self.assertEqual((headers["x-api-key"], headers["anthropic-version"], headers["user-agent"]),
                         ("test-key", "2023-06-01", release_notes.USER_AGENT))

    def test_a_refusal_carries_the_gateways_own_message(self):
        Gateway.reply = (401, "application/json",
                         b'{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}')
        with self.assertRaisesRegex(release_notes.NotesError, "HTTP 401.*invalid x-api-key"):
            self.ask()

    def test_a_reply_past_the_deadline_stops_the_run(self):
        Gateway.reply = (200, "text/event-stream", ("\n".join(model_reply("{}")) + "\n").encode())
        deadline = release_notes.DEADLINE
        release_notes.DEADLINE = -1
        self.addCleanup(setattr, release_notes, "DEADLINE", deadline)
        with self.assertRaisesRegex(release_notes.NotesError, "had not finished"):
            self.ask()


class ModelRangeTests(unittest.TestCase):
    """What the model is given and what the release page keeps, over a real history."""

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        self.addCleanup(self.directory.cleanup)
        git("init", "-q", "-b", "main", cwd=self.root)
        git("config", "user.email", "test@example.com", cwd=self.root)
        git("config", "user.name", "Test", cwd=self.root)
        git("config", "commit.gpgsign", "false", cwd=self.root)
        commit(self.root, "feat(panel): first feature")
        git("tag", "v0.1.0", cwd=self.root)
        commit(self.root, "fix(scene): keep layers in place\n\nParallax no longer pushes the planet out of frame.\n\n"
                          "Fixes #41")
        self.fix = head(self.root)
        commit(self.root, "docs(testing): record a run\n\nInternal verification notes nobody should read.")
        commit(self.root, "chore: bump version to 0.2.0")
        self.bump = head(self.root)
        self.short = release_notes.git("log", "-1", "--format=%h", self.fix, cwd=self.root).strip()
        self.reply = Transport(model_reply(trilingual(commits=(self.short,), fixed=[LAYERS])))
        self.links = suffix(self.fix, 41)

    def write(self, previous="v0.1.0", environ=KEY):
        return release_notes.write_with_model("0.2.0", previous, "HEAD", REPOSITORY, self.root, self.reply, environ)

    def test_the_model_reads_user_visible_bodies_and_writes_all_languages(self):
        body = self.write()
        self.assertIn(f"### English\n\n#### Bug Fixes\n\n- Layers stay in place{self.links}\n", body)
        self.assertIn(f"### 简体中文\n\n#### 问题修复\n\n- 图层保持原位{self.links}\n", body)
        self.assertIn(f"### 한국어\n\n#### 버그 수정\n\n- 레이어가 제자리에 유지됨{self.links}\n", body)
        url, key, payload = self.reply.requests[0]
        prompt = payload["messages"][0]["content"]
        self.assertEqual((url, key, payload["model"], payload["stream"]),
                         ("https://sub2api.moraxcheng.me/v1/messages", "test-key", release_notes.MODEL, True))
        self.assertIn("2 commits since v0.1.0", prompt)
        self.assertIn(f"* {self.short} fix(scene): keep layers in place\n", prompt, "The model cites the hash it is shown")
        self.assertIn("Parallax no longer pushes the planet out of frame.", prompt)
        self.assertIn("docs(testing): record a run", prompt)
        self.assertNotIn("Internal verification notes", prompt)
        self.assertNotIn("bump version", prompt)

    def test_a_bullet_may_cite_only_commits_of_the_range(self):
        for cited in (self.bump[:7], head(self.root, "v0.1.0")[:7]):
            self.reply = Transport(model_reply(trilingual(commits=(cited,), fixed=[LAYERS])))
            with self.subTest(cited=cited), self.assertRaisesRegex(release_notes.NotesError, "matches no commit"):
                self.write()

    def test_only_a_feature_release_asks_for_highlights(self):
        self.write()
        self.assertIn("This is a feature release", self.reply.requests[0][2]["messages"][0]["content"])
        release_notes.write_with_model("0.1.1", "v0.1.0", "HEAD", REPOSITORY, self.root, self.reply, KEY)
        self.assertIn("This is a patch release", self.reply.requests[1][2]["messages"][0]["content"])

    def test_a_patch_replacing_an_unpublished_feature_release_asks_for_highlights(self):
        # 0.2.0 was tagged but never published: 0.2.1's notes start at 0.1.0 and are the
        # first anyone reads of 0.2.
        release_notes.write_with_model("0.2.1", "v0.1.0", "HEAD", REPOSITORY, self.root, self.reply, KEY)
        self.assertIn("This is a feature release", self.reply.requests[0][2]["messages"][0]["content"])

    def test_a_developer_note_is_printed_as_written_in_every_language(self):
        notes_dir = self.root / release_notes.DEVELOPER_NOTES
        notes_dir.mkdir(parents=True)
        (notes_dir / "0.2.0.md").write_text("Sorry about\nthis bug.\n\nWe will test more.\n", encoding="utf-8")
        (notes_dir / "0.2.0.zh-Hans.md").write_text("抱歉。\n\n我们会多测试。\n", encoding="utf-8")
        with self.assertRaisesRegex(release_notes.NotesError, "0.2.0.ko.md"):
            self.write()
        self.assertEqual(len(self.reply.requests), 0, "A broken note stops the run before the model is asked")
        (notes_dir / "0.2.0.ko.md").write_text("죄송합니다.\n\n더 많이 테스트하겠습니다.\n", encoding="utf-8")
        notes = self.write()
        self.assertIn("### English\n\n#### A note from the developer\n\nSorry about this bug.\n\nWe will test more.\n\n"
                      "#### Bug Fixes", notes)
        self.assertIn("### 简体中文\n\n#### 开发者的话\n\n抱歉。\n\n我们会多测试。\n\n#### 问题修复", notes)
        self.assertIn("### 한국어\n\n#### 개발자의 말\n\n죄송합니다.\n\n더 많이 테스트하겠습니다.\n\n#### 버그 수정", notes)
        self.assertNotIn("Sorry", self.reply.requests[-1][2]["messages"][0]["content"], "The model never sees the note")
        release_notes.require_bundled_history(release_notes.section("0.2.0", "2026-01-01", notes), root=self.root)
        page = release_notes.release_body(notes, "0.2.0", repo=REPOSITORY).split(release_notes.NOTES_END)[0]
        self.assertIn("#### A note from the developer\n\nSorry about this bug.", page)
        self.assertNotIn("抱歉", page)

    def test_a_developer_note_is_plain_paragraphs(self):
        notes_dir = self.root / release_notes.DEVELOPER_NOTES
        notes_dir.mkdir(parents=True)
        (notes_dir / "0.2.0.zh-Hans.md").write_text("抱歉。\n", encoding="utf-8")
        (notes_dir / "0.2.0.ko.md").write_text("죄송합니다.\n", encoding="utf-8")
        for english in ("## 9.9.9\n", "- a list\n", "![x](y.png)\n", "Ends <!-- release-notes-end -->\n"):
            (notes_dir / "0.2.0.md").write_text("Sorry.\n\n" + english, encoding="utf-8")
            with self.subTest(english=english), self.assertRaisesRegex(release_notes.NotesError, "plain paragraphs"):
                self.write()
        (notes_dir / "0.2.0.md").write_text("抱歉。\n", encoding="utf-8")
        with self.assertRaisesRegex(release_notes.NotesError, "not english|repeat a language"):
            self.write()

    def test_each_language_opens_with_its_own_banner(self):
        self.assertNotIn("![", self.write(), "No picture, no banner line")
        banners = self.root / "Resources" / "ReleaseBanners"
        banners.mkdir(parents=True)
        (banners / "0.2.0.jpg").write_bytes(b"jpeg")
        shared = self.write()
        self.assertIn("### English\n\n![WallpaperMachine 0.2.0](Resources/ReleaseBanners/0.2.0.jpg)\n\n#### Bug Fixes", shared)
        self.assertIn("### 简体中文\n\n![WallpaperMachine 0.2.0](Resources/ReleaseBanners/0.2.0.jpg)\n\n#### 问题修复", shared,
                      "Without its own picture Chinese shares the English one")
        self.assertIn("### 한국어\n\n![WallpaperMachine 0.2.0](Resources/ReleaseBanners/0.2.0.jpg)\n\n#### 버그 수정", shared,
                      "Without its own picture Korean shares the English one")
        (banners / "0.2.0.zh-Hans.png").write_bytes(b"png")
        chinese_only = self.write()
        self.assertIn("### 한국어\n\n![WallpaperMachine 0.2.0](Resources/ReleaseBanners/0.2.0.jpg)\n", chinese_only,
                      "Korean falls back to English, never to the Chinese picture")
        (banners / "0.2.0.ko.jpg").write_bytes(b"jpeg")
        notes = self.write()
        self.assertIn("### 简体中文\n\n![WallpaperMachine 0.2.0](Resources/ReleaseBanners/0.2.0.zh-Hans.png)\n", notes)
        self.assertIn("### 한국어\n\n![WallpaperMachine 0.2.0](Resources/ReleaseBanners/0.2.0.ko.jpg)\n", notes)
        release_notes.require_bundled_history(release_notes.section("0.2.0", "2026-01-01", notes), root=self.root)
        compare = release_notes.compare_url("v0.1.0", "v0.2.0", REPOSITORY)
        page = release_notes.release_body(notes, "0.2.0", repo=REPOSITORY, compare=compare).split(release_notes.NOTES_END)[0]
        self.assertTrue(page.startswith(
            f"### English\n\n![WallpaperMachine 0.2.0](https://raw.githubusercontent.com/{REPOSITORY}/v0.2.0/"
            "Resources/ReleaseBanners/0.2.0.jpg)\n\n#### Bug Fixes"))
        self.assertIn(f"- Layers stay in place{self.links}\n", page, "The release page keeps the links")
        self.assertTrue(page.rstrip().endswith(f"**Full changelog**: {compare}"))
        self.assertNotIn("zh-Hans", page)
        self.assertNotIn(".ko.", page)
        self.assertNotIn("한국어", page)
        self.assertNotIn("레이어", page)
        self.assertEqual(page.count("**Full changelog**:"), 1)
        self.assertNotIn("![", release_notes.release_body(notes, "0.2.0"), "Without a repository the page has no address for it")

    def test_a_squash_merge_brings_the_body_of_every_commit_it_lists(self):
        long = "Rotate moves through all wallpapers in order or shuffled. " * 40
        commit(self.root, "\n".join([
            "feat: playlists and Workshop updates (#15)", "",
            "* feat(playlists): rotate each display's wallpaper", "", long, "",
            "Co-Authored-By: Claude <noreply@anthropic.com>", "",
            "* docs(testing): record the run", "", "Squashed verification notes nobody should read.", "",
            "* feat(workshop): find and install updates", "", "Update all downloads the new versions.", "",
            "---------", "", "Co-authored-by: Claude <noreply@anthropic.com>",
        ]))
        self.write()
        prompt = self.reply.requests[0][2]["messages"][0]["content"]
        self.assertIn("\n    * feat(playlists): rotate each display's wallpaper\n", prompt)
        self.assertIn("\n    * feat(workshop): find and install updates\n      Update all downloads the new versions.\n",
                      prompt)
        self.assertIn("\n    * docs(testing): record the run\n", prompt)
        self.assertNotIn("Squashed verification notes", prompt)
        self.assertLess(prompt.count("Rotate moves through"), 40)
        self.assertNotIn("noreply@anthropic.com", prompt)
        self.assertNotIn("---", prompt)

    def test_a_range_without_commits_needs_no_request(self):
        git("tag", "v0.2.0", cwd=self.root)
        body = release_notes.write_with_model("1.5.7", "v0.2.0", "HEAD", REPOSITORY, self.root, self.reply, {})
        self.assertIn("### English\n\nNo user-visible changes since `v0.2.0`.", body)
        self.assertIn("### 简体中文\n\n自 `v0.2.0` 以来没有用户能察觉的变化。", body)
        self.assertIn("### 한국어\n\n`v0.2.0` 이후 사용자에게 표시되는 변경 사항이 없습니다.", body)
        release_notes.require_localized_notes(body, "1.5.7")
        self.assertEqual(self.reply.requests, [])

    def test_a_bump_only_range_needs_no_request(self):
        # The repository's bump-only range is also empty after filtering.
        commit(self.root, "chore: bump version to 1.5.7")
        previous = release_notes.git("rev-parse", "HEAD~1", cwd=self.root).strip()
        body = release_notes.write_with_model("1.5.7", previous, "HEAD", REPOSITORY, self.root, self.reply, {})
        self.assertIn("### 한국어", body)
        self.assertEqual(self.reply.requests, [])

    def test_a_missing_key_stops_before_any_request(self):
        with self.assertRaisesRegex(release_notes.NotesError, "RELEASE_NOTES_API_KEY"):
            self.write(environ={})
        self.assertEqual(self.reply.requests, [])

    def test_the_release_page_keeps_only_english_notes_and_links_without_raw_commit_messages(self):
        original = self.write()
        compare = release_notes.compare_url("v0.1.0", "v0.2.0", REPOSITORY)
        body = release_notes.release_body(original, "0.2.0", "abc1234", compare=compare)
        notes, page = body.split(release_notes.NOTES_END)
        self.assertIn(f"### English\n\n#### Bug Fixes\n\n- Layers stay in place{self.links}\n", notes)
        self.assertNotIn("### 简体中文", notes)
        self.assertNotIn("图层保持原位", notes)
        self.assertNotIn("### 한국어", notes)
        self.assertNotIn("레이어가 제자리에 유지됨", notes)
        self.assertIn(f"https://github.com/{REPOSITORY}/compare/v0.1.0...v0.2.0", notes)
        self.assertIn(release_notes.dmg.image_name("0.2.0"), page)
        self.assertIn("abc1234", page)
        self.assertNotIn("docs(testing): record a run", body)
        self.assertNotIn("fix(scene): keep layers in place", body)
        self.assertNotIn("<details>", body)



LEGACY_RECORDED = """\
### English

Layers stay in place.

#### Fixed

- Layers stay in place

### 简体中文

图层保持原位。

#### 修复

- 图层保持原位

**Full changelog**: https://github.com/owner/repo/compare/v0.1.0...v0.2.0
"""


TRILINGUAL_RECORDED = """\
### English

Layers stay in place.

#### Bug Fixes

- Layers stay in place (closes [#41](https://github.com/owner/repo/issues/41)) ([abcdef1](https://github.com/owner/repo/commit/abcdef1234))

### 简体中文

图层保持原位。

#### 问题修复

- 图层保持原位 (closes [#41](https://github.com/owner/repo/issues/41)) ([abcdef1](https://github.com/owner/repo/commit/abcdef1234))

### 한국어

레이어가 제자리에 유지됨.

#### 버그 수정

- 레이어가 제자리에 유지됨 (closes [#41](https://github.com/owner/repo/issues/41)) ([abcdef1](https://github.com/owner/repo/commit/abcdef1234))
"""


class PublishTests(unittest.TestCase):
    """Localized source notes are stored once; GitHub shows only their English part."""

    def changelog(self, body, version="0.2.0", previous=None):
        return release_notes.insert_section(
            release_notes.CHANGELOG_PREAMBLE, version,
            release_notes.section(version, "2026-01-01", body, previous, REPOSITORY))

    def test_recorded_bilingual_notes_are_reused_exactly(self):
        text = self.changelog(LEGACY_RECORDED)
        transport = Transport(model_reply(trilingual(fixed=[LAYERS])))
        notes, updated, generated = release_notes.published_notes(
            "0.2.0", "v0.1.0", "HEAD", REPOSITORY, text, "2026-09-29", ai=True, transport=transport)
        self.assertFalse(generated)
        self.assertEqual(updated, text)
        self.assertEqual(notes, release_notes.recorded_notes(text, "0.2.0"))
        self.assertEqual(transport.requests, [])
        page = release_notes.release_body(notes, "0.2.0")
        self.assertIn("Layers stay in place.", page)
        self.assertNotIn("图层保持原位", page)

    def test_generated_trilingual_notes_are_stored_once_and_published_in_english(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        root = Path(directory.name)
        git("init", "-q", "-b", "main", cwd=root)
        git("config", "user.email", "test@example.com", cwd=root)
        git("config", "user.name", "Test", cwd=root)
        git("config", "commit.gpgsign", "false", cwd=root)
        commit(root, "fix(scene): keep layers in place\n\nCloses #41")
        transport = Transport(model_reply(trilingual(commits=(head(root)[:9],), fixed=[LAYERS])))
        notes, updated, generated = release_notes.published_notes(
            "1.5.7", None, "HEAD", REPOSITORY, self.changelog(LEGACY_RECORDED, "1.5.6"), "2026-01-01",
            ai=True, cwd=root, transport=transport, environ=KEY)
        self.assertTrue(generated)
        self.assertEqual(len(transport.requests), 1)
        self.assertEqual(notes, release_notes.recorded_notes(updated, "1.5.7"))
        self.assertIn("\n## [1.5.7](https://github.com/owner/repo/commits/v1.5.7) (2026-01-01)\n\n### English\n", updated)
        self.assertIn(f"- 레이어가 제자리에 유지됨{suffix(head(root), 41)}\n", notes)
        self.assertIn("### English", notes)
        self.assertIn("### 简体中文", notes)
        self.assertIn("### 한국어", notes)
        self.assertIn("- Layers stay in place", notes)
        self.assertIn("- 图层保持原位", notes)
        self.assertIn("- 레이어가 제자리에 유지됨", notes)
        self.assertEqual(release_notes.split_sections(updated)[1][1],
                         release_notes.split_sections(self.changelog(LEGACY_RECORDED, "1.5.6"))[1][0])
        reused, untouched, regenerated = release_notes.published_notes(
            "1.5.7", None, "HEAD", REPOSITORY, updated, "2026-09-29", ai=True,
            cwd=root, transport=transport, environ={})
        self.assertEqual((reused, untouched, regenerated), (notes, updated, False))
        self.assertEqual(len(transport.requests), 1)
        page = release_notes.release_body(notes, "1.5.7")
        self.assertIn("- Layers stay in place", page.split(release_notes.NOTES_END, 1)[0])
        self.assertNotIn("图层保持原位", page)
        self.assertNotIn("레이어", page)

    def test_korean_boundary_validates_the_section_version(self):
        for version in ("0.2.0", "1.5.6"):
            with self.subTest(version=version):
                text = self.changelog(LEGACY_RECORDED, version)
                self.assertEqual(release_notes.require_bundled_history(text), text)
        for version in ("1.5.7", "1.5.8", "1.6.0", "2.0.0"):
            with self.subTest(version=version), self.assertRaisesRegex(release_notes.NotesError, "Korean"):
                release_notes.require_bundled_history(self.changelog(LEGACY_RECORDED, version))
        for version in ("1.5.6", "1.5.7", "1.6.0"):
            with self.subTest(version=version):
                text = self.changelog(TRILINGUAL_RECORDED, version)
                self.assertEqual(release_notes.require_bundled_history(text), text)

    def test_recorded_new_notes_without_korean_fail_before_any_request(self):
        transport = Transport(model_reply(trilingual(fixed=[LAYERS])))
        text = self.changelog(LEGACY_RECORDED, "1.5.7")
        with self.assertRaisesRegex(release_notes.NotesError, "Korean"):
            release_notes.published_notes(
                "1.5.7", "v1.5.6", "missing-revision", REPOSITORY, text, "2026-09-29",
                ai=True, transport=transport, environ={})
        self.assertEqual(transport.requests, [])

    def test_recorded_trilingual_notes_are_reused_and_published_in_english(self):
        text = self.changelog(TRILINGUAL_RECORDED, "1.5.7", "v1.5.6")
        transport = Transport(model_reply(trilingual(fixed=[LAYERS])))
        notes, updated, generated = release_notes.published_notes(
            "1.5.7", "v1.5.6", "missing-revision", REPOSITORY, text, "2026-09-29",
            ai=True, transport=transport, environ={})
        self.assertEqual((notes, updated, generated), (TRILINGUAL_RECORDED, text, False))
        self.assertEqual(transport.requests, [])
        page = release_notes.release_body(notes, "1.5.7", compare=release_notes.recorded_link(text, "1.5.7"))
        page = page.split(release_notes.NOTES_END, 1)[0]
        self.assertIn("Layers stay in place.", page)
        self.assertIn("- Layers stay in place (closes [#41](https://github.com/owner/repo/issues/41)) ([abcdef1]", page)
        self.assertIn("**Full changelog**: https://github.com/owner/repo/compare/v1.5.6...v1.5.7", page)
        self.assertEqual(page.count("**Full changelog**:"), 1)
        self.assertNotIn("图层", page)
        self.assertNotIn("레이어", page)
        self.assertNotIn("### 한국어", page)

    def test_trilingual_notes_reject_invalid_language_blocks(self):
        blocks = release_notes.language_blocks(TRILINGUAL_RECORDED)
        malformed = (
            TRILINGUAL_RECORDED + "\n### 한국어\n\n중복됨\n",
            TRILINGUAL_RECORDED + "\n### Japanese\n\n翻訳\n",
            TRILINGUAL_RECORDED + "\n###Unknown\n",
            TRILINGUAL_RECORDED + "\n###\n",
            TRILINGUAL_RECORDED + "\n### \n",
            "### English" + blocks["english"] + "### 한국어" + blocks["korean"] + "### 简体中文" + blocks["chinese"],
            TRILINGUAL_RECORDED.replace("### 한국어", "### 수정됨"),
            TRILINGUAL_RECORDED.replace("레이어가 제자리에 유지됨.", "").replace("- 레이어가 제자리에 유지됨", ""),
            TRILINGUAL_RECORDED.replace("### 한국어" + blocks["korean"],
                                         "### 한국어\n\n![배경화면](Resources/ReleaseBanners/1.5.7.ko.jpg)\n"),
            TRILINGUAL_RECORDED.replace("- 레이어가 제자리에 유지됨", ""),
            TRILINGUAL_RECORDED.replace("레이어가 제자리에 유지됨", "Layers stay in place"),
        )
        for body in malformed:
            with self.subTest(body=body), self.assertRaises(release_notes.NotesError):
                release_notes.require_localized_notes(body, "1.5.7")

    def test_english_only_history_is_not_published(self):
        listed = "### Fixed\n\n- Something\n"
        with self.assertRaises(release_notes.NotesError):
            release_notes.published_notes(
                "0.2.0", "v0.1.0", "HEAD", REPOSITORY, self.changelog(listed), "2026-01-01", ai=True)
        with self.assertRaises(release_notes.NotesError):
            release_notes.published_notes(
                "0.2.0", "v0.1.0", "HEAD", REPOSITORY, release_notes.CHANGELOG_PREAMBLE, "2026-01-01", ai=False)
        with self.assertRaises(release_notes.NotesError):
            release_notes.require_localized_notes(listed, "0.2.0")

    def test_headings_and_links_cannot_stand_in_for_translated_notes(self):
        for body in (
            "### English\n#### Fixed\n### 简体中文\n#### 修复\n",
            "### English\n- Fixed a crash\n### 简体中文\n#### 修复\n**Full changelog**: https://example.com\n",
            "### English\n- Fixed a crash\n- Added a filter\n### 简体中文\n- 修复崩溃\n",
        ):
            with self.subTest(body=body), self.assertRaises(release_notes.NotesError):
                release_notes.require_localized_notes(body, "0.2.0")

    def test_a_banner_names_its_own_version(self):
        def with_banner(english, chinese):
            return self.changelog(LEGACY_RECORDED
                                  .replace("### English\n", f"### English\n\n![WallpaperMachine]({english})\n")
                                  .replace("### 简体中文\n", f"### 简体中文\n\n![WallpaperMachine]({chinese})\n"))
        stolen = with_banner("Resources/ReleaseBanners/0.2.0.jpg", "Resources/ReleaseBanners/0.1.0.zh-Hans.jpg")
        with self.assertRaisesRegex(release_notes.NotesError, "banner of 0.2.0"):
            release_notes.require_bundled_history(stolen)
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        root = Path(directory.name)
        banners = root / release_notes.BANNERS
        banners.mkdir(parents=True)
        (banners / "0.2.0.png").write_bytes(b"png")
        (banners / "0.2.0.zh-Hans.jpg").write_bytes(b"jpeg")
        release_notes.require_bundled_history(
            with_banner("Resources/ReleaseBanners/0.2.0.png", "Resources/ReleaseBanners/0.2.0.zh-Hans.jpg"), root=root)

    def test_a_banner_cannot_stand_in_for_a_translation(self):
        with self.assertRaises(release_notes.NotesError):
            release_notes.require_localized_notes(
                "### English\n\n- Fixed a crash\n\n### 简体中文\n\n![壁纸](Resources/ReleaseBanners/0.2.0.zh-Hans.jpg)\n", "0.2.0")

    def test_korean_banner_paths_must_exist_and_name_the_section_version(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        root = Path(directory.name)
        for path in ("Resources/ReleaseBanners/1.5.6.ko.jpg", "Resources/ReleaseBanners/1.5.7.ko.jpg", ""):
            body = TRILINGUAL_RECORDED.replace("### 한국어\n", f"### 한국어\n\n![배경화면]({path})\n")
            with self.subTest(path=path), self.assertRaises(release_notes.NotesError):
                release_notes.require_bundled_history(self.changelog(body, "1.5.7"), root=root)
        banners = root / release_notes.BANNERS
        banners.mkdir(parents=True)
        for suffix in (".ko.jpg", ".ko.png", ".jpg", ".png"):
            path = f"Resources/ReleaseBanners/1.5.7{suffix}"
            (root / path).write_bytes(b"image")
            body = TRILINGUAL_RECORDED.replace("### 한국어\n", f"### 한국어\n\n![배경화면]({path})\n")
            text = self.changelog(body, "1.5.7")
            self.assertEqual(release_notes.require_bundled_history(text, root=root), text)
            page = release_notes.release_body(body, "1.5.7", repo=REPOSITORY)
            self.assertNotIn("![", page, "The Korean banner must never appear in English release notes")

    def test_every_banner_the_changelog_names_is_committed(self):
        text = release_notes.CHANGELOG.read_text(encoding="utf-8")
        for match in release_notes.BANNER.finditer(text):
            self.assertTrue((release_notes.ROOT / match.group("path")).is_file(), match.group("path"))

    def test_missing_historical_translation_blocks_publication(self):
        text = release_notes.insert_section(
            self.changelog(LEGACY_RECORDED), "0.1.0",
            release_notes.section("0.1.0", "2026-01-01", "### English\n- Added a filter\n"))
        with self.assertRaises(release_notes.NotesError):
            release_notes.published_notes(
                "0.2.0", "v0.1.0", "HEAD", REPOSITORY, text, "2026-09-29", ai=True)

    def test_publish_rejects_headings_the_app_cannot_parse(self):
        unreleased = (
            "## Unreleased\n\n### English\n\nUpcoming work.\n\n### 简体中文\n\n即将发布。\n\n"
            + self.changelog(LEGACY_RECORDED)
        )
        internal = self.changelog(LEGACY_RECORDED) + (
            "## Also see\n\n### English\n\nSee the note.\n\n### 简体中文\n\n见这条说明。\n\n"
        )
        cases = (
            ("unreleased", unreleased, "Unreleased"),
            ("internal heading", internal, "Also see"),
            ("prerelease", "## 1.0.0-beta — 2026-01-01\n\n" + LEGACY_RECORDED, "1.0.0-beta"),
            ("leading zero", "## 01.2.0 — 2026-01-01\n\n" + LEGACY_RECORDED, "01.2.0"),
            ("integer overflow", "## 9223372036854775808.0.0\n\n" + LEGACY_RECORDED, "9223372036854775808"),
            ("tab before heading suffix", "## 0.2.0\t—\t2026-01-01\n\n" + LEGACY_RECORDED, "0.2.0"),
            ("duplicate version", self.changelog(LEGACY_RECORDED) + "\n## V0.2.0\n\n" + LEGACY_RECORDED, "0.2.0"),
            ("duplicate across forms", self.changelog(LEGACY_RECORDED) + "\n## 0.2.0 — 2026-01-01\n\n" + LEGACY_RECORDED,
             "0.2.0"),
            ("linked prerelease", "## [1.0.0-beta](https://example.com/c) (2026-01-01)\n\n" + LEGACY_RECORDED, "1.0.0-beta"),
            ("link without a target", "## [0.2.0] (2026-01-01)\n\n" + LEGACY_RECORDED, "[0.2.0]"),
        )
        for name, text, needle in cases:
            with self.subTest(heading=name):
                with self.assertRaises(release_notes.NotesError) as raised:
                    release_notes.published_notes(
                        "0.2.0", "v0.1.0", "HEAD", REPOSITORY, text, "2026-09-29", ai=True)
                self.assertIn(needle, str(raised.exception))

    def test_publish_reuses_prefixed_version_without_generating_a_duplicate(self):
        recorded = "## V0.2.0 — 2026-01-01\n\n" + LEGACY_RECORDED
        notes, bundled, generated = release_notes.published_notes(
            "0.2.0", "v0.1.0", "HEAD", REPOSITORY, recorded, "2026-09-29")
        self.assertEqual(notes.strip(), LEGACY_RECORDED.strip())
        self.assertEqual(bundled, recorded)
        self.assertFalse(generated)

    def test_rebuild_rejects_unreleased_instead_of_dropping_it(self):
        recorded = (
            "## Unreleased\n\n### English\n\nUpcoming work.\n\n### 简体中文\n\n即将发布。\n\n"
            + self.changelog(LEGACY_RECORDED)
        )
        with self.assertRaises(release_notes.NotesError) as raised:
            release_notes.rebuild_changelog(REPOSITORY, recorded=recorded)
        self.assertIn("Unreleased", str(raised.exception))

    def test_cli_release_body_reuses_the_section_and_its_heading_link(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        path = Path(directory.name) / "CHANGELOG.md"
        text = self.changelog(TRILINGUAL_RECORDED, "1.5.7", "v1.5.5")
        path.write_text(text, encoding="utf-8")
        output = Path(directory.name) / "notes.md"
        original = release_notes.CHANGELOG
        release_notes.CHANGELOG = path
        self.addCleanup(setattr, release_notes, "CHANGELOG", original)
        with contextlib.redirect_stdout(io.StringIO()):
            release_notes.main(["--tag", "1.5.7", "--previous", "v1.5.6", "--repository", REPOSITORY,
                                "--release-body", "--output", str(output)])
        notes = output.read_text(encoding="utf-8").split(release_notes.NOTES_END, 1)[0]
        self.assertTrue(notes.startswith("### English\n\nLayers stay in place.\n\n#### Bug Fixes\n\n- Layers stay in place (closes"))
        self.assertTrue(notes.rstrip().endswith("**Full changelog**: https://github.com/owner/repo/compare/v1.5.5...v1.5.7"),
                        "The recorded heading's link wins over the computed one")
        self.assertEqual(path.read_text(encoding="utf-8"), text)

    def test_cli_publish_paths_do_not_write_a_malformed_changelog(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        path = Path(directory.name) / "CHANGELOG.md"
        malformed = "## Unreleased\n\n### English\n\nUpcoming work.\n\n### 简体中文\n\n即将发布。\n\n"
        path.write_text(malformed, encoding="utf-8")
        original = release_notes.CHANGELOG
        release_notes.CHANGELOG = path
        try:
            for argv in (
                ["--rebuild-changelog", "--apply"],
                ["--tag", "0.2.0", "--changelog", "--apply"],
                ["--tag", "0.2.0", "--release-body"],
            ):
                with self.subTest(argv=argv):
                    with self.assertRaises(release_notes.NotesError) as raised:
                        release_notes.main(argv)
                    self.assertIn("Unreleased", str(raised.exception))
                    self.assertEqual(path.read_text(encoding="utf-8"), malformed)
        finally:
            release_notes.CHANGELOG = original


class RepositoryRangeTests(unittest.TestCase):
    """The parts that only a real history can answer."""

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        self.addCleanup(self.directory.cleanup)
        git("init", "-q", "-b", "main", cwd=self.root)
        git("config", "user.email", "test@example.com", cwd=self.root)
        git("config", "user.name", "Test", cwd=self.root)
        git("config", "commit.gpgsign", "false", cwd=self.root)
        commit(self.root, "feat(panel): first feature")
        git("tag", "v0.1.0", cwd=self.root)
        commit(self.root, "fix(scene): second fix")
        git("tag", "v0.2.0", cwd=self.root)
        commit(self.root, "feat(media): third feature")

    def test_tags_sort_by_version_not_by_string(self):
        git("tag", "v0.10.0", cwd=self.root)
        self.assertEqual(release_notes.version_tags(self.root)[-1], "v0.10.0")

    def test_previous_tag_is_the_newest_version_below_the_target(self):
        self.assertEqual(release_notes.previous_tag("0.3.0", "HEAD", self.root), "v0.2.0")

    def test_previous_tag_skips_a_gap_in_the_numbering(self):
        self.assertEqual(release_notes.previous_tag("0.9.0", "HEAD", self.root), "v0.2.0")

    def test_the_first_release_has_no_previous_tag(self):
        self.assertIsNone(release_notes.previous_tag("0.1.0", "v0.1.0", self.root))

    def test_a_range_carries_only_its_own_commits(self):
        collected = release_notes.changes("v0.1.0", "v0.2.0", self.root)
        self.assertEqual([change.subject for change in collected], ["Second fix"])

    def test_the_bump_commit_leaves_the_range_empty(self):
        commit(self.root, "chore: bump version to 0.3.0")
        collected = release_notes.changes("v0.2.0", "HEAD", self.root)
        self.assertEqual([change.subject for change in collected], ["Third feature"])

    def test_a_rebuilt_changelog_covers_every_tag_newest_first(self):
        text = release_notes.rebuild_changelog(REPOSITORY, self.root)
        self.assertIn("\n## [0.2.0](https://github.com/owner/repo/compare/v0.1.0...v0.2.0) (", text)
        self.assertIn("\n## [0.1.0](https://github.com/owner/repo/commits/v0.1.0) (", text)
        self.assertLess(text.index("## [0.2.0]"), text.index("## [0.1.0]"))
        self.assertIn("#### Features\n\n- **panel** — First feature ([", text)
        self.assertIn("#### Bug Fixes\n\n- **scene** — Second fix ([", text)

    def test_a_rebuild_keeps_what_was_recorded_and_lists_only_the_rest(self):
        recorded = release_notes.insert_section(
            release_notes.CHANGELOG_PREAMBLE, "0.2.0", release_notes.section("0.2.0", "2026-01-01", "Written by the model.\n"))
        text = release_notes.rebuild_changelog(REPOSITORY, self.root, recorded)
        self.assertIn(release_notes.heading("0.2.0", "2026-01-01") + "\n\nWritten by the model.\n\n## [0.1.0]", text)
        self.assertNotIn("Second fix", text)
        self.assertIn("First feature", text)


def authored(address, sha="f" * 40, body=""):
    """A commit of the range written from `address`."""
    return release_notes.Commit(sha, sha[:7], "feat(panel): something", body, address)


class ThanksTests(unittest.TestCase):
    """Who a release thanks, and the line every language block ends with."""

    def thanked(self, *entries, lookup=None):
        return release_notes.outside_contributors(entries, REPOSITORY, {}, lookup)

    def test_outside_authors_are_thanked_by_login_oldest_first(self):
        newest_first = (
            authored("7+Second@users.noreply.github.com"),
            authored("first@users.noreply.github.com"),
            authored("12+second@users.noreply.github.com"),
        )
        self.assertEqual(self.thanked(*newest_first), ("second", "first"),
                         "One credit per login, in the order of its first commit")

    def test_maintainers_agents_and_bots_are_not_thanked(self):
        self.assertEqual(self.thanked(
            authored("1+bobbyhuang-dev@users.noreply.github.com"),
            authored("100508620+fzlzjerry@users.noreply.github.com"),
            authored("t3code@users.noreply.github.com"),
            authored("41898282+github-actions[bot]@users.noreply.github.com"),
            authored("noreply@anthropic.com", body="Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"),
        ), ())

    def test_a_co_author_is_thanked_by_a_noreply_address_only(self):
        body = ("Co-authored-by: Helper <9+helper@users.noreply.github.com>\n"
                "Co-authored-by: Someone <someone@example.com>\n")
        self.assertEqual(self.thanked(authored("1+bobbyhuang-dev@users.noreply.github.com", body=body)), ("helper",))

    def test_any_other_address_needs_githubs_record_of_the_commit(self):
        self.assertEqual(self.thanked(authored("person@example.com")), (),
                         "Without a token nobody is asked and an address alone credits no one")
        asked = []

        def lookup(sha):
            asked.append(sha)
            return {"a" * 40: ("Person", "User"), "b" * 40: ("Maker[bot]", "Bot"), "c" * 40: ("bobbyhuang-dev", "User")}.get(sha)

        self.assertEqual(self.thanked(
            authored("person@example.com", "d" * 40), authored("PERSON@example.com", "a" * 40),
            authored("maker@example.com", "b" * 40), authored("bobby@example.com", "c" * 40),
            authored("unknown@example.com", "e" * 40), lookup=lookup), ("Person",))
        self.assertEqual(sorted(asked), ["a" * 40, "b" * 40, "c" * 40, "e" * 40],
                         "Asked once per address; GitHub's answer for the oldest commit stands for the rest")

    def test_every_language_thanks_the_same_logins(self):
        names = ("[@one](https://github.com/one)", "[@two](https://github.com/two)", "[@three](https://github.com/three)")
        self.assertEqual(release_notes.thanks_line("english", ("one",)),
                         f"Thanks to {names[0]} for contributing to this release.")
        self.assertEqual(release_notes.thanks_line("english", ("one", "two", "three")),
                         f"Thanks to {names[0]}, {names[1]} and {names[2]} for contributing to this release.")
        self.assertEqual(release_notes.thanks_line("chinese", ("one", "two")), f"感谢 {names[0]} 和 {names[1]} 为本版本做出的贡献。")
        self.assertEqual(release_notes.thanks_line("korean", ("one", "two")),
                         f"이번 릴리스에 기여해 주신 {names[0]}, {names[1]} 님께 감사드립니다.")
        self.assertIsNone(release_notes.thanks_line("english", ()))


class GitHubCommits(http.server.BaseHTTPRequestHandler):
    """A local stand-in for GitHub's commit API: `replies` maps a path to `(status, body)`."""

    replies = {}
    requests = []

    def do_GET(self):
        GitHubCommits.requests.append((self.path, {name.lower(): value for name, value in self.headers.items()}))
        status, payload = GitHubCommits.replies.get(self.path, (404, {"message": "Not Found"}))
        data = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


class GitHubAuthorTests(unittest.TestCase):
    """The request that names a commit's author when its address is not a noreply one."""

    def setUp(self):
        GitHubCommits.replies, GitHubCommits.requests = {}, []
        urllib.request.install_opener(urllib.request.build_opener(urllib.request.ProxyHandler({})))
        self.addCleanup(urllib.request.install_opener, None)
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), GitHubCommits)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        original = release_notes.GITHUB_API
        release_notes.GITHUB_API = f"http://127.0.0.1:{server.server_address[1]}"
        self.addCleanup(setattr, release_notes, "GITHUB_API", original)

    def test_the_token_asks_github_who_wrote_the_commit(self):
        sha = "a" * 40
        GitHubCommits.replies[f"/repos/{REPOSITORY}/commits/{sha}"] = (200, {"author": {"login": "person", "type": "User"}})
        thanked = release_notes.outside_contributors(
            [authored("person@example.com", sha)], REPOSITORY, {release_notes.GITHUB_TOKEN_VARIABLE: "token"})
        self.assertEqual(thanked, ("person",))
        self.assertEqual(GitHubCommits.requests[0][1]["authorization"], "Bearer token")

    def test_an_unknown_commit_or_unlinked_address_credits_nobody(self):
        sha = "b" * 40
        GitHubCommits.replies[f"/repos/{REPOSITORY}/commits/{sha}"] = (200, {"author": None})
        self.assertIsNone(release_notes.github_author(REPOSITORY, sha, "token"))
        self.assertIsNone(release_notes.github_author(REPOSITORY, "c" * 40, "token"), "A commit GitHub does not know")

    def test_any_other_refusal_stops_the_run(self):
        sha = "d" * 40
        GitHubCommits.replies[f"/repos/{REPOSITORY}/commits/{sha}"] = (401, {"message": "Bad credentials"})
        with self.assertRaisesRegex(release_notes.NotesError, "HTTP 401"):
            release_notes.github_author(REPOSITORY, sha, "token")


class ThanksRangeTests(unittest.TestCase):
    """The thanks line in written notes, over a real history with an outside commit."""

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        self.addCleanup(self.directory.cleanup)
        git("init", "-q", "-b", "main", cwd=self.root)
        git("config", "user.email", "1+bobbyhuang-dev@users.noreply.github.com", cwd=self.root)
        git("config", "user.name", "Maintainer", cwd=self.root)
        git("config", "commit.gpgsign", "false", cwd=self.root)
        commit(self.root, "feat(panel): first feature")
        git("tag", "v0.1.0", cwd=self.root)
        (self.root / "pt-BR.txt").write_text("olá", encoding="utf-8")
        git("add", "-A", cwd=self.root)
        git("commit", "-q", "-m", "feat(localization): add Brazilian Portuguese",
            "--author", "Contributor <5+contributor@users.noreply.github.com>", cwd=self.root)
        self.short = release_notes.git("log", "-1", "--format=%h", "HEAD", cwd=self.root).strip()
        commit(self.root, "fix(scene): keep layers in place")
        commit(self.root, "chore: bump version to 0.2.0")

    def test_every_language_block_of_the_model_notes_ends_with_the_thanks(self):
        reply = Transport(model_reply(trilingual(commits=(self.short,), new=[LAYERS])))
        body = release_notes.write_with_model("0.2.0", "v0.1.0", "HEAD", REPOSITORY, self.root, reply, KEY)
        blocks = release_notes.language_blocks(body)
        mention = "[@contributor](https://github.com/contributor)"
        self.assertTrue(blocks["english"].rstrip().endswith(f"Thanks to {mention} for contributing to this release."))
        self.assertTrue(blocks["chinese"].rstrip().endswith(f"感谢 {mention} 为本版本做出的贡献。"))
        self.assertTrue(blocks["korean"].rstrip().endswith(f"이번 릴리스에 기여해 주신 {mention} 님께 감사드립니다."))
        self.assertNotIn("contributor", reply.requests[0][2]["messages"][0]["content"].lower(),
                         "The script writes the thanks; the model is not asked to")
        release_notes.require_localized_notes(body, "0.2.0")
        page = release_notes.release_body(body, "0.2.0", repo=REPOSITORY)
        self.assertIn(f"Thanks to {mention}", page)
        self.assertNotIn("感谢", page)

    def test_the_listing_thanks_them_too(self):
        body = release_notes.notes_for("0.2.0", "v0.1.0", "HEAD", REPOSITORY, cwd=self.root, environ={})
        self.assertTrue(body.rstrip().endswith("Thanks to [@contributor](https://github.com/contributor) "
                                               "for contributing to this release."))

    def test_a_range_of_maintainer_commits_thanks_nobody(self):
        body = release_notes.notes_for("0.2.0", "HEAD~2", "HEAD", REPOSITORY, cwd=self.root, environ={})
        self.assertNotIn("Thanks", body)


if __name__ == "__main__":
    unittest.main()
