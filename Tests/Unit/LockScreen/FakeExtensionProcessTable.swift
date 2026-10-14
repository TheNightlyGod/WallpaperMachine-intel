import Darwin
import Foundation

@testable import WallpaperMachine

/// A scripted extension process table: pids, reactions to signals and poll sleeps are all
/// simulated, so no test using it can touch a real process.
final class FakeExtensionProcessTable: @unchecked Sendable {
  struct Signal: Equatable {
    var pid: pid_t
    var number: Int32
  }

  /// What a pid does when it is signalled.
  enum Reaction {
    /// Exits once `sleeps` poll intervals have passed after SIGTERM.
    case exitsOnTerm(afterSleeps: Int)
    /// Only SIGKILL ends it.
    case ignoresTerm
    /// Never exits, whatever it receives.
    case unkillable
    /// The pid now belongs to another process: the identity check refuses every signal.
    case reused
  }

  private let lock = NSLock()
  private var table: [LockScreenExtensionProcess]
  private var reactions: [pid_t: Reaction]
  private var alive: Set<pid_t>
  private var termSleeps: [pid_t: Int] = [:]
  private var recordedSignals: [Signal] = []
  private var recordedSleeps = 0
  private var recordedLists = 0
  private var stamps: [String: Date] = [:]
  private var images: [String: Set<UUID>] = [:]

  init(_ processes: [LockScreenExtensionProcess], reactions: [pid_t: Reaction] = [:]) {
    table = processes
    self.reactions = reactions
    alive = Set(processes.map(\.pid))
  }

  var signals: [Signal] { lock.withLock { recordedSignals } }
  var sleeps: Int { lock.withLock { recordedSleeps } }
  var lists: Int { lock.withLock { recordedLists } }

  func setStamp(_ date: Date, for executable: URL) {
    lock.withLock { stamps[executable.path] = date }
  }

  /// The build UUIDs the executable at this path contains; unset paths read as unreadable.
  func setImages(_ uuids: Set<UUID>, for executable: URL) {
    lock.withLock { images[executable.path] = uuids }
  }

  var processes: LockScreenExtensionProcesses {
    LockScreenExtensionProcesses(
      list: { [self] in
        lock.withLock {
          recordedLists += 1
          return table.filter { alive.contains($0.pid) }
        }
      },
      executableStamp: { [self] url in lock.withLock { stamps[url.path] } },
      executableImages: { [self] url in lock.withLock { images[url.path] ?? [] } },
      signal: { [self] process, number in
        lock.withLock {
          guard alive.contains(process.pid) else { return false }
          switch reactions[process.pid] ?? .exitsOnTerm(afterSleeps: 0) {
          case .reused:
            return false
          case .unkillable:
            break
          case .ignoresTerm:
            if number == SIGKILL { alive.remove(process.pid) }
          case .exitsOnTerm(let sleeps):
            if number == SIGKILL {
              alive.remove(process.pid)
            } else if sleeps == 0 {
              alive.remove(process.pid)
            } else {
              termSleeps[process.pid] = sleeps
            }
          }
          recordedSignals.append(Signal(pid: process.pid, number: number))
          return true
        }
      },
      isRunning: { [self] process in
        lock.withLock {
          if case .reused = reactions[process.pid] { return false }
          return alive.contains(process.pid)
        }
      },
      sleep: { [self] _ in
        lock.withLock {
          recordedSleeps += 1
          for (pid, left) in termSleeps {
            if left <= 1 {
              alive.remove(pid)
              termSleeps[pid] = nil
            } else {
              termSleeps[pid] = left - 1
            }
          }
        }
      })
  }

  static func process(
    _ pid: pid_t, bundle: String = "/Apps/Current.app/Contents/Extensions/WallpaperMachineExtension.appex",
    started: Date = Date(timeIntervalSince1970: 1_000), image: UUID? = nil
  ) -> LockScreenExtensionProcess {
    let bundleURL = URL(fileURLWithPath: bundle)
    return LockScreenExtensionProcess(
      pid: pid, startedAt: started,
      executable: LockScreenExtensionProcesses.executable(in: bundleURL), bundle: bundleURL,
      imageUUID: image)
  }

  /// A process macOS reports no path for, as after the app it ran from was replaced.
  static func deletedProcess(
    _ pid: pid_t, started: Date = Date(timeIntervalSince1970: 1_000), image: UUID? = nil
  ) -> LockScreenExtensionProcess {
    LockScreenExtensionProcess(pid: pid, startedAt: started, imageUUID: image)
  }
}
