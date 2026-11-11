import Foundation

/// Signs in to Steam with a QR code that the person scans and approves in the Steam mobile
/// app, through Steam's own authentication service: no password ever reaches the app.
struct SteamQRSignIn: Sendable {
    /// One QR sign-in attempt. Steam may replace the URL while it waits; show the newest one.
    struct Challenge: Sendable, Equatable {
        fileprivate(set) var clientID: UInt64
        let requestID: Data
        fileprivate(set) var url: String
        let pollInterval: Duration
    }

    enum Progress: Sendable, Equatable {
        /// Nobody has approved yet; `scanned` once the phone has opened the code.
        case waiting(scanned: Bool)
        /// Steam replaced the code; show the new challenge's URL.
        case renewed(Challenge)
        case approved(SteamRefreshToken)
    }

    /// `k_EAuthTokenPlatformType_SteamClient`: the only kind of token a connection manager
    /// accepts, which downloads need.
    static let steamClientPlatform: UInt64 = 1
    static let service = "IAuthenticationService"

    private let api: any SteamWebAPI

    init(api: any SteamWebAPI = URLSessionSteamWebAPI()) {
        self.api = api
    }

    /// `deviceName` is what the person later sees under Steam's authorized devices.
    func begin(deviceName: String) async throws -> Challenge {
        var request = SteamProto.Writer()
        request.string(1, deviceName)
        request.varint(2, Self.steamClientPlatform)
        let response = try await api.call(Self.service, "BeginAuthSessionViaQR", request: request.data)
        guard let clientID = response.varint(1), let url = response.string(2), let requestID = response.bytes(3) else {
            throw SteamProto.DecodingError(reason: "BeginAuthSessionViaQR without a challenge")
        }
        let interval = Double(response.float(4) ?? 5)
        return Challenge(clientID: clientID, requestID: requestID, url: url,
                         pollInterval: .milliseconds(Int((min(max(interval, 1), 30) * 1000).rounded())))
    }

    /// Asks once whether the challenge was approved. Call it every `pollInterval`; Steam
    /// answers an expired or cancelled challenge with an error.
    func poll(_ challenge: Challenge) async throws -> Progress {
        var request = SteamProto.Writer()
        request.varint(1, challenge.clientID)
        request.bytes(2, challenge.requestID)
        let response = try await api.call(Self.service, "PollAuthSessionStatus", request: request.data)
        if let token = response.string(3), !token.isEmpty {
            return .approved(try SteamRefreshToken(token, accountName: response.string(6) ?? ""))
        }
        if let url = response.string(2), !url.isEmpty {
            var renewed = challenge
            renewed.clientID = response.varint(1) ?? challenge.clientID
            renewed.url = url
            return .renewed(renewed)
        }
        return .waiting(scanned: response.bool(5) ?? false)
    }
}
