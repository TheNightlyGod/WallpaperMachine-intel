# User-selected files and folders

A wallpaper project can declare `file` and `directory` properties, the Wallpaper
Engine property types for a picture, a clip or a folder of them that the user
picks from anywhere on disk. The app does not hand a page the user's own path. It
keeps its own copy of each pick and, for a web wallpaper, stages that copy where
WebKit lets the page read it. This document covers that storage, the value a page
receives, how the copy is kept current and cleaned up, and the inspector control.
The page-side contract (`applyUserProperties`, the `fetchall` callbacks and
`wallpaperRequestRandomFileForProperty`) is in
[web-wallpapers.md](web-wallpapers.md#host-protocol).

Who uses it:

- **Web wallpapers** are the only importers. `WebWallpaperHost` on the desktop and
  the web surface of the [live preview](wallpaper-properties.md#live-preview)
  (`WebWallpaperPreviewSurface`) run each chosen file or folder through
  `UserAssetStore`; nothing else calls the importer. For any other project type
  that declares such a property the engine stores the picked path verbatim and the
  app copies nothing, which the inspector reports as *Used in place*.
- **The inspector** offers the same *Choose…* and *Clear* controls for every
  project that declares the properties, and reads the store's manifest through the
  bridge, read-only, to say whether the app holds a copy and whether the original
  can still be found ([below](#in-the-inspector)).
- **The lock screen and screen saver** cannot read the store, so the assets they
  reference are republished for the sandboxed extension
  ([below](#lock-screen-and-screen-saver)).
- **Property presets** keep their own copy of each managed attachment under
  `UserAssets/PresetAssets/`, independent of the current property
  ([property presets](wallpaper-properties.md#property-presets)), and **local backups**
  include `UserAssets/` ([backup and restore](backup-restore.md)).
- **Settings → Storage** and `scripts/clean.py` show, purge and delete the store
  ([below](#lifetime-and-cleanup)).

## Why the app keeps a copy

A `WKWebView` only grants `file://` reads below the root passed to
`loadFileURL(_:allowingReadAccessTo:)`, and that root has to be an ancestor of the
entry page, so a page can never read outside its own project folder; widening the
root to a common ancestor would hand every wallpaper the whole application-support
tree. A symlink placed inside the root is resolved by WebKit and refused, a hard link
is not. Those two measured facts fix the design: a canonical copy the app owns, and a
derived link inside the project that exists only to satisfy WebKit.

## How the copy is stored

- **Managed store.** `App/Services/UserAssets/ManagedUserAssetStore.swift` holds the
  app's own copy of each chosen file under
  `~/Library/Application Support/WallpaperMachine/UserAssets/` (`WALLPAPER_MACHINE_HOME`
  relocates it), laid out as `<stableWallpaperId>/<propertyId>/<assetId>/<fileName>`
  with a `manifest.json` per wallpaper. The manifest, not the wallpaper package, is
  the system of record: asset id, the user's original path, size, modification time,
  a SHA-256 content digest, and whether the import was a file or a folder. Keying on
  the stable wallpaper id rather than the display name or entry file name lets an
  import survive a Workshop update or a delete-and-re-download. Import clones the
  file with `clonefile` where the filesystem supports it and copies otherwise; the
  user's original is never moved, renamed or written to. The modification time is
  kept in full precision (`modifiedReferenceTime`) so an unchanged selection can skip
  hashing after relaunch.
- **Derived bridge.** `App/Services/UserAssets/UserAssetStore.swift` keeps a bridge at
  `<project>/.mwe-user-assets/<propertyId>/`, a hard link onto the store's copy when
  the project shares its volume and a byte copy when it does not. It exists only
  because of the WebKit read-access rule and holds nothing of its own: deleting all of
  it loses nothing, because the next import rebuilds it from the manifest. Data flows
  store → bridge only, and the dot directory is the only thing created inside the
  project. A bridge written by this app carries a hidden `.managed-by` marker naming
  its wallpaper. A bridge without one, left by an older build, is absorbed into the
  store once and only when the property's original no longer resolves; nothing in the
  old location is deleted, the manifest records the migration, and a failed copy
  leaves the old entry loading as before.
- **Missing originals.** An asset whose original path no longer resolves but which is
  still in the store stays usable, served from the store. One that is in neither place
  is reported as missing (`assetMissing` on the property descriptor), never silently
  cleared.
- **Value handed to the page.** The staged absolute path with its leading `/`
  removed and `%`, `#` and `?` percent-escaped, so the page's `'file:///' + value`
  resolves. Spaces, non-ASCII, `+`, `&` and `'` stay literal, because a page that
  treats the value as a plain path must still see them.
- **Accepted files.** Only image (`jpeg jpg png pnga bmp gif svg webp`) and video
  (`webm ogg ogv`) extensions are staged, case-insensitively; a property that
  declares no file type accepts the union of the two, never an arbitrary file. A
  folder is read one level deep and capped at
  `UserAssetStore.defaultDirectoryFileLimit` (4096) entries; hitting the cap is
  reported rather than silently dropping files.
- **Watching.** A `fetchall` folder is watched with FSEvents, never polled. A burst
  of changes is debounced into one added/removed diff, which re-stages added or
  rewritten files, drops the links for removed ones, and reaches the page as
  `userDirectoryFilesAddedOrChanged` / `userDirectoryFilesRemoved`. An unavailable
  directory, an unreadable matching file or a failed manifest write preserves the
  last committed list and bytes; pruning happens only after the new manifest is
  durable.
- **Concurrency.** `UserAssetWorker` enumerates, hashes, copies and publishes bridges
  off the main actor. A newer selection cancels the previous preparation, and one
  asynchronous turn per managed root and wallpaper serializes preparation,
  publication, permission changes and purge across store instances, so a stale
  preparation cannot overwrite a newer selection. Copies publish from private
  temporary files, so cancellation never deletes another import's copy.

## Lifetime and cleanup

The store outlives the project, the bridge outlives the process, the in-memory index
does not. `WebWallpaperHost` re-imports on next use (which rebuilds a missing bridge)
and discards the store handle for a project nothing displays any more. Changing the
pick replaces that property's assets in both places; clearing a property removes them
from both.

`python3 scripts/clean.py --user-assets` removes every `.mwe-user-assets` bridge in
the imported library and the Steam workshop folder, which the app rebuilds on next
load. `--managed-user-assets` is the destructive one: it deletes the app's own
copies, which nothing regenerates. Neither the default pass nor `--all` nor
`--derived` reaches either of them.

In **Settings → Storage**, *Wallpaper files you chose* shows the managed directory,
reveals it in Finder, and **Clear unused caches…** reclaims only stored bytes no
manifest still lists: an orphaned `assetId` folder, a property the manifest no
longer mentions, a wallpaper folder with no manifest. A referenced asset is never a
purge candidate, which matters most for the property whose original has gone and
whose stored copy is now the only one; the preset attachments retained under
`PresetAssets` are never candidates either. A missing manifest is distinct from an
unreadable, damaged, foreign or unsupported manifest; the latter blocks purging or
replacing that wallpaper's files, is logged and skipped, and the purge continues
with the others.

## Lock screen and screen saver

The sandboxed extension (`Extension/WallpaperExtension.entitlements`) cannot read the
store or the bridge. For a committed **video or scene** wallpaper, the assets it
actually references are republished into the lock-screen exchange directory as their
own `revisions/<fingerprint>/` tree and the property values are rewritten to point at
that copy; the fingerprint covers the recorded content digests, so an unchanged
selection is not copied again, and revisions the published configuration no longer
names are collected after each successful publish. Web projects get a separate
read-grant root holding only their referenced managed files; see
[lock-screen.md](lock-screen.md#storage).

## In the inspector

A `file` property shows a read-only field with the chosen file's own name (never the
staged path the page reads), a *Choose…* button, a *Clear* button, and the extensions
the property accepts, taken from its `fileFilter`. An absent filter means the author
declared no file-type option, which the protocol defines as both kinds it knows, so
both lists are offered.

A `directory` property adds how many files in the chosen folder the importer would
take, whether the folder holds more than the import limit, and what the wallpaper does
with them: a `fetchall` folder is handed to the page whole, an `ondemand` folder is
one the page picks from itself. The count is the panel's own measurement of the
chosen folder, applying the importer's screens (first level, accepted extensions, no
hidden entries, regular files only, readable only), and is kept until the chosen path
changes. It describes the folder, never the outcome of an import the panel cannot
observe: a single entry whose link and copy both fail is skipped and logged by the
importer. A folder that cannot be read is reported as unreadable rather than empty.

Both also say where the choice lives. A managed pick is noted as copied into the
app's managed folder, so it survives cache cleans and wallpaper updates; a pick that
was never imported is noted as used in place from its original path, and moving or
deleting it there breaks the wallpaper. A pick that resolves in neither place gets a
visible alert and *Reselect…* in place of *Choose…*.

Both persist through `setPropertyPath`; *Clear* sends `nil` and the engine writes the
property's own default back. A choice the app cannot honour (a wallpaper folder that
is missing or read-only, so nothing can be staged inside it) is reported beside that
control rather than in the window-wide banner, and the path is not sent. `texture` and
`scenetexture` properties are a separate kind: they keep the scene texture picker and
are refused by the path editor.

## Verification

The store, bridge, watcher and purge are covered by `Tests/Unit/UserAssets/`
(`UserAssetStoreTests`, `DirectoryWatcherTests`,
`UserAssetPreparationPerformanceTests`), the page payload and staging by
`WebWallpaperPropertyPayloadTests`, the inspector side by `PanelPropertyFilesTests`,
`PanelPropertyRowsTests` and `InspectorFlowTests` in `Tests/Unit/Panel/`, the bridge contract by
`Renderer/Bridge/src/tests/file_properties.rs`, and the lock-screen
republication by `LockScreenWallpaperServiceTests`; the inventory is under
[UserAssets](../testing/coverage.md#userassets). No test drives the real open panel,
so choosing a file through it and a page reading the staged file in a desktop window
need an authorized manual run.
