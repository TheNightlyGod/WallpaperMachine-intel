import Foundation

/// Classifies SteamCMD's parenthesized failures without treating an unknown reason as bad credentials.
/// Only the category is logged: terminal output can contain account names or secrets.
enum SteamCMDReportedFailure: String, Sendable {
    case cachedCredentials, steamGuard, connection, rateLimited, credentials, unknown

    init(reason: String, cachedCredentialsRejected: Bool = false, awaitingSteamGuard: Bool = false) {
        let key = String(reason.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) })
        func mentions(_ words: [String]) -> Bool { words.contains { key.contains($0) } }
        if cachedCredentialsRejected, key.contains("cachedcredential") {
            self = .cachedCredentials
        } else if mentions(["twofactor", "authcode", "steamguard"])
                    || (awaitingSteamGuard && mentions(["denied", "cancel"])) {
            self = .steamGuard
        } else if mentions(["timeout", "timedout", "connection", "connectfailed", "serviceunavailable"]) {
            self = .connection
        } else if mentions(["ratelimit", "toomany"]) {
            self = .rateLimited
        } else if mentions(["invalidpassword", "invalidlogin", "accountlogondenied"]) {
            self = .credentials
        } else {
            self = .unknown
        }
    }

    /// Whether trying the same request again can succeed without the user doing anything: a dropped
    /// or slow connection, as opposed to a sign-in Steam refused or a limit it set.
    var isTransient: Bool { self == .connection }

    var message: String {
        switch self {
        case .cachedCredentials:
            String(localized: "Your saved Steam sign-in has expired or was revoked. Try again and sign in to Steam.")
        case .steamGuard:
            String(localized: "Steam Guard was rejected, cancelled or expired. Try again, enter your password, then approve the new request or use a new code.")
        case .connection:
            String(localized: "Steam could not complete the connection or sign-in in time. Check your connection and any Steam Guard approval, then retry.")
        case .rateLimited:
            String(localized: "Steam has temporarily limited sign-in attempts. Wait before retrying.")
        case .credentials:
            String(localized: "Steam rejected the sign-in. Check your account login name and password, then retry.")
        case .unknown:
            String(localized: "SteamCMD could not complete the request. Check your connection and try again. If it keeps failing, export a diagnostics report from Settings.")
        }
    }
}
