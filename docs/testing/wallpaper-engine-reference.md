# Wallpaper Engine reference frames

When a wallpaper looks wrong, the target is what Wallpaper Engine itself draws for it.
An author's preview image, a screenshot attached to an issue, and our own earlier
render are not targets: previews are often edited or out of date, and an earlier
render carries our own bugs. `scripts/we_reference.py` captures Wallpaper Engine's
frames in a Parallels Windows VM, renders the same wallpaper with Native Metal at the
same size and moment, and puts the two side by side. The order of work for a whole
fix is in [wallpaper-fixes.md](wallpaper-fixes.md).

## When to use it

- Every fix to how a scene looks (shaders, effects, layers, particles, text, scripts,
  cameras, playback): compare before the fix and after it. A fix is done when the
  "after" render is closer to Wallpaper Engine's frame where the report was, and no
  further from it anywhere else on the sheet. A difference that is still there gets
  explained in the report, not left out.
- Reuse frames that were already captured (see [Where things go](#where-things-go)).
  Capture only for a wallpaper that has none, after Wallpaper Engine updates, or when
  the old frames look wrong.
- Without the VM, say in the report that the fix was not compared with Wallpaper
  Engine. A comparison is evidence for a fix, not a gate: it needs the VM, and its
  numbers are coarse.

`render` draws scenes only. Web and video wallpapers can be captured, and their
frames are still the target, but they are compared by eye with the app's own
picture.

## Setup

- Parallels Desktop with a Windows 11 VM on Parallels' Shared network, where the Mac
  is `10.211.55.2`. Inside the VM: Steam signed in and Wallpaper Engine installed
  under Steam's library. With Parallels Desktop Standard, `prlctl` can list VMs but
  not resume them or run commands in them, so the VM is woken by opening it
  (`open -a "Parallels Desktop"` resumes it) and the worker is started by the
  background poller installed in it (see [Capturing](#capturing)).
- A wallpaper missing from the app's library is downloaded with
  `python3 scripts/we_reference.py fetch <id> --into artifacts/<task>`. It runs a
  scratch copy of the app's SteamCMD with the app's saved Steam sign-in, never signs
  in, deletes the copy (it holds the session) and leaves `artifacts/<task>/<id>/`.
  `unpack <wallpaper> --into <dir>` extracts a wallpaper's `scene.pkg` for reading.
- `metal_scene_draw_smoke` built in this tree: `python3 scripts/check_renderer.py`
  builds it into `artifacts/renderer/bin/tests/`. A binary built before the change
  you are judging renders that change's "before"; pass it with `--binary`.

## Capturing

```bash
python3 scripts/we_reference.py capture 2440387496 2850003448
```

The script serves the listed wallpapers on the Shared network only. A wallpaper is a
Workshop id in the app's library or a folder that holds `project.json` (a folder of
generated probe scenes works too: an opaque `util/white` sprite per case reads a rule
off Wallpaper Engine's frame to the 8-bit level). The VM's background poller runs the
worker within seconds, so a capture needs no keystrokes in the VM and never takes the
Mac's focus. Without the poller, the script's printed line
`iex (irm http://10.211.55.2:8765/worker.ps1)` runs the worker once from PowerShell in
the VM.

The poller is installed once, from PowerShell in the VM while a capture is serving:
`iex (irm http://10.211.55.2:8765/install-poller.ps1)`. It writes
`%LOCALAPPDATA%\we-reference\poller.ps1`, adds a `we-reference-poller` shortcut to the
user's Startup folder and starts it hidden; it fetches `worker.ps1` from the Mac every
five seconds and runs it when a capture answers, one poller per Windows session. It runs
whatever that address serves, so it belongs only in this test VM. Remove the shortcut and
end its `powershell.exe` to uninstall. For each wallpaper the worker:

- copies the wallpaper's files into `%LOCALAPPDATA%\we-reference\<id>` in the VM,
  fetching only files that are missing there or whose size changed;
- starts Wallpaper Engine if it is not running and mutes it before and after
  opening anything. It never unmutes;
- opens the wallpaper on monitor 0 with `wallpaper64.exe -control openWallpaper`,
  hides the desktop icons, minimises every window and centres the cursor;
- takes two screenshots of the whole primary display at physical pixels, about 30 s
  and 45 s after opening (`--delays FIRST SECOND` changes them: Wallpaper Engine in the VM
  can take more than 15 s to show a heavy scene, and an earlier shot catches the previous
  wallpaper or a black desktop), and records when it opened the wallpaper and when it took
  each shot. The real times are used for rendering: the first wallpaper after
  Wallpaper Engine starts has been shot 10 s and 30 s in;
- pauses Wallpaper Engine until the next job and shows the icons again at the end.

The script exits when every wallpaper was captured or failed, or after `--timeout`
seconds. Put the VM back to sleep afterwards (Parallels: Actions > Suspend; without
taking focus: `osascript -e 'tell application "System Events" to tell process
"prl_client_app" to click menu item "Suspend" of menu "Actions" of menu bar 1'`).

Driving the VM from an agent is needed only to install the poller, and takes the Mac's
focus: Parallels reads input only while its window is frontmost, so no background
automation reaches the guest. Synthetic clicks may not reach the guest either and
synthetic typing drops keys or leaves one held down; activate Parallels, press Ctrl+Esc
for Start, and paste through the shared clipboard (write the text, press Cmd+V, then
Return), `powershell` into Start search and then the install line. Wallpaper Engine
stays muted. Never change the Mac's volume.

## Rendering and comparing

```bash
python3 scripts/we_reference.py render 2440387496 --binary <binary built before the fix> --label before
python3 scripts/we_reference.py render 2440387496 --label after
python3 scripts/we_reference.py compare 2440387496 --labels before,after
```

`render` runs `metal_scene_draw_smoke`'s poster test
(`LocalProjectsDrawAPosterPicture`; a binary built before the Vulkan path was removed
names it `DrawTheSamePictureOnBothRenderers`, with `WE_TEST_COMPARE_NATIVE_ONLY`, see
[renderer.md](renderer.md#probe-environment-variables)) for each shot, matching it as
closely as the harness allows:

- the shot's screen size at backing scale 1, with `WE_TEST_COMPARE_RESOLUTION=display`
  because Wallpaper Engine rasterizes at the output size;
- the shot's scene time, in real time (`WE_TEST_COMPARE_REALTIME`), so scripts that
  read the wall clock see the same time pass;
- `TZ` set so that this Mac's clock reads the time of day Wallpaper Engine opened the
  wallpaper, so clocks and day/night scripts show the same hour. The date can differ;
- the pointer at the centre of the screen, silence (`WE_TEST_AUDIO_HZ=0`), and a fixed
  particle seed.

`compare` writes one sheet per shot: Wallpaper Engine's frame, each render in
`--labels` order, and the difference between Wallpaper Engine and the last render
(scaled by 4), all cropped to the Windows work area so the taskbar is left out. It
also writes `metrics.json` and prints, per render, the mean absolute difference
(0 to 255), the share of pixels off by more than 48 in any channel, and the
correlation of brightness. Look at the sheet; the numbers only rank.

## Reading a sheet

Wallpaper Engine's own frames are stable: the same two scenes captured in the VM on
2026-10-14 and again on 2026-10-17 differed by a mean of 0.2 to 1.0 with a brightness
correlation of 0.98 to 0.99, even at different scene times. A difference
well above that between Wallpaper Engine and a render is real. These differences are
not renderer bugs:

- The VM's Windows is not activated: an "Activate Windows" watermark sits in the
  bottom-right corner of Wallpaper Engine's frames.
- Particles are random on both sides: judge their density, size, colour and motion,
  not where each one is.
- Audio-driven layers are silent on both sides (Wallpaper Engine is muted, the render
  is fed silence), so spectrum bars and similar layers rest at their silent state.
- Wallpaper Engine draws through Parallels' virtual GPU. A colour difference of a
  level or two is within the noise measured above and is not evidence either way.
- The opening time is when the open command returned; how long Wallpaper Engine then
  took to load is not recorded, so a fast animation can be a little out of step.

## Where things go

- Wallpaper Engine's frames: `artifacts/we-reference/shots/` in the main checkout,
  shared by every worktree and kept between tasks, since a capture needs the VM.
  `<id>-<k>.png` is shot `k`, and `<id>.json` holds the screen size, the work area,
  the opening and shot times in milliseconds since 1970, and the Wallpaper Engine
  version. Pass `--shots <dir>` to keep a capture apart, for example to check that a
  recapture matches.
- Renders and sheets: this tree's `artifacts/we-reference/<label>/` and
  `artifacts/we-reference/compare/`. They belong to the task and are deleted with
  its other output.
