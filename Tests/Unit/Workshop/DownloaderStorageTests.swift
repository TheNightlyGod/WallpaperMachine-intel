import XCTest

@testable import WallpaperMachine

/// A library moved to another disk: SteamCMD, its home and the sign-in it restores stay beside the
/// saved sign-in, and only what it fetches goes to the library's disk.
@MainActor
final class DownloaderStorageTests: DownloaderTestCase {
  func testDownloadToALibraryOnAnotherDiskKeepsSteamCMDsHomeBesideTheSignIn() async throws {
    let root = try makeRuntime(
      """
      set -eu
      install=''
      item=''
      while [ "$#" -gt 0 ]; do
          case "$1" in
              +force_install_dir) shift; install="$1" ;;
              +workshop_download_item) shift; shift; item="$1" ;;
          esac
          shift
      done
      printf '%s\\n%s\\n' "$(pwd -P)" "$(cd "$install" && pwd -P)" > ../paths.txt
      mkdir -p config
      printf 'token' > config/config.vdf
      content="$install/steamapps/workshop/content/431960/$item"
      mkdir -p "$content"
      printf '{"type":"video","file":"movie.mp4"}' > "$content/project.json"
      printf 'movie' > "$content/movie.mp4"
      printf 'Waiting for user info...OK\\nDownloading item %s ...\\nSuccess. Downloaded item %s\\n' "$item" "$item"
      """)
    defer { try? FileManager.default.removeItem(at: root) }
    let drive = root.appendingPathComponent("Drive", isDirectory: true)
    try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)

    let downloader = startDownload(in: root, libraryName: "Drive/Library", rememberSession: false)
    try await assertImported(downloader, in: root, itemID: "123456", libraryName: "Drive/Library")

    let paths = try String(contentsOf: root.appendingPathComponent("paths.txt"), encoding: .utf8)
      .split(separator: "\n").map(String.init)
    let home = try XCTUnwrap(paths.first)
    let install = try XCTUnwrap(paths.last)
    // The shell names `/private/var`, Foundation `/var`: both are read back the same way.
    func parent(_ path: String) -> String {
      URL(fileURLWithPath: path).deletingLastPathComponent().resolvingSymlinksInPath().path
    }
    XCTAssertEqual(parent(home), root.resolvingSymlinksInPath().path,
                   "SteamCMD's home, with the sign-in, is beside the saved sign-in")
    XCTAssertEqual(parent(install), drive.resolvingSymlinksInPath().path,
                   "what it fetches is on the library's disk")
    try assertNoStaging(in: root)
    try assertNoStaging(in: drive)
  }
}
