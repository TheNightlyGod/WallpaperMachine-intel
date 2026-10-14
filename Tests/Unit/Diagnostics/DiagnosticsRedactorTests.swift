import XCTest

@testable import WallpaperMachine

final class DiagnosticsRedactorTests: XCTestCase {
    private func redactor(
        home: String = "/Users/alice",
        users: [String] = ["alice"],
        secrets: [String] = ["steamalice"]
    ) -> DiagnosticsRedactor {
        DiagnosticsRedactor(homeDirectory: home, userNames: users, secrets: secrets)
    }

    func testHomePathBecomesTildeIncludingPrivateAndDataVolumeForms() {
        let redact = redactor().redact
        XCTAssertEqual(redact("/Users/alice/Library"), "~/Library")
        XCTAssertEqual(redact("/private/Users/alice/Library"), "~/Library")
        XCTAssertEqual(redact("/System/Volumes/Data/Users/alice/Library"), "~/Library")
        XCTAssertEqual(redact("sees /Users/alice twice: /Users/alice/Library"), "sees ~ twice: ~/Library")
    }

    func testTrailingSlashOnHomeStillMatchesAndRootHomeIsIgnored() {
        XCTAssertEqual(
            redactor(home: "/Users/alice/").redact("/Users/alice/Library"),
            "~/Library")
        XCTAssertEqual(redactor(home: "/", users: []).redact("/Users/alice /"), "/Users/alice /")
        XCTAssertEqual(redactor(home: "", users: []).redact("/Users/alice"), "/Users/alice")
    }

    func testBareUserNameIsReplacedButNotInsideALongerWord() {
        let redact = redactor().redact
        XCTAssertEqual(redact("alice"), "<user>")
        XCTAssertEqual(redact("Alice"), "<user>")
        XCTAssertEqual(redact("(alice)"), "(<user>)")
        XCTAssertEqual(redact("malice"), "malice")
        XCTAssertEqual(redact("alice2"), "alice2")
        XCTAssertEqual(redact("alice_bob"), "alice_bob")
        XCTAssertEqual(redact("/Users/alice/Library and alice"), "~/Library and <user>")
    }

    func testShortAndDuplicateNamesAreSkippedAndSecretsWinTies() {
        let redact = DiagnosticsRedactor(
            homeDirectory: "",
            userNames: ["a", " alice ", "alice", "a.c"],
            secrets: ["alice", "x"]).redact
        XCTAssertEqual(redact("a alice a.c abc"), "a <account> <user> abc")
    }

    func testLongerTokenIsReplacedBeforeAShorterPrefix() {
        let redact = DiagnosticsRedactor(
            homeDirectory: "",
            userNames: ["alice", "alice-smith"],
            secrets: []).redact
        XCTAssertEqual(redact("alice-smith and alice"), "<user> and <user>")
    }

    func testSteamSignInAndCredentialValuesAreRedacted() {
        let redact = redactor().redact
        XCTAssertEqual(redact("Logging in user 'steamalice'"), "Logging in user '<account>'")
        XCTAssertEqual(redact("Logging in user \"steamalice\""), "Logging in user \"<account>\"")
        XCTAssertEqual(redact("password=hunter2"), "password=<redacted>")
        XCTAssertEqual(redact("password = hunter2"), "password = <redacted>")
        XCTAssertEqual(redact("Token: \"abc def\""), "Token: <redacted>")
        XCTAssertEqual(redact("password='secret value'"), "password=<redacted>")
        XCTAssertEqual(redact("\"password\": \"s3cret\""), "\"password\": <redacted>")
        XCTAssertEqual(redact("access_token=xyz"), "access_token=<redacted>")
        XCTAssertEqual(redact("mytoken=abc"), "mytoken=abc")
        XCTAssertEqual(redact("token expired"), "token expired")
        XCTAssertEqual(redact("password=alice"), "password=<redacted>")
    }

    func testBetaIdentifierValueIsRedacted() {
        let redact = redactor().redact
        XCTAssertEqual(
            redact("Is First Party:   No\nBeta Identifier:  A26873F6-7C45-588D-9E9C-CE7DAA8C4997\nResource Coalition: 3199"),
            "Is First Party:   No\nBeta Identifier:  <redacted>\nResource Coalition: 3199")
        XCTAssertEqual(redact("beta identifier: 1234"), "beta identifier: <redacted>")
        XCTAssertEqual(redact("Beta Identifier:"), "Beta Identifier:", "a line with no value has nothing to hide")
        XCTAssertEqual(
            redact("the Beta Identifier: field is removed"),
            "the Beta Identifier: field is removed",
            "only the report's own line, which starts it, is a value")
    }
}
