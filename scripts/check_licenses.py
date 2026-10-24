#!/usr/bin/env python3
"""List the license closure of the built app and check it against the project's license policy.

Three inventories, each with its license and where it comes from:

1. every Mach-O dependency of the built app: `otool -L` from the main executable, the
   extension executables and every library or framework in `Contents/Frameworks`,
   followed recursively. Homebrew paths resolve through `realpath` to their Cellar keg; an
   already packaged app (`@rpath` into `Contents/Frameworks`) is walked the same way.
   Apple system libraries pass as system;
2. third-party code compiled or statically linked into the renderer, from a source-level
   inventory: the `cargo:rustc-link-lib` lists of `Renderer/Core/build.rs`, the
   `find_package`/`pkg_check_modules` targets of the scene engine's CMake files, and
   the vendored C libraries in `ThirdParty/`. Their licenses come from the hand-kept `COMPONENTS`
   table below, which must cover every entry or the entry is reported as unknown;
3. every linked Rust crate, from `cargo tree` for the target the app is built for (not
   `cargo metadata`, which also lists crates the build never compiles).

Licenses are SPDX expressions. `OR` is a choice (any allowed option is enough), `AND`
needs every part allowed. The policy is the `ALLOWED` table: the app is GPL-3.0-only, so
a dependency must be GPLv3-compatible; GPL-2.0-only, other known incompatible licenses
and unknown licenses fail.

Report-only by default: findings are warnings and the exit status is 0. `--enforce`
exits 1 on any finding, and on any section that could not be checked. Tool errors (no
cargo, an unreadable `--app`) exit 1 either way. The full report is `report.json` and
`closure.txt` in `artifacts/licenses/<run>/`.
"""
import argparse
from collections import deque
from dataclasses import dataclass, replace
from datetime import datetime
import json
from pathlib import Path
import re
import subprocess

from build import cargo_environment
from lib.glyphs import markers
from lib.homebrew import keg_of
from lib.paths import ARTIFACTS, ENGINE, RENDERER, ROOT, THIRD_PARTY, app_bundle

MARK = markers()
LICENSE_ARTIFACTS = ARTIFACTS / "licenses"
CORE_BUILD_SCRIPT = RENDERER / "Core/build.rs"
CARGO_MANIFEST = RENDERER / "Cargo.toml"
LICENSING = ROOT / "LICENSING.md"
CARGO_TREE = ("cargo", "tree", "--offline", "--manifest-path", str(CARGO_MANIFEST), "--workspace",
              "-e", "normal,no-proc-macro", "--target", "aarch64-apple-darwin", "--prefix", "none",
              "-f", "{p}|{l}")

# ---------------------------------------------------------------------------
# License policy. The project is GPL-3.0-only, so everything it links must be
# GPLv3-compatible; LICENSING.md is the account of what the project contains.
# Identifiers are SPDX ids, compared case-insensitively.
# ---------------------------------------------------------------------------
POLICY = "GPL-3.0-only"
ALLOWED = frozenset(license.lower() for license in (
    "MIT", "MIT-0", "BSD-2-Clause", "BSD-3-Clause", "ISC", "Zlib", "0BSD", "Unlicense", "CC0-1.0",
    "BSL-1.0", "Unicode-3.0", "Unicode-DFS-2016", "libpng-2.0", "WTFPL",
    "LicenseRef-PublicDomain",
    "Apache-2.0",  # compatible with GPLv3 (not with GPLv2)
    "MPL-2.0",  # section 3.3 names GPL-3.0 as a Secondary License
    "LGPL-2.1-only", "LGPL-2.1-or-later", "LGPL-3.0-only", "LGPL-3.0-or-later",
    "GPL-2.0-or-later",  # usable under version 3
    "GPL-3.0-only", "GPL-3.0-or-later",
))
# Why a license outside ALLOWED fails: the licenses the policy knows to be GPLv3-incompatible;
# everything else outside ALLOWED is "unknown", which needs a human to look at it before it can be added.
REJECTED_CLASSES = (
    ("gpl2", re.compile(r"^gpl-2\.0-only$")),
    ("incompatible", re.compile(r"^(gpl-1|apache-1|cddl-|epl-|eupl-1\.[01]|sspl-|busl-|openssl|ssleay|"
                                r"cc-by-nc)")),
)
# Deprecated SPDX spellings and the `+` suffix.
SPDX_ALIASES = {"gpl-2.0": "GPL-2.0-only", "gpl-3.0": "GPL-3.0-only", "lgpl-2.1": "LGPL-2.1-only",
                "lgpl-3.0": "LGPL-3.0-only", "agpl-3.0": "AGPL-3.0-only"}
# Metadata that names no license at all.
NO_LICENSE = re.compile(r"^(|noassertion|none|file:.*)$", re.IGNORECASE)

PASSING = ("system", "tool", "not-linked", "first-party")
FAILING = ("gpl2", "incompatible", "unknown")
CLASS_LABEL = {"gpl2": "GPL-2.0-only", "incompatible": "GPLv3-incompatible license", "unknown": "unknown license"}


class ToolError(Exception):
    """A condition that stops the check; the message is the whole report."""


# ---------------------------------------------------------------------------
# SPDX expressions
# ---------------------------------------------------------------------------
class ExpressionError(ValueError):
    pass


def normalise_id(token):
    token = token.strip()
    if token.endswith("+"):
        base = token[:-1]
        return base if base.lower().endswith("-or-later") else f"{base}-or-later"
    return SPDX_ALIASES.get(token.lower(), token)


def tokens_of(expression):
    """SPDX tokens; the legacy `A/B` spelling Cargo manifests still use means `A OR B`."""
    result = []
    for token in re.findall(r"\(|\)|[^\s()]+", expression):
        parts = token.split("/") if token not in ("(", ")") else [token]
        for index, part in enumerate(parts):
            if index:
                result.append("OR")
            if part:
                result.append(part)
    return result


def parse_expression(expression):
    """Parse an SPDX expression into ("or"|"and", [nodes]) / ("atom", id, exception) tuples."""
    tokens = tokens_of(expression)
    position = 0

    def peek():
        return tokens[position].upper() if position < len(tokens) else None

    def advance():
        nonlocal position
        position += 1
        return tokens[position - 1]

    def primary():
        token = peek()
        if token is None:
            raise ExpressionError("expression ends early")
        if token == "(":
            advance()
            node = either()
            if peek() != ")":
                raise ExpressionError("missing )")
            advance()
            return node
        if token in (")", "AND", "OR", "WITH"):
            raise ExpressionError(f"unexpected {token}")
        identifier = normalise_id(advance())
        exception = None
        if peek() == "WITH":
            advance()
            if peek() in (None, "(", ")", "AND", "OR", "WITH"):
                raise ExpressionError("WITH needs an exception id")
            exception = advance()
        return ("atom", identifier, exception)

    def both():
        nodes = [primary()]
        while peek() == "AND":
            advance()
            nodes.append(primary())
        return nodes[0] if len(nodes) == 1 else ("and", nodes)

    def either():
        nodes = [both()]
        while peek() == "OR":
            advance()
            nodes.append(both())
        return nodes[0] if len(nodes) == 1 else ("or", nodes)

    node = either()
    if position != len(tokens):
        raise ExpressionError(f"unexpected {tokens[position]}")
    return node


def evaluate(node):
    """(allowed, rejected atoms). An exception never turns a rejected license into an allowed one."""
    if node[0] == "atom":
        _, identifier, exception = node
        if identifier.lower() in ALLOWED:
            return True, frozenset()
        return False, frozenset({identifier + (f" WITH {exception}" if exception else "")})
    results = [evaluate(child) for child in node[1]]
    rejected = frozenset().union(*(atoms for _, atoms in results))
    if node[0] == "or":
        return any(allowed for allowed, _ in results), (frozenset() if any(a for a, _ in results) else rejected)
    return all(allowed for allowed, _ in results), rejected


def rejected_class(atom):
    identifier = atom.lower().split(" with ")[0]
    for name, pattern in REJECTED_CLASSES:
        if pattern.match(identifier):
            return name
    return "unknown"


@dataclass(frozen=True)
class Verdict:
    status: str  # ok | gpl2 | incompatible | unknown
    classes: tuple = ()
    rejected: tuple = ()
    reason: str = ""


def classify(expression):
    """The policy verdict on an SPDX expression; `status` is the worst class when several apply."""
    if expression is None or NO_LICENSE.match(expression.strip()):
        return Verdict("unknown", ("unknown",), (), "no license metadata")
    try:
        allowed, rejected = evaluate(parse_expression(expression))
    except ExpressionError as error:
        return Verdict("unknown", ("unknown",), (), f"unparseable license expression: {error}")
    if allowed:
        return Verdict("ok")
    classes = sorted({rejected_class(atom) for atom in rejected}, key=FAILING.index)
    return Verdict(classes[0], tuple(classes), tuple(sorted(rejected)), "not allowed: " + ", ".join(sorted(rejected)))


# ---------------------------------------------------------------------------
# Hand-kept license data. Every entry the inventories produce must be here, or it is
# reported as unknown: a new library cannot enter the closure unnoticed.
# ---------------------------------------------------------------------------
@dataclass(frozen=True)
class Entry:
    license: str | None
    note: str
    kind: str = ""  # "" is third-party code; otherwise one of PASSING


COMPONENTS = {
    "nlohmann-json": Entry("MIT", "header-only"),
    "argparse": Entry("MIT", "header-only"),
    "miniaudio": Entry("Unlicense OR MIT-0", "vendored header; public domain or MIT-0 at the user's choice"),
    "effolkronium-random": Entry("MIT", "vendored header (random.hpp); its header states MIT"),
    "vog-sha1": Entry("LicenseRef-PublicDomain", "vendored header (sha1.hpp); its header states 100% public domain"),
    "stb_image": Entry("MIT OR Unlicense", "vendored header; public domain or MIT at the user's choice"),
    "stb_vorbis": Entry("MIT OR Unlicense", "vendored source (stb_vorbis.c 1.22, unchanged), linked as the static archive "
                        "stb_vorbis; public domain or MIT at the user's choice"),
    "glad": Entry(None, "added to the CMake project but never linked; license not checked", "not-linked"),
    "quickjs-ng": Entry("MIT", "Homebrew dylib"),
    "lz4": Entry("BSD-2-Clause", "Homebrew dylib"),
    "freetype": Entry("FTL OR GPL-2.0-or-later", "Homebrew dylib; the keg's LICENSE.TXT offers either"),
    "libpng": Entry("libpng-2.0", "Homebrew dylib, a FreeType dependency"),
    "mediaremote-adapter": Entry("BSD-3-Clause", "ThirdParty/mediaremote-adapter, embedded framework"),
    "(apple system)": Entry(None, "Apple system library or framework", "system"),
    "(build tool)": Entry(None, "build-time tool, not part of the product", "tool"),
}
# Metadata known to be wrong or too coarse, replacing what Homebrew or Cargo report:
# name -> (license, reason). A reason is mandatory.
OVERRIDES = {
    "freetype": ("FTL OR GPL-2.0-or-later",
                 "Homebrew reports only FTL; the keg's LICENSE.TXT offers FTL or GPL-2.0-or-later, and the GPL option is used"),
}
# Names the inventories find -> the COMPONENTS entry (lowercase keys).
ALIASES = {
    # cargo:rustc-link-lib=dylib (c++ is Apple's libc++)
    "c++": "(apple system)", "lz4": "lz4", "freetype": "freetype",
    "qjs": "quickjs-ng",
    # find_package / pkg_check_modules
    "nlohmann_json": "nlohmann-json", "argparse": "argparse",
    "opengl": "(apple system)", "threads": "(apple system)", "pkgconfig": "(build tool)",
    "liblz4": "lz4",
    # ThirdParty/
    "effolkronium": "effolkronium-random", "glad": "glad", "miniaudio": "miniaudio",
    "vog": "vog-sha1", "stb_image": "stb_image",
}
# The scene engine's archives (Renderer/Engine/src, `wp*`) and the other renderer libraries
# (Renderer/, `wm*`: wmMedia, wmSound) are first party.
FIRST_PARTY_ARCHIVE = re.compile(r"^((wp|wm)[A-Z]\w*|wescene-renderer)$")
# A library file's stem -> its component, for libraries whose Homebrew keg cannot be found
# (an already packaged app, or a machine without Homebrew).
LIBRARY_STEMS = {
    "liblz4": "lz4", "libfreetype": "freetype", "libpng16": "libpng",
    "libqjs": "quickjs-ng", "MediaRemoteAdapter": "mediaremote-adapter",
}


@dataclass(frozen=True)
class Component:
    name: str
    kind: str  # dylib | static | link-dylib | cmake-package | vendored | crate, or one of PASSING
    section: str  # dylibs | inventory | crates
    version: str = ""
    license: str | None = None
    source: str = "none"  # brew | cargo | map | override | none
    reached_from: tuple = ()
    files: tuple = ()
    note: str = ""


def with_license(name, brew=None, declared=None):
    """(license, source) for a component: an override first, then what the tool reported, then the table."""
    if name in OVERRIDES:
        return OVERRIDES[name][0], "override"
    if declared is not None and not NO_LICENSE.match(declared.strip()):
        return declared, "brew" if brew else "cargo"
    entry = COMPONENTS.get(name)
    if entry is not None and entry.license is not None:
        return entry.license, "map"
    return None, "none"


# ---------------------------------------------------------------------------
# Command execution (injectable)
# ---------------------------------------------------------------------------
def run_command(command, cwd=None, env=None):
    """Run a command and capture its output separately; a missing executable is reported, not raised."""
    try:
        return subprocess.run(list(map(str, command)), cwd=cwd, env=env, capture_output=True, text=True, errors="replace")
    except OSError as error:
        return subprocess.CompletedProcess(command, 127, "", str(error))


def parse_otool(text):
    """The load commands `otool -L` lists, without the header line and the version suffixes."""
    return [line.strip().split(" (compatibility")[0] for line in text.splitlines()[1:] if line.strip()]


# ---------------------------------------------------------------------------
# 1. The built app's Mach-O closure
# ---------------------------------------------------------------------------
SYSTEM_PREFIXES = ("/usr/lib/", "/System/", "/Library/Apple/")


def is_system(dependency):
    # Swift's runtime libraries are loaded from the OS through @rpath, as package.py also assumes.
    return dependency.startswith(SYSTEM_PREFIXES) or dependency.startswith("@rpath/libswift")


def app_roots(app):
    """(file, directory `@executable_path` means for it) for everything the app loads by itself."""
    contents = app / "Contents"
    roots = []
    for executable_directory in [contents / "MacOS", *sorted((contents / "Extensions").glob("*.appex/Contents/MacOS"))]:
        roots += [(file, executable_directory) for file in sorted(executable_directory.glob("*")) if file.is_file()]
    frameworks = contents / "Frameworks"
    for file in sorted(frameworks.glob("*.dylib")):
        roots.append((file, contents / "MacOS"))
    for framework in sorted(frameworks.glob("*.framework")):
        roots.append((framework / framework.stem, contents / "MacOS"))
    return [(file, directory) for file, directory in roots if file.is_file()]


def resolve_dependency(dependency, file, executable_directory, app, prefix):
    """The file a load command names, or None. `@rpath` looks in the bundle's Frameworks, then Homebrew."""
    candidates = []
    if dependency.startswith("@rpath/"):
        name = dependency.removeprefix("@rpath/")
        candidates = [app / "Contents/Frameworks" / name, executable_directory.parent / "Frameworks" / name]
        if prefix is not None:
            candidates.append(prefix / "lib" / name)
    elif dependency.startswith("@loader_path/"):
        candidates = [file.parent / dependency.removeprefix("@loader_path/")]
    elif dependency.startswith("@executable_path/"):
        candidates = [executable_directory / dependency.removeprefix("@executable_path/")]
    elif dependency.startswith("/"):
        candidates = [Path(dependency)]
    return next((candidate for candidate in candidates if candidate.is_file()), None)


@dataclass
class Walk:
    roots: list
    libraries: dict  # resolved path -> referrer name
    system: set
    unresolved: list  # (dependency, referrer)


def walk_app(app, run, prefix):
    """Every non-system Mach-O file the app loads, directly or transitively; each file once, so cycles end."""
    roots = app_roots(app)
    if not roots:
        raise ToolError(f"No Mach-O executables found in {app}/Contents; is it a built WallpaperMachine.app?")
    walk = Walk([file for file, _ in roots], {}, set(), [])
    seen = {}
    queue = deque()
    for file, directory in roots:
        seen[file.resolve()] = ""
        queue.append((file.resolve(), directory))
    while queue:
        file, directory = queue.popleft()
        completed = run(["otool", "-L", file])
        if completed.returncode != 0:
            raise ToolError(f"otool -L {file} failed: {(completed.stderr or completed.stdout).strip()}")
        for dependency in parse_otool(completed.stdout):
            if is_system(dependency):
                walk.system.add(dependency)
                continue
            target = resolve_dependency(dependency, file, directory, app, prefix)
            if target is None:
                walk.unresolved.append((dependency, file.name))
                continue
            real = target.resolve()
            if real in seen:
                continue
            seen[real] = file.name
            walk.libraries[real] = file.name
            queue.append((real, directory))
    for file, _ in roots:
        walk.libraries.pop(file.resolve(), None)
    # Libraries bundled under Contents/Frameworks are roots too, but they are not the app's own code.
    for file, _ in roots:
        if file.is_relative_to(app / "Contents/Frameworks"):
            walk.libraries[file.resolve()] = "(bundled in Contents/Frameworks)"
    walk.roots = [file for file, _ in roots]
    return walk


def provenance(real, prefix, app):
    """(component name, version, from a keg) of a library file: its Homebrew keg, else its file name."""
    keg = keg_of(real)
    if keg is None and prefix is not None and real.is_relative_to(app):
        linked = prefix / "lib" / real.name
        if linked.exists():
            keg = keg_of(linked.resolve())
    if keg is not None:
        return keg.parent.name, keg.name, True
    return LIBRARY_STEMS.get(real.name.split(".")[0], real.name), "", False


def brew_licenses(run, formulas):
    """{formula: license} from one `brew info` call; empty when Homebrew is unavailable."""
    if not formulas:
        return {}
    completed = run(["brew", "info", "--json=v1", *sorted(formulas)])
    if completed.returncode != 0:
        return {}
    try:
        return {item["name"]: item.get("license") for item in json.loads(completed.stdout)}
    except (ValueError, KeyError, TypeError):
        return {}


def dylib_components(walk, prefix, app, run):
    grouped = {}
    formulas = set()
    for real, referrer in sorted(walk.libraries.items()):
        name, version, from_keg = provenance(real, prefix, app)
        grouped.setdefault((name, version), []).append((real, referrer))
        if from_keg:
            formulas.add(name)
    licenses = brew_licenses(run, formulas)
    components = []
    for (name, version), files in sorted(grouped.items()):
        license, source = with_license(name, brew=name in licenses, declared=licenses.get(name))
        components.append(Component(
            name, "dylib", "dylibs", version, license, source,
            tuple(sorted({referrer for _, referrer in files if referrer})),
            tuple(sorted({real.name for real, _ in files}))))
    for dependency, referrer in walk.unresolved:
        components.append(Component(Path(dependency).name, "dylib", "dylibs", "", None, "none", (referrer,),
                                    note=f"dependency not found: {dependency}"))
    return components


# ---------------------------------------------------------------------------
# 2. Compiled-in and statically linked code, from the sources
# ---------------------------------------------------------------------------
LINK_LIST = re.compile(r'for\s+(\w+)\s+in\s+\[(.*?)\]\s*\{\s*println!\(\s*"cargo:rustc-link-lib=(static|dylib|framework)=\{\1\}"', re.DOTALL)
# The other form: named `const NAME: [&str; N] = [...]` arrays, linked through a table of
# `("static" | "dylib" | "framework", &NAME)` pairs that one `cargo:rustc-link-lib={kind}={name}` loop prints.
NAMED_LIST = re.compile(r"\bconst\s+(\w+)\s*:\s*\[\s*&(?:'static\s+)?str\s*;\s*\d+\s*\]\s*=\s*\[(.*?)\]\s*;", re.DOTALL)
KIND_TABLE = re.compile(r'\(\s*"(static|dylib|framework)"\s*,\s*&(\w+)\s*\)')
FIND_PACKAGE = re.compile(r"\bfind_package\(\s*([A-Za-z0-9_+.-]+)", re.IGNORECASE)
PKG_CHECK = re.compile(r"\bpkg_check_modules\(\s*[A-Za-z0-9_]+((?:\s+(?:REQUIRED|QUIET|IMPORTED_TARGET|GLOBAL))*)\s+([A-Za-z0-9_.+-]+)", re.IGNORECASE)


def link_lists(build_script):
    """[(kind, name)] from the link-lib lists of build.rs; an empty result is an error, never silence."""
    text = build_script.read_text(errors="replace")
    found = []
    for _, body, kind in LINK_LIST.findall(text):
        body = re.sub(r"//[^\n]*", "", body)
        found += [(kind, name) for name in re.findall(r'"([^"]+)"', body)]
    if "cargo:rustc-link-lib={kind}={name}" in text:
        lists = {name: re.sub(r"//[^\n]*", "", body) for name, body in NAMED_LIST.findall(text)}
        for kind, name in KIND_TABLE.findall(text):
            found += [(kind, entry) for entry in re.findall(r'"([^"]+)"', lists.get(name, ""))]
    if not found:
        raise ToolError(f"No cargo:rustc-link-lib lists recognised in {build_script}")
    return found


def cmake_packages(engine):
    """[(name, file)] for the packages the scene engine's own CMake files look up (not its tests)."""
    files = [engine / "CMakeLists.txt", *sorted((engine / "src").rglob("CMakeLists.txt")),
             *sorted((engine / "Dependencies").glob("CMakeLists.txt"))]
    found = []
    for file in files:
        if not file.is_file():
            continue
        text = file.read_text(errors="replace")
        text = re.sub(r"#[^\n]*", "", text)
        relative = file.relative_to(engine)
        found += [(match, str(relative)) for match in FIND_PACKAGE.findall(text)]
        found += [(module, str(relative)) for _, module in PKG_CHECK.findall(text)]
    return found


# ThirdParty/ entries another section checks, or that hold no code.
NOT_ENGINE_VENDORED = {
    "naga": "a Rust crate, checked with the crates",
    "mediaremote-adapter": "an embedded framework, checked with the app's libraries",
    "received-licenses": "license texts of imported code, not code",
}


def vendored(third_party):
    """[(name, path)] of ThirdParty/ the engine may compile: every directory, and every loose header."""
    if not third_party.is_dir():
        raise ToolError(f"No vendored-code directory at {third_party}")
    entries = [entry for entry in sorted(third_party.iterdir()) if entry.name not in NOT_ENGINE_VENDORED]
    items = [(entry.name, f"ThirdParty/{entry.name}") for entry in entries if entry.is_dir()]
    items += [(entry.stem, f"ThirdParty/{entry.name}") for entry in entries
              if entry.is_file() and entry.suffix in (".h", ".hpp")]
    return items


def inventory_components(engine, build_script, third_party):
    """One component per library the sources name, however many lists and CMake files name it."""
    lists = link_lists(build_script)
    raw = [(name, f"build.rs {kind}", {"static": "static", "dylib": "link-dylib"}[kind])
           for kind, name in lists if kind != "framework"]
    raw += [(name, f"CMake {file}", "cmake-package") for name, file in cmake_packages(engine)]
    raw += [(name, path, "vendored") for name, path in vendored(third_party)]
    grouped = {}  # component -> (first raw name, kinds, origins)
    for name, origin, kind in raw:
        first_party = kind == "static" and FIRST_PARTY_ARCHIVE.match(name)
        key = name if first_party else ALIASES.get(name.lower(), name)
        _, kinds, origins = grouped.setdefault(key, (name, [], []))
        kinds.append("first-party" if first_party else kind)
        origins.append(origin)
    components = []
    for key, (raw_name, kinds, origins) in sorted(grouped.items()):
        origins = tuple(sorted(set(origins)))
        if "first-party" in kinds:
            components.append(Component(key, "first-party", "inventory", license="GPL-3.0-only", source="map",
                                        reached_from=origins, note="the project's own archive"))
            continue
        entry = COMPONENTS.get(key)
        kind = ",".join(sorted(set(kinds)))
        if entry is None:
            components.append(Component(key, kind, "inventory", reached_from=origins,
                                        note="not in the license table (COMPONENTS in scripts/check_licenses.py)"))
            continue
        license, source = with_license(key)
        components.append(Component(key, entry.kind or kind, "inventory", "", license, source, origins, note=entry.note))
    frameworks = sorted(name for kind, name in lists if kind == "framework")
    if frameworks:
        held = next((component for component in components if component.name == "(apple system)"), None)
        components = [component for component in components if component is not held]
        components.append(Component(
            "(apple system)", "system", "inventory", source="map", note=COMPONENTS["(apple system)"].note,
            reached_from=tuple(sorted({"build.rs framework", *(held.reached_from if held else ())})),
            files=tuple(sorted({*frameworks, *(held.files if held else ())}))))
    return components


# ---------------------------------------------------------------------------
# 3. Linked Rust crates
# ---------------------------------------------------------------------------
CRATE_LINE = re.compile(r"^(?P<name>\S+) v(?P<version>\S+)(?: \((?P<where>[^)]*)\))?\|(?P<license>.*?)(?: \(\*\))?$")


def is_vendored_crate(where):
    """True for a path crate vendored under `ThirdParty/` (naga).

    `cargo tree` prints every path crate with its directory, so a vendored third-party copy looks
    like a workspace member; it is the directory that tells them apart.
    """
    path = Path(where)
    try:
        parts = path.relative_to(ROOT).parts
    except ValueError:
        parts = path.parts
    if THIRD_PARTY.name not in parts:
        return False
    return len(parts) > parts.index(THIRD_PARTY.name) + 1


def parse_cargo_tree(text):
    """Components from `cargo tree --prefix none -f "{p}|{l}"`: duplicates (`(*)`) folded, workspace crates first party.

    A vendored path crate (`is_vendored_crate`) is third party and keeps the license its Cargo.toml declares.
    """
    seen = {}
    for line in text.splitlines():
        match = CRATE_LINE.match(line.strip())
        if not match:
            continue
        name, version, where = match["name"], match["version"], match["where"]
        key = (name, version)
        if key in seen:
            continue
        first_party = where is not None and where.startswith("/") and not is_vendored_crate(where)
        license = match["license"].strip() or None
        resolved, source = with_license(name, declared=license)
        seen[key] = Component(name, "first-party" if first_party else "crate", "crates", version, resolved,
                              source if not first_party else "cargo")
    return sorted(seen.values(), key=lambda component: (component.kind == "crate", component.name, component.version))


def crate_components(run, environment, output):
    completed = run(list(CARGO_TREE), cwd=RENDERER, env=environment)
    if output is not None:
        (output / "cargo-tree.txt").write_text(completed.stdout or "")
    if completed.returncode != 0:
        raise ToolError(f"cargo tree failed: {(completed.stderr or '').strip().splitlines()[-1:] or ['no output']}")
    components = parse_cargo_tree(completed.stdout)
    if not any(component.kind == "crate" for component in components):
        raise ToolError("cargo tree listed no crates")
    return components


# ---------------------------------------------------------------------------
# Closure, findings and report
# ---------------------------------------------------------------------------
def assess(component):
    """(status, classes, reason) of one component under the policy."""
    if component.kind in PASSING:
        return component.kind, (), ""
    verdict = classify(component.license)
    reason = component.note if component.license is None and component.note else verdict.reason
    return verdict.status, verdict.classes, reason


def normalised(text):
    return text.lower().replace("_", "-")


def merge(components):
    """One entry per third-party component across all inventories, sections joined; its license from the first that has one."""
    merged = {}
    for component in components:
        key = (component.kind == "crate", component.name)
        if key not in merged:
            merged[key] = component
            continue
        held = merged[key]
        merged[key] = replace(
            held, section=",".join(dict.fromkeys([*held.section.split(","), component.section])),
            license=held.license if held.license is not None else component.license,
            source=held.source if held.license is not None else component.source,
            version=held.version or component.version,
            reached_from=tuple(dict.fromkeys([*held.reached_from, *component.reached_from])),
            files=tuple(dict.fromkeys([*held.files, *component.files])))
    return list(merged.values())


def summarise(closure, licensing_text):
    """Counts, per-class lists and the failing components of the merged closure."""
    entries = []
    for component in closure:
        status, classes, reason = assess(component)
        entries.append({"name": component.name, "version": component.version, "kind": component.kind,
                        "section": component.section, "license": component.license, "source": component.source,
                        "reached_from": list(component.reached_from), "files": list(component.files),
                        "note": component.note, "status": status, "classes": list(classes), "reason": reason})
    lists = {name: sorted(entry["name"] for entry in entries if name in entry["classes"]) for name in FAILING}
    failing = [entry for entry in entries if entry["status"] in FAILING]
    unrecorded = []
    if licensing_text is not None:
        text = normalised(licensing_text)
        unrecorded = sorted(entry["name"] for entry in failing if normalised(entry["name"]) not in text)
    counts = {status: sum(1 for entry in entries if entry["status"] == status) for status in (*PASSING, *FAILING, "ok")}
    counts["components"] = len(entries)
    counts["failing"] = len(failing)
    counts["by_class"] = {name: len(names) for name, names in lists.items()}
    return entries, lists, failing, unrecorded, counts


def describe(entry):
    where = ",".join(sorted(set(entry["section"].split(","))))
    version = f" {entry['version']}" if entry["version"] else ""
    return f"{entry['name']}{version} [{where}]  {entry['license'] or '(no license)'}  -> {entry['reason']}"


def display_path(path):
    """A path for output: relative to the repository, or to `~`, so no home directory is printed."""
    path = Path(path)
    for base, prefix in ((ROOT, ""), (Path.home(), "~/")):
        if path.is_relative_to(base):
            return prefix + str(path.relative_to(base))
    return str(path)


def write_closure(output, sections, entries):
    lines = []
    for name, info in sections.items():
        lines.append(f"== {name}: {info['status']}" + (f" ({info['detail']})" if info.get("detail") else ""))
    lines.append("")
    for entry in sorted(entries, key=lambda e: (e["status"] in PASSING, e["status"], e["name"])):
        lines.append(f"{entry['status']:<12} {entry['name']} {entry['version']}".rstrip()
                     + f"  [{entry['section']}]  {entry['license'] or '-'}  ({entry['source']})")
    (output / "closure.txt").write_text("\n".join(lines) + "\n")


@dataclass
class Collected:
    """What the three inventories found, and which of them could not run."""
    components: list
    sections: dict
    incomplete: list
    skipped_by_choice: list
    app: Path | None
    prefix: Path | None  # Homebrew prefix, when the dylib walk found it


def collect_components(options, runner=run_command, environment=None, output=None, say=print):
    """Run the three inventories. `output` receives `cargo-tree.txt`; `say` shows progress (packaging passes none)."""
    sections = {}
    components = []
    incomplete = []
    skipped_by_choice = []
    prefix = None

    app = None if options.skip_app else options.app
    if options.skip_app:
        sections["dylibs"] = {"status": "skipped", "detail": "--skip-app"}
        skipped_by_choice.append("dylibs (--skip-app)")
        say(f"{MARK.warn} Dylibs skipped (--skip-app)")
    elif not app.is_dir():
        if options.app_given:
            raise ToolError(f"No application bundle at {display_path(app)}")
        sections["dylibs"] = {"status": "skipped", "detail": f"no built app at {display_path(app)}"}
        incomplete.append("dylibs")
        say(f"{MARK.warn} Dylibs skipped: no built app at {display_path(app)} (build one or pass --app)")
    else:
        completed = runner(["brew", "--prefix"])
        prefix = Path(completed.stdout.strip()) if completed.returncode == 0 and completed.stdout.strip() else None
        walk = walk_app(app, runner, prefix)
        found = dylib_components(walk, prefix, app, runner)
        components += found
        sections["dylibs"] = {"status": "checked", "roots": [display_path(file) for file in walk.roots],
                              "libraries": len(walk.libraries), "system": len(walk.system),
                              "system_libraries": sorted(walk.system),
                              "unresolved": [list(item) for item in walk.unresolved]}
        say(f"{MARK.step} Dylibs: {len(walk.roots)} roots, {len(walk.libraries)} third-party libraries, "
            f"{len(walk.system)} Apple system libraries ({display_path(app)})")
        for dependency, referrer in walk.unresolved:
            say(f"{MARK.warn} Dependency not found: {dependency} (from {referrer})")

    inventory = inventory_components(options.engine, options.build_script, options.third_party)
    components += inventory
    sections["inventory"] = {"status": "checked", "entries": len(inventory), "build_script": display_path(options.build_script)}
    say(f"{MARK.step} Compiled-in and statically linked: {len(inventory)} inventory entries")

    crates = crate_components(runner, environment, output)
    components += crates
    third_party = sum(1 for component in crates if component.kind == "crate")
    sections["crates"] = {"status": "checked", "third_party": third_party, "first_party": len(crates) - third_party}
    say(f"{MARK.step} Rust crates: {third_party} third-party, {len(crates) - third_party} first-party")
    return Collected(components, sections, incomplete, skipped_by_choice, app, prefix)


def run_checks(output, options, runner=run_command, environment=None, licensing_text=None):
    """Collect the three inventories, print findings, write the report. Returns the exit status."""
    output.mkdir(parents=True, exist_ok=True)
    enforce = options.enforce
    finding_mark = MARK.missing if enforce else MARK.warn
    collected = collect_components(options, runner, environment, output)
    components, sections, incomplete = collected.components, collected.sections, collected.incomplete
    skipped_by_choice, app = collected.skipped_by_choice, collected.app

    closure = merge(components)
    entries, lists, failing, unrecorded, counts = summarise(closure, licensing_text)
    for entry in failing:
        print(f"{finding_mark} {describe(entry)}")
    for name, label in CLASS_LABEL.items():
        if lists[name]:
            print(f"{finding_mark} {label} ({len(lists[name])}): {', '.join(lists[name])}")
    if unrecorded:
        print(f"{finding_mark} Not recorded in LICENSING.md: {', '.join(unrecorded)}")
    findings = len(failing) + (1 if unrecorded else 0)
    failed = bool(findings) or bool(incomplete)
    report = {"generated": datetime.now().isoformat(timespec="seconds"), "policy": POLICY,
              "allowed": sorted(ALLOWED), "enforce": enforce, "app": display_path(app) if app else None,
              "sections": sections, "counts": counts, "lists": lists, "unrecorded_in_licensing_md": unrecorded,
              "incomplete": incomplete, "skipped_by_choice": skipped_by_choice, "violations": [describe(entry) for entry in failing],
              "components": entries}
    (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    write_closure(output, sections, entries)
    summary = (f"license closure ({POLICY}): {counts['components']} components, {len(lists['gpl2'])} GPL-2.0-only, "
               f"{len(lists['incompatible'])} incompatible, {len(lists['unknown'])} unknown, {len(unrecorded)} not in LICENSING.md")
    if incomplete or skipped_by_choice:
        summary += f"; skipped: {', '.join(incomplete + skipped_by_choice)}"
    if not failed:
        print(f"{MARK.ok} {summary}; report: {display_path(output)}")
        return 0
    if enforce:
        print(f"{MARK.missing} {summary}; report: {display_path(output)}")
        return 1
    print(f"{MARK.warn} {summary} (report-only; pass --enforce to fail); report: {display_path(output)}")
    return 0


def main(argv=None, runner=run_command, environment=None, licensing_text=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--app", type=Path, help="Built WallpaperMachine.app (default: the Release build).")
    parser.add_argument("--skip-app", action="store_true", help="Skip the dylib closure; the verdict names the skip, and --enforce accepts it as an explicit choice.")
    parser.add_argument("--enforce", action="store_true", help="Exit 1 on any finding or skipped section (default: report only).")
    parser.add_argument("--output", type=Path, help="Directory for report.json and closure.txt.")
    args = parser.parse_args(argv)
    args.app_given = args.app is not None
    args.app = args.app or app_bundle("Release")
    args.engine = ENGINE
    args.third_party = THIRD_PARTY
    args.build_script = CORE_BUILD_SCRIPT
    output = args.output or LICENSE_ARTIFACTS / datetime.now().strftime("closure-%Y%m%d-%H%M%S-%f")
    try:
        if licensing_text is None and LICENSING.is_file():
            licensing_text = LICENSING.read_text(errors="replace")
        return run_checks(output, args, runner, cargo_environment() if environment is None else environment, licensing_text)
    except ToolError as error:
        print(f"{MARK.missing} {error}")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
