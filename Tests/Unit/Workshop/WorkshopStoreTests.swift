import Foundation
import Observation
import XCTest

@testable import WallpaperMachine

@MainActor
final class WorkshopStoreTests: XCTestCase {
  func testPaginationUsesDisplayedQueryUntilDraftIsSubmitted() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let store = fixture.store
    store.searchText = "forest"
    store.kind = .scene
    store.sort = .popular
    store.tags = ["Nature"]
    assertBrowseURL(store, text: "forest", kind: .scene, sort: .popular, page: 1, tags: ["Nature"])
    store.search()
    try await fixture.reply(
      text: "forest", kind: .scene, sort: .popular, page: 1,
      body: pageHTML(id: "101", title: "Forest \"青\"", page: 1, pages: 3, count: 65),
      tags: ["Nature"])
    try await finished(store)
    assertPage(store, id: "101", page: 1, pages: 3, count: 65)
    XCTAssertEqual(store.items.first?.title, "Forest \"青\"")
    XCTAssertEqual(store.items.first?.creator, "Fixture creator")
    XCTAssertEqual(store.items.first?.kind, .scene)

    store.searchText = "rain"
    store.kind = .video
    store.sort = .newest
    store.tags = ["Relaxing"]
    assertBrowseURL(store, text: "forest", kind: .scene, sort: .popular, page: 1, tags: ["Nature"])
    store.loadPage(2)
    try await fixture.reply(
      text: "forest", kind: .scene, sort: .popular, page: 2,
      body: pageHTML(id: "102", page: 2, pages: 3, count: 65), tags: ["Nature"])
    try await finished(store)
    assertPage(store, id: "102", page: 2, pages: 3, count: 65)
    assertBrowseURL(store, text: "forest", kind: .scene, sort: .popular, page: 2, tags: ["Nature"])

    store.search()
    try await fixture.reply(
      text: "rain", kind: .video, sort: .newest, page: 1,
      body: pageHTML(id: "201", kind: .video, page: 1, pages: 2, count: 33), tags: ["Relaxing"])
    try await finished(store)
    assertPage(store, id: "201", page: 1, pages: 2, count: 33)
    assertBrowseURL(store, text: "rain", kind: .video, sort: .newest, page: 1, tags: ["Relaxing"])
    XCTAssertEqual(store.items.first?.kind, .video)
  }

  /// Recently updated is Steam's `lastupdated` order. It must reach Steam as that key together
  /// with the search text and tags, and the page it answers with is shown.
  func testRecentlyUpdatedSortAsksSteamForLastUpdatedWithTheSearchAndTags() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let store = fixture.store
    store.searchText = "forest"
    store.kind = .scene
    store.sort = .updated
    store.tags = ["Nature"]
    let values = URLComponents(url: store.browseURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
    XCTAssertEqual(values.first { $0.name == "browsesort" }?.value, "lastupdated")
    XCTAssertEqual(values.first { $0.name == "searchtext" }?.value, "forest")
    XCTAssertEqual(values.filter { $0.name == "requiredtags[]" }.compactMap(\.value), ["Scene", "Nature"])
    store.search()
    try await fixture.reply(
      text: "forest", kind: .scene, sort: .updated, page: 1,
      body: pageHTML(id: "301", title: "Updated today", page: 1, pages: 2, count: 31), tags: ["Nature"])
    try await finished(store)
    assertPage(store, id: "301", page: 1, pages: 2, count: 31)
  }

  func testDefaultsMatchWallpaperEngineSidebarAndExclusionsReachSteam() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let store = fixture.store
    // Wallpaper Engine opens on this year's most popular items of every type, rated Everyone,
    // with genre-less items hidden; Application and Asset are never offered.
    XCTAssertEqual(store.kind, .all)
    XCTAssertEqual(store.sort, .trendingYear)
    XCTAssertEqual(store.tags, [])
    XCTAssertEqual(
      Set(store.excludedTags), ["Application", "Asset", "Questionable", "Mature", "Unspecified"])
    assertBrowseURL(
      store, text: "", kind: .all, sort: .trendingYear, page: 1, excludedTags: store.excludedTags)

    // Unticking a genre and a resolution excludes them; the committed query keeps its own list.
    store.excludedTags = store.excludedTags + ["Anime", "Portrait 1080 x 1920"]
    store.tags = ["Approved"]
    store.search()
    try await fixture.reply(
      text: "", kind: .all, sort: .trendingYear, page: 1,
      body: pageHTML(id: "301", page: 1, pages: 1, count: 1), tags: ["Approved"],
      excludedTags: store.excludedTags)
    try await finished(store)
    assertPage(store, id: "301", page: 1, pages: 1, count: 1)
    let committed = store.excludedTags
    store.excludedTags = []
    assertBrowseURL(
      store, text: "", kind: .all, sort: .trendingYear, page: 1, tags: ["Approved"],
      excludedTags: committed)
  }

  /// The downloads-at-once choice outlives a relaunch, and a stored value outside what this
  /// build offers lands on the nearest choice instead of running unbounded.
  func testConcurrentDownloadsChoiceSurvivesRelaunchAndStaysInRange() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let relaunch = {
      WorkshopStore(
        downloader: WorkshopDownloadManager(
          sessionDirectory: fixture.root.appendingPathComponent("SteamSession")),
        supportDirectory: fixture.root, defaults: fixture.defaults)
    }
    XCTAssertEqual(
      fixture.store.downloader.maximumConcurrentDownloads,
      WorkshopDownloadManager.defaultConcurrentDownloads)
    fixture.store.setConcurrentDownloads(5)
    XCTAssertEqual(fixture.store.downloader.slotLimit, 5)
    XCTAssertEqual(relaunch().downloader.maximumConcurrentDownloads, 5)
    fixture.defaults.set(40, forKey: WorkshopStore.concurrentDownloadsKey)
    XCTAssertEqual(
      relaunch().downloader.maximumConcurrentDownloads,
      WorkshopDownloadManager.concurrentDownloadRange.upperBound)
  }

  func testFailedPageAndFailedSubmissionRetryTheirOwnQueryWithoutChangingDraft() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let store = fixture.store
    store.searchText = "forest"
    store.kind = .scene
    store.sort = .popular
    store.tags = ["Nature", "1920 x 1080"]
    store.search()
    try await fixture.reply(
      text: "forest", kind: .scene, sort: .popular, page: 1,
      body: pageHTML(id: "101", page: 1, pages: 3, count: 65), tags: ["Nature", "1920 x 1080"])
    try await finished(store)

    store.loadPage(2)
    try await fixture.reply(
      text: "forest", kind: .scene, sort: .popular, page: 2,
      body: Data(), status: 503, tags: ["Nature", "1920 x 1080"])
    try await finished(store)
    assertPage(store, id: "101", page: 1, pages: 3, count: 65)
    XCTAssertNotNil(store.errorMessage)
    XCTAssertEqual(
      store.failedRequest,
      WorkshopRequest(
        query: .init(
          text: "forest", kind: .scene, sort: .popular,
          tags: ["Nature", "1920 x 1080"], excludedTags: WorkshopStore.defaultExcludedTags), page: 2))
    assertBrowseURL(
      store, text: "forest", kind: .scene, sort: .popular, page: 1, tags: ["Nature", "1920 x 1080"])

    store.searchText = "rain"
    store.kind = .video
    store.sort = .newest
    store.tags = ["Relaxing", "Everyone"]
    store.retrySearch()
    try await fixture.reply(
      text: "forest", kind: .scene, sort: .popular, page: 2,
      body: pageHTML(id: "102", page: 2, pages: 3, count: 65), tags: ["Nature", "1920 x 1080"])
    try await finished(store)
    assertPage(store, id: "102", page: 2, pages: 3, count: 65)
    XCTAssertNil(store.errorMessage)
    XCTAssertNil(store.failedRequest)
    XCTAssertEqual(store.searchText, "rain")
    XCTAssertEqual(store.kind, .video)
    XCTAssertEqual(store.sort, .newest)
    XCTAssertEqual(store.tags, ["Relaxing", "Everyone"])

    store.search()
    try await fixture.reply(
      text: "rain", kind: .video, sort: .newest, page: 1,
      body: Data("<html>Not an SSR Workshop page</html>".utf8), tags: ["Relaxing", "Everyone"])
    try await finished(store)
    assertPage(store, id: "102", page: 2, pages: 3, count: 65)
    XCTAssertNotNil(store.errorMessage)
    assertBrowseURL(
      store, text: "forest", kind: .scene, sort: .popular, page: 2, tags: ["Nature", "1920 x 1080"])
    store.searchText = "snow"
    store.kind = .all
    store.sort = .relevance
    store.tags = []
    store.retrySearch()
    try await fixture.reply(
      text: "rain", kind: .video, sort: .newest, page: 1,
      body: pageHTML(id: "201", kind: .video, page: 1, pages: 1, count: 1),
      tags: ["Relaxing", "Everyone"])
    try await finished(store)
    assertPage(store, id: "201", page: 1, pages: 1, count: 1)
    assertBrowseURL(
      store, text: "rain", kind: .video, sort: .newest, page: 1, tags: ["Relaxing", "Everyone"])
    XCTAssertNil(store.errorMessage)
    XCTAssertNil(store.failedRequest)
    XCTAssertEqual(store.searchText, "snow")
    XCTAssertEqual(store.kind, .all)
    XCTAssertEqual(store.sort, .relevance)
    XCTAssertEqual(store.tags, [])
  }

  /// A list that fails to open does not leave the list before it on show under its tab, where
  /// Next would page that other list; Retry still asks for the one that failed.
  func testFailedSourceSwitchClearsTheListBeforeIt() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let store = fixture.store
    store.sort = .popular
    store.search()
    try await fixture.reply(
      text: "", kind: .all, sort: .popular, page: 1,
      body: pageHTML(id: "101", page: 1, pages: 3, count: 65))
    try await finished(store)
    assertPage(store, id: "101", page: 1, pages: 3, count: 65)

    store.open(.creator(id: "76561198000000001", name: "Fixture author"))
    try await Self.waitUntil { fixture.inbox.hasRequest }
    fixture.inbox.take().fail(URLError(.timedOut))
    try await finished(store)
    XCTAssertNotNil(store.errorMessage)
    XCTAssertFalse(store.hasLoaded)
    XCTAssertTrue(store.items.isEmpty)
    XCTAssertEqual(store.totalCount, 0)
    XCTAssertNil(store.committedQuery)
    XCTAssertEqual(store.failedRequest?.query.source, .creator(id: "76561198000000001", name: "Fixture author"))
    store.loadPage(2)
    XCTAssertFalse(store.isLoading, "nothing is on show to page")
  }

  func testSupersededSuccessCannotPublishOverNewSearch() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let store = fixture.store
    store.searchText = "forest"
    store.search()
    let old = try await fixture.request(text: "forest", kind: .all, sort: .trendingYear, page: 1)
    store.searchText = "rain"
    store.search()
    try await fixture.reply(
      text: "rain", kind: .all, sort: .trendingYear, page: 1,
      body: pageHTML(id: "201", page: 1, pages: 2, count: 33))
    try await finished(store)
    try await waitUntil { old.isStopped }
    // A held server response released after cancellation must not revive its request.
    old.succeed(try pageHTML(id: "101", page: 1, pages: 9, count: 270))
    await fixture.drain()
    assertPage(store, id: "201", page: 1, pages: 2, count: 33)
    assertBrowseURL(store, text: "rain", kind: .all, sort: .trendingYear, page: 1)
    XCTAssertNil(store.errorMessage)
    XCTAssertNil(store.failedRequest)
  }

  func testSupersededTransportErrorCannotReplaceNewResultOrRetryTarget() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let store = fixture.store
    store.searchText = "forest"
    store.search()
    let old = try await fixture.request(text: "forest", kind: .all, sort: .trendingYear, page: 1)
    store.searchText = "rain"
    store.search()
    try await fixture.reply(
      text: "rain", kind: .all, sort: .trendingYear, page: 1,
      body: pageHTML(id: "201", page: 1, pages: 2, count: 33))
    try await finished(store)
    store.loadPage(2)
    try await fixture.reply(
      text: "rain", kind: .all, sort: .trendingYear, page: 2,
      body: Data(), status: 500)
    try await finished(store)
    try await waitUntil { old.isStopped }
    old.fail(URLError(.timedOut))
    await fixture.drain()
    assertPage(store, id: "201", page: 1, pages: 2, count: 33)
    XCTAssertNotNil(store.errorMessage)
    XCTAssertEqual(
      store.failedRequest,
      WorkshopRequest(
        query: .init(
          text: "rain", kind: .all, sort: .trendingYear,
          excludedTags: WorkshopStore.defaultExcludedTags), page: 2))
    assertBrowseURL(store, text: "rain", kind: .all, sort: .trendingYear, page: 1)
  }

  func testCompletionRacingReplacementCannotPublishOldSuccessOrError() async throws {
    // Unlike the held-response cases, these completions enter URLSession before cancellation.
    for succeeds in [true, false] {
      let fixture = try Fixture()
      defer { fixture.remove() }
      let store = fixture.store
      store.searchText = "forest"
      store.search()
      let old = try await fixture.request(text: "forest", kind: .all, sort: .trendingYear, page: 1)
      let oldBody = try pageHTML(id: "101", page: 1, pages: 9, count: 270)
      if succeeds { old.succeed(oldBody) } else { old.fail(URLError(.timedOut)) }
      // No actor suspension between completing the old request and superseding it.
      store.searchText = "rain"
      store.search()
      let current = try await fixture.request(text: "rain", kind: .all, sort: .trendingYear, page: 1)
      XCTAssertTrue(store.isLoading)
      XCTAssertFalse(store.hasLoaded)
      XCTAssertTrue(store.items.isEmpty)
      XCTAssertNil(store.errorMessage)
      XCTAssertNil(store.failedRequest)
      current.succeed(try pageHTML(id: "201", page: 1, pages: 1, count: 1))
      try await finished(store)
      await fixture.drain()
      assertPage(store, id: "201", page: 1, pages: 1, count: 1)
      assertBrowseURL(store, text: "rain", kind: .all, sort: .trendingYear, page: 1)
      XCTAssertNil(store.errorMessage)
      XCTAssertNil(store.failedRequest)
    }
  }

  func testCancellationDoesNotClaimInitialSuccessOrDiscardLoadedPage() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let store = fixture.store
    store.searchText = "forest"
    store.search()
    let initial = try await fixture.request(text: "forest", kind: .all, sort: .trendingYear, page: 1)
    store.cancelSearch()
    try await waitUntil { initial.isStopped }
    initial.succeed(try pageHTML(id: "999", page: 1, pages: 1, count: 1))
    XCTAssertFalse(store.isLoading)
    XCTAssertFalse(store.hasLoaded)
    XCTAssertTrue(store.items.isEmpty)
    XCTAssertNil(store.committedQuery)
    XCTAssertNil(store.failedRequest)
    XCTAssertNil(store.errorMessage)

    store.search()
    try await fixture.reply(
      text: "forest", kind: .all, sort: .trendingYear, page: 1,
      body: pageHTML(id: "101", page: 1, pages: 3, count: 65))
    try await finished(store)
    store.loadPage(2)
    let next = try await fixture.request(text: "forest", kind: .all, sort: .trendingYear, page: 2)
    store.cancelSearch()
    try await waitUntil { next.isStopped }
    next.succeed(try pageHTML(id: "102", page: 2, pages: 3, count: 65))
    await fixture.drain()
    XCTAssertFalse(store.isLoading)
    assertPage(store, id: "101", page: 1, pages: 3, count: 65)
    assertBrowseURL(store, text: "forest", kind: .all, sort: .trendingYear, page: 1)
    XCTAssertNil(store.failedRequest)
    XCTAssertNil(store.errorMessage)
  }

  /// A panel page is one Steam page of 30: paging fetches each page once and serves it from
  /// the cache afterwards, and the page count never exceeds Steam's 1,000-page limit however
  /// many results a query has.
  func testPagesAreSteamPagesServedFromCacheAndCappedAtSteamsLimit() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let store = fixture.store
    // Steam ids are numeric: 1001…1030 fill page 1, 2001…2030 page 2, and so on.
    let steamIDs = { (page: Int, count: Int) in (1...count).map { String(page * 1000 + $0) } }
    store.searchText = "forest"
    store.search()
    try await fixture.reply(
      text: "forest", kind: .all, sort: .trendingYear, page: 1,
      body: pageHTML(ids: steamIDs(1, 30), page: 1, pages: 3, count: 65))
    try await finished(store)
    XCTAssertEqual(store.items.map(\.id), steamIDs(1, 30))
    XCTAssertEqual(store.page, 1)
    XCTAssertEqual(store.totalPages, 3)
    XCTAssertEqual(store.totalCount, 65)
    XCTAssertEqual(store.reachableCount, 65)
    assertBrowseURL(store, text: "forest", kind: .all, sort: .trendingYear, page: 1)

    store.loadPage(2)
    try await fixture.reply(
      text: "forest", kind: .all, sort: .trendingYear, page: 2,
      body: pageHTML(ids: steamIDs(2, 30), page: 2, pages: 3, count: 65))
    try await finished(store)
    XCTAssertEqual(store.items.map(\.id), steamIDs(2, 30))
    XCTAssertEqual(store.page, 2)
    assertBrowseURL(store, text: "forest", kind: .all, sort: .trendingYear, page: 2)

    // Paging back is served from the cache: nothing is requested and nothing shows as loading.
    store.loadPage(1)
    XCTAssertFalse(store.isLoading)
    XCTAssertEqual(store.page, 1)
    XCTAssertEqual(store.items.map(\.id), steamIDs(1, 30))
    XCTAssertFalse(fixture.inbox.hasRequest, "A cached page must not hit Steam again")

    // Pages past the count are refused; a fresh search discards the cache, even for the same
    // query, and the page count is clamped to Steam's limit whatever the page claims.
    store.loadPage(4)
    XCTAssertFalse(store.isLoading)
    XCTAssertFalse(fixture.inbox.hasRequest)
    store.search()
    try await fixture.reply(
      text: "forest", kind: .all, sort: .trendingYear, page: 1,
      body: pageHTML(ids: steamIDs(1, 30), page: 1, pages: 4000, count: 120_000))
    try await finished(store)
    XCTAssertEqual(store.items.count, 30)
    XCTAssertEqual(store.page, 1)
    XCTAssertEqual(store.totalPages, WorkshopStore.maxPages)
    XCTAssertEqual(store.reachableCount, WorkshopStore.maxPages * WorkshopStore.pageSize)
    XCTAssertEqual(store.totalCount, 120_000)
    store.loadPage(WorkshopStore.maxPages + 1)
    XCTAssertFalse(store.isLoading)
    XCTAssertFalse(fixture.inbox.hasRequest, "No page beyond Steam's limit may be requested")
    store.loadPage(WorkshopStore.maxPages)
    try await fixture.reply(
      text: "forest", kind: .all, sort: .trendingYear, page: WorkshopStore.maxPages,
      body: pageHTML(ids: steamIDs(999, 30), page: WorkshopStore.maxPages, pages: 4000, count: 120_000))
    try await finished(store)
    XCTAssertEqual(store.page, WorkshopStore.maxPages)
    assertBrowseURL(store, text: "forest", kind: .all, sort: .trendingYear, page: WorkshopStore.maxPages)
    XCTAssertNil(store.errorMessage)
  }

  func testNextPageIsPrefetchedSoPagingForwardNeverWaits() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let store = fixture.store
    store.prefetchesNextPage = true
    var announced: [[URL]] = []
    store.onPreviewsAvailable = { announced.append($0) }
    let steamIDs = { (page: Int) in (1...30).map { String(page * 1000 + $0) } }
    store.searchText = "forest"
    store.search()
    try await fixture.reply(
      text: "forest", kind: .all, sort: .trendingYear, page: 1,
      body: pageHTML(ids: steamIDs(1), page: 1, pages: 2, count: 60))
    try await finished(store)
    XCTAssertEqual(store.page, 1)

    // Page 2 is asked for without any navigation, and showing it then needs no request.
    try await fixture.reply(
      text: "forest", kind: .all, sort: .trendingYear, page: 2,
      body: pageHTML(ids: steamIDs(2), page: 2, pages: 2, count: 60))
    try await waitUntil { announced.count == 2 }
    store.loadPage(2)
    XCTAssertFalse(store.isLoading)
    XCTAssertEqual(store.items.map(\.id), steamIDs(2))
    XCTAssertFalse(fixture.inbox.hasRequest, "The last page has nothing after it to prefetch")
  }

  private func assertPage(
    _ store: WorkshopStore, id: String, page: Int, pages: Int, count: Int,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertTrue(store.hasLoaded, file: file, line: line)
    XCTAssertEqual(store.items.map(\.id), [id], file: file, line: line)
    XCTAssertEqual(store.page, page, file: file, line: line)
    XCTAssertEqual(store.totalPages, pages, file: file, line: line)
    XCTAssertEqual(store.totalCount, count, file: file, line: line)
  }

  private func assertBrowseURL(
    _ store: WorkshopStore, text: String, kind: WorkshopKind, sort: WorkshopSort, page: Int,
    tags: [String] = [], excludedTags: [String]? = nil, file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let values =
      URLComponents(url: store.browseURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
    XCTAssertEqual(values.first { $0.name == "searchtext" }?.value, text, file: file, line: line)
    XCTAssertEqual(
      values.filter { $0.name == "requiredtags[]" }.compactMap(\.value),
      (kind == .all ? [] : [kind.rawValue]) + tags, file: file, line: line)
    if let excludedTags {
      XCTAssertEqual(
        values.filter { $0.name == "excludedtags[]" }.compactMap(\.value), excludedTags,
        file: file, line: line)
    }
    XCTAssertEqual(
      values.first { $0.name == "browsesort" }?.value, sort.browseSort, file: file, line: line)
    XCTAssertEqual(
      values.first { $0.name == "days" }?.value, String(sort.days), file: file, line: line)
    XCTAssertEqual(values.first { $0.name == "p" }?.value, String(page), file: file, line: line)
  }

  private func finished(_ store: WorkshopStore) async throws {
    try await waitUntil { !store.isLoading }
  }

  private func pageHTML(
    id: String, title: String = "Fixture wallpaper", kind: WorkshopKind = .scene,
    page: Int, pages: Int, count: Int
  ) throws -> Data {
    try pageHTML(ids: [id], title: title, kind: kind, page: page, pages: pages, count: count)
  }

  /// Steam page `page` holding `ids` in order; a full page has 30 of them.
  private func pageHTML(
    ids: [String], title: String = "Fixture wallpaper", kind: WorkshopKind = .scene,
    page: Int, pages: Int, count: Int
  ) throws -> Data {
    let queries: [[String: Any]] = [
      [
        "queryKey": ["PlayerLinkDetails", "76561198000000001"],
        "state": ["data": ["public_data": ["persona_name": "Fixture creator"]]],
      ],
      [
        "queryKey": ["workshop_browse"],
        "state": [
          "data": [
            "eresult": 1, "current_page": page, "total_pages": pages, "total_count": count,
            "results": ids.map { id -> [String: Any] in
              [
                "publishedfileid": id, "consumer_appid": 431960, "title": title,
                "creator": "76561198000000001",
                "short_description": "A real SSR fixture\nwith escaped layers",
                "tags": [["tag": kind.rawValue]], "file_size": "4096", "subscriptions": 12,
              ]
            },
          ]
        ],
      ],
    ]
    let queryData = String(
      decoding: try JSONSerialization.data(withJSONObject: ["queries": queries]), as: UTF8.self)
    let ssr = String(
      decoding: try JSONSerialization.data(withJSONObject: ["renderContext": ["queryData": queryData]]),
      as: UTF8.self)
    return Data(
      "<html><script type=\"application/json\" id=\"valve-ssr-data\">\(ssr)</script></html>".utf8)
  }

  private static func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !condition() {
      guard ContinuousClock.now < deadline else { throw FixtureError.timedOut }
      try await Task.sleep(for: .milliseconds(2))
    }
  }

  private func waitUntil(_ condition: () -> Bool) async throws {
    try await Self.waitUntil(condition)
  }

  private enum FixtureError: Error {
    case timedOut
    case unexpectedRequest(URL?)
  }

  @MainActor
  private final class Fixture {
    let root: URL
    let identifier = UUID().uuidString
    let inbox = WorkshopRequestInbox()
    let delegate = WorkshopSessionDelegate()
    let session: URLSession
    let defaults: UserDefaults
    let store: WorkshopStore

    init() throws {
      root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "WorkshopStoreTests-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      let configuration = URLSessionConfiguration.ephemeral
      configuration.protocolClasses = [WorkshopFixtureProtocol.self]
      configuration.httpAdditionalHeaders = ["X-Workshop-Test": identifier]
      configuration.urlCache = nil
      configuration.timeoutIntervalForRequest = 5
      configuration.timeoutIntervalForResource = 5
      session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
      WorkshopFixtureProtocol.register(identifier, inbox: inbox)
      defaults = TemporaryDefaults.makeForCurrentTest().defaults
      // Search and setup metadata use only this fixture's isolated storage.
      store = WorkshopStore(
        service: WorkshopService(session: session),
        downloader: WorkshopDownloadManager(
          sessionDirectory: root.appendingPathComponent("SteamSession")),
        supportDirectory: root, defaults: defaults)
    }

    func request(
      text: String, kind: WorkshopKind, sort: WorkshopSort, page: Int, tags: [String] = [],
      excludedTags: [String]? = nil
    ) async throws -> WorkshopFixtureProtocol {
      try await WorkshopStoreTests.waitUntil { self.inbox.hasRequest }
      let pending = inbox.take()
      let values =
        URLComponents(url: pending.request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
      guard values.first(where: { $0.name == "searchtext" })?.value == text,
        values.filter({ $0.name == "requiredtags[]" }).compactMap(\.value)
          == (kind == .all ? [] : [kind.rawValue]) + tags,
        excludedTags.map({ values.filter({ $0.name == "excludedtags[]" }).compactMap(\.value) == $0 })
          ?? true,
        values.first(where: { $0.name == "browsesort" })?.value == sort.browseSort,
        values.first(where: { $0.name == "days" })?.value == String(sort.days),
        values.first(where: { $0.name == "p" })?.value == String(page)
      else {
        pending.fail(URLError(.badURL))
        throw FixtureError.unexpectedRequest(pending.request.url)
      }
      return pending
    }

    func reply(
      text: String, kind: WorkshopKind, sort: WorkshopSort, page: Int, body: Data,
      status: Int = 200,
      tags: [String] = [], excludedTags: [String]? = nil
    ) async throws {
      let pending = try await request(
        text: text, kind: kind, sort: sort, page: page, tags: tags, excludedTags: excludedTags)
      pending.succeed(body, status: status)
    }

    func drain() async {
      session.finishTasksAndInvalidate()
      let result = await XCTWaiter().fulfillment(of: [delegate.invalidated], timeout: 5)
      XCTAssertEqual(
        result, .completed, "Fixture session must finish all callbacks before final assertions")
    }

    func remove() {
      store.cancelSearch()
      session.invalidateAndCancel()
      WorkshopFixtureProtocol.remove(identifier)
      try? FileManager.default.removeItem(at: root)
    }
  }
}

private final class WorkshopSessionDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
  let invalidated = XCTestExpectation(description: "Fixture session drained")
  func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
    invalidated.fulfill()
  }
}

private final class WorkshopRequestInbox: @unchecked Sendable {
  private let lock = NSLock()
  private var pending: [WorkshopFixtureProtocol] = []
  var hasRequest: Bool { lock.withLock { !pending.isEmpty } }
  func append(_ request: WorkshopFixtureProtocol) { lock.withLock { pending.append(request) } }
  func take() -> WorkshopFixtureProtocol { lock.withLock { pending.removeFirst() } }
}

private final class WorkshopFixtureProtocol: URLProtocol, @unchecked Sendable {
  private static let registryLock = NSLock()
  nonisolated(unsafe) private static var inboxes: [String: WorkshopRequestInbox] = [:]
  private let responseLock = NSRecursiveLock()
  private var stopped = false
  private var completed = false
  var isStopped: Bool { responseLock.withLock { stopped } }

  static func register(_ identifier: String, inbox: WorkshopRequestInbox) {
    registryLock.withLock { inboxes[identifier] = inbox }
  }
  static func remove(_ identifier: String) {
    _ = registryLock.withLock { inboxes.removeValue(forKey: identifier) }
  }
  // This class is installed only in fixture sessions. Claim every request so no fallback can reach the network.
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    let inbox = Self.registryLock.withLock {
      Self.inboxes[request.value(forHTTPHeaderField: "X-Workshop-Test") ?? ""]
    }
    guard let inbox else {
      fail(URLError(.resourceUnavailable))
      return
    }
    inbox.append(self)
  }
  override func stopLoading() { responseLock.withLock { stopped = true } }
  func succeed(_ body: Data, status: Int = 200) {
    responseLock.withLock {
      guard !stopped, !completed else { return }
      completed = true
      let response = HTTPURLResponse(
        url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "text/html; charset=utf-8"])!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: body)
      client?.urlProtocolDidFinishLoading(self)
    }
  }
  func fail(_ error: Error) {
    responseLock.withLock {
      guard !stopped, !completed else { return }
      completed = true
      client?.urlProtocol(self, didFailWithError: error)
    }
  }
}

/// One click must keep the wallpaper the user asked for while prerequisites are resolved.
/// Only Valve's runtime verification is replaced; the queue, PTY session, and stores are real.
@MainActor
final class WorkshopDownloadIntentTests: XCTestCase {
  private var home: URL!
  private var defaults: UserDefaults!
  private var previousHome: String?
  private var fixtures: [Fixture] = []
  private let scene = WorkshopItem(
    id: "111", title: "Scene fixture", creator: "Test", summary: "",
    previewURL: URL(string: "https://example.com/preview.jpg"),
    tags: ["Scene"], size: 0, subscriptions: 0)
  private let otherScene = WorkshopItem(
    id: "333", title: "Second scene", creator: "Test", summary: "",
    previewURL: nil, tags: ["Scene"], size: 0, subscriptions: 0)
  private let video = WorkshopItem(
    id: "222", title: "Video fixture", creator: "Test", summary: "",
    previewURL: nil, tags: ["Video"], size: 0, subscriptions: 0)

  override func setUpWithError() throws {
    home = FileManager.default.temporaryDirectory
      .appendingPathComponent("mwe-download-intents-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    previousHome = ProcessInfo.processInfo.environment["WALLPAPER_MACHINE_HOME"]
    setenv("WALLPAPER_MACHINE_HOME", home.path, 1)
    defaults = try TemporaryDefaults.make(for: self).defaults
  }

  /// Children own PTYs and staging inside `home`; every one of them must be reaped before the
  /// directory and the environment it resolves through are taken away.
  override func tearDown() async throws {
    for fixture in fixtures {
      await fixture.store.downloader.shutdown()
      await fixture.store.steamCMDSetup.shutdown()
    }
    fixtures.removeAll()
    if let previousHome {
      setenv("WALLPAPER_MACHINE_HOME", previousHome, 1)
    } else {
      unsetenv("WALLPAPER_MACHINE_HOME")
    }
    try? FileManager.default.removeItem(at: home)
  }

  func testRetainedIntentWaitsForSetupThenAccountAndNeedsNoSecondClick() async throws {
    let fixture = try makeFixture()
    XCTAssertFalse(fixture.store.sceneAssetsReady)

    fixture.store.requestDownload(item: video, rememberSession: false, bridge: fixture.bridge)
    XCTAssertEqual(fixture.store.downloadRequests.map(\.id), [video.id])
    XCTAssertEqual(try stage(fixture.store), .setup)
    XCTAssertTrue(
      fixture.store.downloader.downloads.isEmpty,
      "Without a runtime the intent waits instead of failing the click")

    try await makeSetupReady(fixture)
    fixture.store.resumeDownloadRequests(bridge: fixture.bridge)
    XCTAssertEqual(try stage(fixture.store), .account)
    XCTAssertEqual(
      fixture.store.downloadRequests.first?.rememberSession, false,
      "The retained intent keeps the sign-in choice the user made when clicking")
    XCTAssertTrue(
      fixture.store.downloader.downloads.isEmpty,
      "An account the user never supplied must not start a download")

    XCTAssertTrue(
      fixture.store.continueDownload(
        id: video.id, account: "localtest",
        rememberSession: false, includeResources: false,
        bridge: fixture.bridge))
    XCTAssertTrue(fixture.store.downloadRequests.isEmpty)
    XCTAssertEqual(fixture.store.downloader.downloads.map(\.id), [video.id])
  }

  func testSceneNeedsExplicitConsentThenQueuesSharedAssetsAheadOfTheWallpaper() async throws {
    let fixture = try makeFixture()
    try await makeSetupReady(fixture)
    fixture.store.username = "localtest"

    fixture.store.requestDownload(item: scene, rememberSession: true, bridge: fixture.bridge)
    XCTAssertEqual(try stage(fixture.store), .resources)
    XCTAssertTrue(
      fixture.store.downloader.downloads.isEmpty,
      "Multi-gigabyte shared assets must never be authorized implicitly")

    XCTAssertTrue(
      fixture.store.continueDownload(
        id: scene.id, account: "localtest",
        rememberSession: true, includeResources: true,
        bridge: fixture.bridge))
    XCTAssertEqual(
      fixture.store.downloader.downloads.map(\.id),
      [WorkshopStore.sceneAssetsRequestID, scene.id])
    try await waitUntil { fixture.store.downloader.download(for: nil)?.isQueued == false }
    XCTAssertEqual(
      fixture.store.downloader.download(for: scene.id)?.isQueued, true,
      "The wallpaper waits behind the shared assets it needs")

    // A running shared-assets job is the consent for every scene that rides it.
    fixture.store.requestDownload(item: otherScene, rememberSession: true, bridge: fixture.bridge)
    XCTAssertTrue(fixture.store.downloadRequests.isEmpty)
    XCTAssertEqual(
      fixture.store.downloader.downloads.map(\.id),
      [WorkshopStore.sceneAssetsRequestID, scene.id, otherScene.id])
  }

  func testFailedSharedAssetsWarnAboutSceneReadinessWithoutLosingTheWallpaper() async throws {
    let fixture = try makeFixture()
    try await makeSetupReady(fixture)
    fixture.store.selectedItem = scene
    XCTAssertTrue(
      fixture.store.continueDownload(
        id: scene.id, account: "localtest",
        rememberSession: true, includeResources: true,
        bridge: fixture.bridge))
    let assets = try XCTUnwrap(fixture.store.downloader.download(for: nil))
    try await waitUntil { assets.isQueued == false }

    fixture.store.downloader.cancel(assets)
    try await waitUntil { !assets.isPending }
    XCTAssertFalse(fixture.store.sceneAssetsReady)
    XCTAssertNotNil(
      fixture.store.sceneAssetsFailure,
      "A wallpaper can finish while scenes stay unplayable; that gap needs a warning")
    let wallpaper = try XCTUnwrap(fixture.store.downloader.download(for: scene.id))
    try await waitUntil { !wallpaper.isQueued }
    XCTAssertTrue(
      wallpaper.isPending, "Failed shared assets must not cancel the wallpaper download")
  }

  func testRetainedIntentSurvivesBrowsingAndResumesWhenSetupFinishes() async throws {
    let fixture = try makeFixture()
    fixture.store.selectedItem = scene
    fixture.store.requestDownload(item: scene, rememberSession: false, bridge: fixture.bridge)
    fixture.store.selectedItem = nil

    XCTAssertEqual(fixture.store.downloadRequests.first?.item?.title, scene.title)
    XCTAssertEqual(
      fixture.store.workshopItem(id: scene.id)?.title, scene.title,
      "A retained intent must still resolve its item after the results change")
    XCTAssertTrue(
      fixture.store.continueDownload(
        id: scene.id, account: "localtest",
        rememberSession: false, includeResources: true,
        bridge: fixture.bridge))
    XCTAssertEqual(try stage(fixture.store), .setup)
    XCTAssertTrue(fixture.store.downloader.downloads.isEmpty)

    try await makeSetupReady(fixture)
    fixture.store.resumeDownloadRequests(bridge: fixture.bridge)
    XCTAssertTrue(
      fixture.store.downloadRequests.isEmpty,
      "Finishing setup must resume an intent the user already continued")
    XCTAssertEqual(
      fixture.store.downloader.downloads.map(\.id),
      [WorkshopStore.sceneAssetsRequestID, scene.id])
  }

  func testRemovedRequestIsNotResumedLater() async throws {
    let fixture = try makeFixture()
    fixture.store.requestDownload(item: video, rememberSession: false, bridge: fixture.bridge)
    XCTAssertTrue(
      fixture.store.continueDownload(
        id: video.id, account: "localtest",
        rememberSession: false, includeResources: false,
        bridge: fixture.bridge))
    fixture.store.removeDownloadRequest(id: video.id)
    XCTAssertTrue(fixture.store.downloadRequests.isEmpty)

    try await makeSetupReady(fixture)
    fixture.store.resumeDownloadRequests(bridge: fixture.bridge)
    XCTAssertTrue(
      fixture.store.downloader.downloads.isEmpty,
      "A dismissed intent must stay dismissed once prerequisites arrive")
  }

  /// Correcting a mistyped login must stop that sign-in, keep the wallpaper, and never restart
  /// under the rejected name — not from the typed field and not from the saved suggestion.
  func testChangingAccountCancelsThatJobAndRetainsTheIntentWithoutSigningInAgain() async throws {
    let fixture = try makeFixture()
    try await makeSetupReady(fixture)
    fixture.store.requestDownload(item: video, rememberSession: true, bridge: fixture.bridge)
    XCTAssertTrue(
      fixture.store.continueDownload(
        id: video.id, account: "wrongname",
        rememberSession: true, includeResources: false,
        bridge: fixture.bridge))
    let job = try XCTUnwrap(fixture.store.downloader.download(for: video.id))
    try await waitUntil { !job.isQueued }

    await fixture.store.changeDownloadAccount(id: job.id)
    XCTAssertFalse(job.isPending, "The rejected sign-in must be stopped, not left running")
    XCTAssertEqual(fixture.store.downloadRequests.map(\.id), [video.id])
    XCTAssertEqual(fixture.store.downloadRequests.first?.account, "")
    XCTAssertEqual(try stage(fixture.store), .account)

    fixture.store.username = "wrongname"
    fixture.store.resumeDownloadRequests(bridge: fixture.bridge)
    XCTAssertEqual(
      fixture.store.downloadRequests.first?.account, "",
      "A rejected account must not be re-seeded from a suggestion")
    XCTAssertEqual(try stage(fixture.store), .account)
    XCTAssertEqual(
      fixture.store.downloader.downloads.filter(\.isPending).count, 0,
      "Nothing may restart until the user supplies a new account")

    XCTAssertTrue(
      fixture.store.continueDownload(
        id: video.id, account: "rightname",
        rememberSession: true, includeResources: false,
        bridge: fixture.bridge))
    XCTAssertTrue(fixture.store.downloadRequests.isEmpty)
    XCTAssertEqual(fixture.store.downloader.download(for: video.id)?.account, "rightname")
  }

  /// Finding the assets probes several folders, and every page snapshot shows where they
  /// are, so they are found again only when the panel asks.
  func testSceneAssetsAreFoundAgainOnlyOnRefresh() throws {
    let managed = home.appendingPathComponent("SceneAssets", isDirectory: true)
    let steam = home.appendingPathComponent("Steam/assets", isDirectory: true)
    let probe = SceneAssetsProbe(location: managed)
    let fixture = try makeFixture(
      sceneAssetsLocation: { probe.lookups += 1; return probe.location },
      sceneAssetsAvailable: { $0 == steam })
    XCTAssertEqual(fixture.store.sceneAssetsURL, managed)
    XCTAssertFalse(fixture.store.sceneAssetsReady)

    // Steam installs Wallpaper Engine while the app runs.
    probe.location = steam
    for _ in 0..<10 { _ = fixture.store.sceneAssetsURL }
    XCTAssertEqual(probe.lookups, 1, "reading where the assets are does not look again")
    fixture.store.refreshSceneAssetsReadiness()
    XCTAssertEqual(fixture.store.sceneAssetsURL, steam)
    XCTAssertTrue(fixture.store.sceneAssetsReady, "readiness is judged on the folder just found")

    let woke = ObservationFlag()
    withObservationTracking {
      _ = fixture.store.sceneAssetsURL
      _ = fixture.store.sceneAssetsReady
    } onChange: {
      woke.value = true
    }
    fixture.store.refreshSceneAssetsReadiness()
    XCTAssertFalse(woke.value, "coming back to the panel with nothing changed wakes no observer")
  }

  func testSharedAssetsRequestNeedsConsentEvenWhenAssetsAreAlreadyInstalled() async throws {
    let fixture = try makeFixture(sceneAssetsReady: true)
    try await makeSetupReady(fixture)
    fixture.store.username = "localtest"

    fixture.store.requestDownload(item: nil, rememberSession: true, bridge: fixture.bridge)
    XCTAssertEqual(try stage(fixture.store), .resources)
    XCTAssertTrue(
      fixture.store.downloader.downloads.isEmpty,
      "Re-downloading installed shared assets must stay an explicit choice")

    XCTAssertTrue(
      fixture.store.continueDownload(
        id: WorkshopStore.sceneAssetsRequestID,
        account: "localtest", rememberSession: true,
        includeResources: true, bridge: fixture.bridge))
    XCTAssertEqual(
      fixture.store.downloader.downloads.map(\.id), [WorkshopStore.sceneAssetsRequestID])
  }

  /// An installed scene wallpaper needs no consent step once its shared assets exist.
  /// The welcome guide signs in ahead of any download: the intent waits for SteamCMD like a
  /// download, never asks about shared resources, and runs as a sign-in-only job.
  func testSignInRequestWaitsForSetupThenSignsInWithoutADownload() async throws {
    let fixture = try makeFixture()
    fixture.store.requestSignIn(account: "localtest", rememberSession: true, bridge: fixture.bridge)
    XCTAssertEqual(fixture.store.downloadRequests.map(\.id), [WorkshopStore.signInRequestID])
    XCTAssertEqual(try stage(fixture.store), .setup)
    XCTAssertTrue(fixture.store.downloader.downloads.isEmpty)

    try await makeSetupReady(fixture)
    fixture.store.resumeDownloadRequests(bridge: fixture.bridge)
    XCTAssertTrue(fixture.store.downloadRequests.isEmpty, "Finishing setup resumes the sign-in on its own")
    let job = try XCTUnwrap(fixture.store.downloader.signIn)
    XCTAssertEqual(fixture.store.downloader.downloads.map(\.id), [WorkshopStore.signInRequestID])
    XCTAssertTrue(job.isSignIn)
    XCTAssertNil(job.item)
    try await waitUntil { !job.isQueued }
    XCTAssertTrue(job.worker.isSigningInOnly)
    XCTAssertFalse(job.worker.isInstallingAssets)

    // A second request while one runs shows the running job instead of starting another.
    fixture.store.requestSignIn(account: "localtest", rememberSession: true, bridge: fixture.bridge)
    XCTAssertEqual(fixture.store.downloader.downloads.count, 1)
    XCTAssertEqual(fixture.store.selectedDownloadID, WorkshopStore.signInRequestID)

    // An empty account is refused up front and retained for correction, as for a download.
    fixture.store.downloader.cancel(job)
    try await waitUntil { !job.isPending }
    fixture.store.requestSignIn(account: "", rememberSession: true, bridge: fixture.bridge)
    XCTAssertEqual(try stage(fixture.store), .account)
    XCTAssertEqual(fixture.store.downloader.downloads.count, 1, "No job starts without an account")
  }

  func testSceneSkipsResourceConsentWhenAssetsAreReady() async throws {
    let fixture = try makeFixture(sceneAssetsReady: true)
    try await makeSetupReady(fixture)
    fixture.store.username = "localtest"

    fixture.store.requestDownload(item: scene, rememberSession: true, bridge: fixture.bridge)
    XCTAssertTrue(fixture.store.downloadRequests.isEmpty)
    XCTAssertEqual(
      fixture.store.downloader.downloads.map(\.id), [scene.id],
      "Ready assets must not queue a second shared-assets download")
  }

  func testReadyPrerequisitesResumeWhileNoControlPanelExists() async throws {
    let fixture = try makeFixture()
    fixture.store.username = "localtest"
    fixture.store.requestDownload(item: video, rememberSession: false, bridge: fixture.bridge)
    XCTAssertEqual(try stage(fixture.store), .setup)
    // Only the app-owned store is alive: no controller or snapshot loop drives this transition.
    try await makeSetupReady(fixture)
    try await waitUntil { fixture.store.downloader.download(for: self.video.id)?.isPending == true }
    XCTAssertTrue(fixture.store.downloadRequests.isEmpty)
  }

  func testRetainedIntentSurvivesRelaunchAndWaitsForExplicitResume() async throws {
    let original = try makeFixture()
    original.store.username = "localtest"
    original.store.requestDownload(item: video, rememberSession: false, bridge: original.bridge)
    let restored = try makeFixture()
    restored.store.startDownloadLifecycle(bridge: restored.bridge)
    XCTAssertEqual(restored.store.downloadRequests.map(\.id), [video.id])
    XCTAssertTrue(restored.store.downloadRequests[0].isPaused)
    try await makeSetupReady(restored)
    XCTAssertTrue(restored.store.downloader.downloads.isEmpty)
    XCTAssertTrue(restored.store.resumeDownloadRequest(id: video.id, bridge: restored.bridge))
    try await waitUntil { restored.store.downloader.download(for: self.video.id)?.isPending == true }
    XCTAssertTrue(restored.store.downloadRequests.isEmpty)
  }

  func testCancellingARestoredJobWaitingForSetupCannotRestartItLater() async throws {
    let original = try makeFixture()
    try await makeSetupReady(original)
    original.store.username = "localtest"
    original.store.requestDownload(item: video, rememberSession: false, bridge: original.bridge)
    await original.store.downloader.shutdown()
    let restored = try makeFixture()
    restored.store.startDownloadLifecycle(bridge: restored.bridge)
    let paused = try XCTUnwrap(restored.store.downloader.download(for: video.id))
    XCTAssertTrue(paused.isPaused)
    XCTAssertNil(restored.store.steamCMDSetup.selectedRuntime)
    restored.store.resumeDownload(paused, bridge: restored.bridge)
    XCTAssertEqual(restored.store.downloadRequests.map(\.id), [video.id])
    XCTAssertTrue(restored.store.downloader.downloads.isEmpty, "the retained intent becomes the sole owner")
    restored.store.cancelDownload(id: video.id)
    try await makeSetupReady(restored)
    restored.store.resumeDownloadRequests(bridge: restored.bridge)
    XCTAssertTrue(restored.store.downloadRequests.isEmpty)
    XCTAssertTrue(restored.store.downloader.downloads.isEmpty)
  }

  func testResumingSceneRechecksSharedAssetConsent() async throws {
    for assetsReady in [false, true] {
      let original = try makeFixture(sceneAssetsReady: true)
      try await makeSetupReady(original)
      original.store.username = "localtest"
      original.store.requestDownload(item: scene, rememberSession: false, bridge: original.bridge)
      await original.store.downloader.shutdown()
      let restored = try makeFixture(sceneAssetsReady: assetsReady)
      try await makeSetupReady(restored)
      let paused = try XCTUnwrap(restored.store.downloader.download(for: scene.id))
      XCTAssertTrue(paused.isPaused)
      restored.store.resumeDownload(paused, bridge: restored.bridge)
      if assetsReady {
        XCTAssertTrue(restored.store.downloadRequests.isEmpty)
        XCTAssertEqual(restored.store.downloader.downloads.map(\.id), [scene.id])
      } else {
        XCTAssertEqual(try stage(restored.store), .resources)
        XCTAssertTrue(restored.store.downloader.downloads.isEmpty)
        XCTAssertFalse(try XCTUnwrap(restored.store.downloadRequests.first).includesResources)
        restored.store.cancelDownload(id: scene.id)
      }
      await restored.store.downloader.shutdown()
    }
  }

  func testFailedRequestWriteKeepsThePausedJobAsDurableOwner() async throws {
    let original = try makeFixture()
    try await makeSetupReady(original)
    original.store.username = "localtest"
    original.store.requestDownload(item: video, rememberSession: false, bridge: original.bridge)
    await original.store.downloader.shutdown()
    let restored = try makeFixture()
    let paused = try XCTUnwrap(restored.store.downloader.download(for: video.id))
    let requestFile = home.appendingPathComponent("Downloads/workshop-requests.json")
    try FileManager.default.removeItem(at: requestFile)
    try FileManager.default.createDirectory(at: requestFile, withIntermediateDirectories: false)
    restored.store.resumeDownload(paused, bridge: restored.bridge)
    XCTAssertTrue(restored.store.downloader.download(for: video.id) === paused)
    XCTAssertTrue(restored.store.downloadRequests.isEmpty)
    XCTAssertNotNil(restored.store.downloadPersistenceError)
    let records = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: home.appendingPathComponent("Downloads/Workshop/queue.json"))) as? [[String: Any]])
    XCTAssertEqual(records.compactMap { $0["id"] as? String }, [video.id])
  }

  func testFailedQueueWriteDoesNotDeleteItsDurablePrerequisiteRequest() async throws {
    let fixture = try makeFixture()
    fixture.store.username = "localtest"
    fixture.store.requestDownload(item: video, rememberSession: false, bridge: fixture.bridge)
    let queueDirectory = home.appendingPathComponent("Downloads/Workshop")
    try FileManager.default.removeItem(at: queueDirectory)
    try Data("ordinary filesystem conflict".utf8).write(to: queueDirectory)
    try await makeSetupReady(fixture)
    try await waitUntil { fixture.store.downloader.errorMessage != nil }
    XCTAssertFalse(fixture.store.downloader.isRunning)
    XCTAssertTrue(fixture.store.downloader.downloads.isEmpty)
    let records = try JSONDecoder().decode([WorkshopDownloadRequest].self,
      from: Data(contentsOf: home.appendingPathComponent("Downloads/workshop-requests.json")))
    XCTAssertEqual(records.map(\.id), [video.id])
  }

  // MARK: Reinstall

  private func assertReinstallRefused(
    _ id: String, _ fixture: Fixture, file: StaticString = #filePath, line: UInt = #line
  ) async {
    do {
      try await fixture.store.requestReinstall(id: id, rememberSession: false, bridge: fixture.bridge)
      XCTFail("Reinstalling \(id) must be refused", file: file, line: line)
    } catch {
      XCTAssertTrue(error is WallpaperActionError, "\(error)", file: file, line: line)
    }
    XCTAssertTrue(fixture.store.downloadRequests.isEmpty, file: file, line: line)
    XCTAssertTrue(fixture.store.downloader.downloads.isEmpty, file: file, line: line)
  }

  /// A picture imported from disk or a folder renamed by hand has no Workshop page to download
  /// again, so Steam is not even asked.
  func testReinstallAsksSteamOnlyAboutAWorkshopItem() async throws {
    let stub = WorkshopDetailsStub()
    defer { stub.invalidate() }
    stub.rows["222"] = WorkshopDetailsStub.row("222", title: "Video fixture", tags: ["Video"])
    let fixture = try makeFixture(service: stub.service)
    for id in ["image-photo.png", "my wallpaper", "0", "", "12a"] {
      await assertReinstallRefused(id, fixture)
    }
    XCTAssertEqual(stub.requests, [])
  }

  /// A wallpaper Steam removed cannot be fetched again, and the copy the user still has stays.
  func testReinstallOfAnItemSteamNoLongerServesLeavesTheInstalledCopyAlone() async throws {
    let stub = WorkshopDetailsStub()
    defer { stub.invalidate() }
    let installed = ClientPaths.libraryURL.appendingPathComponent("222", isDirectory: true)
    try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
    try Data("keep".utf8).write(to: installed.appendingPathComponent("movie.mp4"))
    let fixture = try makeFixture(service: stub.service)
    try await makeSetupReady(fixture)
    fixture.store.username = "localtest"

    await assertReinstallRefused("222", fixture)
    XCTAssertEqual(stub.requests, [["222"]], "Steam was asked once, about this item only")
    XCTAssertEqual(try Data(contentsOf: installed.appendingPathComponent("movie.mp4")), Data("keep".utf8))
  }

  func testReinstallRefusesAWallpaperThatIsAnApplication() async throws {
    let stub = WorkshopDetailsStub()
    defer { stub.invalidate() }
    stub.rows["222"] = WorkshopDetailsStub.row("222", title: "A program", tags: ["Application"])
    let fixture = try makeFixture(service: stub.service)
    try await makeSetupReady(fixture)
    fixture.store.username = "localtest"
    await assertReinstallRefused("222", fixture)
  }

  /// What Steam serves now is what is downloaded, through the ordinary queue; asking again while
  /// that download runs neither asks Steam again nor queues the item twice.
  func testReinstallQueuesWhatSteamServesNowAndIgnoresARepeat() async throws {
    let stub = WorkshopDetailsStub()
    defer { stub.invalidate() }
    stub.rows["222"] = WorkshopDetailsStub.row("222", title: "Current title", tags: ["Video"])
    let fixture = try makeFixture(service: stub.service)
    try await makeSetupReady(fixture)
    fixture.store.username = "localtest"

    try await fixture.store.requestReinstall(id: "222", rememberSession: false, bridge: fixture.bridge)
    XCTAssertEqual(fixture.store.downloader.downloads.map(\.id), ["222"])
    XCTAssertEqual(fixture.store.downloader.downloads.first?.item?.title, "Current title")
    XCTAssertTrue(fixture.store.downloadRequests.isEmpty)
    XCTAssertEqual(fixture.store.selectedDownloadID, "222")

    try await fixture.store.requestReinstall(id: "222", rememberSession: false, bridge: fixture.bridge)
    XCTAssertEqual(fixture.store.downloader.downloads.map(\.id), ["222"])
    XCTAssertEqual(stub.requests, [["222"]], "A download already under way is not looked up again")
  }

  /// Without SteamCMD or an account the reinstall waits like any download, and clicking it again
  /// leaves that one request where the user continues it.
  func testReinstallWaitsForSetupLikeAnyDownloadAndIgnoresARepeat() async throws {
    let stub = WorkshopDetailsStub()
    defer { stub.invalidate() }
    stub.rows["222"] = WorkshopDetailsStub.row("222", title: "Current title", tags: ["Video"])
    let fixture = try makeFixture(service: stub.service)

    try await fixture.store.requestReinstall(id: "222", rememberSession: false, bridge: fixture.bridge)
    XCTAssertEqual(fixture.store.downloadRequests.map(\.id), ["222"])
    XCTAssertEqual(fixture.store.downloadRequests.first?.item?.title, "Current title")
    XCTAssertEqual(try stage(fixture.store), .setup)
    XCTAssertTrue(fixture.store.downloader.downloads.isEmpty)

    try await fixture.store.requestReinstall(id: "222", rememberSession: false, bridge: fixture.bridge)
    XCTAssertEqual(fixture.store.downloadRequests.map(\.id), ["222"])
    XCTAssertEqual(stub.requests, [["222"]])
  }

  private struct Fixture {
    let store: WorkshopStore
    let bridge: BridgeStore
    let executable: URL
  }

  /// The fixture runtime blocks on its PTY so queued jobs keep their real pending state, and
  /// scene assets readiness is injected so this machine's Steam install cannot change the ladder.
  private func makeFixture(
    sceneAssetsReady: Bool = false,
    service: WorkshopService = WorkshopService(),
    sceneAssetsLocation: @escaping @MainActor () -> URL = { ClientPaths.assetsURL },
    sceneAssetsAvailable: (@MainActor (URL) -> Bool)? = nil
  ) throws -> Fixture {
    let runtime = home.appendingPathComponent("runtime", isDirectory: true)
    try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
    let executable = runtime.appendingPathComponent("steamcmd")
    try Data("#!/bin/sh\nIFS= read -r hold\n".utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    let downloader = WorkshopDownloadManager(
      sessionDirectory: home.appendingPathComponent("SteamSession", isDirectory: true),
      runtimeProvider: IntentRuntimeProvider())
    let store = WorkshopStore(
      service: service, downloader: downloader, supportDirectory: home, defaults: defaults,
      runtimeProvider: IntentRuntimeProvider(), sceneAssetsLocation: sceneAssetsLocation,
      sceneAssetsAvailable: sceneAssetsAvailable ?? { _ in sceneAssetsReady })
    let fixture = Fixture(
      store: store, bridge: BridgeStore(bridge: UnusedBridge(noPointer: .init())),
      executable: executable)
    fixtures.append(fixture)
    return fixture
  }

  private func makeSetupReady(_ fixture: Fixture) async throws {
    fixture.store.steamCMDSetup.selectExisting(at: fixture.executable)
    try await waitUntil { fixture.store.steamCMDSetup.selectedRuntime != nil }
  }

  private func stage(_ store: WorkshopStore) throws -> WorkshopDownloadStage {
    store.stage(for: try XCTUnwrap(store.downloadRequests.first))
  }

  private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !condition() {
      guard ContinuousClock.now < deadline else {
        throw WorkshopFailure(message: "The download queue did not reach the expected state")
      }
      try await Task.sleep(for: .milliseconds(2))
    }
  }
}

/// Answers Steam's public item-details endpoint from a table, so looking up a Workshop item never
/// leaves the process, and records the ids each request asked about.
final class WorkshopDetailsStub: @unchecked Sendable {
  private let lock = NSLock()
  private var table: [String: [String: Any]] = [:]
  private var asked: [[String]] = []
  private let identifier = UUID().uuidString
  private let session: URLSession

  /// The rows Steam would answer with, by item id. An id with no row is answered as removed.
  var rows: [String: [String: Any]] {
    get { lock.withLock { table } }
    set { lock.withLock { table = newValue } }
  }
  /// The ids of each request, in order.
  var requests: [[String]] { lock.withLock { asked } }
  var service: WorkshopService { WorkshopService(session: session) }

  init() {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [WorkshopDetailsProtocol.self]
    configuration.httpAdditionalHeaders = ["X-Workshop-Details-Test": identifier]
    configuration.urlCache = nil
    configuration.timeoutIntervalForRequest = 5
    session = URLSession(configuration: configuration)
    WorkshopDetailsProtocol.register(identifier, self)
  }

  func invalidate() {
    session.invalidateAndCancel()
    WorkshopDetailsProtocol.remove(identifier)
  }

  static func row(_ id: String, title: String, tags: [String]) -> [String: Any] {
    [
      "result": 1, "consumer_app_id": WorkshopApp.id, "publishedfileid": id, "title": title,
      "tags": tags.map { ["tag": $0] }, "file_size": "4096", "subscriptions": 3,
      "time_updated": 1_700_000_000,
    ]
  }

  fileprivate func answer(_ body: Data) -> Data {
    let fields = String(decoding: body, as: UTF8.self).split(separator: "&")
    let ids = fields.compactMap { field -> String? in
      let pair = field.split(separator: "=", maxSplits: 1)
      return pair.count == 2 && pair[0].hasPrefix("publishedfileids[") ? String(pair[1]) : nil
    }
    let details = lock.withLock { () -> [[String: Any]] in
      asked.append(ids)
      return ids.map { table[$0] ?? ["publishedfileid": $0, "result": 9] }
    }
    let reply: [String: Any] = ["response": ["result": 1, "resultcount": details.count, "publishedfiledetails": details]]
    return (try? JSONSerialization.data(withJSONObject: reply)) ?? Data()
  }
}

private final class WorkshopDetailsProtocol: URLProtocol, @unchecked Sendable {
  private static let registryLock = NSLock()
  nonisolated(unsafe) private static var stubs: [String: WorkshopDetailsStub] = [:]

  static func register(_ identifier: String, _ stub: WorkshopDetailsStub) {
    registryLock.withLock { stubs[identifier] = stub }
  }
  static func remove(_ identifier: String) {
    _ = registryLock.withLock { stubs.removeValue(forKey: identifier) }
  }

  // Installed only in the stub's own session: claim everything so nothing can reach the network.
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let stub = Self.registryLock.withLock {
      Self.stubs[request.value(forHTTPHeaderField: "X-Workshop-Details-Test") ?? ""]
    }
    guard let stub else {
      client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
      return
    }
    let body = stub.answer(Self.body(of: request))
    let response = HTTPURLResponse(
      url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": "application/json"])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: body)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}

  /// A POST body reaches a protocol as a stream.
  private static func body(of request: URLRequest) -> Data {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
      let count = stream.read(&buffer, maxLength: buffer.count)
      guard count > 0 else { break }
      data.append(buffer, count: count)
    }
    return data
  }
}

/// Replaces only Valve runtime verification; the session, PTY, and queue stay real.
private struct IntentRuntimeProvider: SteamCMDRuntimeProviding {
  func resolve(executable: URL) throws -> SteamCMDRuntime {
    guard FileManager.default.isExecutableFile(atPath: executable.path) else {
      throw SteamCMDSetupIssue(kind: .invalidSelection, detail: "Missing fixture runtime")
    }
    return SteamCMDRuntime(
      rootURL: executable.deletingLastPathComponent(), executableURL: executable)
  }
  func prepare(executable: URL, staging: URL) async throws -> URL { executable }
  func validate(at root: URL) async throws {}
}

/// The retained-intent ladder never reaches the engine; a library refresh only runs after an import.
private final class UnusedBridge: WallpaperBridge {}

@MainActor
private final class SceneAssetsProbe {
  var location: URL
  var lookups = 0
  init(location: URL) { self.location = location }
}

private final class ObservationFlag: @unchecked Sendable {
  var value = false
}
