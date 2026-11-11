import CryptoKit
import Foundation

/// Valve's SteamCMD package manifest (`steam_cmd_osx`): the file SteamCMD's own bootstrapper
/// reads to update itself. Its packages carry the universal (arm64 and x86_64) runtime, so
/// installing them directly needs no Valve program to run before the result is validated, and
/// never needs the Intel-only bootstrap Valve still publishes as `steamcmd_osx.tar.gz`.
///
/// The grammar accepted is the subset Valve writes: quoted ASCII strings without escapes, braces,
/// and `//` comments. Anything else is refused rather than guessed at. The `kvsign*` blocks are
/// Valve's own signature over the manifest; their key is not published, so integrity rests on
/// HTTPS from Valve's host, each package's SHA-256 and SHA-1, and the code signatures validated
/// after extraction.
struct SteamCMDPackageManifest: Equatable, Sendable {
    struct Package: Equatable, Sendable {
        let name: String
        let file: String
        let size: Int64
        let sha256: String
        /// Valve names every package file after the SHA-1 of its bytes.
        let sha1: String
        var url: URL { SteamCMDPackageManifest.base.appendingPathComponent(file) }
    }

    static let base = URL(string: "https://steamcdn-a.akamaihd.net/client/")!
    static let url = base.appendingPathComponent("steam_cmd_osx")
    static let maximumSize: Int64 = 64 * 1024
    static let maximumTotalSize: Int64 = 256 * 1024 * 1024
    /// The executable and the libraries it loads; the others (Breakpad, localized bootstrapper
    /// text) are installed when listed, but a manifest without these cannot be a SteamCMD.
    static let requiredPackages = ["steamcmd_osx", "steamcmd_bins_osx"]

    let version: String
    let packages: [Package]
    var totalSize: Int64 { packages.reduce(0) { $0 + $1.size } }

    init(data: Data) throws {
        var index = 0
        let document = try Self.entries(try Self.tokens(data), from: &index, depth: 0)
        let roots = document.filter { $0.key == "osx" }
        guard roots.count == 1, case .block(let osx) = roots[0].value, Self.uniqueKeys(osx) else {
            throw Self.malformed()
        }
        var version: String?
        var packages: [Package] = []
        for entry in osx {
            switch entry.value {
            case .text(let text): if entry.key == "version" { version = text }
            case .block(let fields): packages.append(try Self.package(entry.key, fields))
            }
        }
        guard let version, (1...20).contains(version.count), version.allSatisfy({ $0.isASCII && $0.isNumber }),
              (1...16).contains(packages.count),
              Self.requiredPackages.allSatisfy({ name in packages.contains { $0.name == name } }) else {
            throw Self.malformed()
        }
        let (total, overflow) = packages.reduce((Int64(0), false)) { partial, package in
            let sum = partial.0.addingReportingOverflow(package.size)
            return (sum.partialValue, partial.1 || sum.overflow)
        }
        guard !overflow, total <= Self.maximumTotalSize else { throw Self.malformed() }
        self.version = version
        self.packages = packages
    }

    private indirect enum Value { case text(String), block([Entry]) }
    private struct Entry { let key: String; let value: Value }
    private enum Token: Equatable { case string(String), open, close }

    private static func package(_ name: String, _ fields: [Entry]) throws -> Package {
        guard (1...64).contains(name.count), name.allSatisfy(isLowerAlphanumeric), uniqueKeys(fields) else {
            throw malformed()
        }
        var text: [String: String] = [:]
        for field in fields { if case .text(let value) = field.value { text[field.key] = value } }
        let prefix = name + ".zip."
        guard let file = text["file"], file.hasPrefix(prefix),
              let sizeText = text["size"], (1...12).contains(sizeText.count),
              sizeText.allSatisfy({ $0.isASCII && $0.isNumber }), let size = Int64(sizeText),
              (1...maximumTotalSize).contains(size),
              let sha256 = text["sha2"]?.lowercased(), isHex(sha256, count: 64) else { throw malformed() }
        let sha1 = String(file.dropFirst(prefix.count)).lowercased()
        guard isHex(sha1, count: 40) else { throw malformed() }
        return Package(name: name, file: file, size: size, sha256: sha256, sha1: sha1)
    }

    private static func tokens(_ data: Data) throws -> [Token] {
        guard !data.isEmpty, Int64(data.count) <= maximumSize else { throw malformed() }
        let bytes = [UInt8](data)
        var tokens: [Token] = []
        var index = 0
        while index < bytes.count {
            switch bytes[index] {
            case 0x20, 0x09, 0x0a, 0x0d:
                index += 1
            case UInt8(ascii: "{"):
                tokens.append(.open)
                index += 1
            case UInt8(ascii: "}"):
                tokens.append(.close)
                index += 1
            case UInt8(ascii: "/") where index + 1 < bytes.count && bytes[index + 1] == UInt8(ascii: "/"):
                while index < bytes.count, bytes[index] != 0x0a { index += 1 }
            case UInt8(ascii: "\""):
                index += 1
                let start = index
                while index < bytes.count, bytes[index] != UInt8(ascii: "\"") {
                    // Escapes and control or non-ASCII bytes never occur in Valve's manifest.
                    guard (0x20..<0x7f).contains(bytes[index]), bytes[index] != UInt8(ascii: "\\") else {
                        throw malformed()
                    }
                    index += 1
                }
                guard index < bytes.count else { throw malformed() }
                tokens.append(.string(String(decoding: bytes[start..<index], as: UTF8.self)))
                index += 1
            default:
                throw malformed()
            }
            guard tokens.count <= 4096 else { throw malformed() }
        }
        return tokens
    }

    private static func entries(_ tokens: [Token], from index: inout Int, depth: Int) throws -> [Entry] {
        var entries: [Entry] = []
        while index < tokens.count {
            if tokens[index] == .close, depth > 0 { return entries }
            guard case .string(let key) = tokens[index], index + 1 < tokens.count else { throw malformed() }
            index += 1
            switch tokens[index] {
            case .string(let value):
                entries.append(Entry(key: key, value: .text(value)))
                index += 1
            case .open:
                guard depth < 4 else { throw malformed() }
                index += 1
                let children = try self.entries(tokens, from: &index, depth: depth + 1)
                guard index < tokens.count, tokens[index] == .close else { throw malformed() }
                index += 1
                entries.append(Entry(key: key, value: .block(children)))
            case .close:
                throw malformed()
            }
        }
        guard depth == 0 else { throw malformed() }
        return entries
    }

    private static func uniqueKeys(_ entries: [Entry]) -> Bool {
        Set(entries.map(\.key)).count == entries.count
    }

    private static func isLowerAlphanumeric(_ character: Character) -> Bool {
        character.isASCII && (character.isLowercase || character.isNumber || character == "_")
    }

    private static func isHex(_ text: String, count: Int) -> Bool {
        text.count == count && text.allSatisfy { $0.isASCII && $0.isHexDigit }
    }

    private static func malformed() -> SteamCMDSetupIssue {
        SteamCMDSetupIssue(kind: .invalidArchive, detail: String(localized: "Valve’s SteamCMD package manifest is malformed or incomplete. Try again later; nothing was installed."))
    }
}

/// Streams one file from Valve's HTTPS host to a private file in bounded chunks, never into
/// memory, hashing it as it arrives. Redirects may not leave the host or HTTPS.
final class SteamCMDDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct Digest: Equatable, Sendable {
        let sha256: String
        let sha1: String
    }

    private let source: URL
    private let destination: URL
    private let maximum: Int64
    private let expectedSize: Int64?
    private let configuration: URLSessionConfiguration
    private let timeout: TimeInterval?
    private let progress: @Sendable (Int64, Int64?) -> Void
    private let lock = NSLock()
    private var cancelled = false
    private var task: URLSessionDataTask?
    // Remaining state is confined to the serial delegate queue, established before task.resume().
    private var session: URLSession?
    private var continuation: CheckedContinuation<Digest, Error>?
    private var file: FileHandle?
    private var received: Int64 = 0
    private var expected: Int64?
    private var failure: Error?
    private var sha256 = SHA256()
    private var sha1 = Insecure.SHA1()

    /// `expectedSize` is the exact length the manifest promises; a response of any other length
    /// fails. Without it, `maximum` alone bounds the response.
    init(source: URL, destination: URL, maximum: Int64, expectedSize: Int64? = nil,
         configuration: URLSessionConfiguration, timeout: TimeInterval? = nil,
         progress: @escaping @Sendable (Int64, Int64?) -> Void = { _, _ in }) {
        self.timeout = timeout
        self.source = source
        self.destination = destination
        self.maximum = maximum
        self.expectedSize = expectedSize
        // NSCopying preserves this Foundation type; a private copy isolates caller-owned settings.
        // swiftlint:disable:next force_cast
        self.configuration = configuration.copy() as! URLSessionConfiguration
        self.progress = progress
    }

    func start() async throws -> Digest {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                do {
                    let descriptor = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
                    guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                    file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                    self.continuation = continuation
                    configuration.httpCookieStorage = nil
                    configuration.httpShouldSetCookies = false
                    configuration.urlCredentialStorage = nil
                    configuration.urlCache = nil
                    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
                    // `timeout` bounds the whole request; without it a stall or the whole transfer is.
                    configuration.timeoutIntervalForRequest = timeout ?? 300
                    configuration.timeoutIntervalForResource = timeout ?? 1800
                    let queue = OperationQueue()
                    queue.maxConcurrentOperationCount = 1
                    let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
                    self.session = session
                    let task = session.dataTask(with: source)
                    lock.withLock {
                        self.task = task
                        task.resume()
                        if cancelled { task.cancel() }
                    }
                } catch { continuation.resume(throwing: error) }
            }
        } onCancel: {
            self.lock.withLock { self.cancelled = true; self.task?.cancel() }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard request.url?.scheme == "https", request.url?.host == source.host,
              request.url?.port == nil || request.url?.port == 443 else {
            failure = SteamCMDSetupIssue(kind: .network, detail: String(localized: "SteamCMD download redirected outside the official HTTPS host."))
            completionHandler(nil)
            task.cancel()
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard failure == nil else {
            completionHandler(.cancel)
            return
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              response.url?.scheme == "https", response.url?.host == source.host else {
            failure = SteamCMDSetupIssue(kind: .network, detail: String(localized: "The official SteamCMD server did not return HTTP 200."))
            completionHandler(.cancel)
            return
        }
        // URLSession delivers decoded bytes. Content-Length counts the wire encoding (Valve
        // gzips the manifest), not those bytes; package sizes/hashes still check decoded data.
        let encoding = http.value(forHTTPHeaderField: "Content-Encoding")?.lowercased()
        expected = encoding == nil || encoding == "identity"
            ? http.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init).flatMap { $0 >= 0 ? $0 : nil }
            : nil
        if let expected, expected > maximum || expectedSize.map({ $0 != expected }) == true {
            failure = sizeIssue()
            completionHandler(.cancel)
            return
        }
        progress(0, expectedSize ?? expected)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil else { return }
        guard Int64(data.count) <= maximum - received else {
            failure = sizeIssue()
            dataTask.cancel()
            return
        }
        do {
            try file?.write(contentsOf: data)
            sha256.update(data: data)
            sha1.update(data: data)
            received += Int64(data.count)
            progress(received, expectedSize ?? expected)
        } catch { failure = error; dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        do { try file?.close() } catch { if failure == nil { failure = error } }
        file = nil
        let wasCancelled = lock.withLock { self.task = nil; return cancelled }
        let completion = continuation
        continuation = nil
        session.finishTasksAndInvalidate()
        self.session = nil
        if wasCancelled { completion?.resume(throwing: CancellationError()) }
        else if let failure { completion?.resume(throwing: failure) }
        else if let error {
            completion?.resume(throwing: SteamCMDSetupIssue(kind: (error as? URLError)?.code == .timedOut ? .timedOut : .network, detail: error.localizedDescription))
        } else if received == 0 || expected.map({ $0 != received }) == true || expectedSize.map({ $0 != received }) == true {
            completion?.resume(throwing: SteamCMDSetupIssue(kind: .invalidArchive, detail: String(localized: "A SteamCMD download is empty or truncated.")))
        } else {
            completion?.resume(returning: Digest(sha256: Self.hex(sha256.finalize()), sha1: Self.hex(sha1.finalize())))
        }
    }

    private func sizeIssue() -> SteamCMDSetupIssue {
        SteamCMDSetupIssue(kind: .invalidArchive, detail: String(localized: "A SteamCMD download is larger than Valve’s package manifest allows."))
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
