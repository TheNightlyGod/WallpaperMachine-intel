# Local backup and restore

This page covers the backup package and the restore that follows it. Backup is one
of the Settings → Storage tools; the Settings sections are listed in
[control panel](control-panel.md#pages-and-settings).

**Settings → Storage → Backup** exports a versioned `.wmbackup` directory package
containing renderer/wallpaper settings, allowlisted preferences (collections,
plans, presets, favorites, image placements, display layouts, automatic-selection
rules and sunrise/sunset settings included), and retained
[user-selected files](user-files.md). Handled automatic
events and temporary Focus recovery state remain local and are cleared on
successful restore; rollback restores their original values. **Include the
wallpaper library** also copies installed projects. Login sessions, passwords,
keychain entries, logs, caches and shared scene resources are excluded, and the
local scene-assets selection stays local and may need to be selected again. Time
Machine and other backups of the whole Mac likewise skip the saved Steam sign-in,
partial downloads and caches, but not the library ([Steam
sign-in](workshop-downloads.md#steam-sign-in)). Only
preferences saved in the app’s persistent domain are included; inherited system
languages and registered defaults are excluded, including during conflict checks
and rollback. Export checks the complete manifest size before copying payload
bytes and supports the full 48 MB preset archive limit. Three filter-sidebar
preferences (`workshopFiltersCollapsed`, `installedFiltersCollapsed` and
`pixivFiltersCollapsed`, under the `WallpaperMachine.` prefix) are on the allowlist
although the panel does not read them, so backups made by earlier versions restore.

Choose a backup to preview its contents, conflicts and missing-resource warnings.
**Keep what is on this Mac** preserves conflicting per-display playlists, their
deadlines and automatic-selection configurations as whole records; independent
records can be imported. Sunrise/sunset settings are also kept or replaced as one
record, including when a backup from an older version contains only coordinates.
**Replace with the backup** replaces conflicts. Confirmed
restoration is staged for the next launch, before stores or the renderer read
settings; nothing changes in the running session, and the app does not quit or
restart automatically.

Packages reject traversal, links, special files, ambiguous filenames, changed
bytes and unsupported configuration schemas. Publication is journaled and rolls
back on failure. A failed pending restore is shown in Storage and is not retried
every launch without explicit reconfirmation; **Cancel restore** removes staging.
Managed resource paths relocate, while ordinary property text stays unchanged.
Backed-up copies are portable; original external files are read or watched only
after a matching local authorization or an explicit reselection, so restoring
metadata alone cannot authorize a wallpaper to read another folder on this Mac.
Scene texture overrides and authored defaults that had only retained copies are
rewritten to the exact validated retained file, because the scene renderer opens
paths directly rather than going through the Web asset host; original paths stay as
provenance only. A retained directory without a directly usable scene resource, or
a keep-existing asset tree missing the matching bytes, cannot authorize a scene
reference and is rejected before publication.
