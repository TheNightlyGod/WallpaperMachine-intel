import XCTest

@testable import WallpaperMachine

/// Discover's other sources: an author's wallpapers, collections and the signed-in account's
/// subscriptions. Steam is answered by a fixture protocol, so nothing reaches the network.
@MainActor
final class WorkshopSourceTests: XCTestCase {
  private static let author = "76561198000000001"
  private var fixture: SourceFixture!

  override func setUpWithError() throws {
    fixture = try SourceFixture()
  }

  override func tearDown() {
    fixture?.remove()
    fixture = nil
  }

  // MARK: Session

  func testSteamSessionIsReadFromSteamsCookieOnly() {
    let token = "eyJhbGciOiJFZERTQSJ9.payload-part_1"
    let raw = SteamWebSession(cookie: "\(Self.author)||\(token)")
    XCTAssertEqual(raw?.steamID, Self.author)
    XCTAssertEqual(raw?.cookie, "\(Self.author)||\(token)")
    // Steam percent-encodes the bars in the cookie it sets; the value is sent back as it came.
    let encoded = SteamWebSession(cookie: "\(Self.author)%7C%7C\(token)")
    XCTAssertEqual(encoded?.steamID, Self.author)
    XCTAssertEqual(encoded?.cookie, "\(Self.author)%7C%7C\(token)")
    for value in [
      "", token, "\(Self.author)||", "7656119800000000||\(token)", "\(Self.author)||short",
      "\(Self.author)||\(token); Path=/", "\(Self.author)||\(token)||more", "x\(Self.author.dropFirst())||\(token)",
    ] {
      XCTAssertNil(SteamWebSession(cookie: value), value)
    }
  }

  // MARK: Decoding

  func testTheSessionCookieDoesNotFollowARedirectOffSteamCommunity() throws {
    var request = URLRequest(url: try XCTUnwrap(URL(string: "https://steamcommunity.com/profiles/1/myworkshopfiles/")))
    request.setValue("steamLoginSecure=fixture", forHTTPHeaderField: "Cookie")
    XCTAssertNotNil(WorkshopService.redirected(request).value(forHTTPHeaderField: "Cookie"))
    for target in ["https://login.steampowered.com/jwt/refresh", "http://steamcommunity.com/", "https://steamcommunity.com:8443/"] {
      request.url = URL(string: target)
      XCTAssertNil(WorkshopService.redirected(request).value(forHTTPHeaderField: "Cookie"), target)
    }
  }

  func testProfileListingReadsItsItemsTotalAndOwner() throws {
    let listing = try WorkshopService.decodeProfileListing(String(
      decoding: profileHTML(ids: ["300", "100", "300", "200"], name: "Night &amp; Day", total: "1,147"),
      as: UTF8.self))
    XCTAssertEqual(listing.ids, ["300", "100", "200"])
    XCTAssertEqual(listing.total, 1147)
    XCTAssertEqual(listing.name, "Night & Day")
  }

  /// Issue #29: Steam lists subscriptions as rows, not as an author's tiles, and every one of
  /// them must be read, whether or not the served row holds its Unsubscribe control yet.
  func testSubscriptionsListingReadsItsRowsAndTotal() throws {
    for controls in [false, true] {
      let listing = try WorkshopService.decodeProfileListing(String(
        decoding: subscriptionsHTML(ids: ["300", "100", "200"], total: "127", controls: controls), as: UTF8.self))
      XCTAssertEqual(listing.ids, ["300", "100", "200"])
      XCTAssertEqual(listing.total, 127)
    }
    // Without the row's own id, its Unsubscribe call still names the item.
    let calls = try WorkshopService.decodeProfileListing(
      "<html>Showing 1-2 of 2 entries<span onclick=\"UnsubscribeItem( '7', '431960' );\"></span>"
        + "<span onclick=\"UnsubscribeItem('8', '431960');\"></span></html>")
    XCTAssertEqual(calls.ids, ["7", "8"])
  }

  /// A page that says it holds entries but shows none means Steam changed its markup; reading it
  /// as an empty list would hide every wallpaper without a word.
  func testAListingWhoseEntriesCannotBeReadIsAFailure() throws {
    let unread = "<html><head><title>Steam Community :: Me :: Workshop Items</title></head>"
      + "<div class=\"workshopBrowsePagingInfo\">Showing 1-30 of 127 entries</div><div class=\"row\">Item</div></html>"
    XCTAssertThrowsError(try WorkshopService.decodeProfileListing(unread)) { XCTAssertTrue($0 is WorkshopFailure) }
    // A page past the last entry is simply empty.
    let past = try WorkshopService.decodeProfileListing(
      "<html><head><title>Steam Community :: Me</title></head>Showing 151-180 of 127 entries</html>")
    XCTAssertEqual(past.ids, [])
    XCTAssertEqual(past.total, 127)
  }

  /// Every Steam page links to the sign-in page from its header, so only a page titled so means
  /// the session is gone; an author with nothing published is simply empty.
  func testOnlySteamsSignInPageMeansSigningInAgain() throws {
    XCTAssertThrowsError(try WorkshopService.decodeProfileListing(
      "<html><head><title>Sign In</title></head><a href=\"https://steamcommunity.com/login/home/\">Sign in</a></html>"
    )) { XCTAssertTrue($0 is SteamSignInRequired) }
    let empty = try WorkshopService.decodeProfileListing(
      "<html><head><title>Steam Community :: Rabscuttle</title></head><a href=\"https://steamcommunity.com/login/home/?goto=\">Sign in</a></html>")
    XCTAssertEqual(empty.ids, [])
    XCTAssertEqual(empty.total, 0)
    XCTAssertEqual(empty.name, "Rabscuttle")
  }

  func testCollectionIsListedInItsOwnOrderAndAGoneOneSaysSo() throws {
    let ids = try WorkshopService.decodeCollection(collectionJSON(children: [("30", 2), ("10", 0), ("20", 1)]))
    XCTAssertEqual(ids, ["10", "20", "30"])
    XCTAssertThrowsError(try WorkshopService.decodeCollection(
      Data(#"{"response":{"result":1,"resultcount":1,"collectiondetails":[{"publishedfileid":"9","result":9}]}}"#.utf8)))
  }

  func testBrowsedCollectionsAreMarkedWithTheWallpapersTheyHold() throws {
    let browse = try WorkshopService.decodeBrowse(String(decoding: browseHTML(rows: [
      collectionRow("900", children: [("12", 1, 0), ("11", 0, 0), ("950", 2, 2)]),
      wallpaperRow("12", tags: ["Scene"]),
    ]), as: UTF8.self))
    XCTAssertEqual(browse.page.items.map(\.collectionSize), [3, nil])
    // A collection inside the collection is not a wallpaper to vouch for it.
    XCTAssertEqual(browse.children["900"], ["11", "12"])
    XCTAssertEqual(browse.page.items.first?.creatorID, Self.author)
  }

  /// A page of collections carries every collection's children, over a megabyte of page data.
  func testAPageOfAMegabyteOrMoreIsStillRead() throws {
    var rows = (1...30).map { collectionRow(String(900 + $0), children: (1...40).map { (String(5000 + $0), $0, 0) }) }
    for index in rows.indices { rows[index]["short_description"] = String(repeating: "\"quoted\" \\ text ", count: 2400) }
    let html = browseHTML(rows: rows)
    XCTAssertGreaterThan(html.count, 1_000_000)
    let browse = try WorkshopService.decodeBrowse(String(decoding: html, as: UTF8.self))
    XCTAssertEqual(browse.page.items.count, 30)
    XCTAssertEqual(browse.children["901"]?.count, 40)
  }

  /// Steam served `renderContext` through `JSON.parse` before its `valve-ssr-data` block.
  func testOlderBrowsePagesAreStillRead() throws {
    let browse = try WorkshopService.decodeBrowse(String(decoding: browseHTML(rows: [
      wallpaperRow("12", tags: ["Scene"]),
    ], legacy: true), as: UTF8.self))
    XCTAssertEqual(browse.page.items.map(\.id), ["12"])
  }

  func testDetailsMarkCollectionsMadeBySteamsCollectionApp() throws {
    var row = detailsRow("5", tags: [])
    row["creator_app_id"] = WorkshopService.collectionCreatorApp
    XCTAssertEqual(WorkshopService.item(details: row)?.collectionSize, 0)
    XCTAssertNil(WorkshopService.item(details: detailsRow("6", tags: []))?.collectionSize)
  }

  func testUnfilteredSourcesFollowTheSidebarsRules() {
    let page = WorkshopPage(
      items: [
        item("1", tags: ["Scene", "Anime", "Everyone"]),
        item("2", tags: ["scene", "Mature"]),
        item("3", tags: ["Video", "Everyone"]),
        item("4", tags: ["Scene", "Everyone"], collection: true),
      ], page: 1, totalPages: 1, totalCount: 4)
    XCTAssertEqual(WorkshopService.matching(page, tags: ["Scene"], excludedTags: ["mature"]).items.map(\.id), ["1"])
    // Only a hidden rating makes an unvouched collection unsafe to show.
    XCTAssertEqual(WorkshopService.matching(page, tags: [], excludedTags: ["Anime"]).items.map(\.id), ["2", "3", "4"])
    // A tag both required and excluded is required, as it is on Steam.
    XCTAssertEqual(WorkshopService.matching(page, tags: ["Mature"], excludedTags: ["Mature"]).items.map(\.id), ["2"])
    XCTAssertEqual(WorkshopService.matching(page, tags: [], excludedTags: []).totalCount, 4)
  }

  // MARK: Fetching

  /// Collections carry no rating of their own: while one is hidden, a collection is shown only
  /// when its first wallpapers all carry none of the hidden tags.
  func testCollectionsWhoseWallpapersCarryAHiddenRatingAreNotShown() async throws {
    fixture.browse = browseHTML(rows: [
      collectionRow("901", children: [("1", 0, 0), ("2", 0, 1)]),
      collectionRow("902", children: [("3", 0, 0), ("4", 0, 1)]),
      collectionRow("903", children: []),
      collectionRow("904", children: [("5", 0, 0)], tags: ["Mature"]),
    ])
    fixture.details = [
      "1": detailsRow("1", tags: ["Scene", "Everyone"]), "2": detailsRow("2", tags: ["Video", "Everyone"]),
      "3": detailsRow("3", tags: ["Scene", "Everyone"]), "4": detailsRow("4", tags: ["Scene", "Mature"]),
      "5": detailsRow("5", tags: ["Scene", "Everyone"]),
    ]
    let screened = try await fixture.service.collections(
      search: "", sort: .topRated, page: 1, tags: [], excludedTags: WorkshopStore.defaultExcludedTags)
    XCTAssertEqual(screened.items.map(\.id), ["901"])
    XCTAssertEqual(fixture.browseSections, ["collections"])

    let open = try await fixture.service.collections(
      search: "", sort: .topRated, page: 1, tags: [], excludedTags: ["Application"])
    XCTAssertEqual(open.items.map(\.id), ["901", "902", "903", "904"])
    XCTAssertEqual(fixture.detailsRequests, 1, "Nothing is sampled while every rating is shown")
  }

  func testCollectionPagesHoldItsItemsThirtyAtATime() async throws {
    let children = (1...35).map { (String(1000 + $0), $0) }
    fixture.collection = collectionJSON(children: children)
    fixture.details = Dictionary(uniqueKeysWithValues: children.map { ($0.0, detailsRow($0.0, tags: ["Scene", "Everyone"])) })
    let first = try await fixture.service.collectionPage(id: "77", page: 1, tags: [], excludedTags: [])
    XCTAssertEqual(first.items.count, 30)
    XCTAssertEqual(first.items.first?.id, "1001")
    XCTAssertEqual(first.totalPages, 2)
    XCTAssertEqual(first.totalCount, 35)
    let second = try await fixture.service.collectionPage(id: "77", page: 2, tags: [], excludedTags: [])
    XCTAssertEqual(second.items.map(\.id), ["1031", "1032", "1033", "1034", "1035"])
  }

  func testAnAuthorsPageIsTitledWithTheirNameAndTheirItemsCarryIt() async throws {
    fixture.profiles[Self.author] = profileHTML(ids: ["1", "2"], name: "Fixture Author", total: "2")
    fixture.details = ["1": detailsRow("1", tags: ["Scene", "Everyone"]), "2": detailsRow("2", tags: ["Scene", "Mature"])]
    var query = WorkshopQuery(text: "", kind: .all, sort: .topRated, excludedTags: ["Mature"])
    query.source = .creator(id: Self.author, name: "Old name")
    let page = try await fixture.service.page(for: query, page: 1, account: nil)
    XCTAssertEqual(page.items.map(\.id), ["1"])
    XCTAssertEqual(page.items.first?.creator, "Fixture Author")
    XCTAssertEqual(page.title, "Fixture Author")
    XCTAssertNil(fixture.cookies.compactMap { $0 }.first, "An author's public page is read without a session")
  }

  func testSubscriptionsAreReadWithTheSessionAndEveryPageOfThem() async throws {
    let session = try XCTUnwrap(SteamWebSession(cookie: "\(Self.author)||0123456789abcdef0123"))
    fixture.subscriptionPages = [
      1: subscriptionsHTML(ids: (1...30).map(String.init), total: "32"),
      2: subscriptionsHTML(ids: ["31", "32"], total: "32"),
    ]
    let ids = try await fixture.service.subscribedIDs(account: session)
    XCTAssertEqual(ids, (1...32).map(String.init))
    XCTAssertEqual(fixture.cookies, ["steamLoginSecure=\(session.cookie)", "steamLoginSecure=\(session.cookie)"])
  }

  // MARK: Store

  func testOpeningAnAuthorFromACollectionComesBackTheWayItWent() async throws {
    let store = fixture.store
    fixture.browse = browseHTML(rows: [wallpaperRow("12", tags: ["Scene", "Everyone"])])
    fixture.collection = collectionJSON(children: [("12", 0)])
    fixture.details = ["12": detailsRow("12", tags: ["Scene", "Everyone"])]
    fixture.profiles[Self.author] = profileHTML(ids: ["12"], name: "Fixture Author", total: "1")

    store.open(.collections)
    try await finished(store)
    store.open(.collection(id: "77", title: "Night skies"))
    try await finished(store)
    XCTAssertEqual(store.committedQuery?.source, .collection(id: "77", title: "Night skies"))
    store.open(.creator(id: Self.author, name: "Workshop creator"))
    try await finished(store)
    XCTAssertEqual(store.sourceTitle, "Fixture Author")
    XCTAssertEqual(store.sourceHistory, [.collections, .collection(id: "77", title: "Night skies")])

    store.back()
    try await finished(store)
    XCTAssertEqual(store.source, .collection(id: "77", title: "Night skies"))
    store.back()
    try await finished(store)
    XCTAssertEqual(store.source, .collections)
    XCTAssertEqual(store.sourceHistory, [])
    // Choosing a list afresh forgets the way back.
    store.open(.creator(id: Self.author, name: ""))
    try await finished(store)
    store.open(.browse)
    XCTAssertEqual(store.sourceHistory, [])
    try await finished(store)
  }

  func testSubscriptionsWaitForASignInAndAnEndedSessionIsForgotten() async throws {
    let store = fixture.store
    store.open(.subscriptions)
    try await finished(store)
    XCTAssertNotNil(store.errorMessage)
    XCTAssertEqual(store.items, [])

    // A window closed before signing in changes nothing; a cookie that is not a session is refused.
    try await store.signInToSteamWeb { nil }
    XCTAssertNil(store.steamWebSession)
    do {
      try await store.signInToSteamWeb { WebSignInCookies(session: "not-a-session") }
      XCTFail("A cookie that is not a Steam session must be refused")
    } catch {}
    XCTAssertNil(store.steamWebSession)

    fixture.subscriptionPages = [1: subscriptionsHTML(ids: ["1"], total: "1")]
    fixture.details = ["1": detailsRow("1", tags: ["Scene", "Everyone"])]
    try await store.signInToSteamWeb { WebSignInCookies(session: "\(Self.author)||0123456789abcdef0123") }
    try await finished(store)
    XCTAssertEqual(store.items.map(\.id), ["1"])
    XCTAssertNil(store.errorMessage)

    let missing = try await store.missingSubscriptions(installed: ["1"])
    XCTAssertEqual(missing, [])

    // Steam answers with its sign-in page once the session has ended.
    fixture.subscriptionPages = [1: Data("<html><head><title>Sign In</title></head></html>".utf8)]
    store.search()
    try await finished(store)
    XCTAssertNil(store.steamWebSession)
    XCTAssertEqual(store.errorMessage, SteamSignInRequired().localizedDescription)
    XCTAssertEqual(store.items, [])
    XCTAssertFalse(store.hasLoaded)

    fixture.subscriptionPages = [1: subscriptionsHTML(ids: ["1"], total: "1")]
    try await store.signInToSteamWeb { WebSignInCookies(session: "\(Self.author)||0123456789abcdef0123") }
    try await finished(store)
    store.signOutOfSteamWeb()
    XCTAssertNil(store.steamWebSession)
    XCTAssertEqual(store.items, [])
    XCTAssertFalse(store.hasLoaded)
  }

  /// The Steam Community session outlives the app: a sign-in is saved, the next launch takes it
  /// back and reads subscriptions with it, and signing out, or Steam ending it, forgets it there too.
  func testTheSteamCommunitySessionIsSavedForTheNextLaunchAndForgottenWithIt() async throws {
    let access = SteamWebFixtures.cookie(SteamWebFixtures.token(expiresIn: 3600))
    let refresh = SteamWebFixtures.cookie(SteamWebFixtures.token(expiresIn: 86_400, salt: "r"))
    try await fixture.store.signInToSteamWeb { WebSignInCookies(session: access, companion: refresh) }
    XCTAssertEqual(fixture.webSessions.session?.cookie, access)
    XCTAssertNotNil(fixture.webSessions.session?.refreshToken)

    let relaunched = fixture.relaunchedStore()
    defer { relaunched.cancelSearch() }
    XCTAssertNil(relaunched.steamWebSession, "nothing is read before the launch asks for it")
    fixture.subscriptionPages = [1: subscriptionsHTML(ids: ["1"], total: "1")]
    fixture.details = ["1": detailsRow("1", tags: ["Scene", "Everyone"])]
    relaunched.open(.subscriptions)
    relaunched.restoreSteamWebSession()
    // The list asked first; it waits for the keychain and then reads with the saved session.
    try await finished(relaunched)
    XCTAssertEqual(relaunched.steamWebSession?.cookie, access)
    XCTAssertEqual(relaunched.items.map(\.id), ["1"])
    XCTAssertEqual(fixture.cookies.last, "steamLoginSecure=\(access)")
    XCTAssertTrue(fixture.renewalForms.isEmpty, "a fresh cookie is not renewed")

    relaunched.signOutOfSteamWeb()
    XCTAssertNil(fixture.webSessions.session)

    try await fixture.store.signInToSteamWeb { WebSignInCookies(session: access, companion: refresh) }
    fixture.subscriptionPages = [1: Data("<html><head><title>Sign In</title></head></html>".utf8)]
    fixture.store.open(.subscriptions)
    try await finished(fixture.store)
    XCTAssertNil(fixture.store.steamWebSession)
    XCTAssertNil(fixture.webSessions.session, "a session Steam ended is not taken back next launch")
  }

  /// The cookie lasts about a day and the renewal token months: an expired cookie is traded for a
  /// new one before subscriptions are read, and the new one is saved. Steam refusing the token
  /// ends the session.
  func testAnExpiredCookieIsRenewedBeforeSubscriptionsAreRead() async throws {
    let refreshToken = SteamWebFixtures.token(expiresIn: 86_400, salt: "r")
    let expired = SteamWebFixtures.cookie(SteamWebFixtures.token(expiresIn: -60))
    let fresh = SteamWebFixtures.token(expiresIn: 3600, salt: "n")
    fixture.renewal = Data(#"{"response":{"access_token":"\#(fresh)"}}"#.utf8)
    fixture.subscriptionPages = [1: subscriptionsHTML(ids: ["1"], total: "1")]
    fixture.details = ["1": detailsRow("1", tags: ["Scene", "Everyone"])]
    let store = fixture.store
    try await store.signInToSteamWeb {
      WebSignInCookies(session: expired, companion: SteamWebFixtures.cookie(refreshToken))
    }
    store.open(.subscriptions)
    try await finished(store)

    XCTAssertEqual(store.items.map(\.id), ["1"])
    XCTAssertEqual(fixture.renewalForms.count, 1)
    let form = try XCTUnwrap(fixture.renewalForms.first)
    XCTAssertTrue(form.contains("refresh_token=\(refreshToken)"))
    XCTAssertTrue(form.contains("steamid=\(SteamWebFixtures.account)"))
    let renewedCookie = SteamWebFixtures.cookie(fresh)
    XCTAssertEqual(fixture.cookies.last, "steamLoginSecure=\(renewedCookie)")
    XCTAssertFalse(fixture.cookies.contains("steamLoginSecure=\(expired)"), "the expired cookie is never sent")
    XCTAssertEqual(store.steamWebSession?.cookie, renewedCookie)
    XCTAssertEqual(fixture.webSessions.session?.cookie, renewedCookie)
    XCTAssertEqual(fixture.webSessions.session?.refreshToken, refreshToken)

    // Steam refuses the token: the session ends, here and on this Mac.
    try await store.signInToSteamWeb {
      WebSignInCookies(session: expired, companion: SteamWebFixtures.cookie(refreshToken))
    }
    fixture.renewal = Data(#"{"response":{}}"#.utf8)
    do {
      _ = try await store.missingSubscriptions(installed: [])
      XCTFail("A refused renewal must ask for a new sign-in")
    } catch is SteamSignInRequired {}
    XCTAssertNil(store.steamWebSession)
    XCTAssertNil(fixture.webSessions.session)
  }

  /// Issue #27: choosing subscriptions without a Steam Community session, while another list
  /// is on show, must not leave that list's tiles behind; an empty grid is what offers sign-in.
  func testSubscriptionsWithoutASessionDropTheListOnShow() async throws {
    let store = fixture.store
    fixture.collection = collectionJSON(children: [("12", 0)])
    fixture.details = ["12": detailsRow("12", tags: ["Scene", "Everyone"])]
    store.open(.collection(id: "77", title: "Night skies"))
    try await finished(store)
    XCTAssertEqual(store.items.map(\.id), ["12"])

    store.open(.subscriptions)
    try await finished(store)
    XCTAssertNil(store.steamWebSession)
    XCTAssertEqual(store.items, [])
    XCTAssertEqual(store.totalCount, 0)
    XCTAssertEqual(store.totalPages, 1)
    XCTAssertFalse(store.hasLoaded)
  }

  /// Screening leaves gaps in Steam's pages of collections, so a panel page is filled from as
  /// many of them as it takes: paging on shows every kept collection once, in Steam's order,
  /// each Steam page is read once, and paging back needs no request.
  func testScreenedCollectionsFillEachPageFromTheSteamPagesAfterIt() async throws {
    // Four Steam pages of 30; every third collection holds a Mature wallpaper, so 20 a page stay.
    var kept: [String] = []
    var details: [String: [String: Any]] = [:]
    for page in 1...4 {
      let rows = (0..<30).map { index -> [String: Any] in
        let id = String(page * 1000 + index)
        let child = String(page * 1000 + 500 + index)
        let rating = index % 3 == 0 ? "Mature" : "Everyone"
        details[child] = detailsRow(child, tags: ["Scene", rating])
        if rating == "Everyone" { kept.append(id) }
        return collectionRow(id, children: [(child, 0, 0)])
      }
      fixture.browsePages[page] = browseHTML(rows: rows, page: page, pages: 4, count: 120)
    }
    fixture.details = details
    let store = fixture.store

    store.open(.collections)
    try await finished(store)
    XCTAssertEqual(store.items.map(\.id), Array(kept[0..<30]))
    XCTAssertEqual(store.totalPages, 3)
    store.loadPage(2)
    try await finished(store)
    XCTAssertEqual(store.items.map(\.id), Array(kept[30..<60]))
    store.loadPage(3)
    try await finished(store)
    XCTAssertEqual(store.items.map(\.id), Array(kept[60...]))
    XCTAssertEqual(store.totalPages, 3)
    XCTAssertEqual(store.totalCount, kept.count)
    let steamPage = URLComponents(url: store.browseURL, resolvingAgainstBaseURL: false)?.queryItems?
      .first { $0.name == "p" }?.value
    XCTAssertEqual(steamPage, "4", "Open on Steam goes to the Steam page the panel page starts on")
    XCTAssertEqual(fixture.browsePagesRequested.sorted(), [1, 2, 3, 4])

    store.loadPage(1)
    XCTAssertFalse(store.isLoading)
    XCTAssertEqual(store.items.map(\.id), Array(kept[0..<30]))
    XCTAssertEqual(fixture.browsePagesRequested.count, 4)

    // A page jumped to is still full, and starts past what the first page showed.
    store.search()
    try await finished(store)
    store.loadPage(3)
    try await finished(store)
    XCTAssertEqual(store.page, 3)
    XCTAssertEqual(store.items.count, 30)
    XCTAssertTrue(Set(store.items.map(\.id)).isDisjoint(with: kept[0..<30]))
    XCTAssertNil(store.errorMessage)
  }

  /// A panel page whose read limit runs out before any collection passes is empty but leaves
  /// Next to read on, and the count on the last page adds up what each page really showed.
  func testAPageEmptiedByTheReadLimitLeadsOnAndTheLastPageCountsWhatWasShown() async throws {
    var kept: [String] = []
    var details: [String: [String: Any]] = [:]
    let steamPages = WorkshopStore.maxSteamPagesPerPage + 2
    for page in 1...steamPages {
      let rows = (0..<30).map { index -> [String: Any] in
        let id = String(page * 1000 + index)
        let child = String(page * 1000 + 500 + index)
        let rating = page > WorkshopStore.maxSteamPagesPerPage ? "Everyone" : "Mature"
        details[child] = detailsRow(child, tags: ["Scene", rating])
        if rating == "Everyone" { kept.append(id) }
        return collectionRow(id, children: [(child, 0, 0)])
      }
      fixture.browsePages[page] = browseHTML(rows: rows, page: page, pages: steamPages, count: steamPages * 30)
    }
    fixture.details = details
    let store = fixture.store

    store.open(.collections)
    try await finished(store)
    XCTAssertEqual(store.items, [])
    XCTAssertGreaterThan(store.totalPages, 1, "Next reads on past the limit")
    XCTAssertGreaterThan(store.totalCount, 0)
    var page = 1
    while page < store.totalPages {
      page += 1
      store.loadPage(page)
      try await finished(store)
    }
    XCTAssertEqual(store.items.map(\.id), Array(kept[30...]))
    XCTAssertEqual(store.totalCount, kept.count)
  }

  // MARK: A pasted link or id

  private static let pasted = "3632513108"

  /// A pasted link or id is one tile, shown whatever the sidebar's rating, tags and type say:
  /// it was asked for by name. Steam's browse page is never asked for it.
  func testAPastedLinkOrIdShowsThatOneItemAndNeverAsksForABrowsePage() async throws {
    let store = fixture.store
    fixture.browse = browseHTML(rows: [wallpaperRow("12", tags: ["Scene", "Everyone"])])
    fixture.details = [Self.pasted: detailsRow(Self.pasted, tags: ["Video", "Mature"])]
    store.excludedTags = ["Mature", "Application"]
    store.kind = .scene
    store.tags = ["Approved"]
    for text in [
      "https://steamcommunity.com/sharedfiles/filedetails/?id=\(Self.pasted)&searchtext=forest",
      "steam://url/CommunityFilePage/\(Self.pasted)", Self.pasted, "  \(Self.pasted)\n",
    ] {
      store.searchText = text
      store.search()
      try await finished(store)
      XCTAssertEqual(store.items.map(\.id), [Self.pasted], text)
      XCTAssertEqual(store.items.first?.kind, .video)
      XCTAssertEqual(store.page, 1)
      XCTAssertEqual(store.totalPages, 1)
      XCTAssertEqual(store.totalCount, 1)
      XCTAssertEqual(store.reachableCount, 1)
      XCTAssertTrue(store.hasLoaded)
      XCTAssertNil(store.errorMessage)
      XCTAssertEqual(store.committedQuery?.itemID, Self.pasted)
      XCTAssertEqual(store.browseURL, WorkshopItem.pageURL(id: Self.pasted), "Open on Steam opens the item")
    }
    XCTAssertEqual(fixture.browsePagesRequested, [], "the browse page is never read for a pasted item")
    XCTAssertEqual(fixture.detailsRequests, 4)

    // Words are searched as before, and the item no longer stands in for their results.
    store.searchText = "forest"
    store.kind = .all
    store.tags = []
    store.search()
    try await finished(store)
    XCTAssertEqual(store.items.map(\.id), ["12"])
    XCTAssertNil(store.committedQuery?.itemID)
    XCTAssertEqual(fixture.browsePagesRequested, [1])
  }

  /// Steam serves a collection as an item of its own, which opens like one from a list.
  func testAPastedCollectionIsShownAsACollectionTile() async throws {
    var row = detailsRow("77", tags: [])
    row["creator_app_id"] = WorkshopService.collectionCreatorApp
    fixture.details = ["77": row]
    let store = fixture.store
    store.searchText = "https://steamcommunity.com/sharedfiles/filedetails/?id=77"
    store.search()
    try await finished(store)
    XCTAssertEqual(store.items.map(\.id), ["77"])
    XCTAssertNotNil(store.items.first?.collectionSize)
  }

  /// An item that cannot be shown is an ordinary failed load: the banner and Retry, with the
  /// list on show left as it was, and Retry asks for the same item again.
  func testAPastedItemThatCannotBeShownFailsLikeAnyLoadAndRetryAsksAgain() async throws {
    let store = fixture.store
    fixture.browse = browseHTML(rows: [wallpaperRow("12", tags: ["Scene", "Everyone"])])
    store.search()
    try await finished(store)
    XCTAssertEqual(store.items.map(\.id), ["12"])

    var otherApp = detailsRow(Self.pasted, tags: ["Scene"])
    otherApp["consumer_app_id"] = 440
    var messages: [String] = []
    let answers: [[String: [String: Any]]] = [
      [:], [Self.pasted: otherApp], [Self.pasted: detailsRow(Self.pasted, tags: ["Application"])],
    ]
    for answer in answers {
      fixture.details = answer
      store.searchText = Self.pasted
      store.search()
      try await finished(store)
      messages.append(try XCTUnwrap(store.errorMessage))
      XCTAssertEqual(store.items.map(\.id), ["12"], "the list on show stays")
      XCTAssertEqual(store.failedRequest?.query.itemID, Self.pasted)
      XCTAssertEqual(store.failedRequest?.page, 1)
    }
    XCTAssertEqual(Set(messages).count, 3, "each reason is told apart")

    fixture.details = [Self.pasted: detailsRow(Self.pasted, tags: ["Scene", "Everyone"])]
    store.retrySearch()
    try await finished(store)
    XCTAssertEqual(store.items.map(\.id), [Self.pasted])
    XCTAssertNil(store.errorMessage)
    XCTAssertNil(store.failedRequest)
    XCTAssertEqual(fixture.browsePagesRequested, [1], "only the first, ordinary search read the browse page")
  }

  /// The other sources read the text as words, so an id typed there is not looked up.
  func testOtherSourcesIgnoreAPastedId() async throws {
    let store = fixture.store
    fixture.browse = browseHTML(rows: [collectionRow("901", children: [])])
    fixture.details = [Self.pasted: detailsRow(Self.pasted, tags: ["Scene", "Everyone"])]
    store.excludedTags = []
    store.searchText = Self.pasted
    store.open(.collections)
    try await finished(store)
    XCTAssertEqual(store.items.map(\.id), ["901"])
    XCTAssertEqual(fixture.browseSections, ["collections"])
    XCTAssertEqual(fixture.detailsRequests, 0, "no item was looked up")
    XCTAssertNil(store.committedQuery?.itemID)
    XCTAssertEqual(
      URLComponents(url: store.browseURL, resolvingAgainstBaseURL: false)?.queryItems?
        .first { $0.name == "searchtext" }?.value, Self.pasted)
  }

  // MARK: A browse page whose markup changed

  private static let degradedIDs = ["1000000001", "1000000002", "1000000003"]

  private func serve(_ ids: [String]) {
    fixture.details = Dictionary(uniqueKeysWithValues: ids.map { ($0, detailsRow($0, tags: ["Scene", "Everyone"])) })
  }

  /// A page without the render context is not an error while its links still name the items:
  /// they are listed in the page's order from their details, once each, and the list says it
  /// is approximate. Its totals are the number of items seen.
  func testAPageWithoutTheRenderContextIsListedFromItsLinks() async throws {
    let store = fixture.store
    let ids = Self.degradedIDs
    fixture.browse = linksOnlyHTML(ids: [ids[2], ids[0], ids[1], ids[0]])
    serve(ids)
    store.search()
    try await finished(store)
    XCTAssertEqual(store.items.map(\.id), [ids[2], ids[0], ids[1]])
    XCTAssertTrue(store.isDegraded)
    XCTAssertNil(store.errorMessage)
    XCTAssertTrue(store.hasLoaded)
    XCTAssertEqual(store.page, 1)
    XCTAssertEqual(store.totalPages, 1)
    XCTAssertEqual(store.totalCount, 3)
    XCTAssertEqual(fixture.detailsRequests, 1, "one batched request for the whole page")
  }

  /// Steam renaming the query key leaves the rows in its data: their ids are found there, and
  /// an id Steam no longer serves, or that is not Wallpaper Engine's, is left out.
  func testARenamedQueryIsListedFromTheIdsInItsData() async throws {
    let store = fixture.store
    let ids = Self.degradedIDs
    fixture.browse = browseHTML(
      rows: [ids[1], "1000000099", ids[2], ids[0]].map { wallpaperRow($0, tags: ["Scene"]) }, queryKey: "workshop_browse_v2")
    serve(ids)
    store.search()
    try await finished(store)
    XCTAssertEqual(store.items.map(\.id), [ids[1], ids[2], ids[0]])
    XCTAssertTrue(store.isDegraded)
    XCTAssertNil(store.errorMessage)

    // The next search reads an ordinary page again, and the list is no longer approximate.
    fixture.browse = browseHTML(rows: [wallpaperRow("12", tags: ["Scene"])])
    store.searchText = "forest"
    store.search()
    try await finished(store)
    XCTAssertEqual(store.items.map(\.id), ["12"])
    XCTAssertFalse(store.isDegraded)
  }

  /// A full page of links suggests a page after it, and a page past the first counts the pages
  /// before it; a short page is taken as the last.
  func testAFullDegradedPageOffersAnotherPageAndAShortOneIsTheLast() async throws {
    let store = fixture.store
    let first = (0..<30).map { String(2_000_000_000 + $0) }
    let second = (30..<35).map { String(2_000_000_000 + $0) }
    fixture.browsePages = [1: linksOnlyHTML(ids: first), 2: linksOnlyHTML(ids: second)]
    serve(first + second)
    store.search()
    try await finished(store)
    XCTAssertEqual(store.items.map(\.id), first)
    XCTAssertTrue(store.isDegraded)
    XCTAssertEqual(store.totalPages, 2)

    store.loadPage(2)
    try await finished(store)
    XCTAssertEqual(store.items.map(\.id), second)
    XCTAssertTrue(store.isDegraded)
    XCTAssertEqual(store.page, 2)
    XCTAssertEqual(store.totalPages, 2)
    XCTAssertEqual(store.totalCount, 35)
  }

  /// With nothing in the page to list, the original failure stands: an unreadable page never
  /// passes for an empty list, and a list that cannot be listed is not invented.
  func testAPageThatNamesNoItemFailsAsItDidBefore() async throws {
    let store = fixture.store
    func fails(_ page: Data, serving ids: [String]) async throws {
      fixture.browse = page
      serve(ids)
      store.search()
      try await finished(store)
      XCTAssertEqual(store.errorMessage, WorkshopLayoutChanged.message)
      XCTAssertTrue(store.items.isEmpty)
      XCTAssertFalse(store.isDegraded)
      XCTAssertFalse(store.hasLoaded)
      XCTAssertNotNil(store.failedRequest)
    }
    try await fails(Data("<html><body>Steam is being rebuilt.</body></html>".utf8), serving: [])
    // Links, but not to anything Steam serves for Wallpaper Engine.
    try await fails(linksOnlyHTML(ids: Self.degradedIDs), serving: [])
    // Steam answered its own query with a failure: its links are not a list to trust.
    let before = fixture.detailsRequests
    try await fails(
      browseHTML(rows: [wallpaperRow(Self.degradedIDs[0], tags: ["Scene"])], eresult: 15), serving: Self.degradedIDs)
    XCTAssertEqual(fixture.detailsRequests, before, "no item was looked up from a page Steam failed")
  }

  /// Collections are read by the same decoder but are not listed from links: their pages carry
  /// every collection's children, which are not the page's items.
  func testCollectionsAreNotListedFromLinks() async throws {
    let store = fixture.store
    fixture.browse = linksOnlyHTML(ids: Self.degradedIDs)
    serve(Self.degradedIDs)
    store.excludedTags = []
    store.open(.collections)
    try await finished(store)
    XCTAssertEqual(store.errorMessage, WorkshopLayoutChanged.message)
    XCTAssertTrue(store.items.isEmpty)
    XCTAssertFalse(store.isDegraded)
    XCTAssertEqual(fixture.detailsRequests, 0)
  }

  // MARK: Steam busy

  /// A browse page Steam answers busy is asked for again, and the page that follows is shown
  /// as if nothing had happened.
  func testABusyAnswerIsAskedAgainAndTheNextPageIsShown() async throws {
    let store = fixture.store
    let busy = browseHTML(rows: [], eresult: 10)
    fixture.browseQueue = [busy, busy]
    fixture.browse = browseHTML(rows: [wallpaperRow("12", tags: ["Scene"])])
    store.search()
    try await finished(store)
    XCTAssertEqual(store.items.map(\.id), ["12"])
    XCTAssertNil(store.errorMessage)
    XCTAssertFalse(store.isDegraded)
    XCTAssertEqual(fixture.browsePagesRequested.count, 3)
  }

  /// Still busy after the retries: the failure says Steam is busy, not that its page changed,
  /// and no list is guessed at from the page.
  func testStayingBusySaysSoAndListsNothing() async throws {
    let store = fixture.store
    fixture.browse = browseHTML(rows: [wallpaperRow(Self.degradedIDs[0], tags: ["Scene"])], eresult: 10)
    serve(Self.degradedIDs)
    store.search()
    try await finished(store)
    XCTAssertEqual(store.errorMessage, WorkshopBusy.message)
    XCTAssertTrue(store.items.isEmpty)
    XCTAssertFalse(store.isDegraded)
    XCTAssertEqual(fixture.browsePagesRequested.count, 3)
    XCTAssertEqual(fixture.detailsRequests, 0)

    // Collections are read the same way.
    let busy = browseHTML(rows: [], eresult: 10)
    fixture.browseQueue = [busy, busy]
    fixture.browse = browseHTML(rows: [])
    store.excludedTags = []
    store.open(.collections)
    try await finished(store)
    XCTAssertNil(store.errorMessage)
    XCTAssertEqual(fixture.browsePagesRequested.count, 6)
  }

  // MARK: Fixtures

  private func finished(_ store: WorkshopStore) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    // A load starts on the next turn of the main actor; give it that turn before waiting.
    await Task.yield()
    while store.isLoading {
      guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
      try await Task.sleep(for: .milliseconds(2))
    }
  }

  private func item(_ id: String, tags: [String], collection: Bool = false) -> WorkshopItem {
    WorkshopItem(
      id: id, title: "Item \(id)", creator: "Test", summary: "", previewURL: nil, tags: tags, size: 0,
      subscriptions: 0, collectionSize: collection ? 2 : nil)
  }

  private func profileHTML(ids: [String], name: String, total: String) -> Data {
    let tiles = ids.map { "<div class=\"workshopItem\"><a data-publishedfileid=\"\($0)\"></a></div>" }.joined()
    return Data("""
      <html><head><title>Steam Community :: \(name) :: Workshop Items</title></head>
      <a href="https://steamcommunity.com/login/home/?goto=">Sign in</a>
      <div class="workshopBrowsePagingInfo">Showing 1-\(ids.count) of \(total) entries</div>
      <div class="workshopBrowseItems">\(tiles)</div></html>
      """.utf8)
  }

  /// Steam's subscriptions page: a row per item, `id="Subscription<id>"`, without the
  /// `data-publishedfileid` an author's tiles carry. The served page may leave out the row's
  /// Unsubscribe control, which its scripts add later.
  private func subscriptionsHTML(ids: [String], total: String, controls: Bool = false) -> Data {
    let rows = ids.map { id in
      let unsubscribe = controls
        ? "<span id=\"UnsubscribeItemBtn\(id)\" class=\"general_btn subscribe toggled\" onclick=\"UnsubscribeItem( '\(id)', '431960' );\"></span>"
        : ""
      return """
      <div class="workshopItemSubscription " id="Subscription\(id)">
        <div class="workshopItemSubscriptionDetails">
          <a href="https://steamcommunity.com/sharedfiles/filedetails/?id=\(id)&searchtext="><div class="workshopItemTitle">Item \(id)</div></a>
          <div class="workshopItemDate">Subscribed on 4 Oct @ 11:10pm</div>
        </div>
        <div class="workshopItemSubscriptionControls">\(unsubscribe)</div>
      </div>
      """
    }.joined()
    return Data("""
      <html><head><title>Steam Community :: Me :: Workshop Items</title></head>
      <a href="https://steamcommunity.com/login/home/?goto=">Sign in</a>
      <div class="workshopBrowsePagingInfo">Showing 1-\(ids.count) of \(total) entries</div>
      <div class="workshopBrowseItems">\(rows)</div></html>
      """.utf8)
  }

  private func collectionJSON(children: [(String, Int)]) -> Data {
    let rows = children.map { ["publishedfileid": $0.0, "sortorder": $0.1, "filetype": 0] as [String: Any] }
    let body: [String: Any] = [
      "response": [
        "result": 1, "resultcount": 1,
        "collectiondetails": [["publishedfileid": "77", "result": 1, "children": rows]],
      ]
    ]
    return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
  }

  private func detailsRow(_ id: String, tags: [String]) -> [String: Any] {
    [
      "publishedfileid": id, "result": 1, "consumer_app_id": 431960, "creator_app_id": 431960,
      "title": "Item \(id)", "creator": Self.author, "tags": tags.map { ["tag": $0] },
      "file_size": "2048", "subscriptions": 3, "time_updated": 1_700_000_000,
    ]
  }

  private func wallpaperRow(_ id: String, tags: [String]) -> [String: Any] {
    [
      "publishedfileid": id, "consumer_appid": 431960, "title": "Item \(id)", "creator": Self.author,
      "file_type": 0, "tags": tags.map { ["tag": $0] }, "file_size": "2048",
    ]
  }

  private func collectionRow(
    _ id: String, children: [(String, Int, Int)], tags: [String] = []
  ) -> [String: Any] {
    [
      "publishedfileid": id, "consumer_appid": 431960, "title": "Collection \(id)", "creator": Self.author,
      "file_type": 2, "num_children": children.count, "tags": tags.map { ["tag": $0] },
      "children": children.map { ["publishedfileid": $0.0, "sortorder": $0.1, "file_type": $0.2] },
    ]
  }

  /// A browse page of the kind Steam serves when it has changed its markup: item links and
  /// no render context to read them from.
  private func linksOnlyHTML(ids: [String]) -> Data {
    let tiles = ids.map { id in
      let link = "https://steamcommunity.com/sharedfiles/filedetails/?id=\(id)&searchtext="
      return "<div class=\"workshopItem\"><a href=\"\(link)\"><img src=\"x\"></a><a href=\"\(link)\">Item \(id)</a></div>"
    }.joined()
    return Data("<html><body><div class=\"workshopBrowseItems\">\(tiles)</div></body></html>".utf8)
  }

  private func browseHTML(
    rows: [[String: Any]], page: Int = 1, pages: Int = 1, count: Int? = nil, legacy: Bool = false,
    queryKey: String = "workshop_browse", eresult: Int = 1
  ) -> Data {
    let queries: [[String: Any]] = [
      [
        "queryKey": [queryKey],
        "state": [
          "data": [
            "eresult": eresult, "current_page": page, "total_pages": pages, "total_count": count ?? rows.count,
            "results": rows,
          ]
        ],
      ]
    ]
    guard let queryData = try? JSONSerialization.data(withJSONObject: ["queries": queries]) else { return Data() }
    let context = ["queryData": String(decoding: queryData, as: UTF8.self)]
    if legacy {
      guard let contextData = try? JSONSerialization.data(withJSONObject: context),
        let encoded = try? JSONSerialization.data(
          withJSONObject: String(decoding: contextData, as: UTF8.self), options: .fragmentsAllowed)
      else { return Data() }
      return Data(
        "<html><script>window.SSR.renderContext = JSON.parse(\(String(decoding: encoded, as: UTF8.self)));</script></html>".utf8)
    }
    guard let ssr = try? JSONSerialization.data(withJSONObject: ["loaderData": [], "renderContext": context]) else {
      return Data()
    }
    return Data(
      ("<html><body><a href=\"https://steamcommunity.com/\">Steam</a>"
        + "<script type=\"application/json\" id=\"valve-ssr-data\" nonce=\"n\">\(String(decoding: ssr, as: UTF8.self))</script>"
        + "<script nonce=\"n\">window.SSR={renderContext:d.renderContext};</script></body></html>").utf8)
  }
}

/// Answers every request of one fixture's session from what the test put there.
@MainActor
private final class SourceFixture {
  let identifier = UUID().uuidString
  let session: URLSession
  let service: WorkshopService
  let store: WorkshopStore
  /// Where the store keeps the Steam Community session between "launches".
  let webSessions = SteamWebMemorySessionStore()
  private let root: URL
  private let defaults: UserDefaults
  private let answers = SourceAnswers()

  var browse: Data {
    get { answers.read { $0.browse } }
    set { answers.write { $0.browse = newValue } }
  }
  /// Steam's browse answer for one page number; `browse` answers the others.
  var browsePages: [Int: Data] {
    get { answers.read { $0.browsePages } }
    set { answers.write { $0.browsePages = newValue } }
  }
  /// Steam's next browse answers, one per request, before `browsePages` and `browse`.
  var browseQueue: [Data] {
    get { answers.read { $0.browseQueue } }
    set { answers.write { $0.browseQueue = newValue } }
  }
  var collection: Data {
    get { answers.read { $0.collection } }
    set { answers.write { $0.collection = newValue } }
  }
  var details: [String: [String: Any]] {
    get { answers.read { $0.details } }
    set { answers.write { $0.details = newValue } }
  }
  var profiles: [String: Data] {
    get { answers.read { $0.profiles } }
    set { answers.write { $0.profiles = newValue } }
  }
  var subscriptionPages: [Int: Data] {
    get { answers.read { $0.subscriptionPages } }
    set { answers.write { $0.subscriptionPages = newValue } }
  }
  var browseSections: [String] { answers.read { $0.browseSections } }
  var browsePagesRequested: [Int] { answers.read { $0.browsePagesRequested } }
  var detailsRequests: Int { answers.read { $0.detailsRequests } }
  var cookies: [String?] { answers.read { $0.cookies } }
  /// What Steam's token service answers a renewal with; empty refuses it, as Steam does.
  var renewal: Data {
    get { answers.read { $0.renewal } }
    set { answers.write { $0.renewal = newValue } }
  }
  /// The form of each renewal request.
  var renewalForms: [String] { answers.read { $0.renewalForms } }

  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "WorkshopSourceTests-\(identifier)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SourceFixtureProtocol.self]
    configuration.httpAdditionalHeaders = ["X-Source-Test": identifier]
    configuration.urlCache = nil
    configuration.timeoutIntervalForRequest = 5
    session = URLSession(configuration: configuration)
    SourceFixtureProtocol.register(identifier, answers: answers)
    service = WorkshopService(session: session, busyRetryDelays: [.zero, .zero])
    defaults = TemporaryDefaults.makeForCurrentTest().defaults
    store = WorkshopStore(
      service: service,
      downloader: WorkshopDownloadManager(sessionDirectory: root.appendingPathComponent("SteamSession")),
      supportDirectory: root, defaults: defaults, webSessions: webSessions)
  }

  /// Another store over the same Steam answers and saved session: the app's next launch.
  func relaunchedStore() -> WorkshopStore {
    WorkshopStore(
      service: service,
      downloader: WorkshopDownloadManager(sessionDirectory: root.appendingPathComponent("SteamSession")),
      supportDirectory: root, defaults: defaults, webSessions: webSessions)
  }

  func remove() {
    store.cancelSearch()
    session.invalidateAndCancel()
    SourceFixtureProtocol.remove(identifier)
    try? FileManager.default.removeItem(at: root)
  }
}

private final class SourceAnswers: @unchecked Sendable {
  struct State {
    var browse = Data()
    var browsePages: [Int: Data] = [:]
    var browseQueue: [Data] = []
    var collection = Data()
    var details: [String: [String: Any]] = [:]
    var profiles: [String: Data] = [:]
    var subscriptionPages: [Int: Data] = [:]
    var browseSections: [String] = []
    var browsePagesRequested: [Int] = []
    var detailsRequests = 0
    var cookies: [String?] = []
    var renewal = Data(#"{"response":{}}"#.utf8)
    var renewalForms: [String] = []
  }
  private let lock = NSLock()
  private var state = State()
  func read<T>(_ body: (State) -> T) -> T { lock.withLock { body(state) } }
  func write(_ body: (inout State) -> Void) { lock.withLock { body(&state) } }

  /// The status and body Steam would answer `request` with.
  func answer(_ request: URLRequest, body: Data) -> (Int, Data) {
    guard let url = request.url, let host = url.host else { return (404, Data()) }
    let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    let value = { (name: String) in query.first { $0.name == name }?.value }
    // `URL.path` drops a trailing slash.
    let path = url.path.hasSuffix("/") ? String(url.path.dropLast()) : url.path
    return lock.withLock {
      if host == "steamcommunity.com" { state.cookies.append(request.value(forHTTPHeaderField: "Cookie")) }
      switch (host, path) {
      case ("steamcommunity.com", "/workshop/browse"):
        state.browseSections.append(value("section") ?? "")
        let page = Int(value("p") ?? "1") ?? 1
        state.browsePagesRequested.append(page)
        if !state.browseQueue.isEmpty { return (200, state.browseQueue.removeFirst()) }
        return (200, state.browsePages[page] ?? state.browse)
      case ("api.steampowered.com", "/IAuthenticationService/GenerateAccessTokenForApp/v1"):
        state.renewalForms.append(String(decoding: body, as: UTF8.self))
        return (200, state.renewal)
      case ("api.steampowered.com", "/ISteamRemoteStorage/GetCollectionDetails/v1"):
        return (200, state.collection)
      case ("api.steampowered.com", "/ISteamRemoteStorage/GetPublishedFileDetails/v1"):
        state.detailsRequests += 1
        let form = String(decoding: body, as: UTF8.self)
        let ids = form.split(separator: "&").filter { $0.hasPrefix("publishedfileids") }
          .compactMap { $0.split(separator: "=").last.map(String.init) }
        let rows: [[String: Any]] = ids.map { state.details[$0] ?? ["publishedfileid": $0, "result": 9] }
        let json = try? JSONSerialization.data(withJSONObject: ["response": ["publishedfiledetails": rows]])
        return (200, json ?? Data())
      default:
        let parts = path.split(separator: "/")
        guard host == "steamcommunity.com", parts.count == 3, parts[0] == "profiles", parts[2] == "myworkshopfiles"
        else { return (404, Data()) }
        if value("browsefilter") == "mysubscriptions" {
          return (200, state.subscriptionPages[Int(value("p") ?? "1") ?? 1] ?? Data())
        }
        return (200, state.profiles[String(parts[1])] ?? Data())
      }
    }
  }
}

private final class SourceFixtureProtocol: URLProtocol, @unchecked Sendable {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var registry: [String: SourceAnswers] = [:]

  static func register(_ identifier: String, answers: SourceAnswers) {
    lock.withLock { registry[identifier] = answers }
  }
  static func remove(_ identifier: String) {
    _ = lock.withLock { registry.removeValue(forKey: identifier) }
  }
  // Installed only in fixture sessions: every request is claimed, so none reaches the network.
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    let answers = Self.lock.withLock { Self.registry[request.value(forHTTPHeaderField: "X-Source-Test") ?? ""] }
    guard let answers, let url = request.url else {
      client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
      return
    }
    let (status, data) = answers.answer(request, body: Self.body(of: request))
    let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: data)
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
      let read = stream.read(&buffer, maxLength: buffer.count)
      guard read > 0 else { break }
      data.append(buffer, count: read)
    }
    return data
  }
}
