#!/usr/bin/env python3
"""Write THIRD-PARTY-NOTICES.txt: the license text of every third-party component the app contains.

MIT, BSD, ISC and Zlib ask for their notice to travel with binary copies, and the MPL-2.0
asks for a pointer to the source. The closure comes from scripts/check_licenses.py (Mach-O
dependencies of the built app, the compiled-in inventory, every linked Rust crate); for each
component this script finds the license text in the component itself, never from memory:

* Rust crates: the `LICENSE*`/`COPYING*` files of the crate in the local cargo registry, or
  of the vendored copy under `ThirdParty/` (naga). For a choice (`MIT OR Apache-2.0`) the text
  of the option the project uses is written: the first allowed option in `CHOICE_ORDER`.
  Files are matched to a license by what they say, not by what they are called;
* Homebrew libraries and header-only packages: the license files of the keg;
* vendored code: its license file under `ThirdParty/`, or the notice at the end of the header.

A component whose text cannot be found is listed with a `LICENSE TEXT NOT FOUND` marker.
Report-only by default; `--enforce` exits 1 when any text is missing. Tool errors (no cargo,
an unreadable `--app`) exit 1 either way. The default output is
`artifacts/licenses/THIRD-PARTY-NOTICES.txt`; `scripts/package.py` runs this generator and
bundles the result in `Contents/Resources`.
"""
import argparse
from dataclasses import dataclass, replace
import os
from pathlib import Path
import re
from types import SimpleNamespace

import check_licenses
from check_licenses import PASSING, ToolError, evaluate, merge, parse_expression
from lib.glyphs import markers
from lib.homebrew import KEG_LICENSE_FILE
from lib.paths import ARTIFACTS, ENGINE, ROOT, THIRD_PARTY, app_bundle

MARK = markers()
DEFAULT_OUTPUT = ARTIFACTS / "licenses/THIRD-PARTY-NOTICES.txt"
NOT_FOUND = "LICENSE TEXT NOT FOUND"
# License files this repository supplies for a component whose own distribution carries none
# (`<name>/LICENSE*`, copied from the upstream project's repository, recorded in the commit).
SUPPLEMENTS = ROOT / "Packaging/notices"

# The option of a choice that the notice carries: the first allowed alternative in this order,
# so a dual `MIT OR Apache-2.0` crate is noticed under the MIT terms the project uses.
CHOICE_ORDER = ("MIT", "MIT-0", "BSD-3-Clause", "BSD-2-Clause", "ISC", "Zlib", "0BSD", "Unlicense", "CC0-1.0",
                "BSL-1.0", "Unicode-3.0", "Unicode-DFS-2016", "libpng-2.0", "WTFPL")

# What each license's text says, to tell the files of a crate apart: `LICENSE` may be the MIT
# text or the Apache one. An id without a pattern takes any license file.
TEXT_PATTERNS = {
    "MIT": r"permission is hereby granted, free of charge",
    "MIT-0": r"permission is hereby granted, free of charge",
    "BSD-2-Clause": r"redistribution and use in source and binary forms",
    "BSD-3-Clause": r"redistribution and use in source and binary forms",
    "ISC": r"permission to use, copy, modify, and(/or)? distribute this software",
    "0BSD": r"permission to use, copy, modify, and(/or)? distribute this software",
    "Zlib": r"this software is provided ['\"]as-is['\"]",
    "Unlicense": r"this is free and unencumbered software",
    "CC0-1.0": r"creative commons legal code|cc0 1\.0 universal",
    "BSL-1.0": r"boost software license",
    "Unicode-3.0": r"unicode (license|terms of use)|unicode, inc",
    "Unicode-DFS-2016": r"unicode (license|terms of use)|unicode, inc",
    "libpng-2.0": r"png reference library license",
    "MPL-2.0": r"mozilla public license",
    "Apache-2.0": r"apache license",
    "WTFPL": r"do what the fuck you want",
}
CRATE_LICENSE_FILE = re.compile(r"^(LICEN[CS]E|COPYING|UNLICENSE|COPYRIGHT)([-_.].*)?$", re.IGNORECASE)

# Vendored code, by closure name: the license files in the repository. A header is
# `(path, marker)`: the notice is the tail of the file from the marker's line.
VENDORED_FILES = {
    "miniaudio": [THIRD_PARTY / "miniaudio/LICENSE"],
    "stb_vorbis": [THIRD_PARTY / "stb_vorbis/LICENSE"],
    "mediaremote-adapter": [THIRD_PARTY / "mediaremote-adapter/LICENSE"],
    "phosphene abi reference": [ROOT / "Extension/Phosphene-LICENSE.txt"],
}
VENDORED_HEADERS = {
    "stb_image": (THIRD_PARTY / "stb_image/stb_image.h", "This software is available under 2 licenses"),
}
# Shipped in the bundle but outside the closure: not code the walks can see.
EXTRAS = (
    ("mediaremote-adapter", "BSD-3-Clause", "ThirdParty/mediaremote-adapter, embedded framework"),
    ("Phosphene ABI reference", "MIT", "notice for the lock screen extension (Extension/Phosphene-LICENSE.txt)"),
)
SOURCE_NOTE = {
    "crate": "https://crates.io/crates/{name}/{version}",
}
MPL_NOTE = ("Source form of this component: its crate source at the URL above, and the exact version in "
            "Renderer/Cargo.lock of the WallpaperMachine source tree (MPL-2.0 section 3.2).")


@dataclass(frozen=True)
class Notice:
    name: str
    version: str
    expression: str | None
    chosen: tuple  # SPDX ids whose text is written
    origin: str  # where the text came from, for display
    texts: tuple  # ((file label, text), ...)
    missing_ids: tuple = ()  # chosen licenses no file of the component says
    where: str = ""  # the kind of component, for display
    notes: tuple = ()

    @property
    def found(self):
        return bool(self.texts) and not self.missing_ids


@dataclass
class NoticeSet:
    notices: list
    skipped_dylibs: bool = False
    text: str = ""

    @property
    def found(self):
        return [notice for notice in self.notices if notice.found]

    @property
    def missing(self):
        return [notice for notice in self.notices if not notice.found]


# ---------------------------------------------------------------------------
# Which license a notice carries
# ---------------------------------------------------------------------------
def rank(identifier):
    for index, candidate in enumerate(CHOICE_ORDER):
        if candidate.lower() == identifier.lower():
            return index
    return len(CHOICE_ORDER)


def chosen_ids(expression):
    """The SPDX ids whose text the notice carries; every part of an AND, the best allowed side of an OR."""
    if expression is None:
        return ()
    try:
        node = parse_expression(expression)
    except ValueError:
        return ()

    def pick(node):
        if node[0] == "atom":
            return [node[1]]
        if node[0] == "and":
            return [identifier for child in node[1] for identifier in pick(child)]
        options = [child for child in node[1] if evaluate(child)[0]] or list(node[1])
        best = min(options, key=lambda child: max((rank(identifier) for identifier in pick(child)), default=0))
        return pick(best)

    return tuple(dict.fromkeys(pick(node)))


def read(file):
    """A license file as text with unix line ends and no trailing blanks, or None when it is unreadable."""
    try:
        text = file.read_text(errors="replace")
    except OSError:
        return None
    return "\n".join(line.rstrip() for line in text.replace("\r\n", "\n").replace("\r", "\n").split("\n")).strip("\n")


def select_texts(files, chosen):
    """(texts, missing): the files that say one of the chosen licenses, and the chosen ids no file says.

    A chosen id without a text pattern (a license only the table names) accepts every candidate file.
    """
    loaded = [(file, read(file)) for file in files]
    loaded = [(file, text) for file, text in loaded if text]
    selected = []
    missing = []
    for identifier in chosen:
        pattern = TEXT_PATTERNS.get(identifier)
        matches = [(file, text) for file, text in loaded if pattern is None or re.search(pattern, text, re.IGNORECASE)]
        if not matches:
            missing.append(identifier)
        selected += [match for match in matches if match not in selected]
    if not chosen and loaded:
        selected = loaded
    elif not chosen:
        missing.append("any license file")
    return selected, tuple(missing)


def header_notice(path, marker):
    """The license notice at the end of a header: from the comment rule above `marker` to the last `*/`."""
    try:
        lines = path.read_text(errors="replace").splitlines()
    except OSError:
        return None
    hits = [index for index, line in enumerate(lines) if marker in line]
    if not hits:
        return None
    start = hits[-1]
    while start > 0 and not re.match(r"^-{20,}$", lines[start - 1].strip()):
        start -= 1
    start = max(start - 1, 0)
    end = max((index for index, line in enumerate(lines) if line.strip() == "*/"), default=len(lines))
    text = "\n".join(line.rstrip() for line in lines[start:end]).strip("\n")
    return text or None


# ---------------------------------------------------------------------------
# Finding the files of a component
# ---------------------------------------------------------------------------
def label_of(file):
    """A file's name for the notice: repository files by their repository path, others by file name (no home directory)."""
    return check_licenses.display_path(file) if file.is_relative_to(ROOT) else file.name


def license_files(directory, pattern=CRATE_LICENSE_FILE):
    if directory is None or not directory.is_dir():
        return []
    return sorted(file for file in directory.iterdir() if file.is_file() and pattern.match(file.name))


def crate_directory(name, version, environment):
    """The source directory of a crate: the vendored copy under `ThirdParty/`, else the cargo registry."""
    vendored = THIRD_PARTY / name
    if (vendored / "Cargo.toml").is_file():
        return vendored
    home = Path((environment or os.environ).get("CARGO_HOME") or Path.home() / ".cargo")
    for registry in sorted((home / "registry/src").glob("*")):
        candidate = registry / f"{name}-{version}"
        if candidate.is_dir():
            return candidate
    return None


def keg_directory(component, prefix, runner):
    """The Homebrew keg of a component: `Cellar/<formula>/<version>`, else what `brew --prefix <formula>` resolves to."""
    if prefix is not None and component.version:
        keg = prefix / "Cellar" / component.name / component.version
        if keg.is_dir():
            return keg
    completed = runner(["brew", "--prefix", component.name])
    if completed.returncode == 0 and completed.stdout.strip():
        keg = Path(completed.stdout.strip()).resolve()
        if keg.is_dir():
            return keg
    return None


def notice_for(component, prefix, runner, environment):
    """The notice of one closure component."""
    chosen = chosen_ids(component.license)
    key = component.name.lower()
    texts = []
    missing_ids = ()
    origin = ""
    if component.kind == "crate":
        directory = crate_directory(component.name, component.version, environment)
        origin = check_licenses.display_path(directory) if directory and directory.is_relative_to(ROOT) else "cargo registry"
        texts, missing_ids = select_texts(license_files(directory) + license_files(SUPPLEMENTS / component.name), chosen)
    elif key in VENDORED_FILES or key in VENDORED_HEADERS:
        for file in VENDORED_FILES.get(key, []):
            text = read(file)
            if text:
                texts.append((label_of(file), text))
        if key in VENDORED_HEADERS:
            path, marker = VENDORED_HEADERS[key]
            text = header_notice(path, marker)
            if text:
                texts.append((f"{check_licenses.display_path(path)} (notice at the end of the header)", text))
        origin = "repository"
        missing_ids = () if texts else ("any license file",)
    else:
        keg = keg_directory(component, prefix, runner)
        files = license_files(keg, KEG_LICENSE_FILE) + license_files(SUPPLEMENTS / component.name)
        for file in files:
            text = read(file)
            if text:
                texts.append((label_of(file), text))
        origin = f"Homebrew keg {keg.parent.name} {keg.name}" if keg else "Homebrew keg (not found)"
        missing_ids = () if texts else ("any license file",)
        if keg is not None and not component.version:
            component = replace(component, version=keg.name)
    texts = [(label_of(label), text) if isinstance(label, Path) else (label, text) for label, text in texts]
    notes = []
    if component.license and "mpl-2.0" in component.license.lower() and component.kind == "crate":
        notes.append(MPL_NOTE)
    return Notice(component.name, component.version, component.license, chosen, origin, tuple(texts), missing_ids,
                  component.kind, tuple(notes))


def third_party(components):
    """The merged closure's third-party components, once each."""
    return [component for component in merge(components) if component.kind not in PASSING and component.name not in ("(apple system)", "(build tool)")]


def build_notices(collected, runner, environment=None):
    """Every third-party component of a collected closure, plus what is bundled outside it, as notices."""
    components = third_party(collected.components)
    notices = [notice_for(component, collected.prefix, runner, environment) for component in components]
    held = {notice.name.lower() for notice in notices}
    for name, expression, _ in EXTRAS:
        if name.lower() in held:
            continue
        component = check_licenses.Component(name, "vendored", "extras", "", expression, "map")
        notices.append(notice_for(component, collected.prefix, runner, environment))
    notices.sort(key=lambda notice: (notice.name.lower(), notice.version))
    return NoticeSet(notices, skipped_dylibs="dylibs" in collected.sections and collected.sections["dylibs"]["status"] != "checked")


# ---------------------------------------------------------------------------
# The file
# ---------------------------------------------------------------------------
RULE = "=" * 78
THIN = "-" * 78
PREAMBLE = """\
THIRD-PARTY NOTICES

WallpaperMachine is licensed under the GNU General Public License, version 3 only
(see WallpaperMachine-LICENSE.txt and LICENSING.md). It contains the third-party
software listed below, which is licensed under its own terms. Each entry gives the
component, its version, the SPDX license expression it declares, the license the
notice below carries (for a choice, the option this project uses), and the license
text taken from the component itself.

The complete source code of this application, including the exact versions of every
Rust crate in Renderer/Cargo.lock, is available from the project repository
at the tag of the release.
"""


def entry_text(notice):
    lines = [RULE, f"{notice.name} {notice.version}".rstrip()]
    lines.append(f"License: {notice.expression or '(not declared)'}")
    if notice.chosen and len(notice.chosen) and notice.expression and notice.expression.strip() != " ".join(notice.chosen):
        lines.append(f"Notice carries: {' AND '.join(notice.chosen)}")
    if notice.where == "crate":
        lines.append(f"Source: {SOURCE_NOTE['crate'].format(name=notice.name, version=notice.version)}")
    lines += notice.notes
    lines.append(RULE)
    if not notice.found:
        lines += ["", f"{NOT_FOUND} ({notice.origin}; no file says: {', '.join(notice.missing_ids)})", ""]
        for label, text in notice.texts:
            lines += [f"[{label}]", THIN, text, ""]
        return "\n".join(lines)
    for label, text in notice.texts:
        lines += ["", f"[{label}]", THIN, text, ""]
    return "\n".join(lines)


def render(noticeset):
    header = PREAMBLE
    if noticeset.skipped_dylibs:
        header += "\nNOTE: generated without the built app; libraries only the app links are not listed.\n"
    index = "\n".join(f"  {notice.name} {notice.version}".rstrip() + f"  [{notice.expression or 'license not declared'}]"
                      for notice in noticeset.notices)
    body = "\n".join(entry_text(notice) for notice in noticeset.notices)
    return f"{header}\nComponents ({len(noticeset.notices)}):\n\n{index}\n\n{body}\n"


def generate(options, runner=check_licenses.run_command, environment=None):
    """Collect the closure and build the notice file text: a NoticeSet whose `text` is the file."""
    collected = check_licenses.collect_components(options, runner, environment, None, say=lambda *_: None)
    noticeset = build_notices(collected, runner, environment)
    noticeset.text = render(noticeset)
    return noticeset


def summary(noticeset):
    return (f"{len(noticeset.notices)} components, {len(noticeset.found)} with license text, "
            f"{len(noticeset.missing)} without")


def options_for(app=None, skip_app=False):
    """The options `collect_components` reads, for callers that are not the command line."""
    return SimpleNamespace(app=app or app_bundle("Release"), app_given=app is not None, skip_app=skip_app,
                           engine=ENGINE, build_script=check_licenses.CORE_BUILD_SCRIPT, third_party=THIRD_PARTY)


def main(argv=None, runner=check_licenses.run_command, environment=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--app", type=Path, help="Built WallpaperMachine.app (default: the Release build).")
    parser.add_argument("--skip-app", action="store_true", help="Skip the dylib closure; libraries only the app links are then not listed.")
    parser.add_argument("--enforce", action="store_true", help="Exit 1 when any component's license text is not found (default: report only).")
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT, help=f"File to write (default: {check_licenses.display_path(DEFAULT_OUTPUT)}).")
    args = parser.parse_args(argv)
    options = options_for(args.app, args.skip_app)
    environment = check_licenses.cargo_environment() if environment is None else environment
    try:
        noticeset = generate(options, runner, environment)
    except ToolError as error:
        print(f"{MARK.missing} {error}")
        return 1
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(noticeset.text)
    for notice in noticeset.missing:
        print(f"{MARK.missing if args.enforce else MARK.warn} {NOT_FOUND}: {f'{notice.name} {notice.version}'.strip()} ({notice.expression or 'no license'}; {notice.origin})")
    if args.skip_app:
        print(f"{MARK.warn} Dylibs skipped (--skip-app): libraries only the app links are not listed")
    line = f"third-party notices: {summary(noticeset)}; written: {check_licenses.display_path(args.output)}"
    if noticeset.missing and args.enforce:
        print(f"{MARK.missing} {line}")
        return 1
    print(f"{MARK.warn if noticeset.missing else MARK.ok} {line}" + (" (report-only; pass --enforce to fail)" if noticeset.missing else ""))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
