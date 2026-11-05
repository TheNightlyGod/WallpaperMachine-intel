import XCTest

@testable import WallpaperMachine

/// When a Workshop search is translated into English before it goes to Steam: only text in one of
/// the app's other languages, only while that language is downloaded, never English, a link or an
/// id, and not while the switch is off; what is kept and downloaded, when a search shows as
/// translating, and when Settings reads the languages again.
@MainActor
final class WorkshopSearchTranslatorTests: XCTestCase {
    private var backend: FakeTranslation!
    private var defaults: UserDefaults!
    private var appLanguage = AppLanguage.english

    override func setUp() async throws {
        backend = FakeTranslation()
        backend.answers = ["猫": "cat", "風景": "landscape", "初音ミク": "Hatsune Miku", "gato preto": "black cat"]
        defaults = try TemporaryDefaults.make(for: self).defaults
        appLanguage = .english
    }

    private func makeTranslator() -> WorkshopSearchTranslator {
        WorkshopSearchTranslator(defaults: defaults, backend: backend, appLanguage: { [unowned self] in self.appLanguage })
    }

    func testASearchInADownloadedLanguageIsSentInEnglishAndKeepsWhatWasTyped() async {
        let translator = makeTranslator()
        let translation = await translator.translation(for: "  猫 ")
        XCTAssertEqual(translation, WorkshopSearchTranslation(original: "猫", english: "cat", language: "zh-Hans"))
        let traditional = await translator.translation(for: "風景")
        XCTAssertEqual(traditional?.english, "landscape")
        XCTAssertEqual(traditional?.language, "zh-Hant")
        XCTAssertEqual(backend.translations, ["zh-Hans:猫", "zh-Hant:風景"])
    }

    func testALanguageThatIsNotDownloadedIsNeverAskedToTranslateOrDownload() async {
        backend.installed = []
        backend.downloadable = ["zh-Hans"]
        let translator = makeTranslator()
        let translation = await translator.translation(for: "猫")
        XCTAssertNil(translation, "searched as typed")
        XCTAssertEqual(backend.availabilityQuestions, ["zh-Hans"])
        XCTAssertEqual(backend.translations, [], "an uninstalled pair would put a download prompt in the search")
        XCTAssertEqual(backend.downloads, [])
    }

    func testEnglishLinksAndIdsAreSearchedAsTypedWithoutAskingTheTranslator() async {
        let translator = makeTranslator()
        for text in [
            "anime girl", "3632513108", "https://steamcommunity.com/sharedfiles/filedetails/?id=3632513108",
            "https://example.com/猫", "", "   ",
        ] {
            let translation = await translator.translation(for: text)
            XCTAssertNil(translation, text)
        }
        XCTAssertEqual(backend.questionCount, 0)
    }

    func testNothingIsTranslatedOrAskedWhileTheSwitchIsOffAndTheChoiceIsKept() async {
        let translator = makeTranslator()
        XCTAssertTrue(translator.isEnabled, "on until turned off")
        translator.setEnabled(false)
        let translation = await translator.translation(for: "猫")
        XCTAssertNil(translation)
        translator.refreshLanguages()
        XCTAssertNil(translator.languages, "Settings reads nothing while it is off")
        XCTAssertEqual(backend.questionCount, 0)

        XCTAssertFalse(makeTranslator().isEnabled, "the next panel finds it off")
        translator.resetPreference()
        XCTAssertTrue(translator.isEnabled)
        XCTAssertTrue(makeTranslator().isEnabled)
    }

    func testAnAnswerIsKeptSoTheSameSearchTranslatesOnceUpToTheLimit() async {
        let translator = makeTranslator()
        _ = await translator.translation(for: "猫")
        let again = await translator.translation(for: "猫")
        XCTAssertEqual(again?.english, "cat", "a sort or another page searches the same English")
        XCTAssertEqual(backend.translations.count, 1)

        for index in 0..<WorkshopSearchTranslator.cacheLimit {
            _ = await translator.translation(for: "猫\(index)")
        }
        let afterLimit = backend.translations.count
        _ = await translator.translation(for: "猫")
        XCTAssertEqual(backend.translations.count, afterLimit + 1, "the oldest answer gave way")
    }

    func testATranslationThatChangesNothingOrFailsIsSearchedAsTyped() async {
        backend.answers["東京"] = "東京"
        backend.answers["雨の街"] = "City in the rain."
        let translator = makeTranslator()
        let unchanged = await translator.translation(for: "東京")
        XCTAssertNil(unchanged, "nothing to show beside a search Steam gets as typed")
        let sentence = await translator.translation(for: "雨の街")
        XCTAssertEqual(sentence?.english, "City in the rain", "the full stop a translator adds is no search word")

        backend.failure = FakeTranslation.Failure()
        let failed = await translator.translation(for: "初音ミク")
        XCTAssertNil(failed)
        backend.failure = nil
        let retried = await translator.translation(for: "初音ミク")
        XCTAssertEqual(retried?.english, "Hatsune Miku", "a failure is not kept")
    }

    func testASearchIsTranslatingOnlyWhileItWaitsForTheTranslator() async throws {
        let translator = makeTranslator()
        backend.holdsTranslations = true
        let search = Task { await translator.translation(for: "猫") }
        try await waitFor { self.backend.heldCount == 1 }
        XCTAssertTrue(translator.isTranslating, "Discover shows the search as under way")
        backend.releaseTranslations()
        let translation = await search.value
        XCTAssertEqual(translation?.english, "cat")
        XCTAssertFalse(translator.isTranslating)

        backend.holdsTranslations = true
        _ = await translator.translation(for: "猫")
        _ = await translator.translation(for: "aurora")
        XCTAssertEqual(backend.heldCount, 0, "a kept answer and English never wait for the translator")
        XCTAssertFalse(translator.isTranslating)
    }

    func testTheLanguagesAreReadOnceForTheAppLanguageAndAgainAfterItChangesOrAReset() async throws {
        let translator = makeTranslator()
        translator.refreshLanguages()
        translator.refreshLanguages()
        appLanguage = AppLanguage.named("pt-BR")!
        translator.refreshLanguages()
        translator.refreshLanguages()
        try await waitFor { translator.languages != nil }
        XCTAssertEqual(translator.languages?.map(\.id), ["zh-Hans", "zh-Hant", "ja", "ko", "pt-BR"])
        XCTAssertEqual(
            backend.availabilityQuestions, ["zh-Hans", "zh-Hant", "ja", "ko", "pt-BR"],
            "one read for the app's new language; the one for its old language stopped before it asked")

        translator.setEnabled(false)
        let asked = backend.availabilityQuestions.count
        translator.resetPreference()
        XCTAssertTrue(translator.isEnabled)
        try await waitFor { self.backend.availabilityQuestions.count == asked + 5 }
    }

    func testPortugueseIsTranslatedOnlyWhileTheAppIsInPortuguese() async {
        let translator = makeTranslator()
        let inEnglishApp = await translator.translation(for: "gato preto")
        XCTAssertNil(inEnglishApp)
        appLanguage = AppLanguage.named("pt-BR")!
        let inPortugueseApp = await translator.translation(for: "gato preto")
        XCTAssertEqual(inPortugueseApp?.english, "black cat")
        appLanguage = .english
        let backInEnglish = await translator.translation(for: "gato preto")
        XCTAssertNil(backInEnglish, "a kept answer does not outlive the language that read it")
    }

    func testSettingsReadsTheLanguagesAndDownloadsOnlyTheOnePicked() async throws {
        backend.installed = ["ja"]
        backend.downloadable = ["zh-Hans", "zh-Hant", "ko"]
        let translator = makeTranslator()
        translator.refreshLanguages()
        try await waitFor { translator.languages != nil }
        XCTAssertEqual(
            translator.languages?.map { "\($0.id)=\($0.availability)" },
            ["zh-Hans=downloadable", "zh-Hant=downloadable", "ja=installed", "ko=downloadable"])
        XCTAssertEqual(backend.downloads, [], "reading asks for no download")

        try await translator.download(try XCTUnwrap(AppLanguage.named("ko")))
        XCTAssertEqual(backend.downloads, ["ko"])
        try await waitFor { translator.languages?.first { $0.id == "ko" }?.availability == .installed }

        do {
            try await translator.download(try XCTUnwrap(AppLanguage.named("pt-BR")))
            XCTFail("Portuguese is not read while the app is in English, so it is not offered")
        } catch is InvalidControlValue {}
        XCTAssertEqual(backend.downloads, ["ko"])
    }

    private func waitFor(timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("condition not met in time") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
