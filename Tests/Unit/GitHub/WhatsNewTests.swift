import XCTest
@testable import WallpaperMachine

@MainActor
final class WhatsNewTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        defaults = try TemporaryDefaults.make(for: self).defaults
    }

    func testFreshInstallAndSameVersionRelaunchDoNotAnnounce() throws {
        let history = try history()
        XCTAssertNil(store("1.0.0").announcement(history: history, existingUser: false))
        XCTAssertNil(store("1.0.0").announcement(history: history, existingUser: true))
        XCTAssertEqual(store("1.1.0").announcement(history: history, existingUser: true)?.previousVersion, "1.0.0")
    }

    func testUpgradeIncludesSkippedVersionsButNotPreviousOrFutureReleases() throws {
        let history = try history()
        _ = store("1.0.0").announcement(history: history, existingUser: false)
        let current = store("1.2.0")
        let announcement = try XCTUnwrap(current.announcement(history: history, existingUser: true))
        XCTAssertEqual(announcement.currentVersion, "1.2.0")
        XCTAssertEqual(announcement.previousVersion, "1.0.0")
        XCTAssertEqual(announcement.releases.map(\.version.display), ["1.2.0", "1.1.0"])
        XCTAssertEqual(announcement.releases.last?.english.sections.first?.items, ["Added a library filter."])
        XCTAssertEqual(announcement.releases.last?.chinese.sections.first?.items, ["新增媒体库筛选功能。"])
        XCTAssertNotNil(store("1.2.0").announcement(history: history, existingUser: true), "An interrupted presentation must retry")
        current.didPresent(announcement)
        XCTAssertNil(store("1.2.0").announcement(history: history, existingUser: true))
    }

    func testCheckboxImmediatelySuppressesFutureVersionsAcrossStoreReloads() throws {
        let history = try history()
        _ = store("1.0.0").announcement(history: history, existingUser: false)
        let current = store("1.1.0")
        let announcement = try XCTUnwrap(current.announcement(history: history, existingUser: true))
        let controller = WhatsNewViewController(
            announcement: announcement, preferences: current, initialLanguage: .english, close: {})
        _ = controller.view
        controller.suppressionCheckbox.performClick(nil)
        XCTAssertNil(store("1.2.0").announcement(history: history, existingUser: true))
        XCTAssertNil(store("2.0.0").announcement(history: history, existingUser: true))
        controller.suppressionCheckbox.performClick(nil)
        XCTAssertFalse(store("2.0.0").isSuppressed)
        XCTAssertNil(store("1.2.0").announcement(history: history, existingUser: true), "Suppressed versions still advance the high-water mark")
    }

    func testLanguageSelectionReplacesAllReleaseTranslationsAndCanSwitchBack() throws {
        let history = try AppReleaseHistory(markdown: entry("1.5.6") + entry("1.5.7")
            .replacingOccurrences(of: "Added a library filter.", with: "Fixed playback.")
            .replacingOccurrences(of: "新增媒体库筛选功能。", with: "修复播放问题。")
            .replacingOccurrences(of: "보관함 필터가 추가되었습니다.", with: "재생 문제가 수정되었습니다."))
        _ = store("1.5.5").announcement(history: history, existingUser: false)
        let current = store("1.5.7")
        let announcement = try XCTUnwrap(current.announcement(history: history, existingUser: true))
        let controller = WhatsNewViewController(
            announcement: announcement, preferences: current, initialLanguage: .english, close: {})
        _ = controller.view

        select(.english, in: controller)
        let english = controller.notesView.string
        XCTAssertTrue(english.contains("Fixed playback."))
        XCTAssertTrue(english.contains("Added a library filter."))
        XCTAssertFalse(english.contains("修复播放问题。"))
        XCTAssertFalse(english.contains("新增媒体库筛选功能。"))
        select(.chinese, in: controller)
        let chinese = controller.notesView.string
        XCTAssertTrue(chinese.contains("修复播放问题。"))
        XCTAssertTrue(chinese.contains("新增媒体库筛选功能。"))
        XCTAssertFalse(chinese.contains("Fixed playback."))
        XCTAssertFalse(chinese.contains("Added a library filter."))
        XCTAssertLessThan(try XCTUnwrap(chinese.range(of: "1.5.7")?.lowerBound),
                          try XCTUnwrap(chinese.range(of: "1.5.6")?.lowerBound))
        select(.korean, in: controller)
        let korean = controller.notesView.string
        XCTAssertTrue(korean.contains("재생 문제가 수정되었습니다."))
        XCTAssertTrue(korean.contains("Added a library filter."), "Legacy entries fall back independently to English")
        XCTAssertFalse(korean.contains("Fixed playback."))
        XCTAssertFalse(korean.contains("修复播放问题。"))
        XCTAssertFalse(korean.contains("新增媒体库筛选功能。"))
        XCTAssertLessThan(try XCTUnwrap(korean.range(of: "1.5.7")?.lowerBound),
                          try XCTUnwrap(korean.range(of: "1.5.6")?.lowerBound))
        select(.english, in: controller)
        XCTAssertEqual(controller.notesView.string, english)
        select(.chinese, in: controller)
        XCTAssertEqual(controller.notesView.string, chinese)
        select(.korean, in: controller)
        XCTAssertEqual(controller.notesView.string, korean)
    }

    func testInitialTranslationFollowsSavedAppLanguageAndSystemSelection() throws {
        let history = try AppReleaseHistory(markdown: entry("1.5.7"))
        let current = store("1.5.7")
        let announcement = try XCTUnwrap(current.announcement(history: history, existingUser: true))
        let cases: [(String, String, AppReleaseHistory.Language)] = [
            ("zh-Hans", "en", .chinese), ("zh-Hant", "en", .chinese),
            ("en", "zh-CN", .english), ("ja", "zh-CN", .english),
            ("ko", "zh-CN", .korean), ("en", "ko-KR", .english),
            ("system", "zh-CN", .chinese), ("system", "zh-TW", .chinese),
            ("system", "en", .english), ("system", "ja-JP", .english),
            ("system", "ko-KR", .korean),
        ]
        let translations: [AppReleaseHistory.Language: String] = [
            .english: "Added a library filter.", .chinese: "新增媒体库筛选功能。", .korean: "보관함 필터가 추가되었습니다.",
        ]
        for (preference, systemLanguage, expectedLanguage) in cases {
            let language = AppLanguageStore(defaults: defaults, systemLanguages: [systemLanguage])
            try language.set(preference)
            let controller = WhatsNewViewController(
                announcement: announcement, preferences: current, initialLanguage: language.effective, close: {})
            _ = controller.view
            for (translation, text) in translations {
                XCTAssertEqual(controller.notesView.string.contains(text), translation == expectedLanguage,
                               "\(preference), system: \(systemLanguage), translation: \(translation)")
            }
        }
    }

    func testEachTranslationShowsItsOwnBannerForTheAnnouncedVersionOnly() throws {
        let versions = ["1.5.5", "1.5.6", "1.5.7"]
        let markdown = versions.map { version in
            bannerEntry(version, files: [
                .english: "\(version).jpg", .chinese: "\(version).zh-Hans.jpg", .korean: "\(version).ko.jpg",
            ])
        }.joined()
        let history = try AppReleaseHistory(markdown: markdown)
        let current = try XCTUnwrap(history.entries.first)
        XCTAssertEqual(current.banner(language: .english),
                       AppReleaseHistory.Banner(fileName: "1.5.7.jpg", description: "English"))
        XCTAssertEqual(current.banner(language: .chinese)?.fileName, "1.5.7.zh-Hans.jpg")
        XCTAssertEqual(current.banner(language: .korean)?.fileName, "1.5.7.ko.jpg")
        for language in AppReleaseHistory.Language.allCases {
            XCTAssertEqual(current.notes(language: language).sections.count, 1, "A banner is not release prose")
            XCTAssertEqual(current.notes(language: language).sections.first?.isList, true)
        }
        _ = store("1.5.4").announcement(history: history, existingUser: false)
        let announcement = try XCTUnwrap(store("1.5.7").announcement(history: history, existingUser: true))
        var requested: [String] = []
        let images: [AppReleaseHistory.Language: NSImage] = [
            .english: NSImage(size: NSSize(width: 30, height: 10)),
            .chinese: NSImage(size: NSSize(width: 20, height: 10)),
            .korean: NSImage(size: NSSize(width: 40, height: 10)),
        ]
        let controller = WhatsNewViewController(
            announcement: announcement, preferences: store("1.5.7"), initialLanguage: .english,
            bannerImage: { banner in
                requested.append(banner.fileName)
                if banner.fileName.contains("zh-Hans") { return images[.chinese] }
                if banner.fileName.contains(".ko.") { return images[.korean] }
                return images[.english]
            }, close: {})
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(requested, ["1.5.7.jpg", "1.5.7.zh-Hans.jpg", "1.5.7.ko.jpg"],
                       "Skipped versions keep their banners to themselves")
        let bannerView = try XCTUnwrap(controller.bannerView)
        for language in AppReleaseHistory.Language.allCases {
            select(language, in: controller)
            controller.view.layoutSubtreeIfNeeded()
            let image = try XCTUnwrap(images[language])
            XCTAssertIdentical(bannerView.image, image)
            XCTAssertEqual(bannerView.accessibilityLabel(), language.name)
            XCTAssertEqual(bannerView.frame.width / bannerView.frame.height,
                           image.size.width / image.size.height, accuracy: 0.01)
            XCTAssertFalse(controller.notesView.string.contains("!["))
        }
        XCTAssertEqual(requested.count, 3, "Changing translations reuses the loaded pictures")

        let missing = WhatsNewViewController(
            announcement: announcement, preferences: store("1.5.7"), initialLanguage: .english,
            bannerImage: { _ in nil }, close: {})
        _ = missing.view
        XCTAssertNil(missing.bannerView, "A banner the bundle lacks leaves the window as it was")
    }

    func testBannerFallbacksUseAvailablePicturesInLanguageOrder() throws {
        let english = NSImage(size: NSSize(width: 30, height: 10))
        let chinese = NSImage(size: NSSize(width: 20, height: 10))
        let invalid = NSImage(size: .zero)
        let cases: [(String, Bool, [String: NSImage], [AppReleaseHistory.Language: String])] = [
            ("missing Korean", false, ["1.5.7.jpg": english, "1.5.7.zh-Hans.jpg": chinese],
             [.english: "English", .chinese: "简体中文", .korean: "English"]),
            ("unreadable Korean", true, ["1.5.7.jpg": english, "1.5.7.zh-Hans.jpg": chinese],
             [.english: "English", .chinese: "简体中文", .korean: "English"]),
            ("invalid Korean size", true, ["1.5.7.jpg": english, "1.5.7.zh-Hans.jpg": chinese, "1.5.7.ko.jpg": invalid],
             [.english: "English", .chinese: "简体中文", .korean: "English"]),
            ("only Chinese loads", true, ["1.5.7.zh-Hans.jpg": chinese],
             [.english: "简体中文", .chinese: "简体中文", .korean: "简体中文"]),
            ("only English loads", true, ["1.5.7.jpg": english],
             [.english: "English", .chinese: "English", .korean: "English"]),
        ]
        for (name, hasKoreanBanner, images, expected) in cases {
            var files: [AppReleaseHistory.Language: String] = [
                .english: "1.5.7.jpg", .chinese: "1.5.7.zh-Hans.jpg",
            ]
            if hasKoreanBanner { files[.korean] = "1.5.7.ko.jpg" }
            let history = try AppReleaseHistory(markdown: bannerEntry("1.5.7", files: files))
            let announcement = try XCTUnwrap(store("1.5.7").announcement(history: history, existingUser: true))
            let controller = WhatsNewViewController(
                announcement: announcement, preferences: store("1.5.7"),
                initialLanguage: try XCTUnwrap(AppLanguage.named("ko")),
                bannerImage: { images[$0.fileName] }, close: {})
            _ = controller.view
            let banner = try XCTUnwrap(controller.bannerView)
            for language in AppReleaseHistory.Language.allCases {
                select(language, in: controller)
                XCTAssertEqual(banner.accessibilityLabel(), expected[language], name)
            }
        }
    }

    func testSharedBannerFilesAreLoadedOnceEvenWhenUnreadable() throws {
        let files: [AppReleaseHistory.Language: String] = [
            .english: "1.5.7.jpg", .chinese: "1.5.7.jpg", .korean: "1.5.7.jpg",
        ]
        let history = try AppReleaseHistory(markdown: bannerEntry("1.5.7", files: files))
        let announcement = try XCTUnwrap(store("1.5.7").announcement(history: history, existingUser: true))
        for readable in [true, false] {
            var requested: [String] = []
            let image = NSImage(size: NSSize(width: 30, height: 10))
            let controller = WhatsNewViewController(
                announcement: announcement, preferences: store("1.5.7"), initialLanguage: .english,
                bannerImage: { banner in
                    requested.append(banner.fileName)
                    return readable ? image : nil
                }, close: {})
            _ = controller.view
            XCTAssertEqual(requested, ["1.5.7.jpg"])
            XCTAssertEqual(controller.bannerView == nil, !readable)
            if readable {
                for language in AppReleaseHistory.Language.allCases {
                    select(language, in: controller)
                    XCTAssertIdentical(controller.bannerView?.image, image)
                }
            }
        }
    }

    func testListsAreBulletedAndHighlightsStandOut() throws {
        let history = try AppReleaseHistory(markdown: entry("1.2.0").replacingOccurrences(of: "#### New\n", with: """
        A release about filters.
        #### Highlights
        - Filters are faster.
        #### New

        """))
        _ = store("1.0.0").announcement(history: history, existingUser: false)
        let announcement = try XCTUnwrap(store("1.2.0").announcement(history: history, existingUser: true))
        let controller = WhatsNewViewController(
            announcement: announcement, preferences: store("1.2.0"), initialLanguage: .english, close: {})
        _ = controller.view
        let notes = controller.notesView.string
        XCTAssertTrue(notes.contains("A release about filters.\n"), "A summary is a paragraph, not a list entry")
        XCTAssertFalse(notes.contains("\tA release about filters."))
        XCTAssertTrue(notes.contains("\u{2726}\tFilters are faster."))
        XCTAssertTrue(notes.contains("\u{2022}\tAdded a library filter."))
        let storage = try XCTUnwrap(controller.notesView.textStorage)
        let heading = (notes as NSString).range(of: "Highlights")
        XCTAssertEqual(storage.attribute(.foregroundColor, at: heading.location, effectiveRange: nil) as? NSColor,
                       .controlAccentColor)
        let entry = (notes as NSString).range(of: "Added a library filter.")
        let style = try XCTUnwrap(storage.attribute(.paragraphStyle, at: entry.location, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertGreaterThan(style.headIndent, 0, "Wrapped lines hang under the text, not the bullet")
    }

    func testKoreanHighlightsHaveTheSameEmphasisAsEnglish() throws {
        let markdown = entry("1.5.7").replacingOccurrences(of: "#### 새로운 기능\n", with: """
        필터를 개선한 업데이트입니다.
        #### 주요 변경 사항
        - 필터가 더 빨라졌습니다.
        #### 새로운 기능

        """)
        let history = try AppReleaseHistory(markdown: markdown)
        let announcement = try XCTUnwrap(store("1.5.7").announcement(history: history, existingUser: true))
        let controller = WhatsNewViewController(
            announcement: announcement, preferences: store("1.5.7"),
            initialLanguage: try XCTUnwrap(AppLanguage.named("ko")), close: {})
        _ = controller.view
        let notes = controller.notesView.string
        XCTAssertTrue(notes.contains("필터를 개선한 업데이트입니다.\n"))
        XCTAssertFalse(notes.contains("\t필터를 개선한 업데이트입니다."))
        XCTAssertTrue(notes.contains("\u{2726}\t필터가 더 빨라졌습니다."))
        XCTAssertTrue(notes.contains("\u{2022}\t보관함 필터가 추가되었습니다."))
        let storage = try XCTUnwrap(controller.notesView.textStorage)
        let heading = (notes as NSString).range(of: "주요 변경 사항")
        XCTAssertNotEqual(heading.location, NSNotFound)
        guard heading.location != NSNotFound else { return }
        XCTAssertEqual(storage.attribute(.foregroundColor, at: heading.location, effectiveRange: nil) as? NSColor,
                       .controlAccentColor)
        let marker = (notes as NSString).range(of: "\u{2726}")
        XCTAssertNotEqual(marker.location, NSNotFound)
        guard marker.location != NSNotFound else { return }
        XCTAssertEqual(storage.attribute(.foregroundColor, at: marker.location, effectiveRange: nil) as? NSColor,
                       .controlAccentColor)
    }

    func testDowngradeAndReturnDoNotRepeatAnAnnouncement() throws {
        let history = try history()
        _ = store("1.2.0").announcement(history: history, existingUser: false)
        XCTAssertNil(store("1.0.0").announcement(history: history, existingUser: true))
        XCTAssertNil(store("1.2.0").announcement(history: history, existingUser: true))
        XCTAssertEqual(store("2.0.0").announcement(history: history, existingUser: true)?.previousVersion, "1.2.0")
    }

    func testLegacyInstallationShowsCurrentNotesWithoutInventingPreviousVersion() throws {
        let history = try history()
        let current = store("1.2.0")
        let announcement = try XCTUnwrap(current.announcement(history: history, existingUser: true))
        XCTAssertNil(announcement.previousVersion)
        XCTAssertEqual(announcement.releases.map(\.version.display), ["1.2.0"])
        current.didPresent(announcement)
        XCTAssertNil(store("1.2.0").announcement(history: history, existingUser: true))
    }

    func testMissingCurrentNotesDoNotConsumeAnUpgrade() throws {
        let incomplete = try AppReleaseHistory(markdown: entry("1.0.0"))
        _ = store("1.0.0").announcement(history: incomplete, existingUser: false)
        XCTAssertNil(store("1.2.0").announcement(history: incomplete, existingUser: true))
        XCTAssertEqual(store("1.2.0").announcement(history: try history(), existingUser: true)?.previousVersion, "1.0.0")
        XCTAssertNil(store("not-a-version").announcement(history: try history(), existingUser: true))
    }

    func testHistoryRejectsMissingTranslationsAndDuplicateVersions() throws {
        XCTAssertThrowsError(try AppReleaseHistory(markdown: "## 1.0.0 — 2026-01-01\n### English\n- Added a filter."))
        XCTAssertThrowsError(try AppReleaseHistory(markdown: entry("1.0.0") + entry("1.0.0")))
        XCTAssertThrowsError(try AppReleaseHistory(markdown: entry("invalid")))
        let history = try AppReleaseHistory(markdown: entry("1.0.0"))
        XCTAssertEqual(history.entries.first?.chinese.sections.first?.items, ["新增媒体库筛选功能。"], "Compare links are not release prose")
    }

    func testMixedHistoryKeepsKoreanSeparateAndFallsBackOnlyForLegacyEntries() throws {
        let history = try AppReleaseHistory(markdown: entry("1.5.7") + entry("1.5.6"))
        let current = try XCTUnwrap(history.entries.first)
        let legacy = try XCTUnwrap(history.entries.last)
        XCTAssertEqual(current.notes(language: .english).sections.first?.items, ["Added a library filter."])
        XCTAssertEqual(current.notes(language: .chinese).sections.first?.items, ["新增媒体库筛选功能。"])
        XCTAssertEqual(current.korean?.sections.first?.items, ["보관함 필터가 추가되었습니다."])
        XCTAssertEqual(current.notes(language: .korean), try XCTUnwrap(current.korean))
        XCTAssertNil(legacy.korean, "A later Korean block must not leak into another release")
        XCTAssertEqual(legacy.notes(language: .korean), legacy.english)
        XCTAssertEqual(legacy.chinese.sections.count, 1)
        XCTAssertEqual(legacy.chinese.sections.first?.items, ["新增媒体库筛选功能。"])
    }

    func testKoreanIsRequiredStartingWithVersionOneFiveSeven() throws {
        XCTAssertNoThrow(try AppReleaseHistory(markdown: entry("1.5.6", korean: false)))
        for version in ["1.5.7", "1.5.8", "1.6.0", "2.0.0"] {
            XCTAssertThrowsError(try AppReleaseHistory(markdown: entry(version, korean: false)), version) { error in
                XCTAssertEqual(error as? AppReleaseHistory.InvalidHistory, .missingTranslation)
            }
            XCTAssertNoThrow(try AppReleaseHistory(markdown: entry(version, korean: true)), version)
        }
        XCTAssertNoThrow(try AppReleaseHistory(markdown: entry("1.5.6", korean: true)),
                         "An older section may have Korean without making it mandatory for all older versions")
    }

    func testExplicitKoreanBlockCannotBeEmptyOrOnlyHeadingsAndBanner() throws {
        for version in ["1.5.6", "1.5.7"] {
            for replacement in ["", "![한국어](Resources/ReleaseBanners/\(version).ko.jpg)"] {
                let markdown = entry(version, korean: true).replacingOccurrences(
                    of: "- 보관함 필터가 추가되었습니다.", with: replacement)
                XCTAssertThrowsError(try AppReleaseHistory(markdown: markdown)) { error in
                    XCTAssertEqual(error as? AppReleaseHistory.InvalidHistory, .missingTranslation)
                }
            }
        }
    }

    func testLanguageHeadingsMustBeKnownUniqueAndOrdered() throws {
        let valid = entry("1.5.7")
        let cases = [
            valid.replacingOccurrences(of: "### 한국어", with: "### Japanese"),
            valid.replacingOccurrences(of: "### 简体中文", with: "### English"),
            valid.replacingOccurrences(of: "### 한국어", with: "### 简体中文"),
            valid.replacingOccurrences(of: "### English", with: "### 简体中文"),
            valid.replacingOccurrences(of: "### 简体中文", with: "### 한국어"),
            valid.replacingOccurrences(of: "### 한국어", with: "### 한국어\n### 한국어"),
            valid.replacingOccurrences(of: "### English", with: "###English"),
            valid + "### Other changes\n- Unexpected category level\n",
        ]
        for markdown in cases {
            XCTAssertThrowsError(try AppReleaseHistory(markdown: markdown)) { error in
                XCTAssertEqual(error as? AppReleaseHistory.InvalidHistory, .invalidLanguageHeading)
            }
        }
        let spaced = valid.replacingOccurrences(of: "### 한국어", with: "###\t한국어  ")
        XCTAssertNoThrow(try AppReleaseHistory(markdown: spaced))
    }

    func testHistoryRejectsUnreleasedAndHeadingsInsideNotes() throws {
        XCTAssertThrowsError(try AppReleaseHistory(markdown: """
        ## Unreleased
        ### English
        - Soon.
        ### 简体中文
        - 即将发布。

        """)) { error in
            XCTAssertEqual(error as? AppReleaseHistory.InvalidHistory, .invalidVersion)
        }
        XCTAssertThrowsError(try AppReleaseHistory(markdown: entry("1.0.0").replacingOccurrences(
            of: "- Added a library filter.\n",
            with: "- Added a library filter.\n## Also see\n"
        )))
    }

    private func bannerEntry(_ version: String, files: [AppReleaseHistory.Language: String]) -> String {
        var markdown = entry(version, korean: true)
        for (language, file) in files {
            markdown = markdown.replacingOccurrences(
                of: "### \(language.name)\n",
                with: "### \(language.name)\n![\(language.name)](Resources/ReleaseBanners/\(file))\n")
        }
        return markdown
    }

    private func select(_ language: AppReleaseHistory.Language, in controller: WhatsNewViewController) {
        controller.languageControl.selectedSegment = language.rawValue
        controller.languageControl.sendAction(controller.languageControl.action, to: controller.languageControl.target)
    }

    private func store(_ version: String) -> WhatsNewStore {
        WhatsNewStore(defaults: defaults, currentVersion: version)
    }

    private func history() throws -> AppReleaseHistory {
        try AppReleaseHistory(markdown: ["1.1.0", "2.0.0", "1.0.0", "1.2.0"].map { entry($0) }.joined())
    }

    private func entry(_ version: String, korean: Bool? = nil) -> String {
        let includesKorean = korean ?? (SemanticVersion(version).map {
            ($0.major, $0.minor, $0.patch) >= (1, 5, 7)
        } ?? false)
        let koreanNotes = includesKorean ? "### 한국어\n#### 새로운 기능\n- 보관함 필터가 추가되었습니다.\n" : ""
        return """
        ## \(version) — 2026-01-01
        ### English
        #### New
        - Added a library filter.
        ### 简体中文
        #### 新增
        - 新增媒体库筛选功能。
        \(koreanNotes)**Full changelog**: https://example.com/compare

        """
    }
}
