import AppKit
import Darwin
import XCTest

@testable import WallpaperMachine

/// `WorkshopDownloadManager`: serial and parallel queues, slot limits and session conflicts.
@MainActor
final class DownloadQueueTests: DownloaderTestCase {
  func testSerialDownloadsKeepPromptsCancellationAndQueueIndependent() async throws {
    let root = try makeRuntime(
      """
      set -eu
      item=''
      while [ "$#" -gt 0 ]; do
          if [ "$1" = +workshop_download_item ]; then shift; shift; item="$1"; fi
          shift
      done
      printf 'password: '
      IFS= read -r password
      [ "$password" = "secret$item" ] || exit 10
      printf '\\nWaiting for user info...OK\\nDownloading item %s ... (25%%)\\n' "$item"
      touch "../running-$item"
      while [ ! -f "../release-$item" ]; do sleep 0.02; done
      content="steamapps/workshop/content/431960/$item"
      mkdir -p "$content"
      printf '{"type":"video","file":"movie.mp4"}' > "$content/project.json"
      printf 'content-%s' "$item" > "$content/movie.mp4"
      printf 'Success. Downloaded item %s\\n' "$item"
      """)
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = WorkshopDownloadManager(
      sessionDirectory: root.appendingPathComponent("SteamSession"),
      runtimeProvider: ShellRuntimeProvider())
    var imported = Set<String>()
    func enqueue(_ id: String) throws -> WorkshopDownload {
      let requested = WorkshopItem(
        id: id, title: "Queued \(id)", creator: "Test", summary: "", previewURL: nil,
        tags: ["Video"], size: 0, subscriptions: 0)
      manager.start(
        item: requested, username: "localtest",
        executable: root.appendingPathComponent("runtime/steamcmd"),
        library: root.appendingPathComponent("Library"), rememberSession: false
      ) {
        imported.insert(id)
      }
      return try XCTUnwrap(manager.download(for: id))
    }
    do {
      let first = try enqueue("1")
      let second = try enqueue("2")
      let third = try enqueue("3")
      let fourth = try enqueue("4")
      let fifth = try enqueue("5")
      XCTAssertTrue(
        try enqueue("1") === first, "A repeated click must not create a second transfer")
      try await waitUntil { first.worker.prompt == .password }
      XCTAssertTrue(second.isQueued)
      XCTAssertTrue(third.isQueued)
      XCTAssertTrue(fourth.isQueued)
      XCTAssertTrue(fifth.isQueued)
      first.worker.submitSecret("secret1")
      try await waitUntil { first.worker.status == String(localized: "Downloading Workshop files…") }
      XCTAssertNil(first.progress)
      XCTAssertNil(second.worker.prompt)
      XCTAssertNil(third.worker.prompt)
      manager.cancel(second)
      XCTAssertTrue(first.isPending)
      XCTAssertTrue(third.isQueued)
      XCTAssertTrue(fourth.isQueued)
      XCTAssertTrue(fifth.isQueued)
      manager.cancel(fifth)
      try Data().write(to: root.appendingPathComponent("release-1"))
      try await waitUntil { third.worker.prompt == .password }
      XCTAssertNil(fourth.worker.prompt)
      third.worker.submitSecret("secret3")
      try await waitUntil { third.worker.status == String(localized: "Downloading Workshop files…") }
      XCTAssertNil(third.progress)
      try Data().write(to: root.appendingPathComponent("release-3"))
      try await waitUntil { fourth.worker.prompt == .password }
      fourth.worker.submitSecret("secret4")
      try await waitUntil { fourth.worker.status == String(localized: "Downloading Workshop files…") }
      XCTAssertNil(fourth.progress)
      try Data().write(to: root.appendingPathComponent("release-4"))
      try await waitUntil { !manager.isRunning }
      XCTAssertEqual(imported, ["1", "3", "4"])
      for id in imported {
        XCTAssertEqual(
          try String(
            contentsOf: root.appendingPathComponent("Library/\(id)/movie.mp4"), encoding: .utf8),
          "content-\(id)")
      }
      XCTAssertFalse(
        FileManager.default.fileExists(atPath: root.appendingPathComponent("Library/2").path))
      XCTAssertFalse(
        FileManager.default.fileExists(atPath: root.appendingPathComponent("running-5").path))
      try assertNoStaging(in: root)
    } catch {
      await manager.shutdown()
      throw error
    }
  }

  /// The menu bar's line counts what is moving or waiting. A paused job stays pending until its
  /// session has closed, and the sign-in downloads nothing, so neither may count.
  func testMenuBarCountsOnlyTransfersThatAreMovingOrWaiting() async throws {
    let root = try makeRuntime(
      """
      set -eu
      printf 'password: '
      IFS= read -r password
      while :; do sleep 0.02; done
      """)
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = WorkshopDownloadManager(
      sessionDirectory: root.appendingPathComponent("SteamSession"),
      runtimeProvider: ShellRuntimeProvider())
    let executable = root.appendingPathComponent("runtime/steamcmd")
    for id in ["1", "2"] {
      manager.start(
        item: WorkshopItem(
          id: id, title: "Queued \(id)", creator: "Test", summary: "", previewURL: nil,
          tags: ["Video"], size: 0, subscriptions: 0),
        username: "localtest", executable: executable,
        library: root.appendingPathComponent("Library"), rememberSession: false, onImported: {})
    }
    manager.signIn(username: "localtest", executable: executable, root: root, rememberSession: false)
    do {
      let first = try XCTUnwrap(manager.download(for: "1"))
      let second = try XCTUnwrap(manager.download(for: "2"))
      try await waitUntil { first.worker.prompt == .password }
      XCTAssertTrue(second.isQueued)
      XCTAssertNotNil(manager.signIn, "the sign-in job is waiting in line too")

      XCTAssertEqual(manager.inProgressTransfers.count, 2, "the running job and the waiting one, not the sign-in")
      XCTAssertEqual(StatusMenuModel.DownloadActivity.make(manager.inProgressTransfers),
                     StatusMenuModel.DownloadActivity(count: 2, percent: nil),
                     "neither has byte counts yet, so no percent is guessed")

      manager.pause(second)
      XCTAssertEqual(manager.inProgressTransfers.count, 1, "a paused job is out of the count")

      manager.pause(first)
      XCTAssertTrue(first.isPending, "a pausing job still holds its slot until its session has closed")
      XCTAssertTrue(manager.inProgressTransfers.isEmpty)
      XCTAssertNil(StatusMenuModel.DownloadActivity.make(manager.inProgressTransfers))

      if let signIn = manager.signIn { manager.cancel(signIn) }
      await manager.shutdown()
      XCTAssertTrue(manager.inProgressTransfers.isEmpty)
    } catch {
      await manager.shutdown()
      throw error
    }
  }

  func testQueuedDownloadReusesSignInSavedByPreviousJob() async throws {
    let root = try makeSessionRuntime()
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = WorkshopDownloadManager(
      sessionDirectory: root.appendingPathComponent("SteamSession"),
      runtimeProvider: ShellRuntimeProvider())
    for id in ["123456", "234567"] {
      let requested = WorkshopItem(
        id: id, title: id, creator: "Test", summary: "", previewURL: nil, tags: ["Video"], size: 0,
        subscriptions: 0)
      manager.start(
        item: requested, username: "localtest",
        executable: root.appendingPathComponent("runtime/steamcmd"),
        library: root.appendingPathComponent("Library"), onImported: {})
    }
    do {
      let first = try XCTUnwrap(manager.download(for: "123456"))
      let second = try XCTUnwrap(manager.download(for: "234567"))
      try await authenticate(first.worker)
      try await waitUntil { !manager.isRunning || second.worker.prompt != nil }
      XCTAssertNil(
        second.worker.prompt, "Queued work must restore the sign-in saved by the completed job")
      XCTAssertEqual(
        try String(
          contentsOf: root.appendingPathComponent("Library/234567/movie.mp4"), encoding: .utf8),
        "cached:localtest:234567")
      try assertPrivateSession(in: root)
    } catch {
      await manager.shutdown()
      throw error
    }
  }

  /// A batch signs in once. Siblings wait through the prompt, start silently from the sign-in
  /// saved the moment Steam accepts it, and fill the slots; the rest wait for a free slot.
  func testAcceptedSignInLetsSiblingsRunSideBySideUpToTheSlotLimit() async throws {
    let root = try makeParallelRuntime()
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = WorkshopDownloadManager(
      sessionDirectory: root.appendingPathComponent("SteamSession"),
      runtimeProvider: ShellRuntimeProvider(), maximumConcurrentDownloads: 2)
    var imported = Set<String>()
    let jobs = try ["1", "2", "3", "4"].map { id in
      manager.start(
        item: WorkshopItem(
          id: id, title: "Batch \(id)", creator: "Test", summary: "", previewURL: nil,
          tags: ["Video"], size: 0, subscriptions: 0),
        username: "localtest", executable: root.appendingPathComponent("runtime/steamcmd"),
        library: root.appendingPathComponent("Library")
      ) { imported.insert(id) }
      return try XCTUnwrap(manager.download(for: id))
    }
    let started = { (id: String) in
      FileManager.default.fileExists(atPath: root.appendingPathComponent("running-\(id)").path)
    }
    do {
      try await waitUntil { jobs[0].worker.prompt == .password }
      XCTAssertEqual(manager.activeCount, 1)
      XCTAssertTrue(jobs[1...].allSatisfy(\.isQueued), "Prompts must not pile up")
      XCTAssertEqual(jobs[1].hold, .signIn)
      jobs[0].worker.submitSecret("local-password")
      try await waitUntil { started("1") && started("2") }
      XCTAssertEqual(manager.activeCount, 2)
      XCTAssertNil(jobs[1].worker.prompt, "A sibling restores the accepted sign-in silently")
      XCTAssertTrue(jobs[2].isQueued)
      XCTAssertEqual(jobs[2].hold, .slot)
      XCTAssertTrue(jobs[3].isQueued)
      XCTAssertFalse(started("3"))
      try Data().write(to: root.appendingPathComponent("release-1"))
      try await waitUntil { started("3") }
      XCTAssertEqual(manager.activeCount, 2)
      XCTAssertTrue(jobs[3].isQueued)
      XCTAssertFalse(started("4"))
      for id in ["2", "3"] { try Data().write(to: root.appendingPathComponent("release-\(id)")) }
      try await waitUntil { started("4") }
      try Data().write(to: root.appendingPathComponent("release-4"))
      try await waitUntil { !manager.isRunning }
      XCTAssertEqual(imported, ["1", "2", "3", "4"])
      for id in imported {
        XCTAssertEqual(
          try String(
            contentsOf: root.appendingPathComponent("Library/\(id)/movie.mp4"), encoding: .utf8),
          "content-\(id)")
      }
      XCTAssertEqual(manager.savedAccount, "localtest")
      XCTAssertFalse(manager.sessionConflictDetected)
      try assertNoStaging(in: root)
      try assertPrivateSession(in: root)
    } catch {
      await manager.shutdown()
      throw error
    }
  }

  /// With a sign-in already saved, a batch does not wait for its first job to get through
  /// Steam's login: every job restores the saved sign-in itself and they start together.
  func testSavedSignInStartsAWholeBatchAtOnceWithoutWaitingForTheFirstLogin() async throws {
    let root = try makeParallelRuntime()
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = WorkshopDownloadManager(
      sessionDirectory: root.appendingPathComponent("SteamSession"),
      runtimeProvider: ShellRuntimeProvider())
    var imported = Set<String>()
    func enqueue(_ id: String) throws -> WorkshopDownload {
      manager.start(
        item: WorkshopItem(
          id: id, title: "Batch \(id)", creator: "Test", summary: "", previewURL: nil,
          tags: ["Video"], size: 0, subscriptions: 0),
        username: "localtest", executable: root.appendingPathComponent("runtime/steamcmd"),
        library: root.appendingPathComponent("Library")
      ) { imported.insert(id) }
      return try XCTUnwrap(manager.download(for: id))
    }
    let started = { (id: String) in
      FileManager.default.fileExists(atPath: root.appendingPathComponent("running-\(id)").path)
    }
    do {
      let first = try enqueue("1")
      try await authenticate(first.worker, guardCode: false)
      try Data().write(to: root.appendingPathComponent("release-1"))
      try await waitUntil { !manager.isRunning }
      XCTAssertEqual(manager.savedAccount, "localtest")

      let batch = try ["2", "3", "4"].map(enqueue)
      try await waitUntil { started("2") && started("3") && started("4") }
      XCTAssertEqual(manager.activeCount, 3, "Nothing waits behind the first job's login")
      XCTAssertTrue(batch.allSatisfy { $0.worker.prompt == nil })
      for id in ["2", "3", "4"] { try Data().write(to: root.appendingPathComponent("release-\(id)")) }
      try await waitUntil { !manager.isRunning }
      XCTAssertEqual(imported, ["1", "2", "3", "4"])
      try assertNoStaging(in: root)
      try assertPrivateSession(in: root)
    } catch {
      await manager.shutdown()
      throw error
    }
  }

  /// The ceiling can change while work is queued: raising it starts waiting jobs at once, and
  /// lowering it never stops a running transfer, it only holds back what has not started.
  func testChangingTheCeilingStartsQueuedWorkAndNeverStopsARunningTransfer() async throws {
    let root = try makeParallelRuntime()
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = WorkshopDownloadManager(
      sessionDirectory: root.appendingPathComponent("SteamSession"),
      runtimeProvider: ShellRuntimeProvider(), maximumConcurrentDownloads: 1)
    var imported = Set<String>()
    func enqueue(_ id: String) throws -> WorkshopDownload {
      manager.start(
        item: WorkshopItem(
          id: id, title: "Ceiling \(id)", creator: "Test", summary: "", previewURL: nil,
          tags: ["Video"], size: 0, subscriptions: 0),
        username: "localtest", executable: root.appendingPathComponent("runtime/steamcmd"),
        library: root.appendingPathComponent("Library")
      ) { imported.insert(id) }
      return try XCTUnwrap(manager.download(for: id))
    }
    let started = { (id: String) in
      FileManager.default.fileExists(atPath: root.appendingPathComponent("running-\(id)").path)
    }
    do {
      let first = try enqueue("1")
      try await authenticate(first.worker, guardCode: false)
      try Data().write(to: root.appendingPathComponent("release-1"))
      try await waitUntil { !manager.isRunning }

      let batch = try ["2", "3", "4", "5"].map(enqueue)
      try await waitUntil { started("2") }
      XCTAssertEqual(manager.activeCount, 1)
      XCTAssertTrue(batch[1...].allSatisfy { $0.isQueued && $0.hold == .slot })

      manager.setMaximumConcurrentDownloads(3)
      try await waitUntil { started("3") && started("4") }
      XCTAssertEqual(manager.activeCount, 3)
      XCTAssertTrue(batch[3].isQueued)

      manager.setMaximumConcurrentDownloads(1)
      XCTAssertEqual(manager.activeCount, 3, "Lowering the ceiling must not stop running transfers")
      try Data().write(to: root.appendingPathComponent("release-2"))
      try await waitUntil { manager.activeCount == 2 }
      XCTAssertTrue(batch[3].isQueued, "Queued work waits until the running count drops below the new ceiling")
      XCTAssertFalse(started("5"))
      for id in ["3", "4"] { try Data().write(to: root.appendingPathComponent("release-\(id)")) }
      try await waitUntil { started("5") }
      try Data().write(to: root.appendingPathComponent("release-5"))
      try await waitUntil { !manager.isRunning }
      XCTAssertEqual(imported, ["1", "2", "3", "4", "5"])

      manager.setMaximumConcurrentDownloads(99)
      XCTAssertEqual(
        manager.maximumConcurrentDownloads, WorkshopDownloadManager.concurrentDownloadRange.upperBound)
      manager.setMaximumConcurrentDownloads(0)
      XCTAssertEqual(
        manager.maximumConcurrentDownloads, WorkshopDownloadManager.concurrentDownloadRange.lowerBound)
      try assertNoStaging(in: root)
    } catch {
      await manager.shutdown()
      throw error
    }
  }

  /// Steam ending a session for another of our own sign-ins means the account cannot run two
  /// at once: the ended job goes back in line behind the running one and the queue turns serial.
  func testSessionConflictSerialisesTheQueueAndRetriesTheEndedJob() async throws {
    let root = try makeParallelRuntime(
      conflict: """
        if [ -f ../running-1 ] && [ "$item" = 2 ] && [ ! -f ../conflicted ]; then
            touch ../conflicted
            printf 'FAILED (Logged in elsewhere)\\n'
            exit 1
        fi
        """)
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = WorkshopDownloadManager(
      sessionDirectory: root.appendingPathComponent("SteamSession"),
      runtimeProvider: ShellRuntimeProvider())
    var imported = Set<String>()
    let jobs = try ["1", "2"].map { id in
      manager.start(
        item: WorkshopItem(
          id: id, title: "Batch \(id)", creator: "Test", summary: "", previewURL: nil,
          tags: ["Video"], size: 0, subscriptions: 0),
        username: "localtest", executable: root.appendingPathComponent("runtime/steamcmd"),
        library: root.appendingPathComponent("Library")
      ) { imported.insert(id) }
      return try XCTUnwrap(manager.download(for: id))
    }
    let started = { (id: String) in
      FileManager.default.fileExists(atPath: root.appendingPathComponent("running-\(id)").path)
    }
    do {
      try await authenticate(jobs[0].worker, guardCode: false)
      try await waitUntil {
        FileManager.default.fileExists(atPath: root.appendingPathComponent("conflicted").path)
          && jobs[1].isQueued
      }
      XCTAssertTrue(jobs[1].worker.endedBySessionConflict)
      XCTAssertTrue(manager.sessionConflictDetected)
      XCTAssertEqual(manager.slotLimit, 1)
      XCTAssertTrue(jobs[1].isPending)
      XCTAssertNil(jobs[1].errorMessage, "A job back in line for a retry is not a failure")
      XCTAssertFalse(jobs[1].isCancelled)
      try await Task.sleep(for: .milliseconds(300))
      XCTAssertFalse(started("2"), "The retry waits for the running session to end")
      XCTAssertEqual(manager.activeCount, 1)
      try Data().write(to: root.appendingPathComponent("release-1"))
      try await waitUntil { started("2") }
      try Data().write(to: root.appendingPathComponent("release-2"))
      try await waitUntil { !manager.isRunning }
      XCTAssertEqual(imported, ["1", "2"])
      XCTAssertNil(jobs[1].errorMessage)
      XCTAssertNil(jobs[1].worker.errorMessage)
      try assertNoStaging(in: root)
    } catch {
      await manager.shutdown()
      throw error
    }
  }

  func testFailedDownloadReleasesSlotAndShutdownNeverLaunchesQueuedWork() async throws {
    let root = try makeRuntime(
      """
      set -eu
      item=''
      while [ "$#" -gt 0 ]; do
          if [ "$1" = +workshop_download_item ]; then shift; shift; item="$1"; fi
          shift
      done
      touch "../launched-$item"
      if [ "$item" = 1 ]; then printf 'FAILED (Invalid Password)\\n'; exit 1; fi
      printf 'password: '
      IFS= read -r password
      """)
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = WorkshopDownloadManager(
      sessionDirectory: root.appendingPathComponent("SteamSession"),
      runtimeProvider: ShellRuntimeProvider())
    for id in ["1", "2", "3"] {
      let requested = WorkshopItem(
        id: id, title: id, creator: "Test", summary: "", previewURL: nil, tags: ["Video"], size: 0,
        subscriptions: 0)
      manager.start(
        item: requested, username: "localtest",
        executable: root.appendingPathComponent("runtime/steamcmd"),
        library: root.appendingPathComponent("Library"), rememberSession: false, onImported: {})
    }
    do {
      try await waitUntil { manager.download(for: "2")?.worker.prompt == .password }
      XCTAssertTrue(manager.download(for: "1")?.worker.canRetryAuthentication == true)
      XCTAssertTrue(manager.download(for: "3")?.isQueued == true)
      await manager.shutdown()
      XCTAssertFalse(manager.isRunning)
      XCTAssertFalse(
        FileManager.default.fileExists(atPath: root.appendingPathComponent("launched-3").path))
      XCTAssertFalse(
        FileManager.default.fileExists(atPath: root.appendingPathComponent("Library").path))
      try assertNoStaging(in: root)
    } catch {
      await manager.shutdown()
      throw error
    }
  }

  func testPendingDownloadsPreventSessionPreferenceChanges() async throws {
    let root = try makeSessionRuntime()
    defer { try? FileManager.default.removeItem(at: root) }
    let initial = startDownload(in: root)
    try await authenticate(initial)
    try await assertImported(initial, in: root, itemID: item.id)
    try setSessionMode("cancel", in: root)
    let manager = WorkshopDownloadManager(
      sessionDirectory: root.appendingPathComponent("SteamSession"),
      runtimeProvider: ShellRuntimeProvider())
    manager.start(
      item: item, username: "localtest",
      executable: root.appendingPathComponent("runtime/steamcmd"),
      library: root.appendingPathComponent("OtherLibrary"), onImported: {})
    do {
      try await waitUntil { manager.download(for: self.item.id)?.worker.status == String(localized: "Downloading Workshop files…") }
      XCTAssertNil(manager.download(for: item.id)?.progress)
      manager.forgetSavedAccount()
      XCTAssertNotNil(manager.errorMessage)
      XCTAssertEqual(manager.savedAccount, "localtest")
      let other = WorkshopItem(
        id: "234567", title: "Opt out", creator: "Test", summary: "", previewURL: nil,
        tags: ["Video"], size: 0, subscriptions: 0)
      manager.start(
        item: other, username: "localtest",
        executable: root.appendingPathComponent("runtime/steamcmd"),
        library: root.appendingPathComponent("OtherLibrary"), rememberSession: false, onImported: {}
      )
      XCTAssertNil(manager.download(for: other.id))
      await manager.shutdown()
      try assertPrivateSession(in: root)
      manager.forgetSavedAccount()
      XCTAssertNil(manager.savedAccount)
      try assertNoSavedCredentials(in: root)
    } catch {
      await manager.shutdown()
      throw error
    }
  }

  func testLateCachedCredentialRejectionCannotEraseNewerSession() async throws {
    let root = try makeSessionRuntime()
    defer { try? FileManager.default.removeItem(at: root) }
    let initial = startDownload(in: root)
    try await authenticate(initial)
    try await assertImported(initial, in: root, itemID: "123456")
    let rejectingRuntime = try makeRuntime(
      """
      [ -f config/config.vdf ] || exit 10
      printf 'Logging in using cached credentials\\n'
      touch ../old-session-restored
      while [ ! -f ../reject-old-session ]; do sleep 0.02; done
      printf 'FAILED (Invalid cached credentials)\\n'
      exit 1
      """)
    defer { try? FileManager.default.removeItem(at: rejectingRuntime) }
    let rejected = WorkshopDownloader(
      sessionDirectory: root.appendingPathComponent("SteamSession"),
      runtimeProvider: ShellRuntimeProvider())
    rejected.start(
      item: item, username: "localtest",
      executable: rejectingRuntime.appendingPathComponent("runtime/steamcmd"),
      library: root.appendingPathComponent("OtherLibrary"), onImported: {})
    do {
      try await waitUntil {
        FileManager.default.fileExists(
          atPath: root.appendingPathComponent("old-session-restored").path)
      }
      let renewed = startDownload(in: root, itemID: "234567")
      try await assertImported(renewed, in: root, itemID: "234567")
      try Data().write(to: root.appendingPathComponent("reject-old-session"))
      try await waitForStop(rejected)
      XCTAssertTrue(rejected.canRetryAuthentication)
      XCTAssertEqual(rejected.savedAccount, "localtest")
      let next = startDownload(in: root, itemID: "345678")
      try await assertImported(next, in: root, itemID: "345678")
    } catch {
      await rejected.shutdown()
      throw error
    }
  }

  /// The wake observer belongs to the manager's lifetime, not the process's: one that goes away
  /// without `shutdown()` takes its observer with it.
  func testAManagerThatIsDroppedRemovesItsWakeObserver() throws {
    let root = try makeParallelRuntime()
    defer { try? FileManager.default.removeItem(at: root) }
    let center = ObserverCountingCenter()
    do {
      let manager = WorkshopDownloadManager(
        sessionDirectory: root.appendingPathComponent("SteamSession"),
        runtimeProvider: ShellRuntimeProvider(), wakeCenter: center)
      XCTAssertEqual(center.added, 1)
      XCTAssertEqual(center.removed, 0)
      XCTAssertTrue(manager.downloads.isEmpty)
    }
    XCTAssertEqual(center.removed, 1, "Nothing is left registered once the manager is gone")
  }

  /// Waking from sleep makes every running transfer check that bytes still arrive. A job that
  /// is only waiting for a slot has no connection to check.
  func testWakeNotificationReachesRunningTransfersOnly() async throws {
    let root = try makeParallelRuntime()
    defer { try? FileManager.default.removeItem(at: root) }
    let center = NotificationCenter()
    let manager = WorkshopDownloadManager(
      sessionDirectory: root.appendingPathComponent("SteamSession"),
      runtimeProvider: ShellRuntimeProvider(), maximumConcurrentDownloads: 1,
      networkMonitorFactory: { FixtureNetworkMonitor() }, wakeCenter: center)
    func enqueue(_ id: String) throws -> WorkshopDownload {
      manager.start(
        item: WorkshopItem(
          id: id, title: "Wake \(id)", creator: "Test", summary: "", previewURL: nil,
          tags: ["Video"], size: 0, subscriptions: 0),
        username: "localtest", executable: root.appendingPathComponent("runtime/steamcmd"),
        library: root.appendingPathComponent("Library")
      ) {}
      return try XCTUnwrap(manager.download(for: id))
    }
    do {
      let running = try enqueue("1")
      let waiting = try enqueue("2")
      try await authenticate(running.worker, guardCode: false)
      try await waitUntil { running.worker.phase == .transferring }
      XCTAssertTrue(waiting.isQueued)
      XCTAssertNil(running.worker.resumedAt)
      center.post(name: NSWorkspace.didWakeNotification, object: nil)
      try await waitUntil { running.worker.resumedAt != nil }
      XCTAssertNil(waiting.worker.resumedAt)
      XCTAssertTrue(waiting.isQueued)
      await manager.shutdown()
    } catch {
      await manager.shutdown()
      throw error
    }
  }
}

/// Counts the observers a notification center is given and takes back.
private final class ObserverCountingCenter: NotificationCenter, @unchecked Sendable {
  private(set) var added = 0
  private(set) var removed = 0

  override func addObserver(
    forName name: NSNotification.Name?, object: Any?, queue: OperationQueue?,
    using block: @escaping @Sendable (Notification) -> Void
  ) -> NSObjectProtocol {
    added += 1
    return super.addObserver(forName: name, object: object, queue: queue, using: block)
  }

  override func removeObserver(_ observer: Any) {
    removed += 1
    super.removeObserver(observer)
  }
}
