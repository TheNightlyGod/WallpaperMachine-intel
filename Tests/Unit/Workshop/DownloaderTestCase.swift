import Darwin
import XCTest

@testable import WallpaperMachine

/// Shared fixture for the `WorkshopDownloader` suites: a shell `steamcmd` stand-in on a real PTY,
/// session and parallel runtimes, and the assertions every suite makes about staging and
/// credentials. Split from one 2,300-line class so each area reads and runs on its own.
@MainActor
class DownloaderTestCase: XCTestCase {
  let item = WorkshopItem(
    id: "123456", title: "Download lifecycle", creator: "Test", summary: "", previewURL: nil,
    tags: ["Video"], size: 0, subscriptions: 0)

  func makeRuntime(_ script: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "mwe-terminal-tests-\(UUID().uuidString)")
    let runtime = root.appendingPathComponent("runtime")
    try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
    let executable = runtime.appendingPathComponent("steamcmd")
    try Data(("#!/bin/sh\n" + script + "\n").utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    return root
  }

  func startDownload(
    in root: URL, username: String = "localtest", itemID: String = "123456",
    libraryName: String = "Library", rememberSession: Bool = true, item: WorkshopItem? = nil,
    networkMonitor: (any ProcessNetworkMonitoring)? = nil, checkpointDirectory: URL? = nil,
    freeSpace: (@Sendable (URL) -> Int64?)? = nil, retryDelays: [TimeInterval] = [0, 0, 0],
    runtimeProvider: (any SteamCMDRuntimeProviding)? = nil
  ) -> WorkshopDownloader {
    let downloader = WorkshopDownloader(
      sessionDirectory: root.appendingPathComponent("SteamSession"),
      runtimeProvider: runtimeProvider ?? ShellRuntimeProvider(),
      networkMonitor: networkMonitor ?? FixtureNetworkMonitor(),
      checkpointDirectory: checkpointDirectory,
      freeSpace: freeSpace ?? WorkshopDownloader.systemFreeSpace, retryDelays: retryDelays)
    let requestedItem = item ?? WorkshopItem(
      id: itemID, title: "Session fixture", creator: "Test", summary: "", previewURL: nil,
      tags: ["Video"], size: 0, subscriptions: 0)
    downloader.start(
      item: requestedItem, username: username,
      executable: root.appendingPathComponent("runtime/steamcmd"),
      library: root.appendingPathComponent(libraryName), rememberSession: rememberSession,
      onImported: {})
    return downloader
  }

  func waitUntil(_ condition: @escaping () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(5)
    while !condition() {
      guard Date() < deadline else {
        throw WorkshopFailure(message: "SteamCMD did not advance its interactive session")
      }
      try await Task.sleep(for: .milliseconds(20))
    }
  }

  func makeSessionRuntime() throws -> URL {
    try makeRuntime(
      """
      set -eu
      account=''
      install=''
      item=''
      for argument in "$@"; do
          case "$argument" in
              *local-password*|*12345-secret*) exit 80 ;;
          esac
      done
      while [ "$#" -gt 0 ]; do
          case "$1" in
              +login) shift; account="$1" ;;
              +force_install_dir) shift; install="$1" ;;
              +workshop_download_item) shift; shift; item="$1" ;;
          esac
          shift
      done
      [ -n "$account" ] && [ -n "$install" ] && [ -n "$item" ] || exit 81
      account=$(printf '%s' "$account" | tr '[:upper:]' '[:lower:]')
      registry="$HOME/Library/Application Support/Steam/registry.vdf"
      homeconfig="$HOME/Library/Application Support/Steam/config/config.vdf"
      mode=normal
      if [ -f ../session-mode ]; then mode=$(cat ../session-mode); fi
      source=fresh
      if [ -f config/config.vdf ] || [ -f "$registry" ] || [ -f "$homeconfig" ] || [ -f ssfn123456 ]; then
          [ "$(cat config/config.vdf)" = "token:$account" ] || exit 82
          [ "$(cat "$registry")" = "registry:$account" ] || exit 83
          [ "$(cat ssfn123456)" = "machine-token" ] || exit 84
          [ "$(cat "$homeconfig")" = "home-token:$account" ] || exit 87
          source=cached
          if [ "$mode" = terminal ]; then
              printf 'FAILED (Invalid cached credentials)\\n'
              exit 1
          fi
          if [ "$mode" = fallback ]; then
              printf 'Warning (invalid cached credentials)\\n'
              source=fresh
          fi
      fi
      if [ "$source" = fresh ]; then
          printf 'password: '
          IFS= read -r password
          [ "$password" = local-password ] || exit 85
          printf '\\nSteam Guard code: '
          IFS= read -r code
          [ "$code" = 12345-secret ] || exit 86
          mkdir -p config "$(dirname "$registry")" "$(dirname "$homeconfig")"
          printf 'token:%s' "$account" > config/config.vdf
          printf 'registry:%s' "$account" > "$registry"
          printf 'home-token:%s' "$account" > "$homeconfig"
          printf 'machine-token' > ssfn123456
          printf '%s:%s' "$password" "$code" > config/console.log
          printf '%s' "$password" > submitted-password.txt
          chmod 644 config/config.vdf "$registry" "$homeconfig" ssfn123456
      fi
      if [ "$mode" = reject ]; then
          printf '\\nFAILED (Invalid Password)\\n'
          exit 1
      fi
      printf '\\nWaiting for user info...OK\\n'
      if [ "$mode" = access ]; then
          printf 'Downloading item %s ...\\nERROR! Download item %s failed (Access Denied).\\n' "$item" "$item"
          exit 1
      fi
      content="$install/steamapps/workshop/content/431960/$item"
      mkdir -p "$content"
      printf '{"type":"video","file":"movie.mp4"}' > "$content/project.json"
      printf '%s:%s:%s' "$source" "$account" "$item" > "$content/movie.mp4"
      if [ "$mode" = cancel ]; then
          printf 'Downloading item %s ... (25%%)\\n' "$item"
          IFS= read -r finish
          exit 0
      fi
      printf 'Downloading item %s ...\\nSuccess. Downloaded item %s\\n' "$item" "$item"
      """)
  }

  /// Like the session runtime, but every transfer blocks until `release-<item>` appears next to
  /// the staging directories, so the test observes which sessions run side by side.
  func makeParallelRuntime(conflict: String = "") throws -> URL {
    try makeRuntime(
      """
      set -eu
      account=''
      item=''
      while [ "$#" -gt 0 ]; do
          case "$1" in
              +login) shift; account="$1" ;;
              +workshop_download_item) shift; shift; item="$1" ;;
          esac
          shift
      done
      [ -n "$account" ] && [ -n "$item" ] || exit 81
      if [ -f config/config.vdf ]; then
          [ "$(cat config/config.vdf)" = "token:$account" ] || exit 82
          printf 'Logging in using cached credentials\\n'
      else
          printf 'password: '
          IFS= read -r password
          [ "$password" = local-password ] || exit 85
          mkdir -p config
          printf 'token:%s' "$account" > config/config.vdf
          chmod 644 config/config.vdf
      fi
      \(conflict)
      printf '\\nWaiting for user info...OK\\nDownloading item %s ... (25%%)\\n' "$item"
      touch "../running-$item"
      while [ ! -f "../release-$item" ]; do sleep 0.02; done
      content="steamapps/workshop/content/431960/$item"
      mkdir -p "$content"
      printf '{"type":"video","file":"movie.mp4"}' > "$content/project.json"
      printf 'content-%s' "$item" > "$content/movie.mp4"
      printf 'Success. Downloaded item %s\\n' "$item"
      """)
  }

  func setSessionMode(_ mode: String, in root: URL) throws {
    try Data(mode.utf8).write(to: root.appendingPathComponent("session-mode"))
  }

  func authenticate(_ downloader: WorkshopDownloader, guardCode: Bool = true) async throws {
    do {
      try await waitUntil { downloader.prompt == .password || !downloader.isRunning }
      guard downloader.prompt == .password else {
        throw WorkshopFailure(
          message: "Expected a fresh password prompt: \(downloader.errorMessage ?? "session ended")"
        )
      }
      downloader.submitSecret("local-password")
      guard guardCode else { return }
      try await waitUntil { downloader.prompt == .guardCode || !downloader.isRunning }
      guard downloader.prompt == .guardCode else {
        throw WorkshopFailure(
          message: "Expected a Steam Guard prompt: \(downloader.errorMessage ?? "session ended")")
      }
      downloader.submitSecret("12345-secret")
    } catch {
      await downloader.shutdown()
      throw error
    }
  }

  func waitForStop(_ downloader: WorkshopDownloader) async throws {
    do {
      try await waitUntil { !downloader.isRunning }
    } catch {
      await downloader.shutdown()
      throw error
    }
  }

  func assertImported(
    _ downloader: WorkshopDownloader, in root: URL, itemID: String, libraryName: String = "Library",
    file: StaticString = #filePath, line: UInt = #line
  ) async throws {
    try await waitForStop(downloader)
    XCTAssertNil(downloader.errorMessage, file: file, line: line)
    XCTAssertEqual(downloader.downloadedID, itemID, file: file, line: line)
    let movie = root.appendingPathComponent("\(libraryName)/\(itemID)/movie.mp4")
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: movie.path),
      "The newly requested wallpaper must actually be imported", file: file, line: line)
  }

  func assertNoStaging(in root: URL, file: StaticString = #filePath, line: UInt = #line)
    throws
  {
    let children = try FileManager.default.contentsOfDirectory(atPath: root.path)
    XCTAssertFalse(
      children.contains { $0.hasPrefix(".WallpaperMachine-workshop-") }, file: file, line: line)
  }

  func sessionEntries(in root: URL) throws -> [URL] {
    let session = root.appendingPathComponent("SteamSession")
    guard FileManager.default.fileExists(atPath: session.path) else { return [] }
    let enumerator = try XCTUnwrap(
      FileManager.default.enumerator(at: session, includingPropertiesForKeys: [.isRegularFileKey]))
    return [session] + enumerator.compactMap { $0 as? URL }
  }

  func assertNoSavedCredentials(
    in root: URL, file: StaticString = #filePath, line: UInt = #line
  ) throws {
    for url in try sessionEntries(in: root)
    where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
      let contents = try Data(contentsOf: url)
      for marker in ["token:", "registry:", "machine-token", "local-password", "12345-secret"] {
        XCTAssertNil(
          contents.range(of: Data(marker.utf8)),
          "Forgotten credentials remain in \(url.lastPathComponent)", file: file, line: line)
      }
    }
  }

  func assertPrivateSession(
    in root: URL, file: StaticString = #filePath, line: UInt = #line
  ) throws {
    let entries = try sessionEntries(in: root)
    for url in entries {
      let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
      let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
      XCTAssertEqual(
        permissions & 0o077, 0,
        "Steam credentials must be inaccessible to group and other users: \(url.path)", file: file,
        line: line)
      guard attributes[.type] as? FileAttributeType == .typeRegular else { continue }
      let contents = try Data(contentsOf: url)
      for forbidden in [
        "local-password", "12345-secret", "fresh:localtest:123456", "\"movie.mp4\"",
      ] {
        XCTAssertNil(
          contents.range(of: Data(forbidden.utf8)),
          "Session storage must not retain submitted secrets or wallpaper content", file: file,
          line: line)
      }
      XCTAssertNotEqual(url.lastPathComponent, "console.log", file: file, line: line)
    }
  }
}

/// Replaces only Valve runtime verification; PTY, child lifecycle, session and importer remain real.
struct ShellRuntimeProvider: SteamCMDRuntimeProviding {
  func resolve(executable: URL) throws -> SteamCMDRuntime {
    let root = executable.deletingLastPathComponent()
    try check(root)
    return SteamCMDRuntime(rootURL: root, executableURL: root.appendingPathComponent("steamcmd"))
  }

  func prepare(executable: URL, staging: URL) async throws -> URL {
    try Task.checkCancellation()
    let runtime = try resolve(executable: executable)
    try FileManager.default.createDirectory(
      at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let binary = staging.appendingPathComponent("steamcmd")
    try FileManager.default.copyItem(at: runtime.executableURL, to: binary)
    try check(staging)
    return binary
  }

  func validate(at root: URL) async throws { try check(root) }

  private func check(_ root: URL) throws {
    try Task.checkCancellation()
    let executable = root.appendingPathComponent("steamcmd")
    let attributes = try FileManager.default.attributesOfItem(atPath: executable.path)
    guard attributes[.type] as? FileAttributeType == .typeRegular,
      FileManager.default.isExecutableFile(atPath: executable.path),
      try String(contentsOf: executable, encoding: .utf8).hasPrefix("#!/bin/sh\n")
    else {
      throw WorkshopFailure(message: "The shell runtime fixture is missing or invalid")
    }
  }
}

/// Notes, each time the downloader is about to launch SteamCMD, whether its staging directory
/// is already kept out of backups. The directory is gone once the download ends.
final class StagingBackupProbe: SteamCMDRuntimeProviding, @unchecked Sendable {
  private let base = ShellRuntimeProvider()
  private let lock = NSLock()
  private var readings: [Bool] = []

  var excludedAtLaunch: [Bool] { lock.withLock { readings } }

  func resolve(executable: URL) throws -> SteamCMDRuntime { try base.resolve(executable: executable) }

  func prepare(executable: URL, staging: URL) async throws -> URL {
    try await base.prepare(executable: executable, staging: staging)
  }

  func validate(at root: URL) async throws {
    try await base.validate(at: root)
    let excluded = (try? root.resourceValues(forKeys: [.isExcludedFromBackupKey]))?.isExcludedFromBackup
    lock.withLock { readings.append(excluded == true) }
  }
}

/// The fixture exercises production filesystem/load-command validation, not Apple's trust policy.
struct FixtureSystemAssessment: SteamCMDProcessRunning {
  func run(
    executable: URL, arguments: [String], workingDirectory: URL, environment: [String: String],
    onOutput: @escaping @Sendable (Data) -> Void
  ) async throws -> Int32 {
    guard ["/usr/bin/codesign", "/usr/sbin/spctl"].contains(executable.path) else {
      throw WorkshopFailure(message: "The fixture must not execute a runtime program")
    }
    try Task.checkCancellation()
    return 0
  }
}

@MainActor
final class FixtureNetworkMonitor: ProcessNetworkMonitoring {
  var value: Double?
  var received: Int64?
  var startedPIDs: [Int32] = []
  /// How often the downloader has read `received`, so a test can wait for a reading.
  private(set) var receivedReadings = 0
  private(set) var stopCount = 0
  private var running = false

  func start(processID: Int32) {
    startedPIDs.append(processID)
    running = true
  }

  func rate(at time: TimeInterval) -> Double? { value }

  func bytesReceived() -> Int64? {
    receivedReadings += 1
    return received
  }

  func stop() async {
    if running { stopCount += 1 }
    running = false
  }
}

/// A disk whose free space the test decides, and which remembers what it was asked about.
final class FreeSpaceProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var free: Int64?
  private var asked: [URL] = []

  init(_ free: Int64?) { self.free = free }

  var available: Int64? {
    get { lock.withLock { free } }
    set { lock.withLock { free = newValue } }
  }

  var questions: [URL] { lock.withLock { asked } }

  var measure: @Sendable (URL) -> Int64? {
    { url in self.lock.withLock { self.asked.append(url); return self.free } }
  }
}

final class FailingNetworkRunner: SteamCMDProcessRunning, @unchecked Sendable {
  private let lock = NSLock()
  private var captured: (URL, [String])?

  var invocation: (URL, [String])? {
    lock.lock()
    defer { lock.unlock() }
    return captured
  }

  private func record(_ executable: URL, _ arguments: [String]) {
    lock.lock()
    defer { lock.unlock() }
    captured = (executable, arguments)
  }

  func run(
    executable: URL, arguments: [String], workingDirectory: URL, environment: [String: String],
    onOutput: @escaping @Sendable (Data) -> Void
  ) async throws -> Int32 {
    record(executable, arguments)
    throw WorkshopFailure(message: "fixture monitor failure")
  }
}
