import Foundation
import Observation
import Translation

/// What `TranslationSessionHost` asks of a session: the Translation framework's
/// `TranslationSession`, or a fake in tests, which cannot make one.
protocol TranslationSessionServing {
    func translatedText(_ text: String) async throws -> String
    func prepareTranslation() async throws
}

extension TranslationSession: TranslationSessionServing {
    func translatedText(_ text: String) async throws -> String {
        try await translate(text).targetText
    }
}

/// Lends the Translation framework's sessions to work that needs one.
///
/// A session that may ask the person to download a language exists only inside SwiftUI's
/// `.translationTask`, and before macOS 26 every session does. The panel's `TranslationTaskHost`
/// carries that modifier bound to `configuration` and hands each session it is given to
/// `serve(_:)`; everything else happens here, so the view does no work of its own.
///
/// Work waits in a queue. Asking for a session sets `configuration` for the pair the oldest job
/// needs (or invalidates it to ask again for the same pair), and nothing changes it again until
/// that session has served every job for its pair: the framework stops the process if a session
/// is used after its configuration changed or its view went away. A translation that no session
/// serves within `timeout`, because no panel is open to lend one, fails instead of waiting, and
/// the next job asks for a session afresh.
@MainActor
@Observable
final class TranslationSessionHost {
    /// How long a translation waits for a session and its answer before it fails.
    static let timeout: Duration = .seconds(5)

    struct Pair: Equatable, Sendable {
        let source: Locale.Language
        let target: Locale.Language
    }

    /// A translation that no session answered within `timeout`.
    struct TimedOut: LocalizedError {
        var errorDescription: String? { "No translation session answered in time." }
    }

    /// What the panel's `.translationTask` is bound to: nil until work first asks for a session.
    private(set) var configuration: TranslationSession.Configuration?

    /// How the timeouts wait; tests give them a clock they fire by hand.
    @ObservationIgnored var sleep: @Sendable (Duration) async throws -> Void = {
        try await Task.sleep(for: $0)
    }

    private enum Work {
        case translate(String)
        case prepare
    }

    private struct Job {
        let id: UInt64
        let pair: Pair
        let work: Work
    }

    private enum Phase: Equatable {
        case idle
        /// `configuration` was set for this pair and its session has not arrived yet.
        case requested(Pair)
        case serving(Pair)
    }

    @ObservationIgnored private var queue: [Job] = []
    @ObservationIgnored private var waiting: [UInt64: CheckedContinuation<String, Error>] = [:]
    @ObservationIgnored private var nextID: UInt64 = 0
    @ObservationIgnored private var phase = Phase.idle

    /// Translates `text` with a session lent for `pair`.
    func translate(_ text: String, from source: Locale.Language, to target: Locale.Language)
        async throws -> String
    {
        try await submit(.translate(text), Pair(source: source, target: target), timeout: Self.timeout)
    }

    /// Runs the framework's download prompt for `pair` in the panel's window. It waits for the
    /// person, so it has no timeout.
    func prepare(from source: Locale.Language, to target: Locale.Language) async throws {
        _ = try await submit(.prepare, Pair(source: source, target: target), timeout: nil)
    }

    /// The `.translationTask` action: serves every queued job for the pair this session was asked
    /// for, oldest first, then asks for the next pair's session. A session arriving while the
    /// panel's view is going away serves nothing.
    func serve(_ session: some TranslationSessionServing) async {
        guard !Task.isCancelled else { return }
        let pair: Pair
        switch phase {
        case .requested(let requested): pair = requested
        case .serving: return
        case .idle:
            guard let source = configuration?.source, let target = configuration?.target else { return }
            pair = Pair(source: source, target: target)
        }
        phase = .serving(pair)
        while !Task.isCancelled, let index = queue.firstIndex(where: { $0.pair == pair }) {
            let job = queue.remove(at: index)
            guard waiting[job.id] != nil else { continue }
            let result: Result<String, Error>
            do {
                switch job.work {
                case .translate(let text): result = .success(try await session.translatedText(text))
                case .prepare:
                    try await session.prepareTranslation()
                    result = .success("")
                }
            } catch {
                result = .failure(error)
            }
            finish(job.id, with: result)
        }
        phase = .idle
        requestSession()
    }

    private func submit(_ work: Work, _ pair: Pair, timeout: Duration?) async throws -> String {
        nextID &+= 1
        let id = nextID
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiting[id] = continuation
                queue.append(Job(id: id, pair: pair, work: work))
                if let timeout {
                    Task { [weak self, sleep] in
                        try? await sleep(timeout)
                        self?.timedOut(id, pair: pair)
                    }
                }
                requestSession()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(id, with: .failure(CancellationError())) }
        }
    }

    /// A job's time ran out. If its session never arrived, the next job asks again rather than
    /// wait for a request SwiftUI did not answer.
    private func timedOut(_ id: UInt64, pair: Pair) {
        guard waiting[id] != nil else { return }
        finish(id, with: .failure(TimedOut()))
        if phase == .requested(pair) { phase = .idle }
    }

    /// Answers a job once; a later answer for it (its session returning after the timeout) is
    /// dropped.
    private func finish(_ id: UInt64, with result: Result<String, Error>) {
        queue.removeAll { $0.id == id }
        waiting.removeValue(forKey: id)?.resume(with: result)
    }

    /// Asks SwiftUI for a session for the oldest job, unless one is on its way or serving.
    private func requestSession() {
        guard phase == .idle, let pair = queue.first?.pair else { return }
        if var current = configuration, current.source == pair.source, current.target == pair.target {
            current.invalidate()
            configuration = current
        } else {
            configuration = TranslationSession.Configuration(source: pair.source, target: pair.target)
        }
        phase = .requested(pair)
    }
}
