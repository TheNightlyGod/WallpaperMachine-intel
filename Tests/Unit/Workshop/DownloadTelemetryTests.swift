import Darwin
import XCTest

@testable import WallpaperMachine

/// `NetworkReceiveMeter` parsing and the transfer telemetry a download publishes.
@MainActor
final class DownloadTelemetryTests: DownloaderTestCase {
  func testNetworkReceiveMeterUsesOnlyFreshPIDScopedDeltaBytes() {
    var meter = NetworkReceiveMeter(processID: 42)
    func row(_ bytes: Int64) -> Data { Data(",bytes_in,\nsteamcmd.42,\(bytes),\n".utf8) }
    meter.append(row(9_000_000), at: 0)
    XCTAssertNil(meter.rate(at: 0))
    meter.append(Data(",bytes_in,\nsteamcmd.42,60".utf8), at: 1)
    XCTAssertNil(meter.rate(at: 1))
    meter.append(Data("0000,\n".utf8), at: 1)
    XCTAssertEqual(meter.rate(at: 1), 600_000)
    meter.append(row(300_000), at: 2)
    XCTAssertEqual(meter.rate(at: 2), 450_000)
    meter.append(Data(",bytes_in,\nsteamcmd.142,999999999,\nsteamcmd.42,-1,\nsteamcmd.42,NaN,\n".utf8), at: 2.5)
    XCTAssertEqual(meter.rate(at: 2.5), 450_000)
    meter.append(row(0), at: 3)
    XCTAssertEqual(meter.rate(at: 3), 300_000)
    meter.append(row(0), at: 4)
    meter.append(row(0), at: 5)
    XCTAssertEqual(meter.rate(at: 5), 0)
    XCTAssertNil(meter.rate(at: 8.1))
    meter.append(row(50_000_000), at: 20)
    XCTAssertNil(meter.rate(at: 20))
    meter.append(row(150_000), at: 21.5)
    XCTAssertEqual(meter.rate(at: 21.5), 100_000)
    meter.append(row(900_000_000), at: 21.6)
    XCTAssertNil(meter.rate(at: 21.6))
    XCTAssertNil(meter.rate(at: .nan))
  }

  func testNetworkReceiveMeterAcceptsTerminalCRLFAndSplitLineEndings() {
    var meter = NetworkReceiveMeter(processID: 42)
    meter.append(Data(",bytes_in,\r\nWallpaperMachin.42,1,\r\n".utf8), at: 0)
    XCTAssertNil(meter.rate(at: 0))
    meter.append(Data(",bytes_in,\r\nWallpaperMachin.42,1000,\r\n".utf8), at: 1)
    XCTAssertEqual(meter.rate(at: 1), 1000)
    meter.append(Data(",bytes_in,\r".utf8), at: 2)
    meter.append(Data("\nWallpaperMachin.42,2000,\r".utf8), at: 2)
    meter.append(Data("\n".utf8), at: 2)
    XCTAssertEqual(meter.rate(at: 2), 1500)
    meter.append(Data("WallpaperMachin.42,0,\r\n".utf8), at: 3)
    XCTAssertEqual(meter.rate(at: 3), 1000)
  }

  func testNetworkReceiveMeterHonoursHeaderColumnOrder() {
    var meter = NetworkReceiveMeter(processID: 42)
    meter.append(Data(",bytes_out,bytes_in,\nsteamcmd.42,111,600000,\n".utf8), at: 0)
    XCTAssertNil(meter.rate(at: 0))
    meter.append(Data("steamcmd.42,222,300000,\n".utf8), at: 1)
    XCTAssertEqual(meter.rate(at: 1), 300_000)
  }

  func testNetworkReceiveMeterRejectsUnscopedMalformedAndOverflowingRows() {
    var meter = NetworkReceiveMeter(processID: 42)
    meter.append(Data("steamcmd.42,600000,\nother.42,700000,\n".utf8), at: 0)
    XCTAssertNil(meter.rate(at: 1))
    meter.append(Data(",bytes_in,\nsteamcmd.42,99999999999999999999,\n".utf8), at: 0)
    XCTAssertNil(meter.rate(at: 0.4))
    meter.append(Data("steamcmd.42,600000,\n".utf8), at: 1)
    XCTAssertNil(meter.rate(at: 1))
    meter.append(Data("steamcmd.42,300000,\n".utf8), at: 2)
    XCTAssertEqual(meter.rate(at: 2), 300_000)
  }

  func testNetworkReceiveMeterDropsOversizedPartialInput() {
    var meter = NetworkReceiveMeter(processID: 42)
    meter.append(Data(",bytes_in,\nsteamcmd.42,600000,\n".utf8), at: 0)
    meter.append(Data("steamcmd.42,300000,\n".utf8), at: 1)
    XCTAssertEqual(meter.rate(at: 1), 300_000)
    meter.append(Data(repeating: 0x61, count: 70_000), at: 2)
    XCTAssertNil(meter.rate(at: 2))
    meter.append(Data("steamcmd.42,300000,\n".utf8), at: 3)
    XCTAssertNil(meter.rate(at: 3))
    meter.append(Data(",bytes_in,\nsteamcmd.42,600000,\n".utf8), at: 4)
    XCTAssertNil(meter.rate(at: 4))
    meter.append(Data("steamcmd.42,300000,\n".utf8), at: 5)
    XCTAssertEqual(meter.rate(at: 5), 300_000)
  }

  func testNetworkReceiveMeterResetsOnBatchedSameTimestampSamples() {
    var meter = NetworkReceiveMeter(processID: 42)
    meter.append(Data(",bytes_in,\nsteamcmd.42,1000,\nsteamcmd.42,900000000,\n".utf8), at: 1)
    XCTAssertNil(meter.rate(at: 1))
    meter.append(Data("steamcmd.42,300000,\n".utf8), at: 2)
    XCTAssertEqual(meter.rate(at: 2), 300_000)
  }

  func testNetworkReceiveMeterTotalsEveryRowAfterTheFirst() {
    var meter = NetworkReceiveMeter(processID: 42)
    func row(_ bytes: Int64) -> Data { Data(",bytes_in,\nsteamcmd.42,\(bytes),\n".utf8) }
    XCTAssertEqual(meter.bytesReceived, 0)
    // nettop's first row carries everything since the process launched: sign-in, not transfer.
    meter.append(row(9_000_000), at: 0)
    XCTAssertEqual(meter.bytesReceived, 0)
    meter.append(row(600_000), at: 1)
    XCTAssertEqual(meter.bytesReceived, 600_000)
    // Rows other processes, malformed numbers and negative values never count.
    meter.append(Data(",bytes_in,\nsteamcmd.142,999999,\nsteamcmd.42,-1,\nsteamcmd.42,NaN,\n".utf8), at: 1.5)
    XCTAssertEqual(meter.bytesReceived, 600_000)
    // A row outside the rate window or batched at one timestamp still carries real bytes.
    meter.append(row(50_000), at: 20)
    XCTAssertNil(meter.rate(at: 20))
    XCTAssertEqual(meter.bytesReceived, 650_000)
    meter.append(Data(",bytes_in,\nsteamcmd.42,1000,\nsteamcmd.42,2000,\n".utf8), at: 21)
    XCTAssertEqual(meter.bytesReceived, 653_000)
    // Runaway partial output resets the rate window but keeps the total.
    meter.append(Data(String(repeating: "x", count: 70_000).utf8), at: 22)
    XCTAssertEqual(meter.bytesReceived, 653_000)
    meter.append(row(4_000), at: 23)
    XCTAssertEqual(meter.bytesReceived, 657_000)
    XCTAssertNil(meter.rate(at: 23))
    meter.append(row(5_000), at: 24)
    XCTAssertEqual(meter.rate(at: 24), 5_000)
  }

  func testNetworkRateIsIndependentOfWorkshopSizeAndClearsOnCancellation() async throws {
    let root = try makeRuntime("""
      printf 'password: '
      IFS= read -r password
      printf '\\nWaiting for user info...OK\\nDownloading item 123456 ... (75%%)\\n'
      IFS= read -r finish
      """)
    defer { try? FileManager.default.removeItem(at: root) }
    let monitor = FixtureNetworkMonitor()
    monitor.value = 600_000
    let downloader = startDownload(in: root, networkMonitor: monitor)
    do {
      try await waitUntil { downloader.prompt == .password }
      XCTAssertNil(downloader.bytesPerSecond)
      XCTAssertTrue(monitor.startedPIDs.isEmpty)
      downloader.submitSecret("fixture")
      try await waitUntil { downloader.bytesPerSecond == 600_000 }
      XCTAssertNil(downloader.progress)
      XCTAssertNil(downloader.bytesReceived)
      XCTAssertNil(downloader.bytesExpected)
      XCTAssertEqual(monitor.startedPIDs.count, 1)
      monitor.value = 0
      try await waitUntil { downloader.bytesPerSecond == 0 }
      monitor.value = nil
      try await waitUntil { downloader.bytesPerSecond == nil }
      monitor.value = 600_000
      try await waitUntil { downloader.bytesPerSecond == 600_000 }
      downloader.cancel()
      XCTAssertNil(downloader.bytesPerSecond)
      await downloader.shutdown()
      XCTAssertNil(downloader.progress)
      XCTAssertNil(downloader.bytesPerSecond)
      XCTAssertEqual(monitor.stopCount, 1)
    } catch { await downloader.shutdown(); throw error }
  }

  func testCompletedDownloadClearsTransferTelemetry() async throws {
    let root = try makeRuntime("""
      printf 'password: '
      IFS= read -r password
      printf '\\nWaiting for user info...OK\\nDownloading item 123456 ...\\n'
      while [ ! -f ../release-content ]; do sleep 0.02; done
      mkdir -p steamapps/workshop/content/431960/123456
      printf '{"type":"video","file":"movie.mp4"}' > steamapps/workshop/content/431960/123456/project.json
      printf 'real-content' > steamapps/workshop/content/431960/123456/movie.mp4
      printf 'Success. Downloaded item 123456\\n'
      """)
    defer { try? FileManager.default.removeItem(at: root) }
    let monitor = FixtureNetworkMonitor()
    monitor.value = 450_000
    let downloader = WorkshopDownloader(
      sessionDirectory: root.appendingPathComponent("SteamSession"),
      runtimeProvider: ShellRuntimeProvider(),
      networkMonitor: monitor)
    downloader.start(
      item: item, username: "localtest",
      executable: root.appendingPathComponent("runtime/steamcmd"),
      library: root.appendingPathComponent("Library"), rememberSession: false
    ) {
      XCTAssertNil(downloader.bytesPerSecond)
      XCTAssertNil(downloader.bytesReceived)
      XCTAssertNil(downloader.bytesExpected)
      XCTAssertNil(downloader.progress)
    }
    do {
      try await waitUntil { downloader.prompt == .password }
      downloader.submitSecret("fixture")
      try await waitUntil { downloader.bytesPerSecond == 450_000 }
      try Data().write(to: root.appendingPathComponent("release-content"))
      try await waitUntil { !downloader.isRunning }
      XCTAssertNil(downloader.errorMessage)
      XCTAssertEqual(downloader.downloadedID, item.id)
      XCTAssertNil(downloader.progress)
      XCTAssertNil(downloader.bytesReceived)
      XCTAssertNil(downloader.bytesExpected)
      XCTAssertNil(downloader.bytesPerSecond)
      XCTAssertEqual(monitor.stopCount, 1)
      XCTAssertEqual(
        try String(
          contentsOf: root.appendingPathComponent("Library/123456/movie.mp4"), encoding: .utf8),
        "real-content")
    } catch { await downloader.shutdown(); throw error }
  }

  func testFailedDownloadClearsTransferTelemetryAndStopsMonitor() async throws {
    let root = try makeRuntime("""
      printf 'password: '
      IFS= read -r password
      printf '\\nWaiting for user info...OK\\nDownloading item 123456 ...\\n'
      while [ ! -f ../release-failure ]; do sleep 0.02; done
      printf 'ERROR! Download item 123456 failed (Access Denied).\\n'
      exit 1
      """)
    defer { try? FileManager.default.removeItem(at: root) }
    let monitor = FixtureNetworkMonitor()
    monitor.value = 300_000
    let downloader = startDownload(in: root, networkMonitor: monitor)
    do {
      try await waitUntil { downloader.prompt == .password }
      downloader.submitSecret("fixture")
      try await waitUntil { downloader.bytesPerSecond == 300_000 }
      try Data().write(to: root.appendingPathComponent("release-failure"))
      try await waitUntil { !downloader.isRunning }
      XCTAssertNotNil(downloader.errorMessage)
      XCTAssertNil(downloader.downloadedID)
      XCTAssertNil(downloader.progress)
      XCTAssertNil(downloader.bytesReceived)
      XCTAssertNil(downloader.bytesExpected)
      XCTAssertNil(downloader.bytesPerSecond)
      XCTAssertEqual(monitor.startedPIDs.count, 1)
      XCTAssertEqual(monitor.stopCount, 1)
    } catch { await downloader.shutdown(); throw error }
  }

  func testMonitorFailureDoesNotDisturbTransfer() async throws {
    let root = try makeRuntime("""
      printf 'password: '
      IFS= read -r password
      printf '\\nWaiting for user info...OK\\nDownloading item 123456 ...\\n'
      while [ ! -f ../release-download ]; do sleep 0.02; done
      mkdir -p steamapps/workshop/content/431960/123456
      printf '{"type":"video","file":"movie.mp4"}' > steamapps/workshop/content/431960/123456/project.json
      printf 'monitor-isolated-content' > steamapps/workshop/content/431960/123456/movie.mp4
      printf 'Success. Downloaded item 123456\\n'
      """)
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = FailingNetworkRunner()
    let downloader = WorkshopDownloader(
      sessionDirectory: root.appendingPathComponent("SteamSession"),
      runtimeProvider: ShellRuntimeProvider(),
      networkMonitor: ProcessNetworkMonitor(runner: runner))
    downloader.start(
      item: item, username: "localtest",
      executable: root.appendingPathComponent("runtime/steamcmd"),
      library: root.appendingPathComponent("Library"), rememberSession: false, onImported: {})
    do {
      try await waitUntil { downloader.prompt == .password }
      downloader.submitSecret("fixture")
      try await waitUntil { runner.invocation != nil }
      let invocation = try XCTUnwrap(runner.invocation)
      XCTAssertEqual(invocation.0.path, "/usr/bin/nettop")
      let arguments = invocation.1
      XCTAssertEqual(arguments.count, 12)
      let pid = try XCTUnwrap(arguments.count > 4 ? Int32(arguments[4]) : nil)
      XCTAssertGreaterThan(pid, 0)
      XCTAssertEqual(arguments, ["-P", "-L", "0", "-p", String(pid), "-n", "-x", "-d", "-s", "1", "-J", "bytes_in"])
      XCTAssertTrue(downloader.isRunning)
      XCTAssertNil(downloader.errorMessage)
      XCTAssertNil(downloader.bytesPerSecond)
      try Data().write(to: root.appendingPathComponent("release-download"))
      try await waitUntil { !downloader.isRunning }
      XCTAssertNil(downloader.errorMessage)
      XCTAssertEqual(downloader.downloadedID, item.id)
      XCTAssertNil(downloader.bytesPerSecond)
      XCTAssertEqual(
        try String(
          contentsOf: root.appendingPathComponent("Library/123456/movie.mp4"), encoding: .utf8),
        "monitor-isolated-content")
    } catch { await downloader.shutdown(); throw error }
  }

  func testRestartRestartsMonitorWithFreshProcessAndNoStaleRate() async throws {
    let root = try makeRuntime("""
      printf 'password: '
      IFS= read -r password
      printf '\\nWaiting for user info...OK\\nDownloading item 123456 ...\\n'
      if [ -f ../second-pass ]; then
          touch ../second-launch
          IFS= read -r finish
      else
          touch ../first-launch
          while [ ! -f ../release-first ]; do sleep 0.02; done
          exit 42
      fi
      """)
    defer { try? FileManager.default.removeItem(at: root) }
    let monitor = FixtureNetworkMonitor()
    monitor.value = 500_000
    let downloader = startDownload(in: root, networkMonitor: monitor)
    do {
      try await waitUntil { downloader.prompt == .password }
      downloader.submitSecret("fixture")
      try await waitUntil { monitor.startedPIDs.count == 1 }
      try await waitUntil { downloader.bytesPerSecond == 500_000 }
      monitor.value = nil
      try Data().write(to: root.appendingPathComponent("second-pass"))
      try Data().write(to: root.appendingPathComponent("release-first"))
      try await waitUntil { downloader.prompt == .password }
      downloader.submitSecret("fixture")
      try await waitUntil { monitor.startedPIDs.count == 2 }
      XCTAssertEqual(monitor.stopCount, 1)
      XCTAssertNotEqual(monitor.startedPIDs[0], monitor.startedPIDs[1])
      XCTAssertNil(downloader.bytesPerSecond)
      monitor.value = 700_000
      try await waitUntil { downloader.bytesPerSecond == 700_000 }
      await downloader.shutdown()
      XCTAssertTrue(downloader.wasCancelled)
      XCTAssertEqual(monitor.stopCount, 2)
    } catch { await downloader.shutdown(); throw error }
  }

  func testAppUpdatePhaseProgressTracksExplicitByteCountersOnly() async throws {
    let root = try makeRuntime("""
      mkdir -p wallpaper-engine/assets/shaders
      printf 'partial' > wallpaper-engine/assets/shaders/genericimage2.vert
      printf 'Update state (0x61) downloading, progress: 25.00 (250 / 1000)\\n'
      touch ../phase-one
      while [ ! -f ../next-phase ]; do sleep 0.02; done
      printf 'Update state (0x36) verifying, progress: 50.00 (500 / 1000)\\n'
      touch ../phase-two
      while [ ! -f ../final-phase ]; do sleep 0.02; done
      printf 'Update state (0x61) downloading, progress: 0.00 (0 / 0)\\n'
      touch ../phase-three
      IFS= read -r finish
      """)
    defer { try? FileManager.default.removeItem(at: root) }
    let monitor = FixtureNetworkMonitor()
    monitor.value = 400_000
    let downloader = WorkshopDownloader(
      sessionDirectory: root.appendingPathComponent("SteamSession"),
      runtimeProvider: ShellRuntimeProvider(),
      networkMonitor: monitor, freeSpace: { _ in nil })
    downloader.installAssets(
      username: "localtest", executable: root.appendingPathComponent("runtime/steamcmd"),
      destination: root.appendingPathComponent("SceneAssets")
    ) { XCTFail("The incomplete install must not publish assets") }
    do {
      try await waitUntil { FileManager.default.fileExists(atPath: root.appendingPathComponent("phase-one").path) }
      try await waitUntil { downloader.progress == 0.25 }
      try await waitUntil { downloader.bytesPerSecond == 400_000 }
      XCTAssertEqual(downloader.bytesReceived, 250)
      XCTAssertEqual(downloader.bytesExpected, 1000)
      try Data().write(to: root.appendingPathComponent("next-phase"))
      try await waitUntil { FileManager.default.fileExists(atPath: root.appendingPathComponent("phase-two").path) }
      try await waitUntil { downloader.progress == 0.5 }
      XCTAssertNil(downloader.bytesReceived)
      XCTAssertNil(downloader.bytesExpected)
      try await waitUntil { downloader.bytesPerSecond == nil }
      try Data().write(to: root.appendingPathComponent("final-phase"))
      try await waitUntil { FileManager.default.fileExists(atPath: root.appendingPathComponent("phase-three").path) }
      try await waitUntil { downloader.progress == nil }
      XCTAssertNil(downloader.bytesReceived)
      XCTAssertNil(downloader.bytesExpected)
      await downloader.shutdown()
    } catch { await downloader.shutdown(); throw error }
  }

  func testNetworkMonitorStreamsSamplesBeforeProcessExits() async throws {
    let listener = socket(AF_INET, SOCK_STREAM, 0)
    XCTAssertGreaterThanOrEqual(listener, 0)
    guard listener >= 0 else { return }
    defer { close(listener) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    XCTAssertEqual(bound, 0)
    guard bound == 0 else { return }
    XCTAssertEqual(listen(listener, 1), 0)
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let located = withUnsafeMutablePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) }
    }
    XCTAssertEqual(located, 0)
    guard located == 0 else { return }
    let client = socket(AF_INET, SOCK_STREAM, 0)
    XCTAssertGreaterThanOrEqual(client, 0)
    guard client >= 0 else { return }
    defer { close(client) }
    let connected = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(client, $0, length) }
    }
    XCTAssertEqual(connected, 0)
    guard connected == 0 else { return }
    let peer = accept(listener, nil, nil)
    XCTAssertGreaterThanOrEqual(peer, 0)
    guard peer >= 0 else { return }
    defer { close(peer) }
    var byte: UInt8 = 1
    XCTAssertEqual(send(client, &byte, 1, 0), 1)
    XCTAssertEqual(recv(peer, &byte, 1, 0), 1)
    let monitor = ProcessNetworkMonitor()
    monitor.start(processID: getpid())
    do {
      let deadline = ProcessInfo.processInfo.systemUptime + 8
      while monitor.rate(at: ProcessInfo.processInfo.systemUptime) == nil,
            ProcessInfo.processInfo.systemUptime < deadline {
        try await Task.sleep(for: .milliseconds(100))
      }
      XCTAssertNotNil(monitor.rate(at: ProcessInfo.processInfo.systemUptime), "nettop output must stream before its process exits")
      await monitor.stop()
      XCTAssertNil(monitor.rate(at: ProcessInfo.processInfo.systemUptime))
    } catch { await monitor.stop(); throw error }
  }

  /// SteamCMD prints nothing while it fetches an item, so a transfer whose bytes keep arriving
  /// outlives both time limits, and one whose bytes stop is ended as a stalled download rather
  /// than as an unfinished sign-in.
  func testSilentTransferRunsWhileBytesArriveAndStopsWhenTheyStop() async throws {
    let root = try makeRuntime("""
      printf 'Waiting for user info...OK\\nDownloading item 123456 ...\\n'
      IFS= read -r finish
      """)
    defer { try? FileManager.default.removeItem(at: root) }
    let monitor = FixtureNetworkMonitor()
    monitor.received = 0
    // Both limits run on this clock, so a slow launch or a late wakeup under load cannot use
    // them up; only the steps below move it. The stall is meant to end the run here, so the
    // automatic retry of a stalled transfer (`DownloaderRetryTests`) is off.
    var clock = Date(timeIntervalSinceReferenceDate: 0)
    let downloader = WorkshopDownloader(
      sessionDirectory: root.appendingPathComponent("SteamSession"),
      runtimeProvider: ShellRuntimeProvider(), networkMonitor: monitor,
      inactivityTimeout: 1, passTimeout: 1.5, now: { clock }, retryDelays: [])
    downloader.start(
      item: item, username: "localtest", executable: root.appendingPathComponent("runtime/steamcmd"),
      library: root.appendingPathComponent("Library"), rememberSession: false, onImported: {})
    /// Waits for the downloader's next byte reading, which it checks its limits against in the
    /// same main-actor turn.
    func nextCheck() async throws {
      let readings = monitor.receivedReadings
      try await waitUntil { monitor.receivedReadings > readings || !downloader.isRunning }
    }
    do {
      try await waitUntil { monitor.startedPIDs.count == 1 }
      // Bytes land every 0.6 s, under the inactivity limit, for longer than both limits.
      for _ in 0..<6 {
        monitor.received = (monitor.received ?? 0) + 1024
        try await nextCheck()
        clock += 0.6
      }
      try await nextCheck()
      XCTAssertTrue(downloader.isRunning, downloader.errorMessage ?? "")
      XCTAssertNil(downloader.errorMessage)
      clock += 1.1
      try await waitUntil { !downloader.isRunning }
      XCTAssertNotNil(downloader.errorMessage)
      XCTAssertFalse(downloader.canRetryAuthentication)
      await downloader.shutdown()
    } catch { await downloader.shutdown(); throw error }
  }
}
