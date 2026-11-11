# Desktop widgets

Clocks, dates and the other widgets the app draws on the desktop, over whatever wallpaper is on
show. A widget
belongs to no wallpaper: applying another wallpaper, a playlist change or an automatic rule
leaves it where it is. They are set up in **Settings › Desktop Widgets**.

## What the user sees

**Add Widget** is a menu of the kinds; the one chosen goes on the main display (the one with the
menu bar), a little below any widget already there, and opens in the editor. The list under it
shows each widget's words now (the first line of a text, the month of a calendar), its kind and
its display (and **Hidden** for one switched off); a click picks the widget the groups below
edit. Up to 24 widgets can be added.

| Kind | Shows | Changes |
| --- | --- | --- |
| **Clock** | The time, of this Mac's time zone or another city's, after an optional label | Each minute, or each second with seconds |
| **Date** | The date in one of eight styles, in the region's calendar or another one, of this Mac's time zone or another city's, after an optional label | At midnight |
| **Text** | Words the person wrote, on one line or several | Never |
| **Countdown** | "12 days until Launch", "Launch is today", "3 days since Launch"; without an event name, the day itself names it | At midnight |
| **Greeting** | Good morning (from 5), afternoon (12), evening (18) or night (22), with a name if given | At those hours |
| **Battery** | "Battery 82%", or "Charging 82%" while it charges; "No battery" on a Mac without one | When the battery's notification says the reading changed |
| **Sunrise and sunset** | The next sunrise or sunset, or both of today's | At each of them and at midnight |
| **Analog clock** | A clock face with hour marks and hands, a second hand if asked | Each minute, or each second with seconds |
| **Month calendar** | This month's name, the weekdays and the days in a grid, today in bold and underlined; weeks start on the region's first weekday | At midnight |

- **Position**: **Show on the desktop**; **Display** (**Main display**, which follows the menu
  bar, **All displays**, or one display by name; a display that is not connected stays in the
  menu as "*name* (not connected)" and the widget comes back when it does); **Arrange**, a
  picture of that display with the frame its wallpaper is drawing and every widget shown there,
  where dragging a widget moves it and letting go saves the place (see
  [the preview's backdrop](#the-previews-backdrop)); **Horizontal position** and
  **Vertical position**, the same place in whole percent from the left and the top edge, for the
  keyboard and VoiceOver; **Alignment** (**Left**, **Center**, **Right**), the edge of the text
  the position holds, so a clock aligned left does not move its left edge when "9:59" becomes
  "10:00".
- **Look**: **Size** (10 to 320 points; a clock face is one and a half times its size across),
  **Typeface** (not for the clock face) (**Standard**, **Rounded**, **Serif**,
  **Monospaced**: the system font's four designs), **Weight** (100 to 900 in steps of 100),
  **Color**, **Opacity** (10 to 100 %) and **Shadow**, a soft dark shadow that keeps light text
  readable on a light wallpaper. Digits keep one width in every typeface, so a clock does not
  shift as it counts. The lines of a text line up on the edge chosen in **Alignment**.
- **Format**, by kind:
  - a clock: **Time format** (**Follow system**, **12-hour**, **24-hour**), **Show seconds**,
    **Time zone** and **Label**;
  - a date: **Date format**, whose menu writes each style out for today (weekday, month and day;
    month, day and year; the short form; numbers only; the weekday alone; month and year; the
    week of the year, numbered as the region numbers weeks; the day of the year), **Calendar**
    (**Follow system**, or the Chinese, Islamic (Umm al-Qura), Hebrew, Persian, Buddhist,
    Japanese or Indian calendar, each named in the panel's language and written in that
    calendar's own words: "九月三十" in the Chinese calendar), **Time zone** and **Label**;
  - an analog clock: **Show seconds** and **Time zone**;
  - a text: **Text** (Option-Return starts a new line); a countdown: **Event** and **Count down
    to**, a date picker; a greeting: **Your name**;
  - sunrise and sunset: **Sun times** (**Next sunrise or sunset**, **Today’s sunrise and
    sunset**) and **Time format**. The times are those the automatic wallpapers plan with
    (Settings › Displays › Sunrise and sunset): worked out from the coordinates typed or found
    there, or the two clock times fixed there. Without a place it says so; on a polar day or
    night it says there is none today.
  - a battery and a month calendar have no format of their own.

  **Time zone** offers this Mac's own and fifty cities, one for each offset people live at, by
  the city's name in the panel's language and its offset from GMT now. Choosing a city for a
  clock or a date without a label labels it with the city; a label of one's own stays. The
  label, a text, an event or a name keeps at most 500 characters.
- **Remove this widget** takes it away; the editor moves to the next widget.

Every change shows on the desktop at once, a colour while it is being picked in the colour
panel included; none of these controls waits for the renderer or for a wallpaper being applied.
The words follow the Mac's language and region formats (System Settings › General › Language &
Region) and its time zone, as the menu bar clock does, and change with them. The phrases of their
own (a countdown, a greeting, the battery, the sun, "Week" and "Day") are in the language the app
was launched in.

## How it is drawn

`DesktopWidgetController` (`App/Services/Desktop/`), started by `AppDelegate`, puts one
`MWEDesktopWidgetWindow` (`DesktopWidgetWindow`) on each display a shown widget belongs on. The
window is transparent and only as large as its text and shadow, one level above the wallpaper
windows (the [coverage probes'](../architecture.md#desktop-wallpaper-windows-and-private-api-handling)
level) and below Finder's desktop icons, on every Space, ignoring the mouse and never hidden with
the app. Its class is not a wallpaper window class, so occlusion tracking, the window audit and the
desktop-picture posters never look at it. Being transparent, and never as tall as a display's
working area even at the largest size, it never makes a display count as covered. A click on a
widget reaches the desktop beneath it.

`DesktopWidgetRendering` holds what both the desktop and the panel's **Arrange** picture draw: the
words (a Unicode date template the locale arranges, through cached `DateFormatter`s), the month
grid (right-aligned tab stops, one per weekday), the clock face (where each hand points), the
font, the shadow and the frame. `DesktopWidgetView` draws text from the top of its frame, or the
face as one layer, so crossing hands neither darken nor shadow each other. The position names the
content's chosen edge and its vertical centre as fractions of the display; the frame is then
moved, never shrunk, to lie on the display, and is cut only when the content is wider than the
display or taller than 60 % of it, so even a long text never covers a display's working area.

The windows cost nothing between changes of their words:

- Without widgets the controller keeps no window and no timer and only listens for the store's
  change.
- With widgets it redraws when what they show changes (the **Changes** column above), each in
  its own time zone, from one one-shot timer for all of them. Texts and batteries alone schedule
  no timer. A widget's view redraws only when what it draws changed, and a window moves only
  when its frame did.
- The battery's IOKit notification (`SystemBatteryLevel`) is registered only while a battery
  widget is placed, and redraws only when the reading changed; nothing polls it.
- A change of the sunrise and sunset settings (`WallpaperAutomationStore.didChangeNotification`)
  reads them again from the preferences and redraws.
- While none of the widget windows can be seen (windows cover them, the displays sleep, the
  screen is locked) no timer is scheduled; the occlusion change of a widget window brings them up
  to date and schedules the next change again.
- A wake, a change of the clock, the time zone, the region format or the day redraws at once. A
  screen change moves the windows and touches only the ones whose frame changed, so an XDR
  display's stream of EDR headroom changes touches none.

## Storage

The widgets are a JSON array in the app's preferences (`WallpaperMachine.desktopWidgets`,
`DesktopWidgetStore`). Each field has a default, so a widget saved by another version keeps what
it carries; a saved list with a value no control could choose (out of range, an unreadable
colour, a repeated id) is not read, and the log says so. The panel's store writes the list and
posts `DesktopWidgetStore.didChangeNotification`; the controller reads the list again from the
preferences.

A [backup](backup-restore.md) carries the widgets and refuses a list with such a value.
**Reset all settings** keeps them, as it keeps playlists, presets and display layouts.

## The preview's backdrop

The **Arrange** picture shows the wallpaper as the display draws it, not the author's preview
image, which often has another shape, crop and resolution. When the row appears, or the
display's wallpaper or its files change, the page asks the wallpaper's own surface for one frame
through the poster pipeline ([when a poster is taken](desktop-picture.md#when-a-poster-is-taken)):
a Metal readback for a scene, a snapshot for a web page, the player's frame for a video. The
frame has the display's aspect and the wallpaper's placement, scaling and properties; it is
scaled to at most 1024 pixels on its longer edge and only that copy is kept
(`DesktopWallpaperFrames`, wired as `BridgeStore.wallpaperFrame`).

Many wallpapers open with an intro or fade in from black, so the first frame is shown at once
and replaced by a **settled** one once the wallpaper has played a moment:

- `WallpaperSettleClock` counts, per display, how long the wallpaper has played where it can be
  seen: time paused, covered, asleep or suspended by a rule does not count, and a new wallpaper,
  a new window or new files start the count again. The app reports what each display shows after
  every engine snapshot, host pass and presentation change. A wallpaper has settled after the
  desktop picture's settle window, 15 s (`DesktopWallpaperSync.settleCaptureDelays`).
- The wallpaper is asked presenting or not: the panel's own window usually covers the display,
  and a paused surface answers with the frame it holds without playing on, which is past the
  intro when it had played long enough before it stopped. A wallpaper that has not settled
  gives that frame as its first picture.
- A frame that is black or one flat colour all over (sampled on a 32 × 32 grid) is never shown.
- The last settled frame of each display is kept in memory with its `DesktopPosterLook`, so a
  wallpaper replaying its intro under the same look still shows it; a new look drops it.
- Without a frame of its own, the desktop picture sync's poster stands in when it has settled
  (`DesktopWallpaperSync.settledPoster(display:)`: taken while presenting after the settle
  captures of the wallpaper's start, or given back as settled).
- With nothing settled, the first frame shows, and without one (or a blank one) the still with
  the note "Showing the wallpaper's preview image until it has played for a moment." under the
  picture. A wallpaper that plays is asked again after the rest of the settle window. One that
  does not play, such as one paused because the panel covers the desktop (**When the desktop is
  covered** › **Pause**), does not move on, so it is asked again when it next starts or stops
  playing where it can be seen (`WallpaperSettleClock.nextChange`, which sleeps only while a
  waited display plays), and settles once it has played the window. Nothing renders a covered
  wallpaper to settle it. The wait is the row's task and ends with the row.
- The request carries its own `panel-preview:` context, so the desktop picture sync never takes
  the frame as a poster. When the sync is waiting for a frame from that surface, the page asks
  nothing and takes the sync's frame: a renderer answers piled-up requests with one frame
  carrying the newest request's context, and asking would cost the sync its frame.
- No timer runs while the row is not shown and no second renderer runs; the frame is a still.

## Limits

- Only the live desktop shows widgets. The lock screen and the screen saver show only the
  wallpaper (macOS draws its own clock there), and so do the still pictures the app writes as
  the macOS desktop picture, which Mission Control and a quit show.
- Widgets cannot be clicked or dragged on the desktop itself; they are arranged in Settings.
- The kinds are the app's own: lifting a layer out of a scene wallpaper (such as another
  wallpaper's clock) is a different feature this one does not do. Weather, calendar events,
  system load and Now Playing are not offered: they would need a network service, a permission
  prompt, polling or a private framework.
- The battery line in the panel's preview uses the level the panel last read and does not tell
  charging apart; the desktop does.
- A display mirrored to another shows what that one shows.

## Code and verification

- `App/Services/Desktop/`: `DesktopWidget` (the record and its validation),
  `DesktopWidgetStore`, `DesktopWidgetRendering`, `DesktopWidgetController`,
  `DesktopWidgetWindow`, and `DesktopWallpaperFrames` and `WallpaperSettleClock` (the preview's
  backdrop).
- `App/Views/ControlPanel/`: `Settings/Sections/WidgetsSettingsSection.swift` and
  `DesktopWidgetPreview.swift`, the page model `Settings/DesktopWidgetsSettingsModel.swift` and
  the typed actions in `Model/PanelController+DesktopWidgets.swift`.
- Tests: `Tests/Unit/Desktop/DesktopWidgetTests.swift` (each kind's words, the clock face, the
  month grid, other calendars and time zones, frames and the height limit, the next change,
  storage and backup validation), `DesktopWidgetControllerTests.swift` (windows per display,
  timing, occlusion, wake and screen changes, the battery's notification and the sunrise and
  sunset settings, the window's level and class) and `Tests/Unit/Panel/WidgetsSettingsTests.swift`
  (actions, the Display, Date format, Time zone and Calendar menus, the rows each kind offers,
  the preview's wallpaper frame, search and layout in the narrowest and widest column).
  `DesktopWallpaperFramesTests.swift` covers asking a settled wallpaper once and scaling, waiting
  for the sync's own frame, not asking during an intro, the frame kept per look, blank frames and
  the poster fallback; `WallpaperSettleClockTests.swift` the settle count.
- The unit tests never put a widget window on screen. What a widget looks like on a real
  desktop (the clock face and the month grid included), over each kind of wallpaper and across
  Spaces, is checked by hand.
