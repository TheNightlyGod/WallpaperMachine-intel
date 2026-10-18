import Observation

/// Runs `onChange` each time something `track` reads changes, until stopped.
///
/// `withObservationTracking` fires once per registration and before the change lands, so the loop
/// re-arms itself and hops one main-actor turn before reporting, which lets `onChange` read the
/// new values. A restart ends the registrations of the run before it.
@MainActor
final class ObservationLoop {
  private let track: @MainActor () -> Void
  private let onChange: @MainActor () -> Void
  private var generation: UInt64 = 0
  private var isRunning = false

  init(track: @escaping @MainActor () -> Void, onChange: @escaping @MainActor () -> Void) {
    self.track = track
    self.onChange = onChange
  }

  func start() {
    guard !isRunning else { return }
    isRunning = true
    generation &+= 1
    arm(generation)
  }

  func stop() {
    isRunning = false
    generation &+= 1
  }

  private func arm(_ generation: UInt64) {
    withObservationTracking {
      track()
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        guard let self, self.isRunning, self.generation == generation else { return }
        self.onChange()
        guard self.isRunning, self.generation == generation else { return }
        self.arm(generation)
      }
    }
  }
}
