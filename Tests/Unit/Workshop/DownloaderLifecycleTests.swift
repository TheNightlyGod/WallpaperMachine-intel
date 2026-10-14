import Darwin
import XCTest

@testable import WallpaperMachine

/// Single-download lifecycle: staging, prompts, progress, scene assets and failure paths.
@MainActor
final class DownloaderLifecycleTests: DownloaderTestCase {
  func testAnonymousAccountCannotStartDownload() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "mwe-invalid-account-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let downloader = WorkshopDownloader(
      sessionDirectory: root.appendingPathComponent("SteamSession"))
    downloader.start(
      item: item, username: "anonymous", executable: root.appendingPathComponent("missing"),
      library: root.appendingPathComponent("Library"), onImported: {})
    XCTAssertFalse(downloader.isRunning)
    XCTAssertNotNil(downloader.errorMessage)
    XCTAssertNil(downloader.downloadedID)
  }

    func testStagingSweepOnlyReclaimsDirectoriesNothingIsWorkingIn() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("mwe-staging-sweep-\(UUID().uuidString)")
        defer { try? files.removeItem(at: root) }
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        // SteamCMD writes deep inside staging, which never moves the directory's own timestamp.
        func age(_ url: URL, to date: Date) throws {
            var paths = [url.path]
            if let walker = files.enumerator(at: url, includingPropertiesForKeys: nil) {
                for case let child as URL in walker { paths.append(child.path) }
            }
            for path in paths {
                try files.setAttributes([.modificationDate: date], ofItemAtPath: path)
            }
        }
        func staging(_ name: String, stillWriting: Bool) throws -> URL {
            let url = root.appendingPathComponent(WorkshopDownloader.stagingPrefix + name, isDirectory: true)
            let content = url.appendingPathComponent("steamapps/workshop/content/431960", isDirectory: true)
            try files.createDirectory(at: content, withIntermediateDirectories: true)
            let item = content.appendingPathComponent("item")
            try Data("payload".utf8).write(to: item)
            try age(url, to: Date(timeIntervalSinceNow: -3600))
            if stillWriting {
                try files.setAttributes([.modificationDate: Date()], ofItemAtPath: item.path)
            }
            return url
        }

        let abandoned = try staging("abandoned", stillWriting: false)
        let claimed = try staging("claimed", stillWriting: false)
        let occupied = try staging("occupied", stillWriting: false)
        let writing = try staging("writing", stillWriting: true)
        let unrelated = root.appendingPathComponent("SteamSession", isDirectory: true)
        try files.createDirectory(at: unrelated, withIntermediateDirectories: false)

        // A live app holds its claim open for the whole download.
        let claim = open(claimed.appendingPathComponent("owner").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        XCTAssertGreaterThanOrEqual(claim, 0)
        defer { close(claim) }
        XCTAssertEqual(flock(claim, LOCK_EX | LOCK_NB), 0)

        // A crash leaves SteamCMD writing with the app that started it gone. SteamCMD inherits the
        // claim, so handing the locked descriptor to a child and dropping this process's own copy
        // is what an orphaned download looks like from a later launch.
        let inherited = open(occupied.appendingPathComponent("owner").path, O_CREAT | O_RDWR, 0o600)
        XCTAssertGreaterThanOrEqual(inherited, 0)
        XCTAssertEqual(flock(inherited, LOCK_EX | LOCK_NB), 0)
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        child.arguments = ["-c", "sleep 30"]
        child.standardInput = FileHandle(fileDescriptor: inherited, closeOnDealloc: false)
        try child.run()
        close(inherited)
        defer { child.terminate() }

        WorkshopDownloader.removeAbandonedStaging(in: root, quietFor: 60)

        XCTAssertFalse(files.fileExists(atPath: abandoned.path), "Nothing holds or writes here; it must be reclaimed")
        XCTAssertTrue(files.fileExists(atPath: claimed.path), "A held claim must survive")
        XCTAssertTrue(files.fileExists(atPath: occupied.path), "A claim inherited by a surviving child must survive")
        XCTAssertTrue(files.fileExists(atPath: writing.path), "A stale directory timestamp must not condemn a live download")
        XCTAssertTrue(files.fileExists(atPath: unrelated.path), "Only staging directories are swept")
    }

    func testStagingSweepKeepsWhatItCannotInspect() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("mwe-staging-faults-\(UUID().uuidString)")
        defer { try? files.removeItem(at: root) }
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        func staging(_ name: String) throws -> URL {
            let url = root.appendingPathComponent(WorkshopDownloader.stagingPrefix + name, isDirectory: true)
            try files.createDirectory(at: url.appendingPathComponent("steamapps"), withIntermediateDirectories: true)
            try Data("payload".utf8).write(to: url.appendingPathComponent("steamapps/item"))
            var paths = [url.path]
            if let walker = files.enumerator(at: url, includingPropertiesForKeys: nil) {
                for case let child as URL in walker { paths.append(child.path) }
            }
            for path in paths {
                try files.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: path)
            }
            return url
        }

        // Otherwise reclaimable: quiet, unclaimed, and nothing working inside it.
        let unreadableTree = try staging("unreadable-tree")
        let locked = unreadableTree.appendingPathComponent("steamapps/locked", isDirectory: true)
        try files.createDirectory(at: locked, withIntermediateDirectories: false)
        try files.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer { try? files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }

        let unreadableClaim = try staging("unreadable-claim")
        let owner = unreadableClaim.appendingPathComponent("owner")
        try Data().write(to: owner)
        try files.setAttributes([.posixPermissions: 0], ofItemAtPath: owner.path)
        defer { try? files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: owner.path) }

        let quiet = try staging("quiet")
        WorkshopDownloader.removeAbandonedStaging(in: root, quietFor: 60)
        XCTAssertTrue(files.fileExists(atPath: unreadableTree.path), "A tree that cannot be walked is not known to be idle")
        XCTAssertTrue(files.fileExists(atPath: unreadableClaim.path), "A claim that cannot be read is not known to be released")
        XCTAssertFalse(files.fileExists(atPath: quiet.path), "A fully inspected idle directory is still reclaimed")
    }

    func testSteamCMDInheritsTheStagingClaim() async throws {
        // A crash leaves this child writing on its own; the claim it inherits is what tells a later
        // launch the staging is still in use.
        let root = try makeRuntime("""
            [ -e /dev/fd/3 ] && printf inherited > ../claim-visible
            IFS= read -r finish
            """)
        defer { try? FileManager.default.removeItem(at: root) }
        let downloader = startDownload(in: root)
        let marker = root.appendingPathComponent("claim-visible")
        do {
            try await waitUntil { FileManager.default.fileExists(atPath: marker.path) }
            XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "inherited")
        } catch {
            await downloader.shutdown()
            throw error
        }
        await downloader.shutdown()
    }

  func testImmediateShutdownWaitsForStagingCleanup() async throws {
    let root = try makeRuntime("IFS= read -r finish")
    defer { try? FileManager.default.removeItem(at: root) }
    let downloader = WorkshopDownloader(
      sessionDirectory: root.appendingPathComponent("SteamSession"),
      runtimeProvider: ShellRuntimeProvider())
    downloader.start(
      item: item, username: "localcanceltest",
      executable: root.appendingPathComponent("runtime/steamcmd"),
      library: root.appendingPathComponent("Library"), onImported: {})
    await downloader.shutdown()
    XCTAssertFalse(downloader.isRunning)
    XCTAssertTrue(downloader.wasCancelled)
    XCTAssertNil(downloader.downloadedID)
    let children = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
    XCTAssertFalse(children.contains { $0.hasPrefix(".WallpaperMachine-workshop-") })
  }

  func testShortSplitPromptsAllowPasswordAndGuardCodeBeforeDownload() async throws {
    let root = try makeRuntime(
      """
      printf 'Steam Console Client\\npass'
      sleep 0.1
      printf 'word: '
      IFS= read -r password
      [ "$password" = 'local-password' ] || exit 10
      printf '\\nLogging in using username/password.\\nSteam Guard co'
      sleep 0.1
      printf 'de: '
      IFS= read -r code
      [ "$code" = '12345' ] || exit 11
      printf '\\nWaiting for user info...OK\\nDownloading item 123456 ...\\n'
      mkdir -p steamapps/workshop/content/431960/123456
      printf '{"title":"Terminal fixture","type":"video","file":"movie.mp4"}' > steamapps/workshop/content/431960/123456/project.json
      printf 'downloaded-content' > steamapps/workshop/content/431960/123456/movie.mp4
      printf 'Success. Downloaded item 123456\\n'
      """)
    defer { try? FileManager.default.removeItem(at: root) }
    let downloader = startDownload(in: root)
    do {
      try await waitUntil { downloader.prompt == .password }
      downloader.submitSecret("local-password")
      try await waitUntil { downloader.prompt == .guardCode }
      downloader.submitSecret("12345")
      try await waitUntil { !downloader.isRunning }
      XCTAssertNil(downloader.errorMessage)
      XCTAssertEqual(downloader.downloadedID, item.id)
      XCTAssertEqual(
        try String(
          contentsOf: root.appendingPathComponent("Library/123456/movie.mp4"), encoding: .utf8),
        "downloaded-content")
    } catch {
      await downloader.shutdown()
      throw error
    }
  }

  /// A sign-in-only session checks the license without downloading, answers Steam's own
  /// prompts, saves the accepted sign-in for later downloads, and leaves nothing behind.
  func testSignInOnlySessionSavesTheSignInAndDownloadsNothing() async throws {
    let root = try makeRuntime(
      """
      for argument in "$@"; do
        case "$argument" in +workshop_download_item|+app_update) exit 70 ;; esac
      done
      printf '%s\\n' "$*" > ../arguments.txt
      printf 'password: '
      IFS= read -r password
      [ "$password" = 'local-password' ] || exit 71
      printf '\\nLogging in user localtest to Steam Public...OK\\nWaiting for user info...OK\\n'
      mkdir -p config
      printf 'token:localtest' > config/config.vdf
      chmod 644 config/config.vdf
      """)
    defer { try? FileManager.default.removeItem(at: root) }
    let downloader = WorkshopDownloader(
      sessionDirectory: root.appendingPathComponent("SteamSession"),
      runtimeProvider: ShellRuntimeProvider(), networkMonitor: FixtureNetworkMonitor())
    var signedIn = 0
    downloader.signIn(
      username: "LocalTest", executable: root.appendingPathComponent("runtime/steamcmd"),
      root: root, rememberSession: true
    ) { signedIn += 1 }
    do {
      XCTAssertTrue(downloader.isSigningInOnly)
      XCTAssertFalse(downloader.isInstallingAssets)
      try await waitUntil { downloader.prompt == .password || !downloader.isRunning }
      XCTAssertEqual(downloader.prompt, .password, downloader.errorMessage ?? "")
      downloader.submitSecret("local-password")
      try await waitUntil { !downloader.isRunning }
      XCTAssertNil(downloader.errorMessage)
      XCTAssertEqual(signedIn, 1)
      XCTAssertEqual(downloader.phase, .finishing)
      XCTAssertNil(downloader.downloadedID, "Nothing is downloaded")
      XCTAssertEqual(downloader.savedAccount, "localtest", "The accepted sign-in is saved for later downloads")
      let arguments = try String(contentsOf: root.appendingPathComponent("arguments.txt"), encoding: .utf8)
      XCTAssertTrue(arguments.contains("+login localtest +licenses_for_app 431960 +quit"), "The authenticated session checks ownership without downloading: \(arguments)")
      try assertNoStaging(in: root)
      try assertPrivateSession(in: root)
    } catch {
      await downloader.shutdown()
      throw error
    }
  }

  func testSignInChecksOwnershipWithoutTreatingUnknownOutputAsMissingPurchase() async throws {
    let cases: [(String, WorkshopDownloader.WallpaperEngineOwnership)] = [
      ("License packageID 12345:\\n - State : Active( flags 512 )\\n - Apps : 431960, (1 in total)\\n", .owned),
      ("No active license found for appID 431960.", .notOwned),
      ("", .unknown),
      ("Unknown command: licenses_for_app\\n", .unknown),
      ("No active license found for appID 4319600.\\n", .unknown),
      ("License packageID 12345:\\n - State : Inactive( flags 0 )\\n - Apps : 431960, (1 in total)\\n", .unknown),
      ("License packageID 12345:\\n - State : Active (flags 0x200)\\n - Apps : 4319600, (1 in total)\\n", .unknown),
      ("License packageID 12345:\\n - State : Active( flags 512 )\\n - Apps : 123, (1 in total)\\nLicense packageID 67890:\\n - Apps : 431960, (1 in total)\\n", .unknown),
    ]
    for (output, expected) in cases {
      let root = try makeRuntime("""
        for argument in "$@"; do
          case "$argument" in +workshop_download_item|+app_update) exit 70 ;; esac
        done
        printf 'Waiting for user info...OK\\n'
        printf '\(output)'
        """)
      defer { try? FileManager.default.removeItem(at: root) }
      let downloader = WorkshopDownloader(
        sessionDirectory: root.appendingPathComponent("SteamSession"),
        runtimeProvider: ShellRuntimeProvider(), networkMonitor: FixtureNetworkMonitor())
      downloader.signIn(username: "localtest", executable: root.appendingPathComponent("runtime/steamcmd"),
                        root: root, rememberSession: false)
      do {
        try await waitUntil { !downloader.isRunning }
        XCTAssertNil(downloader.errorMessage, "Ownership does not invalidate a successful sign-in")
        XCTAssertEqual(downloader.wallpaperEngineOwnership, expected, output)
        try assertNoStaging(in: root)
      } catch {
        await downloader.shutdown()
        throw error
      }
    }
  }

  func testOwnershipWaitsForCompleteAppIDAndResetsForTheNextSignIn() async throws {
    let root = try makeRuntime("""
      printf 'Waiting for user info...OK\\nLicense packageID 12345:\\n - State : Active( flags 512 )\\n - Apps : 431960'
      touch ../partial-license
      while [ ! -f ../finish-license ]; do sleep 0.02; done
      printf '0, (1 in total)\\nLicense packageID 67890:\\n - State : Active( flags 512 )\\n - Apps : 431960, (1 in total)\\n'
      """)
    defer { try? FileManager.default.removeItem(at: root) }
    let downloader = WorkshopDownloader(
      sessionDirectory: root.appendingPathComponent("SteamSession"),
      runtimeProvider: ShellRuntimeProvider(), networkMonitor: FixtureNetworkMonitor())
    let executable = root.appendingPathComponent("runtime/steamcmd")
    downloader.signIn(username: "localtest", executable: executable, root: root, rememberSession: false)
    do {
      try await waitUntil { FileManager.default.fileExists(atPath: root.appendingPathComponent("partial-license").path) && !downloader.isAuthenticating }
      XCTAssertEqual(downloader.wallpaperEngineOwnership, .unknown)
      try Data().write(to: root.appendingPathComponent("finish-license"))
      try await waitUntil { !downloader.isRunning }
      XCTAssertEqual(downloader.wallpaperEngineOwnership, .owned)
      try Data("#!/bin/sh\nprintf 'Waiting for user info...OK\\nNo active license found for appID 431960.\\n'\n".utf8).write(to: executable)
      downloader.signIn(username: "anotheraccount", executable: executable, root: root, rememberSession: false)
      XCTAssertEqual(downloader.wallpaperEngineOwnership, .unknown, "The previous account's ownership must not carry over")
      try await waitUntil { !downloader.isRunning }
      XCTAssertNil(downloader.errorMessage)
      XCTAssertEqual(downloader.wallpaperEngineOwnership, .notOwned)
    } catch {
      await downloader.shutdown()
      throw error
    }
  }

  /// Steam closing the session before it confirms the sign-in is a sign-in failure the user can
  /// retry, never a success.
  func testSignInOnlySessionThatEndsUnconfirmedFails() async throws {
    let root = try makeRuntime(
      """
      printf 'password: '
      IFS= read -r password
      printf '\\nLogging in user localtest to Steam Public...\\n'
      """)
    defer { try? FileManager.default.removeItem(at: root) }
    let downloader = WorkshopDownloader(
      sessionDirectory: root.appendingPathComponent("SteamSession"),
      runtimeProvider: ShellRuntimeProvider(), networkMonitor: FixtureNetworkMonitor())
    downloader.signIn(
      username: "localtest", executable: root.appendingPathComponent("runtime/steamcmd"),
      root: root, rememberSession: true)
    do {
      try await waitUntil { downloader.prompt == .password || !downloader.isRunning }
      downloader.submitSecret("local-password")
      try await waitUntil { !downloader.isRunning }
      XCTAssertNotNil(downloader.errorMessage)
      XCTAssertTrue(downloader.canRetryAuthentication)
      XCTAssertNil(downloader.savedAccount)
      try assertNoStaging(in: root)
    } catch {
      await downloader.shutdown()
      throw error
    }
  }

  func testPhaseFollowsEachSteamCMDStepBeforeAndAfterTheTransfer() async throws {
    let root = try makeRuntime(
      """
      printf 'Steam Console Client\\nUpdate state (0x5) verifying installation, progress: 1.00\\n'
      while [ ! -f ../release-login ]; do sleep 0.02; done
      printf 'Logging in using username/password.\\npassword: '
      IFS= read -r password
      printf '\\nWaiting for user info...OK\\n'
      while [ ! -f ../release-download ]; do sleep 0.02; done
      printf 'Downloading item 123456 ...\\n'
      mkdir -p steamapps/workshop/content/431960/123456
      printf '{"title":"Phase fixture","type":"video","file":"movie.mp4"}' > steamapps/workshop/content/431960/123456/project.json
      printf 'downloaded-content' > steamapps/workshop/content/431960/123456/movie.mp4
      while [ ! -f ../release-finish ]; do sleep 0.02; done
      printf 'Success. Downloaded item 123456\\n'
      """)
    defer { try? FileManager.default.removeItem(at: root) }
    let release = { (name: String) in FileManager.default.createFile(atPath: root.appendingPathComponent(name).path, contents: nil) }
    let downloader = startDownload(in: root)
    do {
      // Before SteamCMD has reported anything the run is still being prepared or launched.
      XCTAssertTrue([.preparing, .connecting].contains(downloader.phase))
      try await waitUntil { downloader.phase == .updating }
      XCTAssertNil(downloader.progress, "Runtime updates carry no wallpaper progress")
      release("release-login")
      try await waitUntil { downloader.prompt == .password }
      XCTAssertEqual(downloader.phase, .signingIn)
      downloader.submitSecret("local-password")
      try await waitUntil { downloader.phase == .requesting }
      XCTAssertFalse(downloader.isAuthenticating)
      release("release-download")
      try await waitUntil { downloader.phase == .transferring }
      release("release-finish")
      try await waitUntil { downloader.phase == .finishing }
      XCTAssertEqual(downloader.progress, 1, "The last byte fills the ring while validation runs")
      try await waitUntil { !downloader.isRunning }
      XCTAssertNil(downloader.errorMessage)
      XCTAssertEqual(downloader.phase, .finishing)
      XCTAssertEqual(downloader.downloadedID, item.id)
    } catch {
      await downloader.shutdown()
      throw error
    }
  }

  func testPresetDownloadFetchesItsBaseInTheSameRunAndInstallsOneWallpaper() async throws {
    let root = try makeRuntime(
      """
      item=''
      while [ "$#" -gt 0 ]; do
          case "$1" in +workshop_download_item) shift; shift; item="$1" ;; esac
          shift
      done
      printf '%s\\n' "$item" >> ../invocations
      printf 'Waiting for user info...OK\\nDownloading item %s ...\\n' "$item"
      content="steamapps/workshop/content/431960/$item"
      mkdir -p "$content"
      if [ "$item" = 123456 ]; then
          printf '{"title":"Purple preset","dependency":"654321","preset":{"speed":7}}' > "$content/project.json"
      else
          printf '{"title":"Base","type":"video","file":"movie.mp4","general":{"properties":{"speed":{"type":"slider","value":1}}}}' > "$content/project.json"
          printf 'base-content' > "$content/movie.mp4"
      fi
      printf 'Success. Downloaded item %s\\n' "$item"
      """)
    defer { try? FileManager.default.removeItem(at: root) }
    let downloader = startDownload(in: root)
    try await waitForStop(downloader)
    XCTAssertNil(downloader.errorMessage)
    XCTAssertEqual(downloader.downloadedID, "123456")
    let invocations = try String(contentsOf: root.appendingPathComponent("invocations"), encoding: .utf8)
    XCTAssertEqual(invocations.split(separator: "\n"), ["123456", "654321"])
    let installed = root.appendingPathComponent("Library/123456")
    XCTAssertEqual(try Data(contentsOf: installed.appendingPathComponent("movie.mp4")), Data("base-content".utf8))
    let manifest = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: installed.appendingPathComponent("project.json")))
        as? [String: Any])
    XCTAssertEqual(manifest["title"] as? String, "Purple preset")
    XCTAssertEqual(manifest["type"] as? String, "video")
    let speed = (manifest["general"] as? [String: Any])?["properties"] as? [String: Any]
    XCTAssertEqual((speed?["speed"] as? [String: Any])?["value"] as? Int, 7)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("Library/654321").path),
      "Only the requested preset joins the library")
    try assertNoStaging(in: root)
  }

  /// A Workshop preset (123456) built on a base wallpaper (654321). The preset always arrives;
  /// `base` is the shell that runs when SteamCMD is asked for the base. Every request is appended
  /// to `../invocations`, and a preset found already in the staging leaves `../preset-resumed`.
  private func makePresetRuntime(base: String) throws -> URL {
    try makeRuntime(
      """
      item=''
      while [ "$#" -gt 0 ]; do
          case "$1" in +workshop_download_item) shift; shift; item="$1" ;; esac
          shift
      done
      printf '%s\\n' "$item" >> ../invocations
      printf 'Waiting for user info...OK\\nDownloading item %s ...\\n' "$item"
      content="steamapps/workshop/content/431960/$item"
      if [ "$item" = 123456 ]; then
          [ -f "$content/project.json" ] && touch ../preset-resumed
          mkdir -p "$content"
          printf '{"title":"Purple preset","dependency":"654321","preset":{"speed":7}}' > "$content/project.json"
          printf 'Success. Downloaded item %s\\n' "$item"
      else
          \(base)
      fi
      """)
  }

  private let deliverBase = """
    mkdir -p "$content"
    printf '{"title":"Base","type":"video","file":"movie.mp4","general":{"properties":{"speed":{"type":"slider","value":1}}}}' > "$content/project.json"
    printf 'base-content' > "$content/movie.mp4"
    printf 'Success. Downloaded item %s\\n' "$item"
    """

  private let denyBase = "printf 'ERROR! Download item %s failed (Access Denied).\\n' \"$item\"; exit 1"

  private let steamDenied = String(localized: "Steam denied this download. Sign in with an account that owns Wallpaper Engine and has access to this Workshop item.")

  private func invocations(in root: URL) throws -> [String] {
    try String(contentsOf: root.appendingPathComponent("invocations"), encoding: .utf8)
      .split(separator: "\n").map(String.init)
  }

  private func assertNothingInstalled(in root: URL, file: StaticString = #filePath, line: UInt = #line) {
    for id in ["123456", "654321"] {
      XCTAssertFalse(
        FileManager.default.fileExists(atPath: root.appendingPathComponent("Library/\(id)").path),
        "Neither half of a preset reaches the library when its base is missing", file: file, line: line)
    }
  }

  func testFailedBasePassNamesTheBaseAndKeepsTheReason() async throws {
    let root = try makePresetRuntime(base: denyBase)
    defer { try? FileManager.default.removeItem(at: root) }
    let downloader = startDownload(in: root)
    try await waitForStop(downloader)
    let message = try XCTUnwrap(downloader.errorMessage)
    XCTAssertTrue(message.contains("654321"), "The user is told which item did not arrive")
    XCTAssertTrue(message.contains(steamDenied), "Steam's own reason is not swallowed")
    XCTAssertNotEqual(message, steamDenied, "It is not the bare reason for an item they never chose")
    XCTAssertNil(downloader.downloadedID)
    XCTAssertEqual(try invocations(in: root), ["123456", "654321"])
    assertNothingInstalled(in: root)
    try assertNoStaging(in: root)
  }

  func testFailedPresetPassIsReportedAsItsOwnFailure() async throws {
    // The first item is the one the user asked for: nothing about a base applies yet.
    let root = try makeRuntime(
      """
      printf 'Waiting for user info...OK\\nDownloading item 123456 ...\\nERROR! Download item 123456 failed (Access Denied).\\n'
      exit 1
      """)
    defer { try? FileManager.default.removeItem(at: root) }
    let downloader = startDownload(in: root)
    try await waitForStop(downloader)
    XCTAssertEqual(downloader.errorMessage, steamDenied)
  }

  func testBaseThatExitsWithoutConfirmingIsAlsoNamed() async throws {
    let root = try makePresetRuntime(base: "exit 0")
    defer { try? FileManager.default.removeItem(at: root) }
    let downloader = startDownload(in: root)
    try await waitForStop(downloader)
    let message = try XCTUnwrap(downloader.errorMessage)
    XCTAssertTrue(message.contains("654321"))
    XCTAssertNotEqual(message, steamDenied)
    assertNothingInstalled(in: root)

    let crashRoot = try makePresetRuntime(base: "exit 3")
    defer { try? FileManager.default.removeItem(at: crashRoot) }
    let crashed = startDownload(in: crashRoot)
    try await waitForStop(crashed)
    XCTAssertTrue(try XCTUnwrap(crashed.errorMessage).contains("654321"))
    assertNothingInstalled(in: crashRoot)
  }

  func testBaseConnectionDropIsRetriedBeforeItIsReported() async throws {
    let root = try makePresetRuntime(
      base: "printf 'ERROR! Download item %s failed (Timeout).\\n' \"$item\"; exit 1")
    defer { try? FileManager.default.removeItem(at: root) }
    let downloader = startDownload(in: root)
    try await waitForStop(downloader)
    XCTAssertEqual(
      try invocations(in: root), ["123456", "654321", "654321", "654321", "654321"],
      "The base is retried in place; the preset that already arrived is not fetched again")
    let message = try XCTUnwrap(downloader.errorMessage)
    XCTAssertTrue(message.contains("654321"))
    XCTAssertNotEqual(message, steamDenied)
    assertNothingInstalled(in: root)
  }

  func testTryAgainAfterABaseFailureResumesFromTheKeptPreset() async throws {
    let root = try makePresetRuntime(
      base: """
        if [ -f ../base-available ]; then
            \(deliverBase)
        else
            \(denyBase)
        fi
        """)
    defer { try? FileManager.default.removeItem(at: root) }
    let checkpoint = root.appendingPathComponent("Checkpoint")
    let first = startDownload(in: root, checkpointDirectory: checkpoint)
    try await waitForStop(first)
    XCTAssertNotNil(first.errorMessage)
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("preset-resumed").path))
    assertNothingInstalled(in: root)

    FileManager.default.createFile(atPath: root.appendingPathComponent("base-available").path, contents: nil)
    let again = startDownload(in: root, checkpointDirectory: checkpoint)
    try await assertImported(again, in: root, itemID: "123456")
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("preset-resumed").path),
      "The preset came back from the kept download, not from a fresh start")
    XCTAssertEqual(
      try Data(contentsOf: root.appendingPathComponent("Library/123456/movie.mp4")), Data("base-content".utf8))
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Library/654321").path))
    try assertNoStaging(in: root)
  }

  func testMobileApprovalCanAdvanceToIndeterminateDownload() async throws {
    let root = try makeRuntime(
      """
      printf 'Please confirm the login in the Steam Mobile app on your phone.\\n'
      sleep 0.5
      printf 'Waiting for user info...OK\\nDownloading item 123456 ... (25%%)\\n'
      IFS= read -r finish
      """)
    defer { try? FileManager.default.removeItem(at: root) }
    let downloader = startDownload(in: root)
    do {
      try await waitUntil { downloader.status == String(localized: "Downloading Workshop files…") }
      XCTAssertNil(downloader.progress)
      XCTAssertNil(downloader.prompt)
      XCTAssertNil(downloader.errorMessage)
      await downloader.shutdown()
    } catch {
      await downloader.shutdown()
      throw error
    }
  }

  func testWorkshopDiskGrowthReportsProgressAgainstListedSize() async throws {
    let root = try makeRuntime("""
      printf 'Waiting for user info...OK\\nDownloading item 123456 ...\\n'
      mkdir -p steamapps/workshop/downloads/431960/123456
      head -c 512 /dev/zero > steamapps/workshop/downloads/431960/123456/part1
      touch ../first-written
      while [ ! -f ../release-next ]; do sleep 0.02; done
      head -c 1024 /dev/zero > steamapps/workshop/downloads/431960/123456/part2
      touch ../second-written
      while [ ! -f ../release-finish ]; do sleep 0.02; done
      head -c 4096 /dev/zero > steamapps/workshop/downloads/431960/123456/part3
      touch ../third-written
      IFS= read -r finish
      """)
    defer { try? FileManager.default.removeItem(at: root) }
    let sizedItem = WorkshopItem(id: "123456", title: "Disk fixture", creator: "Test", summary: "", previewURL: nil, tags: ["Video"], size: 2048, subscriptions: 0)
    let downloader = startDownload(in: root, item: sizedItem)
    do {
      try await waitUntil { FileManager.default.fileExists(atPath: root.appendingPathComponent("first-written").path) }
      try await waitUntil { downloader.progress == 0.25 }
      XCTAssertEqual(downloader.bytesReceived, 512)
      XCTAssertEqual(downloader.bytesExpected, 2048)
      try Data().write(to: root.appendingPathComponent("release-next"))
      try await waitUntil { FileManager.default.fileExists(atPath: root.appendingPathComponent("second-written").path) }
      try await waitUntil { downloader.progress == 0.75 }
      XCTAssertEqual(downloader.bytesReceived, 1536)
      XCTAssertEqual(downloader.bytesExpected, 2048)
      // More bytes than Steam listed never claim completion; only its success line does.
      try Data().write(to: root.appendingPathComponent("release-finish"))
      try await waitUntil { FileManager.default.fileExists(atPath: root.appendingPathComponent("third-written").path) }
      try await waitUntil { downloader.bytesReceived == 2048 }
      XCTAssertEqual(downloader.progress, 0.99)
      await downloader.shutdown()
      XCTAssertNil(downloader.progress)
      XCTAssertNil(downloader.bytesReceived)
    } catch { await downloader.shutdown(); throw error }
  }

  func testPreallocatedWorkshopFilesReportOnlyBytesThatCrossedTheNetwork() async throws {
    // Steam can allocate a file's full length before its chunks arrive; the tree then claims
    // the whole item at once while the network meter has seen almost nothing.
    let root = try makeRuntime("""
      printf 'Waiting for user info...OK\\nDownloading item 123456 ...\\n'
      mkdir -p steamapps/workshop/downloads/431960/123456
      head -c 2048 /dev/zero > steamapps/workshop/downloads/431960/123456/movie.mp4
      touch ../allocated
      IFS= read -r finish
      """)
    defer { try? FileManager.default.removeItem(at: root) }
    let sizedItem = WorkshopItem(id: "123456", title: "Disk fixture", creator: "Test", summary: "", previewURL: nil, tags: ["Video"], size: 2048, subscriptions: 0)
    let monitor = FixtureNetworkMonitor()
    monitor.received = 0
    let downloader = startDownload(in: root, item: sizedItem, networkMonitor: monitor)
    do {
      try await waitUntil { FileManager.default.fileExists(atPath: root.appendingPathComponent("allocated").path) }
      try await waitUntil { downloader.progress == 0 }
      XCTAssertEqual(downloader.bytesReceived, 0)
      XCTAssertEqual(downloader.bytesExpected, 2048)
      monitor.received = 512
      try await waitUntil { downloader.progress == 0.25 }
      XCTAssertEqual(downloader.bytesReceived, 512)
      monitor.received = 1536
      try await waitUntil { downloader.progress == 0.75 }
      XCTAssertEqual(downloader.bytesReceived, 1536)
      // Traffic beyond what landed on disk (retries, Steam's own chatter) never runs ahead of it.
      monitor.received = 4096
      try await waitUntil { downloader.progress == 0.99 }
      XCTAssertEqual(downloader.bytesReceived, 2048)
      // A meter that stops reporting leaves the tree as the only measure.
      monitor.received = nil
      try await waitUntil { downloader.bytesReceived == 2048 && downloader.progress == 0.99 }
      await downloader.shutdown()
      XCTAssertNil(downloader.progress)
      XCTAssertNil(downloader.bytesReceived)
    } catch { await downloader.shutdown(); throw error }
  }

  func testWorkshopDiskGrowthWithoutListedSizeStaysIndeterminate() async throws {
    let root = try makeRuntime("""
      printf 'Waiting for user info...OK\\nDownloading item 123456 ...\\n'
      mkdir -p steamapps/workshop/downloads/431960/123456
      head -c 512 /dev/zero > steamapps/workshop/downloads/431960/123456/part1
      touch ../first-written
      IFS= read -r finish
      """)
    defer { try? FileManager.default.removeItem(at: root) }
    let downloader = startDownload(in: root)
    do {
      try await waitUntil { FileManager.default.fileExists(atPath: root.appendingPathComponent("first-written").path) }
      try await Task.sleep(for: .milliseconds(1200))
      XCTAssertNil(downloader.progress)
      XCTAssertNil(downloader.bytesReceived)
      XCTAssertNil(downloader.bytesExpected)
      XCTAssertNil(downloader.secondsRemaining, "Nothing to compare with means no time left to claim")
      await downloader.shutdown()
    } catch { await downloader.shutdown(); throw error }
  }

  /// Watches `bytesReceived` while the downloader reads its network meter `readings` more times,
  /// which it does every 200 ms and after each of its half-second disk samples, and returns the
  /// lowest figure shown meanwhile.
  private func lowestBytesShown(
    by downloader: WorkshopDownloader, over readings: Int, monitor: FixtureNetworkMonitor
  ) async throws -> Int64? {
    let target = monitor.receivedReadings + readings
    var lowest: Int64?
    try await waitUntil {
      if let shown = downloader.bytesReceived { lowest = min(lowest ?? shown, shown) }
      return monitor.receivedReadings >= target || !downloader.isRunning
    }
    return lowest
  }

  func testProgressNeverMovesBackwardsWhenTheTreeShrinks() async throws {
    // Steam can move chunks about, so the staged tree may weigh less later than it did earlier.
    let root = try makeRuntime("""
      printf 'Waiting for user info...OK\\nDownloading item 123456 ...\\n'
      mkdir -p steamapps/workshop/downloads/431960/123456
      head -c 1024 /dev/zero > steamapps/workshop/downloads/431960/123456/part1
      touch ../first-written
      while [ ! -f ../release-shrink ]; do sleep 0.02; done
      rm steamapps/workshop/downloads/431960/123456/part1
      head -c 256 /dev/zero > steamapps/workshop/downloads/431960/123456/part2
      touch ../shrunk
      while [ ! -f ../release-grow ]; do sleep 0.02; done
      head -c 1536 /dev/zero > steamapps/workshop/downloads/431960/123456/part3
      touch ../grown
      IFS= read -r finish
      """)
    defer { try? FileManager.default.removeItem(at: root) }
    let sizedItem = WorkshopItem(id: "123456", title: "Disk fixture", creator: "Test", summary: "", previewURL: nil, tags: ["Video"], size: 2048, subscriptions: 0)
    let monitor = FixtureNetworkMonitor()
    let downloader = startDownload(in: root, item: sizedItem, networkMonitor: monitor)
    do {
      try await waitUntil { downloader.bytesReceived == 1024 }
      XCTAssertEqual(downloader.progress, 0.5)
      try Data().write(to: root.appendingPathComponent("release-shrink"))
      try await waitUntil { FileManager.default.fileExists(atPath: root.appendingPathComponent("shrunk").path) }
      let lowest = try await lowestBytesShown(by: downloader, over: 6, monitor: monitor)
      XCTAssertEqual(lowest, 1024, "A tree that weighs less than before must not pull the bytes back")
      XCTAssertEqual(downloader.progress, 0.5)
      // Only more than was already shown moves it again.
      try Data().write(to: root.appendingPathComponent("release-grow"))
      try await waitUntil { downloader.bytesReceived == 1792 }
      XCTAssertEqual(downloader.progress, 0.875)
      await downloader.shutdown()
    } catch { await downloader.shutdown(); throw error }
  }

  func testProgressNeverMovesBackwardsWhenTheNetworkMeterStartsOver() async throws {
    let root = try makeRuntime("""
      printf 'Waiting for user info...OK\\nDownloading item 123456 ...\\n'
      mkdir -p steamapps/workshop/downloads/431960/123456
      head -c 2048 /dev/zero > steamapps/workshop/downloads/431960/123456/movie.mp4
      IFS= read -r finish
      """)
    defer { try? FileManager.default.removeItem(at: root) }
    let sizedItem = WorkshopItem(id: "123456", title: "Disk fixture", creator: "Test", summary: "", previewURL: nil, tags: ["Video"], size: 2048, subscriptions: 0)
    let monitor = FixtureNetworkMonitor()
    monitor.received = 1536
    let downloader = startDownload(in: root, item: sizedItem, networkMonitor: monitor)
    do {
      try await waitUntil { downloader.bytesReceived == 1536 }
      // A new process counts its own traffic from zero.
      monitor.received = 100
      let lowest = try await lowestBytesShown(by: downloader, over: 6, monitor: monitor)
      XCTAssertEqual(lowest, 1536, "A meter that restarts must not pull the bytes back")
      XCTAssertEqual(downloader.progress, 0.75)
      monitor.received = 1792
      try await waitUntil { downloader.bytesReceived == 1792 }
      XCTAssertEqual(downloader.progress, 0.875)
      await downloader.shutdown()
    } catch { await downloader.shutdown(); throw error }
  }

  func testProgressSurvivesSteamCMDRelaunchingWithinTheRun() async throws {
    // Exit status 42 makes the downloader launch SteamCMD again in the same staging, which
    // announces the item once more and starts a fresh network meter.
    let root = try makeRuntime("""
      printf 'Waiting for user info...OK\\nDownloading item 123456 ...\\n'
      mkdir -p steamapps/workshop/downloads/431960/123456
      if [ -f ../second-pass ]; then
          touch ../second-launch
          IFS= read -r finish
      else
          head -c 1536 /dev/zero > steamapps/workshop/downloads/431960/123456/part1
          touch ../first-launch
          while [ ! -f ../release-first ]; do sleep 0.02; done
          exit 42
      fi
      """)
    defer { try? FileManager.default.removeItem(at: root) }
    let sizedItem = WorkshopItem(id: "123456", title: "Disk fixture", creator: "Test", summary: "", previewURL: nil, tags: ["Video"], size: 2048, subscriptions: 0)
    let monitor = FixtureNetworkMonitor()
    monitor.received = 1536
    let downloader = startDownload(in: root, item: sizedItem, networkMonitor: monitor)
    do {
      try await waitUntil { downloader.bytesReceived == 1536 }
      monitor.received = 0
      try Data().write(to: root.appendingPathComponent("second-pass"))
      try Data().write(to: root.appendingPathComponent("release-first"))
      try await waitUntil { monitor.startedPIDs.count == 2 }
      XCTAssertEqual(downloader.bytesReceived, 1536, "The bar keeps its place through the relaunch")
      XCTAssertEqual(downloader.progress, 0.75)
      let lowest = try await lowestBytesShown(by: downloader, over: 6, monitor: monitor)
      XCTAssertEqual(lowest, 1536, "The second process starts counting from zero; the figure shown must not")
      XCTAssertEqual(downloader.progress, 0.75)
      XCTAssertNil(downloader.secondsRemaining, "A relaunch has no pace of its own until bytes move again")
      await downloader.shutdown()
    } catch { await downloader.shutdown(); throw error }
  }

  func testProgressAdvancesAgainAfterARelaunchEvenBelowWhatWasAlreadyShown() async throws {
    // The first process dropped at three quarters. Steam resumes and fetches only the last
    // quarter, so the second process's meter never reaches what was shown before it: the bar
    // has to carry on from where it was, not wait at that figure until Steam reports success.
    let root = try makeRuntime("""
      printf 'Waiting for user info...OK\\nDownloading item 123456 ...\\n'
      mkdir -p steamapps/workshop/downloads/431960/123456
      if [ -f ../second-pass ]; then
          head -c 1024 /dev/zero > steamapps/workshop/downloads/431960/123456/part2
          touch ../second-launch
          IFS= read -r finish
      else
          head -c 3072 /dev/zero > steamapps/workshop/downloads/431960/123456/part1
          touch ../first-launch
          while [ ! -f ../release-first ]; do sleep 0.02; done
          exit 42
      fi
      """)
    defer { try? FileManager.default.removeItem(at: root) }
    let sizedItem = WorkshopItem(id: "123456", title: "Disk fixture", creator: "Test", summary: "", previewURL: nil, tags: ["Video"], size: 4096, subscriptions: 0)
    let monitor = FixtureNetworkMonitor()
    monitor.received = 3072
    let downloader = startDownload(in: root, item: sizedItem, networkMonitor: monitor)
    do {
      try await waitUntil { downloader.bytesReceived == 3072 }
      monitor.received = 0
      try Data().write(to: root.appendingPathComponent("second-pass"))
      try Data().write(to: root.appendingPathComponent("release-first"))
      try await waitUntil { monitor.startedPIDs.count == 2 }
      try await waitUntil { FileManager.default.fileExists(atPath: root.appendingPathComponent("second-launch").path) }
      // The new meter has seen 512 bytes, far below the 3072 already shown.
      monitor.received = 512
      try await waitUntil { downloader.bytesReceived == 3584 }
      XCTAssertEqual(downloader.progress, 0.875, "Bytes fetched after the relaunch move the bar past its old place")
      monitor.received = 1024
      try await waitUntil { downloader.bytesReceived == 4096 }
      XCTAssertEqual(downloader.progress, 0.99, "Bytes alone stop short of completion")
      await downloader.shutdown()
    } catch { await downloader.shutdown(); throw error }
  }

  func testSecondsRemainingFollowsTheMeasuredPaceAndSaysNothingAtTheCap() async throws {
    let root = try makeRuntime("""
      printf 'Waiting for user info...OK\\nDownloading item 123456 ...\\n'
      mkdir -p steamapps/workshop/downloads/431960/123456
      head -c 6000000 /dev/zero > steamapps/workshop/downloads/431960/123456/movie.mp4
      touch ../allocated
      IFS= read -r finish
      """)
    defer { try? FileManager.default.removeItem(at: root) }
    let sizedItem = WorkshopItem(id: "123456", title: "Disk fixture", creator: "Test", summary: "", previewURL: nil, tags: ["Video"], size: 6_000_000, subscriptions: 0)
    let monitor = FixtureNetworkMonitor()
    monitor.received = 0
    // The estimate is measured on the downloader's clock, so the test decides how long a second is.
    var clock = Date(timeIntervalSinceReferenceDate: 0)
    let downloader = WorkshopDownloader(
      sessionDirectory: root.appendingPathComponent("SteamSession"),
      runtimeProvider: ShellRuntimeProvider(), networkMonitor: monitor, now: { clock },
      freeSpace: { _ in nil })
    downloader.start(
      item: sizedItem, username: "localtest", executable: root.appendingPathComponent("runtime/steamcmd"),
      library: root.appendingPathComponent("Library"), rememberSession: false, onImported: {})
    do {
      try await waitUntil { FileManager.default.fileExists(atPath: root.appendingPathComponent("allocated").path) }
      try await waitUntil { downloader.bytesReceived == 0 }
      XCTAssertNil(downloader.secondsRemaining, "A single reading has no pace")
      clock = Date(timeIntervalSinceReferenceDate: 2)
      monitor.received = 2_000_000
      try await waitUntil { downloader.bytesReceived == 2_000_000 }
      XCTAssertNil(downloader.secondsRemaining, "Two seconds of history is too little to promise anything")
      clock = Date(timeIntervalSinceReferenceDate: 4)
      monitor.received = 4_000_000
      try await waitUntil { downloader.bytesReceived == 4_000_000 }
      XCTAssertEqual(downloader.secondsRemaining, 2, "2 MB left at 1 MB/s")
      // The last byte is claimed by Steam alone: at the cap there is nothing left to estimate.
      clock = Date(timeIntervalSinceReferenceDate: 5)
      monitor.received = 6_000_000
      try await waitUntil { downloader.bytesReceived == 6_000_000 }
      XCTAssertEqual(downloader.progress, 0.99)
      XCTAssertNil(downloader.secondsRemaining)
      await downloader.shutdown()
      XCTAssertNil(downloader.secondsRemaining)
    } catch { await downloader.shutdown(); throw error }
  }

  func testAppUpdateProgressParsesBytes() async throws {
    let root = try makeRuntime(
      """
      mkdir -p wallpaper-engine/assets/shaders
      printf 'partial' > wallpaper-engine/assets/shaders/genericimage2.vert
      printf 'Update state (0x61) downloading, progress: 25.00 (250 / 1000)\\n'
      IFS= read -r finish
      """)
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = root.appendingPathComponent("SceneAssets")
    let downloader = WorkshopDownloader(
      sessionDirectory: root.appendingPathComponent("SteamSession"),
      runtimeProvider: ShellRuntimeProvider(), freeSpace: { _ in nil })
    downloader.installAssets(
      username: "localtest", executable: root.appendingPathComponent("runtime/steamcmd"),
      destination: destination
    ) {
      XCTFail("The incomplete install must not publish assets")
    }
    do {
      try await waitUntil { downloader.progress == 0.25 }
      XCTAssertEqual(downloader.bytesReceived, 250)
      XCTAssertEqual(downloader.bytesExpected, 1000)
      await downloader.shutdown()
    } catch {
      await downloader.shutdown()
      throw error
    }
  }

  func testGuardFailureAfterMobileApprovalStopsWithoutRequestingAnotherCode() async throws {
    let root = try makeRuntime(
      """
      printf 'Please confirm the login in the Steam Mobile app on your phone.\\n'
      sleep 0.5
      printf 'FAILED (Account logon denied, need two-factor code)\\n'
      IFS= read -r unexpected
      """)
    defer { try? FileManager.default.removeItem(at: root) }
    let downloader = startDownload(in: root)
    do {
      try await waitUntil { !downloader.isRunning }
      XCTAssertNotNil(downloader.errorMessage)
      XCTAssertNil(downloader.prompt)
      XCTAssertTrue(downloader.canRetryAuthentication)
      XCTAssertNil(downloader.downloadedID)
    } catch {
      await downloader.shutdown()
      throw error
    }
  }

  func testFailureWrittenImmediatelyBeforeExitIsNotLost() async throws {
    let root = try makeRuntime(
      """
      printf 'Logging in user to Steam Public...FAILED (Timeout)'
      exit 0
      """)
    defer { try? FileManager.default.removeItem(at: root) }
    let downloader = startDownload(in: root)
    do {
      try await waitUntil { !downloader.isRunning }
      XCTAssertNotNil(downloader.errorMessage)
      XCTAssertNil(downloader.downloadedID)
      XCTAssertFalse(
        FileManager.default.fileExists(atPath: root.appendingPathComponent("Library").path),
        "Login failure must stop before starting the importer")
    } catch {
      await downloader.shutdown()
      throw error
    }
  }

  func testReportedFailuresKeepTheirDiagnosisThroughTerminalExit() async throws {
    let cases: [(String, SteamCMDReportedFailure)] = [
      ("ServiceUnavailable", .connection), ("RateLimitExceeded", .rateLimited),
      ("InvalidPassword", .credentials), ("Unexpected result", .unknown),
    ]
    for (reason, expected) in cases {
      let root = try makeRuntime("printf 'Logging in user to Steam Public...FAILED (\(reason))'; exit 1")
      defer { try? FileManager.default.removeItem(at: root) }
      let downloader = startDownload(in: root)
      do {
        try await waitUntil { !downloader.isRunning }
        XCTAssertEqual(downloader.errorMessage, expected.message, reason)
        XCTAssertTrue(downloader.canRetryAuthentication)
        XCTAssertNil(downloader.prompt)
        XCTAssertNil(downloader.downloadedID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Library").path))
      } catch {
        await downloader.shutdown()
        throw error
      }
    }
  }

  func testDeniedMobileApprovalCanRestartWithFreshCredentials() async throws {
    let root = try makeRuntime(
      """
      printf 'password: '
      IFS= read -r password
      printf '\\nPlease confirm the login in the Steam Mobile app on your phone.\\n'
      if [ ! -f ../approve-next-login ]; then
          printf 'FAILED (Access Denied)\\n'
          exit 1
      fi
      [ "$password" = 'fresh-password' ] || exit 10
      printf 'Two-factor code: '
      IFS= read -r code
      [ "$code" = 'NEW42' ] || exit 11
      printf '\\nWaiting for user info...OK\\nDownloading item 123456 ...\\n'
      mkdir -p steamapps/workshop/content/431960/123456
      printf '{"type":"video","file":"movie.mp4"}' > steamapps/workshop/content/431960/123456/project.json
      printf 'retried-content' > steamapps/workshop/content/431960/123456/movie.mp4
      printf 'Success. Downloaded item 123456\\n'
      """)
    defer { try? FileManager.default.removeItem(at: root) }
    let downloader = startDownload(in: root)
    do {
      try await waitUntil { downloader.prompt == .password }
      downloader.submitSecret("first-password")
      try await waitUntil { !downloader.isRunning }
      XCTAssertTrue(downloader.canRetryAuthentication)
      XCTAssertNotNil(downloader.errorMessage)
      XCTAssertNil(downloader.downloadedID)
      XCTAssertFalse(
        try FileManager.default.contentsOfDirectory(atPath: root.path).contains {
          $0.hasPrefix(".WallpaperMachine-workshop-")
        })

      try Data().write(to: root.appendingPathComponent("approve-next-login"))
      downloader.start(
        item: item, username: "localtest",
        executable: root.appendingPathComponent("runtime/steamcmd"),
        library: root.appendingPathComponent("Library"), onImported: {})
      XCTAssertFalse(downloader.canRetryAuthentication)
      XCTAssertNil(downloader.errorMessage)
      try await waitUntil { downloader.prompt == .password }
      downloader.submitSecret("fresh-password")
      try await waitUntil { downloader.prompt == .guardCode }
      XCTAssertEqual(downloader.steamGuardChallenge, .authenticatorCode)
      downloader.submitSecret("NEW42")
      try await waitUntil { !downloader.isRunning }
      XCTAssertNil(downloader.errorMessage)
      XCTAssertFalse(downloader.canRetryAuthentication)
      XCTAssertNil(downloader.steamGuardChallenge)
      XCTAssertEqual(downloader.downloadedID, item.id)
      XCTAssertEqual(
        try String(
          contentsOf: root.appendingPathComponent("Library/123456/movie.mp4"), encoding: .utf8),
        "retried-content")
    } catch {
      await downloader.shutdown()
      throw error
    }
  }

  func testWorkshopAccessDenialDoesNotOfferAuthenticationRetry() async throws {
    let root = try makeRuntime(
      """
      printf 'Waiting for user info...OK\\nDownloading item 123456 ...\\n'
      printf 'ERROR! Download item 123456 failed (Access Denied).\\n'
      exit 1
      """)
    defer { try? FileManager.default.removeItem(at: root) }
    let downloader = startDownload(in: root)
    do {
      try await waitUntil { !downloader.isRunning }
      XCTAssertNotNil(downloader.errorMessage)
      XCTAssertFalse(downloader.canRetryAuthentication)
      XCTAssertNil(downloader.downloadedID)
    } catch {
      await downloader.shutdown()
      throw error
    }
  }

  func testSceneAssetsInstallUsesWindowsAppAndKeepsOnlyValidatedAssets() async throws {
    let root = try makeRuntime(
      """
      platform=''
      install=''
      app=''
      while [ "$#" -gt 0 ]; do
          case "$1" in
              +@sSteamCmdForcePlatformType) shift; platform="$1" ;;
              +force_install_dir) shift; install="$1" ;;
              +app_update) shift; app="$1" ;;
          esac
          shift
      done
      [ "$platform" = windows ] && [ "$app" = 431960 ] && [ -n "$install" ] || exit 12
      printf 'password: '
      IFS= read -r password
      [ "$password" = 'local-password' ] || exit 13
      printf '\\nWaiting for user info...OK\\n'
      mkdir -p "$install/assets/shaders" "$install/assets/materials/util" config
      printf 'vertex-content' > "$install/assets/shaders/genericimage2.vert"
      printf 'fragment-content' > "$install/assets/shaders/genericimage2.frag"
      printf '{"passes":[{"shader":"genericimage2"}]}' > "$install/assets/materials/util/effectpassthrough.json"
      printf 'windows-executable' > "$install/wallpaper64.exe"
      printf 'temporary-login' > config/loginusers.vdf
      printf "Success! App '431960' fully installed.\\n"
      """)
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = root.appendingPathComponent("SceneAssets")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    try Data("previous-incomplete-install".utf8).write(
      to: destination.appendingPathComponent("old"))
    let downloader = WorkshopDownloader(
      sessionDirectory: root.appendingPathComponent("SteamSession"),
      runtimeProvider: ShellRuntimeProvider(), freeSpace: { _ in nil })
    downloader.installAssets(
      username: "localtest", executable: root.appendingPathComponent("runtime/steamcmd"),
      destination: destination, onInstalled: {})
    do {
      try await waitUntil { downloader.prompt == .password }
      downloader.submitSecret("local-password")
      try await waitUntil { !downloader.isRunning }
      XCTAssertNil(downloader.errorMessage)
      XCTAssertTrue(ClientPaths.hasSceneAssets(at: destination))
      XCTAssertEqual(
        try String(
          contentsOf: destination.appendingPathComponent("shaders/genericimage2.vert"),
          encoding: .utf8), "vertex-content")
      XCTAssertFalse(
        FileManager.default.fileExists(atPath: destination.appendingPathComponent("old").path))
      try assertNoStaging(in: root)
      XCTAssertEqual(
        Set(try FileManager.default.contentsOfDirectory(atPath: destination.path)),
        ["shaders", "materials"])
      XCTAssertNil(downloader.downloadedID, "Shared assets must not be reported as a Workshop item")
    } catch {
      await downloader.shutdown()
      throw error
    }
  }

  func testIncompleteSceneAssetsNeverReplaceExistingInstallation() async throws {
    let root = try makeRuntime(
      """
      printf 'Waiting for user info...OK\\n'
      mkdir -p wallpaper-engine/assets/shaders
      printf 'partial-download' > wallpaper-engine/assets/shaders/genericimage2.vert
      printf "Success! App '431960' fully installed.\\n"
      """)
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = root.appendingPathComponent("SceneAssets")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    try Data("preserved".utf8).write(to: destination.appendingPathComponent("existing"))
    let downloader = WorkshopDownloader(
      sessionDirectory: root.appendingPathComponent("SteamSession"),
      runtimeProvider: ShellRuntimeProvider(), freeSpace: { _ in nil })
    downloader.installAssets(
      username: "localtest", executable: root.appendingPathComponent("runtime/steamcmd"),
      destination: destination
    ) {
      XCTFail("An incomplete install must not become the renderer's configured assets")
    }
    do {
      try await waitUntil { !downloader.isRunning }
      XCTAssertNotNil(downloader.errorMessage)
      XCTAssertFalse(
        downloader.canRetryAuthentication, "Asset validation failure is not a sign-in failure")
      XCTAssertEqual(
        try String(contentsOf: destination.appendingPathComponent("existing"), encoding: .utf8),
        "preserved")
      XCTAssertEqual(
        try FileManager.default.contentsOfDirectory(atPath: destination.path), ["existing"])
      try assertNoStaging(in: root)
    } catch {
      await downloader.shutdown()
      throw error
    }
  }

  func testCancellingSceneAssetDownloadDoesNotPublishPartialResources() async throws {
    let root = try makeRuntime(
      """
      mkdir -p wallpaper-engine/assets/shaders
      printf 'partial' > wallpaper-engine/assets/shaders/genericimage2.vert
      printf 'Update state (0x61) downloading, progress: 25.00 (250 / 1000)\\n'
      IFS= read -r finish
      """)
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = root.appendingPathComponent("SceneAssets")
    let downloader = WorkshopDownloader(
      sessionDirectory: root.appendingPathComponent("SteamSession"),
      runtimeProvider: ShellRuntimeProvider(), freeSpace: { _ in nil })
    downloader.installAssets(
      username: "localtest", executable: root.appendingPathComponent("runtime/steamcmd"),
      destination: destination
    ) {
      XCTFail("Cancellation must not publish partial scene assets")
    }
    do {
      try await waitUntil { downloader.progress == 0.25 }
      await downloader.shutdown()
      XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
      try assertNoStaging(in: root)
    } catch {
      await downloader.shutdown()
      throw error
    }
  }

  func testUnconfirmedWorkshopContentIsNotPublished() async throws {
    let root = try makeRuntime(
      """
      printf 'Waiting for user info...OK\\nDownloading item 123456 ...\\n'
      mkdir -p steamapps/workshop/content/431960/123456
      printf '{"type":"video","file":"movie.mp4"}' > steamapps/workshop/content/431960/123456/project.json
      printf 'partial-content' > steamapps/workshop/content/431960/123456/movie.mp4
      exit 0
      """)
    defer { try? FileManager.default.removeItem(at: root) }
    let downloader = startDownload(in: root)
    try await waitForStop(downloader)
    XCTAssertNotNil(downloader.errorMessage)
    XCTAssertNil(downloader.downloadedID)
    XCTAssertFalse(downloader.wasCancelled)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("Library/123456").path))
    try assertNoStaging(in: root)
  }

  // MARK: Free disk space

  private let mebibyte: Int64 = 1_048_576

  private func sizedItem(_ size: Int64) -> WorkshopItem {
    WorkshopItem(
      id: "123456", title: "Sized fixture", creator: "Test", summary: "", previewURL: nil,
      tags: ["Video"], size: size, subscriptions: 0)
  }

  private func fileSize(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    return formatter.string(fromByteCount: bytes)
  }

  /// A SteamCMD stand-in that leaves a marker next to staging when it starts and then delivers
  /// the item, so a test sees both whether it was launched and whether the download completed.
  private func makeMarkingRuntime() throws -> URL {
    try makeRuntime(
      """
      touch ../launched
      printf 'Waiting for user info...OK\\nDownloading item 123456 ...\\n'
      content="steamapps/workshop/content/431960/123456"
      mkdir -p "$content"
      printf '{"type":"video","file":"movie.mp4"}' > "$content/project.json"
      printf 'movie' > "$content/movie.mp4"
      printf 'Success. Downloaded item 123456\\n'
      """)
  }

  private func launched(in root: URL) -> Bool {
    FileManager.default.fileExists(atPath: root.appendingPathComponent("launched").path)
  }

  private func restart(_ downloader: WorkshopDownloader, in root: URL, item: WorkshopItem) {
    downloader.start(
      item: item, username: "localtest", executable: root.appendingPathComponent("runtime/steamcmd"),
      library: root.appendingPathComponent("Library"), onImported: {})
  }

  func testShortFreeSpaceFailsBeforeSteamCMDLaunches() async throws {
    let root = try makeMarkingRuntime()
    defer { try? FileManager.default.removeItem(at: root) }
    let listed = sizedItem(50 * mebibyte)
    let disk = FreeSpaceProbe(3 * mebibyte)
    let downloader = startDownload(in: root, item: listed, freeSpace: disk.measure)
    try await waitForStop(downloader)
    let needed = try XCTUnwrap(
      WorkshopDownloader.requiredFreeBytes(expected: listed.size, alreadyStaged: 0, installingAssets: false))
    let message = try XCTUnwrap(downloader.errorMessage)
    XCTAssertTrue(message.contains(fileSize(needed)), "The message names what the download needs: \(message)")
    XCTAssertTrue(message.contains(fileSize(3 * mebibyte)), "The message names what is free: \(message)")
    XCTAssertFalse(launched(in: root), "SteamCMD must not start on a disk that cannot hold the item")
    XCTAssertNil(downloader.downloadedID)
    XCTAssertFalse(downloader.wasCancelled)
    XCTAssertFalse(downloader.canRetryAuthentication, "A full disk is not a sign-in failure")
    XCTAssertEqual(
      disk.questions.map(\.path), [root.path],
      "Free space is read on the disk that holds the library")
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Library/123456").path))
    try assertNoStaging(in: root)
  }

  func testTryAgainChecksFreeSpaceAgainAndStartsOnceThereIsRoom() async throws {
    let root = try makeMarkingRuntime()
    defer { try? FileManager.default.removeItem(at: root) }
    let listed = sizedItem(50 * mebibyte)
    let disk = FreeSpaceProbe(3 * mebibyte)
    let downloader = startDownload(in: root, item: listed, freeSpace: disk.measure)
    try await waitForStop(downloader)
    XCTAssertNotNil(downloader.errorMessage)
    XCTAssertFalse(launched(in: root))
    disk.available = 4_000 * mebibyte
    restart(downloader, in: root, item: listed)
    try await assertImported(downloader, in: root, itemID: "123456")
    XCTAssertTrue(launched(in: root))
    XCTAssertEqual(disk.questions.count, 2, "Each start reads the disk again")
    try assertNoStaging(in: root)
  }

  func testEnoughFreeSpaceDownloadsNormally() async throws {
    let root = try makeMarkingRuntime()
    defer { try? FileManager.default.removeItem(at: root) }
    let listed = sizedItem(50 * mebibyte)
    let needed = try XCTUnwrap(
      WorkshopDownloader.requiredFreeBytes(expected: listed.size, alreadyStaged: 0, installingAssets: false))
    let disk = FreeSpaceProbe(needed)
    let downloader = startDownload(in: root, item: listed, freeSpace: disk.measure)
    try await assertImported(downloader, in: root, itemID: "123456")
    XCTAssertTrue(launched(in: root), "Exactly the space it needs is enough")
  }

  func testUnknownFreeSpaceNeverBlocks() async throws {
    let root = try makeMarkingRuntime()
    defer { try? FileManager.default.removeItem(at: root) }
    let disk = FreeSpaceProbe(nil)
    let downloader = startDownload(in: root, item: sizedItem(50 * mebibyte), freeSpace: disk.measure)
    try await assertImported(downloader, in: root, itemID: "123456")
    XCTAssertTrue(launched(in: root))
  }

  func testItemWithoutAListedSizeIsNeverBlocked() async throws {
    let root = try makeMarkingRuntime()
    defer { try? FileManager.default.removeItem(at: root) }
    let disk = FreeSpaceProbe(0)
    let downloader = startDownload(in: root, item: sizedItem(0), freeSpace: disk.measure)
    try await assertImported(downloader, in: root, itemID: "123456")
    XCTAssertTrue(launched(in: root), "Without a size there is nothing to compare the disk with")
  }

  func testPartialDownloadsAlreadyOnDiskReduceWhatIsRequired() async throws {
    let root = try makeMarkingRuntime()
    defer { try? FileManager.default.removeItem(at: root) }
    let listed = sizedItem(8 * mebibyte)
    let fresh = try XCTUnwrap(
      WorkshopDownloader.requiredFreeBytes(expected: listed.size, alreadyStaged: 0, installingAssets: false))
    let resumed = try XCTUnwrap(
      WorkshopDownloader.requiredFreeBytes(expected: listed.size, alreadyStaged: listed.size, installingAssets: false))
    XCTAssertLessThan(resumed, fresh)
    // Room for the rest of a half-finished download, but not for the whole item over again.
    let disk = FreeSpaceProbe((fresh + resumed) / 2)
    let checkpoint = root.appendingPathComponent("Checkpoint")
    let downloader = startDownload(in: root, item: listed, checkpointDirectory: checkpoint, freeSpace: disk.measure)
    try await waitForStop(downloader)
    XCTAssertNotNil(downloader.errorMessage, "Nothing is staged yet, so the whole item must fit")
    XCTAssertFalse(launched(in: root))

    let partial = checkpoint.appendingPathComponent("steamapps/workshop/downloads/431960/123456")
    try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
    try Data(repeating: 1, count: Int(listed.size)).write(to: partial.appendingPathComponent("part"))
    restart(downloader, in: root, item: listed)
    try await assertImported(downloader, in: root, itemID: "123456")
    XCTAssertTrue(launched(in: root), "What the earlier attempt kept is already on the disk")
  }

  func testRequiredFreeBytesTracksTheListedSizeAndWhatIsAlreadyStaged() {
    let size = 100 * mebibyte
    let fresh = WorkshopDownloader.requiredFreeBytes(expected: size, alreadyStaged: 0, installingAssets: false)
    XCTAssertNotNil(fresh)
    XCTAssertGreaterThan(fresh ?? 0, size + WorkshopDownloader.freeSpaceMargin, "The item plus Steam's staging overhead")
    let half = WorkshopDownloader.requiredFreeBytes(expected: size, alreadyStaged: size / 2, installingAssets: false)
    XCTAssertLessThan(half ?? .max, fresh ?? 0)
    XCTAssertGreaterThan(half ?? 0, WorkshopDownloader.freeSpaceMargin)
    for staged in [size, 3 * size] {
      XCTAssertEqual(
        WorkshopDownloader.requiredFreeBytes(expected: size, alreadyStaged: staged, installingAssets: false),
        WorkshopDownloader.freeSpaceMargin, "A fully staged item needs only the margin")
    }
    XCTAssertEqual(
      WorkshopDownloader.requiredFreeBytes(expected: size, alreadyStaged: -5, installingAssets: false), fresh)
    XCTAssertNil(WorkshopDownloader.requiredFreeBytes(expected: nil, alreadyStaged: 0, installingAssets: false))
    XCTAssertNil(WorkshopDownloader.requiredFreeBytes(expected: 0, alreadyStaged: 0, installingAssets: false))
    XCTAssertNotNil(
      WorkshopDownloader.requiredFreeBytes(expected: .max, alreadyStaged: 0, installingAssets: false),
      "An absurd listed size is bounded rather than overflowing")
  }

  func testSceneAssetsUseTheFixedFloor() async throws {
    let floor = WorkshopDownloader.sceneAssetsFreeBytes
    for (expected, staged) in [(nil, 0), (Int64(10), 0), (nil, -5)] as [(Int64?, Int64)] {
      XCTAssertEqual(
        WorkshopDownloader.requiredFreeBytes(expected: expected, alreadyStaged: staged, installingAssets: true),
        floor, "Nothing staged yet: the whole floor, whatever the listing says")
    }
    XCTAssertEqual(
      WorkshopDownloader.requiredFreeBytes(expected: nil, alreadyStaged: floor / 2, installingAssets: true),
      floor - floor / 2, "What an earlier attempt kept is already on the disk")
    XCTAssertEqual(
      WorkshopDownloader.requiredFreeBytes(expected: nil, alreadyStaged: 10 * floor, installingAssets: true),
      WorkshopDownloader.freeSpaceMargin, "A fully staged install needs only the margin")
    let root = try makeRuntime("touch ../launched")
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = root.appendingPathComponent("SceneAssets")
    let disk = FreeSpaceProbe(floor - 1)
    let downloader = WorkshopDownloader(
      sessionDirectory: root.appendingPathComponent("SteamSession"),
      runtimeProvider: ShellRuntimeProvider(), networkMonitor: FixtureNetworkMonitor(),
      freeSpace: disk.measure)
    downloader.installAssets(
      username: "localtest", executable: root.appendingPathComponent("runtime/steamcmd"),
      destination: destination
    ) {
      XCTFail("A disk that cannot hold the assets must not install them")
    }
    try await waitForStop(downloader)
    let message = try XCTUnwrap(downloader.errorMessage)
    XCTAssertTrue(message.contains(fileSize(floor)) && message.contains(fileSize(floor - 1)), message)
    XCTAssertFalse(launched(in: root))
    XCTAssertFalse(downloader.canRetryAuthentication)
    XCTAssertEqual(disk.questions.map(\.path), [root.path], "Free space is read where the assets are installed")
    try assertNoStaging(in: root)

    disk.available = floor
    downloader.installAssets(
      username: "localtest", executable: root.appendingPathComponent("runtime/steamcmd"),
      destination: destination, onInstalled: {})
    try await waitUntil { self.launched(in: root) }
    await downloader.shutdown()
  }

  func testResumedSceneAssetsOnlyNeedTheSpaceStillMissing() async throws {
    let root = try makeRuntime("touch ../launched")
    defer { try? FileManager.default.removeItem(at: root) }
    let floor = WorkshopDownloader.sceneAssetsFreeBytes
    let kept = 4 * mebibyte
    // Short of the whole floor, but by less than the earlier attempt kept on the disk.
    let disk = FreeSpaceProbe(floor - kept / 2)
    let checkpoint = root.appendingPathComponent("Checkpoint")
    let destination = root.appendingPathComponent("SceneAssets")
    let downloader = WorkshopDownloader(
      sessionDirectory: root.appendingPathComponent("SteamSession"),
      runtimeProvider: ShellRuntimeProvider(), networkMonitor: FixtureNetworkMonitor(),
      checkpointDirectory: checkpoint, freeSpace: disk.measure)
    let install = {
      downloader.installAssets(
        username: "localtest", executable: root.appendingPathComponent("runtime/steamcmd"),
        destination: destination, onInstalled: {})
    }
    install()
    try await waitForStop(downloader)
    XCTAssertNotNil(downloader.errorMessage, "Nothing is staged yet, so the whole floor must fit")
    XCTAssertFalse(launched(in: root))

    // The connection dropped after most of the install had arrived: Resume must not ask for it again.
    let partial = checkpoint.appendingPathComponent("wallpaper-engine/steamapps/downloading/431960")
    try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
    try Data(repeating: 1, count: Int(kept)).write(to: partial.appendingPathComponent("part"))
    install()
    try await waitUntil { self.launched(in: root) }
    await downloader.shutdown()
  }

  func testSignInOnlyNeverChecksFreeSpace() async throws {
    let root = try makeRuntime("printf 'Waiting for user info...OK\\n'")
    defer { try? FileManager.default.removeItem(at: root) }
    let disk = FreeSpaceProbe(0)
    let downloader = WorkshopDownloader(
      sessionDirectory: root.appendingPathComponent("SteamSession"),
      runtimeProvider: ShellRuntimeProvider(), networkMonitor: FixtureNetworkMonitor(),
      freeSpace: disk.measure)
    downloader.signIn(
      username: "localtest", executable: root.appendingPathComponent("runtime/steamcmd"),
      root: root, rememberSession: false)
    try await waitForStop(downloader)
    XCTAssertNil(downloader.errorMessage, "Signing in writes nothing worth a disk check")
    XCTAssertTrue(disk.questions.isEmpty)
    try assertNoStaging(in: root)
  }

  func testAvailableCapacityReadsTheVolumeOfAFolder() throws {
    let folder = FileManager.default.temporaryDirectory
    let free = try XCTUnwrap(WorkshopDownloader.availableCapacity(at: folder))
    XCTAssertGreaterThan(free, 0)
    XCTAssertNil(
      WorkshopDownloader.availableCapacity(
        at: folder.appendingPathComponent("mwe-missing-\(UUID().uuidString)")),
      "A folder that cannot be read is unknown, which never blocks a download")
  }
}
