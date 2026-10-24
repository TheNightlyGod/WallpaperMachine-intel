# Manual release smoke checklist

**This checklist is manual and is not automated.** Every item below controls the
desktop, opens application windows, changes the user's wallpapers, signs in to
Steam, or grants system permissions, so each run requires an explicit user
decision. It is neither routine verification nor a required release gate (see
[README.md](README.md#authorization-boundary)), and no agent may perform it
without an explicit request.

Perform the checks yourself when preparing a release, using disposable imports
where needed. Note any check skipped for unavailable hardware or assets. Restore
your original wallpaper configuration afterwards. Native tests do not establish
these visual and OS-integration behaviors; report them unverified when no check
was run.

## Launch and window

- [ ] One library window opens, the starter wallpaper is visible, and there are
      no blank floating panels.
- [ ] Switch between the Library, Steam Workshop, pixiv and Settings tabs, between All
      wallpapers and Favorites with Library's chips and to a collection from the filters
      panel, and through the eleven Settings sections: Quick
      Settings (the one Settings opens on), General, Appearance, Desktop & Lock Screen,
      Playback & Power, Performance, Displays, Keyboard shortcuts, Library & Steam,
      Storage, About. The window title names the place on show each time, and on All
      wallpapers, Favorites and a collection the subtitle counts it.
- [ ] Narrow the window below 960 points: the inspector closes, the tabs stay whole in
      the middle of the title bar, nothing overlaps the traffic lights or the toolbar, and widening
      the window opens the inspector again. Open it with the toolbar's **Wallpaper
      details** button while the window is narrow: it stays open as the window grows and
      shrinks, and so does a choice to close it in a wide window.
- [ ] Command-comma reuses the existing window.
- [ ] Move the panel to another Space (or a desktop with another app full screen) and
      choose Control Panel from the status menu: it appears on the Space you are on,
      and the green button still offers full screen. Minimize the panel, then choose
      Control Panel from the status menu, click the Dock icon, and Command-Tab to the
      app: each brings it back from the Dock. Repeat the Space check with What's New,
      a wallpaper preview and a Steam or pixiv sign-in window.
- [ ] Close the window with its close button and with Command-W, and reopen it
      each time, without quitting or crashing.
- [ ] On Installed, type a search, change the sort and direction, untick a type box
      and scroll down a long library, then close the panel and reopen it from the status
      menu: the search, sort, boxes and scroll position are as left. Quit and relaunch:
      Installed starts unfiltered at the top.
- [ ] In Filters → Tags, click a chip: it fills with the accent and a check and only
      wallpapers with that tag stay; click it again and they all return. Option-click
      (or right-click → Hide this tag) strikes it through and hides them.
- [ ] With the app running, `open -n` the same app: no second copy appears and the
      first shows its panel. Run a copy from another folder: an alert says another
      copy is using the library, and the running copy is untouched. After an in-app
      update the new version starts normally.
- [ ] Switch WallpaperMachine off in System Settings → General → Login Items, then
      turn **Launch at login** on in Settings → General: the switch returns to off, a
      note says to allow it in Login Items, and **Open Login Items…** opens that pane.
      Allow it there and come back to the panel: the switch is on and the note goes
      away without any other action.
- [ ] In Settings, flip a Quick Settings tile (try Mute All): its full row in
      Playback & Power follows, and the other way round. Search for a word from a row's
      explanation: matching rows stay, the section list counts matches per section and dims
      the rest, a disclosure holding a match opens and closes again when the search
      clears, Escape clears the field, and a word nothing contains reads "No settings
      match …".
- [ ] On a laptop on battery, set **On battery** to Keep running and **When the battery is
      low** to Reduced quality at a level above the current charge: Quick Settings' On
      battery and Quality modules read "The battery is low. Reduced quality is in use.",
      Performance's **Effective now** reads "Limited to 30 fps while the battery is low"
      while the Frame rate limit slider reads No limit, and a display set above 30 fps notes
      the same limit in Settings → Displays and the inspector, whose button opens Playback &
      Power. Set the low-battery rule to Keep running: every one of those lines goes away.
- [ ] On a laptop on battery, set **On battery** to Keep running and **When the battery is
      low** to Pause at a level above the current charge: wallpapers pause, Quick Settings'
      On battery module reads "The battery is low. Wallpapers are paused." and the When the
      battery is low row adds "In effect now. Wallpapers are paused.". Set On battery to
      Pause: the module's line goes away; set the rule to Stop: it reads "… Wallpapers are
      stopped." again. Plug in: the line and the row's In effect now go away.

## Appearance

- [ ] Choose Light and Dark, then System, and change the macOS appearance.
- [ ] Check the title bar (the name and version, the tabs, one colour from the traffic
      lights to over the inspector), the inspector's edge resizing it, the Now Playing bar
      and its details, menus,
      controls, dialogs, inspector, filters panel and download popover in each mode.
- [ ] Set an accent and a surface tone; relaunch and confirm both persist.
- [ ] Try white and black accents, then Reset appearance. Wallpapers and
      playback must not change.

## Library and import

- [ ] Open and cancel Import.
- [ ] In Import's picker, a project's `scene.pkg` and `project.json` and a
      Wallpaper Engine folder are all selectable, and each imports its project(s).
- [ ] Import a large project (several GB, ideally from an external drive) twice
      with **Keep both copies**: the second import ends as skipped without a second
      copy in the library, in about the time it takes to read the project once.
- [ ] Apply an installed project to a display, change a file of its source folder
      (a different video, say) and import that folder with **Replace if changed**:
      the display shows the new file without being reapplied, the library holds
      one folder for it, and a second import of the same folder ends as skipped.
- [ ] With animated GIF previews in the library, Installed shows every tile as a
      still, with nothing moving at rest. Resting the pointer on a tile plays only
      that tile, Tab or arrow keys play only the focused one, and leaving it, a
      selection drag, another page or another window stops it with no flicker when
      the grid re-renders. When a Workshop download finishes or the library is
      rescanned, the covers stay as they are with no flicker; after a preview
      file is replaced (import it again with Replace if changed), only that
      tile's cover refreshes.
- [ ] With a saved Steam sign-in, select an installed Workshop wallpaper and
      choose **Reinstall from Workshop…** in the inspector's **More actions** menu:
      a sheet asks first and Cancel changes nothing. Confirming shows the
      download in the queue and, when it completes, the wallpaper keeps its
      options and a display showing it loads the new files. Delete the entry file
      from its folder beforehand to see the Compatibility check offer the same
      button, and Reinstall repair it. Imported pictures and folders with a
      non-numeric name show no button.
- [ ] Search for a nonexistent local title, clear the search, and confirm the
      collection returns.
- [ ] Select a wallpaper and refresh: the selection survives.
- [ ] Selecting must not activate a wallpaper. Apply/Reapply and double-click
      activate it, and double-click must not close the window. The window stays
      open after applying unless Settings → General → Hide window after applying
      a wallpaper is on.
- [ ] With a wallpaper playing, press **Reapply wallpaper** in its inspector: the
      wallpaper restarts from its first frame on that display only (watch a
      video or scene; note whether a scene flashes to the bare desktop while it
      reloads). Double-clicking the same tile, or choosing it in Recently used,
      must leave it playing without a restart.
- [ ] Try invalid media and missing scene assets: actionable failures appear
      without blocking videos or losing an already downloaded scene, and a valid
      wallpaper remains usable.

## Layout and accessibility

- [ ] Check Discover, pixiv and Installed at 1240×800, 960×640 and 760×560 in light and
      dark mode, with the inspector open and closed. Panes resize without losing the
      target menu or the primary actions, and nothing is cut off at the window's edge.
- [ ] Command-F puts the keyboard in the page's search field (Settings' too); grid arrows, Home and End, Return and Space, Delete, Escape (a name field,
      then a popover, then selection mode), text editing and VoiceOver names stay
      correctly scoped. With Reduce Motion on, no equalizer, spinner or preview animates.

## Discover, search and filters

- [ ] Search Discover, edit an unsubmitted query, then advance a page:
      pagination must still use the displayed query. Submit to switch queries.
- [ ] Navigate away and back: query, page and selection stay.
- [ ] A failed request's Retry repeats that request.
- [ ] Open and dismiss the Downloads/Import pane.
- [ ] Open the Filters sidebar from the page's Filter button and select tags across
      the resolution, ultrawide/portrait, genre, age-rating and category groups:
      results contain only items matching every selected tag, the sidebar slides out
      from the window's leading edge while the grid narrows, and Clear filters restores
      the unfiltered query. The Filter button and the sidebar's own button close it
      with the same slide; it stays open on the next library page.
- [ ] Filter changes never activate wallpapers.

## pixiv

- [ ] The pixiv page opens on the daily ranking; paging, a tag search and each
      filter group work, and Clear restores the defaults.
- [ ] Select a work with several pages, step to another page and download it:
      it appears in Installed as a still wallpaper, applies, and Image fit and
      Background color change it.
- [ ] **Sign in to pixiv…** opens pixiv's own sign-in page in its own window;
      signing in with a pixiv ID or email closes it and the Filters sidebar names the
      account. Closing the window instead changes nothing.
- [ ] Quit and reopen: the sign-in is still there, with no keychain prompt on a
      release build.
- [ ] With an account whose viewing restrictions allow R-18 works, tick Mature
      (R-18): search includes works with the R-18 badge and the R-18 rankings
      join the menu. With an account that hides them, the Filters sidebar says so.
- [ ] **Log out**: the Mature box unticks and disables, an R-18 ranking returns
      to its all-ages one, and Keychain Access no longer lists
      `app.wallpapermachine.pixiv`.

## SteamCMD setup

- [ ] Install or locate SteamCMD in Settings → Library & Steam or the download
      setup dialog, and use the same runtime without restarting.
- [ ] Installation itself must not log in; a retained wallpaper request
      continues once its prerequisites are met.
- [ ] Official signed command-line SteamCMD finishes from Install without an
      extra Allow step.
- [ ] A blocked download remains present across relaunch and retry.
- [ ] Only confirm Allow this SteamCMD after checking the shown path and
      understanding the risk, and only when Gatekeeper actually rejects a copy. Global Gatekeeper and signature checks stay enabled;
      updated bytes require another approval.
- [ ] An official no-login installation smoke uses a disposable support root and
      the production providers, stops on any Gatekeeper, architecture or signature
      block, and never approves a prompt or re-signs downloaded code. The
      installation candidate stays quarantined; only the validated disposable
      execution copy has its download marks cleared, just as for downloads.

## Download queue

- [ ] Double-click a Discover tile with SteamCMD installed and a saved sign-in:
      no dialog opens, the tile's ring fills with a percentage that matches the
      inspector's received/total bytes, and clicking the ring cancels.
- [ ] With a saved sign-in, queue at least four Workshop items: three transfer
      at once (the toolbar's downloads button rings itself and its tooltip reads "3
      downloading" with a combined speed),
      the fourth waits for a free slot, and the app log records each start.
- [ ] With no saved sign-in, queue several items: only the first prompts, the
      rest wait for the sign-in, then start silently as soon as Steam accepts
      it and before the first transfer finishes.
- [ ] Cancel an active item and check that the oldest queued item starts after
      cleanup.
- [ ] If Steam ends a session with "logged in elsewhere", the ended item goes
      back in line, the footer reads "Downloads run one at a time", and it
      retries after the running item without a click.
- [ ] With the panel closed and two or more downloads running, open the menu bar item: the
      line right under **Control Panel** reads "Downloads: N in progress" with a percent
      once every running download has a size (it stays out while one is still signing in
      or waiting), and does not read 100%. Choosing it opens Discover. After the last
      download finishes or is paused, the line is gone the next time the menu opens.
- [ ] Remove queued work and confirm it never starts.
- [ ] Complete one sign-in and check that the next job attempts saved-session
      reuse. Steam may still ask again.
- [ ] With no saved sign-in, the password / Steam Guard dialog opens by itself;
      Not now keeps it closed until Steam asks for something else, and the
      tile's shield reopens it. Close the Downloads popover, change search or
      page, and reopen the active transfer's sign-in dialog.
- [ ] Verify independent retry, completion and scene-resource consent.
- [ ] Saved sign-in settings stay locked until pending transfers finish;
      quitting stops all transfers.
- [ ] With setup missing, click Download, dismiss with Not now, and navigate
      elsewhere: the request remains in Downloads and Continue setup resumes it.
      Removing it prevents later automatic continuation.
- [ ] Completing setup, account and resource consent continues without another
      Start download button. Downloads do not auto-apply unless Download and
      apply was chosen.
- [ ] With a saved sign-in, choose Download and apply on a Discover video that
      is not installed: the inspector reads "Will apply when the download
      finishes.", and when it arrives the target display shows it. Repeat and
      apply a different wallpaper to that display while the download runs, or
      swap it with another display or apply a saved layout that names it: the
      display keeps your choice, the new wallpaper stays in the library, and the
      inspector says it was not applied because you chose another wallpaper.
      Click Download and apply on two wallpapers for one display: whichever
      arrives first, the one you clicked last is applied.
      Quit and reopen mid-download: the download comes back paused and applies
      nothing when resumed.
- [ ] Show in library reveals an item excluded by filters and returns to the
      original results; deleting it removes Discover's installed badge.

Synthetic-process tests do not prove Steam CDN throughput, live-account session
reuse, or visual behavior, which is why these items are manual.

## Displays and properties

- [ ] Select a target display and apply: other displays keep their assignments.
- [ ] Disconnected, disabled or mirrored targets are not silently redirected to
      primary.
- [ ] With two displays, select a wallpaper only one of them shows and choose **Apply
      to all displays** in the inspector: both change, the main display first, and
      the button turns unavailable. With a third display mirroring another, or one
      disabled, it keeps its own picture. `wallpapermachine://apply?id=ID&display=all`
      and Shortcuts' **On all displays** do the same. Unplug a display while the
      apply runs, or use a wallpaper whose files fail to load on one display: the
      others return to what they showed.
- [ ] Pause/resume and relaunch: the expected wallpaper and playback state
      return. Now Playing shows the target display's wallpaper with its equalizer
      only while playing; its Previous, play/pause, Next and Recently used buttons
      act as labelled, and with the target display empty it says "Nothing on this
      display" while still reporting the global playback state.
- [ ] Leave invalid scaling text, refresh or change routes, then return: the
      text is preserved and Apply changes is disabled. Return stages only that
      field, not unrelated properties.
- [ ] Check immediate audio/FPS/scaling-mode/position semantics versus pending
      Apply/Revert.
- [ ] Check the Language, Clock Location and Bar Style property menus, and that
      language-row changes survive reopening the app.
- [ ] When relevant, check each connected display and sleep/wake behavior.
- [ ] Set a display's playlist to **Rotate wallpapers** with **How often** at **Each time
      the Mac is unlocked** (the row's note says so and no next change is shown). Lock the
      screen, wait a few seconds and unlock: the wallpaper changes once, soon after the
      desktop is back, not while the screen is locked; locking and unlocking again
      changes it again, and two unlocks within a second change it once. Repeat after the
      display slept and woke, with a second display on its own unlock playlist (each
      changes once), with playback paused (nothing changes, and nothing changes later
      when playing resumes), and with a full-screen app covering the display (no change
      once the unlock is more than half a minute old).
- [ ] Preview a wallpaper for a portrait or ultrawide display (rotate one, or
      use a 21:9 or 9:16 display): the window opens with a stage of that shape
      and black bars, a scene or page lays out as it does on the display, and
      dragging the window to other shapes keeps the proportions without
      stretching. Previewing again for a 16:9 display reshapes the stage without
      resizing the window.
- [ ] Live property preview ([the preview follows your edits](../features/wallpaper-properties.md#the-preview-follows-your-edits)):
      open the preview of a scene with a slider, a colour, a switch that shows a layer and a
      choice, and of a Web wallpaper with a slider and a choice. Drag the slider: the preview
      follows the thumb, smoothly enough to steer by, and the desktop and the saved options
      do not change. Pick a colour, flip the switch (a layer that was hidden appears, with at
      most one short hitch) and pick a choice; **Restore default** and **Revert** put the
      preview back, and so does applying a preset. Type in a text field: nothing changes until
      Return or leaving the field. Minimize the window, change a value and show it again: it
      shows the new value once. Pause the preview, change a value and resume. Pick another
      picture or file where the wallpaper has such a property: the preview keeps the old one and
      its status line asks for a reload; **Reload preview** shows the new one and clears the
      line. **Apply changes** still reloads the desktop wallpaper from the saved options.
      Drag the slider and hold: the preview follows the thumb as it moves, not only after it
      stops, and stays where the thumb is while it is held; let go and nothing jumps, and a drag
      back to where it began puts the preview back. Open the colour panel and move around in it:
      the preview follows the colour while the panel is open, the colour is saved once you
      stop moving for a moment, and closing the panel saves the colour on show. Press **Revert** or **Restore default** while the picker
      is open: the preview goes back and nothing stays on show.
- [ ] Property edits on the desktop ([edits on the desktop](../features/wallpaper-properties.md#showing-edits-on-the-desktop)):
      with **Show property edits on the desktop as I make them** off, change a slider on a
      scene that is on a display: the desktop does not move until **Apply changes**. Turn it
      on and drag the slider, pick a colour, flip a switch that shows a layer and pick a choice:
      the desktop follows a moment after you stop (a layer that was hidden may cause one short
      hitch), the inspector still says **Modified**, and a picture or an option that adds an
      effect waits for **Apply changes**. **Revert**, **Restore all defaults** and a preset put
      the desktop where they say. Repeat with two displays showing the wallpaper and with a
      mirror: all of them follow. Edit, then close the panel without applying: the desktop keeps
      showing the edit, and reopening the panel still shows it pending. Edit, then **Reapply**
      the wallpaper, change the display arrangement or wake the Mac: the saved look returns and the
      next edit shows the draft again. Edit, then turn the switch off in Settings: the saved look
      returns. **Apply changes** still reloads the wallpaper. The lock screen and the Mission
      Control picture show the saved look throughout (open Mission Control while an edit is on
      show, and again after **Revert**, a Space change or a wake, which must not take the edit
      into the picture). With the switch on, drag a slider on a
      scene that is on a display and then a colour: the desktop follows the thumb while it is
      held, without waiting for it to stop, at a pace that does not make the panel or the
      wallpaper stutter (also with a heavy scene and two displays); letting go does not make
      the desktop jump, a drag back to the starting value returns the saved look, and
      **Revert** while holding the thumb ends the drag on the saved look. With the switch off
      the desktop does not move during a drag.
- [ ] Wallpaper position ([display position](../features/wallpaper-properties.md#display-position)):
      show a scene or video whose shape differs from the display with **Fill**, then drag
      **Horizontal position** and **Vertical position** across 0 to 100%. The visible part
      follows the thumb while it is dragged, smoothly enough to steer by, and slides on the
      display without the wallpaper restarting, once with a scene and once with a video.
      Releasing keeps it where it stopped, a drag back to where it began returns to that
      position, and the lock screen and the Mission Control picture do not change until the
      release. With **Fit** and a **Scale factor** below 1 the picture slides inside the
      bars. **Center** puts it back and is disabled while both sliders read 50%. With
      **Stretch** at a factor of 1, or a wallpaper that exactly fits, nothing moves.
- [ ] The Position sliders by keyboard and screen reader: arrow keys on a focused slider move
      it a step at a time and keep the focus, VoiceOver reads each slider's name and
      percentage and **Center**, and at the narrowest panel width the sliders, the **Center**
      link and the note do not overflow or overlap.
- [ ] Position is remembered: relaunch and it returns; the same wallpaper on another display and
      another wallpaper on the same display keep their own; the lock screen and screen saver
      (when enabled) draw it; the Mission Control picture is retaken after a move.
- [ ] With a supported clip larger than the display (an MP4 and a WebM), the Position sliders
      move the video: it stays where it was while a slider is dragged and moves when the drag
      settles; the Mission Control picture matches; **Center** puts it back; a mirror of it
      stays centred. The Position block has no note about the player, and the **Frame rate**
      row is absent on the display a plain video plays on.

## Wallpaper switching

Authorized desktop run only. Use scenes that take a few seconds to load, and watch the
desktop while applying; [wallpaper-switching.md](../features/wallpaper-switching.md)
describes what should happen and the log lines to read afterwards.

- [ ] Apply scene B while scene A plays: A stays on screen, B replaces it with a short fade,
      and the screen is never black in between. The log has `switch hold: display N frame
      captured`, `veil on scene layer` and `released ... (scene first frame)`.
- [ ] Repeat with a heavy scene (a cold shader compile or a long load): the held picture stays
      until B draws and is not stuck afterwards. With the app idle for a minute afterwards, no
      stale picture covers the wallpaper.
- [ ] Look at the moment of the swap: the held still looks like the picture it replaces
      (colour, scaling, crop, no seam at the edges), and an animated wallpaper does not jump
      noticeably.
- [ ] Switch rapidly A→B→C between scenes: each switch starts once the one before it has
      drawn, so A's picture stays until B draws and B's until C draws. The log shows a
      `frame captured` for every switch, the second one a still of B. Only when B is a web
      page or a clip that is still loading as C is chosen does the hold carry over: then
      there is no second `frame captured` and A's picture stays until C draws.
- [ ] Turn on System Settings › Accessibility › Display › Reduce motion and switch: the
      picture is replaced without a fade.
- [ ] Apply a wallpaper that fails to load (a scene with missing assets, or the forced error
      the project owner uses): the previous wallpaper keeps drawing and the log says
      `released ... (cancelled)`.
- [ ] With two displays showing different scenes, apply a saved layout and Copy or swap:
      each display keeps its own picture until its new scene draws. With a mirror set, the
      mirror shows its own held picture.
- [ ] Switch while the display is covered by a full-screen app or after display sleep: no
      pause on resume, and the log shows no `frame captured` for the suspended display.
- [ ] Switch from a paused wallpaper (Pause all): the switch takes at most about a quarter
      of a second longer; the log says whether the paused renderer delivered a still or
      `poster not delivered within 250 ms`.
- [ ] Switch a web page to another web page (a project with a different entry page): the
      previous picture stays until the new page has loaded and painted, then fades out, and
      the new page is never seen empty or black behind it. The log has `frame captured`,
      `adopted by host` and `released ... (host ready)`, half a second after the page finished
      loading. Look for a flash of an empty page as the picture goes, which would mean 500 ms
      after `didFinish` is not enough for that project's first paint, and for the system
      picture between the old page closing and the new one opening, which the host cannot
      cover.
- [ ] Switch a web page to a scene: the page's snapshot answers the request for a still (the
      log has `frame captured` and not `poster not delivered within 250 ms`), and the picture
      is released with `(scene first frame)`.
- [ ] Switch a scene to a web page, and a web page to a clip with the native backend: the
      system picture may show for the time the second host needs before its window opens (the
      project check and file staging for a page, the metadata read for a clip); the held
      picture appears with the window and goes with the page's or the clip's first frame.
- [ ] Apply a web wallpaper whose entry page is missing or fails to load: the picture goes
      at once (`released ... (host ready)` without the half-second wait) and the failed page
      and its Retry are what the display shows. Remove a display's web wallpaper while its
      page is still loading: the log says `released ... (window closed)`.
- [ ] Plain video (a clip that **In use now** lists): switch from one clip to another. The first
      clip keeps playing until the second one's window is up, which opens with the held
      picture over it and fades it out on the clip's first frame, with no black or system
      picture in between. The log has `frame captured`, `adopted by host` and `released ...
      (host ready)`. Look for a flash as the picture goes, which would mean
      `isReadyForDisplay` alone is a frame early.
- [ ] Switch from a scene to a native clip, and from a clip to a scene: the system picture may
      show for as long as the clip's metadata read takes after a scene (the engine closes the
      scene's window first); a clip to a scene behaves like any scene switch.
- [ ] Apply a VP9 WebM or an H.264 Matroska video (macOS cannot open them; the app's own WebM
      player plays them): the clip's window appears like any other native clip's, the held picture
      goes when its first frame is ready, it loops without a visible or audible seam, pause and
      volume follow the controls, and a WebM with Opus or Vorbis sound is heard. A VP8 WebM
      is refused with a message naming the format, and the display keeps the picture it had (no
      clip window); nothing else draws it.
- [ ] Apply a clip stored on a slow or sleeping external drive: the old clip keeps playing
      through the read. If the read outlasts 8 seconds the clip's window opens without a
      picture over it and the log says `no window took it`.
- [ ] Reapply wallpaper, Retry and a wallpaper update reload still empty the display first,
      as before.

## Native desktop posters and Mission Control

- [ ] Create multiple Desktops, apply a video, and immediately open Mission
      Control **without** switching Desktops.
- [ ] Apply a different scene and repeat, including rapid A→B→C changes. All
      desktop thumbnails update from the new renderer's first frame without
      waiting on a timer.
- [ ] Check the actual rendered image, not its Workshop cover, including
      Fill/Match/Stretch, scaling and flipping.
- [ ] Check different and mirrored wallpapers on connected displays,
      pause/resume, and a newly created Desktop.
- [ ] Apply a wallpaper with an intro, wait about 20 seconds and open Mission
      Control: the thumbnails show the wallpaper after its intro. Change a
      property that fades in and check again.
- [ ] Turn on **Update the Mission Control picture every 5 minutes**, wait past
      five minutes with the wallpaper visible and check that the thumbnails
      moved on; with it off they keep the last settled frame.
- [ ] With an animated wallpaper that has played for over a minute, swipe
      quickly between several Desktops and open Mission Control: every
      thumbnail shows the wallpaper as it looked once it settled, and a Desktop
      created in the middle of the swipes has a picture at once. With verbose
      logging on, keep swiping, waking the Mac and pausing and resuming playback
      for a few minutes: the log says `kept the settled poster` and no new
      `poster-*.jpg` appears in `DesktopPosters`.
- [ ] Turn off **Use the wallpaper as the macOS desktop picture** with a wallpaper
      playing: within a few seconds every Desktop shows the user's own picture in
      Mission Control and the Spaces bar, the five-minute row is disabled, and
      applying or changing wallpapers, switching Spaces and waking the Mac leave it
      alone. Turn it on again: the posters return. Quit with it off: nothing
      changes, and nothing is logged as unfinished.
- [ ] With the switch off, enable **Animate lock screen**: the switch is disabled with
      its reason. Disable the lock screen: no poster is written, and the switch can be
      changed again.
- [ ] Repair at launch: with the switch on and a wallpaper playing, quit the app abruptly
      (`kill -9`) so a poster stays installed, run
      `defaults write app.wallpapermachine WallpaperMachine.writeDesktopPicture -bool NO`
      and relaunch. Within a few seconds no Desktop shows a poster any more and the log
      says `Desktop picture: the macOS wallpaper is back`. Delete the key afterwards.
- [ ] Eject a wallpaper: all Desktops recover their previous native image and
      scaling.
- [ ] Quit and reopen to check restoration journaling.
- [ ] Start with an inherited/system wallpaper on each display, apply a live
      wallpaper, then quit. Each display restores its own original. If macOS
      cannot expose an original image, live playback works but the system
      wallpaper and Mission Control thumbnails remain unchanged.
- [ ] Change a native wallpaper outside the app and verify that quitting does
      not overwrite it.
- [ ] Set the desktop picture to an image you can delete, apply a live wallpaper,
      delete the image, then quit. The quit finishes, every Desktop shows another
      display's original or macOS's default picture, and the log names the missing
      file and what was put back instead.
- [ ] With a live wallpaper applied, log out, then restart and shut down (separate
      runs, authorized only). macOS must show no "cancelled" or "preventing logout"
      dialog. The log says `quit: reason=logout mode=powerOff` (or restart or
      shutdown) and every stage duration; if a line says `desktop restoration
      unfinished`, the next login shows the last poster until the app runs again and
      the next launch logs `previous session: quit normally (logout; desktop
      restoration unfinished)`. Also start a quit from the menu with a restoration that
      cannot finish and log out while it runs: the logout must not be cancelled.

Mission Control posters are sampled still frames, not live animation. Updates
begin as soon as a rendered frame is available, but rendering, JPEG encoding and
the system's thumbnail compositor still take time; zero-millisecond visual
latency cannot be guaranteed. How posters are taken, how originals are resolved
and restored, and which non-public APIs are involved is in
[desktop-picture.md](../features/desktop-picture.md) and, for Space mode,
[spaces.md](../features/spaces.md#poster-ownership-and-late-frames). Two
consequences matter while testing: without a recoverable original the poster
writes are skipped and a failure is logged while live playback continues, and a
journal from an older build that holds only empty originals cannot restore the
earlier wallpaper (select it again in System Settings once).

## Animated lock screen (experimental, opt-in)

- [ ] Enable Animate lock screen, then apply wallpaper A and wallpaper B without
      visiting other Spaces, and inspect every desktop thumbnail.
- [ ] Disable the feature: journaled Desktop/Idle entries are restored and
      poster synchronization resumes.
- [ ] Quit with the feature enabled: the native provider is restored before
      poster restoration is attempted. Repeat with lock-screen only, screen-saver
      only, and both enabled after a poster has already been installed.
      Every desktop returns to its original; quit waits through the native
      service reload. A restoration failure keeps the app running and reports
      the error so Exit can be retried.
- [ ] Lock and unlock the screen and confirm the provider becomes active with
      playback unpaused.
- [ ] Put the displays to sleep and wake them, then close and reopen a laptop lid, with
      the lock screen or screen saver animating: `extension.log` shows a `Re-checking
      presentation` line per event and the `Playback ... paused=` lines follow the real
      display state, including after a wake that logs no `display wake`
      ([lock-screen](../features/lock-screen.md#after-sleep-wake-lock-and-unlock)).
- [ ] Only with explicit authorization, since it changes a system election: run
      `pluginkit -e ignore -i app.wallpapermachine.wallpaper-extension`, then enable
      Animate lock screen. It stops at once, without waiting for a frame, and says macOS
      has the renderer switched off; Retry runs `pluginkit -e use`, activates, and
      `pluginkit -m -i app.wallpapermachine.wallpaper-extension` now starts with `+`.
      Clear the election afterwards with `pluginkit -e default -i
      app.wallpapermachine.wallpaper-extension`.
- [ ] Do not run this alongside a competing global wallpaper manager; a conflict
      is reported and ownership-aware restoration runs instead.

macOS refuses screenshots while locked, so the final lock-screen appearance and
smoothness cannot be captured and have to be judged by eye.

## Native video backend

Every plain video is played by the app's own players now, so apply a plain video (an MP4 for
AVFoundation, a VP9 WebM for the WebM player). The rows below are what no headless test can show about
the players on a real desktop; the tests cover the rules and the media tests the
players on synthetic clips ([coverage](coverage.md#nativevideo) lists what is not covered).
Turn on **Detailed logging** ([diagnostics](../features/diagnostics.md#levels-and-detailed-logging))
and read the log after each row. With every result, write down the macOS version and build,
the display and its refresh rate, and the container and codec of the clip: a difference between the
AVFoundation player and the WebM player on the same content is the case to report.

### Sleep, wake, lock and unlock

Whether the system really takes a playing clip's decoder away during sleep or a lock, and
whether a kick or a rebuild brings it back, is learned here. Record a diagnostic session's
counters (`nativeVideoPlaybackStalled`, `nativeVideoPlaybackKick`,
`nativeVideoPlaybackRebuild`).

- [ ] Sleep the displays only, wait a few minutes and wake them: the picture is moving
      within a few seconds. The log shows `playback advancing after the displays woke`, or
      the stalled line followed by the kick and rebuild lines.
- [ ] Sleep the Mac, wake it: the same.
- [ ] Lock the screen, wait, unlock (and switch to another user and back): the picture is
      moving after the unlock.
- [ ] Cover the desktop with a full-screen app for several minutes, or turn on Low Power
      Mode, then uncover it: the picture is moving, with the check logged after the
      resume.
- [ ] Pause the wallpaper, sleep and wake: it stays paused, and no check, kick or rebuild
      is logged for it.
- [ ] With two displays, sleep and wake: both pictures move, and each display's check is
      logged under its own wallpaper.
- [ ] Whenever a stall is logged, note whether the kick was enough, whether a rebuild was
      needed and whether the display ended up failed (the reason is in the wallpaper's state).
      A stall that ends there is the case to report.

### The menu bar and switching

Two effects are open questions for window-based video wallpapers on recent macOS builds:
the translucent menu bar keeping the tint of the first frame instead of following the
picture, and a new picture showing only after another app is clicked. Neither has been
seen in this app, and nothing in the code or the tests can show either. The native window
is opaque (`isOpaque = true` in `NativeVideoWallpaperWindow`) and nothing re-commits it
after a switch.

- [ ] Play a clip whose top edge changes between dark and bright, with Reduce transparency
      off so the menu bar is translucent. Does the menu bar's tint follow the moving
      picture, or stay on the first frame?
- [ ] Switch wallpaper from the menu bar item (**Next Wallpaper**, **Previous Wallpaper**
      or an entry under **Recently used**) without touching any other app: the new
      picture appears at once, not only after another app or window is clicked. Repeat
      from the panel's Apply, and for clip to clip, clip to scene and scene to clip.
- [ ] Press **Next Wallpaper** several times in a row over native clips: only the last
      one appears on the desktop, with no flash of the ones in between. The log says
      `superseded while its metadata was read` for any that were overtaken.
- [ ] Repeat the first two rows with the same clip as a WebM (the WebM player) and as an MP4 (AVFoundation).

A failure here does not justify making the window non-opaque (an alpha just below 1) or
forcing a re-commit of the window or layer after a switch. Each of those changes costs
something the app does not measure today and needs its own measurement first: the power
harness for WindowServer's share
([power benchmarking](power-benchmark.md#windowservers-share)) and how the system's
occlusion decisions treat a non-opaque window. The window stays opaque
until such a measurement says otherwise.

### The menu bar with two displays

Needs two displays that each show their own wallpaper. The layout and the commands are
unit-tested; how the menu draws and reads on real screens is not.

- [ ] Open the menu bar item: there is one submenu per display instead of the flat
      Previous / Next / Recently used, the main display first and the others left to
      right as the screens sit on the desk. Long display names stay readable, and
      VoiceOver reads each submenu by the display's name.
- [ ] In the second display's submenu choose **Next Wallpaper** and an entry under
      **Recently used**: only that display changes, whichever display the panel targets,
      and the entry for what it shows is ticked.
- [ ] Choose **Random Wallpaper** in each display's submenu a few times: only that display
      changes, never to the wallpaper it already shows, and after as many choices as the
      library has wallpapers each has come round once. With one wallpaper in the library the
      item is not offered. A shortcut key recorded for **Random wallpaper** in Settings →
      General does the same on the panel's target display.
- [ ] Choose **Remove from Display** on one display: it empties and the other keeps its
      wallpaper. Its submenu now offers **Start Again**; choosing it brings back the
      wallpaper that was removed. With a Rotate playlist on that display, wait past the
      interval after the removal: it stays empty until Start Again, Resume playlist or
      another wallpaper.
- [ ] Choose **Open in Control Panel** in the second display's submenu: the panel opens on
      Installed with that display as the target. Mirror the second display or disable it:
      the menu returns to the flat list.

### Scaling and posters

- [ ] With a landscape clip, set each **Scaling mode** (Fill, Fit, Stretch, Original size),
      then a **Scale factor** above and below 1, once with an MP4 and once with a WebM of the
      same picture on the same display: the picture covers the same area with the same crop and the
      same black bars. Original size shows one video pixel per point, so a 1920x1080 clip covers
      1920x1080 points of a Retina display. An anamorphic clip is the one documented
      difference ([performance](../features/performance.md#video-playback)).
- [ ] Change the mode and the factor while the clip plays: the picture moves without the
      clip restarting or going black, and the log (detailed) has a `scaling … -> …` line
      for the change.
- [ ] Set a large **Scale factor** (the panel sets no upper limit; try 4, then 8) on the
      largest display: playback stays smooth. Record the factor, the display and any
      dropped frames; the cost of a large factor is unmeasured.
- [ ] Set **Fit with blurred backdrop** for a 16:9 scene and a 16:9 clip on a display of
      another shape (an ultrawide, a MacBook panel), on Native Metal and on Compatibility:
      the picture sits where Fit puts it and the bars hold a soft, darker copy of it that
      moves with it, with no seam, block or shimmer at the picture's edges; a position
      slider moves the picture and not the copy; the lock screen, the screen saver and the
      Mission Control picture show the same. A clip the native player draws keeps black
      bars and the inspector says so. **Match with blurred backdrop** reads in full in the
      Settings › Displays menu in every language. Not seen on a display yet.
- [ ] Play a portrait clip recorded on a phone (stored rotated), and a mirrored one if
      there is one. It is upright on the desktop, and its Mission Control thumbnail and
      the picture on another Space are upright too and match the desktop, also with Fit
      and with Original size.

### Hot-plugs, mirroring and the lid

The engine reads its displays from CoreGraphics and the native video host draws on the
screens AppKit lists. Whether the two lists differ across hot-plugs, wakes, mirroring and a
closed lid has not been seen on a desktop
([display layouts](../features/display-layouts.md#mirror-sets-airplay-and-a-closed-lid)).

- [ ] Native video on an external monitor, another wallpaper on the built-in display:
      unplug and replug the monitor's cable, then put the monitor to sleep and wake it.
      Note whether the clip restarted or flashed black, and the `display refresh:` lines
      in the log: `a display missing for N ms came back; no refresh` for a blip, or
      `refreshing after N ms of a display being missing` for a monitor that stayed away.
      Record how long the display was really missing; the wait before a refresh is a fixed
      0.8 s that has not been measured against real hot-plugs.
- [ ] Turn on hardware mirroring in System Settings → Displays with a native video
      assigned to the set: record which member shows the wallpaper and whether the log
      has `is offered for display N, which this host cannot see`.
- [ ] Repeat with an AirPlay or Sidecar display, and with the lid of the built-in display
      closed on an external monitor and then reopened. For each, record whether that
      warning appeared, for which display, and how long the video took to open once the
      display was listed again.

### Slow storage and cost

- [ ] If a wallpaper's video file can be put on a spun-down external disk, a network share
      or an evicted cloud file, apply it. Either it plays once the volume
      answers, or the display is reported as failed and its state names the storage and the
      step (the metadata read or the first frame). The other displays' videos are held up
      no longer than the metadata limit (8, 30 or 60 seconds by storage). Record the
      storage, the time taken, and the `nativeVideoProbeTimeout` and
      `nativeVideoFirstFrameTimeout` counters: on the internal drive any count means a
      stall, not slowness.
- [ ] Play a 4K native clip and sleep and wake the displays: no visible hitch around the
      check after the wake. If there is one, measure it with the power harness before
      changing anything; the cost of the check's video output on a 4K clip is unmeasured.

## Audio responsiveness

- [ ] Use an authored audio-reactive scene, leave Audio response enabled, and
      grant system audio recording access.
- [ ] Play and pause music in another app and check shader, script and particle
      response.
- [ ] Verify that mute affects wallpaper playback only.
- [ ] With a scene, a video (an MP4 and a WebM with sound) and a Web wallpaper that all make
      sound, press **Mute Wallpapers** in the menu bar: every one goes silent at once while
      the pictures keep playing, the item is ticked, and Settings → Playback & Power
      shows **Mute all wallpapers** on (and the Quick Settings Mute All tile is lit). Choose it again, or use `wallpapermachine://unmute`:
      each wallpaper is audible again at the volume it had, and the wallpapers' own **Mute
      audio** switches in Settings → Displays never changed. Apply another wallpaper while
      muted: it starts silent. Add an app rule that mutes, turn **Mute all wallpapers** off
      while that app runs: the wallpapers stay silent until the rule ends. Quit and reopen
      while muted: the wallpapers start silent and the item is still ticked.
- [ ] Verify that the final disabled or removed scene stops capture.
- [ ] Verify that denied permission surfaces an error.

## App update

- [ ] Settings → About shows **Check for Updates**. The application menu item
      **Check for Updates…** opens that same section.
- [ ] A live GitHub release check, the published disk image mounting and the
      replacement of the app in Applications. Update tests use fixture JSON, a
      fake client and locally made images, so this path is manual only.
- [ ] With an update available (a build older than the latest release) and
      another app full-screen, no update alert appears and the log has
      `update prompt deferred`; leaving full screen shows the alert once, and
      opening the control panel while a display is covered shows it too.
- [ ] Opening the disk image shows one window without toolbar or sidebar: the
      app and Applications at their places over the background, labels readable,
      the volume icon. Dragging installs; the first launch is refused and opens
      from System Settings → Privacy & Security → **Open Anyway**.

## Cross-cutting

- [ ] Multiple displays, multiple Spaces and Mission Control posters,
      sleep/wake, quit and relaunch restoration, external wallpaper changes, and
      invalid→valid recovery.

Record each authorized desktop run as described in
[wallpaper-corpus.md](wallpaper-corpus.md#record-of-an-authorized-desktop-run),
and add the outcome to [verification-log.md](verification-log.md).
