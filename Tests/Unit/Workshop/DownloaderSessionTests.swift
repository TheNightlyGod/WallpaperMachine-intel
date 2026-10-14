import Darwin
import XCTest

@testable import WallpaperMachine

/// Saved Steam sessions: persistence across relaunch, account switching and credential hygiene.
@MainActor
final class DownloaderSessionTests: DownloaderTestCase {
  func testSavedSessionSurvivesRelaunchWithoutSubmittingSecrets() async throws {
    let root = try makeSessionRuntime()
    defer { try? FileManager.default.removeItem(at: root) }
    let first = startDownload(in: root, username: "LocalTest")
    try await authenticate(first)
    try await assertImported(first, in: root, itemID: "123456")
    XCTAssertEqual(first.savedAccount?.lowercased(), "localtest")
    XCTAssertNil(first.sessionWarning)
    try assertPrivateSession(in: root)

    let second = startDownload(
      in: root, username: "LOCALTEST", itemID: "234567", libraryName: "OtherLibrary")
    try await assertImported(second, in: root, itemID: "234567", libraryName: "OtherLibrary")
    XCTAssertEqual(
      try String(
        contentsOf: root.appendingPathComponent("OtherLibrary/234567/movie.mp4"), encoding: .utf8),
      "cached:localtest:234567")
    try assertNoStaging(in: root)
  }

  func testSavedSignInAndStagingStayOutOfBackupsButTheLibraryDoesNot() async throws {
    let root = try makeSessionRuntime()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = root.appendingPathComponent("SteamSession")
    let probe = StagingBackupProbe()
    let first = startDownload(in: root, runtimeProvider: probe)
    try await authenticate(first)
    try await assertImported(first, in: root, itemID: "123456")
    XCTAssertEqual(probe.excludedAtLaunch, [true], "partial downloads must be skipped from the first byte")
    XCTAssertEqual(first.savedAccount, "localtest")
    XCTAssertTrue(session.isKeptOutOfBackups, "a new sign-in must not reach a backup")

    // Signing in as someone else replaces the saved directory with a new one.
    let other = startDownload(in: root, username: "another_account", itemID: "234567", runtimeProvider: probe)
    try await authenticate(other)
    try await assertImported(other, in: root, itemID: "234567")
    XCTAssertEqual(other.savedAccount, "another_account")
    XCTAssertTrue(session.isKeptOutOfBackups, "a replaced sign-in must not become backed up")
    XCTAssertEqual(probe.excludedAtLaunch, [true, true])
    XCTAssertFalse(root.appendingPathComponent("Library").isKeptOutOfBackups, "installed wallpapers stay in the backup")
    XCTAssertFalse(root.appendingPathComponent("Library/234567").isKeptOutOfBackups)
    try assertNoStaging(in: root)
  }

  func testSwitchingAccountsNeverRestoresPreviousAccountsCredentials() async throws {
    let root = try makeSessionRuntime()
    defer { try? FileManager.default.removeItem(at: root) }
    let first = startDownload(in: root)
    try await authenticate(first)
    try await assertImported(first, in: root, itemID: "123456")

    let other = startDownload(in: root, username: "another_account", itemID: "234567")
    try await authenticate(other)
    try await assertImported(other, in: root, itemID: "234567")
    XCTAssertEqual(other.savedAccount, "another_account")
    let restored = startDownload(in: root, username: "another_account", itemID: "345678")
    try await assertImported(restored, in: root, itemID: "345678")

    let previous = startDownload(in: root, itemID: "456789")
    try await authenticate(previous)
    try await assertImported(previous, in: root, itemID: "456789")
  }

  func testInvalidCachedCredentialWarningAllowsPasswordFallback() async throws {
    let root = try makeSessionRuntime()
    defer { try? FileManager.default.removeItem(at: root) }
    let initial = startDownload(in: root)
    try await authenticate(initial)
    try await assertImported(initial, in: root, itemID: "123456")
    try setSessionMode("fallback", in: root)

    let recovered = startDownload(in: root, itemID: "234567")
    try await authenticate(recovered)
    try await assertImported(recovered, in: root, itemID: "234567")
    XCTAssertFalse(recovered.canRetryAuthentication)
    try setSessionMode("normal", in: root)
    let next = startDownload(in: root, itemID: "345678")
    try await assertImported(next, in: root, itemID: "345678")
  }

  func testTerminalCachedCredentialRejectionRequiresExplicitFreshLogin() async throws {
    let root = try makeSessionRuntime()
    defer { try? FileManager.default.removeItem(at: root) }
    let initial = startDownload(in: root)
    try await authenticate(initial)
    try await assertImported(initial, in: root, itemID: "123456")
    try setSessionMode("terminal", in: root)

    let rejected = startDownload(in: root, itemID: "234567")
    try await waitForStop(rejected)
    XCTAssertNotNil(rejected.errorMessage)
    XCTAssertTrue(rejected.canRetryAuthentication)
    XCTAssertNil(rejected.savedAccount)
    XCTAssertNil(rejected.downloadedID)
    try assertNoStaging(in: root)

    // Leave terminal mode enabled: any stale cache would be rejected again.
    let retry = startDownload(in: root, itemID: "234567")
    try await authenticate(retry)
    try await assertImported(retry, in: root, itemID: "234567")
  }

  func testForgettingSavedAccountRemovesCredentialsAcrossRelaunch() async throws {
    let root = try makeSessionRuntime()
    defer { try? FileManager.default.removeItem(at: root) }
    let initial = startDownload(in: root)
    try await authenticate(initial)
    try await assertImported(initial, in: root, itemID: "123456")
    initial.forgetSavedAccount()
    XCTAssertNil(initial.savedAccount)
    XCTAssertNil(initial.errorMessage)
    try assertNoSavedCredentials(in: root)

    let next = startDownload(in: root, itemID: "234567")
    XCTAssertNil(next.savedAccount)
    try await authenticate(next)
    try await assertImported(next, in: root, itemID: "234567")
  }

  func testOptingOutClearsExistingSessionAndDoesNotSaveNewLogin() async throws {
    let root = try makeSessionRuntime()
    defer { try? FileManager.default.removeItem(at: root) }
    let initial = startDownload(in: root)
    try await authenticate(initial)
    try await assertImported(initial, in: root, itemID: "123456")

    let optedOut = startDownload(in: root, itemID: "234567", rememberSession: false)
    try await authenticate(optedOut)
    try await assertImported(optedOut, in: root, itemID: "234567")
    XCTAssertNil(optedOut.savedAccount)
    try assertNoSavedCredentials(in: root)

    let next = startDownload(in: root, itemID: "345678")
    XCTAssertNil(next.savedAccount)
    try await authenticate(next)
    try await assertImported(next, in: root, itemID: "345678")
  }

  func testRejectedLoginDoesNotPersistCredentialsWrittenBeforeAuthentication() async throws {
    let root = try makeSessionRuntime()
    defer { try? FileManager.default.removeItem(at: root) }
    try setSessionMode("reject", in: root)
    let rejected = startDownload(in: root)
    try await authenticate(rejected)
    try await waitForStop(rejected)
    XCTAssertNotNil(rejected.errorMessage)
    XCTAssertTrue(rejected.canRetryAuthentication)
    XCTAssertNil(rejected.savedAccount)
    try assertNoSavedCredentials(in: root)
    try assertNoStaging(in: root)

    try setSessionMode("normal", in: root)
    let next = startDownload(in: root)
    try await authenticate(next)
    try await assertImported(next, in: root, itemID: "123456")
  }

  func testDownloadAccessFailurePreservesSuccessfullyAuthenticatedSession() async throws {
    let root = try makeSessionRuntime()
    defer { try? FileManager.default.removeItem(at: root) }
    try setSessionMode("access", in: root)
    let denied = startDownload(in: root)
    try await authenticate(denied)
    try await waitForStop(denied)
    XCTAssertNotNil(denied.errorMessage)
    XCTAssertFalse(denied.canRetryAuthentication)
    XCTAssertEqual(denied.savedAccount, "localtest")
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("Library/123456").path))
    try assertNoStaging(in: root)

    try setSessionMode("normal", in: root)
    let next = startDownload(in: root, itemID: "234567")
    try await assertImported(next, in: root, itemID: "234567")
  }

  func testAuthenticatedCancellationRetainsSessionButRemovesPartialWallpaper() async throws {
    let root = try makeSessionRuntime()
    defer { try? FileManager.default.removeItem(at: root) }
    try setSessionMode("cancel", in: root)
    let cancelled = startDownload(in: root)
    try await authenticate(cancelled)
    do {
      try await waitUntil { cancelled.status == String(localized: "Downloading Workshop files…") }
      XCTAssertNil(cancelled.progress)
      await cancelled.shutdown()
    } catch {
      await cancelled.shutdown()
      throw error
    }
    XCTAssertNil(cancelled.downloadedID)
    XCTAssertTrue(cancelled.wasCancelled)
    XCTAssertEqual(cancelled.savedAccount, "localtest")
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("Library/123456").path))
    try assertNoStaging(in: root)

    try setSessionMode("normal", in: root)
    let next = startDownload(in: root, itemID: "234567")
    try await assertImported(next, in: root, itemID: "234567")
  }

  func testFailedAccountSwitchPreservesPreviousAccountSession() async throws {
    let root = try makeSessionRuntime()
    defer { try? FileManager.default.removeItem(at: root) }
    let initial = startDownload(in: root)
    try await authenticate(initial)
    try await assertImported(initial, in: root, itemID: "123456")
    try setSessionMode("reject", in: root)
    let rejected = startDownload(in: root, username: "another_account", itemID: "234567")
    try await authenticate(rejected)
    try await waitForStop(rejected)
    XCTAssertTrue(rejected.canRetryAuthentication)
    XCTAssertEqual(rejected.savedAccount, "localtest")
    try setSessionMode("normal", in: root)
    let previous = startDownload(in: root, itemID: "345678")
    try await assertImported(previous, in: root, itemID: "345678")
  }

  func testSavedCredentialSymlinkCannotReadOutsidePrivateCache() async throws {
    let root = try makeSessionRuntime()
    defer { try? FileManager.default.removeItem(at: root) }
    let initial = startDownload(in: root)
    try await authenticate(initial)
    try await assertImported(initial, in: root, itemID: "123456")
    let files = FileManager.default
    let original = root.appendingPathComponent("SteamSession/config/config.vdf")
    let outside = root.appendingPathComponent("outside-credential")
    try files.moveItem(at: original, to: outside)
    try files.setAttributes([.posixPermissions: 0o640], ofItemAtPath: outside.path)
    try files.createSymbolicLink(at: original, withDestinationURL: outside)
    let blocked = startDownload(in: root, itemID: "234567")
    try await waitForStop(blocked)
    XCTAssertNotNil(blocked.errorMessage)
    XCTAssertNil(blocked.downloadedID)
    XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "token:localtest")
    XCTAssertEqual(
      (try files.attributesOfItem(atPath: outside.path)[.posixPermissions] as? NSNumber)?.intValue,
      0o640)
    try assertNoStaging(in: root)
  }

  func testRestartRejectsRuntimeRemovedByPreviousProcess() async throws {
    let root = try makeRuntime("rm steamcmd; exit 42")
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

  func testShutdownWaitsForOwnedDescendantsBeforeRemovingStaging() async throws {
    let root = try makeRuntime(
      """
      (trap '' TERM; sleep 3; printf late > ../late-write) &
      printf 'password: '
      IFS= read -r password
      """)
    defer { try? FileManager.default.removeItem(at: root) }
    let downloader = startDownload(in: root)
    do {
      try await waitUntil { downloader.prompt == .password }
      await downloader.shutdown()
      XCTAssertTrue(downloader.wasCancelled)
      try assertNoStaging(in: root)
      try await Task.sleep(for: .milliseconds(1300))
      XCTAssertFalse(
        FileManager.default.fileExists(atPath: root.appendingPathComponent("late-write").path))
      XCTAssertNil(downloader.downloadedID)
    } catch {
      await downloader.shutdown()
      throw error
    }
  }
}
