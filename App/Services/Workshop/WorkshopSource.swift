import Foundation

/// Where Discover's tiles come from.
enum WorkshopSource: Equatable, Sendable {
    /// The Workshop's wallpapers, searched, filtered and sorted by Steam.
    case browse
    /// The Workshop's collections, searched and sorted by Steam.
    case collections
    /// The wallpapers in one collection, in the collection's own order.
    case collection(id: String, title: String)
    /// One author's wallpapers.
    case creator(id: String, name: String)
    /// The wallpapers the signed-in Steam account subscribes to.
    case subscriptions
    /// The wallpapers the signed-in Steam account marked as favorites, in the order it chose.
    case favorites

    /// A list of the signed-in account's own, which Steam reads with its session.
    var isPersonal: Bool { self == .subscriptions || self == .favorites }

    /// Whether Steam searches and sorts it; the others are shown in their own order.
    var isSearchable: Bool {
        switch self {
        case .browse, .collections: true
        default: false
        }
    }

    /// The name the panel knows it by.
    var key: String {
        switch self {
        case .browse: "browse"
        case .collections: "collections"
        case .collection: "collection"
        case .creator: "creator"
        case .subscriptions: "subscriptions"
        case .favorites: "favorites"
        }
    }

    /// The collection's or author's Workshop id; nil for the lists.
    var id: String? {
        switch self {
        case .collection(let id, _), .creator(let id, _): id
        default: nil
        }
    }

    /// The collection's title or the author's name, as it was when opened.
    var name: String? {
        switch self {
        case .collection(_, let title): title
        case .creator(_, let name): name
        default: nil
        }
    }
}

/// The orders Steam offers a favorites list in, as its own `sortmethod` values.
enum WorkshopFavoritesOrder: String, CaseIterable, Identifiable, Sendable {
    case dateFavorited = "subscriptiondate"
    case alphabetical = "alpha"
    case lastUpdated = "lastupdated"
    case dateCreated = "creationorder"

    var id: String { rawValue }
}

/// Which of a profile's Workshop lists a page reads.
enum WorkshopProfileList: Equatable, Sendable {
    /// The items the account published.
    case items
    case subscriptions
    case favorites(WorkshopFavoritesOrder)
}

/// A signed-in Steam Community session, taken from Steam's own sign-in page. It is sent to
/// steamcommunity.com alone, to read the list of the account's subscriptions; its renewal token
/// goes to Steam's token service alone. `SteamWebSessionStoring` keeps it between launches.
struct SteamWebSession: Equatable, Sendable {
    /// The account's SteamID64, which the cookie starts with.
    let steamID: String
    /// The `steamLoginSecure` cookie's value, exactly as Steam set it.
    let cookie: String
    /// The token in Steam's `steamRefresh_steam` cookie, which Steam trades for a new
    /// `steamLoginSecure` for months after the sign-in; nil when the page set none.
    let refreshToken: String?
    /// When the cookie's own token runs out, as the token says; nil when it does not say.
    let expiresAt: Date?

    /// Reads a `steamLoginSecure` value, `<SteamID64>||<token>` with the bars percent-encoded or
    /// not; anything else is not a session. `refresh` is the `steamRefresh_steam` value, in the
    /// same form; one of another account, or of any other shape, is left out.
    init?(cookie value: String, refresh: String? = nil) {
        guard let (id, token) = Self.parts(of: value) else { return nil }
        steamID = id
        cookie = value
        expiresAt = Self.expiry(of: token)
        refreshToken = refresh.flatMap(Self.parts(of:)).flatMap { $0.0 == id ? $0.1 : nil }
    }

    /// The same session with the cookie Steam's token service made from `accessToken`; nil when
    /// that is not a token.
    func renewed(accessToken: String) -> SteamWebSession? {
        guard let fresh = SteamWebSession(cookie: "\(steamID)%7C%7C\(accessToken)") else { return nil }
        return SteamWebSession(
            steamID: steamID, cookie: fresh.cookie, refreshToken: refreshToken, expiresAt: fresh.expiresAt)
    }

    /// Whether the cookie has run out, or will within `margin`, and can be renewed.
    func needsRenewal(at now: Date, margin: TimeInterval = 120) -> Bool {
        guard refreshToken != nil, let expiresAt else { return false }
        return expiresAt.timeIntervalSince(now) < margin
    }

    private init(steamID: String, cookie: String, refreshToken: String?, expiresAt: Date?) {
        self.steamID = steamID
        self.cookie = cookie
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }

    /// The SteamID64 and token of `<SteamID64>||<token>`.
    private static func parts(of value: String) -> (String, String)? {
        let decoded = value.replacingOccurrences(of: "%7C", with: "|", options: .caseInsensitive)
        let parts = decoded.components(separatedBy: "||")
        guard parts.count == 2, let id = parts.first, Self.isSteamID(id),
              let token = parts.last, token.count >= 16, value.count <= 4096,
              token.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) })
        else { return nil }
        return (id, token)
    }

    /// The `exp` of a JSON Web Token, read without checking its signature: it only decides when
    /// to ask Steam for a new one, and Steam checks the token itself.
    static func expiry(of token: String) -> Date? {
        let sections = token.split(separator: ".", omittingEmptySubsequences: false)
        guard sections.count == 3 else { return nil }
        var payload = sections[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = (claims["exp"] as? NSNumber)?.doubleValue
        else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    /// Whether `id` has the form of a SteamID64: 17 ASCII digits.
    static func isSteamID(_ id: String) -> Bool {
        id.count == 17 && id.allSatisfy { $0.isASCII && $0.isNumber }
    }
}

/// Steam answered with its sign-in page: the session ended or was never there.
struct SteamSignInRequired: LocalizedError {
    var errorDescription: String? {
        String(localized: "Steam asked you to sign in again. Sign in to Steam to see your subscriptions.")
    }
}
