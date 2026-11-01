---
name: hotfix-release
description: 'Ship an urgent fix to users as its own patch release, without the unreleased work on main. Use when the developer asks for an emergency, urgent, hotfix or "patch release right now" fix (a broken sign-in or download, a crash on launch). Cuts a hotfix/<x.y.z> branch from the newest release tag, puts only the fix on it with its test, runs the gate, and after the developer confirms pushes it with `release: patch`; CI then releases it and merges it back into main.'
---

# Emergency patch release

Follow [Emergency patch release for someone else](../../../docs/release.md#emergency-patch-release-for-someone-else-agents)
in docs/release.md, step by step; [Hotfix releases](../../../docs/release.md#hotfix-releases)
above it says why each step is there. The rules in [AGENTS.md](../../../AGENTS.md) outrank
this skill, and it grants nothing beyond them.

The developer asking for the emergency release is the request a `release:` line needs.
It is not permission to push: pushing the hotfix branch publishes the release to every
user, so show what will ship and push only once the developer agrees. Never push to,
squash or rebase `main` for a hotfix; CI merges it back.
