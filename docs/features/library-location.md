# Library location

Settings → **Storage** → **Wallpaper library location** shows where the installed
wallpapers and the downloads are kept, and moves them to another folder, such as
one on an external drive, or back to this Mac.

## What moves and what stays

A move takes everything that grows with the library, kept together in one
*storage root* (`ClientPaths.storageURL`, `StorageLocation.movedItems`):

| Moves | Stays in `~/Library/Application Support/WallpaperMachine` |
|---|---|
| `Library/` (installed wallpapers) | settings (`config.toml`, `wallpapers/`), preferences |
| `Downloads/Workshop/` (paused and partial Workshop downloads) | `Downloads/workshop-requests.json` (the download queue's requests) |
| `Downloads/Pixiv/` (paused pixiv saves) | `SteamSession/`, `SteamCMD/`, `SceneAssets/` |
| the staging folders of downloads, pixiv saves and imports in progress | `UserAssets/` (files chosen for wallpapers), `Cache/`, logs, telemetry |

The library and its staging stay on one disk, so publishing a download or an
import is still a single exclusive rename. A Workshop download splits its private
SteamCMD folder in two: SteamCMD's home (the restored sign-in), its private copy
and its temporary files stay beside `SteamSession` on this Mac, and only the
content it fetches (`+force_install_dir`) goes to the storage root. The Steam
sign-in therefore never reaches an external drive. On a library that was not
moved both are the one folder they always were.

The choice is `StorageLocation.json` in the app-support folder (so
`WALLPAPER_MACHINE_HOME` moves it too): the path of the storage root and an id.
The storage root holds `.WallpaperMachineStorage` with the same id. A folder
without the marker, or with another library's, is not the library.

## Moving

**Move…** asks for a folder and creates `WallpaperMachine` inside it;
**Move to This Mac…** (shown while the library is elsewhere) moves it back. The
folder is checked before anything is asked or written (`StorageMoveService.plan`):

- it is outside WallpaperMachine's own folders, and has no non-empty
  `WallpaperMachine` folder already;
- it is on a local disk, writable, and its format supports exclusive renames and
  hard links (APFS and Mac OS Extended do; ExFAT, FAT and network shares do not,
  and are refused with a message that says so);
- on another disk, it has room for the library and downloads plus 5 % (at least
  512 MB) for the downloads the move is for.

The confirmation names the size and the destination. A move then has two halves:

1. **Now**, while the app keeps running: everything is copied to
   `<root>/.WallpaperMachineMove/` with a progress bar and **Cancel**
   (`StorageCopier`, `copyfile` with metadata, cancellable inside a file). On the
   same disk nothing is copied. The panel then says **Ready to move**, and
   **Cancel move** removes the copy and the folder. The app does not restart on
   its own, as with a backup restore.
2. **At the next launch**, before the backup restore and before any store,
   preference or renderer opens the library (`StorageMoveService.applyPending` in
   `WallpaperEngineApp.main`): the copy is brought up to date (a file with the same
   size and modification time is left alone, so this reads metadata only for what
   did not change), put in place with exclusive renames, and `StorageLocation.json`
   is written. That write is the commit. Only then is the old copy renamed aside
   (`.WallpaperMachineMoved-…`) and deleted in the background after launch; what a
   quit interrupts is deleted at a later launch (`.RetiredStorage.json`). On one
   disk the folders are renamed instead.

Until the commit the old library is untouched and in use, so any failure leaves
the app as it was: the copy is removed, the record of the move is dropped (a failed
move is never retried behind the user's back), and Settings → Storage shows why in
that run. A launch that stops after the commit finishes retiring the old copy at
the next launch without touching the new library.

## A drive that is not connected

When the storage root or its marker is missing at launch, the app starts without
its library rather than filling a new, empty one on this Mac: `ClientPaths`
still names the chosen folder, `ClientPaths.prepare` throws
`StorageUnavailableError`, a pending backup restore waits, and the window says
**Wallpaper Library Unavailable** with the path and that the library opens once the
drive is connected. Connecting the drive is all it takes: once it mounts with the
library's marker on it, the library opens in place with every service a launch starts
over it, the staging a crashed download or import left beside it is swept as at a
launch, and an open window shows the panel instead. A drive that finished mounting
after the launch looked for it, but before `StorageVolumeMonitor` started listening, is
found by one look once the launch is over, since its mount is not announced again. A
backup restore that waits is applied only before anything opens the library, so with
one pending the window stays and the app has to be reopened, which applies it.
Reopening always works too. **Use This Mac Instead…** (confirmed) forgets the drive and quits;
the next launch keeps the library in the app-support folder again and nothing on the
drive is deleted.

While the app runs, `StorageVolumeMonitor` follows the drive of a library kept on
another disk than the startup disk; for a library on this Mac it observes nothing.
It reads the workspace's mount notifications and ignores every volume but the one the
library is on, without reading anything for them:

- **Ejected** (`willUnmountNotification`) or **unplugged** (`didUnmountNotification`):
  every wallpaper lives in the one library on that drive, so all of them stop, as with
  a **Stop (free memory)** rule ([performance](performance.md)): the monitor is one
  more rule action for `WallpaperPresentationPolicy`. Scene runtimes, web pages, video
  players and the wallpapers kept for other desktops close with the files they hold
  open, so the eject can go ahead, and an open preview window closes. Each display
  keeps its assignment, playlists and rules wait as they do while wallpapers are
  stopped, and the desktop shows its desktop picture
  ([desktop picture](desktop-picture.md)). A warning row in the panel's banner
  names the library's folder until the wallpapers play again. The stop starts when
  macOS announces the eject and finishes a moment later, so a video wallpaper can
  still hold its file when the first attempt is made: ejecting again within 20
  seconds then works.
- **An eject that did not happen**: when another app keeps the drive busy, or the
  eject is cancelled, nothing more is announced; 20 seconds after the announcement,
  if the library is still there, its wallpapers play again. Ejecting again within the
  20 seconds counts them from that attempt; once they have passed the wallpapers are
  playing again, so the next eject meets the same race as the first.
- **Connected again** (`didMountNotification`) with this library's marker: the
  library is rescanned first, then the stop is lifted and each display loads what it
  was assigned. Another drive mounted under the same name, or one with another
  library's marker, changes nothing.

A drive renamed while the library is on it is not followed to its new name: the
library is then missing at the next launch, as above.

## Backups

A backup reads `Library/` from the storage root and a restore writes it there
(`WallpaperBackupService.storageRoot`). A restore keeps the `old/` and `ready/`
copies of library units in a `.BackupRestoreTransaction` folder beside the library,
so putting them in place and putting them back stay renames on that disk; its
journal names that folder and its marker (`libraryRoot`, `libraryMarker`), and a
restore that stopped part-way is put right from there. It waits, keeping the journal
and deleting nothing, while the drive is missing, while only an empty mount point
with no marker is there, or while a replaced wallpaper's set-aside copy cannot be
found. A library move is refused, at
**Move…** and again at launch, while such a restore is still to be put right. The storage root is recorded as one of the
package's source roots, so a property that names a file inside a wallpaper's own
folder is remapped to the library's place on the Mac it is restored to.

## Tests

`StorageMoveServiceTests` (copied and same-disk moves, moving back, a missing or
different drive at launch, refused folders, cancelling, a copy cut short, a launch
that stopped after the commit), `StorageCopierTests`, `StorageLocationTests`,
`DownloaderStorageTests` (SteamCMD's home beside the sign-in, content on the
library's disk), `WallpaperBackupTests.testMovedLibraryIsBackedUpFromAndRestoredToWhereItIsKept`
and the move actions and the drive's banner row in `PanelStorageActionsTests`.
`StorageVolumeMonitorTests` cover the drive while the app runs: an eject stops the
wallpapers through the real presentation policy and connecting the drive plays them
after a rescan, an unplug, an eject that did not happen, other volumes and a drive
with another library change what they should, a library missing at launch opens once
its drive is connected, and a pending backup restore keeps waiting. No test uses a
real external drive: a fake `StorageVolumeInspecting` stands in for another disk, and
the monitor's drive is a folder its notifications name.
