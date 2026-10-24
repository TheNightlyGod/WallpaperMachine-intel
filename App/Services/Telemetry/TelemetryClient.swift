import Foundation

/// Where reports and deletion requests go.
protocol TelemetryUploading: Sendable {
    func send(_ report: Data) async throws
    func delete(install: String) async throws
}

struct TelemetryUploadError: LocalizedError, Equatable {
    var status: Int?
    var errorDescription: String? {
        status.map { "the website answered \($0)" } ?? "the website did not answer"
    }
}

/// Posts to the website's telemetry endpoint. One request at a time and no retries: a
/// failed upload waits for its caller's next turn, so a Mac that is offline wakes nothing.
struct TelemetryClient: TelemetryUploading, TelemetryActiveSending {
    static let endpoint = URL(string: "https://www.wallpapermachine.app/api/telemetry")!

    let endpoint: URL
    let session: URLSession
    let userAgent: String

    init(
        endpoint: URL = Self.endpoint,
        session: URLSession = GitHubReleaseClient.makeSession(),
        version: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    ) {
        self.endpoint = endpoint
        self.session = session
        // Cloudflare refuses a request without a product user agent.
        userAgent = "WallpaperMachine/\(version)"
    }

    func send(_ report: Data) async throws {
        try await post(report, to: endpoint)
    }

    func delete(install: String) async throws {
        let body = try JSONEncoder().encode(["install": install])
        try await post(body, to: endpoint.appendingPathComponent("delete"))
    }

    func sendActive(_ ping: Data) async throws {
        try await post(ping, to: endpoint.appendingPathComponent("active"))
    }

    private func post(_ body: Data, to url: URL) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (_, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode
        guard let status, (200..<300).contains(status) else { throw TelemetryUploadError(status: status) }
    }
}
