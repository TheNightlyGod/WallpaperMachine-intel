#!/usr/bin/env python3
"""Brand export contracts: native appearances, template alpha and ICO interoperability."""
import functools
import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import brand
from lib import dmg


@functools.cache
def ictool_skip_reason():
    """Why Icon Composer cannot export here, or None; headless CI runners exit 255."""
    if sys.platform != 'darwin':
        return 'Requires macOS Icon Composer'
    developer = Path(subprocess.check_output(['xcode-select', '-p'], text=True).strip())
    tool = developer.parent / 'Applications/Icon Composer.app/Contents/Executables/ictool'
    if not tool.exists():
        return f'Icon Composer not found at {tool}'
    with tempfile.TemporaryDirectory() as scratch:
        work = Path(scratch)
        icon = work / 'AppIcon.icon'
        with patch.object(brand, 'APP_ICON', icon), patch.object(brand, 'TRAY_ICON_SET', work / 'tray'):
            brand.write_app_icons(work)
        probe = subprocess.run([str(tool), str(icon), '--export-image', '--output-file', str(work / 'probe.png'),
                                '--platform', 'macOS', '--rendition', 'Default',
                                '--width', '16', '--height', '16', '--scale', '1',
                                '--design-generation', '26'], capture_output=True, text=True)
    if probe.returncode:
        detail = (probe.stderr or probe.stdout).strip().splitlines()
        return f'ictool cannot export in this session (exit {probe.returncode}): {detail[-1] if detail else "no output"}'
    return None


class BrandTests(unittest.TestCase):
    def test_ico_entries_locate_images_including_256_pixel_encoding(self):
        images = [(16, b'first-image'), (32, b'second-longer-image'), (256, b'largest-image')]
        data = brand.ico_bytes(images)
        self.assertEqual(struct.unpack_from('<HHH', data), (0, 1, 3))
        for i, (size, payload) in enumerate(images):
            w, h, colors, reserved, planes, bits, length, offset = struct.unpack_from('<BBBBHHII', data, 6 + i * 16)
            self.assertEqual((w or 256, h or 256), (size, size))
            self.assertEqual((planes, bits), (1, 32))
            self.assertEqual(data[offset:offset + length], payload)

    def test_app_icon_renders_one_background_per_appearance(self):
        if reason := ictool_skip_reason():
            self.skipTest(reason)
        developer = Path(subprocess.check_output(['xcode-select', '-p'], text=True).strip())
        tool = developer.parent / 'Applications/Icon Composer.app/Contents/Executables/ictool'
        with tempfile.TemporaryDirectory() as scratch:
            work = Path(scratch)
            icon = work / 'AppIcon.icon'
            with patch.object(brand, 'APP_ICON', icon), patch.object(brand, 'TRAY_ICON_SET', work / 'tray'):
                brand.write_app_icons(work)
            for rendition, background, foreground in [('Default', 1, 0), ('Dark', 0, 1)]:
                with self.subTest(appearance=rendition):
                    image = work / f'{rendition}.png'
                    subprocess.run([str(tool), str(icon), '--export-image', '--output-file', str(image),
                                    '--platform', 'macOS', '--rendition', rendition,
                                    '--width', '256', '--height', '256', '--scale', '1',
                                    '--design-generation', '26'],
                                   check=True, capture_output=True)
                    result = subprocess.run(['swift', '-e', r'''
import AppKit
let image = NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))!
let points = [(0, 0), (25, 128), (40, 128), (128, 48), (128, 128), (101, 155)]
let colors = points.map { x, y -> [Double] in
    let c = image.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
    return [c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent]
}
// Cross both screen/frame joins: neither may expose the appearance background.
let joins = ((48...96).map { (128, $0) } + (166...208).map { ($0, 128) }).map { x, y -> [Double] in
    let c = image.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
    return [c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent]
}
let foreground = Double(CommandLine.arguments[2])!
let edges = [false, true].map { vertical -> [Int] in
    let pixels = (0..<256).filter { p in
        let c = image.colorAt(x: vertical ? 128 : p, y: vertical ? p : 128)!.usingColorSpace(.sRGB)!
        return c.alphaComponent > 0.99 && [c.redComponent, c.greenComponent, c.blueComponent].allSatisfy {
            abs($0 - foreground) < 0.04
        }
    }
    return [pixels.first ?? -1, pixels.last ?? -1]
}
print(String(data: try JSONSerialization.data(withJSONObject: [colors, joins, edges]), encoding: .utf8)!)
''', str(image), str(foreground)], check=True, capture_output=True, text=True)
                    colors, joins, edges = json.loads(result.stdout)
                    for first, last in edges:
                        self.assertGreaterEqual(first, 0, 'Frame must be visible on each central axis')
                        self.assertAlmostEqual(first, 255 - last, delta=1,
                                               msg='Opposing display-frame margins must match')
                    corner, outer, inner, frame, screen, gear_clearance = colors
                    self.assertEqual(corner[3], 0, 'System mask must leave transparent corners')
                    for color in (outer, inner):
                        self.assertGreater(color[3], 0.99)
                        for channel in color[:3]:
                            self.assertAlmostEqual(channel, background, delta=0.04,
                                                   msg='No contrasting outer tile or inset background')
                    for channel in frame[:3]:
                        self.assertAlmostEqual(channel, foreground, delta=0.04,
                                               msg='Frame must contrast with its appearance background')
                    self.assertGreater(max(screen[:3]) - min(screen[:3]), 0.2,
                                       'Wallpaper panel must retain its color')
                    for channel in gear_clearance[:3]:
                        self.assertAlmostEqual(channel, background, delta=0.04,
                                               msg='Wallpaper must leave a clean cutout around the gear')
                    for color in joins:
                        self.assertGreater(color[3], 0.99)
                        self.assertGreater(max(abs(c - background) for c in color[:3]), 0.2,
                                           'Enlarged screen/frame joins must not expose a background seam')

    def test_dock_icons_are_the_asset_catalog_image_sets_the_app_loads(self):
        for name in ('minimal', 'day', 'night', 'halloween'):
            path = brand.dock_icon(name)
            with self.subTest(icon=name):
                self.assertEqual(path.parent.name, f'AppIcon{name.capitalize()}.imageset')
                contents = json.loads((path.parent / 'Contents.json').read_text())
                self.assertEqual([image['filename'] for image in contents['images']], [path.name])
                header = path.read_bytes()[:24]
                self.assertEqual(header[:8], b'\x89PNG\r\n\x1a\n')
                self.assertEqual(struct.unpack('>II', header[16:24]), (1024, 1024))

    def test_dock_variants_preserve_transparent_margin_and_distinct_artwork(self):
        if reason := ictool_skip_reason():
            self.skipTest(reason)
        with tempfile.TemporaryDirectory() as scratch:
            work = Path(scratch)
            with patch.object(brand, 'APP_ICON', work / 'AppIcon.icon'), \
                    patch.object(brand, 'TRAY_ICON_SET', work / 'tray'), \
                    patch.object(brand, 'DOCK_ICONS', work / 'dock'):
                brand.write_app_icons(work)
                paths = brand.write_dock_icons(work)
            result = subprocess.run(['swift', '-e', r'''
import AppKit
for path in CommandLine.arguments.dropFirst() {
    let image = NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: path)))!
    let points = [(0, 0), (50, 512), (512, 50), (180, 512), (512, 256), (512, 512), (327, 698)]
    let colors = points.map { x, y -> [Double] in
        let c = image.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
        return [c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent]
    }
    let frame = colors[4]
    let frameWidth = (180..<320).filter { y in
        let c = image.colorAt(x: 512, y: y)!.usingColorSpace(.sRGB)!
        return c.alphaComponent > 0.99 && zip([c.redComponent, c.greenComponent, c.blueComponent], frame.prefix(3))
            .allSatisfy { abs($0 - $1) < 0.04 }
    }.count
    print(String(data: try JSONSerialization.data(withJSONObject: [colors, frameWidth]), encoding: .utf8)!)
}
''', *map(str, paths)], check=True, capture_output=True, text=True)
            frame_widths = []
            for path, line in zip(paths, result.stdout.splitlines(), strict=True):
                with self.subTest(icon=path.stem):
                    colors, frame_width = json.loads(line)
                    frame_widths.append(frame_width)
                    self.assertGreater(frame_width, 0, 'Top frame must remain visible')
                    corner, left_margin, top_margin, background, frame, interior, hub = colors
                    for color in (corner, left_margin, top_margin):
                        self.assertEqual(color[3], 0, 'Dock margin must stay transparent, not white-matted')
                    expected_background = 0 if path.stem == 'night' else 1
                    for color in (background, hub):
                        self.assertGreater(color[3], 0.99)
                        for channel in color[:3]:
                            self.assertAlmostEqual(channel, expected_background, delta=0.04)
                    if path.stem == 'minimal':
                        self.assertGreater(frame[2], 0.75, 'Minimal mark must remain blue')
                        self.assertGreater(frame[2] - frame[1], 0.2)
                        self.assertGreater(frame[1] - frame[0], 0.2)
                        for channel in interior[:3]:
                            self.assertAlmostEqual(channel, 1, delta=0.04, msg='Minimal has no wallpaper fill')
                    else:
                        for channel in frame[:3]:
                            self.assertAlmostEqual(channel, 1 - expected_background, delta=0.04)
                        self.assertGreater(max(interior[:3]) - min(interior[:3]), 0.2,
                                           'Day and Night retain the colored wallpaper')
            # The wallpaper slightly overlaps the inner edge to avoid a seam;
            # allow three source pixels (under 0.3 px at picker size).
            self.assertLessEqual(max(frame_widths) - min(frame_widths), 3,
                                 'Dock variants must have consistent rendered frame thickness')

    def test_halloween_dock_icon_is_the_night_tile_with_its_night_and_a_pumpkin_for_the_gear(self):
        if reason := ictool_skip_reason():
            self.skipTest(reason)
        with tempfile.TemporaryDirectory() as scratch:
            work = Path(scratch)
            with patch.object(brand, 'APP_ICON', work / 'AppIcon.icon'), \
                    patch.object(brand, 'TRAY_ICON_SET', work / 'tray'), \
                    patch.object(brand, 'DOCK_ICONS', work / 'dock'):
                brand.write_app_icons(work)
                [path] = brand.write_seasonal_dock_icons(work)
            self.assertEqual(path.parent.name, 'AppIconHalloween.imageset')
            result = subprocess.run(['swift', '-e', r'''
import AppKit
let image = NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))!
// Margin, tile, top frame, panel interior, gear centre (the pumpkin) and the clearance above it.
let points = [(0, 0), (180, 512), (512, 256), (330, 330), (327, 698), (327, 560)]
let colors = points.map { x, y -> [Double] in
    let c = image.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
    return [c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent]
}
print(String(data: try JSONSerialization.data(withJSONObject: colors), encoding: .utf8)!)
''', str(path)], check=True, capture_output=True, text=True)
            margin, tile, frame, panel, pumpkin, clearance = json.loads(result.stdout)
            self.assertEqual(margin[3], 0, 'Dock margin must stay transparent')
            for color in (tile, clearance):
                self.assertGreater(color[3], 0.99)
                self.assertLess(max(color[:3]), 0.06, 'The Night tile, and its clean cutout above the pumpkin')
            for channel in frame[:3]:
                self.assertAlmostEqual(channel, 1, delta=0.04, msg='The frame stays white')
            self.assertGreater(panel[2], panel[1], 'The panel shows the violet night, not the aurora')
            self.assertGreater(panel[2], 0.08, 'The panel is painted, not the bare tile')
            red, green, blue, _ = pumpkin
            self.assertGreater(red, 0.8, 'A pumpkin stands where the gear was')
            self.assertGreater(red - green, 0.2)
            self.assertGreater(green - blue, 0.1)

    @unittest.skipUnless(sys.platform == 'darwin', 'Requires macOS image tools')
    def test_website_icon_centers_the_display_frame(self):
        with tempfile.TemporaryDirectory() as scratch:
            work = Path(scratch)
            image = work / 'website.png'
            brand.rasterize(brand.icon_svg(), {image: 256}, work)
            result = subprocess.run(['swift', '-e', r'''
import AppKit
let image = NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))!
let edges = [false, true].map { vertical -> [Int] in
    let length = vertical ? image.pixelsHigh : image.pixelsWide
    let pixels = (0..<length).filter { p in
        let c = image.colorAt(x: vertical ? image.pixelsWide / 2 : p,
                              y: vertical ? p : image.pixelsHigh / 2)!.usingColorSpace(.sRGB)!
        return c.alphaComponent > 0.99 && max(c.redComponent, c.greenComponent, c.blueComponent) < 0.04
    }
    return [length, pixels.first ?? -1, pixels.last ?? -1]
}
let center = image.colorAt(x: image.pixelsWide / 2, y: image.pixelsHigh / 2)!.usingColorSpace(.sRGB)!
let interior = [center.redComponent, center.greenComponent, center.blueComponent, center.alphaComponent]
print(String(data: try JSONSerialization.data(withJSONObject: [edges, interior]), encoding: .utf8)!)
''', str(image)], check=True, capture_output=True, text=True)
            edges, interior = json.loads(result.stdout)
            for length, first, last in edges:
                self.assertGreater(first, 0, 'Opaque display frame must leave an outer margin')
                self.assertLess(first, length / 2, 'Frame must extend before the center')
                self.assertGreater(last, length / 2, 'Frame must extend after the center')
                self.assertAlmostEqual(first, length - 1 - last, delta=1,
                                       msg='Opposing display-frame margins must match')
            self.assertGreater(interior[3], 0.99, 'Wallpaper interior must be opaque')
            self.assertGreater(max(interior[:3]) - min(interior[:3]), 0.2,
                               'Centered frame must surround a colored wallpaper, not a solid fill')

    @unittest.skipUnless(sys.platform == 'darwin', 'Requires macOS image tools')
    def test_tray_export_preserves_transparent_background_and_antialiasing(self):
        with tempfile.TemporaryDirectory() as scratch:
            work = Path(scratch)
            sizes = {work / name: px for name, px in brand.TRAY_ICON_SIZES.items()}
            brand.rasterize(brand.tray_svg(), sizes, work, source=256, template=True)
            result = subprocess.run(['swift', '-e', r'''
import AppKit
for path in CommandLine.arguments.dropFirst() {
    let image = NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: path)))!
    var alpha: [Int] = []
    for y in 0..<image.pixelsHigh {
        for x in 0..<image.pixelsWide {
            alpha.append(Int((image.colorAt(x: x, y: y)!.alphaComponent * 255).rounded()))
        }
    }
    let data = try JSONSerialization.data(withJSONObject: alpha)
    print(String(data: data, encoding: .utf8)!)
}
''', *map(str, sizes)], check=True, capture_output=True, text=True)
            for px, line in zip(sizes.values(), result.stdout.splitlines(), strict=True):
                with self.subTest(size=px):
                    alpha = json.loads(line)
                    self.assertEqual(len(alpha), px * px)
                    self.assertEqual(alpha[0], 0, 'Background must be transparent')
                    self.assertEqual(alpha[(px // 2) * px + px // 2], 0,
                                     'Display interior must be transparent')
                    self.assertEqual(max(alpha), 255, 'Glyph must remain opaque')
                    self.assertTrue(any(0 < a < 255 for a in alpha),
                                    'Preserve antialiased edges')

    @unittest.skipUnless(sys.platform == 'darwin', 'Requires macOS image tools')
    def test_dmg_background_pair_matches_window_geometry_and_keeps_icon_slots_light(self):
        with tempfile.TemporaryDirectory() as scratch:
            work = Path(scratch)
            with patch.object(brand, 'DMG_BACKGROUND', work / 'out/background.png'):
                paths = brand.write_dmg_background(work)
            self.assertEqual([p.name for p in paths], ['background.png', 'background@2x.png'])
            for scale, path in enumerate(paths, start=1):
                with self.subTest(scale=scale):
                    probe = subprocess.run(['sips', '-g', 'pixelWidth', '-g', 'pixelHeight', '-g', 'dpiWidth',
                                            '-g', 'hasAlpha', str(path)], check=True, capture_output=True, text=True)
                    values = dict(line.strip().split(': ') for line in probe.stdout.splitlines()[1:])
                    self.assertEqual((int(values['pixelWidth']), int(values['pixelHeight'])),
                                     (dmg.WINDOW[0] * scale, dmg.WINDOW[1] * scale),
                                     'Finder tiles a background whose size differs from the window')
                    self.assertEqual(float(values['dpiWidth']), 72 * scale, 'Retina pairing needs 72/144 dpi')
                    self.assertEqual(values['hasAlpha'], 'no')
            # Finder draws 13 pt black labels below the icons and may leave the Applications
            # slot empty: both slots and both label bands must stay plain, light field.
            half = dmg.ICON_SIZE // 2
            zones = [(cx - half, cy - half, cx + half, cy + half + 2 * dmg.LABEL_SIZE + 6)
                     for cx, cy in (dmg.APP_ICON_CENTER, dmg.APPLICATIONS_ICON_CENTER)]
            result = subprocess.run(['swift', '-e', r'''
import AppKit
let image = NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))!
let zones = CommandLine.arguments.dropFirst(2).map { $0.split(separator: ",").map { Int($0)! } }
var report: [[Double]] = []
for zone in zones {
    var low = 1.0, high = 0.0
    for y in zone[1]..<zone[3] {
        for x in zone[0]..<zone[2] {
            let c = image.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
            let l = 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
            low = min(low, l); high = max(high, l)
        }
    }
    report.append([low, high])
}
print(String(data: try JSONSerialization.data(withJSONObject: report), encoding: .utf8)!)
''', str(paths[0]), *(','.join(map(str, zone)) for zone in zones)], check=True, capture_output=True, text=True)
            for zone, (low, high) in zip(zones, json.loads(result.stdout), strict=True):
                with self.subTest(zone=zone):
                    self.assertGreater(low, 0.85, 'Black Finder labels need a light field')
                    self.assertLess(high - low, 0.08, 'Icon slots must stay free of plates, rings or drop zones')

if __name__ == '__main__':
    unittest.main()
