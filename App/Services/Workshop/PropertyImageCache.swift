import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Author artwork is loaded as raster bytes only, never as remote content.
actor PropertyImageCache {
    struct Image: Sendable {
        let data: Data
        let mimeType: String
    }

    private static let byteLimit = 16 * 1024 * 1024
    private let session: URLSession
    private let redirects = PropertyImageRedirects()
    private var cache: [URL: Image] = [:]
    private var order: [URL] = []
    private var cachedBytes = 0
    private struct Load {
        let id = UUID()
        var consumers: [UUID: CheckedContinuation<Image, Error>]
        var job: Task<Void, Never>?
    }
    private static let concurrentLoadLimit = 4
    private var loading: [URL: Load] = [:]
    private var queued: [URL] = []
    private var activeLoads = 0

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
            return
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 45
        self.session = URLSession(configuration: configuration)
    }

    // Exact image CDNs, not arbitrary author URLs or an open proxy into the LAN.
    nonisolated static func allowedURL(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil,
              url.fragment == nil else { return false }
        return [
            "i.ibb.co", "i.imgur.com", "images.steamusercontent.com",
            "steamuserimages-a.akamaihd.net", "shared.akamai.steamstatic.com",
            "photogz.photo.store.qq.com", "photo.store.qq.com",
        ].contains(url.host?.lowercased() ?? "")
    }

    /// Source spelling is retained so a label's markup can be matched to its image. Only src on
    /// an img tag is registered; URL validation is repeated when the image is loaded.
    nonisolated static func sources(in html: String) -> [String: URL] {
        guard html.utf8.count <= 65_536 else { return [:] }
        let pattern = #"<img\b[^>]*?\s+src\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return [:]
        }
        var result: [String: URL] = [:]
        for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).prefix(64) {
            for group in 1...3 {
                guard let range = Range(match.range(at: group), in: html) else { continue }
                let source = String(html[range]).replacingOccurrences(of: "&amp;", with: "&")
                guard let url = URL(string: source), allowedURL(url) else { continue }
                result[source] = url
            }
        }
        return result
    }

    func image(for url: URL) async throws -> Image {
        try Task.checkCancellation()
        guard Self.allowedURL(url) else { throw URLError(.unsupportedURL) }
        if let image = cache[url] { return image }
        let consumer = UUID()
        let image: Image = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Image, Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if var load = loading[url] {
                    load.consumers[consumer] = continuation
                    loading[url] = load
                } else {
                    loading[url] = Load(consumers: [consumer: continuation])
                    queued.append(url)
                }
                startQueuedLoads()
            }
        } onCancel: {
            Task { await self.cancelConsumer(consumer, for: url) }
        }
        try Task.checkCancellation()
        return image
    }

    private func cancelConsumer(_ consumer: UUID, for url: URL) {
        guard var load = loading[url], let continuation = load.consumers.removeValue(forKey: consumer) else { return }
        if load.consumers.isEmpty {
            loading[url] = nil
            if let job = load.job {
                // Keep its slot until the worker exits. A rapid cancel/re-request
                // must not accumulate still-unwinding network transfers.
                job.cancel()
            } else {
                queued.removeAll { $0 == url }
            }
        } else {
            loading[url] = load
        }
        continuation.resume(throwing: CancellationError())
    }

    private func startQueuedLoads() {
        while activeLoads < Self.concurrentLoadLimit, !queued.isEmpty {
            let url = queued.removeFirst()
            guard let load = loading[url] else { continue }
            activeLoads += 1
            let id = load.id
            let session = session
            let redirects = redirects
            loading[url]?.job = Task {
                let result: Result<Image, Error>
                do {
                    result = .success(try await Self.fetch(url, session: session, redirects: redirects))
                } catch {
                    result = .failure(error)
                }
                finishLoad(for: url, id: id, result: result)
            }
        }
    }

    private func finishLoad(for url: URL, id: UUID, result: Result<Image, Error>) {
        activeLoads -= 1
        // An abandoned generation can finish after a fresh request for the same
        // URL. It owns neither the new consumers nor a place in the cache.
        if let load = loading[url], load.id == id {
            loading[url] = nil
            if case .success(let image) = result { store(image, for: url) }
            for continuation in load.consumers.values { continuation.resume(with: result) }
        }
        startQueuedLoads()
    }

    private nonisolated static func fetch(
        _ url: URL, session: URLSession, redirects: PropertyImageRedirects
    ) async throws -> Image {
        try Task.checkCancellation()
        var request = URLRequest(url: url)
        request.setValue("image/png,image/jpeg,image/gif,image/webp", forHTTPHeaderField: "Accept")
        let (stream, response) = try await session.bytes(for: request, delegate: redirects)
        guard let response = response as? HTTPURLResponse,
              response.statusCode == 200, let finalURL = response.url,
              Self.allowedURL(finalURL) else { throw URLError(.badServerResponse) }
        guard response.expectedContentLength <= Self.byteLimit else {
            throw URLError(.dataLengthExceedsMaximum)
        }
        var data = Data()
        data.reserveCapacity(Int(max(0, response.expectedContentLength)))
        for try await byte in stream {
            if data.count.isMultiple(of: 65_536) { try Task.checkCancellation() }
            guard data.count < Self.byteLimit else { throw URLError(.dataLengthExceedsMaximum) }
            data.append(byte)
        }
        try Task.checkCancellation()
        return try Self.decode(data)
    }

    private func store(_ image: Image, for url: URL) {
        // A bounded in-memory cache shares repeated dividers across all properties.
        while cachedBytes + image.data.count > 48 * 1024 * 1024 || order.count >= 64 {
            guard let oldest = order.first else { break }
            order.removeFirst()
            cachedBytes -= cache.removeValue(forKey: oldest)?.data.count ?? 0
        }
        cache[url] = image
        order.append(url)
        cachedBytes += image.data.count
    }

    nonisolated static func decode(_ data: Data) throws -> Image {
        guard data.count <= byteLimit,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let identifier = CGImageSourceGetType(source) as String?,
              [UTType.png.identifier, UTType.jpeg.identifier, UTType.gif.identifier, UTType.webP.identifier].contains(identifier),
              let mime = UTType(identifier)?.preferredMIMEType else { throw URLError(.cannotDecodeContentData) }
        let frames = CGImageSourceGetCount(source)
        guard frames > 0, frames <= 600 else { throw URLError(.dataLengthExceedsMaximum) }
        var pixels = 0
        for index in 0..<frames {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= 8192, height <= 8192,
                  width * height <= 32_000_000 else { throw URLError(.dataLengthExceedsMaximum) }
            pixels += width * height
            guard pixels <= 256_000_000 else { throw URLError(.dataLengthExceedsMaximum) }
        }
        return Image(data: data, mimeType: mime)
    }
}

private final class PropertyImageRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(request.url.map(PropertyImageCache.allowedURL) == true ? request : nil)
    }
}
