import XCTest

@testable import WallpaperMachine

@MainActor
final class WorkshopDownloadPersistenceTests: DownloaderTestCase {
  func testCheckpointReplacementAndInterruptedPublicationRecoverNewestContent() throws {
    let files = FileManager.default
    for interruption in ["none", "pending", "backup", "published"] {
      let root = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? files.removeItem(at: root) }
      let staging = root.appendingPathComponent("staging")
      let checkpoint = root.appendingPathComponent("123456")
      let pending = root.appendingPathComponent(".partial-123456")
      let backup = root.appendingPathComponent(".previous-123456")
      func write(_ directory: URL, _ value: String) throws {
        let content = directory.appendingPathComponent("steamapps/part")
        try files.createDirectory(at: content.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(value.utf8).write(to: content)
      }
      try write(staging, "old")
      try WorkshopDownloadCheckpoint.save(from: staging, to: checkpoint)
      try write(staging, "new")
      if interruption == "none" {
        try WorkshopDownloadCheckpoint.save(from: staging, to: checkpoint)
      } else {
        try files.createDirectory(at: pending, withIntermediateDirectories: true)
        try files.moveItem(at: staging.appendingPathComponent("steamapps"), to: pending.appendingPathComponent("steamapps"))
        if interruption != "pending" { try files.moveItem(at: checkpoint, to: backup) }
        if interruption == "published" { try files.moveItem(at: pending, to: checkpoint) }
      }
      try WorkshopDownloadCheckpoint.restore(from: checkpoint, to: staging)
      XCTAssertEqual(try Data(contentsOf: staging.appendingPathComponent("steamapps/part")), Data("new".utf8), interruption)
      for directory in [checkpoint, pending, backup] {
        XCTAssertFalse(files.fileExists(atPath: directory.path), interruption)
      }
    }
  }

  func testCheckpointCancelRemovesInterruptedPublication() throws {
    let files = FileManager.default
    let root = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? files.removeItem(at: root) }
    for name in ["123456", ".partial-123456", ".previous-123456"] {
      let directory = root.appendingPathComponent(name)
      try files.createDirectory(at: directory, withIntermediateDirectories: true)
      try Data("partial".utf8).write(to: directory.appendingPathComponent("part"))
    }
    try WorkshopDownloadCheckpoint.remove(at: root.appendingPathComponent("123456"))
    XCTAssertTrue(try files.contentsOfDirectory(atPath: root.path).isEmpty)
  }

  func testPauseRestoresContentAndQueueOrderWithoutKeepingThePrivateRuntime() async throws {
    let root = try makeRuntime(
      """
      set -eu
      item=''
      while [ "$#" -gt 0 ]; do
        if [ "$1" = +workshop_download_item ]; then shift; shift; item="$1"; fi
        shift
      done
      printf 'Waiting for user info...OK\\nDownloading item %s ...\\n' "$item"
      partial="steamapps/workshop/downloads/431960/$item.partial"
      if [ ! -f "$partial" ]; then
        mkdir -p "steamapps/workshop/downloads/431960" config
        printf 'partial-' > "$partial"
        printf 'fixture-private-token' > config/config.vdf
        touch "../ready-$item"
        while :; do sleep 0.02; done
      fi
      [ "$(cat "$partial")" = 'partial-' ] || exit 21
      touch "../resumed-$item"
      content="steamapps/workshop/content/431960/$item"
      mkdir -p "$content"
      printf '{"type":"video","file":"movie.mp4"}' > "$content/project.json"
      cat "$partial" > "$content/movie.mp4"
      printf 'finished' >> "$content/movie.mp4"
      printf 'Success. Downloaded item %s\\n' "$item"
      """)
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent("Downloads")
    func manager() -> WorkshopDownloadManager {
      let manager = WorkshopDownloadManager(sessionDirectory: root.appendingPathComponent("SteamSession"),
        runtimeProvider: ShellRuntimeProvider(), maximumConcurrentDownloads: 1)
      manager.configurePersistence(at: directory)
      return manager
    }
    func enqueue(_ id: String, on manager: WorkshopDownloadManager) {
      let item = WorkshopItem(id: id, title: id, creator: "Fixture", summary: "", previewURL: nil,
        tags: ["Video"], size: 0, subscriptions: 0)
      manager.start(item: item, username: "localtest", executable: root.appendingPathComponent("runtime/steamcmd"),
        library: root.appendingPathComponent("Library"), rememberSession: false, onImported: {})
    }
    let first = manager()
    enqueue("123456", on: first)
    enqueue("123457", on: first)
    do {
      try await waitUntil { FileManager.default.fileExists(atPath: root.appendingPathComponent("ready-123456").path) }
      await first.shutdown()
      XCTAssertTrue(first.downloads.allSatisfy(\.isPaused))
      XCTAssertFalse(first.isRunning)
      try assertNoStaging(in: root)
      XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("123456/steamapps/workshop/downloads/431960/123456.partial")), Data("partial-".utf8))
      XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("123456/config").path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("123456/steamcmd").path))
      let restored = manager()
      XCTAssertEqual(restored.downloads.map(\.id), ["123456", "123457"])
      XCTAssertTrue(restored.downloads.allSatisfy(\.isPaused))
      restored.clearCompleted()
      XCTAssertEqual(restored.downloads.count, 2)
      enqueue("123456", on: restored)
      try await waitUntil { !restored.isRunning }
      XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Library/123456/movie.mp4")), Data("partial-finished".utf8))
      XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("123456").path))
      XCTAssertTrue(restored.downloads[1].isPaused)
      restored.cancel(restored.downloads[1])
      XCTAssertTrue(manager().downloads.isEmpty)
    } catch {
      await first.shutdown()
      throw error
    }
  }
  func testPartialDownloadsKeptForLaterStayOutOfBackups() async throws {
    let root = try makeRuntime("mkdir -p steamapps/workshop/downloads/431960; printf 'part' > steamapps/workshop/downloads/431960/part; touch ../ready; while :; do sleep 0.02; done")
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent("Downloads/Workshop")
    let manager = WorkshopDownloadManager(sessionDirectory: root.appendingPathComponent("SteamSession"),
      runtimeProvider: ShellRuntimeProvider(), maximumConcurrentDownloads: 1)
    manager.configurePersistence(at: directory)
    manager.start(item: item, username: "localtest", executable: root.appendingPathComponent("runtime/steamcmd"),
      library: root.appendingPathComponent("Library"), rememberSession: false, onImported: {})
    do {
      try await waitUntil { FileManager.default.fileExists(atPath: root.appendingPathComponent("ready").path) }
      await manager.shutdown()
      XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("123456/steamapps").path),
        "the pause must have kept the partial download")
      XCTAssertTrue(directory.isKeptOutOfBackups, "the folder holding every kept download is skipped by Time Machine")
      XCTAssertFalse(root.appendingPathComponent("Downloads").isKeptOutOfBackups, "the request list next to it is tiny and stays")
    } catch {
      await manager.shutdown()
      throw error
    }
  }

  func testCancelDuringPausedCleanupKeepsCancelledStateAndDiscardsPartialContent() async throws {
    let root = try makeRuntime("mkdir -p steamapps/workshop/downloads/431960; printf 'part' > steamapps/workshop/downloads/431960/part; touch ../ready; while :; do sleep 0.02; done")
    defer { try? FileManager.default.removeItem(at: root) }
    let checkpoint = root.appendingPathComponent("Downloads/123456")
    let monitor = DownloadCleanupGate()
    let worker = WorkshopDownloader(sessionDirectory: root.appendingPathComponent("SteamSession"),
      runtimeProvider: ShellRuntimeProvider(), networkMonitor: monitor, checkpointDirectory: checkpoint)
    worker.start(item: item, username: "localtest", executable: root.appendingPathComponent("runtime/steamcmd"),
      library: root.appendingPathComponent("Library"), rememberSession: false, onImported: {})
    do {
      try await waitUntil { FileManager.default.fileExists(atPath: root.appendingPathComponent("ready").path) }
      worker.pause()
      try await waitUntil { monitor.waiting }
      worker.cancel()
      monitor.release()
      await worker.shutdown()
      XCTAssertTrue(worker.wasCancelled)
      XCTAssertFalse(worker.isRunning)
      XCTAssertFalse(FileManager.default.fileExists(atPath: checkpoint.path))
      try assertNoStaging(in: root)
    } catch {
      monitor.release()
      await worker.shutdown()
      throw error
    }
  }

  func testExplicitPauseWinsOverASessionConflictReportedDuringCleanup() async throws {
    let root = try makeParallelRuntime(conflict: """
      if [ "$item" = 2 ]; then
        printf 'FAILED (Logged in elsewhere)\\n'
        while :; do sleep 0.02; done
      fi
      """)
    defer { try? FileManager.default.removeItem(at: root) }
    let cleanup = DownloadCleanupGate()
    var monitorCount = 0
    let manager = WorkshopDownloadManager(sessionDirectory: root.appendingPathComponent("SteamSession"),
      runtimeProvider: ShellRuntimeProvider(), networkMonitorFactory: {
        monitorCount += 1
        if monitorCount == 2 { return cleanup }
        return FixtureNetworkMonitor()
      })
    let jobs = try ["1", "2"].map { id in
      manager.start(item: WorkshopItem(id: id, title: id, creator: "Fixture", summary: "", previewURL: nil,
        tags: ["Video"], size: 0, subscriptions: 0), username: "localtest",
        executable: root.appendingPathComponent("runtime/steamcmd"), library: root.appendingPathComponent("Library"), onImported: {})
      return try XCTUnwrap(manager.download(for: id))
    }
    do {
      try await authenticate(jobs[0].worker, guardCode: false)
      try await waitUntil { cleanup.waiting }
      XCTAssertTrue(jobs[1].worker.endedBySessionConflict)
      manager.pause(jobs[1])
      cleanup.release()
      try await waitUntil { !jobs[1].isPending }
      XCTAssertTrue(jobs[1].worker.endedBySessionConflict, "the fixture reports a conflict while its paused session closes")
      XCTAssertTrue(jobs[1].isPaused)
      XCTAssertFalse(jobs[1].isQueued)
      XCTAssertFalse(jobs[1].retriesAfterSessionConflict)
      manager.cancel(jobs[0])
      await manager.shutdown()
    } catch {
      cleanup.release()
      await manager.shutdown()
      throw error
    }
  }

}


@MainActor
private final class DownloadCleanupGate: ProcessNetworkMonitoring {
  private var continuation: CheckedContinuation<Void, Never>?
  private var released = false
  private(set) var waiting = false
  func start(processID: Int32) {}
  func rate(at time: TimeInterval) -> Double? { nil }
  func bytesReceived() -> Int64? { nil }
  func stop() async {
    guard !released else { return }
    waiting = true
    await withCheckedContinuation { continuation = $0 }
    waiting = false
  }
  func release() {
    released = true
    continuation?.resume()
    continuation = nil
  }
}
