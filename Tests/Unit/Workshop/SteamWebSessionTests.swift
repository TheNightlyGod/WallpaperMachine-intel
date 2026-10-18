import XCTest
@testable import WallpaperMachine

/// Keeps the Steam Community session in memory in place of the keychain.
final class SteamWebMemorySessionStore: SteamWebSessionStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: SteamWebSession?
    var session: SteamWebSession? { lock.withLock { stored } }

    init(_ session: SteamWebSession? = nil) { stored = session }

    func load() -> SteamWebSession? { lock.withLock { stored } }
    func save(_ session: SteamWebSession) throws { lock.withLock { stored = session } }
    func remove() { lock.withLock { stored = nil } }
}

/// Synthetic Steam tokens: a JSON Web Token whose only claim that matters here is `exp`.
enum SteamWebFixtures {
    static let account = "76561198000000001"
    static let otherAccount = "76561198000000002"

    static func token(expiresIn seconds: TimeInterval, now: Date = Date(), salt: String = "a") -> String {
        let claims = #"{"sub":"\#(account)","exp":\#(Int(now.timeIntervalSince1970 + seconds)),"salt":"\#(salt)"}"#
        let payload = Data(claims.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "eyJhbGciOiJFZERTQSJ9.\(payload).c2lnbmF0dXJlLWZpeHR1cmU"
    }

    static func cookie(_ token: String, account: String = account) -> String { "\(account)%7C%7C\(token)" }
}

final class SteamWebSessionTests: XCTestCase {
    func testTheRenewalTokenIsKeptOnlyForTheSameAccount() throws {
        let access = SteamWebFixtures.token(expiresIn: 3600)
        let refresh = SteamWebFixtures.token(expiresIn: 200 * 86_400, salt: "r")
        let session = try XCTUnwrap(
            SteamWebSession(cookie: SteamWebFixtures.cookie(access), refresh: SteamWebFixtures.cookie(refresh)))
        XCTAssertEqual(session.steamID, SteamWebFixtures.account)
        XCTAssertEqual(session.refreshToken, refresh)

        let other = SteamWebSession(
            cookie: SteamWebFixtures.cookie(access),
            refresh: SteamWebFixtures.cookie(refresh, account: SteamWebFixtures.otherAccount))
        XCTAssertNil(other?.refreshToken, "another account's renewal token is not this session's")
        XCTAssertNil(SteamWebSession(cookie: SteamWebFixtures.cookie(access), refresh: "garbage")?.refreshToken)
    }

    func testAnExpiredCookieWithARenewalTokenNeedsRenewing() throws {
        let now = Date()
        let refresh = SteamWebFixtures.cookie(SteamWebFixtures.token(expiresIn: 86_400, salt: "r"))
        let fresh = try XCTUnwrap(
            SteamWebSession(cookie: SteamWebFixtures.cookie(SteamWebFixtures.token(expiresIn: 3600, now: now)), refresh: refresh))
        XCTAssertFalse(fresh.needsRenewal(at: now))
        XCTAssertTrue(fresh.needsRenewal(at: now.addingTimeInterval(3600)))

        let expired = try XCTUnwrap(
            SteamWebSession(cookie: SteamWebFixtures.cookie(SteamWebFixtures.token(expiresIn: -60, now: now)), refresh: refresh))
        XCTAssertTrue(expired.needsRenewal(at: now))
        let renewed = try XCTUnwrap(expired.renewed(accessToken: SteamWebFixtures.token(expiresIn: 3600, now: now, salt: "n")))
        XCTAssertEqual(renewed.steamID, expired.steamID)
        XCTAssertEqual(renewed.refreshToken, expired.refreshToken)
        XCTAssertFalse(renewed.needsRenewal(at: now))
        XCTAssertNil(expired.renewed(accessToken: "not a token"))

        // Without a renewal token, or a token that names no expiry, there is nothing to renew.
        let alone = try XCTUnwrap(
            SteamWebSession(cookie: SteamWebFixtures.cookie(SteamWebFixtures.token(expiresIn: -60, now: now))))
        XCTAssertFalse(alone.needsRenewal(at: now))
        let opaque = try XCTUnwrap(
            SteamWebSession(cookie: SteamWebFixtures.cookie("0123456789abcdef0123"), refresh: refresh))
        XCTAssertNil(opaque.expiresAt)
        XCTAssertFalse(opaque.needsRenewal(at: now))
    }
}
