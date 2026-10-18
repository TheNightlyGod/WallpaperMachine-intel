"""Guard SwiftUI's lazy containers against rows that go stale when they change section, without Xcode.

A `LazyVStack`, `LazyHStack`, `LazyVGrid`, `LazyHGrid` or `List` that draws one collection through
several sibling `ForEach`es (running jobs, then paused ones, then finished ones) breaks when an
item moves from one `ForEach` to another under the same id: the lazy container keeps the row it
drew before and the new state shows only once the view is rebuilt, as the Downloads popover did
with a resumed download. Such a container draws one `ForEach` over a single ordered list whose ids
are stable (a `ForEach` nested inside another one's rows is fine). This scans the Swift sources
for lazy containers with more than one top-level `ForEach`. See docs/conventions.md.
"""
from pathlib import Path
import re
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_localization_catalogs import ROOT  # noqa: E402

SOURCES = [ROOT / "App", ROOT / "Extension", ROOT / "Shared"]
LAZY = re.compile(r"(?<![\w.])(LazyVStack|LazyHStack|LazyVGrid|LazyHGrid|List)\b")
FOR_EACH = re.compile(r"(?<![\w.])ForEach\b")
CLOSERS = {"(": ")", "{": "}", "[": "]"}


def blank_comments_and_strings(text):
    """`text` with comments and string literals replaced by spaces, newlines kept, so brackets in
    them are not code and offsets still give line numbers."""
    out = list(text)
    index = 0

    def blank(start, end):
        for position in range(start, end):
            if out[position] != "\n":
                out[position] = " "

    while index < len(text):
        if text.startswith("//", index):
            end = text.find("\n", index)
            end = len(text) if end < 0 else end
            blank(index, end)
            index = end
        elif text.startswith("/*", index):
            end = text.find("*/", index + 2)
            end = len(text) if end < 0 else end + 2
            blank(index, end)
            index = end
        elif text.startswith('"""', index):
            end = text.find('"""', index + 3)
            end = len(text) if end < 0 else end + 3
            blank(index, end)
            index = end
        elif text[index] == '"':
            end = index + 1
            depth = 0  # parentheses of an interpolation, whose own strings are skipped too
            while end < len(text) and text[end] != "\n":
                if text[end] == "\\":
                    if text.startswith("\\(", end):
                        depth += 1
                        end += 2
                        continue
                    end += 2
                    continue
                if depth and text[end] == "(":
                    depth += 1
                elif depth and text[end] == ")":
                    depth -= 1
                elif not depth and text[end] == '"':
                    break
                end += 1
            blank(index, min(end + 1, len(text)))
            index = end + 1
        else:
            index += 1
    return "".join(out)


def skip_space(code, index):
    while index < len(code) and code[index].isspace():
        index += 1
    return index


def matching(code, index):
    """The index just past the bracket that closes the one at `index`."""
    opener, closer, depth = code[index], CLOSERS[code[index]], 0
    while index < len(code):
        if code[index] == opener:
            depth += 1
        elif code[index] == closer:
            depth -= 1
            if depth == 0:
                return index + 1
        index += 1
    return len(code)


def call_end(code, index):
    """Past a call that starts at `index` (just after its name): its arguments and its trailing
    closures, or `index` itself when no argument list or closure follows."""
    index = skip_space(code, index)
    if index < len(code) and code[index] == "(":
        index = skip_space(code, matching(code, index))
    while index < len(code) and code[index] == "{":
        index = skip_space(code, matching(code, index))
        label = re.match(r"(\w+):\s*\{", code[index:])  # a labelled trailing closure: `header: {`
        if not label:
            break
        index += label.end() - 1
    return index


def content(code, index):
    """The (start, end) of the content closure of the container whose name ends at `index`, or
    None when it has none (a `List(rows) { row in … }` draws its rows without a ForEach)."""
    index = skip_space(code, index)
    if index < len(code) and code[index] == "(":
        index = skip_space(code, matching(code, index))
    if index < len(code) and code[index] == "{":
        return index + 1, matching(code, index) - 1
    return None


def top_level_for_eaches(code, start, end):
    """The offsets of the `ForEach`es in `code[start:end]` that are not inside another `ForEach`
    or another lazy container (which is checked on its own)."""
    found, index = [], start
    while index < end:
        for_each = FOR_EACH.match(code, index)
        lazy = LAZY.match(code, index)
        if for_each and (index == 0 or not (code[index - 1].isalnum() or code[index - 1] in "_.")):
            found.append(index)
            index = call_end(code, for_each.end())
        elif lazy and (index == 0 or not (code[index - 1].isalnum() or code[index - 1] in "_.")):
            index = call_end(code, lazy.end())
        else:
            index += 1
    return found


def violations(text):
    """(line, container, count) for every lazy container in Swift source `text` that draws more
    than one top-level ForEach."""
    code = blank_comments_and_strings(text)
    found = []
    for match in LAZY.finditer(code):
        body = content(code, match.end())
        if body is None:
            continue
        for_eaches = top_level_for_eaches(code, *body)
        if len(for_eaches) > 1:
            found.append((code.count("\n", 0, match.start()) + 1, match.group(1), len(for_eaches)))
    return found


class LazyListTests(unittest.TestCase):
    def test_no_lazy_container_splits_its_rows_across_sibling_for_eaches(self):
        problems = []
        for source in SOURCES:
            for path in sorted(source.rglob("*.swift")):
                for line, container, count in violations(path.read_text(encoding="utf-8")):
                    problems.append(
                        f"{path.relative_to(ROOT)}:{line}: {container} has {count} sibling ForEach")
        self.assertEqual(
            problems, [],
            "A lazy container keeps a stale row for an item that moves from one ForEach to another;"
            " draw one ForEach over a single ordered list with stable ids (see DownloadQueue.entries)"
            " and docs/conventions.md#swiftui-control-panel.")

    def test_the_scan_finds_sibling_for_eaches_and_nothing_else(self):
        split = """
        ScrollView {
          LazyVStack(spacing: 0) {
            ForEach(queue.requests) { RequestRow(request: $0) }
            ForEach(queue.pending) { JobRow(row: $0) }
            if showsCompleted {
              ForEach(queue.succeeded) { JobRow(row: $0) }
            }
          }
        }
        """
        self.assertEqual(violations(split), [(3, "LazyVStack", 3)])
        single = """
        LazyVStack { ForEach(entries) { entry in Row(entry, note: "ForEach(x) { }") } }
        // LazyVStack { ForEach(a) {}; ForEach(b) {} }
        """
        self.assertEqual(violations(single), [])
        nested = """
        List(selection: $selection) {
          Section { Label("All", systemImage: "square") }
          ForEach(clusters, id: \\.first) { cluster in
            Section { ForEach(cluster, id: \\.self) { Row($0) } }
          }
        }
        """
        self.assertEqual(violations(nested), [], "a ForEach inside another one's rows is fine")
        sections = """
        List {
          Section { ForEach(running) { Row($0) } } header: { Text("Running") }
          Section { ForEach(paused) { Row($0) } }
        }
        """
        self.assertEqual(violations(sections), [(2, "List", 2)])
        inner = """
        LazyVStack {
          ForEach(rows) { row in
            LazyHStack { ForEach(row.a) { A($0) }; ForEach(row.b) { B($0) } }
          }
        }
        """
        self.assertEqual(violations(inner), [(4, "LazyHStack", 2)], "each container is judged alone")
        self.assertEqual(violations("let list = LazyVStackCount; List(rows) { Row($0) }"), [])


if __name__ == "__main__":
    unittest.main()
