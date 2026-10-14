import Foundation

/// Strips home paths, account names, credential values and the beta program
/// identifier of macOS resource reports before a diagnostics bundle is written.
///
/// Home paths are replaced before names. Doing it the other way turns
/// `/Users/alice/Library` into `/Users/<user>/Library`, and the home path no
/// longer matches. Credential values and Steam sign-in lines go first so a
/// password that happens to be the user name becomes `<redacted>` or
/// `<account>`, not `<user>`.
struct DiagnosticsRedactor {
    private let homeForms: [String]
    private let tokens: NSRegularExpression?
    private let tokenReplacements: [String: String]

    init(homeDirectory: String, userNames: [String], secrets: [String]) {
        homeForms = Self.homeForms(in: homeDirectory)
        let compiled = Self.tokens(userNames: userNames, secrets: secrets)
        tokens = compiled.expression
        tokenReplacements = compiled.replacements
    }

    func redact(_ text: String) -> String {
        var text = Self.replaceCredentials(in: text)
        text = Self.replaceSteamSignIn(in: text)
        text = Self.replaceBetaIdentifier(in: text)
        for home in homeForms {
            text = text.replacingOccurrences(of: home, with: "~")
        }
        guard let tokens else { return text }
        return replaceTokens(in: text, expression: tokens)
    }

    /// Longer prefixed forms first, so `/private/Users/alice` is not left as
    /// `/private~` after the bare home path is replaced.
    private static func homeForms(in homeDirectory: String) -> [String] {
        var home = homeDirectory
        while home.count > 1 && home.hasSuffix("/") {
            home.removeLast()
        }
        guard !home.isEmpty, home != "/" else { return [] }
        var forms = [home]
        if home.hasPrefix("/") {
            forms.append("/private" + home)
            forms.append("/System/Volumes/Data" + home)
        }
        return forms.sorted { $0.count > $1.count }
    }

    private static let credentialKeys = [
        "two_factor_code", "refresh_token", "access_token", "authorization",
        "steamguard", "sessionid", "auth_code", "password", "passwd",
        "cookie", "secret", "token",
    ]

    /// Quotes around the key are optional so a JSON field (`"password": "…"`)
    /// is covered as well as `password=…`. `token expired` has no separator
    /// and must not match.
    private static let credentialExpression: NSRegularExpression = {
        let keys = credentialKeys
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
        let pattern = #"(?<![A-Za-z0-9_])("?(?:\#(keys))"?)(\s*[=:])(\s*)(?:"[^"]*"|'[^']*'|\S+)"#
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    private static let steamSignInExpression: NSRegularExpression = {
        try! NSRegularExpression(pattern: #"Logging in user (['"])(.*?)\1"#, options: [])
    }()

    /// The `Beta Identifier:` line of a macOS resource report: a GUID that stays
    /// the same for every report from this install and says nothing about the
    /// problem.
    private static let betaIdentifierExpression: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"^([ \t]*Beta Identifier:[ \t]*)\S.*$"#,
            options: [.caseInsensitive, .anchorsMatchLines])
    }()

    private static func replaceCredentials(in text: String) -> String {
        let ns = text as NSString
        return credentialExpression.stringByReplacingMatches(
            in: text,
            range: NSRange(location: 0, length: ns.length),
            withTemplate: "$1$2$3<redacted>")
    }

    private static func replaceBetaIdentifier(in text: String) -> String {
        let ns = text as NSString
        return betaIdentifierExpression.stringByReplacingMatches(
            in: text,
            range: NSRange(location: 0, length: ns.length),
            withTemplate: "$1<redacted>")
    }

    private static func replaceSteamSignIn(in text: String) -> String {
        let ns = text as NSString
        return steamSignInExpression.stringByReplacingMatches(
            in: text,
            range: NSRange(location: 0, length: ns.length),
            withTemplate: "Logging in user $1<account>$1")
    }

    /// Secrets win when the same token is also a user name: an account name is
    /// the more sensitive of the two, and a later pass would otherwise rewrite
    /// `<account>` if `user` or `account` were themselves tokens.
    private static func tokens(userNames: [String], secrets: [String]) -> (expression: NSRegularExpression?, replacements: [String: String]) {
        struct Token {
            var original: String
            var pattern: String
            var replacement: String
        }
        var tokens: [Token] = []
        var seen = Set<String>()
        func add(_ values: [String], replacement: String) {
            for raw in values {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.count >= 2 else { continue }
                guard seen.insert(trimmed.lowercased()).inserted else { continue }
                tokens.append(Token(
                    original: trimmed,
                    pattern: NSRegularExpression.escapedPattern(for: trimmed),
                    replacement: replacement))
            }
        }
        add(secrets, replacement: "<account>")
        add(userNames, replacement: "<user>")
        guard !tokens.isEmpty else { return (nil, [:]) }
        tokens.sort { $0.original.count > $1.original.count }
        let alternation = tokens.map(\.pattern).joined(separator: "|")
        let pattern = "(?<![A-Za-z0-9_])(?:\(alternation))(?![A-Za-z0-9_])"
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return (nil, [:])
        }
        let replacements = Dictionary(uniqueKeysWithValues: tokens.map { ($0.original.lowercased(), $0.replacement) })
        return (expression, replacements)
    }

    private func replaceTokens(in text: String, expression: NSRegularExpression) -> String {
        let ns = text as NSString
        var result = ""
        var cursor = 0
        let full = NSRange(location: 0, length: ns.length)
        expression.enumerateMatches(in: text, range: full) { match, _, _ in
            guard let match, match.range.location != NSNotFound else { return }
            let span = match.range
            if span.location > cursor {
                result += ns.substring(with: NSRange(location: cursor, length: span.location - cursor))
            }
            let matched = ns.substring(with: span)
            result += tokenReplacements[matched.lowercased()] ?? matched
            cursor = span.location + span.length
        }
        if cursor < ns.length {
            result += ns.substring(from: cursor)
        }
        return result
    }
}
