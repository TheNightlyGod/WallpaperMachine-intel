import CryptoKit
import Foundation

protocol AppUpdateClient: Sendable {
    func fetchLatestRelease() async throws -> GitHubRelease?
    func download(_ asset: GitHubReleaseAsset, to destination: URL,
                  progress: @escaping @Sendable (Int64, Int64, Int64) -> Void) async throws
}

struct DisabledAppUpdateClient: AppUpdateClient {
    func fetchLatestRelease() async throws -> GitHubRelease? {
        throw AppUpdateIssue(code: .configuration, detail: String(localized: "The GitHub Release update metadata is unavailable."))
    }

    func download(_ asset: GitHubReleaseAsset, to destination: URL,
                  progress: @escaping @Sendable (Int64, Int64, Int64) -> Void) async throws {
        throw AppUpdateIssue(code: .configuration, detail: String(localized: "No update is available to download."))
    }
}

/// The ways to GitHub's release files: directly (`nil`) or through one of the mirrors. The way
/// that last worked goes first, so a Mac that can't reach GitHub doesn't wait out its timeout
/// on every check.
final class AppUpdateRoutes: @unchecked Sendable {
    let mirrors: [URL]
    private let lock = NSLock()
    private var preferred: URL?

    init(mirrors: [URL]) {
        self.mirrors = mirrors
    }

    var ordered: [URL?] {
        let routes: [URL?] = [nil] + mirrors
        guard let preferred = lock.withLock({ preferred }) else { return routes }
        return [preferred] + routes.filter { $0 != preferred }
    }

    func remember(_ mirror: URL?) {
        lock.withLock { preferred = mirror }
    }

    /// `url` as `mirror` serves it: the whole GitHub URL appended to the mirror's.
    static func url(_ url: URL, through mirror: URL?) -> URL {
        guard let mirror else { return url }
        return URL(string: mirror.absoluteString + url.absoluteString) ?? url
    }
}

struct GitHubReleaseClient: AppUpdateClient {
    private let session: URLSession
    private let manifestURL: URL
    private let latestURL: URL
    private let routes: AppUpdateRoutes

    init(session: URLSession = GitHubReleaseClient.makeSession(),
         manifestURL: URL = AppUpdateConfiguration.latestManifestURL,
         latestURL: URL = AppUpdateConfiguration.latestReleaseURL,
         mirrors: [URL] = AppUpdateConfiguration.mirrors) {
        self.session = session
        self.manifestURL = manifestURL
        self.latestURL = latestURL
        routes = AppUpdateRoutes(mirrors: mirrors)
    }

    private struct RepositoryIdentity: Decodable {
        let id: Int
    }

    static func makeSession(configuration: URLSessionConfiguration = .ephemeral) -> URLSession {
        let configuration = configuration.copy() as! URLSessionConfiguration
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration)
    }

    /// Reads the update manifest attached to the Latest release and asks the REST API only
    /// when that release has no usable one. The manifest arrives through github.com's release
    /// download redirect, which GitHub's anonymous API limit (60 requests an hour per public
    /// IP, shared with everything behind it) does not count.
    /// When GitHub can't be reached, the mirrors are asked for the same manifest in turn. Only
    /// an unreachable route moves on: GitHub's own answers (a rate limit, no repository) stand,
    /// and when every route fails the error reported is GitHub's.
    func fetchLatestRelease() async throws -> GitHubRelease? {
        var failure: AppUpdateIssue?
        for mirror in routes.ordered {
            try Task.checkCancellation()
            do {
                let release = try await fetchLatestRelease(through: mirror)
                if mirror != nil { AppLog.info("update: checked through \(mirror?.host ?? "")") }
                routes.remember(mirror)
                return release
            } catch let issue as AppUpdateIssue {
                guard issue.code == .network else { throw issue }
                if mirror == nil || failure == nil { failure = issue }
            }
        }
        throw failure ?? AppUpdateIssue(code: .network, detail: String(localized: "GitHub did not return a successful update response."))
    }

    private func fetchLatestRelease(through mirror: URL?) async throws -> GitHubRelease? {
        do {
            if let mirror {
                // A mirror only relays the manifest; anything else it answers is a dead route.
                guard let data = try? await fetchManifestData(through: mirror),
                      let release = try? GitHubReleaseParser.decode(data) else {
                    throw AppUpdateIssue(code: .network, detail: String(localized: "GitHub did not return a successful update response."))
                }
                return release
            }
            if let data = try await fetchManifestData() {
                if let release = try? GitHubReleaseParser.decode(data) { return release }
                AppLog.warn("The latest release's update manifest is unreadable; asking the GitHub API instead")
            }
            return try await fetchFromAPI()
        } catch let issue as AppUpdateIssue {
            throw issue
        } catch {
            throw AppUpdateIssue(code: AppUpdateErrorClassifier.classify(error), detail: error.localizedDescription)
        }
    }

    /// The manifest's bytes, or nil when the Latest release carries none: it predates the
    /// manifest, or nothing is published yet. Redirects are followed only on GitHub's hosts
    /// and the mirror's.
    func fetchManifestData(through mirror: URL? = nil) async throws -> Data? {
        var request = URLRequest(url: AppUpdateRoutes.url(manifestURL, through: mirror))
        request.setValue("WallpaperMachine", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(
            for: request, delegate: GitHubRedirectGuard(mirrors: mirror.map { [$0] } ?? []))
        guard let http = response as? HTTPURLResponse else {
            throw AppUpdateIssue(code: .network, detail: String(localized: "GitHub did not return a successful update response."))
        }
        if http.statusCode == 404 { return nil }
        if let limited = Self.rateLimitIssue(http) { throw limited }
        // A refused redirect leaves its 3xx as the final response.
        guard (200..<300).contains(http.statusCode) else {
            throw AppUpdateIssue(code: .network, detail: String(localized: "GitHub did not return a successful update response."))
        }
        return data
    }

    private func fetchFromAPI() async throws -> GitHubRelease? {
        var request = URLRequest(url: latestURL)
        request.setValue("WallpaperMachine", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AppUpdateIssue(code: .network, detail: String(localized: "GitHub did not return a successful update response."))
        }
        if let limited = Self.rateLimitIssue(http) { throw limited }
        if http.statusCode == 404 {
            // GitHub also returns 404 for inaccessible repositories. Only a
            // reachable repository can turn a missing latest release into an empty result.
            request.url = latestURL.deletingLastPathComponent().deletingLastPathComponent()
            let (repositoryData, repositoryResponse) = try await session.data(for: request)
            guard let repositoryHTTP = repositoryResponse as? HTTPURLResponse else {
                throw AppUpdateIssue(code: .network, detail: String(localized: "GitHub did not return a successful update response."))
            }
            if let limited = Self.rateLimitIssue(repositoryHTTP) { throw limited }
            guard (200..<300).contains(repositoryHTTP.statusCode) else {
                throw AppUpdateIssue(code: repositoryHTTP.statusCode == 404 ? .configuration : .network,
                                     detail: String(localized: "GitHub did not return a successful update response."))
            }
            guard let repository = try? JSONDecoder().decode(RepositoryIdentity.self, from: repositoryData), repository.id > 0 else {
                throw AppUpdateIssue(code: .configuration, detail: String(localized: "The GitHub Release update metadata is unavailable."))
            }
            return nil
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AppUpdateIssue(code: .network, detail: String(localized: "GitHub did not return a successful update response."))
        }
        return try GitHubReleaseParser.decode(data)
    }

    /// GitHub allows 60 unauthenticated API requests per hour per public IP address, shared by
    /// every app and device behind it. Exhaustion answers 403 or 429 with
    /// `x-ratelimit-remaining: 0` and an epoch `x-ratelimit-reset`; secondary limits send
    /// `retry-after` seconds instead.
    static func rateLimitIssue(_ response: HTTPURLResponse, now: Date = Date()) -> AppUpdateIssue? {
        let retryAfter = response.value(forHTTPHeaderField: "retry-after").flatMap(TimeInterval.init)
        let exhausted = response.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0"
        guard response.statusCode == 429 || (response.statusCode == 403 && (exhausted || retryAfter != nil)) else {
            return nil
        }
        let reset: Date?
        if let retryAfter, retryAfter >= 0 {
            reset = now.addingTimeInterval(retryAfter)
        } else if let epoch = response.value(forHTTPHeaderField: "x-ratelimit-reset").flatMap(TimeInterval.init), epoch > 0 {
            reset = Date(timeIntervalSince1970: epoch)
        } else {
            reset = nil
        }
        return AppUpdateIssue(code: .rateLimited,
                              detail: String(localized: "GitHub's hourly limit for anonymous update checks is used up."),
                              retryAfter: reset)
    }

    func download(_ asset: GitHubReleaseAsset, to destination: URL,
                  progress: @escaping @Sendable (Int64, Int64, Int64) -> Void) async throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        // The image itself must be GitHub's; a mirror is only another way to fetch that URL.
        guard GitHubReleaseDownload.isAllowed(asset.downloadURL) else {
            throw AppUpdateIssue(code: .network, detail: String(localized: "The update download redirected outside GitHub."))
        }
        let order = routes.ordered
        let transfer = GitHubReleaseDownload(sources: order.map { AppUpdateRoutes.url(asset.downloadURL, through: $0) },
                                             mirrors: routes.mirrors, destination: destination,
                                             expectedSize: asset.size > 0 ? asset.size : nil,
                                             digest: asset.digest, progress: progress)
        let finished = try await transfer.start()
        if let index = transfer.sources.firstIndex(of: finished) { routes.remember(order[index]) }
    }
}

/// Follows a redirect only while it stays on the GitHub HTTPS hosts a download may use, or on
/// the mirror relaying the request.
final class GitHubRedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    private let mirrors: [URL]

    init(mirrors: [URL] = []) {
        self.mirrors = mirrors
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        guard let url = request.url, GitHubReleaseDownload.isAllowed(url, mirrors: mirrors) else { return nil }
        return request
    }
}

/// Streams a GitHub Release asset to disk from the first of `sources` that delivers it: GitHub
/// itself, then mirrors relaying the same URL. A source that fails, stalls or (while another is
/// left to try) crawls hands over to the next, which resumes where it stopped with an HTTP
/// Range request. Redirects stay on GitHub's HTTPS hosts and the mirrors'.
final class GitHubReleaseDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let allowedHosts: Set<String> = [
        "github.com", "api.github.com", "objects.githubusercontent.com",
        "release-assets.githubusercontent.com", "github-releases.githubusercontent.com"
    ]

    /// Below this rate, measured once a source has had `slowSourceGrace`, a source gives way to
    /// the next one, so a trickling connection to GitHub doesn't hold the image for half an hour.
    static let slowSourceRate: Int64 = 32 * 1024

    let sources: [URL]
    private let mirrors: [URL]
    private let destination: URL
    private let expectedSize: Int64?
    private let digest: String?
    private let progress: @Sendable (Int64, Int64, Int64) -> Void
    private let configuration: URLSessionConfiguration
    private let slowSourceGrace: Duration
    private let slowSourceRate: Int64
    private let lock = NSLock()
    private var cancelled = false
    private var task: URLSessionDataTask?
    private var session: URLSession?
    private var continuation: CheckedContinuation<Void, Error>?
    private var file: FileHandle?
    private var received: Int64 = 0
    private var expected: Int64?
    private var failure: Error?
    private var hasher = SHA256()
    private var lastProgressAt = ContinuousClock.now
    private var lastProgressBytes: Int64 = 0
    private var attemptStartedAt = ContinuousClock.now
    private var attemptStartBytes: Int64 = 0
    private var abandonsSlowSource = false

    /// What ends one source's attempt; the download moves on to the next source.
    private struct SourceFailure: Error {
        let issue: AppUpdateIssue
    }

    init(sources: [URL], mirrors: [URL] = [], destination: URL, expectedSize: Int64?, digest: String?,
         configuration: URLSessionConfiguration = .ephemeral, slowSourceGrace: Duration = .seconds(30),
         slowSourceRate: Int64 = GitHubReleaseDownload.slowSourceRate,
         progress: @escaping @Sendable (Int64, Int64, Int64) -> Void) {
        self.sources = sources
        self.mirrors = mirrors
        self.destination = destination
        self.expectedSize = expectedSize
        self.digest = digest
        self.slowSourceGrace = slowSourceGrace
        self.slowSourceRate = slowSourceRate
        self.progress = progress
        let configuration = configuration.copy() as! URLSessionConfiguration
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 1800
        self.configuration = configuration
    }

    /// Downloads and verifies the image, returning the source that finished it. Sources take
    /// turns while they reach new offsets; once each in a row has failed without advancing,
    /// the last failure ends the download.
    @discardableResult
    func start() async throws -> URL {
        try await withTaskCancellationHandler {
            guard !sources.isEmpty, sources.allSatisfy({ Self.isAllowed($0, mirrors: mirrors) }) else {
                throw AppUpdateIssue(code: .network, detail: String(localized: "The update download redirected outside GitHub."))
            }
            // An image nothing could verify is not worth downloading.
            guard let expectedHash = digest.flatMap(Self.parseSHA256Hex) else {
                throw AppUpdateIssue(code: .verification, detail: String(localized: "The update couldn't be verified, so it wasn't installed."))
            }
            let descriptor = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? file?.close(); file = nil }
            var attempt = 0
            var fruitless = 0
            var furthest = Int64(0)
            while true {
                try Task.checkCancellation()
                let source = sources[attempt % sources.count]
                do {
                    try await transfer(from: source, abandoningIfSlow: attempt < sources.count - 1)
                    let complete = received > 0 && expected.map { $0 == received } != false
                    let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                    if complete, actual == expectedHash {
                        try file?.close()
                        file = nil
                        return source
                    }
                    // Bytes that don't add up to the release's image start over on the next source.
                    try restart()
                    throw SourceFailure(issue: complete
                        ? AppUpdateIssue(code: .verification, detail: String(localized: "The update couldn't be verified, so it wasn't installed."))
                        : AppUpdateIssue(code: .verification, detail: String(localized: "The update download is empty or truncated.")))
                } catch let failure as SourceFailure {
                    fruitless = received > furthest ? 0 : fruitless + 1
                    furthest = max(furthest, received)
                    guard fruitless < sources.count else { throw failure.issue }
                    AppLog.info("update: download moves on from \(source.host ?? "") at \(received) bytes")
                    attempt += 1
                }
            }
        } onCancel: {
            self.lock.withLock { self.cancelled = true; self.task?.cancel() }
        }
    }

    /// One request to `source`, asking for the bytes after those already written.
    private func transfer(from source: URL, abandoningIfSlow: Bool) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.continuation = continuation
            failure = nil
            attemptStartedAt = .now
            attemptStartBytes = received
            abandonsSlowSource = abandoningIfSlow
            var request = URLRequest(url: source)
            request.setValue("WallpaperMachine", forHTTPHeaderField: "User-Agent")
            request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
            if received > 0 { request.setValue("bytes=\(received)-", forHTTPHeaderField: "Range") }
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
            self.session = session
            let task = session.dataTask(with: request)
            lock.withLock {
                self.task = task
                task.resume()
                if cancelled { task.cancel() }
            }
        }
    }

    /// Throws away what was written, for a source that sends the whole image again.
    private func restart() throws {
        guard received > 0 else { return }
        try file?.truncate(atOffset: 0)
        received = 0
        attemptStartBytes = 0
        hasher = SHA256()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, Self.isAllowed(url, mirrors: mirrors) else {
            failure = SourceFailure(issue: AppUpdateIssue(code: .network, detail: String(localized: "The update download redirected outside GitHub.")))
            completionHandler(nil)
            task.cancel()
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let unsuccessful = SourceFailure(issue: AppUpdateIssue(
            code: .network, detail: String(localized: "GitHub did not return a successful update response.")))
        guard let http = response as? HTTPURLResponse, let url = response.url, Self.isAllowed(url, mirrors: mirrors) else {
            failure = unsuccessful
            completionHandler(.cancel)
            return
        }
        let total: Int64?
        if http.statusCode == 206, received > 0, let range = Self.contentRange(http), range.start == received {
            total = range.total
        } else if http.statusCode == 200 {
            // The whole image: a first request, or a source that ignores Range.
            do { try restart() } catch {
                failure = error
                completionHandler(.cancel)
                return
            }
            total = http.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init).flatMap { $0 >= 0 ? $0 : nil }
        } else {
            failure = unsuccessful
            completionHandler(.cancel)
            return
        }
        expected = expectedSize ?? total
        if let expected, expected > AppUpdateConfiguration.maximumDownloadBytes {
            failure = AppUpdateIssue(code: .verification, detail: String(localized: "The update archive exceeds the allowed size."))
            completionHandler(.cancel)
            return
        }
        lastProgressAt = .now
        lastProgressBytes = received
        progress(received, expected ?? 0, 0)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil else { return }
        guard Int64(data.count) <= AppUpdateConfiguration.maximumDownloadBytes - received else {
            failure = AppUpdateIssue(code: .verification, detail: String(localized: "The update archive exceeds the allowed size."))
            dataTask.cancel()
            return
        }
        do {
            try file?.write(contentsOf: data)
            hasher.update(data: data)
            received += Int64(data.count)
            let seconds = Self.seconds(lastProgressAt.duration(to: .now))
            let rate: Int64
            if seconds >= 0.25 {
                rate = Int64(Double(received - lastProgressBytes) / max(seconds, 0.001))
                lastProgressAt = .now
                lastProgressBytes = received
            } else {
                rate = 0
            }
            progress(received, expected ?? 0, max(0, rate))
            let elapsed = attemptStartedAt.duration(to: .now)
            if abandonsSlowSource, elapsed >= slowSourceGrace, expected.map({ received < $0 }) != false,
               Double(received - attemptStartBytes) < Double(slowSourceRate) * Self.seconds(elapsed) {
                failure = SourceFailure(issue: AppUpdateIssue(code: .network, detail: URLError(.timedOut).localizedDescription))
                dataTask.cancel()
            }
        } catch {
            failure = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let wasCancelled = lock.withLock { self.task = nil; return cancelled }
        let completion = continuation
        continuation = nil
        session.finishTasksAndInvalidate()
        self.session = nil
        if wasCancelled {
            completion?.resume(throwing: CancellationError())
            return
        }
        if let failure {
            completion?.resume(throwing: failure)
            return
        }
        if let error {
            completion?.resume(throwing: SourceFailure(issue: AppUpdateIssue(
                code: AppUpdateErrorClassifier.classify(error), detail: error.localizedDescription)))
            return
        }
        // A source that closed early leaves the rest to the next one.
        if let expected, received < expected {
            completion?.resume(throwing: SourceFailure(issue: AppUpdateIssue(
                code: .network, detail: String(localized: "The update download is empty or truncated."))))
            return
        }
        completion?.resume()
    }

    static func isAllowed(_ url: URL, mirrors: [URL] = []) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased(), url.port == nil || url.port == 443 else { return false }
        return allowedHosts.contains(host) || mirrors.contains { $0.host?.lowercased() == host }
    }

    /// `Content-Range: bytes <start>-<end>/<total>`; `total` is nil when the source gives `*`.
    static func contentRange(_ response: HTTPURLResponse) -> (start: Int64, total: Int64?)? {
        guard let value = response.value(forHTTPHeaderField: "Content-Range"), value.hasPrefix("bytes "),
              let dash = value.firstIndex(of: "-"), let slash = value.firstIndex(of: "/"),
              let start = Int64(value[value.index(value.startIndex, offsetBy: 6)..<dash]) else { return nil }
        return (start, Int64(value[value.index(after: slash)...]))
    }

    static func parseSHA256Hex(_ digest: String) -> String? {
        let value = digest.trimmingCharacters(in: .whitespacesAndNewlines)
        let hex = value.lowercased().hasPrefix("sha256:") ? String(value.dropFirst(7)) : value
        let normalized = hex.lowercased()
        guard normalized.count == 64, normalized.allSatisfy(\.isHexDigit) else { return nil }
        return normalized
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1_000_000_000_000_000_000
    }
}
