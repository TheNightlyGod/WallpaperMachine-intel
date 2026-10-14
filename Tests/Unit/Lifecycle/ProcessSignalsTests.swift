import Darwin
import XCTest

@testable import WallpaperMachine

/// The test host already ran `WallpaperEngineApp.main`, which sets the guard, so each test
/// starts from the default action to see what `ignoreBrokenPipes` does by itself, and puts
/// back what the host had. A guard that failed to install is reported before any write is
/// made, so it costs one test and not the test host.
final class ProcessSignalsTests: XCTestCase {
    private var hostDisposition = sigaction()

    override func setUp() {
        super.setUp()
        sigaction(SIGPIPE, nil, &hostDisposition)
    }

    override func tearDown() {
        sigaction(SIGPIPE, &hostDisposition, nil)
        super.tearDown()
    }

    private let defaultAction = unsafeBitCast(SIG_DFL, to: Int.self)
    private let ignored = unsafeBitCast(SIG_IGN, to: Int.self)

    private func disposition() -> Int {
        var current = sigaction()
        sigaction(SIGPIPE, nil, &current)
        return unsafeBitCast(current.__sigaction_u.__sa_handler, to: Int.self)
    }

    private func isCaught() -> Bool {
        let current = disposition()
        return current != defaultAction && current != ignored
    }

    /// Writes one byte to a pipe nobody reads: the result of `write` and its `errno`.
    private func writeToBrokenPipe() -> (written: Int, code: Int32) {
        var ends: [Int32] = [-1, -1]
        XCTAssertEqual(pipe(&ends), 0)
        close(ends[0])
        defer { close(ends[1]) }
        var byte: UInt8 = 1
        let written = write(ends[1], &byte, 1)
        return (written, errno)
    }

    // MARK: A broken pipe is an error

    func testAWriteToABrokenPipeFailsWithEPIPEAndTheProcessSurvives() {
        signal(SIGPIPE, SIG_DFL)

        ProcessSignals.ignoreBrokenPipes()

        guard isCaught() else { return XCTFail("SIGPIPE would still end the process") }
        let result = writeToBrokenPipe()
        XCTAssertEqual(result.written, -1)
        XCTAssertEqual(result.code, EPIPE)
    }

    func testAFileHandleWriteThrowsTheBrokenPipeInsteadOfEndingTheProcess() throws {
        signal(SIGPIPE, SIG_DFL)
        ProcessSignals.ignoreBrokenPipes()
        guard isCaught() else { return XCTFail("SIGPIPE would still end the process") }

        // The import picker's handshake: the helper is gone, the parent writes to its stdin.
        let connection = Pipe()
        try connection.fileHandleForReading.close()

        XCTAssertThrowsError(try connection.fileHandleForWriting.write(contentsOf: Data([1]))) { error in
            let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
            XCTAssertEqual(underlying?.domain, NSPOSIXErrorDomain)
            XCTAssertEqual(underlying?.code, Int(EPIPE))
        }
    }

    // MARK: Calling it again, and a signal someone else already set

    func testCallingItTwiceKeepsOneWorkingGuard() {
        signal(SIGPIPE, SIG_DFL)

        ProcessSignals.ignoreBrokenPipes()
        let first = disposition()
        ProcessSignals.ignoreBrokenPipes()

        guard isCaught() else { return XCTFail("SIGPIPE would still end the process") }
        XCTAssertEqual(disposition(), first)
        XCTAssertEqual(writeToBrokenPipe().code, EPIPE)
    }

    func testASIGPIPEThatWasAlreadyIgnoredStaysIgnored() {
        signal(SIGPIPE, SIG_IGN)

        ProcessSignals.ignoreBrokenPipes()

        XCTAssertEqual(disposition(), ignored, "the launcher's choice already keeps the app alive")
    }

    func testAHandlerThatWasAlreadyInPlaceIsNotReplaced() {
        let theirs: @convention(c) (Int32) -> Void = { _ in }
        var action = sigaction()
        action.__sigaction_u.__sa_handler = theirs
        sigemptyset(&action.sa_mask)
        sigaction(SIGPIPE, &action, nil)
        let before = disposition()

        ProcessSignals.ignoreBrokenPipes()

        XCTAssertEqual(disposition(), before)
    }

    // MARK: What a child inherits

    func testAChildStartedAfterwardsGetsTheDefaultActionBack() throws {
        // The probe first: perl does report an ignore it inherited.
        signal(SIGPIPE, SIG_IGN)
        XCTAssertEqual(try ChildSignalProbe.perlDispositions(of: ["PIPE"]), "IGNORE",
                       "the probe can tell an ignore from a default")
        signal(SIGPIPE, SIG_DFL)

        ProcessSignals.ignoreBrokenPipes()

        guard isCaught() else { return XCTFail("SIGPIPE would still end the process") }
        XCTAssertEqual(try ChildSignalProbe.perlDispositions(of: ["PIPE"]), "DEFAULT",
                       "a caught handler resets across exec; an ignore would pass to SteamCMD")
    }
}
