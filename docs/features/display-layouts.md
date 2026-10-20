# Multi-display wallpaper layouts

**Settings → Displays → Display layouts** saves the wallpaper choices on enabled,
independent displays under a name. **Apply** restores the whole arrangement;
**Rename…** and **Delete…** manage the saved records. Deleting a layout leaves
current wallpapers alone. Empty and mirrored displays are excluded when saving.
Up to 64 layouts with 64 display assignments each are supported.

Layouts save wallpaper IDs and existing display selectors, plus display titles
for explanation. They do not save wallpaper properties, scaling, playlists,
automatic-selection rules, display enablement or mirror topology. Applying uses
each wallpaper's existing options for its destination. The user's Play/Pause stays
unchanged. Playlists and automatic rules keep running, just as after a manual Apply;
a later scheduled event can change the restored wallpaper.

## Copy and swap

Each enabled independent display that has a wallpaper offers **Copy or swap
wallpapers** when another eligible display exists. Choose the other display, then:

- **Copy wallpaper** applies the source wallpaper to the destination, leaving the
  source assignment unchanged. An empty destination is allowed.
- **Swap wallpapers** exchanges the two current assignments. Both displays must
  already have a wallpaper; no content or settings files are moved or copied.

The destination picker excludes the source, disabled and mirrored displays. Native
validation repeats these checks when the queued operation begins, so a stale panel
cannot redirect a request to another display. Empty destination choices disable
both actions. The buttons retain contextual accessible names and return focus to
the initiating control; failures focus their complete error in Display layouts.

## Apply to every display

**Apply to all displays** in an installed wallpaper's inspector, `display=all` in an
apply link and **On all displays** in the Apply Wallpaper shortcut put one
wallpaper on every enabled independent display in a single step. There is no
persistent "all displays" mode: it is a one-time assignment like a layout, and a
display connected afterwards starts as any new display does. Mirrors are left out
because they follow their source; for the same reason the button appears only when
two or more eligible displays exist, and is unavailable when they all already show
the wallpaper.

The displays are read when the command takes its turn, the main display first and
the others in the order Settings lists them, and are read again after the
wallpaper's options are checked. If a display was connected, disabled or switched to
mirroring in between, nothing changes and the result asks you to review the
displays. With no eligible display it refuses with a message to enable one. A
display that already shows the wallpaper is skipped without reloading it, and it
still counts as your choice there. The command is also your choice of the wallpaper as
far as a [crash hold](crash-recovery.md#what-the-user-sees) goes: when the load journal
is holding the wallpaper back, a display that reads as showing it is applied again, and
the first apply that succeeds lifts the hold for every display.

The wallpaper must have no unapplied edits, because one apply for every display
cannot decide which display an edit was for. The single-display Apply commits the
wallpaper's own edits first; here, choose the inspector's **Apply changes** or
**Revert** and then **Apply to all displays**. The refusal reuses the layout message,
"Apply or revert wallpaper edits before changing a display layout."

It shares copy and swap's recovery guarantees (below): one queue turn, a failure
or cancellation restores every display it changed, and the result says which
displays could not be restored. When the shortcut is given both a **Display** and
**On all displays**, **On all displays** wins.

## Missing resources and failure recovery

Every saved display and wallpaper must be available before any assignment changes.
A saved layout with a missing wallpaper, disabled/mirrored screen or disconnected
display remains visible with the reason and a disabled Apply button. Reconnecting
the display or reinstalling the wallpaper makes the same record usable again.
No screen is substituted by position or by matching its friendly title. The
`primary` selector keeps its existing app meaning; other selectors retain the
renderer identity used throughout display settings.

Copy, swap, applying to every display and layout application each hold one
user-command queue turn. The operation validates all targets and rejects pending
edits on involved wallpapers, then checks the assignments again after preparation
and between changes. A later manual wallpaper command waits for this operation,
including any recovery, and then wins on its own display. The operation has no
display slot of its own, so it counts as your choice for every display it gives a
wallpaper to (both for a swap, the destination for a copy, every eligible display
for an apply to all) from the moment it is asked for: a
[Download and apply](workshop-downloads.md#download-and-apply) waiting on one of
them is withdrawn and does not override the result when its download arrives.

If a switch fails or is cancelled midway, recovery restores the affected original
assignments, including an originally empty destination. Recovery does not overwrite
an unexpected third-party assignment or guess from an untrustworthy snapshot.
The result explicitly distinguishes verified restoration from displays that could
not be restored; those need inspection before retrying. There is no promise that
multiple WindowServer surfaces change on the same frame.

Only final, trustworthy assignment changes enter recent/previous history. A fully
rolled-back operation leaves history and manual automatic-selection overrides
untouched. If recovery remains incomplete, the confirmed final changes are recorded.
An explicit successful no-op still counts as a manual choice for automatic rules.

## Shortcuts and backups

**Apply Display Layout** in Shortcuts uses a searchable saved-layout picker. Siri
and Spotlight receive the same action, and a link can use:

```
wallpapermachine://layout?id=LAYOUT_ID
```

There is no `display=` parameter because the layout names all of its displays.
The command validates current display and library availability before applying.

Saved layouts use the allowlisted `WallpaperMachine.displayLayouts` preference.
Local backups include these records. Keep-existing restoration merges by layout
ID and retains local records with the same ID; ordinary display names are labels,
not filesystem paths or authorization to access content. Deleted wallpaper
references remain visible instead of being silently pruned into a partial layout.

## Mirror sets, AirPlay and a closed lid

The renderer reads the active displays from CoreGraphics, while the native video
backend and the web host draw on the screens AppKit lists, matched by display ID. A
hardware mirror set, an AirPlay or Sidecar screen and a built-in display whose lid
is closed are the shapes where the two lists can differ. The app does not reconcile
them, and promises only this:

- A hardware mirror set follows the member macOS reports for it, the set's primary as
  macOS names it. The app does not choose another member or draw on the others.
- A closed lid follows the same rule: the `primary` selector means whichever display
  macOS then reports as the main one, and a wallpaper assigned to the built-in display
  waits there until that display is listed again. The new main display shows its own
  saved wallpaper, or the built-in display's if it was never configured
  ([main display changes](control-panel.md#target-display)).
- A screen AppKit lists without a display number is not drawn on by the Swift hosts,
  because there is no ID to match it to a wallpaper. It is not mistaken for a display
  that left: its coming and going refreshes the displays like any other change.
- When the bridge offers a native video wallpaper for a display that AppKit does not
  list, the wallpaper is not shown there, and the log says so once per wallpaper and
  display (`native video wallpaper … is offered for display …, which this host cannot
  see`). The host adds no retry: the bridge offers the wallpaper again on its next
  snapshot, and a real screen change refreshes the displays, so the display opens as
  soon as the lists agree. A display that is only missing for a moment is logged the
  same way, and that is not a failure. The web host has the same filter and does not
  log it yet.

None of this has been checked against real mirror sets, AirPlay or a closed lid; the
tests prove what the host and the refresh do with the readings they are given. The
[hot-plug and mirroring rows](../testing/manual-smoke.md#hot-plugs-mirroring-and-the-lid)
of the manual smoke checklist are how it gets checked.

## Spaces boundary

These are per-display layouts. [Follow desktop Space](spaces.md) separately keeps
wallpaper/playlist choices by Space UUID and reloads the active display on a desktop
change. Applying a layout is a manual override for the current visit. A layout does
not save that Space map or switch Spaces, and inactive desktops do not retain
separate live renderer instances. Actual OS transitions still need desktop verification.

## Code and verification

| Responsibility | Source |
| --- | --- |
| Records, bounded persistence and backup validation | `App/Services/Library/WallpaperDisplayLayoutStore.swift` |
| Capture, planning, preflight and verified recovery | `App/Services/Desktop/WallpaperDisplayTransfer.swift` |
| Bridge queue, clean-option checks and final history | `App/ViewModels/BridgeStoreDisplayLayouts.swift` |
| Panel actions and state | `saveDisplayLayout`, `renameDisplayLayout`, `deleteDisplayLayout`, `applyDisplayLayout`, `copyWallpaper`, `swapWallpapers` in `App/Views/ControlPanel/Model/PanelController+DisplayLayouts.swift` |
| Settings UI | The Display layouts group in `App/Views/ControlPanel/Settings/Sections/DisplaysGroups.swift`, Copy or swap in `DisplaysSettingsCard.swift`, the page state in `Settings/DisplaysSettingsModel.swift` |
| Apply to all displays | The inspector's **More actions** menu (`Inspector/InspectorHeader.swift`), `activateAll` in `Model/PanelController+Library.swift` |
| Shortcuts and links | `App/Services/Automation/WallpaperConfigurationIntents.swift`, `WallpaperIntents.swift` (Apply Wallpaper's **On all displays**), `AutomationCommand.swift`, `AppDelegate.performAutomation` |

The store, transfer and BridgeStore integration suites (`WallpaperDisplayLayoutStoreTests`,
`WallpaperDisplayTransferTests`, `WallpaperDisplayTransferIntegrationTests`) cover bounded
persistence, capture, copy/swap, stale preparation, validation before writes, failures after
mutation, recovery of empty destinations, external-choice preservation, cancellation, history,
manual-choice callbacks, clean-edit preflight, paused playback, a newer queued manual
action and applying one wallpaper to every display (plan order, displays that already show
it, a display set that changed while preparing, one history entry per display, rollback).
`PanelDisplayLayoutActionsTests` covers the panel's save, rename, apply, delete, copy,
swap, a failed swap putting both displays back, unavailable displays and the limit;
`DisplaysSettingsModelTests` the page's status lines, failed-recovery feedback and focus
return; `SettingsBRenderTests` the page in every shipped language at the smallest window;
`InspectorPolicyTests` and `PanelLibraryActionsTests` Apply to all displays (offered only
with two eligible displays, rollback after a failure); `WallpaperBackupTests`,
`AutomationCommandTests` and `AppAutomationTests` cover backup merging and link validation.
These tests create no desktop wallpaper windows and do not prove real multi-monitor
compositor transitions, visible appearance, VoiceOver, Siri or Shortcuts registration.
