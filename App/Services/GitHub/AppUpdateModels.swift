import Foundation

enum AppUpdateConfiguration {
    static let repository = "WallpaperMachine/WallpaperMachine"
    static let bundleIdentifier = "app.wallpapermachine"
    static let productName = "WallpaperMachine"
    static let applicationName = productName + ".app"
    static let maximumDownloadBytes: Int64 = 1_073_741_824

    /// The drag-to-install disk image `scripts/package.py` produces and the Build workflow
    /// publishes. Renaming the product moves both sides of this contract at once.
    static func assetName(for version: SemanticVersion) -> String {
#if arch(x86_64)
        "\(productName)-\(version.display)-x86_64.dmg"
#else
        "\(productName)-\(version.display)-arm64.dmg"
#endif
    }

    static var repositoryURL: URL {
        URL(string: "https://github.com/\(repository)")!
    }

    static var releasesURL: URL {
        URL(string: "https://github.com/\(repository)/releases")!
    }

    static var latestReleaseURL: URL {
        URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    }

    /// The update manifest `scripts/update_manifest.py` writes and the Build workflow attaches
    /// to every release: the release object in the REST API's shape, so one parser reads both.
    /// Renaming it moves both sides of this contract at once.
    static let manifestName = productName + "-update.json"

    /// github.com redirects this to the asset of the release marked Latest; drafts never
    /// resolve. Not an API request, so the anonymous API limit does not apply.
    static var latestManifestURL: URL {
        URL(string: "https://github.com/\(repository)/releases/latest/download/\(manifestName)")!
    }
}

enum AppUpdateErrorCode: String, Equatable, Sendable {
    case network, rateLimited, configuration, verification, permission, unknown
}

enum AppUpdateOperation: String, Equatable, Sendable {
    case check, download, install
}

struct SemanticVersion: Comparable, Equatable, Sendable {
    let major: Int
    let minor: Int
    let patch: Int

    init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.hasPrefix("v") || trimmed.hasPrefix("V") ? String(trimmed.dropFirst()) : trimmed
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts.allSatisfy({ $0.allSatisfy(\.isNumber) && ($0 == "0" || !$0.hasPrefix("0")) }),
              let major = Int(parts[0]), major >= 0,
              let minor = Int(parts[1]), minor >= 0,
              let patch = Int(parts[2]), patch >= 0
        else { return nil }
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    var display: String { "\(major).\(minor).\(patch)" }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

struct GitHubReleaseAsset: Equatable, Sendable {
    let name: String
    let downloadURL: URL
    let size: Int64
    let digest: String?
    var isDiskImage: Bool { name.lowercased().hasSuffix(".dmg") }
}

struct GitHubRelease: Equatable, Sendable {
    let version: SemanticVersion
    let htmlURL: URL
    let prerelease: Bool
    let assets: [GitHubReleaseAsset]
    /// The release body as GitHub published it, Markdown and all.
    let notes: String

    init(version: SemanticVersion, htmlURL: URL, prerelease: Bool, assets: [GitHubReleaseAsset], notes: String = "") {
        self.version = version
        self.htmlURL = htmlURL
        self.prerelease = prerelease
        self.assets = assets
        self.notes = notes
    }
}

/// What a release body says, reduced to the headings and lines a panel can show.
///
/// `scripts/release_notes.py` writes the body from the commits between two tags and
/// ends the part meant for the app with ``boundary``; everything after it is download
/// instructions the updater already performs. A hand-written body still parses: any
/// heading starts a section and any other line becomes one of its lines.
struct ReleaseNotes: Equatable, Sendable {
    struct Section: Equatable, Sendable {
        let title: String
        let items: [String]
        /// Bullet items, as opposed to a paragraph such as a release's summary.
        var isList = false

        /// Feature-release highlights keep their emphasis in every notes translation.
        var isHighlights: Bool { title == "Highlights" || title == "亮点" || title == "주요 변경 사항" }
    }

    static let boundary = "<!-- release-notes-end -->"

    let version: String
    let sections: [Section]

    init?(version: String, body: String) {
        let sections = Self.parse(body)
        guard !sections.isEmpty else { return nil }
        self.version = version
        self.sections = sections
    }

    static func parse(_ body: String) -> [Section] {
        let text = body.components(separatedBy: boundary).first ?? body
        var sections: [Section] = []
        var title = ""
        var items: [String] = []
        var bullets = false
        func flush(into next: String) {
            if !items.isEmpty { sections.append(Section(title: title, items: items, isList: bullets)) }
            title = next
            items = []
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("#") {
                flush(into: plain(trimmed.drop(while: { $0 == "#" })))
                continue
            }
            // The compare link is the page's navigation, not something to read here.
            if trimmed.hasPrefix("**Full changelog**") { continue }
            // A banner picture is shown, not read: its description is not a change.
            if trimmed.hasPrefix("![") { continue }
            let isBullet = trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ")
            // A paragraph after a list closes it; it is a remark, not another entry.
            if !items.isEmpty, isBullet != bullets { flush(into: "") }
            bullets = isBullet
            let item = plain(isBullet ? trimmed.dropFirst(2) : trimmed[...])
            if !item.isEmpty { items.append(item) }
        }
        flush(into: "")
        return sections
    }

    /// Markdown reduced to the words: the trailing commit reference goes, links keep
    /// their text, emphasis and code fences lose their markers.
    private static func plain(_ value: Substring) -> String {
        var text = String(value).trimmingCharacters(in: .whitespaces)
        for pattern in [#"\s*\(\[`[0-9a-f]{7,40}`\]\([^)]*\)\)$"#, #"\s*\(`[0-9a-f]{7,40}`\)$"#] {
            text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        text = text.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\*{1,2}([^*]+)\*{1,2}"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: "`", with: "")
        return text.trimmingCharacters(in: .whitespaces)
    }
}

enum AppUpdateState: Equatable, Sendable {
    case unsupported(currentVersion: String)
    case idle(currentVersion: String)
    case checking(currentVersion: String)
    case noRelease(currentVersion: String)
    case upToDate(currentVersion: String)
    case available(currentVersion: String, availableVersion: String)
    case manual(currentVersion: String, availableVersion: String)
    case downloading(currentVersion: String, availableVersion: String, percent: Double, transferred: Int64, total: Int64, bytesPerSecond: Int64)
    case ready(currentVersion: String, availableVersion: String)
    case preparing(currentVersion: String, availableVersion: String)
    case error(currentVersion: String, operation: AppUpdateOperation, code: AppUpdateErrorCode, availableVersion: String?)

    var currentVersion: String {
        switch self {
        case .unsupported(let version), .idle(let version), .checking(let version), .noRelease(let version),
             .upToDate(let version), .available(let version, _), .manual(let version, _),
             .downloading(let version, _, _, _, _, _), .ready(let version, _), .preparing(let version, _), .error(let version, _, _, _):
            return version
        }
    }

    var availableVersion: String? {
        switch self {
        case .available(_, let version), .manual(_, let version), .downloading(_, let version, _, _, _, _),
             .ready(_, let version), .preparing(_, let version):
            return version
        case .error(_, _, _, let version):
            return version
        case .unsupported, .idle, .checking, .noRelease, .upToDate:
            return nil
        }
    }

    var isBusy: Bool {
        switch self {
        case .checking, .downloading, .preparing: true
        default: false
        }
    }
}

struct AppUpdateIssue: Error, Equatable {
    let code: AppUpdateErrorCode
    let detail: String
    /// When GitHub accepts anonymous API requests again; set only for `.rateLimited`.
    var retryAfter: Date? = nil
}

enum AppUpdateProgress {
    static func clamped(transferred: Int64, total: Int64, rate: Int64) -> (percent: Double, transferred: Int64, total: Int64, rate: Int64) {
        let boundedTotal = max(0, total)
        let boundedTransferred = boundedTotal > 0 ? min(max(0, transferred), boundedTotal) : max(0, transferred)
        let rawPercent = boundedTotal > 0 ? Double(boundedTransferred) / Double(boundedTotal) * 100 : 0
        let percent = (min(100, max(0, rawPercent)) * 10).rounded() / 10
        return (percent, boundedTransferred, boundedTotal, max(0, rate))
    }
}

enum AppUpdateErrorClassifier {
    static func classify(_ error: Error) -> AppUpdateErrorCode {
        if let issue = error as? AppUpdateIssue { return issue.code }
        if error is CancellationError { return .unknown }
        let message = error.localizedDescription
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled: return .unknown
            case .userAuthenticationRequired, .noPermissionsToReadFile: return .permission
            default: return .network
            }
        }
        if posixPermission(error) { return .permission }
        if message.range(of: #"sha-?256|sha-?512|checksum|digest|signature|could not be verified|disk image|archive"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return .verification
        }
        if message.range(of: #"eacces|eperm|permission|not permitted|access denied"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return .permission
        }
        if message.range(of: #"release metadata|no published|feed url|configuration unavailable|no downloadable"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return .configuration
        }
        if message.range(of: #"enotfound|econn|etimedout|network|net::|socket|timeout|http(?:s)? request|status code"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return .network
        }
        return .unknown
    }

    private static func posixPermission(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == NSPOSIXErrorDomain else { return false }
        return nsError.code == Int(EACCES) || nsError.code == Int(EPERM)
    }
}

enum GitHubReleaseParser {
    static func decode(_ data: Data) throws -> GitHubRelease {
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw AppUpdateIssue(code: .configuration, detail: String(localized: "GitHub did not return a successful update response."))
        }
        guard !payload.prerelease,
              let version = SemanticVersion(payload.tagName),
              let htmlURL = URL(string: payload.htmlURL)
        else {
            throw AppUpdateIssue(code: .configuration, detail: String(localized: "GitHub did not return a successful update response."))
        }
        let assets = payload.assets.compactMap { asset -> GitHubReleaseAsset? in
            guard let url = URL(string: asset.browserDownloadURL) else { return nil }
            return GitHubReleaseAsset(name: asset.name, downloadURL: url, size: asset.size, digest: asset.digest)
        }
        return GitHubRelease(version: version, htmlURL: htmlURL, prerelease: payload.prerelease,
                             assets: assets, notes: payload.body ?? "")
    }

    /// The disk image to download: only product-named `.dmg` assets qualify, so the
    /// `.dmg.sha256` sidecar, zips, feeds and blockmaps never do, and a release without
    /// one is left to a manual download.
    static func selectAsset(from release: GitHubRelease) -> GitHubReleaseAsset? {
        let expected = AppUpdateConfiguration.assetName(for: release.version).lowercased()
        let candidates = release.assets.filter { asset in
            asset.isDiskImage && asset.name.lowercased().contains(AppUpdateConfiguration.productName.lowercased())
        }
        let archMatch: GitHubReleaseAsset?
        #if arch(x86_64)
        archMatch = candidates.first { $0.name.lowercased().contains("x86_64") }
        #else
        archMatch = candidates.first { $0.name.lowercased().contains("arm64") }
        #endif
        return candidates.first { $0.name.lowercased() == expected }
            ?? archMatch
            ?? candidates.first
    }

    private struct Payload: Decodable {
        let tagName: String
        let htmlURL: String
        let prerelease: Bool
        let assets: [Asset]
        let body: String?

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case prerelease, assets, body
        }

        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: String
            let size: Int64
            let digest: String?

            enum CodingKeys: String, CodingKey {
                case name, size, digest
                case browserDownloadURL = "browser_download_url"
            }
        }
    }
}
