import Foundation

/// A Steam refresh token and the claims the app reads from it. The token stands in for the
/// password when the app logs on to Steam, so it is never logged or shown.
struct SteamRefreshToken: Sendable, Equatable, CustomStringConvertible {
    let value: String
    let accountName: String
    let steamID: UInt64
    let audiences: [String]
    let expiresAt: Date

    struct Invalid: LocalizedError {
        let reason: String
        var errorDescription: String? { "Steam returned an unusable sign-in token (\(reason))" }
    }

    /// Reads the claims without checking the signature: Steam checks the token when it is
    /// used, and the app only needs to know whose it is, what it is for and until when.
    init(_ value: String, accountName: String) throws {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { throw Invalid(reason: "not a JWT") }
        var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Invalid(reason: "unreadable claims")
        }
        guard let subject = claims["sub"] as? String, let steamID = UInt64(subject) else {
            throw Invalid(reason: "no SteamID")
        }
        guard let expiry = claims["exp"] as? Double else { throw Invalid(reason: "no expiry") }
        let audiences = (claims["aud"] as? [String]) ?? (claims["aud"] as? String).map { [$0] } ?? []
        // Only a token issued for the Steam client may log on to a connection manager.
        guard audiences.contains("client") else { throw Invalid(reason: "not issued for the Steam client") }
        self.value = value
        self.accountName = accountName
        self.steamID = steamID
        self.audiences = audiences
        self.expiresAt = Date(timeIntervalSince1970: expiry)
    }

    func isExpired(at date: Date = .now) -> Bool { date >= expiresAt }

    var description: String { "SteamRefreshToken(\(accountName), \(steamID), expires \(expiresAt))" }
}
