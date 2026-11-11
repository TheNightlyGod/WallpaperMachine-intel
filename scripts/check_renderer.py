#!/usr/bin/env python3
"""Non-desktop renderer regressions: generated scenes and optional local projects.

Creates only private GPU images. Never launches the app, captures the screen,
initializes sound, changes wallpapers, or controls Spaces. Local packages stay put.
"""
import argparse
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

from build import build_environment, cargo_environment
from lib.paths import ENGINE, RENDERER, RENDERER_ARTIFACTS, ROOT
from lib.xcode import skipped_test_lines

GENERATED_CASE_COUNT = 12
# One registry owns the build/run/verdict and the Metal-device prerequisite.
# VideoToolbox codec prerequisites, if unavailable, are reported by those tests.
REGRESSION_BINARIES = {
    "render_target_lifetime_test": False, "text_object_runtime_test": False, "text_object_behavior_test": False,
    "video_decode_pump_test": False,
    "video_color_conversion_test": False, "video_frame_pacing_test": False,
    "video_source_input_test": False, "video_probe_test": False, "vt_frame_decoder_test": False, "webm_reader_test": False,
    "synthetic_video_test": False,
    "render_scale_test": False,
    "static_subgraph_cache_test": False,
    "scene_mesh_tests": False, "particle_rope_geometry_test": False,
    "particle_mouse_controlpoint_test": False, "particle_parity_test": False,
    "particle_override_tint_test": False,
    "particle_billboard_size_test": False, "particle_control_point_test": False,
    "particle_override_test": False, "particle_rope_pieces_test": False,
    "layer_texture_reference_test": False,
    "project_property_preview_test": False,
    "scenescript_media_event_smoke": False, "scenescript_behavior_test": False, "scenescript_storage_test": False, "media_thumbnail_texture_smoke": False,
    "scene_schema_tests": False, "scene_schema_fixtures_selftest": False, "scene_schema_part01_test": False,
    "scene_schema_part02_test": False, "scene_schema_part03_test": False, "scene_schema_part04_test": False,
    "scene_schema_part05_test": False, "scene_schema_part06_test": False, "scene_schema_part07_test": False, "scene_schema_part08_test": False,
    "scene_schema_part09_test": False, "scene_schema_part10_test": False, "scene_schema_part11_test": False,
    "script_runtime_compat_test": False,
    "sound_layer_cursor_behavior_test": False, "media_event_behavior_test": False,
    "texture_slot_behavior_test": False, "material_constant_behavior_test": False,
    "create_layer_behavior_test": False, "script_host_behavior_test": False,
    "shader_updater_behavior_test": False, "scenescript_puppet_bones_test": False,
    "mouse_input_test": False, "cursor_input_state_test": False, "mdl_schema_tests": False, "tex_schema_tests": False,
    "mdl_parse_tests": False, "puppet_pose_tests": False, "tex_container_tests": False,
    "timer_tests": False, "metal_backend_test": False,
    "metal_scene_draw_smoke": True, "metal_poster_capture_test": True,
    "metal_video_texture_test": True, "unchanged_present_test": True, "scene_failure_policy_test": True,
    "scene_load_sound_test": True,
    "scene_harness_selftest": True, "backdrop_scene_test": True, "metalfx_upscale_test": True,
    "horizontal_flip_pointer_test": True, "scene_options_binding_test": True,
    "scene_placeholder_picture_test": True, "scene_passthrough_layout_test": True,
    "scene_fullscreen_parallax_test": True, "scene_layer_size_test": False,
    "scene_capability_probe_test": False,
    "layer_composite_render_test": True, "cover_slot_composite_test": True, "perspective_image_layer_test": True, "model_parallax_test": True, "unbound_texture_slot_test": True, "scene_lighting_fog_test": True,
    "script_model_layer_test": True,
    "metal_memory_test": True, "scene_video_input_test": False,
    "audio_tests": False, "miniaudio_failure_paths_test": False, "sprite_animation_test": False,
    "rendergraph_smoke": False,
    "workshop_snapshot_test": False, "workshop_corpus_stamps_test": False,
    "stb_image_regression_test": False,
    "surface_health_test": False, "wallpaper_scaling_test": False,
    "backdrop_geometry_test": False,
    "shader_preprocessor_compat_test": False,
    "rust_shader_bridge_behavior_test": False, "shader_program_cache_behavior_test": False,
    "shader_dialect_compat_test": False, "shader_corpus_test": False,
    "video_texture_submission_smoke": False,
    # Renderer/Media/tests: the project's own container readers, pure C++ and headless.
    "media_core_tests": False, "media_isobmff_tests": False, "media_matroska_tests": False,
    # Renderer/Sound/tests: the project's own remix, resample and loop path, pure C++ and headless.
    "sound_core_tests": False, "sound_apple_tests": False, "sound_vorbis_tests": False,
    "sound_matroska_tests": False,
    # Renderer/Surface/tests: the still a wallpaper that cannot be drawn shows, headless (a plain CALayer).
    "surface_path_tests": False, "surface_still_tests": False,
}
# Executables in tests/CMakeLists.txt that the check neither builds nor runs, and
# why. Every other one is registered above, a probe, or the diagnostic benchmark below.
MANUAL_BINARIES = {
    "wpdump": "inspection tool, not a test: dumps one workshop item's parse to JSON",
}
OFFSCREEN_PROBE = "offscreen_scene_probe"
RELOAD_PROBE = "scene_reload_cycle_probe"
TIMER_PROBE = "timer-precision"
TIMER_DELIVERY_BENCHMARK = "timer_delivery_benchmark"
# Tests whose assertions count frames, ticks or expiries against short
# wall-clock waits. Hosted macOS VMs deliver a 10 ms wait 50-100 ms late, so
# these are skipped by name only when the timer probe proves that host.
REALTIME_TESTS = {
    "timer_tests": (
        "FrameTimerTest.ABurstOfWakeOnceAtTheCeilingDoesNotAddCallbacks",
        "ThreadTimerTest.CadenceKeepsItsPeriodDespiteWakeSlack",
        "ThreadTimerTest.RequestsAfterALongWaitStillRespectTheCeiling",
    ),
    "unchanged_present_test": (
        "UnchangedPresent.AStaticSceneStopsPresentingOnceEveryPassIsReused",
        "UnchangedPresent.APropertyPreviewShowsOnAStillSceneAndWakesAnIdleOneForOneFrame",
        "UnchangedPresent.AHistoryLoopKeepsTheClockRunningWithoutATimeUniform",
        "UnchangedPresent.ADrawFailureAfterTheFirstFrameIsReportedOnceAndASurfaceRebuildHealsIt",
    ),
    "audio_tests": (
        "AudioResponseMonoTest.PartialSubmissionsExtendExpiryUntilACompleteBlockArrives",
    ),
}
# The median of 31 condition-variable waits of 10 ms, the frame clock's own
# primitive. More than one whole period late means cadence tests cannot hold.
# A Mac coalesces a 10 ms wait to about 12 ms. A hosted VM has measured 18 to 27 ms, and its
# cadence tests failed at 18 ms, so anything above 15 ms counts as imprecise.
TIMER_PROBE_SOURCE = """#include <algorithm>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <mutex>
#include <vector>
int main() {
    using namespace std::chrono;
    std::mutex mutex;
    std::condition_variable condition;
    std::unique_lock lock(mutex);
    std::vector<double> waits;
    for (int index = 0; index < 31; ++index) {
        const auto start = steady_clock::now();
        const auto due = start + 10ms;
        while (steady_clock::now() < due) condition.wait_until(lock, due);
        waits.push_back(duration<double, std::milli>(steady_clock::now() - start).count());
    }
    std::nth_element(waits.begin(), waits.begin() + 15, waits.end());
    std::printf("median 10 ms wait: %.2f ms\\n", waits[15]);
    return waits[15] > 15.0 ? 77 : 0;
}
"""


def foreground_test_process():
    """Clear inherited Darwin background policy in the forked test child only."""
    os.setpriority(os.PRIO_DARWIN_PROCESS, 0, 0)
    os.setpriority(os.PRIO_DARWIN_THREAD, 0, 0)


def run(command, log, env, timeout=180, cwd=ROOT):
    command = list(map(str, command))
    is_test = Path(command[0]).name in (*REGRESSION_BINARIES, OFFSCREEN_PROBE, RELOAD_PROBE, TIMER_PROBE, TIMER_DELIVERY_BENCHMARK)
    if is_test:
        # Match application scheduling for real-time assertions, even when the
        # invoking CI agent inherited background/latency throttling.
        command = ["/usr/sbin/taskpolicy", "-a", "-l", "0", "-t", "0", *command]
    with log.open("w") as stream:
        return subprocess.run(command, cwd=cwd, env=env,
                              stdout=stream, stderr=subprocess.STDOUT,
                              preexec_fn=foreground_test_process if is_test else None,
                              timeout=timeout, check=False).returncode


def parse_timer_delivery_benchmark(text):
    """Validate one measurement, without imposing a delivery-rate threshold."""
    marker = "TIMER_DELIVERY_BENCHMARK"
    lines = [line for line in text.splitlines() if line.startswith(marker)]
    if len(lines) != 1:
        raise ValueError(f"expected one {marker} line, found {len(lines)}")
    if not lines[0].startswith(marker + " "):
        raise ValueError(f"missing space after {marker}")

    def unique_fields(pairs):
        result = {}
        for name, value in pairs:
            if name in result:
                raise ValueError(f"duplicate benchmark field: {name}")
            result[name] = value
        return result

    def invalid_constant(value):
        raise ValueError(f"invalid JSON constant: {value}")

    payload = json.loads(lines[0][len(marker) + 1:], object_pairs_hook=unique_fields,
                         parse_constant=invalid_constant)
    if not isinstance(payload, dict):
        raise ValueError("benchmark payload must be a JSON object")
    expected = {"schema": 1, "requested_fps": 60, "busy_work_ns": 18_000_000,
                "requested_warmup_ns": 200_000_000, "requested_window_ns": 1_000_000_000}
    for name in (*expected, "window_start_ns", "window_end_ns", "count_before", "count_after", "delivered"):
        if name not in payload:
            raise ValueError(f"missing benchmark field: {name}")
        if type(payload[name]) is not int:
            raise ValueError(f"benchmark field must be an integer, not a boolean: {name}")
    for name, value in expected.items():
        if payload[name] != value:
            raise ValueError(f"unexpected benchmark {name}: {payload[name]}")
    if payload["window_end_ns"] <= payload["window_start_ns"]:
        raise ValueError("benchmark outer window must have positive duration")
    if payload["count_before"] < 0 or payload["count_after"] < payload["count_before"]:
        raise ValueError("benchmark counters must be nonnegative and nondecreasing")
    if payload["delivered"] != payload["count_after"] - payload["count_before"]:
        raise ValueError("benchmark delivered count does not match the counter difference")
    return payload


def collect_timer_delivery_benchmark(build, out, env):
    """Run the diagnostic once; collection errors remain gate tooling failures."""
    log = out / (TIMER_DELIVERY_BENCHMARK + ".log")
    result = {"exit": None, "status": "tooling-failure", "diagnostic_only": True, "log": str(log)}
    try:
        result["exit"] = run([build / "tests" / TIMER_DELIVERY_BENCHMARK], log, env, 30)
    except subprocess.TimeoutExpired:
        result.update(exit="timeout", error="benchmark exceeded its 30 second timeout")
        return result
    except OSError as error:
        result.update(exit="error", error=f"benchmark invocation failed: {error}")
        return result
    if result["exit"] != 0:
        result["error"] = f"benchmark exited with status {result['exit']}"
        return result
    try:
        payload = parse_timer_delivery_benchmark(log.read_text())
        duration_ns = payload["window_end_ns"] - payload["window_start_ns"]
        rate = payload["delivered"] * 1_000_000_000 / duration_ns
    except (OSError, ValueError, OverflowError) as error:
        result["error"] = f"benchmark measurement unavailable: {error}"
        return result
    result.update(status="collected", measurement=payload, actual_outer_duration_ns=duration_ns,
                  delivered_per_second=rate)
    return result


def record_skips(report, name, log):
    reasons = skipped_test_lines(log.read_text(errors="replace").splitlines()) if log.exists() else []
    report_skips(report, name, reasons)


def report_skips(report, name, reasons):
    if reasons:
        report["skips"].setdefault(name, []).extend(reasons)
        for reason in reasons:
            prefix = "::warning::" if os.environ.get("GITHUB_ACTIONS") == "true" else "SKIP "
            print(f"{prefix}{name}: {reason}", flush=True)


def gpu_preflight(out, env):
    """Only a successfully built probe's exit 77 means no Metal device exists."""
    source = out / "gpu-availability.m"
    source.write_text('#import <Metal/Metal.h>\nint main(void) { @autoreleasepool { return MTLCreateSystemDefaultDevice() ? 0 : 77; } }\n')
    return compiled_probe(out, env, "gpu", out / "gpu-availability",
                          ["clang", "-fobjc-arc", source, "-framework", "Metal"])


def timer_preflight(out, env):
    """Only a successfully built probe's exit 77 means short waits overshoot a period."""
    source = out / (TIMER_PROBE + ".cpp")
    source.write_text(TIMER_PROBE_SOURCE)
    return compiled_probe(out, env, "timer", out / TIMER_PROBE,
                          ["clang++", "-std=c++20", "-O2", source])


def compiled_probe(out, env, prefix, binary, compiler):
    result = {"compile_exit": None, "probe_exit": None}
    steps = [(["xcrun", *compiler, "-o", binary], "compile_exit"), ([binary], "probe_exit")]
    for command, key in steps:
        log = out / (prefix + "-" + key + ".log")
        try:
            result[key] = run(command, log, env, 60)
        except subprocess.TimeoutExpired:
            result[key] = "timeout"
        except OSError as error:
            result[key] = "error"
            log.write_text(str(error) + "\n")
        if key == "compile_exit" and result[key] != 0:
            break
    return result


def fixture_assets(root):
    """Minimal original compose-layer assets shared by the synthetic scenes."""
    passthrough = {"blending": "translucent", "cullmode": "nocull", "depthtest": "disabled",
                   "depthwrite": "disabled", "shader": "generated_copy"}
    files = {
        "models/util/composelayer.json": {"passthrough": True, "material": "materials/util/composelayer.json"},
        "materials/util/composelayer.json": {"passes": [{**passthrough, "textures": ["_rt_FullFrameBuffer"]}]},
        "materials/util/effectpassthrough.json": {"passes": [{**passthrough, "blending": "normal"}]},
        "shaders/generated_copy.vert": """uniform mat4 g_ModelViewProjectionMatrix;
attribute vec3 a_Position;
attribute vec2 a_TexCoord;
varying vec2 v_TexCoord;
void main() {
    gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
    v_TexCoord = a_TexCoord;
}
""",
        "shaders/generated_copy.frag": """uniform sampler2D g_Texture0;
varying vec2 v_TexCoord;
void main() {
    gl_FragColor = texSample2D(g_Texture0, v_TexCoord);
}
""",
    }
    for name, value in files.items():
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(value if isinstance(value, str) else json.dumps(value))
    return root


def fixtures(root):
    """Original synthetic assets, no workshop identifiers or copyrighted content."""
    for index in range(8):
        folder = root / f"generated-{index}"
        folder.mkdir(parents=True, exist_ok=True)
        files = {
            "project.json": json.dumps({"title": f"Generated {index}", "type": "scene", "file": "layout.json", "general": {"properties": {}}}),
            "models/tile.json": json.dumps({"width": 64, "height": 48, "material": "materials/tile.json"}),
            "materials/tile.json": json.dumps({"passes": [{"shader": "probe_tile", "blending": "translucent", "cullmode": "nocull", "depthtest": "disabled", "depthwrite": "disabled"}]}),
            "effects/probe.json": json.dumps({"name": "probe copy", "passes": [{"material": "materials/copy.json"}]}),
            "materials/copy.json": json.dumps({"passes": [{"shader": "probe_copy", "blending": "translucent", "cullmode": "nocull", "depthtest": "disabled", "depthwrite": "disabled", "textures": [None]}]}),
            "shaders/probe_tile.vert": "uniform mat4 g_ModelViewProjectionMatrix; attribute vec3 a_Position; attribute vec2 a_TexCoord; varying vec2 v_TexCoord; void main(){gl_Position=mul(vec4(a_Position,1.0),g_ModelViewProjectionMatrix);v_TexCoord=a_TexCoord;}",
            "shaders/probe_tile.frag": "varying vec2 v_TexCoord; void main(){gl_FragColor=vec4(v_TexCoord,0.3,0.8);}",
            "shaders/probe_copy.frag": "uniform sampler2D g_Texture0; varying vec2 v_TexCoord; void main(){gl_FragColor=texSample2D(g_Texture0,v_TexCoord);}",
        }
        files["shaders/probe_copy.vert"] = files["shaders/probe_tile.vert"]
        def tile(id_, name, origin, parent=None):
            obj = {"id": id_, "name": name, "image": "models/tile.json", "origin": origin, "scale": [1,1,1], "angles": [0,0,0], "visible": True}
            if parent is not None:
                obj["parent"] = parent
            return obj
        # Reusable poison target, empty effect, and nested compose children.
        poison = tile(100, "first effect", [40,40,0])
        poison["effects"] = [{"file": "effects/probe.json", "visible": True}]
        compose = {"id": 200, "name": "container", "image": "models/util/composelayer.json", "size": [96 + index * 3,72 + index * 2], "origin": [180,120,0], "scale": [-1 if index % 2 else 1,0.8,1], "angles": [0,0,0.1 * index], "copybackground": bool(index % 2), "effects": [{"file": "effects/probe.json", "visible": True}], "visible": index != 6}
        objects = [poison, compose]
        if index >= 2:
            objects.append(tile(201, "child", [0,0,0], 200))
        if index >= 4:
            inner = dict(compose, id=300, name="inner", parent=200, origin=[15,0,0], size=[64,48], copybackground=False)
            objects.extend([inner, tile(301, "grandchild", [0,0,0], 300)])
        if index == 7:
            objects.reverse()  # Declaration order/ID is not a resource identity.
        # Bloom is off in every generated scene: it is Wallpaper Engine's
        # default, and these fixtures carry no bloom materials.
        scene = {"camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
                 "general": {"ambientcolor":[0,0,0], "skylightcolor":[0,0,0], "clearcolor":[0.02,0.05,0.08], "cameraparallax":False, "bloom":False, "orthogonalprojection":{"width":384,"height":256}}, "objects": objects}
        files["layout.json"] = json.dumps(scene)
        for name, contents in files.items():
            path = folder / name
            path.parent.mkdir(parents=True, exist_ok=True)
            if name.startswith("shaders/"):
                contents = contents.replace(";", ";\n").replace("{", "{\n").replace("}", "\n}\n")
            path.write_text(contents)
        yield folder / "project.json"


def alpha_composite_fixture(root, *, alpha_to_coverage=False):
    """Expose composed coverage as RGB, independent of source artwork or effects."""
    folder = root / ("generated-alpha-single-sample" if alpha_to_coverage else "generated-alpha")
    vertex = """uniform mat4 g_ModelViewProjectionMatrix;
attribute vec3 a_Position;
attribute vec2 a_TexCoord;
varying vec2 v_TexCoord;
void main() {
    gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
    v_TexCoord = a_TexCoord;
}
"""
    # The alpha-to-coverage variant follows the shipped shaders: an `#if GLSL` discard below
    # half alpha that Wallpaper Engine never takes (it does not define GLSL), so coverage alone
    # decides what is kept.
    discard = "\n#if GLSL\n    if (gl_FragColor.a < 0.5) discard;\n#endif\n" if alpha_to_coverage else "\n"
    under_alpha = "0.25 + floor(v_TexCoord.x * 3.0) * 0.375" if alpha_to_coverage else "floor(v_TexCoord.x * 3.0) * 0.5"
    over_alpha = "0.25" if alpha_to_coverage else "0.5"
    fragments = {
        "under": f"""varying vec2 v_TexCoord;
void main() {{
    gl_FragColor = vec4(0.2, 0.4, 0.6, {under_alpha});{discard}}}
""",
        "over": f"""void main() {{
    gl_FragColor = vec4(0.8, 0.6, 0.4, {over_alpha});{discard}}}
""",
        "coverage": """uniform sampler2D g_Texture0;
varying vec2 v_TexCoord;
void main() {
    float coverage = texSample2D(g_Texture0, v_TexCoord).a;
    gl_FragColor = vec4(coverage, coverage, coverage, 1.0);
}
""",
    }
    files = {
        "project.json": {"title": "Source-over coverage", "type": "scene", "file": "layout.json", "general": {"properties": {}}},
        "effects/coverage.json": {"name": "coverage readback", "passes": [{"material": "materials/coverage.json"}]},
    }
    for name, fragment in fragments.items():
        blend = "alphatocoverage" if alpha_to_coverage and name != "coverage" else "translucent"
        files[f"materials/{name}.json"] = {"passes": [{"shader": name, "blending": blend, "cullmode": "nocull", "depthtest": "disabled", "depthwrite": "disabled", "textures": [None]}]}
        files[f"models/{name}.json"] = {"width": 288, "height": 144, "material": f"materials/{name}.json"}
        files[f"shaders/{name}.vert"] = vertex
        files[f"shaders/{name}.frag"] = fragment
    files["layout.json"] = {
        "camera": {"center": [0, 0, 0], "eye": [0, 0, 1], "up": [0, 1, 0]},
        "general": {"clearcolor": [0.1, 0.2, 0.3], "cameraparallax": False, "bloom": False, "orthogonalprojection": {"width": 384, "height": 256}},
        "objects": [
            {"id": 1, "name": "coverage container", "image": "models/util/composelayer.json", "size": [288, 144], "origin": [192, 128, 0], "copybackground": False, "effects": [{"file": "effects/coverage.json", "visible": True}]},
            {"id": 2, "name": "destination", "parent": 1, "image": "models/under.json", "origin": [0, 0, 0]},
            {"id": 3, "name": "source", "parent": 1, "image": "models/over.json", "origin": [0, 0, 0]},
        ],
    }
    for name, contents in files.items():
        path = folder / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(contents if isinstance(contents, str) else json.dumps(contents))
    return folder / "project.json"


def perspective_animation_fixture(root):
    """A quad corner driven by a paused parent timeline, read back as geometry."""
    folder = root / "generated-perspective-animation"
    vertex = """uniform mat4 g_ModelViewProjectionMatrix;
attribute vec3 a_Position;
attribute vec2 a_TexCoord;
varying vec2 v_TexCoord;
void main() {
    gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
    v_TexCoord = a_TexCoord;
}
"""
    # Original homography: the unit square maps onto the four authored corners,
    # so only fragments whose inverse-mapped point is in front of the projection
    # plane and inside the square are drawn. A corner stuck on its static value
    # inverts the quad and leaks a wedge across the empty margin instead.
    fragment = """uniform vec2 g_Point0; // {"material":"point0","default":"0.25 0.5"}
uniform vec2 g_Point1; // {"material":"point1","default":"0.75 0.375"}
uniform vec2 g_Point2; // {"material":"point2","default":"0.375 0.875"}
uniform vec2 g_Point3; // {"material":"point3","default":"0.375 1"}
varying vec2 v_TexCoord;
void main() {
    vec2 span = g_Point0 - g_Point1 + g_Point2 - g_Point3;
    vec2 edge1 = g_Point1 - g_Point2;
    vec2 edge2 = g_Point3 - g_Point2;
    float basis = edge1.x * edge2.y - edge2.x * edge1.y;
    if (abs(basis) < 1e-9) discard;
    float g = (span.x * edge2.y - edge2.x * span.y) / basis;
    float h = (edge1.x * span.y - span.x * edge1.y) / basis;
    float a = g_Point1.x - g_Point0.x + g * g_Point1.x;
    float b = g_Point3.x - g_Point0.x + h * g_Point3.x;
    float c = g_Point0.x;
    float d = g_Point1.y - g_Point0.y + g * g_Point1.y;
    float e = g_Point3.y - g_Point0.y + h * g_Point3.y;
    float f = g_Point0.y;
    float det = a * (e - f * h) - b * (d - f * g) + c * (d * h - e * g);
    if (abs(det) < 1e-9) discard;
    vec3 row0 = vec3(e - f * h, c * h - b, b * f - c * e) / det;
    vec3 row1 = vec3(f * g - d, a - c * g, c * d - a * f) / det;
    vec3 row2 = vec3(d * h - e * g, b * g - a * h, a * e - b * d) / det;
    vec3 point = vec3(v_TexCoord, 1.0);
    float w = dot(row2, point);
    if (w <= 0.0) discard;
    vec2 square = vec2(dot(row0, point), dot(row1, point)) / w;
    if (square.x < 0.0 || square.x > 1.0 || square.y < 0.0 || square.y > 1.0) discard;
    gl_FragColor = vec4(1.0, 1.0, 1.0, 1.0);
}
"""
    # The root is paused on its first key, so the child corner must hold
    # (0.875, 0.875). An independent child clock would autoplay through the
    # probe warm-up and settle on the static (0.375, 0.875) instead.
    corners = {
        "point0": {"value": [0.25, 0.5]},
        "point1": {"value": [0.75, 0.375], "animation": {
            "options": {"fps": 30, "length": 3, "mode": "single", "startpaused": True,
                        "name": "fold", "children": [{"key": "point2"}]},
            "c0": [{"frame": 0, "value": 0.75}, {"frame": 3, "value": 0.75}],
            "c1": [{"frame": 0, "value": 0.375}, {"frame": 3, "value": 0.375}],
        }},
        "point2": {"value": [0.375, 0.875], "animation": {
            "options": {"fps": 30, "length": 3, "mode": "single", "parent": {"key": "point1"}},
            "c0": [{"frame": 0, "value": 0.875}, {"frame": 3, "value": 0.375}],
            "c1": [{"frame": 0, "value": 0.875}, {"frame": 3, "value": 0.875}],
        }},
        "point3": {"value": [0.375, 1.0]},
    }
    files = {
        "project.json": {"title": "Perspective corner timeline", "type": "scene",
                         "file": "layout.json", "general": {"properties": {}}},
        "models/page.json": {"width": 384, "height": 256, "material": "materials/page.json"},
        "materials/page.json": {"passes": [{"shader": "page", "blending": "translucent",
                                            "cullmode": "nocull", "depthtest": "disabled",
                                            "depthwrite": "disabled",
                                            "constantshadervalues": corners}]},
        "shaders/page.vert": vertex,
        "shaders/page.frag": fragment,
        "layout.json": {
            "camera": {"center": [0, 0, 0], "eye": [0, 0, 1], "up": [0, 1, 0]},
            "general": {"clearcolor": [0.1, 0.2, 0.3], "cameraparallax": False, "bloom": False,
                        "orthogonalprojection": {"width": 384, "height": 256}},
            "objects": [{"id": 1, "name": "page", "image": "models/page.json",
                         "origin": [192, 128, 0], "scale": [1, 1, 1], "angles": [0, 0, 0],
                         "visible": True}],
        },
    }
    for name, contents in files.items():
        path = folder / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(contents if isinstance(contents, str) else json.dumps(contents))
    return folder / "project.json"


def origin_animation_fixture(root):
    """An opaque intro card must slide offscreen, not hide half the canvas forever."""
    folder = root / "generated-origin-animation"
    files = {
        "project.json": {"title": "Origin curtain timeline", "type": "scene",
                         "file": "layout.json", "general": {"properties": {}}},
        "models/card.json": {"width": 192, "height": 256, "material": "materials/card.json"},
        "materials/card.json": {"passes": [{"shader": "card", "blending": "normal",
                                            "cullmode": "nocull", "depthtest": "disabled",
                                            "depthwrite": "disabled"}]},
        "shaders/card.vert": """uniform mat4 g_ModelViewProjectionMatrix;
attribute vec3 a_Position;
void main() {
    gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
}
""",
        "shaders/card.frag": "void main() {\n    gl_FragColor = vec4(0.0, 0.0, 0.0, 1.0);\n}\n",
        "layout.json": {
            "camera": {"center": [0, 0, 0], "eye": [0, 0, 1], "up": [0, 1, 0]},
            "general": {"clearcolor": [0.2, 0.4, 0.6], "cameraparallax": False, "bloom": False,
                        "orthogonalprojection": {"width": 384, "height": 256}},
            "objects": [{"id": 1, "name": "curtain", "image": "models/card.json",
                         "alignment": "left", "origin": {"value": [192, 128, 0], "animation": {
                             "relative": True,
                             "options": {"fps": 60, "length": 30, "mode": "single"},
                             "c0": [{"frame": 0, "value": 0}, {"frame": 30, "value": 192}],
                         }}}],
        },
    }
    for name, contents in files.items():
        path = folder / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(contents if isinstance(contents, str) else json.dumps(contents))
    return folder / "project.json"


def check_generated_pixels(data, index):
    """Independent assertions so two equally blank/corrupt outputs cannot pass."""
    magic, dimensions, maximum, pixels = data.split(b"\n", 3)
    width, height = map(int, dimensions.split())
    if (magic, maximum, width, height) != (b"P6", b"255", 384, 256):
        return False
    if len(pixels) != width * height * 3:
        return False
    def pixel(x, y):
        offset = (y * width + x) * 3
        return pixels[offset:offset + 3]
    if index in (8, 11):
        # Index 8: a half-covered source over transparent, half-covered and opaque
        # targets, the children of a compose layer without copybackground: Wallpaper
        # Engine draws them with alpha MAX (sub_1401ECB20), Aout = max(As, Ad).
        # Index 11: the same children as alpha-to-coverage on one sample: a fragment
        # below half alpha is not covered (the 0.25 source never, the 0.25 target third
        # neither) and a covered one is written unblended (0.625 -> 159, 1 -> 255).
        # RGB readback makes the composed alpha observable.
        expected = [(96, 128), (192, 128), (288, 255)] if index == 8 else [(96, 0), (192, 159), (288, 255)]
        return all(abs(channel - value) <= 1
                   for x, value in expected
                   for channel in pixel(x, 128))
    if index == 9:
        # The page has to cover the centre and the margin has to stay exactly the
        # authored clear colour, so a blank, inverted or recoloured frame fails.
        return (all(channel >= 254 for channel in pixel(192, 128)) and
                all(abs(channel - expected) <= 1
                    for x, y in [(48, 32), (48, 224)]
                    for channel, expected in zip(pixel(x, y), (26, 51, 77))))
    if index == 10:
        # Both halves must reveal the coloured canvas once the curtain finishes.
        return all(abs(channel - expected) <= 1
                   for x in (48, 192, 336)
                   for channel, expected in zip(pixel(x, 128), (51, 102, 153)))
    background = pixel(0, 0)
    # First effect must really draw; empty/hidden nested layers must not leak
    # that earlier effect's pixels. Visible children must survive their clears.
    if pixel(40, 216) == background:
        return False
    if index in (0, 1, 6):
        return all(pixel(x, y) == background for y in range(130, 142) for x in range(174, 186))
    return pixel(180, 136) != background


def discard_foreign_build_tree(build, source):
    """Delete a CMake build tree configured from a source directory other than `source`.

    CMake refuses to reconfigure such a tree, which happens to every tree made before
    the engine moved (it was under upstream/renderer/external/open-wallpaper-engine).
    """
    cache = build / "CMakeCache.txt"
    if not cache.is_file():
        return False
    for line in cache.read_text(errors="replace").splitlines():
        if line.startswith("CMAKE_HOME_DIRECTORY:"):
            configured = Path(line.split("=", 1)[1])
            if configured.resolve() == Path(source).resolve():
                return False
            break
    shutil.rmtree(build)
    return True


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--assets", type=Path, default=Path.home() / "Library/Application Support/WallpaperMachine/SceneAssets")
    parser.add_argument("--project", action="append", type=Path, default=[], help="Additional local scene project; repeatable")
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--allow-missing-gpu", action="store_true",
                        help="CI only: allow explicit GPU skips when a compiled Metal-device probe exits 77. Other failures still fail.")
    parser.add_argument("--allow-imprecise-timers", action="store_true",
                        help="CI only: skip the named wall-clock cadence tests when a compiled timer probe exits 77. Other failures still fail.")
    args = parser.parse_args(argv)
    out = RENDERER_ARTIFACTS / ("adaptive-" + datetime.now().strftime("%Y%m%d-%H%M%S"))
    out.mkdir(parents=True)
    # Generated scenes must not depend on an installed wallpaper library.
    generated_assets = fixture_assets(out / "generated-assets")
    env = build_environment()
    build = RENDERER_ARTIFACTS / "bin"
    if not args.skip_build:
        if discard_foreign_build_tree(build, ENGINE):
            print(f"Removed {build}: it was configured from another engine source directory")
        # Cargo must run inside the workspace it builds (Renderer/ for the shader layer):
        # rustup resolves rust-toolchain.toml from the working directory, not --manifest-path.
        steps = [
            (["cargo", "build", "-p", "wm-shader", "--features", "ffi", "--release", "--locked"], "shader-build", RENDERER),
            (["cmake", "-S", ENGINE, "-B", build, "-DCMAKE_BUILD_TYPE=Release", "-DBUILD_TESTS=ON", "-DRUST_SHADER_FFI=ON", "-DRUST_SHADER_STATICLIB=" + str(RENDERER / "target/release/libwm_shader.a")], "configure", ROOT),
            (["cmake", "--build", build, "--target", OFFSCREEN_PROBE, RELOAD_PROBE, TIMER_DELIVERY_BENCHMARK, *REGRESSION_BINARIES, "-j", "6"], "build", ROOT),
        ]
        for command, name, cwd in steps:
            # Cargo gets the environment without the deployment-target pin:
            # it builds host proc-macro dylibs that the compiler then loads, and
            # a pinned one is rejected at load. See build.cargo_environment.
            step_env = cargo_environment() if command[0] == "cargo" else env
            if run(command, out / (name + ".log"), step_env, 600, cwd):
                print(f"Build failed; see {out / (name + '.log')}")
                return 1
    report = {"desktop_automation": False, "gpu_surface": False, "cases": [], "skips": {}}
    gpu_available = True
    if args.allow_missing_gpu:
        report["gpu_preflight"] = gpu_preflight(out, env)
        probe = report["gpu_preflight"]
        if probe["compile_exit"] != 0 or probe["probe_exit"] not in (0, 77):
            (out / "report.json").write_text(json.dumps(report, indent=2))
            print(f"GPU preflight failed: {probe}; see {out}")
            return 1
        gpu_available = probe["probe_exit"] == 0
    report["gpu_checks_executed"] = gpu_available
    timers_precise = True
    if args.allow_imprecise_timers:
        report["timer_preflight"] = timer_preflight(out, env)
        probe = report["timer_preflight"]
        if probe["compile_exit"] != 0 or probe["probe_exit"] not in (0, 77):
            (out / "report.json").write_text(json.dumps(report, indent=2))
            print(f"Timer preflight failed: {probe}; see {out}")
            return 1
        timers_precise = probe["probe_exit"] == 0
    report["realtime_checks_executed"] = timers_precise
    timer_evidence = ""
    if not timers_precise:
        log = out / "timer-probe_exit.log"
        timer_evidence = log.read_text(errors="replace").strip() if log.exists() else ""
    if not gpu_available:
        skipped = [name for name, needs_gpu in REGRESSION_BINARIES.items() if needs_gpu] + [OFFSCREEN_PROBE, RELOAD_PROBE]
        for name in skipped:
            report[name] = "skipped-no-gpu"
            report["skips"][name] = ["compiled Metal-device probe reported no device (exit 77)"]
        print("::warning::No Metal device; unverified GPU targets: " + ", ".join(skipped), flush=True)
    # video_decode_pump_test and video_color_conversion_test need no GPU at all;
    # metal_video_texture_test imports synthetic video frames into private textures.
    for binary, needs_gpu in REGRESSION_BINARIES.items():
        if needs_gpu and not gpu_available:
            continue
        command = [build / "tests" / binary]
        realtime = () if timers_precise else REALTIME_TESTS.get(binary, ())
        if realtime:
            command.append("--gtest_filter=-" + ":".join(realtime))
        try:
            status = run(command, out / (binary + ".log"), env, 600)
        except subprocess.TimeoutExpired:
            status = "timeout"
        report[binary] = status
        record_skips(report, binary, out / (binary + ".log"))
        report_skips(report, binary, [f"{name}: timer probe exit 77, 10 ms waits overshoot a period ({timer_evidence})"
                                      for name in realtime])
    benchmark = collect_timer_delivery_benchmark(build, out, env)
    report[TIMER_DELIVERY_BENCHMARK] = benchmark
    if benchmark["status"] == "collected":
        print(f"{TIMER_DELIVERY_BENCHMARK} (diagnostic only): delivered={benchmark['measurement']['delivered']}; "
              f"actual_outer_duration_ns={benchmark['actual_outer_duration_ns']}; "
              f"delivered_per_second={benchmark['delivered_per_second']:.3f}", flush=True)
    else:
        print(f"{TIMER_DELIVERY_BENCHMARK} tooling failure: {benchmark['error']}; see {benchmark['log']}", flush=True)
    generated_projects = ([*fixtures(out / "fixtures"), alpha_composite_fixture(out / "fixtures"),
                 perspective_animation_fixture(out / "fixtures"),
                 origin_animation_fixture(out / "fixtures"),
                 alpha_composite_fixture(out / "fixtures", alpha_to_coverage=True)] if gpu_available else [])
    projects = [*generated_projects, *args.project] if gpu_available else []
    for index, project in enumerate(projects):
        project = project.resolve()
        assets = generated_assets if index < len(generated_projects) else args.assets
        manifest_bytes = project.read_bytes()
        manifest = json.loads(manifest_bytes)
        package = project.parent / Path(manifest.get("file", "scene.json")).with_suffix(".pkg")
        case = {"project": str(project), "runs": [], "project_sha256": hashlib.sha256(manifest_bytes).hexdigest()}
        if package.is_file():
            with package.open("rb") as stream:
                case["package_sha256"] = hashlib.file_digest(stream, "sha256").hexdigest()
        case_dir = out / ("case-" + str(len(report["cases"])))
        case_dir.mkdir()
        for mode in ["pooled", "isolated"]:
            mode_env = env.copy()
            mode_env.update(WE_TEST_PROJECT=str(project), WE_TEST_ASSETS=str(assets.resolve()), WE_TEST_OUTPUT=str(case_dir / mode))
            for key in ["WE_TEST_NO_REUSE", "WE_TEST_DUMP_PASSES", "WE_DEBUG_SKIP_NODE", "WE_DEBUG_SKIP_MATERIAL", "WE_DEBUG_SKIP_PASSTHROUGH"]:
                mode_env.pop(key, None)
            if mode == "isolated":
                mode_env["WE_TEST_NO_REUSE"] = "1"
            try:
                status = run([build / "tests" / OFFSCREEN_PROBE], case_dir / (mode + ".log"), mode_env)
            except subprocess.TimeoutExpired:
                status = "timeout"
            case["runs"].append({"mode": mode, "exit": status})
            record_skips(report, f"{case_dir.name}/{mode}", case_dir / (mode + ".log"))
        # Rendering without a crash does not prove all authored effects loaded.
        case["diagnostics"] = []
        for mode in ["pooled", "isolated"]:
            for line in (case_dir / (mode + ".log")).read_text(errors="replace").splitlines():
                if "ERROR" in line and 'not found "/cache/' not in line:
                    if line not in case["diagnostics"]:
                        case["diagnostics"].append(line)
        case["pixels_equal"] = False
        if all(r["exit"] == 0 for r in case["runs"]):
            pooled = (case_dir / "pooled/frame-2.ppm").read_bytes()
            isolated = (case_dir / "isolated/frame-2.ppm").read_bytes()
            case["pixels_equal"] = pooled == isolated
            case["sha256"] = hashlib.sha256(pooled).hexdigest()
            if len(report["cases"]) < GENERATED_CASE_COUNT:
                case["expected_pixels"] = check_generated_pixels(pooled, len(report["cases"]))
        case["full_compatibility_verified"] = False  # No authored-reference comparison.
        report["cases"].append(case)
        (out / "report.json").write_text(json.dumps(report, indent=2))
        print(f"{project.parent.name}: {case['runs']}; pixels_equal={case['pixels_equal']}; diagnostics={len(case['diagnostics'])}", flush=True)
    # Switching wallpapers reloads scenes inside one process; per-process state
    # left behind by a previous load must not stall the next parse.
    reload_projects = ([p.resolve() for p in args.project] or list(fixtures(out / "fixtures"))) if gpu_available else []
    reload_env = env.copy()
    reload_env.update(
        WE_TEST_PROJECTS=";".join(str(p) for p in reload_projects),
        WE_TEST_ASSETS=str((args.assets if args.project else generated_assets).resolve()),
        WE_TEST_OUTPUT=str(out / "reload-cycles"),
        WE_TEST_CYCLES="2",
    )
    if gpu_available:
        try:
            report[RELOAD_PROBE] = run(
                [build / "tests" / RELOAD_PROBE], out / "reload-cycles.log", reload_env,
                60 + 60 * len(reload_projects))
        except subprocess.TimeoutExpired:
            report[RELOAD_PROBE] = "timeout"
        record_skips(report, RELOAD_PROBE, out / "reload-cycles.log")
    (out / "report.json").write_text(json.dumps(report, indent=2))
    print(f"reload cycles ({len(reload_projects)} projects x2): {report['scene_reload_cycle_probe']}", flush=True)
    print(f"Evidence: {out}")
    return int(any(report[k] not in (0, "skipped-no-gpu") for k in (*REGRESSION_BINARIES, RELOAD_PROBE))
               or report[TIMER_DELIVERY_BENCHMARK]["status"] != "collected"
               or any(not c["pixels_equal"] for c in report["cases"])
               or any(c["diagnostics"] or not c.get("expected_pixels", False)
                      for c in report["cases"][:GENERATED_CASE_COUNT]))


if __name__ == "__main__":
    raise SystemExit(main())
