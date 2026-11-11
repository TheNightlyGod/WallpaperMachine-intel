import Foundation

/// What SteamCMD printed in the last runs that failed, so a diagnostics report shows why it
/// stopped, not only the step it stopped in. Each transcript is redacted when it is captured
/// (`redacted(_:account:)`): the account name, email addresses, Steam IDs and long tokens never
/// reach the disk, and passwords and Steam Guard codes are never printed, as the terminal does
/// not echo them. The file keeps the newest transcripts that fit in `maximumBytes`, stays
/// private to the user, and is redacted once more when a report is exported.
struct SteamCMDFailureLog {
    static let fileName = "SteamCMDFailures.log"
    static let maximumBytes = 64 * 1024
    /// Lines kept of one run, its last ones; a line is cut at `maximumLineLength`.
    static let maximumLines = 80
    static let maximumLineLength = 400
    private static let separator = "\n\n"

    let url: URL

    /// Adds one transcript, dropping the oldest whole transcripts beyond `maximumBytes`.
    func append(_ transcript: String) {
        var records = read().map { $0.components(separatedBy: Self.separator) } ?? []
        records.append(transcript.trimmingCharacters(in: .whitespacesAndNewlines))
        while records.count > 1, records.joined(separator: Self.separator).utf8.count > Self.maximumBytes {
            records.removeFirst()
        }
        var text = records.joined(separator: Self.separator) + "\n"
        if text.utf8.count > Self.maximumBytes { text = String(decoding: text.utf8.suffix(Self.maximumBytes), as: UTF8.self) }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            AppLog.warn("Could not keep the SteamCMD failure output: \(error.localizedDescription)")
        }
    }

    func read() -> String? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        return String(decoding: data.suffix(Self.maximumBytes), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let rules: [(NSRegularExpression, String)] = [
        // Terminal colour and cursor codes say nothing and break the redactions below.
        (#"\u001B\[[0-9;?]*[A-Za-z]"#, ""),
        (#"\u001B"#, ""),
        (#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, "<email>"),
        (#"\[U:[0-9]:[0-9]+\]"#, "[U:<steamid>]"),
        (#"(?<![0-9])7656119[0-9]{10}(?![0-9])"#, "<steamid>"),
        (#"(?<![A-Za-z0-9+_=-])[A-Za-z0-9+_=-]{32,}"#, "<token>"),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    /// One line of SteamCMD output as it may be kept: control characters gone, `account` (the
    /// login name signed in with) and identifying values replaced, and cut to a readable length.
    static func redacted(_ line: String, account: String) -> String {
        var text = String(line.unicodeScalars.filter { $0 == "\u{1B}" || !CharacterSet.controlCharacters.contains($0) || $0 == "\t" })
        let trimmed = account.trimmingCharacters(in: .whitespacesAndNewlines)
        // The name goes first: an email-address login must read <account>, not <email>.
        if trimmed.count >= 2 {
            text = text.replacingOccurrences(of: trimmed, with: "<account>", options: .caseInsensitive)
        }
        for (expression, template) in rules {
            text = expression.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
        }
        if text.count > maximumLineLength { text = String(text.prefix(maximumLineLength)) + "…" }
        return text
    }
}
