# Wallpaper choices by desktop Space

**Settings → Displays → a display → Automatic wallpaper selection → Follow desktop
Space** assigns a wallpaper or saved playlist to each desktop on an enabled
independent display. This is experimental: the current renderer is reused and the
chosen content reloads after the desktop changes, so a transition can briefly show
the previous wallpaper. Inactive desktops keep their last captured static poster;
they do not keep another live renderer running.

## Choosing and changing desktops

The rows show desktop numbers in their current order on that display and mark the
current desktop. Choices are keyed by the Space UUID, not its displayed number:
reordering a desktop keeps its choice. Create, remove and arrange desktops in
Mission Control; the app only reads the topology and does not switch or rearrange
Spaces. **Refresh Spaces** re-reads that information.

Each row can choose a playable installed wallpaper or saved playlist. An empty
choice leaves the current wallpaper/playlist as it is. Entering a configured
desktop applies its choice once, when playback can run. While paused, locked or
covered, a change waits; only the latest desktop choice runs after playback resumes.
A wallpaper target stops that display's playlist; a playlist target starts a fresh
copy of the saved plan. Playlist progress is not saved separately for each Space.

A manual selection overrides the current visit. Leaving for another regular
desktop, even one with no mapping, and returning creates a new visit and reapplies
the configured choice. Returning from a fullscreen app to the same desktop keeps
the visit and manual override. Visit identity persists across relaunch; restarting
on the same desktop does not unexpectedly undo a manual choice. Switching desktops
while the app is closed is recognized on its next launch.

Fullscreen app Spaces are excluded from the selectable desktop list and do not
trigger a content change. Missing, malformed or ambiguous topology leaves automatic
selection waiting, with the mode unavailable in Settings. Explicit manual wallpaper
commands remain usable. A disappeared desktop's mapping stays visible as an
unavailable choice and can be forgotten; no mapping is reassigned by ordinal number.

## Focus, mirroring and native lock-screen ownership

Focus wallpaper/playlist choices keep their existing priority. Leaving Focus uses
the rule for the currently visible desktop; if that desktop's identity is unknown,
restoration waits rather than choosing an old Space's wallpaper. Manual selections
during Focus retain the existing [Focus restoration rules](automation.md#focus-selection-and-restoration).

Mirrored or disabled displays do not accept Space choices. Displays with a shared
system Space group can still choose different wallpapers, because mappings remain
per display. Ordinary per-display [saved layouts](display-layouts.md), copy, swap
and manual Apply override the current visit in the same way as any manual choice.

Animated lock-screen wallpaper owns the system Desktop provider across Spaces and
currently conflicts with this mode. Settings refuses to enable it while a connected
independent display uses Space mode, and refuses to enter Space mode while that
provider is requested or still owned. If restored preferences contain both,
Space selection waits until the conflict is resolved. Screen-saver-only mode can
continue using the currently applied per-display content.

## Poster ownership and late frames

`WallpaperSpaceMonitor` reads the optional private `CGSCopyManagedDisplaySpaces` entry
point and decodes `Display Identifier`, `Spaces` and `Current Space`. The data shape is
private and not guaranteed on every macOS version, so the symbol and decoding are optional;
no Accessibility permission, synthetic gesture, Space mutation, plist patch or Dock restart
is used.

Poster requests carry a context containing the current visit, assignment and content
revision. Scene, Web and native-video producers return the context of the original
request, and the coordinator rejects mismatched contexts on receipt and again after
asynchronous encoding. Changing out of Space mode also rejects late Space-scoped frames, and
scene readback contexts travel alongside the existing request sequence so retries cannot
attribute old pixels to a newer visit.

`DesktopWallpaperLedger` restricts writes to the matching native Space. A scope with no
current target holds writes; the public NSWorkspace fallback has no Space identity and
cannot receive a scoped poster. Inactive posters and their original wallpaper journal remain
referenced across renderer replacement gaps. Ejecting the current wallpaper restores that
desktop while preserving other desktops' posters, and normal stop/quit restoration still
restores all original selections using the existing journal and external-change checks. The
rest of the poster service (how it resolves originals, confirms writes and restores at quit)
is in [desktop picture](desktop-picture.md).

## Storage and verification

Mappings live in the existing `WallpaperMachine.automaticWallpapers` records, under `spaces`;
records without it decode to an empty map. Local backups include the mappings. UUIDs on
another Mac or after system recreation may not match; those choices remain unavailable until
explicitly reassigned. `WallpaperMachine.spaceVisits` is local runtime state, excluded from
backups and cleared with handled events and Focus recovery on successful restore; failed
restore journals put that local state back.

Space topology, shared/independent display groups, reordered UUIDs, fullscreen Spaces,
malformed topology, persistent visits and notification teardown are covered by
`WallpaperSpaceMonitorTests`; manual overrides, unmapped visits, rapid queued switches, paused
catch-up and Focus exit while topology is unavailable by `WallpaperAutomationSchedulerTests`;
old-schema decoding and mapping restore by the store and backup tests; scoped writes,
public-fallback exclusion, late frames and encodes, mode changes, replacement gaps,
current-only ejection and all-Space restoration by `DesktopWallpaperTests`; and the panel's
choices by UUID, reordering, unavailable mappings, forgetting and validation by
`PanelAutomationActionsTests`, with focus after Forget in `DisplaysSettingsModelTests`.

These checks do not establish actual Mission Control animations, OS notification timing,
visible layout, VoiceOver or installed-app behavior. A separate explicitly authorized desktop
run is still needed for those claims.
