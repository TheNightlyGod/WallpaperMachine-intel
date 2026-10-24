<!-- Thanks for sending a change. CONTRIBUTING.md has the full working agreement. Title the PR as a Conventional Commit subject (`fix(scene): …`): a squash merge uses it as the commit subject, and `feat`, `fix` and `perf` subjects feed the release notes. -->

## What and why

<!-- What changes for someone using or working on the app, and why. Link the issue: Fixes #123. -->

## Verification

<!-- The commands you ran and what they showed; what you checked by hand, and what you did not. -->

- [ ] `python3 scripts/test.py` passes
- [ ] Targeted checks for the area touched (`python3 scripts/check_renderer.py` for renderer or scene work)
- [ ] Visible changes: before and after screenshots below, or "not checked visually"

## Checklist

- [ ] One coherent change, and the PR title is a Conventional Commit subject (`fix(scene): …`, `feat(downloads): …`)
- [ ] No `release:` line in the title or any commit message (it cuts a version when merged)
- [ ] Tests for behavior a plausible bug would break
- [ ] Generated files regenerated, not hand-edited (`project.yml` → Xcode project; bridge bindings through `scripts/build.py`); `ThirdParty/` changes update `ThirdParty/provenance.json`
- [ ] The document that owns the behavior updated
- [ ] No build output, secrets, private wallpapers or personal paths in the diff
- [ ] My commits are signed off (`git commit -s`): I certify the Developer Certificate of Origin and license this change under GPL-3.0-only (CONTRIBUTING.md)
