import Foundation

/// Whether text can be translated from one language into another on this Mac.
enum OnDeviceTranslationAvailability: Equatable, Sendable {
    /// Both languages are downloaded: a translation runs now, with no prompt.
    case installed
    /// The pair is supported but a language still has to be downloaded, which asks the person.
    case downloadable
    case unsupported
}

/// Translates text on this Mac: the system's Translation framework (`SystemTranslation`), or a
/// fake in tests. Nothing here goes online except a language download the person approved.
@MainActor
protocol OnDeviceTranslating: AnyObject {
    func availability(from source: Locale.Language, to target: Locale.Language) async
        -> OnDeviceTranslationAvailability
    /// Translates `text`. Call it only for an `installed` pair: before macOS 26 a pair that is not
    /// downloaded would ask the person to download it in the middle of a search.
    func translate(_ text: String, from source: Locale.Language, to target: Locale.Language)
        async throws -> String
    /// Asks the person to download what `source` into `target` needs: the system's own prompt.
    /// Only an explicit choice of theirs calls it.
    func download(from source: Locale.Language, to target: Locale.Language) async throws
    /// What the panel's `.translationTask` lends sessions to (`TranslationTaskHost`).
    var sessionHost: TranslationSessionHost { get }
}
