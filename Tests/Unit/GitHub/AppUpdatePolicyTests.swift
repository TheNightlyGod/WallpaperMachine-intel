import XCTest
@testable import WallpaperMachine

final class AppUpdatePolicyTests: XCTestCase {
    func testMigrationPreservesOldChoicesAndOnlyFreshInstallDefaultsToAutomatic() {
        XCTAssertEqual(AppUpdateMode.migrate(saved: nil, legacy: nil, freshInstall: false), .notify)
        XCTAssertEqual(AppUpdateMode.migrate(saved: nil, legacy: nil, freshInstall: true), .automatic)
        XCTAssertEqual(AppUpdateMode.migrate(saved: nil, legacy: false, freshInstall: true), .notify)
        XCTAssertEqual(AppUpdateMode.migrate(saved: nil, legacy: true, freshInstall: false), .automatic)
        XCTAssertEqual(AppUpdateMode.migrate(saved: "download", legacy: true, freshInstall: false), .download)
        XCTAssertEqual(AppUpdateMode.migrate(saved: "invalid", legacy: nil, freshInstall: true), .notify)
    }

    func testInstallationRequiresEveryEligibilityCondition() {
        let allowed = AppUpdatePolicy.InstallInput(
            mode: .automatic, unattended: true, shuttingDown: false, onboardingComplete: true,
            canInstallInPlace: true, skipped: false, deferred: false, blocked: false)
        XCTAssertTrue(AppUpdatePolicy.mayInstall(allowed))
        var input = allowed
        input.unattended = false
        XCTAssertFalse(AppUpdatePolicy.mayInstall(input))
        input = allowed; input.mode = .download
        XCTAssertFalse(AppUpdatePolicy.mayInstall(input))
        input = allowed; input.deferred = true
        XCTAssertFalse(AppUpdatePolicy.mayInstall(input))
        input = allowed; input.skipped = true
        XCTAssertFalse(AppUpdatePolicy.mayInstall(input))
        input = allowed; input.blocked = true
        XCTAssertFalse(AppUpdatePolicy.mayInstall(input))
        input = allowed; input.shuttingDown = true
        XCTAssertFalse(AppUpdatePolicy.mayInstall(input))
        input = allowed; input.onboardingComplete = false
        XCTAssertFalse(AppUpdatePolicy.mayInstall(input))
        input = allowed; input.canInstallInPlace = false
        XCTAssertFalse(AppUpdatePolicy.mayInstall(input))
    }

    func testOperatingSystemVersionsAllowShortFormsButRejectMalformedOnes() {
        XCTAssertEqual(UpdateSystemVersion("15"), UpdateSystemVersion("15.0.0"))
        XCTAssertLessThan(UpdateSystemVersion("15.2")!, UpdateSystemVersion("15.2.1")!)
        for raw in ["", "15.beta", "-1", "15..0", "15.0.0.1"] {
            XCTAssertNil(UpdateSystemVersion(raw))
        }
    }

    func testCompatibilityDistinguishesLegacyMetadataFromKnownIncompatibility() throws {
        let version = try XCTUnwrap(SemanticVersion("2.0.0"))
        let legacy = GitHubRelease(version: version, htmlURL: AppUpdateConfiguration.releasesURL,
                                   prerelease: false, assets: [])
        XCTAssertTrue(AppUpdatePolicy.supports(legacy, systemVersion: "15.0", architecture: "arm64"))
        let newerOS = GitHubRelease(version: version, htmlURL: AppUpdateConfiguration.releasesURL,
            prerelease: false, assets: [], minimumSystemVersion: "16.0", architectures: ["arm64"],
            bundleIdentifier: AppUpdateConfiguration.bundleIdentifier)
        XCTAssertFalse(AppUpdatePolicy.supports(newerOS, systemVersion: "15.0", architecture: "arm64"))
        XCTAssertTrue(AppUpdatePolicy.supports(newerOS, systemVersion: "16", architecture: "arm64"))
        XCTAssertFalse(AppUpdatePolicy.supports(newerOS, systemVersion: "16", architecture: "x86_64"))
    }
}
