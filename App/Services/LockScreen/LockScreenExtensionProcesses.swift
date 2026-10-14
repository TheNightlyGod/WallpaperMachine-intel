import Darwin
import Foundation

/// One running instance of the lock-screen extension helper owned by the current user.
struct LockScreenExtensionProcess: Equatable, Sendable {
  var pid: pid_t
  var startedAt: Date
  /// Nil when macOS no longer reports a path: the folder it ran from was deleted, which is
  /// what an in-app update does to the old app once the new one is in place.
  var executable: URL?
  /// The `.appex` the executable belongs to, symlinks resolved; nil without a path.
  var bundle: URL?
  /// The build UUID the kernel recorded when the process started, readable without a path.
  var imageUUID: UUID?

  /// For logs.
  var location: String { executable?.path ?? "(deleted)" }
}

/// Why a running extension process cannot serve the registered copy.
enum LockScreenExtensionStaleness: Equatable, Sendable {
  /// It runs from a different bundle than the one registered now.
  case otherCopy
  /// Its executable was replaced at the same path (an update or rebuild) after it started:
  /// the file is newer than the process, or it holds a different build than the one running.
  case replacedInPlace
  /// Its files are gone and it runs a different build than the registered executable.
  case deletedBuild
}

/// Finds and ends extension helpers that macOS keeps handing out although a different
/// copy is registered. RunningBoard reuses a running process instead of launching the
/// registered binary, so activation otherwise stalls until the user kills it by hand.
///
/// Every capability is a closure so tests drive the whole policy without real processes.
/// `.inert` is the default everywhere except the app itself: unit tests run inside the real
/// app and must never classify the developer's installed extension as stale.
struct LockScreenExtensionProcesses: Sendable {
  struct Outcome: Equatable, Sendable {
    /// Exited after SIGTERM.
    var ended: [pid_t] = []
    /// Needed SIGKILL.
    var forced: [pid_t] = []
    /// Never signalled because the process was gone or no longer the one that was listed.
    var skipped: [pid_t] = []
    /// Still running when the call returned.
    var survived: [pid_t] = []
  }

  var list: @Sendable () -> [LockScreenExtensionProcess]
  /// The later of an executable's creation and modification time. A build or an in-place
  /// write leaves the file newer than a process started before it, so the later of the two
  /// reveals it. A copy that keeps the source's dates (`ditto`, `cp -p`, Finder onto an
  /// existing file) does not, which is why the build UUID is compared as well.
  var executableStamp: @Sendable (URL) -> Date?
  /// The build UUIDs of the executable at a URL, one per slice; empty when it cannot be read.
  var executableImages: @Sendable (URL) -> Set<UUID>
  /// Delivers the signal only if the pid still belongs to the same process.
  var signal: @Sendable (LockScreenExtensionProcess, Int32) -> Bool
  var isRunning: @Sendable (LockScreenExtensionProcess) -> Bool
  var sleep: @Sendable (Duration) async -> Void

  static let executableName = "WallpaperMachineExtension"

  /// SIGTERM, a two-second grace period, then SIGKILL for survivors only.
  static let pollInterval = Duration.milliseconds(100)
  static let polls = 20
  /// SIGKILL cannot be handled; this only confirms it took effect before logging.
  static let confirmPolls = 10

  /// The extension's executable inside its `.appex`.
  static func executable(in bundle: URL) -> URL {
    bundle.appendingPathComponent("Contents/MacOS/\(executableName)")
  }

  /// Pure classification; a process without a readable stamp or build is kept (never guess).
  static func stale(
    _ processes: [LockScreenExtensionProcess], expected: URL,
    stamp: (URL) -> Date?, images: (URL) -> Set<UUID>
  ) -> [(process: LockScreenExtensionProcess, staleness: LockScreenExtensionStaleness)] {
    // Whether the process runs a build the registered executable provably does not contain;
    // an unreadable build on either side proves nothing.
    func runsAnotherBuild(_ process: LockScreenExtensionProcess) -> Bool {
      guard let running = process.imageUUID else { return false }
      let registered = images(Self.executable(in: expected))
      return !registered.isEmpty && !registered.contains(running)
    }
    return processes.compactMap { process in
      guard let bundle = process.bundle, let executable = process.executable else {
        // No path says nothing about which copy this was, but the build it runs does: the
        // same build as the registered executable is kept, a different one cannot serve it.
        return runsAnotherBuild(process) ? (process, .deletedBuild) : nil
      }
      if !LockScreenExtensionDiagnostics.isSameBundle(bundle, expected) {
        return (process, .otherCopy)
      }
      if let stamp = stamp(executable), stamp > process.startedAt {
        return (process, .replacedInPlace)
      }
      // A copy that keeps the source's file dates leaves nothing newer than the process,
      // but the executable it put at this path is still not the build that is running.
      return runsAnotherBuild(process) ? (process, .replacedInPlace) : nil
    }
  }

  /// Ends the extension processes that cannot serve `expected`. Best effort: a refused
  /// signal is logged and activation continues to its own timeout diagnostics.
  @discardableResult
  func terminateStale(expected: URL) async -> Outcome {
    var outcome = Outcome()
    let running = list()
    let stale = Self.stale(running, expected: expected, stamp: executableStamp, images: executableImages)
    for process in running where process.executable == nil && !stale.contains(where: { $0.process == process }) {
      AppLog.debug("Native extension: process \(process.pid) has no path and its build is not proven different; leaving it alone")
    }
    guard !stale.isEmpty, !Task.isCancelled else { return outcome }

    var pending: [LockScreenExtensionProcess] = []
    for (process, staleness) in stale {
      if signal(process, SIGTERM) {
        AppLog.info("Native extension: ended process \(process.pid) (\(staleness)): \(process.location)")
        pending.append(process)
      } else {
        AppLog.info("Native extension: process \(process.pid) is gone or changed; not signalled")
        outcome.skipped.append(process.pid)
      }
    }
    await waitForExit(of: pending, polls: Self.polls)
    var survivors = pending.filter(isRunning)
    outcome.ended = pending.filter { process in !survivors.contains(process) }.map(\.pid)
    guard !survivors.isEmpty, !Task.isCancelled else {
      outcome.survived = survivors.map(\.pid)
      return outcome
    }

    var forced: [LockScreenExtensionProcess] = []
    for process in survivors {
      if signal(process, SIGKILL) {
        AppLog.warn("Native extension: process \(process.pid) ignored SIGTERM; killed it: \(process.location)")
        forced.append(process)
      } else {
        outcome.skipped.append(process.pid)
      }
    }
    outcome.forced = forced.map(\.pid)
    await waitForExit(of: forced, polls: Self.confirmPolls)
    survivors = forced.filter(isRunning)
    outcome.survived = survivors.map(\.pid)
    for process in survivors {
      AppLog.warn("Native extension: process \(process.pid) is still running after SIGKILL: \(process.location)")
    }
    return outcome
  }

  private func waitForExit(of processes: [LockScreenExtensionProcess], polls: Int) async {
    var remaining = polls
    while remaining > 0, !Task.isCancelled, processes.contains(where: isRunning) {
      await sleep(Self.pollInterval)
      remaining -= 1
    }
  }
}

extension LockScreenExtensionProcesses {
  static let inert = LockScreenExtensionProcesses(
    list: { [] }, executableStamp: { _ in nil }, executableImages: { _ in [] },
    signal: { _, _ in false }, isRunning: { _ in false }, sleep: { _ in })

  static let live = LockScreenExtensionProcesses(
    list: { enumerate() },
    executableStamp: { stamp(of: $0) },
    executableImages: { MachOImageUUIDs.uuids(at: $0) },
    signal: { process, number in
      // Re-read the pid right before signalling: it may have exited and been reused.
      guard process.pid > 1, isSame(process) else { return false }
      return kill(process.pid, number) == 0
    },
    isRunning: { isSame($0) },
    sleep: { try? await Task.sleep(for: $0) })

  private struct Sighting {
    var startedAt: Date
    var name: String
    var executable: URL?
  }

  /// Only this user's processes are ever described; nothing else is visible to the policy.
  private static func sighting(of pid: pid_t) -> Sighting? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    // A zombie has already exited; it is neither running nor worth waiting for.
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
      info.pbi_uid == getuid(), info.pbi_ruid == getuid(), info.pbi_status != UInt32(SZOMB)
    else { return nil }
    let name = withUnsafePointer(to: &info.pbi_name) {
      $0.withMemoryRebound(to: CChar.self, capacity: Int(2 * MAXCOMLEN)) { String(cString: $0) }
    }
    // PROC_PIDPATHINFO_MAXSIZE expands to 4*MAXPATHLEN and is not Swift-importable.
    var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    let length = path.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
    let started = Date(
      timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000)
    return Sighting(
      startedAt: started, name: name,
      executable: length > 0 ? URL(fileURLWithPath: String(cString: path)) : nil)
  }

  private static func enumerate() -> [LockScreenExtensionProcess] {
    let estimate = proc_listallpids(nil, 0)
    guard estimate > 0 else { return [] }
    var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
    let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
    guard count > 0 else { return [] }
    return pids.prefix(Int(count)).compactMap { pid in
      guard pid > 0, let sighting = sighting(of: pid) else { return nil }
      guard let executable = sighting.executable else {
        // The folder it ran from was deleted. Only the name, which a path-less process
        // still reports, and the build UUID remain to recognise it.
        guard sighting.name == executableName else { return nil }
        return LockScreenExtensionProcess(
          pid: pid, startedAt: sighting.startedAt, imageUUID: imageUUID(of: pid))
      }
      guard executable.lastPathComponent == executableName else { return nil }
      let bundle = executable.deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
      guard Bundle(url: bundle)?.bundleIdentifier == LockScreenConfiguration.extensionIdentifier
      else { return nil }
      return LockScreenExtensionProcess(
        pid: pid, startedAt: sighting.startedAt, executable: executable,
        bundle: bundle.resolvingSymlinksInPath().standardizedFileURL, imageUUID: imageUUID(of: pid))
    }
  }

  /// The UUID of the executable image the process was started from, as recorded by the
  /// kernel; it stays readable after the file is deleted. Nil when unavailable.
  static func imageUUID(of pid: pid_t) -> UUID? {
    var usage = rusage_info_v0()
    let status = withUnsafeMutablePointer(to: &usage) {
      $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V0, $0) }
    }
    guard status == 0 else { return nil }
    let uuid = UUID(uuid: usage.ri_uuid)
    return uuid == UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) ? nil : uuid
  }

  /// A pid names the same process only while its executable path (or, once the files are
  /// gone, its name) and start time match.
  private static func isSame(_ process: LockScreenExtensionProcess) -> Bool {
    guard let now = sighting(of: process.pid), now.startedAt == process.startedAt,
      now.executable?.path == process.executable?.path
    else { return false }
    return now.executable != nil || now.name == executableName
  }

  private static func stamp(of url: URL) -> Date? {
    var info = stat()
    guard stat(url.path, &info) == 0 else { return nil }
    func date(_ time: timespec) -> Date {
      Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1_000_000_000)
    }
    return max(date(info.st_birthtimespec), date(info.st_mtimespec))
  }
}
