import Foundation

/// The log lines a web wallpaper's own errors and warnings become, for one document.
///
/// The host script reports what the page writes with `console.error` and `console.warn`,
/// its uncaught errors and unhandled rejections, and elements that failed to load
/// (`WebWallpaperProtocol`). Everything in such a report is the page's and untrusted: an
/// unknown kind or a malformed payload is dropped, the text is put on one line and cut to
/// `maximumLength`, and after `maximumLines` a document is not logged again, so a page that
/// throws on every frame cannot fill the log. A new document starts a new count.
struct WebWallpaperPageDiagnostics {
    static let maximumLines = 40
    static let maximumLength = 300

    private(set) var logged = 0

    /// The level and line to log for one report, or nil when it is malformed or over the cap.
    mutating func line(project: String, payload: [String: Any]) -> (level: BridgeLogLevel, text: String)? {
        guard logged < Self.maximumLines,
              let kind = payload["kind"] as? String, let level = Self.levels[kind],
              let raw = payload["text"] as? String
        else { return nil }
        logged += 1
        // Counted in Unicode scalars, so one character stacked with combining marks cannot
        // carry a report past the limit: only what can reach the line is read.
        let head = String(String.UnicodeScalarView(raw.unicodeScalars.prefix(Self.maximumLength + 1)))
        var text = head.components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        if text.unicodeScalars.count > Self.maximumLength {
            text = String(String.UnicodeScalarView(text.unicodeScalars.prefix(Self.maximumLength))) + "…"
        }
        let last = logged == Self.maximumLines ? "; later page messages of this document are not logged" : ""
        return (level, "web wallpaper \(project): page \(kind): \(text)\(last)")
    }

    private static let levels: [String: BridgeLogLevel] = [
        "error": .warn, "uncaught": .warn, "rejection": .warn, "resource": .warn, "warning": .info,
    ]
}
