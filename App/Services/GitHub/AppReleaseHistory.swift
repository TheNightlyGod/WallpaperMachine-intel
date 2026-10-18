import Foundation

/// The bilingual release history shipped with this copy, never the newest remote release.
struct AppReleaseHistory {
    struct Entry: Equatable, Sendable {
        let version: SemanticVersion
        let english: ReleaseNotes
        let chinese: ReleaseNotes
        /// The picture each translation opens with, if the release has one.
        var englishBanner: Banner? = nil
        var chineseBanner: Banner? = nil

        func banner(chinese: Bool) -> Banner? { chinese ? chineseBanner : englishBanner }
    }

    /// A file in the bundle's `ReleaseBanners` folder, and what it shows.
    struct Banner: Equatable, Sendable {
        static let directory = "ReleaseBanners"
        let fileName: String
        let description: String
    }

    enum InvalidHistory: Error {
        case missingResource, invalidVersion, duplicateVersion, missingTranslation
    }

    let entries: [Entry]

    init(bundle: Bundle = .main) throws {
        guard let url = bundle.url(forResource: "CHANGELOG", withExtension: "md") else {
            throw InvalidHistory.missingResource
        }
        try self.init(markdown: String(contentsOf: url, encoding: .utf8))
    }

    init(markdown: String) throws {
        var entries: [Entry] = []
        var version: SemanticVersion?
        var english = ""
        var chinese = ""
        var language = ""
        var englishBanner: Banner?
        var chineseBanner: Banner?
        func finish() throws {
            guard let version else { return }
            guard !entries.contains(where: { $0.version == version }) else {
                throw InvalidHistory.duplicateVersion
            }
            guard let en = ReleaseNotes(version: version.display, body: english),
                  let zh = ReleaseNotes(version: version.display, body: chinese) else {
                throw InvalidHistory.missingTranslation
            }
            entries.append(Entry(version: version, english: en, chinese: zh,
                                 englishBanner: englishBanner, chineseBanner: chineseBanner))
        }
        for line in markdown.components(separatedBy: .newlines) {
            if line.hasPrefix("## ") {
                try finish()
                // Every ## line is a release heading. Unreleased and headings inside
                // notes fail the whole file; release publishing rejects the same lines.
                guard let token = line.dropFirst(3).split(separator: " ").first,
                      let parsed = SemanticVersion(String(token)) else {
                    throw InvalidHistory.invalidVersion
                }
                version = parsed
                english = ""
                chinese = ""
                language = ""
                englishBanner = nil
                chineseBanner = nil
            } else if line == "### English" {
                language = "en"
            } else if line == "### 简体中文" {
                language = "zh-Hans"
            } else if version != nil, !language.isEmpty, let banner = Self.banner(line) {
                // A banner is shown above the notes, not read as one of them.
                if language == "en" { englishBanner = englishBanner ?? banner }
                if language == "zh-Hans" { chineseBanner = chineseBanner ?? banner }
            } else if version != nil {
                if language == "en" { english += line + "\n" }
                if language == "zh-Hans" { chinese += line + "\n" }
            }
        }
        try finish()
        self.entries = entries.sorted { $0.version > $1.version }
    }

    /// `![description](Resources/ReleaseBanners/name)`, the line `scripts/release_notes.py` writes.
    private static func banner(_ line: String) -> Banner? {
        let prefix = "](Resources/\(Banner.directory)/"
        let text = line.trimmingCharacters(in: .whitespaces)
        guard text.hasPrefix("!["), text.hasSuffix(")"), let middle = text.range(of: prefix) else { return nil }
        let description = text[text.index(text.startIndex, offsetBy: 2)..<middle.lowerBound]
        let fileName = text[middle.upperBound..<text.index(before: text.endIndex)]
        guard !description.contains("]"), !fileName.isEmpty,
              !fileName.contains(where: { $0 == "/" || $0 == ")" || $0.isWhitespace }) else { return nil }
        return Banner(fileName: String(fileName), description: String(description))
    }
}
