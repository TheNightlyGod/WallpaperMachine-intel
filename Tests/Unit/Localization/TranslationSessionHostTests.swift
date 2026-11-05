import Translation
import XCTest

@testable import WallpaperMachine

/// How translation work borrows the sessions SwiftUI's `.translationTask` lends: a session is asked
/// for the oldest job's languages, serves every job for them, and only then is another asked for;
/// work no session serves gives up in time instead of holding the search.
@MainActor
final class TranslationSessionHostTests: XCTestCase {
    /// Stands in for a `TranslationSession`, which only SwiftUI can make.
    private final class FakeSession: TranslationSessionServing, @unchecked Sendable {
        var translated: [String] = []
        var prepared = 0

        func translatedText(_ text: String) async throws -> String {
            translated.append(text)
            return "en:\(text)"
        }

        func prepareTranslation() async throws { prepared += 1 }
    }

    private let chinese = Locale.Language(identifier: "zh-Hans")
    private let japanese = Locale.Language(identifier: "ja")
    private let english = Locale.Language(identifier: "en")

    /// A host whose timeouts wait on a clock the test fires; whatever is still waiting on it is
    /// released when the test ends.
    private func makeHost() -> (TranslationSessionHost, ManualSleeper) {
        let host = TranslationSessionHost()
        let sleeper = ManualSleeper()
        host.sleep = sleeper.closure
        addTeardownBlock { sleeper.fireAll() }
        return (host, sleeper)
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            guard Date() < deadline else { return XCTFail("condition not met in time") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func testAJobAsksForASessionForItsLanguagesAndTheSessionAnswersIt() async throws {
        let (host, _) = makeHost()
        XCTAssertNil(host.configuration, "nothing is asked for until work needs a session")

        let job = Task { try await host.translate("猫", from: chinese, to: english) }
        try await waitFor { host.configuration != nil }
        XCTAssertEqual(host.configuration?.source, chinese)
        XCTAssertEqual(host.configuration?.target, english)

        let session = FakeSession()
        await host.serve(session)
        let answer = try await job.value
        XCTAssertEqual(answer, "en:猫")
        XCTAssertEqual(session.translated, ["猫"])
    }

    func testAnotherPairWaitsUntilTheSessionServingTheFirstIsDone() async throws {
        let (host, _) = makeHost()
        let first = Task { try await host.translate("猫", from: chinese, to: english) }
        try await waitFor { host.configuration != nil }
        let second = Task { try await host.translate("桜", from: japanese, to: english) }
        let third = Task { try await host.translate("风景", from: chinese, to: english) }
        // Let both submissions land before the session for the first arrives.
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(host.configuration?.source, chinese, "a session on its way is never replaced")

        let chineseSession = FakeSession()
        await host.serve(chineseSession)
        XCTAssertEqual(chineseSession.translated, ["猫", "风景"], "one session serves every job for its pair")
        XCTAssertEqual(host.configuration?.source, japanese, "then the next pair is asked for")
        let japaneseSession = FakeSession()
        await host.serve(japaneseSession)
        XCTAssertEqual(japaneseSession.translated, ["桜"])
        let answers = try await [first.value, second.value, third.value]
        XCTAssertEqual(answers, ["en:猫", "en:桜", "en:风景"])
    }

    func testTheSamePairAskedAgainGetsAFreshSession() async throws {
        let (host, _) = makeHost()
        let first = Task { try await host.translate("猫", from: chinese, to: english) }
        try await waitFor { host.configuration != nil }
        await host.serve(FakeSession())
        _ = try await first.value
        let served = host.configuration

        let second = Task { try await host.translate("风景", from: chinese, to: english) }
        try await waitFor { host.configuration != served }
        XCTAssertEqual(host.configuration?.source, chinese)
        XCTAssertNotEqual(host.configuration?.version, served?.version, "a used session is not used again")
        await host.serve(FakeSession())
        let answer = try await second.value
        XCTAssertEqual(answer, "en:风景")
    }

    func testATranslationNoSessionServesGivesUpAndAsksAgainNextTime() async throws {
        let (host, sleeper) = makeHost()
        let stranded = Task { try await host.translate("猫", from: chinese, to: english) }
        await sleeper.waitUntilPending(1)
        XCTAssertEqual(sleeper.requested, [TranslationSessionHost.timeout])
        let asked = host.configuration
        sleeper.fireNext()
        do {
            _ = try await stranded.value
            XCTFail("no panel lent a session, so the search goes on as typed")
        } catch is TranslationSessionHost.TimedOut {}

        let next = Task { try await host.translate("风景", from: chinese, to: english) }
        try await waitFor { host.configuration != asked }
        let session = FakeSession()
        await host.serve(session)
        XCTAssertEqual(session.translated, ["风景"], "the job that gave up is not translated late")
        let answer = try await next.value
        XCTAssertEqual(answer, "en:风景")
    }

    func testADownloadPromptWaitsForThePersonWithoutATimeout() async throws {
        let (host, sleeper) = makeHost()
        let download = Task { try await host.prepare(from: japanese, to: english) }
        try await waitFor { host.configuration != nil }
        XCTAssertEqual(sleeper.pendingCount, 0)
        let session = FakeSession()
        await host.serve(session)
        try await download.value
        XCTAssertEqual(session.prepared, 1)
    }

    func testASessionLentWhileTheViewGoesAwayServesNothing() async throws {
        let (host, _) = makeHost()
        let job = Task { try await host.translate("猫", from: chinese, to: english) }
        try await waitFor { host.configuration != nil }
        let session = FakeSession()
        let cancelled = Task { await host.serve(session) }
        cancelled.cancel()
        await cancelled.value
        XCTAssertEqual(session.translated, [], "a session used after its view went away stops the app")
        job.cancel()
        do {
            _ = try await job.value
            XCTFail("a cancelled search gets no translation")
        } catch is CancellationError {}
    }
}
