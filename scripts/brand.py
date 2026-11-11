#!/usr/bin/env python3
"""Generate the WallpaperMachine logo, app icon, tray icon, web favicons and disk-image background.

The mark is a rounded display frame, open at the bottom-left corner, with an eight-tooth gear
sitting in the opening: the same two ideas as Wallpaper Engine's badge (a frame and a gear),
drawn as a single mark that stays legible at 16 px. The native app icon uses a white
background in light appearance and black in dark, with an aurora wallpaper panel.
The wordmark is Manrope ("Wallpaper" bold, "Machine" medium), embedded as outlines in
`lib/wordmark.py`.

    python3 scripts/brand.py                      # native app, Dock choices, tray icon and DMG background
    python3 scripts/brand.py --dmg                # only Packaging/dmg/background.png and background@2x.png
    python3 scripts/brand.py --seasonal           # only the seasonal Dock icons (AppIconHalloween)
    python3 scripts/brand.py --website ../Site    # plus logo, favicons and manifest there

The app icon exports vector layers for Icon Composer. Website app-icon PNGs reuse the
native Dock renders; website vectors share their geometry and appearances. Quick Look
and sips render square web icons and tray assets. Dock choices use Icon Composer's
macOS 26 renderer with a transparent outer margin and land in the AppIconMinimal, AppIconDay
and AppIconNight image sets of `App/Resources/Assets.xcassets` (their Contents.json files are
committed). A season's Dock icon (AppIconHalloween) is the Night tile with the season's papercut
night in the panel and a jack-o'-lantern in the gear's place; that picture is committed under
`Resources/Seasonal/`. The disk-image background is drawn with CoreGraphics and CoreText at 1x and 2x
from `lib/dmg.py`'s window geometry.
"""
from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile

from lib.dmg import APP_ICON_CENTER, APPLICATIONS_ICON_CENTER, BACKGROUND, ICON_SIZE, WINDOW
from lib.glyphs import markers
from lib.paths import ROOT
from lib.wordmark import MACHINE_ADVANCE, MACHINE_PATH, WALLPAPER_ADVANCE, WALLPAPER_PATH

MARK = markers()
APP_ICON = ROOT / "App/Resources/AppIcon.icon"
TRAY_ICON_SET = ROOT / "App/Resources/Assets.xcassets/TrayIcon.imageset"
DOCK_ICONS = ROOT / "App/Resources/Assets.xcassets"
SEASONAL = ROOT / "Resources/Seasonal"
DMG_BACKGROUND = BACKGROUND


def dock_icon(name: str) -> Path:
    """The Dock render of one icon choice, in the asset catalog image set `AppThemePreferences.Icon` loads."""
    return DOCK_ICONS / f"AppIcon{name.capitalize()}.imageset" / f"{name}.png"


# The wallpaper panel runs cyan -> blue -> violet in both native and website icons.
AURORA = ("#7cf0ff", "#3a86ff", "#8a3dff")
LOGO_ACCENT_ON_LIGHT, LOGO_INK_ON_LIGHT = "#1f6fe5", "#14181f"
LOGO_ACCENT_ON_DARK, LOGO_INK_ON_DARK = "#3d8bff", "#ffffff"
FAVICON_BACKGROUND = "#ffffff"

# The disk-image window: a cool near-white field with the aurora as a soft wash along the top
# edge, black Finder labels (Finder ignores Dark Mode on custom backgrounds) and a gray note.
DMG_FIELD = ("#f3f5fa", "#fcfcfe")  # top -> bottom
DMG_NOTE = "#626a78"
DMG_HEADLINE = "Drag WallpaperMachine into Applications"
# `*…*` runs are set in medium weight: the UI names the reader has to find.
DMG_FOOTNOTE = ("This build is ad hoc signed and not notarized, so macOS may block its first launch.",
                "If it does, open *System Settings \u203a Privacy & Security* and click *Open Anyway*.")

# Mark geometry in a 24-unit box. The frame is a rounded rectangle drawn as a stroke; the
# gear centre sits on the frame's bottom-left corner and the frame stops short of the gear
# by `pad` units so the two never touch. `small` is for sizes at or below 64 px.
FRAME = dict(left=4.0, top=3.0, right=21.0, bottom=20.0, radius=3.6)
GEAR_CENTER = (5.9, 18.1)
VARIANTS = {
    "regular": dict(stroke=2.2, radius=4.7, pad=1.25, teeth=dict(
        count=8, root=0.74, hub=0.31, tip=0.52, base=0.76, corner=0.10)),
    "small": dict(stroke=2.9, radius=5.3, pad=1.35, teeth=dict(
        count=8, root=0.72, hub=0.30, tip=0.56, base=0.82, corner=0.08)),
}
MARK_BOX = (1.0, 2.0, 22.1, 22.9)  # visual bounds of the mark inside the 24 box: x0 y0 x1 y1

# The Halloween jack-o'-lantern in the gear's place, in the same 24-unit box; `AppMark` in the
# panel draws the same outline. Three lobes (cx, rx, ry) on one centre line, the middle one in front;
# it keeps the gear's clearance from the frame's end caps.
PUMPKIN = dict(
    cy=18.5, lobes=((3.85, 2.45, 3.3), (7.95, 2.45, 3.3), (5.9, 2.6, 3.7)),
    eyes=(((3.6, 18.2), (4.72, 16.41), (5.42, 18.2)), ((8.2, 18.2), (7.08, 16.41), (6.38, 18.2))),
    mouth=((3.33, 19.24), (4.29, 19.67), (4.86, 19.28), (5.9, 19.81), (6.94, 19.28), (7.51, 19.67), (8.47, 19.24)),
    mouth_curve=(5.9, 22.42),
    stem="M5.33 15.15L5.6 13.85Q6.07 13.15 6.99 13.41Q6.47 13.67 6.29 14.11L6.38 15.15Z",
)

# Standalone website artwork uses an inset macOS squircle; native masking belongs to macOS.
ICON_CANVAS = 1024
ICON_INSET_BOX = 824
SQUIRCLE_RADIUS = 0.2237
TRAY_ICON_SIZES = {"TrayIcon.png": 16, "TrayIcon@2x.png": 32}


def num(value: float) -> str:
    """Compact SVG number: three decimals, no trailing zeros, no negative zero."""
    text = f"{value:.3f}".rstrip("0").rstrip(".")
    return "0" if text in ("-0", "") else text


def rounded_polygon(points: list[tuple[float, float]], radius: float) -> str:
    """Closed path through the vertices with every corner rounded by a quadratic curve."""
    count = len(points)
    parts = []
    for index, (x, y) in enumerate(points):
        px, py = points[index - 1]
        nx, ny = points[(index + 1) % count]
        into = math.hypot(x - px, y - py)
        out = math.hypot(nx - x, ny - y)
        r = min(radius, into / 2, out / 2)
        ax, ay = x + (px - x) / into * r, y + (py - y) / into * r
        bx, by = x + (nx - x) / out * r, y + (ny - y) / out * r
        parts.append(("M" if index == 0 else "L") + f"{num(ax)} {num(ay)}")
        parts.append(f"Q{num(x)} {num(y)} {num(bx)} {num(by)}")
    return "".join(parts) + "Z"


def gear_path(cx: float, cy: float, outer: float, teeth: dict) -> str:
    """Gear body with a round hub hole, for `fill-rule="evenodd"`."""
    root = outer * teeth["root"]
    pitch = 2 * math.pi / teeth["count"]
    half_tip, half_base = pitch * teeth["tip"] / 2, pitch * teeth["base"] / 2
    points = []
    for tooth in range(teeth["count"]):
        angle = pitch / 2 + tooth * pitch
        for theta, r in ((angle - half_base, root), (angle - half_tip, outer),
                         (angle + half_tip, outer), (angle + half_base, root)):
            points.append((cx + r * math.cos(theta), cy + r * math.sin(theta)))
    hub = outer * teeth["hub"]
    hole = (f"M{num(cx + hub)} {num(cy)}A{num(hub)} {num(hub)} 0 1 0 {num(cx - hub)} {num(cy)}"
            f"A{num(hub)} {num(hub)} 0 1 0 {num(cx + hub)} {num(cy)}Z")
    return rounded_polygon(points, outer * teeth["corner"]) + hole


def frame_path(gap_radius: float) -> str:
    """The frame's centreline, open where a circle of `gap_radius` around the gear cuts it."""
    left, top, right, bottom, r = (FRAME[k] for k in ("left", "top", "right", "bottom", "radius"))
    cx, cy = GEAR_CENTER
    y_left = cy - math.sqrt(gap_radius ** 2 - (left - cx) ** 2)
    x_bottom = cx + math.sqrt(gap_radius ** 2 - (bottom - cy) ** 2)
    return (f"M{num(x_bottom)} {num(bottom)}H{num(right - r)}"
            f"A{num(r)} {num(r)} 0 0 0 {num(right)} {num(bottom - r)}V{num(top + r)}"
            f"A{num(r)} {num(r)} 0 0 0 {num(right - r)} {num(top)}H{num(left + r)}"
            f"A{num(r)} {num(r)} 0 0 0 {num(left)} {num(top + r)}V{num(y_left)}")


def frame_outline_path(gap_radius: float, stroke: float) -> str:
    """Filled round-cap outline; macOS 26 icon recoloring ignores a stroke's fill=none."""
    left, top, right, bottom, r = (FRAME[k] for k in ("left", "top", "right", "bottom", "radius"))
    cx, cy = GEAR_CENTER
    y_left = cy - math.sqrt(gap_radius ** 2 - (left - cx) ** 2)
    x_bottom = cx + math.sqrt(gap_radius ** 2 - (bottom - cy) ** 2)
    half = stroke / 2
    outer, inner = r + half, r - half
    return (f'M{num(x_bottom)} {num(bottom + half)}H{num(right - r)}'
            f'A{num(outer)} {num(outer)} 0 0 0 {num(right + half)} {num(bottom - r)}V{num(top + r)}'
            f'A{num(outer)} {num(outer)} 0 0 0 {num(right - r)} {num(top - half)}H{num(left + r)}'
            f'A{num(outer)} {num(outer)} 0 0 0 {num(left - half)} {num(top + r)}V{num(y_left)}'
            f'A{num(half)} {num(half)} 0 0 0 {num(left + half)} {num(y_left)}V{num(top + r)}'
            f'A{num(inner)} {num(inner)} 0 0 1 {num(left + r)} {num(top + half)}H{num(right - r)}'
            f'A{num(inner)} {num(inner)} 0 0 1 {num(right - half)} {num(top + r)}V{num(bottom - r)}'
            f'A{num(inner)} {num(inner)} 0 0 1 {num(right - r)} {num(bottom - half)}H{num(x_bottom)}'
            f'A{num(half)} {num(half)} 0 0 0 {num(x_bottom)} {num(bottom + half)}Z')


def mark_parts(variant: str = "regular") -> tuple[str, str, float]:
    """(frame path, gear path, stroke width) in the 24-unit box."""
    spec = VARIANTS[variant]
    return (frame_path(spec["radius"] + spec["pad"]),
            gear_path(*GEAR_CENTER, spec["radius"], spec["teeth"]), spec["stroke"])


def mark_markup(color: str = "currentColor", variant: str = "regular") -> str:
    frame, gear, stroke = mark_parts(variant)
    return (f'<path d="{frame}" fill="none" stroke="{color}" stroke-width="{num(stroke)}" stroke-linecap="round"/>'
            f'<path d="{gear}" fill="{color}" fill-rule="evenodd"/>')


def mark_svg(color: str = LOGO_ACCENT_ON_LIGHT, variant: str = "regular", *, centered: bool = False) -> str:
    view_box = "0.5 -0.5 24 24" if centered else "0 0 24 24"
    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{view_box}">{mark_markup(color, variant)}</svg>'


def squircle_path(size: float, radius: float, smoothing: float = 0.6) -> str:
    """Rounded square with continuous (Figma-style smoothed) corners, the macOS icon shape."""
    p = min((1 + smoothing) * radius, size / 2)
    smoothing = p / radius - 1
    arc = 90 * (1 - smoothing)
    chord = math.sin(math.radians(arc / 2)) * radius * math.sqrt(2)
    tangent = radius * math.tan(math.radians((90 - arc) / 4))
    beta = 45 * smoothing
    c = tangent * math.cos(math.radians(beta))
    d = c * math.tan(math.radians(beta))
    b = (p - chord - c - d) / 3
    a = 2 * b
    local = [(a, 0), (a + b, 0), (a + b + c, d), (chord, chord), (d, c), (d, b + c), (d, a + b + c)]

    def corner(sx: int, sy: int, swap: bool) -> str:
        pts = [((y if swap else x) * sx, (x if swap else y) * sy) for x, y in local]
        c1, arc_to, c2 = pts[:3], pts[3], pts[4:]
        return (f"c{num(c1[0][0])} {num(c1[0][1])} {num(c1[1][0])} {num(c1[1][1])} {num(c1[2][0])} {num(c1[2][1])}"
                f"a{num(radius)} {num(radius)} 0 0 1 {num(arc_to[0])} {num(arc_to[1])}"
                f"c{num(c2[0][0])} {num(c2[0][1])} {num(c2[1][0])} {num(c2[1][1])} {num(c2[2][0])} {num(c2[2][1])}")

    return (f"M{num(size - p)} 0" + corner(1, 1, False) + f"L{num(size)} {num(size - p)}" + corner(-1, 1, True)
            + f"L{num(p)} {num(size)}" + corner(-1, -1, False) + f"L0 {num(p)}" + corner(1, -1, True) + "Z")


def pumpkin_markup() -> tuple[str, str]:
    """(gradient defs, shapes) of the jack-o'-lantern: lit from the upper left, its face aglow."""
    cy = PUMPKIN["cy"]

    def lobe(cx: float, rx: float, ry: float) -> str:
        return (f'M{num(cx - rx)} {num(cy)}A{num(rx)} {num(ry)} 0 1 0 {num(cx + rx)} {num(cy)}'
                f'A{num(rx)} {num(ry)} 0 1 0 {num(cx - rx)} {num(cy)}Z')

    def polygon(points) -> str:
        return "M" + "L".join(f"{num(x)} {num(y)}" for x, y in points)

    *sides, middle = PUMPKIN["lobes"]
    mouth = polygon(PUMPKIN["mouth"]) + "Q{} {} {} {}Z".format(
        *map(num, (*PUMPKIN["mouth_curve"], *PUMPKIN["mouth"][0])))
    face = "".join(polygon(eye) + "Z" for eye in PUMPKIN["eyes"]) + mouth
    defs = (
        '<radialGradient id="pk-side" gradientUnits="userSpaceOnUse" cx="4.4" cy="16.6" r="7.5">'
        '<stop offset="0" stop-color="#f6802a"/><stop offset="1" stop-color="#9c3a08"/></radialGradient>'
        '<radialGradient id="pk-middle" gradientUnits="userSpaceOnUse" cx="5.1" cy="15.9" r="6.6">'
        '<stop offset="0" stop-color="#ffa850"/><stop offset="1" stop-color="#d65a0c"/></radialGradient>'
        '<radialGradient id="pk-glow" gradientUnits="userSpaceOnUse" cx="5.9" cy="18.9" r="3.2">'
        '<stop offset="0" stop-color="#fff4c2"/><stop offset="1" stop-color="#ffb52e"/></radialGradient>')
    shapes = (f'<path d="{PUMPKIN["stem"]}" fill="#a3ad62"/>'
              + "".join(f'<path d="{lobe(*side)}" fill="url(#pk-side)"/>' for side in sides)
              + f'<path d="{lobe(*middle)}" fill="url(#pk-middle)"/>'
              + f'<path d="{face}" fill="url(#pk-glow)"/>')
    return defs, shapes


def icon_svg(variant: str = "regular", bleed: bool = False, square: bool = False,
             *, layer: str | None = None, appearance: str = "day") -> str:
    """Website icon, or a transparent layer for the native app icon: `screen`, `mark`, or for
    a seasonal icon `frame`, `pumpkin` and `panel` (the screen's outline in black, a mask).

    `bleed` drops the macOS margin; `square` also drops the rounded corners.
    """
    size = ICON_CANVAS
    box = size if bleed or square or layer is not None else ICON_INSET_BOX
    offset = (size - box) / 2
    spec = VARIANTS[variant]
    _, gear, stroke = mark_parts(variant)
    scale = box * 0.82 / 24
    # Centre every icon on the display frame; the gear extends below and to its left.
    anchor_x = (FRAME["left"] + FRAME["right"]) / 2
    anchor_y = (FRAME["top"] + FRAME["bottom"]) / 2
    tx = size / 2 - anchor_x * scale
    ty = size / 2 - anchor_y * scale
    background = "#000" if appearance == "night" else "#fff"
    foreground = LOGO_ACCENT_ON_LIGHT if appearance == "minimal" else "#fff" if appearance == "night" else "#000"
    if square:
        shape = f'<rect width="{size}" height="{size}" fill="{background}"/>'
    else:
        shape = (f'<path transform="translate({num(offset)} {num(offset)})" '
                 f'd="{squircle_path(box, box * SQUIRCLE_RADIUS)}" fill="{background}"/>')
    # Tuck the panel under the frame to avoid an antialiased background seam.
    inset = stroke / 2 - 0.08
    left, top = FRAME["left"] + inset, FRAME["top"] + inset
    right, bottom = FRAME["right"] - inset, FRAME["bottom"] - inset
    radius = FRAME["radius"] - inset
    gap = spec["radius"] + spec["pad"] * 0.55
    cx, cy = GEAR_CENTER
    notch_top = cy - math.sqrt(gap ** 2 - (left - cx) ** 2)
    notch_right = cx + math.sqrt(gap ** 2 - (bottom - cy) ** 2)
    # A real contour survives Icon Composer's SVG import; a luminance mask does not.
    panel = (f'M{num(left)} {num(notch_top)}V{num(top + radius)}'
             f'A{num(radius)} {num(radius)} 0 0 1 {num(left + radius)} {num(top)}'
             f'H{num(right - radius)}A{num(radius)} {num(radius)} 0 0 1 {num(right)} {num(top + radius)}'
             f'V{num(bottom - radius)}A{num(radius)} {num(radius)} 0 0 1 {num(right - radius)} {num(bottom)}'
             f'H{num(notch_right)}A{num(gap)} {num(gap)} 0 0 0 {num(left)} {num(notch_top)}Z')
    defs = (
        f'<linearGradient id="wp" gradientUnits="userSpaceOnUse" x1="5" y1="4" x2="20" y2="19">'
        f'<stop offset="0" stop-color="{AURORA[0]}"/><stop offset=".45" stop-color="{AURORA[1]}"/>'
        f'<stop offset="1" stop-color="{AURORA[2]}"/></linearGradient>'
        '<radialGradient id="glow" gradientUnits="userSpaceOnUse" cx="17.5" cy="6.5" r="9">'
        '<stop offset="0" stop-color="#fff" stop-opacity=".5"/><stop offset="1" stop-color="#fff" stop-opacity="0"/></radialGradient>')
    screen = f'<path d="{panel}" fill="url(#wp)"/><path d="{panel}" fill="url(#glow)"/>'
    frame = frame_outline_path(spec["radius"] + spec["pad"], stroke)
    if layer == "mark":
        mark = f'<path d="{frame}" fill="#fff"/><path d="{gear}" fill="#fff" fill-rule="evenodd"/>'
    elif layer == "frame":
        mark = f'<path d="{frame}" fill="#fff"/>'
    elif layer == "pumpkin":
        pumpkin_defs, mark = pumpkin_markup()
        defs += pumpkin_defs
    elif layer == "panel":
        mark = f'<path d="{panel}" fill="#000"/>'
    else:
        mark = mark_markup(foreground, variant)
    artwork = (screen if layer == "screen"
               else mark if layer in ("mark", "frame", "pumpkin", "panel") or appearance == "minimal"
               else screen + mark)
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{size}" height="{size}" viewBox="0 0 {size} {size}">'
            f'<defs>{defs}</defs>{shape if layer is None else ""}'
            f'<g transform="translate({num(tx)} {num(ty)}) scale({num(scale)})">{artwork}</g></svg>')


def tray_svg() -> str:
    """Template image for the status item: black mark, transparent elsewhere; AppKit tints it."""
    return mark_svg("#000", "small")


def logo_svg(ink: str, accent: str) -> str:
    """Horizontal lockup: mark, then "Wallpaper Machine" on one line, cap-height aligned."""
    cap = 72.0  # Manrope cap height at 100 px
    scale = cap / (FRAME["bottom"] - FRAME["top"]) * 1.18
    x0, y0, x1, y1 = MARK_BOX
    text_x = x1 * scale + 30
    word_gap = 9
    width = text_x + WALLPAPER_ADVANCE + word_gap + MACHINE_ADVANCE + 6
    height = 24 * scale
    baseline = (FRAME["top"] + FRAME["bottom"]) / 2 * scale + cap / 2
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {num(width)} {num(height)}" '
            f'role="img" aria-label="Wallpaper Machine">'
            f'<g transform="scale({num(scale)})">{mark_markup(accent)}</g>'
            f'<g transform="translate({num(text_x)} {num(baseline)})" fill="{ink}"><path d="{WALLPAPER_PATH}"/>'
            f'<path transform="translate({num(WALLPAPER_ADVANCE + word_gap)} 0)" fill-opacity=".74" d="{MACHINE_PATH}"/></g></svg>')


def rasterize(svg: str, sizes: dict[Path, int], work: Path, source: int = ICON_CANVAS,
              template: bool = False) -> None:
    """Draw with Quick Look and resize; template exports turn black-on-white into alpha."""
    stem = work / f"{abs(hash(svg))}.svg"
    stem.write_text(svg)
    subprocess.run(["qlmanage", "-t", "-s", str(source), "-o", str(work), str(stem)],
                   check=True, capture_output=True)
    master = stem.with_name(stem.name + ".png")
    if not master.exists():
        raise RuntimeError("qlmanage produced no thumbnail")
    for target, px in sizes.items():
        target.parent.mkdir(parents=True, exist_ok=True)
        if px == source:
            shutil.copyfile(master, target)
        else:
            subprocess.run(["sips", "-z", str(px), str(px), str(master), "--out", str(target)],
                           check=True, capture_output=True)
    if template:
        # Quick Look flattens SVG transparency onto white. Recover coverage, including
        # antialiased edges and enclosed holes, rather than keying out only pure white.
        subprocess.run(["swift", "-e", r'''
import AppKit
for path in CommandLine.arguments.dropFirst() {
    guard let image = NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: path))),
          let output = NSBitmapImageRep(bitmapDataPlanes: nil,
              pixelsWide: image.pixelsWide, pixelsHigh: image.pixelsHigh,
              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
              isPlanar: false, colorSpaceName: .deviceRGB,
              bitmapFormat: .alphaNonpremultiplied, bytesPerRow: 0, bitsPerPixel: 0)
    else { fatalError("Cannot decode template image: \(path)") }
    for y in 0..<image.pixelsHigh {
        for x in 0..<image.pixelsWide {
            guard let color = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
            else { fatalError("Cannot read template pixel") }
            output.setColor(NSColor(deviceRed: 0, green: 0, blue: 0,
                alpha: (1 - color.redComponent) * color.alphaComponent), atX: x, y: y)
        }
    }
    guard let png = output.representation(using: .png, properties: [:])
    else { fatalError("Cannot encode template image: \(path)") }
    try png.write(to: URL(fileURLWithPath: path))
}
''', *map(str, sizes)], check=True, capture_output=True)


def ico_bytes(pngs: list[tuple[int, bytes]]) -> bytes:
    """A Windows ICO container holding PNG-encoded images (supported since Vista)."""
    header = struct.pack("<HHH", 0, 1, len(pngs))
    offset = len(header) + 16 * len(pngs)
    entries, blobs = [], []
    for px, data in pngs:
        entries.append(struct.pack("<BBBBHHII", px % 256, px % 256, 0, 0, 1, 32, len(data), offset))
        blobs.append(data)
        offset += len(data)
    return header + b"".join(entries) + b"".join(blobs)


def write_app_icons(work: Path) -> list[Path]:
    assets = APP_ICON / "Assets"
    assets.mkdir(parents=True, exist_ok=True)
    written = []
    for layer in ("screen", "mark"):
        path = assets / f"{layer}.svg"
        path.write_text(icon_svg(layer=layer))
        written.append(path)
    document = {
        "fill-specializations": [
            {"value": {"solid": "srgb:1,1,1,1"}},
            {"appearance": "dark", "value": {"solid": "srgb:0,0,0,1"}},
        ],
        "groups": [{
            "layers": [
                {"image-name": "screen.svg", "name": "Wallpaper", "glass": False},
                {"image-name": "mark.svg", "name": "Frame and gear", "glass": False,
                 "fill-specializations": [
                     {"value": {"solid": "srgb:0,0,0,1"}},
                     {"appearance": "dark", "value": {"solid": "srgb:1,1,1,1"}},
                 ]},
            ],
            "lighting": "individual",
            "shadow": {"kind": "neutral", "opacity": 0},
            "specular": False,
            "translucency": {"enabled": False, "value": 0},
        }],
        "supported-platforms": {"squares": ["macOS"]},
    }
    path = APP_ICON / "icon.json"
    path.write_text(json.dumps(document, indent=2) + "\n")
    written.append(path)
    tray = {TRAY_ICON_SET / name: px for name, px in TRAY_ICON_SIZES.items()}
    rasterize(tray_svg(), tray, work, source=256, template=True)
    return written + list(tray)


def write_dock_icons(work: Path) -> list[Path]:
    """Render fixed Dock appearances with the same outer margin as the compiled app icon."""
    tool = ictool()
    minimal = work / "Minimal.icon"
    (minimal / "Assets").mkdir(parents=True, exist_ok=True)
    (minimal / "Assets/mark.svg").write_text(icon_svg(layer="mark"))
    document = json.loads((APP_ICON / "icon.json").read_text())
    document["fill-specializations"] = [{"value": {"solid": "srgb:1,1,1,1"}}]
    blue = ",".join(num(int(LOGO_ACCENT_ON_LIGHT[i:i + 2], 16) / 255) for i in (1, 3, 5))
    document["groups"][0]["layers"] = [{
        "image-name": "mark.svg", "name": "Minimal mark", "glass": False,
        "fill-specializations": [{"value": {"solid": f"srgb:{blue},1"}}],
    }]
    (minimal / "icon.json").write_text(json.dumps(document, indent=2) + "\n")
    paths = []
    for name, source, rendition in (("minimal", minimal, "Default"),
                                    ("day", APP_ICON, "Default"), ("night", APP_ICON, "Dark")):
        paths.extend(export_dock_tile(tool, source, rendition, work / f"dock-{name}.png", dock_icon(name)))
    add_dock_margins(paths)
    return paths[1::2]


def ictool() -> Path:
    developer = Path(subprocess.check_output(["xcode-select", "-p"], text=True).strip())
    return developer.parent / "Applications/Icon Composer.app/Contents/Executables/ictool"


def export_dock_tile(tool: Path, source: Path, rendition: str, image: Path, target: Path) -> tuple[Path, Path]:
    """Render one appearance of an Icon Composer document as the full-bleed tile `image`."""
    subprocess.run([str(tool), str(source), "--export-image", "--output-file", str(image),
                    "--platform", "macOS", "--rendition", rendition,
                    "--width", str(ICON_INSET_BOX), "--height", str(ICON_INSET_BOX),
                    "--scale", "1", "--design-generation", "26"], check=True, capture_output=True)
    target.parent.mkdir(parents=True, exist_ok=True)
    return image, target


def write_seasonal_dock_icons(work: Path) -> list[Path]:
    """The Halloween Dock icon: the Night tile, the papercut night clipped to the screen panel
    and a jack-o'-lantern in the gear's place (`AppThemeStore.dockIconName` while it is on)."""
    document_dir = work / "Halloween.icon"
    assets = document_dir / "Assets"
    assets.mkdir(parents=True, exist_ok=True)
    (assets / "frame.svg").write_text(icon_svg(layer="frame"))
    (assets / "pumpkin.svg").write_text(icon_svg(layer="pumpkin"))
    mask = work / "halloween-panel-mask.png"
    rasterize(icon_svg(layer="panel"), {mask: ICON_CANVAS}, work, template=True)
    # The panel's bounds on the 1024 canvas, as `icon_svg` places the layers.
    stroke = VARIANTS["regular"]["stroke"]
    inset = stroke / 2 - 0.08
    scale = ICON_CANVAS * 0.82 / 24
    x0 = ICON_CANVAS / 2 + (FRAME["left"] + inset - (FRAME["left"] + FRAME["right"]) / 2) * scale
    y0 = ICON_CANVAS / 2 + (FRAME["top"] + inset - (FRAME["top"] + FRAME["bottom"]) / 2) * scale
    side = (FRAME["right"] - FRAME["left"] - 2 * inset) * scale
    subprocess.run(["swift", "-e", r'''
import AppKit
let arguments = CommandLine.arguments
func load(_ path: String) -> CGImage {
    guard let image = NSBitmapImageRep(data: try! Data(contentsOf: URL(fileURLWithPath: path)))?.cgImage
    else { fatalError("Cannot decode \(path)") }
    return image
}
let scene = load(arguments[1]), mask = load(arguments[2])
let canvas = mask.width
let box = arguments[4...7].map { CGFloat(Double($0)!) }
guard let space = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(data: nil, width: canvas, height: canvas, bitsPerComponent: 8, bytesPerRow: 0,
          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
else { fatalError("Cannot create the panel canvas") }
// Fill the panel's square with the painting, then keep only what the panel's outline covers.
let target = CGRect(x: box[0], y: CGFloat(canvas) - box[1] - box[2], width: box[2], height: box[2])
let fill = max(target.width / CGFloat(scene.width), target.height / CGFloat(scene.height))
let size = CGSize(width: CGFloat(scene.width) * fill, height: CGFloat(scene.height) * fill)
context.interpolationQuality = .high
context.draw(scene, in: CGRect(x: target.midX - size.width / 2, y: target.midY - size.height / 2,
                               width: size.width, height: size.height))
context.setBlendMode(.destinationIn)
context.draw(mask, in: CGRect(x: 0, y: 0, width: canvas, height: canvas))
guard let panel = context.makeImage(),
      let png = NSBitmapImageRep(cgImage: panel).representation(using: .png, properties: [:])
else { fatalError("Cannot encode the panel") }
try png.write(to: URL(fileURLWithPath: arguments[3]))
''', str(SEASONAL / "halloween-night.jpg"), str(mask), str(assets / "screen.png"),
                    *(f"{value:.3f}" for value in (x0, y0, side, side))], check=True, capture_output=True)
    document = json.loads((APP_ICON / "icon.json").read_text())
    document["fill-specializations"] = [{"value": {"solid": "srgb:0,0,0,1"}}]
    document["groups"][0]["layers"] = [
        {"image-name": "screen.png", "name": "Halloween night", "glass": False},
        {"image-name": "frame.svg", "name": "Frame", "glass": False,
         "fill-specializations": [{"value": {"solid": "srgb:1,1,1,1"}}]},
        {"image-name": "pumpkin.svg", "name": "Jack-o'-lantern", "glass": False},
    ]
    (document_dir / "icon.json").write_text(json.dumps(document, indent=2) + "\n")
    paths = list(export_dock_tile(ictool(), document_dir, "Default", work / "dock-halloween.png",
                                  dock_icon("halloween")))
    add_dock_margins(paths)
    return paths[1::2]


def add_dock_margins(paths: list[Path]) -> None:
    """Pairs of (full-bleed tile, Dock image): centre each tile on a transparent 1024 canvas."""
    # Icon Composer exports a full-bleed tile. NSApplication's replacement image needs
    # the transparent margin normally added by actool, not Quick Look's white matte.
    subprocess.run(["swift", "-e", r'''
import AppKit
let canvas = Int(CommandLine.arguments[1])!
let tile = Int(CommandLine.arguments[2])!
for index in stride(from: 3, to: CommandLine.arguments.count, by: 2) {
    let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[index]))
    guard let image = NSBitmapImageRep(data: data)?.cgImage,
          let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil, width: canvas, height: canvas, bitsPerComponent: 8,
              bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fatalError("Cannot decode Dock icon") }
    context.clear(CGRect(x: 0, y: 0, width: canvas, height: canvas))
    let margin = (canvas - tile) / 2
    context.draw(image, in: CGRect(x: margin, y: margin, width: tile, height: tile))
    guard let rendered = context.makeImage(),
          let png = NSBitmapImageRep(cgImage: rendered).representation(using: .png, properties: [:])
    else { fatalError("Cannot encode Dock icon") }
    try png.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
}
''', str(ICON_CANVAS), str(ICON_INSET_BOX), *map(str, paths)], check=True, capture_output=True)


def write_website(site: Path, work: Path) -> list[Path]:
    brand = site / "brand"
    brand.mkdir(parents=True, exist_ok=True)
    files = {
        brand / "mark.svg": mark_svg(centered=True),
        brand / "logo.svg": logo_svg(LOGO_INK_ON_LIGHT, LOGO_ACCENT_ON_LIGHT),
        brand / "logo-dark.svg": logo_svg(LOGO_INK_ON_DARK, LOGO_ACCENT_ON_DARK),
        brand / "app-icon.svg": icon_svg(),
        site / "favicon.svg": icon_svg(bleed=True),
        site / "site.webmanifest": json.dumps({
            "name": "Wallpaper Machine", "short_name": "WallpaperMachine",
            "icons": [{"src": "/icon-192.png", "sizes": "192x192", "type": "image/png"},
                      {"src": "/icon-512.png", "sizes": "512x512", "type": "image/png"}],
            "theme_color": FAVICON_BACKGROUND, "background_color": FAVICON_BACKGROUND, "display": "standalone",
        }, indent=2) + "\n",
    }
    for appearance in ("minimal", "day", "night"):
        files[brand / f"app-icon-{appearance}.svg"] = icon_svg(appearance=appearance)
    for path, text in files.items():
        path.write_text(text)
    images = []
    for appearance in ("minimal", "day", "night"):
        target = brand / f"app-icon-{appearance}.png"
        shutil.copyfile(dock_icon(appearance), target)
        images.append(target)
    shutil.copyfile(brand / "app-icon-day.png", brand / "app-icon.png")
    # Crop only the native transparent margin; preserve the tile's transparent corners.
    favicon = work / "favicon.png"
    subprocess.run(["sips", "--cropToHeightWidth", str(ICON_INSET_BOX), str(ICON_INSET_BOX),
                    str(brand / "app-icon-day.png"), "--out", str(favicon)], check=True, capture_output=True)
    for px, folder in ((16, site), (32, site), (48, work)):
        subprocess.run(["sips", "-z", str(px), str(px), str(favicon), "--out", str(folder / f"favicon-{px}.png")],
                       check=True, capture_output=True)
    rasterize(icon_svg(square=True), {site / "apple-touch-icon.png": 180, site / "icon-192.png": 192,
                                      site / "icon-512.png": 512}, work)
    ico = site / "favicon.ico"
    ico.write_bytes(ico_bytes([(px, (folder / name).read_bytes()) for px, folder, name in (
        (16, site, "favicon-16.png"), (32, site, "favicon-32.png"), (48, work, "favicon-48.png"))]))
    return list(files) + images + [brand / "app-icon.png", site / "favicon-16.png", site / "favicon-32.png",
                          site / "apple-touch-icon.png", site / "icon-192.png", site / "icon-512.png", ico]


def write_dmg_background(work: Path) -> list[Path]:
    """Draw the disk-image window background at 1x and 2x from one vector description.

    Finder shows the image from the top-left of the content area, hides its bottom rows
    under the title bar and draws black icon labels without a halo, so the field stays
    light everywhere, text keeps clear of the top and bottom edges, and the icon slots stay
    empty (macOS 26.1 sometimes draws the Applications symlink blank).
    """
    targets = [DMG_BACKGROUND, DMG_BACKGROUND.with_name(f"{DMG_BACKGROUND.stem}@2x{DMG_BACKGROUND.suffix}")]
    staged = [work / target.name for target in targets]
    spec = {
        "window": WINDOW, "iconSize": ICON_SIZE,
        "appCenter": APP_ICON_CENTER, "applicationsCenter": APPLICATIONS_ICON_CENTER,
        "aurora": AURORA, "ink": LOGO_INK_ON_LIGHT, "field": DMG_FIELD, "note": DMG_NOTE,
        "headline": DMG_HEADLINE, "footnote": DMG_FOOTNOTE,
        "outputs": [str(path) for path in staged],
    }
    subprocess.run(["swift", "-e", r'''
import AppKit
import ImageIO
import UniformTypeIdentifiers

struct Spec: Decodable {
    let window: [CGFloat], iconSize: CGFloat
    let appCenter: [CGFloat], applicationsCenter: [CGFloat]
    let aurora: [String], ink: String, field: [String], note: String
    let headline: String, footnote: [String]
    let outputs: [String]
}
let spec = try JSONDecoder().decode(Spec.self, from: CommandLine.arguments[1].data(using: .utf8)!)
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
let (width, height) = (spec.window[0], spec.window[1])

func color(_ hex: String, alpha: CGFloat = 1) -> CGColor {
    let value = UInt32(hex.dropFirst(), radix: 16)!
    return CGColor(colorSpace: srgb, components: [CGFloat(value >> 16 & 255) / 255,
        CGFloat(value >> 8 & 255) / 255, CGFloat(value & 255) / 255, alpha])!
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: srgb, colors: colors as CFArray, locations: locations)!
}

/// A soft elliptical bloom: alpha falls off quadratically so its edge never reads as a ring.
func bloom(_ ctx: CGContext, _ hex: String, at center: CGPoint, radius: CGSize, alpha: CGFloat) {
    let stops: [CGFloat] = [0, 0.25, 0.5, 0.75, 1]
    let fade = gradient(stops.map { color(hex, alpha: alpha * (1 - $0) * (1 - $0)) }, stops)
    ctx.saveGState()
    ctx.translateBy(x: center.x, y: center.y)
    ctx.scaleBy(x: 1, y: radius.height / radius.width)
    ctx.drawRadialGradient(fade, startCenter: .zero, startRadius: 0, endCenter: .zero,
                           endRadius: radius.width, options: [])
    ctx.restoreGState()
}

/// `*…*` runs are set in medium weight; everything else in `weight`.
func line(_ text: String, size: CGFloat, weight: NSFont.Weight, color: CGColor) -> CTLine {
    let styled = NSMutableAttributedString()
    for (index, run) in text.components(separatedBy: "*").enumerated() {
        styled.append(NSAttributedString(string: run, attributes: [
            kCTFontAttributeName as NSAttributedString.Key:
                NSFont.systemFont(ofSize: size, weight: index % 2 == 1 ? .medium : weight),
            kCTForegroundColorAttributeName as NSAttributedString.Key: color]))
    }
    return CTLineCreateWithAttributedString(styled)
}

func drawCentered(_ ctx: CGContext, _ line: CTLine, x: CGFloat, baseline: CGFloat) {
    let advance = CTLineGetTypographicBounds(line, nil, nil, nil)
    ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)  // upright glyphs in the flipped space below
    ctx.textPosition = CGPoint(x: x - advance / 2, y: baseline)
    CTLineDraw(line, ctx)
}

/// Everything is described in points from the top-left corner of the content area.
func draw(_ ctx: CGContext, scale: CGFloat) {
    ctx.scaleBy(x: scale, y: scale)
    ctx.translateBy(x: 0, y: height)
    ctx.scaleBy(x: 1, y: -1)
    ctx.setShouldSmoothFonts(false)  // grayscale antialiasing: no LCD fringes in the file
    ctx.setShouldSubpixelPositionFonts(true)
    ctx.setShouldSubpixelQuantizeFonts(false)

    ctx.drawLinearGradient(gradient([color(spec.field[0]), color(spec.field[1])], [0, 1]),
                           start: .zero, end: CGPoint(x: 0, y: height), options: [])
    // The aurora as light along the top edge, cyan to violet in the arrow's direction,
    // faded out above the icons so they and their labels sit on the plain field.
    bloom(ctx, spec.aurora[0], at: CGPoint(x: width * 0.2, y: 0), radius: CGSize(width: 380, height: 200), alpha: 0.5)
    bloom(ctx, spec.aurora[1], at: CGPoint(x: width * 0.5, y: -10), radius: CGSize(width: 420, height: 210), alpha: 0.27)
    bloom(ctx, spec.aurora[2], at: CGPoint(x: width * 0.8, y: 0), radius: CGSize(width: 380, height: 200), alpha: 0.22)

    // Drag cue: a thin arrow between the icon slots, cyan tail to violet head, with a faint glow.
    let y = spec.appCenter[1]
    let tail = spec.appCenter[0] + spec.iconSize / 2 + 28
    let head = spec.applicationsCenter[0] - spec.iconSize / 2 - 28
    let arrow = CGMutablePath()
    arrow.move(to: CGPoint(x: tail, y: y))
    arrow.addLine(to: CGPoint(x: head, y: y))
    arrow.move(to: CGPoint(x: head - 12, y: y - 12))
    arrow.addLine(to: CGPoint(x: head, y: y))
    arrow.addLine(to: CGPoint(x: head - 12, y: y + 12))
    for pass in 0..<2 {
        ctx.saveGState()
        ctx.addPath(arrow)
        ctx.setLineWidth(3)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        if pass == 0 {  // shadow geometry is in device space, hence the scale factor
            ctx.setShadow(offset: .zero, blur: 10 * scale, color: color(spec.aurora[1], alpha: 0.42))
            ctx.setStrokeColor(color(spec.aurora[1]))
            ctx.strokePath()
        } else {
            ctx.replacePathWithStrokedPath()
            ctx.clip()
            ctx.drawLinearGradient(gradient(spec.aurora.map { color($0) }, [0, 0.4, 1]),
                                   start: CGPoint(x: tail, y: 0), end: CGPoint(x: head, y: 0),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        ctx.restoreGState()
    }

    let iconTop = y - spec.iconSize / 2
    drawCentered(ctx, line(spec.headline, size: 18, weight: .semibold, color: color(spec.ink)),
                 x: width / 2, baseline: iconTop - 48)
    for (index, text) in spec.footnote.enumerated() {
        drawCentered(ctx, line(text, size: 11.5, weight: .regular, color: color(spec.note)),
                     x: width / 2, baseline: height - 82 + CGFloat(index) * 17)
    }
}

for (index, path) in spec.outputs.enumerated() {
    let scale = CGFloat(index + 1)
    guard let ctx = CGContext(data: nil, width: Int(width * scale), height: Int(height * scale),
                              bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { fatalError("Cannot create the background canvas") }
    draw(ctx, scale: scale)
    guard let image = ctx.makeImage(),
          let sink = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                     UTType.png.identifier as CFString, 1, nil)
    else { fatalError("Cannot encode the background") }
    CGImageDestinationAddImage(sink, image, [kCGImagePropertyDPIWidth: 72 * scale,
                                             kCGImagePropertyDPIHeight: 72 * scale] as CFDictionary)
    guard CGImageDestinationFinalize(sink) else { fatalError("Cannot write \(path)") }
}
''', json.dumps(spec)], check=True, capture_output=True)
    # The packager pairs the two files with the same check; fail here, where it is fixable.
    subprocess.run(["tiffutil", "-cathidpicheck", *map(str, staged), "-out", str(work / "background.tiff")],
                   check=True, capture_output=True)
    DMG_BACKGROUND.parent.mkdir(parents=True, exist_ok=True)
    for source, target in zip(staged, targets):
        shutil.copyfile(source, target)
    return targets


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--website", type=Path, help="also write logo, favicons and manifest into this directory")
    parser.add_argument("--skip-app", action="store_true", help="do not touch native app, Dock or tray assets")
    parser.add_argument("--dmg", action="store_true", help="write only the disk-image background pair (Packaging/dmg)")
    parser.add_argument("--seasonal", action="store_true", help="write only the seasonal Dock icons (AppIconHalloween)")
    args = parser.parse_args()
    if sys.platform != "darwin":
        print(f"{MARK.missing} brand.py rasterizes with qlmanage and sips; macOS only", file=sys.stderr)
        return 1
    with tempfile.TemporaryDirectory(prefix="brand-") as scratch:
        work = Path(scratch)
        if args.dmg:
            written = write_dmg_background(work)
        elif args.seasonal:
            written = write_seasonal_dock_icons(work)
        else:
            written = [] if args.skip_app else (write_app_icons(work) + write_dock_icons(work)
                                                + write_seasonal_dock_icons(work))
            written += write_dmg_background(work)
            if args.website:
                written += write_website(args.website.resolve(), work)
    for path in written:
        try:
            shown = path.relative_to(ROOT)
        except ValueError:
            shown = path
        print(f"{MARK.ok} {shown}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
