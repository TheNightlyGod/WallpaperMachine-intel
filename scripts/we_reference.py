#!/usr/bin/env python3
"""Compare scene wallpapers with Wallpaper Engine's own frames, captured in a Parallels Windows VM.

capture  serves the wallpapers to a worker inside the VM, which opens each one in
         Wallpaper Engine (muted), hides the desktop icons, minimises every window,
         centres the cursor and uploads two screenshots at physical pixels, about 8 s
         and 15 s after opening. Run the PowerShell line it prints in the VM.
render   draws the same wallpapers with Native Metal at the screenshots' size, scene
         time and time of day (`metal_scene_draw_smoke`'s renderer comparison, Native Metal only).
compare  writes side-by-side sheets (Wallpaper Engine | each render | difference to the
         last render) cropped to the Windows work area, and coarse metrics.

A wallpaper is a Workshop id in the app's library or a folder holding project.json.
Screenshots are shared by every worktree in the main checkout's
artifacts/we-reference/shots/; renders and sheets go to this tree's
artifacts/we-reference/. See docs/testing/wallpaper-engine-reference.md.
"""
from __future__ import annotations

import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import math
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse

from lib.glyphs import markers
from lib.paths import ARTIFACTS, RENDERER_ARTIFACTS, main_checkout

MARK = markers()
OUTPUT = ARTIFACTS / "we-reference"
SHOTS = main_checkout() / "artifacts/we-reference/shots"
APP_HOME = Path(os.environ.get("WALLPAPER_MACHINE_HOME")
                or Path.home() / "Library/Application Support/WallpaperMachine")
LIBRARY = APP_HOME / "Library"
ASSETS = APP_HOME / "SceneAssets"
BINARY = RENDERER_ARTIFACTS / "bin/tests/metal_scene_draw_smoke"
# The Mac's address on the Parallels "Shared" network, the VM's default gateway.
HOST, PORT = "10.211.55.2", 8765
SHOT_DELAYS = (8, 7)            # seconds after opening, then after the first shot
DEFAULT_TIMES = (8.0, 15.0)     # scene time of each shot when a capture did not record it
STEP = 1.0 / 30.0
SHEET_WIDTH, METRIC_WIDTH = 640, 256

WORKER = r"""
& {
# Wallpaper Engine reference capture (scripts/we_reference.py on the Mac). Talks only
# to the Mac at __SERVER__ and keeps Wallpaper Engine muted throughout.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$srv = '__SERVER__'
$root = Join-Path $env:LOCALAPPDATA 'we-reference'
function Log($message) {
    $line = '{0} {1}' -f (Get-Date -Format s), $message
    Write-Host $line
    try { Invoke-RestMethod -Method Post -Uri "$srv/log" -Body $line | Out-Null } catch {}
}
function Now { [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
if (-not ('WeReferenceScreen' -as [type])) {
    Add-Type -AssemblyName System.Drawing, System.Windows.Forms
    Add-Type 'using System; using System.Runtime.InteropServices;
public static class WeReferenceScreen {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern int GetSystemMetrics(int index);
}'
}
[WeReferenceScreen]::SetProcessDPIAware() | Out-Null
$we = $null
$candidates = @((Join-Path ${env:ProgramFiles(x86)} 'Steam\steamapps\common\wallpaper_engine\wallpaper64.exe'),
                (Join-Path $env:ProgramFiles 'Steam\steamapps\common\wallpaper_engine\wallpaper64.exe'))
$steam = Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue
if ($steam -and $steam.SteamPath) {
    $candidates += (Join-Path ($steam.SteamPath -replace '/', '\') 'steamapps\common\wallpaper_engine\wallpaper64.exe')
}
foreach ($c in $candidates) { if ($c -and (Test-Path $c)) { $we = $c; break } }
if (-not $we) { Log 'wallpaper64.exe not found'; Invoke-RestMethod -Method Post -Uri "$srv/abort" -Body 'wallpaper64.exe not found' | Out-Null; return }
if (-not (Get-Process wallpaper64 -ErrorAction SilentlyContinue)) {
    # Mute as soon as it answers commands (it resumes its last wallpaper), then let it settle.
    Log 'starting Wallpaper Engine'; Start-Process $we; Start-Sleep -Seconds 5
    & $we -control mute; Start-Sleep -Seconds 20
}
& $we -control mute
Log "Wallpaper Engine: $we"
while ($true) {
    $job = Invoke-RestMethod "$srv/next"
    if ($job.done) { break }
    $id = $job.id
    try {
        $dir = Join-Path $root $id
        foreach ($f in $job.files) {
            $dest = Join-Path $dir ($f.path -replace '/', '\')
            New-Item -ItemType Directory -Force -Path (Split-Path $dest) | Out-Null
            if (-not (Test-Path -LiteralPath $dest) -or (Get-Item -LiteralPath $dest).Length -ne $f.size) {
                $rel = ($f.path -split '/' | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'
                Invoke-WebRequest -UseBasicParsing -Uri "$srv/file/$id/$rel" -OutFile $dest
            }
        }
        # Physical pixels: the process is DPI aware and GetSystemMetrics answers for it.
        $b = New-Object System.Drawing.Rectangle 0, 0, ([WeReferenceScreen]::GetSystemMetrics(0)), ([WeReferenceScreen]::GetSystemMetrics(1))
        $w = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
        $cx = [int]($b.Width / 2); $cy = [int]($b.Height / 2)
        [WeReferenceScreen]::SetCursorPos($cx, $cy) | Out-Null
        Log "opening $id"
        & $we -control mute
        & $we -control play
        & $we -control openWallpaper -file (Join-Path $dir $job.entry) -monitor 0
        $opened = Now
        & $we -control mute
        & $we -control hideIcons
        (New-Object -ComObject Shell.Application).MinimizeAll()
        $k = 0
        foreach ($delay in $job.shots) {
            Start-Sleep -Seconds $delay
            [WeReferenceScreen]::SetCursorPos($cx, $cy) | Out-Null
            $taken = Now
            $shot = Join-Path $root ('{0}-{1}.png' -f $id, $k)
            $bitmap = New-Object System.Drawing.Bitmap $b.Width, $b.Height
            $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
            $graphics.CopyFromScreen($b.X, $b.Y, 0, 0, $bitmap.Size)
            $bitmap.Save($shot, [System.Drawing.Imaging.ImageFormat]::Png)
            $graphics.Dispose(); $bitmap.Dispose()
            Invoke-WebRequest -UseBasicParsing -Method Put -InFile $shot -Uri "$srv/shot/$id/${k}?opened=$opened&taken=$taken" | Out-Null
            $k++
        }
        & $we -control pause
        $meta = @{ screen = @($b.Width, $b.Height); work = @($w.X, $w.Y, $w.Width, $w.Height)
                   wallpaper_engine = (Get-Item $we).VersionInfo.ProductVersion } | ConvertTo-Json -Compress
        Invoke-RestMethod -Method Post -Uri "$srv/done/$id" -Body $meta | Out-Null
        Log "captured $id"
    } catch {
        Log "failed $id at line $($_.InvocationInfo.ScriptLineNumber): $($_.Exception.Message)"
        try { Invoke-RestMethod -Method Post -Uri "$srv/fail/$id" -Body $_.Exception.Message | Out-Null } catch {}
    }
}
& $we -control showIcons
Log 'run finished'
}
"""


def resolve(wallpaper: str) -> Path:
    """Folder of a wallpaper given as a Workshop id in the app's library or a path."""
    candidate = Path(wallpaper).expanduser()
    folder = candidate if candidate.is_dir() else LIBRARY / wallpaper
    if not (folder / "project.json").is_file():
        raise SystemExit(f"{MARK.missing} {wallpaper}: no project.json in {folder}")
    return folder.resolve()


def wallpaper_files(folder: Path) -> list[dict]:
    """Every file Wallpaper Engine needs from a wallpaper folder, with its size."""
    files = []
    for path in sorted(folder.rglob("*")):
        rel = path.relative_to(folder)
        if not path.is_file() or any(part.startswith(".") for part in rel.parts) or rel.name == "config.toml":
            continue
        files.append({"path": rel.as_posix(), "size": path.stat().st_size})
    return files


class CaptureRun:
    """The capture queue the VM worker drains: one job per wallpaper, handed out once."""

    def __init__(self, folders: list[Path], shots: Path, delays=SHOT_DELAYS):
        self.folders = {folder.name: folder.resolve() for folder in folders}
        self.shots, self.delays = shots, list(delays)
        self.handed, self.finished, self.failed = set(), set(), {}
        self.aborted = None
        self.drained = threading.Event()   # the worker was told there is nothing left
        self.lock = threading.Lock()
        self.changed = threading.Condition(self.lock)
        shots.mkdir(parents=True, exist_ok=True)

    def next_job(self) -> dict:
        with self.lock:
            for name, folder in self.folders.items():
                if name not in self.handed:
                    self.handed.add(name)
                    return {"id": name, "entry": "project.json", "files": wallpaper_files(folder),
                            "shots": self.delays}
            self.drained.set()
            return {"done": True}

    def file(self, name: str, rel: str) -> Path | None:
        folder = self.folders.get(name)
        if folder is None:
            return None
        path = (folder / rel).resolve()
        return path if path.is_relative_to(folder) and path.is_file() else None

    def save_shot(self, name: str, k: str, data: bytes, query: dict) -> bool:
        if name not in self.folders or not k.isdigit():
            return False
        (self.shots / f"{name}-{int(k)}.png").write_bytes(data)
        meta = self._meta(name)
        taken = meta.setdefault("taken", [])
        taken.extend([None] * (int(k) + 1 - len(taken)))
        taken[int(k)] = int(query["taken"]) if "taken" in query else None
        if "opened" in query:
            meta["opened"] = int(query["opened"])
        self._write_meta(name, meta)
        return True

    def finish(self, name: str, body: bytes) -> bool:
        if name not in self.folders:
            return False
        meta = self._meta(name)
        meta.update(json.loads(body or b"{}"))
        self._write_meta(name, meta)
        with self.changed:
            self.finished.add(name)
            self.changed.notify_all()
        return True

    def fail(self, name: str, message: str) -> bool:
        if name not in self.folders:
            return False
        with self.changed:
            self.failed[name] = message
            self.changed.notify_all()
        return True

    def abort(self, message: str):
        with self.changed:
            self.aborted = message
            self.changed.notify_all()

    def wait(self, timeout: float) -> bool:
        """True once every wallpaper was captured or failed, or the worker gave up."""
        deadline = time.monotonic() + timeout
        with self.changed:
            while not self.complete():
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    return False
                self.changed.wait(remaining)
            return True

    def complete(self) -> bool:
        return self.aborted is not None or len(self.finished) + len(self.failed) == len(self.folders)

    def _meta(self, name: str) -> dict:
        path = self.shots / f"{name}.json"
        return json.loads(path.read_text()) if path.exists() else {}

    def _write_meta(self, name: str, meta: dict):
        meta["captured"] = int(time.time())
        (self.shots / f"{name}.json").write_text(json.dumps(meta, indent=1) + "\n")


def handler(run: CaptureRun, server: str, log: Path):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, fmt, *args):
            with log.open("a") as out:
                out.write(fmt % args + "\n")

        def send(self, code: int, body=b"{}", ctype="application/json"):
            body = body.encode() if isinstance(body, str) else body
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def route(self):
            url = urllib.parse.urlparse(self.path)
            parts = [urllib.parse.unquote(part) for part in url.path.split("/")[1:]]
            return parts, dict(urllib.parse.parse_qsl(url.query))

        def body(self) -> bytes:
            length = int(self.headers.get("Content-Length", 0))
            return self.rfile.read(length) if length else b""

        def do_GET(self):
            parts, _ = self.route()
            if parts == ["worker.ps1"]:
                return self.send(200, WORKER.replace("__SERVER__", server), "text/plain; charset=utf-8")
            if parts == ["next"]:
                return self.send(200, json.dumps(run.next_job()))
            if len(parts) >= 3 and parts[0] == "file":
                path = run.file(parts[1], "/".join(parts[2:]))
                return self.send(200, path.read_bytes(), "application/octet-stream") if path else self.send(404)
            return self.send(404)

        def do_PUT(self):
            parts, query = self.route()
            ok = len(parts) == 3 and parts[0] == "shot" and run.save_shot(parts[1], parts[2], self.body(), query)
            return self.send(200 if ok else 403)

        def do_POST(self):
            parts, _ = self.route()
            data = self.body()
            if parts == ["log"]:
                with log.open("a") as out:
                    out.write(data.decode("utf-8", "replace").rstrip() + "\n")
                print(f"  vm: {data.decode('utf-8', 'replace').rstrip()}", flush=True)
                return self.send(200)
            if parts == ["abort"]:
                run.abort(data.decode("utf-8", "replace"))
                return self.send(200)
            if len(parts) == 2 and parts[0] in ("done", "fail"):
                ok = run.finish(parts[1], data) if parts[0] == "done" else run.fail(parts[1], data.decode("utf-8", "replace"))
                return self.send(200 if ok else 403)
            return self.send(404)
    return Handler


def capture(args) -> int:
    run = CaptureRun([resolve(w) for w in args.wallpapers], args.shots)
    server = f"http://{args.host}:{args.port}"
    try:
        httpd = ThreadingHTTPServer((args.host, args.port), handler(run, server, args.shots / "capture.log"))
    except OSError as error:
        print(f"{MARK.missing} cannot listen on {server} ({error}); start the VM first so the Parallels "
              "network exists, or pass --host")
        return 1
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    print(f"{MARK.step} serving {len(run.folders)} wallpaper(s) on {server}. In the VM, run in PowerShell:")
    print(f"    iex (irm {server}/worker.ps1)")
    finished = run.wait(args.timeout)
    if finished and not run.aborted:
        run.drained.wait(30)   # let the worker hear it is done before the server goes away
    httpd.shutdown()
    if run.aborted:
        print(f"{MARK.missing} the VM worker gave up: {run.aborted}")
        return 1
    for name in run.folders:
        if name in run.finished:
            print(f"{MARK.ok} {name}: {args.shots / name}-<k>.png")
        else:
            print(f"{MARK.missing} {name}: {run.failed.get(name, 'not captured before the timeout')}")
    return 0 if finished and not run.failed else 1


def shot_meta(shots: Path, name: str) -> dict:
    path = shots / f"{name}.json"
    return json.loads(path.read_text()) if path.exists() else {}


def scene_times(meta: dict) -> list[float]:
    """Seconds after opening at which each screenshot was taken."""
    if "opened" in meta and meta.get("taken"):
        return [round((taken - meta["opened"]) / 1000, 2) for taken in meta["taken"] if taken]
    return list(DEFAULT_TIMES)


def reference_tz(opened_ms: int, now: float, gmtoff: int) -> str:
    """A POSIX TZ under which this Mac's clock reads, right now, the time of day
    Wallpaper Engine opened the wallpaper, so clocks and day/night scripts match."""
    west = (int(now) - opened_ms // 1000 - gmtoff) % 86400
    if west >= 43200:
        west -= 86400
    hours, rest = divmod(abs(west), 3600)
    return f"REF{'-' if west < 0 else '+'}{hours}:{rest // 60:02d}:{rest % 60:02d}"


def render(args) -> int:
    if not args.binary.is_file():
        print(f"{MARK.missing} {args.binary} is missing; `python3 scripts/check_renderer.py` builds it")
        return 1
    out = args.out / args.label
    out.mkdir(parents=True, exist_ok=True)
    status = 0
    for wallpaper in args.wallpapers:
        folder = resolve(wallpaper)
        meta = shot_meta(args.shots, folder.name)
        project = json.loads((folder / "project.json").read_text(encoding="utf-8-sig"))
        if str(project.get("type", "")).lower() != "scene":
            print(f"{MARK.warn} {folder.name}: a {project.get('type')} wallpaper, not a scene; skipped")
            continue
        width, height = meta.get("screen", (1920, 1080))
        for k, seconds in enumerate(scene_times(meta)):
            work = Path(tempfile.mkdtemp(prefix=f"{folder.name}-{k}-", dir=out))
            env = dict(os.environ, WE_TEST_ASSETS=str(args.assets), WE_TEST_COMPARE_PROJECTS=str(folder / "project.json"),
                       WE_TEST_COMPARE_SURFACE=f"{width}x{height}", WE_TEST_COMPARE_NATIVE_ONLY="1",
                       WE_TEST_COMPARE_RESOLUTION="display", WE_TEST_COMPARE_REALTIME="1",
                       WE_TEST_METAL_FRAMES=str(min(3600, max(2, round(seconds / STEP)))),
                       WE_TEST_METAL_FRAME_STEP=str(STEP), WE_TEST_RANDOM_SEED="1", WE_TEST_AUDIO_HZ="0",
                       WE_TEST_INPUT_JSON='[{"frame":0,"x":0.5,"y":0.5,"inside":true}]', WE_TEST_OUTPUT=str(work))
            if "opened" in meta:
                env["TZ"] = reference_tz(meta["opened"], time.time(), time.localtime().tm_gmtoff)
            result = subprocess.run([str(args.binary), "--gtest_filter=*DrawTheSamePictureOnBothRenderers*"], env=env,
                                    capture_output=True, text=True, errors="replace")
            log = out / f"{folder.name}-{k}.log"
            log.write_text(result.stdout + result.stderr)
            pictures = sorted(work.glob("*-native.ppm"))
            if pictures:
                subprocess.run(["sips", "-s", "format", "png", str(pictures[0]), "--out", str(out / f"{folder.name}-{k}.png")],
                               check=True, capture_output=True)
                backend = [line for line in result.stdout.splitlines() if "Compatibility" in line]
                note = f" ({backend[-1].strip()})" if backend else ""
                print(f"{MARK.ok} {folder.name}-{k}: {width}x{height} at {seconds:g} s -> {out / folder.name}-{k}.png{note}")
            else:
                print(f"{MARK.missing} {folder.name}-{k}: no picture at {seconds:g} s; see {log}")
                status = 1
            shutil.rmtree(work, ignore_errors=True)
    return status


def read_bmp(data: bytes) -> tuple[int, int, bytes]:
    """Width, height and top-down RGB bytes of an uncompressed or bitfield BMP."""
    offset = struct.unpack_from("<I", data, 10)[0]
    header, width, height, _, bits, compression = struct.unpack_from("<IiiHHI", data, 14)
    if bits not in (24, 32):
        raise ValueError(f"unsupported BMP depth {bits}")
    shifts = (16, 8, 0)
    if compression == 3 and bits == 32:
        shifts = tuple((mask & -mask).bit_length() - 1 for mask in struct.unpack_from("<III", data, 54))
    stride = (bits * width + 31) // 32 * 4
    rows = range(abs(height)) if height < 0 else range(abs(height) - 1, -1, -1)
    out = bytearray()
    step = bits // 8
    for row in rows:
        start = offset + row * stride
        line = data[start:start + width * step]
        if bits == 24:
            pixels = bytearray(width * 3)
            pixels[0::3], pixels[1::3], pixels[2::3] = line[2::3], line[1::3], line[0::3]
        else:
            words = struct.unpack_from(f"<{width}I", line)
            pixels = bytearray(b for word in words for b in ((word >> shifts[0]) & 255, (word >> shifts[1]) & 255,
                                                           (word >> shifts[2]) & 255))
        out += pixels
    return width, abs(height), bytes(out)


def bmp(width: int, height: int, rgb: bytes) -> bytes:
    """A top-down 24-bit BMP of RGB bytes."""
    stride = (width * 3 + 3) // 4 * 4
    body = bytearray()
    for y in range(height):
        line = bytearray(rgb[y * width * 3:(y + 1) * width * 3])
        line[0::3], line[2::3] = line[2::3], line[0::3]
        body += line + bytes(stride - width * 3)
    return (struct.pack("<2sIHHI", b"BM", 54 + len(body), 0, 0, 54)
            + struct.pack("<IiiHHIIiiII", 40, width, -height, 1, 24, 0, len(body), 2835, 2835, 0, 0) + body)


def crop(width: int, height: int, rgb: bytes, x: int, y: int, w: int, h: int) -> bytes:
    """The `w`x`h` rectangle at (`x`, `y`) of an RGB image."""
    return b"".join(rgb[(row * width + x) * 3:(row * width + x + w) * 3] for row in range(y, y + h))


def load(path: Path, screen: list[int], work: list[int], width: int, height: int) -> bytes:
    """RGB bytes of the work area of a full-screen image, scaled to `width`x`height`.
    The whole image is scaled first (sips centres a crop whose offset is zero)."""
    full_w, full_h = round(width * screen[0] / work[2]), round(height * screen[1] / work[3])
    with tempfile.TemporaryDirectory() as scratch:
        sized = Path(scratch) / "sized.bmp"
        subprocess.run(["sips", "-s", "format", "bmp", "-z", str(full_h), str(full_w), str(path), "--out", str(sized)],
                       check=True, capture_output=True)
        w, h, rgb = read_bmp(sized.read_bytes())
    x, y = min(round(work[0] * w / screen[0]), w - width), min(round(work[1] * h / screen[1]), h - height)
    return crop(w, h, rgb, max(0, x), max(0, y), width, height)


def image_size(path: Path) -> tuple[int, int]:
    out = subprocess.run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", str(path)], check=True,
                         capture_output=True, text=True).stdout.split()
    return int(out[out.index("pixelWidth:") + 1]), int(out[out.index("pixelHeight:") + 1])


def metrics(reference: bytes, ours: bytes) -> dict:
    n = len(reference) // 3
    diffs = [abs(a - b) for a, b in zip(reference, ours)]
    luma = lambda rgb: [(rgb[i] + rgb[i + 1] + rgb[i + 2]) / 3 for i in range(0, len(rgb), 3)]
    la, lb = luma(reference), luma(ours)
    ma, mb = sum(la) / n, sum(lb) / n
    cov = sum((a - ma) * (b - mb) for a, b in zip(la, lb))
    va, vb = sum((a - ma) ** 2 for a in la), sum((b - mb) ** 2 for b in lb)
    return {
        "mean_abs": round(sum(diffs) / len(diffs), 2),
        "off48": round(sum(max(diffs[i:i + 3]) > 48 for i in range(0, len(diffs), 3)) / n, 4),
        "luma_we": round(ma, 1), "luma_ours": round(mb, 1),
        "corr": round(cov / math.sqrt(va * vb), 3) if va and vb else None,
    }


def compare(args) -> int:
    labels = [label for label in args.labels.split(",") if label]
    args.out.mkdir(parents=True, exist_ok=True)
    sheets = args.out / "compare"
    sheets.mkdir(exist_ok=True)
    path = sheets / "metrics.json"
    results = json.loads(path.read_text()) if path.exists() else {}
    status = 0
    for wallpaper in args.wallpapers:
        name = Path(wallpaper).name
        meta = shot_meta(args.shots, name)
        for k in range(len(scene_times(meta))):
            reference = args.shots / f"{name}-{k}.png"
            renders = [args.out / label / f"{name}-{k}.png" for label in labels]
            missing = [p for p in [reference, *renders] if not p.exists()]
            if missing:
                print(f"{MARK.missing} {name}-{k}: {', '.join(str(p) for p in missing)} missing")
                status = 1
                continue
            screen = meta.get("screen") or list(image_size(reference))
            work = meta.get("work") or [0, 0, *screen]
            height = round(SHEET_WIDTH * work[3] / work[2])
            mh = round(METRIC_WIDTH * work[3] / work[2])
            panels, entry = [], {}
            ref_panel = load(reference, screen, work, SHEET_WIDTH, height)
            ref_small = load(reference, screen, work, METRIC_WIDTH, mh)
            panels.append(ref_panel)
            for label, image in zip(labels, renders):
                panels.append(load(image, screen, work, SHEET_WIDTH, height))
                entry[label] = metrics(ref_small, load(image, screen, work, METRIC_WIDTH, mh))
            panels.append(bytes(min(255, abs(a - b) * 4) for a, b in zip(ref_panel, panels[-1])))
            gap = bytes([40] * 3 * 8)
            rows = bytearray()
            for y in range(height):
                rows += gap.join(panel[y * SHEET_WIDTH * 3:(y + 1) * SHEET_WIDTH * 3] for panel in panels)
            sheet_width = SHEET_WIDTH * len(panels) + 8 * (len(panels) - 1)
            with tempfile.TemporaryDirectory() as scratch:
                raw = Path(scratch) / "sheet.bmp"
                raw.write_bytes(bmp(sheet_width, height, bytes(rows)))
                subprocess.run(["sips", "-s", "format", "png", str(raw), "--out", str(sheets / f"{name}-{k}.png")],
                               check=True, capture_output=True)
            results[f"{name}-{k}"] = entry
            summary = ", ".join(f"{label} mean {m['mean_abs']} off48 {m['off48']:.1%} corr {m['corr']}"
                                for label, m in entry.items())
            print(f"{MARK.ok} {name}-{k}: {sheets / name}-{k}.png  {summary}")
    path.write_text(json.dumps(results, indent=1) + "\n")
    return status


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--shots", type=Path, default=SHOTS, help="Wallpaper Engine screenshots (default: %(default)s)")
    parser.add_argument("--out", type=Path, default=OUTPUT, help="renders and sheets (default: %(default)s)")
    commands = parser.add_subparsers(dest="command", required=True)
    grab = commands.add_parser("capture", help="capture Wallpaper Engine's frames in the VM")
    grab.add_argument("wallpapers", nargs="+")
    grab.add_argument("--host", default=HOST, help="address to listen on (default: %(default)s, the Parallels network)")
    grab.add_argument("--port", type=int, default=PORT)
    grab.add_argument("--timeout", type=float, default=1800, help="seconds to wait for the VM (default: %(default)s)")
    draw = commands.add_parser("render", help="render the wallpapers as the screenshots show them")
    draw.add_argument("wallpapers", nargs="+")
    draw.add_argument("--label", default="ours", help="name of this set of renders, e.g. before/after (default: %(default)s)")
    draw.add_argument("--binary", type=Path, default=BINARY, help="metal_scene_draw_smoke to render with (default: %(default)s)")
    draw.add_argument("--assets", type=Path, default=ASSETS)
    sheet = commands.add_parser("compare", help="side-by-side sheets and metrics")
    sheet.add_argument("wallpapers", nargs="+")
    sheet.add_argument("--labels", default="ours", help="comma-separated render sets, left to right (default: %(default)s)")
    args = parser.parse_args(argv)
    sys.stdout.reconfigure(line_buffering=True)   # progress shows up while the VM works
    return {"capture": capture, "render": render, "compare": compare}[args.command](args)


if __name__ == "__main__":
    raise SystemExit(main())
