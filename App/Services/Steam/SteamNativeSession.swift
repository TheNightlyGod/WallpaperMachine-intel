import Foundation
import Observation

/// The Steam sign-in made with a QR code, and the one Steam connection the downloads that use
/// it share. The refresh token lives in the keychain; no password is involved.
@MainActor
@Observable
final class SteamNativeSession {
    /// A QR sign-in in progress.
    enum QRState: Equatable {
        case idle
        case starting
        /// Show `url` as a QR code; `scanned` once the phone opened it.
        case waiting(url: String, scanned: Bool)
        case failed(QRFailure)
    }

    /// Why a QR sign-in stopped. The panel words it in its own language when it shows it.
    enum QRFailure: Equatable {
        /// Steam no longer knows the code: it expired or was cancelled on the phone.
        case expired
        /// Steam could not be reached.
        case unreachable
        case failed
    }

    enum Failure: LocalizedError, Equatable {
        case notSignedIn
        case signInExpired

        var errorDescription: String? {
            switch self {
            case .notSignedIn: String(localized: "Sign in to Steam with a QR code first.")
            case .signInExpired: String(localized: "Steam no longer accepts this QR sign-in. Sign in again with a QR code.")
            }
        }
    }

    /// Logon answers that mean the token itself is no longer good: InvalidPassword,
    /// AccessDenied, Expired and Revoked. Anything else (rate limits, Steam being down) keeps it.
    static let rejectedTokenResults: Set<Int32> = [5, 15, 27, 26]

    private(set) var token: SteamRefreshToken?
    private(set) var qr = QRState.idle
    var accountName: String? { token?.accountName }
    var isSignedIn: Bool { token != nil }

    @ObservationIgnored private let store: any SteamClientTokenStoring
    @ObservationIgnored private let signIn: SteamQRSignIn
    @ObservationIgnored private let makeConnection: @MainActor () -> SteamCMConnection
    @ObservationIgnored private let makeClient: @MainActor (SteamCMConnection) -> SteamContentClient
    @ObservationIgnored private let deviceName: String
    @ObservationIgnored private var connection: SteamCMConnection?
    @ObservationIgnored private var client: SteamContentClient?
    @ObservationIgnored private var connecting: Task<SteamContentClient, any Error>?
    /// Counts logons; one that is no longer the latest closes its connection when it answers.
    @ObservationIgnored private var logOnAttempt = 0
    /// Counts sign-ins and sign-outs, so a keychain read that finishes after one is dropped.
    @ObservationIgnored private var signInChanges = 0
    /// The QR attempt under way; tests await it to see where a cancelled one ended.
    @ObservationIgnored private(set) var qrTask: Task<Void, Never>?
    @ObservationIgnored private var users = 0
    @ObservationIgnored private var idleDisconnect: Task<Void, Never>?
    /// Called on the main actor after a QR sign-in was approved and saved, or after sign-out.
    @ObservationIgnored var onChange: (@MainActor () -> Void)?

    init(store: any SteamClientTokenStoring = KeychainSteamClientTokenStore(),
         signIn: SteamQRSignIn = SteamQRSignIn(),
         deviceName: String = "WallpaperMachine on \(Host.current().localizedName ?? "Mac")",
         makeConnection: @escaping @MainActor () -> SteamCMConnection = {
             SteamCMConnection(downloadRegion: { .current })
         },
         makeClient: @escaping @MainActor (SteamCMConnection) -> SteamContentClient = { SteamContentClient(connection: $0) }) {
        self.store = store
        self.signIn = signIn
        self.deviceName = deviceName
        self.makeConnection = makeConnection
        self.makeClient = makeClient
    }

    /// Reads the saved sign-in off the main thread: the keychain may ask first.
    func restore() async {
        let store = store
        let changes = signInChanges
        let saved = await Task.detached(priority: .utility) { await store.load() }.value
        // A sign-out (or a new sign-in) made while the keychain answered is the newer word.
        guard changes == signInChanges, token == nil, let saved else { return }
        if saved.isExpired() {
            // Best effort: a launch that cannot delete it finds it expired again.
            try? store.remove()
            return
        }
        token = saved
    }

    // MARK: - QR sign-in

    /// Starts a QR sign-in, replacing one already showing. The code renews itself until it is
    /// approved, it fails, or `cancelQRSignIn()` is called.
    func beginQRSignIn() {
        // The keychain read of a launch may still be on its way: the code shown now is the
        // newer word, so that read must not sign in the old account under it.
        signInChanges += 1
        qrTask?.cancel()
        qr = .starting
        qrTask = Task { [weak self, signIn, deviceName] in
            do {
                var challenge = try await signIn.begin(deviceName: deviceName)
                // Each answer is checked against a cancellation made while it was on its way:
                // a code closed on screen must not show again or sign in.
                try Task.checkCancellation()
                self?.qr = .waiting(url: challenge.url, scanned: false)
                while !Task.isCancelled {
                    try await Task.sleep(for: challenge.pollInterval)
                    let progress = try await signIn.poll(challenge)
                    try Task.checkCancellation()
                    switch progress {
                    case .waiting(let scanned):
                        self?.qr = .waiting(url: challenge.url, scanned: scanned)
                    case .renewed(let next):
                        challenge = next
                        self?.qr = .waiting(url: next.url, scanned: false)
                    case .approved(let token):
                        try self?.adopt(token)
                        return
                    }
                }
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                AppLog.warn("Steam QR sign-in failed (\(error.localizedDescription))")
                self?.qr = .failed(Self.qrFailure(for: error))
            }
        }
    }

    func cancelQRSignIn() {
        qrTask?.cancel()
        qrTask = nil
        qr = .idle
    }

    private func adopt(_ newToken: SteamRefreshToken) throws {
        try store.save(newToken)
        signInChanges += 1
        disconnect()
        token = newToken
        qr = .idle
        qrTask = nil
        AppLog.info("Signed in to Steam with a QR code as \(newToken.accountName)")
        onChange?()
    }

    /// Forgets the sign-in on this Mac. Steam keeps the device listed under the account's
    /// authorized devices until the person removes it there. Throws, still signed in, when the
    /// keychain keeps the saved token: the next launch would restore it.
    func signOut() throws {
        try store.remove()
        signInChanges += 1
        cancelQRSignIn()
        disconnect()
        token = nil
        onChange?()
    }

    // MARK: - Shared connection

    /// A content client logged on with the saved token, shared by every download that runs.
    /// Pair each call with `release()` once the download is done with it.
    func contentClient() async throws -> SteamContentClient {
        guard let token else { throw Failure.notSignedIn }
        guard !token.isExpired() else {
            forgetRejectedToken()
            throw Failure.signInExpired
        }
        users += 1
        idleDisconnect?.cancel()
        if let client, let connection, await connection.isLoggedOn { return client }
        // Every job waiting for a logon shares the one under way, and its failure reads the
        // same for each of them.
        let logOn = connecting ?? startLogOn(with: token)
        do {
            return try await Self.waitFor(logOn)
        } catch {
            release()
            throw Self.mapped(error)
        }
    }

    /// Logs on in a task of its own, so a job that is paused or cancelled stops waiting at
    /// once while the logon goes on for the jobs that still need it. A logon overtaken by a
    /// sign-out, a new sign-in or an idle disconnect closes its connection instead of adopting it.
    private func startLogOn(with token: SteamRefreshToken) -> Task<SteamContentClient, any Error> {
        // A connection that dropped is closed before another one opens.
        if connection != nil { disconnect() }
        let connection = makeConnection()
        let client = makeClient(connection)
        let deviceName = deviceName
        logOnAttempt += 1
        let attempt = logOnAttempt
        let task = Task { [weak self] () throws -> SteamContentClient in
            do {
                try await connection.logOn(with: token, machineName: deviceName)
            } catch {
                self?.logOnFailed(error, attempt: attempt, token: token)
                throw error
            }
            guard let self, self.adoptLogOn(connection, client, attempt: attempt, token: token) else {
                await connection.logOff()
                throw Failure.notSignedIn
            }
            return client
        }
        connecting = task
        return task
    }

    private func isCurrent(_ attempt: Int, _ token: SteamRefreshToken) -> Bool {
        logOnAttempt == attempt && self.token == token
    }

    private func logOnFailed(_ error: any Error, attempt: Int, token: SteamRefreshToken) {
        guard isCurrent(attempt, token) else { return }
        connecting = nil
        if Self.mapped(error) as? Failure == .signInExpired { forgetRejectedToken() }
    }

    private func adoptLogOn(_ connection: SteamCMConnection, _ client: SteamContentClient, attempt: Int,
                           token: SteamRefreshToken) -> Bool {
        guard isCurrent(attempt, token) else { return false }
        connecting = nil
        self.connection = connection
        self.client = client
        // Every job that asked for it was paused or cancelled meanwhile.
        if users == 0 { scheduleIdleDisconnect() }
        return true
    }

    /// The logon's client, or `CancellationError` as soon as the waiting job is cancelled.
    private static func waitFor(_ logOn: Task<SteamContentClient, any Error>) async throws -> SteamContentClient {
        try Task.checkCancellation()
        let waiter = LogOnWaiter()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiter.install(continuation)
                Task { @MainActor in waiter.finish(await logOn.result) }
            }
        } onCancel: {
            Task { @MainActor in waiter.finish(.failure(CancellationError())) }
        }
    }

    /// One job's wait for the shared logon: the first outcome wins, a later one is ignored.
    @MainActor
    private final class LogOnWaiter {
        private var continuation: CheckedContinuation<SteamContentClient, any Error>?
        private var outcome: Result<SteamContentClient, any Error>?

        func install(_ continuation: CheckedContinuation<SteamContentClient, any Error>) {
            if let outcome { continuation.resume(with: outcome) } else { self.continuation = continuation }
        }

        func finish(_ result: Result<SteamContentClient, any Error>) {
            guard outcome == nil else { return }
            outcome = result
            continuation?.resume(with: result)
            continuation = nil
        }
    }

    /// A logon refusal that means the token itself is no longer good becomes `signInExpired`.
    private static func mapped(_ error: any Error) -> any Error {
        if case SteamCMConnection.Failure.logOnRefused(let eresult)? = error as? SteamCMConnection.Failure,
           rejectedTokenResults.contains(eresult) {
            return Failure.signInExpired
        }
        return error
    }

    /// A download is done with the connection; it closes a minute after the last one.
    func release() {
        users = max(users - 1, 0)
        guard users == 0 else { return }
        scheduleIdleDisconnect()
    }

    private func scheduleIdleDisconnect() {
        idleDisconnect?.cancel()
        idleDisconnect = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled, let self, self.users == 0 else { return }
            self.disconnect()
        }
    }

    private func forgetRejectedToken() {
        AppLog.warn("Steam no longer accepts the saved QR sign-in; it was removed")
        signInChanges += 1
        disconnect()
        // The store empties what the keychain will not delete; one it cannot even empty is
        // refused again at the next logon and removed then.
        try? store.remove()
        token = nil
        onChange?()
    }

    private func disconnect() {
        idleDisconnect?.cancel()
        idleDisconnect = nil
        // A logon still under way is overtaken: it closes its connection when it answers.
        logOnAttempt += 1
        connecting = nil
        if let connection { Task { await connection.logOff() } }
        connection = nil
        client = nil
    }

    static func qrFailure(for error: any Error) -> QRFailure {
        if let refused = error as? SteamWebAPIError, refused.eresult == 9 || refused.eresult == 27 { return .expired }
        if error is URLError { return .unreachable }
        return .failed
    }
}
