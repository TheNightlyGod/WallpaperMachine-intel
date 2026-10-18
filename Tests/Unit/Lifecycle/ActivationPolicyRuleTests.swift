import XCTest

@testable import WallpaperMachine

/// Every place that lowers the app to `.accessory` asks the same rule, so the windows a
/// person can still reach are described here as plain values, without opening any.
final class ActivationPolicyRuleTests: XCTestCase {
    private typealias Window = ActivationPolicyRule.Window

    private func window(
        _ role: Window.Role?, visible: Bool = false, minimized: Bool = false
    ) -> Window {
        Window(role: role, isVisible: visible, isMiniaturized: minimized)
    }

    private func keepsRegular(_ windows: [Window], quitting: Bool = false) -> Bool {
        ActivationPolicyRule.keepsRegular(windows, quitting: quitting)
    }

    func testWithNoWindowTheAppLeavesTheDock() {
        XCTAssertFalse(keepsRegular([]))
    }

    func testEachOrdinaryWindowCountsOnScreenOrInTheDock() {
        let roles: [Window.Role] = [.controlPanel, .whatsNew, .preview, .signIn]
        for role in roles {
            XCTAssertTrue(keepsRegular([window(role, visible: true)]), "\(role) on screen")
            XCTAssertTrue(keepsRegular([window(role, minimized: true)]), "\(role) minimized")
            XCTAssertFalse(keepsRegular([window(role)]), "\(role) ordered out")
        }
    }

    func testAMinimizedPanelKeepsTheDockIconWhenWhatsNewOrThePreviewCloses() {
        // The closed window is no longer one of the app's; the panel is in the Dock.
        let left = [window(.controlPanel, minimized: true), window(nil, visible: true)]
        XCTAssertTrue(keepsRegular(left))
    }

    func testASignInWindowKeepsTheDockIconAfterThePanelCloses() {
        XCTAssertTrue(keepsRegular([window(.signIn, visible: true)]))
        XCTAssertTrue(keepsRegular([window(nil, visible: true), window(.signIn, minimized: true)]))
    }

    func testAPanelAQuitPutAwayDoesNotCount() {
        XCTAssertFalse(keepsRegular([window(.controlPanel), window(.whatsNew)]))
        // Whatever AppKit still reports for a minimized one that was ordered out.
        let putAway = [window(.controlPanel, minimized: true), window(.whatsNew, visible: true)]
        XCTAssertFalse(keepsRegular(putAway, quitting: true))
        XCTAssertTrue(keepsRegular(putAway, quitting: false))
    }

    func testASignInWindowStillCountsDuringAQuit() {
        XCTAssertTrue(keepsRegular([window(.controlPanel), window(.signIn, visible: true)], quitting: true))
        XCTAssertTrue(keepsRegular([window(.preview, visible: true)], quitting: true))
    }

    func testAlertsPanelsAndWallpaperWindowsNeverCount() {
        // An alert or open panel is titled and visible; a wallpaper window is borderless and
        // on every Space. None of them is a window of the app's own.
        let others = [
            window(nil, visible: true), window(nil, minimized: true), window(nil, visible: true, minimized: true),
        ]
        XCTAssertFalse(keepsRegular(others))
        XCTAssertFalse(keepsRegular(others, quitting: true))
    }
}
