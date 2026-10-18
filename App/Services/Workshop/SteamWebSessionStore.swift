import Foundation
import Security

/// Keeps the Steam Community session between launches, so Your subscriptions stays signed in
/// until Steam ends the session or the person signs out. Injected so tests never touch the
/// keychain.
protocol SteamWebSessionStoring: Sendable {
    /// The saved session; nil when there is none or it cannot be read.
    func load() -> SteamWebSession?
    func save(_ session: SteamWebSession) throws
    func remove()
}

/// The keychain refused the item.
struct KeychainSaveFailed: Error {
    let status: OSStatus
}

/// The session as a generic password in the user's login keychain, next to the pixiv one and
/// kept the same way: releases share one designated requirement, so an update reads what the
/// version before it saved; a locally built, ad-hoc signed app is a different app to the
/// keychain, and macOS asks once whether it may read the item.
struct KeychainSteamWebSessionStore: SteamWebSessionStoring {
    static let service = "app.wallpapermachine.steam-community"
    static let account = "session"

    /// What is saved: the two cookie values, as Steam set them.
    private struct Saved: Codable {
        var cookie: String
        var refresh: String?
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
    }

    func load() -> SteamWebSession? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        guard status == errSecSuccess else {
            if status != errSecItemNotFound { AppLog.warn("Steam sign-in could not be read from the keychain (\(status))") }
            return nil
        }
        guard let data = item as? Data, let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return nil }
        return SteamWebSession(cookie: saved.cookie, refresh: saved.refresh)
    }

    func save(_ session: SteamWebSession) throws {
        let saved = Saved(cookie: session.cookie, refresh: session.refreshToken.map { "\(session.steamID)%7C%7C\($0)" })
        let data = try JSONEncoder().encode(saved)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status != errSecSuccess {
            // Missing, or saved by a build this one may not change: start over.
            if status != errSecItemNotFound { SecItemDelete(query as CFDictionary) }
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "WallpaperMachine Steam Community sign-in"
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            AppLog.warn("Steam sign-in could not be saved in the keychain (\(status))")
            throw KeychainSaveFailed(status: status)
        }
    }

    func remove() {
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess, status != errSecItemNotFound {
            AppLog.warn("Steam sign-in could not be removed from the keychain (\(status))")
        }
    }
}
