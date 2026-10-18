import Foundation
import XCTest

@testable import WallpaperMachine

/// Answers pixiv requests from a closure and records them, so no test reaches the network.
final class PixivFixtureTransport: PixivTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let respond: @Sendable (URL, String?) throws -> Data
    private var recorded: [(url: URL, session: String?)] = []
    var requests: [URL] { lock.withLock { recorded.map(\.url) } }
    /// The session each request carried, in order; image requests never carry one.
    var sessions: [String?] { lock.withLock { recorded.map(\.session) } }

    init(respond: @escaping @Sendable (URL) throws -> Data) { self.respond = { url, _ in try respond(url) } }

    /// For answers that depend on who is signed in.
    init(respondingToSession respond: @escaping @Sendable (URL, String?) throws -> Data) { self.respond = respond }

    func data(from url: URL, session: String?) async throws -> Data {
        lock.withLock { recorded.append((url, session)) }
        return try respond(url, session)
    }

    func image(
        from url: URL, limit: Int, progress: @escaping @Sendable (Int64, Int64?) -> Void
    ) async throws -> Data {
        lock.withLock { recorded.append((url, nil)) }
        let data = try respond(url, nil)
        guard data.count <= limit else { throw PixivFailure(code: .tooLarge(megabytes: limit / 1_048_576)) }
        progress(Int64(data.count / 2), Int64(data.count))
        progress(Int64(data.count), Int64(data.count))
        return data
    }
}

/// Holds every request that passes it until opened, optionally retaining cancellation cleanup too.
final class PixivGate: @unchecked Sendable {
    private let lock = NSLock()
    private let finishesOnCancellation: Bool
    private var isOpen = false
    private var held: [UUID: CheckedContinuation<Void, Error>] = [:]
    var waiting: Int { lock.withLock { held.count } }

    init(finishesOnCancellation: Bool = true) {
        self.finishesOnCancellation = finishesOnCancellation
    }

    func pass() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let resume: Bool = lock.withLock {
                    if isOpen || Task.isCancelled { return true }
                    held[id] = continuation
                    return false
                }
                if resume { continuation.resume() }
            }
        } onCancel: {
            guard finishesOnCancellation else { return }
            lock.withLock { held.removeValue(forKey: id) }?.resume(throwing: CancellationError())
        }
        try Task.checkCancellation()
    }

    func open() {
        let released: [CheckedContinuation<Void, Error>] = lock.withLock {
            isOpen = true
            defer { held.removeAll() }
            return Array(held.values)
        }
        for continuation in released { continuation.resume() }
    }
}

/// Answers from `fixture`, holding originals at `originals` and rankings and searches at `listings`.
///
/// A held request ends as soon as its task is cancelled, as a real transfer does. A semaphore in
/// a fixture's answer would keep a concurrency-pool thread until it timed out, out of reach of
/// cancellation, and a panel that shuts down would wait for that thread.
struct PixivHeldTransport: PixivTransport {
    let fixture: PixivFixtureTransport
    var originals: PixivGate?
    var listings: PixivGate?

    func data(from url: URL, session: String?) async throws -> Data {
        if url.path == "/ranking.php" || url.path.hasPrefix("/ajax/search/") { try await listings?.pass() }
        return try await fixture.data(from: url, session: session)
    }

    func image(
        from url: URL, limit: Int, progress: @escaping @Sendable (Int64, Int64?) -> Void
    ) async throws -> Data {
        if url.path.contains("/img-original/") { try await originals?.pass() }
        return try await fixture.image(from: url, limit: limit, progress: progress)
    }
}

/// Keeps the session in memory in place of the keychain.
final class PixivMemorySessionStore: PixivSessionStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?
    private var refusing = false
    var session: String? { lock.withLock { stored } }
    /// Makes `save` fail as a keychain that refuses the item would.
    var refusesToSave: Bool {
        get { lock.withLock { refusing } }
        set { lock.withLock { refusing = newValue } }
    }

    init(_ session: String? = nil) { stored = session }

    func load() -> String? { lock.withLock { stored } }

    func save(_ session: String) throws {
        try lock.withLock {
            guard !refusing else { throw PixivFailure(code: .notSaved) }
            stored = session
        }
    }

    func remove() { lock.withLock { stored = nil } }
}

/// JSON in the shapes pixiv's endpoints answer with, built from synthetic works.
enum PixivFixtures {
    /// A session in the shape pixiv sets once someone signs in: account id, "_", token.
    static let session = "31415926_Q7vX2mLp9KdR4tYw8NzB3cHs6FgJ1aUe"
    static let otherSession = "27182818_Zr5Tq8Wn2Xv6Yb1Mc4Kd7Lf0Hg3Js9Pa"

    struct Work {
        var id: Int
        var width = 1920
        var height = 1080
        var pages = 1
        var sexual = 0
        var sanity = 2
        var xRestrict = 0
        var aiType = 1
        var type = 0
        var title: String? = nil
        var tags = ["風景", "sky"]
    }

    static func thumbnail(_ id: Int) -> String {
        "https://i.pximg.net/c/480x960/img-master/img/2026/09/26/00/00/00/\(id)_p0_master1200.jpg"
    }

    /// A ranking entry; pixiv sends most numbers as strings and the content type as an object.
    static func rankingEntry(_ work: Work, rank: Int) -> [String: Any] {
        [
            "title": work.title ?? "Work \(work.id)", "date": "2026年09月26日 00:00", "tags": work.tags,
            "url": thumbnail(work.id), "illust_type": String(work.type), "illust_book_style": "0",
            "illust_page_count": String(work.pages), "user_name": "Artist \(work.id)",
            "profile_img": "https://i.pximg.net/user-profile/img/1_50.png",
            "illust_content_type": ["sexual": work.sexual, "lo": false, "grotesque": false, "original": true],
            "illust_series": false, "illust_id": work.id, "width": work.width, "height": work.height,
            "user_id": 1000 + work.id, "rank": rank, "yes_rank": 0, "rating_count": 10, "view_count": 100,
            "illust_upload_timestamp": 1_790_000_000, "attr": "original", "is_masked": false,
        ]
    }

    /// What pixiv puts in a ranking slot it hides from anonymous visitors.
    static func maskedRankingEntry(id: Int, rank: Int) -> [String: Any] {
        [
            "title": "", "tags": [String](), "url": "https://s.pximg.net/common/images/limit_unviewable_s.png",
            "illust_type": "0", "illust_page_count": 1, "user_name": "", "illust_content_type": [Any](),
            "illust_series": false, "illust_id": id, "width": 100, "height": 100, "user_id": 1,
            "rank": rank, "is_masked": false, "mask_reason": "login_only",
        ]
    }

    static func ranking(
        _ entries: [[String: Any]], page: Int = 1, total: Int = 500, mode: String = "daily"
    ) -> Data {
        let next: Any = page * 50 < total ? page + 1 : false
        let prev: Any = page > 1 ? page - 1 : false
        return json([
            "contents": entries, "mode": mode, "content": "illust", "page": page, "prev": prev, "next": next,
            "date": "20260927", "prev_date": "20260926", "next_date": false, "rank_total": total,
        ])
    }

    static func searchEntry(_ work: Work) -> [String: Any] {
        [
            "id": String(work.id), "title": work.title ?? "Work \(work.id)", "illustType": work.type,
            "xRestrict": work.xRestrict, "restrict": 0, "sl": work.sanity,
            "url": "https://i.pximg.net/c/250x250_80_a2/img-master/img/2026/09/26/00/00/00/\(work.id)_p0_square1200.jpg",
            "description": "", "tags": work.tags, "userId": String(2000 + work.id), "userName": "Artist \(work.id)",
            "width": work.width, "height": work.height, "pageCount": work.pages, "isBookmarkable": true,
            "bookmarkData": NSNull(), "alt": "", "createDate": "2026-09-29T00:58:36+09:00",
            "updateDate": "2026-09-29T00:58:36+09:00", "isUnlisted": false, "isMasked": false,
            "aiType": work.aiType, "profileImageUrl": "https://i.pximg.net/user-profile/img/2_50.jpg",
        ]
    }

    static func search(_ entries: [[String: Any]], total: Int, lastPage: Int = 10) -> Data {
        json([
            "error": false,
            "body": [
                "illust": ["data": entries, "total": total, "lastPage": lastPage, "bookmarkRanges": [Any]()],
                "popular": ["recent": [Any](), "permanent": [Any]()], "relatedTags": ["背景"],
            ],
        ])
    }

    static func pageEntry(workID: Int, index: Int, width: Int = 1360, height: Int = 1920) -> [String: Any] {
        let stamp = "img/2026/09/26/19/04/18/\(workID)_p\(index)"
        return [
            "urls": [
                "thumb_mini": "https://i.pximg.net/c/128x128/img-master/\(stamp)_square1200.jpg",
                "small": "https://i.pximg.net/c/540x540_70/img-master/\(stamp)_master1200.jpg",
                "regular": "https://i.pximg.net/img-master/\(stamp)_master1200.jpg",
                "original": "https://i.pximg.net/img-original/\(stamp).png",
            ],
            "width": width, "height": height,
        ]
    }

    static func pages(workID: Int, count: Int) -> Data {
        json(["error": false, "message": "", "body": (0..<count).map { pageEntry(workID: workID, index: $0) }])
    }

    /// The members-only answer: the page exists but every address is null.
    static func membersOnlyPages() -> Data {
        json([
            "error": false, "message": "",
            "body": [[
                "urls": ["thumb_mini": NSNull(), "small": NSNull(), "regular": NSNull(), "original": NSNull()],
                "width": 900, "height": 900,
            ]],
        ])
    }

    /// `/touch/ajax/user/self/status`. Signed out, pixiv sends `is_logged_in: false` beside
    /// stamp and emoji lists; signed in, the account's id, name and viewing restriction too.
    static func status(signedIn: Bool, id: String = "31415926", name: String? = "Tester", xRestrict: Any? = "1") -> Data {
        var user: [String: Any] = ["is_logged_in": signedIn, "stamp_series": [Any](), "emoji_series": [Any]()]
        if signedIn {
            user["user_id"] = id
            if let name { user["user_name"] = name }
            if let xRestrict { user["user_x_restrict"] = xRestrict }
        }
        return json(["error": false, "message": "", "body": ["user_status": user]])
    }

    static func user(id: String, name: String) -> Data {
        json(["error": false, "message": "", "body": ["userId": id, "name": name, "image": "", "isFollowed": false]])
    }

    /// pixiv's own answer to an R-18 ranking asked for by someone it does not know is an adult.
    static let forbidden = PixivFailure(code: .status(403))

    static func json(_ object: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    /// Bytes that begin like an image of the given kind; enough for type sniffing, not decoding.
    static func imageBytes(_ kind: String, size: Int = 4096) -> Data {
        let header: [UInt8] =
            switch kind {
            case "png": [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
            case "gif": Array("GIF89a".utf8)
            default: [0xFF, 0xD8, 0xFF, 0xE0]
            }
        return Data(header + [UInt8](repeating: 0x2A, count: max(0, size - header.count)))
    }
}

func XCTAssertPixivFailure<T>(
    _ expression: @autoclosure () async throws -> T, _ code: PixivFailure.Code,
    file: StaticString = #filePath, line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected pixiv failure \(code)", file: file, line: line)
    } catch {
        XCTAssertEqual(error as? PixivFailure, PixivFailure(code: code), file: file, line: line)
    }
}
