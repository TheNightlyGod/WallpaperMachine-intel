---
name: wallpaper-issue
description: Triage and fix a WallpaperMachine report that a wallpaper looks or behaves differently from Wallpaper Engine (wrong colours, missing or misplaced layers, effects, particles, text, timing), usually a GitHub issue with a Workshop id. Downloads the wallpaper with the app's saved Steam sign-in, captures Wallpaper Engine's own frames in the Parallels Windows VM, decides whether the report is a real rendering bug or a misleading preview, then fixes the general mechanism with a test first and a before/after comparison.
---

# Wallpaper issue: triage, fix, verify

The guide is [docs/testing/wallpaper-fixes.md](../../../docs/testing/wallpaper-fixes.md);
read it first and follow its order. The rules in [AGENTS.md](../../../AGENTS.md) outrank
this skill. This skill grants nothing beyond them; the standing permissions it relies on
are written there.

Without asking the user, a wallpaper fix may:

- download the reported item: `python3 scripts/we_reference.py fetch <id> --into artifacts/issue-<n>`
  (the app's saved Steam sign-in, never a new one; if it reports the sign-in is no longer
  accepted, stop and ask the user to sign in again in the app);
- wake the Parallels Windows VM (`open -a "Parallels Desktop"`), capture Wallpaper
  Engine's frames with `capture` (muted, started by the VM's background poller), and
  suspend the VM again through the Parallels menu
  ([how](../../../docs/testing/wallpaper-engine-reference.md#capturing)).

Steps, each detailed in the guide:

1. Triage: get the wallpaper and Wallpaper Engine's frames (reuse shared shots), copy
   `metal_scene_draw_smoke` to `artifacts/issue-<n>/smoke-before` before any renderer
   edit, render `before`, compare. Ours matching Wallpaper Engine means it is not a
   renderer bug: report that with the numbers and stop.
2. Localize: `we_reference.py unpack`, read `scene.json`, find the parser code for the
   keys involved. When Wallpaper Engine's rule is unclear, capture a generated probe
   scene and read the pixels instead of guessing.
3. Fix the general mechanism with a failing test first; no per-frame cost; a
   `ThirdParty/` change updates `ThirdParty/provenance.json` and the owning docs.
4. Verify: render `after`, compare `before,after`, run the gates once, suspend the VM.
5. Deliver: commit with `Fixes #<n>` in the body (push only when asked), Release build
   only per AGENTS.md or local opt-in, delete this task's `artifacts/` output, keep the
   Workshop items' shared shots.

Report the verdict (real bug or preview mismatch), the evidence, the comparison numbers,
what was not compared, and the cleanup in one line.
