import Darwin
import Foundation

/// How much physical memory this process is charged for: the kernel's
/// `ri_phys_footprint`, the figure Activity Monitor shows as "Memory".
///
/// It counts what the kernel charges to the process: its heap, its compressed
/// pages and the graphics allocations it owns. It is per process, not per
/// wallpaper, so it cannot say which scene is the large one. The lock-screen
/// extension is a separate process and is not included.
enum ProcessFootprint {
    /// Bytes, or nil when the kernel does not answer. A failed read is never
    /// reported as zero, because a report that says "0 GB" would be believed.
    static func current(pid: pid_t = getpid()) -> UInt64? {
        var usage = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return status == 0 ? usage.ri_phys_footprint : nil
    }

    /// `3.2 GB` from one gigabyte up, whole megabytes below it (`512 MB`). Both use
    /// 1024-based units, like the memory size in the environment lines.
    static func formatBytes(_ bytes: UInt64) -> String {
        let megabytes = (Double(bytes) / 1_048_576).rounded()
        // Decided on the rounded figure, so 1023.9 MB reads `1.0 GB`, not `1024 MB`.
        guard megabytes >= 1024 else { return String(format: "%.0f MB", megabytes) }
        return String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
    }

    /// The figure as a log or report line states it; an unreadable one says so.
    static func describe(_ bytes: UInt64?) -> String {
        bytes.map(formatBytes) ?? "unknown"
    }

    /// The `environment.txt` line, read when the report is exported.
    static func reportLine(bytes: UInt64?, wallpaperWindows: Int) -> String {
        let windows = "\(wallpaperWindows) wallpaper window\(wallpaperWindows == 1 ? "" : "s")"
        guard let bytes else { return "process footprint unknown, \(windows)" }
        return "process footprint \(formatBytes(bytes)) (physical), \(windows)"
    }
}
