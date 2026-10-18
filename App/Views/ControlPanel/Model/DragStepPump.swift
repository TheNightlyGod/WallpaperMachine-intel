import Foundation

/// Shows the wallpaper at the thumb while a slider or colour is dragged, and settles on release.
///
/// A drag produces values far faster than the renderer can follow, so the pump sends *steps*:
/// at most one in flight, no more often than `interval`, always with the newest value, and never
/// queued behind a command. A step changes nothing that is saved and a refused step is ignored;
/// the release is what saves, and it always does.
///
/// - `update(_:)` reports the newest value. The first one of a drag sends a step at once.
/// - `release(_:commit:)` ends the drag: a step waiting for its turn is dropped, the step already
///   sent is waited for so it cannot land after the commit, and then `commit` runs with the final
///   value, even when it equals the value the drag began with.
/// - A change that has no drag (a key press, VoiceOver) skips the pump and commits at once.
/// - `deferFirstStep` is for a control whose drag happens somewhere the view cannot see, as with a
///   colour picker's own panel: the first step waits one main-actor turn, so a single pick, whose
///   commit follows at once, shows no step before it is saved.
@MainActor
final class DragStepPump<Value: Equatable & Sendable> {
  typealias Sleep = @Sendable (Duration) async throws -> Void

  /// The spacing between two steps.
  nonisolated static var defaultInterval: Duration { .milliseconds(100) }

  private let interval: Duration
  private let sleep: Sleep
  private let step: @MainActor (Value) async -> Void

  private var latest: Value?
  private var shown: Value?
  private var inFlight: Task<Void, Never>?
  private var cooldown: Task<Void, Never>?
  private var deferral: Task<Void, Never>?

  /// `step` shows a value without saving it and never throws. `sleep` is `Task.sleep` in
  /// production; a test hands in a clock it fires by hand.
  init(
    interval: Duration = DragStepPump.defaultInterval,
    sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
    step: @escaping @MainActor (Value) async -> Void
  ) {
    self.interval = interval
    self.sleep = sleep
    self.step = step
  }

  /// Whether a drag has reported a value and not yet been released.
  var isDragging: Bool { latest != nil }
  /// The newest value the drag reported: what a release on blur or cancel settles with.
  var newestValue: Value? { latest }
  /// The value last shown by a step.
  var lastShown: Value? { shown }

  func update(_ value: Value, deferFirstStep: Bool = false) {
    let starting = latest == nil
    latest = value
    if starting {
      shown = nil
      if deferFirstStep {
        deferral = Task { @MainActor [weak self] in
          await Task.yield()
          guard !Task.isCancelled, let self else { return }
          self.deferral = nil
          self.pump()
        }
        return
      }
    }
    pump()
  }

  /// Ends the drag and saves `value`. Resolves after `commit` has returned.
  func release(_ value: Value, commit: @MainActor (Value) async throws -> Void) async rethrows {
    let pending = inFlight
    latest = nil
    cooldown?.cancel()
    cooldown = nil
    deferral?.cancel()
    deferral = nil
    await pending?.value
    shown = nil
    try await commit(value)
  }

  private func pump() {
    guard let value = latest, inFlight == nil, cooldown == nil, deferral == nil, value != shown
    else { return }
    shown = value
    inFlight = Task { @MainActor [weak self] in
      guard let self else { return }
      await self.step(value)
      self.inFlight = nil
      self.pump()
    }
    let sleep = sleep
    let interval = interval
    cooldown = Task { @MainActor [weak self] in
      do { try await sleep(interval) } catch { return }
      // A release cancels this task; one that was resumed a moment before must not clear the
      // cooldown of the drag that came after it.
      guard !Task.isCancelled, let self else { return }
      self.cooldown = nil
      self.pump()
    }
  }
}
