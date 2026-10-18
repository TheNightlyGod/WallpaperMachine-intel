# First-run guide and one-time prompts

One-time offers on a Mac that has not seen them: the welcome guide that covers the
first window, a single request to star or support the project after the first
downloaded wallpaper is applied, a later request for a GitHub star, one question
about [performance data](telemetry.md) for someone who finished the guide before it
had that switch, and one offer to import the Steam subscriptions for someone signed in
to Steam who has not met that import. Each is shown once and remembered in the app's defaults. The panel
they appear in is described in [control panel](control-panel.md).

## First run

The first time the panel opens, a guide covers the window's content: a dimmed scrim over
the page and the Now Playing bar, with a card in the middle, 640 points wide and up to 700 tall,
that shrinks with the window and keeps a 24-point margin
(`App/Views/ControlPanel/Welcome/`; `WelcomeOverlayHost` over the window's content). While it is
open the rest of the panel is disabled and hidden from VoiceOver. It is a page, not a modal
dialog: `Escape` and a click outside do nothing, and the download dialog can still open
over it for an unrelated job. Nothing in it animates on its own except a spinner while
Steam works, and Reduce Motion removes its fades. The card's page scrolls on its own
under the step indicator and above a pinned footer, so the buttons stay reachable at the
760×560 minimum. The indicator is a row of six dots joined by a line (a check for a page
done, a ring for the current one, an exclamation mark for one that needs attention) with
the current step's name under it; each dot opens its page, except while language,
appearance, the lock screen, performance or preferences are being committed. Later pages
have **Back**, and decision pages have **Skip**:

1. **Language & appearance.** The page leads with the image of the chosen Dock app
   icon ([appearance](appearance.md#app-icon)). Radio tiles for the language
   (**System (Auto)** plus every shipped language under its own name) and the
   appearance mode (**System (Auto)**, **Light**, **Dark**, each with a drawn
   miniature); the arrow keys move between them as in a radio group. A choice applies
   at once through the same setters as Settings, so the guide redraws in the chosen
   language and theme. **Skip** puts back whatever was in force when the guide opened
   and moves on.
2. **Steam.** Explains that browsing is free and that downloading needs a Steam
   account that owns Wallpaper Engine, with **Create a Steam account**
   (`store.steampowered.com/join/`) and **Buy Wallpaper Engine** beside that
   explanation. The form takes the account name (login name, not profile name),
   the password (with a show/hide button) and **Keep me signed in on this Mac** (on
   by default). **Sign in** checks the form and then sends only the account name and
   the remember choice; the form hands the password to the guide's model, which holds
   it until Steam's own password prompt arrives on the sign-in job, answers that
   prompt exactly once whatever page is on show, and keeps no copy. Skipping, closing
   the guide or closing the window drops it. Without SteamCMD the button reads
   **Install SteamCMD and sign in** and the guide installs it first (with the
   Gatekeeper approval and locate-a-copy paths when they apply). Steam Guard is
   explained with the same steps as the download dialog; **Cancel** stops the
   session. After sign-in the guide checks Wallpaper Engine ownership and shows
   **Signed in as …** with the result and **Use a different account**, which asks
   before signing out. Non-owners see **Buy Wallpaper Engine** and an explanation
   that pixiv downloads, Workshop browsing and viewing existing wallpapers remain
   available; an inconclusive result is labeled unconfirmed. Both offer **Check
   ownership again** and allow **Continue**, and saved accounts from an earlier run
   can also be checked. Signed in, unless the account is known not to own Wallpaper
   Engine, the page also offers **Import my subscriptions**: the Workshop wallpapers
   the account already subscribes to on Steam, downloaded into the library. Steam lists
   them only behind its Steam Community sign-in, a different one from SteamCMD's, so a
   first import opens Steam's own sign-in window ([Subscriptions](workshop-downloads.md#subscriptions));
   that sign-in stays on this Mac. What the library lacks is queued in Downloads, behind
   the guide, and the card then says how many, or that the library already has them all. **Skip for now** (or **Skip and cancel sign-in** while a job
   or setup request is pending) leaves Steam for the first download to ask about. A
   Steam Guard request arriving on another page marks the Steam step as needing
   attention without changing pages, and keyboard focus goes to the field Steam asks
   about when the page shows it. See [Steam sign-in](workshop-downloads.md#steam-sign-in)
   for the session itself.
3. **Performance.** Radio tiles for the **Low**, **Medium** and **High** quality
   presets (the same pairs as [Settings → Performance](performance.md#quality)),
   then the **Frame rate limit** slider, whose top reads **No limit** (see
   [Default per-display frame rate](performance.md#default-per-display-frame-rate)).
   High, no limit at full render scale, is selected on a fresh install. A preset
   fills both drafts; moving the slider changes only the limit, and a pair matching
   no preset leaves every tile unchecked with a **Custom** note. They are drafts:
   **Continue** sends only what changed (the render scale, then the frame-rate
   limit), **Skip** discards them.
4. **Preferences.** Launch at login, Keep windows in place when clicking the
   wallpaper and [Send performance data](telemetry.md) (off) are switches; the last
   is disabled in a run without the telemetry service. **On battery** is a menu: Keep running, Reduced quality
   or Pause. They are drafts: **Continue** commits only the ones that changed, in
   order, and stops at the first refusal; **Skip** discards them. Launch at
   login is disabled with its reason while the app is outside Applications. When the
   user has switched the app off in System Settings → General → Login Items, the row
   keeps its switch and adds a note to allow it there; Settings → General also offers a
   button that opens Login Items.
   Started at login, the app stays in the menu bar without opening the panel,
   unless this guide is unfinished or the renderer failed to start
   (`ControlPanelLaunch`).
   The last row, **Animate lock screen** (off by default, marked experimental), is
   not a draft: like Settings it changes the lock screen at once, shows the native
   status while busy (**Updating…** while the guide's own request is on its way), is
   disabled when the integration is unavailable, and a refusal leaves the switch off
   with the reason on the page and commits no draft. **Skip** puts it back to the
   value it had when the guide opened. During a preference or lock-screen commit,
   Back, step navigation, Skip and Continue are all disabled so the guide cannot leave
   a partially submitted operation.
5. **Tips.** Three one-line tips (browsing **Steam Workshop**, download then double-click to
   apply, one wallpaper per display), then a compatibility card: not every wallpaper
   works (videos usually play, scenes are experimental, Application wallpapers cannot
   run), failures are reported with the inspector's report button, and pull
   requests are welcome, with **Report an issue** and **Contribute on GitHub**
   links.
6. **Start.** A recap of language, appearance and the actual Steam sign-in state.
   Pending jobs or setup requests offer **Finish sign-in**. Unsaved performance or
   preference drafts each add a row with their count and **Review**, which returns
   to that page without discarding them; closing does not auto-save the drafts.
   **Browse the Workshop** ends the guide and opens **Steam Workshop** (its note points
   to Browse → Steam Workshop in the sidebar), **Import wallpapers**
   ends it, shows Installed and opens the import picker, and **Start using the app**
   simply closes it. A note says the guide can be opened again from Settings →
   General.

Leaving the guide by any of the closing actions stores the flag in the app's defaults
(`WallpaperMachine.welcomeSeen`, `PanelPreferences.welcomeSeenKey`), so the guide is shown
on its own exactly once per Mac; a window closed and reopened before then starts the guide
again from the first page and keeps what was already applied.
**Settings → General → Help → Welcome guide → Show again** brings it back from the
first page; closing it then does not touch the stored flag. Every link passes the
same external-link allowlist as every other link in the panel. While the guide is
open the download dialog does not surface the sign-in job's prompts (the guide answers
them). A finished sign-in-only job is not listed as a download. The guide's texts can
be selected and copied.

## First wallpaper support prompt

After a wallpaper downloaded through Steam Workshop or pixiv is successfully applied by
the user, the panel offers **Feeling good?** once, in a sheet on the panel window.
**Star on GitHub** opens the project repository; **Become a Supporter** opens the
website's pricing page (the Chinese page for either Chinese app language). Both
require a click. **Not now** and Escape dismiss the offer. A link that fails to open
says so and leaves both choices available (`SupportPromptPresenter`).

The download must have finished installing, and applying must have succeeded and
reported a new active display assignment. Downloads alone, local imports, failed
applies, startup restoration, playlist changes, automatic update reloads and
reapplying an already active wallpaper do not qualify. **Apply changes** also
qualifies when it first enables the downloaded wallpaper on a display, and so does
[Download and apply](workshop-downloads.md#download-and-apply) once its wallpaper
has arrived, because it applies as the user's own choice.

Eligibility survives quitting between download and apply. If the panel is hidden,
the [welcome guide](#first-run) or sign-in is open, the download dialog or one of the
panel's popovers is open, or a wallpaper switch is running or waiting, the offer waits; **Hide window after applying a
wallpaper** (see [Selection versus apply](control-panel.md#selection-versus-apply))
defers hiding for this first offer. Only a displayed offer consumes the one-time
flag; after that it never returns automatically, including after quitting or
updating. Opening a link neither stars the repository nor makes a payment; the user
finishes that action in their browser. See [Supporter details](../../SPONSORS.md).

## Star prompt, the performance data question and the subscriptions offer

`SupportPromptStore` schedules all four prompts and `PanelController.pendingPrompt`
names at most one; `SupportPromptPresenter` shows it in the same sheet with the same
waiting rules as above (`SupportPromptSheet`). When several are due, the order is the
performance data question, then the subscriptions offer, then the support prompt, then
the star prompt, and no
prompt appears on the same calendar day as another. Once one has been answered or
dismissed, no other appears in that window.

- **Send performance data?** asks once someone who finished the welcome guide before
  it had the switch. **Send performance data** turns it on and opens nothing; **What is
  sent** opens [telemetry.md](telemetry.md) on GitHub without closing the sheet.
  Reaching the guide's Preferences page, or choosing in Settings, counts as having been
  asked; someone who leaves the guide before that page is asked once afterwards. A run
  without the telemetry service never asks.
- **Import your Steam subscriptions?** offers once the guide's **Import my
  subscriptions** to someone who finished the guide and has a saved SteamCMD sign-in
  but never signed in to Steam Community in a build that has the import: an existing
  user after the update, or someone who skipped the guide's Steam page and signed in
  at a first download. The guide's card appearing, or a Steam Community sign-in from
  anywhere (**Your subscriptions** included), counts as having met it. Choosing it
  spends the offer, closes the sheet and goes on: Steam's sign-in window, then the
  downloads, whose failure, or finding nothing missing, reaches the banner.
- **Like WallpaperMachine?** asks once for a GitHub star from someone who did not
  choose **Star on GitHub** in the support prompt or in Settings → About. It waits
  until 14 days after the first day the panel was on screen with a build that counts
  it, and until the panel has been on screen on at least 5 different days. For an
  existing user the 14 days start at the update. Someone who never downloads a
  wallpaper, and so never sees the support prompt, gets it too.

Settings → About also has **Share WallpaperMachine…**, the system share menu with the
website's home page (the Chinese page for either Chinese app language), and **Star on
GitHub**. A Workshop wallpaper's details offer **Share…**; see
[control panel](control-panel.md#sharing-a-wallpaper).
