import Foundation
import Observation

/// Runs the actions views start, one task each, and keeps the books the page's `send()` kept:
/// which keyed actions are still pending, so a control can disable itself, and what a repeat of
/// one means.
///
/// A key names one control's work (`PanelActionCoordinator.key("property", id: wallpaper,
/// detail: property)`), so two properties of one wallpaper, or one property of two, never wait
/// for each other. Work without a key runs at once and is not tracked.
///
/// A task never throws: a failure goes to `report` (the error banner) and the task still ends,
/// so the key is released on failure too and whoever waited behind it carries on.
@MainActor
@Observable
final class PanelActionCoordinator {
  enum Policy: Sendable {
    /// A repeat while the action is pending is ignored (the original is returned): a second click
    /// on Apply, Delete or Download must not start a second one.
    case dropDuplicates
    /// A repeat waits for the pending work, whether it succeeds or fails, and then runs with its
    /// own value, so the newest value always lands last. For a control that sends many values:
    /// a slider, a field, navigation and the search boxes.
    case latestWins
  }

  /// How many tasks wait or run for each key; only a key with work has an entry.
  private(set) var pending: [String: Int] = [:]

  @ObservationIgnored private var tails: [String: (ticket: UInt64, task: Task<Void, Never>)] = [:]
  @ObservationIgnored private var nextTicket: UInt64 = 0
  @ObservationIgnored private let report: @MainActor (Error) -> Void
  @ObservationIgnored private let succeeded: @MainActor () -> Void

  /// `report` receives a thrown error; `succeeded` runs after an operation that did not throw
  /// (the controller re-checks which error dismissals still apply).
  init(
    report: @escaping @MainActor (Error) -> Void, succeeded: @escaping @MainActor () -> Void = {}
  ) {
    self.report = report
    self.succeeded = succeeded
  }

  /// The key of one control's action: the action, then the wallpaper, display and property or
  /// setting it concerns, in the order the page keyed them.
  nonisolated static func key(
    _ action: String, id: String? = nil, displayID: String? = nil, detail: String? = nil
  ) -> String {
    "\(action):\(id ?? ""):\(displayID ?? ""):\(detail ?? "")"
  }

  /// Whether a task for `key` waits or runs: what a control disables itself on.
  func isBusy(_ key: String) -> Bool { (pending[key] ?? 0) > 0 }

  /// Whether any keyed action waits or runs.
  var hasPending: Bool { !pending.isEmpty }

  /// Starts `operation` and returns its task, which tests await. The task never throws.
  @discardableResult
  func launch(
    _ key: String? = nil, policy: Policy = .dropDuplicates,
    operation: @escaping @MainActor () async throws -> Void
  ) -> Task<Void, Never> {
    guard let key else {
      return Task { @MainActor [weak self] in await self?.run(operation) }
    }
    let previous = tails[key]?.task
    if let previous, policy == .dropDuplicates { return previous }
    pending[key, default: 0] += 1
    nextTicket &+= 1
    let ticket = nextTicket
    let task = Task { @MainActor [weak self] in
      await previous?.value
      await self?.run(operation)
      self?.release(key, ticket: ticket)
    }
    tails[key] = (ticket, task)
    return task
  }

  private func run(_ operation: @MainActor () async throws -> Void) async {
    do {
      try await operation()
      succeeded()
    } catch {
      report(error)
    }
  }

  private func release(_ key: String, ticket: UInt64) {
    if let count = pending[key] {
      if count > 1 { pending[key] = count - 1 } else { pending[key] = nil }
    }
    if tails[key]?.ticket == ticket { tails[key] = nil }
  }
}
