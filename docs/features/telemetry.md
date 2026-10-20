# Performance data

**Settings → Storage → Troubleshooting → Send performance data** sends a small report
once a day so slow wallpapers, slow Macs and crashes can be found from real use. It is
off until the user turns it on: in the welcome guide's Preferences page, in Settings, or
in the one-time question the panel asks someone who finished the guide before it had
the switch. While it is off nothing is recorded, nothing is written to disk and no task
or timer exists.

Code: `App/Services/Telemetry/` (`TelemetryService`, `TelemetryReport`,
`TelemetrySampler`, `TelemetrySpool`, `TelemetryClient`, `TelemetryPreferences`,
`TelemetryEnvironment`). The receiving end is the website's Worker
(`/api/telemetry`), which lives in the website's own repository.

## What a report holds

Every field is a number, a flag or one of a fixed set of words. There is no free text:
no title, path, display name, account, error message or exception name, so nothing has
to be redacted afterwards. The only identifier of a wallpaper is its Steam Workshop id,
which is public. Any id that is not all digits (an import, a pixiv save, a picture, a
folder in the library) is sent as `null` with `source: "local"`, and
`TelemetryWallpaper.workshopID` is the one place that rule lives.

| Part | Contents | Where it comes from |
|---|---|---|
| `install` | A random UUID made when sending is turned on and forgotten when it is turned off | `TelemetryPreferences` |
| `app` | Version, build, and `source`: `false` only when the copy is signed with the project certificate releases use ([release signing](../build.md#release-signing)); an ad-hoc signature or any other certificate, even one with the same name, is a build from source | the bundle and its code signature (`TelemetryEnvironment.isSource`) |
| `mac` | `hw.model`, CPU brand, core count, memory in GB, macOS version, Metal GPU name, and each display's pixel size, scale, maximum refresh rate and whether it is the main one | `TelemetryEnvironment` |
| `sessions` | For each earlier run: start day, version, how it ended (`clean`, `quitStalled`, `unexpected`, `systemRestart`, `exception`), whether macOS left a crash report, minutes, memory-pressure warnings and critical events, peak footprint in MB | the [session ledger](diagnostics.md#how-the-previous-session-ended), the crash report lookup and this run's record |
| `activations` | Day, `activation`/`reload`/`reapply`, wallpaper, kind, origin, outcome and milliseconds | the facts each [activation line](diagnostics.md#wallpaper-activations) states, handed over by `BridgeStore` |
| `frames` | One row per scene surface per frame window (below): backend, fallback, scene mode, window length, frame-clock and content rates, draws, dropped draws, suppressed ticks, unchanged frames skipped, present requests, render failures, the display's size and refresh rate, frame-rate cap, render scale, Reduced quality, battery, Low Power Mode and thermal state | the renderer's own counters |
| `energy` | Ratings added or changed since the last upload: milliwatts, seconds measured and the conditions | [per-wallpaper energy ratings](performance.md#per-wallpaper-energy-rating) |
| `loadStrikes` | Workshop wallpapers the crash guard caught loading when the app died, with the journal's running count | the [load journal](crash-recovery.md) |

Machine strings pass a strict pattern (`Mac15,3`, `Apple M3 Pro`) or are dropped. The
language, time zone, host name and display names are never read for a report. Each
batch keeps at most 30 sessions, 200 activations, 50 frame rows, 100 energy rows and
50 load strikes; when more pile up, the oldest go.

**Show in Finder** next to **Data to be sent** writes `next-report.json`, the exact
report the next upload would send, formatted, and shows it.

## When it runs

One task drives everything while sending is on:

- A minute after launch it records how the previous run ended and sends if a day has
  passed. The crash report lookup runs 20 s after launch, so the answer is in by then.
- Ten minutes after launch, and every four hours from then, it moves this run's
  checkpoint, opens one frame window and sends if due.
- It sends at most once a day: 24 hours after sending was turned on, then 24 hours
  after each upload. A failed upload is tried again at the next four-hour cycle, never
  sooner. A report with no rows is not sent.

The run record (`session.json`) is written at launch, at each memory-pressure event, at
each cycle and at quit, so a run that crashed still has a lower bound for its length.

## Frame windows

The app does not otherwise measure frame rate. A frame window turns the renderer's
counters on for 60 s, reads them at both ends and turns them off again, also when a
read fails. Counting is cumulative and turning it on does not reset it, so each row is
the difference between the two readings of the same surface.

A row is left out when it would not describe a playing wallpaper:

- the surface was paused or had a pause reason at either end;
- the surface appeared, went away or changed generation during the window;
- its display changed wallpaper during the window;
- presentation changed during the window (the same events that void an
  [energy interval](performance.md#per-wallpaper-energy-rating)), which voids every row;
- the display is suspended on its own, playback is paused, or memory pressure is critical.

Web wallpapers draw in their own web views and have no frame rows; their activations
and energy are still reported.

Cost: with counting on, every counted event is one relaxed atomic add in the renderer;
with it off, one relaxed atomic load. A window is 60 s in every four hours, about 0.4 %
of the time. Its energy effect has not been measured on a desktop yet
([power benchmark](../testing/power-benchmark.md#runtime-counters)).

A run whose environment sets `WALLPAPER_MACHINE_DIAGNOSTICS` opens no frame window at
all. Both would switch the same counters, and a power measurement must not include
telemetry's windows.

## Files

Everything lives in `<support>/Telemetry/` (`ClientPaths.telemetryURL`), only while
sending is on:

| File | Contents |
|---|---|
| `pending.json` | Rows not sent yet |
| `session.json` | This run's record, read at the next launch |
| `next-report.json` | Written only by **Show in Finder** |

## Turning it off

Turning it off deletes the folder, forgets the install id and asks the website to
delete everything stored under that id (`POST /api/telemetry/delete`). The request is
kept in `TelemetryPreferences` until the website answers it, and asked for again at
every launch until then. Turning sending on again makes a new id, so the two periods
cannot be joined.

## Website side

`POST https://www.wallpapermachine.app/api/telemetry` takes the report as JSON with a
`WallpaperMachine/<version>` user agent; any 2xx counts as sent.

The Worker:

- validates every field against the same contract and drops rows that fail;
- stores the UTC day it received the report, never the time and never the IP;
- keeps one report per install per day;
- deletes rows older than 180 days.

The data is kept in its own D1 database, `wallpapermachine-telemetry`, separate from
accounts so it can never be joined to them. A maintainer (the website's `OWNER_EMAIL`)
reads it as totals on the website's `/account/telemetry/` page; no install id leaves
the database there. The IP is used only as a rate-limit key,
and Cloudflare's request logs keep it for up to 7 days. The website's
[privacy notice](https://www.wallpapermachine.app/privacy/) says all of this.

## Verification

- `Tests/Unit/Telemetry/TelemetryServiceTests.swift`:
  - nothing is written or sent while it is off;
  - one upload a day, carrying only rows not sent before;
  - a failed upload keeps its rows;
  - turning it off deletes the folder and asks for deletion, and a deletion that was
    not confirmed is asked for again at the next launch;
  - a report built from home paths, user names, local folders and pixiv ids carries
    none of them;
  - the previous run is reported with how it ended.
- `TelemetrySamplerTests`:
  - rows are deltas between the two readings;
  - paused, covered, switched and invalidated windows report nothing;
  - counting is always turned off again.
- `TelemetryClientTests`: the request is one POST with the app's user agent, and
  anything but a 2xx is a failure.
- `SupportPromptStoreTests` and `PanelPerformanceDataTests`: the one-time question,
  through the panel's presenter; the Settings switch round-trips, **Show in Finder**
  writes the report it would send, and the guide answers the question only once its
  switch was shown and commits the switch as a draft.
