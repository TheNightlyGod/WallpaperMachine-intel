#!/usr/bin/env python3
"""Unit tests for scripts/release_notes.py."""
from __future__ import annotations

import http.server
import importlib.util
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
        self.assertLess(body.index("### New"), body.index("### Fixed"))
        self.assertIn("- **panel** — Add a filter rail ([`aaa1111`](https://github.com/owner/repo/commit/aaa1111))", body)
        self.assertIn("https://github.com/owner/repo/compare/v0.5.0...v0.6.0", body)

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
        self.assertIn("https://github.com/owner/repo/commits/v0.1.0", body)

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
        self.assertLess(text.index("## 0.6.0"), text.index("## 0.5.0"))

    def test_an_older_version_lands_below_a_newer_one(self):
        text = release_notes.insert_section(release_notes.CHANGELOG_PREAMBLE, "0.6.0", self.section("0.6.0"))
        text = release_notes.insert_section(text, "0.5.0", self.section("0.5.0"))
        self.assertLess(text.index("## 0.6.0"), text.index("## 0.5.0"))

    def test_rerunning_replaces_rather_than_duplicates(self):
        text = release_notes.insert_section(release_notes.CHANGELOG_PREAMBLE, "0.6.0", self.section("0.6.0"))
        text = release_notes.insert_section(text, "0.6.0", self.section("0.6.0", "### New\n\n- Rewritten\n"))
        self.assertEqual(text.count("## 0.6.0"), 1)
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


def pair(english, chinese):
    return {"english": english, "chinese": chinese}


def bilingual(**sections):
    """A model reply in the required shape. Omitted sections are empty."""
    notes = {"summary": sections.pop("summary", pair("", ""))}
    for key, _heading in release_notes.MODEL_SECTIONS:
        notes[key] = sections.pop(key, [])
    if sections:
        raise AssertionError(f"unknown sections {sorted(sections)}")
    return json.dumps(notes)


LAYERS = pair("Layers stay in place", "图层保持原位")
WAKE = pair("A crash on wake", "唤醒时不再崩溃")


class ModelReplyTests(unittest.TestCase):
    def notes(self, reply):
        return release_notes.render_model_notes("0.6.0", release_notes.parse_notes(release_notes.streamed_text(reply)),
                                                "v0.5.0", REPOSITORY)

    def test_both_languages_keep_the_same_changes_in_order(self):
        body = self.notes(model_reply(bilingual(
            summary=pair("Music wallpapers work again.", "音乐壁纸恢复正常。"),
            fixed=[pair("Album covers show again.", "专辑封面重新显示")],
            new=[pair("- Choose how many downloads run at once", "可以选择同时进行的下载数量")],
            breaking=[pair("Old presets are no longer read", "不再读取旧的预设")],
        )))
        english, chinese = body.split("### 简体中文", 1)
        self.assertTrue(english.startswith("### English\n\nMusic wallpapers work again\n"))
        self.assertLess(english.index("#### Breaking changes"), english.index("#### New"))
        self.assertLess(english.index("#### New"), english.index("#### Fixed"))
        self.assertNotIn("#### Improved", body)
        self.assertIn("- Choose how many downloads run at once\n", english)
        self.assertIn("- Album covers show again\n", english)
        self.assertLess(chinese.index("#### 不兼容变更"), chinese.index("#### 新增"))
        self.assertLess(chinese.index("#### 新增"), chinese.index("#### 修复"))
        self.assertIn("- 可以选择同时进行的下载数量\n", chinese)
        self.assertIn("- 专辑封面重新显示\n", chinese)
        self.assertLess(body.index("### 简体中文"), body.index("https://github.com/owner/repo/compare/v0.5.0...v0.6.0"))
        release_notes.require_bilingual(body)

    def test_a_reply_in_a_code_fence_is_still_read(self):
        body = self.notes(model_reply("```json\n" + bilingual(fixed=[WAKE]) + "\n```"))
        self.assertIn("### English\n\n#### Fixed\n\n- A crash on wake\n", body)
        self.assertIn("### 简体中文\n\n#### 修复\n\n- 唤醒时不再崩溃\n", body)

    def test_notes_with_nothing_in_them_say_so_in_both_languages(self):
        body = self.notes(model_reply(bilingual(fixed=[pair(" ", " ")])))
        self.assertIn("### English\n\nNo user-visible changes since `v0.5.0`.", body)
        self.assertIn("### 简体中文\n\n自 `v0.5.0` 以来没有用户能察觉的变化。", body)
        self.assertLess(body.index("### 简体中文"), body.index("https://github.com/owner/repo/compare/v0.5.0...v0.6.0"))

    def test_a_multi_line_entry_cannot_open_a_changelog_section(self):
        body = self.notes(model_reply(bilingual(
            summary=pair("## 9.9.9\nSurprise", "意外的摘要不会另起一节"),
            fixed=[pair("One\n## 9.9.9 heading", "一行里的标题不会另起一节")],
        )))
        self.assertEqual(len(release_notes.split_sections("# Changelog\n\n## 0.6.0 — day\n\n" + body)[1]), 1)

    def test_the_release_notes_boundary_is_refused(self):
        with self.assertRaises(release_notes.NotesError):
            self.notes(model_reply(bilingual(fixed=[pair("Fixed <!-- release-notes-end --> early", "提前结束")])))

    def test_a_missing_language_stops_the_run(self):
        for reply in (
            json.dumps({"summary": "Music wallpapers work again.", "fixed": ["Album covers show again."]}),
            bilingual(fixed=[{"english": "Album covers show again"}]),
            bilingual(summary=pair("Music wallpapers work again.", "")),
            bilingual(fixed=[pair("Album covers show again.", "Album covers show again.")]),
            bilingual(fixed=[pair("Album covers show again.", "OK")]),
            bilingual(fixed=[pair("专辑封面", "专辑封面重新显示")]),
        ):
            with self.assertRaises(release_notes.NotesError):
                self.notes(model_reply(reply))

    def test_a_reply_that_is_not_json_stops_the_run(self):
        with self.assertRaises(release_notes.NotesError):
            self.notes(model_reply("### English\n\n- Something"))

    def test_unexpected_fields_stop_the_run(self):
        with self.assertRaises(release_notes.NotesError):
            self.notes(model_reply(json.dumps({"summary": pair("", ""), "security": [WAKE]})))

    def test_a_reply_cut_off_at_the_token_limit_stops_the_run(self):
        with self.assertRaises(release_notes.NotesError):
            release_notes.streamed_text(model_reply(bilingual(fixed=[WAKE]), stop="max_tokens"))

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
        commit(self.root, "fix(scene): keep layers in place\n\nParallax no longer pushes the planet out of frame.")
        commit(self.root, "docs(testing): record a run\n\nInternal verification notes nobody should read.")
        commit(self.root, "chore: bump version to 0.2.0")
        self.reply = Transport(model_reply(bilingual(fixed=[LAYERS])))

    def write(self, previous="v0.1.0", environ=KEY):
        return release_notes.write_with_model("0.2.0", previous, "HEAD", REPOSITORY, self.root, self.reply, environ)

    def test_the_model_reads_user_visible_bodies_and_writes_both_languages(self):
        body = self.write()
        self.assertIn("### English\n\n#### Fixed\n\n- Layers stay in place\n", body)
        self.assertIn("### 简体中文\n\n#### 修复\n\n- 图层保持原位\n", body)
        self.assertIn("简体中文", self.reply.requests[0][2]["system"])
        url, key, payload = self.reply.requests[0]
        prompt = payload["messages"][0]["content"]
        self.assertEqual((url, key, payload["model"], payload["stream"]),
                         ("https://sub2api.moraxcheng.me/v1/messages", "test-key", release_notes.MODEL, True))
        self.assertIn("2 commits since v0.1.0", prompt)
        self.assertIn("Parallax no longer pushes the planet out of frame.", prompt)
        self.assertIn("docs(testing): record a run", prompt)
        self.assertNotIn("Internal verification notes", prompt)
        self.assertNotIn("bump version", prompt)

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
        body = release_notes.write_with_model("0.3.0", "v0.2.0", "HEAD", REPOSITORY, self.root, self.reply, KEY)
        self.assertIn("### English\n\nNo user-visible changes since `v0.2.0`.", body)
        self.assertIn("### 简体中文\n\n自 `v0.2.0` 以来没有用户能察觉的变化。", body)
        self.assertEqual(self.reply.requests, [])

    def test_a_missing_key_stops_before_any_request(self):
        with self.assertRaisesRegex(release_notes.NotesError, "RELEASE_NOTES_API_KEY"):
            self.write(environ={})
        self.assertEqual(self.reply.requests, [])

    def test_the_release_page_keeps_only_english_notes_and_links_without_raw_commit_messages(self):
        original = self.write()
        body = release_notes.release_body(original, "0.2.0", "abc1234")
        notes, page = body.split(release_notes.NOTES_END)
        self.assertIn("### English\n\n#### Fixed\n\n- Layers stay in place", notes)
        self.assertNotIn("### 简体中文", notes)
        self.assertNotIn("图层保持原位", notes)
        self.assertIn(f"https://github.com/{REPOSITORY}/compare/v0.1.0...v0.2.0", notes)
        self.assertIn(release_notes.dmg.image_name("0.2.0"), page)
        self.assertIn("abc1234", page)
        self.assertNotIn("docs(testing): record a run", body)
        self.assertNotIn("fix(scene): keep layers in place", body)
        self.assertNotIn("<details>", body)



RECORDED = """\
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


class PublishTests(unittest.TestCase):
    """Bilingual source notes are stored once; GitHub shows only their English part."""

    def changelog(self, body, version="0.2.0"):
        return release_notes.insert_section(
            release_notes.CHANGELOG_PREAMBLE, version, release_notes.section(version, "2026-01-01", body))

    def test_recorded_bilingual_notes_are_reused_exactly(self):
        text = self.changelog(RECORDED)
        transport = Transport(model_reply(bilingual(fixed=[LAYERS])))
        notes, updated, generated = release_notes.published_notes(
            "0.2.0", "v0.1.0", "HEAD", REPOSITORY, text, "2026-09-29", ai=True, transport=transport)
        self.assertFalse(generated)
        self.assertEqual(updated, text)
        self.assertEqual(notes, release_notes.recorded_notes(text, "0.2.0"))
        self.assertEqual(transport.requests, [])
        page = release_notes.release_body(notes, "0.2.0")
        self.assertIn("Layers stay in place.", page)
        self.assertNotIn("图层保持原位", page)

    def test_generated_bilingual_notes_are_stored_once_and_published_in_english(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        root = Path(directory.name)
        git("init", "-q", "-b", "main", cwd=root)
        git("config", "user.email", "test@example.com", cwd=root)
        git("config", "user.name", "Test", cwd=root)
        git("config", "commit.gpgsign", "false", cwd=root)
        commit(root, "fix(scene): keep layers in place")
        transport = Transport(model_reply(bilingual(fixed=[LAYERS])))
        notes, updated, generated = release_notes.published_notes(
            "0.2.0", None, "HEAD", REPOSITORY, release_notes.CHANGELOG_PREAMBLE, "2026-01-01",
            ai=True, cwd=root, transport=transport, environ=KEY)
        self.assertTrue(generated)
        self.assertEqual(len(transport.requests), 1)
        self.assertEqual(notes, release_notes.recorded_notes(updated, "0.2.0"))
        self.assertIn("### English", notes)
        self.assertIn("### 简体中文", notes)
        self.assertIn("- Layers stay in place", notes)
        self.assertIn("- 图层保持原位", notes)
        page = release_notes.release_body(notes, "0.2.0")
        self.assertIn("- Layers stay in place", page.split(release_notes.NOTES_END, 1)[0])
        self.assertNotIn("图层保持原位", page)

    def test_english_only_history_is_not_published(self):
        listed = "### Fixed\n\n- Something\n"
        with self.assertRaises(release_notes.NotesError):
            release_notes.published_notes(
                "0.2.0", "v0.1.0", "HEAD", REPOSITORY, self.changelog(listed), "2026-01-01", ai=True)
        with self.assertRaises(release_notes.NotesError):
            release_notes.published_notes(
                "0.2.0", "v0.1.0", "HEAD", REPOSITORY, release_notes.CHANGELOG_PREAMBLE, "2026-01-01", ai=False)
        with self.assertRaises(release_notes.NotesError):
            release_notes.require_bilingual(listed)

    def test_headings_and_links_cannot_stand_in_for_translated_notes(self):
        for body in (
            "### English\n#### Fixed\n### 简体中文\n#### 修复\n",
            "### English\n- Fixed a crash\n### 简体中文\n#### 修复\n**Full changelog**: https://example.com\n",
            "### English\n- Fixed a crash\n- Added a filter\n### 简体中文\n- 修复崩溃\n",
        ):
            with self.subTest(body=body), self.assertRaises(release_notes.NotesError):
                release_notes.require_bilingual(body)

    def test_missing_historical_translation_blocks_publication(self):
        text = release_notes.insert_section(
            self.changelog(RECORDED), "0.1.0",
            release_notes.section("0.1.0", "2026-01-01", "### English\n- Added a filter\n"))
        with self.assertRaises(release_notes.NotesError):
            release_notes.published_notes(
                "0.2.0", "v0.1.0", "HEAD", REPOSITORY, text, "2026-09-29", ai=True)

    def test_publish_rejects_headings_the_app_cannot_parse(self):
        unreleased = (
            "## Unreleased\n\n### English\n\nUpcoming work.\n\n### 简体中文\n\n即将发布。\n\n"
            + self.changelog(RECORDED)
        )
        internal = self.changelog(RECORDED) + (
            "## Also see\n\n### English\n\nSee the note.\n\n### 简体中文\n\n见这条说明。\n\n"
        )
        cases = (
            ("unreleased", unreleased, "Unreleased"),
            ("internal heading", internal, "Also see"),
            ("prerelease", "## 1.0.0-beta — 2026-01-01\n\n" + RECORDED, "1.0.0-beta"),
            ("leading zero", "## 01.2.0 — 2026-01-01\n\n" + RECORDED, "01.2.0"),
            ("integer overflow", "## 9223372036854775808.0.0\n\n" + RECORDED, "9223372036854775808"),
            ("tab before heading suffix", "## 0.2.0\t—\t2026-01-01\n\n" + RECORDED, "0.2.0"),
            ("duplicate version", self.changelog(RECORDED) + "\n## V0.2.0\n\n" + RECORDED, "0.2.0"),
        )
        for name, text, needle in cases:
            with self.subTest(heading=name):
                with self.assertRaises(release_notes.NotesError) as raised:
                    release_notes.published_notes(
                        "0.2.0", "v0.1.0", "HEAD", REPOSITORY, text, "2026-09-29", ai=True)
                self.assertIn(needle, str(raised.exception))

    def test_publish_reuses_prefixed_version_without_generating_a_duplicate(self):
        recorded = "## V0.2.0 — 2026-01-01\n\n" + RECORDED
        notes, bundled, generated = release_notes.published_notes(
            "0.2.0", "v0.1.0", "HEAD", REPOSITORY, recorded, "2026-09-29")
        self.assertEqual(notes.strip(), RECORDED.strip())
        self.assertEqual(bundled, recorded)
        self.assertFalse(generated)

    def test_rebuild_rejects_unreleased_instead_of_dropping_it(self):
        recorded = (
            "## Unreleased\n\n### English\n\nUpcoming work.\n\n### 简体中文\n\n即将发布。\n\n"
            + self.changelog(RECORDED)
        )
        with self.assertRaises(release_notes.NotesError) as raised:
            release_notes.rebuild_changelog(REPOSITORY, recorded=recorded)
        self.assertIn("Unreleased", str(raised.exception))

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
        self.assertLess(text.index("## 0.2.0"), text.index("## 0.1.0"))
        self.assertIn("First feature", text)
        self.assertIn("Second fix", text)

    def test_a_rebuild_keeps_what_was_recorded_and_lists_only_the_rest(self):
        recorded = release_notes.insert_section(
            release_notes.CHANGELOG_PREAMBLE, "0.2.0", release_notes.section("0.2.0", "2026-01-01", "Written by the model.\n"))
        text = release_notes.rebuild_changelog(REPOSITORY, self.root, recorded)
        self.assertIn("## 0.2.0 — 2026-01-01\n\nWritten by the model.\n\n## 0.1.0", text)
        self.assertNotIn("Second fix", text)
        self.assertIn("First feature", text)


if __name__ == "__main__":
    unittest.main()
