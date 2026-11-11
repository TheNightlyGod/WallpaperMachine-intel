import Foundation
import XCTest

@testable import WallpaperMachine

final class PixivServiceTests: XCTestCase {
    private typealias Work = PixivFixtures.Work

    func testRankingKeepsStillIllustrationsInPixivOrder() throws {
        let sensitive = PixivFixtures.rankingEntry(Work(id: 305), rank: 6).merging(["is_masked": true]) { $1 }
        let data = PixivFixtures.ranking([
            PixivFixtures.rankingEntry(Work(id: 301, pages: 3, sexual: 1), rank: 1),
            PixivFixtures.maskedRankingEntry(id: 302, rank: 2),
            PixivFixtures.rankingEntry(Work(id: 303, type: 1), rank: 3),
            PixivFixtures.rankingEntry(Work(id: 304, width: 1200, height: 2400), rank: 4),
            PixivFixtures.rankingEntry(Work(id: 301), rank: 5),
            sensitive,
        ])

        let page = try PixivService.decodeRanking(data, requestedPage: 1)

        XCTAssertEqual(
            page.works.map(\.id), ["301", "304", "305"], "withheld slots, manga and repeated entries are dropped")
        XCTAssertEqual(page.works.map(\.rank), [1, 4, 6])
        XCTAssertEqual(page.works[0].pageCount, 3)
        XCTAssertEqual(page.works.map(\.rating), [.questionable, .everyone, .questionable])
        XCTAssertNil(page.works[0].aiGenerated, "rankings do not say, and pixiv ranks AI works separately")
        XCTAssertEqual(page.works[1].authorName, "Artist 304")
        XCTAssertEqual(page.works[1].authorID, "1304")
        XCTAssertEqual(page.totalCount, 500)
        XCTAssertEqual(page.totalPages, 10)
    }

    func testRankingEntriesMayUseNumbersAndListsWherePixivUsuallySendsStrings() throws {
        var entry = PixivFixtures.rankingEntry(Work(id: 310), rank: 1)
        entry["illust_type"] = 0
        entry["illust_page_count"] = 2
        entry["illust_content_type"] = [["sexual": 1]]
        let unrated = PixivFixtures.rankingEntry(Work(id: 311), rank: 2).merging(["illust_content_type": [Any]()]) { $1 }

        let works = try PixivService.decodeRanking(PixivFixtures.ranking([entry, unrated]), requestedPage: 1).works

        XCTAssertEqual(works.map(\.id), ["310", "311"])
        XCTAssertEqual(works[0].pageCount, 2)
        XCTAssertEqual(works[0].rating, .questionable)
        XCTAssertEqual(works[1].rating, .everyone)
    }

    func testRankingPagesFollowTheRankTotal() throws {
        let monthly = try PixivService.decodeRanking(
            PixivFixtures.ranking([PixivFixtures.rankingEntry(Work(id: 1), rank: 1)], page: 6, total: 274),
            requestedPage: 6)
        XCTAssertEqual(monthly.page, 6)
        XCTAssertEqual(monthly.totalPages, 6)
        XCTAssertEqual(monthly.totalCount, 274)
    }

    func testSearchReadsIllustrationsWithTheirRatingsAndAIFlag() throws {
        var advert = PixivFixtures.searchEntry(Work(id: 1))
        advert.removeValue(forKey: "id")
        var sensitive = PixivFixtures.searchEntry(Work(id: 405))
        sensitive["isMasked"] = true
        let data = PixivFixtures.search([
            PixivFixtures.searchEntry(Work(id: 401, width: 3840, height: 2160, aiType: 2)),
            PixivFixtures.searchEntry(Work(id: 402, sanity: 4)),
            PixivFixtures.searchEntry(Work(id: 403, xRestrict: 1)),
            PixivFixtures.searchEntry(Work(id: 404, type: 2)),
            advert, sensitive,
        ], total: 1234, lastPage: 10)

        let page = try PixivService.decodeSearch(data, requestedPage: 3)

        XCTAssertEqual(page.works.map(\.id), ["401", "402", "403", "405"])
        XCTAssertEqual(page.works.map(\.rating), [.everyone, .questionable, .mature, .questionable])
        XCTAssertEqual(page.works.map(\.aiGenerated), [true, false, false, false])
        XCTAssertEqual(page.works[0].width, 3840)
        XCTAssertEqual(page.works[0].authorID, "2401")
        XCTAssertNil(page.works[0].rank)
        XCTAssertEqual(page.page, 3)
        XCTAssertEqual(page.totalPages, 10)
        XCTAssertEqual(page.totalCount, 1234)
    }

    func testRefusedOrForeignAnswersAreUnreadable() {
        let refusal = PixivFixtures.json(["error": true, "message": "エラー", "body": [Any]()])
        XCTAssertThrowsError(try PixivService.decodeSearch(refusal, requestedPage: 1)) {
            XCTAssertEqual($0 as? PixivFailure, PixivFailure(code: .unreadable))
        }
        XCTAssertThrowsError(try PixivService.decodeRanking(Data("<!DOCTYPE html>".utf8), requestedPage: 1)) {
            XCTAssertEqual($0 as? PixivFailure, PixivFailure(code: .unreadable))
        }
        XCTAssertThrowsError(try PixivService.decodePages(refusal)) {
            XCTAssertEqual($0 as? PixivFailure, PixivFailure(code: .unreadable))
        }
    }

    func testPagesListEveryOriginalWithItsPreview() throws {
        let pages = try PixivService.decodePages(PixivFixtures.pages(workID: 77, count: 3))

        XCTAssertEqual(pages.map(\.index), [0, 1, 2])
        XCTAssertEqual(pages[2].originalURL.lastPathComponent, "77_p2.png")
        XCTAssertEqual(pages[0].previewURL?.absoluteString.contains("540x540"), true)
        XCTAssertEqual(pages[1].width, 1360)
        XCTAssertEqual(pages[1].height, 1920)
    }

    func testMembersOnlyWorksCannotBeDownloaded() {
        XCTAssertThrowsError(try PixivService.decodePages(PixivFixtures.membersOnlyPages())) {
            XCTAssertEqual($0 as? PixivFailure, PixivFailure(code: .membersOnly))
        }
    }

    func testSearchAddressCarriesTagsAndServerSideFilters() throws {
        let listing = PixivQuery(
            text: "  夜空  a/b+c ", order: .oldest, orientation: .landscape, minimumSize: .ultraHD,
            hidesAIGenerated: true
        ).listing
        let url = try XCTUnwrap(PixivService.searchURL(listing, page: 2))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        XCTAssertEqual(url.host, "www.pixiv.net")
        XCTAssertEqual(components.percentEncodedPath, "/ajax/search/illustrations/%E5%A4%9C%E7%A9%BA%20a%2Fb%2Bc")
        XCTAssertEqual(items["word"], "夜空 a/b+c")
        XCTAssertTrue(components.percentEncodedQuery?.contains("word=%E5%A4%9C%E7%A9%BA%20a/b%2Bc") == true)
        XCTAssertEqual(items["order"], "date")
        XCTAssertEqual(items["mode"], "safe")
        XCTAssertEqual(items["p"], "2")
        XCTAssertEqual(items["type"], "illust")
        XCTAssertEqual(items["ratio"], "0.5")
        XCTAssertEqual(items["wlt"], "3840")
        XCTAssertEqual(items["hlt"], "2160")
        XCTAssertEqual(items["ai_type"], "1")
    }

    func testSearchWithoutOrientationAsksPixivForTheShortSideOnly() throws {
        let portrait = try XCTUnwrap(PixivService.searchURL(
            PixivQuery(text: "sky", orientation: .portrait, minimumSize: .fullHD).listing, page: 1))
        let any = try XCTUnwrap(PixivService.searchURL(
            PixivQuery(text: "sky", minimumSize: .fullHD).listing, page: 1))
        let plain = try XCTUnwrap(PixivService.searchURL(PixivQuery(text: "sky").listing, page: 1))

        func items(_ url: URL) -> [String: String] {
            Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
                .map { ($0.name, $0.value ?? "") })
        }
        XCTAssertEqual(items(portrait)["ratio"], "-0.5")
        XCTAssertEqual(items(portrait)["wlt"], "1080")
        XCTAssertEqual(items(portrait)["hlt"], "1920")
        XCTAssertNil(items(any)["ratio"])
        XCTAssertEqual(items(any)["wlt"], "1080")
        XCTAssertEqual(items(any)["hlt"], "1080")
        XCTAssertNil(items(plain)["wlt"])
        XCTAssertNil(items(plain)["ai_type"])
    }

    func testRankingAddressAsksForIllustrationsOnly() throws {
        let url = PixivService.rankingURL(.rookie, page: 4)
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(url.path, "/ranking.php")
        XCTAssertEqual(items.first { $0.name == "mode" }?.value, "rookie")
        XCTAssertEqual(items.first { $0.name == "content" }?.value, "illust")
        XCTAssertEqual(items.first { $0.name == "format" }?.value, "json")
        XCTAssertEqual(items.first { $0.name == "p" }?.value, "4")
    }

    func testBlankSearchTextBrowsesTheChosenRanking() {
        XCTAssertEqual(PixivQuery(text: " \n ", ranking: .weekly).listing, .ranking(.weekly))
        XCTAssertEqual(
            PixivQuery(text: "a  b", ranking: .weekly).listing,
            .search(
                text: "a b", order: .newest, orientation: .any, minimumSize: .any, hidesAIGenerated: false, mode: .safe))
    }

    func testSearchAsksForR18WorksOnlyWhenMatureIsTicked() {
        func mode(_ ratings: Set<PixivRating>) -> PixivSearchMode? {
            guard case .search(_, _, _, _, _, let mode) = PixivQuery(text: "sky", ratings: ratings).listing else {
                return nil
            }
            return mode
        }
        XCTAssertEqual(mode([.everyone]), .safe)
        XCTAssertEqual(mode([.everyone, .questionable]), .safe)
        XCTAssertEqual(mode([.mature]), .r18)
        XCTAssertEqual(mode([.questionable, .mature]), .all)
        XCTAssertEqual(mode([.everyone, .questionable, .mature]), .all)
        XCTAssertFalse(PixivQuery(text: "sky").listing.isR18)
        XCTAssertTrue(PixivQuery(text: "sky", ratings: [.mature]).listing.isR18)
        XCTAssertTrue(PixivQuery(ranking: .weeklyR18).listing.isR18)
    }

    func testQueriesAskForNothingR18WithoutASignInAndTheMatureBox() {
        let asked = PixivQuery(ranking: .dailyR18, ratings: [.everyone, .mature, .grotesque])

        let anonymous = asked.sanitized(signedIn: false)
        XCTAssertEqual(anonymous.ratings, [.everyone])
        XCTAssertEqual(anonymous.ranking, .daily, "an R-18 ranking falls back to its all-ages one")

        let signedIn = asked.sanitized(signedIn: true)
        XCTAssertEqual(signedIn.ratings, [.everyone, .mature], "R-18G is never asked for")
        XCTAssertEqual(signedIn.ranking, .dailyR18)

        let unticked = PixivQuery(ranking: .weeklyR18, ratings: [.everyone]).sanitized(signedIn: true)
        XCTAssertEqual(unticked.ranking, .weekly)
    }

    func testQueryAdmitsWorksByRatingOrientationSizeAndAIFlag() {
        func work(_ width: Int, _ height: Int, rating: PixivRating = .everyone, ai: Bool? = false) -> PixivWork {
            PixivWork(
                id: "1", title: "", authorID: "", authorName: "", thumbnailURL: nil, width: width, height: height,
                pageCount: 1, rating: rating, aiGenerated: ai, tags: [], rank: nil)
        }
        var query = PixivQuery()
        XCTAssertTrue(query.admits(work(100, 200)))
        XCTAssertFalse(query.admits(work(100, 200, rating: .questionable)))
        XCTAssertFalse(query.admits(work(100, 200, rating: .mature)))
        query.ratings = [.everyone, .questionable, .mature]
        XCTAssertTrue(query.admits(work(100, 200, rating: .questionable)))
        XCTAssertTrue(query.admits(work(100, 200, rating: .mature)))
        query.ratings.insert(.grotesque)
        XCTAssertFalse(query.admits(work(100, 200, rating: .grotesque)), "R-18G is never shown")

        query.orientation = .landscape
        XCTAssertFalse(query.admits(work(200, 200)))
        XCTAssertTrue(query.admits(work(300, 200)))
        query.orientation = .portrait
        XCTAssertTrue(query.admits(work(200, 300)))
        XCTAssertFalse(query.admits(work(300, 200)))

        query.orientation = .any
        query.minimumSize = .quadHD
        XCTAssertTrue(query.admits(work(1440, 2560)))
        XCTAssertFalse(query.admits(work(2560, 1439)))
        XCTAssertFalse(query.admits(work(2000, 2000)))

        query.minimumSize = .any
        query.hidesAIGenerated = true
        XCTAssertFalse(query.admits(work(10, 10, ai: true)))
        XCTAssertTrue(query.admits(work(10, 10, ai: nil)))
    }

    func testRatingFollowsPixivRestrictionAndSanityGrades() {
        XCTAssertEqual(PixivRating(xRestrict: 0, sanityLevel: 2, sexual: nil), .everyone)
        XCTAssertEqual(PixivRating(xRestrict: 0, sanityLevel: 4, sexual: nil), .questionable)
        XCTAssertEqual(PixivRating(xRestrict: 0, sanityLevel: 6, sexual: nil), .questionable)
        XCTAssertEqual(PixivRating(xRestrict: 0, sanityLevel: nil, sexual: 1), .questionable)
        XCTAssertEqual(PixivRating(xRestrict: 1, sanityLevel: 2, sexual: 0), .mature)
        XCTAssertEqual(PixivRating(xRestrict: 2, sanityLevel: nil, sexual: nil), .grotesque)
        XCTAssertEqual(PixivRating(xRestrict: 0, sanityLevel: 2, sexual: 0, sensitive: true), .questionable)
    }

    func testWorkIDsAreDecimalAndLibraryIDsNameThePage() {
        XCTAssertTrue(PixivWork.isValidID("150105294"))
        XCTAssertFalse(PixivWork.isValidID(""))
        XCTAssertFalse(PixivWork.isValidID("000"))
        XCTAssertFalse(PixivWork.isValidID("12a"))
        XCTAssertFalse(PixivWork.isValidID("../1"))
        XCTAssertFalse(PixivWork.isValidID("１２"))
        XCTAssertEqual(PixivWork.libraryID(workID: "42", page: 3), "pixiv-42-p3")
    }

    func testServiceFetchesListingsAndSpacesItsRequests() async throws {
        let transport = PixivFixtureTransport { url in
            url.path == "/ranking.php"
                ? PixivFixtures.ranking([PixivFixtures.rankingEntry(Work(id: 9), rank: 1)])
                : PixivFixtures.search([PixivFixtures.searchEntry(Work(id: 8))], total: 1, lastPage: 1)
        }
        let service = PixivService(transport: transport, minimumInterval: .milliseconds(40))
        let clock = ContinuousClock()
        let start = clock.now

        let ranking = try await service.page(1, of: .ranking(.daily))
        let search = try await service.page(1, of: PixivQuery(text: "sky").listing)

        XCTAssertGreaterThanOrEqual(clock.now - start, .milliseconds(40), "the second request waits its turn")
        XCTAssertEqual(ranking.works.map(\.id), ["9"])
        XCTAssertEqual(search.works.map(\.id), ["8"])
        XCTAssertEqual(transport.requests.map(\.path), ["/ranking.php", "/ajax/search/illustrations/sky"])
    }

    func testR18RankingRatesEveryEntryMatureAndMarksR18G() throws {
        var grotesque = PixivFixtures.rankingEntry(Work(id: 502), rank: 2)
        grotesque["illust_content_type"] = ["sexual": 0, "grotesque": true]
        let data = PixivFixtures.ranking(
            [PixivFixtures.rankingEntry(Work(id: 501), rank: 1), grotesque], total: 2, mode: "daily_r18")

        let works = try PixivService.decodeRanking(data, requestedPage: 1, r18: true).works

        XCTAssertEqual(works.map(\.rating), [.mature, .grotesque])
        XCTAssertFalse(PixivQuery(ranking: .dailyR18, ratings: [.mature]).admits(works[1]))
    }

    func testHTTPFailuresPreserveStatusInsteadOfAssumingRateLimiting() throws {
        let url = URL(string: "https://www.pixiv.net/ranking.php")!
        for status in [401, 403, 404, 429, 500, 503] {
            let response = try XCTUnwrap(HTTPURLResponse(
                url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil))
            XCTAssertThrowsError(try URLSessionPixivTransport.check(response)) {
                XCTAssertEqual($0 as? PixivFailure, PixivFailure(code: .status(status)))
            }
        }
        let ok = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        XCTAssertNoThrow(try URLSessionPixivTransport.check(ok))
        XCTAssertThrowsError(try URLSessionPixivTransport.check(
            URLResponse(url: url, mimeType: nil, expectedContentLength: 0, textEncodingName: nil))) {
            XCTAssertEqual($0 as? PixivFailure, PixivFailure(code: .unreadable))
        }
    }

    func testCloudflareRefusalsAreToldApartFromPixivsOwnDenials() throws {
        func failure(_ status: Int, server: String? = "cloudflare", headers: [String: String] = [:], body: String)
            throws -> PixivFailure.Code?
        {
            var fields = headers
            fields["Server"] = server
            let response = try XCTUnwrap(HTTPURLResponse(
                url: URL(string: "https://www.pixiv.net/ajax/illust/1/pages")!, statusCode: status,
                httpVersion: "HTTP/2", headerFields: fields))
            do {
                try URLSessionPixivTransport.check(response, body: Data(body.utf8))
                return nil
            } catch {
                return (error as? PixivFailure)?.code
            }
        }
        // Cloudflare's plain block answer, and the styled page pixiv shows browsers instead.
        XCTAssertEqual(try failure(403, body: "error code: 1010\n"), .blockedByProtection(reference: 1010))
        let styled = """
            <html><head><title>pixiv</title><style>._error_1xxx .cf-error-details>*{display:none}</style></head>
            <body><div class="cf-error-details cf-error-1020"><h1>Access denied</h1><ul class="cferror_details">
            <li>Ray ID: 0</li><li>Error reference number: 1020</li></ul></div></body></html>
            """
        XCTAssertEqual(try failure(403, body: styled), .blockedByProtection(reference: 1020))
        // A browser check the app cannot pass.
        XCTAssertEqual(
            try failure(403, headers: ["cf-mitigated": "challenge"], body: "<html>Just a moment...</html>"),
            .blockedByProtection(reference: nil))
        // pixiv itself refusing (an R-18 ranking for a visitor it does not know) stays a 403, and
        // so does a page that only looks like Cloudflare's but did not come from it.
        XCTAssertEqual(
            try failure(403, body: "<html><title>イラストコミュニケーションサービス[pixiv]</title></html>"), .status(403))
        XCTAssertEqual(try failure(403, server: "nginx", body: "error code: 1010"), .status(403))
        XCTAssertEqual(try failure(404, body: "error code: 1010"), .status(404))
    }

    func testCloudflareBlockOnAnR18RankingIsNotReportedAsASignInProblem() async {
        let blocked = PixivFailure(code: .blockedByProtection(reference: 1010))
        let transport = PixivFixtureTransport { _ in throw blocked }
        let service = PixivService(transport: transport, minimumInterval: .zero)

        await XCTAssertPixivFailure(try await service.page(1, of: .ranking(.dailyR18)), blocked.code)
        await XCTAssertPixivFailure(
            try await service.page(1, of: .ranking(.dailyR18), session: PixivFixtures.session), blocked.code)
    }

    func testListingFailuresPreserveAccessDenialAndRateLimiting() async {
        for status in [403, 429, 503] {
            let transport = PixivFixtureTransport { _ in throw PixivFailure(code: .status(status)) }
            let service = PixivService(transport: transport, minimumInterval: .zero)
            await XCTAssertPixivFailure(try await service.page(1, of: .ranking(.daily)), .status(status))
            await XCTAssertPixivFailure(
                try await service.page(1, of: PixivQuery(text: "sky").listing), .status(status))
        }
    }

    func testRefusedR18RankingSaysWhetherASignInIsMissingOrTheAccountHidesR18() async {
        let transport = PixivFixtureTransport { _ in throw PixivFixtures.forbidden }
        let service = PixivService(transport: transport, minimumInterval: .zero)

        await XCTAssertPixivFailure(try await service.page(1, of: .ranking(.dailyR18)), .signedOut)
        await XCTAssertPixivFailure(
            try await service.page(1, of: .ranking(.weeklyR18), session: PixivFixtures.session), .r18Hidden)
        await XCTAssertPixivFailure(
            try await service.page(1, of: .ranking(.daily), session: PixivFixtures.session), .status(403))
    }

    func testRequestsCarryTheSessionTheyWereGiven() async throws {
        let transport = PixivFixtureTransport { url in
            url.path.hasSuffix("/pages")
                ? PixivFixtures.pages(workID: 7, count: 1)
                : PixivFixtures.ranking([PixivFixtures.rankingEntry(Work(id: 7), rank: 1)])
        }
        let service = PixivService(transport: transport, minimumInterval: .zero)

        _ = try await service.page(1, of: .ranking(.daily))
        let pages = try await service.pages(ofWork: "7", session: PixivFixtures.session)
        _ = try await service.original(of: pages[0]) { _, _ in }

        XCTAssertEqual(transport.sessions, [nil, PixivFixtures.session, nil], "images never carry the session")
    }

    func testTransportSendsTheSessionCookieToPixivsSiteOnly() {
        func cookie(_ address: String, _ session: String? = PixivFixtures.session) -> String? {
            URLSessionPixivTransport.request(URL(string: address)!, accept: "*/*", session: session)
                .value(forHTTPHeaderField: "Cookie")
        }
        XCTAssertEqual(cookie("https://www.pixiv.net/ajax/illust/1/pages"), "PHPSESSID=\(PixivFixtures.session)")
        XCTAssertNil(cookie("https://i.pximg.net/img-original/img/1_p0.png"))
        XCTAssertNil(cookie("http://www.pixiv.net/ranking.php"))
        XCTAssertNil(cookie("https://www.pixiv.net.example.com/"))
        XCTAssertNil(cookie("https://www.pixiv.net/ranking.php", nil))
        XCTAssertNil(cookie("https://www.pixiv.net/ranking.php", "1_abcdefghij; admin=1"))
        XCTAssertNil(cookie("https://www.pixiv.net:8443/ranking.php"))
        let request = URLSessionPixivTransport.request(URL(string: "https://i.pximg.net/a.jpg")!, accept: "image/*")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"), "https://www.pixiv.net/")

        // A redirect keeps the session only while it stays on pixiv's site.
        var signed = URLSessionPixivTransport.request(
            URL(string: "https://www.pixiv.net/ranking.php")!, accept: "*/*", session: PixivFixtures.session)
        XCTAssertNotNil(URLSessionPixivTransport.redirected(signed).value(forHTTPHeaderField: "Cookie"))
        signed.url = URL(string: "https://accounts.pixiv.net/login")
        XCTAssertNil(URLSessionPixivTransport.redirected(signed).value(forHTTPHeaderField: "Cookie"))
        signed.url = URL(string: "http://www.pixiv.net/ranking.php")
        XCTAssertNil(URLSessionPixivTransport.redirected(signed).value(forHTTPHeaderField: "Cookie"))
    }

    /// pixiv's Cloudflare front answers a signed-in request with a 403 browser check unless its
    /// user agent has the `Mozilla/5.0` form browsers send; anonymous requests pass either way.
    func testSignedInRequestsUseABrowserFormUserAgentThatNamesTheApp() throws {
        let request = URLSessionPixivTransport.request(
            URL(string: "https://www.pixiv.net/ajax/illust/1/pages")!, accept: "application/json",
            session: PixivFixtures.session)
        let agent = try XCTUnwrap(request.value(forHTTPHeaderField: "User-Agent"))
        XCTAssertTrue(agent.hasPrefix("Mozilla/5.0 ("), agent)
        XCTAssertTrue(agent.contains(" WallpaperMachine/"), agent)
        XCTAssertFalse(agent.contains("Safari"), "the app does not claim to be Safari: \(agent)")
    }

    func testOnlySignedInSessionValuesAreAccepted() {
        XCTAssertTrue(PixivService.isSessionValue(PixivFixtures.session))
        XCTAssertEqual(PixivService.userID(fromSession: PixivFixtures.session), "31415926")
        for value in [
            "", "abcdef0123456789abcdef0123456789", "31415926_short", "0_Q7vX2mLp9KdR4tYw8NzB",
            "31415926_Q7vX2mLp9KdR4tYw8NzB;x=1", "31415926_Q7vX2mLp9Kd R4tYw8NzB", "31415926_Q7vX2mLp9KdR4tYw8NzBé",
            "3141_5926_Q7vX2mLp9KdR4tYw8NzB", "31415926_" + String(repeating: "a", count: 129),
        ] {
            XCTAssertFalse(PixivService.isSessionValue(value), value)
            XCTAssertNil(PixivService.userID(fromSession: value), value)
        }
    }

    func testAccountIsWhoPixivSaysTheSessionSignsIn() async throws {
        let transport = PixivFixtureTransport(respondingToSession: { url, session in
            PixivFixtures.status(signedIn: session == PixivFixtures.session, xRestrict: "0")
        })
        let service = PixivService(transport: transport, minimumInterval: .zero)

        let account = try await service.account(session: PixivFixtures.session)
        let stranger = try await service.account(session: PixivFixtures.otherSession)
        let malformed = try await service.account(session: "not-a-session")

        XCTAssertEqual(account, PixivAccount(id: "31415926", name: "Tester", showsR18: false))
        XCTAssertNil(stranger, "pixiv answers signed out for a session it no longer knows")
        XCTAssertNil(malformed)
        XCTAssertEqual(transport.requests.map(\.path), ["/touch/ajax/user/self/status", "/touch/ajax/user/self/status"])
        XCTAssertEqual(transport.sessions, [PixivFixtures.session, PixivFixtures.otherSession])
    }

    func testAccountFillsInWhatTheStatusLeavesOut() async throws {
        let status = PixivFixtures.json([
            "error": false, "message": "", "body": ["user_status": ["is_logged_in": 1, "user_x_restrict": 2]],
        ])
        let transport = PixivFixtureTransport { url in
            url.path == "/touch/ajax/user/self/status" ? status : PixivFixtures.user(id: "31415926", name: "Painter")
        }
        let service = PixivService(transport: transport, minimumInterval: .zero)

        let account = try await service.account(session: PixivFixtures.session)

        XCTAssertEqual(account, PixivAccount(id: "31415926", name: "Painter", showsR18: true))
        XCTAssertEqual(transport.requests.last?.path, "/ajax/user/31415926")
        XCTAssertNil(try PixivService.decodeStatus(PixivFixtures.status(signedIn: true, xRestrict: nil)).viewingRestriction)
        XCTAssertThrowsError(try PixivService.decodeStatus(Data("<html>".utf8)))
    }

    func testImagesAreOnlyFetchedFromPixivsImageHost() async throws {
        let transport = PixivFixtureTransport { _ in PixivFixtures.imageBytes("jpg") }
        let service = PixivService(transport: transport, minimumInterval: .zero)
        let foreign = PixivPage(
            index: 0, width: 1, height: 1, previewURL: nil,
            originalURL: URL(string: "https://example.com/1_p0.jpg")!)

        await XCTAssertPixivFailure(try await service.original(of: foreign) { _, _ in }, .unreadable)
        await XCTAssertPixivFailure(
            try await PixivThumbnailFetcher(transport: transport).fetch(URL(string: "http://i.pximg.net/a.jpg")!),
            .unreadable)
        XCTAssertTrue(transport.requests.isEmpty)
        let bytes = try await PixivThumbnailFetcher(transport: transport).fetch(
            URL(string: PixivFixtures.thumbnail(5))!)
        XCTAssertEqual(bytes, PixivFixtures.imageBytes("jpg"))
    }
}
