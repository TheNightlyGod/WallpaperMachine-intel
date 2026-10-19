# Wallpaper properties

What the inspector offers for one installed wallpaper beyond applying it: the live
preview window, the authored properties with their presets, image placement, the
compatibility check and the black-bar check. Selecting and applying a wallpaper, and the inspector's overall
layout, are in [control panel](control-panel.md#selection-versus-apply).

## Live preview

An installed scene, video or Web wallpaper has **Preview wallpaper** in its
details. It opens one ordinary, resizable **Wallpaper Preview** window; choosing
another preview replaces that window's content. A preview never applies to a
display, changes the panel's selection, consumes a playback-history entry or saves
options. It reads the current property draft, including text still being edited,
and the target display's scaling options when it opens, and then follows the
draft ([the preview follows your edits](#the-preview-follows-your-edits));
**Reload preview** reads everything again.

The wallpaper is shown on a stage with the proportions of the target display, so a
portrait, ultrawide or 4:3 display previews with the layout and crop it will get
instead of a 16:9 frame. The stage is the largest box of that shape inside the
black area above the controls; a window dragged to another shape keeps the
proportions and shows bars. A scene's drawable and a page's `innerWidth` and
`innerHeight` are the stage's, so a scene's crop and a page's layout follow the
display's proportions. A new window opens at a size that fits the stage on the main screen's
visible area (at most 1000 points wide and never narrower than the control row
needs, with a portrait stage getting bars beside it); a window that is already open
keeps its size when another preview replaces its content, and only the stage
changes. A display that is not attached, or whose shape cannot be read, previews at
16:9. Shapes are limited to between 1:4 and 4:1. The stage reproduces the
display's proportions, not its resolution: a page sees the stage's size in points.

The window has its own **Play/Pause**, sound toggle and reload control, and every
new preview, including reload, starts muted. Scene and video rendering is capped
at 30 FPS or the effective lower limit when its inputs are read. Web pages receive
that FPS through the standard wallpaper host protocol, and below 60 the host holds
the page's `requestAnimationFrame` callbacks to it
([frame-rate limit](web-wallpapers.md#frame-rate-limit)); timers, video and CSS
animation are not limited. Hiding, covering or minimizing
the window, locking the session or sleeping the displays suspends it, and resuming
visibility preserves an explicit user pause. Closing the window cancels pending
preparation, removes file watchers and releases its renderer or WebKit page. A
superseded load cannot replace the newer preview. Load failures stay in the window
with their reason and a reload action; first-frame or page readiness has a
30-second budget while visible.

Scene and video previews use a private Compatibility renderer attached to the
window, independently of the desktop's renderer preference, and scene hover,
buttons and dragging are scoped to that view. Web previews reuse the wallpaper
host protocol in a separate, nonpersistent website data store and support ordinary
in-window interaction; preview storage is discarded on close and is not the
desktop page's localStorage or signed-in session. File and directory properties
use the existing managed asset authorization and staging path
([user files](user-files.md)). Audio response and
system media information are unavailable in preview and the window says so;
page-initiated capture, dialogs, new windows and file pickers are declined; a Web
preview is refused if WebKit cannot establish whole-page mute; scene previews need
the shared scene resources, just as desktop scenes do. Per-wallpaper energy
ratings exclude the interval while a preview is open.

`WallpaperPreviewSession` owns the loading and playback lifecycle,
`WallpaperPreviewLoader` validates the installed paths, manifest and inputs, and
`WallpaperPreviewWindowController` exists only for an explicit preview action. The
bridge's read-only `wallpaper_preview` export keeps Web property scalar types and
never reconciles the desktop.

### The preview follows your edits

While the window is open, an edit to the wallpaper's properties shows in it without
reloading: a slider, a colour, a switch, a choice, **Restore default**, **Restore
all defaults**, **Revert** and a preset all change the draft, and the draft is what
the preview shows. Text goes live when it is committed (Return, or leaving the field),
not for each keystroke; text typed but not yet committed when the preview opened is
in it, and the first edit afterwards shows the committed text instead. The preview
window never touches a display, the saved options or the other previews; the desktop
follows the same edits only when [the Settings switch](#showing-edits-on-the-desktop)
is on.

The preview waits until the edits pause for 150 ms and then reads the draft once, so
a drag, a burst of edits and a preset each cost one update, and an edit that arrives
while one is being read queues one more. Nothing is read or sent while the window is
hidden, covered, minimized or the screen is locked: the draft is read once when the
window shows again, and the same holds for an edit made while the preview is still
loading, which is shown once the first frame has drawn. A paused preview takes the
change too, so it resumes current. A failure to show an update is logged (once per
distinct problem) and the preview keeps playing what it has; the next edit tries again.

A slider or a colour is also followed while it is being dragged, not only when it is
let go. The panel sends the value under the thumb (`previewProperty`, through
`DragStepPump`) at most every 100 ms and one at a time, as a Position slider does, and the window reads the draft with
that value on top (the `pending` list of the bridge's `wallpaper_preview`) as soon as it
has taken the step before, without the 150 ms wait an edit gets, which a drag would
never get to the end of. A step is not an edit: nothing becomes **Modified**, dirty or
saved, and letting go of the control makes the edit that keeps the value. A step that
fails is ignored, and a key press or a VoiceOver adjustment, which changes the value at
once, shows no step before it is saved. The colour well opens the system colour panel,
whose dragging the inspector cannot see: each colour it reports is a step, its first one
waiting a turn, and the colour is saved once it has stayed the same for 350 ms or the
panel closes. How smoothly the desktop follows is checked on a desktop
([manual smoke](../testing/manual-smoke.md)).

A scene takes the whole property state through the renderer's
[live property edits](scene-rendering.md#live-property-edits), a Web page through
`applyUserProperties`, which hands the page only the properties whose value changed.
A video has no properties to follow. `PropertyPreviewScheduler` is the wait and
`LivePropertyPayload` decides what is sent; `BridgeStore.onPropertyDraftChanged` is
what tells the session that a wallpaper's draft changed (after an edit, a chosen file,
a restore, a revert or an apply) and `BridgeStore.onPropertyDragged` what tells it of
each step of a drag.

What a preview reads only while it loads does not follow. A picture or file a
property picks (a texture, a file, a folder) keeps the value the preview started with,
and while the draft picks another the window's status line says **Reload preview to
show the picture or files you chose.**; picking the original again clears it.
**Reload preview** starts over from the draft, which is also how the scale factor,
which the preview reads once, is shown. Two scene readers decide while the scene
loads as well, an effect that a switch or choice builds or leaves out and a texture
a property picks for a material: they stay as the scene loaded them and the window
gives no note for them (the renderer logs the held names once), so **Reload preview**
shows those. Apply changes is unchanged: it reloads the wallpaper from the saved options.

## Properties

The inspector's compact **General configuration** section holds mute, volume,
[Audio response](audio-response.md), and media integration. **Audio and media
status** expands to show their explanations and delivery status. **Displays**
follows with per-display playback configuration, open when the wallpaper is on a
display and collapsed otherwise, then **Collections**.
**Wallpaper properties** comes last, with the wallpaper's authored controls in their
original order, so a long property list never pushes the shorter sections out of
reach. General, display and property disclosures keep their state while the same
wallpaper stays selected; another wallpaper starts at the top with its sections at their
defaults.

Property rows place the label on the left and the checkbox, slider/value, combo
menu or color swatch on the right; text and file editors use the full width below
the label. A reset icon appears on hover, keyboard focus, or a modified row and
restores that property's default. Checkboxes use the author's name directly.
Recognized Wallpaper Engine label tokens (brightness, position, default, and
similar built-in vocabulary) are localized rather than displayed as `ui_editor_…`
identifiers. A built-in token without such a phrase is shown as sentence-cased
English words, never as the identifier: the `ui_` prefix, the editor-area words
that begin it (`editor`, `properties`, `effect`, `context`, `menu` and similar) and
a trailing `title`, `label` or `text` are dropped, so `ui_editor_effect_opacity_title`
reads **Opacity**. The same applies to a combo choice. Only a label or choice that
is exactly such a token (surrounding space ignored, at most 96 characters) is
rewritten; author prose that merely mentions one is left alone, and the stored
label and the choice's value are unchanged. The words are English, and the panel
translates them whenever the same phrase is already a catalog entry.

A wallpaper may carry its own translations in `general.localization`: a table per
Wallpaper Engine language code (`en-us`, `zh-chs`, `zh-cht`, `ja-jp`, `ko-kr`) that maps
the `ui_…` tokens its labels and combo options use to text. A label or combo
option that is exactly one of those tokens (surrounding spaces ignored) shows the
text from the app's language, then from `en-us`, and otherwise stays as the author
wrote it, so a token missing from every table is left to the built-in vocabulary
above. Text that only mentions a token is never rewritten, and a translated value
passes through the same label sanitiser as any other label. Titles and
descriptions are not translated. The tables come from downloaded projects and are
bounded (64 languages, 4,096 tokens each, 2 KiB per text, 1 MiB overall); anything
beyond the bounds or not text is ignored without failing the wallpaper. The app
sends its language to the bridge at launch and whenever the language changes, and
the open inspector relabels at once without reloading the wallpaper or touching
pending edits.

Authors use HTML labels as a layout surface. `PropertyLabelDocument`
(`App/Views/ControlPanel/Inspector/`) parses them as data, the way a browser would
repair broken markup, and keeps a small presentation allowlist: headings, paragraphs,
line breaks, lists, emphasis, sizes, font colors (hex values and common names),
centered content, dividers, links and images; `PropertyLabelView` draws the result as
attributed text, rules and registered images. Author scripts, styles, embedded
documents and form controls are dropped with their contents, other unknown elements
keep only their text, and the source, the number of nodes and the depth are bounded.
Plain labels remain available for accessibility and native file pickers. An empty text property is omitted; a control without a
readable name uses **Unnamed option**, never the editor's markup-derived id.

A `group` record is a section heading for the controls after it, so it is shown
as a bold heading with a rule above it (marked as a heading for VoiceOver) rather
than as muted description text. It takes the same sanitised label as any
other, is omitted when it has no words, and is not collapsible: Wallpaper Engine
groups only label what follows and own no rows of their own.

Author artwork is loaded only for the image addresses the label registered, as a
`PanelImageSource.propertyImage` the panel's image pipeline checks again before it
reads anything. `PropertyImageCache` fetches HTTPS raster images natively from the
allowlisted image CDNs (`i.ibb.co`, `i.imgur.com`, the supported Steam image hosts
and QQ's photo-store hosts), rechecks redirects, and rejects credentials, custom
ports, unregistered addresses, oversized images and non-raster content. PNG
transparency and GIF animation are preserved, and repeated dividers share a
bounded in-memory cache. At most four author-image transfers run across all hosts;
a URL's load is shared by its consumers and cancelled when the last one goes away.
Other image hosts are omitted (alt text is retained). Images remain author-hosted,
need network access on a cache miss and are not copied into the app bundle.
Supported author links use the panel's external-link allowlist (`ExternalLink`),
including Bilibili profile/article pages, and open only when clicked; unsupported
links keep their text without a clickable action. A link is part of the label's text
(VoiceOver's rotor reaches it), not a separate keyboard stop.

An authored visibility rule decides whether a property is listed, and the
bridge re-evaluates it after every draft edit. A rule may combine property
checks (`a.value`, `a.value == 3`, with `==`, `===`, `!=`, `!==`, `>`, `>=`, `<`
and `<=`) with `&&`, `||`, `!` and parentheses; use the constants `true` and
`false`; compare against numbers, booleans or text in either kind of quotes; and
test a list such as `[3, 4, 5].includes(a.value)`. A rule using anything else, or
longer, more deeply nested or more heavily listed than the parser's fixed bounds,
is unreadable and leaves its property visible rather than hiding a control the
author may have meant to show. Each library refresh writes one app-log line per
wallpaper naming how many of its rules could not be read. A property hidden by a
rule is only left out of the panel's list. The bridge still reports it, not
enabled and with its current value, so the value (or its authored default) still
feeds other rules and the renderer and a preset can still name it. These rules
only choose which rows the panel lists: a scene layer or effect whose visibility is
bound to a property follows its value whether or not a rule hides the row, and the
scene file alone says what a value switches on or off ([scene
rendering](scene-rendering.md)). The rules are evaluated when the panel's property
list is built, never per frame, and the scene resolves its bindings when it loads
and on a property change. A rule that is always false, such as a bare `false`,
hides its property for good, as Wallpaper Engine does.

Audio, scaling mode, position and frame rate take effect immediately. Everything
else is pending until committed:

- **Apply changes** saves pending properties and scaling factors.
- **Revert** discards pending changes.

Unsubmitted text stays with its wallpaper when navigating between pages. A dirty
or unsubmitted control shows a localized **Modified** flag outside its
author-provided label; Reset clears the flag once the property is clean.

**Restore all defaults**, a link at the top of the **Wallpaper properties** card, under
the presets, stages
the authored default of every property at once instead of one reset icon at a
time. It is pending like any other edit: **Apply changes** keeps it and **Revert**
brings back every value and **Modified** flag. It also drops text not yet sent and
values behind a rule that currently hides their property, but not display
settings, audio or presets. A chosen file or folder is left alone, because it is
saved the moment it is picked; each keeps its own **Clear**. The link is disabled
while nothing but such files and folders differs from the defaults and no text is
waiting, and while the wallpaper cannot be rendered. A modified value behind a
rule that currently hides its property counts as a difference, since it still
reaches the wallpaper, so the link is enabled for it even though no row shows it.

A `scenetexture` property's image picker fills the material slot that names it, so
a wallpaper built around "choose your own picture" shows the picture. The choice
takes effect on **Apply changes**, which reloads the scene; the picker stores the
path, not a copy, so moving or deleting the file leaves that slot on the artwork
the author shipped. A picture outside the app's own storage is not readable from
the sandboxed lock-screen extension, which keeps the authored texture there. A
picture chosen for a solid placeholder layer, the user's own or one a preset ships,
is shown as it is: the layer's colour, often the scheme colour, only paints the
placeholder while no picture fills it.

### Showing edits on the desktop

**Settings → Desktop & Lock Screen → Desktop → Show property edits on the desktop as I
make them** lets the displays that draw a scene wallpaper follow its pending
properties before **Apply changes**. It is off until the user turns it on, a choice
kept on this Mac only (`WallpaperMachine.livePropertyEdits`, `LivePropertyEditing`)
and left out of backups: the update runs inside the scene that is already playing
instead of loading it again ([live property
edits](scene-rendering.md#live-property-edits)), and the few things a scene reads
only while it loads can differ from a fresh load. The default is
`LivePropertyEditing.buildDefault`.

With the switch on, a slider, a colour, a switch, a choice, **Restore default**,
**Restore all defaults**, a preset's edits, text (on Return or leaving the field) and
a chosen file are each followed by one update once the edits pause for 150 ms
(`PropertyPreviewScheduler`), so a drag or a preset costs a display one update, and an
edit that arrives while one is under way queues one more. The update is the
bridge's `preview_wallpaper_properties(wallpaper_id, show, pending)`: it shows the whole
pending state on every scene that draws the wallpaper, mirrors included, so a restored
default is back at the authored value. Turning the switch on shows nothing by itself; the
next edit does.

A dragged slider or colour is followed as it goes, with no wait: each step the panel
sends (at most every 100 ms, one at a time, as above) is handed to the bridge in the same
call's `pending` list, which puts it on top of the draft for that call alone. The bridge
checks it like an edit's value (the same kind, range and options, the same refusal) and
keeps it nowhere, so the draft, the dirty state and the saved options never see it.
`BridgeStore` keeps the newest step of each property in `WallpaperEditorState`
(`propertyPreviewValues`, which is not a draft and never counts as a pending edit) so
that every update of the displays and of the preview window in the meantime carries it,
and the update an earlier edit started does not take the drag back a step. It lasts until
the edit that ends the drag (taken or refused), a restore of that property or of every
default, **Revert**, **Apply** or the inspector showing another wallpaper. A step that
arrives while the wallpaper is being applied or reverted is dropped. Releasing the control
saves the value as it always did; when it is the value of the last step, the one update that
follows finds the scenes already showing it and sends them nothing, and otherwise it shows
the saved value.

- A picture (a texture property), a file or a folder, and what a scene reads only
  while it loads (an effect that a switch or choice builds or leaves out, the
  material slot a picture picks) wait for **Apply changes**; the Settings note says
  so. An edit that reveals a layer the scene left out of its render graph makes the
  scene build the graph again once, as a script revealing the layer does, so that edit
  can hitch briefly.
- Nothing is saved. The edit stays pending and **Modified**, and the lock screen and the
  screen saver keep the saved look ([lock screen](lock-screen.md#use-wallpaper-as-screen-saver)).
  So does the Mission Control picture: it is not taken from a display while it shows an
  edit, whatever asks for it, and it is taken again when Revert, turning the switch off or
  **Apply changes** ends the edit ([when a poster is taken](desktop-picture.md#when-a-poster-is-taken)).
- **Revert** puts the saved look back on the displays and then discards the edit; a
  display that refuses leaves the edit, and Revert can be pressed again. **Apply
  changes** is unchanged: it loads the wallpaper from the saved options, so the scene
  still reloads once.
- Anything else that loads the scene again (a display change, waking, Reapply,
  switching the wallpaper, clearing the shader cache, the repair of a display that
  stopped drawing) shows the saved look. The edit stays pending, and the next edit shows
  it again, even one that leaves the shown document as it was, such as picking a picture.
- Turning the switch off puts the saved look back on every wallpaper whose displays
  were shown an edit; the edits stay pending in the inspector. A refusal is retried the
  next time the switch is turned off.
- Only scene wallpapers are shown. A video has no properties, and a Web wallpaper
  receives its changed properties after **Apply changes**.
- A refused update is logged (`properties: …`) and never shown as an alert, so an edit in
  progress is not interrupted; the next edit tries again. Apply and Revert drop the
  update that is waiting, and the edits Apply itself sends for text it was holding start
  none.

`BridgeStore.showsPropertyEditsOnDesktop` reads the choice for every edit, and
`BridgeStore.stopShowingPropertyEditsOnDesktopAsync` is what turning it off runs.

### Property presets

**Wallpaper properties → Save current…** stores a named preset of the currently
applied authored properties; pending edits must first be applied or reverted.
Choose a preset and **Apply**, rename or delete it, or export/import its versioned
JSON document. Import saves a new preset and never applies it automatically. These
are wallpaper-specific property presets, not the Performance quality tiers.

Application validates every saved property against current types, limits and
choices before staging edits. Default markers follow the author's current default.
File and directory edits join the same draft transaction, and a failed application
restores draft and selection-permission state. Managed attachments are retained
independently of the current property under `UserAssets/PresetAssets`; deleting a
saved preset does not delete a directory still used by an applied wallpaper, and
ordinary cache cleaning leaves these retained originals alone.

Presets can switch a mode and set fields that mode enables. All values and
resources are validated first; enabled mode controls are edited before dependent
fields, and the bridge reevaluates authored conditions after each draft edit. If a
target field remains disabled, the draft is reverted without applying it.

A preset holds the properties the panel listed when it was saved; one a rule hid
then is left out, and applying the preset leaves it as it is. A preset may still
name a property that a rule hides when it is applied, because the wallpaper's
settings changed since or the preset came from an import: the property is set once
the preset's own edits to the properties that control it show it. A property the
wallpaper no longer defines, or whose type changed, is reported as unknown and
nothing is applied.

Portable documents embed up to 32 MB of managed attachments, within a 48 MB
document limit. Hidden files in retained directories (such as Finder metadata) are
excluded from portable exports. Preset names accept 1–120 characters. Arbitrary
external paths do not grant access on import: select external originals through
the property editor. Missing resources, incompatible author changes, malformed
documents and filesystem-aliasing filenames are errors, not partially applied
presets.

### Image placement

App-generated imported pictures and saved pixiv pages show **Position on screen**.
Drag the preview or use its keyboard/position controls and 100–300% zoom; each
target display keeps its own placement. **Reset to Image fit** restores the
Fit/Fill/top-aligned behavior. Original image bytes are unchanged, and changes
reach the running page through properties without resetting its document. An
app-generated page from an earlier template is upgraded once, and only if its
provenance, resources and exact unmodified template match; authored or modified
HTML is never rewritten.

### Display position

A scene or video wallpaper's card for each display, in the inspector's **Displays**
section, has **Horizontal position** and **Vertical position** sliders (0 to 100%, 50% is
the middle) and a **Center** link, below the frame rate. They decide where the wallpaper
sits when the display leaves room around it (Fit, Original size, or a Scale factor
below 1) and which part stays in view when it is larger than the display (Fill, or a
factor above 1). Nothing moves when it already fits the display exactly, and an axis
with no room to spare does not move; the note under the sliders says so. The block is
not offered for a web wallpaper (an image page keeps **Position on screen**, above),
and a mirror display has no card, because it is always centred.

Like the scaling mode, and unlike the Scale factor beside it, a position is not a
draft. A slider sends its value when it is released, or at each keyboard step, and
only the axis that moved, so a horizontal drag never disturbs the vertical position.
The running wallpaper follows without restarting, and the position is saved at once
for that wallpaper on that display. **Apply changes** does not wait for it and
**Revert** does not undo it.

While a slider is being dragged with the pointer the wallpaper also follows the thumb,
showing the newest value about every 100 ms and one step at a time. Those steps are
only shown: nothing is saved, the lock screen, the screen saver and the Mission Control
picture hear nothing, the panel does not redraw, and the saved position is what the
display's options keep reporting. The release is the ordinary move above and is sent
after the step still on its way has been answered, so the last step cannot land after
it. A drag that ends where it began still puts the wallpaper back at the saved
position, and so does a cancelled pointer or a window that loses focus mid-drag. A
refused step is ignored and the release reports its own error. If the panel closes
mid-drag the wallpaper may stay at the last step shown until the next move or until
the scene is rebuilt, which returns it to the saved position; nothing was saved. Key
presses and VoiceOver adjustments have no drag to follow and are saved at once. **Center** puts both axes at 50% and is disabled while
they already are. A request outside 0 to 100% or not a number is refused instead of
being moved to the nearest edge. The command waits its turn behind the user's other
commands, such as a wallpaper switch still running. After a move the Mission Control
picture is taken again ([desktop picture](desktop-picture.md#when-a-poster-is-taken)),
and the lock screen and screen saver draw the wallpaper at the same position
([lock screen](lock-screen.md#where-the-picture-sits)).

Both scene renderers honour the position, and so does Compatibility video playback,
which draws a video as a one-texture scene. The native video player draws a video
centred whatever the position says. A video it draws shows a note saying so, with a
link to Performance settings, where choosing Compatibility for **Video playback** lets
the position apply; the sliders stay available, and the saved position still reaches
the lock screen. The panel learns which displays the native player draws from the
running backend reports, so a wallpaper with no report yet shows the plain note.

### Compatibility check

An installed wallpaper's **Compatibility check** reads entry/shared resources and,
for video, asynchronously checks native admission for the selected display and
frame-rate constraints. Checks are explicit and version/configuration-bound.
Unknown scene shader/graph or Web runtime behavior remains **unknown**; readable
files and video metadata are not proof of a displayed frame. The same card shows
the actual running backend and fallback reason when the runtime reports them.
When the installed project or its entry file is unavailable and the wallpaper is
a Workshop item, the card also offers [Reinstall from Workshop…](workshop-downloads.md#reinstall-from-workshop).

### Black bars

An installed video's **Black bars** card looks for bars baked into the picture
itself, such as a 2.39:1 film inside a 16:9 file or a 4:3 clip inside 16:9.
**Look for black bars** is an explicit click: it decodes five frames at 10, 30, 50,
70 and 90% of the clip (frames that land on the same moment count once), measures
the bars in each and reports what most of them agree on. The check is read-only:
nothing is applied, rewritten or saved. Results are held in memory for the last
16 wallpapers checked and read as not checked again after a library refresh or a
restart; selecting another wallpaper cancels a check that is still running.
Acting on a result is a separate click, described under
[Set scale factor](#set-scale-factor).

- **No black bars found**, or **Black bars found** with their size as a share of the
  picture on each side. Bars on both ends of one axis, or all four sides, are
  reported only when they are about the same size.
- With the target display in **Fill**, the card names the scale factor that crops
  the bars off that display. The factor depends on the display's proportions under
  the engine's Fill layout (a 21:9 display already crops the top and bottom of a
  16:9 video, so the card may say Fill already does it), is rounded up to two
  decimals and carries half a percent of overscan. In any other scaling mode the
  bars are reported and no factor is named.
- **Uneven** bars (one side only, or lopsided) get no factor, because a centred
  zoom would also cut picture. Bars that add up to more than 45% of an axis are
  treated as unreliable and nothing is suggested.
- The card says it cannot tell when the sampled frames are too dark, disagree about
  where the bars are, or are too few after repeats are dropped. It says it cannot
  check when AVFoundation cannot read the file (WebM, Matroska and AVI are not
  readable there), the file has no video track, reading takes longer than 20
  seconds, or the file changed while it was being read.

#### Set scale factor

When a factor is named, **Set scale factor to ×N** fills in the target display's
**Scale factor** with it. The click goes through the same bridge call as the
Displays section's field, so it joins the pending changes: **Apply changes** saves
it and **Revert** restores the saved factor, and like typing in that field it is
previewed on the display while the wallpaper is playing there. The button names only
the wallpaper and display; the factor is recomputed from the stored bars, the clip's
proportions and the display's size at the moment of the click, so nothing the view
holds can change it.

The click is refused, and changes nothing, when the card no longer matches what is
selected and configured: another wallpaper or display, a mirror or disabled
display, a mode other than Fill, a result from before a library refresh, or a
display that already has the factor or a larger one (the user's own larger factor
is never lowered). Before it acts, the app re-reads the video file's size, date
and identity; if the file was replaced since the check, the result is dropped, the
click reports that the video changed, and the card goes back to offering a new
look.

Both video backends apply the scale factor with the same Fill layout ([Video
backend](performance.md#video-backend)), so the button does not depend on which one
plays the clip. Once the display holds the factor the card drops the button. It adds
the line about Apply changes and Revert only for the factor this card set, and only
while that factor is still waiting in the unsaved draft: the app remembers what it
set, and forgets it when the draft is applied or reverted, the factor is edited, or
another wallpaper or display is shown. A factor that was already saved never gets the
line, however many other edits the wallpaper has pending. The numbers on the card come
from the stores, not from what the view did last. The lock-screen configuration
carries the display's scale factor as well; no routine test exercises that path.

Sampled evidence is not proof: a scene that keeps a black border through all five
samples looks like bars, burnt-in subtitles shorten a bar in the frames that carry
them, and the thresholds are this app's own, exercised on generated H.264 clips
and not on a corpus of real wallpapers. Anamorphic (non-square pixel) clips can be
a percent or two off, which the overscan covers. Mirror displays hold their own
scale factor and are not covered.
