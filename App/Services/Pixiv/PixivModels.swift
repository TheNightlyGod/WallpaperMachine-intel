import Foundation

/// A pixiv work's age rating, in the vocabulary Discover's Age rating boxes and a wallpaper
/// manifest's `contentrating` already use, plus pixiv's R-18G, which is never shown.
enum PixivRating: String, CaseIterable, Codable, Sendable {
    case everyone = "Everyone", questionable = "Questionable", mature = "Mature", grotesque = "Grotesque"

    /// pixiv marks restricted works with `xRestrict` (1 is R-18, 2 is R-18G). The rest carry a
    /// sanity level `sl` (2 is all ages, 4 and above suggestive) in search results and a
    /// `sexual` grade (0 all ages, 1 and above suggestive) in rankings, and `sensitive` is set
    /// for the works pixiv's own site blurs until a visitor opts in to sensitive content.
    init(xRestrict: Int, sanityLevel: Int?, sexual: Int?, sensitive: Bool = false) {
        if xRestrict >= 2 {
            self = .grotesque
        } else if xRestrict == 1 {
            self = .mature
        } else if sensitive || (sanityLevel ?? 0) >= 4 || (sexual ?? 0) > 0 {
            self = .questionable
        } else {
            self = .everyone
        }
    }
}

/// One pixiv illustration as a listing presents it: enough to draw its tile and to ask for its
/// pages. Rankings and search results describe the first page only.
struct PixivWork: Identifiable, Codable, Equatable, Sendable {
    /// pixiv's illustration id, decimal digits only.
    let id: String
    let title: String
    let authorID: String
    let authorName: String
    /// The listing's own thumbnail on `i.pximg.net`.
    let thumbnailURL: URL?
    let width: Int
    let height: Int
    let pageCount: Int
    let rating: PixivRating
    /// Whether pixiv flags the work as AI-generated; nil where the listing does not say
    /// (rankings, which pixiv keeps free of AI-generated works).
    let aiGenerated: Bool?
    let tags: [String]
    /// Position in a ranking; nil for search results.
    let rank: Int?

    var artworkURL: URL { URL(string: "https://www.pixiv.net/artworks/\(id)")! }

    /// The library folder, and so the wallpaper id, that page `page` of this work is saved as.
    func libraryID(page: Int) -> String { Self.libraryID(workID: id, page: page) }

    static func libraryID(workID: String, page: Int) -> String { "pixiv-\(workID)-p\(page)" }

    /// A pixiv illustration id: 1 to 12 ASCII digits, never zero.
    static func isValidID(_ value: String) -> Bool {
        (1...12).contains(value.utf8.count) && value.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }
            && value.utf8.contains { $0 != 48 }
    }
}

/// One image of a work, as `/ajax/illust/<id>/pages` lists it.
struct PixivPage: Codable, Equatable, Sendable {
    let index: Int
    let width: Int
    let height: Int
    /// pixiv's 540 px rendition, used for the inspector preview.
    let previewURL: URL?
    /// The image exactly as the artist uploaded it.
    let originalURL: URL
}

/// pixiv's illustration rankings: the ones that accept `content=illust`, so every entry is a
/// single still illustration rather than a comic or an animation. The two R-18 rankings are
/// shown only to a signed-in account that asked for R-18 works.
enum PixivRanking: String, CaseIterable, Sendable {
    case daily, weekly, monthly, rookie
    case dailyR18 = "daily_r18", weeklyR18 = "weekly_r18"

    var isR18: Bool { self == .dailyR18 || self == .weeklyR18 }

    /// The all-ages ranking an R-18 one belongs to; itself for the rest.
    var allAges: PixivRanking {
        switch self {
        case .dailyR18: .daily
        case .weeklyR18: .weekly
        default: self
        }
    }
}

/// Orders pixiv's public search offers without a Premium membership; it quietly answers a
/// popularity order with the newest works instead.
enum PixivSearchOrder: String, CaseIterable, Sendable {
    case newest = "date_d", oldest = "date"
}

enum PixivOrientation: String, CaseIterable, Sendable {
    case any, landscape, portrait
}

/// A display-class minimum resolution, whichever way round the image is.
enum PixivMinimumSize: String, CaseIterable, Sendable {
    case any, fullHD = "1920x1080", quadHD = "2560x1440", ultraHD = "3840x2160"

    /// Long and short side in pixels; nil for `any`.
    var sides: (long: Int, short: Int)? {
        switch self {
        case .any: nil
        case .fullHD: (1920, 1080)
        case .quadHD: (2560, 1440)
        case .ultraHD: (3840, 2160)
        }
    }
}

/// Which ages pixiv's search returns: all-ages works only, R-18 works only, or both.
enum PixivSearchMode: String, Sendable {
    case safe, r18, all
}

/// What pixiv itself is asked: a ranking, or a tag search with the filters its search can
/// apply on the server. Pages fetched for one listing are shared by every query with it.
enum PixivListing: Hashable, Sendable {
    case ranking(PixivRanking)
    case search(
        text: String, order: PixivSearchOrder, orientation: PixivOrientation,
        minimumSize: PixivMinimumSize, hidesAIGenerated: Bool, mode: PixivSearchMode)

    var isR18: Bool {
        switch self {
        case .ranking(let ranking): ranking.isR18
        case .search(_, _, _, _, _, let mode): mode != .safe
        }
    }
}

/// Everything the pixiv page asks for. `listing` goes to pixiv; `admits(_:)` is applied in the
/// app, because rankings accept no filters and search results still need the age rating check.
struct PixivQuery: Equatable, Sendable {
    /// Tags to search for; empty browses `ranking` instead.
    var text = ""
    var ranking = PixivRanking.daily
    var order = PixivSearchOrder.newest
    var orientation = PixivOrientation.any
    var minimumSize = PixivMinimumSize.any
    var hidesAIGenerated = false
    /// Ages to show. Mature (R-18) needs a signed-in pixiv session; see `sanitized(signedIn:)`.
    var ratings: Set<PixivRating> = [.everyone]

    /// The ratings the page offers as boxes; R-18G is never among them.
    static let offeredRatings: [PixivRating] = [.everyone, .questionable, .mature]

    var listing: PixivListing {
        let words = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !words.isEmpty else { return .ranking(ranking) }
        let mature = ratings.contains(.mature)
        let mode: PixivSearchMode =
            !mature ? .safe : ratings.contains(.everyone) || ratings.contains(.questionable) ? .all : .r18
        return .search(
            text: words, order: order, orientation: orientation, minimumSize: minimumSize,
            hidesAIGenerated: hidesAIGenerated, mode: mode)
    }

    /// The query as it may be asked: without a pixiv session, or without the Mature box, it
    /// asks for no R-18 works and an R-18 ranking falls back to its all-ages counterpart.
    func sanitized(signedIn: Bool) -> PixivQuery {
        var query = self
        if !signedIn { query.ratings.remove(.mature) }
        query.ratings.remove(.grotesque)
        if !query.ratings.contains(.mature) { query.ranking = query.ranking.allAges }
        return query
    }

    func admits(_ work: PixivWork) -> Bool {
        guard ratings.contains(work.rating), work.rating != .grotesque else { return false }
        if hidesAIGenerated, work.aiGenerated == true { return false }
        switch orientation {
        case .any: break
        case .landscape: guard work.width > work.height else { return false }
        case .portrait: guard work.height > work.width else { return false }
        }
        if let sides = minimumSize.sides {
            guard max(work.width, work.height) >= sides.long, min(work.width, work.height) >= sides.short
            else { return false }
        }
        return true
    }
}

/// The pixiv account whose session the app holds, as pixiv reports it.
struct PixivAccount: Equatable, Sendable {
    let id: String
    let name: String
    /// Whether the account's viewing restrictions let it see R-18 works; nil when pixiv does
    /// not say, in which case asking is the only way to find out.
    let showsR18: Bool?
}

/// One page of a listing: the works on it that can become wallpapers, in pixiv's order.
struct PixivResultPage: Equatable, Sendable {
    let works: [PixivWork]
    let page: Int
    let totalPages: Int
    let totalCount: Int
}

struct PixivFailure: LocalizedError, Equatable, Sendable {
    enum Code: Equatable, Sendable {
        /// The request never got an HTTP answer; carries the system's description.
        case network(String)
        case status(Int)
        /// pixiv's Cloudflare front refused the connection before pixiv saw it (blocked network,
        /// proxy node or client signature, or a browser check the app cannot pass); carries
        /// Cloudflare's error reference (1010, 1020, …) when its block page names one.
        case blockedByProtection(reference: Int?)
        /// The answer was not the JSON pixiv documents for this request.
        case unreadable
        /// pixiv answered but shows this work to signed-in members only.
        case membersOnly
        case tooLarge(megabytes: Int)
        case notAnImage
        /// The bytes start like an image but do not decode as one.
        case undecodable
        /// The session the app holds no longer signs anyone in.
        case signedOut
        /// Signed in, but pixiv will not show this account R-18 works.
        case r18Hidden
        /// The keychain refused the session, so it lasts until the app quits.
        case notSaved
    }

    let code: Code

    var errorDescription: String? {
        switch code {
        case .network(let detail):
            String(localized: "Couldn’t reach pixiv: \(detail)")
        case .status(404):
            String(localized: "pixiv has nothing at this address any more. The work may have been deleted, or the ranking has no more pages.")
        case .status(429):
            String(localized: "pixiv is limiting requests from this network right now. Wait a minute, then try again.")
        case .status(403):
            String(localized: "pixiv denied access to this request (HTTP 403). Check access in your browser and your network or proxy connection before retrying.")
        case .blockedByProtection(let reference?):
            String(localized: "pixiv’s protection service blocked this connection (Cloudflare error \(reference)). It blocks some networks and proxy nodes even when a browser still opens pixiv. Switch to another proxy node or network, then try again.")
        case .blockedByProtection(nil):
            String(localized: "pixiv’s protection service blocked this connection with a browser check WallpaperMachine can’t complete. It blocks some networks and proxy nodes even when a browser still opens pixiv. Switch to another proxy node or network, then try again.")
        case .status(let status):
            String(localized: "pixiv returned status \(status). Try again later.")
        case .unreadable:
            String(localized: "pixiv sent an answer this version of WallpaperMachine can’t read. Try again, or open the work on pixiv.")
        case .membersOnly:
            String(localized: "pixiv shows this work only to signed-in members, or only to the artist’s followers. Sign in to pixiv, or open the work there.")
        case .tooLarge(let megabytes):
            String(localized: "The image is larger than the \(megabytes) MB WallpaperMachine accepts.")
        case .notAnImage:
            String(localized: "pixiv sent a file that is not a JPEG, PNG or GIF image.")
        case .undecodable:
            String(localized: "The downloaded image couldn’t be read. Try downloading it again.")
        case .signedOut:
            String(localized: "pixiv didn’t accept the sign-in. Sign in to pixiv again.")
        case .r18Hidden:
            String(localized: "pixiv won’t show R-18 works to this account. Turn them on in pixiv’s settings under Viewing restrictions, then refresh.")
        case .notSaved:
            String(localized: "Signed in, but the keychain didn’t keep the sign-in, so you’ll need to sign in again after WallpaperMachine quits.")
        }
    }
}
