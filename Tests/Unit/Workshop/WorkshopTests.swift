import XCTest
@testable import WallpaperMachine

final class WorkshopTests: XCTestCase {
    /// Skips the case unless live-network tests are opted in.
    ///
    /// The `testLive…` cases below contact Steam's real community pages, so they
    /// depend on network access and on Valve's current markup and result set. A
    /// failure there says nothing about this tree, but it still turns the routine
    /// gate red and invites a pointless re-run, so they are opt-in:
    ///
    /// ```
    /// WALLPAPER_MACHINE_NETWORK_TESTS=1 python3 scripts/test.py
    /// ```
    ///
    /// Steam's page format itself stays covered offline: `decodePage` is exercised
    /// against recorded markup by `WorkshopStoreTests`.
    private func skipUnlessNetworkTestsEnabled() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["WALLPAPER_MACHINE_NETWORK_TESTS"] == "1",
            "live Steam tests are opt-in; set WALLPAPER_MACHINE_NETWORK_TESTS=1")
    }

    func testLiveSearchRespectsTypeAndPagination() async throws {
        try skipUnlessNetworkTestsEnabled()
        let service = WorkshopService()
        let first = try await service.browse(search: "forest", kind: .scene, sort: .popular, page: 1)
        let second = try await service.browse(search: "forest", kind: .scene, sort: .popular, page: 2)
        XCTAssertFalse(first.items.isEmpty)
        XCTAssertTrue(first.items.allSatisfy { $0.kind == .scene })
        XCTAssertEqual(second.page, 2)
        XCTAssertNotEqual(Set(first.items.map(\.id)), Set(second.items.map(\.id)))
    }

    func testLiveEmptySearchIsNotReplacedByUnrelatedResults() async throws {
        try skipUnlessNetworkTestsEnabled()
        let result = try await WorkshopService().browse(search: "zzqvwxjkrpnmabcxyzqvwxjkrpnmabcxyz", kind: .scene, sort: .relevance, page: 1)
        XCTAssertTrue(result.items.isEmpty)
        XCTAssertEqual(result.totalCount, 0)
    }

    func testUnexpectedSteamResponseReportsFailure() {
        XCTAssertThrowsError(try WorkshopService.decodePage("<html>Sign in required</html>"))
    }

    func testSearchSpecialCharactersRemainWithinSingleQueryParameter() {
        let query = "rain & snow #winter + night / 日本語"
        let url = WorkshopService.browseURL(search: query, kind: .video, sort: .relevance, page: 1)
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        XCTAssertEqual(components?.queryItems?.first { $0.name == "searchtext" }?.value, query)
        XCTAssertEqual(components?.queryItems?.first { $0.name == "appid" }?.value, "431960")
        XCTAssertNil(components?.fragment)
    }

    func testSortOrdersMapToSteamBrowseSortAndTrendWindow() {
        func query(_ sort: WorkshopSort) -> (sort: String?, days: String?) {
            let url = WorkshopService.browseURL(search: "", kind: .scene, sort: sort, page: 1)
            let values = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            return (values.first { $0.name == "browsesort" }?.value, values.first { $0.name == "days" }?.value)
        }
        XCTAssertEqual(query(.topRated).sort, "toprated")
        XCTAssertEqual(query(.trendingToday).sort, "trend")
        XCTAssertEqual(query(.trendingToday).days, "1")
        XCTAssertEqual(query(.trending).sort, "trend")
        XCTAssertEqual(query(.trending).days, "7")
        XCTAssertEqual(query(.trendingMonth).sort, "trend")
        XCTAssertEqual(query(.trendingMonth).days, "30")
        XCTAssertEqual(query(.trendingYear).sort, "trend")
        XCTAssertEqual(query(.trendingYear).days, "365")
        XCTAssertEqual(query(.popular).sort, "totaluniquesubscribers")
        XCTAssertEqual(query(.newest).sort, "mostrecent")
        XCTAssertEqual(query(.updated).sort, "lastupdated")
        XCTAssertEqual(query(.relevance).sort, "textsearch")
        // The panel round-trips raw values, so every case must survive the trip.
        for sort in WorkshopSort.allCases { XCTAssertEqual(WorkshopSort(rawValue: sort.rawValue), sort) }
    }

    func testRequiredTagsDeduplicateTypeAndPreserveQueryBoundaries() {
        let specialTag = "rain & snow #winter + 日本語"
        let url = WorkshopService.browseURL(search: "", kind: .scene, sort: .popular, page: 2,
                                             tags: ["Scene", "1920 x 1080", specialTag, "1920 x 1080", specialTag])
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let values = components?.queryItems ?? []
        XCTAssertEqual(values.filter { $0.name == "requiredtags[]" }.compactMap(\.value),
                       ["Scene", "1920 x 1080", specialTag])
        XCTAssertEqual(values.first { $0.name == "p" }?.value, "2")
        XCTAssertNil(components?.fragment)

        let allTypesURL = WorkshopService.browseURL(search: "", kind: .all, sort: .popular, page: 1,
                                                     tags: ["Everyone", "Everyone"])
        let allTypesValues = URLComponents(url: allTypesURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(allTypesValues.filter { $0.name == "requiredtags[]" }.compactMap(\.value), ["Everyone"])
    }

    func testExcludedTagsAreSentOnceAndNeverContradictRequiredTags() {
        let url = WorkshopService.browseURL(search: "", kind: .scene, sort: .trendingYear, page: 1,
                                             tags: ["Approved"],
                                             excludedTags: ["Mature", "Scene", "Approved", "Mature", "Unspecified"])
        let values = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(values.filter { $0.name == "requiredtags[]" }.compactMap(\.value), ["Scene", "Approved"])
        // Steam drops an item carrying any excluded tag, so a tag that is also required must not be sent.
        XCTAssertEqual(values.filter { $0.name == "excludedtags[]" }.compactMap(\.value), ["Mature", "Unspecified"])

        let plain = WorkshopService.browseURL(search: "", kind: .all, sort: .trendingYear, page: 1)
        let plainValues = URLComponents(url: plain, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertTrue(plainValues.allSatisfy { $0.name != "excludedtags[]" && $0.name != "requiredtags[]" })
    }

    func testDetailsRequestSendsOnlyNumericIDsAsAForm() throws {
        let request = WorkshopService.detailsRequest(ids: ["3632513108", "image-photo.png", "12"])
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.host, "api.steampowered.com")
        let body = try XCTUnwrap(request.httpBody.flatMap { String(data: $0, encoding: .utf8) })
        XCTAssertEqual(body, "itemcount=2&publishedfileids[0]=3632513108&publishedfileids[1]=12")
    }

    /// The shape of Steam's answer, trimmed from a recorded one: a served item, one Steam no
    /// longer serves, and one belonging to another app.
    func testDetailsKeepOnlyServedWallpaperEngineItems() throws {
        let answer = #"""
        {"response":{"result":1,"resultcount":3,"publishedfiledetails":[
          {"publishedfileid":"3632513108","result":1,"creator":"76561199211352973","consumer_app_id":431960,
           "file_size":"161966295","preview_url":"https://images.steamusercontent.com/ugc/1/2/",
           "title":"千咲","description":"[b]Dynamic[/b] production\nSecond line","time_updated":1766849991,
           "subscriptions":190023,"tags":[{"tag":"Scene"},{"tag":"Everyone"}]},
          {"publishedfileid":"1","result":9},
          {"publishedfileid":"2","result":1,"consumer_app_id":440,"title":"Hat","time_updated":1}
        ]}}
        """#
        let items = try WorkshopService.decodeDetails(Data(answer.utf8))
        XCTAssertEqual(items.map(\.id), ["3632513108"])
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.title, "千咲")
        XCTAssertEqual(item.creatorID, "76561199211352973")
        XCTAssertEqual(item.timeUpdated, Date(timeIntervalSince1970: 1_766_849_991))
        XCTAssertEqual(item.size, 161_966_295)
        XCTAssertEqual(item.kind, .scene)
        XCTAssertEqual(item.summary, "Dynamic production", "BBCode is dropped and only the first paragraph kept")
    }

    func testDetailsInAnUnexpectedShapeReportFailure() {
        XCTAssertThrowsError(try WorkshopService.decodeDetails(Data("<html>".utf8)))
    }

    // MARK: A single item asked for by id

    private func detailsAnswer(_ rows: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["response": ["publishedfiledetails": rows]])
    }

    private func detailsRow(
        _ id: String = "3632513108", result: Int = 1, app: Int = 431960, creatorApp: Int = 431960,
        tags: [String] = ["Scene", "Everyone"]
    ) -> [String: Any] {
        [
            "publishedfileid": id, "result": result, "consumer_app_id": app, "creator_app_id": creatorApp,
            "title": "Item \(id)", "creator": "76561199211352973", "file_size": "161966295",
            "tags": tags.map { ["tag": $0] }, "time_updated": 1_766_849_991,
        ]
    }

    func testLookupReturnsTheWallpaperAskedFor() throws {
        // Steam answers in the order asked and may carry rows for other ids.
        let answer = try detailsAnswer([detailsRow("1"), detailsRow("3632513108", tags: ["Video", "Mature"])])
        let item = try WorkshopService.lookup(details: answer, id: "3632513108")
        XCTAssertEqual(item.id, "3632513108")
        XCTAssertEqual(item.kind, .video)
        XCTAssertEqual(item.creatorID, "76561199211352973")
        XCTAssertNil(item.collectionSize)
        XCTAssertEqual(item.pageURL, WorkshopItem.pageURL(id: "3632513108"))
    }

    func testLookupReturnsACollectionAsACollectionTile() throws {
        let answer = try detailsAnswer([detailsRow("77", creatorApp: WorkshopService.collectionCreatorApp, tags: [])])
        XCTAssertEqual(try WorkshopService.lookup(details: answer, id: "77").collectionSize, 0)
    }

    /// Each way an item cannot be shown says its own reason, so the user knows whether to try
    /// another link or give up on this one.
    func testLookupSaysWhyAnItemCannotBeShown() throws {
        func failure(_ rows: [[String: Any]], id: String = "5") throws -> String {
            let answer = try detailsAnswer(rows)
            do {
                _ = try WorkshopService.lookup(details: answer, id: id)
            } catch let failure as WorkshopFailure {
                return failure.message
            }
            XCTFail("\(rows) should not be shown")
            return ""
        }
        let removed = try failure([detailsRow("5", result: 9)])
        XCTAssertEqual(try failure([]), removed, "an answer without the row means the same")
        XCTAssertEqual(try failure([detailsRow("6")]), removed, "an answer about another id means the same")
        let otherApp = try failure([detailsRow("5", app: 440)])
        let application = try failure([detailsRow("5", tags: ["Application", "Everyone"])])
        let unreadable = try failure([["publishedfileid": "5", "result": 1, "consumer_app_id": 431960]])
        let messages = [removed, otherApp, application, unreadable]
        XCTAssertFalse(messages.contains(""))
        XCTAssertEqual(Set(messages).count, messages.count, "four reasons, four messages")

        XCTAssertThrowsError(try WorkshopService.lookup(details: Data("<html>".utf8), id: "5")) {
            XCTAssertEqual(($0 as? WorkshopFailure)?.message, unreadable)
        }
    }

    // MARK: A browse page whose markup changed

    /// Every way a page has named an item is found, in the order the page first names them, once
    /// each; a run of digits that cannot be an id is not one.
    func testItemIDsKeepFirstSeenOrderAndUniqueness() {
        let escaped = #"JSON.parse("{\"rows\":[{\"publishedfileid\":\"7000000003\"}]}")"#
        let html = """
            <html><a href="https://steamcommunity.com/sharedfiles/filedetails/?id=1000000001&searchtext=">one</a>
            <a href="https://steamcommunity.com/sharedfiles/filedetails/?id=1000000001&amp;searchtext=">one again</a>
            <div data-publishedfileid="2000000002"></div>
            <script>{"rows":[{"publishedfileid":"3000000003"},{"publishedfileid":"1000000001"}]}</script>
            <script>\(escaped)</script>
            <a href="/sharedfiles/filedetails/?id=1234">too short</a>
            <a href="/sharedfiles/filedetails/?id=99999999999999999999">more than a UInt64 holds</a>
            <a href="/sharedfiles/filedetails/?id=123456789012345678901">too long</a>
            <a href="/sharedfiles/filedetails/?id=abc">not digits</a>
            <a href="/sharedfiles/filedetails/?id=0000000">zero</a>
            <a href="/sharedfiles/filedetails/?id=0000000042">padded with zeros</a>
            <a href="/sharedfiles/filedetails/?id=4000000004">last</a>
            </html>
            """
        XCTAssertEqual(
            WorkshopService.itemIDs(in: html, limit: 30),
            ["1000000001", "2000000002", "3000000003", "7000000003", "4000000004"])
    }

    /// A page of any size yields its first `limit` items, in page order, however the markers
    /// interleave, and nothing when it names none.
    func testItemIDsStopAtTheLimitAndAnEmptyPageNamesNone() {
        var html = "<html>"
        for index in 0..<200 {
            let id = 5_000_000_000 + index
            // The link comes first for even items and the JSON key first for odd ones; every item
            // is named by both, so repeats must not count towards the limit.
            let link = "<a href=\"/sharedfiles/filedetails/?id=\(id)\"></a>"
            let key = "{\"publishedfileid\":\"\(id)\"}"
            html += index % 2 == 0 ? link + key : key + link
        }
        html += "</html>"
        let expected = (0..<30).map { String(5_000_000_000 + $0) }
        XCTAssertEqual(WorkshopService.itemIDs(in: html, limit: 30), expected)
        XCTAssertEqual(WorkshopService.itemIDs(in: html, limit: 3), Array(expected.prefix(3)))
        XCTAssertEqual(WorkshopService.itemIDs(in: html, limit: 0), [])
        XCTAssertEqual(WorkshopService.itemIDs(in: "<html>nothing here, id=1234567890</html>", limit: 30), [])
    }

    /// Only a page without the data the app reads it by is a change of layout. A page whose query
    /// Steam answered with a failure is not: nothing is guessed from its links then.
    func testOnlyAMissingContextOrQueryIsALayoutChange() throws {
        func queryData(_ queries: [[String: Any]]) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: ["queries": queries]), as: UTF8.self)
        }
        func page(_ queries: [[String: Any]]) throws -> String {
            let ssr = String(
                decoding: try JSONSerialization.data(
                    withJSONObject: ["renderContext": ["queryData": try queryData(queries)]]), as: UTF8.self)
            return "<html><script type=\"application/json\" id=\"valve-ssr-data\">\(ssr)</script></html>"
        }
        func browseQuery(_ data: [String: Any], key: String = "workshop_browse") -> [String: Any] {
            ["queryKey": [key], "state": ["data": data]]
        }
        let row: [String: Any] = ["publishedfileid": "1000000001", "consumer_appid": 431960, "title": "A"]

        for html in [
            "<html>Sign in required</html>",
            try page([]),
            try page([browseQuery(["eresult": 1, "results": [row]], key: "workshop_browse_v2")]),
            try page([browseQuery(["eresult": 1, "items": [row]])]),
        ] {
            XCTAssertThrowsError(try WorkshopService.decodePage(html)) {
                XCTAssertTrue($0 is WorkshopLayoutChanged, "\(html)")
            }
        }
        XCTAssertThrowsError(try WorkshopService.decodePage(try page([browseQuery(["eresult": 15, "results": [row]])]))) {
            XCTAssertFalse($0 is WorkshopLayoutChanged)
            XCTAssertTrue($0 is WorkshopFailure)
        }
        // Busy is Steam's search being overloaded, neither a layout change nor a refusal.
        XCTAssertThrowsError(try WorkshopService.decodePage(try page([browseQuery(["eresult": 10, "results": []])]))) {
            XCTAssertTrue($0 is WorkshopBusy)
        }
        XCTAssertEqual(
            try WorkshopService.decodePage(try page([browseQuery(["eresult": 1, "results": [row]])])).items.map(\.id),
            ["1000000001"])
        XCTAssertFalse(try WorkshopService.decodePage(try page([browseQuery(["eresult": 1, "results": [row]])])).isDegraded)
    }
}
