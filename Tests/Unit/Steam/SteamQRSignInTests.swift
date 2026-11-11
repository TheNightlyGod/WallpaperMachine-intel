import XCTest
@testable import WallpaperMachine

/// QR sign-in over Steam's authentication WebAPI, with Steam replaced by `FakeSteamWebAPI`.
final class SteamQRSignInTests: XCTestCase {
    private func challengeReply(clientID: UInt64 = 7, url: String = "https://s.team/q/1/7") -> SteamProto.Writer {
        var reply = SteamProto.Writer()
        reply.varint(1, clientID)
        reply.string(2, url)
        reply.bytes(3, Data([1, 2, 3, 4]))
        reply.fixed32(4, Float(5).bitPattern)
        return reply
    }

    func testBeginAsksForASteamClientTokenAndReturnsTheCode() async throws {
        let api = FakeSteamWebAPI()
        api.reply("BeginAuthSessionViaQR", challengeReply())
        let challenge = try await SteamQRSignIn(api: api).begin(deviceName: "Test Mac")

        XCTAssertEqual(challenge.url, "https://s.team/q/1/7")
        XCTAssertEqual(challenge.pollInterval, .seconds(5))
        let request = try XCTUnwrap(api.calls.first?.request)
        XCTAssertEqual(request.string(1), "Test Mac")
        XCTAssertEqual(request.varint(2), SteamQRSignIn.steamClientPlatform)
    }

    func testPollReportsScanRenewalAndApprovalInTurn() async throws {
        let api = FakeSteamWebAPI()
        api.reply("BeginAuthSessionViaQR", challengeReply())
        var scanned = SteamProto.Writer()
        scanned.bool(5, true)
        api.reply("PollAuthSessionStatus", SteamProto.Writer())
        api.reply("PollAuthSessionStatus", scanned)
        var renewed = SteamProto.Writer()
        renewed.varint(1, 8)
        renewed.string(2, "https://s.team/q/1/8")
        api.reply("PollAuthSessionStatus", renewed)
        var approved = SteamProto.Writer()
        approved.string(3, SteamTestToken.jwt(steamID: 76_561_198_000_000_042))
        approved.string(6, "someone")
        api.reply("PollAuthSessionStatus", approved)

        let signIn = SteamQRSignIn(api: api)
        var challenge = try await signIn.begin(deviceName: "Test Mac")
        let first = try await signIn.poll(challenge)
        XCTAssertEqual(first, .waiting(scanned: false))
        let second = try await signIn.poll(challenge)
        XCTAssertEqual(second, .waiting(scanned: true))
        guard case .renewed(let next) = try await signIn.poll(challenge) else { return XCTFail("expected a new code") }
        XCTAssertEqual(next.url, "https://s.team/q/1/8")
        challenge = next
        guard case .approved(let token) = try await signIn.poll(challenge) else { return XCTFail("expected approval") }
        XCTAssertEqual(token.accountName, "someone")
        XCTAssertEqual(token.steamID, 76_561_198_000_000_042)
        // The renewed client id is the one polled after the renewal.
        XCTAssertEqual(api.calls.last?.request.varint(1), 8)
    }

    func testATokenNotIssuedForTheSteamClientIsRefused() async throws {
        let api = FakeSteamWebAPI()
        api.reply("BeginAuthSessionViaQR", challengeReply())
        var approved = SteamProto.Writer()
        approved.string(3, SteamTestToken.jwt(audiences: ["web"]))
        api.reply("PollAuthSessionStatus", approved)
        let signIn = SteamQRSignIn(api: api)
        let challenge = try await signIn.begin(deviceName: "Test Mac")
        do {
            _ = try await signIn.poll(challenge)
            XCTFail("a web-only token cannot log on to a connection manager")
        } catch is SteamRefreshToken.Invalid {}
    }

    func testAnExpiredChallengeSurfacesSteamsAnswer() async throws {
        let api = FakeSteamWebAPI()
        api.reply("BeginAuthSessionViaQR", challengeReply())
        api.fail("PollAuthSessionStatus", eresult: 9)
        let signIn = SteamQRSignIn(api: api)
        let challenge = try await signIn.begin(deviceName: "Test Mac")
        do {
            _ = try await signIn.poll(challenge)
            XCTFail("expected Steam's refusal")
        } catch let error as SteamWebAPIError {
            XCTAssertEqual(error.eresult, 9)
        }
    }

    func testTokenClaimsAndExpiry() throws {
        let token = try SteamRefreshToken(SteamTestToken.jwt(expires: Date(timeIntervalSince1970: 2_000_000_000)),
                                          accountName: "someone")
        XCTAssertEqual(token.audiences, ["client", "web", "renew", "derive"])
        XCTAssertTrue(token.isExpired(at: Date(timeIntervalSince1970: 2_000_000_000)))
        XCTAssertFalse(token.isExpired(at: Date(timeIntervalSince1970: 1_999_999_999)))
        XCTAssertFalse(token.description.contains(token.value))
        XCTAssertThrowsError(try SteamRefreshToken("not-a-token", accountName: "x"))
    }
}
