import Foundation
import Security

/// Keeps the QR sign-in between launches. Injected so tests never touch the keychain.
protocol SteamClientTokenStoring: Sendable {
    /// The saved sign-in; nil when there is none or it cannot be read. Asynchronous so a test
    /// can hold the answer by suspending, never by blocking a thread; the keychain's own read
    /// is synchronous and runs off the main actor.
    func load() async -> SteamRefreshToken?
    func save(_ token: SteamRefreshToken) throws
    /// Throws when the saved sign-in stays: a log-out must not report what did not happen.
    func remove() throws
}

/// The keychain kept the saved sign-in it was asked to delete, as it does for an item another
/// build saved; `reason` is macOS's own wording.
struct SteamClientTokenRemovalFailed: LocalizedError {
    let reason: String
    var errorDescription: String? { reason }
}

/// The refresh token as a generic password in the user's login keychain, beside the Steam
/// Community sign-in and kept the same way (`KeychainGenericPassword` says when macOS asks
/// before handing it over). The token stands in for the password, so it is kept nowhere else.
struct KeychainSteamClientTokenStore: SteamClientTokenStoring {
    static let service = "app.wallpapermachine.steam-client"
    static let account = "refresh-token"

    private struct Saved: Codable {
        var accountName: String
        var token: String
    }

    private let item: KeychainGenericPassword

    init(calls: any KeychainItemCalls = SystemKeychain()) {
        item = KeychainGenericPassword(
            service: Self.service, account: Self.account, label: "WallpaperMachine Steam sign-in (QR code)",
            calls: calls)
    }

    func load() -> SteamRefreshToken? {
        let data: Data?
        do {
            data = try item.read()
        } catch {
            AppLog.warn("Steam QR sign-in could not be read from the keychain (\(error))")
            return nil
        }
        guard let data, let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return nil }
        do {
            return try SteamRefreshToken(saved.token, accountName: saved.accountName)
        } catch {
            AppLog.warn("The saved Steam QR sign-in is unusable and is ignored (\(error.localizedDescription))")
            return nil
        }
    }

    func save(_ token: SteamRefreshToken) throws {
        let data = try JSONEncoder().encode(Saved(accountName: token.accountName, token: token.value))
        do {
            try item.write(data)
        } catch {
            AppLog.warn("Steam QR sign-in could not be saved in the keychain (\(error))")
            throw error
        }
    }

    /// Deletes the item, or empties it when the keychain refuses: macOS will not let one build
    /// delete what another saved, but lets it change the data, and an emptied item loads as no
    /// sign-in. Throws only when the token stays readable.
    func remove() throws {
        do {
            try item.delete()
        } catch {
            do {
                try item.write(Data())
                AppLog.info("Steam QR sign-in could not be deleted from the keychain (\(error)); it was emptied instead")
            } catch {
                AppLog.warn("Steam QR sign-in could not be removed from the keychain (\(error))")
                let reason = (error as? KeychainFailure).flatMap { SecCopyErrorMessageString($0.status, nil) as String? }
                throw SteamClientTokenRemovalFailed(reason: reason ?? String(describing: error))
            }
        }
    }
}
