import Foundation

/// Reads nettop's per-process CSV deltas. nettop's first row for a process carries every byte it
/// received since it launched, not since the sample began, so that row only anchors the timeline:
/// the rate and the running total are built from the rows that follow.
struct NetworkReceiveMeter {
    let processID: Int32
    /// Bytes received since the first sample; the transfer's own traffic, not the sign-in before it.
    private(set) var bytesReceived: Int64 = 0
    private var pending = ""
    private var byteColumn: Int?
    private var lastSample: TimeInterval?
    private var anchored = false
    private var intervals: [(bytes: Double, duration: TimeInterval)] = []
    private var currentRate: Double?

    init(processID: Int32) {
        self.processID = processID
    }

    mutating func append(_ data: Data, at time: TimeInterval) {
        guard time.isFinite else { return }
        pending += String(decoding: data, as: UTF8.self)
        guard pending.utf8.count <= 65_536 else {
            // Runaway output loses the rate window, never the bytes already counted.
            let total = bytesReceived
            let anchored = anchored
            self = NetworkReceiveMeter(processID: processID)
            bytesReceived = total
            self.anchored = anchored
            return
        }
        while let newline = pending.firstIndex(where: { $0.isNewline }) {
            let line = String(pending[..<newline]).trimmingCharacters(in: .whitespacesAndNewlines)
            pending.removeSubrange(...newline)
            guard !line.isEmpty else { continue }
            let fields = line.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            if fields.first == "" {
                byteColumn = fields.firstIndex(of: "bytes_in")
                continue
            }
            guard let column = byteColumn, fields.indices.contains(column),
                  fields.first?.hasSuffix(".\(processID)") == true,
                  !fields[column].isEmpty,
                  fields[column].allSatisfy({ $0.isASCII && $0.isNumber }),
                  let bytes = Int64(fields[column]) else { continue }
            let previous = lastSample
            lastSample = time
            guard anchored else {
                anchored = true
                continue
            }
            bytesReceived += bytes
            guard let previous, (0.5...2.5).contains(time - previous) else {
                intervals = []
                currentRate = nil
                continue
            }
            intervals.append((Double(bytes), time - previous))
            if intervals.count > 3 { intervals.removeFirst(intervals.count - 3) }
            currentRate = intervals.reduce(0) { $0 + $1.bytes } / intervals.reduce(0) { $0 + $1.duration }
        }
    }

    func rate(at time: TimeInterval) -> Double? {
        guard let lastSample, time.isFinite, (0...3).contains(time - lastSample) else { return nil }
        return currentRate
    }
}
