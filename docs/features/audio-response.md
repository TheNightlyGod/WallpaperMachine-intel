# Audio-responsive wallpapers

Scene wallpapers with authored audio effects and web wallpapers with an audio
listener can react to sound playing on the Mac. This document owns the setting, the
capture and the analysis; how a web page receives the spectrum is in
[Web wallpapers](web-wallpapers.md#audio-response), and the now-playing metadata
feature is separate ([Media integration](media-integration.md)).

## Enabling it

Select the wallpaper, then turn on **General configuration → Audio response**
in the inspector. The setting is saved per wallpaper and also applies to that
wallpaper's mirrored displays.

Capture runs only while a wallpaper with audio response on is presenting (not
paused, covered or asleep) and actually reads the sound: an audio-processing
material or particle emitter, a spectrum shader input, or a script that
registers audio buffers. A subscribed web page on screen also counts. A scene
that reads no audio, and every video wallpaper, never starts capture, even with
the setting on; the effects that would have used it received silence anyway. A
script that starts reading later starts capture then.
Capture stops when the last such wallpaper stops presenting or is removed.
Activation errors are reported rather than silently ignored.

A subscribed web page owns capture independently of renderer scene handles, so
web-only sessions work and scene cleanup does not stop their audio. Both kinds
of wallpaper share one capture tap; pause and the saved Audio response setting
still gate delivery. A web page the user paused withdraws its own request for
audio until it plays again; the shared poller stops once no page still asks for
audio. Enabling media integration alone does not enable audio response.

## Permission

macOS requests system audio recording permission at capture startup. If access
is denied, grant it in **System Settings → Privacy & Security → Screen &
System Audio Recording**, then retry the switch.

## What the input is

The input is sound playing in other apps. It is not the microphone, and it is
not the wallpaper's own playback. The wallpaper mute and volume controls stay
independent of audio response.

Capture is a CoreAudio process tap created with
`initStereoGlobalTapButExcludeProcesses:`, so the left and right channels are analysed by
separate FFTs. If that initialiser is absent or the created tap reports fewer than two
channels, capture falls back to a mono tap: left and right are then equal, and nothing
reports that as stereo. The spectrum's `stereo` flag describes how the PCM was submitted,
not whether the content happens to differ.

## Output device changes

Capture is rebuilt when the default output device changes, for example when
headphones or a USB audio interface are connected or removed. The change is
reported after 300 ms without further changes, so a Bluetooth device that
announces a switch several times produces one rebuild. Only a running tap or its
pending recovery is rebuilt: device changes never start a cleanly stopped tap or
one waiting for its first permission grant. A paused display starts a tap on the
current device when it resumes. A rebuild never asks for permission again. The app
watches for the change only while capture is wanted, from the moment a scene that
reads audio or a web page
starts it until the last one stops or capture is suspended, so a Mac whose wallpapers
never read audio has no watcher and a device switch writes nothing to the log.

If the new tap cannot be started, it is tried again after 0.5, 1 and 1.5
seconds; a newer device change replaces the pending retries, and a tap that has
started in the meantime is left alone. After the last failure the log says the tap
could not be rebuilt, and it starts again at the next scene or demand change; no
alert is shown. These steps are written to the application log with the
`[wallpaper-core audio]` prefix. While the tap is down, the analysis treats the
input as stale after 250 ms and the spectrum falls to zero.

Healthy capture and unfinished teardown are tracked separately. A failed callback,
aggregate-device or tap release retains its resources for retry but does not report
usable capture. Disabling demand retries remaining cleanup; reactivation or a rebuild
finishes that cleanup before creating another tap, without repeating successful
release operations. Permission is checked before starting a replacement, and repeated
healthy demand keeps the same tap. A failed suspension restores the previous desired
demand and attempts to restore actual capture; if cleanup prevents that rollback, the
error includes both failures. Removed scenes stay removed, even if teardown fails.
The scene/demand and rebuild retry paths recover capture when cleanup later succeeds.

## What wallpapers receive

Wallpapers are authored against Wallpaper Engine's numbers, so the analysis
follows what its developer and its docs describe and what tones measure on it.
Its exact formula is not published; where this differs, it is an estimate.

- Captured audio is analysed at 48 kHz, 30 spectra a second, each from its own
  33 ms Hann-windowed block. Nothing is decimated without a filter, so treble
  stays in the treble bands.
- The 64 bands are one ~23 Hz FFT bin wide up to about 400 Hz and then widen
  exponentially to about 15 kHz: an octave tone at 42 Hz, 95 Hz, 190 Hz, 380 Hz,
  760 Hz, 1.5 kHz, 3 kHz, 6 kHz and 12 kHz peaks in the band Wallpaper Engine
  shows it in. The 32- and 16-band resolutions cover the same frequencies with
  the energy of the bands they merge.
- A band's value is its level on a 48 dB scale: 0 at -48 dB or below, about 1
  for a full-scale tone, and occasionally a little above 1, as Wallpaper Engine
  documents. Normal music sits mostly between 0.1 and 0.3 with peaks towards 1.
- Every spectrum stands alone. Wallpaper Engine leaves smoothing to the
  wallpaper, so a visualizer that smooths in its script looks as intended and
  one that does not jumps from frame to frame, as it does there.

Scenes receive the values as analysed; web pages receive them clamped to 0.0–1.0 (see
[Web wallpapers](web-wallpapers.md#audio-response)).

## Supported effect paths

| Path | Notes |
| --- | --- |
| Shader spectrum effects | Authored audio-reactive shaders |
| Web `wallpaperRegisterAudioListener()` | 64 bands per channel, one shared delivery pump capped at 30 Hz; a cleared spectrum keeps arriving through silence (every poll for 1.5 s, then once a second) so pages that smooth per callback finish decaying ([details](web-wallpapers.md#audio-response)) |
| SceneScript `engine.registerAudioBuffers()` | 16, 32 and 64 bands |
| Particle emitters and operators | Box and sphere emitters, and the `turbulence` and `vortex` operators, with audio frequency, bounds and exponent settings; a scene that has any of them captures audio |

## Non-goals

- Pre-rendered video wallpapers do not gain reactive effects.
- The [lock-screen extension](lock-screen.md) does not capture system audio.

## Verification

Synthetic offscreen checks cover the analysis against tone measurements
(`AudioResponseMonoTest`, see [renderer testing](../testing/renderer.md)), audio-driven
shader color and SceneScript scale. Device-free controller and bridge tests cover web-only
capture startup, permission, shared ownership, suspension and shutdown, and the
[output device rebuild](#output-device-changes): the debounce, the controller restart,
the retry delays and superseded retries. Offscreen WebKit tests cover listener
delivery. Live capture and desktop behavior require a separately authorized manual
check; that includes the CoreAudio listener itself and a real device switch, which no
unit test can exercise.
