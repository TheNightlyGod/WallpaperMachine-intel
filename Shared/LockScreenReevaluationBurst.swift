import Foundation

/// A short run of re-checks after something that may have changed whether a
/// surface should be presenting: a display or the whole Mac sleeping or waking,
/// the screen locking or unlocking, the wallpaper service saying it woke.
///
/// Those signals arrive in no fixed order and can arrive before the state they
/// announce has settled (displays, backlight and video decoders return at
/// different moments, and the session dictionary can trail the unlock
/// notification) or not at all. So a signal is only a trigger: the answer is read
/// from the system now and again shortly after, and the last read wins.
///
/// A newer trigger, or `cancel()`, retires the checks still pending. Each pending
/// check also carries the generation it was scheduled in and refuses to run once
/// that is stale, so a check already queued when a newer trigger arrives cannot
/// run on its behalf.
@MainActor
final class LockScreenReevaluationBurst {
  /// Schedules `work` after a delay and returns what cancels it.
  typealias Schedule = (Duration, @escaping @MainActor () -> Void) -> (() -> Void)

  /// Delays from the trigger: checks at 0, 0.25, 0.75 and 2 seconds.
  static let defaultOffsets: [Duration] = [.milliseconds(250), .milliseconds(750), .seconds(2)]

  private let offsets: [Duration]
  private let schedule: Schedule
  private let perform: @MainActor () -> Void
  private var generation: UInt64 = 0
  private var cancels: [() -> Void] = []

  init(
    offsets: [Duration] = LockScreenReevaluationBurst.defaultOffsets,
    schedule: @escaping Schedule = LockScreenReevaluationBurst.scheduleBySleeping,
    perform: @escaping @MainActor () -> Void
  ) {
    self.offsets = offsets
    self.schedule = schedule
    self.perform = perform
  }

  /// Checks now and again at each offset, replacing any burst still running.
  func trigger() {
    cancel()
    let current = generation
    for offset in offsets {
      cancels.append(
        schedule(offset) { [weak self] in
          guard let self, self.generation == current else { return }
          self.perform()
        })
    }
    perform()
  }

  /// Stops the checks that have not run yet.
  func cancel() {
    generation &+= 1
    let pending = cancels
    cancels.removeAll()
    pending.forEach { $0() }
  }

  nonisolated static func scheduleBySleeping(
    _ delay: Duration, _ work: @escaping @MainActor () -> Void
  ) -> () -> Void {
    let task = Task { @MainActor in
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled else { return }
      work()
    }
    return { task.cancel() }
  }
}
