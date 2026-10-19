import Foundation

/// The localized release history shipped with this copy, never the newest remote release.
struct AppReleaseHistory {
    enum Language: Int, CaseIterable, Hashable, Sendable {
        case english, chinese, korean

        /// Native language identifiers shared by the changelog and translation picker.
        var name: String {
            switch self {
            case .english: "English"
            case .chinese: "简体中文"
            case .korean: "한국어"
            }
        }

        init(appLanguage: AppLanguage) {
            if appLanguage.tag.hasPrefix("zh") {
                self = .chinese
            } else if appLanguage.tag == "ko" {
                self = .korean
            } else {
                self = .english
            }
        }

        /// Prefer English for a missing Korean banner, never another release's picture.
        var bannerFallbacks: [Self] {
            switch self {
            case .english: [.english, .chinese, .korean]
            case .chinese: [.chinese, .english, .korean]
            case .korean: [.korean, .english, .chinese]
            }
        }
    }

    struct Entry: Equatable, Sendable {
        let version: SemanticVersion
        let english: ReleaseNotes
        let chinese: ReleaseNotes
        var korean: ReleaseNotes? = nil
        /// The picture each translation opens with, if the release has one.
        var englishBanner: Banner? = nil
        var chineseBanner: Banner? = nil
        var koreanBanner: Banner? = nil

        func notes(language: Language) -> ReleaseNotes {
            switch language {
            case .english: english
            case .chinese: chinese
            case .korean: korean ?? english
            }
        }

        func banner(language: Language) -> Banner? {
            switch language {
            case .english: englishBanner
            case .chinese: chineseBanner
            case .korean: koreanBanner
            }
        }
    }

    /// A file in the bundle's `ReleaseBanners` folder, and what it shows.
    struct Banner: Equatable, Sendable {
        static let directory = "ReleaseBanners"
        let fileName: String
        let description: String
    }

    enum InvalidHistory: Error {
        case missingResource, invalidVersion, duplicateVersion, missingTranslation, invalidLanguageHeading
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
        var bodies: [Language: String] = [:]
        var languages: [Language] = []
        var banners: [Language: Banner] = [:]
        func finish() throws {
            guard let version else { return }
            guard !entries.contains(where: { $0.version == version }) else {
                throw InvalidHistory.duplicateVersion
            }
            guard let en = ReleaseNotes(version: version.display, body: bodies[.english] ?? ""),
                  let zh = ReleaseNotes(version: version.display, body: bodies[.chinese] ?? "") else {
                throw InvalidHistory.missingTranslation
            }
            let ko = ReleaseNotes(version: version.display, body: bodies[.korean] ?? "")
            // 1.5.7 introduced Korean notes; older tagged bilingual sections stay valid.
            let requiresKorean = (version.major, version.minor, version.patch) >= (1, 5, 7)
            if (requiresKorean || languages.contains(.korean)) && ko == nil {
                throw InvalidHistory.missingTranslation
            }
            entries.append(Entry(version: version, english: en, chinese: zh, korean: ko,
                                 englishBanner: banners[.english], chineseBanner: banners[.chinese],
                                 koreanBanner: banners[.korean]))
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
                bodies = [:]
                languages = []
                banners = [:]
            } else if version != nil, line.hasPrefix("###"), !line.hasPrefix("####") {
                let heading = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                guard languages.count < Language.allCases.count,
                      let next = Language.allCases.first(where: { $0.name == heading }),
                      next == Language.allCases[languages.count],
                      line.hasPrefix("### ") || line.hasPrefix("###\t") else {
                    throw InvalidHistory.invalidLanguageHeading
                }
                languages.append(next)
            } else if version != nil, let language = languages.last {
                if let banner = Self.banner(line) {
                    // A banner is shown above the notes, not read as one of them.
                    banners[language] = banners[language] ?? banner
                } else {
                    bodies[language, default: ""] += line + "\n"
                }
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
