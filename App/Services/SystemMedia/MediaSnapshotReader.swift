import Darwin
import Foundation

/// A bounded, cancellable one-shot read. The adapter's long-lived stream keeps its own pipe.
actor MediaSnapshotReader {
    enum Failure: Error {
        case outputTooLarge
        case timedOut
        case processExited(Int32)
        case readFailed(Int32)
    }

    private let timeout: TimeInterval
    private let outputLimit: Int

    init(timeout: TimeInterval = 3, outputLimit: Int = 8 * 1024 * 1024) {
        self.timeout = timeout
        self.outputLimit = outputLimit
    }

    func read(executable: URL, arguments: [String]) async throws -> Data {
        let read = Read(executable: executable, arguments: arguments, timeout: timeout, outputLimit: outputLimit)
        return try await read.value()
    }

    /// All process, pipe and completion state belongs to this serial queue. Nonblocking reads
    /// let the timeout and cancellation run even when a helper never closes stdout.
    private final class Read: @unchecked Sendable {
        private let queue = DispatchQueue(label: "app.wallpapermachine.media-snapshot", qos: .utility)
        private let executable: URL
        private let arguments: [String]
        private let timeout: TimeInterval
        private let outputLimit: Int
        private var continuation: CheckedContinuation<Data, Error>?
        private var process: Process?
        private var source: DispatchSourceRead?
        private var deadline: DispatchWorkItem?
        private var killDeadline: DispatchWorkItem?
        private var data = Data()
        private var cancelled = false
        private var exited = false
        private var endedOutput = false
        private var outcome: Result<Data, Error>?
        private var descriptor: Int32 = -1

        init(executable: URL, arguments: [String], timeout: TimeInterval, outputLimit: Int) {
            self.executable = executable
            self.arguments = arguments
            self.timeout = timeout
            self.outputLimit = outputLimit
        }

        func value() async throws -> Data {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    queue.async { self.start(continuation) }
                }
            } onCancel: {
                self.queue.async {
                    self.cancelled = true
                    if self.continuation != nil { self.finish(.failure(CancellationError())) }
                }
            }
        }

        private func start(_ continuation: CheckedContinuation<Data, Error>) {
            guard !cancelled else { continuation.resume(throwing: CancellationError()); return }
            self.continuation = continuation
            let pipe = Pipe()
            let handle = pipe.fileHandleForReading
            descriptor = handle.fileDescriptor
            let flags = fcntl(descriptor, F_GETFL)
            guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
                finish(.failure(Failure.readFailed(errno)))
                return
            }
            let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
            source.setEventHandler { [weak self] in self?.drain() }
            source.setCancelHandler { try? handle.close() }
            self.source = source
            source.resume()

            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = pipe.fileHandleForWriting
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { [weak self] finished in
                let status = finished.terminationStatus
                guard let self else { return }
                self.queue.async { self.didExit(status) }
            }
            self.process = process
            do { try process.run() }
            catch {
                self.process = nil
                finish(.failure(error))
                return
            }
            try? pipe.fileHandleForWriting.close()
            let deadline = DispatchWorkItem { [weak self] in self?.finish(.failure(Failure.timedOut)) }
            self.deadline = deadline
            queue.asyncAfter(deadline: .now() + timeout, execute: deadline)
        }

        private func drain() {
            guard outcome == nil, !endedOutput else { return }
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            while true {
                let count = Darwin.read(descriptor, &buffer, buffer.count)
                if count > 0 {
                    guard data.count <= outputLimit - count else {
                        finish(.failure(Failure.outputTooLarge)); return
                    }
                    data.append(contentsOf: buffer.prefix(count))
                } else if count == 0 {
                    endedOutput = true
                    source?.cancel()
                    if exited { finish(.success(data)) }
                    return
                } else if errno == EINTR {
                    continue
                } else if errno == EAGAIN || errno == EWOULDBLOCK {
                    return
                } else {
                    finish(.failure(Failure.readFailed(errno))); return
                }
            }
        }

        private func didExit(_ status: Int32) {
            exited = true
            if outcome != nil { complete(); return }
            guard status == 0 else { finish(.failure(Failure.processExited(status))); return }
            if endedOutput { finish(.success(data)) } else { drain() }
        }

        private func finish(_ result: Result<Data, Error>) {
            guard outcome == nil else { return }
            outcome = result
            deadline?.cancel()
            source?.cancel()
            guard let process, process.isRunning else { complete(); return }
            process.terminate()
            // A wedged native framework may ignore SIGTERM. Reap it before returning.
            let killDeadline = DispatchWorkItem { [weak self] in
                guard let process = self?.process, process.isRunning else { return }
                kill(process.processIdentifier, SIGKILL)
            }
            self.killDeadline = killDeadline
            queue.asyncAfter(deadline: .now() + 0.25, execute: killDeadline)
        }

        private func complete() {
            guard let outcome, let continuation else { return }
            self.continuation = nil
            killDeadline?.cancel()
            process?.terminationHandler = nil
            process = nil
            source?.cancel()
            source = nil
            data.removeAll()
            continuation.resume(with: outcome)
        }
    }
}
