import Foundation

extension URLSessionPixivTransport {
    private struct ImageCheckpoint: Codable {
        let url: URL
        let validator: String?
        let expected: Int64?
    }

    /// Continue only a representation the server still identifies with the same validator.
    /// A normal 200 response to Range means the original changed and replaces the partial file.
    func image(
        from url: URL, limit: Int, checkpoint: URL,
        progress: @escaping @Sendable (Int64, Int64?) -> Void
    ) async throws -> Data {
        do {
            return try await receiveImage(from: url, limit: limit, checkpoint: checkpoint, progress: progress)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError {
            throw PixivFailure(code: .network(ConnectionInterrupted.message(for: error, site: "www.pixiv.net")))
        }
    }

    private func receiveImage(
        from url: URL, limit: Int, checkpoint: URL, canRetryRange: Bool = true,
        progress: @escaping @Sendable (Int64, Int64?) -> Void
    ) async throws -> Data {
        let files = FileManager.default
        try files.createDirectory(at: checkpoint, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let image = checkpoint.appendingPathComponent("image.partial")
        let metadataFile = checkpoint.appendingPathComponent("transfer.json")
        let saved = (try? Data(contentsOf: metadataFile)).flatMap { try? JSONDecoder().decode(ImageCheckpoint.self, from: $0) }
        let size = (try? files.attributesOfItem(atPath: image.path)[.size] as? NSNumber)?.int64Value ?? 0
        let reusable = saved?.url == url && saved?.validator != nil && size > 0 && size <= Int64(limit)
        let offset = reusable ? size : 0
        var request = Self.request(url, accept: "image/avif,image/webp,image/png,image/jpeg,image/gif,*/*;q=0.5")
        if offset > 0 {
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
            request.setValue(saved?.validator, forHTTPHeaderField: "If-Range")
        }
        let (bytes, response) = try await transportSession.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw PixivFailure(code: .unreadable) }
        if offset > 0, http.statusCode == 416, canRetryRange {
            bytes.task.cancel()
            try? files.removeItem(at: image)
            try? files.removeItem(at: metadataFile)
            return try await receiveImage(from: url, limit: limit, checkpoint: checkpoint,
                                          canRetryRange: false, progress: progress)
        }
        try Self.check(response)
        let resumes = http.statusCode == 206
        let range = http.value(forHTTPHeaderField: "Content-Range").flatMap(Self.contentRange)
        if resumes {
            guard let range, range.start == offset, range.end >= range.start,
                  range.total.map({ range.end < $0 }) ?? true else { throw PixivFailure(code: .unreadable) }
        } else if http.statusCode != 200 {
            throw PixivFailure(code: .unreadable)
        }
        let start = resumes ? offset : 0
        let expected = resumes ? range?.total : (response.expectedContentLength >= 0 ? response.expectedContentLength : nil)
        guard start <= Int64(limit), expected.map({ $0 <= Int64(limit) }) ?? true else {
            throw PixivFailure(code: .tooLarge(megabytes: limit / (1024 * 1024)))
        }
        let etag = http.value(forHTTPHeaderField: "ETag")
        let validator = etag.flatMap { $0.hasPrefix("W/") ? nil : $0 }
            ?? http.value(forHTTPHeaderField: "Last-Modified") ?? (resumes ? saved?.validator : nil)
        let metadata = ImageCheckpoint(url: url, validator: validator, expected: expected)
        if !files.fileExists(atPath: image.path) { files.createFile(atPath: image.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        let handle = try FileHandle(forWritingTo: image)
        defer { try? handle.close() }
        if start == 0 { try handle.truncate(atOffset: 0) }
        try handle.seek(toOffset: UInt64(start))
        try JSONEncoder().encode(metadata).write(to: metadataFile, options: .atomic)
        var received = start
        var chunk = Data()
        chunk.reserveCapacity(65_536)
        // Cancellation retains the last short chunk too; a resume starts at the file's actual size.
        defer { if !chunk.isEmpty { try? handle.write(contentsOf: chunk) } }
        progress(received, expected)
        for try await byte in bytes {
            guard received < Int64(limit) else { throw PixivFailure(code: .tooLarge(megabytes: limit / (1024 * 1024))) }
            chunk.append(byte)
            received += 1
            if chunk.count == 65_536 {
                try handle.write(contentsOf: chunk)
                chunk.removeAll(keepingCapacity: true)
                progress(received, expected)
                try Task.checkCancellation()
            }
        }
        try handle.write(contentsOf: chunk)
        chunk.removeAll(keepingCapacity: true)
        try Task.checkCancellation()
        if let expected, received != expected { throw PixivFailure(code: .unreadable) }
        progress(received, expected)
        return try Data(contentsOf: image)
    }

    private static func contentRange(_ header: String) -> (start: Int64, end: Int64, total: Int64?)? {
        guard header.hasPrefix("bytes ") else { return nil }
        let parts = header.dropFirst(6).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let bounds = parts[0].split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2, let start = Int64(bounds[0]), let end = Int64(bounds[1]), start >= 0 else { return nil }
        let total = Int64(parts[1])
        guard parts[1] == "*" || total.map({ $0 >= 0 }) == true else { return nil }
        return (start, end, total)
    }
}
