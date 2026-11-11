import XCTest
@testable import WallpaperMachine

/// The changelog sections the update manifest carries: how they parse, and which releases the update
/// window shows for a given running version.
@MainActor
final class AppReleaseHistoryTests: XCTestCase {
    func testLinkedHeadingCarriesVersionDateAndComparison() throws {
        let history = try AppReleaseHistory(markdown: entry("1.6.2"))
        let release = try XCTUnwrap(history.entries.first)
        XCTAssertEqual(release.version.display, "1.6.2")
        XCTAssertEqual(release.date, "2026-01-01")
        XCTAssertEqual(release.url?.absoluteString, "https://github.com/o/r/compare/v1.6.1...v1.6.2")
        let legacy = try XCTUnwrap(AppReleaseHistory(markdown: """
        ## 1.0.0 — 2025-12-31
        ### English
        - Added a filter.
        ### 简体中文
        - 新增筛选。

        """).entries.first)
        XCTAssertEqual(legacy.date, "2025-12-31", "the older heading still reads")
        XCTAssertNil(legacy.url)
    }

    func testNotesKeepTheirReferenceLinksForTheWindowAndDropThemForAbout() throws {
        let section = try XCTUnwrap(AppReleaseHistory(markdown: entry("1.6.2")).entries.first?.english.sections.first)
        XCTAssertEqual(section.title, "Features")
        XCTAssertEqual(section.items, ["Added a library filter"])
        XCTAssertEqual(section.markdown, [
            "Added a library filter (closes [#76](https://github.com/o/r/issues/76), closes [#77](https://github.com/o/r/issues/77)) ([abc1234](https://github.com/o/r/commit/abc1234def))",
        ])
        let link = UpdateWindow.inlineNotes(try XCTUnwrap(section.markdown.first))
        XCTAssertTrue(
            link.runs.contains { $0.link?.absoluteString == "https://github.com/o/r/issues/76" },
            "issue references stay links in the window")
        XCTAssertEqual(String(link.characters), "Added a library filter (closes #76, closes #77) (abc1234)")
    }

    func testWindowShowsEveryReleaseAboveTheRunningOneUpToTheLatest() throws {
        let changelog = ["2.3.0", "2.2.0", "2.1.0", "2.0.0"].map { entry($0) }.joined()
        let release = GitHubRelease(
            version: try XCTUnwrap(SemanticVersion("2.2.0")), htmlURL: URL(string: "https://github.com/o/r")!,
            prerelease: false, assets: [], notes: "#### Features\n- From the body", changelog: changelog)
        let shown = AppUpdateStore.releases(in: release, after: try XCTUnwrap(SemanticVersion("2.0.0")))
        XCTAssertEqual(shown.map(\.version.display), ["2.2.0", "2.1.0"], "newest first, nothing past the latest")
        XCTAssertEqual(shown.first?.notes(language: .korean).sections.first?.items, ["보관함 필터가 추가되었습니다"])
    }

    func testWindowFallsBackToTheReleaseBodyWithoutAUsableChangelog() throws {
        let latest = try XCTUnwrap(SemanticVersion("1.2.0"))
        let current = try XCTUnwrap(SemanticVersion("1.0.0"))
        for changelog in ["", "## Unreleased\n", entry("1.1.0")] {
            let release = GitHubRelease(
                version: latest, htmlURL: URL(string: "https://github.com/o/r/releases/tag/v1.2.0")!,
                prerelease: false, assets: [], notes: "#### Bug Fixes\n- From the body", changelog: changelog)
            let shown = AppUpdateStore.releases(in: release, after: current)
            XCTAssertEqual(shown.map(\.version.display), ["1.2.0"], changelog)
            XCTAssertEqual(shown.first?.notes(language: .chinese).sections.first?.items, ["From the body"])
        }
    }

    func testHistoryRejectsMissingTranslationsAndDuplicateVersions() throws {
        XCTAssertThrowsError(try AppReleaseHistory(markdown: "## 1.0.0 — 2026-01-01\n### English\n- Added a filter."))
        XCTAssertThrowsError(try AppReleaseHistory(markdown: entry("1.0.0") + entry("1.0.0")))
        XCTAssertThrowsError(try AppReleaseHistory(markdown: entry("invalid")))
        let history = try AppReleaseHistory(markdown: entry("1.0.0"))
        XCTAssertEqual(history.entries.first?.chinese.sections.first?.items, ["新增媒体库筛选功能"], "Reference links are not release prose")
    }

    func testMixedHistoryKeepsKoreanSeparateAndFallsBackOnlyForLegacyEntries() throws {
        let history = try AppReleaseHistory(markdown: entry("1.5.7") + entry("1.5.6"))
        let current = try XCTUnwrap(history.entries.first)
        let legacy = try XCTUnwrap(history.entries.last)
        XCTAssertEqual(current.notes(language: .english).sections.first?.items, ["Added a library filter"])
        XCTAssertEqual(current.notes(language: .chinese).sections.first?.items, ["新增媒体库筛选功能"])
        XCTAssertEqual(current.korean?.sections.first?.items, ["보관함 필터가 추가되었습니다"])
        XCTAssertEqual(current.notes(language: .korean), try XCTUnwrap(current.korean))
        XCTAssertNil(legacy.korean, "A later Korean block must not leak into another release")
        XCTAssertEqual(legacy.notes(language: .korean), legacy.english)
        XCTAssertEqual(legacy.chinese.sections.count, 1)
        XCTAssertEqual(legacy.chinese.sections.first?.items, ["新增媒体库筛选功能"])
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
                    of: "- 보관함 필터가 추가되었습니다 (closes [#76](https://github.com/o/r/issues/76), closes [#77](https://github.com/o/r/issues/77)) ([abc1234](https://github.com/o/r/commit/abc1234def))", with: replacement)
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
            of: "#### Features\n",
            with: "#### Features\n## Also see\n"
        )))
    }

    private func entry(_ version: String, korean: Bool? = nil) -> String {
        let includesKorean = korean ?? (SemanticVersion(version).map {
            ($0.major, $0.minor, $0.patch) >= (1, 5, 7)
        } ?? false)
        let links = "(closes [#76](https://github.com/o/r/issues/76), closes [#77](https://github.com/o/r/issues/77)) ([abc1234](https://github.com/o/r/commit/abc1234def))"
        let koreanNotes = includesKorean ? "### 한국어\n#### 새로운 기능\n- 보관함 필터가 추가되었습니다 \(links)\n" : ""
        let previous = SemanticVersion(version).map { "\($0.major).\($0.minor).\(max($0.patch, 1) - 1)" } ?? "0.0.0"
        return """
        ## [\(version)](https://github.com/o/r/compare/v\(previous)...v\(version)) (2026-01-01)
        ### English
        #### Features
        - Added a library filter \(links)
        ### 简体中文
        #### 新功能
        - 新增媒体库筛选功能 \(links)
        \(koreanNotes)
        """
    }
}
