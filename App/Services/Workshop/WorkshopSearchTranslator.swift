import Foundation
import Observation

/// A Workshop search typed in another language, and the English words Steam was searched with
/// instead. Display-only beyond the search itself: nothing stores it.
struct WorkshopSearchTranslation: Equatable, Sendable {
    /// What the person typed, trimmed.
    let original: String
    /// The translation into English that Steam is searched with.
    let english: String
    /// The `AppLanguage` tag the original was read as.
    let language: String
}

/// Translates a Workshop search into English on this Mac before it goes to Steam, whose titles and
/// tags are mostly English.
///
/// Only a search that reads as one of the app's other languages (`WorkshopSearchLanguage`) is
/// translated, and only while that language is downloaded for translation: a pair that is not
/// downloaded is never asked for, since that would put the system's download prompt in the middle
/// of a search. English, links and item ids are sent as typed, and so is anything when the switch
/// is off, when the translation fails or when it changes nothing. The last 100 answers are kept, so
/// a sort, a filter or another page of the same search translates nothing again. A text the
/// person chose to search as typed is the search's to remember (`WorkshopStore`), not this
/// window's.
///
/// A language is downloaded only when the person picks one (`download(_:)`), from Settings.
@MainActor
@Observable
final class WorkshopSearchTranslator {
    /// Whether searches are translated. Absent means on.
    nonisolated static let enabledKey = "WallpaperMachine.translatesWorkshopSearches"
    /// How many answers are kept.
    static let cacheLimit = 100
    /// Longer text is searched as typed: a query is a few words, not a passage.
    static let maximumLength = 256
    nonisolated static let english = Locale.Language(identifier: "en")

    /// One language a search can be read in, and whether it is downloaded for translation.
    struct LanguageState: Equatable, Identifiable {
        let language: AppLanguage
        let availability: OnDeviceTranslationAvailability
        var id: String { language.tag }
    }

    private(set) var isEnabled: Bool
    /// The languages searches can be read in, as last read; nil until a read finished.
    private(set) var languages: [LanguageState]?
    /// How many searches wait for the translator now; Discover shows them as searching.
    private var pendingTranslations = 0
    /// A search waits for its English: Discover says it is searching, as it does while Steam answers.
    var isTranslating: Bool { pendingTranslations > 0 }

    @ObservationIgnored let backend: any OnDeviceTranslating
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let appLanguage: @MainActor () -> AppLanguage
    /// Answers by language and typed text; nil is a translation that changed nothing.
    @ObservationIgnored private var answers: [String: String?] = [:]
    @ObservationIgnored private var answerOrder: [String] = []
    @ObservationIgnored private var languageRead: Task<Void, Never>?
    /// The languages the running read asks about.
    @ObservationIgnored private var readCandidates: [AppLanguage] = []

    /// - Parameter appLanguage: The language the app shows, which decides whether Portuguese is read.
    init(
        defaults: UserDefaults = ClientPreferences.defaults,
        backend: (any OnDeviceTranslating)? = nil,
        appLanguage: @escaping @MainActor () -> AppLanguage = { AppLanguageStore.shared.effective }
    ) {
        self.defaults = defaults
        self.backend = backend ?? SystemTranslation()
        self.appLanguage = appLanguage
        isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    /// What the panel's `.translationTask` lends sessions to.
    var sessionHost: TranslationSessionHost { backend.sessionHost }

    // MARK: Searching

    /// The English translation to search with instead of `text`, or nil to search it as typed.
    func translation(for text: String) async -> WorkshopSearchTranslation? {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isEnabled, !typed.isEmpty, typed.count <= Self.maximumLength,
            WorkshopLink.itemID(in: typed) == nil, !typed.contains("://"),
            let language = WorkshopSearchLanguage.detect(typed, app: appLanguage())
        else { return nil }
        let key = "\(language.tag)\u{1F}\(typed)"
        if let answer = answers[key] {
            remember(key, answer)
            return answer.map { WorkshopSearchTranslation(original: typed, english: $0, language: language.tag) }
        }
        let source = Locale.Language(identifier: language.tag)
        pendingTranslations += 1
        defer { pendingTranslations -= 1 }
        guard await backend.availability(from: source, to: Self.english) == .installed else { return nil }
        let english: String?
        do {
            english = Self.searchWords(try await backend.translate(typed, from: source, to: Self.english), for: typed)
        } catch {
            AppLog.warn("Translating a Workshop search from \(language.tag) failed: \(error.localizedDescription)")
            return nil
        }
        remember(key, english)
        return english.map { WorkshopSearchTranslation(original: typed, english: $0, language: language.tag) }
    }

    /// The words to send for `translation` of `original`: trimmed, without the full stop a
    /// translator adds to a phrase that had none, and nil when that leaves nothing, or nothing
    /// but the original again (a name such as "Totoro").
    static func searchWords(_ translation: String, for original: String) -> String? {
        var words = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        if words.hasSuffix("."), !original.hasSuffix("."), !original.hasSuffix("。") {
            words = String(words.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        guard !words.isEmpty,
            words.compare(original, options: [.caseInsensitive, .diacriticInsensitive]) != .orderedSame
        else { return nil }
        return words
    }

    private func remember(_ key: String, _ answer: String?) {
        answers[key] = .some(answer)
        answerOrder.removeAll { $0 == key }
        answerOrder.append(key)
        while answerOrder.count > Self.cacheLimit {
            answers[answerOrder.removeFirst()] = nil
        }
    }

    // MARK: Settings

    /// Turns translation on or off. Answers already kept stay for when it is on again.
    func setEnabled(_ on: Bool) {
        defaults.set(on, forKey: Self.enabledKey)
        isEnabled = on
        if on { refreshLanguages() } else { stopReadingLanguages() }
    }

    /// Back to the default, on, for **Reset all settings**, which Settings › General offers beside
    /// the row: the languages are read again, as turning the switch on reads them.
    func resetPreference() {
        defaults.removeObject(forKey: Self.enabledKey)
        isEnabled = true
        refreshLanguages()
    }

    /// Reads which languages are downloaded, for Settings while it shows them. Nothing is read
    /// while translation is off. A read already running for the same languages is not started
    /// twice; one still asking about the languages of the app's language before it changed starts
    /// again for the new ones (Portuguese is read only while the app is in Portuguese).
    func refreshLanguages() {
        guard isEnabled else { return }
        let candidates = WorkshopSearchLanguage.candidates(app: appLanguage())
        if languageRead != nil, candidates == readCandidates { return }
        stopReadingLanguages()
        readCandidates = candidates
        languageRead = Task { [weak self] in
            var states: [LanguageState] = []
            for language in candidates {
                guard let self, !Task.isCancelled else { return }
                let availability = await self.backend.availability(
                    from: Locale.Language(identifier: language.tag), to: Self.english)
                states.append(LanguageState(language: language, availability: availability))
            }
            guard let self, !Task.isCancelled else { return }
            self.languages = states
            self.languageRead = nil
        }
    }

    /// Asks the person to download `language` for translation into English: the system's own
    /// prompt, which they can decline. Then reads the languages again.
    func download(_ language: AppLanguage) async throws {
        guard WorkshopSearchLanguage.candidates(app: appLanguage()).contains(language) else {
            throw InvalidControlValue()
        }
        defer {
            stopReadingLanguages()
            refreshLanguages()
        }
        do {
            try await backend.download(from: Locale.Language(identifier: language.tag), to: Self.english)
        } catch is CancellationError {
            // The prompt went away with the window: nothing was asked, so nothing failed.
        }
    }

    private func stopReadingLanguages() {
        languageRead?.cancel()
        languageRead = nil
    }
}
