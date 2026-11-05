import Foundation

@testable import WallpaperMachine

/// Stands in for the Translation framework: answers from a table, reports the languages a test
/// says are downloaded, and records every question, so no test translates or downloads anything.
@MainActor
final class FakeTranslation: OnDeviceTranslating {
    struct Failure: Error {}

    /// App language tags whose translation into English is downloaded.
    var installed: Set<String> = ["zh-Hans", "zh-Hant", "ja", "ko", "pt-BR"]
    /// Tags that can be downloaded; any other tag is unsupported.
    var downloadable: Set<String> = []
    /// Translations by source text; text without one comes back unchanged.
    var answers: [String: String] = [:]
    /// Thrown by `translate` while set.
    var failure: Error?
    /// What a download does: by default the language becomes installed.
    var onDownload: ((String) throws -> Void)?
    /// While set, a translation waits for `releaseTranslations()` before it answers.
    var holdsTranslations = false
    private var held: [CheckedContinuation<Void, Never>] = []
    /// The translations waiting for `releaseTranslations()`.
    var heldCount: Int { held.count }

    private(set) var availabilityQuestions: [String] = []
    /// "tag:text" for each translation asked.
    private(set) var translations: [String] = []
    private(set) var downloads: [String] = []
    let sessionHost = TranslationSessionHost()

    /// Every call that reached the framework's stand-in.
    var questionCount: Int { availabilityQuestions.count + translations.count + downloads.count }

    func availability(from source: Locale.Language, to target: Locale.Language) async
        -> OnDeviceTranslationAvailability
    {
        let tag = Self.tag(source)
        availabilityQuestions.append(tag)
        if installed.contains(tag) { return .installed }
        return downloadable.contains(tag) ? .downloadable : .unsupported
    }

    func translate(_ text: String, from source: Locale.Language, to target: Locale.Language)
        async throws -> String
    {
        translations.append("\(Self.tag(source)):\(text)")
        if holdsTranslations { await withCheckedContinuation { held.append($0) } }
        if let failure { throw failure }
        return answers[text] ?? text
    }

    func download(from source: Locale.Language, to target: Locale.Language) async throws {
        let tag = Self.tag(source)
        downloads.append(tag)
        if let onDownload {
            try onDownload(tag)
        } else {
            downloadable.remove(tag)
            installed.insert(tag)
        }
    }

    /// Answers every translation that waits, and stops holding new ones.
    func releaseTranslations() {
        holdsTranslations = false
        let waiting = held
        held = []
        for continuation in waiting { continuation.resume() }
    }

    /// The app language a `Locale.Language` was made from.
    static func tag(_ language: Locale.Language) -> String {
        AppLanguage.supported.map(\.tag).first { Locale.Language(identifier: $0) == language }
            ?? language.maximalIdentifier
    }
}

extension WorkshopSearchTranslator {
    /// A translator over `defaults` that asks `backend` instead of this Mac's Translation
    /// framework, following the language `language` shows: what every panel fixture builds the
    /// controller with, so no panel test's search or Settings row depends on the languages this Mac
    /// has downloaded. The default fake has every language downloaded, the longest note the
    /// Settings row can show.
    static func fake(
        defaults: UserDefaults, backend: FakeTranslation? = nil, language: AppLanguageStore
    ) -> WorkshopSearchTranslator {
        WorkshopSearchTranslator(
            defaults: defaults, backend: backend ?? FakeTranslation(), appLanguage: { language.effective })
    }
}
