import Foundation

/// Keeps the Steam Community session between launches, so Your subscriptions stays signed in
/// until Steam ends the session or the person signs out. Injected so tests never touch the
/// keychain.
protocol SteamWebSessionStoring: Sendable {
    /// The saved session; nil when there is none or it cannot be read.
    func load() -> SteamWebSession?
    func save(_ session: SteamWebSession) throws
    func remove()
}

/// The session as a generic password in the user's login keychain, next to the pixiv one and
/// kept the same way (`KeychainGenericPassword` says when macOS asks before handing it over).
struct KeychainSteamWebSessionStore: SteamWebSessionStoring {
    static let service = "app.wallpapermachine.steam-community"
    static let account = "session"

    /// What is saved: the two cookie values, as Steam set them.
    private struct Saved: Codable {
        var cookie: String
        var refresh: String?
    }

    private let item: KeychainGenericPassword

    init(calls: any KeychainItemCalls = SystemKeychain()) {
        item = KeychainGenericPassword(
            service: Self.service, account: Self.account, label: "WallpaperMachine Steam Community sign-in",
            calls: calls)
    }

    func load() -> SteamWebSession? {
        let data: Data?
        do {
            data = try item.read()
        } catch {
            AppLog.warn("Steam sign-in could not be read from the keychain (\(error))")
            return nil
        }
        guard let data, let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return nil }
        return SteamWebSession(cookie: saved.cookie, refresh: saved.refresh)
    }

    func save(_ session: SteamWebSession) throws {
        let saved = Saved(cookie: session.cookie, refresh: session.refreshToken.map { "\(session.steamID)%7C%7C\($0)" })
        let data = try JSONEncoder().encode(saved)
        do {
            try item.write(data)
        } catch {
            AppLog.warn("Steam sign-in could not be saved in the keychain (\(error))")
            throw error
        }
    }

    func remove() {
        do {
            try item.delete()
        } catch {
            AppLog.warn("Steam sign-in could not be removed from the keychain (\(error))")
        }
    }
}
