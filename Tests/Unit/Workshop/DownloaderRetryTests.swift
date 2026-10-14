import XCTest

@testable import WallpaperMachine

/// A connection that drops after Steam accepted the sign-in is retried a few times in the same
/// staging; everything the user has to decide is not. The shell runtime counts its launches in
/// `../attempts` and prints `$attempt` as the number of the launch that is running.
@MainActor
final class DownloaderRetryTests: DownloaderTestCase {
  private let countLaunch = """
    attempt=$(( $(cat ../attempts 2>/dev/null || echo 0) + 1 ))
    printf '%s' "$attempt" > ../attempts
    """

  /// What SteamCMD prints once it has accepted the sign-in and starts on the item.
  private let signedIn = "printf 'Waiting for user info...OK\\nDownloading item 123456 ...\\n'"

  private let deliverItem = """
    mkdir -p steamapps/workshop/content/431960/123456
    printf '{"type":"video","file":"movie.mp4"}' > steamapps/workshop/content/431960/123456/project.json
    printf 'content' > steamapps/workshop/content/431960/123456/movie.mp4
    printf 'Success. Downloaded item 123456\\n'
    """

  private func makeRetryRuntime(_ body: String) throws -> URL {
    try makeRuntime(
      """
      \(countLaunch)
      \(signedIn)
      \(body)
      """)
  }

  private func attempts(in root: URL) -> Int {
    (try? String(contentsOf: root.appendingPathComponent("attempts"), encoding: .utf8))
      .flatMap { Int($0) } ?? 0
  }

  func testTimeoutTwiceThenSuccessCompletesWithoutAskingAgain() async throws {
    // The first launch needs a password; a retry must find the sign-in it saved in staging, so
    // a launch that is asked again would hang here on its prompt.
    let root = try makeRuntime(
      """
      \(countLaunch)
      if [ -f config/config.vdf ]; then
          printf 'Logging in using cached credentials\\n'
      else
          printf 'password: '
          IFS= read -r password
          mkdir -p config
          printf 'token' > config/config.vdf
      fi
      printf '\\nWaiting for user info...OK\\nDownloading item 123456 ...\\n'
      if [ "$attempt" -lt 3 ]; then
          printf 'ERROR! Download item 123456 failed (Timeout).\\n'
          exit 1
      fi
      \(deliverItem)
      """)
    defer { try? FileManager.default.removeItem(at: root) }
    let downloader = startDownload(in: root)
    try await authenticate(downloader, guardCode: false)
    try await assertImported(downloader, in: root, itemID: "123456")
    XCTAssertEqual(attempts(in: root), 3)
    XCTAssertTrue(downloader.completedSuccessfully)
    XCTAssertNil(downloader.errorMessage)
    XCTAssertNil(downloader.prompt)
    XCTAssertEqual(downloader.retryAttempt, 2)
    try assertNoStaging(in: root)
  }

  func testRetriesAreBounded() async throws {
    let root = try makeRetryRuntime("printf 'ERROR! Download item 123456 failed (Timeout).\\n'; exit 1")
    defer { try? FileManager.default.removeItem(at: root) }
    let downloader = startDownload(in: root)
    try await waitForStop(downloader)
    XCTAssertEqual(attempts(in: root), 4, "The first launch and three retries")
    XCTAssertNotNil(downloader.errorMessage)
    XCTAssertEqual(downloader.retryAttempt, 3)
    XCTAssertFalse(downloader.completedSuccessfully)
    XCTAssertNil(downloader.downloadedID)
    XCTAssertFalse(downloader.canRetryAuthentication, "A dropped connection is not a sign-in failure")
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Library/123456").path))
    try assertNoStaging(in: root)
  }

  func testNoRetriesAreMadeWhenNoneAreAllowed() async throws {
    let root = try makeRetryRuntime("printf 'ERROR! Download item 123456 failed (Timeout).\\n'; exit 1")
    defer { try? FileManager.default.removeItem(at: root) }
    let downloader = startDownload(in: root, retryDelays: [])
    try await waitForStop(downloader)
    XCTAssertEqual(attempts(in: root), 1)
    XCTAssertNotNil(downloader.errorMessage)
  }

  func testAccessDeniedIsNeverRetried() async throws {
    let root = try makeRetryRuntime("printf 'ERROR! Download item 123456 failed (Access Denied).\\n'; exit 1")
    defer { try? FileManager.default.removeItem(at: root) }
    let downloader = startDownload(in: root)
    try await waitForStop(downloader)
    XCTAssertEqual(attempts(in: root), 1)
    XCTAssertNotNil(downloader.errorMessage)
    XCTAssertEqual(downloader.retryAttempt, 0)
  }

  func testAGenericDownloadFailureIsNeverRetried() async throws {
    let root = try makeRetryRuntime("printf 'ERROR! Download item 123456 failed (Failure).\\n'; exit 1")
    defer { try? FileManager.default.removeItem(at: root) }
    let downloader = startDownload(in: root)
    try await waitForStop(downloader)
    XCTAssertEqual(attempts(in: root), 1, "A removed or private item must fail at once")
    XCTAssertNotNil(downloader.errorMessage)
  }

  func testExitingWithoutConfirmationIsNeverRetried() async throws {
    let root = try makeRetryRuntime("exit 0")
    defer { try? FileManager.default.removeItem(at: root) }
    let downloader = startDownload(in: root)
    try await waitForStop(downloader)
    XCTAssertEqual(attempts(in: root), 1)
    XCTAssertNotNil(downloader.errorMessage)
  }

  func testFailureBeforeSignInIsNeverRetried() async throws {
    let root = try makeRuntime(
      """
      \(countLaunch)
      printf 'Logging in user to Steam Public...FAILED (Timeout)\\n'
      exit 1
      """)
    defer { try? FileManager.default.removeItem(at: root) }
    let downloader = startDownload(in: root)
    try await waitForStop(downloader)
    XCTAssertEqual(attempts(in: root), 1, "Nothing is known about this sign-in yet")
    XCTAssertEqual(downloader.errorMessage, SteamCMDReportedFailure.connection.message)
    XCTAssertTrue(downloader.canRetryAuthentication)
  }

  func testASignInThatTimesOutOnARelaunchIsRetriedOnceTheRunWasAccepted() async throws {
    let root = try makeRuntime(
      """
      \(countLaunch)
      if [ "$attempt" -eq 2 ]; then
          printf 'Logging in user to Steam Public...FAILED (Timeout)\\n'
          exit 1
      fi
      \(signedIn)
      if [ "$attempt" -eq 1 ]; then
          while [ ! -f ../go ]; do sleep 0.02; done
          printf 'ERROR! Download item 123456 failed (Timeout).\\n'
          exit 1
      fi
      \(deliverItem)
      """)
    defer { try? FileManager.default.removeItem(at: root) }
    let downloader = startDownload(in: root)
    do {
      // The sign-in is on record by the time the transfer shows.
      try await waitUntil { downloader.phase == .transferring }
      try Data().write(to: root.appendingPathComponent("go"))
      try await assertImported(downloader, in: root, itemID: "123456")
      XCTAssertEqual(attempts(in: root), 3)
    } catch {
      await downloader.shutdown()
      throw error
    }
  }

  func testATimeoutIsNotReportedAsAPurchaseProblem() async throws {
    var messages: [String] = []
    for reason in ["Timeout", "Failure"] {
      let root = try makeRetryRuntime("printf 'ERROR! Download item 123456 failed (\(reason)).\\n'; exit 1")
      defer { try? FileManager.default.removeItem(at: root) }
      let downloader = startDownload(in: root)
      try await waitForStop(downloader)
      messages.append(try XCTUnwrap(downloader.errorMessage))
    }
    XCTAssertNotEqual(messages[0], messages[1])
  }

  /// A reason split across two reads is judged once it is whole, not by its first half.
  func testAReasonArrivingInPiecesIsStillRecognised() async throws {
    let root = try makeRetryRuntime(
      """
      if [ "$attempt" -eq 1 ]; then
          printf 'ERROR! Download item 123456 failed (Time'
          sleep 0.6
          printf 'out).\\n'
          exit 1
      fi
      \(deliverItem)
      """)
    defer { try? FileManager.default.removeItem(at: root) }
    let downloader = startDownload(in: root)
    try await assertImported(downloader, in: root, itemID: "123456")
    XCTAssertEqual(attempts(in: root), 2)
  }

  /// What follows `failed` decides whether the connection or the purchase is to blame, so a read
  /// that ends before the reason must not settle the failure as a purchase problem.
  func testAFailureLineCutBeforeItsReasonIsJudgedOnceWhole() async throws {
    let cuts = [
      ("ERROR! Download item 123456 failed", " (Timeout).\\n"),
      ("ERROR! Download item 123456 failed (", "Timeout).\\n"),
    ]
    for (first, rest) in cuts {
      let root = try makeRetryRuntime(
        """
        if [ "$attempt" -eq 1 ]; then
            printf '\(first)'
            sleep 0.6
            printf '\(rest)'
            exit 1
        fi
        \(deliverItem)
        """)
      defer { try? FileManager.default.removeItem(at: root) }
      let downloader = startDownload(in: root)
      try await assertImported(downloader, in: root, itemID: "123456")
      XCTAssertEqual(attempts(in: root), 2, "Cut after \(first.suffix(8)): the timeout is retried")
    }
  }

  /// A process that exits without a final newline has said all it will say.
  func testAFailureLineWithoutANewlineIsStillJudgedWhenTheProcessEnds() async throws {
    let root = try makeRetryRuntime(
      """
      if [ "$attempt" -eq 1 ]; then
          printf 'ERROR! Download item 123456 failed (Timeout).'
          exit 1
      fi
      \(deliverItem)
      """)
    defer { try? FileManager.default.removeItem(at: root) }
    let downloader = startDownload(in: root)
    try await assertImported(downloader, in: root, itemID: "123456")
    XCTAssertEqual(attempts(in: root), 2)
  }

  // MARK: Free space and silence

  private let mebibyte: Int64 = 1_048_576

  private func sizedItem(_ size: Int64) -> WorkshopItem {
    WorkshopItem(
      id: "123456", title: "Sized fixture", creator: "Test", summary: "", previewURL: nil,
      tags: ["Video"], size: size, subscriptions: 0)
  }

  /// A clock the test moves. Every limit the downloader applies runs on it, so only the steps
  /// a test takes can use one up.
  private final class StepClock {
    var date = Date(timeIntervalSinceReferenceDate: 0)
  }

  private func startClocked(
    in root: URL, retryDelays: [TimeInterval] = [0]
  ) -> (downloader: WorkshopDownloader, monitor: FixtureNetworkMonitor, clock: StepClock) {
    let monitor = FixtureNetworkMonitor()
    monitor.received = 0
    let clock = StepClock()
    let downloader = WorkshopDownloader(
      sessionDirectory: root.appendingPathComponent("SteamSession"),
      runtimeProvider: ShellRuntimeProvider(), networkMonitor: monitor,
      now: { clock.date }, retryDelays: retryDelays)
    downloader.start(
      item: item, username: "localtest", executable: root.appendingPathComponent("runtime/steamcmd"),
      library: root.appendingPathComponent("Library"), rememberSession: false, onImported: {})
    return (downloader, monitor, clock)
  }

  /// The disk can fill while a pass runs. The retry asks again before it launches, instead of
  /// spending another pass on a download that cannot fit.
  func testARetryChecksFreeSpaceAgainBeforeRelaunching() async throws {
    let root = try makeRetryRuntime(
      """
      if [ "$attempt" -eq 1 ]; then
          while [ ! -f ../go ]; do sleep 0.02; done
          printf 'ERROR! Download item 123456 failed (Timeout).\\n'
          exit 1
      fi
      \(deliverItem)
      """)
    defer { try? FileManager.default.removeItem(at: root) }
    let disk = FreeSpaceProbe(4_000 * mebibyte)
    let downloader = startDownload(in: root, item: sizedItem(50 * mebibyte), freeSpace: disk.measure)
    do {
      try await waitUntil { downloader.phase == .transferring }
      disk.available = 3 * mebibyte
      try Data().write(to: root.appendingPathComponent("go"))
      try await waitForStop(downloader)
      XCTAssertEqual(attempts(in: root), 1, "SteamCMD is not launched again on a disk that cannot hold the rest")
      XCTAssertEqual(disk.questions.count, 2, "Once before the first launch and once before the retry")
      XCTAssertNotNil(downloader.errorMessage)
      XCTAssertFalse(downloader.canRetryAuthentication, "A full disk is not a sign-in failure")
      XCTAssertFalse(downloader.completedSuccessfully)
    } catch {
      await downloader.shutdown()
      throw error
    }
  }

  func testARelaunchSteamAsksForChecksFreeSpaceAgain() async throws {
    // Exit status 42 is SteamCMD asking to be started again after updating itself.
    let root = try makeRetryRuntime(
      """
      if [ "$attempt" -eq 1 ]; then
          while [ ! -f ../go ]; do sleep 0.02; done
          exit 42
      fi
      \(deliverItem)
      """)
    defer { try? FileManager.default.removeItem(at: root) }
    let disk = FreeSpaceProbe(4_000 * mebibyte)
    let downloader = startDownload(in: root, item: sizedItem(50 * mebibyte), freeSpace: disk.measure)
    do {
      try await waitUntil { downloader.phase == .transferring }
      disk.available = 3 * mebibyte
      try Data().write(to: root.appendingPathComponent("go"))
      try await waitForStop(downloader)
      XCTAssertEqual(attempts(in: root), 1)
      XCTAssertEqual(disk.questions.count, 2)
      XCTAssertNotNil(downloader.errorMessage)
    } catch {
      await downloader.shutdown()
      throw error
    }
  }

  /// Every silent pass costs the whole inactivity limit, so one repeat is all a connection that
  /// gives no sign of life gets; dropped connections that Steam reports keep their three.
  func testASilentStallIsRepeatedOnlyOnce() async throws {
    let root = try makeRetryRuntime("IFS= read -r finish")
    defer { try? FileManager.default.removeItem(at: root) }
    let (downloader, monitor, clock) = startClocked(in: root, retryDelays: [0, 0, 0])
    do {
      try await waitUntil { monitor.startedPIDs.count == 1 }
      clock.date += 301
      try await waitUntil { monitor.startedPIDs.count == 2 }
      clock.date += 301
      try await waitForStop(downloader)
      XCTAssertEqual(attempts(in: root), 2, "The first pass and one repeat")
      XCTAssertEqual(downloader.retryAttempt, 1)
      XCTAssertNotNil(downloader.errorMessage)
      XCTAssertFalse(downloader.canRetryAuthentication)
    } catch {
      await downloader.shutdown()
      throw error
    }
  }

  func testPauseDuringTheWaitKeepsThePartialDownload() async throws {
    let root = try makeRetryRuntime(
      """
      mkdir -p steamapps/workshop/downloads/431960
      printf 'partial' > steamapps/workshop/downloads/431960/part
      printf 'ERROR! Download item 123456 failed (Timeout).\\n'
      exit 1
      """)
    defer { try? FileManager.default.removeItem(at: root) }
    let checkpoint = root.appendingPathComponent("Checkpoint")
    let downloader = startDownload(in: root, checkpointDirectory: checkpoint, retryDelays: [30])
    do {
      try await waitUntil { downloader.retryAttempt == 1 }
      XCTAssertTrue(downloader.isRunning, "The download holds its slot while it waits")
      downloader.pause()
      try await waitForStop(downloader)
      XCTAssertEqual(attempts(in: root), 1, "A paused download does not come back by itself")
      XCTAssertFalse(downloader.wasCancelled)
      XCTAssertNil(downloader.errorMessage)
      XCTAssertEqual(
        try Data(contentsOf: checkpoint.appendingPathComponent("steamapps/workshop/downloads/431960/part")),
        Data("partial".utf8))
      try assertNoStaging(in: root)
    } catch {
      await downloader.shutdown()
      throw error
    }
  }

  func testCancelDuringTheWaitDiscardsThePartialDownload() async throws {
    let root = try makeRetryRuntime(
      """
      mkdir -p steamapps/workshop/downloads/431960
      printf 'partial' > steamapps/workshop/downloads/431960/part
      printf 'ERROR! Download item 123456 failed (Timeout).\\n'
      exit 1
      """)
    defer { try? FileManager.default.removeItem(at: root) }
    let checkpoint = root.appendingPathComponent("Checkpoint")
    let downloader = startDownload(in: root, checkpointDirectory: checkpoint, retryDelays: [30])
    do {
      try await waitUntil { downloader.retryAttempt == 1 }
      downloader.cancel()
      try await waitForStop(downloader)
      XCTAssertEqual(attempts(in: root), 1)
      XCTAssertTrue(downloader.wasCancelled)
      XCTAssertFalse(FileManager.default.fileExists(atPath: checkpoint.path))
      try assertNoStaging(in: root)
    } catch {
      await downloader.shutdown()
      throw error
    }
  }

  /// SteamCMD prints nothing while it fetches an item, so after a sleep or a lost network the
  /// first sign is silence. Once Steam accepted the sign-in that silence is the connection.
  func testStallAfterSignInIsRetried() async throws {
    let root = try makeRetryRuntime(
      """
      if [ "$attempt" -eq 1 ]; then
          IFS= read -r finish
          exit 0
      fi
      \(deliverItem)
      """)
    defer { try? FileManager.default.removeItem(at: root) }
    let monitor = FixtureNetworkMonitor()
    // The time limits run on this clock, so only the step below can use them up.
    var clock = Date(timeIntervalSinceReferenceDate: 0)
    let downloader = WorkshopDownloader(
      sessionDirectory: root.appendingPathComponent("SteamSession"),
      runtimeProvider: ShellRuntimeProvider(), networkMonitor: monitor,
      inactivityTimeout: 1, passTimeout: 1.5, now: { clock }, retryDelays: [0])
    downloader.start(
      item: item, username: "localtest", executable: root.appendingPathComponent("runtime/steamcmd"),
      library: root.appendingPathComponent("Library"), rememberSession: false, onImported: {})
    do {
      try await waitUntil { monitor.startedPIDs.count == 1 }
      clock += 1.1
      try await assertImported(downloader, in: root, itemID: "123456")
      XCTAssertEqual(attempts(in: root), 2)
      XCTAssertEqual(downloader.retryAttempt, 1)
    } catch {
      await downloader.shutdown()
      throw error
    }
  }

  func testStallWhileSigningInIsNeverRetried() async throws {
    let root = try makeRuntime(
      """
      \(countLaunch)
      printf 'Logging in user to Steam Public...\\n'
      IFS= read -r finish
      """)
    defer { try? FileManager.default.removeItem(at: root) }
    var clock = Date(timeIntervalSinceReferenceDate: 0)
    let downloader = WorkshopDownloader(
      sessionDirectory: root.appendingPathComponent("SteamSession"),
      runtimeProvider: ShellRuntimeProvider(), networkMonitor: FixtureNetworkMonitor(),
      inactivityTimeout: 1, passTimeout: 1.5, now: { clock }, retryDelays: [0, 0, 0])
    downloader.start(
      item: item, username: "localtest", executable: root.appendingPathComponent("runtime/steamcmd"),
      library: root.appendingPathComponent("Library"), rememberSession: false, onImported: {})
    do {
      try await waitUntil { downloader.phase == .signingIn }
      clock += 1.1
      try await waitForStop(downloader)
      XCTAssertEqual(attempts(in: root), 1, "Steam Guard may still be waiting for the user")
      XCTAssertTrue(downloader.canRetryAuthentication)
    } catch {
      await downloader.shutdown()
      throw error
    }
  }

  /// Steam took this run's sign-in, so a relaunch that goes quiet while signing in again is the
  /// connection and not Steam Guard: the tile must not offer to retry the authentication.
  func testStallInARetrysOwnSignInIsTheConnectionNotSteamGuard() async throws {
    let root = try makeRuntime(
      """
      \(countLaunch)
      if [ "$attempt" -eq 1 ]; then
          \(signedIn)
          while [ ! -f ../go ]; do sleep 0.02; done
          printf 'ERROR! Download item 123456 failed (Timeout).\\n'
          exit 1
      fi
      printf 'Logging in user to Steam Public...\\n'
      IFS= read -r finish
      """)
    defer { try? FileManager.default.removeItem(at: root) }
    let (downloader, monitor, clock) = startClocked(in: root)
    do {
      try await waitUntil { monitor.startedPIDs.count == 1 && downloader.phase == .transferring }
      try Data().write(to: root.appendingPathComponent("go"))
      try await waitUntil { self.attempts(in: root) == 2 && downloader.phase == .signingIn }
      clock.date += 301
      try await waitForStop(downloader)
      XCTAssertEqual(attempts(in: root), 2, "The one retry the test allows is spent")
      XCTAssertNotNil(downloader.errorMessage)
      XCTAssertFalse(downloader.canRetryAuthentication, "Nothing is waiting for Steam Guard once the sign-in was accepted")
    } catch {
      await downloader.shutdown()
      throw error
    }
  }

  // MARK: Waking from sleep

  /// Waits for the downloader's next byte reading, which it checks its limits against in the
  /// same main-actor turn.
  private func nextCheck(_ monitor: FixtureNetworkMonitor, _ downloader: WorkshopDownloader)
    async throws
  {
    let readings = monitor.receivedReadings
    try await waitUntil { monitor.receivedReadings > readings || !downloader.isRunning }
  }

  /// A sleep usually kills the connection without a word from SteamCMD. Once the Mac has been
  /// awake for the grace period without a single new byte, the transfer starts over, long before
  /// the inactivity limit would have noticed.
  func testSilentTransferAfterWakeIsRestarted() async throws {
    let root = try makeRetryRuntime(
      """
      if [ "$attempt" -eq 1 ]; then
          IFS= read -r finish
          exit 0
      fi
      \(deliverItem)
      """)
    defer { try? FileManager.default.removeItem(at: root) }
    let (downloader, monitor, clock) = startClocked(in: root)
    do {
      try await waitUntil { monitor.startedPIDs.count == 1 }
      downloader.noteSystemResume()
      clock.date += 44
      try await nextCheck(monitor, downloader)
      XCTAssertTrue(downloader.isRunning, downloader.errorMessage ?? "")
      XCTAssertEqual(attempts(in: root), 1, "Inside the grace period the connection gets the benefit of the doubt")
      clock.date += 2
      try await assertImported(downloader, in: root, itemID: "123456")
      XCTAssertEqual(attempts(in: root), 2)
      XCTAssertEqual(downloader.retryAttempt, 1)
      XCTAssertNil(downloader.errorMessage)
      XCTAssertNil(downloader.prompt, "The restart reuses the sign-in in its staging")
      try assertNoStaging(in: root)
    } catch {
      await downloader.shutdown()
      throw error
    }
  }

  /// The same silence without a wake is left to the inactivity limit, so the restart above is
  /// the wake's doing and not a shorter stall limit.
  func testSilenceWithoutAWakeIsNotRestartedEarly() async throws {
    let root = try makeRetryRuntime("IFS= read -r finish")
    defer { try? FileManager.default.removeItem(at: root) }
    let (downloader, monitor, clock) = startClocked(in: root)
    do {
      try await waitUntil { monitor.startedPIDs.count == 1 }
      clock.date += 120
      try await nextCheck(monitor, downloader)
      try await nextCheck(monitor, downloader)
      XCTAssertTrue(downloader.isRunning, downloader.errorMessage ?? "")
      XCTAssertEqual(attempts(in: root), 1)
      XCTAssertNil(downloader.resumedAt)
      await downloader.shutdown()
    } catch {
      await downloader.shutdown()
      throw error
    }
  }

  func testTransferThatKeepsGrowingAfterWakeIsLeftAlone() async throws {
    let root = try makeRetryRuntime(
      """
      while [ ! -f ../go ]; do sleep 0.02; done
      \(deliverItem)
      """)
    defer { try? FileManager.default.removeItem(at: root) }
    let (downloader, monitor, clock) = startClocked(in: root)
    do {
      try await waitUntil { monitor.startedPIDs.count == 1 }
      downloader.noteSystemResume()
      clock.date += 10
      monitor.received = 4096
      try await nextCheck(monitor, downloader)
      XCTAssertNil(downloader.resumedAt, "Bytes after the wake show the connection survived")
      // Well past the grace period, and still short of the inactivity limit.
      clock.date += 100
      try await nextCheck(monitor, downloader)
      try await nextCheck(monitor, downloader)
      XCTAssertTrue(downloader.isRunning, downloader.errorMessage ?? "")
      XCTAssertEqual(attempts(in: root), 1)
      try Data().write(to: root.appendingPathComponent("go"))
      try await assertImported(downloader, in: root, itemID: "123456")
      XCTAssertEqual(attempts(in: root), 1)
      XCTAssertEqual(downloader.retryAttempt, 0)
    } catch {
      await downloader.shutdown()
      throw error
    }
  }

  /// Steam Guard may still be waiting for the user when the Mac wakes: nothing to restart, and
  /// the wake must not count against the transfer that starts once the user has answered.
  func testWakeIsIgnoredWhileSigningIn() async throws {
    let root = try makeRuntime(
      """
      \(countLaunch)
      printf 'password: '
      IFS= read -r password
      \(signedIn)
      while [ ! -f ../go ]; do sleep 0.02; done
      \(deliverItem)
      """)
    defer { try? FileManager.default.removeItem(at: root) }
    let (downloader, monitor, clock) = startClocked(in: root)
    do {
      try await waitUntil { downloader.prompt == .password }
      downloader.noteSystemResume()
      XCTAssertNil(downloader.resumedAt)
      clock.date += 100
      downloader.submitSecret("local-password")
      try await waitUntil { monitor.startedPIDs.count == 1 }
      try await nextCheck(monitor, downloader)
      try await nextCheck(monitor, downloader)
      XCTAssertTrue(downloader.isRunning, downloader.errorMessage ?? "")
      XCTAssertEqual(attempts(in: root), 1, "A wake before the transfer began says nothing about it")
      try Data().write(to: root.appendingPathComponent("go"))
      try await assertImported(downloader, in: root, itemID: "123456")
      XCTAssertEqual(attempts(in: root), 1)
    } catch {
      await downloader.shutdown()
      throw error
    }
  }

  /// The watch belongs to the process that slept. When something else ends it first, the
  /// replacement must not be cut short for being silent since a wake it never lived through.
  func testWakeWatchDoesNotOutliveTheProcessThatSlept() async throws {
    let root = try makeRetryRuntime(
      """
      if [ "$attempt" -eq 1 ]; then
          while [ ! -f ../drop ]; do sleep 0.02; done
          printf 'ERROR! Download item 123456 failed (Timeout).\\n'
          exit 1
      fi
      while [ ! -f ../go ]; do sleep 0.02; done
      \(deliverItem)
      """)
    defer { try? FileManager.default.removeItem(at: root) }
    let (downloader, monitor, clock) = startClocked(in: root)
    do {
      try await waitUntil { monitor.startedPIDs.count == 1 }
      downloader.noteSystemResume()
      XCTAssertNotNil(downloader.resumedAt)
      try Data().write(to: root.appendingPathComponent("drop"))
      try await waitUntil { monitor.startedPIDs.count == 2 }
      XCTAssertNil(downloader.resumedAt)
      // Silent for longer than the grace period measured from the wake, which says nothing
      // about a process that was not asleep.
      clock.date += 60
      try await nextCheck(monitor, downloader)
      try await nextCheck(monitor, downloader)
      XCTAssertTrue(downloader.isRunning, downloader.errorMessage ?? "")
      XCTAssertEqual(attempts(in: root), 2)
      try Data().write(to: root.appendingPathComponent("go"))
      try await assertImported(downloader, in: root, itemID: "123456")
      XCTAssertEqual(attempts(in: root), 2)
      XCTAssertEqual(downloader.retryAttempt, 1)
    } catch {
      await downloader.shutdown()
      throw error
    }
  }

  /// A wake restart is a retry like any other, and the budget is the same: with none left the
  /// download ends and says what happened.
  func testWakeRestartEndsTheDownloadWhenNoRetriesAreLeft() async throws {
    let root = try makeRetryRuntime("IFS= read -r finish")
    defer { try? FileManager.default.removeItem(at: root) }
    let (downloader, monitor, clock) = startClocked(in: root, retryDelays: [])
    do {
      try await waitUntil { monitor.startedPIDs.count == 1 }
      downloader.noteSystemResume()
      clock.date += 46
      try await waitForStop(downloader)
      XCTAssertEqual(attempts(in: root), 1)
      XCTAssertNotNil(downloader.errorMessage)
      XCTAssertFalse(downloader.completedSuccessfully)
      XCTAssertFalse(downloader.canRetryAuthentication, "A lost connection is not a sign-in failure")
      try assertNoStaging(in: root)
    } catch {
      await downloader.shutdown()
      throw error
    }
  }
}
