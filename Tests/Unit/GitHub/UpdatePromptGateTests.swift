import XCTest

@testable import WallpaperMachine

/// When the unattended update alert may appear, and that a held alert is offered exactly once
/// after the hold lifts. Pure decisions: no window, display or network is involved.
final class UpdatePromptGateTests: XCTestCase {
    private func input(
        panel: Bool = false,
        presentation: GlobalPresentation = .running,
        coveredDisplay: Bool = false,
        whatsNew: Bool = false,
        shuttingDown: Bool = false
    ) -> UpdatePromptGate.Input {
        .init(
            panelVisibleAndActive: panel, globalPresentation: presentation,
            hasSuspendedDisplay: coveredDisplay, whatsNewOpen: whatsNew, shuttingDown: shuttingDown)
    }

    // MARK: Decision table

    func testRunningWallpapersWithNothingCoveredPresent() {
        XCTAssertEqual(UpdatePromptGate.decide(input()), .present)
    }

    func testSleepLockAppRuleAndFocusSuspensionsHold() {
        XCTAssertEqual(UpdatePromptGate.decide(input(presentation: .suspended)), .hold(.presentationSuspended))
        XCTAssertEqual(UpdatePromptGate.decide(input(presentation: .unloaded)), .hold(.presentationSuspended))
    }

    func testDisplayHiddenByAFullScreenAppHolds() {
        XCTAssertEqual(UpdatePromptGate.decide(input(coveredDisplay: true)), .hold(.displayCovered))
    }

    func testPanelInFrontPresentsEvenWhileWallpapersAreSuspended() {
        XCTAssertEqual(UpdatePromptGate.decide(input(panel: true, presentation: .suspended)), .present)
        XCTAssertEqual(UpdatePromptGate.decide(input(panel: true, presentation: .unloaded)), .present)
        XCTAssertEqual(UpdatePromptGate.decide(input(panel: true, coveredDisplay: true)), .present)
    }

    func testWhatsNewOpenAndShuttingDownHoldEvenWithThePanelInFront() {
        XCTAssertEqual(UpdatePromptGate.decide(input(panel: true, whatsNew: true)), .hold(.whatsNewOpen))
        XCTAssertEqual(UpdatePromptGate.decide(input(panel: true, shuttingDown: true)), .hold(.shuttingDown))
        XCTAssertEqual(
            UpdatePromptGate.decide(input(whatsNew: true, shuttingDown: true)), .hold(.shuttingDown),
            "a quit outranks everything, so the reason logged is the one that can never lift")
    }

    func testNoCombinationPresentsOverWhatsNewShutdownOrASuspendedScreen() {
        let presentations: [GlobalPresentation] = [.running, .suspended, .unloaded]
        for panel in [false, true] {
            for presentation in presentations {
                for covered in [false, true] {
                    for whatsNew in [false, true] {
                        for shuttingDown in [false, true] {
                            let given = input(
                                panel: panel, presentation: presentation, coveredDisplay: covered,
                                whatsNew: whatsNew, shuttingDown: shuttingDown)
                            guard UpdatePromptGate.decide(given) == .present else { continue }
                            XCTAssertFalse(whatsNew || shuttingDown, "\(given)")
                            XCTAssertTrue(
                                panel || (presentation == .running && !covered),
                                "an alert appeared with wallpapers suspended and the panel not in front: \(given)")
                        }
                    }
                }
            }
        }
    }

    // MARK: Offering a held prompt

    func testAHeldPromptIsOfferedOnceWhenPresentationResumes() {
        var ledger = UpdatePromptLedger()
        let asleep = input(presentation: .suspended)

        XCTAssertEqual(
            ledger.offer(version: "1.4.0", input: asleep), .held(.presentationSuspended, isNew: true))
        XCTAssertNil(ledger.offeredVersion, "a held version has not been offered")

        XCTAssertEqual(ledger.offer(version: "1.4.0", input: input()), .present(version: "1.4.0"))
        XCTAssertNil(ledger.holdReason)
        XCTAssertEqual(ledger.offeredVersion, "1.4.0")

        // Later is a decision for the launch: neither another check nor a later resume asks again.
        XCTAssertEqual(ledger.offer(version: "1.4.0", input: input()), .none)
        XCTAssertEqual(ledger.offer(version: "1.4.0", input: asleep), .none)
        XCTAssertNil(ledger.holdReason)
    }

    func testANewerVersionIsOfferedAfterAnEarlierOneWasDismissed() {
        var ledger = UpdatePromptLedger()
        XCTAssertEqual(ledger.offer(version: "1.4.0", input: input()), .present(version: "1.4.0"))
        XCTAssertEqual(ledger.offer(version: "1.4.1", input: input()), .present(version: "1.4.1"))
    }

    func testRepeatedRetriesReportAHoldOnlyWhenItsReasonChanges() {
        var ledger = UpdatePromptLedger()
        let asleep = input(presentation: .suspended)
        XCTAssertEqual(ledger.offer(version: "1.4.0", input: asleep), .held(.presentationSuspended, isNew: true))
        XCTAssertEqual(ledger.offer(version: "1.4.0", input: asleep), .held(.presentationSuspended, isNew: false))
        XCTAssertEqual(
            ledger.offer(version: "1.4.0", input: input(coveredDisplay: true)), .held(.displayCovered, isNew: true))
        XCTAssertEqual(ledger.holdReason, .displayCovered)
    }

    func testFullScreenAppHoldsUntilTheDisplayShowsAgain() {
        var ledger = UpdatePromptLedger()
        XCTAssertEqual(
            ledger.offer(version: "2.0.0", input: input(coveredDisplay: true)), .held(.displayCovered, isNew: true))
        XCTAssertEqual(ledger.offer(version: "2.0.0", input: input()), .present(version: "2.0.0"))
    }

    func testOpeningThePanelReleasesAHeldPrompt() {
        var ledger = UpdatePromptLedger()
        _ = ledger.offer(version: "2.0.0", input: input(presentation: .suspended))
        XCTAssertEqual(
            ledger.offer(version: "2.0.0", input: input(panel: true, presentation: .suspended)),
            .present(version: "2.0.0"))
    }

    func testWhatsNewClosingReleasesAHeldPrompt() {
        var ledger = UpdatePromptLedger()
        XCTAssertEqual(
            ledger.offer(version: "2.0.0", input: input(whatsNew: true)), .held(.whatsNewOpen, isNew: true))
        XCTAssertEqual(ledger.offer(version: "2.0.0", input: input()), .present(version: "2.0.0"))
    }

    func testAnUpdateThatDisappearedWhileHeldIsForgotten() {
        var ledger = UpdatePromptLedger()
        _ = ledger.offer(version: "2.0.0", input: input(presentation: .suspended))
        XCTAssertEqual(ledger.offer(version: nil, input: input()), .none)
        XCTAssertNil(ledger.holdReason)
        XCTAssertNil(ledger.offeredVersion)
    }

    func testAPromptHeldDuringShutdownIsNeverOffered() {
        var ledger = UpdatePromptLedger()
        XCTAssertEqual(
            ledger.offer(version: "2.0.0", input: input(shuttingDown: true)), .held(.shuttingDown, isNew: true))
        XCTAssertNil(ledger.offeredVersion)
    }
}
