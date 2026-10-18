import Foundation

/// The pixiv page's list-level state: the query, the works that pass it, how far paging has gone
/// and what the last load said.
///
/// Per-tile state (the saved pages, the download ring) and the selected work's state are asked for
/// separately, so a progress tick re-renders its own tile and not the grid.
struct PixivBrowseState: Equatable {
  /// What the page edits and last committed: sanitized for the account, so a signed-out query never
  /// asks for R-18 works.
  let query: PixivQuery
  /// The results on show answer a tag search, so the toolbar offers search orders and the summary
  /// counts results instead of naming a ranking.
  let isSearching: Bool
  /// The works on the page that the committed query's filters admit, in pixiv's order.
  let works: [PixivWork]
  /// Works pixiv returned for this page that the age rating, orientation or size filters hide.
  let hiddenCount: Int
  let totalCount: Int
  let pager: ResultPager
  let isLoading: Bool
  /// A page has arrived; before that the page is not empty, it is loading.
  let hasLoaded: Bool
  /// Why the last load failed. It shows in the empty state or the pager, not in the error banner.
  let errorMessage: String?
  let selectedID: String?

  @MainActor
  init(_ pixiv: PixivStore) {
    query = pixiv.query
    if case .search = (pixiv.committedQuery ?? pixiv.query).listing {
      isSearching = true
    } else {
      isSearching = false
    }
    works = pixiv.works
    hiddenCount = pixiv.hiddenCount
    totalCount = pixiv.totalCount
    pager = ResultPager(
      page: pixiv.page, totalPages: pixiv.totalPages, isLoading: pixiv.isLoading,
      maxPages: PixivService.maxPages)
    isLoading = pixiv.isLoading
    hasLoaded = pixiv.hasLoaded
    errorMessage = pixiv.errorMessage
    selectedID = pixiv.selectedWork?.id
  }
}

/// Who is signed in to pixiv, and what that unlocks: members-only works and, if the account allows
/// them, R-18 works. The session itself is never part of it.
struct PixivAccountState: Equatable {
  /// A session is held, even before pixiv confirmed it.
  let isSignedIn: Bool
  /// The sign-in window is open, or the session it produced is being checked.
  let isSigningIn: Bool
  /// The account's name, once pixiv confirmed the session.
  let name: String?
  let id: String?
  /// Whether the account's viewing restrictions allow R-18 works; nil when pixiv did not say.
  let showsR18: Bool?
  /// Why the last sign-in did not take, or that pixiv ended the session.
  let message: String?

  /// What the note under the age-rating boxes says.
  enum R18Note: Equatable {
    /// Signed out: sign in to show R-18 works.
    case signInToShow
    /// The account hides R-18 works in pixiv's own settings.
    case accountHidesThem
    /// R-18G works are never shown, whoever signs in.
    case neverShowsR18G
  }

  /// The Mature (R-18) box is tickable only with a session; without one it stays visible and off.
  var allowsMature: Bool { isSignedIn }

  var r18Note: R18Note {
    if !isSignedIn { return .signInToShow }
    return showsR18 == false ? .accountHidesThem : .neverShowsR18G
  }

  init(
    isSignedIn: Bool, isSigningIn: Bool, name: String? = nil, id: String? = nil,
    showsR18: Bool? = nil, message: String? = nil
  ) {
    self.isSignedIn = isSignedIn
    self.isSigningIn = isSigningIn
    self.name = name
    self.id = id
    self.showsR18 = showsR18
    self.message = message
  }

  @MainActor
  init(_ pixiv: PixivStore) {
    self.init(
      isSignedIn: pixiv.isSignedIn, isSigningIn: pixiv.isSigningIn, name: pixiv.account?.name,
      id: pixiv.account?.id, showsR18: pixiv.account?.showsR18, message: pixiv.accountMessage)
  }
}
