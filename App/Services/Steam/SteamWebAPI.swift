import Foundation

/// Steam's public WebAPI (`api.steampowered.com`), the way the Steam client calls it.
/// Injected so tests never reach the network.
protocol SteamWebAPI: Sendable {
    /// Calls a service method with a protobuf request and returns the protobuf response.
    /// Throws `SteamWebAPIError` when Steam answers with an EResult other than OK.
    func call(_ service: String, _ method: String, request: Data) async throws -> SteamProto.Message
    /// A plain GET returning JSON, for the directory endpoints that have no protobuf form.
    func json(_ path: String, query: [URLQueryItem]) async throws -> Data
}

/// Steam declined a WebAPI call. `eresult` is Steam's EResult (2 Fail, 9 FileNotFound, 84 RateLimitExceeded…).
struct SteamWebAPIError: LocalizedError, Equatable {
    let method: String
    let status: Int
    let eresult: Int32?

    var errorDescription: String? {
        "Steam answered \(method) with HTTP \(status)\(eresult.map { ", EResult \($0)" } ?? "")"
    }
}

struct URLSessionSteamWebAPI: SteamWebAPI {
    static let base = URL(string: "https://api.steampowered.com/")!

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func call(_ service: String, _ method: String, request: Data) async throws -> SteamProto.Message {
        // The client's own transport: one multipart field holding the request as base64 protobuf.
        let boundary = "WallpaperMachine-\(UUID().uuidString)"
        var urlRequest = URLRequest(url: Self.base.appending(path: "\(service)/\(method)/v1/"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = Data("""
            --\(boundary)\r
            Content-Disposition: form-data; name="input_protobuf_encoded"\r
            \r
            \(request.base64EncodedString())\r
            --\(boundary)--\r

            """.utf8)
        let (data, response) = try await session.data(for: urlRequest)
        let http = response as? HTTPURLResponse
        let eresult = http?.value(forHTTPHeaderField: "x-eresult").flatMap { Int32($0) }
        guard let http, http.statusCode == 200, eresult == 1 else {
            throw SteamWebAPIError(method: method, status: http?.statusCode ?? 0, eresult: eresult)
        }
        return try SteamProto.Message(data)
    }

    func json(_ path: String, query: [URLQueryItem]) async throws -> Data {
        var url = Self.base.appending(path: path)
        url.append(queryItems: query)
        let (data, response) = try await session.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw SteamWebAPIError(method: path, status: status, eresult: nil) }
        return data
    }
}
