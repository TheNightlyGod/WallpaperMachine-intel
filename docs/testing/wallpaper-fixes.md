# Fixing a wallpaper that looks wrong

The order of work for a report that a wallpaper renders or behaves differently from
Wallpaper Engine, and the techniques that found the rule quickly. The rules themselves
are in [AGENTS.md](../../AGENTS.md): repair the general mechanism, never special-case a
wallpaper, test first, and judge by Wallpaper Engine's own frame. The tools are in
[wallpaper-engine-reference.md](wallpaper-engine-reference.md); agents reach this page
through the `wallpaper-issue` skill.

## What needs no question

A wallpaper fix may, without asking:

- download the reported Workshop item with `scripts/we_reference.py fetch`, which runs a
  scratch copy of the app's SteamCMD with the app's saved Steam sign-in and deletes the
  copy afterwards;
- wake the Parallels Windows VM, capture Wallpaper Engine's frames in it (muted) and
  suspend it again.

Everything else on the [authorization boundary](README.md#authorization-boundary) still
needs the user: a new Steam sign-in (when `fetch` reports that the saved one is no
longer accepted, stop and ask the user to sign in again in the app; never type
credentials or Steam Guard codes), driving the VM's desktop (only reinstalling the
poller needs it), and changing the user's wallpaper or restarting the app.

## 1. Is it a rendering problem?

Work in one task folder, `artifacts/issue-<n>/`.

1. From the issue, note the Workshop id (`?id=` in the link), what looks wrong and
   where on the screen, and anything that changes the picture: user properties, screen
   size, time of day, audio or the cursor.
2. Get the wallpaper. An id in the app's library is used as it is; otherwise
   `python3 scripts/we_reference.py fetch <id> --into artifacts/issue-<n>` and pass the
   folder `artifacts/issue-<n>/<id>` wherever an id goes below (the folder's name is the
   id, so its frames are shared like any other).
3. Get Wallpaper Engine's frames. Reuse `artifacts/we-reference/shots/<id>-0.png` and
   `-1.png` in the main checkout when they exist. Otherwise wake the VM
   (`open -a "Parallels Desktop"`), run `capture`, and suspend the VM through the menu
   command in [Capturing](wallpaper-engine-reference.md#capturing).
4. Before touching renderer code, keep the current harness for the "before" render:
   `cp artifacts/renderer/bin/tests/metal_scene_draw_smoke artifacts/issue-<n>/smoke-before`
   (run `python3 scripts/check_renderer.py` first if it is missing). Any later build
   overwrites it.
5. `render <wallpaper> --binary artifacts/issue-<n>/smoke-before --label before`, then
   `compare <wallpaper> --labels before`, and look at the sheet where the report points.

The verdict:

- Our render matches Wallpaper Engine there, within the noise in
  [Reading a sheet](wallpaper-engine-reference.md#reading-a-sheet): the report's picture
  is an edited or outdated preview, or a setting the reporter changed. Say so in the
  report with the sheet's numbers and change no renderer code.
- Wallpaper Engine draws it differently: a real bug. Describe the difference in
  rendering terms (colour, position, timing, missing layer) before reading code.
- The report depends on something the capture cannot show (audio, interaction, a
  moment long after the 8 s and 15 s shots): say what was and was not compared.

## 2. Find the mechanism

- `python3 scripts/we_reference.py unpack <wallpaper> --into artifacts/issue-<n>/unpacked`
  and read `scene.json`: find the object at the reported place (its `name` and
  `origin`), then its material, effects, particle preset, `instanceoverride` and any
  user property bound to it. Those files say which feature is involved; the wallpaper
  never names the fix.
- Find the code that reads those keys: `rg '<key>'
  Renderer/Engine/src` (scene parsing is in
  `src/Scene/Parse/`), and the regression page for the area
  ([scene](scene-regressions.md) or [runtime](runtime-regressions.md)) for the tests
  that already guard it.
- Shrink the case when the scene is busy: an unpacked folder with its `project.json`
  is itself a wallpaper, so a copy with objects or effects removed shows which one
  carries the difference.

### Read the rule off Wallpaper Engine, do not guess it

When it is unclear what Wallpaper Engine does, build a generated probe scene instead of
reasoning from our code or another port. Put each case in its own cell of a grid (for
colour, an opaque sprite with `util/white` and a constant colour), capture the probe
folder once like a wallpaper, and read the pixel at each cell's centre: `sips -s format
bmp` converts a shot, and `we_reference.read_bmp` returns its pixels. Scene coordinates
have y up; a shot shows the scene scaled by `max(W / width, H / height)` and centred.
The probe's `project.json` needs `"type": "scene"`, `"file": "scene.json"` and
`"general": {"properties": {}}`, or `render` refuses it. Put many cases in one scene,
because each capture costs about a minute, and include the cases where the current
code is believed right, to check the rule against them. Generator scripts go in
`artifacts/issue-<n>/tools/`, apart from downloaded files.

Issue #67 is the example: two probe scenes of 22 cells pinned the particle colour
override rule, 13 cells matched before the fix and all 22 to the 8-bit level after.

## 3. Fix

1. Write the general test first, in the test binary that owns the area (for example
   `particle_parity_test`), named for the behavior, not the wallpaper, and failing on
   the current code. A test that asserts the old, wrong behavior is replaced, citing
   the probe evidence.
2. Iterate with an incremental build of the touched targets, then run them:
   `cmake --build artifacts/renderer/bin --target <test> metal_scene_draw_smoke -j 8`
   and `artifacts/renderer/bin/tests/<test> --gtest_filter='<Suite>.*'`.
3. Prefer work at load or spawn time to work per frame; no extra passes or caches to
   cover a bug (see AGENTS.md).
4. Update the owning feature doc and the regression page in the same change. A change
   under `ThirdParty/` also adds an entry to `ThirdParty/provenance.json`: date, issue,
   the evidence and the regression tests.

## 4. Verify

- `render <wallpaper> --label after` (the freshly built harness), then
  `compare <wallpaper> --labels before,after`. Render and sample the probe scenes the
  same way, before and after.
- Report Wallpaper Engine against before and after where the report points, the mean
  difference and share of pixels off by more than 48, and why what remains is not the
  bug (random particles, fog, the watermark).
- Gates: `python3 scripts/test.py` once at the end, `python3 scripts/check_renderer.py`
  for renderer changes and `python3 scripts/check_rust.py` for Rust crate changes.
- Suspend the VM if this task woke it.

## 5. Deliver and clean up

- Commit under the AGENTS.md rules, one commit per purpose, with `Fixes #<n>` in the
  fix's body so pushing it to `main` closes the issue. Push only when asked.
- Delete `artifacts/issue-<n>/` (the downloaded wallpaper is someone else's work and
  stays out of Git), this task's renders and sheets in `artifacts/we-reference/`
  (`before/`, `after/`, `compare/`) and this task's renderer check runs. Keep the
  Workshop items' frames in the main checkout's `shots/`; a probe scene's shots are
  named after this task's probe folder, no other task can use them, and they go too.

## Traps

- SteamCMD killed at launch (exit 137) inside an agent's command sandbox: run `fetch`
  outside it.
- `capture` waits and the VM never asks for work: the VM is asleep, or its poller is
  missing (reinstalling it drives the VM's desktop, so ask).
- A "before" render taken after a rebuild is an "after" render. If the copy in step 4
  was missed, build the harness from a checkout of the commit before the change.
- The issue's screenshot and the Workshop preview are not targets, even when the
  report compares against them.
- Wallpaper Engine changes some rules with `scene.json`'s `version` (the particle
  colour override tints once from version 5, twice before): give a probe scene the
  reported scene's `version`, and capture the probe at both sides of a suspected gate.
- A probe particle emitter with `"directions": "0 0 0"` and a `movement` operator draws
  nothing at all in Wallpaper Engine, and one such cell blanks the whole probe; use
  `"1 1 1"` with zero distances to emit from one point.
