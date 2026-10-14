import CoreServices
import XCTest

@testable import WallpaperMachine

/// The reason is chosen by a pure function, so every combination of what the system
/// told the app is exercised here. The Apple event codes are written out as text,
/// independently of the SDK constants the production table is built from.
final class QuitReasonTests: XCTestCase {
    private func code(_ text: String) -> UInt32 {
        text.utf8.reduce(0) { $0 << 8 | UInt32($1) }
    }

    private func classify(
        event: String? = nil, notified: Bool = false, update: Bool = false, signal: Int32? = nil
    ) -> QuitReason {
        QuitReason.classify(
            appleEventReason: event.map(code), powerOffNotified: notified,
            updateInstallPending: update, terminationSignal: signal)
    }

    // MARK: classify

    func testAQuitWithNothingElsePendingIsTheUsers() {
        XCTAssertEqual(classify(), .user)
        XCTAssertEqual(classify(event: "quia"), .user, "a plain quit-all event names no power-off")
    }

    func testEachPowerOffCodeNamesItsKind() {
        XCTAssertEqual(classify(event: "rlgo"), .logout)
        XCTAssertEqual(classify(event: "logo"), .logout)
        XCTAssertEqual(classify(event: "rest"), .restart)
        XCTAssertEqual(classify(event: "rrst"), .restart)
        XCTAssertEqual(classify(event: "shut"), .shutdown)
        XCTAssertEqual(classify(event: "rsdn"), .shutdown)
    }

    func testACodeThisBuildDoesNotKnowIsUnknownNotTheUsers() {
        XCTAssertEqual(classify(event: "zzzz"), .unknown)
        XCTAssertEqual(classify(event: "slep"), .unknown, "sleep is not a reason to quit")
    }

    func testAnUpdateWaitingForTheAppBeatsAPlainQuit() {
        XCTAssertEqual(classify(update: true), .update)
        XCTAssertEqual(classify(event: "quia", update: true), .update)
        XCTAssertEqual(classify(event: "zzzz", update: true), .update)
    }

    func testThePowerOffAnnouncementBeatsAPlainQuit() {
        XCTAssertEqual(classify(notified: true), .shutdown)
        XCTAssertEqual(classify(event: "quia", notified: true), .shutdown)
    }

    func testTheEventsOwnReasonBeatsTheAnnouncement() {
        XCTAssertEqual(classify(event: "rlgo", notified: true), .logout)
        XCTAssertEqual(classify(event: "rest", notified: true), .restart)
    }

    func testTheSystemLeavingBeatsAnUpdate() {
        XCTAssertEqual(classify(event: "rlgo", update: true), .logout)
        XCTAssertEqual(classify(notified: true, update: true), .shutdown)
    }

    func testASignalBeatsEverythingElse() {
        XCTAssertEqual(classify(signal: SIGTERM), .signal)
        XCTAssertEqual(classify(event: "rlgo", notified: true, update: true, signal: SIGHUP), .signal)
    }

    func testEveryReasonCanBeProduced() {
        let produced: Set<QuitReason> = [
            classify(), classify(update: true), classify(event: "rlgo"), classify(event: "rest"),
            classify(event: "shut"), classify(signal: SIGTERM), classify(event: "zzzz"),
        ]
        XCTAssertEqual(produced, Set(QuitReason.allCases))
    }

    func testTheProductionCodesAreTheOnesTheSDKDefines() {
        XCTAssertEqual(code("rlgo"), UInt32(kAEReallyLogOut))
        XCTAssertEqual(code("rest"), UInt32(kAERestart))
        XCTAssertEqual(code("shut"), UInt32(kAEShutDown))
        XCTAssertEqual(code("quia"), UInt32(kAEQuitAll))
        XCTAssertEqual(AEKeyword(kAEQuitReason), code("why?"))
    }

    // MARK: The mode a reason selects

    func testLogoutRestartAndShutdownAreThePowerOffQuits() {
        for event in ["rlgo", "rest", "shut"] {
            let reason = classify(event: event)
            XCTAssertTrue(reason.isPowerOff, event)
            XCTAssertEqual(QuitMode.resolve(reason: reason, powerOffNotified: false), .powerOff, event)
        }
        XCTAssertEqual(Set(QuitReason.allCases.filter(\.isPowerOff)), [.logout, .restart, .shutdown])
    }

    func testAUsersQuitAnUpdateAndAnUnknownReasonStayInteractive() {
        for reason in QuitReason.allCases where !reason.isPowerOff {
            XCTAssertEqual(QuitMode.resolve(reason: reason, powerOffNotified: false), .interactive, reason.rawValue)
        }
    }

    func testASignalDuringAnAnnouncedShutdownIsStillAPowerOffQuit() {
        let reason = classify(notified: true, signal: SIGTERM)

        XCTAssertEqual(reason, .signal, "the signal is the proximate cause")
        XCTAssertEqual(QuitMode.resolve(reason: reason, powerOffNotified: true), .powerOff,
                       "but it is the shutdown that is waiting for the app")
        XCTAssertEqual(QuitMode.resolve(reason: classify(signal: SIGTERM), powerOffNotified: false), .interactive)
    }

    func testTheAnnouncementAloneSelectsThePowerOffMode() {
        // The mode asks the announcement too, in case a reason is ever added that outranks it.
        XCTAssertEqual(QuitMode.resolve(reason: .user, powerOffNotified: true), .powerOff)
        XCTAssertEqual(QuitMode.resolve(reason: .update, powerOffNotified: true), .powerOff)
    }

    // MARK: What the session ledger keeps

    func testAQuitThatWentToPlanKeepsThePlainReason() {
        XCTAssertEqual(QuitReason.ledgerText(for: .logout, desktopUnrestored: false, stalled: []), "logout")
    }

    func testTheLedgerSaysWhatAQuitLeftUndone() {
        XCTAssertEqual(QuitReason.ledgerText(for: .logout, desktopUnrestored: true, stalled: []),
                       "logout; desktop restoration unfinished")
        XCTAssertEqual(QuitReason.ledgerText(for: .user, desktopUnrestored: false, stalled: ["steamcmd", "bridge"]),
                       "user; left running: steamcmd, bridge")
        XCTAssertEqual(QuitReason.ledgerText(for: .shutdown, desktopUnrestored: true, stalled: ["bridge"]),
                       "shutdown; desktop restoration unfinished; left running: bridge")
    }

    func testAQuitAskedForByASignalNamesTheSignalInTheLedger() {
        XCTAssertEqual(QuitReason.ledgerReason(for: .signal, signal: SIGTERM), "terminated by SIGTERM")
        XCTAssertEqual(QuitReason.ledgerReason(for: .signal, signal: SIGHUP), "terminated by SIGHUP")
        XCTAssertEqual(QuitReason.ledgerReason(for: .signal), "signal", "no signal is known: the plain reason")
        XCTAssertEqual(QuitReason.ledgerReason(for: .user, signal: SIGTERM), "user",
                       "only a quit classified as a signal's is named for one")
        XCTAssertEqual(
            QuitReason.ledgerText(for: .signal, signal: SIGTERM, desktopUnrestored: false, stalled: ["bridge"]),
            "terminated by SIGTERM; left running: bridge")
    }

    // MARK: The Apple event

    private func quitEvent() -> NSAppleEventDescriptor {
        NSAppleEventDescriptor.appleEvent(
            withEventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEQuitApplication),
            targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID))
    }

    func testTheReasonIsReadFromTheQuitEventsParameter() {
        let event = quitEvent()
        event.setParam(NSAppleEventDescriptor(enumCode: OSType(code("rlgo"))), forKeyword: code("why?"))

        XCTAssertEqual(QuitReason.appleEventReason(from: event), code("rlgo"))
        XCTAssertEqual(QuitReason.classify(
            appleEventReason: QuitReason.appleEventReason(from: event), powerOffNotified: false,
            updateInstallPending: false, terminationSignal: nil), .logout)
    }

    func testNoEventAndAnEventWithoutAReasonGiveNone() {
        XCTAssertNil(QuitReason.appleEventReason(from: nil))
        XCTAssertNil(QuitReason.appleEventReason(from: quitEvent()))
    }

    func testOnlyAnEnumeratedParameterCounts() {
        let event = quitEvent()
        event.setParam(NSAppleEventDescriptor(string: "rlgo"), forKeyword: code("why?"))
        XCTAssertNil(QuitReason.appleEventReason(from: event), "text is not an enumerator")

        event.setParam(NSAppleEventDescriptor(int32: Int32(bitPattern: code("rlgo"))), forKeyword: code("why?"))
        XCTAssertNil(QuitReason.appleEventReason(from: event), "an integer is not an enumerator")
    }

    func testAReasonSetAsAnAttributeIsNotTheReason() {
        // The SDK documents `why?` as a parameter; an attribute under the same keyword is something else.
        let event = quitEvent()
        event.setAttribute(NSAppleEventDescriptor(enumCode: OSType(code("rlgo"))), forKeyword: code("why?"))

        XCTAssertNil(QuitReason.appleEventReason(from: event))
    }

    func testACodeReadsAsItDoesInTheHeadersWhenItIsText() {
        XCTAssertEqual(QuitReason.text(forCode: code("rlgo")), "'rlgo'")
        XCTAssertEqual(QuitReason.text(forCode: 0x0000_0001), "0x00000001", "a code that is not text stays a number")
    }

    // MARK: The power-off announcement

    func testAnAnnouncementCountsOnlyForAWhile() {
        let start = ContinuousClock.now
        var notice = PowerOffNotice()
        XCTAssertFalse(notice.isCurrent(at: start), "nothing was announced")

        notice.record(at: start)
        XCTAssertTrue(notice.isCurrent(at: start.advanced(by: .seconds(5))))
        XCTAssertTrue(notice.isCurrent(at: start.advanced(by: PowerOffNotice.lifetime)))
        XCTAssertFalse(notice.isCurrent(at: start.advanced(by: PowerOffNotice.lifetime + .seconds(1))),
                       "a logout another app refused must not relabel a later Quit")
    }

    func testARefusedQuitForgetsTheAnnouncement() {
        let start = ContinuousClock.now
        var notice = PowerOffNotice()
        notice.record(at: start)
        notice.clear()

        XCTAssertFalse(notice.isCurrent(at: start))
    }

    func testANewerAnnouncementRestartsTheClock() {
        let start = ContinuousClock.now
        var notice = PowerOffNotice()
        notice.record(at: start)
        let later = start.advanced(by: PowerOffNotice.lifetime + .seconds(30))
        notice.record(at: later)

        XCTAssertTrue(notice.isCurrent(at: later.advanced(by: .seconds(10))))
    }
}
