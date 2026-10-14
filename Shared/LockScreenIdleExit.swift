import Foundation
import os

/// Ends the extension process once no wallpaper host or surface uses it.
///
/// RunningBoard hands a still-running process to WallpaperAgent even after macOS has
/// registered another copy of the extension (an app update or a second build). That
/// process never receives the new connection, and WallpaperAgent then stalls about
/// 30 seconds per request; lock-screen, screen-saver and System Settings wallpaper
/// requests queue behind it. Exiting while idle makes the next launch use the
/// registered copy.
@MainActor
final class LockScreenIdleExit {
  private let grace: Duration
  private let isBusy: @MainActor @Sendable () -> Bool
  private let exit: @MainActor @Sendable () -> Void
  /// Counted on the listener's queue as a connection is accepted. Counting after a
  /// hop to the main queue left a moment in which an exit already due could end
  /// the process under a connection it had just accepted.
  private let connections = OSAllocatedUnfairLock(initialState: 0)
  private var pending: Task<Void, Never>?

  /// Nonisolated so the listener can create it off the main queue.
  nonisolated init(grace: Duration, isBusy: @escaping @MainActor @Sendable () -> Bool,
                   exit: @escaping @MainActor @Sendable () -> Void) {
    self.grace = grace
    self.isBusy = isBusy
    self.exit = exit
  }

  /// Connections accepted and not yet closed, readable from any queue.
  nonisolated var openConnections: Int { connections.withLock { $0 } }

  /// Call before the connection resumes, on any queue.
  nonisolated func connectionOpened() {
    connections.withLock { $0 += 1 }
    DispatchQueue.main.async { MainActor.assumeIsolated { self.cancelWhileConnected() } }
  }

  func connectionClosed() {
    connections.withLock { $0 = max(0, $0 - 1) }
    scheduleIfIdle()
  }

  func surfacesChanged() { scheduleIfIdle() }

  /// A close counted before this hop ran leaves its own exit scheduled.
  private func cancelWhileConnected() {
    guard connections.withLock({ $0 }) > 0 else { return }
    pending?.cancel()
    pending = nil
  }

  private func scheduleIfIdle() {
    guard connections.withLock({ $0 }) == 0, !isBusy(), pending == nil else { return }
    pending = Task { [weak self, grace] in
      try? await Task.sleep(for: grace)
      guard let self, !Task.isCancelled else { return }
      self.pending = nil
      // Held through the exit: a connection is either counted first or never accepted.
      self.connections.withLockUnchecked { count in
        if count == 0, !self.isBusy() { self.exit() }
      }
    }
  }
}
