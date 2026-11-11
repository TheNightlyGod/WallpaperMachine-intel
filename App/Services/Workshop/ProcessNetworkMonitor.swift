import Darwin
import Foundation

@MainActor
final class ProcessNetworkMonitor: ProcessNetworkMonitoring {
    private let runner: any SteamCMDProcessRunning
    private var capture: NetworkReceiveCapture?
    private var task: Task<Void, Never>?

    init(runner: any SteamCMDProcessRunning = NetworkTerminalRunner()) { self.runner = runner }

    func start(processID: Int32) {
        guard processID > 0, task == nil else { return }
        let capture = NetworkReceiveCapture(processID: processID)
        self.capture = capture
        let runner = runner
        task = Task {
            defer { capture.finish() }
            _ = try? await runner.run(
                executable: URL(fileURLWithPath: "/usr/bin/nettop"),
                arguments: ["-P", "-L", "0", "-p", String(processID), "-n", "-x", "-d", "-s", "1", "-J", "bytes_in"],
                workingDirectory: URL(fileURLWithPath: "/"),
                environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C"],
                onOutput: { capture.append($0) })
        }
    }

    func rate(at time: TimeInterval) -> Double? { capture?.rate(at: time) }

    func bytesReceived() -> Int64? { capture?.bytesReceived() }

    func stop() async {
        capture?.finish()
        capture = nil
        let current = task
        current?.cancel()
        await current?.value
        task = nil
    }
}

private final class NetworkReceiveCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var meter: NetworkReceiveMeter
    private var finished = false

    init(processID: Int32) { meter = NetworkReceiveMeter(processID: processID) }

    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        meter.append(data, at: ProcessInfo.processInfo.systemUptime)
    }

    func rate(at time: TimeInterval) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        return finished ? nil : meter.rate(at: time)
    }

    func bytesReceived() -> Int64? {
        lock.lock()
        defer { lock.unlock() }
        return finished ? nil : meter.bytesReceived
    }

    func finish() {
        lock.lock()
        defer { lock.unlock() }
        finished = true
    }
}

private struct NetworkTerminalRunner: SteamCMDProcessRunning {
    @MainActor
    func run(executable: URL, arguments: [String], workingDirectory: URL,
             environment: [String: String], onOutput: @escaping @Sendable (Data) -> Void) async throws -> Int32 {
        try Task.checkCancellation()
        var master: Int32 = -1
        var slave: Int32 = -1
        guard openpty(&master, &slave, nil, nil, nil) == 0 else { throw POSIXError(.EIO) }
        defer { close(master) }
        var settings = termios()
        if tcgetattr(slave, &settings) == 0 {
            settings.c_lflag &= ~tcflag_t(ECHO)
            tcsetattr(slave, TCSANOW, &settings)
        }
        let flags = fcntl(master, F_GETFL)
        guard flags >= 0, fcntl(master, F_SETFL, flags | O_NONBLOCK) != -1 else {
            close(slave)
            throw POSIXError(.EIO)
        }
        let process: SteamCMDTerminalProcess
        do {
            process = try SteamCMDTerminalProcess(
                executable: executable, arguments: arguments, workingDirectory: workingDirectory,
                environment: environment, master: master, slave: slave, claim: -1)
        } catch {
            close(slave)
            throw error
        }
        close(slave)

        var buffer = [UInt8](repeating: 0, count: 8192)
        func drain() throws {
            for _ in 0..<32 {
                let count = Darwin.read(master, &buffer, buffer.count)
                if count > 0 {
                    onOutput(Data(buffer[0..<count]))
                    continue
                }
                if count == 0 { return }
                switch errno {
                case EINTR: continue
                case EAGAIN, EIO: return
                default: throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
        }
        do {
            while process.isRunning {
                try Task.checkCancellation()
                try drain()
                try await Task.sleep(for: .milliseconds(40))
            }
            await process.stop()
            try drain()
            try Task.checkCancellation()
            return process.terminationStatus
        } catch {
            await process.stop()
            throw error
        }
    }
}
