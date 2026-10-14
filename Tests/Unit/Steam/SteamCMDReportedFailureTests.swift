import XCTest

@testable import WallpaperMachine

final class SteamCMDReportedFailureTests: XCTestCase {
    func testNetworkAndRateLimitReasonsAreNotCredentialRejections() {
        for reason in ["Timeout", "Timed Out", "No Connection", "NoConnection", "ConnectFailed",
                       "Service Unavailable", "ServiceUnavailable"] {
            XCTAssertEqual(SteamCMDReportedFailure(reason: reason), .connection, reason)
        }
        for reason in ["Rate Limit Exceeded", "RateLimitExceeded", "Too many pending logins", "TooManyPending"] {
            XCTAssertEqual(SteamCMDReportedFailure(reason: reason), .rateLimited, reason)
        }
    }

    func testCredentialsRequireAnExplicitReasonAndGuardTakesPrecedence() {
        for reason in ["Invalid Password", "InvalidPassword", "Invalid login", "AccountLogonDenied"] {
            XCTAssertEqual(SteamCMDReportedFailure(reason: reason), .credentials, reason)
        }
        for reason in ["Account logon denied, need two-factor code", "InvalidLoginAuthCode", "Steam Guard expired"] {
            XCTAssertEqual(SteamCMDReportedFailure(reason: reason), .steamGuard, reason)
        }
        XCTAssertEqual(SteamCMDReportedFailure(reason: "Access Denied", awaitingSteamGuard: true), .steamGuard)
        XCTAssertEqual(SteamCMDReportedFailure(reason: "Cancelled", awaitingSteamGuard: true), .steamGuard)
        XCTAssertEqual(SteamCMDReportedFailure(reason: "Timeout", awaitingSteamGuard: true), .connection)
        XCTAssertEqual(
            SteamCMDReportedFailure(reason: "Cached credentials revoked", cachedCredentialsRejected: true),
            .cachedCredentials)
    }

    func testUnknownReasonsDoNotBlameCredentials() {
        for reason in ["", "Unexpected result", "Access Denied", "FutureSteamError", "private-account private-secret"] {
            XCTAssertEqual(SteamCMDReportedFailure(reason: reason), .unknown, reason)
        }
    }

    func testOnlyAConnectionFailureCanBeRetriedWithoutTheUser() {
        for reason in ["Timeout", "No Connection", "ServiceUnavailable"] {
            XCTAssertTrue(SteamCMDReportedFailure(reason: reason).isTransient, reason)
        }
        for reason in ["Invalid Password", "Steam Guard expired", "Rate Limit Exceeded", "Access Denied",
                       "Failure", ""] {
            XCTAssertFalse(SteamCMDReportedFailure(reason: reason).isTransient, reason)
        }
        XCTAssertFalse(
            SteamCMDReportedFailure(reason: "Cached credentials revoked", cachedCredentialsRejected: true)
                .isTransient)
    }
}
