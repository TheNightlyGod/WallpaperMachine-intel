#!/usr/bin/env python3
"""Unit tests for scripts/update_sponsors.py."""
from __future__ import annotations

import contextlib
import http.server
import importlib.util
import io
import json
import sys
import tempfile
import threading
import unittest
from pathlib import Path
from unittest import mock

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
SPEC = importlib.util.spec_from_file_location("update_sponsors", SCRIPTS / "update_sponsors.py")
update_sponsors = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(update_sponsors)

Wall = update_sponsors.Wall

README = f"""# Title

## Thank you. To every Priority Support member.

Intro.

{update_sponsors.START}
No one is on the list yet.
{update_sponsors.END}

## License
"""


class ParseWallTests(unittest.TestCase):
    def test_reads_names_in_order_the_private_count_and_the_version(self):
        wall = update_sponsors.parse_wall(
            {
                "supporters": [{"name": "Alice", "since": "2026-09"}, {"name": "张三", "since": None}],
                "hidden": 2,
                "version": "6b298c179c3a",
            }
        )
        self.assertEqual(wall, Wall(("Alice", "张三"), 2, "6b298c179c3a"))

    def test_collapses_whitespace_and_drops_invisible_characters(self):
        wall = update_sponsors.parse_wall(
            {"supporters": [{"name": "  A\u200bl\u202eice \n\t Smith "}, {"name": "\u200b "}], "hidden": 0}
        )
        self.assertEqual(wall.names, ("Alice Smith",))

    def test_a_wall_without_a_version_gets_one_from_what_it_shows(self):
        wall = update_sponsors.parse_wall({"supporters": [{"name": "Alice"}], "hidden": 1})
        self.assertRegex(wall.version, r"^[0-9a-f]{12}$")
        same = update_sponsors.parse_wall({"supporters": [{"name": "Alice"}], "hidden": 1})
        other = update_sponsors.parse_wall({"supporters": [{"name": "Alice"}], "hidden": 2})
        self.assertEqual(same.version, wall.version)
        self.assertNotEqual(other.version, wall.version)

    def test_rejects_answers_that_are_not_the_wall(self):
        for payload in (
            [],
            {"hidden": 0},
            {"supporters": {}, "hidden": 0},
            {"supporters": [], "hidden": -1},
            {"supporters": [], "hidden": True},
            {"supporters": [], "hidden": "1"},
            {"supporters": [{"name": 3}], "hidden": 0},
            {"supporters": ["Alice"], "hidden": 0},
            {"supporters": [], "hidden": 0, "version": 7},
            {"supporters": [], "hidden": 0, "version": ""},
            {"supporters": [], "hidden": 0, "version": "abc&x=<y>"},
        ):
            with self.subTest(payload=payload), self.assertRaises(ValueError):
                update_sponsors.parse_wall(payload)


class RenderTests(unittest.TestCase):
    def test_the_picture_of_the_wall_links_to_the_wall(self):
        block = update_sponsors.render(Wall(("Alice",), 0, "abc123"))
        self.assertIn('src="https://www.wallpapermachine.app/sponsors/wall?v=abc123"', block)
        self.assertIn('href="https://www.wallpapermachine.app/#sponsors"', block)

    def test_the_picture_comes_from_the_site_the_list_came_from(self):
        block = update_sponsors.render(Wall((), 0, "v1"), "http://localhost:8787/api/sponsors")
        self.assertIn('src="http://localhost:8787/sponsors/wall?v=v1"', block)

    def test_every_listed_name_and_the_count_are_in_the_alt_text(self):
        block = update_sponsors.render(Wall(("Alice", "Bob"), 1, "v1"))
        self.assertIn(
            'alt="WallpaperMachine Priority Support members: Alice, Bob. 2 Priority Support members on the wall.'
            ' 1 more stays private."',
            block,
        )

    def test_counts_are_worded_as_the_website_words_them(self):
        count = update_sponsors.count_line
        self.assertEqual(count(Wall(("Alice",), 0, "v")), "1 Priority Support member on the wall.")
        self.assertEqual(
            count(Wall(("Alice",), 2, "v")), "1 Priority Support member on the wall. 2 more stay private."
        )
        self.assertEqual(count(Wall((), 3, "v")), "3 Priority Support members so far, all private.")
        self.assertEqual(count(Wall((), 0, "v")), "No one is on the wall yet.")

    def test_private_members_are_counted_not_named(self):
        block = update_sponsors.render(Wall((), 3, "v1"))
        self.assertIn('alt="WallpaperMachine Priority Support members. 3 Priority Support members so far, all private."', block)

    def test_a_name_can_never_become_markup(self):
        hostile = f'" onerror="x [x](https://evil) <img src=x> ![i](y) *b* `c` {update_sponsors.END}'
        block = update_sponsors.render(Wall((hostile,), 0, "v1"))
        alt = block.splitlines()[2].split('alt="', 1)[1]
        # The name stays inside the alt attribute: nothing in it closes the quote,
        # opens a tag or reads as Markdown.
        self.assertEqual(alt.count('"'), 1)
        self.assertTrue(alt.endswith('"></a>'))
        for text in ("<", ">", "[", "]", "(", ")", "*", "`", "!"):
            self.assertNotIn(text, alt[: -len('"></a>')])
        # The markers still delimit exactly one block, so the next run finds it.
        self.assertEqual(block.count(update_sponsors.END), 1)
        self.assertEqual(update_sponsors.BLOCK.fullmatch(block).group(), block)
        once = update_sponsors.rewrite(README, Wall((hostile,), 0, "v1"))
        self.assertEqual(update_sponsors.rewrite(once, Wall((), 0, "v0")), update_sponsors.rewrite(README, Wall((), 0, "v0")))


class RewriteTests(unittest.TestCase):
    def test_replaces_only_the_block(self):
        after = update_sponsors.rewrite(README, Wall(("Alice",), 0, "v1"))
        self.assertIn("Alice", after)
        self.assertNotIn("No one is on the list yet.", after)
        before_block, after_block = README.split(update_sponsors.START)[0], README.split(update_sponsors.END)[1]
        self.assertTrue(after.startswith(before_block))
        self.assertTrue(after.endswith(after_block))

    def test_is_idempotent(self):
        wall = Wall(("Alice", "Bob"), 2, "v1")
        once = update_sponsors.rewrite(README, wall)
        self.assertEqual(update_sponsors.rewrite(once, wall), once)
        self.assertNotEqual(update_sponsors.rewrite(once, Wall(("Alice", "Bob"), 2, "v2")), once)

    def test_refuses_a_readme_without_exactly_one_block(self):
        for text in ("# Title\n", README + README):
            with self.subTest(blocks=text.count("supporters:start")), self.assertRaises(ValueError):
                update_sponsors.rewrite(text, Wall((), 0, "v0"))

    def test_every_repository_readme_has_the_block(self):
        for readme in update_sponsors.READMES:
            with self.subTest(readme=readme.name):
                update_sponsors.rewrite(readme.read_text(encoding="utf-8"), Wall((), 0, "v0"))


class MainTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.wall = self.root / "wall.json"
        self.wall.write_text(json.dumps({"supporters": [{"name": "Alice"}], "hidden": 0, "version": "v1"}), encoding="utf-8")

    def readme(self, name, text=README):
        path = self.root / name
        path.write_text(text, encoding="utf-8")
        return path

    def main(self, readmes, *args):
        argv = ["update_sponsors.py", "--input", str(self.wall), *args]
        with mock.patch.object(update_sponsors, "READMES", tuple(readmes)), mock.patch.object(sys, "argv", argv), \
                contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            return update_sponsors.main()

    def test_rewrites_every_readme(self):
        readmes = [self.readme("README.md"), self.readme("README.zh-CN.md"), self.readme("README.pt-BR.md"),
                   self.readme("README.ko.md")]
        self.assertEqual(self.main(readmes), 0)
        for readme in readmes:
            self.assertIn("Alice", readme.read_text(encoding="utf-8"))
        self.assertEqual(self.main(readmes, "--check"), 0)

    def test_a_readme_without_the_block_leaves_every_readme_as_it_was(self):
        english, chinese = self.readme("README.md"), self.readme("README.zh-CN.md", "# 标题\n")
        self.assertEqual(self.main([english, chinese]), 1)
        self.assertEqual(english.read_text(encoding="utf-8"), README)

    def test_check_reports_a_stale_readme_without_writing_it(self):
        english = self.readme("README.md")
        self.assertEqual(self.main([english], "--check"), 1)
        self.assertEqual(english.read_text(encoding="utf-8"), README)


class FetchTests(unittest.TestCase):
    def serve(self, status, body):
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *args):
                pass

        server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        return f"http://127.0.0.1:{server.server_port}/api/sponsors"

    def test_reads_the_wall(self):
        url = self.serve(200, json.dumps({"supporters": [{"name": "Alice"}], "hidden": 1, "version": "abc"}).encode())
        self.assertEqual(update_sponsors.fetch_wall(url), Wall(("Alice",), 1, "abc"))

    def test_a_page_that_is_not_json_is_an_error(self):
        url = self.serve(200, b"<!doctype html><title>Just a moment...</title>")
        with self.assertRaises(ValueError):
            update_sponsors.fetch_wall(url)

    def test_an_error_status_is_an_error(self):
        url = self.serve(500, b'{"error":"server_error"}')
        with self.assertRaises(update_sponsors.urllib.error.HTTPError):
            update_sponsors.fetch_wall(url)


if __name__ == "__main__":
    unittest.main()
