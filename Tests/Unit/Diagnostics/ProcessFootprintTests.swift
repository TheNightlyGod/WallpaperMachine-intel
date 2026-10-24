import Darwin
import XCTest

@testable import WallpaperMachine

/// The process footprint the log and the diagnostics report quote. The read is the
/// real `proc_pid_rusage` of the test host: it needs no window and no device.
final class ProcessFootprintTests: XCTestCase {
    private let megabyte: UInt64 = 1_048_576
    private let gigabyte: UInt64 = 1_073_741_824

    func testFormatBytes() {
        let cases: [(UInt64, String)] = [
            (0, "0 MB"),
            (512 * megabyte, "512 MB"),
            (1023 * megabyte + megabyte / 3, "1023 MB"),
            // Rounds up to a gigabyte rather than reading "1024 MB".
            (1023 * megabyte + megabyte * 2 / 3, "1.0 GB"),
            (gigabyte, "1.0 GB"),
            (gigabyte * 32 / 10, "3.2 GB"),
            (10 * gigabyte, "10.0 GB"),
        ]
        for (bytes, expected) in cases {
            XCTAssertEqual(ProcessFootprint.formatBytes(bytes), expected, "\(bytes) bytes")
        }
    }

    func testAnUnreadableFootprintIsDescribedAsUnknownNeverAsZero() {
        XCTAssertEqual(ProcessFootprint.describe(nil), "unknown")
        XCTAssertEqual(ProcessFootprint.describe(0), "0 MB")
        XCTAssertEqual(ProcessFootprint.describe(2 * gigabyte), "2.0 GB")
    }

    func testReportLineStatesTheFootprintAndTheWindowsItWasReadBesides() {
        XCTAssertEqual(
            ProcessFootprint.reportLine(bytes: 3 * gigabyte, wallpaperWindows: 6),
            "process footprint 3.0 GB (physical), 6 wallpaper windows")
        XCTAssertEqual(
            ProcessFootprint.reportLine(bytes: 3 * gigabyte, wallpaperWindows: 1),
            "process footprint 3.0 GB (physical), 1 wallpaper window")
        let unknown = ProcessFootprint.reportLine(bytes: nil, wallpaperWindows: 0)
        XCTAssertEqual(unknown, "process footprint unknown, 0 wallpaper windows")
    }

    func testCurrentFootprintIsPositiveForTheTestProcess() throws {
        let footprint = try XCTUnwrap(ProcessFootprint.current())
        // A hosted app with the whole renderer linked in is far above this.
        XCTAssertGreaterThan(footprint, 8 * megabyte)
    }

    func testCurrentFootprintFollowsMemoryTheProcessTouches() throws {
        // A heap allocation may reuse pages already charged to the process. A fresh
        // anonymous mapping starts untouched, so writing it creates a new charge.
        // Other host work can still return memory between reads; retain the bounded
        // three attempts and the same required growth margin.
        let size = Int(64 * megabyte)
        var readings: [(before: UInt64, after: UInt64)] = []
        for _ in 0..<3 {
            let block = try XCTUnwrap(
                mmap(nil, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0))
            guard block != MAP_FAILED else {
                XCTFail("Could not map fresh memory: errno \(errno)")
                return
            }
            defer { XCTAssertEqual(munmap(block, size), 0) }
            let before = try XCTUnwrap(ProcessFootprint.current())
            block.initializeMemory(as: UInt8.self, repeating: 0xA5, count: size)
            let after = try XCTUnwrap(ProcessFootprint.current())
            // Read back so the writes cannot be optimised away.
            XCTAssertEqual(block.load(fromByteOffset: size / 2, as: UInt8.self), 0xA5)
            readings.append((before, after))
            // Half of what was touched is a generous margin for other allocations
            // and for pages the system compresses at once.
            if after > before + 32 * megabyte { return }
        }
        XCTFail("the footprint never rose by 32 MB after touching 64 MB: \(readings)")
    }

    func testAProcessThatDoesNotExistHasNoFootprint() {
        XCTAssertNil(ProcessFootprint.current(pid: Int32.max))
    }
}
