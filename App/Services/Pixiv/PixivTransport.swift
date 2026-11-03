import Foundation

/// The network seam for pixiv: JSON from `www.pixiv.net` and images from `i.pximg.net`, which
/// answers 403 to any request that does not name pixiv as its referrer. Injected so tests never
/// reach the network.
protocol PixivTransport: Sendable {
    /// The body of a 2xx answer; any other status throws `PixivFailure.Code.status`, or
    /// `blockedByProtection` when pixiv's Cloudflare front refused the connection. `session`
    /// is the signed-in account's `PHPSESSID`, or nil to ask anonymously.
    func data(from url: URL, session: String?) async throws -> Data

    /// An image of at most `limit` bytes, reporting bytes received so far and the size the
    /// server announced, when it announced one.
    func image(
        from url: URL, limit: Int, progress: @escaping @Sendable (Int64, Int64?) -> Void
    ) async throws -> Data

    func image(
        from url: URL, limit: Int, checkpoint: URL,
        progress: @escaping @Sendable (Int64, Int64?) -> Void
    ) async throws -> Data
}

extension PixivTransport {
    /// Custom transports may restart a transfer; the production transport supports HTTP ranges.
    func image(
        from url: URL, limit: Int, checkpoint: URL,
        progress: @escaping @Sendable (Int64, Int64?) -> Void
    ) async throws -> Data {
        try await image(from: url, limit: limit, progress: progress)
    }
}

struct URLSessionPixivTransport: PixivTransport {
    static let referer = "https://www.pixiv.net/"
    let transportSession: URLSession

    init(session: URLSession? = nil) { transportSession = session ?? Self.session }

    // Ephemeral and cookie-free: nothing pixiv sets is kept, and the one cookie that is sent, the
    // account's session, is added by hand to the requests that may carry it and taken off any
    // redirect that leaves pixiv's site.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpMaximumConnectionsPerHost = 6
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        return URLSession(configuration: configuration, delegate: RedirectGuard(), delegateQueue: nil)
    }()

    /// WebKit's default user agent form, naming the app instead of Safari: pixiv's
    /// Cloudflare front answers a signed-in request whose user agent lacks the `Mozilla/5.0`
    /// form with a 403 browser check.
    private static let userAgent: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) "
            + "WallpaperMachine/\(version ?? "1.0")"
    }()

    static func request(_ url: URL, accept: String, session: String? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        if let session, PixivService.isSessionValue(session), mayCarrySession(url) {
            request.setValue("PHPSESSID=\(session)", forHTTPHeaderField: "Cookie")
        }
        return request
    }

    /// The session signs in to pixiv's site only: never to its image host, never elsewhere.
    static func mayCarrySession(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.scheme == "https" && url.host == "www.pixiv.net" && url.port == nil && url.user == nil
            && url.password == nil
    }

    /// The request a redirect continues with: the session stays behind unless the new address
    /// is pixiv's site again.
    static func redirected(_ request: URLRequest) -> URLRequest {
        var request = request
        if !mayCarrySession(request.url) { request.setValue(nil, forHTTPHeaderField: "Cookie") }
        return request
    }

    func data(from url: URL, session: String?) async throws -> Data {
        let (data, response) = try await Self.perform {
            try await transportSession.data(for: Self.request(url, accept: "application/json", session: session))
        }
        try Self.check(response, body: data)
        return data
    }

    func image(
        from url: URL, limit: Int, progress: @escaping @Sendable (Int64, Int64?) -> Void
    ) async throws -> Data {
        let request = Self.request(url, accept: "image/avif,image/webp,image/png,image/jpeg,image/gif,*/*;q=0.5")
        let (bytes, response) = try await Self.perform { try await transportSession.bytes(for: request) }
        defer { bytes.task.cancel() }
        try Self.check(response)
        let expected = response.expectedContentLength > 0 ? response.expectedContentLength : nil
        let megabytes = limit / (1024 * 1024)
        if let expected, expected > Int64(limit) { throw PixivFailure(code: .tooLarge(megabytes: megabytes)) }
        var data = Data()
        data.reserveCapacity(Int(min(expected ?? 0, Int64(limit))))
        progress(0, expected)
        try await Self.perform {
            for try await byte in bytes {
                guard data.count < limit else { throw PixivFailure(code: .tooLarge(megabytes: megabytes)) }
                data.append(byte)
                guard data.count.isMultiple(of: 65_536) else { continue }
                try Task.checkCancellation()
                guard data.count <= limit else { throw PixivFailure(code: .tooLarge(megabytes: megabytes)) }
                progress(Int64(data.count), expected)
            }
        }
        try Task.checkCancellation()
        guard data.count <= limit else { throw PixivFailure(code: .tooLarge(megabytes: megabytes)) }
        progress(Int64(data.count), expected)
        return data
    }

    /// A transport failure becomes a `PixivFailure`; cancellation stays a cancellation.
    private static func perform<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError {
            throw PixivFailure(code: .network(ConnectionInterrupted.message(for: error, site: "www.pixiv.net")))
        }
    }

    /// `body` is the answer's content when it was read whole; streamed images pass none, so only
    /// the headers can show a protection block there.
    static func check(_ response: URLResponse, body: Data? = nil) throws {
        guard let http = response as? HTTPURLResponse else { throw PixivFailure(code: .unreadable) }
        guard (200..<300).contains(http.statusCode) else {
            let block = protectionBlock(http, body: body)
            // Log the host and what refused, never URLs, headers or bodies: they can reveal
            // searches or the session cookie.
            let host = http.url?.host.flatMap { ["www.pixiv.net", "i.pximg.net"].contains($0) ? $0 : nil } ?? "another host"
            let detail =
                switch block {
                case .blockedByProtection(let reference?)?: " (blocked by pixiv's Cloudflare protection, error \(reference))"
                case .blockedByProtection(nil)?: " (pixiv's Cloudflare protection asked for a browser check)"
                default: ""
                }
            AppLog.warn("pixiv request to \(host) failed: HTTP \(http.statusCode)\(detail)")
            throw PixivFailure(code: block ?? .status(http.statusCode))
        }
    }

    /// Cloudflare, in front of pixiv's site, answers a connection it refuses itself, before pixiv
    /// sees it: a browser check it marks with `cf-mitigated: challenge`, or a block page naming
    /// its error reference (`error code: 1010` as plain text, or pixiv's styled page with
    /// `cf-error-1010` and `Error reference number: 1010`). pixiv's own refusals, such as an R-18
    /// ranking for a visitor it does not know to be an adult, carry neither.
    static func protectionBlock(_ http: HTTPURLResponse, body: Data?) -> PixivFailure.Code? {
        guard [403, 503].contains(http.statusCode),
            http.value(forHTTPHeaderField: "Server")?.lowercased() == "cloudflare"
        else { return nil }
        if http.value(forHTTPHeaderField: "cf-mitigated")?.lowercased() == "challenge" {
            return .blockedByProtection(reference: nil)
        }
        guard let body, !body.isEmpty else { return nil }
        let text = String(decoding: body, as: UTF8.self)
        for marker in ["cf-error-", "error code: ", "Error reference number: "] {
            var rest = text[...]
            while let found = rest.range(of: marker) {
                rest = rest[found.upperBound...]
                let digits = rest.prefix { $0.isASCII && $0.isNumber }
                if digits.count == 4, digits.first == "1", let reference = Int(digits) {
                    return .blockedByProtection(reference: reference)
                }
            }
        }
        return nil
    }
}

private final class RedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(URLSessionPixivTransport.redirected(request))
    }
}

/// Feeds pixiv thumbnails to a `WorkshopThumbnailCache`, which keeps them on disk exactly as it
/// keeps Workshop previews; only the fetch differs, since `i.pximg.net` needs the referrer.
struct PixivThumbnailFetcher: WorkshopThumbnailFetching {
    /// pixiv's own renditions stay well under this; anything larger is not a thumbnail.
    static let byteLimit = 8 * 1024 * 1024
    private let transport: any PixivTransport

    init(transport: any PixivTransport = URLSessionPixivTransport()) { self.transport = transport }

    func fetch(_ url: URL) async throws -> Data {
        guard PixivService.isImageURL(url) else { throw PixivFailure(code: .unreadable) }
        return try await transport.image(from: url, limit: Self.byteLimit) { _, _ in }
    }
}
