import XCTest

@testable import WallpaperMachine

/// What a failed SteamCMD run leaves behind for a bug report, and how a sign-in that ends with no
/// word from Steam is told apart from one Steam refused.
@MainActor
final class DownloaderFailureOutputTests: DownloaderTestCase {
  func testSilentExitBeforeSignInIsUnexplainedAndKeepsARedactedTail() async throws {
    let root = try makeRuntime(
      """
      printf 'Redirecting stderr to ~/Library/Application Support/Steam/logs/stderr.txt\\n'
      printf "Logging in user 'localtest' [U:1:987654321] to Steam Public...\\n"
      printf 'session 76561198000000001 token abcdefghijklmnopqrstuvwxyz0123456789ABCD\\n'
      exit 8
      """)
    defer { try? FileManager.default.removeItem(at: root) }
    let downloader = startDownload(in: root)
    try await waitForStop(downloader)
    XCTAssertTrue(downloader.endedBeforeSignInUnexplained)
    let output = try XCTUnwrap(downloader.failureOutput)
    XCTAssertTrue(output.contains("Logging in user '<account>' [U:<steamid>] to Steam Public..."), output)
    XCTAssertTrue(output.contains("Redirecting stderr"), output)
    for leaked in ["localtest", "987654321", "76561198000000001", "abcdefghijklmnopqrstuvwxyz0123456789ABCD"] {
      XCTAssertFalse(output.contains(leaked), "\(leaked) must not be kept: \(output)")
    }

    let manager = WorkshopDownloadManager(
      sessionDirectory: root.appendingPathComponent("SteamSession"), runtimeProvider: ShellRuntimeProvider(), downloadRegion: { .steamsChoice })
    var reported: [String] = []
    manager.onUnexplainedSignInFailure = { reported.append($0.id) }
    manager.start(
      item: item, username: "localtest", executable: root.appendingPathComponent("runtime/steamcmd"),
      library: root.appendingPathComponent("Library"), rememberSession: false, onImported: {})
    try await waitUntil { !manager.isRunning }
    XCTAssertEqual(reported, [item.id])
    let kept = try XCTUnwrap(manager.failureLog.read())
    XCTAssertTrue(kept.contains("Steam Public"), kept)
    XCTAssertFalse(kept.contains("localtest"), kept)
  }

  func testAFailureSteamReportsIsExplainedAndAFinishedRunKeepsNothing() async throws {
    let refused = try makeRuntime(
      """
      printf 'Logging in user to Steam Public...FAILED (Timeout)\\n'
      exit 1
      """)
    defer { try? FileManager.default.removeItem(at: refused) }
    let manager = WorkshopDownloadManager(
      sessionDirectory: refused.appendingPathComponent("SteamSession"), runtimeProvider: ShellRuntimeProvider(), downloadRegion: { .steamsChoice })
    var reported: [String] = []
    manager.onUnexplainedSignInFailure = { reported.append($0.id) }
    manager.start(
      item: item, username: "localtest", executable: refused.appendingPathComponent("runtime/steamcmd"),
      library: refused.appendingPathComponent("Library"), rememberSession: false, onImported: {})
    try await waitUntil { !manager.isRunning }
    let job = try XCTUnwrap(manager.download(for: item.id))
    XCTAssertFalse(job.worker.endedBeforeSignInUnexplained, "Steam said why: the connection")
    XCTAssertTrue(reported.isEmpty)
    XCTAssertNotNil(job.worker.failureOutput, "A reported failure still keeps what SteamCMD printed")

    let signedIn = try makeRuntime("printf 'Waiting for user info...OK\\n'")
    defer { try? FileManager.default.removeItem(at: signedIn) }
    let downloader = WorkshopDownloader(
      sessionDirectory: signedIn.appendingPathComponent("SteamSession"),
      runtimeProvider: ShellRuntimeProvider(), networkMonitor: FixtureNetworkMonitor())
    downloader.signIn(
      username: "localtest", executable: signedIn.appendingPathComponent("runtime/steamcmd"),
      root: signedIn, rememberSession: false)
    try await waitForStop(downloader)
    XCTAssertNil(downloader.errorMessage)
    XCTAssertNil(downloader.failureOutput)
    XCTAssertFalse(downloader.endedBeforeSignInUnexplained)
  }

  func testRedactionCoversEmailLoginsAndTerminalCodes() {
    let line = "\u{1B}[1mLogging in user 'Someone@Example.com' (friend other@example.org)\u{1B}[0m\r"
    let redacted = SteamCMDFailureLog.redacted(line, account: "someone@example.com")
    XCTAssertEqual(redacted, "Logging in user '<account>' (friend <email>)")
    let long = SteamCMDFailureLog.redacted(String(repeating: "word ", count: 200), account: "")
    XCTAssertEqual(long.count, SteamCMDFailureLog.maximumLineLength + 1)
  }

  func testTheLogKeepsTheNewestTranscriptsThatFit() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mwe-failure-log-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    let log = SteamCMDFailureLog(url: folder.appendingPathComponent(SteamCMDFailureLog.fileName))
    XCTAssertNil(log.read())
    let filler = String(repeating: "x", count: SteamCMDFailureLog.maximumBytes / 3)
    for index in 0..<5 { log.append("== run \(index)\n\(filler)") }
    let kept = try XCTUnwrap(log.read())
    XCTAssertLessThanOrEqual(kept.utf8.count, SteamCMDFailureLog.maximumBytes)
    XCTAssertTrue(kept.contains("== run 4"))
    XCTAssertFalse(kept.contains("== run 0"))
    let mode = try FileManager.default.attributesOfItem(atPath: log.url.path)[.posixPermissions] as? Int
    XCTAssertEqual(mode, 0o600)
  }
}
