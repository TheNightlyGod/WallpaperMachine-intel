import Foundation

/// The localized release history: the `CHANGELOG.md` sections the update manifest carries, so
/// the update window can show every version between the running one and the latest.
struct AppReleaseHistory {
    enum Language: Int, CaseIterable, Hashable, Sendable {
        case english, chinese, korean

        /// The changelog's language headings, in each language's own name.
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
    }

    struct Entry: Equatable, Sendable {
        let version: SemanticVersion
        let english: ReleaseNotes
        let chinese: ReleaseNotes
        var korean: ReleaseNotes? = nil
        /// The day it was published, as the heading writes it (`2026-10-24`).
        var date: String? = nil
        /// The heading's link: the comparison with the previous version.
        var url: URL? = nil

        func notes(language: Language) -> ReleaseNotes {
            switch language {
            case .english: english
            case .chinese: chinese
            case .korean: korean ?? english
            }
        }
    }

    enum InvalidHistory: Error {
        case invalidVersion, duplicateVersion, missingTranslation, invalidLanguageHeading
    }

    let entries: [Entry]

    init(markdown: String) throws {
        var entries: [Entry] = []
        var version: SemanticVersion?
        var heading: Heading?
        var bodies: [Language: String] = [:]
        var languages: [Language] = []
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
                                 date: heading?.date, url: heading?.url))
        }
        for line in markdown.components(separatedBy: .newlines) {
            if line.hasPrefix("## ") {
                try finish()
                // Every ## line is a release heading. Unreleased and headings inside
                // notes fail the whole file; release publishing rejects the same lines.
                guard let parsed = Heading(line) else { throw InvalidHistory.invalidVersion }
                version = parsed.version
                heading = parsed
                bodies = [:]
                languages = []
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
                // A banner line is skipped by `ReleaseNotes`: it is a picture, not a change.
                bodies[language, default: ""] += line + "\n"
            }
        }
        try finish()
        self.entries = entries.sorted { $0.version > $1.version }
    }

    /// `## [1.6.2](https://…/compare/v1.6.1...v1.6.2) (2026-10-24)`, the heading
    /// `scripts/release_notes.py` writes, or the older `## 1.6.2 — 2026-10-24`.
    private struct Heading {
        let version: SemanticVersion
        let url: URL?
        let date: String?

        init?(_ line: String) {
            let rest = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
            let token: Substring
            var tail: Substring
            if rest.hasPrefix("["), let close = rest.range(of: "]("),
               let end = rest[close.upperBound...].firstIndex(of: ")") {
                token = rest[rest.index(after: rest.startIndex)..<close.lowerBound]
                url = URL(string: String(rest[close.upperBound..<end]))
                tail = rest[rest.index(after: end)...]
            } else {
                token = rest.split(separator: " ").first ?? ""
                url = nil
                tail = rest.dropFirst(token.count)
            }
            guard let version = SemanticVersion(String(token)) else { return nil }
            self.version = version
            tail = tail.drop(while: { $0 == " " || $0 == "—" || $0 == "(" })
            let day = tail.prefix(while: { $0.isNumber || $0 == "-" })
            date = day.isEmpty ? nil : String(day)
        }
    }
}
