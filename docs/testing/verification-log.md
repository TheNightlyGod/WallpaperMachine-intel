# Verification log

Append-only history of what was actually verified, when, and with what result.
The newest entry goes on top; never rewrite an older entry to match today's
tree. Every entry is evidence about the tree it was taken on, not about the
current one — re-run the relevant checks after integration and add a new entry
instead of reusing an old result. Durable guidance belongs in the sibling docs:
test layers and policy in [README.md](README.md), renderer commands and
regression areas in [renderer.md](renderer.md), manual checks in
[manual-smoke.md](manual-smoke.md). Result bundles and probe output are local
and disposable, so entries state counts and commands rather than artifact
paths.

Entry format, so the log stays skimmable: a one-line summary heading, one short
paragraph of context only when the result needs it, then a bullet per command
with its exit status, counts and any skip. Keep an entry around ten lines. A
fact that will still matter next week is not an entry — promote it to the doc
that owns it (renderer behaviour and known-failing tests to
[renderer.md](renderer.md), build and signing traps to
[../build.md](../build.md)) and cite it from there.

Retention: this file keeps the ten newest entries. Add an entry with
`python3 scripts/log_verification.py --title "…" --line "…"`, which prepends it
and moves whatever falls past ten verbatim into a monthly file under
[archive/](archive/); promote anything durable before it goes. Editing an
entry's recorded result is not allowed.

## 2026-11-03 — Web lock screen: page paused state follows the surface (issue 155)

- Cause: the extension created a web page paused before its first frame while WallpaperSurface tracked it as playing; applyPolicy never resumed it, so the settling desktop and any lock within ~15 s kept the readiness frame (black/grey for 音域回响 and 阿洛娜指纹识别2.0). Evidence: unified log showed WebPageProxy::suspend 60 ms after load and no resume at the following lock.
- Fix: Extension/WallpaperSurface.swift creates and updates the page with rendererPaused, like scenes and clips; docs/features/lock-screen.md updated.
- python3 scripts/test.py: 4296 passed, 0 failed, 53 skipped.
- python3 scripts/build.py --swift-only --configuration Release: OK.
- Gap: WallpaperSurface is extension-only and has no unit-test harness, so no regression test; real lock behaviour not checked by the agent.

## 2026-11-03 — Web lock screen: a busy page no longer fails its pause or resume

- Symptom: a 3D web wallpaper sometimes held a still frame on lock; the app log showed 'The web wallpaper did not produce a frame in time.' at unlock and the lock screen was handed back to macOS.
- Unified log: on resume the extension's WebKit GPU process got a process-limit-critical memory event (32) and WebKit's display link reported the main thread stuck; the page's property delivery ran only after the 5 s transition deadline had closed the page.
- Fix: ScreenSaverWebSurface bounds waits on the page (properties, media, held frame) at 5 s and goes on without them; only WebKit's suspend/resume not answering within 15 s fails the surface.
- New test ScreenSaverWebSurfaceTests/testABusyPageIsStillResumedAndPausedWithoutFailingTheSurface fails on the old reconcile with timedOut, passes with the fix.
- python3 scripts/test.py: 4291 passed, 0 failed, 53 skipped. Release build OK.
- Not verified: repeated real locks with the user's wallpaper; why the GPU process reaches its limit on resume (two copies of a heavy page: desktop and lock screen) is not addressed.

## 2026-11-03 — Web lock screen and screen saver: export the live page, not only its snapshot

- Symptom after the issue 155 change: a web wallpaper on the lock screen showed a still frame; extension.log showed it was not paused while locked.
- Cause: ScreenSaverWebSurface.attach added the content view's backing layer to the exported root; AppKit kept it in the window's tree, so the CAContext held only the readiness snapshot beneath it (screen saver too).
- Headless probe (never-ordered window, CARenderer over the root): old attach left the root empty; exporting the frame view layer rendered the page's canvas alternating red/blue.
- New test ScreenSaverWebSurfaceTests/testTheLivePageStaysInTheLayerTreeItWasAttachedTo fails on the old attach, passes with the fix.
- python3 scripts/test.py: 4290 passed, 0 failed, 53 skipped. Release build: python3 scripts/build.py --swift-only --configuration Release, OK.
- Not verified: a real lock with the web wallpaper (the user's next run), and the screen saver on a real idle.

## 2026-11-03 — Web and still wallpapers animate the lock screen (issue 155)

- Change: web projects (and still images, which are web projects) are published for Animate lock screen, take the Desktop selection and follow the lock-screen settle/pause policy in the extension; the 'not applicable' status and compatibility verdict are gone.
- python3 scripts/test.py --only LockScreenWallpaperServiceTests --only WallpaperCompatibilityTests --only ScreenSaverWebSurfaceTests --only WallpaperPresentationAuthorityTests: 108 passed.
- python3 scripts/test.py: 4289 passed, 0 failed, 53 skipped; Python stage (localization catalogs, panel localization, doc links) OK.
- New test: a web wallpaper takes the lock screen and keeps it when the screen saver turns off.
- Catalogs: five web-surface errors reworded from 'web screen saver' to 'web wallpaper' in both catalogs; compatibility and Settings copy updated; three unused keys removed; all six languages.
- Not verified: a real lock/unlock with a web wallpaper on the desktop, extension WebKit memory while held, no Release build.

## 2026-11-02 — When another app is in front (discussion #91)

- Feature: Settings → Playback & Power gains When another app is in front (Keep running / Mute / Pause), default Keep running.
- AppRuleMonitor adds the chosen action while the frontmost app is not Finder or this app; no app in front counts as the desktop.
- python3 scripts/test.py --only AppRuleMonitorTests, PlaybackPreferencesTests, PanelSettingsResetTests, ConditionOverrideTests and six more Panel/Backup classes: 120 passed.
- python3 scripts/test.py: Python stage OK; native 4287 passed, 0 failed, 53 skipped.
- Localization catalog and panel localization checks pass; five languages added for title, note and prose.
- Not checked: the setting on a real desktop (no desktop run requested); the app was not rebuilt.

## 2026-11-01 — Discord invitation, About entry and Help menu item

A fifth one-time prompt, Join us on Discord?, invites once to MMFoundation's Discord through https://mmfoundation.dev/discord (ExternalLink.discord, allowlisted; never the invite itself), last in priority, after 21 days and 7 days of panel use on the star prompt's clock. Settings › About gains Join Discord beside MMFoundation and the Help menu gains Join Discord; either spends the invitation. Strings in all six languages.

- `python3 scripts/test.py --only SupportPromptStoreTests --only PanelSupportPromptTests --only SupportPromptPresenterTests --only WelcomeRenderTests --only SettingsSectionsLocalizationTests --only ExternalLinkTests` — 62 passed (after `xattr -cr build/Build/Products/Debug`, docs/build.md)
- `python3 scripts/test.py` — 4268 passed, 0 failed, 52 skipped
- `python3 scripts/build.py --swift-only --configuration Release` — OK
- Sheet (en, zh-Hans) and Settings › About (en, zh-Hans) rendered offscreen from a never-shown window to check the layout; the app was not launched and the Help menu item was not opened by hand

## 2026-11-01 — MMFoundation link in Settings › About

Settings › About gains an MMFoundation button beside the GPL link, opening https://mmfoundation.dev/ through ExternalLink's allowlist (mmfoundation.dev added); READMEs in all four languages name MMFoundation with a link. Run while another task's uncommitted Spaces/desktop-picture edits were in the same checkout.

- `python3 scripts/test.py --only ExternalLinkTests` — 5 passed (after `xattr -cr build/Build/Products/Debug`, docs/build.md)
- `python3 scripts/test.py --only SettingsSectionsLocalizationTests` — 2 passed; MMFoundation added to its same-everywhere names
- `python3 scripts/test.py` — first run 2 failed: the localization test above (fixed) and EnergyUsageMonitorTests.testKernelCountersForThisProcessAdvanceWithGPUWork (3.4 mW, hardware counter); rerun 4258 passed, 0 failed, 52 skipped
- Not checked: the button on screen (no desktop run requested); no Release build

## 2026-10-31 — Video windows and the desktop picture (PR #138)

The poster sync now hears about native video windows that open or close after a snapshot (`DesktopWallpaperSync.surfacesChanged`).

- `python3 scripts/test.py --only DesktopWallpaperTests` — 90 passed; the new tests fail against the PR's original `refresh(.unsettled)` + `presentationResumed()`, against recording the surfaces before the ledger write, and against an empty map standing for a pass not yet made
- `python3 scripts/test.py` — 4257 passed, 0 failed, 52 skipped (Debug product xattrs cleared per docs/build.md; `build.py --renderer-only` first, the installed library predated main)
- Not checked: the menu bar colour and Mission Control on a real desktop, a video window opened on a second display; the app was not rebuilt

## 2026-10-31 — WE 2.8 parity rebased onto main 1.6.6 (PR #137)

- Merged origin/main (53 commits) into the parity branch and rebuilt it as eight domain commits on main; the final commit's tree is the gated one.
- Overlaps kept this branch's WE-derived code (script ModelData, particle script controls, puppet bones and layers, SKINNING_ALPHA gate, cursor localPosition, colour emoji); main's tests kept and adapted, four dropped where they contradict the native (listed in the PR).
- Kept from main: texture channels, MetalFX, capability probe and missing files, level clipping (plus volume textures), click on release, live material constants, compose-layer script children, poster generator (plus colour options), pt-BR (new strings translated).
- WE loader 0x140261880 read again: the MDLA version-3 block is texture channels (count, then per channel a skipped word and frames + 1 floats).
- check_rust.py OK; build.py --renderer-only OK; check_renderer.py 3,390 passed, 0 failed, 7 skipped; test.py 4,252 passed, 0 failed, 52 skipped.
- Not run after the rebase: 17-scene sweep, Release build, desktop run.

## 2026-10-31 — WE 2.8.0.42 parity round 6: steady rope smoothing, 3D perspective layers, sorting toggle, HDR and energy on the desktop

- Steady uvsmoothing: WE probe rope-uv-v5 (5 variants) within ~0.01 of WE on shot 0; the 8 Hz smoothed rope stays off (+0.014 against WE's -0.110) and shot 1 has a clock offset (12.198 s against 12.292 s).
- Perspective layers in 3D: six WE camera probes (eye, fov 30/50, centre) give the same MVP x/y/w columns; the z column differs and was not compared. PerspectiveImage 6/6.
- Out-of-plane IK ropes: WE controls with the rope tilted/yawed 60 degrees agree with WE as well as the untilted control does (whole-frame correlation 0.82/0.71 against 0.58); no local puppet has a branched rope.
- Sorting runtime toggle: WE probes sort-runtime-off-v1/on-v1 match 36/36 samples, 4 cells change between the states; WE stayed up (no DXGI loss).
- HDR: built-in XDR (headroom 8), scene 3662790108. Display HDR peaks at about 53 against Ultra's 1.0, on 0.035 % of pixels, same median. Brightness as seen by eye was not compared with WE.
- Energy (coalition, no root, VM suspended): scene 3615154110, three alternating new/old pairs at ~60 fps, difference under ~0.5 W GPU (upper bound). Display HDR 29.4 W against Ultra 25.1 W on 3662790108. No powermetrics.
- check_renderer: 3,322 passed, 0 failed, 7 skipped; build.py --renderer-only OK; test.py 4,150 passed, 0 failed, 50 skipped; Release build OK.
- 17-scene sweep against the previous final: 34/34 frames rendered and within 0.3 mean, except 3280146735-0, whose date text changes with the calendar day (calendar caveat), and 3665954520-1 (+0.24).
