import Darwin
import XCTest

@testable import WallpaperMachine

final class LockScreenExtensionProcessesTests: XCTestCase {
  private let expected = URL(
    fileURLWithPath: "/Apps/Current.app/Contents/Extensions/WallpaperMachineExtension.appex")
  private let otherBundle = "/Apps/Old.app/Contents/Extensions/WallpaperMachineExtension.appex"
  private let stamp = Date(timeIntervalSince1970: 1_000)

  private func process(
    _ pid: pid_t, bundle: String? = nil, startedAfterStamp offset: TimeInterval = 60
  ) -> LockScreenExtensionProcess {
    FakeExtensionProcessTable.process(
      pid, bundle: bundle ?? expected.path, started: stamp.addingTimeInterval(offset))
  }

  func testOnlyOtherCopiesAndReplacedBinariesAreStale() {
    let fresh = process(1, startedAfterStamp: 60)
    let replaced = process(2, startedAfterStamp: -60)
    let other = process(3, bundle: otherBundle, startedAfterStamp: 60)
    // Another copy is stale whatever its binary's age; a process of the expected copy only
    // when its executable changed after the process started.
    let result = LockScreenExtensionProcesses.stale(
      [fresh, replaced, other], expected: expected, stamp: { _ in self.stamp }, images: { _ in [] })
    XCTAssertEqual(result.map(\.process.pid), [2, 3])
    XCTAssertEqual(result.map(\.staleness), [.replacedInPlace, .otherCopy])
  }

  func testAnUnreadableStampOrAnEmptyTableNeverMakesAProcessStale() {
    XCTAssertTrue(
      LockScreenExtensionProcesses.stale([], expected: expected, stamp: { _ in nil }, images: { _ in [] }).isEmpty)
    XCTAssertTrue(
      LockScreenExtensionProcesses.stale(
        [process(1)], expected: expected, stamp: { _ in nil }, images: { _ in [] }
      ).isEmpty, "Without a readable timestamp the process of the expected copy must be kept")
    XCTAssertTrue(
      LockScreenExtensionProcesses.stale(
        [process(1, startedAfterStamp: 0)], expected: expected, stamp: { _ in self.stamp }, images: { _ in [] }
      ).isEmpty, "A binary stamped at the exact start time was not replaced afterwards")
  }

  func testTheExpectedCopyReachedThroughASymlinkIsNotAnotherCopy() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let real = root.appendingPathComponent("Real.app/Contents/Extensions/WallpaperMachineExtension.appex")
    try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
    let link = root.appendingPathComponent("Link.app")
    try FileManager.default.createSymbolicLink(
      at: link, withDestinationURL: root.appendingPathComponent("Real.app"))
    let viaLink = link.appendingPathComponent("Contents/Extensions/WallpaperMachineExtension.appex")
    let result = LockScreenExtensionProcesses.stale(
      [FakeExtensionProcessTable.process(1, bundle: real.resolvingSymlinksInPath().path)],
      expected: viaLink, stamp: { _ in nil }, images: { _ in [] })
    XCTAssertTrue(result.isEmpty)
  }

  func testACopyThatKeptItsSourcesDatesIsStaleWhenItsBuildDiffers() {
    let old = UUID()
    let current = UUID()
    let registered = LockScreenExtensionProcesses.executable(in: expected)
    // The executable at the path is dated before the process started, as `ditto` or `cp -p`
    // leave a release's binary copied over a running helper's.
    func verdicts(
      _ process: LockScreenExtensionProcess, _ images: Set<UUID>, stamp: Date? = nil
    ) -> [LockScreenExtensionStaleness] {
      LockScreenExtensionProcesses.stale(
        [process], expected: expected, stamp: { _ in stamp ?? self.stamp },
        images: { $0 == registered ? images : [] }
      ).map(\.staleness)
    }
    func running(_ image: UUID?, bundle: String? = nil) -> LockScreenExtensionProcess {
      FakeExtensionProcessTable.process(
        1, bundle: bundle ?? expected.path, started: stamp.addingTimeInterval(3_600), image: image)
    }

    XCTAssertEqual(verdicts(running(old), [current]), [.replacedInPlace])
    XCTAssertEqual(
      verdicts(running(old), [current, UUID()]), [.replacedInPlace],
      "A universal registered binary counts every slice")
    XCTAssertEqual(
      verdicts(running(current), [UUID(), current]), [],
      "The registered build itself, copied over its own path again, is not stale")
    XCTAssertEqual(verdicts(running(nil), [current]), [], "Without the process's build nothing proves it differs")
    XCTAssertEqual(
      verdicts(running(old), []), [], "Without the registered binary's build nothing proves it differs")
    XCTAssertEqual(
      verdicts(running(old), [current], stamp: stamp.addingTimeInterval(7_200)), [.replacedInPlace],
      "A newer file is stale whatever it holds")
    XCTAssertEqual(
      LockScreenExtensionProcesses.stale(
        [running(old)], expected: expected, stamp: { _ in nil }, images: { _ in [current] }
      ).map(\.staleness),
      [.replacedInPlace], "An unreadable timestamp does not hide a build that provably differs")
    XCTAssertEqual(
      verdicts(running(current, bundle: otherBundle), [current]), [.otherCopy],
      "Another bundle is stale even when it runs the registered build")
  }

  // MARK: - Processes whose files are gone (an in-app update deletes the old app)

  func testAProcessWithoutAPathIsStaleOnlyWhenItsBuildProvablyDiffers() {
    let old = UUID()
    let current = UUID()
    let registered = LockScreenExtensionProcesses.executable(in: expected)
    func verdicts(_ process: LockScreenExtensionProcess, _ images: Set<UUID>, stamp: Date? = nil)
      -> [LockScreenExtensionStaleness]
    {
      LockScreenExtensionProcesses.stale(
        [process], expected: expected, stamp: { _ in stamp },
        images: { $0 == registered ? images : [] }
      ).map(\.staleness)
    }

    XCTAssertEqual(verdicts(FakeExtensionProcessTable.deletedProcess(1, image: old), [current]), [.deletedBuild])
    XCTAssertEqual(
      verdicts(FakeExtensionProcessTable.deletedProcess(1, image: old), [current, UUID()]), [.deletedBuild],
      "A universal registered binary counts every slice")
    XCTAssertEqual(
      verdicts(FakeExtensionProcessTable.deletedProcess(1, image: current), [UUID(), current]), [],
      "The registered build itself, left running after a reinstall, is not stale")
    XCTAssertEqual(
      verdicts(FakeExtensionProcessTable.deletedProcess(1), [current]), [],
      "Without the process's build nothing proves it differs")
    XCTAssertEqual(
      verdicts(FakeExtensionProcessTable.deletedProcess(1, image: old), []), [],
      "Without the registered binary's build nothing proves it differs")
    // File dates play no part: an update keeps the release's build dates, which are older
    // than the moment the old helper started.
    XCTAssertEqual(
      verdicts(
        FakeExtensionProcessTable.deletedProcess(1, started: stamp.addingTimeInterval(3_600), image: old),
        [current], stamp: stamp),
      [.deletedBuild])
  }

  func testTheRegisteredBuildIsReadFromTheExpectedBundlesExecutable() async {
    let old = UUID()
    let current = UUID()
    let table = FakeExtensionProcessTable([
      FakeExtensionProcessTable.deletedProcess(90, image: old),
      FakeExtensionProcessTable.deletedProcess(91, image: current),
      FakeExtensionProcessTable.deletedProcess(92),
      process(93, startedAfterStamp: 60),
    ])
    table.setImages([current], for: LockScreenExtensionProcesses.executable(in: expected))
    let outcome = await table.processes.terminateStale(expected: expected)
    XCTAssertEqual(table.signals, [.init(pid: 90, number: SIGTERM)])
    XCTAssertEqual(outcome.ended, [90])
    XCTAssertTrue(outcome.skipped.isEmpty)
  }

  func testAHelperOfTheRegisteredPathRunningAnotherBuildIsEndedEvenWithOlderFileDates() async {
    let old = UUID()
    let current = UUID()
    let table = FakeExtensionProcessTable([
      FakeExtensionProcessTable.process(94, started: stamp.addingTimeInterval(60), image: old),
      FakeExtensionProcessTable.process(95, started: stamp.addingTimeInterval(60), image: current),
      FakeExtensionProcessTable.process(96, started: stamp.addingTimeInterval(60)),
    ])
    let executable = LockScreenExtensionProcesses.executable(in: expected)
    table.setStamp(stamp, for: executable)
    table.setImages([current], for: executable)
    let outcome = await table.processes.terminateStale(expected: expected)
    XCTAssertEqual(table.signals, [.init(pid: 94, number: SIGTERM)])
    XCTAssertEqual(outcome.ended, [94])
    XCTAssertTrue(outcome.skipped.isEmpty)
  }

  func testTerminationEscalatesOnlyForSurvivors() async {
    // Pid 13 has no scripted reaction, so it exits on SIGTERM at once; pid 12 belongs to the
    // expected copy and must be left alone.
    let table = FakeExtensionProcessTable(
      [process(10, bundle: otherBundle), process(11, bundle: otherBundle), process(12),
        process(13, bundle: otherBundle)],
      reactions: [10: .exitsOnTerm(afterSleeps: 2), 11: .ignoresTerm])
    let outcome = await table.processes.terminateStale(expected: expected)
    XCTAssertEqual(
      table.signals,
      [
        .init(pid: 10, number: SIGTERM), .init(pid: 11, number: SIGTERM),
        .init(pid: 13, number: SIGTERM), .init(pid: 11, number: SIGKILL),
      ])
    XCTAssertEqual(outcome.ended.sorted(), [10, 13])
    XCTAssertEqual(outcome.forced, [11])
    XCTAssertTrue(outcome.skipped.isEmpty)
    XCTAssertTrue(outcome.survived.isEmpty)
  }

  func testAProcessThatExitsDuringTheGracePeriodNeverReceivesSIGKILL() async {
    let table = FakeExtensionProcessTable(
      [process(20, bundle: otherBundle)], reactions: [20: .exitsOnTerm(afterSleeps: 5)])
    let outcome = await table.processes.terminateStale(expected: expected)
    XCTAssertEqual(table.signals, [.init(pid: 20, number: SIGTERM)])
    XCTAssertEqual(outcome.ended, [20])
    XCTAssertEqual(table.sleeps, 5, "It polls only until the process is gone")
  }

  func testAProcessWhoseIdentityChangedIsNeverEscalated() async {
    let table = FakeExtensionProcessTable(
      [process(30, bundle: otherBundle), process(31, bundle: otherBundle)],
      reactions: [30: .reused, 31: .exitsOnTerm(afterSleeps: 0)])
    let outcome = await table.processes.terminateStale(expected: expected)
    XCTAssertEqual(outcome.skipped, [30])
    XCTAssertEqual(outcome.ended, [31])
    XCTAssertTrue(outcome.forced.isEmpty)
    XCTAssertEqual(table.signals, [.init(pid: 31, number: SIGTERM)])
  }

  func testAProcessThatSurvivesSIGKILLIsReportedAndTheWaitStaysBounded() async {
    let table = FakeExtensionProcessTable(
      [process(40, bundle: otherBundle)], reactions: [40: .unkillable])
    let outcome = await table.processes.terminateStale(expected: expected)
    XCTAssertEqual(
      table.signals, [.init(pid: 40, number: SIGTERM), .init(pid: 40, number: SIGKILL)])
    XCTAssertEqual(outcome.forced, [40])
    XCTAssertEqual(outcome.survived, [40])
    XCTAssertEqual(
      table.sleeps, LockScreenExtensionProcesses.polls + LockScreenExtensionProcesses.confirmPolls)
  }

  func testAReplacedBinaryOfTheExpectedCopyIsEndedButANewerProcessIsKept() async {
    let table = FakeExtensionProcessTable([
      process(50, startedAfterStamp: -100), process(51, startedAfterStamp: 100),
    ])
    table.setStamp(stamp, for: LockScreenExtensionProcesses.executable(in: expected))
    let outcome = await table.processes.terminateStale(expected: expected)
    XCTAssertEqual(table.signals, [.init(pid: 50, number: SIGTERM)])
    XCTAssertEqual(outcome.ended, [50])
  }

  func testNothingStaleMeansNoSignalsAndNoDelay() async {
    let table = FakeExtensionProcessTable([process(60)])
    let outcome = await table.processes.terminateStale(expected: expected)
    XCTAssertEqual(outcome, .init())
    XCTAssertTrue(table.signals.isEmpty)
    XCTAssertEqual(table.sleeps, 0)
  }

  func testACancelledTerminationSendsNothing() async {
    let table = FakeExtensionProcessTable([process(70, bundle: otherBundle)])
    let task = Task { () -> LockScreenExtensionProcesses.Outcome in
      withUnsafeCurrentTask { $0?.cancel() }
      return await table.processes.terminateStale(expected: expected)
    }
    _ = await task.value
    XCTAssertTrue(table.signals.isEmpty)
  }

  func testCancellationDuringTheGracePeriodNeverEscalatesToSIGKILL() async {
    let table = FakeExtensionProcessTable(
      [process(80, bundle: otherBundle)], reactions: [80: .ignoresTerm])
    let task = Task { () -> LockScreenExtensionProcesses.Outcome in
      var processes = table.processes
      let inner = processes.sleep
      processes.sleep = { duration in
        await inner(duration)
        withUnsafeCurrentTask { $0?.cancel() }
      }
      return await processes.terminateStale(expected: expected)
    }
    let outcome = await task.value
    XCTAssertEqual(table.signals, [.init(pid: 80, number: SIGTERM)])
    XCTAssertEqual(outcome.survived, [80])
    XCTAssertTrue(outcome.forced.isEmpty)
  }

  func testInertNeverSeesOrSignalsAnything() async {
    let inert = LockScreenExtensionProcesses.inert
    XCTAssertTrue(inert.list().isEmpty)
    let outcome = await inert.terminateStale(expected: expected)
    XCTAssertEqual(outcome, .init())
  }

  // MARK: - Live libproc behaviour against a child this test owns

  /// A tiny program that sleeps; each duration is a different program, hence a different build.
  private func compileSleeper(seconds: Int, in root: URL) throws -> URL {
    let source = root.appendingPathComponent("sleeper\(seconds).c")
    let program = root.appendingPathComponent("sleeper\(seconds)")
    try "#include <unistd.h>\nint main(void) { sleep(\(seconds)); return 0; }\n"
      .write(to: source, atomically: true, encoding: .utf8)
    let compiler = Process()
    compiler.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
    compiler.arguments = [source.path, "-o", program.path]
    compiler.standardError = FileHandle.nullDevice
    do { try compiler.run() } catch { throw XCTSkip("No C compiler to build a stand-in process: \(error)") }
    compiler.waitUntilExit()
    guard compiler.terminationStatus == 0 else { throw XCTSkip("No working C compiler to build a stand-in process") }
    return program
  }

  /// A tiny sleeping program named like the extension inside a bundle with its identifier,
  /// run as a child of the test host. It is the only process these tests ever signal. The
  /// system tools cannot stand in for it: macOS kills a copy of an arm64e binary at launch.
  private func spawnFakeExtension() throws -> (bundle: URL, child: Process, original: URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let bundle = root.appendingPathComponent("Fake.appex")
    let binary = bundle.appendingPathComponent("Contents/MacOS/WallpaperMachineExtension")
    try FileManager.default.createDirectory(
      at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
    try PropertyListSerialization.data(fromPropertyList: [
      "CFBundleIdentifier": LockScreenConfiguration.extensionIdentifier,
      "CFBundleExecutable": "WallpaperMachineExtension", "CFBundlePackageType": "XPC!",
    ], format: .xml, options: 0).write(to: bundle.appendingPathComponent("Contents/Info.plist"))

    let original = try compileSleeper(seconds: 120, in: root)
    try FileManager.default.copyItem(at: original, to: binary)

    let child = Process()
    child.executableURL = binary
    addTeardownBlock {
      if child.isRunning { child.terminate() }
      child.waitUntilExit()
    }
    try child.run()
    return (bundle, child, original)
  }

  func testLiveTableClassifiesAChildFromItsBundleAndItsReplacedBinary() throws {
    let (bundle, child, original) = try spawnFakeExtension()
    let live = LockScreenExtensionProcesses.live
    let found = try XCTUnwrap(
      live.list().first { $0.pid == child.processIdentifier },
      "The live table must list this user's process running the extension executable")
    XCTAssertTrue(LockScreenExtensionDiagnostics.isSameBundle(try XCTUnwrap(found.bundle), bundle))
    XCTAssertEqual(found.startedAt.timeIntervalSinceNow, 0, accuracy: 30)
    func verdicts(of process: LockScreenExtensionProcess, expected: URL) -> [LockScreenExtensionStaleness] {
      LockScreenExtensionProcesses.stale(
        [process], expected: expected, stamp: live.executableStamp, images: live.executableImages
      ).map(\.staleness)
    }

    XCTAssertEqual(verdicts(of: found, expected: bundle), [], "The binary predates the process")
    XCTAssertEqual(
      verdicts(of: found, expected: bundle.deletingLastPathComponent().appendingPathComponent("Other.appex")),
      [.otherCopy])

    // Replace the binary the way a build does: delete it and write a new file at its path.
    // (Copies that keep the source's timestamps, such as `ditto`, carry the source's age.)
    let binary = try XCTUnwrap(found.executable)
    try FileManager.default.removeItem(at: binary)
    try Data(contentsOf: original).write(to: binary)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
    let again = try XCTUnwrap(
      live.list().first { $0.pid == child.processIdentifier },
      "The path of a process still resolves after its executable was replaced")
    XCTAssertEqual(again, found)
    XCTAssertEqual(verdicts(of: again, expected: bundle), [.replacedInPlace])
  }

  func testLiveTableCatchesACopiedBinaryThatKeptItsSourcesDates() throws {
    let (bundle, child, original) = try spawnFakeExtension()
    let live = LockScreenExtensionProcesses.live
    let found = try XCTUnwrap(live.list().first { $0.pid == child.processIdentifier })
    let rebuilt = try compileSleeper(seconds: 121, in: bundle.deletingLastPathComponent())
    XCTAssertNotEqual(
      MachOImageUUIDs.uuids(at: rebuilt), MachOImageUUIDs.uuids(at: original),
      "The two stand-in programs must be different builds")
    func verdicts() -> [LockScreenExtensionStaleness] {
      LockScreenExtensionProcesses.stale(
        [found], expected: bundle, stamp: live.executableStamp, images: live.executableImages
      ).map(\.staleness)
    }

    // What `ditto`, `cp -p` or Finder leave at the path: another binary dated like its source,
    // older than the moment the helper started.
    func copyOver(_ source: URL) throws {
      let binary = try XCTUnwrap(found.executable)
      try FileManager.default.removeItem(at: binary)
      try FileManager.default.copyItem(at: source, to: binary)
      let old = found.startedAt.addingTimeInterval(-3_600)
      try FileManager.default.setAttributes(
        [.creationDate: old, .modificationDate: old, .posixPermissions: 0o755], ofItemAtPath: binary.path)
      let stamp = try XCTUnwrap(live.executableStamp(binary))
      XCTAssertLessThan(stamp, found.startedAt, "The copy must look older than the running process")
    }
    try copyOver(original)
    XCTAssertEqual(verdicts(), [], "The same build copied over its own path is kept")
    try copyOver(rebuilt)
    XCTAssertEqual(verdicts(), [.replacedInPlace], "Dates alone cannot see a copy that keeps its source's")
  }

  /// A bundle holding only the extension's executable, as a registered copy would.
  private func registeredBundle(containing binary: Data) throws -> URL {
    let bundle = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .appendingPathComponent("Registered.appex")
    addTeardownBlock { try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent()) }
    let executable = LockScreenExtensionProcesses.executable(in: bundle)
    try FileManager.default.createDirectory(
      at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
    try binary.write(to: executable)
    return bundle
  }

  func testLiveTableKeepsRecognisingAProcessAfterItsFilesAreDeleted() throws {
    let (bundle, child, original) = try spawnFakeExtension()
    let live = LockScreenExtensionProcesses.live
    let before = try XCTUnwrap(live.list().first { $0.pid == child.processIdentifier })
    let build = try XCTUnwrap(before.imageUUID, "The kernel keeps the build of a running process")
    XCTAssertEqual(MachOImageUUIDs.uuids(at: original), [build], "The file and the process agree on the build")

    // What the in-app updater does to the old app once the new one is in place.
    try FileManager.default.removeItem(at: bundle)
    let after = try XCTUnwrap(
      live.list().first { $0.pid == child.processIdentifier },
      "A process of the extension executable is listed even when macOS reports no path for it")
    XCTAssertNil(after.executable)
    XCTAssertNil(after.bundle)
    XCTAssertEqual(after.imageUUID, build)
    XCTAssertEqual(after.startedAt, before.startedAt)

    func verdicts(registered binary: Data) throws -> [LockScreenExtensionStaleness] {
      LockScreenExtensionProcesses.stale(
        [after], expected: try registeredBundle(containing: binary), stamp: live.executableStamp,
        images: live.executableImages
      ).map(\.staleness)
    }
    XCTAssertEqual(try verdicts(registered: MachOFixture.thin(uuid: UUID())), [.deletedBuild])
    XCTAssertEqual(try verdicts(registered: try Data(contentsOf: original)), [], "The same build is kept")
    XCTAssertEqual(try verdicts(registered: Data("not an executable".utf8)), [], "An unreadable build is kept")

    // The signal still checks the process is the one that was listed.
    var reused = after
    reused.startedAt = after.startedAt.addingTimeInterval(-3_600)
    XCTAssertFalse(live.isRunning(reused))
    XCTAssertFalse(live.signal(reused, SIGTERM))
    XCTAssertTrue(child.isRunning, "A refused signal must leave the process untouched")
    XCTAssertTrue(live.isRunning(after))
    XCTAssertTrue(live.signal(after, SIGTERM))
    child.waitUntilExit()
    XCTAssertEqual(child.terminationStatus, SIGTERM)
    XCTAssertFalse(live.isRunning(after))
  }

  func testLiveSignalNeverReachesAReusedPidAndEndsTheRealProcess() throws {
    let (_, child, _) = try spawnFakeExtension()
    let live = LockScreenExtensionProcesses.live
    let found = try XCTUnwrap(live.list().first { $0.pid == child.processIdentifier })

    // A different start time or path means the pid names another process now.
    var reused = found
    reused.startedAt = found.startedAt.addingTimeInterval(-3_600)
    XCTAssertFalse(live.isRunning(reused))
    XCTAssertFalse(live.signal(reused, SIGTERM))
    var elsewhere = found
    elsewhere.executable = try XCTUnwrap(found.executable).deletingLastPathComponent().appendingPathComponent("Other")
    XCTAssertFalse(live.signal(elsewhere, SIGTERM))
    XCTAssertTrue(child.isRunning, "A refused signal must leave the process untouched")
    XCTAssertTrue(live.isRunning(found))

    XCTAssertTrue(live.signal(found, SIGTERM))
    child.waitUntilExit()
    XCTAssertEqual(child.terminationReason, .uncaughtSignal)
    XCTAssertEqual(child.terminationStatus, SIGTERM)
    XCTAssertFalse(live.isRunning(found))
    XCTAssertFalse(live.signal(found, SIGKILL), "An exited process must not be signalled again")
  }
}
