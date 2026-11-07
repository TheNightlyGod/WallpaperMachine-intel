import XCTest
import Darwin
@testable import WallpaperMachine

final class MediaSnapshotReaderTests: XCTestCase {
    func testReadsCompleteFragmentedSnapshotAndWaitsForExit() async throws {
        let reader = MediaSnapshotReader()
        let data = try await reader.read(executable: URL(fileURLWithPath: "/usr/bin/perl"),
            arguments: ["-e", "$|=1; print '{\"title\":'; print '\"Second\"}';"])
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
        XCTAssertEqual(payload["title"], "Second")
    }

    func testExcessiveOutputIsRejectedInsteadOfBufferedWithoutBound() async {
        let reader = MediaSnapshotReader(outputLimit: 128)
        do {
            _ = try await reader.read(executable: URL(fileURLWithPath: "/usr/bin/perl"),
                arguments: ["-e", "print 'x' x 100000;"])
            XCTFail("oversized output must fail")
        } catch MediaSnapshotReader.Failure.outputTooLarge {
        } catch { XCTFail("unexpected error: \(error)") }
    }

    func testHungHelperTimesOutEvenWhenItIgnoresTermination() async {
        let reader = MediaSnapshotReader(timeout: 0.1)
        do {
            _ = try await reader.read(executable: URL(fileURLWithPath: "/usr/bin/perl"),
                arguments: ["-e", "$SIG{TERM}='IGNORE'; sleep 20;"])
            XCTFail("a silent helper must not block forever")
        } catch MediaSnapshotReader.Failure.timedOut {
        } catch { XCTFail("unexpected error: \(error)") }
    }

    func testCancellingAnAlreadyRunningHelperReapsItsProcess() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: marker) }
        let reader = MediaSnapshotReader(timeout: 5)
        let task = Task {
            try await reader.read(executable: URL(fileURLWithPath: "/usr/bin/perl"), arguments: ["-e",
                "$SIG{TERM}='IGNORE'; open(my $f, '>', $ARGV[0]) or die; print $f $$; close $f; sleep 20;", marker.path])
        }
        defer { task.cancel() }
        let deadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: marker.path), Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let pidText = try String(contentsOf: marker, encoding: .utf8)
        let pid = try XCTUnwrap(Int32(pidText))
        task.cancel()
        do { _ = try await task.value; XCTFail("cancelled helper returned data") }
        catch is CancellationError {} catch { XCTFail("unexpected error: \(error)") }
        let result = kill(pid, 0)
        let code = errno
        XCTAssertEqual(result, -1)
        XCTAssertEqual(code, ESRCH, "the cancelled helper must be reaped before its caller resumes")
    }

    func testCancellationAndNonzeroExitDoNotReturnPartialData() async {
        let reader = MediaSnapshotReader()
        let task = Task {
            try await reader.read(executable: URL(fileURLWithPath: "/usr/bin/perl"),
                arguments: ["-e", "sleep 20;"])
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("cancelled read succeeded") }
        catch is CancellationError {} catch { XCTFail("unexpected error: \(error)") }
        do {
            _ = try await reader.read(executable: URL(fileURLWithPath: "/usr/bin/perl"),
                arguments: ["-e", "print '{\"title\":\"Partial\"}'; exit 2;"])
            XCTFail("failed helper output must not replace metadata")
        } catch MediaSnapshotReader.Failure.processExited(let status) { XCTAssertEqual(status, 2) }
        catch { XCTFail("unexpected error: \(error)") }
    }
}
