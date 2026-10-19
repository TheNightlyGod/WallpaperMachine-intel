# Music information in wallpapers

**Media integration** is on by default for scene and web wallpapers, sharing
the system's current song title, artist, album, artwork and available timeline.
Turn it off in a wallpaper's inspector to stop sharing; saved on/off choices are
preserved. Configurations without a saved choice use the enabled default.
The wallpaper must contain its own music display; this setting does not add an
overlay to arbitrary wallpapers.

The source is macOS Now Playing. Spotify, Apple Music, browsers and local media
players can supply data through it. An MP3 is supported through the application
playing it, provided that application publishes Now Playing information. Only
the current system player is reported, not every audible tab or application.
Missing metadata or artwork is not invented. Changing to a track without a
cover, stopping playback, or disabling integration clears the previous data.
This feature does not capture audio and does not control playback; audio
reactivity is a separate setting, see [Audio response](audio-response.md).

## Sources and lifetime

`DesktopMediaSession` owns one `SystemMediaProvider` and fans events out to
every desktop consumer that has the setting on. Web wallpapers attach through
`WebWallpaperHost`; scene wallpapers attach through `SceneMediaSink`. Neither
constructs a second player subscription. A listener with nothing to feed drops
events: `SceneMediaSink` copies no cover, encodes no JSON and makes no bridge
call for scenes that are paused or suspended, and its deliveries are chained so a
slow cover is never overtaken by the one that replaced it.

**Providers.** The primary provider is `AdapterSystemMediaProvider`. It runs the
pinned BSD-3-Clause `upstream/mediaremote-adapter` stream through `/usr/bin/perl`;
Xcode builds and embeds `MediaRemoteAdapter.framework` without linking it into
the application, and the Perl entry point loads it in its own process. This
accommodates the private MediaRemote interface's restrictions on direct application
access since macOS 15.4. It is still a private interface and future OS changes can
make it unavailable. The app does not invoke the adapter's playback commands or its
test client, which would create a synthetic system Now Playing session.

If the adapter has not answered two seconds after it starts, whether it is silent or
its helper failed, and only then, `FallbackSystemMediaProvider` asks the
music players that are **already running**. Membership is decided from
`NSWorkspace.runningApplications` by bundle identifier (`com.apple.Music`,
`com.spotify.client`): an Apple Event sent to an application that is not running
launches it, and a wallpaper must never start the user's music player. The first
running player with a loaded track wins, and the first query to it can prompt macOS
Automation permission. The app declares `NSAppleEventsUsageDescription`; without it
macOS refuses every Apple Event before the Automation prompt can appear. If the
fallback player exits or neither player reports a readable track, the title, cover,
playback, timeline and transport target are withdrawn together; late artwork from
the previous subscription is ignored, and a recovered player is read afresh.

**Stream rules.** The stream runs only while a host has consumers. Complete JSON
snapshots are decoded with an 8 MiB pending-input bound, artwork is downscaled to
256 pixels, track changes clear stale covers, canceled subscriptions ignore late
messages, and a failed helper stops without an automatic restart loop (toggle
integration off and on to retry). A playing timeline is interpolated from the
reported position, timestamp and playback rate, bounded by duration. The adapter
provider skips base64 decoding and the `MediaArtwork` lookup for a repeated
`artworkData` string, but every complete message still updates properties, playback
and timeline; failed input is never cached, and the cache is released when the last
consumer leaves or the stream fails.

**The setting starts a source; presenting keeps it running.**
`WallpaperBridge.systemMediaSceneHandles()` names the applied desktop Scenes that
have the setting on **and** are actually presenting; the host starts and stops its
provider from that answer plus web consumers. A machine where every wallpaper has
the setting off never loads the adapter, never sends an Apple Event and is never
asked for Automation permission. Pausing playback, a battery or power-policy suspend,
a global presentation suspend and a single occluded display each remove their scenes
from that answer, which releases the adapter process, its timeline ticker and every
fan-out once nothing visible is left (a web wallpaper still on screen keeps its own
vote). The last state is kept, not queued: resuming replays the current state once.
`systemMediaConsentHandles()` is the separate question of what the user permitted
and does not shrink when playback stops; an incoming `engine.openUserShortcut` is
judged against it, because a button press must be refused for want of permission,
never for want of presentation. A scene the host has not fed yet (a replacement
wallpaper, a newly lit display, a rebuild) is replayed the current state instead of
waiting for the track to change.

The lock-screen extension does not load the provider or adapter. Lock-screen scenes
force the setting off after apply, even if the stored desktop config has it on.

## Scene wallpapers

A Scene wallpaper gets events when it is applied to a display and its own setting
is on. `SceneMediaSink` forwards SceneScript `mediaStatusChanged`,
`mediaPropertiesChanged`, `mediaPlaybackChanged`, `mediaTimelineChanged` and
`mediaThumbnailChanged`. JSON is forwarded verbatim so `subTitle`, `albumArtist`,
`genres` and `contentType` are not dropped.
`MediaPlaybackEvent.PLAYBACK_STOPPED` / `PLAYING` / `PAUSED` are 0 / 1 / 2, as in
Wallpaper Engine, and `event.state` carries the same numbers: scripts compare it
with those literals as often as with the names, so a host that sends another
numbering makes a paused player look like a playing one. The Swift codec
(`SystemMediaEventCodec.sceneScriptPlaybackState`) and the Rust bridge's typed
path (`MediaPlaybackState`, which serializes those numbers) both send them; the
bridge's own input, `BridgeMediaSnapshot.playback_state`, keeps the host's
numbering (playing 0, paused 1, stopped 2) and is mapped to the states by name.
Color arrays are exposed as `Vec3` (`.x` / `.y` / `.z`). Artwork is uploaded as RGBA
before `mediaThumbnailChanged` so `$mediaThumbnail` is valid when the script reads
it.

**Idle state.** Every scene starts as a desktop with no player, with or without the
setting. On its first tick, after its scripts have started and before the first frame,
the runtime tells them `mediaPropertiesChanged` with an empty track (the same object
the app sends with the setting on and nothing playing) and `mediaPlaybackChanged` with
`PLAYBACK_STOPPED`. Wallpaper Engine's media widgets are authored visible and hide on
`PLAYBACK_STOPPED`, so without this users with the setting off saw
their covers and mascots on screen all the time. The idle state reveals nothing about
what is playing, so it does not wait for consent: what a player really reports is
still dropped while the setting is off. It is said once, and only for an event type no
real event had said before that tick (the replay of the current state to a scene that
has just attached, with the setting on, wins); a real event afterwards replaces it
like any other. No timeline or thumbnail event is sent, as for a web page with no
player.

**Covers.** A new cover is pixels, not a new scene: `PublishSystemMediaArtwork`
replaces the image behind `$mediaThumbnail` and moves the outgoing one to
`$mediaPreviousThumbnail`, which is what a wallpaper cross-fades from. Each
renderer notices the version move and swaps the texture on its next frame (Vulkan
from the pass's per-frame update, Metal from `refreshRuntimeImages`) without
rebuilding the render graph, so a track change does not idle the GPU or reopen
videos. Both names are 1×1 transparent before any track, so a layer that binds
either always has an image. A slot whose author also left a texture in it (a cover
layer's default art) shows that texture instead of the transparent texel until a
cover is published, and again after the explicit clear, as Wallpaper Engine does;
a slot with nothing authored in it stays transparent
([scene rendering](scene-rendering.md)). Publishing a cover byte-identical to the
one showing does nothing, not even a frame request, which makes replays to new
scenes free and stops a wallpaper cross-fading a cover into itself. A recreated
renderer receives the current snapshot again.

The native artwork protocol represents absence as width 0, height 0 and an empty
byte payload. This explicit clear survives bridge validation, pending scene creation
and renderer replay, then publishes transparent 1×1 images to both texture names;
other empty dimensions or inconsistent RGBA byte counts are rejected, and repeated
clears do not wake an unchanged scene.

**Transport buttons.** A wallpaper's own buttons call `engine.openUserShortcut`
with the name of one of its `usershortcut` properties. The engine resolves that
property against the wallpaper's own declarations (naming another throws) and
reports the request with the property's **value**, which is the user's choice. The
property reaches the panel as a picker offering no action, play / pause, next track
and previous track.

Authors ship these empty, because Wallpaper Engine has the user bind them in its own
editor. So that buttons are not dead until the user finds the picker, an unbound
shortcut starts on the action its own name states: `playpausebutton`,
`nextsongbutton` and `previoussongbutton` begin bound to play / pause, next and
previous (`media:playpause`, `media:next`, `media:previous`), and a name that says
nothing stays unbound. This is a starting value only: the user's choice is stored as
an override and always wins, including choosing no action, and dispatch carries the
**value**, never the name, so rebinding a button really rebinds it. Because the scene
engine parses the project file itself, the host-supplied default is included in the
scene's property overrides even when the user has none, with the user's overrides
applied on top.

A button's release is delivered to whatever took its press, wherever the cursor has
since gone, instead of being hit-tested again: these buttons scale down while held
and restore from `cursorUp`, so re-testing the layer would lose the release for
exactly the buttons that need it. Anything that did not take the press still has to
be under the cursor to hear a release, and a scene-wide script with no layer of its
own still hears one from anywhere.

`WallpaperBridge.next_user_shortcut` long-polls for presses and drops any from a
wallpaper the user has not consented to media integration for. The wait belongs to
`SceneMediaSink`, which already holds the one live session, so the command goes to
whichever provider is actually answering. Each hop of a press is logged.

To render a media wallpaper without a system media source or Automation permission,
feed the offscreen probe synthetic events; the variables (`WE_TEST_MEDIA_EVENTS`,
`WE_TEST_MEDIA_ARTWORK`) are in [renderer testing](../testing/renderer.md#probes).

## Web wallpapers

Web delivery uses listeners on `window`, PNG data-URL artwork, and the constants
under `window.wallpaperMediaIntegration`. The status listener reports the user's own
setting, not the system's capability: with the setting on and no provider available,
status stays `enabled: true` while properties are empty, playback is
`PLAYBACK_STOPPED`, and the timeline listener does not fire at all. The listener
contract is in [Web wallpapers](web-wallpapers.md#host-protocol).

## Verification

The provider, fallback, artwork and sink tests run against fake streams and injected
script results (see *SystemMedia* in [coverage](../testing/coverage.md)); Rust bridge
tests cover consent, disabling and clearing, invalid states, nonfinite times and
artwork bounds; `scenescript_media_event_smoke` and `media_thumbnail_texture_smoke`
exercise script delivery and runtime textures without a real player. Live Spotify,
Apple Music, browser and local-player integration requires an explicit desktop run:
passing the simulated tests is not proof that a particular player or OS version
publishes all fields.
