import Foundation

/// Gives up waiting for an operation after a limit, without needing the
/// operation to cooperate.
///
/// This is deliberately not a task group. A group's scope does not end until
/// every child has finished, and an `AVAsset` load that is blocked inside the
/// kernel on a volume that has stopped answering can ignore cancellation: the
/// group would then wait exactly as long as the unbounded call it was meant to
/// bound. Here the caller is released by whichever of the operation, the timer
/// or its own cancellation happens first, and the losers are cancelled on a
/// best-effort basis and left to finish on their own. An operation that never
/// returns is therefore a leaked task, not a stuck caller, and a late result is
/// dropped.
@MainActor
enum NativeVideoDeadline {
    enum Outcome<Value: Sendable>: Sendable {
        /// The operation finished first.
        case value(Value)
        /// The limit passed first. The operation may still be running.
        case timedOut
        /// The calling task was cancelled first.
        case cancelled
    }

    /// Runs `operation` and returns its value, or stops waiting after `limit`.
    ///
    /// `sleep` is injected so a test can fire the limit by hand; production
    /// passes `Task.sleep`.
    static func race<Value: Sendable>(
        _ limit: Duration,
        sleep: @escaping @Sendable (Duration) async throws -> Void,
        _ operation: @escaping @MainActor () async -> Value
    ) async -> Outcome<Value> {
        if Task.isCancelled { return .cancelled }
        let state = Race<Value>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Outcome<Value>, Never>) in
                state.install(continuation)
                state.start(limit: limit, sleep: sleep, operation: operation)
            }
        } onCancel: {
            Task { @MainActor in state.finish(.cancelled) }
        }
    }

    /// One race's state: the first outcome wins and every later one is
    /// ignored, which is what makes a late operation result harmless.
    @MainActor
    private final class Race<Value: Sendable> {
        private var continuation: CheckedContinuation<Outcome<Value>, Never>?
        private var decided: Outcome<Value>?
        private var operation: Task<Void, Never>?
        private var timer: Task<Void, Never>?

        func install(_ continuation: CheckedContinuation<Outcome<Value>, Never>) {
            if let decided {
                continuation.resume(returning: decided)
            } else {
                self.continuation = continuation
            }
        }

        func start(
            limit: Duration,
            sleep: @escaping @Sendable (Duration) async throws -> Void,
            operation: @escaping @MainActor () async -> Value
        ) {
            guard decided == nil else { return }
            self.operation = Task { @MainActor [self] in
                finish(.value(await operation()))
            }
            timer = Task { @MainActor [self] in
                // Only this race cancels its timer, and only after deciding,
                // so a thrown sleep means the outcome is already settled.
                do { try await sleep(limit) } catch { return }
                finish(.timedOut)
            }
        }

        func finish(_ outcome: Outcome<Value>) {
            guard decided == nil else { return }
            decided = outcome
            timer?.cancel()
            if case .value = outcome {} else { operation?.cancel() }
            if let continuation {
                self.continuation = nil
                continuation.resume(returning: outcome)
            }
        }
    }
}

extension NativeVideoDeadline.Outcome: Equatable where Value: Equatable {}
