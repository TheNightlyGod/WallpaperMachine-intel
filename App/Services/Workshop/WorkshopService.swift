import Foundation

struct WorkshopItem: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let title: String
    var creator: String
    let summary: String
    let previewURL: URL?
    let tags: [String]
    let size: Int64
    let subscriptions: Int
    /// The author's SteamID64, when the source said; it opens the author's other items.
    var creatorID: String?
    /// When the author last changed the item on the Workshop.
    var timeUpdated: Date?
    /// Set when the item is a collection: how many items it holds, or 0 when unknown. A
    /// collection is opened, never downloaded.
    var collectionSize: Int?

    var kind: WorkshopKind {
        WorkshopKind.allCases.first { $0 != .all && tags.contains($0.rawValue) } ?? .all
    }
    var pageURL: URL { Self.pageURL(id: id) }
    /// The item's page on Steam; `id` is digits only.
    static func pageURL(id: String) -> URL { URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(id)")! }
}

enum WorkshopKind: String, CaseIterable, Identifiable, Sendable {
    case all = "All types", scene = "Scene", video = "Video", web = "Web", application = "Application"
    var id: String { rawValue }
    var compatibility: String {
        switch self {
        case .scene: String(localized: "Scene · experimental renderer")
        case .video: String(localized: "Video · codec dependent")
        case .web: String(localized: "Web · built-in web view")
        case .application: String(localized: "Application · unsupported on macOS")
        case .all: String(localized: "Compatibility checked after download")
        }
    }
}

/// Sort orders Steam's public browse page actually honours. The raw value is the stable key
/// shared with the web panel; `browseSort` and `days` are what the request sends. Steam has no
/// public "most voted" sort: unknown `browsesort` values silently fall back to trending.
/// `updated` is Steam's `lastupdated`: items by the time they last changed, newest first, with
/// search text and tags applied like any other sort.
enum WorkshopSort: String, CaseIterable, Identifiable, Sendable {
    case topRated = "toprated"
    case trendingToday = "trend-today", trending = "trend", trendingMonth = "trend-month", trendingYear = "trend-year"
    case popular = "totaluniquesubscribers", newest = "mostrecent", updated = "lastupdated", relevance = "textsearch"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .topRated: String(localized: "Highest rated")
        case .trendingToday: String(localized: "Most popular today")
        case .trending: String(localized: "Trending this week")
        case .trendingMonth: String(localized: "Most popular this month")
        case .trendingYear: String(localized: "Most popular this year")
        case .popular: String(localized: "Most subscribed")
        case .newest: String(localized: "Newest")
        case .updated: String(localized: "Recently updated")
        case .relevance: String(localized: "Relevance")
        }
    }
    /// Steam's `browsesort` query value.
    var browseSort: String {
        switch self {
        case .trendingToday, .trending, .trendingMonth, .trendingYear: "trend"
        default: rawValue
        }
    }
    /// Steam's `days` window; only trending sorts read it, the others ignore it.
    var days: Int {
        switch self {
        case .trendingToday: 1
        case .trendingMonth: 30
        case .trendingYear: 365
        default: 7
        }
    }
}

struct WorkshopPage: Sendable {
    var items: [WorkshopItem]
    let page: Int
    let totalPages: Int
    let totalCount: Int
    /// A name for the source the page came from when it has one, such as an author's.
    var title: String?
    /// Set when Steam's page could not be read the usual way and the items were found from the
    /// links it still carries: the list may be incomplete and its totals are estimates.
    var isDegraded = false
}

/// Wallpaper Engine's Steam app id; every Workshop request is scoped to it.
enum WorkshopApp {
    static let id = 431960
}

struct WorkshopFailure: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

/// A browse page that lacks what this app reads it by, its render context or the
/// `workshop_browse` query inside it: Steam has changed its markup. A type of its own, so
/// `WorkshopService.browse` can fall back to the item links the page still carries.
struct WorkshopLayoutChanged: LocalizedError, Sendable {
    static var message: String {
        String(localized: "Steam changed its public page or requires a browser sign-in. Open Workshop on Steam, then retry.")
    }
    var errorDescription: String? { Self.message }
}

/// Steam answered the browse query with `eresult` 10 (busy): its Workshop search had more
/// queries queued than it takes. Not a layout change; `WorkshopService` asks again before
/// showing it.
struct WorkshopBusy: LocalizedError, Sendable {
    static var message: String { String(localized: "Steam’s Workshop is busy. Try again in a moment.") }
    var errorDescription: String? { Self.message }
}

actor WorkshopService {
    /// Steam's public browse page clamps `numperpage` to 30 and `total_pages` to 1000, so a single
    /// query can only ever expose the first 30,000 results; the panel explains that cap.
    static let pageSize = 30
    static let maxPages = 1000
    private let session: URLSession
    /// The pauses before each new request for a browse page Steam answered busy.
    private let busyRetryDelays: [Duration]

    init(session: URLSession = .shared, busyRetryDelays: [Duration] = [.seconds(1), .seconds(3)]) {
        self.session = session
        self.busyRetryDelays = busyRetryDelays
    }

    static func browseURL(search: String, kind: WorkshopKind, sort: WorkshopSort, page: Int, tags: [String] = [],
                          excludedTags: [String] = [], section: String = "readytouseitems") -> URL {
        var items: [(String, String)] = [
            ("appid", String(WorkshopApp.id)),
            ("section", section),
            ("browsesort", sort.browseSort),
            ("searchtext", search),
            ("p", String(max(1, page))),
            ("numperpage", String(pageSize)),
            ("days", String(sort.days)),
            ("l", "english"),
        ]
        var required: [String] = []
        if kind != .all { required.append(kind.rawValue) }
        for tag in tags where !required.contains(tag) { required.append(tag) }
        items += required.map { ("requiredtags[]", $0) }
        var excluded: [String] = []
        for tag in excludedTags where !required.contains(tag) && !excluded.contains(tag) { excluded.append(tag) }
        items += excluded.map { ("excludedtags[]", $0) }

        // Every value is escaped down to unreserved characters: `URLComponents` would leave `+`
        // (a space to Steam), and a search such as "rain & snow" must stay one parameter.
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var components = URLComponents()
        components.scheme = "https"
        components.host = "steamcommunity.com"
        components.path = "/workshop/browse/"
        components.percentEncodedQuery = items.map { name, value in
            (name.addingPercentEncoding(withAllowedCharacters: unreserved) ?? name) + "="
                + (value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "")
        }.joined(separator: "&")
        return components.url!
    }

    func browse(search: String, kind: WorkshopKind, sort: WorkshopSort, page: Int, tags: [String] = [],
                excludedTags: [String] = []) async throws -> WorkshopPage {
        let url = Self.browseURL(search: search, kind: kind, sort: sort, page: page, tags: tags, excludedTags: excludedTags)
        let (html, decoded) = try await browsePage(url) { html -> (String, WorkshopPage?) in
            do { return (html, try Self.decodePage(html)) } catch is WorkshopLayoutChanged { return (html, nil) }
        }
        if let decoded { return decoded }
        return try await degradedPage(html: html, page: page, original: WorkshopLayoutChanged())
    }

    /// A browse page, decoded. While Steam answers it busy the page is requested again after
    /// each of `busyRetryDelays`; after the last, `WorkshopBusy` stands.
    private func browsePage<T>(_ url: URL, decode: (String) throws -> T) async throws -> T {
        var delays = busyRetryDelays[...]
        while true {
            let html = try await communityPage(url)
            do {
                return try decode(html)
            } catch is WorkshopBusy where !delays.isEmpty {
                try await Task.sleep(for: delays.removeFirst())
            }
        }
    }

    private var loggedDegradedPage = false

    /// A browse page whose markup this app no longer reads, shown from the item links it still
    /// carries: Steam's own order, each item's details from the public endpoint (which drops
    /// whatever is not a Wallpaper Engine item), and totals that can only be estimated. With no
    /// item found the original failure stands, so an unreadable page never passes for an empty list.
    private func degradedPage(html: String, page: Int, original: WorkshopLayoutChanged) async throws -> WorkshopPage {
        let ids = Self.itemIDs(in: html, limit: Self.pageSize)
        guard !ids.isEmpty else { throw original }
        let served = Dictionary(try await details(ids: ids).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let items = ids.compactMap { served[$0] }
        guard !items.isEmpty else { throw original }
        if !loggedDegradedPage {
            loggedDegradedPage = true
            AppLog.warn("Steam's Workshop page no longer has the data this app reads it by; listing the items its links name instead")
        }
        let number = max(1, page)
        // A full page of links suggests another page after it; a short one is taken as the last.
        return WorkshopPage(
            items: items, page: number, totalPages: ids.count >= Self.pageSize ? number + 1 : number,
            totalCount: (number - 1) * Self.pageSize + items.count, isDegraded: true)
    }

    /// A Steam Community page as text. `account` adds its session cookie, and only ever to a
    /// steamcommunity.com address.
    private func communityPage(_ url: URL, account: SteamWebSession? = nil) async throws -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = 35
        request.setValue("WallpaperMachine/1.0 (macOS; public Workshop browser)", forHTTPHeaderField: "User-Agent")
        var redirects: SteamCookieRedirectGuard?
        if let account, Self.mayCarrySession(url) {
            request.httpShouldHandleCookies = false
            request.setValue("steamLoginSecure=\(account.cookie)", forHTTPHeaderField: "Cookie")
            redirects = SteamCookieRedirectGuard()
        }
        let (data, response) = try await session.data(for: request, delegate: redirects)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw WorkshopFailure(message: String(localized: "Steam could not load the Workshop. Check your connection or open Steam in your browser, then retry."))
        }
        guard data.count < 12_000_000, let html = String(data: data, encoding: .utf8) else {
            throw WorkshopFailure(message: String(localized: "Steam returned an unreadable Workshop page. Try again or browse on Steam."))
        }
        return html
    }

    /// The Steam session cookie goes to steamcommunity.com over HTTPS and nowhere else.
    static func mayCarrySession(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.scheme == "https" && url.host == "steamcommunity.com" && url.port == nil && url.user == nil
    }

    /// A redirect keeps the session cookie only while it stays where `mayCarrySession` allows.
    static func redirected(_ request: URLRequest) -> URLRequest {
        var request = request
        if !mayCarrySession(request.url) { request.setValue(nil, forHTTPHeaderField: "Cookie") }
        return request
    }

    /// Where Steam trades a session's renewal token for a new `steamLoginSecure` token.
    static let renewalURL = URL(string: "https://api.steampowered.com/IAuthenticationService/GenerateAccessTokenForApp/v1/")!

    /// The session with a new cookie, from Steam's token service. The renewal token goes there
    /// alone, in the body of a request that follows no redirect. Steam refusing it, or a session
    /// without one, throws `SteamSignInRequired`; a connection failure throws its own error.
    func renew(_ account: SteamWebSession) async throws -> SteamWebSession {
        guard let refreshToken = account.refreshToken else { throw SteamSignInRequired() }
        var request = URLRequest(url: Self.renewalURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 35
        request.httpShouldHandleCookies = false
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "steamid", value: account.steamID),
        ]
        request.httpBody = Data((form.percentEncodedQuery ?? "").utf8)
        let (data, response) = try await session.data(for: request, delegate: SteamNoRedirects())
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw SteamSignInRequired() }
        if http.statusCode == 401 || http.statusCode == 403 { throw SteamSignInRequired() }
        guard (200..<300).contains(http.statusCode) else {
            throw WorkshopFailure(message: String(localized: "Steam could not load the Workshop. Check your connection or open Steam in your browser, then retry."))
        }
        // Steam answers a refused token with an empty response and the reason in a header.
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let body = root["response"] as? [String: Any],
              let token = body["access_token"] as? String,
              let renewed = account.renewed(accessToken: token)
        else { throw SteamSignInRequired() }
        return renewed
    }

    /// Steam's public details endpoint answers up to this many items per request without a key.
    static let detailsBatchSize = 100

    /// Current details of Workshop items, in the order asked, without those Steam no longer
    /// serves (removed, hidden, or not Wallpaper Engine's). The public endpoint needs no key and
    /// no sign-in, and names creators only by SteamID, so `creator` is the stand-in name.
    func details(ids: [String]) async throws -> [WorkshopItem] {
        var items: [WorkshopItem] = []
        var start = 0
        while start < ids.count {
            try Task.checkCancellation()
            let batch = Array(ids[start..<min(ids.count, start + Self.detailsBatchSize)])
            start += batch.count
            let (data, response) = try await session.data(for: Self.detailsRequest(ids: batch))
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw WorkshopFailure(message: String(localized: "Steam did not answer the request for Workshop details. Check your connection and try again."))
            }
            items += try Self.decodeDetails(data)
        }
        return items
    }

    static func detailsRequest(ids: [String]) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 35
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("WallpaperMachine/1.0 (macOS; public Workshop browser)", forHTTPHeaderField: "User-Agent")
        // Ids are digits only, checked here, so the form needs no escaping.
        let numeric = ids.filter { !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }
        var fields = ["itemcount=\(numeric.count)"]
        for (index, id) in numeric.enumerated() { fields.append("publishedfileids[\(index)]=\(id)") }
        request.httpBody = Data(fields.joined(separator: "&").utf8)
        return request
    }

    static func decodeDetails(_ data: Data) throws -> [WorkshopItem] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = root["response"] as? [String: Any],
              let rows = response["publishedfiledetails"] as? [[String: Any]] else {
            throw WorkshopFailure(message: String(localized: "Steam answered the request for Workshop details in a form this app does not read."))
        }
        return rows.compactMap(Self.item(details:))
    }

    /// One row of a details answer; nil unless Steam served it and it is Wallpaper Engine's.
    static func item(details row: [String: Any]) -> WorkshopItem? {
        guard (row["result"] as? Int) == 1, (row["consumer_app_id"] as? Int) == WorkshopApp.id,
              let id = row["publishedfileid"] as? String, UInt64(id) != nil,
              let title = row["title"] as? String else { return nil }
        let preview = (row["preview_url"] as? String).flatMap(URL.init(string:))
        let updated = (row["time_updated"] as? NSNumber)?.doubleValue
        return WorkshopItem(
            id: id, title: title, creator: String(localized: "Workshop creator"),
            summary: Self.summary(row["description"] as? String ?? ""),
            previewURL: preview?.scheme == "https" ? preview : nil,
            tags: (row["tags"] as? [[String: Any]] ?? []).compactMap { $0["tag"] as? String },
            size: Int64(row["file_size"] as? String ?? "") ?? (row["file_size"] as? NSNumber)?.int64Value ?? 0,
            subscriptions: row["subscriptions"] as? Int ?? 0,
            creatorID: row["creator"] as? String,
            timeUpdated: updated.map(Date.init(timeIntervalSince1970:)),
            // Steam makes collections with its own app, 766; their size is not in this answer.
            collectionSize: (row["creator_app_id"] as? Int) == Self.collectionCreatorApp ? 0 : nil)
    }

    static let collectionCreatorApp = 766

    /// The one tile for a Workshop item named by a pasted link or id, as a page of one. The
    /// sidebar's age rating and tags are not applied: the item was asked for by name.
    func itemPage(id: String) async throws -> WorkshopPage {
        let (data, response) = try await session.data(for: Self.detailsRequest(ids: [id]))
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw WorkshopFailure(message: String(localized: "Steam did not answer the request for Workshop details. Check your connection and try again."))
        }
        let item = try Self.lookup(details: data, id: id)
        return WorkshopPage(items: [item], page: 1, totalPages: 1, totalCount: 1)
    }

    /// The item `id` from a details answer, or why it cannot be shown as a tile: Steam no longer
    /// serves it, it belongs to another app, or it is an Application wallpaper. A collection is
    /// returned as a collection tile, so it opens like any other.
    static func lookup(details data: Data, id: String) throws -> WorkshopItem {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = root["response"] as? [String: Any],
              let rows = response["publishedfiledetails"] as? [[String: Any]] else {
            throw WorkshopFailure(message: String(localized: "Steam answered the request for Workshop details in a form this app does not read."))
        }
        guard let row = rows.first(where: { ($0["publishedfileid"] as? String) == id }), (row["result"] as? Int) == 1 else {
            throw WorkshopFailure(message: String(localized: "Steam no longer serves this Workshop item."))
        }
        guard (row["consumer_app_id"] as? Int) == WorkshopApp.id else {
            throw WorkshopFailure(message: String(localized: "This link is not a Wallpaper Engine item."))
        }
        guard let item = item(details: row) else {
            throw WorkshopFailure(message: String(localized: "Steam answered the request for Workshop details in a form this app does not read."))
        }
        guard !item.tags.contains(WorkshopKind.application.rawValue) else {
            throw WorkshopFailure(message: String(localized: "Application wallpapers run Windows programs and can’t be used on macOS."))
        }
        return item
    }

    // MARK: Sources other than the browse page

    /// One page of `query`'s source. Steam filters and sorts the browse and collections pages
    /// itself; the other sources are listed in their own order and filtered here with the same
    /// rules, so a page can hold fewer than `pageSize` tiles.
    func page(for query: WorkshopQuery, page: Int, account: SteamWebSession?) async throws -> WorkshopPage {
        switch query.source {
        case .browse:
            // A pasted link or id is one item, whatever the filters and sort say.
            if let id = query.itemID { return try await itemPage(id: id) }
            return try await browse(
                search: query.text, kind: query.kind, sort: query.sort, page: page, tags: query.tags,
                excludedTags: query.excludedTags)
        case .collections:
            return try await collections(
                search: query.text, sort: query.sort, page: page, tags: query.tags, excludedTags: query.excludedTags)
        case .collection(let id, _):
            return try await collectionPage(id: id, page: page, tags: query.tags, excludedTags: query.excludedTags)
        case .creator(let id, let name):
            var listing = try await profilePage(steamID: id, subscriptions: false, account: nil, page: page)
            let author = listing.name ?? name
            listing.page = Self.matching(listing.page, tags: query.tags, excludedTags: query.excludedTags)
            listing.page.items = listing.page.items.map { item in
                var named = item
                named.creator = author
                return named
            }
            listing.page.title = author
            return listing.page
        case .subscriptions:
            guard let account else { throw SteamSignInRequired() }
            let listing = try await profilePage(steamID: account.steamID, subscriptions: true, account: account, page: page)
            return Self.matching(listing.page, tags: query.tags, excludedTags: query.excludedTags)
        }
    }

    /// How many wallpapers of a collection are looked at before it is shown while an age rating
    /// is hidden. A collection carries no rating of its own, so its first wallpapers stand in.
    static let collectionSample = 3
    private static let ratingTags: Set<String> = ["questionable", "mature"]

    /// Whether the sidebar hides an age rating, which Steam cannot apply to a collection, so
    /// collections are screened here and a page of them can come back with gaps.
    static func screensRatings(tags: [String], excludedTags: [String]) -> Bool {
        !hiddenTags(tags: tags, excludedTags: excludedTags).isDisjoint(with: ratingTags)
    }

    /// The excluded tags, lowercased, less any that are also required, as on Steam.
    private static func hiddenTags(tags: [String], excludedTags: [String]) -> Set<String> {
        Set(excludedTags.map { $0.lowercased() }).subtracting(tags.map { $0.lowercased() })
    }

    /// Collections, as Steam's browse page lists them. While Questionable or Mature is hidden, a
    /// collection is shown only when neither its own tags nor its first few wallpapers carry a
    /// hidden tag, and it has a wallpaper to look at: collections are rarely tagged, and a title
    /// and a cover are enough to show what a hidden rating hides.
    func collections(
        search: String, sort: WorkshopSort, page: Int, tags: [String], excludedTags: [String]
    ) async throws -> WorkshopPage {
        var (listing, children) = try await browsePage(Self.browseURL(
            search: search, kind: .all, sort: sort, page: page, tags: tags, excludedTags: excludedTags,
            section: "collections"), decode: Self.decodeBrowse)
        guard Self.screensRatings(tags: tags, excludedTags: excludedTags) else { return listing }
        let excluded = Self.hiddenTags(tags: tags, excludedTags: excludedTags)
        var samples: [String: [String]] = [:]
        for collection in listing.items { samples[collection.id] = Array((children[collection.id] ?? []).prefix(Self.collectionSample)) }
        let sampled = try await details(ids: Array(Set(samples.values.flatMap { $0 })).sorted())
        let byID = Dictionary(sampled.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        listing.items = listing.items.filter { collection in
            let wallpapers = (samples[collection.id] ?? []).compactMap { byID[$0] }
            return !Self.carries(collection.tags, anyOf: excluded) && !wallpapers.isEmpty
                && !wallpapers.contains { Self.carries($0.tags, anyOf: excluded) }
        }
        return listing
    }

    /// The items of one collection, a page at a time, in the collection's own order. A
    /// collection inside it is shown as a collection unless an age rating is hidden, when there
    /// is nothing to vouch for what it holds.
    func collectionPage(id: String, page: Int, tags: [String], excludedTags: [String]) async throws -> WorkshopPage {
        let (data, response) = try await session.data(for: Self.collectionRequest(id: id))
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw WorkshopFailure(message: String(localized: "Steam did not answer the request for Workshop details. Check your connection and try again."))
        }
        let children = try Self.decodeCollection(data)
        let totalPages = max(1, (children.count + Self.pageSize - 1) / Self.pageSize)
        let number = min(max(1, page), totalPages)
        let slice = Array(children.dropFirst((number - 1) * Self.pageSize).prefix(Self.pageSize))
        let items = try await details(ids: slice)
        return Self.matching(
            WorkshopPage(items: items, page: number, totalPages: totalPages, totalCount: children.count),
            tags: tags, excludedTags: excludedTags)
    }

    static func collectionRequest(id: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.steampowered.com/ISteamRemoteStorage/GetCollectionDetails/v1/")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 35
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("WallpaperMachine/1.0 (macOS; public Workshop browser)", forHTTPHeaderField: "User-Agent")
        let numeric = id.allSatisfy { $0.isASCII && $0.isNumber } && !id.isEmpty ? id : "0"
        request.httpBody = Data("collectioncount=1&publishedfileids[0]=\(numeric)".utf8)
        return request
    }

    /// The ids a collection holds, in its order.
    static func decodeCollection(_ data: Data) throws -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = root["response"] as? [String: Any],
              let collection = (response["collectiondetails"] as? [[String: Any]])?.first else {
            throw WorkshopFailure(message: String(localized: "Steam answered the request for Workshop details in a form this app does not read."))
        }
        guard (collection["result"] as? Int) == 1 else {
            throw WorkshopFailure(message: String(localized: "Steam no longer serves this collection."))
        }
        return (collection["children"] as? [[String: Any]] ?? [])
            .sorted { ($0["sortorder"] as? Int ?? 0) < ($1["sortorder"] as? Int ?? 0) }
            .compactMap { $0["publishedfileid"] as? String }
    }

    static func profileURL(steamID: String, subscriptions: Bool, page: Int) -> URL {
        var url = URLComponents(string: "https://steamcommunity.com/profiles/\(steamID)/myworkshopfiles/")!
        url.queryItems = [
            URLQueryItem(name: "appid", value: String(WorkshopApp.id)),
            URLQueryItem(name: "p", value: String(max(1, page))),
            URLQueryItem(name: "numperpage", value: String(Self.pageSize)),
            URLQueryItem(name: "l", value: "english"),
        ]
        if subscriptions { url.queryItems?.append(URLQueryItem(name: "browsefilter", value: "mysubscriptions")) }
        return url.url!
    }

    /// One page of an account's Workshop items, or of its subscriptions, with the account's name.
    func profilePage(
        steamID: String, subscriptions: Bool, account: SteamWebSession?, page: Int
    ) async throws -> (page: WorkshopPage, name: String?) {
        guard SteamWebSession.isSteamID(steamID) else {
            throw WorkshopFailure(message: String(localized: "This Steam account id is not one Steam uses."))
        }
        let html = try await communityPage(
            Self.profileURL(steamID: steamID, subscriptions: subscriptions, page: page), account: account)
        let listing = try Self.decodeProfileListing(html)
        let items = try await details(ids: listing.ids)
        let totalPages = max(1, (listing.total + Self.pageSize - 1) / Self.pageSize)
        return (WorkshopPage(items: items, page: max(1, page), totalPages: min(totalPages, Self.maxPages), totalCount: listing.total), listing.name)
    }

    /// Every id the account subscribes to, page by page, at most `maxPages` pages.
    func subscribedIDs(account: SteamWebSession) async throws -> [String] {
        var ids: [String] = []
        var page = 1
        var pages = 1
        repeat {
            try Task.checkCancellation()
            let html = try await communityPage(
                Self.profileURL(steamID: account.steamID, subscriptions: true, page: page), account: account)
            let listing = try Self.decodeProfileListing(html)
            ids += listing.ids.filter { !ids.contains($0) }
            pages = min(Self.maxPages, max(1, (listing.total + Self.pageSize - 1) / Self.pageSize))
            if listing.ids.isEmpty { break }
            page += 1
        } while page <= pages
        return ids
    }

    /// The ids on a profile's Workshop items page, the number of entries in all, and the
    /// account's name. Steam's sign-in page instead means the session is gone.
    static func decodeProfileListing(_ html: String) throws -> (ids: [String], total: Int, name: String?) {
        var ids: [String] = []
        // An author's items are tiles carrying `data-publishedfileid`; subscriptions are rows,
        // `<div class="workshopItemSubscription " id="Subscription<id>">`, whose details and
        // Unsubscribe control (`UnsubscribeItem( '<id>', '<app>' )`) are not always in the
        // served page, so the row's own id is what names the item.
        let idPattern = try NSRegularExpression(
            pattern: #"(?:data-publishedfileid="|id="(?:Subscription|UnsubscribeItemBtn)|UnsubscribeItem\(\s*')(\d+)["']"#)
        for match in idPattern.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let range = Range(match.range(at: 1), in: html) else { continue }
            let id = String(html[range])
            if !ids.contains(id) { ids.append(id) }
        }
        let title = (firstMatch(#"<title>([^<]*)</title>"#, in: html) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Every page links to the sign-in page in its header; only the page itself is titled so.
        if ids.isEmpty, title == "Sign In" { throw SteamSignInRequired() }
        let paging = #"Showing\s+([\d,]+)\s*-\s*[\d,]+\s+of\s+([\d,]+)\s+entries"#
        let number = { (group: Int) in
            firstMatch(paging, in: html, group: group).flatMap { Int($0.replacingOccurrences(of: ",", with: "")) }
        }
        let total = number(2) ?? ids.count
        // Steam says this page holds entries yet none could be read: its markup has changed,
        // which must not pass for an empty list.
        if ids.isEmpty, total > 0, let first = number(1), first <= total {
            throw WorkshopFailure(message: String(localized: "Steam returned an unreadable Workshop page. Try again or browse on Steam."))
        }
        let name = firstMatch(#"^Steam Community :: (.+?)(?: :: [^:]*)?$"#, in: title).map(unescapeHTML)
        return (ids, max(total, ids.count), name)
    }

    private static func firstMatch(_ pattern: String, in text: String, group: Int = 1) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: group), in: text) else { return nil }
        return String(text[range])
    }

    private static func unescapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    /// Applies the sidebar's rules to a page Steam did not filter: every required tag must be
    /// on an item and none of the excluded ones, compared without case. A collection inside it
    /// is dropped while an age rating is hidden, as nothing vouches for what it holds.
    static func matching(_ page: WorkshopPage, tags: [String], excludedTags: [String]) -> WorkshopPage {
        let required = Set(tags.map { $0.lowercased() })
        let excluded = hiddenTags(tags: tags, excludedTags: excludedTags)
        let screening = screensRatings(tags: tags, excludedTags: excludedTags)
        var filtered = page
        filtered.items = page.items.filter { item in
            let own = Set(item.tags.map { $0.lowercased() })
            return required.isSubset(of: own) && own.isDisjoint(with: excluded)
                && !(screening && item.collectionSize != nil)
        }
        return filtered
    }

    private static func carries(_ tags: [String], anyOf excluded: Set<String>) -> Bool {
        tags.contains { excluded.contains($0.lowercased()) }
    }

    /// The first paragraph of a Workshop description, without Steam's BBCode markup, short
    /// enough for the inspector the way the browse page's own short description is.
    static func summary(_ description: String) -> String {
        let plain = description.replacingOccurrences(of: #"\[/?[a-zA-Z0-9*]+(=[^\]]*)?\]"#, with: "", options: .regularExpression)
        let first = plain.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        return first.count > 400 ? String(first.prefix(399)) + "…" : first
    }

    /// The page's `renderContext`. Steam serves it as `{"renderContext": {…}}` in a
    /// `<script type="application/json" id="valve-ssr-data">` block; older pages handed a JSON
    /// string literal to `JSON.parse` for `window.SSR.renderContext`, still read in case Steam
    /// serves either. Scanned rather than matched: a regular expression over a page of a
    /// megabyte or more, as a page of collections holds, runs out of backtracking room.
    static func renderContext(in html: String) -> [String: Any]? {
        let bytes = Array(html.utf8)
        if let data = ssrDataBlock(in: bytes) {
            return (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["renderContext"] as? [String: Any]
        }
        guard let encoded = renderContextLiteral(in: bytes),
              let contextString = try? JSONSerialization.jsonObject(with: encoded, options: .fragmentsAllowed) as? String
        else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(contextString.utf8)) as? [String: Any]
    }

    /// The text of the `valve-ssr-data` script element. JSON in a script element cannot hold
    /// `</script`, so the first one after the element's start ends it.
    private static func ssrDataBlock(in bytes: [UInt8]) -> Data? {
        guard let marker = firstIndex(of: Array(#"id="valve-ssr-data""#.utf8), in: bytes, from: 0),
              let open = bytes[marker...].firstIndex(of: UInt8(ascii: ">")),
              let close = firstIndex(of: Array("</script".utf8), in: bytes, from: open + 1) else { return nil }
        return Data(bytes[(open + 1)..<close])
    }

    /// The JSON string literal an older page hands to `JSON.parse` for
    /// `window.SSR.renderContext`, quotes included.
    private static func renderContextLiteral(in bytes: [UInt8]) -> Data? {
        guard let marker = firstIndex(of: Array("window.SSR.renderContext".utf8), in: bytes, from: 0) else { return nil }
        var index = marker + "window.SSR.renderContext".utf8.count
        func skipSpaces() { while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 } }
        skipSpaces()
        guard index < bytes.count, bytes[index] == UInt8(ascii: "=") else { return nil }
        index += 1
        skipSpaces()
        let call = Array("JSON.parse(".utf8)
        guard index + call.count <= bytes.count, Array(bytes[index..<index + call.count]) == call else { return nil }
        index += call.count
        guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { return nil }
        let start = index
        index += 1
        while index < bytes.count {
            switch bytes[index] {
            case UInt8(ascii: "\\"): index += 2
            case UInt8(ascii: "\""): return Data(bytes[start...index])
            default: index += 1
            }
        }
        return nil
    }

    /// How a browse page names an item: the link on its tile, the `publishedfileid` key of its
    /// row in the page's JSON (also in the escaped form of the older `JSON.parse` literal), and
    /// the attribute of older tiles.
    private static let itemNeedles: [[UInt8]] = [
        "sharedfiles/filedetails/?id=", #""publishedfileid":""#, #"publishedfileid\":\""#, #"data-publishedfileid=""#,
    ].map { Array($0.utf8) }

    /// The ids of the Workshop items a browse page names, in the order they first appear, at
    /// most `limit`. Scanned as bytes for the markers an item has carried, not parsed, so it
    /// still works when the page's structure is not what `decodeBrowse` expects. An id is 5 to 20
    /// digits, none leading, that fit a `UInt64`.
    static func itemIDs(in html: String, limit: Int) -> [String] {
        guard limit > 0 else { return [] }
        let bytes = Array(html.utf8)
        var found: [(offset: Int, id: String)] = []
        for needle in itemNeedles {
            // Once a marker has named `limit` different items, a later one cannot be among the
            // first `limit` of the page, so a page of any size is read only as far as it takes.
            var named = Set<String>()
            var from = 0
            while named.count < limit, let at = firstIndex(of: needle, in: bytes, from: from) {
                from = at + needle.count
                if let id = itemID(in: bytes, at: from), named.insert(id).inserted { found.append((at, id)) }
            }
        }
        var unique = Set<String>()
        var ids: [String] = []
        for entry in found.sorted(by: { $0.offset < $1.offset }) where unique.insert(entry.id).inserted {
            ids.append(entry.id)
            if ids.count == limit { break }
        }
        return ids
    }

    /// The id written at `start`: the whole run of digits there, when it is a plausible one
    /// (no leading zero, and a number a `UInt64` holds).
    private static func itemID(in bytes: [UInt8], at start: Int) -> String? {
        var end = start
        while end < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[end]) { end += 1 }
        guard (5...20).contains(end - start), bytes[start] != UInt8(ascii: "0") else { return nil }
        let id = String(decoding: bytes[start..<end], as: UTF8.self)
        return UInt64(id) == nil ? nil : id
    }

    private static func firstIndex(of needle: [UInt8], in haystack: [UInt8], from start: Int) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        var index = start
        while index <= haystack.count - needle.count {
            if haystack[index] == needle[0], haystack[index..<index + needle.count].elementsEqual(needle) { return index }
            index += 1
        }
        return nil
    }

    static func decodePage(_ html: String) throws -> WorkshopPage {
        try decodeBrowse(html).page
    }

    /// A browse page and, for each collection on it, the ids of the wallpapers it holds (not
    /// the collections it holds), in the collection's order.
    static func decodeBrowse(_ html: String) throws -> (page: WorkshopPage, children: [String: [String]]) {
        guard let context = renderContext(in: html),
              let queryData = context["queryData"] as? String,
              let decoded = try? JSONSerialization.jsonObject(with: Data(queryData.utf8)) as? [String: Any],
              let queries = decoded["queries"] as? [[String: Any]] else { throw WorkshopLayoutChanged() }

        func key(_ query: [String: Any]) -> [String] { (query["queryKey"] as? [Any])?.compactMap { $0 as? String } ?? [] }
        func data(_ query: [String: Any]) -> [String: Any]? {
            (query["state"] as? [String: Any])?["data"] as? [String: Any]
        }
        guard let browse = queries.first(where: { key($0).first == "workshop_browse" }),
              let result = data(browse) else { throw WorkshopLayoutChanged() }
        let answer = (result["eresult"] as? NSNumber)?.intValue
        // 10 is Steam's search being overloaded; any other refusal keeps the page-changed wording.
        if answer == 10 { throw WorkshopBusy() }
        guard answer == 1 else { throw WorkshopFailure(message: WorkshopLayoutChanged.message) }
        guard let rows = result["results"] as? [[String: Any]] else { throw WorkshopLayoutChanged() }

        // Display names of the creators the page mentions, by Steam id.
        var names: [String: String] = [:]
        for query in queries {
            let parts = key(query)
            guard parts.count == 2, parts[0] == "PlayerLinkDetails",
                  let name = ((data(query)?["public_data"]) as? [String: Any])?["persona_name"] as? String,
                  !name.isEmpty else { continue }
            names[parts[1]] = name
        }

        func number(_ value: Any?) -> Int? {
            if let number = value as? NSNumber { return number.intValue }
            if let text = value as? String { return Int(text) }
            return nil
        }
        func fileID(_ value: Any?) -> String? {
            if let text = value as? String { return UInt64(text) == nil ? nil : text }
            if let number = value as? NSNumber, number.int64Value > 0 { return number.stringValue }
            return nil
        }

        var seen = Set<String>()
        var items: [WorkshopItem] = []
        var children: [String: [String]] = [:]
        for row in rows {
            guard let id = fileID(row["publishedfileid"]), number(row["consumer_appid"]) == WorkshopApp.id,
                  let title = row["title"] as? String, seen.insert(id).inserted else { continue }
            let preview = (row["preview_url"] as? String).flatMap(URL.init(string:))
            let creatorID = row["creator"] as? String
            let updated = (row["time_updated"] as? NSNumber)?.doubleValue
            let isCollection = number(row["file_type"]) == 2
            var item = WorkshopItem(
                id: id, title: title,
                creator: creatorID.flatMap { names[$0] } ?? String(localized: "Workshop creator"),
                summary: summary(row["short_description"] as? String ?? ""),
                previewURL: preview?.scheme == "https" ? preview : nil,
                tags: (row["tags"] as? [Any] ?? []).compactMap { ($0 as? [String: Any])?["tag"] as? String ?? $0 as? String },
                size: Int64(row["file_size"] as? String ?? "") ?? (row["file_size"] as? NSNumber)?.int64Value ?? 0,
                subscriptions: number(row["subscriptions"]) ?? 0,
                creatorID: creatorID,
                timeUpdated: updated.map(Date.init(timeIntervalSince1970:)))
            if isCollection {
                item.collectionSize = number(row["num_children"]) ?? 0
                let held = (row["children"] as? [[String: Any]] ?? []).filter { number($0["file_type"]) != 2 }
                    .compactMap { child -> (id: String, order: Int)? in
                        fileID(child["publishedfileid"]).map { ($0, number(child["sortorder"]) ?? 0) }
                    }
                children[id] = held.sorted { $0.order < $1.order }.map(\.id)
            }
            items.append(item)
        }
        let page = WorkshopPage(
            items: items, page: number(result["current_page"]) ?? 1,
            totalPages: max(1, number(result["total_pages"]) ?? 1),
            totalCount: number(result["total_count"]) ?? 0)
        return (page, children)
    }
}

/// Strips the Steam session cookie from a redirect that leaves steamcommunity.com.
private final class SteamCookieRedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(WorkshopService.redirected(request))
    }
}

/// Follows no redirect: the renewal token is for Steam's token service and nowhere else.
private final class SteamNoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
