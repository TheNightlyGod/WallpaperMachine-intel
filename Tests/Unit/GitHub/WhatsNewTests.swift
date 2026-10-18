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
        let history = try AppReleaseHistory(markdown: entry("1.1.0") + entry("1.2.0")
            .replacingOccurrences(of: "Added a library filter.", with: "Fixed playback.")
            .replacingOccurrences(of: "新增媒体库筛选功能。", with: "修复播放问题。"))
        _ = store("1.0.0").announcement(history: history, existingUser: false)
        let current = store("1.2.0")
        let announcement = try XCTUnwrap(current.announcement(history: history, existingUser: true))
        let controller = WhatsNewViewController(
            announcement: announcement, preferences: current, initialLanguage: .english, close: {})
        _ = controller.view

        func select(_ segment: Int) {
            controller.languageControl.selectedSegment = segment
            controller.languageControl.sendAction(controller.languageControl.action, to: controller.languageControl.target)
        }
        select(0)
        let english = controller.notesView.string
        XCTAssertTrue(english.contains("Fixed playback."))
        XCTAssertTrue(english.contains("Added a library filter."))
        XCTAssertFalse(english.contains("修复播放问题。"))
        XCTAssertFalse(english.contains("新增媒体库筛选功能。"))
        select(1)
        let chinese = controller.notesView.string
        XCTAssertTrue(chinese.contains("修复播放问题。"))
        XCTAssertTrue(chinese.contains("新增媒体库筛选功能。"))
        XCTAssertFalse(chinese.contains("Fixed playback."))
        XCTAssertFalse(chinese.contains("Added a library filter."))
        XCTAssertLessThan(try XCTUnwrap(chinese.range(of: "1.2.0")?.lowerBound),
                          try XCTUnwrap(chinese.range(of: "1.1.0")?.lowerBound))
        select(0)
        XCTAssertEqual(controller.notesView.string, english)
    }

    func testInitialTranslationFollowsSavedAppLanguageAndSystemSelection() throws {
        let history = try history()
        let current = store("1.2.0")
        let announcement = try XCTUnwrap(current.announcement(history: history, existingUser: true))
        let cases = [
            ("zh-Hans", "en", true), ("zh-Hant", "en", true),
            ("en", "zh-CN", false), ("ja", "zh-CN", false),
            ("system", "zh-CN", true), ("system", "en", false),
        ]
        for (preference, systemLanguage, chinese) in cases {
            let language = AppLanguageStore(defaults: defaults, systemLanguages: [systemLanguage])
            try language.set(preference)
            let controller = WhatsNewViewController(
                announcement: announcement, preferences: current, initialLanguage: language.effective, close: {})
            _ = controller.view
            let expected = chinese ? "新增媒体库筛选功能。" : "Added a library filter."
            let excluded = chinese ? "Added a library filter." : "新增媒体库筛选功能。"
            XCTAssertTrue(controller.notesView.string.contains(expected), "\(preference), system: \(systemLanguage)")
            XCTAssertFalse(controller.notesView.string.contains(excluded), "\(preference), system: \(systemLanguage)")
        }
    }

    func testEachTranslationShowsItsOwnBannerForTheAnnouncedVersionOnly() throws {
        let markdown = ["1.0.0", "1.1.0", "1.2.0"].map { version in
            entry(version)
                .replacingOccurrences(of: "### English\n", with: """
                ### English
                ![WallpaperMachine \(version)](Resources/ReleaseBanners/\(version).jpg)

                """)
                .replacingOccurrences(of: "### 简体中文\n", with: """
                ### 简体中文
                ![WallpaperMachine \(version) 中文](Resources/ReleaseBanners/\(version).zh-Hans.jpg)

                """)
        }.joined()
        let history = try AppReleaseHistory(markdown: markdown)
        let current = try XCTUnwrap(history.entries.first)
        XCTAssertEqual(current.englishBanner,
                       AppReleaseHistory.Banner(fileName: "1.2.0.jpg", description: "WallpaperMachine 1.2.0"))
        XCTAssertEqual(current.chineseBanner?.fileName, "1.2.0.zh-Hans.jpg")
        XCTAssertEqual(current.english.sections.first?.items, ["Added a library filter."],
                       "The banner line is not release prose")
        XCTAssertEqual(current.english.sections.first?.isList, true)
        _ = store("1.0.0").announcement(history: history, existingUser: false)
        let announcement = try XCTUnwrap(store("1.2.0").announcement(history: history, existingUser: true))
        var requested: [String] = []
        let wide = NSImage(size: NSSize(width: 30, height: 10))
        let tall = NSImage(size: NSSize(width: 20, height: 10))
        let controller = WhatsNewViewController(
            announcement: announcement, preferences: store("1.2.0"), initialLanguage: .english,
            bannerImage: { banner in
                requested.append(banner.fileName)
                return banner.fileName.contains("zh-Hans") ? tall : wide
            }, close: {})
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(requested, ["1.2.0.jpg", "1.2.0.zh-Hans.jpg"], "Skipped versions keep their banners to themselves")
        let bannerView = try XCTUnwrap(controller.bannerView)
        XCTAssertIdentical(bannerView.image, wide)
        XCTAssertEqual(bannerView.accessibilityLabel(), "WallpaperMachine 1.2.0")
        XCTAssertEqual(bannerView.frame.width / bannerView.frame.height, 3, accuracy: 0.01)
        XCTAssertFalse(controller.notesView.string.contains("!["))

        controller.languageControl.selectedSegment = 1
        controller.languageControl.sendAction(controller.languageControl.action, to: controller.languageControl.target)
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertIdentical(bannerView.image, tall)
        XCTAssertEqual(bannerView.accessibilityLabel(), "WallpaperMachine 1.2.0 中文")
        XCTAssertEqual(bannerView.frame.width / bannerView.frame.height, 2, accuracy: 0.01)

        let missing = WhatsNewViewController(
            announcement: announcement, preferences: store("1.2.0"), initialLanguage: .english,
            bannerImage: { _ in nil }, close: {})
        _ = missing.view
        XCTAssertNil(missing.bannerView, "A banner the bundle lacks leaves the window as it was")
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

    private func store(_ version: String) -> WhatsNewStore {
        WhatsNewStore(defaults: defaults, currentVersion: version)
    }

    private func history() throws -> AppReleaseHistory {
        try AppReleaseHistory(markdown: ["1.1.0", "2.0.0", "1.0.0", "1.2.0"].map(entry).joined())
    }

    private func entry(_ version: String) -> String {
        """
        ## \(version) — 2026-01-01
        ### English
        #### New
        - Added a library filter.
        ### 简体中文
        #### 新增
        - 新增媒体库筛选功能。
        **Full changelog**: https://example.com/compare

        """
    }
}
